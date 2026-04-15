#!/usr/bin/env bash
# qa-phase.sh — Run QA validation for a phase
# Usage: ./scripts/automation/qa-phase.sh phase-3
#
# Self-bootstrapping: if services are not running, this script can start
# them automatically using CHAIN_START_BACKEND_CMD / CHAIN_START_FRONTEND_CMD
# env vars, or the conventional scripts/start-backend.sh and scripts/start-frontend.sh.
# Logs for auto-started services are written to /tmp/qa-{backend,frontend}.log.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

PHASE="${1:-}"
require_phase_arg "$PHASE"
require_claude

REVIEW="$REPO_ROOT/reports/reviews/${PHASE}-review.md"
if [[ ! -f "$REVIEW" ]]; then
  echo "Error: Review report not found at $REVIEW" >&2
  echo "Run ./scripts/automation/review-phase.sh $PHASE first." >&2
  exit 1
fi

PLAN_FILE="$REPO_ROOT/runs/${PHASE}/plan.md"
SPEC=$(phase_spec_path "$PHASE")
TEST_PLAN="$REPO_ROOT/reports/qa/${PHASE}-test-plan.md"

# Detect if this phase has frontend (for Chrome MCP decision)
FRONTEND_PRESENT="no"
if detect_frontend_in_plan "$PLAN_FILE"; then
  FRONTEND_PRESENT="yes"
fi

echo "[qa-phase] Running QA for: $PHASE (frontend: $FRONTEND_PRESENT)"

# ── Service bootstrapping ─────────────────────────────────────────────────
QA_STARTED_PIDS=()

# Wait until a URL responds with a 2xx/3xx status code, or timeout.
_wait_for_url() {
  local url="$1" name="$2" max_wait="${3:-60}"
  local waited=0
  echo "[qa-phase] Waiting for $name at $url (max ${max_wait}s)..."
  while true; do
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || true)
    if [[ "$code" =~ ^[23] ]]; then
      echo "[qa-phase] $name is ready (${waited}s)."
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
    if [[ $waited -ge $max_wait ]]; then
      echo "[qa-phase] Warning: $name did not become ready within ${max_wait}s (last status: $code)." >&2
      return 1
    fi
  done
}

# Recursively kill a process and all its descendants (depth-first, leaves first).
_stop_pid_tree() {
  local pid=$1
  [[ -z "$pid" ]] && return
  local children
  children=$(pgrep -P "$pid" 2>/dev/null || true)
  for child in $children; do
    _stop_pid_tree "$child"
  done
  kill -TERM "$pid" 2>/dev/null || true
}

# Stop any services we started when this script exits (success or error).
_cleanup_qa_services() {
  if [[ ${#QA_STARTED_PIDS[@]} -eq 0 ]]; then return; fi
  echo "[qa-phase] Stopping services started by QA..."
  for pid in "${QA_STARTED_PIDS[@]}"; do
    echo "[qa-phase]   Stopping pid $pid and its children..."
    _stop_pid_tree "$pid"
  done
}
trap _cleanup_qa_services EXIT

# Resolve start commands — use env vars if set, fall back to conventional scripts
BACKEND_START_CMD="${CHAIN_START_BACKEND_CMD:-}"
FRONTEND_START_CMD="${CHAIN_START_FRONTEND_CMD:-}"

if [[ -z "$BACKEND_START_CMD" ]] && [[ -f "$REPO_ROOT/scripts/start-backend.sh" ]]; then
  BACKEND_START_CMD="bash $REPO_ROOT/scripts/start-backend.sh"
fi
if [[ -z "$FRONTEND_START_CMD" ]] && [[ -f "$REPO_ROOT/scripts/start-frontend.sh" ]]; then
  FRONTEND_START_CMD="bash $REPO_ROOT/scripts/start-frontend.sh"
fi

# Derive URLs from port env vars (set by run-phase.sh for port isolation)
_BACKEND_PORT="${CHAIN_BACKEND_PORT:-8000}"
_FRONTEND_PORT="${CHAIN_FRONTEND_PORT:-3000}"
BACKEND_HEALTH_URL="${CHAIN_BACKEND_HEALTH_URL:-http://localhost:${_BACKEND_PORT}/health}"
FRONTEND_URL="${CHAIN_FRONTEND_URL:-http://localhost:${_FRONTEND_PORT}}"

# Start backend if not already running.
BACKEND_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BACKEND_HEALTH_URL" 2>/dev/null || true)
BACKEND_STARTED_BY_QA=false
if [[ ! "$BACKEND_STATUS" =~ ^[23] ]]; then
  if [[ -n "$BACKEND_START_CMD" ]]; then
    echo "[qa-phase] Backend not running -- starting for QA (log: /tmp/qa-backend.log)..."
    $BACKEND_START_CMD >/tmp/qa-backend.log 2>&1 &
    QA_STARTED_PIDS+=($!)
    BACKEND_STARTED_BY_QA=true
    _wait_for_url "$BACKEND_HEALTH_URL" "backend" 90 || true
  else
    echo "[qa-phase] Backend not running and no start command configured." >&2
    echo "[qa-phase] Set CHAIN_START_BACKEND_CMD or provide scripts/start-backend.sh" >&2
  fi
else
  echo "[qa-phase] Backend already running at $BACKEND_HEALTH_URL."
fi

# Start frontend if not running AND this phase has frontend.
# First kill any orphaned Next.js dev servers — Next.js refuses to start a
# second dev server in the same directory even on a different port.
FRONTEND_STARTED_BY_QA=false
if [[ "$FRONTEND_PRESENT" == "yes" ]]; then
  STALE_NEXT_PIDS=$(pgrep -f "next-server" 2>/dev/null || true)
  if [[ -n "$STALE_NEXT_PIDS" ]]; then
    echo "[qa-phase] Killing orphaned Next.js servers (PIDs: $STALE_NEXT_PIDS)..."
    pkill -f "next dev" 2>/dev/null || true
    pkill -f "next-server" 2>/dev/null || true
    for port in 3000 3001; do
      fuser -k "${port}/tcp" 2>/dev/null || true
    done
    sleep 2
  fi
  FRONTEND_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$FRONTEND_URL" 2>/dev/null || true)
  if [[ ! "$FRONTEND_STATUS" =~ ^[23] ]]; then
    if [[ -n "$FRONTEND_START_CMD" ]]; then
      echo "[qa-phase] Frontend not running -- starting for QA (log: /tmp/qa-frontend.log)..."
      $FRONTEND_START_CMD >/tmp/qa-frontend.log 2>&1 &
      QA_STARTED_PIDS+=($!)
      FRONTEND_STARTED_BY_QA=true
      _wait_for_url "$FRONTEND_URL" "frontend" 120 || true
    else
      echo "[qa-phase] Frontend not running and no start command configured." >&2
      echo "[qa-phase] Set CHAIN_START_FRONTEND_CMD or provide scripts/start-frontend.sh" >&2
    fi
  else
    echo "[qa-phase] Frontend already running at $FRONTEND_URL."
  fi
fi

# Build services context note for the agent prompt.
SERVICES_NOTE=""
if [[ "$BACKEND_STARTED_BY_QA" == "true" || "$FRONTEND_STARTED_BY_QA" == "true" ]]; then
  SERVICES_NOTE="
Note: The QA runner auto-started the following services for this validation:
$(if [[ "$BACKEND_STARTED_BY_QA" == "true" ]]; then echo "  - Backend  ($BACKEND_HEALTH_URL) — started by qa-phase.sh, log: /tmp/qa-backend.log"; fi)
$(if [[ "$FRONTEND_STARTED_BY_QA" == "true" ]]; then echo "  - Frontend ($FRONTEND_URL) — started by qa-phase.sh, log: /tmp/qa-frontend.log"; fi)
These services will be stopped automatically after QA completes.
You do NOT need to start or stop them yourself."
fi

# ── Run QA agent ──────────────────────────────────────────────────────────
cd "$REPO_ROOT"
claude_with_quota_retry -p "You are the qa agent operating in QA VALIDATION mode for phased development.

Phase: $PHASE
Phase spec: $SPEC
Review report: $REVIEW
Execution plan: $PLAN_FILE
CLAUDE.md: $REPO_ROOT/CLAUDE.md
Project template: .claude/project-template.md  <-- read this for test commands
Agent instructions: .claude/agents/qa.md  <-- read this first, follow MODE 2 instructions

Apply the TOKEN AND QUESTIONING POLICY from .claude/core.md strictly.

Frontend Present for this phase: $FRONTEND_PRESENT
$(if [[ "$FRONTEND_PRESENT" == "yes" ]]; then
  echo "Chrome MCP browser checks ARE required. The frontend should be accessible at $FRONTEND_URL."
else
  echo "No frontend in this phase -- skip browser checks entirely."
fi)
$(if [[ -f "$TEST_PLAN" ]]; then
  echo ""
  echo "Functional Test Plan: $TEST_PLAN  <-- read this and execute each test case step by step."
  echo "For each test case: record test ID, steps taken, expected result, actual result, PASS/FAIL, and notes."
  echo "Include the results table in your QA report."
else
  echo ""
  echo "No functional test plan found at $TEST_PLAN -- run standard QA checks only."
fi)
$SERVICES_NOTE

Write your QA report to: reports/qa/${PHASE}-qa.md

The report MUST contain a line matching exactly:
**Verdict:** PASS
  or
**Verdict:** FAIL"

echo "[qa-phase] Done. Report: reports/qa/${PHASE}-qa.md"
