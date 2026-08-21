#!/usr/bin/env bash
# test-output-style.sh — STYLE-1: the headless Claude Code output-style seam.
#
# Claude Code has NO --output-style flag; the per-invocation lever is
# `--settings '{"outputStyle":"<Name>"}'`, and the CLI SILENTLY ignores a name
# it does not know. That silence is the whole reason this layer exists: an
# unlabeled default arm masquerading as a styled one would poison the
# experiment. So the seam (a) validates every configured name through
# lib/agent_permissions.py and REFUSES to dispatch on a bad one, and (b) proves
# per dispatch which style actually ran, by reading the effective style back
# out of the stream-json `system/init` event via the usage sidecar.
#
# Step-0 probe, 2026-08-20, CLI 2.1.237: init.output_style="Concise" with
# --settings '{"outputStyle":"Concise"}' and
# --exclude-dynamic-system-prompt-sections; permission_denials=[]; the
# project's PreToolUse hooks still fired (hook_started/hook_response events)
# ⇒ inline --settings MERGES with project/user settings; available_output_styles
# is absent from this version's init event (treat as optional).
#
# Contract under test:
#   lib/quota-retry.sh   _claude_invoke  — resolve → --settings; resolver rc≠0
#                                          is FATAL (rc 2, nothing dispatched)
#                        _output_style_verify — requested-vs-effective WARNING
#                        _trace_record_invocation — output_style in trace.jsonl
#                        _codex_invoke   — drops --settings (no Codex equivalent)
#   lib/claude_stream_renderer.py        — init.output_style → usage sidecar
#
# Everything runs against PATH-shadowed stub CLIs. No API calls; ~3 s.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SBX="$WORK/sbx"        # empty project dir: the style table needs no files
SESS="$WORK/sess"      # stands in for a goal session (arms the goal-mode gate)
STUB="$WORK/bin"
mkdir -p "$SBX" "$SESS" "$STUB"

# ── Stub CLIs ────────────────────────────────────────────────────────────────
# claude: records its argv one-per-line to $CLAUDE_STUB_ARGS. When
# CLAUDE_STUB_EFFECTIVE is set it emits a minimal stream-json transcript so the
# REAL renderer runs and writes the REAL sidecar — the readback path under test.
cat > "$STUB/claude" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${CLAUDE_STUB_ARGS:-}" ]]; then
  printf '%s\n' "$@" > "$CLAUDE_STUB_ARGS"
fi
if [[ -n "${CLAUDE_STUB_EFFECTIVE:-}" ]]; then
  printf '{"type":"system","subtype":"init","session_id":"stub0000","model":"claude-stub","output_style":"%s"}\n' \
    "$CLAUDE_STUB_EFFECTIVE"
  printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"num_turns":1,"usage":{"input_tokens":1,"output_tokens":1}}'
fi
exit 0
EOF
chmod +x "$STUB/claude"

cat > "$STUB/codex" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${CODEX_STUB_ARGS:-}" ]]; then
  printf '%s\n' "$@" > "$CODEX_STUB_ARGS"
fi
exit 0
EOF
chmod +x "$STUB/codex"

RENDERER="$REPO_ROOT/scripts/automation/lib/claude_stream_renderer.py"

# ── Helpers ──────────────────────────────────────────────────────────────────
# run_seam <claude-argv-file> [ENV=VAL ...] [-- <seam args>]
# Sources quota-retry.sh in a clean env (all three style knobs unset, no goal
# session, no trace dir) and dispatches. Leaves RUN_RC + RUN_OUT (stdout+stderr).
run_seam() {
  local argvfile="$1"; shift
  local -a envs=() cmdargs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift
  cmdargs=("$@")
  [[ ${#cmdargs[@]} -eq 0 ]] && cmdargs=(-p ping)
  : > "$argvfile"
  RUN_RC=0
  RUN_OUT=$(cd "$SBX" && env \
    -u CHAIN_OUTPUT_STYLES -u CHAIN_AGENT_OUTPUT_STYLE -u CHAIN_OUTPUT_STYLE_OVERRIDE \
    -u GOAL_SESSION_DIR -u CHAIN_TRACE_DIR -u CLAUDE_STUB_EFFECTIVE -u CHAIN_CLI \
    -u CHAIN_AGENT_BACKEND -u CHAIN_MODEL_OVERRIDE -u CHAIN_EFFORT_OVERRIDE \
    PATH="$STUB:$PATH" CLAUDE_STUB_ARGS="$argvfile" REPO_ROOT="$REPO_ROOT" \
    CHAIN_TELEMETRY_TOKENS=false CHAIN_DISABLE_AUTO_WAIT=true \
    CHAIN_AGENT_TIMEOUTS=false CHAIN_CLAUDE_MAX_RUNTIME_SECONDS=0 \
    CHAIN_CODEX_MAX_RUNTIME_SECONDS=0 \
    "${envs[@]}" \
    bash -c 'source "$REPO_ROOT/scripts/automation/lib/quota-retry.sh"; claude_with_quota_retry "$@"' \
      _seam "${cmdargs[@]}" 2>&1) || RUN_RC=$?
}

# Exact-line membership in a recorded argv file (pure bash — the machine's grep
# is ugrep and its coreutils are uutils; neither is trusted for this).
argv_has() {
  local f="$1" needle="$2" line
  [[ -f "$f" ]] || return 1
  while IFS= read -r line; do [[ "$line" == "$needle" ]] && return 0; done < "$f"
  return 1
}
# Prints the argv line that follows <flag>.
argv_value_after() {
  local f="$1" flag="$2" prev="" line
  [[ -f "$f" ]] || return 1
  while IFS= read -r line; do
    [[ "$prev" == "$flag" ]] && { printf '%s\n' "$line"; return 0; }
    prev="$line"
  done < "$f"
  return 1
}
# True if any argv line contains <substring>.
argv_grep() {
  local f="$1" needle="$2" line
  [[ -f "$f" ]] || return 1
  while IFS= read -r line; do [[ "$line" == *"$needle"* ]] && return 0; done < "$f"
  return 1
}
argv_empty() { [[ ! -s "$1" ]]; }

CONCISE_SETTINGS='{"outputStyle":"Concise"}'

echo ""
echo "=== output-style seam (STYLE-1) ==="

# ── a. Knob off → no --settings anywhere (the default-off guarantee) ─────────
A="$WORK/a.argv"
run_seam "$A" GOAL_SESSION_DIR="$SESS" CHAIN_CURRENT_AGENT=developer
if [[ $RUN_RC -eq 0 ]] && ! argv_has "$A" "--settings"; then
  pass "a: knob off → no --settings (rc $RUN_RC)"
else
  fail "a: knob off leaked --settings or failed (rc=$RUN_RC, argv: $(cat "$A"))"
fi

# ── b. Table armed → developer gets Concise ─────────────────────────────────
B="$WORK/b.argv"
run_seam "$B" GOAL_SESSION_DIR="$SESS" CHAIN_CURRENT_AGENT=developer CHAIN_OUTPUT_STYLES=true
if [[ $RUN_RC -eq 0 && "$(argv_value_after "$B" "--settings")" == "$CONCISE_SETTINGS" ]]; then
  pass "b: table armed → --settings $CONCISE_SETTINGS"
else
  fail "b: expected $CONCISE_SETTINGS (rc=$RUN_RC, argv: $(cat "$B"))"
fi

# ── b2. Goal-mode-only gate: no GOAL_SESSION_DIR → table inert ──────────────
B2="$WORK/b2.argv"
run_seam "$B2" CHAIN_CURRENT_AGENT=developer CHAIN_OUTPUT_STYLES=true
if [[ $RUN_RC -eq 0 ]] && ! argv_has "$B2" "--settings"; then
  pass "b2: no GOAL_SESSION_DIR → table inert (goal-mode-only gate)"
else
  fail "b2: table fired outside goal mode (rc=$RUN_RC, argv: $(cat "$B2"))"
fi

# ── c. Judge is never in the table (D4) ─────────────────────────────────────
C="$WORK/c.argv"
run_seam "$C" GOAL_SESSION_DIR="$SESS" CHAIN_CURRENT_AGENT=goal-evaluator CHAIN_OUTPUT_STYLES=true
if [[ $RUN_RC -eq 0 ]] && ! argv_has "$C" "--settings"; then
  pass "c: goal-evaluator unstyled under the armed table"
else
  fail "c: judge picked up a style (rc=$RUN_RC, argv: $(cat "$C"))"
fi

# ── d. Per-agent map refuses a judge, loudly, and still dispatches ──────────
D="$WORK/d.argv"
run_seam "$D" GOAL_SESSION_DIR="$SESS" CHAIN_CURRENT_AGENT=goal-evaluator \
  CHAIN_AGENT_OUTPUT_STYLE=goal-evaluator=Concise
if [[ $RUN_RC -eq 0 ]] && ! argv_has "$D" "--settings" \
   && [[ "$RUN_OUT" == *"CHAIN_AGENT_OUTPUT_STYLE refused for judge"* ]]; then
  pass "d: env map refused for a judge, with a loud notice"
else
  fail "d: judge refusal missing (rc=$RUN_RC, argv: $(cat "$D"), out: $RUN_OUT)"
fi

# ── d2. Env map beats the table's absence and canonicalizes case ────────────
D2="$WORK/d2.argv"
run_seam "$D2" GOAL_SESSION_DIR="$SESS" CHAIN_CURRENT_AGENT=iteration-summarizer \
  CHAIN_AGENT_OUTPUT_STYLE=iteration-summarizer=concise
if [[ $RUN_RC -eq 0 && "$(argv_value_after "$D2" "--settings")" == "$CONCISE_SETTINGS" ]]; then
  pass "d2: env map styles a non-table agent, canonicalizing 'concise'→'Concise'"
else
  fail "d2: expected $CONCISE_SETTINGS (rc=$RUN_RC, argv: $(cat "$D2"))"
fi

# ── e. Typo → refuse to dispatch (the CLI would ignore it silently) ─────────
E="$WORK/e.argv"
run_seam "$E" GOAL_SESSION_DIR="$SESS" CHAIN_CURRENT_AGENT=developer \
  CHAIN_AGENT_OUTPUT_STYLE=developer=Consise
if [[ $RUN_RC -eq 2 ]] && argv_empty "$E" \
   && [[ "$RUN_OUT" == *"OUTPUT STYLE RESOLUTION FAILED"* && "$RUN_OUT" == *"unknown output style"* ]]; then
  pass "e: unknown style → rc 2, claude never ran"
else
  fail "e: expected rc 2 + empty argv (rc=$RUN_RC, argv: $(cat "$E"), out: $RUN_OUT)"
fi

# ── f. Refused style (Learning stalls headless runs) ────────────────────────
F="$WORK/f.argv"
run_seam "$F" GOAL_SESSION_DIR="$SESS" CHAIN_CURRENT_AGENT=developer \
  CHAIN_OUTPUT_STYLE_OVERRIDE=Learning
if [[ $RUN_RC -eq 2 ]] && argv_empty "$F" && [[ "$RUN_OUT" == *"is refused"* ]]; then
  pass "f: Learning refused → rc 2, claude never ran"
else
  fail "f: expected rc 2 + refusal (rc=$RUN_RC, argv: $(cat "$F"), out: $RUN_OUT)"
fi

# ── f2. Debug override works outside goal mode, judges included (loudly) ────
F2="$WORK/f2.argv"
run_seam "$F2" CHAIN_CURRENT_AGENT=goal-evaluator CHAIN_OUTPUT_STYLE_OVERRIDE=Explanatory
if [[ $RUN_RC -eq 0 && "$(argv_value_after "$F2" "--settings")" == '{"outputStyle":"Explanatory"}' ]] \
   && [[ "$RUN_OUT" == *"NOTICE"* ]]; then
  pass "f2: global override styles a judge outside goal mode, with a NOTICE"
else
  fail "f2: expected Explanatory + NOTICE (rc=$RUN_RC, argv: $(cat "$F2"), out: $RUN_OUT)"
fi

# ── f3. Override=Default means "pass nothing", not a literal name ───────────
F3="$WORK/f3.argv"
run_seam "$F3" GOAL_SESSION_DIR="$SESS" CHAIN_CURRENT_AGENT=developer \
  CHAIN_OUTPUT_STYLES=true CHAIN_OUTPUT_STYLE_OVERRIDE=Default
if [[ $RUN_RC -eq 0 ]] && ! argv_has "$F3" "--settings"; then
  pass "f3: override=Default → no --settings (beats the armed table)"
else
  fail "f3: Default leaked a flag (rc=$RUN_RC, argv: $(cat "$F3"))"
fi

# ── g. Codex backend drops --settings (no equivalent, no emulation) ─────────
G="$WORK/g.argv"
G_CODEX="$WORK/g.codex.argv"
: > "$G_CODEX"
run_seam "$G" GOAL_SESSION_DIR="$SESS" CHAIN_CURRENT_AGENT=developer \
  CHAIN_OUTPUT_STYLES=true CHAIN_CLI=codex CODEX_STUB_ARGS="$G_CODEX" \
  -- --settings "$CONCISE_SETTINGS" -p ping
if [[ $RUN_RC -eq 0 ]] && ! argv_has "$G_CODEX" "--settings" \
   && ! argv_grep "$G_CODEX" "outputStyle" && argv_has "$G_CODEX" "ping"; then
  pass "g: codex drops --settings and its value, keeps the prompt"
else
  fail "g: codex argv wrong (rc=$RUN_RC, argv: $(cat "$G_CODEX"), out: $RUN_OUT)"
fi

# ── Slice 2: interactive-backend emulation (h*) ─────────────────────────────
# Claude Code injects an output style only into the DEFAULT system prompt, and
# Agent-tool subagents (the /goal pump backend) never receive it — so the
# interactive backend EMULATES the style by appending its body to the prompt.
# These cases drive REAL round-trips through _interactive_invoke against a tiny
# inline "pump", the same recipe tests/automation/test-quota-retry.sh uses.

IPROMPT='Agent instructions: .claude/agents/developer.md  <-- read this first'

# run_interactive <tag> [ENV=VAL ...]
# Backgrounds one interactive dispatch, waits (bounded, ~5 s) for the request the
# seam publishes, saves its `.prompt`, answers `.res`=0, and reaps. Leaves:
#   IRC          the dispatch's exit code
#   IPROMPT_FILE the published prompt (empty file when nothing was published)
#   IREQ_COUNT   req.* files left in the channel
#   ILOG_TEXT    the dispatch's stdout+stderr
#   IARGV        recorded argv of the stub `claude` (must stay empty: no headless call)
run_interactive() {
  local tag="$1"; shift
  local D="$WORK/$tag"
  mkdir -p "$D"
  IPROMPT_FILE="$D/published.prompt"; : > "$IPROMPT_FILE"
  IARGV="$D/claude.argv"; : > "$IARGV"
  touch "$D/.pump-alive"
  (
    cd "$SBX" && env \
      -u CHAIN_OUTPUT_STYLES -u CHAIN_AGENT_OUTPUT_STYLE -u CHAIN_OUTPUT_STYLE_OVERRIDE \
      -u GOAL_SESSION_DIR -u CHAIN_TRACE_DIR -u CHAIN_CLI -u CHAIN_MODEL_OVERRIDE \
      -u CHAIN_TMPDIR -u CHAIN_DISPATCH_LANE \
      PATH="$STUB:$PATH" CLAUDE_STUB_ARGS="$IARGV" REPO_ROOT="$REPO_ROOT" \
      CHAIN_TELEMETRY_TOKENS=false CHAIN_DISABLE_AUTO_WAIT=true \
      CHAIN_AGENT_TIMEOUTS=false CHAIN_CLAUDE_MAX_RUNTIME_SECONDS=0 \
      CHAIN_AGENT_BACKEND=interactive CHAIN_DISPATCH_DIR="$D" \
      CHAIN_DISPATCH_POLL_SECONDS=0.2 CHAIN_PUMP_HEARTBEAT_TIMEOUT=3600 \
      "$@" \
      bash -c 'source "$REPO_ROOT/scripts/automation/lib/quota-retry.sh"; claude_with_quota_retry "$@"' \
        _seam -p "$IPROMPT" > "$D/log" 2>&1
    echo "$?" > "$D/rc.out"
  ) &
  local bg=$! req="" i
  for i in $(seq 1 50); do
    req=$(find "$D" -maxdepth 1 -name 'req.*.ready' 2>/dev/null | head -1)
    [[ -n "$req" || -f "$D/rc.out" ]] && break
    sleep 0.1
  done
  if [[ -n "$req" ]]; then
    jq -r '.prompt' "$req" > "$IPROMPT_FILE" 2>/dev/null || : > "$IPROMPT_FILE"
    echo 0 > "${req%.ready}.res"
  fi
  wait "$bg" 2>/dev/null || true
  IRC=$(cat "$D/rc.out" 2>/dev/null || echo missing)
  IREQ_COUNT=$(find "$D" -maxdepth 1 -name 'req.*' 2>/dev/null | wc -l | tr -d ' ')
  ILOG_TEXT=$(cat "$D/log" 2>/dev/null)
}

H_HDR='# Output Style: Concise (engine-emulated on the interactive backend)'
H_CTX='already loaded as your system prompt'

# ── h. Armed table → the prompt carries the emulation block, CTX-8 note last ─
run_interactive h GOAL_SESSION_DIR="$SESS" CHAIN_CURRENT_AGENT=developer CHAIN_OUTPUT_STYLES=true
H_PROMPT=$(cat "$WORK/h/published.prompt")
H_PRE_HDR="${H_PROMPT%%"$H_HDR"*}"
H_PRE_CTX="${H_PROMPT%%"$H_CTX"*}"
if [[ "$IRC" == "0" && "$H_PROMPT" == *"$H_HDR"* && "$H_PROMPT" == *"Lead with the result"* \
      && "$H_PROMPT" == *"$H_CTX"* ]] && (( ${#H_PRE_HDR} < ${#H_PRE_CTX} )); then
  pass "h: interactive prompt carries the Concise emulation block, CTX-8 note after it"
else
  fail "h: emulation block missing/misordered (rc=$IRC, prompt: $(printf '%s' "$H_PROMPT" | head -c 300))"
fi

# ── h2. Judge stays unemulated under the armed table (D4) ───────────────────
run_interactive h2 GOAL_SESSION_DIR="$SESS" CHAIN_CURRENT_AGENT=goal-evaluator CHAIN_OUTPUT_STYLES=true
H2_PROMPT=$(cat "$WORK/h2/published.prompt")
if [[ "$IRC" == "0" && -s "$WORK/h2/published.prompt" && "$H2_PROMPT" != *"# Output Style:"* ]]; then
  pass "h2: goal-evaluator dispatches unemulated under the armed table"
else
  fail "h2: judge picked up an emulation block (rc=$IRC, prompt: $(printf '%s' "$H2_PROMPT" | head -c 300))"
fi

# ── h3. Unknown style → refuse the dispatch, publish nothing ────────────────
run_interactive h3 GOAL_SESSION_DIR="$SESS" CHAIN_CURRENT_AGENT=developer \
  CHAIN_AGENT_OUTPUT_STYLE=developer=Nope
if [[ "$IRC" == "2" && "$IREQ_COUNT" == "0" && "$ILOG_TEXT" == *"OUTPUT STYLE RESOLUTION FAILED"* ]] \
   && argv_empty "$WORK/h3/claude.argv"; then
  pass "h3: unknown style → rc 2, no request published, no headless fallthrough"
else
  fail "h3: expected rc 2 + nothing published (rc=$IRC, reqs=$IREQ_COUNT, out: $ILOG_TEXT)"
fi

# ── h4. Valid style with no emulation text → warn, dispatch unstyled ────────
run_interactive h4 GOAL_SESSION_DIR="$SESS" CHAIN_CURRENT_AGENT=developer \
  CHAIN_AGENT_OUTPUT_STYLE=developer=Explanatory
H4_PROMPT=$(cat "$WORK/h4/published.prompt")
if [[ "$IRC" == "0" && -s "$WORK/h4/published.prompt" && "$H4_PROMPT" != *"# Output Style:"* \
      && "$ILOG_TEXT" == *"no emulation text"* ]]; then
  pass "h4: Explanatory has no body → WARN + unstyled dispatch (fidelity gap, not a config error)"
else
  fail "h4: expected an unstyled dispatch + warning (rc=$IRC, out: $ILOG_TEXT, prompt: $(printf '%s' "$H4_PROMPT" | head -c 200))"
fi

# ── i. Renderer stamps the effective style into the usage sidecar ───────────
I_SIDE="$WORK/i.sidecar.json"
printf '%s\n' \
  '{"type":"system","subtype":"init","session_id":"abcdef0123","model":"claude-test","output_style":"Concise","available_output_styles":["default","Concise"]}' \
  '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"num_turns":1,"usage":{"input_tokens":1,"output_tokens":1}}' \
  | CHAIN_CLAUDE_USAGE_SIDECAR="$I_SIDE" python3 "$RENDERER" >/dev/null 2>&1
if python3 - "$I_SIDE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("output_style") == "Concise", d.get("output_style")
assert d.get("model") == "claude-test", d.get("model")
assert d.get("available_output_styles") == "default,Concise", d.get("available_output_styles")
PY
then
  pass "i: sidecar carries output_style + model + available_output_styles"
else
  fail "i: sidecar wrong ($(cat "$I_SIDE" 2>/dev/null))"
fi

# ── i2. No output_style in init → null, never a fabricated 'default' ────────
I2_SIDE="$WORK/i2.sidecar.json"
printf '%s\n' \
  '{"type":"system","subtype":"init","session_id":"abcdef0123","model":"claude-test"}' \
  '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"num_turns":1,"usage":{"input_tokens":1,"output_tokens":1}}' \
  | CHAIN_CLAUDE_USAGE_SIDECAR="$I2_SIDE" python3 "$RENDERER" >/dev/null 2>&1
if python3 - "$I2_SIDE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert "output_style" in d, "key missing entirely"
assert d["output_style"] is None, d["output_style"]
assert d.get("available_output_styles") is None, d.get("available_output_styles")
PY
then
  pass "i2: init without output_style → sidecar output_style is null"
else
  fail "i2: sidecar wrong ($(cat "$I2_SIDE" 2>/dev/null))"
fi

# ── j. Requested ≠ effective → loud WARNING (the silent-ignore detector) ────
J="$WORK/j.argv"
run_seam "$J" GOAL_SESSION_DIR="$SESS" CHAIN_CURRENT_AGENT=developer \
  CHAIN_OUTPUT_STYLES=true CHAIN_TELEMETRY_TOKENS=true CLAUDE_STUB_EFFECTIVE=default
if [[ $RUN_RC -eq 0 && "$RUN_OUT" == *"WARNING: output style requested=Concise effective=default"* ]]; then
  pass "j: requested=Concise effective=default → mismatch WARNING"
else
  fail "j: no mismatch warning (rc=$RUN_RC, out: $RUN_OUT)"
fi

# ── j2. Requested == effective → silence ───────────────────────────────────
J2="$WORK/j2.argv"
run_seam "$J2" GOAL_SESSION_DIR="$SESS" CHAIN_CURRENT_AGENT=developer \
  CHAIN_OUTPUT_STYLES=true CHAIN_TELEMETRY_TOKENS=true CLAUDE_STUB_EFFECTIVE=Concise
if [[ $RUN_RC -eq 0 && "$RUN_OUT" != *"WARNING: output style"* ]]; then
  pass "j2: matching effective style is silent"
else
  fail "j2: spurious mismatch warning (rc=$RUN_RC, out: $RUN_OUT)"
fi

# ── j3. The trace row records the requested style (and keeps the effective one) ──
J3="$WORK/j3.argv"
J3_TRACE="$WORK/trace"
mkdir -p "$J3_TRACE"
run_seam "$J3" GOAL_SESSION_DIR="$SESS" CHAIN_CURRENT_AGENT=developer \
  CHAIN_OUTPUT_STYLES=true CHAIN_TRACE_DIR="$J3_TRACE"
if [[ $RUN_RC -eq 0 ]] && python3 - "$J3_TRACE/trace.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
dev = [r for r in rows if r.get("agent") == "developer"]
assert dev, "no developer row"
assert dev[-1].get("output_style") == "Concise", dev[-1].get("output_style")
assert dev[-1].get("output_style_requested") == "Concise", dev[-1].get("output_style_requested")
PY
then
  pass "j3: trace.jsonl developer row carries output_style=Concise and output_style_requested=Concise"
else
  fail "j3: trace row missing style keys (rc=$RUN_RC, trace: $(cat "$J3_TRACE/trace.jsonl" 2>/dev/null))"
fi

# ── j3b. Requested ≠ effective: the trace keeps BOTH (requested is not clobbered) ──
J3B="$WORK/j3b.argv"
J3B_TRACE="$WORK/trace-j3b"
mkdir -p "$J3B_TRACE"
run_seam "$J3B" GOAL_SESSION_DIR="$SESS" CHAIN_CURRENT_AGENT=developer \
  CHAIN_OUTPUT_STYLES=true CHAIN_TELEMETRY_TOKENS=true CLAUDE_STUB_EFFECTIVE=default CHAIN_TRACE_DIR="$J3B_TRACE"
if [[ $RUN_RC -eq 0 ]] && python3 - "$J3B_TRACE/trace.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
dev = [r for r in rows if r.get("agent") == "developer"]
assert dev, "no developer row"
assert dev[-1].get("output_style") == "default", dev[-1].get("output_style")
assert dev[-1].get("output_style_requested") == "Concise", dev[-1].get("output_style_requested")
PY
then
  pass "j3b: mismatch run keeps output_style=default (effective) and output_style_requested=Concise"
else
  fail "j3b: trace row lost the requested style (rc=$RUN_RC, trace: $(cat "$J3B_TRACE/trace.jsonl" 2>/dev/null))"
fi

# ── j3c. No style requested → no output_style_requested key at all ──
J3C="$WORK/j3c.argv"
J3C_TRACE="$WORK/trace-j3c"
mkdir -p "$J3C_TRACE"
run_seam "$J3C" GOAL_SESSION_DIR="$SESS" CHAIN_CURRENT_AGENT=developer CHAIN_TRACE_DIR="$J3C_TRACE"
if [[ $RUN_RC -eq 0 ]] && python3 - "$J3C_TRACE/trace.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
dev = [r for r in rows if r.get("agent") == "developer"]
assert dev, "no developer row"
assert "output_style_requested" not in dev[-1], dev[-1]
PY
then
  pass "j3c: unstyled dispatch has no output_style_requested key"
else
  fail "j3c: unexpected output_style_requested on an unstyled dispatch (rc=$RUN_RC)"
fi

# ── j4. Style requested with token telemetry off → say so, don't pretend ───
J4="$WORK/j4.argv"
run_seam "$J4" GOAL_SESSION_DIR="$SESS" CHAIN_CURRENT_AGENT=developer \
  CHAIN_OUTPUT_STYLES=true CHAIN_TELEMETRY_TOKENS=false
if [[ $RUN_RC -eq 0 && "$RUN_OUT" == *"effective-style verification unavailable"* ]]; then
  pass "j4: telemetry off → 'verification unavailable' notice"
else
  fail "j4: missing unavailable notice (rc=$RUN_RC, out: $RUN_OUT)"
fi

# ── Slice 4: doctor.sh output-styles row (k*) ───────────────────────────────
# doctor.sh's own row (STYLE-1, offline): validates configured names, greps
# the installed claude ELF for "# <Name> Style Active", warns on an ambient
# outputStyle pin. Drives the REAL doctor.sh against a small fixture: a fake
# `claude` on a PATH that shadows the real one (so the grep target is ours),
# plus HOME/CHAIN_DOCTOR_REPO_ROOT overrides so the settings.json pin check
# reads the fixture, never the real repo/home.

DOCTOR="$REPO_ROOT/scripts/automation/doctor.sh"
KBIN="$WORK/kbin"
KHOME="$WORK/khome"
KHOME4="$WORK/khome4"
KREPO="$WORK/krepo"
mkdir -p "$KBIN" "$KHOME/.claude" "$KHOME4/.claude" "$KREPO/.claude"
printf '{"outputStyle":"Explanatory"}\n' > "$KHOME4/.claude/settings.json"

# Fake `claude`: --version answers sensibly; the Concise marker literal is
# present only when $1 = with.
mk_fake_claude() {
  {
    printf '#!/usr/bin/env bash\n'
    printf '[[ "${1:-}" == "--version" ]] && { echo "2.1.237 (Claude Code)"; exit 0; }\n'
    [[ "$1" == "with" ]] && printf '# Concise Style Active\n'
    printf 'exit 0\n'
  } > "$KBIN/claude"
  chmod +x "$KBIN/claude"
}

# run_doctor_styles [ENV=VAL ...] — the real doctor.sh, --only output-styles,
# against the fixture above; the three style knobs are unset by default (a
# case that wants one armed passes it explicitly, same recipe as run_seam).
run_doctor_styles() {
  env -u CHAIN_OUTPUT_STYLES -u CHAIN_AGENT_OUTPUT_STYLE -u CHAIN_OUTPUT_STYLE_OVERRIDE \
    PATH="$KBIN:$PATH" HOME="$KHOME" CHAIN_DOCTOR_REPO_ROOT="$KREPO" \
    "$@" bash "$DOCTOR" --only output-styles 2>&1
}

# ── k. Armed table + the marker present in the binary → PASS "armed" ────────
mk_fake_claude with
K_OUT=$(run_doctor_styles CHAIN_OUTPUT_STYLES=true)
if [[ "$K_OUT" == *"PASS"*"output-styles"* && "$K_OUT" == *"armed"* ]]; then
  pass "k: armed table + marker present in claude → PASS naming it armed"
else
  fail "k: expected an armed PASS row (out: $K_OUT)"
fi

# ── k2. Armed table but the binary lacks the marker → WARN naming Concise ───
mk_fake_claude without
K2_OUT=$(run_doctor_styles CHAIN_OUTPUT_STYLES=true)
if [[ "$K2_OUT" == *"WARN"*"output-styles"* && "$K2_OUT" == *"Concise"* ]]; then
  pass "k2: marker missing from claude → WARN naming Concise"
else
  fail "k2: expected a WARN row naming Concise (out: $K2_OUT)"
fi

# ── k3. Knobs off, nothing pinned → PASS "no output styles configured", dormant
K3_OUT=$(run_doctor_styles)
if [[ "$K3_OUT" == *"PASS"*"output-styles"* && "$K3_OUT" == *"no output styles configured"* \
      && "$K3_OUT" == *"dormant"* ]]; then
  pass "k3: knobs off, nothing pinned → PASS dormant"
else
  fail "k3: expected a dormant PASS row (out: $K3_OUT)"
fi

# ── k4. Knobs off but outputStyle pinned in HOME settings.json → WARN ───────
K4_OUT=$(run_doctor_styles HOME="$KHOME4")
if [[ "$K4_OUT" == *"WARN"*"output-styles"* && "$K4_OUT" == *"pinned"* ]]; then
  pass "k4: knob off but outputStyle pinned in HOME settings.json → WARN"
else
  fail "k4: expected a pinned WARN row (out: $K4_OUT)"
fi

# ── k5. Invalid name behind a judge WARNING line → FAIL naming it, not a
# generic "check crashed" (output-style-check's per-entry judge WARNING for
# 'reviewer' must not crowd the 'Bogus' ERROR line out of the truncated,
# single-line FAIL detail; a multi-line detail would break run_check's
# "last line" verdict parser and fall back to a generic crash message).
mk_fake_claude with
K5_OUT=$(run_doctor_styles CHAIN_AGENT_OUTPUT_STYLE="reviewer=Concise,qa=Bogus")
if [[ "$K5_OUT" == *"FAIL"*"output-styles"* && "$K5_OUT" == *"Bogus"* \
      && "$K5_OUT" != *"check crashed"* ]]; then
  pass "k5: invalid name survives past a judge WARNING line → FAIL naming Bogus, no generic crash"
else
  fail "k5: expected FAIL naming Bogus with no crash fallback (out: $K5_OUT)"
fi

# ── k6. Lowercase built-in name via CHAIN_AGENT_OUTPUT_STYLE, marker present →
# canonicalized to "Concise" before the grep → PASS, not a spurious WARN (the
# resolver already accepts built-in names case-insensitively at dispatch; the
# binary-marker grep must agree, not flag a false "not found").
mk_fake_claude with
K6_OUT=$(run_doctor_styles CHAIN_AGENT_OUTPUT_STYLE="developer=concise")
if [[ "$K6_OUT" == *"PASS"*"output-styles"* && "$K6_OUT" != *"WARN"* ]]; then
  pass "k6: lowercase built-in name canonicalized before the grep → PASS, not WARN"
else
  fail "k6: expected a canonicalized PASS row (out: $K6_OUT)"
fi

# ── k7. CLI-level: output-styles-configured itself prints the canonical
# spelling, not the raw casing — doctor and any other consumer of this
# subcommand all read one canonical name (agent_permissions.py is the
# preferred fix location per the casing ruling, not a doctor.sh-side grep -i).
K7_OUT=$(env -u CHAIN_OUTPUT_STYLES -u CHAIN_OUTPUT_STYLE_OVERRIDE \
  CHAIN_AGENT_OUTPUT_STYLE="developer=concise" \
  python3 "$REPO_ROOT/scripts/automation/lib/agent_permissions.py" output-styles-configured)
if [[ "$K7_OUT" == "Concise"$'\t'"env:CHAIN_AGENT_OUTPUT_STYLE[developer]" ]]; then
  pass "k7: output-styles-configured canonicalizes developer=concise → Concise"
else
  fail "k7: expected canonical 'Concise' (out: $K7_OUT)"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo ""

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
