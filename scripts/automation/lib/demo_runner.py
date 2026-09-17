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
import hashlib
import json
import os
import re
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
# browser issues a same-project POST/PUT/PATCH/DELETE from a fetch/xhr call or a
# document (form) navigation. Observation outranks the owner's declaration in
# docs/goal.md: an owner `none` never hides an observed, unlisted mutation. The
# ONLY owner remedy for a legitimately read-only POST is the digest-tracked
# exception file below, and every applied exception is reported, never silent.
# Only {method, path} is ever recorded — never a query string, header or body.
_MUTATING_METHODS = frozenset({"POST", "PUT", "PATCH", "DELETE"})
_SIDE_EFFECT_RESOURCE_TYPES = frozenset({"fetch", "xhr", "document"})
# Development-server plumbing (HMR, overlays) — never product state.
_DEV_ASSET_PREFIXES = ("/_next/", "/__nextjs", "/sockjs-node", "/@vite", "/__vite")
# Session plumbing a journey's own sign-in performs. Matched as a contiguous run
# of whole path segments anywhere in the path (`/api/login` matches `/login`;
# `/api/login-history` does not). CHAIN_SIDE_EFFECT_IGNORE_PATHS (comma list)
# REPLACES this list; set-but-empty disables every auth exclusion.
_DEFAULT_AUTH_IGNORE_PATHS = ("/login", "/logout", "/auth", "/session", "/token", "/csrf")
_SIDE_EFFECT_LOCAL_HOSTS = frozenset(_LOCAL_HOSTS | {"::1"})
# Owner-authored, digest-tracked exceptions: one `METHOD /path-prefix` per line.
READONLY_ENDPOINTS_RELPATH = "project-extensions/side-effects/read-only-endpoints.txt"
SIDE_EFFECT_SAMPLE_CAP = 20
SIDE_EFFECT_HISTORY_CAP = 5
# A path that walks up or hides a walk-up can never be matched against an
# exception or an auth exclusion — it is classified mutating (fail closed).
_DOT_SEGMENTS = frozenset({".", "..", "%2e", "%2e%2e", ".%2e", "%2e."})


def _path_segments(path: str) -> list[str]:
    return [s for s in (path or "").split("/") if s]


def _has_dot_segment(segments: list[str]) -> bool:
    return any(s.lower() in _DOT_SEGMENTS for s in segments)


def _segments_contain(hay: list[str], needle: list[str]) -> bool:
    n = len(needle)
    if n == 0:
        return False
    h = [s.lower() for s in hay]
    nd = [s.lower() for s in needle]
    return any(h[i:i + n] == nd for i in range(len(h) - n + 1))


def side_effect_ignore_paths(env=None) -> tuple:
    """The auth/session exclusions in force. UNSET → the documented default list;
    SET (even empty) → exactly the listed paths (a bare '/' is never accepted —
    it would silence the whole observer)."""
    env = os.environ if env is None else env
    raw = env.get("CHAIN_SIDE_EFFECT_IGNORE_PATHS")
    if raw is None:
        return _DEFAULT_AUTH_IGNORE_PATHS
    out: list[str] = []
    for part in raw.split(","):
        segs = _path_segments(part.strip())
        if not segs or _has_dot_segment(segs):
            continue
        p = "/" + "/".join(segs)
        if p not in out:
            out.append(p)
    return tuple(out)


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
        if _has_dot_segment(segs):
            invalid.append((lineno, raw.strip(), "dot segments are not allowed in an exception"))
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


def classify_candidate(method: str, path: str, ignored_paths, readonly_endpoints) -> str:
    """Class of a request ALREADY known to be a same-project mutating-method
    fetch/xhr/document request. Pure; shared with the ledger builder
    (goal_gate.py), which re-checks recorded requests when the exception file or
    the auth list changed since they were observed."""
    segs = _path_segments(path)
    if _has_dot_segment(segs):
        return "mutating"
    for ip in ignored_paths or ():
        if _segments_contain(segs, _path_segments(ip)):
            return "ignored-auth"
    m = (method or "").upper()
    for em, ep in readonly_endpoints or ():
        eps = _path_segments(ep)
        if str(em).upper() == m and eps and segs[:len(eps)] == eps:
            return "ignored-readonly"
    return "mutating"


def classify_request(method, resource_type, url, base_url, ignored_paths=None,
                     readonly_endpoints=()) -> "str | None":
    """'mutating' | 'ignored-auth' | 'ignored-readonly' | None (not a side effect).

    None: a non-mutating method, a resource type other than fetch/xhr/document,
    a non-http(s) URL, a different host (external analytics/CDN), or development
    plumbing. Same project = the base URL's host, or any loopback host when the
    base is loopback (the frontend on :3xxx calling the backend on :8xxx)."""
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
    if host != base_host and not (host in _SIDE_EFFECT_LOCAL_HOSTS
                                  and (not base_host or base_host in _SIDE_EFFECT_LOCAL_HOSTS)):
        return None
    path = u.path or "/"
    if path.startswith(_DEV_ASSET_PREFIXES):
        return None
    if ignored_paths is None:
        ignored_paths = side_effect_ignore_paths()
    return classify_candidate(m, path, ignored_paths, readonly_endpoints)


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
        self._exceptions: dict = {}
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
            if cls == "ignored-readonly" and key not in self._exceptions and len(self._exceptions) < self.cap:
                self._exceptions[key] = {"method": key[0], "path": key[1]}
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
            "exceptions_applied": [dict(e) for e in self._exceptions.values()],
            "observer_errors": self._errors,
        }


def render_side_effect_suffix(summary: dict, partial: bool = False) -> str:
    """The results row's Actual-cell suffix. Never contains a table pipe."""
    head = "side effects before the replay stopped" if partial else "side effects"
    n = int(summary.get("mutating_count") or 0)
    if n > 0:
        pairs = [f"{r.get('method')} {r.get('path')}" for r in summary.get("requests") or []
                 if r.get("class") == "mutating"]
        shown = pairs[:3]
        detail = ", ".join(shown)
        if len(pairs) > len(shown):
            detail += f" +{len(pairs) - len(shown)} more"
        if summary.get("truncated"):
            detail += (" " if detail else "") + "(sample truncated)"
        text = f"; {head}: {n} mutating request(s)" + (f" ({detail})" if detail else "")
    else:
        text = f"; {head}: none observed"
    exc = summary.get("exceptions_applied") or []
    if exc:
        text += "; read-only exception applied: " + ", ".join(
            f"{e.get('method')} {e.get('path')}" for e in exc[:3])
        if len(exc) > 3:
            text += f" +{len(exc) - 3} more"
    return text.replace("|", "%7C").replace("\n", " ")


def _utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def merge_side_effect_observations(sidecar, observations: dict, now: "str | None" = None) -> dict:
    """Pure merge of this run's per-journey observations into the sidecar dict.

    Only the `journeys` records of the observed journeys change; every other key
    (the engine's declaration bookkeeping) and every other journey is kept.
    `last_attempt` is always the newest observation. `latest` — the record the
    ledger's status is derived from — is replaced by a COMPLETE replay, or by a
    partial replay that did mutate: a replay that stopped early can upgrade a
    journey to mutating but can never clear an earlier mutation."""
    data = sidecar if isinstance(sidecar, dict) else {}
    data.setdefault("schema_version", 1)
    journeys = data.get("journeys")
    if not isinstance(journeys, dict):
        journeys = {}
        data["journeys"] = journeys
    for jid, obs in (observations or {}).items():
        if not isinstance(obs, dict):
            continue
        rec = journeys.get(jid)
        if not isinstance(rec, dict):
            rec = {}
        try:
            mut = int(obs.get("mutating_count") or 0)
        except (TypeError, ValueError):
            mut = 1  # an unreadable count is treated as a mutation (fail closed)
        rec["last_attempt"] = obs
        if obs.get("complete") is True or mut > 0:
            rec["latest"] = obs
        if mut > 0:
            prior = rec.get("mutating_history")
            hist = [h for h in prior if isinstance(h, dict)] if isinstance(prior, list) else []
            hist.append({
                "iter": obs.get("iter"), "iter_name": obs.get("iter_name"), "run_id": obs.get("run_id"),
                "sample": [f"{r.get('method')} {r.get('path')}" for r in (obs.get("requests") or [])
                           if isinstance(r, dict) and r.get("class") == "mutating"][:3],
            })
            rec["mutating_history"] = hist[-SIDE_EFFECT_HISTORY_CAP:]
        journeys[jid] = rec
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
                    raise TimeoutError(f"could not lock {dirpath} within {timeout:.0f}s")
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


def _sidecar_shape_error(current) -> "str | None":
    """Why an existing sidecar may not be merged into, or None."""
    if not isinstance(current, dict):
        return "the top level is not an object"
    journeys = current.get("journeys", {})
    if not isinstance(journeys, dict):
        return "'journeys' is not an object"
    for jid, rec in journeys.items():
        if not isinstance(rec, dict):
            return f"record {jid} is not an object"
        for key in ("latest", "last_attempt"):
            if key in rec and not isinstance(rec[key], dict):
                return f"record {jid}.{key} is not an object"
        if "mutating_history" in rec and not isinstance(rec["mutating_history"], list):
            return f"record {jid}.mutating_history is not a list"
    return None


def update_side_effects_sidecar(path, observations: dict, lock_timeout: float = 10.0) -> "tuple[bool, str]":
    """Read-modify-write the engine-owned sidecar. A corrupt or wrongly-shaped
    existing file is NEVER overwritten: losing recorded mutations would silently
    downgrade journeys to their declarations (the ledger reports it instead)."""
    p = Path(path)
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        with _locked_dir(p.parent, lock_timeout):
            current = None
            if p.exists():
                try:
                    current = json.loads(p.read_text(encoding="utf-8"))
                except (OSError, ValueError) as exc:
                    return False, (f"{p} is unreadable or corrupt ({exc}) — not overwritten; "
                                   "inspect or move it aside, then re-run")
                shape_error = _sidecar_shape_error(current)
                if shape_error:
                    return False, f"{p} has the wrong shape ({shape_error}) — not overwritten"
            try:
                merged = merge_side_effect_observations(current, observations)
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


def _t_side_effect_env_override() -> None:
    assert side_effect_ignore_paths({}) == _DEFAULT_AUTH_IGNORE_PATHS
    assert side_effect_ignore_paths({"CHAIN_SIDE_EFFECT_IGNORE_PATHS": ""}) == ()
    assert side_effect_ignore_paths({"CHAIN_SIDE_EFFECT_IGNORE_PATHS": "signin, /, /api/x/"}) == ("/signin", "/api/x")


def _t_readonly_endpoint_file() -> None:
    entries, invalid = parse_readonly_endpoints("# c\nPOST /api/a # x\nGET /b\nPOST /\n")
    assert entries == [("POST", "/api/a")], entries
    assert [i[0] for i in invalid] == [3, 4], invalid


def _t_side_effect_recorder_and_suffix() -> None:
    class _R:
        def __init__(self, m, t, u):
            self.method, self.resource_type, self.url = m, t, u
    rec = SideEffectRecorder("http://localhost:3017", (), [("POST", "/api/eval")])
    for r in (_R("POST", "fetch", "/api/runs"), _R("POST", "fetch", "/api/eval"), _R("GET", "fetch", "/api/runs")):
        rec.on_request(r)
    s = rec.summary()
    assert s["mutating_count"] == 1 and s["readonly_count"] == 1, s
    assert render_side_effect_suffix(s) == ("; side effects: 1 mutating request(s) (POST /api/runs); "
                                            "read-only exception applied: POST /api/eval"), render_side_effect_suffix(s)
    assert render_side_effect_suffix(SideEffectRecorder("http://x").summary()) == "; side effects: none observed"


def _t_side_effect_merge_never_downgrades_on_partial() -> None:
    mut = {"complete": True, "mutating_count": 1, "requests": [{"method": "POST", "path": "/a", "class": "mutating"}], "iter": 1}
    part = {"complete": False, "mutating_count": 0, "requests": [], "iter": 2}
    clean = {"complete": True, "mutating_count": 0, "requests": [], "iter": 3}
    d = merge_side_effect_observations({"declaration_digest": "x"}, {"J-01": mut})
    d = merge_side_effect_observations(d, {"J-01": part})
    assert d["journeys"]["J-01"]["latest"]["iter"] == 1 and d["journeys"]["J-01"]["last_attempt"]["iter"] == 2
    d = merge_side_effect_observations(d, {"J-01": clean})
    assert d["journeys"]["J-01"]["latest"]["iter"] == 3 and d["declaration_digest"] == "x"


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
    _t_side_effect_merge_never_downgrades_on_partial,
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
        self.ignore = side_effect_ignore_paths()
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
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        self.meta = {
            "run_id": f"{phase_id}:{stamp}:{os.getpid()}",
            "iter": it,
            "iter_name": phase_id,
            "observed_at": _utc_now(),
            "readonly_endpoints_sha256": self.ro["sha256"],
            "readonly_endpoints_error": self.ro["error"],
            "ignore_paths": list(self.ignore),
        }

    def begin(self, jid: str, context) -> None:
        if not self.enabled:
            return
        rec = SideEffectRecorder(self.base_url, self.ignore, self.ro["entries"])
        self._cur = (jid, rec)
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

    def _flush(self) -> None:
        state = {"path": self.sidecar, "updated": False,
                 "message": "not requested" if not self.sidecar else "no journey was replayed"}
        if self.sidecar and self.observations:
            ok, msg = update_side_effects_sidecar(self.sidecar, self.observations)
            state = {"path": self.sidecar, "updated": ok, "message": msg}
            if not ok:
                print(f"[demo_runner] side-effect sidecar NOT updated ({msg}); the replay verdict is unaffected",
                      file=sys.stderr)
        if self.run_out:
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
                observer.begin(jid, context)
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
