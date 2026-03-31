# Code Review Report — Phase N

## Verdict

<!-- PASS | PASS_WITH_NOTES | FAIL — the **Verdict:** prefix is required -->
**Verdict:** PASS

---

## Checklist

### Spec compliance
- [ ] All in-scope items from the phase spec are implemented
- [ ] No features implemented outside the spec (no scope creep)
- [ ] Definition of Done items are met

### Correctness
- [ ] State transitions validated server-side (not just frontend)
- [ ] Invalid transitions are rejected with appropriate error codes
- [ ] Input validation at system boundaries (user input, external APIs)
- [ ] No SQL injection, XSS, or command injection vectors

### Tests
- [ ] New behavior is covered by unit or integration tests
- [ ] Tests cover the unhappy path (invalid input, rejected transitions)
- [ ] Existing tests still pass (no regressions introduced)
- [ ] Tests test behavior, not implementation details

### Code quality
- [ ] No dead code or commented-out blocks
- [ ] No hardcoded strings that belong in enums or config
- [ ] No unnecessary abstractions for one-time operations
- [ ] Logic is readable without needing to trace three layers deep

### UI (if frontend phase)
- [ ] UI exposes the new capability (not just a button that triggers API)
- [ ] New top-level entities have list + detail pages reachable from navigation
- [ ] Navigation updated to include link to new entity/workflow
- [ ] Per workflow.md UI evolution policy

### Architecture
- [ ] Follows project-specific architecture rules in .claude/project-template.md
- [ ] No cross-layer violations (e.g., business logic in route handlers)
- [ ] Database schema changes are backward-compatible or migration-gated

---

## Issues Found

<!-- List all issues. Use severity: BLOCKING | IMPORTANT | MINOR -->

### BLOCKING (must fix before PASS)

<!-- If none: "None." -->
None.

### IMPORTANT (should fix, may allow PASS_WITH_NOTES)

<!-- If none: "None." -->
None.

### MINOR (optional improvements)

<!-- If none: "None." -->
None.

---

## Notes

<!-- Any other observations, context, or suggestions. -->
