## 11. One large phase spec with no DEFINITION OF DONE

**Pattern:** A phase spec describes 8 features in general terms, with no numbered acceptance checklist.

**Why it fails:** The orchestrator doesn't know what "done" looks like. The developer implements 5 of the 8 things. The reviewer gives PASS_WITH_NOTES on the missing 3. QA gives PASS because tests pass. The audit gives FAIL because the spec goal wasn't reached. The pipeline re-runs from dev — wasting 3 cycles that could have been avoided.

**Prevention:** Every phase spec MUST have a numbered DEFINITION OF DONE checklist. Each item is specific and testable. The auditor's primary job is to verify this checklist against actual code, not summaries.

---

