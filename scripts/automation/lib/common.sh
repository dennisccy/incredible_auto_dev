#!/usr/bin/env bash
# Shared functions for automation scripts

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# Lightweight logger shared by every script that sources common.sh.
# Scripts (e.g. run-phase.sh) that want a custom prefix can define their own
# `log` after sourcing common.sh — the later definition shadows this one.
if ! declare -F log >/dev/null 2>&1; then
  log() { echo "[automation] $*"; }
fi

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

# Returns 0 (true) if report file exists and contains a passing verdict line.
# Passing verdicts and their exact format are defined in verdicts.py.
verdict_passes() {
  local report_file="${1:-}"
  [[ -f "$report_file" ]] || return 1
  python3 "$(dirname "${BASH_SOURCE[0]}")/verdicts.py" check-verdict "$report_file" 2>/dev/null
}

# Update runs/<phase>/status.json with new status and step.
# Both new_status and new_step are validated against verdicts.py enums before writing.
update_status() {
  local phase="$1"
  local new_status="$2"
  local new_step="$3"
  local _verdicts_py
  _verdicts_py="$(dirname "${BASH_SOURCE[0]}")/verdicts.py"
  if ! python3 "$_verdicts_py" validate-status "$new_status" 2>&1; then
    echo "update_status: aborting due to invalid status value" >&2
    return 1
  fi
  if ! python3 "$_verdicts_py" validate-step "$new_step" 2>&1; then
    echo "update_status: aborting due to invalid step value" >&2
    return 1
  fi
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
now = datetime.datetime.now(datetime.UTC).isoformat().replace('+00:00', 'Z')
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

# Deterministic port offset (0..999) derived from the project directory so that
# multiple projects sharing this subtree each land in their own port range.
# Normalizes to the project root (strips trailing /incredible_auto_dev) so the
# auto chain and manual dev.sh produce the same offset for a given project.
_project_port_offset() {
  local project_root="$REPO_ROOT"
  [[ "$project_root" == */incredible_auto_dev ]] && project_root="${project_root%/incredible_auto_dev}"
  local hex
  hex=$(printf '%s' "$project_root" | sha1sum | cut -c1-4)
  echo $((16#$hex % 1000))
}

# Scan upward from $1 to find the first port not currently LISTENing.
# Handles the case where the hashed preferred port is already in use (e.g. a
# previous run of the same project left a server behind).
_find_free_port() {
  local port="$1"
  local attempts=0
  while [[ $attempts -lt 100 ]]; do
    if ! ss -tln 2>/dev/null | grep -q ":${port} "; then
      echo "$port"
      return 0
    fi
    port=$((port + 1))
    attempts=$((attempts + 1))
  done
  echo "$1"
}

# Assign CHAIN_BACKEND_PORT and CHAIN_FRONTEND_PORT deterministically per-project.
# Respects any caller-provided values; otherwise picks free ports based on
# 8000 + hash($REPO_ROOT) for backend and 3000 + same-hash for frontend.
# Idempotent — safe to call from both run-phase.sh and dev.sh.
ensure_phase_ports() {
  local offset
  offset=$(_project_port_offset)
  if [[ -z "${CHAIN_BACKEND_PORT:-}" ]]; then
    export CHAIN_BACKEND_PORT=$(_find_free_port $((8000 + offset)))
  fi
  if [[ -z "${CHAIN_FRONTEND_PORT:-}" ]]; then
    export CHAIN_FRONTEND_PORT=$(_find_free_port $((3000 + offset)))
  fi
}

# Kill any servers started by agents on the assigned phase ports.
# Call between pipeline steps to prevent zombie servers from blocking the next step.
kill_phase_servers() {
  local backend_port="${CHAIN_BACKEND_PORT:-8000}"
  local frontend_port="${CHAIN_FRONTEND_PORT:-3000}"
  for port in $backend_port $frontend_port; do
    fuser -k -9 "$port/tcp" 2>/dev/null || true
  done
}

# Clear any stale Next.js dev server that would block a fresh start.
# Next.js 16+ writes .next/dev/lock with its own PID and refuses to start a
# second dev server from the same directory — even on a different port. Just
# killing by port or by ".*:$PORT" cmdline substring is NOT sufficient because
# the stale server may be bound to a different port. This helper:
#   1. Reads the PID from .next/dev/lock and kills it if alive.
#   2. Kills any next-server process whose /proc/<pid>/cwd points at this
#      frontend directory (defensive — lock file may be absent or outdated).
#   3. Removes the lock file so the fresh start has a clean slate.
# Usage: kill_stale_next_dev_server [frontend_dir]
kill_stale_next_dev_server() {
  local fe_dir="${1:-${CHAIN_FRONTEND_DIR:-$REPO_ROOT/apps/frontend}}"
  local lock="$fe_dir/.next/dev/lock"
  local killed_any=0

  # 1. Kill PID stored in .next/dev/lock if still alive
  if [[ -f "$lock" ]]; then
    local lock_pid
    lock_pid=$(python3 -c "import json,sys
try:
    print(json.load(open('$lock')).get('pid',''))
except Exception:
    pass" 2>/dev/null)
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
      kill -TERM "$lock_pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$lock_pid" 2>/dev/null || true
      killed_any=1
    fi
    rm -f "$lock" 2>/dev/null || true
  fi

  # 2. Kill any next-server process whose cwd is this frontend dir
  local pid cwd
  for pid in $(pgrep -f "next-server" 2>/dev/null); do
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || echo "")
    if [[ -n "$cwd" && "$cwd" == "$fe_dir"* ]]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
      killed_any=1
    fi
  done

  if [[ $killed_any -eq 1 ]]; then
    # Give the OS a moment to release resources before next start
    sleep 1
  fi
  return 0
}

# Remove transient files generated by agents during a phase run.
# Safe to call multiple times. Rescues valid screenshots in evidence dirs (renames to .png);
# removes unrecognised extensionless files. Never removes files that already have an extension.
cleanup_phase_artifacts() {
  local phase="$1"
  # Nested .git dirs created by scaffolders (e.g. create-next-app)
  find "$REPO_ROOT/apps" -mindepth 2 -maxdepth 2 -name ".git" -type d -exec rm -rf {} + 2>/dev/null || true
  # Ad-hoc QA test runners the QA agent writes at repo root
  rm -f "$REPO_ROOT"/qa_*.py 2>/dev/null || true
  # Stray browser screenshots at repo root (agent naming drift — no path prefix)
  rm -f "$REPO_ROOT"/UT-*-result "$REPO_ROOT"/UT-*-check 2>/dev/null || true
  rm -f "$REPO_ROOT"/tc[0-9]*-* 2>/dev/null || true
  # Leftover scaffold staging dir
  rm -rf "$REPO_ROOT/apps/frontend-tmp" 2>/dev/null || true
  # /tmp logs from QA and browser-qa
  rm -f /tmp/qa-backend.log /tmp/qa-frontend.log /tmp/browser-qa-backend.log /tmp/browser-qa-frontend.log 2>/dev/null || true
  # Fix extensionless screenshots in evidence dirs (Chrome MCP naming drift).
  # Rename to .png if the file is a valid PNG; remove otherwise.
  local evidence_dir
  for evidence_dir in "$REPO_ROOT"/reports/qa/*-evidence; do
    [[ -d "$evidence_dir" ]] || continue
    local f
    for f in "$evidence_dir"/*; do
      [[ -f "$f" ]] || continue
      [[ "$f" == *.* ]] && continue  # already has an extension — skip
      if file "$f" 2>/dev/null | grep -q "PNG image"; then
        mv "$f" "${f}.png"
        echo "[cleanup] renamed $(basename "$f") → $(basename "$f").png"
      else
        rm -f "$f"
        echo "[cleanup] removed non-image extensionless file: $(basename "$f")"
      fi
    done
  done
}

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

# ── UI Artifact Utilities ────────────────────────────────────────────────────

# Returns 0 if all 6 UI visibility artifacts exist for a phase
verify_ui_artifacts() {
  local phase="$1"
  local required=(
    "$REPO_ROOT/reports/phase-${phase}-implementation-summary.md"
    "$REPO_ROOT/reports/phase-${phase}-user-visible-changes.md"
    "$REPO_ROOT/reports/phase-${phase}-ui-surface-map.md"
    "$REPO_ROOT/reports/phase-${phase}-ui-test-plan.md"
    "$REPO_ROOT/reports/phase-${phase}-ui-test-results.md"
    "$REPO_ROOT/reports/phase-${phase}-what-to-click.md"
  )
  local missing=()
  for f in "${required[@]}"; do
    [[ -f "$f" ]] || missing+=("$f")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "[verify_ui_artifacts] Missing UI artifacts for $phase:" >&2
    for m in "${missing[@]}"; do echo "  $m" >&2; done
    return 1
  fi
  return 0
}

# Returns 0 if the plan declares frontend is present
# Handles both "Frontend Present: yes" (inline) and "## Frontend Present\nyes" (heading)
detect_frontend_in_plan() {
  local plan_file="$1"
  [[ -f "$plan_file" ]] || return 1
  grep -qi "frontend present: yes" "$plan_file" && return 0
  grep -Pzoq '(?i)frontend present\s*\n\s*yes' "$plan_file" 2>/dev/null && return 0
  return 1
}

# Returns 0 if the phase diff contains frontend files (.tsx/.jsx/.vue/.svelte/.css in frontend dirs)
detect_frontend_changes() {
  local phase="$1"
  local frontend_patterns=(
    "\.tsx$" "\.jsx$" "\.vue$" "\.svelte$"
    "/components/" "/pages/" "/views/" "/screens/"
    "\.module\.css$" "\.module\.scss$"
  )
  # Check changed_files in status.json if available
  local status_file="$REPO_ROOT/runs/$phase/status.json"
  if [[ -f "$status_file" ]]; then
    local changed
    changed=$(python3 -c "
import json, sys
try:
    with open('$status_file') as f:
        files = json.load(f).get('changed_files', [])
    print('\n'.join(files))
except Exception:
    pass
" 2>/dev/null || true)
    if [[ -n "$changed" ]]; then
      for pattern in "${frontend_patterns[@]}"; do
        if echo "$changed" | grep -qE "$pattern"; then
          return 0
        fi
      done
      return 1
    fi
  fi
  # Fallback: check git diff for frontend files
  if git -C "$REPO_ROOT" diff --name-only HEAD 2>/dev/null | grep -qE "(\.tsx$|\.jsx$|\.vue$|/components/|/pages/|/views/)"; then
    return 0
  fi
  return 1
}

# Returns 0 (consistent) or 1 (inconsistent) — checks user-visible-changes vs frontend file changes
check_backend_only_claim() {
  local phase="$1"
  local uvc_file="$REPO_ROOT/reports/phase-${phase}-user-visible-changes.md"
  [[ -f "$uvc_file" ]] || return 0  # File missing — handled elsewhere

  # If the user-visible-changes file says N/A or no visible changes
  if grep -qi "backend-only\|no user-visible\|no visible changes\|Frontend Present: no" "$uvc_file" 2>/dev/null; then
    # Check if frontend files actually changed
    if detect_frontend_changes "$phase"; then
      echo "[check_backend_only_claim] WARNING: user-visible-changes claims no UI changes but frontend files were modified." >&2
      return 1
    fi
  fi
  return 0
}

# Returns 0 if closure verdict file contains CLOSURE-PASS
closure_verdict_passes() {
  local report_file="${1:-}"
  [[ -f "$report_file" ]] || return 1
  grep -qE "^\*\*Verdict:\*\* CLOSURE-PASS" "$report_file" 2>/dev/null
}

# Returns 0 if UX regression report is PASS or WARN (not FAIL)
ux_regression_verdict_passes() {
  local report_file="${1:-}"
  [[ -f "$report_file" ]] || return 0  # Missing = acceptable (backend-only phases may not have this)
  # PASS or WARN are acceptable; only FAIL blocks
  if grep -qE "^\*\*Verdict:\*\* UX-REGRESSION-FAIL" "$report_file" 2>/dev/null; then
    return 1
  fi
  return 0
}

# Write N/A stub files for UI artifacts in backend-only phases
# Usage: write_na_ui_artifacts <phase> [artifact-names...]
# If no artifact names given, writes stubs for all 6 UI artifacts
write_na_ui_artifacts() {
  local phase="$1"
  shift
  local artifacts=("$@")

  # Default: all 6 artifacts
  if [[ ${#artifacts[@]} -eq 0 ]]; then
    artifacts=(
      "implementation-summary"
      "user-visible-changes"
      "ui-surface-map"
      "ui-test-plan"
      "ui-test-results"
      "what-to-click"
    )
  fi

  mkdir -p "$REPO_ROOT/reports"

  for artifact in "${artifacts[@]}"; do
    local out_file="$REPO_ROOT/reports/phase-${phase}-${artifact}.md"
    if [[ ! -f "$out_file" ]]; then
      case "$artifact" in
        implementation-summary)
          printf "# Phase %s — Implementation Summary\n\n**Status:** Backend-only phase (Frontend Present: no)\n\nNo UI-visible implementation. All changes are internal backend.\n" "$phase" > "$out_file"
          ;;
        user-visible-changes)
          printf "# Phase %s — User-Visible Changes\n\n**Status:** N/A — Backend-only phase (Frontend Present: no)\n\nNo user-visible changes. All changes are internal backend implementation.\n" "$phase" > "$out_file"
          ;;
        ui-surface-map)
          printf "# Phase %s — UI Surface Map\n\n**Status:** N/A — Backend-only phase (Frontend Present: no)\n\nNo UI surfaces affected.\n" "$phase" > "$out_file"
          ;;
        ui-test-plan)
          printf "# Phase %s — UI Test Plan\n\n**Status:** N/A — Backend-only phase. No UI tests required.\n" "$phase" > "$out_file"
          ;;
        ui-test-results)
          printf "# Phase %s — UI Test Results\n\n**Browser QA Verdict:** SKIPPED\n\n**Reason:** Backend-only phase (Frontend Present: no). No browser tests executed.\n" "$phase" > "$out_file"
          ;;
        what-to-click)
          printf "# Phase %s — What to Click\n\n**Status:** N/A — Backend-only phase. No UI verification steps.\n" "$phase" > "$out_file"
          ;;
        *)
          printf "# Phase %s — %s\n\n**Status:** N/A — Backend-only phase.\n" "$phase" "$artifact" > "$out_file"
          ;;
      esac
      echo "[write_na_ui_artifacts] Wrote N/A stub: $out_file"
    fi
  done
}
