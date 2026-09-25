# Skill: Manual UI Test Plan Generator

This skill describes how to create a human-executable UI test plan with exact steps and expected outcomes.

## Test Type Definitions

**Smoke test**: Verify the page loads without errors and required elements exist.
- Always start here for each affected surface
- Pass criteria: page renders, no console errors, key elements visible

**Happy path test**: The core user workflow from start to finish.
- One test per major new capability
- Must include the complete flow: entry point → action → verification
- Pass criteria: user achieves the intended outcome

**Validation test**: Form validation and input error handling.
- One test per form that was added or changed
- Test: submit without required fields, submit with invalid data, submit with boundary values
- Pass criteria: user sees specific, helpful error messages

**Error test**: Backend errors surfaced to the user.
- Test what happens when the backend returns an error
- If backend errors can be triggered (e.g., duplicate, not found, unauthorized)
- Pass criteria: user sees actionable error message, not a crash or empty page

**Regression test**: Old functionality still works.
- One test per prior feature that shares a component or route with this phase
- Pass criteria: existing workflow completes without new obstacles

**UX sanity test**: Feature is discoverable and makes sense.
- Navigate to the feature as a new user would
- Pass criteria: user can find the feature within 2 clicks from home, label is clear

## Test Case Writing Rules

### Required fields for every test case:
```
**ID**: UT-XX
**Name**: Short descriptive title (not "test the form")
**Type**: smoke | happy-path | validation | error | regression | ux
**Surface**: /route or component name
**Preconditions**: Exact state required (login, data, permissions)
**Steps**: Numbered actions
**Expected Result**: What the operator should see
```

### Step writing rules:
- Never write "click the button" — write "click the blue 'Save' button in the top-right corner"
- Never write "fill in the form" — write "type 'Test Item' in the 'Name' field"
- Never write "verify it works" — write "verify the item appears in the list with name 'Test Item'"
- Include exact URLs: "navigate to http://localhost:3000/items/new"
- Include exact text: "type 'invalid@' in the Email field"
- Include exact expected values: "expect the message 'Item created successfully' to appear"

### Test data rules:
- Never use a fixture or record that the goal or phase spec reserves for one journey (for example a
  `docs/goal.md` fixture table entry "used only by J-NN") as setup input for any other test case. The
  browser lane runs every test case against the same backend, so that setup contaminates the reserved
  journey: a warmed cache, shifted labels or changed storage make its acceptance unprovable
  (goal-taketwo iter 19: a setup that imported J-01's cold-ingest fixture made J-01 read
  "Reused from cache"). Pick a non-reserved fixture, and name it in Preconditions; if none fits, say so
  there instead of borrowing a reserved one.

### Transient-state rules:
- A state that lasts only seconds (an in-flight status, a button shown only while work runs) must be
  written as ONE in-page script step: trigger, poll the DOM, then assert or click while the state
  holds (see browser-workflow-executor "Verify a transient state"). Never write it as "wait 6-8
  seconds, then look". Each browser-tool round trip takes 30 s to minutes, longer than the state
  (goal-taketwo iter 20: two P1 audit checks missed ~5 s and ~21 s windows that the database proves
  existed).
- Give each attempt an input that really enters the state. Repeating a fixture whose result is cached
  skips the work entirely. Name the cold input in Preconditions, and plan for the first attempt to be
  the one that counts.

### Expected result writing rules:
- Describe the visual outcome the operator should observe
- Include specific text, elements, or states to look for
- State what should NOT appear (e.g., "error message should NOT appear")
- Include the URL the user should be on after the action

## Priority Assignment

**P1 (must pass for PASS verdict)**:
- All smoke tests
- All happy path tests

**P2 (important but non-blocking)**:
- Validation tests
- Error tests

**P3 (informational)**:
- UX sanity tests
- Regression tests with low risk
