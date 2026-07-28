#!/usr/bin/env bash
# plain-language.sh — PLAIN-1: plain-English explanations for status/verdict codes.
#
# Sourced by run-goal.sh and run-phase.sh. Every function ADDS lines next to the
# existing code lines; nothing here may print a machine-parsed marker (**Verdict:**,
# H2 headings, Depth Recommendation, Target journeys:) — tests/automation/
# test-plain-language.sh enforces that, plus full key coverage.
#
# Single source of truth for the plain wording. docs/READING-REPORTS.md and
# skills/plain-language.md mirror these sentences; change them together.
#
# All functions print to stdout and return 0 (callers add >&2 when the
# neighbouring banner writes to stderr); unknown keys are safe no-ops so a new
# status can never crash an engine running under set -euo pipefail.

PLAIN_LANG_GUIDE="docs/READING-REPORTS.md"

plain_goal_status_keys() {
  cat <<'KEYS'
GOAL_ACHIEVED
BUDGET_EXHAUSTED
STALLED
REGRESSION_HALT
ABORTED
ABORT_MALFORMED
GATE_BLOCKED
AWAITING_BLUEPRINT_APPROVAL
AWAITING_INTENT_REVIEW
AWAITING_PUMP
AWAITING_GITHUB_AUTH
AWAITING_DISK
AWAITING_HOST_GUARD
KEYS
  return 0
}

plain_goal_verdict_keys() {
  cat <<'KEYS'
GOAL_ACHIEVED
CONTINUE
ESCALATE
REGRESSION
STALLED
KEYS
  return 0
}

plain_phase_keys() {
  cat <<'KEYS'
review_pass
review_fail
qa_pass
qa_fail
all_passed
KEYS
  return 0
}

# explain_goal_status STATUS [SESSION_ID] [REPO_ROOT]
# Prints 1-2 plain sentences for STATUS, a stable pointer to the reading guide,
# and (when the args are given and the file exists) the friendliest artifact.
explain_goal_status() {
  local _st="${1:-}" _sid="${2:-}" _root="${3:-}"
  case "$_st" in
    GOAL_ACHIEVED)
      echo "  The goal is complete: every must-have journey works and no rule was broken."
      echo "  Nothing to fix — open the Session HTML above to see what was delivered."
      ;;
    BUDGET_EXHAUSTED)
      echo "  The session stopped because it reached the iteration limit you set (--max-iter). Nothing is broken."
      echo "  To build more: resume this session with a higher --max-iter."
      ;;
    STALLED)
      echo "  The chain stopped because it could not make progress on its own. What was built so far still works."
      echo "  Read the last evaluation, unblock the problem (or edit docs/goal.md), then resume."
      ;;
    REGRESSION_HALT)
      echo "  Something that worked before is broken now, so the chain stopped to protect your product."
      echo "  Read the evaluation named above; after you fix or accept the break, resume with --acknowledge-regression."
      ;;
    ABORTED)
      echo "  The run was interrupted before it finished this iteration. Nothing is lost."
      echo "  Resume when ready — it continues from the last saved point."
      ;;
    ABORT_MALFORMED)
      echo "  The evaluator wrote an unreadable verdict twice in a row, so the chain stopped instead of guessing. Your product is unchanged."
      echo "  Inspect the eval file named above, then resume."
      ;;
    GATE_BLOCKED)
      echo "  A project rule (gate) rejected this iteration's plan, so the chain paused before building anything."
      echo "  Check the gate verdict file above, fix the input, then resume."
      ;;
    AWAITING_BLUEPRINT_APPROVAL)
      echo "  The chain is paused, not broken — nothing runs until you review the blueprint and resume."
      ;;
    AWAITING_INTENT_REVIEW)
      echo "  The chain is paused, not broken — nothing runs until you finish this checkpoint and resume."
      ;;
    AWAITING_PUMP)
      echo "  The Claude Code session that runs the agents went away, so the engine paused safely."
      echo "  Re-open Claude Code in this repo and run /goal-resume — it repeats the interrupted iteration."
      ;;
    AWAITING_GITHUB_AUTH)
      echo "  The chain paused because it cannot push to GitHub (login missing or expired). Your product is fine."
      echo "  Run 'gh auth login', then resume."
      ;;
    AWAITING_DISK)
      echo "  The chain paused because this computer is low on disk space — it never builds in that state."
      echo "  Free some space (the command above helps), then resume."
      ;;
    AWAITING_HOST_GUARD)
      echo "  The chain paused because this computer's hardware protection is not in place — it never builds unprotected."
      echo "  Follow the reason printed above (project-extensions/host-guard/README.md), then resume."
      ;;
  esac
  echo "  Read more: ${PLAIN_LANG_GUIDE}  (what each status and verdict means)"
  if [[ -n "$_sid" && -n "$_root" && -f "$_root/reports/goal-session-${_sid}-index.html" ]]; then
    echo "  Friendly overview: file://$_root/reports/goal-session-${_sid}-index.html"
  fi
  return 0
}

# explain_goal_verdict VERDICT NEXT_DEPTH
# One added line under the per-iteration "Verdict:" line. Unknown verdict: silent.
explain_goal_verdict() {
  local _v="${1:-}" _depth="${2:-}" _gloss="" _next=""
  case "$_v" in
    GOAL_ACHIEVED) _gloss="every must-have journey now works, so the session will finish." ;;
    CONTINUE)      _gloss="normal progress — the chain plans and builds the next piece by itself." ;;
    ESCALATE)      _gloss="the last round found something tricky, so the next round uses the slower, more careful pipeline." ;;
    REGRESSION)    _gloss="something that worked before is broken — the chain is stopping so you can look." ;;
    STALLED)       _gloss="the evaluator sees no useful next step it can do alone — it is stopping to ask for your help." ;;
    *) return 0 ;;
  esac
  case "$_v" in
    CONTINUE|ESCALATE)
      case "$_depth" in
        lean) _next=" Next: a quick build-and-check round." ;;
        full) _next=" Next: a full round with extra review, audit and UX checks." ;;
      esac
      ;;
  esac
  echo "  In plain words: ${_gloss}${_next}"
  return 0
}

# explain_phase KEY — one plain line for run-phase.sh call sites.
explain_phase() {
  case "${1:-}" in
    review_pass) echo "In plain words: the reviewer checked the new code and approved it." ;;
    review_fail) echo "In plain words: the reviewer found problems. The developer agent will fix them and try again — you do not need to do anything." ;;
    qa_pass)     echo "In plain words: all automated tests and checks passed." ;;
    qa_fail)     echo "In plain words: testing found problems. The developer agent will fix them and the checks run again — you do not need to do anything." ;;
    all_passed)  echo "  In plain words: this phase is done — code written, reviewed, and tested, and everything passed. Start with the 'What to click' file below to try it yourself." ;;
  esac
  return 0
}
