#!/usr/bin/env bash
# post-write-artifact-quality.sh — Advisory checks on pipeline report artifacts.
#
# Two independent checks, both advisory (always exit 0; only prints warnings):
#   1. Vague-content / thin-file heuristic (only for reports/phase-*).
#   2. Schema validation via artifact_schemas.py — verdict line + required H2
#      sections (for reports/reviews/, reports/qa/, reports/phase-*, docs/handoffs/).
# Triggered as PostToolUse hook on Write/Edit.
set -e

FILE_PATH="${1:-}"

# Claude Code PostToolUse passes JSON on stdin (.tool_input.file_path);
# $CLAUDE_TOOL_INPUT_FILE_PATH never existed. argv ($1) remains the
# test-harness / Codex path (SEC-7 pattern, mirrors guard-dangerous-commands.sh).
if [[ -z "$FILE_PATH" && ! -t 0 ]]; then
  _payload=$(cat 2>/dev/null || true)
  if [[ -n "$_payload" ]]; then
    if command -v jq >/dev/null 2>&1; then
      FILE_PATH=$(printf '%s' "$_payload" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null) || FILE_PATH=""
    else
      FILE_PATH=$(printf '%s' "$_payload" | python3 -c 'import json,sys; ti=json.load(sys.stdin).get("tool_input",{}); print(ti.get("file_path") or ti.get("path") or "")' 2>/dev/null) || FILE_PATH=""
    fi
  fi
fi

if [[ -z "$FILE_PATH" ]]; then exit 0; fi
if [[ ! -f "$FILE_PATH" ]]; then exit 0; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_VALIDATOR="$SCRIPT_DIR/../../scripts/automation/lib/artifact_schemas.py"

# ── Check 1: vague-content / thin-file (existing behavior; phase-* only) ──
if [[ "$FILE_PATH" =~ reports/phase- ]]; then
  CONTENT_LINES=$(grep -v '^\s*$' "$FILE_PATH" | grep -v '^#' | grep -c '.' 2>/dev/null || echo 0)
  VAGUE_MARKERS=$(grep -icE '^\s*(TBD|TODO|FILL IN|PLACEHOLDER|N\/A$|test the form|verify it works|check the page)' "$FILE_PATH" 2>/dev/null || echo 0)

  WARNINGS=()
  if [[ "$CONTENT_LINES" -lt 5 ]]; then
    WARNINGS+=("File has fewer than 5 lines of content ($CONTENT_LINES lines) — this artifact may be too thin.")
  fi
  if [[ "$VAGUE_MARKERS" -gt 2 ]]; then
    WARNINGS+=("File contains $VAGUE_MARKERS vague placeholder lines (TBD/TODO/etc) — replace with specific content.")
  fi

  if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    echo "[artifact-quality] WARNING: $FILE_PATH" >&2
    for w in "${WARNINGS[@]}"; do
      echo "[artifact-quality]   $w" >&2
    done
  fi
fi

# ── Check 2: schema validation (advisory) ──
# The validator handles its own path matching and exits 0 silently for
# unrecognized paths. Stderr output describes any structural issues.
if command -v python3 >/dev/null 2>&1 && [[ -f "$ARTIFACT_VALIDATOR" ]]; then
  python3 "$ARTIFACT_VALIDATOR" validate "$FILE_PATH" 2>&1 1>/dev/null >&2 || true
fi

exit 0
