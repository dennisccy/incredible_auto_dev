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
        [--iter N] [--iter-name NAME] [--step preflight|pre-evaluator]
        [--build-id ID] [--freeze PREFLIGHT_VIEW] [--record-digest]
        HARD-3 journey side-effect ledger. Each journey's status is
        `mutating` if a deterministic replay OBSERVED a mutation that no later
        complete clean replay of the same golden cleared (the sidecar plus the
        session's per-run records iter-*/replay-side-effects*.json) or the
        owner declared `- Side effects: mutating — <note>`; `none` if the owner
        declared `none`, nothing was observed and the observations could be
        read; `unknown` otherwise (no line, an invalid one, or unreadable
        observations). Carries the declaration_digest (sha256 over the parsed
        declarations + the read-only exception file), the per-journey
        declaration_hash and step hints. --record-digest (needs --out) merges
        per-run records the sidecar missed and updates the engine-owned
        sidecar's declaration bookkeeping (never a corrupt one) AFTER the ledger
        is written. --freeze P keeps the iteration's first complete preflight
        ledger at P and reuses it while its inputs (declarations, exception
        file, auth list, journey set) are unchanged, so a resumed iteration is
        re-checked against the same evidence it was planned against. With --out
        the ledger is written atomically and stdout
        carries one `<event>\t<json>` telemetry line per recorded change;
        without it stdout is the ledger JSON. --suggest prints paste-ready
        lines and never edits goal.md.
        exit 0: ledger complete   exit 3: ledger written but INCOMPLETE
        (corrupt sidecar or run record / unreadable exception file — a
        `Side-effect policy: none` spec fails closed on it)
        exit 2: goal.md unreadable, bad arguments, or --out not writable
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

import copy
import datetime
import hashlib
import json
import re
import sys
from pathlib import Path

from iter_spec import fence_scan, fenced_line_flags

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


def _split_lines(text: str) -> list[str]:
    return text.replace("\r\n", "\n").replace("\r", "\n").split("\n")


def _normalize_text(block: str) -> str:
    """The pure normaliser: line endings → \\n, per-line rstrip, trailing blank
    lines dropped — so formatting-only edits do not read as spec changes. It
    knows nothing about side-effect declarations (a later package that needs a
    plain normalised span uses this, not _normalize_block)."""
    lines = [ln.rstrip() for ln in _split_lines(block)]
    while lines and lines[-1] == "":
        lines.pop()
    return "\n".join(lines)


def _normalize_block(block: str, fenced: "list[bool] | None" = None) -> str:
    """_normalize_text of a journey block minus its well-formed declarations.

    HARD-3 (certification path, owner-approved D.3): a WELL-FORMED
    `- Side effects: none | mutating — <note>` line is DROPPED before hashing,
    so adding, editing or removing a valid declaration never creates goal-edit
    drift. It is not invisible: the separate declaration_digest (side-effects
    ledger) changes instead, and the engine emits side_effect_declaration_changed.
    A MALFORMED declaration-shaped line is ordinary journey text and stays in the
    hash, so editing it is drift (the safe direction) — the parser that decides
    "well-formed" is parse_side_effect_declarations' own (one regex, one rule).
    `fenced` carries the DOCUMENT's code-fence flags for these lines, so a line
    is judged exactly as the declaration parser judges it (a block may start or
    end inside a fence); without it the block's own fences are paired."""
    lines = _split_lines(block)
    drop = _well_formed_declaration_indices(lines, fenced)
    return _normalize_text("\n".join(ln for i, ln in enumerate(lines) if i not in drop))


def _journey_hashes(text: str) -> dict[str, str]:
    """sha256 hex of each journey block's normalized text, keyed by J-NN."""
    flags = fenced_line_flags(text.split("\n"))
    out: dict[str, str] = {}
    for jid, start, end in _journey_blocks(text):
        block = text[start:end]
        first = text.count("\n", 0, start)
        n = block.count("\n") + 1
        fenced = flags[first:first + n] if len(_split_lines(block)) == n else None
        out[jid] = hashlib.sha256(_normalize_block(block, fenced).encode("utf-8")).hexdigest()
    return out


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
# Owner-approved schema (plan D.3), one optional list item per journey block:
#     - Side effects: none | mutating — <note>
# Absent = `unknown`. Harmless formatting is normalized (case, whitespace,
# **bold**/`code` around the value, `-`/`–`/`—` before the note). Anything else
# — a near-miss label (`Side effect:`), a line that is not its own list item, an
# unknown value or a malformed note — is invalid (goal-lint ERROR
# side-effects-invalid) and reads as `unknown`, except that a clearly-stated
# `mutating` is still honoured when only its FORMAT is wrong: a malformed
# declaration may never make a journey less restrictive than its stated value.
# There is deliberately no `read-only` value: a read-only POST endpoint belongs
# in the digest-tracked exception file.
#
# Certification path: ONLY a well-formed declaration line is dropped before the
# journey spec_hash (_normalize_block). A malformed one stays journey text, so
# editing it is goal-edit drift — the safe direction — as well as a change of
# the declaration digest, which covers a malformed line's full text.
SIDE_EFFECT_VALUES = ("none", "mutating")
READONLY_ENDPOINTS_REL = "project-extensions/side-effects/read-only-endpoints.txt"
_SE_LINE_RE = re.compile(
    r"^[ \t]*(?P<bullet>[-*+][ \t]+)?(?:\*\*|__)?(?P<label>side[ \t]*[-_]?[ \t]*effects?)(?:\*\*|__)?"
    r"[ \t]*:(?:\*\*|__)?[ \t]*(?P<rest>.*?)[ \t]*$",
    re.IGNORECASE)
_SE_VALUE_RE = re.compile(r"^[*_`]*(?P<value>[A-Za-z]+)[*_`]*(?P<tail>.*)$", re.S)
_SE_NOTE_RE = re.compile(r"^[ \t]*[-–—]+[ \t]*(?P<note>.*?)[ \t]*$", re.S)
_SE_TRIVIAL_TAIL_RE = re.compile(r"^[ \t]*[.;,]?[ \t]*$")
_SE_RAW_VALUE_SPLIT_RE = re.compile(r"[ \t]+[-–—]|[–—]")
_SE_STEP_RE = re.compile(r"^(?P<indent>[ \t]*)(?P<n>\d+)[.)][ \t]+(?P<text>.*)$")
_SE_BULLET_RE = re.compile(r"^[ \t]*[-*+][ \t]")
_SE_CODE_SPAN_RE = re.compile(r"`([^`]*)`")
# Words that name a state-changing browser action (plan WP3: create|submit|save|
# delete|run|launch|upload|edit|update|post, with their common inflections).
# Heuristic ONLY: it drives goal-lint's advisory WARN and the step hints printed
# next to a finding — it never decides a status. A word counts only where the
# step DOES it: imperatively at the start of a clause ("Run the backfill",
# "then delete the row", "re-run"), as a control the step operates ("click
# Run", "press **Save**"), or as an all-caps label / HTTP method ("RUN TODAY",
# "POST /api/x"). "the run completes", "a past run" and "Run `pytest …`" (a
# command) do not count.
_SE_ACTION_STEMS = (r"(?:create[sd]?|creating|submit(?:s|ted|ting)?|save[sd]?|saving|delete[sd]?|deleting"
                    r"|runs?|launch(?:es|ed|ing)?|upload(?:s|ed|ing)?|edit(?:s|ed|ing)?|update[sd]?|updating"
                    r"|posts?|posted|posting)")
_SE_ACTION_WORD_RE = re.compile(rf"\b{_SE_ACTION_STEMS}\b", re.IGNORECASE)
_SE_CODE_TOKEN = " \x00code\x00 "
_SE_WORD_END = r"(?![\w-])(?![ \t]*\x00code\x00)"
_SE_CLAUSE_START_RE = re.compile(
    r"(?:^|[;:,.!?→—–(\[])[ \t]*(?:(?:then|and|also|now|finally|first|next)[ \t]+)*(?:\*\*|__|[\"'“‘])?"
    rf"(?:re-?)?(?P<w>{_SE_ACTION_STEMS}){_SE_WORD_END}", re.IGNORECASE)
_SE_CONTROL_RE = re.compile(
    r"\b(?:click(?:s|ed|ing)?|press(?:es|ed|ing)?|tap(?:s|ped|ping)?|hit(?:s|ting)?|select(?:s|ed|ing)?"
    r"|choos(?:e|es|ing)|chose|use[sd]?|using)[ \t]+(?:on[ \t]+)?(?:the[ \t]+)?(?:\*\*|__|[\"'“‘])?"
    rf"(?P<w>{_SE_ACTION_STEMS}){_SE_WORD_END}", re.IGNORECASE)
_SE_UPPER_RE = re.compile(r"\b(?P<w>RUNS?|SAVE|SUBMIT|CREATE|DELETE|LAUNCH|UPLOAD|EDIT|UPDATE|POST)(?![\w-])")
_SE_LABEL_SPAN_RE = re.compile(rf"{_SE_ACTION_STEMS}(?:[ \t]+[\w-]+){{0,2}}", re.IGNORECASE)
_JOURNEY_NAME_RE = re.compile(r"^\s*-\s+\*\*(J-\d+)\b[\s:.—–-]*(?P<name>.*?)\s*\*\*", re.MULTILINE)


def _declaration_line_matches(lines: list[str],
                              fenced: "list[bool] | None" = None) -> list[tuple[int, "re.Match[str]"]]:
    """(index, match) for every declaration-shaped line outside a code fence.
    `fenced`: document-level fence flags for exactly these lines; without it
    the lines' own fences are paired (iter_spec.fenced_line_flags)."""
    if fenced is None:
        fenced = fenced_line_flags(lines)
    out = []
    for i, ln in enumerate(lines):
        if i < len(fenced) and fenced[i]:
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
    joined = re.match(r"-[^\s\-–—][^\s]*", tail)
    if (joined and value in SIDE_EFFECT_VALUES
            and not m.group(0)[:len(m.group(0)) - len(tail)].rstrip().endswith(("*", "_", "`"))):
        # `none-destructive`: a hyphen glued to the value is part of the value.
        # A glued `mutating-…` still states mutating (never less restrictive).
        shown = value + joined.group(0)
        return {"value": "mutating" if value == "mutating" else None, "raw_value": shown, "note": "",
                "error": f"value {shown!r} is not 'none' or 'mutating' (put the note after a spaced dash)"}
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
    if not m.group("bullet"):
        errors.append("write the declaration as its own list item ('- Side effects: …'), "
                      "not as a continuation of another line")
    if parsed["error"]:
        errors.append(parsed["error"])
    return {"index": idx, "label_ok": label == "side effects", "value": parsed["value"],
            "raw_value": parsed["raw_value"], "note": parsed["note"], "errors": errors,
            "text": " ".join(m.group(0).split())}


def _well_formed_declaration_indices(lines: list[str], fenced: "list[bool] | None" = None) -> set[int]:
    """Indices of the lines a journey spec_hash ignores: well-formed declarations only."""
    return {i for i, m in _declaration_line_matches(lines, fenced)
            if not _parse_declaration_line(i, m)["errors"]}


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
    # A well-formed line contributes its meaning (formatting-neutral); a
    # malformed one its whole whitespace-normalized text, so ANY edit to it is
    # provenance-visible.
    items = [["side effects", f["value"], f["note"]] if not f["errors"] else ["malformed", f["text"]]
             for f in found]
    dhash = None
    if found:
        dhash = hashlib.sha256(json.dumps({"declared": declared or "unknown", "lines": items},
                                          sort_keys=True).encode("utf-8")).hexdigest()
    return {"declared": declared, "valid": not errors, "errors": errors, "note": note,
            "lines": found, "declaration_hash": dhash}


def _block_lines(block: str) -> list[str]:
    return block.replace("\r\n", "\n").replace("\r", "\n").split("\n")


def _norm_newlines(text: str) -> str:
    return text.replace("\r\n", "\n").replace("\r", "\n")


def side_effect_journey_blocks(text: str) -> list[tuple[str, int, int]]:
    """(journey_id, start, end) spans over the newline-normalised text — nested
    headers included, headers inside code fences start no block — with the header
    indent measured on the header's OWN line.

    `_journey_blocks` (the certified spec_hash path — deliberately untouched)
    measures `len(m.group(1))`, and that leading-whitespace group also swallows
    the blank lines before a header, so a journey preceded by two blank lines is
    not a boundary for one preceded by a single blank line and the earlier block
    runs on into it. Declarations must never be attributed to the wrong journey,
    so side-effect parsing uses this corrected splitter (through
    side_effect_journey_views). Hash neutrality does not depend on it:
    _normalize_block judges each line on its own.

    A header inside what the parser reads as a code fence starts no block, but
    it still ENDS the block above it, as it does for _journey_blocks: a stray
    fence must never let one journey's block run on through another journey's
    lines (side_effect_journey_views_all reads such a header's own item)."""
    text = _norm_newlines(text)
    fenced = fenced_line_flags(text.split("\n"))

    def _line_start_and_indent(m: "re.Match[str]") -> tuple[int, int]:
        lead = m.group(1)
        own = lead.rsplit("\n", 1)[-1]
        return m.start() + len(lead) - len(own), len(own.expandtabs(4))

    all_headers = [(m, *_line_start_and_indent(m)) for m in _JOURNEY_HEADER_RE.finditer(text)]
    blocks: list[tuple[str, int, int]] = []
    for i, (m, start, indent) in enumerate(all_headers):
        if fenced[text.count("\n", 0, start)]:
            continue
        end = len(text)
        for _nm, nstart, nindent in all_headers[i + 1:]:
            if nindent <= indent:
                end = nstart
                break
        boundary = None
        for bm in re.finditer(r"^(#{1,6}\s|<!--)", text[m.end():end], re.MULTILINE):
            if not fenced[text.count("\n", 0, m.end() + bm.start())]:
                boundary = bm
                break
        if boundary:
            end = m.end() + boundary.start()
        blocks.append((m.group(2), start, end))
    return blocks


def _list_item_end(text: str, fenced: list[bool], start: int, end: int) -> int:
    """Where the list item whose header line starts at `start` ends: the first
    later non-blank, unfenced line indented no deeper than the header."""
    first = text.count("\n", 0, start)
    lines = text[start:end].split("\n")
    head = lines[0].expandtabs(4)
    indent = len(head) - len(head.lstrip())
    pos = start + len(lines[0]) + 1
    for k, ln in enumerate(lines[1:], 1):
        if ln.strip() and not fenced[first + k]:
            exp = ln.expandtabs(4)
            if len(exp) - len(exp.lstrip()) <= indent:
                return min(pos, end)
        pos += len(ln) + 1
    return end


def _has_own_content(lines: list[str], fenced: list[bool]) -> bool:
    """Does a nested journey header carry its own declaration or numbered step?"""
    body, flags = lines[1:], fenced[1:]
    if _declaration_line_matches(body, fenced=flags):
        return True
    return any(_SE_STEP_RE.match(ln) and not f for ln, f in zip(body, flags))


_NAMED_HEADER_RE = re.compile(r"^[ \t]*[-*+][ \t]+\*\*J-\d+\b[ \t]*[:.\u2013\u2014-][ \t]*[^\s*]")


def side_effect_journey_views(text: str) -> list[dict]:
    """One view per journey DEFINITION over the newline-normalised text:
    {jid, start, end, own, fenced, duplicate}.

    - A header nested inside a block of the SAME journey (an owner note such as
      `- **J-10 CLOSED — …**`) is part of that block, not a second definition.
    - A nested header of ANOTHER journey is a definition when its own list item
      carries a declaration or a numbered step, or when it names a journey
      (`- **J-06: Refund**`) that no top-level header defines; its item's lines
      are then blanked out of the parent (newlines kept, so line indices stay
      relative to `start`). A bare `- **J-11** depends on this`, or a titled
      mention of a journey defined at top level, is a mere reference and its
      line simply stays part of the parent.
    - `fenced` flags each own line that is a code-fence delimiter or inside a
      fence (document-level), `duplicate` marks an id with >1 definition."""
    text = _norm_newlines(text)
    lines_all = text.split("\n")
    fenced_all = fenced_line_flags(lines_all)
    blocks = side_effect_journey_blocks(text)
    items = []
    for jid, st, en in blocks:
        containers = [(j2, s2, e2) for j2, s2, e2 in blocks if s2 < st < e2]
        items.append({"jid": jid, "start": st, "end": en, "containers": containers})
    top_level = {it["jid"] for it in items if not it["containers"]}
    for it in items:
        if not it["containers"]:
            it["kind"] = "def"
            continue
        it["end"] = _list_item_end(text, fenced_all, it["start"], it["end"])
        if any(c[0] == it["jid"] for c in it["containers"]):
            it["kind"] = "same"
            continue
        first = text.count("\n", 0, it["start"])
        body = text[it["start"]:it["end"]].split("\n")
        if _has_own_content(body, fenced_all[first:first + len(body)]):
            it["kind"] = "def"
        elif _NAMED_HEADER_RE.match(body[0]) and it["jid"] not in top_level:
            it["kind"] = "def"     # a sub-journey named only here
        else:
            it["kind"] = "ref"     # a bare or titled mention of a journey defined elsewhere
    defs = [it for it in items if it["kind"] == "def"]
    views: list[dict] = []
    for d in defs:
        holes = sorted((o["start"], min(o["end"], d["end"])) for o in defs
                       if o is not d and o["jid"] != d["jid"] and d["start"] < o["start"] < d["end"])
        parts: list[str] = []
        pos = d["start"]
        for hs, he in holes:
            if he <= pos:
                continue
            hs = max(hs, pos)
            parts.append(text[pos:hs])
            parts.append("\n" * text.count("\n", hs, he))
            pos = he
        parts.append(text[pos:d["end"]])
        own = "".join(parts)
        first = text.count("\n", 0, d["start"])
        n = own.count("\n") + 1
        views.append({"jid": d["jid"], "start": d["start"], "end": d["end"], "own": own,
                      "fenced": fenced_all[first:first + n]})
    counts: dict[str, int] = {}
    for v in views:
        counts[v["jid"]] = counts.get(v["jid"], 0) + 1
    for v in views:
        v["duplicate"] = counts[v["jid"]] > 1
    return views


def _item_end_any(text: str, start: int, end: int) -> int:
    """Where the list item whose header line starts at `start` ends, fences
    ignored: the first later non-blank line indented no deeper than the header
    (capped at `end`)."""
    lines = text[start:end].split("\n")
    head = lines[0].expandtabs(4)
    indent = len(head) - len(head.lstrip())
    pos = start + len(lines[0]) + 1
    for ln in lines[1:]:
        exp = ln.expandtabs(4)
        if ln.strip() and len(exp) - len(exp.lstrip()) <= indent:
            return min(pos, end)
        pos += len(ln) + 1
    return end


def side_effect_journey_views_all(text: str) -> list[dict]:
    """side_effect_journey_views plus a fail-closed view for every journey header
    the CERTIFIED splitter (_journey_blocks) sees that the side-effect splitter
    does not read as a definition:

    - `unattributed`: an id that no definition covers — only nested references
      name it (`no-definition`), or its only header sits inside what the parser
      reads as a code fence (`fenced-header`);
    - `ambiguous` (reason `fenced-header`): an id WITH a live definition that
      also has a header inside a code fence. A stray fence can shift the pairing
      of every later fence without leaving a trace, so the fenced header may be
      the real definition and the live one an example; which one it is cannot be
      told, so neither is trusted with a `none` (goal-lint's duplicate-id ERROR
      already asks the owner to rename an example that reuses a real id).

    Such a view reads the header's own list item (fences ignored for where it
    ends, so it never runs into a neighbouring journey's lines); a line there
    counts as a declaration when either the document's or the item's own fence
    pairing leaves it unfenced. Its stated values are provenance only
    (`stated_values`): a stated `mutating` makes the journey mutating, a stated
    `none` is never trusted, and nothing in such a view is reported as the
    owner's declaration.

    Every live view also carries `blind_values`: the values of the
    declaration-shaped lines in it that only a fence-ignoring read sees (outside
    the extra views' items). A `mutating` there makes the id `ambiguous` (reason
    `fenced-declaration`): a stray fence may have hidden the journey's own line."""
    views = side_effect_journey_views(text)
    norm = _norm_newlines(text)
    doc_flags = fence_scan(norm.split("\n"))[0]
    defined = {v["jid"] for v in views}
    for jid, start, end in _journey_blocks(norm):
        pos = start
        while pos < end and norm[pos] in " \t\n":
            pos += 1
        line_no = norm.count("\n", 0, pos)
        fenced_header = doc_flags[line_no]
        if jid not in defined:
            kind, reason = "unattributed", ("fenced-header" if fenced_header else "no-definition")
        elif fenced_header:
            kind, reason = "ambiguous", "fenced-header"
        else:
            continue
        line_start = norm.rfind("\n", 0, pos) + 1    # the item's indent is measured on its own line
        stop = _item_end_any(norm, line_start, end)
        block = norm[line_start:stop]
        own_flags = fenced_line_flags(_block_lines(block))
        doc_slice = doc_flags[line_no:line_no + len(own_flags)]
        fenced = ([a and b for a, b in zip(doc_slice, own_flags)] if len(doc_slice) == len(own_flags)
                  else own_flags)
        views.append({"jid": jid, "start": line_start, "end": stop, "own": block, "fenced": fenced,
                      "duplicate": False, "extra": kind, "reason": reason})
    extra_spans = [(v["start"], v["end"]) for v in views if v.get("extra")]
    for v in views:
        if v.get("extra"):
            continue
        lines = _block_lines(v["own"])
        live = {i for i, _m in _declaration_line_matches(lines, fenced=v["fenced"])}
        offsets, pos = [], v["start"]
        for ln in lines:
            offsets.append(pos)
            pos += len(ln) + 1
        v["blind_values"] = sorted({
            _parse_declaration_line(i, m)["value"] or "?"
            for i, m in _declaration_line_matches(lines, fenced=[False] * len(lines))
            if i not in live and not any(s <= offsets[i] < e for s, e in extra_spans)} - {"?"})
    return views


def side_effect_journey_own_blocks(text: str) -> list[tuple[str, int, int, str, bool]]:
    """(journey_id, start, end, own_text, duplicate) per journey definition —
    see side_effect_journey_views (offsets refer to the newline-normalised
    text)."""
    return [(v["jid"], v["start"], v["end"], v["own"], v["duplicate"]) for v in side_effect_journey_views(text)]


_AMBIGUOUS_FENCED_LINE_ERROR = ("a 'Side effects: mutating' line in this journey sits inside what the parser reads as "
                                "a code fence, so the journey counts as mutating and its other lines cannot be "
                                "trusted — move the example out of the journey, or close a stray ``` / ~~~ line "
                                "above it")
_AMBIGUOUS_ERROR = ("a header for this journey id also sits inside what the parser reads as a code fence, so its "
                    "'Side effects:' lines cannot be attributed with certainty: a 'none' does not count, a "
                    "'mutating' does — rename the example's id, or close a stray fence above it")


def parse_side_effect_declarations(text: str) -> dict[str, dict]:
    """{journey id: declaration} for every journey defined in goal.md text.

    declaration = {declared: 'none'|'mutating'|None, valid, errors, note, lines,
    declaration_hash (None when the journey has no declaration line)}; each
    line's `index` is relative to the journey block's first line. `declared`
    comes only from the journey's own definition(s). An id with an extra view
    (side_effect_journey_views_all), or whose live block holds a `mutating` line
    only a fence-ignoring read sees, also carries `unattributed` or `ambiguous`,
    `attribution_reason` and `stated_values` — the values stated anywhere for
    it, provenance only."""
    live: dict[str, list[dict]] = {}
    extra: dict[str, list[dict]] = {}
    kinds: dict[str, tuple[str, str]] = {}
    dup: set[str] = set()
    order: list[str] = []
    blind: dict[str, set] = {}
    for v in side_effect_journey_views_all(text):
        jid = v["jid"]
        if jid not in order:
            order.append(jid)
        found = [_parse_declaration_line(i, m)
                 for i, m in _declaration_line_matches(_block_lines(v["own"]), fenced=v["fenced"])]
        if v.get("extra"):
            extra.setdefault(jid, []).extend(found)
            kinds.setdefault(jid, (v["extra"], v["reason"]))
        else:
            live.setdefault(jid, []).extend(found)
            blind.setdefault(jid, set()).update(v.get("blind_values") or [])
            if v["duplicate"]:
                dup.add(jid)
    for jid, values in blind.items():
        if "mutating" in values and jid not in kinds \
                and "mutating" not in {f["value"] for f in live.get(jid, [])}:
            kinds[jid] = ("ambiguous", "fenced-declaration")
    out: dict[str, dict] = {}
    for jid in order:
        d = _effective_declaration(live.get(jid, []), duplicate_block=jid in dup)
        if jid in kinds:
            kind, reason = kinds[jid]
            stated = _effective_declaration(extra.get(jid, []))
            d[kind] = True
            d["attribution_reason"] = reason
            d["stated_values"] = sorted({f["value"] for f in extra.get(jid, []) + live.get(jid, []) if f["value"]}
                                        | blind.get(jid, set()))
            d["stated_hash"] = stated["declaration_hash"]   # any edit of those lines is provenance-visible
            if kind == "unattributed":
                d["declaration_hash"] = stated["declaration_hash"]
            if kind == "ambiguous":
                d["errors"].append(_AMBIGUOUS_FENCED_LINE_ERROR if reason == "fenced-declaration" else _AMBIGUOUS_ERROR)
                d["valid"] = False
        out[jid] = d
    return out


def _journey_steps(block: str, fenced: "list[bool] | None" = None) -> list[dict]:
    """Numbered steps of a journey block with their continuation lines:
    [{n, line (index in the block), text}]. `fenced`: document-level fence
    flags for the block's lines; without it the block's own fences are paired."""
    steps: list[dict] = []
    cur = None
    lines = _block_lines(block)
    if fenced is None:
        fenced = fenced_line_flags(lines)
    for i, raw in enumerate(lines):
        if i < len(fenced) and fenced[i]:
            cur = None
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


def _se_plain(text: str) -> str:
    """Code spans out of the way: a span that is itself a control label (`Run`,
    `Save draft`) keeps its words; any other span (a path, a command) becomes a
    placeholder that is never an action and blocks an imperative before it."""
    def _repl(m: "re.Match[str]") -> str:
        inner = m.group(1).strip()
        return inner if _SE_LABEL_SPAN_RE.fullmatch(inner) else _SE_CODE_TOKEN
    return _SE_CODE_SPAN_RE.sub(_repl, text)


def step_action_words(text: str) -> set[str]:
    """Lower-cased action words a step (or one clause of it) actually performs."""
    plain = _se_plain(text)
    words: set[str] = set()
    for rx in (_SE_CLAUSE_START_RE, _SE_CONTROL_RE, _SE_UPPER_RE):
        words.update(m.group("w").lower() for m in rx.finditer(plain))
    return words


def journey_step_hints(block: str, cap: int = 3, fenced: "list[bool] | None" = None) -> list[dict]:
    """Numbered steps that perform a state-changing action: [{n, line, text,
    words}]. `text` is the step's matching clauses (split on ';')."""
    hints: list[dict] = []
    for step in _journey_steps(block, fenced):
        words = sorted(step_action_words(step["text"]))
        if not words:
            continue
        clauses = [c.strip() for c in step["text"].split(";") if c.strip()]
        hit = [c for c in clauses if step_action_words(c)]
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
    items = []
    for jid, d in sorted(decls.items()):
        marker = "ambiguous" if d.get("ambiguous") else ("unattributed" if d.get("unattributed") else None)
        if marker:
            items.append([jid, d["declared"] or "unknown", d["note"], d["declaration_hash"],
                          f"{marker}:{d.get('attribution_reason')}", d.get("stated_values") or [],
                          d.get("stated_hash")])
        elif d["declaration_hash"]:
            items.append([jid, d["declared"] or "unknown", d["note"], d["declaration_hash"]])
    payload = {"schema": "journey-side-effect-declarations/1", "journeys": items,
               "read_only_endpoints_sha256": _readonly_token(ro)}
    return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def _load_side_effect_sidecar(path) -> tuple["dict | None", "str | None"]:
    """(data, error). An absent sidecar is (None, None): nothing merged yet."""
    if not path:
        return None, None
    p = Path(path)
    try:
        raw = p.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None, None
    except (OSError, ValueError) as exc:
        return None, f"side-effect sidecar {path} is unreadable ({getattr(exc, 'strerror', None) or exc})"
    try:
        data = json.loads(raw)
    except (ValueError, RecursionError) as exc:
        return None, f"side-effect sidecar {path} is not valid JSON ({exc})"
    from demo_runner import sidecar_shape_error  # noqa: PLC0415
    shape = sidecar_shape_error(data)
    if shape:
        return None, f"side-effect sidecar {path} has the wrong shape ({shape})"
    return data, None


def _scan_run_records(sidecar) -> tuple[list, list]:
    """(records, errors): every per-run observation record of the session the
    sidecar belongs to (<session>/iter-*/replay-side-effects*.json — current and
    archived), oldest first. They are never deleted, so the observations stay
    recoverable when the sidecar is corrupt, moved aside or missed an update."""
    if not sidecar:
        return [], []
    p = Path(sidecar)
    if p.parent.name != "state":
        return [], []
    session = p.parent.parent
    try:
        files = sorted(session.glob("iter-*/replay-side-effects*.json"))
    except OSError as exc:
        return [], [f"the per-run side-effect records under {session} cannot be listed ({exc})"]
    from demo_runner import observation_time  # noqa: PLC0415
    recs: list = []
    errs: list = []
    for f in files:
        try:
            d = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, ValueError, RecursionError) as exc:
            errs.append(f"per-run side-effect record {f} is unreadable ({exc})")
            continue
        if (not isinstance(d, dict) or not isinstance(d.get("run_id"), str) or not d["run_id"]
                or not isinstance(d.get("journeys"), dict)
                or any(not isinstance(o, dict) for o in d["journeys"].values())):
            errs.append(f"per-run side-effect record {f} has the wrong shape")
            continue
        recs.append({"path": str(f), "run_id": d["run_id"], "observed_at": d.get("observed_at"),
                     "journeys": d["journeys"]})
    recs.sort(key=lambda r: (observation_time(r), r["run_id"]))
    return recs, errs


def _reclassify(ev: dict, ro: dict, ignore: list[str], classify, version: int):
    """(still_mutating, requests, exceptions_applied, auth_ignored, basis) for one
    recorded observation. When the exception file, the auth list or the
    classifier rules changed since it was recorded, its stored {method, path}
    sample is re-classified with the CURRENT rules; a truncated sample cannot
    be, so it stays mutating if it held any candidate request (fail closed)."""
    try:
        mut = int(ev.get("mutating_count") or 0)
        auth = int(ev.get("auth_count") or 0)
        roc = int(ev.get("readonly_count") or 0)
    except (TypeError, ValueError):
        raise ValueError("observation counts are not integers") from None
    reqs = ev.get("requests") or []
    if not isinstance(reqs, list) or any(not isinstance(r, dict) for r in reqs):
        raise ValueError("observation requests are not a list of objects")

    def _pairs(key: str) -> list:
        v = ev.get(key) or []
        return [dict(x) for x in v if isinstance(x, dict)] if isinstance(v, list) else []

    stale = (bool(ev.get("context_mixed"))
             or ev.get("classifier_version") != version
             or ev.get("readonly_endpoints_sha256") != ro.get("sha256")
             or bool(ev.get("readonly_endpoints_error")) != bool(ro.get("error"))
             or list(ev.get("ignore_paths") or []) != list(ignore))
    if not stale:
        return mut > 0, [dict(r) for r in reqs], _pairs("exceptions_applied"), _pairs("auth_ignored"), "recorded"
    if ev.get("truncated"):
        return (mut + auth + roc) > 0, [dict(r) for r in reqs], [], [], "reclassification-unverifiable"
    entries = [] if ro.get("error") else (ro.get("entries") or [])
    shown = []
    for r in reqs:
        r2 = dict(r)
        r2["class"] = classify(str(r.get("method") or ""), str(r.get("path") or "/"), ignore, entries)
        shown.append(r2)
    observed = any(r["class"] == "mutating" for r in shown) or (mut > 0 and not reqs)
    exceptions = [{"method": r.get("method"), "path": r.get("path")} for r in shown
                  if r["class"] == "ignored-readonly"]
    auth_ignored = [{"method": r.get("method"), "path": r.get("path")} for r in shown
                    if r["class"] == "ignored-auth"]
    return observed, shown, exceptions, auth_ignored, "reclassified"


def _journey_observation(rec, ro: dict, ignore: list[str], classify, version: int) -> dict:
    """Observed-mutation facts for one journey record (sidecar + un-merged run
    records). Status evidence is every mutation that no strictly newer complete
    clean replay of the SAME golden cleared (demo_runner.uncleared_mutations);
    `observation_sticky` marks one that a newer clean replay of a DIFFERENT
    golden could not clear."""
    from demo_runner import observation_time, sidecar_shape_error, uncleared_mutations  # noqa: PLC0415
    base = {"observed_mutating": False, "observed_iter": None, "observed_iter_name": None,
            "observation_complete": None, "observation_basis": None, "observed_at": None,
            "observation_sticky": False, "sticky_detail": None, "golden_sha256": None,
            "requests": [], "exceptions_applied": [], "auth_ignored": [], "error": None}
    if rec is None:
        return base
    shape = sidecar_shape_error({"journeys": {"J": rec}})
    if shape:
        return {**base, "error": shape.replace("record J", "the record")}
    latest = rec.get("latest")
    try:
        uncleared = uncleared_mutations(rec)
        # A clean replay's sample can hold requests an exclusion let through;
        # re-checked under the current rules, they may be mutations after all.
        goldens = rec.get("goldens") if isinstance(rec.get("goldens"), dict) else {}
        cleans = [e["clean"] for e in goldens.values() if isinstance(e, dict) and isinstance(e.get("clean"), dict)]
        if isinstance(latest, dict):
            cleans.append(latest)
        cleans.sort(key=observation_time, reverse=True)
        for m in uncleared + cleans:
            observed, shown, exc, auth_ig, basis = _reclassify(m, ro, ignore, classify, version)
            if not observed:
                continue
            sticky = bool(any(m is u for u in uncleared) and isinstance(latest, dict)
                          and latest.get("complete") is True
                          and not int(latest.get("mutating_count") or 0)
                          and observation_time(latest) > observation_time(m))
            detail = ({"iter": latest.get("iter"), "iter_name": latest.get("iter_name"),
                       "golden_sha256": latest.get("golden_sha256")} if sticky else None)
            return {**base, "observed_mutating": True, "observed_iter": m.get("iter"),
                    "observed_iter_name": m.get("iter_name"), "observation_complete": m.get("complete"),
                    "observation_basis": basis, "observed_at": m.get("observed_at"),
                    "observation_sticky": sticky, "sticky_detail": detail,
                    "golden_sha256": m.get("golden_sha256"), "requests": shown,
                    "exceptions_applied": exc, "auth_ignored": auth_ig}
        if isinstance(latest, dict):
            _o, shown, exc, auth_ig, basis = _reclassify(latest, ro, ignore, classify, version)
            return {**base, "observed_iter": latest.get("iter"), "observed_iter_name": latest.get("iter_name"),
                    "observation_complete": latest.get("complete"), "observation_basis": basis,
                    "observed_at": latest.get("observed_at"), "golden_sha256": latest.get("golden_sha256"),
                    "requests": shown, "exceptions_applied": exc, "auth_ignored": auth_ig}
    except (TypeError, ValueError) as exc:
        return {**base, "error": str(exc)}
    return base


def build_side_effect_ledger(goal_text: str, sidecar=None, readonly_path=None, *, iter_n=None,
                             iter_name=None, step=None, goal_file=None, env=None, build_id=None) -> dict:
    """The deterministic per-iteration side-effect ledger (a pure read: run
    records the sidecar has not merged yet are applied in memory)."""
    from demo_runner import (SIDE_EFFECT_CLASSIFIER_VERSION, classify_candidate,  # noqa: PLC0415
                             load_readonly_endpoints, merge_side_effect_observations,
                             side_effect_ignore_paths, side_effect_ignore_paths_report)
    errors: list[str] = []
    decls = parse_side_effect_declarations(goal_text)
    views: dict[str, dict] = {}
    for v in side_effect_journey_views_all(goal_text):
        views.setdefault(v["jid"], v)
    names = {m.group(1): m.group("name").strip() for m in _JOURNEY_NAME_RE.finditer(goal_text)}
    ro = load_readonly_endpoints(readonly_path)
    if ro["error"]:
        errors.append(f"read-only exception file {ro['path']} is {ro['error']} — exceptions cannot be "
                      "applied and recorded observations cannot be re-checked")
    ignore_t, ignore_rejected = side_effect_ignore_paths_report(env)
    ignore = list(ignore_t)
    side, side_err = _load_side_effect_sidecar(sidecar)
    unestablished = False
    if side_err:
        errors.append(side_err + " — observations recorded only there cannot be read this iteration")
        unestablished = True
    run_recs, run_errs = _scan_run_records(sidecar)
    for e in run_errs:
        errors.append(e + " — the observations it holds are unknown this iteration")
        unestablished = True
    merged_runs = set()
    if isinstance(side, dict) and isinstance(side.get("merged_runs"), list):
        merged_runs = {r for r in side["merged_runs"] if isinstance(r, str)}
    pending = [r for r in run_recs if r["run_id"] not in merged_runs]
    work = copy.deepcopy(side) if isinstance(side, dict) else {}
    for r in pending:
        work = merge_side_effect_observations(work, r["journeys"], now="(in memory)", run_id=r["run_id"])
    records = work.get("journeys") or {}
    journeys: dict[str, dict] = {}
    for jid, view in views.items():
        d = decls[jid]
        o = _journey_observation(records.get(jid), ro, ignore, classify_candidate, SIDE_EFFECT_CLASSIFIER_VERSION)
        if o["error"]:
            errors.append(f"side-effect record for {jid} is unusable ({o['error']})")
        established = not unestablished and not o["error"]
        observed = o["observed_mutating"]
        unattr, ambiguous = bool(d.get("unattributed")), bool(d.get("ambiguous"))
        stated = d.get("stated_values") or []
        if observed or d["declared"] == "mutating" or "mutating" in stated:
            status = "mutating"
        elif d["declared"] == "none" and established and not ambiguous:
            status = "none"
        else:
            status = "unknown"   # includes a `none` whose observations cannot be read, or an ambiguous one
        if observed and d["declared"] == "mutating":
            source = "declared+observed"
        elif observed:
            source = "observed"
        elif ambiguous:
            source = "ambiguous"
        elif unattr:
            source = "unattributed"
        elif d["declared"] == "none" and not established:
            source = "declared-unverified"
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
            "observation_established": established,
            "observation_sticky": o["observation_sticky"],
            "sticky_detail": o["sticky_detail"],
            "observed_at": o["observed_at"],
            "golden_sha256": o["golden_sha256"],
            "requests": o["requests"],
            "exceptions_applied": o["exceptions_applied"],
            "auth_ignored": o["auth_ignored"],
            # any block that says `none` for an observed journey is a conflict (POSSIBLE when uncertain)
            "declaration_conflict": bool(observed and (
                d["declared"] == "none" or ((unattr or ambiguous) and "none" in stated))),
            "unattributed": unattr,
            "ambiguous": ambiguous,
            "attribution_reason": d.get("attribution_reason"),
            "stated_values": stated,
            "status": status,
            "status_source": source,
            "step_hints": [{k: h[k] for k in ("n", "text", "words")}
                           for h in journey_step_hints(view["own"], fenced=view["fenced"])],
        }
    summary = {s: [j for j, r in journeys.items() if r["status"] == s] for s in ("mutating", "none", "unknown")}
    digest = declaration_digest(decls, ro)
    recorded = side if isinstance(side, dict) and "declarations" in side else None
    seed = None
    if recorded is None and not side_err and sidecar:
        seed = _declaration_seed(sidecar, iter_n)
    fingerprint = hashlib.sha256(json.dumps({
        "declaration_digest": digest, "ignore_paths": ignore, "readonly": _readonly_token(ro),
        "classifier_version": SIDE_EFFECT_CLASSIFIER_VERSION, "journeys": sorted(journeys),
    }, sort_keys=True).encode("utf-8")).hexdigest()
    return {
        "schema_version": 1,
        "build_id": build_id,
        "input_fingerprint": fingerprint,
        "built_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "built_at_step": step,
        "iter": iter_n,
        "iter_name": iter_name,
        "goal_file": goal_file,
        "sidecar": str(sidecar) if sidecar else None,
        "complete": not errors,
        "errors": errors,
        "declaration_digest": digest,
        "recorded_declaration_digest": (recorded or {}).get("declaration_digest") or (seed or {}).get("digest"),
        "declaration_digest_prev": (recorded or {}).get("declaration_digest_prev"),
        "declaration_digest_changed_iter": (recorded or {}).get("declaration_digest_changed_iter"),
        "declarations_seeded_from": (seed or {}).get("path"),
        "readonly_endpoints": {k: ro[k] for k in ("path", "present", "sha256", "entries", "invalid", "error")},
        "ignore_paths": ignore,
        "ignore_paths_default": tuple(ignore) == tuple(side_effect_ignore_paths({})),
        "ignore_paths_rejected": list(ignore_rejected),
        "run_records_pending": [r["path"] for r in pending if r["journeys"]],
        "journeys": journeys,
        "summary": summary,
        "conflicts": [j for j, r in journeys.items() if r["declaration_conflict"]],
        "declaration_errors": [{"journey": j, "errors": r["declaration_errors"]}
                               for j, r in journeys.items() if not r["declaration_valid"]],
    }


def _declaration_seed(sidecar, iter_n) -> "dict | None":
    """When the sidecar holds no declaration record (new, or moved aside), the
    newest earlier iteration ledger (iter-<K>/side-effects.json, K < iter_n) is
    the provenance baseline, so a declaration flip made at the same time still
    emits side_effect_declaration_changed."""
    p = Path(sidecar)
    if p.parent.name != "state":
        return None
    best = None
    for f in p.parent.parent.glob("iter-*/side-effects.json"):
        try:
            d = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, ValueError, RecursionError):
            continue
        if not isinstance(d, dict) or not isinstance(d.get("journeys"), dict) or not d.get("declaration_digest"):
            continue
        try:
            k = int(d.get("iter"))
        except (TypeError, ValueError):
            continue
        if iter_n is not None and k >= iter_n:
            continue
        if best is None or k > best[0]:
            best = (k, f, d)
    if best is None:
        return None
    _k, f, d = best
    decls = {jid: {"declared": j.get("declared"), "declaration_hash": j.get("declaration_hash"),
                   "note": j.get("note") or ""}
             for jid, j in d["journeys"].items() if isinstance(j, dict) and j.get("declaration_hash")}
    ro = d.get("readonly_endpoints") if isinstance(d.get("readonly_endpoints"), dict) else {}
    return {"path": str(f), "digest": d["declaration_digest"], "declarations": decls,
            "readonly_endpoints_sha256": _readonly_token(ro), "ignore_paths": d.get("ignore_paths")}


def _first_mutating(requests) -> str:
    return next((f"{r.get('method')} {r.get('path')}" for r in requests or []
                 if isinstance(r, dict) and r.get("class") == "mutating"), "a mutating request")


def record_side_effect_declarations(sidecar_path, ledger: dict, iter_n, iter_name) -> tuple[list, "str | None"]:
    """Engine bookkeeping, one read-modify-write under the same directory lock the
    observer uses: merge every per-run record the sidecar has not merged yet
    (repair), record the current declarations + digest, and return the telemetry
    events for what changed since the last record. A corrupt or wrongly-shaped
    sidecar is never overwritten."""
    from demo_runner import (_atomic_write_json, _locked_dir,  # noqa: PLC0415
                             merge_side_effect_observations, sidecar_shape_error)
    events: list = []
    p = Path(sidecar_path)
    cur_decls = {jid: {"declared": j["declared"], "declaration_hash": j["declaration_hash"], "note": j["note"]}
                 for jid, j in ledger["journeys"].items() if j["declaration_hash"]}
    ro_token = _readonly_token(ledger["readonly_endpoints"])
    digest = ledger["declaration_digest"]
    run_recs, _run_errs = _scan_run_records(p)
    repaired: list = []
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        with _locked_dir(p.parent):
            current: dict = {}
            if p.exists():
                try:
                    current = json.loads(p.read_text(encoding="utf-8"))
                except (OSError, ValueError, RecursionError) as exc:
                    return [], f"{p} is unreadable or corrupt ({exc}) — declarations not recorded, file not overwritten"
                shape = sidecar_shape_error(current)
                if shape:
                    return [], f"{p} has the wrong shape ({shape}) — declarations not recorded, file not overwritten"
            done = {r for r in current.get("merged_runs") or [] if isinstance(r, str)}
            for r in run_recs:
                if r["run_id"] not in done:
                    current = merge_side_effect_observations(current, r["journeys"], run_id=r["run_id"])
                    if r["journeys"]:
                        repaired.append(r)
            if not isinstance(current.get("declarations"), dict):
                seed = _declaration_seed(p, iter_n)
                if seed:
                    current["declarations"] = seed["declarations"]
                    current.setdefault("declaration_digest", seed["digest"])
                    current.setdefault("readonly_endpoints_sha256", seed["readonly_endpoints_sha256"])
                    if isinstance(seed.get("ignore_paths"), list):
                        current.setdefault("ignore_paths", seed["ignore_paths"])
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
                        "rejected": list(ledger.get("ignore_paths_rejected") or []),
                        "iter": iter_n, "iter_name": iter_name, "declaration_digest": digest[:12]}))
                if "readonly_endpoints_sha256" in current and current.get("readonly_endpoints_sha256") != ro_token:
                    events.append(("side_effect_declaration_changed", {
                        "journey": None, "source": "read-only-endpoints",
                        "from": (current.get("readonly_endpoints_sha256") or "absent")[:12],
                        "to": (ro_token or "absent")[:12], "iter": iter_n, "iter_name": iter_name,
                        "declaration_digest": digest[:12]}))
            # A journey declared `none` that a replay observed mutating: reported
            # once per distinct observation (the evaluator is told every time).
            prev_conf = current.get("declaration_conflicts")
            prev_conf = prev_conf if isinstance(prev_conf, dict) else {}
            conflicts: dict = {}
            for jid, j in ledger["journeys"].items():
                if not j.get("declaration_conflict"):
                    continue
                sample = _first_mutating(j.get("requests"))
                conflicts[jid] = f"{sample}@{j.get('observed_at') or ''}"
                if prev_conf.get(jid) != conflicts[jid]:
                    events.append(("side_effect_declaration_conflict", {
                        "journey": jid, "declared": "none", "observed": sample,
                        "observed_iter": j.get("observed_iter"), "sticky": bool(j.get("observation_sticky")),
                        "iter": iter_n, "iter_name": iter_name}))
            current["declaration_conflicts"] = conflicts
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
        return [], f"declarations not recorded ({exc})"
    if repaired:
        events.append(("side_effect_observations_repaired", {
            "iter": iter_n, "iter_name": iter_name, "runs": [r["run_id"] for r in repaired],
            "records": [f"{Path(r['path']).parent.name}/{Path(r['path']).name}" for r in repaired]}))
    return events, None


def attribution_problem(j: dict) -> str:
    """Plain words for an unattributed or ambiguous ledger entry (goal-lint and --suggest)."""
    reason = j.get("attribution_reason")
    if j.get("ambiguous") and reason == "fenced-declaration":
        return ("a 'Side effects: mutating' line in it sits inside what the parser reads as a code fence, so it "
                "counts as mutating — move the example out of the journey, or close a stray ``` / ~~~ line above it")
    if j.get("ambiguous"):
        return ("a header with this id also sits inside a code fence — rename the example's id, or close a stray "
                "``` / ~~~ line above it, so the parser knows which block is the journey")
    if reason == "fenced-header":
        return ("its only header sits inside what the parser reads as a code fence — define the journey outside "
                "any fence, and check for a stray ``` / ~~~ line above it")
    return ("it is only mentioned inside other journeys, never defined at top level — give it its own "
            "'- **J-NN: <name>**' block")


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
    if not ledger.get("sidecar"):
        out[4:4] = ["# No --sidecar was given, so replay observations are not considered: pass",
                    "# --sidecar runs/goal-session-<sid>/state/journey-side-effects.json to include them."]
    n = 0
    for jid, j in ledger["journeys"].items():
        head = f"{jid} ({j['name']})" if j.get("name") else jid
        when = (f"iter-{j['observed_iter']}" if j.get("observed_iter") is not None
                else (j.get("observed_iter_name") or "an earlier iteration"))
        hint = j["step_hints"][0] if j["step_hints"] else None
        if j["declared"] == "none" and j["observed_mutating"]:
            sample = _first_mutating(j["requests"])
            out += [f"{head}: declared none, but the replay OBSERVED {sample} in {when} — the observation wins.",
                    f"  suggest:  - Side effects: mutating — <what {sample} creates or changes>",
                    f"  or, only if that endpoint computes without persisting: add '{sample}' to "
                    f"{READONLY_ENDPOINTS_REL} and keep 'none'", ""]
        elif j.get("unattributed") or j.get("ambiguous"):
            out += [f"{head}: {attribution_problem(j)}; it is read as {j['status']} (a stated 'none' is not "
                    "trusted, a stated 'mutating' is) until that is fixed.", ""]
        elif j["declaration_valid"] and j["declared"]:
            continue
        else:
            if not j["declaration_valid"]:
                out.append(f"{head}: INVALID declaration ({'; '.join(j['declaration_errors'])}) — read as "
                           f"{j['declared'] or 'unknown'}.")
            else:
                out.append(f"{head}: no 'Side effects:' line (status unknown).")
            if j["observed_mutating"]:
                out.append(f"  evidence: the replay observed {_first_mutating(j['requests'])} in {when}")
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


def _load_frozen(path, iter_n, fresh: dict) -> "dict | None":
    """The iteration's first complete preflight ledger, when it still applies:
    same iteration, same input fingerprint, and the fresh build is complete too."""
    try:
        snap = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError, RecursionError):
        return None
    if (not isinstance(snap, dict) or snap.get("complete") is not True or not fresh.get("complete")
            or snap.get("iter") != iter_n or not isinstance(snap.get("journeys"), dict)
            or snap.get("input_fingerprint") != fresh.get("input_fingerprint")):
        return None
    return snap


def cmd_side_effects(goal_path: str, opts: dict) -> int:
    try:
        text = Path(goal_path).read_text(encoding="utf-8", errors="replace")
    except (OSError, ValueError) as exc:
        print(f"[side-effects] goal file unreadable: {goal_path}: {exc}", file=sys.stderr)
        return 2
    out = opts.get("--out")
    sidecar = opts.get("--sidecar")
    if opts.get("--record-digest") and not out:
        print("[side-effects] --record-digest needs --out (change events are printed as tab-separated lines)",
              file=sys.stderr)
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
    ledger = build_side_effect_ledger(text, sidecar=sidecar, readonly_path=readonly, iter_n=iter_n,
                                      iter_name=opts.get("--iter-name"), step=opts.get("--step"),
                                      goal_file=goal_path, build_id=opts.get("--build-id"))
    if opts.get("--suggest"):
        sys.stdout.write(render_side_effect_suggestions(ledger, goal_path))
        return 0
    freeze = opts.get("--freeze")
    frozen_written = False
    fresh_ledger = ledger
    if freeze:
        # The preflight view of an iteration is decided ONCE: a resumed
        # iteration re-lints its spec against the evidence it was planned
        # against, never against its own replay's observations.
        snap = _load_frozen(freeze, iter_n, ledger)
        if snap is not None:
            snap.pop("record_error", None)
            snap.update({"build_id": ledger["build_id"], "built_at": ledger["built_at"],
                         "built_at_step": ledger["built_at_step"], "frozen": True,
                         "frozen_at": snap.get("frozen_at") or snap.get("built_at")})
            ledger = snap
    recording = bool(opts.get("--record-digest") and sidecar)
    # Recording always sees every journey and the CURRENT evidence (a conflict
    # this iteration's own replay found is reported now, frozen view or not);
    # the declarations are identical — the fingerprints matched.
    full_ledger = copy.deepcopy(fresh_ledger)
    prospective_before = {k: ledger.get(k) for k in
                          ("recorded_declaration_digest", "declaration_digest_prev", "declaration_digest_changed_iter")}
    if recording:
        if ledger["complete"]:
            # What the record below will store (it runs only after --out is written,
            # so a failed write can never move the digest without its events).
            if ledger.get("recorded_declaration_digest") != ledger["declaration_digest"]:
                ledger["declaration_digest_prev"] = ledger.get("recorded_declaration_digest")
                ledger["declaration_digest_changed_iter"] = iter_n
                ledger["recorded_declaration_digest"] = ledger["declaration_digest"]
        else:
            ledger["record_error"] = "declarations not recorded: the ledger is incomplete"
    wanted = [j for j in re.findall(r"J-\d+", opts.get("--journeys") or "")]
    if wanted:
        ledger["journeys"] = {j: r for j, r in ledger["journeys"].items() if j in wanted}
        ledger["summary"] = {s: [j for j in lst if j in wanted] for s, lst in ledger["summary"].items()}
        ledger["conflicts"] = [j for j in ledger["conflicts"] if j in wanted]
    ledger["declaration_digest_changed_this_iter"] = bool(
        iter_n is not None and ledger.get("declaration_digest_changed_iter") == iter_n
        and ledger.get("declaration_digest_prev"))
    for e in ledger["errors"]:
        print(f"[side-effects] INCOMPLETE: {e}", file=sys.stderr)
    if not out:
        print(json.dumps(ledger, sort_keys=True, indent=1))
        return 0 if ledger["complete"] else 3
    from demo_runner import _atomic_write_json  # noqa: PLC0415
    try:
        Path(out).parent.mkdir(parents=True, exist_ok=True)
        _atomic_write_json(out, ledger)
    except OSError as exc:
        print(f"[side-effects] could not write {out}: {exc} — nothing was recorded", file=sys.stderr)
        return 2
    if freeze and ledger["complete"] and not ledger.get("frozen"):
        try:
            _atomic_write_json(freeze, ledger)
            frozen_written = True
        except OSError as exc:
            print(f"[side-effects] could not keep the preflight view {freeze}: {exc}", file=sys.stderr)
    if recording and ledger["complete"]:
        try:
            events, rec_err = record_side_effect_declarations(sidecar, full_ledger, iter_n,
                                                              opts.get("--iter-name"))
        except Exception as exc:  # noqa: BLE001 — a bookkeeping bug must not unwrite a valid ledger
            events, rec_err = [], f"declarations not recorded (unexpected error: {exc})"
        if rec_err:
            # Nothing was recorded, so the ledger must not claim a recorded change.
            for key in ("recorded_declaration_digest", "declaration_digest_prev", "declaration_digest_changed_iter"):
                ledger[key] = prospective_before.get(key)
            ledger["declaration_digest_changed_this_iter"] = bool(
                iter_n is not None and ledger.get("declaration_digest_changed_iter") == iter_n
                and ledger.get("declaration_digest_prev"))
            ledger["record_error"] = rec_err
            print(f"[side-effects] {rec_err}", file=sys.stderr)
            try:
                _atomic_write_json(out, ledger)
                if frozen_written:
                    _atomic_write_json(freeze, ledger)
            except OSError:
                pass
        else:
            for name, payload in events:
                print(f"{name}\t{json.dumps(payload, sort_keys=True)}")
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
        valid_removed = re.sub(r"(?m)^  - (\*\*)?Side effects:(\*\*)? (none|mutating)\b.*\n", "", se_goal)
        assert _journey_hashes(se_goal) == _journey_hashes(valid_removed), \
            "a well-formed Side effects line must never change a journey spec_hash"
        all_removed = re.sub(r"(?m)^  - (\*\*)?Side effects:.*\n", "", se_goal)
        assert _journey_hashes(se_goal)["J-03"] != _journey_hashes(all_removed)["J-03"], \
            "a MALFORMED declaration-shaped line is journey text: removing it is drift"
        # edits hidden inside malformed lines are drift AND digest changes
        def _one(line: str) -> str:
            return ("## Must-have user journeys\n\n- **J-09: X**\n  - Steps:\n    1. click Run\n"
                    "  - Acceptance: header shows\n" + line + "\n\n## Anti-goals\n")
        from demo_runner import load_readonly_endpoints  # noqa: PLC0415
        ro_none = load_readonly_endpoints(None)
        for a, b in (("    side effect: the ledger gains exactly one row", "    side effect: the ledger gains two rows"),
                     ("  - Side effects: none (5 rows)", "  - Side effects: none (50 rows)"),
                     ("  - Side effects: none. badge OK", "  - Side effects: none. badge FAILED"),
                     ("  - Side effects: (tbd) — 5 runs", "  - Side effects: (tbd) — 9 runs"),
                     ("  - Side effects: mutating, named Alpha", "  - Side effects: mutating, named Beta"),
                     ("  Side effects: none — reads", "  Side effects: none — writes")):
            ga, gb = _one(a), _one(b)
            assert _journey_hashes(ga) != _journey_hashes(gb), ("malformed edit must be drift", a)
            assert declaration_digest(parse_side_effect_declarations(ga), ro_none) != \
                declaration_digest(parse_side_effect_declarations(gb), ro_none), ("malformed edit must move the digest", a)
        assert parse_side_effect_declarations(_one("  - Side effects: mutating, named Alpha"))["J-09"]["declared"] \
            == "mutating", "a malformed mutating still counts"
        assert parse_side_effect_declarations(_one("  Side effects: none"))["J-09"]["declared"] is None, \
            "a declaration that is not its own list item is invalid"
        fmt_a, fmt_b = _one("  - Side effects: none — reads only"), _one("  -   side effects:  **None**  –  reads   only")
        assert _journey_hashes(fmt_a) == _journey_hashes(fmt_b) and \
            declaration_digest(parse_side_effect_declarations(fmt_a), ro_none) == \
            declaration_digest(parse_side_effect_declarations(fmt_b), ro_none), "harmless formatting is neutral"
        # declarations belong to their innermost journey; a same-id note is not a second definition
        nested = ("## Must-have user journeys\n\n- **J-01: Parent**\n  - Steps:\n    1. click Run\n"
                  "  - **J-02: Child**\n    - Steps:\n      1. Visit `/r`\n    - Side effects: none — reads\n"
                  "- **J-03: Closed**\n  - Steps:\n    1. Visit `/c`\n  - **J-03 CLOSED — owner note**\n"
                  "    - detail\n  - Side effects: none — reads\n\n## Anti-goals\n")
        nd = parse_side_effect_declarations(nested)
        assert nd["J-01"]["declared"] is None and nd["J-02"]["declared"] == "none", nd["J-01"]
        assert nd["J-03"]["declared"] == "none" and nd["J-03"]["valid"], nd["J-03"]
        own = {j: o for j, _s, _e, o, _d in side_effect_journey_own_blocks(nested)}
        assert "Child" not in own["J-01"] and own["J-01"].count("\n") == nested.split("- **J-03")[0].count("\n") - 2
        assert [h["n"] for h in journey_step_hints(own["J-01"])] == [1]
        # the step heuristic: actions the step performs, not nouns or commands
        for text, words in (("Open Backtests; click Run", ["run"]), ("Press RUN TODAY", ["run"]),
                            ("then re-run the backfill", ["run"]), ("Land on the run detail", []),
                            ("Assert the run lands on READY", []), ("Run `pytest -q` and record the count", []),
                            ("POST /api/x with the body", ["post"]), ("Visit `/run-list`", []),
                            ("click `Save draft`", ["save"]), ("Post-condition: rows render", [])):
            assert sorted(step_action_words(text)) == words, (text, step_action_words(text))
        ro_path = d / "ro.txt"
        ro_path.write_text("POST /api/eval\n", encoding="utf-8")
        ro_a = load_readonly_endpoints(ro_path)
        flipped = se_goal.replace("mutating — launches a run", "none — launches a run")
        assert _journey_hashes(flipped) == _journey_hashes(se_goal)
        assert declaration_digest(parse_side_effect_declarations(flipped), ro_a) != \
            declaration_digest(dd, ro_a), "a mutating -> none flip must change the declaration digest"
        ro_path.write_text("POST /api/eval\nPOST /api/preview\n", encoding="utf-8")
        assert declaration_digest(dd, load_readonly_endpoints(ro_path)) != declaration_digest(dd, ro_a), \
            "editing read-only-endpoints.txt must change the declaration digest"
        # ledger: observation outranks none; unreadable observations never read as none
        sess = d / "runs" / "goal-session-t"
        (sess / "state").mkdir(parents=True)
        side = sess / "state" / "journey-side-effects.json"
        g1, g2 = "a" * 64, "b" * 64

        def _obs(n, t, golden, it):
            return {"run_id": f"r-{it}", "iter": it, "iter_name": f"t-iter-{it}", "complete": True,
                    "verdict": "PASS", "mutating_count": n, "auth_count": 0, "readonly_count": 0,
                    "observed_at": f"2026-09-17T00:00:{t:02d}.000000Z", "golden_sha256": golden,
                    "requests": [{"method": "POST", "path": "/api/runs", "class": "mutating", "count": n}] if n else [],
                    "truncated": False, "exceptions_applied": [], "auth_ignored": [], "classifier_version": 2,
                    "readonly_endpoints_sha256": None, "readonly_endpoints_error": None,
                    "ignore_paths": ["/login", "/logout", "/auth", "/session", "/token", "/csrf"]}

        def _record(it, obs):
            f = sess / f"iter-{it}" / "replay-side-effects.json"
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text(json.dumps({"run_id": obs["run_id"], "iter": it, "observed_at": obs["observed_at"],
                                     "journeys": {"J-01": obs}}), encoding="utf-8")

        _record(4, _obs(1, 4, g1, 4))
        led = build_side_effect_ledger(se_goal, sidecar=side, readonly_path=d / "absent.txt", env={})
        assert led["complete"], led["errors"]
        assert led["journeys"]["J-01"]["status"] == "mutating", "observation outranks a none declaration"
        assert led["run_records_pending"] and led["conflicts"] == ["J-01"], led["conflicts"]
        assert led["journeys"]["J-02"]["status"] == "mutating"
        assert led["journeys"]["J-03"]["status"] == "unknown" and led["journeys"]["J-04"]["status"] == "unknown"
        # a later clean replay of ANOTHER golden cannot clear it (sticky); the same golden can
        _record(5, _obs(0, 5, g2, 5))
        j1 = build_side_effect_ledger(se_goal, sidecar=side, readonly_path=d / "absent.txt", env={})["journeys"]["J-01"]
        assert j1["status"] == "mutating" and j1["observation_sticky"] and j1["observed_iter"] == 4, j1
        _record(6, _obs(0, 6, g1, 6))
        j1 = build_side_effect_ledger(se_goal, sidecar=side, readonly_path=d / "absent.txt", env={})["journeys"]["J-01"]
        assert j1["status"] == "none" and not j1["observed_mutating"], j1
        (sess / "iter-6" / "replay-side-effects.json").unlink()
        # recording repairs the sidecar from the run records, once
        rled = build_side_effect_ledger(se_goal, sidecar=side, readonly_path=d / "absent.txt", env={})
        evs, err = record_side_effect_declarations(side, rled, 7, "t-iter-7")
        assert err is None and ("side_effect_observations_repaired" in [e for e, _ in evs]), (err, evs)
        assert "side_effect_declaration_conflict" in [e for e, _ in evs], evs
        assert sorted(json.loads(side.read_text())["merged_runs"]) == ["r-4", "r-5"]
        evs2, _ = record_side_effect_declarations(side, rled, 8, "t-iter-8")
        assert not [e for e, _ in evs2 if e in ("side_effect_observations_repaired",
                                               "side_effect_declaration_conflict")], evs2
        # a corrupt sidecar: incomplete, the record evidence still counts, a
        # none with nothing recorded is UNKNOWN (never "none")
        side.write_text("{ corrupt", encoding="utf-8")
        cl = build_side_effect_ledger(se_goal, sidecar=side, readonly_path=d / "absent.txt", env={})
        assert not cl["complete"] and cl["journeys"]["J-01"]["status"] == "mutating", cl["journeys"]["J-01"]
        noted = se_goal.replace("- **J-04: Plain**", "- **J-04: Plain**\n  - Side effects: none — reads")
        cl4 = build_side_effect_ledger(noted, sidecar=side, readonly_path=d / "absent.txt", env={})["journeys"]["J-04"]
        assert cl4["status"] == "unknown" and cl4["status_source"] == "declared-unverified", cl4
        # moving it aside rebuilds every observation from the run records
        side.unlink()
        mv = build_side_effect_ledger(noted, sidecar=side, readonly_path=d / "absent.txt", env={})
        assert mv["complete"] and mv["journeys"]["J-01"]["status"] == "mutating" \
            and mv["journeys"]["J-04"]["status"] == "none", mv["journeys"]["J-01"]
        # a corrupt run record makes the ledger incomplete too
        (sess / "iter-9").mkdir()
        (sess / "iter-9" / "replay-side-effects.20260917T000000Z-1-1.json").write_text("{", encoding="utf-8")
        assert not build_side_effect_ledger(noted, sidecar=side, readonly_path=d / "absent.txt", env={})["complete"]
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
                  "--iter", "--iter-name", "--step", "--build-id", "--freeze")
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
