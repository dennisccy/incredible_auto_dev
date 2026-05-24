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

# ── Resolve per-project ports the SAME way the app binds them ────────────────
# scripts/dev.sh and scripts/start-frontend.sh bind the deterministic offset
# ports (3000+offset / 8000+offset, offset = hash($REPO_ROOT)) — NOT base
# :3000/:8000. This block used to hard-default to :8000/:3000, so the probe hit
# a dead base port, the FE-availability gate saw "no frontend," and every browser
# test SKIPPED. Use the canonical helper (do NOT re-implement the offset math —
# duplicate-and-drift produced the earlier :3692-vs-:3691 miss) so the probe port
# matches the bound port. Called BEFORE the stale-server kill below so that kill
# targets the right port, and the resolved values are exported so
# ensure_services_running / start-frontend.sh inherit the SAME port.
ensure_phase_ports

# Enforce the invariant "probe the port the app is ACTUALLY bound to". Two drift
# sources make the resolved CHAIN_*_PORT point at a dead port while the live app
# sits on the base offset port:
#   1. ensure_phase_ports derives via _find_free_port, which scans UPWARD past a
#      port that is already LISTENing — so a running app on :3691 pushes it to a
#      dead :3692.
#   2. The goal-mode caller may EXPORT a pre-derived CHAIN_FRONTEND_PORT that has
#      since drifted from where dev.sh bound the app (the historical :3692-vs-:3691
#      miss). ensure_phase_ports respects that exported value, so the drift sticks.
# dev.sh / start-frontend.sh bind the BASE offset port (3000+off / 8000+off)
# DIRECTLY. So the rule is independent of who set the candidate: if the resolved
# probe port does NOT answer 2xx/3xx but the base offset port DOES, the app is on
# the base — reconcile the probe there. (Cold start: neither serves yet → keep the
# resolved port and let ensure_services_running boot the app on it.)
_port_offset=$(_project_port_offset)
_base_fe=$((3000 + _port_offset))
_base_be=$((8000 + _port_offset))
if [[ "${CHAIN_FRONTEND_PORT}" != "$_base_fe" ]]; then
  _cur_fe_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${CHAIN_FRONTEND_PORT}" 2>/dev/null || true)
  if [[ ! "$_cur_fe_code" =~ ^[23] ]]; then
    _base_fe_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${_base_fe}" 2>/dev/null || true)
    if [[ "$_base_fe_code" =~ ^[23] ]]; then
      echo "[browser-qa] Resolved FE port :${CHAIN_FRONTEND_PORT} is dead but the app is live on base :${_base_fe} — reconciling probe to :${_base_fe}."
      export CHAIN_FRONTEND_PORT="$_base_fe"
    fi
  fi
fi
if [[ "${CHAIN_BACKEND_PORT}" != "$_base_be" ]]; then
  _cur_be_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${CHAIN_BACKEND_PORT}/health" 2>/dev/null || true)
  if [[ ! "$_cur_be_code" =~ ^[23] ]]; then
    _base_be_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${_base_be}/health" 2>/dev/null || true)
    if [[ "$_base_be_code" =~ ^[23] ]]; then
      echo "[browser-qa] Resolved BE port :${CHAIN_BACKEND_PORT} is dead but the backend is live on base :${_base_be} — reconciling probe to :${_base_be}."
      export CHAIN_BACKEND_PORT="$_base_be"
    fi
  fi
fi

# Derive URLs from the resolved port env vars
_BACKEND_PORT="${CHAIN_BACKEND_PORT}"
_FRONTEND_PORT="${CHAIN_FRONTEND_PORT}"
BACKEND_HEALTH_URL="${CHAIN_BACKEND_HEALTH_URL:-http://localhost:${_BACKEND_PORT}/health}"
FRONTEND_URL="${CHAIN_FRONTEND_URL:-http://localhost:${_FRONTEND_PORT}}"
echo "[browser-qa] Resolved ports: frontend=${FRONTEND_URL} backend=${BACKEND_HEALTH_URL}"

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

# Re-probe the frontend across a cold-start budget rather than deciding once.
# A dev frontend (Vite/Next) can take >10s to compile its first request; a single
# curl right after ensure_services_running can race a still-booting FE and wrongly
# mark every test SKIPPED. _wait_for_url retries every 3s up to the budget before
# giving up — a slow boot is no longer misread as "frontend not available."
if _wait_for_url "$FRONTEND_URL" "frontend" 90; then
  FRONTEND_AVAILABLE="yes"
else
  FRONTEND_AVAILABLE="no"
  echo "[browser-qa] Frontend not available after re-probe — browser tests will be marked SKIPPED."
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
