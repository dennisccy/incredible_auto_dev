#!/usr/bin/env bash
# demo-phase.sh — Run the per-iteration product demo (showcase, not QA).
#
# Two layers:
#   1. AUTHOR  — the demo-narrator agent (no browser) reads the iteration's
#      already-verified UI flows and writes an executable demo-script JSON.
#      Cached: re-used on the next run unless stale or --reauthor is given.
#   2. EXECUTOR — lib/demo_runner.py (Playwright, no model in the loop) reads
#      that JSON and drives Chrome. Deterministic → fast, no looping.
#
# Usage:
#   ./scripts/automation/demo-phase.sh <phase-id>             # record gallery (default)
#   ./scripts/automation/demo-phase.sh <phase-id> --live      # live walkthrough (this iteration)
#   ./scripts/automation/demo-phase.sh <sid> --session        # live walkthrough of the WHOLE product
#   ./scripts/automation/demo-phase.sh <id>  ... --reauthor   # force the author to rebuild the JSON
#
# Modes:
#   record  → runner drives the app headless, captures a captioned screenshot
#             gallery to reports/demo/<phase-id>/ and writes demo-script.md +
#             demo-results.md (which the HTML renderer consumes). Re-uses the
#             app already booted by browser-qa-phase.sh (idempotent boot).
#   live    → runner drives a VISIBLE Chrome, narrating each step to the
#             terminal and waiting for Enter between steps. Writes no artifacts.
#   session → like live, but the demo JSON covers the cumulative product across
#             all iterations (every passing journey). For goal sessions.
#
# Showcase, not gate: a failed step is a soft note, never a hard pipeline fail.
# On author crash / stream timeout in record mode the script writes a SKIPPED
# stub so the renderer still has something to read, then exits 0. Signal exits
# and quota propagate unchanged (same policy as browser-qa-phase.sh).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ── Parse arguments ──────────────────────────────────────────────────────────
ID=""
MODE="record"   # record | live | session
REAUTHOR="no"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --live)     MODE="live"; shift ;;
    --session)  MODE="session"; shift ;;
    --reauthor) REAUTHOR="yes"; shift ;;
    --*)        echo "Error: unknown flag '$1'" >&2; exit 2 ;;
    *)
      if [[ -z "$ID" ]]; then ID="$1"; else echo "Error: unexpected arg '$1'" >&2; exit 2; fi
      shift ;;
  esac
done

if [[ -z "$ID" ]]; then
  echo "Usage: $0 <id> [--live | --session] [--reauthor]" >&2
  exit 2
fi

# A demo JSON is fresh when it exists and no listed input is newer than it.
_demo_json_fresh() {
  local json="$1"; shift
  [[ -f "$json" ]] || return 1
  local f
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    [[ "$f" -nt "$json" ]] && return 1
  done
  return 0
}

RUNNER="$SCRIPT_DIR/lib/demo_runner.py"

# ── Resolve paths + author inputs (mode-specific) ────────────────────────────
if [[ "$MODE" == "session" ]]; then
  SID="$ID"
  DEMO_JSON_OUT="$REPO_ROOT/reports/goal-session-${SID}-demo.json"
  JOURNEY_HISTORY="$REPO_ROOT/runs/goal-session-${SID}/state/journey-history.json"
  AUTHOR_INPUTS=("$JOURNEY_HISTORY")
  FRONTEND_PRESENT="yes"   # a session walkthrough only makes sense with a UI
else
  PHASE="$ID"
  require_phase_arg "$PHASE"
  SPEC=$(phase_spec_path "$PHASE")
  if [[ -z "$SPEC" ]]; then
    echo "Error: No spec found for '$PHASE' in docs/phases/" >&2
    exit 1
  fi
  PLAN_FILE="$REPO_ROOT/runs/${PHASE}/plan.md"
  UI_TEST_PLAN="$REPO_ROOT/reports/phase-${PHASE}-ui-test-plan.md"
  WHAT_TO_CLICK="$REPO_ROOT/reports/phase-${PHASE}-what-to-click.md"
  USER_VISIBLE="$REPO_ROOT/reports/phase-${PHASE}-user-visible-changes.md"
  UI_TEST_RESULTS="$REPO_ROOT/reports/phase-${PHASE}-ui-test-results.md"
  AUTHOR_INPUTS=("$UI_TEST_PLAN" "$UI_TEST_RESULTS" "$WHAT_TO_CLICK" "$USER_VISIBLE" "$SPEC")

  DEMO_JSON_OUT="$REPO_ROOT/reports/phase-${PHASE}-demo.json"
  DEMO_SCRIPT_OUT="$REPO_ROOT/reports/phase-${PHASE}-demo-script.md"
  DEMO_RESULTS_OUT="$REPO_ROOT/reports/phase-${PHASE}-demo-results.md"
  DEMO_SHOTS_DIR="$REPO_ROOT/reports/demo/${PHASE}"

  FRONTEND_PRESENT="no"
  if detect_frontend_in_plan "$PLAN_FILE"; then
    FRONTEND_PRESENT="yes"
  fi
fi

# Backend-only stub helper (phase record mode only). Writes minimal valid
# artifacts so the renderer's demo loader sees a defined SKIPPED state.
_write_demo_backend_only_stubs() {
  mkdir -p "$REPO_ROOT/reports"
  cat > "$DEMO_SCRIPT_OUT" <<EOF
# Demo Script — ${PHASE}

**Mode:** record
**Status:** N/A — Backend-only iteration (Frontend Present: no)

This iteration made no user-visible changes; there is nothing to demonstrate in a browser.
EOF
  cat > "$DEMO_RESULTS_OUT" <<EOF
# Demo Results — ${PHASE}

**Demo Verdict:** SKIPPED
**Reason:** Backend-only iteration (Frontend Present: no). No browser walkthrough was performed.
EOF
}

# Author-crash stub (record mode): write a SKIPPED demo-results so the renderer
# has something to parse.
_write_demo_skipped_stub() {
  local reason="$1"
  if [[ ! -f "$DEMO_RESULTS_OUT" ]]; then
    mkdir -p "$REPO_ROOT/reports"
    cat > "$DEMO_RESULTS_OUT" <<EOF
# Demo Results — ${PHASE}

**Demo Verdict:** SKIPPED
**Reason:** ${reason}
EOF
  fi
}

echo "[demo] Running product demo for: $ID (mode: $MODE)"

# Backend-only (phase mode) — write stubs and exit cleanly.
if [[ "$MODE" != "session" && "$FRONTEND_PRESENT" == "no" ]]; then
  echo "[demo] Backend-only iteration — writing N/A stubs and skipping browser."
  _write_demo_backend_only_stubs
  echo "[demo] Done (backend-only)."
  exit 0
fi

# ── Ensure the app is running (idempotent; mirrors browser-qa-phase.sh) ──────
BACKEND_START_CMD="${CHAIN_START_BACKEND_CMD:-}"
FRONTEND_START_CMD="${CHAIN_START_FRONTEND_CMD:-}"
if [[ -z "$BACKEND_START_CMD" ]] && [[ -f "$REPO_ROOT/scripts/start-backend.sh" ]]; then
  BACKEND_START_CMD="bash $REPO_ROOT/scripts/start-backend.sh"
fi
if [[ -z "$FRONTEND_START_CMD" ]] && [[ -f "$REPO_ROOT/scripts/start-frontend.sh" ]]; then
  FRONTEND_START_CMD="bash $REPO_ROOT/scripts/start-frontend.sh"
fi

_BACKEND_PORT="${CHAIN_BACKEND_PORT:-8000}"
_FRONTEND_PORT="${CHAIN_FRONTEND_PORT:-3000}"
BACKEND_HEALTH_URL="${CHAIN_BACKEND_HEALTH_URL:-http://localhost:${_BACKEND_PORT}/health}"
FRONTEND_URL="${CHAIN_FRONTEND_URL:-http://localhost:${_FRONTEND_PORT}}"

if [[ "${CHAIN_SHARED_SERVICES:-false}" != "true" ]]; then
  QA_BACKEND_LOG=$(_qa_log_path "demo-backend")
  QA_FRONTEND_LOG=$(_qa_log_path "demo-frontend")
  export QA_BACKEND_HEALTH_URL="$BACKEND_HEALTH_URL"
  export QA_BACKEND_START_CMD="$BACKEND_START_CMD"
  export QA_BACKEND_LOG
  export QA_FRONTEND_URL="$FRONTEND_URL"
  export QA_FRONTEND_START_CMD="$FRONTEND_START_CMD"
  export QA_FRONTEND_LOG
  export QA_FRONTEND_REQUIRED="yes"
  ensure_services_running
fi

FRONTEND_RUNNING_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$FRONTEND_URL" 2>/dev/null || true)
if [[ ! "$FRONTEND_RUNNING_STATUS" =~ ^[23] ]]; then
  echo "[demo] Frontend at $FRONTEND_URL did not respond — recording SKIPPED and exiting." >&2
  if [[ "$MODE" == "record" ]]; then
    _write_demo_skipped_stub "Frontend at $FRONTEND_URL did not respond. No browser walkthrough was performed."
  fi
  exit 0
fi

cd "$REPO_ROOT"

# ── Stage 1: author the demo JSON (cached; skip if fresh) ────────────────────
if [[ "$REAUTHOR" != "yes" ]] && _demo_json_fresh "$DEMO_JSON_OUT" "${AUTHOR_INPUTS[@]}"; then
  echo "[demo] Reusing cached demo script: $(basename "$DEMO_JSON_OUT") (pass --reauthor to rebuild)."
else
  require_claude
  export CHAIN_CURRENT_AGENT=demo-narrator
  export CHAIN_CLAUDE_PRE_RETRY_HOOK="ensure_services_running"
  _author_rc=0
  if [[ "$MODE" == "session" ]]; then
    claude_with_quota_retry -p "You are the demo-narrator agent.

mode: session
Session id: $SID
Frontend URL: $FRONTEND_URL
Agent instructions: .claude/agents/demo-narrator.md  <-- read this first
(CLAUDE.md is already in your system prompt — do not Read it again.)

Demo JSON output path: $DEMO_JSON_OUT  <-- write your strict-JSON demo script here

Journey history: $JOURNEY_HISTORY
Recover each passing journey's concrete steps from its last_passing_iter's
reports/phase-<iter>-what-to-click.md and ui-test-plan.md (use Glob to find them).

Write ONLY the JSON file at the output path. Do NOT open a browser. When done, STOP." || _author_rc=$?
  else
    claude_with_quota_retry -p "You are the demo-narrator agent.

mode: $MODE
Phase id: $PHASE
Frontend URL: $FRONTEND_URL
Agent instructions: .claude/agents/demo-narrator.md  <-- read this first
(CLAUDE.md is already in your system prompt — do not Read it again.)

Demo JSON output path: $DEMO_JSON_OUT  <-- write your strict-JSON demo script here

Inputs (read only what exists):
  UI test plan:        $UI_TEST_PLAN
  UI test results:     $UI_TEST_RESULTS
  What to click:       $WHAT_TO_CLICK
  User-visible changes: $USER_VISIBLE
  Iter spec:           $SPEC

Write ONLY the JSON file at the output path. Do NOT open a browser. When done, STOP." || _author_rc=$?
  fi

  # Signal exit — propagate unchanged (resume logic re-runs). Do not stub.
  if [[ $_author_rc -eq 130 || $_author_rc -eq 137 || $_author_rc -eq 143 ]]; then
    echo "[demo] Killed by signal (exit $_author_rc) — leaving artifacts untouched." >&2
    exit "$_author_rc"
  fi
  # Quota exhaustion — propagate unchanged so the outer retry loop handles it.
  if [[ $_author_rc -eq ${QUOTA_EXHAUSTED_EXIT_CODE:-75} ]]; then
    echo "[demo] Quota exhausted (exit $_author_rc) — propagating." >&2
    exit "$_author_rc"
  fi
  if [[ $_author_rc -ne 0 || ! -f "$DEMO_JSON_OUT" ]]; then
    echo "[demo] author did not produce a demo script (rc $_author_rc) — showcase skipped." >&2
    if [[ "$MODE" == "record" ]]; then
      _write_demo_skipped_stub "demo-narrator did not produce a demo script (rc $_author_rc). Re-run \`./scripts/automation/demo-phase.sh $PHASE\` to retry."
    fi
    exit 0
  fi
fi

# ── Stage 2: run the deterministic runner ────────────────────────────────────
RUNNER_MODE="$MODE"
[[ "$MODE" == "session" ]] && RUNNER_MODE="session-live"

RUNNER_ARGS=(--json "$DEMO_JSON_OUT" --mode "$RUNNER_MODE" --base-url "$FRONTEND_URL"
             --repo-root "$REPO_ROOT" --phase-id "$ID")
if [[ "$MODE" == "record" ]]; then
  mkdir -p "$DEMO_SHOTS_DIR"
  RUNNER_ARGS+=(--out-dir "$DEMO_SHOTS_DIR" --results "$DEMO_RESULTS_OUT" --script-fallback "$DEMO_SCRIPT_OUT")
fi
[[ "${CHAIN_DEMO_VIDEO:-}"   =~ ^(1|true|yes|TRUE|YES)$ ]] && RUNNER_ARGS+=(--video)
[[ "${CHAIN_DEMO_CAPTION:-}" =~ ^(1|true|yes|TRUE|YES)$ ]] && RUNNER_ARGS+=(--caption)

_runner_rc=0
python3 "$RUNNER" "${RUNNER_ARGS[@]}" || _runner_rc=$?

case "$_runner_rc" in
  0) ;;
  3) echo "[demo] Playwright not available (see install hint above) — showcase skipped." >&2 ;;
  4) echo "[demo] Live demo needs a display. View the recorded gallery instead: ./scripts/automation/demo.sh $ID" >&2 ;;
  130|137|143)
     echo "[demo] interrupted (exit $_runner_rc)." >&2; exit "$_runner_rc" ;;
  *) echo "[demo] runner exited $_runner_rc (showcase, non-gating)." >&2 ;;
esac

if [[ "$MODE" == "record" ]]; then
  echo "[demo] Done. Script: $DEMO_SCRIPT_OUT"
  echo "[demo]       Results: $DEMO_RESULTS_OUT"
  echo "[demo]       Gallery: $DEMO_SHOTS_DIR/"
else
  echo "[demo] Walkthrough complete."
fi
exit 0
