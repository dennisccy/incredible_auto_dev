# Reading the chain's output — a plain guide

This page explains, in plain words, everything the chain prints and writes for you:
which file to open, what each status code means, and what the short codes stand for.
Keep it open the first few times you run the chain.

(For how to *start* a run, see [`goal-mode-quickstart.md`](goal-mode-quickstart.md).
This page is only about reading what comes out.)

---

## 1. Which file do I open?

Start at the top of this list. The first two cover 90% of what you need.

### `reports/goal-session-<sid>-index.html` — the session page (open this first)
The one-page overview of a goal session. It leads with "The story so far" (a plain
narrative of how your product has grown), then the latest demo gallery with
screenshots, a journey progress matrix, and one card per iteration.
**Check three things:** does the story match what you wanted? are the journey rows
turning green over time? does the newest card's badge look healthy?

### `reports/phase-<iter>-summary.html` — one iteration, one page
The per-iteration view. It leads with **"In plain words"** (what you can do now, what
changed this time, what's next) and a "Watch it work" screenshot gallery. Technical
sections sit below, collapsed — you can ignore them.
**Check three things:** the "In plain words" block, the verdict badge, the gallery.

### `reports/phase-<iter>-what-to-click.md` — try it yourself in 5 minutes
A short numbered guide: exact pages to open, buttons to press, and what you should
see. No developer knowledge needed. Written for full iterations and phases.

### `runs/goal-session-<sid>/iter-<N>/eval.md` — why the loop stopped
The evaluator's explanation for an iteration: a summary, evidence per journey, and a
recommendation. The terminal points you here when the chain halts. Read the
`## Summary` and `## Next-Step Recommendation` sections; skip the tables unless
you're curious.

### `runs/goal-session-<sid>/state/blueprint.md` — the app's floor plan (pause: review it)
When the chain pauses with "blueprint approval needed", it wants you to check two
things it drafted: the navigation plan (does every feature have an obvious home?)
and the data contract (each shared number has exactly one source). Edit the file
directly — your edits ARE the approval — then resume.

### `runs/goal-session-<sid>/state/intent-review.md` — mid-session checkpoint (pause: answer it)
Appears only if you enabled the intent checkpoint. It shows progress and asks: is
this still the product you wanted? Edit `docs/goal.md` if the direction drifted,
then resume.

### `reports/goal-session-<sid>-delivered.html` — the finish-line page
Written once, when the goal is achieved. A friendly wrap-up of everything the
product can do, with the final walkthrough embedded. The `.md` next to it is the
text version.

### `reports/phase-<iter>-demo-script.md` and `-demo-results.md` — the guided tour
The narrated walkthrough behind the gallery: each step has a plain sentence, the
exact action taken, and a screenshot (`reports/demo/<iter>/step-NN.png`). Steps
marked `[NEW]` were added this iteration. A failed demo step is a soft note, never
a failure of your product's tests.

### `reports/phase-<iter>-user-visible-changes.md` — what users can now do
A plain list of new abilities, visible UI changes, changed behavior, and things
built in the backend that have no UI yet ("not visible yet").

### `reports/goal-session-<sid>-retro.md` — ideas for improving the chain itself
Written after a session ends. Suggestions for the framework (not your product),
for a human to accept or ignore. Nothing in it is scheduled work.

### Deeper, technical reports (fine to skip)
Written for the pipeline and for developers; the summary pages above already
digest them:
- `reports/reviews/<iter>-review.md` — code review, verdict PASS / FAIL.
- `reports/qa/<iter>-qa.md` and `-test-plan.md` — test runs (test cases are `TC-nn`).
- `reports/phase-<iter>-ui-test-plan.md` / `-ui-test-results.md` — browser tests (`UT-nn`)
  with screenshots as evidence.
- `reports/phase-<iter>-ui-surface-map.md`, `-ux-regression.md`, `-closure-verdict.md`,
  `reports/qa/<iter>-ui-audit.md` — UI coverage and closure gates.
- `docs/handoffs/<iter>-dev.md` / `-audit.md`, `reports/phase-<iter>-implementation-summary.md`
  — developer handoffs and the auditor's report.
- `runs/goal-session-<sid>/iter-<N>/coherence.md` — checks new code didn't duplicate
  data sources or hide features outside the navigation.
- `runs/goal-session-<sid>/iter-<N>/journeys-changed.md` — appears only if you edited
  `docs/goal.md` mid-session; lists journeys that must be re-verified.
- `runs/<...>/status.json`, `session.json`, `summary.json`, `plan.md`,
  `journey-history.json`, `state/project-story.md` — machine state and sources the
  HTML pages are built from. You never need to open them.

---

## 2. What the status codes mean

These appear in the terminal, in `session.json`, and on the HTML badges. The
terminal prints the same plain sentences next to them; this is the full list.

### Session end / pause statuses (goal mode)

| Code | In plain words |
|---|---|
| `GOAL_ACHIEVED` | The goal is complete: every must-have journey works and no rule was broken. |
| `BUDGET_EXHAUSTED` | The session stopped because it reached the iteration limit you set (`--max-iter`). Nothing is broken. Resume with a higher limit to build more. |
| `STALLED` | The chain stopped because it could not make progress on its own. What was built so far still works. Read the last evaluation, unblock the problem (or edit `docs/goal.md`), then resume. |
| `REGRESSION_HALT` | Something that worked before is broken now, so the chain stopped to protect your product. After you fix or accept the break, resume with `--acknowledge-regression`. |
| `ABORTED` | The run was interrupted before it finished the iteration. Nothing is lost — resume when ready. |
| `ABORT_MALFORMED` | The evaluator wrote an unreadable verdict twice in a row, so the chain stopped instead of guessing. Your product is unchanged. |
| `GATE_BLOCKED` | A project rule (gate) rejected this iteration's plan, so the chain paused before building anything. |
| `AWAITING_BLUEPRINT_APPROVAL` | Paused, not broken — waiting for you to review `state/blueprint.md` and resume. |
| `AWAITING_INTENT_REVIEW` | Paused, not broken — waiting for you to finish the intent checkpoint and resume. |
| `AWAITING_PUMP` | The Claude Code session that runs the agents went away, so the engine paused safely. Re-open Claude Code in this repo and run `/goal-resume`. |
| `AWAITING_GITHUB_AUTH` | Paused because the chain cannot push to GitHub (login missing or expired). Run `gh auth login`, then resume. |
| `AWAITING_DISK` | Paused because this computer is low on disk space — the chain never builds in that state. Free space, then resume. |
| `in_progress` | The session is running normally. |

### The evaluator's per-iteration verdict

Printed after every iteration as `Verdict: <code>`.

| Code | In plain words |
|---|---|
| `CONTINUE` | Normal progress — the chain plans and builds the next piece by itself. |
| `ESCALATE` | The last round found something tricky, so the next round uses the slower, more careful pipeline. |
| `REGRESSION` | Something that worked before is broken — the chain is stopping so you can look. |
| `STALLED` | The evaluator sees no useful next step it can do alone — it is stopping to ask for your help. |
| `GOAL_ACHIEVED` | Every must-have journey now works, so the session will finish. |

"Next depth" after the verdict: `lean` = a quick build-and-check round; `full` = a
full round with extra review, audit and UX checks.

### Other verdict words you'll see inside reports

| Code | In plain words |
|---|---|
| `PASS` / `FAIL` | The check passed / found problems (the pipeline fixes and retries by itself). |
| `PASS_WITH_NOTES` | Passed; small non-blocking remarks attached. |
| `PASS_WITH_GAPS` | Passed overall, but the auditor found real gaps worth reading. |
| `SKIPPED` | The check didn't run (usually: no browser or no frontend this round). |
| `COHERENCE-PASS / WARN / FAIL` | New code kept / strained / broke the app's structure rules (one source per value, every feature reachable in the navigation). |
| `CLOSURE-PASS / CLOSURE-FAIL` | The final completeness gate for an iteration passed / blocked it. |
| `UI-PASS / UI-PASS-WITH-GAPS / UI-FAIL` | The UI evolved properly with the new capability / partially / not at all. |
| `RECORDED / RECORDED_WITH_NOTES / NOT_YET` | The demo tour was captured / captured with soft notes / there is nothing to demo yet. |
| `IN-PROGRESS` | The session hasn't ended; this iteration is a normal middle step. |

### Journey status words (the pills and the matrix)

`passing` / `already_passing` = ✓ working · `failing` = ✗ broken (not built or not
working yet) · `regressed` = ⚠ worked before, broken now · `partial` = ~ partly
working · `unknown` = ? not verified yet · `pending_infra` = the test could not run
(browser/infrastructure problem), the feature itself may be fine.

---

## 3. Short codes and chain words

**ID families**
- `J-01, J-02…` — your **user journeys** from `docs/goal.md` (things a user can do,
  e.g. J-04 "Sign in with email"). The product is done when all of them pass.
- `UT-01…` — **browser tests**, each checking one journey through a real browser.
- `TC-01…` — **QA test cases** from the test plan.
- `P0 / P1 / P2` — how urgent (P0 = most urgent).
- `Effort S / M / L` — how much work (small / one session / multiple sessions).
- `Risk LOW / MED / HIGH` — chance the change breaks something else.
- `CRITICAL / IMPORTANT / GAP / OBSERVATION` — audit findings, most to least serious.
- `RETRO-1…` — numbered suggestions in a retro report.
- `CTX-8, REL-14, SPEED-2, EVO-1, §16…` — internal improvement tickets and section
  numbers for the framework itself (`docs/improvement-roadmap.md`). Maintainer
  bookkeeping — safe to ignore while running your product.

**Chain words**
- **journey** — one thing a user can do, written as steps with an observable result.
- **iteration** — one loop of plan → build → check. **baseline** — iteration 0, which
  only verifies the starting state and builds nothing.
- **lean / full depth** — quick round vs. full-rigor round (see above).
- **evaluator** — the agent that judges each iteration and writes `eval.md`.
- **gate** — a mechanical safety check that can override an agent's claim. If a gate
  demotes a verdict, the stricter answer wins.
- **blueprint** — the app's floor plan you approve once (navigation + data contract).
- **pump** — the Claude Code session that actually runs the agents when you use the
  interactive `/goal` commands. If it disappears, the engine pauses (`AWAITING_PUMP`).
- **showcase** — the non-blocking tail of each iteration that produces the demo,
  summary, README refresh, and HTML pages. It can fail without failing your build.
- **anti-goal** — a thing you told the chain never to do (`docs/goal.md`).

---

*Single source note (for maintainers): the plain sentences for statuses and verdicts
are defined in `scripts/automation/lib/plain-language.sh` and mirrored here and in
`skills/plain-language.md`. If wording changes, change it in all three together.*
