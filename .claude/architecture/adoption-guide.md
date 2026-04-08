# Adoption Guide

Step-by-step guide to adopting the AI Multi-Agent Dev Chain in a project.

## Prerequisites

- **Claude Code CLI** installed and configured (`claude` command available)
- **gh CLI** installed and authenticated (`gh auth login`) -- required for PR creation
- **Chrome MCP** configured (optional -- required for browser QA tests)
- A project repository with at least a backend codebase

## Step 1: Add the Framework

The framework is designed to be added as a subrepo (submodule or subtree):

```bash
# Option A: git submodule
git submodule add <framework-repo-url> ai-auto-dev-chain

# Option B: git subtree
git subtree add --prefix=ai-auto-dev-chain <framework-repo-url> main --squash

# Option C: direct copy
cp -r ai-auto-dev-chain/.claude /path/to/your/project/
cp -r ai-auto-dev-chain/scripts /path/to/your/project/
cp -r ai-auto-dev-chain/config /path/to/your/project/
cp -r ai-auto-dev-chain/templates /path/to/your/project/
cp ai-auto-dev-chain/CLAUDE.md /path/to/your/project/
```

## Step 2: Define the Project Goal

Create `docs/goal.md` in your project. Use `templates/project-goal.md` as a starting point.

This file defines your project's vision, target users, success criteria, and key capabilities. All agents read it before starting any phase to ensure alignment.

```bash
mkdir -p docs
cp templates/project-goal.md docs/goal.md
# Edit docs/goal.md with your project's specifics
```

## Step 3: Configure the Project

Fill in `.claude/project-template.md`:

1. **PROJECT** -- name, description, repo URL
2. **STACK** -- backend language/framework, frontend framework, database
3. **TEST COMMANDS** -- exact commands the developer and QA agents will run
4. **SERVICE START COMMANDS** -- how to start backend/frontend for QA
5. **ARCHITECTURE PRINCIPLES** -- project-specific rules agents enforce
6. **GIT WORKFLOW** -- branch naming, never-commit files

This is the most important configuration step. Agents use this file to determine which commands to run, which paths to use, and which rules to follow.

## Step 4: Write a Phase Spec

Use `templates/phase-spec.md` as a starting point. Save to `docs/phases/phase-1-<name>.md`.

Every phase spec must have:
- A clear one-sentence goal
- A numbered DEFINITION OF DONE checklist
- Specific, testable acceptance criteria

See `.claude/anti-patterns.md` (pattern 1) for why vague acceptance criteria cause problems.

## Step 5: Run the Pipeline

```bash
# Full pipeline (plan through finalize)
./scripts/automation/run-phase.sh phase-1

# Or with auto-release (auto-commit + PR after all checks pass)
./scripts/automation/run-phase.sh phase-1 --auto-release
```

The pipeline will:
1. Create an execution plan
2. Generate a functional test plan
3. Implement the phase with TDD
4. Review, QA, and audit the implementation
5. Produce UI visibility artifacts (if frontend present)
6. Finalize with a git branch and PR

## Step 6: Customize

### Model assignments

Edit `config/agent-models.yaml` to change which models agents use, then run:
```bash
./scripts/automation/sync-agent-models.sh
```

### Security policy

Edit `config/install-security-policy.json` to pre-approve packages your project uses:
```json
{
  "python": {
    "allowlist": ["flask==3.0.0", "sqlalchemy==2.0.25"]
  }
}
```

### Tool permissions

Edit `.claude/settings.json` to add project-specific CLI tools to the allow list.

## Step 7: Architecture Documentation (Ongoing)

After each phase completes, the pipeline can update project architecture docs:

```bash
# Automatic: runs at the end of finalize-phase.sh (non-blocking)
# Manual: update project docs for a specific phase
./scripts/automation/update-docs.sh phase-1

# Update framework docs (when you modify agents, skills, hooks)
./scripts/automation/update-docs.sh --framework
```

Project architecture docs are stored in `docs/architecture/` and describe what has been built.

## Directory Structure After Adoption

```
your-project/
  CLAUDE.md                          # Framework constitution
  docs/
    goal.md                          # Project goal (you fill this in)
    phases/                          # Phase specs (you write these)
    handoffs/                        # Dev and audit handoffs (agents write these)
    architecture/                    # Project architecture docs (auto-updated)
  .claude/
    core.md                          # Universal rules
    workflow.md                      # Pipeline definition
    project-template.md              # Project config (you fill this in)
    anti-patterns.md                 # Failure modes
    agents/                          # 12 agent definitions
    skills/                          # 9 skills
    hooks/                           # 5 hooks
    architecture/                    # Framework architecture docs
  scripts/automation/                # 16 automation scripts
  config/                            # agent-models.yaml, security policy
  templates/                         # 15 artifact templates
  runs/<phase>/                      # Runtime artifacts per phase
  reports/                           # Reports per phase
```
