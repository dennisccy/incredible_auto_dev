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
#   CHAIN_CLAUDE_DISABLE_CACHE_HYGIENE Set to "true" to drop the
#                                     `--exclude-dynamic-system-prompt-sections` flag.
#                                     Default: flag is added. The flag tells claude to move
#                                     per-machine state (cwd, env info, git status) out of
#                                     the system prompt and into the first user message,
#                                     which improves prompt-cache reuse across invocations
#                                     (and across machines that share this subtree). Only
#                                     applies with claude's default system prompt — which is
#                                     what we use everywhere.
#   CHAIN_TELEMETRY_TOKENS            Set to "false" to disable Claude API usage capture.
#                                     When enabled (the default), claude is invoked with
#                                     `--output-format stream-json` and routed through
#                                     `lib/claude_stream_renderer.py`, which pretty-prints
#                                     events to the terminal and writes a usage sidecar JSON
#                                     consumed by `record_claude_usage_telemetry`. Default
#                                     on — captures input/output/cache tokens and cost so
#                                     `lib/analyze_telemetry.py` has data to summarize.
#                                     If the renderer is missing, the wrapper falls back to
#                                     normal output and logs a warning (no behaviour change).
#   CHAIN_RENDER_TOOL_USE             Set to "true" to print "[tool: <name> arg=val]" for
#                                     every tool call the model makes. Default off — only
#                                     a single progress dot is printed per call. Long
#                                     goal-mode iterations make hundreds of tool calls
#                                     each, so verbose output drowns the model's actual
#                                     text. Enable when debugging an agent that seems
#                                     stuck on a particular file or command.
#   CHAIN_TRACE_DIR                   Directory to capture per-invocation trace records. When
#                                     set to a writable path, each successful claude call
#                                     appends a line to `$CHAIN_TRACE_DIR/trace.jsonl` (args,
#                                     agent, ts, exit_code, usage) and copies its stdout to
#                                     `$CHAIN_TRACE_DIR/<NNNN>-<agent>.log`. Enables
#                                     after-the-fact debug ("what did the orchestrator
#                                     actually see?") and supports the replay tool at
#                                     `lib/replay_trace.py`. Phase and goal entry scripts
#                                     auto-set this to `runs/<phase>/trace/` (phase mode) or
#                                     `$GOAL_SESSION_DIR/trace/` (goal mode); set
#                                     CHAIN_DISABLE_TRACE=true to opt out.
#   CHAIN_DISABLE_TRACE               When "true", the entry scripts skip auto-setting
#                                     CHAIN_TRACE_DIR. Default: false.
#   CHAIN_DISABLE_PERMISSION_ISOLATION When "true", skip the per-agent permission overlay
#                                     that limits which Bash patterns each agent can run.
#                                     The default overlay restricts `git push`,
#                                     `gh pr merge`, etc. to release-manager only. Disable
#                                     only if you have a reason — see lib/agent_permissions.py
#                                     for the full default deny list.

: "${CHAIN_CLAUDE_RESET_TZ:=Europe/London}"
: "${CHAIN_CLAUDE_RESET_BUFFER_SECONDS:=120}"
: "${CHAIN_CLAUDE_FALLBACK_SLEEP_SECONDS:=3600}"
: "${CHAIN_CLAUDE_MAX_QUOTA_RETRIES:=3}"
: "${CHAIN_CLAUDE_MAX_STREAM_RETRIES:=2}"
: "${CHAIN_CLAUDE_STREAM_RETRY_SLEEP:=45}"
: "${CHAIN_DISABLE_AUTO_WAIT:=false}"
: "${CHAIN_CLAUDE_PRE_RETRY_HOOK:=}"
: "${CHAIN_CLAUDE_MAX_RUNTIME_SECONDS:=7200}"
: "${CHAIN_CLAUDE_DISABLE_CACHE_HYGIENE:=false}"
: "${CHAIN_TELEMETRY_TOKENS:=true}"
: "${CHAIN_TRACE_DIR:=}"
: "${CHAIN_DISABLE_TRACE:=false}"
: "${CHAIN_DISABLE_PERMISSION_ISOLATION:=false}"

# ── CLI selection ─────────────────────────────────────────────────────────────
# Which CLI provider drives agent invocations. Set per-run by run-phase.sh / per-session
# by run-goal.sh from the --cli flag, or via env var. claude_with_quota_retry is now a
# back-compat alias for agent_with_quota_retry, so existing call sites work unchanged.
: "${CHAIN_CLI:=claude}"

# Codex parallels of the Claude env knobs. Defaults are conservative.
: "${CHAIN_CODEX_MAX_QUOTA_RETRIES:=3}"
: "${CHAIN_CODEX_MAX_STREAM_RETRIES:=2}"
: "${CHAIN_CODEX_STREAM_RETRY_SLEEP:=45}"
: "${CHAIN_CODEX_FALLBACK_SLEEP_SECONDS:=600}"   # OpenAI rate limits typically reset in <60s, but be safe
: "${CHAIN_CODEX_MAX_RUNTIME_SECONDS:=7200}"

# Exit code returned when quota retries are exhausted.
# 75 = EX_TEMPFAIL (POSIX sysexits.h) — "temporary failure, try again later".
# Callers (run-phase.sh) use this to distinguish quota exhaustion from code failures.
QUOTA_EXHAUSTED_EXIT_CODE=75

# Sentinel file paths — per CLI so Claude and Codex don't trip over each other
# on machines where both are configured.
_QUOTA_SENTINEL="/tmp/claude-quota-exhausted"
_CODEX_QUOTA_SENTINEL="/tmp/codex-quota-exhausted"

# Append a trace record to $CHAIN_TRACE_DIR/trace.jsonl and copy stdout into
# $CHAIN_TRACE_DIR/<NNNN>-<agent>.log. No-op if CHAIN_TRACE_DIR is unset, the
# directory does not exist, or is not writable. Always best-effort: failures
# in trace capture must NOT propagate up and break the pipeline.
#
# Args:
#   $1 — path to tmp_log (claude's captured stdout)
#   $2 — path to sidecar JSON (may be empty/missing)
#   $3 — duration_seconds (epoch delta)
#   $4 — exit_code
#   shift 4 — remaining args are the claude args (the caller's "$@")
_trace_record_invocation() {
  local tmp_log_path="$1"
  local sidecar_path="$2"
  local duration_seconds="$3"
  local invocation_exit="$4"
  shift 4

  local trace_dir="${CHAIN_TRACE_DIR:-}"
  [[ -z "$trace_dir" ]] && return 0
  [[ -d "$trace_dir" && -w "$trace_dir" ]] || return 0

  # Atomic-ish step counter
  local step_file="$trace_dir/.next-step"
  local step
  step=$( ( flock -x 9; s=$(cat "$step_file" 2>/dev/null || echo 1); echo "$((s+1))" > "$step_file"; echo "$s" ) 9>"$trace_dir/.lock" 2>/dev/null) || step=1
  [[ -z "$step" ]] && step=1
  local step_padded
  step_padded=$(printf "%04d" "$step")

  local agent="${CHAIN_CURRENT_AGENT:-unattributed}"
  local cli="${CHAIN_CLI:-claude}"
  local stdout_filename="${step_padded}-${agent}.log"
  cp -- "$tmp_log_path" "$trace_dir/$stdout_filename" 2>/dev/null || true

  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  if command -v jq >/dev/null 2>&1; then
    local args_json
    args_json=$(printf '%s\n' "$@" | jq -R . 2>/dev/null | jq -s -c . 2>/dev/null) || args_json='[]'
    local usage_json="{}"
    if [[ -n "$sidecar_path" && -f "$sidecar_path" && -s "$sidecar_path" ]]; then
      usage_json=$(cat "$sidecar_path" 2>/dev/null) || usage_json="{}"
    fi
    local record
    record=$(jq -cn \
      --argjson step "$step" \
      --arg agent "$agent" \
      --arg cli "$cli" \
      --arg ts "$ts" \
      --argjson exit_code "$invocation_exit" \
      --argjson duration_seconds "$duration_seconds" \
      --arg stdout_path "$stdout_filename" \
      --argjson args "$args_json" \
      --argjson usage "$usage_json" \
      '{step:$step, agent:$agent, cli:$cli, ts:$ts, exit_code:$exit_code, duration_seconds:$duration_seconds, stdout_path:$stdout_path, args:$args} + $usage' 2>/dev/null) || record=""
    if [[ -n "$record" ]]; then
      printf '%s\n' "$record" >> "$trace_dir/trace.jsonl"
    fi
  else
    # Minimal fallback (jq absent): step + agent + cli + ts + stdout path only
    printf '{"step":%d,"agent":"%s","cli":"%s","ts":"%s","exit_code":%d,"duration_seconds":%d,"stdout_path":"%s"}\n' \
      "$step" "$agent" "$cli" "$ts" "$invocation_exit" "$duration_seconds" "$stdout_filename" \
      >> "$trace_dir/trace.jsonl"
  fi
}

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
_claude_invoke() {
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

    # Build claude args. Always pass --effort max. Add --exclude-dynamic-system-prompt-sections
    # by default (improves prompt-cache reuse across machines / sessions; disable via
    # CHAIN_CLAUDE_DISABLE_CACHE_HYGIENE=true). When CHAIN_TELEMETRY_TOKENS=true, also
    # request stream-json output and route through claude_stream_renderer.py so the
    # final usage block lands in $CHAIN_CLAUDE_USAGE_SIDECAR for telemetry capture.
    local -a _claude_extra_args=(--effort max)
    if [[ "$CHAIN_CLAUDE_DISABLE_CACHE_HYGIENE" != "true" ]]; then
      _claude_extra_args+=(--exclude-dynamic-system-prompt-sections)
    fi

    local _renderer_path=""
    local _sidecar=""
    if [[ "$CHAIN_TELEMETRY_TOKENS" == "true" ]]; then
      _renderer_path="$(dirname "${BASH_SOURCE[0]}")/claude_stream_renderer.py"
      if [[ -f "$_renderer_path" ]]; then
        _sidecar=$(mktemp /tmp/claude-usage-XXXXXX.json)
        export CHAIN_CLAUDE_USAGE_SIDECAR="$_sidecar"
        _claude_extra_args+=(--output-format stream-json --verbose --include-partial-messages)
      else
        echo "[quota-retry] $(date -Iseconds) CHAIN_TELEMETRY_TOKENS=true but renderer not found at $_renderer_path — falling back to default output" >&2
        _renderer_path=""
      fi
    fi

    # Per-agent permission overlay + optional budget cap.
    # When CHAIN_CURRENT_AGENT is set (by record_agent_invocation_start), look up
    # disallowed tool patterns and an optional max_budget_usd via
    # lib/agent_permissions.py. Default overlay restricts `git push`, `gh pr merge`,
    # etc. to release-manager only. Disable via CHAIN_DISABLE_PERMISSION_ISOLATION=true.
    if [[ "$CHAIN_DISABLE_PERMISSION_ISOLATION" != "true" && -n "${CHAIN_CURRENT_AGENT:-}" ]]; then
      local _perms_script
      _perms_script="$(dirname "${BASH_SOURCE[0]}")/agent_permissions.py"
      if [[ -f "$_perms_script" ]]; then
        local _denials
        _denials=$(python3 "$_perms_script" disallowed "$CHAIN_CURRENT_AGENT" 2>/dev/null) || _denials=""
        if [[ -n "$_denials" ]]; then
          _claude_extra_args+=(--disallowedTools "$_denials")
        fi
        local _budget
        _budget=$(python3 "$_perms_script" budget "$CHAIN_CURRENT_AGENT" 2>/dev/null) || _budget=""
        if [[ -n "$_budget" ]]; then
          _claude_extra_args+=(--max-budget-usd "$_budget")
        fi
      fi
    fi

    # NOTE on `--foreground`: GNU timeout's default places the child in a new
    # process group via setpgid(2). With that default, terminal Ctrl-C delivers
    # SIGINT to the parent shell's pgrp only — claude never receives it, keeps
    # running, and the parent shell is blocked on the pipeline. The user sees
    # "Ctrl-C did nothing." `--foreground` keeps claude in the parent's pgrp
    # so terminal signals propagate normally. The documented downside is that
    # grandchildren of timeout aren't timed out — which is fine here because
    # we only care about claude's own runtime. See:
    # https://www.gnu.org/software/coreutils/manual/html_node/timeout-invocation.html
    if [[ "${CHAIN_CLAUDE_MAX_RUNTIME_SECONDS:-0}" -gt 0 ]] && command -v timeout >/dev/null 2>&1; then
      if [[ -n "$_renderer_path" ]]; then
        timeout --foreground --kill-after=60 "$CHAIN_CLAUDE_MAX_RUNTIME_SECONDS" claude "${_claude_extra_args[@]}" "$@" 2>&1 \
          | python3 "$_renderer_path" 2>&1 \
          | tee "$tmp_log"
        exit_code="${PIPESTATUS[0]}"
      else
        timeout --foreground --kill-after=60 "$CHAIN_CLAUDE_MAX_RUNTIME_SECONDS" claude "${_claude_extra_args[@]}" "$@" 2>&1 | tee "$tmp_log"
        exit_code="${PIPESTATUS[0]}"
      fi
      # GNU timeout returns 124 on SIGTERM, 137 on SIGKILL — log and treat as failure.
      if [[ $exit_code -eq 124 || $exit_code -eq 137 ]]; then
        echo "[quota-retry] $(date -Iseconds) *** claude exceeded CHAIN_CLAUDE_MAX_RUNTIME_SECONDS (${CHAIN_CLAUDE_MAX_RUNTIME_SECONDS}s) and was terminated ***" >&2
        echo "[quota-retry] $(date -Iseconds) If artifacts were written before the hang, downstream steps can still proceed." >&2
      fi
    else
      if [[ -n "$_renderer_path" ]]; then
        claude "${_claude_extra_args[@]}" "$@" 2>&1 \
          | python3 "$_renderer_path" 2>&1 \
          | tee "$tmp_log"
        exit_code="${PIPESTATUS[0]}"
      else
        claude "${_claude_extra_args[@]}" "$@" 2>&1 | tee "$tmp_log"
        exit_code="${PIPESTATUS[0]}"
      fi
    fi

    # ── Success path ────────────────────────────────────────────────────────
    if [[ $exit_code -eq 0 ]] && ! _quota_is_exhausted "$tmp_log"; then
      local invocation_duration=$(( $(date +%s) - sleep_start ))
      # Trace capture (best-effort, never blocks the pipeline)
      if [[ -n "${CHAIN_TRACE_DIR:-}" ]]; then
        _trace_record_invocation "$tmp_log" "${_sidecar:-}" "$invocation_duration" "$exit_code" "$@" || true
      fi
      rm -f "$tmp_log"
      _quota_clear_sentinel
      # If telemetry capture is enabled and the renderer wrote a usage sidecar,
      # forward it to the telemetry layer (no-op if telemetry.sh isn't sourced).
      if [[ -n "$_sidecar" && -f "$_sidecar" ]]; then
        if declare -F record_claude_usage_from_sidecar >/dev/null 2>&1; then
          record_claude_usage_from_sidecar "$_sidecar" || true
        fi
        rm -f "$_sidecar"
      fi
      unset CHAIN_CLAUDE_USAGE_SIDECAR
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
      # Defensive dump: the user should always see *something* when claude
      # exits non-zero, even if our quota regex didn't match. Without this,
      # an unrecognized error format (e.g., a new claude error wording in
      # stream-json mode) would surface as a silent failure: the harness
      # just returns the exit code with no on-screen explanation.
      if [[ $exit_code -ne 0 ]]; then
        echo "" >&2
        echo "════════════════════════════════════════════════════════════════════" >&2
        echo "[quota-retry] $(date -Iseconds) *** Claude exited with code $exit_code (not recognized as quota) ***" >&2
        echo "[quota-retry] $(date -Iseconds) Last 30 lines of output:" >&2
        echo "─────────────────────────────────────────────────────────────────────" >&2
        tail -n 30 "$tmp_log" >&2
        echo "─────────────────────────────────────────────────────────────────────" >&2
        echo "[quota-retry] $(date -Iseconds) Full output saved to: $tmp_log" >&2
        echo "════════════════════════════════════════════════════════════════════" >&2
      else
        rm -f "$tmp_log"
      fi
      return "$exit_code"
    fi

    # ── Quota exhaustion detected ───────────────────────────────────────────
    echo "" >&2
    echo "════════════════════════════════════════════════════════════════════" >&2
    echo "[quota-retry] $(date -Iseconds) *** CLAUDE QUOTA EXHAUSTION DETECTED ***" >&2
    echo "════════════════════════════════════════════════════════════════════" >&2

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

    # Convert seconds to a human-readable HhMmSs label for the wait line so
    # the operator can decide whether to interrupt and rerun later.
    local _human_sleep
    _human_sleep=$(printf '%dh%02dm%02ds' $(( sleep_secs / 3600 )) $(( (sleep_secs % 3600) / 60 )) $(( sleep_secs % 60 )))
    echo "[quota-retry] $(date -Iseconds) >>> SLEEPING ${_human_sleep} (${sleep_secs}s) — retry ${retry_count}/${max_retries} will follow <<<" >&2
    echo "════════════════════════════════════════════════════════════════════" >&2
    _sleep_until_epoch "$reset_epoch"

    local actual_sleep=$(( $(date +%s) - sleep_start ))
    echo "" >&2
    echo "════════════════════════════════════════════════════════════════════" >&2
    echo "[quota-retry] $(date -Iseconds) >>> WOKE UP after ${actual_sleep}s. Retrying claude (attempt ${retry_count}/${max_retries}) <<<" >&2
    echo "════════════════════════════════════════════════════════════════════" >&2
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

# ── Codex invocation path ────────────────────────────────────────────────────
# Parallel to _claude_invoke but using `codex exec --json`. Codex error/quota
# patterns differ from Claude's — the patterns below are best-guess until the
# first real Codex run (Step F of the multi-CLI rollout). The architecture is
# in place; the regex/sleep specifics will harden as we observe real responses.

_codex_quota_is_exhausted() {
  local log_file="$1"
  [[ -f "$log_file" ]] || return 1
  grep -qiE \
    "(rate.?limit|quota.?exceeded|insufficient_quota|429|rate_limit_exceeded|usage limit)" \
    "$log_file" 2>/dev/null
}

_codex_stream_transient_is_present() {
  local log_file="$1"
  [[ -f "$log_file" ]] || return 1
  grep -qiE \
    "(stream idle|partial response|server disconnected|connection (reset|closed|aborted)|503|502|504|overloaded)" \
    "$log_file" 2>/dev/null
}

# OpenAI rate-limit responses include `Retry-After: <seconds>` in headers and
# sometimes "Please retry after <N>s" in body. This extracts the seconds value.
_codex_parse_retry_after() {
  local log_file="$1"
  python3 - "$log_file" 2>/dev/null <<'PYEOF'
import re, sys
try:
    text = open(sys.argv[1]).read()
except Exception:
    sys.exit(1)
patterns = [
    r'retry[\s-]?after[":\s]+(\d+)',
    r'try again in (\d+)\s*(?:s|sec|seconds?)',
    r'reset[s]? in (\d+)\s*(?:s|sec|seconds?)',
]
for p in patterns:
    m = re.search(p, text, re.IGNORECASE)
    if m:
        # add 30s buffer
        print(int(m.group(1)) + 30)
        sys.exit(0)
sys.exit(1)
PYEOF
}

_codex_invoke() {
  local retry_count=0
  local max_retries="${CHAIN_CODEX_MAX_QUOTA_RETRIES}"
  local stream_retry_count=0
  local max_stream_retries="${CHAIN_CODEX_MAX_STREAM_RETRIES}"
  local tmp_log

  if ! command -v codex >/dev/null 2>&1; then
    echo "[quota-retry] $(date -Iseconds) ERROR: 'codex' CLI not found in PATH." >&2
    echo "[quota-retry] Install OpenAI Codex CLI or set CHAIN_CLI=claude." >&2
    return 127
  fi

  # Translate Claude-style args (-p <prompt>, plus claude-only flags) into
  # Codex's positional-prompt form. The framework's callers always pass the
  # full agent prompt via `-p`; everything else (model, output format, etc.)
  # is added by us — so we can safely strip Claude-only flags and surface the
  # prompt as a positional argument to `codex exec`.
  local _codex_prompt=""
  local -a _codex_passthrough=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--prompt|--print)
        _codex_prompt="$2"
        shift 2
        ;;
      --effort|--exclude-dynamic-system-prompt-sections|--output-format|--verbose|--include-partial-messages|--disallowedTools|--max-budget-usd)
        # Claude-only flags. Drop. Some take a value (effort/output-format/disallowedTools/max-budget-usd); skip the next arg.
        case "$1" in
          --exclude-dynamic-system-prompt-sections|--verbose|--include-partial-messages) shift ;;
          *) shift 2 ;;
        esac
        ;;
      *)
        _codex_passthrough+=("$1")
        shift
        ;;
    esac
  done
  if [[ -z "$_codex_prompt" && ${#_codex_passthrough[@]} -gt 0 ]]; then
    # No -p flag found — treat the first positional as the prompt.
    _codex_prompt="${_codex_passthrough[0]}"
    _codex_passthrough=("${_codex_passthrough[@]:1}")
  fi
  if [[ -z "$_codex_prompt" ]]; then
    echo "[quota-retry/codex] ERROR: no prompt argument found (expected -p <text> or positional)." >&2
    return 2
  fi

  while true; do
    # Sentinel pre-flight
    if [[ -f "$_CODEX_QUOTA_SENTINEL" ]]; then
      local reset_epoch
      reset_epoch=$(cat "$_CODEX_QUOTA_SENTINEL" 2>/dev/null) || reset_epoch=""
      if [[ "$reset_epoch" =~ ^[0-9]+$ ]]; then
        local now_epoch remaining
        now_epoch=$(date +%s)
        remaining=$(( reset_epoch - now_epoch ))
        if [[ $remaining -gt 0 ]]; then
          echo "[quota-retry/codex] $(date -Iseconds) Sentinel active — quota resets in ${remaining}s. Sleeping..." >&2
          _sleep_until_epoch "$reset_epoch"
        fi
      fi
      rm -f "$_CODEX_QUOTA_SENTINEL"
    fi

    tmp_log=$(mktemp /tmp/codex-quota-XXXXXX.log)
    local sleep_start
    sleep_start=$(date +%s)

    # Codex's `exec` subcommand runs a non-interactive single task with the
    # prompt as a positional argument. --json yields NDJSON for our renderer.
    # --skip-git-repo-check prevents Codex bailing out in directories that
    # aren't git repos (the test phases sometimes run in subdirs).
    local -a _codex_extra_args=(exec --json --skip-git-repo-check)
    # Append codex-side passthrough args (anything the caller passed that wasn't claude-only).
    if [[ ${#_codex_passthrough[@]} -gt 0 ]]; then
      _codex_extra_args+=("${_codex_passthrough[@]}")
    fi
    # Final positional: the prompt itself.
    _codex_extra_args+=("$_codex_prompt")

    local _renderer_path=""
    local _sidecar=""
    if [[ "$CHAIN_TELEMETRY_TOKENS" == "true" ]]; then
      _renderer_path="$(dirname "${BASH_SOURCE[0]}")/codex_stream_renderer.py"
      if [[ -f "$_renderer_path" ]]; then
        _sidecar=$(mktemp /tmp/codex-usage-XXXXXX.json)
        export CHAIN_CODEX_USAGE_SIDECAR="$_sidecar"
        # Reuse the Claude env var name so telemetry.sh's existing helper picks it up
        export CHAIN_CLAUDE_USAGE_SIDECAR="$_sidecar"
      else
        _renderer_path=""
      fi
    fi

    local exit_code
    if [[ "${CHAIN_CODEX_MAX_RUNTIME_SECONDS:-0}" -gt 0 ]] && command -v timeout >/dev/null 2>&1; then
      if [[ -n "$_renderer_path" ]]; then
        timeout --foreground --kill-after=60 "$CHAIN_CODEX_MAX_RUNTIME_SECONDS" \
          codex "${_codex_extra_args[@]}" 2>&1 \
          | python3 "$_renderer_path" 2>&1 \
          | tee "$tmp_log"
        exit_code="${PIPESTATUS[0]}"
      else
        timeout --foreground --kill-after=60 "$CHAIN_CODEX_MAX_RUNTIME_SECONDS" \
          codex "${_codex_extra_args[@]}" 2>&1 | tee "$tmp_log"
        exit_code="${PIPESTATUS[0]}"
      fi
    else
      if [[ -n "$_renderer_path" ]]; then
        codex "${_codex_extra_args[@]}" 2>&1 \
          | python3 "$_renderer_path" 2>&1 \
          | tee "$tmp_log"
        exit_code="${PIPESTATUS[0]}"
      else
        codex "${_codex_extra_args[@]}" 2>&1 | tee "$tmp_log"
        exit_code="${PIPESTATUS[0]}"
      fi
    fi

    # Success
    if [[ $exit_code -eq 0 ]] && ! _codex_quota_is_exhausted "$tmp_log"; then
      local invocation_duration=$(( $(date +%s) - sleep_start ))
      if [[ -n "${CHAIN_TRACE_DIR:-}" ]]; then
        _trace_record_invocation "$tmp_log" "${_sidecar:-}" "$invocation_duration" "$exit_code" "$@" || true
      fi
      rm -f "$tmp_log"
      rm -f "$_CODEX_QUOTA_SENTINEL"
      if [[ -n "$_sidecar" && -f "$_sidecar" ]]; then
        if declare -F record_claude_usage_from_sidecar >/dev/null 2>&1; then
          record_claude_usage_from_sidecar "$_sidecar" || true
        fi
        rm -f "$_sidecar"
      fi
      unset CHAIN_CODEX_USAGE_SIDECAR CHAIN_CLAUDE_USAGE_SIDECAR
      return 0
    fi

    # Transient streaming failure
    if _codex_stream_transient_is_present "$tmp_log" && ! _codex_quota_is_exhausted "$tmp_log"; then
      stream_retry_count=$((stream_retry_count + 1))
      if [[ $stream_retry_count -gt $max_stream_retries ]]; then
        echo "[quota-retry/codex] Transient stream error persisted after $max_stream_retries retries. Giving up." >&2
        rm -f "$tmp_log"
        return "$exit_code"
      fi
      local stream_sleep=$(( CHAIN_CODEX_STREAM_RETRY_SLEEP * stream_retry_count ))
      echo "[quota-retry/codex] Transient stream failure (retry $stream_retry_count/$max_stream_retries). Sleeping ${stream_sleep}s..." >&2
      sleep "$stream_sleep" || true
      rm -f "$tmp_log"
      continue
    fi

    # Non-quota failure
    if ! _codex_quota_is_exhausted "$tmp_log"; then
      if [[ $exit_code -ne 0 ]]; then
        echo "[quota-retry/codex] $(date -Iseconds) *** Codex exited with code $exit_code (not quota) ***" >&2
        echo "[quota-retry/codex] Last 30 lines:" >&2
        tail -n 30 "$tmp_log" >&2
        echo "[quota-retry/codex] Full output: $tmp_log" >&2
      else
        rm -f "$tmp_log"
      fi
      return "$exit_code"
    fi

    # Quota exhaustion
    echo "[quota-retry/codex] $(date -Iseconds) *** CODEX QUOTA / RATE LIMIT DETECTED ***" >&2
    if [[ "$CHAIN_DISABLE_AUTO_WAIT" == "true" ]]; then
      return $QUOTA_EXHAUSTED_EXIT_CODE
    fi
    retry_count=$((retry_count + 1))
    if [[ $retry_count -gt $max_retries ]]; then
      echo "[quota-retry/codex] Max quota retries ($max_retries) reached. Giving up." >&2
      return $QUOTA_EXHAUSTED_EXIT_CODE
    fi

    local sleep_secs
    sleep_secs=$(_codex_parse_retry_after "$tmp_log") || sleep_secs=""
    if [[ -z "$sleep_secs" || "$sleep_secs" -le 0 ]] 2>/dev/null; then
      sleep_secs="$CHAIN_CODEX_FALLBACK_SLEEP_SECONDS"
      echo "[quota-retry/codex] No retry-after found; using fallback ${sleep_secs}s." >&2
    else
      echo "[quota-retry/codex] retry-after parsed: ${sleep_secs}s" >&2
    fi

    local reset_epoch=$(( $(date +%s) + sleep_secs ))
    echo "$reset_epoch" > "$_CODEX_QUOTA_SENTINEL"
    echo "[quota-retry/codex] Sleeping ${sleep_secs}s before retry ${retry_count}/${max_retries}..." >&2
    _sleep_until_epoch "$reset_epoch"
    rm -f "$_CODEX_QUOTA_SENTINEL"
    _quota_run_pre_retry_hook
  done
}

# ── CLI dispatcher + back-compat alias ────────────────────────────────────────
# Selects the per-CLI invoke function based on $CHAIN_CLI. All step scripts
# call claude_with_quota_retry (which is now an alias) so no caller changes
# are needed when switching CLIs.

agent_with_quota_retry() {
  local cli="${CHAIN_CLI:-claude}"
  case "$cli" in
    claude) _claude_invoke "$@" ;;
    codex)  _codex_invoke  "$@" ;;
    *)
      echo "[quota-retry] Unknown CHAIN_CLI: '$cli' (expected: claude or codex)" >&2
      return 2
      ;;
  esac
}

# Back-compat alias. Existing scripts call this name; behaviour now depends on
# $CHAIN_CLI. When $CHAIN_CLI=claude (default), it's a no-op rename.
claude_with_quota_retry() {
  agent_with_quota_retry "$@"
}
