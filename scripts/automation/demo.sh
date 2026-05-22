#!/usr/bin/env bash
# demo.sh — On-demand demo viewer / runner.
#
# Usage:
#   ./scripts/automation/demo.sh <id>                   # open recorded gallery
#   ./scripts/automation/demo.sh <id> --replay          # alias for default
#   ./scripts/automation/demo.sh <id> --delivered       # open delivered wrap
#   ./scripts/automation/demo.sh <id> --live            # live walkthrough of one iteration
#   ./scripts/automation/demo.sh <sid> --session-live   # live walkthrough of the WHOLE product
#   ./scripts/automation/demo.sh --latest               # open most recent gallery
#   ./scripts/automation/demo.sh --help                 # show this help
#
# <id> may be either a phase-id (e.g. `phase-1`, `goal-money-iter-3`) or a
# goal session-id (e.g. `money-first`). The default mode auto-detects which by
# checking for matching HTML files in reports/.
#
# Modes:
#   default / --replay : Open the saved HTML gallery in the system browser.
#                        Tries, in order: phase-<id>-summary.html, then
#                        goal-session-<id>-index.html. Errors if none found.
#   --delivered        : Open the one-time `delivered.html` wrap for the
#                        session with id <id> (only valid for goal sessions
#                        that hit GOAL_ACHIEVED).
#   --live             : Delegate to demo-phase.sh <id> --live — the
#                        deterministic Playwright runner drives a visible Chrome
#                        window step-by-step (press Enter to advance). Boots the
#                        app if not running.
#   --session-live     : Delegate to demo-phase.sh <sid> --session — a live
#                        walkthrough of the WHOLE working product across all
#                        iterations (every passing journey).
#   --latest           : Find the most recently modified summary HTML under
#                        reports/ and open it.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ── Parse arguments ────────────────────────────────────────────────────────
TARGET_ID=""
MODE="replay"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <id> [--live|--replay|--delivered]  |  $0 --latest" >&2
  echo "       $0 --help for full usage." >&2
  exit 2
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      sed -n '3,/^set -e/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1
      exit 0
      ;;
    --live)
      MODE="live"; shift
      ;;
    --session-live)
      MODE="session-live"; shift
      ;;
    --replay)
      MODE="replay"; shift
      ;;
    --delivered)
      MODE="delivered"; shift
      ;;
    --latest)
      MODE="latest"; shift
      ;;
    --*)
      echo "Error: unknown flag '$1'" >&2
      exit 2
      ;;
    *)
      if [[ -z "$TARGET_ID" ]]; then
        TARGET_ID="$1"
      else
        echo "Error: unexpected extra argument '$1'" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

# ── Open helper — uses xdg-open / open / wslview / nothing ─────────────────
_open_html() {
  local html="$1"
  if [[ ! -f "$html" ]]; then
    echo "Error: $html does not exist." >&2
    return 1
  fi
  echo "[demo] Opening $html"
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$html" >/dev/null 2>&1 || true
  elif command -v open >/dev/null 2>&1; then
    open "$html" >/dev/null 2>&1 || true
  elif command -v wslview >/dev/null 2>&1; then
    wslview "$html" >/dev/null 2>&1 || true
  else
    echo "[demo] No xdg-open / open / wslview — copy the path manually:"
    echo "       file://$html"
  fi
}

# ── Mode dispatch ──────────────────────────────────────────────────────────
case "$MODE" in
  latest)
    LATEST=$(ls -t "$REPO_ROOT/reports/"*-summary.html "$REPO_ROOT/reports/"goal-session-*-index.html 2>/dev/null | head -n 1 || true)
    if [[ -z "$LATEST" ]]; then
      echo "Error: no rendered HTML found under $REPO_ROOT/reports/" >&2
      exit 1
    fi
    _open_html "$LATEST"
    ;;

  delivered)
    [[ -z "$TARGET_ID" ]] && { echo "Error: --delivered requires a session id." >&2; exit 2; }
    HTML="$REPO_ROOT/reports/goal-session-${TARGET_ID}-delivered.html"
    if [[ ! -f "$HTML" ]]; then
      echo "Error: $HTML not found." >&2
      echo "       (Delivered wraps are produced on GOAL_ACHIEVED; not all sessions have one.)" >&2
      exit 1
    fi
    _open_html "$HTML"
    ;;

  live)
    [[ -z "$TARGET_ID" ]] && { echo "Error: --live requires a phase id." >&2; exit 2; }
    DEMO_SH="$SCRIPT_DIR/demo-phase.sh"
    if [[ ! -x "$DEMO_SH" && ! -f "$DEMO_SH" ]]; then
      echo "Error: $DEMO_SH not found." >&2
      exit 1
    fi
    echo "[demo] Launching live walkthrough via demo-phase.sh $TARGET_ID --live"
    exec bash "$DEMO_SH" "$TARGET_ID" --live
    ;;

  session-live)
    [[ -z "$TARGET_ID" ]] && { echo "Error: --session-live requires a session id." >&2; exit 2; }
    DEMO_SH="$SCRIPT_DIR/demo-phase.sh"
    if [[ ! -f "$DEMO_SH" ]]; then
      echo "Error: $DEMO_SH not found." >&2
      exit 1
    fi
    echo "[demo] Launching whole-product walkthrough via demo-phase.sh $TARGET_ID --session"
    exec bash "$DEMO_SH" "$TARGET_ID" --session
    ;;

  replay|*)
    [[ -z "$TARGET_ID" ]] && { echo "Error: <id> is required for replay." >&2; exit 2; }
    # Try, in order: iteration HTML, session index HTML.
    ITER_HTML="$REPO_ROOT/reports/phase-${TARGET_ID}-summary.html"
    SESSION_HTML="$REPO_ROOT/reports/goal-session-${TARGET_ID}-index.html"
    if [[ -f "$ITER_HTML" ]]; then
      _open_html "$ITER_HTML"
    elif [[ -f "$SESSION_HTML" ]]; then
      _open_html "$SESSION_HTML"
    else
      echo "Error: no rendered HTML for id '$TARGET_ID'." >&2
      echo "       Looked for:" >&2
      echo "         $ITER_HTML" >&2
      echo "         $SESSION_HTML" >&2
      echo "       Run a phase / goal session first, or use --latest to pick the most recent." >&2
      exit 1
    fi
    ;;
esac
