# AI Multi-Agent Dev Chain -- Architecture Docs

This directory contains the framework's architecture documentation. These docs describe how the framework itself works, not any particular project using it.

## Contents

| Document | What it covers |
|----------|---------------|
| [system-overview.md](system-overview.md) | Design philosophy, component taxonomy, how components relate |
| [pipeline.md](pipeline.md) | 11-step pipeline with data flow, retry loops, checkpoint/resume |
| [agents.md](agents.md) | All 12 agents: role, model tier, inputs, outputs |
| [artifacts.md](artifacts.md) | Complete artifact map with paths, producers, and consumers |
| [skills-and-hooks.md](skills-and-hooks.md) | 9 skills and 5 hooks: purpose, consuming agent, trigger |
| [configuration.md](configuration.md) | All config surfaces: project-template, agent-models, security policy |
| [adoption-guide.md](adoption-guide.md) | Step-by-step guide to adopting this framework in a project |

## Relationship to other docs

- **CLAUDE.md** (repo root) -- the constitution. Points agents to the right files.
- **.claude/core.md** -- universal quality rules, testing requirements, security baseline.
- **.claude/workflow.md** -- pipeline stages, retry policy, verdict formats.
- **.claude/project-template.md** -- project-specific config (filled in per project).
- **.claude/anti-patterns.md** -- 14 documented failure modes.
- **docs/goal.md** -- project vision and success criteria (filled in per project).
- **docs/architecture/** -- project-specific architecture docs (auto-updated per phase).

## Keeping these docs current

After adding agents, skills, hooks, or pipeline steps, run:

```bash
./scripts/automation/update-docs.sh --framework
```

This invokes Claude with the `architecture-doc-updater` skill to detect and fix drift between source files and these docs.
