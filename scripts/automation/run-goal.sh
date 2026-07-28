#!/usr/bin/env bash
# run-goal.sh — Goal-driven continuous mode runner.
#
# Reads docs/goal.md (which must include Must-have user journeys + Anti-goals)
# and iterates `decompose -> execute -> evaluate` adaptively until either the
# goal-evaluator declares GOAL_ACHIEVED or a hard halt fires (stall, regression,
# or an optional --max-iter budget — there is no iteration cap by default).
#
# Usage:
#   ./scripts/automation/run-goal.sh [--session-id <id>] [--max-iter N]
#                                    [--stall-window N] [--resume] [--reset]
#                                    [--auto-release]
#                                    [--acknowledge-regression]
#                                    [--require-blueprint-approval]
#                                    [--intent-checkpoint] [--intent-checkpoint-at N]
#                                    [--no-push-per-iter] [--push-per-iter]
#                                    [--push-branch <name>]
#
# Flags:
#   --session-id <id>            Session identifier (auto-generated if omitted)
#   --max-iter N                 Optional hard cap on iterations (default: unlimited; 0 = no cap)
#   --stall-window N             Halt if last N iterations show no journey progress (default: 3)
#   --resume                     Resume an existing session
#   --reset                      Discard the named session and start fresh
#   --auto-release               On GOAL_ACHIEVED, run release-manager once for the whole session
#   --acknowledge-regression     Continue past a prior REGRESSION_HALT
#   --require-blueprint-approval Pause after baseline for the human to review/edit state/blueprint.md
#                                (and on structural nav-skeleton changes). OFF by default — goal mode
#                                auto-approves the AI-drafted blueprint and runs hands-off.
#                                (--auto-approve-blueprint is still accepted but is now the default.)
#   --intent-checkpoint          Opt-in mid-session pause (once per session): when >=50% of the
#                                Must-have journeys pass, pause resumably with a deterministic
#                                intent-review.md asking "is this still the product you wanted?".
#                                OFF by default. --resume acknowledges and continues.
#   --intent-checkpoint-at N     Same pause, but fire when the loop reaches iteration N (same
#                                convention as --max-iter) instead of the 50% threshold. OFF by
#                                default; combinable with --intent-checkpoint (first trigger wins;
#                                still fires at most once per session).
#   --push-per-iter              [Default ON for new sessions.] Commit + push each successful
#                                iteration (CONTINUE / ESCALATE / GOAL_ACHIEVED) to a per-session
#                                branch. No model invocation, no PR per iter — the branch is
#                                populated incrementally and a PR is opened at the end via the
#                                existing --auto-release / manual flow. Useful on resume to
#                                opt in mid-session for a session that wasn't pushing before.
#   --no-push-per-iter           Opt out of per-iter push. Use this on a new session to keep
#                                iter commits local, or on resume to disable push for a session
#                                that was previously pushing.
#   --push-branch <name>         Branch name for per-iter commits (default: goal/<session-id>).
#                                Persists to session.json on new sessions; resume reads from there.
#
# Halt verdicts written to runs/goal-session-<sid>/session.json.status:
#   GOAL_ACHIEVED   - goal-evaluator declared done
#   BUDGET_EXHAUSTED - max iterations reached (only when --max-iter > 0 is set)
#   STALLED          - journey-history hash unchanged for stall_window iterations
#   REGRESSION_HALT  - goal-evaluator emitted REGRESSION verdict
#   ABORTED          - user interrupted (SIGINT/SIGTERM)
#   AWAITING_BLUEPRINT_APPROVAL - only with --require-blueprint-approval: paused after baseline (or a
#                                 structural blueprint change) for the human to review/edit
#                                 state/blueprint.md; resume with --resume (resuming counts as approval)
#   AWAITING_INTENT_REVIEW - only with --intent-checkpoint / --intent-checkpoint-at: paused once
#                            mid-session for the human to read intent-review.md ("is this the
#                            product you wanted?"); resume with --resume (counts as acknowledgment)
#   AWAITING_PUMP    - interactive pump/dispatch was unavailable mid-iteration (the foreground
#                      session/pump went away); resumable — /goal-resume re-runs the same iteration
#   AWAITING_GITHUB_AUTH - preflight found no GitHub push access; fix auth, then --resume
#   AWAITING_DISK    - free disk under the hard floor even after automatic aggressive cleanup;
#                      free space or run scripts/automation/tmp-doctor.sh --aggressive, then --resume
#   AWAITING_HOST_GUARD - host-guard preflight/gate failed (hwmon sampler dead and unstartable,
#                      CPU-affinity wrap absent, a launcher lost its HOST-GUARD cap block, or the
#                      interactive pump session is unconfined); fix per the printed reason
#                      (project-extensions/host-guard/README.md), then --resume
#
# Quota exhaustion is NOT a halt: claude_with_quota_retry transparently sleeps
# until the quota resets and resumes.
set -euo pipefail

# REL-2: snapshot the ambient CHAIN_* names NOW — before this script (or the
# libs it sources) exports its own — so the preflight doctor can report the
# session-START environment truth (stray knobs silently alter engine behavior;
# measurement runs demand a clean env).
_CHAIN_AMBIENT_AT_START="$(compgen -A export CHAIN_ 2>/dev/null | sort | tr '\n' ' ' || true)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/telemetry.sh"
source "$SCRIPT_DIR/lib/goal-gates.sh"
source "$SCRIPT_DIR/lib/engine-lock.sh"
source "$SCRIPT_DIR/lib/plain-language.sh"

# ── Host-guard self-wrap (hardware protection) ─────────────────────────────
# Origin: a mini-PC host hard-reset instantly (no OOM, no thermal log, no
# panic) under goal-mode's bursty all-core load — a power/VRM transient trip.
# When the project declares host caps (project-extensions/host-guard/
# host-guard.env), re-exec the ENTIRE engine tree under an SMT-aware
# CPU-affinity mask (taskset — hard, inherited, instantaneous) plus, when a
# user manager is reachable, a systemd user scope adding AllowedCPUs (cgroup
# cpuset — inherited by every descendant, cannot be widened from inside) and
# CPUQuota/MemoryHigh/TasksMax as averaging/aggregate backstops. Sits BEFORE
# extract_cli_arg so "$@" is still the original argv. HOST_GUARD_WRAPPED
# guards recursion — deliberately NOT CHAIN_-prefixed so the REL-2 ambient
# snapshot above stays clean. Absent/disabled env file ⇒ no-op (the framework
# stays project-neutral). Details: project-extensions/host-guard/README.md.
_HOST_GUARD_ENV_FILE="$REPO_ROOT/project-extensions/host-guard/host-guard.env"
if [[ -z "${HOST_GUARD_WRAPPED:-}" && -f "$_HOST_GUARD_ENV_FILE" ]] \
   && command -v taskset >/dev/null 2>&1; then
  # shellcheck disable=SC1090
  source "$_HOST_GUARD_ENV_FILE"
  if [[ "${HOST_GUARD_ENABLED:-0}" == "1" && -n "${HOST_GUARD_CPU_LIST:-}" ]]; then
    export HOST_GUARD_WRAPPED=1
    # Capture the interactive CLI session root (the pump) BEFORE the re-exec
    # below reparents us: walk the ppid chain for the outermost process whose
    # cmdline matches HOST_GUARD_CLI_PATTERN. The iteration gate verifies —
    # and, if needed, confines in place via host-guard-adopt.sh — this pid.
    if [[ -z "${HOST_GUARD_PUMP_ROOT_PID:-}" ]]; then
      _hg_p="$PPID" _hg_root=""
      while [[ "$_hg_p" =~ ^[0-9]+$ ]] && (( _hg_p > 1 )); do
        if tr '\0' ' ' < "/proc/$_hg_p/cmdline" 2>/dev/null \
             | grep -qE "${HOST_GUARD_CLI_PATTERN:-claude|codex}"; then
          _hg_root="$_hg_p"
        fi
        _hg_p="$(awk '/^PPid:/{print $2}' "/proc/$_hg_p/status" 2>/dev/null || true)"
      done
      if [[ -n "$_hg_root" ]]; then export HOST_GUARD_PUMP_ROOT_PID="$_hg_root"; fi
    fi
    _HG_PROPS=( -p "CPUQuota=${HOST_GUARD_CPUQUOTA:-800%}"
                -p "MemoryHigh=${HOST_GUARD_MEMORY_HIGH:-18G}"
                -p "TasksMax=${HOST_GUARD_TASKS_MAX:-2048}" )
    # --expand-environment=no: systemd ExecStart otherwise $-expands argv.
    if systemd-run --user --scope --quiet --expand-environment=no -p "AllowedCPUs=$HOST_GUARD_CPU_LIST" true 2>/dev/null; then
      # Full confinement: cpuset + quota backstops (AllowedCPUs probe passed).
      exec systemd-run --user --scope --quiet --collect --expand-environment=no \
        --unit "chain-goal-hostguard-$$" \
        -p "AllowedCPUs=$HOST_GUARD_CPU_LIST" "${_HG_PROPS[@]}" \
        taskset -c "$HOST_GUARD_CPU_LIST" "$SCRIPT_DIR/run-goal.sh" "$@"
    elif systemd-run --user --scope --quiet --expand-environment=no -p CPUQuota=10% true 2>/dev/null; then
      # cpuset controller not delegated: scope backstops + taskset mask only.
      exec systemd-run --user --scope --quiet --collect --expand-environment=no \
        --unit "chain-goal-hostguard-$$" \
        "${_HG_PROPS[@]}" \
        taskset -c "$HOST_GUARD_CPU_LIST" "$SCRIPT_DIR/run-goal.sh" "$@"
    else
      # No user manager at all (headless SSH etc.): affinity mask still applies.
      exec taskset -c "$HOST_GUARD_CPU_LIST" "$SCRIPT_DIR/run-goal.sh" "$@"
    fi
  fi
fi

# Pull --cli (and --force-cli) out of the args BEFORE the existing parse loop,
# so the loop below sees only its known flags.
extract_cli_arg "$@" || exit $?
if [[ ${#CHAIN_CLI_REMAINING_ARGS[@]} -gt 0 ]]; then
  set -- "${CHAIN_CLI_REMAINING_ARGS[@]}"
else
  set --
fi

# ── Defaults ──────────────────────────────────────────────────────────────
SESSION_ID=""
MAX_ITER=0          # 0 = unlimited; NEW sessions default to 60 unless --max-iter is passed (explicit 0 keeps unlimited); resume honors the value stored in session.json
MAX_ITER_EXPLICIT=false
STALL_WINDOW=3
RESUME=false
RESET=false
AUTO_RELEASE=false
ACK_REGRESSION=false
# Blueprint review pause. Auto-approved by DEFAULT (goal mode is hands-off): the
# AI-drafted blueprint is accepted as-is and any structural re-approval marker is
# cleared, so the loop never pauses for it. Pass --require-blueprint-approval to
# restore the one-time baseline review pause (and structural re-approval pauses).
AUTO_APPROVE_BLUEPRINT=true
# Interactive dispatch backend: run each agent as a subagent in the foreground
# Claude Code session (the "pump") via a file channel instead of headless
# `claude -p`, so the work bills to the interactive plan allowance. Pinned
# per-session (like --cli). Off by default (headless / Agent SDK path).
INTERACTIVE=false
# Per-iter push is ON by default for new sessions. Pass --no-push-per-iter to
# opt out. On resume, the persisted session.json value wins unless overridden
# by an explicit CLI flag (--push-per-iter or --no-push-per-iter).
PUSH_PER_ITER=true
PUSH_BRANCH=""
# Tristate: "default" (no flag), "yes" (--push-per-iter), "no" (--no-push-per-iter).
# Used by the resume block to decide whether to override session.json.
PUSH_FLAG_USER="default"
# Set in the resume branch (off | continuing | opting-in). Stays empty for
# new sessions; the branch-lifecycle block only consults it when RUN_MODE=resume.
RESUME_PUSH_MODE=""
# Intent checkpoint (NEED-7): opt-in mid-session resumable pause asking the
# human "is this still the product you wanted?". OFF by default; fires at most
# once per session. --intent-checkpoint triggers at >=50% journeys passing;
# --intent-checkpoint-at N triggers when the loop reaches iteration N.
INTENT_CHECKPOINT=false
INTENT_CHECKPOINT_AT=0

# ── Parse flags ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id)              SESSION_ID="$2"; shift 2 ;;
    --max-iter)                MAX_ITER="$2"; MAX_ITER_EXPLICIT=true; shift 2 ;;
    --stall-window)            STALL_WINDOW="$2"; shift 2 ;;
    --resume)                  RESUME=true; shift ;;
    --reset)                   RESET=true; shift ;;
    --auto-release)            AUTO_RELEASE=true; shift ;;
    --acknowledge-regression)  ACK_REGRESSION=true; shift ;;
    --auto-approve-blueprint)  AUTO_APPROVE_BLUEPRINT=true; shift ;;   # now the default; kept for back-compat
    --require-blueprint-approval) AUTO_APPROVE_BLUEPRINT=false; shift ;;
    --interactive)             INTERACTIVE=true; shift ;;
    --intent-checkpoint)       INTENT_CHECKPOINT=true; shift ;;
    --intent-checkpoint-at)    INTENT_CHECKPOINT_AT="$2"; shift 2 ;;
    --push-per-iter)           PUSH_PER_ITER=true;  PUSH_FLAG_USER="yes"; shift ;;
    --no-push-per-iter)        PUSH_PER_ITER=false; PUSH_FLAG_USER="no";  shift ;;
    --push-branch)             PUSH_BRANCH="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$SESSION_ID" ]]; then
  if [[ "$RESUME" == "true" ]]; then
    echo "Error: --resume requires --session-id <id>" >&2
    exit 1
  fi
  SESSION_ID="$(date -u +%Y-%m-%d)-$(printf '%s' "$REPO_ROOT" | sha1sum | cut -c1-6)"
  echo "[run-goal] No --session-id provided. Using auto-generated: $SESSION_ID"
fi

GOAL_SESSION_DIR_LOCAL="$REPO_ROOT/runs/goal-session-${SESSION_ID}"
SESSION_JSON="$GOAL_SESSION_DIR_LOCAL/session.json"
ENGINE_PID_FILE="$GOAL_SESSION_DIR_LOCAL/engine.pid"

# Resume: pin CHAIN_CLI from session.json unless the user explicitly overrode it.
# A mismatch errors out unless --force-cli is given.
if [[ "$RESUME" == "true" && -f "$SESSION_JSON" ]]; then
  PERSISTED_CLI=$(read_cli_from_json "$SESSION_JSON")
  if [[ -n "$PERSISTED_CLI" ]]; then
    if [[ "${CHAIN_CLI_FROM_FLAG:-false}" == "true" && "$CHAIN_CLI" != "$PERSISTED_CLI" ]]; then
      if [[ "${CHAIN_FORCE_CLI:-false}" != "true" ]]; then
        echo "Error: session $SESSION_ID was started with --cli=$PERSISTED_CLI" >&2
        echo "  but --cli=$CHAIN_CLI was passed on resume." >&2
        echo "  Pass --force-cli to override (telemetry will mix CLIs)." >&2
        exit 2
      fi
      echo "[run-goal] WARNING: overriding session CLI from $PERSISTED_CLI to $CHAIN_CLI (--force-cli)" >&2
    else
      export CHAIN_CLI="$PERSISTED_CLI"
    fi
  fi
fi

# Resume self-heal: if a previous engine for this session is still running (e.g.
# the user pressed Ctrl+C in the interactive pump, which never reaches the
# detached engine), stop it cleanly before starting a new one — otherwise two
# engines would race on the same session. SIGTERM fires the old engine's on_abort
# (clean ABORTED checkpoint); SIGKILL only if it ignores us. The /proc cmdline
# check guards against a stale pidfile whose PID was reused by another process.
if [[ "$RESUME" == "true" && -f "$ENGINE_PID_FILE" ]]; then
  _prev_pid="$(cat "$ENGINE_PID_FILE" 2>/dev/null || echo "")"
  if [[ -n "$_prev_pid" ]] && kill -0 "$_prev_pid" 2>/dev/null \
     && grep -qa "run-goal" "/proc/$_prev_pid/cmdline" 2>/dev/null; then
    echo "[run-goal] Resume: a prior engine (pid $_prev_pid) is still running — stopping it cleanly first." >&2
    kill -TERM "$_prev_pid" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$_prev_pid" 2>/dev/null || break; sleep 0.5; done
    if kill -0 "$_prev_pid" 2>/dev/null; then
      echo "[run-goal] Prior engine ignored SIGTERM; sending SIGKILL." >&2
      kill -KILL "$_prev_pid" 2>/dev/null || true
    fi
  fi
  rm -f "$ENGINE_PID_FILE" 2>/dev/null || true
fi

# ── Resolve the agent dispatch backend (interactive vs headless) ───────────
# Pinned per-session like --cli: on resume, adopt the persisted backend unless
# --interactive is re-asserted on the command line.
if [[ "$RESUME" == "true" && -f "$SESSION_JSON" && "$INTERACTIVE" != "true" ]]; then
  PERSISTED_BACKEND=$(python3 -c "import json;print(json.load(open('$SESSION_JSON')).get('agent_backend',''))" 2>/dev/null || echo "")
  if [[ "$PERSISTED_BACKEND" == "interactive" ]]; then
    INTERACTIVE=true
  fi
fi
if [[ "$INTERACTIVE" == "true" ]]; then
  AGENT_BACKEND="interactive"
else
  AGENT_BACKEND="headless"
fi

# Interactive: tee the engine's full (headless-style) stdout+stderr to a session
# log, timestamped per line, so the user can watch the real chain narrative
# (`tail -f runs/goal-session-<sid>/engine.log`) without it costing pump-context
# tokens — the pump never reads this file. Headless's live terminal stream is
# left untouched. python3 is already a hard dependency; -u keeps it line-flushed.
if [[ "$INTERACTIVE" == "true" ]]; then
  ENGINE_LOG="$GOAL_SESSION_DIR_LOCAL/engine.log"
  mkdir -p "$GOAL_SESSION_DIR_LOCAL"
  exec > >(python3 -u -c 'import sys, datetime
for ln in sys.stdin:
    sys.stdout.write(datetime.datetime.now().strftime("%H:%M:%S ") + ln)' \
          | tee -a "$ENGINE_LOG") 2>&1
fi

require_cli
ensure_cli_assets_synced "$CHAIN_CLI"
JOURNEY_HISTORY="$GOAL_SESSION_DIR_LOCAL/state/journey-history.json"
EVALUATOR_LOG="$GOAL_SESSION_DIR_LOCAL/state/evaluator-log.md"
# REL-6: the evaluator-written, decomposer-read iteration digest (single
# writer: only the goal-evaluator's step 7 creates/overwrites this file).
ITER_STATE_FILE="$GOAL_SESSION_DIR_LOCAL/state/iteration-state.md"
LESSONS_FILE="$GOAL_SESSION_DIR_LOCAL/state/lessons.md"
# Assumption ledger (NEED-5): append-only record of interpretation calls the
# decomposer/evaluator made where the goal was ambiguous. Created lazily by the
# agents on first append; absent file renders as a placeholder in prompts.
ASSUMPTIONS_FILE="$GOAL_SESSION_DIR_LOCAL/state/assumptions.md"
# Coherence blueprint (information architecture + data contract). Drafted by the
# baseline decomposer, approved once by the human, enforced each iteration.
BLUEPRINT_FILE="$GOAL_SESSION_DIR_LOCAL/state/blueprint.md"
BLUEPRINT_APPROVED="$GOAL_SESSION_DIR_LOCAL/state/blueprint.approved"
BLUEPRINT_REAPPROVAL="$GOAL_SESSION_DIR_LOCAL/state/blueprint.reapproval-requested"
# Intent checkpoint (NEED-7): the deterministic review packet and the once-per-
# session marker (touched when --resume acknowledges the pause).
INTENT_REVIEW_FILE="$GOAL_SESSION_DIR_LOCAL/intent-review.md"
INTENT_REVIEW_DONE="$GOAL_SESSION_DIR_LOCAL/state/.intent-review-done"
SUMMARY_FILE="$GOAL_SESSION_DIR_LOCAL/summary.md"
GOAL_FILE="$REPO_ROOT/docs/goal.md"

# Run the iteration-summarizer agent for one iteration. Writes
# reports/phase-<iter>-iteration-summary.md. Non-blocking — failures only log.
# The agent reads the existing artifacts (dev handoff, review, eval.md,
# journey-history, etc.) and produces the conclusive MD that the HTML
# renderer then consumes.
_run_iteration_summarizer() {
  local iter_name="$1"
  local agent_file="$REPO_ROOT/.claude/agents/iteration-summarizer.md"
  local summary_md="$REPO_ROOT/reports/phase-${iter_name}-iteration-summary.md"
  [[ -f "$agent_file" ]] || { echo "[run-goal] Warning: iteration-summarizer agent missing, skipping"; return 0; }
  mkdir -p "$REPO_ROOT/reports"

  # Pre-trim evaluator-log.md so token usage stays flat as sessions grow.
  local eval_log_inline=""
  eval_log_inline=$(_tail_or_placeholder "$EVALUATOR_LOG" 300 "(none yet)")

  # Assumption ledger tail (NEED-6): inlined so the summary's "Assumptions
  # made" section can surface interpretation calls to the human.
  local assumptions_inline=""
  assumptions_inline=$(_tail_or_placeholder "$ASSUMPTIONS_FILE" 200 "(no assumptions recorded yet)")

  local project_story_md="$REPO_ROOT/runs/goal-session-${SESSION_ID}/state/project-story.md"
  mkdir -p "$REPO_ROOT/runs/goal-session-${SESSION_ID}/state"

  cd "$REPO_ROOT"
  # record_* pair (not a bare export): attributes telemetry/trace to this agent
  # and clears CHAIN_CURRENT_AGENT afterwards so attribution can't bleed into
  # later inline calls.
  record_agent_invocation_start "iteration-summarizer"
  local _sum_start=$CHAIN_AGENT_START_EPOCH
  local _sum_rc=0
  claude_with_quota_retry -p "You are the iteration-summarizer agent.

mode: normal
Phase id: $iter_name
Output path (iteration summary): $summary_md
Output path (project story, GOAL MODE ONLY): $project_story_md
Agent instructions: .claude/agents/iteration-summarizer.md  <-- read this first
Template: templates/iteration-summary.md  <-- exact section structure your output must follow
(CLAUDE.md is already in your system prompt -- do not Read it again.)

Read every relevant input listed in your agent instructions. Files that don't
exist should be silently skipped. Use what is present. The dispatch wrapper
has pre-trimmed evaluator-log.md below — use the inline content.

Recent evaluator log entries (last 300 lines, pre-trimmed):
---
${eval_log_inline}
---

Assumption ledger tail (recent entries, pre-trimmed; '(no assumptions recorded
yet)' means empty — see the 'Assumptions made' section of your instructions):
---
${assumptions_inline}
---

Write the iteration summary to: $summary_md

This is a GOAL-MODE iteration. After writing the iteration summary, also
maintain $project_story_md per the 'Cumulative project story' section of your
agent instructions. Read the existing file if present, then rewrite it as one
flowing plain-language narrative that ends with this iteration.

Follow the section structure in templates/iteration-summary.md EXACTLY -- the
HTML renderer keys off the section headings. The verdict line must match the
form '**Verdict:** VALUE' where VALUE is one of: GOAL_ACHIEVED, CONTINUE,
ESCALATE, REGRESSION, STALLED, PASS, FAIL, IN-PROGRESS.

When finished, STOP." \
    || { _sum_rc=$?; echo "[run-goal] Warning: iteration-summarizer call failed (non-blocking)"; }
  record_agent_invocation_end "iteration-summarizer" "$_sum_start" "$_sum_rc"
}

# Run the retro-analyst agent at a terminal session halt (EVO-2 slice b).
# Reads ONLY state/retro-input.md (the collector's frozen digest) and drafts
# reports/goal-session-<sid>-retro.md — 1-5 candidate framework-improvement
# proposals for human triage. Non-blocking showcase-class step: a failed or
# skipped dispatch never changes halt behavior or an engine exit code. The
# caller (write_session_summary) gates on CHAIN_SESSION_RETRO + the terminal-
# status filter; this function additionally requires the digest to exist so
# the agent can never dispatch without its single input.
_run_retro_analyst() {
  local agent_file="$REPO_ROOT/.claude/agents/retro-analyst.md"
  local retro_input="$GOAL_SESSION_DIR_LOCAL/state/retro-input.md"
  local retro_report="$REPO_ROOT/reports/goal-session-${SESSION_ID}-retro.md"
  [[ -f "$agent_file" ]] || { echo "[run-goal] Warning: retro-analyst agent missing, skipping retro draft"; return 0; }
  [[ -f "$retro_input" ]] || { echo "[run-goal] Warning: no retro-input.md (collector failed or skipped) — retro-analyst not dispatched."; return 0; }
  mkdir -p "$REPO_ROOT/reports"

  cd "$REPO_ROOT"
  # record_* pair (not a bare export): attributes telemetry/trace to this agent
  # and clears CHAIN_CURRENT_AGENT afterwards so attribution can't bleed into
  # later inline calls.
  record_agent_invocation_start "retro-analyst"
  local _retro_start=$CHAIN_AGENT_START_EPOCH
  local _retro_rc=0
  claude_with_quota_retry -p "You are the retro-analyst agent.

Session ID: $SESSION_ID
Retro input (your ONLY input file): $retro_input
Output path (the retro report): $retro_report
Agent instructions: .claude/agents/retro-analyst.md  <-- read this first
(CLAUDE.md is already in your system prompt -- do not Read it again.)

Read the retro input file and NOTHING else. Draft at most 5 candidate
framework-improvement items per your agent instructions — proposals only,
each citing its exact evidence line from the retro input; zero items is a
valid outcome. Never edit docs/improvement-roadmap.md or any other file.

Write the report to: $retro_report

Write the report and STOP." \
    || { _retro_rc=$?; echo "[run-goal] Warning: retro-analyst dispatch failed (non-blocking) — no retro report." >&2; }
  record_agent_invocation_end "retro-analyst" "$_retro_start" "$_retro_rc"
  # REL-11 missing-evidence tripwire: the dispatch returned (any rc) but the
  # report is not on disk — the baseline benchmark's retro vanished exactly
  # this way with rc=0 (untrusted-workspace Write denial). Non-blocking.
  if [[ ! -f "$retro_report" ]]; then
    warn_missing_evidence "retro-analyst" "$retro_report"
  fi
}

# Maintain the PROJECT's README.md so it always reflects current capabilities and
# carries a How-to-run section. Non-blocking — failures only log. Runs every
# iteration in goal mode (headless or interactive). The agent edits only
# marker-delimited AUTO blocks so any hand-written prose is preserved, and grounds
# all run/install/test commands in .claude/project-template.md.
_run_readme_maintainer() {
  local iter_name="$1"
  local agent_file="$REPO_ROOT/.claude/agents/readme-maintainer.md"
  [[ -f "$agent_file" ]] || { echo "[run-goal] Warning: readme-maintainer agent missing, skipping README update"; return 0; }

  # Token gate: skip the dispatch when this iteration provably changed nothing
  # user-visible (only test/report/handoff/spec churn). Conservative by design —
  # any app/config/script/doc change, a missing snapshot, or a git error runs
  # the agent as before. CHAIN_README_EVERY_ITER=true restores the old behavior.
  if [[ "${CHAIN_README_EVERY_ITER:-false}" != "true" ]]; then
    local _snap _changed
    _snap="$(cat "$GOAL_SESSION_DIR_LOCAL/iter-${CURRENT_ITER}/snapshot-sha" 2>/dev/null || echo "")"
    if [[ -n "$_snap" ]]; then
      _changed="$( { git -C "$REPO_ROOT" diff --name-only "$_snap" 2>/dev/null; git -C "$REPO_ROOT" status --porcelain 2>/dev/null | awk '{print $NF}'; } | sort -u )" || _changed="__git_error__"
      if [[ "$_changed" == "__git_error__" ]]; then
        : # git error → run the agent (fail-safe, unchanged behavior)
      elif [[ -z "$_changed" ]]; then
        # SPEED-14: a zero-change iteration used to fall through this guard and
        # dispatch anyway — the empty set is the STRONGEST reason to skip.
        echo "[run-goal] readme-maintainer: skipped — iteration changed no files at all. Set CHAIN_README_EVERY_ITER=true to disable this gate."
        return 0
      else
        local _visible
        _visible="$(printf '%s\n' "$_changed" | grep -Ev '^(tests?/|runs/|reports/|docs/handoffs/|docs/phases/)' || true)"
        if [[ -z "$_visible" ]]; then
          echo "[run-goal] readme-maintainer: skipped — iteration touched only test/report/handoff/spec paths (no user-visible change). Set CHAIN_README_EVERY_ITER=true to disable this gate."
          return 0
        fi
      fi
    fi
  fi

  cd "$REPO_ROOT"
  record_agent_invocation_start "readme-maintainer"
  local _rm_start=$CHAIN_AGENT_START_EPOCH
  local _rm_rc=0
  claude_with_quota_retry -p "You are the readme-maintainer agent.

Phase id: $iter_name
Target file: README.md (the project-root README of THIS repository)
Agent instructions: .claude/agents/readme-maintainer.md  <-- read this first
Skill: .claude/skills/readme-maintenance.md  <-- the marker-scoped editing method
Run-command source of truth: .claude/project-template.md  <-- Stack, Test commands, Service start commands, URLs
README skeleton (use only if README.md is absent): templates/project-readme.md
Capabilities inputs (read what exists, silently skip what doesn't):
- reports/phase-${iter_name}-user-visible-changes.md
- reports/phase-${iter_name}-implementation-summary.md
- reports/phase-${iter_name}-iteration-summary.md
(CLAUDE.md is already in your system prompt -- do not Read it again.)

Refresh README.md so it reflects the CURRENT project and includes a 'How to run'
section. Edit ONLY the marker-delimited AUTO blocks described in your skill;
never delete human-written prose outside them. Ground every install/run/test
command in .claude/project-template.md — if a needed field is still a template
placeholder (<e.g., ...>), write a 'TODO:' line rather than inventing a command.

When finished, STOP." \
    || { _rm_rc=$?; echo "[run-goal] Warning: readme-maintainer call failed (non-blocking)"; }
  record_agent_invocation_end "readme-maintainer" "$_rm_start" "$_rm_rc"
}

# Generate the one-time "delivered" wrap when goal-evaluator returns
# GOAL_ACHIEVED. Writes a polished non-technical summary to
# reports/goal-session-<sid>-delivered.md and renders the matching HTML. Both
# steps are non-blocking — failures only log so the GOAL_ACHIEVED path still
# completes its auto-release / exit.
_render_final_delivered() {
  local sid="$1"
  local delivered_md="$REPO_ROOT/reports/goal-session-${sid}-delivered.md"
  local agent_file="$REPO_ROOT/.claude/agents/iteration-summarizer.md"
  local renderer="$SCRIPT_DIR/lib/render_iteration_summary.py"

  if [[ ! -f "$agent_file" ]]; then
    echo "[run-goal] Warning: iteration-summarizer agent missing — skipping delivered wrap"
    return 0
  fi

  mkdir -p "$REPO_ROOT/reports"

  cd "$REPO_ROOT"
  record_agent_invocation_start "iteration-summarizer"
  local _dw_start=$CHAIN_AGENT_START_EPOCH
  local _dw_rc=0
  claude_with_quota_retry -p "You are the iteration-summarizer agent.

mode: delivered
Session id: $sid
Output path: $delivered_md
Agent instructions: .claude/agents/iteration-summarizer.md  <-- read this first; specifically the 'Delivered wrap' section
(CLAUDE.md is already in your system prompt -- do not Read it again.)

This is the one-time GOAL_ACHIEVED delivered wrap. Read:
- runs/goal-session-${sid}/state/journey-history.json (all currently passing journeys)
- runs/goal-session-${sid}/state/project-story.md (the running narrative)
- All reports/phase-goal-${sid}-iter-*-iteration-summary.md files (each iter's plain words)
- docs/goal.md (goal title)

Write a polished, non-technical 'what we delivered' document to:
$delivered_md

Follow the 'Delivered wrap' skeleton in your agent instructions EXACTLY. Do
NOT also rewrite the iteration summary in this mode. Friendly, factual, no
journey IDs, no file names.

When finished, STOP." \
    || { _dw_rc=$?; echo "[run-goal] Warning: delivered-wrap iteration-summarizer call failed (non-blocking)"; }
  record_agent_invocation_end "iteration-summarizer" "$_dw_start" "$_dw_rc"

  if [[ -f "$renderer" ]]; then
    python3 "$renderer" delivered "$sid" --repo-root="$REPO_ROOT" 2>&1 \
      | sed 's/^/[run-goal] /' || echo "[run-goal] Warning: delivered HTML render failed (non-blocking)"
  fi
}

# Render the per-iteration HTML summary. Non-blocking — failures only log.
# Invoked after each iteration finishes its goal-evaluator step so the user
# can `open file://...` and inspect what happened that iteration.
_render_iter_html() {
  local iter_name="$1"
  local renderer="$SCRIPT_DIR/lib/render_iteration_summary.py"
  [[ -f "$renderer" ]] || return 0
  python3 "$renderer" iteration "$iter_name" --repo-root="$REPO_ROOT" 2>&1 \
    | sed 's/^/[run-goal] /' || echo "[run-goal] Warning: per-iter HTML render failed (non-blocking)"
}

# Render the session-level index.html that lists every iteration as a card
# plus the journey progress matrix. Called from write_session_summary, so it
# refreshes at every session boundary (CONTINUE, ABORT, GOAL_ACHIEVED, …).
_render_session_index_html() {
  local renderer="$SCRIPT_DIR/lib/render_iteration_summary.py"
  [[ -f "$renderer" ]] || return 0
  python3 "$renderer" session-index "$SESSION_ID" --repo-root="$REPO_ROOT" 2>&1 \
    | sed 's/^/[run-goal] /' || echo "[run-goal] Warning: session-index HTML render failed (non-blocking)"
}

# ── Showcase tail (demo → summary → README → renders), inline or forked ──────
# These steps are non-gating showcase/maintenance, but they used to sit
# 6-13 min on the loop's critical path between the evaluator and the next
# decomposer (measured: summarizer ~5.7m + readme ~4.5m + renders). For
# CONTINUE/ESCALATE verdicts they now run as a background group that overlaps
# the NEXT iteration's decomposer; the group is joined — and its artifacts
# committed — BEFORE the next executor dispatch, so developer/reviewer N+1 see
# exactly the tree the sequential ordering produced. Halt verdicts keep the
# inline path so final summaries are always complete before the session ends.
# Disable with CHAIN_ASYNC_SHOWCASE=false.
_SHOWCASE_PID=""
_SHOWCASE_ITER=""

_run_showcase_steps() {
  local iter_name="$1" depth="$2"
  # Demo first (lean depth only — full depth records inside run-phase.sh).
  # demo-phase.sh boots its own services idempotently; _join_showcase_tail
  # clears them so the next iteration's browser-qa never reuses a server tree
  # that is still serving iteration N's code.
  if [[ "$depth" == "lean" ]]; then
    # SPEED-14: with an empty product diff the app is byte-identical to the
    # last recorded walkthrough — reuse it instead of re-recording (~5-7 min).
    local _demo_skip=""
    if [[ "${CHAIN_ZERO_CHANGE_SKIPS:-true}" == "true" ]] \
       && declare -F goal_product_diff_empty >/dev/null 2>&1 \
       && goal_product_diff_empty "$(cat "$GOAL_SESSION_DIR_LOCAL/iter-${CURRENT_ITER}/snapshot-sha" 2>/dev/null || echo "")" "$REPO_ROOT"; then
      local _prior_demo
      _prior_demo="$(ls -1t "$REPO_ROOT"/reports/phase-goal-"$SESSION_ID"-iter-*-demo-results.md 2>/dev/null | grep -v -- "-${iter_name}-demo-results" | head -1 || true)"
      if [[ -n "$_prior_demo" ]]; then
        echo "[run-goal] demo record skipped — zero-change iteration; walkthrough reused from $(basename "$_prior_demo") (set CHAIN_ZERO_CHANGE_SKIPS=false to always re-record)."
        record_telemetry_event "step_skipped" "$(jq -cn --arg n "$iter_name" '{step:"demo-narrator", iter_name:$n, reason:"zero-change"}' 2>/dev/null || printf '{"step":"demo-narrator","reason":"zero-change"}')"
        _demo_skip=1
      fi
    fi
    if [[ -z "$_demo_skip" ]]; then
      bash "$SCRIPT_DIR/demo-phase.sh" "$iter_name" \
        || echo "[run-goal] demo-phase.sh exited non-zero — continuing (showcase, non-gating)"
    fi
  fi
  _run_iteration_summarizer "$iter_name"
  _run_readme_maintainer "$iter_name"
  _render_iter_html "$iter_name"
  _render_session_index_html
}

_fork_showcase_tail() {
  local iter_name="$1" depth="$2"
  _SHOWCASE_ITER="$CURRENT_ITER"
  ( _run_showcase_steps "$iter_name" "$depth" ) &
  _SHOWCASE_PID=$!
  echo "[run-goal] Showcase tail (demo → summary → README → renders) running in the background (pid $_SHOWCASE_PID); the loop proceeds."
}

# _join_showcase_tail [--kill]
#   default: bounded wait for the group, clear its demo services, then commit
#            (+push) its artifacts when push-per-iter is on. Scoped add — the
#            next iteration's freshly written spec stays uncommitted, exactly
#            as it does under the sequential ordering.
#   --kill:  reap immediately without committing (Ctrl-C / dead-pump paths,
#            where the group's own agent dispatches cannot succeed anyway).
_join_showcase_tail() {
  [[ -n "${_SHOWCASE_PID:-}" ]] || return 0
  local mode="${1:-}"
  if [[ "$mode" == "--kill" ]]; then
    if declare -F _kill_pid_tree >/dev/null 2>&1; then
      _kill_pid_tree "$_SHOWCASE_PID" 2>/dev/null || true
    else
      kill "$_SHOWCASE_PID" 2>/dev/null || true
    fi
    wait "$_SHOWCASE_PID" 2>/dev/null || true
    _SHOWCASE_PID=""
    return 0
  fi
  local timeout_s="${CHAIN_ASYNC_SHOWCASE_JOIN_TIMEOUT:-900}"
  local waited=0
  if kill -0 "$_SHOWCASE_PID" 2>/dev/null; then
    echo "[run-goal] Waiting for the background showcase tail of iter ${_SHOWCASE_ITER} (bounded ${timeout_s}s)..."
  fi
  while kill -0 "$_SHOWCASE_PID" 2>/dev/null; do
    if [[ "$waited" -ge "$timeout_s" ]]; then
      echo "[run-goal] Showcase tail exceeded ${timeout_s}s — killing it (non-gating; artifacts may be partial)." >&2
      if declare -F _kill_pid_tree >/dev/null 2>&1; then
        _kill_pid_tree "$_SHOWCASE_PID" 2>/dev/null || true
      else
        kill "$_SHOWCASE_PID" 2>/dev/null || true
      fi
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done
  wait "$_SHOWCASE_PID" 2>/dev/null || true
  _SHOWCASE_PID=""
  # Clear any services the demo recording booted (fresh-serving-tree guarantee).
  kill_phase_servers 2>/dev/null || true
  if [[ "$PUSH_PER_ITER" == "true" ]]; then
    local _p
    for _p in reports runs README.md; do
      [[ -e "$REPO_ROOT/$_p" ]] && git -C "$REPO_ROOT" add -A -- "$_p" 2>/dev/null || true
    done
    if ! git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null; then
      if git -C "$REPO_ROOT" commit --quiet -m "chore(goal): iter ${_SHOWCASE_ITER} showcase artifacts (demo/summary/README/renders)" 2>/dev/null; then
        GIT_TERMINAL_PROMPT=0 git -C "$REPO_ROOT" push -u origin HEAD >/dev/null 2>&1 \
          || echo "[run-goal] Showcase commit push failed (non-blocking; the next iteration's push carries it)." >&2
      fi
    fi
  fi
}

# Tail an append-only state file to the last N lines, or return a placeholder
# if the file does not exist yet. Used to keep token usage flat as the goal
# session grows — agents only need the tail (last few entries), not the full
# file. The tail size is generous enough to cover the "last 3" / "last 5"
# entries the agents request, even when entries are multi-paragraph.
#
# The result is ALSO byte-capped (CHAIN_INLINE_TAIL_MAX_BYTES, default 48 KiB):
# a line cap alone let these inlined blocks grow one long line at a time until
# the assembled dispatch prompt crossed the 128 KiB execve per-argv-string cap
# (production: every dispatch from ~iteration 40 of a long session). When the
# cap bites, a marker line points the agent at the on-disk file — agents
# already receive those paths, so truncation loses nothing. The dispatch layer
# handles arbitrary prompt sizes regardless (lib/interactive-dispatch.sh,
# lib/quota-retry.sh); this cap stops the prompt bloat and token waste at the
# source.
#   _tail_or_placeholder <file> <max-lines> <placeholder>
_tail_or_placeholder() {
  local file="$1" max="$2" placeholder="$3"
  if [[ -f "$file" && -s "$file" ]]; then
    local cap="${CHAIN_INLINE_TAIL_MAX_BYTES:-49152}"
    local out
    out="$(tail -n "$max" "$file")"
    # Byte cap via bash substring, NOT `| tail -c`: uutils-coreutils tail -c
    # returns wrong sizes when reading a pipe (observed on 0.8.0), and bash
    # needs no extra process. LC_ALL=C makes ${#}/substring count bytes.
    local LC_ALL=C
    if (( ${#out} > cap )); then
      printf '[inline tail truncated to the last %s of %s bytes — full file on disk at: %s]\n' "$cap" "${#out}" "$file"
      printf '%s\n' "${out:${#out}-cap}"
    else
      printf '%s\n' "$out"
    fi
  else
    printf '%s\n' "$placeholder"
  fi
}

if [[ "$RESET" == "true" && -d "$GOAL_SESSION_DIR_LOCAL" ]]; then
  echo "[run-goal] --reset: removing existing $GOAL_SESSION_DIR_LOCAL"
  rm -rf "$GOAL_SESSION_DIR_LOCAL"
fi

# ── Validate goal.md ──────────────────────────────────────────────────────
validate_goal_file() {
  if [[ ! -f "$GOAL_FILE" ]]; then
    echo "Error: $GOAL_FILE not found." >&2
    echo "  Author it from templates/project-goal.md and include 'Must-have user journeys' + 'Anti-goals' sections." >&2
    exit 1
  fi

  if ! grep -q "^## Must-have user journeys" "$GOAL_FILE"; then
    echo "Error: $GOAL_FILE is missing the '## Must-have user journeys' section." >&2
    echo "  See templates/project-goal.md for the format. See .claude/anti-patterns/18-goal-journeys-anti-goals.md." >&2
    exit 1
  fi

  if ! grep -q "^## Anti-goals" "$GOAL_FILE"; then
    echo "Error: $GOAL_FILE is missing the '## Anti-goals' section." >&2
    echo "  See templates/project-goal.md for the format. See .claude/anti-patterns/18-goal-journeys-anti-goals.md." >&2
    exit 1
  fi

  if ! grep -E '^- \*\*J-[0-9]+:' "$GOAL_FILE" >/dev/null; then
    echo "Error: $GOAL_FILE 'Must-have user journeys' section has no journey entries." >&2
    echo "  Each journey MUST have an ID like '- **J-01: <name>**'. See templates/project-goal.md." >&2
    exit 1
  fi

  python3 - <<'PY' "$GOAL_FILE" || exit 1
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'^## Anti-goals\s*$(.*?)(^## |\Z)', text, re.MULTILINE | re.DOTALL)
if not m:
    print("Error: Anti-goals section parse failed.", file=sys.stderr); sys.exit(1)
body = m.group(1)
items = [ln for ln in body.splitlines() if ln.strip().startswith('-') and ln.strip() != '-']
non_placeholder = [ln for ln in items if 'TODO' not in ln and 'placeholder' not in ln.lower()]
if not non_placeholder:
    print("Error: Anti-goals section has no concrete entries (only placeholders or empty bullets).",
          file=sys.stderr)
    print("  See .claude/anti-patterns/18-goal-journeys-anti-goals.md for examples.", file=sys.stderr)
    sys.exit(1)
PY
}

# ── GitHub push-access preflight ──────────────────────────────────────────
# An autonomous loop that pushes every iteration must NOT stall mid-run waiting
# for a username/password when the GitHub HTTPS session expires. This runs once,
# before the loop, on both fresh-start and --resume. On failure it tries an
# interactive `gh auth login` (TTY only) and, if it still can't push, pauses the
# session as AWAITING_GITHUB_AUTH (resumable) — mirroring the blueprint gate.
preflight_github_access() {
  # Push access is only relevant if this session will push.
  [[ "$PUSH_PER_ITER" == "true" || "$AUTO_RELEASE" == "true" ]] || return 0
  if [[ "${CHAIN_SKIP_GITHUB_PREFLIGHT:-false}" == "true" ]]; then
    echo "[run-goal] CHAIN_SKIP_GITHUB_PREFLIGHT=true — skipping GitHub access preflight."
    return 0
  fi

  local rc=0
  check_git_push_access "$REPO_ROOT" || rc=$?   # '|| rc=$?' keeps set -e happy
  if [[ $rc -eq 0 ]]; then
    echo "[run-goal] GitHub push access: OK"
    return 0
  fi

  echo ""
  echo "════════════════════════════════════════════════════════════════════"
  echo "[run-goal] GitHub push access check FAILED (push-per-iter is on)."
  echo "════════════════════════════════════════════════════════════════════"
  if [[ $rc -eq 2 ]]; then
    echo "Reason: no 'origin' remote is configured in this repo."
  else
    echo "Reason: 'origin' did not authenticate (expired or missing credentials)."
  fi

  # Auto-relogin: only when interactive, gh is installed, and a remote exists.
  if [[ $rc -ne 2 && -t 0 && -t 1 ]] && command -v gh >/dev/null 2>&1; then
    echo "[run-goal] Launching 'gh auth login' to refresh your GitHub session..."
    if gh auth login && gh auth setup-git && check_git_push_access "$REPO_ROOT"; then
      echo "[run-goal] GitHub push access restored. Continuing."
      return 0
    fi
    echo "[run-goal] Still no push access after login." >&2
  fi

  # Could not auto-fix → pause gracefully (resumable), mirroring blueprint gate.
  python3 - <<PY
import json, datetime
d = json.load(open("$SESSION_JSON"))
d["status"] = "AWAITING_GITHUB_AUTH"
d["updated_at"] = datetime.datetime.now(datetime.UTC).isoformat().replace('+00:00','Z')
import os as _os, tempfile as _tf
_fd, _tmp = _tf.mkstemp(dir=_os.path.dirname("$SESSION_JSON") or ".", suffix=".sjtmp")
with _os.fdopen(_fd, "w") as _f:
    json.dump(d, _f, indent=2)
    _f.write("\n")
_os.replace(_tmp, "$SESSION_JSON")
PY
  record_telemetry_event "halt" '{"reason":"AWAITING_GITHUB_AUTH","detected_at_step":"preflight"}'
  echo ""
  echo "Fix it, then resume:"
  echo "  gh auth login          # refresh the GitHub session"
  echo "  gh auth setup-git      # let git use the gh credential for HTTPS push"
  [[ $rc -eq 2 ]] && echo "  (or) git remote add origin <url>"
  echo ""
  echo "Resume:  ./scripts/automation/run-goal.sh --resume --session-id $SESSION_ID"
  echo "Skip this check:  export CHAIN_SKIP_GITHUB_PREFLIGHT=true   (exotic credential setups)"
  echo "Run without pushing:  add --no-push-per-iter"
  explain_goal_status "AWAITING_GITHUB_AUTH" "$SESSION_ID" "$REPO_ROOT"
  echo "════════════════════════════════════════════════════════════════════"
  exit 0
}

# ── Disk-space preflight (REL-13) ─────────────────────────────────────────
# An autonomous loop must never die mid-run on ENOSPC/EDQUOT. The guard sweeps
# aggressively first (dead-pid run dirs, stale bench/judgment scratch, old
# pytest basetemps); only a CHAIN_TMP_ROOT filesystem that is STILL under the
# hard floor after sweeping pauses the session — resumable, like the GitHub
# preflight above. /tmp quota pressure alone never pauses (chain temp is
# relocated; leftovers there may be foreign files we cannot remove).
preflight_disk_space() {
  local rc=0
  chain_tmp_disk_guard --enforce || rc=$?
  [[ $rc -eq 2 ]] || return 0
  echo "[run-goal] Disk free below hard floor after automatic cleanup — pausing (AWAITING_DISK)."
  python3 - <<PY
import json, datetime
d = json.load(open("$SESSION_JSON"))
d["status"] = "AWAITING_DISK"
d["updated_at"] = datetime.datetime.now(datetime.UTC).isoformat().replace('+00:00','Z')
import os as _os, tempfile as _tf
_fd, _tmp = _tf.mkstemp(dir=_os.path.dirname("$SESSION_JSON") or ".", suffix=".sjtmp")
with _os.fdopen(_fd, "w") as _f:
    json.dump(d, _f, indent=2)
    _f.write("\n")
_os.replace(_tmp, "$SESSION_JSON")
PY
  record_telemetry_event "halt" '{"reason":"AWAITING_DISK","detected_at_step":"preflight"}'
  echo ""
  echo "Free disk space (or: ./scripts/automation/tmp-doctor.sh --aggressive), then resume:"
  echo "  ./scripts/automation/run-goal.sh --resume --session-id $SESSION_ID"
  explain_goal_status "AWAITING_DISK" "$SESSION_ID" "$REPO_ROOT"
  echo "════════════════════════════════════════════════════════════════════"
  exit 0
}

# ── Host-guard preflight + iteration gate (hardware protection) ────────────
# Origin: a mini-PC host hard-reset repeatedly under goal-mode load with
# NOTHING in the journal — instant power/VRM transient trips, invisible to
# sysstat's 10-minute cadence. When the project declares host caps
# (project-extensions/host-guard/host-guard.env), the engine must not run
# unprotected: verify the affinity wrap (top of this script) took effect and
# the 1 Hz hwmon forensics sampler is alive — auto-starting the sampler first
# (self-heal, like the disk guard's sweep), pausing (AWAITING_HOST_GUARD,
# resumable) only when self-heal fails. Absent or disabled host-guard.env ⇒
# no-op (framework stays project-neutral).
_host_guard_mask_width() { # "0-3,8-11" → 8; 0 when unparseable
  local list="${1:-}" n=0 part a b
  [[ -n "$list" ]] || { echo 0; return 0; }
  local -a parts=()
  IFS=',' read -ra parts <<< "$list"
  for part in "${parts[@]}"; do
    if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
      a="${part%-*}"; b="${part#*-}"
      if (( b >= a )); then n=$(( n + b - a + 1 )); fi
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      n=$(( n + 1 ))
    fi
  done
  echo "$n"
}
_host_guard_sampler_path() { # project-local copy wins; framework copy is the default
  local proj="$REPO_ROOT/project-extensions/host-guard/hwmon-log.sh"
  if [[ -f "$proj" ]]; then printf '%s' "$proj"; else printf '%s' "$SCRIPT_DIR/host-guard/hwmon-log.sh"; fi
}
_host_guard_latest_tctl() { # newest Tctl (°C) from the sampler csv; empty if missing/stale
  local csv="$REPO_ROOT/logs/hwmon/hwmon.csv" mtime line t
  [[ -f "$csv" ]] || return 0
  mtime=$(stat -c %Y "$csv" 2>/dev/null || echo 0)
  (( EPOCHSECONDS - mtime <= 15 )) || return 0
  line=$(tail -n 1 "$csv" 2>/dev/null || true)
  t="${line#*,}"; t="${t%%,*}"
  [[ "$t" =~ ^[0-9]+$ ]] && printf '%s' "$t"
  return 0
}
_host_guard_pause() { # $1 reason, $2 detected_at_step — pause AWAITING_HOST_GUARD (resumable) and exit
  local reason="$1" step="${2:-preflight}"
  echo "[run-goal] Host-guard check failed — pausing (AWAITING_HOST_GUARD)."
  echo "[run-goal]   reason: $reason"
  python3 - <<PY
import json, datetime
d = json.load(open("$SESSION_JSON"))
d["status"] = "AWAITING_HOST_GUARD"
d["updated_at"] = datetime.datetime.now(datetime.UTC).isoformat().replace('+00:00','Z')
import os as _os, tempfile as _tf
_fd, _tmp = _tf.mkstemp(dir=_os.path.dirname("$SESSION_JSON") or ".", suffix=".sjtmp")
with _os.fdopen(_fd, "w") as _f:
    json.dump(d, _f, indent=2)
    _f.write("\n")
_os.replace(_tmp, "$SESSION_JSON")
PY
  record_telemetry_event "halt" "$(printf '{"reason":"AWAITING_HOST_GUARD","detected_at_step":"%s"}' "$step")"
  echo ""
  echo "Fix the host-guard issue (project-extensions/host-guard/README.md), then resume:"
  echo "  ./scripts/automation/run-goal.sh --resume --session-id $SESSION_ID"
  explain_goal_status "AWAITING_HOST_GUARD" "$SESSION_ID" "$REPO_ROOT"
  echo "════════════════════════════════════════════════════════════════════"
  exit 0
}
preflight_host_guard() {
  local hg_env="$REPO_ROOT/project-extensions/host-guard/host-guard.env"
  [[ -f "$hg_env" ]] || return 0
  # shellcheck disable=SC1090
  source "$hg_env"
  [[ "${HOST_GUARD_ENABLED:-0}" == "1" ]] || return 0
  local sampler fail_reason=""
  sampler="$(_host_guard_sampler_path)"

  # 1. Forensics sampler alive + csv fresh (self-heal: try to start it first).
  if [[ -f "$sampler" ]]; then
    if ! HOST_GUARD_ROOT="$REPO_ROOT" bash "$sampler" status >/dev/null 2>&1; then
      echo "[run-goal] host-guard: hwmon sampler not running — auto-starting."
      HOST_GUARD_ROOT="$REPO_ROOT" bash "$sampler" start || true
      sleep 2
      HOST_GUARD_ROOT="$REPO_ROOT" bash "$sampler" status >/dev/null 2>&1 \
        || fail_reason="hwmon sampler failed to start (try: bash $sampler start)"
    fi
  else
    fail_reason="sampler script missing: $sampler"
  fi

  # 2. Affinity wrap took effect: REAL allowed CPUs ≤ declared mask width.
  # Read Cpus_allowed_list, not `nproc` — nproc honors OMP_NUM_THREADS, so a
  # BLAS thread-cap env var would fake a confined engine (false PASS).
  if [[ -z "$fail_reason" ]]; then
    local width allowed_list allowed_n
    width=$(_host_guard_mask_width "${HOST_GUARD_CPU_LIST:-}")
    allowed_list=$(awk -F'\t' '/^Cpus_allowed_list/{print $2}' /proc/self/status 2>/dev/null)
    allowed_n=$(_host_guard_mask_width "$allowed_list")
    if (( width > 0 && allowed_n > width )); then
      fail_reason="engine not confined to HOST_GUARD_CPU_LIST=${HOST_GUARD_CPU_LIST:-} (Cpus_allowed_list=$allowed_list = $allowed_n CPUs > mask width $width — the taskset wrap did not take effect)"
    fi
  fi

  # 3. Launcher cap blocks — project-declared list (HOST_GUARD_MARKER_FILES,
  # space-separated repo-relative paths); enforced only once the project's
  # launcher caps have landed (HOST_GUARD_REQUIRE_MARKERS=1).
  if [[ -z "$fail_reason" && "${HOST_GUARD_REQUIRE_MARKERS:-0}" == "1" && -n "${HOST_GUARD_MARKER_FILES:-}" ]]; then
    local lsc
    for lsc in ${HOST_GUARD_MARKER_FILES}; do
      if [[ -f "$REPO_ROOT/$lsc" ]] && ! grep -q "HOST-GUARD" "$REPO_ROOT/$lsc"; then
        fail_reason="launcher $lsc lost its HOST-GUARD cap block (host-guard regression)"
        break
      fi
    done
  fi

  [[ -n "$fail_reason" ]] || return 0
  _host_guard_pause "$fail_reason" "preflight"
}
host_guard_iteration_gate() {
  # Top-of-loop, never mid-iteration. (a) thermal cooldown: when the hwmon csv
  # is fresh and Tctl ≥ HOST_GUARD_TCTL_PAUSE, wait until ≤ _RESUME (bounded by
  # _MAX_WAIT — then proceed loudly; the gate is defense-in-depth, not a halt).
  # (b) interactive pump confinement: the systemd/taskset self-wrap cannot
  # confine agents dispatched INSIDE the foreground CLI session, so when
  # HOST_GUARD_REQUIRE_PUMP_CONFINED=1 verify the pump process's own cpuset and
  # pause (resumable) if it is wider than the declared mask.
  local hg_env="$REPO_ROOT/project-extensions/host-guard/host-guard.env"
  [[ -f "$hg_env" ]] || return 0
  # shellcheck disable=SC1090
  source "$hg_env"
  [[ "${HOST_GUARD_ENABLED:-0}" == "1" ]] || return 0

  local pause_c="${HOST_GUARD_TCTL_PAUSE:-90}" resume_c="${HOST_GUARD_TCTL_RESUME:-80}"
  local poll="${HOST_GUARD_TCTL_POLL:-15}" max_wait="${HOST_GUARD_TCTL_MAX_WAIT:-1800}"
  local waited=0 tctl
  while :; do
    tctl="$(_host_guard_latest_tctl)"
    [[ "$tctl" =~ ^[0-9]+$ ]] || break   # no fresh telemetry → nothing to gate on
    if (( waited == 0 )); then
      if (( tctl < pause_c )); then break; fi
      echo "[run-goal] host-guard: Tctl ${tctl}°C ≥ ${pause_c}°C — cooling down before the next iteration (resumes < ${resume_c}°C)."
      record_telemetry_event "host_guard_cooldown" "$(printf '{"tctl_c":%s}' "$tctl")"
    else
      if (( tctl <= resume_c )); then
        echo "[run-goal] host-guard: cooled to ${tctl}°C after ${waited}s — continuing."
        break
      fi
      if (( waited >= max_wait )); then
        echo "[run-goal] host-guard: still ${tctl}°C after ${waited}s (max ${max_wait}s) — continuing anyway; check cooling."
        break
      fi
    fi
    sleep "$poll"; waited=$(( waited + poll ))
  done

  if [[ "${HOST_GUARD_REQUIRE_PUMP_CONFINED:-0}" == "1" && "${AGENT_BACKEND:-}" == "interactive" ]]; then
    local hb="${CHAIN_DISPATCH_DIR:-$GOAL_SESSION_DIR_LOCAL/dispatch}/.pump-alive"
    local pump_pid="" hb_age=999999 target="" width allowed_list allowed_n
    if [[ -f "$hb" ]]; then
      hb_age=$(( EPOCHSECONDS - $(stat -c %Y "$hb" 2>/dev/null || echo 0) ))
      pump_pid=$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' "$hb" 2>/dev/null | head -n 1)
    fi
    # Verification handle: the CLI session root captured at engine launch wins
    # (it outlives short-lived heartbeat writers); else the live heartbeat pid.
    if [[ -n "${HOST_GUARD_PUMP_ROOT_PID:-}" && -r "/proc/${HOST_GUARD_PUMP_ROOT_PID}/status" ]]; then
      target="$HOST_GUARD_PUMP_ROOT_PID"
    elif [[ -n "$pump_pid" && "$hb_age" -le "${HOST_GUARD_PUMP_HB_FRESH:-180}" && -r "/proc/$pump_pid/status" ]]; then
      target="$pump_pid"
    fi
    if [[ -n "$target" ]]; then
      width=$(_host_guard_mask_width "${HOST_GUARD_CPU_LIST:-}")
      allowed_list=$(awk -F'\t' '/^Cpus_allowed_list/{print $2}' "/proc/$target/status" 2>/dev/null)
      allowed_n=$(_host_guard_mask_width "$allowed_list")
      if (( width > 0 && allowed_n > width )); then
        # Self-heal first: confine the RUNNING session in place — scope
        # adoption for memory/task/quota ceilings + taskset for the hard CPU
        # mask. No relaunch required; the host-guard-exec.sh wrapper remains
        # the belt-and-braces option (adds BLAS env caps from birth).
        # HOST_GUARD_ADOPT=0 skips the self-heal and pauses immediately.
        if [[ "${HOST_GUARD_ADOPT:-1}" == "1" ]]; then
          echo "[run-goal] host-guard: pump (pid $target) unconfined (Cpus_allowed_list=$allowed_list) — auto-confining in place."
          HOST_GUARD_ROOT="$REPO_ROOT" bash "$SCRIPT_DIR/host-guard-adopt.sh" --cli-root-of "$target" || true
          allowed_list=$(awk -F'\t' '/^Cpus_allowed_list/{print $2}' "/proc/$target/status" 2>/dev/null)
          allowed_n=$(_host_guard_mask_width "$allowed_list")
        fi
        if (( allowed_n > width )); then
          write_session_summary "AWAITING_HOST_GUARD" "$CURRENT_ITER"
          _host_guard_pause "interactive pump (pid $target) is unconfined (Cpus_allowed_list=$allowed_list = $allowed_n CPUs > mask width $width) and in-place auto-confinement did not take — relaunch the pump CLI via scripts/automation/host-guard-exec.sh (e.g. 'scripts/automation/host-guard-exec.sh claude'), or set HOST_GUARD_REQUIRE_PUMP_CONFINED=0" "iteration_gate"
        fi
        record_telemetry_event "host_guard_adopt" "$(printf '{"pid":%s,"cpus":"%s"}' "$target" "$allowed_list")"
        echo "[run-goal] host-guard: pump (pid $target) confined to $allowed_list."
      fi
    elif [[ "$hb_age" -le "${HOST_GUARD_PUMP_HB_FRESH:-180}" ]]; then
      # A live pump we cannot even identify (no pid= line in the heartbeat AND
      # no CLI root captured at launch): loud pause, never a silent bypass.
      _host_guard_pause "cannot verify pump confinement: no usable pump pid ($hb has no pid= line and no CLI root was captured at engine launch) — re-enable the pump ident or set HOST_GUARD_REQUIRE_PUMP_CONFINED=0" "iteration_gate"
    fi
  fi
  return 0
}

# ── Preflight doctor (REL-2) ──────────────────────────────────────────────
# Advisory BY CONSTRUCTION: the doctor observes and reports; it must never be
# able to stop a session (a broken doctor gating the engine would invert its
# purpose). Every failure path here — missing script, crash, nonzero exit, a
# hang (bounded by timeout when available) — degrades to a log line and
# return 0. Strict gating exists only as the doctor CLI's own --strict-doctor
# flag, never as engine behavior. Knob: CHAIN_DOCTOR (default true).
# CHAIN_DOCTOR_BIN overrides the script path (test seam).
run_doctor_preflight() {
  if [[ "${CHAIN_DOCTOR:-true}" != "true" ]]; then
    echo "[run-goal] CHAIN_DOCTOR=${CHAIN_DOCTOR:-false} — preflight doctor skipped."
    return 0
  fi
  local _doctor="${CHAIN_DOCTOR_BIN:-$SCRIPT_DIR/doctor.sh}"
  if [[ ! -f "$_doctor" ]]; then
    echo "[run-goal] Preflight doctor not found ($_doctor) — skipping (advisory)."
    return 0
  fi
  echo "[run-goal] Preflight doctor (advisory — WARN/FAIL rows never gate; CHAIN_DOCTOR=false to skip):"
  local _out="" _rc=0 _runner=""
  command -v timeout >/dev/null 2>&1 && _runner="timeout 90"
  # shellcheck disable=SC2086  # intentional word-split for the optional runner
  _out="$(CHAIN_DOCTOR_AMBIENT="${_CHAIN_AMBIENT_AT_START-}" $_runner bash "$_doctor" 2>&1)" || _rc=$?
  [[ -n "$_out" ]] && printf '%s\n' "$_out"
  if [[ "$_rc" -ne 0 ]]; then
    echo "[run-goal] doctor exited rc=$_rc — continuing anyway (the doctor is advisory by construction)."
    return 0
  fi
  local _counts
  _counts="$(printf '%s\n' "$_out" | grep -m1 -o 'pass=[0-9]* warn=[0-9]* fail=[0-9]* skip=[0-9]*' || true)"
  echo "[run-goal] doctor: ${_counts:-counts unavailable} — advisory only, see table above."
  return 0
}

# ── Intent checkpoint review packet (NEED-7) ──────────────────────────────
# Assembles runs/goal-session-<sid>/intent-review.md DETERMINISTICALLY — pure
# read/format of existing artifacts, no model dispatch. Every section fails
# safe to a placeholder so the pause can never crash the engine.
assemble_intent_review() {
  local digest story ledger_tail blocking irreversible latest_iter_md latest_iter_html links
  digest="$(python3 "$SCRIPT_DIR/lib/goal_gate.py" digest "$JOURNEY_HISTORY" 2>/dev/null \
    || echo "(journey digest unavailable — read $JOURNEY_HISTORY)")"
  story="$(cat "$GOAL_SESSION_DIR_LOCAL/state/project-story.md" 2>/dev/null \
    || echo "(no project story yet — the first iterations have not written one)")"
  ledger_tail="$(_tail_or_placeholder "$ASSUMPTIONS_FILE" 60 "(no assumptions recorded yet)")"
  # Still-failing journeys via goal_gate's own status semantics
  # (PASSING_STATUSES), so this list can never drift from the gates.
  blocking="$(python3 - "$SCRIPT_DIR/lib/goal_gate.py" "$JOURNEY_HISTORY" <<'PY' 2>/dev/null || echo "(journey history unavailable)"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("goal_gate", sys.argv[1])
gg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gg)
data = gg._load_history(sys.argv[2])
if data is None:
    print("(journey history unavailable)")
else:
    rows = [
        f"- **{jid}** ({j.get('name', '') if isinstance(j, dict) else ''}): "
        f"{j.get('status', '?') if isinstance(j, dict) else '?'}"
        for jid, j in sorted(data["journeys"].items())
        if not isinstance(j, dict) or j.get("status") not in gg.PASSING_STATUSES
    ]
    print("\n".join(rows) if rows else "(none — every journey currently passes)")
PY
)"
  # Hard-to-reverse assumptions: ledger blocks whose **Reversible:** line says no.
  irreversible="$(python3 - "$ASSUMPTIONS_FILE" <<'PY' 2>/dev/null || echo "(assumption ledger unreadable)"
import re, sys
from pathlib import Path
p = Path(sys.argv[1])
if not p.exists():
    print("(none recorded)")
    raise SystemExit
out = []
for block in re.split(r"(?m)^##\s+", p.read_text(encoding="utf-8"))[1:]:
    if not re.search(r"(?mi)^\*\*Reversible:\*\*\s*no\b", block):
        continue
    header = block.splitlines()[0].strip()
    amb = re.search(r"(?mi)^\*\*Ambiguity:\*\*\s*(.+)$", block)
    chose = re.search(r"(?mi)^\*\*We chose:\*\*\s*(.+)$", block)
    out.append(
        f"- {header} — {amb.group(1).strip() if amb else '(ambiguity unrecorded)'}"
        f" → chose: {chose.group(1).strip() if chose else '(choice unrecorded)'}"
    )
print("\n".join(out) if out else "(none — all recorded assumptions are reversible)")
PY
)"
  latest_iter_md="$(ls -1 "$REPO_ROOT"/reports/phase-goal-"${SESSION_ID}"-iter-*-iteration-summary.md 2>/dev/null | sort -V | tail -1 || true)"
  links="- Session index (HTML): file://$REPO_ROOT/reports/goal-session-${SESSION_ID}-index.html"
  if [[ -n "$latest_iter_md" ]]; then
    links+=$'\n'"- Latest iteration summary: ${latest_iter_md#"$REPO_ROOT"/}"
    latest_iter_html="${latest_iter_md%-iteration-summary.md}-summary.html"
    [[ -f "$latest_iter_html" ]] && links+="  (HTML: ${latest_iter_html#"$REPO_ROOT"/})"
  else
    links+=$'\n'"- Latest iteration summary: (none written yet)"
  fi
  cat > "$INTENT_REVIEW_FILE" <<EOF
# Intent Review — session ${SESSION_ID} (paused before iteration ${CURRENT_ITER})

Generated deterministically by run-goal.sh (\`--intent-checkpoint\` /
\`--intent-checkpoint-at\`) — no model wrote this. The engine paused so YOU can
check the product is becoming what you wanted before more gets built on it.

**Progress:** ${_intent_passing} of ${_intent_total} Must-have journeys pass.

## Journey digest

\`\`\`
${digest}
\`\`\`

## Where the product stands (project story)

${story}

## Recent assumptions (ledger tail)

${ledger_tail}

## Full reports

${links}

## Targeted questions

1. **Still-failing journeys — is this still what you want built next?**

${blocking}

2. **Hard-to-reverse assumptions (\`Reversible: no\`) — veto any wrong call NOW:**

${irreversible}

## How to respond

- Direction is right → just resume; no other action needed:
  \`./scripts/automation/run-goal.sh --resume --session-id ${SESSION_ID}\`
- Drifting → edit \`docs/goal.md\` (journeys / anti-goals) BEFORE resuming;
  future iterations plan from your edited text.
- This checkpoint fires once per session; resuming acknowledges it.
EOF
}

# ── Session init / load ───────────────────────────────────────────────────
mkdir -p "$GOAL_SESSION_DIR_LOCAL/state"

if [[ -f "$SESSION_JSON" ]]; then
  if [[ "$RESUME" != "true" ]]; then
    echo "Error: session $SESSION_ID already exists at $GOAL_SESSION_DIR_LOCAL" >&2
    echo "  Use --resume to continue, or --reset to start fresh." >&2
    exit 1
  fi
  CURRENT_ITER=$(python3 -c "import json,sys; print(json.load(open('$SESSION_JSON')).get('current_iter', 0))")
  PRIOR_STATUS=$(python3 -c "import json,sys; print(json.load(open('$SESSION_JSON')).get('status', 'unknown'))")
  echo "[run-goal] Resuming session '$SESSION_ID' from iter $CURRENT_ITER (prior status: $PRIOR_STATUS)"

  if [[ "$PRIOR_STATUS" == "REGRESSION_HALT" && "$ACK_REGRESSION" != "true" ]]; then
    echo "Error: prior run halted with REGRESSION_HALT." >&2
    echo "  Review the regression in runs/goal-session-${SESSION_ID}/iter-*/eval.md," >&2
    echo "  fix the regressed journey, then re-run with --acknowledge-regression." >&2
    exit 1
  fi
  # Read push config from session.json and decide the effective value, taking
  # the explicit-CLI-flag tristate into account.
  #
  # Resolution table:
  #
  #   PUSH_FLAG_USER  | session push_per_iter      | result
  #   ────────────────┼────────────────────────────┼─────────────────────────────
  #   "no"            | any                        | OFF for this run (warning if session was on)
  #   "yes"           | true                       | continuing (session was already pushing)
  #   "yes"           | false / missing            | opting-in
  #   "default"       | true                       | continuing
  #   "default"       | false (key present)        | OFF (respect explicit prior choice)
  #   "default"       | missing (pre-feature sess) | opting-in (use new default-on)
  _session_push_key_present=$(python3 -c "import json; print('true' if 'push_per_iter' in json.load(open('$SESSION_JSON')) else 'false')")
  _session_push=$(python3 -c "import json; print('true' if json.load(open('$SESSION_JSON')).get('push_per_iter') else 'false')")
  _session_push_branch=$(python3 -c "import json; print(json.load(open('$SESSION_JSON')).get('push_branch') or '')")
  RESUME_PUSH_MODE="off"           # off | continuing | opting-in

  if [[ "$PUSH_FLAG_USER" == "no" ]]; then
    PUSH_PER_ITER="false"
    PUSH_BRANCH=""
    if [[ "$_session_push" == "true" ]]; then
      echo "[run-goal] push-per-iter: --no-push-per-iter passed; disabling for this run despite session being on. (Branch '$_session_push_branch' is left untouched.)"
    fi
  elif [[ "$_session_push" == "true" ]]; then
    PUSH_PER_ITER="true"
    PUSH_BRANCH="$_session_push_branch"
    RESUME_PUSH_MODE="continuing"
  elif [[ "$PUSH_FLAG_USER" == "yes" ]]; then
    PUSH_PER_ITER="true"
    [[ -z "$PUSH_BRANCH" ]] && PUSH_BRANCH="goal/$SESSION_ID"
    RESUME_PUSH_MODE="opting-in"
    echo "[run-goal] push-per-iter: enabling on resume for session that wasn't pushing previously."
  elif [[ "$_session_push_key_present" == "true" ]]; then
    # Session has explicit push_per_iter: false; default-CLI doesn't override.
    PUSH_PER_ITER="false"
    PUSH_BRANCH=""
  else
    # Pre-feature session (key never written) AND no CLI flag → adopt the new default.
    PUSH_PER_ITER="true"
    [[ -z "$PUSH_BRANCH" ]] && PUSH_BRANCH="goal/$SESSION_ID"
    RESUME_PUSH_MODE="opting-in"
    echo "[run-goal] push-per-iter: defaulting ON for resume of pre-feature session (no prior choice recorded)."
    echo "  Pass --no-push-per-iter on the next resume if you don't want this."
  fi
  RUN_MODE="resume"
else
  validate_goal_file
  # Advisory quality lint (NEED-3): prints warnings, NEVER blocks the engine.
  if [[ "${CHAIN_GOAL_LINT:-true}" == "true" ]]; then
    python3 "$SCRIPT_DIR/lib/goal_lint.py" "$GOAL_FILE" || true
  fi
  CURRENT_ITER=0
  PRIOR_STATUS="new"
  echo "[run-goal] Initializing new session: $SESSION_ID"
  # Resolve push_branch default before persisting
  if [[ "$PUSH_PER_ITER" == "true" && -z "$PUSH_BRANCH" ]]; then
    PUSH_BRANCH="goal/$SESSION_ID"
  fi
  python3 - <<PY
import json, datetime
data = {
  "session_id": "$SESSION_ID",
  "started_at": datetime.datetime.now(datetime.UTC).isoformat().replace('+00:00', 'Z'),
  "current_iter": 0,
  "cli": "${CHAIN_CLI:-claude}",
  "agent_backend": "$AGENT_BACKEND",
  "halt_config": {
    "max_iterations": $MAX_ITER,
    "stall_window": $STALL_WINDOW,
    "regression_halt": True
  },
  "status": "in_progress",
  "last_verdict": None,
  "next_depth": "lean",
  "auto_release": $( [[ "$AUTO_RELEASE" == "true" ]] && echo "True" || echo "False" ),
  "push_per_iter": $( [[ "$PUSH_PER_ITER" == "true" ]] && echo "True" || echo "False" ),
  "push_branch": "$PUSH_BRANCH"
}
import os
with open("$SESSION_JSON", "w") as f:
  json.dump(data, f, indent=2); f.write("\n")
PY
  echo '{"journeys":{},"anti_goal_violations":[],"updated_at":""}' > "$JOURNEY_HISTORY"
  : > "$EVALUATOR_LOG"
  cat > "$LESSONS_FILE" <<EOF
# Goal Session ${SESSION_ID} — Lessons Learned

Append-only ledger of takeaways from prior iterations. The goal-evaluator
appends one entry per iteration; the goal-decomposer reads this file before
planning each iteration to avoid repeating known pitfalls.

Each entry should be 1-3 sentences capturing a non-obvious lesson — surprising
failures, regression triggers, or decisions that worked well. Avoid
restating the verdict (the evaluator-log.md already does that).
EOF
  RUN_MODE="new"
fi

# New sessions get a default iteration cap (a fail-open loop with a
# never-halting evaluator previously ran unbounded). --max-iter always wins,
# and an explicit --max-iter 0 keeps a session unlimited. Resume honors the
# value already stored in session.json rather than silently resetting it.
if [[ "$RUN_MODE" == "new" && "$MAX_ITER_EXPLICIT" != "true" ]]; then
  MAX_ITER=60
  echo "[run-goal] Default iteration cap: $MAX_ITER (override with --max-iter N; 0 = unlimited)."
fi

# Persist halt config; also persist the resolved push_per_iter / push_branch
# values so a subsequent resume picks them up (key may have been absent in
# older sessions that pre-date the per-iter push feature).
python3 - <<PY
import json
d = json.load(open("$SESSION_JSON"))
d.setdefault("halt_config", {})
if "$RUN_MODE" == "new" or "$MAX_ITER_EXPLICIT" == "true":
    d["halt_config"]["max_iterations"] = $MAX_ITER
else:
    d["halt_config"].setdefault("max_iterations", $MAX_ITER)
d["halt_config"]["stall_window"] = $STALL_WINDOW
if $( [[ "$AUTO_RELEASE" == "true" ]] && echo "True" || echo "False" ):
  d["auto_release"] = True
d["push_per_iter"] = $( [[ "$PUSH_PER_ITER" == "true" ]] && echo "True" || echo "False" )
d["push_branch"] = "$PUSH_BRANCH"
d["agent_backend"] = "$AGENT_BACKEND"
if "$RUN_MODE" == "resume" and d.get("status") in ("REGRESSION_HALT", "AWAITING_BLUEPRINT_APPROVAL", "AWAITING_PUMP", "AWAITING_INTENT_REVIEW", "AWAITING_GITHUB_AUTH", "AWAITING_DISK", "AWAITING_HOST_GUARD"):
  d["status"] = "in_progress"
import os as _os, tempfile as _tf
_fd, _tmp = _tf.mkstemp(dir=_os.path.dirname("$SESSION_JSON") or ".", suffix=".sjtmp")
with _os.fdopen(_fd, "w") as _f:
    json.dump(d, _f, indent=2)
    _f.write("\n")
_os.replace(_tmp, "$SESSION_JSON")
PY

# The effective cap is whatever session.json now holds (resume may have kept a
# stored value that differs from this invocation's $MAX_ITER default).
MAX_ITER=$(python3 -c "import json; print(json.load(open('$SESSION_JSON')).get('halt_config', {}).get('max_iterations', 0))" 2>/dev/null || echo "$MAX_ITER")

# Resuming from a blueprint-approval pause: the human has reviewed (and possibly
# edited) state/blueprint.md. Treat the act of resuming as approval, and clear any
# structural re-approval request so the loop proceeds.
if [[ "$RUN_MODE" == "resume" && "$PRIOR_STATUS" == "AWAITING_BLUEPRINT_APPROVAL" ]]; then
  echo "[run-goal] Resuming from blueprint approval — treating your review of $BLUEPRINT_FILE as approval."
  touch "$BLUEPRINT_APPROVED"
  rm -f "$BLUEPRINT_REAPPROVAL"
fi

# Resuming from an intent-review pause: the human has read intent-review.md
# (and possibly edited docs/goal.md). Resuming IS the acknowledgment — touch
# the marker so the checkpoint never fires again this session.
if [[ "$RUN_MODE" == "resume" && "$PRIOR_STATUS" == "AWAITING_INTENT_REVIEW" ]]; then
  echo "[run-goal] Resuming from intent review — acknowledged; the checkpoint will not fire again this session."
  touch "$INTENT_REVIEW_DONE"
fi

# ── Session-start condensation of append-only knowledge files (TOKEN-6) ───
# Protocol §4: when lessons.md / assumptions.md exceed ~200 lines, the
# deterministic helper moves entries older than the newest 5 iterations to
# <file>.archive.md, keeping §2 rule-format lines in place. Warn-only: a
# condense failure NEVER gates the engine. `.claude/` files are refused by
# condense.sh itself (--human, dedicated commit — structural, not this knob).
if [[ "${CHAIN_AUTO_CONDENSE:-true}" == "true" ]]; then
  for _condense_f in "$LESSONS_FILE" "$ASSUMPTIONS_FILE"; do
    if [[ -f "$_condense_f" && "$(wc -l < "$_condense_f")" -gt 200 ]]; then
      if _condense_out="$(bash "$SCRIPT_DIR/lib/condense.sh" "$_condense_f" 2>/dev/null)"; then
        echo "[run-goal] $(printf '%s\n' "$_condense_out" | tail -1)"
      else
        echo "[run-goal] WARN: condense.sh failed for $_condense_f — continuing (warn-only)" >&2
      fi
    fi
  done
  unset _condense_f _condense_out
fi

# ── Export shared env for invoked agents ──────────────────────────────────
export GOAL_SESSION_ID="$SESSION_ID"
export GOAL_SESSION_DIR="$GOAL_SESSION_DIR_LOCAL"

# Interactive dispatch backend: export the backend selector + the file-channel
# directory so every nested script (run-phase.sh, goal-iter-lean.sh, *-phase.sh)
# routes its agent calls through _interactive_invoke (see lib/quota-retry.sh and
# lib/interactive-dispatch.sh). Clear any stale channel files from a prior,
# interrupted run so the pump and engine start from a clean channel.
if [[ "$INTERACTIVE" == "true" ]]; then
  export CHAIN_AGENT_BACKEND="interactive"
  export CHAIN_DISPATCH_DIR="$GOAL_SESSION_DIR_LOCAL/dispatch"
  mkdir -p "$CHAIN_DISPATCH_DIR"
  rm -f "$CHAIN_DISPATCH_DIR"/req.* "$CHAIN_DISPATCH_DIR"/*.res "$CHAIN_DISPATCH_DIR"/*.started "$CHAIN_DISPATCH_DIR/.awaiting-pump" 2>/dev/null || true
  # Seed the pump heartbeat FRESH at launch. A stale .pump-alive surviving from
  # a prior session made the engine's first dispatch race the pump's first
  # await call: if the engine won, Tier A read an hours-old mtime and aborted
  # with "pump heartbeat stale" before the pump ever beat (the bug users worked
  # around by manually pre-touching the file). Seeding (not deleting) keeps the
  # Tier A abort armed for a pump that genuinely never starts.
  touch "$CHAIN_DISPATCH_DIR/.pump-alive"
  echo "[run-goal] Interactive dispatch backend ON — agents run as subagents in the foreground session (the pump)."
  echo "[run-goal]   Dispatch channel: $CHAIN_DISPATCH_DIR"
fi

# Auto-enable replay/time-travel trace capture unless the user opts out.
# Each successful claude invocation appends a record to <session>/trace/trace.jsonl
# (see lib/quota-retry.sh::_trace_record_invocation and lib/replay_trace.py).
if [[ "${CHAIN_DISABLE_TRACE:-false}" != "true" && -z "${CHAIN_TRACE_DIR:-}" ]]; then
  mkdir -p "$GOAL_SESSION_DIR_LOCAL/trace"
  export CHAIN_TRACE_DIR="$GOAL_SESSION_DIR_LOCAL/trace"
fi

# ── Push-per-iter: branch lifecycle ──────────────────────────────────────
# When push_per_iter is on, all iter commits land on a single per-session
# feature branch (default: goal/<sid>). New session creates the branch from
# current HEAD; resume switches to it (errors if missing).
if [[ "$PUSH_PER_ITER" == "true" ]]; then
  if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "Error: --push-per-iter requires a git repository, but $REPO_ROOT is not one." >&2
    exit 1
  fi
  if [[ -z "$PUSH_BRANCH" ]]; then
    # Belt-and-suspenders: the new-session block already defaults this; on
    # resume an empty value means session was created with push_per_iter=true
    # but somehow no branch — fall back to the default name.
    PUSH_BRANCH="goal/$SESSION_ID"
  fi
  _current_branch=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  _branch_exists=false
  if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$PUSH_BRANCH"; then
    _branch_exists=true
  fi

  if [[ "$RUN_MODE" == "new" ]]; then
    if [[ "$_branch_exists" == "true" ]]; then
      echo "Error: branch '$PUSH_BRANCH' already exists. Pick another name with --push-branch <name>, or delete the existing branch." >&2
      exit 1
    fi
    if ! git -C "$REPO_ROOT" checkout -b "$PUSH_BRANCH" >/dev/null 2>&1; then
      echo "Error: failed to create branch '$PUSH_BRANCH'." >&2
      exit 1
    fi
    echo "[run-goal] push-per-iter: created and switched to branch '$PUSH_BRANCH'."
  else
    # Resume — branch handling depends on whether the session was already
    # pushing or we're opting in mid-session via --push-per-iter.
    if [[ "$_branch_exists" == "true" ]]; then
      # Branch is there. Switch if we aren't already on it.
      if [[ "$_current_branch" != "$PUSH_BRANCH" ]]; then
        if ! git -C "$REPO_ROOT" checkout "$PUSH_BRANCH" >/dev/null 2>&1; then
          echo "Error: failed to switch to branch '$PUSH_BRANCH'. Working tree may have uncommitted changes." >&2
          exit 1
        fi
      fi
      if [[ "$RESUME_PUSH_MODE" == "opting-in" ]]; then
        echo "[run-goal] push-per-iter: opted in mid-session; joined existing branch '$PUSH_BRANCH'."
      else
        echo "[run-goal] push-per-iter: switched to branch '$PUSH_BRANCH'."
      fi
    else
      # Branch missing on resume.
      if [[ "$RESUME_PUSH_MODE" == "opting-in" ]]; then
        # User just enabled push-per-iter on a session that wasn't pushing
        # before — create the branch from current HEAD. Iter commits will
        # accumulate from this point forward; prior iters already landed on
        # whatever branch the session was previously running against.
        if ! git -C "$REPO_ROOT" checkout -b "$PUSH_BRANCH" >/dev/null 2>&1; then
          echo "Error: failed to create branch '$PUSH_BRANCH'." >&2
          exit 1
        fi
        echo "[run-goal] push-per-iter: opted in mid-session; created branch '$PUSH_BRANCH' from current HEAD."
      else
        # Session was previously pushing to this branch — its disappearance
        # is a real anomaly, not something we should silently recover from.
        echo "Error: cannot resume — branch '$PUSH_BRANCH' is missing locally." >&2
        echo "  The session was created with push-per-iter on this branch, but it no longer exists." >&2
        echo "  Either restore the branch (git fetch + git checkout -b) or start a fresh session with --reset." >&2
        exit 1
      fi
    fi
  fi
fi

# Reclaim this project's canonical offset ports before assigning them. An
# orphaned dev server from a previous iteration squatting 3000+off / 8000+off
# would otherwise push _find_free_port onto a neighbour port — the whole session
# then drifts (e.g. the demo polls 3836 while the live app is on 3835) and the
# walkthrough is wrongly SKIPPED. No-op when CHAIN_*_PORT are already pinned.
reclaim_canonical_phase_ports
ensure_phase_ports

# ── Telemetry: session_start ──────────────────────────────────────────────
record_telemetry_event "session_start" "$(jq -cn --arg m "$RUN_MODE" --argjson mi $MAX_ITER --argjson sw $STALL_WINDOW --argjson ar "$( [[ "$AUTO_RELEASE" == "true" ]] && echo true || echo false )" '{mode:$m, max_iterations:$mi, stall_window:$sw, auto_release:$ar}' 2>/dev/null || printf '{"mode":"%s","max_iterations":%d,"stall_window":%d}' "$RUN_MODE" "$MAX_ITER" "$STALL_WINDOW")"

# ── Halt detection helpers ────────────────────────────────────────────────
SESSION_START_EPOCH=$(date +%s)
# Exported so child pipelines (run-phase.sh, goal-iter-lean.sh) and the sourced
# quota-retry.sh can bump it from their own shells (SPEED-13).
export QUOTA_PAUSE_COUNT_FILE="$GOAL_SESSION_DIR_LOCAL/.quota-pause-count"
[[ -f "$QUOTA_PAUSE_COUNT_FILE" ]] || echo "0" > "$QUOTA_PAUSE_COUNT_FILE"

journey_history_hash() {
  # Hash ONLY stall-relevant fields. The evaluator bumps last_verified_iter
  # (and evidence paths) on every re-verification even when no journey's
  # STATE changed, so hashing the whole journey dict made consecutive hashes
  # always differ — is_stalled() could never fire and the deterministic
  # stall backstop was dead code. Status + last_passing_iter freeze exactly
  # when real progress freezes.
  python3 -c "
import hashlib, json, sys
data = json.load(open('$JOURNEY_HISTORY'))
journeys = data.get('journeys', {}) or {}
canonical = {'journeys': {jid: {'status': (j or {}).get('status'),
                                'last_passing_iter': (j or {}).get('last_passing_iter')}
                          for jid, j in journeys.items()}}
print(hashlib.sha1(json.dumps(canonical, sort_keys=True).encode()).hexdigest())
"
}

is_stalled() {
  local window="$1"
  local n
  # `$window` is a bash integer interpolated literally into the Python source.
  # The first guard is "window is positive"; `len(int)` is a type error, so
  # compare the int directly. The second guard is "we have enough hashes to
  # fill the window".
  n=$(python3 -c "
import json
hashes = open('$GOAL_SESSION_DIR_LOCAL/.history-hashes').read().splitlines() if __import__('os').path.exists('$GOAL_SESSION_DIR_LOCAL/.history-hashes') else []
if $window > 0 and len(hashes) >= $window:
  recent = hashes[-$window:]
  print(1 if len(set(recent)) == 1 else 0)
else:
  print(0)
")
  [[ "$n" == "1" ]]
}

write_session_summary() {
  local final_verdict="$1"
  local total_iterations="$2"
  # Settle any background showcase tail first so the summary/index reflect the
  # final artifact set. When the pump is gone (AWAITING_PUMP) or the user hit
  # Ctrl-C (ABORTED), the group's own agent dispatches cannot succeed — reap it
  # immediately instead of waiting out its bounded join.
  case "$final_verdict" in
    AWAITING_PUMP|ABORTED|AWAITING_DISK) _join_showcase_tail --kill ;;
    *)                                   _join_showcase_tail ;;
  esac
  local now_epoch=$(date +%s)
  local wall_time=$(( now_epoch - SESSION_START_EPOCH ))
  local quota_pauses
  quota_pauses=$(cat "$QUOTA_PAUSE_COUNT_FILE")
  python3 - <<PY
import json
d = json.load(open("$SESSION_JSON"))
d["status"] = "$final_verdict"
d["finished_at"] = __import__("datetime").datetime.now(__import__("datetime").UTC).isoformat().replace('+00:00','Z')
d["total_iterations"] = $total_iterations
d["wall_time_seconds"] = $wall_time
d["quota_pause_count"] = $quota_pauses
import os as _os, tempfile as _tf
_fd, _tmp = _tf.mkstemp(dir=_os.path.dirname("$SESSION_JSON") or ".", suffix=".sjtmp")
with _os.fdopen(_fd, "w") as _f:
    json.dump(d, _f, indent=2)
    _f.write("\n")
_os.replace(_tmp, "$SESSION_JSON")
PY
  # Branch info (only when push_per_iter is on)
  local branch_section=""
  if [[ "$PUSH_PER_ITER" == "true" && -n "$PUSH_BRANCH" ]]; then
    branch_section=$(printf '\n## Branch\n\nThis session pushed iteration commits to `%s`. Open a PR with:\n\n    gh pr create --base main --head %s \\\n      --title "feat: %s — %s" \\\n      --body-file runs/goal-session-%s/summary.md\n' \
      "$PUSH_BRANCH" "$PUSH_BRANCH" "$SESSION_ID" "$final_verdict" "$SESSION_ID")
  fi

  cat > "$SUMMARY_FILE" <<EOF
# Goal Session Summary — ${SESSION_ID}

**Final verdict:** ${final_verdict}
**Total iterations:** ${total_iterations}
**Wall time (seconds):** ${wall_time}
**Quota pauses:** ${quota_pauses}
**Started:** $(python3 -c "import json; print(json.load(open('$SESSION_JSON'))['started_at'])")
**Finished:** $(python3 -c "import json; print(json.load(open('$SESSION_JSON'))['finished_at'])")
${branch_section}

## Final journey state

$(python3 -c "
import json
d = json.load(open('$JOURNEY_HISTORY'))['journeys']
if not d:
    print('(no journeys recorded)')
else:
    print('| Journey | Status | Last passing iter |')
    print('|---|---|---|')
    for jid, info in sorted(d.items()):
        print(f\"| {jid} | {info.get('status','unknown')} | {info.get('last_passing_iter') or '-'} |\")
")

## Anti-goal violations

$(python3 -c "
import json
v = json.load(open('$JOURNEY_HISTORY')).get('anti_goal_violations', [])
if not v:
    print('(none)')
else:
    for entry in v:
        sev = entry.get('severity','?')
        ag = entry.get('anti_goal','?')
        it = entry.get('iter','?')
        print(f\"- [{sev}] {ag} (iter {it})\")
")

## Telemetry

See \`runs/goal-session-${SESSION_ID}/telemetry.jsonl\` for the structured event log.

## Iteration timing

\`\`\`
$(python3 "$SCRIPT_DIR/lib/analyze_telemetry.py" --wall "$GOAL_SESSION_DIR_LOCAL/telemetry.jsonl" 2>/dev/null || echo "(timing report unavailable)")
\`\`\`
EOF
  record_telemetry_event "session_end" "$(jq -cn --arg fv "$final_verdict" --argjson ti $total_iterations --argjson wt $wall_time --argjson qp $quota_pauses '{final_verdict:$fv, total_iterations:$ti, wall_time_seconds:$wt, quota_pause_count:$qp}' 2>/dev/null || printf '{"final_verdict":"%s","total_iterations":%d}' "$final_verdict" "$total_iterations")"
  echo "[run-goal] Session summary: $SUMMARY_FILE"
  # Session retro (EVO-2 slice a): freeze a deterministic evidence snapshot
  # (state/retro-input.md) for the retro drafting agent on TERMINAL halts only.
  # Resumable pauses (AWAITING_*, GATE_BLOCKED) and ABORTED — which is also how
  # an ABORT_MALFORMED halt arrives here (the halt switch passes "ABORTED") —
  # produce nothing. Non-blocking: a broken collector must never change halt
  # behavior or an engine exit code. Disable with CHAIN_SESSION_RETRO=false.
  if [[ "${CHAIN_SESSION_RETRO:-true}" != "false" ]]; then
    case "$final_verdict" in
      GOAL_ACHIEVED|STALLED|REGRESSION_HALT|BUDGET_EXHAUSTED)
        bash "$SCRIPT_DIR/lib/retro_collect.sh" "$GOAL_SESSION_DIR_LOCAL" "$final_verdict" \
          || echo "[run-goal] Warning: session retro collector failed (non-blocking) — no retro-input.md." >&2
        # EVO-2 slice (b): draft improvement proposals from the frozen digest.
        # Same knob + terminal filter as the collector; the wrapper itself
        # refuses to dispatch when retro-input.md is absent (collector failed).
        _run_retro_analyst
        ;;
    esac
  fi
  _render_session_index_html
  local _idx_html="$REPO_ROOT/reports/goal-session-${SESSION_ID}-index.html"
  [[ -f "$_idx_html" ]] && echo "[run-goal] Session HTML: file://$_idx_html"
}

# Record this engine's PID so /goal-pause and a resuming run can find and stop it
# across separate command invocations (the interactive pump's in-memory PID is
# not available to a later /goal-pause). Cleaned up on any exit, including the
# on_abort path below (which exits 130 → the EXIT trap fires).
echo "$$" > "$ENGINE_PID_FILE" 2>/dev/null || true
# Composed EXIT trap (single trap owner — never add a second `trap … EXIT`, it
# would silently drop earlier cleanup): join/kill the showcase tail FIRST so
# nothing is still writing into the tmp dir, then remove pid file + tmp dir.
_goal_engine_on_exit() {
  _join_showcase_tail --kill 2>/dev/null || true
  rm -f "$ENGINE_PID_FILE" 2>/dev/null || true
  chain_tmp_cleanup
  # REL-4: release LAST so the lock covers the whole cleanup window. Owner-
  # checked no-op when this process never acquired (e.g. a refused start).
  release_engine_lock
}
trap _goal_engine_on_exit EXIT

# Trap: on SIGINT/SIGTERM, write ABORTED summary. Kill the background showcase
# tail FIRST so Ctrl-C never blocks on a non-gating summary/README agent.
on_abort() {
  echo "[run-goal] Aborted by user signal. Writing summary." >&2
  _join_showcase_tail --kill 2>/dev/null || true
  write_session_summary "ABORTED" "$CURRENT_ITER"
  explain_goal_status "ABORTED" "$SESSION_ID" "$REPO_ROOT" >&2
  exit 130
}
trap on_abort INT TERM

# ── Cross-session engine lock (REL-4) ─────────────────────────────────────
# One live engine per session id. Taken AFTER the traps above are armed (so
# every exit from here on releases it — including the AWAITING_* pause exits,
# which end this process; resume re-acquires) and BEFORE anything that costs
# time (doctor, tmp janitor, disk/GitHub preflights, the loop). A live holder
# refuses fast with exit $ENGINE_LOCK_REFUSED_EXIT; a dead one is replaced
# loudly (lib/engine-lock.sh; docs/TROUBLESHOOTING.md "lock held").
acquire_engine_lock "$GOAL_SESSION_DIR_LOCAL/.engine.lock" "engine for goal session '$SESSION_ID'" || exit $?

# Advisory preflight doctor (REL-2): one PASS/WARN/FAIL table of environment
# truth into the engine log BEFORE anything mutates state (tmp init/janitor
# sweeps, disk guard) — warn-only by construction, see run_doctor_preflight.
run_doctor_preflight

# Per-run tmp isolation (lib/chain-tmp.sh): one session-scoped dir now (covers
# the baseline + the first decomposer); the loop rotates to a per-iteration dir
# at each iteration boundary below. Janitor sweeps strays from crashed runs.
chain_tmp_init "goal-${SESSION_ID}"
chain_tmp_janitor

# Disk-space preflight (REL-13): sweep aggressively under pressure; pause
# (AWAITING_DISK) only when the tmp root's filesystem is still critically low.
preflight_disk_space

# Host-guard preflight: forensics sampler + affinity confinement. Repeated
# instant hardware resets under goal-mode load make unprotected engine runs
# unacceptable on hosts that declare caps; no-op everywhere else.
preflight_host_guard

# Verify we can push to GitHub before the loop starts (once; fresh + resume).
# Fails fast / pauses here rather than stalling on a credential prompt mid-run.
preflight_github_access

# ── Main loop ─────────────────────────────────────────────────────────────
while true; do
  # 1. Halt checks (always first)
  if [[ "$MAX_ITER" -gt 0 && $CURRENT_ITER -ge $MAX_ITER ]]; then
    echo "[run-goal] BUDGET_EXHAUSTED — reached max-iter cap of $MAX_ITER."
    record_telemetry_event "halt" '{"reason":"BUDGET_EXHAUSTED","detected_at_step":"pre_decomposer"}'
    write_session_summary "BUDGET_EXHAUSTED" "$CURRENT_ITER"
    explain_goal_status "BUDGET_EXHAUSTED" "$SESSION_ID" "$REPO_ROOT"
    exit 0
  fi

  if [[ $CURRENT_ITER -gt 0 ]] && is_stalled "$STALL_WINDOW"; then
    echo "[run-goal] STALLED — last $STALL_WINDOW iterations made no journey progress."
    record_telemetry_event "halt" '{"reason":"STALLED","detected_at_step":"pre_decomposer"}'
    write_session_summary "STALLED" "$CURRENT_ITER"
    explain_goal_status "STALLED" "$SESSION_ID" "$REPO_ROOT"
    exit 0
  fi

  # 1c. Disk guard (REL-13) — top of the loop, never mid-iteration (blueprint-
  # gate convention): sweeps aggressively under pressure and pauses only when
  # the tmp root's filesystem is still under the hard floor afterwards.
  if ! chain_tmp_disk_guard --enforce; then
    echo "[run-goal] AWAITING_DISK — free space under the hard floor after aggressive cleanup."
    echo "[run-goal]   Free space (or run ./scripts/automation/tmp-doctor.sh --aggressive), then: /goal-resume $SESSION_ID"
    record_telemetry_event "halt" '{"reason":"AWAITING_DISK","detected_at_step":"pre_decomposer"}'
    write_session_summary "AWAITING_DISK" "$CURRENT_ITER"
    explain_goal_status "AWAITING_DISK" "$SESSION_ID" "$REPO_ROOT"
    exit 0
  fi

  # 1d. Host-guard gate — top of the loop, never mid-iteration: thermal
  # cooldown (wait out heat-soak between iterations) + interactive pump
  # confinement (the self-wrap cannot cover agents inside the foreground CLI).
  # No-op unless the project declares host caps.
  host_guard_iteration_gate

  # 1b. Blueprint approval gate (coherence). Pauses at the TOP of the loop —
  # never mid-iteration — so the blueprint is never re-drafted out from under the
  # human. Two triggers: (initial) baseline drafted a blueprint not yet approved;
  # (structural) a later decomposer flagged a nav-skeleton change via the
  # reapproval marker. Additive blueprint edits never set that marker, so they
  # never pause.
  _need_bp_approval=false
  if [[ "$AUTO_APPROVE_BLUEPRINT" == "true" ]]; then
    if [[ -f "$BLUEPRINT_FILE" ]]; then touch "$BLUEPRINT_APPROVED"; fi
    rm -f "$BLUEPRINT_REAPPROVAL"
  elif [[ -f "$BLUEPRINT_REAPPROVAL" ]]; then
    _need_bp_approval=true
  elif [[ -f "$BLUEPRINT_FILE" && ! -f "$BLUEPRINT_APPROVED" ]]; then
    _need_bp_approval=true
  fi
  if [[ "$_need_bp_approval" == "true" ]]; then
    python3 - <<PY
import json, datetime
d = json.load(open("$SESSION_JSON"))
d["status"] = "AWAITING_BLUEPRINT_APPROVAL"
d["updated_at"] = datetime.datetime.now(datetime.UTC).isoformat().replace('+00:00','Z')
import os as _os, tempfile as _tf
_fd, _tmp = _tf.mkstemp(dir=_os.path.dirname("$SESSION_JSON") or ".", suffix=".sjtmp")
with _os.fdopen(_fd, "w") as _f:
    json.dump(d, _f, indent=2)
    _f.write("\n")
_os.replace(_tmp, "$SESSION_JSON")
PY
    record_telemetry_event "halt" '{"reason":"AWAITING_BLUEPRINT_APPROVAL","detected_at_step":"pre_decomposer"}'
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    if [[ -f "$BLUEPRINT_REAPPROVAL" ]]; then
      echo "[run-goal] PAUSED — a structural blueprint change needs your approval"
      echo "════════════════════════════════════════════════════════════════════"
      echo "Reason: $(cat "$BLUEPRINT_REAPPROVAL" 2>/dev/null)"
    else
      echo "[run-goal] PAUSED — blueprint approval needed (one time)"
      echo "════════════════════════════════════════════════════════════════════"
      echo "The baseline drafted your app blueprint."
    fi
    echo ""
    echo "Review (~3 min):  $BLUEPRINT_FILE"
    echo "  1. Information Architecture — are the nav sections sensible, and does"
    echo "     every feature have an obvious home?"
    echo "  2. Data Contract — is every \"same-number-everywhere\" value listed with"
    echo "     exactly ONE source? Add any the AI missed; fix wrong sources."
    echo "Edit the file directly to correct anything — your edits ARE the approval."
    echo ""
    echo "Resume:  ./scripts/automation/run-goal.sh --resume --session-id $SESSION_ID"
    echo "Skip the review next time:  add --auto-approve-blueprint"
    explain_goal_status "AWAITING_BLUEPRINT_APPROVAL" "$SESSION_ID" "$REPO_ROOT"
    echo "════════════════════════════════════════════════════════════════════"
    exit 0
  fi

  # 1c. Intent checkpoint (NEED-7) — opt-in mid-session pause for the human:
  # "is this still the product you wanted?". Cloned from the blueprint gate
  # above: fires at the TOP of the loop (never mid-iteration), writes a
  # resumable status, exits 0; --resume acknowledges it (sibling block next to
  # the blueprint resume-as-approval). Fires at most once per session
  # (state/.intent-review-done). intent-review.md is assembled
  # deterministically — no model dispatch. Triggers: --intent-checkpoint at
  # passing/total >= 50%; --intent-checkpoint-at N when the loop reaches
  # iteration N (same convention as --max-iter).
  _need_intent_review=false
  _intent_total=0
  _intent_passing=0
  if [[ ! -f "$INTENT_REVIEW_DONE" ]] \
     && [[ "$INTENT_CHECKPOINT" == "true" || "$INTENT_CHECKPOINT_AT" -gt 0 ]]; then
    read -r _intent_total _intent_passing <<<"$(
      { python3 "$SCRIPT_DIR/lib/goal_gate.py" journeys "$JOURNEY_HISTORY" 2>/dev/null || true; } \
        | python3 -c 'import json, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
    print(int(d.get("total", 0)), int(d.get("passing", 0)))
except Exception:
    print(0, 0)'
    )"
    if [[ "$INTENT_CHECKPOINT_AT" -gt 0 && $CURRENT_ITER -ge $INTENT_CHECKPOINT_AT ]]; then
      _need_intent_review=true
    elif [[ "$INTENT_CHECKPOINT" == "true" && "$_intent_total" -gt 0 \
            && $(( 2 * _intent_passing )) -ge "$_intent_total" ]]; then
      _need_intent_review=true
    fi
  fi
  if [[ "$_need_intent_review" == "true" ]]; then
    assemble_intent_review
    python3 - <<PY
import json, datetime
d = json.load(open("$SESSION_JSON"))
d["status"] = "AWAITING_INTENT_REVIEW"
d["updated_at"] = datetime.datetime.now(datetime.UTC).isoformat().replace('+00:00','Z')
import os as _os, tempfile as _tf
_fd, _tmp = _tf.mkstemp(dir=_os.path.dirname("$SESSION_JSON") or ".", suffix=".sjtmp")
with _os.fdopen(_fd, "w") as _f:
    json.dump(d, _f, indent=2)
    _f.write("\n")
_os.replace(_tmp, "$SESSION_JSON")
PY
    record_telemetry_event "halt" '{"reason":"AWAITING_INTENT_REVIEW","detected_at_step":"pre_decomposer"}'
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo "[run-goal] PAUSED — intent checkpoint: is this the product you wanted?"
    echo "════════════════════════════════════════════════════════════════════"
    echo "Progress: ${_intent_passing} of ${_intent_total} Must-have journeys pass."
    echo ""
    echo "Review (~5 min):  $INTENT_REVIEW_FILE"
    echo "  1. Journey digest + targeted questions — is what's still failing what"
    echo "     you want built next?"
    echo "  2. Hard-to-reverse assumptions — veto any wrong interpretation NOW."
    echo "If the product is drifting, edit docs/goal.md (journeys / anti-goals)"
    echo "before resuming — future iterations plan from your edited text."
    echo ""
    echo "Resume:  ./scripts/automation/run-goal.sh --resume --session-id $SESSION_ID"
    echo "(The checkpoint fires once per session; resuming acknowledges it.)"
    explain_goal_status "AWAITING_INTENT_REVIEW" "$SESSION_ID" "$REPO_ROOT"
    echo "════════════════════════════════════════════════════════════════════"
    exit 0
  fi

  ITER_NAME="goal-${SESSION_ID}-iter-${CURRENT_ITER}"
  ITER_DIR="$GOAL_SESSION_DIR_LOCAL/iter-${CURRENT_ITER}"
  mkdir -p "$ITER_DIR"
  # Stale-artifact hygiene: a prior ABORTED/AWAITING_PUMP attempt of this same
  # iteration may have left eval.md / coherence.md behind; parsing them would
  # certify a verdict the re-run never produced. Delete them UNLESS a completion
  # marker says the previous attempt genuinely finished that step: eval.md is
  # covered by the .evaluated marker (the evaluator step below reuses it), and
  # coherence.md by its step checkpoint (the coherence step below reuses it —
  # the checkpoint's tree-hash re-verification happens at that site).
  if [[ ! -f "$ITER_DIR/.evaluated" ]]; then
    rm -f "$ITER_DIR/eval.md" 2>/dev/null || true
  fi
  if ! step_done_valid coherence --dir "$ITER_DIR" "$ITER_DIR/coherence.md"; then
    rm -f "$ITER_DIR/coherence.md" 2>/dev/null || true
  fi
  export GOAL_ITER_INDEX="$CURRENT_ITER"
  export GOAL_ITER_NAME="$ITER_NAME"
  # Lets goal-iter-lean.sh fork the coherence audit concurrently with browser-qa.
  export GOAL_BLUEPRINT_FILE="$BLUEPRINT_FILE"

  # Capture a working-tree snapshot at the start of this iteration. This is a
  # zero-impact recording: `git stash create` builds a stash commit object
  # without touching the working tree or stash list. The SHA lets the operator
  # `git diff <sha>..HEAD` to see exactly what this iteration changed, and
  # `git reset --hard <sha>` (advanced) to roll back. Best-effort; failures
  # write an empty file and do not block the iteration.
  # First-write-wins: a RESUMED attempt of this same iteration must keep the
  # original pre-development baseline — re-capturing here would make the
  # coherence-auditor diff against a post-development tree and see nothing.
  if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    if [[ ! -f "$ITER_DIR/snapshot-sha" ]]; then
      if _snap=$(git -C "$REPO_ROOT" stash create 2>/dev/null); then
        printf '%s' "$_snap" > "$ITER_DIR/snapshot-sha"
      else
        : > "$ITER_DIR/snapshot-sha"
      fi
    fi
  fi

  PRIOR_VERDICT=$(python3 -c "import json; print(json.load(open('$SESSION_JSON')).get('last_verdict') or 'null')")
  PRIOR_DEPTH=$(python3 -c "import json; print(json.load(open('$SESSION_JSON')).get('next_depth') or 'lean')")

  record_telemetry_event "iter_start" "$(jq -cn --arg n "$ITER_NAME" --arg pv "$PRIOR_VERDICT" --arg pd "$PRIOR_DEPTH" --arg ss "$(cat "$ITER_DIR/snapshot-sha" 2>/dev/null || echo "")" '{iter_name:$n, prior_verdict:$pv, prior_depth:$pd, snapshot_sha:$ss}' 2>/dev/null || printf '{"iter_name":"%s"}' "$ITER_NAME")"

  # Mark experiment-knob-active iterations so the --tripwire window knows which
  # iterations to judge (opt-in speed experiments, .claude/model-orchestration.md).
  if [[ -n "${CHAIN_AGENT_EFFORT:-}" ]]; then
    record_telemetry_event "iter_config" "$(jq -cn --arg k "CHAIN_AGENT_EFFORT" --arg v "$CHAIN_AGENT_EFFORT" '{key:$k, value:$v}' 2>/dev/null || printf '{"key":"CHAIN_AGENT_EFFORT","value":"%s"}' "$CHAIN_AGENT_EFFORT")"
  fi

  echo ""
  echo "════════════════════════════════════════════════════════════════════"
  echo "[run-goal] Iteration $CURRENT_ITER ($ITER_NAME)"
  echo "════════════════════════════════════════════════════════════════════"

  # 2. Goal decomposer
  if [[ $CURRENT_ITER -eq 0 ]]; then
    DECOMPOSER_MODE="baseline"
  else
    DECOMPOSER_MODE="next"
  fi

  # SPEED-4: hardening-cadence input. The decomposer prompt only inlines the
  # last 3 evaluator entries, so a K-long lean streak is invisible to the agent
  # unless the engine supplies the count; the post-parse backstop below
  # enforces the cadence even if the agent ignores it.
  LEAN_STREAK=$(goal_lean_streak "$GOAL_SESSION_DIR_LOCAL" "$CURRENT_ITER")

  # REL-14 make-up scheduling: journeys the previous evaluation left
  # pending_infra (browser evidence missing due to INFRA, not defects) get a
  # verify-only make-up ride this iteration — a BINDING decomposer prompt line
  # plus an engine-side union into the executor's browser set
  # (CHAIN_BQA_MAKEUP_JOURNEYS; the union also covers the resume path, where a
  # reused spec never saw the line). CHAIN_BQA_PREV_ATTEMPTS carries the token's
  # consecutive-block counter so the evaluator can apply the two-strike rule.
  BQA_MAKEUP_JOURNEYS=""
  if [[ $CURRENT_ITER -gt 0 && -f "$JOURNEY_HISTORY" ]]; then
    BQA_MAKEUP_JOURNEYS="$(python3 -c "
import json
try:
    h = json.load(open('$JOURNEY_HISTORY'))
    js = h.get('journeys', {}) if isinstance(h, dict) else {}
    print(' '.join(sorted(j for j, v in js.items() if isinstance(v, dict) and v.get('pending_infra'))))
except Exception:
    pass" 2>/dev/null || true)"
  fi
  if [[ -n "$BQA_MAKEUP_JOURNEYS" ]]; then
    export CHAIN_BQA_MAKEUP_JOURNEYS="$BQA_MAKEUP_JOURNEYS"
    _prev_infra_token="$GOAL_SESSION_DIR_LOCAL/iter-$((CURRENT_ITER-1))/browser-infra.json"
    CHAIN_BQA_PREV_ATTEMPTS="$(python3 -c "
import json
try: print(int(json.load(open('$_prev_infra_token')).get('attempts', 0)))
except Exception: print(0)" 2>/dev/null || echo 0)"
    export CHAIN_BQA_PREV_ATTEMPTS
    echo "[run-goal] REL-14: pending-infra make-up scheduled for: $BQA_MAKEUP_JOURNEYS (prior attempts: $CHAIN_BQA_PREV_ATTEMPTS)"
  else
    unset CHAIN_BQA_MAKEUP_JOURNEYS CHAIN_BQA_PREV_ATTEMPTS 2>/dev/null || true
  fi

  echo "[run-goal] Step 1: goal-decomposer (mode: $DECOMPOSER_MODE)"
  # Pre-trim historical state — pass only the tail to the decomposer so token
  # usage stays flat as the session grows. Spec asks for "last 3 entries";
  # 200 lines is conservative and covers multi-paragraph entries.
  EVALUATOR_LOG_TAIL=$(_tail_or_placeholder "$EVALUATOR_LOG" 200 "(no entries yet — first iteration)")
  LESSONS_TAIL=$(_tail_or_placeholder "$LESSONS_FILE" 200 "(no lessons recorded yet)")
  ASSUMPTIONS_TAIL=$(_tail_or_placeholder "$ASSUMPTIONS_FILE" 200 "(no assumptions recorded yet)")
  # REL-6: the evaluator-written iteration-state digest, inlined VERBATIM (the
  # schema caps the file at 40 lines, so the 40-line budget below inlines the
  # whole file; _tail_or_placeholder's byte cap guards a rogue oversized write).
  ITER_STATE_INLINE=$(_tail_or_placeholder "$ITER_STATE_FILE" 40 "(first iteration — no prior state)")
  # Token-lean goal view (T1/T8): stable passing journeys digested to one line,
  # vision/anti-goals/failing journeys verbatim; plus an inline journey digest.
  # Both fail safe (full file / placeholder) — see lib/goal_gate.py.
  GOAL_SLICE_PATH="$ITER_DIR/goal-slice.md"
  python3 "$SCRIPT_DIR/lib/goal_gate.py" goal-slice "$GOAL_FILE" \
    --history "$JOURNEY_HISTORY" --out "$GOAL_SLICE_PATH" 2>/dev/null \
    || cp "$GOAL_FILE" "$GOAL_SLICE_PATH" 2>/dev/null || GOAL_SLICE_PATH="$GOAL_FILE"
  JOURNEY_DIGEST=$(python3 "$SCRIPT_DIR/lib/goal_gate.py" digest "$JOURNEY_HISTORY" 2>/dev/null || echo "(journey digest unavailable — read $JOURNEY_HISTORY)")
  cd "$REPO_ROOT"
  ITER_SPEC_PATH="$REPO_ROOT/docs/phases/${ITER_NAME}.md"
  # Resume-skip: a prior attempt of this same iteration already wrote a spec
  # that parses (checkpoint + Depth line) — don't redo the planning call.
  # The guarded section below is not re-indented; it ends at the matching `fi`
  # after the spec-existence check.
  if step_done_valid decomposer --dir "$ITER_DIR" "$ITER_SPEC_PATH" \
     && grep -qiE '(\*\*)?Depth:(\*\*)?[[:space:]]*(lean|full|evidence)' "$ITER_SPEC_PATH"; then
    echo "[run-goal] Resume: goal-decomposer already completed for iteration $CURRENT_ITER (checkpoint + spec verified) — skipping."
    record_telemetry_event "step_skipped" "$(jq -cn --arg n "$ITER_NAME" '{step:"goal-decomposer", iter_name:$n, reason:"checkpoint"}' 2>/dev/null || printf '{"step":"goal-decomposer"}')"
  else
  step_invalidate_from decomposer "$ITER_DIR"
  record_agent_invocation_start "goal-decomposer"   # bare call: must NOT be $(...) or the CHAIN_CURRENT_AGENT export is lost to a subshell
  _decomp_start=$CHAIN_AGENT_START_EPOCH
  _decomp_rc=0
  claude_with_quota_retry -p "You are the goal-decomposer agent for goal-mode iteration planning.

Mode: $DECOMPOSER_MODE
Session ID: $SESSION_ID
Iteration index: $CURRENT_ITER
Iter name: $ITER_NAME
Prior verdict: $PRIOR_VERDICT
Prior depth: $PRIOR_DEPTH
Consecutive lean iterations dispatched: $LEAN_STREAK (hardening cadence: ${CHAIN_HARDENING_CADENCE:-6}; 0 = disabled)

Project template: .claude/project-template.md
Project goal (SLICED — vision + anti-goals + failing/target journeys verbatim; stable passing journeys digested to one line): $GOAL_SLICE_PATH
  Full goal file: $GOAL_FILE — Read it ONLY if a digested journey becomes relevant to your plan.
Agent instructions: .claude/agents/goal-decomposer.md  <-- read this first
(CLAUDE.md is already in your system prompt — do not Read it again.)

Recent evaluator log entries (last 3, pre-trimmed):
\`\`\`
$EVALUATOR_LOG_TAIL
\`\`\`
Lessons learned (full file, append-only):
\`\`\`
$LESSONS_TAIL
\`\`\`
Assumption ledger (append-only): $ASSUMPTIONS_FILE  <-- when a spec decision requires interpreting an ambiguous goal, append an entry per your agent instructions; zero entries is normal. Do not read the full file — recent tail below.
Recent assumption entries (pre-trimmed):
\`\`\`
$ASSUMPTIONS_TAIL
\`\`\`
Journey state (inline digest; Read $JOURNEY_HISTORY only for fields the digest omits):
\`\`\`
$JOURNEY_DIGEST
\`\`\`

Iteration state (single-file digest the goal-evaluator overwrote after the last iteration; inlined verbatim):
\`\`\`
$ITER_STATE_INLINE
\`\`\`
\"Do not redo\" entries above are BINDING — do not re-plan or re-test them — unless docs/goal.md changed for that item.
$( [[ -n "${CHAIN_BQA_MAKEUP_JOURNEYS:-}" ]] && echo "Pending-infra make-up targets: $CHAIN_BQA_MAKEUP_JOURNEYS. BINDING — include them as verify-only targets this iteration; do NOT re-plan their implementation — the code is present, only browser evidence is missing (prior browser-infra failure)." )

$( [[ $CURRENT_ITER -gt 0 && -f "$GOAL_SESSION_DIR_LOCAL/iter-$((CURRENT_ITER-1))/eval.md" ]] && echo "Last iteration eval: $GOAL_SESSION_DIR_LOCAL/iter-$((CURRENT_ITER-1))/eval.md")

Write the iteration spec to: docs/phases/${ITER_NAME}.md
$( if [[ "$DECOMPOSER_MODE" == "baseline" ]]; then echo "BASELINE also: draft the coherence blueprint to $BLUEPRINT_FILE per your agent instructions (Information Architecture + Data Contract, ~one screen, from docs/goal.md's Product Shape + Must-have journeys + Key Capabilities). The blueprint is auto-approved by default and the loop proceeds; pass --require-blueprint-approval to pause for human review after baseline."; else echo "Also keep $BLUEPRINT_FILE current per your agent instructions: register any new displayed value in the Data Contract and place new pages under an existing Information-Architecture home (additive edits only). For a nav-skeleton change, make the edit AND write a one-line reason to $BLUEPRINT_REAPPROVAL."; fi )

The spec MUST include a 'Goal Mode Metadata' section with at minimum:
  - Mode: $DECOMPOSER_MODE
  - Depth: lean | full | evidence
  - Target journeys: <comma-separated journey IDs>

Do NOT write code or implement anything. The iteration spec and any blueprint edits are planning documents, not code. STOP after writing them." || _decomp_rc=$?

  record_agent_invocation_end "goal-decomposer" "$_decomp_start" "$_decomp_rc"

  # Transport loss (exit 70) is infrastructure, not a planning failure: pause
  # resumably like the executor/coherence sites do, instead of the previous
  # (incorrect) hard ABORTED that forced a full manual restart.
  if [[ "$_decomp_rc" -eq "${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}" ]]; then
    echo "[run-goal] Interactive pump/dispatch unavailable during goal-decomposer — pausing (resume re-runs iteration $CURRENT_ITER)." >&2
    if [[ -n "${CHAIN_DISPATCH_DIR:-}" && -f "${CHAIN_DISPATCH_DIR}/.awaiting-pump" ]]; then
      echo "[run-goal]   $(cat "${CHAIN_DISPATCH_DIR}/.awaiting-pump" 2>/dev/null)" >&2
    fi
    echo "[run-goal]   Resume after re-opening the pump session:  /goal-resume $SESSION_ID" >&2
    record_telemetry_event "halt" '{"reason":"AWAITING_PUMP","detected_at_step":"decomposer"}'
    write_session_summary "AWAITING_PUMP" "$CURRENT_ITER"
    explain_goal_status "AWAITING_PUMP" "$SESSION_ID" "$REPO_ROOT" >&2
    exit 0
  fi

  if [[ $_decomp_rc -ne 0 ]]; then
    echo "[run-goal] goal-decomposer failed with exit $_decomp_rc — aborting." >&2
    record_telemetry_event "halt" '{"reason":"DECOMPOSER_FAILED","detected_at_step":"decomposer"}'
    write_session_summary "ABORTED" "$CURRENT_ITER"
    explain_goal_status "ABORTED" "$SESSION_ID" "$REPO_ROOT" >&2
    exit "$_decomp_rc"
  fi

  if [[ ! -f "$ITER_SPEC_PATH" ]]; then
    echo "[run-goal] goal-decomposer did not write spec at $ITER_SPEC_PATH — aborting." >&2
    write_session_summary "ABORTED" "$CURRENT_ITER"
    explain_goal_status "ABORTED" "$SESSION_ID" "$REPO_ROOT" >&2
    exit 1
  fi

  step_mark_done decomposer --dir "$ITER_DIR" "$ITER_SPEC_PATH"
  fi  # end of the decomposer resume-skip guard

  # ── Post-decompose gate (generic, project-local, default-off) ───────────────
  # Extension point M2: if the project provides project-extensions/gates/
  # post-decompose.sh, run it with the iteration context BEFORE any build work.
  # A non-zero exit BLOCKS the iteration (e.g. an evidence-derived proposal whose
  # statistical referee did not certify it). Absent script ⇒ skipped entirely, so
  # other projects sharing this framework behave exactly as before.
  if [[ -f "$REPO_ROOT/project-extensions/gates/post-decompose.sh" ]]; then
    echo "[run-goal] Post-decompose gate: project-extensions/gates/post-decompose.sh ..."
    mkdir -p "$ITER_DIR"
    _gate_rc=0
    (
      export SESSION_ID ITER_NAME REPO_ROOT
      export ITER="$CURRENT_ITER" \
             SPEC_PATH="$ITER_SPEC_PATH" \
             SESSION_DIR="$GOAL_SESSION_DIR_LOCAL" \
             LEDGER_PATH="$GOAL_SESSION_DIR_LOCAL/state/certified-claims.jsonl" \
             STAGING_LEDGER_PATH="$GOAL_SESSION_DIR_LOCAL/state/staging-ledger.jsonl" \
             GATE_VERDICT_PATH="$ITER_DIR/gate-post-decompose.json"
      run_project_gate post-decompose
    ) || _gate_rc=$?
    if [[ "$_gate_rc" -ne 0 ]]; then
      echo "[run-goal] Post-decompose gate BLOCKED iteration $CURRENT_ITER (exit $_gate_rc)." >&2
      if [[ -f "$ITER_DIR/gate-post-decompose.json" ]]; then
        echo "[run-goal]   verdict: $ITER_DIR/gate-post-decompose.json" >&2
      fi
      record_telemetry_event "halt" '{"reason":"GATE_BLOCKED_POST_DECOMPOSE","detected_at_step":"post_decomposer"}'
      write_session_summary "GATE_BLOCKED" "$CURRENT_ITER"
      explain_goal_status "GATE_BLOCKED" "$SESSION_ID" "$REPO_ROOT" >&2
      exit 0
    fi
  fi

  # Parse depth
  DEPTH=$(grep -m1 -E '^[[:space:]]*-?[[:space:]]*\*\*Depth:\*\*' "$ITER_SPEC_PATH" \
            | sed -E 's/.*\*\*Depth:\*\*[[:space:]]*//; s/[[:space:]]+$//' \
            | tr '[:upper:]' '[:lower:]') || true
  if [[ -z "$DEPTH" ]]; then
    DEPTH=$(grep -m1 -E '^[[:space:]]*-?[[:space:]]*Depth:' "$ITER_SPEC_PATH" \
              | sed -E 's/.*Depth:[[:space:]]*//; s/[[:space:]]+$//' \
              | tr '[:upper:]' '[:lower:]') || true
  fi
  # SPEED-9: 'evidence' is a first-class depth (capture + evaluate only). The
  # knob maps it back to lean when the micro-path is disabled.
  if [[ "$DEPTH" == "evidence" && "${CHAIN_EVIDENCE_MICRO_PATH:-true}" != "true" ]]; then
    echo "[run-goal] Depth 'evidence' requested but CHAIN_EVIDENCE_MICRO_PATH=false — dispatching as lean." >&2
    DEPTH="lean"
  fi
  if [[ "$DEPTH" != "lean" && "$DEPTH" != "full" && "$DEPTH" != "evidence" ]]; then
    echo "[run-goal] Could not parse Depth (expected 'lean', 'full', or 'evidence') from $ITER_SPEC_PATH. Defaulting to lean." >&2
    DEPTH="lean"
  fi

  # SPEED-10 full-trigger allowlist: full depth costs ~90-120 min over lean and
  # in practice ran on unjustified iterations (a video re-record got a 3h full
  # pass). A full dispatch must now be JUSTIFIED by one of: prior ESCALATE/
  # REGRESSION verdict, a prior-iteration coherence FAIL, a machine-parseable
  # 'Full trigger:' line in the spec (the rubric's numbered trigger), or the
  # hardening cadence being due anyway. Otherwise demote to lean (the evidence
  # backstop below may demote further). CHAIN_DEPTH_ALLOWLIST=false disables.
  if [[ "$DEPTH" == "full" && "${CHAIN_DEPTH_ALLOWLIST:-true}" == "true" ]]; then
    _full_reason=""
    _prev_coh_file="$GOAL_SESSION_DIR_LOCAL/iter-$((CURRENT_ITER - 1))/coherence.md"
    if [[ "${PRIOR_VERDICT:-}" == "ESCALATE" || "${PRIOR_VERDICT:-}" == "REGRESSION" ]]; then
      _full_reason="prior-verdict-${PRIOR_VERDICT}"
    elif grep -qE '^\*\*Verdict:\*\* COHERENCE-FAIL' "$_prev_coh_file" 2>/dev/null; then
      _full_reason="prior-coherence-fail"
    elif grep -qiE '^[[:space:]]*-?[[:space:]]*(\*\*)?Full trigger:' "$ITER_SPEC_PATH"; then
      _full_reason="spec-full-trigger"
    elif goal_cadence_forces_full "$LEAN_STREAK" "$CURRENT_ITER"; then
      _full_reason="cadence-due"
    fi
    if [[ -z "$_full_reason" ]]; then
      echo "[run-goal] Depth allowlist: the spec asked for a FULL pass but named no trigger (no 'Full trigger:' line, prior verdict was ${PRIOR_VERDICT:-none}, no prior coherence FAIL, cadence not due) — running LEAN instead. Set CHAIN_DEPTH_ALLOWLIST=false to disable this check."
      record_telemetry_event "depth_demoted" "$(jq -cn --arg pv "${PRIOR_VERDICT:-}" '{from:"full", to:"lean", reason:"no-full-trigger", prior_verdict:$pv}' 2>/dev/null || printf '{"from":"full","to":"lean"}')"
      DEPTH="lean"
    fi
  fi

  # SPEED-4 hardening-cadence backstop: a K-long lean streak forces a full
  # hardening pass even when the spec says lean. The spec text stays as
  # written; dispatch + telemetry carry the effective depth.
  if [[ "$DEPTH" == "lean" ]] && goal_cadence_forces_full "$LEAN_STREAK" "$CURRENT_ITER"; then
    echo "[run-goal] Hardening cadence: $LEAN_STREAK consecutive lean iterations — overriding spec depth lean → full (CHAIN_HARDENING_CADENCE=${CHAIN_HARDENING_CADENCE:-6}; 0 disables)."
    DEPTH="full"
    record_telemetry_event "depth_cadence_override" "$(jq -cn --arg s "$LEAN_STREAK" --arg k "${CHAIN_HARDENING_CADENCE:-6}" '{lean_streak:$s, cadence:$k}' 2>/dev/null || printf '{"lean_streak":"%s"}' "$LEAN_STREAK")"
  fi

  TARGET_JOURNEYS=$(grep -m1 -E '^[[:space:]]*-?[[:space:]]*\*\*Target journeys:\*\*' "$ITER_SPEC_PATH" \
                      | sed -E 's/.*\*\*Target journeys:\*\*[[:space:]]*//' || echo "")

  # SPEED-9 evidence backstop: a lean dispatch whose Target journeys are ALL
  # already recorded passing (and none pending-infra) has no build work — the
  # deliverable can only be evidence. Demote lean → evidence so developer and
  # reviewer are not dispatched against a no-op. Never touches full.
  if [[ "$DEPTH" == "lean" && "${CHAIN_EVIDENCE_MICRO_PATH:-true}" == "true" && -n "$TARGET_JOURNEYS" ]] \
     && { [[ "${PRIOR_VERDICT:-}" == "CONTINUE" || "${PRIOR_VERDICT:-}" == "ESCALATE" ]]; } \
     && python3 - "$JOURNEY_HISTORY" "$TARGET_JOURNEYS" <<'PYEOF'
import json, re, sys
try:
    hist = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
journeys = hist.get("journeys") or {}
ids = re.findall(r"J-\d+", sys.argv[2])
if not ids:
    sys.exit(1)
for jid in ids:
    j = journeys.get(jid)
    if not isinstance(j, dict):
        sys.exit(1)
    if j.get("status") not in ("passing", "already_passing"):
        sys.exit(1)
    if j.get("pending_infra"):
        sys.exit(1)
sys.exit(0)
PYEOF
  then
    echo "[run-goal] Evidence backstop: every target journey (${TARGET_JOURNEYS}) is already recorded passing — demoting depth lean → evidence (set CHAIN_EVIDENCE_MICRO_PATH=false to disable)."
    DEPTH="evidence"
    record_telemetry_event "depth_evidence_override" "$(jq -cn --arg tj "$TARGET_JOURNEYS" '{from:"lean", to:"evidence", target_journeys:$tj}' 2>/dev/null || printf '{"from":"lean","to":"evidence"}')"
  fi

  echo "[run-goal] Iter spec depth: $DEPTH"
  echo "[run-goal] Target journeys: ${TARGET_JOURNEYS:-(none parsed)}"
  # Expose the parsed journey list to run-phase.sh / browser-qa-phase.sh so
  # detect_frontend_in_plan (lib/common.sh) forces the browser lane whenever this
  # iteration names journeys — even if the plan mis-states "Frontend Present: no"
  # (the iter-8 CLOSURE-FAIL root cause). Exported unconditionally (empty = none)
  # so a prior iteration's value never leaks forward.
  export CHAIN_GOAL_TARGET_JOURNEYS="$TARGET_JOURNEYS"
  record_telemetry_event "iter_dispatch" "$(jq -cn --arg d "$DEPTH" --arg tj "$TARGET_JOURNEYS" '{depth:$d, target_journeys:$tj}' 2>/dev/null || printf '{"depth":"%s"}' "$DEPTH")"

  # 2c. Join the previous iteration's background showcase tail (if any) BEFORE
  # dispatching build work: its artifacts get committed here, so developer /
  # reviewer of THIS iteration see exactly the tree the sequential ordering
  # would have produced. Overlapping it with the decomposer above is where the
  # ~6-13 min saving comes from.
  _engine_step_begin "showcase-join"
  _join_showcase_tail
  _engine_step_done

  # Tmp hygiene boundary — the per-iteration cleanup step. The previous
  # iteration's background showcase tail has just been joined (its demo
  # services killed), so nothing is writing to the previous tmp dir any more.
  # Clear it and start this iteration's own dir — one call site covers BOTH
  # the lean and full dispatch paths below. (Do NOT clean right after the
  # evaluator: the async showcase tail forked at step 4c still writes there.)
  _prev_tmp="${CHAIN_TMPDIR:-}"
  chain_tmp_rotate "$ITER_NAME"
  echo "[run-goal] Tmp cleanup: cleared ${_prev_tmp:-(none)} — iteration tmp dir: ${CHAIN_TMPDIR:-(disabled)}"

  # 3. Dispatch. Reset the per-iteration exit code first: _exec_rc is a plain
  # shell var, so a stale 70 from a prior iteration would otherwise survive into
  # this one (the `:-0` default only fills an UNSET var) and mis-fire the
  # transport-pause check below.
  _exec_rc=0
  if [[ "$DEPTH" == "full" ]]; then
    _full_extra_args=(--no-finalize)
    echo "[run-goal] Dispatching FULL pipeline via run-phase.sh ${_full_extra_args[*]} ..."
    if grep -q '\-\-no-finalize' "$SCRIPT_DIR/run-phase.sh"; then
      printf 'full' > "$ITER_DIR/depth-dispatched"   # SPEED-4: cadence streak input (depth that actually runs)
      _engine_step_begin "full-pipeline"
      bash "$SCRIPT_DIR/run-phase.sh" "$ITER_NAME" "${_full_extra_args[@]}" || _exec_rc=$?
      _engine_step_done
    else
      echo "[run-goal] run-phase.sh does not yet support --no-finalize. Falling back to lean for safety." >&2
      printf 'lean' > "$ITER_DIR/depth-dispatched"
      _engine_step_begin "lean-pipeline"
      bash "$SCRIPT_DIR/goal-iter-lean.sh" "$ITER_NAME" || _exec_rc=$?
      _engine_step_done
    fi
  elif [[ "$DEPTH" == "evidence" ]]; then
    # SPEED-9 micro-path: capture + evaluate only. goal-iter-lean.sh skips
    # developer/reviewer, runs browser-qa on the Target journeys, and records
    # the walkthrough BEFORE returning so the evaluator can actually see it.
    echo "[run-goal] Dispatching EVIDENCE micro-path via goal-iter-lean.sh (capture + evaluate; no developer/reviewer) ..."
    printf 'evidence' > "$ITER_DIR/depth-dispatched"
    _engine_step_begin "evidence-pipeline"
    CHAIN_LEAN_EVIDENCE_ONLY=true bash "$SCRIPT_DIR/goal-iter-lean.sh" "$ITER_NAME" || _exec_rc=$?
    _engine_step_done
  else
    echo "[run-goal] Dispatching LEAN pipeline via goal-iter-lean.sh ..."
    printf 'lean' > "$ITER_DIR/depth-dispatched"
    _engine_step_begin "lean-pipeline"
    bash "$SCRIPT_DIR/goal-iter-lean.sh" "$ITER_NAME" || _exec_rc=$?
    _engine_step_done
  fi

  # Transport/dispatch-unavailable (exit 70) from the interactive backend: the
  # pump/session went away mid-iteration. This is infrastructure, not agent
  # quality — pause cleanly and resumably instead of running the coherence-auditor
  # and goal-evaluator (which would also fail to dispatch) on an empty iteration.
  # current_iter is NOT advanced (it only moves after the evaluator), so
  # /goal-resume re-runs this same iteration from the decomposer.
  if [[ "$_exec_rc" -eq "${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}" ]]; then
    echo "[run-goal] Interactive pump/dispatch unavailable during iteration $CURRENT_ITER — pausing." >&2
    if [[ -n "${CHAIN_DISPATCH_DIR:-}" && -f "${CHAIN_DISPATCH_DIR}/.awaiting-pump" ]]; then
      echo "[run-goal]   $(cat "${CHAIN_DISPATCH_DIR}/.awaiting-pump" 2>/dev/null)" >&2
    fi
    echo "[run-goal]   Resume after re-opening the pump session:  /goal-resume $SESSION_ID" >&2
    echo "[run-goal]   (or: ./scripts/automation/run-goal.sh --resume --session-id $SESSION_ID --interactive)" >&2
    record_telemetry_event "halt" '{"reason":"AWAITING_PUMP","detected_at_step":"executor"}'
    write_session_summary "AWAITING_PUMP" "$CURRENT_ITER"
    explain_goal_status "AWAITING_PUMP" "$SESSION_ID" "$REPO_ROOT" >&2
    exit 0
  fi

  # 3b. Coherence auditor — information-architecture + data-contract drift gate.
  # Goal-mode only; one integration point covering both lean and full dispatch.
  # Skipped at baseline (iter 0 has no code). Writes iter-<N>/coherence.md; the
  # goal-evaluator vetoes GOAL_ACHIEVED on COHERENCE-FAIL and drives a
  # consolidation CONTINUE. An auditor crash is non-blocking (stubbed PASS) so a
  # safety-net agent can never wedge the session.
  COHERENCE_OUTPUT="$ITER_DIR/coherence.md"
  if [[ $CURRENT_ITER -gt 0 && -f "$BLUEPRINT_FILE" ]]; then
    _coh_dispatched=""
    _coh_stubbed=""
    _snapshot_sha="$(cat "$ITER_DIR/snapshot-sha" 2>/dev/null || echo "")"
    # SPEED-14: zero-change fast path — an empty product diff cannot introduce
    # IA/data-contract drift, so the audit holds by construction. Deterministic
    # PASS with distinct text (goal_gate.py must NOT read it as a crash stub —
    # this verdict stays valid for GOAL_ACHIEVED certification). Only when no
    # genuine audit output exists yet (a lean-fork audit takes precedence).
    if [[ "${CHAIN_ZERO_CHANGE_SKIPS:-true}" == "true" && ! -f "$COHERENCE_OUTPUT" ]] \
       && goal_product_diff_empty "$_snapshot_sha" "$REPO_ROOT"; then
      echo "[run-goal] Step 2b: coherence-auditor skipped — zero-change iteration (empty product diff); deterministic PASS."
      printf '**Verdict:** COHERENCE-PASS\n\n(Zero-change iteration: the product diff since the iteration snapshot is empty — nothing to audit. Deterministic pass without dispatch; set CHAIN_ZERO_CHANGE_SKIPS=false to always dispatch.)\n' > "$COHERENCE_OUTPUT"
      record_telemetry_event "step_skipped" "$(jq -cn --arg n "$ITER_NAME" '{step:"coherence-auditor", iter_name:$n, reason:"zero-change"}' 2>/dev/null || printf '{"step":"coherence-auditor","reason":"zero-change"}')"
    # Resume-skip: a prior attempt's audit is reusable only when its checkpoint,
    # the verdict line, AND the tree state all verify (a drifted tree means the
    # audited diff is no longer this iteration's diff).
    elif step_done_valid coherence --verify-tree --dir "$ITER_DIR" "$COHERENCE_OUTPUT" \
       && grep -qE '^\*\*Verdict:\*\* COHERENCE-(PASS|WARN|FAIL)' "$COHERENCE_OUTPUT"; then
      echo "[run-goal] Resume: coherence audit already completed for iteration $CURRENT_ITER (checkpoint + tree verified) — reusing $COHERENCE_OUTPUT."
      record_telemetry_event "step_skipped" "$(jq -cn --arg n "$ITER_NAME" '{step:"coherence-auditor", iter_name:$n, reason:"checkpoint"}' 2>/dev/null || printf '{"step":"coherence-auditor"}')"
    else
    step_invalidate_from coherence "$ITER_DIR"
    _coh_dispatched=1
    echo "[run-goal] Step 2b: coherence-auditor"
    _coh_rc=0
    dispatch_coherence_audit "$SESSION_ID" "$CURRENT_ITER" "$ITER_NAME" \
      "$BLUEPRINT_FILE" "$ITER_SPEC_PATH" "$COHERENCE_OUTPUT" "$_snapshot_sha" || _coh_rc=$?
    # Pump loss (transport 70) is infrastructure, not an audit result — without
    # this guard a dead pump fabricated a COHERENCE-PASS via the crash stub below.
    if [[ "$_coh_rc" -eq "${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}" ]]; then
      echo "[run-goal] Interactive pump/dispatch unavailable during coherence audit — pausing (resume re-runs iteration $CURRENT_ITER)." >&2
      record_telemetry_event "halt" '{"reason":"AWAITING_PUMP","detected_at_step":"coherence_auditor"}'
      write_session_summary "AWAITING_PUMP" "$CURRENT_ITER"
      explain_goal_status "AWAITING_PUMP" "$SESSION_ID" "$REPO_ROOT" >&2
      exit 0
    fi
    fi  # end of the coherence resume-skip guard
    if [[ ! -f "$COHERENCE_OUTPUT" ]]; then
      echo "[run-goal] coherence-auditor wrote no output — recording non-blocking PASS and continuing." >&2
      printf '**Verdict:** COHERENCE-PASS\n\n(Coherence auditor produced no output; treated as a non-blocking pass.)\n' > "$COHERENCE_OUTPUT"
      _coh_stubbed=1
    fi
    _coh_verdict=$(grep -m1 -E '^\*\*Verdict:\*\*' "$COHERENCE_OUTPUT" | sed -E 's/^\*\*Verdict:\*\*[[:space:]]*//' | awk '{print $1}') || true
    echo "[run-goal] Coherence verdict: ${_coh_verdict:-unknown}"
    record_telemetry_event "coherence_audit" "$(jq -cn --arg v "${_coh_verdict:-unknown}" '{verdict:$v}' 2>/dev/null || printf '{"verdict":"%s"}' "${_coh_verdict:-unknown}")"
    # Checkpoint: only a genuine agent-produced audit is reusable on resume —
    # never the non-blocking crash stub above (a re-run may produce a real one).
    if [[ -n "$_coh_dispatched" && -z "$_coh_stubbed" && "${_coh_rc:-1}" -eq 0 ]]; then
      step_mark_done coherence --dir "$ITER_DIR" --verdict "${_coh_verdict:-unknown}" "$COHERENCE_OUTPUT"
    fi
  fi

  # 3c. Pre-evaluator deterministic artifacts (gates + token-lean context).
  #   - journey-history.pre.json: snapshot BEFORE the evaluator rewrites it —
  #     the regression cross-check compares against this (skipped on the
  #     .evaluated reuse path, where the prior attempt's snapshot must survive)
  #   - scan-report.md / iter-diff.md: full-diff secret scan + bounded diff view
  #   - goal-slice refresh with this iteration's Target journeys kept verbatim
  #   - journeys-changed.md: recorded-passing journeys whose goal.md spec text
  #     no longer matches their recorded spec_hash (mid-session goal edit)
  if [[ ! -f "$ITER_DIR/.evaluated" ]]; then
    cp "$JOURNEY_HISTORY" "$ITER_DIR/journey-history.pre.json" 2>/dev/null || true
  fi
  _snapshot_sha_for_gates="$(cat "$ITER_DIR/snapshot-sha" 2>/dev/null || echo "")"
  goal_gate_build_diff_artifacts "$ITER_DIR" "$_snapshot_sha_for_gates" "$REPO_ROOT" || true
  _spec_targets="$(grep -m1 -E 'Target journeys:' "$ITER_SPEC_PATH" 2>/dev/null | sed -E 's/.*Target journeys:\*?\*?[[:space:]]*//' | tr -d ' ' )" || _spec_targets=""
  python3 "$SCRIPT_DIR/lib/goal_gate.py" goal-slice "$GOAL_FILE" \
    --history "$JOURNEY_HISTORY" ${_spec_targets:+--targets "$_spec_targets"} \
    --out "$GOAL_SLICE_PATH" 2>/dev/null || true
  JOURNEY_DIGEST=$(python3 "$SCRIPT_DIR/lib/goal_gate.py" digest "$JOURNEY_HISTORY" 2>/dev/null || echo "(journey digest unavailable — read $JOURNEY_HISTORY)")
  # Goal-edit drift note: journeys recorded passing whose goal.md text changed
  # since their spec_hash was recorded (the user's mid-session veto mechanism).
  # Histories without spec_hash (pre-NEED-9 sessions) produce no note by design.
  python3 "$SCRIPT_DIR/lib/goal_gate.py" hash-journeys "$GOAL_FILE" \
    --history "$JOURNEY_HISTORY" --out-changed "$ITER_DIR/journeys-changed.md" \
    >/dev/null 2>&1 || true
  if [[ -f "$ITER_DIR/journeys-changed.md" ]]; then
    echo "[run-goal] Goal-edit drift: passing journeys whose goal.md text changed since last verification — see $ITER_DIR/journeys-changed.md"
  fi

  # 4. Goal evaluator
  echo "[run-goal] Step 3: goal-evaluator"
  EVAL_OUTPUT="$ITER_DIR/eval.md"
  # Pre-trim — evaluator spec asks for "last 5 entries"; 300 lines covers it.
  EVALUATOR_LOG_TAIL_5=$(_tail_or_placeholder "$EVALUATOR_LOG" 300 "(no entries yet — first evaluation)")
  # Recompute the assumptions tail fresh (not the decomposer-time value): the
  # decomposer may have appended entries earlier in this same iteration.
  ASSUMPTIONS_TAIL=$(_tail_or_placeholder "$ASSUMPTIONS_FILE" 200 "(no assumptions recorded yet)")
  if [[ -f "$ITER_DIR/.evaluated" && -f "$EVAL_OUTPUT" ]]; then
    # A prior attempt of this iteration completed its evaluation but crashed
    # before current_iter advanced. Re-running the evaluator would double-append
    # evaluator-log.md/lessons.md and re-churn journey-history — reuse instead.
    echo "[run-goal] Iteration $CURRENT_ITER already evaluated (.evaluated marker) — reusing existing eval.md, skipping evaluator re-dispatch."
    cd "$REPO_ROOT"
    _eval_rc=0
  else
  cd "$REPO_ROOT"
  # SPEED-9: deterministic evidence-context lines. The newest demo recording in
  # this session stays valid evidence for journeys whose product code is
  # unchanged since it was made (methodology A.6); the diff status lets the
  # evaluator apply that rule without re-deriving git state.
  _prior_demo_dir="$(ls -1dt "$REPO_ROOT"/reports/demo/goal-"$SESSION_ID"-iter-* 2>/dev/null | head -1 || true)"
  _prior_demo_line="(none recorded yet this session)"
  if [[ -n "$_prior_demo_dir" ]]; then
    _prior_demo_line="${_prior_demo_dir#"$REPO_ROOT"/}/ (results: reports/phase-$(basename "$_prior_demo_dir")-demo-results.md)"
  fi
  _pdiff_status="non-empty"
  if declare -F goal_product_diff_empty >/dev/null 2>&1 \
     && goal_product_diff_empty "$(cat "$ITER_DIR/snapshot-sha" 2>/dev/null || echo "")" "$REPO_ROOT"; then
    _pdiff_status="EMPTY"
  fi
  record_agent_invocation_start "goal-evaluator"   # bare call: must NOT be $(...) or the CHAIN_CURRENT_AGENT export is lost to a subshell
  _eval_start=$CHAIN_AGENT_START_EPOCH
  _eval_rc=0
  claude_with_quota_retry -p "You are the goal-evaluator agent for goal-mode iteration evaluation.

Session ID: $SESSION_ID
Iteration index: $CURRENT_ITER
Iter name: $ITER_NAME
Depth dispatched: $DEPTH

Project goal (SLICED — vision + anti-goals + target/failing journeys verbatim; stable passing journeys digested): $GOAL_SLICE_PATH
  Full goal file: $GOAL_FILE — Read it ONLY if a digested journey becomes relevant.
Iter spec: $ITER_SPEC_PATH
Agent instructions: .claude/agents/goal-evaluator.md  <-- read this first
(CLAUDE.md is already in your system prompt — do not Read it again.)

Iteration artifacts (read what exists):
  Deterministic diff scan (product diff; harness bookkeeping excluded — secrets/deps/license): $ITER_DIR/scan-report.md
  Bounded diff view (complete file list; hunks capped, header lists omissions): $ITER_DIR/iter-diff.md
  Dev handoff: docs/handoffs/${ITER_NAME}-dev.md
  Review report: reports/reviews/${ITER_NAME}-review.md
  QA report: reports/qa/${ITER_NAME}-qa.md (full mode only)
  Audit handoff: docs/handoffs/${ITER_NAME}-audit.md (full mode only)
  Browser QA results: reports/phase-${ITER_NAME}-ui-test-results.md
  Evidence: reports/qa/${ITER_NAME}-evidence/
  Browser-infra token: $ITER_DIR/browser-infra.json  <-- if present: its listed journeys hit a browser INFRA failure (services/Chrome), not a product defect. With no fresh screenshot, score them partial with gap 'pending-infra' and set pending_infra: true in journey-history (methodology A.3); attempts >= 2 in the token = treat the browser infrastructure as a human-owned blocker (STALLED-class)
  Coherence audit: $COHERENCE_OUTPUT  <-- COHERENCE-FAIL vetoes GOAL_ACHIEVED and drives a consolidation CONTINUE
  Goal-edit drift note: $ITER_DIR/journeys-changed.md  <-- if present, each listed journey's prior pass is VOID until re-verified against the CURRENT goal text (your step 3)
  Prior walkthrough recording (methodology A.6 evidence durability — stays valid for journeys whose product code is unchanged since it was recorded): $_prior_demo_line
  Product diff this iteration (deterministic; bookkeeping excluded): $_pdiff_status

Journey state (inline digest — your methodology's section A table starts here):
\`\`\`
$JOURNEY_DIGEST
\`\`\`

Prior session state:
  Journey history: $JOURNEY_HISTORY  <-- update this with new state (full atomic write)
  Iteration state: $ITER_STATE_FILE  <-- OVERWRITE with a fresh ≤40-line digest per templates/iteration-state.md (your step 7); the next decomposer dispatch inlines it verbatim
  Evaluator log: $EVALUATOR_LOG  <-- append a new entry; do not overwrite or read the full file (last 5 entries pre-trimmed below)
  Lessons file: $LESSONS_FILE  <-- append a brief lesson entry capturing a non-obvious takeaway (1-3 sentences). Skip if nothing surprising happened.
  Assumption ledger: $ASSUMPTIONS_FILE  <-- append an entry when a scoring decision required interpreting an ambiguous goal (step 5b of your instructions). Skip when none — zero entries is normal.

Recent evaluator log entries (last 5, pre-trimmed):
\`\`\`
$EVALUATOR_LOG_TAIL_5
\`\`\`

Recent assumption entries (pre-trimmed):
\`\`\`
$ASSUMPTIONS_TAIL
\`\`\`

Write your verdict to: $EVAL_OUTPUT

The verdict line MUST appear at the top of $EVAL_OUTPUT and start exactly with:
**Verdict:** GOAL_ACHIEVED
  or **Verdict:** CONTINUE
  or **Verdict:** ESCALATE
  or **Verdict:** REGRESSION
  or **Verdict:** STALLED

Also include a 'Depth Recommendation For Next Iteration:' line: lean, full, or evidence (evidence = every remaining gap is a capture/recording task on already-working features).

Then update $JOURNEY_HISTORY (full atomic write), OVERWRITE $ITER_STATE_FILE (templates/iteration-state.md shape, ≤40 lines), and append an entry to $EVALUATOR_LOG.
STOP." || _eval_rc=$?

  record_agent_invocation_end "goal-evaluator" "$_eval_start" "$_eval_rc"

  # Pump loss (transport 70) during evaluation: pause resumably. This must be
  # checked BEFORE the missing-file ABORTED branch (which mislabeled pump loss)
  # and before any parse (a stale eval.md must never be certified here — the
  # iteration-start hygiene deletes stale ones, this guard covers the fresh 70).
  if [[ "$_eval_rc" -eq "${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}" ]]; then
    echo "[run-goal] Interactive pump/dispatch unavailable during evaluation — pausing (resume re-runs iteration $CURRENT_ITER)." >&2
    record_telemetry_event "halt" '{"reason":"AWAITING_PUMP","detected_at_step":"goal_evaluator"}'
    write_session_summary "AWAITING_PUMP" "$CURRENT_ITER"
    explain_goal_status "AWAITING_PUMP" "$SESSION_ID" "$REPO_ROOT" >&2
    exit 0
  fi

  if [[ ! -f "$EVAL_OUTPUT" ]]; then
    echo "[run-goal] goal-evaluator did not write $EVAL_OUTPUT — treating as ABORTED." >&2
    write_session_summary "ABORTED" "$CURRENT_ITER"
    explain_goal_status "ABORTED" "$SESSION_ID" "$REPO_ROOT" >&2
    exit 1
  fi
  fi  # end .evaluated reuse guard

  # Parse verdict (guarded: a malformed verdict line must surface as an empty
  # VERDICT for the fallthrough handling, not kill the engine via pipefail)
  VERDICT=$(grep -m1 -E '^\*\*Verdict:\*\*' "$EVAL_OUTPUT" | sed -E 's/^\*\*Verdict:\*\*[[:space:]]*//' | awk '{print $1}') || true
  NEXT_DEPTH=$(grep -m1 -E 'Depth Recommendation For Next Iteration:' "$EVAL_OUTPUT" | sed -E 's/.*Iteration:\*?\*?[[:space:]]*//' | awk '{print $1}' | tr '[:upper:]' '[:lower:]') || true
  [[ "$NEXT_DEPTH" != "lean" && "$NEXT_DEPTH" != "full" && "$NEXT_DEPTH" != "evidence" ]] && NEXT_DEPTH="lean"

  # Mark this iteration's evaluation as complete (with the parsed verdict) so a
  # crash between here and the current_iter advance can resume without a second
  # evaluator pass. Only written for a well-formed verdict.
  if [[ -n "$VERDICT" ]]; then
    printf '{"iter": %s, "verdict": "%s"}\n' "$CURRENT_ITER" "$VERDICT" > "$ITER_DIR/.evaluated" 2>/dev/null || true
  fi

  # ── Deterministic verdict gates (lib/goal-gates.sh) ─────────────────────────
  # Placed BEFORE the session.json write so every downstream consumer (deltas,
  # telemetry, per-iter push, halt cases) sees the FINAL verdict. GOAL_ACHIEVED
  # must survive the mechanical gates + the two-key confirm; malformed verdicts
  # are bounded (2 consecutive → ABORT_MALFORMED); undeclared regressions are
  # surfaced. Disable via CHAIN_GOAL_GATES=false.
  _coherence_expected="false"
  [[ $CURRENT_ITER -gt 0 && -f "$BLUEPRINT_FILE" ]] && _coherence_expected="true"
  _raw_verdict="$VERDICT"
  VERDICT="$(goal_gate_filter_verdict "$_raw_verdict" "$ITER_DIR" "$EVAL_OUTPUT" "$JOURNEY_HISTORY" "$COHERENCE_OUTPUT" "$_coherence_expected" "$REPO_ROOT/reports/phase-${ITER_NAME}-ui-test-results.md" "$GOAL_SESSION_DIR_LOCAL" "$GOAL_SLICE_PATH")"
  if [[ "$VERDICT" != "$_raw_verdict" ]]; then
    echo "[run-goal] Verdict gate: evaluator said '$_raw_verdict' → final verdict '$VERDICT'."
    echo "[run-goal]   (A safety rule overrode the evaluator's claim — the stricter verdict wins.)"
    record_telemetry_event "deterministic_gate" "$(jq -cn --arg r "$_raw_verdict" --arg f "$VERDICT" '{raw:$r, final:$f}' 2>/dev/null || printf '{"raw":"%s","final":"%s"}' "$_raw_verdict" "$VERDICT")"
  fi

  # Capture journey-history hash for stall detection
  HASH=$(journey_history_hash)
  echo "$HASH" >> "$GOAL_SESSION_DIR_LOCAL/.history-hashes"

  # Showcase tail (demo → summary MD → README → HTML renders). The MD is the
  # source of truth — the renderer just visualizes it. Non-blocking either way:
  # halt verdicts run it INLINE here (final artifacts must be complete before
  # the session summary); CONTINUE/ESCALATE defer it to a background fork after
  # the push below, overlapping the next iteration's decomposer.
  _async_showcase="no"
  if [[ "${CHAIN_ASYNC_SHOWCASE:-true}" == "true" ]]; then
    case "$VERDICT" in CONTINUE|ESCALATE) _async_showcase="yes" ;; esac
  fi
  if [[ "$_async_showcase" != "yes" ]]; then
    _run_showcase_steps "$ITER_NAME" "$DEPTH"
  fi
  _iter_md="$REPO_ROOT/reports/phase-${ITER_NAME}-iteration-summary.md"
  _iter_html="$REPO_ROOT/reports/phase-${ITER_NAME}-summary.html"
  _session_index_html="$REPO_ROOT/reports/goal-session-${SESSION_ID}-index.html"
  [[ -f "$_iter_md" ]]            && echo "[run-goal] Iteration summary MD:   $_iter_md"
  [[ -f "$_iter_html" ]]          && echo "[run-goal] Iteration summary HTML: file://$_iter_html"
  [[ -f "$_session_index_html" ]] && echo "[run-goal] Session index HTML:     file://$_session_index_html"

  # Update session.json
  python3 - <<PY
import json
d = json.load(open("$SESSION_JSON"))
d["current_iter"] = $CURRENT_ITER + 1
d["last_verdict"] = "$VERDICT"
d["next_depth"] = "$NEXT_DEPTH"
d["status"] = "in_progress"
d["updated_at"] = __import__("datetime").datetime.now(__import__("datetime").UTC).isoformat().replace('+00:00','Z')
import os as _os, tempfile as _tf
_fd, _tmp = _tf.mkstemp(dir=_os.path.dirname("$SESSION_JSON") or ".", suffix=".sjtmp")
with _os.fdopen(_fd, "w") as _f:
    json.dump(d, _f, indent=2)
    _f.write("\n")
_os.replace(_tmp, "$SESSION_JSON")
PY

  # Compute deltas (best-effort)
  DELTAS=$(python3 -c "
import json
try:
    d = json.load(open('$JOURNEY_HISTORY'))
    js = d.get('journeys', {})
    counts = {'newly_passing':0, 'newly_failing':0, 'regressed':0, 'anti_goal_violations': len(d.get('anti_goal_violations',[]))}
    for jid, info in js.items():
        if info.get('status') in ('regressed',):
            counts['regressed'] += 1
        elif info.get('last_verified_iter') == '$ITER_NAME' and info.get('status') == 'passing':
            counts['newly_passing'] += 1
        elif info.get('last_verified_iter') == '$ITER_NAME' and info.get('status') == 'failing':
            counts['newly_failing'] += 1
    print(json.dumps(counts))
except Exception as e:
    print(json.dumps({'error': str(e)}))
")

  record_telemetry_event "iter_end" "$(jq -cn --arg n "$ITER_NAME" --arg v "$VERDICT" --arg nd "$NEXT_DEPTH" --argjson dl "$DELTAS" '{iter_name:$n, verdict:$v, next_depth:$nd, journey_deltas:$dl}' 2>/dev/null || printf '{"iter_name":"%s","verdict":"%s"}' "$ITER_NAME" "$VERDICT")"

  # Where did this iteration's wall time go? Human-readable per-step breakdown
  # from the telemetry events just recorded (non-blocking, no model).
  python3 "$SCRIPT_DIR/lib/analyze_telemetry.py" --wall --iter "$CURRENT_ITER" \
    "$GOAL_SESSION_DIR_LOCAL/telemetry.jsonl" 2>/dev/null | sed 's/^/[run-goal] /' || true

  # Experiment tripwire: while an opt-in speed knob is active, revert it the
  # moment quality moves in the window (REGRESSION verdict, journey
  # regressions, repeated first-attempt review FAILs). Exit 3 = TRIP; any
  # other non-zero rc is an analyzer error and must NOT trigger a revert.
  if [[ -n "${CHAIN_AGENT_EFFORT:-}" ]]; then
    _trip_rc=0
    python3 "$SCRIPT_DIR/lib/analyze_telemetry.py" --tripwire --window 3 \
      "$GOAL_SESSION_DIR_LOCAL/telemetry.jsonl" > "$ITER_DIR/.tripwire-report" 2>/dev/null || _trip_rc=$?
    if [[ "$_trip_rc" -eq 3 ]]; then
      echo "[run-goal] EXPERIMENT TRIPWIRE: quality moved under CHAIN_AGENT_EFFORT='$CHAIN_AGENT_EFFORT' — reverting the knob for the rest of this run." >&2
      sed 's/^/[run-goal]   /' "$ITER_DIR/.tripwire-report" >&2 2>/dev/null || true
      record_telemetry_event "experiment_reverted" "$(jq -cn --arg k "CHAIN_AGENT_EFFORT" --arg v "$CHAIN_AGENT_EFFORT" '{key:$k, value:$v}' 2>/dev/null || printf '{"key":"CHAIN_AGENT_EFFORT"}')"
      unset CHAIN_AGENT_EFFORT
    fi
    rm -f "$ITER_DIR/.tripwire-report" 2>/dev/null || true
  fi

  echo "[run-goal] Verdict: $VERDICT (next depth: $NEXT_DEPTH)"
  explain_goal_verdict "$VERDICT" "$NEXT_DEPTH"

  # 4b. Push per iter (if enabled). Direct git only — no model invocation.
  # Eligibility: CONTINUE / ESCALATE / GOAL_ACHIEVED. REGRESSION / STALLED
  # halts skip the push so the remote isn't left in a state the user hasn't
  # had a chance to inspect.
  if [[ "$PUSH_PER_ITER" == "true" ]]; then
    case "$VERDICT" in
      CONTINUE|ESCALATE|GOAL_ACHIEVED)
        if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]]; then
          _push_summary=$(printf '%s' "$DELTAS" | jq -r '"passing+\(.newly_passing // 0) failing+\(.newly_failing // 0) regressed+\(.regressed // 0)"' 2>/dev/null || echo "deltas-unavailable")
          _push_np=$(printf '%s' "$DELTAS" | jq -r '.newly_passing // 0' 2>/dev/null || echo 0)
          _push_nf=$(printf '%s' "$DELTAS" | jq -r '.newly_failing // 0' 2>/dev/null || echo 0)
          _push_rg=$(printf '%s' "$DELTAS" | jq -r '.regressed // 0' 2>/dev/null || echo 0)
          _push_av=$(printf '%s' "$DELTAS" | jq -r '.anti_goal_violations // 0' 2>/dev/null || echo 0)
          _push_msg=$(printf 'goal(%s): iter %s — %s (%s)\n\nTarget journeys: %s\nVerdict: %s\nNewly passing: %s\nNewly failing: %s\nRegressed: %s\nAnti-goal violations: %s\nIter spec: docs/phases/%s.md\nIter eval: runs/goal-session-%s/iter-%s/eval.md\n' \
            "$SESSION_ID" "$CURRENT_ITER" "$VERDICT" "$_push_summary" \
            "${TARGET_JOURNEYS:-(none parsed)}" "$VERDICT" \
            "$_push_np" "$_push_nf" "$_push_rg" "$_push_av" \
            "$ITER_NAME" "$SESSION_ID" "$CURRENT_ITER")

          _push_ok=false
          _push_sha=""
          _push_err=""
          if git -C "$REPO_ROOT" add -A 2>/dev/null; then
            if git -C "$REPO_ROOT" commit -m "$_push_msg" >/dev/null 2>&1; then
              _push_sha=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "")
              # GIT_TERMINAL_PROMPT=0 → if the GitHub session expired mid-run,
              # the push fails fast instead of hanging on a username/pw prompt.
              if GIT_TERMINAL_PROMPT=0 git -C "$REPO_ROOT" push -u origin HEAD >/dev/null 2>&1; then
                _push_ok=true
                echo "[run-goal] push-per-iter: pushed iter $CURRENT_ITER (${_push_sha:0:8}) to '$PUSH_BRANCH'"
              else
                _push_err="push failed"
                echo "[run-goal] push-per-iter: WARNING — commit ${_push_sha:0:8} was created but 'git push origin HEAD' failed; commit is local only. Run 'gh auth login' to restore push — local commits push next iteration. Continuing." >&2
              fi
            else
              _push_err="commit failed"
              echo "[run-goal] push-per-iter: WARNING — 'git commit' failed for iter $CURRENT_ITER. Continuing." >&2
            fi
          else
            _push_err="add failed"
            echo "[run-goal] push-per-iter: WARNING — 'git add -A' failed for iter $CURRENT_ITER. Continuing." >&2
          fi

          record_telemetry_event "iter_push" "$(jq -cn \
            --arg b "$PUSH_BRANCH" \
            --arg sha "$_push_sha" \
            --argjson ok "$_push_ok" \
            --arg err "$_push_err" \
            --arg verdict "$VERDICT" \
            '{branch:$b, commit_sha:$sha, success:$ok, error:$err, verdict:$verdict}' 2>/dev/null || printf '{"branch":"%s","success":%s}' "$PUSH_BRANCH" "$_push_ok")"
        else
          echo "[run-goal] push-per-iter: iter $CURRENT_ITER produced no working-tree changes; skipping commit + push."
          record_telemetry_event "iter_push" "$(jq -cn --arg b "$PUSH_BRANCH" --arg verdict "$VERDICT" '{branch:$b, success:true, skipped:"no_changes", verdict:$verdict}' 2>/dev/null || echo '{}')"
        fi
        ;;
      REGRESSION|STALLED)
        # (inline showcase already ran for these halt verdicts)
        echo "[run-goal] push-per-iter: skipping push for $VERDICT — branch left at prior iter's HEAD for inspection."
        # Park the iteration's uncommitted work as a local WIP commit (no push).
        # Left loose, it was exposed to manual cleanup (git checkout/--reset) and
        # would otherwise be silently folded into the NEXT iteration's commit
        # under a misleading message, breaking attribution and bisect.
        if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]]; then
          _park_sha=""
          if git -C "$REPO_ROOT" add -A 2>/dev/null && \
             git -C "$REPO_ROOT" commit --quiet -m "wip(goal): iter $CURRENT_ITER $VERDICT — parked uncommitted work (not pushed)" 2>/dev/null; then
            _park_sha="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "")"
            echo "[run-goal] push-per-iter: parked uncommitted work as local WIP commit ${_park_sha} (amend/revert freely before resuming)."
            python3 - <<PY 2>/dev/null || true
import json, os, tempfile
d = json.load(open("$SESSION_JSON"))
d["parked_wip_sha"] = "${_park_sha}"
_fd, _tmp = tempfile.mkstemp(dir=os.path.dirname("$SESSION_JSON") or ".", suffix=".sjtmp")
with os.fdopen(_fd, "w") as _f:
    json.dump(d, _f, indent=2)
    _f.write("\n")
os.replace(_tmp, "$SESSION_JSON")
PY
          else
            echo "[run-goal] push-per-iter: WARNING — could not park uncommitted work (git add/commit failed); it remains loose in the working tree." >&2
          fi
          record_telemetry_event "wip_parked" "$(jq -cn --arg v "$VERDICT" --arg sha "${_park_sha:-}" '{verdict:$v, sha:$sha}' 2>/dev/null || echo '{}')"
        fi
        record_telemetry_event "iter_push" "$(jq -cn --arg b "$PUSH_BRANCH" --arg verdict "$VERDICT" '{branch:$b, success:true, skipped:"halt_verdict", verdict:$verdict}' 2>/dev/null || echo '{}')"
        ;;
    esac
  fi

  # 4c. Deferred showcase tail: fork AFTER the push so the iteration's own
  # commit is exactly what the sequential ordering produced; the group's
  # artifacts land via _join_showcase_tail before the next executor dispatch.
  if [[ "$_async_showcase" == "yes" ]]; then
    _fork_showcase_tail "$ITER_NAME" "$DEPTH"
  fi

  # 5. Halt-on-verdict
  case "$VERDICT" in
    GOAL_ACHIEVED)
      # ── Continuous-improvement opt-in (framework mechanism "M3") ────────────────
      # DEFAULT-OFF: fires ONLY when the project provides BOTH
      #   project-extensions/hooks/post-goal.sh   AND
      #   project-extensions/proposer-guidance.md
      # (both OUTSIDE the framework subtree). Absent either ⇒ this block is skipped
      # and the session finalizes exactly as before, so other projects sharing this
      # framework are unaffected. When opted in: run the project's deterministic prep
      # hook, then dispatch the generic goal-proposer agent (it surveys the product,
      # keeps only hold-out survivors, writes the proposals backlog, and surgically
      # appends new Must-have journeys into the goal file's <!-- AUTO:journeys -->
      # block). CONTINUE the loop iff it extended the goal — the unmodified decomposer
      # then builds the new (not-yet-passing) journey next iteration. If the proposer
      # is dry (nothing survived), fall through to the normal terminal halt below.
      if [[ -f "$REPO_ROOT/project-extensions/hooks/post-goal.sh" \
            && -f "$REPO_ROOT/project-extensions/proposer-guidance.md" ]]; then
        echo "[run-goal] Continuous improvement: all journeys passing — post-goal hook + goal-proposer ..."
        _state_dir="$GOAL_SESSION_DIR_LOCAL/state"
        mkdir -p "$_state_dir"
        rm -f "$_state_dir/proposer-result.json"
        # 1. deterministic project prep (non-fatal): e.g. refresh the triad scan snapshot.
        (
          export SESSION_ID REPO_ROOT GOAL_FILE \
                 SESSION_DIR="$GOAL_SESSION_DIR_LOCAL" \
                 LEDGER_PATH="$GOAL_SESSION_DIR_LOCAL/state/certified-claims.jsonl" \
                 STAGING_LEDGER_PATH="$GOAL_SESSION_DIR_LOCAL/state/staging-ledger.jsonl"
          run_project_hook post-goal
        ) || echo "[run-goal] post-goal hook returned non-zero (non-fatal) — continuing." >&2
        # 2. dispatch the generic goal-proposer agent (works headless AND interactive pump).
        cd "$REPO_ROOT"
        record_agent_invocation_start "goal-proposer"
        _prop_start=$CHAIN_AGENT_START_EPOCH
        _prop_rc=0
        claude_with_quota_retry -p "You are the goal-proposer agent for goal-mode continuous improvement.

Session ID: $SESSION_ID
Session state dir: $GOAL_SESSION_DIR_LOCAL/state
Goal file: $GOAL_FILE  <-- extend ONLY the <!-- AUTO:journeys --> block
Project guidance: project-extensions/proposer-guidance.md  <-- read this FIRST; it governs everything
Agent instructions: .claude/agents/goal-proposer.md  <-- read this first
(CLAUDE.md is already in your system prompt — do not Read it again.)

Every Must-have journey is passing. Survey the whole product per the guidance, keep only hold-out
survivors, write the proposals backlog, and promote the best 1-2 into new Must-have journeys in the
goal file's AUTO:journeys block (follow the goal-self-extension skill; bake the consistency + walkthrough
requirements into each journey's Acceptance). If nothing new survives, leave the goal file UNTOUCHED.
Then write $GOAL_SESSION_DIR_LOCAL/state/proposer-result.json with keys extended, n_new_journeys,
n_proposals, dry.

Do NOT write product code or start services." || _prop_rc=$?
        record_agent_invocation_end "goal-proposer" "$_prop_start" "$_prop_rc"
        # 3. continue the loop iff the proposer extended the goal with new buildable journey(s).
        _prop_extended=$(python3 -c "import json,sys; print('yes' if json.load(open('$_state_dir/proposer-result.json')).get('extended') else 'no')" 2>/dev/null || echo "no")
        if [[ "$_prop_extended" == "yes" ]]; then
          echo "[run-goal] Continuous improvement: goal extended with new journey(s) — continuing to build them."
          record_telemetry_event "goal_extended" "$(jq -cn --arg s "$SESSION_ID" '{session:$s}' 2>/dev/null || echo '{}')"
          CURRENT_ITER=$((CURRENT_ITER+1))
          continue
        fi
        echo "[run-goal] Continuous improvement: proposer found nothing new (dry) — finalizing the session."
      fi
      # Render the one-time delivered wrap BEFORE write_session_summary so the
      # session-index renderer (invoked inside write_session_summary) can find
      # delivered.html and surface a prominent link to it. Non-blocking.
      _render_final_delivered "$SESSION_ID"
      write_session_summary "GOAL_ACHIEVED" "$((CURRENT_ITER+1))"
      explain_goal_status "GOAL_ACHIEVED" "$SESSION_ID" "$REPO_ROOT"
      if [[ "$AUTO_RELEASE" == "true" ]]; then
        # Direct gh pr create from $PUSH_BRANCH — every iter commit is already
        # there from the per-iter push, so we only need to open the PR. We
        # deliberately do NOT invoke finalize-phase.sh / release-manager here:
        # that path would create a separate `phase/<iter-name>` branch via
        # release-manager.md's policy, fragmenting the single-branch model.
        if [[ "$PUSH_PER_ITER" != "true" || -z "$PUSH_BRANCH" ]]; then
          echo "[run-goal] --auto-release: skipping PR creation — per-iter push was off, so no session branch exists." >&2
          echo "[run-goal]   To enable: start a fresh session with --push-per-iter, or commit + push manually." >&2
          record_telemetry_event "goal_release_pr_skipped" '{"reason":"no_session_branch"}'
        else
          _final_iter_count=$((CURRENT_ITER+1))
          _pr_title="goal(${SESSION_ID}): GOAL_ACHIEVED after ${_final_iter_count} iterations"
          if check_gh_auth; then
            _pr_create_out=""
            if _pr_create_out=$(gh pr create --base main --head "$PUSH_BRANCH" --title "$_pr_title" --body-file "$SUMMARY_FILE" 2>&1); then
              echo "[run-goal] --auto-release: opened PR from $PUSH_BRANCH"
              echo "[run-goal]   $_pr_create_out"
              record_telemetry_event "goal_release_pr_created" "$(jq -cn --arg b "$PUSH_BRANCH" --arg url "$_pr_create_out" '{branch:$b, pr_url:$url}' 2>/dev/null || echo '{}')"
            else
              echo "[run-goal] --auto-release: gh pr create failed:" >&2
              echo "[run-goal]   $_pr_create_out" >&2
              echo "[run-goal]   Branch $PUSH_BRANCH is already pushed. Create the PR manually:" >&2
              echo "[run-goal]   gh pr create --base main --head $PUSH_BRANCH --title \"$_pr_title\" --body-file $SUMMARY_FILE" >&2
              record_telemetry_event "goal_release_pr_failed" "$(jq -cn --arg b "$PUSH_BRANCH" --arg err "$_pr_create_out" '{branch:$b, error:$err}' 2>/dev/null || echo '{}')"
            fi
          else
            echo "[run-goal] --auto-release: gh CLI not authenticated. Branch $PUSH_BRANCH is already pushed." >&2
            echo "[run-goal]   To open the PR: gh auth login && \\" >&2
            echo "[run-goal]     gh pr create --base main --head $PUSH_BRANCH --title \"$_pr_title\" --body-file $SUMMARY_FILE" >&2
            record_telemetry_event "goal_release_pr_skipped" '{"reason":"gh_not_authenticated"}'
          fi
        fi
      fi
      exit 0
      ;;
    REGRESSION)
      python3 - <<PY
import json
d = json.load(open("$SESSION_JSON"))
d["status"] = "REGRESSION_HALT"
import os as _os, tempfile as _tf
_fd, _tmp = _tf.mkstemp(dir=_os.path.dirname("$SESSION_JSON") or ".", suffix=".sjtmp")
with _os.fdopen(_fd, "w") as _f:
    json.dump(d, _f, indent=2)
    _f.write("\n")
_os.replace(_tmp, "$SESSION_JSON")
PY
      record_telemetry_event "halt" '{"reason":"REGRESSION_HALT","detected_at_step":"post_evaluator"}'
      write_session_summary "REGRESSION_HALT" "$((CURRENT_ITER+1))"
      echo "[run-goal] REGRESSION_HALT — review $EVAL_OUTPUT, fix the regression, then resume with --acknowledge-regression." >&2
      explain_goal_status "REGRESSION_HALT" "$SESSION_ID" "$REPO_ROOT" >&2
      exit 1
      ;;
    STALLED)
      record_telemetry_event "halt" '{"reason":"STALLED","detected_at_step":"post_evaluator"}'
      write_session_summary "STALLED" "$((CURRENT_ITER+1))"
      echo "[run-goal] STALLED per evaluator. Edit goal.md and resume with --resume." >&2
      explain_goal_status "STALLED" "$SESSION_ID" "$REPO_ROOT" >&2
      exit 0
      ;;
    CONTINUE|ESCALATE)
      CURRENT_ITER=$((CURRENT_ITER+1))
      ;;
    ABORT_MALFORMED)
      # The gate saw 2 consecutive malformed/unknown evaluator verdicts —
      # something is systematically wrong (prompt drift, model failure).
      # Halting beats the old behavior of silently CONTINUE-ing forever.
      echo "[run-goal] ABORT_MALFORMED — two consecutive malformed evaluator verdicts. Inspect $ITER_DIR/eval.md, fix the cause (or run with CHAIN_GOAL_GATES=false to bypass), then --resume." >&2
      record_telemetry_event "halt" '{"reason":"ABORT_MALFORMED","detected_at_step":"verdict_gate"}'
      write_session_summary "ABORTED" "$CURRENT_ITER"
      explain_goal_status "ABORT_MALFORMED" "$SESSION_ID" "$REPO_ROOT" >&2
      exit 1
      ;;
    *)
      echo "[run-goal] Unknown verdict '$VERDICT' — treating as CONTINUE." >&2
      CURRENT_ITER=$((CURRENT_ITER+1))
      ;;
  esac
done
