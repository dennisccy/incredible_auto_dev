# Phase N — UI Test Results

**Phase:** <phase-id>
**Date:** <YYYY-MM-DD>
**Written by:** browser-qa-agent

---

**Browser QA Verdict:** PASS | FAIL | SKIPPED

<!-- PASS: All P1 tests pass -->
<!-- FAIL: Any P1 test fails -->
<!-- SKIPPED: Frontend not running or Chrome MCP unavailable -->

**Overall:** X/Y tests passed (Z skipped)

---

## Results Table

| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |
|---------|------|------|----------|----------|--------|---------|----------|
| UT-01 | <name> | smoke | P1 | <expected outcome> | <what actually happened> | PASS/FAIL/SKIP | screenshot path or "none" |

---

## Passed Tests

### UT-01 — <name>
**Verdict:** PASS
**Evidence:** `reports/qa/<phase>-evidence/UT-01-result.png`
- <Key verification step and what was observed>

---

## Failed Tests

<!-- One section per failed test. -->

### UT-XX — <name>
**Verdict:** FAIL
**Failure:** <Exact description of what went wrong>
**Evidence:** `reports/qa/<phase>-evidence/UT-XX-fail.png`

**Steps taken:**
1. <What was done>
2. <What was done>

**Expected:** <What should have happened>
**Actual:** <What actually happened>

---

## Skipped Tests

<!-- One section per skipped test with reason. -->

### UT-XX — <name>
**Verdict:** SKIPPED
**Reason:** <Exact reason: frontend not running | Chrome MCP unavailable | prerequisite data missing>

---

## Environment

- **Frontend URL:** http://localhost:3000
- **Browser:** Chrome via MCP
- **Test Date:** <YYYY-MM-DD>
- **Evidence directory:** `reports/qa/<phase>-evidence/`
