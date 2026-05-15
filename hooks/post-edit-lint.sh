#!/usr/bin/env bash
# Post-edit hook: run lightweight syntax validation on edited source files
FILE="$1"

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
