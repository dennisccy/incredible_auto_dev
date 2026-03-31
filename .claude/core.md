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

**A phase is NOT done if:**
- Tests pass but the feature is invisible to the user (backend-only when UI was expected)
- The code technically compiles but the spec's acceptance criteria aren't met
- QA ran only unit tests when the spec required user flow validation
- The reviewer gave PASS_WITH_NOTES but the notes include blocking issues

---

## Handoff Requirements

At the end of every phase, the developer MUST write a handoff to `docs/handoffs/<phase>-dev.md` containing:

1. **What Was Built** — bullet list of new features, endpoints, models, migrations
2. **Files Changed** — complete list with one-line description per file
3. **Tests Run** — exact command and result counts
4. **Known Issues** — any gaps, workarounds, or limitations (honest, not minimized)
5. **Suggested Next Phase** — one paragraph

Then STOP and wait for review/QA to run.
