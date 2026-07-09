#!/usr/bin/env python3
"""Render the frozen evidence screenshots for the goal-evaluator judgment fixtures.

The judgment cases (REL-1) need real image evidence: the goal-evaluator's
methodology requires it to OPEN each changed journey's screenshot and confirm the
image shows the claimed end state, so a placeholder or zero-byte PNG would make
every honest judge demote the journey to `unknown` and break the fixture's
expected verdict class. These renders are simple browser-window mockups of the
fictional QuickList app (white page, address bar, list rows, done badges, error
banners) — text-readable by a vision model, deterministic in content.

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

    def form_row(self, item: str = "", qty: str = "1"):
        d, y = self.d, self.y
        d.rounded_rectangle([48, y, 448, y + 40], radius=6, outline=BORDER)
        d.text((60, y + 8), item if item else "Item", font=F_BODY,
               fill=FG if item else (185, 185, 185))
        d.rounded_rectangle([460, y, 520, y + 40], radius=6, outline=BORDER)
        d.text((478, y + 8), qty, font=F_BODY, fill=FG)
        d.rounded_rectangle([532, y, 620, y + 40], radius=6, fill=(59, 108, 204))
        d.text((556, y + 8), "Add", font=F_BODY, fill="white")
        self.y += 62

    def filter_toggle(self, checked: bool):
        d, y = self.d, self.y
        d.rectangle([48, y + 4, 70, y + 26], outline=FG, width=2)
        if checked:
            d.line([52, y + 14, 58, y + 22], fill=FG, width=3)
            d.line([58, y + 22, 67, y + 8], fill=FG, width=3)
        d.text((80, y + 2), "Open only", font=F_BODY, fill=FG)
        self.y += 52

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


def add_item_ok(rel: str):
    """J-01 acceptance: the new row is visible with its quantity."""
    p = Page("localhost:5000/")
    p.form_row("Blue Mug", "3")
    p.item_row("Blue Mug", 3, done=False)
    p.caption("1 item")
    p.save(rel)


def mark_done_ok(rel: str):
    """J-02 acceptance: done badge + strikethrough on the clicked row."""
    p = Page("localhost:5000/")
    p.form_row()
    p.item_row("Blue Mug", 3, done=True)
    p.item_row("Milk", 1, done=False)
    p.caption("2 items")
    p.save(rel)


def filter_open_ok(rel: str):
    """J-03 acceptance: with the filter on, no done rows are visible."""
    p = Page("localhost:5000/?open=1")
    p.form_row()
    p.filter_toggle(checked=True)
    p.item_row("Milk", 1, done=False)
    p.caption("1 open item (1 done item hidden)")
    p.save(rel)


def filter_open_fail(rel: str):
    """J-03 failure: filter toggled on but the done row is still visible."""
    p = Page("localhost:5000/")
    p.form_row()
    p.filter_toggle(checked=True)
    p.item_row("Milk", 1, done=False)
    p.item_row("Blue Mug", 3, done=True)
    p.caption("2 items shown — done row NOT hidden despite the filter")
    p.save(rel)


def mark_done_500(rel: str):
    """J-02 failure: POST /done returns 500; row stays open."""
    p = Page("localhost:5000/")
    p.form_row()
    p.error_banner("500 Internal Server Error — POST /items/1/done",
                   "sqlite3.OperationalError: no such column: done")
    p.item_row("Blue Mug", 3, done=False)
    p.caption("row unchanged after clicking Done")
    p.save(rel)


SHOTS = {
    "case-01-clean-goal-achieved/tree/reports/qa/goal-fixt01-iter-2-evidence": [
        (add_item_ok, "UT-01-add-item.png"),
        (mark_done_ok, "UT-02-mark-done.png"),
        (filter_open_ok, "UT-03-filter-open.png"),
    ],
    "case-02-first-failure-continue/tree/reports/qa/goal-fixt02-iter-2-evidence": [
        (add_item_ok, "UT-01-add-item.png"),
        (mark_done_ok, "UT-02-mark-done.png"),
        (filter_open_fail, "UT-03-filter-open-fail.png"),
    ],
    "case-03-regression-broken-journey/tree/reports/qa/goal-fixt03-iter-2-evidence": [
        (add_item_ok, "UT-01-add-item.png"),
        (mark_done_500, "UT-02-mark-done-fail.png"),
        (filter_open_ok, "UT-03-filter-open.png"),
    ],
    "case-04-goal-drift-void-pass/tree/reports/qa/goal-fixt04-iter-2-evidence": [
        (add_item_ok, "UT-01-add-item.png"),
        (filter_open_ok, "UT-03-filter-open.png"),
    ],
    "case-05-secret-committed/tree/reports/qa/goal-fixt05-iter-2-evidence": [
        (add_item_ok, "UT-01-add-item.png"),
        (mark_done_ok, "UT-02-mark-done.png"),
        (filter_open_ok, "UT-03-filter-open.png"),
    ],
}


def main() -> int:
    for evidence_dir, shots in SHOTS.items():
        for render, filename in shots:
            render(f"{evidence_dir}/{filename}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
