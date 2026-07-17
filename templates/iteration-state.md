# Iteration State — <session-id>

<!-- Written by the goal-evaluator (its step 7) AFTER scoring each iteration:
     OVERWRITE the whole file every time — never append. HARD CAP: 40 lines
     total — the artifact-schema validator flags a longer file; trim bullets
     rather than exceed it. The next decomposer dispatch inlines this file
     VERBATIM, so it must stay a digest, not a log. -->

**After iteration:** <N> · **Date:** <YYYY-MM-DD> · **Verdict:** <VERDICT>

## Journeys

<ONE line — counts + IDs by status, e.g. "6 passing (J-01..J-05, J-07) · 2 failing (J-06 J-08) · 1 unknown (J-09) — 9 total">

## Active blockers

- <current blocker, its owner (human | dev), and the file/path it lives at — or "none">

## Last 2 verdicts

- iter <N>: <VERDICT> — <one-line why>
- iter <N-1>: <VERDICT> — <one-line why; or "n/a — first evaluated iteration">

## Do not redo

<!-- Work verified DONE, regressions verified FIXED, decisions settled — with
     where each lives. BINDING for the decomposer unless docs/goal.md changed
     for that item. ≤6 bullets: keep only what a planner could plausibly
     re-attempt. -->
- <item + where it lives — or "nothing yet">

<!-- Placeholder variant (iteration 0 / file absent): the dispatch inline
     substitutes "(first iteration — no prior state)" — never create this file
     anywhere except the goal-evaluator's step 7. -->
