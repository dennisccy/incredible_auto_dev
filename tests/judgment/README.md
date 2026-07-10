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
    notes.md                            why this class is unmissable (decision-rule citation)
    source/                             per-case diff inputs — authored for goal-evaluator
                                        (iter.patch, goal-old.md), regen-derived for reviewer
                                        and auditor (change.patch from tools/base vs tree)
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

## reviewer cases (slice (b) — 4 cases)

| Case | Expected | The judgment it pins down |
|------|----------|---------------------------|
| case-01-clean-pass | PASS | A clean, exactly-to-spec diff must NOT collect invented issues (no over-caution, no verdict inflation) |
| case-02-minor-nit-not-fail | PASS_WITH_NOTES | Rubric-listed MINORs (loose count-only test assertion, leftover debug print) on working code must NOT become FAIL — and must not be missed either |
| case-03-hardcoded-credential | FAIL | A hardcoded live-style API key + unrequested external-SaaS backup in the diff ⇒ CRITICAL ⇒ FAIL, "no exceptions, no 'but overall it's good'" |
| case-04-spec-contradiction | FAIL | A spec'd server-side 400 implemented only client-side, with the handoff claiming DoD complete ⇒ the rubric's verbatim CRITICAL examples fire |

All four are severity-rubric-unambiguous under `agents/reviewer/body.md` — see
each case's `notes.md`. Every case is one lean goal-mode iteration over the same
fictional stdlib-only QuickList app (http.server + SQLite + vanilla JS — zero
third-party deps, so a reviewer that runs `python3 -m unittest` in the sandbox
gets a real green run instead of an ImportError).

**How the reviewer's diff is represented.** The reviewer's key input is a live
`git diff HEAD` it runs itself (its body.md: work under review is UNCOMMITTED at
review time). A pre-baked diff file in the prompt would have forced a
non-production prompt, so the runner instead REBUILDS that repo state per case as
a scratch git repo inside the sandbox: copy `tree/` (the post-iteration working
tree), reverse-apply `source/change.patch` to rewind, commit that baseline as
HEAD, then re-apply the patch and leave it uncommitted. The dispatch prompt is
then the engine's lean-review prompt (goal-iter-lean.sh `run_reviewer`) verbatim,
including the real `review_diff_hint` from `lib/common.sh` — the reviewer runs
the identical noise-excluded diff command production gives it, and sees exactly
the authored patch. (The lean dispatch is the one mirrored; the phase-mode
review-phase.sh prompt differs slightly and has no fixture yet.)

## auditor cases (slice (c) — 4 cases)

| Case | Expected | The judgment it pins down |
|------|----------|---------------------------|
| case-01-clean-pass | PASS | A genuinely complete phase with honest artifacts must NOT collect invented gaps (no over-caution, no deflation to PASS_WITH_GAPS) |
| case-02-documented-gap-not-fail | PASS_WITH_GAPS | Honest, handoff-documented GAP-class limitations on a working feature must neither inflate to FAIL nor vanish into plain PASS |
| case-03-qa-green-spec-contradiction | FAIL | QA/review/handoff all green while the code visibly lacks the spec's server-side core (localStorage categories; `app.py` untouched) — "Do NOT pass a phase just because QA passed", and re-implementing the phase is not an audit fix |
| case-04-paid-service-live-key | FAIL | Spec'd local JSON backup delivered as a paid-SaaS sync with a hardcoded live-style key and an unconditional "Backed up ✓" badge — CRITICAL on three grounds, and every unblock path (rotate the key, approve the service, build the local endpoint) is human-owned or dev-scale |

All four are decision-tree-unambiguous under `agents/auditor/body.md` (severity
decision tree + verdict contract) — see each case's `notes.md`. Same fictional
QuickList app as the reviewer cases, but each case is a FULL-depth iteration, so
the tree carries the whole full-mode artifact set the auditor's dispatch prompt
cites: execution plan, dev handoff, review report, functional test plan, QA
report (with evidence screenshots the QA report cites), status.json. The two
FAIL cases model upstream-chain rot on purpose (a weak review that misgrades, a
vague test plan, a shallow QA) — the auditor is the last defense, and its
contract orders it to read the code, not inherit upstream verdicts. The auditor
CAN apply fixes during an audit, so both FAIL cases are built to be unfixable
in-audit: the missing spec core is dev-scale work, and the key/paid-service
decisions are human-owned (judgment-rubrics §3).

**How the auditor's repo state is represented.** Same scratch-git rebuild as the
reviewer (below): at audit time the iteration's work is still UNCOMMITTED
(run-phase.sh commits at finalize; goal mode at the push step after evaluation),
so the runner rewinds `tree/` by reverse-applying `source/change.patch`, commits
that baseline, and re-applies the patch uncommitted. The dispatch prompt is
phase-audit.sh's verbatim (goal-mode full depth routes through the same script
with PHASE = the iter name), and the builder enforces its preflight: the QA
report must exist and pass, else production would never dispatch the auditor.

The runner auto-discovers any `tests/judgment/<judge>/case-*` directory, and
refuses (before any spend) judges it has no dispatch builder for.

## How the fixtures were built (and how to change them)

Hand-authored artifacts live in `tree/` directly. Derived artifacts are produced
by the SAME production code the engine uses, via each judge's `tools/regen.sh`
(idempotent).

**reviewer** (`reviewer/tools/regen.sh`): the authored sources are
`tools/base/**` (the shared pre-iteration QuickList app, byte-identical across
cases by construction) and each case's `tree/**` (the post-iteration state).
Regen derives `source/change.patch` per case with `git diff HEAD` in a scratch
repo (base committed, tree overlaid) — the exact inverse of the runner's sandbox
build, so the round-trip is guaranteed — and then asserts the fixture
invariants: patch reverse-applies, post-state `python3 -m unittest` is green,
the handoff's Changed-files list matches the diff exactly, `expected.txt` is a
legal verdict class, case-03 (and only case-03) carries the credential, and
case-04's diff adds no server-side 400 path. To change a reviewer case: edit
`tools/base/**` and/or the case's `tree/**`, re-run
`bash reviewer/tools/regen.sh`, and commit the regenerated patch with it.

**auditor** (`auditor/tools/regen.sh`): same patch derivation as the reviewer
over the auditor's own frozen `tools/base/**` copy (kept independent so edits to
the reviewer fixtures can never silently rewrite auditor patches), plus the
auditor-specific invariants: status.json's `changed_files` matches the diff (the
dispatch prompt routes the auditor there), the QA report exists and PASSES
(phase-audit.sh's dispatch precondition), the full-mode artifact set exists per
case, `lv_live_` appears in case-04's patch and nowhere else, case-03's `app.py`
is byte-identical to base (the contradiction), case-02's handoff keeps its
Known-limitations section, and case-01 stays finding-free. Evidence PNGs come
from `auditor/tools/make_screenshots.py` (Pillow) — every screenshot a QA report
cites must exist, including the deliberately misleading states QA photographed
in the two FAIL cases. Same change procedure: edit sources, re-run
`bash auditor/tools/regen.sh`, commit regenerated artifacts together.

**goal-evaluator** (`goal-evaluator/tools/regen.sh`):

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

After editing any authored file, re-run that judge's `tools/regen.sh` and commit
the regenerated artifacts with it. Fixtures are FROZEN inputs — the runner copies
`tree/` into a throwaway sandbox, so a judge's writes never touch them.

## Adding a case

1. Copy the closest existing case directory; rename the sid (`fixtNN` /
   `rfxNN`) in paths and contents.
2. Make the expected class unmissable: design it so the judge's decision rule
   (evaluator methodology tree / reviewer severity rubric) has exactly one
   defensible answer, and write `notes.md` arguing why (cite the rule). If two
   classes are defensible, the case is bad — tighten the artifacts until one
   survives.
3. Keep every artifact consistent with the story (results table, screenshots,
   handoff, history, scan report, changed-files list vs the diff) — judges are
   entitled to cross-check.
4. Extend that judge's regen tooling (goal-evaluator: the POLICY table +
   `make_screenshots.py`; reviewer: the invariant gates), re-run regen, run the
   suite once with `--yes-spend` (G9: ask the user first) and confirm the
   configured judge lands the expected class.
