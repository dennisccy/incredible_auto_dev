#!/usr/bin/env bash
# run-phase.sh — Full phase runner: plan -> test-plan -> dev -> review -> UI impact ->
#                UI test design -> browser QA -> QA -> UX regression -> audit -> closure -> finalize
# Usage: ./scripts/automation/run-phase.sh phase-3 [--auto-release] [--reset]
#
# Flags:
#   --auto-release   Automatically finalize (branch + commit + PR) when all checks pass.
#                    Requires gh CLI authenticated: gh auth login
#   --reset          Ignore existing checkpoints and re-run all steps from scratch.
#
# Resume behavior:
#   If a run was interrupted, rerunning this script resumes from the last
#   completed step using runs/<phase>/status.json as the source of truth.
#   Steps already completed are skipped.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

PHASE="${1:-}"
AUTO_RELEASE=false
FORCE_RESET=false

# Parse flags (allow flag in any position)
for arg in "$@"; do
  case "$arg" in
    --auto-release) AUTO_RELEASE=true ;;
    --reset)        FORCE_RESET=true ;;
  esac
done

require_phase_arg "$PHASE"
require_claude

SPEC=$(phase_spec_path "$PHASE")
if [[ -z "$SPEC" ]]; then
  echo "Error: No spec found for '$PHASE' in docs/phases/" >&2
  exit 1
fi

REVIEW_REPORT="$REPO_ROOT/reports/reviews/${PHASE}-review.md"
QA_REPORT="$REPO_ROOT/reports/qa/${PHASE}-qa.md"
PLAN_FILE="$REPO_ROOT/runs/${PHASE}/plan.md"
TEST_PLAN="$REPO_ROOT/reports/qa/${PHASE}-test-plan.md"
AUDIT_REPORT="$REPO_ROOT/docs/handoffs/${PHASE}-audit.md"
IMPL_SUMMARY="$REPO_ROOT/reports/phase-${PHASE}-implementation-summary.md"
USER_VISIBLE="$REPO_ROOT/reports/phase-${PHASE}-user-visible-changes.md"
UI_SURFACE_MAP="$REPO_ROOT/reports/phase-${PHASE}-ui-surface-map.md"
UI_TEST_PLAN="$REPO_ROOT/reports/phase-${PHASE}-ui-test-plan.md"
UI_TEST_RESULTS="$REPO_ROOT/reports/phase-${PHASE}-ui-test-results.md"
WHAT_TO_CLICK="$REPO_ROOT/reports/phase-${PHASE}-what-to-click.md"
UX_REGRESSION="$REPO_ROOT/reports/phase-${PHASE}-ux-regression.md"
CLOSURE_VERDICT="$REPO_ROOT/reports/phase-${PHASE}-closure-verdict.md"
MAX_RETRIES=3
MAX_AUDIT_RETRIES=3

log()  { echo "[run-phase] $*"; }
fail() {
  local msg="$1"
  local step="${2:-failed}"
  log "FAILED: $msg" >&2
  update_status "$PHASE" "blocked" "$step"
  exit 1
}

log "========================================"
log "  Phase: $PHASE"
log "  Spec:  $SPEC"
log "  Auto-release: $AUTO_RELEASE"
log "========================================"
echo ""

# If auto-release requested, check gh auth status now (informational, not fatal)
if [[ "$AUTO_RELEASE" == "true" ]]; then
  if check_gh_auth; then
    log "  gh auth: OK — full release (branch + commit + push + PR)"
  else
    log "  gh auth: NOT configured — will commit only; PR creation will be skipped"
    log "  To enable PR creation: gh auth login"
  fi
fi

init_run_dir "$PHASE"

# ── Resume detection ────────────────────────────────────────────────────────
if [[ "$FORCE_RESET" == "true" ]]; then
  log "  --reset: clearing checkpoint, starting fresh"
  update_status "$PHASE" "in_progress" "starting"
fi

if is_finalized "$PHASE" && [[ "$FORCE_RESET" != "true" ]]; then
  log "Phase $PHASE is already finalized. Use --reset to re-run."
  exit 0
fi

CURRENT_STEP=$(get_current_step "$PHASE")
SKIP_PLAN=false
SKIP_TEST_PLAN=false
SKIP_DEV_REVIEW=false
SKIP_FIRST_DEV=false
SKIP_UI_IMPACT=false
SKIP_UI_TEST_DESIGN=false
SKIP_BROWSER_QA=false
SKIP_QA=false
SKIP_UX_REGRESSION=false
SKIP_AUDIT=false
SKIP_CLOSURE=false

case "$CURRENT_STEP" in
  closure_passed)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
    SKIP_UI_IMPACT=true; SKIP_UI_TEST_DESIGN=true; SKIP_BROWSER_QA=true
    SKIP_QA=true; SKIP_UX_REGRESSION=true; SKIP_AUDIT=true; SKIP_CLOSURE=true ;;
  closure_failed)
    # Closure failed — skip everything up to closure, re-run closure
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
    SKIP_UI_IMPACT=true; SKIP_UI_TEST_DESIGN=true; SKIP_BROWSER_QA=true
    SKIP_QA=true; SKIP_UX_REGRESSION=true; SKIP_AUDIT=true ;;
  audit_passed)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
    SKIP_UI_IMPACT=true; SKIP_UI_TEST_DESIGN=true; SKIP_BROWSER_QA=true
    SKIP_QA=true; SKIP_UX_REGRESSION=true; SKIP_AUDIT=true ;;
  audit_failed|audit_qa_failed)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
    SKIP_UI_IMPACT=true; SKIP_UI_TEST_DESIGN=true; SKIP_BROWSER_QA=true
    SKIP_QA=true; SKIP_UX_REGRESSION=true ;;
  ux_regression_complete)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
    SKIP_UI_IMPACT=true; SKIP_UI_TEST_DESIGN=true; SKIP_BROWSER_QA=true
    SKIP_QA=true; SKIP_UX_REGRESSION=true ;;
  qa_passed)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
    SKIP_UI_IMPACT=true; SKIP_UI_TEST_DESIGN=true; SKIP_BROWSER_QA=true
    SKIP_QA=true ;;
  qa_failed)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
    SKIP_UI_IMPACT=true; SKIP_UI_TEST_DESIGN=true; SKIP_BROWSER_QA=true ;;
  browser_qa_complete)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
    SKIP_UI_IMPACT=true; SKIP_UI_TEST_DESIGN=true; SKIP_BROWSER_QA=true ;;
  ui_test_designed)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
    SKIP_UI_IMPACT=true; SKIP_UI_TEST_DESIGN=true ;;
  ui_impact_complete)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
    SKIP_UI_IMPACT=true ;;
  review_passed)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true ;;
  review_failed)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true ;;
  dev_complete_attempt_*)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true
    if verdict_passes "$REVIEW_REPORT"; then
      SKIP_DEV_REVIEW=true
      update_status "$PHASE" "in_progress" "review_passed"
    else
      SKIP_FIRST_DEV=true
    fi
    ;;
  test_plan_generated)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true ;;
  planned)
    SKIP_PLAN=true ;;
  failed)
    # Legacy generic failure — infer completed stages from existing artifacts
    if closure_verdict_passes "$CLOSURE_VERDICT"; then
      SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
      SKIP_UI_IMPACT=true; SKIP_UI_TEST_DESIGN=true; SKIP_BROWSER_QA=true
      SKIP_QA=true; SKIP_UX_REGRESSION=true; SKIP_AUDIT=true; SKIP_CLOSURE=true
    elif verdict_passes "$AUDIT_REPORT"; then
      SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
      SKIP_UI_IMPACT=true; SKIP_UI_TEST_DESIGN=true; SKIP_BROWSER_QA=true
      SKIP_QA=true; SKIP_UX_REGRESSION=true; SKIP_AUDIT=true
    elif verdict_passes "$QA_REPORT"; then
      SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
      SKIP_UI_IMPACT=true; SKIP_UI_TEST_DESIGN=true; SKIP_BROWSER_QA=true
      SKIP_QA=true
    elif verdict_passes "$REVIEW_REPORT"; then
      SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
    elif [[ -f "$PLAN_FILE" ]]; then
      SKIP_PLAN=true; SKIP_TEST_PLAN=true
    fi
    ;;
esac

if [[ "$CURRENT_STEP" != "" && "$CURRENT_STEP" != "init" && "$CURRENT_STEP" != "starting" ]]; then
  log "RESUMING from checkpoint: $CURRENT_STEP"
  [[ "$SKIP_PLAN" == "true" ]]           && log "  Skipping: plan (already completed)"
  [[ "$SKIP_TEST_PLAN" == "true" ]]      && log "  Skipping: test plan (already completed)"
  [[ "$SKIP_DEV_REVIEW" == "true" ]]     && log "  Skipping: dev+review (already completed)"
  [[ "$SKIP_FIRST_DEV" == "true" ]]      && log "  Skipping: first dev pass (dev already completed, resuming from review)"
  [[ "$SKIP_UI_IMPACT" == "true" ]]      && log "  Skipping: UI impact analysis (already completed)"
  [[ "$SKIP_UI_TEST_DESIGN" == "true" ]] && log "  Skipping: UI test design (already completed)"
  [[ "$SKIP_BROWSER_QA" == "true" ]]     && log "  Skipping: browser QA (already completed)"
  [[ "$SKIP_QA" == "true" ]]             && log "  Skipping: QA (already completed)"
  [[ "$SKIP_UX_REGRESSION" == "true" ]]  && log "  Skipping: UX regression review (already completed)"
  [[ "$SKIP_AUDIT" == "true" ]]          && log "  Skipping: audit (already completed)"
  [[ "$SKIP_CLOSURE" == "true" ]]        && log "  Skipping: closure check (already completed)"
  echo ""
else
  update_status "$PHASE" "in_progress" "starting"
fi

# Detect if this phase has frontend (needed to decide which steps to skip)
FRONTEND_PRESENT="no"
if [[ -f "$PLAN_FILE" ]] && grep -qi "frontend present: yes" "$PLAN_FILE"; then
  FRONTEND_PRESENT="yes"
fi

# ── Step 1/11: Orchestrator creates execution plan ──────────────────────────
if [[ "$SKIP_PLAN" == "false" ]]; then
  log "Step 1/11 -- Orchestrator: creating execution plan..."

  cd "$REPO_ROOT"
  claude_with_quota_retry -p "You are acting as the orchestrator for phased development.

Phase: $PHASE
Phase spec: $SPEC

Read CLAUDE.md at $REPO_ROOT/CLAUDE.md, then read the phase spec.
Read .claude/agents/orchestrator.md for your full instructions.

Apply the TOKEN AND QUESTIONING POLICY from CLAUDE.md strictly.
Ask necessary questions, but batch them upfront and avoid follow-up cascades.

Write a concise execution plan to: $PLAN_FILE

The plan must include these sections:
1. What to Build (bullet list)
2. Agents Required: backend-data (yes/no), frontend-ux (yes/no)
3. Frontend Present: yes/no  <-- QA agent uses this to decide browser checks
4. Files to Create/Modify (expected list)
5. UI Evolution section (required if Frontend Present: yes):
   - New user-facing capability
   - New information displayed
   - New user actions
   - UI surface changes
   - Navigation changes
6. Key Test Scenarios

Keep it concise -- 1-2 pages max. Write the plan and STOP."

  if [[ ! -f "$PLAN_FILE" ]]; then
    mkdir -p "$(dirname "$PLAN_FILE")"
    printf "# %s Execution Plan\n\nFrontend Present: no\n\nNote: orchestrator did not write plan file.\n" "$PHASE" > "$PLAN_FILE"
    log "  Warning: orchestrator did not write plan file; created fallback."
  fi

  # Re-detect frontend after plan is written
  if grep -qi "frontend present: yes" "$PLAN_FILE"; then
    FRONTEND_PRESENT="yes"
  fi

  update_status "$PHASE" "in_progress" "planned"
  log "  Plan: $PLAN_FILE"
  log "  Frontend present: $FRONTEND_PRESENT"
else
  log "Step 1/11 -- Plan: skipped (checkpoint: $CURRENT_STEP)"
  # Re-detect from existing plan
  if [[ -f "$PLAN_FILE" ]] && grep -qi "frontend present: yes" "$PLAN_FILE"; then
    FRONTEND_PRESENT="yes"
  fi
fi
echo ""

# ── Step 2/11: Generate functional test plan ────────────────────────────────
if [[ "$SKIP_TEST_PLAN" == "false" ]]; then
  log "Step 2/11 -- Generating functional test plan..."
  bash "$SCRIPT_DIR/generate-test-plan.sh" "$PHASE" \
    && log "  Test plan: $TEST_PLAN" \
    || log "  Warning: test plan generation failed -- QA will run standard checks only"
  update_status "$PHASE" "in_progress" "test_plan_generated"
else
  log "Step 2/11 -- Test plan: skipped (checkpoint: $CURRENT_STEP)"
fi
echo ""

# ── Step 3/11: Dev + Review loop ─────────────────────────────────────────────
if [[ "$SKIP_DEV_REVIEW" == "false" ]]; then
  log "Step 3/11 -- Dev + Review loop (max $MAX_RETRIES attempts)..."
  ATTEMPT=0

  while true; do
    ATTEMPT=$((ATTEMPT + 1))

    if [[ "$SKIP_FIRST_DEV" == "true" && $ATTEMPT -eq 1 ]]; then
      log "  [attempt $ATTEMPT/$MAX_RETRIES] Skipping dev (already completed), running reviewer..."
    else
      log "  [attempt $ATTEMPT/$MAX_RETRIES] Running dev agent..."
      bash "$SCRIPT_DIR/dev-phase.sh" "$PHASE" || log "  Warning: dev-phase.sh exited with error (attempt $ATTEMPT) -- continuing to review"
      update_status "$PHASE" "in_progress" "dev_complete_attempt_${ATTEMPT}"
    fi

    log "  [attempt $ATTEMPT/$MAX_RETRIES] Running reviewer..."
    bash "$SCRIPT_DIR/review-phase.sh" "$PHASE" || log "  Warning: review-phase.sh exited with error (attempt $ATTEMPT) -- checking verdict"

    if verdict_passes "$REVIEW_REPORT"; then
      log "  Review: PASS"
      break
    fi

    if [[ $ATTEMPT -ge $MAX_RETRIES ]]; then
      fail "Review failed after $MAX_RETRIES attempts. See: $REVIEW_REPORT" "review_failed"
    fi

    log "  Review: FAIL (attempt $ATTEMPT) -- looping back to dev..."
  done

  update_status "$PHASE" "in_progress" "review_passed"
else
  log "Step 3/11 -- Dev + Review: skipped (checkpoint: $CURRENT_STEP)"
fi
echo ""

# ── Step 4/11: UI Impact Analysis ────────────────────────────────────────────
if [[ "$SKIP_UI_IMPACT" == "false" ]]; then
  log "Step 4/11 -- UI Impact Analysis..."
  bash "$SCRIPT_DIR/ui-impact-phase.sh" "$PHASE" \
    || log "  Warning: ui-impact-phase.sh exited with error -- continuing"
  update_status "$PHASE" "in_progress" "ui_impact_complete"
  log "  User-visible changes: $USER_VISIBLE"
  log "  UI surface map:       $UI_SURFACE_MAP"
else
  log "Step 4/11 -- UI Impact Analysis: skipped (checkpoint: $CURRENT_STEP)"
fi
echo ""

# ── Step 5/11: UI Test Design ─────────────────────────────────────────────────
if [[ "$SKIP_UI_TEST_DESIGN" == "false" ]]; then
  if [[ "$FRONTEND_PRESENT" == "yes" ]]; then
    log "Step 5/11 -- UI Test Design..."
    bash "$SCRIPT_DIR/ui-test-design-phase.sh" "$PHASE" \
      || log "  Warning: ui-test-design-phase.sh exited with error -- continuing"
    log "  UI test plan:  $UI_TEST_PLAN"
    log "  What to click: $WHAT_TO_CLICK"
  else
    log "Step 5/11 -- UI Test Design: skipped (backend-only phase) -- writing N/A stubs."
    write_na_ui_artifacts "$PHASE" "ui-test-plan" "what-to-click"
  fi
  update_status "$PHASE" "in_progress" "ui_test_designed"
else
  log "Step 5/11 -- UI Test Design: skipped (checkpoint: $CURRENT_STEP)"
fi
echo ""

# ── Step 6/11: Browser QA ─────────────────────────────────────────────────────
if [[ "$SKIP_BROWSER_QA" == "false" ]]; then
  if [[ "$FRONTEND_PRESENT" == "yes" ]]; then
    log "Step 6/11 -- Browser QA..."
    bash "$SCRIPT_DIR/browser-qa-phase.sh" "$PHASE" \
      || log "  Warning: browser-qa-phase.sh exited with error -- continuing"
    log "  Browser QA results: $UI_TEST_RESULTS"
  else
    log "Step 6/11 -- Browser QA: skipped (backend-only phase) -- writing N/A stubs."
    write_na_ui_artifacts "$PHASE" "ui-test-results"
  fi
  update_status "$PHASE" "in_progress" "browser_qa_complete"
else
  log "Step 6/11 -- Browser QA: skipped (checkpoint: $CURRENT_STEP)"
fi
echo ""

# ── Step 7/11: QA loop ────────────────────────────────────────────────────────
if [[ "$SKIP_QA" == "false" ]]; then
  log "Step 7/11 -- QA loop (max $MAX_RETRIES attempts)..."
  QA_ATTEMPT=0

  while true; do
    QA_ATTEMPT=$((QA_ATTEMPT + 1))
    log "  [QA attempt $QA_ATTEMPT/$MAX_RETRIES] Running QA validator..."
    bash "$SCRIPT_DIR/qa-phase.sh" "$PHASE" || log "  Warning: qa-phase.sh exited with error (attempt $QA_ATTEMPT) -- checking verdict"

    if verdict_passes "$QA_REPORT"; then
      log "  QA: PASS"
      break
    fi

    if [[ $QA_ATTEMPT -ge $MAX_RETRIES ]]; then
      fail "QA failed after $MAX_RETRIES attempts. See: $QA_REPORT" "qa_failed"
    fi

    log "  QA: FAIL (attempt $QA_ATTEMPT) -- fixing then re-reviewing..."
    bash "$SCRIPT_DIR/dev-phase.sh" "$PHASE" || log "  Warning: dev-phase.sh exited with error -- continuing"
    bash "$SCRIPT_DIR/review-phase.sh" "$PHASE" || log "  Warning: review-phase.sh exited with error -- continuing"
  done

  update_status "$PHASE" "complete" "qa_passed"
else
  log "Step 7/11 -- QA: skipped (checkpoint: $CURRENT_STEP)"
fi
echo ""

# ── Step 8/11: UX Regression Review ──────────────────────────────────────────
if [[ "$SKIP_UX_REGRESSION" == "false" ]]; then
  if [[ "$FRONTEND_PRESENT" == "yes" ]]; then
    log "Step 8/11 -- UX Regression Review..."
    bash "$SCRIPT_DIR/ux-regression-phase.sh" "$PHASE" \
      || log "  Warning: ux-regression-phase.sh exited with error -- continuing"
    if ! ux_regression_verdict_passes "$UX_REGRESSION"; then
      log "  UX Regression: FAIL -- flagging for attention (non-blocking, closure auditor will assess)"
    else
      log "  UX Regression: PASS or WARN (acceptable)"
    fi
  else
    log "Step 8/11 -- UX Regression: skipped (backend-only phase)."
  fi
  update_status "$PHASE" "in_progress" "ux_regression_complete"
else
  log "Step 8/11 -- UX Regression Review: skipped (checkpoint: $CURRENT_STEP)"
fi
echo ""

# ── Step 9/11: Post-phase audit loop ─────────────────────────────────────────
if [[ "$SKIP_AUDIT" == "false" ]]; then
  log "Step 9/11 -- Post-phase audit (max $MAX_AUDIT_RETRIES attempts)..."
  AUDIT_ATTEMPT=0

  while true; do
    AUDIT_ATTEMPT=$((AUDIT_ATTEMPT + 1))
    log "  [audit attempt $AUDIT_ATTEMPT/$MAX_AUDIT_RETRIES] Running phase auditor..."
    bash "$SCRIPT_DIR/phase-audit.sh" "$PHASE" || log "  Warning: phase-audit.sh exited with error (attempt $AUDIT_ATTEMPT) -- checking verdict"

    if verdict_passes "$AUDIT_REPORT"; then
      log "  Audit: PASS"
      break
    fi

    if [[ $AUDIT_ATTEMPT -ge $MAX_AUDIT_RETRIES ]]; then
      fail "Audit failed after $MAX_AUDIT_RETRIES attempts. See: $AUDIT_REPORT" "audit_failed"
    fi

    log "  Audit: FAIL (attempt $AUDIT_ATTEMPT) -- applying hardening fixes..."
    bash "$SCRIPT_DIR/dev-phase.sh" "$PHASE" || log "  Warning: dev-phase.sh exited with error -- continuing"
    bash "$SCRIPT_DIR/review-phase.sh" "$PHASE" || log "  Warning: review-phase.sh exited with error -- continuing"

    log "  Re-running QA after hardening..."
    bash "$SCRIPT_DIR/qa-phase.sh" "$PHASE" || log "  Warning: qa-phase.sh exited with error -- checking verdict"
    if ! verdict_passes "$QA_REPORT"; then
      fail "QA failed during audit hardening. See: $QA_REPORT" "audit_qa_failed"
    fi
    log "  QA: PASS (post-hardening)"
  done

  update_status "$PHASE" "complete" "audit_passed"
else
  log "Step 9/11 -- Audit: skipped (checkpoint: $CURRENT_STEP)"
fi
echo ""

# ── Step 10/11: Phase Closure Check ──────────────────────────────────────────
if [[ "$SKIP_CLOSURE" == "false" ]]; then
  log "Step 10/11 -- Phase Closure Check..."
  bash "$SCRIPT_DIR/phase-closure-check.sh" "$PHASE" || log "  Warning: phase-closure-check.sh exited with error -- checking verdict"

  if ! closure_verdict_passes "$CLOSURE_VERDICT"; then
    fail "Phase closure check failed. See: $CLOSURE_VERDICT" "closure_failed"
  fi

  log "  Closure: PASS"
  update_status "$PHASE" "complete" "closure_passed"
else
  log "Step 10/11 -- Closure Check: skipped (checkpoint: $CURRENT_STEP)"
fi
echo ""

# ── Step 11/11: Finalize or print instructions ──────────────────────────────
log "Step 11/11 -- Phase $PHASE complete!"
echo ""
echo "========================================"
echo "  Phase $PHASE: ALL CHECKS PASSED"
echo "========================================"
echo ""
echo "Artifacts:"
echo "  Plan:                     runs/${PHASE}/plan.md"
echo "  Test plan:                reports/qa/${PHASE}-test-plan.md"
echo "  Dev handoff:              docs/handoffs/${PHASE}-dev.md"
echo "  Review report:            reports/reviews/${PHASE}-review.md"
echo "  Implementation summary:   reports/phase-${PHASE}-implementation-summary.md"
echo "  User-visible changes:     reports/phase-${PHASE}-user-visible-changes.md"
echo "  UI surface map:           reports/phase-${PHASE}-ui-surface-map.md"
echo "  UI test plan:             reports/phase-${PHASE}-ui-test-plan.md"
echo "  Browser QA results:       reports/phase-${PHASE}-ui-test-results.md"
echo "  What to click:            reports/phase-${PHASE}-what-to-click.md"
echo "  UX regression review:     reports/phase-${PHASE}-ux-regression.md"
echo "  QA report:                reports/qa/${PHASE}-qa.md"
echo "  Audit report:             docs/handoffs/${PHASE}-audit.md"
echo "  Closure verdict:          reports/phase-${PHASE}-closure-verdict.md"
echo "  Status:                   runs/${PHASE}/status.json"
echo ""
echo "Quick verification:"
echo "  cat reports/phase-${PHASE}-what-to-click.md"
echo ""

if [[ "$AUTO_RELEASE" == "true" ]]; then
  log "Auto-release: running finalize-phase.sh --yes ..."
  echo ""
  bash "$SCRIPT_DIR/finalize-phase.sh" "$PHASE" --yes
else
  echo "To commit and create a PR, run:"
  echo "  ./scripts/automation/finalize-phase.sh $PHASE"
fi
