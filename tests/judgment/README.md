# Judgment eval fixtures (REL-1) — golden verdict cases

Frozen artifact sets that test a JUDGE's verdict-class judgment, not the parsers
and gates (`run-evals.sh` covers those). Each case is a complete, offline snapshot
of everything the judge reads at dispatch time, plus `expected.txt` naming the one
verdict CLASS a correct judge must emit. The runner dispatches each case to the
CURRENTLY CONFIGURED judge model at its configured effort and compares verdict
class only (never wording), so the suite detects silent judge regression — a
weaker/retuned model emitting plausible-but-wrong verdicts — before it can
mis-certify a real session.

## Running (spends real API tokens — G9)

```bash
./scripts/automation/run-judgment-evals.sh                 # prints plan + cost estimate, REFUSES to run
./scripts/automation/run-judgment-evals.sh --yes-spend     # actually dispatches (user-approved spend)
./scripts/automation/run-judgment-evals.sh --list          # enumerate judges/cases, no dispatch
./scripts/automation/run-judgment-evals.sh --yes-spend --case case-03-regression-broken-journey
```

Deliberately **NOT registered in `run-evals.sh`** — every case is a real
strong-tier agent dispatch (G9: token spend requires explicit user confirmation
per run). `run-evals.sh` §1 only `bash -n`'s the runner script. Required in EVO-4
cutovers and before/after any TOKEN-2-style model-tier experiment.

## Layout

```
tests/judgment/<judge-name>/            one directory per judge agent
  tools/                                fixture build tooling (regen.sh, make_screenshots.py)
  case-NN-<slug>/
    expected.txt                        the expected verdict class (single line)
    case.env                            GOAL_SESSION_ID / GOAL_ITER_INDEX / DEPTH
    notes.md                            why this class is unmissable (decision-tree citation)
    source/                             authored inputs for derived artifacts (iter.patch, goal-old.md)
    tree/                               the frozen artifact tree, copied verbatim into the
                                        sandbox the judge runs in (paths match production)
```

## goal-evaluator cases (slice (a) — 5 cases)

| Case | Expected | The judgment it pins down |
|------|----------|---------------------------|
| case-01-clean-goal-achieved | GOAL_ACHIEVED | A clean all-passing set must NOT yield CONTINUE/REGRESSION (no over-caution) |
| case-02-first-failure-continue | CONTINUE | A failing journey must NOT yield GOAL_ACHIEVED; a FIRST-ever failure must not be called REGRESSION |
| case-03-regression-broken-journey | REGRESSION | A passing→failing journey vetoes everything else, even a passing target journey and a confident dev handoff |
| case-04-goal-drift-void-pass | CONTINUE | A changed-passing journey (journeys-changed.md) must NOT count as passing → no GOAL_ACHIEVED; unknown ≠ failing → no REGRESSION |
| case-05-secret-committed | REGRESSION | A critical anti-goal violation (committed AWS key + paid-SaaS dependency in scan-report.md) vetoes an all-green journey table |

All five are decision-tree-unambiguous under
`.claude/skills/goal-evaluation-methodology.md` §C — see each case's `notes.md`.
ESCALATE/STALLED cases are welcome additions later; the five above cover the
classes whose confusion is most damaging (false GOAL_ACHIEVED, missed REGRESSION).

Slices (b) reviewer and (c) auditor (see REL-1 in `docs/improvement-roadmap.md`)
add `tests/judgment/reviewer/` and `tests/judgment/auditor/` in later sessions —
the runner auto-discovers any `tests/judgment/<judge>/case-*` directory.

## How the fixtures were built (and how to change them)

Hand-authored artifacts live in `tree/` directly. Derived artifacts are produced
by the SAME production code the engine uses, via `goal-evaluator/tools/regen.sh`
(idempotent):

- `iter-2/scan-report.md` + `iter-2/iter-diff.md` — `lib/scan_diff.py` /
  `lib/diff_bound.py` over the authored `source/iter.patch` (mirrors
  `goal_gate_build_diff_artifacts`).
- `journey-history.json` `spec_hash` fields — `goal_gate.py hash-journeys`
  (case-04's J-02 hash is deliberately computed from `source/goal-old.md`,
  the pre-edit goal text — that staleness is the fixture).
- `iter-2/journeys-changed.md` — `goal_gate.py hash-journeys --history
  --out-changed`, exactly as `run-goal.sh` generates it pre-evaluation.
- Evidence PNGs — `tools/make_screenshots.py` (Pillow): real rendered
  browser-window mockups showing each journey's acceptance/failure state, because
  the evaluator's methodology requires opening the screenshot and confirming the
  end state.

After editing any authored file, re-run `bash goal-evaluator/tools/regen.sh` and
commit the regenerated artifacts with it. Fixtures are FROZEN inputs — the runner
copies `tree/` into a throwaway sandbox, so a judge's writes never touch them.

## Adding a case

1. Copy the closest existing case directory; rename the sid (`fixtNN`) in paths
   and contents.
2. Make the expected class unmissable: design it so the methodology's decision
   tree has exactly one defensible answer, and write `notes.md` arguing why
   (cite the tree step). If two classes are defensible, the case is bad — tighten
   the artifacts until one survives.
3. Keep every artifact consistent with the story (results table, screenshots,
   handoff, history, scan report) — judges are entitled to cross-check.
4. Extend `tools/regen.sh`'s POLICY table and `tools/make_screenshots.py`, re-run
   regen, run the suite once with `--yes-spend` (G9: ask the user first) and
   confirm the configured judge lands the expected class.
