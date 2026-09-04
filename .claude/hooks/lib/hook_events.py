#!/usr/bin/env python3
"""Append one JSON event line for a Claude Code hook decision.

Session-scoped: <cache>/iad/hook-events/<project-slug>/<session-id>.jsonl — one session per
file. Private: directories 0700, files 0600 (explicit modes, not the caller's umask; existing
wider modes are tightened best-effort — only inside hook-events/). Append-safe: one fully
built line per write on an O_APPEND descriptor under flock, so parallel subagent hooks never
interleave rows. Privacy-safe: never stores raw command text, command hashes or raw
permission suggestions; IAD_HOOK_EVENTS_RAW=1 is the explicit default-off diagnostic that
adds cmd_raw. Never fails the caller: any error exits 0 silently.
    python3 hook_events.py --hook <name> --event <event> [--extra '<json object>']   (hook input JSON on stdin)
    python3 hook_events.py --self-test
"""
import datetime
import fcntl
import hashlib
import json
import os
import re
import stat
import sys

KEEP = ("session_id", "agent_id", "agent_type", "tool_use_id", "tool_name", "permission_mode")
DIR_MODE, FILE_MODE = 0o700, 0o600


def events_file(session_id):
    explicit = os.environ.get("IAD_HOOK_EVENTS_FILE")
    if explicit:
        return explicit
    root = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    slug = re.sub(r"[^A-Za-z0-9]", "-", root)
    sid = re.sub(r"[^A-Za-z0-9._-]", "", session_id or "") or "_no-session"
    base = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return os.path.join(base, "iad", "hook-events", slug, sid + ".jsonl")


def _private_dir(path):
    """mkdir -p with 0700; tighten an existing wider dir (best effort)."""
    os.makedirs(path, mode=DIR_MODE, exist_ok=True)
    try:
        if stat.S_IMODE(os.stat(path).st_mode) != DIR_MODE:
            os.chmod(path, DIR_MODE)
    except OSError:
        pass


def sha16(text):
    return hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()[:16]


def build_event(args, payload):
    try:
        extra = json.loads(args.get("--extra") or "{}")
    except ValueError:
        extra = {}
    event = {"ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
             "event": args.get("--event", ""), "hook": args.get("--hook", "")}
    for key in KEEP:
        event[key] = str(payload.get(key, "") or "")
    if event["event"] == "permission_request":
        sugg = payload.get("permission_suggestions") or []
        event["suggestion_count"] = len(sugg)
        event["suggestion_types"] = sorted({str(s.get("type", "?")) for s in sugg if isinstance(s, dict)})
        event["suggestions_sha"] = sha16(json.dumps(sugg, sort_keys=True)) if sugg else ""
    event.update(extra)
    if os.environ.get("IAD_HOOK_EVENTS_RAW") == "1":      # explicit, default-off diagnostic
        tool_input = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
        event["cmd_raw"] = str(tool_input.get("command", "") or "")[:2000]
    return event


def append_event(path, event):
    parent = os.path.dirname(path)
    if not os.environ.get("IAD_HOOK_EVENTS_FILE"):
        base = os.path.dirname(parent)               # …/hook-events
        _private_dir(base)
        _private_dir(parent)                          # …/hook-events/<slug>
    else:
        os.makedirs(parent, exist_ok=True)
    line = json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, FILE_MODE)
    try:
        if stat.S_IMODE(os.fstat(fd).st_mode) != FILE_MODE:
            try:
                os.fchmod(fd, FILE_MODE)
            except OSError:
                pass
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            os.write(fd, line.encode("utf-8"))
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def main():
    args = dict(zip(sys.argv[1::2], sys.argv[2::2]))
    try:
        payload = json.load(sys.stdin)
    except Exception:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    event = build_event(args, payload)
    append_event(events_file(event["session_id"]), event)


def _self_test():
    import subprocess
    import tempfile
    fails = []
    with tempfile.TemporaryDirectory() as tmp:
        env = dict(os.environ, XDG_CACHE_HOME=tmp, CLAUDE_PROJECT_DIR="/home/u/Git/incredible_auto_dev")
        env.pop("IAD_HOOK_EVENTS_FILE", None)
        env.pop("IAD_HOOK_EVENTS_RAW", None)
        payload = json.dumps({"session_id": "sess-1", "agent_id": "a1", "agent_type": "developer",
                              "tool_use_id": "t1", "tool_name": "Bash", "permission_mode": "auto",
                              "tool_input": {"command": "cd apps && sed -i s/a/b/ x.py SECRET=1"},
                              "permission_suggestions": [{"type": "addRules", "rules": [{"ruleContent": "sed *"}]}]})
        run = lambda ev: subprocess.run([sys.executable, __file__, "--hook", "t", "--event", ev, "--extra", '{"rule":"C1"}'],
                                        input=payload, text=True, env=env, capture_output=True)
        r = run("hygiene_deny")
        f = os.path.join(tmp, "iad", "hook-events", "-home-u-Git-incredible-auto-dev", "sess-1.jsonl")
        if r.returncode != 0 or r.stdout:
            fails.append("writer must exit 0 with empty stdout: rc=%s out=%r" % (r.returncode, r.stdout))
        if not os.path.isfile(f):
            fails.append("session file not created at %s" % f)
        else:
            for d in (os.path.dirname(os.path.dirname(f)), os.path.dirname(f)):
                if stat.S_IMODE(os.stat(d).st_mode) != DIR_MODE:
                    fails.append("dir mode %o != 0700 for %s" % (stat.S_IMODE(os.stat(d).st_mode), d))
            if stat.S_IMODE(os.stat(f).st_mode) != FILE_MODE:
                fails.append("file mode %o != 0600" % stat.S_IMODE(os.stat(f).st_mode))
            row = json.loads(open(f, encoding="utf-8").read().splitlines()[0])
            for forbidden in ("cmd_sha", "cmd_raw"):
                if forbidden in row:
                    fails.append("default schema must not contain %s" % forbidden)
            if "SECRET" in json.dumps(row) or "ruleContent" in json.dumps(row):
                fails.append("event leaks command or suggestion text: %r" % row)
            if row.get("rule") != "C1" or row.get("agent_type") != "developer":
                fails.append("extra/attribution fields missing: %r" % row)
        run("permission_request")
        row = json.loads(open(f, encoding="utf-8").read().splitlines()[1])
        if row.get("suggestion_count") != 1 or row.get("suggestion_types") != ["addRules"] or not row.get("suggestions_sha"):
            fails.append("permission_request summary fields wrong: %r" % row)
        # widened file/dir get tightened best-effort
        os.chmod(f, 0o644)
        os.chmod(os.path.dirname(f), 0o755)
        run("hygiene_fail_open")
        if stat.S_IMODE(os.stat(f).st_mode) != FILE_MODE or stat.S_IMODE(os.stat(os.path.dirname(f)).st_mode) != DIR_MODE:
            fails.append("existing wider modes were not tightened")
        # concurrent appends: 8 processes x 50 events, every row must parse, none interleaved
        procs = [subprocess.Popen([sys.executable, __file__, "--stress", "50", "--event", "hygiene_deny"],
                                  stdin=subprocess.PIPE, text=True, env=env) for _ in range(8)]
        for p in procs:
            p.communicate(payload)
        lines = open(f, encoding="utf-8").read().splitlines()
        bad = sum(1 for l in lines if not l.startswith("{") or not l.endswith("}") or _bad_json(l))
        if len(lines) != 3 + 400 or bad:
            fails.append("concurrent append: %d lines (expected 403), %d malformed" % (len(lines), bad))
        # explicit override + no-session fallback
        env2 = dict(env, IAD_HOOK_EVENTS_FILE=os.path.join(tmp, "override.jsonl"))
        subprocess.run([sys.executable, __file__, "--hook", "t", "--event", "hygiene_deny"], input="{}", text=True, env=env2)
        if not os.path.isfile(os.path.join(tmp, "override.jsonl")):
            fails.append("IAD_HOOK_EVENTS_FILE override not honoured")
        subprocess.run([sys.executable, __file__, "--hook", "t", "--event", "hygiene_deny"], input="{}", text=True, env=env)
        if not os.path.isfile(os.path.join(tmp, "iad", "hook-events", "-home-u-Git-incredible-auto-dev", "_no-session.jsonl")):
            fails.append("_no-session fallback file not created")
    for x in fails:
        print("FAIL " + x)
    print("hook_events self-test: %d failures" % len(fails))
    return 1 if fails else 0


def _bad_json(line):
    try:
        json.loads(line)
        return False
    except ValueError:
        return True


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        sys.exit(_self_test())
    if len(sys.argv) > 2 and sys.argv[1] == "--stress":       # self-test helper: N sequential events
        try:
            payload = json.load(sys.stdin)
            args = dict(zip(sys.argv[3::2], sys.argv[4::2]))
            for _ in range(int(sys.argv[2])):
                append_event(events_file(payload.get("session_id", "")), build_event(args, payload))
        except Exception:
            pass
        sys.exit(0)
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
