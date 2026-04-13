# Anti-Patterns

Failure modes observed in production multi-agent development pipelines.
Each entry includes: the pattern, why it fails, and how to prevent it.

---

## 1. Vague acceptance criteria cause infinite review loops

**Pattern:** Phase specs contain requirements like "works correctly", "handles all cases", or "the UI should look nice."

**Why it fails:** The reviewer and the developer use different interpretations of "correct". Each review cycle produces a FAIL for a different reason. After 3 loops the pipeline halts with no clear fix.

**Prevention:** Every item in DEFINITION OF DONE must be:
- Specific: "POST /api/items returns 201 with the created item's ID"
- Testable: a concrete pass/fail condition, not a judgment
- Scoped: tied to this phase only, not aspirational future state

**Example (bad):** "The form submission should work."
**Example (good):** "Submitting a valid form creates a record in the database and redirects to the detail page. Submitting an invalid form shows field-level error messages and does not create a record."

---

## 2. Hardcoded stack paths in agent prompts break portability

**Pattern:** Agent definitions or scripts contain paths like `apps/backend/.venv/bin/python -m pytest` or `cd apps/backend && alembic upgrade head` embedded directly.

**Why it fails:** When the framework is adopted by a new project, every agent file needs manual editing. Agents in the pipeline inherit the wrong paths and fail silently.

**Prevention:** All stack-specific commands live in `.claude/project-template.md`. Agent definitions reference the template: "Run the test command from project-template.md." Scripts use env vars (`CHAIN_START_BACKEND_CMD`) or conventionally-named scripts (`scripts/start-backend.sh`).

---

## 3. Merged backend+frontend into one developer agent reduces flexibility

**Pattern (anti):** Splitting implementation into separate backend-only and frontend-only agents with separate model invocations.

**Why it's a false economy:** The backend agent writes the handoff, then the frontend agent reads it and adds another handoff. Two sequential long-context invocations for work that shares context. Each agent re-reads the spec, plan, and existing code from scratch.

**Prevention:** A single developer agent handles both. The plan marks `Frontend Present: yes/no`. On yes, the agent implements backend first, then frontend in the same session. Alternatively, run two passes of the same developer agent (backend pass, then frontend pass) using the same agent definition with different context flags.

---

## 4. UI evolution is an afterthought, not a pipeline gate

**Pattern:** QA runs unit tests, they pass, phase is declared done. Three phases later the product manager notices the user can't access the new feature because no navigation link was added.

**Why it fails:** Unit tests don't check whether the UI exposes the capability. A backend feature is invisible until the UI surfaces it.

**Prevention:** The UI Evolution Audit is part of every phase with `Frontend Present: yes`. `UI-FAIL` blocks overall QA PASS. Review checklist explicitly checks for navigation updates and detail/list pages.

---

## 5. Quota exhaustion mid-pipeline without retry causes data loss

**Pattern:** A 6-stage pipeline runs unattended. At stage 4 (QA), Claude hits the usage quota and exits. The partial run state is lost. The pipeline must restart from scratch.

**Why it fails:** Wasted compute. Worse, if stage 3 (dev) made changes that weren't committed, the developer re-implements the same code differently on retry, causing drift.

**Prevention:**
- Checkpoint/resume via `runs/<phase>/status.json` — completed stages are skipped on re-run
- `quota-retry.sh` wraps every Claude invocation — detects quota messages, parses the reset time, sleeps and retries automatically
- Never start a long pipeline before verifying quota headroom

---

## 6. Review reports without file:line references are useless

**Pattern:** Review report says "the validation logic has issues" or "error handling could be improved."

**Why it fails:** The developer reads the report, doesn't know which file or line to fix, makes a guess, and the reviewer flags the same "issue" again in the next loop.

**Prevention:** Every finding in a review report MUST include:
- Exact file path
- Line number or function name
- Specific problem description
- Specific fix description

**Example (bad):** "Error handling is insufficient."
**Example (good):** "`apps/backend/routers/items.py:47` — `create_item` does not catch `IntegrityError` from SQLAlchemy. Add a try/except that returns 409 Conflict when a duplicate key is detected."

---

## 7. Reviewer and QA validator that fix code bypass the feedback loop

**Pattern:** The reviewer notices a bug and edits the file to fix it "since it's obvious." The QA validator notices a test failure and patches the test to pass.

**Why it fails:** The developer agent doesn't learn from the correction. On the next phase, the same mistake recurs because the developer never saw it as a fix — only the reviewer did. More critically: reviewer fixes can silently introduce new bugs that QA was supposed to catch, but QA didn't see the reviewer's changes.

**Prevention:**
- Reviewer NEVER edits source files — writes the report only
- QA NEVER fixes test failures — writes them as blockers
- Only the developer (and auditor, for critical post-QA issues) modifies source code

---

## 8. Free-form agent conversation leads to hallucinated agreements

**Pattern:** Two agents "discuss" a design decision in chat. Agent B says "OK I'll implement it your way." Agent B then implements something different because its actual context window didn't include the full conversation.

**Why it fails:** Chat messages between agents are not in each agent's context window. Agents only have access to what was in their initial prompt and what they've read from files in the current session.

**Prevention:** Agents communicate ONLY through filesystem artifacts. No "pass a message to the next agent." The orchestrator writes a plan to a file; the developer reads that file. The developer writes a handoff; the reviewer reads that file. This is the only reliable inter-agent communication.

---

## 9. Missing functional test plans make QA rubber-stamp

**Pattern:** QA runs `pytest` and reports PASS. The test suite covers internal functions but doesn't verify the user-facing feature works end-to-end. A critical API endpoint is broken but no test covers it.

**Why it fails:** "Tests pass" and "the feature works for a user" are different claims. Without a functional test plan derived from the spec, QA only validates what the developer chose to test, not what the spec required.

**Prevention:** The test plan generator runs BEFORE QA, deriving explicit test cases from the spec's DEFINITION OF DONE and REQUIRED USER FLOWS. QA must execute each TC-01, TC-02, ... test case and record actual vs expected outcomes. A test case failure is a blocker.

---

## 10. Supply-chain attacks target autonomous agents

**Pattern:** A compromised PyPI or npm package gets installed by an agent during a phase run. The agent has no reason to be suspicious — it's just running the install command from the spec.

**Why it fails:** Autonomous agents install packages without human review. A single compromised dependency can exfiltrate secrets, modify the codebase, or establish persistence — all while the pipeline continues normally.

**Prevention:** The install security gate intercepts every `pip install`, `npm install`, `git clone`, and `curl|bash` command. Packages not in the allowlist require approval. Direct URL installs are blocked. All install decisions are logged to `reports/security/install-decisions.jsonl`. The gate is a non-negotiable pipeline component — it is not "paranoia."

---

## 11. One large phase spec with no DEFINITION OF DONE

**Pattern:** A phase spec describes 8 features in general terms, with no numbered acceptance checklist.

**Why it fails:** The orchestrator doesn't know what "done" looks like. The developer implements 5 of the 8 things. The reviewer gives PASS_WITH_NOTES on the missing 3. QA gives PASS because tests pass. The audit gives FAIL because the spec goal wasn't reached. The pipeline re-runs from dev — wasting 3 cycles that could have been avoided.

**Prevention:** Every phase spec MUST have a numbered DEFINITION OF DONE checklist. Each item is specific and testable. The auditor's primary job is to verify this checklist against actual code, not summaries.

---

## 12. Agents that "summarize" instead of reading source code

**Pattern:** The auditor reads the dev handoff and QA report, concludes "tests pass and the handoff describes the implementation," and gives PASS.

**Why it fails:** The handoff is a summary written by the agent that implemented the code. It naturally omits mistakes. The QA report validates what the developer chose to test. Neither is a substitute for reading the actual source files.

**Prevention:** Auditor instructions explicitly state: "Read actual source files, not summaries. If you cannot verify a claim from code, trace through the implementation. Never trust a handoff summary alone."

---

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

## 14. Vague test steps make test plans useless

**Pattern:** A test plan says "test the form submission" or "verify results are correct." The browser QA agent cannot execute this. A human tester cannot follow this. The plan exists but adds no value.

**Why it fails:** Vague test steps produce vague results. "Tested and it works" is not evidence. A test plan that cannot produce reproducible pass/fail evidence is not a test plan.

**Prevention:** Every test step must specify: exact URL, exact element to interact with (by name or visible label), exact value to input, and exact expected outcome. The `post-write-artifact-quality.sh` hook warns when phase report files contain vague placeholder lines. The `what-to-click-writer` skill enforces concrete step writing.
