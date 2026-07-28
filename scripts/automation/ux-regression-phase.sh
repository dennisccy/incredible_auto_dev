#!/usr/bin/env bash
# ux-regression-phase.sh — Run UX regression review for a phase
# Usage: ./scripts/automation/ux-regression-phase.sh phase-3
#
# Checks whether new capabilities are discoverable and whether existing
# user journeys may have regressed. Runs after browser QA.
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
USER_VISIBLE="$REPO_ROOT/reports/phase-${PHASE}-user-visible-changes.md"
UI_SURFACE_MAP="$REPO_ROOT/reports/phase-${PHASE}-ui-surface-map.md"
UI_TEST_RESULTS="$REPO_ROOT/reports/phase-${PHASE}-ui-test-results.md"
UX_REGRESSION="$REPO_ROOT/reports/phase-${PHASE}-ux-regression.md"

echo "[ux-regression] Running UX regression review for: $PHASE"

# Detect frontend
FRONTEND_PRESENT="no"
if detect_frontend_in_plan "$PLAN_FILE"; then
  FRONTEND_PRESENT="yes"
fi

# Skip for backend-only phases
if [[ "$FRONTEND_PRESENT" == "no" ]]; then
  echo "[ux-regression] Backend-only phase — writing minimal report."
  mkdir -p "$(dirname "$UX_REGRESSION")"
  cat > "$UX_REGRESSION" <<EOF
# Phase ${PHASE} — UX Regression Review

**Date:** $(date +%Y-%m-%d)

**Verdict:** UX-REGRESSION-PASS

Backend-only phase (Frontend Present: no). No UX regression review required.
EOF
  echo "[ux-regression] Done (backend-only, N/A report written)."
  exit 0
fi

_FRONTEND_PORT="${CHAIN_FRONTEND_PORT:-3000}"
FRONTEND_URL="${CHAIN_FRONTEND_URL:-http://localhost:${_FRONTEND_PORT}}"

cd "$REPO_ROOT"
record_agent_invocation_start ux-regression-reviewer
_agent_t0="$CHAIN_AGENT_START_EPOCH"
_agent_rc=0
claude_with_quota_retry -p "You are the ux-regression-reviewer for phased development.

Phase: $PHASE
Phase spec: $SPEC
Agent instructions: .claude/agents/ux-regression-reviewer.md  <-- read this first
(CLAUDE.md is already in your system prompt — do not Read it again.)
Skill: .claude/skills/ui-regression-scout.md

Execution plan: $PLAN_FILE
User-visible changes: $USER_VISIBLE
UI surface map: $UI_SURFACE_MAP
Browser QA results: $UI_TEST_RESULTS (if exists)
Prior phase handoffs: docs/handoffs/ directory  <-- scan for prior phases

Frontend URL: $FRONTEND_URL

Your job:
1. Check discoverability: can users find new capabilities within 2 clicks from home?
2. Check regressions: do current changes touch components used by prior phase features?
3. Check UI vs backend parity: are all backend capabilities surfaced in the UI?
4. Flag hidden/undiscoverable capabilities, potential regressions, and UI vs backend gaps

Write your report to: $UX_REGRESSION

Verdict must be one of:
  **Verdict:** UX-REGRESSION-PASS
  **Verdict:** UX-REGRESSION-WARN
  **Verdict:** UX-REGRESSION-FAIL

Then STOP." || _agent_rc=$?
record_agent_invocation_end ux-regression-reviewer "$_agent_t0" "$_agent_rc"
(( _agent_rc == 0 )) || exit "$_agent_rc"

echo "[ux-regression] Done. Report: $UX_REGRESSION"
if [[ -f "$UX_REGRESSION" ]]; then
  VERDICT=$(grep -m1 "^\*\*Verdict:\*\*" "$UX_REGRESSION" 2>/dev/null || echo "")
  [[ -n "$VERDICT" ]] && echo "[ux-regression] $VERDICT"
fi
