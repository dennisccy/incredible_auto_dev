#!/usr/bin/env bash
# interactive-dispatch.sh — the "interactive" agent-dispatch backend for the
# quota-retry seam.
#
# Instead of spawning a headless `claude -p` subprocess (the Agent SDK path),
# this backend hands each agent prompt to a foreground Claude Code session (the
# "pump") over a small file channel and blocks for the result. The pump
# dispatches the agent as a subagent, so the work runs INSIDE the interactive
# session and bills to the interactive plan allowance rather than the Agent SDK
# credit. The engine's loop / stop rules / resume / state are untouched — only
# the leaf invocation changes.
#
# Sourced by quota-retry.sh; selected when CHAIN_AGENT_BACKEND=interactive.
# Requires CHAIN_DISPATCH_DIR (created + exported by run-goal.sh).
#
# Channel protocol (one request per agent call):
#   _interactive_invoke writes   <dir>/req.XXXXXX.ready = {agent, prompt, cwd, res_path}
#   the pump reads it, dispatches subagent_type=<agent>, then writes
#                                <dir>/req.XXXXXX.res   = <exit-code>
#   _interactive_invoke returns that exit code.
#
# Request filenames are unique (mktemp), so the concurrent calls produced by
# run-phase.sh's post-dev fanout never collide. This backend never sleeps until
# a quota reset and never returns the quota exit code 75 — interactive quota is
# handled by the pump pausing and the user resuming.
#
# Environment:
#   CHAIN_DISPATCH_DIR            Channel directory (required). Set by run-goal.sh.
#   CHAIN_DISPATCH_POLL_SECONDS   Poll interval while waiting for a result (default 1).

: "${CHAIN_DISPATCH_POLL_SECONDS:=1}"
# Generous default: the pump only refreshes the heartbeat while it is *waiting*
# for the next request (goal-await-dispatch.sh), not while a dispatched subagent
# is running, so this must comfortably exceed the longest single agent call.
: "${CHAIN_PUMP_HEARTBEAT_TIMEOUT:=1800}"

# Echo the value following -p / --print in the args (the agent prompt). Empty if absent.
_interactive_extract_prompt() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--print) printf '%s' "${2:-}"; return 0 ;;
      *) shift ;;
    esac
  done
  return 0
}

# Drop-in replacement for _claude_invoke when CHAIN_AGENT_BACKEND=interactive.
# Receives the same args the step scripts pass to claude_with_quota_retry
# (i.e. `-p "<prompt>"`); the per-agent --effort/--disallowedTools overlay that
# _claude_invoke builds is not needed here (subagents inherit model/tools from
# their .claude/agents/<name>.md frontmatter).
_interactive_invoke() {
  local dir="${CHAIN_DISPATCH_DIR:-}"
  if [[ -z "$dir" || ! -d "$dir" ]]; then
    echo "[interactive-dispatch] CHAIN_DISPATCH_DIR is unset or not a directory — cannot dispatch." >&2
    return 2
  fi

  local agent="${CHAIN_CURRENT_AGENT:-unattributed}"
  local prompt
  prompt="$(_interactive_extract_prompt "$@")"

  local req res
  req="$(mktemp "$dir/req.XXXXXX")"
  res="$req.res"

  # Build the request JSON. jq handles arbitrary prompt content (quotes,
  # newlines, large prompts) safely; python3 is the fallback.
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg a "$agent" --arg p "$prompt" --arg c "$PWD" --arg r "$res" \
      '{agent:$a, prompt:$p, cwd:$c, res_path:$r}' > "$req"
  else
    _ID_A="$agent" _ID_P="$prompt" _ID_C="$PWD" _ID_R="$res" python3 -c \
      'import json,os; print(json.dumps({"agent":os.environ["_ID_A"],"prompt":os.environ["_ID_P"],"cwd":os.environ["_ID_C"],"res_path":os.environ["_ID_R"]}))' > "$req"
  fi

  # Publish atomically: the pump only picks up *.ready files.
  mv "$req" "$req.ready"

  # Block until the pump writes the result. While waiting, watch the pump's
  # heartbeat: if it exists but has gone stale, the pump/session has died, so
  # give up non-fatally (never the quota code 75) and leave an .awaiting-pump
  # marker — instead of blocking forever. An absent heartbeat means "keep
  # waiting" (the pump may not have beaten yet).
  local hb="$dir/.pump-alive"
  while [[ ! -f "$res" ]]; do
    if [[ -f "$hb" ]]; then
      local _now _hbm _age
      _now="$(date +%s)"
      _hbm="$(stat -c %Y "$hb" 2>/dev/null || stat -f %m "$hb" 2>/dev/null || echo "$_now")"
      _age=$(( _now - _hbm ))
      if [[ "$_age" -gt "$CHAIN_PUMP_HEARTBEAT_TIMEOUT" ]]; then
        echo "[interactive-dispatch] pump heartbeat stale (${_age}s > ${CHAIN_PUMP_HEARTBEAT_TIMEOUT}s) — assuming the pump/session stopped; aborting this dispatch." >&2
        printf 'pump heartbeat stale: %ss since last beat (agent=%s)\n' "$_age" "$agent" > "$dir/.awaiting-pump"
        rm -f "$req.ready" 2>/dev/null || true
        return 70
      fi
    fi
    sleep "$CHAIN_DISPATCH_POLL_SECONDS"
  done

  local rc
  rc="$(cat "$res" 2>/dev/null || echo 1)"
  rm -f "$res" "$req.ready" 2>/dev/null || true
  [[ "$rc" =~ ^[0-9]+$ ]] || rc=1
  return "$rc"
}

# ── Self-test (run directly: `bash interactive-dispatch.sh --self-test`) ──────
# Forks a tiny "pump" that answers one request, then drives a real round-trip
# through _interactive_invoke. Fast (<1s); does NOT exercise the heartbeat-stale
# path. No-op when the file is merely sourced (the BASH_SOURCE guard below).
_interactive_dispatch_self_test() {
  local d fails=0 rc=0 pump r
  d="$(mktemp -d)"
  export CHAIN_DISPATCH_DIR="$d"
  export CHAIN_CURRENT_AGENT="developer"
  ( for _ in $(seq 1 50); do
      r="$(find "$d" -maxdepth 1 -name 'req.*.ready' 2>/dev/null | head -1)"
      if [[ -n "$r" ]]; then echo 0 > "${r%.ready}.res"; break; fi
      sleep 0.1
    done ) &
  pump=$!
  _interactive_invoke -p "ping self-test" || rc=$?
  wait "$pump" 2>/dev/null || true
  if [[ "$rc" -eq 0 ]]; then echo "  PASS interactive-dispatch: round-trip returns pump exit code"; else echo "  FAIL interactive-dispatch: round-trip (rc=$rc)"; fails=1; fi
  rm -rf "$d"
  if [[ "$fails" -eq 0 ]]; then echo "interactive-dispatch self-test: OK"; else echo "interactive-dispatch self-test: FAILED"; fi
  return "$fails"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" && "${1:-}" == "--self-test" ]]; then
  _interactive_dispatch_self_test
  exit $?
fi
