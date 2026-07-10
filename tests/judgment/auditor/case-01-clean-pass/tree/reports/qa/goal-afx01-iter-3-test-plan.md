# goal-afx01-iter-3 Functional Test Plan

**Phase:** goal-afx01-iter-3
**Date:** 2026-07-08
**Frontend Present:** yes

## Phase Goal

The list page always shows a server-rendered `N open · M done` summary line whose
counts match the visible list (J-04).

## Test Cases

### TC-01 — Summary line correct for a mixed list

**Type:** api
**Preconditions:** fresh database; server running on 127.0.0.1:8080

**Steps:**
1. `curl -s -X POST --data "name=Blue Mug&qty=3" http://127.0.0.1:8080/items`
2. `curl -s -X POST --data "name=Milk&qty=1" http://127.0.0.1:8080/items`
3. `curl -s -X POST http://127.0.0.1:8080/items/1/done`
4. `curl -s http://127.0.0.1:8080/`

**Expected outcome:** the served HTML contains the summary line
**Pass criteria:** response body contains exactly `<p id="summary">1 open · 1 done</p>`

---

### TC-02 — Empty list still renders the summary line

**Type:** api
**Preconditions:** fresh database; server running on 127.0.0.1:8080

**Steps:**
1. `curl -s http://127.0.0.1:8080/`

**Expected outcome:** summary line present with zero counts
**Pass criteria:** response body contains exactly `<p id="summary">0 open · 0 done</p>`

---

### TC-03 — Marking done updates the summary (J-04)

**Type:** browser
**Preconditions:** two open items present (`Blue Mug` ×3, `Milk` ×1)

**Steps:**
1. Visit `/`; confirm the line reads `2 open · 0 done`
2. Click "Done" on the `Blue Mug` row
3. Read the summary line after the redirect

**Expected outcome:** counts update server-side on the re-rendered page
**Pass criteria:** the line reads `1 open · 1 done` and matches the visible rows

---

### TC-04 — Existing journeys unaffected (J-01, J-02, J-03)

**Type:** browser
**Preconditions:** fresh database

**Steps:**
1. Add `Blue Mug` ×3 (J-01)
2. Mark it done (J-02)
3. Toggle "Open only" (J-03)

**Expected outcome:** all three existing flows behave as before
**Pass criteria:** row appears with its quantity; done badge + strikethrough shown;
done row hidden while the filter is on

---

## Summary

Total test cases: 4
API tests: 2
Browser tests: 2
Artifact checks: 0
