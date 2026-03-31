#!/usr/bin/env bash
# test-quota-retry.sh — Unit tests for scripts/automation/lib/quota-retry.sh
#
# Usage: ./tests/automation/test-quota-retry.sh
#
# Tests quota exhaustion detection, reset-time parsing, and sleep-duration
# calculation using synthetic log files — does NOT call the Claude CLI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source quota-retry.sh into this shell (it only defines functions, does not execute)
source "$REPO_ROOT/scripts/automation/lib/quota-retry.sh"

PASS=0
FAIL=0
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────

assert() {
  local label="$1"
  local result="$2"   # "pass" or "fail"
  if [[ "$result" == "pass" ]]; then
    echo "  PASS  $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $label"
    FAIL=$((FAIL + 1))
  fi
}

make_log() {
  local name="$1"
  local content="$2"
  local path="$TMP_DIR/${name}.log"
  printf '%s\n' "$content" > "$path"
  echo "$path"
}

# ── Tests: _quota_is_exhausted ────────────────────────────────────────────────

echo ""
echo "=== _quota_is_exhausted tests ==="
echo ""

log=$(make_log "exhausted_1" "You've hit your usage limit. Resets at 9am (BST)")
_quota_is_exhausted "$log" && assert "detects 'hit your usage limit'" "pass" || assert "detects 'hit your usage limit'" "fail"

log=$(make_log "exhausted_2" "out of extra usage for the day. resets 9:30am")
_quota_is_exhausted "$log" && assert "detects 'out of extra usage'" "pass" || assert "detects 'out of extra usage'" "fail"

log=$(make_log "exhausted_3" "Usage limit reached. Visit claude.ai/upgrade")
_quota_is_exhausted "$log" && assert "detects 'usage limit reached'" "pass" || assert "detects 'usage limit reached'" "fail"

log=$(make_log "not_exhausted" "Successfully completed the task.")
_quota_is_exhausted "$log" && assert "does NOT flag normal output as exhausted" "fail" || assert "does NOT flag normal output as exhausted" "pass"

log=$(make_log "empty" "")
_quota_is_exhausted "$log" && assert "does NOT flag empty log as exhausted" "fail" || assert "does NOT flag empty log as exhausted" "pass"

# ── Tests: _quota_extract_reset_string ───────────────────────────────────────

echo ""
echo "=== _quota_extract_reset_string tests ==="
echo ""

log=$(make_log "reset_1" "Resets at 9am (BST). Please wait.")
result=$(_quota_extract_reset_string "$log")
[[ -n "$result" ]] && assert "extracts 'resets at 9am (BST)'" "pass" || assert "extracts 'resets at 9am (BST)'" "fail"

log=$(make_log "reset_2" "resets 9:30 am")
result=$(_quota_extract_reset_string "$log")
[[ -n "$result" ]] && assert "extracts 'resets 9:30 am'" "pass" || assert "extracts 'resets 9:30 am'" "fail"

log=$(make_log "no_reset" "An error occurred.")
result=$(_quota_extract_reset_string "$log")
[[ -z "$result" ]] && assert "returns empty when no reset string" "pass" || assert "returns empty when no reset string" "fail"

# ── Tests: _quota_compute_sleep_secs ─────────────────────────────────────────

echo ""
echo "=== _quota_compute_sleep_secs tests ==="
echo ""

# Use a reset time far in the future (11:59pm) so sleep_secs is always > 0
log=$(make_log "far_future" "Usage limit reached. Resets at 11:59pm (UTC)")
CHAIN_CLAUDE_RESET_TZ="UTC"
CHAIN_CLAUDE_RESET_BUFFER_SECONDS="60"
result=$(_quota_compute_sleep_secs "$log")
if [[ -n "$result" && "$result" -gt 0 ]]; then
  assert "computes positive sleep duration for future reset" "pass"
else
  assert "computes positive sleep duration for future reset" "fail"
fi

# No parseable time → empty result
log=$(make_log "no_time" "out of extra usage for the day")
result=$(_quota_compute_sleep_secs "$log")
[[ -z "$result" ]] && assert "returns empty when no time can be parsed" "pass" || assert "returns empty when no time can be parsed" "fail"

# ── Tests: CHAIN_DISABLE_AUTO_WAIT ───────────────────────────────────────────

echo ""
echo "=== CHAIN_DISABLE_AUTO_WAIT tests ==="
echo ""

# Mock claude to produce quota exhaustion output, then verify retry is skipped
CLAUDE_MOCK="$TMP_DIR/claude"
cat > "$CLAUDE_MOCK" <<'EOF'
#!/usr/bin/env bash
echo "out of extra usage for the day. resets 9am (UTC)"
exit 1
EOF
chmod +x "$CLAUDE_MOCK"
PATH="$TMP_DIR:$PATH"

CHAIN_DISABLE_AUTO_WAIT="true"
CHAIN_CLAUDE_MAX_QUOTA_RETRIES="3"
CHAIN_CLAUDE_RESET_TZ="UTC"
CHAIN_CLAUDE_RESET_BUFFER_SECONDS="0"
CHAIN_CLAUDE_FALLBACK_SLEEP_SECONDS="1"

# Should fail immediately (not retry)
start=$SECONDS
claude_with_quota_retry --print "test" 2>/dev/null || true
elapsed=$((SECONDS - start))

# With disable=true and exit 1, should return quickly (< 5 seconds)
if [[ $elapsed -lt 5 ]]; then
  assert "CHAIN_DISABLE_AUTO_WAIT=true exits without sleeping" "pass"
else
  assert "CHAIN_DISABLE_AUTO_WAIT=true exits without sleeping (took ${elapsed}s)" "fail"
fi

# ── Results ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo ""

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
