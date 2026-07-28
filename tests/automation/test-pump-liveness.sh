#!/usr/bin/env bash
# test-pump-liveness.sh — REL-3 integration proof: a dead pump pid on a CLAIMED
# dispatch fast-pauses the REAL engine through the standard exit-70 machinery,
# indistinguishable downstream from a timeout pause:
#   session.json status AWAITING_PUMP · REL-4 engine lock RELEASED · no
#   retro-input.md (EVO-2's terminal-only filter untouched) · resume re-acquires
#   and re-runs the iteration (fresh dispatch request), then fast-pauses again.
#
# The waiter-level unit cases (dead pid timing, cross-host, old-format,
# live-pid) live in lib/interactive-dispatch.sh --self-test (Tests 16-19);
# pump-side ident writing in goal-await-dispatch.sh --self-test (6-7). This
# file proves the END-TO-END pause plumbing on the real run-goal.sh.
#
# Offline, no model calls. The inflight cap stays at its 7200s default, so the
# engine exiting within seconds is attributable ONLY to the pid fast path.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}

WORK="$(mktemp -d)"
_SPAWNED_PGIDS=()
cleanup() {
  local pg
  for pg in "${_SPAWNED_PGIDS[@]:-}"; do
    [[ -n "$pg" ]] && kill -KILL -- "-$pg" 2>/dev/null
  done
  pkill -KILL -f "$WORK/" 2>/dev/null
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

wait_for() {
  local deadline=$(( $(date +%s) + $1 )); shift
  while ! "$@" 2>/dev/null; do
    [[ $(date +%s) -ge $deadline ]] && return 1
    sleep 0.2
  done
  return 0
}

HOST="$(hostname)"

# ── Sandbox project (consumer-repo layout, same recipe as test-engine-lock) ──
SBX="$WORK/proj"
mkdir -p "$SBX"
cp -r "$ENGINE_ROOT/scripts" "$SBX/"
mkdir -p "$SBX/docs/phases" "$SBX/reports" "$SBX/src" "$SBX/.claude/agents"
touch "$SBX/.claude/agents/developer.md"
git init -q "$SBX"
echo "print('v1')" > "$SBX/src/app.py"
cat > "$SBX/docs/goal.md" <<'EOF'
# Goal

Tiny CSV exporter web app.

## Must-have user journeys

- **J-01: Open the page**
  - Steps: open /
  - Acceptance: page loads

## Anti-goals

- no paid SaaS
EOF
git -C "$SBX" add -A
git -C "$SBX" -c user.email=t@t -c user.name=t commit -qm base

TMPROOT="$WORK/tmproot"
mkdir -p "$TMPROOT"

# Interactive backend needs a `claude` on PATH only for require_cli; dispatches
# go through the file channel, so the stub is never asked to do real work.
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
printf '#!/usr/bin/env bash\necho "stub 0.0"\n' > "$STUB_DIR/claude"
chmod +x "$STUB_DIR/claude"

# CHAIN_SESSION_RETRO is deliberately NOT set: the no-retro assertion below
# must exercise EVO-2's real terminal-only default, not an env off-switch.
run_goal_bg() {
  local log="$1"; shift
  ( cd "$SBX" && env "PATH=$STUB_DIR:$PATH" \
      CHAIN_DOCTOR=false CHAIN_GOAL_LINT=false \
      CHAIN_TMP_ROOT="$TMPROOT" CHAIN_TMP_LEGACY_ROOTS="" \
      CHAIN_BACKEND_PORT=48411 CHAIN_FRONTEND_PORT=48412 \
      setsid bash scripts/automation/run-goal.sh "$@" ) >"$log" 2>&1 &
}

SDIR="$SBX/runs/goal-session-pl1"
DISP="$SDIR/dispatch"
GLOCK="$SDIR/.engine.lock"
ENGINE_LOG="$SDIR/engine.log"

ready_req() { ls "$DISP"/req.*.ready >/dev/null 2>&1; }

# claim_with_dead_pump — claim the pending request with a freshly-killed
# victim's ident (pid+host+starttime), the exact shape a v3 pump writes.
claim_with_dead_pump() {
  local req vpid vstt
  req="$(ls "$DISP"/req.*.ready 2>/dev/null | head -1)"
  [[ -n "$req" ]] || return 1
  setsid sleep 300 &
  vpid=$!
  _SPAWNED_PGIDS+=("$vpid")
  vstt="$(sed 's/.*) //' "/proc/$vpid/stat" 2>/dev/null | awk '{print $20}')"
  printf 'pid=%s\nhost=%s\nstarttime=%s\n' "$vpid" "$HOST" "$vstt" > "${req%.ready}.started.tmp"
  mv "${req%.ready}.started.tmp" "${req%.ready}.started"
  kill -KILL "$vpid" 2>/dev/null
  wait "$vpid" 2>/dev/null
  echo "$vpid"
}

session_status() {
  python3 -c "import json; print(json.load(open('$SDIR/session.json'))['status'])" 2>/dev/null || echo "?"
}
paused() { [[ "$(session_status)" == "AWAITING_PUMP" ]]; }

echo ""
echo "=== REL-3 integration: dead pump → fast AWAITING_PUMP, downstream-identical ==="
echo ""

run_goal_bg "$WORK/pl1.log" --session-id pl1 --no-push-per-iter --interactive
if wait_for 30 ready_req; then
  assert "engine published the baseline dispatch request" "pass"
else
  assert "engine published the baseline dispatch request" "fail"
  sed -n '1,30p' "$WORK/pl1.log"
fi
E1="$(cat "$SDIR/engine.pid" 2>/dev/null || echo "")"
[[ -n "$E1" ]] && _SPAWNED_PGIDS+=("$E1")

VPID="$(claim_with_dead_pump)"
T0="$(date +%s)"
if wait_for 60 paused; then
  EL=$(( $(date +%s) - T0 ))
  assert "dead pump pid → session paused AWAITING_PUMP" "pass"
  [[ "$EL" -le 45 ]] \
    && assert "pause arrived in ${EL}s — the pid fast path, not the 7200s cap" "pass" \
    || assert "pause arrived in ${EL}s — too slow for the fast path" "fail"
else
  assert "dead pump pid → session paused AWAITING_PUMP (status=$(session_status))" "fail"
  assert "pause arrived fast (never paused)" "fail"
  tail -15 "$ENGINE_LOG" 2>/dev/null
fi
wait_for 15 bash -c "[[ ! -f '$SDIR/engine.pid' ]]" \
  && assert "engine process exited (pause is an exit, not a hang)" "pass" \
  || assert "engine process exited (pause is an exit, not a hang)" "fail"
grep -q 'pump is gone' "$ENGINE_LOG" 2>/dev/null && grep -q "$VPID" "$ENGINE_LOG" 2>/dev/null \
  && assert "engine log names the dead pump pid (diagnosable from the log alone)" "pass" \
  || assert "engine log names the dead pump pid (diagnosable from the log alone)" "fail"
grep -q 'pump dead' "$DISP/.awaiting-pump" 2>/dev/null \
  && assert ".awaiting-pump marker explains the pause" "pass" \
  || assert ".awaiting-pump marker explains the pause" "fail"
# wait_for, not an instant check: the engine releases the lock in its exit
# path moments after engine.pid disappears — under machine load the gap is
# visible and an instant check races (observed as an in-suite-only flake).
wait_for 15 bash -c "[[ ! -e '$GLOCK' ]]" \
  && assert "REL-4 engine lock released by the fast pause" "pass" \
  || assert "REL-4 engine lock released by the fast pause" "fail"
[[ ! -f "$SDIR/state/retro-input.md" ]] \
  && assert "no retro-input.md — EVO-2's terminal-only filter untouched" "pass" \
  || assert "no retro-input.md — EVO-2's terminal-only filter untouched" "fail"

echo ""
echo "=== resume: re-acquires the lock, re-runs the iteration, fast-pauses again ==="
echo ""

run_goal_bg "$WORK/pl2.log" --resume --session-id pl1 --no-push-per-iter --interactive
if wait_for 40 ready_req; then
  assert "resume re-ran the iteration (fresh dispatch request published)" "pass"
  [[ -f "$GLOCK/pid" ]] \
    && assert "resume re-acquired the engine lock (held while running)" "pass" \
    || assert "resume re-acquired the engine lock (held while running)" "fail"
  E2="$(cat "$SDIR/engine.pid" 2>/dev/null || echo "")"
  [[ -n "$E2" ]] && _SPAWNED_PGIDS+=("$E2")
  VPID2="$(claim_with_dead_pump)"
  if wait_for 60 paused; then
    assert "second dead pump → AWAITING_PUMP again" "pass"
  else
    assert "second dead pump → AWAITING_PUMP again (status=$(session_status))" "fail"
  fi
  wait_for 15 bash -c "[[ ! -e '$GLOCK' ]]" \
    && assert "lock released again after the second fast pause" "pass" \
    || assert "lock released again after the second fast pause" "fail"
else
  for t in "resume re-ran the iteration (fresh dispatch request published)" \
           "resume re-acquired the engine lock (held while running)" \
           "second dead pump → AWAITING_PUMP again" \
           "lock released again after the second fast pause"; do
    assert "$t (resume never dispatched)" "fail"
  done
  sed -n '1,30p' "$WORK/pl2.log"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo ""
[[ $FAIL -gt 0 ]] && exit 1
exit 0
