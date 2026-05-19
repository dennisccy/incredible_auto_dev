#!/usr/bin/env python3
"""
render_iteration_summary.py — render a self-contained HTML view of one
iteration from the canonical `reports/phase-<phase>-iteration-summary.md`
file written by the iteration-summarizer agent.

Source of truth: the summary MD. This renderer does not re-parse the
12 underlying agent reports. If a section is absent from the summary MD,
the corresponding accordion is omitted. Browser-QA screenshots are still
embedded — paths are pulled from `reports/phase-<phase>-ui-test-results.md`
for hero + Quick-Verify step pairing.

Outputs:
  - reports/phase-<phase>-summary.html              (per-iter)
  - reports/goal-session-<sid>-index.html           (goal-mode session)

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
from typing import Optional

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────

# Fallback REPO_ROOT computed from the source file location. Used only when
# the CLI receives no `--repo-root=` arg and the marker-walk below finds no
# project marker. In layouts where the harness is mounted as a subdirectory
# of a larger project (e.g. `Aplhion/incredible_auto_dev/`), this fallback
# is the WRONG value — it points at the harness, not the project root —
# so the shell wrappers always pass `--repo-root="$REPO_ROOT"` to override.
_FALLBACK_REPO_ROOT = Path(__file__).resolve().parents[3]

# Files / directories that reliably mark a project root in this framework.
# `docs/goal.md` is required for goal mode, `.claude/project-template.md` is
# required by the framework, `.git` is the universal repo marker. Order
# matters: framework-specific markers take precedence over `.git` so a
# nested layout where the harness is itself a git submodule resolves to the
# outer project, not to the submodule.
_PROJECT_MARKERS: tuple[str, ...] = (
    "docs/goal.md",
    ".claude/project-template.md",
    ".git",
)

GOAL_ITER_RE = re.compile(r"^goal-(?P<sid>.+)-iter-(?P<n>\d+)$")


# ─────────────────────────────────────────────────────────────────────────────
# Data structures
# ─────────────────────────────────────────────────────────────────────────────


@dataclass
class IterationData:
    """All inputs the iteration-level renderer needs."""

    phase_id: str
    repo_root: Path
    is_goal_iter: bool = False
    session_id: Optional[str] = None
    iter_num: Optional[int] = None

    # From the summary MD header
    summary_md: Optional[str] = None
    summary_path: Optional[Path] = None
    verdict: str = "IN-PROGRESS"
    iter_type: str = "phase"  # phase | goal-lean | goal-full
    date_str: str = ""
    headline: str = ""

    # Parsed H2 sections from the summary MD
    sections: dict[str, str] = field(default_factory=dict)

    # External resources
    journeys: list[dict] = field(default_factory=list)
    screenshots: list[Path] = field(default_factory=list)
    # Captioned demo gallery (record-mode demo-narrator output).
    demo_verdict: str = ""  # RECORDED | RECORDED_WITH_NOTES | SKIPPED | NOT_YET
    demo_steps: list[dict] = field(default_factory=list)
    demo_notes: list[str] = field(default_factory=list)


@dataclass
class SessionData:
    session_id: str
    repo_root: Path
    goal_title: str = ""
    final_verdict: str = "IN-PROGRESS"
    total_iterations: int = 0
    wall_time_seconds: int = 0
    started_at: str = ""
    finished_at: str = ""
    journeys: list[dict] = field(default_factory=list)
    iterations: list[IterationData] = field(default_factory=list)
    latest_evaluator_note: str = ""
    # Cumulative plain-language story (state/project-story.md). Markdown source.
    project_story_md: str = ""
    # Reference to the most recent iteration whose demo gallery is renderable.
    latest_demo_iter: Optional["IterationData"] = None
    # True if reports/goal-session-<sid>-delivered.md / .html exists.
    delivered_md_exists: bool = False
    delivered_html_path: Optional[Path] = None


# ─────────────────────────────────────────────────────────────────────────────
# Markdown parsing — minimal: split on H2 boundaries, extract bullets / tables
# ─────────────────────────────────────────────────────────────────────────────


def _split_h2_sections(md: str) -> dict[str, str]:
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
    bullets: list[str] = []
    for line in body.splitlines():
        m = re.match(r"^\s*[-*]\s+(.+?)\s*$", line)
        if m:
            bullets.append(m.group(1).strip())
    return bullets


def _extract_numbered_steps(body: str) -> list[str]:
    steps: list[str] = []
    for line in body.splitlines():
        m = re.match(r"^\s*(\d+)\.\s+(.+?)\s*$", line)
        if m:
            steps.append(m.group(2).strip())
    return steps


def _parse_md_table(body: str) -> tuple[list[str], list[list[str]]]:
    """Return (header_cells, list_of_row_cells). Empty if no pipe-table found."""
    lines = [ln for ln in body.splitlines() if "|" in ln]
    if len(lines) < 2:
        return [], []
    # Drop separator row(s) like `|---|---|`
    rows: list[list[str]] = []
    for ln in lines:
        if re.fullmatch(r"\s*\|?[\s|:\-]+\|?\s*", ln):
            continue
        cells = [c.strip() for c in ln.strip().strip("|").split("|")]
        rows.append(cells)
    if not rows:
        return [], []
    return rows[0], rows[1:]


# ─────────────────────────────────────────────────────────────────────────────
# Header parsing — Verdict, Iteration type, Date, Iteration N
# ─────────────────────────────────────────────────────────────────────────────

_HEADER_FIELD_RE = re.compile(
    r"^\*\*(?P<key>Verdict|Iteration type|Date|Iteration):\*\*\s*(?P<val>.+?)\s*$",
    re.MULTILINE,
)
_VERDICT_ENUM = {
    "GOAL_ACHIEVED", "CONTINUE", "ESCALATE", "REGRESSION", "STALLED",
    "PASS", "FAIL", "IN-PROGRESS",
}
_ITER_TYPE_ENUM = {"phase", "goal-lean", "goal-full"}


def _parse_summary_header(md: str) -> dict[str, str]:
    out: dict[str, str] = {}
    # Only scan up to the first H2 — header fields live above it.
    head_only = re.split(r"^##\s+", md, maxsplit=1, flags=re.MULTILINE)[0]
    for m in _HEADER_FIELD_RE.finditer(head_only):
        out[m.group("key")] = m.group("val").strip()
    return out


# ─────────────────────────────────────────────────────────────────────────────
# Direction signal extraction
# ─────────────────────────────────────────────────────────────────────────────

_SIGNAL_VALUES = {"improving", "holding", "stalling", "regressing", "n/a"}


_PLAIN_WORDS_LABELS = ("What you can do now", "What changed this time", "What's next")


def _parse_plain_words(body: str) -> dict[str, str]:
    """Extract the three labelled parts from a '## In plain words' section body.

    Robust to multi-line values, extra blank lines, and label order changes.
    Each value runs until the next bold-label marker (`**Some Label:**`) or EOF.
    Returns labels mapped to their text (possibly empty if missing).
    """
    out = {label: "" for label in _PLAIN_WORDS_LABELS}
    if not body:
        return out
    for label in _PLAIN_WORDS_LABELS:
        pat = re.compile(
            rf"\*\*{re.escape(label)}:\*\*\s*(.+?)(?=\n\s*\*\*[A-Za-z][^*\n]*:\*\*|\Z)",
            re.DOTALL,
        )
        m = pat.search(body)
        if m:
            out[label] = re.sub(r"\s+", " ", m.group(1)).strip()
    return out


def _parse_direction_signal(direction_body: str) -> tuple[str, str]:
    """Return (signal, why_text). Signal defaults to 'n/a'."""
    signal = "n/a"
    why = ""
    m = re.search(r"\*\*Signal:\*\*\s*(\S+?)\s*$", direction_body, re.MULTILINE)
    if m and m.group(1).lower() in _SIGNAL_VALUES:
        signal = m.group(1).lower()
    m = re.search(r"\*\*Why:\*\*\s*(.+?)(?:\n\n|\n\*\*|\Z)", direction_body, re.DOTALL)
    if m:
        why = m.group(1).strip()
    return signal, why


def _parse_trend_block(direction_body: str) -> list[str]:
    """Return a list of trend bullets (lines after `**Trend (last K iters):**`)."""
    m = re.search(
        r"\*\*Trend[^*]*\*\*\s*\n(?P<body>(?:[-*]\s+.+\n?)+)",
        direction_body,
    )
    if not m:
        return []
    return _extract_bullets(m.group("body"))


def _parse_latest_reasoning(direction_body: str) -> str:
    m = re.search(
        r"\*\*Latest evaluator reasoning:\*\*\s*(.+?)(?:\n\n|\Z)",
        direction_body,
        re.DOTALL,
    )
    return m.group(1).strip() if m else ""


# ─────────────────────────────────────────────────────────────────────────────
# Data loading
# ─────────────────────────────────────────────────────────────────────────────


def _read_text(path: Path) -> Optional[str]:
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return None


def load_iteration(phase_id: str, repo_root: Path) -> IterationData:
    data = IterationData(phase_id=phase_id, repo_root=repo_root)
    m = GOAL_ITER_RE.match(phase_id)
    if m:
        data.is_goal_iter = True
        data.session_id = m.group("sid")
        try:
            data.iter_num = int(m.group("n"))
        except ValueError:
            data.iter_num = None

    summary_path = repo_root / "reports" / f"phase-{phase_id}-iteration-summary.md"
    data.summary_path = summary_path
    data.summary_md = _read_text(summary_path)

    if data.summary_md:
        header = _parse_summary_header(data.summary_md)
        v = header.get("Verdict", "").upper()
        if v in _VERDICT_ENUM:
            data.verdict = v
        it = header.get("Iteration type", "").lower()
        if it in _ITER_TYPE_ENUM:
            data.iter_type = it
        if "Date" in header:
            data.date_str = header["Date"]
        # Extract iter num from header if not derived from phase-id
        if "Iteration" in header and data.iter_num is None:
            try:
                data.iter_num = int(header["Iteration"].strip())
            except (ValueError, AttributeError):
                pass
        data.sections = _split_h2_sections(data.summary_md)
        # Headline section content is the one-line outcome
        data.headline = data.sections.get("Headline", "").strip().split("\n")[0]

    if not data.date_str:
        if summary_path.exists():
            data.date_str = _dt.datetime.fromtimestamp(
                summary_path.stat().st_mtime
            ).strftime("%Y-%m-%d")
        else:
            data.date_str = _dt.date.today().isoformat()

    if not data.headline:
        data.headline = phase_id

    # Journey pills come from journey-history (goal mode only)
    if data.is_goal_iter and data.session_id:
        jh = repo_root / "runs" / f"goal-session-{data.session_id}" / "state" / "journey-history.json"
        if jh.exists():
            try:
                data.journeys = _parse_journey_history(json.loads(jh.read_text()))
            except Exception:
                data.journeys = []

    # Browser-QA screenshots — pulled from ui-test-results.md evidence paths,
    # so the renderer doesn't depend on the agent embedding them in the summary.
    utr = _read_text(repo_root / "reports" / f"phase-{phase_id}-ui-test-results.md")
    if utr:
        for p in _evidence_paths_from_results(utr):
            full = repo_root / p
            if full.exists() and full.is_file():
                data.screenshots.append(full)

    # Demo gallery — record-mode demo-narrator output. Soft-loaded so the page
    # still renders when no demo exists yet.
    demo_results = _read_text(repo_root / "reports" / f"phase-{phase_id}-demo-results.md")
    if demo_results:
        data.demo_verdict, data.demo_steps, data.demo_notes = _parse_demo_results(demo_results)
        demo_script = _read_text(repo_root / "reports" / f"phase-{phase_id}-demo-script.md")
        narrations = _parse_demo_script_narrations(demo_script or "")
        for step in data.demo_steps:
            step["narration"] = narrations.get(step["number"], "")
            shot = step.get("screenshot", "")
            if shot:
                shot_path = repo_root / shot
                step["_screenshot_path"] = shot_path if shot_path.exists() else None
            else:
                step["_screenshot_path"] = None

    return data


def _parse_journey_history(data: dict) -> list[dict]:
    out: list[dict] = []
    for jid, info in sorted((data.get("journeys") or {}).items()):
        out.append({
            "id": jid,
            "name": info.get("name", jid),
            "status": info.get("status", "unknown"),
            "last_verified_iter": info.get("last_verified_iter"),
            "last_passing_iter": info.get("last_passing_iter"),
        })
    return out


_DEMO_VERDICTS = {"RECORDED", "RECORDED_WITH_NOTES", "SKIPPED", "NOT_YET"}
_DEMO_VERDICT_RE = re.compile(r"^\*\*Demo Verdict:\*\*\s+([A-Z_]+)\s*$", re.MULTILINE)


def _parse_demo_results(md: str) -> tuple[str, list[dict], list[str]]:
    """Return (verdict, captured_steps, soft_notes) from a demo-results.md body.

    - verdict: one of _DEMO_VERDICTS, or "" if missing/invalid.
    - captured_steps: list of dicts {number, title, is_new, screenshot} parsed
      from the 'Captured Steps' pipe-table. Empty if no table.
    - soft_notes: bullet lines under the '## Soft notes' section.
    """
    verdict = ""
    if md:
        m = _DEMO_VERDICT_RE.search(md)
        if m and m.group(1) in _DEMO_VERDICTS:
            verdict = m.group(1)

    sections = _split_h2_sections(md or "")
    steps: list[dict] = []
    body = sections.get("Captured Steps", "")
    header, rows = _parse_md_table(body)
    if header and rows:
        idx = {name.strip().lower(): i for i, name in enumerate(header)}
        for r in rows:
            def _get(name: str) -> str:
                i = idx.get(name)
                return r[i].strip() if i is not None and i < len(r) else ""
            step_text = _get("step")
            if not step_text or step_text == "-":
                continue
            try:
                number = int(re.sub(r"[^0-9]", "", step_text) or 0)
            except ValueError:
                number = 0
            if number == 0:
                continue
            new_text = _get("new").lower()
            is_new = new_text in {"yes", "y", "true", "✓", "✔", "new"}
            steps.append({
                "number": number,
                "title": _get("title"),
                "is_new": is_new,
                "screenshot": _get("screenshot"),
            })
        steps.sort(key=lambda s: s["number"])

    notes = _extract_bullets(sections.get("Soft notes", ""))
    return verdict, steps, notes


# Per-step narration is sourced from the demo-script.md if present so the
# gallery caption is one short sentence instead of the bare title.
_DEMO_SCRIPT_STEP_RE = re.compile(
    r"^###\s+Step\s+(?P<num>\d+)\b[^\n]*\n(?P<body>(?:.*\n)*?)(?=^###\s+Step|\Z)",
    re.MULTILINE,
)
_DEMO_SCRIPT_NARRATION_RE = re.compile(
    r"^[-*]\s+\*\*Narration:\*\*\s*(.+?)\s*$",
    re.MULTILINE,
)


def _parse_demo_script_narrations(md: str) -> dict[int, str]:
    """Map step number → narration sentence from a demo-script.md body."""
    out: dict[int, str] = {}
    if not md:
        return out
    for m in _DEMO_SCRIPT_STEP_RE.finditer(md):
        try:
            num = int(m.group("num"))
        except ValueError:
            continue
        body = m.group("body")
        nm = _DEMO_SCRIPT_NARRATION_RE.search(body)
        if nm:
            out[num] = nm.group(1).strip()
    return out


def _evidence_paths_from_results(md: str) -> list[str]:
    seen: set[str] = set()
    paths: list[str] = []
    for m in re.finditer(r"\*\*Evidence:\*\*\s*`([^`]+\.png)`", md):
        p = m.group(1).strip()
        if p and p not in seen:
            seen.add(p)
            paths.append(p)
    for line in md.splitlines():
        if "|" not in line:
            continue
        for m in re.finditer(r"([\w./-]+\.png)", line):
            p = m.group(1)
            if p and p not in seen and "none" not in p.lower():
                seen.add(p)
                paths.append(p)
    return paths


def load_session(session_id: str, repo_root: Path) -> SessionData:
    s = SessionData(session_id=session_id, repo_root=repo_root)
    session_dir = repo_root / "runs" / f"goal-session-{session_id}"
    sj = session_dir / "session.json"
    if sj.exists():
        try:
            d = json.loads(sj.read_text())
            s.final_verdict = d.get("status", "IN-PROGRESS")
            s.total_iterations = int(d.get("total_iterations") or 0)
            s.wall_time_seconds = int(d.get("wall_time_seconds") or 0)
            s.started_at = d.get("started_at", "")
            s.finished_at = d.get("finished_at", "")
        except Exception:
            pass

    s.goal_title = _parse_goal_title(_read_text(repo_root / "docs" / "goal.md"))

    jh = session_dir / "state" / "journey-history.json"
    if jh.exists():
        try:
            s.journeys = _parse_journey_history(json.loads(jh.read_text()))
        except Exception:
            s.journeys = []

    # Discover iter dirs by scanning runs/ for matching phase ids
    if (repo_root / "runs").is_dir():
        for sub in sorted((repo_root / "runs").iterdir()):
            if not sub.is_dir():
                continue
            m = GOAL_ITER_RE.match(sub.name)
            if not m or m.group("sid") != session_id:
                continue
            s.iterations.append(load_iteration(sub.name, repo_root))
    s.iterations.sort(key=lambda d: (d.iter_num if d.iter_num is not None else 0))

    if not s.total_iterations:
        s.total_iterations = len(s.iterations)

    log = _read_text(session_dir / "state" / "evaluator-log.md")
    if log:
        parts = re.split(r"^##\s+Iteration\b", log, flags=re.MULTILINE)
        if len(parts) > 1:
            s.latest_evaluator_note = ("## Iteration" + parts[-1]).strip()

    # Cumulative project story (plain-language running narrative).
    story = _read_text(session_dir / "state" / "project-story.md")
    if story:
        s.project_story_md = story

    # Latest iteration that has a renderable demo gallery — used to embed the
    # most recent narrated walkthrough at the session level.
    for it in reversed(s.iterations):
        if it.demo_steps:
            s.latest_demo_iter = it
            break

    # Detect the one-time delivered wrap.
    delivered_md = repo_root / "reports" / f"goal-session-{session_id}-delivered.md"
    if delivered_md.exists():
        s.delivered_md_exists = True
        delivered_html = repo_root / "reports" / f"goal-session-{session_id}-delivered.html"
        if delivered_html.exists():
            s.delivered_html_path = delivered_html

    return s


def _parse_goal_title(md: Optional[str]) -> str:
    if not md:
        return ""
    for line in md.splitlines():
        m = re.match(r"^#\s+(.+?)\s*$", line)
        if m:
            return m.group(1).strip()
    return ""


# ─────────────────────────────────────────────────────────────────────────────
# Screenshot embedding (unchanged from prior implementation)
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
                    kwargs = {"optimize": True} if save_fmt == "PNG" else {"quality": 85, "optimize": True}
                    img.save(buf, save_fmt, **kwargs)
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
# Inline CSS + SVG
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
.badge-row { display: flex; gap: 8px; justify-content: center; flex-wrap: wrap; margin-bottom: 10px; }
.badge {
  display: inline-flex; align-items: center; gap: 8px;
  padding: 6px 14px; border-radius: 999px; font-weight: 600; font-size: 0.95rem;
}
.badge.pass { background: #dafbe1; color: #1a7f37; }
.badge.fail { background: #ffebe9; color: #cf222e; }
.badge.inprogress { background: #fff8c5; color: #9a6700; }
.signal-badge { padding: 6px 14px; border-radius: 999px; font-weight: 600; font-size: 0.9rem; }
.signal-badge.improving { background: #dafbe1; color: #1a7f37; }
.signal-badge.holding { background: #ddf4ff; color: #0969da; }
.signal-badge.stalling { background: #fff8c5; color: #9a6700; }
.signal-badge.regressing { background: #ffebe9; color: #cf222e; }
.signal-badge.na { background: #f6f8fa; color: #57606a; }
.meta { color: #57606a; font-size: 0.875rem; margin: 10px 0 16px; }
.journey-row {
  display: flex; flex-wrap: wrap; gap: 8px; justify-content: center; margin: 12px 0 4px;
}
.journey-pill {
  display: inline-flex; align-items: center; gap: 6px;
  padding: 4px 10px; border-radius: 999px; font-size: 0.85rem;
  background: #f6f8fa; border: 1px solid #d0d7de;
}
.journey-pill.passing, .journey-pill.already_passing { background: #dafbe1; color: #1a7f37; border-color: #b4e2c0; }
.journey-pill.failing, .journey-pill.regressed { background: #ffebe9; color: #cf222e; border-color: #f1aeb0; }
.journey-pill.partial { background: #fff8c5; color: #9a6700; border-color: #eed888; }
.journey-pill.unknown { background: #f6f8fa; color: #57606a; }
.hero-image { margin-top: 18px; }
.hero-image img { max-width: 100%; height: auto; border-radius: 6px; border: 1px solid #d0d7de; }
details {
  background: white; border: 1px solid #d0d7de; border-radius: 8px;
  margin-bottom: 12px;
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
.why-text { background: #f6f8fa; padding: 10px 12px; border-radius: 6px; margin: 4px 0 12px; }
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
.step-shot { margin-top: 10px; }
.step-shot img { max-width: 100%; height: auto; border-radius: 6px; border: 1px solid #d0d7de; }
.next-step-box {
  background: #ddf4ff; padding: 12px 16px; border-radius: 6px;
  border-left: 4px solid #0969da; margin: 12px 0;
}
.drill-table { width: 100%; border-collapse: collapse; font-size: 0.92rem; }
.drill-table th, .drill-table td {
  text-align: left; padding: 8px 6px; border-bottom: 1px solid #eaeef2;
}
.drill-table th { background: #f6f8fa; }
.verdict-cell.PASS, .verdict-cell.CLOSURE-PASS, .verdict-cell.GOAL_ACHIEVED { color: #1a7f37; font-weight: 600; }
.verdict-cell.FAIL, .verdict-cell.CLOSURE-FAIL, .verdict-cell.REGRESSION { color: #cf222e; font-weight: 600; }
.verdict-cell.CONTINUE, .verdict-cell.ESCALATE, .verdict-cell.STALLED { color: #9a6700; font-weight: 600; }
.verdict-cell.SKIPPED, .verdict-cell.UNKNOWN, .verdict-cell.IN-PROGRESS { color: #57606a; }
.footer-note { text-align: center; color: #6e7781; font-size: 0.8rem; margin-top: 24px; }
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
.no-summary {
  background: #fff8c5; border: 1px solid #eed888; padding: 14px 18px;
  border-radius: 8px; color: #9a6700; margin-bottom: 14px;
}
/* Plain-language layer — the primary, non-technical view. */
.plain-words {
  background: linear-gradient(180deg, #ffffff 0%, #f6fbff 100%);
  border: 1px solid #d6e4f0; border-radius: 10px;
  padding: 22px 24px; margin: 18px 0 6px;
  box-shadow: 0 1px 2px rgba(20, 40, 80, 0.04);
}
.plain-words .pw-heading {
  margin: 0 0 14px; font-size: 1.15rem; color: #0969da;
  text-transform: uppercase; letter-spacing: 0.05em;
}
.pw-grid {
  display: grid; gap: 14px;
  grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
}
.pw-card {
  background: white; border-radius: 8px; padding: 14px 16px;
  border: 1px solid #e3eaf3;
}
.pw-card .pw-label {
  font-size: 0.78rem; font-weight: 600; color: #57606a;
  text-transform: uppercase; letter-spacing: 0.04em; margin-bottom: 6px;
}
.pw-card .pw-text {
  margin: 0; font-size: 1rem; color: #1f2328; line-height: 1.45;
}
.pw-empty { color: #8c959f; font-style: italic; font-size: 0.95rem; }
.tech-divider {
  margin: 18px 0 8px; text-align: center;
  color: #6e7781; font-size: 0.82rem; font-style: italic;
  border-top: 1px dashed #d0d7de; padding-top: 12px;
}
/* Watch-it-work — narrated screenshot gallery from demo-narrator. */
.watch-it-work {
  background: white; border: 1px solid #d6e4f0; border-radius: 10px;
  padding: 18px 22px; margin: 10px 0 6px;
}
.wiw-head {
  display: flex; align-items: center; justify-content: space-between;
  gap: 12px; margin-bottom: 14px; flex-wrap: wrap;
}
.wiw-heading {
  margin: 0; font-size: 1.05rem; color: #0969da;
  text-transform: uppercase; letter-spacing: 0.05em;
}
.demo-badge {
  font-size: 0.75rem; font-weight: 600; padding: 4px 10px; border-radius: 12px;
  border: 1px solid transparent; letter-spacing: 0.04em;
}
.demo-badge.demo-recorded { background: #dafbe1; color: #1a7f37; border-color: #aceebb; }
.demo-badge.demo-notes    { background: #fff8c5; color: #9a6700; border-color: #e8d97e; }
.demo-badge.demo-skipped  { background: #f6f8fa; color: #57606a; border-color: #d0d7de; }
.demo-badge.demo-pending  { background: #ddf4ff; color: #0969da; border-color: #b6e3ff; }
.demo-grid {
  display: grid; gap: 14px;
  grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
}
.demo-step {
  margin: 0; padding: 12px; background: #f6f8fa;
  border: 1px solid #d0d7de; border-radius: 8px;
}
.demo-step-head {
  display: flex; align-items: center; gap: 8px; margin-bottom: 8px;
  font-size: 0.9rem;
}
.demo-step-num {
  font-weight: 600; color: #57606a; font-variant-numeric: tabular-nums;
}
.demo-step-title { color: #1f2328; font-weight: 500; }
.demo-new {
  background: #ddf4ff; color: #0969da; font-size: 0.7rem; font-weight: 700;
  padding: 2px 6px; border-radius: 4px; letter-spacing: 0.06em;
}
.demo-shot { margin-bottom: 8px; }
.demo-shot img {
  width: 100%; height: auto; border-radius: 4px; border: 1px solid #d0d7de;
  display: block;
}
.demo-narration {
  margin: 0; color: #1f2328; font-size: 0.92rem; line-height: 1.4;
}
.demo-empty {
  margin: 8px 0 0; color: #57606a; font-style: italic;
}
.demo-notes-wrap { margin-top: 14px; }
.demo-notes-wrap summary {
  cursor: pointer; color: #9a6700; font-weight: 500; font-size: 0.9rem;
}
.demo-notes-wrap[open] summary { margin-bottom: 6px; }
/* Story so far + latest demo (session index plain-language top). */
.story-so-far {
  background: linear-gradient(180deg, #ffffff 0%, #f6fbff 100%);
  border: 1px solid #d6e4f0; border-radius: 10px;
  padding: 22px 26px; margin: 14px 0 6px;
  box-shadow: 0 1px 2px rgba(20, 40, 80, 0.04);
}
.story-heading {
  margin: 0 0 12px; font-size: 1.1rem; color: #0969da;
  text-transform: uppercase; letter-spacing: 0.05em;
}
.story-body { font-size: 1rem; color: #1f2328; line-height: 1.55; }
.story-body .story-h { margin: 14px 0 6px; color: #1f2328; }
.story-body p { margin: 0 0 10px; }
.session-demo {
  background: white; border: 1px solid #d6e4f0; border-radius: 10px;
  padding: 0; margin: 8px 0 6px; overflow: hidden;
}
.session-demo-head {
  display: flex; align-items: center; justify-content: space-between;
  gap: 10px; padding: 12px 22px;
  background: #f6f8fa; border-bottom: 1px solid #d6e4f0;
  font-weight: 600; color: #1f2328; font-size: 0.95rem;
}
.session-demo-head a.open { color: #0969da; text-decoration: none; font-weight: 500; font-size: 0.9rem; }
.session-demo-head a.open:hover { text-decoration: underline; }
.session-demo .watch-it-work {
  border: none; border-radius: 0; box-shadow: none; margin: 0;
}
/* Delivered link banner — sits on the session index when GOAL_ACHIEVED. */
.delivered-link {
  margin: 14px 0; padding: 14px 22px;
  background: #dafbe1; border: 1px solid #aceebb; border-radius: 10px;
  color: #1a7f37; font-size: 1rem;
}
.delivered-link a {
  color: #1a7f37; font-weight: 600; text-decoration: none; margin-left: 8px;
}
.delivered-link a:hover { text-decoration: underline; }
.delivered-back {
  margin: 8px 0 14px; padding: 0; font-size: 0.9rem;
}
.delivered-back a { color: #0969da; text-decoration: none; }
.delivered-back a:hover { text-decoration: underline; }
.delivered-body {
  background: white; border: 1px solid #d6e4f0; border-radius: 10px;
  padding: 22px 28px; margin: 12px 0;
}
.delivered-body h2.story-h { margin-top: 0; }
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
    if verdict in ("PASS", "GOAL_ACHIEVED"):
        return "pass"
    if verdict in ("FAIL", "REGRESSION"):
        return "fail"
    return "inprogress"


def _verdict_icon(verdict: str) -> str:
    cls = _verdict_class(verdict)
    if cls == "pass":
        return SVG_CHECK
    if cls == "fail":
        return SVG_X
    return SVG_CLOCK


def _signal_class(signal: str) -> str:
    return signal if signal in ("improving", "holding", "stalling", "regressing") else "na"


# ─────────────────────────────────────────────────────────────────────────────
# HTML — iteration page
# ─────────────────────────────────────────────────────────────────────────────


def render_html_iteration(data: IterationData) -> str:
    parts: list[str] = [
        "<!doctype html>",
        '<html lang="en"><head>',
        '<meta charset="utf-8">',
        f"<title>{escape(data.phase_id)} — Iteration Summary</title>",
        f"<style>{CSS}</style>",
        "</head><body><div class='container'>",
    ]
    parts.append(_render_hero(data))
    if not data.summary_md:
        parts.append(_render_no_summary_placeholder(data))
    else:
        # Plain-language layer leads — for non-technical readers. The technical
        # accordions below are collapsed by default.
        parts.append(_render_plain_words(data))
        parts.append(_render_watch_it_work(data))
        parts.append(_render_technical_intro())
        parts.append(_render_what_was_done(data))
        parts.append(_render_whats_left_next_step(data))
        parts.append(_render_direction_trend(data))
        parts.append(_render_quick_verify(data))
        parts.append(_render_artifacts(data))
    parts.append(_render_footer(data))
    parts.append("</div></body></html>")
    return "\n".join(p for p in parts if p)


def _render_plain_words(data: IterationData) -> str:
    body = data.sections.get("In plain words", "")
    parts = _parse_plain_words(body)
    # Skip rendering only when every part is empty AND the section header is
    # absent — older summaries written before this layer existed.
    if not body and not any(parts.values()):
        return ""

    def _card(label: str, text: str, *, fallback: str) -> str:
        rendered = escape(text) if text else f"<em class='pw-empty'>{escape(fallback)}</em>"
        return (
            "<div class='pw-card'>"
            f"<div class='pw-label'>{escape(label)}</div>"
            f"<p class='pw-text'>{rendered}</p>"
            "</div>"
        )

    cards = "".join((
        _card(
            "What you can do now",
            parts["What you can do now"],
            fallback="Just getting started — nothing for users to try yet.",
        ),
        _card(
            "What changed this time",
            parts["What changed this time"],
            fallback="No user-visible changes this iteration.",
        ),
        _card(
            "What's next",
            parts["What's next"],
            fallback="To be decided.",
        ),
    ))
    return (
        "<section class='plain-words'>"
        "<h2 class='pw-heading'>In plain words</h2>"
        f"<div class='pw-grid'>{cards}</div>"
        "</section>"
    )


def _render_technical_intro() -> str:
    """Small divider hint that the sections below are the technical detail.

    Helps non-technical readers know they can stop scrolling.
    """
    return (
        "<div class='tech-divider'>"
        "<span>Technical detail below — open if you want the developer view.</span>"
        "</div>"
    )


def _render_watch_it_work(data: IterationData) -> str:
    """Captioned screenshot gallery from the record-mode demo-narrator."""
    # When no demo artifact at all — render nothing.
    if not data.demo_verdict and not data.demo_steps:
        return ""

    # Headline state badge for the gallery section.
    badge_text = data.demo_verdict or "PENDING"
    badge_class = {
        "RECORDED": "demo-recorded",
        "RECORDED_WITH_NOTES": "demo-notes",
        "SKIPPED": "demo-skipped",
        "NOT_YET": "demo-pending",
    }.get(data.demo_verdict, "demo-pending")

    cards: list[str] = []
    for step in data.demo_steps:
        title = escape(step.get("title", "") or f"Step {step['number']:02d}")
        narration = escape(step.get("narration", "") or "")
        new_badge = (
            "<span class='demo-new'>NEW</span>"
            if step.get("is_new") else ""
        )
        shot_html = ""
        shot_path = step.get("_screenshot_path")
        if shot_path:
            url = embed_image(shot_path)
            if url:
                shot_html = (
                    f"<div class='demo-shot'><img src='{url}' "
                    f"alt='Step {step['number']:02d}: {title}'></div>"
                )
        cards.append(
            "<figure class='demo-step'>"
            f"<div class='demo-step-head'>"
            f"<span class='demo-step-num'>Step {step['number']:02d}</span>"
            f"{new_badge}"
            f"<span class='demo-step-title'>{title}</span>"
            "</div>"
            f"{shot_html}"
            + (f"<figcaption class='demo-narration'>{narration}</figcaption>"
               if narration else "")
            + "</figure>"
        )

    # Verdict-only states (SKIPPED / NOT_YET / no captured steps) get a friendly
    # one-liner instead of an empty grid.
    if not cards:
        explainer = {
            "SKIPPED": "No browser walkthrough this iteration — backend-only work or the app wasn't reachable.",
            "NOT_YET": "Just getting started — nothing for users to try yet.",
            "RECORDED": "Recorded, but no steps were captured.",
            "RECORDED_WITH_NOTES": "Recorded, but no steps were captured.",
        }.get(data.demo_verdict, "Demo recording pending.")
        body_inner = f"<p class='demo-empty'>{escape(explainer)}</p>"
    else:
        body_inner = f"<div class='demo-grid'>{''.join(cards)}</div>"

    notes_html = ""
    if data.demo_notes:
        items = "".join(f"<li>{escape(n)}</li>" for n in data.demo_notes)
        notes_html = (
            "<details class='demo-notes-wrap'>"
            "<summary>Notes from the walk-through</summary>"
            f"<ul class='bullets'>{items}</ul>"
            "</details>"
        )

    return (
        "<section class='watch-it-work'>"
        "<div class='wiw-head'>"
        "<h2 class='wiw-heading'>Watch it work</h2>"
        f"<span class='demo-badge {badge_class}'>{escape(badge_text)}</span>"
        "</div>"
        f"{body_inner}"
        f"{notes_html}"
        "</section>"
    )


def _render_hero(data: IterationData) -> str:
    cls = _verdict_class(data.verdict)
    icon = _verdict_icon(data.verdict)
    title = data.phase_id
    if data.is_goal_iter and data.iter_num is not None:
        title = f"Iteration {data.iter_num}  ·  session {data.session_id}"
    journey_pills = ""
    pass_count = 0
    if data.journeys:
        pills = []
        for j in data.journeys:
            status = j["status"]
            cls_j = re.sub(r"[^a-z_]", "", status.lower()) or "unknown"
            if status in ("passing", "already_passing"):
                pass_count += 1
            pills.append(
                f"<span class='journey-pill {cls_j}' title='{escape(j['name'])}'>"
                f"{escape(j['id'])} · {escape(status)}</span>"
            )
        journey_pills = f"<div class='journey-row'>{''.join(pills)}</div>"
    journey_summary = (
        f"<div class='meta'>Journeys: {pass_count}/{len(data.journeys)} passing</div>"
        if data.journeys else ""
    )
    # Direction badge
    signal_html = ""
    if data.summary_md:
        signal, _ = _parse_direction_signal(data.sections.get("Direction", ""))
        if signal != "n/a":
            scls = _signal_class(signal)
            signal_html = f"<span class='signal-badge {scls}'>Direction: {escape(signal)}</span>"
    hero_img = ""
    if data.screenshots:
        url = embed_image(data.screenshots[0])
        if url:
            hero_img = f"<div class='hero-image'><img src='{url}' alt='Hero screenshot'></div>"
    return (
        f"<section class='hero {cls}'>"
        f"<div class='badge-row'>"
        f"<div class='badge {cls}'>{icon}<span>{escape(data.verdict)}</span></div>"
        f"{signal_html}"
        f"</div>"
        f"<h1>{escape(title)}</h1>"
        f"<h2>{escape(data.headline)}</h2>"
        f"<div class='meta'>{escape(data.date_str)} · {escape(data.iter_type)}</div>"
        f"{journey_summary}"
        f"{journey_pills}"
        f"{hero_img}"
        f"</section>"
    )


def _render_no_summary_placeholder(data: IterationData) -> str:
    cmd = f"bash scripts/automation/render-summary.sh {data.phase_id}"
    return (
        "<div class='no-summary'>"
        "<strong>No iteration summary available.</strong> "
        "Run the iteration-summarizer to generate one:"
        f"<pre style='margin:8px 0 0;background:white;padding:8px;border-radius:4px'>{escape(cmd)}</pre>"
        "</div>"
    )


def _render_what_was_done(data: IterationData) -> str:
    body = data.sections.get("What was done", "")
    bullets = _extract_bullets(body)
    if not bullets:
        return ""
    items = "".join(f"<li>{escape(b)}</li>" for b in bullets)
    return (
        f"<details><summary>What was done</summary>"
        f"<div class='accordion-body'><ul class='bullets'>{items}</ul></div></details>"
    )


def _render_whats_left_next_step(data: IterationData) -> str:
    left_body = data.sections.get("What's left", "")
    next_body = data.sections.get("Next step", "")
    left_bullets = _extract_bullets(left_body)
    parts: list[str] = []
    if left_bullets:
        items = "".join(f"<li>{escape(b)}</li>" for b in left_bullets)
        parts.append(f"<h3>Still open</h3><ul class='bullets'>{items}</ul>")
    if next_body.strip():
        parts.append(f"<h3>Next step</h3><div class='next-step-box'>{escape(next_body.strip())}</div>")
    if not parts:
        return ""
    return (
        f"<details><summary>What's left + Next step</summary>"
        f"<div class='accordion-body'>{''.join(parts)}</div></details>"
    )


def _render_direction_trend(data: IterationData) -> str:
    body = data.sections.get("Direction", "")
    if not body.strip():
        return ""
    signal, why = _parse_direction_signal(body)
    trend = _parse_trend_block(body)
    reasoning = _parse_latest_reasoning(body)
    parts: list[str] = []
    if why:
        parts.append(f"<div class='why-text'><strong>Why:</strong> {escape(why)}</div>")
    if trend:
        items = "".join(f"<li>{escape(t)}</li>" for t in trend)
        parts.append(f"<h3>Trend</h3><ul class='bullets'>{items}</ul>")
    if reasoning:
        parts.append(
            f"<h3>Latest evaluator reasoning</h3>"
            f"<div class='why-text'>{escape(reasoning)}</div>"
        )
    if not parts:
        return ""
    # All technical accordions are collapsed by default — the plain-words
    # block above is the primary view; this one is opt-in even in goal mode.
    return (
        f"<details><summary>Direction signal</summary>"
        f"<div class='accordion-body'>{''.join(parts)}</div></details>"
    )


def _render_quick_verify(data: IterationData) -> str:
    body = data.sections.get("Quick verify", "")
    steps = _extract_numbered_steps(body)
    if not steps:
        return ""
    screenshots = list(data.screenshots)
    # Skip first screenshot (used as hero) when pairing with steps for visual variety.
    paired = screenshots[1:] if len(screenshots) > 1 else screenshots
    items: list[str] = []
    for idx, step in enumerate(steps):
        shot_html = ""
        if idx < len(paired):
            url = embed_image(paired[idx])
            if url:
                shot_html = f"<div class='step-shot'><img src='{url}' alt='Step {idx+1}'></div>"
        items.append(
            f"<li><span class='step-action'>{escape(step)}</span>{shot_html}</li>"
        )
    return (
        f"<details><summary>Quick verify (5 min)</summary>"
        f"<div class='accordion-body'><ol class='steps'>{''.join(items)}</ol></div></details>"
    )


def _render_artifacts(data: IterationData) -> str:
    body = data.sections.get("Artifacts", "")
    header, rows = _parse_md_table(body)
    if not rows:
        return ""
    # Build header
    thead_cells = "".join(f"<th>{escape(h)}</th>" for h in header)
    tbody_rows: list[str] = []
    for r in rows:
        cells: list[str] = []
        for i, cell in enumerate(r):
            text = cell.strip()
            # Verdict column (column index 1 in our standard table)
            if i == 1 and header and header[i].lower() == "verdict":
                cells.append(f"<td><span class='verdict-cell {escape(text)}'>{escape(text)}</span></td>")
                continue
            # Path column — turn into a relative link from reports/ where the
            # HTML lives.
            if i == len(r) - 1 and text and "/" in text:
                href = os.path.relpath(text, start="reports")
                cells.append(f"<td><a href='{escape(href)}'>{escape(text)}</a></td>")
                continue
            cells.append(f"<td>{escape(text)}</td>")
        tbody_rows.append(f"<tr>{''.join(cells)}</tr>")
    table = (
        f"<table class='drill-table'><thead><tr>{thead_cells}</tr></thead>"
        f"<tbody>{''.join(tbody_rows)}</tbody></table>"
    )
    return (
        f"<details><summary>Artifacts</summary>"
        f"<div class='accordion-body'>{table}</div></details>"
    )


def _render_footer(data: IterationData) -> str:
    now = _dt.datetime.now().strftime("%Y-%m-%d %H:%M")
    src = ""
    if data.summary_path and data.summary_path.exists():
        rel = os.path.relpath(str(data.summary_path), start=str(data.repo_root / "reports"))
        src = f" · source: <a href='{escape(rel)}'>{escape(rel)}</a>"
    return (
        f"<div class='footer-note'>Generated {escape(now)} by "
        f"<code>render_iteration_summary.py</code>{src}</div>"
    )


# ─────────────────────────────────────────────────────────────────────────────
# HTML — session index
# ─────────────────────────────────────────────────────────────────────────────


def render_html_session_index(data: SessionData) -> str:
    parts: list[str] = [
        "<!doctype html>",
        '<html lang="en"><head>',
        '<meta charset="utf-8">',
        f"<title>Goal session {escape(data.session_id)}</title>",
        f"<style>{CSS}</style>",
        "</head><body><div class='container'>",
        _render_session_hero(data),
        _render_delivered_link(data),
        _render_story_so_far(data),
        _render_latest_demo(data),
        _render_session_technical_intro(data),
        _render_journey_matrix(data),
        _render_iter_cards(data),
        _render_evaluator_note(data),
        f"<div class='footer-note'>Generated {escape(_dt.datetime.now().strftime('%Y-%m-%d %H:%M'))}</div>",
        "</div></body></html>",
    ]
    return "\n".join(p for p in parts if p)


def _render_story_so_far(data: SessionData) -> str:
    if not data.project_story_md:
        return ""
    html_body = _markdown_lite_to_html(data.project_story_md)
    return (
        "<section class='story-so-far'>"
        "<h2 class='story-heading'>The story so far</h2>"
        f"<div class='story-body'>{html_body}</div>"
        "</section>"
    )


def _render_latest_demo(data: SessionData) -> str:
    it = data.latest_demo_iter
    if not it or not it.demo_steps:
        return ""
    label = f"iter-{it.iter_num}" if it.iter_num is not None else escape(it.phase_id)
    iter_link = f"phase-{it.phase_id}-summary.html"
    # Reuse the iteration-level helper so the gallery looks identical to the
    # per-iteration page (NEW badges, captions, demo-verdict badge).
    gallery_html = _render_watch_it_work(it)
    if not gallery_html:
        return ""
    return (
        "<section class='session-demo'>"
        f"<div class='session-demo-head'><span>Latest walkthrough — {escape(label)}</span>"
        f"<a class='open' href='{escape(iter_link)}'>Open full iteration →</a></div>"
        f"{gallery_html}"
        "</section>"
    )


def _render_session_technical_intro(data: SessionData) -> str:
    # Only show the divider when there is plain-language content above it,
    # otherwise the matrix/cards stand on their own as before.
    if not (data.project_story_md or data.latest_demo_iter):
        return ""
    return (
        "<div class='tech-divider'>"
        "<span>Journey-by-journey progress and per-iteration cards below — open if you want the developer view.</span>"
        "</div>"
    )


def _render_delivered_link(data: SessionData) -> str:
    if not data.delivered_md_exists:
        return ""
    if data.delivered_html_path is not None:
        href = data.delivered_html_path.name
    else:
        href = f"goal-session-{data.session_id}-delivered.html"
    return (
        "<aside class='delivered-link'>"
        "<strong>Goal achieved.</strong> "
        f"<a href='{escape(href)}'>Read the &ldquo;What we delivered&rdquo; wrap →</a>"
        "</aside>"
    )


# ─────────────────────────────────────────────────────────────────────────────
# Lightweight Markdown → HTML for the cumulative project story
# Handles H1/H2, paragraphs, italics — enough for project-story.md.
# Avoids pulling in a full Markdown lib (keeps the renderer dependency-free).
# ─────────────────────────────────────────────────────────────────────────────


def _markdown_lite_to_html(md: str) -> str:
    out: list[str] = []
    para: list[str] = []

    def _flush_para() -> None:
        if not para:
            return
        joined = " ".join(line.strip() for line in para).strip()
        if joined:
            out.append(f"<p>{_md_inline(joined)}</p>")
        para.clear()

    for raw_line in md.splitlines():
        line = raw_line.rstrip()
        if not line.strip():
            _flush_para()
            continue
        m = re.match(r"^(#{1,3})\s+(.+?)\s*$", line)
        if m:
            _flush_para()
            level = len(m.group(1))
            tag = {1: "h2", 2: "h3", 3: "h4"}[level]
            out.append(f"<{tag} class='story-h'>{_md_inline(m.group(2))}</{tag}>")
            continue
        para.append(line)
    _flush_para()
    return "\n".join(out)


def _md_inline(s: str) -> str:
    s = escape(s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"(?<![*_])_(.+?)_(?![*_])", r"<em>\1</em>", s)
    s = re.sub(r"\*(.+?)\*", r"<em>\1</em>", s)
    return s


def _render_session_hero(data: SessionData) -> str:
    cls = _verdict_class(data.final_verdict)
    icon = _verdict_icon(data.final_verdict)
    pass_count = sum(1 for j in data.journeys if j["status"] in ("passing", "already_passing"))
    minutes = data.wall_time_seconds // 60
    return (
        f"<section class='hero {cls}'>"
        f"<div class='badge-row'><div class='badge {cls}'>{icon}<span>{escape(data.final_verdict)}</span></div></div>"
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
            lpi = j.get("last_passing_iter") or ""
            if lpi and (lpi == it.phase_id or lpi.endswith(f"iter-{it.iter_num}")):
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
        href = f"phase-{it.phase_id}-summary.html"
        label = f"Iteration {it.iter_num}" if it.iter_num is not None else it.phase_id
        cards.append(
            "<div class='iter-card'>"
            f"<div class='left'><div class='badge {cls}'>{icon}<span>{escape(it.verdict)}</span></div></div>"
            "<div class='body'>"
            f"<div class='title'>{escape(label)} — {escape(it.headline)}</div>"
            f"<div class='sub'>{escape(it.date_str)} · {escape(it.iter_type)} · <code>{escape(it.phase_id)}</code></div>"
            "</div>"
            f"<a class='open' href='{escape(href)}'>Open summary →</a>"
            "</div>"
        )
    return "<h2 style='font-size:1rem;color:#57606a;margin:14px 0 6px'>Iterations</h2>" + "".join(cards)


def _render_evaluator_note(data: SessionData) -> str:
    if not data.latest_evaluator_note:
        return ""
    snippet = data.latest_evaluator_note
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
    return repo_root / "reports" / f"phase-{phase_id}-summary.html"


def session_index_output_path(session_id: str, repo_root: Path) -> Path:
    return repo_root / "reports" / f"goal-session-{session_id}-index.html"


def delivered_output_path(session_id: str, repo_root: Path) -> Path:
    return repo_root / "reports" / f"goal-session-{session_id}-delivered.html"


# ─────────────────────────────────────────────────────────────────────────────
# HTML — delivered wrap (one-time, fires on GOAL_ACHIEVED)
# ─────────────────────────────────────────────────────────────────────────────


def render_html_delivered(data: SessionData, delivered_md: str) -> str:
    body_html = _markdown_lite_to_html(delivered_md)
    # Latest demo gallery embedded — the user-facing companion to the wrap.
    gallery_html = ""
    if data.latest_demo_iter and data.latest_demo_iter.demo_steps:
        gallery_html = _render_watch_it_work(data.latest_demo_iter)
    minutes = data.wall_time_seconds // 60
    pass_count = sum(
        1 for j in data.journeys if j["status"] in ("passing", "already_passing")
    )
    hero = (
        f"<section class='hero pass'>"
        f"<div class='badge-row'><div class='badge pass'>{SVG_CHECK}<span>GOAL ACHIEVED</span></div></div>"
        f"<h1>{escape(data.goal_title or 'Goal session ' + data.session_id)}</h1>"
        f"<h2>Session <code>{escape(data.session_id)}</code></h2>"
        f"<div class='meta'>{data.total_iterations} iterations · "
        f"{pass_count}/{len(data.journeys)} journeys delivered · "
        f"{minutes} min wall time</div>"
        f"</section>"
    )
    back_link = (
        f"<aside class='delivered-back'>"
        f"<a href='goal-session-{escape(data.session_id)}-index.html'>← Back to session index</a>"
        f"</aside>"
    )
    parts = [
        "<!doctype html>",
        '<html lang="en"><head>',
        '<meta charset="utf-8">',
        f"<title>Delivered — {escape(data.goal_title or data.session_id)}</title>",
        f"<style>{CSS}</style>",
        "</head><body><div class='container'>",
        hero,
        back_link,
        "<section class='delivered-body'>",
        body_html,
        "</section>",
        gallery_html,
        f"<div class='footer-note'>Generated {escape(_dt.datetime.now().strftime('%Y-%m-%d %H:%M'))} "
        "by <code>render_iteration_summary.py</code></div>",
        "</div></body></html>",
    ]
    return "\n".join(p for p in parts if p)


# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────


def _walk_up_for_marker(start: Path, max_levels: int = 8) -> Optional[Path]:
    """Walk up from `start` (inclusive) looking for any `_PROJECT_MARKERS`.

    Returns the first ancestor (or start itself) that contains a marker,
    or None if none found within `max_levels` levels.
    """
    cur = start
    for _ in range(max_levels + 1):
        for marker in _PROJECT_MARKERS:
            if (cur / marker).exists():
                return cur
        if cur.parent == cur:
            break
        cur = cur.parent
    return None


def _resolve_repo_root(extra: list[str]) -> Path:
    """Determine the project root, in priority order:

    1. `--repo-root=PATH` CLI arg (highest — what the shell wrappers pass).
    2. `CHAIN_REPO_ROOT` environment variable.
    3. Walk up from CWD looking for `_PROJECT_MARKERS`.
    4. Walk up from this file's location looking for the same markers.
    5. Fall back to `Path(__file__).parents[3]` (works when harness IS the
       project root).

    An empty value in (1) or (2) is treated as "fall through to next" so
    callers that set `--repo-root=""` from an unset shell var still work.
    """
    for arg in extra:
        if arg.startswith("--repo-root="):
            value = arg.split("=", 1)[1].strip()
            if value:
                return Path(value).resolve()

    env_val = os.environ.get("CHAIN_REPO_ROOT", "").strip()
    if env_val:
        return Path(env_val).resolve()

    cwd_found = _walk_up_for_marker(Path.cwd().resolve())
    if cwd_found is not None:
        return cwd_found

    file_found = _walk_up_for_marker(Path(__file__).resolve().parent)
    if file_found is not None:
        return file_found

    return _FALLBACK_REPO_ROOT


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
    print(f"[render-summary] Wrote {out} ({out.stat().st_size // 1024} KB)")
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
    print(f"[render-summary] Wrote {out} ({out.stat().st_size // 1024} KB)")
    return 0


def cmd_delivered(args: list[str]) -> int:
    if not args:
        print("Usage: render_iteration_summary.py delivered <session-id>", file=sys.stderr)
        return 2
    session_id = args[0]
    repo_root = _resolve_repo_root(args[1:])
    delivered_md_path = repo_root / "reports" / f"goal-session-{session_id}-delivered.md"
    if not delivered_md_path.exists():
        print(
            f"[render-summary] Delivered source not found: {delivered_md_path} — skipping.",
            file=sys.stderr,
        )
        return 0
    delivered_md = delivered_md_path.read_text(encoding="utf-8")
    data = load_session(session_id, repo_root)
    html = render_html_delivered(data, delivered_md)
    out = delivered_output_path(session_id, repo_root)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(html, encoding="utf-8")
    print(f"[render-summary] Wrote {out} ({out.stat().st_size // 1024} KB)")
    return 0


# ─────────────────────────────────────────────────────────────────────────────
# Self-test
# ─────────────────────────────────────────────────────────────────────────────


_FIXTURE_SUMMARY_FULL = """# Iteration Summary — phase-7

**Verdict:** PASS
**Iteration type:** phase
**Date:** 2026-05-12

## In plain words

**What you can do now:** Sign in with your email and password, and edit your profile bio.

**What changed this time:** You can now open your profile and write a short bio about yourself.

**What's next:** Next we'll let you add a profile photo.

## Headline

Added user profile page with bio editing.

## Direction

**Signal:** n/a
**Why:** Phase mode iteration — no goal-evaluator context, but closure check passed.

## What was done

- Added /profile route with bio editing form
- Wired POST /api/v1/profile endpoint
- Added regression tests for the new endpoint

## What's left

- Profile photo upload is deferred to next phase
- Internationalisation pending

## Next step

Begin phase-8 for profile photo upload.

## Quick verify

From `reports/phase-7-what-to-click.md`:

1. Open http://localhost:3000 in your browser
2. Click "My Profile" in the header menu
3. Click "Edit bio", type a value, click Save

## Artifacts

| Report | Verdict | Path |
|--------|---------|------|
| Dev handoff | — | docs/handoffs/phase-7-dev.md |
| Review | PASS | reports/reviews/phase-7-review.md |
| Closure | CLOSURE-PASS | reports/phase-7-closure-verdict.md |
"""

_FIXTURE_SUMMARY_GOAL = """# Iteration Summary — goal-money-first-iter-18

**Verdict:** CONTINUE
**Iteration type:** goal-lean
**Date:** 2026-05-12
**Iteration:** 18

## In plain words

**What you can do now:** Sign in with email and view your account. Browse products.

**What changed this time:** You can now sign in with your email and password.

**What's next:** Next we'll let you check out with a payment method.

## Headline

J-04 login flow now passes browser QA.

## Direction

**Signal:** improving
**Why:** Newly passing J-04 this iter; no regressions; last three iters all moved a journey forward.

**Trend (last 5 iters):**
- Newly passing this iter: J-04
- Newly passing in last 5 iters total: J-02, J-03, J-04
- Regressions in last 5 iters: none
- Anti-goal violations in last 5 iters: none
- Iters with no journey state change: 1 of last 5

**Latest evaluator reasoning:** J-04 verified via browser QA. The next obvious target is J-06 (checkout), which is the only remaining failing journey.

## What was done

- Implemented login form with email + password fields
- Verified 1 target journey (J-04) passes browser QA

## What's left

- Journey J-06 (checkout) failing
- Journey J-07 (refund) still untested

## Next step

Target J-06 next iteration. Dispatch as lean if straightforward, else escalate to full.

## Artifacts

| Report | Verdict | Path |
|--------|---------|------|
| Iter spec | — | docs/phases/goal-money-first-iter-18.md |
| Dev handoff | — | docs/handoffs/goal-money-first-iter-18-dev.md |
| Review | PASS | reports/reviews/goal-money-first-iter-18-review.md |
| Browser QA | PASS | reports/phase-goal-money-first-iter-18-ui-test-results.md |
| Goal evaluation | CONTINUE | runs/goal-session-money-first/iter-18/eval.md |
"""

_FIXTURE_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
)


def _write_summary_fixture(tmp: Path, phase_id: str, body: str, *, with_screenshots: bool = True) -> None:
    (tmp / "reports").mkdir(parents=True, exist_ok=True)
    (tmp / "reports" / f"phase-{phase_id}-iteration-summary.md").write_text(body)
    if with_screenshots:
        ev = tmp / "reports" / "qa" / f"{phase_id}-evidence"
        ev.mkdir(parents=True, exist_ok=True)
        for name in ("UT-01.png", "UT-02.png", "UT-03.png"):
            (ev / name).write_bytes(_FIXTURE_PNG)
        results = (
            f"**Browser QA Verdict:** PASS\n\n"
            f"| ID | Evidence |\n|---|---|\n"
            f"| UT-01 | reports/qa/{phase_id}-evidence/UT-01.png |\n"
            f"| UT-02 | reports/qa/{phase_id}-evidence/UT-02.png |\n"
            f"| UT-03 | reports/qa/{phase_id}-evidence/UT-03.png |\n"
        )
        (tmp / "reports" / f"phase-{phase_id}-ui-test-results.md").write_text(results)


def _write_demo_fixture(
    tmp: Path,
    phase_id: str,
    *,
    verdict: str = "RECORDED",
    steps: Optional[list[dict]] = None,
    soft_notes: Optional[list[str]] = None,
) -> None:
    """Write a demo-results.md + demo-script.md + step screenshots fixture."""
    steps = steps if steps is not None else [
        {"num": 1, "title": "Open sign-in", "is_new": True,
         "narration": "Open the app and click Sign in."},
        {"num": 2, "title": "Submit credentials", "is_new": False,
         "narration": "Enter your email and password."},
    ]
    (tmp / "reports").mkdir(parents=True, exist_ok=True)
    demo_dir = tmp / "reports" / "demo" / phase_id
    demo_dir.mkdir(parents=True, exist_ok=True)
    rows: list[str] = ["| Step | Title | New | Screenshot |", "|------|-------|-----|------------|"]
    script_blocks: list[str] = ["# Demo Script — " + phase_id, ""]
    for step in steps:
        n = step["num"]
        shot_rel = f"reports/demo/{phase_id}/step-{n:02d}.png"
        (tmp / shot_rel).write_bytes(_FIXTURE_PNG)
        new_cell = "yes" if step["is_new"] else ""
        rows.append(f"| {n:02d} | {step['title']} | {new_cell} | {shot_rel} |")
        new_tag = "  [NEW]" if step["is_new"] else ""
        script_blocks.append(f"### Step {n:02d} — {step['title']}{new_tag}")
        script_blocks.append(f"- **Narration:** {step['narration']}")
        script_blocks.append("- **Action:** click")
        script_blocks.append("- **Point out:** ...")
        script_blocks.append(f"- **Screenshot:** {shot_rel}")
        script_blocks.append("")
    notes_block = ""
    if soft_notes:
        notes_block = "\n## Soft notes\n\n" + "\n".join(f"- {n}" for n in soft_notes) + "\n"
    (tmp / "reports" / f"phase-{phase_id}-demo-results.md").write_text(
        f"# Demo Results — {phase_id}\n\n"
        f"**Demo Verdict:** {verdict}\n\n"
        f"## Captured Steps\n\n" + "\n".join(rows) + "\n" + notes_block
    )
    (tmp / "reports" / f"phase-{phase_id}-demo-script.md").write_text(
        "\n".join(script_blocks) + "\n"
    )


def _cmd_self_test(_argv: list[str]) -> int:
    """Built-in self-test covering parsers, rendering, and repo-root resolution."""
    import tempfile
    failures: list[str] = []

    # Repo-root resolution priority tests
    with tempfile.TemporaryDirectory() as raw_tmp:
        tmp = Path(raw_tmp).resolve()
        # Nested-harness layout: docs/goal.md lives in tmp/project, harness in
        # tmp/project/incredible_auto_dev/. CWD-walk should find the outer dir.
        (tmp / "project" / "docs").mkdir(parents=True)
        (tmp / "project" / "docs" / "goal.md").write_text("# Test goal\n")
        (tmp / "project" / "incredible_auto_dev" / "scripts" / "automation" / "lib").mkdir(parents=True)
        original_cwd = os.getcwd()
        try:
            # Case 1: --repo-root takes priority over everything
            r = _resolve_repo_root([f"--repo-root={tmp / 'project'}"])
            if r != (tmp / "project").resolve():
                failures.append(f"resolve: --repo-root flag should win, got {r}")

            # Case 2: empty --repo-root falls through (does not return empty path)
            os.chdir(tmp / "project")
            r = _resolve_repo_root(["--repo-root="])
            if r != (tmp / "project").resolve():
                failures.append(f"resolve: empty --repo-root should fall through to CWD walk, got {r}")

            # Case 3: CHAIN_REPO_ROOT env var when no --repo-root
            os.environ["CHAIN_REPO_ROOT"] = str(tmp / "project")
            try:
                os.chdir(raw_tmp)  # no marker here, force env var to win
                r = _resolve_repo_root([])
                if r != (tmp / "project").resolve():
                    failures.append(f"resolve: env var should win, got {r}")
            finally:
                del os.environ["CHAIN_REPO_ROOT"]

            # Case 4: CWD walk finds outer project even when CWD is inside harness
            os.chdir(tmp / "project" / "incredible_auto_dev")
            r = _resolve_repo_root([])
            if r != (tmp / "project").resolve():
                failures.append(f"resolve: CWD walk from harness subdir should find outer project, got {r}")

            # Case 5: outside any project — falls back to fallback constant
            os.chdir(raw_tmp)
            r = _resolve_repo_root([])
            # Should be _FALLBACK_REPO_ROOT (the harness checkout we run from)
            if r != _FALLBACK_REPO_ROOT:
                # _walk_up_for_marker on __file__ may find the harness root,
                # which is also acceptable. So allow either.
                file_walk = _walk_up_for_marker(Path(__file__).resolve().parent)
                if r != file_walk:
                    failures.append(f"resolve: outside project should fall back to file-walk or constant, got {r}")
        finally:
            os.chdir(original_cwd)

    # Parser tests
    header = _parse_summary_header(_FIXTURE_SUMMARY_GOAL)
    if header.get("Verdict") != "CONTINUE":
        failures.append(f"_parse_summary_header: verdict expected CONTINUE, got {header}")
    if header.get("Iteration type") != "goal-lean":
        failures.append(f"_parse_summary_header: type expected goal-lean, got {header}")

    sections = _split_h2_sections(_FIXTURE_SUMMARY_GOAL)
    if "Direction" not in sections:
        failures.append("split_h2: Direction section missing")
    if "In plain words" not in sections:
        failures.append("split_h2: 'In plain words' section missing")
    signal, why = _parse_direction_signal(sections.get("Direction", ""))
    if signal != "improving":
        failures.append(f"signal: expected improving, got {signal}")
    if "Newly passing J-04" not in why and "J-04" not in why:
        failures.append(f"why: expected to mention J-04, got: {why}")

    pw = _parse_plain_words(sections.get("In plain words", ""))
    if "Sign in" not in pw["What you can do now"]:
        failures.append(f"plain words 'what you can do now' missing expected text: {pw}")
    if "sign in" not in pw["What changed this time"].lower():
        failures.append(f"plain words 'what changed this time' missing expected text: {pw}")
    if "check out" not in pw["What's next"].lower():
        failures.append(f"plain words 'what's next' missing expected text: {pw}")
    # Verdict line is still parseable above the new section.
    if header.get("Verdict") != "CONTINUE":
        failures.append("plain words insertion broke header verdict parsing")

    trend = _parse_trend_block(sections.get("Direction", ""))
    if not trend or len(trend) < 5:
        failures.append(f"trend: expected 5 bullets, got {len(trend) if trend else 0}")

    bullets = _extract_bullets(sections.get("What was done", ""))
    if len(bullets) != 2:
        failures.append(f"what was done: expected 2 bullets, got {len(bullets)}")

    steps = _extract_numbered_steps(sections.get("Quick verify", ""))
    # Goal fixture has no Quick verify; phase fixture does
    if steps:
        failures.append(f"goal fixture should have no Quick verify steps, got {steps}")

    header_p, rows = _parse_md_table(sections.get("Artifacts", ""))
    if len(rows) != 5:
        failures.append(f"artifacts table: expected 5 rows, got {len(rows)}")

    # Parse demo-results directly — verdict + table parsing.
    _demo_md = (
        "# Demo Results — phase-1\n\n"
        "**Demo Verdict:** RECORDED_WITH_NOTES\n\n"
        "## Captured Steps\n\n"
        "| Step | Title | New | Screenshot |\n"
        "|------|-------|-----|------------|\n"
        "| 01   | Open app | yes | reports/demo/phase-1/step-01.png |\n"
        "| 02   | Sign in  |     | reports/demo/phase-1/step-02.png |\n\n"
        "## Soft notes\n\n- Step 2 expected toast did not appear.\n"
    )
    dv, dsteps, dnotes = _parse_demo_results(_demo_md)
    if dv != "RECORDED_WITH_NOTES":
        failures.append(f"_parse_demo_results: verdict {dv}")
    if len(dsteps) != 2:
        failures.append(f"_parse_demo_results: steps {len(dsteps)}")
    elif not dsteps[0]["is_new"] or dsteps[1]["is_new"]:
        failures.append(f"_parse_demo_results: NEW flags wrong: {dsteps}")
    if len(dnotes) != 1:
        failures.append(f"_parse_demo_results: notes {len(dnotes)}")

    # Parse narrations from a demo-script.md body.
    _demo_script = (
        "# Demo Script — phase-1\n\n"
        "### Step 01 — Open app  [NEW]\n"
        "- **Narration:** Open the home page and look for the Sign in button.\n"
        "- **Action:** Navigate http://localhost\n\n"
        "### Step 02 — Sign in\n"
        "- **Narration:** Type your email and password.\n"
        "- **Action:** Click Submit\n"
    )
    narr = _parse_demo_script_narrations(_demo_script)
    if narr.get(1, "") != "Open the home page and look for the Sign in button.":
        failures.append(f"_parse_demo_script_narrations: step 1 missing: {narr}")
    if narr.get(2, "") != "Type your email and password.":
        failures.append(f"_parse_demo_script_narrations: step 2 missing: {narr}")

    # End-to-end render — goal-mode iter with screenshots
    with tempfile.TemporaryDirectory() as raw_tmp:
        tmp = Path(raw_tmp)
        _write_summary_fixture(tmp, "goal-money-first-iter-18", _FIXTURE_SUMMARY_GOAL)
        _write_demo_fixture(
            tmp, "goal-money-first-iter-18",
            verdict="RECORDED",
            steps=[
                {"num": 1, "title": "Open sign-in", "is_new": True,
                 "narration": "Open the app and click Sign in."},
                {"num": 2, "title": "Submit credentials", "is_new": False,
                 "narration": "Enter your email and password."},
            ],
        )
        # Session journey-history
        sd = tmp / "runs" / "goal-session-money-first" / "state"
        sd.mkdir(parents=True, exist_ok=True)
        (sd / "journey-history.json").write_text(json.dumps({
            "journeys": {
                "J-04": {"id": "J-04", "name": "Login", "status": "passing",
                          "last_verified_iter": "goal-money-first-iter-18",
                          "last_passing_iter": "goal-money-first-iter-18"},
                "J-06": {"id": "J-06", "name": "Checkout", "status": "failing",
                          "last_verified_iter": "goal-money-first-iter-18"},
            }
        }))
        data = load_iteration("goal-money-first-iter-18", tmp)
        if data.verdict != "CONTINUE":
            failures.append(f"load_iteration: verdict {data.verdict}")
        if data.iter_type != "goal-lean":
            failures.append(f"load_iteration: iter_type {data.iter_type}")
        if data.iter_num != 18:
            failures.append(f"load_iteration: iter_num {data.iter_num}")
        if len(data.journeys) != 2:
            failures.append(f"journeys count {len(data.journeys)}")
        if len(data.screenshots) != 3:
            failures.append(f"screenshots count {len(data.screenshots)}")
        html = render_html_iteration(data)
        if data.demo_verdict != "RECORDED":
            failures.append(f"load_iteration: demo_verdict {data.demo_verdict}")
        if len(data.demo_steps) != 2:
            failures.append(f"load_iteration: demo_steps count {len(data.demo_steps)}")
        elif data.demo_steps[0].get("narration") != "Open the app and click Sign in.":
            failures.append(
                f"load_iteration: demo narration not attached: {data.demo_steps[0]}"
            )
        for expect in (
            "CONTINUE",
            "Direction: improving",
            "J-04 · passing",
            "What was done",
            "Direction signal",
            "Latest evaluator reasoning",
            "data:image/png;base64,",
            # Plain-words layer — leads the body and is prominent.
            "class='plain-words'",
            "In plain words",
            "Sign in with email",
            "Technical detail below",
            # Watch-it-work gallery — present, with NEW badge and narration.
            "class='watch-it-work'",
            "Watch it work",
            "demo-recorded",
            ">NEW<",
            "Open sign-in",
            "Enter your email and password.",
        ):
            if expect not in html:
                failures.append(f"goal render missing: {expect}")
        if 'src="http' in html:
            failures.append("goal render contains remote refs")
        # The technical accordions must all be collapsed by default — no
        # `<details open>` should appear anywhere in the body.
        if "<details open>" in html:
            failures.append("goal render leaves a technical accordion open by default")
        # The plain-words section must render BEFORE any technical accordion.
        pw_pos = html.find("class='plain-words'")
        first_details = html.find("<details")
        if pw_pos < 0 or first_details < 0 or pw_pos > first_details:
            failures.append(
                "goal render: plain-words section must come before first <details>"
            )

        # Phase-mode iter (no goal context)
        _write_summary_fixture(tmp, "phase-7", _FIXTURE_SUMMARY_FULL, with_screenshots=False)
        data_p = load_iteration("phase-7", tmp)
        if data_p.verdict != "PASS":
            failures.append(f"phase verdict {data_p.verdict}")
        if data_p.iter_type != "phase":
            failures.append(f"phase iter_type {data_p.iter_type}")
        html_p = render_html_iteration(data_p)
        for expect in (
            "PASS",
            "Added user profile page",
            "Quick verify",
            "class='plain-words'",
            "edit your profile bio",
        ):
            if expect not in html_p:
                failures.append(f"phase render missing: {expect}")
        if "Direction: " in html_p:
            failures.append("phase render should hide direction badge (n/a)")
        if "<details open>" in html_p:
            failures.append("phase render leaves a technical accordion open by default")

        # Missing-summary fallback
        empty_data = load_iteration("missing-phase", tmp)
        if empty_data.summary_md is not None:
            failures.append("missing-phase: summary_md should be None")
        html_e = render_html_iteration(empty_data)
        if "No iteration summary available" not in html_e:
            failures.append("missing-phase: expected placeholder text")
        # Hero still renders
        if "missing-phase" not in html_e:
            failures.append("missing-phase: hero should show phase id")

        # Session index — 2 iters
        _write_summary_fixture(tmp, "goal-demo-iter-0", _FIXTURE_SUMMARY_GOAL.replace("iter-18", "iter-0").replace("18", "0"), with_screenshots=False)
        _write_summary_fixture(tmp, "goal-demo-iter-1", _FIXTURE_SUMMARY_GOAL.replace("iter-18", "iter-1").replace("18", "1"), with_screenshots=False)
        demo_dir = tmp / "runs" / "goal-session-demo"
        (demo_dir / "state").mkdir(parents=True, exist_ok=True)
        (demo_dir / "session.json").write_text(json.dumps({
            "status": "IN-PROGRESS", "total_iterations": 2, "wall_time_seconds": 1200,
            "started_at": "2026-05-12T10:00:00Z", "finished_at": "",
        }))
        (demo_dir / "state" / "journey-history.json").write_text(json.dumps({
            "journeys": {"J-04": {"id": "J-04", "name": "Login", "status": "passing",
                                    "last_verified_iter": "goal-demo-iter-1",
                                    "last_passing_iter": "goal-demo-iter-1"}}
        }))
        # Also create iter dirs so load_session discovers them
        (tmp / "runs" / "goal-demo-iter-0").mkdir(parents=True, exist_ok=True)
        (tmp / "runs" / "goal-demo-iter-1").mkdir(parents=True, exist_ok=True)
        (tmp / "docs").mkdir(exist_ok=True)
        (tmp / "docs" / "goal.md").write_text("# Build the money app\n")
        # Write a project-story.md so the session index leads with the
        # cumulative narrative.
        (demo_dir / "state" / "project-story.md").write_text(
            "# Project story so far\n\n"
            "A small money app that lets users sign in and view their account.\n\n"
            "## How it has grown\n\n"
            "Started with login, then added the account page. Sign-in passes browser checks.\n\n"
            "## What it can do today\n\n"
            "The product lets users sign in and view their account.\n\n"
            "_Last updated: 2026-05-12 after iteration 1._\n"
        )
        # Give iter-1 a demo fixture so the session index can embed the latest
        # gallery.
        _write_demo_fixture(
            tmp, "goal-demo-iter-1",
            verdict="RECORDED",
            steps=[
                {"num": 1, "title": "Open sign-in", "is_new": True,
                 "narration": "Open the home page."},
                {"num": 2, "title": "Submit credentials", "is_new": False,
                 "narration": "Sign in and land on the account page."},
            ],
        )
        sess = load_session("demo", tmp)
        if len(sess.iterations) != 2:
            failures.append(f"session iterations: {len(sess.iterations)}")
        if not sess.project_story_md:
            failures.append("session: project_story_md not loaded")
        if sess.latest_demo_iter is None or sess.latest_demo_iter.phase_id != "goal-demo-iter-1":
            failures.append(
                f"session: latest_demo_iter expected goal-demo-iter-1, got "
                f"{sess.latest_demo_iter.phase_id if sess.latest_demo_iter else None}"
            )
        idx_html = render_html_session_index(sess)
        if idx_html.count("class='iter-card'") != 2:
            failures.append(f"session cards: {idx_html.count('iter-card')}")
        if "phase-goal-demo-iter-0-summary.html" not in idx_html:
            failures.append("session: cross-iter href should target reports/ flat name")
        if "Build the money app" not in idx_html:
            failures.append("session: title missing")
        for expect in (
            "class='story-so-far'",
            "The story so far",
            "How it has grown",
            "class='session-demo'",
            "Latest walkthrough",
            "Open sign-in",
            "Open the home page.",
            "Journey-by-journey progress",
        ):
            if expect not in idx_html:
                failures.append(f"session index missing: {expect}")
        # 'The story so far' section must come before the journey matrix.
        story_pos = idx_html.find("class='story-so-far'")
        matrix_pos = idx_html.find("class='matrix'")
        if story_pos < 0 or matrix_pos < 0 or story_pos > matrix_pos:
            failures.append("session index: story section must come before matrix")

        # Delivered wrap fixture — drop a delivered.md and exercise the new
        # `delivered` command + the session-index 'delivered-link' banner.
        delivered_md = (
            "# Delivered — Build the money app\n\n"
            "**Session:** demo\n**Date:** 2026-05-12\n**Final verdict:** GOAL_ACHIEVED\n"
            "**Iterations:** 2\n\n"
            "## What you can do today\n\n"
            "Sign in with email. View account.\n\n"
            "## How it came together\n\n"
            "First we built sign-in. Then the account page.\n"
        )
        (tmp / "reports" / "goal-session-demo-delivered.md").write_text(delivered_md)
        rc = cmd_delivered(["demo", f"--repo-root={tmp}"])
        if rc != 0:
            failures.append(f"cmd_delivered exit {rc}")
        d_out = delivered_output_path("demo", tmp)
        if not d_out.exists():
            failures.append(f"delivered HTML not written at {d_out}")
        else:
            d_html = d_out.read_text(encoding="utf-8")
            for expect in (
                "GOAL ACHIEVED",
                "Build the money app",
                "class='delivered-body'",
                "What you can do today",
                "How it came together",
                "class='watch-it-work'",  # latest demo gallery embedded
                "goal-session-demo-index.html",  # back link
            ):
                if expect not in d_html:
                    failures.append(f"delivered HTML missing: {expect}")
        # Re-render session index — now it should surface the delivered link.
        sess2 = load_session("demo", tmp)
        if not sess2.delivered_md_exists:
            failures.append("session: delivered_md_exists should be true after writing")
        idx_html2 = render_html_session_index(sess2)
        if "class='delivered-link'" not in idx_html2:
            failures.append("session index: delivered-link banner missing after GOAL_ACHIEVED")
        if "goal-session-demo-delivered.html" not in idx_html2:
            failures.append("session index: delivered href missing")

        # Output path correctness
        ip = iteration_output_path("phase-7", tmp)
        if not str(ip).endswith("/reports/phase-phase-7-summary.html"):
            failures.append(f"iteration_output_path: unexpected {ip}")
        sp = session_index_output_path("demo", tmp)
        if not str(sp).endswith("/reports/goal-session-demo-index.html"):
            failures.append(f"session_index_output_path: unexpected {sp}")
        dp = delivered_output_path("demo", tmp)
        if not str(dp).endswith("/reports/goal-session-demo-delivered.html"):
            failures.append(f"delivered_output_path: unexpected {dp}")

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
    "delivered": cmd_delivered,
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
