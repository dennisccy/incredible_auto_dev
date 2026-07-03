# Judgment Rubrics

Executable judgment criteria for agents and main-loop sessions. Each rubric gives the
decision criteria plus one positive (✚) and one negative (✖) example — most drawn from a real
production goal-mode deployment (Trendora, goal-session `mcp-loop`); read them as case studies,
not as artifacts you can open in this repo. When a rubric and your intuition disagree,
follow the rubric and note the disagreement in your report.

---

## 1. When to upgrade the model (escalate a dispatch to the strong tier)

Escalate when ANY of:
- The same subtask has failed twice on the current tier (include the complete failure trace).
- The decision requires weighing **contradictory evidence** (e.g., tests pass but the browser
  flow fails; two artifacts disagree).
- The output will be **hard to reverse** (verdicts that halt/certify a session, destructive
  migrations, ledger writes).
- The task needs **cross-cutting design** (touches >2 subsystems' contracts at once).

Do NOT escalate for: long-but-mechanical work (batch renames, formatting, boilerplate —
that's volume, not difficulty); tasks a checklist fully covers.

- ✚ Iter-16's evaluator call — "probe blocked: is this STALLED or CONTINUE?" required
  weighing a hard external blocker against in-repo progress: strong-tier judgment.
- ✖ Applying the same import-path fix to 30 test files after the first one is proven:
  batch-apply on a cheap model with the solved example inline.

## 2. What counts as truly complete

A capability is complete ONLY when all four hold:
1. **Journey-level evidence**: the user-visible flow was exercised end-to-end (browser results
   row + screenshot for UI; real request/response for APIs) — not just unit tests.
2. **Every claim cites its artifact** (`file:line`, screenshot filename, test name). A claim
   with no citation is `unknown`, not `done`.
3. **Deterministic gates green**: tests, replay-verify lane, coherence/gate-report — whatever
   the pipeline defines for this change class.
4. **No renegotiation**: the acceptance criteria being satisfied are the ORIGINAL ones (or an
   explicitly user-approved amendment) — not a quietly weakened version.

- ✚ Iter-15 GOAL_ACHIEVED: all nine journeys had browser evidence + passing replay scripts;
  ledger claims traced to certified rows; verdict cited artifacts per journey.
- ✖ "Backend endpoint implemented, unit tests green, journey J-07 therefore passing" — the
  journey was never exercised in a browser; a routing typo made the page 404. Tests-green ≠
  journey-passing. Status: `partial`, not `passing`.

## 3. When to stop and ask the user (vs. proceed autonomously)

STOP and surface (verdict `STALLED` in goal mode; a question in interactive work) when ANY of:
- Every unblock path requires a **human-owned resource or decision**: credentials/API keys,
  paid services, network/IP allowlists, account actions, spending money.
- The next step is **irreversible or high-stakes** and was not explicitly pre-authorized:
  resetting a ledger, deleting data, force-pushing, publishing externally.
- Two **legitimate readings of the goal/spec conflict** and the choice changes the product
  (not just the implementation).

Do NOT stop for: choices between equivalent implementations (pick one, note it); missing
information you can obtain yourself (read the code, run the probe, check the docs);
discomfort with a hard-but-specified task.

- ✚ Iter-16: Stooq's per-IP export ACL blocked ingestion; every unblock option (run from an
  allowed network, obtain `STOOQ_API_KEY`, amend the goal's provider) was a human action, and
  the follow-on step (data-basis swap + sanctioned ledger reset) was high-stakes → STALLED
  with the three options spelled out. Correct.
- ✖ Stopping to ask "should I use library A or B?" when both satisfy the spec and neither is
  user-visible → pick the simpler one and record the choice in the handoff.

## 4. Wrong-direction signals (change approach — do not retry)

Any ONE of these means the current approach is wrong; retrying it harder wastes tokens:
- The **same error class** appears after 2 genuinely different fixes.
- The **fix diff keeps growing** while the failing-test count doesn't shrink (complexity
  chasing the bug instead of cornering it).
- You catch yourself **renegotiating acceptance criteria** mid-iteration ("passing except
  for…", "should count as done because…").
- The fix requires **disabling or weakening a gate/test** to go green.
- Progress requires **fabricating or substituting** what the spec fixed (different data
  provider, mocked "live" probe, invented numbers) — see §6.

On a wrong-direction signal: stop, write down the failure trace, then either (a) re-derive
the approach from the actual evidence, or (b) escalate per §1 with that trace.

- ✚ Ranking certification candidates by edge size kept failing the referee (a bigger edge
  FAILED at p=0.0245 while a smaller one PASSED at p=0.0115 — high volatility inflates SE).
  The fix was changing the selection criterion to the p-value, not resubmitting bigger edges
  (mcp-loop iter-8: submitting more candidates would have permanently tightened the
  Bonferroni bar and killed the one viable claim).
- ✖ A developer's third attempt at the same flaky browser test adds sleeps and retries around
  the same selector instead of asking why the element isn't there (the route had moved — the
  first failure trace already showed the 404).

## 5. Quality floor per claim type (minimum acceptable evidence)

| Claim | Minimum evidence — anything less is `unknown` |
|-------|-----------------------------------------------|
| "UI journey passes" | Browser results row (pass) + screenshot showing the acceptance state |
| "API works" | Actual request + response captured in the artifact (not "endpoint exists") |
| "Bug fixed" | The previously-failing test/repro now passing — cite before AND after |
| "Data/metric is X" | The computing artifact (ledger row, test, script output) — never prose |
| "No regressions" | Replay-verify lane green + journey deltas table, or explicit list of what was NOT re-verified |
| "Committed/pushed" | The SHA, and for pushes the remote ref |

## 6. Honesty rules (non-negotiable)

- **Unknown is a first-class answer.** If evidence is missing or you did not check, write
  `unknown` — never guess a status to keep momentum. A wrong `passing` costs far more than an
  honest `unknown` (it poisons every later iteration's baseline).
- **Never fabricate or silently substitute** to unblock: no invented data, no swapped
  providers, no mocked results presented as live. If the sanctioned path is blocked, say so
  and stop (§3).
- **Report failures with the output**, not a paraphrase. "Tests failed (3): <names + first
  assertion lines>" — not "minor test issues remain".
- ✚ Iter-16 staged **zero** symbols rather than substitute Yahoo data for the spec'd Stooq
  30-year basis — the honest empty result kept every downstream certification meaningful.
- ✖ Marking a journey `passing` because "the code path is clearly correct" while the
  screenshot shows an error toast. If the screenshot contradicts the claim, the screenshot
  wins.

## 7. Quality-floor verification for your OWN output (before you hand off)

1. Re-read your verdict/handoff as the *next* agent: does every claim have a citation they
   can open?
2. Does any statement contradict an artifact you read? (If you didn't read it, don't cite it.)
3. Did you complete every checklist your role's skill mandates — and say so explicitly?
4. Would a fresh-context skeptic reach your verdict from the cited evidence ALONE? If not,
   add the missing evidence or weaken the claim.
