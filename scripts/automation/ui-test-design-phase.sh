#!/usr/bin/env bash
# ui-test-design-phase.sh — Run the UI test designer for a phase
# Usage: ./scripts/automation/ui-test-design-phase.sh phase-3
#
# Converts UI impact analysis into a practical test plan and 5-minute operator guide.
# Runs after ui-impact-phase.sh completes.
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
USER_VISIBLE="$REPO_ROOT/reports/phase-${PHASE}-user-visible-changes.md"
UI_SURFACE_MAP="$REPO_ROOT/reports/phase-${PHASE}-ui-surface-map.md"
UI_TEST_PLAN="$REPO_ROOT/reports/phase-${PHASE}-ui-test-plan.md"
WHAT_TO_CLICK="$REPO_ROOT/reports/phase-${PHASE}-what-to-click.md"
EXISTING_TEST_PLAN="$REPO_ROOT/reports/qa/${PHASE}-test-plan.md"

echo "[ui-test-design] Running UI test design for: $PHASE"

# Detect frontend
FRONTEND_PRESENT="no"
if detect_frontend_in_plan "$PLAN_FILE"; then
  FRONTEND_PRESENT="yes"
fi

# Skip for backend-only phases
if [[ "$FRONTEND_PRESENT" == "no" ]]; then
  echo "[ui-test-design] Backend-only phase — writing N/A stubs."
  write_na_ui_artifacts "$PHASE" "ui-test-plan" "what-to-click"
  echo "[ui-test-design] Done (backend-only, N/A stubs written)."
  exit 0
fi

# Verify dependencies
if [[ ! -f "$USER_VISIBLE" ]]; then
  echo "Error: User-visible-changes report not found at $USER_VISIBLE" >&2
  echo "Run ./scripts/automation/ui-impact-phase.sh $PHASE first." >&2
  exit 1
fi

if [[ ! -f "$UI_SURFACE_MAP" ]]; then
  echo "Error: UI surface map not found at $UI_SURFACE_MAP" >&2
  echo "Run ./scripts/automation/ui-impact-phase.sh $PHASE first." >&2
  exit 1
fi

EXISTING_TEST_PLAN_NOTE=""
if [[ -f "$EXISTING_TEST_PLAN" ]]; then
  EXISTING_TEST_PLAN_NOTE="Existing functional test plan: $EXISTING_TEST_PLAN  <-- read for context, do not duplicate API tests"
fi

_FRONTEND_PORT="${CHAIN_FRONTEND_PORT:-3000}"
FRONTEND_URL="${CHAIN_FRONTEND_URL:-http://localhost:${_FRONTEND_PORT}}"

cd "$REPO_ROOT"
claude_with_quota_retry -p "You are the ui-test-designer for phased development.

Phase: $PHASE
Phase spec: $SPEC
CLAUDE.md: $REPO_ROOT/CLAUDE.md
Agent instructions: .claude/agents/ui-test-designer.md  <-- read this first
Skills to use:
  - .claude/skills/manual-ui-test-plan-generator.md
  - .claude/skills/what-to-click-writer.md

Execution plan: $PLAN_FILE
User-visible changes: $USER_VISIBLE  <-- read this first
UI surface map: $UI_SURFACE_MAP  <-- read this for surfaces to test
$EXISTING_TEST_PLAN_NOTE

Frontend URL: $FRONTEND_URL

Your job:
1. Read the agent instructions and skills above
2. For each surface in the UI surface map, create test cases (smoke, happy-path, validation, error, regression, UX)
3. Each test case must have exact steps with specific URLs, button text, field names, and expected outcomes
4. Write the 5-minute operator verification guide (max 10 steps)

Write these two reports:
  - $UI_TEST_PLAN  (use template: templates/ui-test-plan.md)
  - $WHAT_TO_CLICK  (use template: templates/what-to-click.md)

Every step must be independently executable. No vague steps like 'test the form' or 'verify it works'.

Then STOP."

echo "[ui-test-design] Done. Reports:"
echo "  UI test plan:  $UI_TEST_PLAN"
echo "  What to click: $WHAT_TO_CLICK"
