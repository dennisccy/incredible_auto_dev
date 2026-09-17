#!/usr/bin/env python3
"""demo_runner.py — deterministic browser demo executor.

Reads an executable demo-script JSON (authored by the demo-narrator agent) and
drives Chrome via Playwright. NO model is in the execution loop, so it cannot
loop or stall on round-trips.

Modes:
  live          headed Chrome, press-Enter-to-advance, narration to the CLI.
  record        headless, auto-wait, screenshots → reports/demo/<id>/step-NN.png.
  session-live  same as live, for a whole-product (session) demo JSON.

The runner re-emits demo-script.md + demo-results.md byte-compatibly with the
existing HTML gallery renderer (render_iteration_summary.py), so that renderer
needs no changes.

Self-test (no browser, no network):
  python3 demo_runner.py self-test

Exit codes: 0 ok/soft-skip · 2 bad args/JSON · 3 playwright missing · 4 no DISPLAY (live)
· 5 verify found ≥1 FAIL · 6 browser infrastructure failure (launch/crash — verify only;
callers route replay journeys back to the LLM lane so nothing is silently unverified).

HARD-3 side-effect observer (verify mode only, active when --side-effects-out and/or
--side-effects-run-out is given): every journey's browser context is watched for
same-project POST/PUT/PATCH/DELETE requests (see classify_request). Each replayed row's
Actual cell gains a `; side effects: …` suffix (the 8-cell row shape is unchanged), the
engine-owned sidecar runs/goal-session-<sid>/state/journey-side-effects.json is updated
read-modify-write under a directory lock, and a per-run record is written for the lane's
telemetry. Observer failures never change a replay verdict.
"""
from __future__ import annotations

import contextlib
import datetime
import functools
import hashlib
import ipaddress
import json
import os
import re
import socket
import sys
import time
from pathlib import Path
from urllib.parse import urljoin, urlsplit, urlunsplit

# ── pure logic (deterministic, browser-free) ─────────────────────────────────

_LOCAL_HOSTS = {"localhost", "127.0.0.1", "0.0.0.0"}
_VALID_ACTIONS = {"goto", "click", "fill", "expect", "wait_for"}


def normalize_url(base_url: str, url: str) -> str:
    """Resolve a step URL against the real base_url.

    Relative paths are joined onto base_url. Absolute URLs pointing at a local
    host (localhost/127.0.0.1) are rewritten onto base_url's host:port — this is
    the fix for the start scripts' offset dev-port (a hardcoded :3000 from a QA
    artifact would otherwise hit the wrong port). Genuinely external absolute
    URLs are left untouched.
    """
    base = urlsplit(base_url)
    u = urlsplit(url or "")
    if u.scheme and u.netloc:
        if (u.hostname or "") in _LOCAL_HOSTS:
            return urlunsplit((base.scheme, base.netloc, u.path or "/", u.query, u.fragment))
        return url
    path = u.path or "/"
    if not path.startswith("/"):
        path = "/" + path
    return urlunsplit((base.scheme, base.netloc, path, u.query, u.fragment))


def validate_script(data: object) -> list[str]:
    """Return a list of human-readable problems; empty list means valid."""
    errors: list[str] = []
    if not isinstance(data, dict):
        return ["script is not a JSON object"]
    if not isinstance(data.get("schema_version"), int):
        errors.append("missing or non-integer schema_version")
    steps = data.get("steps")
    if data.get("not_yet"):
        # A "nothing to show yet" script legitimately has no steps.
        if steps is not None and not isinstance(steps, list):
            errors.append("steps must be a list when present")
        return errors
    if not isinstance(steps, list) or not steps:
        errors.append("missing or empty steps[]")
        return errors
    for i, step in enumerate(steps):
        where = f"step[{i}]"
        if not isinstance(step, dict):
            errors.append(f"{where} is not an object")
            continue
        action = step.get("action")
        if not isinstance(action, dict):
            errors.append(f"{where} missing action object")
            continue
        atype = action.get("type")
        if atype not in _VALID_ACTIONS:
            errors.append(f"{where} invalid action type {atype!r}")
            continue
        if atype == "goto" and not action.get("url"):
            errors.append(f"{where} goto requires url")
        if atype in ("click", "fill") and not isinstance(action.get("target"), dict):
            errors.append(f"{where} {atype} requires a target object")
        if atype == "fill" and not action.get("text"):
            errors.append(f"{where} fill requires text")
    return errors


def resolve_spec(target: object) -> list[tuple]:
    """Map a target hint to an ordered list of locator specs (primary first,
    then automatic degradation). Each spec is (kind, role_or_None, value).
    The Playwright layer tries them in order and uses the first that resolves.
    """
    if not isinstance(target, dict):
        return []
    if "role" in target:
        name = target.get("name", "")
        specs = [("role", target["role"], name)]
        if name:
            specs.append(("text", None, name))  # degrade role→text
        return specs
    if "text" in target:
        return [("text", None, target["text"])]
    if "label" in target:
        return [("label", None, target["label"]), ("placeholder", None, target["label"])]
    if "placeholder" in target:
        return [("placeholder", None, target["placeholder"])]
    if "testid" in target:
        return [("testid", None, target["testid"])]
    if "css" in target:
        return [("css", None, target["css"])]
    return []


def compute_verdict(any_captured: bool, has_soft_notes: bool, not_yet: bool) -> str:
    if not_yet:
        return "NOT_YET"
    if not any_captured:
        return "SKIPPED"
    if has_soft_notes:
        return "RECORDED_WITH_NOTES"
    return "RECORDED"


def compute_regression_verdict(results: list[dict]) -> str:
    """Overall verdict for a deterministic regression-replay run (verify mode).

    Unlike the showcase verdicts above, replay treats a journey's `expect`s as
    HARD assertions: FAIL if any journey failed; SKIPPED if none ran or all were
    skipped (e.g. no golden script on file); otherwise PASS."""
    verdicts = [r.get("verdict") for r in results]
    if not verdicts:
        return "SKIPPED"
    if "FAIL" in verdicts:
        return "FAIL"
    if all(v == "SKIP" for v in verdicts):
        return "SKIPPED"
    return "PASS"


# ── HARD-3: side-effect observer (pure, deterministic, browser-free) ─────────
# A journey MUTATES persisted state when, during its deterministic replay, the
# browser sends a same-project POST/PUT/PATCH/DELETE through any channel a page
# can write with: fetch/xhr, a document (form) navigation, a beacon (ping), or an
# unclassified request. Observation outranks the owner's declaration in
# docs/goal.md: an owner `none` never hides an observed, unlisted mutation. The
# ONLY owner remedy for a legitimately read-only POST is the digest-tracked
# exception file below, and every applied exception — read-only or auth — is
# reported, never silent.
# Only {method, path} is ever recorded — never a query string, header or body.
_MUTATING_METHODS = frozenset({"POST", "PUT", "PATCH", "DELETE"})
_SIDE_EFFECT_RESOURCE_TYPES = frozenset({"fetch", "xhr", "document", "ping", "beacon", "other", ""})
# Development-server plumbing (HMR, overlays) — never product state.
_DEV_ASSET_PREFIXES = ("/_next/", "/__nextjs", "/sockjs-node", "/@vite", "/__vite")
# Session plumbing a journey's own sign-in performs. An entry names an ENDPOINT,
# not a subtree: once an API prefix (/api, /api/v<N>, /v<N>) is set aside on both
# sides, a request matches entry E only when the rest of its path is
#   * E itself                               /api/login, /api/v1/session, /csrf
#   * E plus ONE sign-in step                /auth/login, /api/token/refresh
#   * E plus callback|signin plus a provider name, when E ends in "auth"
#     (NextAuth)                             /api/auth/callback/credentials
# Anything else under E is a real change: /api/auth/users, /auth/register,
# /api/session/all, /api/login/history/clear, /api/auth/users/5. Only POST and
# DELETE (sign-in, token refresh, sign-out) are ever excluded — a PUT or PATCH on
# such a path is a real change. An ambiguous path (dot segment, encoded
# separator, backslash, empty segment) is never excluded.
# CHAIN_SIDE_EFFECT_IGNORE_PATHS (comma list) REPLACES this list, with the same
# endpoint semantics; set-but-empty disables every auth exclusion; an entry that
# names only an API root (/api, /api/v1, /v2) or '/', or that is not a plain path
# (dot segment, encoded separator, backslash, wildcard, query, whitespace), is
# REJECTED and reported.
_DEFAULT_AUTH_IGNORE_PATHS = ("/login", "/logout", "/auth", "/session", "/token", "/csrf")
_AUTH_IGNORE_METHODS = frozenset({"POST", "DELETE"})
# The one step an excluded endpoint may take below itself (sign-in, sign-out,
# token / session refresh, CSRF, an OAuth callback).
_AUTH_PLUMBING_STEPS = frozenset({"login", "logout", "signin", "signout", "sign-in", "sign-out", "sign_in",
                                  "sign_out", "session", "token", "refresh", "csrf", "callback"})
# NextAuth's provider forms below an ".../auth" endpoint: callback/<provider>, signin/<provider>.
_AUTH_PROVIDER_STEPS = frozenset({"callback", "signin"})
_PROVIDER_NAME_RE = re.compile(r"[a-z][a-z0-9_-]{0,39}")
_NOT_A_PLAIN_PATH_RE = re.compile(r"[*?#\s]")
_API_VERSION_RE = re.compile(r"v\d+(?:\.\d+)*", re.I)
_ID_SEGMENT_RE = re.compile(
    r"\d+|[0-9a-f]{8}(?:-?[0-9a-f]{4}){3}-?[0-9a-f]{12}|[0-9a-f]{12,}|(?=[A-Za-z0-9_-]*\d)[A-Za-z0-9_-]{16,}", re.I)
# Hosts that are part of the project when the base URL is itself local: loopback,
# private-network and link-local addresses, single-label and local-only names.
_LOCAL_HOST_SUFFIXES = (".localhost", ".local", ".internal", ".lan", ".home.arpa", ".test")
# Owner-authored, digest-tracked exceptions: one `METHOD /path-prefix` per line.
READONLY_ENDPOINTS_RELPATH = "project-extensions/side-effects/read-only-endpoints.txt"
SIDE_EFFECT_SAMPLE_CAP = 20
SIDE_EFFECT_HISTORY_CAP = 5
SIDE_EFFECT_GOLDEN_CAP = 50
SIDE_EFFECT_CLEARED_INDEX_CAP = 500
MERGED_RUNS_CAP = 100_000  # a sanity bound: every run id a session ever merged
# Bumped whenever classify_candidate's rules change: a recorded observation
# classified under another version is always re-classified by the ledger.
# 3: auth exclusions name endpoints, not subtrees; an empty segment is ambiguous.
SIDE_EFFECT_CLASSIFIER_VERSION = 3
UNIDENTIFIED_GOLDEN = "unidentified"
# A path that walks up, hides a walk-up or hides a separator can never be matched
# against an exception, an auth exclusion or a dev-asset prefix — it is
# classified mutating (fail closed).
_DOT_SEGMENTS = frozenset({".", "..", "%2e", "%2e%2e", ".%2e", "%2e."})
_ENCODED_PATH_CHAR_RE = re.compile(r"%(?:2f|5c|2e)", re.I)
_SHA256_RE = re.compile(r"[0-9a-f]{64}")


def _path_segments(path: str) -> list[str]:
    return [s for s in (path or "").split("/") if s]


def _has_dot_segment(segments: list[str]) -> bool:
    return any(s.lower() in _DOT_SEGMENTS for s in segments)


def _path_is_ambiguous(path: str) -> bool:
    """A path whose meaning depends on how a server decodes or normalizes it:
    a backslash, an encoded separator or dot, a dot segment, or an empty
    segment ("//")."""
    p = path or ""
    return ("\\" in p or "//" in p or bool(_ENCODED_PATH_CHAR_RE.search(p))
            or _has_dot_segment(_path_segments(p)))


def _strip_api_prefix(segments: list[str]) -> list[str]:
    s = list(segments)
    if s and s[0].lower() == "api":
        s = s[1:]
    if s and _API_VERSION_RE.fullmatch(s[0]):
        s = s[1:]
    return s


def side_effect_ignore_paths_report(env=None) -> "tuple[tuple, tuple]":
    """(effective, rejected) auth/session exclusions. UNSET → the documented
    default list; SET (even empty) → exactly the listed paths, minus every entry
    that could silence more than session plumbing or does not name one plain
    path ('/', an API root such as /api or /api/v1, a dot segment, an encoded
    separator, a backslash, an empty segment, a wildcard, a query or
    whitespace), which is REJECTED and reported rather than applied."""
    env = os.environ if env is None else env
    raw = env.get("CHAIN_SIDE_EFFECT_IGNORE_PATHS")
    if raw is None:
        return _DEFAULT_AUTH_IGNORE_PATHS, ()
    out: list[str] = []
    rejected: list[str] = []
    for part in raw.split(","):
        part = part.strip()
        if not part:
            continue
        segs = _path_segments(part)
        if (not segs or _path_is_ambiguous(part) or _NOT_A_PLAIN_PATH_RE.search(part)
                or not _strip_api_prefix(segs)):
            if part not in rejected:
                rejected.append(part)
            continue
        p = "/" + "/".join(segs)
        if p not in out:
            out.append(p)
    return tuple(out), tuple(rejected)


def side_effect_ignore_paths(env=None) -> tuple:
    """The auth/session exclusions in force (see side_effect_ignore_paths_report)."""
    return side_effect_ignore_paths_report(env)[0]


def parse_readonly_endpoints(text: str) -> "tuple[list, list]":
    """(entries, invalid) from the owner's exception file. entries are
    (METHOD, /normalized/prefix) tuples; invalid are (lineno, text, reason) and
    are REPORTED, never applied."""
    entries: list = []
    invalid: list = []
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 2:
            invalid.append((lineno, raw.strip(), "expected exactly 'METHOD /path-prefix'"))
            continue
        method, prefix = parts[0].upper(), parts[1].split("?", 1)[0]
        if method not in _MUTATING_METHODS:
            invalid.append((lineno, raw.strip(),
                            f"method {parts[0]!r} is not POST/PUT/PATCH/DELETE — only a mutating method needs an exception"))
            continue
        if not prefix.startswith("/"):
            invalid.append((lineno, raw.strip(), "the path prefix must start with '/'"))
            continue
        segs = _path_segments(prefix)
        if not segs:
            invalid.append((lineno, raw.strip(),
                            "a bare '/' would silence every request of that method — name the endpoint"))
            continue
        if _path_is_ambiguous(prefix):
            invalid.append((lineno, raw.strip(),
                            "dot segments, backslashes, encoded separators and empty segments are not allowed "
                            "in an exception"))
            continue
        entry = (method, "/" + "/".join(segs))
        if entry not in entries:
            entries.append(entry)
    return entries, invalid


def load_readonly_endpoints(path) -> dict:
    """The exception file as a dict: present / sha256 (over the raw bytes — the
    declaration digest input) / entries / invalid / error. Absent is normal;
    unreadable is an ERROR (the caller treats its ledger as incomplete)."""
    info = {"path": str(path) if path else None, "present": False, "sha256": None,
            "entries": [], "invalid": [], "error": None}
    if not path:
        return info
    try:
        data = Path(path).read_bytes()
    except FileNotFoundError:
        return info
    except OSError as exc:
        info["present"] = True
        info["error"] = f"unreadable: {exc.strerror or exc}"
        return info
    info["present"] = True
    info["sha256"] = hashlib.sha256(data).hexdigest()
    entries, invalid = parse_readonly_endpoints(data.decode("utf-8", errors="replace"))
    info["entries"] = [list(e) for e in entries]
    info["invalid"] = [{"line": i[0], "text": i[1], "reason": i[2]} for i in invalid]
    return info


def _auth_endpoint_match(body: list, entry: list) -> bool:
    """Does a request path (API prefix set aside, lower-cased) name the excluded
    endpoint itself, one sign-in step below it, or a provider callback / sign-in
    below an '.../auth' endpoint?"""
    if body[:len(entry)] != entry:
        return False
    rest = body[len(entry):]
    if not rest:
        return True
    if len(rest) == 1:
        return rest[0] in _AUTH_PLUMBING_STEPS
    return (len(rest) == 2 and entry[-1] == "auth" and rest[0] in _AUTH_PROVIDER_STEPS
            and bool(_PROVIDER_NAME_RE.fullmatch(rest[1])) and not _ID_SEGMENT_RE.fullmatch(rest[1]))


def classify_candidate(method: str, path: str, ignored_paths, readonly_endpoints) -> str:
    """Class of a request ALREADY known to be a same-project mutating-method
    request. Pure; shared with the ledger builder (goal_gate.py), which
    re-checks recorded requests when the exception file, the auth list or these
    rules (SIDE_EFFECT_CLASSIFIER_VERSION) changed since they were observed."""
    raw = path or "/"
    if _path_is_ambiguous(raw):
        return "mutating"
    segs = _path_segments(raw)
    m = (method or "").upper()
    if m in _AUTH_IGNORE_METHODS:
        body = [s.lower() for s in _strip_api_prefix(segs)]
        for ip in ignored_paths or ():
            needle = [s.lower() for s in _strip_api_prefix(_path_segments(str(ip)))]
            if needle and _auth_endpoint_match(body, needle):
                return "ignored-auth"
    for em, ep in readonly_endpoints or ():
        eps = _path_segments(ep)
        if str(em).upper() == m and eps and segs[:len(eps)] == eps:
            return "ignored-readonly"
    return "mutating"


@functools.lru_cache(maxsize=1)
def _machine_host_names() -> frozenset:
    names = set()
    with contextlib.suppress(OSError):
        h = socket.gethostname().lower().rstrip(".")
        if h:
            names.update({h, h.split(".", 1)[0]})
    return frozenset(names)


def _is_local_host(host: str) -> bool:
    h = (host or "").strip("[]").rstrip(".").lower()
    if not h:
        return False
    if h == "localhost" or h.endswith(_LOCAL_HOST_SUFFIXES):
        return True
    try:
        ip = ipaddress.ip_address(h)
    except ValueError:
        return "." not in h or h in _machine_host_names()
    return ip.is_loopback or ip.is_private or ip.is_link_local or ip.is_unspecified


def _same_project_host(host: str, base_host: str) -> bool:
    if not host:
        return False
    if host == base_host:
        return True
    return _is_local_host(host) and (not base_host or _is_local_host(base_host))


def classify_request(method, resource_type, url, base_url, ignored_paths=None,
                     readonly_endpoints=()) -> "str | None":
    """'mutating' | 'ignored-auth' | 'ignored-readonly' | None (not a side effect).

    None: a non-mutating method, a sub-resource type (image, script, style, …),
    a non-http(s) URL, a host outside the project (external analytics/CDN), or
    development plumbing. Same project = the base URL's host, or — when the base
    is itself local — any local host (loopback, private network, link-local,
    single-label or local-only name, this machine's name): the frontend on :3xxx
    calling the backend on :8xxx or on a LAN address."""
    m = (method or "").upper()
    if m not in _MUTATING_METHODS:
        return None
    if (resource_type or "").lower() not in _SIDE_EFFECT_RESOURCE_TYPES:
        return None
    u = urlsplit(url or "")
    if not u.scheme:
        u = urlsplit(urljoin(base_url or "", url or ""))
    if (u.scheme or "").lower() not in ("http", "https"):
        return None
    host = (u.hostname or "").lower()
    base_host = (urlsplit(base_url or "").hostname or "").lower()
    if not _same_project_host(host, base_host):
        return None
    path = u.path or "/"
    if not _path_is_ambiguous(path) and path.startswith(_DEV_ASSET_PREFIXES):
        return None
    if ignored_paths is None:
        ignored_paths = side_effect_ignore_paths()
    return classify_candidate(m, path, ignored_paths, readonly_endpoints)


def golden_identity(script) -> "str | None":
    """sha256 of a golden script's EXECUTABLE content (steps + default timeout)
    as canonical JSON, so a cosmetic rewrite (key order, whitespace, name) keeps
    the identity. Only a complete clean replay of the SAME identity may clear a
    mutation recorded for it."""
    if not isinstance(script, dict):
        return None
    try:
        payload = json.dumps({"steps": script.get("steps"), "default_timeout_ms": script.get("default_timeout_ms")},
                             sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    except (TypeError, ValueError):
        return None
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


class SideEffectRecorder:
    """Per-journey request observer. `on_request` is the Playwright handler; it
    never raises (a broken request object is counted, not propagated)."""

    def __init__(self, base_url, ignored_paths=None, readonly_endpoints=(), cap=SIDE_EFFECT_SAMPLE_CAP):
        self.base_url = base_url
        self.ignored_paths = side_effect_ignore_paths() if ignored_paths is None else tuple(ignored_paths)
        self.readonly_endpoints = [tuple(e) for e in (readonly_endpoints or ())]
        self.cap = cap
        self._counts = {"mutating": 0, "ignored-auth": 0, "ignored-readonly": 0}
        self._pairs: dict = {}
        self._applied = {"ignored-readonly": {}, "ignored-auth": {}}
        self._truncated = False
        self._errors = 0

    def on_request(self, request) -> None:
        try:
            method = request.method
            url = request.url
            cls = classify_request(method, request.resource_type, url, self.base_url,
                                   self.ignored_paths, self.readonly_endpoints)
            if cls is None:
                return
            u = urlsplit(url or "")
            if not u.scheme:
                u = urlsplit(urljoin(self.base_url or "", url or ""))
            key = (str(method).upper(), u.path or "/")
            self._counts[cls] += 1
            applied = self._applied.get(cls)
            if applied is not None and key not in applied and len(applied) < self.cap:
                applied[key] = {"method": key[0], "path": key[1]}
            rec = self._pairs.get(key)
            if rec is not None:
                rec["count"] += 1
            elif len(self._pairs) < self.cap:
                self._pairs[key] = {"method": key[0], "path": key[1], "class": cls, "count": 1}
            else:
                self._truncated = True
        except Exception:  # noqa: BLE001 — observer failures are per request, never fatal
            self._errors += 1

    def summary(self) -> dict:
        return {
            "mutating_count": self._counts["mutating"],
            "auth_count": self._counts["ignored-auth"],
            "readonly_count": self._counts["ignored-readonly"],
            "requests": [dict(r) for r in self._pairs.values()],
            "truncated": self._truncated,
            "exceptions_applied": [dict(e) for e in self._applied["ignored-readonly"].values()],
            "auth_ignored": [dict(e) for e in self._applied["ignored-auth"].values()],
            "observer_errors": self._errors,
        }


def _pairs_text(items, cap: int = 3) -> str:
    pairs = [f"{e.get('method')} {e.get('path')}" for e in items]
    text = ", ".join(pairs[:cap])
    if len(pairs) > cap:
        text += f" +{len(pairs) - cap} more"
    return text


def render_side_effect_suffix(summary: dict, partial: bool = False) -> str:
    """The results row's Actual-cell suffix. Never contains a table pipe."""
    head = "side effects before the replay stopped" if partial else "side effects"
    n = int(summary.get("mutating_count") or 0)
    if n > 0:
        muts = [r for r in summary.get("requests") or [] if r.get("class") == "mutating"]
        detail = _pairs_text(muts)
        if summary.get("truncated"):
            detail += (" " if detail else "") + "(sample truncated)"
        text = f"; {head}: {n} mutating request(s)" + (f" ({detail})" if detail else "")
    else:
        text = f"; {head}: none observed"
    exc = summary.get("exceptions_applied") or []
    if exc:
        text += "; read-only exception applied: " + _pairs_text(exc)
    auth = summary.get("auth_ignored") or []
    if auth:
        text += "; auth request(s) not counted: " + _pairs_text(auth)
    return text.replace("|", "%7C").replace("\n", " ")


def _utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _utc_now_precise() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def observation_time(o) -> float:
    """Sortable time of an observation (epoch seconds); -inf when unknown.
    Parsed, never compared as text, so second- and microsecond-resolution
    stamps order correctly."""
    v = o.get("observed_at") if isinstance(o, dict) else None
    if not isinstance(v, str) or not v:
        return float("-inf")
    s = v[:-1] if v.endswith("Z") else v
    try:
        dt = datetime.datetime.fromisoformat(s)
    except ValueError:
        return float("-inf")
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt.timestamp()


def _mutation_count(o) -> int:
    try:
        return int(o.get("mutating_count") or 0)
    except (TypeError, ValueError, AttributeError):
        return 1  # an unreadable count is treated as a mutation (fail closed)


def golden_key(o) -> str:
    g = o.get("golden_sha256") if isinstance(o, dict) else None
    return g if isinstance(g, str) and _SHA256_RE.fullmatch(g) else UNIDENTIFIED_GOLDEN


def _union_pairs(a, b, keys, cap=SIDE_EFFECT_SAMPLE_CAP) -> "tuple[list, bool]":
    out: list = []
    seen: dict = {}
    overflow = False
    for r in list(a or []) + list(b or []):
        if not isinstance(r, dict):
            continue
        k = tuple(str(r.get(x)) for x in keys)
        if k in seen:
            if "count" in r:
                with contextlib.suppress(TypeError, ValueError):
                    seen[k]["count"] = max(int(seen[k].get("count") or 0), int(r.get("count") or 0))
            continue
        if len(out) >= cap:
            overflow = True
            continue
        rr = dict(r)
        seen[k] = rr
        out.append(rr)
    return out, overflow


_CONTEXT_KEYS = ("readonly_endpoints_sha256", "readonly_endpoints_error", "ignore_paths", "classifier_version")


def _cleared(mutation_time: float, clean_time: "float | None") -> bool:
    """A mutation is cleared only by a STRICTLY newer clean replay; one whose own
    time is unknown is never cleared (fail closed, like an unreadable count)."""
    return clean_time is not None and mutation_time != float("-inf") and clean_time > mutation_time


def _merge_mutating(entry: dict, obs: dict, cleared_at: "float | None" = None) -> None:
    """Record a mutating observation under its golden. Ignored when a strictly
    newer complete clean replay of the same golden already cleared it (the
    entry's clean record, or `cleared_at` for a golden whose entry was capped
    away); two uncleared observations of one golden are unioned (newest
    metadata wins)."""
    t = observation_time(obs)
    clean = entry.get("clean") if isinstance(entry.get("clean"), dict) else None
    times = [x for x in (observation_time(clean) if clean else None, cleared_at) if x is not None]
    clean_t = max(times) if times else None
    if _cleared(t, clean_t):
        return
    cur = entry.get("mutating") if isinstance(entry.get("mutating"), dict) else None
    if cur is None or _cleared(observation_time(cur), clean_t):
        entry["mutating"] = dict(obs)
        return
    newer, older = (dict(obs), cur) if t >= observation_time(cur) else (dict(cur), obs)
    reqs, over = _union_pairs(newer.get("requests"), older.get("requests"), ("method", "path", "class"))
    newer["requests"] = reqs
    newer["truncated"] = bool(newer.get("truncated") or older.get("truncated") or over)
    newer["mutating_count"] = max(_mutation_count(newer), _mutation_count(older))
    for key in ("exceptions_applied", "auth_ignored"):
        newer[key] = _union_pairs(newer.get(key), older.get(key), ("method", "path"))[0]
    if any(newer.get(k) != older.get(k) for k in _CONTEXT_KEYS):
        newer["context_mixed"] = True
    entry["mutating"] = newer


_EVIDENCE_KEYS = ("iter", "iter_name", "run_id", "observed_at", "verdict", "complete", "golden_sha256",
                  "mutating_count", "auth_count", "readonly_count", "requests", "truncated",
                  "exceptions_applied", "auth_ignored", "observer_attached") + _CONTEXT_KEYS


def _merge_clean(entry: dict, obs: dict) -> None:
    """Keep the newest complete clean replay of a golden — with its request
    sample, so a request it did NOT count (read-only / auth exclusion) becomes
    a mutation again if the owner later withdraws that exclusion."""
    cur = entry.get("clean") if isinstance(entry.get("clean"), dict) else None
    if cur is None or observation_time(obs) >= observation_time(cur):
        entry["clean"] = {k: obs.get(k) for k in _EVIDENCE_KEYS if k in obs}


def _entry_uncleared(key: str, entry) -> "dict | None":
    if not isinstance(entry, dict) or not isinstance(entry.get("mutating"), dict):
        return None
    m = entry["mutating"]
    c = entry.get("clean")
    if key != UNIDENTIFIED_GOLDEN and isinstance(c, dict) and _cleared(observation_time(m), observation_time(c)):
        return None
    return m


def uncleared_mutations(rec) -> list:
    """A journey record's mutating evidence that no strictly newer COMPLETE clean
    replay of the SAME golden has cleared, newest first. A mutation recorded
    under an unidentified golden, or with an unreadable time, is never cleared.
    A legacy record (no `goldens`) falls back to a mutating `latest`."""
    if not isinstance(rec, dict):
        return []
    goldens = rec.get("goldens")
    out: list = []
    if isinstance(goldens, dict):
        for key, entry in goldens.items():
            m = _entry_uncleared(key, entry)
            if m is not None:
                out.append(m)
    else:
        latest = rec.get("latest")
        if isinstance(latest, dict) and _mutation_count(latest) > 0:
            out.append(latest)
    out.sort(key=observation_time, reverse=True)
    return out


def _cap_goldens(goldens: dict, cleared_index: dict) -> dict:
    """Bound the per-golden entries. Only entries with nothing left to prove may
    go (oldest first) — never uncleared mutating evidence, never a clean
    replay whose sample holds a request an exclusion let through (it must stay
    re-checkable). A dropped entry's clean time moves to `cleared_index`, so a
    late-merged old mutation of that golden is still recognised as cleared."""
    if len(goldens) <= SIDE_EFFECT_GOLDEN_CAP:
        return goldens

    def _activity(item):
        e = item[1] if isinstance(item[1], dict) else {}
        return max(observation_time(e.get("mutating")), observation_time(e.get("clean")))

    def _droppable(key, entry) -> bool:
        if _entry_uncleared(key, entry) is not None or not isinstance(entry, dict):
            return False
        clean = entry.get("clean") if isinstance(entry.get("clean"), dict) else {}
        try:
            excluded = int(clean.get("readonly_count") or 0) or int(clean.get("auth_count") or 0)
        except (TypeError, ValueError):
            return False
        return not (clean.get("exceptions_applied") or clean.get("auth_ignored") or excluded)

    out = dict(goldens)
    for key, entry in sorted((it for it in goldens.items() if _droppable(*it)), key=_activity):
        if len(out) <= SIDE_EFFECT_GOLDEN_CAP:
            break
        clean = entry.get("clean") if isinstance(entry, dict) else None
        if isinstance(clean, dict) and clean.get("observed_at"):
            cleared_index[key] = clean["observed_at"]
        out.pop(key, None)
    while len(cleared_index) > SIDE_EFFECT_CLEARED_INDEX_CAP:
        cleared_index.pop(min(cleared_index, key=lambda k: observation_time({"observed_at": cleared_index[k]})))
    return out


def merge_side_effect_observations(sidecar, observations: dict, now: "str | None" = None,
                                   notes: "dict | None" = None, run_id: "str | None" = None) -> dict:
    """Pure merge of per-journey observations into the sidecar dict.

    Only the `journeys` records of the observed journeys change; every other key
    (the engine's declaration bookkeeping) and every other journey is kept. Per
    journey: `last_attempt` is the newest observation, `latest` the newest
    complete-or-mutating one (display), and `goldens` the status evidence keyed
    by golden identity — a mutation stays until a strictly newer COMPLETE clean
    replay of the SAME golden clears it (a partial, blind or other-golden replay
    never does). Whether a journey has uncleared evidence does not depend on the
    order observations arrive in, so a late merge of an older run record is
    safe; only the request SAMPLE of a union can differ by order, and only by
    holding more requests (never fewer). `notes` (optional) is filled with the
    journeys whose complete clean replay could NOT clear an earlier mutation;
    `run_id` (optional) is recorded as merged even when the run observed no
    journey."""
    data = sidecar if isinstance(sidecar, dict) else {}
    data.setdefault("schema_version", 1)
    journeys = data.get("journeys")
    if not isinstance(journeys, dict):
        journeys = {}
        data["journeys"] = journeys
    runs = data.get("merged_runs")
    runs = [r for r in runs if isinstance(r, str)] if isinstance(runs, list) else []
    for jid, obs in (observations or {}).items():
        if not isinstance(obs, dict):
            continue
        rec = journeys.get(jid)
        if not isinstance(rec, dict):
            rec = {}
        t = observation_time(obs)
        last = rec.get("last_attempt")
        if not isinstance(last, dict) or t >= observation_time(last):
            rec["last_attempt"] = obs
        mut = _mutation_count(obs) > 0
        complete_clean = (not mut) and obs.get("complete") is True
        latest = rec.get("latest")
        if (mut or complete_clean) and (not isinstance(latest, dict) or t >= observation_time(latest)):
            rec["latest"] = obs
        key = golden_key(obs)
        goldens = rec.get("goldens") if isinstance(rec.get("goldens"), dict) else {}
        entry = goldens.get(key) if isinstance(goldens.get(key), dict) else {}
        index = rec.get("cleared_goldens") if isinstance(rec.get("cleared_goldens"), dict) else {}
        if mut:
            idx_t = index.get(key) if key != UNIDENTIFIED_GOLDEN else None
            _merge_mutating(entry, obs, observation_time({"observed_at": idx_t}) if idx_t else None)
            prior = rec.get("mutating_history")
            hist = [h for h in prior if isinstance(h, dict)] if isinstance(prior, list) else []
            item = {
                "iter": obs.get("iter"), "iter_name": obs.get("iter_name"), "run_id": obs.get("run_id"),
                "observed_at": obs.get("observed_at"), "golden_sha256": obs.get("golden_sha256"),
                "sample": [f"{r.get('method')} {r.get('path')}" for r in (obs.get("requests") or [])
                           if isinstance(r, dict) and r.get("class") == "mutating"][:3],
            }
            if not (item["run_id"] and any(h.get("run_id") == item["run_id"] for h in hist)):
                hist.append(item)
            hist.sort(key=observation_time)
            rec["mutating_history"] = hist[-SIDE_EFFECT_HISTORY_CAP:]
        elif complete_clean and key != UNIDENTIFIED_GOLDEN:
            _merge_clean(entry, obs)
        if entry:
            goldens[key] = entry
        if goldens:
            rec["goldens"] = _cap_goldens(goldens, index)
        if index:
            rec["cleared_goldens"] = index
        if complete_clean and notes is not None:
            left = uncleared_mutations(rec)
            if left:
                m = left[0]
                notes[jid] = {
                    "golden_sha256": obs.get("golden_sha256"), "mutating_golden_sha256": m.get("golden_sha256"),
                    "mutating_iter": m.get("iter"), "mutating_iter_name": m.get("iter_name"),
                    "sample": [f"{r.get('method')} {r.get('path')}" for r in (m.get("requests") or [])
                               if isinstance(r, dict) and r.get("class") == "mutating"][:3],
                }
        journeys[jid] = rec
        obs_run = obs.get("run_id")
        if isinstance(obs_run, str) and obs_run and obs_run not in runs:
            runs.append(obs_run)
    if isinstance(run_id, str) and run_id and run_id not in runs:
        runs.append(run_id)
    data["merged_runs"] = runs[-MERGED_RUNS_CAP:]
    data["observations_updated_at"] = now or _utc_now()
    return data


@contextlib.contextmanager
def _locked_dir(dirpath, timeout: float = 10.0):
    """Exclusive flock on the DIRECTORY itself — no lock file is created (a lock
    file under runs/ would be committed as evidence; HARD-7's hygiene rule)."""
    import fcntl  # noqa: PLC0415 — POSIX only; imported where used
    fd = os.open(str(dirpath), os.O_RDONLY)
    try:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"could not lock {dirpath} within {timeout:g}s")
                time.sleep(0.05)
        try:
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def _atomic_write_json(path, data) -> None:
    p = Path(path)
    tmp = p.with_name(f".{p.name}.tmp.{os.getpid()}")
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=1, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, p)
    finally:
        with contextlib.suppress(OSError):
            tmp.unlink()


def sidecar_shape_error(current) -> "str | None":
    """Why an existing sidecar may not be merged into, or None."""
    if not isinstance(current, dict):
        return "the top level is not an object"
    journeys = current.get("journeys", {})
    if not isinstance(journeys, dict):
        return "'journeys' is not an object"
    if "merged_runs" in current and not isinstance(current["merged_runs"], list):
        return "'merged_runs' is not a list"
    for key in ("declarations", "declaration_conflicts"):
        if key in current and not isinstance(current[key], dict):
            return f"'{key}' is not an object"
    for jid, rec in journeys.items():
        if not isinstance(rec, dict):
            return f"record {jid} is not an object"
        for key in ("latest", "last_attempt"):
            if key in rec and not isinstance(rec[key], dict):
                return f"record {jid}.{key} is not an object"
        if "mutating_history" in rec and not isinstance(rec["mutating_history"], list):
            return f"record {jid}.mutating_history is not a list"
        if "cleared_goldens" in rec and not isinstance(rec["cleared_goldens"], dict):
            return f"record {jid}.cleared_goldens is not an object"
        if "goldens" in rec:
            if not isinstance(rec["goldens"], dict):
                return f"record {jid}.goldens is not an object"
            for key, entry in rec["goldens"].items():
                if not isinstance(entry, dict) or any(
                        k in entry and not isinstance(entry[k], dict) for k in ("mutating", "clean")):
                    return f"record {jid}.goldens.{key} is not a well-formed entry"
    return None


_sidecar_shape_error = sidecar_shape_error  # the name the first HARD-3 commit used


def side_effect_lock_timeout(env=None) -> float:
    """Seconds a sidecar writer waits for the state/ directory lock
    (CHAIN_SIDE_EFFECT_LOCK_TIMEOUT, default 10, clamped to 0.1–120; anything
    unparseable is the default). A timeout never loses an observation: the
    per-run record keeps it and the next preflight merges it."""
    env = os.environ if env is None else env
    try:
        v = float(env.get("CHAIN_SIDE_EFFECT_LOCK_TIMEOUT") or 10.0)
    except ValueError:
        return 10.0
    return min(max(v, 0.1), 120.0) if v == v else 10.0


def update_side_effects_sidecar(path, observations: dict, lock_timeout: float = 10.0,
                                notes: "dict | None" = None, run_id: "str | None" = None) -> "tuple[bool, str]":
    """Read-modify-write the engine-owned sidecar. A corrupt or wrongly-shaped
    existing file is NEVER overwritten: losing recorded mutations would silently
    downgrade journeys to their declarations (the ledger reports it instead, and
    the per-run records still carry every observation)."""
    p = Path(path)
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        with _locked_dir(p.parent, lock_timeout):
            current = None
            if p.exists():
                try:
                    current = json.loads(p.read_text(encoding="utf-8"))
                except (OSError, ValueError, RecursionError) as exc:
                    return False, (f"{p} is unreadable or corrupt ({exc}) — not overwritten; "
                                   "inspect or move it aside, then re-run")
                shape_error = sidecar_shape_error(current)
                if shape_error:
                    return False, f"{p} has the wrong shape ({shape_error}) — not overwritten"
            try:
                merged = merge_side_effect_observations(current, observations, notes=notes, run_id=run_id)
            except Exception as exc:  # noqa: BLE001 — never overwrite what cannot be merged
                return False, f"{p} could not be merged ({exc}) — not overwritten"
            _atomic_write_json(p, merged)
    except (OSError, TimeoutError) as exc:
        return False, f"sidecar update failed: {exc}"
    return True, "updated"


def _observation_record(summary: dict, verdict: str, complete: bool, run_meta: dict) -> dict:
    rec = dict(run_meta)
    rec.update({"verdict": verdict, "complete": bool(complete)})
    rec.update(summary)
    return rec


def _today() -> str:
    return datetime.date.today().isoformat()


def render_results_md(phase_id: str, frontend_url: str, iteration, captured: list[dict],
                      soft_notes: list[str], verdict: str, mode: str) -> str:
    """Emit demo-results.md byte-compatibly with render_iteration_summary.py."""
    lines = [f"# Demo Results — {phase_id}", ""]
    lines.append(f"**Demo Verdict:** {verdict}")
    lines.append(f"**Date:** {_today()}")
    lines.append(f"**Frontend URL:** {frontend_url}")
    if iteration is not None:
        lines.append(f"**Iteration:** {iteration}")
    lines += ["", "## Captured Steps", "",
              "| Step | Title | Journey | New | Screenshot |",
              "|------|-------|---------|-----|------------|"]
    for s in captured:
        n = f"{int(s['n']):02d}"
        title = str(s.get("title", "")).replace("|", "\\|")
        journey = s.get("journey") or ""
        new = "yes" if s.get("new") else ""
        shot = s.get("screenshot", "") or ""
        lines.append(f"| {n} | {title} | {journey} | {new} | {shot} |")
    lines.append("")
    if soft_notes:
        lines += ["## Soft notes", ""]
        lines += [f"- {note}" for note in soft_notes]
        lines.append("")
    lines += ["## Environment", "",
              f"- **Frontend URL:** {frontend_url}",
              f"- **Browser:** Chromium via Playwright ({mode})",
              f"- **Demo mode:** {mode}", ""]
    return "\n".join(lines)


def render_regression_results_md(phase_id: str, frontend_url: str, iteration,
                                 results: list[dict], mode: str = "verify") -> str:
    """Emit a ui-test-results.md-compatible report for deterministic regression
    replay — byte-shaped like templates/ui-test-results.md so the goal-evaluator
    reads it exactly like the LLM browser-qa output (top `**Browser QA Verdict:**`
    line, one `UT-<journey>` row per journey, evidence screenshots). `results` is
    a list of {journey, name, verdict (PASS/FAIL/SKIP), expected, actual, evidence}."""
    overall = compute_regression_verdict(results)
    total = len(results)
    n_pass = sum(1 for r in results if r.get("verdict") == "PASS")
    n_skip = sum(1 for r in results if r.get("verdict") == "SKIP")
    lines = [f"# Regression Replay — {phase_id}", ""]
    lines.append(f"**Phase:** {phase_id}")
    lines.append(f"**Date:** {_today()}")
    lines.append("**Written by:** demo_runner.py (deterministic replay)")
    if iteration is not None:
        lines.append(f"**Iteration:** {iteration}")
    lines += ["", "---", "",
              f"**Browser QA Verdict:** {overall}", "",
              f"**Overall:** {n_pass}/{total} journeys passed ({n_skip} skipped)", "",
              "---", "", "## Results Table", "",
              "| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |",
              "|---------|------|------|----------|----------|--------|---------|----------|"]
    for r in results:
        tid = f"UT-{r.get('journey', '')}"
        name = str(r.get("name", "")).replace("|", "\\|")
        exp = str(r.get("expected", "")).replace("|", "\\|")
        act = str(r.get("actual", "")).replace("|", "\\|")
        ev = r.get("evidence", "none") or "none"
        lines.append(f"| {tid} | {name} | regression | P1 | {exp} | {act} | {r.get('verdict', '')} | {ev} |")
    lines.append("")
    failed = [r for r in results if r.get("verdict") == "FAIL"]
    skipped = [r for r in results if r.get("verdict") == "SKIP"]
    if failed:
        lines += ["## Failed Tests", ""]
        for r in failed:
            lines += [f"### UT-{r.get('journey', '')} — {r.get('name', '')}", "",
                      "**Verdict:** FAIL",
                      f"**Failure:** {r.get('actual', '')}",
                      f"**Evidence:** `{r.get('evidence', 'none')}`", ""]
    if skipped:
        lines += ["## Skipped Tests", ""]
        for r in skipped:
            lines += [f"### UT-{r.get('journey', '')} — {r.get('name', '')}", "",
                      "**Verdict:** SKIPPED",
                      f"**Reason:** {r.get('actual', '')}", ""]
    lines += ["## Environment", "",
              f"- **Frontend URL:** {frontend_url}",
              f"- **Browser:** Chromium via Playwright (deterministic replay, {mode})",
              f"- **Test Date:** {_today()}", ""]
    return "\n".join(lines)


def _emit_script_step(lines: list[str], s: dict) -> None:
    n = f"{int(s['n']):02d}"
    tag = "  [NEW]" if s.get("new") else ""
    lines.append(f"### Step {n} — {s.get('title', '')}{tag}")
    lines.append("")
    if s.get("narration"):
        lines.append(f"- **Narration:** {s['narration']}")
    if s.get("action"):
        lines.append(f"- **Action:** {s['action']}")
    if s.get("point_out"):
        lines.append(f"- **Point out:** {s['point_out']}")
    if s.get("screenshot"):
        lines.append(f"- **Screenshot:** {s['screenshot']}")
    lines.append("")


def render_script_md(phase_id: str, frontend_url: str, iteration, steps: list[dict],
                     mode: str) -> str:
    """Emit a renderer-compatible demo-script.md from the JSON (single source of
    truth). The renderer keys off `### Step NN` headings and `- **Narration:**`
    lines; Highlights steps carry a screenshot, Full-tour steps are text-only."""
    hi = [s for s in steps if s.get("section", "highlights") != "full_tour"]
    full = [s for s in steps if s.get("section", "highlights") == "full_tour"]
    lines = [f"# Demo Script — {phase_id}", ""]
    lines.append(f"**Mode:** {mode}")
    lines.append(f"**Date:** {_today()}")
    lines.append(f"**Frontend URL:** {frontend_url}")
    if iteration is not None:
        lines.append(f"**Iteration:** {iteration}")
    lines += ["", "## Highlights", ""]
    for s in hi:
        _emit_script_step(lines, s)
    if full:
        lines += ["## Full tour (text only)", ""]
        for s in full:
            _emit_script_step(lines, s)
    return "\n".join(lines)


# ── self-test (written first, TDD) ───────────────────────────────────────────
# Each _t_* function checks one behavior. The harness runs them all and reports
# every failure, so a fresh run shows the full RED surface at once.


def _t_normalize_url_relative() -> None:
    assert normalize_url("http://localhost:3017", "/items/new") == "http://localhost:3017/items/new"
    assert normalize_url("http://localhost:3017/", "items") == "http://localhost:3017/items"
    assert normalize_url("http://localhost:3017", "/") == "http://localhost:3017/"
    assert normalize_url("http://localhost:3017", "") == "http://localhost:3017/"
    assert normalize_url("http://localhost:3017", "/x?a=1") == "http://localhost:3017/x?a=1"


def _t_normalize_url_rewrites_localhost() -> None:
    # The port-offset fix: a hardcoded :3000 from QA artifacts must be rewritten
    # to the actual base_url (the offset dev-port).
    assert normalize_url("http://localhost:3017", "http://localhost:3000/items/new") == "http://localhost:3017/items/new"
    assert normalize_url("http://localhost:3017", "http://127.0.0.1:3000/x") == "http://localhost:3017/x"


def _t_normalize_url_keeps_external() -> None:
    # A genuinely external absolute URL is left untouched.
    assert normalize_url("http://localhost:3017", "https://example.com/x") == "https://example.com/x"


def _t_validate_accepts_good() -> None:
    data = {
        "schema_version": 1,
        "base_url": "http://localhost:3000",
        "steps": [
            {"n": 1, "action": {"type": "goto", "url": "/"}},
            {"n": 2, "action": {"type": "click", "target": {"role": "button", "name": "Save"}}},
            {"n": 3, "action": {"type": "fill", "target": {"label": "Title"}, "text": "Q3"}},
        ],
    }
    assert validate_script(data) == [], validate_script(data)


def _t_validate_rejects_missing_steps() -> None:
    assert validate_script({"schema_version": 1}) != []


def _t_validate_rejects_bad_action() -> None:
    data = {"schema_version": 1, "steps": [{"n": 1, "action": {"type": "frobnicate"}}]}
    assert validate_script(data) != []
    # goto without url, fill without text
    assert validate_script({"schema_version": 1, "steps": [{"n": 1, "action": {"type": "goto"}}]}) != []
    assert validate_script({"schema_version": 1, "steps": [
        {"n": 1, "action": {"type": "fill", "target": {"label": "x"}}}]}) != []


def _t_validate_accepts_not_yet() -> None:
    # A "nothing to show yet" script legitimately has no steps.
    assert validate_script({"schema_version": 1, "not_yet": True, "steps": []}) == []
    assert validate_script({"schema_version": 1, "not_yet": True}) == []


def _t_resolve_role_degrades_to_text() -> None:
    assert resolve_spec({"role": "button", "name": "Save"}) == [
        ("role", "button", "Save"), ("text", None, "Save")]


def _t_resolve_label_degrades_to_placeholder() -> None:
    assert resolve_spec({"label": "Title"}) == [
        ("label", None, "Title"), ("placeholder", None, "Title")]


def _t_resolve_simple_kinds() -> None:
    assert resolve_spec({"text": "Save"}) == [("text", None, "Save")]
    assert resolve_spec({"placeholder": "Email"}) == [("placeholder", None, "Email")]
    assert resolve_spec({"testid": "submit"}) == [("testid", None, "submit")]
    assert resolve_spec({"css": ".btn"}) == [("css", None, ".btn")]


def _t_verdict_matrix() -> None:
    assert compute_verdict(any_captured=True, has_soft_notes=False, not_yet=False) == "RECORDED"
    assert compute_verdict(any_captured=True, has_soft_notes=True, not_yet=False) == "RECORDED_WITH_NOTES"
    assert compute_verdict(any_captured=False, has_soft_notes=False, not_yet=False) == "SKIPPED"
    assert compute_verdict(any_captured=True, has_soft_notes=True, not_yet=True) == "NOT_YET"


def _t_results_md_roundtrip() -> None:
    import render_iteration_summary as R
    steps = [
        {"n": 1, "title": "Open dashboard", "journey": "J-04", "new": True,
         "screenshot": "reports/demo/x/step-01.png"},
        {"n": 2, "title": "Open the form", "journey": "", "new": False,
         "screenshot": "reports/demo/x/step-02.png"},
    ]
    md = render_results_md(phase_id="x", frontend_url="http://localhost:3000", iteration=3,
                           captured=steps, soft_notes=["Step 02 — toast did not appear"],
                           verdict="RECORDED_WITH_NOTES", mode="record")
    verdict, parsed, notes = R._parse_demo_results(md)
    assert verdict == "RECORDED_WITH_NOTES", verdict
    assert [s["number"] for s in parsed] == [1, 2], parsed
    assert parsed[0]["title"] == "Open dashboard"
    assert parsed[0]["is_new"] is True
    assert parsed[0]["journey"] == "J-04"
    assert parsed[0]["screenshot"] == "reports/demo/x/step-01.png"
    assert parsed[1]["is_new"] is False
    assert parsed[1]["journey"] == ""
    assert len(notes) == 1, notes


def _t_script_md_roundtrip() -> None:
    import render_iteration_summary as R
    steps = [
        {"n": 1, "title": "Open dashboard", "narration": "We open the home page.",
         "action": "Navigate to /", "point_out": "the sidebar",
         "screenshot": "reports/demo/x/step-01.png", "new": True},
        {"n": 2, "title": "Open the form", "narration": "We open the form.",
         "action": "Click New Report", "point_out": "a blank form",
         "screenshot": "reports/demo/x/step-02.png", "new": False},
    ]
    md = render_script_md(phase_id="x", frontend_url="http://localhost:3000", iteration=3,
                          steps=steps, mode="record")
    narr = R._parse_demo_script_narrations(md)
    assert narr.get(1) == "We open the home page.", narr
    assert narr.get(2) == "We open the form.", narr


def _t_regression_verdict_matrix() -> None:
    assert compute_regression_verdict([]) == "SKIPPED"
    assert compute_regression_verdict([{"verdict": "PASS"}, {"verdict": "PASS"}]) == "PASS"
    assert compute_regression_verdict([{"verdict": "PASS"}, {"verdict": "FAIL"}]) == "FAIL"
    assert compute_regression_verdict([{"verdict": "SKIP"}, {"verdict": "SKIP"}]) == "SKIPPED"
    assert compute_regression_verdict([{"verdict": "SKIP"}, {"verdict": "PASS"}]) == "PASS"
    assert compute_regression_verdict([{"verdict": "FAIL"}, {"verdict": "SKIP"}]) == "FAIL"


def _t_regression_results_md() -> None:
    results = [
        {"journey": "J-06", "name": "View dashboard", "verdict": "PASS",
         "expected": "e", "actual": "ok", "evidence": "reports/qa/x/J-06-verify.png"},
        {"journey": "J-07", "name": "Filter the table", "verdict": "FAIL",
         "expected": "e", "actual": 'step 03 expected "Results" did not appear',
         "evidence": "reports/qa/x/J-07-verify.png"},
        {"journey": "J-09", "name": "Export report", "verdict": "SKIP",
         "expected": "e", "actual": "no golden script on file", "evidence": "none"},
    ]
    md = render_regression_results_md("goal-x-iter-5", "http://localhost:3017", 5, results, "verify")
    # one journey FAILED → overall FAIL, with the marker line the goal-evaluator parses
    assert "**Browser QA Verdict:** FAIL" in md, md
    assert "## Results Table" in md
    # one UT row per journey, using the journey id as the test id
    for tid in ("UT-J-06", "UT-J-07", "UT-J-09"):
        assert tid in md, tid
    assert "## Failed Tests" in md and "## Skipped Tests" in md
    assert "1/3 journeys passed (1 skipped)" in md, md


def _t_launch_chromium_retries() -> None:
    # A flaky launch succeeds on the retry; a dead one raises after N attempts
    # (no browser involved — fake pw objects).
    class _FlakyChromium:
        calls = 0
        @staticmethod
        def launch(**_kw):
            _FlakyChromium.calls += 1
            if _FlakyChromium.calls < 2:
                raise RuntimeError("Timeout 45000ms exceeded launching chromium")
            return "browser-handle"

    class _FlakyPW:
        chromium = _FlakyChromium

    assert _launch_chromium(_FlakyPW, headless=True, attempts=2) == "browser-handle"
    assert _FlakyChromium.calls == 2

    class _DeadChromium:
        calls = 0
        @staticmethod
        def launch(**_kw):
            _DeadChromium.calls += 1
            raise RuntimeError("boom")

    class _DeadPW:
        chromium = _DeadChromium

    try:
        _launch_chromium(_DeadPW, headless=True, attempts=2)
        raise AssertionError("expected the launch failure to propagate")
    except RuntimeError as exc:
        assert "boom" in str(exc)
    assert _DeadChromium.calls == 2


def _derive_demo_fixture() -> dict:
    # Matches the demo-narrator contract: every step carries a "journey" key,
    # "" on shared orientation steps (the untagged prefix).
    return {
        "schema_version": 1,
        "phase_id": "goal-x-iter-9",
        "name": "demo",
        "default_timeout_ms": 9000,
        "steps": [
            {"n": 1, "journey": "", "action": {"type": "goto", "url": "/"}, "narration": "open the app",
             "expect": {"text": "Home"}},
            {"n": 2, "journey": "J-07", "action": {"type": "click", "target": {"text": "Filters"}},
             "narration": "open filters"},
            {"n": 3, "journey": "J-07", "action": {"type": "expect"}, "expect": {"text": "Filter panel"},
             "timeout_ms": 4000},
            {"n": 4, "journey": "J-09", "action": {"type": "click", "target": {"text": "Export"}},
             "expect": {"text": "Exported"}},
        ],
    }


def _t_derive_happy() -> None:
    golden, reason = derive_golden_steps(_derive_demo_fixture(), "J-07")
    assert golden is not None, reason
    assert validate_script(golden) == [], golden
    # prefix (untagged step 1) + the 2 tagged steps, renumbered 1..3
    assert [s["n"] for s in golden["steps"]] == [1, 2, 3], golden["steps"]
    assert all(s["journey"] == "J-07" for s in golden["steps"])
    assert golden["steps"][0]["action"]["type"] == "goto"
    # demo-only fields are stripped
    assert all("narration" not in s for s in golden["steps"])
    assert golden["steps"][2]["timeout_ms"] == 4000
    assert golden["journey"] == "J-07" and golden["default_timeout_ms"] == 9000


def _t_derive_rejects_untagged_journey() -> None:
    golden, reason = derive_golden_steps(_derive_demo_fixture(), "J-99")
    assert golden is None and "no steps tagged" in reason, (golden, reason)


def _t_derive_rejects_no_expect() -> None:
    demo = _derive_demo_fixture()
    for s in demo["steps"]:
        if s.get("journey") == "J-07":
            s.pop("expect", None)
    golden, reason = derive_golden_steps(demo, "J-07")
    assert golden is None and "expect" in reason, (golden, reason)


def _t_derive_rejects_no_goto_open() -> None:
    demo = _derive_demo_fixture()
    demo["steps"] = demo["steps"][1:]   # drop the untagged goto prefix
    golden, reason = derive_golden_steps(demo, "J-07")
    assert golden is None and "goto" in reason, (golden, reason)


def _t_derive_rejects_invalid_demo() -> None:
    golden, reason = derive_golden_steps({"schema_version": 1, "steps": []}, "J-07")
    assert golden is None and "invalid" in reason, (golden, reason)
    golden, reason = derive_golden_steps({"schema_version": 1, "not_yet": True}, "J-07")
    assert golden is None, (golden, reason)


def _t_derive_prefix_without_journey_key() -> None:
    # Legacy/hand-written demos may omit the journey key entirely on setup
    # steps — the prefix scan must treat that the same as journey:"".
    demo = _derive_demo_fixture()
    del demo["steps"][0]["journey"]
    golden, reason = derive_golden_steps(demo, "J-07")
    assert golden is not None, reason
    assert golden["steps"][0]["action"]["type"] == "goto"


def _t_classify_request_matrix() -> None:
    fe, be = "http://localhost:3017", "http://localhost:8017"
    ro = [("POST", "/api/policy/evaluate")]
    assert classify_request("POST", "fetch", fe + "/api/runs", fe, ()) == "mutating"
    assert classify_request("GET", "fetch", fe + "/api/runs", fe, ()) is None
    assert classify_request("POST", "image", fe + "/x", fe, ()) is None
    assert classify_request("POST", "fetch", fe + "/_next/data/x", fe, ()) is None
    assert classify_request("POST", "xhr", be + "/api/runs", fe, ()) == "mutating"
    assert classify_request("POST", "fetch", "https://stats.example.com/c", fe, ()) is None
    assert classify_request("POST", "fetch", fe + "/api/login", fe) == "ignored-auth"
    assert classify_request("POST", "fetch", fe + "/api/policy/evaluate", fe, (), ro) == "ignored-readonly"
    assert classify_request("POST", "fetch", fe + "/api/policy/evaluate", fe, (), ()) == "mutating"
    assert classify_request("POST", "fetch", fe + "/api/policy/evaluate/../../runs", fe, (), ro) == "mutating"
    assert classify_request("POST", "document", "/runs/new", fe, ()) == "mutating"
    # every write channel counts: beacons and unclassified requests too
    assert classify_request("POST", "ping", fe + "/api/drafts", fe, ()) == "mutating"
    assert classify_request("POST", "other", fe + "/api/drafts", fe, ()) == "mutating"
    # a local base makes every local backend part of the project
    for host in ("http://192.168.1.20:8000", "http://10.0.0.5", "http://myhost:8000", "http://app.local",
                 "http://127.0.0.2:9000", "http://[::1]:8000"):
        assert classify_request("POST", "fetch", host + "/api/runs", fe, ()) == "mutating", host
    assert classify_request("POST", "fetch", "http://8.8.8.8/api/runs", fe, ()) is None
    # an encoded separator never rides a dev-asset or auth exemption
    assert classify_request("POST", "fetch", fe + "/_next/..%2Fapi/runs", fe, ()) == "mutating"
    # auth exclusions: anchored after an API prefix, POST/DELETE only
    auth = _DEFAULT_AUTH_IGNORE_PATHS
    for path in ("/api/login", "/api/v1/login", "/v2/auth/token", "/logout", "/api/session", "/csrf"):
        assert classify_candidate("POST", path, auth, ()) == "ignored-auth", path
    assert classify_candidate("DELETE", "/api/session", auth, ()) == "ignored-auth"
    for method, path in (("PATCH", "/api/chat/session/7"), ("DELETE", "/api/workouts/session/9"),
                         ("POST", "/api/trading/session/start"), ("POST", "/api/users/42/token"),
                         ("POST", "/api/api-keys/token"), ("PUT", "/api/settings/auth"),
                         ("PUT", "/api/session"), ("PATCH", "/api/auth/password"),
                         ("POST", "/api/login-history/clear"), ("POST", "/api/sessions"),
                         ("DELETE", "/api/auth/users/5"),
                         ("DELETE", "/api/session/3f2a9c1e-0b7d-4c2a-9e51-7d1f0c2b8a64")):
        assert classify_candidate(method, path, auth, ()) == "mutating", (method, path)
    assert classify_candidate("POST", "/api/auth/callback/credentials", auth, ()) == "ignored-auth"
    # an entry names an endpoint: one sign-in step below it, or a NextAuth provider form — nothing else
    for method, path in (("POST", "/api/auth/login"), ("POST", "/api/token/refresh"), ("DELETE", "/api/auth/session"),
                         ("POST", "/api/auth/signin/github"), ("POST", "/API/Auth/Logout")):
        assert classify_candidate(method, path, auth, ()) == "ignored-auth", (method, path)
    for method, path in (("POST", "/api/auth/users"), ("POST", "/auth/register"), ("DELETE", "/api/session/all"),
                         ("POST", "/api/login/history/clear"), ("POST", "/api/auth/callback/credentials/x"),
                         ("POST", "/api/auth/callback/5"), ("POST", "/api/token/revoke"),
                         ("POST", "//api//login"), ("PUT", "/api/auth/login")):
        assert classify_candidate(method, path, auth, ()) == "mutating", (method, path)


def _t_side_effect_env_override() -> None:
    assert side_effect_ignore_paths({}) == _DEFAULT_AUTH_IGNORE_PATHS
    assert side_effect_ignore_paths({"CHAIN_SIDE_EFFECT_IGNORE_PATHS": ""}) == ()
    eff, rej = side_effect_ignore_paths_report(
        {"CHAIN_SIDE_EFFECT_IGNORE_PATHS": "signin, /, /api/x/, /api, api/v1, /v2, /a/../b, /api/*, /x?y, //x"})
    assert eff == ("/signin", "/api/x"), eff
    assert rej == ("/", "/api", "api/v1", "/v2", "/a/../b", "/api/*", "/x?y", "//x"), rej
    assert classify_candidate("POST", "/api/runs", eff, ()) == "mutating"
    assert classify_candidate("POST", "/api/x/y", eff, ()) == "mutating"
    assert classify_candidate("POST", "/api/x/refresh", eff, ()) == "ignored-auth"


def _t_readonly_endpoint_file() -> None:
    entries, invalid = parse_readonly_endpoints("# c\nPOST /api/a # x\nGET /b\nPOST /\nPOST /api/%2e%2e/runs\n")
    assert entries == [("POST", "/api/a")], entries
    assert [i[0] for i in invalid] == [3, 4, 5], invalid


def _t_side_effect_recorder_and_suffix() -> None:
    class _R:
        def __init__(self, m, t, u):
            self.method, self.resource_type, self.url = m, t, u
    rec = SideEffectRecorder("http://localhost:3017", _DEFAULT_AUTH_IGNORE_PATHS, [("POST", "/api/eval")])
    for r in (_R("POST", "fetch", "/api/runs"), _R("POST", "fetch", "/api/eval"), _R("GET", "fetch", "/api/runs"),
              _R("POST", "fetch", "/api/login")):
        rec.on_request(r)
    s = rec.summary()
    assert s["mutating_count"] == 1 and s["readonly_count"] == 1 and s["auth_count"] == 1, s
    assert s["auth_ignored"] == [{"method": "POST", "path": "/api/login"}], s
    assert render_side_effect_suffix(s) == ("; side effects: 1 mutating request(s) (POST /api/runs); "
                                            "read-only exception applied: POST /api/eval; "
                                            "auth request(s) not counted: POST /api/login"), render_side_effect_suffix(s)
    assert render_side_effect_suffix(SideEffectRecorder("http://x").summary()) == "; side effects: none observed"


def _t_golden_identity() -> None:
    a = {"schema_version": 1, "name": "A", "default_timeout_ms": 8000,
         "steps": [{"n": 1, "action": {"type": "goto", "url": "/"}}]}
    b = json.loads(json.dumps(a))
    b["name"] = "renamed"
    assert golden_identity(a) == golden_identity(b) and len(golden_identity(a)) == 64
    b["steps"][0]["action"]["url"] = "/x"
    assert golden_identity(a) != golden_identity(b)
    assert golden_identity(None) is None


def _t_side_effect_merge_golden_semantics() -> None:
    import itertools
    g1, g2 = "1" * 64, "2" * 64

    def ob(n, t, golden, complete=True, iter_=0):
        return {"run_id": f"r{t}", "iter": iter_, "complete": complete, "mutating_count": n,
                "observed_at": f"2026-09-17T00:00:{t:02d}.000000Z", "golden_sha256": golden,
                "requests": [{"method": "POST", "path": "/api/runs", "class": "mutating", "count": n}] if n else []}

    def status(seq):
        d = {"declaration_digest": "x"}
        for o in seq:
            d = merge_side_effect_observations(d, {"J-01": o})
        assert d["declaration_digest"] == "x"
        return [m["observed_at"] for m in uncleared_mutations(d["journeys"]["J-01"])], d

    mut = ob(1, 1, g1)
    # a partial or blind replay that saw nothing never clears
    left, d = status([mut, ob(0, 2, g1, complete=False)])
    assert left and d["journeys"]["J-01"]["last_attempt"]["run_id"] == "r2" and d["merged_runs"] == ["r1", "r2"]
    # a complete clean replay of ANOTHER golden never clears (and says so)
    notes: dict = {}
    d = merge_side_effect_observations({}, {"J-01": mut})
    d = merge_side_effect_observations(d, {"J-01": ob(0, 3, g2)}, notes=notes)
    assert uncleared_mutations(d["journeys"]["J-01"]) and notes["J-01"]["mutating_golden_sha256"] == g1, notes
    # an unidentified golden is never cleared, even by an unidentified clean replay
    assert status([ob(1, 1, None), ob(0, 2, None)])[0]
    # only a strictly newer complete clean replay of the SAME golden clears
    assert not status([mut, ob(0, 4, g1)])[0]
    assert status([mut, ob(0, 1, g1)])[0]
    # a mutation AFTER the clearing replay counts again
    assert status([mut, ob(0, 4, g1), ob(1, 5, g1)])[0]
    # the outcome never depends on arrival order
    seq = [ob(1, 1, g1), ob(0, 2, g2), ob(1, 3, g2), ob(0, 4, g2), ob(0, 5, g1, complete=False)]
    ref = status(seq)[0]
    assert ref == ["2026-09-17T00:00:01.000000Z"], ref
    for perm in itertools.permutations(seq):
        assert status(list(perm))[0] == ref, perm
    # a mutation whose time cannot be read is never cleared
    bad_t = dict(ob(1, 1, g1), observed_at="not-a-time")
    assert status([bad_t, ob(0, 9, g1)])[0] == ["not-a-time"]
    # a golden whose entry was capped away still clears a late-merged old mutation
    d = {}
    for i in range(SIDE_EFFECT_GOLDEN_CAP + 3):
        d = merge_side_effect_observations(d, {"J-01": ob(0, 10 + i % 40, f"{i:064x}")})
    first = f"{0:064x}"
    assert first not in d["journeys"]["J-01"]["goldens"] and first in d["journeys"]["J-01"]["cleared_goldens"]
    d = merge_side_effect_observations(d, {"J-01": ob(1, 5, first)})
    assert uncleared_mutations(d["journeys"]["J-01"]) == []
    # a run that observed no journey is still recorded as merged
    assert merge_side_effect_observations({}, {}, run_id="r-empty")["merged_runs"] == ["r-empty"]
    # merging the same run twice changes nothing but the timestamp
    a = status([mut, ob(0, 3, g2)])[1]
    b = merge_side_effect_observations(json.loads(json.dumps(a)), {"J-01": ob(0, 3, g2)}, now=a["observations_updated_at"])
    assert a == b


def _t_validate_tolerates_observed_mirror() -> None:
    # A golden may carry an `observed` block (HARD-3 mirror field); the replay
    # contract ignores it.
    data = {"schema_version": 1, "observed": {"mutating_count": 1},
            "steps": [{"n": 1, "action": {"type": "goto", "url": "/"}}]}
    assert validate_script(data) == [], validate_script(data)


_SELF_TEST_CHECKS = [
    _t_classify_request_matrix,
    _t_side_effect_env_override,
    _t_readonly_endpoint_file,
    _t_side_effect_recorder_and_suffix,
    _t_golden_identity,
    _t_side_effect_merge_golden_semantics,
    _t_validate_tolerates_observed_mirror,
    _t_normalize_url_relative,
    _t_normalize_url_rewrites_localhost,
    _t_normalize_url_keeps_external,
    _t_validate_accepts_good,
    _t_validate_rejects_missing_steps,
    _t_validate_rejects_bad_action,
    _t_validate_accepts_not_yet,
    _t_resolve_role_degrades_to_text,
    _t_resolve_label_degrades_to_placeholder,
    _t_resolve_simple_kinds,
    _t_verdict_matrix,
    _t_results_md_roundtrip,
    _t_script_md_roundtrip,
    _t_regression_verdict_matrix,
    _t_regression_results_md,
    _t_launch_chromium_retries,
    _t_derive_happy,
    _t_derive_rejects_untagged_journey,
    _t_derive_rejects_no_expect,
    _t_derive_rejects_no_goto_open,
    _t_derive_rejects_invalid_demo,
    _t_derive_prefix_without_journey_key,
]


def _self_test(_argv: list[str] | None = None) -> int:
    passed = 0
    failed: list[tuple[str, str]] = []
    for check in _SELF_TEST_CHECKS:
        try:
            check()
            passed += 1
        except Exception as exc:  # noqa: BLE001 — report every failure
            failed.append((check.__name__, repr(exc)))
    for name, err in failed:
        print(f"  FAIL {name}: {err}", file=sys.stderr)
    print(f"[demo_runner self-test] {passed} passed, {len(failed)} failed")
    return 1 if failed else 0


# ── browser layer (Playwright; no model in the loop) ─────────────────────────

_PLAYWRIGHT_HELP = (
    "[demo_runner] Playwright (Python) is not available.\n"
    "  Install (one time, user scope):  python3 -m pip install --user playwright\n"
    "  Browsers cache at ~/.cache/ms-playwright; if missing run:\n"
    "      python3 -m playwright install chromium"
)


def _playwright_available() -> bool:
    try:
        import playwright.sync_api  # noqa: F401
        return True
    except Exception:
        return False


def _rel(path_abs: str, repo_root: str | None) -> str:
    if repo_root:
        try:
            return os.path.relpath(path_abs, repo_root)
        except ValueError:
            return path_abs
    return path_abs


def _locator_for(page, spec: tuple):
    kind, role, value = spec
    if kind == "role":
        return page.get_by_role(role, name=value)
    if kind == "text":
        return page.get_by_text(value)
    if kind == "label":
        return page.get_by_label(value)
    if kind == "placeholder":
        return page.get_by_placeholder(value)
    if kind == "testid":
        return page.get_by_test_id(value)
    return page.locator(value)  # css


def _find(page, target: dict, timeout_ms: int):
    """Resolve a target to a visible locator, trying degraded specs in order.
    Bounded: each spec gets a slice of the budget, so it can never spin."""
    specs = resolve_spec(target)
    if not specs:
        raise RuntimeError(f"unresolvable target {target!r}")
    per = max(800, timeout_ms // len(specs))
    last: Exception | None = None
    for spec in specs:
        loc = _locator_for(page, spec).first
        try:
            loc.wait_for(state="visible", timeout=per)
            return loc
        except Exception as exc:  # noqa: BLE001
            last = exc
    raise last or RuntimeError("not found")


def _check_expect(page, exp: dict, timeout_ms: int) -> bool:
    try:
        if "text" in exp:
            page.get_by_text(exp["text"]).first.wait_for(state="visible", timeout=timeout_ms)
            return True
        if "target" in exp:
            _find(page, exp["target"], timeout_ms)
            return True
    except Exception:
        return False
    return False


def _expect_desc(exp: dict) -> str:
    if "text" in exp:
        return f'"{exp["text"]}"'
    return str(exp.get("target", exp))


def _target_phrase(target: dict) -> str:
    if "role" in target and target.get("name"):
        return f'the "{target["name"]}" {target["role"]}'
    if "label" in target:
        return f'the "{target["label"]}" field'
    for k in ("text", "placeholder", "testid", "css"):
        if k in target:
            return f'"{target[k]}"'
    return "the element"


def _action_phrase(action: dict) -> str:
    """Human-readable one-liner for the demo-script.md `Action:` line."""
    t = action.get("type")
    if t == "goto":
        return f"Navigate to {action.get('url', '/')}"
    if t == "click":
        return f"Click {_target_phrase(action.get('target', {}))}"
    if t == "fill":
        return f'Type "{action.get("text", "")}" into {_target_phrase(action.get("target", {}))}'
    if t == "wait_for":
        return "Wait for the page to settle"
    if t == "expect":
        return f"Expect {_expect_desc(action)}"
    return str(t or "")


def _do_action(page, action: dict, base_url: str, timeout_ms: int) -> None:
    t = action.get("type")
    if t == "goto":
        page.goto(normalize_url(base_url, action.get("url", "/")),
                  wait_until="domcontentloaded", timeout=timeout_ms)
        try:
            page.wait_for_load_state("networkidle", timeout=min(timeout_ms, 12000))
        except Exception:
            pass  # SPA may never go idle — best-effort
        return
    if t == "wait_for":
        if "ms" in action:
            page.wait_for_timeout(int(action["ms"]))
            return
        _find(page, action.get("target", {}), timeout_ms)
        return
    if t == "click":
        _find(page, action["target"], timeout_ms).click(timeout=timeout_ms)
        return
    if t == "fill":
        _find(page, action["target"], timeout_ms).fill(action.get("text", ""), timeout=timeout_ms)
        return
    if t == "expect":
        if not _check_expect(page, action, timeout_ms):
            raise RuntimeError("expect not satisfied")
        return
    raise RuntimeError(f"unknown action type {t!r}")


def _highlight(page, loc) -> None:
    try:
        loc.scroll_into_view_if_needed(timeout=2000)
    except Exception:
        pass
    try:
        loc.evaluate(
            "el => { el.setAttribute('data-demo-prev', el.style.outline || '');"
            " el.style.outline = '3px solid #ff3b30'; el.style.outlineOffset = '2px'; }")
    except Exception:
        pass


def _unhighlight(page, loc) -> None:
    try:
        loc.evaluate("el => { el.style.outline = el.getAttribute('data-demo-prev') || ''; }")
    except Exception:
        pass


def _caption(page, text: str) -> None:
    try:
        page.evaluate(
            """(t) => { let b = document.getElementById('__demo_caption');
              if (!b) { b = document.createElement('div'); b.id='__demo_caption';
                b.style.cssText='position:fixed;left:0;right:0;top:0;z-index:2147483647;'
                  +'background:rgba(17,17,17,.92);color:#fff;font:16px/1.5 system-ui,sans-serif;'
                  +'padding:12px 18px;text-align:center;';
                document.body.appendChild(b); }
              b.textContent = t; }""", text)
    except Exception:
        pass


# Loading indicators that, while present, mean the page is mid-render — capturing
# now would screenshot an empty skeleton. Best-effort union; absent on most pages.
_LOADING_SELECTOR = (
    '[aria-busy="true"], [role="progressbar"], [data-loading="true"], '
    '.loading, .spinner, .skeleton, [class*="skeleton"], [class*="Skeleton"]'
)


def _settle_for_capture(page, budget_ms: int) -> None:
    """Best-effort wait for the page to finish loading before a screenshot, so the
    gallery never captures a spinner / empty skeleton. NEVER raises — the demo is a
    showcase, not a gate.

    Three guards, each bounded by the budget: (1) network goes idle so client-side
    fetches land; (2) any visible loading indicator disappears; (3) web fonts are
    ready, plus a short paint settle. An SPA that long-polls may never reach idle,
    which is exactly why every step is best-effort and falls through on timeout."""
    budget_ms = max(1000, min(int(budget_ms), 12000))
    try:
        page.wait_for_load_state("networkidle", timeout=budget_ms)
    except Exception:
        pass  # SPA may never go idle — best-effort
    try:
        loc = page.locator(_LOADING_SELECTOR)
        if loc.count() > 0:
            loc.first.wait_for(state="hidden", timeout=min(budget_ms, 8000))
    except Exception:
        pass  # no indicator, or it never resolved — best-effort
    try:
        page.evaluate("() => (document.fonts ? document.fonts.ready : null)")
    except Exception:
        pass
    try:
        page.wait_for_timeout(400)  # final paint settle
    except Exception:
        pass


def _default_timeout(script: dict, opts) -> int:
    raw = int(script.get("default_timeout_ms", opts.timeout_ms))
    return max(1000, min(raw, 20000))


def _write_skipped_results(opts, reason: str) -> None:
    if not opts.results:
        return
    md = render_results_md(opts.phase_id or "?", opts.base_url, opts.iteration,
                           [], [reason], "SKIPPED", opts.mode)
    Path(opts.results).parent.mkdir(parents=True, exist_ok=True)
    Path(opts.results).write_text(md, encoding="utf-8")


def run_lint(opts) -> int:
    """Validate golden replay scripts WITHOUT a browser (no playwright needed).

    Prints one line per requested journey: `<J-XX> ok` when the golden parses
    and validates, `<J-XX> invalid: <reason>` otherwise (a missing file counts
    as invalid). goal-iter-lean.sh uses this to quarantine broken goldens into
    the LLM lane BEFORE the replay partition — a broken golden used to surface
    only as a replay SKIP that nothing re-confirmed, silently leaving that
    journey unverified for the iteration. Always exits 0; callers decide per
    line."""
    scripts_dir = Path(opts.scripts_dir or ".")
    journeys = [j.strip() for j in (opts.journeys or "").split(",") if j.strip()]
    for jid in journeys:
        sp = scripts_dir / f"{jid}.json"
        if not sp.exists():
            print(f"{jid} invalid: no golden script on file")
            continue
        try:
            data = json.loads(sp.read_text(encoding="utf-8"))
        except Exception as exc:  # noqa: BLE001
            print(f"{jid} invalid: not valid JSON: {str(exc)[:100]}")
            continue
        errs = validate_script(data)
        if errs:
            print(f"{jid} invalid: " + "; ".join(errs)[:160])
        elif isinstance(data, dict) and data.get("not_yet"):
            print(f"{jid} invalid: marked not_yet")
        else:
            print(f"{jid} ok")
    return 0


def derive_golden_steps(demo: object, journey: str) -> "tuple[dict | None, str]":
    """SPEED-21: derive a candidate golden replay script for `journey` from an
    already-recorded demo script (same runner schema — verify ignores the
    demo-only fields). Copy + filter + renumber: the untagged PREFIX steps
    (shared setup before the first journey-tagged step) plus every step tagged
    with this journey; each kept step keeps only n/journey/action/expect/
    timeout_ms. Fail-closed — returns (None, reason) unless the demo
    validates, >=1 step is tagged for the journey, the derived sequence opens
    with a goto, and >=1 TAGGED step carries an expect (a golden with no
    assertions would pass vacuously). A returned script always passes
    validate_script."""
    errors = validate_script(demo)
    if errors:
        return None, "demo script invalid: " + "; ".join(errors)[:160]
    assert isinstance(demo, dict)  # validate_script guarantees this
    if demo.get("not_yet"):
        return None, "demo marked not_yet (no executable steps)"
    steps = demo.get("steps") or []
    # The demo-narrator contract has EVERY step carry a "journey" key, with ""
    # for shared orientation/setup steps — so "untagged" means a FALSY journey
    # value (missing, "", null), not a missing key.
    prefix: list = []
    for s in steps:
        if isinstance(s, dict) and not s.get("journey"):
            prefix.append(s)
        else:
            break
    tagged = [s for s in steps if isinstance(s, dict) and s.get("journey") == journey]
    if not tagged:
        return None, "no steps tagged for this journey"
    if not any(isinstance(s.get("expect"), dict) for s in tagged):
        return None, "no tagged step carries an expect (nothing to assert)"
    out_steps: list = []
    for i, s in enumerate(prefix + tagged, 1):
        ns: dict = {"n": i, "journey": journey, "action": s.get("action")}
        if isinstance(s.get("expect"), dict):
            ns["expect"] = s["expect"]
        if s.get("timeout_ms") is not None:
            ns["timeout_ms"] = s["timeout_ms"]
        out_steps.append(ns)
    first_action = out_steps[0].get("action") or {}
    if not isinstance(first_action, dict) or first_action.get("type") != "goto":
        return None, "derived sequence does not open with a goto"
    golden = {
        "schema_version": 1,
        "journey": journey,
        "name": str(demo.get("name") or journey),
        "default_timeout_ms": demo.get("default_timeout_ms", 8000),
        "steps": out_steps,
    }
    errors = validate_script(golden)
    if errors:
        return None, "derived script failed validation: " + "; ".join(errors)[:160]
    return golden, ""


def run_derive(opts) -> int:
    """SPEED-21 CLI: write candidate goldens (`<J-XX>.json.candidate` in
    --scripts-dir) derived from the --json demo for each --journeys id.
    Prints one parseable line per journey: `<J-XX> derived <path>` or
    `<J-XX> rejected: <reason>`. ALWAYS exits 0 — a rejected candidate is
    never a gate; the shell caller (replay_lane_autoderive_goldens) runs a
    REAL verify pass on every candidate before installing it."""
    journeys = [j.strip() for j in (opts.journeys or "").split(",") if j.strip()]
    if not opts.json or not opts.scripts_dir or not journeys:
        sys.stderr.write("[demo_runner] derive mode needs --json, --scripts-dir and --journeys; nothing derived.\n")
        return 0
    try:
        with open(opts.json, encoding="utf-8") as fh:
            demo = json.load(fh)
    except Exception as exc:  # noqa: BLE001
        for jid in journeys:
            print(f"{jid} rejected: demo JSON unreadable: {str(exc)[:100]}")
        return 0
    outdir = Path(opts.scripts_dir)
    outdir.mkdir(parents=True, exist_ok=True)
    for jid in journeys:
        golden, reason = derive_golden_steps(demo, jid)
        if golden is None:
            print(f"{jid} rejected: {reason}")
            continue
        cand = outdir / f"{jid}.json.candidate"
        cand.write_text(json.dumps(golden, indent=1) + "\n", encoding="utf-8")
        print(f"{jid} derived {cand}")
    return 0


def _launch_chromium(pw, headless: bool, attempts: int = 2, timeout_ms: int = 45000,
                     args: list | None = None):
    """Launch chromium with a bounded timeout and one fast retry.

    A cold chromium on a loaded machine intermittently exceeds Playwright's
    default 30s launch timeout (observed in a real session: one launch timeout
    turned a ~20-min browser-qa step into a ~40-min spike AND left the replay
    lane's journeys silently unverified). Bounded attempts turn that failure
    mode into ≤ ~90s before the caller's fallback engages."""
    last_exc: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            return pw.chromium.launch(headless=headless, timeout=timeout_ms, args=args or [])
        except Exception as exc:  # noqa: BLE001
            last_exc = exc
            print(f"[demo_runner] chromium launch attempt {attempt}/{attempts} failed: "
                  f"{str(exc).splitlines()[0][:140]}", file=sys.stderr)
    assert last_exc is not None
    raise last_exc


def run_record(script: dict, opts, base_url: str) -> int:
    phase_id = opts.phase_id or script.get("phase_id") or "?"
    iteration = opts.iteration if opts.iteration is not None else script.get("iteration")
    out_dir = Path(opts.out_dir or ".").resolve()

    if script.get("not_yet"):
        if opts.results:
            md = render_results_md(phase_id, base_url, iteration, [], [], "NOT_YET", "record")
            Path(opts.results).parent.mkdir(parents=True, exist_ok=True)
            Path(opts.results).write_text(md, encoding="utf-8")
        print("[demo_runner] nothing to demo yet (NOT_YET).")
        return 0

    from playwright.sync_api import sync_playwright

    steps = script["steps"]
    default_tmo = _default_timeout(script, opts)
    out_dir.mkdir(parents=True, exist_ok=True)
    captured: list[dict] = []
    soft_notes: list[str] = []
    script_steps: list[dict] = []

    with sync_playwright() as pw:
        browser = _launch_chromium(pw, headless=True)
        ctx_kwargs: dict = {"viewport": {"width": 1280, "height": 800}}
        if opts.video:
            ctx_kwargs["record_video_dir"] = str(out_dir / "video")
            ctx_kwargs["record_video_size"] = {"width": 1280, "height": 720}
        context = browser.new_context(**ctx_kwargs)
        page = context.new_page()
        for step in steps:
            n = int(step.get("n", 0))
            section = step.get("section", "highlights")
            tmo = max(1000, min(int(step.get("timeout_ms", default_tmo)), 20000))
            try:
                _do_action(page, step["action"], base_url, tmo)
                acted = True
            except Exception as exc:  # noqa: BLE001 — showcase never raises out
                acted = False
                soft_notes.append(
                    f"Step {n:02d} — couldn't perform "
                    f"{step['action'].get('type')} ({str(exc).splitlines()[0][:120]}); "
                    "captured the page anyway.")
            exp = step.get("expect")
            # The expect is the strongest "content has loaded" signal — wait for it
            # with the FULL step budget (not a 3s cap) so a slow-but-real render is not
            # captured mid-skeleton. Still only a soft note if it never appears.
            if acted and exp and not _check_expect(page, exp, tmo):
                soft_notes.append(
                    f"Step {n:02d} — expected {_expect_desc(exp)} did not appear; recorded anyway.")
            shot_rel = ""
            if section != "full_tour":
                # Settle (network idle + loading indicators gone + paint) so the
                # gallery never captures a spinner / empty skeleton.
                _settle_for_capture(page, tmo)
                shot_abs = out_dir / f"step-{n:02d}.png"
                try:
                    page.screenshot(path=str(shot_abs))
                except Exception:
                    pass
                shot_rel = _rel(str(shot_abs), opts.repo_root)
                captured.append({
                    "n": n, "title": step.get("title", ""),
                    "journey": step.get("journey", ""), "new": step.get("new", False),
                    "screenshot": shot_rel,
                })
            script_steps.append({
                "n": n, "title": step.get("title", ""), "new": step.get("new", False),
                "narration": step.get("narration", ""), "point_out": step.get("point_out", ""),
                "action": _action_phrase(step["action"]), "section": section,
                "screenshot": shot_rel,
            })
        context.close()
        browser.close()

    verdict = compute_verdict(bool(captured), bool(soft_notes), not_yet=False)
    if opts.results:
        Path(opts.results).parent.mkdir(parents=True, exist_ok=True)
        Path(opts.results).write_text(
            render_results_md(phase_id, base_url, iteration, captured, soft_notes, verdict, "record"),
            encoding="utf-8")
    # demo-script.md is regenerated from the JSON (single source of truth) so its
    # captions never drift from what was actually recorded.
    if opts.script_fallback:
        Path(opts.script_fallback).parent.mkdir(parents=True, exist_ok=True)
        Path(opts.script_fallback).write_text(
            render_script_md(phase_id, base_url, iteration, script_steps, "record"), encoding="utf-8")
    print(f"[demo_runner] recorded {len(captured)} step(s) → {out_dir} (verdict: {verdict})")
    return 0


def run_live(script: dict, opts, base_url: str) -> int:
    phase_id = opts.phase_id or script.get("phase_id") or "?"
    if script.get("not_yet"):
        print("\n  Nothing to show yet — no working features to walk through.\n")
        return 0

    from playwright.sync_api import sync_playwright

    steps = script["steps"]
    total = len(steps)
    default_tmo = _default_timeout(script, opts)
    print(f"\n  Live walkthrough of {phase_id} — {total} step(s). "
          "A Chrome window will open; press Enter in THIS terminal to advance.\n")

    with sync_playwright() as pw:
        browser = _launch_chromium(pw, headless=False, args=["--start-maximized"])
        context = browser.new_context(no_viewport=True)
        page = context.new_page()
        for i, step in enumerate(steps, 1):
            title = step.get("title", "")
            tag = "  [NEW]" if step.get("new") else ""
            print(f"\n── Step {i:02d}/{total:02d} ─ {title}{tag}")
            if step.get("narration"):
                print(f"   {step['narration']}")
            tmo = max(1000, min(int(step.get("timeout_ms", default_tmo)), 20000))
            action = step["action"]
            loc = None
            target = action.get("target")
            if target:
                try:
                    loc = _find(page, target, min(tmo, 4000))
                    _highlight(page, loc)
                except Exception:
                    loc = None
            if opts.caption and step.get("narration"):
                _caption(page, step["narration"])
            try:
                input("   ▶ Press Enter (in this terminal) to perform this step… ")
            except EOFError:
                pass
            try:
                _do_action(page, action, base_url, tmo)
                _settle_for_capture(page, tmo)  # let content load before the human looks
                if step.get("point_out"):
                    print(f"   ↳ Notice: {step['point_out']}")
            except Exception as exc:  # noqa: BLE001
                print(f"   ⚠ Couldn't find that element — skipping this step. "
                      f"({str(exc).splitlines()[0][:120]})")
            finally:
                if loc is not None:
                    _unhighlight(page, loc)
        print("\n   That's the full tour.")
        try:
            input("   Press Enter to finish and close the browser… ")
        except EOFError:
            pass
        context.close()
        browser.close()
    return 0


class _SideEffectRun:
    """HARD-3 observer state for one run_verify invocation. Inert (every method a
    no-op, row text unchanged) unless --side-effects-out or --side-effects-run-out
    was given."""

    def __init__(self, opts, base_url: str, phase_id: str, iteration):
        self.sidecar = getattr(opts, "side_effects_out", None)
        self.run_out = getattr(opts, "side_effects_run_out", None)
        self.enabled = bool(self.sidecar or self.run_out)
        self.base_url = base_url
        self.observations: dict = {}
        self._cur = None
        self._golden = None
        self._attached = False
        self._flushed = False
        if not self.enabled:
            return
        try:
            self._setup(opts, phase_id, iteration)
        except Exception as exc:  # noqa: BLE001 — the replay verdict must not depend on the observer
            self.enabled = False
            print(f"[demo_runner] side-effect observer DISABLED for this run ({exc}); no observation is "
                  "recorded and nothing recorded earlier is changed", file=sys.stderr)

    def _setup(self, opts, phase_id: str, iteration) -> None:
        self.ignore, rejected = side_effect_ignore_paths_report()
        for bad in rejected:
            print(f"[demo_runner] side effects: CHAIN_SIDE_EFFECT_IGNORE_PATHS entry {bad!r} REJECTED (it names "
                  "'/' or an API root and would silence real mutations) — not applied", file=sys.stderr)
        root = Path(getattr(opts, "repo_root", None) or ".")
        self.ro = load_readonly_endpoints(root / READONLY_ENDPOINTS_RELPATH)
        if self.ro["error"]:
            print(f"[demo_runner] side effects: {self.ro['path']} is {self.ro['error']} — NO read-only "
                  "exception is applied this run (every listed POST counts as a mutation)", file=sys.stderr)
        for bad in self.ro["invalid"]:
            print(f"[demo_runner] side effects: ignoring invalid exception line {bad['line']} "
                  f"({bad['text']!r}): {bad['reason']}", file=sys.stderr)
        it = iteration
        try:
            it = int(it) if it is not None else None
        except (TypeError, ValueError):
            it = None
        if it is None:
            m = re.search(r"-iter-(\d+)$", phase_id or "")
            it = int(m.group(1)) if m else None
        observed_at = _utc_now_precise()
        stamp = re.sub(r"[^0-9]", "", observed_at)
        self.meta = {
            "run_id": f"{phase_id}:{stamp}:{os.getpid()}",
            "iter": it,
            "iter_name": phase_id,
            "observed_at": observed_at,
            "classifier_version": SIDE_EFFECT_CLASSIFIER_VERSION,
            "readonly_endpoints_sha256": self.ro["sha256"],
            "readonly_endpoints_error": self.ro["error"],
            "ignore_paths": list(self.ignore),
            "ignore_paths_rejected": list(rejected),
        }

    def begin(self, jid: str, context, script=None) -> None:
        if not self.enabled:
            return
        rec = SideEffectRecorder(self.base_url, self.ignore, self.ro["entries"])
        self._cur = (jid, rec)
        self._golden = golden_identity(script)
        self._attached = False
        # Context-level: covers every page and popup the journey opens.
        try:
            context.on("request", rec.on_request)
            self._attached = True
        except Exception:  # noqa: BLE001 — fall back to the page in attach_page
            self._attached = False

    def attach_page(self, page) -> None:
        if not self.enabled or self._cur is None or self._attached:
            return
        try:
            page.on("request", self._cur[1].on_request)
            self._attached = True
        except Exception as exc:  # noqa: BLE001
            print(f"[demo_runner] side effects: request observer could not attach for {self._cur[0]}: "
                  f"{str(exc).splitlines()[0][:120]}", file=sys.stderr)

    def end(self, verdict: str) -> str:
        """Close the current journey; returns the row's Actual-cell suffix."""
        if not self.enabled or self._cur is None:
            return ""
        jid, rec = self._cur
        self._cur = None
        summ = rec.summary()
        # Only a clean, fully observed PASS may later CLEAR an earlier mutation;
        # a blind or error-hit observation can only ever add one.
        complete = verdict == "PASS" and self._attached and summ["observer_errors"] == 0
        obs = _observation_record(summ, verdict, complete, self.meta)
        obs["observer_attached"] = self._attached
        obs["golden_sha256"] = self._golden
        self.observations[jid] = obs
        if not self._attached:
            return "; side effects: NOT observed (the request observer could not attach)"
        return render_side_effect_suffix(summ, partial=(verdict != "PASS"))

    def abort(self) -> None:
        if self._cur is not None:
            self.end("INFRA")

    def flush(self) -> None:
        if not self.enabled or self._flushed:
            return
        self._flushed = True
        try:
            self._flush()
        except Exception as exc:  # noqa: BLE001 — bookkeeping never changes the replay outcome
            print(f"[demo_runner] side-effect bookkeeping failed ({exc}); the replay verdict is unaffected",
                  file=sys.stderr)

    def _write_record(self, state: dict) -> None:
        if not self.run_out:
            return
        record = dict(self.meta)
        record.update({
            "schema_version": 1,
            "base_url": self.base_url,
            "readonly_endpoints": {k: self.ro[k] for k in ("path", "present", "sha256", "invalid", "error")},
            "journeys": self.observations,
            "sidecar": state,
        })
        try:
            Path(self.run_out).parent.mkdir(parents=True, exist_ok=True)
            _atomic_write_json(self.run_out, record)
        except OSError as exc:
            print(f"[demo_runner] side-effect run record not written ({exc})", file=sys.stderr)

    def _flush(self) -> None:
        if not (self.sidecar and self.observations):
            self._write_record({"path": self.sidecar, "updated": False,
                                "message": "not requested" if not self.sidecar else "no journey was replayed"})
            return
        # The durable per-run record is written FIRST, so an interruption before
        # the sidecar update can never leave an observation only in the sidecar.
        self._write_record({"path": self.sidecar, "updated": False, "message": "pending"})
        notes: dict = {}
        ok, msg = update_side_effects_sidecar(self.sidecar, self.observations, notes=notes,
                                              lock_timeout=side_effect_lock_timeout(),
                                              run_id=self.meta.get("run_id"))
        state = {"path": self.sidecar, "updated": ok, "message": msg}
        if ok and notes:
            # A complete clean replay that could NOT clear an earlier mutation
            # (recorded under another golden): the journey stays mutating.
            state["clear_refused"] = notes
        if not ok:
            print(f"[demo_runner] side-effect sidecar NOT updated ({msg}); the replay verdict is unaffected. "
                  "This run's record keeps the observations and the next preflight merges them.",
                  file=sys.stderr)
        self._write_record(state)


def run_verify(opts, base_url: str) -> int:
    """Deterministic regression replay (no model in the loop).

    Replays each listed journey's stored golden script (`<scripts-dir>/<J-XX>.json`)
    in a FRESH browser context — so each journey's own sign-in/setup runs from a
    clean state and journeys never bleed into each other — treats every step's
    `expect` as a HARD assertion, captures one end-state screenshot per journey for
    evidence, and writes a ui-test-results.md the goal-evaluator consumes unchanged.

    Returns 0 when nothing failed, 5 when ≥1 journey FAILED (so the caller can
    re-confirm just those journeys with the LLM agent — guards against a brittle
    selector causing a false regression). A journey with no/invalid golden script
    is SKIP (the caller routes those to the LLM lane).

    HARD-3: with --side-effects-out / --side-effects-run-out the side-effect
    observer is attached to every journey's context (see the module docstring);
    its bookkeeping never alters a verdict or the return code."""
    from playwright.sync_api import sync_playwright

    scripts_dir = Path(opts.scripts_dir or ".")
    journeys = [j.strip() for j in (opts.journeys or "").split(",") if j.strip()]
    phase_id = opts.phase_id or "?"
    iteration = opts.iteration
    evidence_dir = Path(opts.evidence_dir) if opts.evidence_dir else None
    if evidence_dir:
        evidence_dir.mkdir(parents=True, exist_ok=True)

    observer = _SideEffectRun(opts, base_url, phase_id, iteration)

    def _write(results: list[dict]) -> None:
        if opts.results:
            Path(opts.results).parent.mkdir(parents=True, exist_ok=True)
            Path(opts.results).write_text(
                render_regression_results_md(phase_id, base_url, iteration, results, "verify"),
                encoding="utf-8")
        observer.flush()

    if not journeys:
        _write([])
        print("[demo_runner] verify: no journeys to replay (SKIPPED).")
        return 0

    results: list[dict] = []
    try:
        with sync_playwright() as pw:
            browser = _launch_chromium(pw, headless=True)
            for jid in journeys:
                sp = scripts_dir / f"{jid}.json"
                if not sp.exists():
                    results.append({"journey": jid, "name": jid, "verdict": "SKIP",
                                    "expected": "replay golden script",
                                    "actual": "no golden script on file", "evidence": "none"})
                    continue
                try:
                    data = json.loads(sp.read_text(encoding="utf-8"))
                except Exception as exc:  # noqa: BLE001
                    results.append({"journey": jid, "name": jid, "verdict": "SKIP",
                                    "expected": "replay golden script",
                                    "actual": f"golden script not valid JSON: {str(exc)[:120]}",
                                    "evidence": "none"})
                    continue
                errs = validate_script(data)
                if errs or data.get("not_yet"):
                    results.append({"journey": jid, "name": jid, "verdict": "SKIP",
                                    "expected": "replay golden script",
                                    "actual": "invalid golden script: " + "; ".join(errs) if errs
                                    else "golden script marked not_yet", "evidence": "none"})
                    continue
                name = data.get("name") or data.get("title") or jid
                steps = data.get("steps") or []
                default_tmo = _default_timeout(data, opts)
                context = browser.new_context(viewport={"width": 1280, "height": 800})
                observer.begin(jid, context, data)
                page = context.new_page()
                observer.attach_page(page)
                verdict, actual = "PASS", "journey replayed end-to-end; all expects held"
                for step in steps:
                    n = int(step.get("n", 0))
                    tmo = max(1000, min(int(step.get("timeout_ms", default_tmo)), 20000))
                    try:
                        _do_action(page, step["action"], base_url, tmo)
                    except Exception as exc:  # noqa: BLE001
                        verdict = "FAIL"
                        actual = (f"step {n:02d} could not perform "
                                  f"{step['action'].get('type')}: {str(exc).splitlines()[0][:140]}")
                        break
                    exp = step.get("expect")
                    if exp and not _check_expect(page, exp, tmo):
                        verdict = "FAIL"
                        actual = f"step {n:02d} expected {_expect_desc(exp)} did not appear"
                        break
                shot_rel = "none"
                if evidence_dir:
                    _settle_for_capture(page, default_tmo)
                    shot_abs = evidence_dir / f"{jid}-verify.png"
                    try:
                        page.screenshot(path=str(shot_abs))
                        shot_rel = _rel(str(shot_abs), opts.repo_root)
                    except Exception:  # noqa: BLE001
                        pass
                actual += observer.end(verdict)
                results.append({"journey": jid, "name": name, "verdict": verdict,
                                "expected": "journey replays end-to-end; all expects hold",
                                "actual": actual, "evidence": shot_rel})
                context.close()
            browser.close()
    except Exception as exc:  # noqa: BLE001
        # Browser INFRASTRUCTURE failure (launch timeout, mid-run crash) — not a
        # journey verdict. Record what did not get replayed and return 6 so the
        # caller (goal-iter-lean.sh) routes every replay journey back to the LLM
        # lane. Previously this crashed with rc=1 and the replay journeys were
        # silently left unverified for the iteration.
        observer.abort()   # a journey interrupted mid-replay keeps what it DID observe (partial)
        done = {r["journey"] for r in results}
        for jid in journeys:
            if jid not in done:
                results.append({"journey": jid, "name": jid, "verdict": "SKIP",
                                "expected": "replay golden script",
                                "actual": "browser infrastructure failure: "
                                          + str(exc).splitlines()[0][:140],
                                "evidence": "none"})
        _write(results)
        print("[demo_runner] verify: browser infrastructure failure — routing replay "
              f"journeys to the LLM lane (rc 6): {str(exc).splitlines()[0][:140]}",
              file=sys.stderr)
        return 6

    _write(results)
    overall = compute_regression_verdict(results)
    n_fail = sum(1 for r in results if r["verdict"] == "FAIL")
    print(f"[demo_runner] verify: {len(results)} journey(s), {n_fail} failed (verdict: {overall})")
    return 5 if n_fail else 0


def main(argv: list[str]) -> int:
    if argv and argv[0] in ("self-test", "--self-test"):
        return _self_test(argv[1:])

    import argparse
    p = argparse.ArgumentParser(prog="demo_runner.py", description="Deterministic browser demo executor.")
    p.add_argument("--json", default=None, help="path to the executable demo-script JSON (record/live)")
    p.add_argument("--mode", default="record", choices=["live", "record", "session-live", "verify", "lint", "derive"])
    p.add_argument("--base-url", default="http://localhost:3000")
    p.add_argument("--out-dir", default=None, help="screenshot dir, e.g. reports/demo/<id>")
    p.add_argument("--results", default=None, help="demo-results.md output path")
    p.add_argument("--script-fallback", default=None, help="demo-script.md path (written only if absent)")
    p.add_argument("--phase-id", default=None)
    p.add_argument("--iteration", default=None)
    p.add_argument("--video", action="store_true")
    p.add_argument("--caption", action="store_true")
    p.add_argument("--repo-root", default=None)
    p.add_argument("--timeout-ms", type=int, default=8000)
    p.add_argument("--scripts-dir", default=None,
                   help="verify mode: dir of per-journey golden scripts (<J-XX>.json)")
    p.add_argument("--journeys", default=None,
                   help="verify mode: comma-separated journey IDs to replay")
    p.add_argument("--evidence-dir", default=None,
                   help="verify mode: per-journey screenshot evidence dir")
    p.add_argument("--side-effects-out", default=None,
                   help="verify mode (HARD-3): engine-owned sidecar "
                        "runs/goal-session-<sid>/state/journey-side-effects.json, updated read-modify-write")
    p.add_argument("--side-effects-run-out", default=None,
                   help="verify mode (HARD-3): per-run observation record (the lane's telemetry source)")
    opts = p.parse_args(argv)
    live = opts.mode in ("live", "session-live")
    verify = opts.mode == "verify"

    if opts.mode == "lint":
        return run_lint(opts)   # pure validation — needs no browser/playwright

    if opts.mode == "derive":
        return run_derive(opts)  # pure transform (SPEED-21) — no browser/playwright

    if not _playwright_available():
        sys.stderr.write(_PLAYWRIGHT_HELP + "\n")
        if not live and not verify:
            _write_skipped_results(opts, "Playwright (Python) not installed; demo skipped.")
        return 3

    if live and not os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY"):
        if os.environ.get("CHAIN_DEMO_LIVE_FALLBACK_RECORD", "").lower() in ("1", "true", "yes"):
            opts.mode, live = "record", False
            sys.stderr.write("[demo_runner] No display — falling back to record mode.\n")
        else:
            sys.stderr.write(
                "[demo_runner] Live mode needs a display (X11/Wayland). Set DISPLAY, run record "
                "mode (./scripts/automation/demo.sh <id>), or set CHAIN_DEMO_LIVE_FALLBACK_RECORD=true.\n")
            return 4

    if verify:
        return run_verify(opts, opts.base_url or "http://localhost:3000")

    if not opts.json:
        sys.stderr.write("[demo_runner] --json is required for record/live modes.\n")
        return 2

    try:
        with open(opts.json, encoding="utf-8") as fh:
            script = json.load(fh)
    except FileNotFoundError:
        sys.stderr.write(f"[demo_runner] demo JSON not found: {opts.json}\n")
        if not live:
            _write_skipped_results(opts, f"demo JSON not found: {opts.json}")
        return 2
    except json.JSONDecodeError as exc:
        sys.stderr.write(f"[demo_runner] demo JSON is not valid JSON: {exc}\n")
        if not live:
            _write_skipped_results(opts, f"demo JSON parse error: {exc}")
        return 2

    errors = validate_script(script)
    if errors:
        sys.stderr.write("[demo_runner] invalid demo script: " + "; ".join(errors) + "\n")
        if not live:
            _write_skipped_results(opts, "invalid demo script: " + "; ".join(errors))
        return 2

    base_url = opts.base_url or script.get("base_url") or "http://localhost:3000"
    if opts.phase_id is None:
        opts.phase_id = script.get("phase_id")
    if opts.iteration is None:
        opts.iteration = script.get("iteration")

    return run_live(script, opts, base_url) if live else run_record(script, opts, base_url)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
