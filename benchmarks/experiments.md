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
