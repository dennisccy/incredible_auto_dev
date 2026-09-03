#!/usr/bin/env bash
# Guard hook: read-path hygiene (PreToolUse / Bash).
#
# Turns `.claude/core.md` § "File Paths in Bash" from advisory prose into a
# machine-enforced rule, so a dispatched agent never stalls the pipeline on a
# human approval prompt it cannot get. Prose alone did not hold: goal session
# contract-pack-v0 iter 1 stalled on
# `cd .../contracts && grep -rn "book_snapshot" workstation_contracts/*.py`
# with the rule already in core.md AND in the dispatch prompt's search-path note.
#
# On match this DENIES with a corrective message naming the rewrite, so the agent
# self-corrects on its next turn instead of waiting for a human. The detection
# logic lives in lib/read_path_hygiene.py (see its docstring for the two rules).
#
# I/O modes mirror guard-dangerous-commands.sh (SEC-7):
#   argv mode  — command as $1 (run-evals, test harness, Codex): GUARD lines on
#     stderr + exit 1 on match.
#   stdin mode — the Claude Code PreToolUse protocol: JSON on stdin
#     (.tool_input.command). On match emit permissionDecision "deny" JSON on
#     stdout and exit 0 — the settings wrapper is `|| true`, so the exit code
#     carries no signal on Claude and the stdout JSON is the enforcement channel.
# Fail-open on missing/unparseable input or a missing python3.

CMD="${1:-}"
INPUT_MODE="argv"
if [ -z "$CMD" ] && [ ! -t 0 ]; then
  _payload=$(cat 2>/dev/null || true)
  if [ -n "$_payload" ]; then
    if command -v jq >/dev/null 2>&1; then
      CMD=$(printf '%s' "$_payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || CMD=""
    else
      CMD=$(printf '%s' "$_payload" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command") or "")' 2>/dev/null) || CMD=""
    fi
    if [ -n "$CMD" ]; then INPUT_MODE="stdin"; fi
  fi
fi
[ -z "$CMD" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

_HOOK_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
_DETECTOR="$_HOOK_DIR/lib/read_path_hygiene.py"
[ -f "$_DETECTOR" ] || exit 0

_deny() {
  echo "GUARD: $1" >&2
  echo "GUARD: command was: $CMD" >&2
  if [ "$INPUT_MODE" = "stdin" ]; then
    _reason="guard-read-path-hygiene: $1"
    if command -v jq >/dev/null 2>&1; then
      jq -cn --arg r "$_reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    else
      python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":sys.argv[1]}}, separators=(",",":")))' "$_reason"
    fi
    exit 0
  fi
  exit 1
}

_verdict=$(printf '%s' "$CMD" | python3 "$_DETECTOR" 2>/dev/null) || _verdict=""
[ -n "$_verdict" ] && _deny "$_verdict"
exit 0
