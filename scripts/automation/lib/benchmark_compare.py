"""
benchmark_compare.py — EVO-3 slice (c): delta table + verdict between two
benchmark results JSONs written by scripts/automation/run-benchmark.sh.

Compares OLD (baseline) against NEW (candidate) over the metrics a framework
change is supposed to move, and renders one plain-text delta table:

    wall_seconds · est. cost (economics agents total
    gen_ai.usage.total_cost_usd) · total tokens in/out · journeys passing ·
    attempt-1 review FAILs · malformed verdicts · final status / last verdict
    (absolute old → new, plus % where meaningful)

Verdict rule (EVO-3, docs/improvement-roadmap.md):
    REGRESS   wall +>25% OR cost +>25% OR journeys-passing dropped
    OK        otherwise — requires all three of those inputs comparable
    UNKNOWN   any of those three inputs missing or the literal
              "unknown (<why>)" on either side: that metric is INCOMPARABLE
              and the tool refuses to guess a number to force a verdict.
              (A comparable metric that WOULD have regressed is still
              reported as a note — the signal is shown, never graded.)
Non-verdict rows (tokens, review FAILs, malformed verdicts, status strings)
may be unknown without affecting the verdict; they render as-is.

Exit codes: 0 OK · 3 REGRESS · 4 UNKNOWN · 2 usage error / unreadable input.

CLI:
    python3 benchmark_compare.py <old.json> <new.json>
    python3 benchmark_compare.py --self-test
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

REGRESS_PCT = 25.0  # wall/cost regress threshold: strictly greater than +25%

# (row label, extractor key, kind) — kind drives formatting and verdict role.
_NUMERIC_ROWS = (
    ("wall_seconds", "wall_seconds"),
    ("est_cost_usd", "cost"),
    ("tokens_in", "tokens_in"),
    ("tokens_out", "tokens_out"),
    ("journeys_passing", "journeys_passing"),
    ("attempt1_review_fails", "attempt1_review_fails"),
    ("malformed_verdicts", "malformed_verdicts"),
)
_STRING_ROWS = (
    ("final_status", "final_status"),
    ("last_verdict", "last_verdict"),
)
_VERDICT_INPUTS = ("wall_seconds", "cost", "journeys_passing")


def _is_unknown(v) -> bool:
    return v is None or (isinstance(v, str) and v.startswith("unknown ("))


def _numeric(v):
    """Return the value as a number, or None when it is not comparable."""
    if isinstance(v, bool) or _is_unknown(v):
        return None
    return v if isinstance(v, (int, float)) else None


def extract(results: dict) -> dict:
    """Flatten one results JSON into the compared metric set. Missing paths
    become the literal 'unknown (<why>)' — the same convention the runner
    itself uses — so the renderer and verdict logic see one shape."""
    meta = results.get("meta") or {}
    outcome = results.get("outcome") or {}
    economics = results.get("economics") or {}

    def out_key(key):
        return outcome[key] if key in outcome else f"unknown ({key} absent from outcome)"

    sid = meta.get("session_id")
    total = {}
    agents = economics.get("agents")
    if isinstance(agents, dict) and isinstance(agents.get(sid), dict):
        total = agents[sid].get("total") or {}

    def eco_key(key):
        v = total.get(key)
        return v if v is not None else f"unknown (economics agents total lacks {key})"

    return {
        "sha": meta.get("framework_sha", "unknown (meta.framework_sha absent)"),
        "date": meta.get("date_utc", "unknown (meta.date_utc absent)"),
        "wall_seconds": out_key("wall_seconds"),
        "cost": eco_key("gen_ai.usage.total_cost_usd"),
        "tokens_in": eco_key("gen_ai.usage.input_tokens"),
        "tokens_out": eco_key("gen_ai.usage.output_tokens"),
        "journeys_passing": out_key("journeys_passing_after"),
        "journeys_total": out_key("journeys_total"),
        "attempt1_review_fails": out_key("attempt1_review_fails"),
        "malformed_verdicts": out_key("malformed_verdicts"),
        "final_status": out_key("final_status"),
        "last_verdict": out_key("last_verdict"),
    }


def _fmt(v) -> str:
    if isinstance(v, float):
        return f"{v:.4f}".rstrip("0").rstrip(".")
    return str(v)


def _delta_cell(old, new) -> str:
    a, b = _numeric(old), _numeric(new)
    if a is None or b is None:
        return "incomparable"
    d = b - a
    cell = f"{d:+.4f}".rstrip("0").rstrip(".") if isinstance(d, float) else f"{d:+d}"
    if d and a > 0:
        cell += f" ({(d / a) * 100:+.1f}%)"
    return cell


def compare(old: dict, new: dict) -> tuple[str, list[str], list[str]]:
    """Verdict over two extract() dicts.
    Returns (verdict, reasons, notes): reasons explain the verdict; notes
    carry regress-worthy signals seen while the verdict is UNKNOWN."""
    unknown = []
    regress = []
    for key in _VERDICT_INPUTS:
        a, b = _numeric(old[key]), _numeric(new[key])
        if a is None or b is None:
            side = "old" if a is None else "new"
            unknown.append(f"{key} incomparable ({side}: {_fmt(old[key] if a is None else new[key])})")
            continue
        if key == "journeys_passing":
            if b < a:
                regress.append(f"journeys_passing dropped {_fmt(a)}→{_fmt(b)}")
        elif a > 0:
            pct = (b - a) / a * 100
            if pct > REGRESS_PCT:
                regress.append(f"{key} {pct:+.1f}% (>+{REGRESS_PCT:.0f}%)")
        elif b > a:  # old == 0, new > 0: % undefined — refuse to grade it
            unknown.append(f"{key} incomparable (old is 0, % undefined)")
    if unknown:
        notes = [f"would REGRESS on the comparable inputs: {'; '.join(regress)}"] if regress else []
        return "UNKNOWN", unknown, notes
    if regress:
        return "REGRESS", regress, []
    return "OK", ["no verdict input regressed"], []


def render(old: dict, new: dict, old_path: str, new_path: str) -> tuple[str, int]:
    """Full report text + exit code for one comparison."""
    lines = [
        f"[benchmark-compare] old: {old_path} (sha {str(old['sha'])[:12]} · {old['date']})",
        f"[benchmark-compare] new: {new_path} (sha {str(new['sha'])[:12]} · {new['date']})",
        "",
        f"{'metric':<22} {'old':>18} {'new':>18}  delta",
    ]
    for label, key in _NUMERIC_ROWS:
        o, n = old[key], new[key]
        if key == "journeys_passing":
            o = f"{_fmt(o)}/{_fmt(old['journeys_total'])}"
            n = f"{_fmt(n)}/{_fmt(new['journeys_total'])}"
        lines.append(f"{label:<22} {_fmt(o):>18} {_fmt(n):>18}  "
                     f"{_delta_cell(old[key], new[key])}")
    for label, key in _STRING_ROWS:
        arrow = f"{_fmt(old[key])} → {_fmt(new[key])}"
        if old[key] == new[key]:
            arrow += "  (unchanged)"
        lines.append(f"{label:<22} {arrow}")
    verdict, reasons, notes = compare(old, new)
    lines.append("")
    lines.append(f"verdict: {verdict} ({'; '.join(reasons)})")
    for note in notes:
        lines.append(f"note: {note}")
    code = {"OK": 0, "REGRESS": 3, "UNKNOWN": 4}[verdict]
    return "\n".join(lines), code


def run_compare(old_path: str, new_path: str) -> int:
    loaded = []
    for path in (old_path, new_path):
        try:
            loaded.append(json.loads(Path(path).read_text(encoding="utf-8")))
        except (OSError, ValueError) as e:
            print(f"[benchmark-compare] ERROR unreadable results JSON: {path}: {e}",
                  file=sys.stderr)
            return 2
        if not isinstance(loaded[-1], dict):
            print(f"[benchmark-compare] ERROR not a results object: {path}",
                  file=sys.stderr)
            return 2
    text, code = render(extract(loaded[0]), extract(loaded[1]), old_path, new_path)
    print(text)
    return code


# ── self-test ─────────────────────────────────────────────────────────────────

_BASE = {
    "meta": {"date_utc": "2026-07-10T00:00:00Z", "framework_sha": "a" * 40,
             "session_id": "bench-20260710-0000"},
    "outcome": {"engine_exit_code": 0, "final_status": "GOAL_ACHIEVED",
                "last_verdict": "GOAL_ACHIEVED", "iterations_used": 2,
                "journeys_passing_after": 3, "journeys_total": 3,
                "attempt1_review_fails": 1, "malformed_verdicts": 0,
                "wall_seconds": 9000},
    "economics": {"agents": {"bench-20260710-0000": {"total": {
        "gen_ai.usage.input_tokens": 140000,
        "gen_ai.usage.output_tokens": 70000,
        "gen_ai.usage.total_cost_usd": 3.20,
    }}}},
}


def _variant(**outcome_or_special) -> dict:
    """Deep-copied _BASE with outcome keys (or cost=/sid=) overridden."""
    r = json.loads(json.dumps(_BASE))
    for k, v in outcome_or_special.items():
        if k == "cost":
            r["economics"]["agents"][r["meta"]["session_id"]]["total"][
                "gen_ai.usage.total_cost_usd"] = v
        elif k == "no_agents":
            r["economics"]["agents"] = {}
        else:
            r["outcome"][k] = v
    return r


def _verdict(old: dict, new: dict) -> tuple[str, int]:
    text, code = render(extract(old), extract(new), "old.json", "new.json")
    v = next(l for l in text.splitlines() if l.startswith("verdict: "))
    return v.split()[1], code


def _self_test() -> int:
    import contextlib
    import io
    import tempfile

    # 0. identical pair (the baseline-vs-baseline sanity): all deltas 0 → OK 0
    text, code = render(extract(_BASE), extract(_BASE), "a.json", "b.json")
    assert code == 0 and "verdict: OK" in text, text
    for row in ("wall_seconds", "est_cost_usd", "tokens_in", "tokens_out",
                "journeys_passing", "attempt1_review_fails", "malformed_verdicts",
                "final_status", "last_verdict"):
        assert any(l.startswith(row) for l in text.splitlines()), f"row missing: {row}"
    data_rows = [l for l in text.splitlines()
                 if l.split() and l.split()[0] in dict(_NUMERIC_ROWS)]
    assert all(("+0" in l) or l.rstrip().endswith(" 0") or " 0 " in l for l in data_rows) \
        and "incomparable" not in text, f"identical pair must show zero deltas:\n{text}"
    assert "(unchanged)" in text

    # 1. wall +>25% → REGRESS 3; exactly +25% is NOT a regress (strictly greater)
    assert _verdict(_BASE, _variant(wall_seconds=11251)) == ("REGRESS", 3)
    assert _verdict(_BASE, _variant(wall_seconds=11250)) == ("OK", 0)
    # improvement direction never regresses
    assert _verdict(_BASE, _variant(wall_seconds=100)) == ("OK", 0)

    # 2. cost +>25% → REGRESS; +25% exactly → OK
    assert _verdict(_BASE, _variant(cost=4.01)) == ("REGRESS", 3)
    assert _verdict(_BASE, _variant(cost=4.00)) == ("OK", 0)

    # 3. journeys-passing dropped → REGRESS (any drop, no threshold)
    assert _verdict(_BASE, _variant(journeys_passing_after=2)) == ("REGRESS", 3)
    assert _verdict(_BASE, _variant(journeys_passing_after=4)) == ("OK", 0)

    # 4. literal unknown on a verdict input (either side) → UNKNOWN 4
    unk = "unknown (journey-history.json missing)"
    assert _verdict(_BASE, _variant(journeys_passing_after=unk)) == ("UNKNOWN", 4)
    assert _verdict(_variant(journeys_passing_after=unk), _BASE) == ("UNKNOWN", 4)
    assert _verdict(_BASE, _variant(wall_seconds="unknown (x)")) == ("UNKNOWN", 4)

    # 5. missing economics (no agents entry) → cost incomparable → UNKNOWN
    assert _verdict(_BASE, _variant(no_agents=True)) == ("UNKNOWN", 4)

    # 6. UNKNOWN outranks REGRESS, but the regress signal survives as a note
    both = _variant(wall_seconds=20000, journeys_passing_after=unk)
    text, code = render(extract(_BASE), extract(both), "o", "n")
    assert code == 4 and "verdict: UNKNOWN" in text
    assert "would REGRESS" in text and "wall_seconds" in text, text

    # 7. unknown on a NON-verdict row does not affect the verdict
    tokenless = _variant()
    del tokenless["economics"]["agents"][_BASE["meta"]["session_id"]]["total"][
        "gen_ai.usage.input_tokens"]
    assert _verdict(_BASE, tokenless) == ("OK", 0)

    # 8. old wall of 0 with a nonzero new: % undefined → UNKNOWN, never a guess
    assert _verdict(_variant(wall_seconds=0), _variant(wall_seconds=500)) == ("UNKNOWN", 4)
    assert _verdict(_variant(wall_seconds=0), _variant(wall_seconds=0)) == ("OK", 0)

    # 9. file-level: unreadable / non-JSON / non-object → 2; good pair round-trips
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)
        (d / "old.json").write_text(json.dumps(_BASE), encoding="utf-8")
        (d / "new.json").write_text(json.dumps(_variant(wall_seconds=11251)),
                                    encoding="utf-8")
        (d / "junk.json").write_text("not json", encoding="utf-8")
        (d / "list.json").write_text("[1,2]", encoding="utf-8")

        def _run(*argv) -> tuple[int, str, str]:
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                rc = main(list(argv))
            return rc, out.getvalue(), err.getvalue()

        rc, out, _ = _run(str(d / "old.json"), str(d / "new.json"))
        assert rc == 3 and "verdict: REGRESS" in out
        rc, _, err = _run(str(d / "missing.json"), str(d / "new.json"))
        assert rc == 2 and "unreadable" in err
        rc, _, err = _run(str(d / "junk.json"), str(d / "new.json"))
        assert rc == 2 and "unreadable" in err
        rc, _, err = _run(str(d / "list.json"), str(d / "new.json"))
        assert rc == 2 and "not a results object" in err

    # 10. usage errors → 2
    with contextlib.redirect_stderr(io.StringIO()):
        assert main([]) == 2
        assert main(["one.json"]) == 2
        assert main(["a", "b", "c"]) == 2

    print("self-test passed")
    return 0


def main(argv: list[str]) -> int:
    if argv and argv[0] == "--self-test":
        return _self_test()
    if len(argv) != 2 or argv[0] in ("-h", "--help"):
        print(__doc__, file=sys.stderr)
        return 2
    return run_compare(argv[0], argv[1])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
