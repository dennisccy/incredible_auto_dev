#!/usr/bin/env bash
# test-goal-inline-tail.sh — _tail_or_placeholder byte cap.
#
# Defense in depth for the execve MAX_ARG_STRLEN dispatch bug: run-goal.sh's
# inlined evaluator-log / assumption-ledger tails are LINE-capped, which lets
# the assembled prompt grow one long line at a time until it crosses the 128
# KiB per-argv-string cap (production: ~iteration 40). The tails must also be
# BYTE-capped, with a marker pointing at the on-disk file (the agents already
# receive those paths, so truncation loses nothing).
#
# No API calls. Runs in under a second.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}

# run-goal.sh is a script (top-level flow), not source-safe — extract just the
# function under test. A failed extraction is a hard error: it means the
# function moved/renamed and this test needs updating alongside it.
FUNC="$(sed -n '/^_tail_or_placeholder()/,/^}/p' "$REPO_ROOT/scripts/automation/run-goal.sh")"
if [[ -z "$FUNC" ]]; then
  echo "FATAL: could not extract _tail_or_placeholder from run-goal.sh" >&2
  exit 1
fi
eval "$FUNC"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

echo ""
echo "=== _tail_or_placeholder byte-cap tests ==="
echo ""

# 1. Missing file → placeholder (existing contract, unchanged).
out="$(_tail_or_placeholder "$T/none.md" 300 "(none yet)")"
[[ "$out" == "(none yet)" ]] \
  && assert "missing file → placeholder" "pass" \
  || assert "missing file → placeholder (got: $(printf '%s' "$out" | head -c 60))" "fail"

# 2. Small file → verbatim tail, no truncation marker (existing contract).
printf 'line1\nline2\n' > "$T/small.md"
out="$(_tail_or_placeholder "$T/small.md" 300 "(none yet)")"
[[ "$out" == $'line1\nline2' && "$out" != *truncated* ]] \
  && assert "small file → verbatim tail, no marker" "pass" \
  || assert "small file → verbatim tail, no marker (got: $(printf '%s' "$out" | head -c 60))" "fail"

# 3. 300 lines x ~1 KB ≈ 300 KB passes the line cap → must come back byte-
#    capped (default 48 KiB) with a first-line marker naming the on-disk path,
#    keeping the NEWEST content (the tail end).
longline="$(head -c 1024 /dev/zero | tr '\0' e)"
for i in $(seq 1 300); do printf '%s %s\n' "$i" "$longline"; done > "$T/big.md"
out="$(_tail_or_placeholder "$T/big.md" 300 "(none yet)")"
bytes="$(printf '%s' "$out" | wc -c)"
[[ "$bytes" -le $((49152 + 200)) ]] \
  && assert "oversized tail is byte-capped (${bytes}B ≤ ~48KiB+marker)" "pass" \
  || assert "oversized tail is byte-capped (got ${bytes}B)" "fail"
if printf '%s\n' "$out" | head -1 | grep -q "truncated" \
   && printf '%s\n' "$out" | head -1 | grep -qF "$T/big.md"; then
  assert "truncation marker on first line names the on-disk file" "pass"
else
  assert "truncation marker on first line names the on-disk file (got: $(printf '%s' "$out" | head -1 | head -c 100))" "fail"
fi
[[ "$(printf '%s\n' "$out" | tail -1)" == "$(tail -1 "$T/big.md")" ]] \
  && assert "cap keeps the newest content (last line intact)" "pass" \
  || assert "cap keeps the newest content (last line intact)" "fail"

# 4. CHAIN_INLINE_TAIL_MAX_BYTES tightens the cap.
out="$(CHAIN_INLINE_TAIL_MAX_BYTES=1000 _tail_or_placeholder "$T/big.md" 300 "(none yet)")"
bytes="$(printf '%s' "$out" | wc -c)"
[[ "$bytes" -le 1200 ]] \
  && assert "CHAIN_INLINE_TAIL_MAX_BYTES tightens the cap (${bytes}B)" "pass" \
  || assert "CHAIN_INLINE_TAIL_MAX_BYTES tightens the cap (got ${bytes}B)" "fail"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo ""
[[ $FAIL -gt 0 ]] && exit 1
exit 0
