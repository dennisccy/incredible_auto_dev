#!/usr/bin/env bash
# run-goal.sh — Goal-driven continuous mode runner.
#
# Reads docs/goal.md (which must include Must-have user journeys + Anti-goals)
# and iterates `decompose -> execute -> evaluate` adaptively until either the
# goal-evaluator declares GOAL_ACHIEVED or a hard halt fires (max iterations,
# stall, regression).
#
# Usage:
#   ./scripts/automation/run-goal.sh [--session-id <id>] [--max-iter N]
#                                    [--stall-window N] [--resume] [--reset]
#                                    [--auto-release]
#                                    [--acknowledge-regression]
#                                    [--no-push-per-iter] [--push-per-iter]
#                                    [--push-branch <name>]
#
# Flags:
#   --session-id <id>            Session identifier (auto-generated if omitted)
#   --max-iter N                 Hard cap on iterations (default: 30)
#   --stall-window N             Halt if last N iterations show no journey progress (default: 3)
#   --resume                     Resume an existing session
#   --reset                      Discard the named session and start fresh
#   --auto-release               On GOAL_ACHIEVED, run release-manager once for the whole session
#   --acknowledge-regression     Continue past a prior REGRESSION_HALT
#   --push-per-iter              [Default ON for new sessions.] Commit + push each successful
#                                iteration (CONTINUE / ESCALATE / GOAL_ACHIEVED) to a per-session
#                                branch. No model invocation, no PR per iter — the branch is
#                                populated incrementally and a PR is opened at the end via the
#                                existing --auto-release / manual flow. Useful on resume to
#                                opt in mid-session for a session that wasn't pushing before.
#   --no-push-per-iter           Opt out of per-iter push. Use this on a new session to keep
#                                iter commits local, or on resume to disable push for a session
#                                that was previously pushing.
#   --push-branch <name>         Branch name for per-iter commits (default: goal/<session-id>).
#                                Persists to session.json on new sessions; resume reads from there.
#
# Halt verdicts written to runs/goal-session-<sid>/session.json.status:
#   GOAL_ACHIEVED   - goal-evaluator declared done
#   BUDGET_EXHAUSTED - max iterations reached
#   STALLED          - journey-history hash unchanged for stall_window iterations
#   REGRESSION_HALT  - goal-evaluator emitted REGRESSION verdict
#   ABORTED          - user interrupted (SIGINT/SIGTERM)
#
# Quota exhaustion is NOT a halt: claude_with_quota_retry transparently sleeps
# until the quota resets and resumes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/telemetry.sh"

# Pull --cli (and --force-cli) out of the args BEFORE the existing parse loop,
# so the loop below sees only its known flags.
extract_cli_arg "$@" || exit $?
if [[ ${#CHAIN_CLI_REMAINING_ARGS[@]} -gt 0 ]]; then
  set -- "${CHAIN_CLI_REMAINING_ARGS[@]}"
else
  set --
fi

# ── Defaults ──────────────────────────────────────────────────────────────
SESSION_ID=""
MAX_ITER=30
STALL_WINDOW=3
RESUME=false
RESET=false
AUTO_RELEASE=false
ACK_REGRESSION=false
FAST_MODE=false
# Per-iter push is ON by default for new sessions. Pass --no-push-per-iter to
# opt out. On resume, the persisted session.json value wins unless overridden
# by an explicit CLI flag (--push-per-iter or --no-push-per-iter).
PUSH_PER_ITER=true
PUSH_BRANCH=""
# Tristate: "default" (no flag), "yes" (--push-per-iter), "no" (--no-push-per-iter).
# Used by the resume block to decide whether to override session.json.
PUSH_FLAG_USER="default"
# Set in the resume branch (off | continuing | opting-in). Stays empty for
# new sessions; the branch-lifecycle block only consults it when RUN_MODE=resume.
RESUME_PUSH_MODE=""

# ── Parse flags ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id)              SESSION_ID="$2"; shift 2 ;;
    --max-iter)                MAX_ITER="$2"; shift 2 ;;
    --stall-window)            STALL_WINDOW="$2"; shift 2 ;;
    --resume)                  RESUME=true; shift ;;
    --reset)                   RESET=true; shift ;;
    --auto-release)            AUTO_RELEASE=true; shift ;;
    --acknowledge-regression)  ACK_REGRESSION=true; shift ;;
    --push-per-iter)           PUSH_PER_ITER=true;  PUSH_FLAG_USER="yes"; shift ;;
    --no-push-per-iter)        PUSH_PER_ITER=false; PUSH_FLAG_USER="no";  shift ;;
    --push-branch)             PUSH_BRANCH="$2"; shift 2 ;;
    --fast)                    FAST_MODE=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$SESSION_ID" ]]; then
  if [[ "$RESUME" == "true" ]]; then
    echo "Error: --resume requires --session-id <id>" >&2
    exit 1
  fi
  SESSION_ID="$(date -u +%Y-%m-%d)-$(printf '%s' "$REPO_ROOT" | sha1sum | cut -c1-6)"
  echo "[run-goal] No --session-id provided. Using auto-generated: $SESSION_ID"
fi

GOAL_SESSION_DIR_LOCAL="$REPO_ROOT/runs/goal-session-${SESSION_ID}"
SESSION_JSON="$GOAL_SESSION_DIR_LOCAL/session.json"

# Resume: pin CHAIN_CLI from session.json unless the user explicitly overrode it.
# A mismatch errors out unless --force-cli is given.
if [[ "$RESUME" == "true" && -f "$SESSION_JSON" ]]; then
  PERSISTED_CLI=$(read_cli_from_json "$SESSION_JSON")
  if [[ -n "$PERSISTED_CLI" ]]; then
    if [[ "${CHAIN_CLI_FROM_FLAG:-false}" == "true" && "$CHAIN_CLI" != "$PERSISTED_CLI" ]]; then
      if [[ "${CHAIN_FORCE_CLI:-false}" != "true" ]]; then
        echo "Error: session $SESSION_ID was started with --cli=$PERSISTED_CLI" >&2
        echo "  but --cli=$CHAIN_CLI was passed on resume." >&2
        echo "  Pass --force-cli to override (telemetry will mix CLIs)." >&2
        exit 2
      fi
      echo "[run-goal] WARNING: overriding session CLI from $PERSISTED_CLI to $CHAIN_CLI (--force-cli)" >&2
    else
      export CHAIN_CLI="$PERSISTED_CLI"
    fi
  fi
fi

require_cli
ensure_cli_assets_synced "$CHAIN_CLI"
JOURNEY_HISTORY="$GOAL_SESSION_DIR_LOCAL/state/journey-history.json"
EVALUATOR_LOG="$GOAL_SESSION_DIR_LOCAL/state/evaluator-log.md"
LESSONS_FILE="$GOAL_SESSION_DIR_LOCAL/state/lessons.md"
SUMMARY_FILE="$GOAL_SESSION_DIR_LOCAL/summary.md"
GOAL_FILE="$REPO_ROOT/docs/goal.md"

# Run the iteration-summarizer agent for one iteration. Writes
# reports/phase-<iter>-iteration-summary.md. Non-blocking — failures only log.
# The agent reads the existing artifacts (dev handoff, review, eval.md,
# journey-history, etc.) and produces the conclusive MD that the HTML
# renderer then consumes.
_run_iteration_summarizer() {
  local iter_name="$1"
  local agent_file="$REPO_ROOT/.claude/agents/iteration-summarizer.md"
  local summary_md="$REPO_ROOT/reports/phase-${iter_name}-iteration-summary.md"
  [[ -f "$agent_file" ]] || { echo "[run-goal] Warning: iteration-summarizer agent missing, skipping"; return 0; }
  mkdir -p "$REPO_ROOT/reports"

  # Pre-trim evaluator-log.md so token usage stays flat as sessions grow.
  local eval_log_inline=""
  eval_log_inline=$(_tail_or_placeholder "$EVALUATOR_LOG" 300 "(none yet)")

  local project_story_md="$REPO_ROOT/runs/goal-session-${SESSION_ID}/state/project-story.md"
  mkdir -p "$REPO_ROOT/runs/goal-session-${SESSION_ID}/state"

  cd "$REPO_ROOT"
  export CHAIN_CURRENT_AGENT=iteration-summarizer
  claude_with_quota_retry -p "You are the iteration-summarizer agent.

mode: normal
Phase id: $iter_name
Output path (iteration summary): $summary_md
Output path (project story, GOAL MODE ONLY): $project_story_md
Agent instructions: .claude/agents/iteration-summarizer.md  <-- read this first
Template: templates/iteration-summary.md  <-- exact section structure your output must follow
(CLAUDE.md is already in your system prompt -- do not Read it again.)

Apply the TOKEN AND QUESTIONING POLICY from .claude/core.md strictly.

Read every relevant input listed in your agent instructions. Files that don't
exist should be silently skipped. Use what is present. The dispatch wrapper
has pre-trimmed evaluator-log.md below — use the inline content.

Recent evaluator log entries (last 300 lines, pre-trimmed):
---
${eval_log_inline}
---

Write the iteration summary to: $summary_md

This is a GOAL-MODE iteration. After writing the iteration summary, also
maintain $project_story_md per the 'Cumulative project story' section of your
agent instructions. Read the existing file if present, then rewrite it as one
flowing plain-language narrative that ends with this iteration.

Follow the section structure in templates/iteration-summary.md EXACTLY -- the
HTML renderer keys off the section headings. The verdict line must match the
form '**Verdict:** VALUE' where VALUE is one of: GOAL_ACHIEVED, CONTINUE,
ESCALATE, REGRESSION, STALLED, PASS, FAIL, IN-PROGRESS.

When finished, STOP." \
    || echo "[run-goal] Warning: iteration-summarizer call failed (non-blocking)"
}

# Generate the one-time "delivered" wrap when goal-evaluator returns
# GOAL_ACHIEVED. Writes a polished non-technical summary to
# reports/goal-session-<sid>-delivered.md and renders the matching HTML. Both
# steps are non-blocking — failures only log so the GOAL_ACHIEVED path still
# completes its auto-release / exit.
_render_final_delivered() {
  local sid="$1"
  local delivered_md="$REPO_ROOT/reports/goal-session-${sid}-delivered.md"
  local agent_file="$REPO_ROOT/.claude/agents/iteration-summarizer.md"
  local renderer="$SCRIPT_DIR/lib/render_iteration_summary.py"

  if [[ ! -f "$agent_file" ]]; then
    echo "[run-goal] Warning: iteration-summarizer agent missing — skipping delivered wrap"
    return 0
  fi

  mkdir -p "$REPO_ROOT/reports"

  cd "$REPO_ROOT"
  export CHAIN_CURRENT_AGENT=iteration-summarizer
  claude_with_quota_retry -p "You are the iteration-summarizer agent.

mode: delivered
Session id: $sid
Output path: $delivered_md
Agent instructions: .claude/agents/iteration-summarizer.md  <-- read this first; specifically the 'Delivered wrap' section
(CLAUDE.md is already in your system prompt -- do not Read it again.)

Apply the TOKEN AND QUESTIONING POLICY from .claude/core.md strictly.

This is the one-time GOAL_ACHIEVED delivered wrap. Read:
- runs/goal-session-${sid}/state/journey-history.json (all currently passing journeys)
- runs/goal-session-${sid}/state/project-story.md (the running narrative)
- All reports/phase-goal-${sid}-iter-*-iteration-summary.md files (each iter's plain words)
- docs/goal.md (goal title)

Write a polished, non-technical 'what we delivered' document to:
$delivered_md

Follow the 'Delivered wrap' skeleton in your agent instructions EXACTLY. Do
NOT also rewrite the iteration summary in this mode. Friendly, factual, no
journey IDs, no file names.

When finished, STOP." \
    || echo "[run-goal] Warning: delivered-wrap iteration-summarizer call failed (non-blocking)"

  if [[ -f "$renderer" ]]; then
    python3 "$renderer" delivered "$sid" --repo-root="$REPO_ROOT" 2>&1 \
      | sed 's/^/[run-goal] /' || echo "[run-goal] Warning: delivered HTML render failed (non-blocking)"
  fi
}

# Render the per-iteration HTML summary. Non-blocking — failures only log.
# Invoked after each iteration finishes its goal-evaluator step so the user
# can `open file://...` and inspect what happened that iteration.
_render_iter_html() {
  local iter_name="$1"
  local renderer="$SCRIPT_DIR/lib/render_iteration_summary.py"
  [[ -f "$renderer" ]] || return 0
  python3 "$renderer" iteration "$iter_name" --repo-root="$REPO_ROOT" 2>&1 \
    | sed 's/^/[run-goal] /' || echo "[run-goal] Warning: per-iter HTML render failed (non-blocking)"
}

# Render the session-level index.html that lists every iteration as a card
# plus the journey progress matrix. Called from write_session_summary, so it
# refreshes at every session boundary (CONTINUE, ABORT, GOAL_ACHIEVED, …).
_render_session_index_html() {
  local renderer="$SCRIPT_DIR/lib/render_iteration_summary.py"
  [[ -f "$renderer" ]] || return 0
  python3 "$renderer" session-index "$SESSION_ID" --repo-root="$REPO_ROOT" 2>&1 \
    | sed 's/^/[run-goal] /' || echo "[run-goal] Warning: session-index HTML render failed (non-blocking)"
}

# Tail an append-only state file to the last N lines, or return a placeholder
# if the file does not exist yet. Used to keep token usage flat as the goal
# session grows — agents only need the tail (last few entries), not the full
# file. The tail size is generous enough to cover the "last 3" / "last 5"
# entries the agents request, even when entries are multi-paragraph.
#   _tail_or_placeholder <file> <max-lines> <placeholder>
_tail_or_placeholder() {
  local file="$1" max="$2" placeholder="$3"
  if [[ -f "$file" && -s "$file" ]]; then
    tail -n "$max" "$file"
  else
    printf '%s\n' "$placeholder"
  fi
}

if [[ "$RESET" == "true" && -d "$GOAL_SESSION_DIR_LOCAL" ]]; then
  echo "[run-goal] --reset: removing existing $GOAL_SESSION_DIR_LOCAL"
  rm -rf "$GOAL_SESSION_DIR_LOCAL"
fi

# ── Validate goal.md ──────────────────────────────────────────────────────
validate_goal_file() {
  if [[ ! -f "$GOAL_FILE" ]]; then
    echo "Error: $GOAL_FILE not found." >&2
    echo "  Author it from templates/project-goal.md and include 'Must-have user journeys' + 'Anti-goals' sections." >&2
    exit 1
  fi

  if ! grep -q "^## Must-have user journeys" "$GOAL_FILE"; then
    echo "Error: $GOAL_FILE is missing the '## Must-have user journeys' section." >&2
    echo "  See templates/project-goal.md for the format. See .claude/anti-patterns.md #18." >&2
    exit 1
  fi

  if ! grep -q "^## Anti-goals" "$GOAL_FILE"; then
    echo "Error: $GOAL_FILE is missing the '## Anti-goals' section." >&2
    echo "  See templates/project-goal.md for the format. See .claude/anti-patterns.md #18." >&2
    exit 1
  fi

  if ! grep -E '^- \*\*J-[0-9]+:' "$GOAL_FILE" >/dev/null; then
    echo "Error: $GOAL_FILE 'Must-have user journeys' section has no journey entries." >&2
    echo "  Each journey MUST have an ID like '- **J-01: <name>**'. See templates/project-goal.md." >&2
    exit 1
  fi

  python3 - <<'PY' "$GOAL_FILE" || exit 1
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'^## Anti-goals\s*$(.*?)(^## |\Z)', text, re.MULTILINE | re.DOTALL)
if not m:
    print("Error: Anti-goals section parse failed.", file=sys.stderr); sys.exit(1)
body = m.group(1)
items = [ln for ln in body.splitlines() if ln.strip().startswith('-') and ln.strip() != '-']
non_placeholder = [ln for ln in items if 'TODO' not in ln and 'placeholder' not in ln.lower()]
if not non_placeholder:
    print("Error: Anti-goals section has no concrete entries (only placeholders or empty bullets).",
          file=sys.stderr)
    print("  See .claude/anti-patterns.md #18 for examples.", file=sys.stderr)
    sys.exit(1)
PY
}

# ── Session init / load ───────────────────────────────────────────────────
mkdir -p "$GOAL_SESSION_DIR_LOCAL/state"

if [[ -f "$SESSION_JSON" ]]; then
  if [[ "$RESUME" != "true" ]]; then
    echo "Error: session $SESSION_ID already exists at $GOAL_SESSION_DIR_LOCAL" >&2
    echo "  Use --resume to continue, or --reset to start fresh." >&2
    exit 1
  fi
  CURRENT_ITER=$(python3 -c "import json,sys; print(json.load(open('$SESSION_JSON')).get('current_iter', 0))")
  PRIOR_STATUS=$(python3 -c "import json,sys; print(json.load(open('$SESSION_JSON')).get('status', 'unknown'))")
  echo "[run-goal] Resuming session '$SESSION_ID' from iter $CURRENT_ITER (prior status: $PRIOR_STATUS)"

  if [[ "$PRIOR_STATUS" == "REGRESSION_HALT" && "$ACK_REGRESSION" != "true" ]]; then
    echo "Error: prior run halted with REGRESSION_HALT." >&2
    echo "  Review the regression in runs/goal-session-${SESSION_ID}/iter-*/eval.md," >&2
    echo "  fix the regressed journey, then re-run with --acknowledge-regression." >&2
    exit 1
  fi
  # Read push config from session.json and decide the effective value, taking
  # the explicit-CLI-flag tristate into account.
  #
  # Resolution table:
  #
  #   PUSH_FLAG_USER  | session push_per_iter      | result
  #   ────────────────┼────────────────────────────┼─────────────────────────────
  #   "no"            | any                        | OFF for this run (warning if session was on)
  #   "yes"           | true                       | continuing (session was already pushing)
  #   "yes"           | false / missing            | opting-in
  #   "default"       | true                       | continuing
  #   "default"       | false (key present)        | OFF (respect explicit prior choice)
  #   "default"       | missing (pre-feature sess) | opting-in (use new default-on)
  _session_push_key_present=$(python3 -c "import json; print('true' if 'push_per_iter' in json.load(open('$SESSION_JSON')) else 'false')")
  _session_push=$(python3 -c "import json; print('true' if json.load(open('$SESSION_JSON')).get('push_per_iter') else 'false')")
  _session_push_branch=$(python3 -c "import json; print(json.load(open('$SESSION_JSON')).get('push_branch') or '')")
  RESUME_PUSH_MODE="off"           # off | continuing | opting-in

  if [[ "$PUSH_FLAG_USER" == "no" ]]; then
    PUSH_PER_ITER="false"
    PUSH_BRANCH=""
    if [[ "$_session_push" == "true" ]]; then
      echo "[run-goal] push-per-iter: --no-push-per-iter passed; disabling for this run despite session being on. (Branch '$_session_push_branch' is left untouched.)"
    fi
  elif [[ "$_session_push" == "true" ]]; then
    PUSH_PER_ITER="true"
    PUSH_BRANCH="$_session_push_branch"
    RESUME_PUSH_MODE="continuing"
  elif [[ "$PUSH_FLAG_USER" == "yes" ]]; then
    PUSH_PER_ITER="true"
    [[ -z "$PUSH_BRANCH" ]] && PUSH_BRANCH="goal/$SESSION_ID"
    RESUME_PUSH_MODE="opting-in"
    echo "[run-goal] push-per-iter: enabling on resume for session that wasn't pushing previously."
  elif [[ "$_session_push_key_present" == "true" ]]; then
    # Session has explicit push_per_iter: false; default-CLI doesn't override.
    PUSH_PER_ITER="false"
    PUSH_BRANCH=""
  else
    # Pre-feature session (key never written) AND no CLI flag → adopt the new default.
    PUSH_PER_ITER="true"
    [[ -z "$PUSH_BRANCH" ]] && PUSH_BRANCH="goal/$SESSION_ID"
    RESUME_PUSH_MODE="opting-in"
    echo "[run-goal] push-per-iter: defaulting ON for resume of pre-feature session (no prior choice recorded)."
    echo "  Pass --no-push-per-iter on the next resume if you don't want this."
  fi
  RUN_MODE="resume"
else
  validate_goal_file
  CURRENT_ITER=0
  PRIOR_STATUS="new"
  echo "[run-goal] Initializing new session: $SESSION_ID"
  # Resolve push_branch default before persisting
  if [[ "$PUSH_PER_ITER" == "true" && -z "$PUSH_BRANCH" ]]; then
    PUSH_BRANCH="goal/$SESSION_ID"
  fi
  python3 - <<PY
import json, datetime
data = {
  "session_id": "$SESSION_ID",
  "started_at": datetime.datetime.now(datetime.UTC).isoformat().replace('+00:00', 'Z'),
  "current_iter": 0,
  "cli": "${CHAIN_CLI:-claude}",
  "halt_config": {
    "max_iterations": $MAX_ITER,
    "stall_window": $STALL_WINDOW,
    "regression_halt": True
  },
  "status": "in_progress",
  "last_verdict": None,
  "next_depth": "lean",
  "auto_release": $( [[ "$AUTO_RELEASE" == "true" ]] && echo "True" || echo "False" ),
  "push_per_iter": $( [[ "$PUSH_PER_ITER" == "true" ]] && echo "True" || echo "False" ),
  "push_branch": "$PUSH_BRANCH"
}
import os
with open("$SESSION_JSON", "w") as f:
  json.dump(data, f, indent=2); f.write("\n")
PY
  echo '{"journeys":{},"anti_goal_violations":[],"updated_at":""}' > "$JOURNEY_HISTORY"
  : > "$EVALUATOR_LOG"
  cat > "$LESSONS_FILE" <<EOF
# Goal Session ${SESSION_ID} — Lessons Learned

Append-only ledger of takeaways from prior iterations. The goal-evaluator
appends one entry per iteration; the goal-decomposer reads this file before
planning each iteration to avoid repeating known pitfalls.

Each entry should be 1-3 sentences capturing a non-obvious lesson — surprising
failures, regression triggers, or decisions that worked well. Avoid
restating the verdict (the evaluator-log.md already does that).
EOF
  RUN_MODE="new"
fi

# Allow --max-iter override on resume; also persist the resolved push_per_iter
# / push_branch values so a subsequent resume picks them up (key may have been
# absent in older sessions that pre-date the per-iter push feature).
python3 - <<PY
import json
d = json.load(open("$SESSION_JSON"))
d.setdefault("halt_config", {})
d["halt_config"]["max_iterations"] = $MAX_ITER
d["halt_config"]["stall_window"] = $STALL_WINDOW
if $( [[ "$AUTO_RELEASE" == "true" ]] && echo "True" || echo "False" ):
  d["auto_release"] = True
d["push_per_iter"] = $( [[ "$PUSH_PER_ITER" == "true" ]] && echo "True" || echo "False" )
d["push_branch"] = "$PUSH_BRANCH"
if "$RUN_MODE" == "resume" and d.get("status") == "REGRESSION_HALT":
  d["status"] = "in_progress"
json.dump(d, open("$SESSION_JSON","w"), indent=2); open("$SESSION_JSON","a").write("\n")
PY

# ── Export shared env for invoked agents ──────────────────────────────────
export GOAL_SESSION_ID="$SESSION_ID"
export GOAL_SESSION_DIR="$GOAL_SESSION_DIR_LOCAL"

# Auto-enable replay/time-travel trace capture unless the user opts out.
# Each successful claude invocation appends a record to <session>/trace/trace.jsonl
# (see lib/quota-retry.sh::_trace_record_invocation and lib/replay_trace.py).
if [[ "${CHAIN_DISABLE_TRACE:-false}" != "true" && -z "${CHAIN_TRACE_DIR:-}" ]]; then
  mkdir -p "$GOAL_SESSION_DIR_LOCAL/trace"
  export CHAIN_TRACE_DIR="$GOAL_SESSION_DIR_LOCAL/trace"
fi

# ── Push-per-iter: branch lifecycle ──────────────────────────────────────
# When push_per_iter is on, all iter commits land on a single per-session
# feature branch (default: goal/<sid>). New session creates the branch from
# current HEAD; resume switches to it (errors if missing).
if [[ "$PUSH_PER_ITER" == "true" ]]; then
  if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "Error: --push-per-iter requires a git repository, but $REPO_ROOT is not one." >&2
    exit 1
  fi
  if [[ -z "$PUSH_BRANCH" ]]; then
    # Belt-and-suspenders: the new-session block already defaults this; on
    # resume an empty value means session was created with push_per_iter=true
    # but somehow no branch — fall back to the default name.
    PUSH_BRANCH="goal/$SESSION_ID"
  fi
  _current_branch=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  _branch_exists=false
  if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$PUSH_BRANCH"; then
    _branch_exists=true
  fi

  if [[ "$RUN_MODE" == "new" ]]; then
    if [[ "$_branch_exists" == "true" ]]; then
      echo "Error: branch '$PUSH_BRANCH' already exists. Pick another name with --push-branch <name>, or delete the existing branch." >&2
      exit 1
    fi
    if ! git -C "$REPO_ROOT" checkout -b "$PUSH_BRANCH" >/dev/null 2>&1; then
      echo "Error: failed to create branch '$PUSH_BRANCH'." >&2
      exit 1
    fi
    echo "[run-goal] push-per-iter: created and switched to branch '$PUSH_BRANCH'."
  else
    # Resume — branch handling depends on whether the session was already
    # pushing or we're opting in mid-session via --push-per-iter.
    if [[ "$_branch_exists" == "true" ]]; then
      # Branch is there. Switch if we aren't already on it.
      if [[ "$_current_branch" != "$PUSH_BRANCH" ]]; then
        if ! git -C "$REPO_ROOT" checkout "$PUSH_BRANCH" >/dev/null 2>&1; then
          echo "Error: failed to switch to branch '$PUSH_BRANCH'. Working tree may have uncommitted changes." >&2
          exit 1
        fi
      fi
      if [[ "$RESUME_PUSH_MODE" == "opting-in" ]]; then
        echo "[run-goal] push-per-iter: opted in mid-session; joined existing branch '$PUSH_BRANCH'."
      else
        echo "[run-goal] push-per-iter: switched to branch '$PUSH_BRANCH'."
      fi
    else
      # Branch missing on resume.
      if [[ "$RESUME_PUSH_MODE" == "opting-in" ]]; then
        # User just enabled push-per-iter on a session that wasn't pushing
        # before — create the branch from current HEAD. Iter commits will
        # accumulate from this point forward; prior iters already landed on
        # whatever branch the session was previously running against.
        if ! git -C "$REPO_ROOT" checkout -b "$PUSH_BRANCH" >/dev/null 2>&1; then
          echo "Error: failed to create branch '$PUSH_BRANCH'." >&2
          exit 1
        fi
        echo "[run-goal] push-per-iter: opted in mid-session; created branch '$PUSH_BRANCH' from current HEAD."
      else
        # Session was previously pushing to this branch — its disappearance
        # is a real anomaly, not something we should silently recover from.
        echo "Error: cannot resume — branch '$PUSH_BRANCH' is missing locally." >&2
        echo "  The session was created with push-per-iter on this branch, but it no longer exists." >&2
        echo "  Either restore the branch (git fetch + git checkout -b) or start a fresh session with --reset." >&2
        exit 1
      fi
    fi
  fi
fi

ensure_phase_ports

# ── Telemetry: session_start ──────────────────────────────────────────────
record_telemetry_event "session_start" "$(jq -cn --arg m "$RUN_MODE" --argjson mi $MAX_ITER --argjson sw $STALL_WINDOW --argjson ar "$( [[ "$AUTO_RELEASE" == "true" ]] && echo true || echo false )" '{mode:$m, max_iterations:$mi, stall_window:$sw, auto_release:$ar}' 2>/dev/null || printf '{"mode":"%s","max_iterations":%d,"stall_window":%d}' "$RUN_MODE" "$MAX_ITER" "$STALL_WINDOW")"

# ── Halt detection helpers ────────────────────────────────────────────────
SESSION_START_EPOCH=$(date +%s)
QUOTA_PAUSE_COUNT_FILE="$GOAL_SESSION_DIR_LOCAL/.quota-pause-count"
[[ -f "$QUOTA_PAUSE_COUNT_FILE" ]] || echo "0" > "$QUOTA_PAUSE_COUNT_FILE"

journey_history_hash() {
  python3 -c "
import hashlib, json, sys
data = json.load(open('$JOURNEY_HISTORY'))
canonical = {'journeys': data.get('journeys', {})}
print(hashlib.sha1(json.dumps(canonical, sort_keys=True).encode()).hexdigest())
"
}

is_stalled() {
  local window="$1"
  local n
  # `$window` is a bash integer interpolated literally into the Python source.
  # The first guard is "window is positive"; `len(int)` is a type error, so
  # compare the int directly. The second guard is "we have enough hashes to
  # fill the window".
  n=$(python3 -c "
import json
hashes = open('$GOAL_SESSION_DIR_LOCAL/.history-hashes').read().splitlines() if __import__('os').path.exists('$GOAL_SESSION_DIR_LOCAL/.history-hashes') else []
if $window > 0 and len(hashes) >= $window:
  recent = hashes[-$window:]
  print(1 if len(set(recent)) == 1 else 0)
else:
  print(0)
")
  [[ "$n" == "1" ]]
}

write_session_summary() {
  local final_verdict="$1"
  local total_iterations="$2"
  local now_epoch=$(date +%s)
  local wall_time=$(( now_epoch - SESSION_START_EPOCH ))
  local quota_pauses
  quota_pauses=$(cat "$QUOTA_PAUSE_COUNT_FILE")
  python3 - <<PY
import json
d = json.load(open("$SESSION_JSON"))
d["status"] = "$final_verdict"
d["finished_at"] = __import__("datetime").datetime.now(__import__("datetime").UTC).isoformat().replace('+00:00','Z')
d["total_iterations"] = $total_iterations
d["wall_time_seconds"] = $wall_time
d["quota_pause_count"] = $quota_pauses
json.dump(d, open("$SESSION_JSON","w"), indent=2); open("$SESSION_JSON","a").write("\n")
PY
  # Branch info (only when push_per_iter is on)
  local branch_section=""
  if [[ "$PUSH_PER_ITER" == "true" && -n "$PUSH_BRANCH" ]]; then
    branch_section=$(printf '\n## Branch\n\nThis session pushed iteration commits to `%s`. Open a PR with:\n\n    gh pr create --base main --head %s \\\n      --title "feat: %s — %s" \\\n      --body-file runs/goal-session-%s/summary.md\n' \
      "$PUSH_BRANCH" "$PUSH_BRANCH" "$SESSION_ID" "$final_verdict" "$SESSION_ID")
  fi

  cat > "$SUMMARY_FILE" <<EOF
# Goal Session Summary — ${SESSION_ID}

**Final verdict:** ${final_verdict}
**Total iterations:** ${total_iterations}
**Wall time (seconds):** ${wall_time}
**Quota pauses:** ${quota_pauses}
**Started:** $(python3 -c "import json; print(json.load(open('$SESSION_JSON'))['started_at'])")
**Finished:** $(python3 -c "import json; print(json.load(open('$SESSION_JSON'))['finished_at'])")
${branch_section}

## Final journey state

$(python3 -c "
import json
d = json.load(open('$JOURNEY_HISTORY'))['journeys']
if not d:
    print('(no journeys recorded)')
else:
    print('| Journey | Status | Last passing iter |')
    print('|---|---|---|')
    for jid, info in sorted(d.items()):
        print(f\"| {jid} | {info.get('status','unknown')} | {info.get('last_passing_iter') or '-'} |\")
")

## Anti-goal violations

$(python3 -c "
import json
v = json.load(open('$JOURNEY_HISTORY')).get('anti_goal_violations', [])
if not v:
    print('(none)')
else:
    for entry in v:
        sev = entry.get('severity','?')
        ag = entry.get('anti_goal','?')
        it = entry.get('iter','?')
        print(f\"- [{sev}] {ag} (iter {it})\")
")

## Telemetry

See \`runs/goal-session-${SESSION_ID}/telemetry.jsonl\` for the structured event log.
EOF
  record_telemetry_event "session_end" "$(jq -cn --arg fv "$final_verdict" --argjson ti $total_iterations --argjson wt $wall_time --argjson qp $quota_pauses '{final_verdict:$fv, total_iterations:$ti, wall_time_seconds:$wt, quota_pause_count:$qp}' 2>/dev/null || printf '{"final_verdict":"%s","total_iterations":%d}' "$final_verdict" "$total_iterations")"
  echo "[run-goal] Session summary: $SUMMARY_FILE"
  _render_session_index_html
  local _idx_html="$REPO_ROOT/reports/goal-session-${SESSION_ID}-index.html"
  [[ -f "$_idx_html" ]] && echo "[run-goal] Session HTML: file://$_idx_html"
}

# Trap: on SIGINT/SIGTERM, write ABORTED summary
on_abort() {
  echo "[run-goal] Aborted by user signal. Writing summary." >&2
  write_session_summary "ABORTED" "$CURRENT_ITER"
  exit 130
}
trap on_abort INT TERM

# ── Main loop ─────────────────────────────────────────────────────────────
while true; do
  # 1. Halt checks (always first)
  if [[ $CURRENT_ITER -ge $MAX_ITER ]]; then
    echo "[run-goal] BUDGET_EXHAUSTED — reached max-iter cap of $MAX_ITER."
    record_telemetry_event "halt" '{"reason":"BUDGET_EXHAUSTED","detected_at_step":"pre_decomposer"}'
    write_session_summary "BUDGET_EXHAUSTED" "$CURRENT_ITER"
    exit 0
  fi

  if [[ $CURRENT_ITER -gt 0 ]] && is_stalled "$STALL_WINDOW"; then
    echo "[run-goal] STALLED — last $STALL_WINDOW iterations made no journey progress."
    record_telemetry_event "halt" '{"reason":"STALLED","detected_at_step":"pre_decomposer"}'
    write_session_summary "STALLED" "$CURRENT_ITER"
    exit 0
  fi

  ITER_NAME="goal-${SESSION_ID}-iter-${CURRENT_ITER}"
  ITER_DIR="$GOAL_SESSION_DIR_LOCAL/iter-${CURRENT_ITER}"
  mkdir -p "$ITER_DIR"
  export GOAL_ITER_INDEX="$CURRENT_ITER"
  export GOAL_ITER_NAME="$ITER_NAME"

  # Capture a working-tree snapshot at the start of this iteration. This is a
  # zero-impact recording: `git stash create` builds a stash commit object
  # without touching the working tree or stash list. The SHA lets the operator
  # `git diff <sha>..HEAD` to see exactly what this iteration changed, and
  # `git reset --hard <sha>` (advanced) to roll back. Best-effort; failures
  # write an empty file and do not block the iteration.
  if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    if _snap=$(git -C "$REPO_ROOT" stash create 2>/dev/null); then
      printf '%s' "$_snap" > "$ITER_DIR/snapshot-sha"
    else
      : > "$ITER_DIR/snapshot-sha"
    fi
  fi

  PRIOR_VERDICT=$(python3 -c "import json; print(json.load(open('$SESSION_JSON')).get('last_verdict') or 'null')")
  PRIOR_DEPTH=$(python3 -c "import json; print(json.load(open('$SESSION_JSON')).get('next_depth') or 'lean')")

  record_telemetry_event "iter_start" "$(jq -cn --arg n "$ITER_NAME" --arg pv "$PRIOR_VERDICT" --arg pd "$PRIOR_DEPTH" --arg ss "$(cat "$ITER_DIR/snapshot-sha" 2>/dev/null || echo "")" '{iter_name:$n, prior_verdict:$pv, prior_depth:$pd, snapshot_sha:$ss}' 2>/dev/null || printf '{"iter_name":"%s"}' "$ITER_NAME")"

  echo ""
  echo "════════════════════════════════════════════════════════════════════"
  echo "[run-goal] Iteration $CURRENT_ITER ($ITER_NAME)"
  echo "════════════════════════════════════════════════════════════════════"

  # 2. Goal decomposer
  if [[ $CURRENT_ITER -eq 0 ]]; then
    DECOMPOSER_MODE="baseline"
  else
    DECOMPOSER_MODE="next"
  fi

  echo "[run-goal] Step 1: goal-decomposer (mode: $DECOMPOSER_MODE)"
  # Pre-trim historical state — pass only the tail to the decomposer so token
  # usage stays flat as the session grows. Spec asks for "last 3 entries";
  # 200 lines is conservative and covers multi-paragraph entries.
  EVALUATOR_LOG_TAIL=$(_tail_or_placeholder "$EVALUATOR_LOG" 200 "(no entries yet — first iteration)")
  LESSONS_TAIL=$(_tail_or_placeholder "$LESSONS_FILE" 200 "(no lessons recorded yet)")
  cd "$REPO_ROOT"
  _decomp_start=$(record_agent_invocation_start "goal-decomposer")
  _decomp_rc=0
  claude_with_quota_retry -p "You are the goal-decomposer agent for goal-mode iteration planning.

Mode: $DECOMPOSER_MODE
Session ID: $SESSION_ID
Iteration index: $CURRENT_ITER
Iter name: $ITER_NAME
Prior verdict: $PRIOR_VERDICT
Prior depth: $PRIOR_DEPTH

Project template: .claude/project-template.md
Project goal: $GOAL_FILE  <-- read 'Must-have user journeys' and 'Anti-goals'
Agent instructions: .claude/agents/goal-decomposer.md  <-- read this first
(CLAUDE.md is already in your system prompt — do not Read it again.)

Recent evaluator log entries (last 3, pre-trimmed):
\`\`\`
$EVALUATOR_LOG_TAIL
\`\`\`
Lessons learned (full file, append-only):
\`\`\`
$LESSONS_TAIL
\`\`\`
Journey history: $JOURNEY_HISTORY  <-- read for full journey state

$( [[ $CURRENT_ITER -gt 0 && -f "$GOAL_SESSION_DIR_LOCAL/iter-$((CURRENT_ITER-1))/eval.md" ]] && echo "Last iteration eval: $GOAL_SESSION_DIR_LOCAL/iter-$((CURRENT_ITER-1))/eval.md")

Apply the TOKEN AND QUESTIONING POLICY from .claude/core.md strictly.

Write the iteration spec to: docs/phases/${ITER_NAME}.md

The spec MUST include a 'Goal Mode Metadata' section with at minimum:
  - Mode: $DECOMPOSER_MODE
  - Depth: lean | full
  - Target journeys: <comma-separated journey IDs>

Do NOT write code or implement anything. STOP after writing the spec." || _decomp_rc=$?

  record_agent_invocation_end "goal-decomposer" "$_decomp_start" "$_decomp_rc"

  if [[ $_decomp_rc -ne 0 ]]; then
    echo "[run-goal] goal-decomposer failed with exit $_decomp_rc — aborting." >&2
    record_telemetry_event "halt" '{"reason":"DECOMPOSER_FAILED","detected_at_step":"decomposer"}'
    write_session_summary "ABORTED" "$CURRENT_ITER"
    exit "$_decomp_rc"
  fi

  ITER_SPEC_PATH="$REPO_ROOT/docs/phases/${ITER_NAME}.md"
  if [[ ! -f "$ITER_SPEC_PATH" ]]; then
    echo "[run-goal] goal-decomposer did not write spec at $ITER_SPEC_PATH — aborting." >&2
    write_session_summary "ABORTED" "$CURRENT_ITER"
    exit 1
  fi

  # Parse depth
  DEPTH=$(grep -m1 -E '^[[:space:]]*-?[[:space:]]*\*\*Depth:\*\*' "$ITER_SPEC_PATH" \
            | sed -E 's/.*\*\*Depth:\*\*[[:space:]]*//; s/[[:space:]]+$//' \
            | tr '[:upper:]' '[:lower:]')
  if [[ -z "$DEPTH" ]]; then
    DEPTH=$(grep -m1 -E '^[[:space:]]*-?[[:space:]]*Depth:' "$ITER_SPEC_PATH" \
              | sed -E 's/.*Depth:[[:space:]]*//; s/[[:space:]]+$//' \
              | tr '[:upper:]' '[:lower:]')
  fi
  if [[ "$DEPTH" != "lean" && "$DEPTH" != "full" ]]; then
    echo "[run-goal] Could not parse Depth (expected 'lean' or 'full') from $ITER_SPEC_PATH. Defaulting to lean." >&2
    DEPTH="lean"
  fi

  TARGET_JOURNEYS=$(grep -m1 -E '^[[:space:]]*-?[[:space:]]*\*\*Target journeys:\*\*' "$ITER_SPEC_PATH" \
                      | sed -E 's/.*\*\*Target journeys:\*\*[[:space:]]*//' || echo "")

  echo "[run-goal] Iter spec depth: $DEPTH"
  echo "[run-goal] Target journeys: ${TARGET_JOURNEYS:-(none parsed)}"
  record_telemetry_event "iter_dispatch" "$(jq -cn --arg d "$DEPTH" --arg tj "$TARGET_JOURNEYS" '{depth:$d, target_journeys:$tj}' 2>/dev/null || printf '{"depth":"%s"}' "$DEPTH")"

  # 3. Dispatch
  if [[ "$DEPTH" == "full" ]]; then
    # Propagate --fast into the full-iteration path so the parallel post-dev
    # fanout in run-phase.sh kicks in. Lean iterations have no parallelisable
    # surface (dev → review → browser-qa → demo are strictly sequential), so
    # --fast is a no-op there and we just log the fact for visibility.
    _full_extra_args=(--no-finalize)
    if [[ "$FAST_MODE" == "true" ]]; then
      _full_extra_args+=(--fast)
    fi
    echo "[run-goal] Dispatching FULL pipeline via run-phase.sh ${_full_extra_args[*]} ..."
    if grep -q '\-\-no-finalize' "$SCRIPT_DIR/run-phase.sh"; then
      bash "$SCRIPT_DIR/run-phase.sh" "$ITER_NAME" "${_full_extra_args[@]}" || _exec_rc=$?
    else
      echo "[run-goal] run-phase.sh does not yet support --no-finalize. Falling back to lean for safety." >&2
      bash "$SCRIPT_DIR/goal-iter-lean.sh" "$ITER_NAME" || _exec_rc=$?
    fi
  else
    if [[ "$FAST_MODE" == "true" ]]; then
      echo "[run-goal] --fast is a no-op for lean iterations (no parallelisable steps); Tier 1 polish + per-agent --effort overrides still apply."
    fi
    echo "[run-goal] Dispatching LEAN pipeline via goal-iter-lean.sh ..."
    bash "$SCRIPT_DIR/goal-iter-lean.sh" "$ITER_NAME" || _exec_rc=$?
  fi
  _exec_rc=${_exec_rc:-0}

  # 4. Goal evaluator
  echo "[run-goal] Step 3: goal-evaluator"
  EVAL_OUTPUT="$ITER_DIR/eval.md"
  # Pre-trim — evaluator spec asks for "last 5 entries"; 300 lines covers it.
  EVALUATOR_LOG_TAIL_5=$(_tail_or_placeholder "$EVALUATOR_LOG" 300 "(no entries yet — first evaluation)")
  cd "$REPO_ROOT"
  _eval_start=$(record_agent_invocation_start "goal-evaluator")
  _eval_rc=0
  claude_with_quota_retry -p "You are the goal-evaluator agent for goal-mode iteration evaluation.

Session ID: $SESSION_ID
Iteration index: $CURRENT_ITER
Iter name: $ITER_NAME
Depth dispatched: $DEPTH

Project goal: $GOAL_FILE  <-- read 'Must-have user journeys' and 'Anti-goals'
Iter spec: $ITER_SPEC_PATH
Agent instructions: .claude/agents/goal-evaluator.md  <-- read this first
(CLAUDE.md is already in your system prompt — do not Read it again.)

Iteration artifacts (read what exists):
  Dev handoff: docs/handoffs/${ITER_NAME}-dev.md
  Review report: reports/reviews/${ITER_NAME}-review.md
  QA report: reports/qa/${ITER_NAME}-qa.md (full mode only)
  Audit handoff: docs/handoffs/${ITER_NAME}-audit.md (full mode only)
  Browser QA results: reports/phase-${ITER_NAME}-ui-test-results.md
  Evidence: reports/qa/${ITER_NAME}-evidence/

Prior session state:
  Journey history: $JOURNEY_HISTORY  <-- update this with new state (full atomic write)
  Evaluator log: $EVALUATOR_LOG  <-- append a new entry; do not overwrite or read the full file (last 5 entries pre-trimmed below)
  Lessons file: $LESSONS_FILE  <-- append a brief lesson entry capturing a non-obvious takeaway (1-3 sentences). Skip if nothing surprising happened.

Recent evaluator log entries (last 5, pre-trimmed):
\`\`\`
$EVALUATOR_LOG_TAIL_5
\`\`\`

Apply the TOKEN AND QUESTIONING POLICY from .claude/core.md strictly.

Write your verdict to: $EVAL_OUTPUT

The verdict line MUST appear at the top of $EVAL_OUTPUT and start exactly with:
**Verdict:** GOAL_ACHIEVED
  or **Verdict:** CONTINUE
  or **Verdict:** ESCALATE
  or **Verdict:** REGRESSION
  or **Verdict:** STALLED

Also include a 'Depth Recommendation For Next Iteration:' line: lean or full.

Then update $JOURNEY_HISTORY (full atomic write) and append an entry to $EVALUATOR_LOG.
STOP." || _eval_rc=$?

  record_agent_invocation_end "goal-evaluator" "$_eval_start" "$_eval_rc"

  if [[ ! -f "$EVAL_OUTPUT" ]]; then
    echo "[run-goal] goal-evaluator did not write $EVAL_OUTPUT — treating as ABORTED." >&2
    write_session_summary "ABORTED" "$CURRENT_ITER"
    exit 1
  fi

  # Parse verdict
  VERDICT=$(grep -m1 -E '^\*\*Verdict:\*\*' "$EVAL_OUTPUT" | sed -E 's/^\*\*Verdict:\*\*[[:space:]]*//' | awk '{print $1}')
  NEXT_DEPTH=$(grep -m1 -E 'Depth Recommendation For Next Iteration:' "$EVAL_OUTPUT" | sed -E 's/.*Iteration:\*?\*?[[:space:]]*//' | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
  [[ "$NEXT_DEPTH" != "lean" && "$NEXT_DEPTH" != "full" ]] && NEXT_DEPTH="lean"

  # Capture journey-history hash for stall detection
  HASH=$(journey_history_hash)
  echo "$HASH" >> "$GOAL_SESSION_DIR_LOCAL/.history-hashes"

  # Build the iteration summary MD (via summarizer agent), then render its HTML.
  # The MD is the source of truth — the renderer just visualizes it.
  # Non-blocking; the session index is refreshed by every write_session_summary call.
  _run_iteration_summarizer "$ITER_NAME"
  _render_iter_html "$ITER_NAME"
  _iter_md="$REPO_ROOT/reports/phase-${ITER_NAME}-iteration-summary.md"
  _iter_html="$REPO_ROOT/reports/phase-${ITER_NAME}-summary.html"
  [[ -f "$_iter_md" ]]   && echo "[run-goal] Iteration summary MD:   $_iter_md"
  [[ -f "$_iter_html" ]] && echo "[run-goal] Iteration summary HTML: file://$_iter_html"

  # Update session.json
  python3 - <<PY
import json
d = json.load(open("$SESSION_JSON"))
d["current_iter"] = $CURRENT_ITER + 1
d["last_verdict"] = "$VERDICT"
d["next_depth"] = "$NEXT_DEPTH"
d["status"] = "in_progress"
d["updated_at"] = __import__("datetime").datetime.now(__import__("datetime").UTC).isoformat().replace('+00:00','Z')
json.dump(d, open("$SESSION_JSON","w"), indent=2); open("$SESSION_JSON","a").write("\n")
PY

  # Compute deltas (best-effort)
  DELTAS=$(python3 -c "
import json
try:
    d = json.load(open('$JOURNEY_HISTORY'))
    js = d.get('journeys', {})
    counts = {'newly_passing':0, 'newly_failing':0, 'regressed':0, 'anti_goal_violations': len(d.get('anti_goal_violations',[]))}
    for jid, info in js.items():
        if info.get('status') in ('regressed',):
            counts['regressed'] += 1
        elif info.get('last_verified_iter') == '$ITER_NAME' and info.get('status') == 'passing':
            counts['newly_passing'] += 1
        elif info.get('last_verified_iter') == '$ITER_NAME' and info.get('status') == 'failing':
            counts['newly_failing'] += 1
    print(json.dumps(counts))
except Exception as e:
    print(json.dumps({'error': str(e)}))
")

  record_telemetry_event "iter_end" "$(jq -cn --arg n "$ITER_NAME" --arg v "$VERDICT" --arg nd "$NEXT_DEPTH" --argjson dl "$DELTAS" '{iter_name:$n, verdict:$v, next_depth:$nd, journey_deltas:$dl}' 2>/dev/null || printf '{"iter_name":"%s","verdict":"%s"}' "$ITER_NAME" "$VERDICT")"

  echo "[run-goal] Verdict: $VERDICT (next depth: $NEXT_DEPTH)"

  # 4b. Push per iter (if enabled). Direct git only — no model invocation.
  # Eligibility: CONTINUE / ESCALATE / GOAL_ACHIEVED. REGRESSION / STALLED
  # halts skip the push so the remote isn't left in a state the user hasn't
  # had a chance to inspect.
  if [[ "$PUSH_PER_ITER" == "true" ]]; then
    case "$VERDICT" in
      CONTINUE|ESCALATE|GOAL_ACHIEVED)
        if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]]; then
          _push_summary=$(printf '%s' "$DELTAS" | jq -r '"passing+\(.newly_passing // 0) failing+\(.newly_failing // 0) regressed+\(.regressed // 0)"' 2>/dev/null || echo "deltas-unavailable")
          _push_np=$(printf '%s' "$DELTAS" | jq -r '.newly_passing // 0' 2>/dev/null || echo 0)
          _push_nf=$(printf '%s' "$DELTAS" | jq -r '.newly_failing // 0' 2>/dev/null || echo 0)
          _push_rg=$(printf '%s' "$DELTAS" | jq -r '.regressed // 0' 2>/dev/null || echo 0)
          _push_av=$(printf '%s' "$DELTAS" | jq -r '.anti_goal_violations // 0' 2>/dev/null || echo 0)
          _push_msg=$(printf 'goal(%s): iter %s — %s (%s)\n\nTarget journeys: %s\nVerdict: %s\nNewly passing: %s\nNewly failing: %s\nRegressed: %s\nAnti-goal violations: %s\nIter spec: docs/phases/%s.md\nIter eval: runs/goal-session-%s/iter-%s/eval.md\n' \
            "$SESSION_ID" "$CURRENT_ITER" "$VERDICT" "$_push_summary" \
            "${TARGET_JOURNEYS:-(none parsed)}" "$VERDICT" \
            "$_push_np" "$_push_nf" "$_push_rg" "$_push_av" \
            "$ITER_NAME" "$SESSION_ID" "$CURRENT_ITER")

          _push_ok=false
          _push_sha=""
          _push_err=""
          if git -C "$REPO_ROOT" add -A 2>/dev/null; then
            if git -C "$REPO_ROOT" commit -m "$_push_msg" >/dev/null 2>&1; then
              _push_sha=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "")
              if git -C "$REPO_ROOT" push -u origin HEAD >/dev/null 2>&1; then
                _push_ok=true
                echo "[run-goal] push-per-iter: pushed iter $CURRENT_ITER (${_push_sha:0:8}) to '$PUSH_BRANCH'"
              else
                _push_err="push failed"
                echo "[run-goal] push-per-iter: WARNING — commit ${_push_sha:0:8} was created but 'git push origin HEAD' failed; commit is local only. Continuing." >&2
              fi
            else
              _push_err="commit failed"
              echo "[run-goal] push-per-iter: WARNING — 'git commit' failed for iter $CURRENT_ITER. Continuing." >&2
            fi
          else
            _push_err="add failed"
            echo "[run-goal] push-per-iter: WARNING — 'git add -A' failed for iter $CURRENT_ITER. Continuing." >&2
          fi

          record_telemetry_event "iter_push" "$(jq -cn \
            --arg b "$PUSH_BRANCH" \
            --arg sha "$_push_sha" \
            --argjson ok "$_push_ok" \
            --arg err "$_push_err" \
            --arg verdict "$VERDICT" \
            '{branch:$b, commit_sha:$sha, success:$ok, error:$err, verdict:$verdict}' 2>/dev/null || printf '{"branch":"%s","success":%s}' "$PUSH_BRANCH" "$_push_ok")"
        else
          echo "[run-goal] push-per-iter: iter $CURRENT_ITER produced no working-tree changes; skipping commit + push."
          record_telemetry_event "iter_push" "$(jq -cn --arg b "$PUSH_BRANCH" --arg verdict "$VERDICT" '{branch:$b, success:true, skipped:"no_changes", verdict:$verdict}' 2>/dev/null || echo '{}')"
        fi
        ;;
      REGRESSION|STALLED)
        echo "[run-goal] push-per-iter: skipping push for $VERDICT — branch left at prior iter's HEAD for inspection."
        record_telemetry_event "iter_push" "$(jq -cn --arg b "$PUSH_BRANCH" --arg verdict "$VERDICT" '{branch:$b, success:true, skipped:"halt_verdict", verdict:$verdict}' 2>/dev/null || echo '{}')"
        ;;
    esac
  fi

  # 5. Halt-on-verdict
  case "$VERDICT" in
    GOAL_ACHIEVED)
      # Render the one-time delivered wrap BEFORE write_session_summary so the
      # session-index renderer (invoked inside write_session_summary) can find
      # delivered.html and surface a prominent link to it. Non-blocking.
      _render_final_delivered "$SESSION_ID"
      write_session_summary "GOAL_ACHIEVED" "$((CURRENT_ITER+1))"
      if [[ "$AUTO_RELEASE" == "true" ]]; then
        # Direct gh pr create from $PUSH_BRANCH — every iter commit is already
        # there from the per-iter push, so we only need to open the PR. We
        # deliberately do NOT invoke finalize-phase.sh / release-manager here:
        # that path would create a separate `phase/<iter-name>` branch via
        # release-manager.md's policy, fragmenting the single-branch model.
        if [[ "$PUSH_PER_ITER" != "true" || -z "$PUSH_BRANCH" ]]; then
          echo "[run-goal] --auto-release: skipping PR creation — per-iter push was off, so no session branch exists." >&2
          echo "[run-goal]   To enable: start a fresh session with --push-per-iter, or commit + push manually." >&2
          record_telemetry_event "goal_release_pr_skipped" '{"reason":"no_session_branch"}'
        else
          _final_iter_count=$((CURRENT_ITER+1))
          _pr_title="goal(${SESSION_ID}): GOAL_ACHIEVED after ${_final_iter_count} iterations"
          if check_gh_auth; then
            _pr_create_out=""
            if _pr_create_out=$(gh pr create --base main --head "$PUSH_BRANCH" --title "$_pr_title" --body-file "$SUMMARY_FILE" 2>&1); then
              echo "[run-goal] --auto-release: opened PR from $PUSH_BRANCH"
              echo "[run-goal]   $_pr_create_out"
              record_telemetry_event "goal_release_pr_created" "$(jq -cn --arg b "$PUSH_BRANCH" --arg url "$_pr_create_out" '{branch:$b, pr_url:$url}' 2>/dev/null || echo '{}')"
            else
              echo "[run-goal] --auto-release: gh pr create failed:" >&2
              echo "[run-goal]   $_pr_create_out" >&2
              echo "[run-goal]   Branch $PUSH_BRANCH is already pushed. Create the PR manually:" >&2
              echo "[run-goal]   gh pr create --base main --head $PUSH_BRANCH --title \"$_pr_title\" --body-file $SUMMARY_FILE" >&2
              record_telemetry_event "goal_release_pr_failed" "$(jq -cn --arg b "$PUSH_BRANCH" --arg err "$_pr_create_out" '{branch:$b, error:$err}' 2>/dev/null || echo '{}')"
            fi
          else
            echo "[run-goal] --auto-release: gh CLI not authenticated. Branch $PUSH_BRANCH is already pushed." >&2
            echo "[run-goal]   To open the PR: gh auth login && \\" >&2
            echo "[run-goal]     gh pr create --base main --head $PUSH_BRANCH --title \"$_pr_title\" --body-file $SUMMARY_FILE" >&2
            record_telemetry_event "goal_release_pr_skipped" '{"reason":"gh_not_authenticated"}'
          fi
        fi
      fi
      exit 0
      ;;
    REGRESSION)
      python3 - <<PY
import json
d = json.load(open("$SESSION_JSON"))
d["status"] = "REGRESSION_HALT"
json.dump(d, open("$SESSION_JSON","w"), indent=2); open("$SESSION_JSON","a").write("\n")
PY
      record_telemetry_event "halt" '{"reason":"REGRESSION_HALT","detected_at_step":"post_evaluator"}'
      write_session_summary "REGRESSION_HALT" "$((CURRENT_ITER+1))"
      echo "[run-goal] REGRESSION_HALT — review $EVAL_OUTPUT, fix the regression, then resume with --acknowledge-regression." >&2
      exit 1
      ;;
    STALLED)
      record_telemetry_event "halt" '{"reason":"STALLED","detected_at_step":"post_evaluator"}'
      write_session_summary "STALLED" "$((CURRENT_ITER+1))"
      echo "[run-goal] STALLED per evaluator. Edit goal.md and resume with --resume." >&2
      exit 0
      ;;
    CONTINUE|ESCALATE)
      CURRENT_ITER=$((CURRENT_ITER+1))
      ;;
    *)
      echo "[run-goal] Unknown verdict '$VERDICT' — treating as CONTINUE." >&2
      CURRENT_ITER=$((CURRENT_ITER+1))
      ;;
  esac
done
