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
      [--required-primary J-04,J-13] [--primary-lane <path>] [--primary-lane-floor]
  merge_ui_test_results.py classify <raw-primary.md> <J-XX> [<J-YY> ...]
  merge_ui_test_results.py void <results.md> <J-XX> [<J-YY> ...]
  merge_ui_test_results.py self-test

The `void` subcommand (SPEED-22 mass-false-FAIL breaker) rewrites the listed
journeys' FAIL rows to SKIP with a "voided" note, recomputes the headline
verdict from the surviving rows, and appends a dated loud footer — used when
2 green canary re-checks prove a majority-FAIL replay run was selector/
environment drift rather than real regressions.

Fresh-evidence coverage contract (goal mode, REL-14 target-aware). The generic
merger above is provenance-blind: any surviving PASS row makes the headline
PASS, so a deterministic-replay PASS for a stable journey could launder an
iteration whose PRIMARY browser dispatch never verified its targets (Chrome did
not start; every target row SKIP) into `Browser QA Verdict: PASS`. When the
caller declares what the primary dispatch OWED fresh evidence for, the headline
is additionally gated (existing vocabulary only — PASS | FAIL | SKIPPED):
  - any surviving FAIL row                                   → FAIL (unchanged)
  - every --required-primary journey has a fresh PRIMARY-lane row (mapped by
    UT-J-NN test id or a J-NN token in the id/Name cell) and every such row is
    PASS; no primary-lane row is a browser-infra SKIP; with the optional
    --primary-lane-floor guard the primary lane also carries at least one PASS
    row (a lane-level sanity check only — it never proves a journey; both goal
    depths pass their targets in --required-primary: lean rows are UT-J-NN by
    prompt contract, full depth requires one UT-J-NN attribution row per target
    beside its generic UT-XX test-plan rows)                  → PASS
  - otherwise (a required journey is SKIP/MISSING/FAIL-free-but-unverified) → SKIPPED
A replay PASS row never satisfies a fresh-primary obligation; replay-lane rows
(voids, unscripted SKIPs, DEFERRED-BUDGET) never block it. The primary lane is
the LAST input unless --primary-lane names it (an absent primary file = every
required journey MISSING). Without the flags the merger is byte-identical to
before.

The `classify` subcommand is the per-journey classifier behind that contract
and behind the REL-14 post-scan browser-infra token: for each expected journey
it prints `<J-NN>\t<PASS|FAIL|SKIP_INFRA|SKIP_OTHER|MISSING>\t<detail>`. Only
the explicit browser-infra taxonomy (demo_runner's "browser infrastructure
failure", a "Chrome [MCP] did not become ready" error) in the journey's own row
cells or its `### UT-...` detail section qualifies as SKIP_INFRA; a different
journey's PASS/FAIL never affects it; MISSING and SKIP_OTHER are never infra —
with ONE evidence-backed exception: a lane that produced rows but NO PASS/FAIL
row anywhere and carries the taxonomy (Chrome never started for the whole
dispatch) attributes its missing/plain-SKIP required journeys to infra, which is
the pre-existing all-SKIP rule applied to the RAW primary artifact instead of
the merged one. Unreadable input classifies everything MISSING (fails closed:
no PASS, no token). No model is involved anywhere here.
"""
from __future__ import annotations

import datetime
import re
import sys
from pathlib import Path

# Headline verdict. Tolerates markdown emphasis around the token (`**FAIL**`,
# `` `SKIPPED` ``) — anti-pattern 28: agent formatting drift must never read as
# "no verdict".
_VERDICT_RE = re.compile(r"\*\*Browser QA Verdict:\*\*\s*[*_`~\s]*([A-Z_]+)")
# A results-table data row: | UT-xx | name | type | prio | expected | actual | VERDICT | evidence |
_ROW_RE = re.compile(r"^\|\s*(UT-[^|]+?)\s*\|(.*)\|\s*$")
# Cells split on UNESCAPED pipes only — the replay renderer escapes '|' inside
# cells as '\|'; a bare split would shift every later cell.
_CELL_SPLIT_RE = re.compile(r"(?<!\\)\|")
# Column order in the template (after the leading Test ID cell).
_C_NAME, _C_ACTUAL, _C_VERDICT, _C_EVIDENCE = 0, 4, 5, 6
# A verdict CELL (anti-pattern 28): the token may be wrapped in markdown
# emphasis/backticks and may carry an annotation — `**FAIL**`, `` `SKIPPED` ``,
# `PASS (with caveat)`, `FAIL — step 3`, `SKIP: no frontend`. What follows the
# token must be the end of the cell, whitespace, or an annotation opener; a
# word character, '/', '.' or '_' means it is a different word (`PASSED`, the
# template placeholder `PASS/FAIL`, a filename `PASS.png`). Bare-word prose
# that merely CONTAINS a verdict word never matches (the token must lead).
_CELL_VERDICT_RE = re.compile(
    r"^[\s*_`~]*(PASS|FAIL|SKIPPED|SKIP)[*_`~]*(?:$|[\s(\[:;,\u2014\u2013-])",
    re.IGNORECASE)


def _today() -> str:
    return datetime.date.today().isoformat()


def cell_verdict(cell: str) -> str:
    """The verdict a single cell carries: PASS, FAIL, SKIP (SKIPPED folds into
    SKIP) or "" when the cell is not a verdict cell. See _CELL_VERDICT_RE."""
    m = _CELL_VERDICT_RE.match(cell)
    if not m:
        return ""
    v = m.group(1).upper()
    return "SKIP" if v == "SKIPPED" else v


def row_verdict(cells: "list[str]") -> str:
    """The row's verdict. The template's Verdict column wins when it parses;
    otherwise the cells are scanned in REVERSE order, because in every template
    shape the verdict sits to the RIGHT of the free-prose Expected/Actual cells
    (anti-pattern 28: the verdict column must outrank prose that happens to
    start with a verdict word). "" when no cell parses as a verdict — an
    unparseable row is UNKNOWN, never an implicit PASS."""
    if len(cells) > _C_VERDICT:
        v = cell_verdict(cells[_C_VERDICT])
        if v:
            return v
    for c in reversed(cells):
        v = cell_verdict(c)
        if v:
            return v
    return ""


def parse_rows(text: str) -> "list[dict]":
    """Extract results-table data rows. Returns dicts with test_id + cells +
    verdict (PASS/FAIL/SKIP, or "" when no cell parses as a verdict)."""
    rows: list[dict] = []
    for line in text.splitlines():
        m = _ROW_RE.match(line.strip())
        if not m:
            continue
        test_id = m.group(1).strip()
        cells = [c.strip() for c in _CELL_SPLIT_RE.split(m.group(2))]
        # Skip a markdown header-separator row that happened to start with a dash run.
        if cells and all(set(c) <= {"-", ":"} for c in cells if c):
            continue
        rows.append({"test_id": test_id, "cells": cells, "verdict": row_verdict(cells),
                     "raw": "| " + test_id + " |" + m.group(2) + "|"})
    return rows


def file_top_verdict(text: str) -> str:
    m = _VERDICT_RE.search(text)
    return m.group(1) if m else ""


# ── REL-14 target-aware primary classification ─────────────────────────────
# The browser-infra taxonomy REL-14 recognizes (same strings the shell post-scan
# grepped before this classifier existed; deliberately narrow — "frontend not
# running" is the REL-12 legitimate SKIP, never infra).
_INFRA_TAXONOMY_RE = re.compile(
    r"(browser infrastructure failure|chrome (?:mcp )?did not become ready)[^|\n]*",
    re.IGNORECASE)
_JOURNEY_ID_RE = re.compile(r"^(?:UT-)?(J-\d+)$", re.IGNORECASE)
_JOURNEY_TOKEN_RE = re.compile(r"\bJ-\d+\b")
_SECTION_HEAD_RE = re.compile(r"^###\s+(UT-\S+)", re.IGNORECASE)

CLASS_PASS, CLASS_FAIL, CLASS_SKIP_INFRA, CLASS_SKIP_OTHER, CLASS_MISSING = (
    "PASS", "FAIL", "SKIP_INFRA", "SKIP_OTHER", "MISSING")


def row_journeys(row: dict) -> "set[str]":
    """Journeys a row maps to: a `UT-J-NN` / `J-NN` test id is the journey;
    otherwise J-NN tokens in the test id or the Name cell (full-depth test plans
    key rows UT-XX and may name the journey in the Name cell). Empty when the
    row cannot be attributed to any journey."""
    tid = row["test_id"].strip()
    m = _JOURNEY_ID_RE.match(tid)
    if m:
        return {"J-" + m.group(1)[2:]}
    found = set(_JOURNEY_TOKEN_RE.findall(tid)) | set(_JOURNEY_TOKEN_RE.findall(_cell(row, _C_NAME)))
    return found


def _row_sections(text: str) -> "dict[str, str]":
    """`### UT-xx ...` detail sections keyed by test id (until the next `##`)."""
    sections: dict[str, str] = {}
    cur = None
    buf: list[str] = []
    for line in text.splitlines():
        m = _SECTION_HEAD_RE.match(line.strip())
        if m:
            if cur:
                sections[cur] = "\n".join(buf)
            cur, buf = m.group(1).strip().rstrip(":—-"), []
            continue
        if line.startswith("##"):
            if cur:
                sections[cur] = "\n".join(buf)
            cur, buf = None, []
            continue
        if cur:
            buf.append(line)
    if cur:
        sections[cur] = "\n".join(buf)
    return sections


def row_infra_reason(row: dict, sections: "dict[str, str] | None" = None) -> str:
    """The browser-infra taxonomy match carried by THIS row (its cells, or its
    own `### <test id>` detail section) — "" when the row carries none."""
    m = _INFRA_TAXONOMY_RE.search(" | ".join(row["cells"]))
    if not m and sections:
        m = _INFRA_TAXONOMY_RE.search(sections.get(row["test_id"], ""))
    return m.group(0).strip() if m else ""


def classify_primary(text: "str | None", expected: "list[str]") -> "list[tuple[str, str, str]]":
    """Per-journey classification of the RAW primary browser results (see the
    module docstring). Returns [(journey, CLASS, detail)] in the order of
    `expected` (deduplicated). `text` None = unreadable/absent file."""
    seen: set[str] = set()
    order = [j for j in expected if j and not (j in seen or seen.add(j))]
    if text is None:
        return [(j, CLASS_MISSING, "results file missing/unreadable") for j in order]
    try:
        rows = parse_rows(text)
        sections = _row_sections(text)
    except Exception as exc:  # noqa: BLE001 — malformed input fails closed
        return [(j, CLASS_MISSING, f"results unparseable: {exc!r}") for j in order]
    mapped: dict[str, list[dict]] = {}
    for r in rows:
        for j in row_journeys(r):
            mapped.setdefault(j, []).append(r)
    lane_has_result = any(r["verdict"] in ("PASS", "FAIL") for r in rows)
    lane_m = _INFRA_TAXONOMY_RE.search(text)
    lane_reason = lane_m.group(0).strip() if lane_m else ""
    lane_dead = bool(rows) and not lane_has_result and bool(lane_reason)
    out: list[tuple[str, str, str]] = []
    for j in order:
        rs = mapped.get(j, [])
        if not rs:
            if lane_dead:
                out.append((j, CLASS_SKIP_INFRA, f"no row; whole primary lane infra-blocked: {lane_reason}"))
            else:
                out.append((j, CLASS_MISSING, "no primary-lane row"))
            continue
        vs = [r["verdict"] for r in rs]
        if "FAIL" in vs:
            out.append((j, CLASS_FAIL, _cell(rs[vs.index("FAIL")], _C_ACTUAL)))
            continue
        if vs and all(v == "PASS" for v in vs):
            out.append((j, CLASS_PASS, ""))
            continue
        reasons = [row_infra_reason(r, sections) for r in rs if r["verdict"] == "SKIP"]
        reasons = [x for x in reasons if x]
        if reasons:
            out.append((j, CLASS_SKIP_INFRA, reasons[0]))
        elif "SKIP" in vs and lane_dead:
            out.append((j, CLASS_SKIP_INFRA, f"SKIP row; whole primary lane infra-blocked: {lane_reason}"))
        elif "SKIP" in vs:
            out.append((j, CLASS_SKIP_OTHER, _cell(rs[vs.index("SKIP")], _C_ACTUAL)))
        else:
            out.append((j, CLASS_MISSING, "row present but its verdict cell is unparseable"))
    return out


def infra_journeys(text: "str | None", expected: "list[str]") -> "list[str]":
    """The SKIP_INFRA subset of classify_primary, in expected order."""
    return [j for j, c, _ in classify_primary(text, expected) if c == CLASS_SKIP_INFRA]


def coverage_gaps(primary_text: "str | None", required_primary: "list[str]", lane_floor: bool) -> "list[str]":
    """Why the fresh-evidence coverage contract is NOT satisfied — [] when it is.
    A required journey is satisfied only by a PASS-classified PRIMARY-lane row set
    (a generic UT-XX row never proves a journey — MISSING is a gap); any
    primary-lane browser-infra SKIP row is a gap (the dispatch owed that test
    case even when the row is not journey-attributable); the optional lane floor
    additionally requires at least one primary PASS row."""
    gaps = [f"{j}: {c}" for j, c, _ in classify_primary(primary_text, required_primary) if c != CLASS_PASS]
    prows = parse_rows(primary_text) if primary_text else []
    sections = _row_sections(primary_text) if primary_text else {}
    infra_rows = [r["test_id"] for r in prows if r["verdict"] == "SKIP" and row_infra_reason(r, sections)]
    if infra_rows:
        gaps.append("primary-lane browser-infra SKIP row(s): " + " ".join(infra_rows))
    if lane_floor and not any(r["verdict"] == "PASS" for r in prows):
        gaps.append("primary lane produced no PASS row" if prows else "primary lane produced no rows")
    return gaps


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


def merge(texts: "list[str]", required_primary: "list[str] | None" = None,
          primary_index: "int | None" = None, lane_floor: bool = False) -> str:
    """Merge in order; later inputs win per Test ID. Returns the merged markdown
    with a single authoritative headline verdict and detail rebuilt from the
    surviving rows (no verbatim per-lane embedding → exactly one verdict line).

    The fresh-evidence coverage contract (module docstring) is active when
    `required_primary` is non-empty or `lane_floor` is set; `primary_index`
    names the primary lane's entry in `texts` (None = the primary file is
    absent, so every required journey is MISSING). Inactive ⇒ byte-identical
    to the generic merge."""
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
    required_primary = [j for j in (required_primary or []) if j]
    gaps: list[str] = []
    if overall != "FAIL" and (required_primary or lane_floor):
        primary_text = texts[primary_index] if primary_index is not None and 0 <= primary_index < len(texts) else None
        gaps = coverage_gaps(primary_text, required_primary, lane_floor)
        if gaps:
            overall = "SKIPPED"
    n_pass = sum(1 for r in rows if r["verdict"] == "PASS")
    n_skip = sum(1 for r in rows if r["verdict"] == "SKIP")
    total = len(rows)

    out = ["# UI Test Results (merged)", "",
           f"**Date:** {_today()}",
           "**Written by:** merge_ui_test_results.py (LLM browser-qa + deterministic replay)",
           "", "---", "",
           f"**Browser QA Verdict:** {overall}", ""]
    if gaps:
        out += ["**Fresh-evidence coverage:** INCOMPLETE — the primary browser dispatch owed "
                "fresh evidence this iteration that it did not deliver: " + "; ".join(gaps) +
                ". Replay PASS rows below do not satisfy that obligation (the headline is "
                "SKIPPED, not PASS); no journey is marked FAIL on this basis.", ""]
    out += [f"**Overall:** {n_pass}/{total} journeys passed ({n_skip} skipped)",
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
            cells = [c.strip() for c in _CELL_SPLIT_RE.split(m.group(2))]
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


def cmd_classify(path: str, journeys: "list[str]") -> int:
    """Print `<J-NN>\t<CLASS>\t<detail>` per expected journey. Always exits 0:
    an unreadable file classifies everything MISSING (the caller must fail
    closed on MISSING — no token, no PASS — not crash)."""
    try:
        text: "str | None" = Path(path).read_text(encoding="utf-8")
    except OSError:
        text = None
    for j, c, d in classify_primary(text, journeys):
        print(f"{j}\t{c}\t{d}")
    return 0


def _split_opts(argv: "list[str]") -> "tuple[list[str], dict]":
    """Pull the merge options out of argv (any position after the out path)."""
    pos: list[str] = []
    opts: dict = {"required_primary": [], "primary_lane": None, "lane_floor": False}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--required-primary" and i + 1 < len(argv):
            opts["required_primary"] = [j for j in re.split(r"[,\s]+", argv[i + 1]) if j]
            i += 2
        elif a == "--primary-lane" and i + 1 < len(argv):
            opts["primary_lane"] = argv[i + 1]
            i += 2
        elif a == "--primary-lane-floor":
            opts["lane_floor"] = True
            i += 1
        else:
            pos.append(a)
            i += 1
    return pos, opts


def main(argv: "list[str]") -> int:
    if argv and argv[0] in ("self-test", "--self-test"):
        return _self_test()
    if argv and argv[0] == "void":
        if len(argv) < 3:
            sys.stderr.write("usage: merge_ui_test_results.py void <results.md> <J-XX> [...]\n")
            return 2
        return cmd_void(argv[1], argv[2:])
    if argv and argv[0] == "classify":
        if len(argv) < 2:
            sys.stderr.write("usage: merge_ui_test_results.py classify <raw-primary.md> <J-XX> [...]\n")
            return 2
        return cmd_classify(argv[1], argv[2:])
    pos, opts = _split_opts(argv)
    if len(pos) < 2:
        sys.stderr.write("usage: merge_ui_test_results.py <out.md> <in1.md> [<in2.md> ...] "
                         "[--required-primary J-XX,...] [--primary-lane <path>] [--primary-lane-floor]\n")
        return 2
    out_path = Path(pos[0])
    inputs = pos[1:]
    primary_lane = opts["primary_lane"] or inputs[-1]
    texts: list[str] = []
    primary_index: "int | None" = None
    for p in inputs:
        fp = Path(p)
        if fp.exists():
            if p == primary_lane or fp.resolve() == Path(primary_lane).resolve():
                primary_index = len(texts)
            texts.append(fp.read_text(encoding="utf-8"))
    if not texts:
        sys.stderr.write("[merge_ui_test_results] no readable input files\n")
        return 2
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(merge(texts, opts["required_primary"], primary_index, opts["lane_floor"]),
                        encoding="utf-8")
    contract = ""
    if opts["required_primary"] or opts["lane_floor"]:
        contract = (f" (fresh-evidence contract: required-primary={','.join(opts['required_primary']) or '-'}"
                    f"{', lane floor' if opts['lane_floor'] else ''}"
                    f"{'' if primary_index is not None else ', primary lane ABSENT'})")
    print(f"[merge_ui_test_results] merged {len(texts)} file(s) → {out_path}{contract}")
    return 0


# ── self-test (no filesystem) ────────────────────────────────────────────────

def _self_test() -> int:
    failures: list[str] = []
    n_checks = 0

    def check(name, fn):
        nonlocal n_checks
        n_checks += 1
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

    # ── anti-pattern 28: markdown-styled / annotated verdict cells ───────────
    # Real agent output shapes that previously parsed as NO verdict and dropped
    # out of compute_overall (ops-hardening iter-9: two bold FAILs → merged PASS).
    styled = (
        "**Browser QA Verdict:** FAIL\n\n## Results Table\n"
        "| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n"
        "|---|---|---|---|---|---|---|---|\n"
        "| UT-J-04 | compute | journey | P1 | e | button did nothing | **FAIL** | a.png |\n"
        "| UT-J-05 | sweep | journey | P1 | e | ok | PASS (with caveat) | b.png |\n"
        "| UT-J-06 | export | journey | P1 | e | no frontend | `SKIPPED` | none |\n"
        "| UT-J-07 | banner | journey | P1 | expected result: user sees PASS label | label missing | FAIL | c.png |\n")

    def t_bold_verdicts():
        rows = {r["test_id"]: r["verdict"] for r in parse_rows(styled)}
        assert rows["UT-J-04"] == "FAIL", rows
        # the bold FAIL must reach the headline — this is the laundered-PASS shape
        assert file_top_verdict(merge([styled])) == "FAIL", file_top_verdict(merge([styled]))

    def t_annotated_verdicts():
        rows = {r["test_id"]: r["verdict"] for r in parse_rows(styled)}
        assert rows["UT-J-05"] == "PASS", rows

    def t_backtick_skipped():
        rows = {r["test_id"]: r["verdict"] for r in parse_rows(styled)}
        assert rows["UT-J-06"] == "SKIP", rows

    def t_prose_not_verdict():
        # The verdict column outranks a free-prose cell that merely contains the
        # word PASS; and a bare prose cell never becomes a verdict by itself.
        rows = {r["test_id"]: r["verdict"] for r in parse_rows(styled)}
        assert rows["UT-J-07"] == "FAIL", rows
        prose_only = ("| UT-J-08 | banner | journey | P1 | expected: user sees PASS label "
                      "| label shows PASS text | (no verdict recorded) | none |\n")
        assert parse_rows(prose_only)[0]["verdict"] == "", parse_rows(prose_only)
        # the template placeholder and a passing-looking filename are not verdicts
        assert parse_rows("| UT-01 | n | smoke | P1 | e | a | PASS/FAIL | none |\n")[0]["verdict"] == ""
        assert parse_rows("| UT-01 | n | smoke | P1 | e | passed | | PASS.png |\n")[0]["verdict"] == ""

    def t_styled_headline():
        assert file_top_verdict("**Browser QA Verdict:** **FAIL**\n") == "FAIL"
        assert file_top_verdict("**Browser QA Verdict:** `SKIPPED`\n") == "SKIPPED"

    def t_escaped_pipe_cells():
        # cells split on UNESCAPED pipes only, so the verdict column is found by
        # position even when an earlier cell carries an escaped '|'
        row = "| UT-J-07 | Filter \\| sort table | regression | P1 | e | ok | PASS | b.png |\n"
        r = parse_rows(row)[0]
        assert len(r["cells"]) == 7 and r["verdict"] == "PASS", r

    # ── REL-14 (target-aware): primary-lane journey classification + the
    # fresh-evidence coverage headline. Fixture = the exact incident shape:
    # deterministic replay PASSes the stable journeys while the primary
    # browser dispatch could not start Chrome for this iteration's targets.
    hdr = ("| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n"
           "|---|---|---|---|---|---|---|---|\n")
    infra = "browser infrastructure failure: Chrome did not become ready on port 9222 within 15000ms"
    replay_ok = ("**Browser QA Verdict:** PASS\n\n## Results Table\n" + hdr +
                 "| UT-J-01 | login | regression | P1 | e | ok | PASS | a.png |\n"
                 "| UT-J-02 | browse | regression | P1 | e | ok | PASS | b.png |\n")
    primary_dead = ("**Browser QA Verdict:** SKIPPED\n\n## Results Table\n" + hdr +
                    f"| UT-J-04 | compute | journey | P1 | e | {infra} | SKIP | none |\n"
                    f"| UT-J-13 | sweep | journey | P1 | e | {infra} | SKIP | none |\n")
    primary_mixed = ("**Browser QA Verdict:** PASS\n\n## Results Table\n" + hdr +
                     "| UT-J-04 | compute | journey | P1 | e | ok | PASS | c.png |\n"
                     f"| UT-J-13 | sweep | journey | P1 | e | {infra} | SKIP | none |\n")
    primary_fail = ("**Browser QA Verdict:** FAIL\n\n## Results Table\n" + hdr +
                    "| UT-J-04 | compute | journey | P1 | e | button did nothing | FAIL | c.png |\n"
                    f"| UT-J-13 | sweep | journey | P1 | e | {infra} | SKIP | none |\n")
    primary_ok = ("**Browser QA Verdict:** PASS\n\n## Results Table\n" + hdr +
                  "| UT-J-04 | compute | journey | P1 | e | ok | PASS | c.png |\n"
                  "| UT-J-13 | sweep | journey | P1 | e | ok | PASS | d.png |\n")

    def cls(text, expected):
        return {j: (c, d) for j, c, d in classify_primary(text, expected)}

    def verdicts(md):
        return {r["test_id"]: r["verdict"] for r in parse_rows(md)}

    def t_classify_incident():  # R1 — both targets infra, nothing else
        c = cls(primary_dead, ["J-04", "J-13"])
        assert c["J-04"][0] == "SKIP_INFRA" and c["J-13"][0] == "SKIP_INFRA", c
        assert "did not become ready" in c["J-04"][1], c
        assert infra_journeys(primary_dead, ["J-04", "J-13"]) == ["J-04", "J-13"]

    def t_merge_incident_not_pass():  # R1 — replay PASS rows cannot satisfy the targets' obligation
        md = merge([replay_ok, primary_dead], required_primary=["J-04", "J-13"], primary_index=1)
        assert file_top_verdict(md) == "SKIPPED", file_top_verdict(md)
        v = verdicts(md)
        assert v["UT-J-01"] == "PASS" and v["UT-J-02"] == "PASS", v          # replay rows intact
        assert v["UT-J-04"] == "SKIP" and v["UT-J-13"] == "SKIP", v          # no journey FAILed by infra
        assert "FAIL" not in v.values(), v
        assert md.count("**Browser QA Verdict:**") == 1
        assert "J-04" in md.split("**Fresh-evidence coverage:**", 1)[1].splitlines()[0]
        # the same inputs WITHOUT the contract keep the generic-merger headline
        assert file_top_verdict(merge([replay_ok, primary_dead])) == "PASS"

    def t_classify_mixed():  # R2 — token only for the infra-blocked target
        c = cls(primary_mixed, ["J-04", "J-13"])
        assert c["J-04"][0] == "PASS" and c["J-13"][0] == "SKIP_INFRA", c
        assert infra_journeys(primary_mixed, ["J-04", "J-13"]) == ["J-13"]
        md = merge([replay_ok, primary_mixed], required_primary=["J-04", "J-13"], primary_index=1)
        assert file_top_verdict(md) == "SKIPPED", file_top_verdict(md)

    def t_classify_fail_dominates():  # R3 — a real product FAIL is never hidden by infra handling
        c = cls(primary_fail, ["J-04", "J-13"])
        assert c["J-04"][0] == "FAIL" and c["J-13"][0] == "SKIP_INFRA", c
        assert infra_journeys(primary_fail, ["J-04", "J-13"]) == ["J-13"]
        md = merge([replay_ok, primary_fail], required_primary=["J-04", "J-13"], primary_index=1)
        assert file_top_verdict(md) == "FAIL", file_top_verdict(md)

    def t_classify_non_infra_skip():  # R4 — a legitimate SKIP is never tokenized, never PASS
        p = ("**Browser QA Verdict:** SKIPPED\n\n## Results Table\n" + hdr +
             "| UT-J-04 | compute | journey | P1 | e | prerequisite data missing (contract) | SKIP | none |\n")
        c = cls(p, ["J-04"])
        assert c["J-04"][0] == "SKIP_OTHER", c
        assert infra_journeys(p, ["J-04"]) == []
        md = merge([replay_ok, p], required_primary=["J-04"], primary_index=1)
        assert file_top_verdict(md) == "SKIPPED", file_top_verdict(md)

    def t_classify_missing_row():  # R5 — no row: not PASS, no fabricated infra attribution
        p = ("**Browser QA Verdict:** PASS\n\n## Results Table\n" + hdr +
             "| UT-J-13 | sweep | journey | P1 | e | ok | PASS | d.png |\n")
        c = cls(p, ["J-04", "J-13"])
        assert c["J-04"][0] == "MISSING" and c["J-13"][0] == "PASS", c
        assert infra_journeys(p, ["J-04", "J-13"]) == []
        md = merge([replay_ok, p], required_primary=["J-04", "J-13"], primary_index=1)
        assert file_top_verdict(md) == "SKIPPED", file_top_verdict(md)
        # the whole primary file missing: every required journey is MISSING, headline SKIPPED
        assert all(c == "MISSING" for _, c, _ in classify_primary(None, ["J-04"]))
        assert file_top_verdict(merge([replay_ok], required_primary=["J-04"], primary_index=None)) == "SKIPPED"

    def t_lane_dead_missing_row():  # a lane with NO PASS/FAIL row + the infra taxonomy: a missing row IS infra-blocked
        p = ("**Browser QA Verdict:** SKIPPED\n\n## Results Table\n" + hdr +
             f"| UT-J-13 | sweep | journey | P1 | e | {infra} | SKIP | none |\n")
        c = cls(p, ["J-04", "J-13"])
        assert c["J-04"][0] == "SKIP_INFRA" and c["J-13"][0] == "SKIP_INFRA", c
        # ...but a row-less file is never infra (no row = no evidence the dispatch ran anything)
        assert cls("**Browser QA Verdict:** SKIPPED\n" + infra + "\n", ["J-04"])["J-04"][0] == "MISSING"

    def t_replay_only_healthy():  # R6 — every obligation replay-satisfied, no fresh-primary set
        assert file_top_verdict(merge([replay_ok])) == "PASS"
        assert file_top_verdict(merge([replay_ok], required_primary=[], primary_index=None)) == "PASS"

    def t_healthy_mixed_lanes():  # R7 — stable replay PASS + every required target PASS
        c = cls(primary_ok, ["J-04", "J-13"])
        assert all(v[0] == "PASS" for v in c.values()), c
        assert infra_journeys(primary_ok, ["J-04", "J-13"]) == []
        md = merge([replay_ok, primary_ok], required_primary=["J-04", "J-13"], primary_index=1)
        assert file_top_verdict(md) == "PASS", file_top_verdict(md)
        assert "**Fresh-evidence coverage:**" not in md   # healthy merged file unchanged
        assert md == merge([replay_ok, primary_ok]), "a satisfied contract is byte-identical to the generic merge"

    def t_section_reason():  # the reason may live in the row's ### section, not the Actual cell
        p = ("**Browser QA Verdict:** SKIPPED\n\n## Results Table\n" + hdr +
             "| UT-J-04 | compute | journey | P1 | e | browser never started | SKIP | none |\n"
             "| UT-J-13 | sweep | journey | P1 | e | ok | PASS | d.png |\n\n"
             "## Skipped Tests\n\n### UT-J-04 — compute\n**Verdict:** SKIPPED\n"
             "**Reason:** Chrome MCP did not become ready on port 9222\n\n## Environment\n")
        c = cls(p, ["J-04", "J-13"])
        assert c["J-04"][0] == "SKIP_INFRA" and c["J-13"][0] == "PASS", c

    def t_full_mode_plan_rows():  # the optional lane floor over generic UT-XX rows (a guard, never target proof)
        plan_ok = ("**Browser QA Verdict:** PASS\n\n## Results Table\n" + hdr +
                   "| UT-01 | page loads | smoke | P1 | e | ok | PASS | a.png |\n")
        plan_dead = ("**Browser QA Verdict:** SKIPPED\n\n## Results Table\n" + hdr +
                     f"| UT-01 | page loads | smoke | P1 | e | {infra} | SKIP | none |\n")
        assert file_top_verdict(merge([replay_ok, plan_ok], required_primary=[], primary_index=1, lane_floor=True)) == "PASS"
        assert file_top_verdict(merge([replay_ok, plan_dead], required_primary=[], primary_index=1, lane_floor=True)) == "SKIPPED"
        assert file_top_verdict(merge([replay_ok], required_primary=[], primary_index=None, lane_floor=True)) == "SKIPPED"
        # an untagged plan row cannot be attributed by journey — unless the whole lane is dead
        assert cls(plan_ok, ["J-02"])["J-02"][0] == "MISSING"
        assert cls(plan_dead, ["J-02"])["J-02"][0] == "SKIP_INFRA"
        # a journey token in the Name cell maps a plan-keyed row to its journey
        tagged = ("**Browser QA Verdict:** PASS\n\n## Results Table\n" + hdr +
                  "| UT-01 | J-02 add an item | smoke | P1 | e | ok | PASS | a.png |\n")
        assert cls(tagged, ["J-02"])["J-02"][0] == "PASS"

    def t_primary_infra_row_unmapped():  # an infra-SKIP row in the PRIMARY lane blocks PASS even when unmapped
        p = ("**Browser QA Verdict:** PASS\n\n## Results Table\n" + hdr +
             "| UT-01 | page loads | smoke | P1 | e | ok | PASS | a.png |\n"
             "| UT-02 | add item | smoke | P1 | e | browser infrastructure failure: crashed mid-run | SKIP | none |\n")
        assert file_top_verdict(merge([replay_ok, p], required_primary=[], primary_index=1, lane_floor=True)) == "SKIPPED"
        # replay-lane SKIP rows (a SPEED-22 void, an unscripted journey) are NOT primary rows and never block
        voided = ("**Browser QA Verdict:** PASS\n\n## Results Table\n" + hdr +
                  f"| UT-J-01 | login | regression | P1 | e | {_VOID_NOTE} | SKIP | none |\n"
                  "| UT-J-02 | browse | regression | P1 | e | ok | PASS | b.png |\n")
        assert file_top_verdict(merge([voided, primary_ok], required_primary=["J-04", "J-13"], primary_index=1)) == "PASS"

    check("classify_incident", t_classify_incident)
    check("merge_incident_not_pass", t_merge_incident_not_pass)
    check("classify_mixed", t_classify_mixed)
    check("classify_fail_dominates", t_classify_fail_dominates)
    check("classify_non_infra_skip", t_classify_non_infra_skip)
    check("classify_missing_row", t_classify_missing_row)
    check("lane_dead_missing_row", t_lane_dead_missing_row)
    check("replay_only_healthy", t_replay_only_healthy)
    check("healthy_mixed_lanes", t_healthy_mixed_lanes)
    check("section_reason", t_section_reason)
    check("full_mode_plan_rows", t_full_mode_plan_rows)
    check("primary_infra_row_unmapped", t_primary_infra_row_unmapped)

    check("bold_verdicts", t_bold_verdicts)
    check("annotated_verdicts", t_annotated_verdicts)
    check("backtick_skipped", t_backtick_skipped)
    check("prose_not_verdict", t_prose_not_verdict)
    check("styled_headline", t_styled_headline)
    check("escaped_pipe_cells", t_escaped_pipe_cells)

    for f in failures:
        print(f"  FAIL {f}", file=sys.stderr)
    print(f"[merge_ui_test_results self-test] {n_checks - len(failures)} passed, {len(failures)} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
