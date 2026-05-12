#!/usr/bin/env bash
# render-summary.sh — Regenerate the iteration summary MD and HTML report.
#
# Usage:
#   ./scripts/automation/render-summary.sh <phase-id>
#   ./scripts/automation/render-summary.sh <phase-id> --no-resummarize
#   ./scripts/automation/render-summary.sh --session-index <session-id>
#
# Flow:
#   1. Invokes the iteration-summarizer agent to (re)write
#      reports/phase-<phase-id>-iteration-summary.md  -- uses API tokens.
#      The --no-resummarize flag skips this step (offline re-render).
#   2. Runs the HTML renderer to (re)produce
#      reports/phase-<phase-id>-summary.html.
#
# --session-index <sid> regenerates only the session-level
# reports/goal-session-<sid>-index.html. It links to per-iter
# summary HTML files already on disk and does not invoke the agent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

RENDERER="$SCRIPT_DIR/lib/render_iteration_summary.py"

if [[ ! -f "$RENDERER" ]]; then
  echo "Error: renderer not found at $RENDERER" >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Usage:"
  echo "  $0 <phase-id> [--no-resummarize]"
  echo "  $0 --session-index <session-id>"
  exit 2
fi

# Session-index mode — no agent involved.
if [[ "$1" == "--session-index" ]]; then
  if [[ $# -lt 2 ]]; then
    echo "Error: --session-index requires a session id" >&2
    exit 2
  fi
  exec python3 "$RENDERER" session-index "$2" --repo-root="$REPO_ROOT"
fi

PHASE="$1"
shift
NO_RESUMMARIZE=false
for arg in "$@"; do
  case "$arg" in
    --no-resummarize) NO_RESUMMARIZE=true ;;
    *) echo "Warning: unknown flag $arg" >&2 ;;
  esac
done

SUMMARY_MD="$REPO_ROOT/reports/phase-${PHASE}-iteration-summary.md"

if [[ "$NO_RESUMMARIZE" == "false" ]]; then
  require_claude
  bash "$SCRIPT_DIR/lib/quota-retry.sh" --check 2>/dev/null || true
  # shellcheck source=lib/quota-retry.sh
  source "$SCRIPT_DIR/lib/quota-retry.sh"

  mkdir -p "$REPO_ROOT/reports"
  echo "[render-summary] Invoking iteration-summarizer for $PHASE..."

  # Pre-trim evaluator-log.md to last 300 lines if it exists for the session
  # this phase belongs to (goal mode). For phase mode there is no log.
  EVAL_LOG_INLINE=""
  if [[ "$PHASE" =~ ^goal-(.+)-iter-[0-9]+$ ]]; then
    SID="${BASH_REMATCH[1]}"
    LOG_FILE="$REPO_ROOT/runs/goal-session-${SID}/state/evaluator-log.md"
    if [[ -f "$LOG_FILE" ]]; then
      EVAL_LOG_INLINE=$(tail -n 300 "$LOG_FILE")
    fi
  fi

  PROMPT="You are the iteration-summarizer agent.

Phase id: $PHASE
Output path: $SUMMARY_MD
Agent instructions: .claude/agents/iteration-summarizer.md  <-- read this first
Template: templates/iteration-summary.md  <-- exact section structure your output must follow
(CLAUDE.md is already in your system prompt -- do not Read it again.)

Apply the TOKEN AND QUESTIONING POLICY from .claude/core.md strictly.

Read every relevant input listed in your agent instructions. Files that don't
exist should be silently skipped -- do not warn, do not ask. Use what is
present. The dispatch wrapper has already pre-trimmed evaluator-log.md to its
last 300 lines (below) so you do not need to read that file directly.

Recent evaluator log entries (last 300 lines, pre-trimmed):
---
${EVAL_LOG_INLINE:-(none — phase mode or log not present)}
---

Write the iteration summary to: $SUMMARY_MD

Follow the section structure in templates/iteration-summary.md EXACTLY -- the
HTML renderer keys off the section headings. The verdict line must match the
form '**Verdict:** VALUE' where VALUE is one of: GOAL_ACHIEVED, CONTINUE,
ESCALATE, REGRESSION, STALLED, PASS, FAIL, IN-PROGRESS.

When finished, STOP. Do not print the summary to chat."

  claude_with_quota_retry -p "$PROMPT" \
    || echo "[render-summary] Warning: iteration-summarizer call failed (non-blocking; HTML will still render)."

  if [[ -f "$SUMMARY_MD" ]]; then
    echo "[render-summary] Summary MD: $SUMMARY_MD"
  fi
fi

# Always render HTML (even if MD missing — renderer emits a placeholder).
python3 "$RENDERER" iteration "$PHASE" --repo-root="$REPO_ROOT"
