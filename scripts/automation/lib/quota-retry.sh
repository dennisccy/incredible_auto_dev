#!/usr/bin/env bash
# quota-retry.sh — Auto-wait wrapper for Claude quota exhaustion
#
# Provides claude_with_quota_retry(), a drop-in replacement for `claude`
# that detects quota exhaustion, waits until the reset time, and retries.
# Also retries on transient streaming failures ("API Error: Stream idle
# timeout", "Server disconnected") with a short backoff.
#
# Sourced by common.sh — do not execute directly.
#
# Environment variables (all optional):
#   CHAIN_CLAUDE_RESET_TZ             Default TZ for reset time parsing (default: Europe/London)
#   CHAIN_CLAUDE_RESET_BUFFER_SECONDS Extra seconds added after parsed reset time (default: 120)
#   CHAIN_CLAUDE_FALLBACK_SLEEP_SECONDS Sleep duration when reset time cannot be parsed (default: 3600)
#   CHAIN_CLAUDE_MAX_QUOTA_RETRIES    Max quota-wait-retry cycles before hard fail (default: 3)
#   CHAIN_CLAUDE_MAX_STREAM_RETRIES   Max transient-stream-error retries (default: 2)
#   CHAIN_CLAUDE_STREAM_RETRY_SLEEP   Base sleep between stream retries, in seconds (default: 45)
#   CHAIN_DISABLE_AUTO_WAIT           Set to "true" to disable auto-wait and fail immediately
#   CHAIN_CLAUDE_PRE_RETRY_HOOK       Shell snippet eval'd after any quota sleep, before
#                                     retrying claude. Use to re-verify background services
#                                     (servers, tunnels, etc.) that may have died during the
#                                     long sleep. Runs in the caller's shell — can reference
#                                     functions and variables defined by the caller. Non-zero
#                                     exit warns but does not abort the retry.
#   CHAIN_CLAUDE_MAX_RUNTIME_SECONDS  Hard wall-clock limit for a single claude invocation
#                                     (default: 7200 = 2h). Observed behaviour: claude can
#                                     occasionally hang in ep_poll after the task is fully
#                                     written to disk (MCP cleanup, API socket stuck, etc.),
#                                     blocking the pipeline indefinitely. The timeout wraps
#                                     claude with GNU timeout: SIGTERM at the limit, SIGKILL
#                                     after a 60s grace period. A killed claude that already
#                                     wrote its artifacts is treated like any non-zero exit —
#                                     callers (run-phase.sh) log a warning and continue.
#                                     Set to 0 to disable the timeout.

: "${CHAIN_CLAUDE_RESET_TZ:=Europe/London}"
: "${CHAIN_CLAUDE_RESET_BUFFER_SECONDS:=120}"
: "${CHAIN_CLAUDE_FALLBACK_SLEEP_SECONDS:=3600}"
: "${CHAIN_CLAUDE_MAX_QUOTA_RETRIES:=3}"
: "${CHAIN_CLAUDE_MAX_STREAM_RETRIES:=2}"
: "${CHAIN_CLAUDE_STREAM_RETRY_SLEEP:=45}"
: "${CHAIN_DISABLE_AUTO_WAIT:=false}"
: "${CHAIN_CLAUDE_PRE_RETRY_HOOK:=}"
: "${CHAIN_CLAUDE_MAX_RUNTIME_SECONDS:=7200}"

# Exit code returned when quota retries are exhausted.
# 75 = EX_TEMPFAIL (POSIX sysexits.h) — "temporary failure, try again later".
# Callers (run-phase.sh) use this to distinguish quota exhaustion from code failures.
QUOTA_EXHAUSTED_EXIT_CODE=75

# Sentinel file path — shared across all pipeline stages on this machine.
_QUOTA_SENTINEL="/tmp/claude-quota-exhausted"

# ── Internal helpers ─────────────────────────────────────────────────────────

# Returns 0 if the given log file contains quota-exhaustion indicators.
#
# Note: the "your.*usage limit" pattern allows qualifiers between "your" and
# "usage limit" so messages like "you've hit your org's monthly usage limit"
# are detected. Without the .*, monthly/org variants slip through and the
# pipeline treats them as ordinary failures (returning a confusing non-quota
# exit code instead of the QUOTA_EXHAUSTED_EXIT_CODE). "reached" covers a
# likely future-variant of the same surface message.
_quota_is_exhausted() {
  local log_file="$1"
  [[ -f "$log_file" ]] || return 1
  grep -qiE \
    "(out of extra usage|you.?ve (hit|reached) (your|the).*usage limit|(monthly|daily|weekly) usage limit|usage limit reached|claude\.ai/upgrade|resets [0-9]|resets at [0-9])" \
    "$log_file" 2>/dev/null
}

# Returns 0 if the given log file indicates a long-duration limit (monthly /
# org-wide) that will NOT reset within a few hours. We treat these as hard
# fails so the pipeline does not burn 3 fallback-sleep cycles waiting for a
# reset that is days or weeks away.
_quota_is_long_duration_limit() {
  local log_file="$1"
  [[ -f "$log_file" ]] || return 1
  grep -qiE \
    "(monthly usage limit|your org.?s.*usage limit|organization.*usage limit|enterprise.*usage limit)" \
    "$log_file" 2>/dev/null
}

# Returns 0 if the given log file contains a transient streaming error that
# should be retried with a short backoff (NOT a quota issue). Examples:
#   "API Error: Stream idle timeout - partial response received"
#   "API Error: Request was aborted"
#   "API Error: Connection error"
#   "API Error: 529 overloaded_error"
#   "Server disconnected"
_stream_transient_is_present() {
  local log_file="$1"
  [[ -f "$log_file" ]] || return 1
  grep -qiE \
    "(stream idle timeout|partial response received|server disconnected|request was aborted|api error: (connection|socket|network)|overloaded_error|api error: 5[0-9][0-9])" \
    "$log_file" 2>/dev/null
}

# Prints a human-readable reset time string from the log, or empty string.
_quota_extract_reset_string() {
  local log_file="$1"
  grep -oiE "resets (at )?[0-9]{1,2}(:[0-9]{2})?\s*(am|pm)?(\s*\([^)]+\))?" "$log_file" 2>/dev/null | head -1 || true
}

# Computes seconds to sleep until the reset time, plus buffer.
# Prints the integer seconds to stdout, or empty string on failure.
_quota_compute_sleep_secs() {
  local log_file="$1"
  python3 - "$log_file" "$CHAIN_CLAUDE_RESET_TZ" "$CHAIN_CLAUDE_RESET_BUFFER_SECONDS" 2>/dev/null <<'PYEOF'
import sys, re, datetime

log_file   = sys.argv[1]
default_tz = sys.argv[2] if len(sys.argv) > 2 else "Europe/London"
buffer     = int(sys.argv[3]) if len(sys.argv) > 3 else 120

try:
    with open(log_file) as f:
        content = f.read()
except Exception:
    sys.exit(1)

# Match: "resets [at] HH[:MM] [am|pm] [(timezone)]"
pattern = r'resets\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(?:\(([^)]+)\))?'
match = re.search(pattern, content, re.IGNORECASE)
if not match:
    sys.exit(1)

hour_str   = match.group(1)
minute_str = match.group(2) or "0"
ampm       = (match.group(3) or "").lower()
tz_name    = match.group(4) or default_tz

hour   = int(hour_str)
minute = int(minute_str)

if ampm == "pm" and hour != 12:
    hour += 12
elif ampm == "am" and hour == 12:
    hour = 0

# Normalise common short-form timezone names
tz_aliases = {
    "BST":        "Europe/London",
    "GMT":        "Etc/GMT",
    "UTC":        "UTC",
    "EST":        "US/Eastern",
    "EDT":        "US/Eastern",
    "US/Eastern": "US/Eastern",
    "CST":        "US/Central",
    "MST":        "US/Mountain",
    "PST":        "US/Pacific",
    "PDT":        "US/Pacific",
    "US/Pacific": "US/Pacific",
}
tz_name = tz_aliases.get(tz_name.strip(), tz_name.strip())

try:
    import zoneinfo
    tz = zoneinfo.ZoneInfo(tz_name)
except Exception:
    try:
        tz = zoneinfo.ZoneInfo(default_tz)
    except Exception:
        sys.exit(1)

now        = datetime.datetime.now(tz=tz)
reset_time = now.replace(hour=hour, minute=minute, second=0, microsecond=0)

# If the reset time is already in the past, roll over to the next day.
if reset_time <= now:
    reset_time += datetime.timedelta(days=1)

sleep_secs = int(reset_time.timestamp() - now.timestamp()) + buffer
if sleep_secs < 0:
    sleep_secs = buffer

print(sleep_secs)
PYEOF
}

# ── Sentinel file functions ──────────────────────────────────────────────────
# The sentinel coordinates quota state across independently-invoked pipeline
# stages.  It stores the absolute epoch when quota resets.

# Write sentinel with the given reset epoch (atomic write).
_quota_write_sentinel() {
  local reset_epoch="$1"
  local tmp
  tmp=$(mktemp "${_QUOTA_SENTINEL}.XXXXXX")
  echo "$reset_epoch" > "$tmp"
  mv -f "$tmp" "$_QUOTA_SENTINEL"
}

# If sentinel exists and reset is in the future, prints remaining seconds
# to stdout and returns 0.  Otherwise removes stale sentinel and returns 1.
_quota_check_sentinel() {
  [[ -f "$_QUOTA_SENTINEL" ]] || return 1
  local reset_epoch
  reset_epoch=$(cat "$_QUOTA_SENTINEL" 2>/dev/null) || return 1
  [[ "$reset_epoch" =~ ^[0-9]+$ ]] || { rm -f "$_QUOTA_SENTINEL"; return 1; }
  local now_epoch
  now_epoch=$(date +%s)
  local remaining=$(( reset_epoch - now_epoch ))
  if [[ $remaining -gt 0 ]]; then
    echo "$remaining"
    return 0
  else
    rm -f "$_QUOTA_SENTINEL"
    return 1
  fi
}

# Remove the sentinel file.
_quota_clear_sentinel() {
  rm -f "$_QUOTA_SENTINEL"
}

# ── Suspend-resilient sleep ──────────────────────────────────────────────────
# `sleep N` on Linux uses CLOCK_MONOTONIC, which pauses during system
# suspend/hibernate. A 3-hour sleep across an overnight suspend can block for
# days instead of minutes. `_sleep_until_epoch <wall_clock_epoch>` polls the
# wall clock in small chunks, so on resume it detects the epoch has passed and
# exits immediately.
#
# Usage: _sleep_until_epoch <epoch_seconds>
# Returns: 0 when wall clock reaches epoch (or already past).
_sleep_until_epoch() {
  local target="$1"
  [[ "$target" =~ ^[0-9]+$ ]] || return 0
  local now chunk
  while true; do
    now=$(date +%s)
    if [[ $now -ge $target ]]; then return 0; fi
    chunk=$(( target - now ))
    # Cap at 60s so suspend/resume is detected within a minute of wake-up.
    [[ $chunk -gt 60 ]] && chunk=60
    # sleep || return 0: if operator SIGTERMs the sleep (e.g. to force retry
    # now that quota is back), exit immediately rather than propagate 143 up
    # — which would be misread as a non-quota failure under `set -e`.
    sleep "$chunk" || return 0
  done
}

# ── Public function ──────────────────────────────────────────────────────────

# Drop-in replacement for `claude`. Accepts the same arguments.
# On quota exhaustion: logs the event, waits for reset, retries up to MAX_RETRIES times.
# On any other failure: propagates the exit code immediately.
# On success: cleans up and returns 0.
#
# Exit codes:
#   0  — success
#   75 — quota exhaustion (all retries spent or auto-wait disabled)
#   *  — non-quota failure from claude (exit code passed through)
claude_with_quota_retry() {
  local retry_count=0
  local max_retries="${CHAIN_CLAUDE_MAX_QUOTA_RETRIES}"
  local stream_retry_count=0
  local max_stream_retries="${CHAIN_CLAUDE_MAX_STREAM_RETRIES}"
  local tmp_log

  while true; do
    # ── Pre-flight: check sentinel before wasting a claude invocation ────
    local sentinel_remaining sentinel_epoch
    if sentinel_remaining=$(_quota_check_sentinel); then
      sentinel_epoch=$(( $(date +%s) + sentinel_remaining ))
      echo "[quota-retry] $(date -Iseconds) Sentinel active — quota resets in ${sentinel_remaining}s. Sleeping..." >&2
      _sleep_until_epoch "$sentinel_epoch"
      _quota_clear_sentinel
      echo "[quota-retry] $(date -Iseconds) Sentinel sleep complete. Retrying." >&2
      _quota_run_pre_retry_hook
    fi

    tmp_log=$(mktemp /tmp/claude-quota-XXXXXX.log)

    # Run claude, stream output to terminal AND capture to temp file.
    # PIPESTATUS[0] gives claude's exit code even through the pipe.
    # Wrap with `timeout` so a hung claude (observed: stuck in ep_poll after
    # task completion due to MCP/API socket cleanup) cannot block the pipeline
    # forever. The timeout is only applied when CHAIN_CLAUDE_MAX_RUNTIME_SECONDS > 0
    # and the `timeout` binary is available.
    local sleep_start
    sleep_start=$(date +%s)
    local exit_code
    if [[ "${CHAIN_CLAUDE_MAX_RUNTIME_SECONDS:-0}" -gt 0 ]] && command -v timeout >/dev/null 2>&1; then
      timeout --kill-after=60 "$CHAIN_CLAUDE_MAX_RUNTIME_SECONDS" claude --effort max "$@" 2>&1 | tee "$tmp_log"
      exit_code="${PIPESTATUS[0]}"
      # GNU timeout returns 124 on SIGTERM, 137 on SIGKILL — log and treat as failure.
      if [[ $exit_code -eq 124 || $exit_code -eq 137 ]]; then
        echo "[quota-retry] $(date -Iseconds) *** claude exceeded CHAIN_CLAUDE_MAX_RUNTIME_SECONDS (${CHAIN_CLAUDE_MAX_RUNTIME_SECONDS}s) and was terminated ***" >&2
        echo "[quota-retry] $(date -Iseconds) If artifacts were written before the hang, downstream steps can still proceed." >&2
      fi
    else
      claude --effort max "$@" 2>&1 | tee "$tmp_log"
      exit_code="${PIPESTATUS[0]}"
    fi

    # ── Success path ────────────────────────────────────────────────────────
    if [[ $exit_code -eq 0 ]] && ! _quota_is_exhausted "$tmp_log"; then
      rm -f "$tmp_log"
      _quota_clear_sentinel
      return 0
    fi

    # ── Transient streaming failure (retry with short backoff) ──────────────
    # Detect API-side stream drops that are NOT quota exhaustion. These often
    # occur on long-running agents (browser QA) when the Anthropic streaming
    # connection goes idle; a single retry usually succeeds.
    if _stream_transient_is_present "$tmp_log" && ! _quota_is_exhausted "$tmp_log"; then
      stream_retry_count=$((stream_retry_count + 1))
      if [[ $stream_retry_count -gt $max_stream_retries ]]; then
        echo "[quota-retry] $(date -Iseconds) Stream-transient error persisted after $max_stream_retries retries. Giving up (exit $exit_code)." >&2
        rm -f "$tmp_log"
        return "$exit_code"
      fi
      # Exponential-ish backoff: base * retry_count
      local stream_sleep=$(( CHAIN_CLAUDE_STREAM_RETRY_SLEEP * stream_retry_count ))
      echo "[quota-retry] $(date -Iseconds) Transient stream failure detected (retry $stream_retry_count/$max_stream_retries). Sleeping ${stream_sleep}s before retry..." >&2
      sleep "$stream_sleep" || true
      rm -f "$tmp_log"
      continue
    fi

    # ── Non-quota, non-transient failure ───────────────────────────────────
    if ! _quota_is_exhausted "$tmp_log"; then
      rm -f "$tmp_log"
      return "$exit_code"
    fi

    # ── Quota exhaustion detected ───────────────────────────────────────────
    echo "" >&2
    echo "[quota-retry] $(date -Iseconds) *** Claude quota exhaustion detected ***" >&2

    local reset_str
    reset_str=$(_quota_extract_reset_string "$tmp_log")
    [[ -n "$reset_str" ]] && echo "[quota-retry] $(date -Iseconds) Reset indicator: '$reset_str'" >&2

    echo "[quota-retry] $(date -Iseconds) Output saved to: $tmp_log" >&2

    # Long-duration limits (monthly / org-wide) cannot be retried in a few
    # hours — fail fast so the operator can rerun on the next billing window.
    # Without this branch, the loop burns CHAIN_CLAUDE_FALLBACK_SLEEP_SECONDS
    # × CHAIN_CLAUDE_MAX_QUOTA_RETRIES seconds (default 3h) sleeping for a
    # reset that is days or weeks away.
    if _quota_is_long_duration_limit "$tmp_log"; then
      echo "[quota-retry] $(date -Iseconds) Long-duration limit detected (monthly/org). Skipping retry — limit will not reset in the retry window." >&2
      echo "[quota-retry] $(date -Iseconds) Re-run this step after the billing window resets." >&2
      rm -f "$tmp_log"
      return $QUOTA_EXHAUSTED_EXIT_CODE
    fi

    if [[ "$CHAIN_DISABLE_AUTO_WAIT" == "true" ]]; then
      echo "[quota-retry] $(date -Iseconds) CHAIN_DISABLE_AUTO_WAIT=true — not retrying." >&2
      return $QUOTA_EXHAUSTED_EXIT_CODE
    fi

    retry_count=$((retry_count + 1))
    if [[ $retry_count -gt $max_retries ]]; then
      echo "[quota-retry] $(date -Iseconds) Max quota retries ($max_retries) reached. Giving up (exit $QUOTA_EXHAUSTED_EXIT_CODE)." >&2
      return $QUOTA_EXHAUSTED_EXIT_CODE
    fi

    # Compute sleep duration
    local sleep_secs
    sleep_secs=$(_quota_compute_sleep_secs "$tmp_log")

    if [[ -z "$sleep_secs" || "$sleep_secs" -le 0 ]] 2>/dev/null; then
      echo "[quota-retry] $(date -Iseconds) Could not parse reset time from output." >&2
      echo "[quota-retry] $(date -Iseconds) Using fallback sleep: ${CHAIN_CLAUDE_FALLBACK_SLEEP_SECONDS}s" >&2
      sleep_secs="$CHAIN_CLAUDE_FALLBACK_SLEEP_SECONDS"
    else
      local wake_time
      wake_time=$(date -d "@$(( $(date +%s) + sleep_secs ))" "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null \
                  || date -r  "$(( $(date +%s) + sleep_secs ))" "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null \
                  || echo "unknown")
      echo "[quota-retry] $(date -Iseconds) Parsed reset time. Wake at: $wake_time (sleep ${sleep_secs}s incl. ${CHAIN_CLAUDE_RESET_BUFFER_SECONDS}s buffer)" >&2
    fi

    # Write sentinel so other pipeline stages can coordinate
    local reset_epoch=$(( $(date +%s) + sleep_secs ))
    _quota_write_sentinel "$reset_epoch"

    echo "[quota-retry] $(date -Iseconds) Sleeping ${sleep_secs}s ... (retry $retry_count/$max_retries will follow)" >&2
    _sleep_until_epoch "$reset_epoch"

    local actual_sleep=$(( $(date +%s) - sleep_start ))
    echo "[quota-retry] $(date -Iseconds) Woke up after ${actual_sleep}s. Retrying claude (attempt $retry_count/$max_retries)..." >&2
    _quota_run_pre_retry_hook
    echo "" >&2
  done
}

# Invoke the optional pre-retry hook after a quota sleep. Runs in the caller's
# shell (eval), so hook snippets can reference caller-defined functions and
# variables. A non-zero exit is logged but does not abort the retry — the hook
# is best-effort cleanup.
_quota_run_pre_retry_hook() {
  [[ -z "${CHAIN_CLAUDE_PRE_RETRY_HOOK:-}" ]] && return 0
  echo "[quota-retry] $(date -Iseconds) Running pre-retry hook..." >&2
  if ! eval "$CHAIN_CLAUDE_PRE_RETRY_HOOK"; then
    echo "[quota-retry] $(date -Iseconds) Pre-retry hook returned non-zero; continuing." >&2
  fi
}
