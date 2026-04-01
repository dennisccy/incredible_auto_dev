#!/usr/bin/env bash
# phase-closure-check.sh — Run phase closure audit (final gate before finalize)
# Usage: ./scripts/automation/phase-closure-check.sh phase-3
#
# Verifies all required artifacts exist and are non-vague.
# Blocks phases from completing when UI artifacts are missing or inconsistent.
# Runs after the audit loop, before finalize.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

PHASE="${1:-}"
require_phase_arg "$PHASE"
require_claude

SPEC=$(phase_spec_path "$PHASE")
if [[ -z "$SPEC" ]]; then
  echo "Error: No spec found for '$PHASE' in docs/phases/" >&2
  exit 1
fi

PLAN_FILE="$REPO_ROOT/runs/${PHASE}/plan.md"
REVIEW_REPORT="$REPO_ROOT/reports/reviews/${PHASE}-review.md"
QA_REPORT="$REPO_ROOT/reports/qa/${PHASE}-qa.md"
AUDIT_REPORT="$REPO_ROOT/docs/handoffs/${PHASE}-audit.md"
CLOSURE_VERDICT="$REPO_ROOT/reports/phase-${PHASE}-closure-verdict.md"

echo "[closure-check] Running phase closure audit for: $PHASE"

# Verify standard pipeline gates are present before invoking agent
MISSING_GATES=()
[[ -f "$REVIEW_REPORT" ]] || MISSING_GATES+=("$REVIEW_REPORT")
[[ -f "$QA_REPORT" ]]     || MISSING_GATES+=("$QA_REPORT")

if [[ ${#MISSING_GATES[@]} -gt 0 ]]; then
  echo "Error: Required pipeline artifacts missing:" >&2
  for f in "${MISSING_GATES[@]}"; do echo "  $f" >&2; done
  echo "Complete the pipeline stages before running closure check." >&2
  exit 1
fi

# Check backend-only claim consistency (non-fatal — agent will assess)
check_backend_only_claim "$PHASE" || \
  echo "[closure-check] Warning: user-visible-changes may be inconsistent with actual file changes."

cd "$REPO_ROOT"
claude_with_quota_retry -p "You are the phase-closure-auditor for phased development.

Phase: $PHASE
Phase spec: $SPEC
CLAUDE.md: $REPO_ROOT/CLAUDE.md
Agent instructions: .claude/agents/phase-closure-auditor.md  <-- read this first
Skill: .claude/skills/phase-closure-gate.md

Execution plan: $PLAN_FILE
Review report: $REVIEW_REPORT
QA report: $QA_REPORT
Audit report: $AUDIT_REPORT (if exists)

UI visibility artifacts (check each exists and has real content):
  - reports/phase-${PHASE}-implementation-summary.md
  - reports/phase-${PHASE}-user-visible-changes.md
  - reports/phase-${PHASE}-ui-surface-map.md
  - reports/phase-${PHASE}-ui-test-plan.md
  - reports/phase-${PHASE}-ui-test-results.md
  - reports/phase-${PHASE}-what-to-click.md

UX regression report (if exists): reports/phase-${PHASE}-ux-regression.md

Your job:
1. Verify all standard pipeline gates passed (review, QA, audit)
2. Verify all 6 UI visibility artifacts exist and are non-vague
3. Cross-reference claims vs evidence for consistency
4. Check for backend-only claims when frontend work was expected
5. Write closure verdict to: $CLOSURE_VERDICT

Use template: templates/closure-verdict.md

Verdict line MUST appear at the top of the file:
**Verdict:** CLOSURE-PASS
  or
**Verdict:** CLOSURE-FAIL

For CLOSURE-FAIL: list exact blocking issues and specific remediation steps.

Then STOP."

echo "[closure-check] Done. Verdict: $CLOSURE_VERDICT"
if [[ -f "$CLOSURE_VERDICT" ]]; then
  VERDICT=$(grep -m1 "^\*\*Verdict:\*\*" "$CLOSURE_VERDICT" 2>/dev/null || echo "")
  [[ -n "$VERDICT" ]] && echo "[closure-check] $VERDICT"
fi
