"""
Stream-JSON renderer for `claude --output-format stream-json`.

Reads JSONL events from stdin (the claude stream-json output), pretty-prints a
human-readable summary to stdout for terminal display, and writes a usage
sidecar JSON to $CHAIN_CLAUDE_USAGE_SIDECAR when the final result event arrives.

Why exist:
  Stream-JSON gives us per-event token usage and total_cost_usd in the final
  `result` event. Plain text mode (the default) does not expose this. Routing
  claude's stdout through this renderer preserves a usable terminal UX while
  capturing the structured data the harness needs for telemetry.

Design:
  - Tolerant: any line that fails to parse as JSON is passed through verbatim.
  - Quiet: text deltas stream as-is; tool calls collapse to a single bracket line.
  - The sidecar is only written if CHAIN_CLAUDE_USAGE_SIDECAR is set AND a
    `result` event with usage data is observed. If claude exits before that,
    the sidecar is absent and the caller emits no token-telemetry event.
"""
from __future__ import annotations

import json
import os
import sys
from typing import Any


def _emit_text(text: str) -> None:
    if not text:
        return
    sys.stdout.write(text)
    sys.stdout.flush()


def _summarize_tool_use(block: dict[str, Any]) -> str:
    name = block.get("name", "?")
    input_obj = block.get("input") or {}
    # Single most useful arg if obvious
    hint = ""
    for key in ("file_path", "path", "command", "url", "pattern", "subagent_type"):
        if key in input_obj and isinstance(input_obj[key], str):
            val = input_obj[key]
            if len(val) > 80:
                val = val[:77] + "..."
            hint = f" {key}={val}"
            break
    return f"\n[tool: {name}{hint}]\n"


def _summarize_tool_result(_block: dict[str, Any]) -> str:
    # Tool results can be huge; signal arrival without dumping the body.
    return ""


def _handle_event(event: dict[str, Any]) -> None:
    etype = event.get("type")

    if etype == "system":
        # Initial session info — usually one-line
        sub = event.get("subtype", "")
        if sub == "init":
            model = event.get("model") or ""
            sid = event.get("session_id") or ""
            if sid:
                sys.stderr.write(
                    f"[claude] session={sid[:8]}... model={model}\n"
                )
        return

    if etype == "assistant":
        msg = event.get("message", {}) or {}
        for block in msg.get("content", []) or []:
            btype = block.get("type")
            if btype == "text":
                _emit_text(block.get("text", ""))
            elif btype == "tool_use":
                _emit_text(_summarize_tool_use(block))
            elif btype == "thinking":
                # Don't echo extended thinking — treat as private reasoning
                pass
        return

    if etype == "user":
        msg = event.get("message", {}) or {}
        for block in msg.get("content", []) or []:
            if block.get("type") == "tool_result":
                _emit_text(_summarize_tool_result(block))
        return

    if etype == "result":
        # Final summary; capture for sidecar.
        return  # consumed in main loop


def _write_sidecar(result_event: dict[str, Any]) -> None:
    sidecar_path = os.environ.get("CHAIN_CLAUDE_USAGE_SIDECAR", "")
    if not sidecar_path:
        return
    payload = {
        "duration_ms": result_event.get("duration_ms"),
        "duration_api_ms": result_event.get("duration_api_ms"),
        "num_turns": result_event.get("num_turns"),
        "total_cost_usd": result_event.get("total_cost_usd"),
        "session_id": result_event.get("session_id"),
        "is_error": result_event.get("is_error", False),
        "subtype": result_event.get("subtype"),
        "usage": result_event.get("usage", {}) or {},
    }
    try:
        with open(sidecar_path, "w", encoding="utf-8") as f:
            json.dump(payload, f)
    except OSError as e:
        sys.stderr.write(f"[claude-stream-renderer] failed to write sidecar: {e}\n")


def _emit_result_summary(result_event: dict[str, Any]) -> None:
    """Echo result info to stdout so the captured log is informative AND
    contains any error text quota-detection regexes need to see."""
    is_error = result_event.get("is_error", False)
    subtype = result_event.get("subtype", "")
    if is_error or subtype not in ("success", "", None):
        # Surface error result so quota detection / debugging can read it
        result_text = result_event.get("result")
        if isinstance(result_text, str):
            sys.stdout.write(f"\n{result_text}\n")
        sys.stdout.write(
            f"[claude-result] subtype={subtype} is_error={is_error}\n"
        )
    usage = result_event.get("usage") or {}
    cost = result_event.get("total_cost_usd")
    if usage:
        sys.stdout.write(
            "[claude-usage] "
            f"in={usage.get('input_tokens', 0)} "
            f"out={usage.get('output_tokens', 0)} "
            f"cache_read={usage.get('cache_read_input_tokens', 0)} "
            f"cache_create={usage.get('cache_creation_input_tokens', 0)}"
        )
        if cost is not None:
            sys.stdout.write(f" cost_usd={cost}")
        sys.stdout.write("\n")
    sys.stdout.flush()


def main() -> int:
    last_result: dict[str, Any] | None = None
    for line in sys.stdin:
        stripped = line.rstrip("\n")
        if not stripped:
            continue
        try:
            event = json.loads(stripped)
        except json.JSONDecodeError:
            # Pass through any non-JSON line (e.g., pre-init banner, plain
            # error messages from claude before stream-json kicks in).
            sys.stdout.write(stripped + "\n")
            sys.stdout.flush()
            continue
        if not isinstance(event, dict):
            continue

        if event.get("type") == "result":
            last_result = event
        else:
            _handle_event(event)

    sys.stdout.write("\n")
    sys.stdout.flush()

    if last_result is not None:
        _emit_result_summary(last_result)
        _write_sidecar(last_result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
