# Benchmark experiments ledger (EVO-3)

**APPEND-ONLY.** Entries below the marker line are never edited or deleted once
written. A bad entry is corrected by APPENDING a dated correction line under
it — never by rewriting history. Pre-registration only proves anything
(ground rule G8: prediction precedes execution) if the record is immutable.

How entries get here (written by `scripts/automation/run-benchmark.sh`):

- **PRE** — appended after the runner's refusal gates pass and BEFORE the
  engine launches: date · framework sha (+dirty flag) · fixture · one-line
  hypothesis · the metric(s) and predicted direction/size (taken from the
  `--predict` predicates when given, otherwise stated inside the hypothesis
  itself and graded manually later).
- **POST** — appended after results extraction, under the same session id:
  results file path · headline numbers · per-predicate evaluations · a
  `verdict-vs-prediction:` line. With `--predict` predicates the verdict is
  computed mechanically (all true → CONFIRMED, all false → REFUTED, else
  MIXED). Without predicates the line reads
  `MANUAL — append CONFIRMED|REFUTED|MIXED after review`: the runner never
  self-grades a free-text hypothesis — read the results JSON, then append your
  verdict as a new dated line under the POST entry.

Entry format contract (grep-able; pinned by
`tests/automation/test-benchmark-runner.sh`): PRE entries start
`## PRE <session-id>`, POST entries start `## POST <session-id>`.

<!-- entries are appended below this line — do not edit anything beneath it -->

---

## PRE bench-20260710-2110 · 2026-07-10T21:10:26Z
- framework-sha: b172cea005aa8225299b1f7160ae87a946a06a20 (dirty: false)
- fixture: todo-app · max-iter 2
- hypothesis: Baseline @ b172cea005aa: chain reaches GOAL_ACHIEVED with 3/3 journeys within --max-iter 2 on the todo-app fixture
- metrics + prediction (mechanical --predict): final_status==GOAL_ACHIEVED;journeys_passing_after>=3

## POST bench-20260710-2110 · 2026-07-10T21:10:28Z
- results: benchmarks/results/20260710-211028-b172cea005aa.json
- headline: status=ABORTED last_verdict=unknown (last_verdict null/absent in session.json) journeys=0/0 iters=0 engine_exit=2 wall=2s cost=unknown
- predicate: final_status==GOAL_ACHIEVED → false (final_status='ABORTED')
- predicate: journeys_passing_after>=3 → false (journeys_passing_after=0)
- verdict-vs-prediction: REFUTED
- correction 2026-07-10: INFRA FAILURE, not a chain result — the slice-(b) runner
  exported the invalid `CHAIN_AGENT_BACKEND=headless` (quota-retry.sh accepts
  interactive|claude|codex; headless dispatch = `claude`), so the engine aborted at
  the first dispatch after 2s with ZERO agent spend (economics empty; the bad value
  is visible in the results JSON's chain_env). Runner + test fixed to export
  `claude` in the same commit that carries this line. The offline suite could not
  catch this: its stub engines echo the env var without validating it against the
  real quota-retry contract. Any rerun is a fresh PRE/POST pair under fresh user
  approval (G9) — this entry stays as the record of the aborted attempt.

---

## PRE bench-20260710-2117 · 2026-07-10T21:17:11Z
- framework-sha: c48f25047126a52ccec88f9b2347403280b1c22b (dirty: false)
- fixture: todo-app · max-iter 2
- hypothesis: Baseline @ c48f25047126: chain reaches GOAL_ACHIEVED with 3/3 journeys within --max-iter 2 on the todo-app fixture
- metrics + prediction (mechanical --predict): final_status==GOAL_ACHIEVED;journeys_passing_after>=3

## POST bench-20260710-2117 · 2026-07-10T22:42:06Z
- results: benchmarks/results/20260710-224206-c48f25047126.json
- headline: status=BUDGET_EXHAUSTED last_verdict=CONTINUE journeys=0/3 iters=2 engine_exit=0 wall=5095s cost=$10.885761
- predicate: final_status==GOAL_ACHIEVED → false (final_status='BUDGET_EXHAUSTED')
- predicate: journeys_passing_after>=3 → false (journeys_passing_after=0)
- verdict-vs-prediction: REFUTED
- assessment 2026-07-10: GENUINE CHAIN RESULT, not infra — environment healthy (zero
  quota pauses, engine exit 0, Chrome MCP + playwright preflight-verified, friction
  counters all zero). The chain BUILT all three journeys (reviewer PASS,
  COHERENCE-PASS, scan CLEAN, 15/15 pytest) but its browser-QA lane produced zero
  journey evidence in BOTH iterations, so the evaluator honestly held J-01..J-03 at
  `unknown` (0/3 passing). Root causes per evaluator-log + trace/0014-qa.log in the
  kept scratch: (1) the generic `scripts/start-backend.sh` template copied with the
  framework subrepo set (uvicorn / apps-backend layout) shadowed the fixture
  project-template's `.venv/bin/python app.py`, so nothing served on 127.0.0.1:5177
  (README Known Limitation 1 made concrete); (2) a headless write-permission prompt
  blocked the QA report and the retro-analyst report from persisting. Both are
  framework gaps this baseline exists to expose; fixing them should move journeys
  0→3 in a future compare. REFUTED stands as the recorded baseline. Kept scratch:
  ~/.cache/chain-bench-tmp/bench-bench-20260710-2117.EMAuTK
- note 2026-07-10: main was REBASED (by the repo owner, outside this protocol) between
  this run's completion and the close-out commit — a judgment-fixture amendment
  (tests/judgment/goal-evaluator/case-05-secret-committed, 4 files) was inserted deep
  in history and everything re-picked. The measured shas b172cea005aa (aborted
  attempt) and c48f25047126 (recorded baseline) are therefore no longer reachable
  from main; both are pinned by local tags bench-20260710-2110-framework-sha /
  bench-20260710-2117-framework-sha so gc never prunes them. Substantively nothing
  changes: `git diff c48f25047126 1814e24 -- .claude scripts config templates
  CLAUDE.md benchmarks` is EMPTY (the rebased equivalent of the measured commit
  differs only in tests/judgment/**, which the benchmark scratch never copies) — the
  measured tree is byte-identically reproducible from the new main.

---

## PRE bench-20260712-1536 · 2026-07-12T15:36:09Z
- framework-sha: 5e87813077aeafc8f044c043b6c70f1b06a60c00 (dirty: false)
- fixture: todo-app · max-iter 2
- hypothesis: REL-10/11 @ 5e87813077ae: QA lane now produces evidence — journeys 0→3; wall and cost EXPECTED TO RISE vs baseline (the voided browser lane now executes)
- metrics + prediction (mechanical --predict): journeys_passing_after>=3

## POST bench-20260712-1536 · 2026-07-12T17:13:24Z
- results: benchmarks/results/20260712-171324-5e87813077ae.json
- headline: status=BUDGET_EXHAUSTED last_verdict=CONTINUE journeys=3/3 iters=2 engine_exit=0 wall=5833s cost=$15.575128
- predicate: journeys_passing_after>=3 → true (journeys_passing_after=3)
- verdict-vs-prediction: CONFIRMED
- assessment 2026-07-12: GENUINE CHAIN RESULT — the fixes did exactly what the baseline
  predicted fixing them would do. Journeys 0→3: REL-10's fixture.env put the backend on
  127.0.0.1:5177 (`.venv/bin/python app.py` via CHAIN_START_BACKEND_CMD; the generic
  start-backend template no longer shadows it) and REL-11's scratch pre-trust let the
  light-tier writers persist their evidence — reports/qa/ populated (QA report +
  test plan, empty for the whole baseline run) and 0 of 25 traces carry the
  "Ignoring N permissions.allow entries" banner (baseline: every trace). The trust key
  was reverted by the runner and independently verified absent from ~/.claude.json.
  benchmark_compare vs the baseline: exit-3 REGRESS on cost (+43.1%, $10.89→$15.58;
  wall +14.5%, tokens_out +35.9%) — PRE-REGISTERED direction, not a failure: the
  previously-voided browser/QA lane now executes and bills. journeys_passing +3 is the
  headline. missing-evidence tripwire (REL-11c) fired 0 times, consistent with all
  expected artifacts present. final_status BUDGET_EXHAUSTED unchanged (max-iter 2 cap;
  last_verdict CONTINUE — the chain wanted a third iteration, same shape as baseline).
  EVO-2's first live artifact: reports/goal-session-bench-20260712-1536-retro.md exists
  in the kept scratch ("PROPOSALS ONLY" header; drafts RETRO-1 glue-time
  instrumentation + RETRO-2 concurrent-QA-lane state isolation — candidates for §16
  triage, not scheduled work). CONFIRMED stands. Kept scratch:
  ~/.cache/chain-bench-tmp/bench-bench-20260712-1536.ozxtwM
- retro report preserved 2026-07-12: copied verbatim (sha256-verified) from the kept
  scratch to benchmarks/results/20260712-171324-5e87813077ae.retro.md (sibling of the
  results JSON) before tmp cleanup can eat it; RETRO-1/RETRO-2 staged in the roadmap
  §16 as CAND-GLUE-TIME / CAND-QA-ISOLATION the same day (user-authorized staging per
  EVO-2's contract — promotion stays human).

---

## PRE bench-20260713-2334 · 2026-07-13T23:34:38Z
- framework-sha: b89a4d506f5e8d9ee784c0219f2e1294e1dd0e1b (dirty: false)
- fixture: todo-app · max-iter 2
- hypothesis: TOKEN-1 @ 25ee855de7ec: reviewer+qa per-agent input tokens DOWN vs 20260712 baseline; journeys HOLD 3/3; wall/cost ≈ flat
- metrics + prediction (mechanical --predict): journeys_passing_after>=3
- attribution 2026-07-14 (appended at launch, engine running; CONTROL run, all knobs
  off): this run is TOKEN-1's DoD telemetry measurement against baseline
  bench-20260712-1536 (`benchmarks/results/20260712-171324-5e87813077ae.json`, sha
  5e87813077ae). Every commit in 5e878130..b89a4d50 is provably inert in a knob-off
  run: cd65220/c86a259/da4f436/0b1c31d/a3d1c24/b89a4d5 are docs/results-only; 6b805b6
  (EVO-5) is a harvester script outside the iteration path; bb09160 (SPEED-1) is a
  byte-identical refactor (proof in its entry); 24af735 (SPEED-2) and 2ffedc3
  (SPEED-3) sit behind CHAIN_LEAN_PARALLEL_BROWSER_QA, UNSET here (launch env checked
  empty of CHAIN_*; see this run's chain_env). The A-vs-baseline delta therefore
  attributes to TOKEN-1 (25ee855) alone. Pre-registered interpretation caveats:
  (1) per-agent token deltas live in nested economics keys the predicate grammar
  cannot reach — they are assessed in the POST prose with numbers quoted, not graded
  mechanically; (2) per-iteration depth (lean vs full) is decomposer-chosen, so a
  different depth mix than the baseline's (which invoked reviewer ×1, qa ×1) adds
  noise to the per-agent comparison — the POST must read this run's actual
  composition from the kept scratch before comparing; (3) journeys<3 aborts the
  session before run B; wall/cost +>25% with journeys held is noted and continued
  (benchmark_compare flags it).

## POST bench-20260713-2334 · 2026-07-14T00:42:57Z
- results: benchmarks/results/20260714-004257-b89a4d506f5e.json
- headline: status=BUDGET_EXHAUSTED last_verdict=CONTINUE journeys=3/3 iters=2 engine_exit=0 wall=4099s cost=$11.669063
- predicate: journeys_passing_after>=3 → true (journeys_passing_after=3)
- verdict-vs-prediction: CONFIRMED
- assessment 2026-07-14: journeys 3/3 is a GENUINE CHAIN RESULT (iter-1 full pipeline
  built the todo app — 78-line app.py, 14 tests — and browser-evidenced all three
  journeys; benchmark_compare verdict OK, wall −29.7% 5833→4099s, cost −25.1%
  $15.58→$11.67). But the run also EXPOSED A LIVE REGRESSION, and the wall/cost drop
  is composition-confounded — details below. Free-text hypothesis grades MIXED:
  journeys HOLD ✓; qa per-agent tokens DOWN ✓ (like-for-like qa-phase.sh validation
  dispatch, recorded in both runs: input 368→313 (−14.9%), cache_creation
  129,713→96,327 (−25.7%), cost $0.6258→$0.5148; duration 876s→216s is browser-work
  variance, NOT attributed to TOKEN-1, and the cache_creation magnitude is dominated
  by turn-count variance — only the DIRECTION plus TOKEN-1's deterministic mechanism
  (51-line inlined slice replaces a ~180-line full-file Read instruction) is claimed);
  reviewer per-agent tokens UNMEASURABLE this run (two independent reasons: the lean
  lane that carries the only telemetry-recorded reviewer dispatch never executed —
  regression below — and the full-depth reviewer that DID run (trace 0009,
  review-phase.sh, sliced prompt) records no usage telemetry because *-phase.sh
  scripts do not source lib/telemetry.sh — a blind spot affecting BOTH runs' totals
  equally, baseline's recorded "reviewer" row being its lean iter-0 reviewer);
  wall/cost ≈ flat NEITHER confirmed nor refuted (composition differs: baseline ran a
  live lean iter-0 — bootstrap developer $2.42/319s + reviewer $0.89/198s recorded —
  while this run's iter-0 lane died in <1s).
- REGRESSION DISCOVERED 2026-07-14 (root-caused + reproduced): SPEED-2 (24af735)
  added top-level journey-set parsing to goal-iter-lean.sh —
  `REQUIRED_JOURNEYS="$(_spec_journeys 'Required-still-passing')"` (line 168 @
  b89a4d5). The script runs under `set -e` (its line 34) PLUS `pipefail` inherited
  from sourcing lib/telemetry.sh (`set -uo pipefail`, its line 21). On any spec whose
  Required-still-passing line contains no J-IDs — every iteration-0 baseline spec
  ("Required-still-passing journeys: none — ...") — the pipeline's inner
  `grep -oE 'J-[0-9]+'` exits 1, pipefail propagates it through the substitution, and
  set -e kills the script SILENTLY before the developer step (after line 98's
  iter_dispatch, before line 562's iter_config — exactly the observed telemetry gap:
  iter_dispatch 23:38:11 → evaluator start same second, no iter_config event, empty
  iter dir, no stderr). run-goal.sh only special-cases rc 70, so it proceeded to the
  evaluator, which honestly returned ESCALATE ("execution lane never ran") → iter-1
  forced full depth. Reproduced mechanically against the actual iter-0 spec file
  (bash -euo pipefail snippet: TARGET_JOURNEYS assignment survives, REQUIRED_JOURNEYS
  assignment rc=1 kills the shell). KNOB-INDEPENDENT: the block runs before any knob
  check, so this hits every lean iteration with a journey-less
  Required-still-passing (or Target-journeys) line since 24af735 — production
  impact: every fresh goal session's iter-0 baseline silently loses its entire lean
  lane (no dev bootstrap, no reviewer, no browser evidence) and burns an ESCALATE.
  Why nothing caught it: the offline SPEED evals use specs with J-IDs in both lines;
  the SPEED-2/3 G8 certifications did not run a fresh-session iter-0 through the
  lean lane. The baseline sha (5e878130) predates the block, which is why ITS iter-0
  lean lane ran fine.
- correction 2026-07-14 (to this run's PRE attribution addendum): the claim "24af735
  (SPEED-2) and 2ffedc3 (SPEED-3) sit behind CHAIN_LEAN_PARALLEL_BROWSER_QA, UNSET
  here" is FALSIFIED as an inertness argument — SPEED-2 also added the
  knob-INDEPENDENT top-level parsing above, which changed knob-off behavior (killed
  iter-0's lean lane). The A-vs-baseline delta therefore attributes to TOKEN-1 PLUS
  this regression's composition effect, not TOKEN-1 alone. The like-for-like qa-pair
  comparison above survives (same dispatch site, same depth, both runs); the
  wall/cost/topline token deltas do NOT cleanly attribute. Prediction-precedes-
  execution is intact (the runner-written PRE is untouched); this correction is the
  honest post-hoc grading of my own addendum.
- run-B implication 2026-07-14 (recorded BEFORE any run-B launch): with this
  regression at HEAD and --max-iter 2, run B as approved CANNOT exercise the knob —
  iter-0's lean lane dies before the fork spawn point regardless of knob value, the
  evaluator ESCALATEs, and iter-1 is then forced full depth (ESCALATE ⇒ full, no
  exceptions), which routes through run-phase.sh where CHAIN_LEAN_PARALLEL_BROWSER_QA
  is never consulted. A $15 run-B would be a mechanically-guaranteed null on the
  wall-overlap question — materially different from the pre-registered "tiny fixture
  may under-resolve" caveat. Escalated to the user (G7) instead of launching.
- retro report preserved 2026-07-14: copied verbatim (sha256
  6ba59532aded9bbe87978d013046339535310d9942aead424318a1ceef7c3580 verified match)
  from the kept scratch to benchmarks/results/20260714-004257-b89a4d506f5e.retro.md.
  Kept scratch: /tmp/bench-bench-20260713-2334.xLVVzP
- correction 2026-07-14 (to the REGRESSION paragraph above; discovered while scoping
  the fix): the journey-parsing death is NOT SPEED-2-introduced — `_spec_journeys` +
  both assignments exist at the BASELINE sha too (5e878130
  goal-iter-lean.sh:307-309, introduced by 633059a, deterministic-replay), positioned
  MID-SECTION (after dev+review, before browser-qa). SPEED-2 (24af735) RELOCATED the
  parsing before the developer step, enlarging the blast radius from "browser-qa +
  coherence lanes die" to "entire lean lane dies". Proof from the baseline kept
  scratch: its iter-0 traces show developer (0002) + reviewer (0003) then NO
  browser-qa/coherence dispatch, iter-0 verdict ESCALATE next_depth=full, no
  coherence.md in iter-0/ — the same silent death on the same journey-less
  "Required-still-passing: none" line, one pipeline stage later. CONSEQUENCE FOR THE
  COMPARISON ABOVE: baseline and run A compositions differ ONLY by baseline's iter-0
  bootstrap developer ($2.42/319s recorded) + reviewer ($0.89/198s recorded) — both
  runs lost their iter-0 browser lane and ESCALATEd identically. Composition-
  normalized (run A cost + baseline's iter-0 dev+review ≈ $14.98 vs $15.58), cost is
  ≈ FLAT (−3.9%) exactly as the hypothesis predicted; wall remains lower
  (4099+~517=~4616s vs 5833s, −21%) but within plausible evaluator/browser variance
  (e.g. evaluator 1037s vs 942s, qa 216s vs 876s swings). The "SPEED-2/3 knob-off
  inert" attribution claim stays falsified (the relocation IS a knob-off behavior
  change), but the delta it injected is the small dev+review skip, not an unknown.
  Both benchmark iter-0s silently losing their browser lane ALSO means: neither run
  ever exercised a live lean browser-qa section — the SPEED-2/3 fork code has still
  never run against a real iteration, reinforcing the run-B implication above.

---

## PRE bench-20260714-0634 · 2026-07-14T06:34:02Z
- framework-sha: c8bb8c068a1118fba6dc72e79d5ec19e55745bf1 (dirty: false)
- fixture: todo-app · max-iter 2
- hypothesis: TOKEN-1 @ 25ee855de7ec on fixed engine c8bb8c0: lean iter-0 lane ALIVE (iter_config event + developer/reviewer usage rows recorded); like-for-like lean reviewer input tokens DOWN vs baseline 20260712 (was 9,627 in / 45,095 cache-create); unconverted developer ≈ flat as falsification control; journeys HOLD 3/3
- metrics + prediction (mechanical --predict): journeys_passing_after>=3
- attribution 2026-07-14 (appended at launch, engine running; run "A′" of the
  user-approved fix → A′ → B sequence; CONTROL, knob off, launch env verified empty
  of CHAIN_*): sha c8bb8c0 = run A's b89a4d5 + the lean-lane pipefail fix (c8bb8c0,
  three `|| true` guards + scenario-I eval) + run A's results/ledger commit
  (edbe175, docs-only). vs the 20260712 baseline the engine-visible delta is
  TOKEN-1 + the fix; the fix's composition effect is pre-registered and DESIRED:
  iter-0's lean lane now survives its journey-less spec, so iter-0 runs
  developer+reviewer (as baseline did) AND continues into browser-qa + coherence
  (which baseline's iter-0 never reached — it died at the parse's pre-SPEED-2
  mid-section position). TOPLINE wall/cost vs baseline is therefore NOT the metric
  and a rise is expected, pre-registered, and not a strike. The metrics are the
  like-for-like per-agent rows: (a) lean iter-0 reviewer — baseline 9,627 in /
  45,095 cache-create / $0.889 / 198s under the full-file-read prompt vs A′ under
  the TOKEN-1 pre-sliced prompt → predicted DOWN; (b) lean iter-0 developer —
  UNCONVERTED by TOKEN-1, predicted ≈ flat (falsification control: if the
  developer's tokens drop like the reviewer's, the drop is ambient variance, not
  TOKEN-1); (c) qa-phase validation row IF both runs' iter-1 goes full depth
  (baseline's did; A′'s depth is the decomposer's choice — if lean, the qa pair
  comes from run A instead and A′ contributes the reviewer pair). Verdict shape
  expectations (not failures if different, but read the composition): iter-0 with
  real browser evidence of a bare scaffold likely CONTINUE (baseline's evidence-less
  iter-0 was ESCALATE); iter-1 depth may therefore differ from baseline's
  forced-full. B (knob=full, SAME sha — to be proven by empty results-only diff in
  B's PRE) compares against THIS run one-variable.

## POST bench-20260714-0634 · 2026-07-14T08:27:00Z
- results: benchmarks/results/20260714-082700-c8bb8c068a11.json
- headline: status=GOAL_ACHIEVED last_verdict=GOAL_ACHIEVED journeys=3/3 iters=2 engine_exit=0 wall=6778s cost=$17.452364
- predicate: journeys_passing_after>=3 → true (journeys_passing_after=3)
- verdict-vs-prediction: CONFIRMED
- assessment 2026-07-14: GENUINE CHAIN RESULT and the series' first GOAL_ACHIEVED
  (baseline + run A both capped out BUDGET_EXHAUSTED/CONTINUE): iter-0's resurrected
  lean lane produced real bare-scaffold browser evidence (verdict CONTINUE, not the
  evidence-less ESCALATE of both prior runs), iter-1 (full) built + verified all
  three journeys, evaluator declared GOAL_ACHIEVED through the deterministic gates.
  Every part of the free-text hypothesis lands: (1) lean lane ALIVE — iter_config
  event present (value=off), iter-0 dispatched developer → reviewer →
  browser-qa-agent, developer+reviewer usage rows recorded (all absent in run A);
  (2) like-for-like lean iter-0 REVIEWER (converted by TOKEN-1) DOWN on every axis
  vs baseline: input 9,627→9,604 (flat), cache_creation 45,095→43,182 (−4.2%,
  −1,913 tok — right order for the ~180-line Read replaced by the 56-line inlined
  slice), cache_read 1,299,005→1,098,587 (−15.4%), turns 22→19, cost $0.889→$0.759
  (−14.6%), 198s→159s; (3) falsification control DECISIVE: the UNCONVERTED
  developer moved the OPPOSITE way (input 9,924→10,078 flat; cache_creation
  208,213→263,951 +26.8%; cache_read +38.7%; turns 55→60; cost $2.42→$3.09 +27.7%)
  — ambient drift this run pushed agents UP, so the reviewer's across-the-board
  drop is not ambient. Prompt-shape attribution rests on the code pins at the
  measured sha (TOKEN-1 mirror gate + scenario-I dispatch-order eval), not on trace
  narration (too terse to corroborate either way). NON-REPLICATION recorded
  honestly: the qa-phase validation row (converted agent, full-depth iter-1 in all
  three runs) reads cache_creation 129,713 (baseline) / 96,327 (run A, −25.7%) /
  133,006 (A′, +2.5%) — a ±25% noise band around an expected ~2k-token mechanism;
  run A's qa-direction claim does NOT replicate and qa telemetry is INCONCLUSIVE
  for TOKEN-1 on this fixture. The reviewer pair + control is TOKEN-1's DoD
  telemetry evidence. Topline wall 5,833→6,778s (+16.2%) and cost $15.58→$17.45
  (+12.1%) vs baseline are the PRE-REGISTERED rise (iter-0's browser lane executes
  work baseline's dead lane never did) — not graded. chain_env clean (runner's six
  vars only; knob unset). benchmark_compare vs baseline: not run for the topline
  verdict — its REGRESS rule would mechanically flag the pre-registered
  composition rise; per-agent deltas above are the registered metrics. Kept
  scratch: /tmp/bench-bench-20260714-0634.8Bsppc
- retro report preserved 2026-07-14: copied verbatim (sha256
  b0c8b134296d967ae12b3c2e9479d3f83c3ca9e4ce20aeb4927f62a60884a901 verified match)
  to benchmarks/results/20260714-082700-c8bb8c068a11.retro.md.
- correction 2026-07-14 (found while analyzing run B): the assessment above
  OVERCLAIMS iter-0's browser outcome. "iter-0's resurrected lean lane produced real
  bare-scaffold browser evidence" is WRONG — iter-0's browser-qa SKIPPED all three
  journeys (ui-test-results: UT-J-01/02/03 = SKIP, evidence dir EMPTY; eval.md:
  "The baseline produced zero journey evidence ... QA boot lane tried to start a
  Next.js frontend at apps/frontend on port 3822 — a stack that does not exist —
  instead of the Flask app at 127.0.0.1:5177"; journeys recorded unknown ×3). What
  IS true and verified: the lean lane RAN (developer+reviewer+browser-qa dispatched,
  iter_config present — the fix's claim), the reviewer pair stands unaffected, and
  the iter-0 verdict was CONTINUE because the evaluator credited the lane's honest
  SKIP diagnosis as agent-fixable ("not STALLED"). The 3/3 journeys + GOAL_ACHIEVED
  came from iter-1's full-depth lane entirely. NEW ISOLATED GAP (knob-independent,
  present in A′ AND B, pre-existing): on a single-service Flask fixture the lean
  lane's generic frontend boot (start-frontend.sh template, Next.js/apps-frontend
  assumptions) fails and browser-qa is told "Frontend available: no" — the fixture
  sets CHAIN_START_BACKEND_CMD but nothing points CHAIN_FRONTEND_URL at the Flask
  app itself, so lean iter-0 browser evidence is structurally impossible on this
  fixture until that env gap is closed (candidate fix: fixture.env
  CHAIN_FRONTEND_URL=http://127.0.0.1:5177; same family as REL-10's backend fix).

---

## PRE bench-20260714-0830 · 2026-07-14T08:30:24Z
- framework-sha: 76b8225ee14f8cfa94ef84206f2e46c0aad4d2fd (dirty: false)
- fixture: todo-app · max-iter 2
- attribution 2026-07-14 (appended at launch, engine running; run "B" of the
  user-approved fix → A′ → B sequence): ONE VARIABLE vs run A′ bench-20260714-0634.
  Sha proof: 76b8225 = A′'s engine sha c8bb8c0 + A′'s results/ledger commit only —
  `git diff c8bb8c0 HEAD -- .claude scripts config templates CLAUDE.md` verified
  EMPTY (0 lines) at launch. Launch environment verified to contain EXACTLY
  `CHAIN_LEAN_PARALLEL_BROWSER_QA=full` and no other CHAIN_ var (the launch guard
  aborts otherwise; this run's chain_env block records the knob alongside the
  runner's own six). Comparison target: A′ (journeys 3/3, GOAL_ACHIEVED, wall
  6,778s, cost $17.45; iter-0 lean sequential browser-qa, iter-1 full). Decisive
  observables are MECHANICAL, pre-registered here: iter_config value=full with
  empty reason; the "Forking the FULL browser-qa section" spawn line; fork
  telemetry attribution (browser-qa usage inside the fork); review and browser-qa
  wall-clock overlap in iter-0; journeys HOLD; no SPEED-2 tripwire trip; no orphan
  processes. The WALL delta is pre-registered as likely UNRESOLVABLE on this
  fixture (expected overlap saving ≈ min(review 159s, browser section boot+replay+
  LLM ≈ 2-5 min) ≈ 2-4 min against ±10% ≈ ±700s run noise) — a null wall delta
  means "fixture cannot resolve it; flip decision needs real-session telemetry",
  NOT "the feature is worthless"; a wall INCREASE beyond noise, a journey drop, a
  tripwire trip, or an orphaned fork process is a genuine strike against flipping.
  iter-1's depth is the chain's own choice; if it goes full (as in A′ and both
  prior runs), only iter-0 exercises the knob — that too is a pre-registered
  fixture limit, not a feature failure.
- hypothesis: SPEED-2/3 flip evidence @ engine c8bb8c0, knob CHAIN_LEAN_PARALLEL_BROWSER_QA=full, ONE variable vs run A' bench-20260714-0634: lean iter-0 forks the FULL browser-qa section concurrent with review (iter_config value=full, fork spawn logged, review/browser-qa overlap in time); journeys HOLD 3/3; cost ≈ flat (no attempt-1 review FAILs → no wasted fork); wall DOWN by roughly the iter-0 review∥browser-qa overlap — pre-registered sensitivity: overlap ≈ 2-5 min vs ±10% wall noise on this fixture, so a null wall delta means 'fixture cannot resolve it; flip decision needs real-session telemetry', NOT 'feature worthless'; wall INCREASE beyond noise or journey drop or tripwire/orphan = genuine strike against flipping
- metrics + prediction (mechanical --predict): journeys_passing_after>=3

## POST bench-20260714-0830 · 2026-07-14T10:10:19Z
- results: benchmarks/results/20260714-101019-76b8225ee14f.json
- headline: status=BUDGET_EXHAUSTED last_verdict=CONTINUE journeys=3/3 iters=2 engine_exit=0 wall=5995s cost=$16.664435
- predicate: journeys_passing_after>=3 → true (journeys_passing_after=3)
- verdict-vs-prediction: CONFIRMED
- assessment 2026-07-14: FORK MECHANICS FULLY VERIFIED LIVE, WALL QUESTION NULL —
  the pre-registered split lands exactly. Mechanical observables, all green:
  iter_config {value:full, requested:full, reason:""} (no headless demotion);
  "Forking the FULL browser-qa section (LLM lane included)" spawned after the
  developer settled (08:39:07); reviewer ran 08:39:08–08:40:21 WHILE the fork
  booted services beside it; fork's browser-qa-agent dispatch attributed correctly
  in telemetry (08:41:22–08:42:38, inside the fork); join settled the fork BEFORE
  the evaluator started (08:42:39, 1s after the lane finished — evaluator input set
  complete); attempt-1 review FAILs 0 (no wasted-dispatch path taken;
  parallel_bqa_wasted_dispatch events: 0); SPEED-2 tripwire never tripped (no state
  file); ZERO orphaned fork processes post-run (pgrep clean). One-variable held:
  chain_env = the runner's six vars + exactly CHAIN_LEAN_PARALLEL_BROWSER_QA=full.
  benchmark_compare A′→B: wall 6,778→5,995s (−11.6%), cost $17.45→$16.66 (−4.5%),
  journeys 3/3→3/3, verdict OK. THE WALL DELTA IS NOT ATTRIBUTABLE TO THE KNOB —
  pre-registered sensitivity caveat fires. Decomposition: the actual overlap
  potential in iter-0 was ≤73s (review took only 73s this run vs A′'s 159s, and the
  fork's LLM lane started 61s AFTER review already ended — only the fork's boot
  phase overlapped review), while individual agent durations swung far larger than
  any overlap: developer 385→274s (cache_create 263,951→63,537), qa-phase 404→52s,
  evaluator total 854→1,253s. −783s is run variance around a ≤73s mechanism.
  VERDICT-SHAPE differences are evaluator judgment variance, not knob effects, on
  near-identical inputs: BOTH runs' iter-0 browser lanes SKIPPED all journeys for
  the SAME pre-existing infra reason (generic Next.js frontend boot fails on the
  single-service Flask fixture; A′ probed :3822, B :3247 — each run's derived
  default; see the correction under A′'s POST) — A′'s evaluator graded that
  CONTINUE ("honest SKIP, agent-fixable"), B's graded it ESCALATE ("lane produced
  nothing") — both defensible readings of the same rubric boundary; and at iter-1
  both runs reached 3/3 with full-depth evidence, where A′'s evaluator declared
  GOAL_ACHIEVED and B's held CONTINUE at the max-iter cap (the two-key gate is
  deliberately conservative; 3/3 passing is identical in both journey histories).
  No quality regression is attributable to the fork: journeys held, evidence set
  complete at the join, review verdict PASS in both. FLIP-DECISION INPUT (grading
  the free-text hypothesis MIXED — mechanics CONFIRMED, wall NULL as
  pre-registered): the feature is live-proven SAFE on this fixture but its wall
  win is UNRESOLVED here (review 73–159s vs a browser section whose LLM lane runs
  ~75s after a ~2-min boot — the fixture's sections are too short to overlap
  meaningfully). Per the PRE's interpretation rule this reads "fixture cannot
  resolve it; flip decision needs real-session telemetry", NOT "feature
  worthless". Kept scratch: /tmp/bench-bench-20260714-0830.1jHzAr
- retro report preserved 2026-07-14: copied verbatim (sha256
  b135495f224e9967e79123b3101c4fe82248422a6dad64dac4f78ab68240ae31 verified match)
  to benchmarks/results/20260714-101019-76b8225ee14f.retro.md.

---

## PRE bench-20260714-1539 · 2026-07-14T15:39:20Z
- framework-sha: 39e2a79de68a577c67b70f4d20e4676e336c4827 (dirty: false)
- fixture: todo-app · max-iter 2
- hypothesis: TOKEN-8+REL-12 @ 39e2a79de68a: full-depth usage rows appear (developer, reviewer, auditor visible in by_agent); iter-0 lean browser-qa EXECUTES journeys on the fixture (SKIP-for-boot gone — failing evidence beats no evidence); journeys HOLD 3/3; cost totals rise from VISIBILITY, not regression; status not predicated
- metrics + prediction (mechanical --predict): journeys_passing_after>=3
- attribution 2026-07-14 (appended at launch, engine running; run "C" of the
  user-approved TOKEN-8+REL-12 session). COMPARABILITY BREAK, PRE-REGISTERED
  FIRST: TOKEN-8 makes previously-INVISIBLE full-depth dispatch usage VISIBLE
  — developer/reviewer/auditor/orchestrator/UI-chain rows now land in
  telemetry, so by_agent totals and estimated cost vs A′ (bench-20260714-0634)
  and B (bench-20260714-0830) RISE from measurement COVERAGE alone; any
  benchmark_compare cost-REGRESS verdict against pre-TOKEN-8 runs is EXPECTED
  and MEANINGLESS; run C is the NEW COMPARABILITY BASELINE for all future
  runs. Sha proof: 39e2a79de68a = B's engine sha 76b8225 + two docs/results-
  only commits (a71e724, b49392e — `git diff 76b8225 b49392e -- scripts
  .claude config templates CLAUDE.md agents skills commands hooks policy`
  verified EMPTY at launch) + exactly the TOKEN-8/REL-12 feature commit
  (39e2a79). Engine-visible delta vs A′/B is therefore: telemetry sourcing in
  15 phase scripts (TOKEN-8), the lean lane's single-service frontend
  short-circuit (REL-12), and fixture.env CHAIN_FRONTEND_URL=127.0.0.1:5177.
  chain_env note, pre-registered: this run's block gains CHAIN_FRONTEND_URL
  (the runner's fixture-manifest exports are now seven vars, not six) —
  fixture boot config, not an experiment knob. Launch env verified empty of
  CHAIN_* (knobs off; CHAIN_LEAN_PARALLEL_BROWSER_QA unset → sequential lean
  lane, one variable set vs A′: the feature commit itself). Decisive
  observables, mechanical: (1) TOKEN-8 DoD — session telemetry.jsonl carries
  claude_usage rows for the full-depth iteration's developer + reviewer +
  auditor (rows named in the POST); (2) REL-12 DoD — iter-0 lean browser-qa
  EXECUTES journeys (the REL-12 short-circuit log line present, naming
  127.0.0.1:5177; SKIP-for-boot gone; failing-journey evidence acceptable —
  it beats no evidence); (3) journeys HOLD 3/3 (the mechanical predicate);
  (4) topline wall/cost vs A′/B NOT graded (visibility rise pre-registered
  above); (5) final status (GOAL_ACHIEVED vs CONTINUE at the max-iter cap) is
  evaluator judgment variance on near-identical inputs (A′-vs-B precedent)
  and is NOT a pass/fail observable — hypothesis says "status not predicated".

## POST bench-20260714-1539 · 2026-07-14T16:50:58Z
- results: benchmarks/results/20260714-165058-39e2a79de68a.json
- headline: status=GOAL_ACHIEVED last_verdict=GOAL_ACHIEVED journeys=3/3 iters=2 engine_exit=0 wall=4297s cost=$20.84373
- predicate: journeys_passing_after>=3 → true (journeys_passing_after=3)
- verdict-vs-prediction: CONFIRMED
- assessment 2026-07-14: GENUINE CHAIN RESULT, the series' second GOAL_ACHIEVED and
  its fastest (wall 6,778→4,297s vs A′, −36.6%). Run C is the NEW COMPARABILITY
  BASELINE per the PRE. Grading the free-text hypothesis clause by clause:
  (1) REL-12 CONFIRMED, fully — the short-circuit fired in BOTH iterations
  ("[goal-iter-lean] Frontend already answering at http://127.0.0.1:5177 (HTTP
  200) — direct probe enabled the browser lane; skipping the frontend boot
  (REL-12 single-service short-circuit)"), and iter-0 browser-qa EXECUTED all
  three journeys instead of SKIP-for-boot: verdict "FAIL (0/3 passed, 0
  skipped)" with per-journey DOM diagnostics ("0 inputs, 0 buttons, 0 links")
  and three PNG evidence files (A′/B iter-0: SKIP ×3, evidence dir EMPTY,
  journeys unknown ×3). Failing evidence beat no evidence exactly as
  hypothesized — the iter-0 evaluator: "all three Must-have journeys were
  executed in a real browser and all three failed. This is a clean starting
  line, not a defect."
  (2) TOKEN-8 clause NOT RESOLVED BY THIS RUN — pre-registered observable
  missing for a composition reason, not a code failure: NO full-depth iteration
  ran, so dev-phase.sh/review-phase.sh/phase-audit.sh never executed and the
  full-depth developer/reviewer/auditor rows cannot exist. The by_agent
  developer/reviewer rows present are the LEAN lane's (visible since
  pre-TOKEN-8); no auditor row. Root cause is REL-12's own success: iter-0
  produced real browser evidence, so the evaluator recommended lean for iter-1
  ("the lean pipeline still runs browser QA over all three journeys") and the
  session achieved goal without a full iteration — the engine's own close-out
  even declared "next depth: full" for the iteration that never ran. The
  MECHANISM did prove itself live where a converted script DID run:
  demo-phase.sh (converted) dispatched demo-narrator in iter-0 and its usage
  row appears ($0.247) — A′'s same-class demo dispatch (iter-1 Branch-UI) left
  NO row. TOKEN-8 therefore stays IN-PROGRESS; any future full-depth iteration
  (e.g. a --max-iter 3 run or the SPEED-2/3 flip control) resolves its live DoD.
  (3) journeys HOLD 3/3 — mechanical predicate true.
  (4) cost topline $17.45→$20.84 (+19.4%) NOT graded per the PRE; honest
  attribution note: with no full iteration, TOKEN-8's new visibility added only
  ~$0.25 of previously-invisible rows this run (demo-narrator), so this rise is
  DOMINATED BY RUN VARIANCE (iter-1 evaluator ×2 dispatches $5.09 total,
  developer $3.08, decomposer $2.24), consistent with the ±25% agent-level
  noise band A′↔B established — the PRE's "cost rises from visibility" framing
  applies to future FULL-depth runs, only weakly here.
  INTEGRITY NOTE (G7 stop-and-ask honored, user-reviewed disposition): iter-1's
  missing-evidence tripwire fired once — an Anthropic API server error cut
  browser-qa's FINAL report write AFTER all three journeys had passed with
  screenshots + golden replay scripts already on disk (missing_evidence
  telemetry event 16:33:56Z; SKIPPED crash-stub on file). REL-11's honesty
  machinery worked as designed (loud banner, stub kept the evaluator fed) and
  the evaluator verified from the evidence itself (methodology A.3,
  screenshots outrank prose) before declaring GOAL_ACHIEVED through the
  deterministic gates — environmental blip absorbed, not a framework defect.
  FRAMEWORK GAP flagged by that evaluator for triage (retro drafted it):
  goal-gates' cmd_results passes VACUOUSLY on a crash-stub (searches for
  "| FAIL |" cells; a stub with no table at all reads as pass) — it cannot
  tell "all journeys passed" from "the report is missing". chain_env: exactly
  the seven pre-registered vars incl. CHAIN_FRONTEND_URL — one-variable claim
  holds. benchmark_compare vs A′/B: not run for the topline verdict (the PRE
  pre-registered its cost-REGRESS as meaningless across the TOKEN-8 visibility
  break). Kept scratch: /tmp/bench-bench-20260714-1539.5Ro0t7
- retro report preserved 2026-07-14: copied verbatim (sha256
  325923a3f0789faa8a6c69d73d35d758330e6e8dbadf6173701e6fe60a772d9d verified
  match) to benchmarks/results/20260714-165058-39e2a79de68a.retro.md.
