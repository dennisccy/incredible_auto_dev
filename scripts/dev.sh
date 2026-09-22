#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Deterministic per-project port offset (mirror of
# incredible_auto_dev/scripts/automation/lib/common.sh::_project_port_offset).
# Strip trailing /incredible_auto_dev so running from the subtree or the
# project root produces the same offset for a given project.
_port_root="$ROOT_DIR"
[[ "$_port_root" == */incredible_auto_dev ]] && _port_root="${_port_root%/incredible_auto_dev}"
_offset=$(printf '%s' "$_port_root" | sha1sum | cut -c1-4)
_offset=$((16#$_offset % 1000))
BACKEND_PORT="${CHAIN_BACKEND_PORT:-$((8000 + _offset))}"
FRONTEND_PORT="${CHAIN_FRONTEND_PORT:-$((3000 + _offset))}"

# ── Reclaim the ports (HARD-5: ownership-aware) ─────────────────────────────
# This used to `kill -9` every pid on the port and then `fuser -k -9` in a loop.
# That is the same owner-blind termination the pipeline was hardened against:
# it will happily kill a running Goal Mode session's app, or any unrelated
# service that happens to sit on this project's deterministic offset ports.
#
# Now: processes this dev stack provably started (including the orphans of a
# previous dev.sh whose launcher has since died) are reclaimed automatically.
# Anything else is reported and NOT killed — unless the operator states intent
# explicitly for this invocation with DEV_FORCE=1, which is deliberate,
# per-run, and loud rather than a silent default.
_SO_LIB="$ROOT_DIR/incredible_auto_dev/scripts/automation/lib/service-owner.sh"
[ -f "$_SO_LIB" ] || _SO_LIB="$ROOT_DIR/scripts/automation/lib/service-owner.sh"
if [ -f "$_SO_LIB" ]; then
  # REPO_ROOT must be EXPORTED, not set as a one-command prefix: every later
  # service_repo_hash() call derives the registry path and the repo-lineage check
  # from it, and a prefix assignment would leave those falling back to $PWD.
  export REPO_ROOT="$ROOT_DIR"
  # shellcheck source=/dev/null
  . "$_SO_LIB"
  service_owner_scope_init "$_port_root" "dev.sh" || true
fi

for PORT in $BACKEND_PORT $FRONTEND_PORT; do
  if command -v service_owner_terminate >/dev/null 2>&1; then
    if service_owner_terminate "$PORT" "dev.sh"; then
      continue
    fi
  fi
  # Still occupied by something we cannot prove is ours.
  #
  # Select LISTENERS ONLY. The previous `lsof -ti :$PORT` matched every socket
  # on that port in either direction, so an established CLIENT — a browser or a
  # curl talking to the app — was in the kill list purely for being connected.
  # Verified: with a listener and a separate client on one port, `lsof -ti :P`
  # returned both pids; `-sTCP:LISTEN` returned only the server.
  if command -v service_listener_pids >/dev/null 2>&1; then
    PIDS=$(service_listener_pids "$PORT" | tr '\n' ' ')
  else
    PIDS=$(lsof -ti "tcp:$PORT" -sTCP:LISTEN 2>/dev/null | sort -u || true)
  fi
  PIDS=$(echo $PIDS)
  [ -n "$PIDS" ] || continue
  if [ "${DEV_FORCE:-0}" = "1" ]; then
    # DEV_FORCE is explicit operator intent to reclaim THIS port, not a licence
    # to signal arbitrary pids. Scope: listeners on this port only; each one
    # named before it is signalled; identity bound at signal time so a pid that
    # exits mid-teardown and is recycled cannot inherit the KILL.
    echo "DEV_FORCE=1: reclaiming port $PORT. Listeners that will be terminated:"
    for p in $PIDS; do
      echo "    pid $p: $(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-120)"
    done
    # NO ownership stamp is required here: DEV_FORCE exists precisely to reclaim
    # a port this stack does not own, and the operator has stated that intent
    # for this invocation. So this cannot go through service_signal_tree — that
    # helper demands the caller's verified ownership scope and refuses without
    # one (by design, pinned by E2c), which silently turned this override into a
    # no-op that always ended in "still held". The act is bound to what the
    # operator authorised instead: capture the process identity, confirm that
    # same pid still LISTENS on this port, then have proc_signal.py pin it
    # (pidfd) and re-verify the identity before the first signal. A pid that
    # exited and was recycled in between fails one of those checks and is not
    # signalled.
    _PS="$(dirname "$_SO_LIB")/proc_signal.py"
    for p in $PIDS; do
      if command -v service_pid_starttime >/dev/null 2>&1; then
        _id="$(service_pid_starttime "$p")"
        if [ -z "$_id" ] || ! service_listener_pids "$PORT" | grep -qx "$p"; then
          echo "    pid $p is gone or no longer listens on :$PORT — not signalled"
          continue
        fi
        if [ -f "$_PS" ] && command -v python3 >/dev/null 2>&1; then
          python3 "$_PS" tree "$p" --grace 2 --identity "$_id" || true
        elif [ "$(service_pid_starttime "$p")" = "$_id" ]; then
          kill -TERM "$p" 2>/dev/null || true
        fi
      else
        kill -TERM "$p" 2>/dev/null || true
      fi
    done
    for i in $(seq 1 50); do
      ss -tlnH sport = :$PORT 2>/dev/null | grep -q . || break
      sleep 0.1
    done
    if ss -tlnH sport = :$PORT 2>/dev/null | grep -q .; then
      echo "ERROR: port $PORT is still held after DEV_FORCE reclaim — not proceeding." >&2
      exit 1
    fi
  else
    echo "ERROR: port $PORT is held by a listener this dev stack does not own:" >&2
    for p in $PIDS; do
      echo "  pid $p: $(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-120)" >&2
    done
    echo "  Refusing to kill it. This may be a running Goal Mode session, another" >&2
    echo "  developer stack, or an unrelated service." >&2
    echo "  Stop it yourself, or re-run with DEV_FORCE=1 to override deliberately." >&2
    exit 1
  fi
done

# Start backend
echo "Starting backend on :$BACKEND_PORT ..."
(
  cd "$ROOT_DIR/apps/backend"
  source .venv/bin/activate
  export CORS_ORIGINS="${CORS_ORIGINS:-http://localhost:${FRONTEND_PORT},http://localhost:3000,http://localhost:3001}"
  uvicorn main:app --reload --host 0.0.0.0 --port $BACKEND_PORT
) &
BACKEND_PID=$!

# Start frontend
echo "Starting frontend on :$FRONTEND_PORT ..."
(
  cd "$ROOT_DIR/apps/frontend"
  NEXT_PUBLIC_API_URL="http://localhost:${BACKEND_PORT}" NEXT_PUBLIC_API_PORT="${BACKEND_PORT}" npx next dev -p "$FRONTEND_PORT"
) &
FRONTEND_PID=$!

LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo ""
echo "  Backend:   http://localhost:${BACKEND_PORT}   http://${LOCAL_IP}:${BACKEND_PORT}"
echo "  Frontend:  http://localhost:${FRONTEND_PORT}   http://${LOCAL_IP}:${FRONTEND_PORT}"
echo ""
echo "  Backend PID: $BACKEND_PID  |  Frontend PID: $FRONTEND_PID"
echo "  Press Ctrl+C to stop both."

# Propagate Ctrl+C to both children
trap "kill $BACKEND_PID $FRONTEND_PID 2>/dev/null; exit 0" INT TERM

wait
