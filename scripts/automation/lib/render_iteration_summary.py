#!/usr/bin/env python3
"""
render_iteration_summary.py — render a self-contained HTML summary of one
pipeline iteration (phase or goal-mode iter) and, in goal mode, a session
index that lists every iteration as a card.

The HTML is the human-readable view layer over the existing markdown
artifacts (closure-verdict, user-visible-changes, what-to-click, ui-test-
results, journey-history). Agent reports are unchanged; this script only
reads them.

Goals:
  - Job 1: verify the iteration in 5 min ("Try it yourself" steps + screenshots)
  - Job 2: decide ship vs continue (verdict banner + still-missing list)
  - Job 3: share with non-devs (single self-contained file with embedded images)

Design:
  - Stdlib only. Optional Pillow used for screenshot resize when available.
  - Graceful degradation: parsers return None for missing sections; renderer
    omits the corresponding accordion. Renderer never raises on missing
    artifacts; it always produces *some* HTML.
  - Self-contained output: inline CSS, inline SVG icons, base64-embedded
    PNG screenshots. No external network references.

Usage:
    python3 render_iteration_summary.py iteration <phase-id>
    python3 render_iteration_summary.py session-index <session-id>
    python3 render_iteration_summary.py self-test
"""
from __future__ import annotations

import base64
import datetime as _dt
import json
import os
import re
import sys
from dataclasses import dataclass, field
from html import escape
from pathlib import Path
from typing import Any, Optional

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────

REPO_ROOT = Path(__file__).resolve().parents[3]

GOAL_ITER_RE = re.compile(r"^goal-(?P<sid>.+)-iter-(?P<n>\d+)$")


# ─────────────────────────────────────────────────────────────────────────────
# Data structures
# ─────────────────────────────────────────────────────────────────────────────


@dataclass
class IterationData:
    """Aggregated inputs to the iteration-level renderer."""

    phase_id: str
    repo_root: Path
    is_goal_iter: bool = False
    session_id: Optional[str] = None
    iter_num: Optional[int] = None

    # Headline
    verdict: str = "IN-PROGRESS"  # PASS / FAIL / IN-PROGRESS
    verdict_source: str = "unknown"  # which file the verdict came from
    one_line_goal: str = ""
    date_str: str = ""

    # Source artifacts (markdown bodies; None if missing)
    plan_md: Optional[str] = None
    closure_verdict_md: Optional[str] = None
    user_visible_changes_md: Optional[str] = None
    what_to_click_md: Optional[str] = None
    ui_test_results_md: Optional[str] = None
    implementation_summary_md: Optional[str] = None
    qa_md: Optional[str] = None
    review_md: Optional[str] = None
    audit_md: Optional[str] = None

    # Parsed sub-data
    journeys: list[dict[str, Any]] = field(default_factory=list)
    screenshots: list[Path] = field(default_factory=list)
    frontend_present: Optional[bool] = None

    # Resolved paths to source MDs (for drill-down links)
    artifact_paths: dict[str, str] = field(default_factory=dict)


@dataclass
class SessionData:
    """Aggregated inputs to the session-index renderer."""

    session_id: str
    repo_root: Path
    goal_title: str = ""
    final_verdict: str = "IN-PROGRESS"
    total_iterations: int = 0
    wall_time_seconds: int = 0
    started_at: str = ""
    finished_at: str = ""
    journeys: list[dict[str, Any]] = field(default_factory=list)
    iterations: list[IterationData] = field(default_factory=list)
    latest_evaluator_note: str = ""


# ─────────────────────────────────────────────────────────────────────────────
# Markdown parsers — minimal, tolerant of missing sections.
# Each returns either the parsed structure or None if the file is empty/missing.
# ─────────────────────────────────────────────────────────────────────────────


def _split_h2_sections(md: str) -> dict[str, str]:
    """Split a markdown document into {h2-title: body} chunks.

    Body excludes the H2 line itself and stops at the next H2 boundary.
    HTML-comment template hints (<!-- ... -->) are stripped from the body
    so they don't leak into rendered output.
    """
    if not md:
        return {}
    sections: dict[str, str] = {}
    current_title: Optional[str] = None
    buf: list[str] = []
    for line in md.splitlines():
        m = re.match(r"^##\s+(.+?)\s*$", line)
        if m:
            if current_title is not None:
                sections[current_title] = _strip_html_comments("\n".join(buf)).strip()
            current_title = m.group(1).strip()
            buf = []
        else:
            buf.append(line)
    if current_title is not None:
        sections[current_title] = _strip_html_comments("\n".join(buf)).strip()
    return sections


def _strip_html_comments(s: str) -> str:
    return re.sub(r"<!--.*?-->", "", s, flags=re.DOTALL)


def _extract_bullets(body: str) -> list[str]:
    """Extract top-level `- ` or `* ` bullets. Skip placeholder bullets that
    are obviously unfilled template angle-bracket lines."""
    bullets: list[str] = []
    for line in body.splitlines():
        m = re.match(r"^\s*[-*]\s+(.+?)\s*$", line)
        if not m:
            continue
        text = m.group(1).strip()
        if _looks_like_template_placeholder(text):
            continue
        bullets.append(text)
    return bullets


def _looks_like_template_placeholder(text: str) -> bool:
    """Detect unfilled template lines like '<action>' or 'Users can now <X>'."""
    # Pure angle-bracket tokens like "<thing>"
    if re.fullmatch(r"<[^>]+>", text):
        return True
    # Lines that are mostly angle-bracket placeholders interleaved with template scaffolding
    placeholders = re.findall(r"<[^>]+>", text)
    if not placeholders:
        return False
    # If the text without placeholders is mostly punctuation, it's a template line
    stripped = re.sub(r"<[^>]+>", "", text).strip(" .,-:;")
    return len(stripped) < 8


def parse_user_visible_changes(md: Optional[str]) -> Optional[dict[str, list[str]]]:
    if not md:
        return None
    sections = _split_h2_sections(md)
    keys = [
        "What Users Can Now Do",
        "What Changed in the Visible UI",
        "What Old Behavior Changed",
        "Not Visible Yet",
    ]
    out: dict[str, list[str]] = {}
    for k in keys:
        body = sections.get(k, "")
        bullets = _extract_bullets(body)
        if bullets:
            out[k] = bullets
    return out or None


def parse_what_to_click(md: Optional[str]) -> Optional[dict[str, Any]]:
    """Return {prerequisites, steps, working_indicators, common_issues}.

    `steps` is a list of {'action': str, 'expect': str|None}. Step body is
    the part after the leading `N. ` token; `expect` is the part of the
    bullet sub-line beginning with `- **Expect:**` (or `- Expect:`).
    """
    if not md:
        return None
    # Detect N/A stubs
    if re.search(r"\bN/?A\b", md[:200], re.IGNORECASE) and len(md) < 400:
        return None
    sections = _split_h2_sections(md)
    prereqs = _extract_bullets(sections.get("Prerequisites", ""))

    steps_body = sections.get("Verification Steps", "")
    steps: list[dict[str, Any]] = []
    # Walk lines; group each `N. ` line with following `   - **Expect:**` line.
    current_step: Optional[dict[str, Any]] = None
    for line in steps_body.splitlines():
        m = re.match(r"^\s*(\d+)\.\s+(.+?)\s*$", line)
        if m:
            if current_step is not None:
                steps.append(current_step)
            current_step = {"action": m.group(2).strip(), "expect": None}
            continue
        # Sub-bullet under a numbered step
        m = re.match(r"^\s*[-*]\s+\*\*Expect:\*\*\s+(.+?)\s*$", line)
        if not m:
            m = re.match(r"^\s*[-*]\s+Expect:\s+(.+?)\s*$", line)
        if m and current_step is not None and current_step["expect"] is None:
            current_step["expect"] = m.group(1).strip()
    if current_step is not None:
        steps.append(current_step)

    # Skip pure-template placeholder steps
    steps = [s for s in steps if not _looks_like_template_placeholder(s["action"])]

    working = _extract_bullets(sections.get('What "Working Correctly" Looks Like', ""))
    issues_body = sections.get("Common Issues", "")
    common_issues = _extract_bullets(issues_body)

    if not steps and not prereqs:
        return None
    return {
        "prerequisites": prereqs,
        "steps": steps,
        "working_indicators": working,
        "common_issues": common_issues,
    }


def parse_closure_verdict(md: Optional[str]) -> Optional[dict[str, Any]]:
    """Return {verdict, blocking_issues}."""
    if not md:
        return None
    verdict_m = re.search(r"\*\*Verdict:\*\*\s*(CLOSURE-PASS|CLOSURE-FAIL)", md)
    verdict = verdict_m.group(1) if verdict_m else "UNKNOWN"
    sections = _split_h2_sections(md)
    blocking_body = sections.get("Blocking Issues", "")
    # Each blocking issue is a numbered or bulleted entry. Extract whole-line
    # text for each item up to the first blank line gap.
    items: list[str] = []
    for line in blocking_body.splitlines():
        if not line.strip():
            continue
        if re.fullmatch(r"None\.?", line.strip(), re.IGNORECASE):
            continue
        m = re.match(r"^\s*(?:\d+\.|[-*])\s+(.+?)\s*$", line)
        if m:
            items.append(m.group(1).strip())
        elif items and (line.startswith("   ") or line.startswith("\t")):
            # continuation of previous item
            items[-1] = items[-1] + " " + line.strip()
    return {"verdict": verdict, "blocking_issues": items}


def parse_ui_test_results(md: Optional[str]) -> Optional[dict[str, Any]]:
    """Return {verdict, evidence_paths (in order), failed_tests, skipped_tests}.

    Evidence paths are collected from the results table 'Evidence' column AND
    from the per-test `**Evidence:**` lines below.
    """
    if not md:
        return None
    verdict_m = re.search(r"\*\*Browser QA Verdict:\*\*\s*(PASS|FAIL|SKIPPED)", md)
    verdict = verdict_m.group(1) if verdict_m else "UNKNOWN"
    # Order-preserving collection of unique evidence paths.
    seen: set[str] = set()
    paths: list[str] = []
    # `**Evidence:**` lines first (these carry priority because they include verdict context).
    for m in re.finditer(r"\*\*Evidence:\*\*\s*`([^`]+\.png)`", md):
        p = m.group(1).strip()
        if p and p not in seen:
            seen.add(p)
            paths.append(p)
    # Table rows: pipe-delimited columns; pick `.png` tokens.
    for line in md.splitlines():
        if "|" not in line:
            continue
        for m in re.finditer(r"([\w./-]+\.png)", line):
            p = m.group(1)
            if p not in seen and "none" not in p.lower():
                seen.add(p)
                paths.append(p)

    sections = _split_h2_sections(md)
    failed = _extract_failed_blocks(sections.get("Failed Tests", ""))
    skipped = _extract_failed_blocks(sections.get("Skipped Tests", ""))
    return {
        "verdict": verdict,
        "evidence_paths": paths,
        "failed_tests": failed,
        "skipped_tests": skipped,
    }


def _extract_failed_blocks(body: str) -> list[dict[str, str]]:
    """Parse `### UT-XX — name` sub-blocks. Returns list of {id, name, body}."""
    if not body:
        return []
    blocks: list[dict[str, str]] = []
    current: Optional[dict[str, str]] = None
    for line in body.splitlines():
        m = re.match(r"^###\s+(UT-\S+)\s*(?:[—\-]\s*)?(.*)$", line)
        if m:
            if current:
                blocks.append(current)
            current = {"id": m.group(1), "name": m.group(2).strip(), "body": ""}
            continue
        if current is not None:
            current["body"] += line + "\n"
    if current:
        blocks.append(current)
    # Skip template stubs
    blocks = [b for b in blocks if not b["id"].lower().startswith("ut-xx")]
    return blocks


def parse_implementation_summary(md: Optional[str]) -> Optional[dict[str, list[str]]]:
    if not md:
        return None
    sections = _split_h2_sections(md)
    keys = [
        "Features Implemented",
        "Changed Behavior",
        "Backend-Only Items",
        "Incomplete Items",
        "Known Limitations",
    ]
    out: dict[str, list[str]] = {}
    for k in keys:
        body = sections.get(k, "")
        bullets = _extract_bullets(body)
        if bullets:
            out[k] = bullets
    return out or None


def parse_journey_history(data: dict[str, Any]) -> list[dict[str, Any]]:
    journeys = data.get("journeys", {}) or {}
    out: list[dict[str, Any]] = []
    for jid, info in sorted(journeys.items()):
        out.append(
            {
                "id": jid,
                "name": info.get("name", jid),
                "status": info.get("status", "unknown"),
                "last_verified_iter": info.get("last_verified_iter"),
                "last_passing_iter": info.get("last_passing_iter"),
                "evidence": info.get("last_evidence_path"),
            }
        )
    return out


def parse_goal_title(goal_md: Optional[str]) -> str:
    if not goal_md:
        return ""
    for line in goal_md.splitlines():
        m = re.match(r"^#\s+(.+?)\s*$", line)
        if m:
            return m.group(1).strip()
    return ""


def parse_frontend_present(plan_md: Optional[str]) -> Optional[bool]:
    if not plan_md:
        return None
    m = re.search(r"^Frontend Present:\s*(yes|no)\b", plan_md, re.IGNORECASE | re.MULTILINE)
    if not m:
        return None
    return m.group(1).lower() == "yes"


def parse_one_line_goal(plan_md: Optional[str]) -> str:
    """Find a useful one-line description from plan.md or fall back to phase id."""
    if not plan_md:
        return ""
    # First H1 or a "Goal:" line
    for line in plan_md.splitlines():
        m = re.match(r"^#\s+(.+?)\s*$", line)
        if m:
            return m.group(1).strip()
        m = re.match(r"^(?:\*\*)?Goal(?:\*\*)?:\s*(.+?)\s*$", line, re.IGNORECASE)
        if m:
            return m.group(1).strip()
    return ""


# ─────────────────────────────────────────────────────────────────────────────
# Data loading
# ─────────────────────────────────────────────────────────────────────────────


def _read_text(path: Path) -> Optional[str]:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    except OSError:
        return None


def load_iteration(phase_id: str, repo_root: Path) -> IterationData:
    """Read every artifact relevant to one iteration."""
    data = IterationData(phase_id=phase_id, repo_root=repo_root)
    m = GOAL_ITER_RE.match(phase_id)
    if m:
        data.is_goal_iter = True
        data.session_id = m.group("sid")
        try:
            data.iter_num = int(m.group("n"))
        except ValueError:
            data.iter_num = None

    artifacts = {
        "plan": f"runs/{phase_id}/plan.md",
        "closure_verdict": f"reports/phase-{phase_id}-closure-verdict.md",
        "user_visible_changes": f"reports/phase-{phase_id}-user-visible-changes.md",
        "what_to_click": f"reports/phase-{phase_id}-what-to-click.md",
        "ui_test_results": f"reports/phase-{phase_id}-ui-test-results.md",
        "implementation_summary": f"reports/phase-{phase_id}-implementation-summary.md",
        "ui_surface_map": f"reports/phase-{phase_id}-ui-surface-map.md",
        "ui_test_plan": f"reports/phase-{phase_id}-ui-test-plan.md",
        "ux_regression": f"reports/phase-{phase_id}-ux-regression.md",
        "qa": f"reports/qa/{phase_id}-qa.md",
        "review": f"reports/reviews/{phase_id}-review.md",
        "audit": f"docs/handoffs/{phase_id}-audit.md",
        "summary_json": f"runs/{phase_id}/summary.json",
    }
    data.artifact_paths = artifacts

    data.plan_md = _read_text(repo_root / artifacts["plan"])
    data.closure_verdict_md = _read_text(repo_root / artifacts["closure_verdict"])
    data.user_visible_changes_md = _read_text(repo_root / artifacts["user_visible_changes"])
    data.what_to_click_md = _read_text(repo_root / artifacts["what_to_click"])
    data.ui_test_results_md = _read_text(repo_root / artifacts["ui_test_results"])
    data.implementation_summary_md = _read_text(repo_root / artifacts["implementation_summary"])
    data.qa_md = _read_text(repo_root / artifacts["qa"])
    data.review_md = _read_text(repo_root / artifacts["review"])
    data.audit_md = _read_text(repo_root / artifacts["audit"])

    data.frontend_present = parse_frontend_present(data.plan_md)

    # Verdict resolution priority:
    #  closure-verdict.md > qa.md > "IN-PROGRESS"
    closure_data = parse_closure_verdict(data.closure_verdict_md)
    if closure_data and closure_data["verdict"] in ("CLOSURE-PASS", "CLOSURE-FAIL"):
        data.verdict = "PASS" if closure_data["verdict"] == "CLOSURE-PASS" else "FAIL"
        data.verdict_source = "closure-verdict.md"
    elif data.qa_md:
        if re.search(r"\*\*Verdict:\*\*\s*PASS\b", data.qa_md):
            data.verdict = "PASS"
            data.verdict_source = "qa.md"
        elif re.search(r"\*\*Verdict:\*\*\s*FAIL\b", data.qa_md):
            data.verdict = "FAIL"
            data.verdict_source = "qa.md"
    # else IN-PROGRESS

    # One-line goal from plan
    data.one_line_goal = parse_one_line_goal(data.plan_md) or phase_id

    # Date: prefer summary.json finalized_at; else file mtime of closure verdict; else today
    sj_path = repo_root / artifacts["summary_json"]
    finalized_at = None
    if sj_path.exists():
        try:
            sj = json.loads(sj_path.read_text())
            finalized_at = sj.get("finalized_at")
        except Exception:
            finalized_at = None
    if finalized_at:
        data.date_str = finalized_at[:10]
    else:
        for cand in (
            repo_root / artifacts["closure_verdict"],
            repo_root / artifacts["qa"],
            repo_root / artifacts["plan"],
        ):
            if cand.exists():
                data.date_str = _dt.datetime.fromtimestamp(cand.stat().st_mtime).strftime("%Y-%m-%d")
                break
        else:
            data.date_str = _dt.date.today().isoformat()

    # Journeys (only for goal iterations)
    if data.is_goal_iter and data.session_id:
        jh_path = repo_root / "runs" / f"goal-session-{data.session_id}" / "state" / "journey-history.json"
        if jh_path.exists():
            try:
                data.journeys = parse_journey_history(json.loads(jh_path.read_text()))
            except Exception:
                data.journeys = []

    # Screenshot paths
    test_results = parse_ui_test_results(data.ui_test_results_md)
    if test_results:
        for p in test_results["evidence_paths"]:
            full = repo_root / p
            if full.exists() and full.is_file():
                data.screenshots.append(full)

    return data


def load_session(session_id: str, repo_root: Path) -> SessionData:
    s = SessionData(session_id=session_id, repo_root=repo_root)
    session_dir = repo_root / "runs" / f"goal-session-{session_id}"
    session_json_path = session_dir / "session.json"
    if session_json_path.exists():
        try:
            sj = json.loads(session_json_path.read_text())
            s.final_verdict = sj.get("status", "IN-PROGRESS")
            s.total_iterations = int(sj.get("total_iterations") or 0)
            s.wall_time_seconds = int(sj.get("wall_time_seconds") or 0)
            s.started_at = sj.get("started_at", "")
            s.finished_at = sj.get("finished_at", "")
        except Exception:
            pass

    s.goal_title = parse_goal_title(_read_text(repo_root / "docs" / "goal.md"))

    jh_path = session_dir / "state" / "journey-history.json"
    if jh_path.exists():
        try:
            s.journeys = parse_journey_history(json.loads(jh_path.read_text()))
        except Exception:
            s.journeys = []

    # Discover all iter dirs from runs/<phase>/ where phase matches the goal-iter pattern
    if repo_root.joinpath("runs").is_dir():
        for sub in sorted(repo_root.joinpath("runs").iterdir()):
            if not sub.is_dir():
                continue
            m = GOAL_ITER_RE.match(sub.name)
            if not m or m.group("sid") != session_id:
                continue
            s.iterations.append(load_iteration(sub.name, repo_root))
    s.iterations.sort(key=lambda d: (d.iter_num if d.iter_num is not None else 0))

    if not s.total_iterations:
        s.total_iterations = len(s.iterations)

    # Latest evaluator-log note (last entry, trimmed)
    log_path = session_dir / "state" / "evaluator-log.md"
    log_md = _read_text(log_path)
    if log_md:
        # Take the last `## Iteration ...` block and trim it.
        parts = re.split(r"^##\s+Iteration\b", log_md, flags=re.MULTILINE)
        if len(parts) > 1:
            last = "## Iteration" + parts[-1]
            s.latest_evaluator_note = last.strip()

    return s


# ─────────────────────────────────────────────────────────────────────────────
# Screenshot embedding
# ─────────────────────────────────────────────────────────────────────────────


_PIL_AVAILABLE: Optional[bool] = None


def _have_pillow() -> bool:
    global _PIL_AVAILABLE
    if _PIL_AVAILABLE is None:
        try:
            from PIL import Image  # noqa: F401

            _PIL_AVAILABLE = True
        except Exception:
            _PIL_AVAILABLE = False
    return _PIL_AVAILABLE


def embed_image(path: Path, *, max_bytes_unresized: int = 500_000, target_width: int = 1200) -> str:
    """Return a `data:image/png;base64,...` URL for the file.

    Files above `max_bytes_unresized` are resized to `target_width` if Pillow
    is available. Without Pillow, the file is embedded as-is (with a stderr
    warning so the operator notices large outputs).
    """
    try:
        raw = path.read_bytes()
    except OSError as e:
        print(f"[render-summary] WARN: could not read {path}: {e}", file=sys.stderr)
        return ""
    mime = "image/png"
    suffix = path.suffix.lower()
    if suffix in (".jpg", ".jpeg"):
        mime = "image/jpeg"
    elif suffix == ".gif":
        mime = "image/gif"
    elif suffix == ".webp":
        mime = "image/webp"
    if len(raw) > max_bytes_unresized:
        if _have_pillow() and mime in ("image/png", "image/jpeg"):
            try:
                import io as _io

                from PIL import Image as _Image

                img = _Image.open(_io.BytesIO(raw))
                if img.width > target_width:
                    ratio = target_width / img.width
                    new_h = int(img.height * ratio)
                    img = img.resize((target_width, new_h), _Image.LANCZOS)
                    buf = _io.BytesIO()
                    save_fmt = "PNG" if mime == "image/png" else "JPEG"
                    save_kwargs = {"optimize": True} if save_fmt == "PNG" else {"quality": 85, "optimize": True}
                    img.save(buf, save_fmt, **save_kwargs)
                    raw = buf.getvalue()
            except Exception as e:  # noqa: BLE001
                print(f"[render-summary] WARN: resize failed for {path.name}: {e}", file=sys.stderr)
        else:
            print(
                f"[render-summary] WARN: {path.name} is {len(raw)//1024} KB (Pillow not installed; embedding as-is)",
                file=sys.stderr,
            )
    b64 = base64.b64encode(raw).decode("ascii")
    return f"data:{mime};base64,{b64}"


# ─────────────────────────────────────────────────────────────────────────────
# Inline assets (CSS + SVG)
# ─────────────────────────────────────────────────────────────────────────────

CSS = """
*, *::before, *::after { box-sizing: border-box; }
body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  margin: 0; padding: 0; color: #1f2328; background: #f6f8fa; line-height: 1.5;
}
.container { max-width: 880px; margin: 0 auto; padding: 24px 16px 80px; }
.hero {
  background: white; border: 1px solid #d0d7de; border-radius: 8px;
  padding: 28px; margin-bottom: 16px; text-align: center;
}
.hero.pass { border-top: 6px solid #1a7f37; }
.hero.fail { border-top: 6px solid #cf222e; }
.hero.inprogress { border-top: 6px solid #d4a72c; }
.hero h1 { margin: 0 0 6px 0; font-size: 1.6rem; }
.hero h2 { margin: 0 0 14px 0; font-size: 1rem; color: #57606a; font-weight: 500; }
.badge {
  display: inline-flex; align-items: center; gap: 8px;
  padding: 6px 14px; border-radius: 999px; font-weight: 600; font-size: 0.95rem;
}
.badge.pass { background: #dafbe1; color: #1a7f37; }
.badge.fail { background: #ffebe9; color: #cf222e; }
.badge.inprogress { background: #fff8c5; color: #9a6700; }
.meta { color: #57606a; font-size: 0.875rem; margin: 10px 0 16px; }
.journey-row {
  display: flex; flex-wrap: wrap; gap: 8px; justify-content: center; margin: 12px 0 4px;
}
.journey-pill {
  display: inline-flex; align-items: center; gap: 6px;
  padding: 4px 10px; border-radius: 999px; font-size: 0.85rem;
  background: #f6f8fa; border: 1px solid #d0d7de;
}
.journey-pill.passing { background: #dafbe1; color: #1a7f37; border-color: #b4e2c0; }
.journey-pill.already_passing { background: #dafbe1; color: #1a7f37; border-color: #b4e2c0; }
.journey-pill.failing { background: #ffebe9; color: #cf222e; border-color: #f1aeb0; }
.journey-pill.regressed { background: #ffebe9; color: #cf222e; border-color: #f1aeb0; }
.journey-pill.partial { background: #fff8c5; color: #9a6700; border-color: #eed888; }
.journey-pill.unknown { background: #f6f8fa; color: #57606a; }
.hero-image { margin-top: 18px; }
.hero-image img { max-width: 100%; height: auto; border-radius: 6px; border: 1px solid #d0d7de; }
details {
  background: white; border: 1px solid #d0d7de; border-radius: 8px;
  margin-bottom: 12px; padding: 0;
}
details > summary {
  cursor: pointer; padding: 14px 18px; font-weight: 600; font-size: 1.05rem;
  list-style: none; user-select: none; display: flex; align-items: center; gap: 8px;
}
details > summary::-webkit-details-marker { display: none; }
details > summary::before {
  content: '▶'; transition: transform 0.15s; font-size: 0.75rem; color: #57606a;
}
details[open] > summary::before { transform: rotate(90deg); }
.accordion-body { padding: 0 18px 18px; }
.accordion-body h3 { font-size: 0.95rem; color: #57606a; margin: 16px 0 6px; }
ul.bullets { margin: 6px 0 14px; padding-left: 22px; }
ul.bullets li { margin-bottom: 4px; }
ol.steps { padding-left: 0; list-style: none; counter-reset: step; }
ol.steps > li {
  counter-increment: step; padding: 12px 0 12px 44px;
  border-top: 1px solid #eaeef2; position: relative;
}
ol.steps > li:first-child { border-top: none; }
ol.steps > li::before {
  content: counter(step); position: absolute; left: 0; top: 14px;
  width: 30px; height: 30px; border-radius: 50%;
  background: #0969da; color: white; display: flex;
  align-items: center; justify-content: center; font-size: 0.85rem; font-weight: 600;
}
.step-action { font-weight: 500; }
.step-expect { color: #57606a; font-size: 0.9rem; margin-top: 4px; }
.step-expect::before { content: '↳ '; }
.step-shot { margin-top: 10px; }
.step-shot img { max-width: 100%; height: auto; border-radius: 6px; border: 1px solid #d0d7de; }
.checkbox { margin-right: 8px; }
.gallery {
  display: grid; grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
  gap: 8px; margin-top: 14px;
}
.gallery img { width: 100%; height: auto; border-radius: 6px; border: 1px solid #d0d7de; }
.missing-list li { padding: 6px 0; border-bottom: 1px solid #eaeef2; }
.missing-list li:last-child { border-bottom: none; }
.drill-table {
  width: 100%; border-collapse: collapse; font-size: 0.92rem;
}
.drill-table th, .drill-table td {
  text-align: left; padding: 8px 6px; border-bottom: 1px solid #eaeef2;
}
.drill-table th { background: #f6f8fa; }
.verdict-cell.PASS, .verdict-cell.CLOSURE-PASS { color: #1a7f37; font-weight: 600; }
.verdict-cell.FAIL, .verdict-cell.CLOSURE-FAIL { color: #cf222e; font-weight: 600; }
.verdict-cell.SKIPPED, .verdict-cell.UNKNOWN { color: #57606a; }
.footer-note {
  text-align: center; color: #6e7781; font-size: 0.8rem; margin-top: 24px;
}
.iter-card {
  background: white; border: 1px solid #d0d7de; border-radius: 8px;
  padding: 16px 18px; margin-bottom: 12px; display: flex; align-items: center; gap: 14px;
}
.iter-card .left { flex-shrink: 0; }
.iter-card .body { flex: 1 1 auto; }
.iter-card .body .title { font-weight: 600; }
.iter-card .body .sub { color: #57606a; font-size: 0.88rem; margin-top: 2px; }
.iter-card a.open { color: #0969da; text-decoration: none; font-weight: 500; }
.iter-card a.open:hover { text-decoration: underline; }
.matrix { width: 100%; border-collapse: collapse; margin: 12px 0 22px; font-size: 0.88rem; }
.matrix th, .matrix td { padding: 6px 8px; border: 1px solid #d0d7de; text-align: center; }
.matrix th:first-child, .matrix td:first-child { text-align: left; }
.matrix .cell-passing, .matrix .cell-already_passing { background: #dafbe1; color: #1a7f37; }
.matrix .cell-failing, .matrix .cell-regressed { background: #ffebe9; color: #cf222e; }
.matrix .cell-partial { background: #fff8c5; color: #9a6700; }
.matrix .cell-unknown { background: #f6f8fa; color: #57606a; }
"""

SVG_CHECK = """<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true">
<circle cx="12" cy="12" r="11" fill="#1a7f37"/>
<path d="M7 12.5l3 3 7-7" stroke="white" stroke-width="2.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/>
</svg>"""

SVG_X = """<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true">
<circle cx="12" cy="12" r="11" fill="#cf222e"/>
<path d="M8 8l8 8M16 8l-8 8" stroke="white" stroke-width="2.5" fill="none" stroke-linecap="round"/>
</svg>"""

SVG_CLOCK = """<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true">
<circle cx="12" cy="12" r="11" fill="#d4a72c"/>
<path d="M12 6v6l4 2.5" stroke="white" stroke-width="2.5" fill="none" stroke-linecap="round"/>
</svg>"""


def _verdict_class(verdict: str) -> str:
    if verdict == "PASS" or verdict == "GOAL_ACHIEVED" or verdict == "CLOSURE-PASS":
        return "pass"
    if verdict in ("FAIL", "REGRESSION_HALT", "CLOSURE-FAIL"):
        return "fail"
    return "inprogress"


def _verdict_icon(verdict: str) -> str:
    cls = _verdict_class(verdict)
    if cls == "pass":
        return SVG_CHECK
    if cls == "fail":
        return SVG_X
    return SVG_CLOCK


# ─────────────────────────────────────────────────────────────────────────────
# HTML generation — iteration page
# ─────────────────────────────────────────────────────────────────────────────


def render_html_iteration(data: IterationData) -> str:
    parts: list[str] = []
    parts.append("<!doctype html>")
    parts.append('<html lang="en"><head>')
    parts.append('<meta charset="utf-8">')
    parts.append(f"<title>{escape(data.phase_id)} — Iteration Summary</title>")
    parts.append(f"<style>{CSS}</style>")
    parts.append("</head><body><div class='container'>")
    parts.append(_render_hero(data))
    parts.append(_render_accordion_what_users_can_do(data))
    parts.append(_render_accordion_try_it(data))
    parts.append(_render_accordion_still_missing(data))
    parts.append(_render_accordion_drill_down(data))
    parts.append(_render_footer())
    parts.append("</div></body></html>")
    return "\n".join(parts)


def _render_hero(data: IterationData) -> str:
    cls = _verdict_class(data.verdict)
    icon = _verdict_icon(data.verdict)
    title_label = data.phase_id
    if data.is_goal_iter and data.iter_num is not None:
        title_label = f"Iteration {data.iter_num}  ·  session {data.session_id}"
    journey_pills = ""
    if data.journeys:
        pills = []
        for j in data.journeys:
            status = j["status"]
            cls_j = re.sub(r"[^a-z_]", "", status.lower()) or "unknown"
            pills.append(
                f"<span class='journey-pill {cls_j}' title='{escape(j['name'])}'>"
                f"{escape(j['id'])} · {escape(status)}</span>"
            )
        journey_pills = f"<div class='journey-row'>{''.join(pills)}</div>"
    pass_count = sum(1 for j in data.journeys if j["status"] in ("passing", "already_passing"))
    journey_summary = ""
    if data.journeys:
        journey_summary = f"<div class='meta'>Journeys: {pass_count}/{len(data.journeys)} passing</div>"
    hero_img = ""
    chosen = _pick_hero_screenshot(data)
    if chosen is not None:
        data_url = embed_image(chosen)
        if data_url:
            hero_img = f"<div class='hero-image'><img src='{data_url}' alt='Hero screenshot'></div>"

    return (
        f"<section class='hero {cls}'>"
        f"<div class='badge {cls}'>{icon}<span>{escape(data.verdict)}</span></div>"
        f"<h1>{escape(title_label)}</h1>"
        f"<h2>{escape(data.one_line_goal)}</h2>"
        f"<div class='meta'>{escape(data.date_str)}"
        f"{' · backend-only' if data.frontend_present is False else ''}</div>"
        f"{journey_summary}"
        f"{journey_pills}"
        f"{hero_img}"
        f"</section>"
    )


def _pick_hero_screenshot(data: IterationData) -> Optional[Path]:
    if not data.screenshots:
        return None
    # Prefer the first PASS-labelled evidence path if we can infer it.
    test_results = parse_ui_test_results(data.ui_test_results_md)
    if test_results:
        # The first evidence path in the file is from the results table which
        # lists rows in order — typically UT-01 is the smoke test. The first
        # passing test is usually first. Use the first available screenshot.
        for s in data.screenshots:
            return s
    return data.screenshots[0]


def _render_accordion_what_users_can_do(data: IterationData) -> str:
    sections = parse_user_visible_changes(data.user_visible_changes_md)
    fallback_label = "What was built"
    used_fallback = False
    if not sections and data.frontend_present is False:
        impl = parse_implementation_summary(data.implementation_summary_md)
        if impl:
            sections = {fallback_label: impl.get("Features Implemented", [])}
            sections = {k: v for k, v in sections.items() if v}
            used_fallback = True
    if not sections:
        return ""
    body_parts: list[str] = []
    for title, bullets in sections.items():
        if title == "Not Visible Yet":
            continue  # Surface this in Accordion 3 instead.
        body_parts.append(f"<h3>{escape(title)}</h3>")
        body_parts.append("<ul class='bullets'>")
        for b in bullets:
            body_parts.append(f"<li>{escape(b)}</li>")
        body_parts.append("</ul>")
    if not body_parts:
        return ""
    summary_label = (
        f"What users can do" if not used_fallback else f"{fallback_label} (backend-only phase)"
    )
    return (
        "<details open><summary>"
        f"{summary_label}</summary>"
        f"<div class='accordion-body'>{''.join(body_parts)}</div>"
        "</details>"
    )


def _render_accordion_try_it(data: IterationData) -> str:
    parsed = parse_what_to_click(data.what_to_click_md)
    if not parsed:
        return ""
    body: list[str] = []
    if parsed["prerequisites"]:
        body.append("<h3>Prerequisites</h3><ul class='bullets'>")
        for p in parsed["prerequisites"]:
            body.append(f"<li>{escape(p)}</li>")
        body.append("</ul>")
    # Steps with paired screenshots (in order).
    body.append("<ol class='steps'>")
    screenshots = list(data.screenshots)
    for idx, step in enumerate(parsed["steps"]):
        action_html = escape(step["action"])
        expect_html = (
            f"<div class='step-expect'>{escape(step['expect'])}</div>" if step.get("expect") else ""
        )
        shot_html = ""
        if idx < len(screenshots):
            data_url = embed_image(screenshots[idx])
            if data_url:
                shot_html = (
                    f"<div class='step-shot'><img src='{data_url}' alt='Step {idx+1}'></div>"
                )
        body.append(
            "<li>"
            "<input type='checkbox' class='checkbox' aria-label='step done'>"
            f"<span class='step-action'>{action_html}</span>"
            f"{expect_html}{shot_html}"
            "</li>"
        )
    body.append("</ol>")
    # Extra screenshots beyond steps → thumbnail gallery
    if len(screenshots) > len(parsed["steps"]):
        extras = screenshots[len(parsed["steps"]):]
        body.append("<h3>More screenshots</h3><div class='gallery'>")
        for s in extras:
            data_url = embed_image(s)
            if data_url:
                body.append(f"<img src='{data_url}' alt='{escape(s.name)}'>")
        body.append("</div>")
    if parsed.get("working_indicators"):
        body.append("<h3>What \"Working\" looks like</h3><ul class='bullets'>")
        for w in parsed["working_indicators"]:
            body.append(f"<li>{escape(w)}</li>")
        body.append("</ul>")
    if parsed.get("common_issues"):
        body.append("<h3>Common issues</h3><ul class='bullets'>")
        for c in parsed["common_issues"]:
            body.append(f"<li>{escape(c)}</li>")
        body.append("</ul>")
    return (
        f"<details open><summary>Try it yourself (5 min)</summary>"
        f"<div class='accordion-body'>{''.join(body)}</div></details>"
    )


def _render_accordion_still_missing(data: IterationData) -> str:
    items: list[str] = []
    uvc = parse_user_visible_changes(data.user_visible_changes_md) or {}
    for b in uvc.get("Not Visible Yet", []):
        items.append(b)
    closure = parse_closure_verdict(data.closure_verdict_md) or {}
    for b in closure.get("blocking_issues", []):
        items.append(b)
    test_results = parse_ui_test_results(data.ui_test_results_md) or {}
    for f in test_results.get("failed_tests", []):
        items.append(f"{f['id']} — {f['name']}: failed")
    for s in test_results.get("skipped_tests", []):
        items.append(f"{s['id']} — {s['name']}: skipped")
    if not items:
        return ""
    body = "<ul class='bullets missing-list'>"
    for it in items:
        body += f"<li>{escape(it)}</li>"
    body += "</ul>"
    return (
        f"<details><summary>Still missing</summary>"
        f"<div class='accordion-body'>{body}</div></details>"
    )


def _render_accordion_drill_down(data: IterationData) -> str:
    rows: list[tuple[str, str, str]] = []  # (label, relative-path, verdict)
    def _vfile(md: Optional[str]) -> str:
        if not md:
            return "—"
        m = re.search(r"\*\*(?:Executive )?Verdict:\*\*\s*([A-Z][A-Z\-_]*)", md)
        if m:
            return m.group(1)
        m = re.search(r"\*\*Browser QA Verdict:\*\*\s*([A-Z]+)", md)
        if m:
            return m.group(1)
        return "—"
    candidates = [
        ("Plan", data.artifact_paths["plan"], data.plan_md, "—"),
        ("Implementation summary", data.artifact_paths["implementation_summary"], data.implementation_summary_md, "—"),
        ("User-visible changes", data.artifact_paths["user_visible_changes"], data.user_visible_changes_md, "—"),
        ("UI surface map", data.artifact_paths["ui_surface_map"], None, "—"),
        ("UI test plan", data.artifact_paths["ui_test_plan"], None, "—"),
        ("UI test results", data.artifact_paths["ui_test_results"], data.ui_test_results_md, None),
        ("What to click", data.artifact_paths["what_to_click"], data.what_to_click_md, "—"),
        ("UX regression", data.artifact_paths["ux_regression"], None, None),
        ("Review", data.artifact_paths["review"], data.review_md, None),
        ("QA", data.artifact_paths["qa"], data.qa_md, None),
        ("Audit", data.artifact_paths["audit"], data.audit_md, None),
        ("Closure verdict", data.artifact_paths["closure_verdict"], data.closure_verdict_md, None),
    ]
    for label, rel, body, fixed_verdict in candidates:
        full = data.repo_root / rel
        if not full.exists():
            continue
        if fixed_verdict is None:
            extra_md = body if body is not None else _read_text(full)
            verdict = _vfile(extra_md)
        else:
            verdict = fixed_verdict
        # Relative href from the location of summary.html (`runs/<phase>/`)
        href = os.path.relpath(rel, start=f"runs/{data.phase_id}")
        rows.append((label, href, verdict))
    if not rows:
        return ""
    body_parts: list[str] = []
    body_parts.append("<table class='drill-table'><thead><tr>")
    body_parts.append("<th>Report</th><th>Verdict</th><th>File</th></tr></thead><tbody>")
    for label, href, verdict in rows:
        v_cls = escape(verdict)
        body_parts.append(
            f"<tr><td>{escape(label)}</td>"
            f"<td><span class='verdict-cell {v_cls}'>{escape(verdict)}</span></td>"
            f"<td><a href='{escape(href)}'>{escape(href)}</a></td></tr>"
        )
    body_parts.append("</tbody></table>")
    return (
        f"<details><summary>Agent reports</summary>"
        f"<div class='accordion-body'>{''.join(body_parts)}</div></details>"
    )


def _render_footer() -> str:
    now = _dt.datetime.now().strftime("%Y-%m-%d %H:%M")
    return (
        f"<div class='footer-note'>Generated {escape(now)} by "
        f"<code>render_iteration_summary.py</code></div>"
    )


# ─────────────────────────────────────────────────────────────────────────────
# HTML generation — session index page
# ─────────────────────────────────────────────────────────────────────────────


def render_html_session_index(data: SessionData) -> str:
    parts: list[str] = []
    parts.append("<!doctype html>")
    parts.append('<html lang="en"><head>')
    parts.append('<meta charset="utf-8">')
    parts.append(f"<title>Goal session {escape(data.session_id)}</title>")
    parts.append(f"<style>{CSS}</style>")
    parts.append("</head><body><div class='container'>")
    parts.append(_render_session_hero(data))
    parts.append(_render_journey_matrix(data))
    parts.append(_render_iter_cards(data))
    parts.append(_render_evaluator_note(data))
    parts.append(_render_footer())
    parts.append("</div></body></html>")
    return "\n".join(parts)


def _render_session_hero(data: SessionData) -> str:
    cls = _verdict_class(data.final_verdict)
    icon = _verdict_icon(data.final_verdict)
    pass_count = sum(1 for j in data.journeys if j["status"] in ("passing", "already_passing"))
    minutes = data.wall_time_seconds // 60
    return (
        f"<section class='hero {cls}'>"
        f"<div class='badge {cls}'>{icon}<span>{escape(data.final_verdict)}</span></div>"
        f"<h1>{escape(data.goal_title or 'Goal session ' + data.session_id)}</h1>"
        f"<h2>Session <code>{escape(data.session_id)}</code></h2>"
        f"<div class='meta'>{data.total_iterations} iterations · "
        f"{pass_count}/{len(data.journeys)} journeys passing · "
        f"{minutes} min wall time</div>"
        f"</section>"
    )


def _render_journey_matrix(data: SessionData) -> str:
    if not data.journeys or not data.iterations:
        return ""
    # We don't have per-iter journey snapshots in journey-history.json; that file
    # is the *latest* state only. So the matrix shows the current status per
    # journey + a column for each iteration tagged with that iter's verdict.
    head = "<tr><th>Journey</th>"
    for it in data.iterations:
        label = f"iter-{it.iter_num}" if it.iter_num is not None else it.phase_id
        head += f"<th title='{escape(it.verdict)}'>{escape(label)}</th>"
    head += "<th>Latest</th></tr>"
    rows: list[str] = []
    for j in data.journeys:
        status = j["status"]
        row = f"<tr><td title='{escape(j['name'])}'>{escape(j['id'])}</td>"
        for it in data.iterations:
            last_iter = j.get("last_passing_iter") or ""
            if last_iter and (last_iter == it.phase_id or last_iter.endswith(f"iter-{it.iter_num}")):
                row += "<td class='cell-passing'>✓</td>"
            elif j.get("last_verified_iter") == it.phase_id:
                cls = re.sub(r"[^a-z_]", "", status.lower()) or "unknown"
                glyph = {"passing": "✓", "already_passing": "✓", "failing": "✗",
                         "regressed": "↓", "partial": "~", "unknown": "?"}.get(status, "·")
                row += f"<td class='cell-{cls}'>{glyph}</td>"
            else:
                row += "<td class='cell-unknown'>·</td>"
        cls = re.sub(r"[^a-z_]", "", status.lower()) or "unknown"
        row += f"<td class='cell-{cls}'>{escape(status)}</td></tr>"
        rows.append(row)
    return (
        "<h2 style='font-size:1rem;color:#57606a;margin:14px 0 6px'>Journey progress</h2>"
        f"<table class='matrix'><thead>{head}</thead><tbody>{''.join(rows)}</tbody></table>"
    )


def _render_iter_cards(data: SessionData) -> str:
    if not data.iterations:
        return "<p style='color:#57606a'>No iterations recorded yet.</p>"
    cards: list[str] = []
    for it in data.iterations:
        cls = _verdict_class(it.verdict)
        icon = _verdict_icon(it.verdict)
        href = f"../{it.phase_id}/summary.html"
        label = f"Iteration {it.iter_num}" if it.iter_num is not None else it.phase_id
        cards.append(
            "<div class='iter-card'>"
            f"<div class='left'><div class='badge {cls}'>{icon}<span>{escape(it.verdict)}</span></div></div>"
            "<div class='body'>"
            f"<div class='title'>{escape(label)} — {escape(it.one_line_goal)}</div>"
            f"<div class='sub'>{escape(it.date_str)} · <code>{escape(it.phase_id)}</code></div>"
            "</div>"
            f"<a class='open' href='{escape(href)}'>Open summary →</a>"
            "</div>"
        )
    return "<h2 style='font-size:1rem;color:#57606a;margin:14px 0 6px'>Iterations</h2>" + "".join(cards)


def _render_evaluator_note(data: SessionData) -> str:
    if not data.latest_evaluator_note:
        return ""
    snippet = data.latest_evaluator_note
    # Trim to ~1500 chars for inline display
    if len(snippet) > 1500:
        snippet = snippet[:1500] + "…"
    safe = escape(snippet).replace("\n", "<br>")
    return (
        "<details><summary>Latest evaluator note</summary>"
        f"<div class='accordion-body'><pre style='white-space:pre-wrap;font-size:0.85rem;color:#3b4252'>"
        f"{safe}</pre></div></details>"
    )


# ─────────────────────────────────────────────────────────────────────────────
# Output paths
# ─────────────────────────────────────────────────────────────────────────────


def iteration_output_path(phase_id: str, repo_root: Path) -> Path:
    return repo_root / "runs" / phase_id / "summary.html"


def session_index_output_path(session_id: str, repo_root: Path) -> Path:
    return repo_root / "runs" / f"goal-session-{session_id}" / "index.html"


# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────


def cmd_iteration(args: list[str]) -> int:
    if not args:
        print("Usage: render_iteration_summary.py iteration <phase-id>", file=sys.stderr)
        return 2
    phase_id = args[0]
    repo_root = _resolve_repo_root(args[1:])
    data = load_iteration(phase_id, repo_root)
    html = render_html_iteration(data)
    out = iteration_output_path(phase_id, repo_root)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(html, encoding="utf-8")
    size_kb = out.stat().st_size // 1024
    print(f"[render-summary] Wrote {out} ({size_kb} KB)")
    return 0


def cmd_session_index(args: list[str]) -> int:
    if not args:
        print("Usage: render_iteration_summary.py session-index <session-id>", file=sys.stderr)
        return 2
    session_id = args[0]
    repo_root = _resolve_repo_root(args[1:])
    data = load_session(session_id, repo_root)
    html = render_html_session_index(data)
    out = session_index_output_path(session_id, repo_root)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(html, encoding="utf-8")
    size_kb = out.stat().st_size // 1024
    print(f"[render-summary] Wrote {out} ({size_kb} KB)")
    return 0


def _resolve_repo_root(extra: list[str]) -> Path:
    for arg in extra:
        if arg.startswith("--repo-root="):
            return Path(arg.split("=", 1)[1]).resolve()
    return REPO_ROOT


# ─────────────────────────────────────────────────────────────────────────────
# Self-test
# ─────────────────────────────────────────────────────────────────────────────

_FIXTURE_PLAN = """# Phase fixture-1 plan

Frontend Present: yes

## Goal
Add a user profile page where users can edit their bio.
"""

_FIXTURE_USER_VISIBLE = """# Phase 1 — User-Visible Changes

**Phase:** fixture-1

## What Users Can Now Do

- Users can now edit their bio on the profile page
- Users can now view a list of all profiles at /profiles

## What Changed in the Visible UI

- A new "My Profile" link appeared in the header menu
- The user dropdown now shows the current bio

## What Old Behavior Changed

- Login: now redirects to /profile/me instead of /dashboard

## Not Visible Yet

- Account deletion exists in the backend API but no UI route yet
"""

_FIXTURE_WHAT_TO_CLICK = """# Phase 1 — What to Click

## Prerequisites

- Frontend running at http://localhost:3000
- Logged in as a test user

## Verification Steps

1. Open http://localhost:3000 in your browser
   - **Expect:** Dashboard loads with no error

2. Click "My Profile" in the header menu
   - **Expect:** /profile/me opens, your bio is visible

3. Click "Edit bio", type "Hello world", click "Save"
   - **Expect:** Green toast "Saved" appears, bio updates

## What "Working Correctly" Looks Like

- Toast confirmation
- Bio persists on page reload

## Common Issues

- Blank page: check backend is running
"""

_FIXTURE_UI_TEST_RESULTS = """# Phase 1 — UI Test Results

**Browser QA Verdict:** PASS

**Overall:** 3/3 tests passed

## Results Table

| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |
|---------|------|------|----------|----------|--------|---------|----------|
| UT-01 | Dashboard loads | smoke | P1 | Loads | Loaded | PASS | reports/qa/fixture-1-evidence/UT-01-dash.png |
| UT-02 | Profile shows bio | happy-path | P1 | Visible | Visible | PASS | reports/qa/fixture-1-evidence/UT-02-bio.png |
| UT-03 | Bio edit saves | happy-path | P1 | Saved | Saved | PASS | reports/qa/fixture-1-evidence/UT-03-save.png |

## Passed Tests

### UT-01 — Dashboard loads
**Verdict:** PASS
**Evidence:** `reports/qa/fixture-1-evidence/UT-01-dash.png`
"""

_FIXTURE_CLOSURE = """# Phase 1 — Closure Verdict

**Verdict:** CLOSURE-PASS

## Standard Pipeline Gate Checks

| Artifact | Status | Verdict |
|----------|--------|---------|
| Review report | exists | PASS |
| QA report | exists | PASS |

## Blocking Issues

None.
"""

_FIXTURE_QA = """# QA Report

## Verdict

**Verdict:** PASS

## Test Results
All tests passed.
"""


# 1x1 transparent PNG bytes for fixture screenshots
_FIXTURE_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
)


def _write_fixture(tmp: Path, phase_id: str = "fixture-1", *, with_screenshots: bool = True,
                   with_what_to_click: bool = True, with_user_visible: bool = True) -> None:
    (tmp / "runs" / phase_id).mkdir(parents=True, exist_ok=True)
    (tmp / "runs" / phase_id / "plan.md").write_text(_FIXTURE_PLAN)
    (tmp / "reports").mkdir(parents=True, exist_ok=True)
    if with_user_visible:
        (tmp / "reports" / f"phase-{phase_id}-user-visible-changes.md").write_text(_FIXTURE_USER_VISIBLE)
    if with_what_to_click:
        (tmp / "reports" / f"phase-{phase_id}-what-to-click.md").write_text(_FIXTURE_WHAT_TO_CLICK)
    (tmp / "reports" / f"phase-{phase_id}-ui-test-results.md").write_text(_FIXTURE_UI_TEST_RESULTS)
    (tmp / "reports" / f"phase-{phase_id}-closure-verdict.md").write_text(_FIXTURE_CLOSURE)
    (tmp / "reports" / "qa").mkdir(parents=True, exist_ok=True)
    (tmp / "reports" / "qa" / f"{phase_id}-qa.md").write_text(_FIXTURE_QA)
    if with_screenshots:
        ev = tmp / "reports" / "qa" / f"{phase_id}-evidence"
        ev.mkdir(parents=True, exist_ok=True)
        for name in ("UT-01-dash.png", "UT-02-bio.png", "UT-03-save.png"):
            (ev / name).write_bytes(_FIXTURE_PNG)


def _cmd_self_test(_argv: list[str]) -> int:
    """Built-in fixture roundtrip covering the design's behavioural expectations.

    Runs:
      1. parse_what_to_click yields 3 steps with expects
      2. parse_user_visible_changes finds 4 sections
      3. parse_closure_verdict reads CLOSURE-PASS
      4. parse_ui_test_results returns evidence paths in order
      5. Full iteration render: contains hero, 3 step list items, 3 base64 imgs
      6. Backend-only fallback: no what-to-click → no Accordion 2; uses
         implementation-summary
      7. Missing screenshots: hero falls back to text-only banner
      8. Session index: 2 iterations render as 2 cards
      9. Output is self-contained: no http:// references with src/href to remote
    """
    import tempfile

    failures: list[str] = []

    # Parser tests (independent of disk)
    wtc = parse_what_to_click(_FIXTURE_WHAT_TO_CLICK)
    if not wtc or len(wtc["steps"]) != 3:
        failures.append(f"parse_what_to_click: expected 3 steps, got {wtc and len(wtc['steps'])}")
    elif wtc["steps"][1]["expect"] is None:
        failures.append("parse_what_to_click: step 2 should have an expect line")

    uvc = parse_user_visible_changes(_FIXTURE_USER_VISIBLE)
    if not uvc or "What Users Can Now Do" not in uvc:
        failures.append(f"parse_user_visible_changes: missing 'What Users Can Now Do' (got {uvc})")
    elif len(uvc["What Users Can Now Do"]) != 2:
        failures.append(
            f"parse_user_visible_changes: expected 2 bullets, got {len(uvc['What Users Can Now Do'])}"
        )

    cv = parse_closure_verdict(_FIXTURE_CLOSURE)
    if not cv or cv["verdict"] != "CLOSURE-PASS":
        failures.append(f"parse_closure_verdict: expected CLOSURE-PASS, got {cv}")

    ut = parse_ui_test_results(_FIXTURE_UI_TEST_RESULTS)
    if not ut or len(ut["evidence_paths"]) != 3:
        failures.append(
            f"parse_ui_test_results: expected 3 evidence paths, got {ut and len(ut['evidence_paths'])}"
        )
    elif ut["evidence_paths"][0] != "reports/qa/fixture-1-evidence/UT-01-dash.png":
        failures.append(
            f"parse_ui_test_results: first evidence path wrong, got {ut['evidence_paths'][0]}"
        )

    with tempfile.TemporaryDirectory() as raw_tmp:
        tmp = Path(raw_tmp)
        # Case A: full fixture with screenshots
        _write_fixture(tmp, "fixture-1")
        data = load_iteration("fixture-1", tmp)
        if data.verdict != "PASS":
            failures.append(f"caseA: verdict expected PASS, got {data.verdict}")
        if len(data.screenshots) != 3:
            failures.append(f"caseA: expected 3 screenshots, got {len(data.screenshots)}")
        html = render_html_iteration(data)
        if "data:image/png;base64," not in html:
            failures.append("caseA: expected at least one embedded base64 image")
        if html.count("<li><input type='checkbox'") < 3:
            failures.append("caseA: expected 3 checkbox steps in Try-it accordion")
        if "Try it yourself" not in html:
            failures.append("caseA: expected 'Try it yourself' accordion label")
        if "Still missing" not in html:
            failures.append("caseA: expected 'Still missing' section (uvc says 'Not Visible Yet')")
        if 'src="http://' in html or 'src="https://' in html:
            failures.append("caseA: HTML contains remote image src — should be self-contained")
        # Write artifact for inspection
        out_path = iteration_output_path("fixture-1", tmp)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(html, encoding="utf-8")

        # Case B: backend-only — no what-to-click, no user-visible-changes,
        # but has implementation-summary as fallback
        _write_fixture(tmp, "fixture-2", with_what_to_click=False, with_user_visible=False)
        (tmp / "runs" / "fixture-2" / "plan.md").write_text("Frontend Present: no\n\n# Refactor data layer\n")
        impl = """# Implementation Summary

## Features Implemented

- New repository pattern for the data layer
- Connection pool now configurable via env
"""
        (tmp / "reports" / "phase-fixture-2-implementation-summary.md").write_text(impl)
        data_b = load_iteration("fixture-2", tmp)
        html_b = render_html_iteration(data_b)
        if "Try it yourself" in html_b:
            failures.append("caseB: Try-it accordion should be absent for backend-only phase")
        if "What was built" not in html_b:
            failures.append("caseB: fallback 'What was built' heading missing")
        if "backend-only" not in html_b:
            failures.append("caseB: hero should mark phase as backend-only")

        # Case C: no screenshots at all — hero should be text-only
        _write_fixture(tmp, "fixture-3", with_screenshots=False)
        # Also clear evidence paths from results to mimic SKIPPED
        (tmp / "reports" / "phase-fixture-3-ui-test-results.md").write_text(
            "# UI Test Results\n\n**Browser QA Verdict:** SKIPPED\n\n## Results Table\n\n| - | - |\n"
        )
        data_c = load_iteration("fixture-3", tmp)
        if data_c.screenshots:
            failures.append(f"caseC: expected no screenshots, got {len(data_c.screenshots)}")
        html_c = render_html_iteration(data_c)
        if "<div class='hero-image'>" in html_c:
            failures.append("caseC: hero should not render <div class='hero-image'> when no screenshots")
        if "data:image/png;base64," in html_c:
            failures.append("caseC: no base64 images should be embedded when there are no screenshots")

        # Case D: session index with 2 goal-mode iterations
        _write_fixture(tmp, "goal-demo-iter-0")
        _write_fixture(tmp, "goal-demo-iter-1")
        # Minimal session.json + journey-history
        session_dir = tmp / "runs" / "goal-session-demo"
        (session_dir / "state").mkdir(parents=True, exist_ok=True)
        (session_dir / "session.json").write_text(json.dumps({
            "status": "IN-PROGRESS", "total_iterations": 2, "wall_time_seconds": 600,
            "started_at": "2026-05-01T10:00:00Z", "finished_at": "",
        }))
        (session_dir / "state" / "journey-history.json").write_text(json.dumps({
            "journeys": {
                "J-01": {"id": "J-01", "name": "Sign up", "status": "passing",
                          "last_verified_iter": "goal-demo-iter-1",
                          "last_passing_iter": "goal-demo-iter-1"},
                "J-02": {"id": "J-02", "name": "Delete account", "status": "failing",
                          "last_verified_iter": "goal-demo-iter-1",
                          "last_passing_iter": None},
            }
        }))
        (tmp / "docs").mkdir(exist_ok=True)
        (tmp / "docs" / "goal.md").write_text("# Build a profile system\n")
        sess = load_session("demo", tmp)
        if len(sess.iterations) != 2:
            failures.append(f"caseD: expected 2 iterations, got {len(sess.iterations)}")
        idx_html = render_html_session_index(sess)
        if idx_html.count("class='iter-card'") != 2:
            failures.append("caseD: expected 2 iteration cards")
        if "J-01" not in idx_html or "J-02" not in idx_html:
            failures.append("caseD: journey matrix should include J-01 and J-02")
        if "Build a profile system" not in idx_html:
            failures.append("caseD: session hero should show goal title")

        # Case E: self-contained check across all rendered HTML
        for name, html_doc in (("A", html), ("B", html_b), ("C", html_c), ("session", idx_html)):
            # External CSS/JS refs would use src=/href= with http(s)
            bad = re.findall(r'(?:src|href)="(https?://[^"]+)"', html_doc)
            # Empty acceptable (no remote refs)
            if bad:
                failures.append(f"case{name}: remote refs present: {bad[:3]}")

    if failures:
        print("self-test FAILED:", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1
    print("self-test passed")
    return 0


_COMMANDS = {
    "iteration": cmd_iteration,
    "session-index": cmd_session_index,
    "self-test": _cmd_self_test,
    "--self-test": _cmd_self_test,
}


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in _COMMANDS:
        print(
            "Usage: render_iteration_summary.py <command> [args]\n"
            f"Commands: {', '.join(c for c in _COMMANDS if not c.startswith('--'))}",
            file=sys.stderr,
        )
        sys.exit(2)
    sys.exit(_COMMANDS[sys.argv[1]](sys.argv[2:]))
