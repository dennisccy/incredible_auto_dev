#!/usr/bin/env bash
# Stop hook: reminder to check artifacts if a phase run is in progress
STATUS_FILES=(runs/*/status.json)

for f in "${STATUS_FILES[@]}"; do
  if [[ -f "$f" ]]; then
    STATUS=$(python3 -c "import json,sys; d=json.load(open('$f')); print(d.get('status',''))" 2>/dev/null)
    if [[ "$STATUS" == "in_progress" ]]; then
      echo "Notice: phase run in progress at $f — status=in_progress"
    fi
  fi
done

# ── Check for missing UI visibility artifacts ─────────────────────────────
# Warn if a phase is past review_passed but UI artifacts are missing.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

UI_ARTIFACT_WARNING=false
for status_file in "$REPO_ROOT"/runs/*/status.json; do
  [[ -f "$status_file" ]] || continue
  PHASE_ID=$(python3 -c "
import json, sys
try:
    with open('$status_file') as f:
        d = json.load(f)
    step = d.get('current_step', '')
    status = d.get('status', '')
    # Only warn for active phases past review stage
    past_review = step in ('review_passed', 'ui_impact_complete', 'ui_test_designed',
                           'browser_qa_complete', 'qa_passed', 'ux_regression_complete',
                           'audit_passed', 'closure_passed')
    if past_review and status in ('in_progress', 'complete'):
        print(d.get('phase', ''))
except Exception:
    pass
" 2>/dev/null || true)

  [[ -z "$PHASE_ID" ]] && continue

  # Check if UI artifacts are missing
  MISSING_UI=()
  for artifact in implementation-summary user-visible-changes ui-surface-map ui-test-plan ui-test-results what-to-click; do
    f="$REPO_ROOT/reports/phase-${PHASE_ID}-${artifact}.md"
    [[ -f "$f" ]] || MISSING_UI+=("$artifact")
  done

  if [[ ${#MISSING_UI[@]} -gt 0 ]]; then
    echo "[on-stop] NOTE: Phase '$PHASE_ID' is past review stage but missing UI visibility artifacts:"
    for m in "${MISSING_UI[@]}"; do
      echo "[on-stop]   Missing: reports/phase-${PHASE_ID}-${m}.md"
    done
    echo "[on-stop]   Run: ./scripts/automation/ui-impact-phase.sh $PHASE_ID"
    UI_ARTIFACT_WARNING=true
  fi
done

exit 0
