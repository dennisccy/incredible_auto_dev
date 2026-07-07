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
#   AWAITING_PUMP    - interactive pump/dispatch was unavailable mid-iteration (the foreground
#                      session/pump went away); resumable — /goal-resume re-runs the same iteration
#
# Quota exhaustion is NOT a halt: claude_with_quota_retry transparently sleeps
# until the quota resets and resumes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/telemetry.sh"
source "$SCRIPT_DIR/lib/goal-gates.sh"

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
LESSONS_FILE="$GOAL_SESSION_DIR_LOCAL/state/lessons.md"
# Coherence blueprint (information architecture + data contract). Drafted by the
# baseline decomposer, approved once by the human, enforced each iteration.
BLUEPRINT_FILE="$GOAL_SESSION_DIR_LOCAL/state/blueprint.md"
BLUEPRINT_APPROVED="$GOAL_SESSION_DIR_LOCAL/state/blueprint.approved"
BLUEPRINT_REAPPROVAL="$GOAL_SESSION_DIR_LOCAL/state/blueprint.reapproval-requested"
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

Apply the TOKEN AND QUESTIONING POLICY from .claude/core.md strictly.

Read every relevant input listed in your agent instructions. Files that don't
exist should be silently skipped. Use what is present. The dispatch wrapper
has pre-trimmed evaluator-log.md below — use the inline content.

Recent evaluator log entries (last 300 lines, pre-trimmed):
---
${eval_log_inline}
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
      if [[ -n "$_changed" && "$_changed" != "__git_error__" ]]; then
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

Apply the TOKEN AND QUESTIONING POLICY from .claude/core.md strictly.

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

Apply the TOKEN AND QUESTIONING POLICY from .claude/core.md strictly.

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
    bash "$SCRIPT_DIR/demo-phase.sh" "$iter_name" \
      || echo "[run-goal] demo-phase.sh exited non-zero — continuing (showcase, non-gating)"
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
#   _tail_or_placeholder <file> <max-lines> <placeholder>
_tail_or_placeholder() {
  local file="$1" max="$2" placeholder="$3"
  if [[ -f "$file" && -s "$file" ]]; then
    tail -n "$max" "$file"
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
    echo "  See templates/project-goal.md for the format. See .claude/anti-patterns.md #18." >&2
    exit 1
  fi

  if ! grep -q "^## Anti-goals" "$GOAL_FILE"; then
    echo "Error: $GOAL_FILE is missing the '## Anti-goals' section." >&2
    echo "  See templates/project-goal.md for the format. See .claude/anti-patterns.md #18." >&2
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
    print("  See .claude/anti-patterns.md #18 for examples.", file=sys.stderr)
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
  echo "════════════════════════════════════════════════════════════════════"
  exit 0
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
if "$RUN_MODE" == "resume" and d.get("status") in ("REGRESSION_HALT", "AWAITING_BLUEPRINT_APPROVAL", "AWAITING_PUMP"):
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
QUOTA_PAUSE_COUNT_FILE="$GOAL_SESSION_DIR_LOCAL/.quota-pause-count"
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
    AWAITING_PUMP|ABORTED) _join_showcase_tail --kill ;;
    *)                     _join_showcase_tail ;;
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
  _render_session_index_html
  local _idx_html="$REPO_ROOT/reports/goal-session-${SESSION_ID}-index.html"
  [[ -f "$_idx_html" ]] && echo "[run-goal] Session HTML: file://$_idx_html"
}

# Record this engine's PID so /goal-pause and a resuming run can find and stop it
# across separate command invocations (the interactive pump's in-memory PID is
# not available to a later /goal-pause). Cleaned up on any exit, including the
# on_abort path below (which exits 130 → the EXIT trap fires).
echo "$$" > "$ENGINE_PID_FILE" 2>/dev/null || true
trap '_join_showcase_tail --kill 2>/dev/null; rm -f "$ENGINE_PID_FILE" 2>/dev/null || true' EXIT

# Trap: on SIGINT/SIGTERM, write ABORTED summary. Kill the background showcase
# tail FIRST so Ctrl-C never blocks on a non-gating summary/README agent.
on_abort() {
  echo "[run-goal] Aborted by user signal. Writing summary." >&2
  _join_showcase_tail --kill 2>/dev/null || true
  write_session_summary "ABORTED" "$CURRENT_ITER"
  exit 130
}
trap on_abort INT TERM

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
    exit 0
  fi

  if [[ $CURRENT_ITER -gt 0 ]] && is_stalled "$STALL_WINDOW"; then
    echo "[run-goal] STALLED — last $STALL_WINDOW iterations made no journey progress."
    record_telemetry_event "halt" '{"reason":"STALLED","detected_at_step":"pre_decomposer"}'
    write_session_summary "STALLED" "$CURRENT_ITER"
    exit 0
  fi

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

  echo "[run-goal] Step 1: goal-decomposer (mode: $DECOMPOSER_MODE)"
  # Pre-trim historical state — pass only the tail to the decomposer so token
  # usage stays flat as the session grows. Spec asks for "last 3 entries";
  # 200 lines is conservative and covers multi-paragraph entries.
  EVALUATOR_LOG_TAIL=$(_tail_or_placeholder "$EVALUATOR_LOG" 200 "(no entries yet — first iteration)")
  LESSONS_TAIL=$(_tail_or_placeholder "$LESSONS_FILE" 200 "(no lessons recorded yet)")
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
     && grep -qiE '(\*\*)?Depth:(\*\*)?[[:space:]]*(lean|full)' "$ITER_SPEC_PATH"; then
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
Journey state (inline digest; Read $JOURNEY_HISTORY only for fields the digest omits):
\`\`\`
$JOURNEY_DIGEST
\`\`\`

$( [[ $CURRENT_ITER -gt 0 && -f "$GOAL_SESSION_DIR_LOCAL/iter-$((CURRENT_ITER-1))/eval.md" ]] && echo "Last iteration eval: $GOAL_SESSION_DIR_LOCAL/iter-$((CURRENT_ITER-1))/eval.md")

Apply the TOKEN AND QUESTIONING POLICY from .claude/core.md strictly.

Write the iteration spec to: docs/phases/${ITER_NAME}.md
$( if [[ "$DECOMPOSER_MODE" == "baseline" ]]; then echo "BASELINE also: draft the coherence blueprint to $BLUEPRINT_FILE per your agent instructions (Information Architecture + Data Contract, ~one screen, from docs/goal.md's Product Shape + Must-have journeys + Key Capabilities). The blueprint is auto-approved by default and the loop proceeds; pass --require-blueprint-approval to pause for human review after baseline."; else echo "Also keep $BLUEPRINT_FILE current per your agent instructions: register any new displayed value in the Data Contract and place new pages under an existing Information-Architecture home (additive edits only). For a nav-skeleton change, make the edit AND write a one-line reason to $BLUEPRINT_REAPPROVAL."; fi )

The spec MUST include a 'Goal Mode Metadata' section with at minimum:
  - Mode: $DECOMPOSER_MODE
  - Depth: lean | full
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
    exit 0
  fi

  if [[ $_decomp_rc -ne 0 ]]; then
    echo "[run-goal] goal-decomposer failed with exit $_decomp_rc — aborting." >&2
    record_telemetry_event "halt" '{"reason":"DECOMPOSER_FAILED","detected_at_step":"decomposer"}'
    write_session_summary "ABORTED" "$CURRENT_ITER"
    exit "$_decomp_rc"
  fi

  if [[ ! -f "$ITER_SPEC_PATH" ]]; then
    echo "[run-goal] goal-decomposer did not write spec at $ITER_SPEC_PATH — aborting." >&2
    write_session_summary "ABORTED" "$CURRENT_ITER"
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
  if [[ "$DEPTH" != "lean" && "$DEPTH" != "full" ]]; then
    echo "[run-goal] Could not parse Depth (expected 'lean' or 'full') from $ITER_SPEC_PATH. Defaulting to lean." >&2
    DEPTH="lean"
  fi

  TARGET_JOURNEYS=$(grep -m1 -E '^[[:space:]]*-?[[:space:]]*\*\*Target journeys:\*\*' "$ITER_SPEC_PATH" \
                      | sed -E 's/.*\*\*Target journeys:\*\*[[:space:]]*//' || echo "")

  echo "[run-goal] Iter spec depth: $DEPTH"
  echo "[run-goal] Target journeys: ${TARGET_JOURNEYS:-(none parsed)}"
  record_telemetry_event "iter_dispatch" "$(jq -cn --arg d "$DEPTH" --arg tj "$TARGET_JOURNEYS" '{depth:$d, target_journeys:$tj}' 2>/dev/null || printf '{"depth":"%s"}' "$DEPTH")"

  # 2c. Join the previous iteration's background showcase tail (if any) BEFORE
  # dispatching build work: its artifacts get committed here, so developer /
  # reviewer of THIS iteration see exactly the tree the sequential ordering
  # would have produced. Overlapping it with the decomposer above is where the
  # ~6-13 min saving comes from.
  _join_showcase_tail

  # 3. Dispatch. Reset the per-iteration exit code first: _exec_rc is a plain
  # shell var, so a stale 70 from a prior iteration would otherwise survive into
  # this one (the `:-0` default only fills an UNSET var) and mis-fire the
  # transport-pause check below.
  _exec_rc=0
  if [[ "$DEPTH" == "full" ]]; then
    _full_extra_args=(--no-finalize)
    echo "[run-goal] Dispatching FULL pipeline via run-phase.sh ${_full_extra_args[*]} ..."
    if grep -q '\-\-no-finalize' "$SCRIPT_DIR/run-phase.sh"; then
      bash "$SCRIPT_DIR/run-phase.sh" "$ITER_NAME" "${_full_extra_args[@]}" || _exec_rc=$?
    else
      echo "[run-goal] run-phase.sh does not yet support --no-finalize. Falling back to lean for safety." >&2
      bash "$SCRIPT_DIR/goal-iter-lean.sh" "$ITER_NAME" || _exec_rc=$?
    fi
  else
    echo "[run-goal] Dispatching LEAN pipeline via goal-iter-lean.sh ..."
    bash "$SCRIPT_DIR/goal-iter-lean.sh" "$ITER_NAME" || _exec_rc=$?
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
    # Resume-skip: a prior attempt's audit is reusable only when its checkpoint,
    # the verdict line, AND the tree state all verify (a drifted tree means the
    # audited diff is no longer this iteration's diff).
    if step_done_valid coherence --verify-tree --dir "$ITER_DIR" "$COHERENCE_OUTPUT" \
       && grep -qE '^\*\*Verdict:\*\* COHERENCE-(PASS|WARN|FAIL)' "$COHERENCE_OUTPUT"; then
      echo "[run-goal] Resume: coherence audit already completed for iteration $CURRENT_ITER (checkpoint + tree verified) — reusing $COHERENCE_OUTPUT."
      record_telemetry_event "step_skipped" "$(jq -cn --arg n "$ITER_NAME" '{step:"coherence-auditor", iter_name:$n, reason:"checkpoint"}' 2>/dev/null || printf '{"step":"coherence-auditor"}')"
    else
    step_invalidate_from coherence "$ITER_DIR"
    _coh_dispatched=1
    echo "[run-goal] Step 2b: coherence-auditor"
    _snapshot_sha="$(cat "$ITER_DIR/snapshot-sha" 2>/dev/null || echo "")"
    _coh_rc=0
    dispatch_coherence_audit "$SESSION_ID" "$CURRENT_ITER" "$ITER_NAME" \
      "$BLUEPRINT_FILE" "$ITER_SPEC_PATH" "$COHERENCE_OUTPUT" "$_snapshot_sha" || _coh_rc=$?
    # Pump loss (transport 70) is infrastructure, not an audit result — without
    # this guard a dead pump fabricated a COHERENCE-PASS via the crash stub below.
    if [[ "$_coh_rc" -eq "${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}" ]]; then
      echo "[run-goal] Interactive pump/dispatch unavailable during coherence audit — pausing (resume re-runs iteration $CURRENT_ITER)." >&2
      record_telemetry_event "halt" '{"reason":"AWAITING_PUMP","detected_at_step":"coherence_auditor"}'
      write_session_summary "AWAITING_PUMP" "$CURRENT_ITER"
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

  # 4. Goal evaluator
  echo "[run-goal] Step 3: goal-evaluator"
  EVAL_OUTPUT="$ITER_DIR/eval.md"
  # Pre-trim — evaluator spec asks for "last 5 entries"; 300 lines covers it.
  EVALUATOR_LOG_TAIL_5=$(_tail_or_placeholder "$EVALUATOR_LOG" 300 "(no entries yet — first evaluation)")
  if [[ -f "$ITER_DIR/.evaluated" && -f "$EVAL_OUTPUT" ]]; then
    # A prior attempt of this iteration completed its evaluation but crashed
    # before current_iter advanced. Re-running the evaluator would double-append
    # evaluator-log.md/lessons.md and re-churn journey-history — reuse instead.
    echo "[run-goal] Iteration $CURRENT_ITER already evaluated (.evaluated marker) — reusing existing eval.md, skipping evaluator re-dispatch."
    cd "$REPO_ROOT"
    _eval_rc=0
  else
  cd "$REPO_ROOT"
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
  Deterministic diff scan (FULL diff — secrets/deps/license): $ITER_DIR/scan-report.md
  Bounded diff view (complete file list; hunks capped, header lists omissions): $ITER_DIR/iter-diff.md
  Dev handoff: docs/handoffs/${ITER_NAME}-dev.md
  Review report: reports/reviews/${ITER_NAME}-review.md
  QA report: reports/qa/${ITER_NAME}-qa.md (full mode only)
  Audit handoff: docs/handoffs/${ITER_NAME}-audit.md (full mode only)
  Browser QA results: reports/phase-${ITER_NAME}-ui-test-results.md
  Evidence: reports/qa/${ITER_NAME}-evidence/
  Coherence audit: $COHERENCE_OUTPUT  <-- COHERENCE-FAIL vetoes GOAL_ACHIEVED and drives a consolidation CONTINUE

Journey state (inline digest — your methodology's section A table starts here):
\`\`\`
$JOURNEY_DIGEST
\`\`\`

Prior session state:
  Journey history: $JOURNEY_HISTORY  <-- update this with new state (full atomic write)
  Evaluator log: $EVALUATOR_LOG  <-- append a new entry; do not overwrite or read the full file (last 5 entries pre-trimmed below)
  Lessons file: $LESSONS_FILE  <-- append a brief lesson entry capturing a non-obvious takeaway (1-3 sentences). Skip if nothing surprising happened.

Recent evaluator log entries (last 5, pre-trimmed):
\`\`\`
$EVALUATOR_LOG_TAIL_5
\`\`\`

Apply the TOKEN AND QUESTIONING POLICY from .claude/core.md strictly.

Write your verdict to: $EVAL_OUTPUT

The verdict line MUST appear at the top of $EVAL_OUTPUT and start exactly with:
**Verdict:** GOAL_ACHIEVED
  or **Verdict:** CONTINUE
  or **Verdict:** ESCALATE
  or **Verdict:** REGRESSION
  or **Verdict:** STALLED

Also include a 'Depth Recommendation For Next Iteration:' line: lean or full.

Then update $JOURNEY_HISTORY (full atomic write) and append an entry to $EVALUATOR_LOG.
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
    exit 0
  fi

  if [[ ! -f "$EVAL_OUTPUT" ]]; then
    echo "[run-goal] goal-evaluator did not write $EVAL_OUTPUT — treating as ABORTED." >&2
    write_session_summary "ABORTED" "$CURRENT_ITER"
    exit 1
  fi
  fi  # end .evaluated reuse guard

  # Parse verdict (guarded: a malformed verdict line must surface as an empty
  # VERDICT for the fallthrough handling, not kill the engine via pipefail)
  VERDICT=$(grep -m1 -E '^\*\*Verdict:\*\*' "$EVAL_OUTPUT" | sed -E 's/^\*\*Verdict:\*\*[[:space:]]*//' | awk '{print $1}') || true
  NEXT_DEPTH=$(grep -m1 -E 'Depth Recommendation For Next Iteration:' "$EVAL_OUTPUT" | sed -E 's/.*Iteration:\*?\*?[[:space:]]*//' | awk '{print $1}' | tr '[:upper:]' '[:lower:]') || true
  [[ "$NEXT_DEPTH" != "lean" && "$NEXT_DEPTH" != "full" ]] && NEXT_DEPTH="lean"

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

Apply the TOKEN AND QUESTIONING POLICY from .claude/core.md strictly. Do NOT write product code or start services." || _prop_rc=$?
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
      exit 1
      ;;
    STALLED)
      record_telemetry_event "halt" '{"reason":"STALLED","detected_at_step":"post_evaluator"}'
      write_session_summary "STALLED" "$((CURRENT_ITER+1))"
      echo "[run-goal] STALLED per evaluator. Edit goal.md and resume with --resume." >&2
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
      exit 1
      ;;
    *)
      echo "[run-goal] Unknown verdict '$VERDICT' — treating as CONTINUE." >&2
      CURRENT_ITER=$((CURRENT_ITER+1))
      ;;
  esac
done
