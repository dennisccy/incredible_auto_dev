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

# ── CLI selection (claude vs codex) ──────────────────────────────────────────
# These helpers were added when multi-CLI support landed. They preserve the
# previous behaviour when CHAIN_CLI is unset (defaults to claude).

# Parse --cli from the script's argv. Sets CHAIN_CLI and writes the remaining
# args to the global CHAIN_CLI_REMAINING_ARGS array. Supports both `--cli claude`
# and `--cli=claude` forms.
#
# Usage in callers:
#   extract_cli_arg "$@" || exit $?
#   if [[ ${#CHAIN_CLI_REMAINING_ARGS[@]} -gt 0 ]]; then
#     set -- "${CHAIN_CLI_REMAINING_ARGS[@]}"
#   else
#     set --
#   fi
extract_cli_arg() {
  CHAIN_CLI_REMAINING_ARGS=()
  CHAIN_CLI_FROM_FLAG=false  # tracks whether --cli appeared on the command line
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cli)
        if [[ -z "${2:-}" ]]; then
          echo "Error: --cli requires an argument (claude|codex)" >&2
          return 2
        fi
        export CHAIN_CLI="$2"
        CHAIN_CLI_FROM_FLAG=true
        shift 2
        ;;
      --cli=*)
        export CHAIN_CLI="${1#--cli=}"
        CHAIN_CLI_FROM_FLAG=true
        shift
        ;;
      --force-cli)
        export CHAIN_FORCE_CLI=true
        shift
        ;;
      *)
        CHAIN_CLI_REMAINING_ARGS+=("$1")
        shift
        ;;
    esac
  done
  : "${CHAIN_CLI:=claude}"
  case "$CHAIN_CLI" in
    claude|codex) ;;
    *)
      echo "Error: --cli must be claude or codex (got '$CHAIN_CLI')" >&2
      return 2
      ;;
  esac
}

# Check the right CLI binary is on PATH for the currently selected CLI.
require_cli() {
  local cli="${CHAIN_CLI:-claude}"
  case "$cli" in
    claude)
      if ! command -v claude &>/dev/null; then
        echo "Error: 'claude' CLI not found. Install Claude Code or use --cli codex." >&2
        exit 1
      fi
      ;;
    codex)
      if ! command -v codex &>/dev/null; then
        echo "Error: 'codex' CLI not found. Install OpenAI Codex or use --cli claude." >&2
        exit 1
      fi
      ;;
  esac
}

# Back-compat: existing callers say require_claude. Now dispatches via require_cli.
require_claude() { require_cli; }

# Idempotent: regenerate the per-CLI asset tree from neutral source if it's missing.
# Called by run-phase.sh / run-goal.sh after CLI selection, before any agent
# invocation. Force a resync with CHAIN_RESYNC_CLI_ASSETS=true.
ensure_cli_assets_synced() {
  local cli="${1:-${CHAIN_CLI:-claude}}"
  local marker
  case "$cli" in
    claude) marker="$REPO_ROOT/.claude/agents/developer.md" ;;
    codex)  marker="$REPO_ROOT/.codex/agents/developer.toml" ;;
    *) return 0 ;;
  esac
  if [[ -f "$marker" && "${CHAIN_RESYNC_CLI_ASSETS:-false}" != "true" ]]; then
    return 0
  fi
  log "ensure_cli_assets_synced: materializing $cli assets from neutral source..."
  python3 "$REPO_ROOT/scripts/automation/sync-cli-assets.py" --cli "$cli" >&2 || {
    echo "Error: sync-cli-assets failed for cli=$cli" >&2
    return 1
  }
}

# Persist the active CLI to a status/session JSON file. Idempotent — used by
# run-phase.sh (status.json) and run-goal.sh (session.json) to record which
# CLI ran the work, so resume + telemetry can tell them apart.
record_cli_in_json() {
  local json_path="$1"
  local cli="${CHAIN_CLI:-claude}"
  [[ -f "$json_path" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local tmp
  tmp=$(mktemp "${json_path}.XXXXXX")
  if jq --arg cli "$cli" '. + {cli: $cli}' "$json_path" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$json_path"
  else
    rm -f "$tmp"
  fi
}

# Read the persisted CLI from a status/session JSON file. Echoes the value or
# empty string. Used by run-goal.sh --resume to pin the CLI from a prior session.
read_cli_from_json() {
  local json_path="$1"
  [[ -f "$json_path" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '.cli // ""' "$json_path" 2>/dev/null
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

# Check that a non-interactive push to 'origin' would authenticate.
# Returns 0 if origin is reachable + authorized; 2 if there is no 'origin'
# remote; non-zero (typically 1/128/124) on an auth or network failure.
#
# This tests git's REAL credential path (the one `git push` uses) rather than
# `gh auth status`, so it catches an expired HTTPS session that would otherwise
# block `git push` on a username/password prompt. GIT_TERMINAL_PROMPT=0 and ssh
# BatchMode make git fail fast instead of prompting — so this can never hang.
# `ls-remote` is a read-only call that exercises the same auth as push.
#
# Callers MUST capture the code without tripping `set -e`, e.g.:
#     rc=0; check_git_push_access "$REPO_ROOT" || rc=$?
check_git_push_access() {
  local repo="${1:-$REPO_ROOT}"
  git -C "$repo" remote get-url origin >/dev/null 2>&1 || return 2
  # Optional `timeout` prefix (intentional word-split; portable to old bash).
  local runner=""
  command -v timeout >/dev/null 2>&1 && runner="timeout 20"
  # shellcheck disable=SC2086
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -oBatchMode=yes -oStrictHostKeyChecking=accept-new" \
    $runner git -C "$repo" ls-remote --heads origin >/dev/null 2>&1
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
  local _cli="${CHAIN_CLI:-claude}"
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
# 'cli' is captured on first write only — preserves which CLI started the phase
# even if CHAIN_CLI is changed between resumes.
for k, v in [('started_at', now), ('cli', '${_cli}'), ('blockers', []), ('changed_files', []), ('tests_run', False), ('browser_checks_run', False), ('next_action', 'none')]:
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
# AND status.json does not say the phase is currently blocked.
#
# Both files must agree: previously summary.json could lie because
# finalize-phase.sh writes it BEFORE the release-manager actually runs.
# If the release-manager hits quota or any other failure after that,
# status.json is updated to "blocked" but summary.json is left claiming
# finalized — which made subsequent runs exit early with "already
# finalized" even though closure had since failed.
is_finalized() {
  local phase="$1"
  local summary_file="$REPO_ROOT/runs/$phase/summary.json"
  local status_file="$REPO_ROOT/runs/$phase/status.json"
  if [[ ! -f "$summary_file" ]]; then return 1; fi
  python3 - "$summary_file" "$status_file" <<'PYEOF' 2>/dev/null
import json, sys, os
summary_file, status_file = sys.argv[1], sys.argv[2]
try:
    with open(summary_file) as f:
        if json.load(f).get("status") != "finalized":
            sys.exit(1)
except Exception:
    sys.exit(1)
# If status.json exists and says blocked, the phase is not really done
# regardless of what summary.json claims — trust the more recent state.
if os.path.exists(status_file):
    try:
        with open(status_file) as f:
            if json.load(f).get("status") == "blocked":
                sys.exit(1)
    except Exception:
        pass
sys.exit(0)
PYEOF
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

# Reclaim this project's *canonical* offset ports before a fresh standalone
# bring-up (demo / standalone QA), killing any orphaned dev servers squatting
# on them. Without this, ensure_phase_ports' "next free port" search DRIFTS to a
# neighbour (e.g. 8000+offset is taken by a zombie backend, so it picks +1) while
# a stale, still-responding frontend keeps the OLD backend port baked into its
# Vite/dev proxy (the proxy target is fixed at frontend startup and can never
# re-point). The result: the browser loads but every /api call is proxied to a
# dead port, so the UI renders empty. Reclaiming the canonical ports guarantees a
# freshly-started, mutually-aligned frontend+backend pair every run.
# Only safe for standalone runs that own these ports; the pipeline (run-phase.sh)
# must NOT call this mid-run. No-op when CHAIN_*_PORT are already pinned by caller.
reclaim_canonical_phase_ports() {
  [[ -n "${CHAIN_BACKEND_PORT:-}" || -n "${CHAIN_FRONTEND_PORT:-}" ]] && return 0
  local offset
  offset=$(_project_port_offset)
  for port in $((8000 + offset)) $((3000 + offset)); do
    fuser -k -9 "$port/tcp" 2>/dev/null || true
  done
  sleep 1
  return 0
}

# Return a project-scoped /tmp log path to avoid cross-project log clobbering
# when multiple projects share this subtree (each project has a unique port
# offset, so using the port as a discriminator gives a stable per-project path).
# Usage: _qa_log_path <role>  (role e.g. "qa-backend" or "browser-qa-frontend")
_qa_log_path() {
  local role="$1"
  local port="${CHAIN_BACKEND_PORT:-${CHAIN_FRONTEND_PORT:-0}}"
  echo "/tmp/${role}-${port}.log"
}

# Parse the TCP port out of a localhost URL (http://localhost:3836/… -> 3836).
# Echoes empty when the URL carries no explicit port. set -e safe.
_url_port() {
  printf '%s' "$1" | sed -n 's#^[a-zA-Z][a-zA-Z0-9+.-]*://[^/:]*:\([0-9][0-9]*\).*#\1#p'
}

# Kill a process and all its descendants (TERM, brief grace, then KILL).
# Best-effort and set -e safe; no-op on empty/dead PID.
_kill_pid_tree() {
  local pid="$1"
  [[ -z "$pid" ]] && return 0
  local child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    _kill_pid_tree "$child"
  done
  kill -TERM "$pid" 2>/dev/null || true
  return 0
}

# Echo a human-readable hint when an obvious prerequisite for a role is missing,
# so a SKIPPED reason can say "deps not installed" instead of a bare timeout.
# Empty output when nothing obvious is wrong. Always safe to call.
_qa_dep_hint() {
  local role="$1"
  case "$role" in
    *frontend*)
      local fe_dir="${CHAIN_FRONTEND_DIR:-$REPO_ROOT/apps/frontend}"
      [[ -d "$fe_dir/node_modules" ]] || \
        echo "frontend dependencies are not installed (missing $fe_dir/node_modules) — run 'npm install' there" ;;
    *backend*)
      [[ -d "$REPO_ROOT/apps/backend/.venv" ]] || \
        echo "backend virtualenv is missing ($REPO_ROOT/apps/backend/.venv) — create it and install requirements" ;;
  esac
  return 0
}

# Start a service with health-gated retries. Unlike a bare URL re-probe this
# re-SPAWNS the start command up to <max_attempts> times, escalating cleanup
# between attempts so half-started servers never stack on the port, and on final
# failure captures the tail of its log into the caller-named <tail_var> so the
# operator sees the REAL reason (a crash / missing dep / port clash) rather than
# a generic timeout.
#
# Usage: _start_service_with_retries <role> <health_url> <start_cmd> <log_path> \
#            <per_attempt_timeout> <max_attempts> <tail_var> [pre_start_hook]
# Returns 0 as soon as the URL answers 2xx/3xx; 1 if every attempt fails.
# Idempotent: an already-healthy service returns 0 immediately with NO spawn,
# which keeps it cheap and safe as the quota-retry pre-hook (called repeatedly).
_start_service_with_retries() {
  local role="$1" health_url="$2" start_cmd="$3" log_path="$4"
  local per_attempt="$5" max_attempts="$6" tail_var="$7" pre_hook="${8:-}"

  # Nothing to start with — leave it to upstream handling (callers tolerate this).
  [[ -z "$start_cmd" || -z "$health_url" ]] && return 0

  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "$health_url" 2>/dev/null || true)
  if [[ "$code" =~ ^[23] ]]; then
    return 0   # already healthy — idempotent fast path, no spawn
  fi

  local target_port
  target_port=$(_url_port "$health_url")

  local attempt=1 pid waited
  while [[ $attempt -le $max_attempts ]]; do
    echo "[ensure_services_running] $role not healthy (status: ${code:-none}) — start attempt ${attempt}/${max_attempts}..." >&2

    # Clear anything squatting this role's port / single-instance lock first.
    # pre_hook (kill_stale_next_dev_server / kill_stale_backend_server) is
    # cwd-scoped so it also reclaims a DRIFTED orphan on a neighbour port.
    if [[ -n "$pre_hook" ]]; then eval "$pre_hook" >&2 2>&1 || true; fi
    [[ -n "$target_port" ]] && { fuser -k -9 "${target_port}/tcp" 2>/dev/null || true; }

    : >"$log_path" 2>/dev/null || true   # fresh log so the failure tail is THIS attempt's
    $start_cmd >"$log_path" 2>&1 &
    pid=$!
    # QA_STARTED_PIDS is declared by qa-phase.sh / browser-qa-phase.sh but NOT by
    # demo-phase.sh — guard so the append is safe whether or not it pre-exists.
    if declare -p QA_STARTED_PIDS >/dev/null 2>&1; then
      QA_STARTED_PIDS+=("$pid")
    else
      QA_STARTED_PIDS=("$pid")
    fi

    waited=0
    while [[ $waited -lt $per_attempt ]]; do
      code=$(curl -s -o /dev/null -w "%{http_code}" "$health_url" 2>/dev/null || true)
      if [[ "$code" =~ ^[23] ]]; then
        echo "[ensure_services_running] $role is ready (attempt ${attempt}, ${waited}s)." >&2
        return 0
      fi
      # If the process died on boot there is no point waiting out the budget —
      # the next attempt (or the captured log) is the way forward.
      if ! kill -0 "$pid" 2>/dev/null; then
        echo "[ensure_services_running] $role process (pid $pid) exited during boot — see $log_path." >&2
        break
      fi
      sleep 3
      waited=$((waited + 3))
    done

    # Alive-but-not-serving (or dead): tear down before the next attempt so we
    # never leave a half-started server holding the port.
    _kill_pid_tree "$pid"
    [[ -n "$target_port" ]] && { fuser -k -9 "${target_port}/tcp" 2>/dev/null || true; }
    attempt=$((attempt + 1))
    [[ $attempt -le $max_attempts ]] && sleep 1
  done

  local tail_txt=""
  [[ -f "$log_path" ]] && tail_txt="$(tail -n 20 "$log_path" 2>/dev/null || true)"
  printf -v "$tail_var" '%s' "$tail_txt"
  echo "[ensure_services_running] $role failed to become healthy after ${max_attempts} attempt(s) (log: $log_path)." >&2
  return 1
}

# ── Idempotent service bootstrap (shared by qa-phase.sh and browser-qa-phase.sh) ──
#
# Starts the backend (and optionally frontend) if they are not already running.
# Designed to be called both at script start AND from the quota-retry pre-retry
# hook so that servers killed or crashed during a long quota sleep are revived
# before the next claude attempt.
#
# Required env vars (set by the caller):
#   QA_BACKEND_HEALTH_URL   — HTTP URL that returns 2xx/3xx when backend is up
#   QA_BACKEND_START_CMD    — shell command to start backend (runs in background)
#   QA_BACKEND_LOG          — path to redirect backend stdout/stderr
#   QA_FRONTEND_URL         — HTTP URL for the frontend root
#   QA_FRONTEND_START_CMD   — shell command to start frontend (runs in background)
#   QA_FRONTEND_LOG         — path to redirect frontend stdout/stderr
#   QA_FRONTEND_REQUIRED    — "yes" to ensure frontend too, "no" to skip
#
# The function is a no-op for services that are already healthy. It does not
# error if start commands are missing — callers handle that case upstream.
ensure_services_running() {
  # Exported so callers (demo-phase.sh, browser-qa-phase.sh, qa-phase.sh,
  # goal-iter-lean.sh) can put the REAL reason — not a bare timeout — into their
  # SKIPPED artifacts. Reset every call so a later healthy boot clears a stale
  # tail and the quota-retry pre-hook never carries forward an old failure.
  export QA_BACKEND_UP="unknown"
  export QA_FRONTEND_UP="unknown"
  export QA_BACKEND_LOG_TAIL=""
  export QA_FRONTEND_LOG_TAIL=""

  # Backend: 2 attempts × 45s = the same 90s ceiling as the previous single shot,
  # but now re-SPAWNS on failure and reclaims a stale/drifted uvicorn by cwd.
  if [[ -n "${QA_BACKEND_HEALTH_URL:-}" && -n "${QA_BACKEND_START_CMD:-}" ]]; then
    if _start_service_with_retries "backend" \
         "$QA_BACKEND_HEALTH_URL" "$QA_BACKEND_START_CMD" "${QA_BACKEND_LOG:-/dev/null}" \
         45 2 QA_BACKEND_LOG_TAIL "kill_stale_backend_server"; then
      export QA_BACKEND_UP="yes"
    else
      export QA_BACKEND_UP="no"
    fi
  fi

  # Frontend (only when required): 2 attempts × 60s = the same 120s ceiling as
  # before. kill_stale_next_dev_server clears Next's single-instance lock so a
  # retry can actually bind.
  if [[ "${QA_FRONTEND_REQUIRED:-no}" == "yes" && -n "${QA_FRONTEND_URL:-}" && -n "${QA_FRONTEND_START_CMD:-}" ]]; then
    if _start_service_with_retries "frontend" \
         "$QA_FRONTEND_URL" "$QA_FRONTEND_START_CMD" "${QA_FRONTEND_LOG:-/dev/null}" \
         60 2 QA_FRONTEND_LOG_TAIL "kill_stale_next_dev_server"; then
      export QA_FRONTEND_UP="yes"
    else
      export QA_FRONTEND_UP="no"
    fi
  fi

  # ALWAYS 0: the five bare call sites run under `set -e`. Failure is surfaced
  # via QA_*_UP / QA_*_LOG_TAIL, never a non-zero return.
  return 0
}

# Re-probe a URL across a cold-start budget rather than deciding once. A dev
# frontend (Vite/Next) can take >10s to compile its first request, and
# ensure_services_running returns silently on timeout — so a single curl right
# after it can race a still-booting / recompiling app and wrongly conclude it is
# unreachable. Retries every 3s up to max_wait before giving up.
# Usage: _wait_for_url <url> <name> [max_wait_seconds] [log_tag]
# Returns 0 once the URL answers 2xx/3xx, 1 on timeout.
_wait_for_url() {
  local url="$1" name="$2" max_wait="${3:-60}" tag="${4:-wait}"
  local waited=0
  echo "[$tag] Waiting for $name at $url (max ${max_wait}s)..."
  while true; do
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || true)
    if [[ "$code" =~ ^[23] ]]; then
      echo "[$tag] $name is ready (${waited}s)."
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
    if [[ $waited -ge $max_wait ]]; then
      echo "[$tag] Warning: $name did not become ready within ${max_wait}s (last status: $code)." >&2
      return 1
    fi
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

# Clear any stale backend (uvicorn) server whose working directory is this
# project's backend dir, so a fresh start can bind the port. The backend twin of
# kill_stale_next_dev_server. cwd-scoped (matches /proc/<pid>/cwd against
# $REPO_ROOT/apps/backend) so it reclaims a DRIFTED orphan on a neighbour port
# yet never touches a sibling project's backend on a shared machine.
# Usage: kill_stale_backend_server [backend_dir]
kill_stale_backend_server() {
  local be_dir="${1:-$REPO_ROOT/apps/backend}"
  local killed_any=0
  local pid cwd
  for pid in $(pgrep -f "uvicorn" 2>/dev/null); do
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || echo "")
    if [[ -n "$cwd" && "$cwd" == "$be_dir"* ]]; then
      _kill_pid_tree "$pid"   # uvicorn + its reloader/worker children
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
      killed_any=1
    fi
  done
  [[ $killed_any -eq 1 ]] && sleep 1
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
  # Orphan HTML summaries from the prior runs/<phase>/summary.html location;
  # the new location is reports/phase-<phase>-summary.html. Drop only the file
  # at the old path — never touch runs/<phase>/{plan,status,summary}.json etc.
  rm -f "$REPO_ROOT/runs/$phase/summary.html" 2>/dev/null || true
  rm -f "$REPO_ROOT/runs/goal-session-"*"/index.html" 2>/dev/null || true
  # /tmp logs from QA and browser-qa (both legacy shared paths and current
  # port-scoped paths written by _qa_log_path)
  rm -f /tmp/qa-backend.log /tmp/qa-frontend.log /tmp/browser-qa-backend.log /tmp/browser-qa-frontend.log 2>/dev/null || true
  local _backend_port="${CHAIN_BACKEND_PORT:-0}"
  local _frontend_port="${CHAIN_FRONTEND_PORT:-0}"
  rm -f "/tmp/qa-backend-${_backend_port}.log" "/tmp/qa-frontend-${_backend_port}.log" \
        "/tmp/browser-qa-backend-${_backend_port}.log" "/tmp/browser-qa-frontend-${_backend_port}.log" \
        2>/dev/null || true
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

# Write a SKIPPED stub for an artifact that an agent failed to produce — e.g.
# when the `claude` CLI exits non-zero (stream timeout, crash) and leaves no
# results file. This keeps the phase chain moving and lets closure see the
# artifact rather than blocking on a missing file.
#
# Usage: write_failed_artifact_stub <phase> <artifact-name> <reason>
# Where <artifact-name> matches one of the keys in write_na_ui_artifacts
# (e.g., ui-test-results, user-visible-changes, ui-surface-map).
#
# If the artifact file already exists (even partially written by the agent),
# this function does nothing so real output is preserved.
write_failed_artifact_stub() {
  local phase="$1"
  local artifact="$2"
  local reason="${3:-agent failed to write artifact}"

  local out_file="$REPO_ROOT/reports/phase-${phase}-${artifact}.md"
  if [[ -f "$out_file" ]]; then
    return 0
  fi

  mkdir -p "$(dirname "$out_file")"

  local header="# Phase ${phase} — ${artifact}"
  local verdict_block=""
  case "$artifact" in
    ui-test-results)
      verdict_block=$'\n**Browser QA Verdict:** SKIPPED\n'
      ;;
    qa-report|review-report|audit-report)
      verdict_block=$'\n**Verdict:** SKIPPED\n'
      ;;
  esac

  {
    echo "$header"
    echo ""
    echo "**Status:** SKIPPED — agent did not produce this artifact."
    echo "$verdict_block"
    echo "## Reason"
    echo ""
    echo "$reason"
    echo ""
    echo "## Recovery"
    echo ""
    echo "This stub was written automatically by the phase script because the"
    echo "underlying Claude CLI invocation exited without producing the"
    echo "expected artifact. To regenerate with full content, re-run the"
    echo "relevant phase step (e.g., \`./scripts/automation/browser-qa-phase.sh"
    echo "${phase}\`) once the transient condition has cleared."
  } > "$out_file"

  echo "[write_failed_artifact_stub] Wrote SKIPPED stub: $out_file"
}
