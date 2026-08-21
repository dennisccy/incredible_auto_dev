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

## config/model-tiers.yaml (+ agents/*/agent.yaml `model_tier`)

Maps each of the 20 agents to a model tier (12 phase-pipeline + 4 goal-mode + 4 showcase/maintenance).

```yaml
tiers:
  strong:   claude-opus-5
  standard: claude-sonnet-5
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

After editing, run `python3 scripts/automation/sync-cli-assets.py --cli claude` and commit the regenerated `.claude/agents/*.md`.

All agent invocations (phase mode and goal mode) go through `lib/quota-retry.sh::claude_with_quota_retry`, which passes `--effort max` (plus `--settings '{"outputStyle":"<name>"}'` when the wave-1 output-style table resolves one, opt-in via `CHAIN_OUTPUT_STYLES=true`) and handles quota exhaustion by sleeping until reset and resuming. This is automatic — no per-agent flag is needed.

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
| `CHAIN_TELEMETRY_TOKENS` | `true` | When `true` (the default for headless runs), route claude calls through `lib/claude_stream_renderer.py` to capture token usage and `total_cost_usd` into `claude_usage` telemetry events. See `docs/goal-mode-telemetry.md`. |
| `CHAIN_TRACE_DIR` | (auto-set by entry scripts) | Directory where each successful claude invocation appends a record to `trace.jsonl` and copies its stdout to `<NNNN>-<agent>.log`. Phase mode auto-sets to `runs/<phase>/trace/`; goal mode auto-sets to `runs/goal-session-<sid>/trace/`. Inspect with `python3 scripts/automation/lib/replay_trace.py list <dir>`. |
| `CHAIN_DISABLE_TRACE` | `false` | When `true`, the entry scripts skip auto-setting `CHAIN_TRACE_DIR` so no trace records are written. |
| `CHAIN_DISABLE_PERMISSION_ISOLATION` | `false` | When `true`, skip the per-agent permission overlay applied by `lib/quota-retry.sh`. The overlay reads `lib/agent_permissions.py` and passes `--disallowedTools` to claude based on `CHAIN_CURRENT_AGENT` — by default, only `release-manager` can `git push`, `gh pr merge`, `gh release`, `git tag`, etc. |
| `CHAIN_OUTPUT_STYLES` | `false` | STYLE-1 experiment: `true` arms the wave-1 table in `lib/agent_permissions.py` (`OUTPUT_STYLE_OVERRIDES`) — per-agent Claude Code output style on headless dispatches (`Concise` on developer/qa/browser-qa-agent/orchestrator/ui-impact-analyst/ux-regression-reviewer). Judges refused by construction; goal mode only. |
| `CHAIN_AGENT_OUTPUT_STYLE` | (unset) | Per-agent output-style experiment map, e.g. `developer=Concise,qa=Concise` — same grammar as `CHAIN_AGENT_EFFORT`; judges refused. |
| `CHAIN_OUTPUT_STYLE_OVERRIDE` | (unset) | Debug: forces one style on every agent including judges (loud NOTICE); wins over all other resolution; works outside goal mode too. |
| `CHAIN_DEPTH_ARBITER` | `true` | SPEED-20 deterministic depth arbiter (evaluator depth recommendation binding by default; `false` restores the legacy SPEED-10 allowlist) |
| `CHAIN_FULL_CADENCE_CAP` | `4` | Arbiter window cap: at most one full per W iterations (`0`/`1` disables the cap) |
| `CHAIN_REQUIRE_FULL_DEPTH` | (unset) | **OPERATOR-SET ONLY.** Truthy (`true`/`TRUE`/`1`/`yes`/`on`) makes full depth a HARD requirement wherever an iteration already asks for it: it PREVENTS a `Depth: full` spec from being demoted (it outranks every cost rung of the arbiter, and the legacy-allowlist path pauses rather than demotes), and if full still cannot be dispatched the engine pauses `AWAITING_FULL_DEPTH` before dispatch instead of running lean. It does NOT promote a lean or evidence spec to full: the arbiter's precedence rung only runs for a spec that already asked for full, and the other guard sites (`depth-parse`, `full-dispatch`, `depth-legacy-allowlist`, `isolation-requires-full`) PAUSE rather than promote. Write `Depth: full` in the spec for the requirement to have something to protect. Per-iteration equivalent: a `Depth enforcement: required` line in the iteration spec. The decomposer is forbidden to emit that line (anti-pattern 25) — a human writes it. Default off: with neither present the arbiter behaves exactly as before |
| `CHAIN_MAINTENANCE_ISOLATION` | (unset) | **OPERATOR-SET ONLY.** Truthy (`true`/`TRUE`/`1`/`yes`/`on`/`required`) declares the run a maintenance isolation: full reviewer/QA/auditor/coherence/evaluator depth REQUIRED, application-service boot, browser QA, the deterministic replay lane and the demo showcase FORBIDDEN. Enforced fail-closed at seven sites: `detect_frontend_in_plan` subordinates the `CHAIN_GOAL_TARGET_JOURNEYS` browser override, and `_boot_shared_services`, `ensure_services_running`, `browser-qa-phase.sh`, `replay_lane_partition_and_verify`, `demo-phase.sh` and `run-goal.sh`'s async showcase-join reap call `maintenance_isolation_refuse`, which appends to `iter-<N>/maintenance-isolation-refusals` and emits a `maintenance_isolation_refused` event (the six original chokepoints of the port, plus the showcase-join reap added on this side). Per-iteration equivalent: a `Maintenance isolation: required` line in the spec (decomposer forbidden — anti-pattern 25). Isolation is enforced only at FULL depth: it implies the full-depth requirement (`goal_full_depth_required`), so an isolated `Depth: full` spec is protected from every cost rung, and an isolated spec that resolves to lean/evidence pauses `AWAITING_FULL_DEPTH` (step `isolation-requires-full`) rather than being promoted or run |
| `CHAIN_MAINTENANCE_ISOLATION_SOURCE` | (engine-set) | Provenance stamp written by `apply_maintenance_isolation_from_spec`: `spec` when this iteration's spec declared isolation (cleared and recomputed at the next iteration so it cannot leak forward), `env` when the operator declared it session-wide (never cleared). Diagnostic — do not set by hand |
| `CHAIN_ITER_TIME_BUDGET_SECONDS` | `3600` | SPEED-15 wall-clock iteration budget (`0` disarms everything) |
| `CHAIN_ITER_BUDGET_MODE` | `trim` | `warn` logs only; `trim` (default) sheds optional breadth in rung order — spine/gates never trimmed |
| `CHAIN_DEV_FULL_GOAL` | `false` | TOKEN-10 hatch: `true` feeds executors the full `docs/goal.md` instead of the goal slice |
| `CHAIN_GOLDEN_AUTODERIVE` / `CHAIN_GOLDEN_AUTODERIVE_MAX` | `true` / `3` | SPEED-21: derive + verify + install golden candidates from the verified demo (cap per iteration) |
| `CHAIN_GOLDEN_NUDGE` | `true` | SPEED-23: one gap journey per iteration gets its golden promoted to a REQUIRED deliverable |
| `CHAIN_REPLAY_MASS_FAIL_BREAKER` | `true` | SPEED-22: majority replay-FAIL runs re-check 2 canaries before re-confirming the whole set (lean executor only) |
| `CHAIN_UI_COMBINED` | `true` | SPEED-24: goal-mode fulls combine ui-impact + ui-test-design into one dispatch (under-delivery falls back) |
| `CHAIN_SKIP_TESTPLAN_IF_PRESENT` | `true` | TOKEN-3 (flipped 2026-07-29): skip test-plan generation when the spec lists its own tests or a fresh plan exists |
| `GOAL_SESSION_DIR` | (set by run-goal.sh) | Goal-mode session directory; consumed by `lib/telemetry.sh` for JSONL writes. No-op when unset (phase mode is unaffected). |
| `GOAL_SESSION_ID` | (set by run-goal.sh) | Session id; included in every telemetry event |
| `GOAL_ITER_INDEX` | (set by run-goal.sh) | Current iteration index; included in every telemetry event |
| `GOAL_ITER_NAME` | (set by run-goal.sh) | Synthetic phase name `goal-<sid>-iter-<N>` |
