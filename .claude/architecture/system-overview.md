# System Overview

## Design Philosophy

The AI Multi-Agent Dev Chain is a reusable framework for software development with Claude AI agents. It enforces quality through a verdict-gated pipeline: each stage must pass before the next runs.

The framework supports two modes:
- **Phase mode** — human-authored phase specs, executed one at a time. Maximum control.
- **Goal mode** — a goal-driven outer loop iterates `decompose → execute → evaluate` adaptively until an AI evaluator declares the goal achieved. Maximum autonomy. See [`goal-mode.md`](goal-mode.md).

Both modes share all agents and skills. Phase mode is the default and stays the right choice when you have a clear roadmap; goal mode handles the case where the user has a vision but not a step-by-step plan.

Core principles (apply to both modes):

1. **Bounded delivery** -- build only what the current iteration calls for, stop when done, do not continue automatically (in phase mode: per phase; in goal mode: per iteration).
2. **Artifact-based communication** -- agents communicate only through filesystem artifacts, never free-form conversation.
3. **Verdict-gated progression** -- every pipeline stage produces a machine-readable verdict (PASS/FAIL). FAIL blocks the next stage.
4. **TDD by default** -- the developer agent writes failing tests before implementation.
5. **UI visibility** -- backend capabilities are not "done" until visible to users (when frontend is present).
6. **Security gates** -- all package installs and dangerous commands are intercepted before execution.
7. **Checkpoint/resume** -- interrupted runs resume from the last completed step.

## Component Taxonomy

The framework consists of 6 component types:

### 1. Agents (14 total, in `.claude/agents/`)

Markdown files that define each agent's role, inputs, outputs, and rules. Agents are invoked by automation scripts. Each agent has a model tier assignment (strong/standard/light) defined in `config/agent-models.yaml`.

Twelve agents serve the phase pipeline (orchestrator, developer, reviewer, qa, auditor, release-manager, product-manager, ui-impact-analyst, ui-test-designer, browser-qa-agent, ux-regression-reviewer, phase-closure-auditor). Two agents are specific to goal mode (goal-decomposer, goal-evaluator). Goal mode reuses all twelve phase agents unchanged.

### 2. Skills (9 total, in `.claude/skills/`)

Reusable instruction files that agents read during their workflow. Skills are not agents -- they are methodologies that agents consume. For example, the `diff-to-ui-impact` skill teaches the ui-impact-analyst how to classify file changes.

### 3. Hooks (5 total, in `.claude/hooks/`)

Shell scripts triggered by Claude Code at specific points (pre-tool-call, post-edit, post-write, on-stop). Hooks enforce security and quality rules automatically.

### 4. Automation Scripts (18 total, in `scripts/automation/`)

Shell scripts that orchestrate the pipelines. Two top-level entry points:
- `run-phase.sh <phase-name>` drives the 11-step phase pipeline.
- `run-goal.sh --session-id <id>` drives the goal-mode outer loop, which dispatches `goal-iter-lean.sh` for lean iterations and reuses `run-phase.sh --no-finalize` for full iterations.

Individual phase steps can also be run standalone (e.g., `dev-phase.sh`, `review-phase.sh`). Goal mode also adds `lib/telemetry.sh` for structured event capture.

### 5. Templates (13 total, in `templates/`)

Markdown templates for all artifact types. Agents use these as format references when writing reports, handoffs, and verdicts.

### 6. Configuration (4 files)

- `.claude/project-template.md` -- project-specific stack, commands, principles
- `config/agent-models.yaml` -- agent-to-model-tier mapping
- `config/install-security-policy.json` -- supply-chain security policy
- `.claude/settings.json` -- Claude Code tool permissions

## How Components Relate

```
CLAUDE.md (constitution)
    |
    +-- .claude/core.md (universal rules)
    +-- .claude/workflow.md (pipeline definition)
    +-- .claude/project-template.md (project config)
    +-- .claude/anti-patterns.md (failure modes)
    |
    +-- .claude/agents/*.md (12 agent definitions)
    |       |
    |       +-- read .claude/skills/*.md (9 skills)
    |
    +-- .claude/hooks/*.sh (5 hooks, triggered by Claude Code)
    |
    +-- scripts/automation/*.sh (16 scripts)
    |       |
    |       +-- lib/common.sh (shared functions)
    |       +-- lib/quota-retry.sh (quota handling)
    |       +-- lib/verdicts.py (verdict parsing)
    |
    +-- config/ (agent-models.yaml, install-security-policy.json)
    +-- templates/ (13 artifact templates)
    +-- runs/<phase>/ (runtime artifacts: status.json, plan.md, summary.json)
```

## Adoption Model

The framework is designed to be added to existing project repos as a subrepo (submodule or subtree). Framework files live under `.claude/`, `scripts/`, `config/`, and `templates/` -- directories that do not conflict with typical project layouts.

Each project fills in:
1. `docs/goal.md` -- project vision, success criteria, key capabilities
2. `.claude/project-template.md` -- stack, test commands, architecture principles
3. `docs/phases/<phase>.md` -- phase specs with definition of done

See [adoption-guide.md](adoption-guide.md) for the full procedure.
