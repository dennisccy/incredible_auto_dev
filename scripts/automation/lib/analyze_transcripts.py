#!/usr/bin/env python3
"""analyze_transcripts.py — pump-side economics + subagent context composition (TOKEN-12).

Framework telemetry records what each SUBAGENT dispatch cost (`claude_usage`) but
nothing about the foreground pump's own turns, and nothing about WHAT fills a
subagent's context (which tool results, how many turns). This reads the Claude
Code session transcript(s) directly:

  <pump-session>.jsonl                      the pump's own turns
  <pump-session>/subagents/agent-<id>.jsonl every subagent it dispatched

Usage:
  analyze_transcripts.py <pump-session.jsonl> [--json]
  analyze_transcripts.py --compare <A.jsonl> <B.jsonl> [--json]
  analyze_transcripts.py --self-test

Pump side: usage-bearing turns (assistant messages carrying `usage`, deduped by
`message.id` — streaming snapshots repeat ids, keep each id's LAST row),
output / cache_read / cache_creation / input totals, per-tool counts with average
input and result bytes, Agent dispatches, **pump turns between consecutive Agent
calls** (the plumbing cost of one dispatch), resolved `message.model` per turn,
compaction/summary events.

Subagent side (agentId → agentType from `toolUseResult`): invocations, turns per
invocation, output / cache_read per invocation, tool-result bytes by tool with
image reads counted separately (PNG bytes are not tokens), and the five largest
tool results with the first 80 chars of the tool input that produced them.

Read-only. Unknown row shapes are skipped, never guessed. The numbers are the
recorded PRE/POST for TOKEN-11/13/15/16 and EXP-6 — see docs/goal-mode-telemetry.md.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
from collections import Counter, defaultdict

IMAGE_EXT = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp")
SUBAGENT_TYPES_OF_INTEREST = None  # None = every agentType seen


def _rows(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if isinstance(row, dict):
                yield row


def _blocks(message):
    content = (message or {}).get("content")
    return content if isinstance(content, list) else []


def _result_len(block):
    content = block.get("content", "")
    if isinstance(content, str):
        return len(content), False
    total, image = 0, False
    if isinstance(content, list):
        for part in content:
            if not isinstance(part, dict):
                continue
            if part.get("type") == "image":
                image = True
                src = part.get("source") or {}
                total += len(str(src.get("data", "")))
            else:
                total += len(json.dumps(part, ensure_ascii=False))
    return total, image


import datetime as _dt
import re as _re

STALL_GAP_SECONDS = 600.0
AMBIGUOUS_GAP_SECONDS = 120.0
_RULE_TAG = _re.compile(r"^guard-[\w-]+: \[(\w+)\]")


def _secs(ts):
    if not ts:
        return None
    for fmt, n in (("%Y-%m-%dT%H:%M:%S.%f", 23), ("%Y-%m-%dT%H:%M:%S", 19)):
        try:
            return _dt.datetime.strptime(ts[:n], fmt).timestamp()
        except ValueError:
            continue
    return None


def classify_result(block, row, gap, stall_gap=STALL_GAP_SECONDS):
    """Deterministic permission-economics classification (E3/E6). Returns (class, rule_id)."""
    kind = row.get("toolDenialKind")
    text = block.get("content") if isinstance(block.get("content"), str) else ""
    if kind == "permission-rule":
        m = _RULE_TAG.match(text)
        return ("hook_deny", m.group(1) if m else "?") if text.startswith("guard-") else ("settings_deny", None)
    if kind in ("automode-blocked", "automode-unavailable"):
        return ("automode_deny", None)
    if kind == "user-rejected":
        return ("user_deny", None)
    tur = row.get("toolUseResult")
    if isinstance(tur, dict) and (tur.get("timedOutAfterMs") or tur.get("backgroundTaskId") or tur.get("interrupted")):
        return ("ok_long", None)
    if gap is not None and gap >= stall_gap:
        return ("stall", None)
    if gap is not None and gap >= AMBIGUOUS_GAP_SECONDS:
        return ("ambiguous_gap", None)
    return ("ok", None)


def _collapse(inp):
    """Normalize a Bash tool_use input (JSON string) to its whitespace-collapsed command."""
    try:
        return " ".join(str(json.loads(inp).get("command", "")).split())
    except ValueError:
        return inp


def bash_sequence_metrics(bash_seq, bash_verdict):
    """Sequence-dependent Bash metrics from ISSUE order, after the whole transcript is parsed.
    Never from result-arrival order, which differs when one turn issues several calls or
    results land out of order."""
    out = {"identical_command_retries": 0, "same_rule_retries": 0, "retry_loops": 0}
    run_len = 0
    for i, (tid, cmd) in enumerate(bash_seq):
        cls, rule = bash_verdict.get(tid, ("ok", None))
        denied = cls.endswith("_deny")
        run_len = run_len + 1 if denied else 0
        if run_len == 3:
            out["retry_loops"] += 1
        if not denied:
            continue
        if cmd and any(c == cmd for _t, c in bash_seq[i + 1:i + 4]):
            out["identical_command_retries"] += 1
        if cls == "hook_deny" and i + 1 < len(bash_seq):
            ncls, nrule = bash_verdict.get(bash_seq[i + 1][0], ("ok", None))
            if ncls == "hook_deny" and nrule == rule:
                out["same_rule_retries"] += 1
    return out


def _merge_permissions(dst, src):
    """Sum every numeric field of a session `permissions` dict into an aggregate,
    merging `hook_denies` as a rule-id → count Counter."""
    for k, v in src.items():
        if k == "hook_denies":
            c = Counter(dst.get("hook_denies") or {})
            c.update(v)
            dst["hook_denies"] = dict(c)
        else:
            dst[k] = dst.get(k, 0) + v


def default_events_path(transcript_path):
    """<cache>/iad/hook-events/<project-slug>/<session-id>.jsonl for one transcript — one
    direct open, never a directory scan."""
    base = os.path.basename(transcript_path)
    sid = base[:-6] if base.endswith(".jsonl") else base
    slug = os.path.basename(os.path.dirname(os.path.abspath(transcript_path)))
    cache = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return os.path.join(cache, "iad", "hook-events", slug, sid + ".jsonl")


def load_events(events_path):
    """{event: [rows]} + malformed count from ONE session file; None when the file is absent."""
    if not events_path or not os.path.isfile(events_path):
        return None
    out = {"permission_request": [], "hygiene_deny": [], "hygiene_fail_open": [], "malformed": 0}
    with open(events_path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                ev = json.loads(line)
                out.setdefault(ev.get("event", "?"), []).append(ev)
            except (ValueError, AttributeError):
                out["malformed"] += 1
    return out


def _is_compaction(row):
    if row.get("type") == "summary" or row.get("isCompactSummary"):
        return True
    msg = row.get("message") or {}
    content = msg.get("content")
    text = content if isinstance(content, str) else ""
    return "This session is being continued from a previous conversation" in text


def analyze_session(path, stall_gap=STALL_GAP_SECONDS):
    """One transcript file (pump or subagent) → per-message usage + tool stats."""
    seen = {}            # message.id → last usage snapshot (+ model)
    order = []           # message ids in first-seen order
    uses = {}            # tool_use id → (name, input json, input len)
    tool_calls = Counter()
    tool_in_bytes = Counter()
    res_bytes = Counter()
    res_count = Counter()
    image_results = 0
    image_bytes = 0
    top = []             # (bytes, tool, input head)
    agent_ids = {}       # agentId → agentType
    agent_turn_marks = []  # index (in order) of the turn that issued each Agent call
    compactions = 0
    # ── permission economics (Task 8) ────────────────────────────────────────
    perm = {"hook_denies": Counter(), "settings_denies": 0, "automode_denies": 0, "user_denies": 0,
            "stalls": 0, "stall_seconds": 0.0, "ambiguous_gaps": 0,
            "post_denial_tool_turns": 0, "immediate_bash_retries": 0}
    use_ts, outcomes = {}, {}          # tool_use id → timestamp; tool_use id → (class, gap)
    bash_seq = []                      # (tool_use id, normalized command) in ISSUE order
    bash_verdict = {}                  # tool_use id → (class, rule) once its result is seen
    pending = []                       # tool names of denials awaiting their "next assistant row" check
    for row in _rows(path):
        if _is_compaction(row):
            compactions += 1
        tur = row.get("toolUseResult")
        if isinstance(tur, dict) and tur.get("agentId") and tur.get("agentType"):
            agent_ids[str(tur["agentId"])] = str(tur["agentType"])
        msg = row.get("message") or {}
        if row.get("type") == "assistant":
            # Permission economics: does THIS turn recover from the pending denial(s)?
            has_tool = any(isinstance(b, dict) and b.get("type") == "tool_use" for b in _blocks(msg))
            has_bash = any(isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "Bash"
                           for b in _blocks(msg))
            for entry in pending:
                perm["post_denial_tool_turns"] += has_tool
                if entry == "Bash":
                    perm["immediate_bash_retries"] += has_bash
            pending = []
            mid = msg.get("id")
            usage = msg.get("usage")
            if mid and isinstance(usage, dict):
                if mid not in seen:
                    order.append(mid)
                seen[mid] = {"usage": usage, "model": msg.get("model")}
            for b in _blocks(msg):
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    if b.get("id") in uses:      # repeated streaming snapshot of the same message
                        continue
                    name = str(b.get("name", "?"))
                    inp = json.dumps(b.get("input", {}), ensure_ascii=False)
                    uses[b.get("id")] = (name, inp)
                    tool_calls[name] += 1
                    tool_in_bytes[name] += len(inp)
                    use_ts[b["id"]] = row.get("timestamp")
                    if name == "Bash":
                        bash_seq.append((b["id"], _collapse(inp)))
                    if name == "Agent" and mid:
                        agent_turn_marks.append(len(order) - 1 if mid in seen else len(order))
        elif row.get("type") == "user":
            for b in _blocks(msg):
                if isinstance(b, dict) and b.get("type") == "tool_result":
                    name, inp = uses.get(b.get("tool_use_id"), ("?", ""))
                    t0, t1 = _secs(use_ts.get(b.get("tool_use_id"))), _secs(row.get("timestamp"))
                    gap = (t1 - t0) if (t0 is not None and t1 is not None) else None
                    cls, rule = classify_result(b, row, gap, stall_gap)
                    outcomes[b.get("tool_use_id")] = (cls, gap)
                    denied = cls.endswith("_deny")
                    if cls == "hook_deny":
                        perm["hook_denies"][rule] += 1
                    elif denied:
                        perm[cls.replace("deny", "denies")] += 1
                    elif cls == "stall":
                        perm["stalls"] += 1
                        perm["stall_seconds"] += gap
                    elif cls == "ambiguous_gap":
                        perm["ambiguous_gaps"] += 1
                    if name == "Bash":
                        bash_verdict[b.get("tool_use_id")] = (cls, rule)
                    if denied:
                        pending.append(name)
                    length, image = _result_len(b)
                    if not image and name == "Read":
                        try:
                            fp = str(json.loads(inp).get("file_path", "")).lower()
                            image = fp.endswith(IMAGE_EXT)
                        except ValueError:
                            pass
                    if image:
                        image_results += 1
                        image_bytes += length
                    else:
                        res_bytes[name] += length
                        res_count[name] += 1
                    top.append((length, name, inp[:80]))
    usage_tot = Counter()
    models = Counter()
    for mid in order:
        u = seen[mid]["usage"]
        for k in ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"):
            usage_tot[k] += int(u.get(k, 0) or 0)
        models[str(seen[mid].get("model") or "?")] += 1
    turns = len(order)
    dispatches = tool_calls.get("Agent", 0)
    # plumbing turns per dispatch: usage-bearing turns between consecutive Agent-issuing turns
    gaps = [b - a for a, b in zip(agent_turn_marks, agent_turn_marks[1:])]
    turns_per_dispatch = (sum(gaps) / len(gaps)) if gaps else (turns / dispatches if dispatches else 0.0)
    top.sort(key=lambda t: -t[0])
    perm.update(bash_sequence_metrics(bash_seq, bash_verdict))
    return {
        "path": path,
        "turns": turns,
        "usage": dict(usage_tot),
        "models": dict(models),
        "compactions": compactions,
        "tool_calls": dict(tool_calls),
        "tool_input_bytes": dict(tool_in_bytes),
        "result_bytes": dict(res_bytes),
        "result_count": dict(res_count),
        "image_results": image_results,
        "image_bytes": image_bytes,
        "top_results": [{"bytes": b, "tool": n, "input_head": h} for b, n, h in top[:5]],
        "agent_dispatches": dispatches,
        "turns_per_dispatch": round(turns_per_dispatch, 2),
        "agent_ids": agent_ids,
        "permissions": {**perm, "hook_denies": dict(perm["hook_denies"])},
        "outcomes": outcomes,
    }


def analyze_pump(path, events_path=None, stall_gap=STALL_GAP_SECONDS):
    pump = analyze_session(path, stall_gap=stall_gap)
    sub_dir = os.path.join(path[:-6] if path.endswith(".jsonl") else path, "subagents")
    per_type = {}
    for aid, atype in pump["agent_ids"].items():
        sp = os.path.join(sub_dir, f"agent-{aid}.jsonl")
        if not os.path.isfile(sp):
            continue
        s = analyze_session(sp, stall_gap=stall_gap)
        d = per_type.setdefault(atype, {"invocations": 0, "turns": 0, "output_tokens": 0,
                                        "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0,
                                        "result_bytes": Counter(), "result_count": Counter(),
                                        "tool_calls": Counter(), "image_results": 0, "image_bytes": 0,
                                        "top_results": [], "permissions": {}, "outcomes": {}})
        d["invocations"] += 1
        d["turns"] += s["turns"]
        d["output_tokens"] += s["usage"].get("output_tokens", 0)
        d["cache_read_input_tokens"] += s["usage"].get("cache_read_input_tokens", 0)
        d["cache_creation_input_tokens"] += s["usage"].get("cache_creation_input_tokens", 0)
        d["result_bytes"].update(s["result_bytes"])
        d["result_count"].update(s["result_count"])
        d["tool_calls"].update(s["tool_calls"])
        d["image_results"] += s["image_results"]
        d["image_bytes"] += s["image_bytes"]
        d["top_results"] = sorted(d["top_results"] + s["top_results"], key=lambda t: -t["bytes"])[:5]
        _merge_permissions(d["permissions"], s["permissions"])
        d["outcomes"].update(s["outcomes"])
    for d in per_type.values():
        n = d["invocations"] or 1
        d["turns_per_inv"] = round(d["turns"] / n, 1)
        d["output_per_inv"] = d["output_tokens"] // n
        d["cache_read_per_inv"] = d["cache_read_input_tokens"] // n
        d["result_bytes"] = dict(d["result_bytes"])
        d["result_count"] = dict(d["result_count"])
        d["tool_calls"] = dict(d["tool_calls"])
    del pump["agent_ids"]
    per_type_reports = list(per_type.values())
    all_outcomes = dict(pump["outcomes"])
    for d in per_type_reports:
        all_outcomes.update(d["outcomes"])
    ev = load_events(events_path or default_events_path(path))
    prompts = ev["permission_request"] if ev else []
    outc = Counter()
    for e in prompts:
        cls, gap = all_outcomes.get(e.get("tool_use_id"), ("unmatched", None))
        outc["user_deny" if cls == "user_deny" else "unmatched" if cls == "unmatched"
             else "allowed_after_wait" if (gap or 0) >= AMBIGUOUS_GAP_SECONDS else "allowed_fast"] += 1
    fo = Counter(e.get("reason", "?") for e in (ev["hygiene_fail_open"] if ev else []))
    pump["permissions"].update({"human_prompts": (len(prompts) if ev else None), "prompt_outcomes": dict(outc),
                                "fail_opens": dict(fo), "malformed_event_rows": (ev["malformed"] if ev else None)})
    for r in [pump] + per_type_reports:
        r.pop("outcomes", None)
    return {"pump": pump, "subagents": per_type}


def _perm_line(perm):
    return ("  permissions: human_prompts=%s stalls>600s=%d stall_seconds=%.0f hook_denies=%s "
            "identical_command_retries=%d retry_loops=%d same_rule_retries=%d "
            "post_denial_tool_turns=%d immediate_bash_retries=%d settings_denies=%d "
            "automode_denies=%d user_denies=%d fail_opens=%s malformed_event_rows=%s") % (
        perm.get("human_prompts"), perm.get("stalls", 0), perm.get("stall_seconds", 0.0),
        perm.get("hook_denies", {}), perm.get("identical_command_retries", 0), perm.get("retry_loops", 0),
        perm.get("same_rule_retries", 0), perm.get("post_denial_tool_turns", 0),
        perm.get("immediate_bash_retries", 0), perm.get("settings_denies", 0), perm.get("automode_denies", 0),
        perm.get("user_denies", 0), perm.get("fail_opens", {}), perm.get("malformed_event_rows"))


def render_text(rep):
    p = rep["pump"]
    u = p["usage"]
    out = []
    out.append(f"PUMP {p['path']}")
    out.append(f"  usage-bearing turns={p['turns']}  agent dispatches={p['agent_dispatches']}  "
               f"pump turns per dispatch={p['turns_per_dispatch']}  compactions={p['compactions']}")
    out.append(f"  output={u.get('output_tokens',0):,}  cache_read={u.get('cache_read_input_tokens',0):,}  "
               f"cache_create={u.get('cache_creation_input_tokens',0):,}  input={u.get('input_tokens',0):,}")
    if p["turns"]:
        out.append(f"  cache_read per turn={u.get('cache_read_input_tokens',0)//p['turns']:,}")
    out.append("  models: " + ", ".join(f"{m}×{n}" for m, n in sorted(p["models"].items(), key=lambda kv: -kv[1])))
    out.append("  tools (calls / avg input B / avg result B):")
    for name, n in sorted(p["tool_calls"].items(), key=lambda kv: -kv[1]):
        ai = p["tool_input_bytes"].get(name, 0) // max(1, n)
        rc = p["result_count"].get(name, 0)
        ar = p["result_bytes"].get(name, 0) // max(1, rc)
        out.append(f"    {name:34s} {n:5d}  {ai:7d}  {ar:8d}")
    out.append(_perm_line(p.get("permissions", {})))
    out.append("SUBAGENTS")
    for atype, d in sorted(rep["subagents"].items(), key=lambda kv: -kv[1]["cache_read_input_tokens"]):
        out.append(f"  {atype}: inv={d['invocations']} turns/inv={d['turns_per_inv']} "
                   f"output/inv={d['output_per_inv']:,} cache_read/inv={d['cache_read_per_inv']:,} "
                   f"image reads={d['image_results']} ({d['image_bytes']//1024} KB)")
        out.append(_perm_line(d.get("permissions", {})))
        tot = sum(d["result_bytes"].values()) or 1
        for name, b in sorted(d["result_bytes"].items(), key=lambda kv: -kv[1])[:6]:
            out.append(f"      {name:30s} calls/inv={d['tool_calls'].get(name,0)/d['invocations']:6.1f} "
                       f"result KB/inv={b/1024/d['invocations']:8.1f} share={100*b/tot:3.0f}%")
        for t in d["top_results"][:3]:
            out.append(f"      TOP {t['bytes']//1024:6d} KB {t['tool']:10s} {t['input_head']}")
    return "\n".join(out)


def compare(a, b):
    def pick(rep):
        p = rep["pump"]
        row = {"pump_turns": p["turns"], "pump_turns_per_dispatch": p["turns_per_dispatch"],
               "pump_cache_read": p["usage"].get("cache_read_input_tokens", 0),
               "pump_output": p["usage"].get("output_tokens", 0),
               "pump_cache_read_per_dispatch": (p["usage"].get("cache_read_input_tokens", 0) // p["agent_dispatches"]) if p["agent_dispatches"] else 0,
               "compactions": p["compactions"]}
        perm = p.get("permissions", {})
        row["permission.human_prompts"] = perm.get("human_prompts")
        row["permission.stalls"] = perm.get("stalls")
        row["permission.stall_seconds"] = perm.get("stall_seconds")
        row["permission.hook_denies_total"] = sum((perm.get("hook_denies") or {}).values())
        row["permission.identical_command_retries"] = perm.get("identical_command_retries")
        row["permission.retry_loops"] = perm.get("retry_loops")
        row["permission.same_rule_retries"] = perm.get("same_rule_retries")
        row["permission.post_denial_tool_turns"] = perm.get("post_denial_tool_turns")
        row["permission.immediate_bash_retries"] = perm.get("immediate_bash_retries")
        row["permission.automode_denies"] = perm.get("automode_denies")
        row["permission.user_denies"] = perm.get("user_denies")
        for atype, d in rep["subagents"].items():
            row[f"{atype}.turns_per_inv"] = d["turns_per_inv"]
            row[f"{atype}.cache_read_per_inv"] = d["cache_read_per_inv"]
            row[f"{atype}.output_per_inv"] = d["output_per_inv"]
        return row
    ra, rb = pick(a), pick(b)
    keys = sorted(set(ra) | set(rb))
    rows = []
    for k in keys:
        va, vb = ra.get(k), rb.get(k)
        delta = None
        if isinstance(va, (int, float)) and isinstance(vb, (int, float)) and va:
            delta = round(100.0 * (vb - va) / va, 1)
        rows.append({"metric": k, "a": va, "b": vb, "delta_pct": delta})
    return rows


def render_compare(rows):
    out = [f"{'metric':40s} {'A':>16s} {'B':>16s} {'Δ%':>8s}"]
    for r in rows:
        d = "" if r["delta_pct"] is None else f"{r['delta_pct']:+.1f}"
        out.append(f"{r['metric']:40s} {str(r['a']):>16s} {str(r['b']):>16s} {d:>8s}")
    return "\n".join(out)


# ── self-test on a synthetic fixture ─────────────────────────────────────────
def _write_fixture(root):
    sid = "sess1"
    pump = os.path.join(root, f"{sid}.jsonl")
    sub = os.path.join(root, sid, "subagents")
    os.makedirs(sub)
    U = lambda o, cr, cc=0, i=0: {"input_tokens": i, "output_tokens": o, "cache_read_input_tokens": cr, "cache_creation_input_tokens": cc}
    rows = [
        {"type": "assistant", "message": {"id": "m1", "model": "claude-opus-5", "usage": U(10, 1000),
         "content": [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "await"}}]}},
        {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "content": "req.5-a.ready"}]}},
        {"type": "assistant", "message": {"id": "m2", "model": "claude-opus-5", "usage": U(20, 2000),
         "content": [{"type": "tool_use", "id": "t2", "name": "Agent", "input": {"prompt": "x" * 100, "subagent_type": "developer"}}]}},
        {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t2", "content": "done"}]},
         "toolUseResult": {"agentId": "a1", "agentType": "developer"}},
        # streaming snapshot of m3 repeated: the LAST row must win
        {"type": "assistant", "message": {"id": "m3", "model": "claude-opus-5", "usage": U(5, 100),
         "content": [{"type": "tool_use", "id": "t3", "name": "Bash", "input": {"command": "finish"}}]}},
        {"type": "assistant", "message": {"id": "m3", "model": "claude-opus-5", "usage": U(30, 3000),
         "content": [{"type": "tool_use", "id": "t3", "name": "Bash", "input": {"command": "finish"}}]}},
        {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t3", "content": "ok"}]}},
        {"type": "summary", "summary": "compacted"},
        {"type": "assistant", "message": {"id": "m4", "model": "claude-opus-5", "usage": U(40, 4000),
         "content": [{"type": "tool_use", "id": "t4", "name": "Agent", "input": {"prompt": "y" * 50, "subagent_type": "reviewer"}}]}},
        {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t4", "content": "done2"}]},
         "toolUseResult": {"agentId": "a2", "agentType": "reviewer"}},
    ]
    with open(pump, "w") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")
    dev = [
        {"type": "assistant", "message": {"id": "d1", "model": "claude-sonnet-5", "usage": U(100, 50000),
         "content": [{"type": "tool_use", "id": "u1", "name": "Read", "input": {"file_path": "/x/shot.png"}}]}},
        {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "u1",
         "content": [{"type": "image", "source": {"data": "A" * 4000}}]}]}},
        {"type": "assistant", "message": {"id": "d2", "model": "claude-sonnet-5", "usage": U(200, 60000),
         "content": [{"type": "tool_use", "id": "u2", "name": "Bash", "input": {"command": "pytest -q"}}]}},
        {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "u2", "content": "." * 300}]}},
        {"type": "assistant", "message": {"id": "d3", "model": "claude-sonnet-5", "usage": U(300, 70000),
         "content": [{"type": "text", "text": "done"}]}},
    ]
    # ── permission economics rows (Task 8): appended after the token-accounting rows
    # above. Deliberately carry NO "usage" (so they don't perturb dev's turns/output/
    # cache_read token asserts above) — only tool_use/tool_result shape matters here.
    # One turn issues two Bash calls whose results return out of issue order; three
    # identical in-place edits are denied in a row (issue order, not result order); then
    # a clean command stalls 700s with no timeout/background/interrupted marker.
    A = lambda mid, ts, uses_: {"type": "assistant", "timestamp": ts, "message": {"id": mid, "role": "assistant",
        "content": [{"type": "tool_use", "id": tid, "name": "Bash", "input": {"command": cmd}} for tid, cmd in uses_]}}
    D = lambda tid, ts: {"type": "user", "timestamp": ts, "toolDenialKind": "permission-rule",
        "toolUseResult": "Error: guard-read-path-hygiene: [C1] denied",
        "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tid, "is_error": True,
                                                 "content": "guard-read-path-hygiene: [C1] denied"}]}}
    OK = lambda tid, ts: {"type": "user", "timestamp": ts, "toolUseResult": {"stdout": "", "stderr": "", "interrupted": False},
        "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tid, "is_error": False, "content": ""}]}}
    SED = "cd apps && sed -i s/a/b/ x.py"
    dev += [
        A("perm1", "2026-09-04T00:00:00.000Z", [("tu_x1", "cd apps && pytest -q"), ("tu_x2", SED)]),
        D("tu_x2", "2026-09-04T00:00:00.100Z"),          # results arrive out of issue order
        OK("tu_x1", "2026-09-04T00:00:02.000Z"),
        A("perm2", "2026-09-04T00:00:03.000Z", [("tu_x3", "cd apps &&  sed -i s/a/b/ x.py")]),  # same cmd, extra space
        D("tu_x3", "2026-09-04T00:00:03.100Z"),
        A("perm3", "2026-09-04T00:00:05.000Z", [("tu_x4", SED)]),
        D("tu_x4", "2026-09-04T00:00:05.100Z"),
        A("perm4", "2026-09-04T00:00:06.000Z", [("tu_stall", "cd apps && install -m 755 a b")]),
        OK("tu_stall", "2026-09-04T00:11:46.000Z"),      # 700 s, no marker → approval stall
    ]
    with open(os.path.join(sub, "agent-a1.jsonl"), "w") as fh:
        for r in dev:
            fh.write(json.dumps(r) + "\n")
    # reviewer transcript deliberately absent → skipped, never guessed
    # Events file (Task 7 recorder output shape): one permission_request for the stall's
    # tool_use_id, plus one malformed line — read by analyze_pump via events_path=.
    with open(os.path.join(root, "events.jsonl"), "w") as fh:
        fh.write(json.dumps({"ts": "2026-09-04T00:11:46Z", "event": "permission_request",
                             "hook": "permission-request-log", "session_id": sid, "agent_id": "a1",
                             "agent_type": "developer", "tool_use_id": "tu_stall", "tool_name": "Bash",
                             "permission_mode": "auto", "suggestion_count": 0, "suggestion_types": [],
                             "suggestions_sha": ""}) + "\n")
        fh.write("{not json\n")
    return pump


def _self_test():
    with tempfile.TemporaryDirectory() as root:
        pump = _write_fixture(root)
        ev = os.path.join(root, "events.jsonl")
        rep = analyze_pump(pump, events_path=ev)
        p = rep["pump"]
        assert p["turns"] == 4, p["turns"]                              # m3 counted once
        assert p["usage"]["output_tokens"] == 10 + 20 + 30 + 40, p["usage"]
        assert p["usage"]["cache_read_input_tokens"] == 1000 + 2000 + 3000 + 4000
        assert p["agent_dispatches"] == 2
        assert p["turns_per_dispatch"] == 2.0, p["turns_per_dispatch"]  # m2 → m4 spans 2 turns
        assert p["compactions"] == 1
        assert p["tool_calls"] == {"Bash": 2, "Agent": 2}, p["tool_calls"]
        assert p["models"] == {"claude-opus-5": 4}
        assert p["tool_input_bytes"]["Agent"] > 150
        dev = rep["subagents"]["developer"]
        assert dev["invocations"] == 1 and dev["turns"] == 3
        assert dev["output_per_inv"] == 600 and dev["cache_read_per_inv"] == 180000
        assert dev["image_results"] == 1 and dev["image_bytes"] == 4000, (dev["image_results"], dev["image_bytes"])
        assert dev["result_bytes"] == {"Bash": 408}, dev["result_bytes"]   # image bytes kept apart; +3×36B denial text
        assert dev["top_results"][0]["tool"] == "Read" and dev["top_results"][0]["bytes"] == 4000
        assert "reviewer" not in rep["subagents"]                         # missing transcript skipped
        # ── permission economics (Task 8): issue-order Bash retry/stall/prompt metrics ──
        perm = dev["permissions"]
        assert perm["hook_denies"] == {"C1": 3}, perm
        assert perm["post_denial_tool_turns"] == 3 and perm["immediate_bash_retries"] == 3, perm
        assert perm["identical_command_retries"] == 2 and perm["same_rule_retries"] == 2, perm
        assert perm["retry_loops"] == 1, perm          # issue order: ok, deny, deny, deny; result order would say 0
        assert perm["stalls"] == 1 and perm["stall_seconds"] == 700.0, perm
        pp = p["permissions"]
        assert pp["human_prompts"] == 1 and pp["prompt_outcomes"] == {"allowed_after_wait": 1}, pp
        assert pp["malformed_event_rows"] == 1, pp
        rows = compare(rep, rep)
        assert all(r["delta_pct"] in (0.0, None) for r in rows), rows
        assert any(r["metric"] == "permission.retry_loops" for r in rows)
        txt = render_text(rep)
        assert "pump turns per dispatch=2.0" in txt and "developer: inv=1" in txt
        assert "permissions: human_prompts=1" in txt and "stalls>600s=1" in txt and "retry_loops=1" in txt
        json.dumps(rep)  # serialisable
    print("analyze_transcripts self-test: OK")
    return 0


def _extract_flag(argv, flag):
    """Pull `--flag value` out of argv (anywhere) and return (value_or_None, remaining_argv)."""
    argv = list(argv)
    if flag in argv:
        i = argv.index(flag)
        val = argv[i + 1] if i + 1 < len(argv) else None
        del argv[i:i + 2]
        return val, argv
    return None, argv


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if argv[0] == "--self-test":
        return _self_test()
    events_path, argv = _extract_flag(argv, "--events")
    stall_gap_s, argv = _extract_flag(argv, "--stall-gap")
    stall_gap = float(stall_gap_s) if stall_gap_s is not None else STALL_GAP_SECONDS
    as_json = "--json" in argv
    args = [a for a in argv if a != "--json"]
    if args[0] == "--compare":
        if len(args) != 3:
            print("usage: --compare <A.jsonl> <B.jsonl>", file=sys.stderr)
            return 2
        rows = compare(analyze_pump(args[1], events_path=events_path, stall_gap=stall_gap),
                        analyze_pump(args[2], events_path=events_path, stall_gap=stall_gap))
        print(json.dumps(rows, indent=1) if as_json else render_compare(rows))
        return 0
    rep = analyze_pump(args[0], events_path=events_path, stall_gap=stall_gap)
    print(json.dumps(rep, indent=1) if as_json else render_text(rep))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
