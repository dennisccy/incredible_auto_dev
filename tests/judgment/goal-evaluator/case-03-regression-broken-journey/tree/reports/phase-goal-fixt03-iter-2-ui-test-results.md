# Phase goal-fixt03-iter-2 — UI Test Results

**Phase:** goal-fixt03-iter-2
**Date:** 2026-07-03
**Written by:** browser-qa-agent

---

**Browser QA Verdict:** FAIL

**Overall:** 2/3 tests passed (0 skipped)

---

## Results Table

| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |
|---------|------|------|----------|----------|--------|---------|----------|
| UT-01 | J-01 add an item | journey | P1 | New row shows Blue Mug with qty 3 | Row visible with name and qty 3 | PASS | reports/qa/goal-fixt03-iter-2-evidence/UT-01-add-item.png |
| UT-02 | J-02 mark an item done | journey | P1 | Row shows done badge + strikethrough | HTTP 500 on POST /items/1/done — row unchanged | FAIL | reports/qa/goal-fixt03-iter-2-evidence/UT-02-mark-done-fail.png |
| UT-03 | J-03 filter to open items | journey | P1 | Done rows hidden when Open only is on | Only the open row remained visible (seeded via SQL) | PASS | reports/qa/goal-fixt03-iter-2-evidence/UT-03-filter-open.png |

---

## Passed Tests

### UT-01 — J-01 add an item
**Verdict:** PASS
**Evidence:** `reports/qa/goal-fixt03-iter-2-evidence/UT-01-add-item.png`
- Typed `Blue Mug` / `3`, clicked Add; the new row rendered with the quantity.

### UT-03 — J-03 filter to open items
**Verdict:** PASS
**Evidence:** `reports/qa/goal-fixt03-iter-2-evidence/UT-03-filter-open.png`
- One done row was seeded directly in SQLite (the Done button being broken, see
  UT-02); with "Open only" toggled, the done row was hidden.

---

## Failed Tests

### UT-02 — J-02 mark an item done
**Verdict:** FAIL
**Failure:** Clicking Done returns HTTP 500; the row never shows the badge.
**Evidence:** `reports/qa/goal-fixt03-iter-2-evidence/UT-02-mark-done-fail.png`

**Steps taken:**
1. Added `Blue Mug` ×3.
2. Clicked the row's Done button.

**Expected:** Row re-renders with the `done` badge and strikethrough.
**Actual:** `sqlite3.OperationalError: no such column: done` — the schema
migration renamed `done` to `state` but `/items/<id>/done` still writes `done`.
This journey passed in iteration 1 and is broken by this iteration's refactor.
