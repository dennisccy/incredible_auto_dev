#!/usr/bin/env bash
# Thin wrapper around extract-neutral-source.py — a one-shot migration of the
# existing .claude/ tree into the new neutral source layout. Idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$HERE/extract-neutral-source.py" "$@"
