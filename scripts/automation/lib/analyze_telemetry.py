"""
Aggregate token / cost telemetry from one or more telemetry.jsonl files.

Reads the JSONL events written by lib/telemetry.sh and prints a per-agent /
per-session summary of:
  - Claude invocations (count)
  - Input tokens, output tokens, cache read/create tokens
  - total_cost_usd (when reported by the API)
  - Cache hit ratio (cache_read / (input + cache_read))

Usage:
    python3 analyze_telemetry.py <path>...                # one or more JSONL files
    python3 analyze_telemetry.py --json <path>...         # machine-readable output
    python3 analyze_telemetry.py --self-test              # built-in fixture roundtrip

Maps to OpenTelemetry GenAI semantic conventions in the JSON output:
  gen_ai.usage.input_tokens, output_tokens, cache_read_input_tokens,
  cache_creation_input_tokens, total_cost_usd.

Designed to be run after a goal-mode session ends (or any time during it):
    python3 analyze_telemetry.py runs/goal-session-<sid>/telemetry.jsonl
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class UsageRow:
    invocations: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_input_tokens: int = 0
    cache_creation_input_tokens: int = 0
    total_cost_usd: float = 0.0
    duration_ms: int = 0
    duration_api_ms: int = 0
    num_turns: int = 0
    errors: int = 0

    def add(self, usage: dict[str, Any], event: dict[str, Any]) -> None:
        self.invocations += 1
        self.input_tokens += int(usage.get("input_tokens", 0) or 0)
        self.output_tokens += int(usage.get("output_tokens", 0) or 0)
        self.cache_read_input_tokens += int(
            usage.get("cache_read_input_tokens", 0) or 0
        )
        self.cache_creation_input_tokens += int(
            usage.get("cache_creation_input_tokens", 0) or 0
        )
        cost = event.get("total_cost_usd")
        if isinstance(cost, (int, float)):
            self.total_cost_usd += float(cost)
        self.duration_ms += int(event.get("duration_ms") or 0)
        self.duration_api_ms += int(event.get("duration_api_ms") or 0)
        self.num_turns += int(event.get("num_turns") or 0)
        if event.get("is_error"):
            self.errors += 1

    def cache_hit_ratio(self) -> float:
        denom = self.input_tokens + self.cache_read_input_tokens
        if denom <= 0:
            return 0.0
        return self.cache_read_input_tokens / denom

    def to_dict(self) -> dict[str, Any]:
        return {
            "invocations": self.invocations,
            "errors": self.errors,
            "gen_ai.usage.input_tokens": self.input_tokens,
            "gen_ai.usage.output_tokens": self.output_tokens,
            "gen_ai.usage.cache_read_input_tokens": self.cache_read_input_tokens,
            "gen_ai.usage.cache_creation_input_tokens": self.cache_creation_input_tokens,
            "gen_ai.usage.total_cost_usd": round(self.total_cost_usd, 6),
            "duration_ms": self.duration_ms,
            "duration_api_ms": self.duration_api_ms,
            "num_turns": self.num_turns,
            "cache_hit_ratio": round(self.cache_hit_ratio(), 4),
        }


@dataclass
class SessionSummary:
    session_id: str
    paths: list[str] = field(default_factory=list)
    total: UsageRow = field(default_factory=UsageRow)
    by_agent: dict[str, UsageRow] = field(default_factory=lambda: defaultdict(UsageRow))
    by_model: dict[str, UsageRow] = field(default_factory=lambda: defaultdict(UsageRow))


def _iter_lines(path: str):
    with open(path, encoding="utf-8") as f:
        for raw in f:
            stripped = raw.strip()
            if not stripped:
                continue
            try:
                yield json.loads(stripped)
            except json.JSONDecodeError:
                # tolerate partial / corrupt last line of an in-progress run
                continue


def aggregate(paths: list[str]) -> dict[str, SessionSummary]:
    """Aggregate `claude_usage` events from telemetry.jsonl files."""
    sessions: dict[str, SessionSummary] = {}
    for path in paths:
        if not os.path.isfile(path):
            print(f"[analyze-telemetry] skip: {path} not found", file=sys.stderr)
            continue
        for event in _iter_lines(path):
            if event.get("event") != "claude_usage":
                continue
            sid = event.get("session_id") or "unknown"
            usage = event.get("usage") or {}
            agent = event.get("agent") or "unattributed"
            model = event.get("model") or "unknown-model"
            summary = sessions.setdefault(sid, SessionSummary(session_id=sid))
            if path not in summary.paths:
                summary.paths.append(path)
            summary.total.add(usage, event)
            summary.by_agent[agent].add(usage, event)
            summary.by_model[model].add(usage, event)
    return sessions


def aggregate_traces(paths: list[str]) -> dict[str, SessionSummary]:
    """Aggregate per-call usage from trace.jsonl files (written by quota-retry).

    Trace records are flatter than telemetry events: usage fields live at the
    top level via the sidecar spread. We treat every trace entry with a
    non-empty `usage` block as one invocation.
    """
    sessions: dict[str, SessionSummary] = {}
    for path in paths:
        if not os.path.isfile(path):
            print(f"[analyze-telemetry] skip: {path} not found", file=sys.stderr)
            continue
        for event in _iter_lines(path):
            usage = event.get("usage") or {}
            if not usage:
                continue
            # Trace records carry session_id from the sidecar (if telemetry was
            # on); fall back to the trace dir name.
            sid = event.get("session_id") or Path(path).parent.name or "unknown"
            agent = event.get("agent") or "unattributed"
            model = event.get("model") or "unknown-model"
            summary = sessions.setdefault(sid, SessionSummary(session_id=sid))
            if path not in summary.paths:
                summary.paths.append(path)
            summary.total.add(usage, event)
            summary.by_agent[agent].add(usage, event)
            summary.by_model[model].add(usage, event)
    return sessions


def render_text(sessions: dict[str, SessionSummary]) -> str:
    if not sessions:
        return "No claude_usage events found.\n"
    out: list[str] = []
    grand_total = UsageRow()
    for sid, summary in sessions.items():
        out.append(f"== Session: {sid}")
        out.append(f"   sources: {', '.join(summary.paths)}")
        out.append("")
        out.append(_format_row("TOTAL", summary.total))
        out.append("")
        out.append("   By agent:")
        for agent, row in sorted(summary.by_agent.items()):
            out.append("   " + _format_row(agent, row, indent="     "))
        out.append("")
        if summary.by_model:
            out.append("   By model:")
            for model, row in sorted(summary.by_model.items()):
                out.append("   " + _format_row(model, row, indent="     "))
            out.append("")
        # accumulate grand total
        gt = summary.total
        grand_total.invocations += gt.invocations
        grand_total.input_tokens += gt.input_tokens
        grand_total.output_tokens += gt.output_tokens
        grand_total.cache_read_input_tokens += gt.cache_read_input_tokens
        grand_total.cache_creation_input_tokens += gt.cache_creation_input_tokens
        grand_total.total_cost_usd += gt.total_cost_usd
        grand_total.duration_ms += gt.duration_ms
        grand_total.duration_api_ms += gt.duration_api_ms
        grand_total.num_turns += gt.num_turns
        grand_total.errors += gt.errors
    if len(sessions) > 1:
        out.append("== Grand total across sessions")
        out.append(_format_row("ALL", grand_total))
        out.append("")
    return "\n".join(out)


def _format_row(label: str, row: UsageRow, indent: str = "   ") -> str:
    cost = f"${row.total_cost_usd:.4f}" if row.total_cost_usd else "$0.0000"
    cache_pct = f"{row.cache_hit_ratio() * 100:.1f}%"
    return (
        f"{indent}{label:<24s} "
        f"calls={row.invocations:<3d} "
        f"in={row.input_tokens:<8d} "
        f"out={row.output_tokens:<8d} "
        f"cache_read={row.cache_read_input_tokens:<8d} "
        f"cache_create={row.cache_creation_input_tokens:<6d} "
        f"hit={cache_pct:>5s} "
        f"cost={cost} "
        f"errors={row.errors}"
    )


def render_json(sessions: dict[str, SessionSummary]) -> str:
    out: dict[str, Any] = {}
    for sid, summary in sessions.items():
        out[sid] = {
            "sources": summary.paths,
            "total": summary.total.to_dict(),
            "by_agent": {a: r.to_dict() for a, r in summary.by_agent.items()},
            "by_model": {m: r.to_dict() for m, r in summary.by_model.items()},
        }
    return json.dumps(out, indent=2, default=str)


# ── wall-time / per-iteration breakdown (--wall) ─────────────────────────────
#
# Where do the ~2 hours of a goal-mode iteration actually go? This mode walks
# the event stream in file order (telemetry.jsonl is append-only, so file order
# is chronological), opens an iteration record at each `iter_start`, attributes
# agent_invocation_end / step_skipped / dispatch_wait / quota_pause_end events
# to the open iteration, and closes it at `iter_end`. Tolerates ragged real
# data (unmatched starts from crashed attempts stay marked incomplete).


def _parse_ts(ts: Any) -> float | None:
    if not isinstance(ts, str) or not ts:
        return None
    try:
        import datetime as _dt

        return _dt.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def _new_iter_record(iter_name: str, ts: float | None) -> dict[str, Any]:
    return {
        "iter_name": iter_name,
        "start_ts": ts,
        "end_ts": None,
        "wall_seconds": None,
        "verdict": None,
        "depth": None,
        "complete": False,
        "agents": {},          # name → {seconds, calls, retries, failures}
        "skipped_steps": [],
        "pump_wait_seconds": 0,
        "quota_sleep_seconds": 0,
        "review_verdicts": [], # [{verdict, attempt}]
        "knob_active": False,  # iter_config event seen (experiment running)
        "journey_deltas": {},
    }


def build_wall_report(paths: list[str]) -> dict[str, dict[str, Any]]:
    sessions: dict[str, dict[str, Any]] = {}

    def _sess(sid: str) -> dict[str, Any]:
        return sessions.setdefault(sid, {
            "iterations": [], "open": None, "halts": [],
            "paused_seconds": 0, "last_halt_ts": None,
        })

    for path in paths:
        if not os.path.isfile(path):
            print(f"[analyze-telemetry] skip: {path} not found", file=sys.stderr)
            continue
        for event in _iter_lines(path):
            kind = event.get("event")
            sid = event.get("session_id") or "unknown"
            s = _sess(sid)
            ts = _parse_ts(event.get("ts"))
            cur = s["open"]
            if kind == "iter_start":
                if cur is not None:
                    s["iterations"].append(cur)  # ragged: prior attempt never ended
                s["open"] = _new_iter_record(event.get("iter_name") or "?", ts)
            elif kind == "iter_dispatch" and cur is not None:
                d = event.get("depth")
                if d:
                    cur["depth"] = d
            elif kind == "agent_invocation_end" and cur is not None:
                a = event.get("agent") or "unattributed"
                row = cur["agents"].setdefault(
                    a, {"seconds": 0, "calls": 0, "retries": 0, "failures": 0})
                row["seconds"] += int(event.get("duration_seconds") or 0)
                row["calls"] += 1
                row["retries"] += int(event.get("retries") or 0)
                if int(event.get("exit_status") or 0) != 0:
                    row["failures"] += 1
            elif kind == "step_skipped" and cur is not None:
                cur["skipped_steps"].append(event.get("step") or "?")
            elif kind == "dispatch_wait" and cur is not None:
                cur["pump_wait_seconds"] += int(event.get("wait_seconds") or 0)
            elif kind == "quota_pause_end" and cur is not None:
                cur["quota_sleep_seconds"] += int(event.get("sleep_seconds") or 0)
            elif kind == "review_verdict" and cur is not None:
                cur["review_verdicts"].append({
                    "verdict": event.get("verdict") or "?",
                    "attempt": int(event.get("attempt") or 0)})
            elif kind == "iter_config" and cur is not None:
                cur["knob_active"] = True
            elif kind == "iter_end":
                if cur is not None:
                    cur["end_ts"] = ts
                    cur["verdict"] = event.get("verdict")
                    nd = event.get("journey_deltas")
                    if isinstance(nd, dict):
                        cur["journey_deltas"] = nd
                    if cur["start_ts"] is not None and ts is not None:
                        cur["wall_seconds"] = int(ts - cur["start_ts"])
                    cur["complete"] = True
                    s["iterations"].append(cur)
                    s["open"] = None
            elif kind == "halt":
                s["halts"].append(event.get("reason") or "?")
                if event.get("reason") == "AWAITING_PUMP":
                    s["last_halt_ts"] = ts
            elif kind == "session_start":
                if s["last_halt_ts"] is not None and ts is not None:
                    s["paused_seconds"] += max(0, int(ts - s["last_halt_ts"]))
                    s["last_halt_ts"] = None

    for s in sessions.values():
        if s["open"] is not None:
            s["iterations"].append(s["open"])
            s["open"] = None
    return sessions


def _iter_index(iter_name: str) -> int | None:
    tail = iter_name.rsplit("-", 1)[-1]
    return int(tail) if tail.isdigit() else None


def _fmt_m(seconds: Any) -> str:
    if seconds is None:
        return "?"
    return f"{seconds / 60:.1f}m"


def render_wall_text(report: dict[str, dict[str, Any]],
                     iter_filter: int | None = None) -> str:
    if not report:
        return "No iteration events found.\n"
    out: list[str] = []
    for sid, s in report.items():
        iters = s["iterations"]
        if iter_filter is not None:
            iters = [i for i in iters if _iter_index(i["iter_name"]) == iter_filter]
        out.append(f"== Wall-time report: session {sid}")
        for rec in iters:
            wall = rec["wall_seconds"]
            flag = "" if rec["complete"] else "  (incomplete/interrupted attempt)"
            out.append(
                f"  {rec['iter_name']}  depth={rec['depth'] or '?'}  "
                f"verdict={rec['verdict'] or '?'}  wall={_fmt_m(wall)}{flag}")
            agent_total = 0
            for a, row in sorted(rec["agents"].items(),
                                 key=lambda kv: -kv[1]["seconds"]):
                agent_total += row["seconds"]
                extra = ""
                if row["failures"]:
                    extra += f"  failures={row['failures']}"
                if row["retries"]:
                    extra += f"  retries={row['retries']}"
                out.append(f"      {a:<24s} {_fmt_m(row['seconds']):>8s}  "
                           f"calls={row['calls']}{extra}")
            if rec["skipped_steps"]:
                out.append(f"      (resume-skipped: {', '.join(rec['skipped_steps'])})")
            if rec["pump_wait_seconds"]:
                out.append(f"      pump-wait              {_fmt_m(rec['pump_wait_seconds']):>8s}")
            if rec["quota_sleep_seconds"]:
                out.append(f"      quota-pauses           {_fmt_m(rec['quota_sleep_seconds']):>8s}")
            if wall is not None:
                if agent_total > wall:
                    out.append(f"      overlap saved          {_fmt_m(agent_total - wall):>8s}  (parallel steps)")
                else:
                    out.append(f"      unattributed (glue)    {_fmt_m(wall - agent_total):>8s}")
        completed = [i for i in s["iterations"] if i["complete"] and i["wall_seconds"]]
        if completed and iter_filter is None:
            mean = sum(i["wall_seconds"] for i in completed) / len(completed)
            out.append(f"  session: {len(completed)} completed iteration(s), "
                       f"mean wall {_fmt_m(mean)}")
            totals: dict[str, int] = {}
            for i in s["iterations"]:
                for a, row in i["agents"].items():
                    totals[a] = totals.get(a, 0) + row["seconds"]
            for a, secs in sorted(totals.items(), key=lambda kv: -kv[1]):
                out.append(f"      total {a:<24s} {_fmt_m(secs):>8s}")
            if s["paused_seconds"]:
                out.append(f"      total AWAITING_PUMP paused gaps: {_fmt_m(s['paused_seconds'])}")
            if s["halts"]:
                out.append(f"      halts: {', '.join(s['halts'])}")
        out.append("")
    return "\n".join(out)


def render_wall_json(report: dict[str, dict[str, Any]],
                     iter_filter: int | None = None) -> str:
    out: dict[str, Any] = {}
    for sid, s in report.items():
        iters = s["iterations"]
        if iter_filter is not None:
            iters = [i for i in iters if _iter_index(i["iter_name"]) == iter_filter]
        out[sid] = {
            "iterations": iters,
            "halts": s["halts"],
            "awaiting_pump_paused_seconds": s["paused_seconds"],
        }
    return json.dumps(out, indent=2, default=str)


# ── experiment tripwire (--tripwire) ─────────────────────────────────────────
#
# Guards opt-in speed experiments (e.g. CHAIN_AGENT_EFFORT=developer=high).
# Looks at the last --window knob-active completed iterations and TRIPs when
# quality moved: any REGRESSION verdict, any journey regression count > 0, or
# first-attempt review FAILs in ≥2 of the window. Exit 3 on TRIP so shell
# callers can auto-revert the knob.


def evaluate_tripwire(report: dict[str, dict[str, Any]], window: int = 3
                      ) -> tuple[bool, list[str]]:
    reasons: list[str] = []
    tripped = False
    for sid, s in report.items():
        active = [i for i in s["iterations"] if i["complete"] and i["knob_active"]]
        recent = active[-window:]
        if not recent:
            continue
        fail_iters = 0
        for rec in recent:
            if rec["verdict"] == "REGRESSION":
                tripped = True
                reasons.append(f"{sid}/{rec['iter_name']}: REGRESSION verdict")
            if int((rec["journey_deltas"] or {}).get("regressed") or 0) > 0:
                tripped = True
                reasons.append(f"{sid}/{rec['iter_name']}: journey regression recorded")
            if any(rv["verdict"] == "FAIL" and rv["attempt"] == 1
                   for rv in rec["review_verdicts"]):
                fail_iters += 1
        if fail_iters >= 2:
            tripped = True
            reasons.append(
                f"{sid}: first-attempt review FAIL in {fail_iters}/{len(recent)} "
                f"knob-active iterations")
    return tripped, reasons


# ── self-test ────────────────────────────────────────────────────────────────

_FIXTURE = [
    {"event": "session_start", "session_id": "s-1", "ts": "2026-05-04T10:00:00Z"},
    {
        "event": "agent_invocation_start",
        "session_id": "s-1",
        "agent": "developer",
        "ts": "2026-05-04T10:00:01Z",
    },
    {
        "event": "claude_usage",
        "session_id": "s-1",
        "agent": "developer",
        "model": "claude-opus-4-8",
        "duration_ms": 12000,
        "duration_api_ms": 10000,
        "num_turns": 3,
        "total_cost_usd": 0.04,
        "is_error": False,
        "usage": {
            "input_tokens": 1500,
            "output_tokens": 250,
            "cache_read_input_tokens": 8000,
            "cache_creation_input_tokens": 100,
        },
    },
    {
        "event": "claude_usage",
        "session_id": "s-1",
        "agent": "reviewer",
        "model": "claude-sonnet-5",
        "duration_ms": 4000,
        "duration_api_ms": 3500,
        "num_turns": 1,
        "total_cost_usd": 0.01,
        "is_error": False,
        "usage": {
            "input_tokens": 500,
            "output_tokens": 100,
            "cache_read_input_tokens": 4000,
            "cache_creation_input_tokens": 0,
        },
    },
    {
        "event": "agent_invocation_end",
        "session_id": "s-1",
        "agent": "developer",
        "ts": "2026-05-04T10:00:30Z",
    },
]


# Two iterations of a goal session: iter-1 is clean (agents + a resume-skip +
# pump wait, parallel overlap), iter-2 regresses under an active experiment
# knob — exercises both --wall attribution and the --tripwire verdict. An
# unmatched iter_start (crashed attempt) checks ragged-data tolerance.
_WALL_FIXTURE = [
    {"event": "session_start", "session_id": "w-1", "ts": "2026-07-01T10:00:00Z"},
    {"event": "iter_start", "session_id": "w-1", "iter_name": "goal-w-iter-1",
     "ts": "2026-07-01T10:00:00Z"},
    {"event": "iter_dispatch", "session_id": "w-1", "depth": "lean",
     "ts": "2026-07-01T10:08:00Z"},
    {"event": "agent_invocation_end", "session_id": "w-1", "agent": "goal-decomposer",
     "exit_status": 0, "duration_seconds": 480, "retries": 0, "ts": "2026-07-01T10:08:00Z"},
    {"event": "agent_invocation_end", "session_id": "w-1", "agent": "developer",
     "exit_status": 0, "duration_seconds": 2400, "retries": 0, "ts": "2026-07-01T10:48:00Z"},
    {"event": "step_skipped", "session_id": "w-1", "step": "reviewer",
     "iter_name": "goal-w-iter-1", "ts": "2026-07-01T10:48:01Z"},
    {"event": "dispatch_wait", "session_id": "w-1", "agent": "browser-qa-agent",
     "wait_seconds": 120, "run_seconds": 1100, "status": "ok", "ts": "2026-07-01T11:10:00Z"},
    {"event": "agent_invocation_end", "session_id": "w-1", "agent": "browser-qa-agent",
     "exit_status": 0, "duration_seconds": 1220, "retries": 0, "ts": "2026-07-01T11:10:00Z"},
    {"event": "agent_invocation_end", "session_id": "w-1", "agent": "coherence-auditor",
     "exit_status": 0, "duration_seconds": 240, "retries": 0, "ts": "2026-07-01T11:10:05Z"},
    {"event": "agent_invocation_end", "session_id": "w-1", "agent": "goal-evaluator",
     "exit_status": 0, "duration_seconds": 900, "retries": 0, "ts": "2026-07-01T11:25:10Z"},
    {"event": "iter_end", "session_id": "w-1", "iter_name": "goal-w-iter-1",
     "verdict": "CONTINUE", "journey_deltas": {"regressed": 0},
     "ts": "2026-07-01T11:26:00Z"},
    {"event": "iter_start", "session_id": "w-1", "iter_name": "goal-w-iter-2",
     "ts": "2026-07-01T11:26:30Z"},
    {"event": "iter_config", "session_id": "w-1", "key": "CHAIN_AGENT_EFFORT",
     "value": "developer=high", "ts": "2026-07-01T11:26:31Z"},
    {"event": "review_verdict", "session_id": "w-1", "verdict": "FAIL",
     "attempt": 1, "iter_name": "goal-w-iter-2", "ts": "2026-07-01T12:00:00Z"},
    {"event": "iter_end", "session_id": "w-1", "iter_name": "goal-w-iter-2",
     "verdict": "REGRESSION", "journey_deltas": {"regressed": 1},
     "ts": "2026-07-01T12:30:00Z"},
    # crashed attempt: an iter_start that never ends
    {"event": "iter_start", "session_id": "w-1", "iter_name": "goal-w-iter-3",
     "ts": "2026-07-01T12:31:00Z"},
]


def _self_test() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "telemetry.jsonl"
        path.write_text(
            "\n".join(json.dumps(e) for e in _FIXTURE) + "\n",
            encoding="utf-8",
        )
        sessions = aggregate([str(path)])
        if "s-1" not in sessions:
            print("FAIL: session s-1 missing", file=sys.stderr)
            return 1
        s = sessions["s-1"]
        if s.total.invocations != 2:
            print(f"FAIL: expected 2 invocations, got {s.total.invocations}", file=sys.stderr)
            return 1
        if s.total.input_tokens != 2000:
            print(f"FAIL: expected 2000 input tokens, got {s.total.input_tokens}", file=sys.stderr)
            return 1
        if s.total.cache_read_input_tokens != 12000:
            print(f"FAIL: expected 12000 cache reads, got {s.total.cache_read_input_tokens}", file=sys.stderr)
            return 1
        # cache hit ratio = 12000 / (2000 + 12000) = 0.857...
        if not (0.85 < s.total.cache_hit_ratio() < 0.86):
            print(f"FAIL: cache hit ratio off: {s.total.cache_hit_ratio()}", file=sys.stderr)
            return 1
        if abs(s.total.total_cost_usd - 0.05) > 1e-6:
            print(f"FAIL: cost off: {s.total.total_cost_usd}", file=sys.stderr)
            return 1
        agents = sorted(s.by_agent.keys())
        if agents != ["developer", "reviewer"]:
            print(f"FAIL: agent split: {agents}", file=sys.stderr)
            return 1
        models = sorted(s.by_model.keys())
        if models != ["claude-opus-4-8", "claude-sonnet-5"]:
            print(f"FAIL: model split: {models}", file=sys.stderr)
            return 1
        if s.by_model["claude-opus-4-8"].input_tokens != 1500:
            print("FAIL: by_model token attribution off", file=sys.stderr)
            return 1
        # Render check
        text = render_text(sessions)
        if "developer" not in text or "reviewer" not in text:
            print("FAIL: render missing agents", file=sys.stderr)
            return 1
        json_out = render_json(sessions)
        json.loads(json_out)  # must parse

        # ── --wall / --tripwire fixture ──────────────────────────────────────
        wpath = Path(tmp) / "wall-telemetry.jsonl"
        wpath.write_text(
            "\n".join(json.dumps(e) for e in _WALL_FIXTURE) + "\n",
            encoding="utf-8",
        )
        report = build_wall_report([str(wpath)])
        if "w-1" not in report:
            print("FAIL: wall session w-1 missing", file=sys.stderr)
            return 1
        iters = report["w-1"]["iterations"]
        if len(iters) != 3:
            print(f"FAIL: expected 3 iteration records (incl. crashed attempt), got {len(iters)}", file=sys.stderr)
            return 1
        it1 = iters[0]
        if it1["wall_seconds"] != 5160:  # 10:00:00 → 11:26:00
            print(f"FAIL: iter-1 wall {it1['wall_seconds']} != 5160", file=sys.stderr)
            return 1
        if it1["agents"]["developer"]["seconds"] != 2400:
            print("FAIL: developer seconds attribution", file=sys.stderr)
            return 1
        if it1["skipped_steps"] != ["reviewer"]:
            print(f"FAIL: skipped steps {it1['skipped_steps']}", file=sys.stderr)
            return 1
        if it1["pump_wait_seconds"] != 120:
            print("FAIL: pump wait attribution", file=sys.stderr)
            return 1
        if it1["depth"] != "lean" or it1["verdict"] != "CONTINUE" or not it1["complete"]:
            print("FAIL: iter-1 metadata", file=sys.stderr)
            return 1
        if iters[2]["complete"]:
            print("FAIL: crashed attempt marked complete", file=sys.stderr)
            return 1
        text = render_wall_text(report)
        for needle in ("goal-w-iter-1", "developer", "resume-skipped: reviewer",
                       "pump-wait", "incomplete/interrupted"):
            if needle not in text:
                print(f"FAIL: wall render missing '{needle}'", file=sys.stderr)
                return 1
        only2 = render_wall_text(report, iter_filter=2)
        if "goal-w-iter-2" not in only2 or "goal-w-iter-1" in only2:
            print("FAIL: --iter filter", file=sys.stderr)
            return 1
        json.loads(render_wall_json(report))  # must parse
        tripped, reasons = evaluate_tripwire(report, window=3)
        if not tripped:
            print("FAIL: tripwire should TRIP on REGRESSION + regressed>0", file=sys.stderr)
            return 1
        if not any("REGRESSION" in r for r in reasons):
            print(f"FAIL: tripwire reasons: {reasons}", file=sys.stderr)
            return 1
        # Without the knob-active iteration, the tripwire must stay quiet.
        quiet = [e for e in _WALL_FIXTURE if e["event"] != "iter_config"]
        qpath = Path(tmp) / "quiet.jsonl"
        qpath.write_text("\n".join(json.dumps(e) for e in quiet) + "\n", encoding="utf-8")
        tripped_q, _ = evaluate_tripwire(build_wall_report([str(qpath)]), window=3)
        if tripped_q:
            print("FAIL: tripwire fired with no knob-active iterations", file=sys.stderr)
            return 1
    print("self-test passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Aggregate Claude API usage from telemetry.jsonl files."
    )
    parser.add_argument(
        "paths",
        nargs="*",
        help=(
            "telemetry.jsonl OR trace.jsonl files (one or more). "
            "e.g. runs/goal-session-X/telemetry.jsonl OR runs/<phase>/trace/trace.jsonl"
        ),
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="emit machine-readable JSON instead of text summary",
    )
    parser.add_argument(
        "--source",
        choices=("auto", "telemetry", "trace"),
        default="auto",
        help=(
            "input format: 'telemetry' (claude_usage events) or 'trace' "
            "(per-call records from quota-retry). 'auto' picks based on filename."
        ),
    )
    parser.add_argument(
        "--watch",
        type=int,
        metavar="SECONDS",
        help=(
            "re-aggregate and re-render every SECONDS until interrupted; "
            "useful for monitoring an active session"
        ),
    )
    parser.add_argument(
        "--wall",
        action="store_true",
        help="per-iteration wall-time breakdown (where the ~2h goes) instead of token usage",
    )
    parser.add_argument(
        "--iter",
        type=int,
        default=None,
        metavar="N",
        help="with --wall: only the iteration with this index",
    )
    parser.add_argument(
        "--tripwire",
        action="store_true",
        help=(
            "evaluate the speed-experiment quality tripwire over the last "
            "--window knob-active iterations; exit 3 when tripped"
        ),
    )
    parser.add_argument(
        "--window",
        type=int,
        default=3,
        help="tripwire window (default 3 knob-active completed iterations)",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run built-in fixture self-test and exit",
    )
    args = parser.parse_args()

    if args.self_test:
        return _self_test()
    if not args.paths:
        parser.error("provide at least one path, or --self-test")

    if args.wall or args.tripwire:
        report = build_wall_report(args.paths)
        if args.tripwire:
            tripped, reasons = evaluate_tripwire(report, window=args.window)
            if tripped:
                print("TRIPWIRE: TRIP")
                for r in reasons:
                    print(f"  - {r}")
                return 3
            print("TRIPWIRE: OK (no quality movement in the window)")
            return 0
        if args.json:
            print(render_wall_json(report, iter_filter=args.iter))
        else:
            print(render_wall_text(report, iter_filter=args.iter))
        return 0

    def _aggregate_now() -> dict[str, SessionSummary]:
        if args.source == "trace":
            return aggregate_traces(args.paths)
        if args.source == "telemetry":
            return aggregate(args.paths)
        # auto: dispatch per file based on filename, merge results
        merged: dict[str, SessionSummary] = {}
        tele_paths = [p for p in args.paths if "trace" not in os.path.basename(p)]
        trace_paths = [p for p in args.paths if "trace" in os.path.basename(p)]
        if tele_paths:
            for sid, s in aggregate(tele_paths).items():
                merged[sid] = s
        if trace_paths:
            for sid, s in aggregate_traces(trace_paths).items():
                if sid in merged:
                    # Merge: caller likely double-counts if same data appears
                    # in both sources. Prefer telemetry (which carries proper
                    # session_id); skip duplicate trace data.
                    continue
                merged[sid] = s
        return merged

    if args.watch is not None and args.watch > 0:
        try:
            while True:
                sessions = _aggregate_now()
                # Clear screen for redraw
                sys.stdout.write("\x1b[2J\x1b[H")
                sys.stdout.write(
                    f"[watch] refresh every {args.watch}s. Ctrl-C to stop.\n\n"
                )
                if args.json:
                    print(render_json(sessions))
                else:
                    print(render_text(sessions))
                time.sleep(args.watch)
        except KeyboardInterrupt:
            return 0

    sessions = _aggregate_now()
    if args.json:
        print(render_json(sessions))
    else:
        print(render_text(sessions))
    return 0


if __name__ == "__main__":
    sys.exit(main())
