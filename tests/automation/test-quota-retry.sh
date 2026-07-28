#!/usr/bin/env bash
# test-quota-retry.sh — Unit tests for scripts/automation/lib/quota-retry.sh
#
# Usage: ./tests/automation/test-quota-retry.sh
#
# Tests quota exhaustion detection, reset-time parsing, sleep-duration
# calculation, sentinel file lifecycle, and exit code 75 — does NOT call
# the Claude CLI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source quota-retry.sh into this shell (it only defines functions, does not execute)
source "$REPO_ROOT/scripts/automation/lib/quota-retry.sh"

PASS=0
FAIL=0
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"; rm -f "$_QUOTA_SENTINEL" 2>/dev/null' EXIT

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
result=$(_quota_compute_sleep_secs "$log" || true)
[[ -z "$result" ]] && assert "returns empty when no time can be parsed" "pass" || assert "returns empty when no time can be parsed" "fail"

# ── Tests: Sentinel file lifecycle ───────────────────────────────────────────

echo ""
echo "=== Sentinel file lifecycle tests ==="
echo ""

# Clean state
_quota_clear_sentinel
_quota_check_sentinel 2>/dev/null && assert "no sentinel → check returns 1" "fail" || assert "no sentinel → check returns 1" "pass"

# Write sentinel 60s in the future
future_epoch=$(( $(date +%s) + 60 ))
_quota_write_sentinel "$future_epoch"
[[ -f "$_QUOTA_SENTINEL" ]] && assert "write creates sentinel file" "pass" || assert "write creates sentinel file" "fail"

remaining=$(_quota_check_sentinel) && status=0 || status=$?
if [[ $status -eq 0 && "$remaining" -gt 0 && "$remaining" -le 61 ]]; then
  assert "check returns remaining seconds (got ${remaining}s)" "pass"
else
  assert "check returns remaining seconds (got '${remaining:-}', status=$status)" "fail"
fi

# Write sentinel in the past → should auto-clear
past_epoch=$(( $(date +%s) - 10 ))
_quota_write_sentinel "$past_epoch"
_quota_check_sentinel 2>/dev/null && assert "past sentinel → check returns 1 (auto-cleared)" "fail" || assert "past sentinel → check returns 1 (auto-cleared)" "pass"
[[ ! -f "$_QUOTA_SENTINEL" ]] && assert "past sentinel file removed" "pass" || assert "past sentinel file removed" "fail"

# Clear sentinel
_quota_write_sentinel "$(( $(date +%s) + 60 ))"
_quota_clear_sentinel
[[ ! -f "$_QUOTA_SENTINEL" ]] && assert "clear removes sentinel" "pass" || assert "clear removes sentinel" "fail"

# Sentinel with garbage content
echo "not-a-number" > "$_QUOTA_SENTINEL"
_quota_check_sentinel 2>/dev/null && assert "garbage sentinel → check returns 1" "fail" || assert "garbage sentinel → check returns 1" "pass"

# ── Tests: QUOTA_EXHAUSTED_EXIT_CODE ─────────────────────────────────────────

echo ""
echo "=== QUOTA_EXHAUSTED_EXIT_CODE tests ==="
echo ""

[[ "$QUOTA_EXHAUSTED_EXIT_CODE" -eq 75 ]] && assert "exit code constant is 75" "pass" || assert "exit code constant is 75" "fail"

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

# Should fail immediately with exit code 75 (not retry)
start=$SECONDS
rc=0
claude_with_quota_retry --print "test" 2>/dev/null || rc=$?
elapsed=$((SECONDS - start))

# With disable=true and exit 1, should return quickly (< 5 seconds)
if [[ $elapsed -lt 5 ]]; then
  assert "CHAIN_DISABLE_AUTO_WAIT=true exits without sleeping" "pass"
else
  assert "CHAIN_DISABLE_AUTO_WAIT=true exits without sleeping (took ${elapsed}s)" "fail"
fi

# Should return exit code 75 (not 1)
if [[ $rc -eq 75 ]]; then
  assert "CHAIN_DISABLE_AUTO_WAIT returns exit code 75" "pass"
else
  assert "CHAIN_DISABLE_AUTO_WAIT returns exit code 75 (got $rc)" "fail"
fi

# ── Tests: interactive dispatch backend ──────────────────────────────────────

echo ""
echo "=== interactive dispatch backend tests ==="
echo ""

# Round-trip: with CHAIN_AGENT_BACKEND=interactive, a call publishes a request
# file (carrying agent + prompt) and BLOCKS until a "pump" writes the matching
# .res file, then returns that exit code. A mock `claude` on PATH guarantees that
# if the interactive backend is NOT wired up, the call falls through to
# _claude_invoke and fails fast (no real CLI call, no network).
IDISPATCH=$(mktemp -d)
mkdir -p "$IDISPATCH/bin"
cat > "$IDISPATCH/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "out of extra usage. resets 9am (UTC)"
exit 1
EOF
chmod +x "$IDISPATCH/bin/claude"

(
  export PATH="$IDISPATCH/bin:$PATH"
  export CHAIN_AGENT_BACKEND="interactive"
  export CHAIN_DISPATCH_DIR="$IDISPATCH"
  export CHAIN_CURRENT_AGENT="developer"
  export CHAIN_DISABLE_AUTO_WAIT="true"   # fail fast if wrongly routed to claude
  rc=0
  claude_with_quota_retry -p "ping" || rc=$?
  echo "$rc" > "$IDISPATCH/rc.out"
) &
roundtrip_pid=$!

# Wait up to ~5s for a published request
ireq=""
for _ in $(seq 1 50); do
  ireq=$(ls "$IDISPATCH"/req.*.ready 2>/dev/null | head -1 || true)
  [[ -n "$ireq" ]] && break
  sleep 0.1
done

[[ -n "$ireq" ]] && assert "interactive: publishes a request file" "pass" || assert "interactive: publishes a request file" "fail"

if [[ -n "$ireq" ]] && grep -q '"developer"' "$ireq" && grep -q '"ping"' "$ireq"; then
  assert "interactive: request carries agent + prompt" "pass"
else
  assert "interactive: request carries agent + prompt" "fail"
fi

# Act as the pump: answer with exit code 0
if [[ -n "$ireq" ]]; then
  echo 0 > "${ireq%.ready}.res"
fi
wait "$roundtrip_pid" 2>/dev/null || true
iroundtrip_rc=$(cat "$IDISPATCH/rc.out" 2>/dev/null || echo missing)
[[ "$iroundtrip_rc" == "0" ]] && assert "interactive: returns pump-supplied exit code" "pass" || assert "interactive: returns pump-supplied exit code (got $iroundtrip_rc)" "fail"

rm -rf "$IDISPATCH"

# Heartbeat: if the pump's heartbeat is stale (pump/session died), a blocked
# call must give up — non-fatally and never with exit 75 — and leave an
# .awaiting-pump marker, instead of hanging forever waiting for a result.
IHB=$(mktemp -d)
touch -d '1000 seconds ago' "$IHB/.pump-alive" 2>/dev/null || touch -t 202001010000 "$IHB/.pump-alive"
(
  export CHAIN_DISPATCH_DIR="$IHB"
  export CHAIN_AGENT_BACKEND="interactive"
  export CHAIN_CURRENT_AGENT="developer"
  export CHAIN_PUMP_HEARTBEAT_TIMEOUT="2"
  export CHAIN_DISPATCH_POLL_SECONDS="1"
  rc=0
  claude_with_quota_retry -p "ping" || rc=$?
  echo "$rc" > "$IHB/rc.out"
) &
hb_pid=$!
hb_rc="timeout"
for _ in $(seq 1 60); do
  [[ -f "$IHB/rc.out" ]] && { hb_rc=$(cat "$IHB/rc.out"); break; }
  sleep 0.2
done
kill "$hb_pid" 2>/dev/null || true
wait "$hb_pid" 2>/dev/null || true

if [[ "$hb_rc" != "timeout" && "$hb_rc" != "0" && "$hb_rc" != "75" ]]; then
  assert "interactive: stale heartbeat → non-fatal non-75 return (got $hb_rc)" "pass"
else
  assert "interactive: stale heartbeat → non-fatal non-75 return (got $hb_rc)" "fail"
fi
[[ -f "$IHB/.awaiting-pump" ]] && assert "interactive: stale heartbeat writes .awaiting-pump marker" "pass" || assert "interactive: stale heartbeat writes .awaiting-pump marker" "fail"
rm -rf "$IHB"

# Concurrency guard: two simultaneous calls (as in run-phase's post-dev fanout)
# must create two DISTINCT request files — no collision (relies on mktemp).
ICC=$(mktemp -d)
cc_pids=()
for n in 1 2; do
  (
    export CHAIN_DISPATCH_DIR="$ICC"
    export CHAIN_AGENT_BACKEND="interactive"
    export CHAIN_CURRENT_AGENT="agent$n"
    claude_with_quota_retry -p "p$n" >/dev/null 2>&1
  ) &
  cc_pids+=("$!")
done
ncc=0
for _ in $(seq 1 50); do
  ncc=$(find "$ICC" -maxdepth 1 -name 'req.*.ready' 2>/dev/null | wc -l | tr -d ' ')
  [[ "$ncc" -ge 2 ]] && break
  sleep 0.1
done
[[ "$ncc" -eq 2 ]] && assert "interactive: concurrent calls create distinct request files" "pass" || assert "interactive: concurrent calls create distinct request files (got $ncc)" "fail"
for f in "$ICC"/req.*.ready; do [[ -e "$f" ]] && echo 0 > "${f%.ready}.res"; done
for p in "${cc_pids[@]}"; do wait "$p" 2>/dev/null || true; done
rm -rf "$ICC"

# ── Tests: _agent_timeout_for (per-agent runtime cap resolution) ─────────────

echo ""
echo "=== _agent_timeout_for tests ==="
echo ""

# Table hit: reviewer resolves from lib/agent_permissions.py (3600).
v=$(CHAIN_CURRENT_AGENT="reviewer" _agent_timeout_for "")
[[ "$v" == "3600" ]] && assert "reviewer cap from builtin table (3600)" "pass" || assert "reviewer cap from builtin table (got '$v')" "fail"

# No-entry agent: empty → caller keeps the flat global (run-phase.sh unchanged).
# SPEED-12 filled the full-pipeline rows; only a truly-unknown agent falls back.
v=$(CHAIN_CURRENT_AGENT="orchestrator" _agent_timeout_for "")
[[ "$v" == "2700" ]] && assert "orchestrator capped by the SPEED-12 table (2700)" "pass" || assert "orchestrator capped by the SPEED-12 table (got '$v')" "fail"
v=$(CHAIN_CURRENT_AGENT="some-unknown-agent" _agent_timeout_for "")
[[ -z "$v" ]] && assert "unknown agent keeps flat global (empty)" "pass" || assert "unknown agent keeps flat global (got '$v')" "fail"

# Env override wins over the table.
v=$(CHAIN_CURRENT_AGENT="reviewer" CHAIN_TIMEOUT_REVIEWER=99 _agent_timeout_for "")
[[ "$v" == "99" ]] && assert "CHAIN_TIMEOUT_<AGENT> env wins over table" "pass" || assert "CHAIN_TIMEOUT_<AGENT> env wins (got '$v')" "fail"

# Explicit flat cap disables the table defaults...
v=$(CHAIN_CURRENT_AGENT="reviewer" _agent_timeout_for "set")
[[ -z "$v" ]] && assert "explicit flat cap disables table defaults" "pass" || assert "explicit flat cap disables table (got '$v')" "fail"

# ...but the more-specific per-agent env override still wins even then.
v=$(CHAIN_CURRENT_AGENT="reviewer" CHAIN_TIMEOUT_REVIEWER=77 _agent_timeout_for "set")
[[ "$v" == "77" ]] && assert "per-agent env wins even with explicit flat cap" "pass" || assert "per-agent env vs explicit flat (got '$v')" "fail"

# Kill switch reverts everyone to the flat global.
v=$(CHAIN_CURRENT_AGENT="reviewer" CHAIN_AGENT_TIMEOUTS=false _agent_timeout_for "")
[[ -z "$v" ]] && assert "CHAIN_AGENT_TIMEOUTS=false reverts to flat global" "pass" || assert "CHAIN_AGENT_TIMEOUTS=false (got '$v')" "fail"

# Non-numeric env value is ignored (falls through to the table).
v=$(CHAIN_CURRENT_AGENT="reviewer" CHAIN_TIMEOUT_REVIEWER="soon" _agent_timeout_for "")
[[ "$v" == "3600" ]] && assert "non-numeric env override ignored (table applies)" "pass" || assert "non-numeric env override (got '$v')" "fail"

# No current agent → empty (unattributed calls keep the flat global).
v=$(CHAIN_CURRENT_AGENT="" _agent_timeout_for "")
[[ -z "$v" ]] && assert "no CHAIN_CURRENT_AGENT keeps flat global" "pass" || assert "no CHAIN_CURRENT_AGENT (got '$v')" "fail"

# ── Tests: tmp-file hygiene (TMPDIR templates, sidecar discard, log preserve) ─
# Uses a mock `claude` on PATH via a subshell so the REAL claude_with_quota_retry
# path runs end-to-end offline. Telemetry stays off here (renderer behavior on
# mock output is not under test); sidecar discard is covered by calling the
# helper contracts through the failure paths.

echo ""
echo "=== tmp hygiene tests ==="
echo ""

HYG=$(mktemp -d)
mkdir -p "$HYG/bin" "$HYG/tmp" "$HYG/trace"
cat > "$HYG/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "agent exploded: unrecoverable assertion failure"
exit 7
EOF
chmod +x "$HYG/bin/claude"

# Non-quota, non-transient failure WITH a trace dir:
#   - exit code passes through (7)
#   - the kept failure log is MOVED into CHAIN_TRACE_DIR (claude-failure-*.log)
#   - NOTHING is left behind in TMPDIR
rc=0
( export PATH="$HYG/bin:$PATH" TMPDIR="$HYG/tmp"
  export CHAIN_TELEMETRY_TOKENS=false CHAIN_DISABLE_AUTO_WAIT=true
  export CHAIN_TRACE_DIR="$HYG/trace" CHAIN_AGENT_TIMEOUTS=false
  unset CHAIN_CURRENT_AGENT
  claude_with_quota_retry -p "boom" >/dev/null 2>&1 ) || rc=$?
[[ $rc -eq 7 ]] \
  && assert "hygiene: non-quota exit code passes through" "pass" \
  || assert "hygiene: non-quota exit code passes through (got $rc)" "fail"
ls "$HYG/trace"/claude-failure-*.log >/dev/null 2>&1 \
  && assert "hygiene: failure log moved into CHAIN_TRACE_DIR" "pass" \
  || assert "hygiene: failure log moved into CHAIN_TRACE_DIR" "fail"
if ls "$HYG/tmp"/claude-quota-*.log >/dev/null 2>&1 || ls "$HYG/tmp"/claude-usage-*.json >/dev/null 2>&1; then
  assert "hygiene: TMPDIR left clean after traced failure" "fail"
else
  assert "hygiene: TMPDIR left clean after traced failure" "pass"
fi

# Same failure WITHOUT a trace dir: the kept log must land IN TMPDIR (proves
# the mktemp template honors TMPDIR), and nothing else may remain.
rm -rf "$HYG/tmp"; mkdir -p "$HYG/tmp"
rc=0
( export PATH="$HYG/bin:$PATH" TMPDIR="$HYG/tmp"
  export CHAIN_TELEMETRY_TOKENS=false CHAIN_DISABLE_AUTO_WAIT=true CHAIN_AGENT_TIMEOUTS=false
  unset CHAIN_TRACE_DIR CHAIN_CURRENT_AGENT
  claude_with_quota_retry -p "boom" >/dev/null 2>&1 ) || rc=$?
ls "$HYG/tmp"/claude-quota-*.log >/dev/null 2>&1 \
  && assert "hygiene: kept failure log honors TMPDIR (no trace dir)" "pass" \
  || assert "hygiene: kept failure log honors TMPDIR (no trace dir)" "fail"

# Quota-exhaustion failure (auto-wait disabled): the quota log must be
# preserved into the trace dir, TMPDIR left clean, exit 75.
cat > "$HYG/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "You've hit your usage limit. Resets at 9am (BST)"
exit 1
EOF
chmod +x "$HYG/bin/claude"
rm -rf "$HYG/tmp" "$HYG/trace"; mkdir -p "$HYG/tmp" "$HYG/trace"
rc=0
( export PATH="$HYG/bin:$PATH" TMPDIR="$HYG/tmp"
  export CHAIN_TELEMETRY_TOKENS=false CHAIN_DISABLE_AUTO_WAIT=true
  export CHAIN_TRACE_DIR="$HYG/trace" CHAIN_AGENT_TIMEOUTS=false
  unset CHAIN_CURRENT_AGENT
  claude_with_quota_retry -p "boom" >/dev/null 2>&1 ) || rc=$?
[[ $rc -eq 75 ]] \
  && assert "hygiene: quota failure returns 75" "pass" \
  || assert "hygiene: quota failure returns 75 (got $rc)" "fail"
ls "$HYG/trace"/claude-quota-*.log >/dev/null 2>&1 \
  && assert "hygiene: quota log preserved into CHAIN_TRACE_DIR" "pass" \
  || assert "hygiene: quota log preserved into CHAIN_TRACE_DIR" "fail"
if ls "$HYG/tmp"/claude-quota-*.log >/dev/null 2>&1; then
  assert "hygiene: TMPDIR left clean after quota failure" "fail"
else
  assert "hygiene: TMPDIR left clean after quota failure" "pass"
fi

# Success path stays clean end to end.
cat > "$HYG/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "done"
exit 0
EOF
chmod +x "$HYG/bin/claude"
rm -rf "$HYG/tmp"; mkdir -p "$HYG/tmp"
rc=0
( export PATH="$HYG/bin:$PATH" TMPDIR="$HYG/tmp"
  export CHAIN_TELEMETRY_TOKENS=false CHAIN_AGENT_TIMEOUTS=false
  unset CHAIN_CURRENT_AGENT
  claude_with_quota_retry -p "ok" >/dev/null 2>&1 ) || rc=$?
if [[ $rc -eq 0 && -z "$(ls -A "$HYG/tmp" 2>/dev/null)" ]]; then
  assert "hygiene: success leaves TMPDIR empty" "pass"
else
  assert "hygiene: success leaves TMPDIR empty (rc=$rc, left: $(ls "$HYG/tmp" 2>/dev/null | tr '\n' ' '))" "fail"
fi
rm -rf "$HYG"
# The quota sentinel may have been written by the quota case above — clear it
# so this test run leaves no shared state (the EXIT trap also clears it).
rm -f "$_QUOTA_SENTINEL" 2>/dev/null || true

# ── Tests: oversized prompt routing (execve MAX_ARG_STRLEN) ──────────────────
# Linux caps every single argv/envp string at 128 KiB (32 pages). A prompt past
# that cap can never be passed as one argv string — execve fails with E2BIG
# before the CLI starts. The invoke layer must route oversized prompts via
# stdin (below the threshold argv is used exactly as before).

echo ""
echo "=== oversized prompt routing tests ==="
echo ""

BIG=$(mktemp -d)
mkdir -p "$BIG/bin"
# Mock claude: records the longest argv string and each arg (one per line),
# copies stdin verbatim. Never invoked at all under the old code for the
# oversized case — execve dies with E2BIG first.
cat > "$BIG/bin/claude" <<'EOF'
#!/usr/bin/env bash
max=0
for a in "$@"; do n=${#a}; (( n > max )) && max=$n; done
printf '%s' "$max" > "$MOCK_ARGV_MAX_OUT"
printf '%s\n' "$@" > "$MOCK_ARGS_OUT"
cat > "$MOCK_STDIN_COPY"
echo done
exit 0
EOF
chmod +x "$BIG/bin/claude"

bigp="$(head -c 300000 /dev/zero | tr '\0' q)"
bigp+=$'\nsecond line with "quotes", a \ttab, a trailing space \nand a trailing newline:\n'
printf '%s' "$bigp" > "$BIG/expected.prompt"

rc=0
( export PATH="$BIG/bin:$PATH"
  export MOCK_ARGV_MAX_OUT="$BIG/argv-max" MOCK_ARGS_OUT="$BIG/args" MOCK_STDIN_COPY="$BIG/stdin-copy"
  export CHAIN_TELEMETRY_TOKENS=false CHAIN_DISABLE_AUTO_WAIT=true CHAIN_AGENT_TIMEOUTS=false
  unset CHAIN_CURRENT_AGENT CHAIN_TRACE_DIR CHAIN_AGENT_BACKEND
  claude_with_quota_retry -p "$bigp" < /dev/null >/dev/null 2>&1 ) || rc=$?

[[ $rc -eq 0 ]] \
  && assert "oversized claude prompt: dispatch succeeds (no E2BIG)" "pass" \
  || assert "oversized claude prompt: dispatch succeeds (got rc=$rc)" "fail"
cmp -s "$BIG/expected.prompt" "$BIG/stdin-copy" 2>/dev/null \
  && assert "oversized claude prompt: reaches the CLI byte-exact via stdin" "pass" \
  || assert "oversized claude prompt: reaches the CLI byte-exact via stdin" "fail"
argvmax=$(cat "$BIG/argv-max" 2>/dev/null || echo 999999)
[[ "$argvmax" -lt 131072 ]] \
  && assert "oversized claude prompt: no argv string at MAX_ARG_STRLEN (max=$argvmax)" "pass" \
  || assert "oversized claude prompt: no argv string at MAX_ARG_STRLEN (max=$argvmax)" "fail"

# Small prompt: byte-identical historical behavior — the prompt stays on argv
# and nothing is fed on stdin.
rm -f "$BIG/argv-max" "$BIG/args" "$BIG/stdin-copy"
rc=0
( export PATH="$BIG/bin:$PATH"
  export MOCK_ARGV_MAX_OUT="$BIG/argv-max" MOCK_ARGS_OUT="$BIG/args" MOCK_STDIN_COPY="$BIG/stdin-copy"
  export CHAIN_TELEMETRY_TOKENS=false CHAIN_DISABLE_AUTO_WAIT=true CHAIN_AGENT_TIMEOUTS=false
  unset CHAIN_CURRENT_AGENT CHAIN_TRACE_DIR CHAIN_AGENT_BACKEND
  claude_with_quota_retry -p "small prompt stays on argv" < /dev/null >/dev/null 2>&1 ) || rc=$?
if [[ $rc -eq 0 ]] && grep -qxF "small prompt stays on argv" "$BIG/args" 2>/dev/null \
   && [[ ! -s "$BIG/stdin-copy" ]]; then
  assert "small claude prompt: stays on argv, stdin untouched" "pass"
else
  assert "small claude prompt: stays on argv, stdin untouched (rc=$rc)" "fail"
fi

# Codex backend: an oversized prompt must become the stdin-sentinel positional
# `-` (codex exec reads the prompt from stdin then), byte-exact on stdin.
cat > "$BIG/bin/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_ARGS_OUT"
cat > "$MOCK_STDIN_COPY"
echo done
exit 0
EOF
chmod +x "$BIG/bin/codex"
rm -f "$BIG/args" "$BIG/stdin-copy"
rm -f /tmp/codex-quota-exhausted 2>/dev/null || true
rc=0
( export PATH="$BIG/bin:$PATH"
  export MOCK_ARGS_OUT="$BIG/args" MOCK_STDIN_COPY="$BIG/stdin-copy"
  export CHAIN_TELEMETRY_TOKENS=false CHAIN_DISABLE_AUTO_WAIT=true CHAIN_AGENT_TIMEOUTS=false
  export CHAIN_AGENT_BACKEND=codex
  unset CHAIN_CURRENT_AGENT CHAIN_TRACE_DIR
  claude_with_quota_retry -p "$bigp" < /dev/null >/dev/null 2>&1 ) || rc=$?
if [[ $rc -eq 0 ]] && [[ "$(tail -n 1 "$BIG/args" 2>/dev/null)" == "-" ]] \
   && cmp -s "$BIG/expected.prompt" "$BIG/stdin-copy" 2>/dev/null; then
  assert "oversized codex prompt: positional '-' + byte-exact stdin" "pass"
else
  assert "oversized codex prompt: positional '-' + byte-exact stdin (rc=$rc, last-arg=$(tail -n 1 "$BIG/args" 2>/dev/null | head -c 20))" "fail"
fi
rm -rf "$BIG"

# ── Results ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo ""

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
