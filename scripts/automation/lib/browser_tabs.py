#!/usr/bin/env python3
"""browser_tabs.py — deterministic CDP tab teardown for the QA browser lanes.

The engine (never an agent) closes the tabs a browser dispatch used, right
after the dispatch returns. Two backends, two commands:

  close-all    --port P [--pid PID] [--wait-exit S]
      Headless engine: the lane's pinned Chrome is ours, so close EVERY page
      over CDP (GET /json → GET /json/close/<id>) and wait for the browser to
      exit on its own — a clean exit, so the profile is not marked Crashed and
      Chrome does not restore the QA tabs on its next launch. Prints one JSON
      object: {"closed_tabs", "remaining_tabs", "clean_exit"}.

  close-origin --frontend URL --profile-root DIR [--timeout S]
      Interactive pump: the pump session's MCP server owns the browser, so scan
      DIR/*.meta.json for live browsers and close only the pages whose EXACT
      normalized origin equals the frontend URL's origin, plus that browser's
      blank pages (about:blank / new-tab) — and only when at least one app tab
      matched. Foreign origins are never closed; no process is ever killed.
      Prints one JSON line per browser acted on:
      {"profile", "port", "origin", "closed_tabs", "remaining_tabs"}.

  origin URL   → prints the normalized origin ("" when not an http(s) URL).
  --self-test  → offline unit checks (run-evals.sh).

Origin normalization = lowercase scheme + normalized host + effective port
(80/443 filled in for http/https). `localhost`, `127.0.0.1` and `::1` are one
host because the lane scripts' frontend-URL derivation already treats the local
frontend that way; no other host equivalence exists. Path, query and fragment
never matter. `http://localhost:3000` is NOT `http://localhost:30000`.

Never raises out to the caller: every failure degrades to "nothing closed".
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.request
from urllib.parse import urlsplit

_LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1"}
_DEFAULT_PORT = {"http": 80, "https": 443}
_BLANK_PREFIXES = ("about:blank", "chrome://newtab", "chrome://new-tab-page")


def normalized_origin(url):
    """scheme://host:port for an http(s) URL, else None."""
    if not isinstance(url, str):
        return None
    try:
        parts = urlsplit(url.strip())
        scheme = (parts.scheme or "").lower()
        if scheme not in _DEFAULT_PORT:
            return None
        host = (parts.hostname or "").lower()
        if not host:
            return None
        if host in _LOCAL_HOSTS:
            host = "localhost"
        port = parts.port if parts.port is not None else _DEFAULT_PORT[scheme]
    except ValueError:
        return None
    return f"{scheme}://{host}:{port}"


def is_blank(url):
    return isinstance(url, str) and url.startswith(_BLANK_PREFIXES)


def select_targets(pages, target_origin):
    """Pages to close for one browser: exact-origin matches, plus blank pages
    only when at least one page matched (a blank tab in a browser that never
    touched the app is somebody else's)."""
    if not target_origin:
        return []
    matched = [t for t in pages if normalized_origin(t.get("url", "")) == target_origin]
    if not matched:
        return []
    blanks = [t for t in pages if is_blank(t.get("url", ""))]
    return matched + blanks


# ── CDP over HTTP (the same two calls the plugin's tabs.js makes) ─────────────
def _get(port, path, timeout):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def list_pages(port, timeout=3.0):
    data = json.loads(_get(port, "/json", timeout))
    if not isinstance(data, list):
        return []
    return [t for t in data if isinstance(t, dict) and t.get("type") == "page"]


def close_page(port, target_id, timeout=3.0):
    if not target_id:
        return False
    try:
        _get(port, f"/json/close/{target_id}", timeout)
        return True
    except Exception:
        return False


def _pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _port_open(port, timeout=1.0):
    try:
        _get(port, "/json/version", timeout)
        return True
    except Exception:
        return False


def cmd_close_all(port, pid, wait_exit):
    try:
        pages = list_pages(port)
    except Exception:
        pages = []
    closed = sum(1 for t in pages if close_page(port, t.get("id", "")))
    deadline = time.time() + max(0.0, wait_exit)
    clean = False
    while True:
        gone = (not _pid_alive(pid)) if pid else (not _port_open(port))
        if gone:
            clean = True
            break
        if time.time() >= deadline:
            break
        time.sleep(0.25)
    remaining = 0
    if not clean:
        try:
            remaining = len(list_pages(port))
        except Exception:
            remaining = 0
    print(json.dumps({"closed_tabs": closed, "remaining_tabs": remaining, "clean_exit": clean}))
    return 0


def cmd_close_origin(frontend, profile_root, timeout):
    target = normalized_origin(frontend)
    if not target or not os.path.isdir(profile_root):
        return 0
    for name in sorted(os.listdir(profile_root)):
        if not name.endswith(".meta.json"):
            continue
        try:
            with open(os.path.join(profile_root, name), encoding="utf-8") as fh:
                meta = json.load(fh)
        except Exception:
            continue
        port, pid = meta.get("port"), meta.get("pid")
        if not isinstance(port, int) or not isinstance(pid, int) or not _pid_alive(pid):
            continue
        try:
            pages = list_pages(port, timeout)
        except Exception:
            continue
        targets = select_targets(pages, target)
        if not targets:
            continue
        closed = sum(1 for t in targets if close_page(port, t.get("id", ""), timeout))
        try:
            remaining = len(list_pages(port, timeout))
        except Exception:
            remaining = 0
        print(json.dumps({"profile": name[: -len(".meta.json")], "port": port, "origin": target,
                          "closed_tabs": closed, "remaining_tabs": remaining}))
    return 0


# ── self-test ─────────────────────────────────────────────────────────────────
def _self_test():
    app = normalized_origin("http://localhost:3000")
    cases = [
        ("exact app origin, path differs", "http://localhost:3000/x?y=1#z", True),
        ("same host, other port", "http://localhost:3001/", False),
        ("prefix look-alike :30000", "http://localhost:30000/", False),
        ("foreign https origin", "https://example.com/", False),
        ("127.0.0.1 normalizes to localhost", "http://127.0.0.1:3000/y", True),
        ("[::1] normalizes to localhost", "http://[::1]:3000/", True),
        ("scheme differs", "https://localhost:3000/", False),
        ("uppercase host", "HTTP://LOCALHOST:3000/", True),
    ]
    for label, url, expect in cases:
        got = normalized_origin(url) == app
        assert got == expect, f"{label}: {url} -> {normalized_origin(url)} (expected match={expect})"
    assert normalized_origin("http://example.com") == "http://example.com:80", "default http port"
    assert normalized_origin("https://Example.com:443/p") == "https://example.com:443", "explicit default https port"
    assert normalized_origin("about:blank") is None, "about:blank has no origin"
    assert normalized_origin("chrome://newtab/") is None, "chrome:// has no origin"
    assert normalized_origin("http://[bad") is None, "malformed URL"
    assert normalized_origin("http://localhost:notaport/") is None, "garbage port"
    assert normalized_origin(None) is None, "non-string"
    assert is_blank("about:blank") and is_blank("chrome://newtab/") and not is_blank("http://localhost:3000/")
    pages = [
        {"id": "a", "type": "page", "url": "http://localhost:3000/x"},
        {"id": "b", "type": "page", "url": "http://localhost:30000/"},
        {"id": "c", "type": "page", "url": "https://example.com/"},
        {"id": "d", "type": "page", "url": "http://127.0.0.1:3000/y"},
        {"id": "e", "type": "page", "url": "about:blank"},
    ]
    assert [t["id"] for t in select_targets(pages, app)] == ["a", "d", "e"], "match + blank only"
    foreign_only = [{"id": "f", "type": "page", "url": "https://foo.test/"},
                    {"id": "g", "type": "page", "url": "about:blank"}]
    assert select_targets(foreign_only, app) == [], "no app tab → blank pages are not ours"
    assert select_targets(pages, None) == [], "no target origin → nothing"
    print("browser_tabs self-test: OK")
    return 0


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if argv[0] == "--self-test":
        return _self_test()
    cmd, rest = argv[0], argv[1:]
    opts, positional = {}, []
    i = 0
    while i < len(rest):
        if rest[i].startswith("--") and i + 1 < len(rest):
            opts[rest[i][2:]] = rest[i + 1]
            i += 2
        else:
            positional.append(rest[i])
            i += 1
    try:
        if cmd == "origin":
            print(normalized_origin(positional[0]) or "" if positional else "")
            return 0
        if cmd == "close-all":
            pid = int(opts["pid"]) if opts.get("pid") else None
            return cmd_close_all(int(opts["port"]), pid, float(opts.get("wait-exit", "5")))
        if cmd == "close-origin":
            return cmd_close_origin(opts.get("frontend", ""), opts.get("profile-root", ""),
                                    float(opts.get("timeout", "3")))
    except Exception as exc:  # never fail a QA lane over browser hygiene
        print(f"[browser_tabs] {cmd} failed: {exc}", file=sys.stderr)
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
