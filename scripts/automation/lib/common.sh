#!/usr/bin/env bash
# Shared functions for automation scripts

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# Validate phase argument
require_phase_arg() {
  if [[ -z "$1" ]]; then
    echo "Usage: $0 <phase-id>" >&2
    echo "  Example: $0 phase-3" >&2
    exit 1
  fi
}

# Check claude CLI is available
require_claude() {
  if ! command -v claude &>/dev/null; then
    echo "Error: 'claude' CLI not found. Install Claude Code." >&2
    exit 1
  fi
}

# Check gh CLI is available and authenticated (hard exit on failure)
require_gh_auth() {
  if ! command -v gh &>/dev/null; then
    echo "Error: 'gh' CLI not found. Install GitHub CLI: https://cli.github.com" >&2
    exit 1
  fi
  if ! gh auth status &>/dev/null; then
    echo "Error: gh CLI is not authenticated. Run: gh auth login" >&2
    exit 1
  fi
}

# Returns 0 if gh is available and authenticated, 1 otherwise (non-fatal)
check_gh_auth() {
  command -v gh &>/dev/null && gh auth status &>/dev/null
}

# Return path to phase spec file (searches docs/phases/)
phase_spec_path() {
  local phase="$1"
  local candidates=(
    "$REPO_ROOT/docs/phases/${phase}.md"
    "$REPO_ROOT/docs/phases/${phase}-*.md"
  )
  for c in "${candidates[@]}"; do
    for f in $c; do
      if [[ -f "$f" ]]; then
        echo "$f"
        return 0
      fi
    done
  done
  echo ""
}

# Returns 0 (true) if report file exists and contains a PASS or PASS_WITH_NOTES verdict
verdict_passes() {
  local report_file="${1:-}"
  [[ -f "$report_file" ]] || return 1
  grep -qE "^\*\*Verdict:\*\* (PASS|PASS WITH NOTES|PASS WITH GAPS|PASS_WITH_NOTES|PASS_WITH_GAPS)" "$report_file" 2>/dev/null
}

# Update runs/<phase>/status.json with new status and step
update_status() {
  local phase="$1"
  local new_status="$2"
  local new_step="$3"
  local run_dir="$REPO_ROOT/runs/$phase"
  mkdir -p "$run_dir"
  python3 -c "
import json, datetime, os, sys
f = '${run_dir}/status.json'
d = {}
if os.path.exists(f):
    try:
        with open(f) as fp: d = json.load(fp)
    except Exception: pass
now = datetime.datetime.utcnow().isoformat() + 'Z'
d.update({'phase': '${phase}', 'status': '${new_status}', 'current_step': '${new_step}', 'updated_at': now})
for k, v in [('started_at', now), ('blockers', []), ('changed_files', []), ('tests_run', False), ('browser_checks_run', False), ('next_action', 'none')]:
    d.setdefault(k, v)
with open(f, 'w') as fp:
    json.dump(d, fp, indent=2)
    fp.write('\n')
" 2>/dev/null || echo "Warning: could not update status.json" >&2
}

# Read current_step from runs/<phase>/status.json (empty string if not found)
get_current_step() {
  local phase="$1"
  local status_file="$REPO_ROOT/runs/$phase/status.json"
  if [[ -f "$status_file" ]]; then
    python3 -c "
import json, sys
try:
    with open('$status_file') as f:
        print(json.load(f).get('current_step', ''))
except Exception:
    print('')
" 2>/dev/null
  fi
}

# Returns 0 if runs/<phase>/summary.json has status: "finalized"
is_finalized() {
  local phase="$1"
  local summary_file="$REPO_ROOT/runs/$phase/summary.json"
  if [[ ! -f "$summary_file" ]]; then return 1; fi
  python3 -c "
import json, sys
try:
    with open('$summary_file') as f:
        sys.exit(0 if json.load(f).get('status') == 'finalized' else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null
}

# Source quota-retry helpers (defines claude_with_quota_retry)
# shellcheck source=quota-retry.sh
source "$(dirname "${BASH_SOURCE[0]}")/quota-retry.sh"

# Ensure runs/<phase>/ directory exists with initial status.json
init_run_dir() {
  local phase="$1"
  local run_dir="$REPO_ROOT/runs/$phase"
  mkdir -p "$run_dir"
  if [[ ! -f "$run_dir/status.json" ]]; then
    update_status "$phase" "in_progress" "init"
    echo "Initialized $run_dir/status.json"
  fi
}
