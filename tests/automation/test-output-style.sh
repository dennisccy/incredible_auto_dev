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

# ── Slice 2 (interactive-backend emulation) cases h/h2/h3 land here ─────────
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

# ── j3. The trace row records the requested style ──────────────────────────
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
PY
then
  pass "j3: trace.jsonl developer row carries output_style=Concise"
else
  fail "j3: trace row missing output_style (rc=$RUN_RC, trace: $(cat "$J3_TRACE/trace.jsonl" 2>/dev/null))"
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

# ── Slice 4 (doctor + tripwire) cases k/k2/k3/k4 land here ──────────────────

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo ""

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
