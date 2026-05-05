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

Maps each of the 14 agents to a model tier (12 phase-mode + 2 goal-mode).

```yaml
tiers:
  strong:   claude-opus-4-7
  standard: claude-sonnet-4-6
  light:    claude-haiku-4-5

agents:
  # Phase-mode agents
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

  # Goal-mode agents
  goal-decomposer: strong   # iteration spec generation
  goal-evaluator:  strong   # done/regression/stall judgment
```

After editing, run `./scripts/automation/sync-agent-models.sh` to propagate changes to agent `.md` files.

All agent invocations (phase mode and goal mode) go through `lib/quota-retry.sh::claude_with_quota_retry`, which passes `--effort max` and handles quota exhaustion by sleeping until reset and resuming. This is automatic — no per-agent flag is needed.

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
| `CHAIN_CLAUDE_DISABLE_CACHE_HYGIENE` | `false` | When `true`, drop the `--exclude-dynamic-system-prompt-sections` flag from claude invocations. Default keeps it on (improves prompt-cache reuse across sessions). |
| `CHAIN_TELEMETRY_TOKENS` | `false` | When `true`, route claude calls through `lib/claude_stream_renderer.py` to capture token usage and `total_cost_usd` into `claude_usage` telemetry events. See `docs/goal-mode-telemetry.md`. |
| `CHAIN_TRACE_DIR` | (auto-set by entry scripts) | Directory where each successful claude invocation appends a record to `trace.jsonl` and copies its stdout to `<NNNN>-<agent>.log`. Phase mode auto-sets to `runs/<phase>/trace/`; goal mode auto-sets to `runs/goal-session-<sid>/trace/`. Inspect with `python3 scripts/automation/lib/replay_trace.py list <dir>`. |
| `CHAIN_DISABLE_TRACE` | `false` | When `true`, the entry scripts skip auto-setting `CHAIN_TRACE_DIR` so no trace records are written. |
| `CHAIN_DISABLE_PERMISSION_ISOLATION` | `false` | When `true`, skip the per-agent permission overlay applied by `lib/quota-retry.sh`. The overlay reads `lib/agent_permissions.py` and passes `--disallowedTools` to claude based on `CHAIN_CURRENT_AGENT` — by default, only `release-manager` can `git push`, `gh pr merge`, `gh release`, `git tag`, etc. |
| `GOAL_SESSION_DIR` | (set by run-goal.sh) | Goal-mode session directory; consumed by `lib/telemetry.sh` for JSONL writes. No-op when unset (phase mode is unaffected). |
| `GOAL_SESSION_ID` | (set by run-goal.sh) | Session id; included in every telemetry event |
| `GOAL_ITER_INDEX` | (set by run-goal.sh) | Current iteration index; included in every telemetry event |
| `GOAL_ITER_NAME` | (set by run-goal.sh) | Synthetic phase name `goal-<sid>-iter-<N>` |
