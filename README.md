# AI Multi-Agent Dev Chain

A reusable framework for running phased software development with Claude AI agents. The chain handles the full lifecycle: planning, implementation, review, UI validation, QA, audit, and release.

## What This Is

A collection of:
- **Claude agent definitions** covering the full dev lifecycle, UI visibility, per-iteration summary, and an auto-recorded product demo — every agent is listed in [Agent Roles](#agent-roles)
- **Automation shell scripts** orchestrating an 11-step pipeline plus an on-demand demo viewer
- **Security hooks** guarding against supply-chain attacks, dangerous commands, and vague artifacts
- **Skills** providing reusable methodologies for UI analysis, test design, and doc updates
- **Report templates** for consistent handoffs across all agents
- **A modular CLAUDE.md system** (core rules, workflow, project config, anti-patterns, architecture docs)

The chain has checkpoint/resume, quota-exhaustion auto-retry, and a verdict-gated pipeline where each stage must pass before the next runs.

For comprehensive framework documentation, see [`.claude/architecture/`](.claude/architecture/README.md).

## Modes

The framework supports two modes:

**Phase mode** (the original) — you author phase specs in `docs/phases/` and run them one at a time through the 11-step pipeline. Each phase is a discrete, gated unit of work with a human-defined scope. Use this when you have a clear roadmap and want a human gate between every phase. Entry point: `./scripts/automation/run-phase.sh <phase-name>`.

**Goal mode** (added later, parallel to phase mode) — you author `docs/goal.md` once with **Must-have user journeys** and **Anti-goals**, then run `./scripts/automation/run-goal.sh`. The system loops `decompose → execute → evaluate` adaptively (lean cycle for small changes, full 11-step pipeline for risky ones) until an AI evaluator declares the goal achieved or a hard halt fires (max iterations, stall, regression). Quota exhaustion does NOT halt the loop — it pauses and auto-resumes when quota resets. Use this when you want autonomous, unattended development against a fixed product target. See [`docs/goal-mode-quickstart.md`](docs/goal-mode-quickstart.md) and [`.claude/architecture/goal-mode.md`](.claude/architecture/goal-mode.md).

The two modes share all agents and skills. They write to disjoint artifact namespaces (`runs/<phase>/` vs `runs/goal-session-<sid>/`) so you can use both in the same project without collision.

### CLI Provider (Claude or Codex)

Both modes can run on either **Claude Code** (default) or **OpenAI Codex CLI** — pass `--cli claude|codex` to either entry script. A single canonical asset source under `agents/`, `skills/`, `hooks/`, `policy/`, and `config/` is rendered into per-CLI trees (`.claude/`, `.codex/`) on first run; nothing is duplicated. Goal mode pins the choice in `session.json`; phase mode is per-run. Full guide in [`docs/cli-providers.md`](docs/cli-providers.md).

#### Multi-CLI — deferred / TODO

The multi-CLI infrastructure is in place and the Claude path is verified non-regressing at the script level. The following are intentionally **not yet done** — each needs an API-token budget or a heavier cleanup pass:

- [ ] **Real end-to-end Claude no-regression run.** Run a full phase with `--cli claude` and diff every artifact against a pre-migration baseline. (Script-level + semantic-equivalence checks pass; a real token-burning run is the final gate.)
- [ ] **Real Codex end-to-end run + hardening.** `_codex_invoke` quota/error regexes in `lib/quota-retry.sh` are best-guess. First real `--cli codex` run will reveal the actual OpenAI rate-limit/error wording to match. Expect 1–2 tightening passes.
- [ ] **Codex stream parsing.** `lib/codex_stream_renderer.py` handles several plausible event shapes; confirm against real `codex exec --json` NDJSON and trim to the actual schema.
- [ ] **Retire legacy `.claude/` files from git.** `.claude/agents/*.md`, `.claude/settings.json`, `.claude/hooks/*`, `.claude/skills/*` are still tracked and regenerated on sync (producing small, functionally-identical cosmetic diffs). Move them to `.gitignore` and `git rm --cached` once the Claude no-regression run passes.
- [ ] **`hooks/lib/normalize-input.sh` / `normalize-output.sh`.** Planned shims so one hook script reads a uniform input schema and writes a uniform allow/block decision across both CLIs. SEC-7 inlined the normalization in the two Bash guards (argv → stdin `.tool_input.command` fallback + Claude `permissionDecision` deny-JSON) and CTX-1 did the same for the PostToolUse pair (stdin `.tool_input.file_path`, advisory); the shim remains TODO purely for deduplication.
- [ ] **Architecture docs.** `.claude/architecture/*.md` still describe the pre-migration Claude-only layout; update for the neutral source + adapter model.
- [ ] **MCP servers in neutral source.** `policy/mcp-servers.yaml` is a stub; Claude MCP/plugins currently live in `adapters/claude/passthrough/`. Promote to neutral source when a shared MCP definition is actually needed.
- [ ] **Mixed-CLI runs (per-agent override).** Architecture supports a per-agent `cli:` field in `agent.yaml`; not wired up. Deferred until there's a real use case.
- [ ] **Codex profiles for non-default tiers.** Generated `.codex/config.toml` sticks to a single profile.

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

**1. Author `docs/goal.md` from `templates/project-goal.md`**, including the **Must-have user journeys** and **Anti-goals** sections (required for goal mode; phase mode ignores them). Optionally fill the **Product Shape** section (a navigation sketch + the list of *canonical values*) — it seeds the coherence blueprint and is the best defense against the same number showing different values on different pages.

**2. Configure `.claude/project-template.md`** the same way you would for phase mode.

**3. Run.**

```bash
./scripts/automation/run-goal.sh --session-id my-app
```

Optional flags: `--max-iter N` (optional hard cap on iterations; **unlimited by default**), `--stall-window N` (default 3), `--auto-release` (opens PR from `goal/<sid>` branch on `GOAL_ACHIEVED`), `--push-per-iter` / `--no-push-per-iter` (per-iter commits land on a single per-session branch; default ON), `--push-branch <name>` (override the default `goal/<sid>` name), `--require-blueprint-approval` (pause after baseline to review the drafted blueprint; **off by default — the blueprint is auto-approved**), `--resume`, `--reset`, `--acknowledge-regression`.

After baseline the decomposer drafts a coherence blueprint at `runs/goal-session-my-app/state/blueprint.md` and, **by default, auto-approves it and keeps running unattended** — a `coherence-auditor` then enforces the blueprint every iteration. If you'd rather review it first (~3 min: sane navigation? every shared value has one source?), start with `--require-blueprint-approval`: the loop pauses once (`AWAITING_BLUEPRINT_APPROVAL`), and you edit the file if needed then `--resume` (resuming counts as approval).

**4. Inspect** `runs/goal-session-my-app/summary.md` when the loop halts. Halt verdicts: `GOAL_ACHIEVED` (success), `BUDGET_EXHAUSTED`, `STALLED`, `REGRESSION_HALT`, `ABORTED`, `AWAITING_BLUEPRINT_APPROVAL` (resumable pause for blueprint review — only with `--require-blueprint-approval`), `AWAITING_GITHUB_AUTH` (resumable pause — push-per-iter is on but `origin` won't authenticate; the run offers `gh auth login` when interactive, else `gh auth login && gh auth setup-git` then `--resume`), `AWAITING_FULL_DEPTH` (resumable pause — the iteration declared full depth a HARD requirement via `CHAIN_REQUIRE_FULL_DEPTH` or a `Depth enforcement: required` spec line and only lean could be dispatched, so nothing ran; set `CHAIN_FULL_CADENCE_CAP=1` or `CHAIN_DEPTH_ARBITER=false`, or let the cadence window pass, then `--resume` — never clear the requirement).

Because per-iter push is on by default, goal mode checks at startup that a push to `origin` would authenticate, so an expired GitHub session can't stall a mid-run push on a credential prompt. Pushes are also run with `GIT_TERMINAL_PROMPT=0` so they fail fast (non-fatally) instead of hanging. Skip the startup check with `CHAIN_SKIP_GITHUB_PREFLIGHT=true`.

Quota exhaustion is NOT a halt — the loop pauses and auto-resumes when the quota resets.

See [`docs/goal-mode-quickstart.md`](docs/goal-mode-quickstart.md) for the full guide.

### Run Goal Mode inside Claude Code (interactive)

Prefer to run it from an interactive Claude Code session, with the work billed to your **interactive plan allowance** instead of the headless Agent SDK credit? Start `claude`, then:

```text
/goal my-app
```

`/goal` runs the **same** engine until the goal is achieved or an existing rule halts/pauses it — same stop rules, resume, and quota handling — but dispatches each agent as a subagent in your live session. Companion commands: `/goal-status`, `/goal-resume`, `/goal-pause`, `/goal-step`. The pump runs quietly (the full timestamped chain log streams to `runs/goal-session-<sid>/engine.log`); press Ctrl+C then `/goal-pause` to pause cleanly and `/goal-resume` to continue. It is for individual development use; shared/team production automation should use the programmatic `run-goal.sh` path with an API key. Full guide: [`docs/goal-mode-interactive.md`](docs/goal-mode-interactive.md).

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
 6.5 demo-narrator      --> demo-script + demo-results + screenshots [frontend only, showcase]
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
10.5 iteration-summarizer --> iteration-summary.md + summary.html
    |
    v
11. release-manager    --> summary.json + branch + commit + PR
```

Steps 5, 6, 6.5, and 8 are skipped for backend-only phases (`Frontend Present: no`).

Step 6.5 (the demo) is **showcase, not gate** — a failed step is a soft note, never a hard pipeline fail. It re-uses the app already booted by browser QA in the same window (idempotent `ensure_services_running`), so no second app boot.

## Iteration Summary + HTML Report

Step 10.5 produces a single conclusive per-iteration markdown at
`reports/phase-<phase>-iteration-summary.md`. It answers the four questions a
developer actually has after a run: what was done, what's left, what direction
the project is moving (improving / holding / stalling / regressing — for goal
mode), and what the next step is. This MD is the source of truth.

A deterministic HTML renderer turns that MD into a self-contained
`reports/phase-<phase>-summary.html` (inline CSS, base64-embedded screenshots,
no remote refs). Goal mode also writes a session-level
`reports/goal-session-<sid>-index.html` that lists every iteration as a card
with a journey progress matrix.

Regenerate either or both at any time:

```bash
bash scripts/automation/render-summary.sh <phase-id>                  # rebuild MD via agent + render HTML
bash scripts/automation/render-summary.sh <phase-id> --no-resummarize # re-render HTML only (no API tokens)
bash scripts/automation/render-summary.sh --session-index <sid>       # re-render goal-mode session index
```

## Non-Technical Summary & Live Demo

The framework writes a layered view of every iteration so that **anyone — not just developers — can understand what was built and decide what's next.** Three things happen, automatically, on every iteration:

1. **Plain-language layer in the iteration summary.** The iteration-summary HTML (the page at `reports/phase-<phase>-summary.html`) now *leads* with a `## In plain words` block: *What you can do now / What changed this time / What's next*. No jargon, no file names, no journey IDs. The technical sections (Direction, What was done, Quick verify, Artifacts) are kept exactly as before — they just sit below, **collapsed by default**, for when a developer wants to drill down.

2. **An auto-recorded narrated demo (Step 6.5).** Right after browser QA — in the same app-up window — the framework walks the **whole working product so far** in a real browser, captures one captioned screenshot per step, and assembles them into a "Watch it work" gallery on the same page. Steps that were added or visibly changed this iteration are flagged `[NEW]`. Showcase, not QA — a failed step is a soft note in `demo-results.md`, never a hard pipeline fail.

3. **A continuously-updated "Project story so far" + GOAL_ACHIEVED wrap** (goal mode only). The `iteration-summarizer` agent also maintains `runs/goal-session-<sid>/state/project-story.md` — one flowing plain-language narrative of how the product grew, rewritten each iteration so it reads end-to-end. The session index HTML (`reports/goal-session-<sid>-index.html`) leads with this story plus the latest demo gallery. When `goal-evaluator` finally returns `GOAL_ACHIEVED`, the framework emits a one-time polished `goal-session-<sid>-delivered.html` — a celebratory "what we delivered" page with the final walkthrough embedded, linked from a banner on the session index.

### Watch your app — how to run & what to expect

Watch your built app run in a **real Chrome window** while plain-language
explanations print in your terminal. You press **Enter** to step through it —
like someone sitting next to you demoing the product.

```bash
# Live walkthrough of the WHOLE product built so far (every working feature)
./scripts/automation/demo.sh <session-id> --session-live

# Live walkthrough of a single iteration
./scripts/automation/demo.sh <iter-id> --live          # e.g. goal-money-iter-3 (or phase-1)

# Just open the recorded picture gallery — no live window
./scripts/automation/demo.sh <id>                      # phase OR session id
./scripts/automation/demo.sh --latest                  # most recent gallery
./scripts/automation/demo.sh <sid> --delivered         # the GOAL_ACHIEVED "delivered" wrap
```

**What to expect (live):** A Chrome window opens. For each step the terminal
prints a short, non-technical explanation and the matching on-screen element is
highlighted; press **Enter in this terminal** (not the browser) to perform that
step and watch it happen, then the terminal tells you what to notice. At the end
the window stays open until you press Enter one last time. It never types on its
own — you control the pace. A step looks like:

```
── Step 02/06 ─ Open the new-report form  [NEW]
   We open the form to create a report.
   ▶ Press Enter (in this terminal) to perform this step…
   ↳ Notice: a blank form titled "New Report".
```

**Prerequisites & notes:**
- Live mode opens a real browser window, so it needs a display. It works over SSH X11 forwarding (may lag a little — that's normal). On a fresh machine it prints the one `python3 -m pip install --user playwright` command if Playwright isn't set up yet.
- The app is started automatically if it isn't already running.
- The first live run prepares the walkthrough once (a few seconds); repeat runs reuse it and open instantly. Add `--reauthor` to rebuild it after big changes.

**If you can't see a window** (headless / remote without X): open the recorded
gallery instead (`./scripts/automation/demo.sh <id>`), or set
`CHAIN_DEMO_LIVE_FALLBACK_RECORD=true` to auto-record instead of going live.

**Optional touches:** `CHAIN_DEMO_VIDEO=true` also saves a video of the run;
`CHAIN_DEMO_CAPTION=true` overlays the explanation on the page itself.

**Troubleshooting:** a `⚠ couldn't find that element — skipping` line is expected
and harmless — the demo just continues to the next step. *"Nothing to show yet"*
means it's an early or backend-only iteration with no features to walk through.

### Outputs produced

**New to these files and the status codes inside them?** Read
[`docs/READING-REPORTS.md`](docs/READING-REPORTS.md) — a plain-language guide to
which report to open and what every code means.

| Artifact | Where | Audience |
|----------|-------|----------|
| Plain-language section + Watch-it-work gallery + technical accordions | `reports/phase-<phase>-summary.html` | Everyone |
| Narrated demo script (record mode) | `reports/phase-<phase>-demo-script.md` | Reviewable text source for the gallery |
| Demo results + verdict (`RECORDED` / `RECORDED_WITH_NOTES` / `SKIPPED` / `NOT_YET`) | `reports/phase-<phase>-demo-results.md` | Renderer + audit trail |
| Captioned screenshots | `reports/demo/<phase>/step-NN.png` | Embedded into the HTML |
| Cumulative "Project story so far" (goal mode) | `runs/goal-session-<sid>/state/project-story.md` | Rendered into the session index |
| Session index (story + latest gallery + matrix + per-iter cards) | `reports/goal-session-<sid>-index.html` | Everyone |
| One-time delivered wrap (MD + HTML) | `reports/goal-session-<sid>-delivered.{md,html}` | Everyone, on `GOAL_ACHIEVED` |

For more, see [`docs/goal-mode-quickstart.md`](docs/goal-mode-quickstart.md), [`runs/SCHEMA.md`](runs/SCHEMA.md) (artifact registry), and [`.claude/architecture/artifacts.md`](.claude/architecture/artifacts.md) (producer/consumer matrix).

Screenshots of the rendered HTML appear in this section after your first iteration runs end-to-end — the artifacts are real, not mocked.

## Faster Iterations

Three always-on improvements shorten every iteration:

- **Tier 1 prompt polish.** Per-agent prompts no longer re-read `CLAUDE.md` (it's auto-loaded into the system prompt) and the duplicated "Token and Questioning Policy" boilerplate that paraphrased `.claude/core.md` has been removed from every agent body. Each call is smaller and the static prefix is more cache-friendly. **Behavior is unchanged** — same artifacts, same verdicts.
- **Per-agent `--effort` overrides.** Reasoning-heavy agents (`developer`, `reviewer`, `auditor`, `orchestrator`, `goal-decomposer`, `goal-evaluator`, `browser-qa-agent`, `demo-narrator`) stay at `--effort max`. Structured / mechanical agents (`release-manager`, `qa`, `ui-test-designer`, `ui-impact-analyst`, `phase-closure-auditor`) drop to `--effort medium` for shorter responses without losing what they need to do their job. Set `CHAIN_DISABLE_EFFORT_OVERRIDE=true` to restore `--effort max` for every agent.
- **Parallel post-dev fanout.** After Step 3 finishes, the safe post-dev pairs run **in parallel** with shared services:

```
                        (Step 3: dev + review)
                                │
                                ▼
                  ┌─────────────── shared app boot ──────────────┐
                  │                                              │
  ┌─ Branch A (UI chain, sequential) ─┐    ┌─ Branch B (QA) ─┐
  │  ui-impact   →  ui-test-design    │    │  qa-validate    │
  │     →  browser-qa  →  demo        │    │                 │
  └──────────────┬───────────────────┘    └──────┬──────────┘
                 │                               │
                 └────────── wait both ──────────┘
                                │
                                ▼
                    Step 8: ux-regression   →   close + finalize
```

The fanout writes a single `post_dev_parallel_complete` checkpoint after both branches succeed. If Branch B's QA verdict fails, the existing sequential Step 7 retry loop still runs (dev → review → qa, up to 3 attempts) — so the self-heal path is preserved. If either branch is interrupted by signal or hits quota, the parent propagates the same exit code and the next resume re-runs the fanout from scratch. Backend-only phases (`Frontend Present: no`) skip the fanout and run the sequential Step 4 → 5 → 6 → 6.5 → 7 blocks instead.

Expected wall-clock reduction over the pre-parallel pipeline: **~30–50% for full phase iterations**, **~15–25% for lean goal-mode iterations** (lean has nothing to parallelise; the gain comes entirely from Tier 1 polish + `--effort` drops).

```bash
CHAIN_DISABLE_EFFORT_OVERRIDE=true ./scripts/automation/run-phase.sh phase-1   # escape hatch: restore --effort max
```

Implementation notes for advanced users: the parallel runner is in [`scripts/automation/lib/parallel.sh`](scripts/automation/lib/parallel.sh); shared services are coordinated via the `CHAIN_SHARED_SERVICES=true` env contract that `browser-qa-phase.sh`, `qa-phase.sh`, and `demo-phase.sh` honor; per-agent effort is resolved by `agent_permissions.py effort <agent>`. Telemetry (`CHAIN_TELEMETRY_TOKENS=true`, default) records per-agent input/output/cache/cost so you can quantify the gain on your own workloads.

## Goal Mode Pipeline

Goal mode wraps the phase pipeline in an outer loop driven by an AI evaluator.

```
docs/goal.md  (Must-have user journeys + Anti-goals)
    |
    v
 +-- run-goal.sh outer loop ---------------------------------------+
 |                                                                 |
 |   Halt checks (max-iter | stall | regression | quota = pause)   |
 |   Blueprint approval pause (after baseline / structural change) |
 |       |                                                         |
 |       v                                                         |
 |   goal-decomposer  --> docs/phases/goal-<sid>-iter-<N>.md       |
 |       (baseline also drafts state/blueprint.md)                 |
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
 |   coherence-auditor --> iter-<N>/coherence.md (vs blueprint)    |
 |       |                                                         |
 |       v                                                         |
 |   goal-evaluator  --> verdict + journey-history.json + log      |
 |       (COHERENCE-FAIL vetoes GOAL_ACHIEVED -> consolidation)    |
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
| `iteration-summarizer` | light | 10.5 | Synthesizes the per-iteration summary MD (what was done / left / direction) that drives the HTML report; also maintains the cumulative `project-story.md` and writes the one-time `delivered.md` wrap on `GOAL_ACHIEVED` |
| `demo-narrator` | standard | 6.5 | Authors a machine-executable demo-script (steps + narration) from the iteration's verified flows; the deterministic Playwright runner (`lib/demo_runner.py`) executes it to produce the recorded "Watch it work" gallery and the live walkthrough. Showcase, not gate. |
| `goal-decomposer` | strong | (goal mode) | Reads goal + state, writes next iteration spec, picks lean/full depth; drafts the blueprint at baseline |
| `goal-evaluator` | strong | (goal mode) | Skeptical done/regression/stall judgment, updates journey-history; vetoes GOAL_ACHIEVED on COHERENCE-FAIL |
| `coherence-auditor` | standard | (goal mode) | Audits each iteration's diff against the blueprint (information architecture + data contract); hard-fails only on objective drift |
| `goal-proposer` | strong | (goal mode, opt-in) | After every Must-have journey passes, surveys the whole product through the project's usefulness lens (`project-extensions/proposer-guidance.md`), writes an enhancement-proposals backlog, and appends the best survivors as new Must-have journeys in `docs/goal.md` AUTO:journeys — runs only when that guidance file exists |
| `readme-maintainer` | standard | (goal mode) | After each iteration, refreshes the project-root README's marker-delimited AUTO blocks so capabilities and "How to run" stay accurate; non-blocking showcase step, never gates the pipeline |
| `retro-analyst` | light | (goal mode, terminal halts) | At a terminal goal-session halt, reads ONLY the frozen `state/retro-input.md` evidence digest and drafts 1-5 candidate framework-improvement proposals to `reports/goal-session-<sid>-retro.md` for human triage; proposals only, non-blocking, never edits the roadmap |

Model tiers: each agent's `model_tier` lives in `agents/<name>/agent.yaml`; tiers resolve to model ids in `config/model-tiers.yaml`. Edit, then `python3 scripts/automation/sync-cli-assets.py` and commit the regenerated mirrors.

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
./scripts/automation/demo-phase.sh phase-1             # auto-record a narrated product demo (showcase, non-gating)
./scripts/automation/ux-regression-phase.sh phase-1    # check UX regression
./scripts/automation/phase-closure-check.sh phase-1    # final closure gate

# Demo viewer (non-technical owner UX)
./scripts/automation/demo.sh --latest                  # open most recent walkthrough
./scripts/automation/demo.sh <id>                      # open recorded gallery (phase OR session id)
./scripts/automation/demo.sh <id> --live               # live walkthrough of one iteration (press Enter to advance)
./scripts/automation/demo.sh <sid> --session-live      # live walkthrough of the WHOLE product across iterations
./scripts/automation/demo.sh <sid> --delivered         # open the GOAL_ACHIEVED "delivered" wrap

# Utilities
./scripts/automation/run-evals.sh                      # offline eval suite (<30s, no API) — run before every framework commit
bash scripts/automation/install-git-hooks.sh           # OPT-IN pre-commit eval guard (fast subset, <10s) — see Tests
bash scripts/automation/doctor.sh                      # preflight doctor: PASS/WARN/FAIL environment table (advisory; --only <check>, --list, --strict-doctor)
./scripts/automation/generate-test-plan.sh phase-1     # write test plan before dev
./scripts/automation/ui-audit-phase.sh phase-1         # standalone UI audit
./scripts/automation/check-install.sh "pip install X"  # check install safety
./scripts/automation/update-docs.sh --framework        # update framework docs
./scripts/automation/update-docs.sh phase-1            # update project docs
bash scripts/automation/render-summary.sh <phase-id>   # rebuild iteration-summary MD + render HTML
bash scripts/automation/render-summary.sh <phase-id> --no-resummarize  # re-render HTML only (no API tokens)
bash scripts/automation/render-summary.sh --session-index <sid>        # re-render goal-mode session index

# Goal mode
./scripts/automation/run-goal.sh --session-id my-app                    # full goal-mode loop
./scripts/automation/run-goal.sh --session-id my-app --resume           # resume an in-flight session
./scripts/automation/run-goal.sh --session-id my-app --reset            # discard session and restart
./scripts/automation/run-goal.sh --session-id my-app --max-iter 50      # set an optional iteration budget (no cap by default)
./scripts/automation/run-goal.sh --session-id my-app --stall-window 5   # widen stall window
./scripts/automation/run-goal.sh --session-id my-app --auto-release     # release-manager runs once on GOAL_ACHIEVED
./scripts/automation/run-goal.sh --session-id my-app --acknowledge-regression  # continue past REGRESSION_HALT
./scripts/automation/run-goal.sh --session-id my-app --require-blueprint-approval  # pause after baseline to review the blueprint (off by default)
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
| `templates/iteration-summary.md` | Iteration summary format (drives the HTML report; includes the new plain-language `## In plain words` section) |
| `templates/demo-script.md` | Per-iteration narrated demo script (Highlights + Full tour) |
| `templates/demo-results.md` | Per-iteration demo verdict + captured-steps table |
| `templates/project-goal.md` | Project goal document template (now includes Must-have user journeys + Anti-goals — required for goal mode, ignored by phase mode) |
| `templates/architecture-overview.md` | Project architecture doc template |

## Configuration

| File | Purpose |
|------|---------|
| `.claude/project-template.md` | Project stack, test commands, architecture rules |
| `config/model-tiers.yaml` + `agents/*/agent.yaml` | Tier→model map + per-agent tier |
| `config/install-security-policy.json` | Package allowlists and deny patterns |
| `.claude/settings.json` | Claude Code tool permissions |
| `lib/agent_permissions.py` → `OUTPUT_STYLE_OVERRIDES` | Per-agent Claude Code output style (wave-1: `Concise` on developer/qa/browser-qa-agent/orchestrator/ui-impact-analyst/ux-regression-reviewer); inert until `CHAIN_OUTPUT_STYLES=true` — see `.claude/model-orchestration.md` §7 |
| `docs/goal.md` | Project vision and success criteria (goal mode also reads Must-have user journeys + Anti-goals) |
| `runs/goal-session-<sid>/session.json` | Goal-mode session state (halt config, current iteration, last verdict) |
| `runs/goal-session-<sid>/state/journey-history.json` | Per-journey pass/fail/regressed status across iterations |
| `runs/goal-session-<sid>/telemetry.jsonl` | Structured event log for the session — see [`docs/goal-mode-telemetry.md`](docs/goal-mode-telemetry.md) |

**Temp-file hygiene:** every run gets its own `$CHAIN_TMP_ROOT/iad.<run-id>.<pid>` dir (root default `~/.cache/iad` — a big un-quota'd disk, NOT the quota'd tmpfs `/tmp`), exported as `TMPDIR`, so pytest/playwright/service-log temp files are isolated per run and removed on exit (goal mode clears the previous iteration's dir at each iteration boundary). A startup janitor sweeps strays from crashed runs across the root and legacy `/tmp` — stale `iad.*` dirs, `bench-*`/`judgment-*` scratch, `pytest-of-$USER` entries, and the `shared/` interactive-TMPDIR dir — and `chain_tmp_disk_guard` sweeps aggressively under disk pressure (goal mode pauses as resumable `AWAITING_DISK` only when the root filesystem stays critically low). Self-service cleanup any agent can run: `./scripts/automation/tmp-doctor.sh [--status|--clean|--aggressive]`. Knobs: `CHAIN_TMPDIR_DISABLE=true` (leave the environment alone), `CHAIN_TMP_JANITOR=false` (skip the sweep), `CHAIN_TMP_ROOT` (base dir), `CHAIN_TMP_LEGACY_ROOTS` (extra janitor roots, default `/tmp`), `CHAIN_TMP_MAX_AGE_HOURS=24` / `CHAIN_TMP_SHARED_MAX_AGE_HOURS=72` (age gates), `CHAIN_BENCH_KEEP=2` (bench scratch retention), `CHAIN_TMP_MIN_FREE_MB=2048` / `CHAIN_TMP_HARD_MIN_FREE_MB=512` / `CHAIN_TMP_PROBE_MB=32` (disk guard), `CHAIN_TMP_DISK_GUARD=false` (disable the guard). See `.claude/anti-patterns/21-shared-tmp-accumulation.md`.

## Subrepo Usage

This framework is designed to be added to project repos as a submodule or subtree. Framework files live under `.claude/`, `scripts/`, `config/`, and `templates/` -- directories that do not conflict with typical project layouts. Project-specific docs go in `docs/`.

## Architecture Documentation

- **Framework docs**: [`.claude/architecture/`](.claude/architecture/README.md) -- how this framework works
- **Project docs**: `docs/architecture/` -- what the project has built (auto-updated per phase)

## Improvement Roadmap

All pending framework improvements — including the former "Token Optimization — Pending Work" and "Pipeline Hardening — Pending Work" backlogs that used to live here — are maintained in one canonical file: [`docs/improvement-roadmap.md`](docs/improvement-roadmap.md). It holds ~50 specified items (problem, file:line anchors, change spec, definition of done, verification commands, rollback) written so any maintainer session can execute one at a time, plus the executor ground rules and the process for adding new items. Every absorbed item from the old sections is traceable in that file's §17 ledger (several were already shipped and are marked as such).

## Host incident 2026-08-07 — status + pending fix plan (GEEKOM A7 Max)

> **Status 2026-08-08: C-state soak FALSIFIED on day 1 — unit removed; ladder → rung 3 (overnight
> memtest86+ 08-08→09); goal mode PAUSED pending the verdict.** Fault reset #4 (12:48:17 boot)
> fired with C2/C3 verifiably off in the dying boot (journal tag + `host_state`; 30 W / load1
> 3.04 / 84 °C). Postmortem frozen pre-resume: `3f7c111ae8e94cdd8e39ad67cd0cff8b.md`. Memtest
> errors → DIMM isolation → reseat/swap → RMA; clean → BIOS JEDEC baseline → fresh 7-day soak.
> *(Previous status: fix EXECUTED — soak ACTIVE since 2026-08-07 21:02:21 BST.)* Phase 2 framework
> code was committed 17:27 (`be57376` + vendored syncs). The Phase 1 unit was installed 17:26 but
> left **un-enabled** (`sudo cp` only — the implementing session was killed by fault reset #3 at
> 17:46, which fired **near-idle** in exactly that gap); enabled + verified 21:02:21 (journal tag
> `iad-cstate-limit`, sysfs `state[23]/disable` 32×1, `is-enabled`) — that timestamp starts the
> 7-day soak. Pump runs display-less under tmux user scope `goal-pump-tmux`; auto-resume unit
> installed but **disarmed** (API-billing question stands). Daily journal:
> `~/.cache/iad/host-guard/soak-log.md`. Plan files:
> `~/.claude/plans/when-running-trendora-goal-drifting-floyd.md` (diagnosis + fix design),
> `~/.claude/plans/just-after-implementing-the-majestic-sun.md` (execution + reset #3 forensics).

### What happened (evidence-verified)

Reported symptom: while trendora goal mode (session `ops-hardening`, iter 52) ran, the desktop
froze and dropped to the GDM login screen. Investigation found **two distinct failures**:

1. **The reported incident (15:13–15:18, no reboot):** `gnome-shell` logged
   `Invalid sequence for VSYNC frame info` (15:13:15, UI freeze), then **SIGSEGV'd** (15:18:24,
   `org.gnome.Shell@ubuntu.service: result 'core-dump'`); systemd tore down the graphical session →
   login screen. The interactive pump (claude in ghostty) is a child of that session, so pump +
   engine died as collateral (`engine_stop` 15:18:33; orphan `iter52_health_drill.py` left running).
   Ruled out with hwmon/PSI data: memory pressure, oomd, CPU saturation, thermal trip (Tctl 84–89 °C,
   gate 90). Contributing stress: pump-dispatched **browser-QA Chrome runs headed in the session**
   (inherits `WAYLAND_DISPLAY`), spamming Wayland frame errors for hours.
2. **Recurring hardware hard-resets (separate; 02:13, 11:12, then a 3rd at 17:46 that fired
   NEAR-IDLE — 20–39 W, engine stopped, C-state unit installed-but-disabled; see Status):** 6 of the last
   10 boots began from kernel reset-reason `0x08000800 — an uncorrected error caused a data fabric
   sync flood event`. Settled 2026-07-30 (reset #7 fired with every software mitigation in force at
   26–37 W / 65–74 °C): **hardware marginality**, not load. Boost-off/split-masks/engine-cap were
   deliberately released 2026-07-30 — do **not** re-impose them. Failure 1's segfault is plausibly
   collateral of the same marginal silicon.
   Runbook status (`docs/host-guard.md` §"After a hardware reset", line 123): journald 15 s sync ✅,
   rasdaemon ✅ (zero events — expected, non-ECC), pstore empty ✅; **C-state limiting never actually
   in force** (volatile sysfs write, wiped by the daily resets); memtest86+ installed, never run;
   **BIOS 1.26 (2025-09-15) is the latest — owner confirmed no newer firmware exists**.

Evidence lives in: `~/.cache/iad/host-guard/postmortems/6f5ec77c93e0402d9629bf24a7a1a2b5.md` (the
11:12 reset), `~/.cache/iad/host-guard/events.jsonl` (`host_state` events prove which mitigations
were live), `~/.cache/iad/host-guard/hwmon/hwmon.csv` (1 Hz), journald boots -1/-2 of 2026-08-07.

### Decisions already made by the owner (2026-08-07)

- **Hardware sequencing: C-state limit first**, persistent, one-week soak; memtest → JEDEC →
  reseat/RMA ladder only if resets continue. **No BIOS rung** (no newer firmware exists).
- **Topology: keep the interactive pump; add auto-resume.** No permanent headless switch.

### Pending fix plan (execute in order; [P] = propagate to all 5 copies*)

*\*Propagation rule: neutral source `incredible_auto_dev/scripts/automation/...` + active copies in
`trendora/` and `tapeology/` + vendored snapshots `{trendora,tapeology}/incredible_auto_dev/` —
patch identical hunks, never whole-tree rsync; `cmp` before/after (all 5 currently byte-identical
for the files below). Env files are machine/project-specific, never copied.*

**Phase 0 — stabilization:** (1) kill orphan `iter52_health_drill.py` (was pid 291199 — verify cmdline
first; stale after any reboot). (2) Stale dispatch `runs/goal-session-ops-hardening/dispatch/req.5-aC2vHX.*`
(no `.res`): leave — `dispatch_channel_janitor` + `--resume` handle it; rm the trio only if the resumed
pump stalls. (3) Reap escaped headed QA Chromes (`pgrep -af iad-qa-`). (4) [sudo] record pstore contents
for the soak log.

**Phase 1 — hardware soak ladder [sudo]:** (1) Install `/etc/systemd/system/iad-cstate-limit.service`
(oneshot; `for f in /sys/devices/system/cpu/cpu*/cpuidle/state[2-9]/disable; do echo 1 > "$f"; done`
plus a `logger` echo line; `WantedBy=multi-user.target` **and** the four sleep targets with matching
`After=` so it re-asserts on resume), `enable --now`. Disables C2+C3 (acpi_idle). Self-verifying:
every engine start's `host_state` event must show `cstate_disabled` `C2:1,C3:1`. Correct the stale
"in flight" comment in `~/.config/iad/host-guard-host.env` (~line 76) to name the unit, dated.
(2) Add `HOST_GUARD_MAX_ENGINES=1` there too, dated "revert on acceptance" (pauses tapeology's
engine resumably during the soak). (3) If a FAULT reset occurs during week 1 → overnight MemTest86+
(≥1 full pass; any error → rung 5). (4) Week 2 if still faulting: BIOS setup → JEDEC baseline
(disable EXPO/XMP). (5) Escalation: SO-DIMM reseat → single-DIMM A/B → GEEKOM RMA.
(6) **Acceptance** (runbook line 199): 7 consecutive days of `doctor.sh --only reset-reason` CLEAN;
then revert (2).

**Phase 2 — framework fixes [P]:** (1) `host-guard-adopt.sh:103-115` — the width-only early-exit is
always taken at mask `0-15`, so the scope + `MemoryHigh`/`TasksMax` block (117–131) never runs and
the 12G pump ceiling binds nothing. Add `_in_hg_scope()` (grep `/proc/<pid>/cgroup` for
`chain-(pump|goal)-hostguard-`); early-exit only when in-scope AND width-ok, re-issuing
`systemctl --user set-property` (idempotent refresh) on that path; always adopt when not in scope;
skip the taskset walk at full width. Keep `MemoryHigh=12G`. (2) Mid-dispatch thermal defer:
`host_guard_thermal_defer()` in `run-goal.sh` (~line 963), knob `HOST_GUARD_TCTL_DISPATCH_GATE`
(default 0), poll until Tctl ≤ `TCTL_RESUME`, bound `HOST_GUARD_TCTL_DISPATCH_MAX_WAIT` (600 s,
proceed loudly), emit `thermal_defer`; hook at top of `agent_with_quota_retry`
(`lib/quota-retry.sh:1237`) via `declare -F … || true`. Defers next dispatch only. (3) `--headless`
resume override in `run-goal.sh` (parse ~line 209; skip persisted-backend adoption at 291–304;
document in usage header). (4) Optional: `HOST_GUARD_PUMP_HEADLESS_QA=1` → `unset DISPLAY
WAYLAND_DISPLAY` in `host-guard-exec.sh` (~line 47). (5) Env values: trendora
`project-extensions/host-guard/host-guard.env` → `HOST_GUARD_TCTL_PAUSE=85`, `TCTL_RESUME=75`,
`TCTL_DISPATCH_GATE=1` (+ dated comment citing this incident); tapeology env → same; and a dated
line in `docs/host-guard.md` §123 naming `iad-cstate-limit.service` [P]. **No mask/boost changes.**
(6) `run-evals.sh` green + 5-copy `cmp` after patching.

**Phase 3 — pump survives session death:** (1) QA Chrome headless for pump dispatches — supported
via absent `DISPLAY`/`WAYLAND_DISPLAY` (`lib/common.sh:386-395`); delivered by the launch recipe
below (`CHAIN_BQA_HEADED=1` stays the debug escape). (2) Standard launch becomes: `systemd-run
--user --scope --unit=goal-pump-tmux env -u DISPLAY -u WAYLAND_DISPLAY tmux new-session -A -s
goal-pump`, then `claude` + `/goal ops-hardening` inside — survives pty/SIGHUP cascade AND
session-cgroup teardown (Linger=yes verified); after a compositor crash: re-login,
`tmux attach -t goal-pump`. (3) Opt-in post-reset auto-resume: user unit
`iad-goal-autoresume.service` gated on marker `~/.config/iad/goal-autoresume.armed`; if
`session.json` status is `in_progress`/`AWAITING_HOST_GUARD`, exec `run-goal.sh --resume
--session-id ops-hardening --headless`. **Verify first: headless spawns per-agent `claude -p` —
API-key billing (`commands/goal.md:47-51`); if unacceptable, leave disarmed and resume via tmux.**

**Verification:** C-state flags survive reboot + suspend/resume; `host_state` shows `C2:1,C3:1`;
morning check = `doctor.sh --only reset-reason` CLEAN + no new postmortem + gapless hwmon.csv.
Adopt fix: run adopt twice on a live pump → `systemctl --user show chain-pump-hostguard-<pid>.scope
-p MemoryHigh -p TasksMax` = 12G/2048 both times. Thermal defer: throwaway session with
`TCTL_PAUSE=1`, `DISPATCH_MAX_WAIT=10` → `thermal_defer` events, then proceeds. Session-kill drill:
`pkill -f ghostty` + `loginctl terminate-session` mid-iteration → `tmux attach` shows pump alive,
`engine.log` advancing. Headless QA: `pgrep -af iad-qa-` shows `--headless`, no new VSYNC lines in
gnome-shell journal.

## Known Limitations

1. **Service bootstrap**: QA expects `CHAIN_START_BACKEND_CMD` or `scripts/start-backend.sh`.
2. **Claude Code only**: Hooks and agent definitions are Claude Code-specific.
3. **Model tier costs**: Assumes access to Claude API with multiple model tiers.
4. **Pipeline is CLI-only**: Phase/goal runs don't execute in CI. GitHub Actions covers only the offline eval suite (`.github/workflows/evals.yml` — see Tests).
5. **Chrome MCP optional for phase mode**: Browser checks require Chrome MCP. Without it, browser tests are skipped.
6. **Chrome MCP required for goal mode**: The goal-evaluator anchors its `GOAL_ACHIEVED` decision on browser-qa journey results. Without Chrome MCP, browser tests are SKIPPED and the evaluator will likely emit `ESCALATE` indefinitely.

## Tests

```bash
./scripts/automation/run-evals.sh         # full offline eval suite (<30s, no API credits)
./tests/automation/test-install-gate.sh   # supply-chain gate unit tests
./tests/automation/test-quota-retry.sh    # quota-retry unit tests
```

### Eval guard: pre-commit hook + CI branch protection

Two layers keep a red eval suite from landing on `main` (roadmap SAFE-1):

- **Local (opt-in)** — install a pre-commit hook that runs the fast pure-python
  eval subset (the `_run_self_test` registrations in `run-evals.sh`; well under
  10s) and blocks the commit on any failure:

  ```bash
  bash scripts/automation/install-git-hooks.sh              # install (never installed automatically)
  bash scripts/automation/install-git-hooks.sh --uninstall  # remove
  ```

  The hook is local-only (`.git/hooks/pre-commit`), is **never auto-installed**
  by any pipeline script, and prints how to run the full suite. Emergency
  bypass: `git commit --no-verify` — CI still gates the push.

- **CI (recommended)** — `.github/workflows/evals.yml` (workflow
  `harness-evals`) already runs the full suite on every push and PR to `main`.
  To make it a hard gate, enable branch protection: GitHub → **Settings →
  Branches → Add branch protection rule** → branch pattern `main` → check
  **Require status checks to pass before merging** → search for and select
  **`offline eval suite`** (the `harness-evals` job). From then on a red eval
  suite blocks the merge instead of just reporting.
