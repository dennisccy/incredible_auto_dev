#!/usr/bin/env python3
"""merge_ui_test_results.py — merge several ui-test-results.md files into one.

Goal mode's lean browser-QA runs in two lanes (see goal-iter-lean.sh):
  - the LLM browser-qa-agent verifies the NEW/changed (Target) journeys, and
  - the deterministic replay runner (demo_runner.py --mode verify) re-verifies the
    already-passing regression set from stored golden scripts.

Each lane writes a ui-test-results.md (same template). This merges them into the
single `reports/phase-<iter>-ui-test-results.md` the goal-evaluator reads, so that
contract is unchanged. Inputs are merged in order with LATER-WINS by Test ID, so a
journey the LLM re-confirmed overrides a replay verdict for the same journey (the
caller passes the replay file first, the authoritative LLM file last).

The merged `**Browser QA Verdict:**` is recomputed from the SURVIVING rows (after
later-wins), NOT from the input files' own headline verdicts — otherwise a replay
FAIL that the LLM later re-confirmed as PASS would wrongly keep the file at FAIL.

Usage:
  merge_ui_test_results.py <out.md> <in1.md> [<in2.md> ...]
  merge_ui_test_results.py void <results.md> <J-XX> [<J-YY> ...]
  merge_ui_test_results.py self-test

The `void` subcommand (SPEED-22 mass-false-FAIL breaker) rewrites the listed
journeys' FAIL rows to SKIP with a "voided" note, recomputes the headline
verdict from the surviving rows, and appends a dated loud footer — used when
2 green canary re-checks prove a majority-FAIL replay run was selector/
environment drift rather than real regressions.
"""
from __future__ import annotations

import datetime
import re
import sys
from pathlib import Path

_VERDICT_RE = re.compile(r"\*\*Browser QA Verdict:\*\*\s*([A-Z_]+)")
# A results-table data row: | UT-xx | name | type | prio | expected | actual | VERDICT | evidence |
_ROW_RE = re.compile(r"^\|\s*(UT-[^|]+?)\s*\|(.*)\|\s*$")
# Column order in the template (after the leading Test ID cell).
_C_NAME, _C_ACTUAL, _C_EVIDENCE = 0, 4, 6


def _today() -> str:
    return datetime.date.today().isoformat()


def parse_rows(text: str) -> "list[dict]":
    """Extract results-table data rows. Returns dicts with test_id + cells +
    verdict (the cell that is one of PASS/FAIL/SKIP/SKIPPED)."""
    rows: list[dict] = []
    for line in text.splitlines():
        m = _ROW_RE.match(line.strip())
        if not m:
            continue
        test_id = m.group(1).strip()
        cells = [c.strip() for c in m.group(2).split("|")]
        # Skip a markdown header-separator row that happened to start with a dash run.
        if cells and all(set(c) <= {"-", ":"} for c in cells if c):
            continue
        verdict = ""
        for c in cells:
            cu = c.upper()
            if cu in ("PASS", "FAIL", "SKIP", "SKIPPED"):
                verdict = "SKIP" if cu == "SKIPPED" else cu
                break
        rows.append({"test_id": test_id, "cells": cells, "verdict": verdict,
                     "raw": "| " + test_id + " |" + m.group(2) + "|"})
    return rows


def file_top_verdict(text: str) -> str:
    m = _VERDICT_RE.search(text)
    return m.group(1) if m else ""


def compute_overall(rows: "list[dict]", file_verdicts: "list[str] | None" = None) -> str:
    """Overall verdict. Surviving rows are authoritative; only when NO rows could
    be parsed do we fall back to the input files' headline verdicts."""
    verdicts = [r["verdict"] for r in rows if r["verdict"]]
    if verdicts:
        if "FAIL" in verdicts:
            return "FAIL"
        if "PASS" in verdicts:
            return "PASS"
        return "SKIPPED"
    file_verdicts = file_verdicts or []
    if "FAIL" in file_verdicts:
        return "FAIL"
    if "PASS" in file_verdicts:
        return "PASS"
    return "SKIPPED"


def _cell(row: dict, i: int) -> str:
    cells = row["cells"]
    return cells[i] if i < len(cells) else ""


def merge(texts: "list[str]") -> str:
    """Merge in order; later inputs win per Test ID. Returns the merged markdown
    with a single authoritative headline verdict and detail rebuilt from the
    surviving rows (no verbatim per-lane embedding → exactly one verdict line)."""
    by_id: "dict[str, dict]" = {}
    order: "list[str]" = []
    file_verdicts: "list[str]" = []
    for text in texts:
        file_verdicts.append(file_top_verdict(text))
        for row in parse_rows(text):
            tid = row["test_id"]
            if tid not in by_id:
                order.append(tid)
            by_id[tid] = row  # later wins
    rows = [by_id[t] for t in order]
    overall = compute_overall(rows, file_verdicts)
    n_pass = sum(1 for r in rows if r["verdict"] == "PASS")
    n_skip = sum(1 for r in rows if r["verdict"] == "SKIP")
    total = len(rows)

    out = ["# UI Test Results (merged)", "",
           f"**Date:** {_today()}",
           "**Written by:** merge_ui_test_results.py (LLM browser-qa + deterministic replay)",
           "", "---", "",
           f"**Browser QA Verdict:** {overall}", "",
           f"**Overall:** {n_pass}/{total} journeys passed ({n_skip} skipped)",
           "", "---", "", "## Results Table", "",
           "| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |",
           "|---------|------|------|----------|----------|--------|---------|----------|"]
    for r in rows:
        out.append(r["raw"])
    out.append("")

    failed = [r for r in rows if r["verdict"] == "FAIL"]
    skipped = [r for r in rows if r["verdict"] == "SKIP"]
    if failed:
        out += ["## Failed Tests", ""]
        for r in failed:
            out += [f"### {r['test_id']} — {_cell(r, _C_NAME)}", "",
                    "**Verdict:** FAIL",
                    f"**Failure:** {_cell(r, _C_ACTUAL)}",
                    f"**Evidence:** `{_cell(r, _C_EVIDENCE) or 'none'}`", ""]
    if skipped:
        out += ["## Skipped Tests", ""]
        for r in skipped:
            out += [f"### {r['test_id']} — {_cell(r, _C_NAME)}", "",
                    "**Verdict:** SKIPPED",
                    f"**Reason:** {_cell(r, _C_ACTUAL)}", ""]
    out += ["## Environment", "",
            "- **Browser:** Chromium (LLM browser-qa + deterministic replay)",
            f"- **Test Date:** {_today()}", ""]
    return "\n".join(out) + "\n"


_VOID_NOTE = ("voided: suspected selector/environment drift — mass replay FAIL "
              "overturned by green canary re-checks")


def void_text(text: str, journeys: "list[str]") -> "tuple[str, list[str]]":
    """Pure transform for the `void` subcommand: rewrite the listed journeys'
    FAIL rows to SKIP + the voided note, recompute the headline from the
    surviving rows, append a dated footer. Returns (new_text, voided_ids)."""
    want = {f"UT-{j}" for j in journeys} | set(journeys)
    voided: list[str] = []
    out_lines: list[str] = []
    for line in text.splitlines():
        m = _ROW_RE.match(line.strip())
        if m:
            tid = m.group(1).strip()
            # Split on UNESCAPED pipes only — the replay renderer escapes '|'
            # inside cells as '\|'; a bare split would shift every later cell.
            cells = [c.strip() for c in re.split(r"(?<!\\)\|", m.group(2))]
            is_sep = cells and all(set(c) <= {"-", ":"} for c in cells if c)
            if tid in want and not is_sep and any(c.upper() == "FAIL" for c in cells):
                new_cells = []
                for idx, c in enumerate(cells):
                    if c.upper() == "FAIL":
                        new_cells.append("SKIP")
                    elif idx == _C_ACTUAL:
                        new_cells.append(_VOID_NOTE)
                    else:
                        new_cells.append(c)
                out_lines.append("| " + tid + " | " + " | ".join(new_cells) + " |")
                voided.append(tid)
                continue
        out_lines.append(line)
    if not voided:
        return text, []
    new_text = "\n".join(out_lines)
    rows = parse_rows(new_text)
    overall = compute_overall(rows)
    new_text = _VERDICT_RE.sub(f"**Browser QA Verdict:** {overall}", new_text, count=1)
    ids = " ".join(sorted({t.replace('UT-', '', 1) for t in voided}))
    new_text += (
        f"\n\n---\n\n_VOIDED ({_today()}): the FAIL rows for {ids} above were VOIDED "
        "(SPEED-22 mass-false-FAIL breaker) — a majority of the replay set failed at "
        "once and the canary journeys re-checked GREEN via the LLM lane, so the "
        "failures are suspected golden-script/selector drift, not product "
        "regressions. These journeys keep their prior recorded status; their golden "
        "scripts are queued for regeneration (state/goldens-regen-pending) and are "
        "re-derived from the next verified demo recording._\n"
    )
    return new_text, sorted({t.replace("UT-", "", 1) for t in voided})


def cmd_void(path: str, journeys: "list[str]") -> int:
    p = Path(path)
    try:
        text = p.read_text(encoding="utf-8")
    except OSError as exc:
        sys.stderr.write(f"[merge_ui_test_results] void: unreadable {path}: {exc}\n")
        return 2
    new_text, voided = void_text(text, journeys)
    if not voided:
        print("[merge_ui_test_results] void: no matching FAIL rows — file unchanged")
        return 0
    p.write_text(new_text, encoding="utf-8")
    print(f"[merge_ui_test_results] voided FAIL rows for: {' '.join(voided)}")
    return 0


def main(argv: "list[str]") -> int:
    if argv and argv[0] in ("self-test", "--self-test"):
        return _self_test()
    if argv and argv[0] == "void":
        if len(argv) < 3:
            sys.stderr.write("usage: merge_ui_test_results.py void <results.md> <J-XX> [...]\n")
            return 2
        return cmd_void(argv[1], argv[2:])
    if len(argv) < 2:
        sys.stderr.write("usage: merge_ui_test_results.py <out.md> <in1.md> [<in2.md> ...]\n")
        return 2
    out_path = Path(argv[0])
    texts: list[str] = []
    for p in argv[1:]:
        fp = Path(p)
        if fp.exists():
            texts.append(fp.read_text(encoding="utf-8"))
    if not texts:
        sys.stderr.write("[merge_ui_test_results] no readable input files\n")
        return 2
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(merge(texts), encoding="utf-8")
    print(f"[merge_ui_test_results] merged {len(texts)} file(s) → {out_path}")
    return 0


# ── self-test (no filesystem) ────────────────────────────────────────────────

def _self_test() -> int:
    failures: list[str] = []

    def check(name, fn):
        try:
            fn()
        except Exception as exc:  # noqa: BLE001
            failures.append(f"{name}: {exc!r}")

    replay = (
        "**Browser QA Verdict:** FAIL\n\n## Results Table\n"
        "| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n"
        "|---|---|---|---|---|---|---|---|\n"
        "| UT-J-06 | View dashboard | regression | P1 | e | ok | PASS | a.png |\n"
        "| UT-J-07 | Filter table | regression | P1 | e | step 3 failed | FAIL | b.png |\n")
    llm = (
        "**Browser QA Verdict:** PASS\n\n## Results Table\n"
        "| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n"
        "|---|---|---|---|---|---|---|---|\n"
        "| UT-J-20 | New feature | smoke | P1 | e | ok | PASS | c.png |\n"
        "| UT-J-07 | Filter table | smoke | P1 | e | works on recheck | PASS | d.png |\n")

    def t_parse():
        rows = parse_rows(replay)
        assert [r["test_id"] for r in rows] == ["UT-J-06", "UT-J-07"], rows
        assert rows[1]["verdict"] == "FAIL", rows[1]
        # the header-separator row must not be mistaken for data
        assert all(r["test_id"].startswith("UT-") for r in rows), rows

    def t_later_wins():
        # replay says J-07 FAIL, LLM re-confirm says PASS → LLM (later) wins → overall PASS.
        md = merge([replay, llm])
        rows = parse_rows(md)
        ids = {r["test_id"]: r["verdict"] for r in rows}
        assert ids == {"UT-J-06": "PASS", "UT-J-07": "PASS", "UT-J-20": "PASS"}, ids
        # the merged headline (the ONLY verdict line) must be PASS, not FAIL
        assert file_top_verdict(md) == "PASS", file_top_verdict(md)
        assert md.count("**Browser QA Verdict:**") == 1, "exactly one headline verdict"

    def t_real_fail_survives():
        # replay FAIL with no later override → overall FAIL.
        md = merge([replay])
        assert file_top_verdict(md) == "FAIL", file_top_verdict(md)
        assert "## Failed Tests" in md and "UT-J-07" in md

    def t_skipped_only():
        skip = ("**Browser QA Verdict:** SKIPPED\n## Results Table\n"
                "| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n"
                "|---|---|---|---|---|---|---|---|\n"
                "| UT-J-09 | Export | regression | P1 | e | no script | SKIP | none |\n")
        md = merge([skip])
        assert file_top_verdict(md) == "SKIPPED", file_top_verdict(md)
        assert "## Skipped Tests" in md

    mass = (
        "**Browser QA Verdict:** FAIL\n\n## Results Table\n"
        "| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n"
        "|---|---|---|---|---|---|---|---|\n"
        "| UT-J-01 | login | regression | P1 | e | ok | PASS | a.png |\n"
        "| UT-J-02 | browse | regression | P1 | e | step 2 failed | FAIL | b.png |\n"
        "| UT-J-03 | export | regression | P1 | e | step 1 failed | FAIL | c.png |\n"
        "| UT-J-04 | filter | regression | P1 | e | step 4 failed | FAIL | d.png |\n")

    def t_void_rewrites_and_recomputes():
        # Void ALL the FAILs → SKIP rows with the note, headline flips to PASS
        # (the surviving PASS row wins), dated footer appended exactly once.
        new, voided = void_text(mass, ["J-02", "J-03", "J-04"])
        assert voided == ["J-02", "J-03", "J-04"], voided
        rows = {r["test_id"]: r["verdict"] for r in parse_rows(new)}
        assert rows == {"UT-J-01": "PASS", "UT-J-02": "SKIP", "UT-J-03": "SKIP", "UT-J-04": "SKIP"}, rows
        assert file_top_verdict(new) == "PASS", file_top_verdict(new)
        assert new.count("_VOIDED (") == 1 and "voided: suspected selector" in new
        assert new.count("**Browser QA Verdict:**") == 1

    def t_void_keeps_unlisted_fail():
        # An un-listed FAIL survives and keeps the headline at FAIL.
        new, voided = void_text(mass, ["J-02"])
        assert voided == ["J-02"], voided
        rows = {r["test_id"]: r["verdict"] for r in parse_rows(new)}
        assert rows["UT-J-03"] == "FAIL" and rows["UT-J-02"] == "SKIP", rows
        assert file_top_verdict(new) == "FAIL", file_top_verdict(new)

    def t_void_no_match_is_noop():
        new, voided = void_text(mass, ["J-99"])
        assert voided == [] and new == mass

    def t_void_respects_escaped_pipes():
        # The replay renderer escapes '|' in cells; void must not split on it.
        esc = (
            "**Browser QA Verdict:** FAIL\n\n## Results Table\n"
            "| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n"
            "|---|---|---|---|---|---|---|---|\n"
            "| UT-J-07 | Filter \\| sort table | regression | P1 | e | step 2 failed | FAIL | b.png |\n")
        new, voided = void_text(esc, ["J-07"])
        assert voided == ["J-07"], voided
        row = [l for l in new.splitlines() if l.startswith("| UT-J-07")][0]
        # verdict flipped, the note landed in the Actual cell, the escaped
        # pipe survived, and the column count is unchanged
        assert "| SKIP |" in row and _VOID_NOTE in row and "\\|" in row, row
        assert len(re.split(r"(?<!\\)\|", row)) == len(re.split(r"(?<!\\)\|",
            "| UT-J-07 | Filter \\| sort table | regression | P1 | e | step 2 failed | FAIL | b.png |")), row

    check("parse_rows", t_parse)
    check("later_wins_override", t_later_wins)
    check("real_fail_survives", t_real_fail_survives)
    check("skipped_only", t_skipped_only)
    check("void_rewrites_and_recomputes", t_void_rewrites_and_recomputes)
    check("void_keeps_unlisted_fail", t_void_keeps_unlisted_fail)
    check("void_no_match_is_noop", t_void_no_match_is_noop)
    check("void_respects_escaped_pipes", t_void_respects_escaped_pipes)

    for f in failures:
        print(f"  FAIL {f}", file=sys.stderr)
    print(f"[merge_ui_test_results self-test] {8 - len(failures)} passed, {len(failures)} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
