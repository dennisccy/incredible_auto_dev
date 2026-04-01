# Phase N — UI Test Plan

**Phase:** <phase-id>
**Date:** <YYYY-MM-DD>
**Written by:** ui-test-designer
**Frontend URL:** http://localhost:3000 (or configured CHAIN_FRONTEND_URL)

---

## Test Cases

<!-- Test IDs use UT-XX prefix to distinguish from functional test plan TC-XX IDs. -->
<!-- Each test MUST have exact steps and specific expected results. -->
<!-- Vague steps like "test the form" or "verify it works" are not acceptable. -->

---

### UT-01 — <Page> loads without errors (smoke)

**Type:** smoke
**Priority:** P1
**Surface:** `<route>`

**Preconditions:**
- Frontend is running at http://localhost:3000
- User is <logged in / not logged in>

**Steps:**
1. Navigate to `http://localhost:3000<route>`
2. Wait for page to fully load

**Expected Result:**
- Page renders without blank screen or error message
- The heading "<expected heading text>" is visible
- No console errors

---

### UT-02 — User can <action> successfully (happy path)

**Type:** happy-path
**Priority:** P1
**Surface:** `<route>`

**Preconditions:**
- <Required data or state>

**Steps:**
1. Navigate to `http://localhost:3000<route>`
2. Click the "<exact button text>" button
3. Fill in the "<exact field label>" field with "<test value>"
4. Click the "<exact submit button text>" button

**Expected Result:**
- <Exact outcome, e.g., "Page redirects to /items/1">
- <Exact visible feedback, e.g., "Green toast message 'Item created' appears">
- <Data visible, e.g., "The item 'Test Item' appears in the list">

---

### UT-03 — Form validates required fields (validation)

**Type:** validation
**Priority:** P2
**Surface:** `<form route>`

**Preconditions:**
- Navigate to the form page

**Steps:**
1. Navigate to `http://localhost:3000<form-route>`
2. Click "<submit button text>" without filling any fields

**Expected Result:**
- Form does NOT submit
- Error message "<exact expected error text>" appears below the "<field name>" field
- User remains on the form page

---

### UT-04 — <Existing feature> still works after this phase (regression)

**Type:** regression
**Priority:** P1
**Surface:** `<prior-feature-route>`

**Preconditions:**
- <Required data from prior phase>

**Steps:**
1. Navigate to `http://localhost:3000<prior-feature-route>`
2. <Action that the prior feature supports>

**Expected Result:**
- <Prior feature still works as expected>

---

### UT-05 — New feature is discoverable from navigation (ux)

**Type:** ux
**Priority:** P2
**Surface:** navigation / sidebar

**Steps:**
1. Navigate to `http://localhost:3000` (home/dashboard)
2. Look at the navigation sidebar/menu

**Expected Result:**
- A link or menu item named "<expected label>" is visible in the navigation
- Clicking it navigates to `http://localhost:3000<expected-route>`

---

## Test Summary

| ID | Name | Type | Priority | Surface |
|----|------|------|----------|---------|
| UT-01 | Page loads | smoke | P1 | `/` |
| UT-02 | Happy path | happy-path | P1 | `/` |
| UT-03 | Validation | validation | P2 | `/` |
| UT-04 | Regression check | regression | P1 | `/` |
| UT-05 | Discoverability | ux | P2 | nav |

**P1 tests must all pass for browser QA verdict to be PASS.**
