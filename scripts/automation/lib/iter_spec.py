#!/usr/bin/env python3
"""iter_spec.py — deterministic probes over a goal-mode iteration spec
(docs/phases/goal-<sid>-iter-<N>.md).

HARD-1 ships exactly ONE probe (the smallest regression surface for the
highest-priority silent-loss fix; `metadata`, `lint` and any parser
consolidation are HARD-2 concerns):

    iter_spec.py has-implementation-work <spec>
        exit 0  the spec plans implementation work: >=1 concrete bullet under
                `## IN SCOPE` -> `### Backend*` / `### Frontend*` (header prefix
                match, case-insensitive), OR >=1 concrete bullet directly under
                `## IN SCOPE` before any `###` sub-heading (loose format)
        exit 1  provably none
        exit 2  unreadable file, or no `## IN SCOPE` heading (unparseable).
                Callers treat 2 as "has work": a parse failure must never be
                the reason developer + reviewer are skipped (fail closed).
        stdout  JSON {"has_implementation_work": bool, "backend_bullets": n,
                      "frontend_bullets": n, "loose_bullets": n,
                      "in_scope_present": bool}

    iter_spec.py metadata <spec>
        exit 0 always (JSON on stdout) unless the file is unreadable (exit 2).
        The canonical deterministic read of the machine-readable spec fields:
        mode, depth, work_kind, full_trigger, frontend_present, target_journeys,
        required_journeys, plus `bold`/`present` maps recording, per field,
        whether it was found at all and whether it used the canonical bold form
        (`- **Depth:** lean`) or only the plain fallback (`Depth: lean`).

    iter_spec.py lint <spec> [--prior-verdict V] [--mode-expected baseline|next]
                             [--journey-history P] [--json-out P]
        exit 0  clean, or warnings only
        exit 1  at least one deterministic ERROR — the spec must not dispatch
        exit 2  unreadable spec (the caller fails closed; see run-goal.sh's
                CHAIN_SPEC_LINT block mode)
        stdout  one `[spec-lint] ERROR|WARN <rule>: <msg>` line per finding.

    iter_spec.py self-test

A "concrete bullet" is a `-` / `- [ ]` line whose text does not start with `<`
(a template placeholder) and does not match the filler regex — none / N/A /
nothing / "(none — ...)" / "No code changes" / "no work" / "no backend" ... .
DoD checkboxes, `TC-` lines, `Frontend Present:` and Data-contract prose
deliberately do NOT count: they describe verification, or are model-written
prose (anti-pattern 29), never construction.

Why a content probe: the evidence backstop in run-goal.sh used to decide "no
build work" from journey STATUS alone (evaluator-written) and never read the
spec body, so TenSteps policy-state-core-v1 iteration 7 — `Depth: lean`, every
target already passing, two concrete Backend bullets — was demoted to an
evidence-only dispatch and the fix silently never happened.
"""
from __future__ import annotations

import json
import re
import sys

_IN_SCOPE_RE = re.compile(r"^##\s+IN SCOPE\s*$(.*?)(?=^##\s|\Z)", re.S | re.M | re.I)
_H3_RE = re.compile(r"^###\s+(.*?)\s*$")
_H4PLUS_RE = re.compile(r"^#{4,}\s")
_BULLET_RE = re.compile(r"^\s*-\s+(?:\[.\]\s+)?(\S.*)$")
# Leading decoration a filler may carry: quotes, backticks, bold stars, an
# opening parenthesis/bracket ("- (none — the pages already render ...)").
# Fillers: none / N/A / nothing, and the "no [other|new|further|additional]
# [code|backend|frontend|product|file(s)] changes|work|items|edits|files" family
# ("No code changes", "No other backend file changes.", "No new files").
# A bullet starting with any other word is treated as concrete (fail closed
# toward "has work").
_NONE_RE = re.compile(
    r"""^[("'`*\[]*\s*(none|n/?a|nothing"""
    r"""|no\s+(?:(?:other|new|further|additional)\s+)?(?:(?:code|backend|frontend|product|files?)\s+)*"""
    r"""(?:changes?|work|items?|edits?|modifications?|backend|frontend|files?))\b""",
    re.I,
)


def _is_concrete_bullet(line: str) -> bool:
    m = _BULLET_RE.match(line)
    if not m:
        return False
    txt = m.group(1).strip()
    if txt.startswith("<"):
        return False
    return not _NONE_RE.match(txt)


def analyze(spec_text: str) -> dict:
    """Pure analysis of a spec's text. Never raises on odd content."""
    m = _IN_SCOPE_RE.search(spec_text)
    if not m:
        return {
            "has_implementation_work": False,
            "backend_bullets": 0,
            "frontend_bullets": 0,
            "loose_bullets": 0,
            "in_scope_present": False,
        }
    scope = m.group(1)
    backend = frontend = loose = 0
    current: str | None = None  # None = before the first ### (loose region)
    for line in scope.splitlines():
        h3 = _H3_RE.match(line)
        if h3:
            current = h3.group(1).strip().strip("*").strip().lower()
            continue
        if _H4PLUS_RE.match(line):
            continue  # deeper headings stay inside the current sub-section
        if not _is_concrete_bullet(line):
            continue
        if current is None:
            loose += 1
        elif current.startswith("backend"):
            backend += 1
        elif current.startswith("frontend"):
            frontend += 1
        # bullets under other sub-sections (capability / surface / contract
        # prose) never count — they are descriptions, not construction
    return {
        "has_implementation_work": (backend + frontend + loose) > 0,
        "backend_bullets": backend,
        "frontend_bullets": frontend,
        "loose_bullets": loose,
        "in_scope_present": True,
    }


def cmd_has_implementation_work(path: str) -> int:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:
        print(json.dumps({"error": f"unreadable: {exc}"}))
        return 2
    result = analyze(text)
    print(json.dumps(result, sort_keys=True))
    if not result["in_scope_present"]:
        return 2
    return 0 if result["has_implementation_work"] else 1


# ── HARD-2: canonical metadata read ──────────────────────────────────────────
# One deterministic parser for the machine-readable spec fields. Before HARD-2
# these were scattered greps in run-goal.sh, each with its own bold/plain policy
# (`Depth:` had a plain fallback, `Target journeys:` did not — so a plain-form
# target line parsed EMPTY and silently disarmed both the evidence backstop and
# the browser lane). The governed agent's prose is never consulted: only the
# declared fields and the IN SCOPE structure (anti-pattern 25).
_H2_LINE_RE = re.compile(r"^##\s+(.*?)\s*$", re.M)
_METADATA_H2 = "goal mode metadata"

# field key -> label as written in the spec
_FIELDS: dict[str, str] = {
    "session_id": "Session ID",
    "iteration": "Iteration",
    "mode": "Mode",
    "depth": "Depth",
    "full_trigger": "Full trigger",
    "target_journeys": "Target journeys",
    "required_journeys": "Required-still-passing journeys",
    "work_kind": "Work kind",
    "frontend_present": "Frontend Present",
}
# Fields whose canonical form the lint enforces (E02). Session ID / Iteration /
# Full trigger / Frontend Present are informational and are not bold-enforced.
_BOLD_ENFORCED = ("depth", "target_journeys", "required_journeys", "work_kind")

_VALID_DEPTH = ("lean", "full", "evidence")
_VALID_WORK_KIND = ("implementation", "evidence-only", "verify-only")
_VALID_MODE = ("baseline", "next")
_JOURNEY_ID_RE = re.compile(r"J-\d+")
# Operator-only lines the decomposer may never write but a RESUMED spec may
# legitimately carry — never a lint finding (plan WP2 "explicit non-rule").
_OPERATOR_ONLY = ("Depth enforcement", "Maintenance isolation")


def _field_patterns(label: str) -> tuple[re.Pattern[str], re.Pattern[str]]:
    esc = re.escape(label)
    bold = re.compile(rf"^[ \t]*-?[ \t]*\*\*{esc}:\*\*[ \t]*(.*?)[ \t]*$", re.M | re.I)
    plain = re.compile(rf"^[ \t]*-?[ \t]*{esc}:[ \t]*(.*?)[ \t]*$", re.M | re.I)
    return bold, plain


def read_metadata(spec_text: str) -> dict:
    """Deterministic read of the spec's machine fields. Never raises."""
    h2s = [m.group(1).strip() for m in _H2_LINE_RE.finditer(spec_text)]
    values: dict[str, str | None] = {}
    bold: dict[str, bool] = {}
    present: dict[str, bool] = {}
    for key, label in _FIELDS.items():
        b_re, p_re = _field_patterns(label)
        m = b_re.search(spec_text)
        if m:
            values[key], bold[key], present[key] = m.group(1).strip(), True, True
            continue
        m = p_re.search(spec_text)
        if m:
            values[key], bold[key], present[key] = m.group(1).strip(), False, True
        else:
            values[key], bold[key], present[key] = None, False, False

    def _norm(v: str | None) -> str | None:
        return v.strip().strip("*").strip().lower() if v else None

    scope = analyze(spec_text)
    if scope["has_implementation_work"]:
        derived = "implementation"
    elif scope["in_scope_present"]:
        derived = "evidence-only"
    else:
        derived = "verify-only"

    fp = _norm(values.get("frontend_present"))
    return {
        "metadata_section_present": any(h.lower() == _METADATA_H2 for h in h2s),
        "h2_sections": h2s,
        "mode": _norm(values.get("mode")),
        "depth": _norm(values.get("depth")),
        "work_kind": _norm(values.get("work_kind")),
        "full_trigger": values.get("full_trigger"),
        "frontend_present": (True if fp in ("yes", "true") else False if fp in ("no", "false") else None),
        "target_journeys": _JOURNEY_ID_RE.findall(values.get("target_journeys") or ""),
        "required_journeys": _JOURNEY_ID_RE.findall(values.get("required_journeys") or ""),
        "target_journeys_raw": values.get("target_journeys"),
        "bold": bold,
        "present": present,
        "in_scope": scope,
        "work_kind_derived": derived,
        "operator_lines": [n for n in _OPERATOR_ONLY if _field_patterns(n)[1].search(spec_text)],
    }


# ── HARD-2: deterministic lint ───────────────────────────────────────────────
# E-rules are contradictions: the spec cannot be dispatched as written. W-rules
# are advisory. The governor never GRANTS anything on a declared field alone —
# a field can only ever ADD a contradiction (anti-pattern 25).
_RULE_TEXT = {
    "E01": "metadata-missing",
    "E02": "field-not-bold",
    "E03": "depth-invalid",
    "E04": "targets-empty",
    "E05": "workkind-invalid",
    # E06 (policy-invalid) is RESERVED for HARD-3's `Side-effect policy` field.
    "E07": "evidence-with-implementation",
    "E08": "verify-only-with-implementation",
    "E09": "baseline-with-implementation",
    "E10": "evidence-after-escalate",
    "E11": "evidence-target-not-passing",
    "W01": "workkind-missing",
    # W02 (policy-missing) is RESERVED for HARD-3.
    "W03": "targets-line-absent",
    "W04": "lean-after-escalate",
    "W05": "contract-additions-without-bullets",
    "W06": "loose-in-scope-bullets",
    "W07": "sentinel-spec",
    "W08": "full-without-trigger",
}

_DATA_CONTRACT_RE = re.compile(r"^###\s+Data-contract additions\s*$(.*?)(?=^###\s|^##\s|\Z)", re.S | re.M | re.I)


def _passing_targets(history_path: str, targets: list[str]) -> list[str]:
    """Target ids NOT recorded passing. Empty list when history is unusable."""
    try:
        with open(history_path, encoding="utf-8") as fh:
            hist = json.load(fh)
    except Exception:
        return []
    journeys = hist.get("journeys") or {}
    bad = []
    for jid in targets:
        j = journeys.get(jid)
        if not isinstance(j, dict) or j.get("status") not in ("passing", "already_passing"):
            bad.append(jid)
    return bad


def lint_spec(
    spec_text: str,
    *,
    prior_verdict: str | None = None,
    mode_expected: str | None = None,
    journey_history: str | None = None,
) -> dict:
    """Pure lint. Returns {errors:[{rule,name,msg}], warnings:[...], metadata:{...}}."""
    md = read_metadata(spec_text)
    scope = md["in_scope"]
    errors: list[dict] = []
    warnings: list[dict] = []

    def err(rule: str, msg: str) -> None:
        errors.append({"rule": rule, "name": _RULE_TEXT[rule], "msg": msg})

    def warn(rule: str, msg: str) -> None:
        warnings.append({"rule": rule, "name": _RULE_TEXT[rule], "msg": msg})

    if not md["metadata_section_present"]:
        err("E01", "no '## Goal Mode Metadata' section — the engine cannot read this spec's machine fields")

    for key in _BOLD_ENFORCED:
        if md["present"].get(key) and not md["bold"].get(key):
            err("E02", f"'{_FIELDS[key]}:' is written in plain form; the canonical machine-readable "
                       f"form is bold: - **{_FIELDS[key]}:** <value>")

    if md["present"].get("depth") and md["depth"] not in _VALID_DEPTH:
        err("E03", f"Depth '{md['depth']}' is not one of {list(_VALID_DEPTH)}")

    if md["present"].get("target_journeys") and not md["target_journeys"]:
        err("E04", "'Target journeys:' is present but names no J-<n> id — the browser lane and the "
                   "evidence backstop would both read an empty target list")
    if not md["present"].get("target_journeys"):
        warn("W03", "no 'Target journeys:' line — the iteration names no journey to verify")

    if md["present"].get("work_kind") and md["work_kind"] not in _VALID_WORK_KIND:
        err("E05", f"Work kind '{md['work_kind']}' is not one of {list(_VALID_WORK_KIND)}")
    if not md["present"].get("work_kind"):
        warn("W01", f"no 'Work kind:' line; derived from IN SCOPE as '{md['work_kind_derived']}'")

    n = f"{scope['backend_bullets']} backend / {scope['frontend_bullets']} frontend / {scope['loose_bullets']} loose"
    # The three content-contradiction ERRORs key on STRUCTURED work — a bullet
    # explicitly under `### Backend` / `### Frontend`, which the decomposer
    # contract defines as a construction item. A LOOSE bullet directly under
    # `## IN SCOPE` is ambiguous prose ("- verify-only baseline"), and these
    # rules HALT a session, so an ambiguous signal must not trigger them: loose
    # bullets stay W06. HARD-1's probe still counts them, so the engine guard
    # still refuses an evidence dispatch for such a spec and runs it lean —
    # failing closed toward RUNNING the developer, never toward halting.
    structured_work = (scope["backend_bullets"] + scope["frontend_bullets"]) > 0
    if structured_work:
        if md["depth"] == "evidence" or md["work_kind"] == "evidence-only":
            which = "Depth: evidence" if md["depth"] == "evidence" else "Work kind: evidence-only"
            err("E07", f"{which} but IN SCOPE plans implementation work ({n} concrete bullet(s)) — "
                       "an evidence iteration dispatches no developer, so this work would never be built")
        if md["work_kind"] == "verify-only":
            err("E08", f"Work kind: verify-only but IN SCOPE plans implementation work ({n})")
        if md["mode"] == "baseline" or mode_expected == "baseline":
            err("E09", f"a baseline (iteration 0) spec is verify-only, but IN SCOPE plans implementation work ({n})")

    pv = (prior_verdict or "").strip().upper()
    if pv == "ESCALATE":
        if md["depth"] == "evidence":
            err("E10", "the prior verdict was ESCALATE, which requires the next iteration to run full; "
                       "this spec asks for evidence depth")
        elif md["depth"] == "lean":
            warn("W04", "the prior verdict was ESCALATE, which requires full; this spec asks for lean "
                        "(the engine promotes it — CHAIN_ESCALATE_FORCES_FULL)")

    if md["depth"] == "evidence" and journey_history and md["target_journeys"]:
        bad = _passing_targets(journey_history, md["target_journeys"])
        if bad:
            err("E11", f"Depth: evidence requires every target journey to be recorded passing; "
                       f"not passing: {', '.join(bad)}")

    dc = _DATA_CONTRACT_RE.search(spec_text)
    if dc and any(_is_concrete_bullet(ln) for ln in dc.group(1).splitlines()) \
            and not scope["has_implementation_work"]:
        warn("W05", "'Data-contract additions' lists contract changes but IN SCOPE has no concrete "
                    "Backend/Frontend bullet to build them")
    if scope["loose_bullets"]:
        warn("W06", f"{scope['loose_bullets']} bullet(s) sit directly under '## IN SCOPE' with no "
                    "### Backend/### Frontend sub-heading")
    if not scope["in_scope_present"]:
        warn("W07", "no '## IN SCOPE' section — treated as a sentinel spec (all remaining work human-blocked)")
    if md["depth"] == "full" and not md["present"].get("full_trigger"):
        warn("W08", "Depth: full without a 'Full trigger:' line naming which numbered trigger applies")

    return {"errors": errors, "warnings": warnings, "metadata": md,
            "work_kind_derived": md["work_kind_derived"]}


def _read_spec(path: str) -> str:
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def cmd_metadata(path: str) -> int:
    try:
        text = _read_spec(path)
    except OSError as exc:
        print(json.dumps({"error": f"unreadable: {exc}"}))
        return 2
    print(json.dumps(read_metadata(text), sort_keys=True))
    return 0


def cmd_lint(argv: list[str]) -> int:
    path = argv[0]
    opts: dict[str, str] = {}
    i = 1
    while i < len(argv) - 1:
        if argv[i] in ("--prior-verdict", "--mode-expected", "--journey-history", "--json-out"):
            opts[argv[i]] = argv[i + 1]
            i += 2
        else:
            i += 1
    try:
        text = _read_spec(path)
    except OSError as exc:
        print(f"[spec-lint] ERROR unreadable: cannot read {path}: {exc}", file=sys.stderr)
        return 2
    res = lint_spec(
        text,
        prior_verdict=opts.get("--prior-verdict"),
        mode_expected=opts.get("--mode-expected"),
        journey_history=opts.get("--journey-history"),
    )
    for f in res["errors"]:
        print(f"[spec-lint] ERROR {f['rule']} {f['name']}: {f['msg']}")
    for f in res["warnings"]:
        print(f"[spec-lint] WARN {f['rule']} {f['name']}: {f['msg']}")
    out = opts.get("--json-out")
    if out:
        try:
            with open(out, "w", encoding="utf-8") as fh:
                json.dump(res, fh, sort_keys=True, indent=2)
        except OSError as exc:
            print(f"[spec-lint] WARN json-out: could not write {out}: {exc}", file=sys.stderr)
    return 1 if res["errors"] else 0


# ── self-test ────────────────────────────────────────────────────────────────
_FIXTURES: dict[str, tuple[str, int, dict]] = {
    "two backend bullets (iter-7 shape)": (
        "## Goal Mode Metadata\n- **Depth:** lean\n## IN SCOPE\n### Backend\n"
        "- [ ] `versions.py::_pending_identity()`: replace the placeholder\n"
        "- [ ] `test_policy_versions.py`: remove the carve-out\n- [ ] No other backend file changes.\n"
        "### Frontend\n- (none — the pages already render what the backend serves)\n## OUT OF SCOPE\n- x\n",
        0, {"backend_bullets": 2, "frontend_bullets": 0},
    ),
    "none / N/A fillers (iter-9 shape)": (
        "## IN SCOPE\n### Backend\n- (none — no backend file is edited)\n### Frontend\n- N/A\n## OUT OF SCOPE\n- x\n",
        1, {"backend_bullets": 0},
    ),
    "placeholders and no-code fillers": (
        "## IN SCOPE\n### Backend\n- [ ] <specific change>\n- [ ] No code changes\n- Nothing\n### Frontend\n- none\n",
        1, {},
    ),
    "backend bullets only under OUT OF SCOPE": (
        "## IN SCOPE\n### Backend\n- none\n## OUT OF SCOPE\n### Backend\n- [ ] rewrite the engine\n",
        1, {},
    ),
    "loose bullet directly under IN SCOPE": (
        "## IN SCOPE\n- [ ] Fix versions.py so the stamp names the commit\n## OUT OF SCOPE\n- x\n",
        0, {"loose_bullets": 1},
    ),
    "frontend header variant": (
        "## IN SCOPE\n### Backend\n- none\n### Frontend (if applicable)\n- [ ] page.tsx: render the badge\n",
        0, {"frontend_bullets": 1},
    ),
    "descriptive sub-sections never count": (
        "## IN SCOPE\n### New user-facing capability\n- None new.\n### UI surface changes\n- the same three routes render the same fields\n",
        1, {},
    ),
    "no IN SCOPE heading": ("# Sentinel\n\nAll remaining work is human-blocked.\n", 2, {"in_scope_present": False}),
    "deeper heading stays inside Backend": (
        "## IN SCOPE\n### Backend\n#### Migration\n- [ ] add the column\n",
        0, {"backend_bullets": 1},
    ),
}


def _md(depth: str = "lean", work_kind: str = "", extra: str = "", mode: str = "next",
        targets: str = "J-01, J-02") -> str:
    """Build a metadata block. Every field stays INSIDE the metadata section —
    a `- **Work kind:** x` bullet appended after `## IN SCOPE` would land under
    `### Frontend` and be counted, correctly, as a concrete frontend bullet."""
    wk = f"- **Work kind:** {work_kind}\n" if work_kind else ""
    return ("## Goal Mode Metadata\n\n- **Session ID:** s\n- **Iteration:** 3\n"
            f"- **Mode:** {mode}\n- **Depth:** {depth}\n- **Target journeys:** {targets}\n"
            f"- **Required-still-passing journeys:** J-03\n{wk}{extra}")
_WORK = "\n## IN SCOPE\n### Backend\n- [ ] add the endpoint\n### Frontend\n- none\n"
_NOWORK = "\n## IN SCOPE\n### Backend\n- none\n### Frontend\n- N/A\n"

# (spec text, kwargs, expected rc, rule ids that MUST appear, rule ids that must NOT)
_LINT_FIXTURES: dict[str, tuple[str, dict, int, tuple[str, ...], tuple[str, ...]]] = {
    "clean lean spec with work": (
        _md("lean", "implementation") + _WORK, {}, 0, (), ("E07", "E02", "W01")),
    "E01 no metadata section": ("# spec\n\n- **Depth:** lean\n" + _WORK, {}, 1, ("E01",), ()),
    "E02 plain Depth line": (
        _md("lean").replace("- **Depth:** lean", "Depth: lean") + _WORK, {}, 1, ("E02",), ()),
    "E02 plain Target journeys line": (
        _md("lean").replace("- **Target journeys:** J-01, J-02", "Target journeys: J-01, J-02")
        + _WORK, {}, 1, ("E02",), ("W03", "E04")),
    "E03 invalid depth": (_md("deep") + _WORK, {}, 1, ("E03",), ()),
    "E04 targets line with no ids": (_md("lean", targets="TBD") + _WORK, {}, 1, ("E04",), ("W03",)),
    "E05 invalid work kind": (_md("lean", "whatever") + _WORK, {}, 1, ("E05",), ()),
    "E07 evidence depth with backend work": (_md("evidence") + _WORK, {}, 1, ("E07",), ()),
    "E07 evidence-only work kind with work": (_md("lean", "evidence-only") + _WORK, {}, 1, ("E07",), ()),
    "E08 verify-only with work": (_md("lean", "verify-only") + _WORK, {}, 1, ("E08",), ()),
    "E09 baseline mode with work": (_md("lean", mode="baseline") + _WORK, {}, 1, ("E09",), ()),
    "E09 baseline expected by the engine": (
        _md("lean") + _WORK, {"mode_expected": "baseline"}, 1, ("E09",), ()),
    "E10 evidence after ESCALATE": (
        _md("evidence", "evidence-only") + _NOWORK, {"prior_verdict": "ESCALATE"}, 1, ("E10",), ("E07",)),
    "W04 lean after ESCALATE is a warning only": (
        _md("lean", "implementation") + _WORK, {"prior_verdict": "ESCALATE"}, 0, ("W04",), ("E10",)),
    "genuine evidence spec is clean": (
        _md("evidence", "evidence-only") + _NOWORK, {}, 0, (), ("E07", "E10", "W01")),
    "W01 missing work kind derives from IN SCOPE": (_md("lean") + _WORK, {}, 0, ("W01",), ()),
    "W03 no target journeys line": (
        _md("lean", "implementation").replace("- **Target journeys:** J-01, J-02\n", "")
        + _WORK, {}, 0, ("W03",), ("E04",)),
    "W07 sentinel spec warns, never errors": (
        _md("lean") + "\nAll remaining work is human-blocked.\n", {}, 0, ("W07",), ()),
    "loose bullets never trigger the halting rules (E07/E08/E09)": (
        _md("evidence", "evidence-only", mode="baseline")
        + "\n## IN SCOPE\n- verify-only baseline (descriptive prose, not a construction item)\n",
        {"mode_expected": "baseline"}, 0, ("W06",), ("E07", "E08", "E09")),
    "structured Backend work still triggers E09 in baseline mode": (
        _md("lean", mode="baseline") + _WORK, {"mode_expected": "baseline"}, 1, ("E09",), ()),
    "W06 loose IN SCOPE bullets": (
        _md("lean", "implementation") + "\n## IN SCOPE\n- [ ] fix the thing\n", {}, 0, ("W06",), ()),
    "W08 full without a trigger": (_md("full", "implementation") + _WORK, {}, 0, ("W08",), ()),
    "full with a trigger does not warn": (
        _md("full", "implementation", "- **Full trigger:** 2 — coherence FAIL\n") + _WORK, {}, 0, (), ("W08",)),
    "operator-only lines are never a finding": (
        _md("full", "implementation", "- **Full trigger:** 1 — x\nDepth enforcement: required\n"
            "Maintenance isolation: required\n") + _WORK, {}, 0, (), ("E02", "E03", "W08")),
    "W05 contract additions with no bullets": (
        _md("lean", "evidence-only") + _NOWORK
        + "### Data-contract additions\n- [ ] `GET /api/x` returns `total`\n", {}, 0, ("W05",), ()),
    "E11 evidence target not recorded passing": (
        _md("evidence", "evidence-only") + _NOWORK, {"journey_history": "@HIST_BAD@"}, 1, ("E11",), ()),
    "E11 clean when every target passes": (
        _md("evidence", "evidence-only") + _NOWORK, {"journey_history": "@HIST_OK@"}, 0, (), ("E11",)),
}


def _lint_self_test() -> int:
    import tempfile
    fails = 0
    tmp = tempfile.mkdtemp(prefix="iter-spec-selftest-")
    hists = {
        "@HIST_OK@": {"journeys": {"J-01": {"status": "passing"}, "J-02": {"status": "already_passing"}}},
        "@HIST_BAD@": {"journeys": {"J-01": {"status": "passing"}, "J-02": {"status": "failing"}}},
    }
    for token, payload in hists.items():
        with open(f"{tmp}/{token.strip('@')}.json", "w", encoding="utf-8") as fh:
            json.dump(payload, fh)
    for name, (text, kwargs, want_rc, must, must_not) in _LINT_FIXTURES.items():
        kwargs = dict(kwargs)
        jh = kwargs.get("journey_history")
        if jh in hists:
            kwargs["journey_history"] = f"{tmp}/{jh.strip('@')}.json"
        res = lint_spec(text, **kwargs)
        got = {f["rule"] for f in res["errors"]} | {f["rule"] for f in res["warnings"]}
        rc = 1 if res["errors"] else 0
        ok = rc == want_rc and all(r in got for r in must) and not any(r in got for r in must_not)
        print(f"  {'PASS' if ok else 'FAIL'}  lint: {name} (rc={rc}, want {want_rc}; rules={sorted(got)})")
        fails += 0 if ok else 1
    # Reserved for HARD-3 — must not be emitted by HARD-2.
    for reserved in ("E06", "W02"):
        if reserved in _RULE_TEXT:
            print(f"  FAIL  lint: {reserved} is reserved for HARD-3 and must not be implemented here")
            fails += 1
    print(f"iter_spec lint self-test: {'OK' if fails == 0 else 'FAILED'} "
          f"({len(_LINT_FIXTURES) - fails}/{len(_LINT_FIXTURES)})")
    return 1 if fails else 0


def _self_test() -> int:
    fails = 0
    for name, (text, want_rc, want_fields) in _FIXTURES.items():
        res = analyze(text)
        rc = 2 if not res["in_scope_present"] else (0 if res["has_implementation_work"] else 1)
        ok = rc == want_rc and all(res.get(k) == v for k, v in want_fields.items())
        print(f"  {'PASS' if ok else 'FAIL'}  {name} (rc={rc}, want {want_rc}; {res})")
        fails += 0 if ok else 1
    print(f"iter_spec self-test: {'OK' if fails == 0 else 'FAILED'} ({len(_FIXTURES) - fails}/{len(_FIXTURES)})")
    return 1 if (fails or _lint_self_test()) else 0


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] == "has-implementation-work":
        return cmd_has_implementation_work(argv[1])
    if len(argv) >= 2 and argv[0] == "metadata":
        return cmd_metadata(argv[1])
    if len(argv) >= 2 and argv[0] == "lint":
        return cmd_lint(argv[1:])
    if argv and argv[0] == "self-test":
        return _self_test()
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
