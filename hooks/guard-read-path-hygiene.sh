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
# Acceptance philosophy: deny only a shape PROVEN to stall approval -- an
# observed incident, Claude Code's own hard-gate table, or documented core.md
# behaviour -- and fail open on every shape this cannot parse or does not
# recognize. Rules A (relative-path content read after `cd`), B (recursive
# search rooted unbounded) and C1-C3 (write / output-redirect / git after a
# `cd`) live in lib/read_path_hygiene.py; read its docstring for the full
# breakdown and the unknown/fail-open reasons it prints to stderr.
#
# On match this DENIES with a rule-tagged corrective message -- e.g.
# `guard-read-path-hygiene: [C1] ...` -- so the agent self-corrects on its next
# turn instead of waiting for a human, and a log reader can group denials by
# rule id without the command text ever being stored. The detection logic (and
# its stdout header protocol) lives in lib/read_path_hygiene.py; the event
# writer lives in lib/hook_events.py.
#
# I/O modes mirror guard-dangerous-commands.sh (SEC-7):
#   argv mode  — command as $1 (run-evals, test harness, Codex): GUARD lines on
#     stderr + exit 1 on match.
#   stdin mode — the Claude Code PreToolUse protocol: JSON on stdin
#     (.tool_input.command). On match emit permissionDecision "deny" JSON on
#     stdout and exit 0 — the settings wrapper is `|| true`, so the exit code
#     carries no signal on Claude and the stdout JSON is the enforcement channel.
# Fail-open on missing/unparseable input or a missing python3.
#
# Privacy: every DENY, and every fail-open on syntax this module genuinely
# cannot classify, is logged as one privacy-safe JSON event -- no raw command
# text, no command hash, no raw permission-suggestion text -- to a
# session-scoped file under $XDG_CACHE_HOME/iad/hook-events/<project-slug>/
# (or $IAD_HOOK_EVENTS_FILE, if set); see lib/hook_events.py's docstring for
# the event schema and the directory/file privacy modes (0700/0600). Logging
# is best-effort and silent: it never blocks or fails the guard.

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
_EVENTS="$_HOOK_DIR/lib/hook_events.py"
[ -f "$_DETECTOR" ] || exit 0
_PAYLOAD_JSON="${_payload:-{\}}"      # "{}" in argv mode (tests, Codex)

_event() {   # $1 event name, $2 extra JSON object — never fails, never prints to stdout
  [ -f "$_EVENTS" ] || return 0
  printf '%s' "$_PAYLOAD_JSON" | python3 "$_EVENTS" --hook guard-read-path-hygiene --event "$1" --extra "$2" >/dev/null 2>&1 || true
}

_deny() {   # $1 rule id, $2 header JSON, $3 message
  echo "GUARD: [$1] $3" >&2
  echo "GUARD: command was: $CMD" >&2
  _event hygiene_deny "$2"
  if [ "$INPUT_MODE" = "stdin" ]; then
    _reason="guard-read-path-hygiene: [$1] $3"
    if command -v jq >/dev/null 2>&1; then
      jq -cn --arg r "$_reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    else
      python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":sys.argv[1]}}, separators=(",",":")))' "$_reason"
    fi
    exit 0
  fi
  exit 1
}

_err_file="$(mktemp 2>/dev/null || echo /dev/null)"
_verdict=$(printf '%s' "$CMD" | python3 "$_DETECTOR" 2>"$_err_file") || _verdict=""
if [ -n "$_verdict" ]; then
  _hdr="${_verdict%%$'\n'*}"
  _msg="${_verdict#*$'\n'}"
  _rule="${_hdr#*\"rule\":\"}"; _rule="${_rule%%\"*}"
  _deny "$_rule" "$_hdr" "$_msg"
fi
_fo="$(grep -o 'FAILOPEN reason=[^ ]*' "$_err_file" 2>/dev/null | head -1 | cut -d= -f2)"
[ "$_err_file" != /dev/null ] && rm -f "$_err_file" 2>/dev/null
[ -n "$_fo" ] && _event hygiene_fail_open "{\"reason\":\"$_fo\"}"
exit 0
