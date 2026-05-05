"""
Inspect or replay claude invocations recorded by `lib/quota-retry.sh` when
`CHAIN_TRACE_DIR` is set.

Each entry in `<trace_dir>/trace.jsonl` is one successful claude call: the args,
the agent context, duration, exit code, and (when telemetry was enabled) token
usage and cost. The captured stdout lives next to the index as
`<NNNN>-<agent>.log`.

Commands:
    list   <trace_dir>                   Tabular summary of all steps
    show   <trace_dir> <step> [--args|--stdout|--full]
                                          Print prompt args and/or stdout
    replay <trace_dir> <step> [--execute] Re-run the captured invocation. Without
                                          --execute, just prints the command.
    self-test                              Internal fixture roundtrip

Designed to be safe by default — `replay` is dry-run unless `--execute` is set,
because re-invoking claude costs API credits.
"""
from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


def _load_trace(trace_dir: str) -> list[dict[str, Any]]:
    path = Path(trace_dir) / "trace.jsonl"
    if not path.is_file():
        raise FileNotFoundError(f"trace.jsonl not found in {trace_dir}")
    entries: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as f:
        for raw in f:
            stripped = raw.strip()
            if not stripped:
                continue
            try:
                entries.append(json.loads(stripped))
            except json.JSONDecodeError:
                # Tolerate partial last line (in-progress run)
                continue
    return entries


def _prompt_preview(args: list[str], width: int = 80) -> str:
    if not args:
        return ""
    # Find the prompt: usually the value after -p / --print, or the last arg.
    prompt = ""
    for i, arg in enumerate(args):
        if arg in ("-p", "--print") and i + 1 < len(args):
            prompt = args[i + 1]
            break
    if not prompt and args:
        prompt = args[-1]
    prompt = prompt.replace("\n", " ").strip()
    if len(prompt) > width:
        return prompt[: width - 3] + "..."
    return prompt


def _cmd_list(trace_dir: str) -> int:
    entries = _load_trace(trace_dir)
    if not entries:
        print(f"(no entries in {trace_dir}/trace.jsonl)")
        return 0
    print(f"{'step':<5s} {'agent':<22s} {'ts':<22s} {'dur':>5s} {'cost':>9s} prompt")
    print("-" * 110)
    for e in entries:
        cost = e.get("total_cost_usd")
        cost_str = f"${cost:.4f}" if isinstance(cost, (int, float)) else "      -"
        dur = e.get("duration_seconds", 0)
        prompt = _prompt_preview(e.get("args", []), width=50)
        print(
            f"{e.get('step', '?'):<5} "
            f"{e.get('agent', 'unknown'):<22s} "
            f"{e.get('ts', ''):<22s} "
            f"{dur:>4}s "
            f"{cost_str:>9s} "
            f"{prompt}"
        )
    return 0


def _cmd_show(trace_dir: str, step: int, what: str) -> int:
    entries = _load_trace(trace_dir)
    entry = next((e for e in entries if e.get("step") == step), None)
    if entry is None:
        print(f"step {step} not found in {trace_dir}/trace.jsonl", file=sys.stderr)
        return 1

    show_args = what in ("args", "full")
    show_stdout = what in ("stdout", "full")
    if not (show_args or show_stdout):
        # Default: show args
        show_args = True

    if show_args:
        print(f"== step {step} — {entry.get('agent', '?')} @ {entry.get('ts', '?')}")
        print(f"   exit_code={entry.get('exit_code')} duration_seconds={entry.get('duration_seconds')}")
        usage = entry.get("usage") or {}
        cost = entry.get("total_cost_usd")
        if usage or cost is not None:
            print(
                f"   tokens: in={usage.get('input_tokens', 0)} "
                f"out={usage.get('output_tokens', 0)} "
                f"cache_read={usage.get('cache_read_input_tokens', 0)} "
                f"cost={cost}"
            )
        print()
        print("== args (claude invocation) ==")
        for arg in entry.get("args", []):
            print(arg)
        print()

    if show_stdout:
        stdout_path = entry.get("stdout_path")
        if stdout_path:
            full = Path(trace_dir) / stdout_path
            if full.is_file():
                print(f"== stdout (from {full}) ==")
                print(full.read_text(encoding="utf-8", errors="replace"))
            else:
                print(f"(stdout file {full} missing)", file=sys.stderr)
        else:
            print("(no stdout_path recorded)", file=sys.stderr)
    return 0


def _cmd_replay(trace_dir: str, step: int, execute: bool) -> int:
    entries = _load_trace(trace_dir)
    entry = next((e for e in entries if e.get("step") == step), None)
    if entry is None:
        print(f"step {step} not found in {trace_dir}/trace.jsonl", file=sys.stderr)
        return 1
    args = entry.get("args", [])
    if not args:
        print(f"step {step} has no recorded args — nothing to replay", file=sys.stderr)
        return 1
    cmd = ["claude", *args]
    rendered = " ".join(shlex.quote(a) for a in cmd)
    if not execute:
        print("# Dry-run. Re-run with --execute to invoke claude:")
        print(rendered)
        return 0
    print(f"# Replaying step {step} ({entry.get('agent', '?')})", file=sys.stderr)
    print(f"# {rendered}", file=sys.stderr)
    try:
        result = subprocess.run(cmd, check=False)
        return result.returncode
    except FileNotFoundError:
        print("Error: claude CLI not found in PATH.", file=sys.stderr)
        return 127


def _self_test() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        trace_dir = Path(tmp)
        # Build a fixture trace.jsonl + matching stdout files
        entries = [
            {
                "step": 1,
                "agent": "orchestrator",
                "ts": "2026-05-04T10:00:00Z",
                "exit_code": 0,
                "duration_seconds": 12,
                "stdout_path": "0001-orchestrator.log",
                "args": ["-p", "Plan phase-1: build login flow"],
                "duration_ms": 12000,
                "total_cost_usd": 0.04,
                "usage": {
                    "input_tokens": 1500,
                    "output_tokens": 250,
                    "cache_read_input_tokens": 8000,
                    "cache_creation_input_tokens": 100,
                },
            },
            {
                "step": 2,
                "agent": "developer",
                "ts": "2026-05-04T10:00:30Z",
                "exit_code": 0,
                "duration_seconds": 45,
                "stdout_path": "0002-developer.log",
                "args": ["-p", "Implement plan from runs/phase-1/plan.md"],
                "duration_ms": 45000,
                "total_cost_usd": 0.12,
                "usage": {"input_tokens": 4000, "output_tokens": 1500, "cache_read_input_tokens": 0},
            },
        ]
        (trace_dir / "trace.jsonl").write_text(
            "\n".join(json.dumps(e) for e in entries) + "\n", encoding="utf-8"
        )
        (trace_dir / "0001-orchestrator.log").write_text("Plan output here\n", encoding="utf-8")
        (trace_dir / "0002-developer.log").write_text("Code change output\n", encoding="utf-8")

        # 1. list
        loaded = _load_trace(str(trace_dir))
        assert len(loaded) == 2, f"expected 2 entries, got {len(loaded)}"

        # 2. show args
        rc = _cmd_show(str(trace_dir), 1, "args")
        assert rc == 0, f"show args failed rc={rc}"

        # 3. show stdout
        rc = _cmd_show(str(trace_dir), 2, "stdout")
        assert rc == 0, f"show stdout failed rc={rc}"

        # 4. show missing
        rc = _cmd_show(str(trace_dir), 99, "args")
        assert rc == 1, f"missing-step should return 1, got {rc}"

        # 5. replay dry-run
        rc = _cmd_replay(str(trace_dir), 1, execute=False)
        assert rc == 0, f"dry-run replay failed rc={rc}"

        print("self-test passed")
        return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Inspect / replay claude trace records.")
    sub = parser.add_subparsers(dest="cmd")

    p_list = sub.add_parser("list", help="Show all steps")
    p_list.add_argument("trace_dir")

    p_show = sub.add_parser("show", help="Show one step's args and/or stdout")
    p_show.add_argument("trace_dir")
    p_show.add_argument("step", type=int)
    p_show_what = p_show.add_mutually_exclusive_group()
    p_show_what.add_argument("--args", action="store_const", const="args", dest="what")
    p_show_what.add_argument("--stdout", action="store_const", const="stdout", dest="what")
    p_show_what.add_argument("--full", action="store_const", const="full", dest="what")
    p_show.set_defaults(what="args")

    p_replay = sub.add_parser("replay", help="Re-invoke claude with the captured args")
    p_replay.add_argument("trace_dir")
    p_replay.add_argument("step", type=int)
    p_replay.add_argument(
        "--execute",
        action="store_true",
        help="Actually run the claude command (default: print only)",
    )

    sub.add_parser("self-test", help="Run built-in fixture self-test")

    args = parser.parse_args()
    if args.cmd is None:
        parser.print_help()
        return 2

    if args.cmd == "list":
        return _cmd_list(args.trace_dir)
    if args.cmd == "show":
        return _cmd_show(args.trace_dir, args.step, args.what)
    if args.cmd == "replay":
        return _cmd_replay(args.trace_dir, args.step, args.execute)
    if args.cmd == "self-test":
        return _self_test()
    return 2


if __name__ == "__main__":
    sys.exit(main())
