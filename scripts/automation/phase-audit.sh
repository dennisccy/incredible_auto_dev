#!/usr/bin/env bash
# phase-audit.sh — Post-QA audit: verify whether the phase truly achieved its goal
# Usage: ./scripts/automation/phase-audit.sh phase-3
#
# Requires QA to have passed first. Invokes the auditor agent, which reads
# the phase spec, all handoffs, QA report, and actual source files. The auditor
# may apply fixes for critical issues found, then writes an audit report to:
#   docs/handoffs/<phase>-audit.md
#
# Verdict: PASS | PASS_WITH_GAPS | FAIL
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

PHASE="${1:-}"
require_phase_arg "$PHASE"
require_claude

# QA must have passed before audit runs
QA_REPORT="$REPO_ROOT/reports/qa/${PHASE}-qa.md"
if [[ ! -f "$QA_REPORT" ]]; then
  echo "Error: QA report not found at $QA_REPORT" >&2
  echo "Run ./scripts/automation/qa-phase.sh $PHASE first." >&2
  exit 1
fi
if ! verdict_passes "$QA_REPORT"; then
  echo "Error: QA must pass before audit. See: $QA_REPORT" >&2
  exit 1
fi

SPEC=$(phase_spec_path "$PHASE")
if [[ -z "$SPEC" ]]; then
  echo "Error: No spec found for '$PHASE' in docs/phases/" >&2
  exit 1
fi

PLAN_FILE="$REPO_ROOT/runs/${PHASE}/plan.md"
REVIEW_REPORT="$REPO_ROOT/reports/reviews/${PHASE}-review.md"
DEV_HANDOFF="$REPO_ROOT/docs/handoffs/${PHASE}-dev.md"
FRONTEND_HANDOFF="$REPO_ROOT/docs/handoffs/${PHASE}-frontend.md"
TEST_PLAN="$REPO_ROOT/reports/qa/${PHASE}-test-plan.md"
AUDIT_REPORT="$REPO_ROOT/docs/handoffs/${PHASE}-audit.md"
STATUS_FILE="$REPO_ROOT/runs/${PHASE}/status.json"

# Build optional context references
HANDOFF_CONTEXT="Dev handoff: $DEV_HANDOFF"
if [[ -f "$FRONTEND_HANDOFF" ]]; then
  HANDOFF_CONTEXT="$HANDOFF_CONTEXT
Frontend handoff: $FRONTEND_HANDOFF"
fi

TEST_PLAN_CONTEXT=""
if [[ -f "$TEST_PLAN" ]]; then
  TEST_PLAN_CONTEXT="Functional test plan: $TEST_PLAN"
fi

echo "[phase-audit] Running post-phase audit for: $PHASE"

cd "$REPO_ROOT"
claude_with_quota_retry -p "You are the auditor agent for phased development.

Phase: $PHASE
Phase spec: $SPEC
Execution plan: $PLAN_FILE
$HANDOFF_CONTEXT
Review report: $REVIEW_REPORT
QA report: $QA_REPORT
$TEST_PLAN_CONTEXT
Status file: $STATUS_FILE  <-- read changed_files to know which source files to inspect
CLAUDE.md: $REPO_ROOT/CLAUDE.md
Project template: .claude/project-template.md  <-- read for test commands and architecture rules
Agent instructions: .claude/agents/auditor.md  <-- read this first

Apply the TOKEN AND QUESTIONING POLICY from .claude/core.md strictly.
Do not ask questions — assess from evidence in the code and artifacts.

Write your audit report to: $AUDIT_REPORT

The report MUST begin with an Executive Verdict section containing exactly one of:
**Verdict:** PASS
  or
**Verdict:** PASS_WITH_GAPS
  or
**Verdict:** FAIL

IMPORTANT: The **Verdict:** prefix is required — scripts parse this line by machine. Do NOT use **PASS** or **PASS WITH GAPS** without the prefix.

Write the audit report and STOP."

if [[ ! -f "$AUDIT_REPORT" ]]; then
  echo "[phase-audit] Warning: agent did not write audit report file." >&2
  exit 1
fi

echo "[phase-audit] Done. Audit report: $AUDIT_REPORT"
