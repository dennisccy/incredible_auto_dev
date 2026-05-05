"""
Validate that every skill in `.claude/skills/*.md` is well-formed.

Skills don't carry YAML frontmatter (unlike agents) — they're prose
methodology documents. The validator catches drift / incomplete skills:

  - File starts with an H1 heading (`# ...`)
  - Has at least one H2 section (structured content)
  - Has substantive body (default: ≥20 non-empty, non-comment lines)
  - No vague placeholder markers (TBD, TODO, FIXME, PLACEHOLDER) above
    the threshold count of 0 — placeholders mean the skill is incomplete

Usage:
    python3 validate_skills.py                          # default .claude/skills
    python3 validate_skills.py <skills-dir>
    python3 validate_skills.py --self-test
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

DEFAULT_SKILLS_DIR = Path(".claude/skills")
MIN_CONTENT_LINES = 20
PLACEHOLDER_RE = re.compile(
    r"^\s*(?:>?\s*)?(?:TBD|TODO|FIXME|PLACEHOLDER|FILL\s+IN|XXX)\b",
    re.IGNORECASE,
)
H1_RE = re.compile(r"^#\s+\S")
H2_RE = re.compile(r"^##\s+\S")


def validate_skill_file(path: Path) -> list[str]:
    issues: list[str] = []
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as e:
        return [f"could not read: {e}"]

    lines = text.splitlines()
    non_blank = [ln for ln in lines if ln.strip() and not ln.lstrip().startswith("<!--")]

    if not non_blank:
        return ["file is empty"]

    if not H1_RE.match(non_blank[0]):
        issues.append(f"first non-blank line should be a markdown H1 (got: '{non_blank[0][:80]}')")

    if not any(H2_RE.match(ln) for ln in non_blank):
        issues.append("no '## ' subsection — skill should have at least one H2 header")

    content_lines = [
        ln for ln in non_blank
        if not ln.lstrip().startswith("#") and not ln.lstrip().startswith("```")
    ]
    if len(content_lines) < MIN_CONTENT_LINES:
        issues.append(
            f"only {len(content_lines)} content lines — skills should be ≥{MIN_CONTENT_LINES}"
        )

    placeholders = [
        ln for ln in lines if PLACEHOLDER_RE.match(ln)
    ]
    if placeholders:
        issues.append(
            f"contains {len(placeholders)} placeholder line(s) "
            f"(TBD/TODO/FIXME/etc.) — first: {placeholders[0].strip()[:80]}"
        )

    return issues


def _self_test() -> int:
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)
        # Good skill — passes
        good = d / "good-skill.md"
        good_body = "# Skill: Good Skill\n\nA proper methodology document.\n\n## Usage\n\n"
        good_body += "\n".join(f"Step {i}: do thing." for i in range(25))
        good.write_text(good_body, encoding="utf-8")
        # Bad: no H1
        bad1 = d / "no-h1.md"
        bad1.write_text("Hello world\n## Subsection\n", encoding="utf-8")
        # Bad: no H2
        bad2 = d / "no-h2.md"
        bad2_body = "# Title\n\n"
        bad2_body += "\n".join(f"line {i}" for i in range(25))
        bad2.write_text(bad2_body, encoding="utf-8")
        # Bad: too short
        bad3 = d / "too-short.md"
        bad3.write_text("# Title\n\n## Sub\n\nOne line.\n", encoding="utf-8")
        # Bad: placeholder
        bad4 = d / "has-placeholder.md"
        bad4_body = "# Title\n\n## Sub\nTODO fill in\n"
        bad4_body += "\n".join(f"line {i}" for i in range(25))
        bad4.write_text(bad4_body, encoding="utf-8")

        assert validate_skill_file(good) == [], f"good skill rejected: {validate_skill_file(good)}"
        assert validate_skill_file(bad1), "no-H1 should fail"
        assert validate_skill_file(bad2), "no-H2 should fail"
        assert validate_skill_file(bad3), "too-short should fail"
        assert validate_skill_file(bad4), "placeholder should fail"
    print("self-test passed")
    return 0


def main() -> int:
    args = sys.argv[1:]
    if args and args[0] == "--self-test":
        return _self_test()
    skills_dir = Path(args[0]) if args else DEFAULT_SKILLS_DIR
    if not skills_dir.is_dir():
        print(f"error: {skills_dir} is not a directory", file=sys.stderr)
        return 2
    files = sorted(skills_dir.glob("*.md"))
    if not files:
        print(f"warning: no *.md files in {skills_dir}", file=sys.stderr)
        return 0
    failures: dict[str, list[str]] = {}
    for f in files:
        issues = validate_skill_file(f)
        if issues:
            failures[str(f)] = issues
    if failures:
        print(f"FAIL: {len(failures)} of {len(files)} skill files have issues:")
        for path, issues in failures.items():
            print(f"  {path}")
            for issue in issues:
                print(f"    - {issue}")
        return 1
    print(f"OK: all {len(files)} skill files validate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
