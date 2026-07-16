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
#   _interactive_invoke writes   <dir>/req.XXXXXX.ready = {agent, prompt, cwd, res_path,
#                                out, usage_path, model?}
#   the pump reads it, dispatches subagent_type=<agent> (passing `model` as the
#   Agent tool's model param when present), writes the subagent's final message
#   verbatim to `out` (best-effort), optionally writes a usage sidecar JSON to
#   `usage_path` (protocol v2 — token counts for the dispatch, shaped like the
#   headless stream renderer's sidecar; see skills/goal-interactive-dispatch.md),
#   then writes
#                                <dir>/req.XXXXXX.res   = <exit-code>
#   _interactive_invoke returns that exit code. `out`, `usage_path`, and `model`
#   are optional for older pumps — a pump that ignores them still works (no
#   trace / token telemetry captured, byte-identical pre-v2 behavior).
#
# Request filenames are unique (mktemp), so the concurrent calls produced by
# run-phase.sh's post-dev fanout never collide. This backend never sleeps until
# a quota reset and never returns the quota exit code 75 — interactive quota is
# handled by the pump pausing and the user resuming.
#
# Environment:
#   CHAIN_DISPATCH_DIR            Channel directory (required). Set by run-goal.sh.
#   CHAIN_DISPATCH_POLL_SECONDS   Poll interval while waiting for a result (default 1).
#   CHAIN_DISPATCH_REQUEUE_ON_TIMEOUT  After a Tier B inflight timeout, republish the
#                                 request once before giving up with exit 70 (default
#                                 true). Rescues the "pump became available again"
#                                 case (user Esc'd a wedged Task; late Task return)
#                                 without the AWAITING_PUMP + /goal-resume ceremony.
#                                 A truly dead pump fails the requeue via Tier A fast
#                                 (its heartbeat is already stale by then).
#   Per-agent inflight caps: when quota-retry.sh is sourced (the normal path), the
#   Tier B cap for the current agent resolves via _agent_timeout_for — same
#   precedence as the headless runtime cap. An explicitly exported flat
#   CHAIN_DISPATCH_INFLIGHT_TIMEOUT (or CHAIN_CLAUDE_MAX_RUNTIME_SECONDS) keeps
#   the flat meaning for every agent.

: "${CHAIN_DISPATCH_POLL_SECONDS:=1}"
: "${CHAIN_DISPATCH_REQUEUE_ON_TIMEOUT:=true}"
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
# Explicitness is captured BEFORE the := default so an operator-exported flat
# cap can disable the per-agent timeout table (see _agent_timeout_for in
# quota-retry.sh). Guarded against double-sourcing in the same process.
if [[ -z "${_CHAIN_INFLIGHT_EXPLICIT+x}" ]]; then
  _CHAIN_INFLIGHT_EXPLICIT="${CHAIN_DISPATCH_INFLIGHT_TIMEOUT+set}"
fi
: "${CHAIN_DISPATCH_INFLIGHT_TIMEOUT:=${CHAIN_CLAUDE_MAX_RUNTIME_SECONDS:-7200}}"

# Telemetry: one `dispatch_wait` event per dispatch attempt outcome, splitting
# the invocation into pickup-wait vs run time — this is what makes pump-stall
# cost measurable (analyze_telemetry.py --wall). Uses the caller's dynamically
# scoped locals (agent, _dispatch_start, _claim_epoch). No-op when telemetry
# isn't sourced (phase mode / standalone self-test).
#   $1 status (ok | pickup-timeout | inflight-timeout | inflight-timeout-requeued)
#   $2 rc
_interactive_dispatch_wait_event() {
  declare -F record_telemetry_event >/dev/null 2>&1 || return 0
  local _status="$1" _rc="${2:-}"
  local _now2 _wait _run
  _now2="$(date +%s)"
  if [[ -n "${_claim_epoch:-}" ]]; then
    _wait=$(( _claim_epoch - _dispatch_start ))
    _run=$(( _now2 - _claim_epoch ))
  else
    _wait=$(( _now2 - _dispatch_start ))
    _run=0
  fi
  [[ "$_wait" -lt 0 ]] && _wait=0
  [[ "$_run" -lt 0 ]] && _run=0
  record_telemetry_event "dispatch_wait" "$(jq -cn --arg a "${agent:-unattributed}" --arg s "$_status" \
    --argjson w "$_wait" --argjson r "$_run" --arg rc "$_rc" \
    '{agent:$a, status:$s, wait_seconds:$w, run_seconds:$r, rc:$rc}' 2>/dev/null \
    || printf '{"agent":"%s","status":"%s","wait_seconds":%d,"run_seconds":%d}' \
         "${agent:-unattributed}" "$_status" "$_wait" "$_run")"
}

# A pump usage sidecar is valid when its `.usage` is an object whose four token
# fields are ALL non-negative numbers (strings/negatives/missing keys, or a file
# that isn't JSON at all, are invalid — the caller warns once and skips). Extra
# fields (model, num_turns, duration_ms, ...) are passed through unvalidated,
# mirroring what the headless stream-renderer sidecar carries. jq primary,
# python3 fallback, matching the request-builder's tooling policy.
_interactive_usage_valid() {
  local f="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -e '.usage | type == "object" and
      ([.input_tokens, .output_tokens, .cache_read_input_tokens, .cache_creation_input_tokens]
       | all(type == "number" and . >= 0))' "$f" >/dev/null 2>&1
    return $?
  fi
  python3 - "$f" <<'PYEOF' >/dev/null 2>&1
import json, sys
try:
    u = json.load(open(sys.argv[1])).get("usage")
except Exception:
    sys.exit(1)
ok = isinstance(u, dict) and all(
    isinstance(u.get(k), (int, float)) and not isinstance(u.get(k), bool) and u.get(k) >= 0
    for k in ("input_tokens", "output_tokens",
              "cache_read_input_tokens", "cache_creation_input_tokens"))
sys.exit(0 if ok else 1)
PYEOF
}

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

  # Pump-mode TMPDIR bridge: interactive subagents execute in the PUMP session's
  # environment — the engine's exported TMPDIR never reaches them. Relay it as a
  # prompt instruction instead (the only lever the Task tool offers). Belt and
  # braces: an agent may ignore it; chain_tmp_janitor sweeps whatever still
  # lands in shared /tmp.
  if [[ -n "${CHAIN_TMPDIR:-}" && -d "${CHAIN_TMPDIR:-}" ]]; then
    prompt+=$'\n\n'"Environment note: this pipeline run isolates temp files. Before running tests or any command that writes temporary files, run: export TMPDIR=\"$CHAIN_TMPDIR\" TMP=\"$CHAIN_TMPDIR\" TEMP=\"$CHAIN_TMPDIR\""
  fi

  # Optional per-dispatch model override (escalation ladder / two-key confirm).
  # Empty means "no override — the subagent's frontmatter tier applies".
  local model_override="${CHAIN_MODEL_OVERRIDE:-}"

  # Per-agent inflight cap. Resolved once per dispatch via the shared
  # _agent_timeout_for (quota-retry.sh) so a hung 20-minute reviewer is bounded
  # at its own cap instead of the flat 2h. An operator-exported flat cap (either
  # var) keeps the flat meaning; standalone sourcing (self-test) has no
  # _agent_timeout_for and silently keeps the flat cap.
  local _inflight_cap="${CHAIN_DISPATCH_INFLIGHT_TIMEOUT:-7200}"
  local _flat_explicit=""
  if [[ "${_CHAIN_INFLIGHT_EXPLICIT:-}" == "set" || "${_CHAIN_RUNTIME_EXPLICIT:-}" == "set" ]]; then
    _flat_explicit="set"
  fi
  if declare -F _agent_timeout_for >/dev/null 2>&1; then
    local _agent_cap
    _agent_cap="$(_agent_timeout_for "$_flat_explicit")"
    [[ -n "$_agent_cap" ]] && _inflight_cap="$_agent_cap"
  fi

  local req res out usage_f
  local _requeued=""
  local _dispatch_start _claim_epoch hb started _now _ref _age _busy _s
  # Dispatch-attempt loop: normally one pass; a Tier B inflight timeout may
  # republish the request ONCE (fresh req/res paths — the pump reads res_path
  # from the JSON, so a requeue must mint new ones) before giving up with 70.
  while :; do
    _claim_epoch=""
    req="$(mktemp "$dir/req.XXXXXX")"
    res="$req.res"
    out="$req.out"
    usage_f="$req.usage"

    # Build the request JSON. jq handles arbitrary prompt content (quotes,
    # newlines, large prompts) safely; python3 is the fallback.
    if command -v jq >/dev/null 2>&1; then
      jq -cn --arg a "$agent" --arg p "$prompt" --arg c "$PWD" --arg r "$res" \
        --arg o "$out" --arg u "$usage_f" --arg m "$model_override" \
        '{agent:$a, prompt:$p, cwd:$c, res_path:$r, out:$o, usage_path:$u}
         + (if $m != "" then {model:$m} else {} end)' > "$req"
    else
      _ID_A="$agent" _ID_P="$prompt" _ID_C="$PWD" _ID_R="$res" _ID_O="$out" _ID_U="$usage_f" _ID_M="$model_override" python3 -c \
        'import json,os; d={"agent":os.environ["_ID_A"],"prompt":os.environ["_ID_P"],"cwd":os.environ["_ID_C"],"res_path":os.environ["_ID_R"],"out":os.environ["_ID_O"],"usage_path":os.environ["_ID_U"]};
m=os.environ.get("_ID_M","");
d.update({"model":m} if m else {});
print(json.dumps(d))' > "$req"
    fi

    _dispatch_start="$(date +%s)"

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
    #     Tier A deliberately never requeues: an unclaimed request + dead heartbeat
    #     means nothing exists to service a requeue — resume regenerates it anyway.
    #
    #   Tier B — INFLIGHT (this request claimed: goal-await-dispatch.sh touched
    #     <req>.started when it handed the request to the pump). The pump is actively
    #     running the subagent, so bound it ONLY by the per-agent inflight cap
    #     (from the .started mtime; 0 = unlimited). This is what stops a legitimately
    #     long agent — e.g. the developer's INITIAL BUILD, routinely > 30 min — from
    #     being mistaken for a dead pump.
    hb="$dir/.pump-alive"
    started="$req.started"
    while [[ ! -f "$res" ]]; do
      _now="$(date +%s)"
      if [[ -f "$started" ]]; then
        if [[ -z "$_claim_epoch" ]]; then
          _claim_epoch="$(stat -c %Y "$started" 2>/dev/null || stat -f %m "$started" 2>/dev/null || echo "$_now")"
        fi
        # Tier B: claimed → inflight cap measured from the claim time.
        if [[ "$_inflight_cap" -gt 0 ]]; then
          _ref="$(stat -c %Y "$started" 2>/dev/null || stat -f %m "$started" 2>/dev/null || echo "$_now")"
          _age=$(( _now - _ref ))
          if [[ "$_age" -gt "$_inflight_cap" ]]; then
            rm -f "$req.ready" "$started" "$usage_f" 2>/dev/null || true
            if [[ -z "$_requeued" && "${CHAIN_DISPATCH_REQUEUE_ON_TIMEOUT:-true}" == "true" ]]; then
              _requeued=1
              echo "[interactive-dispatch] claimed agent '$agent' exceeded inflight timeout (${_age}s > ${_inflight_cap}s) — requeueing once before giving up." >&2
              _interactive_dispatch_wait_event "inflight-timeout-requeued" ""
              continue 2
            fi
            echo "[interactive-dispatch] claimed agent '$agent' exceeded inflight timeout (${_age}s > ${_inflight_cap}s) — aborting this dispatch." >&2
            printf 'inflight timeout: %ss since claim (agent=%s)\n' "$_age" "$agent" > "$dir/.awaiting-pump"
            _interactive_dispatch_wait_event "inflight-timeout" "${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}"
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
            _interactive_dispatch_wait_event "pickup-timeout" "${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}"
            return "${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}"
          fi
        fi
      fi
      sleep "$CHAIN_DISPATCH_POLL_SECONDS"
    done
    break
  done

  local rc
  rc="$(cat "$res" 2>/dev/null || echo 1)"
  [[ "$rc" =~ ^[0-9]+$ ]] || rc=1

  # A fast pump can claim + answer between polls — recover the claim time from
  # the .started marker (still on disk until the cleanup below) for telemetry.
  if [[ -z "$_claim_epoch" && -f "$started" ]]; then
    _claim_epoch="$(stat -c %Y "$started" 2>/dev/null || stat -f %m "$started" 2>/dev/null || echo "")"
  fi
  _interactive_dispatch_wait_event "ok" "$rc"

  # Usage sidecar (protocol v2, best-effort). A v2 pump writes per-dispatch
  # token counts to $usage_f BEFORE $res, shaped like the headless stream
  # renderer's $CHAIN_CLAUDE_USAGE_SIDECAR — so the SAME telemetry helper
  # emits the same claude_usage event (agent attribution included) and the
  # trace recorder spreads it, with no analyzer changes. Absent file = pre-v2
  # pump = today's behavior. Malformed content: one warn, skip, never fatal.
  local _usage_sidecar=""
  if [[ -s "$usage_f" ]]; then
    if _interactive_usage_valid "$usage_f"; then
      _usage_sidecar="$usage_f"
      if declare -F record_claude_usage_from_sidecar >/dev/null 2>&1; then
        record_claude_usage_from_sidecar "$usage_f" || true
      fi
    else
      echo "[interactive-dispatch] agent '$agent' returned a malformed usage sidecar — skipping token telemetry for this dispatch." >&2
    fi
  fi

  # Trace capture (best-effort). The pump writes the subagent's final message
  # to $out before $res; older pumps don't — record a stub so the invocation
  # is still attributed. Model attribution: the explicit override if set, else
  # the frontmatter model the subagent inherits (a model in the validated usage
  # sidecar wins in the trace merge, same as headless).
  if [[ -n "${CHAIN_TRACE_DIR:-}" ]] && declare -F _trace_record_invocation >/dev/null 2>&1; then
    local _dur=$(( $(date +%s) - _dispatch_start ))
    local _out_for_trace="$out"
    if [[ ! -f "$out" ]]; then
      _out_for_trace="$(mktemp)"
      printf '[interactive] pump did not write an output transcript for this dispatch (agent=%s)\n' "$agent" > "$_out_for_trace"
    fi
    if [[ -n "$model_override" ]]; then
      _CHAIN_TRACE_MODEL="$model_override"
    else
      _CHAIN_TRACE_MODEL="$(python3 "$(dirname "${BASH_SOURCE[0]}")/agent_permissions.py" model "$agent" 2>/dev/null || true)"
    fi
    _CHAIN_TRACE_EFFORT=""   # effort is not applied on the interactive path
    _trace_record_invocation "$_out_for_trace" "$_usage_sidecar" "$_dur" "$rc" "$@" || true
    [[ "$_out_for_trace" != "$out" ]] && rm -f "$_out_for_trace" 2>/dev/null || true
    _CHAIN_TRACE_MODEL=""
  fi

  rm -f "$res" "$req.ready" "$started" "$out" "$usage_f" 2>/dev/null || true
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
  # Requeue disabled here to test the pure abort path; Tests 6-8 cover requeue.
  d="$(mktemp -d)"; export CHAIN_DISPATCH_DIR="$d"; rc=0
  CHAIN_PUMP_HEARTBEAT_TIMEOUT=3600; CHAIN_DISPATCH_INFLIGHT_TIMEOUT=1; CHAIN_DISPATCH_POLL_SECONDS=0.2
  CHAIN_DISPATCH_REQUEUE_ON_TIMEOUT=false
  ( for _ in $(seq 1 60); do
      r="$(find "$d" -maxdepth 1 -name 'req.*.ready' 2>/dev/null | head -1)"
      if [[ -n "$r" ]]; then touch -d '120 seconds ago' "${r%.ready}.started" 2>/dev/null || true; break; fi
      sleep 0.1
    done ) &
  pump=$!
  _interactive_invoke -p "stuck claimed agent" || rc=$?
  wait "$pump" 2>/dev/null || true
  CHAIN_DISPATCH_REQUEUE_ON_TIMEOUT=true
  if [[ "$rc" -eq "${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}" ]]; then echo "  PASS interactive-dispatch: claimed + exceeds inflight → 70 (Tier B)"; else echo "  FAIL interactive-dispatch: inflight-timeout abort (rc=$rc)"; fails=1; fi
  rm -rf "$d"

  # Test 5 — request JSON carries `out` (+ `model` when CHAIN_MODEL_OVERRIDE is
  # set); when the pump writes the out file, the invoke records a trace via
  # _trace_record_invocation (stubbed here — the real recorder is exercised by
  # tests/automation/test-quota-retry.sh).
  d="$(mktemp -d)"; export CHAIN_DISPATCH_DIR="$d"; rc=0
  local trace_d; trace_d="$(mktemp -d)"; export CHAIN_TRACE_DIR="$trace_d"
  export CHAIN_MODEL_OVERRIDE="claude-test-override"
  _trace_record_invocation() {  # stub: record what we were handed
    printf '%s|%s|%s\n' "${CHAIN_CURRENT_AGENT:-}" "${_CHAIN_TRACE_MODEL:-}" "$(cat "$1" 2>/dev/null | head -1)" >> "$CHAIN_TRACE_DIR/stub-trace.log"
  }
  ( for _ in $(seq 1 50); do
      r="$(find "$d" -maxdepth 1 -name 'req.*.ready' 2>/dev/null | head -1)"
      if [[ -n "$r" ]]; then
        if grep -q '"out"' "$r" && grep -q '"model":"claude-test-override"' "$r"; then
          o="$(sed -n 's/.*"out":"\([^"]*\)".*/\1/p' "$r")"
          [[ -n "$o" ]] && printf 'final message from subagent\n' > "$o"
          echo 0 > "${r%.ready}.res"
        else
          echo 9 > "${r%.ready}.res"   # fields missing → fail the test via rc
        fi
        break
      fi
      sleep 0.1
    done ) &
  pump=$!
  CHAIN_DISPATCH_POLL_SECONDS=0.2 CHAIN_PUMP_HEARTBEAT_TIMEOUT=3600 _interactive_invoke -p "trace capture test" || rc=$?
  wait "$pump" 2>/dev/null || true
  unset CHAIN_MODEL_OVERRIDE
  unset -f _trace_record_invocation
  if [[ "$rc" -eq 0 ]] && grep -q '^developer|claude-test-override|final message' "$trace_d/stub-trace.log" 2>/dev/null; then
    echo "  PASS interactive-dispatch: out+model in request; trace recorded from pump output"
  else
    echo "  FAIL interactive-dispatch: trace capture (rc=$rc, stub=$(cat "$trace_d/stub-trace.log" 2>/dev/null || echo missing))"; fails=1
  fi
  rm -rf "$d" "$trace_d"; unset CHAIN_TRACE_DIR

  # Test 6 — per-agent inflight cap (via a stubbed _agent_timeout_for) tightens
  # a huge flat cap: the claimed request must abort at the AGENT cap, not 3600s.
  d="$(mktemp -d)"; export CHAIN_DISPATCH_DIR="$d"; rc=0
  CHAIN_PUMP_HEARTBEAT_TIMEOUT=3600; CHAIN_DISPATCH_INFLIGHT_TIMEOUT=3600; CHAIN_DISPATCH_POLL_SECONDS=0.2
  CHAIN_DISPATCH_REQUEUE_ON_TIMEOUT=false
  _agent_timeout_for() { printf '1'; }   # stub: reviewer-style tight cap
  ( for _ in $(seq 1 60); do
      r="$(find "$d" -maxdepth 1 -name 'req.*.ready' 2>/dev/null | head -1)"
      if [[ -n "$r" ]]; then touch -d '120 seconds ago' "${r%.ready}.started" 2>/dev/null || true; break; fi
      sleep 0.1
    done ) &
  pump=$!
  _interactive_invoke -p "per-agent capped agent" || rc=$?
  wait "$pump" 2>/dev/null || true
  unset -f _agent_timeout_for
  CHAIN_DISPATCH_REQUEUE_ON_TIMEOUT=true
  if [[ "$rc" -eq "${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}" ]]; then echo "  PASS interactive-dispatch: per-agent cap tightens the flat inflight cap"; else echo "  FAIL interactive-dispatch: per-agent cap (rc=$rc)"; fails=1; fi
  rm -rf "$d"

  # Test 7 — requeue round-trip: the first claimed request wedges past the cap;
  # the invoke republishes ONCE and the pump answers the second request → rc 0,
  # and no .awaiting-pump marker is left behind.
  d="$(mktemp -d)"; export CHAIN_DISPATCH_DIR="$d"; rc=0
  CHAIN_PUMP_HEARTBEAT_TIMEOUT=3600; CHAIN_DISPATCH_INFLIGHT_TIMEOUT=1; CHAIN_DISPATCH_POLL_SECONDS=0.2
  touch "$d/.pump-alive"
  ( first=""
    for _ in $(seq 1 60); do
      r="$(find "$d" -maxdepth 1 -name 'req.*.ready' 2>/dev/null | head -1)"
      if [[ -n "$r" ]]; then touch -d '120 seconds ago' "${r%.ready}.started" 2>/dev/null || true; first="$r"; break; fi
      sleep 0.1
    done
    for _ in $(seq 1 100); do
      r2="$(find "$d" -maxdepth 1 -name 'req.*.ready' 2>/dev/null | grep -v -F "$first" | head -1)"
      if [[ -n "$r2" ]]; then echo 0 > "${r2%.ready}.res"; break; fi
      sleep 0.1
    done ) &
  pump=$!
  _interactive_invoke -p "requeue rescue" || rc=$?
  wait "$pump" 2>/dev/null || true
  if [[ "$rc" -eq 0 && ! -f "$d/.awaiting-pump" ]]; then
    echo "  PASS interactive-dispatch: Tier B timeout → requeue → second request served (rc 0)"
  else
    echo "  FAIL interactive-dispatch: requeue round-trip (rc=$rc, marker=$([[ -f "$d/.awaiting-pump" ]] && echo present || echo absent))"; fails=1
  fi
  rm -rf "$d"

  # Test 8 — requeue then dead pump: first request wedges past the cap, the
  # requeued request is never picked up and the heartbeat is stale → Tier A → 70.
  d="$(mktemp -d)"; export CHAIN_DISPATCH_DIR="$d"; rc=0
  CHAIN_PUMP_HEARTBEAT_TIMEOUT=1; CHAIN_DISPATCH_INFLIGHT_TIMEOUT=1; CHAIN_DISPATCH_POLL_SECONDS=0.2
  touch -d '120 seconds ago' "$d/.pump-alive" 2>/dev/null || true
  ( for _ in $(seq 1 60); do
      r="$(find "$d" -maxdepth 1 -name 'req.*.ready' 2>/dev/null | head -1)"
      if [[ -n "$r" ]]; then touch -d '120 seconds ago' "${r%.ready}.started" 2>/dev/null || true; break; fi
      sleep 0.1
    done ) &
  pump=$!
  _interactive_invoke -p "requeue into dead pump" || rc=$?
  wait "$pump" 2>/dev/null || true
  if [[ "$rc" -eq "${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}" ]]; then echo "  PASS interactive-dispatch: requeue into dead pump → 70 via Tier A"; else echo "  FAIL interactive-dispatch: requeue-then-dead (rc=$rc)"; fails=1; fi
  rm -rf "$d"

  # Tests 9-12 — TOKEN-5 usage sidecar. Source the real telemetry lib (restoring
  # shell options afterwards: telemetry.sh sets -u, the self-test predates it) so
  # the engine-side emit path runs for real and lands in telemetry.jsonl.
  local _old_opts; _old_opts="$(set +o)"
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/telemetry.sh"
  eval "$_old_opts" 2>/dev/null || true
  export GOAL_SESSION_ID="td-usage-test"

  # Test 9 — pump writes a valid usage sidecar to the request's usage_path →
  # one claude_usage telemetry event with the dispatching agent + exact numbers,
  # the trace recorder is handed that sidecar (not ""), and the sidecar file is
  # cleaned up with the channel files.
  d="$(mktemp -d)"; export CHAIN_DISPATCH_DIR="$d"; rc=0
  local td9; td9="$(mktemp -d)"; export GOAL_SESSION_DIR="$td9"
  local trace9; trace9="$(mktemp -d)"; export CHAIN_TRACE_DIR="$trace9"
  _trace_record_invocation() {  # stub: capture the sidecar arg while it is live
    [[ -n "${2:-}" && -s "${2:-/nonexistent}" ]] && cp "$2" "$CHAIN_TRACE_DIR/sidecar-as-seen.json" 2>/dev/null
  }
  CHAIN_PUMP_HEARTBEAT_TIMEOUT=3600 CHAIN_DISPATCH_INFLIGHT_TIMEOUT=3600
  ( for _ in $(seq 1 50); do
      r="$(find "$d" -maxdepth 1 -name 'req.*.ready' 2>/dev/null | head -1)"
      if [[ -n "$r" ]]; then
        u="$(sed -n 's/.*"usage_path":"\([^"]*\)".*/\1/p' "$r")"
        if [[ -n "$u" ]]; then
          printf '{"model":"claude-test-usage","num_turns":7,"duration_ms":4200,"usage":{"input_tokens":111,"output_tokens":222,"cache_read_input_tokens":333,"cache_creation_input_tokens":44}}\n' > "$u"
          echo 0 > "${r%.ready}.res"
        else
          echo 9 > "${r%.ready}.res"   # usage_path missing from request JSON
        fi
        break
      fi
      sleep 0.1
    done ) &
  pump=$!
  CHAIN_DISPATCH_POLL_SECONDS=0.2 _interactive_invoke -p "usage sidecar test" || rc=$?
  wait "$pump" 2>/dev/null || true
  unset -f _trace_record_invocation
  local _urow
  _urow="$(jq -c 'select(.event=="claude_usage")' "$td9/telemetry.jsonl" 2>/dev/null | head -1)"
  if [[ "$rc" -eq 0 && -n "$_urow" ]] \
     && [[ "$(printf '%s' "$_urow" | jq -r '.agent')" == "developer" ]] \
     && [[ "$(printf '%s' "$_urow" | jq -r '.usage.output_tokens')" == "222" ]] \
     && [[ "$(printf '%s' "$_urow" | jq -r '.usage.cache_creation_input_tokens')" == "44" ]] \
     && [[ "$(printf '%s' "$_urow" | jq -r '.model')" == "claude-test-usage" ]] \
     && grep -q '"output_tokens":222' "$trace9/sidecar-as-seen.json" 2>/dev/null \
     && ! find "$d" -maxdepth 1 -name 'req.*.usage' 2>/dev/null | grep -q .; then
    echo "  PASS interactive-dispatch: valid usage sidecar → claude_usage event (agent+numbers) + trace sidecar + cleanup"
  else
    echo "  FAIL interactive-dispatch: usage sidecar emit (rc=$rc, row=${_urow:-missing}, trace=$(cat "$trace9/sidecar-as-seen.json" 2>/dev/null || echo missing))"; fails=1
  fi
  rm -rf "$d" "$trace9"; unset CHAIN_TRACE_DIR

  # Test 10 — no usage sidecar written (an older pump): byte-identical behavior,
  # no claude_usage event, no usage warning on stderr.
  d="$(mktemp -d)"; export CHAIN_DISPATCH_DIR="$d"; rc=0
  local td10; td10="$(mktemp -d)"; export GOAL_SESSION_DIR="$td10"
  local err10; err10="$(mktemp)"
  ( for _ in $(seq 1 50); do
      r="$(find "$d" -maxdepth 1 -name 'req.*.ready' 2>/dev/null | head -1)"
      if [[ -n "$r" ]]; then echo 0 > "${r%.ready}.res"; break; fi
      sleep 0.1
    done ) &
  pump=$!
  CHAIN_DISPATCH_POLL_SECONDS=0.2 _interactive_invoke -p "no usage sidecar" 2>"$err10" || rc=$?
  wait "$pump" 2>/dev/null || true
  if [[ "$rc" -eq 0 ]] \
     && ! grep -q 'claude_usage' "$td10/telemetry.jsonl" 2>/dev/null \
     && ! grep -q 'usage' "$err10"; then
    echo "  PASS interactive-dispatch: absent usage sidecar → no event, no warnings, rc flows"
  else
    echo "  FAIL interactive-dispatch: absent-sidecar path (rc=$rc, stderr=$(cat "$err10"))"; fails=1
  fi
  rm -rf "$d" "$td10"; rm -f "$err10"

  # Test 11 — malformed usage sidecars (string tokens; negative tokens) are
  # tolerated loudly: no claude_usage event, exactly ONE warn line per dispatch,
  # exit code still flows (never a crash).
  local _bad _n=0
  for _bad in \
    '{"usage":{"input_tokens":"abc","output_tokens":222,"cache_read_input_tokens":333,"cache_creation_input_tokens":44}}' \
    '{"usage":{"input_tokens":111,"output_tokens":-5,"cache_read_input_tokens":333,"cache_creation_input_tokens":44}}'; do
    _n=$((_n+1))
    d="$(mktemp -d)"; export CHAIN_DISPATCH_DIR="$d"; rc=0
    local td11; td11="$(mktemp -d)"; export GOAL_SESSION_DIR="$td11"
    local err11; err11="$(mktemp)"
    ( for _ in $(seq 1 50); do
        r="$(find "$d" -maxdepth 1 -name 'req.*.ready' 2>/dev/null | head -1)"
        if [[ -n "$r" ]]; then
          u="$(sed -n 's/.*"usage_path":"\([^"]*\)".*/\1/p' "$r")"
          [[ -n "$u" ]] && printf '%s\n' "$_bad" > "$u"
          echo 0 > "${r%.ready}.res"
          break
        fi
        sleep 0.1
      done ) &
    pump=$!
    CHAIN_DISPATCH_POLL_SECONDS=0.2 _interactive_invoke -p "malformed usage $_n" 2>"$err11" || rc=$?
    wait "$pump" 2>/dev/null || true
    if [[ "$rc" -eq 0 ]] \
       && ! grep -q 'claude_usage' "$td11/telemetry.jsonl" 2>/dev/null \
       && [[ "$(grep -c 'malformed usage' "$err11")" == "1" ]]; then
      echo "  PASS interactive-dispatch: malformed usage sidecar #$_n → skipped with one warn, rc flows"
    else
      echo "  FAIL interactive-dispatch: malformed usage #$_n (rc=$rc, warns=$(grep -c 'malformed usage' "$err11" 2>/dev/null), stderr=$(cat "$err11"))"; fails=1
    fi
    rm -rf "$d" "$td11"; rm -f "$err11"
  done

  # Test 12 — analyze_telemetry.py aggregates the pump-emitted row (Test 9's
  # telemetry.jsonl) alongside a hand-built headless-shaped row with NO analyzer
  # changes: per-agent buckets and totals come out right.
  printf '%s\n' '{"ts":"2026-07-16T00:00:00Z","session_id":"td-usage-test","iter":1,"event":"claude_usage","cli":"claude","agent":"reviewer","model":"claude-sonnet-5","num_turns":3,"duration_ms":1000,"total_cost_usd":0.01,"is_error":false,"usage":{"input_tokens":500,"output_tokens":100,"cache_read_input_tokens":4000,"cache_creation_input_tokens":0}}' >> "$td9/telemetry.jsonl"
  local _agg
  _agg="$(python3 "$(dirname "${BASH_SOURCE[0]}")/analyze_telemetry.py" --json "$td9/telemetry.jsonl" 2>/dev/null)"
  if [[ -n "$_agg" ]] \
     && [[ "$(printf '%s' "$_agg" | jq -r '.["td-usage-test"].by_agent.developer["gen_ai.usage.output_tokens"]')" == "222" ]] \
     && [[ "$(printf '%s' "$_agg" | jq -r '.["td-usage-test"].by_agent.reviewer["gen_ai.usage.output_tokens"]')" == "100" ]] \
     && [[ "$(printf '%s' "$_agg" | jq -r '.["td-usage-test"].total.invocations')" == "2" ]] \
     && [[ "$(printf '%s' "$_agg" | jq -r '.["td-usage-test"].by_model["claude-test-usage"]["gen_ai.usage.input_tokens"]')" == "111" ]]; then
    echo "  PASS interactive-dispatch: analyze_telemetry aggregates mixed pump+headless rows unchanged"
  else
    echo "  FAIL interactive-dispatch: analyzer mixed-fixture aggregation (got: $(printf '%s' "$_agg" | head -c 300))"; fails=1
  fi
  rm -rf "$td9"
  unset GOAL_SESSION_DIR GOAL_SESSION_ID

  if [[ "$fails" -eq 0 ]]; then echo "interactive-dispatch self-test: OK"; else echo "interactive-dispatch self-test: FAILED"; fi
  return "$fails"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" && "${1:-}" == "--self-test" ]]; then
  _interactive_dispatch_self_test
  exit $?
fi
