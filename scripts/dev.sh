#!/usr/bin/env bash
set -e

BACKEND_PORT="${CHAIN_BACKEND_PORT:-8000}"
FRONTEND_PORT="${CHAIN_FRONTEND_PORT:-3000}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Kill processes occupying the ports
for PORT in $BACKEND_PORT $FRONTEND_PORT; do
  PIDS=$(lsof -ti :$PORT 2>/dev/null | sort -u || true)
  if [ -n "$PIDS" ]; then
    echo "Killing processes on port $PORT: $PIDS"
    kill -9 $PIDS 2>/dev/null || true
    sleep 0.5
  fi
done

# Start backend
echo "Starting backend on :$BACKEND_PORT ..."
(
  cd "$ROOT_DIR/apps/backend"
  source .venv/bin/activate
  uvicorn main:app --reload --port $BACKEND_PORT
) &
BACKEND_PID=$!

# Start frontend
echo "Starting frontend on :$FRONTEND_PORT ..."
(
  cd "$ROOT_DIR/apps/frontend"
  NEXT_PUBLIC_API_URL="http://localhost:${BACKEND_PORT}" npx next dev -p "$FRONTEND_PORT"
) &
FRONTEND_PID=$!

echo "Backend PID: $BACKEND_PID  |  Frontend PID: $FRONTEND_PID"
echo "Press Ctrl+C to stop both."

# Propagate Ctrl+C to both children
trap "kill $BACKEND_PID $FRONTEND_PID 2>/dev/null; exit 0" INT TERM

wait
