"""
Generate per-CLI asset trees (.claude/ and/or .codex/) from the neutral
canonical source. Idempotent; safe to run before every phase/goal invocation.

Usage:
  sync-cli-assets.py [--cli claude|codex|both] [--dry-run] [--check] [--resync]

  --cli       Which CLI to sync. Default: both.
  --dry-run   Print what would change, write nothing.
  --check     Exit non-zero if generated tree differs from current on-disk state.
              (Used in CI to catch hand-edits to generated files.)
  --resync    Force regeneration even if files appear current.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

_HERE = Path(__file__).resolve()
# Repo root is two levels up from scripts/automation/
sys.path.insert(0, str(_HERE.parents[2]))

from adapters.claude import sync as claude_sync  # noqa: E402
from adapters.codex import sync as codex_sync  # noqa: E402


def _parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--cli", choices=["claude", "codex", "both"], default="both")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--check", action="store_true")
    p.add_argument("--resync", action="store_true", help="force write even if up-to-date (no-op today; sync is already idempotent)")
    return p.parse_args(argv)


def main(argv: list[str]) -> int:
    args = _parse_args(argv)
    dry = args.dry_run or args.check

    total_changes = 0
    if args.cli in ("claude", "both"):
        counts = claude_sync.sync_all(dry_run=dry)
        for k, v in counts.items():
            label = "would change" if dry else "wrote"
            print(f"  claude/{k}: {label} {v}")
            total_changes += v
    if args.cli in ("codex", "both"):
        counts = codex_sync.sync_all(dry_run=dry)
        for k, v in counts.items():
            label = "would change" if dry else "wrote"
            print(f"  codex/{k}: {label} {v}")
            total_changes += v

    if args.check:
        if total_changes:
            print(f"DRIFT: {total_changes} file(s) would change. Re-run without --check to update.", file=sys.stderr)
            return 1
        print("OK: generated tree matches neutral source.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
