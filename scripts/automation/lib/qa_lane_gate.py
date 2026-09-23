#!/usr/bin/env python3
"""qa_lane_gate.py — a QA PASS never stands beside a required browser lane that is not PASS.

Why (anti-pattern 36): in the full pipeline the QA validator runs CONCURRENTLY with the
browser lane (run-phase.sh post-dev fanout), so it routinely writes its report before the
authoritative `reports/phase-<phase>-ui-test-results.md` is final — and nothing forced the
QA verdict to account for that lane. goal-taketwo iter 12: browser lane `FAIL` (the target
journey and three required journeys red), QA report `**Verdict:** PASS` / "All validations
passed" citing only three spot-check screenshots. That false green also unlocked the audit
(phase-audit.sh requires a passing QA verdict) and the "ALL CHECKS PASSED" banner.

Rule (deterministic, no model): when the browser lane is REQUIRED for the phase (the phase
has a frontend and maintenance isolation does not forbid the lane — the caller decides and
passes `--lane-required`), a passing QA verdict (verdicts.PASSING_VERDICTS) survives only
if the lane's headline reads PASS and no results row reads FAIL. A FAIL, SKIPPED,
unparseable or missing lane rewrites the QA report's verdict to FAIL. The browser failure
is never converted into a PASS, and the QA agent's own spot-checks never substitute for
the lane.

The rewrite keeps every agent-written byte except the passing verdict lines:
verdicts.check_verdict_file() accepts ANY `**Verdict:** PASS` line in the file, so each
one is neutralised — the first becomes `**Verdict:** FAIL` (unless the agent already wrote
a FAIL verdict line) and the rest become
`**Agent verdict (overridden by the browser-lane gate):** <value>` — and a
`## Browser lane gate (deterministic)` section is appended citing the lane file, its
headline and every row that is not PASS. The output has no timestamp, so a re-apply is a
no-op (the report no longer passes).

Usage:
  qa_lane_gate.py apply <qa-report.md> <ui-test-results.md> --lane-required yes|no
      exit 0 = nothing to gate (lane not required, QA report absent or not passing,
               or lane PASS) — the file is untouched;
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
from merge_ui_test_results import file_top_verdict, parse_rows  # noqa: E402

OVERRIDDEN_EXIT = 3
SECTION_HEADING = "## Browser lane gate (deterministic)"
AGENT_VERDICT_LABEL = "**Agent verdict (overridden by the browser-lane gate):**"

_PASSING = sorted((v.value for v in verdicts.PASSING_VERDICTS), key=len, reverse=True)
# Same shape verdicts.check_verdict_file() accepts, so every line it would read as a
# pass is found here.
_PASS_LINE_RE = re.compile(r"^\*\*Verdict:\*\*\s+(" + "|".join(map(re.escape, _PASSING)) + r")\s*$")
_FAIL_LINE_RE = re.compile(r"^\*\*Verdict:\*\*\s+FAIL\s*$")


def lane_status(text: "str | None") -> "tuple[str, list[str]]":
    """(status, non-PASS rows) of a browser-lane results file.

    status: PASS | FAIL | SKIPPED | MISSING | UNPARSEABLE. A FAIL row outranks a PASS
    headline (the lane's own finalizer recomputes the headline from its rows; a
    hand-edited or stale headline must not launder a failing row). Rows are reported
    as `<test id>: <verdict>`, UNKNOWN when no cell parses as a verdict."""
    if text is None:
        return "MISSING", []
    rows = parse_rows(text)
    not_pass = [f"{r['test_id']}: {r['verdict'] or 'UNKNOWN'}" for r in rows if r["verdict"] != "PASS"]
    headline = file_top_verdict(text)
    if headline == "FAIL" or any(r["verdict"] == "FAIL" for r in rows):
        return "FAIL", not_pass
    if headline == "PASS":
        return "PASS", not_pass
    if headline in ("SKIPPED", "SKIP"):
        return "SKIPPED", not_pass
    return "UNPARSEABLE", not_pass


def _display(path: str) -> str:
    try:
        rel = os.path.relpath(path)
    except ValueError:
        return path
    return path if rel.startswith("..") else rel


def gate_text(qa_text: str, lane_text: "str | None", lane_path: str) -> "tuple[str, str]":
    """Return (new_qa_text, lane status). new_qa_text == qa_text when nothing is gated."""
    lines = qa_text.splitlines(keepends=True)
    if not any(_PASS_LINE_RE.match(l.rstrip("\r\n")) for l in lines):
        return qa_text, ""
    status, not_pass = lane_status(lane_text)
    if status == "PASS":
        return qa_text, status

    has_fail_line = any(_FAIL_LINE_RE.match(l.rstrip("\r\n")) for l in lines)
    agent_verdicts: list[str] = []
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

    headline = {"MISSING": "no results file", "UNPARSEABLE": "no parseable `Browser QA Verdict` headline"}
    lane_desc = headline.get(status, f"`Browser QA Verdict: {status}`")
    section = [
        "", "", SECTION_HEADING, "",
        "- **Rule:** a QA verdict cannot pass while this phase's required browser lane is not PASS "
        "(`scripts/automation/lib/qa_lane_gate.py`, anti-pattern 36). The QA agent's own browser "
        "spot-checks never substitute for that lane.",
        f"- **QA agent verdict:** {', '.join(agent_verdicts)} — overridden to **FAIL**.",
        f"- **Authoritative browser lane:** `{_display(lane_path)}` — {lane_desc}.",
    ]
    if not_pass:
        section.append("- **Rows not passing:**")
        section.extend(f"  - {r}" for r in not_pass)
    section.append(
        "- The browser result is not converted into a pass. Fix what the lane reports, re-run the "
        "browser lane (`scripts/automation/browser-qa-phase.sh <phase>`), then QA; re-running QA "
        "alone cannot change this verdict.")
    body = "".join(lines).rstrip("\n")
    return body + "\n".join(section) + "\n", status


def cmd_apply(qa_path: str, lane_path: str, lane_required: str) -> int:
    if lane_required not in ("yes", "no"):
        print("qa_lane_gate: --lane-required must be yes or no", file=sys.stderr)
        return 2
    if lane_required == "no":
        print("qa_lane_gate: browser lane not required for this phase — nothing to gate")
        return 0
    try:
        qa_text = Path(qa_path).read_text(encoding="utf-8")
    except FileNotFoundError:
        print(f"qa_lane_gate: no QA report at {qa_path} — nothing to gate")
        return 0
    try:
        lane_text: "str | None" = Path(lane_path).read_text(encoding="utf-8")
    except FileNotFoundError:
        lane_text = None
    new_text, status = gate_text(qa_text, lane_text, lane_path)
    if new_text == qa_text:
        why = f"browser lane {status}" if status else "QA verdict is not passing"
        print(f"qa_lane_gate: consistent ({why}) — QA report unchanged")
        return 0
    Path(qa_path).write_text(new_text, encoding="utf-8")
    if verdicts.check_verdict_file(qa_path):
        # Postcondition: the machine verdict reader must now see a failing report.
        print(f"qa_lane_gate: INTERNAL ERROR — {qa_path} still reads as passing after the rewrite", file=sys.stderr)
        return 1
    print(f"qa_lane_gate: QA verdict overridden to FAIL — required browser lane is {status} ({_display(lane_path)})")
    return OVERRIDDEN_EXIT


def _self_test() -> int:
    lane_hdr = ("| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n"
                "|---|---|---|---|---|---|---|---|\n")
    lane_fail = ("**Browser QA Verdict:** FAIL\n\n## Results Table\n" + lane_hdr +
                 "| UT-J-01 | upload | browser | P1 | ok | ok | PASS | a.png |\n"
                 "| UT-J-06 | correction | browser | P1 | ok | replay miss | FAIL | b.png |\n"
                 "| UT-J-09 | budget | browser | P1 | ok | - | SKIP | - |\n")
    lane_pass = ("**Browser QA Verdict:** PASS\n\n## Results Table\n" + lane_hdr +
                 "| UT-J-01 | upload | browser | P1 | ok | ok | PASS | a.png |\n")
    lane_skipped = "**Browser QA Verdict:** SKIPPED\n\n**Reason:** Chrome did not become ready\n"
    lane_pass_headline_fail_row = ("**Browser QA Verdict:** PASS\n\n## Results Table\n" + lane_hdr +
                                   "| UT-J-02 | analyse | browser | P1 | ok | no | **FAIL** | c.png |\n")
    qa_pass = ("# p QA Validation Report\n\n**Verdict:** PASS\n\n## Browser Checks\n\nAll good.\n\n"
               "**Verdict:** PASS_WITH_NOTES\n")

    failures: list[str] = []

    def check(cond: bool, label: str) -> None:
        print(("  PASS  " if cond else "  FAIL  ") + label)
        if not cond:
            failures.append(label)

    with tempfile.TemporaryDirectory() as d:
        dp = Path(d)

        def run(qa: "str | None", lane: "str | None", required: str = "yes") -> "tuple[int, str]":
            qp, lp = dp / "qa.md", dp / "lane.md"
            for p in (qp, lp):
                if p.exists():
                    p.unlink()
            if qa is not None:
                qp.write_text(qa, encoding="utf-8")
            if lane is not None:
                lp.write_text(lane, encoding="utf-8")
            rc = cmd_apply(str(qp), str(lp), required)
            return rc, (qp.read_text(encoding="utf-8") if qp.exists() else "")

        rc, out = run(qa_pass, lane_fail)
        check(rc == OVERRIDDEN_EXIT, "A: QA PASS + lane FAIL -> overridden (exit 3)")
        check(not verdicts.check_verdict_file(str(dp / "qa.md")), "A: verdicts.py now reads the QA report as failing")
        check(out.count("**Verdict:** FAIL") == 1, "A: exactly one FAIL verdict line")
        check(out.index("**Verdict:** FAIL") < out.index("## Browser Checks"),
              "A: the FAIL verdict takes the agent's top verdict position")
        check(f"{AGENT_VERDICT_LABEL} PASS_WITH_NOTES" in out, "A: a second passing line is neutralised too")
        check("UT-J-06: FAIL" in out and "UT-J-09: SKIP" in out and "UT-J-01" not in out.split(SECTION_HEADING)[1],
              "A: section lists every non-PASS row and no PASS row")
        check("All good." in out, "A: agent prose preserved")
        rc2, out2 = run(out, lane_fail)
        check(rc2 == 0 and out2 == out, "A: re-apply is a no-op (idempotent)")

        rc, out = run(qa_pass, lane_pass)
        check(rc == 0 and out == qa_pass, "B: lane PASS -> QA report byte-identical")

        rc, out = run(qa_pass, lane_skipped)
        check(rc == OVERRIDDEN_EXIT and "`Browser QA Verdict: SKIPPED`" in out, "C: lane SKIPPED -> overridden")

        rc, out = run(qa_pass, None)
        check(rc == OVERRIDDEN_EXIT and "no results file" in out, "D: lane file missing -> overridden (fail closed)")

        rc, out = run(qa_pass, "# results\n\nno headline here\n")
        check(rc == OVERRIDDEN_EXIT and "no parseable" in out, "E: unparseable lane -> overridden (fail closed)")

        rc, out = run(qa_pass, lane_pass_headline_fail_row)
        check(rc == OVERRIDDEN_EXIT and "UT-J-02: FAIL" in out, "F: a FAIL row outranks a PASS headline")

        rc, out = run(qa_pass, lane_fail, required="no")
        check(rc == 0 and out == qa_pass, "G: lane not required (backend-only / isolation) -> untouched")

        qa_fail = "# QA\n\n**Verdict:** FAIL\n\nTests failed.\n"
        rc, out = run(qa_fail, lane_fail)
        check(rc == 0 and out == qa_fail, "H: agent FAIL verdict -> untouched (normal fix loop owns it)")

        rc, out = run(None, lane_fail)
        check(rc == 0 and not (dp / "qa.md").exists(), "I: no QA report -> nothing written")

        mixed = "# QA\n\n**Verdict:** FAIL\n\nlater:\n**Verdict:** PASS\n"
        rc, out = run(mixed, lane_fail)
        check(rc == OVERRIDDEN_EXIT and out.count("**Verdict:** FAIL") == 1
              and not verdicts.check_verdict_file(str(dp / "qa.md")),
              "J: existing FAIL line kept; stray PASS line neutralised, no second FAIL line")

        check(cmd_apply(str(dp / "qa.md"), str(dp / "lane.md"), "maybe") == 2, "K: bad --lane-required -> usage error")

    print(f"qa_lane_gate self-test: {'OK' if not failures else f'{len(failures)} FAILED'}")
    return 0 if not failures else 1


def main(argv: "list[str]") -> int:
    if argv[:1] == ["self-test"]:
        return _self_test()
    if len(argv) == 5 and argv[0] == "apply" and argv[3] == "--lane-required":
        return cmd_apply(argv[1], argv[2], argv[4])
    print(__doc__.split("Usage:")[1].strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
