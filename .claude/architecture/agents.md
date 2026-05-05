# Agents

The framework defines 14 agents in `.claude/agents/`. Each agent has a model tier assignment in `config/agent-models.yaml`. Twelve agents serve the phase pipeline; two are specific to goal mode.

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

## Goal Mode Agents (2)

These agents are invoked only by the goal-mode pipeline (`run-goal.sh` and `goal-iter-lean.sh`). Phase mode does not use them. See [`goal-mode.md`](goal-mode.md) for how they fit into the loop.

### goal-decomposer
- **File:** `.claude/agents/goal-decomposer.md`
- **Model:** strong (claude-opus-4-7)
- **Pipeline step:** Goal-mode iteration step 1 (planning)
- **Inputs:** CLAUDE.md, project-template.md, `docs/goal.md` (especially Must-have user journeys + Anti-goals), `runs/goal-session-<sid>/state/journey-history.json`, last 3 entries of `runs/goal-session-<sid>/state/evaluator-log.md`, prior iteration's `eval.md`, codebase state via Glob/Grep/Read
- **Output:** `docs/phases/goal-<sid>-iter-<N>.md` — a phase-spec-shaped iter spec with Goal Mode Metadata (Mode: baseline|next, Depth: lean|full, Target journeys, Required-still-passing journeys, Anti-goal reminders)
- **Role:** Plans the next goal-mode iteration. Two modes:
  - `Mode: baseline` (iter 0): writes a verify-only spec; no code changes; lists ALL Must-have journeys as targets so browser-qa establishes which already pass.
  - `Mode: next` (iter 1+): picks the next 1-3 failing/partial journeys, decides depth based on risk and prior evaluator feedback, writes a tight scoped spec.

### goal-evaluator
- **File:** `.claude/agents/goal-evaluator.md`
- **Model:** strong (claude-opus-4-7)
- **Pipeline step:** Goal-mode iteration step 3 (judgment)
- **Inputs:** `docs/goal.md`, the iter spec, all iteration artifacts (dev handoff, review report, QA report, audit handoff for full mode), browser-qa results, evidence screenshots, prior `journey-history.json`, prior evaluator-log entries
- **Output:** `runs/goal-session-<sid>/iter-<N>/eval.md` (verdict + recommendation), updated `journey-history.json` (full atomic write), appended `evaluator-log.md` entry
- **Verdicts:** `GOAL_ACHIEVED` (halt success), `CONTINUE` (loop), `ESCALATE` (next iter must be full), `REGRESSION` (halt for human review), `STALLED` (halt — evaluator-driven, separate from script-side hash detection)
- **Role:** Skeptical, evidence-grounded judge of iteration outcomes. Verifies journey claims by reading actual browser-qa results and screenshots, not summaries. Anchors `GOAL_ACHIEVED` decisions on objective journey evidence + anti-goal compliance.

## Agent Versioning

Each agent file in `.claude/agents/` carries a semantic version and last-updated date in its frontmatter:

```yaml
---
name: <agent>
description: <one-line role>
model: <claude-model-id>
tools: [...]                         # optional — Claude Code tool list
version: 1.0.0
last_updated: YYYY-MM-DD
disallowed_tools: ["Bash(rm -rf *)"] # optional — added to default deny list
max_budget_usd: 1.50                 # optional — per-invocation hard cap
---
```

**When to bump version:**

- Patch (`1.0.0 → 1.0.1`): typo or wording fix that does not change agent behavior.
- Minor (`1.0.0 → 1.1.0`): adds new instructions, optional inputs/outputs, or capabilities without breaking existing pipeline contracts.
- Major (`1.0.0 → 2.0.0`): changes the agent's contract — output format, mandatory inputs, model tier — in a way that downstream agents or scripts must be aware of.

`last_updated` is the date of the most recent meaningful edit (any version bump). Always update it together with the version.

Git history is the source of truth for what changed; the version field exists so a downstream system or eval suite can detect that an agent has changed without diffing the file. The framework does not gate on version equality — the field is informational.

## Per-Agent Permissions and Budget

`lib/quota-retry.sh::claude_with_quota_retry` reads `CHAIN_CURRENT_AGENT` (set by `record_agent_invocation_start`) and overlays:

- **Disallowed tools** — `lib/agent_permissions.py disallowed <agent>` returns the list of `--disallowedTools` patterns. Built from a hardcoded default deny list plus the optional `disallowed_tools:` field in the agent's frontmatter.
  - Hardcoded default for **all agents**: filesystem-destroying patterns (`Bash(rm -rf /*)`) and force-pushes to `main`/`master`.
  - Hardcoded default for **all agents except release-manager**: `Bash(git push *)`, `Bash(gh pr merge *)`, `Bash(gh pr close *)`, `Bash(gh release *)`, `Bash(git tag *)`. Only release-manager can publish.
- **Budget cap** — `lib/agent_permissions.py budget <agent>` returns `max_budget_usd` if set, which is then passed to claude as `--max-budget-usd`. Opt-in per agent — no defaults; you set this only on agents whose cost you want capped.

Disable the overlay (e.g. for debugging) with `CHAIN_DISABLE_PERMISSION_ISOLATION=true`.

`lib/agent_permissions.py self-test` exercises the lookup logic. The eval suite (`scripts/automation/run-evals.sh`) runs the self-test on every CI run.
