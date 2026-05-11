#!/usr/bin/env bash
# render-summary.sh — regenerate the human-readable HTML summary for an
# iteration or a goal-mode session.
#
# Usage:
#   ./scripts/automation/render-summary.sh <phase-id>
#   ./scripts/automation/render-summary.sh --session-index <session-id>
#
# Re-reads existing markdown artifacts (closure-verdict, user-visible-changes,
# what-to-click, ui-test-results, journey-history) and writes:
#   - runs/<phase-id>/summary.html               (iteration mode)
#   - runs/goal-session-<sid>/index.html         (--session-index mode)
#
# Safe to run any time; non-blocking. Useful after hand-editing source MDs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENDERER="$SCRIPT_DIR/lib/render_iteration_summary.py"

if [[ ! -f "$RENDERER" ]]; then
  echo "Error: renderer not found at $RENDERER" >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Usage:"
  echo "  $0 <phase-id>"
  echo "  $0 --session-index <session-id>"
  exit 2
fi

if [[ "$1" == "--session-index" ]]; then
  if [[ $# -lt 2 ]]; then
    echo "Error: --session-index requires a session id" >&2
    exit 2
  fi
  exec python3 "$RENDERER" session-index "$2"
else
  exec python3 "$RENDERER" iteration "$1"
fi
