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
headline and the rows involved. The output has no timestamp and the section is written
once, so a re-apply is a no-op. The lane file itself is never touched.

Usage:
  qa_lane_gate.py apply <qa-report.md> <ui-test-results.md> --lane-required yes|no
                        [--test-plan <ui-test-plan.md>]
      exit 0 = QA verdict consistent with the lane (untouched, or annotated
               PASS_WITH_NOTES for non-blocking findings);
      exit 3 = the QA verdict was overridden to FAIL (file rewritten);
      exit 2 = usage error.
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

_PASSING = sorted((v.value for v in verdicts.PASSING_VERDICTS), key=len, reverse=True)
# Same shape verdicts.check_verdict_file() accepts, so every line it would read as a
# pass is found here.
_PASS_LINE_RE = re.compile(r"^\*\*Verdict:\*\*\s+(" + "|".join(map(re.escape, _PASSING)) + r")\s*$")
_FAIL_LINE_RE = re.compile(r"^\*\*Verdict:\*\*\s+FAIL\s*$")
_PLAN_ROW_RE = re.compile(r"^\|\s*[*_`~]*(UT-[^|\s*_`~]+)[*_`~]*\s*\|(.*)\|\s*$")
_PRIORITY_RE = re.compile(r"^[*_`\s]*(P[0-3])\b")
_PLAN_SECTION_RE = re.compile(r"^#{2,4}\s+(UT-[^\s:—–-]+(?:-[^\s:—–]+)*)")
_PLAN_PRIORITY_LINE_RE = re.compile(r"^\*\*Priority:\*\*\s*(P[0-3])\b")


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
        if v == "PASS":
            continue
        tid = r["test_id"]
        journeys = row_journeys(r)
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


def gate_text(qa_text: str, lane_text: "str | None", lane_path: str,
              plan_text: "str | None" = None, plan_path: str = "") -> "tuple[str, str]":
    """Return (new_qa_text, lane status). new_qa_text == qa_text when nothing changes."""
    lines = qa_text.splitlines(keepends=True)
    if not any(_PASS_LINE_RE.match(l.rstrip("\r\n")) for l in lines):
        return qa_text, ""
    if SECTION_HEADING in qa_text:
        return qa_text, "ALREADY-GATED"
    status, blocking, findings = assess_lane(lane_text, plan_priorities(plan_text))
    if status == "PASS":
        return qa_text, status

    agent_verdicts: list[str] = []
    if status == "FINDINGS":
        for i, line in enumerate(lines):
            m = _PASS_LINE_RE.match(line.rstrip("\r\n"))
            if m:
                agent_verdicts.append(m.group(1))
                if m.group(1) == "PASS":
                    lines[i] = "**Verdict:** PASS_WITH_NOTES\n"
    else:
        has_fail_line = any(_FAIL_LINE_RE.match(l.rstrip("\r\n")) for l in lines)
        for i, line in enumerate(lines):
            m = _PASS_LINE_RE.match(line.rstrip("\r\n"))
            if not m:
                continue
            agent_verdicts.append(m.group(1))
            if not has_fail_line:
                lines[i] = (f"**Verdict:** FAIL\n{AGENT_VERDICT_LABEL} {m.group(1)} — see "
                            f"\"{SECTION_HEADING[3:]}\" below.\n")
                has_fail_line = True
            else:
                lines[i] = f"{AGENT_VERDICT_LABEL} {m.group(1)}\n"

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
        "- **Rule:** a QA verdict cannot pass while this phase's required browser lane fails its DoD: "
        "a missing/SKIPPED lane, a failing journey row, or a failing (or skipped) check the pre-run "
        "test plan marks P1 or does not list (`scripts/automation/lib/qa_lane_gate.py`, anti-pattern 36). "
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
            "- The browser result is not converted into a pass. Fix what the lane reports, re-run the "
            "browser lane (`scripts/automation/browser-qa-phase.sh <phase>`), then QA; re-running QA "
            "alone cannot change this verdict.")
    body = "".join(lines).rstrip("\n")
    return body + "\n".join(section) + "\n", status


def _read(path: str) -> "str | None":
    try:
        return Path(path).read_text(encoding="utf-8")
    except (FileNotFoundError, IsADirectoryError):
        return None


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
    plan_text = _read(plan_path) if plan_path else None
    new_text, status = gate_text(qa_text, _read(lane_path), lane_path, plan_text, plan_path)
    if new_text == qa_text:
        why = {"": "QA verdict is not passing", "ALREADY-GATED": "already gated"}.get(status, f"browser lane {status}")
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
    print(__doc__.split("Usage:")[1].strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
