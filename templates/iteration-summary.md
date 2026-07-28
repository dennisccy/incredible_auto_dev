# Iteration Summary — <phase-id>

**Verdict:** <GOAL_ACHIEVED | CONTINUE | ESCALATE | REGRESSION | STALLED | PASS | FAIL | IN-PROGRESS>
**Iteration type:** <phase | goal-lean | goal-full>
**Date:** <YYYY-MM-DD>
**Iteration:** <N>   <!-- goal mode only; omit for phase -->

## In plain words

<!-- For a non-technical product owner. No jargon, no file or agent names, no acronyms. -->
<!-- Three short, labelled parts. Each 1-3 plain sentences. -->

**What you can do now:** <Plain-language list of capabilities the product actually delivers to a user today. Frame as actions the user can take ("Sign in with email", "Save a draft and come back to it"). Re-derived every iteration from the currently-passing journeys in goal mode (never copied verbatim from the prior summary), or the cumulative end-user surface so far in phase mode.>

**What changed this time:** <MUST name the concrete user-visible change: the screen or page by its visible name and what the user now sees or does there ("The Watchlist page now has an 'Export CSV' button that downloads your list."). "Behind-the-scenes work — nothing visibly new this round" is allowed ONLY when the iteration changed zero product source files, and even then it must name the concrete area worked on ("sped up the price-history loading code").>

**What's next:** <Plain-language recommendation, derived from the technical Next step. Phrase it as the next thing the product will get to do for the user.>

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

<!-- FIRST bullet is fixed-format: either "Product changes: <changed product files and/or routes>" -->
<!-- (from status.json changed_files + the dev handoff's Files Changed list) or exactly -->
<!-- "No product change this iteration." Nothing else may be first. Then 3-8 terse bullets. -->
- Product changes: <comma-separated changed product files and/or routes — e.g. apps/frontend/app/desk/page.tsx, /api/desk/topup — or exactly "No product change this iteration.">
- <bullet>
- <bullet>

## What's left

<!-- 3-10 bullets. Failing journeys, closure blockers, Not Visible Yet, Known Limitations. -->
- <bullet>
- <bullet>

## Next step

<!-- One short paragraph. Verbatim from eval.md Next-Step Recommendation in goal mode. -->

<recommended action>

## Assumptions made

<!-- Interpretation calls from the session assumption ledger (goal mode: the dispatch -->
<!-- wrapper inlines the recent tail of state/assumptions.md). One plain bullet per -->
<!-- entry — NEVER copy the ledger's "## iter-N" headings (they would break H2 parsing). -->
<!-- When the ledger is empty, absent, or phase mode: write exactly "none recorded". -->

- iter-<N> · <agent> — Ambiguity: <what the goal left open>. We chose: <the reading built on>. Reversible: <yes|no>

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
