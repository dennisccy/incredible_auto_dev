# Agents

The framework defines 12 agents in `.claude/agents/`. Each agent has a model tier assignment in `config/agent-models.yaml`.

## Model Tiers

| Tier | Model | Used for |
|------|-------|----------|
| strong | claude-opus-4-6 | Complex reasoning: planning, code generation, auditing |
| standard | claude-sonnet-4-6 | Solid tasks: code review, UI analysis, test design |
| light | claude-haiku-4-5 | Routine workflow: QA execution, git operations |

## Core Pipeline Agents (7)

### orchestrator
- **File:** `.claude/agents/orchestrator.md`
- **Model:** strong (claude-opus-4-6)
- **Pipeline step:** 1 (Plan)
- **Inputs:** CLAUDE.md, project-template.md, phase spec, docs/goal.md, prior handoffs
- **Output:** `runs/<phase>/plan.md`
- **Role:** Reads the phase spec and writes a concise execution plan. Does not implement code or run commands.

### developer
- **File:** `.claude/agents/developer.md`
- **Model:** strong (claude-opus-4-6)
- **Pipeline step:** 3 (Dev + Review loop)
- **Inputs:** plan.md, phase spec, project-template.md, existing code, review/QA reports (fix mode)
- **Outputs:** implementation code, `docs/handoffs/<phase>-dev.md`, `reports/phase-{N}-implementation-summary.md`
- **Role:** Implements changes using TDD. Handles both backend and frontend. In fix mode, reads failing reports and fixes only listed issues.

### reviewer
- **File:** `.claude/agents/reviewer.md`
- **Model:** standard (claude-sonnet-4-6)
- **Pipeline step:** 3 (Dev + Review loop)
- **Inputs:** dev handoff, phase spec, changed files, git diff
- **Output:** `reports/reviews/<phase>-review.md`
- **Role:** Reviews code for correctness, spec compliance, and architecture standards. Never edits source files.

### qa
- **File:** `.claude/agents/qa.md`
- **Model:** light (claude-haiku-4-5)
- **Pipeline steps:** 2 (Test Plan) and 7 (QA Validation)
- **Mode 1 inputs:** phase spec, plan
- **Mode 1 output:** `reports/qa/<phase>-test-plan.md`
- **Mode 2 inputs:** plan, review report, dev handoff, test plan, project-template.md
- **Mode 2 output:** `reports/qa/<phase>-qa.md`
- **Role:** Two modes -- (1) derives functional test cases from spec before dev, (2) validates implementation by running tests and executing test plan.

### auditor
- **File:** `.claude/agents/auditor.md`
- **Model:** strong (claude-opus-4-6)
- **Pipeline step:** 9 (Audit)
- **Inputs:** phase spec, plan, dev handoff, review report, QA report, test plan, actual source files
- **Output:** `docs/handoffs/<phase>-audit.md`
- **Role:** Skeptical post-QA assessment. Reads actual source code, not summaries. May apply fixes for critical issues.

### release-manager
- **File:** `.claude/agents/release-manager.md`
- **Model:** light (claude-haiku-4-5)
- **Pipeline step:** 11 (Finalize)
- **Inputs:** QA report, dev handoff, summary.json, project-template.md
- **Output:** git branch, commit, PR
- **Role:** Git and GitHub operations -- branch creation, commit, push, PR. Adapts behavior based on gh auth availability.

### product-manager
- **File:** `.claude/agents/product-manager.md`
- **Model:** strong (claude-opus-4-6)
- **Pipeline step:** Optional (before Step 1)
- **Inputs:** phase spec, existing codebase, project-template.md
- **Output:** `docs/plans/<date>-<phase>-plan.md`
- **Role:** Optional architecture planning for complex phases. Produces detailed implementation plans. Does not write code.

## UI Visibility Agents (5)

### ui-impact-analyst
- **File:** `.claude/agents/ui-impact-analyst.md`
- **Model:** standard (claude-sonnet-4-6)
- **Pipeline step:** 4 (UI Impact Analysis)
- **Inputs:** dev handoff, frontend handoff, plan, phase spec, changed files
- **Skills used:** `diff-to-ui-impact`, `visible-change-summarizer`, `ui-workflow-inference`
- **Outputs:** `reports/phase-{N}-user-visible-changes.md`, `reports/phase-{N}-ui-surface-map.md`
- **Role:** Translates code changes into user-visible impact. Classifies each changed file by UI impact type.

### ui-test-designer
- **File:** `.claude/agents/ui-test-designer.md`
- **Model:** standard (claude-sonnet-4-6)
- **Pipeline step:** 5 (UI Test Design)
- **Inputs:** user-visible-changes, ui-surface-map, phase spec, functional test plan
- **Skills used:** `manual-ui-test-plan-generator`, `what-to-click-writer`
- **Outputs:** `reports/phase-{N}-ui-test-plan.md`, `reports/phase-{N}-what-to-click.md`
- **Role:** Converts UI impact analysis into structured test plans with exact click paths and a 5-minute operator verification guide.

### browser-qa-agent
- **File:** `.claude/agents/browser-qa-agent.md`
- **Model:** standard (claude-sonnet-4-6)
- **Pipeline step:** 6 (Browser QA)
- **Inputs:** ui-test-plan, ui-surface-map
- **Skills used:** `browser-workflow-executor`
- **Output:** `reports/phase-{N}-ui-test-results.md`
- **Role:** Executes browser-based UI tests using Chrome MCP. Records pass/fail with evidence screenshots.

### ux-regression-reviewer
- **File:** `.claude/agents/ux-regression-reviewer.md`
- **Model:** standard (claude-sonnet-4-6)
- **Pipeline step:** 8 (UX Regression Review)
- **Inputs:** user-visible-changes, ui-surface-map, ui-test-results, prior phase handoffs
- **Skills used:** `ui-regression-scout`
- **Output:** `reports/phase-{N}-ux-regression.md`
- **Role:** Checks that the UI evolved with new capabilities. Flags hidden, undiscoverable, or regressed features.

### phase-closure-auditor
- **File:** `.claude/agents/phase-closure-auditor.md`
- **Model:** standard (claude-sonnet-4-6)
- **Pipeline step:** 10 (Phase Closure)
- **Inputs:** all pipeline verdicts, all 6 UI visibility artifacts, phase spec, plan
- **Skills used:** `phase-closure-gate`
- **Output:** `reports/phase-{N}-closure-verdict.md`
- **Role:** Final gate before finalize. Validates all UI artifacts exist, are non-vague, and are consistent. Blocks false completion.
