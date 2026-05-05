"""
Validate that every agent definition in `.claude/agents/*.md` has well-formed
frontmatter: required fields present, model is a recognized tier, version is
semver-ish, last_updated is a date.

Run with no args from the repo root, or pass an explicit `<agents-dir>`.
Returns 0 if all agents pass, 1 if any fail.

This is the agent half of the offline eval suite. It catches prompt drift
(missing version, malformed frontmatter, agents that lost a required key)
without spending API credits.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any

REQUIRED_FIELDS = {"name", "description", "model", "version", "last_updated"}
OPTIONAL_FIELDS = {
    "tools",                 # list of Claude Code tool names this agent uses
    "disallowed_tools",      # list — additional Bash patterns to deny on top of HARD_DEFAULT_DENIALS
    "max_budget_usd",        # numeric — per-invocation hard cap passed as --max-budget-usd
}
KNOWN_MODELS = {
    # strong
    "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5",
    # standard
    "claude-sonnet-4-6", "claude-sonnet-4-5", "claude-sonnet-4-7",
    # light
    "claude-haiku-4-5", "claude-haiku-4-6",
    # generic aliases sometimes used
    "opus", "sonnet", "haiku",
}
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def _parse_frontmatter(text: str) -> dict[str, Any] | None:
    """Parse YAML-ish frontmatter at the top of a markdown file. Returns None
    if frontmatter is absent or malformed."""
    if not text.startswith("---"):
        return None
    end = text.find("\n---", 3)
    if end == -1:
        return None
    block = text[3:end].strip()
    fields: dict[str, Any] = {}
    for line in block.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        # very narrow YAML: `key: value` or `key: [a, b, c]`
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        key = key.strip()
        value = value.strip()
        if value.startswith("[") and value.endswith("]"):
            inner = value[1:-1].strip()
            fields[key] = (
                [s.strip() for s in inner.split(",")] if inner else []
            )
        elif value:
            fields[key] = value
    return fields


def validate_agent_file(path: Path) -> list[str]:
    """Return a list of diagnostic strings for the given agent file. Empty
    list means pass."""
    issues: list[str] = []
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as e:
        return [f"could not read: {e}"]

    fm = _parse_frontmatter(text)
    if fm is None:
        return ["missing or malformed frontmatter (must start with --- ... ---)"]

    missing = REQUIRED_FIELDS - fm.keys()
    if missing:
        issues.append(f"missing required field(s): {sorted(missing)}")

    # name should match filename stem
    if "name" in fm and fm["name"] != path.stem:
        issues.append(
            f"name '{fm['name']}' does not match filename stem '{path.stem}'"
        )

    # description must be non-empty (rule of thumb: at least 30 chars)
    if "description" in fm and len(str(fm["description"]).strip()) < 30:
        issues.append("description is too short (<30 chars)")

    # model must be a known model id
    if "model" in fm and fm["model"] not in KNOWN_MODELS:
        issues.append(
            f"model '{fm['model']}' not in known set; if this is intentional, "
            "add it to KNOWN_MODELS in validate_agents.py"
        )

    if "version" in fm and not VERSION_RE.match(str(fm["version"])):
        issues.append(f"version '{fm['version']}' is not semver-shaped (X.Y.Z)")

    if "last_updated" in fm and not DATE_RE.match(str(fm["last_updated"])):
        issues.append(f"last_updated '{fm['last_updated']}' is not YYYY-MM-DD")

    # Optional fields: type-check when present.
    if "disallowed_tools" in fm:
        v = fm["disallowed_tools"]
        if not isinstance(v, list):
            issues.append("disallowed_tools must be a list (e.g., ['Bash(rm -rf /*)'])")
        else:
            for item in v:
                if not isinstance(item, str) or not item.strip():
                    issues.append(f"disallowed_tools contains non-string or empty entry: {item!r}")

    if "max_budget_usd" in fm:
        try:
            v = float(fm["max_budget_usd"])
            if v <= 0:
                issues.append(f"max_budget_usd must be > 0, got {v}")
        except (TypeError, ValueError):
            issues.append(f"max_budget_usd must be a positive number, got {fm['max_budget_usd']!r}")

    return issues


def main() -> int:
    agents_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".claude/agents")
    if not agents_dir.is_dir():
        print(f"error: {agents_dir} is not a directory", file=sys.stderr)
        return 2
    failures: dict[str, list[str]] = {}
    files = sorted(agents_dir.glob("*.md"))
    if not files:
        print(f"warning: no *.md files in {agents_dir}", file=sys.stderr)
        return 0
    for f in files:
        issues = validate_agent_file(f)
        if issues:
            failures[str(f)] = issues
    if failures:
        print(f"FAIL: {len(failures)} of {len(files)} agent files have issues:")
        for path, issues in failures.items():
            print(f"  {path}")
            for issue in issues:
                print(f"    - {issue}")
        return 1
    print(f"OK: all {len(files)} agent files validate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
