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

Exit codes: 0 ok/soft-skip · 2 bad args/JSON · 3 playwright missing · 4 no DISPLAY (live).
"""
from __future__ import annotations

import datetime
import json
import os
import sys
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

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


_SELF_TEST_CHECKS = [
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
            page.wait_for_load_state("networkidle", timeout=min(timeout_ms, 3000))
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
        browser = pw.chromium.launch(headless=True)
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
            if acted and exp and not _check_expect(page, exp, min(tmo, 3000)):
                soft_notes.append(
                    f"Step {n:02d} — expected {_expect_desc(exp)} did not appear; recorded anyway.")
            shot_rel = ""
            if section != "full_tour":
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
        browser = pw.chromium.launch(headless=False, args=["--start-maximized"])
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


def main(argv: list[str]) -> int:
    if argv and argv[0] in ("self-test", "--self-test"):
        return _self_test(argv[1:])

    import argparse
    p = argparse.ArgumentParser(prog="demo_runner.py", description="Deterministic browser demo executor.")
    p.add_argument("--json", required=True, help="path to the executable demo-script JSON")
    p.add_argument("--mode", default="record", choices=["live", "record", "session-live"])
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
    opts = p.parse_args(argv)
    live = opts.mode in ("live", "session-live")

    if not _playwright_available():
        sys.stderr.write(_PLAYWRIGHT_HELP + "\n")
        if not live:
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
