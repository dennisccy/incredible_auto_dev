#!/usr/bin/env bash
# dev-phase.sh — Run the developer agent for a phase
# Usage: ./scripts/automation/dev-phase.sh phase-3
#
# On the first run: implements the phase from the execution plan.
# On retry runs: reads any existing review/QA reports and fixes the issues found.
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
REVIEW_REPORT="$REPO_ROOT/reports/reviews/${PHASE}-review.md"
QA_REPORT="$REPO_ROOT/reports/qa/${PHASE}-qa.md"
AUDIT_REPORT="$REPO_ROOT/docs/handoffs/${PHASE}-audit.md"

echo "[dev-phase] Running developer agent for: $PHASE"

# ── Determine mode (initial build vs fix) ─────────────────────────────────
MODE_LABEL="INITIAL BUILD"
FIX_CONTEXT=""

if [[ -f "$REVIEW_REPORT" ]] && ! verdict_passes "$REVIEW_REPORT"; then
  MODE_LABEL="FIX MODE (review failed)"
  FIX_CONTEXT="
The review report below contains FAIL issues that must be fixed.
Do NOT rebuild from scratch -- fix only what is listed.

Review report path: $REVIEW_REPORT
"
fi

if [[ -f "$QA_REPORT" ]] && ! verdict_passes "$QA_REPORT"; then
  MODE_LABEL="FIX MODE (QA failed)"
  FIX_CONTEXT="$FIX_CONTEXT
The QA report below contains failures that must be fixed.
Do NOT rebuild from scratch -- fix only what is listed.

QA report path: $QA_REPORT
"
fi

if [[ -f "$AUDIT_REPORT" ]] && ! verdict_passes "$AUDIT_REPORT"; then
  MODE_LABEL="FIX MODE (audit failed)"
  FIX_CONTEXT="$FIX_CONTEXT
The audit report below contains issues that must be fixed.
Do NOT rebuild from scratch -- fix only what is listed.

Audit report path: $AUDIT_REPORT
"
fi

echo "[dev-phase] Mode: $MODE_LABEL"

# TOKEN-10 context diet: goal-mode full iterations hand the developer a sliced
# goal view (vision + anti-goals + target/failing journeys verbatim; stable
# passing journeys digested) — the agent body otherwise sends it to the whole
# goal.md, which grows with every proposer-promoted journey. Plain phases keep
# a plain goal line when docs/goal.md exists, else no line (as before).
GOAL_CONTEXT_LINE=""
if [[ "$PHASE" =~ ^goal-(.+)-iter-[0-9]+$ ]]; then
  _dev_targets="$(grep -iE 'Target journeys:' "$SPEC" 2>/dev/null | head -1 | grep -oE 'J-[0-9]+' | sort -u | tr '\n' ',' | sed 's/,$//' || true)"
  goal_slice_for_exec "$PHASE" "$_dev_targets" "$REPO_ROOT/runs/$PHASE/goal-slice-exec.md"
  if [[ "$GOAL_SLICE_EXEC_MODE" == "sliced" ]]; then
    GOAL_CONTEXT_LINE="Project goal (SLICED — vision, anti-goals, and this iteration's target + failing journeys verbatim; stable passing journeys digested to one line): $GOAL_SLICE_EXEC_PATH  <-- read Must-have user journeys and Anti-goals here
Full goal file: docs/goal.md — Read it ONLY if a digested journey becomes relevant to your work."
  else
    GOAL_CONTEXT_LINE="Project goal: docs/goal.md  <-- read Must-have user journeys and Anti-goals"
  fi
elif [[ -f "$REPO_ROOT/docs/goal.md" ]]; then
  GOAL_CONTEXT_LINE="Project goal: docs/goal.md  <-- read Must-have user journeys and Anti-goals"
fi

# ── Cleanup: kill any server processes started by the dev agent ──────────
# The dev agent may start uvicorn/next dev for verification.  These are
# long-running servers that block the agent from exiting if not cleaned up.
cleanup_dev_servers() {
  echo "[dev-phase] Cleaning up any leftover server processes..."
  local _be_port="${CHAIN_BACKEND_PORT:-8000}"
  local _fe_port="${CHAIN_FRONTEND_PORT:-3000}"
  # Kill uvicorn/next processes bound to this project's assigned ports only
  # (avoids killing neighbor projects running on different ports).
  pkill -f "uvicorn main:app.*--port ${_be_port}" 2>/dev/null || true
  pkill -f "next dev -p ${_fe_port}" 2>/dev/null || true
  pkill -f "next-server.*:${_fe_port}" 2>/dev/null || true
  fuser -k "${_be_port}/tcp" "${_fe_port}/tcp" 2>/dev/null || true
  sleep 2
}
trap cleanup_dev_servers EXIT

# ── Developer agent ──────────────────────────────────────────────────────
cd "$REPO_ROOT"
record_agent_invocation_start developer
_agent_t0="$CHAIN_AGENT_START_EPOCH"
_agent_rc=0
claude_with_quota_retry -p "You are the developer agent for phased development.

Phase: $PHASE
Phase spec: $SPEC
$GOAL_CONTEXT_LINE
Project template: .claude/project-template.md  <-- read this for stack info, test commands, architecture rules
Agent instructions: .claude/agents/developer.md  <-- read this first
(CLAUDE.md is already in your system prompt — do not Read it again.)

Execution plan: $PLAN_FILE  <-- read this to understand what to build
$FIX_CONTEXT
Mode: $MODE_LABEL

When complete:
- Write dev handoff to: docs/handoffs/${PHASE}-dev.md
- If frontend work was done, also write: docs/handoffs/${PHASE}-frontend.md
- Also write: reports/phase-${PHASE}-implementation-summary.md
  Use the template at templates/implementation-summary.md.
  Include: features implemented, changed behavior, backend-only items, incomplete items, config/env changes, known limitations.
  This report is for operators, not developers — write in plain language, not code.
- Update runs/${PHASE}/status.json with current_step: dev_complete" || _agent_rc=$?
record_agent_invocation_end developer "$_agent_t0" "$_agent_rc"
(( _agent_rc == 0 )) || exit "$_agent_rc"

echo "[dev-phase] Done."
