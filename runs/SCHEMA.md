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
| `ui_impact_complete` | Plan, test plan, dev+review, UI impact analysis |
| `ui_test_designed` | Plan, test plan, dev+review, UI impact, UI test design |
| `browser_qa_complete` | Plan through browser QA |
| `ux_regression_complete` | Plan through UX regression review |
| `closure_passed` | All steps — only finalize runs |
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
| Implementation summary | `reports/phase-{N}-implementation-summary.md` |
| User-visible changes | `reports/phase-{N}-user-visible-changes.md` |
| UI surface map | `reports/phase-{N}-ui-surface-map.md` |
| UI test plan | `reports/phase-{N}-ui-test-plan.md` |
| UI test results | `reports/phase-{N}-ui-test-results.md` |
| What to click | `reports/phase-{N}-what-to-click.md` |
| UX regression report | `reports/phase-{N}-ux-regression.md` |
| Closure verdict | `reports/phase-{N}-closure-verdict.md` |

---

## UI Visibility Artifacts (per phase, in `reports/`)

Six artifacts are produced for every phase. For backend-only phases (`Frontend Present: no`), N/A stubs are written automatically.

### reports/phase-{N}-implementation-summary.md

Written by the developer as part of the dev handoff. Contains:
- Features implemented (plain-language, not code)
- Changed behavior (existing features that work differently)
- Backend-only items (complete but not UI-wired)
- Incomplete items (deferred or partial)
- Config/env changes
- Known limitations

### reports/phase-{N}-user-visible-changes.md

Written by the ui-impact-analyst. Contains:
- What users can now do
- What changed in the visible UI
- Behavior changes
- Not-visible-yet items (backend without UI)

### reports/phase-{N}-ui-surface-map.md

Written by the ui-impact-analyst. A table of every affected route, page, component, form, modal, table, chart, or navigation element. Each row has: route/page, component/element, change type, why changed, what to test (specific action).

### reports/phase-{N}-ui-test-plan.md

Written by the ui-test-designer. Structured test cases (UT-01, UT-02, ...) with:
- Type: smoke | happy-path | validation | error | regression | ux
- Exact numbered steps with specific URLs, button text, field names
- Exact expected results visible to the operator

### reports/phase-{N}-ui-test-results.md

Written by the browser-qa-agent. Contains:
- Browser QA Verdict: PASS | FAIL | SKIPPED
- Results table (test ID, expected, actual, verdict, evidence path)
- Per-test detail for failures and skips
- Environment info

### reports/phase-{N}-what-to-click.md

Written by the ui-test-designer. A 3–10 step operator guide to verify the phase in under 5 minutes. Contains exact URLs, exact actions, and exact expected outcomes. No developer knowledge required to follow.

### reports/phase-{N}-closure-verdict.md

Written by the phase-closure-auditor. Final gate before finalize. Contains:
- **Verdict:** CLOSURE-PASS | CLOSURE-FAIL
- Standard pipeline gate checks
- UI artifact existence and quality checks
- Cross-reference consistency checks
- Blocking issues (if any)
