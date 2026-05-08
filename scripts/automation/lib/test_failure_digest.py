#!/usr/bin/env python3
"""
test_failure_digest.py — distill raw test runner output into a structured
markdown digest that a coding agent can act on without grepping the full log.

Usage:
    python3 test_failure_digest.py <log-path> [--scope <directory>] [--max-tests <N>]

Detects pytest / jest / vitest / mocha by signature. Output is markdown to
stdout. Always exits 0 — if parsing fails, emits a 'could not parse' digest
so the caller can still proceed.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


def detect_runner(log: str) -> str:
    if re.search(r"^=+ FAILURES =+$", log, re.MULTILINE):
        return "pytest"
    if re.search(r"^=+ short test summary info =+$", log, re.MULTILINE):
        return "pytest"
    if re.search(r"^Tests:\s+\d+", log, re.MULTILINE) and "Suites:" in log:
        return "jest"
    if "vitest" in log.lower() and re.search(r"FAIL\s+\S+", log):
        return "vitest"
    if re.search(r"\d+ passing", log) and re.search(r"\d+ failing", log):
        return "mocha"
    return "unknown"


def parse_pytest_summary(log: str) -> dict:
    m = re.search(r"=+\s*(\d+) failed[,\s]+(\d+) passed", log)
    if m:
        return {"failed": int(m.group(1)), "passed": int(m.group(2))}
    m = re.search(r"=+\s*(\d+) passed", log)
    if m:
        return {"failed": 0, "passed": int(m.group(1))}
    m = re.search(r"=+\s*(\d+) failed", log)
    if m:
        return {"failed": int(m.group(1)), "passed": 0}
    return {}


def all_pytest_failures(log: str, max_tests: int = 5) -> list[dict]:
    m = re.search(
        r"=+ FAILURES =+\n(.+?)(?=\n=+ (?:warnings summary|short test summary|passed|ERRORS) =+|\Z)",
        log,
        re.DOTALL,
    )
    if not m:
        return []
    block = m.group(1)
    parts = re.split(r"\n_+\s+(\S+)\s+_+\n", "\n" + block)
    failures: list[dict] = []
    for i in range(1, len(parts), 2):
        if len(failures) >= max_tests:
            break
        name = parts[i]
        body = parts[i + 1] if i + 1 < len(parts) else ""
        file_line_m = re.search(r"^([^:\n]+\.py):(\d+):", body, re.MULTILINE)
        err_lines = re.findall(r"^E\s+(.*)$", body, re.MULTILINE)
        err_text = "\n".join(err_lines[:6]) if err_lines else body.split("\n")[0]
        failures.append({
            "test": name,
            "file": file_line_m.group(1) if file_line_m else None,
            "line": int(file_line_m.group(2)) if file_line_m else None,
            "error": err_text.strip(),
            "traceback": "\n".join(body.strip().split("\n")[:20]),
        })
    return failures


def parse_jest_summary(log: str) -> dict:
    m = re.search(r"Tests:\s+(\d+) failed,\s+(\d+) passed", log)
    if m:
        return {"failed": int(m.group(1)), "passed": int(m.group(2))}
    m = re.search(r"Tests:\s+(\d+) passed", log)
    if m:
        return {"failed": 0, "passed": int(m.group(1))}
    return {}


def all_jest_failures(log: str, max_tests: int = 5) -> list[dict]:
    failures: list[dict] = []
    for m in re.finditer(r"●\s+(.+?)\n\n(.+?)(?=\n●\s+|\Z)", log, re.DOTALL):
        if len(failures) >= max_tests:
            break
        name = m.group(1).strip()
        body = m.group(2)
        file_line_m = re.search(r"at\s+[^(]*\(([^:)]+):(\d+):\d+\)", body) \
                      or re.search(r"^\s+at\s+([^:\s]+):(\d+):\d+", body, re.MULTILINE)
        failures.append({
            "test": name,
            "file": file_line_m.group(1) if file_line_m else None,
            "line": int(file_line_m.group(2)) if file_line_m else None,
            "error": body.split("\n")[0].strip(),
            "traceback": body[:800],
        })
    return failures


def recently_modified(scope: Path) -> list[str]:
    """Files touched in the working tree (uncommitted) + last commit."""
    files: list[str] = []
    try:
        out = subprocess.run(
            ["git", "diff", "--name-only", "HEAD"],
            cwd=scope, capture_output=True, text=True, timeout=10,
        )
        files += [f for f in out.stdout.splitlines() if f.strip()]
    except Exception:
        pass
    try:
        out = subprocess.run(
            ["git", "diff", "--name-only", "HEAD~1..HEAD"],
            cwd=scope, capture_output=True, text=True, timeout=10,
        )
        files += [f for f in out.stdout.splitlines() if f.strip()]
    except Exception:
        pass
    seen, ordered = set(), []
    for f in files:
        if f not in seen:
            seen.add(f)
            ordered.append(f)
    return ordered[:10]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("log_path", help="Path to raw test runner output log")
    ap.add_argument("--scope", default=".", help="Repo root for git lookups")
    ap.add_argument("--max-tests", type=int, default=5)
    args = ap.parse_args()

    log_path = Path(args.log_path)
    if not log_path.exists():
        print(f"# Test Failure Digest\n\nLog file not found: `{args.log_path}`")
        return 0

    log = log_path.read_text(errors="ignore")
    if not log.strip():
        print(f"# Test Failure Digest\n\nLog file is empty: `{args.log_path}`")
        return 0

    runner = detect_runner(log)
    if runner == "pytest":
        summary = parse_pytest_summary(log)
        failures = all_pytest_failures(log, args.max_tests)
    elif runner in ("jest", "vitest"):
        summary = parse_jest_summary(log)
        failures = all_jest_failures(log, args.max_tests)
    else:
        summary, failures = {}, []

    out = ["# Test Failure Digest", ""]
    out.append(f"**Runner detected:** `{runner}`")
    if summary:
        out.append(
            f"**Summary:** {summary.get('passed', '?')} passed, "
            f"{summary.get('failed', '?')} failed"
        )
    out.append(f"**Source log:** `{log_path}`")
    out.append("")

    if not failures:
        out.append("## Failures")
        out.append("")
        out.append(
            "Could not parse structured failures from the log. "
            "Inspect the raw log directly."
        )
        out.append("")
    else:
        out.append(f"## Failing Tests ({len(failures)} shown)")
        out.append("")
        for i, f in enumerate(failures, 1):
            out.append(f"### {i}. `{f['test']}`")
            if f.get("file"):
                line = f":{f['line']}" if f.get("line") else ""
                out.append(f"- **Location:** `{f['file']}{line}`")
            out.append("")
            out.append("**Error:**")
            out.append("```")
            out.append(f.get("error") or "(no error message captured)")
            out.append("```")
            out.append("")
            out.append("<details><summary>Traceback excerpt</summary>")
            out.append("")
            out.append("```")
            out.append(f.get("traceback") or "(no traceback captured)")
            out.append("```")
            out.append("")
            out.append("</details>")
            out.append("")

    files = recently_modified(Path(args.scope))
    if files:
        out.append("## Recently modified files (likely in scope)")
        out.append("")
        for f in files:
            out.append(f"- `{f}`")
        out.append("")

    out.append("## Suggested next reads (for the dev agent)")
    out.append("")
    refs: list[str] = []
    for f in failures[:3]:
        if f.get("file"):
            line = f":{f['line']}" if f.get("line") else ""
            refs.append(f"`{f['file']}{line}` — failing test")
    for src in files[:3]:
        if not any(src in r for r in refs):
            refs.append(f"`{src}` — recently modified")
    if not refs:
        refs.append("Manually inspect the log; auto-parsing failed.")
    for i, r in enumerate(refs, 1):
        out.append(f"{i}. {r}")
    out.append("")

    sys.stdout.write("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
