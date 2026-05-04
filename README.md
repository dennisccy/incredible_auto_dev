# AI Multi-Agent Dev Chain

A reusable framework for running phased software development with Claude AI agents. The chain handles the full lifecycle: planning, implementation, review, UI validation, QA, audit, and release.

## What This Is

A collection of:
- **12 Claude agent definitions** covering the full dev lifecycle and UI visibility
- **16 automation shell scripts** orchestrating an 11-step pipeline
- **5 security hooks** guarding against supply-chain attacks, dangerous commands, and vague artifacts
- **9 skills** providing reusable methodologies for UI analysis, test design, and doc updates
- **15 report templates** for consistent handoffs across all agents
- **A modular CLAUDE.md system** (core rules, workflow, project config, anti-patterns, architecture docs)

The chain has checkpoint/resume, quota-exhaustion auto-retry, and a verdict-gated pipeline where each stage must pass before the next runs.

For comprehensive framework documentation, see [`.claude/architecture/`](.claude/architecture/README.md).

## Modes

The framework supports two modes:

**Phase mode** (the original) — you author phase specs in `docs/phases/` and run them one at a time through the 11-step pipeline. Each phase is a discrete, gated unit of work with a human-defined scope. Use this when you have a clear roadmap and want a human gate between every phase. Entry point: `./scripts/automation/run-phase.sh <phase-name>`.

**Goal mode** (added later, parallel to phase mode) — you author `docs/goal.md` once with **Must-have user journeys** and **Anti-goals**, then run `./scripts/automation/run-goal.sh`. The system loops `decompose → execute → evaluate` adaptively (lean cycle for small changes, full 11-step pipeline for risky ones) until an AI evaluator declares the goal achieved or a hard halt fires (max iterations, stall, regression). Quota exhaustion does NOT halt the loop — it pauses and auto-resumes when quota resets. Use this when you want autonomous, unattended development against a fixed product target. See [`docs/goal-mode-quickstart.md`](docs/goal-mode-quickstart.md) and [`.claude/architecture/goal-mode.md`](.claude/architecture/goal-mode.md).

The two modes share all agents and skills. They write to disjoint artifact namespaces (`runs/<phase>/` vs `runs/goal-session-<sid>/`) so you can use both in the same project without collision.

## Quick Start

**1. Add this repo to your project** (as a submodule, subtree, or direct copy).

**2. Define your project goal.** Create `docs/goal.md` from `templates/project-goal.md`.

**3. Fill in `.claude/project-template.md`.** Configure your stack, test commands, and architecture rules.

**4. Write a phase spec.** Use `templates/phase-spec.md`. Save to `docs/phases/phase-1-<name>.md`.

**5. Run.**

```bash
./scripts/automation/run-phase.sh phase-1
```

See [`.claude/architecture/adoption-guide.md`](.claude/architecture/adoption-guide.md) for the full adoption procedure.

### Goal Mode Quick Start

Goal mode skips per-phase authoring. You write a single `docs/goal.md` with extra sections for must-have user journeys and anti-goals, then run a continuous loop until an AI evaluator declares the goal achieved.

**1. Author `docs/goal.md` from `templates/project-goal.md`**, including the **Must-have user journeys** and **Anti-goals** sections (required for goal mode; phase mode ignores them).

**2. Configure `.claude/project-template.md`** the same way you would for phase mode.

**3. Run.**

```bash
./scripts/automation/run-goal.sh --session-id my-app
```

Optional flags: `--max-iter N` (cap, default 30), `--stall-window N` (default 3), `--auto-release` (PR on success), `--resume`, `--reset`, `--acknowledge-regression`.

**4. Inspect** `runs/goal-session-my-app/summary.md` when the loop halts. Halt verdicts: `GOAL_ACHIEVED` (success), `BUDGET_EXHAUSTED`, `STALLED`, `REGRESSION_HALT`, `ABORTED`.

Quota exhaustion is NOT a halt — the loop pauses and auto-resumes when the quota resets.

See [`docs/goal-mode-quickstart.md`](docs/goal-mode-quickstart.md) for the full guide.

## Pipeline (11 Steps)

```
Phase spec (docs/phases/<phase>.md)
    |
    v
 1. orchestrator       --> plan.md
    |
    v
 2. qa (generate)      --> test-plan.md
    |
    v
 3. developer+reviewer --> dev-handoff + review-report  (loop: max 3 attempts)
    |
    v
 4. ui-impact-analyst  --> user-visible-changes + ui-surface-map
    |
    v
 5. ui-test-designer   --> ui-test-plan + what-to-click          [frontend only]
    |
    v
 6. browser-qa-agent   --> ui-test-results                       [frontend only]
    |
    v
 7. qa (validate)      --> qa-report                    (loop: max 3 attempts)
    |
    v
 8. ux-regression      --> ux-regression-report                  [frontend only]
    |
    v
 9. auditor            --> audit-report                 (loop: max 2 attempts)
    |
    v
10. phase-closure      --> closure-verdict
    |
    v
11. release-manager    --> summary.json + branch + commit + PR
```

Steps 5, 6, and 8 are skipped for backend-only phases (`Frontend Present: no`).

## Goal Mode Pipeline

Goal mode wraps the phase pipeline in an outer loop driven by an AI evaluator.

```
docs/goal.md  (Must-have user journeys + Anti-goals)
    |
    v
 +-- run-goal.sh outer loop ---------------------------------------+
 |                                                                 |
 |   Halt checks (max-iter | stall | regression | quota = pause)   |
 |       |                                                         |
 |       v                                                         |
 |   goal-decomposer  --> docs/phases/goal-<sid>-iter-<N>.md       |
 |       |                                                         |
 |       v                                                         |
 |   depth: lean ?  ----- yes ---->  goal-iter-lean.sh             |
 |                                   (dev -> review -> browser-qa) |
 |       |                                                         |
 |       no (full)                                                 |
 |       v                                                         |
 |   run-phase.sh <iter-name> --no-finalize                        |
 |   (existing 11-step pipeline; release deferred to session end)  |
 |       |                                                         |
 |       v                                                         |
 |   goal-evaluator  --> verdict + journey-history.json + log      |
 |       |                                                         |
 |   loop unless GOAL_ACHIEVED, BUDGET_EXHAUSTED, STALLED, or      |
 |   REGRESSION_HALT                                               |
 |                                                                 |
 +-----------------------------------------------------------------+
```

Iteration name `goal-<sid>-iter-<N>` is used as the "phase name" so existing scripts and agents need no changes. Artifacts isolate naturally under disjoint namespaces.

## Agent Roles

| Agent | Model Tier | Pipeline Step | What it does |
|-------|-----------|---------------|--------------|
| `orchestrator` | strong | 1 | Reads phase spec, writes execution plan |
| `developer` | strong | 3 | TDD implementation (backend + frontend) |
| `reviewer` | standard | 3 | Code review against spec and architecture |
| `qa` | light | 2, 7 | Test plan generation (mode 1) and QA validation (mode 2) |
| `auditor` | strong | 9 | Skeptical post-QA audit, may apply critical fixes |
| `release-manager` | light | 11 | Git branch, commit, push, PR |
| `product-manager` | strong | (optional) | Architecture planning before phase spec |
| `ui-impact-analyst` | standard | 4 | Maps code changes to user-visible UI surfaces |
| `ui-test-designer` | standard | 5 | Creates UI test plans and operator verification guides |
| `browser-qa-agent` | standard | 6 | Executes browser tests via Chrome MCP |
| `ux-regression-reviewer` | standard | 8 | Checks UI evolved with capabilities, flags regressions |
| `phase-closure-auditor` | standard | 10 | Final gate: validates all artifacts exist and are non-vague |
| `goal-decomposer` | strong | (goal mode) | Reads goal + state, writes next iteration spec, picks lean/full depth |
| `goal-evaluator` | strong | (goal mode) | Skeptical done/regression/stall judgment, updates journey-history |

Model tiers are defined in `config/agent-models.yaml`. Change assignments there and run `./scripts/automation/sync-agent-models.sh`.

## Commands

```bash
# Full pipeline
./scripts/automation/run-phase.sh phase-1              # all 11 steps
./scripts/automation/run-phase.sh phase-1 --auto-release  # auto-commit + PR

# Individual steps
./scripts/automation/dev-phase.sh phase-1              # implement
./scripts/automation/review-phase.sh phase-1           # review
./scripts/automation/qa-phase.sh phase-1               # QA validate
./scripts/automation/phase-audit.sh phase-1            # post-QA audit
./scripts/automation/finalize-phase.sh phase-1         # commit + PR

# UI pipeline
./scripts/automation/ui-impact-phase.sh phase-1        # analyze UI impact
./scripts/automation/ui-test-design-phase.sh phase-1   # create UI test plan
./scripts/automation/browser-qa-phase.sh phase-1       # run browser QA
./scripts/automation/ux-regression-phase.sh phase-1    # check UX regression
./scripts/automation/phase-closure-check.sh phase-1    # final closure gate

# Utilities
./scripts/automation/generate-test-plan.sh phase-1     # write test plan before dev
./scripts/automation/ui-audit-phase.sh phase-1         # standalone UI audit
./scripts/automation/sync-agent-models.sh              # sync model assignments
./scripts/automation/check-install.sh "pip install X"  # check install safety
./scripts/automation/update-docs.sh --framework        # update framework docs
./scripts/automation/update-docs.sh phase-1            # update project docs

# Goal mode
./scripts/automation/run-goal.sh --session-id my-app                    # full goal-mode loop
./scripts/automation/run-goal.sh --session-id my-app --resume           # resume an in-flight session
./scripts/automation/run-goal.sh --session-id my-app --reset            # discard session and restart
./scripts/automation/run-goal.sh --session-id my-app --max-iter 50      # raise iteration cap
./scripts/automation/run-goal.sh --session-id my-app --stall-window 5   # widen stall window
./scripts/automation/run-goal.sh --session-id my-app --auto-release     # release-manager runs once on GOAL_ACHIEVED
./scripts/automation/run-goal.sh --session-id my-app --acknowledge-regression  # continue past REGRESSION_HALT
./scripts/automation/goal-iter-lean.sh <iter-name>                      # single lean iteration (advanced)
```

## Security

- **Supply-chain gate**: Every `pip install`, `npm install`, `git clone`, and `curl | bash` is intercepted. Policy in `config/install-security-policy.json`.
- **Command guard**: Dangerous commands (rm -rf /, force-push main, credential reads) are blocked.
- **Post-edit lint**: Edited Python files get syntax-checked. TypeScript files get type-checked.
- **Artifact quality**: Phase reports are checked for vague placeholder content.
- **Stop check**: Warns if a phase run is in-progress when the session ends.

## Templates

| Template | Use when |
|----------|---------|
| `templates/phase-spec.md` | Writing a new phase spec |
| `templates/dev-handoff.md` | Developer agent output reference |
| `templates/review-checklist.md` | Reviewer agent output reference |
| `templates/test-plan.md` | QA test plan reference |
| `templates/qa-report.md` | QA validation report reference |
| `templates/audit-report.md` | Auditor report reference |
| `templates/implementation-summary.md` | Implementation summary format |
| `templates/user-visible-changes.md` | User-visible changes format |
| `templates/ui-surface-map.md` | UI surface map format |
| `templates/ui-test-plan.md` | UI test plan format |
| `templates/ui-test-results.md` | Browser QA results format |
| `templates/what-to-click.md` | Operator verification guide format |
| `templates/closure-verdict.md` | Phase closure verdict format |
| `templates/project-goal.md` | Project goal document template (now includes Must-have user journeys + Anti-goals — required for goal mode, ignored by phase mode) |
| `templates/architecture-overview.md` | Project architecture doc template |

## Configuration

| File | Purpose |
|------|---------|
| `.claude/project-template.md` | Project stack, test commands, architecture rules |
| `config/agent-models.yaml` | Agent-to-model-tier assignments |
| `config/install-security-policy.json` | Package allowlists and deny patterns |
| `.claude/settings.json` | Claude Code tool permissions |
| `docs/goal.md` | Project vision and success criteria (goal mode also reads Must-have user journeys + Anti-goals) |
| `runs/goal-session-<sid>/session.json` | Goal-mode session state (halt config, current iteration, last verdict) |
| `runs/goal-session-<sid>/state/journey-history.json` | Per-journey pass/fail/regressed status across iterations |
| `runs/goal-session-<sid>/telemetry.jsonl` | Structured event log for the session — see [`docs/goal-mode-telemetry.md`](docs/goal-mode-telemetry.md) |

## Subrepo Usage

This framework is designed to be added to project repos as a submodule or subtree. Framework files live under `.claude/`, `scripts/`, `config/`, and `templates/` -- directories that do not conflict with typical project layouts. Project-specific docs go in `docs/`.

## Architecture Documentation

- **Framework docs**: [`.claude/architecture/`](.claude/architecture/README.md) -- how this framework works
- **Project docs**: `docs/architecture/` -- what the project has built (auto-updated per phase)

## Known Limitations

1. **Service bootstrap**: QA expects `CHAIN_START_BACKEND_CMD` or `scripts/start-backend.sh`.
2. **Claude Code only**: Hooks and agent definitions are Claude Code-specific.
3. **Model tier costs**: Assumes access to Claude API with multiple model tiers.
4. **No CI integration**: Pipeline is CLI-only. GitHub Actions integration is not included.
5. **Chrome MCP optional for phase mode**: Browser checks require Chrome MCP. Without it, browser tests are skipped.
6. **Chrome MCP required for goal mode**: The goal-evaluator anchors its `GOAL_ACHIEVED` decision on browser-qa journey results. Without Chrome MCP, browser tests are SKIPPED and the evaluator will likely emit `ESCALATE` indefinitely.

## Tests

```bash
./tests/automation/test-install-gate.sh   # supply-chain gate unit tests
./tests/automation/test-quota-retry.sh    # quota-retry unit tests
```
