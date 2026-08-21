#!/usr/bin/env python3
"""closure_gate.py — deterministic phase-closure gate (SPEED-17).

Replaces the phase-closure-auditor LLM dispatch for the default path. The
agent's Steps 1-4 were re-reads and existence/count/cross-consistency checks
over artifacts that already gated the pipeline upstream — no new judgment —
so they are mechanized here. The agent stays on disk as the escape hatch:
`CHAIN_CLOSURE_LLM=true` makes phase-closure-check.sh dispatch it instead.

Checks (mirroring agents/phase-closure-auditor/body.md Steps 1-4 and
.claude/skills/phase-closure-gate.md):
  1. Pipeline gate verdicts — review / QA / audit reports must exist and carry
     a passing verdict (same parser the pipeline itself uses: lib/verdicts.py).
     FAIL or absent => CLOSURE-FAIL naming the report (they already gated
     upstream; absence here means the pipeline is inconsistent).
  2. UI artifact existence (all 6, both branches) and, when the plan says
     `Frontend Present: yes`, content checks: >5 content lines, no N/A stubs,
     no placeholder markers, what-to-click has >=3 numbered non-vague steps,
     ui-test-results not all-SKIPPED-without-a-documented-reason.
  3. Backend-only claim guard — port of common.sh check_backend_only_claim
     (user-visible-changes claims "no visible changes" while frontend files
     changed): blocking on a frontend phase, WARN on a backend-only one.
  4. Vagueness — only OBJECTIVE vagueness blocks (placeholder markers and the
     bare "Test the form"-class what-to-click steps). Anything subtler is a
     WARN line: upstream QA live-audits and the downstream evaluator
     evidence-walk cover subtle vagueness.

Writes reports/phase-<phase>-closure-verdict.md in the frozen format the
pipeline greps (`closure_verdict_passes` in lib/common.sh): the FIRST line is
`**Verdict:** CLOSURE-PASS` or `**Verdict:** CLOSURE-FAIL`.

Exit codes: 0 = CLOSURE-PASS, 1 = CLOSURE-FAIL (verdict file written in both
cases), 2 = usage/environment error (no verdict written).

Usage:
  closure_gate.py <phase-name> --repo-root <path>
  closure_gate.py self-test
"""
from __future__ import annotations

import datetime
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import goal_lint  # noqa: E402  (vague-term list — single source, NEED-3)
import verdicts  # noqa: E402  (same verdict parser the pipeline gates use)
from merge_ui_test_results import parse_rows, file_top_verdict  # noqa: E402

# The 6 UI visibility artifacts (agents/phase-closure-auditor/body.md Step 2).
UI_ARTIFACTS = [
    "implementation-summary",
    "user-visible-changes",
    "ui-surface-map",
    "ui-test-plan",
    "ui-test-results",
    "what-to-click",
]

# Objective placeholder markers (skill "Vagueness Detection" + SPEED-17 list).
# Marker TOKENS are case-sensitive: `TODO`/`FIXME`/`TBD`/`FILL IN` are how a
# writer flags unfinished work; "todo"/"Todo" in prose is product vocabulary
# (a todo app tripped the gate on every artifact — G8 stage 1, 2026-08-21).
# The free-text placeholders stay case-insensitive.
_PLACEHOLDER_RE_TOKENS = re.compile(r"\bTODO\b|\bFIXME\b|\bTBD\b|\bFILL IN\b")
_PLACEHOLDER_RE_TEXT = re.compile(r"<fill|\blorem\b|\bxxx+\b", re.IGNORECASE)

# Maintenance isolation, as the engine declares it. Same shape as the bash
# marker regex (goal_maintenance_isolation_required, lib/common.sh): optional
# list dash, optional bold, tolerant of `- **Maintenance isolation:** required`.
_ISOLATION_MARKER_RE = re.compile(
    r"^[ \t]*-?[ \t]*(?:\*\*)?maintenance[ -]isolation:?(?:\*\*)?[ \t]*:?[ \t]*(?:\*\*)?required",
    re.IGNORECASE | re.MULTILINE,
)
# Deliberately the SAME literal set the bash predicate accepts — not a
# case-insensitive superset. A value bash reads as "not isolated" (e.g. "True")
# must not make this gate the more lenient of the two.
_ISOLATION_ENV_TRUTHY = frozenset({"true", "TRUE", "1", "yes", "on", "required"})

# N/A-stub / backend-only claim markers — the same set check_backend_only_claim
# greps (lib/common.sh) so both layers agree on what a backend-only claim is.
_BACKEND_CLAIM_RE = re.compile(
    r"backend-only|no user-visible|no visible changes|frontend present:\s*no",
    re.IGNORECASE,
)

# Frontend file patterns — mirror of detect_frontend_changes (lib/common.sh).
_FRONTEND_FILE_RE = re.compile(
    r"(\.tsx$|\.jsx$|\.vue$|\.svelte$|/components/|/pages/|/views/|/screens/"
    r"|\.module\.css$|\.module\.scss$)"
)

_NUMBERED_STEP_RE = re.compile(r"^\s*\d+[.)]")

# A step is "objectively vague" only when it is a bare generic-verb +
# generic-object phrase ("Test the form", "Verify it works", "Check the page
# loads properly"). Steps that merely CONTAIN a vague term but also carry
# specifics stay WARN — see the module docstring, point 4.
_GENERIC_STEP_RE = re.compile(
    r"^(?:please\s+)?(?:test|verify|check|try|open|click|use|run|ensure|confirm)\s+"
    r"(?:that\s+)?(?:the\s+|a\s+|an\s+)?"
    r"(?:forms?|pages?|apps?|applications?|buttons?|ui|sites?|websites?|"
    r"features?|it|everything|stuff|things?|works?)"
    r"(?:\s+(?:works?|loads?|functions?|renders?))?"
    r"(?:\s+(?:well|properly|correctly|fine|as\s+expected))?\s*[.!]?$",
    re.IGNORECASE,
)

# Tokens that make a step concrete enough to be beyond this gate's reach.
_SPECIFIC_TOKEN_RE = re.compile(r"[\d\"'`/=$#§→]|->|https?:|expect", re.IGNORECASE)

# A documented reason for an all-SKIPPED browser-QA file. Accepts the house
# conventions: a `**Reason:**` line, a `## Reason` section, or the browser-infra
# taxonomy strings bqa_results_infra_reason greps (lib/replay-lane.sh).
_REASON_LINE_RE = re.compile(r"\*\*Reason:\*\*\s*(\S.*)$", re.MULTILINE)
_REASON_SECTION_RE = re.compile(r"^##\s+Reason\s*\n+(\S.*)$", re.MULTILINE)
_INFRA_REASON_RE = re.compile(
    r"(browser infrastructure failure|chrome (?:mcp )?did not become ready"
    r"|chrome (?:mcp )?(?:not |un)available|frontend (?:is )?not (?:running|available)"
    r"|frontend not running)[^|\n]*",
    re.IGNORECASE,
)


# ── pure helpers ──────────────────────────────────────────────────────────────

def content_lines(text: str) -> int:
    """Count content lines: non-blank, not a markdown header, not a bare
    horizontal rule, not an HTML comment line."""
    n = 0
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#") or s.startswith("<!--") or set(s) <= {"-"}:
            continue
        n += 1
    return n


def maintenance_isolation_active(plan_text: str = "") -> bool:
    """True when this phase/iteration declared maintenance isolation.

    Read the two ways the feature propagates: the environment variable
    run-goal.sh / run-phase.sh export once the spec is resolved
    (apply_maintenance_isolation_from_spec), and the marker line itself for a
    consumer that never inherited that environment — a hand re-run of closure,
    say. The spec regex is NOT re-implemented against the spec file: this reads
    the plan text the gate already has.
    """
    if os.environ.get("CHAIN_MAINTENANCE_ISOLATION", "") in _ISOLATION_ENV_TRUTHY:
        return True
    return bool(plan_text) and bool(_ISOLATION_MARKER_RE.search(plan_text))


def frontend_present(plan_text: str) -> bool:
    """Mirror of detect_frontend_in_plan (lib/common.sh), including the
    maintenance-isolation carve-out: isolation withholds browser execution, so
    every UI artifact is legitimately an N/A stub and the frontend branch must
    not demand real content for a lane the contract forbade. The bash function's
    OTHER branch — the CHAIN_GOAL_TARGET_JOURNEYS override — is deliberately not
    mirrored: it only ever ADDS the browser lane, and this gate reads artifacts
    that the lane either produced or did not.
    """
    if maintenance_isolation_active(plan_text):
        return False
    if re.search(r"frontend present:\s*yes", plan_text, re.IGNORECASE):
        return True
    return bool(re.search(r"frontend present\s*\n\s*yes", plan_text, re.IGNORECASE))


def numbered_steps(text: str) -> list[str]:
    return [ln for ln in text.splitlines() if _NUMBERED_STEP_RE.match(ln)]


def step_text(line: str) -> str:
    """Strip the leading number and markdown emphasis from a step line."""
    s = re.sub(r"^\s*\d+[.)]\s*", "", line).strip()
    return s.strip("*_ ").strip()


def classify_step(line: str) -> str:
    """'blocking' | 'warn' | 'ok' for one numbered what-to-click step."""
    s = step_text(line)
    if _GENERIC_STEP_RE.match(s):
        return "blocking"
    if goal_lint._VAGUE_RE.search(s) and not _SPECIFIC_TOKEN_RE.search(s):
        return "blocking"
    if goal_lint._VAGUE_RE.search(s):
        return "warn"
    return "ok"


def all_skipped(results_text: str) -> bool:
    """True when the ui-test-results file shows no PASS/FAIL execution at all."""
    rows = parse_rows(results_text)
    row_verdicts = [r["verdict"] for r in rows if r["verdict"]]
    if row_verdicts:
        return not any(v in ("PASS", "FAIL") for v in row_verdicts)
    return file_top_verdict(results_text) == "SKIPPED"


def skip_reason(results_text: str) -> str | None:
    """Extract a documented reason for an all-SKIPPED run, if any."""
    m = _REASON_LINE_RE.search(results_text)
    if m:
        return m.group(1).strip()
    m = _REASON_SECTION_RE.search(results_text)
    if m:
        return m.group(1).strip()
    m = _INFRA_REASON_RE.search(results_text)
    if m:
        return m.group(0).strip()
    return None


def placeholder_hits(text: str) -> list[str]:
    """Placeholder markers on non-comment lines, as 'marker (line N)' strings."""
    hits: list[str] = []
    for i, line in enumerate(text.splitlines(), 1):
        if line.strip().startswith("<!--"):
            continue
        for rx in (_PLACEHOLDER_RE_TOKENS, _PLACEHOLDER_RE_TEXT):
            for m in rx.finditer(line):
                hits.append(f"{m.group(0)} (line {i})")
    return hits


def frontend_files_changed(repo_root: Path, phase: str) -> bool:
    """Port of detect_frontend_changes: status.json changed_files first,
    git diff fallback. Errors conservatively mean 'no frontend change'."""
    status_file = repo_root / "runs" / phase / "status.json"
    if status_file.is_file():
        try:
            changed = json.loads(status_file.read_text(encoding="utf-8")).get(
                "changed_files", []
            )
        except (json.JSONDecodeError, OSError):
            changed = []
        if changed:
            return any(_FRONTEND_FILE_RE.search(f) for f in changed)
    try:
        out = subprocess.run(
            ["git", "-C", str(repo_root), "diff", "--name-only", "HEAD"],
            capture_output=True, text=True, timeout=30, check=False,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return any(_FRONTEND_FILE_RE.search(f) for f in out.splitlines())


# ── the gate ──────────────────────────────────────────────────────────────────

class GateResult:
    def __init__(self) -> None:
        self.blocking: list[tuple[str, str]] = []  # (issue, remediation)
        self.warns: list[str] = []
        self.gate_rows: list[tuple[str, str, str]] = []   # (artifact, status, verdict)
        self.ui_rows: list[tuple[str, str, str, str, str]] = []
        self.crossref: list[str] = []

    @property
    def verdict(self) -> str:
        return "CLOSURE-FAIL" if self.blocking else "CLOSURE-PASS"


def _read(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return None


def run_gate(phase: str, repo_root: Path) -> GateResult:
    r = GateResult()
    reports = repo_root / "reports"

    # ── Step 1: pipeline gate verdicts (already gated upstream) ──────────────
    gates = [
        ("Review report", repo_root / "reports" / "reviews" / f"{phase}-review.md"),
        ("QA report", repo_root / "reports" / "qa" / f"{phase}-qa.md"),
        ("Audit report", repo_root / "docs" / "handoffs" / f"{phase}-audit.md"),
    ]
    for label, path in gates:
        rel = path.relative_to(repo_root)
        if not path.is_file():
            r.gate_rows.append((f"{label} (`{rel}`)", "missing", "FAIL"))
            r.blocking.append((
                f"{label} missing: `{rel}`",
                "Pipeline gates not passed — complete the upstream pipeline "
                f"stage that writes `{rel}` before re-running closure.",
            ))
        elif not verdicts.check_verdict_file(str(path)):
            r.gate_rows.append((f"{label} (`{rel}`)", "exists", "FAIL"))
            r.blocking.append((
                f"{label} does not carry a passing verdict: `{rel}`",
                "Pipeline gates not passed — this report already gated the "
                "pipeline upstream; a non-passing verdict here means the "
                "pipeline is inconsistent. Re-run the failing stage.",
            ))
        else:
            r.gate_rows.append((f"{label} (`{rel}`)", "exists", "PASS"))

    # ── Frontend Present branch ──────────────────────────────────────────────
    plan_path = repo_root / "runs" / phase / "plan.md"
    plan_text = _read(plan_path)
    if plan_text is None:
        r.blocking.append((
            f"Execution plan missing: `runs/{phase}/plan.md`",
            f"Run `./scripts/automation/run-phase.sh {phase}` so the "
            "orchestrator writes the plan (it carries `Frontend Present:`).",
        ))
        is_frontend = False
    else:
        is_frontend = frontend_present(plan_text)
    r.crossref.append(
        f"Frontend Present: {'yes' if is_frontend else 'no'}"
        + ("" if plan_text is not None else " (plan missing — defaulted)")
    )

    # ── Step 2: UI artifact existence + content ──────────────────────────────
    artifact_texts: dict[str, str | None] = {}
    for name in UI_ARTIFACTS:
        path = reports / f"phase-{phase}-{name}.md"
        text = _read(path)
        artifact_texts[name] = text
        fname = f"{name}.md"
        if text is None:
            r.ui_rows.append((fname, "no", "-", "-", "MISSING"))
            r.blocking.append((
                f"UI artifact missing: `reports/phase-{phase}-{name}.md`",
                "Re-run the pipeline step that writes it (ui-impact / "
                "ui-test-design / browser-qa), or for a backend-only phase "
                "let run-phase.sh write the N/A stubs (write_na_ui_artifacts).",
            ))
            continue
        if not is_frontend:
            # N/A stubs acceptable — existence is the whole requirement.
            r.ui_rows.append((fname, "yes", "n/a (stub ok)", "n/a", "OK"))
            continue

        lines = content_lines(text)
        nonempty = lines > 5
        stub = bool(_BACKEND_CLAIM_RE.search(text)) and lines <= 5
        holders = placeholder_hits(text)
        status = "OK"
        if stub:
            status = "VAGUE"
            r.blocking.append((
                f"`phase-{phase}-{name}.md` is an N/A/backend-only stub but the "
                "plan says Frontend Present: yes",
                "Regenerate the artifact with real content for this frontend "
                "phase (re-run the producing pipeline step).",
            ))
        elif not nonempty:
            status = "VAGUE"
            r.blocking.append((
                f"`phase-{phase}-{name}.md` has ≤5 content lines "
                f"({lines} non-blank, non-header) for a frontend phase",
                "Regenerate the artifact with real content (re-run the "
                "producing pipeline step).",
            ))
        if holders:
            status = "VAGUE"
            shown = ", ".join(holders[:3])
            r.blocking.append((
                f"`phase-{phase}-{name}.md` contains placeholder markers: {shown}",
                "Replace placeholders with real content and re-run closure.",
            ))
        r.ui_rows.append((
            fname, "yes", "yes" if nonempty else "no",
            "no" if (holders or stub) else "yes", status,
        ))

    # ── Steps 3-4: cross-reference checks (frontend phases only) ─────────────
    if is_frontend:
        _crossref_frontend(phase, repo_root, artifact_texts, r)
    else:
        r.crossref.append(
            "Backend-only phase: N/A stubs accepted; cross-reference checks "
            "not applicable."
        )
        # Backend-only claim guard still worth a WARN if frontend files moved.
        if frontend_files_changed(repo_root, phase):
            r.warns.append(
                "Plan says Frontend Present: no but frontend-looking files "
                "changed this phase — check the plan flag (WARN only: the "
                "evaluator evidence-walk covers this)."
            )

    # ── UX regression report (optional; FAIL already gated by run-phase.sh) ──
    ux_path = reports / f"phase-{phase}-ux-regression.md"
    ux_text = _read(ux_path)
    if ux_text is None:
        r.crossref.append("UX regression report: not present (acceptable).")
    elif re.search(r"^\*\*Verdict:\*\* UX-REGRESSION-FAIL", ux_text, re.MULTILINE):
        r.blocking.append((
            f"UX regression report is UX-REGRESSION-FAIL: `reports/phase-{phase}-ux-regression.md`",
            "This verdict already gates the pipeline (run-phase.sh) — a FAIL "
            "surviving to closure means the pipeline is inconsistent. Fix the "
            "flagged regressions and re-run ux-regression-phase.sh.",
        ))
        r.crossref.append("UX regression report: FAIL (blocking).")
    elif re.search(r"^\*\*Verdict:\*\* UX-REGRESSION-WARN", ux_text, re.MULTILINE):
        r.warns.append("UX regression report carries UX-REGRESSION-WARN (non-blocking).")
        r.crossref.append("UX regression report: WARN (non-blocking).")
    else:
        r.crossref.append("UX regression report: present, not FAIL.")

    return r


def _crossref_frontend(
    phase: str, repo_root: Path, texts: dict[str, str | None], r: GateResult
) -> None:
    # what-to-click: >=3 numbered steps, none objectively vague.
    wtc = texts.get("what-to-click")
    if wtc is not None:
        steps = numbered_steps(wtc)
        if len(steps) < 3:
            r.blocking.append((
                f"`phase-{phase}-what-to-click.md` has {len(steps)} numbered "
                "step(s); ≥3 required",
                "Re-run ui-test-design-phase.sh so the operator guide has at "
                "least 3 concrete numbered steps with expected outcomes.",
            ))
        r.crossref.append(f"what-to-click numbered steps: {len(steps)} (≥3 required)")
        vague_block = [step_text(s) for s in steps if classify_step(s) == "blocking"]
        vague_warn = [step_text(s) for s in steps if classify_step(s) == "warn"]
        if vague_block:
            shown = "; ".join(f'"{s}"' for s in vague_block[:3])
            r.blocking.append((
                f"`phase-{phase}-what-to-click.md` has objectively vague "
                f"step(s): {shown}",
                "Rewrite each step with an exact action and exact expected "
                "outcome (see templates/what-to-click.md), then re-run closure.",
            ))
        for s in vague_warn:
            r.warns.append(
                f'what-to-click step uses a vague term but carries specifics: "{s}" '
                "(WARN only — QA live-audit / evaluator evidence-walk cover this)."
            )

    # ui-test-results: all-SKIPPED needs a documented reason.
    results = texts.get("ui-test-results")
    if results is not None:
        if all_skipped(results):
            reason = skip_reason(results)
            if reason:
                r.warns.append(
                    "ui-test-results is all-SKIPPED with a documented reason "
                    f'("{reason}") — pass-with-warn per the closure-gate skill; '
                    "verify browser QA was reasonable to skip for this phase."
                )
                r.crossref.append("ui-test-results: all SKIPPED, reason documented (WARN).")
            else:
                r.blocking.append((
                    f"`phase-{phase}-ui-test-results.md` shows no executed browser "
                    "tests (all SKIPPED) and no documented reason",
                    "Run browser-qa-phase.sh with the frontend running, or "
                    "document explicitly (a `**Reason:**` line) why browser "
                    "validation was not required for this phase.",
                ))
                r.crossref.append("ui-test-results: all SKIPPED, NO reason (blocking).")
        else:
            r.crossref.append("ui-test-results: execution evidence present (PASS/FAIL rows).")

    # ui-surface-map: at least one table row is the convention — WARN only
    # (bullet-style maps are legitimate; this is the subtle zone).
    smap = texts.get("ui-surface-map")
    if smap is not None:
        data_rows = [
            ln for ln in smap.splitlines()
            if ln.strip().startswith("|") and not set(ln.strip()) <= {"|", "-", ":", " "}
        ]
        if len(data_rows) <= 1:  # header row only, or none
            r.warns.append(
                "ui-surface-map has no table rows naming routes/components "
                "(WARN only — format may legitimately vary)."
            )

    # Backend-only claim guard (port of check_backend_only_claim, blocking here
    # because Frontend Present: yes — body.md Step 4).
    uvc = texts.get("user-visible-changes")
    if uvc is not None and _BACKEND_CLAIM_RE.search(uvc):
        if frontend_files_changed(repo_root, phase):
            r.blocking.append((
                "user-visible-changes claims no visible changes but frontend "
                "files were modified",
                "Reconcile: either document the user-visible changes "
                "(re-run ui-impact-phase.sh) or correct the change set.",
            ))
            r.crossref.append("backend-only claim guard: INCONSISTENT (blocking).")
        else:
            r.warns.append(
                "user-visible-changes uses backend-only language on a frontend "
                "phase, but no frontend file changes were detected (WARN)."
            )
    else:
        r.crossref.append("backend-only claim guard: consistent.")


# ── report rendering (frozen format — closure_verdict_passes greps line 1) ───

def render_report(phase: str, r: GateResult) -> str:
    today = datetime.date.today().isoformat()
    out: list[str] = []
    out.append(f"**Verdict:** {r.verdict}")
    out.append("")
    out.append(f"# Phase {phase} — Closure Verdict")
    out.append("")
    out.append(f"**Phase:** {phase}")
    out.append(f"**Date:** {today}")
    out.append("**Written by:** closure_gate.py (deterministic gate, SPEED-17)")
    out.append("")
    out.append("---")
    out.append("")
    out.append("## Standard Pipeline Gate Checks")
    out.append("")
    out.append("| Artifact | Status | Verdict |")
    out.append("|----------|--------|---------|")
    for artifact, status, verdict in r.gate_rows:
        out.append(f"| {artifact} | {status} | {verdict} |")
    out.append("")
    out.append("## UI Visibility Artifact Checks")
    out.append("")
    out.append("| Artifact | Exists | Non-Empty | Non-Vague | Status |")
    out.append("|----------|--------|-----------|-----------|--------|")
    for row in r.ui_rows:
        out.append("| " + " | ".join(row) + " |")
    out.append("")
    out.append("## Cross-Reference Checks")
    out.append("")
    for line in r.crossref:
        out.append(f"- {line}")
    out.append("")
    out.append("## Blocking Issues")
    out.append("")
    if r.blocking:
        for i, (issue, remediation) in enumerate(r.blocking, 1):
            out.append(f"{i}. **{issue}**")
            out.append(f"   **Remediation**: {remediation}")
    else:
        out.append("None")
    out.append("")
    out.append("## Non-Blocking Notes")
    out.append("")
    if r.warns:
        for w in r.warns:
            out.append(f"- WARN: {w}")
    else:
        out.append("- None")
    out.append("")
    out.append("---")
    out.append("")
    out.append(
        "Produced deterministically by `scripts/automation/lib/closure_gate.py` "
        "(no LLM dispatch). Escape hatch: set `CHAIN_CLOSURE_LLM=true` to "
        "restore the phase-closure-auditor agent dispatch."
    )
    out.append("")
    return "\n".join(out)


def main(argv: list[str]) -> int:
    if argv and argv[0] in ("self-test", "--self-test"):
        return _self_test()
    if not argv:
        sys.stderr.write(
            "usage: closure_gate.py <phase-name> --repo-root <path> | self-test\n"
        )
        return 2
    phase = argv[0]
    repo_root = Path.cwd()
    rest = argv[1:]
    while rest:
        if rest[0] == "--repo-root" and len(rest) > 1:
            repo_root = Path(rest[1])
            rest = rest[2:]
        else:
            sys.stderr.write(f"closure_gate.py: unknown argument {rest[0]!r}\n")
            return 2
    if not repo_root.is_dir():
        sys.stderr.write(f"closure_gate.py: repo root not a directory: {repo_root}\n")
        return 2

    result = run_gate(phase, repo_root)
    verdict_path = repo_root / "reports" / f"phase-{phase}-closure-verdict.md"
    verdict_path.parent.mkdir(parents=True, exist_ok=True)
    verdict_path.write_text(render_report(phase, result), encoding="utf-8")

    print(f"[closure_gate] {result.verdict} — verdict written to {verdict_path}")
    for issue, _ in result.blocking:
        print(f"[closure_gate]   BLOCKING: {issue}")
    for w in result.warns:
        print(f"[closure_gate]   WARN: {w}")
    return 0 if result.verdict == "CLOSURE-PASS" else 1


# ── self-test ────────────────────────────────────────────────────────────────

_RICH = "\n".join(f"- content line {i} with real substance" for i in range(1, 9))


def _write_fixture(root: Path, phase: str, frontend: str = "yes") -> None:
    (root / "runs" / phase).mkdir(parents=True, exist_ok=True)
    (root / "reports" / "reviews").mkdir(parents=True, exist_ok=True)
    (root / "reports" / "qa").mkdir(parents=True, exist_ok=True)
    (root / "docs" / "handoffs").mkdir(parents=True, exist_ok=True)
    (root / "runs" / phase / "plan.md").write_text(
        f"# Plan\n\nFrontend Present: {frontend}\n", encoding="utf-8"
    )
    (root / "reports" / "reviews" / f"{phase}-review.md").write_text(
        "**Verdict:** PASS\n", encoding="utf-8")
    (root / "reports" / "qa" / f"{phase}-qa.md").write_text(
        "**Verdict:** PASS\n", encoding="utf-8")
    (root / "docs" / "handoffs" / f"{phase}-audit.md").write_text(
        "**Verdict:** PASS_WITH_GAPS\n", encoding="utf-8")
    if frontend == "yes":
        for name in UI_ARTIFACTS:
            (root / "reports" / f"phase-{phase}-{name}.md").write_text(
                f"# Phase {phase} — {name}\n\n{_RICH}\n", encoding="utf-8")
        (root / "reports" / f"phase-{phase}-what-to-click.md").write_text(
            f"# What to Click\n\n{_RICH}\n\n"
            '1. Open `http://localhost:3000` — **Expect:** dashboard loads\n'
            '2. Click the "New Item" button — **Expect:** form modal opens\n'
            '3. Fill "Name" with "demo-1" and submit — **Expect:** row appears\n',
            encoding="utf-8")
        (root / "reports" / f"phase-{phase}-ui-test-results.md").write_text(
            "# UI Test Results\n\n**Browser QA Verdict:** PASS\n\n"
            "**Overall:** 1/1 tests passed (0 skipped)\n\n"
            "| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n"
            "|---|---|---|---|---|---|---|---|\n"
            "| UT-01 | Create item | smoke | P1 | row appears | row appeared | PASS | a.png |\n\n"
            "## Environment\n\n- Browser: Chromium\n- Test Date: today\n",
            encoding="utf-8")
    else:
        # Mirror write_na_ui_artifacts stubs (lib/common.sh).
        stubs = {
            "implementation-summary":
                "**Status:** Backend-only phase (Frontend Present: no)\n\n"
                "No UI-visible implementation. All changes are internal backend.\n",
            "user-visible-changes":
                "**Status:** N/A — Backend-only phase (Frontend Present: no)\n\n"
                "No user-visible changes. All changes are internal backend implementation.\n",
            "ui-surface-map":
                "**Status:** N/A — Backend-only phase (Frontend Present: no)\n\nNo UI surfaces affected.\n",
            "ui-test-plan":
                "**Status:** N/A — Backend-only phase. No UI tests required.\n",
            "ui-test-results":
                "**Browser QA Verdict:** SKIPPED\n\n"
                "**Reason:** Backend-only phase (Frontend Present: no). No browser tests executed.\n",
            "what-to-click":
                "**Status:** N/A — Backend-only phase. No UI verification steps.\n",
        }
        for name, body in stubs.items():
            (root / "reports" / f"phase-{phase}-{name}.md").write_text(
                f"# Phase {phase} — {name}\n\n{body}", encoding="utf-8")


def _self_test() -> int:
    import tempfile

    failures: list[str] = []

    def check(name: str, fn) -> None:
        try:
            fn()
        except Exception as exc:  # noqa: BLE001
            failures.append(f"{name}: {exc!r}")

    # ── pure-helper unit checks ──────────────────────────────────────────────
    def t_helpers():
        assert frontend_present("Frontend Present: yes")
        assert frontend_present("## Frontend Present\nyes")
        assert not frontend_present("Frontend Present: no")
        # maintenance isolation carve-out (env + plan marker), and its default OFF
        assert not maintenance_isolation_active("Frontend Present: yes")
        assert maintenance_isolation_active("- **Maintenance isolation:** required")
        assert maintenance_isolation_active("Maintenance-isolation: REQUIRED")
        assert not frontend_present(
            "Frontend Present: yes\n- **Maintenance isolation:** required\n"
        )
        _prev_env = os.environ.get("CHAIN_MAINTENANCE_ISOLATION")
        try:
            os.environ["CHAIN_MAINTENANCE_ISOLATION"] = "true"
            assert not frontend_present("Frontend Present: yes")
            os.environ["CHAIN_MAINTENANCE_ISOLATION"] = "False"
            assert frontend_present("Frontend Present: yes")  # not a bash-truthy value
        finally:
            if _prev_env is None:
                os.environ.pop("CHAIN_MAINTENANCE_ISOLATION", None)
            else:
                os.environ["CHAIN_MAINTENANCE_ISOLATION"] = _prev_env
        assert content_lines("# h\n\n---\n<!-- c -->\nreal\nreal2\n") == 2
        assert len(numbered_steps("1. a\n2) b\nx\n 3. c\n")) == 3
        assert classify_step("1. Test the form") == "blocking"
        assert classify_step("2. Verify it works properly") == "blocking"
        assert classify_step("3. Check the page") == "blocking"
        assert classify_step('4. Fill "Name" with "demo" — Expect: row appears') == "ok"
        assert classify_step("5. Verify the total updates correctly to $45") == "warn"
        assert placeholder_hits("real\nTODO: later\n") != []
        assert placeholder_hits("real\nFIXME: wire up\n") != []
        assert placeholder_hits("real\nTBD\n") != []
        assert placeholder_hits("real\n<fill in the route>\n") != []
        assert placeholder_hits("real\nLorem ipsum dolor\n") != []
        assert placeholder_hits("<!-- TBD template note -->\nreal\n") == []
        # Product vocabulary is not a marker (G8 stage 1: a todo app tripped the gate).
        assert placeholder_hits("Add a todo via the form\n") == []
        assert placeholder_hits("state is stored in todo.json\n") == []
        assert placeholder_hits("the heading 'Todo' is visible\n") == []
        assert placeholder_hits("shows the todos list\n") == []
        assert placeholder_hits("Fixme is a band name\n") == []

    def t_skip_detection():
        skipped = ("**Browser QA Verdict:** SKIPPED\n"
                   "| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n"
                   "|---|---|---|---|---|---|---|---|\n"
                   "| UT-01 | x | smoke | P1 | e | frontend not running | SKIP | none |\n")
        assert all_skipped(skipped)
        assert skip_reason(skipped)  # infra taxonomy string present
        bare = ("**Browser QA Verdict:** SKIPPED\n"
                "| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n"
                "|---|---|---|---|---|---|---|---|\n"
                "| UT-01 | x | smoke | P1 | e | - | SKIP | none |\n")
        assert all_skipped(bare) and skip_reason(bare) is None
        executed = ("| UT-01 | x | smoke | P1 | e | ok | PASS | a.png |\n")
        assert not all_skipped(executed)

    # ── end-to-end fixture checks ────────────────────────────────────────────
    def t_happy():
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            _write_fixture(root, "p1")
            r = run_gate("p1", root)
            assert r.verdict == "CLOSURE-PASS", (r.verdict, r.blocking)
            report = render_report("p1", r)
            assert report.splitlines()[0] == "**Verdict:** CLOSURE-PASS", report.splitlines()[0]

    def t_missing_artifact():
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            _write_fixture(root, "p1")
            (root / "reports" / "phase-p1-what-to-click.md").unlink()
            r = run_gate("p1", root)
            assert r.verdict == "CLOSURE-FAIL"
            assert any("what-to-click" in b[0] for b in r.blocking), r.blocking

    def t_failed_gate_verdict():
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            _write_fixture(root, "p1")
            (root / "reports" / "qa" / "p1-qa.md").write_text(
                "**Verdict:** FAIL\n", encoding="utf-8")
            r = run_gate("p1", root)
            assert r.verdict == "CLOSURE-FAIL"
            assert any("QA report" in b[0] for b in r.blocking), r.blocking

    def t_all_skipped_reason_nuance():
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            _write_fixture(root, "p1")
            rp = root / "reports" / "phase-p1-ui-test-results.md"
            rp.write_text(
                "# r\n\n**Browser QA Verdict:** SKIPPED\n\n**Reason:** frontend not "
                "running — single-service API project, browser QA not applicable.\n\n"
                + _RICH + "\n", encoding="utf-8")
            r = run_gate("p1", root)
            assert r.verdict == "CLOSURE-PASS", r.blocking
            assert any("all-SKIPPED" in w for w in r.warns), r.warns
            rp.write_text("# r\n\n**Browser QA Verdict:** SKIPPED\n\n" + _RICH + "\n",
                          encoding="utf-8")
            r = run_gate("p1", root)
            assert r.verdict == "CLOSURE-FAIL"
            assert any("no documented reason" in b[0] for b in r.blocking), r.blocking

    def t_backend_only_stubs_pass():
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            _write_fixture(root, "p1", frontend="no")
            r = run_gate("p1", root)
            assert r.verdict == "CLOSURE-PASS", r.blocking

    def t_vague_what_to_click():
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            _write_fixture(root, "p1")
            (root / "reports" / "phase-p1-what-to-click.md").write_text(
                "# What to Click\n\n" + _RICH +
                "\n\n1. Test the form\n2. Verify it works\n3. Check the page\n",
                encoding="utf-8")
            r = run_gate("p1", root)
            assert r.verdict == "CLOSURE-FAIL"
            assert any("vague" in b[0] for b in r.blocking), r.blocking

    def t_na_stub_on_frontend_phase():
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            _write_fixture(root, "p1")
            (root / "reports" / "phase-p1-user-visible-changes.md").write_text(
                "# Phase p1 — User-Visible Changes\n\n"
                "**Status:** N/A — Backend-only phase (Frontend Present: no)\n",
                encoding="utf-8")
            r = run_gate("p1", root)
            assert r.verdict == "CLOSURE-FAIL"
            assert any("stub" in b[0] for b in r.blocking), r.blocking

    tests = [
        ("helpers", t_helpers),
        ("skip_detection", t_skip_detection),
        ("happy_tree", t_happy),
        ("missing_artifact", t_missing_artifact),
        ("failed_gate_verdict", t_failed_gate_verdict),
        ("all_skipped_reason_nuance", t_all_skipped_reason_nuance),
        ("backend_only_stubs_pass", t_backend_only_stubs_pass),
        ("vague_what_to_click", t_vague_what_to_click),
        ("na_stub_on_frontend_phase", t_na_stub_on_frontend_phase),
    ]
    for name, fn in tests:
        check(name, fn)

    for f in failures:
        print(f"  FAIL {f}", file=sys.stderr)
    print(f"[closure_gate self-test] {len(tests) - len(failures)} passed, "
          f"{len(failures)} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
