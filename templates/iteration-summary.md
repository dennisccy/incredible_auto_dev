# Iteration Summary — <phase-id>

**Verdict:** <GOAL_ACHIEVED | CONTINUE | ESCALATE | REGRESSION | STALLED | PASS | FAIL | IN-PROGRESS>
**Iteration type:** <phase | goal-lean | goal-full>
**Date:** <YYYY-MM-DD>
**Iteration:** <N>   <!-- goal mode only; omit for phase -->

## Headline

<One-line outcome — what this iteration accomplished or attempted. ≤120 chars.>

## Direction

**Signal:** <improving | holding | stalling | regressing | n/a>
**Why:** <2-3 sentences explaining the signal. Reference specific journey IDs and concrete progress.>

<!-- Trend block: goal mode only; omit for phase mode -->
**Trend (last 5 iters):**
- Newly passing this iter: <journey IDs or "none">
- Newly passing in last 5 iters total: <journey IDs or "none">
- Regressions in last 5 iters: <list with iter tags, or "none">
- Anti-goal violations in last 5 iters: <count + severity, or "none">
- Iters with no journey state change: <N> of last 5

**Latest evaluator reasoning:** <verbatim 2-4 sentences from eval.md or the most recent evaluator-log entry>

## What was done

<!-- 3-8 bullets. Action-oriented, terse. -->
- <bullet>
- <bullet>

## What's left

<!-- 3-10 bullets. Failing journeys, closure blockers, Not Visible Yet, Known Limitations. -->
- <bullet>
- <bullet>

## Next step

<!-- One short paragraph. Verbatim from eval.md Next-Step Recommendation in goal mode. -->

<recommended action>

## Quick verify

<!-- Goal-full and phase iters only. Cap at 5 numbered steps copied from what-to-click.md. -->
<!-- Omit entirely for lean iters or when what-to-click.md is absent. -->

From `reports/phase-<phase-id>-what-to-click.md`:

1. <action>
2. <action>
3. <action>

## Artifacts

<!-- One row per artifact that actually exists. Omit missing rows. -->

| Report | Verdict | Path |
|--------|---------|------|
| Iter spec | — | docs/phases/<phase-id>.md |
| Dev handoff | — | docs/handoffs/<phase-id>-dev.md |
| Review | <PASS/FAIL> | reports/reviews/<phase-id>-review.md |
| Browser QA | <PASS/FAIL/SKIPPED> | reports/phase-<phase-id>-ui-test-results.md |
| ... | ... | ... |
