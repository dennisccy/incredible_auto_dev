#!/usr/bin/env bash
# goal-iter-lean.sh — Run a lean goal-mode iteration.
#
# Usage: ./scripts/automation/goal-iter-lean.sh <iter-name>
#   <iter-name> is the synthetic phase name `goal-<sid>-iter-<N>`.
#
# A lean iteration is the stripped-down execution path used when the
# goal-decomposer marks an iteration as `Depth: lean`. It runs:
#   1. developer  (TDD implementation from the iter spec)
#   2. reviewer   (max 2 attempts; second is a fix-mode developer pass + reviewer re-run)
#   3. browser-qa-agent  (runs only the journeys named in the iter spec's "Target journeys")
#
# Skipped (vs full pipeline run-phase.sh): orchestrator, qa test-plan generator,
# ui-impact-analyst, ui-test-designer, qa validator, ux-regression-reviewer,
# auditor, phase-closure-auditor, release-manager.
#
# SPEED-2: with CHAIN_LEAN_PARALLEL_BROWSER_QA=replay (default off), the
# browser-qa service boot + deterministic replay lane is forked right after the
# developer step and joined once the review loop settles; a review-1 FAIL kills
# the fork BEFORE any step invalidation (see the fork block below).
#
# SPEED-3: =full (headless backends ONLY; the interactive backend demotes to
# replay with a warning — killing an engine-side waiter would strand the
# pump's subagent, EXP-4's cancellation gap) forks the WHOLE browser-qa
# section, LLM lane included. The join translates a transport exit (70) from
# inside the fork into the same resumable engine pause the sequential path
# takes, and a review-1 FAIL kills the fork tree (in-flight dispatch included)
# before any invalidation.
#
# The outer run-goal.sh runs the goal-evaluator after this script returns.
#
# All Claude calls go through claude_with_quota_retry → --effort max + auto-resume on quota.
# Telemetry events are recorded via lib/telemetry.sh when GOAL_SESSION_DIR is set.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/telemetry.sh"
# Deterministic regression-replay lane — ONE implementation shared with the
# FULL pipeline's browser-qa step (browser-qa-phase.sh). The tag keeps this
# script's lane log lines byte-identical to their pre-extraction text.
source "$SCRIPT_DIR/lib/replay-lane.sh"
# shellcheck disable=SC2034  # consumed by lib/replay-lane.sh's log helpers
REPLAY_LANE_TAG="goal-iter-lean"

# A transport/dispatch-unavailable exit (70) from the interactive backend means
# the pump/session went away — a transport failure, not an agent-quality failure.
# Pause cleanly and resumably (run-goal.sh turns this 70 into an AWAITING_PUMP
# pause) instead of finishing the iteration with partial work. No-op otherwise.
# (lib/quota-retry.sh defines DISPATCH_UNAVAILABLE_EXIT_CODE; default 70.)
_pause_if_transport() {
  local rc="$1" label="${2:-step}"
  if [[ "$rc" -eq "${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}" ]]; then
    echo "[goal-iter-lean] $label: interactive pump/dispatch unavailable (exit $rc) — pausing." >&2
    echo "[goal-iter-lean] The interactive session/pump went away. Resume with /goal-resume after re-opening it." >&2
    exit "${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}"
  fi
}

ITER_NAME="${1:-}"
if [[ -z "$ITER_NAME" ]]; then
  echo "Usage: $0 <iter-name>" >&2
  echo "  Example: $0 goal-2026-05-04-todo-app-iter-3" >&2
  exit 1
fi
require_claude

SPEC=$(phase_spec_path "$ITER_NAME")
if [[ -z "$SPEC" ]]; then
  echo "Error: No iter spec found for '$ITER_NAME' in docs/phases/" >&2
  echo "  goal-decomposer should have written it. Did the outer loop run?" >&2
  exit 1
fi

GOAL_FILE="$REPO_ROOT/docs/goal.md"
if [[ ! -f "$GOAL_FILE" ]]; then
  echo "Error: docs/goal.md not found." >&2
  exit 1
fi

DEV_HANDOFF="$REPO_ROOT/docs/handoffs/${ITER_NAME}-dev.md"
REVIEW_REPORT="$REPO_ROOT/reports/reviews/${ITER_NAME}-review.md"
UI_TEST_RESULTS="$REPO_ROOT/reports/phase-${ITER_NAME}-ui-test-results.md"

mkdir -p "$REPO_ROOT/runs/${ITER_NAME}"
mkdir -p "$REPO_ROOT/reports/reviews"
mkdir -p "$REPO_ROOT/reports/qa/${ITER_NAME}-evidence"
mkdir -p "$REPO_ROOT/docs/handoffs"

# ── Step checkpoints (lib/checkpoint.sh) ──────────────────────────────────
# A resumed iteration (pump stall / quota / Ctrl-C) skips steps whose marker,
# artifact, and working-tree state all verify — so a stall never redoes the
# expensive developer build. Any doubt → the step re-runs (today's behavior).
ITER_DIR="$(goal_iter_dir "$ITER_NAME" 2>/dev/null || true)"

# ── TOKEN-7: pre-baked review packet ──────────────────────────────────────
# Built once the developer settles — BEFORE the SPEED-2/3 fork spawn points
# (the packet's stat tail reads tracked runs/ paths, and a forked lane
# mid-write must never race the packet; roadmap TOKEN-7 stop-and-ask (2)) —
# and REBUILT after every fix-mode developer pass (after the fork reap +
# invalidation) so a round-2 reviewer never reads a stale packet. A build
# failure degrades LOUDLY to hint-only dispatch (the prompt's packet line
# says "if present") and removes any stale file — absent beats stale.
# Lives under runs/ (checkpoint-tree-hash-excluded), so builds never churn
# a resume-skip decision.
REVIEW_PACKET="${ITER_DIR:-$REPO_ROOT/runs/$ITER_NAME}/review-packet.md"
_build_review_packet_or_degrade() {
  if (cd "$REPO_ROOT" && build_review_packet "$REVIEW_PACKET" HEAD); then
    echo "[goal-iter-lean] review packet built: $REVIEW_PACKET (base HEAD)"
  else
    echo "[goal-iter-lean] review packet build failed — removing any stale packet; the reviewer degrades to the diff-hint commands." >&2
    rm -f "$REVIEW_PACKET" 2>/dev/null || true
  fi
}

_review_parses() { grep -qE '^\*\*Verdict:\*\*[[:space:]]*(PASS_WITH_NOTES|PASS|FAIL)[[:space:]]*$' "$REVIEW_REPORT" 2>/dev/null; }
_review_verdict() { grep -m1 -E '^\*\*Verdict:\*\*' "$REVIEW_REPORT" 2>/dev/null | grep -oE 'PASS_WITH_NOTES|PASS|FAIL' | head -1; }
_step_skipped_event() {
  echo "[goal-iter-lean] Resume: $1 already completed for this iteration (checkpoint verified) — skipping."
  record_telemetry_event "step_skipped" "$(jq -cn --arg s "$1" --arg n "$ITER_NAME" '{step:$s, iter_name:$n, reason:"checkpoint"}' 2>/dev/null || printf '{"step":"%s","iter_name":"%s"}' "$1" "$ITER_NAME")"
}

echo "[goal-iter-lean] Iteration: $ITER_NAME"
record_telemetry_event "iter_dispatch" "$(jq -cn --arg n "$ITER_NAME" --arg d "lean" '{iter_name:$n, depth:$d}' 2>/dev/null || printf '{"iter_name":"%s","depth":"lean"}' "$ITER_NAME")"

ensure_phase_ports

# Per-run tmp isolation: adopt the engine's CHAIN_TMPDIR (run-goal.sh sets it)
# or create our own for standalone invocations. chain_tmp_cleanup is
# owner-guarded, so under run-goal.sh the trap below removes nothing — the
# engine rotates the dir at its iteration boundary instead.
chain_tmp_init "$ITER_NAME"
# Standalone parity with run-phase.sh: janitor + soft disk guard only when this
# invocation owns its dir (under run-goal.sh the engine already ran both).
if [[ "${CHAIN_TMPDIR_OWNER_PID:-}" == "$$" ]]; then
  chain_tmp_janitor
  chain_tmp_disk_guard || true
fi

# ── Cleanup any stray dev server processes on exit ────────────────────────
# Port sweep factored out (same commands, same order) so the SPEED-2 review-FAIL
# reap can reuse it: a finished fork's servers are orphaned to init and survive
# a fork-tree kill, yet the post-fix boot must start servers on the FIXED tree.
_bqa_kill_port_servers() {
  local _be_port="${CHAIN_BACKEND_PORT:-8000}"
  local _fe_port="${CHAIN_FRONTEND_PORT:-3000}"
  pkill -f "uvicorn main:app.*--port ${_be_port}" 2>/dev/null || true
  pkill -f "next dev -p ${_fe_port}" 2>/dev/null || true
  pkill -f "next-server.*:${_fe_port}" 2>/dev/null || true
  fuser -k "${_be_port}/tcp" "${_fe_port}/tcp" 2>/dev/null || true
}

cleanup_iter_servers() {
  _bqa_kill_port_servers
  # Reap a still-running coherence fork so an aborting iteration can't leave an
  # orphaned agent racing a future resume of the same iteration.
  if [[ -n "${_COH_PID:-}" ]]; then
    if declare -F _kill_pid_tree >/dev/null 2>&1; then
      _kill_pid_tree "$_COH_PID" 2>/dev/null || true
    else
      kill "$_COH_PID" 2>/dev/null || true
    fi
  fi
  # SPEED-2: reap a still-running browser-qa replay fork on every exit path so
  # an aborting iteration can't leave an orphan writing lane files into a
  # future resume of the same iteration.
  if [[ -n "${_BQA_PID:-}" ]]; then
    if declare -F _kill_pid_tree >/dev/null 2>&1; then
      _kill_pid_tree "$_BQA_PID" 2>/dev/null || true
    else
      kill "$_BQA_PID" 2>/dev/null || true
    fi
  fi
  # SPEED-3: reap a still-running full-section fork on every exit path (same
  # rationale; the tree kill also takes down an in-flight LLM dispatch child).
  if [[ -n "${_BQA_FULL_PID:-}" ]]; then
    if declare -F _kill_pid_tree >/dev/null 2>&1; then
      _kill_pid_tree "$_BQA_FULL_PID" 2>/dev/null || true
    else
      kill "$_BQA_FULL_PID" 2>/dev/null || true
    fi
  fi
}
trap 'cleanup_iter_servers; chain_tmp_cleanup' EXIT

# ══ SPEED-2: parallel review ∥ browser-qa — stage "replay" ═════════════════
# Reviewer (~21m) and browser-qa (~20m) both need only the post-dev tree. In
# "replay" mode the forkable unit — service boot + the deterministic replay
# lane ONLY (demo_runner.py --mode verify: pure python, cleanly killable on
# both backends, no pump involvement) — runs in a background subshell while
# the review loop runs, and is joined (or reaped) before anything consumes it.
# The unit is ONE function, run_browser_qa_boot_and_replay(): knob=off calls
# it inline at its original position inside run_browser_qa_section() (no
# behavior change); knob=replay forks it right after the developer step.

# Journey sets come from the spec (needed by the fork guard below AND by the
# resume-skip check and the lanes inside the section). First match wins; the
# journey-less-line pipefail guard is load-bearing and lives in
# replay_lane_spec_journeys — see lib/replay-lane.sh (both 20260710/20260712
# benchmark iter-0s died on exactly that parse before the guard existed).
TARGET_JOURNEYS="$(replay_lane_spec_journeys 'Target journeys:' "$SPEC")"
REQUIRED_JOURNEYS="$(replay_lane_spec_journeys 'Required-still-passing' "$SPEC")"
_bq_sig="${TARGET_JOURNEYS}|${REQUIRED_JOURNEYS}"

# Lane path derivations (EVIDENCE_DIR, JOURNEY_SCRIPTS_DIR, REGRESSION_RESULTS,
# LLM_RESULTS, DEMO_RUNNER, MERGE_RESULTS) are replay_lane_paths in
# lib/replay-lane.sh — shared by the forkable unit, the join, and the reap;
# every assignment is a pure derivation and the mkdir is idempotent, so
# recomputing in fork and parent stays safe.

# The forkable unit: service boot + golden partition + deterministic replay
# lane. Body lines moved VERBATIM from run_browser_qa_section (SPEED-1 style:
# un-indented pure move); knob=off runs this in the caller's shell exactly
# where the lines used to sit, so every assignment/export/cd lands globally
# as before. It never dispatches an agent, so exit-70 transport handling
# cannot arise inside it.
run_browser_qa_boot_and_replay() {

QA_BACKEND_LOG=$(_qa_log_path "goal-iter-backend")
QA_FRONTEND_LOG=$(_qa_log_path "goal-iter-frontend")

BACKEND_START_CMD="${CHAIN_START_BACKEND_CMD:-}"
FRONTEND_START_CMD="${CHAIN_START_FRONTEND_CMD:-}"
if [[ -z "$BACKEND_START_CMD" && -f "$REPO_ROOT/scripts/start-backend.sh" ]]; then
  BACKEND_START_CMD="bash $REPO_ROOT/scripts/start-backend.sh"
fi
if [[ -z "$FRONTEND_START_CMD" && -f "$REPO_ROOT/scripts/start-frontend.sh" ]]; then
  FRONTEND_START_CMD="bash $REPO_ROOT/scripts/start-frontend.sh"
fi

_BACKEND_PORT="${CHAIN_BACKEND_PORT:-8000}"
_FRONTEND_PORT="${CHAIN_FRONTEND_PORT:-3000}"
BACKEND_HEALTH_URL="${CHAIN_BACKEND_HEALTH_URL:-http://localhost:${_BACKEND_PORT}/health}"
FRONTEND_URL="${CHAIN_FRONTEND_URL:-http://localhost:${_FRONTEND_PORT}}"

kill_stale_next_dev_server 2>/dev/null || true

QA_STARTED_PIDS=()
export QA_BACKEND_HEALTH_URL="$BACKEND_HEALTH_URL"
export QA_BACKEND_START_CMD="$BACKEND_START_CMD"
export QA_BACKEND_LOG
export QA_FRONTEND_URL="$FRONTEND_URL"
export QA_FRONTEND_START_CMD="$FRONTEND_START_CMD"
export QA_FRONTEND_LOG
export QA_FRONTEND_REQUIRED="yes"

# ── REL-12: single-service frontend short-circuit ───────────────────────────
# Boot the backend first (frontend deferred), then probe $FRONTEND_URL once,
# directly. On a single-service project the frontend is server-rendered by the
# backend (CHAIN_FRONTEND_URL points at it), so the URL answers as soon as the
# backend is up — while booting the generic frontend template could only fail
# twice and skip every journey (proven live: both 20260714 benchmark iter-0
# lanes; experiments.md POSTs bench-20260714-0634/-0830). A probe hit skips
# the frontend boot LOUDLY (never silently): the log line names the URL, so a
# two-service project misconfigured onto its backend URL stays visible rather
# than quietly mistested. A probe miss restores the env and runs the frontend
# boot + readiness gate below exactly as before.
export QA_FRONTEND_REQUIRED="no"
ensure_services_running
_fe_probe_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$FRONTEND_URL" 2>/dev/null || true)"
export QA_FRONTEND_REQUIRED="yes"
if [[ "$_fe_probe_code" =~ ^[23] ]]; then
  FRONTEND_AVAILABLE="yes"
  FRONTEND_SKIP_REASON=""
  # Single service: LLM-lane retries (the quota-retry pre-hook re-runs
  # ensure_services_running) must keep skipping the frontend boot too.
  export QA_FRONTEND_REQUIRED="no"
  echo "[goal-iter-lean] Frontend already answering at $FRONTEND_URL (HTTP $_fe_probe_code) — direct probe enabled the browser lane; skipping the frontend boot (REL-12 single-service short-circuit)."
else
  # Frontend half of the boot. The backend half already ran above and must not
  # re-run its retry ladder here (matters when the backend is DOWN) — blank its
  # inputs for this call and restore its verdict afterwards.
  _relbe_health="${QA_BACKEND_HEALTH_URL:-}"; _relbe_cmd="${QA_BACKEND_START_CMD:-}"
  _relbe_up="${QA_BACKEND_UP:-unknown}";      _relbe_tail="${QA_BACKEND_LOG_TAIL:-}"
  export QA_BACKEND_HEALTH_URL="" QA_BACKEND_START_CMD=""
  ensure_services_running
  export QA_BACKEND_HEALTH_URL="$_relbe_health" QA_BACKEND_START_CMD="$_relbe_cmd"
  export QA_BACKEND_UP="$_relbe_up" QA_BACKEND_LOG_TAIL="$_relbe_tail"

  # Trust the retrying ensure_services_running verdict first (QA_FRONTEND_UP), then
  # a re-probe so a frontend that is merely mid-recompile isn't misread as down —
  # avoids a false SKIP right after a successful-but-still-compiling boot. The gate
  # is corruption-aware: this is the standalone (non-shared) path, so on a persistent
  # corrupt `.next` it heals once (rm -rf .next + restart). Budget is 120s (not 30s)
  # so a guaranteed-cold rebuild — including the QA_FRONTEND_UP=slow case where the
  # boot left a still-compiling server running — has room to finish.
  if [[ "${QA_FRONTEND_UP:-unknown}" == "yes" ]] || _wait_for_frontend_ready "$FRONTEND_URL" "frontend" 120 "goal-iter-lean"; then
    FRONTEND_AVAILABLE="yes"
    FRONTEND_SKIP_REASON=""
  else
    FRONTEND_AVAILABLE="no"
    echo "[goal-iter-lean] Frontend not available — browser tests will be SKIPPED."
    # Surface the real cause (dep hint + log tail) instead of a bare "not running".
    FRONTEND_SKIP_REASON="frontend not running"
    _fe_hint="$(_qa_dep_hint frontend)"
    [[ -n "$_fe_hint" ]] && FRONTEND_SKIP_REASON+=" — likely cause: $_fe_hint"
    _fe_tail="${QA_FRONTEND_LOG_TAIL:-}"
    [[ -z "$_fe_tail" && -n "${QA_FRONTEND_LOG:-}" && -f "${QA_FRONTEND_LOG:-}" ]] && _fe_tail="$(tail -n 15 "$QA_FRONTEND_LOG" 2>/dev/null || true)"
    [[ -n "$_fe_tail" ]] && { echo "[goal-iter-lean] Frontend start log tail (${QA_FRONTEND_LOG:-?}):" >&2; echo "$_fe_tail" >&2; }
  fi
fi

export CHAIN_CLAUDE_PRE_RETRY_HOOK="ensure_services_running"
cd "$REPO_ROOT"

replay_lane_paths "$ITER_NAME"

# Golden partition + lane 1 (deterministic replay) — shared implementation in
# lib/replay-lane.sh: stale-artifact hygiene, lint-quarantine of invalid
# goldens, rc=5 → REPLAY_FAILED re-confirm via the LLM lane, rc=6 → service
# re-check + ONE retry then SKIPPED-INFRA on a second rc-6 (REL-5), any other
# failure → ALL regression journeys fall back to the LLM lane, and the
# CHAIN_REGRESSION_REPLAY=false hatch. Sets R_REPLAY, R_LLM, _use_replay,
# REPLAY_FAILED, REPLAY_SKIPPED_INFRA — the exact globals _bqa_state_save
# ships across the SPEED-2 fork boundary.
replay_lane_partition_and_verify "$ITER_NAME"

}

# Serialize the fork's outward state (atomic tmp+mv, %q-quoted, sentinel-
# terminated) so the join can adopt it wholesale. Plain assignments source as
# globals; the export lines restore the env the LLM lane's quota-retry
# pre-hook (ensure_services_running) needs in the parent shell.
_bqa_state_save() {
  local f="$1" tmp="$1.tmp.$$"
  {
    printf 'FRONTEND_AVAILABLE=%q\n'   "${FRONTEND_AVAILABLE:-}"
    printf 'FRONTEND_SKIP_REASON=%q\n' "${FRONTEND_SKIP_REASON:-}"
    printf 'FRONTEND_URL=%q\n'         "${FRONTEND_URL:-}"
    printf '_use_replay=%q\n'          "${_use_replay:-no}"
    printf 'R_REPLAY=%q\n'             "${R_REPLAY:-}"
    printf 'R_LLM=%q\n'                "${R_LLM:-}"
    printf 'REPLAY_FAILED=%q\n'        "${REPLAY_FAILED:-}"
    printf 'REPLAY_SKIPPED_INFRA=%q\n' "${REPLAY_SKIPPED_INFRA:-}"
    printf 'export QA_BACKEND_HEALTH_URL=%q\n'       "${QA_BACKEND_HEALTH_URL:-}"
    printf 'export QA_BACKEND_START_CMD=%q\n'        "${QA_BACKEND_START_CMD:-}"
    printf 'export QA_BACKEND_LOG=%q\n'              "${QA_BACKEND_LOG:-}"
    printf 'export QA_FRONTEND_URL=%q\n'             "${QA_FRONTEND_URL:-}"
    printf 'export QA_FRONTEND_START_CMD=%q\n'       "${QA_FRONTEND_START_CMD:-}"
    printf 'export QA_FRONTEND_LOG=%q\n'             "${QA_FRONTEND_LOG:-}"
    printf 'export QA_FRONTEND_REQUIRED=%q\n'        "${QA_FRONTEND_REQUIRED:-yes}"
    printf 'export CHAIN_CLAUDE_PRE_RETRY_HOOK=%q\n' "${CHAIN_CLAUDE_PRE_RETRY_HOOK:-}"
    printf '_BQA_STATE_COMPLETE=1\n'
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# Join the forked lane. Returns 0 ONLY when the fork exited 0 and left a
# complete state file — the section then skips the inline unit. Any other
# outcome (no fork this run, crash, incomplete state) cleans up and returns 1
# so the section runs the unit inline (the sequential path IS the fallback).
# Never trusts files from a previous process: _BQA_PID is set only by THIS
# run's fork, so a stale state file on disk is ignored and overwritten.
_bqa_fork_consume() {
  [[ -n "${_BQA_PID:-}" ]] || return 1
  wait "$_BQA_PID" 2>/dev/null || true
  _BQA_PID=""
  local _frc
  _frc="$(cat "$_BQA_RC_FILE" 2>/dev/null || echo 1)"
  if [[ "$_frc" != "0" || ! -s "$_BQA_STATE_FILE" ]]; then
    echo "[goal-iter-lean] Forked replay lane unusable (rc=${_frc:-?}) — running service boot + replay inline." >&2
    rm -f "$_BQA_STATE_FILE" "$_BQA_RC_FILE" 2>/dev/null || true
    return 1
  fi
  _BQA_STATE_COMPLETE=""
  # shellcheck source=/dev/null
  source "$_BQA_STATE_FILE"
  rm -f "$_BQA_STATE_FILE" "$_BQA_RC_FILE" 2>/dev/null || true
  if [[ "${_BQA_STATE_COMPLETE:-}" != "1" ]]; then
    echo "[goal-iter-lean] Forked replay lane left an incomplete state file — running service boot + replay inline." >&2
    return 1
  fi
  replay_lane_paths "$ITER_NAME"
  cd "$REPO_ROOT"
  echo "[goal-iter-lean] Consumed forked replay-lane results (frontend: ${FRONTEND_AVAILABLE:-?}, replay: ${_use_replay:-no}${REPLAY_FAILED:+, re-confirming via LLM: ${REPLAY_FAILED% }}${REPLAY_SKIPPED_INFRA:+, replay lane SKIPPED-INFRA — browser infra failed twice})."
  return 0
}

# Review-1 FAIL path (SPEED-2 CRITICAL ORDERING): the forked lane's results
# were produced against the PRE-fix tree — kill the fork's whole process tree,
# WAIT until it is dead, discard its lane files, and only then may the caller
# run step_invalidate_from. A forked write landing after invalidation is the
# exact stale-artifact race this design guards (roadmap SPEED-2 stop-and-ask).
# The lane files are discarded here explicitly because step_invalidate_from
# only deletes MARKER-registered artifacts, and the fork's outputs are not
# registered until step_mark_done browser-qa at the end of the section.
_bqa_fork_reap() {
  [[ -n "${_BQA_PID:-}" ]] || return 0
  echo "[goal-iter-lean] Reaping the forked replay lane (pid $_BQA_PID) before invalidation..."
  if declare -F _kill_pid_tree >/dev/null 2>&1; then
    _kill_pid_tree "$_BQA_PID" 2>/dev/null || true
  else
    kill "$_BQA_PID" 2>/dev/null || true
  fi
  wait "$_BQA_PID" 2>/dev/null || true
  _BQA_PID=""
  # A finished fork's servers were orphaned to init (they survive the tree
  # kill) and would serve PRE-fix code to the post-fix browser-qa — sweep the
  # ports so the sequential rerun boots on the fixed tree.
  _bqa_kill_port_servers
  replay_lane_paths "$ITER_NAME"
  rm -f "$_BQA_STATE_FILE" "$_BQA_RC_FILE" "${REGRESSION_RESULTS:-}" 2>/dev/null || true
  echo "[goal-iter-lean] Forked replay lane is dead and its lane files are discarded — safe to invalidate."
  return 0
}

# ══ SPEED-3: parallel review ∥ browser-qa — stage "full" (headless only) ═══
# Forkable unit = the WHOLE run_browser_qa_section (service boot + replay lane
# + LLM lane + merge). Two contracts differ from the replay stage:
#   • Checkpointing stays in the PARENT: the fork writes NO step markers — the
#     review loop's own step_invalidate_from calls cascade through browser-qa,
#     so a marker written concurrently from the fork could be wiped mid-write
#     or trusted when it should not be. The spawn site invalidates browser-qa
#     BEFORE forking (deterministic ordering vs the review loop), and the join
#     validates the results file and writes the marker itself.
#   • A transport pause crosses the process boundary as an EXIT STATUS:
#     _pause_if_transport exits the SUBSHELL from inside run_browser_qa_llm
#     (rc 70) BEFORE the fork can write its rc file, so the join reads `wait`'s
#     status and re-raises the pause in the parent — the engine pauses
#     resumably exactly as if the dispatch had run inline (mirror of the
#     coherence join's rc-70 branch below).

# Join the full-section fork. Returns 0 ONLY when the fork ran the section to
# completion (rc file present and 0) — the caller then skips the inline
# section; the checkpoint mark (the one thing the fork deferred) happens here.
# A transport 70 pauses the engine. Any other outcome cleans up and returns 1
# so the caller runs the section inline (the sequential path IS the fallback).
_bqa_full_fork_consume() {
  [[ -n "${_BQA_FULL_PID:-}" ]] || return 1
  local _frc=0
  wait "$_BQA_FULL_PID" 2>/dev/null || _frc=$?
  _BQA_FULL_PID=""
  local _file_rc
  _file_rc="$(cat "$_BQA_FULL_RC_FILE" 2>/dev/null || echo "")"
  rm -f "$_BQA_FULL_RC_FILE" "$_BQA_FULL_PID_FILE" 2>/dev/null || true
  if [[ "$_frc" -eq "${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}" || "$_file_rc" == "${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}" ]]; then
    # Today only wait's status can carry the 70 (the in-fork exit skips the
    # rc-file write); the file check is belt-and-braces against a refactor.
    # browser-qa was invalidated before the fork, so the resume re-runs the
    # whole section and nothing certifies the fork's partial artifacts.
    _pause_if_transport "${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}" "browser-qa-agent (parallel full)"
  fi
  if [[ "$_file_rc" != "0" ]]; then
    echo "[goal-iter-lean] Forked full browser-qa section unusable (wait rc=$_frc, section rc=${_file_rc:-none}) — running the section inline." >&2
    return 1
  fi
  replay_lane_paths "$ITER_NAME"
  cd "$REPO_ROOT"
  # Checkpoint mark — verbatim the section's own tail, which the fork skipped.
  _bq_verdict="$(grep -m1 -E '^\*\*Browser QA Verdict:\*\*' "$UI_TEST_RESULTS" 2>/dev/null | grep -oE 'PASS|FAIL|SKIPPED' | head -1)"
  if [[ "$_bq_verdict" == "PASS" || "$_bq_verdict" == "FAIL" ]]; then
    step_mark_done browser-qa --dir "$ITER_DIR" --verdict "$_bq_verdict" --journeys "$_bq_sig" "$UI_TEST_RESULTS"
  fi
  echo "[goal-iter-lean] Consumed forked full browser-qa results (verdict: ${_bq_verdict:-none})."
  return 0
}

# Review-1 FAIL path for the full stage (same CRITICAL ORDERING as
# _bqa_fork_reap, bigger blast radius): the fork may hold an IN-FLIGHT LLM
# dispatch — kill the whole tree (dispatch child included), wait until dead,
# sweep the orphaned-to-init servers, and discard every lane file the section
# could have produced against the pre-fix tree (replay results, LLM results,
# and the MERGED results file; none is marker-registered yet). Also emits the
# SPEED-3 tripwire cost event: each review-FAIL iteration in full mode wastes
# one full browser-qa dispatch — the 2-of-3 tripwire spares exactly this cost.
_bqa_full_fork_reap() {
  [[ -n "${_BQA_FULL_PID:-}" ]] || return 0
  echo "[goal-iter-lean] Reaping the forked full browser-qa section (pid $_BQA_FULL_PID) before invalidation..."
  if declare -F _kill_pid_tree >/dev/null 2>&1; then
    _kill_pid_tree "$_BQA_FULL_PID" 2>/dev/null || true
  else
    kill "$_BQA_FULL_PID" 2>/dev/null || true
  fi
  wait "$_BQA_FULL_PID" 2>/dev/null || true
  _BQA_FULL_PID=""
  _bqa_kill_port_servers
  replay_lane_paths "$ITER_NAME"
  rm -f "$_BQA_FULL_RC_FILE" "$_BQA_FULL_PID_FILE" \
        "${REGRESSION_RESULTS:-}" "${LLM_RESULTS:-}" "${UI_TEST_RESULTS:-}" 2>/dev/null || true
  record_telemetry_event "parallel_bqa_wasted_dispatch" "$(jq -cn --arg n "$ITER_NAME" \
      '{mode:"full", iter_name:$n,
        wasted:"one full browser-qa dispatch (LLM lane included) ran against the pre-fix tree and was discarded on the attempt-1 review FAIL",
        note:"the 2-of-3 attempt-1-FAIL tripwire also spares this cost by disabling the fork for the rest of the session"}' 2>/dev/null \
    || printf '{"mode":"full","iter_name":"%s","wasted":"one full browser-qa dispatch"}' "$ITER_NAME")"
  echo "[goal-iter-lean] Forked full browser-qa section is dead and its lane files are discarded — safe to invalidate."
  return 0
}

# Read-only mirror of the resume-skip check ahead of run_browser_qa_section
# (keep the two in sync; this one must not emit the step_skipped telemetry).
# When the browser-qa checkpoint will be reused, a fork would boot services
# and replay journeys for nothing on a resumed iteration.
_bqa_checkpoint_reusable() {
  step_done_valid browser-qa --verify-tree --dir "$ITER_DIR" "$UI_TEST_RESULTS" || return 1
  [[ "$(step_field browser-qa journeys "$ITER_DIR")" == "$_bq_sig" ]] || return 1
  local _v
  _v="$(grep -m1 -E '^\*\*Browser QA Verdict:\*\*' "$UI_TEST_RESULTS" 2>/dev/null | grep -oE 'PASS|FAIL|SKIPPED' | head -1 || true)"
  [[ "$_v" == "PASS" || "$_v" == "FAIL" ]]
}

# SPEED-2 tripwire: if >=2 of the last 3 iterations logged an attempt-1 review
# FAIL, the fork is a bad bet (every review FAIL wastes a forked boot+replay)
# — skip it for the REST OF THE SESSION. The decision is persisted as a state
# file because this script runs once per iteration (env cannot carry it).
# Returns 0 = fork must be skipped (tripped now, or previously persisted),
# 1 = clear, 2 = cannot evaluate (no jq — callers skip the fork: an
# experiment whose tripwire cannot fire must not run). Reads only jq-written
# telemetry (the no-jq writer wraps payloads as strings, invisible here —
# consistent, since without jq this reader never runs either).
_bqa_tripwire_active() {
  local _sess="${GOAL_SESSION_DIR:-}"
  [[ -z "$_sess" && -n "${ITER_DIR:-}" ]] && _sess="$(dirname "$ITER_DIR")"
  [[ -n "$_sess" ]] || return 1
  local _state="$_sess/state/parallel-bqa-disabled"
  if [[ -f "$_state" ]]; then
    echo "[goal-iter-lean] SPEED-2 tripwire state present ($_state) — parallel browser-qa fork disabled for this session."
    return 0
  fi
  command -v jq >/dev/null 2>&1 || return 2
  local _tj="$_sess/telemetry.jsonl"
  [[ -s "$_tj" ]] || return 1
  local _fails
  _fails="$(jq -s '
      [ .[] | select(.event? == "review_verdict" and .attempt? == 1) ]
      | reduce .[] as $e ([]; map(select(.iter_name != $e.iter_name))
                             + [{iter_name: ($e.iter_name // "unknown"), verdict: $e.verdict}])
      | .[-3:] | map(select(.verdict == "FAIL")) | length
    ' "$_tj" 2>/dev/null || true)"
  [[ "$_fails" =~ ^[0-9]+$ ]] || return 1
  [[ "$_fails" -ge 2 ]] || return 1
  mkdir -p "$_sess/state" 2>/dev/null || true
  { jq -cn --arg reason "attempt-1 review FAIL in >=2 of the last 3 iterations" \
       --arg tripped_by "${ITER_NAME:-}" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '{reason:$reason, tripped_by:$tripped_by, ts:$ts}' 2>/dev/null \
    || echo '{"reason":"attempt-1 review FAIL in >=2 of the last 3 iterations"}'; } > "$_state"
  echo "[goal-iter-lean] SPEED-2 tripwire TRIPPED: attempt-1 review FAIL in $_fails of the last 3 iterations — parallel browser-qa fork disabled for the rest of the session ($_state)."
  return 0
}

# Knob: CHAIN_LEAN_PARALLEL_BROWSER_QA=off|replay|full, default off (G4).
# "full" (SPEED-3: fork the whole section, LLM lane included) is HEADLESS-ONLY:
# on the interactive backend, killing the engine-side waiter would strand the
# pump's subagent against a request nobody reads (stale req/res files are only
# cleaned at engine start) — that cancellation gap is EXP-4's, so interactive
# demotes full → replay with a logged warning. Unrecognized values fall to off.
_BQA_REQUESTED="${CHAIN_LEAN_PARALLEL_BROWSER_QA:-off}"
_BQA_MODE="off"
_BQA_OFF_REASON=""
case "$_BQA_REQUESTED" in
  replay) _BQA_MODE="replay" ;;
  full)
    if [[ "${CHAIN_AGENT_BACKEND:-}" == "interactive" ]]; then
      echo "[goal-iter-lean] CHAIN_LEAN_PARALLEL_BROWSER_QA=full is headless-only (an interactive fork kill would strand the pump's subagent — EXP-4); using replay." >&2
      _BQA_MODE="replay"
      _BQA_OFF_REASON="interactive-backend"
    else
      _BQA_MODE="full"
    fi ;;
  off|"") _BQA_MODE="off" ;;
  *)
    echo "[goal-iter-lean] CHAIN_LEAN_PARALLEL_BROWSER_QA='$_BQA_REQUESTED' is not off|replay|full — using off." >&2
    _BQA_MODE="off" ;;
esac
if [[ "$_BQA_MODE" == "replay" || "$_BQA_MODE" == "full" ]]; then
  _tw_rc=0
  _bqa_tripwire_active || _tw_rc=$?
  if [[ "$_tw_rc" -eq 0 ]]; then
    _BQA_MODE="off"; _BQA_OFF_REASON="tripwire"
  elif [[ "$_tw_rc" -eq 2 ]]; then
    echo "[goal-iter-lean] jq unavailable — the SPEED-2 tripwire cannot be evaluated, so the parallel browser-qa fork stays off." >&2
    _BQA_MODE="off"; _BQA_OFF_REASON="no-jq"
  fi
fi
# Name the knob state every iteration (mirrors run-goal.sh's iter_config event).
record_telemetry_event "iter_config" "$(jq -cn --arg k "CHAIN_LEAN_PARALLEL_BROWSER_QA" --arg v "$_BQA_MODE" --arg req "$_BQA_REQUESTED" --arg r "$_BQA_OFF_REASON" '{key:$k, value:$v, requested:$req, reason:$r}' 2>/dev/null || printf '{"key":"CHAIN_LEAN_PARALLEL_BROWSER_QA","value":"%s"}' "$_BQA_MODE")"

# The browser-qa section as ONE function — extracted verbatim for SPEED-1.
# SPEED-2 carved its first half (service boot + golden partition + replay
# lane) into run_browser_qa_boot_and_replay above so replay mode can fork it;
# SPEED-3 forks this WHOLE section (LLM lane included, headless only) — the
# definition was moved verbatim above the developer step so the full-fork
# subshell (spawned right after developer settles) can see it.
# On the sequential path it is called from the caller's shell, NOT a subshell:
# every assignment and `cd` inside lands globally, exactly as the previous
# inline block behaved. The full fork instead runs it inside its subshell,
# whose exit status carries any in-body transport exit (70) to the join.
# Body kept un-indented from its pre-extraction guarded-block days (pure move).
run_browser_qa_section() {

# ── Browser QA: two lanes (goal-mode lean) ────────────────────────────────
# Late iterations accumulate many already-passing journeys; re-driving each one
# with an LLM through a real browser is what makes late iterations take hours.
# So we split the work:
#   • LLM browser-qa-agent → only the NEW/changed (Target) journeys (judgment
#     needed), plus any regression journey that has no golden script yet.
#   • deterministic replay → already-passing journeys WITH a stored golden script
#     (runs/goal-session-<sid>/journey-scripts/<J-XX>.json), via
#     demo_runner.py --mode verify (no model in the loop → minutes, not hours).
# A replay FAIL is re-confirmed by the LLM (a brittle selector must not fake a
# regression and halt the session). With NO golden scripts on file the regression
# set falls entirely to the LLM lane — behaviour is then identical to before, and
# the speedup switches on by itself as golden scripts accumulate. Disable with
# CHAIN_REGRESSION_REPLAY=false.
#
# SPEED-2 join: when the boot+replay unit was forked after the developer step
# and completed cleanly, consume its results (state file) instead of re-running
# the lane; otherwise run the same unit inline — the sequential path, which is
# also the automatic fallback when the fork crashed or was reaped.
if ! _bqa_fork_consume; then
  run_browser_qa_boot_and_replay
fi

# (Journey IDs were pulled from the spec at the SPEED-2 block, before the
# resume-skip check; lane paths were set by replay_lane_paths.)

# Dispatch the LLM browser-qa-agent on an explicit journey list, writing to $2.
run_browser_qa_llm() {
  local _journeys="$1" _out="$2" _exclude="$3"
  cd "$REPO_ROOT"
  record_agent_invocation_start "browser-qa-agent"   # bare call: $(...) would lose the CHAIN_CURRENT_AGENT export to a subshell
  local _bqa_start=$CHAIN_AGENT_START_EPOCH
  local _rc=0
  claude_with_quota_retry -p "You are the browser-qa-agent for goal-mode lean iteration.

Iteration: $ITER_NAME
Iter spec: $SPEC
Project goal: $GOAL_FILE  <-- read \"Must-have user journeys\" section for journey definitions
Agent instructions: .claude/agents/browser-qa-agent.md  <-- read this first
(CLAUDE.md is already in your system prompt — do not Read it again.)
Skill: .claude/skills/browser-workflow-executor.md  <-- read for Chrome MCP technique

GOAL-MODE LEAN MODE — test EXACTLY these journeys this run: ${_journeys:-(none)}
$( [[ -n "${_exclude// /}" ]] && echo "Do NOT test these — a deterministic replay verifies them separately: $_exclude" )
  1. For each journey ID above, read its numbered steps + Acceptance line from the project goal's \"Must-have user journeys\" section.
  2. Execute the steps with Chrome MCP; use the journey ID as the test case ID (e.g. UT-J-01).

Frontend URL: $FRONTEND_URL
Frontend available: $FRONTEND_AVAILABLE

$(if [[ "$FRONTEND_AVAILABLE" == "yes" ]]; then
  echo "Chrome MCP browser checks ARE required. Use mcp__plugin_superpowers-chrome_chrome__use_browser."
else
  echo "Frontend is NOT available. Mark all tests as SKIPPED with reason: ${FRONTEND_SKIP_REASON:-frontend not running}."
  echo "Do NOT attempt to run browser tests."
fi)

For each journey:
  - Execute the numbered steps exactly as written in goal.md
  - Verify the Acceptance condition
  - Take a screenshot of the end state, save to reports/qa/${ITER_NAME}-evidence/
  - Record PASS / FAIL / SKIP with a short failure description if FAIL

GOLDEN REPLAY SCRIPTS (goal-mode regression speedup): for every journey you verify
PASS, ALSO write a self-contained deterministic replay script to
$JOURNEY_SCRIPTS_DIR/<J-XX>.json (overwrite if present) so future iterations can
re-verify it without a browser-driving model. Follow the 'Golden replay script'
section of your agent instructions for the exact JSON shape. Best-effort: if you
cannot produce one for a journey, skip it (that journey just falls back to the LLM
next time).

Write your results to: $_out
Use template: templates/ui-test-results.md
Map each journey ID to a UT row.

The report MUST contain a line at the top:
**Browser QA Verdict:** PASS
  or
**Browser QA Verdict:** FAIL
  or
**Browser QA Verdict:** SKIPPED

Then STOP." || _rc=$?
  record_agent_invocation_end "browser-qa-agent" "$_bqa_start" "$_rc"
  _pause_if_transport "$_rc" "browser-qa-agent"   # exits the script on a transport (70) failure
  return $_rc
}

# (Golden partition + lane 1 — the deterministic replay — live inside
# run_browser_qa_boot_and_replay above: they already ran, inline or forked.)

# Lane 2 — LLM browser-qa-agent.
if [[ "$_use_replay" == "yes" ]]; then
  _llm_set="$TARGET_JOURNEYS $R_LLM $REPLAY_FAILED"   # targets + no-golden regression + replay re-confirms
  _llm_out="$LLM_RESULTS"
else
  _llm_set="$TARGET_JOURNEYS $REQUIRED_JOURNEYS"       # replay off → LLM covers everything (prior behaviour)
  _llm_out="$UI_TEST_RESULTS"
fi
LLM_JOURNEYS="$(echo "$_llm_set" | tr ' ' '\n' | grep -E '^J-[0-9]+$' | sort -u | tr '\n' ' ' || true)"   # same pipefail guard as replay_lane_spec_journeys: an all-replay iteration has an empty LLM set
_llm_csv="$(echo "$LLM_JOURNEYS" | tr ' ' ',' | sed 's/^,*//;s/,*$//')"

_bqa_rc=0
_bqa_dispatched="no"
if [[ -n "$_llm_csv" || "$_use_replay" != "yes" ]]; then
  _bqa_dispatched="yes"
  run_browser_qa_llm "$_llm_csv" "$_llm_out" "$R_REPLAY" || _bqa_rc=$?
fi

# REL-11 missing-evidence tripwire: the browser-qa dispatch returned but left
# no results file (a quota pause, rc 75, is excluded — the engine handles it
# loudly; a transport failure, rc 70, never reaches here because
# _pause_if_transport exits inside run_browser_qa_llm). The SKIPPED-stub block
# below keeps the evaluator fed; this adds the loud banner + telemetry so a
# silently voided lane can never again read as a quiet SKIP. Note the check is
# on the LLM lane's own output ($_llm_out), not the merged file — with the
# replay lane active a merge fallback can leave a results file even though the
# dispatch itself produced nothing.
if [[ "$_bqa_dispatched" == "yes" && ! -f "$_llm_out" \
      && "$_bqa_rc" -ne "${QUOTA_EXHAUSTED_EXIT_CODE:-75}" ]]; then
  warn_missing_evidence "browser-qa-agent" "$_llm_out"
fi

# Merge replay + LLM into the single results file the goal-evaluator reads
# (LLM listed last → wins on any journey both lanes touched, e.g. a re-confirm).
# Shared implementation in lib/replay-lane.sh — includes the reconciliation
# footer on the raw replay artifact when the LLM lane overturned a replay FAIL,
# so no stale FAIL survives the iteration on disk.
if [[ "$_use_replay" == "yes" ]]; then
  replay_lane_merge_results "$UI_TEST_RESULTS" "$_llm_out"
fi

# If no results artifact exists at all (and it was not a quota pause), leave a
# SKIPPED stub so the evaluator always has something to read.
if [[ ! -f "$UI_TEST_RESULTS" && "$_bqa_rc" -ne "${QUOTA_EXHAUSTED_EXIT_CODE:-75}" ]]; then
  echo "[goal-iter-lean] Browser-qa produced no results file (rc=$_bqa_rc) — writing SKIPPED stub." >&2
  write_failed_artifact_stub "$ITER_NAME" "ui-test-results" \
    "goal-iter-lean.sh browser-qa produced no results file (exit $_bqa_rc). The evaluator will likely emit ESCALATE for the next iteration."
fi

# Golden coverage (loud, non-gating; shared implementation in
# lib/replay-lane.sh): every PASSing journey should now have a lintable golden
# so the replay lane keeps growing (browser-qa LLM time decays iteration over
# iteration) — gaps simply return to the LLM lane next iteration.
replay_lane_golden_coverage "$UI_TEST_RESULTS" "$ITER_NAME"

# Checkpoint: reusable on resume only with a real PASS/FAIL verdict (never a
# SKIPPED stub) and the journey signature this run actually covered.
# SPEED-3: inside the full fork the mark is DEFERRED to the join
# (_bqa_full_fork_consume) — a marker written from the fork could race the
# review loop's invalidation cascade in the parent shell.
_bq_verdict="$(grep -m1 -E '^\*\*Browser QA Verdict:\*\*' "$UI_TEST_RESULTS" 2>/dev/null | grep -oE 'PASS|FAIL|SKIPPED' | head -1)"
if [[ ( "$_bq_verdict" == "PASS" || "$_bq_verdict" == "FAIL" ) && -z "${_BQA_IN_FULL_FORK:-}" ]]; then
  step_mark_done browser-qa --dir "$ITER_DIR" --verdict "$_bq_verdict" --journeys "$_bq_sig" "$UI_TEST_RESULTS"
fi

}

# ── Step 1: Developer ─────────────────────────────────────────────────────
run_developer() {
  local mode_label="$1"
  local fix_context="$2"
  cd "$REPO_ROOT"
  local _start
  record_agent_invocation_start "developer"   # bare call: $(...) would lose the CHAIN_CURRENT_AGENT export to a subshell
  _start=$CHAIN_AGENT_START_EPOCH
  local _rc=0
  claude_with_quota_retry -p "You are the developer agent for goal-mode lean iteration.

Iteration: $ITER_NAME
Iter spec: $SPEC
Project goal: $GOAL_FILE  <-- read Must-have user journeys and Anti-goals
Project template: .claude/project-template.md
Agent instructions: .claude/agents/developer.md  <-- read this first
(CLAUDE.md is already in your system prompt — do not Read it again.)

Mode: $mode_label
$fix_context

This is a LEAN goal-mode iteration. Implement only what the iter spec's IN SCOPE
section calls for. Tighter scope than a full phase. Do NOT introduce features
outside the iter spec's IN SCOPE list.

When complete:
- Write dev handoff to: $DEV_HANDOFF
- Update runs/${ITER_NAME}/status.json with current_step: dev_complete
" || _rc=$?
  record_agent_invocation_end "developer" "$_start" "$_rc"
  return $_rc
}

# ── Step 2: Reviewer ──────────────────────────────────────────────────────
run_reviewer() {
  cd "$REPO_ROOT"
  local _start
  record_agent_invocation_start "reviewer"   # bare call: $(...) would lose the CHAIN_CURRENT_AGENT export to a subshell
  _start=$CHAIN_AGENT_START_EPOCH
  local _rc=0
  claude_with_quota_retry -p "You are the reviewer agent for goal-mode lean iteration.

Iteration: $ITER_NAME
Iter spec: $SPEC
Dev handoff: $DEV_HANDOFF
Project template (relevant sections, pre-sliced):
\`\`\`\`
$(project_template_slice reviewer)
\`\`\`\`
Agent instructions: .claude/agents/reviewer.md  <-- read this first
(CLAUDE.md is already in your system prompt — do not Read it again.)

Bounded diff packet (read FIRST if present): $REVIEW_PACKET — hunks capped, noise excluded, truncations NAMED. The iter spec + dev handoff remain required reading — never verdict from the diff alone (D7).
Run these only for files the packet marks truncated or excluded (or if the packet file is absent):
$(review_diff_hint HEAD)

Apply the TOKEN AND QUESTIONING POLICY from .claude/core.md strictly.

Write your review report to: $REVIEW_REPORT

The report MUST start with a line matching exactly:
**Verdict:** PASS
  or
**Verdict:** PASS_WITH_NOTES
  or
**Verdict:** FAIL
" || _rc=$?
  record_agent_invocation_end "reviewer" "$_start" "$_rc"
  return $_rc
}

# Round 1: build. A transport failure (70) pauses cleanly; any other non-zero
# aborts the iteration as before (set -e semantics, now with the code preserved).
# Resume-skip: handoff on disk + the tree exactly where this iteration last
# left it → the ~41-min build is already done, don't redo it.
if step_done_valid developer --verify-tree --dir "$ITER_DIR" "$DEV_HANDOFF"; then
  _step_skipped_event "developer"
else
  step_invalidate_from developer "$ITER_DIR"
  _dev_rc=0
  run_developer "INITIAL BUILD" "" || _dev_rc=$?
  _pause_if_transport "$_dev_rc" "developer (initial build)"
  if [[ "$_dev_rc" -ne 0 ]]; then exit "$_dev_rc"; fi
  [[ -s "$DEV_HANDOFF" ]] && step_mark_done developer --dir "$ITER_DIR" "$DEV_HANDOFF"
fi

# TOKEN-7 build 1: the round-1 review packet. Ordering is load-bearing — this
# sits BEFORE both fork spawn points below (same stale-write discipline as the
# forks' own kill-then-invalidate rule).
_build_review_packet_or_degrade

# ── SPEED-2 fork: service boot + deterministic replay ∥ review ────────────
# Forked HERE — right after the developer step settles — because review and
# browser-qa both need only the post-dev tree. Isolation copies the coherence
# fork: subshell (contains CHAIN_CURRENT_AGENT + env), own rc-file, plus a PID
# file as a cross-process orphan guard. All fork writes land under runs/ +
# reports/, which are excluded from the checkpoint tree hash (checkpoint.sh),
# so the fork can never churn a resume-skip decision. Joined by
# _bqa_fork_consume once the review loop settles; reaped by _bqa_fork_reap on
# a review-1 FAIL and by cleanup_iter_servers on every exit path.
_BQA_PID=""
_BQA_STATE_FILE="${ITER_DIR:+$ITER_DIR/.bqa-replay-state}"
_BQA_RC_FILE="${ITER_DIR:+$ITER_DIR/.bqa-replay-rc}"
_BQA_PID_FILE="${ITER_DIR:+$ITER_DIR/.bqa-replay-pid}"
if [[ "$_BQA_MODE" == "replay" && -n "$ITER_DIR" ]] && ! _bqa_checkpoint_reusable; then
  # Orphan guard: a hard-killed previous attempt (kill -9 skips the EXIT trap)
  # can leave its fork alive and still writing this iteration's lane files.
  # Reap it before forking again — but only a pid whose command line still
  # looks like ours (PIDs recycle; never tree-kill a stranger).
  _stale_pid="$(cat "$_BQA_PID_FILE" 2>/dev/null || true)"
  if [[ -n "$_stale_pid" ]] && kill -0 "$_stale_pid" 2>/dev/null \
     && ps -o args= -p "$_stale_pid" 2>/dev/null | grep -qE 'goal-iter-lean|demo_runner'; then
    echo "[goal-iter-lean] Reaping an orphaned replay fork from a previous attempt (pid $_stale_pid)..." >&2
    _kill_pid_tree "$_stale_pid" 2>/dev/null || true
  fi
  rm -f "$_BQA_STATE_FILE" "$_BQA_RC_FILE" "$_BQA_PID_FILE" 2>/dev/null || true
  echo "[goal-iter-lean] Forking browser-qa service boot + replay lane to run concurrently with review (CHAIN_LEAN_PARALLEL_BROWSER_QA=$_BQA_REQUESTED)..."
  (
    _rc=0
    record_agent_invocation_start "browser-qa-replay"   # subshell-contained: isolates CHAIN_CURRENT_AGENT so fork telemetry attributes to this name
    _bqa_start=$CHAIN_AGENT_START_EPOCH
    run_browser_qa_boot_and_replay || _rc=$?
    _bqa_state_save "$_BQA_STATE_FILE" || _rc=$?
    record_agent_invocation_end "browser-qa-replay" "$_bqa_start" "$_rc"
    echo "$_rc" > "$_BQA_RC_FILE"
  ) &
  _BQA_PID=$!
  echo "$_BQA_PID" > "$_BQA_PID_FILE"
fi

# ── SPEED-3 fork: the WHOLE browser-qa section ∥ review (headless only) ───
# Same spawn point and isolation as the replay fork (the subshell contains the
# LLM dispatch's CHAIN_CURRENT_AGENT export; own rc/pid files; the pid file
# doubles as the recycled-PID-safe orphan guard). browser-qa is invalidated
# HERE, before the fork exists: the JOIN (not the fork) writes the browser-qa
# marker — see the _bqa_full_fork_consume contract — so ordering vs the review
# loop's own invalidation cascades stays deterministic and a killed or paused
# fork can never leave a marker a resume would trust. The fork writes its rc
# file only on clean completion; an in-body transport exit (70) surfaces as
# the subshell's exit status, which the join reads via `wait`.
_BQA_FULL_PID=""
_BQA_FULL_RC_FILE="${ITER_DIR:+$ITER_DIR/.bqa-full-rc}"
_BQA_FULL_PID_FILE="${ITER_DIR:+$ITER_DIR/.bqa-full-pid}"
if [[ "$_BQA_MODE" == "full" && -n "$ITER_DIR" ]] && ! _bqa_checkpoint_reusable; then
  # Orphan guard: reap a previous attempt's still-alive fork before forking
  # again — but only a pid whose command line still looks like ours (PIDs
  # recycle; never tree-kill a stranger).
  _stale_pid="$(cat "$_BQA_FULL_PID_FILE" 2>/dev/null || true)"
  if [[ -n "$_stale_pid" ]] && kill -0 "$_stale_pid" 2>/dev/null \
     && ps -o args= -p "$_stale_pid" 2>/dev/null | grep -qE 'goal-iter-lean|demo_runner'; then
    echo "[goal-iter-lean] Reaping an orphaned full browser-qa fork from a previous attempt (pid $_stale_pid)..." >&2
    _kill_pid_tree "$_stale_pid" 2>/dev/null || true
  fi
  rm -f "$_BQA_FULL_RC_FILE" "$_BQA_FULL_PID_FILE" 2>/dev/null || true
  step_invalidate_from browser-qa "$ITER_DIR"
  echo "[goal-iter-lean] Forking the FULL browser-qa section (LLM lane included) to run concurrently with review (CHAIN_LEAN_PARALLEL_BROWSER_QA=$_BQA_REQUESTED)..."
  (
    _rc=0
    _BQA_IN_FULL_FORK=1
    run_browser_qa_section || _rc=$?
    echo "$_rc" > "$_BQA_FULL_RC_FILE"
  ) &
  _BQA_FULL_PID=$!
  echo "$_BQA_FULL_PID" > "$_BQA_FULL_PID_FILE"
fi

# Round 1: review. A transport failure pauses; any other review failure is
# tolerated (the retry below / evaluator handles it), as the prior `|| true` did.
# Resume-skip: the marker alone is never trusted — the report must live-parse
# to a verdict (a FAIL report still routes into the fix branch below, exactly
# as a freshly written FAIL would).
if { step_done_valid review-1 --dir "$ITER_DIR" "$REVIEW_REPORT" \
     || step_done_valid review-2 --dir "$ITER_DIR" "$REVIEW_REPORT"; } && _review_parses; then
  _step_skipped_event "reviewer"
else
  step_invalidate_from review-1 "$ITER_DIR"
  _rev_rc=0
  run_reviewer || _rev_rc=$?
  _pause_if_transport "$_rev_rc" "reviewer"
  if _review_parses; then
    record_telemetry_event "review_verdict" "$(jq -cn --arg v "$(_review_verdict)" --argjson a 1 --arg n "$ITER_NAME" '{verdict:$v, attempt:$a, iter_name:$n}' 2>/dev/null || printf '{"verdict":"%s","attempt":1}' "$(_review_verdict)")"
  fi
  if [[ "$_rev_rc" -eq 0 ]] && _review_parses; then
    step_mark_done review-1 --dir "$ITER_DIR" --verdict "$(_review_verdict)" "$REVIEW_REPORT"
  fi
fi

# Retry once if reviewer FAILed
if [[ -f "$REVIEW_REPORT" ]] && ! verdict_passes "$REVIEW_REPORT"; then
  echo "[goal-iter-lean] Review FAIL — running developer in fix mode (1 retry allowed)..."
  # SPEED-2/SPEED-3 CRITICAL ORDERING: kill+wait whichever fork is running and
  # discard its lane files BEFORE any step_invalidate_from below — post-fix
  # browser-qa then runs fully sequentially (the join finds no fork and runs
  # the section/unit inline). The two reaps are mutually exclusive by mode and
  # each no-ops when its fork was never started.
  _bqa_fork_reap
  _bqa_full_fork_reap
  if step_done_valid developer-fix --verify-tree --dir "$ITER_DIR" "$DEV_HANDOFF"; then
    _step_skipped_event "developer-fix"
  else
    step_invalidate_from developer-fix "$ITER_DIR"
    _dev_rc=0
    escalate_model_on   # fix-mode retry runs on the strong tier (escalation ladder)
    run_developer "FIX MODE (review failed)" "
The review report below contains FAIL issues that must be fixed.
Do NOT rebuild from scratch -- fix only what is listed.

Review report path: $REVIEW_REPORT
" || _dev_rc=$?
    escalate_model_off
    _pause_if_transport "$_dev_rc" "developer (fix-mode)"
    if [[ "$_dev_rc" -ne 0 ]]; then exit "$_dev_rc"; fi
    [[ -s "$DEV_HANDOFF" ]] && step_mark_done developer-fix --dir "$ITER_DIR" "$DEV_HANDOFF"
  fi
  # TOKEN-7 rebuild: the fix-mode developer changed the tree (whichever fork
  # was running is already reaped and its lane files discarded, above) — a
  # round-2 reviewer must never read the stale round-1 packet. Runs on the
  # resume-skip path too: a resumed fix invalidates a crashed attempt's packet.
  _build_review_packet_or_degrade
  if step_done_valid review-2 --dir "$ITER_DIR" "$REVIEW_REPORT" && _review_parses; then
    _step_skipped_event "reviewer (fix-mode)"
  else
    step_invalidate_from review-2 "$ITER_DIR"
    _rev_rc=0
    run_reviewer || _rev_rc=$?
    _pause_if_transport "$_rev_rc" "reviewer (fix-mode)"
    if _review_parses; then
      record_telemetry_event "review_verdict" "$(jq -cn --arg v "$(_review_verdict)" --argjson a 2 --arg n "$ITER_NAME" '{verdict:$v, attempt:$a, iter_name:$n}' 2>/dev/null || printf '{"verdict":"%s","attempt":2}' "$(_review_verdict)")"
    fi
    if [[ "$_rev_rc" -eq 0 ]] && _review_parses; then
      step_mark_done review-2 --dir "$ITER_DIR" --verdict "$(_review_verdict)" "$REVIEW_REPORT"
    fi
  fi
fi

if [[ -f "$REVIEW_REPORT" ]] && ! verdict_passes "$REVIEW_REPORT"; then
  echo "[goal-iter-lean] Review still FAIL after retry — proceeding to browser-qa anyway."
  echo "[goal-iter-lean] The goal-evaluator will likely emit ESCALATE for the next iteration."
fi

# ── Coherence audit fork (runs concurrently with browser-qa) ──────────────
# The coherence-auditor reads only the blueprint + this iteration's diff, both
# final once review settles — nothing it needs depends on services or browser
# results. Forking here hides its ~4 min under the ~20-min browser-qa lane.
# The subshell isolates CHAIN_CURRENT_AGENT and the dispatch env; run-goal.sh's
# sequential coherence step remains the automatic fallback: it reuses this
# fork's checkpoint when valid, or re-dispatches if the fork crashed.
# Disable with CHAIN_LEAN_PARALLEL_COHERENCE=false.
_COH_PID=""
_COH_RC_FILE="${ITER_DIR:+$ITER_DIR/.coherence-rc}"
COHERENCE_OUTPUT_LEAN="${ITER_DIR:+$ITER_DIR/coherence.md}"
if [[ "${CHAIN_LEAN_PARALLEL_COHERENCE:-true}" == "true" && -n "$ITER_DIR" \
      && "${GOAL_ITER_INDEX:-0}" -gt 0 \
      && -n "${GOAL_BLUEPRINT_FILE:-}" && -f "${GOAL_BLUEPRINT_FILE:-/nonexistent}" ]]; then
  if step_done_valid coherence --verify-tree --dir "$ITER_DIR" "$COHERENCE_OUTPUT_LEAN" \
     && grep -qE '^\*\*Verdict:\*\* COHERENCE-(PASS|WARN|FAIL)' "$COHERENCE_OUTPUT_LEAN"; then
    _step_skipped_event "coherence-auditor"
  else
    step_invalidate_from coherence "$ITER_DIR"
    rm -f "$_COH_RC_FILE"
    # Coherence-scoped bounded diff (judge context trim): the source tree is
    # final once review settles, so build iter-diff.md NOW for the auditor to
    # read first. run-goal.sh rebuilds the scan/iter-diff artifacts at its
    # original post-browser-qa point (overwriting these files); both builds
    # exclude harness bookkeeping (CHAIN_SCAN_BOOKKEEPING_EXCLUDES), so the
    # rebuild converges with this one instead of drifting CLEAN→CRITICAL as
    # runs/ and reports/ artifacts accumulate mid-iteration.
    if declare -F goal_gate_build_diff_artifacts >/dev/null 2>&1 || source "$SCRIPT_DIR/lib/goal-gates.sh" 2>/dev/null; then
      goal_gate_build_diff_artifacts "$ITER_DIR" "$(cat "$ITER_DIR/snapshot-sha" 2>/dev/null || echo "")" "$REPO_ROOT" 2>/dev/null || true
    fi
    echo "[goal-iter-lean] Forking coherence-auditor to run concurrently with browser-qa..."
    (
      _rc=0
      dispatch_coherence_audit "${GOAL_SESSION_ID:-unknown}" "${GOAL_ITER_INDEX}" "$ITER_NAME" \
        "$GOAL_BLUEPRINT_FILE" "$SPEC" "$COHERENCE_OUTPUT_LEAN" \
        "$(cat "$ITER_DIR/snapshot-sha" 2>/dev/null || echo "")" || _rc=$?
      echo "$_rc" > "$_COH_RC_FILE"
    ) &
    _COH_PID=$!
  fi
fi

# ── Step 3: Browser QA ────────────────────────────────────────────────────
# Determine if frontend work is implied. Lean iterations always test journeys,
# so we always try to start the frontend; if it fails we mark all SKIPPED and
# the evaluator will treat that as ESCALATE.

# (Journey sets — TARGET_JOURNEYS / REQUIRED_JOURNEYS / _bq_sig — were
# computed at the SPEED-2 block above: the fork guard needs them before the
# review loop, this resume-skip check and the lanes read the same values.)

# Resume-skip for the WHOLE browser-qa section (service boot + replay lane +
# LLM lane + merge): reusable only when the results file carries a real
# PASS/FAIL verdict (a SKIPPED verdict is never reusable — a re-run may produce
# a genuine result instead of a wasted ESCALATE), the journey sets still match
# the spec, and the tree is exactly where this iteration last left it.
_bq_skip="no"
if step_done_valid browser-qa --verify-tree --dir "$ITER_DIR" "$UI_TEST_RESULTS" \
   && [[ "$(step_field browser-qa journeys "$ITER_DIR")" == "$_bq_sig" ]]; then
  _prior_bq_verdict="$(grep -m1 -E '^\*\*Browser QA Verdict:\*\*' "$UI_TEST_RESULTS" 2>/dev/null | grep -oE 'PASS|FAIL|SKIPPED' | head -1)"
  if [[ "$_prior_bq_verdict" == "PASS" || "$_prior_bq_verdict" == "FAIL" ]]; then
    _bq_skip="yes"
    _step_skipped_event "browser-qa"
  fi
fi

# The resume-skip guard and the invalidation stay at the caller: a skipped
# resume must neither invalidate the browser-qa checkpoint nor re-run the
# section (SPEED-1 contract).
# SPEED-3 join: when the full-section fork is running, consume it instead of
# running the section inline (browser-qa was already invalidated at the spawn
# site; a second invalidation here would wipe the marker the consume just
# wrote). Off/replay modes have no full fork, so the consume returns 1
# immediately and this block behaves exactly as before.
if [[ "$_bq_skip" != "yes" ]]; then
  if ! _bqa_full_fork_consume; then
    step_invalidate_from browser-qa "$ITER_DIR"
    run_browser_qa_section
  fi
fi

# ── Coherence audit join ──────────────────────────────────────────────────
# Settle the fork BEFORE this script returns: the goal-evaluator's input set
# must be complete and identical to the sequential ordering.
if [[ -n "$_COH_PID" ]]; then
  wait "$_COH_PID" 2>/dev/null || true
  _coh_rc="$(cat "$_COH_RC_FILE" 2>/dev/null || echo 1)"
  rm -f "$_COH_RC_FILE"
  _COH_PID=""
  if [[ "$_coh_rc" -eq "${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}" ]]; then
    rm -f "$COHERENCE_OUTPUT_LEAN" 2>/dev/null || true   # partial output is untrustworthy
    _pause_if_transport "$_coh_rc" "coherence-auditor (parallel)"
  fi
  if [[ "$_coh_rc" -eq 0 ]] && grep -qE '^\*\*Verdict:\*\* COHERENCE-(PASS|WARN|FAIL)' "$COHERENCE_OUTPUT_LEAN" 2>/dev/null; then
    _coh_v="$(grep -m1 -E '^\*\*Verdict:\*\*' "$COHERENCE_OUTPUT_LEAN" | grep -oE 'COHERENCE-(PASS|WARN|FAIL)' | head -1)"
    step_mark_done coherence --dir "$ITER_DIR" --verdict "${_coh_v:-unknown}" "$COHERENCE_OUTPUT_LEAN"
    echo "[goal-iter-lean] Coherence audit (parallel) verdict: ${_coh_v:-unknown}"
  else
    # Crash or malformed output → clear it; run-goal.sh's sequential coherence
    # step re-dispatches fresh (automatic fallback) per its own rules.
    echo "[goal-iter-lean] Parallel coherence audit did not complete cleanly (rc=$_coh_rc) — falling back to the sequential dispatch in run-goal.sh." >&2
    rm -f "$COHERENCE_OUTPUT_LEAN" 2>/dev/null || true
  fi
fi

# ── Product demo (showcase) ───────────────────────────────────────────────
# Moved OUT of the lean executor: run-goal.sh's showcase tail now runs
# demo-phase.sh (per-iteration, lean depth) off the gate path — in the
# background for CONTINUE/ESCALATE, inline for halt verdicts. The evaluator
# never read demo artifacts, so its input set is unchanged. demo-phase.sh
# boots its own services idempotently, so it no longer depends on this
# script's still-warm ports.

echo "[goal-iter-lean] Done. Iteration artifacts:"
echo "  Dev handoff:   $DEV_HANDOFF"
echo "  Review report: $REVIEW_REPORT"
echo "  Test results:  $UI_TEST_RESULTS"
