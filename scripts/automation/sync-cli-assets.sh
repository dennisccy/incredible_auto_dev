#!/usr/bin/env bash
# Materialize per-CLI asset trees (.claude/ and/or .codex/) from the neutral
# canonical source under agents/, skills/, hooks/, policy/, config/.
# Idempotent. Safe to run at the top of every run-phase / run-goal invocation.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$HERE/sync-cli-assets.py" "$@"
