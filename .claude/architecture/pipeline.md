# Pipeline

This document describes the **phase-mode pipeline**: 11 steps driven by `scripts/automation/run-phase.sh`. Steps 5, 6, and 8 are skipped for backend-only phases (`Frontend Present: no`).

For the **goal-mode pipeline** (an outer loop that wraps this one for adaptive autonomous execution), see [`goal-mode.md`](goal-mode.md). Goal-mode "full" iterations reuse this 11-step pipeline unchanged, just with `--no-finalize` so release happens once at session end.

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
| `post_dev_parallel_complete` | Steps 1-7 (written by `run-phase.sh` after both branches of the post-dev fanout succeed; see [Parallel post-dev fanout](#parallel-post-dev-fanout) below) |
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

## Parallel post-dev fanout

This is the default post-dev path. When `run-phase.sh` reaches Step 4 with `Frontend Present: yes` and none of Steps 4–7 already complete from a prior resume, Steps 4 → 5 → 6 → 6.5 → 7 are replaced with a single **parallel fanout** that runs after Step 3 completes:

```
            (Step 3 review_passed)
                    │
                    ▼
        ┌──── single shared service boot ────┐
        │  (ensure_services_running once)    │
        ▼                                    ▼
  Branch A — UI chain (sequential)     Branch B — QA validate
  ui-impact → ui-test-design           qa-phase.sh
   → browser-qa → demo                 (single-shot, no retry)
        │                                    │
        └─────── wait for both ──────────────┘
                    │
                    ▼
            post_dev_parallel_complete checkpoint
                    │
                    ▼
            Step 8 (ux-regression), then 9, 10, 10.5, 11
```

Key contracts:

- **Shared services.** `run-phase.sh` exports `CHAIN_SHARED_SERVICES=true` before launching the fanout. `browser-qa-phase.sh`, `qa-phase.sh`, and `demo-phase.sh` honor this env var by skipping their own `ensure_services_running` call **and** their own `trap … EXIT` teardown. The caller is responsible for `kill_phase_servers` after the fanout completes. When the fanout doesn't run (backend-only phase, or resume after one of Steps 4–7), the env var is never set and each script manages its own services per its own contract.
- **Soft-fail QA.** If Branch B's qa-phase.sh writes a FAIL verdict, the fanout's `SKIP_QA` flag stays `false` and the existing sequential Step 7 retry loop runs to self-heal (dev → review → qa, up to 3 attempts). This preserves today's QA-retry semantics.
- **Soft-fail UI chain.** A non-zero exit inside Branch A's ui-impact/ui-test-design/browser-qa is logged as a warning but the chain continues to the next step — same "warn and continue" pattern the sequential blocks use. Demo (Step 6.5) is non-gating and never aborts the chain.
- **Signal / quota propagation.** A signal exit (130/137/143) inside either branch is forwarded by `lib/parallel.sh::parallel_run` to the other branch as SIGTERM, then propagated up so `run-phase.sh`'s outer signal guard aborts the run cleanly; the next resume re-runs the fanout. Quota exhaustion (exit 75) propagates immediately so the outer `_run_step` quota loop can sleep and retry.
- **Single checkpoint.** After both branches succeed, `run-phase.sh` writes `current_step: post_dev_parallel_complete` to `runs/<phase>/status.json`. On resume, this label maps to "skip all of Steps 4–7." If the fanout is interrupted mid-batch, the checkpoint stays at the previous step (`review_passed`) and the whole fanout re-runs from scratch.
- **Fallback to sequential.** Backend-only phases (`Frontend Present: no`) and resume runs where any of Steps 4–7 already completed skip the fanout block entirely and run the original sequential Step 4 → 5 → 6 → 6.5 → 7 blocks, each booting and tearing down its own services.

Goal mode: full iterations dispatch through `run-phase.sh --no-finalize`, so the fanout runs there too. Lean iterations (`goal-iter-lean.sh`) have no parallelisable surface — dev → review → browser-qa → demo is strictly sequential — and run as today.
