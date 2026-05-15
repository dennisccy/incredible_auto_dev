# Skill: Phase Closure Gate

This skill defines how to evaluate whether a phase is truly complete, not just technically finished.

## Required Artifact Checklist

For every phase, verify all exist and are non-empty:

**Standard pipeline artifacts** (always required):
- [ ] `docs/handoffs/<phase>-dev.md` — exists and has "What Was Built" section
- [ ] `reports/reviews/<phase>-review.md` — verdict is PASS or PASS_WITH_NOTES
- [ ] `reports/qa/<phase>-qa.md` — verdict is PASS
- [ ] `docs/handoffs/<phase>-audit.md` — verdict is PASS or PASS WITH GAPS

**UI visibility artifacts** (required if Frontend Present: yes):
- [ ] `reports/phase-{N}-implementation-summary.md` — exists, >5 lines, not all placeholders
- [ ] `reports/phase-{N}-user-visible-changes.md` — exists, has at least one specific entry
- [ ] `reports/phase-{N}-ui-surface-map.md` — exists, has at least one table row
- [ ] `reports/phase-{N}-ui-test-plan.md` — exists, has at least one test case with steps
- [ ] `reports/phase-{N}-ui-test-results.md` — exists, has execution evidence
- [ ] `reports/phase-{N}-what-to-click.md` — exists, has ≥3 numbered steps

**UI visibility artifacts** (N/A stubs acceptable if Frontend Present: no):
- [ ] All 6 files still must exist, even as one-line N/A stubs

## Vagueness Detection

Reject any artifact that contains only:
- Generic placeholders: "TBD", "TODO", "FILL IN", "N/A" where content is expected
- Vague test steps: "Test the form", "Verify it works", "Check the page"
- Empty sections with just headers
- Fewer than 5 lines of actual content (excluding headers)

## Cross-Reference Validation

Check consistency across artifacts:

**Claim vs evidence check**:
- If `implementation-summary` says "5 features added"
- But `user-visible-changes` has 0 entries OR only says "no visible changes"
- AND `Frontend Present: yes`
- → Flag as inconsistency

**Browser QA execution check**:
- If `ui-test-results` shows all tests as SKIPPED
- AND the reason is "frontend not running" OR "Chrome MCP not available"
- AND there is no documented justification for why this is acceptable
- → Flag as "browser QA not executed"

**Acceptable exception**: If the phase added backend-only items but the phase spec said "API layer only" or similar backend-scoped language, then SKIPPED browser tests are acceptable. Document this explicitly.

## Backend-only Claim Guard

When `Frontend Present: yes`:
- Check `implementation-summary` for features described as "complete"
- Check if those features have a corresponding entry in `user-visible-changes`
- If a feature is described as complete but not visible: ask whether the phase spec said this should be user-facing
- If yes: flag as "feature complete in backend but not wired to UI"

## Blocking vs Non-Blocking

**Blocking (must be fixed before CLOSURE-PASS)**:
- Missing required artifacts
- Standard pipeline gates not passed (review, QA, audit fail)
- Frontend Present: yes but no UI test execution at all
- Inconsistency between implementation claims and evidence

**Non-blocking (document as known gap)**:
- Some test cases in the UI test plan have SKIP but most executed
- Minor UX regression flags with WARN verdict
- What-to-click guide has fewer than ideal steps
