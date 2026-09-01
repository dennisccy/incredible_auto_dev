#!/usr/bin/env bash
# goal-await-dispatch.sh — pump-side helper for the interactive dispatch backend.
#
# The "pump" is the foreground Claude Code session running /goal. It launches the
# goal-mode engine (run-goal.sh --interactive) in the background, then repeatedly
# calls this helper. Each call BLOCKS until either:
#   - one or more UNANSWERED requests are published in the dispatch dir, in which
#     case it prints their file paths (one per line) and exits 0; or
#   - the engine process has exited and nothing is left to service, in which case
#     it prints "ENGINE_DONE" and exits 0.
#
# Each poll touches the pump heartbeat (.pump-alive) so the engine's
# _interactive_invoke (lib/interactive-dispatch.sh) knows the pump is alive and
# does not abort dispatches while the pump is merely waiting.
#
# The pump then, for each printed request path R:
#   - reads R (JSON: {agent, prompt, cwd, res_path, out, usage_path, model?})
#   - dispatches subagent_type=<agent> with <prompt> verbatim (no model override)
#   - writes the final message to `out`, optionally a usage sidecar to
#     `usage_path` (protocol v2 token telemetry), then the subagent's exit code
#     to "${R%.ready}.res" (always last — it is the completion signal)
# and calls this helper again. See skills/goal-interactive-dispatch.md.
#
# Usage:
#   goal-await-dispatch.sh --dispatch-dir <dir> --engine-pid <pid> [--poll <secs>]
#                          [--max-wait <secs>] [--print-json]
#                          [--finish <req.ready>=<agent>=<rc>]...   (protocol v4)
#   goal-await-dispatch.sh --self-test
set -euo pipefail

# ── Self-test (no engine, no blocking) ────────────────────────────────────────
if [[ "${1:-}" == "--self-test" ]]; then
  t=$(mktemp -d); fails=0
  # A guaranteed-dead pid: spawn a no-op, reap it.
  ( exit 0 ) & deadpid=$!; wait "$deadpid" 2>/dev/null || true

  # Scenario 1: engine gone, nothing pending → ENGINE_DONE
  out=$("$0" --dispatch-dir "$t" --engine-pid "$deadpid" --poll 1 2>/dev/null || true)
  if [[ "$out" == "ENGINE_DONE" ]]; then echo "  PASS await: engine-done → ENGINE_DONE"; else echo "  FAIL await: engine-done (got '$out')"; fails=1; fi

  # Scenario 2: an unanswered ready request is listed
  r="$t/req.aaaaaa.ready"; printf '{"agent":"developer","prompt":"x"}\n' > "$r"
  out=$("$0" --dispatch-dir "$t" --engine-pid "$$" --poll 1 2>/dev/null || true)
  if [[ "$out" == "$r" ]]; then echo "  PASS await: lists unanswered request"; else echo "  FAIL await: lists pending (got '$out')"; fails=1; fi

  # Scenario 2b: listing a request writes its .started claim marker.
  if [[ -f "${r%.ready}.started" ]]; then echo "  PASS await: claim marker (.started) written when handed to pump"; else echo "  FAIL await: no .started claim marker"; fails=1; fi

  # Scenario 3: an ALREADY-answered ready request (has a .res sibling) is skipped,
  # so with the engine gone it reports ENGINE_DONE rather than re-listing it.
  echo 0 > "${r%.ready}.res"
  out=$("$0" --dispatch-dir "$t" --engine-pid "$deadpid" --poll 1 2>/dev/null || true)
  if [[ "$out" == "ENGINE_DONE" ]]; then echo "  PASS await: skips already-answered request"; else echo "  FAIL await: skips answered (got '$out')"; fails=1; fi

  # Scenario 4: live engine, no UNANSWERED request (the one from scenario 2 now
  # has a .res), and --max-wait elapses → WAITING. Also proves --max-wait is a
  # recognized arg (not "Unknown argument").
  out=$("$0" --dispatch-dir "$t" --engine-pid "$$" --poll 1 --max-wait 1 2>/dev/null || true)
  if [[ "$out" == "WAITING" ]]; then echo "  PASS await: --max-wait elapsed → WAITING"; else echo "  FAIL await: max-wait (got '$out')"; fails=1; fi

  # Scenario 5: a claimed-but-unanswered request (.started present, no .res) is
  # NOT re-listed → no double-dispatch; with a live engine + --max-wait → WAITING.
  r2="$t/req.bbbbbb.ready"; printf '{"agent":"developer","prompt":"y"}\n' > "$r2"; touch "${r2%.ready}.started"
  out=$("$0" --dispatch-dir "$t" --engine-pid "$$" --poll 1 --max-wait 1 2>/dev/null || true)
  if [[ "$out" == "WAITING" ]]; then echo "  PASS await: claimed-unanswered request not re-listed (no double-dispatch)"; else echo "  FAIL await: re-listed claimed request (got '$out')"; fails=1; fi

  # Heartbeat file is created.
  if [[ -f "$t/.pump-alive" ]]; then echo "  PASS await: touches pump heartbeat"; else echo "  FAIL await: no heartbeat"; fails=1; fi

  # Scenario 6 (REL-3, protocol v3): with a resolvable pump pid (CHAIN_PUMP_PID
  # seam), the claim marker AND the heartbeat carry pid/host(/starttime) so the
  # engine can kill -0 the pump during a claimed dispatch.
  t6=$(mktemp -d)
  r6="$t6/req.cccccc.ready"; printf '{"agent":"developer","prompt":"z"}\n' > "$r6"
  out=$(CHAIN_PUMP_PID="$$" "$0" --dispatch-dir "$t6" --engine-pid "$$" --poll 1 2>/dev/null || true)
  stt="$(sed 's/.*) //' "/proc/$$/stat" 2>/dev/null | awk '{print $20}')"
  if grep -q "^pid=$$\$" "${r6%.ready}.started" 2>/dev/null \
     && grep -q "^host=$(hostname)\$" "${r6%.ready}.started" 2>/dev/null \
     && grep -q "^starttime=${stt}\$" "${r6%.ready}.started" 2>/dev/null; then
    echo "  PASS await: claim marker carries pid+host+starttime (protocol v3)"
  else
    echo "  FAIL await: claim marker ident (got: $(tr '\n' ' ' < "${r6%.ready}.started" 2>/dev/null || echo empty))"; fails=1
  fi
  if grep -q "^pid=$$\$" "$t6/.pump-alive" 2>/dev/null; then
    echo "  PASS await: heartbeat carries the pump ident"
  else
    echo "  FAIL await: heartbeat ident (got: $(tr '\n' ' ' < "$t6/.pump-alive" 2>/dev/null || echo empty))"; fails=1
  fi
  rm -rf "$t6"

  # Scenario 7 (REL-3): resolution DISABLED (CHAIN_PUMP_PID set empty — the
  # old-format seam): claim marker and heartbeat stay contentless, exactly the
  # pre-v3 files an old engine expects.
  t7=$(mktemp -d)
  r7="$t7/req.dddddd.ready"; printf '{"agent":"developer","prompt":"w"}\n' > "$r7"
  out=$(CHAIN_PUMP_PID="" "$0" --dispatch-dir "$t7" --engine-pid "$$" --poll 1 2>/dev/null || true)
  if [[ -f "${r7%.ready}.started" && ! -s "${r7%.ready}.started" && ! -s "$t7/.pump-alive" ]]; then
    echo "  PASS await: ident disabled → contentless claim + heartbeat (pre-v3 format)"
  else
    echo "  FAIL await: disabled ident leaked content (started: $(wc -c < "${r7%.ready}.started" 2>/dev/null || echo missing)B, hb: $(wc -c < "$t7/.pump-alive" 2>/dev/null || echo missing)B)"; fails=1
  fi
  rm -rf "$t7"

  # ── Protocol v4 (TOKEN-11a): finish-in-await ────────────────────────────────
  # `--finish <req.ready>=<agent>=<rc>` completes a dispatch BEFORE blocking:
  # the subagent's final message and usage come from the pump session's own
  # transcript (the same lookup the v2 usage recipe used), `out` and `usage_path`
  # are written, then `.res` LAST. The pump never re-emits a prompt or a reply.
  t8=$(mktemp -d); fh="$t8/home"; sid="sess-v4"
  mkdir -p "$fh/.claude/projects/-slug/$sid/subagents"
  # Pump transcript: the Agent tool_result row carrying the subagent attribution.
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"done"}]},"toolUseResult":{"agentId":"x1","agentType":"developer","resolvedModel":"claude-sonnet-5","totalDurationMs":1234,"prompt":"You are the developer agent for goal-mode lean iteration."}}' \
    > "$fh/.claude/projects/-slug/$sid.jsonl"
  # Subagent transcript: two messages, the second repeated as a streaming
  # snapshot (LAST row wins: output 25, not 20+25).
  {
    printf '%s\n' '{"type":"assistant","message":{"id":"d1","model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":5},"content":[{"type":"text","text":"working"}]}}'
    printf '%s\n' '{"type":"assistant","message":{"id":"d2","model":"claude-sonnet-5","usage":{"input_tokens":2,"output_tokens":20,"cache_read_input_tokens":200,"cache_creation_input_tokens":6},"content":[{"type":"text","text":"Handoff written to docs/handoffs/dev.md"}]}}'
    printf '%s\n' '{"type":"assistant","message":{"id":"d2","model":"claude-sonnet-5","usage":{"input_tokens":2,"output_tokens":25,"cache_read_input_tokens":200,"cache_creation_input_tokens":6},"content":[{"type":"text","text":"Handoff written to docs/handoffs/dev.md (final)"}]}}'
  } > "$fh/.claude/projects/-slug/$sid/subagents/agent-x1.jsonl"
  r8="$t8/req.5-cccccc.ready"
  printf '{"agent":"developer","prompt":"You are the developer agent for goal-mode lean iteration.","cwd":"/x","res_path":"%s","out":"%s","usage_path":"%s"}\n' \
    "$t8/req.5-cccccc.res" "$t8/req.5-cccccc.out" "$t8/req.5-cccccc.usage" > "$r8"
  out=$(HOME="$fh" CLAUDE_CODE_SESSION_ID="$sid" "$0" --dispatch-dir "$t8" --engine-pid "$deadpid" --poll 1 --finish "$r8=developer=0" 2>/dev/null || true)
  if [[ "$out" == "ENGINE_DONE" ]]; then echo "  PASS finish: still awaits after finishing (ENGINE_DONE with a dead engine)"; else echo "  FAIL finish: await after finish (got '$out')"; fails=1; fi
  if [[ "$(cat "$t8/req.5-cccccc.res" 2>/dev/null)" == "0" ]]; then echo "  PASS finish: .res written with the exit code"; else echo "  FAIL finish: .res missing/wrong ($(cat "$t8/req.5-cccccc.res" 2>/dev/null))"; fails=1; fi
  if [[ "$(cat "$t8/req.5-cccccc.out" 2>/dev/null)" == "Handoff written to docs/handoffs/dev.md (final)" ]]; then echo "  PASS finish: out = subagent's final message from its transcript"; else echo "  FAIL finish: out content ($(cat "$t8/req.5-cccccc.out" 2>/dev/null))"; fails=1; fi
  u8="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); u=d["usage"]; print(d["model"], d["num_turns"], d["duration_ms"], u["input_tokens"], u["output_tokens"], u["cache_read_input_tokens"], u["cache_creation_input_tokens"])' "$t8/req.5-cccccc.usage" 2>/dev/null || true)"
  if [[ "$u8" == "claude-sonnet-5 2 1234 3 35 300 11" ]]; then echo "  PASS finish: usage sidecar summed with snapshot dedupe (last row wins)"; else echo "  FAIL finish: usage sidecar (got '$u8')"; fails=1; fi
  # Missing transcript → stub out, NO usage (honesty rule), .res still written (rc passthrough).
  r9="$t8/req.5-dddddd.ready"
  printf '{"agent":"reviewer","prompt":"p","cwd":"/x","res_path":"%s","out":"%s","usage_path":"%s"}\n' \
    "$t8/req.5-dddddd.res" "$t8/req.5-dddddd.out" "$t8/req.5-dddddd.usage" > "$r9"
  out=$(HOME="$fh" CLAUDE_CODE_SESSION_ID="$sid" "$0" --dispatch-dir "$t8" --engine-pid "$deadpid" --poll 1 --finish "$r9=reviewer=3" 2>/dev/null || true)
  if [[ "$(cat "$t8/req.5-dddddd.res" 2>/dev/null)" == "3" ]]; then echo "  PASS finish: nonzero rc passed through"; else echo "  FAIL finish: rc passthrough ($(cat "$t8/req.5-dddddd.res" 2>/dev/null))"; fails=1; fi
  if [[ -s "$t8/req.5-dddddd.out" && ! -e "$t8/req.5-dddddd.usage" ]]; then echo "  PASS finish: missing transcript → stub out, no usage sidecar"; else echo "  FAIL finish: missing-transcript handling (out=$(cat "$t8/req.5-dddddd.out" 2>/dev/null) usage_exists=$([[ -e "$t8/req.5-dddddd.usage" ]] && echo yes || echo no))"; fails=1; fi
  # Two finishes in one call, both completed; --print-json lists a pending request as JSON.
  ra="$t8/req.5-eeeeee.ready"; rb="$t8/req.5-ffffff.ready"; rc9="$t8/req.5-gggggg.ready"
  for x in eeeeee ffffff; do printf '{"agent":"qa","prompt":"p","cwd":"/x","res_path":"%s","out":"%s","usage_path":"%s"}\n' "$t8/req.5-$x.res" "$t8/req.5-$x.out" "$t8/req.5-$x.usage" > "$t8/req.5-$x.ready"; done
  printf '{"agent":"auditor","prompt":"audit it","cwd":"/x","res_path":"%s","out":"%s","usage_path":"%s","model":"claude-opus-5"}\n' "$t8/req.5-gggggg.res" "$t8/req.5-gggggg.out" "$t8/req.5-gggggg.usage" > "$rc9"
  out=$(HOME="$fh" CLAUDE_CODE_SESSION_ID="$sid" "$0" --dispatch-dir "$t8" --engine-pid "$$" --poll 1 --max-wait 1 --print-json --finish "$ra=qa=0" --finish "$rb=qa=1" 2>/dev/null || true)
  if [[ "$(cat "$t8/req.5-eeeeee.res" 2>/dev/null)" == "0" && "$(cat "$t8/req.5-ffffff.res" 2>/dev/null)" == "1" ]]; then echo "  PASS finish: two finishes in one call"; else echo "  FAIL finish: two finishes ($(cat "$t8/req.5-eeeeee.res" 2>/dev/null)/$(cat "$t8/req.5-ffffff.res" 2>/dev/null))"; fails=1; fi
  pj="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["path"], d["agent"], d["prompt"], d.get("model"))' "$out" 2>/dev/null || true)"
  if [[ "$pj" == "$rc9 auditor audit it claude-opus-5" ]]; then echo "  PASS await: --print-json emits the request JSON plus its path"; else echo "  FAIL await: --print-json (got '$out')"; fails=1; fi
  if [[ -f "${rc9%.ready}.started" ]]; then echo "  PASS await: --print-json still claims the request"; else echo "  FAIL await: --print-json did not claim"; fails=1; fi
  rm -rf "$t8"

  rm -rf "$t"
  [[ "$fails" -eq 0 ]] && echo "goal-await-dispatch self-test: OK" || echo "goal-await-dispatch self-test: FAILED"
  exit "$fails"
fi

# ── Normal mode ───────────────────────────────────────────────────────────────
DIR=""; PID=""; POLL=1; MAXWAIT=0; PRINT_JSON=0; FINISH=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dispatch-dir) DIR="$2"; shift 2 ;;
    --engine-pid)   PID="$2"; shift 2 ;;
    --poll)         POLL="$2"; shift 2 ;;
    --max-wait)     MAXWAIT="$2"; shift 2 ;;
    --print-json)   PRINT_JSON=1; shift ;;
    --finish)       [[ -n "${2:-}" ]] || { echo "ERROR: --finish needs <req.ready>=<agent>=<rc>" >&2; exit 2; }
                    FINISH+=("$2"); shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$DIR" ]] || { echo "ERROR: --dispatch-dir is required" >&2; exit 2; }

# ── Protocol v4 (TOKEN-11a): finish the previous dispatch(es) BEFORE blocking ─
# `--finish <req.ready>=<agent>=<rc>` replaces the pump's own out/usage/res
# writes (three tool turns per dispatch, plus the subagent's final message
# re-emitted as output tokens). lib/pump_finish.py takes the subagent's final
# message and usage from the pump session's OWN transcript — the same lookup the
# v2 usage recipe used — writes `out`, then `usage_path` (only when extraction
# fully succeeded: the honesty rule), then `.res` LAST. Whatever happens, `.res`
# is written so the engine never waits on a finished dispatch.
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
for _spec in "${FINISH[@]}"; do
  _req="${_spec%%=*}"; _rest="${_spec#*=}"; _agent="${_rest%%=*}"; _rc="${_rest#*=}"
  [[ "$_rc" =~ ^[0-9]+$ ]] || _rc=1
  if ! python3 "$_LIB/pump_finish.py" --request "$_req" --agent "$_agent" --rc "$_rc"; then
    _res="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("res_path",""))' "$_req" 2>/dev/null || true)"
    [[ -n "$_res" ]] || _res="${_req%.ready}.res"
    _out="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("out",""))' "$_req" 2>/dev/null || true)"
    [[ -z "$_out" || -f "$_out" ]] || printf '[interactive] subagent final message unavailable (agent=%s; finish helper failed)\n' "$_agent" > "$_out" 2>/dev/null || true
    echo "$_rc" > "$_res" 2>/dev/null || true
    echo "[goal-await-dispatch] finish helper failed for $_req — wrote .res=$_rc directly." >&2
  fi
done

# ── Pump identity (REL-3, protocol v3) ───────────────────────────────────────
# This helper is SHORT-LIVED (it exits the moment it hands work to the pump),
# so its own $$ is useless as a liveness anchor. The process that stays alive
# for the whole claimed dispatch is the pump's `claude` session binary — our
# ancestor. Resolve it once: CHAIN_PUMP_PID wins when SET (empty value = ident
# disabled, the pre-v3 format — deterministic test seam), else walk /proc
# ancestry for the first cmdline containing 'claude'. Unresolvable → write the
# contentless files of protocol v2 and the engine keeps its timeout nets: every
# field is OPTIONAL, absence must mean exactly today's behavior.
# starttime (/proc/<pid>/stat field 22) rides along so the engine can rule out
# a recycled pid, not just a missing one.
_PUMP_PID=""
if [[ -n "${CHAIN_PUMP_PID+set}" ]]; then
  _PUMP_PID="$(printf '%s' "$CHAIN_PUMP_PID" | tr -dc 0-9)"
else
  _anc="$PPID"
  for _ in $(seq 1 15); do
    { [[ -n "$_anc" ]] && [[ "$_anc" -gt 1 ]]; } 2>/dev/null || break
    if grep -qa 'claude' "/proc/$_anc/cmdline" 2>/dev/null; then _PUMP_PID="$_anc"; break; fi
    _anc="$(sed 's/.*) //' "/proc/$_anc/stat" 2>/dev/null | awk '{print $2}')"
  done
fi
_PUMP_HOST=""; _PUMP_STT=""
if [[ -n "$_PUMP_PID" ]]; then
  _PUMP_HOST="$(hostname 2>/dev/null || uname -n 2>/dev/null || echo '')"
  if [[ -r "/proc/$_PUMP_PID/stat" ]]; then
    _PUMP_STT="$(sed 's/.*) //' "/proc/$_PUMP_PID/stat" 2>/dev/null | awk '{print $20}')"
  fi
  [[ -z "$_PUMP_HOST" ]] && _PUMP_PID=""
fi

# _write_ident <target> — write the pump ident atomically (tmp + mv, so a
# mid-write read never sees a torn file and the mv sets the fresh mtime the
# engine's epoch/staleness logic has always keyed on). No ident → plain touch,
# byte-identical to protocol v2.
_write_ident() {
  local target="$1" _t
  if [[ -z "$_PUMP_PID" ]]; then
    touch "$target" 2>/dev/null || true
    return 0
  fi
  if ! _t="$(mktemp "$DIR/.ident.XXXXXX" 2>/dev/null)"; then
    touch "$target" 2>/dev/null || true
    return 0
  fi
  {
    printf 'pid=%s\n' "$_PUMP_PID"
    printf 'host=%s\n' "$_PUMP_HOST"
    if [[ -n "$_PUMP_STT" ]]; then printf 'starttime=%s\n' "$_PUMP_STT"; fi
  } > "$_t" 2>/dev/null || true
  mv -f "$_t" "$target" 2>/dev/null || { rm -f "$_t" 2>/dev/null || true; touch "$target" 2>/dev/null || true; }
}

# Print unanswered, unclaimed ready requests: a .ready file with neither a .res
# sibling (already answered) nor a .started sibling (already handed to the pump
# and in flight). The .started skip prevents a long-running claimed request from
# being re-listed and DOUBLE-DISPATCHED on a later --max-wait cycle.
_list_pending() {
  local f
  for f in "$DIR"/req.*.ready; do
    [[ -e "$f" ]] || continue
    [[ -e "${f%.ready}.res" ]] && continue
    [[ -e "${f%.ready}.started" ]] && continue
    printf '%s\n' "$f"
  done
}

# Hand a set of pending requests to the pump: mark each one claimed (touch its
# .started sibling) at the exact moment we emit it, then print it. The .started
# marker is the deterministic record that the pump has TAKEN the work — the
# engine's _interactive_invoke switches from the pickup-heartbeat timeout to the
# (much larger) inflight timeout once it appears, so a legitimately long agent is
# never mistaken for a dead pump.
_claim_and_emit() {
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    _write_ident "${f%.ready}.started"
    if (( PRINT_JSON )); then
      # Protocol v4: hand the pump the request itself (agent, prompt, model,
      # out/usage/res paths) plus its path, so no Read turn is needed. A
      # request that does not parse falls back to the bare path.
      python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); d["path"]=sys.argv[1]; print(json.dumps(d))' "$f" 2>/dev/null || printf '%s\n' "$f"
    else
      printf '%s\n' "$f"
    fi
  done <<< "$1"
}

# Branch priority inside the loop: pending > ENGINE_DONE > WAITING > sleep, so a
# request that appears at the last moment is always returned, never masked by the
# bounded-wait sentinel.
START_EPOCH=$(date +%s)
_HB_IDENT_WRITTEN=""
while true; do
  # First beat of this invocation writes the ident (content survives later
  # touches); subsequent beats just refresh the mtime, same as always.
  if [[ -n "$_PUMP_PID" && -z "$_HB_IDENT_WRITTEN" ]]; then
    _write_ident "$DIR/.pump-alive"
    _HB_IDENT_WRITTEN=1
  else
    touch "$DIR/.pump-alive" 2>/dev/null || true
  fi
  pending="$(_list_pending)"
  if [[ -n "$pending" ]]; then
    _claim_and_emit "$pending"
    exit 0
  fi
  if [[ -n "$PID" ]] && ! kill -0 "$PID" 2>/dev/null; then
    # Engine gone — re-check once for a publish/exit race, then declare done.
    pending="$(_list_pending)"
    if [[ -n "$pending" ]]; then _claim_and_emit "$pending"; exit 0; fi
    echo "ENGINE_DONE"
    exit 0
  fi
  # Bounded foreground wait: when --max-wait is set and elapses with the engine
  # still alive and nothing pending, hand control back to the pump so it can
  # re-call deterministically (no background job for the pump to poll). 0 = block
  # forever (the original behavior).
  if [[ "$MAXWAIT" -gt 0 ]] && (( $(date +%s) - START_EPOCH >= MAXWAIT )); then
    echo "WAITING"
    exit 0
  fi
  sleep "$POLL"
done
