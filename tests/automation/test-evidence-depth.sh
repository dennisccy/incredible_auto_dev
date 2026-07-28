#!/usr/bin/env bash
# test-evidence-depth.sh — SPEED-9 unit test: the 'evidence' depth micro-path
# (capture + evaluate only; no developer/reviewer) and the lean demo-ordering
# fix (in evidence mode the walkthrough records BEFORE the evaluator reads —
# the desk-session iter-12 ESCALATE was a lean spec whose deliverable was a
# recording the post-eval showcase ordering could never surface).
#
# Sourceable logic tested directly:
#   goal_lean_streak (lib/common.sh) — 'evidence' dispatches continue the lean
#   streak (they run no audit either), 'full' still breaks it.
# Engine wiring is grep-asserted (the dispatch itself needs a live backend).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

source "$ENGINE_ROOT/scripts/automation/lib/common.sh"

# ── goal_lean_streak with evidence dispatches ────────────────────────────────
SDIR="$WORK/goal-session-x"
seed_depths() {
  rm -rf "$SDIR"; mkdir -p "$SDIR"
  local i=1 v
  for v in "$@"; do
    mkdir -p "$SDIR/iter-$i"
    [[ "$v" != "-" ]] && printf '%s' "$v" > "$SDIR/iter-$i/depth-dispatched"
    i=$((i + 1))
  done
}

seed_depths lean evidence lean lean
val=$(goal_lean_streak "$SDIR" 5 2>/dev/null || true)
[[ "$val" == "4" ]] \
  && assert "streak: evidence continues the lean streak -> 4" "pass" \
  || assert "streak: evidence continues the lean streak -> 4 (got '$val')" "fail"

seed_depths evidence evidence full lean
val=$(goal_lean_streak "$SDIR" 5 2>/dev/null || true)
[[ "$val" == "1" ]] \
  && assert "streak: full still breaks the streak -> 1" "pass" \
  || assert "streak: full still breaks the streak -> 1 (got '$val')" "fail"

# ── run-goal.sh wiring ───────────────────────────────────────────────────────
RG="$ENGINE_ROOT/scripts/automation/run-goal.sh"
grep -q 'CHAIN_EVIDENCE_MICRO_PATH=false — dispatching as lean' "$RG" \
  && assert "wiring: knob off maps evidence depth back to lean" "pass" \
  || assert "wiring: knob off maps evidence depth back to lean" "fail"
grep -q '"\$DEPTH" != "lean" && "\$DEPTH" != "full" && "\$DEPTH" != "evidence"' "$RG" \
  && assert "wiring: depth parse accepts the evidence token" "pass" \
  || assert "wiring: depth parse accepts the evidence token" "fail"
grep -q 'depth_evidence_override' "$RG" \
  && assert "wiring: lean→evidence backstop records telemetry" "pass" \
  || assert "wiring: lean→evidence backstop records telemetry" "fail"
grep -q 'CHAIN_LEAN_EVIDENCE_ONLY=true bash "\$SCRIPT_DIR/goal-iter-lean.sh"' "$RG" \
  && assert "wiring: evidence dispatch branch exports the mode to the executor" "pass" \
  || assert "wiring: evidence dispatch branch exports the mode to the executor" "fail"
grep -q "printf 'evidence' > \"\$ITER_DIR/depth-dispatched\"" "$RG" \
  && assert "wiring: evidence dispatch writes depth-dispatched (cadence input)" "pass" \
  || assert "wiring: evidence dispatch writes depth-dispatched (cadence input)" "fail"
grep -q 'Prior walkthrough recording' "$RG" \
  && assert "wiring: evaluator prompt carries the prior-recording line" "pass" \
  || assert "wiring: evaluator prompt carries the prior-recording line" "fail"
grep -q 'Product diff this iteration (deterministic' "$RG" \
  && assert "wiring: evaluator prompt carries the product-diff status line" "pass" \
  || assert "wiring: evaluator prompt carries the product-diff status line" "fail"
grep -q '"\$NEXT_DEPTH" != "evidence"' "$RG" \
  && assert "wiring: evaluator Depth Recommendation accepts evidence" "pass" \
  || assert "wiring: evaluator Depth Recommendation accepts evidence" "fail"

# ── goal-iter-lean.sh wiring ─────────────────────────────────────────────────
LEAN="$ENGINE_ROOT/scripts/automation/goal-iter-lean.sh"
grep -q 'EVIDENCE mode: skipping developer' "$LEAN" \
  && assert "wiring: evidence mode skips the developer with a stub handoff" "pass" \
  || assert "wiring: evidence mode skips the developer with a stub handoff" "fail"
grep -q 'EVIDENCE mode: skipping reviewer' "$LEAN" \
  && assert "wiring: evidence mode skips the reviewer with a stub report" "pass" \
  || assert "wiring: evidence mode skips the reviewer with a stub report" "fail"
grep -q '_BQA_OFF_REASON="evidence-mode"' "$LEAN" \
  && assert "wiring: evidence mode forces the parallel browser-qa fork off" "pass" \
  || assert "wiring: evidence mode forces the parallel browser-qa fork off" "fail"
grep -q 'CHAIN_LEAN_EVIDENCE_ONLY.*== "true" ]] || _build_review_packet_or_degrade' "$LEAN" \
  && assert "wiring: evidence mode skips the review packet build" "pass" \
  || assert "wiring: evidence mode skips the review packet build" "fail"

# Ordering (the iter-12 fix): the evidence-mode demo record must sit AFTER the
# coherence join and BEFORE the final Done line — i.e., inside the executor,
# pre-evaluation — not in the post-eval showcase tail.
demo_line=$(grep -n 'EVIDENCE mode: recording the walkthrough BEFORE evaluation' "$LEAN" | head -1 | cut -d: -f1 || echo 0)
join_line=$(grep -n 'Coherence audit join' "$LEAN" | head -1 | cut -d: -f1 || echo 0)
done_line=$(grep -n 'Done. Iteration artifacts' "$LEAN" | head -1 | cut -d: -f1 || echo 0)
if [[ "$demo_line" -gt "$join_line" && "$demo_line" -lt "$done_line" && "$join_line" -gt 0 ]]; then
  assert "ordering: evidence demo records after coherence join, before return (pre-evaluator)" "pass"
else
  assert "ordering: evidence demo records after coherence join, before return (got demo=$demo_line join=$join_line done=$done_line)" "fail"
fi

# The showcase tail must not re-record for evidence depth (it records only for
# depth == lean; evidence recorded in-executor).
grep -q '"\$depth" == "lean"' "$RG" \
  && assert "wiring: showcase tail demo remains lean-only (evidence records in-executor)" "pass" \
  || assert "wiring: showcase tail demo remains lean-only (evidence records in-executor)" "fail"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
