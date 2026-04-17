#!/usr/bin/env bash
# start-backend.sh — Start the FastAPI backend for automated QA
# Used by qa-phase.sh and browser-qa-phase.sh when backend is not running.
# Respects CHAIN_BACKEND_PORT (default: 8000) for multi-project parallel runs.
set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Deterministic per-project port fallback (matches ensure_phase_ports in
# incredible_auto_dev/scripts/automation/lib/common.sh) so standalone runs
# don't collide with other projects on this machine.
_port_root="$REPO_ROOT"
[[ "$_port_root" == */incredible_auto_dev ]] && _port_root="${_port_root%/incredible_auto_dev}"
_offset=$(printf '%s' "$_port_root" | sha1sum | cut -c1-4)
_offset=$((16#$_offset % 1000))
PORT="${CHAIN_BACKEND_PORT:-$((8000 + _offset))}"

# Run pending migrations before starting
cd "$REPO_ROOT/apps/backend"
if [[ -d alembic ]]; then
  "$REPO_ROOT/apps/backend/.venv/bin/alembic" upgrade head 2>/dev/null || true
fi

exec "$REPO_ROOT/apps/backend/.venv/bin/uvicorn" main:app \
  --host 0.0.0.0 \
  --port "$PORT" \
  --app-dir "$REPO_ROOT/apps/backend"
