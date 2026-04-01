#!/usr/bin/env bash
# finalize-phase.sh — Commit phase artifacts and create a PR
# Usage: ./scripts/automation/finalize-phase.sh phase-3 [--yes]
#
# Flags:
#   --yes   Skip interactive confirmation (used by run-phase --auto-release)
#
# Requires:
# - QA report with PASS verdict (run qa-phase.sh first)
# - gh CLI authenticated (run: gh auth login)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

PHASE="${1:-}"
AUTO_YES=false

# Parse flags
for arg in "$@"; do
  case "$arg" in
    --yes|-y) AUTO_YES=true ;;
  esac
done

require_phase_arg "$PHASE"
require_claude

QA_REPORT="$REPO_ROOT/reports/qa/${PHASE}-qa.md"
STATUS_FILE="$REPO_ROOT/runs/${PHASE}/status.json"
SUMMARY_FILE="$REPO_ROOT/runs/${PHASE}/summary.json"

if [[ ! -f "$QA_REPORT" ]]; then
  echo "Error: QA report not found at $QA_REPORT" >&2
  echo "Run ./scripts/automation/qa-phase.sh $PHASE first." >&2
  exit 1
fi

if ! verdict_passes "$QA_REPORT"; then
  echo "Error: QA report does not have a PASS verdict." >&2
  echo "Check $QA_REPORT for details." >&2
  exit 1
fi

AUDIT_REPORT="$REPO_ROOT/docs/handoffs/${PHASE}-audit.md"
if [[ -f "$AUDIT_REPORT" ]] && ! verdict_passes "$AUDIT_REPORT"; then
  echo "Error: Audit report does not have a passing verdict." >&2
  echo "Check $AUDIT_REPORT for details." >&2
  exit 1
fi

CLOSURE_VERDICT="$REPO_ROOT/reports/phase-${PHASE}-closure-verdict.md"
if [[ -f "$CLOSURE_VERDICT" ]] && ! closure_verdict_passes "$CLOSURE_VERDICT"; then
  echo "Error: Phase closure check did not pass." >&2
  echo "Check $CLOSURE_VERDICT for details." >&2
  exit 1
fi

echo ""
echo "Phase $PHASE is ready to finalize."
echo "  QA report:  $QA_REPORT"
echo "  Status:     $STATUS_FILE"
echo ""

if [[ "$AUTO_YES" == "true" ]]; then
  echo "Auto-release mode: skipping confirmation."
else
  read -r -p "Create a branch, commit, and open a PR? [y/N] " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# Write summary.json directly — guaranteed artifact regardless of agent behavior
python3 - <<PYEOF
import json, datetime, os
summary_file = "${SUMMARY_FILE}"
os.makedirs(os.path.dirname(summary_file), exist_ok=True)
now = datetime.datetime.utcnow().isoformat() + "Z"
data = {}
if os.path.exists(summary_file):
    try:
        with open(summary_file) as f:
            data = json.load(f)
    except Exception:
        pass
data.update({
    "phase": "${PHASE}",
    "status": "finalized",
    "qa_passed": True,
    "audit_passed": os.path.exists("${AUDIT_REPORT}"),
    "finalized_at": now,
    "artifacts": {
        "plan": "runs/${PHASE}/plan.md",
        "test_plan": "reports/qa/${PHASE}-test-plan.md",
        "review_report": "reports/reviews/${PHASE}-review.md",
        "qa_report": "reports/qa/${PHASE}-qa.md",
        "audit_report": "docs/handoffs/${PHASE}-audit.md",
        "status": "runs/${PHASE}/status.json",
        "implementation_summary": "reports/phase-${PHASE}-implementation-summary.md",
        "user_visible_changes": "reports/phase-${PHASE}-user-visible-changes.md",
        "ui_surface_map": "reports/phase-${PHASE}-ui-surface-map.md",
        "ui_test_plan": "reports/phase-${PHASE}-ui-test-plan.md",
        "ui_test_results": "reports/phase-${PHASE}-ui-test-results.md",
        "what_to_click": "reports/phase-${PHASE}-what-to-click.md",
        "closure_verdict": "reports/phase-${PHASE}-closure-verdict.md"
    }
})
with open(summary_file, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print("Summary written to: ${SUMMARY_FILE}")
PYEOF

# Check gh auth availability (non-fatal — determines if PR can be created)
GH_AUTH_AVAILABLE=false
if check_gh_auth; then
  GH_AUTH_AVAILABLE=true
  echo "gh auth: OK — PR will be created"
else
  echo "gh auth: not configured — commit will run but PR creation will be skipped"
  echo "  To enable PR creation later: gh auth login && ./scripts/automation/finalize-phase.sh $PHASE"
fi

cd "$REPO_ROOT"
claude_with_quota_retry -p "You are the release-manager agent for phased development.

Phase to finalize: $PHASE
QA report: $QA_REPORT
Status file: $STATUS_FILE
Summary file: $SUMMARY_FILE (already written — read it for PR body content)
CLAUDE.md: $REPO_ROOT/CLAUDE.md
Project template: .claude/project-template.md  <-- read for never-commit files
Agent instructions: .claude/agents/release-manager.md  <-- read this first

GH_AUTH_AVAILABLE: $GH_AUTH_AVAILABLE

Apply the TOKEN AND QUESTIONING POLICY from .claude/core.md strictly.

Perform the release flow:
1. Create branch: phase/$PHASE  (if not already on it)
2. Stage and commit all phase changes (read dev handoff for file list)
   Do NOT commit files listed in .claude/project-template.md never-commit section
3. Push branch to origin
4. If GH_AUTH_AVAILABLE is true: create PR with title: feat: $PHASE -- <one-line summary>
5. If GH_AUTH_AVAILABLE is false: skip PR creation, print a clear message showing the
   manual command the user can run once they authenticate: gh pr create ...
6. Report the PR URL (or the manual command if PR was skipped)"
