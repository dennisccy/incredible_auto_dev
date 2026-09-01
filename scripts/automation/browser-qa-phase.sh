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
# Telemetry (no-op unless GOAL_SESSION_DIR is set, i.e. goal-mode full depth):
# lets claude_with_quota_retry forward each dispatch's usage sidecar into the
# session's per-agent economics (TOKEN-8).
source "$SCRIPT_DIR/lib/telemetry.sh"
# Deterministic regression-replay lane — ONE implementation shared with the
# lean executor (lib/replay-lane.sh). Engages ONLY for goal-session iterations
# (see the goal-context block below); plain phase mode never touches it.
source "$SCRIPT_DIR/lib/replay-lane.sh"
# shellcheck disable=SC2034  # consumed by lib/replay-lane.sh's log helpers
REPLAY_LANE_TAG="browser-qa"

# SPEED-15: pick up the engine's iteration clock so the trim ladder (rung 2
# below) can consult the shared budget. Standalone phase mode has no epoch
# exported → the budget machinery stays inert here, exactly as before.
if [[ -n "${CHAIN_ITER_START_EPOCH:-}" ]]; then iter_budget_init; fi

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

# FAIL-CLOSED: maintenance isolation forbids this entire lane — browser QA and
# the deterministic replay it drives both start processes and read a database
# this iteration has declared off-limits. Refuse BEFORE any service probe, any
# replay partition, and any agent dispatch, and leave an honest SKIPPED artifact
# so the merge/evaluator path sees a contract decision, not a silent gap.
if goal_maintenance_isolation_required "$SPEC"; then
  maintenance_isolation_refuse "browser-qa-phase" "browser QA + deterministic replay lane" || true
  mkdir -p "$(dirname "$UI_TEST_RESULTS")" 2>/dev/null || true
  cat > "$UI_TEST_RESULTS" <<EOF
# Phase ${PHASE} — UI Test Results

**Browser QA Verdict:** SKIPPED

**Reason:** maintenance isolation is required for this iteration — application-service boot, browser QA and the deterministic replay lane are forbidden by contract, so no browser validation was executed.

## Why this lane did not run

This iteration declares **maintenance isolation**. Application-service boot,
browser QA, and the deterministic replay lane are **forbidden by contract** for
it — this is a deliberate contract decision, not an infrastructure failure and
not an accidental gap.

Full reviewer / QA / auditor / coherence / evaluator depth is unchanged and still
required; only app-service and browser execution are withheld. No backend or
frontend was started, no browser was opened, no replay was partitioned or run,
and no golden replay script was written.

No journey is marked PASS or FAIL here. A journey failure against the current
dataset would be expected damage from a known, still-unrepaired condition rather
than a regression, so recording either verdict from this lane would be misleading.
EOF
  echo "[browser-qa] SKIPPED by maintenance isolation — wrote $UI_TEST_RESULTS"
  exit 0
fi

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

# _wait_for_url lives in lib/common.sh (sourced above) — shared with qa-phase.sh
# and demo-phase.sh.

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
#
# Skip entirely in the post-dev fanout: there the caller (run-phase.sh
# _boot_shared_services) owns the frontend and already cleared stale locks at boot.
# Killing it here would leave the demo — which runs after this script in the SAME
# branch against the SAME shared services — with no frontend to probe, the cause of
# spurious demo SKIPs. Only reclaim stale servers when this script owns them.
if [[ "${CHAIN_SHARED_SERVICES:-false}" != "true" ]]; then
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
# mark every test SKIPPED. _wait_for_frontend_ready retries every 3s up to the
# budget before giving up — a slow boot is no longer misread as "frontend not
# available" — and, on the standalone (non-shared) path, heals a corrupt `.next`
# once (rm -rf .next + restart) instead of waiting out the budget against a 500.
if _wait_for_frontend_ready "$FRONTEND_URL" "frontend" 90 "browser-qa"; then
  FRONTEND_AVAILABLE="yes"
  FRONTEND_SKIP_REASON=""
else
  FRONTEND_AVAILABLE="no"
  echo "[browser-qa] Frontend not available after re-probe — browser tests will be marked SKIPPED."
  # Build an actionable reason (dependency hint) instead of a bare "not running",
  # and echo the real start-up log tail (captured by ensure_services_running) to
  # the operator console so the cause is visible, not just the symptom.
  FRONTEND_SKIP_REASON="frontend not running"
  _fe_hint="$(_qa_dep_hint frontend)"
  [[ -n "$_fe_hint" ]] && FRONTEND_SKIP_REASON+=" — likely cause: $_fe_hint"
  _fe_tail="${QA_FRONTEND_LOG_TAIL:-}"
  [[ -z "$_fe_tail" && -n "${QA_FRONTEND_LOG:-}" && -f "${QA_FRONTEND_LOG:-}" ]] && _fe_tail="$(tail -n 15 "$QA_FRONTEND_LOG" 2>/dev/null || true)"
  [[ -n "$_fe_tail" ]] && { echo "[browser-qa] Frontend start log tail (${QA_FRONTEND_LOG:-?}):" >&2; echo "$_fe_tail" >&2; }
fi

# ── Goal-mode deterministic regression replay (replay-gap fix) ───────────────
# For goal-session iterations (phase name `goal-<sid>-iter-<N>` — the same
# regex run-phase.sh keys its evaluator-log pre-trim on) this step runs the
# SAME two-lane split as the lean executor, via the shared lib/replay-lane.sh:
#   • the deterministic replay re-verifies the iteration spec's
#     Required-still-passing journeys that have stored golden scripts —
#     services are already up here (under the post-dev fanout via
#     CHAIN_SHARED_SERVICES, or this script's own boot above);
#   • the LLM lane below covers the remainder (no golden on file, a replay
#     FAIL to re-confirm, or the CHAIN_REGRESSION_REPLAY=false hatch) through
#     the GOAL-MODE REGRESSION LANES prompt addendum;
#   • after the dispatch the lanes merge into the single authoritative
#     ui-test-results.md the goal-evaluator and the achievement gate read.
# Plain phase mode: the name never matches, every variable below keeps its
# empty/default value, and the dispatch prompt is byte-identical to before.
GOAL_REPLAY_ACTIVE="no"
# Lane dataflow globals — set here (and reassigned by the lib), consumed inside
# lib/replay-lane.sh functions shellcheck cannot follow (computed source path).
_use_replay="no"; R_REPLAY=""; REPLAY_FAILED=""
# shellcheck disable=SC2034
R_LLM=""
REQUIRED_JOURNEYS=""
_llm_out="$UI_TEST_RESULTS"
_goal_lanes_note=""
if [[ "$PHASE" =~ ^goal-(.+)-iter-[0-9]+$ ]]; then
  GOAL_REPLAY_ACTIVE="yes"
  replay_lane_paths "$PHASE"
  # shellcheck disable=SC2034
  REQUIRED_JOURNEYS="$(replay_lane_spec_journeys 'Required-still-passing' "$SPEC")"
  replay_lane_partition_and_verify "$PHASE"
  if [[ "$_use_replay" == "yes" ]]; then
    _llm_out="$LLM_RESULTS"
  fi
  # SPEED-15 rung 2: capture the deferred set ONCE (the budget clock keeps
  # ticking — a later recompute could disagree with what was dispatched);
  # replay_lane_llm_regression_set narrows itself when it is non-empty, and
  # the post-merge writer below appends the DEFERRED-BUDGET rows. Targets are
  # excluded from deferral — they are dispatched regardless.
  _bqa_targets="$(replay_lane_spec_journeys 'Target journeys:' "$SPEC")"
  REPLAY_DEFERRED_BUDGET="$(replay_lane_deferred_budget_set "$_bqa_targets")"
  if [[ -n "${REPLAY_DEFERRED_BUDGET// /}" ]]; then
    echo "[browser-qa] iter-budget trim (rung 2): deferring no-golden regression journey(s) this iteration: ${REPLAY_DEFERRED_BUDGET% }— targets + replay-FAIL re-confirms are never deferred."
    declare -F iter_budget_trim_event >/dev/null 2>&1 && iter_budget_trim_event "replay-narrow"
  fi
  _llm_regr_set="$(replay_lane_llm_regression_set)"
  # TOKEN-10: journey definitions for the regression lane come from a sliced
  # goal view — targets ∪ this run's LLM regression set stay verbatim; only
  # replay-covered/stable journeys are digested. Bare call: sets
  # GOAL_SLICE_EXEC_PATH + GOAL_SLICE_EXEC_MODE (hatch/fallback → full file).
  goal_slice_for_exec "$PHASE" \
    "$(echo "$_bqa_targets $_llm_regr_set" | tr ' ' '\n' | grep -E '^J-[0-9]+$' | sort -u | tr '\n' ',' | sed 's/,$//')" \
    "$REPO_ROOT/runs/$PHASE/goal-slice-bqa.md"
  _bqa_goal_ref="$GOAL_SLICE_EXEC_PATH"
  _bqa_goal_note=""
  [[ "$GOAL_SLICE_EXEC_MODE" == "sliced" ]] && _bqa_goal_note=" (a token-lean goal slice — every journey listed here appears verbatim; read the full docs/goal.md ONLY if a definition you need is missing)"
  # SPEED-23: same rotating golden nudge as the lean lane — one gap journey in
  # this run's LLM set gets its golden promoted to a REQUIRED deliverable.
  _bqa_nudge="$(replay_lane_golden_nudge_pick "$_llm_regr_set" || true)"
  if [[ -n "$_bqa_nudge" ]]; then
    echo "[browser-qa] SPEED-23 golden nudge: $_bqa_nudge MUST get a golden replay script this dispatch (rotating pick from state/golden-gaps; CHAIN_GOLDEN_NUDGE=false disables)."
    if declare -F record_telemetry_event >/dev/null 2>&1; then
      record_telemetry_event "golden_nudge" "$(jq -cn --arg j "$_bqa_nudge" --arg n "$PHASE" '{journey:$j, iter_name:$n}' 2>/dev/null || printf '{"journey":"%s"}' "$_bqa_nudge")" || true
    fi
  fi
  _goal_lanes_note="

GOAL-MODE REGRESSION LANES (goal-session iteration — IN ADDITION to the test plan):
$(if [[ "$_use_replay" == "yes" && -n "${R_REPLAY// /}" ]]; then
  echo "- Deterministic replay has ALREADY re-verified these Required-still-passing journeys from stored golden scripts: ${R_REPLAY% }. Do NOT re-test them and do NOT emit rows for them — their rows merge into the results automatically after your run. (If a test-plan case you execute anyway covers one, that is fine; your row supersedes the replay's.)"
fi)
$(if [[ -n "${_llm_regr_set// /}" ]]; then
  echo "- ALSO execute these regression journeys this run: ${_llm_regr_set% }. For each: read its numbered steps + Acceptance line from the \"Must-have user journeys\" section of ${_bqa_goal_ref}${_bqa_goal_note}, execute it like a test case, and add a results-table row using the journey ID as the Test ID (e.g. UT-J-01)."
fi)
$(if [[ -n "${REPLAY_FAILED// /}" ]]; then
  echo "- The replay lane flagged possible regression(s) on: ${REPLAY_FAILED% } (already included in the list above). Re-confirm each by executing the journey yourself; if it passes, the replay FAIL was a stale golden script — repair that journey's golden so the next iteration replays clean."
fi)

GOLDEN REPLAY SCRIPTS (goal-mode regression speedup): for every journey you verify
PASS, ALSO write a self-contained deterministic replay script to
$JOURNEY_SCRIPTS_DIR/<J-XX>.json (overwrite if present), IMMEDIATELY after that
journey passes — follow the 'Golden replay script' section of your agent
instructions for the exact JSON shape. Best-effort: if you cannot produce one for
a journey, skip it (that journey just falls back to the LLM lane next time).
$(if [[ -n "${_bqa_nudge:-}" ]]; then echo "REQUIRED DELIVERABLE (golden-coverage nudge): journey $_bqa_nudge keeps passing but still has NO golden replay script, so it rides this slow LLM lane every iteration. After verifying it this run you MUST write $JOURNEY_SCRIPTS_DIR/$_bqa_nudge.json before finishing — for THIS one journey the golden is NOT best-effort."; fi)"
fi

SERVICES_NOTE="Note: browser-qa-phase.sh manages backend (${BACKEND_HEALTH_URL}, log: ${QA_BACKEND_LOG}) and frontend (${FRONTEND_URL}, log: ${QA_FRONTEND_LOG}). Services are restarted automatically if they die during quota-retry sleeps."

# Pre-retry hook — revive any services that died during a long quota sleep
# before claude attempts the next call.
export CHAIN_CLAUDE_PRE_RETRY_HOOK="ensure_services_running"

# ── Host-safety: pin the QA browser, run it headless, re-confine escapees ────
# The Chrome MCP reconnects to and adopts browsers it did not spawn, so a
# browser born unconfined stays unconfined however well the engine tree is
# capped — and an unconfined headed Chrome is the burst profile that hard-reset
# this host on 2026-07-29. All three calls no-op without a host-guard project.
ensure_qa_browser_env ""
strip_display_for_headless_qa
bqa_browser_confine

# ── REL-14 preflight (CHAIN_BQA_PREFLIGHT, default off) ─────────────────────
# Probe services once more (+ one ensure_services_running retry) before burning
# the browser-qa dispatch against dead infra. On persistent failure: skip the
# dispatch; goal-session iterations also write the out-of-band token the
# goal-evaluator reads ($ITER_DIR/browser-infra.json). The merged results
# verdict enum stays PASS|FAIL|SKIPPED either way. FRONTEND_AVAILABLE=no keeps
# today's honest agent-side SKIP path and is never tokenized here.
_bqa_infra_blocked="no"
_bqa_tok_set=""
if [[ "$GOAL_REPLAY_ACTIVE" == "yes" ]]; then
  _bqa_tok_set="$(replay_lane_spec_journeys 'Target journeys:' "$SPEC") ${_llm_regr_set:-}"
  _bqa_tok_set="$(echo "$_bqa_tok_set" | tr ' ' '\n' | grep -E '^J-[0-9]+$' | sort -u | tr '\n' ' ' || true)"
  _bqa_tok_set="${_bqa_tok_set% }"
fi
if [[ "${CHAIN_BQA_PREFLIGHT:-false}" == "true" && "$FRONTEND_AVAILABLE" == "yes" ]]; then
  if ! bqa_preflight; then
    _bqa_infra_blocked="yes"
    echo "[browser-qa] REL-14 preflight: services still unreachable after re-check + retry — skipping the browser-qa dispatch." >&2
    if [[ "$GOAL_REPLAY_ACTIVE" == "yes" && -n "${GOAL_SESSION_DIR:-}" && -n "${GOAL_ITER_INDEX:-}" ]]; then
      bqa_write_infra_token "$GOAL_SESSION_DIR/iter-$GOAL_ITER_INDEX" "$_bqa_tok_set" \
        "services preflight failed after ensure_services_running retry" "preflight"
    fi
  fi
fi

# ── Run browser QA agent ───────────────────────────────────────────────────
cd "$REPO_ROOT"
# Guard against `set -e` so we can inspect the exit code and fall back to
# writing a SKIPPED stub when the agent leaves no results file.
_bqa_rc=0
if [[ "$_bqa_infra_blocked" == "yes" ]]; then
  : # REL-14: dispatch skipped — preflight failure recorded above (no dispatch → no agent telemetry)
else
record_agent_invocation_start browser-qa-agent
_agent_t0="$CHAIN_AGENT_START_EPOCH"
claude_with_quota_retry -p "You are the browser-qa-agent for phased development.

Phase: $PHASE
Phase spec: $SPEC
Agent instructions: .claude/agents/browser-qa-agent.md  <-- read this first
(CLAUDE.md is already in your system prompt — do not Read it again.)
Skill: .claude/skills/browser-workflow-executor.md  <-- read for Chrome MCP technique

UI test plan: $UI_TEST_PLAN  <-- execute each test case in this file
UI surface map: $UI_SURFACE_MAP${_goal_lanes_note}

Frontend URL: $FRONTEND_URL
Frontend available: $FRONTEND_AVAILABLE
$SERVICES_NOTE

$(if [[ "$FRONTEND_AVAILABLE" == "yes" ]]; then
  echo "Chrome MCP browser checks ARE required. Use mcp__plugin_superpowers-chrome_chrome__use_browser for each test case."
else
  echo "Frontend is NOT available. Mark all tests as SKIPPED with reason: ${FRONTEND_SKIP_REASON:-frontend not running}."
  echo "Do NOT attempt to run browser tests."
fi)

Execute the test plan:
- For each UT-XX test case: execute steps, verify expected result, record PASS/FAIL/SKIP
- Take screenshots for key states and save to reports/qa/${PHASE}-evidence/
- For failures: record exact failure description

Write your results to: $_llm_out
Use template: templates/ui-test-results.md

The report MUST contain a line at the top:
**Browser QA Verdict:** PASS
  or
**Browser QA Verdict:** FAIL
  or
**Browser QA Verdict:** SKIPPED

Then STOP." || _bqa_rc=$?
record_agent_invocation_end browser-qa-agent "$_agent_t0" "$_bqa_rc"
# Engine-side browser teardown, right after the dispatch: closes the tabs the
# agent used (clean exit), reaps only a survivor of THIS lane. lib/common.sh.
qa_browser_step_teardown "$FRONTEND_URL"
fi

# Signal-induced exit (Ctrl-C, SIGKILL, SIGTERM) → do NOT write SKIPPED stubs.
# A stub would advertise the step as "ran but produced no real artifact," which
# tricks run-phase.sh's retry loop into advancing the checkpoint past this step
# (`update_status ... browser_qa_complete`). The next resume would then skip
# the step but closure-check would flag the stub as missing real content. By
# exiting without stubs, the working tree is unchanged so resume re-runs the
# step and run-phase.sh's signal-aware retry guard aborts the run cleanly.
# See .claude/anti-patterns/20-next-build-against-dev.md.
if [[ $_bqa_rc -eq 130 || $_bqa_rc -eq 137 || $_bqa_rc -eq 143 ]]; then
  echo "[browser-qa] Killed by signal (exit $_bqa_rc) — leaving artifacts untouched so resume can re-run this step." >&2
  exit "$_bqa_rc"
fi

# ── Goal-mode lane merge (replay + LLM → the authoritative results file) ─────
# LLM listed last → wins on any journey both lanes touched (e.g. a replay-FAIL
# re-confirm); the shared merge also reconciles the raw replay artifact when a
# FAIL was overturned. Runs BEFORE the no-results stub check below, so an
# LLM-lane crash still leaves the replay lane's REAL rows in ui-test-results.md
# (never a stub) — the goal-evaluator and the achievement gate read the merged
# file either way. Mirrors goal-iter-lean.sh's section tail (REL-11 warn on a
# dispatch that returned without writing; quota 75 excluded — the outer loop
# handles it loudly).
if [[ "$GOAL_REPLAY_ACTIVE" == "yes" ]]; then
  if [[ ! -f "$_llm_out" && $_bqa_rc -ne ${QUOTA_EXHAUSTED_EXIT_CODE:-75} && "$_bqa_infra_blocked" != "yes" ]]; then
    warn_missing_evidence "browser-qa-agent" "$_llm_out"
  fi
  if [[ "$_use_replay" == "yes" ]]; then
    replay_lane_merge_results "$UI_TEST_RESULTS" "$_llm_out"
    replay_lane_write_deferred_rows "$UI_TEST_RESULTS"
  fi
  replay_lane_golden_coverage "$UI_TEST_RESULTS" "$PHASE"
fi

# REL-14 post-scan (same knob): a dispatch that returned but left no results
# file (mid-run browser death; quota pauses excluded) or an all-SKIP results
# file carrying an explicit browser-infra reason also earns the token — no
# preflight can catch a Chrome that dies mid-run. Goal-session iterations only.
if [[ "${CHAIN_BQA_PREFLIGHT:-false}" == "true" && "$_bqa_infra_blocked" != "yes" \
      && "$GOAL_REPLAY_ACTIVE" == "yes" && -n "${GOAL_SESSION_DIR:-}" && -n "${GOAL_ITER_INDEX:-}" ]]; then
  if [[ ! -f "$_llm_out" && $_bqa_rc -ne ${QUOTA_EXHAUSTED_EXIT_CODE:-75} ]]; then
    bqa_write_infra_token "$GOAL_SESSION_DIR/iter-$GOAL_ITER_INDEX" "$_bqa_tok_set" \
      "browser-qa dispatch returned rc=$_bqa_rc with no results file" "postscan-missing"
  elif _bqa_infra_reason="$(bqa_results_infra_reason "$UI_TEST_RESULTS")"; then
    bqa_write_infra_token "$GOAL_SESSION_DIR/iter-$GOAL_ITER_INDEX" "$_bqa_tok_set" \
      "$_bqa_infra_reason" "postscan"
  fi
fi

# REL-14: a preflight-blocked dispatch leaves no LLM rows; if the replay merge
# did not produce a results file either, write the SKIPPED stub so closure and
# the evaluator still have an artifact (the out-of-band token carries the why).
if [[ "$_bqa_infra_blocked" == "yes" && ! -f "$UI_TEST_RESULTS" ]]; then
  write_failed_artifact_stub "$PHASE" "ui-test-results" \
    "REL-14 preflight: services unreachable after re-check + one retry — browser-qa dispatch skipped (browser infrastructure, not a product defect)."
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

# The per-dispatch browser teardown ran right after the dispatch above
# (qa_browser_step_teardown): default-on, lane-scoped, clean CDP close before any
# reap. CHAIN_BQA_REAP=0 restores the old leave-warm behaviour.

echo "[browser-qa] Done. Report: $UI_TEST_RESULTS"
