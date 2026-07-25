## 13. Backend capabilities without UI verification leads to invisible features

**Pattern:** A phase adds 3 new API endpoints. Unit tests pass. QA validates the APIs. Audit gives PASS. But no one verified that the user can actually reach these features from the UI. Three phases later, someone clicks through the app and discovers half the features have no navigation path.

**Why it fails:** "Tests pass" and "the feature works for a user" are completely different claims. A feature that exists in the backend but has no UI entry point is invisible product capability — it was built but cannot be used.

**Prevention:** The UI visibility system produces 6 artifacts per phase:
- `implementation-summary` — what was built
- `user-visible-changes` — what users can now do
- `ui-surface-map` — which routes/components changed and what to test
- `ui-test-plan` — exact click paths and expected outcomes
- `ui-test-results` — browser automation evidence
- `what-to-click` — 5-minute operator verification guide

The phase closure auditor blocks completion when these artifacts are missing or vague. Browser QA must test actual user workflows, not just that pages render.

---

