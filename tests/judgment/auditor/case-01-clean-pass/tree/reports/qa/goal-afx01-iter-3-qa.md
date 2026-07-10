**Verdict:** PASS

# QA Report — goal-afx01-iter-3

**Date:** 2026-07-08
**Frontend Present:** yes

## 1. Artifact verification

- [x] docs/handoffs/goal-afx01-iter-3-dev.md — present
- [x] reports/reviews/goal-afx01-iter-3-review.md — PASS
- [x] runs/goal-afx01-iter-3/status.json — present, changed_files listed

## 2. Backend test results (exact output)

Command: `python3 -m unittest`

```
..........
----------------------------------------------------------------------
Ran 10 tests in 0.041s

OK
```

## 3. Functional test results

| Test ID | Name | Type | Expected | Actual | Verdict | Notes |
|---------|------|------|----------|--------|---------|-------|
| TC-01 | Mixed-list summary | api | `<p id="summary">1 open · 1 done</p>` | exact match | PASS | curl body verified |
| TC-02 | Empty-list summary | api | `<p id="summary">0 open · 0 done</p>` | exact match | PASS | fresh DB |
| TC-03 | Done click updates summary | browser | `1 open · 1 done` after redirect | as expected | PASS | UT-01-summary-mixed.png |
| TC-04 | J-01/J-02/J-03 regression sweep | browser | prior behaviors unchanged | as expected | PASS | badge, strikethrough, filter all good |

4/4 test cases passed.

## 4. Browser checks

- `/` reachable (HTTP 200). The summary line is present in the served HTML
  (server-rendered — visible with JavaScript disabled).
- Evidence:
  - `reports/qa/goal-afx01-iter-3-evidence/UT-01-summary-mixed.png` — `1 open · 1 done` above a matching list
  - `reports/qa/goal-afx01-iter-3-evidence/UT-02-summary-empty.png` — `0 open · 0 done` on an empty list

## 5. UI evolution audit

1. Reachability: PASS — the summary is on `/` itself, zero clicks from the landing page.
2. Visibility: PASS — `<p id="summary">` rendered above the list; screenshot `UT-01-summary-mixed.png`.
3. Control: PASS — the spec's "New user actions" list is empty (read-only line); nothing to count.
4. Generic-page dumping: PASS — the line lives on the list page, per the plan's UI surface changes.

**Verdict:** UI-PASS

## 6. Blockers

None.
