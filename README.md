# AI Multi-Agent Dev Chain

A reusable framework for running phased software development with Claude AI agents. The chain handles the full lifecycle: planning → implementation → review → QA → audit → release.

## What This Is

A collection of:
- **7 Claude agent definitions** covering the full dev lifecycle
- **10 automation shell scripts** orchestrating the pipeline
- **4 security hooks** guarding against supply-chain attacks and dangerous commands
- **A modular CLAUDE.md system** (core rules, workflow, project config, anti-patterns)
- **Report templates** for consistent handoffs across all agents

The chain has a checkpoint/resume system, quota-exhaustion auto-retry, and a verdict-gated pipeline where each stage must pass before the next runs.

## Quick Start

**1. Copy this repo into your project.**

```bash
cp -r ai-auto-dev-chain/.claude /path/to/your/project/
cp -r ai-auto-dev-chain/scripts /path/to/your/project/
cp -r ai-auto-dev-chain/config /path/to/your/project/
cp ai-auto-dev-chain/CLAUDE.md /path/to/your/project/
```

**2. Fill in `.claude/project-template.md`.**

Configure your stack, test commands, and architecture rules. The developer agent reads this instead of hard-coded paths.

**3. Write a phase spec.**

Use `templates/phase-spec.md` as a starting point. Save to `docs/phases/phase-1-<name>.md`.

**4. Run.**

```bash
./scripts/automation/run-phase.sh phase-1
```

## Pipeline

```
Phase spec
    │
    ▼
orchestrator  ──── plan.md ────────────────────────────────────────┐
    │                                                               │
    ▼                                                               │
[generate test plan]  ──── reports/qa/<phase>-test-plan.md         │
    │                                                               │
    ▼                                                               │
developer  ──── docs/handoffs/<phase>-dev.md ──────────────────┐   │
    │                                                           │   │
    ▼                                                           │   │
reviewer  ──── reports/reviews/<phase>-review.md               │   │
    │  (FAIL → back to developer, max 3 attempts)               │   │
    ▼                                                           │   │
qa  ──── reports/qa/<phase>-qa.md                              │   │
    │  (FAIL → back to developer, max 3 attempts)               │   │
    ▼                                                           │   │
auditor  ──── docs/handoffs/<phase>-audit.md                   │   │
    │  (FAIL → fix + re-audit, max 2 attempts)                  │   │
    ▼                                                           │   │
release-manager  ──── PR + merge ──────────────────────────────┘   │
                                                                    │
All artifacts written to runs/<phase>/ ─────────────────────────────┘
```

## Agent Roles

| Agent | Model Tier | What it does |
|-------|-----------|--------------|
| `orchestrator` | strong | Reads phase spec, writes execution plan, manages checkpoint |
| `developer` | strong | TDD implementation — backend + frontend, reads project-template for stack config |
| `reviewer` | standard | Code review against spec checklist, writes verdict report |
| `qa` | light | Two modes: test plan generation (mode 1) and QA validation (mode 2) |
| `auditor` | strong | Skeptical post-QA audit, may apply critical fixes directly |
| `release-manager` | light | Git branch, commit, push, PR — no force-push |
| `product-manager` | strong | Optional: architecture planning before phase spec is written |

Model tiers are defined in `config/agent-models.yaml`. Change model assignments there and run `./scripts/automation/sync-agent-models.sh` to propagate.

## Security Infrastructure

### Supply-chain gate

Every `pip install`, `npm install`, `git clone`, and `curl | bash` command is intercepted before execution. The gate checks against `config/install-security-policy.json` and returns one of:
- `allow` — in allowlist
- `review_required` — not in allowlist, requires human approval
- `deny` — matches a deny pattern (custom index URLs, curl|bash, etc.)

To bypass for a known-safe command: `CHAIN_INSTALL_GATE_BYPASS=true ./your-command`

### Command guard

Dangerous shell commands (`rm -rf /`, `dd`, `mkfs`, credential reads, force-push main) are blocked at the pre-tool-call hook level.

### Post-edit lint

Edited Python files are auto-linted with `ruff`. Edited TypeScript/TSX files are type-checked with `tsc --noEmit`.

### Stop artifact check

On session stop, verifies that the current phase's expected artifacts exist. Warns if dev ran without writing a handoff.

## Configuration

### `.claude/project-template.md`

The single file you must fill in to adopt the framework. Defines:
- Project name, description, repo URL
- Backend language, framework, DB, package manager, virtualenv path
- Frontend framework, package manager
- Test commands (backend, frontend, lint)
- Service start/stop commands
- Phase spec location and naming convention
- Architecture principles (project-specific rules reviewers enforce)
- Never-commit file list

### `config/agent-models.yaml`

Assigns each agent to a model tier (strong/standard/light). After editing, run:
```bash
./scripts/automation/sync-agent-models.sh
```

### `config/install-security-policy.json`

Package allowlists (pip, npm) and deny patterns. Add approved packages here. Empty by default — all installs start as `review_required`.

### `.claude/settings.json`

Claude Code tool permissions. Customise the `allow` list for your stack's specific CLI tools (e.g., add `Bash(alembic *)` for Django, `Bash(cargo *)` for Rust).

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `CHAIN_START_BACKEND_CMD` | `./scripts/start-backend.sh` | How qa-phase.sh starts the backend |
| `CHAIN_START_FRONTEND_CMD` | `./scripts/start-frontend.sh` | How qa-phase.sh starts the frontend |
| `CHAIN_BACKEND_HEALTH_URL` | `http://localhost:8000/health` | Health endpoint for backend readiness check |
| `CHAIN_FRONTEND_URL` | `http://localhost:3000` | Frontend base URL for browser checks |
| `CHAIN_CLAUDE_RESET_TZ` | `Europe/London` | Timezone for quota reset time parsing |
| `CHAIN_CLAUDE_RESET_BUFFER_SECONDS` | `120` | Extra seconds added after parsed reset time |
| `CHAIN_CLAUDE_FALLBACK_SLEEP_SECONDS` | `3600` | Sleep when reset time cannot be parsed |
| `CHAIN_CLAUDE_MAX_QUOTA_RETRIES` | `3` | Max quota-wait-retry cycles |
| `CHAIN_DISABLE_AUTO_WAIT` | `false` | Set to `true` to fail immediately on quota exhaustion |
| `CHAIN_INSTALL_GATE_BYPASS` | (unset) | Set to `true` to bypass install security gate |

## Templates

| Template | Use when |
|----------|---------|
| `templates/phase-spec.md` | Writing a new phase spec |
| `templates/dev-handoff.md` | Developer agent output reference |
| `templates/review-checklist.md` | Reviewer agent output reference |
| `templates/test-plan.md` | QA agent test plan reference |
| `templates/qa-report.md` | QA agent validation report reference |
| `templates/audit-report.md` | Auditor agent report reference |

## Artifact Schema

See `runs/SCHEMA.md` for the full schema of `status.json`, `summary.json`, and `plan.md` (including the machine-read `Frontend Present: yes/no` line).

## Known Limitations

1. **Service bootstrap**: `qa-phase.sh` expects `CHAIN_START_BACKEND_CMD` or `scripts/start-backend.sh`. You must provide one.
2. **Claude Code only**: Hooks and agent definitions are Claude Code-specific. Not compatible with other AI coding assistants.
3. **Model tier costs**: Assumes access to Claude API with multiple model tiers. Single-model setups need to edit `config/agent-models.yaml`.
4. **No CI integration**: Pipeline is CLI-only. GitHub Actions integration is not included.
5. **Chrome MCP optional**: Browser checks require Chrome MCP to be configured. Without it, browser TCs are skipped (not failed).

## Tests

```bash
./tests/automation/test-install-gate.sh   # supply-chain gate unit tests
./tests/automation/test-quota-retry.sh    # quota-retry unit tests
```
