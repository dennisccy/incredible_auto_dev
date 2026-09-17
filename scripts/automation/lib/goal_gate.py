"""
goal_gate.py — deterministic goal-mode gate helpers (stdlib only).

The goal loop's quality verdicts historically rested on a single model output.
These helpers give run-goal.sh mechanical cross-checks (via lib/goal-gates.sh)
so a degraded/over-optimistic evaluator cannot mis-certify a session, plus
token-lean digest/slice builders for the judge prompts.

Exit-code philosophy: commands used to certify GOAL_ACHIEVED fail CLOSED
(missing/unparsable input → non-zero); purely informational commands
(digest, goal-slice) fail SAFE (fall back to full content, exit 0).

CLI:
    python3 goal_gate.py journeys <journey-history.json>
        exit 0: every journey status ∈ {passing, already_passing}
        exit 1: blocking journeys exist   exit 2: file missing/unparsable
        stdout: {"total":N,"passing":N,"blocking":["J-xx", ...]}
    python3 goal_gate.py coherence <coherence.md> [--for-achievement]
        exit 0: PASS/WARN   exit 1: FAIL (or, with --for-achievement, a
        crash-stub PASS)    exit 2: file missing/no verdict line
    python3 goal_gate.py results <ui-test-results.md>
        exit 0: no FAIL cells   exit 1: at least one   exit 2: file missing
    python3 goal_gate.py regressions <pre.json> <post.json>
        exit 0: none (or no pre-snapshot to compare)   exit 3: regressions
        stdout: one line per regression "J-xx: <pre> -> <post>"
    python3 goal_gate.py digest <journey-history.json> [--max-chars N]
        stdout: one line per journey (id | status | last_passing | name)
    python3 goal_gate.py goal-slice <goal.md> --history <journey-history.json>
        [--targets J-01,J-02] [--out <path>]
        stdout/out-file: goal.md with stable passing journeys' blocks replaced
        by one-line digests; vision/anti-goals/other prose verbatim.
    python3 goal_gate.py hash-journeys <goal.md> [--history <journey-history.json>]
        [--out-changed <path>]
        stdout: {"J-01": "<sha256>", ...} — stable per-journey spec-text hash
        (line endings and trailing whitespace normalized). With --history the
        output becomes {"hashes": ..., "changed": [...]} where changed lists
        passing/already_passing journeys whose recorded spec_hash no longer
        matches the current text; --out-changed additionally writes (or, when
        nothing changed, removes) a markdown note listing them. A missing
        history file or a journey without spec_hash is UNKNOWN → never listed
        (old sessions must not be demoted).
        exit 0 (informational — changes are reported, not enforced here)
        exit 2: goal.md unreadable
    python3 goal_gate.py side-effects <goal.md> [--sidecar P] [--out P]
        [--journeys J-01,J-02] [--suggest] [--repo-root DIR] [--readonly-endpoints P]
        [--iter N] [--iter-name NAME] [--step preflight|pre-evaluator] [--record-digest]
        HARD-3 journey side-effect ledger. Each journey's status is
        `mutating` if a deterministic replay OBSERVED a mutation (sidecar) or
        the owner declared `- Side effects: mutating — <note>`; `none` if the
        owner declared `none` and nothing was observed; `unknown` otherwise
        (no line, or an invalid one). Carries the declaration_digest (sha256
        over the parsed declarations + the read-only exception file), the
        per-journey declaration_hash and step hints. --record-digest updates
        the engine-owned sidecar's declaration bookkeeping (never a corrupt
        one). With --out the ledger is written atomically and stdout carries
        one `<event>\t<json>` telemetry line per declaration change; without
        it stdout is the ledger JSON. --suggest prints paste-ready lines and
        never edits goal.md.
        exit 0: ledger complete   exit 3: ledger written but INCOMPLETE
        (corrupt sidecar / unreadable exception file — a `Side-effect policy:
        none` spec fails closed on it)   exit 2: goal.md unreadable
    python3 goal_gate.py drift <journeys-changed.md> <journey-history.json>
        The enforcement side of hash-journeys (achievement gate, NEED-9):
        every journey listed in the note must have been re-verified against
        the edited goal text — its recorded spec_hash re-recorded to the
        note's current hash — or demoted out of passing/already_passing.
        exit 0: no note file, or every listed journey re-verified/demoted
        exit 1: a listed journey still counts as passing on the OLD text
        exit 2: note present but unparsable, or history unreadable (a
        certification path — fails CLOSED)
        stdout: one line per unresolved journey
    python3 goal_gate.py self-test
"""
from __future__ import annotations

import datetime
import hashlib
import json
import re
import sys
from pathlib import Path

PASSING_STATUSES = {"passing", "already_passing"}

# A journey entry in goal.md: a list item starting "- **J-NN" (tolerates
# "**J-NN:" / "**J-NN —" / "**J-NN.") at any indent. A block runs until the
# next journey header at the SAME or shallower indent, or a markdown heading,
# or an HTML comment marker (the AUTO:journeys fence).
_JOURNEY_HEADER_RE = re.compile(r"^(\s*)-\s+\*\*(J-\d+)\b", re.MULTILINE)
_STUB_MARKER = "Coherence auditor produced no output"
_VERDICT_RE = re.compile(r"^\*\*Verdict:\*\*\s*(\S+)", re.MULTILINE)
# A table cell that IS a FAIL verdict: the token leads the cell, may be wrapped
# in markdown emphasis/backticks and may carry an annotation (`**FAIL**`,
# `FAIL (step 3 timed out)`) — anti-pattern 28. Prose that merely contains the
# word (`expect no FAILURE here`, `see FAIL below`) never matches, and neither
# does a different word (`FAILURE`, the template placeholder `PASS/FAIL`).
_FAIL_CELL_RE = re.compile(
    r"\|\s*[*_`~]*FAIL[*_`~]*(?:\s*\||[\s(\[:;,\u2014\u2013-][^|]*\|)", re.IGNORECASE)
# SPEED-15 rung 2: a journey deferred for wall-clock budget was NOT verified
# this iteration — it keeps its prior status for scoring, but it must block
# GOAL_ACHIEVED exactly like a FAIL until a later iteration re-verifies it.
_DEFERRED_CELL_RE = re.compile(r"\|\s*DEFERRED-BUDGET\s*\|")


def _load_history(path: str) -> dict | None:
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    journeys = data.get("journeys")
    if not isinstance(journeys, dict):
        return None
    return data


def cmd_journeys(path: str) -> int:
    data = _load_history(path)
    if data is None:
        print(json.dumps({"error": f"unreadable journey history: {path}"}))
        return 2
    journeys = data["journeys"]
    blocking = sorted(
        jid for jid, j in journeys.items()
        if not isinstance(j, dict) or j.get("status") not in PASSING_STATUSES
    )
    print(json.dumps({
        "total": len(journeys),
        "passing": len(journeys) - len(blocking),
        "blocking": blocking,
    }))
    if not journeys:
        # An empty journey set can't certify an achieved goal.
        return 2
    return 1 if blocking else 0


def cmd_coherence(path: str, for_achievement: bool) -> int:
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError:
        return 2
    m = _VERDICT_RE.search(text)
    if not m:
        return 2
    verdict = m.group(1).strip()
    if verdict == "COHERENCE-FAIL":
        return 1
    if for_achievement and _STUB_MARKER in text:
        # A crash-stub PASS may let the loop continue, but never certify done.
        return 1
    if verdict in ("COHERENCE-PASS", "COHERENCE-WARN"):
        return 0
    return 2


def cmd_results(path: str) -> int:
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError:
        return 2
    return 1 if (_FAIL_CELL_RE.search(text) or _DEFERRED_CELL_RE.search(text)) else 0


def cmd_regressions(pre_path: str, post_path: str) -> int:
    pre = _load_history(pre_path)
    post = _load_history(post_path)
    if pre is None:
        # No pre-snapshot (first gated iteration) — nothing to compare.
        return 0
    if post is None:
        print("post journey-history unreadable", file=sys.stderr)
        return 3
    regressions = []
    for jid, pj in pre["journeys"].items():
        if not isinstance(pj, dict) or pj.get("status") not in PASSING_STATUSES:
            continue
        cur = post["journeys"].get(jid)
        cur_status = cur.get("status") if isinstance(cur, dict) else "missing"
        if cur_status not in PASSING_STATUSES:
            regressions.append(f"{jid}: {pj.get('status')} -> {cur_status}")
    for line in sorted(regressions):
        print(line)
    return 3 if regressions else 0


def cmd_digest(path: str, max_chars: int) -> int:
    data = _load_history(path)
    if data is None:
        print("(journey digest unavailable — read the journey-history file directly)")
        return 0
    lines = []
    for jid in sorted(data["journeys"]):
        j = data["journeys"][jid]
        if not isinstance(j, dict):
            j = {}
        lines.append(
            f"{jid} | {j.get('status', '?'):<15s} | last_passing={j.get('last_passing_iter') or '-'} | {j.get('name', '')}"
        )
    out = "\n".join(lines)
    if len(out) > max_chars:
        out = out[:max_chars] + "\n... (digest truncated — read the journey-history file directly)"
    print(out)
    return 0


def _journey_blocks(text: str) -> list[tuple[str, int, int]]:
    """Return (journey_id, start, end) character spans for each journey block."""
    headers = list(_JOURNEY_HEADER_RE.finditer(text))
    blocks: list[tuple[str, int, int]] = []
    for i, m in enumerate(headers):
        start = m.start()
        indent = len(m.group(1))
        end = len(text)
        # End at the next journey header with indent <= this one, or the next
        # markdown heading / HTML comment at column 0.
        tail = text[m.end():]
        for nm in _JOURNEY_HEADER_RE.finditer(text, m.end()):
            if len(nm.group(1)) <= indent:
                end = nm.start()
                break
        boundary = re.search(r"^(#{1,6}\s|<!--)", text[m.end():end], re.MULTILINE)
        if boundary:
            end = m.end() + boundary.start()
        blocks.append((m.group(2), start, end))
    return blocks


def _normalize_block(block: str) -> str:
    """Line endings → \\n, per-line rstrip, trailing blank lines dropped — so
    formatting-only edits to goal.md do not read as spec changes.

    HARD-3 (certification path, owner-approved D.3): every `Side effects:`
    declaration line — valid or not — is DROPPED before hashing, so adding,
    editing or removing a declaration never creates goal-edit drift. It is not
    invisible: the separate declaration_digest (side-effects ledger) changes
    instead, and the engine emits side_effect_declaration_changed. The line set
    is exactly what parse_side_effect_declarations reads (one regex)."""
    lines = block.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    drop = {i for i, _ in _declaration_line_matches(lines)}
    lines = [ln.rstrip() for i, ln in enumerate(lines) if i not in drop]
    while lines and lines[-1] == "":
        lines.pop()
    return "\n".join(lines)


def _journey_hashes(text: str) -> dict[str, str]:
    """sha256 hex of each journey block's normalized text, keyed by J-NN."""
    return {
        jid: hashlib.sha256(_normalize_block(text[start:end]).encode("utf-8")).hexdigest()
        for jid, start, end in _journey_blocks(text)
    }


def cmd_hash_journeys(
    goal_path: str,
    history_path: str | None,
    out_changed: str | None,
) -> int:
    try:
        text = Path(goal_path).read_text(encoding="utf-8")
    except OSError:
        print(f"goal file unreadable: {goal_path}", file=sys.stderr)
        return 2
    hashes = _journey_hashes(text)
    if history_path is None:
        print(json.dumps(hashes, sort_keys=True))
        return 0

    changed: list[dict[str, str]] = []
    data = _load_history(history_path)
    if data is not None:
        for jid in sorted(data["journeys"]):
            j = data["journeys"][jid]
            if not isinstance(j, dict) or j.get("status") not in PASSING_STATUSES:
                continue
            recorded, current = j.get("spec_hash"), hashes.get(jid)
            if not recorded or not current:
                # No recorded hash (pre-NEED-9 session) or journey block gone
                # from goal.md: unknown, never a demotion signal.
                continue
            if recorded != current:
                changed.append({
                    "id": jid,
                    "name": j.get("name", ""),
                    "status": j.get("status", ""),
                    "recorded_hash": recorded,
                    "current_hash": current,
                })
    if out_changed:
        note = Path(out_changed)
        if changed:
            lines = [
                "<!-- Generated by goal_gate.py hash-journeys (goal-edit drift check).",
                "     Each journey below is recorded as passing, but its goal.md spec",
                "     text changed since it was last verified. It must be re-verified",
                "     against the CURRENT text before it may count toward GOAL_ACHIEVED. -->",
                "",
                "# Passing journeys whose goal.md text changed",
                "",
            ]
            lines += [
                f"- {c['id']} ({c['name']}): status {c['status']}, "
                f"spec_hash {c['recorded_hash'][:12]}… → {c['current_hash'][:12]}…"
                for c in changed
            ]
            note.write_text("\n".join(lines) + "\n", encoding="utf-8")
        else:
            note.unlink(missing_ok=True)  # a stale note must not outlive the drift
    print(json.dumps({"hashes": hashes, "changed": changed}, sort_keys=True))
    return 0


# One journey line of the note cmd_hash_journeys writes. Writer and parser
# live in this file on purpose: the self-test round-trips them, so a format
# change cannot silently disable the drift gate (it fails closed instead).
_CHANGED_NOTE_LINE_RE = re.compile(
    r"^-\s+(J-\d+)\s+\(.*\):\s*status\s+\S+,\s*"
    r"spec_hash\s+[0-9a-f]+…\s*→\s*([0-9a-f]+)…\s*$",
    re.MULTILINE,
)


def cmd_drift(note_path: str, history_path: str) -> int:
    note = Path(note_path)
    if not note.exists():
        # No drift note this iteration — nothing to enforce.
        return 0
    try:
        entries = _CHANGED_NOTE_LINE_RE.findall(note.read_text(encoding="utf-8"))
    except OSError:
        print(f"drift note unreadable: {note_path}", file=sys.stderr)
        return 2
    if not entries:
        print(f"drift note has no parsable journey lines: {note_path}", file=sys.stderr)
        return 2
    data = _load_history(history_path)
    if data is None:
        print(f"journey history unreadable: {history_path}", file=sys.stderr)
        return 2
    unresolved: list[str] = []
    for jid, current_prefix in entries:
        j = data["journeys"].get(jid)
        if not isinstance(j, dict):
            unresolved.append(f"{jid}: listed as goal-edited but missing from journey-history")
            continue
        if j.get("status") not in PASSING_STATUSES:
            continue  # demoted — the all-passing journeys check blocks achievement
        if not str(j.get("spec_hash") or "").startswith(current_prefix):
            unresolved.append(
                f"{jid}: still {j.get('status')} but spec_hash was not re-recorded "
                "against the edited goal text (stale pass)"
            )
    for line in sorted(unresolved):
        print(line)
    return 1 if unresolved else 0


def cmd_goal_slice(
    goal_path: str,
    history_path: str,
    targets: set[str],
    out_path: str | None,
) -> int:
    try:
        text = Path(goal_path).read_text(encoding="utf-8")
    except OSError:
        print(f"goal file unreadable: {goal_path}", file=sys.stderr)
        return 2

    def _emit(content: str) -> None:
        if out_path:
            Path(out_path).write_text(content, encoding="utf-8")
        else:
            sys.stdout.write(content)

    data = _load_history(history_path)
    blocks = _journey_blocks(text)
    if data is None or not blocks:
        # Fail-safe: no history (baseline) or unrecognized structure → full file.
        _emit(text)
        return 0

    journeys = data["journeys"]
    keep: set[str] = set(targets)
    for jid, j in journeys.items():
        status = j.get("status") if isinstance(j, dict) else None
        if status not in PASSING_STATUSES:
            keep.add(jid)

    out_parts: list[str] = []
    cursor = 0
    replaced = 0
    for jid, start, end in blocks:
        out_parts.append(text[cursor:start])
        j = journeys.get(jid) if isinstance(journeys.get(jid), dict) else {}
        if jid in keep or jid not in journeys:
            # Unknown-to-history journeys stay verbatim (new/just-added).
            out_parts.append(text[start:end])
        else:
            name = j.get("name", "")
            out_parts.append(
                f"- **{jid}: {name}** — {j.get('status')} (stable; digested)\n"
            )
            replaced += 1
        cursor = end
    out_parts.append(text[cursor:])
    sliced = "".join(out_parts)
    if replaced == 0 or len(sliced) >= len(text):
        _emit(text)
        return 0
    header = (
        "<!-- GOAL SLICE: generated by goal_gate.py. Stable passing journeys are\n"
        f"     digested to one line ({replaced} of {len(blocks)}); vision, anti-goals, and\n"
        f"     target/failing journeys are verbatim. Full text: {goal_path} -->\n"
    )
    _emit(header + sliced)
    return 0


# ── HARD-3: journey side-effect declarations + deterministic ledger ──────────
# Owner-approved schema (plan D.3), one optional line per journey block:
#     - Side effects: none | mutating — <note>
# Absent = `unknown`. Harmless formatting is normalized (case, whitespace,
# **bold**/`code` around the value, `-`/`–`/`—` before the note). Anything else
# is invalid (goal-lint ERROR side-effects-invalid) and reads as `unknown` —
# except that a clearly-stated `mutating` is still honoured when only its
# FORMAT is wrong: a malformed declaration may never make a journey less
# restrictive than its stated value. There is deliberately no `read-only` value:
# a read-only POST endpoint belongs in the digest-tracked exception file.
SIDE_EFFECT_VALUES = ("none", "mutating")
READONLY_ENDPOINTS_REL = "project-extensions/side-effects/read-only-endpoints.txt"
_SE_LINE_RE = re.compile(
    r"^[ \t]*(?:[-*+][ \t]+)?(?:\*\*|__)?(?P<label>side[ \t]*[-_]?[ \t]*effects?)(?:\*\*|__)?"
    r"[ \t]*:(?:\*\*|__)?[ \t]*(?P<rest>.*?)[ \t]*$",
    re.IGNORECASE)
_SE_VALUE_RE = re.compile(r"^[*_`]*(?P<value>[A-Za-z]+)[*_`]*(?P<tail>.*)$", re.S)
_SE_NOTE_RE = re.compile(r"^[ \t]*[-–—]+[ \t]*(?P<note>.*?)[ \t]*$", re.S)
_SE_TRIVIAL_TAIL_RE = re.compile(r"^[ \t]*[.;,]?[ \t]*$")
_SE_RAW_VALUE_SPLIT_RE = re.compile(r"[ \t]+[-–—]|[–—]")
_SE_FENCE_RE = re.compile(r"^[ \t]*(```|~~~)")
_SE_STEP_RE = re.compile(r"^(?P<indent>[ \t]*)(?P<n>\d+)[.)][ \t]+(?P<text>.*)$")
_SE_BULLET_RE = re.compile(r"^[ \t]*[-*+][ \t]")
_SE_CODE_SPAN_RE = re.compile(r"`[^`]*`")
# Words that name a state-changing browser action (plan WP3: create|submit|save|
# delete|run|launch|upload|edit|update|post, with their common inflections).
# Heuristic ONLY: it drives goal-lint's advisory WARN and the step hints printed
# next to a finding — it never decides a status.
_SE_ACTION_WORD_RE = re.compile(
    r"\b(create[sd]?|creating|submit(?:s|ted|ting)?|save[sd]?|saving|delete[sd]?|deleting"
    r"|runs?|launch(?:es|ed|ing)?|upload(?:s|ed|ing)?|edit(?:s|ed|ing)?|update[sd]?|updating"
    r"|posts?|posted|posting)\b",
    re.IGNORECASE)
_JOURNEY_NAME_RE = re.compile(r"^\s*-\s+\*\*(J-\d+)\b[\s:.—–-]*(?P<name>.*?)\s*\*\*", re.MULTILINE)


def _declaration_line_matches(lines: list[str]) -> list[tuple[int, "re.Match[str]"]]:
    """(index, match) for every declaration-shaped line outside a code fence."""
    out = []
    in_fence = False
    for i, ln in enumerate(lines):
        if _SE_FENCE_RE.match(ln):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        m = _SE_LINE_RE.match(ln)
        if m:
            out.append((i, m))
    return out


def _parse_declaration_value(rest: str) -> dict:
    rest = rest.strip()
    if not rest:
        return {"value": None, "raw_value": "", "note": "",
                "error": "no value — write '- Side effects: none' or '- Side effects: mutating — <note>'"}
    raw_value = _SE_RAW_VALUE_SPLIT_RE.split(rest, maxsplit=1)[0].strip().strip("*_`").strip()
    m = _SE_VALUE_RE.match(rest)
    if not m:
        return {"value": None, "raw_value": raw_value, "note": "",
                "error": f"value {raw_value!r} is not 'none' or 'mutating'"}
    value = m.group("value").lower()
    tail = m.group("tail")
    note, sep_error = "", None
    if not _SE_TRIVIAL_TAIL_RE.match(tail):
        nm = _SE_NOTE_RE.match(tail)
        if nm:
            note = " ".join(nm.group("note").split())
        else:
            sep_error = ("the note must follow the value after a dash, e.g. "
                         "'- Side effects: mutating — <what it creates or changes>'")
    if value not in SIDE_EFFECT_VALUES:
        shown = raw_value or value
        return {"value": None, "raw_value": shown, "note": note,
                "error": (f"value {shown!r} is not 'none' or 'mutating' — there is no third value; "
                          f"a read-only POST endpoint belongs in {READONLY_ENDPOINTS_REL}")}
    return {"value": value, "raw_value": value, "note": note, "error": sep_error}


def _parse_declaration_line(idx: int, m: "re.Match[str]") -> dict:
    label = " ".join(m.group("label").lower().split())
    parsed = _parse_declaration_value(m.group("rest"))
    errors = []
    if label != "side effects":
        errors.append(f"the label must be exactly 'Side effects:' (found '{m.group('label').strip()}:')")
    if parsed["error"]:
        errors.append(parsed["error"])
    return {"index": idx, "label_ok": label == "side effects", "value": parsed["value"],
            "raw_value": parsed["raw_value"], "note": parsed["note"], "errors": errors}


def _effective_declaration(found: list[dict], duplicate_block: bool = False) -> dict:
    errors: list[str] = []
    for f in found:
        errors.extend(f["errors"])
    if len(found) > 1:
        errors.append(f"declared {len(found)} times in this journey — keep exactly one 'Side effects:' line")
    if duplicate_block and found:
        errors.append("this journey id is defined more than once in goal.md")
    values = [f["value"] for f in found if f["value"]]
    if not found:
        declared = None
    elif "mutating" in values:
        declared = "mutating"          # the most restrictive stated intent always stands
    elif values and not errors and all(v == "none" for v in values):
        declared = "none"              # a `none` counts only when perfectly well-formed
    else:
        declared = None
    note = next((f["note"] for f in found if f["value"] and f["note"]), "")
    tuples = [["side effects" if f["label_ok"] else "invalid-label",
               f["value"] or ("invalid:" + f["raw_value"].lower()), f["note"]] for f in found]
    dhash = None
    if found:
        dhash = hashlib.sha256(json.dumps({"declared": declared or "unknown", "lines": tuples},
                                          sort_keys=True).encode("utf-8")).hexdigest()
    return {"declared": declared, "valid": not errors, "errors": errors, "note": note,
            "lines": found, "declaration_hash": dhash}


def _block_lines(block: str) -> list[str]:
    return block.replace("\r\n", "\n").replace("\r", "\n").split("\n")


def side_effect_journey_blocks(text: str) -> list[tuple[str, int, int]]:
    """(journey_id, start, end) spans with the header indent measured on the
    header's OWN line.

    `_journey_blocks` (the certified spec_hash path — deliberately untouched)
    measures `len(m.group(1))`, and that leading-whitespace group also swallows
    the blank lines before a header, so a journey preceded by two blank lines is
    not a boundary for one preceded by a single blank line and the earlier block
    runs on into it.
    Declarations must never be attributed to the wrong journey, so side-effect
    parsing uses this corrected splitter. Hash neutrality does not depend on it:
    `_normalize_block` drops every declaration line in whatever block it hashes."""
    headers = list(_JOURNEY_HEADER_RE.finditer(text))

    def _line_start_and_indent(m: "re.Match[str]") -> tuple[int, int]:
        lead = m.group(1)
        own = lead.rsplit("\n", 1)[-1]
        return m.start() + len(lead) - len(own), len(own.expandtabs(4))

    blocks: list[tuple[str, int, int]] = []
    for i, m in enumerate(headers):
        start, indent = _line_start_and_indent(m)
        end = len(text)
        for nm in headers[i + 1:]:
            nstart, nindent = _line_start_and_indent(nm)
            if nindent <= indent:
                end = nstart
                break
        boundary = re.search(r"^(#{1,6}\s|<!--)", text[m.end():end], re.MULTILINE)
        if boundary:
            end = m.end() + boundary.start()
        blocks.append((m.group(2), start, end))
    return blocks


def parse_side_effect_declarations(text: str) -> dict[str, dict]:
    """{journey id: declaration} for every journey block in goal.md text.

    declaration = {declared: 'none'|'mutating'|None, valid, errors, note, lines,
    declaration_hash (None when the journey has no declaration line)}."""
    out: dict[str, dict] = {}
    raw: dict[str, list[dict]] = {}
    dup: set[str] = set()
    for jid, start, end in side_effect_journey_blocks(text):
        lines = _block_lines(text[start:end])
        found = [_parse_declaration_line(i, m) for i, m in _declaration_line_matches(lines)]
        if jid in raw:
            dup.add(jid)
            raw[jid] = raw[jid] + found
        else:
            raw[jid] = found
    for jid, found in raw.items():
        out[jid] = _effective_declaration(found, duplicate_block=jid in dup)
    return out


def _journey_steps(block: str) -> list[dict]:
    """Numbered steps of a journey block with their continuation lines:
    [{n, line (index in the block), text}]."""
    steps: list[dict] = []
    cur = None
    in_fence = False
    for i, raw in enumerate(_block_lines(block)):
        if _SE_FENCE_RE.match(raw):
            in_fence = not in_fence
            cur = None
            continue
        if in_fence:
            continue
        m = _SE_STEP_RE.match(raw)
        if m:
            cur = {"n": int(m.group("n")), "line": i, "indent": len(m.group("indent").expandtabs(4)),
                   "parts": [m.group("text").strip()]}
            steps.append(cur)
            continue
        if cur is None:
            continue
        if not raw.strip():
            cur = None
            continue
        expanded = raw.expandtabs(4)
        indent = len(expanded) - len(expanded.lstrip())
        if indent > cur["indent"] and not _SE_LINE_RE.match(raw) and not _SE_BULLET_RE.match(raw):
            cur["parts"].append(raw.strip())
        else:
            cur = None
    return [{"n": s["n"], "line": s["line"], "text": " ".join(" ".join(s["parts"]).split())} for s in steps]


def journey_step_hints(block: str, cap: int = 3) -> list[dict]:
    """Numbered steps that name a state-changing action: [{n, line, text, words}].
    `text` is the step's matching clauses (split on ';'), code spans ignored."""
    hints: list[dict] = []
    for step in _journey_steps(block):
        plain = _SE_CODE_SPAN_RE.sub(" ", step["text"])
        words = sorted({w.lower() for w in _SE_ACTION_WORD_RE.findall(plain)})
        if not words:
            continue
        clauses = [c.strip() for c in step["text"].split(";") if c.strip()]
        hit = [c for c in clauses if _SE_ACTION_WORD_RE.search(_SE_CODE_SPAN_RE.sub(" ", c))]
        excerpt = "; ".join(hit) if hit else step["text"]
        if len(excerpt) > 200:
            excerpt = excerpt[:199].rstrip() + "…"
        hints.append({"n": step["n"], "line": step["line"], "text": excerpt, "words": words})
        if len(hints) >= cap:
            break
    return hints


def _readonly_token(ro: dict):
    """The exception file's contribution to the declaration digest."""
    if ro.get("error"):
        return "unreadable"
    return ro.get("sha256")


def declaration_digest(decls: dict[str, dict], ro: dict) -> str:
    items = [[jid, d["declared"] or "unknown", d["note"], d["declaration_hash"]]
             for jid, d in sorted(decls.items()) if d["declaration_hash"]]
    payload = {"schema": "journey-side-effect-declarations/1", "journeys": items,
               "read_only_endpoints_sha256": _readonly_token(ro)}
    return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def _load_side_effect_sidecar(path) -> tuple["dict | None", "str | None"]:
    """(data, error). An absent sidecar is (None, None): no observations yet."""
    if not path:
        return None, None
    p = Path(path)
    try:
        raw = p.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None, None
    except OSError as exc:
        return None, f"side-effect sidecar {path} is unreadable ({exc.strerror or exc})"
    try:
        data = json.loads(raw)
    except ValueError as exc:
        return None, f"side-effect sidecar {path} is not valid JSON ({exc})"
    if not isinstance(data, dict) or not isinstance(data.get("journeys", {}), dict):
        return None, f"side-effect sidecar {path} has the wrong shape (no 'journeys' object)"
    return data, None


def _journey_observation(rec, ro: dict, ignore: list[str], classify) -> dict:
    """Observed-mutation facts for one journey from its sidecar record.

    The status-driving record is `latest`. When the exception file or the auth
    list changed since it was recorded, its stored {method, path} sample is
    re-classified with the CURRENT rules; a truncated sample cannot be, so it
    stays mutating if it held any candidate request (fail closed)."""
    base = {"observed_mutating": False, "observed_iter": None, "observed_iter_name": None,
            "observation_complete": None, "observation_basis": None, "observed_at": None,
            "requests": [], "exceptions_applied": [], "error": None}
    if rec is None:
        return base
    if not isinstance(rec, dict):
        return {**base, "error": "record is not an object"}
    latest = rec.get("latest")
    if latest is None:
        return base
    if not isinstance(latest, dict):
        return {**base, "error": "'latest' is not an object"}
    try:
        mut = int(latest.get("mutating_count") or 0)
        auth = int(latest.get("auth_count") or 0)
        roc = int(latest.get("readonly_count") or 0)
    except (TypeError, ValueError):
        return {**base, "error": "observation counts are not integers"}
    reqs = latest.get("requests") or []
    if not isinstance(reqs, list) or any(not isinstance(r, dict) for r in reqs):
        return {**base, "error": "observation requests are not a list of objects"}
    stale = (latest.get("readonly_endpoints_sha256") != ro.get("sha256")
             or bool(latest.get("readonly_endpoints_error")) != bool(ro.get("error"))
             or list(latest.get("ignore_paths") or []) != list(ignore))
    if not stale:
        observed, basis = mut > 0, "recorded"
        shown = [dict(r) for r in reqs]
        exceptions = [dict(e) for e in (latest.get("exceptions_applied") or []) if isinstance(e, dict)]
    elif latest.get("truncated"):
        observed, basis = (mut + auth + roc) > 0, "reclassification-unverifiable"
        shown = [dict(r) for r in reqs]
        exceptions = []
    else:
        entries = [] if ro.get("error") else (ro.get("entries") or [])
        shown = []
        for r in reqs:
            r2 = dict(r)
            r2["class"] = classify(str(r.get("method") or ""), str(r.get("path") or "/"), ignore, entries)
            shown.append(r2)
        observed = any(r["class"] == "mutating" for r in shown) or (mut > 0 and not reqs)
        basis = "reclassified"
        exceptions = [{"method": r.get("method"), "path": r.get("path")} for r in shown
                      if r["class"] == "ignored-readonly"]
    return {**base, "observed_mutating": bool(observed), "observed_iter": latest.get("iter"),
            "observed_iter_name": latest.get("iter_name"), "observation_complete": latest.get("complete"),
            "observation_basis": basis, "observed_at": latest.get("observed_at"),
            "requests": shown, "exceptions_applied": exceptions}


def build_side_effect_ledger(goal_text: str, sidecar=None, readonly_path=None, *, iter_n=None,
                             iter_name=None, step=None, goal_file=None, env=None) -> dict:
    """The deterministic per-iteration side-effect ledger (a pure read)."""
    from demo_runner import classify_candidate, load_readonly_endpoints, side_effect_ignore_paths  # noqa: PLC0415
    errors: list[str] = []
    decls = parse_side_effect_declarations(goal_text)
    blocks: dict[str, str] = {}
    for jid, start, end in side_effect_journey_blocks(goal_text):
        blocks.setdefault(jid, goal_text[start:end])
    names = {m.group(1): m.group("name").strip() for m in _JOURNEY_NAME_RE.finditer(goal_text)}
    ro = load_readonly_endpoints(readonly_path)
    if ro["error"]:
        errors.append(f"read-only exception file {ro['path']} is {ro['error']} — exceptions cannot be "
                      "applied and recorded observations cannot be re-checked")
    ignore = list(side_effect_ignore_paths(env))
    side, side_err = _load_side_effect_sidecar(sidecar)
    if side_err:
        errors.append(side_err + " — observed mutations are unknown this iteration")
    records = (side or {}).get("journeys") or {}
    journeys: dict[str, dict] = {}
    for jid, block in blocks.items():
        d = decls[jid]
        o = _journey_observation(records.get(jid), ro, ignore, classify_candidate)
        if o["error"]:
            errors.append(f"side-effect sidecar record for {jid} is unusable ({o['error']})")
        observed = o["observed_mutating"]
        if observed or d["declared"] == "mutating":
            status = "mutating"
        elif d["declared"] == "none":
            status = "none"
        else:
            status = "unknown"
        if observed and d["declared"] == "mutating":
            source = "declared+observed"
        elif observed:
            source = "observed"
        elif d["declared"]:
            source = "declared"
        elif d["lines"]:
            source = "invalid-declaration"
        else:
            source = "undeclared"
        journeys[jid] = {
            "name": names.get(jid, ""),
            "declared": d["declared"],
            "declaration_valid": d["valid"],
            "declaration_errors": d["errors"],
            "declaration_hash": d["declaration_hash"],
            "note": d["note"],
            "observed_mutating": observed,
            "observed_iter": o["observed_iter"],
            "observed_iter_name": o["observed_iter_name"],
            "observation_complete": o["observation_complete"],
            "observation_basis": o["observation_basis"],
            "observed_at": o["observed_at"],
            "requests": o["requests"],
            "exceptions_applied": o["exceptions_applied"],
            "status": status,
            "status_source": source,
            "step_hints": [{k: h[k] for k in ("n", "text", "words")} for h in journey_step_hints(block)],
        }
    summary = {s: [j for j, r in journeys.items() if r["status"] == s] for s in ("mutating", "none", "unknown")}
    return {
        "schema_version": 1,
        "built_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "built_at_step": step,
        "iter": iter_n,
        "iter_name": iter_name,
        "goal_file": goal_file,
        "sidecar": str(sidecar) if sidecar else None,
        "complete": not errors,
        "errors": errors,
        "declaration_digest": declaration_digest(decls, ro),
        "recorded_declaration_digest": (side or {}).get("declaration_digest"),
        "declaration_digest_prev": (side or {}).get("declaration_digest_prev"),
        "declaration_digest_changed_iter": (side or {}).get("declaration_digest_changed_iter"),
        "readonly_endpoints": {k: ro[k] for k in ("path", "present", "sha256", "entries", "invalid", "error")},
        "ignore_paths": ignore,
        "ignore_paths_default": tuple(ignore) == tuple(side_effect_ignore_paths({})),
        "journeys": journeys,
        "summary": summary,
        "declaration_errors": [{"journey": j, "errors": r["declaration_errors"]}
                               for j, r in journeys.items() if not r["declaration_valid"]],
    }


def record_side_effect_declarations(sidecar_path, ledger: dict, iter_n, iter_name) -> tuple[list, "str | None"]:
    """Engine bookkeeping: record the current declarations + digest in the
    sidecar (read-modify-write under the same directory lock the observer uses)
    and return the telemetry events for what changed since the last record. A
    corrupt sidecar is never overwritten."""
    from demo_runner import _atomic_write_json, _locked_dir  # noqa: PLC0415
    events: list = []
    p = Path(sidecar_path)
    cur_decls = {jid: {"declared": j["declared"], "declaration_hash": j["declaration_hash"], "note": j["note"]}
                 for jid, j in ledger["journeys"].items() if j["declaration_hash"]}
    ro_token = _readonly_token(ledger["readonly_endpoints"])
    digest = ledger["declaration_digest"]
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        with _locked_dir(p.parent):
            current: dict = {}
            if p.exists():
                try:
                    current = json.loads(p.read_text(encoding="utf-8"))
                except (OSError, ValueError) as exc:
                    return events, f"{p} is unreadable or corrupt ({exc}) — declarations not recorded, file not overwritten"
                if not isinstance(current, dict):
                    return events, f"{p} has the wrong shape — declarations not recorded, file not overwritten"
            prev = current.get("declarations")
            if isinstance(prev, dict):
                for jid in sorted(set(prev) | set(cur_decls)):
                    old = prev.get(jid) if isinstance(prev.get(jid), dict) else {}
                    new = cur_decls.get(jid) or {}
                    if old.get("declaration_hash") != new.get("declaration_hash"):
                        events.append(("side_effect_declaration_changed", {
                            "journey": jid, "from": old.get("declared") or "unknown",
                            "to": new.get("declared") or "unknown", "iter": iter_n, "iter_name": iter_name,
                            "note_changed": (old.get("note") or "") != (new.get("note") or ""),
                            "declaration_digest": digest[:12]}))
                if "ignore_paths" in current and list(current.get("ignore_paths") or []) != list(ledger["ignore_paths"]):
                    # CHAIN_SIDE_EFFECT_IGNORE_PATHS can suppress observations, so a
                    # change to the list in force is provenance like the exception file.
                    events.append(("side_effect_declaration_changed", {
                        "journey": None, "source": "auth-ignore-paths",
                        "from": list(current.get("ignore_paths") or []), "to": list(ledger["ignore_paths"]),
                        "iter": iter_n, "iter_name": iter_name, "declaration_digest": digest[:12]}))
                if "readonly_endpoints_sha256" in current and current.get("readonly_endpoints_sha256") != ro_token:
                    events.append(("side_effect_declaration_changed", {
                        "journey": None, "source": "read-only-endpoints",
                        "from": (current.get("readonly_endpoints_sha256") or "absent")[:12],
                        "to": (ro_token or "absent")[:12], "iter": iter_n, "iter_name": iter_name,
                        "declaration_digest": digest[:12]}))
            if current.get("declaration_digest") != digest:
                current["declaration_digest_prev"] = current.get("declaration_digest")
                current["declaration_digest_changed_iter"] = iter_n
                current["declaration_digest"] = digest
            current["declarations"] = cur_decls
            current["readonly_endpoints_sha256"] = ro_token
            current["ignore_paths"] = list(ledger["ignore_paths"])
            current["declarations_recorded_iter"] = iter_n
            current.setdefault("schema_version", 1)
            current.setdefault("journeys", {})
            _atomic_write_json(p, current)
    except (OSError, TimeoutError) as exc:
        return events, f"declarations not recorded ({exc})"
    return events, None


def render_side_effect_suggestions(ledger: dict, goal_path: str) -> str:
    """Paste-ready declaration lines. Report-only: the framework never edits goal.md."""
    out = [
        "# Side-effect declarations - paste-ready suggestions (goal_gate.py side-effects --suggest)",
        f"# Source: {goal_path}. The framework never edits this file: review each suggestion and paste",
        "# it into the journey's block yourself, one line per journey (for example below its Acceptance line).",
        "# Values: none | mutating — <note>. A missing line means 'unknown'. There is no 'read-only' value:",
        f"# list a read-only POST endpoint in {READONLY_ENDPOINTS_REL} ('POST /api/path') and declare 'none'.",
        "",
    ]
    n = 0
    for jid, j in ledger["journeys"].items():
        head = f"{jid} ({j['name']})" if j.get("name") else jid
        mut_reqs = [f"{r.get('method')} {r.get('path')}" for r in j["requests"] if r.get("class") == "mutating"]
        when = (f"iter-{j['observed_iter']}" if j.get("observed_iter") is not None
                else (j.get("observed_iter_name") or "an earlier iteration"))
        hint = j["step_hints"][0] if j["step_hints"] else None
        if j["declared"] == "none" and j["observed_mutating"]:
            sample = mut_reqs[0] if mut_reqs else "a mutating request"
            out += [f"{head}: declared none, but the replay OBSERVED {sample} in {when} — the observation wins.",
                    f"  suggest:  - Side effects: mutating — <what {sample} creates or changes>",
                    f"  or, only if that endpoint computes without persisting: add '{sample}' to "
                    f"{READONLY_ENDPOINTS_REL} and keep 'none'", ""]
        elif j["declaration_valid"] and j["declared"]:
            continue
        else:
            if not j["declaration_valid"]:
                out.append(f"{head}: INVALID declaration ({'; '.join(j['declaration_errors'])}) — read as "
                           f"{j['declared'] or 'unknown'}.")
            else:
                out.append(f"{head}: no 'Side effects:' line (status unknown).")
            if j["observed_mutating"]:
                out.append(f"  evidence: the replay observed {mut_reqs[0] if mut_reqs else 'a mutation'} in {when}")
            if hint:
                out.append(f"  evidence: step {hint['n']} mentions {', '.join(hint['words'])}: '{hint['text']}'")
            if j["observed_mutating"] or hint or j["declared"] == "mutating":
                what = f"what step {hint['n']} creates or changes" if hint else "what it creates or changes"
                out.append(f"  suggest:  - Side effects: mutating — <{what}>")
            else:
                out.append("  suggest:  - Side effects: none — <why this journey only reads>")
            out.append("")
        n += 1
    if n == 0:
        out.append("# Every journey already carries a valid declaration consistent with the observations.")
    return "\n".join(out).rstrip() + "\n"


def cmd_side_effects(goal_path: str, opts: dict) -> int:
    try:
        text = Path(goal_path).read_text(encoding="utf-8")
    except OSError as exc:
        print(f"[side-effects] goal file unreadable: {goal_path}: {exc}", file=sys.stderr)
        return 2
    readonly = opts.get("--readonly-endpoints")
    if readonly is None:
        root = Path(opts["--repo-root"]) if opts.get("--repo-root") else Path(goal_path).resolve().parent.parent
        readonly = str(root / READONLY_ENDPOINTS_REL)
    iter_n = None
    if opts.get("--iter") not in (None, ""):
        try:
            iter_n = int(opts["--iter"])
        except ValueError:
            print(f"[side-effects] --iter must be an integer (got {opts['--iter']!r})", file=sys.stderr)
            return 2
    sidecar = opts.get("--sidecar")
    ledger = build_side_effect_ledger(text, sidecar=sidecar, readonly_path=readonly, iter_n=iter_n,
                                      iter_name=opts.get("--iter-name"), step=opts.get("--step"),
                                      goal_file=goal_path)
    events: list = []
    if opts.get("--record-digest") and sidecar:
        if ledger["complete"]:
            events, rec_err = record_side_effect_declarations(sidecar, ledger, iter_n, opts.get("--iter-name"))
            if rec_err:
                ledger["record_error"] = rec_err
                print(f"[side-effects] {rec_err}", file=sys.stderr)
            else:
                side, _ = _load_side_effect_sidecar(sidecar)
                side = side or {}
                ledger["recorded_declaration_digest"] = side.get("declaration_digest")
                ledger["declaration_digest_prev"] = side.get("declaration_digest_prev")
                ledger["declaration_digest_changed_iter"] = side.get("declaration_digest_changed_iter")
        else:
            ledger["record_error"] = "declarations not recorded: the ledger is incomplete"
    if opts.get("--suggest"):
        sys.stdout.write(render_side_effect_suggestions(ledger, goal_path))
        return 0
    wanted = [j for j in re.findall(r"J-\d+", opts.get("--journeys") or "")]
    if wanted:
        ledger["journeys"] = {j: r for j, r in ledger["journeys"].items() if j in wanted}
        ledger["summary"] = {s: [j for j in lst if j in wanted] for s, lst in ledger["summary"].items()}
    ledger["declaration_digest_changed_this_iter"] = bool(
        iter_n is not None and ledger.get("declaration_digest_changed_iter") == iter_n
        and ledger.get("declaration_digest_prev"))
    for e in ledger["errors"]:
        print(f"[side-effects] INCOMPLETE: {e}", file=sys.stderr)
    out = opts.get("--out")
    if out:
        from demo_runner import _atomic_write_json  # noqa: PLC0415
        try:
            Path(out).parent.mkdir(parents=True, exist_ok=True)
            _atomic_write_json(out, ledger)
        except OSError as exc:
            print(f"[side-effects] could not write {out}: {exc}", file=sys.stderr)
            return 2
        for name, payload in events:
            print(f"{name}\t{json.dumps(payload, sort_keys=True)}")
    else:
        print(json.dumps(ledger, sort_keys=True, indent=1))
    return 0 if ledger["complete"] else 3


# ── self-test ─────────────────────────────────────────────────────────────────

def _self_test() -> int:
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)

        hist_pass = d / "hist-pass.json"
        hist_pass.write_text(json.dumps({"journeys": {
            "J-01": {"status": "passing", "name": "Login", "last_passing_iter": "i-3"},
            "J-02": {"status": "already_passing", "name": "Browse", "last_passing_iter": "i-0"},
        }}), encoding="utf-8")
        hist_fail = d / "hist-fail.json"
        hist_fail.write_text(json.dumps({"journeys": {
            "J-01": {"status": "passing", "name": "Login"},
            "J-02": {"status": "failing", "name": "Browse"},
            "J-03": {"status": "unknown", "name": "Export"},
        }}), encoding="utf-8")

        assert cmd_journeys(str(hist_pass)) == 0
        assert cmd_journeys(str(hist_fail)) == 1
        assert cmd_journeys(str(d / "missing.json")) == 2
        empty = d / "empty.json"
        empty.write_text('{"journeys": {}}', encoding="utf-8")
        assert cmd_journeys(str(empty)) == 2, "empty journey set must not certify"

        coh_pass = d / "c1.md"; coh_pass.write_text("**Verdict:** COHERENCE-PASS\nok\n", encoding="utf-8")
        coh_warn = d / "c2.md"; coh_warn.write_text("**Verdict:** COHERENCE-WARN\n", encoding="utf-8")
        coh_fail = d / "c3.md"; coh_fail.write_text("**Verdict:** COHERENCE-FAIL\n", encoding="utf-8")
        coh_stub = d / "c4.md"; coh_stub.write_text(
            "**Verdict:** COHERENCE-PASS\n\n(Coherence auditor produced no output; treated as a non-blocking pass.)\n",
            encoding="utf-8")
        assert cmd_coherence(str(coh_pass), False) == 0
        assert cmd_coherence(str(coh_warn), True) == 0
        assert cmd_coherence(str(coh_fail), False) == 1
        assert cmd_coherence(str(coh_stub), False) == 0, "stub PASS may gate CONTINUE"
        assert cmd_coherence(str(coh_stub), True) == 1, "stub PASS must not certify done"
        # SPEED-14: the zero-change deterministic PASS is a reasoned verdict
        # (empty product diff ⇒ no drift possible), NOT a crash stub — it stays
        # valid for GOAL_ACHIEVED certification.
        coh_zero = d / "c5.md"; coh_zero.write_text(
            "**Verdict:** COHERENCE-PASS\n\n(Zero-change iteration: the product diff since the "
            "iteration snapshot is empty — nothing to audit. Deterministic pass without dispatch; "
            "set CHAIN_ZERO_CHANGE_SKIPS=false to always dispatch.)\n",
            encoding="utf-8")
        assert cmd_coherence(str(coh_zero), False) == 0, "zero-change PASS gates CONTINUE"
        assert cmd_coherence(str(coh_zero), True) == 0, "zero-change PASS stays valid for certification (SPEED-14)"
        assert cmd_coherence(str(d / "nope.md"), True) == 2

        res_ok = d / "r1.md"; res_ok.write_text("| T1 | n | ui | P1 | e | a | PASS | x.png |\n", encoding="utf-8")
        res_bad = d / "r2.md"; res_bad.write_text(
            "| T1 | n | ui | P1 | e | a | PASS | x.png |\n| T2 | n | ui | P1 | e | a | FAIL | y.png |\n",
            encoding="utf-8")
        res_prose = d / "r3.md"; res_prose.write_text("| T1 | expect no FAILURE here | PASS |\n", encoding="utf-8")
        assert cmd_results(str(res_ok)) == 0
        assert cmd_results(str(res_bad)) == 1
        assert cmd_results(str(res_prose)) == 0, "FAIL must match a whole cell only"
        # SPEED-15 rung 2: a DEFERRED-BUDGET row blocks achievement like a FAIL
        # (the journey was not verified this iteration), even with every other
        # row PASS.
        res_def = d / "r4.md"; res_def.write_text(
            "| T1 | n | ui | P1 | e | a | PASS | x.png |\n"
            "| UT-J-06 | J-06 regression re-check | regression | P2 | e | not run | DEFERRED-BUDGET | deferred: over iteration wall-clock budget |\n",
            encoding="utf-8")
        assert cmd_results(str(res_def)) == 1, "DEFERRED-BUDGET must block GOAL_ACHIEVED"
        # anti-pattern 28: agents write **FAIL** / FAIL (annotation) — a styled
        # FAIL cell must still block; sentence-shaped prose never matches.
        res_bold = d / "r5.md"; res_bold.write_text(
            "| T1 | n | ui | P1 | e | a | PASS | x.png |\n| T2 | n | ui | P1 | e | a | **FAIL** | y.png |\n",
            encoding="utf-8")
        assert cmd_results(str(res_bold)) == 1, "a bold **FAIL** cell must block GOAL_ACHIEVED"
        res_annot = d / "r6.md"; res_annot.write_text(
            "| T2 | n | ui | P1 | e | a | FAIL (step 3 timed out) | y.png |\n", encoding="utf-8")
        assert cmd_results(str(res_annot)) == 1, "an annotated FAIL cell must block GOAL_ACHIEVED"
        res_prose2 = d / "r7.md"; res_prose2.write_text(
            "| T1 | see FAIL below | PASS |\n| T2 | n | ui | P1 | e | a | `PASS` | x.png |\n"
            "| T3 | n | ui | P1 | e | a | PASS/FAIL | x.png |\n",
            encoding="utf-8")
        assert cmd_results(str(res_prose2)) == 0, "prose containing FAIL / the PASS/FAIL placeholder is not a FAIL cell"

        # regressions: J-01 passing→failing is caught; missing pre → 0
        post = d / "post.json"
        post.write_text(json.dumps({"journeys": {
            "J-01": {"status": "failing"}, "J-02": {"status": "already_passing"},
        }}), encoding="utf-8")
        assert cmd_regressions(str(hist_pass), str(post)) == 3
        assert cmd_regressions(str(hist_pass), str(hist_pass)) == 0
        assert cmd_regressions(str(d / "no-pre.json"), str(post)) == 0

        assert cmd_digest(str(hist_fail), 4000) == 0
        assert cmd_digest(str(d / "missing.json"), 4000) == 0  # fail-safe

        # goal-slice: stable J-01 digested, failing J-02 + target J-03 verbatim,
        # anti-goals verbatim; missing history → full file.
        goal = d / "goal.md"
        goal.write_text(
            "# Goal\n\nVision text.\n\n## Anti-goals\n\n- no paid SaaS\n\n"
            "## Must-have user journeys\n\n"
            "- **J-01: Login** \n  - Steps: open the login page, type credentials, submit the form\n"
            "  - Acceptance: dashboard shows the signed-in user's watchlist header\n"
            "- **J-02: Browse** \n  - Steps: scroll\n  - Acceptance: list renders\n"
            "- **J-03: Export** \n  - Steps: click export\n  - Acceptance: csv downloads\n\n"
            "## Notes\n\ntail prose\n",
            encoding="utf-8")
        out = d / "slice.md"
        assert cmd_goal_slice(str(goal), str(hist_fail), {"J-03"}, str(out)) == 0
        sliced = out.read_text(encoding="utf-8")
        assert "no paid SaaS" in sliced, "anti-goals must stay verbatim"
        assert "type credentials" not in sliced, "stable passing journey must be digested"
        assert "J-01: Login" in sliced, "digest line must still name the journey"
        assert "scroll" in sliced, "failing journey must stay verbatim"
        assert "click export" in sliced, "target journey must stay verbatim"
        assert "tail prose" in sliced, "post-section prose must survive"
        assert cmd_goal_slice(str(goal), str(d / "missing.json"), set(), str(out)) == 0
        assert out.read_text(encoding="utf-8") == goal.read_text(encoding="utf-8"), \
            "no history → full file fallback"

        # hash-journeys: stable sha256 per J-NN block; --history/--out-changed
        # flags passing journeys whose spec text changed since the recorded
        # spec_hash. Missing history file / missing spec_hash = unknown → never
        # flagged (NEED-9 tolerance: no demotion on absence).
        goal_text = goal.read_text(encoding="utf-8")
        h1 = _journey_hashes(goal_text)
        assert set(h1) == {"J-01", "J-02", "J-03"}
        assert all(re.fullmatch(r"[0-9a-f]{64}", v) for v in h1.values())
        assert _journey_hashes(goal_text.replace("\n", " \n")) == h1, \
            "hash must ignore trailing whitespace"
        assert _journey_hashes(goal_text.replace("\n", "\r\n")) == h1, \
            "hash must ignore line-ending style"
        edited = _journey_hashes(goal_text.replace("csv downloads", "pdf downloads"))
        assert edited["J-03"] != h1["J-03"], "hash must change when spec text changes"
        assert edited["J-01"] == h1["J-01"], "other journeys' hashes must not change"

        assert cmd_hash_journeys(str(goal), None, None) == 0
        assert cmd_hash_journeys(str(d / "nope.md"), None, None) == 2
        note = d / "journeys-changed.md"
        hist_hash = d / "hist-hash.json"
        hist_hash.write_text(json.dumps({"journeys": {
            "J-01": {"status": "passing", "name": "Login", "spec_hash": "0" * 64},
            "J-02": {"status": "failing", "name": "Browse", "spec_hash": "0" * 64},
            "J-03": {"status": "already_passing", "name": "Export"},
        }}), encoding="utf-8")
        assert cmd_hash_journeys(str(goal), str(hist_hash), str(note)) == 0
        note_text = note.read_text(encoding="utf-8")
        assert "J-01" in note_text, "stale passing journey must be flagged"
        assert "J-02" not in note_text, "non-passing journey must not be flagged"
        assert "J-03" not in note_text, "missing spec_hash = unknown, no demotion"
        hist_ok = d / "hist-ok.json"
        hist_ok.write_text(json.dumps({"journeys": {
            jid: {"status": "passing", "name": "x", "spec_hash": h}
            for jid, h in h1.items()
        }}), encoding="utf-8")
        assert cmd_hash_journeys(str(goal), str(hist_ok), str(note)) == 0
        assert not note.exists(), "no changes → stale note must be removed"
        assert cmd_hash_journeys(str(goal), str(d / "missing.json"), str(note)) == 0
        assert not note.exists(), "missing history = unknown → no note"

        # drift: the achievement-gate side of NEED-9. Parses the note that
        # cmd_hash_journeys itself wrote (writer↔parser round-trip lives in
        # this one file) and fails unless every listed journey was re-verified
        # against the edited text (spec_hash re-recorded) or demoted out of
        # passing. Certification path → fail closed on anything unreadable.
        assert cmd_drift(str(d / "no-note.md"), str(hist_hash)) == 0, \
            "no note → nothing to enforce"
        assert cmd_hash_journeys(str(goal), str(hist_hash), str(note)) == 0
        assert note.exists(), "fixture: stale J-01 must be flagged again"
        assert cmd_drift(str(note), str(hist_hash)) == 1, \
            "listed journey still passing on the old hash → unresolved"
        hist_reverified = d / "hist-reverified.json"
        hist_reverified.write_text(json.dumps({"journeys": {
            "J-01": {"status": "passing", "name": "Login", "spec_hash": h1["J-01"]},
            "J-02": {"status": "failing", "name": "Browse", "spec_hash": "0" * 64},
            "J-03": {"status": "already_passing", "name": "Export"},
        }}), encoding="utf-8")
        assert cmd_drift(str(note), str(hist_reverified)) == 0, \
            "spec_hash re-recorded against the new text = re-verified"
        hist_demoted = d / "hist-demoted.json"
        hist_demoted.write_text(json.dumps({"journeys": {
            "J-01": {"status": "unknown", "name": "Login", "spec_hash": "0" * 64},
        }}), encoding="utf-8")
        assert cmd_drift(str(note), str(hist_demoted)) == 0, \
            "demoted out of passing = resolved (the all-passing gate blocks it)"
        hist_gone = d / "hist-gone.json"
        hist_gone.write_text('{"journeys": {}}', encoding="utf-8")
        assert cmd_drift(str(note), str(hist_gone)) == 1, \
            "listed journey missing from history → fail closed"
        assert cmd_drift(str(note), str(d / "missing.json")) == 2, \
            "note present but history unreadable → fail closed"
        garbage = d / "garbage-note.md"
        garbage.write_text(
            "# Passing journeys whose goal.md text changed\n\nprose only\n",
            encoding="utf-8")
        assert cmd_drift(str(garbage), str(hist_hash)) == 2, \
            "note with no parsable journey lines → fail closed (format drift)"
        assert cmd_journeys(str(hist_ok)) == 0, \
            "histories carrying spec_hash must parse everywhere"

        # HARD-3: side-effect declarations — parse, hash neutrality, digest.
        se_goal = (
            "# Goal\n\n## Must-have user journeys\n\n"
            "- **J-01: Read**\n  - Steps:\n    1. Visit `/`\n  - Acceptance: rows render\n"
            "  - Side effects: none — reads only\n"
            "- **J-02: Launch**\n  - Steps:\n    1. Open Runs; click Run\n  - Acceptance: a run row appears\n"
            "  - **Side effects:** mutating — launches a run\n"
            "- **J-03: Odd**\n  - Steps:\n    1. Visit `/x`\n  - Acceptance: y\n  - Side effects: read-only\n"
            "- **J-04: Plain**\n  - Steps:\n    1. Visit `/y`\n  - Acceptance: z\n\n## Anti-goals\n\n- none paid\n")
        dd = parse_side_effect_declarations(se_goal)
        assert dd["J-01"]["declared"] == "none" and dd["J-02"]["declared"] == "mutating"
        assert dd["J-04"]["declared"] is None and dd["J-04"]["valid"], "absent = unknown, not an error"
        assert dd["J-03"]["declared"] is None and not dd["J-03"]["valid"], "read-only is invalid -> unknown"
        undeclared = re.sub(r"(?m)^  - (\*\*)?Side effects:.*\n", "", se_goal)
        assert _journey_hashes(se_goal) == _journey_hashes(undeclared), \
            "a Side effects line must never change a journey spec_hash"
        ro_path = d / "ro.txt"
        ro_path.write_text("POST /api/eval\n", encoding="utf-8")
        from demo_runner import load_readonly_endpoints  # noqa: PLC0415
        ro_a = load_readonly_endpoints(ro_path)
        flipped = se_goal.replace("mutating — launches a run", "none — launches a run")
        assert _journey_hashes(flipped) == _journey_hashes(se_goal)
        assert declaration_digest(parse_side_effect_declarations(flipped), ro_a) != \
            declaration_digest(dd, ro_a), "a mutating -> none flip must change the declaration digest"
        ro_path.write_text("POST /api/eval\nPOST /api/preview\n", encoding="utf-8")
        assert declaration_digest(dd, load_readonly_endpoints(ro_path)) != declaration_digest(dd, ro_a), \
            "editing read-only-endpoints.txt must change the declaration digest"
        side = d / "se-sidecar.json"
        side.write_text(json.dumps({"journeys": {"J-01": {"latest": {
            "complete": True, "mutating_count": 1, "auth_count": 0, "readonly_count": 0, "iter": 4,
            "requests": [{"method": "POST", "path": "/api/runs", "class": "mutating", "count": 1}],
            "readonly_endpoints_sha256": None, "ignore_paths": ["/login", "/logout", "/auth", "/session",
                                                                "/token", "/csrf"]}}}}), encoding="utf-8")
        led = build_side_effect_ledger(se_goal, sidecar=side, readonly_path=d / "absent.txt", env={})
        assert led["complete"], led["errors"]
        assert led["journeys"]["J-01"]["status"] == "mutating", "observation outranks a none declaration"
        assert led["journeys"]["J-02"]["status"] == "mutating"
        assert led["journeys"]["J-03"]["status"] == "unknown" and led["journeys"]["J-04"]["status"] == "unknown"
        sugg = render_side_effect_suggestions(led, "goal.md")
        assert "J-01" in sugg and "OBSERVED POST /api/runs" in sugg, sugg
        assert "- Side effects: none — <why this journey only reads>" in sugg, sugg
        assert "J-02 (Launch)" not in sugg, "a valid, consistent declaration needs no suggestion"

    print("self-test passed")
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, args = argv[0], argv[1:]
    if cmd == "journeys" and args:
        return cmd_journeys(args[0])
    if cmd == "coherence" and args:
        return cmd_coherence(args[0], "--for-achievement" in args[1:])
    if cmd == "results" and args:
        return cmd_results(args[0])
    if cmd == "regressions" and len(args) >= 2:
        return cmd_regressions(args[0], args[1])
    if cmd == "digest" and args:
        max_chars = 6000
        if "--max-chars" in args:
            max_chars = int(args[args.index("--max-chars") + 1])
        return cmd_digest(args[0], max_chars)
    if cmd == "goal-slice" and args:
        goal_path = args[0]
        history = ""
        targets: set[str] = set()
        out_path = None
        rest = args[1:]
        i = 0
        while i < len(rest):
            if rest[i] == "--history" and i + 1 < len(rest):
                history = rest[i + 1]; i += 2
            elif rest[i] == "--targets" and i + 1 < len(rest):
                targets = {t.strip() for t in rest[i + 1].split(",") if t.strip()}; i += 2
            elif rest[i] == "--out" and i + 1 < len(rest):
                out_path = rest[i + 1]; i += 2
            else:
                i += 1
        return cmd_goal_slice(goal_path, history, targets, out_path)
    if cmd == "hash-journeys" and args:
        history_p: str | None = None
        out_changed: str | None = None
        rest = args[1:]
        i = 0
        while i < len(rest):
            if rest[i] == "--history" and i + 1 < len(rest):
                history_p = rest[i + 1]; i += 2
            elif rest[i] == "--out-changed" and i + 1 < len(rest):
                out_changed = rest[i + 1]; i += 2
            else:
                i += 1
        return cmd_hash_journeys(args[0], history_p, out_changed)
    if cmd == "drift" and len(args) >= 2:
        return cmd_drift(args[0], args[1])
    if cmd == "side-effects" and args:
        valued = ("--sidecar", "--out", "--journeys", "--repo-root", "--readonly-endpoints",
                  "--iter", "--iter-name", "--step")
        flags = ("--suggest", "--record-digest")
        se_opts: dict = {}
        rest = args[1:]
        i = 0
        while i < len(rest):
            if rest[i] in valued and i + 1 < len(rest):
                se_opts[rest[i]] = rest[i + 1]; i += 2
            elif rest[i] in flags:
                se_opts[rest[i]] = True; i += 1
            else:
                i += 1
        return cmd_side_effects(args[0], se_opts)
    if cmd == "self-test":
        return _self_test()
    print(f"unknown command: {cmd}", file=sys.stderr)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
