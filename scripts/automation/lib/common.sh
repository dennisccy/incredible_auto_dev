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
import tempfile
_fd, _tmp = tempfile.mkstemp(dir=os.path.dirname(f) or '.', suffix='.sttmp')
with os.fdopen(_fd, 'w') as fp:
    json.dump(d, fp, indent=2)
    fp.write('\n')
os.replace(_tmp, f)
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
source "$(dirname "${BASH_SOURCE[0]}")/project-gates.sh"
# Step-level checkpoint/resume for goal-mode iterations (defines step_mark_done,
# step_done_valid, step_invalidate_from, chain_tree_hash, goal_iter_dir)
# shellcheck source=checkpoint.sh
source "$(dirname "${BASH_SOURCE[0]}")/checkpoint.sh"
# Per-run TMPDIR isolation + cleanup + janitor (defines chain_tmp_init,
# chain_tmp_cleanup, chain_tmp_rotate, chain_tmp_janitor)
# shellcheck source=chain-tmp.sh
source "$(dirname "${BASH_SOURCE[0]}")/chain-tmp.sh"

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

# ── Reviewer diff hygiene ─────────────────────────────────────────────────────
# Pathspec excludes for the diffs REVIEWERS read: machine-generated lockfiles,
# minified bundles, sourcemaps, binary/image assets, and harness artifact dirs
# (push-per-iter makes runs/** tracked in consumer repos, so telemetry/report
# churn otherwise lands in every `git diff HEAD` the reviewer runs). These trim
# reviewer CONTEXT only — the deterministic scan_diff.py secrets/deps scan
# (lib/goal-gates.sh) runs on the full PRODUCT diff (its own bookkeeping
# excludes are CHAIN_SCAN_BOOKKEEPING_EXCLUDES in goal-gates.sh — the scanner
# must never read the harness's own generated output), package.json stays in
# the main diff, and the hint's second command keeps dependency-file awareness.
REVIEW_DIFF_EXCLUDE_PATTERNS=(
  '*package-lock.json' '*yarn.lock' '*pnpm-lock.yaml' '*poetry.lock' '*uv.lock' '*Cargo.lock'
  '*.min.js' '*.min.css' '*.map'
  'runs/*' 'reports/*' 'docs/handoffs/*'
  '*.png' '*.jpg' '*.jpeg' '*.gif' '*.svg' '*.ico' '*.pdf' '*.woff' '*.woff2' '*.ttf'
)

# Emit the two-command diff instruction reviewer-class agents embed in their
# prompts: the noise-excluded diff to review, plus a --stat of ONLY the
# excluded paths so the reviewer still KNOWS when dependency files changed.
#   $1 — git ref to diff against (default HEAD)
review_diff_hint() {
  local ref="${1:-HEAD}"
  local ex="" only="" p
  for p in "${REVIEW_DIFF_EXCLUDE_PATTERNS[@]}"; do
    ex+=" ':(exclude)$p'"
    only+=" '$p'"
  done
  printf 'Run: git diff %s -- .%s\n' "$ref" "$ex"
  printf '  (this is the diff to review — lockfile/minified/binary/harness-artifact noise is pre-excluded)\n'
  printf 'Then run: git diff %s --stat --%s\n' "$ref" "$only"
  printf '  (stat of ONLY the excluded paths: if it lists dependency lockfiles, note WHICH changed and review the matching package.json/pyproject edit in the main diff; runs/ and reports/ churn is harness bookkeeping, outside review scope)\n'
}

# Build the pre-baked review packet (TOKEN-7): a bounded file that pre-executes
# BOTH review_diff_hint commands so reviewer-class agents stop paying tool-call
# round trips for git diffs. Section 1 is the hint's first command (the
# REVIEW_DIFF_EXCLUDE_PATTERNS-excluded diff) piped through diff_bound.py —
# hunks capped, truncations NAMED in its header; the same patterns are ALSO
# passed as --exclude so a rename/path form the git pathspec misses is still
# named, never silently rendered. Section 2 is the hint's second command: a
# --stat of ONLY the excluded paths (dependency-lockfile visibility). The
# packet replaces running diff COMMANDS, never code-reading (anti-pattern #12)
# and never the spec/handoff inputs (roadmap D7). Deliberately independent of
# goal_gate_build_diff_artifacts (different consumer + timing; gate artifacts
# stay untouched). Runs against the CURRENT working directory's git repo —
# callers cd first (engine → $REPO_ROOT; judgment runner → its case sandbox).
# Contract: atomic write (tmp+mv, never a half-written packet); non-zero on
# build failure WITHOUT leaving a stale packet behind — callers log and let
# the dispatch degrade to hint-only (the TOKEN-7 DoD's absent-packet path).
#   $1 — output file    $2 — git ref to diff against (default HEAD)
build_review_packet() {
  local out="${1:?build_review_packet: output path required}" ref="${2:-HEAD}"
  local p tmp bounded stat_out
  local ex=() only=() bound_ex=()
  for p in "${REVIEW_DIFF_EXCLUDE_PATTERNS[@]}"; do
    ex+=(":(exclude)$p"); only+=("$p"); bound_ex+=(--exclude "$p")
  done
  # Every step is individually rc-checked: callers invoke this under
  # `if ! ...` (set -e suspended there), and a failed git diff must NEVER
  # yield a packet that reads as "(no changes)" — fail, leave no file.
  bounded="$(set -o pipefail
             git diff "$ref" -- . "${ex[@]}" 2>/dev/null \
               | python3 "$REPO_ROOT/scripts/automation/lib/diff_bound.py" "${bound_ex[@]}" 2>/dev/null)" || return 1
  [[ -n "$bounded" ]] || return 1   # diff_bound always emits a header; empty = something upstream lied
  stat_out="$(git diff "$ref" --stat -- "${only[@]}" 2>/dev/null)" || return 1
  mkdir -p "$(dirname "$out")" 2>/dev/null || return 1
  tmp="$(mktemp "$out.tmp.XXXXXX" 2>/dev/null)" || return 1
  {
    printf '# Review packet — bounded diff vs %s\n' "$ref"
    printf 'Pre-built by build_review_packet (lib/common.sh): the dispatch prompt'\''s git diff\n'
    printf 'commands, already run for you. Truncations and exclusions are NAMED below — run\n'
    printf 'the git commands ONLY for files marked truncated or excluded, if they matter.\n\n'
    printf '%s\n' "$bounded"
    printf '\n## Excluded-path stat (dependency/lockfile visibility)\n\n'
    if [[ -n "$stat_out" ]]; then
      printf '%s\n' "$stat_out"
      printf '\n(if a dependency lockfile appears above, review the matching package.json/pyproject\nedit in the main diff — never lockfile hunks; runs/ reports/ docs/handoffs/ churn is\nharness bookkeeping, outside review scope)\n'
    else
      printf '(no changes in excluded paths)\n'
    fi
  } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$out" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

# ── Per-agent project-template slicing (TOKEN-1) ──────────────────────────────
# Dispatch wrappers inline ONLY the template sections an agent's duties use,
# instead of instructing a full-file Read (release-manager needs ~5 lines of a
# ~200-line file). The map lives HERE, next to the helper: `## ` heading names
# exactly as they appear in .claude/project-template.md. Keep it in sync with
# each agent's body.md duties — an agent whose duties cite an unmapped section
# is a map bug. developer and auditor are deliberately NOT mapped (they need
# most of the file — the unknown-agent fallback serves them the whole thing).
#   release-manager — GIT WORKFLOW: branch naming, PR title format, main
#     branch, and the never-commit list are all of its template-sourced duties.
#   reviewer — ARCHITECTURE PRINCIPLES (project-standards checklist),
#     DESIGN SYSTEM (its UI-quality checklist verifies components/tokens/effects
#     against it), TEST COMMANDS (verifying test quality claims).
#   qa — STACK (service URLs/ports + frontend-enabled flag), TEST COMMANDS
#     (backend/frontend test runs), SERVICE START COMMANDS (qa-phase boot).
_project_template_sections_for() {
  case "$1" in
    release-manager) printf '%s\n' "GIT WORKFLOW" ;;
    reviewer)        printf '%s\n' "ARCHITECTURE PRINCIPLES" "DESIGN SYSTEM" "TEST COMMANDS" ;;
    qa)              printf '%s\n' "STACK" "TEST COMMANDS" "SERVICE START COMMANDS" ;;
    *) return 1 ;;
  esac
}

# Emit the mapped sections of the project template for an agent, VERBATIM
# (heading line through the line before the next `## ` heading, the template's
# own `---` separators included), in map order. Contract (eval-fixture-tested
# in tests/automation/test-project-template-slice.sh):
#   • a mapped section missing from the template → a loud inline
#     "[slice: section 'X' not found in <path>]" marker — never a silent
#     omission (the agent and any human reading the prompt see the gap);
#   • unknown agent → the FULL template on stdout (safe fallback) plus one
#     diagnostic line on stderr (stdout stays clean prompt content);
#   • template file missing → a loud not-found marker on stdout;
#   • ALWAYS returns 0 — dispatch prompts embed this via $(...) under set -e.
# Section headings match case-insensitively with trailing whitespace ignored.
# Usage: project_template_slice <agent> [template_path]
project_template_slice() {
  local agent="${1:-}"
  local template="${2:-$REPO_ROOT/.claude/project-template.md}"
  if [[ ! -f "$template" ]]; then
    echo "[slice: template file not found: $template]"
    return 0
  fi
  local sections
  if ! sections="$(_project_template_sections_for "$agent")"; then
    echo "[project-template-slice] no section map for agent '${agent:-?}' — emitting the full template" >&2
    cat "$template"
    return 0
  fi
  awk -v want="${sections//$'\n'/|}" -v path="$template" -v q="'" '
    /^## / {
      key = $0; sub(/^## /, "", key); sub(/[ \t]+$/, "", key); key = toupper(key)
      if (key in body) body[key] = body[key] "\n" $0
      else body[key] = $0
      cur = key; next
    }
    cur != "" { body[cur] = body[cur] "\n" $0; next }
    END {
      n = split(want, W, /\|/)
      for (i = 1; i <= n; i++) {
        k = W[i]; sub(/[ \t]+$/, "", k); k = toupper(k)
        if (k in body) print body[k]
        else print "[slice: section " q W[i] q " not found in " path "]"
      }
    }
  ' "$template"
  return 0
}

# Dispatch the coherence-auditor agent (goal mode). ONE shared implementation
# for both call sites so the prompt cannot drift: the parallel fork inside
# goal-iter-lean.sh (runs concurrently with browser-qa — the audit needs only
# the diff + blueprint, not services or browser results) and the sequential
# fallback in run-goal.sh (parallelism off, fork crashed, or full-depth path).
#   $1 session-id   $2 iter-index   $3 iter-name    $4 blueprint-file
#   $5 iter-spec    $6 output-path  $7 snapshot-sha (may be empty)
# Returns the agent's exit code; records agent_invocation telemetry events.
dispatch_coherence_audit() {
  local _sid="$1" _idx="$2" _name="$3" _blueprint="$4" _spec="$5" _out="$6" _snap="${7:-}"
  cd "$REPO_ROOT"
  declare -F record_agent_invocation_start >/dev/null 2>&1 && record_agent_invocation_start "coherence-auditor"   # bare call: exports CHAIN_CURRENT_AGENT
  local _start="${CHAIN_AGENT_START_EPOCH:-$(date +%s)}"
  local _rc=0
  claude_with_quota_retry -p "You are the coherence-auditor agent for goal-mode coherence enforcement.

Session ID: $_sid
Iteration index: $_idx
Iter name: $_name

Blueprint (the contract): $_blueprint
Iter spec: $_spec
Agent instructions: .claude/agents/coherence-auditor.md  <-- read this first
Methodology: .claude/skills/coherence-audit.md
(CLAUDE.md is already in your system prompt — do not Read it again.)

This iteration's changes — read in this order (judge-sanctioned context trim:
lower the context fed to you, never your effort):
1. Bounded diff (read FIRST if it exists): $(dirname "$_out")/iter-diff.md — hunks capped, noise excluded, truncations are NAMED in its header so you can git-diff just those files.
2. For anything it truncates — or if the file is absent —
$(review_diff_hint "${_snap:-HEAD~1}")
(Also \`git status\` for uncommitted changes. If the snapshot SHA is empty, diff against HEAD~1.)
UI surface map (read if it exists): reports/phase-${_name}-ui-surface-map.md

Apply the TOKEN AND QUESTIONING POLICY from .claude/core.md strictly.

Write your verdict to: $_out
The verdict line MUST appear first and start exactly with:
**Verdict:** COHERENCE-PASS
  or **Verdict:** COHERENCE-WARN
  or **Verdict:** COHERENCE-FAIL" || _rc=$?
  declare -F record_agent_invocation_end >/dev/null 2>&1 && record_agent_invocation_end "coherence-auditor" "$_start" "$_rc"
  return $_rc
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

# Return a project-scoped log path to avoid cross-project log clobbering
# when multiple projects share this subtree (each project has a unique port
# offset, so using the port as a discriminator gives a stable per-project path).
# Lands in the per-run CHAIN_TMPDIR when the pipeline initialized one
# (chain_tmp_init), so run-end cleanup is a single rm; legacy shared /tmp
# otherwise (standalone step-script invocations).
# Usage: _qa_log_path <role>  (role e.g. "qa-backend" or "browser-qa-frontend")
_qa_log_path() {
  local role="$1"
  local port="${CHAIN_BACKEND_PORT:-${CHAIN_FRONTEND_PORT:-0}}"
  echo "${CHAIN_TMPDIR:-/tmp}/${role}-${port}.log"
}

# Parse the TCP port out of a localhost URL (http://localhost:3836/… -> 3836).
# Echoes empty when the URL carries no explicit port. set -e safe.
_url_port() {
  printf '%s' "$1" | sed -n 's#^[a-zA-Z][a-zA-Z0-9+.-]*://[^/:]*:\([0-9][0-9]*\).*#\1#p'
}

# Echo a pid and all its descendants, children before their parent. Best-effort
# and set -e/-u safe; echoes nothing for an empty/dead pid.
_pid_tree() {
  local p="${1:-}"
  [[ -z "$p" ]] && return 0
  local c
  for c in $(pgrep -P "$p" 2>/dev/null || true); do
    _pid_tree "$c"
  done
  printf '%s\n' "$p"
}

# Kill a process and all its descendants: TERM, a brief grace, then KILL any
# survivors. `next dev`'s turbopack/swc worker tree (and other children) often
# ignore a bare TERM and would otherwise keep squatting the port / Next's
# single-instance lock and can re-touch `.next` after a heal — so a TERM-only
# teardown silently defeats the frontend self-heal. Grace is
# CHAIN_KILL_GRACE_SECONDS (default 2s). The whole tree is snapshotted BEFORE
# signalling so reparented grandchildren stay reachable for the KILL sweep.
# Best-effort and set -e/-u safe; no-op on empty/dead PID. Benefits every caller.
_kill_pid_tree() {
  local pid="${1:-}"
  [[ -z "$pid" ]] && return 0

  local -a tree=()
  local p
  while IFS= read -r p; do [[ -n "$p" ]] && tree+=("$p"); done < <(_pid_tree "$pid")

  # Phase 1: TERM everything (children first, then the root).
  for p in ${tree[@]+"${tree[@]}"}; do
    kill -TERM "$p" 2>/dev/null || true
  done

  # Phase 2: brief grace so well-behaved processes exit on their own.
  local grace="${CHAIN_KILL_GRACE_SECONDS:-2}"
  [[ "$grace" =~ ^[0-9]+$ ]] || grace=2
  [[ "$grace" -gt 0 ]] && sleep "$grace"

  # Phase 3: KILL any survivor in the original tree (best-effort). Use `if` so a
  # dead-pid `kill -0` (non-zero) never trips the caller's `set -e` mid-loop.
  for p in ${tree[@]+"${tree[@]}"}; do
    if kill -0 "$p" 2>/dev/null; then kill -KILL "$p" 2>/dev/null || true; fi
  done
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
      if [[ ! -d "$fe_dir/node_modules" ]]; then
        echo "frontend dependencies are not installed (missing $fe_dir/node_modules) — run 'npm install' there"
      elif _next_build_is_corrupt "${QA_FRONTEND_LOG:-/dev/null}"; then
        echo "a stale/corrupt .next build (a 'next build' likely ran against the live 'next dev' .next). The harness auto-clears .next and retries; if it persists, isolate builds with NEXT_DIST_DIR (e.g. NEXT_DIST_DIR=.next-qa for build/QA commands)."
      fi ;;
    *backend*)
      [[ -d "$REPO_ROOT/apps/backend/.venv" ]] || \
        echo "backend virtualenv is missing ($REPO_ROOT/apps/backend/.venv) — create it and install requirements" ;;
  esac
  return 0
}

# True (0) if a frontend log shows a stale/corrupt Next.js `.next` build: a
# prebuilt webpack chunk went missing — typically a `next build` (production)
# clobbered a running `next dev`'s `.next`, so the dev server now answers every
# request with HTTP 500 (MODULE_NOT_FOUND) and will keep doing so until `.next`
# is removed. The fix is deterministic: `rm -rf .next` then let `next dev`
# rebuild on the next request.
_next_build_is_corrupt() {
  local log="$1"
  [[ -f "$log" ]] && grep -qiE "MODULE_NOT_FOUND|Cannot find module" "$log" 2>/dev/null
}

# Start a service with health-gated retries. Unlike a bare URL re-probe this
# re-SPAWNS the start command up to <max_attempts> times, escalating cleanup
# between attempts so half-started servers never stack on the port, and on final
# failure captures the tail of its log into the caller-named <tail_var> so the
# operator sees the REAL reason (a crash / missing dep / port clash) rather than
# a generic timeout.
#
# Usage: _start_service_with_retries <role> <health_url> <start_cmd> <log_path> \
#            <per_attempt_timeout> <max_attempts> <tail_var> [pre_start_hook] [ready_re]
# Returns 0 as soon as the URL answers a status matching <ready_re> (default
# ^[23] = 2xx/3xx); 1 if every attempt fails. Callers that only need "the server
# is reachable" (not "/health returns 200") pass a permissive ready_re such as
# '^[1-5][0-9][0-9]$' so a 404/405 still counts as up.
# Idempotent: an already-healthy service returns 0 immediately with NO spawn,
# which keeps it cheap and safe as the quota-retry pre-hook (called repeatedly).
_start_service_with_retries() {
  local role="$1" health_url="$2" start_cmd="$3" log_path="$4"
  local per_attempt="$5" max_attempts="$6" tail_var="$7" pre_hook="${8:-}"
  # Codes that count as "ready". Default = 2xx/3xx. A permissive regex like
  # '^[1-5][0-9][0-9]$' (any real HTTP status, but NOT curl's 000 = connection
  # failure) lets a 404 on /health read as "server up" for projects that don't
  # serve a health route at the root.
  local ready_re="${9:-^[23]}"

  # Frontend only: where a corrupt `.next` lives, so we can self-heal a stale
  # build (see _next_build_is_corrupt) between attempts. Empty for the backend.
  local fe_dir=""
  [[ "$role" == *frontend* ]] && fe_dir="${CHAIN_FRONTEND_DIR:-$REPO_ROOT/apps/frontend}"

  # Nothing to start with — leave it to upstream handling (callers tolerate this).
  [[ -z "$start_cmd" || -z "$health_url" ]] && return 0

  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "$health_url" 2>/dev/null || true)
  if [[ "$code" =~ $ready_re ]]; then
    return 0   # already healthy — idempotent fast path, no spawn
  fi

  local target_port
  target_port=$(_url_port "$health_url")

  # Frontend self-heal bookkeeping. `healed` ensures we clear `.next` AT MOST
  # once and grant exactly ONE guaranteed-cold rebuild attempt — so a heal is
  # never wasted by landing on the final attempt, yet can never loop forever.
  # `heal_timeout` is the longer per-attempt budget used ONLY for that cold
  # rebuild (a real app's from-scratch `next dev` compile of "/" routinely
  # exceeds the normal warm-start window). `attempt_timeout` is the budget for
  # the CURRENT attempt (normally per_attempt; raised once for the post-heal one).
  local healed=0
  local heal_timeout="${CHAIN_FRONTEND_HEAL_TIMEOUT:-180}"
  [[ "$heal_timeout" =~ ^[0-9]+$ ]] || heal_timeout=180
  local attempt_timeout

  local attempt=1 pid waited
  while [[ $attempt -le $max_attempts ]]; do
    # The attempt immediately AFTER a heal is the guaranteed-cold rebuild — give
    # it the longer budget. (healed flips to 1 in the heal block below, and
    # max_attempts was bumped there if needed so this attempt actually runs.)
    if [[ -n "$fe_dir" && $healed -eq 1 ]]; then
      attempt_timeout="$heal_timeout"
    else
      attempt_timeout="$per_attempt"
    fi
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
    while [[ $waited -lt $attempt_timeout ]]; do
      code=$(curl -s -o /dev/null -w "%{http_code}" "$health_url" 2>/dev/null || true)
      if [[ "$code" =~ $ready_re ]]; then
        echo "[ensure_services_running] $role is ready (attempt ${attempt}, ${waited}s)." >&2
        return 0
      fi
      # A frontend dev server that is UP but serving 5xx from a corrupt `.next`
      # will never recover on its own — stop waiting out the budget; the retry
      # clears `.next` (below) and rebuilds clean.
      if [[ -n "$fe_dir" && "$code" =~ ^5 ]] && _next_build_is_corrupt "$log_path"; then
        echo "[ensure_services_running] $role up but $code with a stale/corrupt .next — see $log_path." >&2
        break
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

    # Classify BEFORE teardown (teardown does not change the log/code). A corrupt
    # frontend is one whose log shows the missing-chunk signature, OR (defensively)
    # one that stayed UP on 5xx.
    local corrupt_now=0
    if [[ -n "$fe_dir" ]] \
       && { _next_build_is_corrupt "$log_path" || [[ "$code" =~ ^5 ]]; }; then
      corrupt_now=1
    fi

    # Don't kill a slow cold compile: on what is CURRENTLY the final attempt, if
    # the frontend process is still ALIVE and NOT corrupt, it is most likely just
    # still compiling its first request (code 000/transient, not 5xx-corrupt).
    # Killing it here is exactly what forced the downstream 90s-on-a-dead-port
    # SKIP. Leave it running so the readiness gate can catch the finishing compile,
    # and signal "started but slow" (return 2) so callers re-probe rather than
    # trust UP. Capture the log tail first, mirroring the final-failure path.
    if [[ -n "$fe_dir" && $attempt -eq $max_attempts && $corrupt_now -eq 0 ]] \
       && kill -0 "$pid" 2>/dev/null; then
      echo "[ensure_services_running] $role still alive and not corrupt on final attempt (status: ${code:-none}) — likely a slow cold compile; leaving it running for the readiness gate." >&2
      printf -v "$tail_var" '%s' "$( [[ -f "$log_path" ]] && tail -n 20 "$log_path" 2>/dev/null || true )"
      return 2
    fi

    # Alive-but-not-serving, dead, or corrupt: tear down before the next attempt
    # so we never leave a half-started/wedged server holding the port.
    _kill_pid_tree "$pid"
    [[ -n "$target_port" ]] && { fuser -k -9 "${target_port}/tcp" 2>/dev/null || true; }

    # Frontend self-heal: a corrupt `.next` (typically a `next build` that
    # clobbered the running `next dev`) never recovers on its own. Clear it so the
    # NEXT attempt's `next dev` rebuilds clean. Heal AT MOST ONCE, and bump
    # max_attempts ONLY when the heal lands on what is currently the final attempt
    # — this guarantees EXACTLY ONE cold-rebuild attempt follows a heal, and that
    # attempt is ALWAYS the final one (so it is eligible for the leave-running
    # path above). The `healed` guard blocks a second bump, so the loop always
    # terminates. The rm only ever touches an existing `.next` under $fe_dir.
    if [[ $healed -eq 0 && $corrupt_now -eq 1 && -n "$fe_dir" && -d "$fe_dir/.next" ]]; then
      echo "[ensure_services_running] clearing stale/corrupt $fe_dir/.next, then one cold-rebuild attempt (up to ${heal_timeout}s)." >&2
      rm -rf "$fe_dir/.next"
      healed=1
      [[ $attempt -ge $max_attempts ]] && max_attempts=$((max_attempts + 1))
    fi

    attempt=$((attempt + 1))
    [[ $attempt -le $max_attempts ]] && sleep 1
  done

  local tail_txt=""
  [[ -f "$log_path" ]] && tail_txt="$(tail -n 20 "$log_path" 2>/dev/null || true)"
  printf -v "$tail_var" '%s' "$tail_txt"
  echo "[ensure_services_running] $role failed to become healthy after ${max_attempts} attempt(s) (log: $log_path)." >&2
  return 1
}

# ── Escalation ladder (model) ─────────────────────────────────────────────────
# Fix-mode retries run on the strong tier: a task that already failed once on
# its normal model gets more capability, not another identical roll
# (.claude/model-orchestration.md §5). Works on both backends — headless via
# the --model injection in quota-retry.sh, interactive via the request JSON's
# model field. Disable with CHAIN_MODEL_ESCALATION=false.
escalate_model_on() {
  [[ "${CHAIN_MODEL_ESCALATION:-true}" != "true" ]] && return 0
  local _m
  _m="$(python3 "$(dirname "${BASH_SOURCE[0]}")/agent_permissions.py" tier-model strong 2>/dev/null || true)"
  if [[ -n "$_m" ]]; then
    export CHAIN_MODEL_OVERRIDE="$_m"
    echo "[escalation] retry runs on the strong tier: $_m"
    if declare -F record_telemetry_event >/dev/null 2>&1; then
      record_telemetry_event "model_escalation" "$(jq -cn --arg m "$_m" '{model:$m, escalated:true}' 2>/dev/null || printf '{"model":"%s","escalated":true}' "$_m")" || true
    fi
  fi
  return 0
}

escalate_model_off() {
  unset CHAIN_MODEL_OVERRIDE
  return 0
}

# ── Hardening cadence (SPEED-4) ───────────────────────────────────────────────
# The sharpened depth rubric makes lean the default; the cadence guarantees a
# periodic full hardening pass so audit coverage cannot silently vanish on a
# long lean streak. run-goal.sh writes $ITER_DIR/depth-dispatched (the depth
# that actually ran, incl. the legacy fallback-to-lean) per iteration; the
# streak is recomputed from those idempotent files every pass, so resume
# re-entry cannot double-count.

# goal_lean_streak <session_dir> <current_iter>
# Echoes the count of consecutive trailing `lean` dispatches over
# iter-(N-1)..iter-1. A missing file or any non-lean value breaks the streak.
# iter-0 (baseline) is never counted — the loop floor is iter-1.
goal_lean_streak() {
  local session_dir="$1" current_iter="$2"
  local streak=0 i v
  for (( i = current_iter - 1; i >= 1; i-- )); do
    v="$(cat "$session_dir/iter-$i/depth-dispatched" 2>/dev/null || true)"
    [[ "$v" == "lean" ]] || break
    streak=$((streak + 1))
  done
  echo "$streak"
}

# goal_cadence_forces_full <streak> <current_iter>
# True iff the hardening cadence demands a full pass now: K>0 AND
# current_iter>K (never fires in a session's opening window, where iter-0 is
# the baseline) AND streak>=K. K = CHAIN_HARDENING_CADENCE, default 4, 0
# disables the cadence entirely.
goal_cadence_forces_full() {
  local streak="$1" current_iter="$2"
  local k="${CHAIN_HARDENING_CADENCE:-4}"
  [[ "$k" =~ ^[0-9]+$ ]] || k=4
  (( k > 0 && current_iter > k && streak >= k ))
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
    # Backend ready_re is permissive: a 404/405 on /health still proves uvicorn is
    # listening and routing. Projects that namespace routes (e.g. /api/health) would
    # otherwise be wrongly judged DOWN and torn down on every attempt. QA_BACKEND_UP
    # is advisory only (no verdict gates on it), so "reachable" is the right bar.
    if _start_service_with_retries "backend" \
         "$QA_BACKEND_HEALTH_URL" "$QA_BACKEND_START_CMD" "${QA_BACKEND_LOG:-/dev/null}" \
         45 2 QA_BACKEND_LOG_TAIL "kill_stale_backend_server" '^[1-5][0-9][0-9]$'; then
      export QA_BACKEND_UP="yes"
    else
      export QA_BACKEND_UP="no"
    fi
  fi

  # Frontend (only when required). Base budget 2 attempts × 60s; on a detected
  # corrupt `.next`, _start_service_with_retries heals once and grants ONE extra
  # cold-rebuild attempt with the longer CHAIN_FRONTEND_HEAL_TIMEOUT budget
  # (default 180s). It returns 0=ready, 2=started-but-slow (left running; the
  # downstream readiness gate re-probes), or 1=failed. kill_stale_next_dev_server
  # clears Next's single-instance lock so a retry can actually bind.
  if [[ "${QA_FRONTEND_REQUIRED:-no}" == "yes" && -n "${QA_FRONTEND_URL:-}" && -n "${QA_FRONTEND_START_CMD:-}" ]]; then
    local _fe_rc=0
    _start_service_with_retries "frontend" \
      "$QA_FRONTEND_URL" "$QA_FRONTEND_START_CMD" "${QA_FRONTEND_LOG:-/dev/null}" \
      60 2 QA_FRONTEND_LOG_TAIL "kill_stale_next_dev_server" || _fe_rc=$?
    case "$_fe_rc" in
      0) export QA_FRONTEND_UP="yes" ;;
      2) export QA_FRONTEND_UP="slow" ;;   # alive, still compiling — gate re-probes
      *) export QA_FRONTEND_UP="no" ;;
    esac
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

# Corruption-aware readiness gate for the FRONTEND. A drop-in superset of
# _wait_for_url (same signature, same 0=ready/1=timeout contract): it waits for
# 2xx/3xx, but if it sees a PERSISTENT corrupt `.next` (the log shows the
# missing-chunk signature AND the port answers 5xx, or is dead at 000) it heals
# ONCE — kill the stale dev server, `rm -rf .next`, restart, and wait through the
# resulting cold rebuild. This is the last line of defence for the standalone
# demo / browser-qa / goal-iter-lean paths whose only readiness check used to be
# a heal-less _wait_for_url against a server the boot may have already given up on.
#
# CRITICAL SAFETY: under CHAIN_SHARED_SERVICES=true the frontend is shared across
# parallel fanout branches (demo + browser-qa). Restarting it from one branch
# would yank it out from under the other (and demo does not even export
# QA_FRONTEND_START_CMD in that mode). So the heal-restart is GUARDED to the
# non-shared path; under shared services this degrades to a plain re-probe, with
# recovery owned by the shared boot's in-loop self-heal (_start_service_with_retries),
# which now leaves a compiling server running for this gate to catch. Also gated
# by CHAIN_FRONTEND_GATE_HEAL (default on; set 0 to disable the gate heal).
#
# Usage: _wait_for_frontend_ready <url> <name> [max_wait_seconds] [log_tag]
# Returns 0 once the URL answers 2xx/3xx, 1 on timeout.
_wait_for_frontend_ready() {
  local url="$1" name="${2:-frontend}" max_wait="${3:-90}" tag="${4:-wait}"
  local fe_dir="${CHAIN_FRONTEND_DIR:-$REPO_ROOT/apps/frontend}"
  local log_path="${QA_FRONTEND_LOG:-/dev/null}"
  local healed=0 waited=0 code
  echo "[$tag] Waiting for $name at $url (max ${max_wait}s, corruption-aware)..."
  while true; do
    code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || true)
    if [[ "$code" =~ ^[23] ]]; then
      echo "[$tag] $name is ready (${waited}s)."
      return 0
    fi

    # One-shot heal-restart: only when safe (non-shared) and enabled, only when
    # we can actually see a corrupt-.next signature, and only when we own the
    # lifecycle (start cmd exported, .next present).
    if [[ $healed -eq 0 \
          && "${CHAIN_FRONTEND_GATE_HEAL:-1}" != "0" \
          && "${CHAIN_SHARED_SERVICES:-false}" != "true" \
          && -n "${QA_FRONTEND_START_CMD:-}" \
          && -d "$fe_dir/.next" ]] \
       && _next_build_is_corrupt "$log_path" \
       && [[ "$code" =~ ^5 || "$code" == "000" ]]; then
      echo "[$tag] $name persistently $code with a corrupt .next — healing once: rm -rf $fe_dir/.next + restart." >&2
      healed=1
      kill_stale_next_dev_server "$fe_dir" >/dev/null 2>&1 || true
      rm -rf "$fe_dir/.next"
      : >"$log_path" 2>/dev/null || true
      # Same unquoted word-split form _start_service_with_retries uses (line ~527).
      ${QA_FRONTEND_START_CMD} >"$log_path" 2>&1 &
      local _gpid=$!
      if declare -p QA_STARTED_PIDS >/dev/null 2>&1; then
        QA_STARTED_PIDS+=("$_gpid")
      else
        QA_STARTED_PIDS=("$_gpid")
      fi
      # Give the guaranteed-cold rebuild its own budget.
      local heal_budget="${CHAIN_FRONTEND_HEAL_TIMEOUT:-180}"
      [[ "$heal_budget" =~ ^[0-9]+$ ]] || heal_budget=180
      if [[ $max_wait -lt $heal_budget ]]; then max_wait="$heal_budget"; fi
      waited=0
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
  # Service logs from qa / browser-qa / fanout / demo / goal-iter boots, in BOTH
  # locations: legacy shared /tmp (fixed and port-scoped names from pre-TMPDIR
  # runs) and the current per-run CHAIN_TMPDIR (written by _qa_log_path).
  local _role _port _dir
  local _backend_port="${CHAIN_BACKEND_PORT:-0}"
  local _frontend_port="${CHAIN_FRONTEND_PORT:-0}"
  for _dir in /tmp ${CHAIN_TMPDIR:+"$CHAIN_TMPDIR"}; do
    for _role in qa browser-qa fanout demo goal-iter; do
      rm -f "$_dir/${_role}-backend.log" "$_dir/${_role}-frontend.log" 2>/dev/null || true
      for _port in "$_backend_port" "$_frontend_port"; do
        rm -f "$_dir/${_role}-backend-${_port}.log" "$_dir/${_role}-frontend-${_port}.log" 2>/dev/null || true
      done
    done
  done
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
  grep -m1 -qE "^\*\*Verdict:\*\* CLOSURE-PASS[[:space:]]*$" "$report_file" 2>/dev/null
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

# ── Missing-evidence tripwire (REL-11) ────────────────────────────────────────
# A dispatch that returns rc=0 but leaves no report artifact voids downstream
# judgment SILENTLY — the first real benchmark (bench-20260710-2117) lost its QA
# report and retro report to exactly this (untrusted-workspace Write denial) and
# every friction counter stayed zero. Loud stderr banner + a `missing_evidence`
# telemetry event ({agent, path}); NEVER a gate — callers stay non-blocking.
# The telemetry emit is guarded: in processes that don't source telemetry.sh
# (or with GOAL_SESSION_DIR unset) only the banner fires.
#
# Usage: warn_missing_evidence <agent> <expected-report-path>
warn_missing_evidence() {
  local _agent="$1"
  local _path="$2"
  {
    echo ""
    echo "============================= [missing-evidence] ============================="
    echo "[missing-evidence] agent '${_agent}' returned WITHOUT its expected report:"
    echo "[missing-evidence]   ${_path}"
    echo "[missing-evidence] The dispatch consumed tokens but left no evidence artifact;"
    echo "[missing-evidence] downstream judges will read it as unknown/SKIPPED. Check the"
    echo "[missing-evidence] agent trace for permission denials (untrusted workspace?)."
    echo "==============================================================================="
  } >&2
  if declare -F record_telemetry_event >/dev/null 2>&1; then
    record_telemetry_event "missing_evidence" \
      "$(jq -cn --arg agent "$_agent" --arg path "$_path" '{agent:$agent, path:$path}' 2>/dev/null \
         || printf '{"agent":"%s","path":"%s"}' "$_agent" "$_path")" || true
  fi
}

# ── Self-test (only when invoked directly: `bash common.sh self-test`) ───────
# Hermetic and fast (<10s): no real Next.js, no model, no network. Stubs `curl`
# and uses a fake start script whose log shows the corrupt-.next signature while
# `$fe_dir/.next` exists and "serves" 200 once it is gone — so the whole self-heal
# path (detect → kill → rm -rf .next → cold rebuild → ready) is exercised end to
# end. Wired into run-evals.sh. The `BASH_SOURCE == $0` guard means sourcing this
# library never triggers the block.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    self-test)
      _t_pass=0; _t_fail=0
      _t_ok()  { _t_pass=$((_t_pass+1)); echo "  OK: $*"; }
      _t_bad() { _t_fail=$((_t_fail+1)); echo "  FAIL: $*" >&2; }

      echo "[common.sh self-test] _kill_pid_tree TERM->grace->KILL"
      # A child that ignores TERM must still be KILLed after the grace. `wait`
      # reaps the killed child so the follow-up `kill -0` doesn't see a zombie
      # (a zombie PID still "exists" for kill -0 until its parent reaps it).
      ( trap '' TERM; sleep 20 ) &
      _kp=$!
      CHAIN_KILL_GRACE_SECONDS=1 _kill_pid_tree "$_kp"
      wait "$_kp" 2>/dev/null || true
      if kill -0 "$_kp" 2>/dev/null; then
        _t_bad "_kill_pid_tree left a TERM-ignoring process alive"; kill -KILL "$_kp" 2>/dev/null || true
      else
        _t_ok "_kill_pid_tree escalated TERM->KILL"
      fi
      # set -e/-u safe on empty and dead pids (the production callers run set -e).
      if ( set -eu; _kill_pid_tree "" ; _kill_pid_tree 999999999 ); then
        _t_ok "_kill_pid_tree set -eu safe on empty/dead pid"
      else
        _t_bad "_kill_pid_tree tripped set -eu on empty/dead pid"
      fi

      echo "[common.sh self-test] _next_build_is_corrupt detector"
      _tlog=$(mktemp)
      printf 'Error: Cannot find module ./webpack-runtime.js\n' >"$_tlog"
      if _next_build_is_corrupt "$_tlog"; then _t_ok "detector: positive (Cannot find module)"; else _t_bad "detector: missed signature"; fi
      printf '✓ Compiled / in 1200ms\n' >"$_tlog"
      if _next_build_is_corrupt "$_tlog"; then _t_bad "detector: false positive on a clean log"; else _t_ok "detector: negative on a clean log"; fi
      if _next_build_is_corrupt "/nonexistent-$$-xyz"; then _t_bad "detector: claimed missing file is corrupt"; else _t_ok "detector: missing-file safe"; fi
      rm -f "$_tlog"

      echo "[common.sh self-test] _start_service_with_retries self-heal recovery"
      _ROOT=$(mktemp -d)
      mkdir -p "$_ROOT/fe/.next"
      export CHAIN_FRONTEND_DIR="$_ROOT/fe"
      export CHAIN_FRONTEND_HEAL_TIMEOUT=2
      export CHAIN_KILL_GRACE_SECONDS=0
      _SPAWNS="$_ROOT/spawns"; : >"$_SPAWNS"
      _FELOG="$_ROOT/fe.log"
      # Stub curl: 500 while .next exists (corrupt), 200 once it is gone. Ignores args.
      curl() { if [[ -d "$CHAIN_FRONTEND_DIR/.next" ]]; then echo 500; else echo 200; fi; }
      # Fake start command: record a spawn, write the corrupt signature to its log
      # ONLY while .next is present, then stay alive so `kill -0` sees a live pid.
      _STARTSH="$_ROOT/start.sh"
      cat >"$_STARTSH" <<EOF
#!/usr/bin/env bash
echo x >> "$_SPAWNS"
if [[ -d "$CHAIN_FRONTEND_DIR/.next" ]]; then echo "Error: Cannot find module './webpack-runtime.js'"; fi
exec sleep 6
EOF
      chmod +x "$_STARTSH"
      # Run under `set -e` in a subshell to prove the function is set -e safe AND
      # recovers. Portless health URL => target_port empty => fuser is skipped.
      _tail=""; _rc=0
      ( set -e; _start_service_with_retries "frontend" "http://stub" "bash $_STARTSH" "$_FELOG" 2 2 _tail "" ) >/dev/null 2>&1 || _rc=$?
      _nspawn=$(wc -l <"$_SPAWNS" 2>/dev/null | tr -d ' ')
      if [[ "$_rc" -eq 0 ]]; then _t_ok "self-heal: recovered (rc=0) under set -e"; else _t_bad "self-heal: rc=$_rc (expected 0)"; fi
      if [[ ! -d "$CHAIN_FRONTEND_DIR/.next" ]]; then _t_ok "self-heal: corrupt .next was removed"; else _t_bad "self-heal: .next still present (heal did not run)"; fi
      if [[ "${_nspawn:-0}" -ge 2 && "${_nspawn:-0}" -le 3 ]]; then _t_ok "self-heal: spawned ${_nspawn}x (healed once)"; else _t_bad "self-heal: spawned ${_nspawn:-?}x (expected 2-3)"; fi
      # The cold-rebuild fake server is intentionally left running by the new code;
      # the fake `sleep 6` self-terminates shortly after the test, so no reap needed.

      echo "[common.sh self-test] slow cold compile is left running, not killed (return 2)"
      # After the heal, the cold rebuild is ALIVE but not yet ready and not corrupt
      # (curl 000 = still binding/compiling). The new code must leave it running and
      # return 2 (=slow) so the readiness gate can catch it — instead of killing it
      # and forcing the downstream 90s-on-a-dead-port SKIP this whole change fixes.
      mkdir -p "$_ROOT/fe3/.next"
      export CHAIN_FRONTEND_DIR="$_ROOT/fe3"
      _SPAWNS3="$_ROOT/spawns3"; : >"$_SPAWNS3"
      curl() { if [[ -d "$CHAIN_FRONTEND_DIR/.next" ]]; then echo 500; else echo 000; fi; }
      _STARTSH3="$_ROOT/start3.sh"
      cat >"$_STARTSH3" <<EOF
#!/usr/bin/env bash
echo x >> "$_SPAWNS3"
if [[ -d "$CHAIN_FRONTEND_DIR/.next" ]]; then echo "Error: Cannot find module './webpack-runtime.js'"; fi
exec sleep 8
EOF
      chmod +x "$_STARTSH3"
      _rc=0
      ( set -e; _start_service_with_retries "frontend" "http://stub" "bash $_STARTSH3" "$_ROOT/fe3.log" 2 2 _tail "" ) >/dev/null 2>&1 || _rc=$?
      if [[ "$_rc" -eq 2 ]]; then _t_ok "slow-compile: left running, returned 2 (gate re-probes)"; else _t_bad "slow-compile: rc=$_rc (expected 2)"; fi
      if [[ ! -d "$CHAIN_FRONTEND_DIR/.next" ]]; then _t_ok "slow-compile: corrupt .next cleared before the cold rebuild"; else _t_bad "slow-compile: .next not cleared"; fi

      echo "[common.sh self-test] healthy fast-path guard (no .next, never heals)"
      mkdir -p "$_ROOT/fe2"   # deliberately NO .next
      export CHAIN_FRONTEND_DIR="$_ROOT/fe2"
      curl() { echo 200; }   # healthy immediately
      _rc=0
      ( set -e; _start_service_with_retries "frontend" "http://stub" "bash $_STARTSH" "$_ROOT/fe2.log" 2 2 _tail "" ) >/dev/null 2>&1 || _rc=$?
      if [[ "$_rc" -eq 0 && ! -d "$_ROOT/fe2/.next" ]]; then _t_ok "guard: healthy fast-path, no spawn, no .next created"; else _t_bad "guard: rc=$_rc or .next appeared"; fi

      unset -f curl 2>/dev/null || true
      unset CHAIN_FRONTEND_DIR CHAIN_FRONTEND_HEAL_TIMEOUT CHAIN_KILL_GRACE_SECONDS 2>/dev/null || true
      rm -rf "$_ROOT"

      echo "[common.sh self-test] _qa_log_path CHAIN_TMPDIR scoping"
      _q=$(CHAIN_TMPDIR="/x/y" CHAIN_BACKEND_PORT=8123 _qa_log_path "qa-backend")
      if [[ "$_q" == "/x/y/qa-backend-8123.log" ]]; then _t_ok "_qa_log_path uses CHAIN_TMPDIR"; else _t_bad "_qa_log_path: got $_q"; fi
      _q=$(CHAIN_TMPDIR="" CHAIN_BACKEND_PORT=8123 _qa_log_path "qa-backend")
      if [[ "$_q" == "/tmp/qa-backend-8123.log" ]]; then _t_ok "_qa_log_path legacy /tmp fallback"; else _t_bad "_qa_log_path fallback: got $_q"; fi

      echo "[common.sh self-test] cleanup_phase_artifacts role-log sweep"
      _CROOT=$(mktemp -d)
      mkdir -p "$_CROOT/repo/apps" "$_CROOT/tmpd"
      for _r in qa browser-qa fanout demo goal-iter; do
        : > "$_CROOT/tmpd/${_r}-backend-99911.log"
        : > "$_CROOT/tmpd/${_r}-frontend-99912.log"
      done
      : > "$_CROOT/tmpd/keep-me.txt"
      # Subshell: repoint REPO_ROOT at scratch so the repo-root globs are inert.
      ( REPO_ROOT="$_CROOT/repo" CHAIN_TMPDIR="$_CROOT/tmpd" \
        CHAIN_BACKEND_PORT=99911 CHAIN_FRONTEND_PORT=99912 \
        cleanup_phase_artifacts "selftest-phase" ) >/dev/null 2>&1 || true
      if ls "$_CROOT/tmpd"/*-9991[12].log >/dev/null 2>&1; then
        _t_bad "cleanup left role logs in CHAIN_TMPDIR"
      else
        _t_ok "cleanup removed all role logs from CHAIN_TMPDIR"
      fi
      if [[ -f "$_CROOT/tmpd/keep-me.txt" ]]; then _t_ok "cleanup kept unrelated file"; else _t_bad "cleanup removed unrelated file"; fi
      rm -rf "$_CROOT"

      echo "[common.sh self-test] ${_t_pass} pass, ${_t_fail} fail"
      [[ "$_t_fail" -eq 0 ]] || exit 1
      ;;
    *)
      echo "Usage: $0 self-test" >&2
      exit 2
      ;;
  esac
fi
