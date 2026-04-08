# Pipeline

The pipeline has 11 steps, driven by `scripts/automation/run-phase.sh`. Steps 5, 6, and 8 are skipped for backend-only phases (`Frontend Present: no`).

## Steps

| Step | Name | Script | Agent | Key Output |
|------|------|--------|-------|------------|
| 1 | Plan | `run-phase.sh` (inline) | orchestrator | `runs/<phase>/plan.md` |
| 2 | Test Plan | `generate-test-plan.sh` | qa (mode: generate) | `reports/qa/<phase>-test-plan.md` |
| 3 | Dev + Review | `dev-phase.sh` + `review-phase.sh` | developer, reviewer | `docs/handoffs/<phase>-dev.md`, `reports/reviews/<phase>-review.md` |
| 4 | UI Impact Analysis | `ui-impact-phase.sh` | ui-impact-analyst | `reports/phase-{N}-user-visible-changes.md`, `reports/phase-{N}-ui-surface-map.md` |
| 5 | UI Test Design | `ui-test-design-phase.sh` | ui-test-designer | `reports/phase-{N}-ui-test-plan.md`, `reports/phase-{N}-what-to-click.md` |
| 6 | Browser QA | `browser-qa-phase.sh` | browser-qa-agent | `reports/phase-{N}-ui-test-results.md` |
| 7 | QA Validation | `qa-phase.sh` | qa (mode: validate) | `reports/qa/<phase>-qa.md` |
| 8 | UX Regression Review | `ux-regression-phase.sh` | ux-regression-reviewer | `reports/phase-{N}-ux-regression.md` |
| 9 | Audit | `phase-audit.sh` | auditor | `docs/handoffs/<phase>-audit.md` |
| 10 | Phase Closure | `phase-closure-check.sh` | phase-closure-auditor | `reports/phase-{N}-closure-verdict.md` |
| 11 | Finalize | `finalize-phase.sh` | release-manager | `runs/<phase>/summary.json`, PR |

## Data Flow

```
Phase spec (docs/phases/<phase>.md)
    |
    v
[Step 1] orchestrator --> plan.md
    |
    v
[Step 2] qa (generate) --> test-plan.md
    |
    v
[Step 3] developer --> dev-handoff + implementation-summary
         reviewer  --> review-report
         (loop: max 3 attempts on FAIL)
    |
    v
[Step 4] ui-impact-analyst --> user-visible-changes + ui-surface-map
    |
    v
[Step 5*] ui-test-designer --> ui-test-plan + what-to-click
    |
    v
[Step 6*] browser-qa-agent --> ui-test-results
    |
    v
[Step 7] qa (validate) --> qa-report
         (loop: max 3 attempts on FAIL)
    |
    v
[Step 8*] ux-regression-reviewer --> ux-regression-report
    |
    v
[Step 9] auditor --> audit-report
         (loop: max 2 attempts on FAIL)
    |
    v
[Step 10] phase-closure-auditor --> closure-verdict
    |
    v
[Step 11] release-manager --> summary.json + branch + commit + PR

* Steps 5, 6, 8 skipped when Frontend Present: no (N/A stubs written automatically)
```

## Retry Loops

| Loop | Max Attempts | On FAIL |
|------|-------------|---------|
| Dev + Review | 3 | Developer fixes issues listed in review report, reviewer re-evaluates |
| QA | 3 | Developer fixes, reviewer confirms, QA re-validates |
| Audit | 2 | Developer + reviewer + QA re-run before auditor re-evaluates |

After max retries are exhausted, the pipeline halts with FAILED status.

## Checkpoint / Resume

Every step updates `runs/<phase>/status.json` with the current step name. If a run is interrupted, re-running `run-phase.sh` resumes from the last completed step.

| `current_step` value | Steps skipped on resume |
|---------------------|------------------------|
| `planned` | Step 1 |
| `test_plan_generated` | Steps 1-2 |
| `dev_complete_attempt_N` | Steps 1-2; dev re-runs from review |
| `review_passed` | Steps 1-3 |
| `ui_impact_complete` | Steps 1-4 |
| `ui_test_designed` | Steps 1-5 |
| `browser_qa_complete` | Steps 1-6 |
| `qa_passed` | Steps 1-7 |
| `ux_regression_complete` | Steps 1-8 |
| `audit_passed` | Steps 1-9 |
| `closure_passed` | Steps 1-10 |
| `summary.json` finalized | All steps -- exits immediately |

Use `--reset` flag to clear checkpoints and re-run all steps from scratch.

## Backend-Only Skip Logic

When the plan contains `Frontend Present: no`:

- Steps 5 (UI test design), 6 (browser QA), and 8 (UX regression) are skipped
- N/A stub files are written automatically by `write_na_ui_artifacts()` in `lib/common.sh`
- Step 4 (UI impact) still runs but writes N/A stubs
- Step 10 (phase closure) accepts N/A stubs for backend-only phases
