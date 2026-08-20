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
# Telemetry (no-op unless GOAL_SESSION_DIR is set, i.e. goal-mode full depth):
# lets claude_with_quota_retry forward each dispatch's usage sidecar into the
# session's per-agent economics (TOKEN-8).
source "$SCRIPT_DIR/lib/telemetry.sh"

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

# SPEED-24 combined mode (goal-mode fulls; armed by run-phase.sh's Branch-A
# via CHAIN_UI_COMBINED_DISPATCH=1): the same dispatch ALSO writes the UI test
# plan + what-to-click guide — the designer's inputs are exactly this
# analyst's outputs, so a second dispatch buys a fresh context, not a second
# opinion. Same artifact names/templates/skills as ui-test-design-phase.sh.
# Under-delivery is safe: the failure/post-condition stubs below cover ONLY
# the two impact artifacts, so a missing plan/click leaves those files absent
# and Branch-A falls back to the separate designer dispatch loudly.
COMBINED_NOTE=""
COMBINED_JOB=""
if [[ "${CHAIN_UI_COMBINED_DISPATCH:-}" == "1" ]]; then
  UI_TEST_PLAN="$REPO_ROOT/reports/phase-${PHASE}-ui-test-plan.md"
  WHAT_TO_CLICK="$REPO_ROOT/reports/phase-${PHASE}-what-to-click.md"
  EXISTING_TEST_PLAN="$REPO_ROOT/reports/qa/${PHASE}-test-plan.md"
  _FRONTEND_PORT="${CHAIN_FRONTEND_PORT:-3000}"
  FRONTEND_URL="${CHAIN_FRONTEND_URL:-http://localhost:${_FRONTEND_PORT}}"
  _existing_tp_note=""
  [[ -f "$EXISTING_TEST_PLAN" ]] && _existing_tp_note="Existing functional test plan: $EXISTING_TEST_PLAN  <-- read for context, do not duplicate API tests"
  echo "[ui-impact] SPEED-24 combined mode: this dispatch also writes the UI test plan + what-to-click guide (CHAIN_UI_COMBINED=false disables)."
  COMBINED_NOTE="COMBINED MODE (SPEED-24) — follow the '## Combined mode' section of your agent instructions.
Additional skills for the combined deliverables:
  - .claude/skills/manual-ui-test-plan-generator.md
  - .claude/skills/what-to-click-writer.md
${_existing_tp_note}
Frontend URL: $FRONTEND_URL"
  COMBINED_JOB="6. COMBINED MODE: from your just-written surface map, create test cases per surface (smoke, happy-path, validation, error, regression, UX) with exact steps (specific URLs, button text, field names, expected outcomes) and the 5-minute operator verification guide (max 10 steps), then ALSO write:
  - $UI_TEST_PLAN  (use template: templates/ui-test-plan.md)
  - $WHAT_TO_CLICK  (use template: templates/what-to-click.md)
Every step must be independently executable. No vague steps like 'test the form' or 'verify it works'."
fi

cd "$REPO_ROOT"
record_agent_invocation_start ui-impact-analyst
_agent_t0="$CHAIN_AGENT_START_EPOCH"
_ui_rc=0
claude_with_quota_retry -p "You are the ui-impact-analyst for phased development.

Phase: $PHASE
Phase spec: $SPEC
Agent instructions: .claude/agents/ui-impact-analyst.md  <-- read this first
(CLAUDE.md is already in your system prompt — do not Read it again.)
Skills to use:
  - .claude/skills/diff-to-ui-impact.md
  - .claude/skills/visible-change-summarizer.md
  - .claude/skills/ui-workflow-inference.md

Execution plan: $PLAN_FILE
Dev handoff: $DEV_HANDOFF  <-- read to understand what was built
$FRONTEND_HANDOFF_NOTE
$IMPL_SUMMARY_NOTE
$COMBINED_NOTE

Frontend Present: $FRONTEND_PRESENT

Your job:
1. Read the agent instructions and skills above
2. Identify all changed files from the dev handoff
3. Classify each file's UI impact using diff-to-ui-impact skill
4. Map code changes to user-visible UI surfaces
5. Identify what users can now do vs what is backend-only
$COMBINED_JOB

Write these two reports:
  - $USER_VISIBLE
  - $UI_SURFACE_MAP

Use the templates at templates/user-visible-changes.md and templates/ui-surface-map.md.

Every entry in the surface map MUST have a specific 'What to Test' action (not vague phrases like 'verify it works').

Then STOP." || _ui_rc=$?
record_agent_invocation_end ui-impact-analyst "$_agent_t0" "$_ui_rc"

# Fall back to SKIPPED stubs if the agent exited without writing its artifacts
# (commonly due to a transient Anthropic streaming error). Quota exit (75) is
# propagated unchanged so the outer run-phase.sh retry loop triggers.
if [[ $_ui_rc -ne 0 && $_ui_rc -ne ${QUOTA_EXHAUSTED_EXIT_CODE:-75} ]]; then
  _reason="ui-impact-phase.sh Claude CLI exited with code $_ui_rc without writing the expected report(s). Re-run \`./scripts/automation/ui-impact-phase.sh $PHASE\` once the transient condition has cleared."
  write_failed_artifact_stub "$PHASE" "user-visible-changes" "$_reason"
  write_failed_artifact_stub "$PHASE" "ui-surface-map"       "$_reason"
  exit "$_ui_rc"
fi

# rc==0 post-condition: an agent can return 0 without ever writing its reports.
# Do NOT print a phantom "Done." in that case — the next stage (ui-test-design)
# would then abort on a missing file. Assert both artifacts exist and are
# non-empty; if not, write SKIPPED stubs and fail loudly at the source.
if [[ ! -s "$USER_VISIBLE" || ! -s "$UI_SURFACE_MAP" ]]; then
  _reason="ui-impact-phase.sh: the ui-impact-analyst agent exited 0 but did not write a non-empty user-visible-changes and/or ui-surface-map report. Re-run \`./scripts/automation/ui-impact-phase.sh $PHASE\`."
  # REL-11: the SKIPPED stub keeps the pipeline fed but reads as a quiet skip;
  # this emits the loud banner + missing_evidence telemetry alongside it.
  warn_missing_evidence "ui-impact-analyst" "$USER_VISIBLE"
  write_failed_artifact_stub "$PHASE" "user-visible-changes" "$_reason"
  write_failed_artifact_stub "$PHASE" "ui-surface-map"       "$_reason"
  echo "[ui-impact] ERROR: agent returned success but expected report(s) are missing/empty — wrote SKIPPED stubs and failing." >&2
  exit 1
fi

echo "[ui-impact] Done. Reports:"
echo "  User-visible changes: $USER_VISIBLE"
echo "  UI surface map:       $UI_SURFACE_MAP"
