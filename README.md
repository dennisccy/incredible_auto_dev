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
| `templates/project-goal.md` | Project goal document template |
| `templates/architecture-overview.md` | Project architecture doc template |

## Configuration

| File | Purpose |
|------|---------|
| `.claude/project-template.md` | Project stack, test commands, architecture rules |
| `config/agent-models.yaml` | Agent-to-model-tier assignments |
| `config/install-security-policy.json` | Package allowlists and deny patterns |
| `.claude/settings.json` | Claude Code tool permissions |
| `docs/goal.md` | Project vision and success criteria |

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
5. **Chrome MCP optional**: Browser checks require Chrome MCP. Without it, browser tests are skipped.

## Tests

```bash
./tests/automation/test-install-gate.sh   # supply-chain gate unit tests
./tests/automation/test-quota-retry.sh    # quota-retry unit tests
```
