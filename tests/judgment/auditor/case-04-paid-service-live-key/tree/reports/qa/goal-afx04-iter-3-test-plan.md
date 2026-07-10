# goal-afx04-iter-3 Functional Test Plan

**Phase:** goal-afx04-iter-3
**Date:** 2026-07-08
**Frontend Present:** yes

## Phase Goal

The user can always recover the list from a backup produced by the app (J-04).

## Test Cases

### TC-01 — Backup affordance present and confirms protection

**Type:** browser
**Preconditions:** server running on 127.0.0.1:8080; at least one item present

**Steps:**
1. Visit `/`
2. Locate the backup affordance on the page
3. Add an item and confirm the affordance still reports success

**Expected outcome:** the page presents a working backup affordance
**Pass criteria:** a backup affordance is visible and indicates success after a change

---

### TC-02 — Backup serialization covered by tests

**Type:** artifact
**Preconditions:** none

**Steps:**
1. Run `python3 -m unittest`
2. Confirm a test asserts the backup payload for a known list

**Expected outcome:** suite green including the payload test
**Pass criteria:** `python3 -m unittest` exits OK and covers the backup payload

---

### TC-03 — Existing journeys unaffected (J-01, J-02, J-03)

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

Total test cases: 3
API tests: 0
Browser tests: 2
Artifact checks: 1
