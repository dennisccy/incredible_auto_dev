#!/usr/bin/env python3
"""
lint_contracts.py — agent-contract static linter (roadmap SAFE-2).

Statically checks the NEUTRAL-SOURCE agent bodies (agents/*/body.md), report
templates (templates/*.md), and agent manifests (agents/*/agent.yaml) against
lib/verdicts.py — the single source of verdict truth — so writer→reader drift
is caught at edit time instead of mid-session.

Checks
  1. Agent bodies: every verdict value named on a `**Verdict:**` (or
     `**Browser QA Verdict:**`) line must belong to that agent's report-type
     enum(s) per AGENT_CONTRACTS; a contract agent must name at least one
     value of each of its primary enums; an agent with no verdict contract
     must not carry verdict-marker lines at all.
  2. Templates: every mapped template still has a line-START verdict-marker
     line (the position machine parsers read); each such line is either a
     literal enum value or a `<...>`/pipe placeholder list whose tokens are a
     subset of the mapped enum(s); templates parsed by
     verdicts.check_verdict_file() must additionally contain a line matching
     the real _VERDICT_LINE_RE (else a report following the template could
     never register as passing); an unmapped template must not introduce
     verdict-marker lines.
  3. Every agents/<name>/ dir has body.md and an agent.yaml with non-empty
     top-level `model_tier:` and `version:` keys.

Scope notes (deliberate):
  - Lints the neutral source only — `.claude/` mirrors are build products,
    guarded by `sync-cli-assets.py --check`.
  - `**Demo Verdict:**` (templates/demo-results.md) is showcase-only, not in
    verdicts.py, and gates nothing — out of scope.
  - Verdict values are extracted only from text AFTER a marker on the same
    line; ALL-CAPS prose elsewhere is ignored. Placeholder words (VERDICT,
    VALUE) are skipped, not treated as values.

CLI (exit 0 = clean, 1 = violations/failures, 2 = usage/environment):
    python3 lint_contracts.py lint        # lint this repo, file:line per violation
    python3 lint_contracts.py self-test   # broken-fixture assertions, then lint this repo
"""

import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verdicts  # noqa: E402
from verdicts import (  # noqa: E402
    BrowserQAVerdict,
    ClosureVerdict,
    CoherenceVerdict,
    GoalEvalVerdict,
    IterationSummaryVerdict,
    UIVerdict,
    UXRegressionVerdict,
    Verdict,
)

REPO_ROOT = Path(__file__).resolve().parents[3]

# The exact strings machine parsers key on. `**Verdict:**` is verdicts.py's
# universal format; `**Browser QA Verdict:**` is parsed by
# merge_ui_test_results.py (_VERDICT_RE) and goal-iter-lean.sh.
_MARKERS = ("**Verdict:**", "**Browser QA Verdict:**")

_TOKEN_RE = re.compile(r"[A-Z][A-Z0-9_-]{2,}")
# Placeholder words that appear in `**Verdict:** <VERDICT>` / `**Verdict:** VALUE`
# format examples — never actual verdict values.
_SKIP_TOKENS = {"VERDICT", "VALUE", "VALUES"}

# Which verdicts.py enum(s) each agent's report contract draws from.
# "primary": the enums whose values the body MUST name (its own contract).
# "extra": additional enums the body may legitimately reference (e.g. source
# vocabularies it aggregates) — tolerated in the subset check, not required.
# An agent absent from this map must not carry verdict-marker lines.
AGENT_CONTRACTS = {
    "reviewer": {"primary": [Verdict]},
    "qa": {"primary": [Verdict, UIVerdict]},
    "auditor": {"primary": [Verdict]},
    "phase-closure-auditor": {"primary": [ClosureVerdict]},
    "ux-regression-reviewer": {"primary": [UXRegressionVerdict]},
    "browser-qa-agent": {"primary": [BrowserQAVerdict]},
    "goal-evaluator": {"primary": [GoalEvalVerdict]},
    "coherence-auditor": {"primary": [CoherenceVerdict]},
    # Aggregator: carries verdicts forward from eval.md / closure-verdict.md /
    # review.md, so it legitimately names ClosureVerdict source values too.
    "iteration-summarizer": {"primary": [IterationSummaryVerdict], "extra": [ClosureVerdict]},
}

# Which enum(s) each verdict-bearing template's `**Verdict:**` lines draw from.
# "phase_verdict": template output is parsed by verdicts.check_verdict_file()
# (_VERDICT_LINE_RE), so the template must contain a matching passing line.
# A template absent from this map must not carry line-start verdict markers.
TEMPLATE_CONTRACTS = {
    "audit-report.md": {"enums": [Verdict], "phase_verdict": True},
    "qa-report.md": {"enums": [Verdict, UIVerdict], "phase_verdict": True},
    "review-checklist.md": {"enums": [Verdict], "phase_verdict": True},
    "closure-verdict.md": {"enums": [ClosureVerdict]},
    "coherence-verdict.md": {"enums": [CoherenceVerdict]},
    "iteration-summary.md": {"enums": [IterationSummaryVerdict]},
    "ui-test-results.md": {"enums": [BrowserQAVerdict]},
}


def _enum_values(enums):
    vals = set()
    for e in enums:
        vals.update(m.value for m in e)
    return vals


def _enum_names(enums):
    return "/".join(e.__name__ for e in enums)


def _find_marker(line):
    """Return (marker, payload-after-marker) for the first marker on the line, else None."""
    best = None
    for m in _MARKERS:
        i = line.find(m)
        if i >= 0 and (best is None or i < best[0]):
            best = (i, m)
    if best is None:
        return None
    i, m = best
    return m, line[i + len(m):]


def _extract_values(payload):
    """Candidate verdict values named after a marker (placeholder words skipped)."""
    return [t for t in _TOKEN_RE.findall(payload) if t not in _SKIP_TOKENS]


def lint_tree(root, agent_contracts, template_contracts):
    """Lint one source tree. Returns sorted [(relpath, line, code, message), ...]."""
    root = Path(root)
    violations = []
    violations += _lint_agents(root, agent_contracts)
    violations += _lint_templates(root, template_contracts)
    return sorted(violations)


def _lint_agents(root, contracts):
    out = []
    agents_dir = root / "agents"
    if not agents_dir.is_dir():
        return out
    for d in sorted(p for p in agents_dir.iterdir() if p.is_dir()):
        rel_yaml = f"agents/{d.name}/agent.yaml"
        yaml_path = d / "agent.yaml"
        if not yaml_path.is_file():
            out.append((rel_yaml, 1, "missing-agent-yaml", "agent dir has no agent.yaml"))
        else:
            text = yaml_path.read_text(encoding="utf-8")
            for key, code in (("model_tier", "missing-model-tier"),
                              ("version", "missing-version")):
                m = re.search(rf"^{key}:[ \t]*(\S.*)?$", text, re.MULTILINE)
                if not m or not (m.group(1) or "").strip():
                    line = text[:m.start()].count("\n") + 1 if m else 1
                    out.append((rel_yaml, line, code,
                                f"agent.yaml must set a non-empty top-level '{key}:'"))

        rel_body = f"agents/{d.name}/body.md"
        body_path = d / "body.md"
        if not body_path.is_file():
            out.append((rel_body, 1, "missing-body", "agent dir has no body.md"))
            continue

        marker_hits = []  # (line_no, payload-after-marker)
        for i, line in enumerate(body_path.read_text(encoding="utf-8").splitlines(), 1):
            found = _find_marker(line)
            if found:
                marker_hits.append((i, found[1]))

        contract = contracts.get(d.name)
        if contract is None:
            if marker_hits:
                out.append((rel_body, marker_hits[0][0], "unmapped-verdict-contract",
                            f"body carries a verdict-marker line but '{d.name}' has no entry in "
                            "AGENT_CONTRACTS — register its report type (add the enum to "
                            "lib/verdicts.py first if it is new)"))
            continue

        primary = contract["primary"]
        allowed = _enum_values(primary) | _enum_values(contract.get("extra", []))
        named = set()
        for line_no, payload in marker_hits:
            for tok in _extract_values(payload):
                if tok in allowed:
                    named.add(tok)
                else:
                    out.append((rel_body, line_no, "unknown-verdict-value",
                                f"'{tok}' is not a {_enum_names(primary)} value "
                                f"(allowed: {', '.join(sorted(allowed))})"))
        for enum in primary:
            if not named & _enum_values([enum]):
                out.append((rel_body, 1, "missing-verdict-values",
                            f"body never names any {enum.__name__} value on a verdict-marker "
                            "line — the verdict contract must be stated in the body"))
    return out


def _lint_templates(root, contracts):
    out = []
    tdir = root / "templates"
    if not tdir.is_dir():
        return out
    for f in sorted(tdir.glob("*.md")):
        rel = f"templates/{f.name}"
        content = f.read_text(encoding="utf-8")

        # Only line-START markers: that is the position _VERDICT_LINE_RE and the
        # shell greps anchor on. Mid-line mentions are prose/comments.
        starts = []  # (line_no, payload-after-marker)
        for i, line in enumerate(content.splitlines(), 1):
            for m in _MARKERS:
                if line.startswith(m):
                    starts.append((i, line[len(m):]))
                    break

        contract = contracts.get(f.name)
        if contract is None:
            if starts:
                out.append((rel, starts[0][0], "unmapped-verdict-contract",
                            f"template carries a verdict line but '{f.name}' has no entry in "
                            "TEMPLATE_CONTRACTS — register its report type (add the enum to "
                            "lib/verdicts.py first if it is new)"))
            continue

        allowed = _enum_values(contract["enums"])
        if not starts:
            out.append((rel, 1, "missing-verdict-line",
                        "mapped verdict template has no line starting with a verdict marker — "
                        "machine parsers can no longer find the verdict"))
        for line_no, payload in starts:
            stripped = payload.strip()
            if stripped.startswith("<") or "|" in stripped:
                toks = _extract_values(payload)
                if not toks:
                    out.append((rel, line_no, "bad-verdict-line",
                                "placeholder verdict line names no values"))
                for tok in toks:
                    if tok not in allowed:
                        out.append((rel, line_no, "unknown-verdict-value",
                                    f"'{tok}' is not a {_enum_names(contract['enums'])} value "
                                    f"(allowed: {', '.join(sorted(allowed))})"))
            else:
                m = re.match(r"[ \t]+(\S+)[ \t]*$", payload)
                if not m:
                    out.append((rel, line_no, "bad-verdict-line",
                                "verdict line must be '<marker> VALUE' — single value, "
                                "whitespace-separated (this is what the parsers match)"))
                elif m.group(1) not in allowed:
                    out.append((rel, line_no, "unknown-verdict-value",
                                f"'{m.group(1)}' is not a {_enum_names(contract['enums'])} value "
                                f"(allowed: {', '.join(sorted(allowed))})"))

        if contract.get("phase_verdict") and not verdicts._VERDICT_LINE_RE.search(content):
            out.append((rel, 1, "no-passing-verdict-line",
                        "template output is parsed by verdicts.check_verdict_file() but no line "
                        "matches _VERDICT_LINE_RE — a report following it could never pass"))
    return out


def lint_repo():
    return lint_tree(REPO_ROOT, AGENT_CONTRACTS, TEMPLATE_CONTRACTS)


def _print_violations(violations):
    for path, line, code, msg in violations:
        print(f"{path}:{line}: [{code}] {msg}")


# ── CLI: lint ─────────────────────────────────────────────────────────────────

def _cmd_lint(_args):
    if not (REPO_ROOT / "agents").is_dir() or not (REPO_ROOT / "templates").is_dir():
        print(f"Error: {REPO_ROOT} does not look like the framework repo "
              "(agents/ or templates/ missing)", file=sys.stderr)
        return 2
    violations = lint_repo()
    _print_violations(violations)
    if violations:
        print(f"lint_contracts: {len(violations)} violation(s)")
        return 1
    n_agents = sum(1 for p in (REPO_ROOT / "agents").iterdir() if p.is_dir())
    n_templates = len(list((REPO_ROOT / "templates").glob("*.md")))
    print(f"lint_contracts: OK ({n_agents} agents, {n_templates} templates)")
    return 0


# ── CLI: self-test ────────────────────────────────────────────────────────────

def _write(root, relpath, content):
    p = root / relpath
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content, encoding="utf-8")


_OK_YAML = "name: {name}\nmodel_tier: standard\nversion: 1.0.0\n"


def _build_clean_fixture(root):
    _write(root, "agents/goodagent/agent.yaml", _OK_YAML.format(name="goodagent"))
    _write(root, "agents/goodagent/body.md",
           "# Good agent\n"
           "\n"
           "Emit `**Verdict:** PASS` on success or `**Verdict:** FAIL` otherwise.\n"
           "\n"
           "**Verdict:** <VERDICT>\n")
    _write(root, "agents/plain/agent.yaml", _OK_YAML.format(name="plain"))
    _write(root, "agents/plain/body.md", "# Plain agent\n\nNo report contract here.\n")
    _write(root, "templates/good-report.md",
           "# Report\n"
           "\n"
           "**Verdict:** PASS\n"
           "\n"
           "**Verdict:** <PASS | FAIL>\n")
    _write(root, "templates/bq.md",
           "# Browser results\n"
           "\n"
           "**Browser QA Verdict:** PASS | FAIL | SKIPPED\n")
    _write(root, "templates/plain.md", "# Nothing verdict-shaped here\n")
    agent_contracts = {"goodagent": {"primary": [Verdict]}}
    template_contracts = {
        "good-report.md": {"enums": [Verdict], "phase_verdict": True},
        "bq.md": {"enums": [BrowserQAVerdict]},
    }
    return agent_contracts, template_contracts


def _build_broken_fixture(root):
    # badvalue: names a value outside its enum (and therefore none inside it)
    _write(root, "agents/badvalue/agent.yaml", _OK_YAML.format(name="badvalue"))
    _write(root, "agents/badvalue/body.md", "# Bad\n\n**Verdict:** PASSED\n")
    # silent: mapped agent that names no verdict values at all
    _write(root, "agents/silent/agent.yaml", _OK_YAML.format(name="silent"))
    _write(root, "agents/silent/body.md", "# Silent\n\nNo verdict named here.\n")
    # rogue: verdict line in an agent with no registered contract
    _write(root, "agents/rogue/agent.yaml", _OK_YAML.format(name="rogue"))
    _write(root, "agents/rogue/body.md", "# Rogue\n\n**Verdict:** PASS\n")
    # noyaml: valid body, missing agent.yaml
    _write(root, "agents/noyaml/body.md", "# No yaml\n\n**Verdict:** CONTINUE\n")
    # notier: agent.yaml without model_tier
    _write(root, "agents/notier/agent.yaml", "name: notier\nversion: 1.0.0\n")
    _write(root, "agents/notier/body.md", "# No tier\n")
    # nobody: agent dir without body.md
    _write(root, "agents/nobody/agent.yaml", _OK_YAML.format(name="nobody"))
    # broken-bold: the classic drift — bold markers broken, parser can't find the line
    _write(root, "templates/broken-bold.md", "# Closure\n\n**Verdict: ** CLOSURE-PASS\n")
    # wrong-value: verdict value outside the mapped enum
    _write(root, "templates/wrong-value.md", "# Coherence\n\n**Verdict:** MAYBE\n")
    # fail-only: valid enum value, but nothing _VERDICT_LINE_RE could ever match
    _write(root, "templates/fail-only.md", "# Audit\n\n**Verdict:** FAIL\n")
    # nospace: missing the required whitespace between marker and value
    _write(root, "templates/nospace.md", "# QA\n\n**Verdict:**PASS\n")
    # rogue-template: verdict line in a template with no registered contract
    _write(root, "templates/rogue-template.md", "# Rogue\n\n**Verdict:** PASS\n")
    agent_contracts = {
        "badvalue": {"primary": [Verdict]},
        "silent": {"primary": [GoalEvalVerdict]},
        "noyaml": {"primary": [GoalEvalVerdict]},
        # rogue / notier / nobody intentionally unmapped
    }
    template_contracts = {
        "broken-bold.md": {"enums": [ClosureVerdict]},
        "wrong-value.md": {"enums": [CoherenceVerdict]},
        "fail-only.md": {"enums": [Verdict], "phase_verdict": True},
        "nospace.md": {"enums": [Verdict]},
        # rogue-template.md intentionally unmapped
    }
    return agent_contracts, template_contracts


_EXPECTED_BROKEN = {
    ("agents/badvalue/body.md", 3, "unknown-verdict-value"),
    ("agents/badvalue/body.md", 1, "missing-verdict-values"),
    ("agents/silent/body.md", 1, "missing-verdict-values"),
    ("agents/rogue/body.md", 3, "unmapped-verdict-contract"),
    ("agents/noyaml/agent.yaml", 1, "missing-agent-yaml"),
    ("agents/notier/agent.yaml", 1, "missing-model-tier"),
    ("agents/nobody/body.md", 1, "missing-body"),
    ("templates/broken-bold.md", 1, "missing-verdict-line"),
    ("templates/wrong-value.md", 3, "unknown-verdict-value"),
    ("templates/fail-only.md", 1, "no-passing-verdict-line"),
    ("templates/nospace.md", 3, "bad-verdict-line"),
    ("templates/rogue-template.md", 3, "unmapped-verdict-contract"),
}


def _cmd_self_test(_args):
    failures = []

    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        ac, tc = _build_clean_fixture(root)
        got = lint_tree(root, ac, tc)
        if got:
            failures.append("clean fixture must produce zero violations, got:")
            failures += [f"  {p}:{l}: [{c}] {m}" for p, l, c, m in got]
        else:
            print("self-test: clean fixture → 0 violations OK")

    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        ac, tc = _build_broken_fixture(root)
        got = {(p, l, c) for p, l, c, _ in lint_tree(root, ac, tc)}
        missing = _EXPECTED_BROKEN - got
        unexpected = got - _EXPECTED_BROKEN
        if missing:
            failures.append("broken fixture: expected violations NOT detected:")
            failures += [f"  {p}:{l}: [{c}]" for p, l, c in sorted(missing)]
        if unexpected:
            failures.append("broken fixture: unexpected violations reported:")
            failures += [f"  {p}:{l}: [{c}]" for p, l, c in sorted(unexpected)]
        if not missing and not unexpected:
            print(f"self-test: broken fixture → all {len(_EXPECTED_BROKEN)} expected violations detected OK")

    # The real tree must be green — this is what turns run-evals.sh red when a
    # live agent body / template / agent.yaml drifts from verdicts.py.
    real = lint_repo()
    if real:
        failures.append(f"current tree has {len(real)} contract violation(s):")
        failures += [f"  {p}:{l}: [{c}] {m}" for p, l, c, m in real]
    else:
        print("self-test: current tree lint → clean OK")

    if failures:
        print("self-test FAILED:")
        for f in failures:
            print(f)
        return 1
    print("self-test: all lint_contracts checks passed")
    return 0


_COMMANDS = {
    "lint": _cmd_lint,
    "self-test": _cmd_self_test,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in _COMMANDS:
        print("Usage: lint_contracts.py <lint|self-test>", file=sys.stderr)
        sys.exit(2)
    sys.exit(_COMMANDS[sys.argv[1]](sys.argv[2:]))
