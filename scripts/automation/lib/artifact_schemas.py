"""
Artifact schema validation for pipeline reports.

Each verdict-bearing artifact (review, qa, audit, closure, ux-regression,
browser-qa) has a known shape — a verdict line whose value is in a specific
enum, plus a small set of required H2 sections. This module validates that
shape.

Reuses verdict enums from `verdicts.py` so the source of truth stays single.

CLI:
    python3 artifact_schemas.py validate <path>     # exit 0 if pass or unrecognized; 1 if issues
    python3 artifact_schemas.py list                # print recognized artifact types
    python3 artifact_schemas.py self-test           # built-in fixture roundtrip

Behavior is advisory: the hook that calls this prints warnings and continues.
The exit code is informational only.
"""
from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verdicts import (
    BrowserQAVerdict,
    ClosureVerdict,
    IterationSummaryVerdict,
    UIVerdict,  # noqa: F401  (referenced by qa schema's optional ui audit)
    UXRegressionVerdict,
    Verdict,
)


@dataclass(frozen=True)
class ArtifactSchema:
    artifact_type: str
    path_pattern: re.Pattern
    verdict_enum: type[Enum]
    required_h2: tuple[str, ...] = ()
    description: str = ""


SCHEMAS: tuple[ArtifactSchema, ...] = (
    ArtifactSchema(
        artifact_type="review",
        path_pattern=re.compile(r"reports/reviews/.+-review\.md$"),
        verdict_enum=Verdict,
        required_h2=("Verdict",),
        description="Reviewer report — reports/reviews/<phase>-review.md",
    ),
    ArtifactSchema(
        artifact_type="qa",
        path_pattern=re.compile(r"reports/qa/.+-qa\.md$"),
        verdict_enum=Verdict,
        required_h2=("Verdict",),
        description="QA validation report — reports/qa/<phase>-qa.md",
    ),
    ArtifactSchema(
        artifact_type="audit",
        path_pattern=re.compile(r"docs/handoffs/.+-audit\.md$"),
        verdict_enum=Verdict,
        required_h2=("Executive Verdict",),
        description="Auditor report — docs/handoffs/<phase>-audit.md",
    ),
    ArtifactSchema(
        artifact_type="closure",
        path_pattern=re.compile(r"reports/phase-.+-closure-verdict\.md$"),
        verdict_enum=ClosureVerdict,
        required_h2=(),
        description="Phase closure verdict — reports/phase-<N>-closure-verdict.md",
    ),
    ArtifactSchema(
        artifact_type="ux-regression",
        path_pattern=re.compile(r"reports/phase-.+-ux-regression\.md$"),
        verdict_enum=UXRegressionVerdict,
        required_h2=(),
        description="UX regression report — reports/phase-<N>-ux-regression.md",
    ),
    ArtifactSchema(
        artifact_type="browser-qa",
        path_pattern=re.compile(r"reports/phase-.+-ui-test-results\.md$"),
        verdict_enum=BrowserQAVerdict,
        required_h2=("Results Table",),
        description="Browser QA results — reports/phase-<N>-ui-test-results.md",
    ),
    ArtifactSchema(
        artifact_type="iteration-summary",
        path_pattern=re.compile(r"reports/phase-.+-iteration-summary\.md$"),
        verdict_enum=IterationSummaryVerdict,
        required_h2=(
            "In plain words",
            "Headline",
            "Direction",
            "What was done",
            "What's left",
            "Next step",
        ),
        description="Iteration summary — reports/phase-<N>-iteration-summary.md",
    ),
)


# Match any line of the form `**[anything] Verdict:** VALUE` and capture VALUE.
# Allows flexible labels like "Verdict:", "Browser QA Verdict:", "UI Verdict:".
_VERDICT_LINE_RE = re.compile(r"^\*\*[^*\n]*Verdict:\*\*\s+([^\s|<>]+)", re.MULTILINE)
_H2_RE = re.compile(r"^##\s+(.+?)\s*$", re.MULTILINE)


def match_schema(path: str) -> Optional[ArtifactSchema]:
    """Return the schema matching the path, or None."""
    norm = path.replace("\\", "/")
    for s in SCHEMAS:
        if s.path_pattern.search(norm):
            return s
    return None


def find_verdict(content: str, allowed: set[str]) -> Optional[str]:
    """Return the first verdict value present in `content` that is in `allowed`."""
    for match in _VERDICT_LINE_RE.finditer(content):
        value = match.group(1).strip()
        if value in allowed:
            return value
    return None


def find_h2_sections(content: str) -> set[str]:
    return set(_H2_RE.findall(content))


@dataclass
class ValidationResult:
    matched: bool
    artifact_type: Optional[str] = None
    verdict: Optional[str] = None
    issues: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return self.matched and not self.issues


def validate_path(path: str) -> ValidationResult:
    schema = match_schema(path)
    if schema is None:
        return ValidationResult(matched=False)

    try:
        with open(path, encoding="utf-8") as f:
            content = f.read()
    except OSError as e:
        return ValidationResult(
            matched=True,
            artifact_type=schema.artifact_type,
            issues=[f"could not read file: {e}"],
        )

    issues: list[str] = []
    allowed = {v.value for v in schema.verdict_enum}
    verdict = find_verdict(content, allowed)
    if verdict is None:
        issues.append(
            f"missing or invalid verdict line; expected one of: "
            f"{sorted(allowed)}"
        )

    h2s = find_h2_sections(content)
    for required in schema.required_h2:
        if required not in h2s:
            issues.append(f"missing required '## {required}' section")

    return ValidationResult(
        matched=True,
        artifact_type=schema.artifact_type,
        verdict=verdict,
        issues=issues,
    )


# ── CLI ──────────────────────────────────────────────────────────────────────

def _cmd_validate(argv: list[str]) -> int:
    if not argv:
        print("Usage: artifact_schemas.py validate <path>", file=sys.stderr)
        return 2
    result = validate_path(argv[0])
    if not result.matched:
        return 0  # silently skip non-artifact paths
    if result.issues:
        print(
            f"[artifact-schema] {argv[0]} ({result.artifact_type}):",
            file=sys.stderr,
        )
        for issue in result.issues:
            print(f"  - {issue}", file=sys.stderr)
        return 1
    return 0


def _cmd_list(_argv: list[str]) -> int:
    for s in SCHEMAS:
        verdicts = ", ".join(v.value for v in s.verdict_enum)
        print(f"{s.artifact_type:16s}  {s.description}")
        print(f"{'':16s}  verdicts: {verdicts}")
        if s.required_h2:
            print(f"{'':16s}  required H2: {', '.join(s.required_h2)}")
    return 0


_FIXTURES = {
    "review_pass": (
        "reports/reviews/phase-1-review.md",
        "# Code Review Report\n\n## Verdict\n\n**Verdict:** PASS\n\n## Findings\n\nNone.\n",
        True,
    ),
    "review_missing_verdict": (
        "reports/reviews/phase-1-review.md",
        "# Code Review Report\n\nLooks good.\n",
        False,
    ),
    "review_invalid_verdict": (
        "reports/reviews/phase-1-review.md",
        "# Code Review Report\n\n## Verdict\n\n**Verdict:** GOOD\n",
        False,
    ),
    "audit_missing_h2": (
        "docs/handoffs/phase-1-audit.md",
        "# Phase 1 Audit\n\n**Verdict:** PASS\n",
        False,  # missing 'Executive Verdict' H2
    ),
    "closure_pass": (
        "reports/phase-1-closure-verdict.md",
        "# Phase 1 Closure\n\n**Verdict:** CLOSURE-PASS\n",
        True,
    ),
    "browser_qa_pass": (
        "reports/phase-1-ui-test-results.md",
        "# UI Test Results\n\n**Browser QA Verdict:** PASS\n\n## Results Table\n\n| ... |\n",
        True,
    ),
    "iteration_summary_pass_phase": (
        "reports/phase-1-iteration-summary.md",
        "# Iteration Summary — phase-1\n\n**Verdict:** PASS\n\n"
        "## In plain words\n\n**What you can do now:** Sign in with email.\n\n"
        "**What changed this time:** You can now sign in.\n\n"
        "**What's next:** Next we'll let you reset a forgotten password.\n\n"
        "## Headline\n\nAdded login.\n\n"
        "## Direction\n\n**Signal:** n/a\n\n## What was done\n\n- Login\n\n"
        "## What's left\n\n- nothing\n\n## Next step\n\nNext phase.\n\n## Artifacts\n\n| - | - | - |\n",
        True,
    ),
    "iteration_summary_pass_goal": (
        "reports/phase-goal-x-iter-3-iteration-summary.md",
        "# Iteration Summary — goal-x-iter-3\n\n**Verdict:** CONTINUE\n\n"
        "## In plain words\n\n**What you can do now:** Sign in with email and view your tasks.\n\n"
        "**What changed this time:** You can now sign in.\n\n"
        "**What's next:** Next we'll let you create a task.\n\n"
        "## Headline\n\nJ-04 passes.\n\n"
        "## Direction\n\n**Signal:** improving\n\n## What was done\n\n- J-04\n\n"
        "## What's left\n\n- J-05\n\n## Next step\n\nTarget J-05.\n\n## Artifacts\n\n| - | - | - |\n",
        True,
    ),
    "iteration_summary_missing_h2": (
        "reports/phase-1-iteration-summary.md",
        "# Iteration Summary — phase-1\n\n**Verdict:** PASS\n\n## Headline\n\nx\n",
        False,  # missing required H2 sections (including 'In plain words')
    ),
    "iteration_summary_invalid_verdict": (
        "reports/phase-1-iteration-summary.md",
        "# Iteration Summary\n\n**Verdict:** MAYBE\n\n"
        "## In plain words\n\n**What you can do now:** x\n**What changed this time:** x\n**What's next:** x\n\n"
        "## Headline\n\nx\n"
        "## Direction\n\n## What was done\n\n## What's left\n\n## Next step\n",
        False,
    ),
    "unrecognized": (
        "reports/some-other-file.md",
        "Whatever.\n",
        True,  # silently passes
    ),
}


def _cmd_self_test(_argv: list[str]) -> int:
    """Run built-in fixtures through validator without writing to disk."""
    import io
    import os
    import tempfile

    failures: list[str] = []
    with tempfile.TemporaryDirectory() as tmp:
        for name, (rel, body, expected_ok) in _FIXTURES.items():
            full = Path(tmp) / rel
            full.parent.mkdir(parents=True, exist_ok=True)
            full.write_text(body, encoding="utf-8")
            result = validate_path(str(full))
            actual_ok = result.ok if result.matched else True  # unmatched ≡ silent pass
            if actual_ok != expected_ok:
                failures.append(
                    f"  [{name}] expected ok={expected_ok}, got matched={result.matched}, "
                    f"issues={result.issues}, verdict={result.verdict}"
                )
            else:
                print(f"  [{name}] ok ({result.artifact_type or 'no-match'})")
    if failures:
        print("\nself-test FAILED:", file=sys.stderr)
        for f in failures:
            print(f, file=sys.stderr)
        return 1
    print("\nself-test passed")
    return 0


_COMMANDS = {
    "validate": _cmd_validate,
    "list": _cmd_list,
    "self-test": _cmd_self_test,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in _COMMANDS:
        print(f"Usage: artifact_schemas.py <command> [args]", file=sys.stderr)
        print(f"Commands: {', '.join(_COMMANDS)}", file=sys.stderr)
        sys.exit(2)
    sys.exit(_COMMANDS[sys.argv[1]](sys.argv[2:]))
