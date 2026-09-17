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
import html
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

# A POSSESSIVE is a determiner, so "launch J-04's run", "the user's portfolio
# run" and "the users' runs" name the same object as "launch a run": the words
# BETWEEN a verb and its object may carry one. `_scan_form` has already folded
# every apostrophe look-alike to "'", so one form covers ’s and 's alike.
# _GAP_WORD is the word token every bounded gap below repeats ({0,n}) — a
# possessive widens the WORD, never the number of words a gap may cross.
_POSS = r"(?:'s|s')"
_GAP_WORD = r"[\w-]+" + _POSS + r"?"

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
     re.compile(r"\b(?:ledger|row|record|run)s?[\s-]*(?:row[\s-]*)?count\s*(?:[:=\u2013\u2014-]\s*)?"
                r"(?:(?:must|should|will|shall|may)\s+)?(?:(?:is|be|stays?|remains?|was|still)\s+){0,2}"
                r"(?:completely\s+|entirely\s+)?"
                r"(?:unchanged|the\s+same|constant|stable|identical)\b"
                r"|\b(?:ledger|row|record|run)s?[\s-]*(?:row[\s-]*)?count\s+(?:does\s+not|doesn't|must\s+not|should\s+not"
                r"|may\s+not|will\s+not|never)\s+(?:change|increase|grow)\b"
                r"|\bnumber\s+of\s+(?:ledger\s+)?(?:rows|records|runs|entries)\s+"
                r"(?:(?:is|stays|remains|must\s+(?:stay|remain|be))\s+)?(?:still\s+)?(?:unchanged|the\s+same|constant"
                r"|at\s+\d+)\b"
                r"|\bledger\s+(?:still\s+)?(?:has|holds|contains)\s+(?:exactly\s+)?(?:the\s+same\s+number\s+of|\d+)\s+"
                r"(?:rows|records|entries)\b", re.I),
     "any", True),
    ("no-new-row-run-record",
     re.compile(r"\bno\s+new\s+(?:" + _GAP_WORD + r"\s+){0,2}?(?:rows?|runs?|records?"
                r"|ledger\s+(?:rows?|entry|entries))\b", re.I),
     "any", False),
    ("ledger-unchanged",
     re.compile(r"\bledger(?:[\s.-]+(?:rows?|entries|records?|file|table|store|db|database|jsonl?|csv|sqlite"
                r"|parquet))?\s+(?:(?:must|should|will|shall|may)\s+)?"
                r"(?:(?:is|are|be|stays?|remains?|was|were|still|left|kept)\s+){0,3}(?:completely\s+|entirely\s+"
                r"|fully\s+)?(?:unchanged|frozen|untouched|unmodified)\b", re.I),
     "any", False),
    ("must-not-mutate",
     re.compile(r"\bmust\s+not\s+(?:create|launch|append|write)\b"
                r"|\bmust\s+not\s+(?:start|trigger)\s+(?:a\s+|any\s+)?(?:new\s+)?(?:" + _GAP_WORD
                + r"\s+)?runs?\b", re.I),
     "any", False),
    ("no-write-mutation-launch",
     re.compile(r"\bno\s+(?:writes?|mutations?|launch(?:es)?)\b(?![-\w])", re.I), "any", False),
    ("any-new-run-launch",
     re.compile(r"\bany\s+new\s+(?:" + _GAP_WORD + r"\s+){0,3}?run\s+launch(?:es)?\b", re.I), "any", False),
)
_PRE_EXISTING_ROWS_RE = re.compile(r"\bpre-?existing\s+(?:ledger\s+)?$", re.I)

# Two ACTIVITIES — creating, editing, deleting, writing, appending, adding,
# inserting, modifying, changing, updating, removing or reordering ledger rows
# (or "the ledger"), and launching, starting, triggering, creating, executing,
# submitting or re-running a run or backtest — are decided by one rule the
# decomposer contract states word for word:
#   * on an OUT OF SCOPE item, mentioning an activity (any verb form, a passive,
#     or a noun such as "new run launches" / "ledger writes") is a prohibition;
#   * on a TC or DEFINITION OF DONE item, a SENTENCE that mentions an activity is
#     a prohibition when a negation in it reaches the activity:
#       - "not", "n't", "never", "cannot", "avoid", "refrain", "prevent",
#         "prohibit", "forbid", "disallow", "exclude(d)", "exclusion" and "out of
#         scope" reach it wherever they stand in the sentence;
#       - a noun-phrase negation — "no", "none", "nothing", "nobody", "no one",
#         "neither", "nor", "without", "except", "excluding", and a "not" after a
#         comma, "(", "and" or "but" and before "a" / "an" / "the" — reaches an
#         activity after it in its own clause (no subordinator, semicolon, colon
#         or dash in between; asides skipped), an activity whose own phrase
#         holds it ("writes nothing to the ledger"), or an activity it follows as
#         the predicate ("Ledger writes: none");
#     "none", "0" or "zero" right after an activity ("New runs launched: 0") is a
#     prohibition too;
#   * except a negation about "pre-existing" data — its object ("no
#     pre-existing row is edited", "must not modify any pre-existing row") or
#     its subject clause ("…, pre-existing rows are not edited") — unless that
#     negation directly governs an activity after it ("does not launch a new
#     run");
#   * an activity whose own object or subject is only "pre-existing" rows
#     (entries, records, runs — never "the pre-existing ledger") is the
#     invariant itself, in OUT OF SCOPE too ("edits to pre-existing ledger
#     rows"), and so is one followed by a carve-out for a journey's own step
#     ("launching runs beyond J-04's own step 1");
#   * "not only", "whether or not", "if not", "or not", "no doubt", "no matter"
#     negate nothing;
#   * a sentence that states a refused request ("… is rejected", "… responds
#     4xx / with an error", "… raises `…Refused`", "a validation error is
#     shown", "the login page opens", a `refusal_…` field) may say with a
#     noun-phrase negation that no row or run results from it ("… and no run is
#     created", "… appends no ledger row"); a "not" still counts there.
# Re-running a JOURNEY ("re-run J-04") is a replay, not an activity. A ledger
# phrase that names a UI, code or tooling thing ("the ledger rows grid", "the
# ledger writer", "ledger/store.py", "the assumption ledger") is not the ledger.
# Text is read after markdown emphasis, code-span backticks, HTML entities and
# look-alike apostrophes, hyphens and spaces are normalised (a soft hyphen is
# dropped); an item's wrapped lines are part of it; a sentence ends at ; or at
# . ! ? before a space, never inside parentheses, an abbreviation or a number.
# The rule errs toward reporting: a false positive costs a rewrite the E16 text
# spells out, a false negative lets the contradiction through.
_RE_PREFIX = r"(?:\(re\))?\b(?:re-?)?"
_LEDGER_VERB = (r"(?:creat(?:e|es|ed|ing)|edit(?:s|ed|ing)?|delet(?:e|es|ed|ing)|writ(?:e|es|ing|ten)|wrote"
                r"|append(?:s|ed|ing)?|add(?:s|ed|ing)?|insert(?:s|ed|ing)?|modif(?:y|ies|ied|ying)"
                r"|chang(?:e|es|ed|ing)|updat(?:e|es|ed|ing)|remov(?:e|es|ed|ing)|mutat(?:e|es|ed|ing)"
                r"|alter(?:s|ed|ing)?|touch(?:es|ed|ing)?|re-?order(?:s|ed|ing)?)(?!-\w)")   # not "append-only"
_RUN_VERB = (r"(?:launch(?:es|ed|ing)?|start(?:s|ed|ing)?|trigger(?:s|ed|ing)?|creat(?:e|es|ed|ing)"
             r"|execut(?:e|es|ed|ing)|submit(?:s|ted|ting)?|spawn(?:s|ed|ing)?|kick(?:s|ed|ing)?\s+off)")
_ANY_VERB = r"(?:\(re\))?(?:re-?)?(?:" + _LEDGER_VERB + r"|" + _RUN_VERB + r")\b"
_ROW_WORD = r"(?:rows?|entry|entries|records?)"
# A noun right after "ledger (rows)" or "run" that makes the phrase a UI, code or tooling thing: "the
# ledger rows grid", "the ledger writer", "the run list".
_UI_NOUN = (r"(?:pages?|views?|tabs?|panels?|panes?|screens?|ui|widgets?|charts?|exports?|filters?|headers?"
            r"|columns?|links?|buttons?|counts?|summar(?:y|ies)|reports?|grids?|lists?|sections?|cards?"
            r"|modals?|dialogs?|drawers?|toolbars?|components?|api|endpoints?|schemas?|quer(?:y|ies)|logs?"
            r"|histor(?:y|ies)|feeds?|affordances?|icons?|badges?|tooltips?|layouts?|styl(?:e|es|ing)"
            r"|pagination|sort(?:ing)?|search|forms?|menus?|details?|status|fixtures?|mocks?|stubs?|samples?"
            r"|examples?|templates?|docs?|documentation|tests?|specs?|kinds?|types?|paths?|writers?|readers?"
            r"|modules?|code|class(?:es)?|functions?|services?|routers?|renderers?|helpers?|utils?|scripts?"
            r"|tools?|logic|ids?|names?|dirs?|director(?:y|ies)|folders?|flows?|wizards?)")
# ... or a code file or directory ("app/ledger.py", "ledger/store.py"), not the ledger's data.
_CODE_FILE = r"(?:/\w|[\s.]+(?:py|ts|tsx|js|jsx|mjs|rb|go|rs|java|kt|sh|sql|md|ya?ml|toml)\b)"
# "The assumption ledger" and "the anti-goal ledger" are goal-mode documents, not a product ledger.
_LEDGER_WORD = (r"\b(?:\w[\w-]*-)?(?<!assumption )(?<!assumption-)(?<!anti-goal )(?<!anti-goal-)"
                r"(?:(?<!/)|(?=ledger[\s.]+(?:jsonl?|csv|db|sqlite3?|parquet)\b))ledger")
_LEDGER_OBJ = (_LEDGER_WORD + r"(?:[\s-]+" + _ROW_WORD + r")?\b"
               r"(?![\s-]+(?:" + _ROW_WORD + r"[\s-]+)?" + _UI_NOUN + r"\b)(?!" + _CODE_FILE + r")")
_LEDGER_NOUN = (r"(?:creation|insertion|deletion|removal|addition|append|edit|change|update|write|modification"
                r"|mutation)s?")
# A test / tooling run ("the pytest run", "a browser-QA run", "a dry run") is not the product's run.
_TOOL_RUN = ("test", "tests", "pytest", "jest", "vitest", "cypress", "playwright", "lint", "build", "smoke", "e2e",
             "unit", "eval", "evals", "suite", "qa", "replay", "dry", "ci", "check")
# The same word one apostrophe further left still names a tooling run ("the
# suite's run", "the tests' runs"), so the guard covers the possessive too —
# expanding possessive matching must not turn a test run into a product run.
_RUN_NOUN = ("".join(rf"(?<!\b{w} )(?<!\b{w}-)(?<!\b{w}'s )" + (rf"(?<!\b{w}' )" if w.endswith("s") else "")
                     for w in _TOOL_RUN)
             + r"(?:runs?|backtests?)\b(?![\s-]+(?:" + _UI_NOUN + r"|rows?|table)\b)(?!/\w)(?!-\w)")
_ASIDE = (r"(?:\([^()]{0,80}\)|,[^,.;!?]{0,60},|[\u2013\u2014][^\u2013\u2014.;!?]{0,60}[\u2013\u2014]"
          r"|--\s[^.;!?]{0,60}?\s--)")
# The words between a ledger verb and "ledger": plain words, a parenthesis, a short comma aside, a dash
# aside, or a comma before another verb ("create, edit or delete ledger rows") — never a clause or a
# list of other things ("never rewritten, every run an operator act, the ledger …").
_LEDGER_GAP = (r"(?P<gap>(?:[^.;:!?,()\u2013\u2014]|\([^()]{0,60}\)|,(?=\s*(?:(?:or|and|nor)\s+)?" + _ANY_VERB
               + r")|,[^.;:!?,()]{1,28},|[\u2013\u2014][^\u2013\u2014.;!?]{0,60}[\u2013\u2014]){0,80}?)")
_PASSIVE_AUX = (r"(?:(?:is|are|was|were|be|been|being|gets?|got|has\s+been|have\s+been)\s+(?:not\s+|never\s+)?"
                r"|(?:must|should|will|shall|may|can|could|would|might)\s+(?:not\s+|never\s+)?be\s+)(?:ever\s+)?")
_LEDGER_PARTICIPLE = (r"(?:(?:creat|edit|delet|append|add|insert|modifi|chang|updat|remov|mutat|alter|touch"
                      r"|re-?order)ed|written)\b")
_RUN_PARTICIPLE = r"(?:launched|started|triggered|created|executed|submitted|spawned|kicked\s+off)\b"
# "Ledger rows added: 0", "New runs launched - none": a count or "none" right after the activity
_COUNT_SEP = r"\s*(?:[:=\u2013\u2014]|\s-\s)"
_COUNT_NONE_RE = re.compile(_COUNT_SEP + r"\s*(?:0|zero|none|nothing)\b|" + _COUNT_SEP + r"\s*no\b(?=\s*(?:$|[.,;:!?)]))",
                            re.I)
_ACTIVITY_PARTS: tuple = (
    # (name, form, pattern) — each an activity MENTION. `form` says where the object stands: "verb" = in
    # the named group `gap` after the verb; "subject" = the words right before the match.
    ("ledger-row-edit", "verb", _RE_PREFIX + _LEDGER_VERB + r"\b" + _LEDGER_GAP + r"\b" + _LEDGER_OBJ),
    ("ledger-row-edit", "subject", _LEDGER_OBJ + r"\s+(?:[\w'-]+\s+){0,3}?" + _PASSIVE_AUX + r"(?:left\s+)?(?:re-?)?"
                                   + _LEDGER_VERB + r"\b"),
    ("ledger-row-edit", "subject", _LEDGER_OBJ + r"\s+(?:re-?)?" + _LEDGER_PARTICIPLE + r"(?=" + _COUNT_SEP + r")"),
    ("ledger-row-edit", "verb", r"\bno\s+(?P<gap>(?:" + _GAP_WORD + r"\s+){0,2}?)" + _LEDGER_OBJ + r"\s+(?:re-?)?"
                                + _LEDGER_PARTICIPLE),
    ("ledger-row-edit", "subject", _LEDGER_WORD + r"[\s-]+(?:" + _ROW_WORD + r"[\s-]+)?" + _LEDGER_NOUN
                                   + r"\b(?![\s-]+" + _UI_NOUN + r"\b)"),
    ("ledger-row-edit", "verb", _LEDGER_NOUN + r"\s+(?:of|to|in)\s+(?P<gap>(?:(?:new|the|any|existing|pre-?existing)"
                                r"\s+)?(?:" + _GAP_WORD + r"\s+)?)" + _LEDGER_OBJ),
    ("any-new-run-launch", "verb", r"(?<!-)" + _RE_PREFIX + r"(?P<verb>" + _RUN_VERB + r")(?:\s*" + _ASIDE
                                   + r")?\s+(?P<gap>(?:" + _GAP_WORD + r"[\s-]+){0,4}?)" + _RUN_NOUN),
    ("any-new-run-launch", "subject", r"\b" + _RUN_NOUN + r"\s+(?:re-?)?" + _RUN_PARTICIPLE + r"(?=" + _COUNT_SEP
                                      + r")"),
    ("any-new-run-launch", "verb", r"\bno\s+(?P<gap>(?:" + _GAP_WORD + r"\s+){0,2}?)" + _RUN_NOUN + r"\s+(?:re-?)?"
                                   + _RUN_PARTICIPLE),
    ("any-new-run-launch", "subject", r"\b" + _RUN_NOUN + r"\s+(?:[\w'-]+\s+){0,3}?" + _PASSIVE_AUX
                                      + r"(?:re-?)?(?:launched|started|triggered|created|executed|submitted|spawned"
                                      r"|kicked\s+off)\b"),
    ("any-new-run-launch", "verb", r"\b(?:is|are|was|were)\s+(?P<gap>(?:an?\s+|any\s+|the\s+)?(?:" + _GAP_WORD
                                   + r"\s+){0,2}?)runs?\s+(?:ever\s+)?(?:re-?)?(?:launched|started|triggered"
                                   r"|created)\b"),
    ("any-new-run-launch", "subject", r"\bruns?[\s-]+launch(?:es)?\b(?![\s-]+" + _UI_NOUN + r"\b)"),
    ("any-new-run-launch", "verb", r"\blaunch(?:es)?\s+of\s+(?P<gap>(?:an?\s+|any\s+)?(?:new\s+)?(?:" + _GAP_WORD
                                   + r"\s+)?)runs?\b"),
    # "re-run J-04" replays a journey; only a run NOUN close behind the verb makes
    # it a launch — so the gap stays a determiner ("the", or a possessive: "J-04's
    # portfolio run") plus at most one modifier.
    ("any-new-run-launch", "verb", r"\bre-?run(?:s|ning)?\s+(?P<gap>(?:(?:the|[\w-]+" + _POSS + r")\s+)?(?:"
                                   + _GAP_WORD + r"\s+)?)" + _RUN_NOUN),
    ("any-new-run-launch", "verb", r"\brun(?:s|ning)?\s+(?P<gap>(?:an?|any|another|the|new|more|extra)\s+"
                                   r"(?:" + _GAP_WORD + r"\s+){0,2}?)backtests?\b"),
)
_ACTIVITY_RES: tuple = tuple((name, form, re.compile(rx, re.I)) for name, form, rx in _ACTIVITY_PARTS)
_MENTION_INFO: dict = {rx: (name, form) for name, form, rx in _ACTIVITY_RES}
_LEDGER_VERB_RX = _ACTIVITY_RES[0][2]
_LEDGER_RXS = frozenset(rx for name, _f, rx in _ACTIVITY_RES if name == "ledger-row-edit")
_ROW_OBJECT_RE = re.compile(r"ledger[\s-]+" + _ROW_WORD + r"\b", re.I)
_RUN_VERB_RX = next(rx for _n, _f, rx in _ACTIVITY_RES if "(?P<verb>" in rx.pattern)
# "Add sorting to ledger records", "a CSV export of ledger entries": the verb's object is another thing.
_UI_HEAD_RE = re.compile(r"\b" + _UI_NOUN + r"\s+(?:of|for|to|on|in|from|with|into|about)\s+"
                         r"(?:(?:the|a|an|all|any|its|their|our|new|existing)\s+)?$", re.I)
# "Launching runs beyond J-04's own step 1": the journey's own step is carved out of the activity.
_CARVE_OUT_RE = re.compile(r"\s*,?\s*(?:beyond|other\s+than|besides|apart\s+from|except(?:ing)?(?:\s+for)?"
                           r"|outside(?:\s+of)?|on\s+top\s+of)\s+(?:what\s+|those\s+of\s+)?(?:the\s+)?J-\d+(?:'s)?"
                           r"\s+(?:own\s+)?(?:numbered\s+|run\s+)?steps?\b", re.I)
# "Start the app and run the tests": a "run" right after a conjunction or modal is a verb.
_VERB_RUN_GAP_RE = re.compile(r"(?:^|\s)(?:and|or|nor|to|then|not|also|can|will|must|should)\s+$", re.I)
# "The launched run", "the triggered backfill runs": a participle before its noun is an adjective; the
# past tense takes a determiner ("never launched a new run").
_PARTICIPLE_RE = re.compile(r"(?:ed|off)$", re.I)
_DETERMINER_START_RE = re.compile(r"(?:(?:an?|any|another|the|new|more|extra|fresh|additional|further|second|one|two"
                                  r"|three|its|their|his|her|our|this|that|these|those|no|several|some|each|every"
                                  r"|multiple|many|all|\d+)\b|[\w-]+" + _POSS + r")", re.I)
# OUT OF SCOPE also lists bare nouns as an item or list element: "Any new run", "New portfolio runs",
# "Excluded: the new ledger rows" (not "Styling of new ledger rows", not "any prior runs").
_OOS_NOUN_RE = re.compile(
    r"(?:^[ \t]*(?:>[ \t]*)?(?:(?:[-*+]|\d+[.)]|[a-z][.)])[ \t]+)?(?:\[[ xX]\][ \t]+)?(?:[A-Za-z][\w -]{0,30}:\s*)?"
    r"|[,;/|(:]\s*|\s-\s+|\b(?:or|and|nor|plus|no)\s+)(?:(?:the|a|an)\s+)?"
    r"(?:(?:any|new|more|extra|additional)\s+(?!(?:existing|prior|previous|old|older|earlier|completed|finished|past"
    r"|archived|stored|pre-?existing|historical|recorded|cited)\b)(?:" + _GAP_WORD + r"\s+){0,2}?" + _RUN_NOUN
    + r"|new\s+(?:" + _GAP_WORD + r"\s+)?ledger\s+(?:rows?|entries|records)\b)", re.I)
_NEG_CUE_RE = re.compile(
    r"\b(?:no[\s-]one|no|not|never|nor|neither|none|nothing|nobody|without|cannot|cant|[a-z]+n't|dont|doesnt|didnt"
    r"|wont|isnt|arent|wasnt|werent|mustnt|shouldnt|shant|hasnt|havent|hadnt|couldnt|wouldnt"
    r"|avoid(?:s|ed|ing)?|refrain(?:s|ed|ing)?|prevent(?:s|ed|ing)?|prohibit(?:s|ed|ing)?"
    r"|forbid(?:s|den|ding)?|forbade|disallow(?:s|ed|ing)?|exclu(?:de|des|ded|ding|sions?)|except(?:ing)?"
    r"|exception\s+of|out[\s-]+of[\s-]+scope)\b", re.I)
# A DETERMINER negation negates what follows it; every other negation word negates its clause's verb.
_DETERMINER_CUE_RE = re.compile(r"(?:no|none|nothing|nobody|no[\s-]one|neither|nor|without|except(?:ing)?"
                                r"|excluding|exception\s+of)$", re.I)
# "…, not a stale screenshot", "writes X and not the canonical file": a "not" that negates a noun phrase
_CONTRASTIVE_BEFORE_RE = re.compile(r"(?:[,(]|\b(?:and|but))\s*$", re.I)
_CONTRASTIVE_AFTER_RE = re.compile(r"\s+(?:a|an|the)\b", re.I)
# "Ledger writes: none", "new runs launched - none", "… are none": the determiner IS the predicate.
_PREDICATE_NONE_RE = re.compile(r"(?:[:=\u2013\u2014]|\s-|\b(?:is|are|was|were|be))\s*$", re.I)
_PREDICATE_WORDS = ("no", "none", "nothing")
_PREDICATE_NO_END_RE = re.compile(r"\s*(?:$|[.,;:!?)])")                       # "…: no" ends its clause
_IDIOM_NOT_BEFORE_RE = re.compile(r"\b(?:or|if|whether\s+or)\s+$", re.I)         # "or not", "if not"
_IDIOM_NOT_AFTER_RE = re.compile(r"^\s+only\b", re.I)                            # "not only"
_IDIOM_NO_AFTER_RE = re.compile(r"^\s+(?:doubt|matter)\b", re.I)                 # "no doubt", "no matter"
_PRE_EXISTING_RE = re.compile(r"\bpre-?existing\b", re.I)
_PRE_EXISTING_SUBJECT_RE = re.compile(
    r"\bpre-?existing\s+(?:[\w-]+\s+){0,2}?(?:rows?|records?|entries|entry|runs?|data)\s+(?:(?:is|are|was|were"
    r"|must|should|will|shall|can|may|do|does|did|stays?|remains?)\s+)?$", re.I)
_WORD_RE = re.compile(r"[\w'-]+")
_PRE_EXISTING_WORDS = frozenset({"pre-existing", "preexisting"})
_QUALIFIER_WORDS = (frozenset({"any", "all", "the", "a", "an", "its", "their", "our", "these", "those", "such", "of",
                              "one", "single", "existing", "older", "old", "prior", "previous", "earlier", "ever",
                              "again", "also", "even", "already", "to", "into", "in", "on", "from", "within"})
                    | _PRE_EXISTING_WORDS)
_COORD_WORDS = frozenset({"or", "and", "nor", "either", "both", "re", "ever", "again", "also", "even"})
_SUBJECT_WORDS = _QUALIFIER_WORDS | _COORD_WORDS | {"new", "ledger", "row", "rows", "entry", "entries", "record",
                                                   "records", "run", "runs"}
_CLAUSE_BREAK_RE = re.compile(r"[,;:()\u2013\u2014]")
_GOVERN_ASIDE_RE = re.compile(r"\([^()]{0,80}\)|[\u2013\u2014]\s*[^\u2013\u2014.;!?]{0,60}[\u2013\u2014]"
                              r"|--\s[^.;!?]{0,60}?\s--|,\s*(?:[^,.;!?\s()]+\s+){0,4}[^,.;!?\s()]+\s*,")
_ONCE_RE = re.compile(r"^\s*once\b", re.I)                   # "without once launching", "never once"
_GOVERN_BREAK_RE = re.compile(r"[;:\u2013\u2014]|\s-\s")
_VERB_WORD_RE = re.compile(r"(?:re-?)?(?:" + _LEDGER_VERB + "|" + _RUN_VERB + ")", re.I)
_SUBORDINATOR_RE = re.compile(r"\b(?:when|whenever|while|after|before|if|unless|until|once|because|since|as"
                              r"|whereas)\b", re.I)
_REFUSAL_RE = re.compile(
    r"\b(?:is|are|was|were|gets?|got)\s+(?:\w+\s+)?(?:refused|rejected|denied)\b"
    r"|\b(?:responds?|returns?|answers?|replies|reply)\s+(?:with\s+)?(?:an?\s+|HTTP\s+|status\s+)?"
    r"(?:4\d\d\b|error\b(?!-)(?!\s+(?:count|panel|log|logs|rate|list|page|tab)\b))"
    r"|\braises?\s+(?:an?\s+)?\w*(?:Refused|Rejected|Denied|Error|Exception)\b"
    r"|\b(?:an?|the)\s+(?:validation\s+)?error\s+(?:message\s+)?(?:is|was|gets)\s+(?:shown|displayed|returned|raised"
    r"|rendered)\b|\b(?:an?|the)\s+(?:validation\s+)?error\s+appears\b"
    r"|\b(?:shows?|displays?|renders?)\s+(?:an?|the)\s+(?:validation\s+)?error\b(?!-)"
    r"(?!\s+(?:count|panel|log|logs|rate|list|page|tab)\b)"
    r"|\b(?:refusal|rejection)_\w+\s*(?:reads|is|=|:)"
    r"|\b(?:redirects?\s+to|opens?|is\s+redirected\s+to)\s+the\s+(?:login|sign[\s-]?in)\s+page\b"
    r"|\bthe\s+(?:login|sign[\s-]?in)\s+page\s+(?:opens|loads|appears|is\s+(?:shown|displayed))\b", re.I)
_OTHER_REQUEST_RE = re.compile(r"\b(?:that|which|who|whose|previously|earlier|already|once|still)\s*$", re.I)
_NOT_A_BREAK_RE = re.compile(r"\b(?:e\.g|i\.e|etc|vs|cf|approx|incl|resp|fig|max|min|ca)\.|\bno\.(?=\s*\d)"
                             r"|(?<=\d)\.(?=\d)", re.I)
_SENTENCE_END_RE = re.compile(r"[.!?](?=\s|$|[\"')\]])|;")
_PAREN_RE = re.compile(r"\([^()]*\)")
_CODE_SPAN_RE = re.compile(r"`([^`]*)`")
_ZERO_WIDTH_RE = re.compile("[\u200b\u200c\u200d\u2060\ufeff\u00ad]")
_HYPHEN_LOOKALIKE_RE = re.compile("[\u2010\u2011\u2012\u2212]")
_APOSTROPHE_LOOKALIKE_RE = re.compile("[\u2018\u2019\u02bc\u00b4\uff07]")
_EMPHASIS_UNDERSCORE_RE = re.compile(r"(?<![A-Za-z0-9])_+|_+(?![A-Za-z0-9])")
_ELLIPSIS_RE = re.compile("[.]{3}|\u2026")
_WINDOW = 300


def _scan_form(line: str) -> str:
    """The text the prohibition rule reads: HTML entities decoded, look-alike
    spaces / hyphens / apostrophes unified, zero-width characters and soft
    hyphens dropped, markdown emphasis and code-span backticks removed (a code
    span's sentence punctuation becomes a space), and the periods of
    abbreviations and numbers blanked."""
    s = html.unescape(line)
    s = _ZERO_WIDTH_RE.sub("", s).replace("\u00a0", " ").replace("\u202f", " ")
    s = _HYPHEN_LOOKALIKE_RE.sub("-", s)
    s = _APOSTROPHE_LOOKALIKE_RE.sub("'", s)
    s = re.sub(r"(?<=[A-Za-z])`(?=t\b)", "'", s)                     # doesn`t
    s = _CODE_SPAN_RE.sub(lambda m: re.sub(r"[.;:!?]", " ", m.group(1)), s)
    s = s.replace("`", "").replace("*", "")
    s = _EMPHASIS_UNDERSCORE_RE.sub("", s)
    s = _ELLIPSIS_RE.sub("   ", s)                                  # "must never... launch"
    return _NOT_A_BREAK_RE.sub(lambda a: a.group(0).replace(".", " "), s)


def _sentences(text: str) -> list[tuple[int, int]]:
    """(start, end) spans of the sentences of `text` (already in scan form):
    they end at ; or at . ! ? before a space, never inside parentheses."""
    masked = text
    for _ in range(3):
        masked = _PAREN_RE.sub(lambda p: re.sub(r"[.;!?]", " ", p.group(0)), masked)
    spans, start = [], 0
    for m in _SENTENCE_END_RE.finditer(masked):
        spans.append((start, m.end()))
        start = m.end()
    if start < len(text):
        spans.append((start, len(text)))
    return spans


def _false_mention(m: "re.Match[str]") -> bool:
    """A match that is not the activity: a carve-out for a journey's own step
    follows it ("launching runs beyond J-04's own step 1"), another thing is
    the verb's object, the "run" is a verb, or the participle is an
    adjective."""
    if _CARVE_OUT_RE.match(m.string, m.end()):
        return True
    if m.re is _LEDGER_VERB_RX:
        return bool(_UI_HEAD_RE.search(m.group("gap")))
    if m.re is _RUN_VERB_RX:
        gap = m.group("gap")
        return bool(_VERB_RUN_GAP_RE.search(gap)
                    or (_PARTICIPLE_RE.search(m.group("verb")) and not _DETERMINER_START_RE.match(gap)))
    return False


def _mentions(text: str) -> list["re.Match[str]"]:
    """Every activity mention in `text`, sorted by start."""
    found = []
    for _name, _form, rx in _ACTIVITY_RES:
        pos = 0
        while pos <= len(text):
            m = rx.search(text, pos)
            if not m:
                break
            if _false_mention(m):
                pos = m.start() + 1            # look for a later start
                continue
            found.append(m)
            pos = max(m.end(), m.start() + 1)
    return sorted(found, key=lambda m: m.start())


def _mention_name(m: "re.Match[str]") -> str:
    return _MENTION_INFO[m.re][0]


def _mention_qualified(text: str, m: "re.Match[str]") -> bool:
    """Is this mention's own object only "pre-existing" data — "edit or delete
    any pre-existing ledger row", "no pre-existing ledger row is edited"? Such a
    mention is the invariant itself, not the activity. Only ROWS (entries,
    records, runs) can be pre-existing this way: "the pre-existing ledger" is
    the ledger."""
    if m.re in _LEDGER_RXS and not _ROW_OBJECT_RE.search(m.group(0)):
        return False
    if _MENTION_INFO[m.re][1] == "verb":
        words = _WORD_RE.findall((m.groupdict().get("gap") or "").lower())
        i = 0
        while i < len(words) and (words[i] in _COORD_WORDS or _VERB_WORD_RE.fullmatch(words[i])):
            i += 1                              # "edit or delete …" shares one object
        rest = words[i:]
        return bool(rest) and all(w in _QUALIFIER_WORDS for w in rest) \
            and any(w in _PRE_EXISTING_WORDS for w in rest)
    tail = []
    before = _CLAUSE_BREAK_RE.split(text[max(0, m.start() - 80):m.start()])[-1]      # its own clause
    for w in reversed(_WORD_RE.findall(before.lower())):
        if w not in _SUBJECT_WORDS:
            break
        tail.append(w)
    return any(w in _PRE_EXISTING_WORDS for w in tail) and "new" not in tail


def _counting_cues(sentence: str) -> list["re.Match[str]"]:
    cues = []
    for c in _NEG_CUE_RE.finditer(sentence):
        word = c.group(0).lower()
        before = sentence[max(0, c.start() - 20):c.start()]
        after = sentence[c.end():c.end() + 20]
        if word == "not" and (_IDIOM_NOT_BEFORE_RE.search(before) or _IDIOM_NOT_AFTER_RE.match(after)):
            continue
        if word == "no" and _IDIOM_NO_AFTER_RE.match(after):
            continue
        cues.append(c)
    return cues


def _qualified(sentence: str, cue: "re.Match[str]", plain_starts: list[int]) -> bool:
    """Is this negation about "pre-existing" data (its object within six words
    of the same clause, or its subject clause), with no unqualified activity
    in between?"""
    rest = sentence[cue.end():cue.end() + 160]
    q = _PRE_EXISTING_RE.search(rest)
    if q:
        between = rest[:q.start()]
        k = bisect.bisect_left(plain_starts, cue.end())
        if (len(between.split()) <= 6 and not re.search(r"[;:]|[\u2013\u2014]", between)
                and not (k < len(plain_starts) and plain_starts[k] < cue.end() + q.start())):
            return True
    head = sentence[max(0, cue.start() - 160):cue.start()]
    clause = re.split(r"[,;:]|[\u2013\u2014]", head)[-1]
    if _PRE_EXISTING_SUBJECT_RE.search(clause):
        k = bisect.bisect_left(plain_starts, cue.start() - len(clause))
        return not (k < len(plain_starts) and plain_starts[k] < cue.start())
    return False


def _governs(sentence: str, cue: "re.Match[str]", plain: list, starts: list[int],
             determiner: bool) -> "re.Match[str] | None":
    """The activity this negation reaches AFTER it in its own clause: no
    subordinator or semicolon in between (asides skipped) and, for a
    determiner, no colon or lone dash either ("must not edit X — or launch Y"
    still reaches Y)."""
    k = bisect.bisect_left(starts, cue.end())
    if k >= len(plain):
        return None
    between = sentence[cue.end():starts[k]]
    if len(between) > _WINDOW:
        return None
    bare = _ONCE_RE.sub(" ", _GOVERN_ASIDE_RE.sub(" ", between))
    if _SUBORDINATOR_RE.search(bare) or ";" in bare or (determiner and _GOVERN_BREAK_RE.search(bare)):
        return None
    return plain[k]


def _containing(plain: list, starts: list[int], reach: list[int], cue: "re.Match[str]") -> "re.Match[str] | None":
    """The activity mention whose own phrase holds this negation ("writes
    nothing to the ledger")."""
    k = bisect.bisect_right(starts, cue.start()) - 1
    if k < 0 or reach[k] < cue.end():
        return None
    while k >= 0:
        if plain[k].end() >= cue.end():
            return plain[k]
        k -= 1
    return None


def _refused(sentence: str) -> bool:
    """Does the sentence state that the request it tests is refused?"""
    masked = _PAREN_RE.sub(lambda p: " " * len(p.group(0)), sentence)
    for r in _REFUSAL_RE.finditer(masked):
        before = masked[max(0, r.start() - 40):r.start()]
        near = " ".join(before.split()[-3:])
        if _NEG_CUE_RE.search(r.group(0)) or _NEG_CUE_RE.search(near) or _OTHER_REQUEST_RE.search(before) \
                or re.search(r"\b(?:is|are|was|were)\s+still\s+", r.group(0), re.I):
            continue
        return True
    return False


def _sentence_prohibition(sentence: str) -> "re.Match[str] | None":
    """The activity mention a TC / DoD sentence prohibits (see the rule above)."""
    mentions = _mentions(sentence)
    if not mentions:
        return None
    # an activity whose own object is only "pre-existing" is the invariant itself
    plain = [m for m in mentions if not _mention_qualified(sentence, m)]
    if not plain:
        return None
    for m in plain:
        if _COUNT_NONE_RE.match(sentence, m.end()):
            return m                         # "Ledger writes: none", "new runs launched: 0"
    cues = _counting_cues(sentence)
    if not cues:
        return None
    starts = [m.start() for m in plain]
    reach, far = [], -1
    for m in plain:
        far = max(far, m.end())
        reach.append(far)
    refused = None
    for cue in cues:
        determiner = bool(_DETERMINER_CUE_RE.fullmatch(cue.group(0))) or (
            cue.group(0).lower() == "not" and _CONTRASTIVE_AFTER_RE.match(sentence, cue.end()) is not None
            and _CONTRASTIVE_BEFORE_RE.search(sentence[max(0, cue.start() - 12):cue.start()]) is not None)
        if determiner:
            if refused is None:
                refused = _refused(sentence)
            if refused:
                continue                     # "… is rejected and no run is created"
        governed = _governs(sentence, cue, plain, starts, determiner)
        if governed is not None:
            return governed                  # "does not launch a new run": never exempt
        if determiner:
            inside = _containing(plain, starts, reach, cue)
            if inside is not None:
                return inside                # "writes nothing to the ledger"
            k = bisect.bisect_left(starts, cue.start())
            if not (k and cue.group(0).lower() in _PREDICATE_WORDS
                    and _PREDICATE_NONE_RE.search(sentence[max(0, cue.start() - 12):cue.start()])
                    and (cue.group(0).lower() != "no" or _PREDICATE_NO_END_RE.match(sentence, cue.end()))):
                continue                     # "no stored run has …, when … launches a run"
            if not _qualified(sentence, cue, starts):
                return plain[k - 1]          # "Ledger writes: none"
            continue
        if not _qualified(sentence, cue, starts):
            return plain[0]
    return None


_TC_LINE_RE = re.compile(
    r"^(?P<indent>[ \t]*)(?:>[ \t]*)*(?P<heading>#{1,6}[ \t]+)?(?:(?:[-*+]|\d+[.)])[ \t]+)?(?:\[[ xX]\][ \t]+)?"
    r"(?:\|(?:[^|\n]{0,12}\|){0,2}[ \t]*)?(?:\*{1,3}|_{1,3})?(?:test[ \t]+case[ \t]+)?[`(\[]?"
    r"(?P<tc>TC[-\u2010\u2011\u2012\u2013\u2212]\d+[a-z]?)(?![A-Za-z0-9])", re.I)
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
    top_closers: dict = {}
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
            key = (ch, size, col)
            if key not in top_closers:          # the top-level closers this opener shape accepts
                top_closers[key] = [j for j in by_char[ch]
                                    if closes[j][1] >= size and closes[j][2] == 0 and closes[j][3] <= col + 3]
            positions = top_closers[key]
            k = bisect.bisect_right(positions, i)
            if k < len(positions):
                end = positions[k]
            else:
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


_ANY_HEADING_LINE_RE = re.compile(r"^[ \t]{0,3}(?P<hashes>#{1,6})[ \t]+(?P<title>.*?)[ \t#]*$")


def _section_kind(title: str) -> str:
    words = re.sub(r"[^A-Z]+", " ", title.upper()).split()
    joined = " ".join(words)
    if joined.startswith(_METADATA_H2.upper()):
        return "metadata"
    if re.search(r"\b(?:OUT OF SCOPE|NOT IN SCOPE|NON GOALS|NONGOALS|EXCLUSIONS?)\b", joined):
        return "OUT OF SCOPE"
    if re.search(r"\bDEFINITION OF DONE\b", joined) or (words and words[0] == "DOD"):
        return "DEFINITION OF DONE"
    first = title.strip().split()[0] if title.strip() else ""
    if (words and words[0] in _PROSE_SECTIONS and len(words) <= 3
            and not re.match(r"[A-Za-z]+-", first)):          # "Goal-level acceptance tests" is not prose
        return "prose"
    return "other"


def _glued_headings(lines: list[str]) -> list[bool]:
    """True for a line in the same blank-line-free block as an earlier fence
    line, with another fence line somewhere below: a heading there may sit
    inside a code fence ("```" / "## Notes" / … / "```") whatever the pairing
    says."""
    fence = [bool(_FENCE_OPEN_RE.match(ln) or _FENCE_CLOSE_RE.match(ln)) for ln in lines]
    below, seen = [False] * len(lines), False
    for i in range(len(lines) - 1, -1, -1):
        below[i] = seen
        seen = seen or fence[i]
    glued, in_block = [False] * len(lines), False
    for i, ln in enumerate(lines):
        if not ln.strip():
            in_block = False
        elif fence[i]:
            in_block = True
        else:
            glued[i] = in_block and below[i]
    return glued


def _line_sections(lines: list[str], fenced: list[bool], hidden: "list[bool] | None" = None,
                   glued: "list[bool] | None" = None, glued_kinds: tuple = ()) -> list[str]:
    """The section kind of every line ('heading' for a heading line). A level-2
    heading always starts a section; a level-1 or level-3 heading does when its
    name is a known section (OUT OF SCOPE, DoD, a prose section, the metadata).
    A heading inside a fence or inside an HTML comment region (`hidden`) starts
    nothing, and neither does a heading of a `glued_kinds` kind that may sit
    inside a fence (`glued`, for the fence-ignoring reads: a section that hides
    lines must never be opened by what may be a quotation)."""
    kinds: list[str] = []
    kind = "other"
    for i, (ln, f) in enumerate(zip(lines, fenced)):
        h = None if f or (hidden is not None and hidden[i]) else _ANY_HEADING_LINE_RE.match(ln)
        if h:
            level = len(h.group("hashes"))
            named = _section_kind(h.group("title"))
            if glued is not None and glued[i] and named in glued_kinds:
                kinds.append(kind)
                continue
            if level == 2 or (level in (1, 3) and named != "other"):
                kind = named
                kinds.append("heading")
                continue
        kinds.append(kind)
    return kinds


def _indent_of(line: str) -> int:
    expanded = line.expandtabs(4)
    return len(expanded) - len(expanded.lstrip())


_ITEM_START_RE = re.compile(r"^[ \t]*(?:>[ \t]*)?(?:(?:[-*+]|\d+[.)]|[a-z][.)])[ \t]|\|)")
_MARKED_TC_RE = re.compile(r"^[ \t]*(?:>[ \t]*)*(?:#{1,6}[ \t]+|(?:[-*+]|\d+[.)])[ \t]+|\|)")


def _item_hit(scan: str, label: str) -> "tuple[str, int, int] | None":
    """(pattern, start, end) of the first prohibition in one item's text (scan form)."""
    for name, rx, where, qualified in _PROHIBITION_RES:
        if where == "oos" and label != "OUT OF SCOPE":
            continue
        for m in rx.finditer(scan):
            if qualified and _PRE_EXISTING_ROWS_RE.search(scan[max(0, m.start() - 40):m.start()]):
                continue
            return name, m.start(), m.end()
    if label == "OUT OF SCOPE":
        found = [m for m in _mentions(scan) if not _mention_qualified(scan, m)]
        if found:
            return _mention_name(found[0]), found[0].start(), found[0].end()
        noun = _OOS_NOUN_RE.search(scan)
        if noun:
            return "any-new-run-launch" if re.search(r"runs?|backtests?", noun.group(0), re.I) \
                else "ledger-row-edit", noun.start(), noun.end()
        return None
    for a, b in _sentences(scan):
        m = _sentence_prohibition(scan[a:b])
        if m:
            return _mention_name(m), a + m.start(), a + m.end()
    return None


def _scan_prohibitions(lines: list[str], fenced: list[bool], comments: list[bool]) -> list[dict]:
    """One finding per ITEM — a bullet, numbered, lettered, checkbox or table
    line, or a TC line, with its wrapped continuation lines (indented, or lazy
    right below it) — reported at the line where the match starts. A child
    bullet under a lead-in that ends with ":" is read together with that
    lead-in ("must not:" / "- launch a new run")."""
    blind = not any(fenced)
    kinds = _line_sections(lines, fenced, [f or c for f, c in zip(fenced, comments)],
                           _glued_headings(lines) if blind else None, ("prose", "metadata"))
    items: list[dict] = []
    current: "dict | None" = None
    tc_label, tc_indent, tc_heading = None, 0, 0
    gap = False                                   # a blank line since the item's last line
    for i, line in enumerate(lines, 1):
        kind = kinds[i - 1]
        stripped = line.strip()
        if fenced[i - 1] or kind in ("heading", "prose", "metadata"):
            if kind == "heading":
                tc_label, tc_heading = None, 0
            current, gap = None, False
            continue
        if not stripped:
            gap = True
            continue
        heading = _ANY_HEADING_LINE_RE.match(line)
        tc = _TC_LINE_RE.match(line)
        deeper = current is not None and _indent_of(line) > current["indent"]
        if tc and kind not in ("OUT OF SCOPE", "DEFINITION OF DONE") and (
                _MARKED_TC_RE.match(line) or _indent_of(line) == 0 or current is None):
            tc_label, tc_indent = re.sub(r"\W", "-", tc.group("tc").upper()), _indent_of(tc.group("indent"))
            tc_heading = len(heading.group("hashes")) if heading else 0
            label = tc_label
            starts = True
        elif tc_label and tc_heading and not (heading and len(heading.group("hashes")) <= tc_heading):
            label = tc_label                      # the body of a `### TC-4` heading (deeper headings included)
            starts = bool(_ITEM_START_RE.match(line)) or current is None or gap
        elif (tc_label and not tc_heading and not heading
              and not line.lstrip().startswith("|")
              and (_indent_of(line) > tc_indent or (not gap and current is not None
                                                    and current["label"] == tc_label
                                                    and not _ITEM_START_RE.match(line)))):
            label = tc_label                      # a TC continued (or sub-bulleted) below its line
            starts = bool(_ITEM_START_RE.match(line)) or (gap and not deeper)
        else:
            tc_label, tc_heading = None, 0
            if kind in ("OUT OF SCOPE", "DEFINITION OF DONE"):
                label = kind
                starts = (bool(_ITEM_START_RE.match(line)) or current is None or current["label"] != label
                          or (gap and not deeper))
            else:
                current, gap = None, False
                continue
        gap = False                               # an indented paragraph after a blank line continues its item
        if starts or current is None or current["label"] != label:
            lead = ""
            if (current is not None and _ITEM_START_RE.match(line) and _indent_of(line) > current["indent"]
                    and current["parts"][-1][2].rstrip().endswith(":")):
                lead = current["lead"] + " ".join(s for _n, _t, s in current["parts"]) + " "   # "must not:" / "- launch …"
            current = {"label": label, "indent": _indent_of(line), "parts": [], "lead": lead}
            items.append(current)
        current["parts"].append((i, stripped, _scan_form(stripped)))
    found: list[dict] = []
    for item in items:
        scan = item["lead"] + " ".join(s for _n, _t, s in item["parts"])
        hit = _item_hit(scan, item["label"])
        if not hit:
            continue
        name, start, end = hit
        start -= len(item["lead"])
        line_no, pos = item["parts"][0][0], 0
        for n, _t, s in item["parts"]:
            if start < pos + len(s) + 1:
                line_no = n
                break
            pos += len(s) + 1
        text = " ".join(t for _n, t, _s in item["parts"])
        found.append({"section": item["label"], "line": line_no, "pattern": name,
                      "match": scan[start + len(item["lead"]):end],
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
    even inside a code fence (agents/goal-decomposer/body.md). Headings inside
    HTML comments start no section in either pass."""
    lines = spec_text.splitlines()
    comments = _html_comment_flags(lines)
    found = {p["line"]: p for p in _scan_prohibitions(lines, fenced_line_flags(lines), comments)}
    for p in _scan_prohibitions(lines, [False] * len(lines), comments):
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
_POLICY_QUOTES = "`*_\"'\u2018\u2019\u201c\u201d"
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
    real_comments = _html_comment_flags(lines)
    if blind:
        fenced = comments = [False] * n
    else:
        fenced, comments = fenced_line_flags(lines), real_comments
    kinds = _line_sections(lines, fenced, [f or c for f, c in zip(fenced, real_comments)],
                           _glued_headings(lines) if blind else None, ("prose",))
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
    uncertain = rec.get("ambiguous") or rec.get("unattributed") or rec.get("orphaned")
    if rec.get("declared") == "mutating" and not uncertain:
        src.append("declared mutating" + (f": '{rec['note']}'" if rec.get("note") else ""))
    elif rec.get("declared") == "mutating" or "mutating" in (rec.get("stated_values") or []):
        src.append(f"a 'Side effects: mutating' line that cannot be tied to it with certainty ({_attribution(rec)}) "
                   "— read as mutating, fail-closed")
    if rec.get("observed_mutating"):
        conflict = ""
        if rec.get("declaration_conflict"):
            conflict = "a block says none (uncertain), but " if uncertain else "declared none, but "
        src.append(conflict + _observation_text(rec))
    hints = rec.get("step_hints") or []
    hint = f"; its step {hints[0]['n']}: '{hints[0]['text']}'" if hints else ""
    return f"{_role_text(roles)} journey {jid} is MUTATING ({'; '.join(src) or 'ledger status mutating'}{hint})"


def _attribution(rec: dict) -> str:
    # An ORPHANED line is reported alongside the reason its journey is unreadable
    # (a fenced header is the root cause; the stray line is what it cost).
    orphan = (" and a 'Side effects:' line in its certified block sits inside no journey definition"
              if rec.get("orphaned") else "")
    if rec.get("attribution_reason") == "orphaned-declaration":
        return "orphaned: a 'Side effects:' line in its certified block sits inside no journey definition"
    if rec.get("ambiguous") and rec.get("attribution_reason") == "fenced-declaration":
        return "ambiguous: a 'Side effects: mutating' line in it sits inside a code fence" + orphan
    if rec.get("ambiguous"):
        return "ambiguous: a header with this id also sits inside a code fence" + orphan
    if rec.get("attribution_reason") == "fenced-header":
        return "unattributed: its only header sits inside a code fence" + orphan
    return "unattributed: it has no definition of its own" + orphan


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
                rule = (" (a TC / DEFINITION OF DONE sentence that names this activity is a prohibition when a "
                        "negation reaches it: 'not', 'never', 'cannot', 'avoid', 'forbid' or 'out of scope' anywhere "
                        "in the sentence, or 'no', 'none', 'nothing' or 'without' before it in its own clause — write "
                        "it positively, put the negation in a sentence of its own, or say 'pre-existing' if the "
                        "negation is about earlier data)"
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
    "activities creating/editing/deleting/writing/appending/adding/inserting/changing/removing ledger rows and "
    "launching/starting/triggering/creating/executing a run: naming one in OUT OF SCOPE is a prohibition; a TC "
    "or DEFINITION OF DONE sentence that names one is a prohibition when it contains not, n't, never, cannot, "
    "avoid, prevent, prohibit, forbid, disallow, exclude(d) or \"out of scope\" ANYWHERE, or when no, none, "
    "nothing, nobody, neither, nor, without, except or excluding stands before the activity in the same clause, "
    "inside its phrase (\"writes nothing to the ledger\") or as its predicate (\"Ledger writes: none\") — "
    "unless the negation is about data called \"pre-existing\" (a refused request may add \"and no run is "
    "created\"). An activity on pre-existing rows only (\"edits to pre-existing ledger rows\") or carved out for a "
    "journey's own step (\"launching runs beyond J-04's own step 1\") is not one, in OUT OF SCOPE too. Write such "
    "sentences positively, or give the negation a sentence of its own. Never copy a rejected "
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
        uncertain = rec.get("ambiguous") or rec.get("unattributed") or rec.get("orphaned")
        if rec.get("declared") == "mutating" or "mutating" in (rec.get("stated_values") or []):
            src.append(("ambiguous declaration" if rec.get("ambiguous")
                        else "unattributed declaration" if rec.get("unattributed")
                        else "orphaned declaration")
                       if uncertain else "declared")
        if rec.get("observed_mutating"):
            conflict = ""
            if rec.get("declaration_conflict"):
                conflict = ("AMBIGUOUS, one block says none, but " if rec.get("ambiguous")
                            else "ORPHANED, an unattached line says none, but " if rec.get("orphaned")
                            else "UNATTRIBUTED, a block says none, but " if uncertain else "DECLARED NONE, but ")
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
# The same when the `none` comes from an AMBIGUOUS, UNATTRIBUTED or ORPHANED id
# (a header with the id sits inside a code fence, no definition covers it, or the
# line itself sits inside none): which block, if any, is the journey is uncertain.
_CONFLICT_AMBIG_EVAL = ("POSSIBLE DECLARATION CONFLICT: a docs/goal.md block for {jids} says 'none', but which block "
                        "(if any) defines the journey is uncertain (a header with the id sits inside what the parser "
                        "reads as a code fence, only other journeys mention it, or the line itself sits inside no "
                        "journey definition) — and the deterministic replay "
                        "observed a mutation: report it in Summary and assumptions.md as a finding to check (a "
                        "product regression or a wrong or misplaced declaration).")
_CONFLICT_AMBIG_LANE = ("POSSIBLE DECLARATION CONFLICT: a docs/goal.md block for {jids} says 'none' (the id's "
                        "definition is uncertain), yet a replay observed a mutation — name the step that changes "
                        "data in {its} row's Actual cell.")
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
    uncertain = {j for j in mut if (recs.get(j) or {}).get("ambiguous") or (recs.get(j) or {}).get("unattributed")
                 or (recs.get(j) or {}).get("orphaned")}
    conflicts = [j for j in mut if (recs.get(j) or {}).get("declaration_conflict") and j not in uncertain]
    ambiguous = [j for j in mut if (recs.get(j) or {}).get("declaration_conflict") and j in uncertain]
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
