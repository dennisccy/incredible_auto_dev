"""
goal_lint.py — deterministic goal.md quality linter (stdlib only).

`validate_goal_file` (run-goal.sh) hard-fails on missing STRUCTURE; this
linter flags QUALITY problems that predict wasted iterations (vague
acceptance criteria are the documented #1 failure mode). It is ADVISORY:
run-goal.sh prints its output behind CHAIN_GOAL_LINT (default true) and
always proceeds (`|| true`) — style must never gate execution. The
/goal-lint command (NEED-4) reuses it against drafts.

Journey blocks are parsed with goal_gate's regexes (imported — one source
of truth, per the writer/reader-drift rule).

Rules — errors (exit 2) are broken machine contracts, warnings (exit 1)
are quality signals:
    ERROR duplicate-id       two journey headers share one J-NN id
                             (journey-history.json is keyed by id)
    ERROR no-journeys        no `- **J-NN` journey blocks found at all
    WARN  journey-shape      journey missing numbered steps (1., 2., ...)
                             or an `Acceptance:` line
    WARN  placeholder        leftover `<...>` template placeholder outside
                             HTML comments / code spans / autolink URLs
    WARN  vague-acceptance   Acceptance line uses a vague term: "works
                             well", "fast", "properly", "intuitive",
                             "user-friendly", "correctly"
    WARN  aspirational-anti-goal  anti-goal bullet with no checkable
                             condition (no prohibition keyword, comparator,
                             or number — an aspiration, not a veto rule)
    WARN  product-shape-empty  >=2 journeys' Acceptance lines share a
                             value/metric phrase (stopword-free adjacent
                             word pair) but the Product Shape section is
                             absent or has no concrete content (an explicit
                             "none" counts as concrete)

Exit codes: 0 clean, 1 warnings only, 2 structural errors (including
unreadable file). Output: one line per finding + a summary; silent when
clean.

CLI:
    python3 goal_lint.py <goal.md>
    python3 goal_lint.py self-test
"""
from __future__ import annotations

import re
import sys
from collections import namedtuple
from pathlib import Path

from goal_gate import _journey_blocks

Finding = namedtuple("Finding", "severity rule line message")  # line: int|None

_NUMBERED_STEP_RE = re.compile(r"^\s*\d+[.)]\s", re.MULTILINE)
_ACCEPTANCE_RE = re.compile(
    r"^\s*(?:[-*]\s*)?(?:\*\*)?Acceptance(?:\*\*)?\s*:", re.IGNORECASE | re.MULTILINE
)
# Template placeholders look like "<observable end state>"; HTML comments and
# code spans are blanked before this runs, autolinks are excluded here.
_PLACEHOLDER_RE = re.compile(r"<(?!https?://|mailto:)[A-Za-z][^<>\n]*>")
# Exactly the spec's vague-term list (NEED-3) — do not grow it casually.
_VAGUE_RE = re.compile(
    r"\b(works\s+well|user[\s-]friendly|fast|properly|intuitive|correctly)\b",
    re.IGNORECASE,
)
# An anti-goal is "checkable" if it prohibits or bounds something: a
# prohibition keyword, a comparator, or a number. Anything else reads as an
# aspiration the evaluator cannot veto on.
_CHECKABLE_RE = re.compile(
    r"\b(no|not|never|none|must|avoid|only|without|disallow(?:ed)?|"
    r"forbid(?:den)?|ban(?:ned)?|excluded?|reject(?:ed)?|refused?|"
    r"skip(?:ped)?|deny|denied|prevent(?:ed)?|block(?:ed)?)\b|\d|[<>≤≥=%]",
    re.IGNORECASE,
)
_ANTI_GOALS_HEAD_RE = re.compile(r"^##\s+Anti-goals\s*$", re.IGNORECASE)
_PRODUCT_SHAPE_HEAD_RE = re.compile(r"^##\s+Product Shape\s*$", re.IGNORECASE)
_H2_RE = re.compile(r"^##\s")

# Words too generic to name a value/metric: articles/prepositions/verbs plus
# UI-navigation vocabulary. Used only by the product-shape heuristic.
_STOPWORDS = frozenset("""
the a an and or of to in on for with is are be at as by it its this that from
into after before then when than there here each every all any some same new
their his her our your user users page pages screen button buttons form forms
click clicks clicking shows show showing displays display displaying displayed
see sees seeing expect expects expected visible appears appear appearing
renders rendered render contains contain containing reads read gains gain
moves move without within via using use should must can will browser app site
tab tabs open opens load loads loaded still now again
""".split())


def _stripped_lines(text: str) -> list[str]:
    """The file's lines with fenced code blocks, inline code spans, and HTML
    comments blanked out. Line count is preserved, so index+1 = line number."""
    out: list[str] = []
    in_fence = False
    in_comment = False
    for raw in text.splitlines():
        if in_fence:
            if raw.lstrip().startswith("```"):
                in_fence = False
            out.append("")
            continue
        if not in_comment and raw.lstrip().startswith("```"):
            in_fence = True
            out.append("")
            continue
        parts: list[str] = []
        j = 0
        while j < len(raw):
            if in_comment:
                end = raw.find("-->", j)
                if end == -1:
                    j = len(raw)
                else:
                    in_comment = False
                    j = end + 3
            else:
                start = raw.find("<!--", j)
                if start == -1:
                    parts.append(raw[j:])
                    break
                parts.append(raw[j:start])
                in_comment = True
                j = start + 4
        out.append(re.sub(r"`[^`]*`", "", "".join(parts)))
    return out


def _acceptance_bigrams(block: str) -> set[str]:
    """Adjacent non-stopword word pairs from a journey block's Acceptance
    line(s) — a deterministic proxy for 'this journey references a named
    value/metric' (e.g. "unread count", "total return")."""
    grams: set[str] = set()
    for line in block.splitlines():
        m = _ACCEPTANCE_RE.match(line)
        if not m:
            continue
        toks = [
            t[:-2] if t.endswith("'s") else t
            for t in re.findall(r"[a-z][a-z'\-]*", line[m.end():].lower())
        ]
        for a, b in zip(toks, toks[1:]):
            if len(a) > 2 and len(b) > 2 and a not in _STOPWORDS and b not in _STOPWORDS:
                grams.add(f"{a} {b}")
    return grams


def lint_text(text: str) -> list[Finding]:
    findings: list[Finding] = []
    lines = _stripped_lines(text)

    blocks = _journey_blocks(text)
    if not blocks:
        return [Finding(
            "ERROR", "no-journeys", None,
            "no '- **J-NN: ...**' journey blocks found — see templates/project-goal.md",
        )]

    def _line_of(char_pos: int) -> int:
        # _JOURNEY_HEADER_RE's leading ^(\s*) may swallow the blank line before
        # the header; advance to the first non-whitespace char (the "-") first.
        while char_pos < len(text) and text[char_pos] in " \t\r\n":
            char_pos += 1
        return text.count("\n", 0, char_pos) + 1

    # duplicate-id (ERROR): journey-history.json and the goal slice key on the id,
    # so a duplicate silently merges two different journeys.
    first_seen: dict[str, int] = {}
    for jid, start, _end in blocks:
        ln = _line_of(start)
        if jid in first_seen:
            findings.append(Finding(
                "ERROR", "duplicate-id", ln,
                f"duplicate journey id '{jid}' (first defined at line {first_seen[jid]})",
            ))
        else:
            first_seen[jid] = ln

    # journey-shape (WARN): the browser-qa agent needs executable numbered
    # steps and an observable end state.
    for jid, start, end in blocks:
        block = text[start:end]
        ln = _line_of(start)
        if not _NUMBERED_STEP_RE.search(block):
            findings.append(Finding(
                "WARN", "journey-shape", ln,
                f"journey {jid} has no numbered steps (1., 2., ...) the browser-qa agent can execute",
            ))
        if not _ACCEPTANCE_RE.search(block):
            findings.append(Finding(
                "WARN", "journey-shape", ln,
                f"journey {jid} has no 'Acceptance:' line describing the observable end state",
            ))

    # placeholder (WARN) — comments/code already blanked in `lines`.
    for i, line in enumerate(lines, 1):
        hits = _PLACEHOLDER_RE.findall(line)
        if hits:
            extra = f" (+{len(hits) - 1} more on this line)" if len(hits) > 1 else ""
            findings.append(Finding(
                "WARN", "placeholder", i,
                f'leftover template placeholder "{hits[0]}"{extra} — replace with real content',
            ))

    # vague-acceptance (WARN) — Acceptance lines only (spec scope).
    for i, line in enumerate(lines, 1):
        if not _ACCEPTANCE_RE.match(line):
            continue
        terms: list[str] = []
        for t in _VAGUE_RE.findall(line):
            t = re.sub(r"\s+", " ", t.lower())
            if t not in terms:
                terms.append(t)
        if terms:
            quoted = ", ".join(f'"{t}"' for t in terms)
            findings.append(Finding(
                "WARN", "vague-acceptance", i,
                f"Acceptance uses vague term(s) {quoted} — state an observable end state instead",
            ))

    # aspirational-anti-goal (WARN) — bullets in the Anti-goals section.
    ag_idx = next((i for i, l in enumerate(lines) if _ANTI_GOALS_HEAD_RE.match(l)), None)
    if ag_idx is not None:
        for i in range(ag_idx + 1, len(lines)):
            line = lines[i]
            if _H2_RE.match(line):
                break
            s = line.strip()
            if not s.startswith("-") or s == "-":
                continue
            body = s.lstrip("-").strip()
            if not body or "TODO" in body or _PLACEHOLDER_RE.search(body):
                continue  # incomplete, not aspirational — placeholder rule owns those
            if not _CHECKABLE_RE.search(body):
                findings.append(Finding(
                    "WARN", "aspirational-anti-goal", i + 1,
                    f'anti-goal "{body}" has no checkable condition — phrase it as a '
                    "veto rule (prohibition or measurable bound)",
                ))

    # product-shape-empty (WARN): >=2 journeys naming the same value/metric is
    # exactly the "same number differs across pages" risk the Product Shape
    # section exists to prevent.
    gram_owners: dict[str, set[str]] = {}
    for jid, start, end in blocks:
        for gram in _acceptance_bigrams(text[start:end]):
            gram_owners.setdefault(gram, set()).add(jid)
    shared = sorted(g for g, owners in gram_owners.items() if len(owners) >= 2)
    if shared:
        ps_idx = next((i for i, l in enumerate(lines) if _PRODUCT_SHAPE_HEAD_RE.match(l)), None)
        has_content = False
        if ps_idx is not None:
            for i in range(ps_idx + 1, len(lines)):
                line = lines[i]
                if _H2_RE.match(line):
                    break
                if line.lstrip().startswith("#"):
                    continue  # ### subheadings are scaffolding, not content
                content = _PLACEHOLDER_RE.sub("", line).strip().strip("-").strip()
                if re.search(r"[A-Za-z0-9]", content):
                    has_content = True
                    break
        if not has_content:
            phrases = ", ".join(f'"{g}"' for g in shared[:3])
            where = ("has no concrete content" if ps_idx is not None
                     else "section is missing")
            findings.append(Finding(
                "WARN", "product-shape-empty",
                ps_idx + 1 if ps_idx is not None else None,
                f">=2 journeys' acceptance criteria reference {phrases} but the "
                f"Product Shape {where} — pin each shared value to one source "
                "(templates/project-goal.md, 'Canonical values')",
            ))

    return findings


# ── output / exit-code plumbing ───────────────────────────────────────────────

def exit_code(findings: list[Finding]) -> int:
    if any(f.severity == "ERROR" for f in findings):
        return 2
    return 1 if findings else 0


def render(findings: list[Finding], path: str) -> str:
    if not findings:
        return ""
    lines = []
    for f in sorted(findings, key=lambda f: (f.line or 0)):
        loc = f" line {f.line}" if f.line else ""
        lines.append(f"[goal-lint] {f.severity} {f.rule}{loc}: {f.message}")
    errors = sum(1 for f in findings if f.severity == "ERROR")
    warns = len(findings) - errors
    lines.append(
        f"[goal-lint] {path}: {errors} error(s), {warns} warning(s) — advisory:"
        " lint never blocks the engine (CHAIN_GOAL_LINT=false to silence)"
    )
    return "\n".join(lines)


def run_lint(path: str) -> int:
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as e:
        print(f"[goal-lint] ERROR unreadable: {path}: {e}")
        return 2
    findings = lint_text(text)
    out = render(findings, path)
    if out:
        print(out)
    return exit_code(findings)


# ── self-test ─────────────────────────────────────────────────────────────────

_CLEAN = """\
# Project Goal

## Vision
A local-first notes app for one user.

## Product Shape

### Navigation / information architecture
- Notes | Archive | Settings

### Canonical values (single source of truth)
- unread count — computed once in lib/counts.py, served from /api/counts

## Must-have user journeys

- **J-01: Create a note**
  - Steps:
    1. Visit `/notes`
    2. Click "New note", type "Milk", press Enter
  - Acceptance: the notes list gains a row titled "Milk" and the unread count reads 1

- **J-02: Archive a note**
  - Steps:
    1. Visit `/notes`
    2. Click the archive icon on the "Milk" row
  - Acceptance: the row moves to the Archive tab and the unread count reads 0

## Anti-goals

- No cloud sync or third-party network calls.
- Never store note bodies outside the local SQLite file.
"""


def _rules(findings: list[Finding]) -> list[str]:
    return [f.rule for f in findings]


def _by_rule(findings: list[Finding], rule: str) -> list[Finding]:
    return [f for f in findings if f.rule == rule]


def _self_test() -> int:
    import contextlib
    import io
    import tempfile

    # 0. clean fixture: no findings, exit 0
    f = lint_text(_CLEAN)
    assert f == [], f"clean fixture must be finding-free, got: {f}"
    assert exit_code(f) == 0

    # 1. duplicate-id → ERROR, exit 2 (second J-01 shadows the first)
    dup = _CLEAN.replace("- **J-02: Archive a note**", "- **J-01: Archive a note**")
    f = lint_text(dup)
    d = _by_rule(f, "duplicate-id")
    assert len(d) == 1 and d[0].severity == "ERROR", f"want 1 duplicate-id ERROR, got: {f}"
    assert "J-01" in d[0].message
    assert d[0].line and dup.splitlines()[d[0].line - 1].startswith("- **J-01: Archive"), \
        "duplicate-id must point at the SECOND occurrence"
    assert exit_code(f) == 2

    # 2. no-journeys → ERROR, exit 2
    f = lint_text("# Goal\n\n## Anti-goals\n\n- No cloud sync.\n")
    assert _rules(f) == ["no-journeys"] and f[0].severity == "ERROR"
    assert exit_code(f) == 2

    # 3. journey-shape: unnumbered steps / missing Acceptance line
    shaped = _CLEAN.replace(
        "  - Steps:\n    1. Visit `/notes`\n    2. Click \"New note\", type \"Milk\", press Enter\n",
        "  - Steps: visit the notes page and add an item called Milk\n",
    )
    f = lint_text(shaped)
    s = _by_rule(f, "journey-shape")
    assert len(s) == 1 and "J-01" in s[0].message and "numbered" in s[0].message, \
        f"comma-list Steps must warn about numbered steps, got: {f}"
    no_acc = _CLEAN.replace(
        "  - Acceptance: the row moves to the Archive tab and the unread count reads 0\n", ""
    )
    f = lint_text(no_acc)
    s = _by_rule(f, "journey-shape")
    assert len(s) == 1 and "J-02" in s[0].message and "Acceptance" in s[0].message, \
        f"journey without Acceptance line must warn, got: {f}"
    assert exit_code(f) == 1

    # 4. placeholder: template leftovers flagged; comments/code/autolinks exempt
    ph = _CLEAN.replace(
        "- **J-02: Archive a note**",
        "- **J-02: <next journey>**",
    ).replace(
        "  - Acceptance: the row moves to the Archive tab and the unread count reads 0",
        "  - Acceptance: <observable end state>",
    )
    f = lint_text(ph)
    p = _by_rule(f, "placeholder")
    assert len(p) == 2, f"want 2 placeholder warnings, got: {f}"
    assert any("<next journey>" in x.message for x in p)
    assert any("<observable end state>" in x.message for x in p)
    exempt = _CLEAN + (
        "\n## Notes\n\n"
        "<!-- guidance: fill <this> in later -->\n"
        "Autolink <https://example.com> and code `List<int>` stay legal.\n"
        "```\n<div>fenced html</div>\n```\n"
    )
    assert lint_text(exempt) == [], "comments/code/autolinks must not trip the placeholder rule"

    # 5. vague-acceptance: spec's six terms, word-boundary, Acceptance lines only
    vague = _CLEAN.replace(
        "  - Acceptance: the notes list gains a row titled \"Milk\" and the unread count reads 1",
        "  - Acceptance: search works well and feels fast",
    )
    f = lint_text(vague)
    v = _by_rule(f, "vague-acceptance")
    assert len(v) == 1 and "works well" in v[0].message and "fast" in v[0].message, \
        f"want one vague-acceptance naming both terms, got: {f}"
    boundary = _CLEAN.replace(
        "  - Acceptance: the notes list gains a row titled \"Milk\" and the unread count reads 1",
        "  - Acceptance: the breakfast menu lists 3 items",
    )
    assert _by_rule(lint_text(boundary), "vague-acceptance") == [], \
        '"breakfast" must not match "fast" (word boundary)'
    prose = _CLEAN.replace(
        "A local-first notes app for one user.",
        "A fast, intuitive notes app that works well for one user.",
    )
    assert _by_rule(lint_text(prose), "vague-acceptance") == [], \
        "vague terms outside Acceptance lines are not this rule's business"

    # 6. aspirational-anti-goal: no prohibition/number/comparator → warn
    asp = _CLEAN.replace(
        "- No cloud sync or third-party network calls.",
        "- Delightful, polished experience.",
    )
    f = lint_text(asp)
    a = _by_rule(f, "aspirational-anti-goal")
    assert len(a) == 1 and "Delightful" in a[0].message, f"aspiration must warn, got: {f}"
    ok = _CLEAN.replace(
        "- No cloud sync or third-party network calls.",
        "- p95 page load stays under 200 ms.",
    )
    assert _by_rule(lint_text(ok), "aspirational-anti-goal") == [], \
        "a numeric bound is checkable — no warning"
    todo = _CLEAN.replace(
        "- No cloud sync or third-party network calls.",
        "- TODO: decide licensing rules.",
    )
    assert _by_rule(lint_text(todo), "aspirational-anti-goal") == [], \
        "TODO bullets are incomplete, not aspirational — skip them"

    # 7. product-shape-empty: shared acceptance phrase + no concrete shape content
    empty_shape = _CLEAN.replace(
        "- Notes | Archive | Settings",
        "- <e.g., Dashboard | Strategies | Settings>",
    ).replace(
        "- unread count — computed once in lib/counts.py, served from /api/counts",
        "- <e.g., total return — computed once, displayed everywhere>",
    )
    f = lint_text(empty_shape)
    ps = _by_rule(f, "product-shape-empty")
    assert len(ps) == 1 and "unread count" in ps[0].message, \
        f"shared 'unread count' + placeholder-only shape must warn, got: {f}"
    absent = re.sub(
        r"## Product Shape.*?(?=## Must-have)", "", _CLEAN, flags=re.DOTALL
    )
    f = lint_text(absent)
    ps = _by_rule(f, "product-shape-empty")
    assert len(ps) == 1 and "unread count" in ps[0].message, \
        f"absent Product Shape section must warn the same way, got: {f}"
    distinct = absent.replace(
        "  - Acceptance: the row moves to the Archive tab and the unread count reads 0",
        "  - Acceptance: the row moves to the Archive tab and vanishes from Notes",
    )
    assert _by_rule(lint_text(distinct), "product-shape-empty") == [], \
        "no shared value/metric phrase → empty shape is fine (section is optional)"
    # clean fixture already covers: shared phrase + concrete content → no warning

    # 8. file-level exit codes through run_lint
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)

        def _run(path: str) -> tuple[int, str]:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = run_lint(path)
            return rc, buf.getvalue()

        (d / "clean.md").write_text(_CLEAN, encoding="utf-8")
        rc, out = _run(str(d / "clean.md"))
        assert rc == 0 and out == "", f"clean file must be silent rc=0, got rc={rc} out={out!r}"

        (d / "warn.md").write_text(vague, encoding="utf-8")
        rc, out = _run(str(d / "warn.md"))
        assert rc == 1 and "WARN vague-acceptance" in out and "advisory" in out, \
            f"warn file must rc=1 with advisory summary, got rc={rc} out={out!r}"

        (d / "dup.md").write_text(dup, encoding="utf-8")
        rc, out = _run(str(d / "dup.md"))
        assert rc == 2 and "ERROR duplicate-id" in out

        rc, out = _run(str(d / "missing.md"))
        assert rc == 2 and "unreadable" in out

    print("self-test passed")
    return 0


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__, file=sys.stderr)
        return 2
    if argv[0] == "self-test":
        return _self_test()
    return run_lint(argv[0])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
