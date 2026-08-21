# Goal Mode Quick Start

Goal mode is an autonomous, continuous mode of the AI Multi-Agent Dev Chain. You define a product goal once; the system iterates `decompose → execute → evaluate` until the goal is achieved or it halts with a clear cause.

For phase-by-phase mode (still fully supported), see the main [README](../README.md). For the architecture details, see [`.claude/architecture/goal-mode.md`](../.claude/architecture/goal-mode.md).

New to the terms and status codes (STALLED, `J-01`, lean/full…)? Keep
[`READING-REPORTS.md`](READING-REPORTS.md) open next to your first run — it explains
every report file and every code in plain words.

## When to use goal mode vs phase mode

| Use **phase mode** when … | Use **goal mode** when … |
|---|---|
| You have a clear, decomposed roadmap | You have a vision and want the system to figure out the steps |
| You want a human gate between every phase | You're happy reviewing the result at the end of a session |
| Your work doesn't have observable user journeys (pure infra refactor) | The product is testable via concrete user flows in a browser |
| You want full pipeline rigor on every change | You want adaptive depth — lean cycles where appropriate, full pipeline when risk is high |

You can use both modes in the same project. They write to disjoint artifact namespaces.

## 4-step setup

### 1. Author `docs/goal.md`

**Recommended:** run `/goal-init` inside Claude Code — it interviews you section-by-section and drafts `docs/goal.md` for you (playback confirmation before any write, structural self-check after).

**Manual alternative:** start from `templates/project-goal.md` and fill in every section yourself.

Either way, the two sections required by goal mode (and ignored by phase mode) are:

```markdown
## Must-have user journeys

- **J-01: Sign up and log in**
  - Steps:
    1. Visit `/signup`
    2. Enter `user@example.com` / `password123`
    3. Submit form, expect redirect to `/dashboard`
    4. Click "Log out"
    5. Visit `/login`, enter same credentials, expect `/dashboard` again
  - Acceptance: dashboard greeting shows the user's email

- **J-02: Create a todo with a tag**
  - Steps: …
  - Acceptance: …

## Anti-goals

- No hard-coded credentials, API keys, or tokens in source.
- Auth tokens MUST NOT be stored in `localStorage`.
- No dependency on a paid SaaS service unless explicitly listed in Constraints.
```

Each journey needs a unique ID (`J-NN`), numbered click/type/assert steps that the browser-qa-agent can execute via Chrome MCP, and an "Acceptance" line describing the observable end state. Anti-goals must be concrete, checkable rules — not aspirations.

If either section is missing or empty, `run-goal.sh` aborts with a clear error message (this is anti-pattern #18).

**Optional but high-leverage — `## Product Shape`.** You can also sketch the app's navigation / information architecture and list the *canonical values* (metrics or entities that must read the same everywhere they appear). The goal-decomposer drafts a coherence **blueprint** from this at baseline; if you leave it blank, it proposes one from your journeys. Naming canonical values here is the single best defense against the "the same number shows different values on different pages" problem. By default the blueprint is auto-approved and the run proceeds unattended; pass `--require-blueprint-approval` to review it once first (see step 3).

### 2. Configure `.claude/project-template.md`

Same as phase mode: name your project, declare your stack, list test commands, set architecture rules, etc.

### 3. Run

```bash
./scripts/automation/run-goal.sh --session-id my-app
```

This will:
1. Validate `docs/goal.md`
2. Initialize `runs/goal-session-my-app/`
3. Run iteration 0 (baseline): the goal-decomposer writes a verify-only spec **and drafts the coherence blueprint** (`state/blueprint.md`), then browser-qa runs every Must-have journey against the current codebase to figure out what already passes (handy for existing projects) and what needs work
4. **Auto-approve the blueprint and keep going (default).** The AI-drafted blueprint is accepted as-is and the loop proceeds straight into feature iterations — no pause. If you'd rather review it first, start with `--require-blueprint-approval`: the loop stops once (`AWAITING_BLUEPRINT_APPROVAL`) so you can edit the drafted blueprint (~3 min — see below; your edits are the approval), then `--resume`.
5. Loop iterations 1, 2, 3 … each iteration: decomposer picks the next chunk of failing journeys → lean or full pipeline executes → **coherence-auditor checks the change against the blueprint** → evaluator scores → loop or halt

**Reviewing the blueprint (only if you passed `--require-blueprint-approval`):** open `runs/goal-session-my-app/state/blueprint.md` and check two things — (1) **Information Architecture**: are the nav sections sensible and does every feature have an obvious home? (2) **Data Contract**: is every "same-number-everywhere" value listed with exactly one source? Add any the AI missed; fix wrong sources. Edit the file directly, then `--resume` (resuming counts as approval).

You can leave it running unattended. The framework's existing quota auto-resume (`claude_with_quota_retry`) handles API limits transparently — when the quota resets, the iteration resumes from where it paused.

**Run it interactively instead?** From a `claude` session, `/goal my-app` drives this same engine as interactive subagents — billed to your interactive plan allowance rather than the Agent SDK credit — with `/goal-status`, `/goal-resume`, `/goal-pause`, and `/goal-step` alongside. The pump stays quiet (watch `runs/goal-session-<sid>/engine.log`); Ctrl+C then `/goal-pause` pauses cleanly. Trade-offs (keep the session open; quota becomes a pause) and setup are in [`goal-mode-interactive.md`](goal-mode-interactive.md).

### 4. Inspect the result

When the loop halts, read:

- `runs/goal-session-my-app/summary.md` — final verdict, journey-by-journey status, total iterations, wall time
- `runs/goal-session-my-app/state/evaluator-log.md` — chronicle of every iteration's evaluator decision
- `runs/goal-session-my-app/telemetry.jsonl` — structured event log for analysis

…or **watch the product run** in a real browser with plain-language narration in
your terminal (press Enter to step through it):

```bash
./scripts/automation/demo.sh my-app --session-live   # live tour of the WHOLE product built so far
./scripts/automation/demo.sh goal-my-app-iter-3 --live  # live tour of one iteration
./scripts/automation/demo.sh my-app                   # open the recorded gallery / session index instead
```

See the "Watch your app" section of the [README](../README.md) for what to
expect and prerequisites (it needs a display; works over SSH X11 forwarding).

Halt verdicts:
- `GOAL_ACHIEVED` — every Must-have journey passes, no anti-goal violations
- `BUDGET_EXHAUSTED` — hit the `--max-iter` cap you set (there is no cap by default); resume with a higher cap to continue
- `STALLED` — no journey progress for `--stall-window` iterations; edit `goal.md` (clearer journeys, narrower scope) and `--resume`
- `REGRESSION_HALT` — a previously-passing journey now fails; review, fix manually if needed, then resume with `--acknowledge-regression`
- `AWAITING_BLUEPRINT_APPROVAL` — only when you ran with `--require-blueprint-approval`: paused after baseline (or after a structural blueprint change) for you to review `state/blueprint.md`; `--resume` to continue (counts as approval)
- `AWAITING_INTENT_REVIEW` — only when you ran with `--intent-checkpoint` / `--intent-checkpoint-at N`: paused once mid-session for you to read `runs/goal-session-<sid>/intent-review.md` ("is this still the product you wanted?"); `--resume` to continue (counts as acknowledgment; fires once per session)
- `AWAITING_GITHUB_AUTH` — paused at startup because per-iter push is on but a push to `origin` wouldn't authenticate (expired GitHub session, or no remote); fix auth (the run will offer to launch `gh auth login` for you when interactive) and `--resume`
- `AWAITING_HOST_GUARD` — only on hosts that declare hardware caps (`project-extensions/host-guard/host-guard.env`): the hwmon forensics sampler could not be started, the engine's CPU-affinity wrap did not take effect, a declared launcher lost its HOST-GUARD cap block, or the interactive pump session could not be confined (the engine auto-confines a running pump in place first via `host-guard-adopt.sh`; relaunching through `scripts/automation/host-guard-exec.sh <cli>` is only needed if that fails); fix the printed reason and `--resume` — see `docs/host-guard.md`
- `AWAITING_FULL_DEPTH` — only when full depth was declared a HARD requirement for the iteration (you set `CHAIN_REQUIRE_FULL_DEPTH=true`, or the spec carries a `Depth enforcement: required` line) and the engine could not dispatch it. The engine halts BEFORE dispatch — no developer run, no browser/replay lane, no service boot, nothing changed — and writes `runs/goal-session-<sid>/iter-<N>/depth-requirement-unmet` with the reason, the step that caught it, and a `remedy=` line. The remedy depends on the step, and the engine prints it: `depth-arbiter` (the cost ladder could not grant full) — let the cadence window pass or re-run with `CHAIN_FULL_CADENCE_CAP=1`; `depth-parse` — fix the spec's `Depth:` line so it parses; `full-dispatch` — the installed `run-phase.sh` has no `--no-finalize` flag, so update/restore the framework checkout; `depth-legacy-allowlist` — add the qualifying `Full trigger: <1-4> — <reason>` line to the spec, or re-enable the deterministic arbiter (unset `CHAIN_DEPTH_ARBITER`). Then `--resume`. Two things are NOT remedies: clearing `CHAIN_REQUIRE_FULL_DEPTH` or deleting the spec line (that deletes the check, not the cause), and `CHAIN_DEPTH_ARBITER=false` (it removes the precedence rung and the guard, and routes the iteration to the legacy allowlist)

## Common workflows

### Resume after laptop suspend or quota pause

The framework already handles both transparently — quota exhaustion sleeps until reset, system suspends use wall-clock-aware sleeps. If you want to manually pause: Ctrl-C; the trap writes an `ABORTED` summary. Then:

```bash
./scripts/automation/run-goal.sh --resume --session-id my-app
```

Resumes are cheap: step-level checkpoints (`CHAIN_STEP_CHECKPOINTS`, default on)
skip every already-completed step whose artifacts and working tree still verify,
so a pump stall or Ctrl-C never redoes the ~40-minute developer build.

### See where each iteration's time went

```bash
python3 scripts/automation/lib/analyze_telemetry.py --wall runs/goal-session-my-app/telemetry.jsonl
```

Per-iteration wall breakdown: minutes per agent, resume-skipped steps, pump
wait, parallel-overlap savings. Printed automatically after every iteration,
embedded in `summary.md`, and shown as a "Timing" accordion on each iteration's
HTML page. Token/cost telemetry is on by default for headless runs
(`CHAIN_TELEMETRY_TOKENS`); the interactive pump backend cannot capture usage.

### Try the opt-in speed experiment (guarded)

```bash
CHAIN_AGENT_EFFORT="developer=high" ./scripts/automation/run-goal.sh --resume --session-id my-app
```

Lowers the developer's reasoning effort only (judges are refused by a hardcoded
guard). Run ≥3 baseline iterations first; the telemetry tripwire auto-reverts
the knob if a REGRESSION verdict, journey regression, or repeated first-attempt
review FAILs appear while it is active.

### Try the opt-in output-style experiment (guarded)

```bash
CHAIN_OUTPUT_STYLES=true ./scripts/automation/run-goal.sh --resume --session-id my-app
```

Arms the wave-1 table in `lib/agent_permissions.py` (`OUTPUT_STYLE_OVERRIDES`),
sending Claude Code's built-in `Concise` output style to developer, qa,
browser-qa-agent, orchestrator, ui-impact-analyst, and ux-regression-reviewer
(judges are refused by a hardcoded guard). Run ≥3 baseline iterations with the
knob OFF first — the cost tripwire needs that many same-session unstyled rows
per agent to compute a baseline median before it can judge a styled one. It
likewise needs ≥3 STYLED rows per agent before it can judge — expect no cost
verdict before the third knob-on iteration. The telemetry tripwire auto-reverts
the knob on a quality regression (as with `CHAIN_AGENT_EFFORT` above) AND on a
cost regression (styled median `output_tokens` or `num_turns` more than 1.5x the
unstyled baseline). Check for a style mismatch after a run:

```bash
jq -c 'select(.event=="output_style_mismatch")' runs/goal-session-my-app/telemetry.jsonl
```

An empty result means every dispatch's effective style matched what was requested.

### Recover from `BUDGET_EXHAUSTED`

```bash
./scripts/automation/run-goal.sh --resume --session-id my-app --max-iter 50
```

### Recover from `REGRESSION_HALT`

1. Read `runs/goal-session-my-app/iter-<N>/eval.md` to see which journey regressed and why
2. Fix the regression manually OR adjust the goal (the regression may indicate a journey was poorly specified)
3. Resume:
   ```bash
   ./scripts/automation/run-goal.sh --resume --session-id my-app --acknowledge-regression
   ```

### Recover from `AWAITING_GITHUB_AUTH`

Because per-iter push is on by default, goal mode checks once at startup that a push
to `origin` would authenticate — so an expired GitHub session can't silently stall a
mid-run push on a username/password prompt. If the check fails in an interactive
terminal, the run offers to launch `gh auth login` for you, then continues. If it's
running unattended (or `gh` isn't installed), it pauses as `AWAITING_GITHUB_AUTH`:

```bash
gh auth login        # refresh the GitHub session
gh auth setup-git    # let git use the gh credential for HTTPS push
./scripts/automation/run-goal.sh --resume --session-id my-app   # re-checks, then continues
```

Pushes are also hardened so they can never block on a credential prompt — if the
session expires mid-run, that iteration's push fails fast and the loop continues
(the commit stays local and pushes on the next iteration once you re-auth). Skip the
startup check entirely with `export CHAIN_SKIP_GITHUB_PREFLIGHT=true` (for exotic
credential setups), or run without pushing via `--no-push-per-iter`.

### Review the blueprint (opt-in)

By default the blueprint is **auto-approved** and the run is fully hands-off — no pause. If you want to review the AI's draft first, start the session with `--require-blueprint-approval`: after baseline the loop pauses with `AWAITING_BLUEPRINT_APPROVAL` so you can edit it and resume:

```bash
./scripts/automation/run-goal.sh --session-id my-app --require-blueprint-approval
# ... loop pauses after baseline ...
$EDITOR runs/goal-session-my-app/state/blueprint.md   # check IA + Data Contract
./scripts/automation/run-goal.sh --resume --session-id my-app   # resuming = approval
```

`--require-blueprint-approval` is a per-run flag — pass it on each invocation/resume to keep the review pause on (it also pauses on any later structural blueprint change). `--auto-approve-blueprint` is still accepted but is now the default.

### Mid-session intent checkpoint (opt-in)

Goal mode normally runs hands-off from `goal.md` to `GOAL_ACHIEVED` — if the journeys encode the wrong product, you find out at the end. `--intent-checkpoint` adds one resumable mid-session pause: when **≥ 50% of the Must-have journeys pass**, the loop stops with `AWAITING_INTENT_REVIEW` and writes `runs/goal-session-<sid>/intent-review.md` — a deterministic packet (no model call) with the journey digest, the project story, the assumption-ledger tail, links to the HTML reports, and targeted questions (the still-failing journeys and any `Reversible: no` assumptions). Prefer an iteration count instead? `--intent-checkpoint-at N` fires when the loop reaches iteration N (same convention as `--max-iter`). Both are off by default and fire at most once per session:

```bash
./scripts/automation/run-goal.sh --session-id my-app --intent-checkpoint
# ... loop pauses once half the journeys pass ...
$EDITOR runs/goal-session-my-app/intent-review.md   # is this the product you wanted?
# drifting? edit docs/goal.md (journeys / anti-goals) before resuming
./scripts/automation/run-goal.sh --resume --session-id my-app   # resuming = acknowledged
```

Like the blueprint pause, these are per-run flags; the once-per-session memory lives in `state/.intent-review-done`, so a later resume never re-fires it.

### Start over

```bash
./scripts/automation/run-goal.sh --reset --session-id my-app
```

This deletes `runs/goal-session-my-app/` and starts fresh.

### Auto-create a PR when the goal is reached

```bash
./scripts/automation/run-goal.sh --session-id my-app --auto-release
```

The release-manager runs once at the end of the session (not per iteration), creating a feature branch and PR for the entire body of work. Requires authenticated `gh` CLI.

### Push every iteration to a session branch (default ON)

```bash
./scripts/automation/run-goal.sh --session-id my-app
```

Per-iter push is **on by default** for new sessions. `goal/my-app` is created from current HEAD and one commit lands per successful iteration (CONTINUE / ESCALATE / GOAL_ACHIEVED). `REGRESSION` and `STALLED` halts skip the push so the remote isn't left in a state you haven't reviewed. No model invocation per push — direct shell `git`. Override the branch name with `--push-branch <name>`.

To opt out for a particular session:

```bash
./scripts/automation/run-goal.sh --session-id my-app --no-push-per-iter
```

To opt in mid-session for a session that was started without push (or a session that pre-dates this feature), pass `--push-per-iter` on resume:

```bash
./scripts/automation/run-goal.sh --resume --session-id my-app --push-per-iter
```

The branch is created from current HEAD on first resume, and the choice is persisted to `session.json` so subsequent resumes pick it up automatically. Prior iters' code stays on whatever branch it was committed to before — only iters from this point forward accumulate on the new branch.

You can also flip the other way: `--no-push-per-iter` on resume disables push for this run AND persists `push_per_iter: false`, so future resumes respect the change.

The `summary.md` written when the loop halts includes a ready-to-paste `gh pr create` command. PR creation itself is still manual (or use `--auto-release` for the existing end-of-session PR flow).

Each iteration's commit message includes the verdict and the journey delta counts, so `git log goal/my-app` is a reviewable timeline of the session:

```
goal(my-app): iter 4 — CONTINUE (passing+1 failing+0 regressed+0)
goal(my-app): iter 3 — ESCALATE (passing+0 failing+1 regressed+0)
goal(my-app): iter 2 — CONTINUE (passing+2 failing+0 regressed+0)
goal(my-app): iter 1 — CONTINUE (passing+1 failing+0 regressed+0)
goal(my-app): iter 0 — CONTINUE (passing+0 failing+3 regressed+0)
```

## Continuous improvement (opt-in)

By default a session **finalizes** at `GOAL_ACHIEVED`. Opting in to continuous improvement changes that: once every Must-have journey passes, the **goal-proposer** agent surveys the finished product (via the read-only tools your guidance file names), detects vision gaps (Vision / Key Capabilities claims no journey covers), writes an improvement backlog to `runs/goal-session-<sid>/state/enhancement-proposals.jsonl`, and appends the best 1–2 proposals as new Must-have journeys inside the `<!-- AUTO:journeys -->` block of `docs/goal.md` — so the loop keeps building. When nothing worth building survives its validation screen, it reports a **dry** result and the session finalizes exactly as before (the honest stop — it never invents work to keep looping).

The opt-in is two files, both outside the framework subtree. `run-goal.sh` dispatches the proposer only when BOTH exist:

```bash
# 1. The guidance file — every project-specific judgment the proposer uses.
mkdir -p project-extensions/hooks
cp templates/proposer-guidance.md project-extensions/proposer-guidance.md
$EDITOR project-extensions/proposer-guidance.md   # fill in all six sections

# 2. The post-goal hook — deterministic prep run before the proposer. A no-op is enough:
cat > project-extensions/hooks/post-goal.sh <<'SH'
#!/usr/bin/env bash
exit 0
SH
```

The hook is where a project refreshes a pre-screen snapshot for the proposer to read (e.g. write a `usage-scan.json` into the session state dir, and name that file in the guidance). It runs with `SESSION_ID`, `SESSION_DIR`, `REPO_ROOT`, and `GOAL_FILE` exported, is invoked via `bash` (no `chmod +x` needed), and is non-fatal — a failing hook logs a warning and the proposer still runs. If you have no prep step, the minimal no-op above is all you need.

Each cycle writes `state/proposer-result.json` with the outcome (`extended` vs `dry`, plus a one-line summary naming any vision gaps found). The proposer edits **only** the `AUTO:journeys` block — human journeys and Anti-goals are never touched, and Anti-goals still bind every proposed journey. Every promoted journey bakes your consistency (Data Contract) and `[NEW]`-walkthrough requirements into its Acceptance, so the normal pipeline gates verify it like any other journey.

## Worked example: tiny goal

Here's a minimal `goal.md` that demonstrates goal mode end-to-end:

```markdown
# Project Goal

## Vision
A static page that shows the current UTC time when the user clicks a button.

## Target Users
A developer demoing this framework's goal mode.

## Success Criteria
- Page renders at /
- Time updates on button click

## Key Capabilities
1. Display the current UTC time
2. Refresh the time on button click

## Non-Goals
- No persistence, no backend, no auth, no styling beyond default.

## Constraints
- Single-page Next.js app, no external deps beyond what the framework allows.

## Design Direction
- Visual style: minimal-clean
- Mood: neutral

## Must-have user journeys

- **J-01: Page loads with current time**
  - Steps:
    1. Visit `/`
    2. Read the time element
  - Acceptance: a time string in `HH:MM:SS UTC` format is visible on the page

- **J-02: Refresh button updates the time**
  - Steps:
    1. Visit `/`
    2. Note the displayed time
    3. Click the button labeled "Refresh"
    4. Read the time element again
  - Acceptance: the displayed time has advanced by at least 1 second

## Anti-goals

- No third-party time API; the time MUST be derived from the browser or server clock only.
- No external CSS framework — keep dependencies minimal.
```

Then:

```bash
./scripts/automation/run-goal.sh --session-id tiny-clock --max-iter 5
```

(The blueprint is auto-approved by default, so this demo runs unattended; add `--require-blueprint-approval` if you want to review the drafted IA + Data Contract first. `--max-iter 5` is an optional safety budget — omit it to run uncapped.) A typical run for this goal completes in 2-3 iterations (baseline finds nothing exists → iter 1 builds the page → iter 2 verifies). The total wall time is dominated by build/test execution, not Claude calls.

## See also

- `/goal-init` ([`commands/goal-init.md`](../commands/goal-init.md)) — guided interview that drafts `docs/goal.md` for you
- [`templates/project-goal.md`](../templates/project-goal.md) — full goal template with all required sections
- [`.claude/architecture/goal-mode.md`](../.claude/architecture/goal-mode.md) — internal architecture
- [`docs/goal-mode-telemetry.md`](goal-mode-telemetry.md) — telemetry event schema
- [`.claude/anti-patterns/`](../.claude/anti-patterns/) — common authoring pitfalls (especially `18-goal-journeys-anti-goals.md`)
