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
            summary = sessions.setdefault(sid, SessionSummary(session_id=sid))
            if path not in summary.paths:
                summary.paths.append(path)
            summary.total.add(usage, event)
            summary.by_agent[agent].add(usage, event)
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
            summary = sessions.setdefault(sid, SessionSummary(session_id=sid))
            if path not in summary.paths:
                summary.paths.append(path)
            summary.total.add(usage, event)
            summary.by_agent[agent].add(usage, event)
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
        }
    return json.dumps(out, indent=2, default=str)


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
        # Render check
        text = render_text(sessions)
        if "developer" not in text or "reviewer" not in text:
            print("FAIL: render missing agents", file=sys.stderr)
            return 1
        json_out = render_json(sessions)
        json.loads(json_out)  # must parse
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
        "--self-test",
        action="store_true",
        help="run built-in fixture self-test and exit",
    )
    args = parser.parse_args()

    if args.self_test:
        return _self_test()
    if not args.paths:
        parser.error("provide at least one path, or --self-test")

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
