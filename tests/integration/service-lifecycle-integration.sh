#!/usr/bin/env bash
# service-lifecycle-integration.sh — HARD-5 integration validation.
#
# NOT part of the offline eval suite: it binds the canonical offset ports of a
# scratch project and takes ~40s of real wall time. Run it by hand when changing
# the service lifecycle, and after a vendored sync into a product checkout:
#
#     bash tests/integration/service-lifecycle-integration.sh
#
# It builds an ISOLATED scratch project (never a product repo) with a real HTTP
# service, and drives the REAL shipped lifecycle functions across five sessions:
#
#   A  a session starts the app, and it SURVIVES both the phase-boundary sweep
#      and the final-summary sweep
#   B  a SECOND session (a genuinely different owner process) reuses the SAME
#      process — no restart, no port drift, frontend/backend pairing intact
#   C  a code revision change causes a CONTROLLED restart on the same port
#   D  an unowned, incompatible listener SURVIVES and produces an operational
#      blocker; the dependency is not claimed satisfied and the port is not
#      switched
#   E  a server an agent started and abandoned IS cleaned up
#   F  the lifecycle telemetry of all of the above is recorded
#
# Scope, stated plainly: this covers the service-lifecycle layer end to end. It
# does NOT dispatch agents — a full run-goal.sh session needs model calls, which
# is spend an operator has to authorise separately.
set -uo pipefail

# Derive the engine from this script's own location so the harness works
# unchanged in a vendored product checkout.
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f "$ENGINE/scripts/automation/lib/service-owner.sh" ]] || {
  echo "ERROR: cannot locate the framework from $ENGINE" >&2; exit 2; }
_TMPBASE="${CHAIN_TMP_ROOT:-${TMPDIR:-/tmp}}"
mkdir -p "$_TMPBASE" 2>/dev/null || _TMPBASE="${TMPDIR:-/tmp}"
BASE="$(mktemp -d "$_TMPBASE/iad-lifecycle-int-XXXXXX")"
ROOT="$BASE/project"          # the git working tree the revision hash covers
SIDE="$BASE/side"             # everything runtime: logs, registry, tmp, scripts
export CHAIN_SERVICE_REGISTRY_DIR="$SIDE/registry"
export CHAIN_TMP_ROOT="$SIDE/tmp"
export TELEMETRY_ENABLED=true
export GOAL_SESSION_DIR="$ROOT/runs/session"   # runs/ is excluded from the hash
export GOAL_SESSION_ID="integration"
mkdir -p "$ROOT/.claude" "$ROOT/apps/backend" "$GOAL_SESSION_DIR" \
         "$CHAIN_TMP_ROOT" "$SIDE/registry" "$SIDE"

PASS=0; FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
chk() { if [[ "$2" == "$3" ]]; then ok "$1 ($3)"; else bad "$1 — expected '$2', got '$3'"; fi; }

TRACK=()
cleanup() {
  local p
  for p in ${TRACK[@]+"${TRACK[@]}"}; do kill -KILL "$p" 2>/dev/null || true; done
  for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    [[ -r "/proc/$p/cmdline" ]] || continue   # exited between listing and read
    case "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)" in
      *iad-lifecycle-int-*|*"$BASE"*) kill -KILL "$p" 2>/dev/null || true ;;
    esac
  done
  rm -rf "$BASE"
}
trap cleanup EXIT

git init -q "$ROOT"
echo "rev-1" > "$ROOT/apps/backend/app.py"
# Runtime noise must not move the revision hash; runs/ and reports/ are already
# in CHAIN_STEP_HASH_EXCLUDES, and everything else lives outside the tree.
printf '%s\n' '*.log' > "$ROOT/.gitignore"

# ── The application: a real HTTP service that reports its own build revision ──
cat > "$ROOT/app.py" <<'APP'
import os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
REV = open(os.environ["APP_REV_FILE"]).read().strip()
BODY = ('{"service":"iad-integration-api","revision":"%s"}' % REV).encode()
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        # /health is the readiness route; / is deliberately 404 so the run must
        # rely on the project's declared health contract, not on a 2xx default.
        if self.path.startswith("/health"):
            self.send_response(200); self.send_header("Content-Length", str(len(BODY)))
            self.end_headers(); self.wfile.write(BODY)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
APP
cat > "$ROOT/start-backend.sh" <<START
#!/usr/bin/env bash
exec python3 "$ROOT/app.py" "\${CHAIN_BACKEND_PORT}"
START
chmod +x "$ROOT/start-backend.sh"
cat > "$ROOT/.claude/service-contracts.sh" <<'CONTRACT'
export CHAIN_SERVICE_VERIFY_BACKEND='grep -q iad-integration-api'
export CHAIN_SERVICE_HEALTHY_BACKEND='^[23]'
CONTRACT

export APP_REV_FILE="$ROOT/apps/backend/app.py"

# ── Session driver: a fresh lifecycle owner each time, like a new engine ──────
session() {                      # session <label> <body-file>
  local label="$1" body="$2"
  IAD_ENGINE="$ENGINE" IAD_ROOT="$ROOT" IAD_SIDE="$SIDE" IAD_BODY="$body" \
  env -u CHAIN_SERVICE_OWNER_SCOPE -u CHAIN_SERVICE_OWNER_TOKEN \
      -u CHAIN_BACKEND_PORT -u CHAIN_FRONTEND_PORT -u CHAIN_ENGINE_TOKEN \
      -u _SERVICE_CONTRACTS_LOADED -u CHAIN_SERVICE_VERIFY_BACKEND \
      -u CHAIN_SERVICE_HEALTHY_BACKEND \
      bash -c '
    set +eu
    source "$IAD_ENGINE/scripts/automation/lib/common.sh" >/dev/null 2>&1
    source "$IAD_ENGINE/scripts/automation/lib/telemetry.sh" >/dev/null 2>&1
    export REPO_ROOT="$IAD_ROOT"
    export CHAIN_SERVICE_OWNER_KIND="goal-engine"
    reclaim_canonical_phase_ports
    ensure_phase_ports
    export QA_BACKEND_HEALTH_URL="http://127.0.0.1:${CHAIN_BACKEND_PORT}/health"
    export QA_BACKEND_START_CMD="bash $IAD_ROOT/start-backend.sh"
    export QA_BACKEND_LOG="$IAD_SIDE/backend.log"
    export QA_FRONTEND_REQUIRED="no"
    echo "SCOPE=$CHAIN_SERVICE_OWNER_SCOPE"
    echo "BE_PORT=$CHAIN_BACKEND_PORT"
    echo "FE_PORT=$CHAIN_FRONTEND_PORT"
    echo "VERIFY=${CHAIN_SERVICE_VERIFY_BACKEND:-<unset>}"
    source "$IAD_BODY"
  ' 2>&1
}

listener_pid() { ss -tlnpH "sport = :$1" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | head -1; }
health()       { curl -s --max-time 3 "http://127.0.0.1:$1/health" 2>/dev/null; }
status()       { curl -s -o /dev/null --max-time 3 -w "%{http_code}" "http://127.0.0.1:$1/health" 2>/dev/null; }

echo "=============================================================="
echo " HARD-5 integration validation — isolated project"
echo " project root : $ROOT"
echo "=============================================================="
echo

# ══ SESSION A ════════════════════════════════════════════════════════════════
cat > "$SIDE/sessA.sh" <<'BODY'
ensure_services_running
echo "BACKEND_UP=$QA_BACKEND_UP"
echo "REC=$(service_owner_classify "$CHAIN_BACKEND_PORT")"
kill_phase_servers                       # phase boundary
echo "AFTER_PHASE_BOUNDARY=$(curl -s -o /dev/null --max-time 3 -w '%{http_code}' "$QA_BACKEND_HEALTH_URL")"
kill_phase_servers                       # final summary
echo "AFTER_FINAL_SUMMARY=$(curl -s -o /dev/null --max-time 3 -w '%{http_code}' "$QA_BACKEND_HEALTH_URL")"
BODY
A_OUT="$(session A "$SIDE/sessA.sh")"
echo "--- session A ---"; echo "$A_OUT" | sed 's/^/    /'
BE=$(sed -n 's/^BE_PORT=//p' <<<"$A_OUT"); FE=$(sed -n 's/^FE_PORT=//p' <<<"$A_OUT")
A_SCOPE=$(sed -n 's/^SCOPE=//p' <<<"$A_OUT")
A_PID=$(listener_pid "$BE"); TRACK+=("$A_PID")
echo
echo "### 1. Session A: service started, owned, and SURVIVES both sweeps"
chk "backend came up"                 "yes"       "$(sed -n 's/^BACKEND_UP=//p' <<<"$A_OUT")"
chk "ownership record is MINE"        "MINE"      "$(sed -n 's/^REC=//p' <<<"$A_OUT" | cut -d: -f1)"
chk "alive after phase boundary"      "200"       "$(sed -n 's/^AFTER_PHASE_BOUNDARY=//p' <<<"$A_OUT")"
chk "alive after final summary"       "200"       "$(sed -n 's/^AFTER_FINAL_SUMMARY=//p' <<<"$A_OUT")"
echo "    pid=$A_PID  port=$BE  identity=$(cat /proc/$A_PID/stat 2>/dev/null | sed 's/.*) //' | awk '{print $20}')"
echo "    health body: $(health "$BE")"
echo

# ══ SESSION B — reuse, no drift, no termination ══════════════════════════════
cat > "$SIDE/sessB.sh" <<'BODY'
ensure_services_running
echo "BACKEND_UP=$QA_BACKEND_UP"
echo "DECISION=$(service_reuse_decision backend "$QA_BACKEND_HEALTH_URL" "$CHAIN_BACKEND_PORT")"
BODY
B_OUT="$(session B "$SIDE/sessB.sh")"
echo "--- session B ---"; echo "$B_OUT" | sed 's/^/    /'
B_PID=$(listener_pid "$BE")
echo
echo "### 2. Session B: reuses the SAME process, no drift, no restart"
chk "same backend port (no drift)"    "$BE"       "$(sed -n 's/^BE_PORT=//p' <<<"$B_OUT")"
chk "same frontend port (pairing)"    "$FE"       "$(sed -n 's/^FE_PORT=//p' <<<"$B_OUT")"
chk "SAME process pid — not restarted" "$A_PID"   "$B_PID"
chk "reuse decision"                  "REUSE"     "$(sed -n 's/^DECISION=//p' <<<"$B_OUT")"
chk "still serving"                   "200"       "$(status "$BE")"
echo "    session A scope: $A_SCOPE"
echo "    session B scope: $(sed -n 's/^SCOPE=//p' <<<"$B_OUT")   (different owner, same service)"
echo

# ══ SESSION C — a code revision change forces a controlled restart ═══════════
echo "rev-2" > "$ROOT/apps/backend/app.py"
cat > "$SIDE/sessC.sh" <<'BODY'
# NOTE: the session-start reclaim already evaluates the revision, so by the time
# this body runs the stale service has been released. That IS the controlled
# restart — assert on the framework's own decision line, not on a predicate
# re-evaluated after the fact.
ensure_services_running
echo "BACKEND_UP=$QA_BACKEND_UP"
BODY
C_OUT="$(session C "$SIDE/sessC.sh")"
echo "--- session C (after editing apps/backend/app.py) ---"; echo "$C_OUT" | sed 's/^/    /'
C_PID=$(listener_pid "$BE"); TRACK+=("$C_PID")
echo
echo "### 3. A revision change causes a CONTROLLED restart"
grep -q "a restart is required" <<<"$C_OUT" \
  && ok "framework decided a restart was required (revision moved)" \
  || bad "no restart decision recorded — a stale service would have been reused"
if [[ -n "$C_PID" && "$C_PID" != "$A_PID" ]]; then
  ok "restarted: new pid $C_PID (was $A_PID)"
else
  bad "expected a NEW pid after the revision change (got '$C_PID', old '$A_PID')"
fi
chk "healthy on the same port"        "200"       "$(status "$BE")"
echo "    serving revision: $(health "$BE")"
echo

# ══ SESSION D — an unowned incompatible listener survives + blocks ═══════════
# Free the port, then put a foreign service on it that answers but is NOT ours.
kill -KILL "$C_PID" 2>/dev/null; sleep 1
python3 -c "
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        b=b'{\"service\":\"somebody-elses-app\"}'
        self.send_response(200); self.send_header('Content-Length',str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
" "$BE" >/dev/null 2>&1 &
FOREIGN=$!; TRACK+=("$FOREIGN"); sleep 1.5
cat > "$SIDE/sessD.sh" <<'BODY'
ensure_services_running
echo "BACKEND_UP=$QA_BACKEND_UP"
echo "TAIL=$QA_BACKEND_LOG_TAIL"
kill_phase_servers
BODY
D_OUT="$(session D "$SIDE/sessD.sh")"
echo "--- session D (foreign service squatting the port) ---"; echo "$D_OUT" | sed 's/^/    /' | head -20
sleep 1
echo
echo "### 4. An unowned, incompatible listener SURVIVES and produces a blocker"
if kill -0 "$FOREIGN" 2>/dev/null; then ok "foreign service still alive (pid $FOREIGN)"; else bad "foreign service was KILLED"; fi
chk "dependency NOT claimed satisfied" "no"       "$(sed -n 's/^BACKEND_UP=//p' <<<"$D_OUT")"
grep -q "BLOCKED" <<<"$D_OUT" && ok "operational blocker reported" || bad "no blocker reported"
grep -q "$BE" <<<"$D_OUT"      && ok "blocker names the port $BE" || bad "blocker does not name the port"
chk "port NOT drifted"                 "$BE"      "$(sed -n 's/^BE_PORT=//p' <<<"$D_OUT")"
echo
kill -KILL "$FOREIGN" 2>/dev/null; sleep 1

# ══ SESSION E — an agent-created ephemeral server IS cleaned up ══════════════
cat > "$SIDE/sessE.sh" <<'BODY'
# Simulate what a developer/QA agent does inside a dispatch: start a server and
# abandon it. It inherits the dispatch's ownership scope, so it is provably ours.
python3 -c "
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(200); self.end_headers()
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
" "$CHAIN_BACKEND_PORT" >/dev/null 2>&1 &
echo "AGENT_PID=$!"
sleep 1.5
echo "BEFORE=$(curl -s -o /dev/null --max-time 3 -w '%{http_code}' "http://127.0.0.1:$CHAIN_BACKEND_PORT/")"
kill_phase_servers
sleep 1
echo "AFTER=$(curl -s -o /dev/null --max-time 3 -w '%{http_code}' "http://127.0.0.1:$CHAIN_BACKEND_PORT/")"
BODY
E_OUT="$(session E "$SIDE/sessE.sh")"
echo "--- session E (abandoned agent server) ---"; echo "$E_OUT" | sed 's/^/    /'
echo
echo "### 5. An agent-created ephemeral server IS cleaned up"
chk "agent server was serving"        "200"       "$(sed -n 's/^BEFORE=//p' <<<"$E_OUT")"
chk "reaped by the phase sweep"       "000"       "$(sed -n 's/^AFTER=//p' <<<"$E_OUT")"
echo

# ══ Telemetry ════════════════════════════════════════════════════════════════
echo "### 6. Lifecycle telemetry recorded"
TELEM="$GOAL_SESSION_DIR/telemetry.jsonl"
if [[ -s "$TELEM" ]]; then
  echo "    $TELEM  ($(wc -l < "$TELEM") events)"
  grep -oE '"event":"services_[a-z_]+"' "$TELEM" 2>/dev/null | sort | uniq -c | sed 's/^/    /'
  for want in services_preserved services_terminated services_port_blocked services_released_for_restart; do
    grep -q "\"event\":\"$want\"" "$TELEM" \
      && ok "telemetry: $want recorded" || bad "telemetry: $want missing"
  done
  echo "    sample rows:"
  grep -E '"event":"services_' "$TELEM" | head -4 | sed 's/^/      /'
else
  bad "no telemetry written to $TELEM"
fi
echo
echo "=============================================================="
echo " integration result: $PASS passed, $FAIL failed"
echo "=============================================================="
[[ $FAIL -eq 0 ]]
