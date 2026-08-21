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

---

## PRE bench-20260715-0924 · 2026-07-15T09:24:28Z
- framework-sha: fd378ca276a932e3509b1120bffd7da4d00bf25b (dirty: false)
- fixture: todo-app · max-iter 2
- hypothesis: Run D @ fd378ca276a9, knob=full, ONE variable vs run C bench-20260714-1539: fork spawns at iter-0 (iter_config value=full, spawn logged), review ∥ browser-qa overlap visible in timings; journeys HOLD 3/3; cost ≈ flat vs C (same visibility baseline); wall DOWN by ~100s (iter-0 overlap cap, review 100s fully covered by the 237s browser section) plus ~242s more if iter-1 stays lean (its review cap) — sensitivity pre-registered: prior runs show ±10%-class wall noise (±430s on C) and GOAL_ACHIEVED/CONTINUE-at-cap variance, so a sub-noise delta = "still fixture-bound; flip waits for real-session telemetry", while wall INCREASE beyond noise, journey drop, tripwire fire, or orphan process = genuine strike against flipping; final status NOT predicated
- metrics + prediction (mechanical --predict): journeys_passing_after>=3
- attribution 2026-07-15 (appended at launch, engine running; run "D" of the
  user-approved SPEED-2/3 flip re-measurement, G9 approval this session): ONE
  VARIABLE AT THE KNOB LEVEL vs run C bench-20260714-1539. Sha context:
  fd378ca276a9 = C's engine sha 39e2a79de68a + 31ba8fb (run C results/docs) +
  d0f9896 (REL-13 tmp lifecycle + SEC-6 allowlist) + fd378ca (SEC-7 hook fix +
  curl-guard v2). UNLIKE B-vs-A′, the engine-visible diff is NOT empty —
  characterized hunk-by-hunk at launch: goal-iter-lean.sh +6 is an
  owner-guarded standalone-only janitor block (CHAIN_TMPDIR_OWNER_PID==$$ —
  false under run-goal.sh, so a NO-OP in this run); run-goal.sh +56 is the
  REL-13 disk preflight/AWAITING_DISK pause (acts only under disk pressure);
  run-benchmark.sh +9 relocates the scratch root (this run: ~/.cache/iad/shared,
  off quota'd /tmp); core.md +10 is dormant disk-error recovery guidance
  (activates only on ENOSPC/EDQUOT); settings.json/SEC-6+SEC-7 widen the Bash
  allowlist + fix guard hooks (direction: FEWER permission denials in dispatched
  agents, no dispatch-structure change). No change to iteration structure,
  section order, agent bodies, or model routing. Launch env verified: zero
  ambient CHAIN_ vars; exactly CHAIN_LEAN_PARALLEL_BROWSER_QA=full exported —
  expected chain_env = C's seven vars + the knob. Comparison target: C
  (GOAL_ACHIEVED, journeys 3/3, wall 4,297s, cost $20.84; BOTH iterations lean,
  knob off; the TOKEN-8 cost-visibility baseline). Decisive observables,
  mechanical, pre-registered: (1) iter_config {value:full, requested:full} at
  iter-0 — headless, no demotion; (2) the full-section fork spawn line after
  the developer settles; (3) review ∥ browser-qa OVERLAP VISIBLE IN TIMINGS
  (browser-qa invocation_start BEFORE reviewer invocation_end) — the witness D
  adds over B: C proved the lean lane executes journeys (REL-12 short-circuit,
  LLM dispatch starts ~3s into the section), so the forked lane can genuinely
  cover review's window for the first time; (4) journeys HOLD 3/3 (the
  mechanical predicate); (5) tripwire trips 0; (6) zero orphan processes in the
  kept scratch; (7) cost ≈ flat vs C. Wall sensitivity, computed FROM C's
  telemetry at plan time: overlap cap = min(review 100s, browser 237s) = ~100s
  at iter-0, plus min(review 242s, browser 888s) = ~242s IF iter-1 stays lean —
  best case ~342s (−8.0%) vs a ±10%-class noise band (±430s on C's wall), so
  the predicted saving is SUB-NOISE even best-case; per the pre-committed
  decision matrix a sub-noise delta with quality held reads "second
  fixture-bound null → stay off, close SPEED-2/3 as DONE-knob-off, flip waits
  on real-session telemetry". iter-1 depth is the chain's own choice: if it
  goes FULL, only iter-0 exercises the knob (pre-registered fixture limit) and
  the TOKEN-8 live DoD resolves opportunistically (developer/reviewer/auditor
  usage rows from the converted phase scripts); if lean, TOKEN-8 stays pending
  — neither outcome is forced (G7). Ambient-load note, accepted by the user at
  approval: two idle interactive goal sessions parked on this box (trendora
  mcp-loop, tapeology tradable_wall; both pump-waiting, hours stale) — a
  wake-up mid-run would add wall noise.

## POST bench-20260715-0924 · 2026-07-15T10:11:35Z
- results: benchmarks/results/20260715-101135-fd378ca276a9.json
- headline: status=STALLED last_verdict=STALLED journeys=0/3 iters=2 engine_exit=0 wall=2827s cost=$15.952902
- predicate: journeys_passing_after>=3 → false (journeys_passing_after=0)
- verdict-vs-prediction: REFUTED
- assessment 2026-07-15 (G7 STOP-AND-ASK FIRED — journeys 0/3 < 3; run graded,
  disposition presented to the user, NO flip, NO further runs today):
  FORK MECHANICS 100% GREEN, QUALITY STRIKE ENVIRONMENTAL. Every pre-registered
  mechanical observable landed: iter_config {value:full, requested:full} in BOTH
  iterations (headless honored, no demotion); the full-section fork spawn line
  after the developer settled in both (engine.log:84,:312); the OVERLAP WITNESS
  realized — iter-0 browser-qa invocation_start 09:32:33 preceded reviewer end
  09:36:00 by 207s (review wall 211s), iter-1 09:56:55 vs 10:00:00 = 185s of a
  188s review — the fork realized ~392s of its ~399s theoretical cap (98%),
  first live proof of the review ∥ browser-qa mechanism on a lean-capable lane
  (REL-12 short-circuit fired both iters, frontend HTTP 200; engine wall report
  prints "overlap saved 3.5m"/"8.4m", the iter-1 figure also counting coherence
  + showcase parallelism that C had too); joins consumed cleanly ("Consumed
  forked full browser-qa results" ×2); attempt-1 review FAILs 0;
  parallel_bqa_wasted_dispatch events 0; tripwire never tripped (no state
  file); ZERO orphan processes in the kept scratch (pgrep clean; ports
  5177/9224 free post-run). THE STRIKE — journeys 0/3, prediction REFUTED — is
  ENVIRONMENTAL, not knob-attributable: in BOTH iterations the forked
  browser-qa agent ran fine (570s/393s), confirmed the frontend healthy, then
  Chrome's DevTools port (9224) never opened within the 15s window; the agents'
  in-run diagnosis (both iterations, independently): ~50-53 foreign Chrome
  processes on this shared host with debug ports 9222/9223 claimed by OTHER
  sessions; stale profile lock ruled out (cleaned + retried), OOM ruled out,
  CPU load ruled out; identical signature reproduced 2×. Post-run host check
  corroborates LIVE: 47 chrome processes still running, 9222/9223 still
  foreign-claimed at assessment time. The ambient-load risk pre-registered at
  approval materialized as browser-infrastructure contention rather than API
  contention. The honesty machinery worked as designed: SKIP-with-reason (never
  a fake pass), journeys held at unknown, iter-0 CONTINUE (transient bet) →
  iter-1 STALLED at the second consecutive no-evidence iteration (operator-
  owned infra blocker — correct escalation, and the halt is itself evidence
  the C.2 stall test works). benchmark_compare C→D: REGRESS (journeys 3→0);
  wall −34.2% and cost −23.5% are UNREADABLE as knob evidence — composition
  broke comparability exactly as the sensitivity language anticipated (D's
  browser lanes did ~6min of Chrome diagnosis then SKIP instead of journey
  execution; D iter-1 targeted J-01 only vs C's three journeys; D iter-1 ran a
  single evaluator pass vs C's two-key GOAL_ACHIEVED confirm ×2) — no wall or
  cost clause is graded. PRE-COMMITTED MATRIX APPLIED: quality strike → STAY
  OFF, strike recorded, no further runs today. Context for the disposition:
  quality-hold under knob=full was already demonstrated by run B (3/3 HOLD);
  what D uniquely adds is the realized-overlap witness — the mechanism works
  end-to-end live; the fixture still cannot price the flip, and a rerun today
  would hit the same contended host. OPPORTUNISTIC TOKEN-8 CHECK: both
  iterations ran LEAN (iter_dispatch depth=lean ×2) — no full-depth iteration
  occurred — TOKEN-8 live DoD still pending; its status untouched. Kept
  scratch: /home/dennis-chan/.cache/iad/shared/bench-bench-20260715-0924.ifaR4T
- retro report preserved 2026-07-15: copied verbatim (sha256
  80a208fd7f7e0d381ab0fe4953b6636ea6025877d7808dd71a177894edc9af64 verified match)
  to benchmarks/results/20260715-101135-fd378ca276a9.retro.md.

---

## PRE bench-20260716-0626 · 2026-07-16T06:26:04Z
- framework-sha: d41a38bcfb4f59b2257b825a8e20d9355eb7903b (dirty: false)
- fixture: todo-app · max-iter 2
- hypothesis: TOKEN-2 @ d41a38bcfb4f: standard-tier decomposer holds spec quality — journeys 3/3 within cap; decomposer per-agent cost DOWN materially vs control (run C decomposer: 2 calls, $3.591, 56,705 out-tok); wall/cost otherwise ≈ flat at the TOKEN-8 visibility baseline; final status NOT predicated (GOAL_ACHIEVED/CONTINUE/STALLED variance is documented)
- metrics + prediction (mechanical --predict): journeys_passing_after>=3
- attribution 2026-07-16 (appended at launch, engine running; the TOKEN-2
  user-approved G1 spend session, prompt of 2026-07-15): ONE VARIABLE AT THE
  ROUTING LEVEL vs run C bench-20260714-1539 — goal-decomposer model_tier
  strong→standard (claude-opus-4-8 → claude-sonnet-5; flip commit 869c338,
  launch sha d41a38bcfb4f = flip + docs/fixture-evidence commits only). Blast
  radius proven at flip time: agent_permissions model/effort across all 20
  agents changed exactly ONE row (goal-decomposer); all judges (goal-evaluator,
  auditor, goal-proposer, reviewer) unchanged; decomposer effort stays max; D4
  judge-effort guard still covers it (JUDGE_AGENTS membership untouched).
  REL-1 FIXTURES MEASURED PRE-LAUNCH ON THIS BRANCH: goal-evaluator 5/5, all
  verdict classes exact, 244–316s/case (judge resolved opus-4-8 @ max —
  config-surface regression insurance green). COMPARABILITY AUDIT vs run C
  (intervening commits 31ba8fb, d0f9896, fd378ca, fd18b9b): 31ba8fb and fd18b9b
  verified EMPTY over the scratch copy set (.claude scripts config templates
  CLAUDE.md); d0f9896+fd378ca engine-visible deltas partition into (a)
  dormant-by-construction paths — run-goal.sh disk preflight acts only under
  disk pressure; goal-iter-lean.sh janitor block is owner-guarded
  standalone-only (NO-OP under run-goal.sh); core.md +10 disk-recovery lines
  activate only on ENOSPC/EDQUOT; (b) REL-13 tmp/scratch relocation off quota'd
  /tmp tmpfs to ~/.cache/iad disk — I/O location only, applies identically to
  ANY run at today's runner (a fresh control could not undo it); run D executed
  the full engine on these paths cleanly; (c) SEC-6/SEC-7 permission+hook
  surface — EMPIRICALLY NIL on this fixture in BOTH directions: run C's 16
  agent traces contain ZERO permission denials (grep across granted/approval/
  denied/blocked phrasings — nothing for SEC-6's wider allowlist to smooth) and
  run D's 17 post-SEC-6/7 traces also ZERO (newly-live guards never fired on
  fixture-class commands; flask is allowlisted in install-security-policy.json;
  unpinned registry installs WARN-and-proceed by design; run D's fixture built
  and served HTTP 200 in both iterations); (d) eval/runner-only files
  (run-evals.sh, run-judgment-evals.sh, tmp-doctor.sh, suggest-allowlist.sh)
  never execute inside an engine iteration; the interactive-dispatch skill line
  is pump-only (headless run). NAMED RESIDUALS, confined to the non-criterial
  wall/cost topline: tmpfs→disk I/O for engine tmp files, and ~24 added
  agent-readable doc lines (core.md+anti-patterns) — cost direction UP, i.e.
  conservative against the "decomposer cost DOWN" claim; both sub-noise class
  (±10% wall / ±25% per-agent bands established A′↔B↔C). ENVIRONMENT PREFLIGHT
  (run D's lesson, mandatory — findings stated): at first check (2026-07-15)
  the box was DISQUALIFYING — two active goal engines (tradable_wall resumed,
  mcp-loop mid-iteration) + 3 CDP Chrome profiles, 9222/9223 foreign-claimed,
  one stray --remote-debugging-port=9224 flag-holder; STOPPED per protocol and
  presented to the user, who chose to clear the box. At launch (2026-07-16):
  both engines gone (user-stopped); this session killed the two orphaned
  automation Chrome trees left behind (goal-mcp-loop-iter-40-qa QA browser +
  the parked sessions' superpowers-chrome plugin browser — ephemeral, owners
  reboot them on demand); final state ZERO CDP/automation Chrome consumers,
  9222/9223/9224 + 5177 free, env clean of CHAIN_* (knob off). Remaining
  ambient load, accepted as BASELINE-EQUIVALENT: the user's ordinary desktop
  Chrome (no debug port, personal profile, up 2d7h — demonstrably already
  running during green control run C, so removing it would CHANGE the
  environment vs control) and 4 idle parked claude UIs whose superpowers MCP
  servers currently hold no browser. ADOPT CRITERIA (pre-committed): fixtures
  5/5 (done) · journeys 3/3 (the mechanical predicate) · decomposer per-agent
  cost DOWN materially vs run C's 2-call/$3.591/56.7k-out row · comparative
  spec-quality reading (branch iter specs vs run C's kept-scratch specs:
  structure, journey targeting, acceptance concreteness — quoted lines, since
  journeys alone can mask sloppier specs on a tiny fixture) NO WORSE. Wall/cost
  topline NOT an adopt criterion (hedged "≈ flat", reduced confidence per the
  named residuals). OPPORTUNISTIC TOKEN-8: if any iteration dispatches
  full-depth, the converted phase scripts' developer/reviewer/auditor usage
  rows resolve TOKEN-8's live DoD — scratch telemetry grepped post-run either
  way. Final status NOT predicated (GOAL_ACHIEVED vs CONTINUE-at-cap is
  documented evaluator variance on near-identical inputs, A′/B/C precedent).
  ADOPT/REVERT decision gets a final user confirm before any merge (branch
  protocol; STALE-with-evidence is a fully successful outcome).

## POST bench-20260716-0626 · 2026-07-16T07:26:53Z
- results: benchmarks/results/20260716-072653-d41a38bcfb4f.json
- headline: status=GOAL_ACHIEVED last_verdict=GOAL_ACHIEVED journeys=3/3 iters=2 engine_exit=0 wall=3648s cost=$21.152457
- predicate: journeys_passing_after>=3 → true (journeys_passing_after=3)
- verdict-vs-prediction: CONFIRMED
- assessment 2026-07-16 (TOKEN-2 after-measurement B; adopt decision pending the
  user's confirm, recorded under the roadmap entry): GENUINE CHAIN RESULT — the
  series' third GOAL_ACHIEVED and its fastest (wall 4,297→3,648s vs C, −15.1%).
  Grading the hypothesis clause by clause:
  (1) JOURNEYS 3/3 HOLD — mechanical predicate CONFIRMED. attempt1_review_fails
  0, malformed_verdicts 0, coherence.md **COHERENCE-PASS**, GOAL_ACHIEVED passed
  the deterministic gates + two-key confirm (evaluator ×3, all opus). Browser
  evidence per journey (distinct PNGs; evaluator's table cites post-reload
  frames).
  (2) DECOMPOSER COST DOWN MATERIALLY — CONFIRMED: $3.591 → $2.184 (−39.2%);
  output tokens 56,705 → 45,629 (−19.5%); duration 752 → 523s (−30%); 2 calls
  both runs. ROUTING PROOF: engine.log Step-1 dispatch line reads
  "model=claude-sonnet-5"; results by_model shows claude-opus-4-8 billed for
  EXACTLY 3 invocations = the goal-evaluator's 3 calls ($3.808 matches its
  by_agent row to the cent) — the only opus consumer was the judge, as designed.
  (3) WALL/COST ≈ FLAT AT THE TOKEN-8 VISIBILITY BASELINE — cost CONFIRMED:
  $20.84 → $21.15 (+1.5%), and like-for-like E is flat-to-BETTER because E's
  coverage is more complete than C's (C's iter-1 browser-qa dispatch crashed
  before its report — its usage row never landed — and C's iter-1 demo row is
  likewise missing; E records browser-qa ×2 and demo ×2). Notable per-agent
  moves inside the flat total: decomposer −39%, evaluator −43%, coherence −33%;
  developer +64% ($4.40→$7.23) — read as PART ±25%-band noise (A′↔B precedent),
  part plausible COST SHIFT DOWNSTREAM of a leaner spec (E's 88-line iter-1 spec
  leaves DOM/test design to the developer, and its client-side-JS architecture
  is simply more code than C's server-rendered forms); the fixture cannot
  decompose noise vs shift further (pre-registered). Wall −15.1% is favorable-
  direction but NOT graded (PRE-named residuals: tmpfs→disk relocation + doc
  lines; the decomposer's own −229s accounts for ~35% of the −649s delta).
  (4) SPEC QUALITY (the adopt criterion — comparative reading, branch scratch
  specs vs run C's kept-scratch specs, quotes not vibes):
  EQUAL — structure/metadata complete in both; identical journey bundle with the
  same one-feature rationale (E: "together they're the entire remaining
  Must-have scope … all three share one canonical store"; C: "they are not
  three independent risky changes — they are one feature"); both argue the lean
  depth call against the same rubric trigger (E: "this does cross the
  backend/frontend boundary, but that crossing is intrinsic to every possible
  journey in this single-page app"; C: budget + evaluator recommendation +
  pinned data model); both carry the 2-lean-iteration budget awareness.
  THINNER (E) — no DOM-contract selector table (C pinned #add-form/#todo-list/
  li.todo.done…; E's developer invented selectors); no per-journey evidence
  naming or store-reset mandate — C DETECTED goal.md's own J-02→J-03 state
  contradiction ("J-02 leaves 'buy milk' done, but J-03's acceptance requires
  the Open view to show 'buy milk'") and mandated per-journey resets, where E
  restates goal.md's sequence unexamined and the executor's pragmatics absorbed
  it; softer persistence-test phrasing (E: "persists the new todo to the JSON
  store"; C: "re-read the JSON file from disk and assert done is True").
  DIVERGENT INTERPRETATION, JUDGED CONFORMANT — goal.md IA line: "The only
  other route is /health." C ledgered a navigable-pages reading at iter-0 and
  still forbade any JSON read-API; E shipped GET/POST /api/todos +
  /api/todos/<id>/toggle with client-side filtering WITHOUT ledgering that
  reading (its one ledger entry covers the smaller default-All-view call). The
  UNCHANGED opus evaluator examined the endpoints explicitly ("three endpoints
  only, client filters one fetched array; all UI on the existing / page, no new
  route/duplicate home") and coherence passed the canonical-store rule — so NOT
  a goal violation, but C's interpretation-logging depth is absent in E.
  NET: outcome-equal on every observable (verdicts, journeys, zero attempt-1
  review fails, distinct evidence), artifact-thinner on defensive spec
  engineering; the thinness plausibly surfaces as the developer +64% row inside
  a flat total.
  (5) FINAL STATUS GOAL_ACHIEVED — not predicated; consistent with C.
  ENVIRONMENT: mandatory preflight HELD at launch — first check (07-15) was
  disqualifying (two active goal engines + 3 CDP profiles; stop-and-ask fired;
  user cleared the engines); at launch zero CDP/automation Chrome consumers,
  922x/5177 free; only the user's desktop Chrome (no debug port; demonstrably
  already running during green control C) plus 4 idle parked claude UIs
  remained. REL-12 short-circuit fired in BOTH iterations (as in C); knob
  unset; fixture manifest exports same family as C. POST-RUN ORPHAN NOTE
  (honesty, new observable class from run D's standard): two processes from
  THIS run were found alive post-run with cwd = this scratch — the browser-qa
  Chrome (port 9222, superpowers-chrome-3 profile, started mid-run) and the
  session-demo's `.venv/bin/python app.py` (started ~3 min before close-out).
  This session's cleanup attempt was BLOCKED by the permission layer
  (classifier read them as possibly-foreign workloads) — left running, flagged
  to the operator in the session report. Framework-gap candidate for triage:
  the demo/close-out step does not reap the service it boots, and the forked
  browser-qa Chrome outlives the engine.
  OPPORTUNISTIC TOKEN-8 CHECK: both iterations dispatched LEAN (iter_dispatch
  depth=lean ×2) — no full-depth iteration, so the live DoD did not resolve;
  TOKEN-8 status untouched (note added to its entry).
  ADOPT SCORECARD (pre-committed): fixtures 5/5 ✓ · journeys 3/3 ✓ · decomposer
  cost down materially ✓ · spec quality: outcome-equal / artifact-thinner
  (quoted above) — recommendation ADOPT presented to the user; decision +
  confirm recorded in the TOKEN-2 roadmap entry. Kept scratch:
  /home/dennis-chan/.cache/iad/shared/bench-bench-20260716-0626.PmMupK

---

## PRE bench-20260716-1430 · 2026-07-16T14:30:56Z
- framework-sha: 13668f3059638cb7f8fa739004e4f70f3bee3584 (dirty: false)
- fixture: todo-app · max-iter 2
- hypothesis: TOKEN-7 @ 13668f305963: reviewer per-agent wall + output tokens DOWN vs run E bench-20260716-0626 (hypothesis ~10% per Superpowers-6, direction certain, size uncertain); packet present in scratch for every review round incl. any fix rounds; journeys HOLD 3/3; other agents ≈ flat; status not predicated
- metrics + prediction (mechanical --predict): journeys_passing_after>=3
- attribution 2026-07-16 (appended at launch, engine running; the TOKEN-7
  user-approved G9 spend session, prompt of 2026-07-16): ONE VARIABLE ON THE
  REVIEWER'S DISPATCH PATH vs control run E `bench-20260716-0626` @
  d41a38bcfb4f — TOKEN-7's pre-baked review packet (commit 13668f3: packet
  built post-developer/pre-fork + rebuilt post-fix, packet-first reviewer
  prompt with the hint reframed to truncation follow-ups, reviewer body
  1.2.0→1.2.1). WINDOW AUDIT (all 8 commits d41a38bcfb4f..HEAD, file lists
  read): 083db52 + d19f4a4 + b10ddc6 docs-only; TOKEN-3 0700934 touches
  run-phase.sh Step 2 behind CHAIN_SKIP_TESTPLAN_IF_PRESENT default FALSE
  (full-mode-only; benchmark env carries no CHAIN_* knobs and run E dispatched
  lean ×2); TOKEN-4 2bf5e51 touches run-phase.sh Step 9's audit-rerun cap
  (full-mode-only; lean has no audit step); TOKEN-5 743c0a3 touches
  interactive-dispatch.sh/goal-await-dispatch.sh/skills (pump backend only;
  the benchmark runs headless — those files never execute); TOKEN-6 1ea8853
  adds lib/condense.sh + a session-start warn-only wiring in run-goal.sh
  gated on lessons/assumptions >200 lines (a fresh benchmark scratch starts
  empty — deterministic no-op, no dispatch); TOKEN-7 13668f3 is the variable.
  None of TOKEN-3/4/5/6 touches the reviewer's path. JUDGMENT FIXTURES
  MEASURED PRE-LAUNCH ON THIS SHA (the G9 ~$3 gate): reviewer 4/4, every
  verdict class exact (PASS/PASS_WITH_NOTES/FAIL/FAIL, 123–200s/case) under
  the packet-first prompt with the packet built per-sandbox by the mirrored
  helper (packet observed in each case sandbox at the engine path layout) —
  no class flip, judge resolved claude-sonnet-5 @ max. Offline gates at
  launch: run-evals 116/116 (incl. the new test-review-packet.sh G3 fixture),
  test-goal-parallel-bqa 80/80 (expected artifact tree gains the packet in
  BOTH sequential and fork modes), prompt-mirror byte-gate green with NO new
  sanctioned rename ($REVIEW_PACKET spelled identically both sides).
  ENVIRONMENT PREFLIGHT (run D's lesson, mandatory — findings): zero goal
  engines, zero benchmark/lean processes, zero CDP/automation Chrome
  consumers, ports 9222/9223/9224/5177/8000/3000 all free, shell env clean of
  CHAIN_*; remaining ambient load BASELINE-EQUIVALENT to green runs C/E — the
  user's ordinary desktop Chrome (no debug port; demonstrably running during
  both green controls) and idle parked claude UIs whose superpowers MCP node
  servers hold no browser (same class run E accepted; this session is one of
  them). NAMED RESIDUALS vs E (sub-noise class, cost direction ≈ nil): one
  packet build per review round (git diff + stdlib python, sub-second,
  engine-side — no model tokens) and one added engine log line per build.
  MEASUREMENT PLAN: per-agent reviewer rows (wall, output tokens, cost,
  turns) vs run E's reviewer row (2 inv, 24,080 out-tok, $1.574, 300,473 ms,
  37 turns); packet files verified per round in the kept scratch (engine.log
  "review packet built" lines vs review rounds, rebuilt-after-fix if any fix
  round occurs); opportunistic TOKEN-8 full-depth check as always. Reviewer
  wall/out-tok are the graded clauses; size claim (~10%) is graded honestly
  against the ±25% per-agent noise band (A′↔B↔C precedent) — a null result on
  size against that band is a finding about fixture sensitivity, not a failed
  replication. Final status NOT predicated (documented evaluator variance).
- LAUNCH ABORTED 2026-07-16 ~15:34Z (infrastructure, not engine): the session
  harness killed the backgrounded runner's process tree ~4 min after launch —
  iteration-0's verify-only developer was mid-dispatch (engine.log ends
  mid-stream; no halt banner, no quota event, no packet involvement; ~<$1
  spent). Engine tree confirmed dead; scratch kept at
  ~/.cache/iad/shared/bench-bench-20260716-1430.fHcC8L for provenance. No
  results, no POST. Superseded by the detached relaunch below — SAME sha
  13668f3059638cb7f8fa739004e4f70f3bee3584, same hypothesis re-registered
  verbatim, same environment (preflight re-verified at relaunch); the
  attribution paragraph above carries over to the relaunch unchanged.

---

## PRE bench-20260716-1436 · 2026-07-16T14:36:30Z
- framework-sha: 18d639c17ac21db0936295485c4f5a04a34bbf36 (dirty: false)
- fixture: todo-app · max-iter 2
- hypothesis: TOKEN-7 @ 13668f305963 (launch sha 18d639c = +ledger-docs only; relaunch of killed bench-20260716-1430): reviewer per-agent wall + output tokens DOWN vs run E bench-20260716-0626 (hypothesis ~10% per Superpowers-6, direction certain, size uncertain); packet present in scratch for every review round incl. any fix rounds; journeys HOLD 3/3; other agents ≈ flat; status not predicated
- metrics + prediction (mechanical --predict): journeys_passing_after>=3

## POST bench-20260716-1436 · 2026-07-16T16:17:41Z
- results: benchmarks/results/20260716-161741-18d639c17ac2.json
- headline: status=GOAL_ACHIEVED last_verdict=GOAL_ACHIEVED journeys=3/3 iters=2 engine_exit=0 wall=6070s cost=$28.245694
- predicate: journeys_passing_after>=3 → true (journeys_passing_after=3)
- verdict-vs-prediction: CONFIRMED
- assessment 2026-07-16 (TOKEN-7 after-measurement; grading the hypothesis
  clause by clause, honest sizes vs the source's ~10% claim):
  (1) JOURNEYS 3/3 HOLD — mechanical predicate CONFIRMED. GOAL_ACHIEVED passed
  the deterministic gates + two-key confirm; COHERENCE-PASS; attempt-1 review
  fails 0; zero friction counters (retro: no quota pauses, no malformed
  verdicts). Same final status as control run E (not predicated either way).
  (2) DEPTH FLIP — the one structural difference vs E: the decomposer sent
  iter-1 FULL (E ran lean×2). Named consequences: (a) the reviewer comparison
  crosses modes — E iter-1 lean reviewer vs this run's phase-mode reviewer
  (review-phase.sh, richer required inputs incl. the execution plan), a
  conservative confound since the packet won anyway (below); (b) the session
  topline is NOT comparable — $21.15 → $28.25 (+33.5%) and wall 3648 → 6070s
  are EXPLAINED by the full chain's 8 extra agent rows (orchestrator $0.85 +
  qa test-plan/validation $0.67 + ui-impact $0.43 + ui-test-designer $0.44 +
  ux-regression $0.40 + phase-closure $0.60 + auditor $1.58 ≈ $4.97, plus a
  heavier browser-qa and 4 summarizer calls), so the 'other agents ≈ flat'
  clause is UNGRADEABLE at the session level — the depth choice is documented
  decomposer variance, not a TOKEN-7 effect (packet code paths are identical
  in both depths and were exercised in both).
  (3) REVIEWER PER-AGENT — THE GRADED CLAUSE (E: 2 inv, 24,080 out-tok,
  $1.574, 300.5s, 37 turns → T7: 2 inv, 24,181 out-tok, $1.192, 292.4s, 24
  turns), per-invocation from both kept scratches:
    · iter-1 REAL review (E lean vs T7 full+packet): turns 21→16 (−23.8%),
      billed cache-read input 1,366,695→452,357 (−66.9%), cost $1.069→$0.780
      (−27.1%), wall 220.6→186.9s (−15.5%), out-tok 17,521→16,361 (−6.6%).
    · iter-0 baseline review (near-empty diff both runs): turns 16→8 (−50%),
      cache-read 522,503→272,774 (−47.8%), cost $0.505→$0.412 (−18.4%),
      out-tok +19% (small absolute), wall 79.9→105.5s (+33% — sub-noise on an
      ~80s dispatch; the reviewer's own report cites reading 'the empty
      review packet' as its zero-change evidence).
  MECHANISM CONFIRMED, METRIC RELOCATED: the packet does NOT cut what the
  reviewer WRITES (out-tok ≈ flat session-total, −6.6% real review — the
  ~10% 'review tokens' claim is a NULL on output tokens at this fixture's
  noise band) — it cuts TURNS (−35% session) and therefore BILLED INPUT
  (cache-read −48%/−67% per round: every eliminated git round-trip stops
  re-reading the whole accumulated context) and COST (reviewer −24.3%
  session, −27.1% real review). Wall: −15.5% on the real review (in line
  with the source's ~10%), ≈ flat session-total (the baseline round's +26s
  absorbs it). Superpowers-6's number REPLICATES on billed-input/cost/turns
  and on real-review wall — their claim, our data: direction right, their
  size understated on input (−67%) and overstated on output (null).
  (4) PACKET PRESENT EVERY ROUND — CONFIRMED: engine.log shows exactly 2
  'review packet built' lines (one per review round: lean iter-0 412B
  near-empty packet 15:43; phase-mode iter-1 11,424B packet 16:11, 4 files
  all shown in full) and 0 'build failed' lines; both files verified in the
  kept scratch; 2 reviewer dispatches total. Zero review FAILs occurred, so
  the fix-path REBUILD was not exercised live — that path stays covered by
  the offline scenario tests (test-goal-parallel-bqa C/G ordering + the
  rebuild call after fork-reap; run-evals 116/116 at launch).
  (5) OPPORTUNISTIC TOKEN-8 CHECK — LIVE DoD RESOLVED: iter-1's FULL dispatch
  ran the converted phase scripts and the session telemetry carries per-agent
  usage rows for orchestrator/qa(×2: test-plan + validation)/ui-impact/
  ui-test-designer/ux-regression/phase-closure/auditor, all attributed
  iter=1 — the exact rows TOKEN-8's measurement note has been waiting for
  since bench-20260714-1539. TOKEN-3 confirmed inert in-run (knob off, Step 2
  generated the test plan; 0 skip lines); TOKEN-4 confirmed inert (audit
  passed clean; 0 rerun-cap lines).
  ENVIRONMENT: preflight held at relaunch (zero CDP/automation consumers,
  ports free, env clean; desktop Chrome + idle parked UIs = the accepted
  C/E baseline). First launch (bench-20260716-1430) was killed by the
  session harness ~4 min in — annotated above, superseded by this detached
  relaunch; ~<$1 of its spend is outside this run's books. POST-RUN ORPHANS
  (honesty; the run-D observable class RECURRED): two automation Chrome trees
  from THIS run were alive at close-out — pid 2348846 (CDP 9222, profile
  superpowers-chrome-3; the browser-qa browser) and pid 2371948 (CDP 9223,
  profile superpowers-chrome-4; started later in the run). No app.py orphan;
  5177 free. Cleanup NOT attempted from this session (the permission
  classifier is known to deny these kills — bench-orphan precedent); kill
  one-liner reported to the operator in the session report. Same
  framework-gap candidate as run E flagged: the forked/scripted browser-qa
  Chrome outlives the engine. Kept scratch:
  /home/dennis-chan/.cache/iad/shared/bench-bench-20260716-1436.dNHg0w

## PRE speed-package-20260728 · 2026-07-28T15:30:00Z
- framework-sha: e619138 (+ the SPEED-12/15/17/18/19/TOKEN-9 commits landing the same day; dirty during authoring)
- fixture: next REAL tapeology goal session (or an EVO-3 benchmark rerun) vs the desk-session baseline recorded below
- hypothesis: the SPEED-9..19 + REP-4 + TOKEN-9 package cuts typical goal-mode iteration wall time under 60 min without journey-quality regressions. Baseline (desk, 15 iters): ~153 agent-min/iter; verification = 54% of agent minutes; full depth 4 of last 6 iters; browser-qa >100 turns/invocation; 3 of last 5 iterations were evidence-only waste (~6h); zero quota-pause events recorded (attribution bug).
- metrics + prediction (manual grading): median wall for lean/evidence/zero-change iterations < 60m; evidence-class gaps resolved in < 45m via the evidence micro-path (no developer dispatch); full-depth ratio <= 1 in 6; browser-qa <= 60 turns/invocation; demo-narrator+readme token cost ~1/3 of sonnet baseline; NO journey regressions or golden verdict-class flips attributable to the package; summaries name concrete files/screens (grep for 'Product changes:' rows).
- note: pre-registered manually (G8) — the package is engine+contract work, not a run-benchmark.sh invocation; grade against the next session's telemetry with analyze_telemetry.py --wall.

## POST speed-package-20260728 · 2026-07-29T12:30:00Z
- graded against: LIVE tapeology desk session iters 15-18 (the first iterations
  running the full package — vendored sync to main 48a3b97 on Jul 29 00:22,
  engine restart 01:04; iters 0-14 ran OLD code and are excluded), telemetry +
  trace analysis performed 2026-07-29 during the iteration-shape investigation.
- arm-by-arm:
  · median lean/evidence/zero-change wall < 60m — **UNTESTED**: no lean or
    evidence iteration ran in the window; every iteration 15-18 dispatched
    FULL (see next arm — the same defect).
  · full-depth ratio <= 1 in 6 — **FAILED (5 of 6 full)**: the decomposer wrote
    a qualifying `Full trigger: 2 — adds a field to persisted record` line
    into EVERY spec (trivially true for every proposer-promoted journey) and
    the SPEED-10 allowlist trusted it; the evaluator's `next_depth: evidence`
    recommendation (iters 16, 17) was overridden both times. Root cause of
    the surviving 2h+ floor; promoted to anti-pattern 25 and fixed by
    SPEED-20 (iteration-shape package).
  · browser-qa <= 60 turns/invocation — **FAILED**: 104-132 turns observed
    (J-06-class no-golden journeys keep riding the LLM lane; golden-first
    regression SPEED-21/22/23 targets this).
  · demo-narrator+readme cost ~1/3 sonnet baseline — **PASSED (better)**:
    demo-narrator 26m → ~90s per iteration after the haiku routing.
  · no journey regressions / golden verdict-class flips — **PASSED**: 13/14
    journeys passing after iter-18, 1 partial (J-14, new scope); zero
    package-attributable regressions; iter-14's 8/9 replay false-FAIL was
    selector drift (pre-package code), not a golden flip.
  · summaries name concrete files/screens — **PASSED** (Product changes: rows
    present in the post-sync summaries).
  · (headline, unregistered but the package's stated goal) full-depth
    productive time 210m → 133m (−37%); steady-state iterations 15-18 =
    118-151 min of near-continuous first-try LLM work across 16-18 SEQUENTIAL
    dispatches, zero quota pauses (0s across 174 dispatches — SPEED-13's
    attribution fix held), zero retry loops. The remaining floor is the
    pipeline's SHAPE, not failures — which is what the iteration-shape
    package (PRE below) attacks.
- verdict: package effective where it aimed (−37% productive time, showcase
  costs collapsed, honesty fixes held) but the <60m target was structurally
  unreachable while the depth governor could be self-certified around —
  full-ratio arm decisively failed. Follow-up package pre-registered below.

## PRE iteration-shape-20260729 · 2026-07-29T12:45:00Z
- framework-sha: 48a3b97 + the iteration-shape package (SPEED-20..24, TOKEN-10,
  REP-5, SPEED-15 armed 3600/trim, TOKEN-3 flip) landing on branch
  speed-iteration-shape this session; dirty during authoring.
- fixture: the next 6 REAL goal-session iterations running this package
  (tapeology desk session after the operator's next vendored sync, or any
  adopter session), graded with `analyze_telemetry.py --wall`.
- hypothesis: with the depth governor deterministic (arbiter), the budget
  armed with teeth (3600s/trim + next-iter lean ratchet), executor context
  sliced, and the regression sweep golden-first, the typical iteration
  becomes lean/evidence by construction and lands under an hour.
- metrics + prediction (manual grading, G8):
  · median iteration wall < 60 min over the next 6 real-session iterations;
  · full-depth ratio <= 1 in 4 (arbiter window cap W=4), with every full
    carrying a `depth_full_granted` reason that is NOT `new-fullstack-journey`
    unless journey-history confirms the journey was genuinely new;
  · developer mean wall < 25 min (TOKEN-10 slice; desk baseline 31→77m);
  · >= 2 goldens auto-derived and installed (`golden_autoderived` events) OR
    zero eligible PASS-without-golden journeys existed;
  · zero journey regressions and zero golden verdict-class flips attributable
    to the package; any DEFERRED-BUDGET row is re-verified within 2 iterations;
  · no GOAL_ACHIEVED certified while a DEFERRED-BUDGET row exists (mechanical,
    goal_gate).
- note: pre-registered manually (G8) — engine+contract work, not a
  run-benchmark.sh invocation. Rollback ladder if the prediction fails:
  CHAIN_DEPTH_ARBITER=false / CHAIN_ITER_TIME_BUDGET_SECONDS=0 /
  CHAIN_ITER_BUDGET_MODE=warn / CHAIN_DEV_FULL_GOAL=true /
  CHAIN_GOLDEN_AUTODERIVE=false / CHAIN_REPLAY_MASS_FAIL_BREAKER=false /
  CHAIN_UI_COMBINED=false / CHAIN_SKIP_TESTPLAN_IF_PRESENT=false — each knob
  reverts exactly one item.

---

## PRE bench-20260820-2246 · 2026-08-20T22:46:53Z
- framework-sha: f8c98b95064070eba1a8f58df30e134749fde60d (dirty: false)
- fixture: todo-app · max-iter 2
- hypothesis: STYLE-1 G8 stage-1 ARM A = CONTROL at framework f8c98b9 (style knobs unset; same-sha baseline for arm B): chain reaches GOAL_ACHIEVED 3/3 within max-iter 2 with 0 attempt-1 review FAILs and 0 malformed verdicts; every claude_usage row reads output_style=default and carries no output_style_requested; zero iter_config / output_style_mismatch events; the developer iter-1 row is the baseline for arm B's token prediction. Deviation from the CAND-STYLE DoD, recorded: fixture A/B across two sessions instead of a same-session knob flip (both vendored real-session repos have live engines and HOST_GUARD_MAX_ENGINES=2), so the same-session cost guard is NOT exercised here; stage 2 = the real session after the next vendored sync.
- metrics + prediction (mechanical --predict): journeys_passing_after>=3;final_status==GOAL_ACHIEVED;attempt1_review_fails==0;malformed_verdicts==0

## POST bench-20260820-2246 · 2026-08-20T23:36:04Z
- results: benchmarks/results/20260820-233604-f8c98b950640.json
- headline: status=GOAL_ACHIEVED last_verdict=GOAL_ACHIEVED journeys=3/3 iters=2 engine_exit=0 wall=2951s cost=$15.16705
- predicate: journeys_passing_after>=3 → true (journeys_passing_after=3)
- predicate: final_status==GOAL_ACHIEVED → true (final_status='GOAL_ACHIEVED')
- predicate: attempt1_review_fails==0 → true (attempt1_review_fails=0)
- predicate: malformed_verdicts==0 → true (malformed_verdicts=0)
- verdict-vs-prediction: CONFIRMED

---

## PRE bench-20260820-2337 · 2026-08-20T23:37:25Z
- framework-sha: 3e165ba9a35f0216e8c742a8ac5c532184edd2a4 (dirty: false)
- fixture: todo-app · max-iter 2
- hypothesis: STYLE-1 G8 stage-1 ARM B = ARMED at framework f8c98b9 (CHAIN_OUTPUT_STYLES=true): every wave-1 dispatch (developer, qa, browser-qa-agent, orchestrator, ui-impact-analyst, ux-regression-reviewer) carries --settings outputStyle=Concise in its trace args AND reads back output_style=Concise from the init event; judges read output_style=default; zero output_style_mismatch; exactly one iter_config key=CHAIN_OUTPUT_STYLES per iteration; chain still GOAL_ACHIEVED 3/3 with 0 attempt-1 review FAILs, 0 malformed verdicts, 0 missing_evidence rows and no artifact-schema issues; developer iter-1 output_tokens -20..30 percent vs arm A with num_turns flat within 10 percent and cache_creation_input_tokens at most +25K per wave-1 dispatch; wall not worse than arm A +10 percent. Graded MANUAL with the CAND-STYLE read-out recipe; n=1 real iteration per arm, so the token clause is indicative only — the pass/fail clauses are the proof of mechanism.
- metrics + prediction (mechanical --predict): journeys_passing_after>=3;final_status==GOAL_ACHIEVED;attempt1_review_fails==0;malformed_verdicts==0

## POST bench-20260820-2337 · 2026-08-21T00:38:32Z
- results: benchmarks/results/20260821-003832-3e165ba9a35f.json
- headline: status=BUDGET_EXHAUSTED last_verdict=CONTINUE journeys=1/3 iters=2 engine_exit=0 wall=3667s cost=$19.847708
- predicate: journeys_passing_after>=3 → false (journeys_passing_after=1)
- predicate: final_status==GOAL_ACHIEVED → false (final_status='BUDGET_EXHAUSTED')
- predicate: attempt1_review_fails==0 → true (attempt1_review_fails=0)
- predicate: malformed_verdicts==0 → true (malformed_verdicts=0)
- verdict-vs-prediction: MIXED
- assessment 2026-08-21 (STYLE-1 G8 stage-1, arms A = bench-20260820-2246 control and
  B = bench-20260820-2337 armed; same fixture, code-identical framework f8c98b9/3e165ba;
  graded clause by clause, MANUAL for everything --predict cannot see):
  (1) MECHANISM — PASSED on every clause: all six wave-1 agents (developer ×2, browser-qa-agent
  ×2, orchestrator, ui-impact-analyst, qa, ux-regression-reviewer) requested `Concise` and read
  back `output_style=Concise` from the CLI init event; every judge/showcase agent read back
  `default`; `iter_config key=CHAIN_OUTPUT_STYLES` fired in both iterations; zero
  `output_style_mismatch`, zero `missing_evidence`, zero `experiment_reverted`; tripwire quiet
  in both arms; doctor `output-styles` PASS (armed) at engine boot; arm A's rows all
  `default` with no `output_style_requested`. The `--settings` flag itself is not visible in
  trace `args` (that field records the caller argv; injected flags such as --effort/--model
  appear as separate fields) — graded by readback, follow-up filed.
  (2) JOURNEYS 3/3 — REFUTED for arm B (1/3, BUDGET_EXHAUSTED after iter-1 ran FULL depth),
  but NOT attributable to the style: arm A's browser-QA Chrome (profile
  `superpowers/browser-profiles/iad-qa-scratch`, CDP 10133, started 23:56 during arm A)
  outlived its engine and still held the pinned profile when arm B started, so arm B's Chrome
  MCP lane got `ECONNREFUSED 127.0.0.1:10547` in BOTH iterations (iter-0 browser QA verdict
  SKIPPED, iter-1 refused twice); the evaluator graded J-02/J-03 "partial" from the Playwright
  demo walkthrough alone, whose step 4 (authored by the Default-styled demo-narrator) clicked
  an already-done item's "✓" and never produced the mixed open+done state. The evaluator's own
  checks (store probe, 14/14 tests, auditor stop/restart persistence) confirmed the product
  works — "only the picture of it is missing". Same orphan class as the 2026-07-16 run-D/E
  note; this time it cost the next session its browser lane.
  (3) DEVELOPER TOKENS — MIXED (n=1 per cell): the only like-for-like cell, iter-0 (lean in
  both arms): 14,967 → 8,416 output tokens (−44%), 35 → 28 turns (−20%), 184 → 109 s (−41%),
  cache_creation 53.7K → 71.6K (+17.9K, inside the ≤+25K budget). iter-1 is depth-confounded
  (arm A lean 29,518 tok / 45 turns / 292 s vs arm B FULL 33,098 / 46 / 325 s — the full-depth
  developer consumes the orchestrator plan and a different input set). Session-level developer:
  44,485 → 41,514 tokens (−7%), 80 → 74 turns, $2.70 → $2.82.
  (4) FULL-DEPTH STYLED ROWS (first ever, n=1 each, no same-version control): orchestrator
  7,991 tok / 11 turns (2026-07-16 unstyled, older framework: 18,570 / 22); qa 11,923 / 57
  (14,186 / 74 over 2 invocations then); ui-impact-analyst 8,737 / 22 (4,352 / 15 — but the UI
  step is now combined with test-plan authoring, so not comparable); ux-regression-reviewer
  5,946 / 14 (3,456 / 11). Cross-version, indicative only.
  (5) ARTIFACT THINNING — no deterministic signal fired (0 missing_evidence); dev handoff
  iter-1 5,184 B (A) vs 4,307 B + 3,584 B frontend handoff (B, full depth); review PASS
  attempt 1 in both arms (iter-0 of B; the full-depth iter-1 review emits no `review_verdict`
  telemetry — pre-existing gap in review-phase.sh, so that metric is blind in full iterations);
  audit PASS_WITH_GAPS with gaps "in evidence, not behaviour". WATCH ITEM: the styled QA report
  claimed a Chrome screenshot confirmed the done treatment while its only screenshot showed an
  unticked item — caught and corrected by the auditor and flagged by the styled
  ux-regression-reviewer. n=1; cannot be attributed to Concise yet; count QA over-claims per
  arm in stage 2. `artifact_schemas.py validate` flags the lean review reports and the QA report
  in BOTH arms (`## Verdict` section rule vs the `**Verdict:**` first-line format) —
  validator/format mismatch, pre-existing, not a style effect.
  (6) WALL/COST — session wall 2951 s → 3667 s and $15.17 → $19.85, explained by the full-depth
  iter-1 (7 extra agent rows ≈ $5.5 — auditor alone $3.69) and the blocked browser lane; iter-0
  wall 14.7 m → 11.2 m (−24%).
  (7) PRE-EXISTING DEFECTS SURFACED (framework, not style): (a) benchmark/browser-QA Chrome
  outlives the engine and blocks the next session's pinned chrome-mcp profile; (b)
  `closure_gate.py:66` matches the word "todo" case-insensitively as a TODO marker — the
  closure gate fails on every iteration of a todo app (the evaluator correctly called it a
  false alarm); (c) full-depth review emits no `review_verdict` telemetry; (d) injected
  `--settings` not recorded in the trace row.
  VERDICT: mechanism CONFIRMED; token clause indicative (−44% on the one like-for-like cell,
  +18K cache creation); journey clause REFUTED for infrastructure reasons, not the style;
  no flip decision from stage 1 (cross-session A/B, n=1, cost guard not exercised by design).
  Stage 2 = the real same-session rollout per the CAND-STYLE DoD after the next vendored sync,
  with the orphan-Chrome reap fixed first. Kept scratches:
  /home/dennis-chan/.cache/iad/shared/bench-bench-20260820-2246.hC7Rqc (A),
  /home/dennis-chan/.cache/iad/shared/bench-bench-20260820-2337.5aoUbc (B).
