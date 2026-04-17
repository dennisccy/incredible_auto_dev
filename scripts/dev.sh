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

# Kill processes occupying the ports and wait until they are free
for PORT in $BACKEND_PORT $FRONTEND_PORT; do
  PIDS=$(lsof -ti :$PORT 2>/dev/null | sort -u || true)
  if [ -n "$PIDS" ]; then
    echo "Killing processes on port $PORT: $PIDS"
    kill -9 $PIDS 2>/dev/null || true
  fi
  # Also kill via fuser (catches child processes lsof may list under a different PID)
  fuser -k -9 $PORT/tcp 2>/dev/null || true
  # Wait until port is fully released: no owning process AND no lingering socket
  for i in $(seq 1 50); do
    if ! lsof -ti :$PORT >/dev/null 2>&1 && \
       ! ss -tlnH sport = :$PORT 2>/dev/null | grep -q .; then
      break
    fi
    # On each iteration, re-kill anything that's still holding the port
    fuser -k -9 $PORT/tcp 2>/dev/null || true
    sleep 0.1
  done
done

# Start backend
echo "Starting backend on :$BACKEND_PORT ..."
(
  cd "$ROOT_DIR/apps/backend"
  source .venv/bin/activate
  uvicorn main:app --reload --host 0.0.0.0 --port $BACKEND_PORT
) &
BACKEND_PID=$!

# Start frontend
echo "Starting frontend on :$FRONTEND_PORT ..."
(
  cd "$ROOT_DIR/apps/frontend"
  NEXT_PUBLIC_API_PORT="${BACKEND_PORT}" npx next dev -p "$FRONTEND_PORT"
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
