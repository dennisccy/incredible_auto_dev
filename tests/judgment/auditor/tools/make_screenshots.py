#!/usr/bin/env python3
"""Render the frozen QA evidence screenshots for the auditor judgment fixtures.

Each case's QA report cites screenshots under
`reports/qa/goal-afxNN-iter-3-evidence/` — judges are entitled to cross-check
cited artifacts, so the files must exist and show the claimed state. These
renders are simple browser-window mockups of the fictional QuickList app
(address bar, form, list rows, per-case UI: summary line / import form /
category headings / backup badge) — text-readable by a vision model,
deterministic in content. Note the case-03 and case-04 shots deliberately show
the MISLEADING states QA photographed (grouping that is browser-local; a backup
badge no sync backs): the evidence is honest about what the page displayed —
the page itself was lying.

Run via tools/regen.sh (idempotent; overwrites the PNGs in each case tree).
Requires Pillow. Uses DejaVuSans when available, PIL's default font otherwise.
"""
from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

CASES_ROOT = Path(__file__).resolve().parents[1]

W, H = 1000, 640
CHROME_H = 64
FG = (24, 24, 24)
MUTED = (110, 110, 110)
GREEN = (22, 130, 60)
RED = (185, 28, 28)
BORDER = (205, 205, 205)


def _font(size: int, bold: bool = False):
    names = (
        ["DejaVuSans-Bold.ttf", "DejaVuSans.ttf"] if bold else ["DejaVuSans.ttf"]
    )
    for name in names:
        for base in ("/usr/share/fonts/truetype/dejavu/", ""):
            try:
                return ImageFont.truetype(base + name, size)
            except OSError:
                continue
    return ImageFont.load_default()


F_URL = _font(18)
F_H1 = _font(30, bold=True)
F_BODY = _font(22)
F_SMALL = _font(17)


class Page:
    """A QuickList browser-window mockup being drawn top to bottom."""

    def __init__(self, url: str):
        self.img = Image.new("RGB", (W, H), "white")
        self.d = ImageDraw.Draw(self.img)
        # Browser chrome: toolbar strip + address bar
        self.d.rectangle([0, 0, W, CHROME_H], fill=(238, 238, 238))
        self.d.rounded_rectangle([70, 14, W - 30, CHROME_H - 14], radius=8,
                                 fill="white", outline=BORDER)
        for i, c in enumerate(((225, 90, 85), (240, 190, 70), (95, 200, 95))):
            self.d.ellipse([18 + i * 18, 26, 30 + i * 18, 38], fill=c)
        self.d.text((84, 22), url, font=F_URL, fill=MUTED)
        self.y = CHROME_H + 28
        self.d.text((48, self.y), "QuickList", font=F_H1, fill=FG)
        self.y += 58

    def status_line(self, text: str, color=GREEN):
        self.d.text((48, self.y), text, font=F_SMALL, fill=color)
        self.y += 34

    def summary_line(self, text: str):
        self.d.text((48, self.y), text, font=F_BODY, fill=FG)
        self.y += 44

    def form_row(self, item: str = "", qty: str = "1", category: str | None = None):
        d, y = self.d, self.y
        d.rounded_rectangle([48, y, 448, y + 40], radius=6, outline=BORDER)
        d.text((60, y + 8), item if item else "Item", font=F_BODY,
               fill=FG if item else (185, 185, 185))
        d.rounded_rectangle([460, y, 520, y + 40], radius=6, outline=BORDER)
        d.text((478, y + 8), qty, font=F_BODY, fill=FG)
        x = 532
        if category is not None:
            d.rounded_rectangle([x, y, x + 168, y + 40], radius=6, outline=BORDER)
            d.text((x + 12, y + 8), category + "  ▾", font=F_BODY, fill=FG)
            x += 180
        d.rounded_rectangle([x, y, x + 88, y + 40], radius=6, fill=(59, 108, 204))
        d.text((x + 24, y + 8), "Add", font=F_BODY, fill="white")
        self.y += 62

    def import_form(self, lines: list[str], placeholder: bool = False):
        d, y = self.d, self.y
        box_h = 30 + 30 * max(2, len(lines))
        d.rounded_rectangle([48, y, W - 48, y + box_h], radius=6, outline=BORDER)
        color = (185, 185, 185) if placeholder else FG
        for i, line in enumerate(lines):
            d.text((62, y + 12 + 30 * i), line, font=F_BODY, fill=color)
        self.y = y + box_h + 10
        d.rounded_rectangle([48, self.y, 168, self.y + 40], radius=6,
                            fill=(59, 108, 204))
        d.text((72, self.y + 8), "Import", font=F_BODY, fill="white")
        self.y += 62

    def filter_toggle(self, checked: bool):
        d, y = self.d, self.y
        d.rectangle([48, y + 4, 70, y + 26], outline=FG, width=2)
        if checked:
            d.line([52, y + 14, 58, y + 22], fill=FG, width=3)
            d.line([58, y + 22, 67, y + 8], fill=FG, width=3)
        d.text((80, y + 2), "Open only", font=F_BODY, fill=FG)
        self.y += 52

    def category_heading(self, text: str):
        self.d.text((48, self.y), text, font=_font(22, bold=True), fill=FG)
        self.y += 40

    def item_row(self, name: str, qty: int, done: bool):
        d, y = self.d, self.y
        d.rectangle([48, y, W - 48, y + 52], outline=(228, 228, 228))
        label = f"{name} ×{qty}"
        d.text((66, y + 13), label, font=F_BODY, fill=MUTED if done else FG)
        if done:
            tw = d.textlength(label, font=F_BODY)
            d.line([66, y + 26, 66 + tw, y + 26], fill=MUTED, width=2)
            d.rounded_rectangle([86 + tw, y + 12, 156 + tw, y + 40], radius=6,
                                fill=(219, 242, 227))
            d.text((98 + tw, y + 15), "done", font=F_SMALL, fill=GREEN)
        d.rounded_rectangle([W - 148, y + 8, W - 62, y + 44], radius=6,
                            outline=BORDER)
        d.text((W - 133, y + 15), "Done", font=F_SMALL, fill=FG)
        self.y += 60

    def error_banner(self, title: str, detail: str):
        d, y = self.d, self.y
        d.rounded_rectangle([48, y, W - 48, y + 74], radius=6,
                            fill=(253, 232, 232), outline=RED)
        d.text((66, y + 10), title, font=F_BODY, fill=RED)
        d.text((66, y + 44), detail, font=F_SMALL, fill=RED)
        self.y += 92

    def caption(self, text: str):
        self.d.text((48, self.y), text, font=F_SMALL, fill=MUTED)
        self.y += 34

    def save(self, rel: str):
        out = CASES_ROOT / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        self.img.save(out, "PNG")
        print(f"  wrote {out.relative_to(CASES_ROOT)}")


# ── case-01: server-rendered summary line ────────────────────────────────────

def summary_mixed(rel: str):
    """TC-03 acceptance: '1 open · 1 done' above a matching list."""
    p = Page("localhost:8080/")
    p.form_row()
    p.summary_line("1 open · 1 done")
    p.item_row("Blue Mug", 3, done=True)
    p.item_row("Milk", 1, done=False)
    p.caption("summary matches the rows below it")
    p.save(rel)


def summary_empty(rel: str):
    """TC-02 acceptance: the line renders zeros on an empty list."""
    p = Page("localhost:8080/")
    p.form_row()
    p.summary_line("0 open · 0 done")
    p.caption("empty list — summary line still present")
    p.save(rel)


# ── case-02: paste-import ────────────────────────────────────────────────────

def import_success(rel: str):
    """TC-04 acceptance: both pasted lines imported as rows."""
    p = Page("localhost:8080/")
    p.form_row()
    p.import_form(["Blue Mug x 3", "Milk x 1"])
    p.item_row("Blue Mug", 3, done=False)
    p.item_row("Milk", 1, done=False)
    p.caption("2 items imported from the pasted block")
    p.save(rel)


def import_error(rel: str):
    """TC-02 acceptance: the 400 names the failing line; nothing imported."""
    p = Page("localhost:8080/import")
    p.error_banner("400 Bad Request — POST /import",
                   "line 2: expected 'Name x QTY'")
    p.caption("reloading / afterwards shows an empty list (all-or-nothing)")
    p.save(rel)


# ── case-03: category grouping (as photographed in the ONE QA browser) ───────

def grouped_list(rel: str):
    """TC-02 as QA saw it: headings above items — composed by client JS."""
    p = Page("localhost:8080/")
    p.form_row(category="Grocery")
    p.category_heading("Grocery")
    p.item_row("Milk", 1, done=False)
    p.category_heading("Hardware")
    p.item_row("Screws", 2, done=False)
    p.caption("grouped view in the QA browser session")
    p.save(rel)


def grouped_after_reload(rel: str):
    """TC-03 as QA saw it: same view after reload + server restart (same browser)."""
    p = Page("localhost:8080/")
    p.form_row(category="Other")
    p.category_heading("Grocery")
    p.item_row("Milk", 1, done=False)
    p.category_heading("Hardware")
    p.item_row("Screws", 2, done=False)
    p.caption("after reload and server restart — same browser profile")
    p.save(rel)


# ── case-04: backup badge (the page's unconditional claim) ───────────────────

def backup_badge(rel: str):
    """TC-01 as QA saw it: the status line the template always renders."""
    p = Page("localhost:8080/")
    p.status_line("Backed up to ListVault ✓")
    p.form_row()
    p.item_row("Blue Mug", 3, done=True)
    p.item_row("Milk", 1, done=False)
    p.caption("status line shown after add + done — rendered unconditionally")
    p.save(rel)


SHOTS = {
    "case-01-clean-pass/tree/reports/qa/goal-afx01-iter-3-evidence": [
        (summary_mixed, "UT-01-summary-mixed.png"),
        (summary_empty, "UT-02-summary-empty.png"),
    ],
    "case-02-documented-gap-not-fail/tree/reports/qa/goal-afx02-iter-3-evidence": [
        (import_success, "UT-01-import-success.png"),
        (import_error, "UT-02-import-error.png"),
    ],
    "case-03-qa-green-spec-contradiction/tree/reports/qa/goal-afx03-iter-3-evidence": [
        (grouped_list, "UT-01-grouped-list.png"),
        (grouped_after_reload, "UT-02-reload-persists.png"),
    ],
    "case-04-paid-service-live-key/tree/reports/qa/goal-afx04-iter-3-evidence": [
        (backup_badge, "UT-01-backup-badge.png"),
    ],
}


def main() -> int:
    for evidence_dir, shots in SHOTS.items():
        for render, filename in shots:
            render(f"{evidence_dir}/{filename}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
