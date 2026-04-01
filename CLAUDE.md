# CLAUDE.md — AI Multi-Agent Dev Chain

This is the operating constitution for all agents working in this project.
All agents MUST read this file and the files it references before taking any action.

---

## MODULAR INSTRUCTION SYSTEM

This constitution is split into focused files. Agents must read the relevant files for their role:

| File | Contents | Who reads it |
|------|----------|--------------|
| `.claude/core.md` | Universal quality rules, testing checklist, security baseline, token policy | **All agents** |
| `.claude/workflow.md` | Pipeline stages, retry policy, artifact locations, verdict formats, UI evolution policy | **All agents** |
| `.claude/project-template.md` | Project name, stack, test commands, architecture principles | **All agents** |
| `.claude/anti-patterns.md` | Lessons learned, failure modes to avoid | **Orchestrator, reviewer, auditor** |

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

---

## QUICK START

```bash
# Run a full phase end-to-end
./scripts/automation/run-phase.sh phase-1

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
./scripts/automation/ux-regression-phase.sh phase-1   # check UX regression
./scripts/automation/phase-closure-check.sh phase-1   # final closure gate
```

---

## PROJECT CONFIGURATION

Before running any phase, fill in `.claude/project-template.md` with:
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

See `.claude/anti-patterns.md` for 14 documented failure modes from production use.
Most common: vague acceptance criteria → infinite review loops.
