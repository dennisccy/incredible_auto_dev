#!/usr/bin/env bash
# ui-impact-phase.sh — Run the UI impact analyst for a phase
# Usage: ./scripts/automation/ui-impact-phase.sh phase-3
#
# Analyzes what the phase implementation changed from a user's perspective.
# Maps code changes to UI surfaces. Produces user-visible-changes and ui-surface-map reports.
# Runs after dev+review passes.
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
DEV_HANDOFF="$REPO_ROOT/docs/handoffs/${PHASE}-dev.md"
FRONTEND_HANDOFF="$REPO_ROOT/docs/handoffs/${PHASE}-frontend.md"
IMPL_SUMMARY="$REPO_ROOT/reports/phase-${PHASE}-implementation-summary.md"
USER_VISIBLE="$REPO_ROOT/reports/phase-${PHASE}-user-visible-changes.md"
UI_SURFACE_MAP="$REPO_ROOT/reports/phase-${PHASE}-ui-surface-map.md"

echo "[ui-impact] Running UI impact analysis for: $PHASE"

# Detect if this phase has frontend
FRONTEND_PRESENT="no"
if detect_frontend_in_plan "$PLAN_FILE"; then
  FRONTEND_PRESENT="yes"
fi

echo "[ui-impact] Frontend present: $FRONTEND_PRESENT"

# For backend-only phases, write N/A stubs and skip agent invocation
if [[ "$FRONTEND_PRESENT" == "no" ]]; then
  echo "[ui-impact] Backend-only phase — writing N/A stubs."
  write_na_ui_artifacts "$PHASE" "user-visible-changes" "ui-surface-map"
  echo "[ui-impact] Done (backend-only, N/A stubs written)."
  exit 0
fi

# Build optional handoff context
FRONTEND_HANDOFF_NOTE=""
if [[ -f "$FRONTEND_HANDOFF" ]]; then
  FRONTEND_HANDOFF_NOTE="Frontend handoff: $FRONTEND_HANDOFF"
fi

IMPL_SUMMARY_NOTE=""
if [[ -f "$IMPL_SUMMARY" ]]; then
  IMPL_SUMMARY_NOTE="Implementation summary: $IMPL_SUMMARY  <-- read this for context on what was built"
fi

cd "$REPO_ROOT"
claude_with_quota_retry -p "You are the ui-impact-analyst for phased development.

Phase: $PHASE
Phase spec: $SPEC
CLAUDE.md: $REPO_ROOT/CLAUDE.md
Agent instructions: .claude/agents/ui-impact-analyst.md  <-- read this first
Skills to use:
  - .claude/skills/diff-to-ui-impact.md
  - .claude/skills/visible-change-summarizer.md

Execution plan: $PLAN_FILE
Dev handoff: $DEV_HANDOFF  <-- read to understand what was built
$FRONTEND_HANDOFF_NOTE
$IMPL_SUMMARY_NOTE

Frontend Present: $FRONTEND_PRESENT

Your job:
1. Read the agent instructions and skills above
2. Identify all changed files from the dev handoff
3. Classify each file's UI impact using diff-to-ui-impact skill
4. Map code changes to user-visible UI surfaces
5. Identify what users can now do vs what is backend-only

Write these two reports:
  - $USER_VISIBLE
  - $UI_SURFACE_MAP

Use the templates at templates/user-visible-changes.md and templates/ui-surface-map.md.

Every entry in the surface map MUST have a specific 'What to Test' action (not vague phrases like 'verify it works').

Then STOP."

echo "[ui-impact] Done. Reports:"
echo "  User-visible changes: $USER_VISIBLE"
echo "  UI surface map:       $UI_SURFACE_MAP"
