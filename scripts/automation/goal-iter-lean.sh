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

echo "[goal-iter-lean] Iteration: $ITER_NAME"
record_telemetry_event "iter_dispatch" "$(jq -cn --arg n "$ITER_NAME" --arg d "lean" '{iter_name:$n, depth:$d}' 2>/dev/null || printf '{"iter_name":"%s","depth":"lean"}' "$ITER_NAME")"

ensure_phase_ports

# ── Cleanup any stray dev server processes on exit ────────────────────────
cleanup_iter_servers() {
  local _be_port="${CHAIN_BACKEND_PORT:-8000}"
  local _fe_port="${CHAIN_FRONTEND_PORT:-3000}"
  pkill -f "uvicorn main:app.*--port ${_be_port}" 2>/dev/null || true
  pkill -f "next dev -p ${_fe_port}" 2>/dev/null || true
  pkill -f "next-server.*:${_fe_port}" 2>/dev/null || true
  fuser -k "${_be_port}/tcp" "${_fe_port}/tcp" 2>/dev/null || true
}
trap cleanup_iter_servers EXIT

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

Run: git diff HEAD to see what changed.

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
_dev_rc=0
run_developer "INITIAL BUILD" "" || _dev_rc=$?
_pause_if_transport "$_dev_rc" "developer (initial build)"
if [[ "$_dev_rc" -ne 0 ]]; then exit "$_dev_rc"; fi

# Round 1: review. A transport failure pauses; any other review failure is
# tolerated (the retry below / evaluator handles it), as the prior `|| true` did.
_rev_rc=0
run_reviewer || _rev_rc=$?
_pause_if_transport "$_rev_rc" "reviewer"

# Retry once if reviewer FAILed
if [[ -f "$REVIEW_REPORT" ]] && ! verdict_passes "$REVIEW_REPORT"; then
  echo "[goal-iter-lean] Review FAIL — running developer in fix mode (1 retry allowed)..."
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
  _rev_rc=0
  run_reviewer || _rev_rc=$?
  _pause_if_transport "$_rev_rc" "reviewer (fix-mode)"
fi

if [[ -f "$REVIEW_REPORT" ]] && ! verdict_passes "$REVIEW_REPORT"; then
  echo "[goal-iter-lean] Review still FAIL after retry — proceeding to browser-qa anyway."
  echo "[goal-iter-lean] The goal-evaluator will likely emit ESCALATE for the next iteration."
fi

# ── Step 3: Browser QA ────────────────────────────────────────────────────
# Determine if frontend work is implied. Lean iterations always test journeys,
# so we always try to start the frontend; if it fails we mark all SKIPPED and
# the evaluator will treat that as ESCALATE.

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

# Pull the journey IDs out of a spec metadata line (first match wins).
_spec_journeys() { grep -iE "$1" "$SPEC" 2>/dev/null | head -1 | grep -oE 'J-[0-9]+' | sort -u | tr '\n' ' '; }
TARGET_JOURNEYS="$(_spec_journeys 'Target journeys:')"
REQUIRED_JOURNEYS="$(_spec_journeys 'Required-still-passing')"

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

# Partition Required-still-passing into replay (golden script on file) vs LLM.
R_REPLAY=""; R_LLM=""
for _j in $REQUIRED_JOURNEYS; do
  if [[ -f "$JOURNEY_SCRIPTS_DIR/$_j.json" ]]; then R_REPLAY+="$_j "; else R_LLM+="$_j "; fi
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

# ── Product demo (showcase) ───────────────────────────────────────────────
# Reuses the still-running app (cleanup_iter_servers fires only on EXIT). The
# idempotent ensure_services_running in demo-phase.sh is a no-op when ports
# are warm, so no second boot. Non-gating: failures become a SKIPPED stub and
# the lean iteration continues to its closing summary.
bash "$SCRIPT_DIR/demo-phase.sh" "$ITER_NAME" \
  || echo "[goal-iter-lean] demo-phase.sh exited non-zero — continuing (showcase, non-gating)"

echo "[goal-iter-lean] Done. Iteration artifacts:"
echo "  Dev handoff:   $DEV_HANDOFF"
echo "  Review report: $REVIEW_REPORT"
echo "  Test results:  $UI_TEST_RESULTS"
