#!/usr/bin/env bash
# Post-edit hook: run lightweight syntax validation on edited source files
#
# Two input modes (SEC-7 pattern, mirrors guard-dangerous-commands.sh):
#   argv mode  — file path as $1 (run-evals, test harness, Codex).
#   stdin mode — the Claude Code PostToolUse protocol: JSON on stdin
#     (.tool_input.file_path; $CLAUDE_TOOL_INPUT_FILE_PATH never existed).
# Advisory only: warnings to stderr, always exit 0.
FILE="${1:-}"
if [[ -z "$FILE" && ! -t 0 ]]; then
  _payload=$(cat 2>/dev/null || true)
  if [[ -n "$_payload" ]]; then
    if command -v jq >/dev/null 2>&1; then
      FILE=$(printf '%s' "$_payload" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null) || FILE=""
    else
      FILE=$(printf '%s' "$_payload" | python3 -c 'import json,sys; ti=json.load(sys.stdin).get("tool_input",{}); print(ti.get("file_path") or ti.get("path") or "")' 2>/dev/null) || FILE=""
    fi
  fi
fi
[[ -z "$FILE" ]] && exit 0

if [[ "$FILE" == *.py ]]; then
  if command -v python3 &>/dev/null; then
    python3 -m py_compile "$FILE" 2>&1 && echo "syntax ok: $FILE" || echo "syntax error in $FILE" >&2
  fi
fi

# TypeScript/TSX syntax check (if tsc is available)
if [[ "$FILE" == *.ts || "$FILE" == *.tsx ]]; then
  if command -v tsc &>/dev/null; then
    # Only do a quick parse check, not a full compile
    tsc --noEmit --skipLibCheck "$FILE" 2>&1 | head -5 || true
  fi
fi

exit 0
