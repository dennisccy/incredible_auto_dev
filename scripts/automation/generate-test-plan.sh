#!/usr/bin/env bash
# generate-test-plan.sh — Generate a functional test plan for a phase from its spec
# Usage: ./scripts/automation/generate-test-plan.sh phase-3
#
# Reads the phase spec and execution plan, then invokes the qa agent (test-plan mode)
# to produce a structured, user-facing test plan at:
#   reports/qa/<phase>-test-plan.md
#
# This runs before QA so the qa agent can execute the plan step by step.
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
TEST_PLAN="$REPO_ROOT/reports/qa/${PHASE}-test-plan.md"

# Detect frontend presence from plan
FRONTEND_PRESENT="no"
if [[ -f "$PLAN_FILE" ]] && grep -qi "frontend present: yes" "$PLAN_FILE"; then
  FRONTEND_PRESENT="yes"
fi

echo "[generate-test-plan] Generating test plan for: $PHASE (frontend: $FRONTEND_PRESENT)"

mkdir -p "$REPO_ROOT/reports/qa"

cd "$REPO_ROOT"
claude_with_quota_retry -p "You are the qa agent operating in TEST PLAN GENERATION mode for phased development.

Phase: $PHASE
Phase spec: $SPEC
Execution plan: $PLAN_FILE
Agent instructions: .claude/agents/qa.md  <-- read this first, follow MODE 1 instructions

Frontend Present for this phase: $FRONTEND_PRESENT

Apply the TOKEN AND QUESTIONING POLICY from .claude/core.md strictly.
Do not ask questions — derive all test cases from the phase spec.

Write the functional test plan to: $TEST_PLAN

The plan must include:
- Phase goal summary
- Numbered test cases (TC-01, TC-02, ...)
- For each test case: type, preconditions, steps, expected outcome, pass criteria
- A summary of total test cases by type

Keep it concise (1-3 pages). Write the plan and STOP."

if [[ ! -f "$TEST_PLAN" ]]; then
  echo "[generate-test-plan] Warning: agent did not write test plan file." >&2
  exit 1
fi

echo "[generate-test-plan] Done. Test plan: $TEST_PLAN"
