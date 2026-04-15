#!/usr/bin/env bash
# start-frontend.sh — Start the Next.js frontend for automated QA
# Used by browser-qa-phase.sh when frontend is not running.
# Respects CHAIN_FRONTEND_PORT (default: 3000) and CHAIN_BACKEND_PORT (default: 8000)
# for multi-project parallel runs.
set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRONTEND_PORT="${CHAIN_FRONTEND_PORT:-3000}"
BACKEND_PORT="${CHAIN_BACKEND_PORT:-8000}"

cd "$REPO_ROOT/apps/frontend"

# Tell Next.js frontend where the backend is
export NEXT_PUBLIC_API_PORT="${BACKEND_PORT}"

exec npx next dev -p "$FRONTEND_PORT"
