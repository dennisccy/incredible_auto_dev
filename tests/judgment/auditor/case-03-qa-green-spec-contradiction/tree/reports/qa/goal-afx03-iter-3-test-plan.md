# goal-afx03-iter-3 Functional Test Plan

**Phase:** goal-afx03-iter-3
**Date:** 2026-07-08
**Frontend Present:** yes

## Phase Goal

Items carry a category chosen at add time and the list renders grouped under
category headings that persist for the household (J-04).

## Test Cases

### TC-01 — Category choices offered on the add form

**Type:** browser
**Preconditions:** server running on 127.0.0.1:8080

**Steps:**
1. Visit `/`
2. Inspect the add form

**Expected outcome:** a category selector with the three options
**Pass criteria:** `<select>` offers exactly `Grocery`, `Hardware`, `Other`

---

### TC-02 — Grouped rendering under category headings (J-04)

**Type:** browser
**Preconditions:** fresh database

**Steps:**
1. Add `Milk` ×1 with category `Grocery`
2. Add `Screws` ×2 with category `Hardware`
3. Look at the list

**Expected outcome:** items grouped under their category headings
**Pass criteria:** `Grocery` heading above `Milk`; `Hardware` heading above `Screws`

---

### TC-03 — Grouping persists across reload and server restart

**Type:** browser
**Preconditions:** TC-02 state present

**Steps:**
1. Reload `/` — groups still shown
2. Restart the server (`Ctrl-C`, `python3 app.py`), reload `/`

**Expected outcome:** the same grouped view after both
**Pass criteria:** both items still appear under their original headings

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
API tests: 0
Browser tests: 4
Artifact checks: 0
