# CLAUDE.md — AI Multi-Agent Dev Chain

The operating constitution for all agents in this project. It is auto-loaded into every
agent's context, so it stays SHORT and routes to focused files — read the routed file for
your role before acting; do not guess its contents.

---

## MODES

| Mode | Entry point | What it is |
|------|------------|------------|
| **Phase mode** | `./scripts/automation/run-phase.sh <phase-name>` | Human-authored specs in `docs/phases/`, one 11-step pipeline per phase, human-gated between phases. The default. |
| **Goal mode** | `./scripts/automation/run-goal.sh --session-id <id>` | One `docs/goal.md` (Must-have journeys + Anti-goals); continuous `decompose → execute → evaluate` loop until the evaluator + deterministic gates declare the goal achieved or a hard halt fires. |

Goal-mode usage: [`docs/goal-mode-quickstart.md`](docs/goal-mode-quickstart.md) · internals: [`.claude/architecture/goal-mode.md`](.claude/architecture/goal-mode.md) · interactive `/goal` commands: [`docs/goal-mode-interactive.md`](docs/goal-mode-interactive.md). The modes write to disjoint namespaces (`runs/<phase>/` vs `runs/goal-session-<sid>/`).

Both modes run on **Claude Code** (default) or **OpenAI Codex CLI** (`--cli codex`). One neutral asset source (`agents/`, `skills/`, `commands/`, `hooks/`, `policy/`, `config/`) renders the per-CLI trees; **edit the neutral source, never the generated `.claude/` mirrors** — see `.claude/maintenance-protocol.md` §3. Full guide: [`docs/cli-providers.md`](docs/cli-providers.md).

---

## INSTRUCTION FILES — who reads what

| File | Contents | Who reads it |
|------|----------|--------------|
| `.claude/core.md` | Universal quality rules, testing checklist, security baseline, token policy | **All agents** |
| `.claude/workflow.md` | Pipeline stages, retry policy, artifact locations, verdict formats, UI evolution policy | **All agents** |
| `.claude/project-template.md` | Project stack, test/run commands, architecture principles | **All agents** |
| `.claude/model-orchestration.md` | Model×effort table, delegation package, reporting contract, escalation ladder, non-self-verification rules | Orchestrator, pump, anyone dispatching agents |
| `.claude/judgment-rubrics.md` | Executable judgment criteria (escalation, definition-of-done, stop-and-ask, wrong-direction signals, evidence floors, honesty) with ✚/✖ examples | Judges (evaluator, auditor, decomposer, reviewer) and anyone making verdict-class calls |
| `.claude/delegation-templates.md` | Fill-in dispatch templates (search/implement/refactor/research/review) | Anyone dispatching agents |
| `.claude/maintenance-protocol.md` | Which files may be edited autonomously vs. need the user; the resync invariant; lessons format; condensation rule | Anyone editing framework/instruction files |
| `.claude/anti-patterns.md` | Documented failure modes from production use | Orchestrator, reviewer, auditor; add new ones per maintenance protocol §2 |
| `.claude/letter-to-future-sessions.md` | How this system degrades and what to check first | New sessions doing framework work |
| `.claude/architecture/` | System architecture, agent catalog, pipeline flow, artifact map | Reference (all agents) |

## AGENTS AND SKILLS

**Agents** live in `.claude/agents/<name>.md` (rendered from `agents/<name>/`): the
pipeline chain (orchestrator, developer, reviewer, qa, auditor, release-manager,
product-manager), the UI chain (ui-impact-analyst, ui-test-designer, browser-qa-agent,
phase-closure-auditor, ux-regression-reviewer), goal mode (goal-decomposer, goal-evaluator,
coherence-auditor, goal-proposer), and showcase (iteration-summarizer, demo-narrator,
readme-maintainer). Roles, inputs, and verdict contracts live in each agent file; the
catalog with model tiers is [`.claude/architecture/agents.md`](.claude/architecture/agents.md).

**Skills** (reusable methodologies) live in `.claude/skills/` — each agent's body names
the skills it must follow. Catalog: [`.claude/architecture/skills-and-hooks.md`](.claude/architecture/skills-and-hooks.md).

Model routing: each agent's `model_tier` (`agents/<name>/agent.yaml`) resolves through
`config/model-tiers.yaml`; the rendered frontmatter model is applied on BOTH backends
(headless `--model` injection and pump subagents). Fix-mode retries escalate to the strong
tier; GOAL_ACHIEVED must pass deterministic gates plus a two-key confirm. Details:
`.claude/model-orchestration.md`.

---

## QUICK START

```bash
./scripts/automation/run-phase.sh phase-1              # full phase pipeline
./scripts/automation/run-goal.sh --session-id my-app   # goal mode (headless)
# inside Claude Code:  /goal [sid] · /goal-status · /goal-resume · /goal-pause · /goal-step
./scripts/automation/run-evals.sh                      # offline eval suite (<30s, no API)
python3 scripts/automation/sync-cli-assets.py --cli claude   # re-render .claude/ after neutral-source edits
```

The full command reference (individual steps, demos, rendering, telemetry, replay) is in
[`README.md`](README.md) — agents rarely need it; the pipeline scripts invoke each other.

## PROJECT CONFIGURATION

Before the first run: fill `docs/goal.md` (vision, Must-have journeys, Anti-goals — use
`templates/project-goal.md`) and `.claude/project-template.md` (stack, test/start commands,
architecture principles, never-commit list).

## COMMUNICATION MODEL

Agents communicate ONLY through filesystem artifacts — no free-form agent-to-agent chat.
Artifact locations and verdict formats: `.claude/workflow.md`. Verdict lines are parsed by
machine; emit them EXACTLY as your agent file specifies.

## CORE PRINCIPLES (summary — full rules in `.claude/core.md`)

- Build ONLY what the current phase/iteration specifies — stop immediately after.
- Every phase/iteration produces a visible change or measurable capability, with tests.
- Every claim cites evidence; unknown is a first-class answer (`.claude/judgment-rubrics.md`).
- No force-push to main; no secrets committed; no paid services without explicit approval.
- Token policy: read the curated inputs your agent file lists — not entire histories.
