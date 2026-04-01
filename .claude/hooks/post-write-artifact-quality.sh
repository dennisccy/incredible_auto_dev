#!/usr/bin/env bash
# post-write-artifact-quality.sh — Warn when phase report artifacts are vague or too short
# Triggered as PostToolUse hook on Write/Edit when the file path matches reports/phase-*
# This is advisory — it always exits 0. It only prints warnings.
set -e

FILE_PATH="${1:-}"

# Only check phase report files
if [[ -z "$FILE_PATH" ]]; then exit 0; fi
if [[ ! "$FILE_PATH" =~ reports/phase- ]]; then exit 0; fi
if [[ ! -f "$FILE_PATH" ]]; then exit 0; fi

# Count non-empty, non-header lines
CONTENT_LINES=$(grep -v '^\s*$' "$FILE_PATH" | grep -v '^#' | grep -c '.' 2>/dev/null || echo 0)

# Check for vague placeholder markers
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

exit 0
