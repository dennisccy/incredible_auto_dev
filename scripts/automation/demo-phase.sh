#!/usr/bin/env bash
# demo-phase.sh — Run the per-iteration product demo (showcase, not QA).
#
# Usage:
#   ./scripts/automation/demo-phase.sh <phase-id>            # record mode (default)
#   ./scripts/automation/demo-phase.sh <phase-id> --live     # live walkthrough
#
# Modes:
#   record  → demo-narrator walks every working journey end-to-end against the
#             currently-running app, capturing a captioned screenshot gallery to
#             reports/demo/<phase-id>/ and writing demo-script.md +
#             demo-results.md. Steps added or changed this iteration are flagged
#             [NEW] in the script and gallery. Re-uses the app already booted by
#             browser-qa-phase.sh in the standard pipeline (idempotent
#             ensure_services_running is a no-op when the app is warm); boots
#             once when run standalone.
#   live    → demo-narrator drives a visible Chrome window in real time,
#             narrating each step to chat and pausing between steps. Writes no
#             artifacts. Intended for on-demand viewing by a non-technical
#             owner.
#
# Showcase, not gate: a failed step is a soft note in demo-results, never a hard
# pipeline fail. On agent crash or stream timeout the script writes a SKIPPED
# stub so the renderer still has something to read, then exits 0 (signal exits
# and quota propagate unchanged — same policy as browser-qa-phase.sh).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

PHASE="${1:-}"
require_phase_arg "$PHASE"

MODE="record"
if [[ "${2:-}" == "--live" ]]; then
  MODE="live"
fi

require_claude

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

DEMO_SCRIPT_OUT="$REPO_ROOT/reports/phase-${PHASE}-demo-script.md"
DEMO_RESULTS_OUT="$REPO_ROOT/reports/phase-${PHASE}-demo-results.md"
DEMO_SHOTS_DIR="$REPO_ROOT/reports/demo/${PHASE}"

# Backend-only stub helper. Writes minimal valid artifacts so the renderer's
# IterationData.demo_steps loader sees a defined SKIPPED state.
_write_demo_backend_only_stubs() {
  mkdir -p "$REPO_ROOT/reports"
  if [[ ! -f "$DEMO_SCRIPT_OUT" ]]; then
    cat > "$DEMO_SCRIPT_OUT" <<EOF
# Demo Script — ${PHASE}

**Mode:** record
**Status:** N/A — Backend-only iteration (Frontend Present: no)

This iteration made no user-visible changes; there is nothing to demonstrate in a browser.
EOF
  fi
  if [[ ! -f "$DEMO_RESULTS_OUT" ]]; then
    cat > "$DEMO_RESULTS_OUT" <<EOF
# Demo Results — ${PHASE}

**Demo Verdict:** SKIPPED
**Reason:** Backend-only iteration (Frontend Present: no). No browser walkthrough was performed.
EOF
  fi
}

# Agent-crash stub helper. Writes only the demo-results stub when the agent
# exited non-zero without producing one; preserves any partial files the agent
# did write.
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

echo "[demo] Running product demo for: $PHASE (mode: $MODE)"

# Detect frontend present per the plan
FRONTEND_PRESENT="no"
if detect_frontend_in_plan "$PLAN_FILE"; then
  FRONTEND_PRESENT="yes"
fi

# Backend-only — write stubs and exit cleanly (mirrors browser-qa-phase.sh).
if [[ "$FRONTEND_PRESENT" == "no" ]]; then
  echo "[demo] Backend-only iteration — writing N/A stubs and skipping browser."
  _write_demo_backend_only_stubs
  echo "[demo] Done (backend-only)."
  exit 0
fi

# Live mode without artifacts but still needs the app running.
# Record mode also needs the app running.

# ── Resolve start commands (mirrors browser-qa-phase.sh) ───────────────────
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

# Idempotent boot. ensure_services_running is a no-op when ports are already
# answering, so the standard pipeline (where browser-qa-phase.sh just booted
# them moments ago) does NOT pay a second boot.
# When CHAIN_SHARED_SERVICES=true (run-phase.sh --fast fanout), the caller has
# already booted services and owns the EXIT-time teardown — skip the boot.
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
if [[ "$FRONTEND_RUNNING_STATUS" =~ ^[23] ]]; then
  FRONTEND_AVAILABLE="yes"
else
  FRONTEND_AVAILABLE="no"
  echo "[demo] Frontend not available — recording SKIPPED stub and exiting."
  if [[ "$MODE" == "record" ]]; then
    _write_demo_skipped_stub "Frontend at $FRONTEND_URL did not respond. No browser walkthrough was performed."
  fi
  exit 0
fi

# Pre-retry hook so a long quota sleep does not leave services dead.
export CHAIN_CLAUDE_PRE_RETRY_HOOK="ensure_services_running"

mkdir -p "$DEMO_SHOTS_DIR"

# ── Run the demo-narrator agent ────────────────────────────────────────────
cd "$REPO_ROOT"
_demo_rc=0

export CHAIN_CURRENT_AGENT=demo-narrator

if [[ "$MODE" == "live" ]]; then
  # Live mode: agent narrates to chat and drives a visible browser. No
  # artifacts. We still go through claude_with_quota_retry so the same quota
  # handling applies; the watcher sees narration in chat.
  claude_with_quota_retry -p "You are the demo-narrator agent.

mode: live
Phase id: $PHASE
Frontend URL: $FRONTEND_URL
Frontend available: yes
Agent instructions: .claude/agents/demo-narrator.md  <-- read this first
Skill: .claude/skills/browser-workflow-executor.md  <-- Chrome MCP technique
(CLAUDE.md is already in your system prompt — do not Read it again.)

UI test plan:        $UI_TEST_PLAN
What to click:       $WHAT_TO_CLICK
User-visible changes: $USER_VISIBLE
Browser QA results:  $UI_TEST_RESULTS
Iter spec:           $SPEC

This is the LIVE walkthrough mode. Drive a visible Chrome window via
mcp__plugin_superpowers-chrome_chrome__use_browser. Print plain-language
narration to chat before each action. Pause briefly between steps so the
watching owner can follow. Write NO files, take NO screenshots. After the
last step, print 'Demo complete'. Then STOP." || _demo_rc=$?
else
  # Record mode: agent walks the product, takes screenshots, writes the two
  # artifacts.
  claude_with_quota_retry -p "You are the demo-narrator agent.

mode: record
Phase id: $PHASE
Frontend URL: $FRONTEND_URL
Frontend available: yes
Agent instructions: .claude/agents/demo-narrator.md  <-- read this first
Skill: .claude/skills/browser-workflow-executor.md  <-- Chrome MCP technique
(CLAUDE.md is already in your system prompt — do not Read it again.)

UI test plan:        $UI_TEST_PLAN
What to click:       $WHAT_TO_CLICK
User-visible changes: $USER_VISIBLE
Browser QA results:  $UI_TEST_RESULTS
Iter spec:           $SPEC

Output paths (overwrite if present):
  Demo script:   $DEMO_SCRIPT_OUT
  Demo results:  $DEMO_RESULTS_OUT
  Screenshots:   $DEMO_SHOTS_DIR/step-NN.png  (one per Highlights step)

Follow the section structures in templates/demo-script.md and
templates/demo-results.md EXACTLY — the HTML renderer keys off these.

Showcase, not QA. A step whose on-screen result did not match its Point-out
becomes a soft note in demo-results, never a hard failure. Never block the
pipeline.

The demo-results MUST contain a line matching the regex
'^\\*\\*Demo Verdict:\\*\\*\\s+(RECORDED|RECORDED_WITH_NOTES|SKIPPED|NOT_YET)\\s*\$'.

When finished, STOP." || _demo_rc=$?
fi

# Signal exit (Ctrl-C / SIGTERM / SIGKILL) — propagate unchanged so resume
# logic in the outer loop can re-run. Do NOT write stubs (would falsely
# advertise the step as done). Mirrors browser-qa-phase.sh:208-211.
if [[ $_demo_rc -eq 130 || $_demo_rc -eq 137 || $_demo_rc -eq 143 ]]; then
  echo "[demo] Killed by signal (exit $_demo_rc) — leaving artifacts untouched." >&2
  exit "$_demo_rc"
fi

# Quota exhaustion (exit 75) — propagate unchanged so the outer retry loop
# handles it. Mirrors browser-qa-phase.sh:216-217.
if [[ $_demo_rc -eq ${QUOTA_EXHAUSTED_EXIT_CODE:-75} ]]; then
  echo "[demo] Quota exhausted (exit $_demo_rc) — propagating." >&2
  exit "$_demo_rc"
fi

# Any other non-zero in record mode → soft-fail with stub so the renderer has
# something to parse, then exit 0. The pipeline never halts on the demo.
if [[ "$MODE" == "record" && $_demo_rc -ne 0 ]]; then
  echo "[demo] demo-narrator exited with code $_demo_rc — writing SKIPPED stub." >&2
  _write_demo_skipped_stub "demo-narrator exited with code $_demo_rc. Showcase-only — pipeline continues. Re-run \`./scripts/automation/demo-phase.sh $PHASE\` to retry."
  echo "[demo] Done (stub written)."
  exit 0
fi

# Live mode soft-fail: just log and exit 0.
if [[ "$MODE" == "live" && $_demo_rc -ne 0 ]]; then
  echo "[demo] live walkthrough ended with code $_demo_rc — see chat above." >&2
  exit 0
fi

if [[ "$MODE" == "record" ]]; then
  echo "[demo] Done. Script: $DEMO_SCRIPT_OUT"
  echo "[demo]       Results: $DEMO_RESULTS_OUT"
  echo "[demo]       Gallery: $DEMO_SHOTS_DIR/"
else
  echo "[demo] Live walkthrough complete."
fi
