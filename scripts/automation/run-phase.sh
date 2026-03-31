#!/usr/bin/env bash
# run-phase.sh — Full phase runner: plan -> test-plan -> dev -> review -> QA -> audit -> finalize
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
#   Steps already completed (plan, test-plan, dev+review, QA, audit) are skipped.
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
# Without gh auth, auto-release still commits but skips PR creation.
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
# If --reset, clear any existing checkpoint so all steps run fresh.
if [[ "$FORCE_RESET" == "true" ]]; then
  log "  --reset: clearing checkpoint, starting fresh"
  update_status "$PHASE" "in_progress" "starting"
fi

# If already finalized (and not resetting), nothing to do.
if is_finalized "$PHASE" && [[ "$FORCE_RESET" != "true" ]]; then
  log "Phase $PHASE is already finalized. Use --reset to re-run."
  exit 0
fi

CURRENT_STEP=$(get_current_step "$PHASE")
SKIP_PLAN=false
SKIP_TEST_PLAN=false
SKIP_DEV_REVIEW=false
SKIP_FIRST_DEV=false
SKIP_QA=false
SKIP_AUDIT=false

case "$CURRENT_STEP" in
  audit_passed)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true; SKIP_QA=true; SKIP_AUDIT=true ;;
  audit_failed|audit_qa_failed)
    # Audit failed — skip everything up to audit, re-run audit
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true; SKIP_QA=true ;;
  qa_passed)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true; SKIP_QA=true ;;
  qa_failed)
    # QA failed — skip plan+test-plan+dev+review, re-run QA
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true ;;
  review_passed)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true ;;
  review_failed)
    # Review failed — skip plan+test-plan, re-run dev+review
    SKIP_PLAN=true; SKIP_TEST_PLAN=true ;;
  dev_complete_attempt_*)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true
    if verdict_passes "$REVIEW_REPORT"; then
      # Review already passed but status wasn't updated before interruption
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
    if verdict_passes "$QA_REPORT"; then
      SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true; SKIP_QA=true
    elif verdict_passes "$REVIEW_REPORT"; then
      SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
    elif [[ -f "$PLAN_FILE" ]]; then
      SKIP_PLAN=true; SKIP_TEST_PLAN=true
    fi
    ;;
esac

if [[ "$CURRENT_STEP" != "" && "$CURRENT_STEP" != "init" && "$CURRENT_STEP" != "starting" ]]; then
  log "RESUMING from checkpoint: $CURRENT_STEP"
  [[ "$SKIP_PLAN" == "true" ]]       && log "  Skipping: plan (already completed)"
  [[ "$SKIP_TEST_PLAN" == "true" ]]  && log "  Skipping: test plan (already completed)"
  [[ "$SKIP_DEV_REVIEW" == "true" ]] && log "  Skipping: dev+review (already completed)"
  [[ "$SKIP_FIRST_DEV" == "true" ]]  && log "  Skipping: first dev pass (dev already completed, resuming from review)"
  [[ "$SKIP_QA" == "true" ]]         && log "  Skipping: QA (already completed)"
  [[ "$SKIP_AUDIT" == "true" ]]      && log "  Skipping: audit (already completed)"
  echo ""
else
  update_status "$PHASE" "in_progress" "starting"
fi

# ── Step 1/6: Orchestrator creates execution plan ────────────────────────────
if [[ "$SKIP_PLAN" == "false" ]]; then
  log "Step 1/6 -- Orchestrator: creating execution plan..."

  cd "$REPO_ROOT"
  claude_with_quota_retry -p "You are acting as the orchestrator for Alphion phased development.

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
5. Key Test Scenarios

Keep it concise -- 1-2 pages max. Write the plan and STOP."

  if [[ ! -f "$PLAN_FILE" ]]; then
    mkdir -p "$(dirname "$PLAN_FILE")"
    printf "# %s Execution Plan\n\nFrontend Present: no\n\nNote: orchestrator did not write plan file.\n" "$PHASE" > "$PLAN_FILE"
    log "  Warning: orchestrator did not write plan file; created fallback."
  fi

  update_status "$PHASE" "in_progress" "planned"
  log "  Plan: $PLAN_FILE"
else
  log "Step 1/6 -- Plan: skipped (checkpoint: $CURRENT_STEP)"
fi
echo ""

# ── Step 2/6: Generate functional test plan ──────────────────────────────────
if [[ "$SKIP_TEST_PLAN" == "false" ]]; then
  log "Step 2/6 -- Generating functional test plan..."
  bash "$SCRIPT_DIR/generate-test-plan.sh" "$PHASE" \
    && log "  Test plan: $TEST_PLAN" \
    || log "  Warning: test plan generation failed -- QA will run standard checks only"
  update_status "$PHASE" "in_progress" "test_plan_generated"
else
  log "Step 2/6 -- Test plan: skipped (checkpoint: $CURRENT_STEP)"
fi
echo ""

# ── Step 3/6: Dev + Review loop ──────────────────────────────────────────────
if [[ "$SKIP_DEV_REVIEW" == "false" ]]; then
  log "Step 3/6 -- Dev + Review loop (max $MAX_RETRIES attempts)..."
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
  log "Step 3/6 -- Dev + Review: skipped (checkpoint: $CURRENT_STEP)"
fi
echo ""

# ── Step 4/6: QA loop ────────────────────────────────────────────────────────
if [[ "$SKIP_QA" == "false" ]]; then
  log "Step 4/6 -- QA loop (max $MAX_RETRIES attempts)..."
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
  log "Step 4/6 -- QA: skipped (checkpoint: $CURRENT_STEP)"
fi
echo ""

# ── Step 5/6: Post-phase audit loop ──────────────────────────────────────────
if [[ "$SKIP_AUDIT" == "false" ]]; then
  log "Step 5/6 -- Post-phase audit (max $MAX_AUDIT_RETRIES attempts)..."
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
  log "Step 5/6 -- Audit: skipped (checkpoint: $CURRENT_STEP)"
fi
echo ""

# ── Step 6/6: Finalize or print instructions ────────────────────────────────
log "Step 6/6 -- Phase $PHASE complete!"
echo ""
echo "========================================"
echo "  Phase $PHASE: ALL CHECKS PASSED"
echo "========================================"
echo ""
echo "Artifacts:"
echo "  Plan:          runs/${PHASE}/plan.md"
echo "  Test plan:     reports/qa/${PHASE}-test-plan.md"
echo "  Dev handoff:   docs/handoffs/${PHASE}-dev.md"
echo "  Review report: reports/reviews/${PHASE}-review.md"
echo "  QA report:     reports/qa/${PHASE}-qa.md"
echo "  Audit report:  docs/handoffs/${PHASE}-audit.md"
echo "  Status:        runs/${PHASE}/status.json"
echo ""

if [[ "$AUTO_RELEASE" == "true" ]]; then
  log "Auto-release: running finalize-phase.sh --yes ..."
  echo ""
  bash "$SCRIPT_DIR/finalize-phase.sh" "$PHASE" --yes
else
  echo "To commit and create a PR, run:"
  echo "  ./scripts/automation/finalize-phase.sh $PHASE"
fi
