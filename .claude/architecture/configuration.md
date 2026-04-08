# Configuration

All configuration surfaces in the framework.

## .claude/project-template.md

The primary project configuration file. Every adopting project fills this in. Contains:

| Section | What it configures |
|---------|-------------------|
| PROJECT | Name, description, repository URL |
| PROJECT GOAL | Pointer to `docs/goal.md` |
| STACK | Backend language/framework/ORM/DB, frontend framework, database type/location |
| TEST COMMANDS | Exact commands for backend tests, frontend tests, migrations, lint |
| SERVICE START COMMANDS | How to start backend and frontend for QA |
| PHASE SPECS | Directory and naming convention for phase spec files |
| ROADMAP | Phase list with status |
| ARCHITECTURE PRINCIPLES | Project-specific rules all agents enforce |
| DATA MODEL RULES | Conventions for data modeling (IDs, timestamps, etc.) |
| GIT WORKFLOW | Branch naming, PR format, never-commit file list |
| OUT OF SCOPE DEFAULT | Items never implemented unless a phase spec explicitly requires them |
| NOTES FOR AGENTS | Additional context |

Agents reference this file for stack-specific commands (test runner, package manager, migration tool) instead of hard-coding paths.

## config/agent-models.yaml

Maps each of the 12 agents to a model tier.

```yaml
tiers:
  strong:   claude-opus-4-6
  standard: claude-sonnet-4-6
  light:    claude-haiku-4-5

agents:
  orchestrator:    strong
  developer:       strong
  reviewer:        standard
  qa:              light
  auditor:         strong
  release-manager: light
  product-manager: strong
  ui-impact-analyst:      standard
  ui-test-designer:       standard
  browser-qa-agent:       standard
  ux-regression-reviewer: standard
  phase-closure-auditor:  standard
```

After editing, run `./scripts/automation/sync-agent-models.sh` to propagate changes to agent `.md` files.

## config/install-security-policy.json

Supply-chain security policy. Controls which packages can be installed without human approval.

| Section | What it controls |
|---------|-----------------|
| `python.allowlist` | Pre-approved pip packages |
| `python.rules` | Require pinned versions, block direct URLs, min release age |
| `npm.allowlist` | Pre-approved npm packages |
| `npm.rules` | Require pinned versions, block direct URLs |
| `git.trusted_orgs` | GitHub orgs whose repos can be cloned |
| `git.rules` | Require pinned ref, block unknown orgs |
| `skills.trusted_repos` | Repos whose skills can be installed |
| `global` | Block curl-pipe-bash, log all decisions, bypass env var |

Decision log: `reports/security/install-decisions.jsonl`

## .claude/settings.json

Claude Code tool permissions. Controls which Bash commands are allowed without user confirmation.

The `allow` list should be customized per project (e.g., add `Bash(alembic *)` for projects using Alembic migrations).

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `CHAIN_START_BACKEND_CMD` | `./scripts/start-backend.sh` | Backend start command for QA |
| `CHAIN_START_FRONTEND_CMD` | `./scripts/start-frontend.sh` | Frontend start command for QA |
| `CHAIN_BACKEND_HEALTH_URL` | `http://localhost:8000/health` | Health check endpoint |
| `CHAIN_FRONTEND_URL` | `http://localhost:3000` | Frontend URL for browser checks |
| `CHAIN_CLAUDE_RESET_TZ` | `Europe/London` | Timezone for quota reset parsing |
| `CHAIN_CLAUDE_RESET_BUFFER_SECONDS` | `120` | Buffer after quota reset |
| `CHAIN_CLAUDE_FALLBACK_SLEEP_SECONDS` | `3600` | Sleep when reset time unparseable |
| `CHAIN_CLAUDE_MAX_QUOTA_RETRIES` | `3` | Max quota-wait-retry cycles |
| `CHAIN_DISABLE_AUTO_WAIT` | `false` | Fail immediately on quota exhaustion |
| `CHAIN_INSTALL_GATE_BYPASS` | (unset) | Bypass install security gate |
