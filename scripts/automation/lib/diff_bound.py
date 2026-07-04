"""
diff_bound.py — bound a unified diff for model consumption (stdlib only).

The goal-evaluator/coherence-auditor used to ingest raw `git diff` output —
megabytes on data-heavy iterations (seed CSVs, lockfiles), degrading exactly
the judgment the loop depends on. This filter produces `iter-diff.md`: the
COMPLETE file list is always preserved; excluded/oversized content is
summarized with an honest header (no silent caps); agents Read the real file
when detail matters. The secret scanner (scan_diff.py) runs on the FULL diff
separately — bounding never applies to gate-critical inputs.

CLI:
    git diff <sha> | python3 diff_bound.py [--max-file-lines N] [--max-total-lines N]
                                           [--exclude g1 --exclude g2 ...]
    python3 diff_bound.py self-test

Default excludes (fnmatch, against the b/ path): data dirs, seed dirs,
lockfiles, minified assets, source maps, images/binaries. Extend with
--exclude or the CHAIN_DIFF_EXCLUDES env var (space-separated globs).
"""
from __future__ import annotations

import fnmatch
import os
import sys

DEFAULT_EXCLUDES = [
    "apps/*/data/*", "data/*", "*/seed*/*", "*seed-*/*",
    "*.lock", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "poetry.lock",
    "*.min.js", "*.min.css", "*.map",
    "*.png", "*.jpg", "*.jpeg", "*.gif", "*.svg", "*.ico", "*.pdf",
    "*.woff", "*.woff2", "*.ttf",
    # Harness artifact churn: push-per-iter makes runs/** tracked in consumer
    # repos, so telemetry/report/handoff writes otherwise inflate every bounded
    # diff the judges read. Excluded files stay NAMED in the header.
    "runs/*", "reports/*", "docs/handoffs/*",
]

DEFAULT_MAX_FILE_LINES = 400
DEFAULT_MAX_TOTAL_LINES = 4000


def _matches(path: str, globs: list[str]) -> bool:
    return any(
        fnmatch.fnmatch(path, g) or fnmatch.fnmatch("/" + path, g) or
        fnmatch.fnmatch(path, g.rstrip("/") + "/*")
        for g in globs
    )


def _split_file_sections(diff_text: str) -> list[tuple[str, list[str]]]:
    """Split a unified diff into (path, lines) per file section."""
    sections: list[tuple[str, list[str]]] = []
    current_path = ""
    current: list[str] = []
    for line in diff_text.splitlines():
        if line.startswith("diff --git "):
            if current:
                sections.append((current_path, current))
            current = [line]
            # `diff --git a/x b/x` — take the b/ path.
            parts = line.split(" b/", 1)
            current_path = parts[1] if len(parts) == 2 else line
        else:
            if not current:
                current = []
            current.append(line)
            if line.startswith("+++ b/") and not current_path:
                current_path = line[6:].strip()
    if current:
        sections.append((current_path, current))
    return sections


def bound(diff_text: str, excludes: list[str], max_file_lines: int, max_total_lines: int) -> str:
    sections = _split_file_sections(diff_text)
    if not sections:
        return "# Iteration diff (bounded)\n\n(no changes)\n"

    excluded: list[tuple[str, int]] = []
    truncated: list[tuple[str, int]] = []
    body: list[str] = []
    total = 0

    for path, lines in sections:
        if _matches(path, excludes):
            excluded.append((path, len(lines)))
            continue
        if total >= max_total_lines:
            truncated.append((path, len(lines)))
            continue
        if len(lines) > max_file_lines:
            kept = lines[:max_file_lines]
            body.extend(kept)
            omitted = len(lines) - max_file_lines
            body.append(f"... [diff_bound] {path}: {omitted} more diff lines omitted — Read the file for full detail")
            total += max_file_lines + 1
            truncated.append((path, omitted))
        else:
            body.extend(lines)
            total += len(lines)

    header = ["# Iteration diff (bounded)", ""]
    header.append(f"Files changed: {len(sections)}. Shown in full: "
                  f"{len(sections) - len(excluded) - len(truncated)}.")
    if excluded:
        header.append("")
        header.append("**Excluded paths** (data/lock/binary — content not shown; the secret scanner")
        header.append("still scanned them; Read a file directly if it matters):")
        for p, n in excluded:
            header.append(f"- `{p}` ({n} diff lines)")
    if truncated:
        header.append("")
        header.append("**Truncated** (over the line caps; tail omitted, noted inline or fully skipped):")
        for p, n in truncated:
            header.append(f"- `{p}` ({n} lines not shown)")
    header.append("")
    header.append("```diff")
    return "\n".join(header) + "\n" + "\n".join(body) + "\n```\n"


def _self_test() -> int:
    def fake_section(path: str, n: int) -> str:
        lines = [f"diff --git a/{path} b/{path}", f"--- a/{path}", f"+++ b/{path}", "@@ -1 +1 @@"]
        lines += [f"+line {i}" for i in range(n)]
        return "\n".join(lines)

    diff = "\n".join([
        fake_section("app/main.py", 10),
        fake_section("package-lock.json", 500),
        fake_section("apps/backend/data/seed-stooq-30y/prices/AAPL.csv", 2000),
        fake_section("app/big_module.py", 600),
    ])
    out = bound(diff, DEFAULT_EXCLUDES, 400, 4000)
    assert "line 5" in out, "normal file content must be shown"
    assert "package-lock.json` (" in out, "lockfile must be excluded with a count"
    assert out.count("+line") < 1200, "excluded/truncated content must not leak wholesale"
    assert "AAPL.csv" in out, "excluded path must still be NAMED (no silent caps)"
    assert "more diff lines omitted" in out, "oversized file must note its truncation inline"
    assert "Files changed: 4" in out

    assert "(no changes)" in bound("", DEFAULT_EXCLUDES, 400, 4000)

    # Total cap: later files get skipped but still listed.
    small = "\n".join(fake_section(f"m{i}.py", 50) for i in range(10))
    out2 = bound(small, [], 400, 100)
    assert "lines not shown" in out2

    print("self-test passed")
    return 0


def main(argv: list[str]) -> int:
    if argv and argv[0] == "self-test":
        return _self_test()
    excludes = list(DEFAULT_EXCLUDES)
    env_extra = os.environ.get("CHAIN_DIFF_EXCLUDES", "")
    excludes.extend(g for g in env_extra.split() if g)
    max_file_lines = DEFAULT_MAX_FILE_LINES
    max_total_lines = DEFAULT_MAX_TOTAL_LINES
    i = 0
    while i < len(argv):
        if argv[i] == "--exclude" and i + 1 < len(argv):
            excludes.append(argv[i + 1]); i += 2
        elif argv[i] == "--max-file-lines" and i + 1 < len(argv):
            max_file_lines = int(argv[i + 1]); i += 2
        elif argv[i] == "--max-total-lines" and i + 1 < len(argv):
            max_total_lines = int(argv[i + 1]); i += 2
        else:
            i += 1
    sys.stdout.write(bound(sys.stdin.read(), excludes, max_file_lines, max_total_lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
