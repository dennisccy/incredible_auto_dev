# Goal Mode Quick Start

Goal mode is an autonomous, continuous mode of the AI Multi-Agent Dev Chain. You define a product goal once; the system iterates `decompose → execute → evaluate` until the goal is achieved or it halts with a clear cause.

For phase-by-phase mode (still fully supported), see the main [README](../README.md). For the architecture details, see [`.claude/architecture/goal-mode.md`](../.claude/architecture/goal-mode.md).

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

Start from `templates/project-goal.md` and fill in every section. The two sections required by goal mode (and ignored by phase mode) are:

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

### 2. Configure `.claude/project-template.md`

Same as phase mode: name your project, declare your stack, list test commands, set architecture rules, etc.

### 3. Run

```bash
./scripts/automation/run-goal.sh --session-id my-app
```

This will:
1. Validate `docs/goal.md`
2. Initialize `runs/goal-session-my-app/`
3. Run iteration 0 (baseline): the goal-decomposer writes a verify-only spec, browser-qa runs every Must-have journey against the current codebase to figure out what already passes (handy for existing projects) and what needs work
4. Loop iterations 1, 2, 3 … each iteration: decomposer picks the next chunk of failing journeys → lean or full pipeline executes → evaluator scores → loop or halt

You can leave it running unattended. The framework's existing quota auto-resume (`claude_with_quota_retry`) handles API limits transparently — when the quota resets, the iteration resumes from where it paused.

### 4. Inspect the result

When the loop halts, read:

- `runs/goal-session-my-app/summary.md` — final verdict, journey-by-journey status, total iterations, wall time
- `runs/goal-session-my-app/state/evaluator-log.md` — chronicle of every iteration's evaluator decision
- `runs/goal-session-my-app/telemetry.jsonl` — structured event log for analysis

Halt verdicts:
- `GOAL_ACHIEVED` — every Must-have journey passes, no anti-goal violations
- `BUDGET_EXHAUSTED` — hit `--max-iter` cap; resume with a higher cap to continue
- `STALLED` — no journey progress for `--stall-window` iterations; edit `goal.md` (clearer journeys, narrower scope) and `--resume`
- `REGRESSION_HALT` — a previously-passing journey now fails; review, fix manually if needed, then resume with `--acknowledge-regression`

## Common workflows

### Resume after laptop suspend or quota pause

The framework already handles both transparently — quota exhaustion sleeps until reset, system suspends use wall-clock-aware sleeps. If you want to manually pause: Ctrl-C; the trap writes an `ABORTED` summary. Then:

```bash
./scripts/automation/run-goal.sh --resume --session-id my-app
```

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

### Push every iteration to a session branch

```bash
./scripts/automation/run-goal.sh --session-id my-app --push-per-iter
```

Creates `goal/my-app` from current HEAD and pushes one commit per successful iteration (CONTINUE / ESCALATE / GOAL_ACHIEVED). `REGRESSION` and `STALLED` halts skip the push so the remote isn't left in a state you haven't reviewed. No model invocation per push — direct shell `git`. Override the branch name with `--push-branch <name>`.

The `summary.md` written when the loop halts includes a ready-to-paste `gh pr create` command. PR creation itself is still manual (or use `--auto-release` for the existing end-of-session PR flow).

Each iteration's commit message includes the verdict and the journey delta counts, so `git log goal/my-app` is a reviewable timeline of the session:

```
goal(my-app): iter 4 — CONTINUE (passing+1 failing+0 regressed+0)
goal(my-app): iter 3 — ESCALATE (passing+0 failing+1 regressed+0)
goal(my-app): iter 2 — CONTINUE (passing+2 failing+0 regressed+0)
goal(my-app): iter 1 — CONTINUE (passing+1 failing+0 regressed+0)
goal(my-app): iter 0 — CONTINUE (passing+0 failing+3 regressed+0)
```

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

A typical run for this goal completes in 2-3 iterations (baseline finds nothing exists → iter 1 builds the page → iter 2 verifies). The total wall time is dominated by build/test execution, not Claude calls.

## See also

- [`templates/project-goal.md`](../templates/project-goal.md) — full goal template with all required sections
- [`.claude/architecture/goal-mode.md`](../.claude/architecture/goal-mode.md) — internal architecture
- [`docs/goal-mode-telemetry.md`](goal-mode-telemetry.md) — telemetry event schema
- [`.claude/anti-patterns.md`](../.claude/anti-patterns.md) — common authoring pitfalls (especially #18)
