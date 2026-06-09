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
# CHAIN_PUMP_HEARTBEAT_TIMEOUT governs the PICKUP window only: how long a brand-new,
# not-yet-claimed request may wait for the pump to take it. An alive idle pump
# refreshes the heartbeat (.pump-alive) every ~1s while waiting in
# goal-await-dispatch.sh, so staleness here genuinely means the pump never picked
# the request up (it stopped/closed). It no longer needs to cover a long agent's
# runtime — that is the inflight cap below.
: "${CHAIN_PUMP_HEARTBEAT_TIMEOUT:=1800}"
# CHAIN_DISPATCH_INFLIGHT_TIMEOUT bounds a single CLAIMED, in-flight subagent
# (measured from the pump's .started claim marker), so a legitimately long agent
# call (e.g. the developer's INITIAL BUILD, which routinely exceeds 30 min) is
# never mistaken for a dead pump. 0 = unlimited. Defaults to the headless per-call
# runtime cap so the interactive backend is symmetric with `claude -p`.
: "${CHAIN_DISPATCH_INFLIGHT_TIMEOUT:=${CHAIN_CLAUDE_MAX_RUNTIME_SECONDS:-7200}}"

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

  # Block until the pump writes the result. Two tiers of liveness while waiting
  # (give up non-fatally — never the quota code 75 — and leave an .awaiting-pump
  # marker instead of blocking forever):
  #
  #   Tier A — PICKUP (this request not yet claimed: no .started marker).
  #     An alive idle pump refreshes .pump-alive every ~1s while it waits in
  #     goal-await-dispatch.sh, so a heartbeat older than CHAIN_PUMP_HEARTBEAT_TIMEOUT
  #     means the pump never picked this request up (it stopped/closed) → abort.
  #     An absent heartbeat means "keep waiting" (the pump may not have beaten yet).
  #     If ANY req.*.started exists in the channel the pump is demonstrably alive and
  #     busy on another request, so this unclaimed request falls back to the inflight
  #     cap rather than the short pickup timeout (avoids a false abort mid-dispatch).
  #
  #   Tier B — INFLIGHT (this request claimed: goal-await-dispatch.sh touched
  #     <req>.started when it handed the request to the pump). The pump is actively
  #     running the subagent, so bound it ONLY by CHAIN_DISPATCH_INFLIGHT_TIMEOUT
  #     (from the .started mtime; 0 = unlimited). This is what stops a legitimately
  #     long agent — e.g. the developer's INITIAL BUILD, routinely > 30 min — from
  #     being mistaken for a dead pump.
  local hb="$dir/.pump-alive"
  local started="$req.started"
  local _now _ref _age _busy _s
  while [[ ! -f "$res" ]]; do
    _now="$(date +%s)"
    if [[ -f "$started" ]]; then
      # Tier B: claimed → inflight cap measured from the claim time.
      if [[ "${CHAIN_DISPATCH_INFLIGHT_TIMEOUT:-7200}" -gt 0 ]]; then
        _ref="$(stat -c %Y "$started" 2>/dev/null || stat -f %m "$started" 2>/dev/null || echo "$_now")"
        _age=$(( _now - _ref ))
        if [[ "$_age" -gt "${CHAIN_DISPATCH_INFLIGHT_TIMEOUT:-7200}" ]]; then
          echo "[interactive-dispatch] claimed agent '$agent' exceeded inflight timeout (${_age}s > ${CHAIN_DISPATCH_INFLIGHT_TIMEOUT}s) — aborting this dispatch." >&2
          printf 'inflight timeout: %ss since claim (agent=%s)\n' "$_age" "$agent" > "$dir/.awaiting-pump"
          rm -f "$req.ready" "$started" 2>/dev/null || true
          return "${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}"
        fi
      fi
    elif [[ -f "$hb" ]]; then
      # Tier A: not yet claimed → pickup timeout against the heartbeat, UNLESS the
      # pump is demonstrably alive and busy on another request (a sibling .started).
      _busy=""
      for _s in "$dir"/req.*.started; do [[ -e "$_s" ]] && { _busy=1; break; }; done
      if [[ -z "$_busy" ]]; then
        _ref="$(stat -c %Y "$hb" 2>/dev/null || stat -f %m "$hb" 2>/dev/null || echo "$_now")"
        _age=$(( _now - _ref ))
        if [[ "$_age" -gt "$CHAIN_PUMP_HEARTBEAT_TIMEOUT" ]]; then
          echo "[interactive-dispatch] pump heartbeat stale (${_age}s > ${CHAIN_PUMP_HEARTBEAT_TIMEOUT}s) and request not picked up — assuming the pump/session stopped; aborting this dispatch." >&2
          printf 'pump heartbeat stale: %ss since last beat (agent=%s)\n' "$_age" "$agent" > "$dir/.awaiting-pump"
          rm -f "$req.ready" 2>/dev/null || true
          return "${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}"
        fi
      fi
    fi
    sleep "$CHAIN_DISPATCH_POLL_SECONDS"
  done

  local rc
  rc="$(cat "$res" 2>/dev/null || echo 1)"
  rm -f "$res" "$req.ready" "$started" 2>/dev/null || true
  [[ "$rc" =~ ^[0-9]+$ ]] || rc=1
  return "$rc"
}

# ── Self-test (run directly: `bash interactive-dispatch.sh --self-test`) ──────
# Drives real round-trips through _interactive_invoke against tiny forked "pumps",
# covering the round-trip AND both timeout tiers. Fast (a few seconds). No-op when
# the file is merely sourced (the BASH_SOURCE guard below). `touch -d` is used to
# back-date markers so aborts fire on the first poll (Linux/GNU coreutils).
_interactive_dispatch_self_test() {
  local fails=0 d rc pump r
  export CHAIN_CURRENT_AGENT="developer"

  # Test 1 — round-trip returns the pump's exit code.
  d="$(mktemp -d)"; export CHAIN_DISPATCH_DIR="$d"; rc=0
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

  # Test 2 — a CLAIMED agent survives a stale heartbeat (THE core fix). With a
  # .started claim marker present, a stale .pump-alive must NOT abort: Tier B's
  # inflight cap governs, not the short pickup timeout. Under the old code this
  # round-trip would have aborted with 70.
  d="$(mktemp -d)"; export CHAIN_DISPATCH_DIR="$d"; rc=0
  CHAIN_PUMP_HEARTBEAT_TIMEOUT=1; CHAIN_DISPATCH_INFLIGHT_TIMEOUT=3600; CHAIN_DISPATCH_POLL_SECONDS=0.2
  ( for _ in $(seq 1 60); do
      r="$(find "$d" -maxdepth 1 -name 'req.*.ready' 2>/dev/null | head -1)"
      if [[ -n "$r" ]]; then
        touch "${r%.ready}.started"                                    # pump claims it
        touch -d '120 seconds ago' "$d/.pump-alive" 2>/dev/null || true # heartbeat already stale
        sleep 0.6                                                       # long agent, no heartbeat refresh
        echo 0 > "${r%.ready}.res"
        break
      fi
      sleep 0.1
    done ) &
  pump=$!
  _interactive_invoke -p "long claimed agent" || rc=$?
  wait "$pump" 2>/dev/null || true
  if [[ "$rc" -eq 0 ]]; then echo "  PASS interactive-dispatch: claimed agent survives stale heartbeat (Tier B)"; else echo "  FAIL interactive-dispatch: claimed agent wrongly aborted (rc=$rc)"; fails=1; fi
  rm -rf "$d"

  # Test 3 — UNCLAIMED request + stale heartbeat → 70 (Tier A pickup abort).
  d="$(mktemp -d)"; export CHAIN_DISPATCH_DIR="$d"; rc=0
  CHAIN_PUMP_HEARTBEAT_TIMEOUT=1; CHAIN_DISPATCH_INFLIGHT_TIMEOUT=3600; CHAIN_DISPATCH_POLL_SECONDS=0.2
  touch -d '120 seconds ago' "$d/.pump-alive" 2>/dev/null || true       # pump never picks up
  _interactive_invoke -p "unclaimed stale" || rc=$?
  if [[ "$rc" -eq "${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}" ]]; then echo "  PASS interactive-dispatch: unclaimed + stale heartbeat → 70 (Tier A)"; else echo "  FAIL interactive-dispatch: pickup-timeout abort (rc=$rc)"; fails=1; fi
  rm -rf "$d"

  # Test 4 — CLAIMED request that exceeds the inflight cap → 70 (Tier B abort).
  d="$(mktemp -d)"; export CHAIN_DISPATCH_DIR="$d"; rc=0
  CHAIN_PUMP_HEARTBEAT_TIMEOUT=3600; CHAIN_DISPATCH_INFLIGHT_TIMEOUT=1; CHAIN_DISPATCH_POLL_SECONDS=0.2
  ( for _ in $(seq 1 60); do
      r="$(find "$d" -maxdepth 1 -name 'req.*.ready' 2>/dev/null | head -1)"
      if [[ -n "$r" ]]; then touch -d '120 seconds ago' "${r%.ready}.started" 2>/dev/null || true; break; fi
      sleep 0.1
    done ) &
  pump=$!
  _interactive_invoke -p "stuck claimed agent" || rc=$?
  wait "$pump" 2>/dev/null || true
  if [[ "$rc" -eq "${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}" ]]; then echo "  PASS interactive-dispatch: claimed + exceeds inflight → 70 (Tier B)"; else echo "  FAIL interactive-dispatch: inflight-timeout abort (rc=$rc)"; fails=1; fi
  rm -rf "$d"

  if [[ "$fails" -eq 0 ]]; then echo "interactive-dispatch self-test: OK"; else echo "interactive-dispatch self-test: FAILED"; fi
  return "$fails"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" && "${1:-}" == "--self-test" ]]; then
  _interactive_dispatch_self_test
  exit $?
fi
