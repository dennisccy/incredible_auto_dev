#!/usr/bin/env bash
# run-phase.sh — Full phase runner: plan -> test-plan -> dev -> review -> UI impact ->
#                UI test design -> browser QA -> QA -> UX regression -> audit -> closure ->
#                html-summary -> finalize
# Usage: ./scripts/automation/run-phase.sh phase-3 [--auto-release] [--reset] [--no-finalize]
#
# Flags:
#   --auto-release   Automatically finalize (branch + commit + PR) when all checks pass.
#                    Requires gh CLI authenticated: gh auth login
#   --reset          Ignore existing checkpoints and re-run all steps from scratch.
#   --no-finalize    Skip the finalize hint at the end of a successful run AND skip
#                    --auto-release if it was passed alongside. Used by run-goal.sh
#                    to dispatch a full-mode iteration without committing/creating a PR
#                    for each iteration; release-manager runs once at goal-session end.
#
# Post-dev parallel fanout: after Step 3, when the phase has a frontend, Branch A
# (ui-impact → ui-test-design → browser-qa → demo) runs concurrently with
# Branch B (qa-validate) under a single service boot. Backend-only phases and
# resume runs where one of those steps already completed fall through to the
# sequential blocks. This is the default; there is no flag.
#
# Resume behavior:
#   If a run was interrupted, rerunning this script resumes from the last
#   completed step using runs/<phase>/status.json as the source of truth.
#   Steps already completed are skipped.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/parallel.sh"

# Pull --cli (and --force-cli) out of the args BEFORE the existing parse loop,
# so the loop below sees only its known flags. CHAIN_CLI defaults to claude.
extract_cli_arg "$@" || exit $?
if [[ ${#CHAIN_CLI_REMAINING_ARGS[@]} -gt 0 ]]; then
  set -- "${CHAIN_CLI_REMAINING_ARGS[@]}"
else
  set --
fi

PHASE="${1:-}"
AUTO_RELEASE=false
FORCE_RESET=false
NO_FINALIZE=false

# Parse flags (allow flag in any position). Unknown long flags hard-error;
# positional args (phase name) and short forms fall through.
for arg in "$@"; do
  case "$arg" in
    --auto-release) AUTO_RELEASE=true ;;
    --reset)        FORCE_RESET=true ;;
    --no-finalize)  NO_FINALIZE=true ;;
    --*)            echo "Error: unknown flag '$arg'" >&2; exit 2 ;;
  esac
done

# --no-finalize suppresses --auto-release for this run (the goal-mode outer loop
# handles release once at session end, not per iteration).
if [[ "$NO_FINALIZE" == "true" ]]; then
  AUTO_RELEASE=false
fi

require_phase_arg "$PHASE"
require_cli
ensure_cli_assets_synced "$CHAIN_CLI"

# ── Auto-assign deterministic per-project ports ──────────────────────────────
# Helpers live in lib/common.sh (already sourced). Explicit CHAIN_*_PORT wins.
ensure_phase_ports

SPEC=$(phase_spec_path "$PHASE")
if [[ -z "$SPEC" ]]; then
  echo "Error: No spec found for '$PHASE' in docs/phases/" >&2
  exit 1
fi

REVIEW_REPORT="$REPO_ROOT/reports/reviews/${PHASE}-review.md"
QA_REPORT="$REPO_ROOT/reports/qa/${PHASE}-qa.md"
PLAN_FILE="$REPO_ROOT/runs/${PHASE}/plan.md"
TEST_PLAN="$REPO_ROOT/reports/qa/${PHASE}-test-plan.md"
AUDIT_REPORT="$REPO_ROOT/docs/handoffs/${PHASE}-audit.md"
IMPL_SUMMARY="$REPO_ROOT/reports/phase-${PHASE}-implementation-summary.md"
USER_VISIBLE="$REPO_ROOT/reports/phase-${PHASE}-user-visible-changes.md"
UI_SURFACE_MAP="$REPO_ROOT/reports/phase-${PHASE}-ui-surface-map.md"
UI_TEST_PLAN="$REPO_ROOT/reports/phase-${PHASE}-ui-test-plan.md"
UI_TEST_RESULTS="$REPO_ROOT/reports/phase-${PHASE}-ui-test-results.md"
WHAT_TO_CLICK="$REPO_ROOT/reports/phase-${PHASE}-what-to-click.md"
UX_REGRESSION="$REPO_ROOT/reports/phase-${PHASE}-ux-regression.md"
CLOSURE_VERDICT="$REPO_ROOT/reports/phase-${PHASE}-closure-verdict.md"
MAX_RETRIES=3
MAX_AUDIT_RETRIES=3

log()  { echo "[run-phase] $*"; }

# Invoke the iteration-summarizer agent. The agent reads existing artifacts
# and writes reports/phase-<phase>-iteration-summary.md. Non-blocking — if
# the agent call fails, the renderer below still runs and falls back to a
# "no summary available" placeholder.
_run_iteration_summarizer() {
  local agent_file="$REPO_ROOT/.claude/agents/iteration-summarizer.md"
  local summary_md="$REPO_ROOT/reports/phase-${PHASE}-iteration-summary.md"
  [[ -f "$agent_file" ]] || { log "  Warning: iteration-summarizer agent not found, skipping"; return 0; }
  mkdir -p "$REPO_ROOT/reports"

  # Pre-trim evaluator-log.md (goal mode only) so token usage stays flat.
  local eval_log_inline=""
  if [[ "$PHASE" =~ ^goal-(.+)-iter-[0-9]+$ ]]; then
    local _sid="${BASH_REMATCH[1]}"
    local _log="$REPO_ROOT/runs/goal-session-${_sid}/state/evaluator-log.md"
    [[ -f "$_log" ]] && eval_log_inline=$(tail -n 300 "$_log")
  fi

  cd "$REPO_ROOT"
  export CHAIN_CURRENT_AGENT=iteration-summarizer
  claude_with_quota_retry -p "You are the iteration-summarizer agent.

Phase id: $PHASE
Output path: $summary_md
Agent instructions: .claude/agents/iteration-summarizer.md  <-- read this first
Template: templates/iteration-summary.md  <-- exact section structure your output must follow
(CLAUDE.md is already in your system prompt -- do not Read it again.)

Apply the TOKEN AND QUESTIONING POLICY from .claude/core.md strictly.

Read every relevant input listed in your agent instructions. Files that don't
exist should be silently skipped -- do not warn, do not ask. Use what is present.
The dispatch wrapper has pre-trimmed evaluator-log.md (last 300 lines below);
use the inline content, do not read the file directly.

Recent evaluator log entries (last 300 lines, pre-trimmed):
---
${eval_log_inline:-(none — phase mode or log not present)}
---

Write the iteration summary to: $summary_md

Follow the section structure in templates/iteration-summary.md EXACTLY -- the
HTML renderer keys off the section headings. The verdict line must match the
form '**Verdict:** VALUE' where VALUE is one of: GOAL_ACHIEVED, CONTINUE,
ESCALATE, REGRESSION, STALLED, PASS, FAIL, IN-PROGRESS.

When finished, STOP." \
    || log "  Warning: iteration-summarizer call failed (non-blocking)"
}

# Render the human-readable HTML summary for this iteration. Always non-blocking
# — failures are logged but do not break the pipeline. Called from the success
# path (Step 10.5) AND from fail() so even failed iterations get a viewable
# summary of whatever artifacts exist.
_render_summary_html() {
  local renderer="$SCRIPT_DIR/lib/render_iteration_summary.py"
  [[ -f "$renderer" ]] || return 0
  python3 "$renderer" iteration "$PHASE" --repo-root="$REPO_ROOT" 2>&1 \
    | sed 's/^/[run-phase] /' || log "  Warning: HTML summary render failed (non-blocking)"
}

# Boot backend/frontend services once for the post-dev fanout, then export
# CHAIN_SHARED_SERVICES=true so each underlying step script (browser-qa,
# qa-validate, demo) skips its own boot AND its own EXIT-trap teardown.
# The caller is responsible for `kill_phase_servers` AFTER the fanout completes.
# Mirrors the env contract `browser-qa-phase.sh` already uses for its own boot.
_boot_shared_services() {
  local _be_port="${CHAIN_BACKEND_PORT:-8000}"
  local _fe_port="${CHAIN_FRONTEND_PORT:-3000}"
  local _be_health="${CHAIN_BACKEND_HEALTH_URL:-http://localhost:${_be_port}/health}"
  local _fe_url="${CHAIN_FRONTEND_URL:-http://localhost:${_fe_port}}"
  local _be_cmd="${CHAIN_START_BACKEND_CMD:-}"
  local _fe_cmd="${CHAIN_START_FRONTEND_CMD:-}"
  if [[ -z "$_be_cmd" && -f "$REPO_ROOT/scripts/start-backend.sh" ]]; then
    _be_cmd="bash $REPO_ROOT/scripts/start-backend.sh"
  fi
  if [[ -z "$_fe_cmd" && -f "$REPO_ROOT/scripts/start-frontend.sh" ]]; then
    _fe_cmd="bash $REPO_ROOT/scripts/start-frontend.sh"
  fi
  export QA_BACKEND_HEALTH_URL="$_be_health"
  export QA_BACKEND_START_CMD="$_be_cmd"
  export QA_BACKEND_LOG; QA_BACKEND_LOG=$(_qa_log_path "fanout-backend")
  export QA_FRONTEND_URL="$_fe_url"
  export QA_FRONTEND_START_CMD="$_fe_cmd"
  export QA_FRONTEND_LOG; QA_FRONTEND_LOG=$(_qa_log_path "fanout-frontend")
  export QA_FRONTEND_REQUIRED="yes"
  ensure_services_running
  export CHAIN_SHARED_SERVICES=true
}

# Run Branch A (UI chain: ui-impact → ui-test-design → browser-qa → demo) as a
# single sequential function suitable for backgrounding. Each underlying script
# runs as a child process; its exit code is captured. A non-zero exit aborts
# the chain so the caller sees the first real failure.
_branch_a_ui_chain() {
  local _rc=0
  bash "$SCRIPT_DIR/ui-impact-phase.sh"      "$PHASE" || { _rc=$?; echo "[branch-A] ui-impact-phase.sh exit $_rc — aborting chain"; return "$_rc"; }
  bash "$SCRIPT_DIR/ui-test-design-phase.sh" "$PHASE" || { _rc=$?; echo "[branch-A] ui-test-design-phase.sh exit $_rc — aborting chain"; return "$_rc"; }
  bash "$SCRIPT_DIR/browser-qa-phase.sh"     "$PHASE" || { _rc=$?; echo "[branch-A] browser-qa-phase.sh exit $_rc — aborting chain"; return "$_rc"; }
  # Demo is showcase, non-gating — never abort the chain on its exit code.
  bash "$SCRIPT_DIR/demo-phase.sh"           "$PHASE" || echo "[branch-A] demo-phase.sh exit $? — continuing (showcase, non-gating)"
  return 0
}

# Post-dev parallel fanout. Replaces the sequential Step 4 → 5 → 6 → 6.5 → 7
# block with two concurrent branches that share a single boot of the
# backend/frontend services. Step 8 (ux-regression) runs sequentially after
# both branches succeed; the caller then tears down services.
#
# Returns 0 on success, 75 on quota exhaustion (caller's _run_step retries),
# 130/137/143 on signal (caller aborts), or another non-zero code if at least
# one branch soft-failed (caller treats as non-fatal per existing browser-QA
# pattern — Step 4–7 already follow "warn and continue" semantics today).
_run_post_dev_fanout() {
  log "Step 4-7/11 -- Post-dev parallel fanout..."
  _boot_shared_services
  local _rc=0
  parallel_run \
    Branch-UI _branch_a_ui_chain \
    -- \
    Branch-QA bash "$SCRIPT_DIR/qa-phase.sh" "$PHASE" \
    || _rc=$?
  # Always unset the shared-services flag so subsequent steps (ux-regression
  # below, plus anything in fail()) follow today's per-script boot semantics.
  unset CHAIN_SHARED_SERVICES
  return "$_rc"
}

fail() {
  local msg="$1"
  local step="${2:-failed}"
  log "FAILED: $msg" >&2
  update_status "$PHASE" "blocked" "$step"
  _run_iteration_summarizer
  _render_summary_html
  exit 1
}

# Signal-aware abort — invoked by `trap` for SIGINT/SIGTERM AND by retry-loop
# guards when a child step exits with 130/137/143. Exits without advancing the
# checkpoint, so the next resume re-runs the in-flight step from scratch.
# Without this, the warn-and-advance retry pattern (intended for transient
# agent errors) wrongly treats a signal kill as "step done" and the resume
# skips an unrun step, leaving SKIPPED stub artifacts that closure-check
# flags. See .claude/anti-patterns.md #20.
_is_signal_exit() {
  local rc="$1"
  [[ $rc -eq 130 || $rc -eq 137 || $rc -eq 143 ]]
}

_run_phase_aborted() {
  echo "" >&2
  log "Interrupted by signal — aborting WITHOUT advancing checkpoint."
  log "  Current step in runs/$PHASE/status.json is preserved; resume will re-run the in-flight step."
  exit 130
}
trap _run_phase_aborted INT TERM

# ── Quota-aware step runner ──────────────────────────────────────────────────
# Runs a phase script and handles quota exhaustion (exit 75) by sleeping until
# the quota resets, then signaling the caller to retry.
#   Returns: 0 on success, 75 if quota was hit (caller should retry), other on failure
_run_step() {
  local script="$1"; shift
  local rc=0
  bash "$script" "$@" || rc=$?
  if [[ $rc -eq ${QUOTA_EXHAUSTED_EXIT_CODE:-75} ]]; then
    log "  Quota exhaustion detected (exit 75). Waiting for reset..."
    update_status "$PHASE" "blocked" "quota_blocked"
    local remaining wake_epoch
    if remaining=$(_quota_check_sentinel 2>/dev/null); then
      wake_epoch=$(( $(date +%s) + remaining ))
      log "  Sentinel: sleeping ${remaining}s until quota resets..."
      _sleep_until_epoch "$wake_epoch"
    else
      local fallback="${CHAIN_CLAUDE_FALLBACK_SLEEP_SECONDS:-3600}"
      wake_epoch=$(( $(date +%s) + fallback ))
      log "  No sentinel — fallback sleep ${fallback}s..."
      _sleep_until_epoch "$wake_epoch"
    fi
    _quota_clear_sentinel 2>/dev/null || true
    log "  Quota sleep complete. Resuming."
    return 75
  fi
  return $rc
}

log "========================================"
log "  Phase: $PHASE"
log "  Spec:  $SPEC"
log "  Auto-release: $AUTO_RELEASE"
log "  Backend port:  $CHAIN_BACKEND_PORT"
log "  Frontend port: $CHAIN_FRONTEND_PORT"
log "========================================"
echo ""

# If auto-release requested, check gh auth status now (informational, not fatal)
if [[ "$AUTO_RELEASE" == "true" ]]; then
  if check_gh_auth; then
    log "  gh auth: OK — full release (branch + commit + push + PR)"
  else
    log "  gh auth: NOT configured — will commit only; PR creation will be skipped"
    log "  To enable PR creation: gh auth login"
  fi
fi

init_run_dir "$PHASE"

# Auto-enable replay/time-travel trace capture unless the user opts out.
# Each successful claude invocation appends a record to runs/<phase>/trace/trace.jsonl
# (see lib/quota-retry.sh::_trace_record_invocation and lib/replay_trace.py).
if [[ "${CHAIN_DISABLE_TRACE:-false}" != "true" && -z "${CHAIN_TRACE_DIR:-}" ]]; then
  mkdir -p "$REPO_ROOT/runs/$PHASE/trace"
  export CHAIN_TRACE_DIR="$REPO_ROOT/runs/$PHASE/trace"
fi

# ── Resume detection ────────────────────────────────────────────────────────
if [[ "$FORCE_RESET" == "true" ]]; then
  log "  --reset: clearing checkpoint, starting fresh"
  update_status "$PHASE" "in_progress" "starting"
  # Clear all phase artifact files so a step that fails (quota, timeout,
  # crash) cannot be falsely reported as PASS by a verdict-passes check
  # against a stale file from a prior run. Includes summary.json so the
  # is_finalized check sees a clean slate.
  rm -f "$PLAN_FILE" "$TEST_PLAN" \
        "$REVIEW_REPORT" "$QA_REPORT" "$AUDIT_REPORT" \
        "$IMPL_SUMMARY" "$USER_VISIBLE" "$UI_SURFACE_MAP" \
        "$UI_TEST_PLAN" "$UI_TEST_RESULTS" "$WHAT_TO_CLICK" \
        "$UX_REGRESSION" "$CLOSURE_VERDICT" \
        "$REPO_ROOT/runs/$PHASE/summary.json"
  log "  --reset: cleared phase artifact files"
fi

if is_finalized "$PHASE" && [[ "$FORCE_RESET" != "true" ]]; then
  log "Phase $PHASE is already finalized. Use --reset to re-run."
  exit 0
fi

CURRENT_STEP=$(get_current_step "$PHASE")
SKIP_PLAN=false
SKIP_TEST_PLAN=false
SKIP_DEV_REVIEW=false
SKIP_FIRST_DEV=false
SKIP_UI_IMPACT=false
SKIP_UI_TEST_DESIGN=false
SKIP_BROWSER_QA=false
SKIP_QA=false
SKIP_UX_REGRESSION=false
SKIP_AUDIT=false
SKIP_CLOSURE=false

case "$CURRENT_STEP" in
  closure_passed)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
    SKIP_UI_IMPACT=true; SKIP_UI_TEST_DESIGN=true; SKIP_BROWSER_QA=true
    SKIP_QA=true; SKIP_UX_REGRESSION=true; SKIP_AUDIT=true; SKIP_CLOSURE=true ;;
  closure_failed)
    # Closure failed — re-run UI pipeline (steps 4-6) and closure; skip the rest
    # UI artifacts are the most common cause of closure failures
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
    SKIP_QA=true; SKIP_UX_REGRESSION=true; SKIP_AUDIT=true ;;
  audit_passed)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
    SKIP_UI_IMPACT=true; SKIP_UI_TEST_DESIGN=true; SKIP_BROWSER_QA=true
    SKIP_QA=true; SKIP_UX_REGRESSION=true; SKIP_AUDIT=true ;;
  audit_failed|audit_qa_failed)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
    SKIP_UI_IMPACT=true; SKIP_UI_TEST_DESIGN=true; SKIP_BROWSER_QA=true
    SKIP_QA=true; SKIP_UX_REGRESSION=true ;;
  ux_regression_complete)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
    SKIP_UI_IMPACT=true; SKIP_UI_TEST_DESIGN=true; SKIP_BROWSER_QA=true
    SKIP_QA=true; SKIP_UX_REGRESSION=true ;;
  qa_passed|qa_complete)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
    SKIP_UI_IMPACT=true; SKIP_UI_TEST_DESIGN=true; SKIP_BROWSER_QA=true
    SKIP_QA=true ;;
  qa_failed)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
    SKIP_UI_IMPACT=true; SKIP_UI_TEST_DESIGN=true; SKIP_BROWSER_QA=true ;;
  browser_qa_complete)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
    SKIP_UI_IMPACT=true; SKIP_UI_TEST_DESIGN=true; SKIP_BROWSER_QA=true ;;
  ui_test_designed)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
    SKIP_UI_IMPACT=true; SKIP_UI_TEST_DESIGN=true ;;
  ui_impact_complete)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
    SKIP_UI_IMPACT=true ;;
  review_passed)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true ;;
  review_failed)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true ;;
  dev_complete_attempt_*)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true
    if verdict_passes "$REVIEW_REPORT"; then
      SKIP_DEV_REVIEW=true
      update_status "$PHASE" "in_progress" "review_passed"
    else
      SKIP_FIRST_DEV=true
    fi
    ;;
  test_plan_generated)
    SKIP_PLAN=true; SKIP_TEST_PLAN=true ;;
  planned)
    SKIP_PLAN=true ;;
  quota_blocked|failed)
    # quota_blocked: process was killed mid-quota-wait — infer from artifacts.
    # failed: legacy generic failure — infer completed stages from existing artifacts.
    if closure_verdict_passes "$CLOSURE_VERDICT"; then
      SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
      SKIP_UI_IMPACT=true; SKIP_UI_TEST_DESIGN=true; SKIP_BROWSER_QA=true
      SKIP_QA=true; SKIP_UX_REGRESSION=true; SKIP_AUDIT=true; SKIP_CLOSURE=true
    elif verdict_passes "$AUDIT_REPORT"; then
      SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
      SKIP_UI_IMPACT=true; SKIP_UI_TEST_DESIGN=true; SKIP_BROWSER_QA=true
      SKIP_QA=true; SKIP_UX_REGRESSION=true; SKIP_AUDIT=true
    elif verdict_passes "$QA_REPORT"; then
      SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
      SKIP_UI_IMPACT=true; SKIP_UI_TEST_DESIGN=true; SKIP_BROWSER_QA=true
      SKIP_QA=true
    elif verdict_passes "$REVIEW_REPORT"; then
      SKIP_PLAN=true; SKIP_TEST_PLAN=true; SKIP_DEV_REVIEW=true
    elif [[ -f "$PLAN_FILE" ]]; then
      SKIP_PLAN=true; SKIP_TEST_PLAN=true
    fi
    ;;
esac

if [[ "$CURRENT_STEP" != "" && "$CURRENT_STEP" != "init" && "$CURRENT_STEP" != "starting" ]]; then
  log "RESUMING from checkpoint: $CURRENT_STEP"
  [[ "$SKIP_PLAN" == "true" ]]           && log "  Skipping: plan (already completed)"
  [[ "$SKIP_TEST_PLAN" == "true" ]]      && log "  Skipping: test plan (already completed)"
  [[ "$SKIP_DEV_REVIEW" == "true" ]]     && log "  Skipping: dev+review (already completed)"
  [[ "$SKIP_FIRST_DEV" == "true" ]]      && log "  Skipping: first dev pass (dev already completed, resuming from review)"
  [[ "$SKIP_UI_IMPACT" == "true" ]]      && log "  Skipping: UI impact analysis (already completed)"
  [[ "$SKIP_UI_TEST_DESIGN" == "true" ]] && log "  Skipping: UI test design (already completed)"
  [[ "$SKIP_BROWSER_QA" == "true" ]]     && log "  Skipping: browser QA (already completed)"
  [[ "$SKIP_QA" == "true" ]]             && log "  Skipping: QA (already completed)"
  [[ "$SKIP_UX_REGRESSION" == "true" ]]  && log "  Skipping: UX regression review (already completed)"
  [[ "$SKIP_AUDIT" == "true" ]]          && log "  Skipping: audit (already completed)"
  [[ "$SKIP_CLOSURE" == "true" ]]        && log "  Skipping: closure check (already completed)"
  echo ""
else
  update_status "$PHASE" "in_progress" "starting"
fi

# Detect if this phase has frontend (needed to decide which steps to skip)
FRONTEND_PRESENT="no"
if detect_frontend_in_plan "$PLAN_FILE"; then
  FRONTEND_PRESENT="yes"
fi

# ── Step 1/11: Orchestrator creates execution plan ──────────────────────────
if [[ "$SKIP_PLAN" == "false" ]]; then
  log "Step 1/11 -- Orchestrator: creating execution plan..."

  cd "$REPO_ROOT"
  export CHAIN_CURRENT_AGENT=orchestrator
  claude_with_quota_retry -p "You are acting as the orchestrator for phased development.

Phase: $PHASE
Phase spec: $SPEC
Agent instructions: .claude/agents/orchestrator.md  <-- read this first
(CLAUDE.md is already in your system prompt — do not Read it again.)

Apply the questioning policy from .claude/core.md.
Ask necessary questions, but batch them upfront and avoid follow-up cascades.

Before writing the plan, study the project context:
1. If docs/goal.md exists, read it — understand the project vision, success criteria, and key capabilities
2. If docs/architecture/*.md exist, read them — understand what has already been built
3. Read any prior phase handoffs in docs/handoffs/ and reports/phase-*-implementation-summary.md
4. Ensure your plan:
   - Advances the project toward its goals (docs/goal.md)
   - Builds on existing architecture without duplicating prior work
   - Flags if the phase spec contradicts or drifts from the project goal

Do NOT read .claude/architecture/*.md — those are framework reference docs, not project state.

Write a concise execution plan to: $PLAN_FILE

The plan must include these sections:
1. What to Build (bullet list)
2. Agents Required: backend-data (yes/no), frontend-ux (yes/no)
3. Frontend Present: yes/no  <-- QA agent uses this to decide browser checks
   CRITICAL FORMAT: Write this as a plain inline line "Frontend Present: yes" or "Frontend Present: no"
   Do NOT use a markdown heading (## Frontend Present) with the value on the next line.
4. Files to Create/Modify (expected list)
5. UI Evolution section (required if Frontend Present: yes):
   - New user-facing capability
   - New information displayed
   - New user actions
   - UI surface changes
   - Navigation changes
6. Key Test Scenarios

Keep it concise -- 1-2 pages max. Write the plan and STOP."

  if [[ ! -f "$PLAN_FILE" ]]; then
    mkdir -p "$(dirname "$PLAN_FILE")"
    printf "# %s Execution Plan\n\nFrontend Present: no\n\nNote: orchestrator did not write plan file.\n" "$PHASE" > "$PLAN_FILE"
    log "  Warning: orchestrator did not write plan file; created fallback."
  fi

  # Re-detect frontend after plan is written
  if detect_frontend_in_plan "$PLAN_FILE"; then
    FRONTEND_PRESENT="yes"
  fi

  update_status "$PHASE" "in_progress" "planned"
  log "  Plan: $PLAN_FILE"
  log "  Frontend present: $FRONTEND_PRESENT"
else
  log "Step 1/11 -- Plan: skipped (checkpoint: $CURRENT_STEP)"
  # Re-detect from existing plan
  if detect_frontend_in_plan "$PLAN_FILE"; then
    FRONTEND_PRESENT="yes"
  fi
fi
echo ""

# ── Step 2/11: Generate functional test plan ────────────────────────────────
if [[ "$SKIP_TEST_PLAN" == "false" ]]; then
  log "Step 2/11 -- Generating functional test plan..."
  bash "$SCRIPT_DIR/generate-test-plan.sh" "$PHASE" \
    && log "  Test plan: $TEST_PLAN" \
    || log "  Warning: test plan generation failed -- QA will run standard checks only"
  update_status "$PHASE" "in_progress" "test_plan_generated"
else
  log "Step 2/11 -- Test plan: skipped (checkpoint: $CURRENT_STEP)"
fi
echo ""

# ── Step 3/11: Dev + Review loop ─────────────────────────────────────────────
if [[ "$SKIP_DEV_REVIEW" == "false" ]]; then
  log "Step 3/11 -- Dev + Review loop (max $MAX_RETRIES attempts)..."
  ATTEMPT=0

  while true; do
    ATTEMPT=$((ATTEMPT + 1))

    if [[ "$SKIP_FIRST_DEV" == "true" && $ATTEMPT -eq 1 ]]; then
      log "  [attempt $ATTEMPT/$MAX_RETRIES] Skipping dev (already completed), running reviewer..."
    else
      log "  [attempt $ATTEMPT/$MAX_RETRIES] Running dev agent..."
      dev_rc=0
      _run_step "$SCRIPT_DIR/dev-phase.sh" "$PHASE" || dev_rc=$?
      if [[ $dev_rc -eq 75 ]]; then
        ATTEMPT=$((ATTEMPT - 1))  # don't count quota failures as attempts
        continue
      fi
      if _is_signal_exit "$dev_rc"; then
        log "  Step 3 (dev) interrupted by signal (exit $dev_rc) — aborting."
        exit "$dev_rc"
      fi
      [[ $dev_rc -ne 0 ]] && log "  Warning: dev-phase.sh exited with error (attempt $ATTEMPT) -- continuing to review"
      update_status "$PHASE" "in_progress" "dev_complete_attempt_${ATTEMPT}"
    fi

    log "  [attempt $ATTEMPT/$MAX_RETRIES] Running reviewer..."
    # Clear stale verdict so a script crash before write cannot be masked
    # by the previous attempt's PASS verdict.
    rm -f "$REVIEW_REPORT"
    rev_rc=0
    _run_step "$SCRIPT_DIR/review-phase.sh" "$PHASE" || rev_rc=$?
    if [[ $rev_rc -eq 75 ]]; then
      ATTEMPT=$((ATTEMPT - 1))
      continue
    fi
    if _is_signal_exit "$rev_rc"; then
      log "  Step 3 (review) interrupted by signal (exit $rev_rc) — aborting."
      exit "$rev_rc"
    fi
    [[ $rev_rc -ne 0 ]] && log "  Warning: review-phase.sh exited with error (attempt $ATTEMPT) -- checking verdict"

    if verdict_passes "$REVIEW_REPORT"; then
      log "  Review: PASS"
      break
    fi

    if [[ $ATTEMPT -ge $MAX_RETRIES ]]; then
      fail "Review failed after $MAX_RETRIES attempts. See: $REVIEW_REPORT" "review_failed"
    fi

    log "  Review: FAIL (attempt $ATTEMPT) -- looping back to dev..."
  done

  update_status "$PHASE" "in_progress" "review_passed"
else
  log "Step 3/11 -- Dev + Review: skipped (checkpoint: $CURRENT_STEP)"
fi
echo ""

# ── Step 4-7/11: Parallel post-dev fanout ───────────────────────────────────
# When the phase has a frontend AND none of Steps 4-7 are already SKIP'd (resume),
# run the safe pairs (Branch A = ui-impact → ui-test-design → browser-qa → demo;
# Branch B = qa-validate) concurrently with shared services. After the fanout,
# flip the SKIP_ flags for the steps that completed so the existing sequential
# blocks below become no-ops. Step 7's flag is only set if QA passed — otherwise
# we let the existing retry loop handle the fix path.
# When the gating conditions fail (backend-only phase, or resume after one of
# these steps), this block is skipped and the sequential blocks below run.
if [[ "$FRONTEND_PRESENT" == "yes" \
   && "$SKIP_UI_IMPACT" == "false" \
   && "$SKIP_UI_TEST_DESIGN" == "false" \
   && "$SKIP_BROWSER_QA" == "false" \
   && "$SKIP_QA" == "false" ]]; then
  fanout_rc=0
  _run_post_dev_fanout || fanout_rc=$?
  if _is_signal_exit "$fanout_rc"; then
    log "  Fanout (Step 4-7/11) interrupted by signal (exit $fanout_rc) — aborting; resume will re-run."
    exit "$fanout_rc"
  fi
  if [[ $fanout_rc -eq 75 ]]; then
    log "  Fanout (Step 4-7/11) hit quota (exit 75) — outer loop will handle."
    exit 75
  fi
  if [[ $fanout_rc -ne 0 ]]; then
    log "  Warning: post-dev fanout exited $fanout_rc — sequential retry will pick up any failed step"
  fi
  # The UI chain steps (4, 5, 6, 6.5) are always idempotent and write their
  # artifacts (or N/A stubs) regardless — mark them complete unconditionally.
  SKIP_UI_IMPACT=true
  SKIP_UI_TEST_DESIGN=true
  SKIP_BROWSER_QA=true
  update_status "$PHASE" "in_progress" "post_dev_parallel_complete"
  # Step 7 (QA): only skip the existing retry loop if QA passed in the fanout.
  # Otherwise leave SKIP_QA=false so the sequential retry path runs as today.
  if [[ -f "$QA_REPORT" ]] && verdict_passes "$QA_REPORT"; then
    SKIP_QA=true
    log "  Post-dev fanout complete — QA passed in fanout; Step 7 retry loop skipped."
  else
    log "  Post-dev fanout complete — QA did not pass; Step 7 retry loop will run."
  fi
  echo ""
fi

# ── Step 4/11: UI Impact Analysis ────────────────────────────────────────────
if [[ "$SKIP_UI_IMPACT" == "false" ]]; then
  log "Step 4/11 -- UI Impact Analysis..."
  ui_q=0
  while true; do
    ui_rc=0
    _run_step "$SCRIPT_DIR/ui-impact-phase.sh" "$PHASE" || ui_rc=$?
    if [[ $ui_rc -eq 75 && $ui_q -lt 2 ]]; then ui_q=$((ui_q+1)); continue; fi
    if _is_signal_exit "$ui_rc"; then
      log "  Step 4 (ui-impact) interrupted by signal (exit $ui_rc) — aborting."
      exit "$ui_rc"
    fi
    [[ $ui_rc -ne 0 && $ui_rc -ne 75 ]] && log "  Warning: ui-impact-phase.sh exited with error -- continuing"
    break
  done
  update_status "$PHASE" "in_progress" "ui_impact_complete"
  log "  User-visible changes: $USER_VISIBLE"
  log "  UI surface map:       $UI_SURFACE_MAP"
else
  log "Step 4/11 -- UI Impact Analysis: skipped (checkpoint: $CURRENT_STEP)"
fi
echo ""

# ── Step 5/11: UI Test Design ─────────────────────────────────────────────────
if [[ "$SKIP_UI_TEST_DESIGN" == "false" ]]; then
  if [[ "$FRONTEND_PRESENT" == "yes" ]]; then
    log "Step 5/11 -- UI Test Design..."
    utd_q=0
    while true; do
      utd_rc=0
      _run_step "$SCRIPT_DIR/ui-test-design-phase.sh" "$PHASE" || utd_rc=$?
      if [[ $utd_rc -eq 75 && $utd_q -lt 2 ]]; then utd_q=$((utd_q+1)); continue; fi
      if _is_signal_exit "$utd_rc"; then
        log "  Step 5 (ui-test-design) interrupted by signal (exit $utd_rc) — aborting; resume will re-run this step."
        exit "$utd_rc"
      fi
      [[ $utd_rc -ne 0 && $utd_rc -ne 75 ]] && log "  Warning: ui-test-design-phase.sh exited with error -- continuing"
      break
    done
    log "  UI test plan:  $UI_TEST_PLAN"
    log "  What to click: $WHAT_TO_CLICK"
  else
    log "Step 5/11 -- UI Test Design: skipped (backend-only phase) -- writing N/A stubs."
    write_na_ui_artifacts "$PHASE" "ui-test-plan" "what-to-click"
  fi
  update_status "$PHASE" "in_progress" "ui_test_designed"
else
  log "Step 5/11 -- UI Test Design: skipped (checkpoint: $CURRENT_STEP)"
fi
echo ""

# ── Step 6/11: Browser QA ─────────────────────────────────────────────────────
if [[ "$SKIP_BROWSER_QA" == "false" ]]; then
  if [[ "$FRONTEND_PRESENT" == "yes" ]]; then
    log "Step 6/11 -- Browser QA..."
    # Clear stale results so a script crash before write doesn't leave
    # an old run's results pretending to be this run's.
    rm -f "$UI_TEST_RESULTS"
    bqa_q=0
    while true; do
      bqa_rc=0
      _run_step "$SCRIPT_DIR/browser-qa-phase.sh" "$PHASE" || bqa_rc=$?
      if [[ $bqa_rc -eq 75 && $bqa_q -lt 2 ]]; then bqa_q=$((bqa_q+1)); continue; fi
      if _is_signal_exit "$bqa_rc"; then
        log "  Step 6 (browser-qa) interrupted by signal (exit $bqa_rc) — aborting; resume will re-run this step."
        exit "$bqa_rc"
      fi
      [[ $bqa_rc -ne 0 && $bqa_rc -ne 75 ]] && log "  Warning: browser-qa-phase.sh exited with error -- continuing"
      break
    done
    log "  Browser QA results: $UI_TEST_RESULTS"
  else
    log "Step 6/11 -- Browser QA: skipped (backend-only phase) -- writing N/A stubs."
    write_na_ui_artifacts "$PHASE" "ui-test-results"
  fi
  update_status "$PHASE" "in_progress" "browser_qa_complete"
else
  log "Step 6/11 -- Browser QA: skipped (checkpoint: $CURRENT_STEP)"
fi
echo ""

# ── Step 6.5/11: Product demo (showcase, not gate) ──────────────────────────
# Runs in the SAME app-up window as browser QA — the idempotent
# ensure_services_running in demo-phase.sh is a no-op when the app is still
# warm, so the standard pipeline pays NO second boot. Showcase-only: the demo
# never halts the pipeline (signals and quota propagate; any other failure
# becomes a SKIPPED stub and exit 0). Skipped for backend-only iterations and
# when browser QA itself was skipped.
if [[ "$SKIP_BROWSER_QA" == "false" && "$FRONTEND_PRESENT" == "yes" ]]; then
  log "Step 6.5/11 -- Product demo (showcase)..."
  demo_rc=0
  _run_step "$SCRIPT_DIR/demo-phase.sh" "$PHASE" || demo_rc=$?
  if _is_signal_exit "$demo_rc"; then
    log "  Step 6.5 (demo) interrupted by signal (exit $demo_rc) — aborting; resume will re-run this step."
    exit "$demo_rc"
  fi
  if [[ $demo_rc -eq 75 ]]; then
    log "  Step 6.5 (demo) hit quota (exit 75) — outer loop will handle."
    exit 75
  fi
  if [[ $demo_rc -ne 0 ]]; then
    log "  Warning: demo-phase.sh exited with code $demo_rc — continuing (showcase, non-gating)"
  fi
else
  log "Step 6.5/11 -- Product demo: skipped (backend-only or browser-qa skipped)"
fi
echo ""

# Kill any servers left behind by previous steps (browser QA, demo, dev, etc.)
kill_phase_servers

# ── Step 7/11: QA loop ────────────────────────────────────────────────────────
if [[ "$SKIP_QA" == "false" ]]; then
  log "Step 7/11 -- QA loop (max $MAX_RETRIES attempts)..."
  QA_ATTEMPT=0

  while true; do
    QA_ATTEMPT=$((QA_ATTEMPT + 1))
    log "  [QA attempt $QA_ATTEMPT/$MAX_RETRIES] Running QA validator..."
    # Clear stale verdict so a script crash before write cannot be masked
    # by the previous attempt's PASS verdict.
    rm -f "$QA_REPORT"
    qa_rc=0
    _run_step "$SCRIPT_DIR/qa-phase.sh" "$PHASE" || qa_rc=$?
    if [[ $qa_rc -eq 75 ]]; then
      QA_ATTEMPT=$((QA_ATTEMPT - 1))  # don't count quota failures
      continue
    fi
    if _is_signal_exit "$qa_rc"; then
      log "  Step 7 (qa) interrupted by signal (exit $qa_rc) — aborting."
      exit "$qa_rc"
    fi
    [[ $qa_rc -ne 0 ]] && log "  Warning: qa-phase.sh exited with error (attempt $QA_ATTEMPT) -- checking verdict"

    if verdict_passes "$QA_REPORT"; then
      log "  QA: PASS"
      break
    fi

    if [[ $QA_ATTEMPT -ge $MAX_RETRIES ]]; then
      fail "QA failed after $MAX_RETRIES attempts. See: $QA_REPORT" "qa_failed"
    fi

    log "  QA: FAIL (attempt $QA_ATTEMPT) -- fixing then re-reviewing..."
    qd_rc=0
    _run_step "$SCRIPT_DIR/dev-phase.sh" "$PHASE" || qd_rc=$?
    [[ $qd_rc -eq 75 ]] && { QA_ATTEMPT=$((QA_ATTEMPT - 1)); continue; }
    if _is_signal_exit "$qd_rc"; then
      log "  Step 7 fix-mode (dev) interrupted by signal (exit $qd_rc) — aborting."
      exit "$qd_rc"
    fi
    [[ $qd_rc -ne 0 ]] && log "  Warning: dev-phase.sh exited with error -- continuing"
    qr_rc=0
    _run_step "$SCRIPT_DIR/review-phase.sh" "$PHASE" || qr_rc=$?
    [[ $qr_rc -eq 75 ]] && { QA_ATTEMPT=$((QA_ATTEMPT - 1)); continue; }
    if _is_signal_exit "$qr_rc"; then
      log "  Step 7 fix-mode (review) interrupted by signal (exit $qr_rc) — aborting."
      exit "$qr_rc"
    fi
    [[ $qr_rc -ne 0 ]] && log "  Warning: review-phase.sh exited with error -- continuing"
  done

  update_status "$PHASE" "complete" "qa_passed"
else
  log "Step 7/11 -- QA: skipped (checkpoint: $CURRENT_STEP)"
fi
echo ""

# Kill any servers left behind by QA
kill_phase_servers

# ── Step 8/11: UX Regression Review ──────────────────────────────────────────
if [[ "$SKIP_UX_REGRESSION" == "false" ]]; then
  if [[ "$FRONTEND_PRESENT" == "yes" ]]; then
    log "Step 8/11 -- UX Regression Review..."
    # Clear stale verdict so a script crash before write cannot be masked
    # by a previous run's PASS verdict.
    rm -f "$UX_REGRESSION"
    uxr_q=0
    while true; do
      uxr_rc=0
      _run_step "$SCRIPT_DIR/ux-regression-phase.sh" "$PHASE" || uxr_rc=$?
      if [[ $uxr_rc -eq 75 && $uxr_q -lt 2 ]]; then uxr_q=$((uxr_q+1)); continue; fi
      if _is_signal_exit "$uxr_rc"; then
        log "  Step 8 (ux-regression) interrupted by signal (exit $uxr_rc) — aborting."
        exit "$uxr_rc"
      fi
      [[ $uxr_rc -ne 0 && $uxr_rc -ne 75 ]] && log "  Warning: ux-regression-phase.sh exited with error -- continuing"
      break
    done
    if ! ux_regression_verdict_passes "$UX_REGRESSION"; then
      log "  UX Regression: FAIL -- flagging for attention (non-blocking, closure auditor will assess)"
    else
      log "  UX Regression: PASS or WARN (acceptable)"
    fi
  else
    log "Step 8/11 -- UX Regression: skipped (backend-only phase)."
  fi
  update_status "$PHASE" "in_progress" "ux_regression_complete"
else
  log "Step 8/11 -- UX Regression Review: skipped (checkpoint: $CURRENT_STEP)"
fi
echo ""

# Kill any servers left behind by UX regression
kill_phase_servers

# ── Step 9/11: Post-phase audit loop ─────────────────────────────────────────
if [[ "$SKIP_AUDIT" == "false" ]]; then
  log "Step 9/11 -- Post-phase audit (max $MAX_AUDIT_RETRIES attempts)..."
  AUDIT_ATTEMPT=0

  while true; do
    AUDIT_ATTEMPT=$((AUDIT_ATTEMPT + 1))
    log "  [audit attempt $AUDIT_ATTEMPT/$MAX_AUDIT_RETRIES] Running phase auditor..."
    # Clear stale verdict so a script crash before write cannot be masked
    # by a previous attempt's PASS verdict.
    rm -f "$AUDIT_REPORT"
    aud_rc=0
    _run_step "$SCRIPT_DIR/phase-audit.sh" "$PHASE" || aud_rc=$?
    if [[ $aud_rc -eq 75 ]]; then
      AUDIT_ATTEMPT=$((AUDIT_ATTEMPT - 1))  # don't count quota failures
      continue
    fi
    if _is_signal_exit "$aud_rc"; then
      log "  Step 9 (audit) interrupted by signal (exit $aud_rc) — aborting."
      exit "$aud_rc"
    fi
    [[ $aud_rc -ne 0 ]] && log "  Warning: phase-audit.sh exited with error (attempt $AUDIT_ATTEMPT) -- checking verdict"

    if verdict_passes "$AUDIT_REPORT"; then
      log "  Audit: PASS"
      break
    fi

    if [[ $AUDIT_ATTEMPT -ge $MAX_AUDIT_RETRIES ]]; then
      fail "Audit failed after $MAX_AUDIT_RETRIES attempts. See: $AUDIT_REPORT" "audit_failed"
    fi

    log "  Audit: FAIL (attempt $AUDIT_ATTEMPT) -- applying hardening fixes..."
    ad_rc=0
    _run_step "$SCRIPT_DIR/dev-phase.sh" "$PHASE" || ad_rc=$?
    [[ $ad_rc -eq 75 ]] && { AUDIT_ATTEMPT=$((AUDIT_ATTEMPT - 1)); continue; }
    if _is_signal_exit "$ad_rc"; then
      log "  Step 9 hardening (dev) interrupted by signal (exit $ad_rc) — aborting."
      exit "$ad_rc"
    fi
    [[ $ad_rc -ne 0 ]] && log "  Warning: dev-phase.sh exited with error -- continuing"
    ar_rc=0
    _run_step "$SCRIPT_DIR/review-phase.sh" "$PHASE" || ar_rc=$?
    [[ $ar_rc -eq 75 ]] && { AUDIT_ATTEMPT=$((AUDIT_ATTEMPT - 1)); continue; }
    if _is_signal_exit "$ar_rc"; then
      log "  Step 9 hardening (review) interrupted by signal (exit $ar_rc) — aborting."
      exit "$ar_rc"
    fi
    [[ $ar_rc -ne 0 ]] && log "  Warning: review-phase.sh exited with error -- continuing"

    log "  Re-running QA after hardening..."
    aq_rc=0
    _run_step "$SCRIPT_DIR/qa-phase.sh" "$PHASE" || aq_rc=$?
    [[ $aq_rc -eq 75 ]] && { AUDIT_ATTEMPT=$((AUDIT_ATTEMPT - 1)); continue; }
    if _is_signal_exit "$aq_rc"; then
      log "  Step 9 hardening (qa) interrupted by signal (exit $aq_rc) — aborting."
      exit "$aq_rc"
    fi
    if ! verdict_passes "$QA_REPORT"; then
      fail "QA failed during audit hardening. See: $QA_REPORT" "audit_qa_failed"
    fi
    log "  QA: PASS (post-hardening)"
  done

  update_status "$PHASE" "complete" "audit_passed"
else
  log "Step 9/11 -- Audit: skipped (checkpoint: $CURRENT_STEP)"
fi
echo ""

# ── Step 10/11: Phase Closure Check ──────────────────────────────────────────
if [[ "$SKIP_CLOSURE" == "false" ]]; then
  log "Step 10/11 -- Phase Closure Check..."
  # Clear stale verdict so a script crash before write cannot be masked
  # by a previous run's PASS verdict.
  rm -f "$CLOSURE_VERDICT"
  clo_q=0
  while true; do
    clo_rc=0
    _run_step "$SCRIPT_DIR/phase-closure-check.sh" "$PHASE" || clo_rc=$?
    if [[ $clo_rc -eq 75 && $clo_q -lt 2 ]]; then clo_q=$((clo_q+1)); continue; fi
    [[ $clo_rc -ne 0 && $clo_rc -ne 75 ]] && log "  Warning: phase-closure-check.sh exited with error -- checking verdict"
    break
  done

  if ! closure_verdict_passes "$CLOSURE_VERDICT"; then
    fail "Phase closure check failed. See: $CLOSURE_VERDICT" "closure_failed"
  fi

  log "  Closure: PASS"
  update_status "$PHASE" "complete" "closure_passed"
else
  log "Step 10/11 -- Closure Check: skipped (checkpoint: $CURRENT_STEP)"
fi
echo ""

# ── Step 10.5/11: Build iteration summary + render HTML ─────────────────────
log "Step 10.5/11 -- Building iteration summary + rendering HTML..."
_run_iteration_summarizer
_render_summary_html
SUMMARY_MD="$REPO_ROOT/reports/phase-${PHASE}-iteration-summary.md"
HTML_PATH="$REPO_ROOT/reports/phase-${PHASE}-summary.html"
[[ -f "$SUMMARY_MD" ]] && log "  Summary MD:   $SUMMARY_MD"
[[ -f "$HTML_PATH" ]] && log "  Summary HTML: file://$HTML_PATH"
echo ""

# ── Cleanup: remove temp files generated during the run ─────────────────────
log "Cleanup: removing temp files..."
cleanup_phase_artifacts "$PHASE"
log "  Cleanup complete."
echo ""

# ── Step 11/11: Finalize or print instructions ──────────────────────────────
log "Step 11/11 -- Phase $PHASE complete!"
echo ""
echo "========================================"
echo "  Phase $PHASE: ALL CHECKS PASSED"
echo "========================================"
echo ""
echo "Artifacts:"
echo "  Plan:                     runs/${PHASE}/plan.md"
echo "  Test plan:                reports/qa/${PHASE}-test-plan.md"
echo "  Dev handoff:              docs/handoffs/${PHASE}-dev.md"
echo "  Review report:            reports/reviews/${PHASE}-review.md"
echo "  Implementation summary:   reports/phase-${PHASE}-implementation-summary.md"
echo "  User-visible changes:     reports/phase-${PHASE}-user-visible-changes.md"
echo "  UI surface map:           reports/phase-${PHASE}-ui-surface-map.md"
echo "  UI test plan:             reports/phase-${PHASE}-ui-test-plan.md"
echo "  Browser QA results:       reports/phase-${PHASE}-ui-test-results.md"
echo "  What to click:            reports/phase-${PHASE}-what-to-click.md"
echo "  UX regression review:     reports/phase-${PHASE}-ux-regression.md"
echo "  QA report:                reports/qa/${PHASE}-qa.md"
echo "  Audit report:             docs/handoffs/${PHASE}-audit.md"
echo "  Closure verdict:          reports/phase-${PHASE}-closure-verdict.md"
echo "  Status:                   runs/${PHASE}/status.json"
echo "  Iteration summary:        reports/phase-${PHASE}-iteration-summary.md"
echo "  HTML summary:             reports/phase-${PHASE}-summary.html"
echo "  Project goal:             docs/goal.md (if present)"
echo "  Architecture docs:        docs/architecture/ (if present)"
echo ""
echo "Quick verification:"
echo "  cat reports/phase-${PHASE}-what-to-click.md"
echo ""

if [[ "$AUTO_RELEASE" == "true" ]]; then
  log "Auto-release: running finalize-phase.sh --yes ..."
  echo ""
  bash "$SCRIPT_DIR/finalize-phase.sh" "$PHASE" --yes
elif [[ "$NO_FINALIZE" == "true" ]]; then
  log "--no-finalize set: skipping finalize hint (release-manager will run once at goal-session end)."
else
  echo "To commit and create a PR, run:"
  echo "  ./scripts/automation/finalize-phase.sh $PHASE"
fi
