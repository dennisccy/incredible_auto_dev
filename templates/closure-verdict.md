# Phase N — Closure Verdict

**Phase:** <phase-id>
**Date:** <YYYY-MM-DD>
**Written by:** phase-closure-auditor

---

**Verdict:** CLOSURE-PASS | CLOSURE-FAIL

<!-- CLOSURE-PASS: All gates passed, phase is ready to finalize -->
<!-- CLOSURE-FAIL: One or more blocking issues prevent completion -->

---

## Standard Pipeline Gate Checks

| Artifact | Status | Verdict |
|----------|--------|---------|
| Review report (`reports/reviews/<phase>-review.md`) | exists / missing | PASS / FAIL |
| QA report (`reports/qa/<phase>-qa.md`) | exists / missing | PASS / FAIL |
| Audit report (`docs/handoffs/<phase>-audit.md`) | exists / missing | PASS / FAIL |

---

## UI Visibility Artifact Checks

| Artifact | Exists | Non-Empty | Non-Vague | Status |
|----------|--------|-----------|-----------|--------|
| implementation-summary.md | yes/no | yes/no | yes/no | OK / MISSING / VAGUE |
| user-visible-changes.md | yes/no | yes/no | yes/no | OK / MISSING / VAGUE |
| ui-surface-map.md | yes/no | yes/no | yes/no | OK / MISSING / VAGUE |
| ui-test-plan.md | yes/no | yes/no | yes/no | OK / MISSING / VAGUE |
| ui-test-results.md | yes/no | yes/no | yes/no | OK / MISSING / VAGUE |
| what-to-click.md | yes/no | yes/no | yes/no | OK / MISSING / VAGUE |

---

## Cross-Reference Checks

- [ ] user-visible-changes lists ≥1 specific capability (or N/A for backend-only)
- [ ] ui-surface-map has specific route/component entries (or N/A)
- [ ] ui-test-plan has specific steps with exact actions and expected results
- [ ] ui-test-results shows execution evidence (or SKIPPED with documented reason)
- [ ] what-to-click has ≥3 numbered steps with exact expected outcomes (or N/A)
- [ ] implementation-summary claims are consistent with ui-test-results evidence

---

## Blocking Issues

<!-- List each issue that blocks CLOSURE-PASS. -->
<!-- For CLOSURE-PASS: write "None" -->

1. **<Issue title>**: <Specific description of what is missing or inconsistent>
   **Remediation**: <Exact command or action to fix this>

---

## Non-Blocking Notes

<!-- Optional: issues that are not blocking but should be tracked. -->

- <Note>

<!-- None if no non-blocking notes. -->
