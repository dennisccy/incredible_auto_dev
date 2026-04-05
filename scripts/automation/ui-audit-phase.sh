#!/usr/bin/env bash
# ui-audit-phase.sh — Run a standalone UI evolution audit for a completed phase
# Usage: ./scripts/automation/ui-audit-phase.sh phase-8
#
# Invokes the qa agent with a focused UI-audit-only prompt.
# Reads runs/<phase>/plan.md and reports/qa/<phase>-qa.md for context.
# Writes the audit result to reports/qa/<phase>-ui-audit.md.
#
# Can be run retroactively on any previously completed phase to assess
# whether the UI adequately reflects the phase's backend capabilities.
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
QA_REPORT="$REPO_ROOT/reports/qa/${PHASE}-qa.md"
UI_AUDIT_REPORT="$REPO_ROOT/reports/qa/${PHASE}-ui-audit.md"

echo "[ui-audit] Running UI evolution audit for: $PHASE"

if [[ ! -f "$PLAN_FILE" ]]; then
  echo "Error: Plan file not found at $PLAN_FILE" >&2
  echo "Tip: Run './scripts/automation/run-phase.sh $PHASE' first to generate a plan." >&2
  exit 1
fi

# Detect if this is a frontend phase
if ! grep -qi "frontend present: yes" "$PLAN_FILE" 2>/dev/null; then
  echo "[ui-audit] Frontend Present: no — this is a backend-only phase."
  echo "[ui-audit] Writing SKIPPED audit to $UI_AUDIT_REPORT"
  mkdir -p "$(dirname "$UI_AUDIT_REPORT")"
  cat > "$UI_AUDIT_REPORT" <<EOF
## UI Evolution Audit — ${PHASE}

**Verdict:** UI-SKIPPED

Backend-only phase (Frontend Present: no in plan.md). No UI evolution audit required.
EOF
  echo "[ui-audit] Done (SKIPPED — backend-only phase)."
  exit 0
fi

echo "[ui-audit] Frontend phase detected — running full UI evolution audit..."

# Determine frontend URL
_FRONTEND_PORT="${CHAIN_FRONTEND_PORT:-3000}"
FRONTEND_URL="${CHAIN_FRONTEND_URL:-http://localhost:${_FRONTEND_PORT}}"

cd "$REPO_ROOT"
claude_with_quota_retry -p "You are the qa agent for phased development.

Your task is a FOCUSED UI EVOLUTION AUDIT ONLY for phase: $PHASE

Phase spec: $SPEC
Plan: $PLAN_FILE
Existing QA report (if any): $QA_REPORT
UI EVOLUTION POLICY is defined in: .claude/workflow.md

## Your job

Evaluate whether the UI meaningfully evolved for this phase by answering:

1. Did the UI evolve to reflect the phase's new capability?
2. Can the user now see, understand, and control the new capability from the UI?
3. Is the UI still relying on old generic pages for new functionality?
4. Is the implementation technically complete but product-wise underexposed?

Read the phase spec to understand what capability was added. Read the relevant frontend
files to assess what UI surfaces exist.

If the frontend is running (check $FRONTEND_URL), use Chrome MCP to verify
the key user-facing flows. If not running, assess from code only.

## Output

Assign one of these verdicts:
- **UI-PASS**: UI meaningfully reflects the new capability
- **UI-PASS-WITH-GAPS**: UI works but has notable gaps (list each)
- **UI-FAIL**: Backend capability is not adequately reflected in the UI

Write the audit report to: $UI_AUDIT_REPORT

Use this format:
\`\`\`
## UI Evolution Audit — ${PHASE}

**Verdict:** UI-PASS | UI-PASS-WITH-GAPS | UI-FAIL

### Questions answered
1. Did the UI evolve to reflect the phase's new capability? <answer>
2. Can the user see/understand/control the new capability? <answer>
3. Is the UI still relying on old generic pages? <answer>
4. Is the implementation underexposed product-wise? <answer>

### Gaps (if any)
- <gap description>

### Recommendation
<action or none>
\`\`\`

Keep the report focused and actionable. Then STOP."

echo ""
echo "[ui-audit] ====================================="
echo "[ui-audit] Audit complete. Report: $UI_AUDIT_REPORT"

if [[ -f "$UI_AUDIT_REPORT" ]]; then
  VERDICT=$(grep -m1 "^\*\*Verdict:\*\*" "$UI_AUDIT_REPORT" 2>/dev/null || echo "")
  if [[ -n "$VERDICT" ]]; then
    echo "[ui-audit] $VERDICT"
  fi
fi
echo "[ui-audit] ====================================="
