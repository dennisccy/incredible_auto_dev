# CLAUDE.md — AI Multi-Agent Dev Chain

This is the operating constitution for all agents working in this project.
All agents MUST read this file and the files it references before taking any action.

---

## MODES

The framework supports two execution modes. Both share all agents and skills; they differ only in how iterations are scheduled and gated.

| Mode | Entry point | When to use |
|------|------------|-------------|
| **Phase mode** | `./scripts/automation/run-phase.sh <phase-name>` | Human-authored phase specs in `docs/phases/`. One phase at a time, 11-step pipeline, human-gated between phases. The default. |
| **Goal mode** | `./scripts/automation/run-goal.sh --session-id <id>` | One `docs/goal.md` (with Must-have user journeys + Anti-goals). Continuous loop `decompose → execute → evaluate` until an AI evaluator declares the goal achieved or a hard halt fires. Quota exhaustion auto-resumes. |

For goal-mode usage, see [`docs/goal-mode-quickstart.md`](docs/goal-mode-quickstart.md). For internals, see [`.claude/architecture/goal-mode.md`](.claude/architecture/goal-mode.md). For the README, see the project-root [`README.md`](README.md).

The two modes write to disjoint artifact namespaces — phase mode uses `runs/<phase>/`, goal mode uses `runs/goal-session-<sid>/` — so both can be used in the same project without collision.

---

## CLI PROVIDERS

Both modes can run on either **Claude Code** (default) or **OpenAI Codex CLI**. Pass `--cli claude|codex` to either entry script. Goal mode pins the choice to `session.json` on creation; phase mode is per-run.

```bash
./scripts/automation/run-phase.sh phase-1 --cli codex
./scripts/automation/run-goal.sh --session-id myapp --cli codex
```

A single canonical asset source lives under `agents/`, `skills/`, `hooks/`, `policy/`, and `config/`. Per-CLI adapters (`adapters/claude/sync.py`, `adapters/codex/sync.py`) generate `.claude/` and `.codex/` from it on first run. Edit the neutral source — the per-CLI trees are build products. Full guide in [`docs/cli-providers.md`](docs/cli-providers.md).

---

## MODULAR INSTRUCTION SYSTEM

This constitution is split into focused files. Agents must read the relevant files for their role:

| File | Contents | Who reads it |
|------|----------|--------------|
| `.claude/core.md` | Universal quality rules, testing checklist, security baseline, token policy | **All agents** |
| `.claude/workflow.md` | Pipeline stages, retry policy, artifact locations, verdict formats, UI evolution policy | **All agents** |
| `.claude/project-template.md` | Project name, stack, test commands, architecture principles | **All agents** |
| `.claude/anti-patterns.md` | Lessons learned, failure modes to avoid | **Orchestrator, reviewer, auditor** |
| `.claude/architecture/` | System architecture, agent catalog, pipeline flow, artifact map, adoption guide | **All agents** (reference) |

---

## AGENT ROLES

Specialist subagent definitions live in `.claude/agents/`:

| Agent | File | Role |
|-------|------|------|
| `orchestrator` | `.claude/agents/orchestrator.md` | Plans phase, writes `runs/<phase>/plan.md`, delegates work |
| `developer` | `.claude/agents/developer.md` | Implements backend + frontend changes with TDD |
| `reviewer` | `.claude/agents/reviewer.md` | Reviews diff against spec, writes review report |
| `qa` | `.claude/agents/qa.md` | Generates test plans (mode 1) and validates them (mode 2) |
| `auditor` | `.claude/agents/auditor.md` | Post-QA skeptical audit, may apply critical fixes |
| `release-manager` | `.claude/agents/release-manager.md` | Git/GitHub: branches, commits, PRs, merges |
| `product-manager` | `.claude/agents/product-manager.md` | Optional: architecture planning before phase spec is written |
| `ui-impact-analyst` | `.claude/agents/ui-impact-analyst.md` | Post-dev: maps code changes to UI surfaces, identifies user-visible impact |
| `ui-test-designer` | `.claude/agents/ui-test-designer.md` | Creates practical UI test plan and 5-minute operator verification guide |
| `browser-qa-agent` | `.claude/agents/browser-qa-agent.md` | Executes browser automation tests via Chrome MCP, records pass/fail |
| `phase-closure-auditor` | `.claude/agents/phase-closure-auditor.md` | Final gate: validates all UI artifacts exist and are non-vague |
| `ux-regression-reviewer` | `.claude/agents/ux-regression-reviewer.md` | Checks UI evolved with new capabilities, flags hidden/undiscoverable features |
| `goal-decomposer` | `.claude/agents/goal-decomposer.md` | Goal mode: reads goal + state, writes next iteration spec, picks lean/full depth |
| `goal-evaluator` | `.claude/agents/goal-evaluator.md` | Goal mode: skeptical done/regression/stall judgment, updates journey-history |
| `iteration-summarizer` | `.claude/agents/iteration-summarizer.md` | Post-iteration synthesis: writes the plain-language + technical iteration summary and maintains the cumulative `project-story.md` in goal mode; emits the one-time `delivered.md` wrap on GOAL_ACHIEVED |
| `demo-narrator` | `.claude/agents/demo-narrator.md` | Per-iteration product demonstrator: drives the running app via Chrome MCP, captures a captioned narrated screenshot gallery (record mode) or walks a visible Chrome live (live mode). Showcase, not QA — never halts the pipeline |

---

## SKILLS (Agent Reference Instructions)

Reusable instruction files that agents read during their workflow. Located in `.claude/skills/`:

| File | Used by | Purpose |
|------|---------|---------|
| `diff-to-ui-impact.md` | ui-impact-analyst | Classify file changes by UI impact type |
| `ui-workflow-inference.md` | ui-impact-analyst | Infer user journeys from changed routes/components |
| `manual-ui-test-plan-generator.md` | ui-test-designer | Create human-executable test plans |
| `browser-workflow-executor.md` | browser-qa-agent | Execute browser flows via Chrome MCP |
| `visible-change-summarizer.md` | ui-impact-analyst | Write plain-language user-facing change summaries |
| `phase-closure-gate.md` | phase-closure-auditor | Evaluate phase completion criteria |
| `ui-regression-scout.md` | ux-regression-reviewer | Identify old journeys affected by new changes |
| `what-to-click-writer.md` | ui-test-designer | Write fast operator verification guides |
| `architecture-doc-updater.md` | update-docs.sh | Update framework or project architecture docs on drift |

---

## QUICK START

```bash
# Run a full phase end-to-end (phase mode)
./scripts/automation/run-phase.sh phase-1
./scripts/automation/run-phase.sh phase-1 --cli codex      # use Codex instead of Claude

# Run goal mode (continuous, autonomous, until goal achieved or hard halt)
./scripts/automation/run-goal.sh --session-id my-app
./scripts/automation/run-goal.sh --session-id my-app --cli codex
./scripts/automation/run-goal.sh --resume --session-id my-app   # resume (CLI pinned in session.json)

# Sync per-CLI asset trees (.claude/ and .codex/) from neutral source — runs
# automatically on first phase/goal invocation; manual call only needed after editing
# neutral source files outside the normal flow.
./scripts/automation/sync-cli-assets.sh                     # both CLIs
./scripts/automation/sync-cli-assets.sh --cli codex         # one CLI
./scripts/automation/sync-cli-assets.sh --check             # CI: non-zero if drift

# Or run individual steps
./scripts/automation/dev-phase.sh phase-1           # implement
./scripts/automation/review-phase.sh phase-1        # review
./scripts/automation/qa-phase.sh phase-1            # test + browser checks
./scripts/automation/phase-audit.sh phase-1         # post-QA audit
./scripts/automation/finalize-phase.sh phase-1      # commit + PR

# Utilities
./scripts/automation/generate-test-plan.sh phase-1  # write test plan before dev
./scripts/automation/ui-audit-phase.sh phase-1      # standalone UI audit
./scripts/automation/sync-agent-models.sh           # sync model assignments
./scripts/automation/check-install.sh "pip install X"  # check install safety
./scripts/automation/ui-impact-phase.sh phase-1      # analyze UI impact after dev
./scripts/automation/ui-test-design-phase.sh phase-1  # create UI test plan
./scripts/automation/browser-qa-phase.sh phase-1      # run browser QA
./scripts/automation/demo-phase.sh phase-1            # auto-record a narrated product demo (showcase, non-gating)
./scripts/automation/demo.sh phase-1                  # open the saved demo gallery for a phase or session
./scripts/automation/demo.sh phase-1 --live           # live walkthrough — agent drives a visible Chrome
./scripts/automation/demo.sh <sid> --delivered        # open the one-time GOAL_ACHIEVED "delivered" wrap
./scripts/automation/demo.sh --latest                 # open the most recently rendered HTML
./scripts/automation/ux-regression-phase.sh phase-1   # check UX regression
./scripts/automation/phase-closure-check.sh phase-1   # final closure gate
bash scripts/automation/render-summary.sh phase-1     # (re)build iteration-summary.md via summarizer agent + render HTML
bash scripts/automation/render-summary.sh phase-1 --no-resummarize  # re-render HTML only (no API tokens)
bash scripts/automation/render-summary.sh --session-index <sid>  # (re)render goal-mode session index
./scripts/automation/update-docs.sh --framework        # update framework architecture docs
./scripts/automation/update-docs.sh phase-1            # update project architecture docs
./scripts/automation/run-evals.sh                      # offline harness eval suite (~30s, no API)
python3 scripts/automation/lib/replay_trace.py list runs/<phase>/trace   # inspect captured agent invocations
python3 scripts/automation/lib/analyze_telemetry.py runs/goal-session-<sid>/telemetry.jsonl  # token/cost summary (needs CHAIN_TELEMETRY_TOKENS=true)
```

---

## PROJECT CONFIGURATION

Before running any phase:
1. Fill in `docs/goal.md` with the project's vision, success criteria, key capabilities, and non-goals/scope boundaries (use `templates/project-goal.md`).
2. Fill in `.claude/project-template.md` with:
- Project name and description
- Stack (backend language/framework, frontend, DB, package manager)
- Test commands and service start commands
- Architecture principles and never-commit file list
- Phase roadmap

---

## COMMUNICATION MODEL

Agents communicate ONLY through filesystem artifacts. No free-form conversation between agents.

See `.claude/workflow.md` for the full artifact location table.

---

## CORE PRINCIPLES (summary)

Full rules in `.claude/core.md`. Key points:
- Build ONLY within the current phase — stop immediately after
- Every phase must produce a visible change or measurable capability
- Every phase must have unit or browser tests
- No force-push to main; no secrets committed
- Token policy: read all available context before asking questions

---

## ANTI-PATTERNS

See `.claude/anti-patterns.md` for 18 documented failure modes from production use.
Most common: vague acceptance criteria → infinite review loops.
