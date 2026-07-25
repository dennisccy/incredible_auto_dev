## 14. Vague test steps make test plans useless

**Pattern:** A test plan says "test the form submission" or "verify results are correct." The browser QA agent cannot execute this. A human tester cannot follow this. The plan exists but adds no value.

**Why it fails:** Vague test steps produce vague results. "Tested and it works" is not evidence. A test plan that cannot produce reproducible pass/fail evidence is not a test plan.

**Prevention:** Every test step must specify: exact URL, exact element to interact with (by name or visible label), exact value to input, and exact expected outcome. The `post-write-artifact-quality.sh` hook warns when phase report files contain vague placeholder lines. The `what-to-click-writer` skill enforces concrete step writing.

---

