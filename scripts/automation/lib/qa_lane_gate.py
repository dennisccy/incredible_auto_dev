#!/usr/bin/env python3
"""qa_lane_gate.py — a QA PASS never stands beside a required browser lane that fails the DoD.

Why (anti-pattern 36): in the full pipeline the QA validator runs CONCURRENTLY with the
browser lane (run-phase.sh post-dev fanout), so it routinely writes its report before the
authoritative `reports/phase-<phase>-ui-test-results.md` is final — and nothing forced the
QA verdict to account for that lane. goal-taketwo iter 12: browser lane `FAIL` (the target
journey and three required journeys red), QA report `**Verdict:** PASS` / "All validations
passed" citing only three spot-check screenshots. That false green also unlocked the audit
(phase-audit.sh requires a passing QA verdict) and the "ALL CHECKS PASSED" banner.

Rule (deterministic, no model). The caller decides whether the browser lane is REQUIRED
(the phase has a frontend and maintenance isolation does not forbid the lane) and passes
`--lane-required`. When it is, a passing QA verdict (verdicts.PASSING_VERDICTS) is checked
against the lane:

- BLOCKING — the QA verdict is rewritten to FAIL:
  - the lane is missing, has no parseable `Browser QA Verdict` headline, or reads SKIPPED
    (the lane's own finalizer writes SKIPPED when a target journey got no fresh evidence);
  - a FAIL row for a journey (`UT-J-NN`, or a row naming a J-NN) — journeys are the DoD;
  - a QUALIFIED PASS on a journey row — a verdict cell with words after the token, such as
    `PASS (with disclosed caveat, not a product defect)` (anti-pattern 38). A journey passes
    only when every acceptance clause held, so its verdict cell is the bare token; caveats
    belong in the Actual cell, and an observation that contradicts a clause is FAIL whatever
    the cause (goal-taketwo iter 19: a contradicted J-01 clause was recorded as a PASS);
  - a FAIL row, or a non-journey SKIP row, that the PRE-RUN test plan (`--test-plan`,
    written by the UI test designer before the lane ran) marks P1 or does not list at all
    (unknown priority fails closed);
  - a FAIL headline with no FAIL row to account for it.
- NON-BLOCKING — the verdict may still pass, but never as a plain "all passed": a FAIL row
  for a non-journey test the pre-run plan marks P2 or P3 is a recorded finding, not a DoD
  failure. A plain `PASS` becomes `PASS_WITH_NOTES` and the report cites every such row.

Priorities come ONLY from the pre-run plan, never from the results table the executing
agent wrote (anti-pattern 25: a governor validates against signals the governed agent
cannot author).

The rewrite keeps every agent-written byte except the passing verdict lines:
verdicts.check_verdict_file() accepts ANY `**Verdict:** PASS` line in the file, so on a
blocking result each one is neutralised — the first becomes `**Verdict:** FAIL` (unless the
agent already wrote a FAIL verdict line) and the rest become
`**Agent verdict (overridden by the browser-lane gate):** <value>`. Either way a
`## Browser lane gate (deterministic)` section is appended naming the lane file, its
headline and the rows involved. The lane file itself is never touched.

Every apply re-assesses the lane: a gate section already on record never exempts a report
(an early "already gated" short-circuit let a PASS_WITH_NOTES survive a lane that turned
red on a closure_failed resume, which re-runs the lane but not QA). Every section the
gate wrote is replaced — never stacked, even with agent prose added below it — by one
reflecting the current lane, placed last and keeping the verdicts the agent originally
wrote. It carries no timestamp, so a re-apply over an unchanged lane is a no-op. An agent
that quotes the heading gains nothing: only a block in the gate's exact shape counts.

Skipped JOURNEY rows are deliberately left to the lane headline. Which journeys owe fresh
evidence is the lane finalizer's contract (merge_ui_test_results.py, REL-14): a skipped
target journey turns the headline SKIPPED (blocking here), while replay-lane SKIPs
(unscripted, DEFERRED-BUDGET, voided) never block. Blocking every skipped journey row
would turn those legitimate replay rows into QA failures.

Usage:
  qa_lane_gate.py apply <qa-report.md> <ui-test-results.md> --lane-required yes|no
                        [--test-plan <ui-test-plan.md>]
      exit 0 = QA verdict consistent with the lane (untouched, or annotated
               PASS_WITH_NOTES for non-blocking findings);
      exit 3 = the QA verdict was overridden to FAIL (file rewritten);
      exit 2 = usage error.
  qa_lane_gate.py lane-status <ui-test-results.md> [--test-plan <ui-test-plan.md>]
      prints the lane's DoD status: PASS | FINDINGS | FAIL | SKIPPED | MISSING |
      UNPARSEABLE (run-phase.sh routes the Step 7 fix path on it).
  qa_lane_gate.py self-test
"""
from __future__ import annotations

import os
import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import verdicts  # noqa: E402  (single source for the passing-verdict set)
from merge_ui_test_results import file_top_verdict, parse_rows, row_journeys  # noqa: E402

OVERRIDDEN_EXIT = 3
SECTION_HEADING = "## Browser lane gate (deterministic)"
AGENT_VERDICT_LABEL = "**Agent verdict (overridden by the browser-lane gate):**"
_RULE_BULLET = "- **Rule:** a QA verdict cannot pass while"
# How the gate's own section begins (it is always appended last, after a blank line).
_SECTION_START = f"\n\n{SECTION_HEADING}\n\n{_RULE_BULLET}"
_AGENT_VERDICT_RECORD_RE = re.compile(r"^- \*\*QA agent verdict:\*\* (.+?) — (?:stands|overridden)", re.M)

_PASSING = sorted((v.value for v in verdicts.PASSING_VERDICTS), key=len, reverse=True)
# Same shape verdicts.check_verdict_file() accepts, so every line it would read as a
# pass is found here.
_PASS_LINE_RE = re.compile(r"^\*\*Verdict:\*\*\s+(" + "|".join(map(re.escape, _PASSING)) + r")\s*$")
_FAIL_LINE_RE = re.compile(r"^\*\*Verdict:\*\*\s+FAIL\s*$")
_PLAN_ROW_RE = re.compile(r"^\|\s*[*_`~]*(UT-[^|\s*_`~]+)[*_`~]*\s*\|(.*)\|\s*$")
_PRIORITY_RE = re.compile(r"^[*_`\s]*(P[0-3])\b")
_PLAN_SECTION_RE = re.compile(r"^#{2,4}\s+(UT-[^\s:—–-]+(?:-[^\s:—–]+)*)")
_PLAN_PRIORITY_LINE_RE = re.compile(r"^\*\*Priority:\*\*\s*(P[0-3])\b")
# The verdict token leading a cell (emphasis tolerated), and the qualifier words after it.
_LEADING_TOKEN_RE = re.compile(r"^[\s*_`~]*(?:PASS|FAIL|SKIPPED|SKIP)[*_`~]*", re.IGNORECASE)
_WORD_RE = re.compile(r"[^\W_]", re.UNICODE)


def verdict_qualifier(cell: str) -> str:
    """The words a verdict cell carries after its token ("" for a bare `PASS`,
    `**PASS**` or `PASS ✓`). Only letters/digits count: emphasis, punctuation and
    symbols alone never make a verdict qualified."""
    m = _LEADING_TOKEN_RE.match(cell or "")
    rest = cell[m.end():] if m else ""
    return rest.strip() if _WORD_RE.search(rest) else ""


def plan_priorities(text: "str | None") -> "dict[str, str]":
    """Test id -> priority (P0..P3) from a pre-run UI test plan: its summary-table rows
    (`| UT-06 | name | type | P2 | surface |`) and its `### UT-06 …` sections'
    `**Priority:** P2` lines. When sources disagree the stricter (lower) priority wins."""
    pri: dict[str, str] = {}
    if not text:
        return pri

    def put(tid: str, p: str) -> None:
        if tid not in pri or p < pri[tid]:
            pri[tid] = p

    section = None
    for line in text.splitlines():
        s = line.strip()
        m = _PLAN_ROW_RE.match(s)
        if m:
            for cell in m.group(2).split("|"):
                pm = _PRIORITY_RE.match(cell.strip())
                if pm:
                    put(m.group(1), pm.group(1))
                    break
            continue
        m = _PLAN_SECTION_RE.match(s)
        if m:
            section = m.group(1)
            continue
        if s.startswith("#"):
            section = None
            continue
        m = _PLAN_PRIORITY_LINE_RE.match(s)
        if m and section:
            put(section, m.group(1))
    return pri


def assess_lane(text: "str | None", priorities: "dict[str, str]") -> "tuple[str, list[str], list[str]]":
    """(status, blocking rows, non-blocking rows).

    status: PASS | FINDINGS | FAIL | SKIPPED | MISSING | UNPARSEABLE. PASS and FINDINGS
    let a passing QA verdict stand (FINDINGS as PASS_WITH_NOTES); every other status
    blocks. Rows are rendered `<test id>: <verdict> (<why>)`."""
    if text is None:
        return "MISSING", [], []
    headline = file_top_verdict(text)
    if headline in ("SKIPPED", "SKIP"):
        return "SKIPPED", [], []
    if headline not in ("PASS", "FAIL"):
        return "UNPARSEABLE", [], []
    blocking: list[str] = []
    findings: list[str] = []
    fail_rows = 0
    for r in parse_rows(text):
        v = r["verdict"] or "UNKNOWN"
        tid = r["test_id"]
        journeys = row_journeys(r)
        if v == "PASS":
            if journeys and verdict_qualifier(r.get("verdict_cell", "")):
                # A journey verdict with conditions attached is not a pass (anti-pattern 38).
                blocking.append(f"{tid}: qualified PASS `{r['verdict_cell']}` (journey "
                                f"{', '.join(sorted(journeys))}) — a journey row passes only with a bare "
                                "PASS; caveats belong in Actual and a contradicted acceptance clause is FAIL")
            continue
        pri = priorities.get(tid, "")
        if v in ("FAIL", "UNKNOWN"):
            fail_rows += v == "FAIL"
            if journeys:
                blocking.append(f"{tid}: {v} (journey {', '.join(sorted(journeys))})")
            elif pri in ("P2", "P3"):
                findings.append(f"{tid}: {v} (pre-run plan priority {pri})")
            else:
                blocking.append(f"{tid}: {v} (pre-run plan priority {pri or 'not listed'})")
        elif v == "SKIP" and not journeys and pri not in ("P2", "P3"):
            # Journey coverage is the headline's job (the finalizer's fresh-evidence
            # contract); a skipped P1 / unlisted check is an unverified DoD item.
            blocking.append(f"{tid}: SKIP (pre-run plan priority {pri or 'not listed'})")
    if headline == "FAIL" and fail_rows == 0 and not blocking:
        return "UNPARSEABLE", ["headline FAIL with no FAIL row to account for it"], findings
    if blocking:
        return "FAIL", blocking, findings
    return ("FINDINGS" if findings else "PASS"), [], findings


def _display(path: str) -> str:
    try:
        rel = os.path.relpath(path)
    except ValueError:
        return path
    return path if rel.startswith("..") else rel


# The lines the gate's own section is made of — kept in step with gate_text's writer.
_GATE_BULLETS = (_RULE_BULLET, "- **Authoritative browser lane:**", "- **Pre-run test plan (priority source):**",
                 "- **QA agent verdict:**", "- **Blocking rows:**", "- **Non-blocking findings (pre-run plan P2/P3):**",
                 "- The browser result is not converted into a pass.", "  - ")


def _split_gate_section(qa_text: str) -> "tuple[str, list[str] | None]":
    """(report with every gate section removed, the agent verdicts the LAST one recorded).
    A gate section is the heading, a blank line, then an unbroken run of the gate's own
    lines (the gate never writes a blank line inside it); the first blank or other line
    ends it. So an agent's own bullets or notes below an old section, or a quoted heading,
    stay report prose. (A verbatim copy of a whole section is indistinguishable and is
    treated as the gate's — it is regenerated from the current lane anyway.)"""
    parts: list[str] = []
    recorded: "list[str] | None" = None
    pos = 0
    while (i := qa_text.find(_SECTION_START, pos)) >= 0:
        k = end = qa_text.index("\n", i + 2) + 2          # the Rule bullet's line
        while k < len(qa_text):
            nl = qa_text.find("\n", k)
            nl = len(qa_text) if nl < 0 else nl
            if not qa_text[k:nl].startswith(_GATE_BULLETS):
                break
            end, k = nl, nl + 1
        m = _AGENT_VERDICT_RECORD_RE.search(qa_text, i, end)
        recorded = [v.strip() for v in m.group(1).split(",")] if m else None
        parts.append(qa_text[pos:i])
        pos = end
    parts.append(qa_text[pos:])
    return "".join(parts), recorded


def gate_text(qa_text: str, lane_text: "str | None", lane_path: str,
              plan_text: "str | None" = None, plan_path: str = "") -> "tuple[str, str]":
    """Return (new_qa_text, lane status). new_qa_text == qa_text when nothing changes.

    The lane is re-assessed on EVERY call: a gate section already on record never exempts
    the report. It is replaced by one reflecting the current lane, so the lane turning red
    after an earlier PASS_WITH_NOTES (a closure_failed resume re-runs the lane but not QA)
    still overrides the verdict, and an unchanged lane leaves the report byte-identical."""
    if not any(_PASS_LINE_RE.match(l.rstrip("\r\n")) for l in qa_text.splitlines()):
        return qa_text, ""
    status, blocking, findings = assess_lane(lane_text, plan_priorities(plan_text))
    if status == "PASS":
        # An earlier findings record, if any, stays as written: the verdict passes either way.
        return qa_text, status

    base, recorded = _split_gate_section(qa_text)
    lines = base.splitlines(keepends=True)
    passing = [i for i, l in enumerate(lines) if _PASS_LINE_RE.match(l.rstrip("\r\n"))]
    # The agent's own words: a PASS the gate already turned into PASS_WITH_NOTES is still
    # the agent's PASS, so a re-gate reports (and relabels) what the agent actually wrote.
    agent_verdicts = [_PASS_LINE_RE.match(lines[i].rstrip("\r\n")).group(1) for i in passing]
    # Trusted only when it is consistent with the lines on record: the gate's one rewrite of
    # a passing line is PASS -> PASS_WITH_NOTES, so anything else is not its record.
    if recorded and len(recorded) == len(agent_verdicts) and all(
            r in _PASSING and (c == r or (r, c) == ("PASS", "PASS_WITH_NOTES"))
            for r, c in zip(recorded, agent_verdicts)):
        agent_verdicts = recorded
    if status == "FINDINGS":
        for i, original in zip(passing, agent_verdicts):
            if original == "PASS":
                lines[i] = "**Verdict:** PASS_WITH_NOTES\n"
    else:
        has_fail_line = any(_FAIL_LINE_RE.match(l.rstrip("\r\n")) for l in lines)
        for i, original in zip(passing, agent_verdicts):
            if not has_fail_line:
                lines[i] = (f"**Verdict:** FAIL\n{AGENT_VERDICT_LABEL} {original} — see "
                            f"\"{SECTION_HEADING[3:]}\" below.\n")
                has_fail_line = True
            else:
                lines[i] = f"{AGENT_VERDICT_LABEL} {original}\n"

    described = {"MISSING": "no results file", "UNPARSEABLE": "no parseable, self-consistent headline",
                 "SKIPPED": "`Browser QA Verdict: SKIPPED`"}
    file_headline = file_top_verdict(lane_text or "") or "none"
    # The gate's own DoD assessment is never presented as the file's headline: a lane can read
    # PASS while a pre-run-P1 check it skipped still blocks (goal-taketwo iter 18).
    lane_desc = described.get(status) or (
        f"file headline `Browser QA Verdict: {file_headline}`; gate DoD assessment **{status}**")
    plan_desc = f"`{_display(plan_path)}`" if plan_text else "none available (every non-journey failure blocks)"
    section = [
        "", "", SECTION_HEADING, "",
        f"{_RULE_BULLET} this phase's required browser lane fails its DoD: "
        "a missing/SKIPPED lane, a failing or qualified-PASS journey row, or a failing (or skipped) check "
        "the pre-run test plan marks P1 or does not list (`scripts/automation/lib/qa_lane_gate.py`, "
        "anti-patterns 36 and 38). "
        "The QA agent's own browser spot-checks never substitute for that lane.",
        f"- **Authoritative browser lane:** `{_display(lane_path)}` — {lane_desc}.",
        f"- **Pre-run test plan (priority source):** {plan_desc}.",
    ]
    if status == "FINDINGS":
        section.append(f"- **QA agent verdict:** {', '.join(agent_verdicts)} — stands, recorded as "
                       "**PASS_WITH_NOTES**: the only failing lane rows are checks the pre-run plan "
                       "marked P2/P3. They are findings, not DoD failures, and stay on record:")
        section.extend(f"  - {r}" for r in findings)
    else:
        section.append(f"- **QA agent verdict:** {', '.join(agent_verdicts)} — overridden to **FAIL**.")
        if blocking:
            section.append("- **Blocking rows:**")
            section.extend(f"  - {r}" for r in blocking)
        if findings:
            section.append("- **Non-blocking findings (pre-run plan P2/P3):**")
            section.extend(f"  - {r}" for r in findings)
        section.append(
            "- The browser result is not converted into a pass. Only the lane can change this verdict: "
            "fix what it reports, re-run it (`scripts/automation/browser-qa-phase.sh <phase>`; "
            "run-phase.sh's QA fix loop does this itself), then QA. Re-running QA alone cannot change it.")
    body = "".join(lines).rstrip("\n")
    return body + "\n".join(section) + "\n", status


def _read(path: str, lenient: bool = False) -> "str | None":
    """File text, or None when absent. `lenient` (the lane and the plan): undecodable bytes
    are replaced and an unreadable file counts as absent — the lane then reads MISSING and
    blocks, and the engine re-runs it, instead of a crash wedging every resume. The QA
    report itself is read strictly: a gate that cannot read it must not pass it."""
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace" if lenient else "strict")
    except (FileNotFoundError, IsADirectoryError):
        return None
    except PermissionError:
        if lenient:
            return None
        raise


def cmd_apply(qa_path: str, lane_path: str, lane_required: str, plan_path: str = "") -> int:
    if lane_required not in ("yes", "no"):
        print("qa_lane_gate: --lane-required must be yes or no", file=sys.stderr)
        return 2
    if lane_required == "no":
        print("qa_lane_gate: browser lane not required for this phase — nothing to gate")
        return 0
    qa_text = _read(qa_path)
    if qa_text is None:
        print(f"qa_lane_gate: no QA report at {qa_path} — nothing to gate")
        return 0
    plan_text = _read(plan_path, lenient=True) if plan_path else None
    new_text, status = gate_text(qa_text, _read(lane_path, lenient=True), lane_path, plan_text, plan_path)
    if new_text == qa_text:
        why = "QA verdict is not passing" if not status else f"browser lane {status}"
        print(f"qa_lane_gate: consistent ({why}) — QA report unchanged")
        return 0
    Path(qa_path).write_text(new_text, encoding="utf-8")
    if status == "FINDINGS":
        print(f"qa_lane_gate: QA verdict stands as PASS_WITH_NOTES — non-blocking P2/P3 lane findings cited ({_display(lane_path)})")
        return 0
    if verdicts.check_verdict_file(qa_path):
        # Postcondition: the machine verdict reader must now see a failing report.
        print(f"qa_lane_gate: INTERNAL ERROR — {qa_path} still reads as passing after the rewrite", file=sys.stderr)
        return 1
    print(f"qa_lane_gate: QA verdict overridden to FAIL — required browser lane fails the DoD ({status}) ({_display(lane_path)})")
    return OVERRIDDEN_EXIT


def lane_status(lane_path: str, plan_path: str = "") -> str:
    """The lane's DoD status alone (assess_lane), for callers that route on it:
    run-phase.sh re-runs a lane that produced no usable evidence without a dev fix."""
    plan_text = _read(plan_path, lenient=True) if plan_path else None
    return assess_lane(_read(lane_path, lenient=True), plan_priorities(plan_text))[0]


def _self_test() -> int:
    lane_hdr = ("| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n"
                "|---|---|---|---|---|---|---|---|\n")

    def lane(headline: str, *rows: str) -> str:
        return f"**Browser QA Verdict:** {headline}\n\n## Results Table\n" + lane_hdr + "".join(rows)

    def row(tid: str, verdict: str, pri: str = "P1", name: str = "check") -> str:
        return f"| {tid} | {name} | browser | {pri} | ok | x | {verdict} | e.png |\n"

    plan = ("# UI test plan\n\n### UT-01 — smoke\n\n**Priority:** P1\n\n### UT-06 — lifecycle\n\n"
            "**Priority:** P2\n\n## Summary\n\n| ID | Name | Type | Priority | Surface |\n|---|---|---|---|---|\n"
            "| UT-01 | smoke | smoke | P1 | / |\n| UT-06 | lifecycle | regression | P2 | / |\n"
            "| UT-07 | ux | ux | P3 | / |\n")
    lane_journey_fail = lane("FAIL", row("UT-J-01", "PASS"), row("UT-J-06", "FAIL"), row("UT-09", "SKIP", "P2"))
    lane_pass = lane("PASS", row("UT-J-01", "PASS"))
    lane_skipped = "**Browser QA Verdict:** SKIPPED\n\n**Reason:** Chrome did not become ready\n"
    lane_p2_fail = lane("FAIL", row("UT-J-01", "PASS"), row("UT-01", "PASS"), row("UT-06", "FAIL", "P2"))
    lane_p1_fail = lane("FAIL", row("UT-J-01", "PASS"), row("UT-01", "FAIL", "P1"))
    lane_unlisted_fail = lane("FAIL", row("UT-J-01", "PASS"), row("UT-99", "FAIL", "P3"))
    lane_agent_downgrade = lane("FAIL", row("UT-01", "FAIL", "P3"))   # plan says P1
    lane_pass_headline_journey_fail = lane("PASS", row("UT-J-02", "**FAIL**"))
    lane_p1_skip = lane("PASS", row("UT-J-01", "PASS"), row("UT-01", "SKIP", "P1"))
    lane_fail_no_rows = lane("FAIL", row("UT-J-01", "PASS"))
    lane_journey_qualified = lane("PASS", row(
        "UT-J-01", "PASS (with disclosed test-contamination caveat, not a product defect)"))
    lane_journey_bare_styled = lane("PASS", row("UT-J-01", "**PASS**"), row("UT-J-07", "PASS ✓"))
    lane_nonjourney_qualified = lane("PASS", row("UT-J-01", "PASS"), row("UT-01", "PASS (slow but correct)"))
    qa_pass = ("# p QA Validation Report\n\n**Verdict:** PASS\n\n## Browser Checks\n\nAll good.\n\n"
               "**Verdict:** PASS_WITH_NOTES\n")

    failures: list[str] = []

    def check(cond: bool, label: str) -> None:
        print(("  PASS  " if cond else "  FAIL  ") + label)
        if not cond:
            failures.append(label)

    with tempfile.TemporaryDirectory() as d:
        dp = Path(d)
        qp, lp, pp = dp / "qa.md", dp / "lane.md", dp / "plan.md"

        def run(qa: "str | None", lane_text: "str | None", required: str = "yes",
                plan_text: "str | None" = plan) -> "tuple[int, str]":
            for p in (qp, lp, pp):
                if p.exists():
                    p.unlink()
            if qa is not None:
                qp.write_text(qa, encoding="utf-8")
            if lane_text is not None:
                lp.write_text(lane_text, encoding="utf-8")
            if plan_text is not None:
                pp.write_text(plan_text, encoding="utf-8")
            rc = cmd_apply(str(qp), str(lp), required, str(pp))
            return rc, (qp.read_text(encoding="utf-8") if qp.exists() else "")

        def passes() -> bool:
            return verdicts.check_verdict_file(str(qp))

        rc, out = run(qa_pass, lane_journey_fail)
        check(rc == OVERRIDDEN_EXIT, "A: QA PASS + failing journey row -> overridden (exit 3)")
        check(not passes(), "A: verdicts.py now reads the QA report as failing")
        check(out.count("**Verdict:** FAIL") == 1, "A: exactly one FAIL verdict line")
        check(out.index("**Verdict:** FAIL") < out.index("## Browser Checks"),
              "A: the FAIL verdict takes the agent's top verdict position")
        check(f"{AGENT_VERDICT_LABEL} PASS_WITH_NOTES" in out, "A: a second passing line is neutralised too")
        check("UT-J-06: FAIL (journey J-06)" in out and "All good." in out,
              "A: names the blocking journey row; agent prose preserved")
        rc2, out2 = run(out, lane_journey_fail)
        check(rc2 == 0 and out2 == out, "A: re-apply is a no-op (idempotent)")

        rc, out = run(qa_pass, lane_pass)
        check(rc == 0 and out == qa_pass, "B: lane PASS -> QA report byte-identical")

        rc, out = run(qa_pass, lane_skipped)
        check(rc == OVERRIDDEN_EXIT and "`Browser QA Verdict: SKIPPED`" in out, "C: lane SKIPPED -> overridden")

        rc, out = run(qa_pass, None)
        check(rc == OVERRIDDEN_EXIT and "no results file" in out, "D: lane file missing -> overridden (fail closed)")

        rc, out = run(qa_pass, "# results\n\nno headline here\n")
        check(rc == OVERRIDDEN_EXIT and "no parseable" in out, "E: unparseable lane -> overridden (fail closed)")

        rc, out = run(qa_pass, lane_pass_headline_journey_fail)
        check(rc == OVERRIDDEN_EXIT and "UT-J-02: FAIL" in out, "F: a failing journey row outranks a PASS headline")

        rc, out = run(qa_pass, lane_journey_fail, required="no")
        check(rc == 0 and out == qa_pass, "G: lane not required (backend-only / isolation) -> untouched")

        qa_fail = "# QA\n\n**Verdict:** FAIL\n\nTests failed.\n"
        rc, out = run(qa_fail, lane_journey_fail)
        check(rc == 0 and out == qa_fail, "H: agent FAIL verdict -> untouched (normal fix loop owns it)")

        rc, out = run(None, lane_journey_fail)
        check(rc == 0 and not qp.exists(), "I: no QA report -> nothing written")

        mixed = "# QA\n\n**Verdict:** FAIL\n\nlater:\n**Verdict:** PASS\n"
        rc, out = run(mixed, lane_journey_fail)
        check(rc == OVERRIDDEN_EXIT and out.count("**Verdict:** FAIL") == 1 and not passes(),
              "J: existing FAIL line kept; stray PASS line neutralised, no second FAIL line")

        check(cmd_apply(str(qp), str(lp), "maybe") == 2, "K: bad --lane-required -> usage error")

        rc, out = run(qa_pass, lane_p2_fail)
        check(rc == 0 and passes() and "**Verdict:** PASS_WITH_NOTES" in out.splitlines()[2],
              "L: only a pre-run-P2 row fails -> QA passes as PASS_WITH_NOTES")
        check("UT-06: FAIL (pre-run plan priority P2)" in out and "All good." in out,
              "L: the non-blocking finding is cited in the QA report")
        rc2, out2 = run(out, lane_p2_fail)
        check(rc2 == 0 and out2 == out, "L: re-apply is a no-op (idempotent)")

        rc, out = run(qa_pass, lane_p1_fail)
        check(rc == OVERRIDDEN_EXIT and "UT-01: FAIL (pre-run plan priority P1)" in out, "M: a pre-run-P1 row fails -> blocks")

        rc, out = run(qa_pass, lane_unlisted_fail)
        check(rc == OVERRIDDEN_EXIT and "UT-99: FAIL (pre-run plan priority not listed)" in out,
              "N: a row the pre-run plan does not list fails -> blocks (fail closed)")

        rc, out = run(qa_pass, lane_agent_downgrade)
        check(rc == OVERRIDDEN_EXIT, "O: the executing agent's own priority cell cannot downgrade a P1 failure")

        rc, out = run(qa_pass, lane_p2_fail, plan_text=None)
        check(rc == OVERRIDDEN_EXIT, "P: no pre-run plan -> every non-journey failure blocks")

        rc, out = run(qa_pass, lane_p1_skip)
        check(rc == OVERRIDDEN_EXIT and "UT-01: SKIP" in out, "Q: a skipped pre-run-P1 check blocks (unverified DoD item)")
        check("file headline `Browser QA Verdict: PASS`; gate DoD assessment **FAIL**" in out,
              "Q: the gate's DoD assessment is never presented as the file's own headline")

        rc, out = run(qa_pass, lane_fail_no_rows)
        check(rc == OVERRIDDEN_EXIT, "R: FAIL headline with no FAIL row -> blocks (inconsistent lane)")

        rc, out = run(qa_pass, lane_journey_qualified)
        check(rc == OVERRIDDEN_EXIT and "UT-J-01: qualified PASS" in out and not passes(),
              "T: a qualified PASS on a journey row blocks (anti-pattern 38)")

        rc, out = run(qa_pass, lane_journey_bare_styled)
        check(rc == 0 and out == qa_pass, "U: emphasis or a symbol around a journey PASS is still bare")

        rc, out = run(qa_pass, lane_nonjourney_qualified)
        check(rc == 0 and out == qa_pass, "V: a qualified PASS on a non-journey row does not block")

        check(all(verdict_qualifier(c) == "" for c in ("PASS", "**PASS**", "PASS ✓", "`PASS`.", "")),
              "W: bare verdict cells carry no qualifier")
        check(all(verdict_qualifier(c) for c in ("PASS (with caveat)", "**PASS** — step 3 partial", "PASS: see note")),
              "W: worded annotations are qualifiers")

        # ── Re-gating (review finding #1): a gate section on record never exempts the
        # report — the lane is re-assessed on every apply, so a lane that turned red
        # after an earlier PASS_WITH_NOTES (closure_failed resume re-runs the lane but
        # not QA; Step 9 hardening may leave the old report) is still caught.
        rc, gated = run(qa_pass, lane_p2_fail)
        rc, out = run(gated, lane_journey_fail)
        check(rc == OVERRIDDEN_EXIT and not passes(), "X: gated PASS_WITH_NOTES + lane now fails a journey -> FAIL")
        check(out.count(SECTION_HEADING) == 1 and "UT-J-06: FAIL (journey J-06)" in out
              and "UT-06: FAIL (pre-run plan priority P2)" not in out.split(SECTION_HEADING)[0],
              "X: the stale section is replaced, not stacked")
        check(f"- **QA agent verdict:** PASS, PASS_WITH_NOTES — overridden" in out,
              "X: the agent's ORIGINAL verdicts stay on record across a re-gate")
        rc2, out2 = run(out, lane_journey_fail)
        check(rc2 == 0 and out2 == out, "X: re-apply of the re-gated report is a no-op")

        lane_p2_p3_fail = lane("FAIL", row("UT-J-01", "PASS"), row("UT-06", "FAIL", "P2"), row("UT-07", "FAIL", "P3"))
        rc, out = run(gated, lane_p2_p3_fail)
        check(rc == 0 and passes() and out.count(SECTION_HEADING) == 1 and "UT-07: FAIL (pre-run plan priority P3)" in out,
              "Y: findings changed -> the section is refreshed in place and QA still passes")
        check(f"- **QA agent verdict:** PASS, PASS_WITH_NOTES — stands" in out,
              "Y: the refreshed section keeps the agent's original verdicts")

        rc, out = run(gated, lane_pass)
        check(rc == 0 and out == gated, "AA: gated PASS_WITH_NOTES + lane now PASS -> report left as recorded")

        appended = gated.rstrip("\n") + "\n\nRe-run note from the agent: checked again.\n"
        rc, out = run(appended, lane_journey_fail)
        check(rc == OVERRIDDEN_EXIT and out.count(SECTION_HEADING) == 1 and "Re-run note from the agent" in out
              and out.index("Re-run note from the agent") < out.index(SECTION_HEADING)
              and f"- **QA agent verdict:** PASS, PASS_WITH_NOTES — overridden" in out,
              "AD: prose appended below a stale section -> the section is still replaced, not stacked")

        bullets_after = gated.rstrip("\n") + "\n\n- Re-verified J-02 by hand; see evidence/j02.png\n"
        rc, out = run(bullets_after, lane_journey_fail)
        check(rc == OVERRIDDEN_EXIT and "- Re-verified J-02 by hand" in out and out.count(SECTION_HEADING) == 1,
              "AE: agent bullets written after an old gate section are prose, never swallowed with it")

        old_quote = gated.split(SECTION_HEADING)[1].replace("PASS, PASS_WITH_NOTES — stands", "FAIL, FAIL — stands")
        quoted_then_real = ("# QA\n\nAn older run's gate said:\n\n" + SECTION_HEADING + old_quote.rstrip("\n")
                            + "\n\nNow:\n\n**Verdict:** PASS\n\n**Verdict:** PASS_WITH_NOTES\n")
        rc, first = run(quoted_then_real, lane_p2_fail)
        rc, out = run(first, lane_journey_fail)
        check(rc == OVERRIDDEN_EXIT and f"- **QA agent verdict:** PASS, PASS_WITH_NOTES — overridden" in out,
              "AF: the agent verdicts on record come from the LAST gate section, never an earlier quoted one")

        lp.write_bytes(b"**Browser QA Verdict:** PASS\n\n\xff\xfe stray bytes\n| UT-J-01 | a | b | P1 | c | d | PASS | e |\n")
        check(lane_status(str(lp), str(pp)) == "PASS", "AG: undecodable bytes in the lane file never crash the gate")

        quoting = qa_pass + f"\nThe previous run said:\n\n{SECTION_HEADING}\n\n(quoted by the agent)\n"
        rc, out = run(quoting, lane_journey_fail)
        check(rc == OVERRIDDEN_EXIT and not passes() and "(quoted by the agent)" in out,
              "Z: an agent quoting the gate heading is still gated; its prose is kept")

        # ── Journey SKIP rows (review finding #4 — deliberately NOT blocking). Which
        # journeys owe fresh evidence is the lane finalizer's contract (REL-14): a
        # skipped TARGET journey turns the headline SKIPPED (case C), while replay-lane
        # SKIPs (unscripted, DEFERRED-BUDGET, voided) never block. Pinned here so a
        # future "block every skipped journey" change has to face that contract.
        lane_nontarget_journey_skip = lane("PASS", row("UT-J-01", "PASS"), row("UT-J-02", "SKIP (unscripted replay)"))
        rc, out = run(qa_pass, lane_nontarget_journey_skip)
        check(rc == 0 and out == qa_pass, "AB: a skipped journey row under a PASS headline does not block (finalizer's job)")

        # ── lane-status (run-phase.sh routes the Step 7 fix path on it).
        for text, want in ((lane_pass, "PASS"), (lane_p2_fail, "FINDINGS"), (lane_journey_fail, "FAIL"),
                           (lane_skipped, "SKIPPED"), (None, "MISSING"), ("# r\n\nno headline\n", "UNPARSEABLE")):
            if lp.exists():
                lp.unlink()
            if text is not None:
                lp.write_text(text, encoding="utf-8")
            pp.write_text(plan, encoding="utf-8")
            check(lane_status(str(lp), str(pp)) == want, f"AC: lane-status -> {want}")

        check(plan_priorities(plan) == {"UT-01": "P1", "UT-06": "P2", "UT-07": "P3"}, "S: plan priorities parsed")
        check(plan_priorities("| UT-05 | x | y | P1 | s |\n### UT-05 — x\n**Priority:** P2\n") == {"UT-05": "P1"},
              "S: conflicting plan priorities -> the stricter wins")
        check(plan_priorities("| **UT-08** | x | y | **P2** | s |\n") == {"UT-08": "P2"},
              "S: styled plan ID and priority cells parse")

    print(f"qa_lane_gate self-test: {'OK' if not failures else f'{len(failures)} FAILED'}")
    return 0 if not failures else 1


def main(argv: "list[str]") -> int:
    if argv[:1] == ["self-test"]:
        return _self_test()
    if argv[:1] == ["apply"] and len(argv) in (5, 7) and argv[3] == "--lane-required":
        plan = ""
        if len(argv) == 7:
            if argv[5] != "--test-plan":
                return main([])
            plan = argv[6]
        return cmd_apply(argv[1], argv[2], argv[4], plan)
    if argv[:1] == ["lane-status"] and (len(argv) == 2 or (len(argv) == 4 and argv[2] == "--test-plan")):
        print(lane_status(argv[1], argv[3] if len(argv) == 4 else ""))
        return 0
    print(__doc__.split("Usage:")[1].strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
