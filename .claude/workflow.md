# Workflow — Phase Execution Pipeline

This file defines how phases are executed, how agents interact, and what constitutes success.

---

## Pipeline Overview

Each phase flows through 6 stages, driven by `scripts/automation/run-phase.sh`:

```
Plan → Test Plan → Dev+Review loop → QA loop → Audit loop → Finalize
```

| Stage | Script | Agent | Output |
|-------|--------|-------|--------|
| 1. Plan | `run-phase.sh` (internal) | orchestrator | `runs/<phase>/plan.md` |
| 2. Test Plan | `generate-test-plan.sh` | qa (mode: generate) | `reports/qa/<phase>-test-plan.md` |
| 3. Dev + Review | `dev-phase.sh` + `review-phase.sh` | developer, reviewer | `docs/handoffs/<phase>-dev.md`, `reports/reviews/<phase>-review.md` |
| 4. QA | `qa-phase.sh` | qa (mode: validate) | `reports/qa/<phase>-qa.md` |
| 5. Audit | `phase-audit.sh` | auditor | `docs/handoffs/<phase>-audit.md` |
| 6. Finalize | `finalize-phase.sh` | release-manager | `runs/<phase>/summary.json`, PR |

---

## Retry Policy

- **Dev+Review loop**: max 3 attempts. On review FAIL, developer fixes listed issues, reviewer re-evaluates.
- **QA loop**: max 3 attempts. On QA FAIL, developer fixes, reviewer confirms, QA re-validates.
- **Audit loop**: max 2 attempts. On audit FAIL, developer + reviewer + QA re-run before auditor re-evaluates.
- After max retries are exhausted, the pipeline halts with a FAILED status.

---

## Artifact-Based Communication

Agents ONLY communicate through filesystem artifacts. No free-form messages between agents.

**Artifact locations:**

| Artifact | Path | Written by | Read by |
|----------|------|------------|---------|
| Phase spec | `docs/phases/<phase>.md` | Human | All agents |
| Execution plan | `runs/<phase>/plan.md` | orchestrator | developer, reviewer, qa, auditor |
| Test plan | `reports/qa/<phase>-test-plan.md` | qa (generate mode) | qa (validate mode) |
| Dev handoff | `docs/handoffs/<phase>-dev.md` | developer | reviewer, qa, auditor |
| Frontend handoff | `docs/handoffs/<phase>-frontend.md` | developer | reviewer, qa, auditor |
| Audit report | `docs/handoffs/<phase>-audit.md` | auditor | release-manager |
| Review report | `reports/reviews/<phase>-review.md` | reviewer | qa, developer (fix mode) |
| QA report | `reports/qa/<phase>-qa.md` | qa | auditor, release-manager |
| Phase status | `runs/<phase>/status.json` | scripts + agents | scripts |
| Phase summary | `runs/<phase>/summary.json` | finalize script | release-manager |

---

## Checkpoint / Resume Protocol

Every phase run is tracked in `runs/<phase>/status.json`. If a run is interrupted, re-running `run-phase.sh` resumes from the last completed step.

**State machine:**

| `current_step` | Steps skipped on resume |
|---|---|
| `planned` | Plan |
| `test_plan_generated` | Plan, test plan |
| `dev_complete_attempt_*` | Plan, test plan; first dev pass (review re-runs) |
| `review_passed` | Plan, test plan, dev+review |
| `qa_passed` | Plan, test plan, dev+review, QA |
| `audit_passed` | Plan, test plan, dev+review, QA, audit |
| `summary.json` finalized | All steps — exits immediately |

Use `--reset` flag to clear checkpoints and re-run all steps.

---

## Verdict Formats (machine-read)

Verdicts are detected by `grep` in shell scripts. Use EXACTLY these formats:

**Review report** (`reports/reviews/<phase>-review.md`) — first line:
```
**Verdict:** PASS
**Verdict:** PASS_WITH_NOTES
**Verdict:** FAIL
```

**QA report** (`reports/qa/<phase>-qa.md`) — first line:
```
**Verdict:** PASS
**Verdict:** FAIL
```

**Audit report** (`docs/handoffs/<phase>-audit.md`) — in Executive Verdict section:
```
**PASS**
**PASS WITH GAPS**
**FAIL**
```

**UI Evolution Audit** (inside QA report):
```
**Verdict:** UI-PASS
**Verdict:** UI-PASS-WITH-GAPS
**Verdict:** UI-FAIL
```

If verdict format is wrong, scripts cannot detect PASS and will loop indefinitely.

---

## UI Evolution Policy

For every phase where the backend adds user-facing capability:

1. The UI MUST evolve to expose that capability
2. New entity types MUST have list + detail pages reachable from navigation
3. The sidebar/navigation MUST be updated if a new top-level workflow is introduced
4. A phase MUST NOT be considered complete if the backend changed but the UI did not reflect it

**UI Evolution Audit (conducted by qa agent when `Frontend Present: yes`):**

Answer each question:
1. Did the UI evolve to reflect the phase's new capability?
2. Can the user now see, understand, and control the new capability from the UI?
3. Is the UI still relying on old generic pages for new functionality?
4. Is the implementation technically complete but product-wise underexposed?

Assign:
- `UI-PASS` — UI meaningfully reflects the new capability
- `UI-PASS-WITH-GAPS` — UI works but has notable gaps (list each)
- `UI-FAIL` — backend capability is not adequately reflected in the UI

**If UI-FAIL: overall QA verdict MUST be FAIL.**
**If Frontend Present: no — skip UI audit entirely.**

---

## State and Lifecycle Rules

- Each entity must have clear status enums
- State transitions must be explicit and validated in backend logic
- Invalid transitions must be rejected (not silently ignored)
- Every important state change must be recorded with a timestamp and payload (audit trail)
- Do NOT rely on frontend for validation of business rules

---

## Plan Format

The orchestrator writes `runs/<phase>/plan.md` in this exact structure (machine-read by scripts):

```markdown
# <phase> Execution Plan

## What to Build
- <feature 1>
- <feature 2>

## Agents Required
- developer: yes/no -- <what to implement>
- (additional specializations if needed)

## Frontend Present
yes/no

## Files to Create/Modify
- `path/to/file` -- <description>

## UI Evolution (required if Frontend Present: yes)
- New user-facing capability: <what user can now see/do>
- New information displayed: <new data visible>
- New user actions: <buttons/forms/controls added>
- UI surface changes: <pages/panels added or improved>
- Navigation changes: <sidebar links added, or "none">

## Key Test Scenarios
- <scenario that must pass for phase to be complete>
```

The `Frontend Present:` line is machine-read by `qa-phase.sh` to decide whether Chrome MCP browser checks are required. Write it **exactly** as shown above.

---

## Git and GitHub Workflow

- Branch naming: `phase/<phase-id>`
- PR title format: `feat: <phase-id> — <one-line summary>`
- PRs are created after audit passes (or QA passes if no auditor configured)
- NEVER force-push main
- NEVER amend published commits
- Files listed in project-template.md `never-commit` section must not be staged

---

## Model Tier Rationale

| Tier | Model | Used for |
|------|-------|----------|
| strong | claude-opus-4-6 | Complex reasoning: planning, code generation, auditing |
| standard | claude-sonnet-4-6 | Solid tasks: code review, test plan generation |
| light | claude-haiku-4-5 | Routine workflow: QA execution, git/GitHub operations |

Model assignments are in `config/agent-models.yaml`. Update models there and run `sync-agent-models.sh` to propagate.
