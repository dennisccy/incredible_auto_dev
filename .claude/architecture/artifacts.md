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

## Backend-Only N/A Stubs

When `Frontend Present: no`, the pipeline writes N/A stub files for the 6 UI visibility artifacts automatically via `write_na_ui_artifacts()` in `lib/common.sh`. These stubs:

- Contain the phase number and a "Backend-only phase" status line
- Are accepted by the phase-closure-auditor as valid for backend-only phases
- Are written only if the file does not already exist (no overwriting)
