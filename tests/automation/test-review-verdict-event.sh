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
# Non-vacuous rc-75 case: seed a PASS event first (proving the helper actually
# ran, not merely "command not found" also yielding empty output), then call
# again with a no-verdict report + rc 75 into the SAME file and assert the
# count stays at exactly one -- the second call truly suppressed.
rm -f "$WORK/telemetry.jsonl"
printf '**Verdict:** PASS\n' > "$WORK/pass-seed.md"
printf '# Review\n\nLooks fine.\n' > "$WORK/no-verdict.md"
env GOAL_SESSION_DIR="$WORK" bash -c "
  source '$AUTO/lib/telemetry.sh' >/dev/null 2>&1
  record_review_verdict '$WORK/pass-seed.md' 1 goal-x-iter-3 0
  record_review_verdict '$WORK/no-verdict.md' 1 goal-x-iter-3 75" >/dev/null 2>&1
n_events="$(jq -s '[.[] | select(.event=="review_verdict")] | length' "$WORK/telemetry.jsonl" 2>/dev/null)"
[[ "$n_events" == "1" ]] && pass "no verdict line, rc 75 (quota) → no event (helper ran+suppressed: seeded PASS row is the only one)" || fail "quota case: expected exactly 1 review_verdict row after seed+suppress, got $n_events"
out="$(emit '**Verdict:** PASS\n' 1 75)"
[[ "$out" == '{"verdict":"PASS","attempt":1,"iter_name":"goal-x-iter-3"}' ]] && pass "parseable verdict wins even when rc is 75" || fail "rc 75 with verdict (got: $out)"

# Regression (fix round 1, F1): an EARLIER "**Verdict:**" line with no
# PASS/PASS_WITH_NOTES/FAIL token (loose grep would land on it first) followed
# by a LATER strict line must not abort the caller under set -e/pipefail. The
# extraction pipeline's middle stage (grep -oE token) can fail on the
# loose-matched line while the rightmost stage (head) still exits 0 --
# pipefail hunts for ANY failing stage, not just the rightmost, so a bare
# `v="$(...)"` assignment used to trip `set -e` before record_telemetry_event
# ever ran. Run bare (no `|| true` at the call site) to prove the HELPER
# itself is now safe, not just the call sites' defence in depth.
rm -f "$WORK/telemetry.jsonl"
printf '**Verdict:** TBD (draft note, ignore)\nsome text\n**Verdict:** PASS\n' > "$WORK/multi-verdict.md"
out2="$(env GOAL_SESSION_DIR="$WORK" bash -c "
  set -euo pipefail
  source '$AUTO/lib/telemetry.sh' >/dev/null 2>&1
  record_review_verdict '$WORK/multi-verdict.md' 1 goal-x-iter-3 0
  echo STILL-ALIVE" 2>&1)"
ev2="$(jq -c 'select(.event=="review_verdict") | {verdict,attempt,iter_name}' "$WORK/telemetry.jsonl" 2>/dev/null)"
[[ "$ev2" == '{"verdict":"PASS","attempt":1,"iter_name":"goal-x-iter-3"}' && "$out2" == *STILL-ALIVE* ]] \
  && pass "earlier non-strict Verdict line + later strict line: caller survives under set -e/pipefail" \
  || fail "multi-Verdict-line under set -e (event: $ev2, output: $out2)"

# Wiring: both loops call the helper; lean no longer emits inline.
awk '/Step 3\/11 -- Dev \+ Review loop/,/update_status "\$PHASE" "in_progress" "review_passed"/' "$AUTO/run-phase.sh" | grep -q 'record_review_verdict "\$REVIEW_REPORT" "\$ATTEMPT" "\$PHASE" "\$rev_rc"' \
  && pass "run-phase.sh Step 3 calls record_review_verdict with attempt/phase/rc" || fail "run-phase.sh Step 3 wiring"
[[ "$(grep -c 'record_review_verdict "\$REVIEW_REPORT"' "$AUTO/goal-iter-lean.sh")" == "2" ]] && pass "goal-iter-lean.sh calls the helper at both review sites" || fail "goal-iter-lean.sh wiring ($(grep -c 'record_review_verdict' "$AUTO/goal-iter-lean.sh") calls)"
! grep -q 'record_telemetry_event "review_verdict"' "$AUTO/goal-iter-lean.sh" && pass "goal-iter-lean.sh has no inline review_verdict emission left" || fail "inline emission still present in goal-iter-lean.sh"

echo ""; echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
