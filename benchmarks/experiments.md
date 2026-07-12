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
