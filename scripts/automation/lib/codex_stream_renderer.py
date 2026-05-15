"""
Stream-JSON renderer for `codex exec --json`.

Parallel to claude_stream_renderer.py: reads NDJSON events from stdin, prints a
human-readable summary to stdout, and writes a usage sidecar JSON to
$CHAIN_CODEX_USAGE_SIDECAR (or $CHAIN_CLAUDE_USAGE_SIDECAR for symmetry — the
quota-retry layer treats one as a fallback for the other).

Why parallel rather than shared:
  Codex's NDJSON event vocabulary differs from Claude's stream-json. Both renderers
  emit the same sidecar shape ({"usage": {...}, "total_cost_usd": ...}) so the
  telemetry layer can consume either uniformly.

Tolerant by default: any event we don't recognise passes through verbatim. The
final usage block is whatever Codex puts on the last `result`-like event.
"""
from __future__ import annotations

import json
import os
import sys
from typing import Any

_RENDER_TOOL_USE = os.environ.get("CHAIN_RENDER_TOOL_USE", "false").lower() == "true"

_DOT_BUFFER = 0
_DOT_WRAP = 60
_AT_LINE_START = True

_FINAL_USAGE: dict[str, Any] = {}


def _flush_dots() -> None:
    global _DOT_BUFFER, _AT_LINE_START
    if _DOT_BUFFER > 0:
        sys.stdout.write("\n")
        sys.stdout.flush()
        _DOT_BUFFER = 0
        _AT_LINE_START = True


def _emit_text(text: str) -> None:
    global _AT_LINE_START
    if not text:
        return
    _flush_dots()
    sys.stdout.write(text)
    sys.stdout.flush()
    _AT_LINE_START = text.endswith("\n")


def _emit_tool_dot() -> None:
    global _DOT_BUFFER, _AT_LINE_START
    if _DOT_BUFFER == 0 and not _AT_LINE_START:
        sys.stdout.write("\n")
    sys.stdout.write(".")
    _DOT_BUFFER += 1
    if _DOT_BUFFER >= _DOT_WRAP:
        sys.stdout.write("\n")
        _DOT_BUFFER = 0
        _AT_LINE_START = True
    sys.stdout.flush()


def _emit_tool_verbose(name: str, summary: str) -> None:
    _flush_dots()
    sys.stdout.write(f"[tool: {name} {summary}]\n")
    sys.stdout.flush()


def _handle_event(ev: dict[str, Any]) -> None:
    """Dispatch one parsed event. Designed to tolerate schema drift —
    unknown event types are logged via stdout but otherwise ignored."""
    global _FINAL_USAGE

    # Codex event types are documented loosely; handle several plausible shapes.
    et = ev.get("type") or ev.get("event") or ""

    # Plain text / message deltas
    if et in ("agent_message_delta", "message_delta", "text", "agent_text"):
        text = ev.get("text") or ev.get("delta") or ev.get("content") or ""
        if isinstance(text, list):
            text = "".join(p.get("text", "") for p in text if isinstance(p, dict))
        _emit_text(str(text))
        return
    if et in ("agent_message", "message"):
        text = ev.get("text") or ev.get("content") or ""
        if isinstance(text, list):
            text = "".join(p.get("text", "") for p in text if isinstance(p, dict))
        _emit_text(str(text) + ("\n" if not str(text).endswith("\n") else ""))
        return

    # Tool calls
    if et in ("tool_call", "tool_use", "function_call"):
        name = ev.get("name") or ev.get("tool") or "tool"
        if _RENDER_TOOL_USE:
            args = ev.get("input") or ev.get("arguments") or {}
            try:
                summary = json.dumps(args)[:160]
            except Exception:
                summary = str(args)[:160]
            _emit_tool_verbose(str(name), summary)
        else:
            _emit_tool_dot()
        return

    # Tool results — we don't normally render these; Codex echoes them itself.
    if et in ("tool_result", "function_result"):
        return

    # Final usage block. Codex wraps it in different shapes depending on version:
    if et in ("result", "final", "usage", "complete"):
        usage = ev.get("usage") or {}
        cost = ev.get("cost_usd") or ev.get("total_cost_usd") or ev.get("cost")
        if usage:
            _FINAL_USAGE["usage"] = usage
        if cost is not None:
            _FINAL_USAGE["total_cost_usd"] = cost
        # Some Codex builds emit a final text alongside; surface it.
        text = ev.get("text") or ev.get("message")
        if text:
            _emit_text(str(text) + ("\n" if not str(text).endswith("\n") else ""))
        return

    # Errors — surface clearly so the operator sees them.
    if et in ("error", "agent_error"):
        _flush_dots()
        msg = ev.get("message") or ev.get("error") or json.dumps(ev)
        sys.stderr.write(f"[codex error] {msg}\n")
        sys.stderr.flush()
        return

    # Unknown — pass through compact JSON so we don't lose information.
    _flush_dots()
    sys.stdout.write(json.dumps(ev) + "\n")
    sys.stdout.flush()


def _write_sidecar() -> None:
    sidecar = os.environ.get("CHAIN_CODEX_USAGE_SIDECAR") or os.environ.get(
        "CHAIN_CLAUDE_USAGE_SIDECAR"
    )
    if not sidecar:
        return
    if not _FINAL_USAGE:
        return
    try:
        with open(sidecar, "w", encoding="utf-8") as fh:
            json.dump(_FINAL_USAGE, fh)
    except OSError:
        pass


def main() -> int:
    for raw in sys.stdin:
        line = raw.rstrip("\n")
        if not line.strip():
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            # not JSON — pass through
            _flush_dots()
            sys.stdout.write(line + "\n")
            sys.stdout.flush()
            continue
        if isinstance(ev, dict):
            _handle_event(ev)
        else:
            _flush_dots()
            sys.stdout.write(line + "\n")
            sys.stdout.flush()
    _flush_dots()
    _write_sidecar()
    return 0


if __name__ == "__main__":
    sys.exit(main())
