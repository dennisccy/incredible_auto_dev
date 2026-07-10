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
# The outer run-goal.sh runs the goal-evaluator after this script returns.
#
# All Claude calls go through claude_with_quota_retry → --effort max + auto-resume on quota.
# Telemetry events are recorded via lib/telemetry.sh when GOAL_SESSION_DIR is set.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/telemetry.sh"

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

# ── Cleanup any stray dev server processes on exit ────────────────────────
cleanup_iter_servers() {
  local _be_port="${CHAIN_BACKEND_PORT:-8000}"
  local _fe_port="${CHAIN_FRONTEND_PORT:-3000}"
  pkill -f "uvicorn main:app.*--port ${_be_port}" 2>/dev/null || true
  pkill -f "next dev -p ${_fe_port}" 2>/dev/null || true
  pkill -f "next-server.*:${_fe_port}" 2>/dev/null || true
  fuser -k "${_be_port}/tcp" "${_fe_port}/tcp" 2>/dev/null || true
  # Reap a still-running coherence fork so an aborting iteration can't leave an
  # orphaned agent racing a future resume of the same iteration.
  if [[ -n "${_COH_PID:-}" ]]; then
    if declare -F _kill_pid_tree >/dev/null 2>&1; then
      _kill_pid_tree "$_COH_PID" 2>/dev/null || true
    else
      kill "$_COH_PID" 2>/dev/null || true
    fi
  fi
}
trap 'cleanup_iter_servers; chain_tmp_cleanup' EXIT

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
Project template: .claude/project-template.md
Agent instructions: .claude/agents/reviewer.md  <-- read this first
(CLAUDE.md is already in your system prompt — do not Read it again.)

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
    # read first. The evaluator's own scan/iter-diff artifacts are still built
    # at their original post-browser-qa point in run-goal.sh (overwriting this
    # file), so the evaluator's inputs are byte-identical to before.
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

# Journey sets come from the spec (needed by the resume-skip check below AND by
# the lanes inside the block). First match wins.
_spec_journeys() { grep -iE "$1" "$SPEC" 2>/dev/null | head -1 | grep -oE 'J-[0-9]+' | sort -u | tr '\n' ' '; }
TARGET_JOURNEYS="$(_spec_journeys 'Target journeys:')"
REQUIRED_JOURNEYS="$(_spec_journeys 'Required-still-passing')"
_bq_sig="${TARGET_JOURNEYS}|${REQUIRED_JOURNEYS}"

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

# NOTE: the section below is guarded, not re-indented — the guard is the only
# change to its flow. It ends at the matching `fi` before the demo step.
if [[ "$_bq_skip" != "yes" ]]; then
step_invalidate_from browser-qa "$ITER_DIR"

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

ensure_services_running

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

export CHAIN_CLAUDE_PRE_RETRY_HOOK="ensure_services_running"
cd "$REPO_ROOT"

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
EVIDENCE_DIR="$REPO_ROOT/reports/qa/${ITER_NAME}-evidence"
SID="${ITER_NAME#goal-}"; SID="${SID%-iter-*}"
JOURNEY_SCRIPTS_DIR="$REPO_ROOT/runs/goal-session-${SID}/journey-scripts"
mkdir -p "$JOURNEY_SCRIPTS_DIR"
REGRESSION_RESULTS="$REPO_ROOT/reports/phase-${ITER_NAME}-regression-replay-results.md"
LLM_RESULTS="$REPO_ROOT/reports/phase-${ITER_NAME}-ui-test-results.llm.md"
DEMO_RUNNER="$SCRIPT_DIR/lib/demo_runner.py"
MERGE_RESULTS="$SCRIPT_DIR/lib/merge_ui_test_results.py"

# (Journey IDs were pulled from the spec above, before the resume-skip check.)

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

# Partition Required-still-passing into replay (LINTABLE golden on file) vs LLM.
# A golden that fails validation is quarantined (renamed *.json.invalid) and its
# journey routed to the LLM lane — previously an invalid golden produced a
# replay SKIP that nothing re-confirmed (silently unverified journey). A lint
# crash (no output) conservatively keeps the old file-exists behavior: the
# verify runner re-validates at replay time anyway.
_lint_out=""
if [[ -n "${REQUIRED_JOURNEYS// /}" ]]; then
  _lint_out="$(python3 "$DEMO_RUNNER" --mode lint --scripts-dir "$JOURNEY_SCRIPTS_DIR" \
    --journeys "$(echo "$REQUIRED_JOURNEYS" | tr ' ' ',' | sed 's/^,*//;s/,*$//')" 2>/dev/null || true)"
fi
R_REPLAY=""; R_LLM=""
for _j in $REQUIRED_JOURNEYS; do
  if [[ -f "$JOURNEY_SCRIPTS_DIR/$_j.json" ]]; then
    if printf '%s\n' "$_lint_out" | grep -q "^$_j invalid"; then
      echo "[goal-iter-lean] Golden for $_j failed lint — quarantining ($_j.json.invalid) and routing to the LLM lane: $(printf '%s\n' "$_lint_out" | grep -m1 "^$_j invalid" | cut -d' ' -f2-)"
      mv -f "$JOURNEY_SCRIPTS_DIR/$_j.json" "$JOURNEY_SCRIPTS_DIR/$_j.json.invalid" 2>/dev/null || true
      R_LLM+="$_j "
    else
      R_REPLAY+="$_j "
    fi
  else
    R_LLM+="$_j "
  fi
done

_use_replay="no"
if [[ "${CHAIN_REGRESSION_REPLAY:-true}" == "true" && "$FRONTEND_AVAILABLE" == "yes" && -n "${R_REPLAY// /}" ]]; then
  _use_replay="yes"
fi

# Lane 1 — deterministic replay of the already-passing set (only if golden scripts exist).
REPLAY_FAILED=""
if [[ "$_use_replay" == "yes" ]]; then
  echo "[goal-iter-lean] Regression (deterministic replay): $R_REPLAY"
  _replay_csv="$(echo "$R_REPLAY" | tr ' ' ',' | sed 's/^,*//;s/,*$//')"
  _replay_rc=0
  python3 "$DEMO_RUNNER" --mode verify \
    --scripts-dir "$JOURNEY_SCRIPTS_DIR" --journeys "$_replay_csv" \
    --results "$REGRESSION_RESULTS" --evidence-dir "$EVIDENCE_DIR" \
    --base-url "$FRONTEND_URL" --phase-id "$ITER_NAME" --repo-root "$REPO_ROOT" || _replay_rc=$?
  if [[ "$_replay_rc" -eq 5 ]]; then
    REPLAY_FAILED="$(grep -E '^\| UT-J-[0-9]+ ' "$REGRESSION_RESULTS" 2>/dev/null | grep -F '| FAIL |' | grep -oE 'J-[0-9]+' | sort -u | tr '\n' ' ')"
    echo "[goal-iter-lean] Replay flagged possible regression(s) — re-confirming via LLM: $REPLAY_FAILED"
  elif [[ "$_replay_rc" -ne 0 ]]; then
    # Replay-lane infrastructure failure (rc 6 = browser launch/crash; any
    # other rc = runner crash). The replay journeys were NOT verified — route
    # ALL of them back to the LLM lane, byte-identical to running this
    # iteration with CHAIN_REGRESSION_REPLAY=false. Previously a replay crash
    # left them silently unverified for the iteration.
    echo "[goal-iter-lean] Replay lane failed (rc=$_replay_rc) — falling back to the LLM lane for ALL regression journeys." >&2
    _use_replay="no"
    R_REPLAY=""
  fi
fi

# Lane 2 — LLM browser-qa-agent.
if [[ "$_use_replay" == "yes" ]]; then
  _llm_set="$TARGET_JOURNEYS $R_LLM $REPLAY_FAILED"   # targets + no-golden regression + replay re-confirms
  _llm_out="$LLM_RESULTS"
else
  _llm_set="$TARGET_JOURNEYS $REQUIRED_JOURNEYS"       # replay off → LLM covers everything (prior behaviour)
  _llm_out="$UI_TEST_RESULTS"
fi
LLM_JOURNEYS="$(echo "$_llm_set" | tr ' ' '\n' | grep -E '^J-[0-9]+$' | sort -u | tr '\n' ' ')"
_llm_csv="$(echo "$LLM_JOURNEYS" | tr ' ' ',' | sed 's/^,*//;s/,*$//')"

_bqa_rc=0
if [[ -n "$_llm_csv" || "$_use_replay" != "yes" ]]; then
  run_browser_qa_llm "$_llm_csv" "$_llm_out" "$R_REPLAY" || _bqa_rc=$?
fi

# Merge replay + LLM into the single results file the goal-evaluator reads
# (LLM listed last → wins on any journey both lanes touched, e.g. a re-confirm).
if [[ "$_use_replay" == "yes" ]]; then
  if ! python3 "$MERGE_RESULTS" "$UI_TEST_RESULTS" "$REGRESSION_RESULTS" "$_llm_out"; then
    echo "[goal-iter-lean] results merge failed — falling back to a lane output." >&2
    if [[ -f "$_llm_out" ]]; then cp "$_llm_out" "$UI_TEST_RESULTS" 2>/dev/null || true
    elif [[ -f "$REGRESSION_RESULTS" ]]; then cp "$REGRESSION_RESULTS" "$UI_TEST_RESULTS" 2>/dev/null || true; fi
  fi
fi

# If no results artifact exists at all (and it was not a quota pause), leave a
# SKIPPED stub so the evaluator always has something to read.
if [[ ! -f "$UI_TEST_RESULTS" && "$_bqa_rc" -ne "${QUOTA_EXHAUSTED_EXIT_CODE:-75}" ]]; then
  echo "[goal-iter-lean] Browser-qa produced no results file (rc=$_bqa_rc) — writing SKIPPED stub." >&2
  write_failed_artifact_stub "$ITER_NAME" "ui-test-results" \
    "goal-iter-lean.sh browser-qa produced no results file (exit $_bqa_rc). The evaluator will likely emit ESCALATE for the next iteration."
fi

# Golden coverage: every PASSing journey should now have a lintable golden so
# the replay lane keeps growing (browser-qa LLM time decays iteration over
# iteration). A gap is loud but non-gating — those journeys simply return to
# the LLM lane next iteration.
_pass_j="$(grep -E '^\| UT-J-[0-9]+ ' "$UI_TEST_RESULTS" 2>/dev/null | grep -F '| PASS |' | grep -oE 'J-[0-9]+' | sort -u | tr '\n' ' ')"
_n_pass=0; _missing_golden=""
for _j in $_pass_j; do
  _n_pass=$((_n_pass + 1))
  [[ -f "$JOURNEY_SCRIPTS_DIR/$_j.json" ]] || _missing_golden+="$_j "
done
if [[ -n "${_missing_golden// /}" ]]; then
  echo "[goal-iter-lean] Golden coverage gap: PASSing journey(s) without a replay script: ${_missing_golden}— the browser-qa agent should write a golden per PASS (they fall back to the slower LLM lane next iteration)."
fi
record_telemetry_event "golden_coverage" "$(jq -cn --argjson p "$_n_pass" --arg m "${_missing_golden% }" --arg n "$ITER_NAME" '{passing:$p, missing_goldens:$m, iter_name:$n}' 2>/dev/null || printf '{"passing":%d,"missing_goldens":"%s"}' "$_n_pass" "${_missing_golden% }")"

# Checkpoint: reusable on resume only with a real PASS/FAIL verdict (never a
# SKIPPED stub) and the journey signature this run actually covered.
_bq_verdict="$(grep -m1 -E '^\*\*Browser QA Verdict:\*\*' "$UI_TEST_RESULTS" 2>/dev/null | grep -oE 'PASS|FAIL|SKIPPED' | head -1)"
if [[ "$_bq_verdict" == "PASS" || "$_bq_verdict" == "FAIL" ]]; then
  step_mark_done browser-qa --dir "$ITER_DIR" --verdict "$_bq_verdict" --journeys "$_bq_sig" "$UI_TEST_RESULTS"
fi

fi  # end of the browser-qa resume-skip guard (_bq_skip)

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
