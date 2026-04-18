#!/usr/bin/env bash
# browser-qa-phase.sh — Run browser QA for a phase using Chrome MCP
# Usage: ./scripts/automation/browser-qa-phase.sh phase-3
#
# Executes UI test cases from the ui-test-plan through browser automation.
# Self-bootstrapping: auto-starts frontend if not running (same as qa-phase.sh).
# Runs after ui-test-design-phase.sh completes.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

PHASE="${1:-}"
require_phase_arg "$PHASE"
require_claude

SPEC=$(phase_spec_path "$PHASE")
if [[ -z "$SPEC" ]]; then
  echo "Error: No spec found for '$PHASE' in docs/phases/" >&2
  exit 1
fi

PLAN_FILE="$REPO_ROOT/runs/${PHASE}/plan.md"
UI_TEST_PLAN="$REPO_ROOT/reports/phase-${PHASE}-ui-test-plan.md"
UI_SURFACE_MAP="$REPO_ROOT/reports/phase-${PHASE}-ui-surface-map.md"
UI_TEST_RESULTS="$REPO_ROOT/reports/phase-${PHASE}-ui-test-results.md"

echo "[browser-qa] Running browser QA for: $PHASE"

# Detect frontend
FRONTEND_PRESENT="no"
if detect_frontend_in_plan "$PLAN_FILE"; then
  FRONTEND_PRESENT="yes"
fi

# Skip for backend-only phases
if [[ "$FRONTEND_PRESENT" == "no" ]]; then
  echo "[browser-qa] Backend-only phase — writing N/A stubs."
  write_na_ui_artifacts "$PHASE" "ui-test-results"
  echo "[browser-qa] Done (backend-only, N/A stubs written)."
  exit 0
fi

# Verify test plan exists
if [[ ! -f "$UI_TEST_PLAN" ]]; then
  echo "Error: UI test plan not found at $UI_TEST_PLAN" >&2
  echo "Run ./scripts/automation/ui-test-design-phase.sh $PHASE first." >&2
  exit 1
fi

# ── Service bootstrapping (same pattern as qa-phase.sh) ───────────────────
QA_STARTED_PIDS=()

_wait_for_url() {
  local url="$1" name="$2" max_wait="${3:-60}"
  local waited=0
  echo "[browser-qa] Waiting for $name at $url (max ${max_wait}s)..."
  while true; do
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || true)
    if [[ "$code" =~ ^[23] ]]; then
      echo "[browser-qa] $name is ready (${waited}s)."
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
    if [[ $waited -ge $max_wait ]]; then
      echo "[browser-qa] Warning: $name did not become ready within ${max_wait}s (last status: $code)." >&2
      return 1
    fi
  done
}

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

_cleanup_browser_qa_services() {
  if [[ ${#QA_STARTED_PIDS[@]} -eq 0 ]]; then return; fi
  echo "[browser-qa] Stopping services started by browser QA..."
  for pid in "${QA_STARTED_PIDS[@]}"; do
    _stop_pid_tree "$pid"
  done
}
trap _cleanup_browser_qa_services EXIT

# Resolve start commands
BACKEND_START_CMD="${CHAIN_START_BACKEND_CMD:-}"
FRONTEND_START_CMD="${CHAIN_START_FRONTEND_CMD:-}"

if [[ -z "$BACKEND_START_CMD" ]] && [[ -f "$REPO_ROOT/scripts/start-backend.sh" ]]; then
  BACKEND_START_CMD="bash $REPO_ROOT/scripts/start-backend.sh"
fi
if [[ -z "$FRONTEND_START_CMD" ]] && [[ -f "$REPO_ROOT/scripts/start-frontend.sh" ]]; then
  FRONTEND_START_CMD="bash $REPO_ROOT/scripts/start-frontend.sh"
fi

# Derive URLs from port env vars
_BACKEND_PORT="${CHAIN_BACKEND_PORT:-8000}"
_FRONTEND_PORT="${CHAIN_FRONTEND_PORT:-3000}"
BACKEND_HEALTH_URL="${CHAIN_BACKEND_HEALTH_URL:-http://localhost:${_BACKEND_PORT}/health}"
FRONTEND_URL="${CHAIN_FRONTEND_URL:-http://localhost:${_FRONTEND_PORT}}"

# ── Start backend if not running ──────────────────────────────────────────
BACKEND_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BACKEND_HEALTH_URL" 2>/dev/null || true)
BACKEND_STARTED_BY_QA=false
if [[ ! "$BACKEND_STATUS" =~ ^[23] ]]; then
  if [[ -n "$BACKEND_START_CMD" ]]; then
    echo "[browser-qa] Backend not running -- starting (log: /tmp/browser-qa-backend.log)..."
    $BACKEND_START_CMD >/tmp/browser-qa-backend.log 2>&1 &
    QA_STARTED_PIDS+=($!)
    BACKEND_STARTED_BY_QA=true
    _wait_for_url "$BACKEND_HEALTH_URL" "backend" 90 || true
  else
    echo "[browser-qa] Backend not running and no start command configured." >&2
    echo "[browser-qa] Set CHAIN_START_BACKEND_CMD or provide scripts/start-backend.sh" >&2
  fi
else
  echo "[browser-qa] Backend already running at $BACKEND_HEALTH_URL."
fi

# ── Start frontend (kill stale instance first to ensure correct API URL) ──
# A stale frontend may have a different backend port baked in from a previous run.
# Also kill any orphaned Next.js dev servers from previous agent runs — Next.js
# refuses to start a second dev server in the same directory even on a different port.
FRONTEND_STARTED_BY_QA=false
echo "[browser-qa] Clearing any stale Next.js dev server for this project..."
kill_stale_next_dev_server
FRONTEND_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$FRONTEND_URL" 2>/dev/null || true)
if [[ "$FRONTEND_STATUS" =~ ^[23] ]]; then
  STALE_PIDS=$(lsof -ti "tcp:${_FRONTEND_PORT}" 2>/dev/null || true)
  if [[ -n "$STALE_PIDS" ]]; then
    echo "[browser-qa] Killing stale frontend on port ${_FRONTEND_PORT} to ensure correct API URL..."
    kill -TERM $STALE_PIDS 2>/dev/null || true
    sleep 2
  fi
fi

if [[ -n "$FRONTEND_START_CMD" ]]; then
  echo "[browser-qa] Starting frontend (port ${_FRONTEND_PORT}, API→localhost:${_BACKEND_PORT}, log: /tmp/browser-qa-frontend.log)..."
  $FRONTEND_START_CMD >/tmp/browser-qa-frontend.log 2>&1 &
  QA_STARTED_PIDS+=($!)
  FRONTEND_STARTED_BY_QA=true
  _wait_for_url "$FRONTEND_URL" "frontend" 120 || true
else
  echo "[browser-qa] No frontend start command configured." >&2
  echo "[browser-qa] Set CHAIN_START_FRONTEND_CMD or provide scripts/start-frontend.sh" >&2
  echo "[browser-qa] Browser QA will write SKIPPED results."
fi

FRONTEND_RUNNING_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$FRONTEND_URL" 2>/dev/null || true)
if [[ "$FRONTEND_RUNNING_STATUS" =~ ^[23] ]]; then
  FRONTEND_AVAILABLE="yes"
else
  FRONTEND_AVAILABLE="no"
  echo "[browser-qa] Frontend not available — browser tests will be marked SKIPPED."
fi

SERVICES_NOTE=""
if [[ "$FRONTEND_STARTED_BY_QA" == "true" || "$BACKEND_STARTED_BY_QA" == "true" ]]; then
  SERVICES_NOTE="Note: browser-qa-phase.sh auto-started services (backend: $BACKEND_STARTED_BY_QA, frontend: $FRONTEND_STARTED_BY_QA). They will be stopped after QA completes."
fi

# ── Run browser QA agent ───────────────────────────────────────────────────
cd "$REPO_ROOT"
claude_with_quota_retry -p "You are the browser-qa-agent for phased development.

Phase: $PHASE
Phase spec: $SPEC
CLAUDE.md: $REPO_ROOT/CLAUDE.md
Agent instructions: .claude/agents/browser-qa-agent.md  <-- read this first
Skill: .claude/skills/browser-workflow-executor.md  <-- read for Chrome MCP technique

UI test plan: $UI_TEST_PLAN  <-- execute each test case in this file
UI surface map: $UI_SURFACE_MAP

Frontend URL: $FRONTEND_URL
Frontend available: $FRONTEND_AVAILABLE
$SERVICES_NOTE

$(if [[ "$FRONTEND_AVAILABLE" == "yes" ]]; then
  echo "Chrome MCP browser checks ARE required. Use mcp__plugin_superpowers-chrome_chrome__use_browser for each test case."
else
  echo "Frontend is NOT available. Mark all tests as SKIPPED with reason: frontend not running."
  echo "Do NOT attempt to run browser tests."
fi)

Execute the test plan:
- For each UT-XX test case: execute steps, verify expected result, record PASS/FAIL/SKIP
- Take screenshots for key states and save to reports/qa/${PHASE}-evidence/
- For failures: record exact failure description

Write your results to: $UI_TEST_RESULTS
Use template: templates/ui-test-results.md

The report MUST contain a line at the top:
**Browser QA Verdict:** PASS
  or
**Browser QA Verdict:** FAIL
  or
**Browser QA Verdict:** SKIPPED

Then STOP."

echo "[browser-qa] Done. Report: $UI_TEST_RESULTS"
