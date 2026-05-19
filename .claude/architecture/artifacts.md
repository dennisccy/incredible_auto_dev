# Artifacts

All inter-agent communication happens through filesystem artifacts. This document maps every artifact type, its path, producer, consumers, and format.

## Core Pipeline Artifacts

| Artifact | Path | Producer | Consumers |
|----------|------|----------|-----------|
| Phase spec | `docs/phases/<phase>.md` | Human | All agents |
| Execution plan | `runs/<phase>/plan.md` | orchestrator | developer, reviewer, qa, auditor, all UI agents |
| Test plan | `reports/qa/<phase>-test-plan.md` | qa (generate mode) | qa (validate mode), ui-test-designer |
| Dev handoff | `docs/handoffs/<phase>-dev.md` | developer | reviewer, qa, auditor, ui-impact-analyst |
| Frontend handoff | `docs/handoffs/<phase>-frontend.md` | developer | reviewer, qa, auditor, ui-impact-analyst |
| Review report | `reports/reviews/<phase>-review.md` | reviewer | qa, developer (fix mode) |
| QA report | `reports/qa/<phase>-qa.md` | qa (validate mode) | auditor, release-manager |
| Audit report | `docs/handoffs/<phase>-audit.md` | auditor | release-manager, phase-closure-auditor |
| Phase status | `runs/<phase>/status.json` | scripts + agents | scripts (checkpoint/resume) |
| Phase summary | `runs/<phase>/summary.json` | finalize-phase.sh | release-manager |
| Project goal | `docs/goal.md` | Human | orchestrator, developer, reviewer, qa |
| Project architecture | `docs/architecture/*.md` | update-docs.sh | orchestrator, developer |

## UI Visibility Artifacts (6 per phase)

| Artifact | Path | Producer | Consumers |
|----------|------|----------|-----------|
| Implementation summary | `reports/phase-{N}-implementation-summary.md` | developer | ui-impact-analyst, phase-closure-auditor |
| User-visible changes | `reports/phase-{N}-user-visible-changes.md` | ui-impact-analyst | ui-test-designer, ux-regression-reviewer, phase-closure-auditor |
| UI surface map | `reports/phase-{N}-ui-surface-map.md` | ui-impact-analyst | ui-test-designer, browser-qa-agent, ux-regression-reviewer |
| UI test plan | `reports/phase-{N}-ui-test-plan.md` | ui-test-designer | browser-qa-agent, phase-closure-auditor |
| UI test results | `reports/phase-{N}-ui-test-results.md` | browser-qa-agent | ux-regression-reviewer, phase-closure-auditor |
| What to click | `reports/phase-{N}-what-to-click.md` | ui-test-designer | operator (human), phase-closure-auditor |

## Additional Artifacts

| Artifact | Path | Producer | Consumers |
|----------|------|----------|-----------|
| UX regression report | `reports/phase-{N}-ux-regression.md` | ux-regression-reviewer | phase-closure-auditor |
| Closure verdict | `reports/phase-{N}-closure-verdict.md` | phase-closure-auditor | finalize-phase.sh |
| UI audit report | `reports/qa/<phase>-ui-audit.md` | ui-audit-phase.sh | qa (standalone) |
| Browser evidence | `reports/qa/<phase>-evidence/*.png` | browser-qa-agent | phase-closure-auditor |
| Iteration summary (MD) | `reports/phase-<phase>-iteration-summary.md` | iteration-summarizer | render_iteration_summary.py, human |
| HTML iteration summary | `reports/phase-<phase>-summary.html` | render_iteration_summary.py | human |
| Goal-mode session index | `reports/goal-session-<sid>-index.html` | render_iteration_summary.py | human |
| Demo script | `reports/phase-<phase>-demo-script.md` | demo-narrator | render_iteration_summary.py, human |
| Demo results | `reports/phase-<phase>-demo-results.md` | demo-narrator | render_iteration_summary.py, human |
| Demo screenshots | `reports/demo/<phase>/step-NN.png` | demo-narrator | render_iteration_summary.py |
| Cumulative project story | `runs/goal-session-<sid>/state/project-story.md` | iteration-summarizer (goal mode) | render_iteration_summary.py, human |
| Delivered wrap (MD) | `reports/goal-session-<sid>-delivered.md` | iteration-summarizer (delivered mode, GOAL_ACHIEVED only) | render_iteration_summary.py, human |
| Delivered wrap (HTML) | `reports/goal-session-<sid>-delivered.html` | render_iteration_summary.py (`delivered` command) | human |
| Install decisions | `reports/security/install-decisions.jsonl` | install-security-gate.sh | human review |
| Framework architecture | `.claude/architecture/*.md` | update-docs.sh | all agents (reference) |

## Verdict Formats

All verdicts use the prefix `**Verdict:**` followed by the exact value. Scripts parse this line by machine via `verdicts.py`.

| Report | Valid Verdicts |
|--------|---------------|
| Review | `PASS`, `PASS_WITH_NOTES`, `FAIL` |
| QA | `PASS`, `PASS_WITH_NOTES`, `FAIL` |
| Audit | `PASS`, `PASS_WITH_GAPS`, `FAIL` |
| UI Evolution (in QA) | `UI-PASS`, `UI-PASS-WITH-GAPS`, `UI-FAIL` |
| Browser QA | `PASS`, `FAIL`, `SKIPPED` |
| Phase Closure | `CLOSURE-PASS`, `CLOSURE-FAIL` |
| UX Regression | `UX-REGRESSION-PASS`, `UX-REGRESSION-WARN`, `UX-REGRESSION-FAIL` |
| Iteration summary | `GOAL_ACHIEVED`, `CONTINUE`, `ESCALATE`, `REGRESSION`, `STALLED`, `PASS`, `FAIL`, `IN-PROGRESS` |
| Demo results | `RECORDED`, `RECORDED_WITH_NOTES`, `SKIPPED`, `NOT_YET` (showcase, never blocks the pipeline) |

## Backend-Only N/A Stubs

When `Frontend Present: no`, the pipeline writes N/A stub files for the 6 UI visibility artifacts automatically via `write_na_ui_artifacts()` in `lib/common.sh`. These stubs:

- Contain the phase number and a "Backend-only phase" status line
- Are accepted by the phase-closure-auditor as valid for backend-only phases
- Are written only if the file does not already exist (no overwriting)

## Goal-Mode Artifacts

Goal mode adds a parallel artifact tree under `runs/goal-session-<sid>/`. Per-iteration code/test artifacts still use the existing `runs/<iter-name>/` and `reports/...<iter-name>...` paths, where the iteration name `goal-<sid>-iter-<N>` is treated as a "phase name" — so all phase-mode artifacts above are produced for goal-mode iterations too.

| Artifact | Path | Producer | Consumers |
|----------|------|----------|-----------|
| Goal spec (extended) | `docs/goal.md` (with Must-have user journeys + Anti-goals sections) | Human | goal-decomposer, goal-evaluator, all phase agents |
| Iteration spec | `docs/phases/goal-<sid>-iter-<N>.md` | goal-decomposer | run-phase.sh (full) or goal-iter-lean.sh (lean), then all downstream agents |
| Session state | `runs/goal-session-<sid>/session.json` | run-goal.sh | run-goal.sh (resume, halt arithmetic) |
| Journey history | `runs/goal-session-<sid>/state/journey-history.json` | goal-evaluator | goal-decomposer (next-step planning), goal-evaluator (regression detection), run-goal.sh (stall detection via hash) |
| Evaluator log | `runs/goal-session-<sid>/state/evaluator-log.md` | goal-evaluator (append-only) | goal-decomposer (read last 3 entries) |
| Iter eval | `runs/goal-session-<sid>/iter-<N>/eval.md` | goal-evaluator | run-goal.sh (verdict parsing) |
| Telemetry | `runs/goal-session-<sid>/telemetry.jsonl` | run-goal.sh + goal-iter-lean.sh + lib/telemetry.sh | analysis tools (jq), future self-evolution loop (deferred) |
| History hashes | `runs/goal-session-<sid>/.history-hashes` | run-goal.sh | run-goal.sh (stall detection) |
| Session summary | `runs/goal-session-<sid>/summary.md` | run-goal.sh (on halt) | Human |

### journey-history.json schema

```json
{
  "journeys": {
    "J-01": {
      "id": "J-01",
      "name": "Sign up and log in",
      "status": "passing | failing | partial | already_passing | regressed | unknown",
      "last_verified_iter": "goal-<sid>-iter-<N>",
      "last_passing_iter": "goal-<sid>-iter-<N> | null",
      "first_seen_iter": "goal-<sid>-iter-<N>",
      "last_evidence_path": "reports/qa/<iter-name>-evidence/UT-J-01-*.png"
    }
  },
  "anti_goal_violations": [
    {
      "iter": "goal-<sid>-iter-<N>",
      "anti_goal": "verbatim text from goal.md",
      "severity": "critical | minor",
      "evidence": "file:line or commit description",
      "resolved": false
    }
  ],
  "updated_at": "<ISO timestamp>"
}
```

### Telemetry schema

See [`docs/goal-mode-telemetry.md`](../../docs/goal-mode-telemetry.md). Each line of `telemetry.jsonl` is one JSON object with common fields (`ts`, `session_id`, `iter`, `event`) plus event-specific fields. Stable across schema versions: consumers should ignore unknown event types and unknown fields.

### Goal-mode verdicts

The goal-evaluator emits one of:
| Verdict | Meaning |
|---|---|
| `GOAL_ACHIEVED` | All Must-have journeys pass, no critical anti-goal violations. Loop halts with success. |
| `CONTINUE` | Progress made or actionable next work identified. Loop continues. |
| `ESCALATE` | Lean iteration uncovered ambiguity; next iteration MUST run as full. |
| `REGRESSION` | A previously-passing journey now fails OR a critical anti-goal was violated. Halts for human review. |
| `STALLED` | Evaluator-side judgment that no productive next work is identifiable. Halts. |

The outer loop also emits halt verdicts of its own (`BUDGET_EXHAUSTED`, `STALLED` via hash detection, `REGRESSION_HALT`, `ABORTED`) into `session.json.status`.
