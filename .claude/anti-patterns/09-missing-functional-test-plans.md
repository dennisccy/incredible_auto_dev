## 9. Missing functional test plans make QA rubber-stamp

**Pattern:** QA runs `pytest` and reports PASS. The test suite covers internal functions but doesn't verify the user-facing feature works end-to-end. A critical API endpoint is broken but no test covers it.

**Why it fails:** "Tests pass" and "the feature works for a user" are different claims. Without a functional test plan derived from the spec, QA only validates what the developer chose to test, not what the spec required.

**Prevention:** The test plan generator runs BEFORE QA, deriving explicit test cases from the spec's DEFINITION OF DONE and REQUIRED USER FLOWS. QA must execute each TC-01, TC-02, ... test case and record actual vs expected outcomes. A test case failure is a blocker.

---

