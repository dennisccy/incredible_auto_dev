#!/usr/bin/env bash
# test-engine-lock.sh — REL-4 cross-session engine lock:
#   A. lib/engine-lock.sh unit semantics (mkdir-atomic acquire, refuse-fresh
#      with the distinct exit code, stale-replace, owner-only release,
#      cross-host TTL, empty-metadata grace)
#   B. run-goal.sh wiring: the REAL engine in a sandbox with a stub `claude` —
#      lock held while running, second start refuses fast, SIGKILL leaves a
#      stale lock the next start replaces and proceeds, process-group INT
#      (faithful Ctrl-C) releases, AWAITING_* pause paths release, resume
#      re-acquires. Plus the trap-composition proof: the PRE-EXISTING cleanups
#      (engine.pid removal, REL-13 tmp-dir removal) still run after REL-4
#      extended the EXIT handler.
#   C. run-phase.sh wiring: the repo-level runs/.phase.lock twin behaves the
#      same (hold, refuse, INT release, transport-pause release).
#
# Offline, no model calls; signals only ever target processes this test
# spawned (setsid process groups in a throwaway sandbox).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$ENGINE_ROOT/scripts/automation/lib/engine-lock.sh"

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
  # Belt-and-suspenders: anything still referencing this test's private
  # sandbox path is ours (mktemp-unique) — never touches foreign processes.
  pkill -KILL -f "$WORK/" 2>/dev/null
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

# wait_for <seconds> <cmd...> — poll until cmd succeeds; rc 1 on timeout.
wait_for() {
  local deadline=$(( $(date +%s) + $1 )); shift
  while ! "$@" 2>/dev/null; do
    [[ $(date +%s) -ge $deadline ]] && return 1
    sleep 0.2
  done
  return 0
}

# wait_gone <seconds> <path> — poll until path no longer exists.
_gone() { [[ ! -e "$1" ]]; }
wait_gone() { wait_for "$1" _gone "$2"; }

HOST="$(hostname)"

echo ""
echo "=== A. lib/engine-lock.sh unit semantics ==="
echo ""

if [[ ! -f "$LIB" ]]; then
  for t in "A1 acquire creates lock with pid/host/epoch metadata" \
           "A2 second acquire refuses with ENGINE_LOCK_REFUSED_EXIT and a clear message" \
           "A3 non-owner release leaves the lock in place" \
           "A4 owner release removes the lock; releasing again is a no-op" \
           "A5 same-host dead pid is stale: replaced with one logged warning" \
           "A6 cross-host young lock refuses" \
           "A7 cross-host lock older than TTL is replaced loudly" \
           "A8 empty lock dir: young refuses, old is stale"; do
    assert "$t (lib/engine-lock.sh missing)" "fail"
  done
else
  # A1: acquire in a background holder process; metadata must name that process.
  # $0 is a real name (lands in the lock's cmd file AND in /proc cmdline), and
  # `sleep & wait` keeps the holder a live BASH — a bare trailing `sleep` gets
  # tail-exec'd by bash, morphing the process image and tripping the lib's
  # pid-recycled cmdline check (a fate real engines can't meet: run-goal.sh /
  # run-phase.sh keep their script path in argv for their whole lives).
  L1="$WORK/a1.lock"
  bash -c 'source "'"$LIB"'"; acquire_engine_lock "$1" "unit holder" || exit $?; sleep 60 & wait' engine-lock-a1-holder "$L1" &
  H1=$!
  if wait_for 10 test -f "$L1/pid"; then
    pid_ok=false; host_ok=false; epoch_ok=false
    [[ "$(cat "$L1/pid")" == "$H1" ]] && pid_ok=true
    [[ "$(cat "$L1/host" 2>/dev/null)" == "$HOST" ]] && host_ok=true
    [[ "$(cat "$L1/epoch" 2>/dev/null)" =~ ^[0-9]+$ ]] && epoch_ok=true
    if $pid_ok && $host_ok && $epoch_ok; then
      assert "A1 acquire creates lock with pid/host/epoch metadata" "pass"
    else
      assert "A1 acquire creates lock with pid/host/epoch metadata (pid=$pid_ok host=$host_ok epoch=$epoch_ok)" "fail"
    fi
  else
    assert "A1 acquire creates lock with pid/host/epoch metadata (never appeared)" "fail"
  fi

  # A2: a second process must refuse fast with the distinct code + message.
  rc=0; err="$WORK/a2.err"
  bash -c 'source "'"$LIB"'"; acquire_engine_lock "$1" "unit second"' _ "$L1" 2>"$err" || rc=$?
  want=$(bash -c 'source "'"$LIB"'"; echo "$ENGINE_LOCK_REFUSED_EXIT"')
  [[ "$rc" == "$want" && "$rc" != "0" ]] \
    && assert "A2 second acquire refuses with ENGINE_LOCK_REFUSED_EXIT ($want)" "pass" \
    || assert "A2 second acquire refuses with ENGINE_LOCK_REFUSED_EXIT (want $want got $rc)" "fail"
  if grep -q "$H1" "$err" && grep -q "$HOST" "$err" && grep -qi "TROUBLESHOOTING" "$err"; then
    assert "A2 refusal message names pid + host + TROUBLESHOOTING pointer" "pass"
  else
    assert "A2 refusal message names pid + host + TROUBLESHOOTING pointer ($(tr '\n' ' ' < "$err" | head -c 200))" "fail"
  fi

  # A3: releasing from a process that does not own the lock must not remove it.
  bash -c 'source "'"$LIB"'"; release_engine_lock "$1"' _ "$L1" 2>/dev/null
  [[ -d "$L1" && "$(cat "$L1/pid" 2>/dev/null)" == "$H1" ]] \
    && assert "A3 non-owner release leaves the lock in place" "pass" \
    || assert "A3 non-owner release leaves the lock in place" "fail"
  kill -KILL "$H1" 2>/dev/null; wait "$H1" 2>/dev/null

  # A4: owner acquire→release removes it; double release is a clean no-op.
  L4="$WORK/a4.lock"
  rc=0
  bash -c 'source "'"$LIB"'"
           acquire_engine_lock "$1" "unit a4" || exit 40
           [[ -f "$1/pid" ]] || exit 41
           release_engine_lock || exit 42
           [[ ! -e "$1" ]] || exit 43
           release_engine_lock || exit 44' _ "$L4" || rc=$?
  [[ "$rc" -eq 0 ]] \
    && assert "A4 owner release removes the lock; releasing again is a no-op" "pass" \
    || assert "A4 owner release removes the lock; releasing again is a no-op (step $rc)" "fail"

  # A5: same-host dead pid → stale → replaced with a logged warning.
  L5="$WORK/a5.lock"
  mkdir -p "$L5"
  printf '999999999\n' > "$L5/pid"; printf '%s\n' "$HOST" > "$L5/host"
  printf '%s\n' "$(( $(date +%s) - 500 ))" > "$L5/epoch"
  rc=0; err="$WORK/a5.err"
  bash -c 'source "'"$LIB"'"; acquire_engine_lock "$1" "unit a5" || exit $?; cat "$1/pid"' _ "$L5" >"$WORK/a5.out" 2>"$err" || rc=$?
  new_pid="$(cat "$WORK/a5.out" 2>/dev/null)"
  if [[ "$rc" -eq 0 && "$new_pid" != "999999999" && -n "$new_pid" ]] && grep -qi 'stale' "$err"; then
    assert "A5 same-host dead pid is stale: replaced with one logged warning" "pass"
  else
    assert "A5 same-host dead pid is stale: replaced (rc=$rc pid=$new_pid warn=$(grep -ci stale "$err" 2>/dev/null))" "fail"
  fi

  # A6/A7: cross-host uses the age TTL (knob), since kill -0 can't cross hosts.
  L6="$WORK/a6.lock"
  mkdir -p "$L6"
  printf '4242\n' > "$L6/pid"; printf 'some-other-host\n' > "$L6/host"
  printf '%s\n' "$(date +%s)" > "$L6/epoch"
  rc=0
  CHAIN_ENGINE_LOCK_CROSS_HOST_TTL=3600 \
    bash -c 'source "'"$LIB"'"; acquire_engine_lock "$1" "unit a6"' _ "$L6" 2>/dev/null || rc=$?
  [[ "$rc" == "$want" ]] \
    && assert "A6 cross-host young lock refuses" "pass" \
    || assert "A6 cross-host young lock refuses (want $want got $rc)" "fail"

  printf '%s\n' "$(( $(date +%s) - 7200 ))" > "$L6/epoch"
  rc=0; err="$WORK/a7.err"
  CHAIN_ENGINE_LOCK_CROSS_HOST_TTL=3600 \
    bash -c 'source "'"$LIB"'"; acquire_engine_lock "$1" "unit a7"' _ "$L6" 2>"$err" || rc=$?
  if [[ "$rc" -eq 0 ]] && grep -qi 'stale' "$err"; then
    assert "A7 cross-host lock older than TTL is replaced loudly" "pass"
  else
    assert "A7 cross-host lock older than TTL is replaced loudly (rc=$rc)" "fail"
  fi

  # A8: metadata-free lock dir (acquirer crashed mid-write): young → refuse
  # (a racing acquirer may still be writing); old → stale.
  L8="$WORK/a8.lock"
  mkdir -p "$L8"
  rc=0
  bash -c 'source "'"$LIB"'"; acquire_engine_lock "$1" "unit a8"' _ "$L8" 2>/dev/null || rc=$?
  young_ok=false; [[ "$rc" == "$want" ]] && young_ok=true
  touch -d '10 minutes ago' "$L8"
  rc=0; err="$WORK/a8.err"
  bash -c 'source "'"$LIB"'"; acquire_engine_lock "$1" "unit a8b"' _ "$L8" 2>"$err" || rc=$?
  if $young_ok && [[ "$rc" -eq 0 ]] && grep -qi 'stale' "$err"; then
    assert "A8 empty lock dir: young refuses, old is stale" "pass"
  else
    assert "A8 empty lock dir: young refuses, old is stale (young_refuse=$young_ok old_rc=$rc)" "fail"
  fi
fi

echo ""
echo "=== B. run-goal.sh wiring (real engine, sandbox, stub claude) ==="
echo ""

# ── Sandbox project with the engine's scripts embedded (consumer-repo layout) ─
SBX="$WORK/proj"
mkdir -p "$SBX"
cp -r "$ENGINE_ROOT/scripts" "$SBX/"
mkdir -p "$SBX/docs/phases" "$SBX/reports" "$SBX/src" "$SBX/.claude/agents"
# ensure_cli_assets_synced no-ops when the rendered marker exists.
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
- **J-02: Export CSV**
  - Steps: click export
  - Acceptance: csv downloads

## Anti-goals

- no paid SaaS
EOF
git -C "$SBX" add -A
git -C "$SBX" -c user.email=t@t -c user.name=t commit -qm base

TMPROOT="$WORK/tmproot"
mkdir -p "$TMPROOT"

# Stub claude, two flavors. sleep: linger holding the lock (dispatch in
# flight); 70: transport-unavailable so the engine pauses fast (AWAITING_PUMP).
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
CANARY="$WORK/dispatched-agents.log"
stub_sleep() {
  cat > "$STUB_DIR/claude" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == "--version" ]] && { echo "stub 0.0"; exit 0; }
echo "\${CHAIN_CURRENT_AGENT:-unknown}" >> "$CANARY"
sleep 120
EOF
  chmod +x "$STUB_DIR/claude"
}
stub_70() {
  cat > "$STUB_DIR/claude" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == "--version" ]] && { echo "stub 0.0"; exit 0; }
echo "\${CHAIN_CURRENT_AGENT:-unknown}" >> "$CANARY"
exit 70
EOF
  chmod +x "$STUB_DIR/claude"
}

# run_goal_bg <logfile> <args...> — REAL run-goal.sh in its own session
# (setsid) so signals can target the whole process group, Ctrl-C-style.
# The python exec shim restores SIGINT to SIG_DFL first: bash gives
# BACKGROUNDED children SIGINT=SIG_IGN (job control off), and a signal ignored
# at shell entry can never be re-trapped — the engine would be born INT-deaf,
# a disposition no real terminal Ctrl-C target ever has.
run_goal_bg() {
  local log="$1"; shift
  ( cd "$SBX" && env "PATH=$STUB_DIR:$PATH" \
      CHAIN_DOCTOR=false CHAIN_GOAL_LINT=false CHAIN_SESSION_RETRO=false \
      CHAIN_TMP_ROOT="$TMPROOT" CHAIN_TMP_LEGACY_ROOTS="" \
      CHAIN_BACKEND_PORT=48311 CHAIN_FRONTEND_PORT=48312 \
      setsid python3 -c 'import signal,os,sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])' \
      bash scripts/automation/run-goal.sh "$@" ) >"$log" 2>&1 &
}

# run_goal_fg <timeout> <logfile> <args...> — foreground, bounded.
run_goal_fg() {
  local to="$1" log="$2"; shift 2
  ( cd "$SBX" && env "PATH=$STUB_DIR:$PATH" \
      CHAIN_DOCTOR=false CHAIN_GOAL_LINT=false CHAIN_SESSION_RETRO=false \
      CHAIN_TMP_ROOT="$TMPROOT" CHAIN_TMP_LEGACY_ROOTS="" \
      CHAIN_BACKEND_PORT=48311 CHAIN_FRONTEND_PORT=48312 \
      timeout "$to" bash scripts/automation/run-goal.sh "$@" ) >"$log" 2>&1
}

# Scoped tmp checks. A SIGKILLed engine legitimately leaves its iad.* dir
# behind (the trap never ran; the next engine start's janitor sweeps it by
# owner-pid liveness/age), so global "no iad.* at all" would flag REL-13's
# documented behavior. Assert per-engine (dir names end in the owner pid) or
# by before/after snapshot instead.
no_iad_for() { ! ls -d "$TMPROOT"/iad.*."$1" >/dev/null 2>&1; }
iad_snapshot() { ls -d "$TMPROOT"/iad.* 2>/dev/null | sort | tr '\n' ' '; }

SDIR="$SBX/runs/goal-session-b1"
GLOCK="$SDIR/.engine.lock"

# ── B1: a running engine holds the lock (sleeping stub keeps it in-dispatch) ──
stub_sleep
: > "$CANARY"
run_goal_bg "$WORK/b1.log" --session-id b1 --no-push-per-iter
if wait_for 20 test -f "$GLOCK/pid"; then
  assert "B1 running engine holds runs/goal-session-<sid>/.engine.lock" "pass"
else
  assert "B1 running engine holds runs/goal-session-<sid>/.engine.lock" "fail"
  sed -n '1,25p' "$WORK/b1.log"
fi
ENGINE_PID="$(cat "$SDIR/engine.pid" 2>/dev/null || echo "")"
LOCK_PID="$(cat "$GLOCK/pid" 2>/dev/null || echo "")"
_SPAWNED_PGIDS+=("$ENGINE_PID")
[[ -n "$ENGINE_PID" && "$LOCK_PID" == "$ENGINE_PID" ]] \
  && assert "B1 lock pid matches the engine's recorded pid" "pass" \
  || assert "B1 lock pid matches the engine's recorded pid (lock=$LOCK_PID engine=$ENGINE_PID)" "fail"

# ── B2: second start refuses fast with the distinct exit code ────────────────
# Remove engine.pid first: the resume self-heal deliberately SIGTERMs a live
# prior engine (takeover by design); the LOCK is the layer that must catch the
# cases self-heal can't see (lost pidfile, simultaneous starts).
rm -f "$SDIR/engine.pid"
n_before="$(wc -l < "$CANARY" 2>/dev/null || echo 0)"
rc=0; run_goal_fg 30 "$WORK/b2.log" --resume --session-id b1 --no-push-per-iter || rc=$?
[[ "$rc" -eq 86 ]] \
  && assert "B2 second start refuses fast with exit 86" "pass" \
  || { assert "B2 second start refuses fast with exit 86 (rc=$rc)" "fail"; sed -n '1,25p' "$WORK/b2.log"; }
grep -q "$LOCK_PID" "$WORK/b2.log" && grep -qi "TROUBLESHOOTING" "$WORK/b2.log" \
  && assert "B2 refusal names the holder pid and points at TROUBLESHOOTING" "pass" \
  || assert "B2 refusal names the holder pid and points at TROUBLESHOOTING" "fail"
n_after="$(wc -l < "$CANARY" 2>/dev/null || echo 0)"
[[ "$n_after" == "$n_before" ]] \
  && assert "B2 refused start never reached an agent dispatch" "pass" \
  || assert "B2 refused start never reached an agent dispatch ($n_before -> $n_after)" "fail"
[[ -f "$GLOCK/pid" && "$(cat "$GLOCK/pid")" == "$LOCK_PID" ]] \
  && assert "B2 holder's lock survives the refused start" "pass" \
  || assert "B2 holder's lock survives the refused start" "fail"

# ── B3: SIGKILL the holder (whole group, no traps) → stale lock left behind ──
kill -KILL -- "-$ENGINE_PID" 2>/dev/null
wait_for 10 bash -c '! kill -0 '"$ENGINE_PID"' 2>/dev/null'
[[ -f "$GLOCK/pid" ]] \
  && assert "B3 SIGKILL leaves the lock behind (dead pid inside)" "pass" \
  || assert "B3 SIGKILL leaves the lock behind (dead pid inside)" "fail"

# ── B4: next start detects stale, replaces loudly, proceeds; pause releases ──
stub_70
: > "$CANARY"
rc=0; run_goal_fg 60 "$WORK/b4.log" --resume --session-id b1 --no-push-per-iter || rc=$?
[[ "$rc" -eq 0 ]] \
  && assert "B4 start over a stale lock exits 0 (proceeded to the pause)" "pass" \
  || { assert "B4 start over a stale lock exits 0 (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/b4.log"; }
grep -qi 'stale' "$WORK/b4.log" \
  && assert "B4 stale replacement is logged" "pass" \
  || assert "B4 stale replacement is logged" "fail"
[[ -s "$CANARY" ]] \
  && assert "B4 engine proceeded past the lock (dispatch attempted)" "pass" \
  || assert "B4 engine proceeded past the lock (dispatch attempted)" "fail"
status="$(python3 -c "import json; print(json.load(open('$SDIR/session.json'))['status'])" 2>/dev/null || echo "?")"
[[ "$status" == "AWAITING_PUMP" ]] \
  && assert "B4 transport-70 pause recorded (AWAITING_PUMP)" "pass" \
  || assert "B4 transport-70 pause recorded (AWAITING_PUMP, got $status)" "fail"
[[ ! -e "$GLOCK" ]] \
  && assert "B4 AWAITING_PUMP pause released the lock" "pass" \
  || assert "B4 AWAITING_PUMP pause released the lock" "fail"

# ── B5: process-group INT (faithful Ctrl-C) releases + pre-existing cleanups ──
stub_sleep
SDIR5="$SBX/runs/goal-session-b5"
GLOCK5="$SDIR5/.engine.lock"
run_goal_bg "$WORK/b5.log" --session-id b5 --no-push-per-iter
if wait_for 20 test -f "$GLOCK5/pid"; then
  E5="$(cat "$SDIR5/engine.pid" 2>/dev/null || echo "")"
  _SPAWNED_PGIDS+=("$E5")
  krc=0; kill -INT -- "-$E5" || krc=$?
  if wait_gone 20 "$GLOCK5"; then
    assert "B5 Ctrl-C (group INT): lock released" "pass"
  else
    assert "B5 Ctrl-C (group INT): lock released (E5='$E5' kill_rc=$krc)" "fail"
    ps -eo pid,pgid,stat,cmd | awk -v pg="$E5" '$2==pg {print}' | cut -c1-120
    tail -5 "$WORK/b5.log"
  fi
  wait_gone 10 "$SDIR5/engine.pid" \
    && assert "B5 trap composition: pre-existing engine.pid cleanup still runs" "pass" \
    || assert "B5 trap composition: pre-existing engine.pid cleanup still runs" "fail"
  wait_for 10 no_iad_for "$E5" \
    && assert "B5 trap composition: pre-existing REL-13 tmp-dir cleanup still runs" "pass" \
    || assert "B5 trap composition: pre-existing REL-13 tmp-dir cleanup still runs ($(ls "$TMPROOT" 2>/dev/null | tr '\n' ' '))" "fail"
  status="$(python3 -c "import json; print(json.load(open('$SDIR5/session.json'))['status'])" 2>/dev/null || echo "?")"
  [[ "$status" == "ABORTED" ]] \
    && assert "B5 aborted session records ABORTED" "pass" \
    || assert "B5 aborted session records ABORTED (got $status)" "fail"
else
  for t in "B5 Ctrl-C (group INT): lock released" \
           "B5 trap composition: pre-existing engine.pid cleanup still runs" \
           "B5 trap composition: pre-existing REL-13 tmp-dir cleanup still runs" \
           "B5 aborted session records ABORTED"; do assert "$t (engine never locked)" "fail"; done
  sed -n '1,25p' "$WORK/b5.log"
  # Reap the never-locked engine so it can't pollute later scenarios.
  E5="$(cat "$SDIR5/engine.pid" 2>/dev/null || echo "")"
  [[ -n "$E5" ]] && { _SPAWNED_PGIDS+=("$E5"); kill -KILL -- "-$E5" 2>/dev/null; }
fi

# ── B6: AWAITING_GITHUB_AUTH pause path (zero dispatches) releases ────────────
# Fresh session, per-iter push defaulted ON, sandbox has NO origin remote →
# the GitHub preflight pauses the session before any dispatch.
: > "$CANARY"
SDIR6="$SBX/runs/goal-session-b6"
GLOCK6="$SDIR6/.engine.lock"
snap6="$(iad_snapshot)"
rc=0; run_goal_fg 60 "$WORK/b6.log" --session-id b6 || rc=$?
status="$(python3 -c "import json; print(json.load(open('$SDIR6/session.json'))['status'])" 2>/dev/null || echo "?")"
{ [[ "$rc" -eq 0 && "$status" == "AWAITING_GITHUB_AUTH" ]]; } \
  && assert "B6 GitHub preflight pause: exit 0, status AWAITING_GITHUB_AUTH" "pass" \
  || { assert "B6 GitHub preflight pause (rc=$rc status=$status)" "fail"; sed -n '1,40p' "$WORK/b6.log"; }
[[ ! -s "$CANARY" ]] \
  && assert "B6 pause happened before any dispatch" "pass" \
  || assert "B6 pause happened before any dispatch" "fail"
[[ ! -e "$GLOCK6" ]] \
  && assert "B6 AWAITING_GITHUB_AUTH pause released the lock" "pass" \
  || assert "B6 AWAITING_GITHUB_AUTH pause released the lock" "fail"
[[ ! -f "$SDIR6/engine.pid" ]] \
  && assert "B6 trap composition: engine.pid cleaned on pause exit" "pass" \
  || assert "B6 trap composition: engine.pid cleaned on pause exit" "fail"
[[ "$(iad_snapshot)" == "$snap6" ]] \
  && assert "B6 trap composition: tmp dir cleaned on pause exit" "pass" \
  || assert "B6 trap composition: tmp dir cleaned on pause exit (before='$snap6' after='$(iad_snapshot)')" "fail"

# ── B7: resume after a pause re-acquires cleanly (never refuses) ──────────────
rc=0; run_goal_fg 60 "$WORK/b7.log" --resume --session-id b6 || rc=$?
status="$(python3 -c "import json; print(json.load(open('$SDIR6/session.json'))['status'])" 2>/dev/null || echo "?")"
if [[ "$rc" -eq 0 && "$status" == "AWAITING_GITHUB_AUTH" ]] && ! grep -qi 'REFUSED' "$WORK/b7.log"; then
  assert "B7 resume after pause re-acquires (no refusal) and pauses again" "pass"
else
  assert "B7 resume after pause re-acquires (rc=$rc status=$status refused=$(grep -ci REFUSED "$WORK/b7.log"))" "fail"
fi
[[ ! -e "$GLOCK6" ]] \
  && assert "B7 lock released again after the second pause" "pass" \
  || assert "B7 lock released again after the second pause" "fail"

echo ""
echo "=== C. run-phase.sh wiring (repo-level runs/.phase.lock twin) ==="
echo ""

cat > "$SBX/docs/phases/lockphase.md" <<'EOF'
# Phase: lockphase

## Objective
Exercise the phase-runner lock (test fixture; never implemented).

## IN SCOPE
- nothing

## Tests
- TC-1: none
- TC-2: none
- TC-3: none
EOF
cp "$SBX/docs/phases/lockphase.md" "$SBX/docs/phases/lockphase2.md"

PLOCK="$SBX/runs/.phase.lock"

# Same SIGINT=SIG_DFL shim as run_goal_bg (see the rationale there).
run_phase_bg() {
  local log="$1"; shift
  ( cd "$SBX" && env "PATH=$STUB_DIR:$PATH" \
      CHAIN_DOCTOR=false CHAIN_TMP_ROOT="$TMPROOT" CHAIN_TMP_LEGACY_ROOTS="" \
      CHAIN_BACKEND_PORT=48313 CHAIN_FRONTEND_PORT=48314 \
      setsid python3 -c 'import signal,os,sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])' \
      bash scripts/automation/run-phase.sh "$@" ) >"$log" 2>&1 &
}
run_phase_fg() {
  local to="$1" log="$2"; shift 2
  ( cd "$SBX" && env "PATH=$STUB_DIR:$PATH" \
      CHAIN_DOCTOR=false CHAIN_TMP_ROOT="$TMPROOT" CHAIN_TMP_LEGACY_ROOTS="" \
      CHAIN_BACKEND_PORT=48313 CHAIN_FRONTEND_PORT=48314 \
      timeout "$to" bash scripts/automation/run-phase.sh "$@" ) >"$log" 2>&1
}

# ── C1: a running phase pipeline holds the repo-level lock ────────────────────
stub_sleep
run_phase_bg "$WORK/c1.log" lockphase --no-finalize
if wait_for 20 test -f "$PLOCK/pid"; then
  assert "C1 running run-phase.sh holds runs/.phase.lock" "pass"
else
  assert "C1 running run-phase.sh holds runs/.phase.lock" "fail"
  sed -n '1,25p' "$WORK/c1.log"
fi
P1="$(cat "$PLOCK/pid" 2>/dev/null || echo "")"
if [[ -n "$P1" ]]; then
  _SPAWNED_PGIDS+=("$P1")
else
  # Never-locked runner: reap by sandbox path so later scenarios stay clean.
  pkill -KILL -f "$WORK/proj/scripts/automation/run-phase.sh" 2>/dev/null || true
fi

# ── C2: a second phase run (even another phase) refuses fast ──────────────────
rc=0; run_phase_fg 30 "$WORK/c2.log" lockphase2 --no-finalize || rc=$?
[[ "$rc" -eq 86 ]] \
  && assert "C2 concurrent phase run refuses fast with exit 86" "pass" \
  || { assert "C2 concurrent phase run refuses fast with exit 86 (rc=$rc)" "fail"; sed -n '1,25p' "$WORK/c2.log"; }
[[ -f "$PLOCK/pid" && "$(cat "$PLOCK/pid")" == "$P1" ]] \
  && assert "C2 holder's phase lock survives the refused start" "pass" \
  || assert "C2 holder's phase lock survives the refused start" "fail"

# ── C3: group INT on the phase runner releases + tmp cleanup still runs ───────
kill -INT -- "-$P1" 2>/dev/null
wait_gone 20 "$PLOCK" \
  && assert "C3 Ctrl-C (group INT): phase lock released" "pass" \
  || assert "C3 Ctrl-C (group INT): phase lock released" "fail"
wait_for 10 no_iad_for "$P1" \
  && assert "C3 trap composition: run-phase tmp cleanup still runs" "pass" \
  || assert "C3 trap composition: run-phase tmp cleanup still runs ($(ls "$TMPROOT" 2>/dev/null | tr '\n' ' '))" "fail"

# ── C4: transport-pause exit (70) releases the phase lock ─────────────────────
stub_70
snap4="$(iad_snapshot)"
rc=0; run_phase_fg 60 "$WORK/c4.log" lockphase --no-finalize --reset || rc=$?
[[ "$rc" -eq 70 ]] \
  && assert "C4 transport failure pauses with exit 70" "pass" \
  || { assert "C4 transport failure pauses with exit 70 (rc=$rc)" "fail"; sed -n '1,30p' "$WORK/c4.log"; }
[[ ! -e "$PLOCK" ]] \
  && assert "C4 transport pause released the phase lock" "pass" \
  || assert "C4 transport pause released the phase lock" "fail"
[[ "$(iad_snapshot)" == "$snap4" ]] \
  && assert "C4 trap composition: tmp dir cleaned on transport-pause exit" "pass" \
  || assert "C4 trap composition: tmp dir cleaned on transport-pause exit (before='$snap4' after='$(iad_snapshot)')" "fail"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo ""
[[ $FAIL -gt 0 ]] && exit 1
exit 0
