"""
Centralized verdict and status definitions — single source of truth.

All report agents MUST produce verdicts in the format:
    **Verdict:** VALUE

where VALUE is one of the enum values defined here.

CLI usage (called from shell scripts):
    python3 verdicts.py check-verdict <report_file>   # exit 0 if passing verdict, 1 otherwise
    python3 verdicts.py validate-status <value>        # exit 0 if valid PhaseStatus, 1 otherwise
    python3 verdicts.py validate-step <value>          # exit 0 if valid PhaseStep, 1 otherwise
    python3 verdicts.py passing-verdicts               # print space-separated passing verdict values
    python3 verdicts.py all-verdicts                   # print all Verdict values
"""

import re
import sys
from enum import Enum


class Verdict(str, Enum):
    """Phase report verdicts (review, QA, audit).

    All reports use the universal format:
        **Verdict:** VALUE
    where VALUE is exactly one of these enum values.
    """
    PASS = "PASS"
    PASS_WITH_NOTES = "PASS_WITH_NOTES"
    PASS_WITH_GAPS = "PASS_WITH_GAPS"
    FAIL = "FAIL"


class UIVerdict(str, Enum):
    """UI evolution audit verdicts (embedded inside QA reports)."""
    UI_PASS = "UI-PASS"
    UI_PASS_WITH_GAPS = "UI-PASS-WITH-GAPS"
    UI_FAIL = "UI-FAIL"
    UI_SKIPPED = "UI-SKIPPED"


class ClosureVerdict(str, Enum):
    """Phase closure audit verdicts (reports/phase-{N}-closure-verdict.md)."""
    CLOSURE_PASS = "CLOSURE-PASS"
    CLOSURE_FAIL = "CLOSURE-FAIL"


class UXRegressionVerdict(str, Enum):
    """UX regression review verdicts (reports/phase-{N}-ux-regression.md)."""
    UX_REGRESSION_PASS = "UX-REGRESSION-PASS"
    UX_REGRESSION_WARN = "UX-REGRESSION-WARN"
    UX_REGRESSION_FAIL = "UX-REGRESSION-FAIL"


class BrowserQAVerdict(str, Enum):
    """Browser QA verdicts (reports/phase-{N}-ui-test-results.md)."""
    PASS = "PASS"
    FAIL = "FAIL"
    SKIPPED = "SKIPPED"


class PhaseStatus(str, Enum):
    """Top-level status field in status.json."""
    IN_PROGRESS = "in_progress"
    COMPLETE = "complete"
    BLOCKED = "blocked"
    FAILED = "failed"
    FINALIZED = "finalized"


class PhaseStep(str, Enum):
    """current_step field in status.json.

    Note: dev_complete_attempt_N is a special pattern (prefix: "dev_complete_attempt_")
    and is handled via is_valid_step() rather than enum membership.
    """
    INIT = "init"
    STARTING = "starting"
    PLANNED = "planned"
    TEST_PLAN_GENERATED = "test_plan_generated"
    DEV_COMPLETE = "dev_complete"        # set by developer agent directly
    REVIEW_PASSED = "review_passed"
    REVIEW_FAILED = "review_failed"
    QA_COMPLETE = "qa_complete"          # set by QA agent directly
    QA_PASSED = "qa_passed"
    QA_FAILED = "qa_failed"
    AUDIT_PASSED = "audit_passed"
    AUDIT_FAILED = "audit_failed"
    AUDIT_QA_FAILED = "audit_qa_failed"
    UI_IMPACT_COMPLETE = "ui_impact_complete"
    UI_TEST_DESIGNED = "ui_test_designed"
    BROWSER_QA_COMPLETE = "browser_qa_complete"
    UX_REGRESSION_COMPLETE = "ux_regression_complete"
    CLOSURE_PASSED = "closure_passed"
    CLOSURE_FAILED = "closure_failed"
    FAILED = "failed"


class NextAction(str, Enum):
    """next_action field in status.json."""
    FINALIZE = "finalize"
    FIX_REVIEW = "fix_review"
    FIX_QA = "fix_qa"
    FIX_AUDIT = "fix_audit"
    NONE = "none"


# Verdicts that mean the phase step passed (subset of Verdict)
PASSING_VERDICTS = {Verdict.PASS, Verdict.PASS_WITH_NOTES, Verdict.PASS_WITH_GAPS}

# Regex pattern used to detect a passing verdict line in a report file
_VERDICT_LINE_RE = re.compile(
    r"^\*\*Verdict:\*\*\s+(" + "|".join(re.escape(v.value) for v in PASSING_VERDICTS) + r")\s*$",
    re.MULTILINE,
)


def check_verdict_file(path: str) -> bool:
    """Return True if report at path contains a passing verdict line."""
    try:
        with open(path, encoding="utf-8") as f:
            content = f.read()
        return bool(_VERDICT_LINE_RE.search(content))
    except OSError:
        return False


def is_valid_step(value: str) -> bool:
    """Return True if value is a valid PhaseStep (including dev_complete_attempt_N pattern)."""
    if value.startswith("dev_complete_attempt_"):
        suffix = value[len("dev_complete_attempt_"):]
        return suffix.isdigit()
    return value in {s.value for s in PhaseStep}


def is_valid_status(value: str) -> bool:
    """Return True if value is a valid PhaseStatus."""
    return value in {s.value for s in PhaseStatus}


# ── CLI entrypoints ────────────────────────────────────────────────────────────

def _cmd_check_verdict(args: list[str]) -> int:
    if not args:
        print("Usage: verdicts.py check-verdict <report_file>", file=sys.stderr)
        return 2
    result = check_verdict_file(args[0])
    return 0 if result else 1


def _cmd_validate_status(args: list[str]) -> int:
    if not args:
        print("Usage: verdicts.py validate-status <value>", file=sys.stderr)
        return 2
    if not is_valid_status(args[0]):
        valid = ", ".join(s.value for s in PhaseStatus)
        print(f"Error: invalid status '{args[0]}'. Valid values: {valid}", file=sys.stderr)
        return 1
    return 0


def _cmd_validate_step(args: list[str]) -> int:
    if not args:
        print("Usage: verdicts.py validate-step <value>", file=sys.stderr)
        return 2
    if not is_valid_step(args[0]):
        valid = ", ".join(s.value for s in PhaseStep) + ", dev_complete_attempt_N"
        print(f"Error: invalid step '{args[0]}'. Valid values: {valid}", file=sys.stderr)
        return 1
    return 0


def _cmd_passing_verdicts(_args: list[str]) -> int:
    print(" ".join(v.value for v in PASSING_VERDICTS))
    return 0


def _cmd_all_verdicts(_args: list[str]) -> int:
    print(" ".join(v.value for v in Verdict))
    return 0


_COMMANDS = {
    "check-verdict": _cmd_check_verdict,
    "validate-status": _cmd_validate_status,
    "validate-step": _cmd_validate_step,
    "passing-verdicts": _cmd_passing_verdicts,
    "all-verdicts": _cmd_all_verdicts,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in _COMMANDS:
        print(f"Usage: verdicts.py <command> [args]", file=sys.stderr)
        print(f"Commands: {', '.join(_COMMANDS)}", file=sys.stderr)
        sys.exit(2)
    sys.exit(_COMMANDS[sys.argv[1]](sys.argv[2:]))
