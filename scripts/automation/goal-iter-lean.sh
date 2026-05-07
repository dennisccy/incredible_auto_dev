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
  _start=$(record_agent_invocation_start "developer")
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
  _start=$(record_agent_invocation_start "reviewer")
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

# Round 1: build
run_developer "INITIAL BUILD" ""

# Round 1: review
run_reviewer || true

# Retry once if reviewer FAILed
if [[ -f "$REVIEW_REPORT" ]] && ! verdict_passes "$REVIEW_REPORT"; then
  echo "[goal-iter-lean] Review FAIL — running developer in fix mode (1 retry allowed)..."
  run_developer "FIX MODE (review failed)" "
The review report below contains FAIL issues that must be fixed.
Do NOT rebuild from scratch -- fix only what is listed.

Review report path: $REVIEW_REPORT
"
  run_reviewer || true
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

FRONTEND_RUNNING_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$FRONTEND_URL" 2>/dev/null || true)
if [[ "$FRONTEND_RUNNING_STATUS" =~ ^[23] ]]; then
  FRONTEND_AVAILABLE="yes"
else
  FRONTEND_AVAILABLE="no"
  echo "[goal-iter-lean] Frontend not available — browser tests will be SKIPPED."
fi

export CHAIN_CLAUDE_PRE_RETRY_HOOK="ensure_services_running"

cd "$REPO_ROOT"
_bqa_start=$(record_agent_invocation_start "browser-qa-agent")
_bqa_rc=0
claude_with_quota_retry -p "You are the browser-qa-agent for goal-mode lean iteration.

Iteration: $ITER_NAME
Iter spec: $SPEC
Project goal: $GOAL_FILE  <-- read \"Must-have user journeys\" section for journey definitions
Agent instructions: .claude/agents/browser-qa-agent.md  <-- read this first
(CLAUDE.md is already in your system prompt — do not Read it again.)
Skill: .claude/skills/browser-workflow-executor.md  <-- read for Chrome MCP technique

GOAL-MODE LEAN MODE — no separate ui-test-plan.md exists. Instead:
  1. Read the iter spec's \"Goal Mode Metadata\" section to find Target journeys (e.g. J-01, J-03).
  2. Read the project goal's \"Must-have user journeys\" section to find each journey's
     numbered steps and Acceptance line.
  3. Execute ONLY the journeys listed under Target journeys. Each one becomes a
     test case (use the journey ID as the test case ID, e.g. UT-J-01).
  4. Also re-run any journeys listed under \"Required-still-passing journeys\" to
     verify no regression — mark them with the same UT-<journey-id> convention.

Frontend URL: $FRONTEND_URL
Frontend available: $FRONTEND_AVAILABLE

$(if [[ "$FRONTEND_AVAILABLE" == "yes" ]]; then
  echo "Chrome MCP browser checks ARE required. Use mcp__plugin_superpowers-chrome_chrome__use_browser."
else
  echo "Frontend is NOT available. Mark all tests as SKIPPED with reason: frontend not running."
  echo "Do NOT attempt to run browser tests."
fi)

For each journey:
  - Execute the numbered steps exactly as written in goal.md
  - Verify the Acceptance condition
  - Take a screenshot of the end state, save to reports/qa/${ITER_NAME}-evidence/
  - Record PASS / FAIL / SKIP with a short failure description if FAIL

Write your results to: $UI_TEST_RESULTS
Use template: templates/ui-test-results.md
Map each journey ID to a UT row.

The report MUST contain a line at the top:
**Browser QA Verdict:** PASS
  or
**Browser QA Verdict:** FAIL
  or
**Browser QA Verdict:** SKIPPED

Then STOP." || _bqa_rc=$?

record_agent_invocation_end "browser-qa-agent" "$_bqa_start" "$_bqa_rc"

if [[ $_bqa_rc -ne 0 && $_bqa_rc -ne ${QUOTA_EXHAUSTED_EXIT_CODE:-75} ]]; then
  if [[ ! -f "$UI_TEST_RESULTS" ]]; then
    echo "[goal-iter-lean] Browser-qa exited with code $_bqa_rc without producing results file." >&2
    echo "[goal-iter-lean] Writing SKIPPED stub so evaluator can read an artifact." >&2
    write_failed_artifact_stub "$ITER_NAME" "ui-test-results" \
      "goal-iter-lean.sh browser-qa-agent invocation exited with code $_bqa_rc without flushing the results file. The evaluator will likely emit ESCALATE for the next iteration."
  fi
fi

echo "[goal-iter-lean] Done. Iteration artifacts:"
echo "  Dev handoff:   $DEV_HANDOFF"
echo "  Review report: $REVIEW_REPORT"
echo "  Test results:  $UI_TEST_RESULTS"
