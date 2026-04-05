#!/usr/bin/env bash
# start-backend.sh — Start the FastAPI backend for automated QA
# Used by qa-phase.sh and browser-qa-phase.sh when backend is not running.
# Respects CHAIN_BACKEND_PORT (default: 8000) for multi-project parallel runs.
set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${CHAIN_BACKEND_PORT:-8000}"

exec "$REPO_ROOT/apps/backend/.venv/bin/uvicorn" main:app \
  --host 0.0.0.0 \
  --port "$PORT" \
  --app-dir "$REPO_ROOT/apps/backend"
