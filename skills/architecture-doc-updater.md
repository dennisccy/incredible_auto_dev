# Skill: Architecture Doc Updater

This skill describes how to update architecture documentation to reflect the current state of source files. Used by `scripts/automation/update-docs.sh`.

## Two Contexts

### Framework mode (`--framework`)

Update `.claude/architecture/*.md` to match the actual framework source files.

**Source of truth files:**
- `.claude/agents/*.md` -- count and list of agents
- `.claude/skills/*.md` -- count and list of skills
- `.claude/hooks/*.sh` -- count and list of hooks
- `scripts/automation/*.sh` -- count and list of scripts
- `templates/*` -- count and list of templates
- `config/agent-models.yaml` -- model tier assignments
- `scripts/automation/run-phase.sh` -- pipeline step count and order
- `scripts/automation/lib/common.sh` -- shared utilities
- `.claude/workflow.md` -- pipeline stages and verdict formats
- `CLAUDE.md` -- constitution tables

**What to check:**
1. Agent count in `agents.md` matches `ls .claude/agents/*.md | wc -l`
2. Skill count in `skills-and-hooks.md` matches `ls .claude/skills/*.md | wc -l`
3. Hook count in `skills-and-hooks.md` matches `ls .claude/hooks/*.sh | wc -l`
4. Script count in `system-overview.md` matches `ls scripts/automation/*.sh | wc -l`
5. Template count in `system-overview.md` matches `ls templates/* | wc -l`
6. Pipeline step count in `pipeline.md` matches step comments in `run-phase.sh`
7. Model assignments in `agents.md` match `config/agent-models.yaml`
8. All agents listed in `agents.md` have corresponding files in `.claude/agents/`

### Project mode (with phase argument)

Update `docs/architecture/*.md` to reflect what has been built. If no architecture docs exist, create them from `templates/architecture-overview.md`.

**Source of truth files:**
- `docs/goal.md` -- project vision and capabilities
- `.claude/project-template.md` -- stack, architecture principles
- `runs/<phase>/plan.md` -- what was planned
- `docs/handoffs/<phase>-dev.md` -- what was built
- `reports/phase-{N}-implementation-summary.md` -- implementation details
- `reports/phase-{N}-user-visible-changes.md` -- user-visible changes

**What to update:**
1. Add new components, endpoints, models built in the phase
2. Update data model if schema changed
3. Update API endpoint list if routes changed
4. Note new capabilities added
5. Update phase completion status

## Rules

1. **Factual only** -- document what exists in source files, never invent capabilities
2. **Maintain structure** -- update counts, tables, and lists within existing document structure
3. **Update, do not rewrite** -- change specific sections that drifted, leave correct sections alone
4. **Verify counts** -- always count actual files, do not rely on previous doc content
5. **No opinions** -- do not add commentary, recommendations, or future plans unless they exist in source files
6. **Preserve formatting** -- maintain existing markdown structure, headings, and table formats

## Drift Detection

A doc has drifted when any of these are true:
- File count in doc does not match actual file count
- A listed file no longer exists or a new file is not listed
- Model tier assignment in doc does not match `agent-models.yaml`
- Pipeline step count or order does not match `run-phase.sh`
- An agent's described role does not match its `.md` file's description field
