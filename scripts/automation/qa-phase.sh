#!/usr/bin/env bash
# qa-phase.sh — Run QA validation for a phase
# Usage: ./scripts/automation/qa-phase.sh phase-3
#
# Self-bootstrapping: if services are not running, this script can start
# them automatically using CHAIN_START_BACKEND_CMD / CHAIN_START_FRONTEND_CMD
# env vars, or the conventional scripts/start-backend.sh and scripts/start-frontend.sh.
# Logs for auto-started services are written via _qa_log_path (per-run
# CHAIN_TMPDIR when set, else /tmp): <dir>/qa-{backend,frontend}-<port>.log.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
# Telemetry (no-op unless GOAL_SESSION_DIR is set, i.e. goal-mode full depth):
# needed so the missing-evidence tripwire below can record its event.
source "$SCRIPT_DIR/lib/telemetry.sh"

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

# Resolve maintenance isolation FIRST — before frontend detection, before any
# start command is resolved, and before any service call. The previous ordering
# resolved services and called ensure_services_running, and only then consulted
# isolation; that is backwards. Under `set -e` it also meant relying on a
# deliberate non-zero refusal as control flow. The static path now bypasses
# service startup entirely, and ensure_services_running's refusal is left purely
# as a backstop for accidental callers.
MAINTENANCE_ISOLATION="no"
if apply_maintenance_isolation_from_spec "$SPEC"; then
  MAINTENANCE_ISOLATION="yes"
fi

# Detect if this phase has frontend (for Chrome MCP decision)
FRONTEND_PRESENT="no"
if [[ "$MAINTENANCE_ISOLATION" == "yes" ]]; then
  FRONTEND_PRESENT="no"   # contract: no browser/Chrome requirement is initialized
elif detect_frontend_in_plan "$PLAN_FILE"; then
  FRONTEND_PRESENT="yes"
fi

if [[ "$MAINTENANCE_ISOLATION" == "yes" ]]; then
  echo "[qa-phase] Running QA for: $PHASE (MAINTENANCE ISOLATION — static/no-service mode; app services prohibited by contract)"
else
  echo "[qa-phase] Running QA for: $PHASE (frontend: $FRONTEND_PRESENT)"
fi

# ── Service bootstrapping ─────────────────────────────────────────────────
QA_STARTED_PIDS=()

# _wait_for_url (shared, in lib/common.sh) is available if this script needs to
# poll a URL; it is not currently called here.

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
# When CHAIN_SHARED_SERVICES=true (run-phase.sh post-dev fanout), the caller
# owns service lifecycle — we MUST NOT install the EXIT trap or our finish
# would kill the shared app under the parallel browser-qa branch.
if [[ "${CHAIN_SHARED_SERVICES:-false}" != "true" ]]; then
  trap _cleanup_qa_services EXIT
fi

# Resolve start commands — use env vars if set, fall back to conventional scripts.
# Under maintenance isolation these stay EMPTY: the fallback to start-backend.sh /
# start-frontend.sh is never resolved into an executable command, so there is
# nothing for any later caller to run. This is the bypass, not a skipped call.
BACKEND_START_CMD=""
FRONTEND_START_CMD=""
if [[ "$MAINTENANCE_ISOLATION" != "yes" ]]; then
  BACKEND_START_CMD="${CHAIN_START_BACKEND_CMD:-}"
  FRONTEND_START_CMD="${CHAIN_START_FRONTEND_CMD:-}"

  if [[ -z "$BACKEND_START_CMD" ]] && [[ -f "$REPO_ROOT/scripts/start-backend.sh" ]]; then
    BACKEND_START_CMD="bash $REPO_ROOT/scripts/start-backend.sh"
  fi
  if [[ -z "$FRONTEND_START_CMD" ]] && [[ -f "$REPO_ROOT/scripts/start-frontend.sh" ]]; then
    FRONTEND_START_CMD="bash $REPO_ROOT/scripts/start-frontend.sh"
  fi
fi

# Derive URLs from port env vars (set by run-phase.sh for port isolation)
_BACKEND_PORT="${CHAIN_BACKEND_PORT:-8000}"
_FRONTEND_PORT="${CHAIN_FRONTEND_PORT:-3000}"
BACKEND_HEALTH_URL="${CHAIN_BACKEND_HEALTH_URL:-http://localhost:${_BACKEND_PORT}/health}"
FRONTEND_URL="${CHAIN_FRONTEND_URL:-http://localhost:${_FRONTEND_PORT}}"

# Export vars consumed by ensure_services_running (shared helper in common.sh).
# Using project-scoped log paths so parallel project runs don't clobber each other.
QA_BACKEND_LOG=$(_qa_log_path "qa-backend")
QA_FRONTEND_LOG=$(_qa_log_path "qa-frontend")
export QA_BACKEND_HEALTH_URL="$BACKEND_HEALTH_URL"
export QA_BACKEND_START_CMD="$BACKEND_START_CMD"
export QA_BACKEND_LOG
export QA_FRONTEND_URL="$FRONTEND_URL"
export QA_FRONTEND_START_CMD="$FRONTEND_START_CMD"
export QA_FRONTEND_LOG
export QA_FRONTEND_REQUIRED="$FRONTEND_PRESENT"

# Initial start — records PIDs in QA_STARTED_PIDS via the shared helper.
# Skip when CHAIN_SHARED_SERVICES=true; the caller already booted services.
# Under maintenance isolation the call is BYPASSED entirely rather than made and
# refused: relying on a deliberate non-zero return as control flow under `set -e`
# is fragile, and an attempted-then-refused boot would also misreport as
# "services unavailable" instead of "prohibited by contract".
if [[ "$MAINTENANCE_ISOLATION" == "yes" ]]; then
  export QA_BACKEND_UP="no"
  export QA_FRONTEND_UP="no"
  echo "[qa-phase] Service startup bypassed — maintenance isolation (prohibited by contract, not unavailable)."
elif [[ "${CHAIN_SHARED_SERVICES:-false}" != "true" ]]; then
  ensure_services_running
fi

# Build services context note for the agent prompt.
if [[ "$MAINTENANCE_ISOLATION" == "yes" ]]; then
  # Static/no-service QA. Full skepticism is still required — this withholds
  # application services, NOT scrutiny. The note must say the restriction is a
  # contract decision so the report cannot read as an accidental gap, and must
  # forbid fabricating the evidence those services would have produced.
  SERVICES_NOTE="
MAINTENANCE ISOLATION IS ACTIVE FOR THIS ITERATION — run QA in no-service (static) mode.

FORBIDDEN, by contract rather than by circumstance: starting the backend or frontend,
calling ensure_services_running, any browser/Chrome automation, and the deterministic
replay lane. No service is running and none may be started; the runner has deliberately
not booted any. Note that this project's backend boot warmup itself writes derived rows,
which is one reason the contract withholds it.

STILL REQUIRED — full QA depth, using what does not need a running app: read the code and
the diff; run the allowed file-scoped/unit tests; inspect persisted artifacts and reports;
run direct READ-ONLY database queries where the iteration spec authorizes them; and verify
mutation accounting after the developer's execution.

State plainly in your report that it ran under maintenance isolation and that app-service
and browser checks were prohibited by contract, not skipped by accident. Record those checks
as SKIPPED with that reason. Do NOT fabricate browser evidence, and do NOT mark a journey
PASS or FAIL from a lane that did not run."
else
SERVICES_NOTE="
Note: The QA runner manages backend (${BACKEND_HEALTH_URL}, log: ${QA_BACKEND_LOG})$(if [[ "$FRONTEND_PRESENT" == "yes" ]]; then echo " and frontend (${FRONTEND_URL}, log: ${QA_FRONTEND_LOG})"; fi) for this validation.
Services are restarted automatically if they die during quota-retry sleeps.
You do NOT need to start or stop them yourself."
fi

# If the backend never came up, hand the QA agent the real reason (dependency
# hint + captured start-up log tail set by ensure_services_running) so it records
# an actionable failure instead of a generic "backend unreachable".
if [[ "${QA_BACKEND_UP:-}" == "no" ]]; then
  _be_hint="$(_qa_dep_hint backend)"
  SERVICES_NOTE+=$'\n\nWARNING: the backend did NOT become healthy after retries.'
  [[ -n "$_be_hint" ]] && SERVICES_NOTE+=" Likely cause: $_be_hint"
  [[ -n "${QA_BACKEND_LOG_TAIL:-}" ]] && SERVICES_NOTE+=$'\nBackend start log tail:\n'"${QA_BACKEND_LOG_TAIL}"
fi

# Pre-retry hook — revive any services that died during a long quota sleep
# before claude attempts the next call. Hook runs in this shell (via eval),
# so it can reference ensure_services_running and the QA_* env vars set above.
# Under maintenance isolation the retry hook is NOT registered: a quota-retry
# sleep must not become a back door that boots services the contract forbids.
if [[ "$MAINTENANCE_ISOLATION" == "yes" ]]; then
  unset CHAIN_CLAUDE_PRE_RETRY_HOOK 2>/dev/null || true
else
  export CHAIN_CLAUDE_PRE_RETRY_HOOK="ensure_services_running"
fi

# ── Host-safety: pinned + headless + confined QA browser (see browser-qa-phase)
# The "qa" lane suffix keeps this lane off the browser-qa lane's profile lock —
# the two can run concurrently in the post-dev fanout.
ensure_qa_browser_env "qa"
strip_display_for_headless_qa
if [[ -f "$SCRIPT_DIR/host-guard/browser-confine.sh" ]]; then
  HOST_GUARD_ROOT="$REPO_ROOT" bash "$SCRIPT_DIR/host-guard/browser-confine.sh" || true
fi

# ── Run QA agent ──────────────────────────────────────────────────────────
cd "$REPO_ROOT"
record_agent_invocation_start qa
_agent_t0="$CHAIN_AGENT_START_EPOCH"
_agent_rc=0
claude_with_quota_retry -p "You are the qa agent operating in QA VALIDATION mode for phased development.

Phase: $PHASE
Phase spec: $SPEC
Review report: $REVIEW
Execution plan: $PLAN_FILE
Project template (relevant sections, pre-sliced):
\`\`\`\`
$(project_template_slice qa)
\`\`\`\`
Agent instructions: .claude/agents/qa.md  <-- read this first, follow MODE 2 instructions
(CLAUDE.md is already in your system prompt — do not Read it again.)

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
**Verdict:** FAIL" || _agent_rc=$?
record_agent_invocation_end qa "$_agent_t0" "$_agent_rc"
(( _agent_rc == 0 )) || exit "$_agent_rc"

# REL-11 missing-evidence tripwire: a nonzero dispatch already dies loudly
# above (explicit exit right after the telemetry end event). The silent failure mode is
# rc=0 with no report on disk (baseline bench-20260710-2117: every qa dispatch
# exited 0, reports/qa/ stayed empty). Banner + telemetry, never a gate.
QA_REPORT="$REPO_ROOT/reports/qa/${PHASE}-qa.md"
if [[ ! -f "$QA_REPORT" ]]; then
  warn_missing_evidence "qa" "$QA_REPORT"
fi

echo "[qa-phase] Done. Report: reports/qa/${PHASE}-qa.md"
