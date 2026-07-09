# Phase goal-fixt02-iter-2 — UI Test Results

**Phase:** goal-fixt02-iter-2
**Date:** 2026-07-03
**Written by:** browser-qa-agent

---

**Browser QA Verdict:** FAIL

**Overall:** 2/3 tests passed (0 skipped)

---

## Results Table

| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |
|---------|------|------|----------|----------|--------|---------|----------|
| UT-01 | J-01 add an item | journey | P1 | New row shows Blue Mug with qty 3 | Row visible with name and qty 3 | PASS | reports/qa/goal-fixt02-iter-2-evidence/UT-01-add-item.png |
| UT-02 | J-02 mark an item done | journey | P1 | Row shows done badge + strikethrough | Badge and strikethrough rendered | PASS | reports/qa/goal-fixt02-iter-2-evidence/UT-02-mark-done.png |
| UT-03 | J-03 filter to open items | journey | P1 | Done rows hidden when Open only is on | Done row STILL VISIBLE after toggling the filter | FAIL | reports/qa/goal-fixt02-iter-2-evidence/UT-03-filter-open-fail.png |

---

## Passed Tests

### UT-01 — J-01 add an item
**Verdict:** PASS
**Evidence:** `reports/qa/goal-fixt02-iter-2-evidence/UT-01-add-item.png`
- Typed `Blue Mug` / `3`, clicked Add; the new row rendered with the quantity.

### UT-02 — J-02 mark an item done
**Verdict:** PASS
**Evidence:** `reports/qa/goal-fixt02-iter-2-evidence/UT-02-mark-done.png`
- Clicked Done on the Blue Mug row; the row re-rendered struck through with a `done` badge.

---

## Failed Tests

### UT-03 — J-03 filter to open items
**Verdict:** FAIL
**Failure:** Toggling "Open only" did not hide the done row.
**Evidence:** `reports/qa/goal-fixt02-iter-2-evidence/UT-03-filter-open-fail.png`

**Steps taken:**
1. Seeded one done item (Blue Mug ×3) and one open item (Milk ×1).
2. Toggled the "Open only" checkbox on.

**Expected:** Only `Milk ×1` remains visible.
**Actual:** Both rows remained visible — the toggle listener binds before the list
renders, so rows added after page load never get the display rule applied.
