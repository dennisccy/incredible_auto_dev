#!/usr/bin/env bash
# test-phase-telemetry.sh — TOKEN-8 unit test: phase-script dispatches record
# claude_usage telemetry ONLY under goal mode (GOAL_SESSION_DIR set).
#
# Drives the REAL generate-test-plan.sh (one of the TOKEN-8-converted phase
# scripts: it sources lib/telemetry.sh and exports CHAIN_CURRENT_AGENT=qa) in a
# sandbox with a stub `claude` on PATH. The stub writes a fake usage sidecar to
# $CHAIN_CLAUDE_USAGE_SIDECAR — standing in for what claude_stream_renderer.py
# produces on a real run — and quota-retry's success path forwards it via
# record_claude_usage_from_sidecar (quota-retry.sh, declare -F guard). The
# renderer itself never clobbers the stub's sidecar: it only writes when a
# stream-json result event arrives, and the stub emits no stdout at all.
#
#   1. GOAL_SESSION_DIR set   → telemetry.jsonl gains exactly one claude_usage
#                               row attributed to the dispatching agent (qa).
#   2. GOAL_SESSION_DIR unset → NO telemetry file is written anywhere
#                               (lib/telemetry.sh's documented no-op contract:
#                               standalone phase mode stays telemetry-free).
#
# No API calls; a couple of seconds total.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ── Sandbox builder (fresh per case; engine scripts embedded) ────────────────
make_sandbox() {
  local tag="$1"
  SBX="$WORK/proj-$tag"
  mkdir -p "$SBX"
  cp -r "$ENGINE_ROOT/scripts" "$SBX/"
  mkdir -p "$SBX/docs/phases"
  cat > "$SBX/docs/phases/phase-tt.md" <<'EOF'
# Phase tt — telemetry sourcing unit-test spec
Build nothing; the stub agent writes the test plan.
EOF
}

# ── Stub claude: writes the prompt's target file + a fake usage sidecar ──────
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<'EOF'
#!/usr/bin/env bash
prompt="$*"
out="$(printf '%s\n' "$prompt" | sed -n 's/^Write the functional test plan to: //p' | head -n1)"
if [[ -n "$out" ]]; then
  mkdir -p "$(dirname "$out")"
  printf 'stub test plan\n' > "$out"
fi
if [[ -n "${CHAIN_CLAUDE_USAGE_SIDECAR:-}" ]]; then
  printf '{"input_tokens":111,"output_tokens":22,"total_cost_usd":0.0042,"session_id":"stub-upstream","stub_marker":"token8-test"}' \
    > "$CHAIN_CLAUDE_USAGE_SIDECAR"
fi
exit 0
EOF
chmod +x "$STUB_DIR/claude"

export CHAIN_TELEMETRY_TOKENS=true
export CHAIN_DISABLE_AUTO_WAIT=true

# ══ Case 1: GOAL_SESSION_DIR set → usage row with the right agent ════════════
make_sandbox goal
export GOAL_SESSION_DIR="$SBX/runs/goal-session-tt"
mkdir -p "$GOAL_SESSION_DIR"
export GOAL_SESSION_ID="tt"
export GOAL_ITER_INDEX=1
rc=0
( cd "$SBX" && PATH="$STUB_DIR:$PATH" bash scripts/automation/generate-test-plan.sh phase-tt ) \
  >"$WORK/case1.log" 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] && assert "1: converted script exits 0 under goal mode" "pass" \
  || { assert "1: converted script exits 0 under goal mode (rc=$rc)" "fail"; sed -n '1,30p' "$WORK/case1.log"; }
TLM="$GOAL_SESSION_DIR/telemetry.jsonl"
[[ -f "$TLM" ]] && assert "1: telemetry.jsonl written under GOAL_SESSION_DIR" "pass" \
  || assert "1: telemetry.jsonl written under GOAL_SESSION_DIR" "fail"
if [[ -f "$TLM" ]] && jq -es '
    [ .[] | select(.event=="claude_usage") ]
    | length == 1 and .[0].agent == "qa" and .[0].stub_marker == "token8-test"
  ' "$TLM" >/dev/null 2>&1; then
  assert "1: exactly one claude_usage row, attributed to agent qa, sidecar payload intact" "pass"
else
  assert "1: exactly one claude_usage row, attributed to agent qa, sidecar payload intact (got: $(cat "$TLM" 2>/dev/null))" "fail"
fi

# ══ Case 2: GOAL_SESSION_DIR unset → no telemetry file anywhere ══════════════
make_sandbox phase
unset GOAL_SESSION_DIR GOAL_SESSION_ID GOAL_ITER_INDEX
rc=0
( cd "$SBX" && PATH="$STUB_DIR:$PATH" bash scripts/automation/generate-test-plan.sh phase-tt ) \
  >"$WORK/case2.log" 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] && assert "2: converted script exits 0 standalone (phase mode)" "pass" \
  || { assert "2: converted script exits 0 standalone (rc=$rc)" "fail"; sed -n '1,30p' "$WORK/case2.log"; }
[[ -f "$SBX/reports/qa/phase-tt-test-plan.md" ]] \
  && assert "2: dispatch itself still works (test plan written)" "pass" \
  || assert "2: dispatch itself still works (test plan written)" "fail"
_stray="$(find "$SBX" -name telemetry.jsonl 2>/dev/null || true)"
[[ -z "$_stray" ]] \
  && assert "2: NO telemetry file written standalone (no-op contract holds)" "pass" \
  || assert "2: NO telemetry file written standalone (found: $_stray)" "fail"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
