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

  local ts session_id iter
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  session_id="${GOAL_SESSION_ID:-unknown}"
  iter="${GOAL_ITER_INDEX:-null}"

  local file="$GOAL_SESSION_DIR/telemetry.jsonl"

  if command -v jq &>/dev/null; then
    local merged
    if ! merged="$(printf '%s' "$payload" | jq -c \
      --arg ts "$ts" \
      --arg session_id "$session_id" \
      --argjson iter "$iter" \
      --arg event "$event_type" \
      '. + {ts:$ts, session_id:$session_id, iter:$iter, event:$event}' 2>/dev/null)"; then
      merged="$(jq -cn \
        --arg ts "$ts" \
        --arg session_id "$session_id" \
        --argjson iter "$iter" \
        --arg event "$event_type" \
        --arg raw "$payload" \
        '{ts:$ts, session_id:$session_id, iter:$iter, event:$event, payload_raw:$raw}')"
    fi
    printf '%s\n' "$merged" >> "$file"
  else
    local iter_field="$iter"
    [[ "$iter_field" == "null" ]] || iter_field="\"$iter_field\""
    printf '{"ts":"%s","session_id":"%s","iter":%s,"event":"%s","payload_raw":%s}\n' \
      "$ts" "$session_id" "$iter_field" "$event_type" "$(printf '%s' "$payload" | sed 's/"/\\"/g; s/^/"/; s/$/"/')" \
      >> "$file"
  fi
}

# Convenience: record an agent invocation start. Returns the start time
# (epoch seconds) on stdout — capture it and pass to record_agent_invocation_end.
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
  record_telemetry_event "agent_invocation_start" "$payload"
  date +%s
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
  local now duration
  now="$(date +%s)"
  duration=$(( now - start_epoch ))
  local payload
  payload=$(printf '{"agent":"%s","exit_status":%d,"duration_seconds":%d,"retries":%d}' \
    "$agent" "$status" "$duration" "$retries")
  record_telemetry_event "agent_invocation_end" "$payload"
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
  start=$(record_agent_invocation_start "developer")
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
