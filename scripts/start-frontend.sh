#!/usr/bin/env bash
# start-frontend.sh — Start the Next.js frontend for automated QA
# Used by browser-qa-phase.sh when frontend is not running.
# Respects CHAIN_FRONTEND_PORT (default: 3000) and CHAIN_BACKEND_PORT (default: 8000)
# for multi-project parallel runs.
set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Deterministic per-project port fallback (matches ensure_phase_ports in
# incredible_auto_dev/scripts/automation/lib/common.sh).
_port_root="$REPO_ROOT"
[[ "$_port_root" == */incredible_auto_dev ]] && _port_root="${_port_root%/incredible_auto_dev}"
_offset=$(printf '%s' "$_port_root" | sha1sum | cut -c1-4)
_offset=$((16#$_offset % 1000))
FRONTEND_PORT="${CHAIN_FRONTEND_PORT:-$((3000 + _offset))}"
BACKEND_PORT="${CHAIN_BACKEND_PORT:-$((8000 + _offset))}"

cd "$REPO_ROOT/apps/frontend"

# Tell the Next.js frontend where the backend is. Export both a full URL
# (what the app actually reads) and the port (for scripts that still refer
# to the old name). process.env takes precedence over .env.local in Next.js,
# so a hardcoded .env.local URL does not stick when QA uses a different port.
export NEXT_PUBLIC_API_URL="${NEXT_PUBLIC_API_URL:-http://localhost:${BACKEND_PORT}}"
export NEXT_PUBLIC_API_PORT="${BACKEND_PORT}"

exec npx next dev -p "$FRONTEND_PORT"
