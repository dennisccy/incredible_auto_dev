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

# start_coded_listener <port> <status> <body> [VAR=VAL ...] — a listener whose
# every response carries the given status and body. Lets a scenario distinguish
# "a socket is open" from "the application is healthy" from "it is the RIGHT
# application", which the framework must now treat as three separate questions.
start_coded_listener() {
  local port="$1" status="$2" body="$3"; shift 3
  env -u CHAIN_SERVICE_OWNER_SCOPE -u CHAIN_SERVICE_INSTANCE "$@" python3 -c "
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
st=int(sys.argv[2]); body=sys.argv[3].encode()
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(st); self.send_header('Content-Length',str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()
" "$port" "$status" "$body" >/dev/null 2>&1 &
  LISTENER_PID=$!
  DUMMY_PIDS+=("$LISTENER_PID")
  local i=0
  while [[ $i -lt 50 ]]; do
    curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$port/" 2>/dev/null && break
    sleep 0.1; i=$((i + 1))
  done
}

port_answers() { curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$1/" 2>/dev/null; }
# port_status <port> — the HTTP status, or 000 when nothing answers.
port_status() { curl -s -o /dev/null --max-time 2 -w "%{http_code}" "http://127.0.0.1:$1/" 2>/dev/null || echo 000; }
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
# A real project is a git working tree, and that is where the serving-revision
# check gets its signal, so the sandbox must be one too.
git init -q "$PROJECT_ROOT" 2>/dev/null || true
echo "v1" > "$PROJECT_ROOT/src.txt"

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

# ═══════════════════════════════════════════════════════════════════════════
# C-series — review follow-up (2026-09-16). Ownership says WHO MAY terminate;
# lifecycle policy says WHETHER termination is appropriate. Identity must hold
# at SIGNAL time, not just at check time. A healthy endpoint is not proof that
# it is the right service at the right revision.
# ═══════════════════════════════════════════════════════════════════════════

# ── C1: a healthy OWNED application service survives between-phase cleanup ───
echo "-- C1: healthy owned app service survives phase cleanup"
C1_PORT="$(free_port)"
C1_INSTANCE="$(service_instance_mint)"
start_listener "$C1_PORT" "CHAIN_SERVICE_OWNER_SCOPE=$OUR_SCOPE" "CHAIN_SERVICE_INSTANCE=$C1_INSTANCE"
C1_PID="$LISTENER_PID"
service_owner_register "$C1_PORT" "backend" "$C1_PID" "$C1_INSTANCE" \
  "persistent" "http://127.0.0.1:$C1_PORT/" "$(service_tree_revision)"
service_release "$C1_PORT" "kill_phase_servers" >/dev/null 2>&1
settle
if port_answers "$C1_PORT"; then
  assert "C1a healthy owned app service survives kill_phase_servers" pass
else
  assert "C1a phase cleanup KILLED a healthy owned app service" fail
fi
assert_eq "C1b its ownership record is retained" "MINE" "$(service_owner_classify "$C1_PORT" | cut -d: -f1)"
echo

# ── C2: it also survives the final-summary path ──────────────────────────────
echo "-- C2: healthy owned app service survives Goal Mode completion"
service_release "$C1_PORT" "showcase-join" >/dev/null 2>&1
settle
if port_answers "$C1_PORT"; then
  assert "C2 app service survives the final summary teardown" pass
else
  assert "C2 final summary KILLED a healthy owned app service" fail
fi
echo

# ── C3: an EPHEMERAL leak (scope-owned, unrecorded) is still reaped ──────────
echo "-- C3: ephemeral agent-started leak is still reaped"
C3_PORT="$(free_port)"
start_listener "$C3_PORT" "CHAIN_SERVICE_OWNER_SCOPE=$OUR_SCOPE"
C3_PID="$LISTENER_PID"
service_release "$C3_PORT" "dev-phase-exit" >/dev/null 2>&1
settle
if port_answers "$C3_PORT"; then
  assert "C3 ephemeral leak was NOT reaped (policy too permissive)" fail
else
  assert "C3 ephemeral leak reaped" pass
fi
echo

# ── C4: a stale-revision service IS restarted (verified restart required) ────
echo "-- C4: stale-revision owned service is released for restart"
C4_PORT="$(free_port)"
C4_INSTANCE="$(service_instance_mint)"
start_listener "$C4_PORT" "CHAIN_SERVICE_OWNER_SCOPE=$OUR_SCOPE" "CHAIN_SERVICE_INSTANCE=$C4_INSTANCE"
C4_PID="$LISTENER_PID"
service_owner_register "$C4_PORT" "backend" "$C4_PID" "$C4_INSTANCE" \
  "persistent" "http://127.0.0.1:$C4_PORT/" "revision-from-an-older-tree"
if service_restart_required "$C4_PORT"; then
  assert "C4a stale revision is detected as restart-required" pass
else
  assert "C4a stale revision NOT detected (services would serve old code)" fail
fi
service_release "$C4_PORT" "kill_phase_servers" >/dev/null 2>&1
settle
if port_answers "$C4_PORT"; then
  assert "C4b stale-revision service was NOT released (stale code would be tested)" fail
else
  assert "C4b stale-revision service released for restart" pass
fi
echo

# ── C5: identity must hold at SIGNAL time, not just at check time ────────────
# The old sequence was: snapshot pids -> TERM -> sleep -> `kill -0` -> KILL.
# `kill -0` proves existence, not identity, so a pid that exits during the grace
# window and is recycled receives the KILL. Signalling must be bound to a stable
# identity captured before the first signal.
echo "-- C5: signal-time identity validation (check-to-signal PID reuse gap)"
C5_PORT="$(free_port)"
start_listener "$C5_PORT"
C5_PID="$LISTENER_PID"
# Correct identity => the signal is delivered.
service_signal_tree "$C5_PID" 1 "$(service_pid_starttime "$C5_PID")" >/dev/null 2>&1
settle
if port_answers "$C5_PORT"; then
  assert "C5a a correctly-identified process IS signalled" fail
else
  assert "C5a a correctly-identified process IS signalled" pass
fi
# Wrong identity (simulating a recycled pid) => no signal at all.
C5B_PORT="$(free_port)"
start_listener "$C5B_PORT"
C5B_PID="$LISTENER_PID"
service_signal_tree "$C5B_PID" 1 "999999999-not-this-process" >/dev/null 2>&1
settle
if port_answers "$C5B_PORT"; then
  assert "C5b a pid whose identity no longer matches is NOT signalled" pass
else
  assert "C5b stale identity STILL killed the process (reuse gap open)" fail
fi
echo

# ── C6: the stale-server helpers use the same validated signalling ───────────
echo "-- C6: stale-server helpers revalidate identity before escalating"
if grep -q 'service_signal_tree\|service_signal_pid' \
     <(sed -n '/^kill_stale_next_dev_server()/,/^}/p' "$ENGINE_ROOT/scripts/automation/lib/common.sh"); then
  assert "C6a kill_stale_next_dev_server signals via the validated path" pass
else
  assert "C6a kill_stale_next_dev_server still uses a bare TERM/sleep/KILL" fail
fi
if grep -q 'service_signal_tree\|service_signal_pid' \
     <(sed -n '/^kill_stale_backend_server()/,/^}/p' "$ENGINE_ROOT/scripts/automation/lib/common.sh"); then
  assert "C6b kill_stale_backend_server signals via the validated path" pass
else
  assert "C6b kill_stale_backend_server still uses a bare TERM/sleep/KILL" fail
fi
# No helper may accept a pid ALONE and signal it: that shape is how a verified
# decision gets dropped on the way to the act.
if grep -q '^_svc_kill_tree()' "$ENGINE_ROOT/scripts/automation/lib/service-owner.sh"; then
  assert "C6c an unbound pid-only kill helper still exists" fail
else
  assert "C6c no unbound pid-only kill helper remains" pass
fi
_unbound=$(grep -hn 'service_signal_tree "' \
             "$ENGINE_ROOT/scripts/automation/lib/service-owner.sh" \
             "$ENGINE_ROOT/scripts/automation/lib/common.sh" 2>/dev/null \
           | grep -vE 'service_pid_starttime|_p_ident|\\$' || true)
if [[ -z "$_unbound" ]]; then
  assert "C6d every library signal call carries a verified identity" pass
else
  assert "C6d a library signal call omits the identity" fail
  printf '    %s\n' "$_unbound"
fi
echo

# ── C7: a healthy but WRONG service is not accepted as the dependency ────────
echo "-- C7: healthy-but-wrong service fails closed (not reused, not killed)"
C7_PORT="$(free_port)"
start_listener "$C7_PORT"          # answers 200, but is NOT our backend
C7_LOG="$WORK/c7.log"
(
  set +e
  export REPO_ROOT="$SBX"
  # shellcheck source=/dev/null
  source "$SBX/scripts/automation/lib/common.sh" >/dev/null 2>&1
  # Project-supplied verifier that this listener cannot satisfy.
  export CHAIN_SERVICE_VERIFY_BACKEND="grep -q iad-backend-marker"
  _start_service_with_retries "backend" "http://127.0.0.1:$C7_PORT/" "true" \
    "$WORK/c7-svc.log" 2 1 QA_BACKEND_LOG_TAIL "" '^[1-5][0-9][0-9]$'
  echo "RC=$?"
) >"$C7_LOG" 2>&1
settle
if grep -q "^RC=0" "$C7_LOG"; then
  assert "C7a healthy-but-unverified service was ACCEPTED as the dependency" fail
else
  assert "C7a healthy-but-unverified service is not accepted (fails closed)" pass
fi
if port_answers "$C7_PORT"; then
  assert "C7b the unverified service was left running (not killed)" pass
else
  assert "C7b the unverified service was KILLED" fail
fi
echo

# ── C8: unowned healthy service with NO verification contract ⇒ fail closed ──
echo "-- C8: unverifiable external service is not silently trusted"
C8_PORT="$(free_port)"
start_listener "$C8_PORT"
C8_LOG="$WORK/c8.log"
(
  set +e
  export REPO_ROOT="$SBX"
  # shellcheck source=/dev/null
  source "$SBX/scripts/automation/lib/common.sh" >/dev/null 2>&1
  unset CHAIN_SERVICE_VERIFY_BACKEND
  _start_service_with_retries "backend" "http://127.0.0.1:$C8_PORT/" "true" \
    "$WORK/c8-svc.log" 2 1 QA_BACKEND_LOG_TAIL "" '^[1-5][0-9][0-9]$'
  echo "RC=$?"
) >"$C8_LOG" 2>&1
settle
if grep -q "^RC=0" "$C8_LOG"; then
  assert "C8a unowned unverifiable service silently accepted" fail
else
  assert "C8a unowned unverifiable service fails closed" pass
fi
if port_answers "$C8_PORT"; then
  assert "C8b it was left running, not killed and not port-switched" pass
else
  assert "C8b it was KILLED" fail
fi
echo

# ── C9: DEV_FORCE must not reach processes merely CONNECTED to the port ──────
# `lsof -ti :PORT` matches established client sockets too, so the override would
# kill an unrelated client (e.g. a browser talking to the app).
echo "-- C9: DEV_FORCE targets listeners only, never connected clients"
C9_PORT="$(free_port)"
start_listener "$C9_PORT"
C9_SRV="$LISTENER_PID"
python3 -c "
import socket,sys,time
c=socket.socket(); c.connect(('127.0.0.1',int(sys.argv[1]))); time.sleep(30)
" "$C9_PORT" >/dev/null 2>&1 &
C9_CLIENT=$!
DUMMY_PIDS+=("$C9_CLIENT")
sleep 1
C9_FREE="$(free_port)"
CHAIN_BACKEND_PORT="$C9_PORT" CHAIN_FRONTEND_PORT="$C9_FREE" DEV_FORCE=1 \
  bash "$DEVSBX/scripts/dev.sh" >"$WORK/c9.log" 2>&1 || true
settle
if pid_alive "$C9_CLIENT"; then
  assert "C9 DEV_FORCE spared a process merely connected to the port" pass
else
  assert "C9 DEV_FORCE killed an unrelated CONNECTED client" fail
fi
kill -TERM "$C9_CLIENT" 2>/dev/null || true
echo

# ═══════════════════════════════════════════════════════════════════════════
# D-series — second review follow-up. Three seams where a check was performed
# but not carried through to the act that depended on it.
# ═══════════════════════════════════════════════════════════════════════════

# ── D1: the identity verified during the ownership check must gate the signal ─
# service_owner_terminate verified ownership and then passed only a PID onward.
# The validated identity was dropped, so the signal targeted whatever occupied
# that pid at signal time. This exercises REPLACEMENT between verification and
# signalling — not a mismatch that already existed before the call.
echo "-- D1: identity verified at check time gates the signal"
D1_PORT="$(free_port)"
D1_INSTANCE="$(service_instance_mint)"
start_listener "$D1_PORT" "CHAIN_SERVICE_OWNER_SCOPE=$OUR_SCOPE" "CHAIN_SERVICE_INSTANCE=$D1_INSTANCE"
D1_OLD_PID="$LISTENER_PID"
D1_OLD_IDENT="$(service_pid_starttime "$D1_OLD_PID")"
# The verified process goes away and something else takes the port — exactly the
# window between "ownership verified" and "signal sent".
kill -KILL "$D1_OLD_PID" 2>/dev/null; wait "$D1_OLD_PID" 2>/dev/null
sleep 0.5
start_listener "$D1_PORT" "CHAIN_SERVICE_OWNER_SCOPE=$OUR_SCOPE"
D1_NEW_PID="$LISTENER_PID"
# Signalling with the OLD identity must hit nothing at all.
service_signal_tree "$D1_NEW_PID" 1 "$D1_OLD_IDENT" >/dev/null 2>&1
d1_rc=$?
settle
assert_eq "D1a signalling with a superseded identity is refused" "1" "$d1_rc"
if pid_alive "$D1_NEW_PID"; then
  assert "D1b the replacement process survives" pass
else
  assert "D1b the replacement process was KILLED via a stale identity" fail
fi
# The ownership decision must also be re-verified against the PINNED process.
D1C_PORT="$(free_port)"
start_listener "$D1C_PORT"                       # no scope stamp at all
D1C_PID="$LISTENER_PID"
python3 "$ENGINE_ROOT/scripts/automation/lib/proc_signal.py" tree "$D1C_PID" \
  --grace 1 --identity "$(service_pid_starttime "$D1C_PID")" \
  --require-env "CHAIN_SERVICE_OWNER_SCOPE=$OUR_SCOPE" >/dev/null 2>&1
d1c_rc=$?
settle
assert_eq "D1c signalling refuses when the pinned process lacks the required stamp" "3" "$d1c_rc"
if pid_alive "$D1C_PID"; then
  assert "D1d the unstamped process survives post-pin verification" pass
else
  assert "D1d an unstamped process was signalled" fail
fi
# And the integration seam: terminate must hand identity + scope onward.
if grep -qE 'service_signal_tree "\$_p_pid" .*"\$_p_ident"|owned\+=\("\$p:' \
     <(sed -n '/^service_owner_terminate()/,/^}/p' "$ENGINE_ROOT/scripts/automation/lib/service-owner.sh"); then
  assert "D1e service_owner_terminate carries identity into signalling" pass
else
  assert "D1e service_owner_terminate still discards the verified identity" fail
fi
echo

# ── D2: a persistent record must be bound to the ACTUAL listener ─────────────
# Registered service exits, its record survives, a different scope-owned
# verification server takes the port and answers 200. Without record-to-process
# correlation the leak inherits "persistent" and the previous revision identity,
# so it is preserved as though it were the application.
echo "-- D2: a stale persistent record cannot adopt a replacement listener"
D2_PORT="$(free_port)"
D2_INSTANCE="$(service_instance_mint)"
start_listener "$D2_PORT" "CHAIN_SERVICE_OWNER_SCOPE=$OUR_SCOPE" "CHAIN_SERVICE_INSTANCE=$D2_INSTANCE"
D2_APP_PID="$LISTENER_PID"
service_owner_register "$D2_PORT" "backend" "$D2_APP_PID" "$D2_INSTANCE" \
  "persistent" "http://127.0.0.1:$D2_PORT/" "$(service_tree_revision)"
kill -KILL "$D2_APP_PID" 2>/dev/null; wait "$D2_APP_PID" 2>/dev/null
sleep 0.5
# A DIFFERENT scope-owned process (an agent's verification server) takes the port.
start_listener "$D2_PORT" "CHAIN_SERVICE_OWNER_SCOPE=$OUR_SCOPE"
D2_LEAK_PID="$LISTENER_PID"
assert_eq "D2a the reuse decision refuses to trust the stale record" "RESTART" \
  "$(service_reuse_decision backend "http://127.0.0.1:$D2_PORT/" "$D2_PORT")"
service_release "$D2_PORT" "kill_phase_servers" >/dev/null 2>&1
settle
if port_answers "$D2_PORT"; then
  assert "D2b the replacement inherited 'persistent' and was PRESERVED" fail
else
  assert "D2b the replacement is treated as ephemeral and reaped" pass
fi
echo

# ── D3: HTTP 500 is reachability, not health ─────────────────────────────────
echo "-- D3: an owned service returning 500 is not a healthy dependency"
D3_PORT="$(free_port)"
D3_INSTANCE="$(service_instance_mint)"
start_coded_listener "$D3_PORT" 500 "boom" \
  "CHAIN_SERVICE_OWNER_SCOPE=$OUR_SCOPE" "CHAIN_SERVICE_INSTANCE=$D3_INSTANCE"
D3_PID="$LISTENER_PID"
service_owner_register "$D3_PORT" "backend" "$D3_PID" "$D3_INSTANCE" \
  "persistent" "http://127.0.0.1:$D3_PORT/" "$(service_tree_revision)"
assert_eq "D3a the service really is returning 500" "500" "$(port_status "$D3_PORT")"
if service_service_healthy "$D3_PORT"; then
  assert "D3b a 500 response is classified as HEALTHY" fail
else
  assert "D3b a 500 response is not classified as healthy" pass
fi
if service_restart_required "$D3_PORT"; then
  assert "D3c an unhealthy owned service is restart-required" pass
else
  assert "D3c an unhealthy owned service was left as-is" fail
fi
assert_eq "D3d the reuse decision refuses a 500 backend" "RESTART" \
  "$(service_reuse_decision backend "http://127.0.0.1:$D3_PORT/" "$D3_PORT")"
service_release "$D3_PORT" "kill_phase_servers" >/dev/null 2>&1
settle
if port_answers "$D3_PORT"; then
  assert "D3e the 500 service was PRESERVED as healthy" fail
else
  assert "D3e the 500 service was released for restart" pass
fi
# A project whose valid readiness is not 2xx must be able to say so EXPLICITLY.
D3F_PORT="$(free_port)"
D3F_INSTANCE="$(service_instance_mint)"
start_coded_listener "$D3F_PORT" 404 "no health route here" \
  "CHAIN_SERVICE_OWNER_SCOPE=$OUR_SCOPE" "CHAIN_SERVICE_INSTANCE=$D3F_INSTANCE"
D3F_PID="$LISTENER_PID"
service_owner_register "$D3F_PORT" "backend" "$D3F_PID" "$D3F_INSTANCE" \
  "persistent" "http://127.0.0.1:$D3F_PORT/" "$(service_tree_revision)"
if CHAIN_SERVICE_HEALTHY_BACKEND='^(2|3|404)' service_service_healthy "$D3F_PORT"; then
  assert "D3f an explicit health contract admits a non-2xx readiness response" pass
else
  assert "D3f an explicit health contract was ignored" fail
fi
echo

# ── D4: the verification contract must be configurable, not just documented ──
# .claude/project-template.md is prose fed to agents; nothing sources it, so a
# contract declared only there never reaches the shell. A real deployment needs
# a supported mechanism and an external service must be reusable without any
# manual process intervention.
echo "-- D4: an external service is reusable via a real configuration mechanism"
D4_PORT="$(free_port)"
start_coded_listener "$D4_PORT" 200 '{"service":"iad-demo-api","rev":"abc"}'   # EXTERNAL: unstamped
D4_PID="$LISTENER_PID"
mkdir -p "$SBX/.claude"
cat > "$SBX/.claude/service-contracts.sh" <<'CONTRACT'
# Project service contracts (sourced by the framework).
export CHAIN_SERVICE_VERIFY_BACKEND='grep -q iad-demo-api'
export CHAIN_SERVICE_HEALTHY_BACKEND='^[23]'
CONTRACT
D4_LOG="$WORK/d4.log"
(
  set +e
  export REPO_ROOT="$SBX"
  # shellcheck source=/dev/null
  source "$SBX/scripts/automation/lib/common.sh" >/dev/null 2>&1
  # No manual export of CHAIN_SERVICE_VERIFY_* — the framework must pick up the
  # project's contract file by itself.
  service_contracts_load
  _start_service_with_retries "backend" "http://127.0.0.1:$D4_PORT/" "true" \
    "$WORK/d4-svc.log" 2 1 QA_BACKEND_LOG_TAIL "" '^[1-5][0-9][0-9]$'
  echo "RC=$?"
) >"$D4_LOG" 2>&1
settle
if grep -q "^RC=0" "$D4_LOG"; then
  assert "D4a a verified external service is reused with no manual intervention" pass
else
  assert "D4a a verified external service was NOT reused (see $D4_LOG)" fail
fi
if port_answers "$D4_PORT"; then
  assert "D4b the external service was left running, unowned" pass
else
  assert "D4b the external service was KILLED" fail
fi
assert_eq "D4c reusing it acquired no ownership record" "NO_RECORD" \
  "$(CHAIN_SERVICE_REGISTRY_DIR="$CHAIN_SERVICE_REGISTRY_DIR" service_owner_classify "$D4_PORT" | cut -d: -f1)"
# Negative: the same mechanism must still reject a service the contract denies.
D4E_PORT="$(free_port)"
start_coded_listener "$D4E_PORT" 200 '{"service":"somebody-elses-api"}'
D4E_PID="$LISTENER_PID"
D4E_LOG="$WORK/d4e.log"
(
  set +e
  export REPO_ROOT="$SBX"
  # shellcheck source=/dev/null
  source "$SBX/scripts/automation/lib/common.sh" >/dev/null 2>&1
  service_contracts_load
  _start_service_with_retries "backend" "http://127.0.0.1:$D4E_PORT/" "true" \
    "$WORK/d4e-svc.log" 2 1 QA_BACKEND_LOG_TAIL "" '^[1-5][0-9][0-9]$'
  echo "RC=$?"
) >"$D4E_LOG" 2>&1
settle
if grep -q "^RC=0" "$D4E_LOG"; then
  assert "D4d a contract-rejected external service was accepted" fail
else
  assert "D4d a contract-rejected external service fails closed" pass
fi
if port_answers "$D4E_PORT"; then
  assert "D4e the rejected service was left running (not killed)" pass
else
  assert "D4e the rejected service was KILLED" fail
fi
# The mechanism existing is not the same as it being WIRED. A deployment must
# get its contracts without anyone calling the loader by hand.
(
  set +e
  export REPO_ROOT="$SBX"
  unset CHAIN_SERVICE_VERIFY_BACKEND CHAIN_SERVICE_HEALTHY_BACKEND
  # shellcheck source=/dev/null
  source "$SBX/scripts/automation/lib/common.sh" >/dev/null 2>&1
  CHAIN_BACKEND_PORT=1 CHAIN_FRONTEND_PORT=2 ensure_phase_ports >/dev/null 2>&1
  echo "VERIFY=${CHAIN_SERVICE_VERIFY_BACKEND:-<unset>}"
) >"$WORK/d4f.log" 2>&1
if grep -q "VERIFY=grep -q iad-demo-api" "$WORK/d4f.log"; then
  assert "D4f ensure_phase_ports loads the project contract automatically" pass
else
  assert "D4f the contract file is not wired into the pipeline (see $WORK/d4f.log)" fail
fi
# An explicit environment value must beat the file, so CI can override per run.
(
  set +e
  export REPO_ROOT="$SBX"
  export CHAIN_SERVICE_VERIFY_BACKEND="operator-override"
  # shellcheck source=/dev/null
  source "$SBX/scripts/automation/lib/common.sh" >/dev/null 2>&1
  service_contracts_load
  echo "VERIFY=${CHAIN_SERVICE_VERIFY_BACKEND}"
) >"$WORK/d4g.log" 2>&1
if grep -q "VERIFY=operator-override" "$WORK/d4g.log"; then
  assert "D4g an explicit environment override beats the contract file" pass
else
  assert "D4g the contract file clobbered an explicit override" fail
fi
echo

echo "== summary: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
