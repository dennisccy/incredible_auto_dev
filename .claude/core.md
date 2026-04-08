# Core Rules — Universal Standards

This file defines universal rules that apply to ALL agents in ALL projects using this framework.
These rules never change between projects. Project-specific rules live in `.claude/project-template.md`.

---

## Phase Scoping

- Build ONLY within the current phase's spec
- STOP immediately after completing the phase — do NOT continue automatically
- Do NOT implement features outside the current phase spec
- If the spec asks for something that conflicts with project architecture, flag it in the plan — do not silently skip or silently implement it
- When in doubt about scope, exclude rather than include

---

## Code Quality Checklist

Every piece of code produced MUST meet all of the following before the phase is considered complete:

- [ ] Readable and maintainable — a fresh reader can understand it without comments
- [ ] No unnecessary libraries or dependencies
- [ ] No premature optimization
- [ ] No refactoring of code outside the current task scope
- [ ] No dead code, commented-out blocks, or print/debug statements
- [ ] No hardcoded strings that belong in enums, config, or constants
- [ ] No silent failures — errors must surface, not be swallowed
- [ ] State transitions validated in backend logic, not only in frontend or client
- [ ] No feature flags or backwards-compatibility shims unless the spec requires them

---

## Visual Quality Checklist

Every UI change MUST meet all of the following (applies when `Frontend Present: yes`):

- [ ] Uses component library components from DESIGN SYSTEM config — no raw HTML `<div>` soup where a Card, Button, Table, or Dialog exists
- [ ] Follows color palette tokens — no arbitrary hex values outside the defined palette
- [ ] Follows spacing scale — no arbitrary pixel values (use the configured spacing system)
- [ ] Follows typography scale — no arbitrary font sizes
- [ ] Visual hierarchy is clear — headings, content, and actions are visually distinct
- [ ] Loading, empty, and error states have appropriate visual treatment (skeleton loaders, empty state illustrations, error messages styled consistently)
- [ ] Interactive elements have hover/focus/active states
- [ ] Effects (glassmorphism, glows, gradients) are used as defined in DESIGN SYSTEM — not invented ad-hoc
- [ ] Pages are responsive at configured breakpoints
- [ ] New pages visually match the established style of existing pages

---

## Testing Requirements

Every new capability MUST be covered by at least one of the following:

- [ ] A backend unit or integration test that asserts the correct behavior (not just that it runs)
- [ ] A browser-driven UI workflow test via Chrome MCP (if the capability is user-facing)

**Testing standards:**

- Tests must assert exact values, not just "something was returned"
- Tests must cover at least one edge case or failure path, not just the happy path
- Tests must pass before a phase is declared complete
- Do NOT assume functionality without running tests
- Do NOT write tests that pass by accident (wrong setup, mocked-out dependencies that hide the real behavior)
- Test failures BLOCK phase completion — they cannot be noted as "known issues" and shipped

---

## Security Baseline

- NEVER commit secrets, `.env` files, credentials, API keys, or database files
- NEVER force-push main
- NEVER amend published commits
- NEVER delete remote branches unless the user explicitly instructs it
- NEVER run destructive operations (`rm -rf`, `dd`, disk tools) without explicit user instruction
- NEVER read SSH keys, AWS credentials, or browser password stores
- NEVER send env vars or secrets to external endpoints
- Supply-chain: all new package installs go through the security gate (see hooks)

---

## Token and Questioning Policy

**Before asking ANY question:**
1. Read `.claude/project-template.md` — project-specific context
2. Read the phase spec — requirements and acceptance criteria
3. Read existing code — understand what already exists
4. Read prior artifacts (plans, handoffs, review reports) — understand prior decisions

**Questioning rules:**
- Do NOT ask for information available in the spec, CLAUDE.md, project-template.md, or existing code
- Batch all necessary questions into ONE message before major execution begins
- Avoid follow-up question cascades — if you have 3 questions, ask them together
- Record assumptions in artifacts (`runs/<phase>/plan.md`), not in chat
- Prefer a documented assumption over a blocked question

**Interrupt for:**
- Blocking issues that cannot be inferred from the repo
- Critical ambiguity that would cause significant rework
- Missing credentials or auth required to proceed
- Dangerous or irreversible actions

**Output rules:**
- Keep chat output concise and decision-oriented
- Do NOT repeat repo context or prior instructions in replies
- Do NOT print large code blocks unless explicitly requested
- Write detailed output to repo artifacts — not chat

---

## Definition of Done (per phase)

A phase is done when ALL of the following are true:

1. All items in the spec's DEFINITION OF DONE are implemented and verified in code (not just summarized)
2. All required tests pass
3. Every new user-facing capability is accessible via the UI (if the project has a frontend)
4. The dev handoff is written to `docs/handoffs/<phase>-dev.md`
5. The review report has a PASS or PASS_WITH_NOTES verdict
6. The QA report has a PASS verdict
7. The audit report (if auditor is configured) has PASS or PASS_WITH_GAPS verdict
8. All 6 UI visibility artifacts are produced (implementation-summary, user-visible-changes, ui-surface-map, ui-test-plan, ui-test-results, what-to-click)
9. The phase closure auditor gives CLOSURE-PASS

**A phase is NOT done if:**
- Tests pass but the feature is invisible to the user (backend-only when UI was expected)
- The code technically compiles but the spec's acceptance criteria aren't met
- QA ran only unit tests when the spec required user flow validation
- The reviewer gave PASS_WITH_NOTES but the notes include blocking issues
- UI test results show failures that are not documented as known issues
- Phase promised a user-facing feature but only backend work exists and `Frontend Present: yes`
- Browser QA was skipped without a documented reason
- Manual test instructions are vague or missing exact user steps and expected outcomes

---

## Handoff Requirements

At the end of every phase, the developer MUST write a handoff to `docs/handoffs/<phase>-dev.md` containing:

1. **What Was Built** — bullet list of new features, endpoints, models, migrations
2. **Files Changed** — complete list with one-line description per file
3. **Tests Run** — exact command and result counts
4. **Known Issues** — any gaps, workarounds, or limitations (honest, not minimized)
5. **Suggested Next Phase** — one paragraph

Then STOP and wait for review/QA to run.

---

## UI Visibility Rules

These rules apply to every phase where user-visible behavior is affected:

1. **A phase is not complete because code compiles or API tests pass.** User-facing phases require user-facing evidence.
2. **If user-visible behavior changed, explain what changed in the UI.** Produce `user-visible-changes.md` and `ui-surface-map.md`.
3. **If user-visible behavior changed, provide both:** automated browser validation (`ui-test-results.md`) and manual test steps (`what-to-click.md`).
4. **Reports must be written for operators, not developers.** No API jargon in user-facing artifacts.
5. **Exact click paths and expected outcomes are mandatory.** "Test the form" is not a test step.
6. **Browser QA must test workflows, not only render checks.** Navigating to a page is not a test — completing a user journey is.
7. **Reviewer must reject backend-only completion when the phase goal implies full product capability.**
8. **UI must evolve with backend capabilities.** Hidden or undiscoverable features are insufficient.
9. **Manual testing instructions must be concise, ordered, and immediately actionable.** An operator must be able to follow them without developer knowledge.
10. **Any skipped UI test must include a concrete, documented reason.** "Could not run" is not a reason.
