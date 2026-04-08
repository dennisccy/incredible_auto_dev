# System Overview

## Design Philosophy

The AI Multi-Agent Dev Chain is a reusable framework for running phased software development with Claude AI agents. It enforces quality through a verdict-gated pipeline: each stage must pass before the next runs.

Core principles:

1. **Phased delivery** -- build one phase at a time, stop when done, do not continue automatically.
2. **Artifact-based communication** -- agents communicate only through filesystem artifacts, never free-form conversation.
3. **Verdict-gated progression** -- every pipeline stage produces a machine-readable verdict (PASS/FAIL). FAIL blocks the next stage.
4. **TDD by default** -- the developer agent writes failing tests before implementation.
5. **UI visibility** -- backend capabilities are not "done" until visible to users (when frontend is present).
6. **Security gates** -- all package installs and dangerous commands are intercepted before execution.
7. **Checkpoint/resume** -- interrupted runs resume from the last completed step.

## Component Taxonomy

The framework consists of 6 component types:

### 1. Agents (12 total, in `.claude/agents/`)

Markdown files that define each agent's role, inputs, outputs, and rules. Agents are invoked by automation scripts. Each agent has a model tier assignment (strong/standard/light) defined in `config/agent-models.yaml`.

### 2. Skills (9 total, in `.claude/skills/`)

Reusable instruction files that agents read during their workflow. Skills are not agents -- they are methodologies that agents consume. For example, the `diff-to-ui-impact` skill teaches the ui-impact-analyst how to classify file changes.

### 3. Hooks (5 total, in `.claude/hooks/`)

Shell scripts triggered by Claude Code at specific points (pre-tool-call, post-edit, post-write, on-stop). Hooks enforce security and quality rules automatically.

### 4. Automation Scripts (16 total, in `scripts/automation/`)

Shell scripts that orchestrate the pipeline. The main entry point is `run-phase.sh`, which drives all 11 steps. Individual steps can also be run standalone (e.g., `dev-phase.sh`, `review-phase.sh`).

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
