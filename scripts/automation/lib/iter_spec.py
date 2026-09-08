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


def _self_test() -> int:
    fails = 0
    for name, (text, want_rc, want_fields) in _FIXTURES.items():
        res = analyze(text)
        rc = 2 if not res["in_scope_present"] else (0 if res["has_implementation_work"] else 1)
        ok = rc == want_rc and all(res.get(k) == v for k, v in want_fields.items())
        print(f"  {'PASS' if ok else 'FAIL'}  {name} (rc={rc}, want {want_rc}; {res})")
        fails += 0 if ok else 1
    print(f"iter_spec self-test: {'OK' if fails == 0 else 'FAILED'} ({len(_FIXTURES) - fails}/{len(_FIXTURES)})")
    return 1 if fails else 0


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] == "has-implementation-work":
        return cmd_has_implementation_work(argv[1])
    if argv and argv[0] == "self-test":
        return _self_test()
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
