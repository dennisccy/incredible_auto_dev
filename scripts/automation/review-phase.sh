#!/usr/bin/env bash
# review-phase.sh — Run the reviewer agent against a completed dev handoff
# Usage: ./scripts/automation/review-phase.sh phase-3
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

PHASE="${1:-}"
require_phase_arg "$PHASE"
require_claude

HANDOFF="$REPO_ROOT/docs/handoffs/${PHASE}-dev.md"
if [[ ! -f "$HANDOFF" ]]; then
  echo "Error: Dev handoff not found at $HANDOFF" >&2
  echo "Run ./scripts/automation/dev-phase.sh $PHASE first." >&2
  exit 1
fi

SPEC=$(phase_spec_path "$PHASE")
PLAN_FILE="$REPO_ROOT/runs/${PHASE}/plan.md"

echo "[review-phase] Reviewing: $PHASE"

cd "$REPO_ROOT"
claude_with_quota_retry -p "You are the reviewer agent for phased development.

Phase: $PHASE
Phase spec: $SPEC
Dev handoff: $HANDOFF
Execution plan: $PLAN_FILE
CLAUDE.md: $REPO_ROOT/CLAUDE.md
Project template: .claude/project-template.md  <-- read this for project-specific architecture rules
Agent instructions: .claude/agents/reviewer.md  <-- read this first

Read CLAUDE.md, project-template.md, the phase spec, the dev handoff, and each changed file listed in the handoff.
Run: git diff HEAD to see what changed.

Apply the TOKEN AND QUESTIONING POLICY from .claude/core.md strictly.

Write your review report to: reports/reviews/${PHASE}-review.md

The report MUST start with a line matching exactly:
**Verdict:** PASS
  or
**Verdict:** PASS_WITH_NOTES
  or
**Verdict:** FAIL"

echo "[review-phase] Done. Report: reports/reviews/${PHASE}-review.md"
