# goal-afx02-iter-3 Functional Test Plan

**Phase:** goal-afx02-iter-3
**Date:** 2026-07-08
**Frontend Present:** yes

## Phase Goal

A pasted plain-text list (`Name x QTY` per line) imports as items in one action,
all-or-nothing, with malformed input rejected server-side naming the failing line
(J-04).

## Test Cases

### TC-01 — Valid two-line paste imports both items

**Type:** api
**Preconditions:** fresh database; server running on 127.0.0.1:8080

**Steps:**
1. `curl -s -X POST --data-urlencode "block=Blue Mug x 3
Milk x 1" http://127.0.0.1:8080/import`
2. `curl -s http://127.0.0.1:8080/`

**Expected outcome:** both items render in the list
**Pass criteria:** response body contains `Blue Mug × 3` and `Milk × 1`

---

### TC-02 — Malformed second line rejected, failing line named

**Type:** api
**Preconditions:** fresh database; server running on 127.0.0.1:8080

**Steps:**
1. `curl -s -i -X POST --data-urlencode "block=Blue Mug x 3
Milk & 1" http://127.0.0.1:8080/import`

**Expected outcome:** the whole block is rejected with the failing line identified
**Pass criteria:** status is `400`; body contains `line 2: expected 'Name x QTY'`

---

### TC-03 — Rejected import inserts nothing (all-or-nothing)

**Type:** api
**Preconditions:** immediately after TC-02 (same fresh database)

**Steps:**
1. `curl -s http://127.0.0.1:8080/`

**Expected outcome:** no partial import happened
**Pass criteria:** neither `Blue Mug` nor `Milk` appears in the list

---

### TC-04 — Paste-import through the browser (J-04)

**Type:** browser
**Preconditions:** fresh database

**Steps:**
1. Visit `/`
2. Paste `Blue Mug x 3` and `Milk x 1` (two lines) into the import box
3. Click "Import"

**Expected outcome:** both items appear in the list after the redirect
**Pass criteria:** rows `Blue Mug × 3` and `Milk × 1` visible

---

### TC-05 — Existing journeys unaffected (J-01, J-02, J-03)

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

Total test cases: 5
API tests: 3
Browser tests: 2
Artifact checks: 0
