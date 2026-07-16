#!/usr/bin/env bash
# review-phase.sh — Run the reviewer agent against a completed dev handoff
# Usage: ./scripts/automation/review-phase.sh phase-3
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

# TOKEN-7: pre-baked review packet — built fresh before EVERY dispatch of this
# script (run-phase.sh re-invokes it per review round: Step 3 attempts, Step 7
# fix-mode, Step 9 hardening), so a re-review never reads a stale packet. A
# build failure degrades LOUDLY to the hint-only dispatch (the prompt's packet
# line says "if present") and removes any stale file — absent beats stale.
REVIEW_PACKET="$REPO_ROOT/runs/${PHASE}/review-packet.md"
if build_review_packet "$REVIEW_PACKET" HEAD; then
  echo "[review-phase] review packet built: $REVIEW_PACKET (base HEAD)"
else
  echo "[review-phase] review packet build failed — removing any stale packet; the reviewer degrades to the diff-hint commands." >&2
  rm -f "$REVIEW_PACKET" 2>/dev/null || true
fi

export CHAIN_CURRENT_AGENT=reviewer
claude_with_quota_retry -p "You are the reviewer agent for phased development.

Phase: $PHASE
Phase spec: $SPEC
Dev handoff: $HANDOFF
Execution plan: $PLAN_FILE
Project template (relevant sections, pre-sliced):
\`\`\`\`
$(project_template_slice reviewer)
\`\`\`\`
Agent instructions: .claude/agents/reviewer.md  <-- read this first
(CLAUDE.md is already in your system prompt — do not Read it again.)

Read the phase spec, the dev handoff, and each changed file listed in the handoff.
Bounded diff packet (read FIRST if present): $REVIEW_PACKET — hunks capped, noise excluded, truncations NAMED. The phase spec + dev handoff remain required reading — never verdict from the diff alone (D7).
Run these only for files the packet marks truncated or excluded (or if the packet file is absent):
$(review_diff_hint HEAD)

Apply the TOKEN AND QUESTIONING POLICY from .claude/core.md strictly.

Write your review report to: reports/reviews/${PHASE}-review.md

The report MUST start with a line matching exactly:
**Verdict:** PASS
  or
**Verdict:** PASS_WITH_NOTES
  or
**Verdict:** FAIL"

echo "[review-phase] Done. Report: reports/reviews/${PHASE}-review.md"
