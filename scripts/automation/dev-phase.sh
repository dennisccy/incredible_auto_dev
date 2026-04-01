#!/usr/bin/env bash
# dev-phase.sh — Run the developer agent for a phase
# Usage: ./scripts/automation/dev-phase.sh phase-3
#
# On the first run: implements the phase from the execution plan.
# On retry runs: reads any existing review/QA reports and fixes the issues found.
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

# ── Developer agent ──────────────────────────────────────────────────────
cd "$REPO_ROOT"
claude_with_quota_retry -p "You are the developer agent for phased development.

Phase: $PHASE
Phase spec: $SPEC
CLAUDE.md: $REPO_ROOT/CLAUDE.md
Project template: .claude/project-template.md  <-- read this for stack info, test commands, architecture rules
Agent instructions: .claude/agents/developer.md  <-- read this first

Execution plan: $PLAN_FILE  <-- read this to understand what to build
$FIX_CONTEXT
Mode: $MODE_LABEL

Apply the TOKEN AND QUESTIONING POLICY from .claude/core.md strictly.

When complete:
- Write dev handoff to: docs/handoffs/${PHASE}-dev.md
- If frontend work was done, also write: docs/handoffs/${PHASE}-frontend.md
- Also write: reports/phase-${PHASE}-implementation-summary.md
  Use the template at templates/implementation-summary.md.
  Include: features implemented, changed behavior, backend-only items, incomplete items, config/env changes, known limitations.
  This report is for operators, not developers — write in plain language, not code.
- Update runs/${PHASE}/status.json with current_step: dev_complete"

echo "[dev-phase] Done."
