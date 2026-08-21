#!/usr/bin/env bash
# test-review-verdict-event.sh — record_review_verdict (lib/telemetry.sh): the one
# emitter behind the `review_verdict` event for BOTH the lean and the full-depth
# review loops, plus the wiring greps that prove both loops call it.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AUTO="$ENGINE_ROOT/scripts/automation"
PASS=0; FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# emit <report-body> <attempt> <rc> → prints the review_verdict events written
emit() {
  local t="$WORK/telemetry.jsonl"; rm -f "$t"
  printf '%b' "$1" > "$WORK/review.md"
  # lib/telemetry.sh appends to $GOAL_SESSION_DIR/telemetry.jsonl and is a no-op
  # when GOAL_SESSION_DIR is unset/unwritable (telemetry_enabled, telemetry.sh:24-26, :52).
  env GOAL_SESSION_DIR="$WORK" bash -c "
    source '$AUTO/lib/telemetry.sh' >/dev/null 2>&1
    record_review_verdict '$WORK/review.md' $2 goal-x-iter-3 $3" >/dev/null 2>&1
  [[ -f "$t" ]] && jq -c 'select(.event=="review_verdict") | {verdict,attempt,iter_name}' "$t" 2>/dev/null || true
}

out="$(emit '**Verdict:** PASS\n\n```yaml\nphase: x\n```\n' 1 0)"
[[ "$out" == '{"verdict":"PASS","attempt":1,"iter_name":"goal-x-iter-3"}' ]] && pass "PASS report → verdict PASS, attempt 1, iter_name" || fail "PASS report (got: $out)"
out="$(emit '# Review\n\n**Verdict:** PASS_WITH_NOTES\n' 2 0)"
[[ "$out" == '{"verdict":"PASS_WITH_NOTES","attempt":2,"iter_name":"goal-x-iter-3"}' ]] && pass "PASS_WITH_NOTES, attempt 2" || fail "PASS_WITH_NOTES (got: $out)"
out="$(emit '**Verdict:** FAIL\n' 1 0)"
[[ "$out" == '{"verdict":"FAIL","attempt":1,"iter_name":"goal-x-iter-3"}' ]] && pass "FAIL report" || fail "FAIL report (got: $out)"
out="$(emit '# Review\n\nLooks fine.\n' 1 0)"
[[ "$out" == '{"verdict":"","attempt":1,"iter_name":"goal-x-iter-3"}' ]] && pass "no verdict line, rc 0 → empty verdict event" || fail "unparseable (got: $out)"
out="$(emit '**Verdict:** PASS (with notes)\n' 1 0)"
[[ "$out" == '{"verdict":"","attempt":1,"iter_name":"goal-x-iter-3"}' ]] && pass "loose verdict line is unparseable (strict rule)" || fail "loose line (got: $out)"
out="$(emit '# Review\n\nLooks fine.\n' 1 75)"
[[ -z "$out" ]] && pass "no verdict line, rc 75 (quota) → no event" || fail "quota case emitted: $out"
out="$(emit '**Verdict:** PASS\n' 1 75)"
[[ "$out" == '{"verdict":"PASS","attempt":1,"iter_name":"goal-x-iter-3"}' ]] && pass "parseable verdict wins even when rc is 75" || fail "rc 75 with verdict (got: $out)"

# Wiring: both loops call the helper; lean no longer emits inline.
awk '/Step 3\/11 -- Dev \+ Review loop/,/update_status "\$PHASE" "in_progress" "review_passed"/' "$AUTO/run-phase.sh" | grep -q 'record_review_verdict "\$REVIEW_REPORT" "\$ATTEMPT" "\$PHASE" "\$rev_rc"' \
  && pass "run-phase.sh Step 3 calls record_review_verdict with attempt/phase/rc" || fail "run-phase.sh Step 3 wiring"
[[ "$(grep -c 'record_review_verdict "\$REVIEW_REPORT"' "$AUTO/goal-iter-lean.sh")" == "2" ]] && pass "goal-iter-lean.sh calls the helper at both review sites" || fail "goal-iter-lean.sh wiring ($(grep -c 'record_review_verdict' "$AUTO/goal-iter-lean.sh") calls)"
! grep -q 'record_telemetry_event "review_verdict"' "$AUTO/goal-iter-lean.sh" && pass "goal-iter-lean.sh has no inline review_verdict emission left" || fail "inline emission still present in goal-iter-lean.sh"

echo ""; echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
