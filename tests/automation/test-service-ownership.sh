#!/usr/bin/env bash
# test-service-ownership.sh — HARD-5 regression suite for the service ownership
# and lifecycle model.
#
# The defect this pins: every framework service teardown used to terminate by
# PORT (`fuser -k -9 <port>/tcp`) or by command-line pattern (`pkill -f`), so a
# pre-existing PRODUCT service listening on the project's deterministic offset
# port was indistinguishable from a stray agent-started verification server and
# was killed. Observed 2026-09-15 against trading_workstation (:8319/:3319).
#
# The corrected invariant these tests enforce:
#
#     Termination requires PER-PROCESS proof of ownership read from
#     /proc/<pid>/environ. A configured port, a matching repository cwd, a
#     matching command line, an absent record, or an "apparently stale" process
#     is NEVER proof.
#
# Every scenario uses REAL local subprocesses on dynamically allocated ports and
# asserts the actual lifecycle outcome (did the listener survive / die), not the
# return value of a predicate. Negative scenarios are written so that they FAIL
# if unsafe port-based or pattern-based killing is reintroduced anywhere.
#
# Host safety: every process this test starts is tracked by pid and reaped by
# pid. The suite never runs `fuser -k`, `pkill`, or `killall`, so it can never
# terminate an unrelated process on the developer's machine.
#
# Scenarios:
#   B1  ownership record written at managed-service boot; environ carries both stamps
#   B2  REQUIRED REGRESSION: pre-existing unowned listener survives EVERY
#       framework teardown path (engine start, phase completion, iteration
#       boundary, final summary, dev EXIT trap, lean EXIT trap, retries)
#   B3  framework-owned managed service IS cleaned up (the layer is not inert)
#   B4  scope-owned (agent-started) leaked verification server IS cleaned up
#   B5  stale record + reused PID ⇒ refuse (no stamp on the recycled process)
#   B6  foreign live owner ⇒ refuse
#   B7  dead owner of OUR repo lineage ⇒ reclaimable
#   B8  registry corruption / unreadable registry ⇒ fails CLOSED (listener lives)
#   B9  cleanup is idempotent for an already-exited owned process
#   B10 startup retry against an unowned unhealthy listener: no kill, concrete blocker
#   B11 healthy unowned listener is REUSED, not killed, and ports do not drift
#   B12 static: no unsafe termination path remains reachable in any framework script
#   B13 a port that listens but shows no pid (another user's) is refused, not "clear"
#   B14 scripts/dev.sh refuses an unowned port for real (behaviour, not just a grep)
#
# No API calls, no model dispatch. Runtime ~60s.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1));
  else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}
assert_eq() { # <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then assert "$1" pass
  else assert "$1 (expected '$2', got '$3')" fail; fi
}

WORK="$(mktemp -d)"
DUMMY_PIDS=()

# Reap only what we started, by pid, newest first. Never by port or pattern.
cleanup() {
  local p
  for p in ${DUMMY_PIDS[@]+"${DUMMY_PIDS[@]}"}; do
    kill -TERM "$p" 2>/dev/null || true
  done
  sleep 0.3
  for p in ${DUMMY_PIDS[@]+"${DUMMY_PIDS[@]}"}; do
    kill -KILL "$p" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

export CHAIN_TMP_ROOT="$WORK/tmproot"
export CHAIN_SERVICE_REGISTRY_DIR="$WORK/registry"
export TELEMETRY_ENABLED=false
mkdir -p "$CHAIN_TMP_ROOT"

# ── Harness helpers ──────────────────────────────────────────────────────────

# free_port — an unused TCP port, allocated by the kernel then released.
free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

# start_listener <port> [VAR=VAL ...] — a real HTTP listener on <port> with the
# given extra environment. Echoes its pid. Tracked for pid-scoped reaping.
# Publishes the pid in the GLOBAL $LISTENER_PID and appends it to DUMMY_PIDS.
# It must NOT echo the pid for `$(...)` capture: command substitution runs in a
# SUBSHELL, so the DUMMY_PIDS append would be discarded and the EXIT trap would
# reap nothing — leaking a real listener per scenario, per run.
start_listener() {
  local port="$1"; shift
  # Scrub OUR stamps first: a listener is "unowned" unless the caller explicitly
  # stamps it. Without this, `env` would pass the test runner's own exported
  # scope through and every "pre-existing product service" would be born owned.
  env -u CHAIN_SERVICE_OWNER_SCOPE -u CHAIN_SERVICE_INSTANCE \
    "$@" python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 &
  LISTENER_PID=$!
  DUMMY_PIDS+=("$LISTENER_PID")
  local i=0
  while [[ $i -lt 50 ]]; do
    port_answers "$port" && break
    sleep 0.1; i=$((i + 1))
  done
}

# start_dead_listener <port> — binds the port and ACCEPTS, then immediately
# closes each connection without replying. That is the realistic "unhealthy
# service" shape: the port is occupied (so the framework cannot bind it) but no
# health probe ever succeeds. It closes rather than stalling so a probe without
# a timeout returns promptly instead of hanging the test.
start_dead_listener() {
  local port="$1"; shift
  env -u CHAIN_SERVICE_OWNER_SCOPE -u CHAIN_SERVICE_INSTANCE "$@" python3 -c "
import socket,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',int(sys.argv[1]))); s.listen(16)
while True:
    try:
        c,_=s.accept(); c.close()
    except OSError:
        pass
" "$port" >/dev/null 2>&1 &
  LISTENER_PID=$!
  DUMMY_PIDS+=("$LISTENER_PID")
  sleep 0.4
}

port_answers() { curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$1/" 2>/dev/null; }
pid_alive()    { kill -0 "$1" 2>/dev/null; }

# settle — give a teardown path time to actually kill before we assert survival,
# so a surviving listener is real evidence and not a race.
settle() { sleep 1.0; }

echo "== test-service-ownership.sh =="
echo

# ── Load the ownership layer under test ──────────────────────────────────────
if [[ ! -f "$ENGINE_ROOT/scripts/automation/lib/engine-identity.sh" ]]; then
  echo "  FAIL  lib/engine-identity.sh is missing (HARD-4A A0 prerequisite)"; exit 1
fi
if [[ ! -f "$ENGINE_ROOT/scripts/automation/lib/service-owner.sh" ]]; then
  echo "  FAIL  lib/service-owner.sh is missing (HARD-5)"; exit 1
fi
# shellcheck source=/dev/null
source "$ENGINE_ROOT/scripts/automation/lib/engine-identity.sh"
# shellcheck source=/dev/null
source "$ENGINE_ROOT/scripts/automation/lib/service-owner.sh"

PROJECT_ROOT="$WORK/proj"
mkdir -p "$PROJECT_ROOT"
export REPO_ROOT="$PROJECT_ROOT"

# This test process acts as the lifecycle owner.
export CHAIN_ENGINE_TOKEN="$(engine_token_mint "$$")"
service_owner_scope_init "$PROJECT_ROOT" "test-runner"
OUR_SCOPE="$CHAIN_SERVICE_OWNER_SCOPE"

# ── B1: record written at managed boot; both stamps in the service environ ───
echo "-- B1: ownership acquisition at managed-service boot"
B1_PORT="$(free_port)"
B1_INSTANCE="$(service_instance_mint)"
start_listener "$B1_PORT" "CHAIN_SERVICE_OWNER_SCOPE=$OUR_SCOPE" "CHAIN_SERVICE_INSTANCE=$B1_INSTANCE"
B1_PID="$LISTENER_PID"
service_owner_write "$B1_PORT" "backend" "$B1_PID" "$B1_INSTANCE"

assert_eq "B1 record exists and classifies MINE" "MINE" "$(service_owner_classify "$B1_PORT" | cut -d: -f1)"
if service_pid_carries_instance "$B1_PID" "$B1_INSTANCE"; then
  assert "B1 service environ carries CHAIN_SERVICE_INSTANCE" pass
else
  assert "B1 service environ carries CHAIN_SERVICE_INSTANCE" fail
fi
if service_pid_in_our_scope "$B1_PID"; then
  assert "B1 service environ carries CHAIN_SERVICE_OWNER_SCOPE" pass
else
  assert "B1 service environ carries CHAIN_SERVICE_OWNER_SCOPE" fail
fi
echo

# ── B2: THE REQUIRED REGRESSION ──────────────────────────────────────────────
# A pre-existing product listener with NO stamps and NO record must survive
# every teardown path the framework can reach. This is the exact 2026-09-15
# incident. Any reintroduction of port- or pattern-based killing fails here.
echo "-- B2: pre-existing unowned listener survives EVERY teardown path"
BE_PORT="$(free_port)"
FE_PORT="$(free_port)"
start_listener "$BE_PORT"
PROD_BE="$LISTENER_PID"
start_listener "$FE_PORT"
PROD_FE="$LISTENER_PID"

export CHAIN_BACKEND_PORT="$BE_PORT"
export CHAIN_FRONTEND_PORT="$FE_PORT"

# Build a sandbox checkout so the real call sites run against real scripts.
SBX="$WORK/sbx"
mkdir -p "$SBX"
cp -r "$ENGINE_ROOT/scripts" "$SBX/"
mkdir -p "$SBX/docs/phases" "$SBX/runs"

# Drive each teardown path in a subshell that sources the REAL common.sh from
# the sandbox, inheriting our scope so the call is "a legitimate framework
# teardown by the owning process" — the strongest form of the test.
run_teardown() { # <bash snippet>
  (
    set +e
    export REPO_ROOT="$SBX"
    # shellcheck source=/dev/null
    source "$SBX/scripts/automation/lib/common.sh" >/dev/null 2>&1
    eval "$1"
  ) >>"$WORK/teardown.log" 2>&1
}

run_teardown 'kill_phase_servers'
settle
if port_answers "$BE_PORT" && port_answers "$FE_PORT"; then
  assert "B2a kill_phase_servers spares an unowned listener" pass
else
  assert "B2a kill_phase_servers KILLED an unowned listener" fail
fi

run_teardown 'unset CHAIN_BACKEND_PORT CHAIN_FRONTEND_PORT; reclaim_canonical_phase_ports'
settle
if port_answers "$BE_PORT" && port_answers "$FE_PORT"; then
  assert "B2b reclaim_canonical_phase_ports spares an unowned listener" pass
else
  assert "B2b reclaim_canonical_phase_ports KILLED an unowned listener" fail
fi

# dev-phase.sh EXIT trap — the path that fired 35 times in the real incident.
run_teardown 'cleanup_dev_servers 2>/dev/null || true'
settle
if port_answers "$BE_PORT" && port_answers "$FE_PORT"; then
  assert "B2c dev-phase EXIT cleanup spares an unowned listener" pass
else
  assert "B2c dev-phase EXIT cleanup KILLED an unowned listener" fail
fi

# Run the REAL dev-phase.sh EXIT trap by sourcing its cleanup definition.
DEV_TRAP_SNIPPET="$(sed -n '/^cleanup_dev_servers()/,/^}/p' "$SBX/scripts/automation/dev-phase.sh")"
if [[ -n "$DEV_TRAP_SNIPPET" ]]; then
  run_teardown "$DEV_TRAP_SNIPPET"$'\n''cleanup_dev_servers'
  settle
  if port_answers "$BE_PORT" && port_answers "$FE_PORT"; then
    assert "B2d real dev-phase.sh cleanup body spares an unowned listener" pass
  else
    assert "B2d real dev-phase.sh cleanup body KILLED an unowned listener" fail
  fi
else
  assert "B2d dev-phase.sh no longer defines cleanup_dev_servers (path removed)" pass
fi

# goal-iter-lean.sh EXIT trap port sweep.
LEAN_SNIPPET="$(sed -n '/^_bqa_kill_port_servers()/,/^}/p' "$SBX/scripts/automation/goal-iter-lean.sh")"
if [[ -n "$LEAN_SNIPPET" ]]; then
  run_teardown "$LEAN_SNIPPET"$'\n''_bqa_kill_port_servers'
  settle
  if port_answers "$BE_PORT" && port_answers "$FE_PORT"; then
    assert "B2e lean iteration cleanup spares an unowned listener" pass
  else
    assert "B2e lean iteration cleanup KILLED an unowned listener" fail
  fi
else
  assert "B2e goal-iter-lean.sh no longer defines _bqa_kill_port_servers" pass
fi

# stale-server helpers: cwd-scoped kills must not be authority either.
run_teardown 'kill_stale_backend_server "'"$SBX"'" 2>/dev/null || true; kill_stale_next_dev_server "'"$SBX"'" 2>/dev/null || true'
settle
if port_answers "$BE_PORT" && port_answers "$FE_PORT"; then
  assert "B2f stale-server helpers spare an unowned listener" pass
else
  assert "B2f stale-server helpers KILLED an unowned listener" fail
fi
echo

# ── B3: the layer is not inert — an owned managed service IS cleaned up ──────
echo "-- B3: framework-owned managed service is cleaned up"
B3_PORT="$(free_port)"
B3_INSTANCE="$(service_instance_mint)"
start_listener "$B3_PORT" "CHAIN_SERVICE_OWNER_SCOPE=$OUR_SCOPE" "CHAIN_SERVICE_INSTANCE=$B3_INSTANCE"
B3_PID="$LISTENER_PID"
service_owner_write "$B3_PORT" "backend" "$B3_PID" "$B3_INSTANCE"
b3_rc=0; service_owner_terminate "$B3_PORT" "test-b3" >/dev/null 2>&1 || b3_rc=$?
# rc must be 0: a successful teardown that races its own SIGKILL and reports
# "still listening" would make every normal cleanup look like a failure.
assert_eq "B3 successful teardown reports rc 0 (no false 'incomplete')" "0" "$b3_rc"
settle
if port_answers "$B3_PORT"; then
  assert "B3 owned service was NOT cleaned up (layer is inert)" fail
else
  assert "B3 owned service cleaned up" pass
fi
assert_eq "B3 record released after termination" "NO_RECORD" "$(service_owner_classify "$B3_PORT" | cut -d: -f1)"
echo

# ── B4: leaked agent-started verification server (scope stamp, no record) ────
# The developer/QA agents run inside our dispatch, so anything they spawn
# inherits CHAIN_SERVICE_OWNER_SCOPE. That is verified ownership — it is the
# ownership-aware replacement for the old blind sweep that existed to stop
# abandoned verification servers blocking the pipeline.
echo "-- B4: leaked agent-started server (scope-owned, unrecorded) is cleaned up"
B4_PORT="$(free_port)"
start_listener "$B4_PORT" "CHAIN_SERVICE_OWNER_SCOPE=$OUR_SCOPE"
B4_PID="$LISTENER_PID"
service_owner_terminate "$B4_PORT" "test-b4" >/dev/null 2>&1
settle
if port_answers "$B4_PORT"; then
  assert "B4 scope-owned leaked server was NOT cleaned up" fail
else
  assert "B4 scope-owned leaked server cleaned up" pass
fi
echo

# ── B5: stale record must not authorize termination of a reused PID ──────────
echo "-- B5: stale record cannot authorize killing a recycled PID"
B5_PORT="$(free_port)"
B5_GHOST_INSTANCE="$(service_instance_mint)"
# An innocent listener with NO stamps, but the registry names its pid as ours.
start_listener "$B5_PORT"
B5_PID="$LISTENER_PID"
service_owner_write "$B5_PORT" "backend" "$B5_PID" "$B5_GHOST_INSTANCE"
service_owner_terminate "$B5_PORT" "test-b5" >/dev/null 2>&1
settle
if port_answers "$B5_PORT"; then
  assert "B5 recycled-PID listener survives a stale record naming its pid" pass
else
  assert "B5 stale record KILLED an innocent recycled PID" fail
fi
echo

# ── B6: foreign live owner ───────────────────────────────────────────────────
echo "-- B6: foreign live owner cannot be terminated by us"
B6_PORT="$(free_port)"
# A live foreign owner process and a service stamped with ITS scope.
setsid sleep 120 >/dev/null 2>&1 &
FOREIGN_OWNER=$!
DUMMY_PIDS+=("$FOREIGN_OWNER")
FOREIGN_TOKEN="$(engine_token_mint "$FOREIGN_OWNER")"
FOREIGN_SCOPE="$(service_owner_scope_value "$PROJECT_ROOT" "$FOREIGN_TOKEN")"
B6_INSTANCE="$(service_instance_mint)"
start_listener "$B6_PORT" "CHAIN_SERVICE_OWNER_SCOPE=$FOREIGN_SCOPE" "CHAIN_SERVICE_INSTANCE=$B6_INSTANCE"
B6_PID="$LISTENER_PID"
service_owner_write_as "$B6_PORT" "backend" "$B6_PID" "$B6_INSTANCE" "$FOREIGN_TOKEN"
assert_eq "B6 classifies FOREIGN" "FOREIGN" "$(service_owner_classify "$B6_PORT" | cut -d: -f1)"
service_owner_terminate "$B6_PORT" "test-b6" >/dev/null 2>&1
settle
if port_answers "$B6_PORT"; then
  assert "B6 foreign-owned service survives our teardown" pass
else
  assert "B6 foreign-owned service was KILLED" fail
fi
echo

# ── B7: dead owner of our repo lineage is reclaimable ────────────────────────
echo "-- B7: provably-dead owner of our repo lineage is reclaimable"
B7_PORT="$(free_port)"
sleep 60 >/dev/null 2>&1 &
DEAD_OWNER=$!
DEAD_TOKEN="$(engine_token_mint "$DEAD_OWNER")"
DEAD_SCOPE="$(service_owner_scope_value "$PROJECT_ROOT" "$DEAD_TOKEN")"
B7_INSTANCE="$(service_instance_mint)"
start_listener "$B7_PORT" "CHAIN_SERVICE_OWNER_SCOPE=$DEAD_SCOPE" "CHAIN_SERVICE_INSTANCE=$B7_INSTANCE"
B7_PID="$LISTENER_PID"
service_owner_write_as "$B7_PORT" "backend" "$B7_PID" "$B7_INSTANCE" "$DEAD_TOKEN"
kill -KILL "$DEAD_OWNER" 2>/dev/null || true
wait "$DEAD_OWNER" 2>/dev/null || true
assert_eq "B7 classifies DEAD once the owner exits" "DEAD" "$(service_owner_classify "$B7_PORT" | cut -d: -f1)"
service_owner_terminate "$B7_PORT" "test-b7" >/dev/null 2>&1
settle
if port_answers "$B7_PORT"; then
  assert "B7 dead-owner orphan was NOT reclaimed" fail
else
  assert "B7 dead-owner orphan reclaimed" pass
fi
echo

# ── B8: registry corruption fails CLOSED ─────────────────────────────────────
echo "-- B8: registry corruption / unreadable registry fails closed"
B8_PORT="$(free_port)"
start_listener "$B8_PORT"
B8_PID="$LISTENER_PID"           # unowned, no stamps
B8_REC="$(service_owner_record_path "$B8_PORT")"
mkdir -p "$(dirname "$B8_REC")"
printf 'this is not a valid record\x00\x01garbage' > "$B8_REC"
STATE="$(service_owner_classify "$B8_PORT" | cut -d: -f1)"
if [[ "$STATE" == "GRACE" || "$STATE" == "REGISTRY_ERROR" ]]; then
  assert "B8a malformed record classifies GRACE/REGISTRY_ERROR (not NO_RECORD)" pass
else
  assert "B8a malformed record classified '$STATE'" fail
fi
service_owner_terminate "$B8_PORT" "test-b8" >/dev/null 2>&1
settle
if port_answers "$B8_PORT"; then
  assert "B8b corrupt record does not authorize a kill" pass
else
  assert "B8b corrupt record AUTHORIZED a kill" fail
fi

# Registry directory entirely unreadable.
chmod 000 "$(dirname "$B8_REC")" 2>/dev/null || true
B8B_PORT="$(free_port)"
start_listener "$B8B_PORT"
B8B_PID="$LISTENER_PID"
service_owner_terminate "$B8B_PORT" "test-b8c" >/dev/null 2>&1
settle
if port_answers "$B8B_PORT"; then
  assert "B8c unreadable registry dir does not authorize a kill" pass
else
  assert "B8c unreadable registry dir AUTHORIZED a kill" fail
fi
chmod 755 "$(dirname "$B8_REC")" 2>/dev/null || true
echo

# ── B9: idempotent cleanup of an already-exited owned process ────────────────
echo "-- B9: cleanup is idempotent for an already-exited owned service"
B9_PORT="$(free_port)"
B9_INSTANCE="$(service_instance_mint)"
start_listener "$B9_PORT" "CHAIN_SERVICE_OWNER_SCOPE=$OUR_SCOPE" "CHAIN_SERVICE_INSTANCE=$B9_INSTANCE"
B9_PID="$LISTENER_PID"
service_owner_write "$B9_PORT" "backend" "$B9_PID" "$B9_INSTANCE"
service_owner_terminate "$B9_PORT" "test-b9" >/dev/null 2>&1
rc1=0; service_owner_terminate "$B9_PORT" "test-b9-again" >/dev/null 2>&1 || rc1=$?
rc2=0; service_owner_terminate "$B9_PORT" "test-b9-third" >/dev/null 2>&1 || rc2=$?
assert_eq "B9 repeat termination returns 0 (idempotent)" "0" "$rc1"
assert_eq "B9 third termination returns 0 (idempotent)" "0" "$rc2"
echo

# ── B10: retry against an UNHEALTHY unowned occupant ⇒ blocker, never a kill ─
echo "-- B10: startup retry never kills an unrelated listener"
B10_PORT="$(free_port)"
start_dead_listener "$B10_PORT"
B10_PID="$LISTENER_PID"    # binds, never answers, unowned
B10_LOG="$WORK/b10.log"
(
  set +e
  export REPO_ROOT="$SBX"
  # shellcheck source=/dev/null
  source "$SBX/scripts/automation/lib/common.sh" >/dev/null 2>&1
  export QA_BACKEND_HEALTH_URL="http://127.0.0.1:$B10_PORT/health"
  export QA_BACKEND_START_CMD="true"
  export QA_BACKEND_LOG="$WORK/b10-svc.log"
  _start_service_with_retries "backend" "$QA_BACKEND_HEALTH_URL" "true" \
    "$QA_BACKEND_LOG" 2 1 QA_BACKEND_LOG_TAIL "" '^[23]'
) >"$B10_LOG" 2>&1
settle
if pid_alive "$B10_PID"; then
  assert "B10a startup retry spared an unowned unhealthy listener" pass
else
  assert "B10a startup retry KILLED an unowned unhealthy listener" fail
fi
if grep -qi "blocked\|blocker\|not owned\|refus" "$B10_LOG" 2>/dev/null; then
  assert "B10b startup reported a concrete ownership blocker" pass
else
  assert "B10b startup did not report an ownership blocker (see $B10_LOG)" fail
fi
echo

# ── B11: healthy unowned listener is REUSED and ports do not drift ───────────
echo "-- B11: healthy unowned service is reused; canonical ports do not drift"
(
  set +e
  export REPO_ROOT="$PROJECT_ROOT"
  # shellcheck source=/dev/null
  source "$SBX/scripts/automation/lib/common.sh" >/dev/null 2>&1
  off="$(_project_port_offset)"
  echo "OFFSET=$off"
) >"$WORK/b11-offset.log" 2>&1
B11_OFF="$(sed -n 's/^OFFSET=//p' "$WORK/b11-offset.log" | head -1)"
B11_BE=$((8000 + B11_OFF))
B11_FE=$((3000 + B11_OFF))
# Occupy the canonical backend port with a healthy unowned listener.
if ! port_answers "$B11_BE"; then
  start_listener "$B11_BE"
B11_PID="$LISTENER_PID"
  (
    set +e
    export REPO_ROOT="$PROJECT_ROOT"
    unset CHAIN_BACKEND_PORT CHAIN_FRONTEND_PORT
    # shellcheck source=/dev/null
    source "$SBX/scripts/automation/lib/common.sh" >/dev/null 2>&1
    ensure_phase_ports
    echo "BE=$CHAIN_BACKEND_PORT FE=$CHAIN_FRONTEND_PORT"
  ) >"$WORK/b11.log" 2>&1
  B11_GOT_BE="$(sed -n 's/.*BE=\([0-9]*\).*/\1/p' "$WORK/b11.log" | head -1)"
  B11_GOT_FE="$(sed -n 's/.*FE=\([0-9]*\).*/\1/p' "$WORK/b11.log" | head -1)"
  assert_eq "B11a backend port pinned to canonical (no drift)" "$B11_BE" "$B11_GOT_BE"
  assert_eq "B11b frontend port pinned to canonical (pairing intact)" "$B11_FE" "$B11_GOT_FE"
  settle
  if port_answers "$B11_BE"; then
    assert "B11c healthy unowned occupant reused, not killed" pass
  else
    assert "B11c healthy unowned occupant was KILLED" fail
  fi
else
  assert "B11 skipped: canonical port $B11_BE already busy on this host" pass
fi
echo

# ── B13: an occupied port whose owning pid we cannot see is never "clear" ────
# A socket owned by ANOTHER USER is withheld from `ss -p` / `lsof`, so the
# listener list comes back empty while the port is very much occupied. Reporting
# that as success would tell the caller the port is free, and the failure to bind
# that follows would have no explanation. Simulated here by stubbing the listener
# lookup — the condition itself needs a second uid, the CONSEQUENCE does not.
echo "-- B13: invisible (other-user) listener is refused, not reported clear"
B13_PORT="$(free_port)"
start_listener "$B13_PORT"
B13_PID="$LISTENER_PID"
_real_listener_pids="$(declare -f service_listener_pids)"
service_listener_pids() { :; }          # emulate "socket visible, pid withheld"
b13_rc=0; service_owner_terminate "$B13_PORT" "test-b13" >/dev/null 2>&1 || b13_rc=$?
eval "$_real_listener_pids"             # restore the real implementation
assert_eq "B13a refuses when the port listens but no pid is visible" "1" "$b13_rc"
settle
if port_answers "$B13_PORT"; then
  assert "B13b the invisible listener survives" pass
else
  assert "B13b the invisible listener was KILLED" fail
fi
echo

# ── B12: no unsafe termination path remains reachable in any framework script ─
echo "-- B12: static sweep — no port/pattern kills left in framework scripts"
UNSAFE=0
UNSAFE_LINES=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  UNSAFE=$((UNSAFE + 1))
  UNSAFE_LINES+="    $line"$'\n'
done < <(
  grep -rn 'fuser -k\|pkill \|killall ' \
    "$ENGINE_ROOT/scripts/automation/" 2>/dev/null \
    | grep -v '__pycache__' \
    | grep -v '^\s*#' \
    | grep -vE ':[0-9]+:\s*#' \
    || true
)
if [[ $UNSAFE -eq 0 ]]; then
  assert "B12a no fuser -k / pkill / killall in scripts/automation" pass
else
  assert "B12a $UNSAFE unsafe termination call(s) remain in scripts/automation" fail
  printf '%s' "$UNSAFE_LINES"
fi

# scripts/dev.sh is an operator convenience, not a pipeline path, but it must
# not be a back door into the same defect while the pipeline is hardened. Its
# one remaining unconditional kill is gated behind DEV_FORCE=1 — an explicit,
# per-invocation operator authority, not a default. Comment lines are excluded:
# the file documents the removed commands by name.
# Single-file `grep -n` emits "<line>:<content>" with no path prefix, so the
# comment filter must anchor on the line number, not on a leading colon.
DEV_UNSAFE="$(grep -n 'fuser -k' "$ENGINE_ROOT/scripts/dev.sh" 2>/dev/null \
                | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
if [[ -n "$DEV_UNSAFE" ]]; then
  assert "B12b scripts/dev.sh still contains a blind port kill" fail
  printf '    %s\n' "$DEV_UNSAFE"
else
  assert "B12b scripts/dev.sh has no blind port kill" pass
fi
if grep -q 'DEV_FORCE' "$ENGINE_ROOT/scripts/dev.sh" 2>/dev/null; then
  assert "B12c scripts/dev.sh gates any override behind explicit DEV_FORCE" pass
else
  assert "B12c scripts/dev.sh has no explicit override gate" fail
fi
echo

# ── B14: scripts/dev.sh refuses an unowned port (behaviour, not just a grep) ──
# B12 proves the unsafe commands are gone from the source. B14 proves the
# replacement actually protects a live process: the real dev.sh, run against a
# port held by an unowned listener, must exit non-zero, explain itself, and
# leave the listener running.
echo "-- B14: scripts/dev.sh refuses to clear a port it does not own"
DEVSBX="$WORK/devsbx"
mkdir -p "$DEVSBX/scripts/automation/lib"
cp "$ENGINE_ROOT/scripts/dev.sh" "$DEVSBX/scripts/"
cp "$ENGINE_ROOT/scripts/automation/lib/service-owner.sh" \
   "$ENGINE_ROOT/scripts/automation/lib/engine-identity.sh" "$DEVSBX/scripts/automation/lib/"
B14_PORT="$(free_port)"
B14_FREE="$(free_port)"
start_listener "$B14_PORT"
B14_PID="$LISTENER_PID"
b14_rc=0
CHAIN_BACKEND_PORT="$B14_PORT" CHAIN_FRONTEND_PORT="$B14_FREE" \
  bash "$DEVSBX/scripts/dev.sh" >"$WORK/b14.log" 2>&1 || b14_rc=$?
assert_eq "B14a dev.sh exits non-zero rather than clearing an unowned port" "1" "$b14_rc"
settle
if port_answers "$B14_PORT"; then
  assert "B14b the unowned listener survives dev.sh" pass
else
  assert "B14b dev.sh KILLED an unowned listener" fail
fi
if grep -q "does not own" "$WORK/b14.log" 2>/dev/null; then
  assert "B14c dev.sh explains the refusal and names the holder" pass
else
  assert "B14c dev.sh refusal message missing (see $WORK/b14.log)" fail
fi
echo

echo "== summary: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
