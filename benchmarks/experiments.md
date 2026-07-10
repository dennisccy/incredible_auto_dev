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
