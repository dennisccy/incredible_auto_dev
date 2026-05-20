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
# When CHAIN_SHARED_SERVICES=true, the caller (run-phase.sh's post-dev fanout)
# owns service lifecycle for the whole post-dev batch — we MUST NOT install
# the EXIT trap or the first branch to finish would tear down the shared app
# under the other still-running branch.
if [[ "${CHAIN_SHARED_SERVICES:-false}" != "true" ]]; then
  trap _cleanup_browser_qa_services EXIT
fi

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

# Kill any stale Next.js dev server for this project before starting — Next.js 16+
# refuses to start a second dev server in the same directory even on a different
# port, using .next/dev/lock as the signal. Also handle the case where a stale
# frontend may be bound with a different backend URL baked in.
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

# Export vars consumed by ensure_services_running (shared helper in common.sh).
# Project-scoped log paths prevent cross-project clobbering when multiple
# projects share this subtree.
QA_BACKEND_LOG=$(_qa_log_path "browser-qa-backend")
QA_FRONTEND_LOG=$(_qa_log_path "browser-qa-frontend")
export QA_BACKEND_HEALTH_URL="$BACKEND_HEALTH_URL"
export QA_BACKEND_START_CMD="$BACKEND_START_CMD"
export QA_BACKEND_LOG
export QA_FRONTEND_URL="$FRONTEND_URL"
export QA_FRONTEND_START_CMD="$FRONTEND_START_CMD"
export QA_FRONTEND_LOG
export QA_FRONTEND_REQUIRED="yes"

# Skip the boot when the caller has already booted services (post-dev fanout).
# The caller's _boot_shared_services already called ensure_services_running.
if [[ "${CHAIN_SHARED_SERVICES:-false}" != "true" ]]; then
  ensure_services_running
fi

FRONTEND_RUNNING_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$FRONTEND_URL" 2>/dev/null || true)
if [[ "$FRONTEND_RUNNING_STATUS" =~ ^[23] ]]; then
  FRONTEND_AVAILABLE="yes"
else
  FRONTEND_AVAILABLE="no"
  echo "[browser-qa] Frontend not available — browser tests will be marked SKIPPED."
fi

SERVICES_NOTE="Note: browser-qa-phase.sh manages backend (${BACKEND_HEALTH_URL}, log: ${QA_BACKEND_LOG}) and frontend (${FRONTEND_URL}, log: ${QA_FRONTEND_LOG}). Services are restarted automatically if they die during quota-retry sleeps."

# Pre-retry hook — revive any services that died during a long quota sleep
# before claude attempts the next call.
export CHAIN_CLAUDE_PRE_RETRY_HOOK="ensure_services_running"

# ── Run browser QA agent ───────────────────────────────────────────────────
cd "$REPO_ROOT"
export CHAIN_CURRENT_AGENT=browser-qa-agent
# Guard against `set -e` so we can inspect the exit code and fall back to
# writing a SKIPPED stub when the agent leaves no results file.
_bqa_rc=0
claude_with_quota_retry -p "You are the browser-qa-agent for phased development.

Phase: $PHASE
Phase spec: $SPEC
Agent instructions: .claude/agents/browser-qa-agent.md  <-- read this first
(CLAUDE.md is already in your system prompt — do not Read it again.)
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

Then STOP." || _bqa_rc=$?

# Signal-induced exit (Ctrl-C, SIGKILL, SIGTERM) → do NOT write SKIPPED stubs.
# A stub would advertise the step as "ran but produced no real artifact," which
# tricks run-phase.sh's retry loop into advancing the checkpoint past this step
# (`update_status ... browser_qa_complete`). The next resume would then skip
# the step but closure-check would flag the stub as missing real content. By
# exiting without stubs, the working tree is unchanged so resume re-runs the
# step and run-phase.sh's signal-aware retry guard aborts the run cleanly.
# See .claude/anti-patterns.md #20.
if [[ $_bqa_rc -eq 130 || $_bqa_rc -eq 137 || $_bqa_rc -eq 143 ]]; then
  echo "[browser-qa] Killed by signal (exit $_bqa_rc) — leaving artifacts untouched so resume can re-run this step." >&2
  exit "$_bqa_rc"
fi

# If the agent exited non-zero AND did not leave a results file (common when
# the Anthropic stream times out), write a SKIPPED stub so phase closure can
# still read an artifact rather than blocking on a missing file. Quota
# exhaustion (exit 75) is handled differently by the outer run-phase.sh —
# propagate it unchanged so the outer retry loop triggers.
if [[ $_bqa_rc -ne 0 && $_bqa_rc -ne ${QUOTA_EXHAUSTED_EXIT_CODE:-75} ]]; then
  if [[ ! -f "$UI_TEST_RESULTS" ]]; then
    echo "[browser-qa] Claude CLI exited with code $_bqa_rc without producing results file." >&2
    echo "[browser-qa] Writing SKIPPED stub so closure is not blocked." >&2
    write_failed_artifact_stub "$PHASE" "ui-test-results" \
      "browser-qa-phase.sh Claude CLI invocation exited with code $_bqa_rc without flushing the results file. This commonly indicates a transient Anthropic streaming error (e.g., 'Stream idle timeout - partial response received') after a long live run. Re-run \`./scripts/automation/browser-qa-phase.sh $PHASE\` to retry."
  fi
  exit "$_bqa_rc"
fi

echo "[browser-qa] Done. Report: $UI_TEST_RESULTS"
