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
                             [--side-effects LEDGER] [--side-effects-build-id ID]
                             [--strict-side-effects] [--makeup-journeys J-01,J-02]
        exit 0  clean, or warnings only
        exit 1  at least one deterministic ERROR — the spec must not dispatch
        exit 2  unreadable spec (the caller fails closed; see run-goal.sh's
                CHAIN_SPEC_LINT block mode)
        stdout  one `[spec-lint] ERROR|WARN <rule>: <msg>` line per finding.
        HARD-3: `Side-effect policy` is a machine field (E02/E06/W02 always run;
        a near-miss label such as `Side effect policy:` or `* **Side-effect
        policy:**` is E02, never a silently absent policy).
        With --side-effects (the engine's iter-<N>/side-effects.json ledger,
        lib/goal_gate.py side-effects) the contradiction preflight also runs over
        targets ∪ required ∪ make-up journeys: E13 (policy none vs a MUTATING
        journey), E15 (policy none but the ledger is unavailable, incomplete or
        — with --side-effects-build-id — not this run's build: fail closed,
        never re-planned), E16 (an explicit no-mutation prohibition in OUT OF
        SCOPE, DEFINITION OF DONE or a TC- line outside GOAL/BACKGROUND/NOTES vs
        a MUTATING journey — whatever the policy says), W09/W10 (unknown
        journeys under policy none / under a prohibition; E14 with
        --strict-side-effects), W11 (ledger unavailable under an allowed or
        absent policy).

    iter_spec.py side-effect-context --mode lane|evaluator|decomposer
                             --side-effects LEDGER [--spec P] [--makeup-journeys CSV]
                             [--lane-kind lean|full]
        exit 0 always. Prints the engine-built side-effect prompt context, or
        NOTHING when no context applies (lane/evaluator prompts then stay
        byte-identical): a lane/evaluator block needs a readable ledger AND a
        declared policy or a MUTATING journey in the spec's journey set.

    iter_spec.py policy-intent <spec>
        prints `none` when the spec states a restrictive side-effect policy in
        any readable-to-a-human form, else the canonical value; exit 2 when the
        spec is unreadable.

    iter_spec.py ledger-ok <ledger> [--build-id ID]
        exit 0 only for an available, complete ledger of that build.

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

import bisect
import json
import re
import sys
import unicodedata

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
    "side_effect_policy": "Side-effect policy",
    "frontend_present": "Frontend Present",
}
# Fields whose canonical form the lint enforces (E02). Session ID / Iteration /
# Full trigger / Frontend Present are informational and are not bold-enforced.
_BOLD_ENFORCED = ("depth", "target_journeys", "required_journeys", "work_kind", "side_effect_policy")

_VALID_DEPTH = ("lean", "full", "evidence")
_VALID_WORK_KIND = ("implementation", "evidence-only", "verify-only")
# HARD-3: `none` = no target/required journey executed this iteration mutates
# persisted state; `allowed` = journey mutations are expected (TCs must then be
# invariants on PRE-EXISTING rows). Absent = unspecified (W02).
_VALID_POLICY = ("none", "allowed")
_VALID_MODE = ("baseline", "next")
_JOURNEY_ID_RE = re.compile(r"J-\d+")
# Operator-only lines the decomposer may never write but a RESUMED spec may
# legitimately carry — never a lint finding (plan WP2 "explicit non-rule").
_OPERATOR_ONLY = ("Depth enforcement", "Maintenance isolation")


# Accepted alternate spellings, tried after the canonical label. The engine's
# pre-HARD-2 greps matched a PREFIX, so specs in the wild (and fixtures) carry
# `- **Required-still-passing:** J-02` without the trailing word. The canonical
# parser must read those too, or a valid legacy spec would silently lose its
# required-journey list.
_FIELD_ALIASES_LABELS: dict[str, tuple[str, ...]] = {
    "required_journeys": ("Required-still-passing",),
}


def _field_patterns(label: str) -> tuple[re.Pattern[str], re.Pattern[str]]:
    esc = re.escape(label)
    bold = re.compile(rf"^[ \t]*-?[ \t]*\*\*{esc}:\*\*[ \t]*(.*?)[ \t]*$", re.M | re.I)
    plain = re.compile(rf"^[ \t]*-?[ \t]*{esc}:[ \t]*(.*?)[ \t]*$", re.M | re.I)
    return bold, plain


# The canonical metadata section, bounded by the next H2 or EOF. A machine field
# counts ONLY inside it: a `- **Depth:** lean` line under OUT OF SCOPE, NOTES, a
# DoD item or a TC example is prose about the iteration, not machine state, and
# the governed document must not be able to satisfy or override a machine field
# by repeating it elsewhere (anti-pattern 25).
_H2_BLOCK_RE = re.compile(r"^##\s+(?P<title>.*?)[ \t]*$(?P<body>.*?)(?=^##\s|\Z)", re.S | re.M)


def metadata_section(spec_text: str) -> tuple[str, int]:
    """(body of the canonical metadata section, how many such sections exist)."""
    bodies = [m.group("body") for m in _H2_BLOCK_RE.finditer(spec_text)
              if m.group("title").strip().lower() == _METADATA_H2]
    return (bodies[0] if bodies else ""), len(bodies)


def read_metadata(spec_text: str) -> dict:
    """Deterministic read of the spec's machine fields. Never raises."""
    h2s = [m.group(1).strip() for m in _H2_LINE_RE.finditer(spec_text)]
    section, section_count = metadata_section(spec_text)
    values: dict[str, str | None] = {}
    bold: dict[str, bool] = {}
    present: dict[str, bool] = {}
    # Per field: every occurrence INSIDE the metadata section, bold and plain.
    # More than one distinct value is a conflict the engine refuses to resolve
    # by regex order (E12); the parsed value stays deterministic (bold first,
    # then first occurrence) so the report is reproducible.
    conflicts: dict[str, list[str]] = {}
    misplaced: list[str] = []
    shadowed: list[str] = []
    for key, label in _FIELDS.items():
        b_re, p_re = _field_patterns(label)
        b_hits = [m.group(1).strip() for m in b_re.finditer(section)]
        p_hits = [m.group(1).strip() for m in p_re.finditer(section)]
        for alt in _FIELD_ALIASES_LABELS.get(key, ()):
            if b_hits or p_hits:
                break
            ab_re, ap_re = _field_patterns(alt)
            b_hits = [m.group(1).strip() for m in ab_re.finditer(section)]
            p_hits = [m.group(1).strip() for m in ap_re.finditer(section)]
            if b_hits or p_hits:
                b_re, p_re = ab_re, ap_re      # so the outside-scan uses the same label
        distinct = []
        for v in b_hits + p_hits:
            n = v.strip().strip("*").strip().lower()
            if n not in distinct:
                distinct.append(n)
        if len(distinct) > 1:
            conflicts[key] = distinct
        outside_txt = spec_text.replace(section, "\n") if section else spec_text
        if b_hits or p_hits:
            # Declared canonically AND repeated outside: the outside copy is
            # prose with zero runtime influence, but say so — a reader should
            # not have to guess which line the engine obeyed.
            if b_re.search(outside_txt) or p_re.search(outside_txt):
                shadowed.append(key)
        if b_hits:
            values[key], bold[key], present[key] = b_hits[0], True, True
        elif p_hits:
            values[key], bold[key], present[key] = p_hits[0], False, True
        else:
            values[key], bold[key], present[key] = None, False, False
            # A machine field that exists ONLY outside the canonical section is
            # MISPLACED, not absent — say so, so the author is not told to add a
            # line the document already contains.
            if b_re.search(outside_txt) or p_re.search(outside_txt):
                misplaced.append(key)

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
        "metadata_section_present": section_count > 0,
        "metadata_section_count": section_count,
        "field_conflicts": conflicts,
        "fields_outside_section": misplaced,
        "fields_shadowed_outside": shadowed,
        "h2_sections": h2s,
        "mode": _norm(values.get("mode")),
        "depth": _norm(values.get("depth")),
        "work_kind": _norm(values.get("work_kind")),
        "side_effect_policy": _norm(values.get("side_effect_policy")),
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
    "E06": "policy-invalid",                                  # HARD-3
    "E07": "evidence-with-implementation",
    "E08": "verify-only-with-implementation",
    "E09": "baseline-with-implementation",
    "E10": "evidence-after-escalate",
    "E11": "evidence-target-not-passing",
    "E12": "metadata-field-conflict",
    # HARD-3 contradiction preflight (need the engine's side-effect ledger).
    "E13": "policy-none-vs-mutating-journey",
    "E14": "unknown-journey-under-strict-side-effects",
    "E15": "policy-none-ledger-unavailable",
    "E16": "explicit-prohibition-vs-mutating-journey",
    "W01": "workkind-missing",
    "W02": "policy-missing",                                  # HARD-3
    "W03": "targets-line-absent",
    "W04": "lean-after-escalate",
    "W05": "contract-additions-without-bullets",
    "W06": "loose-in-scope-bullets",
    "W07": "sentinel-spec",
    "W08": "full-without-trigger",
    "W09": "policy-none-with-unknown-journeys",               # HARD-3
    "W10": "prohibition-with-unknown-journeys",               # HARD-3
    "W11": "side-effect-ledger-unavailable",                  # HARD-3
    "W12": "field-shadowed-outside-metadata",
}

# A loose bullet directly under `## IN SCOPE` is ambiguous: legacy baseline specs
# describe themselves there ("- verify-only baseline"), while an actionable
# instruction ("- change users.py so login persists the token") is real work that
# a baseline / verify-only / evidence spec must not smuggle past the halting
# rules. The allowlist is anchored, small and closed: a bullet is DESCRIPTIVE
# only if it opens with iteration-meta vocabulary AND carries no code marker.
# Anything else counts as work — unknown text is treated as actionable, so the
# governor is never widened by a phrasing it has not seen.
_DESCRIPTIVE_LOOSE_RE = re.compile(
    r"""^[("'`*\[]*\s*(verify-only|evidence-only|verification|verify|evidence|baseline"""
    r"""|capture|capturing|record|recording|re-?record|screenshot|screenshots|demo"""
    r"""|walkthrough|confirm|confirmation|observe|observation|smoke|sanity|read-only"""
    r"""|no-op|noop)\b""",
    re.I,
)
# A construction verb ANYWHERE in the bullet makes it actionable, whatever it
# opens with. Without this, a descriptive opener hid a real instruction:
# "review the authentication flow AND CHANGE login behavior to persist tokens"
# was exempted as harmless baseline prose.
# The ONE proven-necessary legacy shape: a baseline spec describing itself, with
# an optional parenthetical note. Checked BEFORE the construction-verb test so a
# fixture like "verify-only baseline (iteration-state wiring test)" stays
# compatible WITHOUT having to exempt the words `wiring`/`writing` generally.
# Deliberately exact: it matches this shape and nothing else.
_LEGACY_DESCRIPTOR_RE = re.compile(
    r"""^[("'`*\[]*\s*verify-only\s+baseline\s*(\([^)]*\))?\s*\.?\s*$""", re.I)

_CONSTRUCTION_VERB_RE = re.compile(
    r"\b(add|adds|adding|change|changes|changing|update|updates|updating"
    r"|implement|implements|implementing|create|creates|creating"
    r"|modify|modifies|modifying|fix|fixes|fixing|rewrite|rewrites|rewriting"
    r"|persist|persists|persisting|remove|removes|removing|delete|deletes|deleting"
    r"|refactor|refactors|refactoring|introduce|introduces|introducing"
    r"|build|builds|building|migrate|migrates|migrating"
    r"|rename|renames|renaming|replace|replaces|replacing|extend|extends|extending"
    r"|install|installs|installing|configure|configures|configuring"
    r"|write|writes|writing|wire|wires|wiring)\b",
    re.I,
)
# `write`/`wire` are full construction verbs. The only phrase that needed them
# exempted is the exact legacy descriptor above, which is matched first, so
# "verify the login flow by writing persistent session state" and "confirm the
# feature by wiring token persistence" are correctly actionable.
_CODE_MARKER_RE = re.compile(r"[`/]|\b\w+\.(py|ts|tsx|js|jsx|sh|json|md|sql|ya?ml|css|html)\b|::")


def _actionable_loose_bullets(spec_text: str) -> list[str]:
    """Loose `## IN SCOPE` bullets that read as construction, not description."""
    m = _IN_SCOPE_RE.search(spec_text)
    if not m:
        return []
    out = []
    for line in m.group(1).splitlines():
        if _H3_RE.match(line):
            break                     # loose region ends at the first sub-heading
        if not _is_concrete_bullet(line):
            continue
        txt = _BULLET_RE.match(line).group(1).strip()
        # The exact legacy descriptor is compatibility surface, whatever words it
        # happens to contain.
        if _LEGACY_DESCRIPTOR_RE.match(txt):
            continue
        # Otherwise descriptive ONLY when all three hold: it opens with closed-set
        # capture/verification vocabulary, names no code artefact, and contains
        # no construction verb anywhere. Unknown phrasing is actionable, so the
        # exemption can never be widened by wording the classifier has not seen.
        if (_DESCRIPTIVE_LOOSE_RE.match(txt)
                and not _CODE_MARKER_RE.search(txt)
                and not _CONSTRUCTION_VERB_RE.search(txt)):
            continue
        out.append(txt)
    return out


_DATA_CONTRACT_RE = re.compile(r"^###\s+Data-contract additions\s*$(.*?)(?=^###\s|^##\s|\Z)", re.S | re.M | re.I)


class HistoryUnusable(Exception):
    """The independent journey-history input could not be verified.

    NEVER conflated with "no failing target": an empty result means every target
    is recorded passing, so a corrupt, unreadable or wrongly-shaped history must
    raise instead of returning []. Callers turn this into an input/runtime
    verification failure (exit 2), which CHAIN_SPEC_LINT=block fails closed on
    before any dispatch — not into a clean lint.
    """


def _passing_targets(history_path: str, targets: list[str]) -> list[str]:
    """Target ids NOT recorded passing. Raises HistoryUnusable if it cannot tell."""
    try:
        with open(history_path, encoding="utf-8") as fh:
            hist = json.load(fh)
    except OSError as exc:
        raise HistoryUnusable(f"cannot read {history_path}: {exc}") from exc
    except ValueError as exc:
        raise HistoryUnusable(f"{history_path} is not valid JSON: {exc}") from exc
    if not isinstance(hist, dict):
        raise HistoryUnusable(f"{history_path}: top level is {type(hist).__name__}, expected an object")
    journeys = hist.get("journeys")
    if not isinstance(journeys, dict):
        raise HistoryUnusable(
            f"{history_path}: 'journeys' is {type(journeys).__name__}, expected an object")
    bad = []
    for jid in targets:
        j = journeys.get(jid)
        if j is None:
            bad.append(jid)          # absent = not recorded passing (a real contradiction)
            continue
        if not isinstance(j, dict) or not isinstance(j.get("status"), str):
            raise HistoryUnusable(
                f"{history_path}: journey {jid} has no usable status field")
        if j["status"] not in ("passing", "already_passing"):
            bad.append(jid)
    return bad


# ── HARD-3: side-effect contradiction preflight ─────────────────────────────
# The spec's machine policy and its explicit deterministic mutation constraints
# must agree with the journeys it executes BEFORE any browser dispatch. The
# journey statuses come from the engine-built ledger (lib/goal_gate.py
# side-effects): owner declaration in docs/goal.md + replay observation, with an
# observed mutation always outranking a `none` declaration. The policy line can
# only ADD a contradiction (E13/E15) — it can never excuse one (E16 ignores it).
_SIDE_EFFECT_STATUSES = ("none", "mutating", "unknown")
# Any label a reader would take for the policy field — spaces, ASCII or Unicode
# hyphens/dashes (U+2010–U+2015, U+2212, soft hyphen) or underscores between the
# words, singular or plural.
_POLICY_LABEL = r"side[\s\-_\u2010-\u2015\u2212\u00ad]*effects?[\s\-_\u2010-\u2015\u2212\u00ad]*polic(?:y|ies)"

# Explicit no-mutation prohibitions (plan WP3, matched case-insensitively, one
# finding per line) — scanned ONLY in `## OUT OF SCOPE` and `## DEFINITION OF
# DONE` (heading suffixes such as "(this iteration)" or "(DoD)" allowed) and on
# `TC-<n>` lines (bullet, numbered, checkbox or table form, continuation lines
# included) outside the prose sections. GOAL / BACKGROUND / NOTES prose — where
# a re-planned spec naturally explains what an earlier TC said — is never a
# machine constraint, and neither is the metadata section.
# (name, pattern, where, qualified): `where` "any" = every scanned line, "oos" =
# only an OUT OF SCOPE line. `qualified` = a row count qualified DIRECTLY as
# "pre-existing (ledger) row count" is an invariant, not a prohibition.
_PROHIBITION_RES: tuple = (
    ("row-count-unchanged",
     re.compile(r"\b(?:row|record|ledger)s?\s+count\s+(?:(?:must|should|will|shall)\s+)?"
                r"(?:(?:is|be|stays?|remains?|was)\s+)?(?:unchanged|the\s+same)\b"
                r"|\b(?:row|record|ledger)s?\s+count\s+(?:does\s+not|doesn't|must\s+not|should\s+not)\s+change\b"
                r"|\bnumber\s+of\s+(?:ledger\s+)?(?:rows|records|runs|entries)\s+"
                r"(?:(?:is|stays|remains|must\s+(?:stay|remain|be))\s+)?(?:unchanged|the\s+same)\b", re.I),
     "any", True),
    ("no-new-row-run-record",
     re.compile(r"\bno\s+new\s+(?:[\w-]+\s+){0,2}?(?:rows?|runs?|records?|ledger\s+(?:rows?|entry|entries))\b", re.I),
     "any", False),
    ("ledger-unchanged",
     re.compile(r"\bledger\s+(?:(?:is|stays|remains)\s+)?(?:left\s+)?(?:unchanged|frozen|untouched)\b", re.I),
     "any", False),
    ("must-not-mutate",
     re.compile(r"\bmust\s+not\s+(?:create|launch|append|write)\b"
                r"|\bmust\s+not\s+(?:start|trigger)\s+(?:a\s+|any\s+)?(?:new\s+)?(?:[\w-]+\s+)?runs?\b", re.I),
     "any", False),
    ("no-write-mutation-launch",
     re.compile(r"\bno\s+(?:writes?|mutations?|launch(?:es)?)\b(?![-\w])", re.I), "any", False),
    ("any-new-run-launch",
     re.compile(r"\bany\s+new\s+(?:[\w-]+\s+){0,3}?run\s+launch(?:es)?\b", re.I), "any", False),
    # Listed as a noun at the start of an OUT OF SCOPE item: "New run launches",
    # "New ledger rows", "Ledger row edits or …".
    ("out-of-scope-new-run-or-row",
     re.compile(r"^[\W_]*(?:\d+[.)]\s+)?(?:any\s+)?(?:new\s+(?:[\w-]+\s+){0,2}?runs?\s+launch(?:es)?|new\s+ledger\s+(?:rows?|entries"
                r"|records)|ledger[\s-]+(?:row|entry|record)s?\s+(?:edits?|changes?|deletions?|writes?|updates?"
                r"|additions?))\b", re.I),
     "oos", False),
)
_PRE_EXISTING_ROWS_RE = re.compile(r"\bpre-?existing\s+(?:ledger\s+)?$", re.I)
# "no run is launched / created", "no ledger rows are created" (the TenSteps
# iteration-7/8 wording) — a prohibition, except in a negative-path test.
_PASSIVE_NONE_RE = re.compile(
    r"\bno\s+(?:runs?|ledger\s+(?:rows?|records?|entry|entries))\s+(?:(?:is|are|was|were|gets?|got)\s+"
    r"|(?:will|shall|should|must|may|can)\s+be\s+)(?:launched|started|triggered|created|kicked\s+off|added"
    r"|appended|written|inserted)\b", re.I)

# Two ACTIVITIES — creating/editing/deleting/writing/appending/adding/inserting
# ledger rows, and launching/starting/triggering a new run — are decided by one
# rule the decomposer contract states word for word:
#   * on an OUT OF SCOPE item, naming the activity is a prohibition;
#   * on a TC or DEFINITION OF DONE item, a SENTENCE that names the activity and
#     contains any negation (no, not, n't, never, nor, neither, none, nothing,
#     nobody, without, cannot, avoid, refrain, prevent, prohibit, forbid,
#     disallow, exclude, except, out of scope) is a prohibition — wherever the
#     negation stands in the sentence;
#   * the one exception is a negation whose object is qualified "pre-existing"
#     ("no pre-existing ledger row is edited", "… must not modify any
#     pre-existing row") — the invariant wording the fix text asks for — unless
#     the activity is joined to that object by "or" / "nor" ("must not edit
#     pre-existing rows or launch a new run");
#   * idioms that negate nothing ("not only", "whether or not") are not
#     negations; a sentence that states a refused request ("… responds 400 …", "…
#     is rejected", "given an invalid …") is a negative-path assertion, not a
#     prohibition.
# A sentence ends at . ; ! or ? (not inside an abbreviation or a number); an
# item's wrapped continuation lines are part of it. The rule errs toward
# reporting: a false positive costs a rewrite the E16 text spells out, a false
# negative lets the contradiction through.
_RE_PREFIX = r"(?:\(re\))?\b(?:re-?)?"
_LEDGER_TAIL = r"\b(?!-)[^.;:!?]{0,60}?\bledger\s+(?:rows?|entries|records)\b"   # not "append-only"
_LEDGER_VERBS = (r"(?:creat(?:e|es|ing)|edit(?:s|ing)?|delet(?:e|es|ing)|writ(?:e|es|ing)|append(?:s|ing)?"
                 r"|add(?:s|ing)?|insert(?:s|ing)?)")
_RUN_VERBS = r"(?:launch(?:es|ing)?|start(?:s|ing)?|trigger(?:s|ing)?)"
_RUN_TAIL = (r"(?!-)\s+(?:(?:\([^()]{0,60}\)|,[^,.;:!?]{0,40},|[\u2013\u2014][^\u2013\u2014.;:!?]{0,40}[\u2013\u2014])\s*)?"
             r"(?:of\s+)?(?:[\w-]+\s+){0,2}?new\s+(?:[\w-]+\s+){0,2}?runs?\b")
_ACTIVITY_RES: tuple = (
    # (name, the activity anywhere, the form an OUT OF SCOPE item lists). An OUT
    # OF SCOPE item lists a ledger activity as a gerund or as an imperative that
    # opens the item ("- Create or edit ledger rows"); elsewhere there a base form
    # is usually a noun ("an edit affordance for ledger rows").
    ("ledger-row-edit",
     re.compile(_RE_PREFIX + _LEDGER_VERBS + _LEDGER_TAIL, re.I),
     re.compile(r"(?:(?:\(re\))?\b(?:re-?)?creating|\b(?:editing|deleting|writing|appending|adding|inserting))"
                + _LEDGER_TAIL + r"|^[\W_]*(?:\d+[.)]\s+)?(?:re-?)?(?:create|edit|delete|write|append|add|insert)"
                r"(?:\s+(?:or|and|a|an|any|the|new|more|extra|additional|(?:re-?)?(?:create|edit|delete|write|append"
                r"|add|insert)))*\s+ledger\s+(?:rows?|entries|records)\b", re.I)),
    ("any-new-run-launch",
     re.compile(_RE_PREFIX + _RUN_VERBS + _RUN_TAIL, re.I),
     re.compile(_RE_PREFIX + _RUN_VERBS + _RUN_TAIL, re.I)),
)
_ACTIVITY_START_RE = re.compile(_RE_PREFIX + r"(?:" + _LEDGER_VERBS + r"|" + _RUN_VERBS + r")\b", re.I)
_NEG_CUE_RE = re.compile(
    r"\b(?:no\s+one|no|not|never|nor|neither|none|nothing|nobody|without|cannot|[a-z]+n't|avoid(?:s|ed|ing)?"
    r"|refrain(?:s|ed|ing)?|prevent(?:s|ed|ing)?|prohibit(?:s|ed|ing)?|forbid(?:s|den|ding)?"
    r"|disallow(?:s|ed|ing)?|exclud(?:e|es|ed|ing)|except|out\s+of\s+scope)\b", re.I)
_IDIOM_BEFORE_RE = re.compile(r"\b(?:or|if|whether)\s*$", re.I)                    # "or not", "if not"
_IDIOM_AFTER_RE = re.compile(r"^\s*(?:only|just|merely|least|doubt|matter)\b", re.I)  # "not only", "no doubt"
_PRE_EXISTING_RE = re.compile(r"\bpre-?existing\b", re.I)
_PRE_EXISTING_SUBJECT_RE = re.compile(
    r"\bpre-?existing\s+(?:[\w-]+\s+){0,2}?(?:rows?|records?|entries|entry|runs?|data)\s+(?:(?:is|are|was|were"
    r"|must|should|will|shall|can|may|do|does|did|stays?|remains?)\s+)?$", re.I)
_CLAUSE_BREAK_RE = re.compile(r"[,;:]|[\u2013\u2014]|\s-\s")
_OR_JOIN_RE = re.compile(r"[^,;:.!?\u2013\u2014]*\b(?:or|nor)\s+$", re.I)
_REFUSAL_RE = re.compile(
    r"\b(?:is|are|was|were|gets?|got|being|been)\s+(?:\w+\s+)?(?:refused|rejected|denied)\b"
    r"|\b(?:responds?|returns?|answers?|replies|reply|fails?)\s+(?:with\s+)?(?:an?\s+|the\s+)?"
    r"(?:HTTP\s+|status\s+)?(?:[45]\d\d|error)\b"
    r"|\b(?:shows?|displays?|renders?|raises?|surfaces?)\s+(?:an?\s+|the\s+)?(?:[\w-]+\s+){0,2}?error\b"
    r"|\b(?:an?|the)\s+(?:[\w-]+\s+){0,2}?error\s+(?:message\s+)?(?:is|was|gets|appears)\b"
    r"|\bfails?\s+validation\b|\bvalidation\s+fails\b"
    r"|\braises?\s+(?:an?\s+)?`?\w*(?:Refused|Rejected|Denied|Error|Exception)\b"   # raises `ConcurrentRunnerRefused`
    r"|\b(?:refusal|rejection)_\w+", re.I)                                             # a refusal field
_OTHER_REQUEST_RE = re.compile(r"\b(?:that|which|who|previously|earlier|already|once)\s*$", re.I)
_GIVEN_INVALID_RE = re.compile(
    r"^\W*(?:TC-\d+[a-z]?\W+)?given\s+(?:an?\s+|the\s+|some\s+)?(?:[\w-]+\s+){0,3}?(?:expired|invalid|unknown"
    r"|malformed|duplicate|unauthori[sz]ed|forbidden|missing|empty|wrong|bad|revoked|locked|disabled"
    r"|out-of-range)\b", re.I)
_PAREN_RE = re.compile(r"\([^()]*\)")
_NOT_A_BREAK_RE = re.compile(r"\b(?:e\.g|i\.e|etc|vs|cf|approx|incl|resp)\.|(?<=\d)\.(?=\d)", re.I)
_QUALIFIER_WINDOW = 160
_SENTENCE_END_RE = re.compile(r"[.!?](?=\s|$|[\"')\]*_`])|;")   # not the dot of `run.py`


def _sentences(text: str) -> list[tuple[int, int]]:
    """(start, end) spans of the sentences of `text`: they end at ; or at . ! ?
    before a space or the end — never at the dot of a file name, an
    abbreviation or a number."""
    masked = _NOT_A_BREAK_RE.sub(lambda a: a.group(0).replace(".", " "), text)
    spans, start = [], 0
    for m in _SENTENCE_END_RE.finditer(masked):
        spans.append((start, m.end()))
        start = m.end()
    if start < len(text):
        spans.append((start, len(text)))
    return spans


def _counting_cues(sentence: str) -> list["re.Match[str]"]:
    return [c for c in _NEG_CUE_RE.finditer(sentence)
            if not (_IDIOM_BEFORE_RE.search(sentence[:c.start()]) or _IDIOM_AFTER_RE.match(sentence[c.end():]))]


def _qualified_end(sentence: str, cue: "re.Match[str]", starts: list[int]) -> "int | None":
    """Where the "pre-existing" qualification of this negation ends, or None.
    The negation's object is qualified when "pre-existing" follows within six
    words, in the same clause, with no unqualified activity between ("no
    pre-existing row is edited", "must not modify any pre-existing row", "does
    not edit or delete any pre-existing ledger row"); its subject is qualified
    when the clause before the negation names "pre-existing" data and no
    unqualified activity ("…, pre-existing rows are not edited"). `starts` are
    the sorted start offsets of the sentence's unqualified activities."""
    def _activity_in(lo: int, hi: int) -> bool:
        k = bisect.bisect_left(starts, lo)
        return k < len(starts) and starts[k] < hi
    rest = sentence[cue.end():cue.end() + _QUALIFIER_WINDOW]
    q = _PRE_EXISTING_RE.search(rest)
    if q:
        between = rest[:q.start()]
        if not (len(between.split()) > 6 or _CLAUSE_BREAK_RE.search(between)
                or _activity_in(cue.end(), cue.end() + q.start())):
            return cue.end() + q.end()
    head = sentence[max(0, cue.start() - _QUALIFIER_WINDOW):cue.start()]
    clause = _CLAUSE_BREAK_RE.split(head)[-1]
    # "…, pre-existing (ledger) rows are | must not …" — and no activity shares that subject
    if _PRE_EXISTING_SUBJECT_RE.search(clause) and not _activity_in(cue.start() - len(clause), cue.start()):
        return cue.end()
    return None


def _refused(sentence: str) -> bool:
    """Does the sentence state a refused request (a negative-path assertion)?"""
    if _GIVEN_INVALID_RE.search(sentence):
        return True
    masked = _PAREN_RE.sub(lambda p: " " * len(p.group(0)), sentence)
    for r in _REFUSAL_RE.finditer(masked):
        before = " ".join(masked[:r.start()].split()[-3:])
        if _NEG_CUE_RE.search(r.group(0)) or _NEG_CUE_RE.search(before) or _OTHER_REQUEST_RE.search(before):
            continue       # negated, or about another request ("the earlier request that was rejected")
        return True
    return False


def _sentence_prohibition(sentence: str, rx: "re.Pattern[str]") -> "re.Match[str] | None":
    """The activity `rx` a TC / DoD sentence prohibits (see the rule above)."""
    acts = [m for m in (rx.match(sentence, s.start()) for s in _ACTIVITY_START_RE.finditer(sentence)) if m]
    # an activity on pre-existing data is itself the invariant ("… edit any pre-existing ledger row")
    plain = [a for a in acts if not _PRE_EXISTING_RE.search(a.group(0))]
    if not plain:
        return None
    cues = _counting_cues(sentence)
    if not cues or _refused(sentence):
        return None
    starts = [a.start() for a in plain]
    for cue in cues:
        q = _qualified_end(sentence, cue, starts)
        if q is None:
            return plain[0]
        k = bisect.bisect_left(starts, q)          # only the next activity can be joined by "or"
        if k < len(plain) and _OR_JOIN_RE.fullmatch(sentence[q:plain[k].start()]):
            return plain[k]
    return None


_TC_LINE_RE = re.compile(
    r"^(?P<indent>[ \t]*)(?P<heading>#{1,6}[ \t]+)?(?:(?:[-*+]|\d+[.)])[ \t]+)?(?:\[[ xX]\][ \t]+)?(?:\|[ \t]*)?"
    r"(?:\*\*|__)?[`(\[]?(?P<tc>TC-\d+[a-z]?)\b", re.I)
_ANY_HEADING_RE = re.compile(r"^[ \t]{0,3}#{1,6}[ \t]")
_PROSE_SECTIONS = ("GOAL", "BACKGROUND", "NOTES", "NOTE", "CONTEXT", "RATIONALE", "HISTORY")

# ── markdown code fences (shared with goal_gate.py) ──────────────────────────
_FENCE_OPEN_RE = re.compile(r"^(?P<quote>[ \t]*(?:>[ \t]?)*)(?P<lead>[ \t]*(?:(?:[-*+]|\d{1,9}[.)])[ \t]+)*)"
                            r"(?P<fence>`{3,}|~{3,})(?P<info>.*)$")
_FENCE_CLOSE_RE = re.compile(r"^(?P<quote>[ \t]*(?:>[ \t]?)*)(?P<lead>[ \t]*)(?P<fence>`{3,}|~{3,})[ \t]*$")
_QUOTE_PREFIX_RE = re.compile(r"^[ \t]*(?:>[ \t]?)*")


def _fence_shape(m: "re.Match[str]") -> tuple[str, int, int, int]:
    """(character, length, blockquote depth, column after the quote markers)."""
    quote = m.group("quote")
    after = quote.rsplit(">", 1)[-1]
    return (m.group("fence")[0], len(m.group("fence")), quote.count(">"),
            len((after + m.group("lead")).expandtabs(4)))


def fence_scan(lines: list[str]) -> tuple[list[bool], list[int]]:
    """(flags, unclosed): flags[i] is True for every line that is a code-fence
    delimiter or inside a fence; `unclosed` lists the top-level openers that
    never close.

    CommonMark pairing, approximated without a full container parser:
    - a fence closes only on a line of the SAME character, at least as long,
      with nothing after it (a backtick opener's info string holds no
      backtick), at the same blockquote depth and indented at most 3 columns
      deeper than the opener; everything between is content (a ``` line inside
      a ~~~ block included);
    - an opener may sit on a list-item line (`- ```bash`); such a fence ends with
      its list item (a non-blank line indented less than the item's content)
      when it is not closed before, as it does in CommonMark;
    - a fence inside a blockquote ends with the quote when it is not closed
      before;
    - deliberate deviation: a top-level opener that is never closed is ordinary
      text, so one stray fence cannot swallow the rest of a document.
    A stray fence can still pair with a LATER fence and shift the reading of
    every fence after it (a renderer shifts the same way) — sometimes without
    leaving an unclosed opener behind — so the callers that decide safety never
    rely on this reading alone (find_mutation_prohibitions, policy_intent_detail
    and goal_gate's side_effect_journey_views_all)."""
    n = len(lines)
    flags = [False] * n
    unclosed: list[int] = []
    text = [ln[:-1] if ln.endswith("\r") else ln for ln in lines]
    depth = [_QUOTE_PREFIX_RE.match(ln).group(0).count(">") for ln in text]
    closes: list = [None] * n
    by_char: dict[str, list[int]] = {"`": [], "~": []}
    for j, ln in enumerate(text):
        c = _FENCE_CLOSE_RE.match(ln)
        if c:
            closes[j] = _fence_shape(c)
            by_char[closes[j][0]].append(j)
    i = 0
    while i < n:
        m = _FENCE_OPEN_RE.match(text[i])
        if not m or (m.group("fence")[0] == "`" and "`" in m.group("info")):
            i += 1
            continue
        ch, size, qd, col = _fence_shape(m)
        item = bool(m.group("lead").strip())            # the opener sits on a list-item line
        end = None
        if qd or item:
            j = i + 1
            while j < n:
                if qd and depth[j] < qd:
                    break                               # the quote ended
                if item and text[j].strip() and len(text[j].expandtabs(4)) - len(
                        text[j].expandtabs(4).lstrip()) < col:
                    break                               # the list item ended
                c = closes[j]
                if c and c[0] == ch and c[1] >= size and c[2] == qd and c[3] <= col + 3:
                    break
                j += 1
            closed_here = j < n and closes[j] is not None and closes[j][0] == ch and closes[j][1] >= size \
                and closes[j][2] == qd and closes[j][3] <= col + 3 and not (qd and depth[j] < qd)
            end = j if closed_here else j - 1
        else:
            positions = by_char[ch]
            for j in positions[bisect.bisect_right(positions, i):]:
                c = closes[j]
                if c[1] >= size and c[2] == 0 and c[3] <= col + 3:
                    end = j
                    break
            if end is None:
                unclosed.append(i)
        if end is None:
            i += 1
            continue
        for k in range(i, end + 1):
            flags[k] = True
        i = end + 1
    return flags, unclosed


def fenced_line_flags(lines: list[str]) -> list[bool]:
    """True for every line that is a code-fence delimiter or inside a fence (see fence_scan)."""
    return fence_scan(lines)[0]


def _html_comment_flags(lines: list[str]) -> list[bool]:
    """Lines inside a multi-line HTML comment (or starting one on their own).
    An opener that is never closed is ordinary text, like an unclosed fence."""
    n = len(lines)
    flags = [False] * n
    i = 0
    while i < n:
        s = lines[i].strip()
        if not s.startswith("<!--"):
            i += 1
            continue
        if "-->" in s[4:]:
            flags[i] = True
            i += 1
            continue
        end = next((j for j in range(i + 1, n) if "-->" in lines[j]), None)
        if end is None:
            i += 1
            continue
        for k in range(i, end + 1):
            flags[k] = True
        i = end + 1
    return flags


def _section_kind(title: str) -> str:
    words = re.sub(r"[^A-Z]+", " ", title.upper()).split()
    joined = " ".join(words)
    if joined.startswith(_METADATA_H2.upper()):
        return "metadata"
    if joined.startswith(("OUT OF SCOPE", "NOT IN SCOPE", "NON GOALS", "NONGOALS")):
        return "OUT OF SCOPE"
    if joined.startswith("DEFINITION OF DONE") or (words and words[0] == "DOD"):
        return "DEFINITION OF DONE"
    if words and words[0] in _PROSE_SECTIONS:
        return "prose"
    return "other"


def _line_sections(lines: list[str], fenced: list[bool]) -> list[str]:
    kinds: list[str] = []
    kind = "other"
    for ln, f in zip(lines, fenced):
        h2 = None if f else _H2_LINE_RE.match(ln)
        if h2:
            kind = _section_kind(h2.group(1))
            kinds.append("heading")
            continue
        kinds.append(kind)
    return kinds


def _indent_of(line: str) -> int:
    expanded = line.expandtabs(4)
    return len(expanded) - len(expanded.lstrip())


_ITEM_START_RE = re.compile(r"^[ \t]*(?:(?:[-*+]|\d+[.)])[ \t]|\|)")


def _item_hit(text: str, label: str) -> "tuple[str, int, int] | None":
    """(pattern, start, end) of the first prohibition in one item's joined text."""
    text = text.replace("\u2019", "'").replace("\u00a0", " ")
    for name, rx, where, qualified in _PROHIBITION_RES:
        if where == "oos" and label != "OUT OF SCOPE":
            continue
        for m in rx.finditer(text):
            if qualified and _PRE_EXISTING_ROWS_RE.search(text[:m.start()]):
                continue
            return name, m.start(), m.end()
    spans = _sentences(text)
    for a, b in spans:
        passive = _PASSIVE_NONE_RE.search(text, a, b)
        if passive and not _refused(text[a:b]):
            return "no-new-row-run-record", passive.start(), passive.end()
    for name, anywhere, listed in _ACTIVITY_RES:
        if label == "OUT OF SCOPE":
            m = listed.search(text)
            if m:
                return name, m.start(), m.end()
            continue
        for a, b in spans:
            m = _sentence_prohibition(text[a:b], anywhere)
            if m:
                return name, a + m.start(), a + m.end()
    return None


def _scan_prohibitions(lines: list[str], fenced: list[bool]) -> list[dict]:
    """One finding per ITEM — a bullet, numbered, checkbox or table line, or a
    TC line, together with its wrapped continuation lines (indented, or lazy at
    column 0 right below a TC line) — reported at the line where the match
    starts."""
    kinds = _line_sections(lines, fenced)
    items: list[list] = []
    current: "list | None" = None
    tc_label, tc_indent, tc_heading = None, 0, False
    for i, line in enumerate(lines, 1):
        kind = kinds[i - 1]
        stripped = line.strip()
        if fenced[i - 1] or kind in ("heading", "prose", "metadata"):
            if kind == "heading":
                tc_label = None
            current = None
            continue
        tc = _TC_LINE_RE.match(line)
        in_tc_item = current is not None and current[0] == tc_label
        if tc:
            tc_label, tc_indent = tc.group("tc").upper(), _indent_of(tc.group("indent"))
            tc_heading = bool(tc.group("heading"))
            label = tc_label
        elif tc_label and tc_heading and not _ANY_HEADING_RE.match(line):
            label = tc_label                       # the body of a `### TC-4` heading
        elif (tc_label and not tc_heading and stripped and not _ANY_HEADING_RE.match(line)
              and not line.lstrip().startswith("|")
              and (_indent_of(line) > tc_indent or (in_tc_item and not _ITEM_START_RE.match(line)))):
            label = tc_label                       # a TC continued (or sub-bulleted) below its line
        else:
            tc_label = None
            if kind in ("OUT OF SCOPE", "DEFINITION OF DONE"):
                label = kind
            else:
                current = None
                continue
        if not stripped:
            current = None
            continue
        if tc or current is None or current[0] != label or _ITEM_START_RE.match(line):
            current = [label, []]
            items.append(current)
        current[1].append((i, stripped))
    found: list[dict] = []
    for label, parts in items:
        text = " ".join(t for _n, t in parts)
        hit = _item_hit(text, label)
        if not hit:
            continue
        name, start, end = hit
        line_no, pos = parts[0][0], 0
        for n, t in parts:
            if start < pos + len(t) + 1:
                line_no = n
                break
            pos += len(t) + 1
        found.append({"section": label, "line": line_no, "pattern": name, "match": text[start:end],
                      "text": text if len(text) <= 240 else text[:239] + "…"})
    return found


def find_mutation_prohibitions(spec_text: str) -> list[dict]:
    """[{section, line, text, pattern, match}] — section is 'OUT OF SCOPE',
    'DEFINITION OF DONE' or the TC id ('TC-4').

    The spec is scanned twice and the findings are merged: once with its code
    fences paired (a fenced example is not a constraint) and once ignoring
    fences (`fence_blind` marks what only that pass found), because a stray
    fence can shift the pairing of every fence after it without leaving a trace
    — a prohibition must never disappear because the fence reading was wrong. A
    re-planned spec therefore never quotes a rejected section WITH its heading,
    even inside a code fence (agents/goal-decomposer/body.md)."""
    lines = spec_text.splitlines()
    found = {p["line"]: p for p in _scan_prohibitions(lines, fenced_line_flags(lines))}
    for p in _scan_prohibitions(lines, [False] * len(lines)):
        if p["line"] not in found:
            p["fence_blind"] = True
            found[p["line"]] = p
    return [found[n] for n in sorted(found)]


# A line that states the side-effect policy in ANY shape a reader would take for
# it: after blockquote / table / list / checkbox prefixes, emphasis, Unicode
# format characters (zero-width) and dash variants are set aside, the line
# STARTS with the label. The value follows the first `:`, `|` or `=` — a
# qualifier such as "(this iteration)" or "for J-04" may come before it — or,
# with no such separator, whatever follows the label ("**Side-effect policy**
# none", "Side-effect policy is allowed").
_POLICY_LINE_PREFIX_RE = re.compile(
    r"^[ \t]*(?:>[ \t]?)*(?:\|[ \t]*)?(?:(?:[-*+]|\d+[.)])[ \t]+)?(?:\[[ xX]\][ \t]+)?")
_POLICY_LABEL_START_RE = re.compile(rf"^[*_` \t]*{_POLICY_LABEL}\b(?P<rest>.*)$", re.I)
_POLICY_HTML_TAG_RE = re.compile(r"</?(?:b|strong|em|i|u|code|span|mark|kbd)\b[^>]*>", re.I)
_POLICY_SEP_RE = re.compile(r"[:|=]")
_POLICY_LEAD_RE = re.compile(
    r"^(?:[*_` \t]|[-\u2013\u2014\u2192>]+(?=[ \t*_`]|$))*(?:(?:is|stays|remains|set[ \t]+to)\b[ \t]*)?", re.I)
_POLICY_QUOTES = "`*_\"'‘’“”"
_POLICY_PLAIN_ALLOWED_RE = re.compile(
    rf"^[{_POLICY_QUOTES}]*allowed[{_POLICY_QUOTES}]*[.;,!]?(?:[ \t]+[-\u2013\u2014]+[ \t]+(?P<note>.*))?$", re.I)
_POLICY_NOTE_RESTRICTIVE_RE = re.compile(
    r"^(?:but|except|unless)\b|\b(?:none(?![ \t]+of\b)|read[-\s]?only|forbidden|prohibited|disallowed)\b", re.I)


def _policy_line_value(line: str) -> "str | None":
    """The value a policy-labelled line states ('' when none can be isolated),
    or None when the line does not start with the policy label."""
    s = unicodedata.normalize("NFKC", line)
    s = "".join(ch for ch in s if unicodedata.category(ch) != "Cf")
    s = _POLICY_LINE_PREFIX_RE.sub("", _POLICY_HTML_TAG_RE.sub("", s), count=1)
    m = _POLICY_LABEL_START_RE.match(s)
    if not m:
        return None
    rest = m.group("rest")
    sep = _POLICY_SEP_RE.search(rest)
    if sep:
        rest = rest[sep.end():]
    return _POLICY_LEAD_RE.sub("", rest, count=1)


def _policy_value_restrictive(value: str) -> bool:
    """Anything but a plainly stated `allowed` (optionally followed by a dash
    note) is restrictive — fail closed: `none`, `no`, `not allowed`,
    `read-only`, `allowed | none`, `allowed/none`, `allowed (but none for
    J-02)`, an empty or struck-through value; a dash note that restricts
    (`allowed — but none for J-02`) is restrictive too."""
    v = re.sub(r"[ \t]*\|+[ \t]*$", "", value).strip()
    if "~~" in v:
        return True
    m = _POLICY_PLAIN_ALLOWED_RE.match(v)
    if not m:
        return True
    return bool(_POLICY_NOTE_RESTRICTIVE_RE.search((m.group("note") or "").strip()))


def _policy_intent_pass(lines: list[str], canonical, blind: bool) -> dict:
    n = len(lines)
    if blind:
        fenced = comments = [False] * n
    else:
        fenced, comments = fenced_line_flags(lines), _html_comment_flags(lines)
    kinds = _line_sections(lines, fenced)
    in_section: list[tuple[int, str]] = []
    outside: list[tuple[int, str]] = []
    for i, ln in enumerate(lines):
        if fenced[i] or comments[i] or kinds[i] == "heading":
            continue
        value = _policy_line_value(ln)
        if value is None:
            continue
        if kinds[i] == "metadata":
            in_section.append((i + 1, value))
        elif kinds[i] != "prose":
            stripped = ln.expandtabs(4)
            body = stripped.lstrip()
            if (not blind and len(stripped) - len(body) >= 4
                    and not re.match(r"(?:[-*+]|\d+[.)])[ \t]", body)):
                continue                      # an indented code block
            outside.append((i + 1, value))
    hits, where = (in_section, "section") if in_section else (outside, "outside")
    for n_, value in hits:
        if _policy_value_restrictive(value):
            return {"intent": "none", "where": "canonical" if canonical == "none" and where == "section" else where,
                    "line": n_}
    if canonical in _VALID_POLICY:
        return {"intent": canonical, "where": "canonical", "line": None}
    if hits:
        return {"intent": "allowed", "where": where, "line": hits[0][0]}
    return {"intent": "", "where": None, "line": None}


def policy_intent_detail(spec_text: str) -> dict:
    """{intent, where, line, hidden}: intent 'none' (restrictive), 'allowed' or ''.

    Policy-shaped lines in the metadata section decide; only when the section has
    none (the field is absent or misplaced) do lines elsewhere count — never
    prose sections (GOAL / BACKGROUND / NOTES …), HTML comments, fences or
    indented code. A restrictive-looking line counts whatever its form, so a
    policy the canonical parser cannot read is reported (E02/E06/E01) AND
    treated as restrictive (E13/E15). When the reading with code fences and
    comments paired finds nothing restrictive, a reading that ignores them
    decides (`hidden`: True) — a stray fence or comment opener must never hide a
    restrictive policy, so a re-planned spec never quotes a policy line, even
    inside a fence."""
    canonical = read_metadata(spec_text).get("side_effect_policy")
    lines = spec_text.splitlines()
    aware = _policy_intent_pass(lines, canonical, blind=False)
    aware["hidden"] = False
    if aware["intent"] == "none":
        return aware
    blind = _policy_intent_pass(lines, canonical, blind=True)
    if blind["intent"] == "none":
        blind["hidden"] = True
        return blind
    return aware


def policy_intent(spec_text: str) -> str:
    """'none' when the spec states a restrictive side-effect policy in any form
    (see policy_intent_detail), else 'allowed' or ''."""
    return policy_intent_detail(spec_text)["intent"]


def load_side_effect_ledger(path: str | None, build_id: str | None = None) -> dict:
    """{availability: ok|incomplete|unavailable, reason, ledger}. NEVER raises;
    anything that is not a well-formed, complete ledger — including one that
    was not produced by the expected build (`build_id`) — is reported as such so
    a restrictive policy can fail closed on it (E15)."""
    def _bad(reason: str) -> dict:
        return {"availability": "unavailable", "reason": reason, "ledger": None}
    if not path:
        return _bad("no ledger path was given")
    try:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
    except (OSError, ValueError) as exc:
        return _bad(f"cannot read it: {getattr(exc, 'strerror', None) or exc}")
    try:
        data = json.loads(raw)
    except (ValueError, RecursionError) as exc:
        return _bad(f"not valid JSON: {str(exc)[:200]}")
    if not isinstance(data, dict) or not isinstance(data.get("journeys"), dict):
        return _bad("wrong shape (no 'journeys' object)")
    if build_id is not None and data.get("build_id") != build_id:
        return _bad(f"stale: it is not this run's preflight build (build id {data.get('build_id')!r}, "
                    f"expected {build_id!r}) — the build that should have replaced it failed")
    for jid, j in data["journeys"].items():
        if not isinstance(j, dict) or j.get("status") not in _SIDE_EFFECT_STATUSES:
            return _bad(f"journey {jid} has no usable status")
    if data.get("complete") is not True:
        errs = data.get("errors") if isinstance(data.get("errors"), list) else []
        return {"availability": "incomplete",
                "reason": "; ".join(str(e) for e in errs) or "the ledger is marked incomplete",
                "ledger": data}
    return {"availability": "ok", "reason": "", "ledger": data}


def _journey_roles(md: dict, makeup: list[str]) -> dict[str, set]:
    roles: dict[str, set] = {}
    for j in md["target_journeys"]:
        roles.setdefault(j, set()).add("target")
    for j in md["required_journeys"]:
        roles.setdefault(j, set()).add("required")
    for j in makeup:
        roles.setdefault(j, set()).add("make-up")
    return roles


def _role_text(roles: set) -> str:
    return "/".join(r for r in ("target", "required", "make-up") if r in roles)


def _observed_sample(rec: dict) -> tuple[str, str]:
    sample = next((f"{r.get('method')} {r.get('path')}" for r in rec.get("requests") or []
                   if isinstance(r, dict) and r.get("class") == "mutating"), "a mutating request")
    if rec.get("observed_iter") is not None:
        when = f"iter-{rec['observed_iter']}"
    else:
        when = rec.get("observed_iter_name") or "an earlier iteration"
    return sample, when


def _observation_text(rec: dict) -> str:
    sample, when = _observed_sample(rec)
    text = f"observed {sample} in {when}"
    if rec.get("observation_sticky"):
        sd = rec.get("sticky_detail") or {}
        later = (f"iter-{sd['iter']}" if sd.get("iter") is not None
                 else (sd.get("iter_name") or "a later iteration"))
        text += f", not cleared by the clean replay in {later}, which used a different golden script"
    return text


def _mutating_desc(jid: str, rec: dict, roles: set) -> str:
    src = []
    if rec.get("declared") == "mutating":
        src.append("declared mutating" + (f": '{rec['note']}'" if rec.get("note") else ""))
    elif "mutating" in (rec.get("stated_values") or []):
        src.append(f"a 'Side effects: mutating' line that cannot be tied to it with certainty ({_attribution(rec)}) "
                   "— read as mutating, fail-closed")
    if rec.get("observed_mutating"):
        conflict = "declared none, but " if rec.get("declared") == "none" else ""
        src.append(conflict + _observation_text(rec))
    hints = rec.get("step_hints") or []
    hint = f"; its step {hints[0]['n']}: '{hints[0]['text']}'" if hints else ""
    return f"{_role_text(roles)} journey {jid} is MUTATING ({'; '.join(src) or 'ledger status mutating'}{hint})"


def _attribution(rec: dict) -> str:
    if rec.get("ambiguous"):
        return "ambiguous: a header with this id also sits inside a code fence"
    if rec.get("attribution_reason") == "fenced-header":
        return "unattributed: its only header sits inside a code fence"
    return "unattributed: it has no definition of its own"


def _conflict_fix(jids: list[str], roles: dict[str, set], baseline: bool = False) -> str:
    pinned = [j for j in jids if roles[j] & {"required", "make-up"}]
    base = ("Fix: declare '- **Side-effect policy:** allowed' and phrase every TC / DEFINITION OF DONE line "
            "that assumes nothing changes as an invariant on PRE-EXISTING rows (e.g. 'no pre-existing ledger "
            "row is edited or deleted; the journey's own step may add a new row')")
    if baseline:
        return (f"{base}. This is a baseline (iteration 0) spec, which assesses every journey: change the "
                "policy and the wording, never the journey set.")
    if pinned:
        kinds = "Required-still-passing or engine-scheduled make-up"
        return (f"{base}. {', '.join(pinned)} {'is a' if len(pinned) == 1 else 'are'} {kinds} "
                f"journey{'' if len(pinned) == 1 else 's'} and may NOT be dropped to dodge the conflict.")
    return f"{base}, or drop it from Target journeys (never from Required-still-passing)."


def side_effect_findings(spec_text: str, md: dict, ledger_path: str | None, strict: bool,
                         makeup: list[str], err, warn, baseline: bool = False,
                         build_id: str | None = None) -> dict:
    """Append the HARD-3 findings through err()/warn(); return the report block."""
    policy_raw = md.get("side_effect_policy")
    policy = policy_raw if policy_raw in _VALID_POLICY else None
    detail = policy_intent_detail(spec_text)
    intent = detail["intent"]
    restrictive = policy == "none" or intent == "none"
    hidden = (" — the line sits inside what the parser reads as a code fence or HTML comment, and a stray "
              "fence or comment opener must never hide a policy" if detail.get("hidden") else "")
    if policy == "none":
        stated = "Side-effect policy: none"
    elif detail["where"] == "outside":
        stated = (f"a Side-effect policy line outside the metadata section (line {detail['line']}) does not state "
                  f"a plain 'allowed', and the section declares no policy — it is treated as restrictive{hidden}")
    else:
        stated = (f"the Side-effect policy line (line {detail['line']}) does not state a plain 'allowed' (see "
                  f"E02/E06 for the canonical form) — it is treated as restrictive{hidden}")
    roles = _journey_roles(md, makeup)
    checked = list(roles)
    info = load_side_effect_ledger(ledger_path, build_id)
    avail = info["availability"]
    ledger = info["ledger"] or {}
    recs = ledger.get("journeys") or {}
    if avail == "unavailable":
        statuses = {j: "unavailable" for j in checked}
    else:
        statuses = {j: (recs.get(j) or {}).get("status", "unknown") for j in checked}
    mutating = [j for j in checked if statuses[j] == "mutating"]
    unknown = [j for j in checked if statuses[j] == "unknown"]
    prohibitions = find_mutation_prohibitions(spec_text)
    ledger_ref = ledger_path or "(none)"
    reproduce = ("Reproduce: python3 scripts/automation/lib/goal_gate.py side-effects docs/goal.md "
                 "--sidecar runs/goal-session-<sid>/state/journey-side-effects.json")

    if avail != "ok":
        what = "could not be built or read" if avail == "unavailable" else "is INCOMPLETE"
        if restrictive:
            err("E15", f"'{stated}', but the deterministic side-effect ledger "
                       f"{ledger_ref} {what} ({info['reason']}). A restrictive policy is never trusted "
                       f"without its evidence source, so the session stops here (not re-planned) — fix the "
                       f"ledger input, then resume. {reproduce}")
        else:
            warn("W11", f"the deterministic side-effect ledger {ledger_ref} {what} ({info['reason']}); the "
                        f"policy is '{policy_raw or 'not declared'}', so dispatch continues, but journeys whose "
                        f"status could not be established are not checked against this spec. {reproduce}")

    if restrictive:
        for j in mutating:
            err("E13", f"{stated}, but " + _mutating_desc(j, recs[j], roles[j])
                + " — a browser lane executing it WILL change persisted data. " + _conflict_fix([j], roles, baseline))

    if avail != "unavailable":
        undeclared_hint = ("declare their '- Side effects:' lines in docs/goal.md "
                           "(python3 scripts/automation/lib/goal_gate.py side-effects docs/goal.md --suggest)")
        if restrictive and unknown:
            msg = (f"{stated}, but {', '.join(unknown)} "
                   f"{'has' if len(unknown) == 1 else 'have'} no known side-effect status (no valid declaration "
                   f"and no replay observation), so the policy cannot be verified for "
                   f"{'it' if len(unknown) == 1 else 'them'} — {undeclared_hint}")
            if strict:
                err("E14", "strict side-effect mode (CHAIN_SIDE_EFFECT_STRICT=true): " + msg)
            else:
                warn("W09", msg + ". CHAIN_SIDE_EFFECT_STRICT=true makes this an error")
        if prohibitions and mutating:
            descs = "; ".join(_mutating_desc(j, recs[j], roles[j]) for j in mutating)
            for p in prohibitions:
                blind = (" (found with code fences ignored: a stray fence can make a live line read as fenced, so "
                         "fenced prohibition-shaped text counts — never quote a rejected section with its heading)"
                         if p.get("fence_blind") else "")
                rule = (" (a TC / DEFINITION OF DONE sentence that names this activity and contains any negation is a "
                        "prohibition — write it positively, keep the activity out of the negated sentence, or say "
                        "'pre-existing' if the negation is about earlier data)"
                        if p["pattern"] in ("ledger-row-edit", "any-new-run-launch")
                        and p["section"] != "OUT OF SCOPE" else "")
                err("E16", f"{p['section']} (line {p['line']}){blind} forbids a mutation ('{p['text']}'){rule} but {descs}. "
                           f"The Side-effect policy line ('{policy_raw or 'absent'}') cannot resolve this: the "
                           f"spec forbids what its own journey does. " + _conflict_fix(mutating, roles, baseline))
        elif prohibitions and unknown:
            p = prohibitions[0]
            msg = (f"{p['section']} (line {p['line']}) forbids a mutation ('{p['text']}') but "
                   f"{', '.join(unknown)} {'has' if len(unknown) == 1 else 'have'} an unknown side-effect "
                   f"status, so the prohibition cannot be checked against "
                   f"{'it' if len(unknown) == 1 else 'them'} — {undeclared_hint}")
            if strict:
                err("E14", "strict side-effect mode (CHAIN_SIDE_EFFECT_STRICT=true): " + msg)
            else:
                warn("W10", msg)

    return {
        "ledger": ledger_path,
        "availability": avail,
        "reason": info["reason"],
        "policy": policy,
        "policy_raw": policy_raw,
        "policy_intent": intent,
        "policy_intent_where": detail["where"],
        "policy_intent_hidden": bool(detail.get("hidden")),
        "restrictive": restrictive,
        "strict": bool(strict),
        "journeys_checked": checked,
        "roles": {j: sorted(r) for j, r in roles.items()},
        "statuses": statuses,
        "mutating": mutating,
        "unknown": unknown,
        "none": [j for j in checked if statuses[j] == "none"],
        "conflicts": [j for j in checked if (recs.get(j) or {}).get("declaration_conflict")],
        "sticky": [j for j in checked if (recs.get(j) or {}).get("observation_sticky")],
        "prohibitions": prohibitions,
        "declaration_digest": ledger.get("declaration_digest"),
        "build_id": ledger.get("build_id"),
    }


# Prompt-context text. The lane and evaluator rules are the plan's wording
# verbatim (WP3 "Prompt injections"); a test pins them.
_LANE_RULE = (
    "Execute every numbered step EXACTLY as written even when it creates or changes data. Do not fail the "
    "journey merely because one of its own declared numbered steps mutates state; if that required mutation "
    "conflicts with the iteration spec, report it in the row's Actual cell as a spec/journey contradiction "
    "(the deterministic preflight should normally have blocked it before execution). Never perform a mutation "
    "that is not a numbered step. In each row's Actual cell name any create/update/delete you performed or "
    "write \"no data changed\".")
_EVAL_RULE = (
    "Do not fail the product journey merely because one of its own declared numbered steps mutates state. If "
    "that required mutation conflicts with the iteration spec, classify it as a spec/journey contradiction "
    "rather than a product regression (the deterministic preflight should normally have blocked it before "
    "execution); score such a TC on the invariant that matters (no PRE-EXISTING row edited) and name the "
    "contradiction in Summary and assumptions.md — never ignore an actual spec contradiction.")
_DECOMPOSER_RULE = (
    "Side-effect rule (BINDING — the deterministic spec lint enforces it before anything is dispatched): write "
    "'- **Side-effect policy:** none' only when NO target, required or make-up journey is MUTATING (E13); an "
    "Unknown journey under 'none' is a warning (an error in strict mode). When any of them changes persisted "
    "data, write '- **Side-effect policy:** allowed' and phrase every TC and DEFINITION OF DONE line as an "
    "invariant on PRE-EXISTING rows (\"no pre-existing ledger row is edited or deleted\"). Whatever the policy "
    "says, never put a no-mutation prohibition in OUT OF SCOPE, a TC- line or DEFINITION OF DONE — "
    "\"row/record/ledger count unchanged\", \"no new row/run/record\", \"ledger unchanged/frozen\", "
    "\"must not create/launch/append/write\", \"no write/mutation/launch\", \"Any new ... run launch\", "
    "\"no run is launched\" — while a MUTATING journey is in the iteration (E16). The same holds for the "
    "activities creating/editing/deleting/writing/appending/adding/inserting ledger rows and "
    "launching/starting/triggering a new run: naming one in OUT OF SCOPE is a prohibition, and a TC or "
    "DEFINITION OF DONE sentence that names one and contains ANY negation (no, not, n't, never, without, none, "
    "nothing, avoid, prevent, forbid, …) is a prohibition — unless the negation is about data called "
    "\"pre-existing\"; write such sentences positively or keep the activity out of them. Never copy a rejected "
    "section heading or policy line into the spec, not even inside a code fence. Never drop a "
    "Required-still-passing journey to avoid a conflict.")


def _status_list(jids: list[str], recs: dict, with_source: bool) -> str:
    out = []
    for j in jids:
        rec = recs.get(j) or {}
        if not with_source:
            out.append(j)
            continue
        src = []
        if rec.get("declared") == "mutating":
            src.append("declared")
        elif "mutating" in (rec.get("stated_values") or []):
            src.append("ambiguous declaration" if rec.get("ambiguous") else "unattributed declaration")
        if rec.get("observed_mutating"):
            conflict = ""
            if rec.get("declared") == "none":
                conflict = "AMBIGUOUS, one block says none, but " if rec.get("ambiguous") else "DECLARED NONE, but "
            src.append(conflict + _observation_text(rec))
        out.append(f"{j} ({'; '.join(src)})" if src else j)
    return ", ".join(out) or "(none)"


def _plural(jids: list[str]) -> tuple[str, str, str]:
    one = len(jids) == 1
    return ", ".join(jids), ("is" if one else "are"), ("its" if one else "their")


# Rendered only when a checked journey is declared `none` in docs/goal.md but a
# replay observed it mutating (goal_gate.py marks it declaration_conflict).
_CONFLICT_EVAL = ("DECLARATION CONFLICT: {jids} {is_are} declared 'none' in docs/goal.md, yet the deterministic "
                  "replay observed a mutation — report it in Summary and assumptions.md as a finding (a product "
                  "regression or a wrong declaration); it is never excused as the journey's own step.")
_CONFLICT_LANE = ("DECLARATION CONFLICT: {jids} {is_are} declared 'none' in docs/goal.md, yet a replay observed a "
                  "mutation — name the step that changes data in {its} row's Actual cell.")
# The same when the `none` comes from an AMBIGUOUS id (a header with the id also
# sits inside a code fence): which block is the journey is uncertain.
_CONFLICT_AMBIG_EVAL = ("POSSIBLE DECLARATION CONFLICT: a docs/goal.md block for {jids} says 'none', but a header with "
                        "the same id also sits inside a code fence, so which block is the journey is uncertain — and "
                        "the deterministic replay observed a mutation: report it in Summary and assumptions.md as a "
                        "finding to check (a product regression or a wrong or misplaced declaration).")
_CONFLICT_AMBIG_LANE = ("POSSIBLE DECLARATION CONFLICT: a docs/goal.md block for {jids} says 'none' (the id is "
                        "ambiguous), yet a replay observed a mutation — name the step that changes data in {its} "
                        "row's Actual cell.")
_FULL_LANE_NOTE = ("(In this full-depth run, a numbered step also means a numbered step of a UT- test case you "
                   "were asked to execute.)")


def render_side_effect_context(mode: str, ledger_path: str | None, spec_text: str | None = None,
                               makeup: list[str] | None = None, lane_kind: str = "lean") -> str:
    info = load_side_effect_ledger(ledger_path)
    ledger = info["ledger"] or {}
    recs = ledger.get("journeys") or {}
    digest = (ledger.get("declaration_digest") or "")[:12]
    if mode == "decomposer":
        if info["availability"] == "unavailable":
            return ("Side-effect ledger (deterministic, engine-built): UNAVAILABLE this iteration "
                    f"({info['reason']}) — do NOT write '- **Side-effect policy:** none': a restrictive policy "
                    "without its deterministic ledger fails closed (E15).\n" + _DECOMPOSER_RULE)
        allj = list(recs)
        line = (f"Side-effect ledger (deterministic, engine-built): {ledger_path} — "
                f"MUTATING: {_status_list([j for j in allj if recs[j]['status'] == 'mutating'], recs, True)}; "
                f"NONE: {_status_list([j for j in allj if recs[j]['status'] == 'none'], recs, False)}; "
                f"Unknown: {_status_list([j for j in allj if recs[j]['status'] == 'unknown'], recs, False)}; "
                f"declaration digest {digest or '(none)'}.")
        if info["availability"] == "incomplete":
            line += (f" INCOMPLETE ({info['reason']}) — do NOT write '- **Side-effect policy:** none' this "
                     "iteration (E15).")
        return line + "\n" + _DECOMPOSER_RULE
    if info["availability"] == "unavailable":
        return ""
    md = read_metadata(spec_text) if spec_text is not None else None
    policy = md["side_effect_policy"] if md and md["side_effect_policy"] in _VALID_POLICY else None
    if policy is None and spec_text is not None and policy_intent(spec_text) == "none":
        policy = "none (stated in a non-canonical form — treated as restrictive)"
    if md is not None:
        relevant = list(_journey_roles(md, list(makeup or [])))
    else:
        relevant = list(recs)
    status = {j: (recs.get(j) or {}).get("status", "unknown") for j in relevant}
    mut = [j for j in relevant if status[j] == "mutating"]
    if policy is None and not mut:
        return ""
    lists = (f"MUTATING: {_status_list(mut, recs, True)}; "
             f"NONE: {_status_list([j for j in relevant if status[j] == 'none'], recs, False)}; "
             f"Unknown: {_status_list([j for j in relevant if status[j] == 'unknown'], recs, False)}")
    policy_txt = policy or "not declared"
    conflicts = [j for j in mut if (recs.get(j) or {}).get("declaration_conflict") and not recs[j].get("ambiguous")]
    ambiguous = [j for j in mut if (recs.get(j) or {}).get("declaration_conflict") and recs[j].get("ambiguous")]
    incomplete = info["availability"] == "incomplete"
    if mode == "lane":
        head = ("SIDE-EFFECT CONTEXT (deterministic, engine-built): spec Side-effect policy: "
                f"{policy_txt}; {lists}.")
        if incomplete:
            head += " The ledger is INCOMPLETE this iteration, so these statuses may understate what mutates."
        lines = [head]
        if conflicts:
            jids, is_are, its = _plural(conflicts)
            lines.append(_CONFLICT_LANE.format(jids=jids, is_are=is_are, its=its))
        if ambiguous:
            jids, _is_are, its = _plural(ambiguous)
            lines.append(_CONFLICT_AMBIG_LANE.format(jids=jids, its=its))
        lines.append(_LANE_RULE + (" " + _FULL_LANE_NOTE if lane_kind == "full" else ""))
        return "\n".join(lines)
    extra = ""
    if incomplete:
        extra += f"; INCOMPLETE ledger ({info['reason']})"
    if ledger.get("declaration_digest_changed_this_iter"):
        extra += f"; declarations changed this iteration (previous digest {(ledger.get('declaration_digest_prev') or '')[:12]})"
    conflict_txt = ""
    if conflicts:
        jids, is_are, _its = _plural(conflicts)
        conflict_txt = " " + _CONFLICT_EVAL.format(jids=jids, is_are=is_are)
    if ambiguous:
        conflict_txt += " " + _CONFLICT_AMBIG_EVAL.format(jids=_plural(ambiguous)[0])
    return (f"  Side-effect ledger (deterministic): {ledger_path} <-- policy: {policy_txt}; {lists}; "
            f"declaration digest {digest or '(none)'}{extra}.{conflict_txt} {_EVAL_RULE}")


def lint_spec(
    spec_text: str,
    *,
    prior_verdict: str | None = None,
    mode_expected: str | None = None,
    journey_history: str | None = None,
    side_effects: str | None = None,
    strict_side_effects: bool = False,
    makeup_journeys: list[str] | None = None,
    side_effects_build_id: str | None = None,
) -> dict:
    """Pure lint. Returns {errors:[{rule,name,msg}], warnings:[...], metadata:{...},
    side_effects: {...} | None}. The HARD-3 ledger rules run only when
    `side_effects` (the ledger path) is given."""
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
    else:
        if not md["present"].get("depth"):
            err("E01", "no 'Depth:' field inside '## Goal Mode Metadata' — the engine's depth decision "
                       "has no declared input")
        for key in md["fields_outside_section"]:
            err("E01", f"'{_FIELDS[key]}:' appears in the document but NOT inside "
                       f"'## Goal Mode Metadata'. A field outside that section is prose, not machine "
                       f"state, and never satisfies the machine field — move it into the metadata section")
    for key in md["fields_shadowed_outside"]:
        warn("W12", f"'{_FIELDS[key]}:' is declared inside '## Goal Mode Metadata' AND repeated "
                    f"elsewhere in the document. Only the metadata section is machine state; the "
                    f"other copy has ZERO runtime influence and is ignored")
    if md["metadata_section_count"] > 1:
        err("E12", f"{md['metadata_section_count']} '## Goal Mode Metadata' sections — exactly one is canonical")
    for key, vals in sorted(md["field_conflicts"].items()):
        err("E12", f"'{_FIELDS[key]}:' is declared more than once inside the metadata section with "
                   f"conflicting values ({', '.join(repr(v) for v in vals)}) — the engine refuses to pick "
                   f"one by document order; keep exactly one line")

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

    # HARD-3: the side-effect policy is a machine field in its own right. A
    # label the canonical parser cannot read would silently turn a restrictive
    # `none` into "absent" (E13/E15 skipped), so a near miss is an error.
    policy_b, policy_p = _field_patterns(_FIELDS["side_effect_policy"])
    for ln in metadata_section(spec_text)[0].splitlines():
        if _policy_line_value(ln) is not None and not (policy_b.match(ln) or policy_p.match(ln)):
            err("E02", f"'{ln.strip()}' looks like a Side-effect policy line but is not in the canonical form "
                       "- **Side-effect policy:** none|allowed, so the engine cannot read it and the policy would "
                       "silently count as absent")
    if md["present"].get("side_effect_policy") and md["side_effect_policy"] not in _VALID_POLICY:
        err("E06", f"Side-effect policy '{md['side_effect_policy']}' is not one of {list(_VALID_POLICY)} — write "
                   "exactly '- **Side-effect policy:** none' or '- **Side-effect policy:** allowed' and put any "
                   "reasoning in BACKGROUND")
    if not md["present"].get("side_effect_policy"):
        warn("W02", "no 'Side-effect policy:' line — write '- **Side-effect policy:** none' when no target or "
                    "required journey may change persisted data this iteration, or 'allowed' when a journey's own "
                    "steps create or change data (every TC must then be an invariant on PRE-EXISTING rows)")

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
    # ...plus loose bullets that read as construction rather than description.
    # A descriptive loose bullet ("- verify-only baseline") is compatibility
    # surface and stays W06; an actionable one ("- change users.py ...") is real
    # work and must not slip past a baseline/verify-only/evidence declaration
    # just because it carries no `### Backend` heading.
    actionable_loose = _actionable_loose_bullets(spec_text)
    if actionable_loose:
        n += f"; actionable loose bullet: {actionable_loose[0][:70]!r}"
    if structured_work or actionable_loose:
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

    input_error: str | None = None
    if md["depth"] == "evidence" and journey_history and md["target_journeys"]:
        try:
            bad = _passing_targets(journey_history, md["target_journeys"])
        except HistoryUnusable as exc:
            # The independent evidence input could not be verified. This is NOT a
            # product contradiction and must never read as "every target passes":
            # the caller turns it into exit 2, which block mode fails closed on.
            input_error = str(exc)
            bad = []
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

    side_effects_report = None
    if side_effects is not None:
        side_effects_report = side_effect_findings(
            spec_text, md, side_effects, strict_side_effects, list(makeup_journeys or []), err, warn,
            baseline=(md["mode"] == "baseline" or mode_expected == "baseline"),
            build_id=side_effects_build_id)

    return {"errors": errors, "warnings": warnings, "metadata": md,
            "work_kind_derived": md["work_kind_derived"], "input_error": input_error,
            "side_effects": side_effects_report}


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


_FIELD_ALIASES = {
    "depth": "depth", "mode": "mode", "work_kind": "work_kind", "work-kind": "work_kind",
    "side_effect_policy": "side_effect_policy", "side-effect-policy": "side_effect_policy",
    "side-effect_policy": "side_effect_policy",
    "full_trigger": "full_trigger", "full-trigger": "full_trigger",
    "target_journeys": "target_journeys", "target-journeys": "target_journeys",
    "required_journeys": "required_journeys", "required-journeys": "required_journeys",
}


def cmd_field(argv: list[str]) -> int:
    """Print ONE canonical machine field for shell consumers.

    The point of this subcommand is that the engine, the executor and the browser
    lane read the SAME interpretation the lint gate validated. Before it existed
    each consumer ran its own whole-document `grep -m1`, so a `- **Depth:**
    evidence` line under NOTES beat the canonical `- **Depth:** full` inside the
    metadata section and the validator certified one machine state while the
    executor ran another.

      exit 0  value printed (empty line when the field is absent)
      exit 2  the spec could not be read
      exit 3  the spec has no `## Goal Mode Metadata` section at all — NOT a
              goal-mode iteration spec (a phase-mode spec, say). Callers fall
              back to their legacy grep so phase mode is untouched.
    """
    path, name = argv[0], argv[1]
    sep = ", "
    if "--sep" in argv:
        sep = argv[argv.index("--sep") + 1]
    key = _FIELD_ALIASES.get(name.strip().lower().replace(" ", "_"))
    if key is None:
        print(f"iter_spec: unknown field {name!r}", file=sys.stderr)
        return 2
    try:
        text = _read_spec(path)
    except OSError as exc:
        print(f"iter_spec: unreadable: {exc}", file=sys.stderr)
        return 2
    md = read_metadata(text)
    if not md["metadata_section_present"]:
        return 3
    if key in ("target_journeys", "required_journeys"):
        print(sep.join(md[key]))
    else:
        print(md[key] or "")
    return 0


_LINT_VALUED = ("--prior-verdict", "--mode-expected", "--journey-history", "--json-out",
                "--side-effects", "--makeup-journeys", "--side-effects-build-id")
_LINT_FLAGS = ("--strict-side-effects",)


def _parse_opts(argv: list[str], valued: tuple, flags: tuple) -> dict:
    opts: dict = {}
    i = 0
    while i < len(argv):
        if argv[i] in valued and i + 1 < len(argv):
            opts[argv[i]] = argv[i + 1]
            i += 2
        elif argv[i] in flags:
            opts[argv[i]] = True
            i += 1
        else:
            i += 1
    return opts


def cmd_lint(argv: list[str]) -> int:
    path = argv[0]
    opts = _parse_opts(argv[1:], _LINT_VALUED, _LINT_FLAGS)
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
        side_effects=opts.get("--side-effects"),
        strict_side_effects=bool(opts.get("--strict-side-effects")),
        makeup_journeys=_JOURNEY_ID_RE.findall(opts.get("--makeup-journeys") or ""),
        side_effects_build_id=opts.get("--side-effects-build-id"),
    )
    for f in res["errors"]:
        print(f"[spec-lint] ERROR {f['rule']} {f['name']}: {f['msg']}")
    for f in res["warnings"]:
        print(f"[spec-lint] WARN {f['rule']} {f['name']}: {f['msg']}")
    if res["input_error"]:
        # Printed on BOTH streams: stdout so the durable spec-lint.txt records it,
        # stderr so the engine's crash tail (spec_lint_crash) samples it too.
        line = f"[spec-lint] INPUT-FAILURE journey-history: {res['input_error']}"
        print(line)
        print(line, file=sys.stderr)
    out = opts.get("--json-out")
    if out:
        try:
            with open(out, "w", encoding="utf-8") as fh:
                json.dump(res, fh, sort_keys=True, indent=2)
        except OSError as exc:
            # The findings above already reached stdout/stderr; losing the JSON
            # sidecar must not change the verdict, only be said out loud.
            print(f"[spec-lint] WARN json-out: could not write {out}: {exc}", file=sys.stderr)
    if res["input_error"]:
        return 2
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
        targets: str = "J-01, J-02", policy: str = "") -> str:
    """Build a metadata block. Every field stays INSIDE the metadata section —
    a `- **Work kind:** x` bullet appended after `## IN SCOPE` would land under
    `### Frontend` and be counted, correctly, as a concrete frontend bullet."""
    wk = f"- **Work kind:** {work_kind}\n" if work_kind else ""
    pol = f"- **Side-effect policy:** {policy}\n" if policy else ""
    return ("## Goal Mode Metadata\n\n- **Session ID:** s\n- **Iteration:** 3\n"
            f"- **Mode:** {mode}\n- **Depth:** {depth}\n- **Target journeys:** {targets}\n"
            f"- **Required-still-passing journeys:** J-03\n{wk}{pol}{extra}")
_WORK = "\n## IN SCOPE\n### Backend\n- [ ] add the endpoint\n### Frontend\n- none\n"
_NOWORK = "\n## IN SCOPE\n### Backend\n- none\n### Frontend\n- N/A\n"
_PROHIBIT = ("\n## OUT OF SCOPE\n- Any new portfolio run launch, sweep, or ledger write\n"
             "\n## TESTING REQUIREMENTS\n- TC-4: given the replay, when it ends, then the ledger row count is unchanged\n")

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
    # G8 blocker A — metadata is section-scoped.
    "E01 a machine field outside the metadata section never satisfies it": (
        _md("lean", "implementation").replace("- **Depth:** lean\n", "")
        + "\n## OUT OF SCOPE\n- **Depth:** lean\n" + _WORK, {}, 1, ("E01",), ()),
    "E01 a misplaced field is reported as misplaced, not merely absent": (
        _md("lean", "implementation").replace("- **Target journeys:** J-01, J-02\n", "")
        + "\n## NOTES\n- **Target journeys:** J-99\n" + _WORK, {}, 1, ("E01",), ()),
    "W12 a field repeated outside the section is prose, warned not blocked": (
        "## NOTES\n\n- **Depth:** evidence\n\n" + _md("lean", "implementation") + _WORK,
        {}, 0, ("W12",), ("E01", "E12")),
    "E12 conflicting duplicate field inside the metadata section": (
        _md("lean", "implementation").replace("- **Depth:** lean\n",
                                              "- **Depth:** lean\n- **Depth:** evidence\n")
        + _WORK, {}, 1, ("E12",), ()),
    "E12 two metadata sections": (
        _md("lean", "implementation") + "\n## Goal Mode Metadata\n\n- **Depth:** full\n" + _WORK,
        {}, 1, ("E12",), ()),
    "a repeated field with the SAME value is not a conflict": (
        _md("lean", "implementation").replace("- **Depth:** lean\n", "- **Depth:** lean\n- **Depth:** lean\n")
        + _WORK, {}, 0, (), ("E12",)),
    # G8 blocker D — loose IN SCOPE bullets.
    "a descriptive loose bullet stays compatibility surface": (
        _md("lean", "verify-only", mode="baseline")
        + "\n## IN SCOPE\n- verify-only baseline (iteration-state wiring test)\n",
        {"mode_expected": "baseline"}, 0, ("W06",), ("E07", "E08", "E09")),
    "an ACTIONABLE loose bullet is implementation work in a baseline spec": (
        _md("lean", "verify-only", mode="baseline")
        + "\n## IN SCOPE\n- change users.py so login persists the token\n",
        {"mode_expected": "baseline"}, 1, ("E08", "E09"), ()),
    "an ACTIONABLE loose bullet blocks an evidence spec too": (
        _md("evidence", "evidence-only")
        + "\n## IN SCOPE\n- add the export endpoint\n", {}, 1, ("E07",), ()),
    "an actionable loose bullet in a plain lean spec is only W06": (
        _md("lean", "implementation") + "\n## IN SCOPE\n- add the export endpoint\n",
        {}, 0, ("W06",), ("E07", "E08", "E09")),
    "E11 evidence target not recorded passing": (
        _md("evidence", "evidence-only") + _NOWORK, {"journey_history": "@HIST_BAD@"}, 1, ("E11",), ()),
    # G8 blocker B — an unverifiable independent input is never "all passing".
    "corrupt journey-history is an INPUT failure, never a clean evidence spec": (
        _md("evidence", "evidence-only") + _NOWORK, {"journey_history": "@HIST_BAD_JSON@"},
        2, ("INPUT",), ("E11",)),
    "wrongly-shaped journey-history is an INPUT failure": (
        _md("evidence", "evidence-only") + _NOWORK, {"journey_history": "@HIST_SHAPE@"},
        2, ("INPUT",), ()),
    "a journey record with no usable status is an INPUT failure": (
        _md("evidence", "evidence-only") + _NOWORK, {"journey_history": "@HIST_REC@"},
        2, ("INPUT",), ()),
    "E11 clean when every target passes": (
        _md("evidence", "evidence-only") + _NOWORK, {"journey_history": "@HIST_OK@"}, 0, (), ("E11",)),
    # HARD-3: the policy field.
    "E06 invalid side-effect policy": (
        _md("lean", "implementation", policy="nothing") + _WORK, {}, 1, ("E06",), ()),
    "W02 missing side-effect policy": (_md("lean", "implementation") + _WORK, {}, 0, ("W02",), ("E06",)),
    "a declared policy is not W02": (
        _md("lean", "implementation", policy="allowed") + _WORK, {}, 0, (), ("W02", "E06")),
    # HARD-3: the contradiction preflight (ledger fixtures below).
    "E13 policy none vs a declared-mutating target": (
        _md("lean", "verify-only", policy="none") + _NOWORK, {"side_effects": "@LED_MUT@"}, 1, ("E13",), ("E16",)),
    "policy allowed over a mutating target with no prohibition is clean": (
        _md("lean", "verify-only", policy="allowed") + _NOWORK, {"side_effects": "@LED_MUT@"}, 0, (),
        ("E13", "E16", "W09", "W10")),
    "E16 prohibition vs a mutating target under policy allowed": (
        _md("lean", "verify-only", policy="allowed") + _NOWORK + _PROHIBIT,
        {"side_effects": "@LED_MUT@"}, 1, ("E16",), ("E13",)),
    "E16 prohibition vs a mutating target with the policy absent": (
        _md("lean", "verify-only") + _NOWORK + _PROHIBIT, {"side_effects": "@LED_MUT@"}, 1, ("E16", "W02"), ()),
    "E16 and E13 under policy none": (
        _md("lean", "verify-only", policy="none") + _NOWORK + _PROHIBIT,
        {"side_effects": "@LED_MUT@"}, 1, ("E16", "E13"), ()),
    "W10 prohibition with only unknown journeys": (
        _md("lean", "verify-only", policy="allowed") + _NOWORK + _PROHIBIT,
        {"side_effects": "@LED_UNK@"}, 0, ("W10",), ("E16", "E14")),
    "W09 policy none with unknown journeys": (
        _md("lean", "verify-only", policy="none") + _NOWORK, {"side_effects": "@LED_UNK@"}, 0, ("W09",), ("E14",)),
    "E14 unknown journeys under strict mode": (
        _md("lean", "verify-only", policy="none") + _NOWORK,
        {"side_effects": "@LED_UNK@", "strict_side_effects": True}, 1, ("E14",), ("W09",)),
    "E15 policy none with no ledger": (
        _md("lean", "verify-only", policy="none") + _NOWORK, {"side_effects": "@LED_ABSENT@"}, 1, ("E15",), ()),
    "E15 policy none with an incomplete ledger": (
        _md("lean", "verify-only", policy="none") + _NOWORK, {"side_effects": "@LED_INCOMPLETE@"}, 1,
        ("E15",), ()),
    "W11 policy allowed with no ledger": (
        _md("lean", "verify-only", policy="allowed") + _NOWORK, {"side_effects": "@LED_ABSENT@"}, 0,
        ("W11",), ("E15",)),
    "no ledger flag -> no ledger rules": (
        _md("lean", "verify-only", policy="none") + _NOWORK + _PROHIBIT, {}, 0, (), ("E13", "E15", "E16")),
}


def _lint_self_test() -> int:
    import tempfile
    fails = 0
    tmp = tempfile.mkdtemp(prefix="iter-spec-selftest-")
    hists = {
        "@HIST_OK@": {"journeys": {"J-01": {"status": "passing"}, "J-02": {"status": "already_passing"}}},
        "@HIST_BAD@": {"journeys": {"J-01": {"status": "passing"}, "J-02": {"status": "failing"}}},
        "@HIST_SHAPE@": {"journeys": []},
        "@HIST_REC@": {"journeys": {"J-01": "passing", "J-02": 42}},
    }
    for token, payload in hists.items():
        with open(f"{tmp}/{token.strip('@')}.json", "w", encoding="utf-8") as fh:
            json.dump(payload, fh)
    with open(f"{tmp}/HIST_BAD_JSON.json", "w", encoding="utf-8") as fh:
        fh.write("{ not json at all")
    hists["@HIST_BAD_JSON@"] = None
    # HARD-3 ledgers: J-01 declared mutating (a target in every fixture).
    def _led(status1: str, complete: bool = True) -> dict:
        rec = {"status": status1, "declared": "mutating" if status1 == "mutating" else None,
               "note": "launches a run", "observed_mutating": False,
               "step_hints": [{"n": 1, "text": "click Run", "words": ["run"]}]}
        return {"complete": complete, "errors": [] if complete else ["sidecar unreadable"],
                "declaration_digest": "0" * 64,
                "journeys": {"J-01": rec, "J-02": {"status": "unknown"}, "J-03": {"status": "unknown"}}}
    ledgers = {"@LED_MUT@": _led("mutating"), "@LED_UNK@": _led("unknown"),
               "@LED_INCOMPLETE@": _led("mutating", complete=False)}
    for token, payload in ledgers.items():
        with open(f"{tmp}/{token.strip('@')}.json", "w", encoding="utf-8") as fh:
            json.dump(payload, fh)
    for name, (text, kwargs, want_rc, must, must_not) in _LINT_FIXTURES.items():
        kwargs = dict(kwargs)
        jh = kwargs.get("journey_history")
        if jh in hists:
            kwargs["journey_history"] = f"{tmp}/{jh.strip('@')}.json"
        se = kwargs.get("side_effects")
        if isinstance(se, str) and se.startswith("@"):
            kwargs["side_effects"] = f"{tmp}/{se.strip('@')}.json"
        res = lint_spec(text, **kwargs)
        got = {f["rule"] for f in res["errors"]} | {f["rule"] for f in res["warnings"]}
        rc = 2 if res["input_error"] else (1 if res["errors"] else 0)
        if res["input_error"]:
            got.add("INPUT")
        ok = rc == want_rc and all(r in got for r in must) and not any(r in got for r in must_not)
        print(f"  {'PASS' if ok else 'FAIL'}  lint: {name} (rc={rc}, want {want_rc}; rules={sorted(got)})")
        fails += 0 if ok else 1
    # HARD-3 owns the ids HARD-2 reserved for it; the block must be complete.
    for rule in ("E06", "E13", "E14", "E15", "E16", "W02", "W09", "W10", "W11"):
        if rule not in _RULE_TEXT:
            print(f"  FAIL  lint: HARD-3 rule {rule} is not implemented")
            fails += 1
    # The prompt context is byte-identical-safe: nothing when nothing applies.
    unk = f"{tmp}/LED_UNK.json"
    if render_side_effect_context("lane", unk, _md("lean", "verify-only") + _NOWORK) != "":
        print("  FAIL  context: no policy + no mutating journey must render NOTHING")
        fails += 1
    lane = render_side_effect_context("lane", f"{tmp}/LED_MUT.json", _md("lean", "verify-only") + _NOWORK)
    if not (lane.startswith("SIDE-EFFECT CONTEXT (deterministic, engine-built): spec Side-effect policy: "
                            "not declared; MUTATING: J-01 (declared)") and _LANE_RULE in lane):
        print(f"  FAIL  context: lane block for a mutating target ({lane!r})")
        fails += 1
    if render_side_effect_context("evaluator", f"{tmp}/LED_ABSENT.json", _md("lean", policy="none")) != "":
        print("  FAIL  context: an unavailable ledger renders nothing in the evaluator prompt")
        fails += 1
    if "UNAVAILABLE" not in render_side_effect_context("decomposer", f"{tmp}/LED_ABSENT.json"):
        print("  FAIL  context: the decomposer is told when the ledger is unavailable")
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


def cmd_side_effect_context(argv: list[str]) -> int:
    """Prints the engine-built side-effect prompt context (or nothing). Never
    fails the caller: any problem prints nothing and exits 0."""
    opts = _parse_opts(argv, ("--mode", "--side-effects", "--spec", "--makeup-journeys", "--lane-kind"), ())
    mode = opts.get("--mode", "lane")
    if mode not in ("lane", "evaluator", "decomposer"):
        print(f"iter_spec: unknown --mode {mode!r}", file=sys.stderr)
        return 0
    spec_text = None
    if opts.get("--spec"):
        try:
            spec_text = _read_spec(opts["--spec"])
        except OSError:
            spec_text = None
    try:
        text = render_side_effect_context(mode, opts.get("--side-effects"), spec_text,
                                          _JOURNEY_ID_RE.findall(opts.get("--makeup-journeys") or ""),
                                          lane_kind=opts.get("--lane-kind") or "lean")
    except Exception as exc:  # noqa: BLE001 — a prompt helper must never break a dispatch
        print(f"iter_spec: side-effect context unavailable: {exc}", file=sys.stderr)
        return 0
    if text:
        print(text)
    return 0


def cmd_policy_intent(argv: list[str]) -> int:
    """Print the spec's side-effect policy intent (see policy_intent); exit 2
    when the spec cannot be read. The engine's fail-closed fallback when the
    lint itself did not complete."""
    try:
        text = _read_spec(argv[0])
    except (OSError, IndexError) as exc:
        print(f"iter_spec: unreadable: {exc}", file=sys.stderr)
        return 2
    print(policy_intent(text))
    return 0


def cmd_ledger_ok(argv: list[str]) -> int:
    """exit 0 only when the ledger is available, complete and (with
    --build-id) this build's; otherwise 1 with the reason on stderr."""
    opts = _parse_opts(argv[1:], ("--build-id",), ())
    info = load_side_effect_ledger(argv[0] if argv else None, opts.get("--build-id"))
    if info["availability"] == "ok":
        return 0
    print(f"iter_spec: side-effect ledger {info['availability']}: {info['reason']}", file=sys.stderr)
    return 1


def main(argv: list[str]) -> int:
    if argv and argv[0] == "side-effect-context":
        return cmd_side_effect_context(argv[1:])
    if len(argv) >= 2 and argv[0] == "policy-intent":
        return cmd_policy_intent(argv[1:])
    if argv and argv[0] == "ledger-ok":
        return cmd_ledger_ok(argv[1:])
    if len(argv) >= 2 and argv[0] == "has-implementation-work":
        return cmd_has_implementation_work(argv[1])
    if len(argv) >= 2 and argv[0] == "metadata":
        return cmd_metadata(argv[1])
    if len(argv) >= 3 and argv[0] == "field":
        return cmd_field(argv[1:])
    if len(argv) >= 2 and argv[0] == "lint":
        return cmd_lint(argv[1:])
    if argv and argv[0] == "self-test":
        return _self_test()
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
