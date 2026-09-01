#!/usr/bin/env python3
"""pump_finish.py — complete one interactive dispatch from the pump's own transcript (TOKEN-11a).

Called by goal-await-dispatch.sh --finish <req.ready>=<agent>=<rc>. Instead of the
pump spending three tool turns per dispatch (Write out, Bash usage extraction,
Write res) and re-emitting the subagent's final message as output tokens, this
reads the pump session's Claude Code transcript:

  $HOME/.claude/projects/<slug>/$CLAUDE_CODE_SESSION_ID.jsonl        (the pump)
  <that path minus .jsonl>/subagents/agent-<agentId>.jsonl            (the subagent)

and writes, in this order: `out` (the subagent's final assistant text, or a stub
line when the lookup fails), `usage_path` (ONLY when extraction fully succeeded —
never estimated, never guessed: the engine treats absence as "unknown"), then
`.res` LAST (the completion signal the engine waits for). The exit code is 0 as
long as `.res` was written; the caller writes `.res` itself otherwise.

Attribution: the pump transcript's tool_result rows carry
`toolUseResult.{agentId, agentType, resolvedModel, totalDurationMs, prompt}`.
The newest not-yet-consumed row of the requested agentType is used; when the
request's prompt is available the candidate whose `prompt` starts with the same
first 120 characters is preferred (two concurrent dispatches of one agent type).
Consumed agentIds are remembered in `<dispatch-dir>/.finished-agents`.

Schema probe: when the transcript exists but no row carries the expected
attribution fields at all, that is logged as possible schema drift — and the
dispatch still completes with a stub `out` and no usage (fail closed).
"""
from __future__ import annotations

import glob
import json
import os
import sys

USAGE_KEYS = ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")


def _log(msg):
    print(f"[finish] {msg}", file=sys.stderr)


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


def resolve_pump_transcript(explicit=None):
    if explicit:
        return explicit if os.path.isfile(explicit) else None
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    if not sid:
        return None
    home = os.environ.get("HOME", os.path.expanduser("~"))
    cands = glob.glob(os.path.join(home, ".claude", "projects", "*", f"{sid}.jsonl"))
    if not cands:
        return None
    cands.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return cands[0]


def find_candidate(pump_path, agent, prompt_head, consumed):
    """Newest not-yet-consumed toolUseResult row for this agentType (prompt-matched first)."""
    rows = []
    any_attr = False
    for row in _rows(pump_path):
        tur = row.get("toolUseResult")
        if not isinstance(tur, dict):
            continue
        if tur.get("agentType"):
            any_attr = True
        if str(tur.get("agentType", "")) != agent or not tur.get("agentId"):
            continue
        if str(tur["agentId"]) in consumed:
            continue
        rows.append(tur)
    if not rows:
        return None, ("no attribution rows at all — schema drift?" if not any_attr else f"no unconsumed dispatch of agentType {agent!r}")
    if prompt_head:
        matched = [r for r in rows if str(r.get("prompt", "")).startswith(prompt_head)]
        if matched:
            return matched[-1], ""
    return rows[-1], ""


def extract_subagent(sub_path):
    """(final_text, usage_sidecar) from a subagent transcript; usage deduped by message.id."""
    seen = {}
    order = []
    last_text_id = None
    for row in _rows(sub_path):
        if row.get("type") != "assistant":
            continue
        msg = row.get("message") or {}
        mid = msg.get("id")
        if not mid:
            continue
        if mid not in seen:
            order.append(mid)
        seen[mid] = msg
    if not order:
        return None, None
    totals = {k: 0 for k in USAGE_KEYS}
    n_usage = 0
    for mid in order:
        u = seen[mid].get("usage")
        if isinstance(u, dict):
            n_usage += 1
            for k in USAGE_KEYS:
                totals[k] += int(u.get(k, 0) or 0)
    final_text = ""
    for mid in reversed(order):
        parts = [b.get("text", "") for b in (seen[mid].get("content") or []) if isinstance(b, dict) and b.get("type") == "text"]
        text = "\n".join(t for t in parts if t).strip()
        if text:
            final_text = text
            break
    usage = None
    if n_usage:
        usage = {"num_turns": len(order), "usage": totals}
    return final_text, usage


def finish(request_path, agent, rc, transcript=None):
    with open(request_path, encoding="utf-8") as fh:
        req = json.load(fh)
    base = request_path[:-len(".ready")] if request_path.endswith(".ready") else request_path
    out_path = req.get("out") or f"{base}.out"
    usage_path = req.get("usage_path") or f"{base}.usage"
    res_path = req.get("res_path") or f"{base}.res"
    dispatch_dir = os.path.dirname(os.path.abspath(request_path))
    consumed_file = os.path.join(dispatch_dir, ".finished-agents")
    consumed = set()
    if os.path.isfile(consumed_file):
        with open(consumed_file, encoding="utf-8") as fh:
            consumed = {l.strip() for l in fh if l.strip()}

    final_text, sidecar, reason = None, None, ""
    try:
        pump = resolve_pump_transcript(transcript)
        if not pump:
            reason = "pump transcript not found (CLAUDE_CODE_SESSION_ID unset or no matching ~/.claude/projects/*/<sid>.jsonl)"
        else:
            cand, reason = find_candidate(pump, agent, str(req.get("prompt", ""))[:120], consumed)
            if cand:
                sub = os.path.join(pump[:-len(".jsonl")], "subagents", f"agent-{cand['agentId']}.jsonl")
                if not os.path.isfile(sub):
                    reason = f"subagent transcript missing: {sub}"
                else:
                    final_text, sidecar = extract_subagent(sub)
                    if sidecar is None:
                        reason = "subagent transcript carries no usage rows"
                    else:
                        sidecar["model"] = cand.get("resolvedModel")
                        sidecar["duration_ms"] = int(cand.get("totalDurationMs") or 0)
                        with open(consumed_file, "a", encoding="utf-8") as fh:
                            fh.write(f"{cand['agentId']}\n")
    except Exception as exc:  # fail closed: stub out, no usage
        final_text, sidecar, reason = None, None, f"{type(exc).__name__}: {exc}"

    # 1. out — always
    text = final_text if final_text else f"[interactive] subagent final message unavailable (agent={agent}; transcript lookup failed: {reason or 'empty final message'})"
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(text if text.endswith("\n") else text + "\n")
    # 2. usage — only when extraction fully succeeded
    if sidecar is not None:
        tmp = usage_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(sidecar, fh)
        os.replace(tmp, usage_path)
    # 3. res — LAST
    with open(res_path, "w", encoding="utf-8") as fh:
        fh.write(f"{rc}\n")
    if sidecar is not None:
        _log(f"{agent} ok: turns={sidecar['num_turns']} model={sidecar.get('model')} → {os.path.basename(res_path)}")
    else:
        _log(f"{agent}: stub out, no usage — {reason}")
    return 0


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    opts = {}
    i = 0
    while i < len(argv):
        if argv[i].startswith("--") and i + 1 < len(argv):
            opts[argv[i][2:]] = argv[i + 1]
            i += 2
        else:
            i += 1
    req, agent = opts.get("request"), opts.get("agent")
    if not req or not agent:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        rc = int(opts.get("rc", "0"))
    except ValueError:
        rc = 1
    try:
        return finish(req, agent, rc, opts.get("transcript"))
    except Exception as exc:
        _log(f"fatal: {type(exc).__name__}: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
