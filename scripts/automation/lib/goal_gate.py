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
    python3 goal_gate.py self-test
"""
from __future__ import annotations

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
# A table cell whose entire content is FAIL (avoids matching prose that
# merely contains the word).
_FAIL_CELL_RE = re.compile(r"\|\s*FAIL\s*\|")


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
    return 1 if _FAIL_CELL_RE.search(text) else 0


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
    formatting-only edits to goal.md do not read as spec changes."""
    lines = [ln.rstrip() for ln in block.replace("\r\n", "\n").replace("\r", "\n").split("\n")]
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
        assert cmd_coherence(str(d / "nope.md"), True) == 2

        res_ok = d / "r1.md"; res_ok.write_text("| T1 | n | ui | P1 | e | a | PASS | x.png |\n", encoding="utf-8")
        res_bad = d / "r2.md"; res_bad.write_text(
            "| T1 | n | ui | P1 | e | a | PASS | x.png |\n| T2 | n | ui | P1 | e | a | FAIL | y.png |\n",
            encoding="utf-8")
        res_prose = d / "r3.md"; res_prose.write_text("| T1 | expect no FAILURE here | PASS |\n", encoding="utf-8")
        assert cmd_results(str(res_ok)) == 0
        assert cmd_results(str(res_bad)) == 1
        assert cmd_results(str(res_prose)) == 0, "FAIL must match a whole cell only"

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
    if cmd == "self-test":
        return _self_test()
    print(f"unknown command: {cmd}", file=sys.stderr)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
