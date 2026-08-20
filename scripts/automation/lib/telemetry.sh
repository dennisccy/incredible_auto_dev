#!/usr/bin/env bash
# telemetry.sh — local telemetry capture for goal mode.
#
# Goal-mode scripts call record_telemetry_event at key points. Events are
# appended as JSON Lines to $GOAL_SESSION_DIR/telemetry.jsonl. This is the
# foundation for a future self-evolution loop that aggregates telemetry across
# sessions, but for now nothing leaves the local project.
#
# Phase mode does not source this file and does not call record_telemetry_event.
# When goal-mode scripts source this file but $GOAL_SESSION_DIR is unset, the
# helpers are no-ops so the same scripts work in test fixtures.
#
# Usage:
#   source "$(dirname "$0")/lib/telemetry.sh"
#   record_telemetry_event "iter_start" '{"iter":3,"depth":"lean"}'
#   record_telemetry_event "agent_invocation_end" \
#     "$(jq -n --arg agent "$agent" --arg status "$status" \
#         --argjson dur "$duration" --argjson retries "$retries" \
#         '{agent:$agent,status:$status,duration_seconds:$dur,retries:$retries}')"

set -uo pipefail

# Returns 0 if telemetry is enabled (i.e. GOAL_SESSION_DIR is a writable directory).
telemetry_enabled() {
  [[ -n "${GOAL_SESSION_DIR:-}" && -d "$GOAL_SESSION_DIR" && -w "$GOAL_SESSION_DIR" ]]
}

# Append one JSON line to $GOAL_SESSION_DIR/telemetry.jsonl.
#
# Args:
#   $1 — event type (string, e.g. "iter_start", "agent_invocation_end")
#   $2 — JSON object with event-specific fields. Must be valid JSON.
#
# Common fields are added automatically: ts, session_id, iter, event.
# If $2 is missing or empty, only the common fields are written.
#
# No-op when GOAL_SESSION_DIR is unset (so phase mode is unaffected).
record_telemetry_event() {
  if ! telemetry_enabled; then
    return 0
  fi

  local event_type="${1:-unknown}"
  local payload="${2:-{\}}"

  local ts session_id iter cli
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  session_id="${GOAL_SESSION_ID:-unknown}"
  iter="${GOAL_ITER_INDEX:-null}"
  cli="${CHAIN_CLI:-claude}"

  local file="$GOAL_SESSION_DIR/telemetry.jsonl"

  if command -v jq &>/dev/null; then
    local merged
    if ! merged="$(printf '%s' "$payload" | jq -c \
      --arg ts "$ts" \
      --arg session_id "$session_id" \
      --argjson iter "$iter" \
      --arg event "$event_type" \
      --arg cli "$cli" \
      '. + {ts:$ts, session_id:$session_id, iter:$iter, event:$event, cli:$cli}' 2>/dev/null)"; then
      merged="$(jq -cn \
        --arg ts "$ts" \
        --arg session_id "$session_id" \
        --argjson iter "$iter" \
        --arg event "$event_type" \
        --arg cli "$cli" \
        --arg raw "$payload" \
        '{ts:$ts, session_id:$session_id, iter:$iter, event:$event, cli:$cli, payload_raw:$raw}')"
    fi
    printf '%s\n' "$merged" >> "$file"
  else
    local iter_field="$iter"
    [[ "$iter_field" == "null" ]] || iter_field="\"$iter_field\""
    printf '{"ts":"%s","session_id":"%s","iter":%s,"event":"%s","cli":"%s","payload_raw":%s}\n' \
      "$ts" "$session_id" "$iter_field" "$event_type" "$cli" "$(printf '%s' "$payload" | sed 's/"/\\"/g; s/^/"/; s/$/"/')" \
      >> "$file"
  fi
}

# ── engine-step wall-time attribution (RETRO-1, ops-hardening retro) ─────────
# Wraps big NON-AGENT engine steps (the full/lean sub-pipeline dispatch, the
# showcase-tail join) so the wall-time report can name what the former
# "unattributed (glue)" residual — 200-625m per full iteration — actually was.
# Single-slot by design: wrapped regions must not nest (the run-goal.sh call
# sites are strictly sequential). A begin without a matching done is dropped.
_engine_step_begin() {
  _ENGINE_STEP_NAME="${1:?engine step name}"
  _ENGINE_STEP_T0="$(date +%s)"
}

_engine_step_done() {
  [[ -n "${_ENGINE_STEP_NAME:-}" ]] || return 0
  local dur=$(( $(date +%s) - ${_ENGINE_STEP_T0:-$(date +%s)} ))
  record_telemetry_event "engine_step" "$(jq -cn --arg s "$_ENGINE_STEP_NAME" --argjson d "$dur" \
      '{step:$s, duration_seconds:$d}' 2>/dev/null \
    || printf '{"step":"%s","duration_seconds":%d}' "$_ENGINE_STEP_NAME" "$dur")"
  _ENGINE_STEP_NAME=""
}

# Convenience: record an agent invocation start.
#
# Call this as a BARE STATEMENT — never via command substitution $(...).
# Both side effects must land in the CALLER's shell:
#   - exports CHAIN_CURRENT_AGENT, used both to attribute subsequent claude_usage
#     telemetry to this agent AND (critically) for the interactive dispatch
#     backend to label the request with the right subagent. A $(...) capture runs
#     this in a subshell, so the export is silently dropped and the next dispatch
#     carries a stale/empty agent name (a mislabel the pump then has to reconcile).
#   - sets CHAIN_AGENT_START_EPOCH (epoch seconds) — read it into a local right
#     after the call and pass it to record_agent_invocation_end.
record_agent_invocation_start() {
  local agent="$1"
  local extra="${2:-}"
  local payload
  if [[ -n "$extra" ]]; then
    payload=$(printf '{"agent":"%s",%s}' "$agent" "${extra#\{}")
    payload="${payload%\}}"\}
  else
    payload=$(printf '{"agent":"%s"}' "$agent")
  fi
  export CHAIN_CURRENT_AGENT="$agent"
  record_telemetry_event "agent_invocation_start" "$payload"
  CHAIN_AGENT_START_EPOCH="$(date +%s)"
  # SPEED-13: quota-retry.sh accumulates quota-sleep seconds here so the end
  # event can split active work from quota-pause wall time.
  CHAIN_QUOTA_SLEPT_SECONDS=0
}

# Convenience: record an agent invocation end with duration and status.
#
# Args:
#   $1 — agent name
#   $2 — start_epoch (from record_agent_invocation_start)
#   $3 — exit status (numeric)
#   $4 — retries (numeric, default 0)
record_agent_invocation_end() {
  local agent="$1"
  local start_epoch="$2"
  local status="$3"
  local retries="${4:-0}"
  local now duration slept active
  now="$(date +%s)"
  duration=$(( now - start_epoch ))
  # SPEED-13: duration_seconds keeps its historical meaning (wall clock).
  # quota_sleep_seconds/active_seconds are additive fields so consumers can
  # separate real work from quota-pause waits (18h "agent durations" were
  # actually overnight quota sleeps attributed to the agent).
  slept="${CHAIN_QUOTA_SLEPT_SECONDS:-0}"
  [[ "$slept" =~ ^[0-9]+$ ]] || slept=0
  (( slept > duration )) && slept=$duration
  active=$(( duration - slept ))
  local payload
  payload=$(printf '{"agent":"%s","exit_status":%d,"duration_seconds":%d,"quota_sleep_seconds":%d,"active_seconds":%d,"retries":%d}' \
    "$agent" "$status" "$duration" "$slept" "$active" "$retries")
  record_telemetry_event "agent_invocation_end" "$payload"
  unset CHAIN_CURRENT_AGENT
  CHAIN_QUOTA_SLEPT_SECONDS=0
}

# Forward Claude API usage info captured by claude_stream_renderer.py to the
# telemetry log. The sidecar is a JSON object containing usage counts,
# total_cost_usd, duration, and the upstream session_id.
#
# Called from quota-retry.sh on the success path when CHAIN_TELEMETRY_TOKENS=true.
# No-op when telemetry is not enabled or the sidecar is empty/missing.
#
# Args:
#   $1 — path to the sidecar JSON file
record_claude_usage_from_sidecar() {
  local sidecar_path="${1:-}"
  if ! telemetry_enabled; then return 0; fi
  if [[ -z "$sidecar_path" || ! -s "$sidecar_path" ]]; then return 0; fi

  local payload
  payload=$(cat "$sidecar_path" 2>/dev/null) || return 0
  if [[ -z "$payload" ]]; then return 0; fi

  # Attach the current agent name so analyzers can attribute cost back to the
  # agent that drove the call, plus the REQUESTED output style (STYLE-1) when
  # one was in force — the EFFECTIVE style already rides in from the sidecar as
  # `output_style` (the renderer stamps it from the stream-json init event);
  # interactive rows read `<name>(emulated)`. Falls back to the raw sidecar
  # payload if jq is unavailable or the payload is malformed.
  if command -v jq >/dev/null 2>&1 && [[ -n "${CHAIN_CURRENT_AGENT:-}" ]]; then
    local enriched
    if enriched=$(printf '%s' "$payload" | jq -c --arg a "$CHAIN_CURRENT_AGENT" --arg os "${_CHAIN_TRACE_OUTPUT_STYLE:-}" \
        '. + {agent:$a} + (if $os != "" then {output_style_requested:$os} else {} end)' 2>/dev/null); then
      payload="$enriched"
    fi
  fi

  record_telemetry_event "claude_usage" "$payload"
}

# Standalone test mode: invoking this script directly with arg "test" exercises
# the helpers against a temporary $GOAL_SESSION_DIR and prints results.
if [[ "${BASH_SOURCE[0]}" == "${0}" && "${1:-}" == "test" ]]; then
  set -e
  tmp_dir=$(mktemp -d)
  export GOAL_SESSION_DIR="$tmp_dir"
  export GOAL_SESSION_ID="test-session"
  export GOAL_ITER_INDEX=2

  record_telemetry_event "iter_start" '{"depth":"lean"}'
  record_agent_invocation_start "developer"
  start=$CHAIN_AGENT_START_EPOCH
  sleep 1
  record_agent_invocation_end "developer" "$start" 0 1
  record_telemetry_event "iter_end" '{"verdict":"CONTINUE","journey_deltas":2}'

  echo "--- telemetry.jsonl ---"
  cat "$tmp_dir/telemetry.jsonl"
  echo "--- end ---"

  if command -v jq &>/dev/null; then
    echo "Validating each line is valid JSON..."
    while IFS= read -r line; do
      printf '%s' "$line" | jq empty >/dev/null
    done < "$tmp_dir/telemetry.jsonl"
    echo "All lines valid."
  fi

  unset GOAL_SESSION_DIR
  record_telemetry_event "should_be_noop" '{}'
  echo "No-op when GOAL_SESSION_DIR unset: OK"

  rm -rf "$tmp_dir"
  echo "Test passed."
fi
