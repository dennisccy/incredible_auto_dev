#!/usr/bin/env bash
# claude-launch-dir-permissions.sh — does a REAL Claude Code session actually enforce the
# deny rules we render, from each directory a session may be started in?
#
# NOT part of the offline eval suite: it starts the installed `claude` binary. Run it by
# hand when changing the permission rendering, after a Claude Code upgrade, and after a
# vendored sync into a product checkout:
#
#     bash tests/integration/claude-launch-dir-permissions.sh
#
# No model and no spend. Claude Code talks to a local stand-in for the Messages API
# (ANTHROPIC_BASE_URL) that scripts which Bash calls the session asks for; the real
# permission checker then decides each one. The API key is a dummy, so a stray call to the
# real API could only get a 401, and CLAUDE_CONFIG_DIR is a scratch directory, so no user
# credentials, settings or hooks take part. Every probe is a harmless `echo`.
#
# What it pins (the 2026-09-22 incident): Claude Code reads the shared .claude/settings.json
# ONLY from the directory a session is STARTED in, so a session started in a product
# subdirectory enforced none of the project's deny rules. `claude_launch_dirs` renders the
# deny list into each declared subdirectory; these scenarios prove the rules are in force
# there — including for the subagents an interactive engine runs its agents as.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1));
  else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}

echo "== claude-launch-dir-permissions.sh =="
if ! command -v claude >/dev/null 2>&1; then
  echo "  SKIP  the 'claude' binary is not on PATH — nothing to enforce against"
  exit 0
fi
echo "  claude $(claude --version 2>/dev/null | head -1)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── scratch product: <P>/incredible_auto_dev (vendored) + <P>/.claude symlink ────────────
P="$WORK/product"
V="$P/incredible_auto_dev"
mkdir -p "$V/scripts/automation/lib" "$P/apps/backend" "$P/apps/frontend"
for d in adapters agents skills hooks commands config policy .claude; do
  cp -r "$ENGINE_ROOT/$d" "$V/"
done
cp "$ENGINE_ROOT/scripts/automation/sync-cli-assets.py" "$V/scripts/automation/"
cp "$ENGINE_ROOT/scripts/automation/lib/agent_permissions.py" "$V/scripts/automation/lib/"
ln -s incredible_auto_dev/.claude "$P/.claude"

# A canary rule of our own, so the scenarios do not depend on any product's policy, and
# apps/backend as a declared launch directory. apps/frontend stays UNdeclared: it is the
# negative control that shows the rendered file is what carries the rules.
CANARY="iad-launch-dir-canary"
python3 - "$V/policy/permissions.yaml" "$CANARY" <<'PY'
import sys
path, canary = sys.argv[1], sys.argv[2]
s = open(path, encoding="utf-8").read()
anchor = "\nadditionalDirectories:"
assert s.count(anchor) == 1
s = s.replace(anchor, "\n- Bash(*%s*)" % canary + anchor)
s = s.rstrip("\n") + "\nclaude_launch_dirs:\n- apps/backend\n"
open(path, "w", encoding="utf-8").write(s)
PY
python3 "$V/scripts/automation/sync-cli-assets.py" --cli claude >/dev/null 2>&1
if [[ -f "$P/apps/backend/.claude/settings.json" ]]; then
  assert "S0 the declared launch directory has rendered settings to enforce" pass
else
  assert "S0 nothing was rendered into the declared launch directory" fail
  echo "== summary: $PASS passed, $FAIL failed =="; exit 1
fi

cat > "$WORK/probe.py" <<'PYEOF'
"""Run one real Claude Code session against a local stand-in for the Messages API and
print what its permission checker did with each scripted Bash call.

    probe.py <launch-dir> <out-prefix> <probe>... [--subagent <probe>...]
"""
import json, os, socket, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

launch_dir, prefix = sys.argv[1], sys.argv[2]
rest = sys.argv[3:]
main_probes = rest[:rest.index("--subagent")] if "--subagent" in rest else rest
sub_probes = rest[rest.index("--subagent") + 1:] if "--subagent" in rest else []
SUB_MARK = "SUBAGENT-PROBES"


def first_user_text(messages):
    for m in messages:
        if m.get("role") == "user":
            c = m.get("content")
            if isinstance(c, str):
                return c
            if isinstance(c, list):
                return " ".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
    return ""


def done_count(messages):
    n = 0
    for m in messages:
        if m.get("role") == "user" and isinstance(m.get("content"), list):
            n += sum(1 for b in m["content"] if isinstance(b, dict) and b.get("type") == "tool_result")
    return n


def plan(body):
    tools = [t.get("name") for t in (body.get("tools") or []) if isinstance(t, dict)]
    msgs = body.get("messages") or []
    done = done_count(msgs)
    if "Bash" not in tools:
        return {"type": "text", "text": "ok"}
    if SUB_MARK in first_user_text(msgs):
        if done < len(sub_probes):
            return {"type": "tool_use", "id": "toolu_s%03d" % done, "name": "Bash",
                    "input": {"command": sub_probes[done], "description": "probe"}}
        return {"type": "text", "text": "done"}
    sub_tool = next((t for t in ("Task", "Agent") if t in tools), None)
    steps = ([("sub", sub_tool)] if (sub_probes and sub_tool) else []) + [("bash", p) for p in main_probes]
    if done >= len(steps):
        return {"type": "text", "text": "done"}
    kind, val = steps[done]
    if kind == "sub":
        return {"type": "tool_use", "id": "toolu_t%03d" % done, "name": val,
                "input": {"description": "probes", "subagent_type": "general-purpose",
                          "prompt": SUB_MARK + ": run the scripted probes"}}
    return {"type": "tool_use", "id": "toolu_m%03d" % done, "name": "Bash",
            "input": {"command": val, "description": "probe"}}


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _json(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._json({"data": [], "has_more": False})

    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            body = {}
        path = self.path.split("?")[0]
        if path.endswith("/count_tokens"):
            return self._json({"input_tokens": 100})
        if not path.endswith("/v1/messages"):
            return self._json({})
        block = plan(body)
        stop = "tool_use" if block["type"] == "tool_use" else "end_turn"
        msg = {"id": "msg_mock", "type": "message", "role": "assistant", "model": body.get("model") or "mock",
               "content": [], "stop_reason": None, "stop_sequence": None,
               "usage": {"input_tokens": 10, "output_tokens": 1}}
        if not body.get("stream"):
            msg.update(content=[block], stop_reason=stop)
            return self._json(msg)
        if block["type"] == "tool_use":
            opened = {"type": "content_block_start", "index": 0, "content_block": dict(block, input={})}
            delta = {"type": "content_block_delta", "index": 0,
                     "delta": {"type": "input_json_delta", "partial_json": json.dumps(block["input"])}}
        else:
            opened = {"type": "content_block_start", "index": 0,
                      "content_block": {"type": "text", "text": ""}}
            delta = {"type": "content_block_delta", "index": 0,
                     "delta": {"type": "text_delta", "text": block["text"]}}
        events = [("message_start", {"type": "message_start", "message": msg}),
                  ("content_block_start", opened), ("content_block_delta", delta),
                  ("content_block_stop", {"type": "content_block_stop", "index": 0}),
                  ("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None},
                                     "usage": {"output_tokens": 20}}),
                  ("message_stop", {"type": "message_stop"})]
        payload = "".join("event: %s\ndata: %s\n\n" % (e, json.dumps(d)) for e, d in events).encode()
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
port = srv.server_address[1]

env = {k: v for k, v in os.environ.items() if not k.startswith(("ANTHROPIC_", "CLAUDE_", "CLAUDECODE"))}
env.update({"ANTHROPIC_BASE_URL": "http://127.0.0.1:%d" % port,
            "ANTHROPIC_API_KEY": "sk-ant-api03-mock-local-probe-not-a-real-key",
            "CLAUDE_CONFIG_DIR": tempfile.mkdtemp(prefix="cfg-"),
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_AUTOUPDATER": "1",
            "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1"})
out_path = prefix + ".stream.jsonl"
try:
    subprocess.run(["claude", "-p", "Run the scripted permission probes.", "--output-format", "stream-json",
                    "--verbose", "--permission-mode", "default", "--max-turns", "60",
                    "--allowedTools", "Bash(echo *)"],
                   cwd=launch_dir, env=env, stdout=open(out_path, "w"),
                   stderr=open(prefix + ".stderr.txt", "w"), timeout=240)
except subprocess.TimeoutExpired:
    pass
srv.shutdown()

uses, results = {}, {}
for line in open(out_path, encoding="utf-8", errors="replace"):
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue
    msg = ev.get("message")
    if not isinstance(msg, dict) or not isinstance(msg.get("content"), list):
        continue
    for b in msg["content"]:
        if not isinstance(b, dict):
            continue
        if b.get("type") == "tool_use" and b.get("name") == "Bash":
            uses[b["id"]] = ((b.get("input") or {}).get("command", ""), bool(ev.get("parent_tool_use_id")))
        elif b.get("type") == "tool_result":
            c = b.get("content")
            results[b.get("tool_use_id")] = c if isinstance(c, str) else \
                " ".join(x.get("text", "") for x in (c or []) if isinstance(x, dict))

for tid, (cmd, via_sub) in uses.items():
    txt = results.get(tid) or ""
    if "Permission to use Bash with command" in txt and "has been denied" in txt:
        verdict = "RULE-DENIED"
    elif "auto mode classifier" in txt:
        verdict = "CLASSIFIER"
    elif txt.lstrip().startswith("guard-"):
        verdict = "HOOK"
    else:
        verdict = "RAN"
    print("%s\t%s\t%s" % (verdict, "subagent" if via_sub else "main", cmd))
PYEOF

probe() { # probe <launch-dir> <tag> <probe...> — prints "VERDICT<TAB>via<TAB>command" lines
  python3 "$WORK/probe.py" "$1" "$WORK/$2" "${@:3}"
}
verdict_of() { # verdict_of <file> <via> <command>
  awk -F'\t' -v via="$2" -v cmd="$3" '$2 == via && $3 == cmd {print $1; found=1} END {if (!found) print "NO-CALL"}' "$1"
}

echo "-- S1: a session started at the product root"
probe "$P" root "echo $CANARY" "echo unrelated-control" > "$WORK/root.tsv" 2>"$WORK/root.err"
[[ "$(verdict_of "$WORK/root.tsv" main "echo $CANARY")" == "RULE-DENIED" ]] \
  && assert "S1a the canary rule is enforced at the product root" pass \
  || assert "S1a the canary rule was NOT enforced at the product root (see $WORK/root.err)" fail
[[ "$(verdict_of "$WORK/root.tsv" main "echo unrelated-control")" == "RAN" ]] \
  && assert "S1b an unrelated command still runs there" pass \
  || assert "S1b an unrelated command was blocked at the product root" fail

echo "-- S2: a session started in the DECLARED launch directory (the incident's directory)"
probe "$P/apps/backend" backend "echo $CANARY" "echo unrelated-control" --subagent "echo $CANARY" "echo unrelated-control" > "$WORK/be.tsv" 2>"$WORK/be.err"
[[ "$(verdict_of "$WORK/be.tsv" main "echo $CANARY")" == "RULE-DENIED" ]] \
  && assert "S2a the canary rule is enforced in the declared launch directory" pass \
  || assert "S2a the canary rule is NOT enforced in the declared launch directory" fail
[[ "$(verdict_of "$WORK/be.tsv" subagent "echo $CANARY")" == "RULE-DENIED" ]] \
  && assert "S2b it is enforced for a SUBAGENT there too (how an interactive engine runs its agents)" pass \
  || assert "S2b a subagent there escaped the rule" fail
[[ "$(verdict_of "$WORK/be.tsv" main "echo unrelated-control")" == "RAN" ]] \
  && assert "S2c an unrelated command still runs there" pass \
  || assert "S2c an unrelated command was blocked in the declared launch directory" fail

echo "-- S3: an UNdeclared subdirectory — the rendered file is what carries the rules"
probe "$P/apps/frontend" frontend "echo $CANARY" > "$WORK/fe.tsv" 2>"$WORK/fe.err"
if [[ "$(verdict_of "$WORK/fe.tsv" main "echo $CANARY")" == "RAN" ]]; then
  assert "S3 an undeclared subdirectory enforces nothing — declare it to cover it" pass
else
  assert "S3 an undeclared subdirectory behaved unexpectedly (Claude Code discovery may have changed)" fail
fi

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
