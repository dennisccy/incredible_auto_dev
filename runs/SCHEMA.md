# Run Artifact Schema

Each phase execution produces artifacts under `runs/<phase>/`.

## status.json

Machine-readable current state of a phase run. Written and updated by automation scripts.
Read by `run-phase.sh` to determine checkpoint resume behavior.

```json
{
  "phase": "<phase>",
  "current_step": "init | planned | test_plan_generated | dev_complete_attempt_N | review_passed | qa_passed | audit_passed | failed",
  "status": "in_progress | complete | blocked | failed",
  "started_at": "2026-01-01T10:00:00Z",
  "updated_at": "2026-01-01T11:30:00Z",
  "blockers": [],
  "changed_files": ["src/api/routes/resource.py"],
  "tests_run": true,
  "browser_checks_run": false,
  "next_action": "finalize | fix_review | fix_qa | fix_audit | none"
}
```

### current_step resume behavior

| `current_step` | Steps skipped on resume |
|---|---|
| `planned` | Plan |
| `test_plan_generated` | Plan, test plan |
| `dev_complete_attempt_*` | Plan, test plan; first dev pass (review re-runs) |
| `review_passed` | Plan, test plan, dev+review |
| `qa_passed` | Plan, test plan, dev+review, QA — audit and finalize run |
| `audit_passed` | Plan, test plan, dev+review, QA, audit — only finalize runs |
| `summary.json` has `status: "finalized"` | All steps — exits immediately |

### blockers format

Each entry in `blockers` is a string describing what is blocking progress:
```json
"blockers": ["QA failed: TC-03 state transition not enforced", "Review: missing input validation on POST /api/v1/resource"]
```

### changed_files

List of paths (relative to repo root) modified during dev. Used by the auditor agent to know which source files to inspect.

---

## summary.json

Human-readable final summary of a completed phase. Written by `finalize-phase.sh`.

```json
{
  "phase": "<phase>",
  "status": "finalized",
  "qa_passed": true,
  "audit_passed": true,
  "finalized_at": "2026-01-01T12:00:00Z",
  "artifacts": {
    "plan": "runs/<phase>/plan.md",
    "test_plan": "reports/qa/<phase>-test-plan.md",
    "review_report": "reports/reviews/<phase>-review.md",
    "qa_report": "reports/qa/<phase>-qa.md",
    "audit_report": "docs/handoffs/<phase>-audit.md",
    "status": "runs/<phase>/status.json"
  }
}
```

---

## plan.md

Written by the orchestrator agent at the start of each phase. Read by all subsequent agents.

Required fields (machine-read by scripts):
```
Frontend Present: yes
```
or
```
Frontend Present: no
```

This line controls whether `dev-phase.sh` runs the second frontend pass and whether `qa-phase.sh` runs Chrome MCP browser checks.

---

## UI Audit Artifacts

### reports/qa/\<phase\>-ui-audit.md

Optional standalone UI evolution audit, produced by `./scripts/automation/ui-audit-phase.sh <phase>`.
Also included as a section inside `reports/qa/<phase>-qa.md` when `Frontend Present: yes`.

```markdown
## UI Evolution Audit — <phase>

**Verdict:** UI-PASS | UI-PASS-WITH-GAPS | UI-FAIL

### Questions answered
1. Did the UI evolve to reflect the phase's new capability? <answer>
2. Can the user see/understand/control the new capability? <answer>
3. Is the UI still relying on old generic pages? <answer>
4. Is the implementation underexposed product-wise? <answer>

### Gaps (if any)
- <gap description>

### Recommendation
<action or none>
```

---

## Artifact locations (all phases)

| Artifact | Path |
|---|---|
| Phase spec | `docs/phases/<phase>-<name>.md` |
| Execution plan | `runs/<phase>/plan.md` |
| Phase status | `runs/<phase>/status.json` |
| Phase summary | `runs/<phase>/summary.json` |
| Test plan | `reports/qa/<phase>-test-plan.md` |
| Review report | `reports/reviews/<phase>-review.md` |
| QA report | `reports/qa/<phase>-qa.md` |
| UI audit report | `reports/qa/<phase>-ui-audit.md` |
| Audit report | `docs/handoffs/<phase>-audit.md` |
| Dev handoff | `docs/handoffs/<phase>-dev.md` |
| Frontend handoff | `docs/handoffs/<phase>-frontend.md` |
