#!/usr/bin/env python3
"""prompt_quote_lint.py — an agent prompt passed as `-p "<...>"` must reach the agent as ONE word.

Why: the engine builds agent prompts as multi-line bash double-quoted strings
(`claude_with_quota_retry -p "…" || rc=$?`). An unescaped `"` inside that text closes
the string early; bash then glues the next characters onto the prompt and splits the
remainder into stray argv words, so the agent silently receives a truncated prompt.
run-phase.sh's orchestrator prompt lost every line after
`Write this as a plain inline line "Frontend Present: yes"…` — the plan contract's
items 4-6 and "Keep it concise" never reached the orchestrator (goal-taketwo iter 13,
2026-09-23; the orchestrator noticed the dangling sentence and recovered it from the
script source).

Check (static, no execution): for every `-p "` argument in the scanned scripts, walk
the double-quoted word the way bash does — backslash escapes, `$(…)` / `` `…` `` command
substitutions (their inner quotes are a fresh context), `${…}` — find where the word
really ends, and require that end to be followed by a command separator
(`||`, `&&`, `;`, `|`, `)`, a redirection, or end of line). Anything else means the
prompt was split.

Usage:
  prompt_quote_lint.py check <script.sh> [...]   exit 0 clean, 1 violations (printed)
  prompt_quote_lint.py check-engine              check scripts/automation/*.sh and lib/*.sh
  prompt_quote_lint.py self-test
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

# Only agent invocations: the retry wrappers and a bare `claude -p` (never `mkdir -p`).
_START_RE = re.compile(r"(?:^|[\s;(|&])(?:claude_with_quota_retry|agent_with_quota_retry|claude)\s+-p\s+\"")
# After the prompt word: a separator, a redirection, end of line, a `\`-newline
# continuation, or another flag.
_OK_AFTER_RE = re.compile(r"[ \t]*(?:\|\||&&|;|\||\)|[0-9]?>|<|$|\n|#|\\\n|--?[A-Za-z])")


def _skip_dq(text: str, i: int) -> int:
    """text[i] is just after an opening double quote. Return the index just after
    its closing quote (or len(text) if unterminated)."""
    n = len(text)
    while i < n:
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == '"':
            return i + 1
        if c == "`":
            i = _skip_backtick(text, i + 1)
            continue
        if c == "$" and i + 1 < n and text[i + 1] == "(":
            i = _skip_paren(text, i + 2)
            continue
        if c == "$" and i + 1 < n and text[i + 1] == "{":
            i = _skip_brace(text, i + 2)
            continue
        i += 1
    return n


def _skip_backtick(text: str, i: int) -> int:
    n = len(text)
    while i < n:
        if text[i] == "\\":
            i += 2
            continue
        if text[i] == "`":
            return i + 1
        i += 1
    return n


def _skip_brace(text: str, i: int) -> int:
    depth, n = 1, len(text)
    while i < n and depth:
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == '"':
            i = _skip_dq(text, i + 1)
            continue
        if c == "'":
            j = text.find("'", i + 1)
            i = n if j < 0 else j + 1
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
        i += 1
    return i


def _skip_paren(text: str, i: int) -> int:
    """Inside `$(`: a fresh shell context — quotes nest, parens balance."""
    depth, n = 1, len(text)
    while i < n and depth:
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == '"':
            i = _skip_dq(text, i + 1)
            continue
        if c == "'":
            j = text.find("'", i + 1)
            i = n if j < 0 else j + 1
            continue
        if c == "`":
            i = _skip_backtick(text, i + 1)
            continue
        if c == "$" and i + 1 < n and text[i + 1] == "(":
            i = _skip_paren(text, i + 2)
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        i += 1
    return i


def violations(text: str) -> "list[tuple[int, str]]":
    """(line number of the `-p "`, text after the premature close) per split prompt."""
    out: list[tuple[int, str]] = []
    for m in _START_RE.finditer(text):
        # Skip matches inside a comment line.
        line_start = text.rfind("\n", 0, m.start()) + 1
        if text[line_start:m.start()].lstrip().startswith("#"):
            continue
        end = _skip_dq(text, m.end())
        if end >= len(text):
            out.append((text.count("\n", 0, m.start()) + 1, "<unterminated prompt>"))
            continue
        if not _OK_AFTER_RE.match(text, end):
            tail = text[end:end + 60].split("\n", 1)[0]
            out.append((text.count("\n", 0, m.start()) + 1, tail))
    return out


def cmd_check(paths: "list[str]") -> int:
    bad = 0
    for p in paths:
        for line, tail in violations(Path(p).read_text(encoding="utf-8")):
            print(f"{p}:{line}: agent prompt ends early — an unescaped \" splits it; text after the close: {tail!r}")
            bad += 1
    if not bad:
        print(f"prompt_quote_lint: {len(paths)} script(s) clean")
    return 1 if bad else 0


def _self_test() -> int:
    cases = [
        ('claude_with_quota_retry -p "one\nline two" || rc=$?\n', 0, "clean multi-line prompt"),
        ('claude_with_quota_retry -p "a \\"quoted\\" word\nmore" || rc=$?\n', 0, "escaped inner quotes"),
        ('claude_with_quota_retry -p "a $( [[ -n "$V" ]] && echo "v=$V" ) b" || rc=$?\n', 0, "quotes inside $() are a fresh context"),
        ('claude_with_quota_retry -p "a ${X:-"d"} b"\n', 0, "quotes inside ${} default"),
        ('claude_with_quota_retry -p "plain inline line "Frontend Present: yes" or no\nmore." || rc=$?\n', 1, "the iter-13 orchestrator bug"),
        ('claude_with_quota_retry -p "a "b" c" || rc=$?\n', 1, "word continues after an inner close"),
        ('# comment: -p "a "b" c"\n', 0, "comment lines are ignored"),
        ('claude_with_quota_retry -p "never closed\n', 1, "unterminated prompt"),
        ('claude -p "ok" 2>&1 | tee log\n', 0, "redirection after the prompt"),
        ('claude_with_quota_retry -p "$P" \\\n  --model x\n', 0, "continuation line with flags"),
        ('claude -p "ok" --output-format json\n', 0, "flag after the prompt"),
        ('mkdir -p "$a" "$b"\n', 0, "mkdir -p is not an agent prompt"),
    ]
    failed = 0
    for text, want, label in cases:
        got = len(violations(text))
        ok = got == want
        failed += not ok
        print(("  PASS  " if ok else "  FAIL  ") + f"{label} (violations={got}, want {want})")
    print(f"prompt_quote_lint self-test: {'OK' if not failed else f'{failed} FAILED'}")
    return 1 if failed else 0


def main(argv: "list[str]") -> int:
    if argv[:1] == ["self-test"]:
        return _self_test()
    if len(argv) >= 2 and argv[0] == "check":
        return cmd_check(argv[1:])
    if argv == ["check-engine"]:
        lib = Path(__file__).resolve().parent
        return cmd_check(sorted(str(p) for p in [*lib.parent.glob("*.sh"), *lib.glob("*.sh")]))
    print(__doc__.split("Usage:")[1].strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
