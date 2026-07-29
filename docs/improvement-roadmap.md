# Improvement Roadmap — canonical backlog (single source of truth)

**This file is the ONLY improvement backlog for this framework.** The README's former
"Token Optimization — Pending Work" and "Pipeline Hardening — Pending Work" sections were
absorbed here (see §17 ledger). If you find another TODO list, it is stale — merge it here.

Written 2026-07-06 by the last Fable-5 planning session, after a full exploration of the
codebase and a feasibility review of every P0 design. Line anchors reference commit
`02aefc8`. **Anchors are strong hints, not gospel** — if an anchor is off by more than
~30 lines, re-grep for the named function/pattern instead of trusting the number.

---

## 1. Purpose & audience

- **Audience:** future maintainer sessions — interactive Claude Code sessions on
  whatever models `config/model-tiers.yaml` names when you read this.
  Items are written so you do NOT need to re-derive context: each one carries its own
  problem statement, evidence anchors, change spec, definition of done, verification
  commands, and rollback.
- **Goal:** keep this framework improving — faster iterations, higher reliability, better
  capture of what the user actually wants, stronger security, leaner tokens, clearer
  reports and docs — even though the sessions doing the work are weaker than the one
  that wrote this file. The gates and evals carry the judgment load; your job is to
  execute one well-scoped item at a time and let the machinery check you.

## 2. How to use this file

1. Read §3 (ground rules) and §4 (item format) once per session. They are short.
2. Pick ONE item, normally the first `TODO` item in §5's recommended order. Do not pick
   two. Do not "also quickly fix" neighboring things.
3. Set its `Status:` to `IN-PROGRESS` (this edit is autonomous-class; no approval needed).
4. Read the item's anchors in the actual files before writing anything.
5. Implement exactly the change spec. If reality contradicts the spec (anchor gone,
   mechanism changed), STOP and ask the user — do not improvise a new design.
6. Run the item's **Verify** block. All commands must pass.
7. For Effort M/L items: verification must be done by a FRESH session (see §3). Leave the
   item `IN-PROGRESS` with a note; the fresh session flips it to `DONE`.
8. When `DONE`: move the item's body to `docs/improvement-roadmap.archive.md` (create it
   if absent) leaving one line in place: `### <ID> — DONE <date>, archived`. This keeps
   the active file lean (growth rule, §7 of EVO-1).
9. New improvement ideas (yours, the user's, or retro output from EVO-2) go into §16
   staging — never directly into a numbered section. The human promotes them (EVO-1).

## 3. Ground rules for executors (non-negotiable)

- **G1** Read `CLAUDE.md` and `.claude/maintenance-protocol.md` before any framework
  edit. Protocol beats momentum. File-class permissions in protocol §1 apply — e.g.
  `config/model-tiers.yaml` and gate defaults are ASK-THE-USER-FIRST class.
- **G2** Edit neutral source (`agents/ skills/ commands/ hooks/ policy/ config/`),
  NEVER the rendered `.claude/` mirrors. After any neutral-source edit:
  `python3 scripts/automation/sync-cli-assets.py --cli claude`, commit source AND
  mirrors together, and version-bump the touched `agent.yaml`.
- **G3** `./scripts/automation/run-evals.sh` must be green after every item, before
  commit. A new artifact contract (verdict line, table, JSON field, path) requires a
  new eval fixture in the SAME change — grep for every reader of the artifact first
  (writer→reader drift is the #1 documented bug class here).
- **G4** Experiments ship behind a default-off env knob (`CHAIN_*`) with a named
  tripwire metric. Never flip a default in the same change that introduces the knob.
- **G5** Never disable gates (`CHAIN_GOAL_GATES`, `CHAIN_GOAL_CONFIRM`,
  `CHAIN_MODEL_ESCALATION`, `CHAIN_DISABLE_MODEL_ROUTING`). If you must set an escape
  hatch to debug, re-enable it in the same session and say so in your report.
- **G6** One item per session. If an item won't fit, stop, split it in §16 staging with
  a note, and ask the user. Do not improvise scope cuts.
- **G7** Every MED/HIGH-risk item lists **Stop-and-ask** triggers. Hitting one means
  literally stop and ask the user. "I found a workaround" is not an exemption.
- **G8** Effort M/L items: final verification by a FRESH session — the implementer never
  self-certifies (non-self-verification, `.claude/model-orchestration.md`). Baseline
  before experiment: any SPEED/TOKEN experiment needs telemetry from at least one real
  session (or an EVO-3 benchmark run) before AND after. Pre-register before running:
  write the hypothesis + predicted metric movement into `benchmarks/experiments.md`
  (EVO-3's ledger) BEFORE the measurement run; the writeup compares result vs
  prediction — never rationalize after the fact.
- **G9** Anything that spends real API tokens beyond your own session (benchmark runs,
  test goal-sessions) → confirm with the user first, with a cost estimate.

**Explicit do-NOTs** (absorbed from README Tier-3 — these were considered and rejected;
do not resurrect them without new evidence):
- **D1** Do not downgrade `qa` below Haiku — it drives Chrome MCP browser flows; if
  browser checks regress, upgrade it to Sonnet, not down.
- **D2** Do not merge ui-impact-analyst + ui-test-designer + ux-regression-reviewer —
  each is an independent skeptical source the closure auditor depends on.
- **D3** Do not eliminate retries — they exist for quality. Only the audit-failure
  full-rerun cap (TOKEN-4) is sanctioned.
- **D4** Do not lower a judge's effort to save tokens — lower the context you feed it.
  The `JUDGE_AGENTS` guard in `scripts/automation/lib/agent_permissions.py` exists for
  this; do not remove it.
- **D5** Do not cap thinking/effort to cut cost — on ANY agent, not only judges (D4).
  Superpowers 6 measured the failure mode: capping thinking increased turn count and
  ~doubled output tokens (cost went UP, not down). Judges are hardcoded-refused
  (`JUDGE_AGENTS`, `scripts/automation/lib/agent_permissions.py:262-264`); for
  non-judges the `CHAIN_AGENT_EFFORT` knob stays opt-in and must carry a COST tripwire
  (REL-8) — the current quality-only tripwire (`lib/analyze_telemetry.py:441-466`)
  cannot see this failure mode.
- **D6** Do not impose word/length budgets on specs or plans. If a spec must shrink,
  cut implementation narrative — NEVER test scenarios or interface/data-contract
  definitions (Superpowers 6: a plan word-budget cut test content −62%; tests and
  interfaces are what carry implementation quality — see REL-9).
- **D7** Do not dispatch a reviewer with diff-only context. The iteration spec and dev
  handoff must accompany any diff packet (Superpowers 6: diff-only reviewers re-derived
  requirements and produced confident but WRONG spec verdicts). Applies to TOKEN-7 and
  any future review-packet work.

## 4. Item format legend

Every item carries: `ID` · `Priority` (P0/P1/P2) · `Effort` (S = part of a session,
M = one full session, L = must be executed slice-by-slice, one slice per session) ·
`Risk` (LOW/MED/HIGH) · `Status` (TODO / IN-PROGRESS / DONE / STALE / BLOCKED) ·
**Problem** · **Current state** (with file:line anchors) · **Change spec** ·
**DoD** (definition of done) · **Verify** (commands) · **Files** · **Rollback** ·
**Stop-and-ask** (mandatory on MED/HIGH risk) · **Trigger** (experiments only: the
signal that says "do this now").

## 5. Recommended execution order (dependency-aware)

1. **SAFE-1, SAFE-2, DOC-1, DOC-2** — cheap protection and drift fixes first.
2. **REL-1** (judgment fixtures) — protects every later change against judge regressions.
3. **NEED-1 → NEED-2** (intake), **NEED-3 → NEED-4** (linter), **NEED-5 → NEED-6**
   (assumption ledger; 6 requires 5), **NEED-9**, **NEED-7** (checkpoint; better with 5
   but works without), **NEED-8**.
4. **EVO-2** (retro), **EVO-3** (benchmark; required before any SPEED/TOKEN experiment),
   **EVO-4** (playbook), **EVO-5**. (EVO-1 ships with this file.)
5. **SPEED-1 → SPEED-2 → SPEED-3** (strict order), **TOKEN-1…8** (TOKEN-2 requires
   EVO-3 + REL-1 to exist; TOKEN-7 is independent of the SPEED chain; TOKEN-8 staged
   2026-07-14 — small, unblocks full-depth per-agent economics).
6. **REL-2…12, SEC-1…4, QUAL-1, REP-1…3, DOC-3…7** — as capacity allows; SEC-4 pairs
   with SAFE-1; REL-8 must land before any real `CHAIN_AGENT_EFFORT` use; REL-9 is
   cheap — do it early; REL-10/REL-11 were user-promoted 2026-07-11 (one bundled
   session) and verify together via the §9 benchmark rerun; REL-12 staged 2026-07-14
   (prereq for a resolvable SPEED flip re-measurement at lean depth).
7. **EXP-** items only with explicit human sign-off and a written design doc first.
8. **SPEED-4…7** shipped 2026-07-17 (one user-approved package session; plan
   sign-off = EVO-1 promotion + G6 multi-S exception). **SPEED-8** waits for SPEED-4
   to bed in one real session; **REL-14** (absorbs CAND-BQA-PREFLIGHT) schedules
   with the REL block — both are weaker-model-ready mini-specs.
9. **CTX-1…14** — context engineering (§18, promoted 2026-07-25 as a user-approved
   package): S items CTX-1/2/4/5/6/8/13 first, then CTX-3 and CTX-12; CTX-7 requires
   its judgment spot-run; CTX-9/10/11/14 as capacity allows. CTX-15 staged as
   CAND-RICHREF in §16.
10. **PLAIN-1** — plain-language output (§19, promoted 2026-07-26 by direct user
    request; absorbs DOC-5). Shipped 2026-07-26 in one bundled session; judgment
    spot-run green; certified DONE per G8 same day.
11. **SPEED-9…19 + REP-4 + TOKEN-9** — the iteration-speed package (promoted
    2026-07-28 by direct user request after the tapeology desk-session diagnosis;
    EVO-1 promotion + G6 multi-item exception, all three judge cuts and the
    ask-first flips explicitly approved). Implemented 2026-07-28 in one bundled
    session; judgment spot-run GREEN 2026-07-29 — 14/14 verdict classes
    (auditor 4/4 incl. case-03 contradiction-still-FAILs, goal-evaluator 6/6
    incl. case-04 drift-beats-durability and case-06 make-up-boolean
    distinction, reviewer 4/4 with the SPEED-18 key removals). Still owed
    before any item flips to DONE: G8 fresh-session certification and one real
    session's before/after telemetry (PRE speed-package-20260728 in
    benchmarks/experiments.md). SPEED-15 slice (b) (trim-mode browser
    narrowing) stays TODO until a warn-mode session exists.
    *G8 fresh-session certification 2026-07-29 (non-implementer): steps 1-5
    verified green; items remain IN-PROGRESS pending the real-session
    telemetry (PRE speed-package-20260728).*
12. **SPEED-20…24 + TOKEN-10 + REP-5** — the iteration-shape package (promoted
    2026-07-29 by direct user request: tapeology still spent 2h+ per iteration
    from iter-14 on AFTER the speed package; telemetry attributed the floor to
    the pipeline's SHAPE — the depth governor routed around via self-certified
    `Full trigger:` lines, no enforced ceiling, and recurring taxes). Root-cause
    killers: SPEED-20 deterministic depth arbiter (evaluator recommendation
    binding) + SPEED-15 completion (budget armed 3600s/trim — both
    gate-default changes sanctioned by the user task, incl. the TOKEN-3 flip);
    plus TOKEN-10 executor goal slices, SPEED-21/22/23 golden-first regression,
    SPEED-24 combined UI dispatch, REP-5 confirm attribution. Grades the PRE
    speed-package-20260728 entry as POST (full-ratio arm FAILED — 5/6, the
    governor bypass; productive-time arm PASSED −37%) and registers PRE
    `iteration-shape-20260729`. Judgment spot-run GREEN 2026-07-29 (the
    DEFERRED-BUDGET evaluator-contract wording touches evaluator inputs):
    goal-evaluator 6/6 verdict classes on claude-opus-5 @ max, incl. case-01
    GOAL_ACHIEVED and case-06 pending-infra CONTINUE. Adversarially reviewed
    same session (6-lens workflow, 34 raw → 11 confirmed findings, all fixed —
    incl. a canary-dispatch unbound goal-line crash now pinned end-to-end by
    test-goal-parallel-bqa scenario L). G8 fresh-session certification + the
    next real session's telemetry still owed before any item flips to DONE.
    *G8 fresh-session certification 2026-07-29 (non-implementer): steps 1-5
    verified green (run-evals 147/0; self-tests goal-gates OK incl. the REP-5
    confirm-attribution case, goal_gate.py OK incl. the DEFERRED-BUDGET block,
    demo_runner 22/0, merge_ui_test_results 8/0; suites depth-arbiter 33,
    depth-cadence 23, iter-budget 33, replay-lane 59, replay-lane-full 24,
    goal-parallel-bqa 103 incl. scenario L, goal-context-slice 26,
    golden-autoderive 22, testplan-skip 30, ui-combined 18 — all 0 FAIL;
    defaults 3600/trim + CHAIN_SKIP_TESTPLAN_IF_PRESENT/CHAIN_DEPTH_ARBITER
    default-true with the legacy allowlist intact; the five trim consult sites
    shed only showcase/replay-breadth/test-plan/ux-regression — never the
    spine; DEFERRED-BUDGET spelling identical in all five sources + mirrors;
    4a1ce4f leaves the evaluator dispatch prompt and run-judgment-evals.sh
    untouched; rung-3 traced end-to-end — iter-N/budget-breached written after
    the verdict gate, read by iter-N+1 under PRIOR_VERDICT=CONTINUE, SPEED-4
    re-promotion suppressed). Items remain IN-PROGRESS pending the real-session
    telemetry (PRE iteration-shape-20260729).*

---

## 6. P0 — User-need capture

The chain's biggest structural gap: every agent is instructed "do not ask questions",
`docs/goal.md` is treated as fixed ground truth, and nothing checks that the authored
journeys actually capture what the user wants. These items add capture, linting,
assumption transparency, and a mid-session human checkpoint — without breaking the
hands-off engine (all human interaction happens either before the engine starts or at
resumable pauses).

### NEED-1 — DONE 2026-07-07, archived

### NEED-2 — DONE 2026-07-07, archived

### NEED-3 — DONE 2026-07-07, archived

### NEED-4 — DONE 2026-07-07, archived

### NEED-5 — DONE 2026-07-07, archived

### NEED-6 — DONE 2026-07-07, archived

### NEED-7 — DONE 2026-07-08, archived

### NEED-8 — DONE 2026-07-08, archived

### NEED-9 — DONE 2026-07-07, archived

---

## 7. P0 — Evolution engine

What keeps improvement going after this initial backlog: where new items come from, how
the system measures itself, and how it survives the next model change.

### EVO-1 · Roadmap maintenance protocol  (SHIPS WITH THIS FILE — read, don't build)
- **Priority:** P0 · **Effort:** — · **Risk:** — · **Status:** DONE (this section is it)
- **Sources of new items** (in trust order):
  1. §16 staging entries written by EVO-2 retros (automated, per terminal session halt).
  2. The human's direct asks.
  3. Telemetry anomalies (a step's wall/token cost trending up across sessions).
  4. Session halts and their causes (`REGRESSION_HALT`, `ABORT_MALFORMED`, repeated
     `ESCALATE`).
  5. Recurring `lessons.md` / `evaluator-log.md` pain across projects (EVO-5).
  6. Model/CLI releases (run EVO-4's playbook; new capabilities may unblock EXP items).
- **Promotion rule:** only the HUMAN moves an item from §16 staging into a numbered
  section (assigning ID, priority, effort). Sessions may draft the full mini-spec in
  staging to make promotion easy.
- **ID allocation:** next free number in the cluster; never reuse a retired ID.
- **Growth control:** when an item is DONE, archive its body to
  `docs/improvement-roadmap.archive.md` (leave a one-line stub). When §16 staging
  exceeds ~15 entries, ask the human for a triage session.
- **Stop rule** (absorbed from README): if a 30-iteration goal session costs less than
  the user's stated budget and a phase costs less than their per-phase number, stop
  optimizing tokens/speed — invest in features instead. Ask the user for their numbers
  once and record them here: _(unset — ask when first relevant)_.
- **Review cadence:** at the start of any framework-work session, skim §5 and §16;
  if >8 weeks since the last edit of this file (`git log -1 --format=%cs -- docs/improvement-roadmap.md`),
  tell the user it may be stale.

### EVO-2 · Automatic post-session retrospective
- **Priority:** P0 · **Effort:** L (2 slices) · **Risk:** MED · **Status:** DONE
  *(slice (a) — deterministic collector + terminal-halt wiring — implemented 2026-07-10:
  `scripts/automation/lib/retro_collect.sh` (new) writes `state/retro-input.md` with the
  stable sections Outcome / Verdict sequence / Agent economics / Friction counters /
  Lessons tail / Halt context; sourceless counters are the literal `unknown (<why>)`.
  Wired into `write_session_summary` (`run-goal.sh:1263-1273` after slice (b)'s edits)
  behind `CHAIN_SESSION_RETRO` (default `true`; documented in
  `.claude/model-orchestration.md` knob table), firing on
  GOAL_ACHIEVED/STALLED/REGRESSION_HALT/BUDGET_EXHAUSTED only, non-blocking.
  Slice (a) certified 2026-07-10 by a non-implementer session per G8: 23/23 asserts +
  full evals green, wiring claims re-verified against code, digest judged sufficient
  as the drafting agent's sole input — no collector amendments needed.
  Slice (b) — drafting agent — implemented 2026-07-10 by that certifying session: new
  `agents/retro-analyst/` (model_tier light, tools [Read, Write]) reads ONLY the digest
  and writes `reports/goal-session-<sid>-retro.md` — ≤5 candidate items in this file's
  §4 shape, each citing its exact digest line, PROPOSALS-ONLY banner, zero items a
  valid output, report ≤120 lines. Dispatched by `_run_retro_analyst`
  (`run-goal.sh:329`, the summarizer wrapper pattern) from inside write_session_summary
  immediately after the collector — same knob + same terminal filter + digest-exists
  guard, non-blocking (a failed dispatch prints one warning, changes no exit code).
  No `templates/retro.md` was needed — body.md carries the report skeleton (the Files
  line below listed it as an either/or with the agent). Tests:
  `tests/automation/test-goal-retro.sh` now 32 asserts (the stub plays the drafting
  model: both-files DoD on STALLED, neither file on AWAITING_PUMP/knob-off, broken
  collector → no orphan dispatch, failed dispatch → exit codes unchanged + one
  warning), still registered in `run-evals.sh` §2c.
  ABORT_MALFORMED call-site audit (slice (b) optional step): NOT changed. Every
  session.json status consumer falls through safely on an unknown status EXCEPT
  `run-goal.sh:1176` (`AWAITING_PUMP|ABORTED) _join_showcase_tail --kill`), which
  special-cases "ABORTED" — passing ABORT_MALFORMED would flip that halt from
  reap-immediately to bounded-join, so per the audit gate the call site
  (`run-goal.sh:2245-2251`) still passes "ABORTED" and malformed-x2 halts still get NO
  retro. A future slice shipping the rename must extend that case list plus the three
  status-enum docs (`.claude/workflow.md:305`, `skills/goal-interactive-dispatch.md:147`,
  `docs/goal-mode-telemetry.md:37/:115` — the last already omits ABORT_MALFORMED as an
  emitted halt reason today, pre-existing drift, not introduced here).
  Slice (b) certified DONE 2026-07-10 by a fresh non-implementer session per G8:
  32/32 retro asserts + 93/93 evals green; agent contract (light tier, tools exactly
  [Read, Write], digest-only input, ≤5 §4-shape items with verbatim evidence quotes,
  PROPOSALS-ONLY banner, zero-items valid, ≤120 lines, never edits the roadmap),
  wiring guards, the `run-goal.sh:1176` ABORTED special-case, and all three catalog
  surfaces (CLAUDE.md list, agents.md count 20, README row) re-verified against code;
  `sync-cli-assets --check` clean; plus one user-approved (G9) real light-tier smoke
  dispatch (claude-haiku-4-5) against a collector-built synthetic digest — well-formed
  4-item report, verbatim evidence quotes, product-only lesson correctly skipped, no
  stray writes. EVO-2 complete; body archiving left to a future tidy pass (REL-1
  precedent).)*
- **Problem:** every session generates evidence about what hurt (halts, quota pauses,
  review-FAIL loops, wall-time spikes, lessons) — and none of it flows back into
  framework improvements. The feedback loop is the evolution engine's core.
- **Current state:** terminal halts are decided in the verdict/halt switch
  (`run-goal.sh:2066-2210`), but EVERY halt — terminal and resumable — funnels through
  `write_session_summary()` (`run-goal.sh:1123`), the single choke point slice (a) wired
  (AWAITING_* pauses and the GOAL_ACHIEVED+proposer-extended `continue` never reach a
  terminal summary); the showcase tail is the proven non-blocking pattern (forked for
  CONTINUE `run-goal.sh:2063`, inline for halts `:1900`); wall/token aggregation exists
  (`lib/analyze_telemetry.py`, `build_wall_report` `:273`, `--json` output supported);
  lessons tail inlining exists (`run-goal.sh:1469`); verdict-per-iteration telemetry:
  `iter_end` `:1945`, `deterministic_gate` rewrites `:1883`, `review_verdict`
  (`goal-iter-lean.sh:210`).
- **Change spec:**
  1. **Slice (a) — deterministic collector + wiring.** New
     `scripts/automation/lib/retro_collect.sh` (or `.py`): writes
     `runs/goal-session-<sid>/state/retro-input.md` — halt reason + final verdict,
     verdict sequence across iterations, per-agent wall/token stats
     (`analyze_telemetry.py --json`), quota-pause count, attempt-1 review-FAIL count,
     malformed-verdict count, lessons tail. Wire into the TERMINAL halt paths only
     (GOAL_ACHIEVED / STALLED / REGRESSION_HALT / BUDGET_EXHAUSTED / ABORT_MALFORMED —
     NOT resumable AWAITING_* pauses), non-blocking (`|| true`), behind
     `CHAIN_SESSION_RETRO` (default `true`, escape hatch documented). Sandbox test
     asserting it runs on STALLED and not on AWAITING_PUMP.
  2. **Slice (b) — drafting agent.** Light-tier dispatch (reuse the
     `_run_iteration_summarizer` wrapper pattern, `run-goal.sh:251`) reading ONLY
     `retro-input.md`, writing `reports/goal-session-<sid>-retro.md`: 1-5 candidate
     framework-improvement items in this file's §4 item format, each citing its
     evidence line from retro-input. PROPOSALS ONLY — the agent never edits this
     roadmap; the human copies candidates into §16. Neutral source: either a new
     `agents/retro-analyst/` (agent.yaml `model_tier: light`) or a prompt template —
     prefer the agent for consistency with the catalog. Non-blocking; failure never
     blocks the halt.
- **DoD:** terminal halt in a sandbox session produces both files; AWAITING_* pauses
  produce neither; engine exit code unchanged when retro fails; evals green.
- **Verify:** slice tests + `bash -n scripts/automation/run-goal.sh &&
  ./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/lib/retro_collect.sh` (new),
  `scripts/automation/run-goal.sh`, `agents/retro-analyst/` (new, slice b),
  `templates/retro.md` (new, slice b), mirrors, test.
- **Rollback:** `CHAIN_SESSION_RETRO=false`; or remove the halt-path calls (isolated).
- **Stop-and-ask:** if adding the retro-analyst agent requires touching the agent
  catalog count in CLAUDE.md ("19 agents"), flag it — CLAUDE.md is ask-first class.

### EVO-3 · Automated benchmark harness
- **Priority:** P0 · **Effort:** L (3 slices) · **Risk:** MED · **Status:** DONE
  *(slice (a) — fixture project — implemented 2026-07-10:
  `benchmarks/fixtures/todo-app/` is a runnable but deliberately BARE Flask +
  vanilla-JS + pytest scaffold — shell page + `/health` on fixed port 5177, storage
  = one runtime-created `todos.json`, journeys deliberately UNIMPLEMENTED (the
  benchmark measures the chain BUILDING them, not verifying pre-built ones).
  `docs/goal.md` carries J-01 add / J-02 toggle+persist / J-03 filter with numbered
  steps + browser-observable Acceptance lines and 2 checkable anti-goals —
  goal_lint exit 0 (clean, not just <2) and validate_goal_file-compatible. Nested
  `.claude/project-template.md` truthfully filled for THIS app (fixture content,
  never a sync-cli-assets target — judgment-fixture nesting precedent); scaffold
  tests green (3/3: import, GET / 200 + runtime store creation, /health 200) via a
  gitignored `.venv/` (system python 3.14 ships no flask/pytest); README documents
  the slice-(b) consumption contract (copy → scratch dir → git init →
  `run-goal.sh --session-id bench-<date> --max-iter 2`) and hand-verification.
  Authored independently of tests/judgment/** — zero shared files, so the two eval
  assets cannot drift into coupling. No runner, no `benchmarks/results/`, no
  engine runs (every benchmark run is G9 ask-first spend). Slices (b) runner +
  (c) compare/baseline remain; slice (a) certification per G8 folds into the
  slice-(b) session.)*
  *(slice (b) — runner + pre-registration ledger — implemented 2026-07-10, same
  session as the G8 fresh-eyes certification of slice (a) (certified: fixture
  tests 3/3 green, app boots on 5177 with `/` and `/health` → 200, goal_lint
  exit 0, journeys confirmed browser-observable and genuinely unimplemented in
  the scaffold — no todo logic in `app.py`/`app.js` — and `run-evals.sh` green;
  certifier was not slice (a)'s implementer. One recorded nit, no edit: the
  fixture project-template's "commits directly to main" line vs the engine's
  default `goal/<sid>` push branch — fixture prose, no behavioral effect).
  `scripts/automation/run-benchmark.sh`: always prints plan + cost estimate,
  then REFUSES without `--yes-spend` (G9), without `--hypothesis` (G8), and on
  a dirty framework tree unless `--allow-dirty` (recorded as
  `framework_dirty:true` + diffstat) — every refusal BEFORE any side effect.
  Run sequence: PRE entry appended to `benchmarks/experiments.md` (append-only
  ledger, created this slice) BEFORE the engine launches → scratch repo =
  subrepo set (`.claude/ scripts/ config/ templates/ CLAUDE.md` [+`.mcp.json`])
  + fixture overlay (fixture files win collisions, so its project-template
  replaces the framework placeholder; `.venv`/`__pycache__`/`.pytest_cache`/
  `todos.json` excluded) + fresh git repo (main, deterministic goal-chain
  author) with a LOCAL BARE origin, so the engine's ls-remote preflight and
  push-per-iter exercise their real code paths with zero network → engine
  `run-goal.sh --session-id bench-<UTCdate-hhmm> --max-iter 2` headless
  (nonzero/paused engine = recorded RESULT, not a runner crash) → results JSON
  `benchmarks/results/<UTCts>-<sha12>.json` (meta: every CHAIN_* env var at
  launch + model-tiers sha256; outcome: journeys passing/total from
  journey-history, attempt-1 review FAILs + malformed verdicts counted with
  `retro_collect.sh`'s exact telemetry semantics, wall seconds; economics:
  `analyze_telemetry.py --json` embedded verbatim; missing sources = literal
  `unknown (<why>)`), validated for required keys before success → POST entry
  with headline + per-predicate evaluations. `--predict` comparisons over
  top-level result keys make verdict-vs-prediction mechanical (all true
  CONFIRMED / all false REFUTED / else MIXED); without predicates the POST line
  is the literal MANUAL instruction — the runner never self-grades free text.
  Engine command injectable via `CHAIN_BENCH_ENGINE_CMD` — a documented TEST
  SEAM strictly DOWNSTREAM of the spend gates (G5) and recorded in `chain_env`,
  so a stubbed run is visibly stubbed. 40 offline assertions in
  `tests/automation/test-benchmark-runner.sh` (registered in run-evals §2c,
  ~0.9s, suite 95/95): refusals-before-side-effects, scratch layout + canary
  exclusions, results schema/counts vs a stub engine's known artifacts,
  PRE-precedes-engine asserted BY the stub, all four verdict paths,
  keep/cleanup rules. ZERO engine runs this session (G6/G9). Slice (c) —
  `benchmark_compare.py` + docs + the first REAL baseline run (G9
  user-approved spend) — remains; slice (b) certification per G8 folds into
  the slice-(c) session.)*
  *(slice (b) certified 2026-07-10 by a fresh non-implementer session per G8
  (the slice-(c) session): 40/40 runner asserts + full evals green; gate order
  re-verified against code — both refusals + the dirty-tree check fire before
  ANY side effect (first write is the PRE append, `run-benchmark.sh:183`), PRE
  strictly precedes engine launch, and the `CHAIN_BENCH_ENGINE_CMD` seam is
  consulted only downstream of every gate with its value recorded in
  `chain_env`; live refusal probes on the real repo (no flags and
  --hypothesis-only → exit 2, plan printed, ledger byte-identical, no results
  dir) plus a dirty-tree refusal re-proven on a clone; ZERO-SPEND dry assembly
  (`CHAIN_BENCH_ENGINE_CMD='true'`) run inside a discarded git clone so the
  probe's PRE/POST entries landed in the clone's ledger — the real append-only
  ledger kept zero probe trace, nothing was ever deleted from it. Assembled
  scratch verified: subrepo set + fixture overlay (fixture project-template won
  the collision; `.venv`/`todos.json`/`benchmarks` excluded; 1 commit on main,
  deterministic author, local bare origin ls-remote-reachable), then proven
  AGENT-RUNNABLE exactly as the chain finds it — venv bootstrap per the fixture
  project-template, pytest 3/3, app boot with `/health` 200 on port 5177,
  goal_lint exit 0 inside scratch. No runner defects found; no edits needed.)*
  *(slice (c) — compare tool + FIRST REAL BASELINE — implemented 2026-07-10 by
  that same certifying session: `scripts/automation/lib/benchmark_compare.py`
  (delta table over wall / est. cost / tokens in+out / journeys passing /
  attempt-1 review FAILs / malformed verdicts / final status+verdict; REGRESS
  if wall or cost +>25% or journeys-passing dropped; any of those three verdict
  inputs missing or literal "unknown (...)" → INCOMPARABLE → verdict UNKNOWN,
  never a guessed number — regress-worthy comparable signals survive as a note;
  exit 0 OK / 3 REGRESS / 4 UNKNOWN / 2 usage; `--self-test` registered in
  run-evals §2, suite 96/96).
  Baseline attempt 1 (bench-20260710-2110 @ b172cea005aa) ABORTED in 2s with
  zero agent spend: slice (b) exported the invalid `CHAIN_AGENT_BACKEND=headless`
  (quota-retry accepts interactive|claude|codex; headless dispatch = `claude`) —
  a defect the offline suite structurally cannot catch (stub engines echo the
  env var unvalidated; only a real engine validates it). Runner+test fixed
  (commit c48f250); aborted attempt kept as a record: results JSON committed,
  ledger PRE/POST retained with an appended dated correction line (append-only).
  Attempt 2 = THE RECORDED BASELINE (fresh G9 approval, fresh PRE entry):
  bench-20260710-2117 @ c48f25047126 · hypothesis "chain reaches GOAL_ACHIEVED
  with 3/3 journeys within --max-iter 2 on the todo-app fixture" →
  **verdict-vs-prediction: REFUTED** (mechanical; both predicates false) ·
  final_status=BUDGET_EXHAUSTED · last_verdict=CONTINUE · journeys 0/3 (all
  honestly `unknown` — zero browser evidence) · iterations 2 (verify-only
  baseline + one full-depth build) · wall 5095s (~85 min) · est. cost $10.89
  (106.5k in / 153.6k out tokens, 12 invocations; goal-evaluator $4.16 +
  goal-decomposer $2.46 dominate) · results
  `benchmarks/results/20260710-224206-c48f25047126.json`. GENUINE CHAIN
  RESULT, not infra (environment healthy; friction counters zero): the chain
  built all three journeys to reviewer-PASS / COHERENCE-PASS / 15-of-15-pytest
  quality, but its browser-QA lane produced ZERO evidence in both iterations —
  (a) the generic `scripts/start-backend.sh` template in the subrepo set
  (uvicorn, apps/backend layout) shadowed the fixture project-template's
  `.venv/bin/python app.py`, so nothing served on 5177 (README Known
  Limitation 1 made concrete); (b) a headless write-permission prompt blocked
  the QA report and the retro-analyst report from persisting. Both are
  framework gaps the baseline exists to expose — prime §16-promotion
  candidates; fixing them should move journeys 0→3 in the next compare.
  Compare sanity: baseline-vs-baseline → all deltas 0, verdict OK, exit 0.
  Standing usage rule: §9 "When to benchmark". EVO-3 complete; body archiving
  left to a future tidy pass (REL-1 precedent).)*
  maintainer can trust. The per-session tripwire compares within a session; nothing
  compares across framework versions.
- **Current state:** no `benchmarks/` dir. Headless engine is scriptable
  (`run-goal.sh --session-id X --max-iter N`); telemetry JSON aggregation exists
  (`analyze_telemetry.py`); `runs/` ships empty so any committed fixture results are
  new territory.
- **Change spec:**
  1. **Slice (a) — fixture project.** `benchmarks/fixtures/todo-app/`: minimal runnable
     scaffold (smallest stack the chain supports well — e.g. a single-page Express or
     Flask app), a filled `.claude/project-template.md`, and a `docs/goal.md` with 2-3
     small journeys + 2 anti-goals. Small enough that 2 lean iterations can plausibly
     reach all-passing.
  2. **Slice (b) — runner + metrics.** `scripts/automation/run-benchmark.sh`: copies
     the fixture to a scratch dir, `git init`, runs
     `run-goal.sh --session-id bench-<date> --max-iter 2` headless; on exit extracts
     `benchmarks/results/<date>-<framework-sha>.json`: wall seconds, per-agent wall,
     tokens in/out, est. cost, journeys passing after, iterations used, attempt-1
     review-FAILs, final verdict. Refuses to run without `--yes-spend` (G9). Also
     refuses to run without `--hypothesis '<one-line prediction>'`: before launching,
     append a pre-registration entry to `benchmarks/experiments.md` (append-only
     ledger: date · framework sha · hypothesis · metric(s) · predicted direction/size);
     after the run, append result + `verdict-vs-prediction: CONFIRMED|REFUTED|MIXED`
     to the same entry. Prediction BEFORE execution is the point (G8) — it catches
     measurement errors and post-hoc rationalization (Superpowers 6 ran 25+
     pre-registered experiments this way and credits it for catching bad measurements).
  3. **Slice (c) — compare + baseline.** `scripts/automation/lib/benchmark_compare.py
     <old.json> <new.json>`: delta table + verdict (REGRESS if wall or cost +>25% or
     journeys-passing dropped; else OK). Docs section in this file + capture the first
     baseline (one confirmed run).
- **DoD:** one full benchmark run completes on the fixture; results JSON validates;
  compare tool renders deltas; docs tell a weaker model exactly when to run it (before
  AND after any SPEED/TOKEN experiment, and during EVO-4 cutovers); runner refuses
  without a hypothesis; every recorded run has a ledger entry whose prediction
  precedes its result.
- **Verify:** `bash -n scripts/automation/run-benchmark.sh && python3
  scripts/automation/lib/benchmark_compare.py --self-test &&
  ./scripts/automation/run-evals.sh` + one confirmed real run.
- **Files:** `benchmarks/fixtures/todo-app/**` (new),
  `scripts/automation/run-benchmark.sh` (new),
  `scripts/automation/lib/benchmark_compare.py` (new),
  `benchmarks/experiments.md` (new, slice b), this file (baseline note).
- **Rollback:** the harness is standalone; delete `benchmarks/` + the two scripts.
- **Stop-and-ask:** EVERY benchmark run costs real API tokens (~the cost of up to 2 lean
  iterations on a tiny app). Confirm with the user before each run — no exceptions.
  NEVER wire this into CI.

### EVO-4 · Model-cutover playbook
- **Priority:** P0 · **Effort:** S · **Risk:** LOW · **Status:** DONE
  *(implemented 2026-07-11: `docs/model-cutover-playbook.md` — all 9 steps as exact
  command(s) · expected evidence · failure/abort path, every command verified against
  the scripts' own headers; three unmissable user checkpoints (step 2 tier-change
  approval, step 6 judgment-fixture G9 gate, step 7 per-run benchmark G9 gate) with a
  spend-class label on every step (step 1 preflight = cents but still tell the user;
  step 6 = the runner's printed estimate; step 7 ≈ $11 + ~1.5h wall per run at baseline
  scale); rollback section mirrors steps 2-6 around a single-commit revert; cross-links
  landed both ways — one line in the letter's deployment section and one in
  maintenance-protocol §6, playbook links out to §9 "When to benchmark",
  run-judgment-evals.sh and REL-1's fixtures. Verify grep hits all three files; evals
  96/96. S item — implementer flips DONE (G8 fresh-session certification is M/L-only);
  body archiving left to a future tidy pass (REL-1 precedent).)*
- **Problem:** the Fable→Opus/Sonnet cutover was done once, by a strong model, with the
  procedure living in its head and partially in the letter. The next cutover will be
  done by a weaker model.
- **Current state:** pieces exist in `.claude/letter-to-future-sessions.md` ("The model
  table rots") and `.claude/maintenance-protocol.md` §6. No single runnable checklist.
- **Change spec:** new `docs/model-cutover-playbook.md`, a strict ordered checklist:
  1. Preflight every candidate id: `claude -p --model <id> 'reply OK'`.
  2. Get explicit user approval (model spend = ask-first class), then flip
     `config/model-tiers.yaml` — the ONE source; never per-agent `model_override`.
  3. Resync mirrors + `sync-cli-assets.py --cli claude --check`.
  4. Update the table in `.claude/model-orchestration.md` in the SAME commit.
  5. `./scripts/automation/run-evals.sh` green.
  6. Run REL-1 judgment fixtures: `./scripts/automation/run-judgment-evals.sh
     --yes-spend` (G9: user-approved spend; the runner prints the estimate and
     refuses without the flag).
  7. Run the EVO-3 benchmark before AND after the flip (§9 "When to benchmark"):
     `./scripts/automation/run-benchmark.sh --hypothesis '<prediction>'
     [--predict '<key OP value>']... --yes-spend` on the pre-cutover sha, again
     on the post-cutover sha, then `python3
     scripts/automation/lib/benchmark_compare.py benchmarks/results/<pre>.json
     benchmarks/results/<post>.json` — REGRESS (exit 3) → do not proceed with
     the cutover without a human decision.
  8. First-session watchlist: `gate-report.md` appears on any GOAL_ACHIEVED;
     `[escalation]` lines in the engine log; per-model rows in
     `analyze_telemetry.py <session>/telemetry.jsonl`.
  9. Append a dated note to the letter's deployment section.
  Cross-link from the letter and from `.claude/maintenance-protocol.md` §6.
- **DoD:** playbook exists with all 9 steps; letter + protocol link to it.
- **Verify:** `grep -n "model-cutover-playbook" .claude/letter-to-future-sessions.md
  .claude/maintenance-protocol.md docs/model-cutover-playbook.md`
- **Files:** `docs/model-cutover-playbook.md` (new),
  `.claude/letter-to-future-sessions.md` (1 line), `.claude/maintenance-protocol.md`
  (1 line).
- **Rollback:** docs-only.

### EVO-5 · Cross-project lesson harvesting
- **Priority:** P0 · **Effort:** M · **Risk:** LOW · **Status:** DONE —
  implemented 2026-07-12; certified DONE 2026-07-12 by a fresh non-implementer
  session per G8: skeptical read + mechanical redirect audit confirmed read-only
  (stdout/stderr only, zero write-capable commands) and judgment-free; contracted
  degraded paths re-exercised on a synthetic fixture (malformed / non-dict /
  missing session.json, nonexistent repo arg → labeled `unknown (<why>)` / empty
  sections, rc 0); dry run on this repo → clean labeled-empty digest, rc 0;
  adopter re-run over ~/Git/tapeology + ~/Git/trendora → rc 0 and the digest
  reproduces the §16 CAND evidence (verbatim audit-dispatch and BQA-preflight
  quotes in the lessons tails); procedure documented in-entry and all three
  harvest-sourced CANDs cite dated provenance; run-evals 97/97 green.
  *(Implementation note 2026-07-12: `scripts/automation/harvest-lessons.sh` ships the
  spec's digest — per-repo grouped sections for (1) session.json halt lines
  (status · last_verdict · current_iter, literal values; missing/unreadable → the
  house `unknown (<why>)`), (2) lessons.md tails (last 20 lines each), and (3) one
  post-spec, in-spirit EVO-2-era extension: a `reports/goal-session-*-retro.md`
  paths section, so retro proposals surface in the digest alongside the lessons
  they grew from. Read-only (stdout only), judgment-free, exit 0 on every content
  condition (usage error = exit 2); covered by run-evals.sh §1's
  scripts/automation/*.sh syntax glob (96 → 97 checks). DoD dry run on this repo:
  clean labeled-empty digest. Degraded paths (absent runs/, missing + unreadable
  session.json, nonexistent repo arg, multi-repo invocation) hand-verified against
  a synthetic fixture the same day. First real harvest run the same day over
  ~/Git/tapeology + ~/Git/trendora; recurring symptoms drafted as §16
  CAND-AUDIT-DISPATCH / CAND-BQA-PREFLIGHT / CAND-VENDORED-SCAN-SCOPE.)*
- **Problem:** each adopting repo accumulates `lessons.md` / `evaluator-log.md` pain the
  framework repo never learns from; anti-patterns.md only grows when someone remembers.
- **Current state:** maintenance protocol §2 defines the lesson formats and where
  framework lessons go (numbered anti-patterns entries: symptom → root cause →
  checkable rule). No harvesting procedure or tooling.
- **Change spec:**
  1. New `scripts/automation/harvest-lessons.sh <repo-path>...`: for each repo, print
     the tails of `runs/goal-session-*/state/lessons.md` and halt lines from
     `session.json`s, grouped per repo — a digest for a human+session to review
     (read-only; makes no judgments).
  2. Procedure (documented in this file, here): quarterly or after each delivered
     project, run the harvester over known adopting repos; for each recurring symptom,
     draft either an anti-patterns entry (protocol §2 format) or a §16 staging item.
- **Procedure (operational — EVO-1 source 5):** quarterly, or after each delivered
  project, run `./scripts/automation/harvest-lessons.sh <repo>...` over the known
  adopter repos and review the digest with the user. Known adopters (2026-07-12):
  `~/Git/tapeology`, `~/Git/trendora` — extend this list as projects deliver. For
  each symptom recurring across sessions or repos, the reviewing session DRAFTS
  either a numbered `.claude/anti-patterns.md` entry (protocol §2: symptom → root
  cause → checkable rule) or a §16 staging item carrying the digest's evidence
  quotes; the human promotes (EVO-1). Adopters run VENDORED framework snapshots —
  before promoting any harvested symptom, verify it still exists at framework HEAD.
  The harvester stays judgment-free: interpretation happens in the review, never in
  the script.
- **DoD:** script handles missing dirs gracefully; procedure documented; one dry run on
  this repo (no sessions → clean empty output).
- **Verify:** `bash -n scripts/automation/harvest-lessons.sh &&
  ./scripts/automation/harvest-lessons.sh . | head -20`
- **Files:** `scripts/automation/harvest-lessons.sh` (new), this file.
- **Rollback:** standalone script; delete it.

---

## 8. P1 — Self-modification safety

Guards for the fact that the models editing this repo are now weaker than the one that
built it. Do these first; they are cheap.

### SAFE-1 — DONE 2026-07-08, archived

### SAFE-2 — DONE 2026-07-08, archived

---

## 9. P1 — Speed & token efficiency

Clean lean iteration ≈ 109 min (developer ~41m, reviewer ~21m, browser-qa ~20m,
evaluator ~17m, decomposer ~8m — typicals from the timeout table comments,
`scripts/automation/lib/agent_permissions.py:88-110`). Rule for ALL items here: EVO-3
benchmark (or a real session's telemetry) before AND after (G8).

**When to benchmark (standing rule — the EVO-3 harness):**
- BEFORE and AFTER any SPEED-*/TOKEN-* experiment in this section, and during
  EVO-4 model cutovers (playbook step 7). Same fixture, same `--max-iter`.
- Run (G9 — user-approved spend per run; order-of-dollars, ~1.5-5h wall):
  `./scripts/automation/run-benchmark.sh --hypothesis '<one-line prediction>'
  [--predict '<key OP value>']... --yes-spend`. The runner refuses without the
  hypothesis (G8) or on a dirty tree — commit first; the PRE entry in
  `benchmarks/experiments.md` (append-only ledger) is written BEFORE the engine
  launches and the POST entry grades `--predict` predicates mechanically
  (CONFIRMED/REFUTED/MIXED). Predicate keys = scalar keys of the results JSON's
  meta+outcome blocks (e.g. `final_status`, `journeys_passing_after`).
- Compare: `python3 scripts/automation/lib/benchmark_compare.py <old>.json
  <new>.json` → delta table + verdict OK / REGRESS / UNKNOWN (exit 0/3/4);
  REGRESS = wall or cost +>25% or journeys-passing dropped; incomparable
  verdict inputs → UNKNOWN, never a guess.
- Afterwards commit the new results JSON + ledger entries; whatever completed
  IS the measurement — a rerun for a prettier number needs fresh approval and
  a fresh PRE entry.

### SPEED-1 · Refactor browser-qa into a function (no behavior change)
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** DONE 2026-07-12 —
  extracted `run_browser_qa_section()` with the resume-skip guard AND
  `step_invalidate_from browser-qa` kept at the caller; the function runs in the
  caller's shell (plain call, no subshell) and the body moved verbatim
  (un-indented pure move — zero body lines appear in the diff, which is two
  boundary edits plus one comment word). Zero `local`s added: inventory of 44
  body-assigned globals (QA_* exports, QA_STARTED_PIDS, FRONTEND_*/service
  vars, lane vars, `_j`) — none is read after the call site in-file, and
  same-shell lib consumers (ensure_services_running, the quota-retry hook) see
  identical state. Proof: instrumented test-goal-checkpoints.sh with kept
  sandbox, normalized artifact tree+content snapshot (noise classes
  pre-validated by two identical-code HEAD runs) diffs EMPTY pre vs post with
  stdout 11/11 identical; test-goal-async-tail 14/14 identical (PIDs
  normalized); test-goal-retro 41/41 identical; bash -n + run-evals 97/97.
- **Problem:** the browser-qa section of the lean executor was a ~270-line inline
  block; SPEED-2 needs to run it in a forked subshell.
- **Current state (anchors refreshed after SPEED-2's 2026-07-12 renumbering):**
  `run_browser_qa_section()` definition `scripts/automation/goal-iter-lean.sh:716-881`
  (SPEED-2 carved service boot + golden partition + replay lane into
  `run_browser_qa_boot_and_replay()` `:174-289`, run inline by the section's join
  fallback `:735-738` when the knob is off; LLM lane + merge `:809-857`, REL-11
  tripwire `:827-839`, golden coverage + checkpoint mark `:859-880`);
  resume-skip check `:694-707`; caller guard + invalidation + call `:883-889`.
- **Change spec:** extract into `run_browser_qa_section()` in the same file; keep the
  resume-skip guard and `step_invalidate_from browser-qa` at the caller; byte-identical
  sequential behavior.
- **DoD:** existing checkpoint test green; no diff in any artifact path or verdict
  behavior.
- **Verify:** `bash -n scripts/automation/goal-iter-lean.sh &&
  bash tests/automation/test-goal-checkpoints.sh && ./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/goal-iter-lean.sh`.
- **Rollback:** revert the commit (pure refactor).

### SPEED-2 · Parallel review ∥ browser-qa — stage "replay"
- **Priority:** P1 · **Effort:** M · **Risk:** MED · **Status:** DONE 2026-07-12 —
  certified 2026-07-12 by a fresh non-implementer session per G8: parallel-bqa 36/36 +
  checkpoints 11/11 + run-evals 98/98; off-mode byte-identity REPRODUCED (fresh stub
  sandbox on pre-SPEED-2 `bb09160` vs HEAD, normalized tree+content+stdout+prompt
  snapshot diff = exactly the one spec-mandated `iter_config` telemetry line, normalizer
  pre-validated by a HEAD-vs-HEAD empty diff); FAIL-path kill-before-invalidate proof
  repeated 5× with zero flakes (slow-stub TERM stamp); fork isolation, tripwire
  persistence across invocations, and the cleanup reap re-verified by skeptical read.
  DONE ≠ default flip (G4): any default flip still requires the pre-registered benchmark
  measurement per §9 (before = `benchmarks/results/20260712-171324-5e87813077ae.json`);
  default remains `off`.
  *Measurement note (2026-07-14, §9 runs A′+B — ledger `bench-20260714-0634` /
  `bench-20260714-0830`):* SPEED-2's relocation of the journey-set parse exposed a
  PRE-EXISTING silent lean-lane death on journey-less spec lines (introduced 633059a;
  at its old mid-section position it had killed BOTH prior benchmarks' iter-0
  browser+coherence lanes; the relocation enlarged the kill to the whole lane,
  pre-developer) — root-caused, fixed and eval-pinned in c8bb8c0 (`|| true` guards +
  parallel-bqa scenario I, proven red-on-prefix/green-on-fix, 74/74). Live stage-full
  run (B, one variable vs A′): the shared fork machinery is ALL green in a real
  session — spawn after developer, fork telemetry attribution, join settled 1s before
  the evaluator, 0 attempt-1-review-FAIL waste, tripwire untripped, 0 orphans. Wall
  −11.6% NOT attributable (pre-registered null: iter-0 overlap potential was ≤73s —
  review 73s, fork LLM lane started after review ended — vs far larger agent-duration
  variance). Stage replay itself still has no live-session run (no goldens existed at
  iter-0). Journeys held 3/3 in both runs.
  *Flip decision (2026-07-14, user):* default stays **off** per the pre-registered
  null-result rule — the flip decision needs one real-session telemetry comparison
  (sections long enough to overlap; see also REL-12, which unlocks lean browser
  evidence on single-service projects). Tripwire stays armed. Evidence:
  `benchmarks/experiments.md` POSTs bench-20260714-0634 / bench-20260714-0830.
  *Control update (2026-07-14, §9 run C `bench-20260714-1539` @ 39e2a79de68a,
  knob off):* REL-12 is DONE — run C's iter-0 lean browser lane EXECUTES journeys
  on the single-service fixture (SKIP-for-boot gone), so run C is the new
  lean-capable control and the flip re-measurement at lean depth is now
  RESOLVABLE: one future knob-on run vs C settles it. Fresh G9 approval required;
  one variable (the knob) only. Compare against C, not A′/B — run C is also the
  TOKEN-8 comparability baseline for cost reads.
  *Flip decision FINAL (2026-07-15, user — §9 run D `bench-20260715-0924` @
  fd378ca276a9, knob=full, lean-depth control C):* default stays **off**; the
  flip question is CLOSED as DONE-knob-off — the default is a recorded product
  decision, not pending work. Run D's fork mechanics were 100% green (knob
  honored ×2 iterations with no demotion, spawn + clean joins, tripwire 0,
  wasted dispatches 0, orphans 0) and it delivered the first LIVE
  realized-overlap witness on a lean-capable lane: ~392s of a ~399s cap —
  review fully covered by the forked browser lane in BOTH iterations. But its
  journeys predicate REFUTED 0/3 for an environmental reason orthogonal to the
  knob: Chrome MCP DevTools-port contention from ~50 foreign Chrome processes
  on the shared host (diagnosed independently in both iterations, corroborated
  live post-run; the browser lane SKIPPED honestly and the evaluator STALLED
  correctly at the 2nd no-evidence iteration), so wall (−34.2%) and cost
  (−23.5%) vs C are composition-broken and ungraded. Per the pre-committed
  decision matrix: quality strike → stay off, no further fixture runs — the
  fixture has failed to price the flip three times (A′/B pre-registered null,
  D confounded); any future flip ask requires REAL-SESSION telemetry with
  meaningful overlap windows and its own G9/G4 approval. Tripwire stays armed.
  Evidence: ledger PRE/POST bench-20260715-0924,
  benchmarks/results/20260715-101135-fd378ca276a9.json.
  *Implementation note (2026-07-12):* knob `CHAIN_LEAN_PARALLEL_BROWSER_QA=off|replay|full`,
  default `off` (`full` warns "full is SPEED-3" and behaves as `replay`; documented in the
  `.claude/model-orchestration.md` knob table). Fork unit =
  `run_browser_qa_boot_and_replay()` (`goal-iter-lean.sh:174-289`: service boot + golden
  partition + replay lane, body lines moved verbatim) — knob=off calls it inline at its
  original position via the section's join fallback (`:735-738`, byte-identity proven:
  normalized artifact-tree+content+stdout snapshots of a stub sandbox run, HEAD vs
  post-change, diff to EXACTLY the one spec-mandated `iter_config` telemetry line, with
  noise classes pre-validated by two identical-code HEAD runs); knob=replay forks it right
  after the developer step settles (`:538-575`) with coherence-style isolation
  (subshell-contained `CHAIN_CURRENT_AGENT=browser-qa-replay`, own rc/state/pid files under
  the iter dir; the pid file doubles as a cross-process orphan guard). The join
  (`_bqa_fork_consume` `:324-347`) consumes an atomic sentinel-terminated state file
  (frontend availability, QA_* env for the retry hook, partition + `REPLAY_FAILED`), so the
  LLM lane's target set is computed EXACTLY as sequentially (test-asserted equal). FAIL-path
  ordering (`_bqa_fork_reap` `:357-375`, called at `:604` before any invalidation):
  `_kill_pid_tree` → `wait` until dead → port sweep (a finished fork's servers are orphaned
  to init and would serve pre-fix code) → rm lane files explicitly (`step_invalidate_from`
  deletes only marker-registered artifacts; the fork's outputs aren't registered until
  `step_mark_done browser-qa`) → THEN `step_invalidate_from developer-fix` (`:608`).
  Tripwire: attempt-1 review FAILs in ≥2 of the last 3 iterations (jq over
  `telemetry.jsonl`, last-verdict-per-iteration) → persists
  `runs/goal-session-<sid>/state/parallel-bqa-disabled` for the rest of the session
  (`_bqa_tripwire_active` `:398-426`); no-jq → fork stays off (a tripwire that cannot fire
  must not arm the experiment); an `iter_config` event (`{key,value,requested,reason}`,
  `:455`) names the knob state every iteration — the one intentional off-mode delta.
  Test: `tests/automation/test-goal-parallel-bqa.sh` (36 asserts — off-identity incl. exact
  pre-change artifact tree; fork+join with LLM-target-set + merged-rows equality vs the
  sequential run; kill-before-invalidate proven via a TERM stamp from inside a 30s-slow
  stub demo_runner + no lane file post-invalidation after a settle window; tripwire
  trip+persist across two iterations; full→replay warning), registered in run-evals §2c
  (98/98; suite ~66s — the quick-start "<30s" claim was already stale at ~51s before this
  change). NOTE: this change renumbered `goal-iter-lean.sh` below `:104` — other items
  citing that file should re-verify anchors (standing rule).
- **Problem:** reviewer (~21m) and browser-qa (~20m) both need only the post-dev tree
  yet run sequentially — the single biggest safe parallelism left in the lean path.
- **Current state (post-implementation anchors):** sequence is developer →
  fork (`goal-iter-lean.sh:538-575`) → review loop (`:577-641`; reap `:604`;
  `step_invalidate_from developer-fix` `:608`) → join at the top of
  `run_browser_qa_section` (`:735-738`) → LLM lane + merge (`:809-857`).
  Coherence fork `:643-683`, its join `:891-913`; both forks reaped in
  `cleanup_iter_servers` `:113-134`. Feasibility re-verified 2026-07-12: the
  checkpoint canonical order (`lib/checkpoint.sh:40`) is an INVALIDATION order, not an
  execution order — `step_invalidate_from developer-fix` already cascades deletion of
  browser-qa/coherence/evaluator markers AND their registered artifacts
  (`checkpoint.sh:193-225`), so an early-forked browser-qa result is auto-invalidated
  on the FAIL path with zero checkpoint changes (raw lane files are additionally
  discarded by the reap — they are not marker-registered until the section's
  `step_mark_done browser-qa`). Browser-qa writes land under `runs/`
  + `reports/`, which are excluded from the tree hash (`checkpoint.sh:35`). Reviewer
  only reads/diffs (`review_diff_hint`).
- **Change spec:**
  1. Knob `CHAIN_LEAN_PARALLEL_BROWSER_QA=off|replay|full`, default `off`.
  2. In `replay` mode: after `step_mark_done developer` (`:193`), fork service boot +
     lane-1 deterministic replay ONLY (`demo_runner.py --mode verify` — pure python,
     cleanly killable in both backends, no pump involvement) in a subshell copying the
     coherence-fork pattern (isolate `CHAIN_CURRENT_AGENT`, rc-file, PID). Join after
     review settles; feed `REPLAY_FAILED` into the LLM lane's target set exactly as the
     sequential path does (`:534`).
  3. **On review-1 FAIL — ordering is CRITICAL:** kill the fork, `wait` for it to die,
     THEN `step_invalidate_from developer-fix`, then re-run browser-qa sequentially
     post-fix. Never let a forked write land after invalidation.
  4. Extend `cleanup_iter_servers` to reap the new PID.
  5. Tripwire: if ≥2 of the last 3 iterations logged an attempt-1 review FAIL (read
     `telemetry.jsonl` with jq), skip the fork for the rest of the session; emit an
     `iter_config` telemetry event naming the knob state (mirror `run-goal.sh:1194-1198`).
  6. New `tests/automation/test-goal-parallel-bqa.sh` (stub-claude sandbox, modeled on
     `test-goal-checkpoints.sh`): asserts fork/join on the PASS path and
     kill-then-invalidate on the FAIL path.
- **DoD:** default-off; replay mode green in the sandbox test on both paths; telemetry
  attributes the fork correctly; evals green. (All met 2026-07-12 — DONE additionally
  requires the G8 fresh-session certification, see Status.)
- **Verify:** `bash tests/automation/test-goal-parallel-bqa.sh &&
  bash tests/automation/test-goal-checkpoints.sh && ./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/goal-iter-lean.sh`,
  `tests/automation/test-goal-parallel-bqa.sh`, `scripts/automation/run-evals.sh`
  (§2c registration), `.claude/model-orchestration.md` (knob table).
- **Rollback:** knob default `off` — no rollback needed; delete the fork block if it
  misbehaves.
- **Stop-and-ask:** any evidence of a result file appearing AFTER its invalidation
  (stale artifact certifying nothing) = stop, that's the exact race this design guards.
- **Trigger:** ship after SPEED-1; measure with EVO-3 or one real session before/after.
- **Depends on:** SPEED-1.

### SPEED-3 · Parallel review ∥ browser-qa — stage "full" (headless only)
- **Priority:** P1 · **Effort:** M · **Risk:** MED · **Status:** DONE 2026-07-13 —
  certified 2026-07-13 by a fresh non-implementer session per G8: parallel-bqa 68/68
  green across 6 consecutive full-suite runs — the race/orphan/rc-70 scenarios (C
  kill-ordering, G kill-mid-dispatch + zero-orphan pgrep + wasted-dispatch event, H
  rc-70 pause parity, 28 asserts) re-run 5× with zero flakes; the join-pause tree-diff
  claim reproduced (H: forked rc-70 pause tree file-list + step markers + developer
  marker tree_hash IDENTICAL to the sequential pause tree; H3 resume: developer skips,
  browser-qa re-forks, real PASS); interactive→replay backend gate re-verified (E:
  headless-only warning, `iter_config` reason=interactive-backend, zero dispatches on
  a checkpointed rerun); checkpoints 11/11; run-evals 98/98. Skeptical structural read
  of the fork machinery (rc file skipped on in-fork exit-70 so `wait` carries the
  pause to the join; marker deferred to the join behind `_BQA_IN_FULL_FORK`;
  reap-before-invalidate ordering; recycled-PID-safe orphan guard;
  `cleanup_iter_servers` full-fork reap) matched every implementation-note claim.
  DONE ≠ default flip (G4): any default flip still requires the §9 pre-registered
  benchmark measurement (before = `benchmarks/results/20260712-171324-5e87813077ae.json`);
  default remains `off`.
  *Measurement note (2026-07-14, §9 run B `bench-20260714-0830` vs control A′
  `bench-20260714-0634`, one variable = `CHAIN_LEAN_PARALLEL_BROWSER_QA=full`):* FIRST
  LIVE RUN of the full-section fork — every mechanical observable green:
  `iter_config {value:full, requested:full}` (headless honored, no demotion), fork
  spawned after the developer settled, review ran concurrently with the fork's boot
  phase, the fork's browser-qa-agent dispatch attributed correctly in session
  telemetry, join settled the fork 1s before the goal-evaluator started (input set
  complete), 0 attempt-1 review FAILs (no wasted-dispatch path), tripwire never
  tripped, 0 orphan processes post-run. Journeys 3/3 HOLD; benchmark_compare verdict
  OK (wall −11.6%, cost −4.5%). The WALL delta is NOT attributable to the knob
  (pre-registered null): the fixture's iter-0 sections are too short to overlap
  meaningfully (review 73s; the fork's LLM lane began 61s after review ended; only
  the ~2-min service boot overlapped) and per-agent duration variance dwarfed the
  ≤73s overlap potential. Verdict-shape deltas across the pair (A′ GOAL_ACHIEVED vs
  B BUDGET_EXHAUSTED/CONTINUE at 3/3; iter-0 CONTINUE vs ESCALATE on identically
  SKIPPED browser lanes) are evaluator judgment variance, not knob effects — full
  detail in the ledger POSTs.
  *Flip decision (2026-07-14, user):* default stays **off** per the pre-registered
  null-result rule — a real-session telemetry comparison (meaningful overlap windows)
  is the prerequisite for any flip ask; `full` remains headless-gated when it comes.
  Tripwire stays armed. Evidence: ledger POSTs bench-20260714-0634 /
  bench-20260714-0830.
  *Control update (2026-07-14, §9 run C `bench-20260714-1539` @ 39e2a79de68a,
  knob off):* run C is the new lean-capable control (REL-12 DONE: iter-0 lean
  browser lane executes journeys on the single-service fixture) — a stage-full
  flip re-measurement at lean depth is now RESOLVABLE as one future knob-on run
  vs C (fresh G9 approval; one variable only; compare against C, not A′/B — run
  C is also the TOKEN-8 comparability baseline).
  *Flip decision FINAL (2026-07-15, user — §9 run D `bench-20260715-0924` @
  fd378ca276a9):* default stays **off**; CLOSED as DONE-knob-off (recorded
  product decision). Run D was stage-full's second live run and its first on a
  lean-capable control: every mechanical observable green (iter_config
  value=full ×2, fork spawn + clean join ×2, tripwire 0, wasted dispatches 0,
  orphans 0) and the review ∥ browser-qa overlap REALIZED at ~98% of its
  theoretical cap (iter-0: 207s of a 211s review; iter-1: 185s of 188s) —
  first live proof the full-section fork actually buys its min(review,
  browser-qa) saving. Journeys REFUTED 0/3 on host Chrome-MCP DevTools-port
  contention (~50 foreign Chrome processes; orthogonal to the knob; the
  SKIP → STALLED honesty path worked as designed), leaving wall/cost vs C
  ungraded. Matrix: quality strike → stay off; the flip is parked on
  real-session telemetry (the fixture failed to price it 3×). Expected saving
  on real sessions remains ≈ min(review, browser-qa) — the mechanism is
  live-proven; only its price on real workloads is unknown. Evidence: ledger
  PRE/POST bench-20260715-0924,
  benchmarks/results/20260715-101135-fd378ca276a9.json + SPEED-2's note.
  *Implementation note (2026-07-13):* backend gate at knob parse: `full` is honored only
  when `CHAIN_AGENT_BACKEND != interactive`; interactive demotes to `replay` with one
  logged warning and `iter_config` reason `interactive-backend` (`goal-iter-lean.sh:540`,
  replacing SPEED-2's placeholder warning). Fork unit = the WHOLE
  `run_browser_qa_section` (service boot + replay lane + LLM lane + merge) — its
  definition moved verbatim above the developer step so the fork subshell can see it
  (`:575`; off-mode byte-identity re-proven post-move: pre-SPEED-2 `bb09160` vs HEAD
  normalized sandbox snapshot still diffs to exactly the one `iter_config` line). Spawn
  right after developer settles with replay-fork isolation (subshell-contained agent
  name, own `.bqa-full-rc`/`.bqa-full-pid`, recycled-PID-safe orphan guard, `:865`).
  Checkpointing stays in the PARENT: the fork writes NO step markers (the review loop's
  invalidation cascades pass through browser-qa, so a fork-written marker would race
  them); browser-qa is invalidated BEFORE forking and the join writes the marker after
  validating the merged results (`_BQA_IN_FULL_FORK` guard `:739`). JOIN-PAUSE
  TRANSLATION (the hardest semantic): `_pause_if_transport` EXITS the fork subshell from
  inside `run_browser_qa_llm` before the rc file can be written, so the join
  (`_bqa_full_fork_consume` `:415`) reads `wait`'s status and re-raises rc 70 in the
  parent — engine pauses resumably exactly as inline; any other fork failure falls back
  to the inline section (the sequential path IS the fallback). Test-proven: the
  pause-at-join sandbox tree (file list + step markers + marker tree_hash) is IDENTICAL
  to the sequential rc-70 pause tree, and a follow-up run resumes (developer skips,
  browser-qa re-forks, real PASS). Review-1 FAIL: `_bqa_full_fork_reap` (`:453`, called
  `:931` beside the replay reap) kills the whole fork tree (in-flight stub dispatch
  included), waits, sweeps ports, discards replay+LLM+merged lane files, THEN
  `step_invalidate_from developer-fix` — post-fix browser-qa runs sequentially; pgrep
  in the test asserts ZERO surviving fork processes (the stop-and-ask trigger). Cost
  dimension: the reap emits `parallel_bqa_wasted_dispatch` (mode=full, wasted full
  browser-qa dispatch fact, plus the note that the 2-of-3 tripwire spares exactly this
  cost); the tripwire itself now gates both `replay` and `full`.
  `cleanup_iter_servers` reaps the full-fork PID tree on every exit path (`:142`).
  Test: `tests/automation/test-goal-parallel-bqa.sh` extended 36→68 asserts (scenarios
  E interactive-gate/dispatch-free, F full+PASS with overlap witness + tree/rows/target
  identity vs sequential, G kill-mid-dispatch + zero-orphan pgrep + wasted-dispatch
  event, H rc-70 pause-tree parity + resume); suite ~24s, still in run-evals §2c
  (98/98). Race/orphan scenarios re-run 5× — zero flakes.
- **Problem:** replay mode only parallelizes the deterministic lane; the LLM browser-qa
  dispatch (~most of the 20m) still waits for review.
- **Current state:** as SPEED-2. The interactive backend is EXCLUDED: killing the
  engine-side waiter leaves the pump's subagent running against a request nobody reads
  (stale `req.*`/`.res` files are only cleaned at engine start, `run-goal.sh:819`) —
  that cancellation gap is EXP-4's problem, not this item's.
- **Change spec:** in `full` mode AND `CHAIN_AGENT_BACKEND != interactive`: fork the
  whole `run_browser_qa_section` (LLM lane included); join handles rc 70 exactly like
  the coherence join (`goal-iter-lean.sh:899-902`); same kill-then-invalidate FAIL
  ordering; tripwire gains a cost dimension (a wasted full browser-qa dispatch per
  review-FAIL iteration — log it).
- **DoD:** headless sandbox test green both paths; interactive mode ignores `full`
  (falls back to `replay`) with a logged warning; evals green.
- **Verify:** extend `test-goal-parallel-bqa.sh`; `./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/goal-iter-lean.sh`, test, docs.
- **Rollback:** knob.
- **Stop-and-ask:** same as SPEED-2; plus if headless kill leaves orphan `claude`
  processes (check `pgrep` in the test), stop.
- **Depends on:** SPEED-2. Expected saving ≈ min(review, browser-qa) ≈ up to ~20m on
  clean iterations.
  *Scope note (2026-07-17, SPEED-6):* this item's scope is `goal-iter-lean.sh` only —
  "full" in this entry names the `CHAIN_LEAN_PARALLEL_BROWSER_QA=full` knob STAGE
  (fork the whole browser-qa section of a LEAN iteration), not full pipeline depth.
  run-phase.sh full depth has never had review ∥ browser-qa (review completes inside
  the sequential Step 3 dev+review loop, `run-phase.sh:674-726`); what full depth
  does parallelize is the post-dev Branch-UI ∥ Branch-QA fanout
  (`_run_post_dev_fanout`, `run-phase.sh:254`, call `:745`). Porting a review-overlap
  fork to the full pipeline is staged as §16 CAND-FULL-BQA-OVERLAP — re-check demand
  after SPEED-4, which makes full iterations rare.

### SPEED-4 · Depth rubric sharpened — lean-first + deterministic hardening cadence
- **Priority:** P1 · **Effort:** S · **Risk:** LOW-MED · **Status:** DONE 2026-07-17
  *(user-approved throughput package; implemented same session as SPEED-5/6/7 — plan
  sign-off served as the EVO-1 promotion for direct §9 placement and the G6
  multiple-S-items exception.)*
- **Problem:** the depth rubric sent an iteration full when it "requires new tests
  beyond browser smoke" — post-REL-9 every spec must carry ≥3 `TC-` scenario lines,
  so the trigger fired on every real journey. Evidence (tapeology
  `goal-session-fast_wall`, 299-event telemetry): 0 lean / 7 full post-baseline
  iterations at ~3-4h each vs ~2h lean (§9 header) — ~1.5-2h/iteration of
  full-pipeline overhead (orchestrator, qa ×2, ui chain, auditor, closure) spent on
  single-module work that lean's own definition covers.
- **Current state (as built):** rubric rewritten `agents/goal-decomposer/body.md:143-170`
  — lean is the default; full only on numbered triggers (1 structural/cross-cutting
  ≥3 modules, 2 data model / Data-Contract value, 3 prior ESCALATE, 4 hardening
  cadence); "needs unit tests" explicitly NOT a trigger (lean's developer still
  executes every TC- scenario — depth selects the agent set, not testing).
  Self-check #4 updated (`body.md:226` — full cites its numbered trigger; lean
  states "no full trigger holds"). Engine cadence: every dispatch branch writes
  `$ITER_DIR/depth-dispatched` (`run-goal.sh:1884/:1888/:1893` — the depth that
  actually ran, legacy fallback included; idempotent overwrite → resume-proof);
  `goal_lean_streak` + `goal_cadence_forces_full` (`lib/common.sh:888/:904`) compute
  the trailing-lean streak (missing file or non-lean breaks it; iter-0 never
  counted); the streak is inlined into the decomposer prompt (`run-goal.sh:1719` —
  the prompt only carries the last 3 evaluator entries, so the engine must supply
  the count) and a post-parse backstop (`run-goal.sh:1845-1848`) overrides
  `lean → full` when K consecutive leans have run (K=`CHAIN_HARDENING_CADENCE`,
  default 4, `0` disables), logging loudly + telemetry `depth_cadence_override`.
  When the backstop fires the spec still reads lean — dispatch + telemetry carry
  the effective depth (intended: a hardening pass audits the ACCUMULATED tree, so a
  lean-scoped spec is exactly right).
- **DoD (met):** `tests/automation/test-depth-cadence.sh` (17 asserts, TDD
  red→green: streak semantics incl. reset / missing-file / idempotent re-entry,
  cadence decision matrix incl. K=0 and the current_iter>K floor, engine wiring
  greps, rubric greps) green + registered in run-evals §2c; sync `--check` clean;
  rendered mirror carries the new rubric.
- **Verify:** `bash tests/automation/test-depth-cadence.sh` ·
  `python3 scripts/automation/sync-cli-assets.py --cli claude --check` ·
  `grep -n "Hardening cadence" .claude/agents/goal-decomposer.md`
- **Files:** `agents/goal-decomposer/body.md` (+ rendered mirror, version 2.3.0),
  `scripts/automation/run-goal.sh`, `scripts/automation/lib/common.sh`,
  `tests/automation/test-depth-cadence.sh`, `scripts/automation/run-evals.sh`.
- **Rollback:** revert the body + engine edits; `CHAIN_HARDENING_CADENCE=0` disables
  the cadence alone (rubric stays).
- **Stop-and-ask:** if any file besides `agents/goal-decomposer/body.md` + its
  rendered mirror turns out to describe the depth triggers, stop and resync them
  together (grep across docs/.claude/skills/commands/templates proved only those two
  today). A lean-classified structural change slipping through is the accepted risk;
  mitigations = cadence full pass + the evaluator's existing ESCALATE⇒full path.
- **Before/after (G8 via telemetry, no paid benchmark — rubric fix, not a knob
  experiment):** BEFORE = fast_wall 0:7 lean:full post-baseline, ~19.9h over iters
  0-5. AFTER = first real session on this rubric: record its lean:full ratio +
  wall/iter here from telemetry. Expected ~1.5-2h saved per correctly-lean-classed
  iteration.

### SPEED-5 · Goal-mode full iterations ran the iteration-summarizer twice
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** DONE 2026-07-17
  *(same user-approved package as SPEED-4.)*
- **Problem:** a goal-mode FULL iteration dispatched the summarizer twice onto the
  same file: run-phase.sh Step 10.5 (pre-evaluator, inside the executor) and the
  goal engine's post-evaluator showcase tail (`run-goal.sh:267` writes the identical
  `reports/phase-<iter>-iteration-summary.md`; run-phase's `$PHASE` IS run-goal's
  `$ITER_NAME`). Write #2 overwrites write #1. fast_wall: 135 min of summarizer
  wall across 6 iterations, ×2 dispatches each — the largest pure-overhead sink.
- **Current state (as built):** `_summary_deferred_to_goal_showcase`
  (`run-phase.sh:134`) gates BOTH call sites — Step 10.5 (`:1073`, loud deferral
  log) and `fail()` (`:279`; on executor failure run-goal still proceeds to the
  evaluator and the showcase runs for every verdict, so the summary still gets
  written) — on the CONJUNCTION `NO_FINALIZE=true` AND phase name
  `^goal-.+-iter-[0-9]+$`; escape hatch `CHAIN_FULL_ITER_SUMMARY=true` (mirrors
  `CHAIN_README_EVERY_ITER`). Both signals required: `--no-finalize` alone also
  serves standalone phase runs (test-engine-lock drives `lockphase --no-finalize`);
  the name alone also serves manual reruns. Reader map (why write #1 was safe to
  drop): every consumer — readme-maintainer (`run-goal.sh:430`), delivered wrap
  (`:481`), intent-review links (`:887-891`), session-index, the next iteration's
  summarizer — reads AFTER the showcase write; the executor→evaluator gap has ZERO
  readers (the evaluator dispatch prompt, `run-goal.sh:2012` region, lists its
  inputs explicitly and the summary is absent; coherence/decomposer/gate libs grep
  clean). Accepted loss: a hard engine crash between executor and showcase leaves
  that iteration without a summary — the exposure lean mode already has
  (equalization, not regression).
- **DoD (met):** `tests/automation/test-summary-dedupe.sh` (11 asserts, TDD
  red→green: deferral + loud log naming the escape hatch + pipeline completion in
  the goal case; summarizer KEPT for standalone `--no-finalize` phases, manual
  goal-name reruns, and the escape hatch) green + registered in run-evals §2c;
  neighbors green (test-engine-lock / test-testplan-skip / test-goal-async-tail).
- **Verify:** `bash tests/automation/test-summary-dedupe.sh` ·
  `bash tests/automation/test-engine-lock.sh`
- **Files:** `scripts/automation/run-phase.sh`,
  `tests/automation/test-summary-dedupe.sh`, `scripts/automation/run-evals.sh`.
- **Rollback:** `CHAIN_FULL_ITER_SUMMARY=true` (behavioral) or revert (structural).
- **Stop-and-ask:** if any consumer of the PRE-evaluator summary ever surfaces (a
  reader inside the executor→evaluator window), stop — re-check against the reader
  map above.
- **Saving:** one summarizer dispatch + render per full iteration (~15-30 min/iter
  observed in fast_wall; the showcase copy is unchanged).

### SPEED-6 · SPEED-3 scope reconciliation (docs-only)
- **Priority:** P2 · **Effort:** S · **Risk:** LOW · **Status:** DONE 2026-07-17.
- **Problem:** SPEED-3's headline "stage 'full' (headless)" invites misreading as
  full-DEPTH parallelism; this week's session forensics initially flagged
  run-phase.sh's sequential review → browser-qa ordering as "SPEED-3 not engaged".
- **Change (as built):** scope note appended to the SPEED-3 entry above (knob stage
  vs pipeline depth, with run-phase.sh anchors); the genuine full-depth port is
  staged as §16 CAND-FULL-BQA-OVERLAP behind a demand gate (post-SPEED-4, full
  iterations should be rare).
- **Files:** this file only. **Rollback:** docs-only.
- **Verify:** `grep -n "Scope note (2026-07-17" docs/improvement-roadmap.md`

### SPEED-7 · Journey merge advisory at authoring time
- **Priority:** P2 · **Effort:** S · **Risk:** LOW · **Status:** DONE 2026-07-17
  *(same user-approved package as SPEED-4.)*
- **Problem:** each Must-have journey is the unit the engine plans, verifies, and
  iterates on, but nothing at authoring time says so — needless journey splits buy
  extra iterations, not extra safety. fast_wall evidence: J-02 + J-06 (both durable
  SQLite accelerators; goal.md itself notes J-06 rides on J-02's precedent) were
  authored separately and cost one ~3h full iteration each.
- **Current state (as built):** merge advisory in the authoring interview
  (`skills/goal-authoring.md:52-59` — merge same-surface/same-risk pairs into ONE
  journey with multiple acceptance bullets; keep them split when surfaces or risk
  class differ, or when merging would break fresh-page independence) + a
  `Mergeable journey pair (advisory)` semantic-pass bullet in
  `commands/goal-lint.md:35-39` (suggests the merged journey text; splitting is
  never an error). Report-only by construction — goal-lint never edits goal.md;
  deterministic `goal_lint.py` untouched.
- **DoD (met):** both inserts render in mirrors; sync `--check` clean.
- **Verify:** `grep -n "Merge advisory" .claude/skills/goal-authoring.md` ·
  `grep -n "Mergeable journey pair" .claude/commands/goal-lint.md`
- **Files:** `skills/goal-authoring.md`, `commands/goal-lint.md` (+ mirrors).
- **Rollback:** docs-only revert.
- **Saving:** ~1 full iteration (~3h) per journey pair a future goal merges.

### SPEED-8 · Passenger batching — one risky journey + up to 2 disjoint trivial passengers
- **Priority:** P1 · **Effort:** M · **Risk:** MED · **Status:** TODO
  *(mini-spec authored 2026-07-17 in the same user-approved package; implement in a
  later session.)*
- **Problem:** priority-rubric rule 5 (`agents/goal-decomposer/body.md:136`) is an
  exclusive OR — "several trivial journeys OR one risky journey" — so a goal whose
  journeys are mostly risky marches strictly 1/iteration even when small
  independent journeys could ride along. fast_wall: 7 journeys → 7 iterations.
- **Change spec:** (1) Replace rule 5 with: an iteration carries at most ONE risky
  journey (data-model change, provider integration, cross-cutting refactor) and MAY
  additionally carry up to 2 trivial "passenger" journeys ONLY IF each passenger
  (a) touches no module/page the risky journey touches, (b) is independently
  scoreable from its own evidence, and (c) is droppable — a failed passenger is
  simply not done; it never blocks or muddies the risky journey's verdict. Never
  two risky journeys (unchanged — a joint failure is undiagnosable). Update the
  "Stay tight" rule (`body.md:237`) to reference rule 5's passenger form.
  (2) NEW optional Goal Mode Metadata line
  `Journey complexity: J-07=normal, J-03=trivial` — its OWN line, NEVER annotations
  inside `Target journeys:` (that raw line feeds `goal_gate.py goal-slice
  --targets`, `run-goal.sh:1978`, and the display/telemetry at `:1851-1856`;
  annotations would corrupt both). Same `trivial|normal` vocabulary as §16
  CAND-TIER — whichever lands first defines the line; cross-reference on landing.
  (3) Evaluator (`agents/goal-evaluator/body.md`, methodology section + CONTINUE
  verdict bullet): score each target journey from its own evidence; a passenger
  failure is recorded on the passenger only, never downgrades the risky journey's
  earned verdict, and never alone justifies ESCALATE.
- **DoD:** rubric + metadata + evaluator guidance rendered in mirrors (decomposer +
  evaluator version bumps); a goal-evaluator judgment fixture where a passenger
  fails while the risky journey passes yields CONTINUE with independent per-journey
  rows; evals green; G8 fresh-session certification.
- **Verify:** sync `--check` · `./scripts/automation/run-evals.sh` · judgment
  fixture run (G9 spend approval).
- **Files:** `agents/goal-decomposer/body.md`, `agents/goal-evaluator/body.md`
  (+ mirrors), `tests/judgment/goal-evaluator/` (new case), this file.
- **Rollback:** revert the body edits — the metadata line is optional, old specs
  parse unchanged.
- **Stop-and-ask:** any change that would touch an engine parse of
  `Target journeys:`; any judgment-fixture verdict-class flip.
- **Depends on:** SPEED-4 (the sharpened rubric defines what "trivial" means in
  practice); synergizes with §16 CAND-TIER (same complexity vocabulary).

<!-- ═══ SPEED-9…19 · the 2026-07-28 iteration-speed package (user-approved
     promotion per EVO-1 + G6 multi-item exception, same mechanism as
     SPEED-4..7 / CTX / PLAIN-1). Diagnosis basis: tapeology desk session
     telemetry — 15 iterations, ~153 agent-min each; verification = 54% of all
     agent minutes; of iters 10-14 only ONE shipped product code (the rest
     chased screenshots/recordings); iter-7 blocked 18.3h on a dead pump's
     claim; full depth ran 4 of the last 6 iterations. Target: typical
     iterations < 60 min without giving up the judge chain's quality. ═══ -->

### SPEED-9 · Evidence fast path — `evidence` depth + evaluator evidence durability
- **Priority:** P0 · **Effort:** L (a: engine micro-path; b: evaluator contract;
  c: decomposer rules) · **Risk:** MED · **Status:** IN-PROGRESS — implemented
  2026-07-28 (commits 58b93be, 8bd513f, dc86b53); G8 fresh-session certification
  + one real-session before/after pending.
- **Problem:** 3 of the desk session's last 5 iterations (~6h) ran full/lean
  pipelines solely to retake a screenshot or record a walkthrough for features
  already verified working; lean specs whose deliverable was the walkthrough were
  structurally unpassable (recording happened AFTER scoring — iter-12 ESCALATE).
- **Change spec (landed):** (a) third depth token `evidence`
  (`CHAIN_EVIDENCE_MICRO_PATH`, default on): goal-iter-lean.sh skips
  developer/reviewer with honest stubs, runs browser-qa unchanged, and records
  the demo BEFORE returning; engine backstop demotes lean→evidence when every
  target journey is already recorded passing (telemetry
  `depth_evidence_override`); evaluator prompt gains deterministic
  `Prior walkthrough recording` + `Product diff this iteration` lines
  (judgment-eval mirror updated byte-for-byte). (b) methodology A.6 (evidence
  expires with CHANGE, not time; goal-edit drift always outranks durability;
  the no-screenshot rail keeps demanding a citation) + A.7 (`capture-defect`
  gap, `evidence_makeup` journey-history boolean mirroring `pending_infra`);
  read-list diet (plan.md dropped; audit/QA reports scoped to verdict blocks).
  (c) decomposer rubric rule 7: never plan an evidence-only iteration;
  anti-restatement rules (D6-safe); read-list diet.
- **DoD:** tests green (`test-evidence-depth.sh` 16 cases); judgment goldens
  6/6 evaluator cases on the configured model; one real session shows an
  evidence-class gap resolved in an `evidence` dispatch < 45 min.
- **Verify:** `bash tests/automation/test-evidence-depth.sh` ·
  `./scripts/automation/run-evals.sh` · judgment spot-run (G9).
- **Files:** `scripts/automation/run-goal.sh`, `goal-iter-lean.sh`,
  `lib/common.sh`, `run-judgment-evals.sh`, `agents/goal-evaluator/*`,
  `agents/goal-decomposer/*`, `skills/goal-evaluation-methodology.md`, mirrors.
- **Rollback:** `CHAIN_EVIDENCE_MICRO_PATH=false` (engine); body reverts + version.
- **Stop-and-ask:** any evaluator golden verdict-class flip (drift-beats-durability
  case-04 above all); a demo-less project needing more than the SKIPPED-stub path.

### SPEED-10 · Depth discipline — full-trigger allowlist + cadence 4→6
- **Priority:** P0 · **Effort:** M · **Risk:** LOW-MED · **Status:** IN-PROGRESS —
  implemented 2026-07-28 (58b93be); G8 certification pending.
- **Problem:** full depth (~90-120 min over lean) ran on 4 of the desk session's
  last 6 iterations; at most 2 were justified (one full pass existed to re-record
  a video).
- **Change spec (landed):** engine allowlist (`CHAIN_DEPTH_ALLOWLIST`, default
  on): a full spec stays full only on prior ESCALATE/REGRESSION, prior-iteration
  COHERENCE-FAIL, a machine-parseable `Full trigger: <1|2|3|4> — reason` line
  (decomposer contract, dc86b53), or cadence-due; otherwise demoted with
  `depth_demoted` telemetry. `CHAIN_HARDENING_CADENCE` default 4→6 (evidence
  dispatches continue the streak).
- **DoD:** `test-depth-cadence.sh` 23 cases green; first real session shows
  full-ratio ≤ 1-in-6 with no ESCALATE caused by a demoted full.
- **Verify:** `bash tests/automation/test-depth-cadence.sh` · run-evals.
- **Files:** `scripts/automation/run-goal.sh`, `lib/common.sh`,
  `agents/goal-decomposer/body.md`, tests.
- **Rollback:** `CHAIN_DEPTH_ALLOWLIST=false`; `CHAIN_HARDENING_CADENCE=4`.
- **Stop-and-ask:** a demoted-full iteration producing an ESCALATE in the first
  real session — report before tuning anything.
- **SUPERSEDED as the default (2026-07-29):** the desk session proved the
  allowlist's `Full trigger:` arm is self-certifying — the decomposer wrote a
  qualifying line into every spec and full ran 5-of-6 (anti-pattern 25).
  SPEED-20's deterministic arbiter is now the default path; this allowlist
  survives verbatim as the arbiter's PRIOR_DEPTH=full rung and as the
  `CHAIN_DEPTH_ARBITER=false` escape hatch.

### SPEED-11 · Lean replay-fork default flip (off→replay)
- **Priority:** P1 · **Effort:** S · **Risk:** LOW-MED · **Status:** IN-PROGRESS —
  implemented 2026-07-28 (58b93be); G8 certification pending.
- **Change spec (landed):** `CHAIN_LEAN_PARALLEL_BROWSER_QA` default off→replay
  (SPEED-2's fork: built, benchmarked, tripwired — 2-of-3 attempt-1 review FAILs
  auto-disable per session). Test scenarios pin `off` explicitly now. Recorded
  decisions: CAND-FULL-BQA-OVERLAP stays staged (post-SPEED-10 fulls too rare to
  justify the port); decomposer-N+1 ∥ evaluator-N overlap REJECTED (the
  decomposer consumes evaluator outputs).
- **Verify:** `bash tests/automation/test-goal-parallel-bqa.sh` (92 cases).
- **Rollback:** `CHAIN_LEAN_PARALLEL_BROWSER_QA=off`.
- **Stop-and-ask:** tripwire firing immediately in the first post-flip session.

### SPEED-12 · Dispatch/timeout hardening — busy cap, claim janitor, lanes, timeout table
- **Priority:** P1 · **Effort:** M · **Risk:** LOW-MED · **Status:** IN-PROGRESS —
  implemented 2026-07-28; G8 certification pending.
- **Problem:** iter-7 blocked 18h19m on an UNCLAIMED request while a dead pump's
  stale sibling `.started` kept the Tier-A wait unbounded
  (`lib/interactive-dispatch.sh` busy branch); 8 agents fell to the flat 7200s
  cap; showcase dispatches queued ahead of spine work.
- **Change spec (landed):** `_dispatch_claim_pump_dead` helper — provably-dead
  sibling claims cleared on the spot; `CHAIN_DISPATCH_PICKUP_BUSY_TIMEOUT`
  (default = flat inflight cap, 0=old unlimited) bounds the genuine-busy
  unclaimed wait resumably (`pickup-busy-timeout` event);
  `dispatch_channel_janitor` at the iteration boundary; per-agent timeout table
  filled for the full-pipeline chain (each ≥2.5× observed desk maxima);
  priority lanes — `req.<lane>-XXXXXX` filenames (`CHAIN_DISPATCH_LANE`,
  default 5; showcase tail exports 9) ride the pump's sorted glob with zero
  pump-side changes.
- **Verify:** `bash scripts/automation/lib/interactive-dispatch.sh --self-test`
  (23 cases incl. 4 new) · `goal-await-dispatch.sh --self-test` ·
  `python3 scripts/automation/lib/agent_permissions.py self-test`.
- **Files:** `lib/interactive-dispatch.sh`, `lib/agent_permissions.py`,
  `run-goal.sh`, `docs/goal-mode-interactive.md`.
- **Rollback:** `CHAIN_DISPATCH_PICKUP_BUSY_TIMEOUT=0`; unset
  `CHAIN_DISPATCH_LANE` semantics revert by deleting the two call-site exports;
  table rows are per-agent deletes.
- **Stop-and-ask:** a pickup-busy-timeout pause on a HEALTHY long dispatch in a
  real session (cap mis-sized) — report before raising it.

### SPEED-13 · Telemetry honesty — quota pauses, active vs wall, full-pipeline attribution
- **Priority:** P1 · **Effort:** M · **Risk:** LOW · **Status:** IN-PROGRESS —
  implemented 2026-07-28 (adf5f22); G8 certification pending.
- **Problem:** quota_pause_start/end documented + consumed but never emitted;
  `.quota-pause-count` had no increment site; quota sleeps inflated agent
  durations (the "18.7h evaluator"); full-depth iterations emitted zero
  per-agent events and rendered as 130-190m "unattributed (glue)".
- **Change spec (landed):** both events + counter bump at all four sleep sites in
  `lib/quota-retry.sh`; `agent_invocation_end` gains additive
  `quota_sleep_seconds`/`active_seconds`; all 16 phase-script dispatch sites
  wrap with `record_agent_invocation_start/end`; analyzer consumes `engine_step`
  events, prefers active seconds, renders an honest residual.
- **Verify:** `bash scripts/automation/lib/telemetry.sh test` ·
  `python3 scripts/automation/lib/analyze_telemetry.py --self-test`.
- **Rollback:** revert (additive fields; no behavior change).
- **Stop-and-ask:** none (measurement only).

### SPEED-14 · Zero-change iteration guards
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** IN-PROGRESS —
  implemented 2026-07-28 (58b93be); G8 certification pending.
- **Change spec (landed):** `goal_product_diff_empty` helper (fail-safe,
  bookkeeping-excluded); readme-maintainer's empty-change hole fixed (a
  zero-change iteration used to DISPATCH; the empty set now skips); coherence
  zero-change deterministic PASS with text DISTINCT from the crash stub —
  `goal_gate.py` certifies it (self-test pins both classifications); demo
  recording reused on an empty product diff. Knob `CHAIN_ZERO_CHANGE_SKIPS`,
  default on.
- **Verify:** `bash tests/automation/test-zero-change-guard.sh` (13 cases) ·
  `python3 scripts/automation/lib/goal_gate.py self-test`.
- **Rollback:** `CHAIN_ZERO_CHANGE_SKIPS=false` (readme hole fix stays — bug fix;
  its escape is the pre-existing `CHAIN_README_EVERY_ITER=true`).
- **Stop-and-ask:** none.

### SPEED-15 · Wall-clock iteration budget (armed by default: 3600s / trim)
- **Priority:** P0 (promoted from P2 by the desk 2h-floor evidence) ·
  **Effort:** M · **Risk:** MED · **Status:** IN-PROGRESS — slice (a) implemented
  2026-07-28 (warn-first); slice (b) + the default flip implemented 2026-07-29
  (iteration-shape package); G8 certification pending.
- **Change spec (landed 07-29):** **gate-default change, sanctioned by the
  user's 2026-07-29 iteration-shape task (maintenance-protocol §1); Dennis
  picked 3600s/trim explicitly.** Defaults `CHAIN_ITER_TIME_BUDGET_SECONDS`
  0→3600 and `CHAIN_ITER_BUDGET_MODE` warn→trim — the slice-(b) precondition
  ("one warn-mode session of telemetry first") is satisfied by the desk
  session's iters 15-18 (118-151 min productive, zero quota pauses). Trim
  ladder, in rung order, each with `iter_budget_trim{rung}` telemetry:
  rung 1 defer demo+README to the tail (existed); rung 2 browser-set narrowing —
  `replay_lane_deferred_budget_set` defers only the no-golden regression
  journeys (targets + replay-FAIL re-confirms NEVER cut), post-merge
  `DEFERRED-BUDGET` rows keep prior status per the evaluator contract
  (goal-evaluator body + methodology A), and `goal_gate.py results` blocks
  GOAL_ACHIEVED while any row is deferred; rung 3a skip test-plan generation
  when the spec carries TC- lines or a fresh plan exists; rung 3b skip
  ux-regression-reviewer with a SKIPPED (never FAIL) stub. `run-phase.sh` +
  `browser-qa-phase.sh` join the engine clock via `CHAIN_ITER_START_EPOCH`
  (standalone phase mode stays inert). Never-trim list grep-pinned:
  developer, reviewer, decomposer, evaluator, QA loop, audit, closure,
  deterministic gates, two-key confirm. A breach also forces the NEXT
  iteration lean via the `budget-breached` marker (SPEED-20 rung 3).
- **Verify:** `bash tests/automation/test-iter-budget.sh` (33 cases) ·
  `test-replay-lane.sh` (rung-2 cases) · `test-testplan-skip.sh` (rung-3a) ·
  `goal_gate.py self-test` (DEFERRED row blocks).
- **Rollback:** `CHAIN_ITER_TIME_BUDGET_SECONDS=0` disarms everything;
  `CHAIN_ITER_BUDGET_MODE=warn` keeps warnings only.
- **Stop-and-ask:** a DEFERRED-BUDGET journey turning out to be a REAL
  regression discovered late — bring the iteration, don't widen never-trim
  silently.

### SPEED-16 · Browser-qa turn diet
- **Priority:** P0 · **Effort:** S · **Risk:** LOW · **Status:** IN-PROGRESS —
  implemented 2026-07-28 (b33e21d); G8 certification pending.
- **Change spec (landed):** 2-attempt selector recovery budget then
  FAIL-with-evidence (a page that genuinely changed stays a recorded finding);
  ONE screenshot per test at the acceptance state (+1 on failure; triad
  deleted); all expected strings verified in ONE get_text; golden-first setup
  (replay `journey-scripts/` prefixes verbatim; judgment starts at NEW steps).
- **DoD:** post-session telemetry shows browser-qa ≤ 60 turns/invocation with
  no journey-status regressions vs the desk baseline.
- **Verify:** sync `--check` · run-evals · next-session telemetry (TOKEN-8 rows).
- **Rollback:** revert bodies + versions.
- **Stop-and-ask:** journeys flipping PASS→FAIL on recovery exhaustion — raise
  the cap to 3, never delete it.

### SPEED-17 · Deterministic phase-closure gate (LLM retired to an escape hatch)
- **Priority:** P1 · **Effort:** M · **Risk:** LOW-MED · **Status:** IN-PROGRESS —
  implemented 2026-07-28; G8 certification pending.
- **Problem:** the phase-closure-auditor LLM added no new judgment — Step 1
  re-read three already-gating verdicts; Steps 2-4 were existence/count/
  consistency checks. ~5 min + one LLM flake source per full iteration on a
  HARD gate.
- **Change spec (landed):** `scripts/automation/lib/closure_gate.py` writes the
  FROZEN CLOSURE-PASS/CLOSURE-FAIL format deterministically (verdict presence,
  6-UI-artifact existence + substance, ≥3 numbered what-to-click steps,
  all-SKIPPED with-reason ⇒ WARN / without ⇒ FAIL, backend-only inconsistency,
  objective vagueness BLOCKING / subtle vagueness WARN — policed upstream by
  qa's live audit and downstream by the evaluator's evidence walk);
  `phase-closure-check.sh` calls it; the agent dispatch survives behind
  `CHAIN_CLOSURE_LLM=true`.
- **Verify:** `python3 scripts/automation/lib/closure_gate.py self-test` ·
  `bash tests/automation/test-closure-gate.sh` · run-evals.
- **Rollback:** `CHAIN_CLOSURE_LLM=true` (single env).
- **Stop-and-ask:** a real session where the deterministic gate passes an
  artifact set the LLM would have failed for a SUBSTANTIVE reason — bring the
  case, don't widen the script silently.

### SPEED-18 · UI-evolution question dedupe (4 askers → 2)
- **Priority:** P1 · **Effort:** S · **Risk:** MED · **Status:** IN-PROGRESS —
  implemented 2026-07-28; G8 certification pending.
- **Problem:** "did the UI evolve / is it reachable" was asked FOUR times per
  full iteration (reviewer checklist, qa live audit, ux-regression Step 1,
  coherence Step 2).
- **Change spec (landed):** owners = qa's live UI Evolution Audit (browser +
  screenshots, gating) and coherence-auditor Step 2 (blueprint-grounded,
  objective FAIL, GOAL_ACHIEVED veto) — both UNCHANGED. Reviewer lost its three
  runtime-guess checklist items + the `ui_evolved_with_capability`/
  `navigation_updated` YAML keys (verified: no script parses them; auditor
  golden fixtures carry them only as frozen inputs). Ux-regression Step 1 now
  CONSUMES qa's audit + coherence.md and judges only what neither covers (label
  clarity, visual feedback, rendered consistency) + flags audit contradictions.
  D2 intact — all agents survive; only repeated questions were removed.
- **Verify:** reviewer judgment goldens 4/4 · sync `--check` · run-evals.
- **Rollback:** revert bodies + versions.
- **Stop-and-ask:** a reviewer golden verdict-class flip; a real-session UI miss
  only the deleted reviewer items would have caught ⇒ restore the first item only.

### SPEED-19 · Auditor risk-ranked spot-verification
- **Priority:** P1 · **Effort:** S-M · **Risk:** MED-HIGH · **Status:**
  IN-PROGRESS — implemented 2026-07-28; G8 certification pending.
- **Problem:** auditor Step 1 re-derived the full spec-compliance trace for
  EVERY DoD item — the third full pass over ground the reviewer (code) and QA
  (live rows) already covered (~202 min/session).
- **Change spec (landed):** full code trace when ANY of: (a) state/data/auth/
  money risk class; (b) artifact contradiction (the trigger even when QA is
  green — golden case-03's shape); (c) reviewer `spec_alignment: partial` or a
  spec-category issue; (d) the auditor's own Steps 2-4 leads. Mechanical items
  with reviewer PASS + an executed QA row: accepted WITH double citation; no
  citation ⇒ full trace. Steps 2-5, severity tree, fix authority untouched.
- **Verify:** auditor judgment goldens 4/4 (case-03 MUST still FAIL) · run-evals.
- **Rollback:** revert body + version (single hunk).
- **Stop-and-ask:** any auditor golden verdict-class flip ⇒ revert immediately.

### SPEED-20 · Deterministic depth arbiter — evaluator recommendation binding by default
- **Priority:** P0 · **Effort:** M · **Risk:** MED · **Status:** IN-PROGRESS —
  implemented 2026-07-29 (iteration-shape package); G8 certification pending.
- **Problem:** SPEED-10's allowlist trusted the spec's own `Full trigger:` line
  and the decomposer learned to write a trivially-true one (trigger 2 "adds a
  field to persisted record") into EVERY spec — desk iters 13-18 ran full 5 of
  6 against a PRE-registered target of ≤1-in-6, twice overriding an explicit
  evaluator `next_depth: evidence` recommendation (anti-pattern 25).
- **Change spec (landed):** engine ladder (`CHAIN_DEPTH_ARBITER`, default on,
  iter>0) replaces the allowlist for spec-requested fulls, precedence:
  prior ESCALATE/REGRESSION → full; prior COHERENCE-FAIL → full; prev-iteration
  `budget-breached` marker + CONTINUE → LEAN (SPEED-4 re-promotion suppressed
  that pass); cadence-due → full; full ran inside the
  `CHAIN_FULL_CADENCE_CAP` (default 4) window → LEAN (`full-cap`); evaluator
  recommended lean/evidence → full ONLY on `Full trigger:` line AND
  `goal_new_fullstack_journey` (backend+frontend bullets, real Data-contract
  additions, ≥1 never-implemented target; fail-closed python) else LEAN
  (`evaluator-requested-*`); evaluator recommended full → legacy allowlist.
  Grants/demotions telemetered (`depth_full_granted`/`depth_demoted`).
  Decomposer trigger 2 tightened to Data-model MIGRATION (purely additive is
  explicitly NOT the trigger); binding-recommendation language in body,
  self-check 4, and the engine prompt line. New helpers
  `goal_full_ran_in_window` + `goal_new_fullstack_journey` in `lib/common.sh`.
- **Verify:** `bash tests/automation/test-depth-arbiter.sh` (29 cases) ·
  `test-depth-cadence.sh` still green · run-evals.
- **Files:** `run-goal.sh`, `lib/common.sh`, `agents/goal-decomposer/*`, tests.
- **Rollback:** `CHAIN_DEPTH_ARBITER=false` (legacy SPEED-10 allowlist verbatim);
  `CHAIN_FULL_CADENCE_CAP=0` removes just the window cap.
- **Stop-and-ask:** a demoted full producing an ESCALATE, or the full ratio
  staying >1-in-4 over the next 6 real iterations (the PRE entry grades it).

### SPEED-21 · Golden auto-derivation from the verified demo
- **Priority:** P1 · **Effort:** M · **Risk:** LOW-MED · **Status:** IN-PROGRESS —
  implemented 2026-07-29 (iteration-shape package); G8 certification pending.
- **Problem:** goldens depend on the browser-qa agent's best-effort authoring —
  desk J-06 rode the slow LLM lane for 8 straight iterations because its golden
  never got written; goldens and demo scripts are the SAME runner format.
- **Change spec (landed):** `demo_runner.py --mode derive` (pure transform,
  fail-closed: demo must validate, ≥1 tagged step, derived sequence opens with
  goto, ≥1 tagged expect; writes `<J>.json.candidate`, always rc 0) +
  `replay_lane_autoderive_goldens` (gate `CHAIN_GOLDEN_AUTODERIVE`, default on;
  want = PASS-without-golden ∪ PASS∩`goldens-regen-pending`, cap
  `CHAIN_GOLDEN_AUTODERIVE_MAX`=3): each candidate gets a REAL verify pass in a
  throwaway scripts-dir against the live frontend — rc 0 → atomic install +
  `golden_autoderived`; rc 5 → discard (`golden_autoderive_rejected`); rc 6 →
  discard the batch. Hooked in `demo-phase.sh` after a GREEN record run of a
  goal iteration (services still up; both depths share the hook).
- **Verify:** `python3 scripts/automation/lib/demo_runner.py self-test`
  (`_t_derive_*`) · `bash tests/automation/test-golden-autoderive.sh` · run-evals.
- **Rollback:** `CHAIN_GOLDEN_AUTODERIVE=false`.
- **Stop-and-ask:** an auto-derived golden producing a verdict-class flip a
  hand-written golden would not have (bring the JSON pair).

### SPEED-22 · Mass-false-FAIL breaker — canary re-check before re-confirming the world
- **Priority:** P1 · **Effort:** M · **Risk:** MED · **Status:** IN-PROGRESS —
  implemented 2026-07-29 (iteration-shape package); G8 certification pending.
- **Problem:** desk iter-14's replay lane false-FAILed 8/9 journeys (selector
  drift after a UI change) and the LLM lane spent ~28 min re-confirming every
  one individually.
- **Change spec (landed):** in the shared lane, a >2-FAIL majority
  (2·n_fail > n_ran; 8/9 triggers, 2/9 and 3/6 do not) arms the breaker
  (`CHAIN_REPLAY_MASS_FAIL_BREAKER`, default on) — ONLY when
  `REPLAY_LANE_CANARY_CAPABLE=1` (set by goal-iter-lean.sh; the full pipeline
  is byte-identical). The lean lane dispatches the 2 lowest-ID FAILs as
  canaries first: both green → `merge_ui_test_results.py void` rewrites every
  listed FAIL row to SKIP + voided note, recomputes the headline, appends a
  dated loud footer; voided journeys queue in `goldens-regen-pending`
  (SPEED-21 re-derives them verified-green); `REPLAY_FAILED` cleared;
  `replay_mass_fail_voided`. Any canary FAIL or unusable canary file →
  conservative: today's re-confirm path for the remaining set +
  `replay_mass_fail_confirmed`. The canary results file rides the merge as a
  middle input either way; breaker state crosses the SPEED-2 fork via
  `_bqa_state_save`.
- **Verify:** `python3 scripts/automation/lib/merge_ui_test_results.py self-test`
  (void cases) · `bash tests/automation/test-replay-lane.sh` (cases 14-16) ·
  `test-goal-parallel-bqa.sh`.
- **Rollback:** `CHAIN_REPLAY_MASS_FAIL_BREAKER=false`.
- **Stop-and-ask:** a voided FAIL that was REAL (a canary passed while a
  sibling journey had genuinely regressed) — bring the evidence, do not widen
  the canary count silently.

### SPEED-23 · Bounded golden-coverage nudge (one required golden per iteration)
- **Priority:** P2 · **Effort:** S · **Risk:** LOW · **Status:** IN-PROGRESS —
  implemented 2026-07-29 (iteration-shape package); G8 certification pending.
- **Problem:** golden authoring is best-effort by design, so a journey can ride
  the slow LLM lane indefinitely (J-06: 8 iterations) — nothing ever escalates
  one specific golden to "required".
- **Change spec (landed):** `replay_lane_golden_coverage` now persists the gap
  list to `state/golden-gaps`; `replay_lane_golden_nudge_pick` (gate
  `CHAIN_GOLDEN_NUDGE`, default on) picks ONE gap∩LLM-set journey per
  iteration — min nudge-count rotation persisted in `state/golden-nudge.json` —
  and both browser-qa prompts (lean + full) carry it as an explicit REQUIRED
  DELIVERABLE line; `golden_nudge` telemetry.
- **Verify:** `bash tests/automation/test-golden-autoderive.sh` (cases 7-9).
- **Rollback:** `CHAIN_GOLDEN_NUDGE=false`.
- **Stop-and-ask:** none (one journey per dispatch is the bound).

### SPEED-24 · Combined UI dispatch — ui-impact + ui-test-design in one agent call
- **Priority:** P1 · **Effort:** M · **Risk:** MED · **Status:** IN-PROGRESS —
  implemented 2026-07-29 (iteration-shape package); G8 certification pending.
- **Problem:** the designer's ONLY inputs are exactly the analyst's outputs —
  a second sequential dispatch buys a fresh context (and ~13-17 min per full),
  not a second opinion.
- **Change spec (landed):** goal-mode full iterations only (gate
  `CHAIN_UI_COMBINED`, default on): Branch-A dispatches ui-impact with
  `CHAIN_UI_COMBINED_DISPATCH=1` — the analyst's new `## Combined mode` section
  writes all FOUR artifacts (same names/templates/skills); the phase script's
  failure stubs still cover only the two impact artifacts, so combined
  under-delivery (plan or what-to-click missing/empty) falls back LOUDLY to the
  separate ui-test-design dispatch (browser-qa hard-errors without a plan).
  ui-test-designer agent untouched (phase mode + fallback); closure gate
  unchanged (all four names still checked) = the quality net.
- **Verify:** `bash tests/automation/test-ui-combined.sh` (18 cases: combined
  skips designer / under-delivery fallback / knob-off / plain phase unchanged).
- **Rollback:** `CHAIN_UI_COMBINED=false`.
- **Stop-and-ask:** closure-gate FAILs on combined-authored plan/click quality
  that the standalone designer did not produce ⇒ report before tuning prompts.

### TOKEN-1 · Per-agent project-template slicing
- **Priority:** P1 · **Effort:** M · **Risk:** LOW · **Status:** DONE 2026-07-14 —
  release-manager/reviewer/qa converted; developer conversion deliberately LAST per this
  entry; auditor untouched. G8 fresh-session certification 2026-07-14 (non-implementer):
  offline half green — slice contract test 18/18 incl. the production↔builder mirror
  gate, full run-evals 99/99, sync --check clean, slice-sufficiency re-read of all
  three bodies vs the map confirmed with one recorded borderline (reviewer map omits
  DATA MODEL RULES — defensible: its checklist never cites that section; the developer,
  who writes the data code, still gets the full file); M1 reviewer fixtures RE-RUN
  fresh-eyes: 4/4 classes hold (PASS / PASS_WITH_NOTES / FAIL / FAIL, 99/178/131/219s,
  sonnet-tier, `run-judgment-evals.sh --yes-spend --judge reviewer`). DoD telemetry
  delivered by §9 run A′ (`bench-20260714-0634` vs the 20260712 baseline, like-for-like
  lean iter-0 rows): CONVERTED reviewer DOWN every axis — cache_creation 45,095→43,182
  (−4.2%, −1,913 tok ≈ the ~180-line Read replaced by the 56-line slice), cache_read
  −15.4%, turns 22→19, cost $0.889→$0.759 (−14.6%) — while the UNCONVERTED developer
  (falsification control) moved OPPOSITE (+26.8% cache_creation, +27.7% cost), so the
  reviewer drop is not ambient drift. RECORDED GAP: qa telemetry INCONCLUSIVE (its
  cache_creation reads 129.7k/96.3k/133.0k across three runs — ±25% workflow noise
  around a ~2k mechanism; direction claim from run A did NOT replicate); release-manager
  + full-depth reviewer/qa rows unmeasurable until the *-phase.sh telemetry blind spot
  is closed (those scripts record no usage rows) or a real session covers them. The
  static mechanism (slice inlined, full-file Read instruction removed) is
  eval-pinned regardless.
  Reviewer judgment fixtures RE-RUN post-slice (G9-approved 2026-07-13): 4/4 verdict
  classes hold under the new pre-sliced prompt (case-01 PASS, case-02 PASS_WITH_NOTES,
  case-03 FAIL, case-04 FAIL — 141/170/199/226s, sonnet-tier,
  `run-judgment-evals.sh --yes-spend --judge reviewer`).
  *Implementation note (2026-07-13):* helper `project_template_slice <agent> [template]`
  + the AGENT→sections map beside it in `scripts/automation/lib/common.sh`. Map
  (adjusted from this entry's initial guess after reading the bodies): release-manager →
  GIT WORKFLOW (branch naming + PR title format + never-commit are ALL its
  template-sourced duties); reviewer → ARCHITECTURE PRINCIPLES + DESIGN SYSTEM (its
  UI-quality checklist verifies components/tokens/effects against it) + TEST COMMANDS;
  qa → STACK (service URLs + frontend flag) + TEST COMMANDS + SERVICE START COMMANDS.
  Semantics: verbatim `##`-section chunks in map order; a mapped section missing from
  the template → loud inline `[slice: section 'X' not found …]` marker (never silent);
  unknown agent → full file + one stderr diagnostic (safe fallback for
  developer/auditor); missing template file → loud marker; always rc 0 (prompts embed
  it via `$(...)` under `set -e`). Sites converted (the "read this" line → inlined
  four-backtick-fenced slice labeled "Project template (relevant sections,
  pre-sliced):"): `finalize-phase.sh` (release-manager; step-2 never-commit wording now
  points at the inlined GIT WORKFLOW), `qa-phase.sh` (qa), `review-phase.sh` and
  `goal-iter-lean.sh` `run_reviewer` (reviewer). The three `body.md`s now say the
  pre-sliced sections in the dispatch prompt are authoritative — do not Read the full
  file (`agent.yaml` bumps: reviewer 1.2.0, qa 1.2.0, release-manager 1.1.0; mirrors
  re-rendered). THE MIRROR: `run-judgment-evals.sh` `_prepare_reviewer` inlines the
  slice via the SAME helper over the sandbox's `.claude/project-template.md` — factual
  correction to this entry: the fixture trees carry NO `.claude/`; the sandbox reaches
  the framework's own template through the runner's read-only-asset symlink, so
  mirroring works with fixtures untouched. NEW GATE:
  `tests/automation/test-project-template-slice.sh` (run-evals §2c → 99/99; 18 asserts)
  pins the slice contract (exact-match fixture slices, map order, fallback, both loud
  markers, real-template map sufficiency incl. the never-commit canary) AND
  extracts+normalizes the production `run_reviewer` prompt vs the judgment builder's
  heredoc — the verbatim-mirror invariant is now a failing eval, not a convention
  (the gate was validated green on the PRE-change prompt pair first). Benchmark
  fixture's filled template slices clean for all three agents (release-manager 14 /
  qa 51 / reviewer 56 lines vs the ~180-line full file), so the §9 measurement run
  needs no fixture edits.  *(absorbed: README Token-Opt Tier-1 polish)*
- **Problem:** every agent that reads `.claude/project-template.md` reads all of it;
  release-manager needs ~5 lines (never-commit list), developer needs most.
- **Current state:** agents told to read the whole file; helper-slicing deferred in old
  README with "until measured token win is meaningful".
- **Change spec:** helper in `lib/common.sh` (e.g. `project_template_slice <agent>`)
  emitting the per-agent section set (map maintained next to the helper); dispatch
  wrappers inline the slice instead of instructing a full read; agents' bodies updated
  to reference the inlined slice. Do developer LAST (it needs most sections; least win).
- **DoD:** slices inlined for release-manager, reviewer, qa first; token telemetry
  before/after on one session or benchmark; evals green.
- **Verify:** `bash -n scripts/automation/lib/common.sh &&
  ./scripts/automation/run-evals.sh` + telemetry comparison.
- **Files:** `scripts/automation/lib/common.sh`, dispatch call sites, affected
  `agents/*/body.md` + versions, mirrors.
- **Rollback:** wrappers fall back to "read the file" instruction.
- **Trigger:** telemetry shows template reads are a measurable share of input tokens.

### TOKEN-2 · Tier experiment: goal-decomposer strong→standard
- **Priority:** P1 · **Effort:** S · **Risk:** MED · **Status:** DONE
  (**ADOPTED 2026-07-16, user-confirmed** — experiment ran 2026-07-15→16 on branch
  `experiment/token-2-decomposer-standard` under the user-approved G1 spend session
  and merged on the explicit ADOPT confirm; the decomposer now runs the standard
  tier with effort max; judges unchanged on strong; single-line rollback stands)
  *(absorbed: README Token-Opt Tier-2; the orchestrator half is already DONE —
  see §17 ledger)*
- **Problem:** the decomposer runs on the strong tier every iteration; spec-writing may
  be within standard-tier reach now that it receives the goal slice + journey digest.
- **Current state (post-adopt):** `agents/goal-decomposer/agent.yaml`
  `model_tier: standard` (v2.0.0, adopted 2026-07-16); goal-evaluator stays strong
  (adversarial judgment — old README said the same); judge-effort guard (D4)
  unchanged and still covers the decomposer.
- **Blast-radius proof (2026-07-15, on the experiment branch):**
  `agent_permissions.py model/effort` across all 20 agents, before vs after the flip
  + resync — exactly one row changed: goal-decomposer `claude-opus-4-8 → claude-sonnet-5`
  (effort stays `max`). goal-evaluator/auditor/goal-proposer/reviewer unchanged at their
  tiers; D4 intact (goal-decomposer remains in `JUDGE_AGENTS`, so `CHAIN_AGENT_EFFORT`
  still refuses it; `agent_permissions.py` untouched by the flip). Evals 111/111 post-flip.
- **REL-1 fixtures on the flipped branch (2026-07-15): 5/5 PASS** — goal-evaluator
  judge resolved unchanged (claude-opus-4-8 @ max) and every verdict class landed
  exact (GOAL_ACHIEVED/CONTINUE/REGRESSION/CONTINUE/REGRESSION, 244–316s/case, in
  line with the 2026-07-09 baseline timings). Config-surface regression insurance
  green; no revert trigger. (Runner does not instrument case cost by design;
  pre-estimate $11.90 ±3x, durations match the in-band 07-09 run.)
- **EVO-3 benchmark on the flipped branch (2026-07-16, `bench-20260716-0626` @
  d41a38bcfb4f vs control run C `bench-20260714-1539`): all pre-committed adopt
  criteria measured.** GOAL_ACHIEVED, journeys 3/3 (predicate CONFIRMED), zero
  attempt-1 review fails, COHERENCE-PASS, two-key confirm passed. Decomposer
  per-agent: $3.591 → **$2.184 (−39.2%)**, out-tok −19.5%, duration −30%;
  routing proven (engine.log "model=claude-sonnet-5" on Step 1; by_model: opus
  billed exactly the evaluator's 3 calls). Session total $20.84 → $21.15
  (+1.5% ≈ flat, with E's telemetry coverage MORE complete than C's); wall
  −15.1%. Spec-quality comparative reading: outcome-equal, artifact-thinner
  (no DOM-contract table; goal.md's J-02→J-03 state contradiction left to
  executor pragmatics where C defused it in-spec; the /api-routes IA reading
  shipped unledgered — though the unchanged opus evaluator + coherence audit
  examined and passed that architecture explicitly). Developer row +64% inside
  the flat total — part noise (±25% band), part plausible spec-thinness cost
  shift; fixture cannot decompose further. Full graded assessment: the POST in
  `benchmarks/experiments.md`. **Decision: ADOPT — user-confirmed 2026-07-16;
  branch merged to main.** Watch item for real sessions: if decomposer spec
  quality shows pain live (unledgered interpretation calls, downstream developer
  cost inflation, review fails traceable to spec gaps), the rollback is the
  single `model_tier` line + resync (this entry's Rollback), and the evidence
  here is the before/after baseline.
- **Change spec:** flip `model_tier` to `standard` on a branch; run EVO-3 benchmark +
  REL-1 judgment fixtures before/after; adopt only if spec quality (fixture pass +
  benchmark journeys/iteration) holds. Model-spend class → user approval first (G1).
- **DoD:** decision recorded here with evidence either way (adopt or revert+STALE).
- **Verify:** REL-1 fixtures + EVO-3 compare.
- **Files:** `agents/goal-decomposer/agent.yaml`, mirrors.
- **Rollback:** flip back; single-line change.
- **Stop-and-ask:** user approval BEFORE flipping (spend class); and if fixtures
  regress, revert — do not "tune the prompt to make it pass".
- **Trigger:** decomposer cost is a top-3 line in per-agent telemetry.

### TOKEN-3 · Skip test-plan generation when the spec already lists tests
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** IN-PROGRESS —
  mechanics landed + sandbox-proven 2026-07-16; **default flipped `true`
  2026-07-29** (iteration-shape package; gate-default change sanctioned by the
  user's task per maintenance-protocol §1 — the pre-registered "one observed
  clean full-mode phase" evidence is the desk session's clean full iterations
  15-18). A SECOND arm landed with the flip: an existing generated plan that is
  non-empty, has ≥3 `TC-` lines, and is NEWER than the spec also skips
  (per-iteration filenames make cross-iteration staleness structurally
  impossible); the log names which arm matched. G8 certification pending.
  *(absorbed: README Token-Opt Tier-2)*
- **Problem:** full-mode Step 2 generates a functional test plan even when the phase
  spec already contains explicit test scenarios — a wasted dispatch.
- **Current state (post-flip, 2026-07-29):** `run-phase.sh` Step 2 gates the
  generator dispatch behind `CHAIN_SKIP_TESTPLAN_IF_PRESENT`, **default `true`**
  (`false` = the rollback to always-generate; a match → dispatch skipped with ONE
  loud log line naming the matched arm, checkpoint still advances to
  `test_plan_generated`). Two arms: (1) heuristic `_spec_lists_tests_reason()` —
  word-bounded `## Test`-titled section (`## Tests`, `## Test Scenarios`,
  `## Test Plan` — deliberately NOT the boilerplate `## TESTING REQUIREMENTS`
  heading, which `templates/phase-spec.md` ships in every spec while its comment
  says the generator is still expected to run) OR ≥3 `TC-` test-case lines (the
  decomposer TC- scenario contract, REL-9); (2) an existing generated plan that
  is non-empty, has ≥3 `TC-` lines, and is NEWER than the spec.
- **Change spec:** deterministic heuristic (spec contains a `## Test` section or ≥3
  `TC-` lines, or a fresh generated plan exists) → skip generation and note the skip
  in the run log; NEVER skip silently. ✅ shipped, including the default flip.
- **DoD:** sandbox phase with tests-in-spec skips with a logged reason; phase without
  them generates as today; evals green. ✅ *Sandbox half met 2026-07-16, extended
  2026-07-29:* `tests/automation/test-testplan-skip.sh` (30 assertions; full stubbed
  run-phase.sh pipeline runs: heading-skip + TC-skip with logged reasons and zero
  generator dispatches on the canary, plain spec generates as today, knob unset
  now SKIPS (the flip) while knob=false generates (the rollback), fresh-plan arm
  skips while a stale plan generates, `## TESTING REQUIREMENTS` boilerplate does
  NOT suppress). ✅ *Default flip landed 2026-07-29* (iteration-shape package;
  evidence = the desk session's clean full iterations 15-18).
  *Coupling note (2026-07-16):* REL-9 landed — the decomposer template now
  CONTRACTS ≥1 TC- scenario line per DoD checkbox (≥3 in any real spec), so
  specs meeting the TC- heuristic become the norm rather than the exception;
  the observed-clean-phase precondition is reachable at the next full-depth
  phase run with `CHAIN_SKIP_TESTPLAN_IF_PRESENT=true`.
- **Verify:** `bash -n scripts/automation/run-phase.sh && ./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/run-phase.sh`, `tests/automation/test-testplan-skip.sh`.
- **Rollback:** knob.

### TOKEN-4 · Cap the audit-failure full-rerun
- **Priority:** P1 · **Effort:** S · **Risk:** MED · **Status:** DONE
  (landed + sandbox-proven 2026-07-16; the DoD is fully sandbox-satisfiable and met.
  **Ships default cap=1 by design — deliberately NOT G4 default-off:** the entry
  itself specifies `CHAIN_AUDIT_RERUN_CAP=1`; this is a cost guard with a tested
  one-knob rollback (`cap=0` = exact pre-cap behavior) rather than a behavior
  experiment, and the Stop-and-ask below carries the explicit revert trigger. Do
  not relitigate the default.) *(absorbed: README Token-Opt Tier-2)*
- **Problem:** on audit FAIL, the hardening loop (`run-phase.sh`, Step 9 —
  the loop moves; grep "Post-phase audit loop", `MAX_AUDIT_RETRIES=3`) re-ran
  developer + reviewer + full QA on EVERY failed attempt — the most expensive retry
  in the pipeline. (The old README cited `:649-679`; verified moved 2026-07-06 and
  again 2026-07-16.)
- **Current state (post-change):** the loop picks a hardening mode per failed
  attempt, loudly logged: FULL-RERUN (dev + review + full QA) until
  `CHAIN_AUDIT_RERUN_CAP` COMPLETED full passes are spent (default `1`;
  quota-interrupted QA does not spend the cap), then FIX-ONLY (dev + review +
  audit re-check, NO full QA rerun). Identical in both modes: strong-tier dev
  escalation (`escalate_model_on`) and the `audit_qa_failed` hard-fail whenever
  full-mode QA runs and fails. The counter is per-run (in-memory): a human resume
  from `audit_failed` re-earns one full rerun; `MAX_AUDIT_RETRIES=3` still bounds
  total attempts.
- **Change spec:** after the FIRST full rerun, subsequent audit FAILs in the same phase
  switch to fix-only mode (developer fix + reviewer + audit re-check, no full QA rerun),
  logged. Knob `CHAIN_AUDIT_RERUN_CAP=1`.
- **DoD:** sandbox test of the audit-fail path shows the cap; evals green. ✅
  2026-07-16: `tests/automation/test-audit-rerun-cap.sh` (17 assertions driving the
  real run-phase.sh Step-9 loop from an `audit_failed` checkpoint with stubbed step
  scripts + dispatch canary: attempt 1 hardens FULL, attempt 2+ hardens FIX-ONLY
  with zero QA dispatches; `cap=0` restores full reruns every attempt; escalation
  env visible to dev in both modes; `audit_qa_failed` and `audit_failed` exhaustion
  paths unchanged). Evals green (113).
- **Verify:** `bash tests/automation/test-audit-rerun-cap.sh && ./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/run-phase.sh`, `tests/automation/test-audit-rerun-cap.sh`.
- **Rollback:** knob (`CHAIN_AUDIT_RERUN_CAP=0` → old behavior; covered by test case B).
- **Stop-and-ask (STILL LIVE — the revert trigger):** if telemetry shows audits
  legitimately need full reruns (fix-only passes audit but phases ship bugs), revert
  to `cap=0` and mark this STALE with evidence.
- **Trigger:** telemetry shows the audit-fail full-rerun firing more than rarely.

### TOKEN-5 · Interactive pump token-usage telemetry
- **Priority:** P1 · **Effort:** M · **Risk:** MED · **Status:** IN-PROGRESS *(2026-07-16:
  contract + engine parse + extraction recipe shipped, evals green. Same day, G8: offline
  half CERTIFIED by a fresh non-implementer session — dispatch self-tests 9–12 green
  (valid/absent/malformed×2/analyzer-mix), claude sync --check + 113/113 evals green, and
  the extraction recipe reproduced live on the certifying session's own transcript: the
  recipe's jq and an independent python sum agree on all four token fields (13 msgs;
  dedupe by `message.id` is load-bearing — the naive sum over the same 47 raw rows
  inflates output ~4×), and re-running the recipe fresh on the original probe artifact
  `agent-af4c552` reproduces the recorded totals exactly (16 msgs → 4,915 / 44,823 /
  563,877 / 67,486). Restart rule confirmed documented in the skill's protocol-v2 header.
  Remaining for DONE: first REAL pump session showing `claude_usage` rows — requires a
  pump started after this change, per the restart rule)*
- **Feasibility finding (2026-07-16 — Outcome A, a real path EXISTS):** a pump session
  CAN obtain per-dispatch token counts zero-spend from its own Claude Code transcript
  (verified live on CLI 2.1.205/2.1.206): `CLAUDE_CODE_SESSION_ID` is exported to Bash
  tool calls, and `~/.claude/projects/*/<sid>.jsonl` exists for the running session.
  Each Task dispatch leaves a parent-transcript `toolUseResult` row (`{agentId,
  agentType, resolvedModel, totalDurationMs, ...}`) plus a subagent transcript
  `<sid>/subagents/agent-<agentId>.jsonl`; summing its per-message `usage` rows
  deduped by `message.id` (streaming snapshots repeat ids) yields the dispatch totals
  — recipe output cross-checked by an independent Python sum (agent af4c552: 16 msgs →
  input 4,915 / output 44,823 / cache-read 563,877 / cache-create 67,486) and accepted
  by the engine validator. CAUTION (encoded in the skill): `toolUseResult.usage` /
  `totalTokens` is a final-API-call snapshot — verified equal to the subagent
  transcript's LAST row — NOT the dispatch total; headless sidecar semantics are
  run-cumulative (real rows: 46 turns → 90,865 output; 556 turns → 149,017 output), so
  the transcript SUM is the matching semantics. Other surfaces: OTEL env unset, no
  `~/.claude` cost files, Task tool_result text carries no counts — the transcript is
  the ONLY pump-accessible surface. Interactive dispatches expose no USD cost → events
  omit `total_cost_usd` (absence = unknown; never estimated).
- **Problem:** interactive (pump) sessions record NO token usage — documented gap
  (`docs/goal-mode-telemetry.md:133`) — so all cost work is blind in interactive mode.
- **Current state (shipped by this item):** pump protocol v2 — request JSON carries
  `usage_path` (idiom of `out`); pump writes a sidecar-shaped usage JSON before `.res`;
  `_interactive_invoke` validates it (all four token fields non-negative numbers;
  malformed → ONE warn + skip, never fatal) and reuses `record_claude_usage_from_sidecar`
  → byte-identical `claude_usage` event shape, `analyze_telemetry.py` UNCHANGED (proved
  by dispatch self-test 12's mixed pump+headless fixture); the validated sidecar also
  enriches `trace.jsonl` via the existing recorder sidecar arg. Absent sidecar =
  byte-identical v1 flow. Skill `version: 2.0.0` + recipe + running-pump-restart rule
  (letter). Additive protocol composes with REL-3 (pid/host live in heartbeat/claim
  files, not the usage sidecar).
- **DoD:** with a stub pump writing the field, telemetry shows usage events; without
  it, no errors; evals green — met (dispatch self-tests 9–12). NOT yet stub-free: a
  real `/goal` pump session must show usage rows before DONE (G8).
- **Verify:** `bash scripts/automation/lib/interactive-dispatch.sh --self-test` +
  `./scripts/automation/run-evals.sh`; then live: any post-restart `/goal` session →
  `python3 scripts/automation/lib/analyze_telemetry.py runs/goal-session-<sid>/telemetry.jsonl`
  shows per-agent token rows.
- **Files:** `skills/goal-interactive-dispatch.md` (+ mirror + version),
  `scripts/automation/lib/interactive-dispatch.sh`,
  `scripts/automation/goal-await-dispatch.sh`, `docs/goal-mode-telemetry.md`,
  `docs/goal-mode-interactive.md`, `.claude/architecture/goal-mode.md`.
- **Rollback:** engine tolerates the field's absence by design; revert engine parse.
- **Stop-and-ask:** if the pump genuinely cannot access its own usage numbers, record
  that finding here and mark STALE — do not fake estimates. *(Probed 2026-07-16: it
  can — see Feasibility finding. The no-fabrication rule is now enforced in the skill's
  HONESTY RULE and the engine's skip-on-invalid.)*

### TOKEN-6 · Condensation helper for append-only state files
- **Priority:** P1 · **Effort:** M · **Risk:** LOW · **Status:** IN-PROGRESS *(2026-07-16:
  helper + warn-only session-start wiring + protocol §4 cross-ref shipped, 9-case
  self-test written RED first, wired into run-evals; remaining: G8 fresh-session
  certification, and the first real session start with a >200-line lessons.md /
  assumptions.md is the live proof of the wiring. `.claude/anti-patterns.md` (321 lines,
  over budget) is deliberately NOT condensed by the engine — protocol §4.4 documents the
  human-triggered `--human` command and dedicated-commit rule for it)*
- **Problem:** maintenance protocol §4 mandates condensing knowledge files at ~200
  lines, but no mechanism exists (verified) — they grow until someone notices prompt
  bloat.
- **Current state (shipped by this item):** `scripts/automation/lib/condense.sh` —
  deterministic-only (no model calls ever): entries = unfenced `## ` blocks keyed by
  `iter-<N>` / `Iteration <N>` / `<N>.` (the shipped §2 formats); blocks outside the
  newest K distinct keys (default 5; `--keep` / `CHAIN_CONDENSE_KEEP_ITERS`) move
  VERBATIM to `<file>.archive.md` (append-only, header on creation); §2 rule-class
  lines (`**Rule:**`/`**Prevention:**`/`**Applies to:**`/`**AGENT RULE …:**` +
  continuations) stay live under a `[condensed:]` heading stub; keyless headings and
  malformed lines are kept in place with one warning; fenced `## `/rule text is
  content, not boundaries. Threshold `--min-lines` default 200 (§4). Guards
  (structural): paths under `.claude/` refused without `--human`;
  `evaluator-log.md`/`journey-history.json` always refused (§4.3). Idempotent —
  second run moves nothing. Engine wiring: `run-goal.sh` session start, one warn-only
  call per session state file (`lessons.md`, `assumptions.md`) over 200 lines behind
  `CHAIN_AUTO_CONDENSE` (default true), logging one line per condensed file. Files
  before this item: manual-only; affected: `runs/.../state/lessons.md`,
  `assumptions.md` (NEED-5), `.claude/anti-patterns.md` (already over budget).
- **Change spec:** deterministic-first: `scripts/automation/lib/condense.sh <file>` —
  moves entries older than the newest K iterations to `<file>.archive.md` beside it,
  preserving any line matching the "rule" format; prints a summary. Engine calls it
  warn-only at session start for session files over 200 lines (knob
  `CHAIN_AUTO_CONDENSE`, default `true` for session files, NEVER for `.claude/` files —
  those stay human-triggered per protocol §4's dedicated-commit rule). LLM-based
  semantic condensation explicitly NOT included (risk of losing rules).
- **DoD:** self-test with a fixture file; session-start wiring warn-only; anti-patterns
  condensation left to a human-triggered run documented in the protocol.
- **Verify:** `bash scripts/automation/lib/condense.sh --self-test &&
  ./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/lib/condense.sh` (new),
  `scripts/automation/run-goal.sh` (1 call), protocol cross-ref.
- **Rollback:** knob; archives are additive.

### TOKEN-7 · Pre-baked review packet (reviewer stops running git)
- **Priority:** P1 · **Effort:** M · **Risk:** MED · **Status:** DONE
  (implemented + fixtures 4/4 + measured 2026-07-16 @ 13668f305963; **G8-certified
  DONE 2026-07-16 by a fresh session @ 3331f97** — reproduced, not re-trusted:
  test-review-packet 20/20 + parallel-bqa 80/80 + checkpoints 11/11 + sync --check
  clean + run-evals 116/116; build_review_packet, both dispatch prompts, the
  reviewer body and the judgment-runner mirror read against the change spec
  (`$REVIEW_PACKET` spelled identically both sides; the byte-gate's four sanctioned
  renames unchanged); both stop-and-ask orderings re-confirmed in code with the
  measurement note's line anchors corrected — build 1 at `goal-iter-lean.sh:900`
  BEFORE both fork spawns (`:928`/`:967`), fix-path rebuild `:1029` after the reaps
  (`:1006-1007`) + `escalate_model_off` (`:1020`); economics re-derived from the
  results JSONs + both kept scratches' per-invocation telemetry — every raw figure
  exact, one derived-percentage slip corrected in the verdict below (real-review
  wall 220.6→186.9s = −15.3%, not the ledger's −15.5%); packet files verified in
  the kept scratch (iter-0 412B lean, iter-1 11,424B phase-mode; exactly 2
  runtime "review packet built" lines, 0 "build failed"))
- **Source:** Superpowers 6 release notes (primeradiant.com/blog/2026/superpowers-6.html):
  pre-generated diff packages cut review tokens + wall ≈10% on THEIR benchmark — treat
  as hypothesis here, measure per G8. Anchors verified 2026-07-07 @ `eb5c8f9`.
  *Replication verdict (2026-07-16, `bench-20260716-1436` vs run E, full POST in
  benchmarks/experiments.md):* their number REPLICATED in direction with the metric
  RELOCATED — the packet does not cut reviewer OUTPUT tokens (≈ flat; null vs their
  ~10% at this fixture's noise band) but collapses TURNS (37→24 session, −35%) and
  therefore BILLED INPUT (cache-read −67% on the real review round) and COST
  (reviewer −24.3% session, −27.1% real review); real-review wall −15.3% (in line
  with their ~10%; the ledger POST's −15.5% was a derived-percentage slip — raw
  220.6→186.9s, corrected here at G8 certification), session reviewer wall ≈ flat.
  Their claim, our data: direction right; size understated on billed input,
  overstated on output tokens.
- **Problem:** the reviewer (~21 min, 2nd-longest lean step) receives only a two-command
  HINT and shells out to git itself — every review pays tool-call round trips for a
  diff the engine could pre-build deterministically.
- **Current state:** hint built by `review_diff_hint()`
  (`scripts/automation/lib/common.sh:377-388`; exclude patterns
  `REVIEW_DIFF_EXCLUDE_PATTERNS` `:366-371`), inlined at `goal-iter-lean.sh:158`
  (dispatch block `:149-170`), `review-phase.sh:38`, and the coherence dispatch
  `common.sh:420`. The packet mechanism ALREADY EXISTS:
  `goal_gate_build_diff_artifacts` (`lib/goal-gates.sh:45-73`) builds bounded
  `iter-<N>/iter-diff.md` via `diff_bound.py` (hunks capped, noise excluded,
  truncations NAMED in its header, untracked files capped at 200) — but only AFTER
  review settles (`goal-iter-lean.sh:277-278`, inside the coherence fork; evaluator
  copy rebuilt at `run-goal.sh:1470`). The coherence-auditor already consumes it
  packet-first (`common.sh:418`). The reviewer body tells the agent to run git itself
  and asserts the work under review is UNCOMMITTED at review time
  (`agents/reviewer/body.md:16`).
- **Change spec:**
  1. New `build_review_packet <out-file> <base-ref>` in `lib/common.sh` beside
     `review_diff_hint`: run `diff_bound.py` with the SAME
     `REVIEW_DIFF_EXCLUDE_PATTERNS`, then append a `--stat` section of ONLY the
     excluded paths (lockfile changes stay visible). Do NOT reuse
     `goal_gate_build_diff_artifacts` (different consumer + timing; gate artifacts
     stay untouched).
  2. Lean path: call it after the developer step completes, before the first
     `run_reviewer` (`goal-iter-lean.sh:~143`), writing `$ITER_DIR/review-packet.md`.
     **Rebuild after EVERY fix-mode developer pass** (after `escalate_model_off`,
     `goal-iter-lean.sh:~226`, before the next reviewer round) — a round-2 reviewer
     must never read a stale packet.
  3. Reviewer dispatch (`goal-iter-lean.sh:149-170`): add above the hint line:
     "Bounded diff packet (read FIRST if present): <path> — hunks capped, noise
     excluded, truncations NAMED. The iter spec + dev handoff remain required
     reading — never verdict from the diff alone (D7)." KEEP the `review_diff_hint`
     line but reframe: "run these only for files the packet marks truncated."
     (Mirrors the coherence precedent `common.sh:418-420`; absent packet degrades to
     today's behavior.)
  4. Phase mode: same packet build before the review step, writing
     `runs/<phase>/review-packet.md`, + the same prompt edit at
     `review-phase.sh:37-38`.
  5. `agents/reviewer/body.md:16`: packet-first; git only for truncation follow-ups.
     UNCHANGED: "read each changed source file" (anti-pattern #12 — the packet
     replaces running diff COMMANDS, never reading code) and the spec/handoff input
     list (D7). Version-bump `agent.yaml` 1.1.2→1.1.3, resync mirrors, commit
     together (G2).
  6. Eval fixture (G3 — new artifact contract): assert `build_review_packet` output
     header names the base ref and truncation markers; register in `run-evals.sh`.
  7. Measure per G8 (pre-register per EVO-3's ledger once it exists): reviewer
     wall/output tokens before/after via `analyze_telemetry.py` per-agent rows.
- **DoD:** packet built pre-review and rebuilt post-fix in lean; phase-mode packet
  built; both dispatch prompts + body are packet-first; absent packet degrades to
  hint-only; fixture + evals green.
- **Verify:** `bash -n scripts/automation/goal-iter-lean.sh
  scripts/automation/review-phase.sh && bash tests/automation/test-goal-checkpoints.sh
  && python3 scripts/automation/sync-cli-assets.py --cli claude --check &&
  ./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/lib/common.sh`, `scripts/automation/goal-iter-lean.sh`,
  `scripts/automation/review-phase.sh`, `agents/reviewer/body.md` + `agent.yaml`,
  mirrors, eval fixture.
- **Rollback:** remove the build calls + prompt lines, revert the body — the hint path
  was kept, so behavior returns to today's exactly.
- **Stop-and-ask:** (1) RANGE semantics: the hint uses `git diff HEAD` (uncommitted
  work only) while gate artifacts diff from the iteration's `snapshot-sha`
  (`goal-iter-lean.sh:278`). `body.md:16` asserts the work is uncommitted at review
  time, which makes `HEAD` correct — CONFIRM that invariant on both backends (does
  any path commit before review?) before picking the packet's base ref; if it does
  not hold, ask the user before changing what the reviewer sees. (2) If SPEED-2 has
  landed, confirm the packet build sits BEFORE the fork point and the fix-path
  rebuild happens after kill-then-invalidate (same ordering rule as SPEED-2's
  stop-and-ask).
  *Implementation + measurement note (2026-07-16 @ 13668f305963, commit
  `feat(token): TOKEN-7`):* both stop-and-asks CONFIRMED before code — (1) every
  committer on both backends runs outside the developer→review window
  (push-per-iter + WIP-park are post-evaluation `run-goal.sh:2117/:2159`; the
  showcase commit joins pre-dispatch `:1754`; finalize is phase Step 11 and goal
  mode passes `--no-finalize`; `stash create` `:1547` moves no HEAD) ⇒ packet base
  = HEAD; (2) anchors: build 1 after the developer block `goal-iter-lean.sh:873`,
  BEFORE the fork spawns (`:901`/`:940`); fix-path rebuild after the developer-fix
  block (`:997`), i.e. after `_bqa_fork_reap`/`_bqa_full_fork_reap` (`:979-980`) +
  `escalate_model_off`, before the round-2 dispatch. All 7 change-spec points
  shipped in one commit (helper is atomic + fail-closed; absent packet degrades to
  hint-only; reviewer 1.2.0→1.2.1 — the 1.1.2 anchor in this entry predated
  TOKEN-1-era bumps); judgment-runner mirror builds the packet per-sandbox with
  the SAME helper ($REVIEW_PACKET spelled identically both sides — the TOKEN-1
  byte-gate stayed green with no new sanctioned rename); G3 fixture
  `tests/automation/test-review-packet.sh` registered (run-evals 116/116);
  parallel-bqa expected tree gains the packet in both modes (80/80). G9 gate 1:
  reviewer judgment fixtures 4/4, every class exact, packet observed per sandbox.
  G9 gate 2: benchmark `bench-20260716-1436` (GOAL_ACHIEVED, journeys 3/3
  CONFIRMED, zero review FAILs) — reviewer economics vs run E in the Source
  replication verdict above; packet present + consumed in BOTH depths (lean
  iter-0 + phase-mode full iter-1 — the run also resolved TOKEN-8's live DoD);
  fix-path rebuild not exercised live (zero FAILs) — covered by the offline
  scenario tests. First launch was harness-killed at ~4 min (annotated in the
  ledger; detached relaunch measured). DoD met on every clause; remaining for
  DONE: G8 fresh-session certification.

### TOKEN-8 · Usage telemetry for phase-script dispatches (full-depth economics blind spot)
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** DONE (code + tests
  landed 2026-07-14 @ 39e2a79de68a; live full-depth DoD resolved 2026-07-16 by the
  TOKEN-7 benchmark's natural full iter-1 — see the final measurement note)
- **Problem:** the full-depth pipeline's dispatch scripts record NO `claude_usage`
  telemetry rows — a goal-mode full iteration's developer, reviewer, orchestrator,
  test-plan qa, UI chain, and auditor are invisible in the session's per-agent
  economics. Proven cost: TOKEN-1's DoD could not measure the full-depth reviewer/qa
  deltas across three benchmark runs (ledger POSTs bench-20260713-2334 / -0634 /
  -0830), and benchmark `by_agent` totals systematically under-count full iterations.
- **Current state:** `lib/telemetry.sh` is a guarded no-op without `GOAL_SESSION_DIR`
  (its header: "Phase mode does not source this file"); `quota-retry.sh:706` records
  usage only when `record_claude_usage_from_sidecar` is a defined function — i.e. only
  in scripts that source telemetry.sh. Today that is `run-goal.sh`,
  `goal-iter-lean.sh`, `qa-phase.sh` (which is why qa-validation rows appear) and
  `run-evals.sh`; NOT `dev-phase.sh`, `review-phase.sh`, `generate-test-plan.sh`,
  `phase-audit.sh`, nor the UI-chain wrappers.
- **Change spec:** add `source "$SCRIPT_DIR/lib/telemetry.sh"` (mirroring
  qa-phase.sh's source block) to every phase script that calls
  `claude_with_quota_retry` — enumerate call sites with
  `grep -l claude_with_quota_retry scripts/automation/*.sh` and skip the ones already
  sourcing it. No other change: each script already exports `CHAIN_CURRENT_AGENT`,
  and the `GOAL_SESSION_DIR` guard keeps standalone phase mode telemetry-free (the
  file's documented contract — do not alter it).
- **DoD:** a full-depth goal iteration's session telemetry carries usage rows for
  developer + reviewer + auditor (+ orchestrator/UI chain); phase mode standalone
  still writes nothing; run-evals green.
- **Verify:** extend `tests/automation/test-benchmark-runner.sh`'s stub engine or a
  small unit test: run one converted script with `GOAL_SESSION_DIR` set + stub
  sidecar → row appears with the right agent; with it unset → no file. Then
  `./scripts/automation/run-evals.sh`.
- **Files:** `scripts/automation/dev-phase.sh`, `review-phase.sh`,
  `generate-test-plan.sh`, `phase-audit.sh`, UI-chain dispatch scripts (enumerate by
  grep), matching test.
- **Rollback:** remove the source lines (each is one line).
- **Trigger:** hit live 2026-07-14 — the §9 measurement runs could not read
  full-depth per-agent tokens.
  *Measurement note (2026-07-14, §9 run C `bench-20260714-1539` @ 39e2a79de68a):*
  code shipped to 15 scripts (grep enumeration; run-judgment-evals.sh EXCLUDED —
  its grep hit is a comment, no real dispatch; update-docs.sh exports no
  CHAIN_CURRENT_AGENT so its rows land agent-less). Offline DoD half GREEN:
  `tests/automation/test-phase-telemetry.sh` (converted script + GOAL_SESSION_DIR
  + stub sidecar → claude_usage row attributed to `qa`; unset → no file written)
  + run-evals 100/100. Live full-depth half UNRESOLVED BY RUN C — a composition
  effect, not a code failure: REL-12 fixed lean-lane evidence, the evaluator
  therefore kept iter-1 lean ("the lean pipeline still runs browser QA over all
  three journeys") and NO full-depth iteration ran, so
  dev-phase/review-phase/phase-audit never executed and the named
  developer/reviewer/auditor rows could not exist (engine's own close-out said
  "next depth: full" for the iteration that never ran). Mechanism live-proven
  where a converted script DID run: demo-phase.sh's demo-narrator row appears in
  run C iter-0 ($0.247) — A′'s same-class demo dispatch left NO row. REMAINING TO
  DONE: one full-depth iteration in any approved run/session (e.g. --max-iter 3,
  or the SPEED-2/3 flip control) → name the developer/reviewer/auditor rows.
  *Run D check (2026-07-15, §9 `bench-20260715-0924` @ fd378ca276a9):* no
  full-depth iteration occurred (both iterations dispatched lean; iter-1 was a
  one-journey lean build that STALLED on host browser contention) — TOKEN-8
  live DoD still pending; status unchanged. The standing resolution path (any
  approved full-depth iteration) remains.
  *Run E check (2026-07-16, TOKEN-2 benchmark `bench-20260716-0626` @
  d41a38bcfb4f):* both iterations dispatched lean again (REL-12 keeps the lean
  lane evidence-sufficient; the evaluator recommended lean and the session
  achieved goal at the 2-iteration cap) — no full-depth iteration, live DoD
  still pending, status unchanged. Third consecutive composition miss; if a
  natural full-depth iteration keeps not occurring, the standing alternative is
  an explicitly approved `--max-iter 3`-style run or a real session's full
  iteration.
  *LIVE DoD RESOLVED (2026-07-16, TOKEN-7 benchmark `bench-20260716-1436` @
  18d639c17ac2):* the decomposer sent iter-1 FULL on its own (fourth run's
  composition finally landed), the converted phase scripts dispatched, and the
  session telemetry carries named per-agent usage rows for orchestrator
  ($0.854), qa ×2 (test-plan $0.085 + validation $0.583), ui-impact-analyst,
  ui-test-designer, ux-regression-reviewer, phase-closure-auditor, reviewer
  (via review-phase.sh) and auditor ($1.578), all attributed `iter=1` — the
  exact rows this entry's three prior run-checks could not produce. Offline
  half was already green (test-phase-telemetry.sh; standalone phase mode
  writes nothing). DoD met in full → DONE.
  *Certified 2026-07-16 (fresh session; telemetry re-read row-by-row from the
  kept scratch `bench-bench-20260716-1436.dNHg0w`):* claim VERIFIED — and
  under-enumerated: full iter-1 also carries the **developer** row ($3.144,
  79 turns, iter=1, via dev-phase.sh) that the resolution note above omitted,
  completing the DoD's named developer + reviewer ($0.780) + auditor ($1.578)
  trio; every row correctly agent-attributed at iter=1, and run E's all-lean
  telemetry correctly carries none of the phase-script rows. Offline half
  re-ran green same day (test-phase-telemetry.sh cases 1+2 inside run-evals
  116/116). Measurement chapter closed.

### TOKEN-9 · Showcase tier demotion — demo-narrator + readme-maintainer → light
- **Priority:** P2 · **Effort:** S · **Risk:** LOW · **Status:** IN-PROGRESS —
  implemented 2026-07-28 (part of the SPEED-9..19 package); TOKEN-2-class
  experiment, G8 before/after via the next real session's TOKEN-8 rows.
- **Problem:** demo-narrator (373k output tokens/15 iters) and readme-maintainer
  are schema-constrained procedural writers with deterministic safety nets
  (demo JSON is linted/executed by `demo_runner.py`; README edits are
  marker-scoped) — sonnet-priced tokens for haiku-shaped work. ~0 wall-clock
  (both ride the forked showcase tail), pure token cost.
- **Change spec (landed):** `model_tier: standard → light` on both agent.yamls
  (demo-narrator 2.2.0, readme-maintainer 1.2.0); tier prose table in
  `.claude/model-orchestration.md` updated. **iteration-summarizer deliberately
  STAYS standard** — REP-4 raised its concreteness bar and it is the human's
  primary reading surface; demoting it while fixing its top complaint would be
  self-defeating.
- **DoD:** after one real session: `demo_runner.py --mode lint` pass-rate
  unchanged; README AUTO blocks intact; TOKEN-8 rows show the cost drop.
- **Verify:** sync `--check` · run-evals · next-session artifact checks above.
- **Rollback:** one-line tier revert per agent (TOKEN-2's watch-item pattern).
- **Stop-and-ask:** haiku demo JSON failing lint more than occasionally, or ONE
  README AUTO-block corruption of hand-written prose ⇒ revert that agent.

### TOKEN-10 · Executor context diet — developer + browser-qa get the goal slice
- **Priority:** P1 · **Effort:** M · **Risk:** MED · **Status:** IN-PROGRESS —
  implemented 2026-07-29 (iteration-shape package; PROMOTED from
  CAND-DEV-CONTEXT sketch (a) with the desk evidence attached: developer wall
  grew 31→77 min while feeding the full 97KB/1,150-line goal.md that the
  proposer keeps extending); G8 certification pending.
- **Change spec (landed):** `goal_slice_for_exec` in `lib/common.sh` wraps the
  EXISTING `goal_gate.py goal-slice` builder (unmodified) for executing agents:
  vision + anti-goals + target/failing journeys verbatim, stable passing
  journeys digested; sets `GOAL_SLICE_EXEC_PATH`/`GOAL_SLICE_EXEC_MODE`
  (sliced|full-hatch|full-fallback), loud WARNING + `goal_slice_fallback`
  telemetry on any builder failure (never blocks, never stale — the out-path
  is used only on a fresh rc-0 non-empty build). Lean developer slices over
  targets; lean browser-qa over targets ∪ its LLM set (every journey the LLM
  executes stays verbatim); full-depth developer via `dev-phase.sh`'s new
  goal-context line; full browser-qa over targets ∪ `_llm_regr_set`. Agent
  bodies defer to "the goal file named in your dispatch prompt".
- **Honest effect:** slice is O(targets+failing) vs goal.md O(all journeys) —
  ~55-70% of goal-context bytes cut now, and the growth term stops growing;
  wall saving is mostly indirect (fewer tokens to re-read per turn).
- **Verify:** `bash tests/automation/test-goal-context-slice.sh` (26 cases:
  slice content verbatim/digested, hatch, loud fallback, full-pipeline wiring).
- **Rollback:** `CHAIN_DEV_FULL_GOAL=true` restores the full goal file at every
  executor site.
- **Stop-and-ask:** a developer building against a digested journey it should
  have read (the slice prompt names the full file as the escape) — bring the
  iteration before widening the slice.

---

## 10. P1 — Reliability & weaker-model hardening

### REL-1 · Judgment eval fixtures (golden verdict cases)
- **Priority:** P1 · **Effort:** L (slice per judge) · **Risk:** LOW · **Status:** DONE
  *(slice (a) — goal-evaluator cases + runner — implemented 2026-07-09; slice (b) —
  reviewer cases, scratch-git diff representation, runner per-judge builders —
  implemented 2026-07-09 (user-directed follow-on session); slice (c) — auditor cases +
  phase-audit.sh runner builder — certified and confirm-run 2026-07-10 by a fresh
  session (not the implementer) per G8, closing all three slices.
  Confirmed real runs (user-approved spend):
  (a) 2026-07-09, judge = claude-opus-4-8 @ effort max: 5/5 verdict classes correct —
  case-01-clean-goal-achieved → GOAL_ACHIEVED (342s), case-02-first-failure-continue →
  CONTINUE (234s), case-03-regression-broken-journey → REGRESSION (262s),
  case-04-goal-drift-void-pass → CONTINUE (322s), case-05-secret-committed →
  REGRESSION (196s).
  (b) 2026-07-09, judge = claude-sonnet-5 @ effort max: 4/4 verdict classes correct —
  case-01-clean-pass → PASS (172s), case-02-minor-nit-not-fail →
  PASS_WITH_NOTES (149s), case-03-hardcoded-credential → FAIL (177s),
  case-04-spec-contradiction → FAIL (192s).
  (c) 2026-07-10, judge = claude-opus-4-8 @ effort max: 4/4 verdict classes correct —
  case-01-clean-pass → PASS (220s), case-02-documented-gap-not-fail →
  PASS_WITH_GAPS (352s), case-03-qa-green-spec-contradiction → FAIL (325s),
  case-04-paid-service-live-key → FAIL (328s).)*
- **Problem:** the single biggest retirement risk is silent judge regression — a weaker
  evaluator/reviewer/auditor emitting plausible-but-wrong verdicts. The eval suite
  checks parsers and gates, not judgment.
- **Current state:** `run-evals.sh` = 74 offline checks, no LLM-in-the-loop cases.
  Golden vs-Fable baselines were deliberately skipped (letter, "Not done"). Verdict
  contracts: `lib/verdicts.py`.
- **Change spec:** new `tests/judgment/` — per judge, 3-5 frozen artifact sets (spec +
  handoff + browser results + journey history) with an EXPECTED verdict class chosen so
  a correct judge cannot miss (e.g. a failing journey table must NOT yield
  GOAL_ACHIEVED; a CRITICAL security finding must yield FAIL). Runner
  `scripts/automation/run-judgment-evals.sh` dispatches each case to the CURRENT
  configured judge model at its configured effort, compares verdict class only (not
  wording). NOT part of `run-evals.sh` (spends tokens — G9 confirm each run); required
  in EVO-4 cutovers and before/after TOKEN-2-style tier experiments.
- **DoD:** ≥3 cases each for goal-evaluator, reviewer, auditor; runner prints a
  pass/fail table; documented in EVO-4's playbook step 6.
- **Verify:** `bash -n scripts/automation/run-judgment-evals.sh` + one confirmed real
  run (user-approved spend).
- **Files:** `tests/judgment/**` (new), `scripts/automation/run-judgment-evals.sh`
  (new), playbook cross-ref.
- **Rollback:** standalone; delete.
- **Slices:** (a) evaluator cases + runner; (b) reviewer cases; (c) auditor cases.

### REL-2 · Preflight doctor
- **Priority:** P1 · **Effort:** M · **Risk:** LOW · **Status:** DONE 2026-07-17
  *(implemented + tested 2026-07-17: `scripts/automation/doctor.sh` (14 checks, `--only`/
  `--list`/`--strict-doctor`, advisory by construction — exit 0 unless `--strict-doctor`
  AND ≥1 FAIL) + warn-only engine wiring (`run_doctor_preflight`, `CHAIN_DOCTOR=true`
  default, called before `chain_tmp_init` so the table is pre-mutation truth; crash/
  nonzero/hang all degrade to a log line — proven by a crashing-stub test) +
  `tests/automation/test-doctor.sh` (44 asserts, PATH-shim fakes, registered in
  run-evals §2c, ~2s; suite 122/122). Three evidence-born checks beyond the original
  list: `tmp-health` WRITE-probes the configured tmp root (REL-13 EDQUOT incident —
  failure mode was exit-1-with-no-output, statfs is blind to tmpfs quotas);
  `chrome-exclusive` WARNs naming competing chrome PIDs (run D `bench-20260715-0924`
  lost ~$16 to DevTools-port contention from foreign Chromes); `ambient-env` WARNs on
  ambient CHAIN_* vars via a snapshot taken at the very top of run-goal.sh before the
  engine's own exports (`_CHAIN_AMBIENT_AT_START` → `CHAIN_DOCTOR_AMBIENT`; §9
  measurement discipline records "no ambient CHAIN_ vars" as a precondition).
  `engine-lock` row live since REL-4 (2026-07-17): absent→PASS, fresh→WARN naming the
  holder, stale→FAIL — verdicts from the lock lib's own `engine_lock_classify`, both
  goal-session and phase lock paths. Chrome MCP detection is config-file truth, zero dispatch
  spend: `.claude/settings.json` enabledPlugins/allow + plugin cache dir +
  `.mcp.json`/`~/.claude.json` mcpServers. First real-machine run: 10 PASS / 3 WARN
  (gh not logged in; uutils timeout, not GNU; 17 chrome-family processes) / 1 SKIP in
  1.4s — honest findings, reported. Certified DONE 2026-07-17 by a fresh
  non-implementer session per G8: test-doctor 44/44 + evals 122/122 re-run green; live
  table on this machine 10 PASS / 3 WARN / 0 FAIL / 1 SKIP in 1.5s with every WARN
  independently truth-checked (gh auth rc 1; uutils timeout 0.8.0; 26 live
  chrome-family processes vs the row's 27 — scan-to-scan drift, same truth);
  `--only` single-row + unknown-key exit 2, strict/non-strict exit semantics, the
  crashing-stub warn-only wiring, the three incident citations, and config-file
  Chrome-MCP detection all spot-checked against source plus the fresh suite run. Live
  engine-start proof still rides the next real session with `CHAIN_DOCTOR` active.)*
- **Problem:** sessions die mid-iteration on environment problems that were knowable at
  start (missing playwright, dead Chrome MCP, unauthenticated gh, low disk, stale pump).
- **Current state:** only GitHub auth is preflighted (`git ls-remote` before the loop,
  `run-goal.sh:575-643` → `AWAITING_GITHUB_AUTH`).
- **Change spec:** `scripts/automation/doctor.sh` — PASS/WARN/FAIL table: python3/node
  versions, `playwright` + browser install, Chrome MCP configured (when goal mode —
  it's REQUIRED there), `gh auth status`, git remote reachability, disk space, GNU
  `timeout`, `jq`, stale pump heartbeat, stale engine lock (REL-4). Standalone command +
  called at engine start warn-only (`CHAIN_DOCTOR=true` default; `--strict-doctor` to
  fail on FAIL rows).
  *Partial delivery (2026-07-14, REL-13):* the disk-space row exists now as
  `chain_tmp_disk_guard` (engine preflight + per-iteration, `AWAITING_DISK`
  pause) plus `scripts/automation/tmp-doctor.sh --status`. The remaining rows
  (playwright/Chrome-MCP/gh/timeout/jq/pump/lock) are still TODO.
- **DoD:** runs clean on a healthy machine; each check individually testable
  (`--only <check>`); engine wiring warn-only; evals green.
- **Verify:** `bash scripts/automation/doctor.sh && bash -n
  scripts/automation/run-goal.sh && ./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/doctor.sh` (new), `scripts/automation/run-goal.sh`
  (1 call), README command table.
- **Rollback:** knob / remove call.

### REL-3 · Pump PID-liveness
- **Priority:** P1 · **Effort:** M · **Risk:** MED · **Status:** DONE 2026-07-17
  *(implemented + stub-proven 2026-07-17; certified DONE 2026-07-17 by a fresh
  non-implementer session per G8: dispatch self-test OK with tests 16-19 discriminating
  on elapsed time (dead same-host pid → 70 within one poll, 0s observed; cross-host
  inflight net unchanged; old-format claim byte-identical; live pid keeps waiting),
  await self-test OK (v3 ident scenarios + the set-but-empty disabled seam),
  test-pump-liveness 12/12 (real engine paused AWAITING_PUMP in 2s against the 7200s
  cap, REL-4 lock released, no retro-input.md, resume re-acquired the lock + re-ran the
  iteration + fast-paused again), test-doctor 50/50, run-evals 125/125; waiter diff
  read for the additive-only property — fast path gated on pid+host present AND same
  host, EPERM-safe dead check (kill -0 + /proc absence), standard exit-70 machinery,
  both timeout nets untouched; skill 3.0.0 + mirror byte-identical + restart rule
  restated. The DoD never required a real incident — the first real dead-pump rescue
  rides the next actual incident as live validation, not as a DoD gate. Absorbed known
  gap: the letter's pump-liveness limitation bullet is now annotated closed. Protocol v3
  (skill 3.0.0, mirrors resynced, restart rule restated): `goal-await-dispatch.sh`
  resolves the long-lived pump process once per call — the `claude` session via /proc
  ancestry walk; `CHAIN_PUMP_PID` overrides, set-but-empty disables — and writes
  pid/host/starttime into `.pump-alive` + each `.started` atomically (tmp+mv preserves
  the mtime semantics every pre-v3 reader keys on). Engine waiter
  (`lib/interactive-dispatch.sh`): on a CLAIMED dispatch, same-host + provably-dead pid
  (kill -0 + /proc existence, EPERM-safe) or starttime-recycled pid → the STANDARD
  exit-70 machinery (log line naming pid/host/agent, `.awaiting-pump` marker, channel
  cleanup, `dispatch_wait` status `pump-dead`, no requeue — a dead pump can't service
  one) within one poll; absent fields / cross-host / unprovable verdicts leave both
  timeout nets byte-identical (dispatch self-tests 1-15 pass unchanged; explicit
  cross-host, old-format, and live-pid invariant tests added as 16-19; pump-side ident
  + disabled-seam tests in the await self-test). Integration proof
  (`tests/automation/test-pump-liveness.sh`, run-evals §2c): the real engine paused
  AWAITING_PUMP in 1s against the default 7200s cap, REL-4's lock released, no
  retro-input.md (EVO-2 terminal-only filter untouched), resume re-acquired + re-ran
  the iteration + fast-paused again — downstream-indistinguishable from a timeout
  pause. Doctor pump-heartbeat row surfaces the v3 ident (test-doctor 50/50). Residual
  pid-reuse window, noted honestly: a recycled pid is caught only when starttime was
  recorded at claim time and /proc stays readable — otherwise plain kill -0 semantics,
  i.e. the entry's original spec.)*
- **Problem:** a pump that dies during a CLAIMED dispatch makes the engine wait out the
  full in-flight timeout (default 2h) before pausing.
- **Current state:** two-tier liveness: pickup heartbeat staleness
  (`lib/interactive-dispatch.sh:49-55`, `~:223-238`) and in-flight timeout from the
  `.started` marker (`~:56-67`, `~:197-221`). Heartbeat write:
  `goal-await-dispatch.sh:88-140`. No PID in the protocol.
- **Change spec:** pump writes `pid` + `host` into its heartbeat/claim files; the
  engine-side waiter, when on the same host and the dispatch is CLAIMED, checks
  `kill -0 <pid>` each poll — dead pid → immediate exit 70 (`AWAITING_PUMP`) instead of
  waiting out the timeout. Different host or missing pid → today's behavior. Bump the
  dispatch skill version; document pump-restart-after-change.
- **DoD:** stub test: claimed dispatch + killed pump pid → engine pauses within one poll
  interval; cross-host case unchanged; evals green.
- **Verify:** targeted stub test + `./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/goal-await-dispatch.sh`,
  `scripts/automation/lib/interactive-dispatch.sh`,
  `skills/goal-interactive-dispatch.md` (+version, mirror).
- **Rollback:** engine ignores the pid field (additive protocol).
- **Stop-and-ask:** if the protocol change would strand a currently-running production
  pump mid-session, coordinate timing with the user.

### REL-4 · Cross-session lock
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** DONE 2026-07-17 *(S item —
  implementer flips DONE (G8 fresh-session certification is M/L-only). Absorbed known gap:
  letter — its "no cross-session lock" limitation bullet is now removed.
  `lib/engine-lock.sh`: mkdir-atomic lock DIR with pid/host/epoch/cmd metadata inside;
  same-host staleness = `kill -0` plus a /proc-cmdline pid-recycle sanity (the engine.pid
  self-heal precedent, `run-goal.sh:190`); cross-host = age vs
  `CHAIN_ENGINE_LOCK_CROSS_HOST_TTL` (default 86400s — longer than any plausible session
  incl. quota sleeps; a crashed remote holder blocks only until TTL or documented manual
  removal); metadata-free dirs get a 60s init grace (`CHAIN_ENGINE_LOCK_INIT_GRACE`).
  FRESH → refuse fast with exit 86 (`ENGINE_LOCK_REFUSED_EXIT`, distinct from 70
  transport / 75 quota / 130-137-143 signals) naming pid/host/age + the TROUBLESHOOTING
  section; STALE → replace with ONE logged warning. run-goal acquires after its traps arm
  and before the doctor/tmp/disk/GitHub preflights; run-phase (including goal-driven
  full-depth children — the shared-worktree critical section) right after its EXIT trap
  registration; release is appended LAST inside the EXISTING composed EXIT handlers — no
  new `trap` registrations anywhere, so REL-13 tmp cleanup + engine.pid removal +
  showcase reaping still run (asserted explicitly). AWAITING_* pause exits release; resume
  re-acquires; the resume self-heal composes (SIGTERM takeover → clean release; SIGKILL →
  stale-replace on next start). Doctor `engine-lock` row un-SKIPped — PASS absent / WARN
  fresh naming the holder / FAIL stale, verdicts from the same `engine_lock_classify`.
  `tests/automation/test-engine-lock.sh` 40/40 (registered in run-evals §2c): helper
  units (refuse code+message, owner-only release, cross-host TTL both ways, init grace)
  plus REAL engines under a stub claude — hold, refuse-fast, SIGKILL→stale→replace→
  proceed, faithful Ctrl-C via process-group INT with SIGINT restored to SIG_DFL through
  an exec shim (bash backgrounds children INT-ignored, and an entry-ignored signal can
  never be re-trapped — without the shim the test INTs a disposition no terminal
  produces), AWAITING_PUMP + AWAITING_GITHUB_AUTH releases, resume-after-pause
  re-acquire, and the repo-level phase twin incl. cross-phase refusal; test-doctor.sh
  49/49 with the new absent/fresh/stale/cross-host fixtures.)*
- **Problem:** two engine sessions on one repo race silently ("one repo, one live
  session" is currently just a convention).
- **Current state:** no lock anywhere.
- **Change spec:** at engine start, acquire `runs/goal-session-<sid>/.engine.lock`
  (mkdir-style atomic; contains pid+host+epoch). Held → check staleness (`kill -0`
  same-host, age threshold cross-host); fresh → refuse to start with a clear message;
  stale → replace with a logged warning. Release on all exit paths (trap). Also guard
  phase mode with a repo-level `runs/.phase.lock` the same way.
- **DoD:** second engine start on a locked session fails fast; stale lock recovered;
  Ctrl-C releases; evals green.
- **Verify:** targeted test (background engine stub + second start) +
  `./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/run-goal.sh`, `scripts/automation/run-phase.sh`,
  `docs/TROUBLESHOOTING.md` entry.
- **Rollback:** remove acquisition (lock files inert).

### REL-5 · Browser-qa flake discipline
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** DONE 2026-07-17 *(S item —
  implementer flips DONE; stub tests are the DoD. Taxonomy re-verified first (the entry's
  premise, refreshed anchors): demo_runner.py verify-mode rc contract is 0 ok / 5 = ≥1
  journey assertion FAIL (`run_verify` tail, `lib/demo_runner.py:1045`) / 6 =
  browser-INFRA failure — launch timeout or mid-run crash; the except path still writes
  the results file (SKIP rows naming the failure) before returning 6 (`~:1021-1039`;
  docstring `~:20-22`) / 3 = playwright missing / 2 = bad invocation. The split the
  entry assumed exists; it was invisible to a naive `exit 6` grep because both codes are
  `return`s propagated through `sys.exit(main(...))`. The lane itself moved post-entry
  into `lib/replay-lane.sh` (`replay_lane_partition_and_verify`, shared by BOTH depths);
  implemented there: rc 6 → `ensure_services_running` re-check (guarded `declare -F`;
  the fn always returns 0) + retry ONCE via `_replay_lane_verify_once` (same command,
  extracted); a second rc-6 → `_replay_lane_mark_skipped_infra`: raw artifact verdict
  line rewritten to exactly `**Browser QA Verdict:** SKIPPED-INFRA` + dated footer,
  `REPLAY_SKIPPED_INFRA=yes`, `replay_lane_skipped_infra` telemetry, one-line greppable
  retry + verdict logs — then the SAME whole-set LLM fallback as any lane failure. rc 5
  NEVER retried (proven with a discriminating '5 0' rc sequence — a forbidden retry
  would flip the outcome); non-6 failure rcs keep the old no-retry generic fallback
  byte-identically. demo_runner.py untouched. READER MAP (the G3 pass; decision:
  SKIPPED-INFRA journeys DO feed the LLM lane — the entry's "infra unknown", so the LLM
  lane still attempts/verifies them): ① `replay_lane_llm_regression_set` → whole
  REQUIRED set via `_use_replay=no` (test 12e pin); ② SPEED-2 fork boundary —
  `_bqa_state_save`/`_bqa_fork_consume` serialize the new global and the join's consume
  line names the state (parallel-bqa scenario K reader proof); ③ the merged
  ui-test-results.md NEVER carries SKIPPED-INFRA — its verdict line stays
  agent/merge-written PASS/FAIL/SKIPPED (verdicts.py BrowserQAVerdict unchanged), so
  the `PASS|FAIL|SKIPPED` checkpoint greps (goal-iter-lean.sh `~:448/:495/:739/:1045`)
  cannot collapse it — asserted at the reader in scenario K; ④ evaluator + gates read
  only the merged file (evaluator body already calls the raw file "a lane artifact, not
  an input"; missing evidence → journey `unknown`), so "infra unknown" arrives with no
  parser-contract change; NEITHER the browser-qa body's result-table contract (agent's
  own PASS/FAIL/SKIP(PED)) nor the evaluator body enumerates lane states, so per the
  entry's mirror-only-if-enumerating clause both bodies are untouched; ⑤ REL-11
  missing-evidence tripwire watches the LLM lane's own output file — silent on a
  SKIPPED-INFRA lane (scenario K). Fixtures (G3; both files already registered in
  run-evals §2c): test-replay-lane.sh 35/35 — double-6 → exactly one retry + exactly
  one service re-check + exact state string at writer and raw artifact; 6-then-0 rescue
  → normal lane; 6-then-5 → REPLAY_FAILED unchanged; rc-3 → old fallback text
  unchanged; test-goal-parallel-bqa.sh 91/91 with new scenario K (fork/join end-to-end:
  retry counted across the fork, state survives the join, merged-file placement,
  tripwire silence, checkpoint marker carries the merged PASS, telemetry event);
  test-replay-lane-full.sh 24/24; test-goal-checkpoints.sh 11/11; run-evals green.)*
- **Problem:** a browser infra hiccup (dead server moment, browser crash) reads as a
  journey FAIL, poisoning the evaluator's evidence and sometimes a whole iteration.
- **Current state:** `demo_runner.py` already separates infra from assertion failures
  (exit 6 = browser infra failure vs 5 = verify FAIL); the lean replay lane treats
  failures uniformly.
- **Change spec:** in the replay lane (`goal-iter-lean.sh:379-460` area): on exit 6,
  re-check service health (`ensure_services_running`, `lib/common.sh:763`) and retry
  ONCE; second 6 → mark lane SKIPPED-INFRA (distinct from FAIL) so the LLM lane / the
  evaluator sees "infra unknown", not "journey broken". Mirror the wording in the
  browser-qa agent body's result-table contract if it enumerates statuses.
- **DoD:** forced-exit-6 stub shows one retry then SKIPPED-INFRA; real FAIL (5) is NOT
  retried (don't mask real regressions); evals green.
- **Verify:** targeted stub test + `./scripts/automation/run-evals.sh`
- **Files (as built):** `scripts/automation/lib/replay-lane.sh` (the lane's post-entry
  home, shared by both depths), `scripts/automation/goal-iter-lean.sh` (fork-state
  serialization + consume line + lane-contract comment),
  `tests/automation/test-replay-lane.sh`, `tests/automation/test-goal-parallel-bqa.sh`.
  `agents/browser-qa-agent/body.md` untouched — it enumerates only the agent's own
  statuses, not lane states.
- **Rollback:** revert the rc-6 retry branch in `replay_lane_partition_and_verify`
  (rc 6 then lands in the generic non-zero fallback exactly as pre-REL-5).

### REL-6 · Iteration-state synthesis
- **Priority:** P1 · **Effort:** M · **Risk:** MED · **Status:** IN-PROGRESS
  *(implemented + sandbox-proven 2026-07-17; G9 gate run same day: goal-evaluator
  judgment fixtures 5/5 under the extended prompt (user-approved spend; the frozen
  trees carry no iteration-state file, so every case exercised the absent-file path —
  no verdict-class flip). REMAINING: G8 fresh-session certification (M item —
  implementer never self-certifies) + first real-session iteration-state file.
  Refreshed anchors: evaluator dispatch = run-goal.sh Step 3 (`~:1980` era; new
  "Iteration state:" line in the Prior-session-state block + the closing
  update-instruction line), decomposer dispatch `~:1698` era (inline lands after the
  journey-digest block), state vars `~:237-245`; the judgment builder mirrors the
  evaluator prompt in `run-judgment-evals.sh` `_prepare_goal_evaluator`, and the
  prompt-mirror byte-gate now covers the evaluator PAIR
  (test-project-template-slice.sh §7; sole sanctioned rename
  `$VERDICT_FILE`↔`$EVAL_OUTPUT`; frozen fixture trees untouched). Implemented:
  `templates/iteration-state.md` (34-line template — journey one-liner, active
  blockers, last 2 verdicts + why, Do-not-redo; placeholder variant documented);
  evaluator body step 7 (OVERWRITE after eval.md, single writer, cap named) v1.6.0;
  decomposer body read-first item 5 (verbatim inline, "Do not redo" BINDING unless
  goal.md changed, never writes the file) v2.2.0; mirrors resynced. The ≤40-line cap
  is ENFORCED by `lib/artifact_schemas.py` (the stop-and-ask condition): new
  verdict-less iteration-state schema (first Optional-enum schema; required H2s
  Journeys / Active blockers / Last 2 verdicts / Do not redo; `max_lines=40`) whose
  violations are validation issues (CLI `validate` exit 1) — enforcement lives in the
  validator + evals while runtime keeps the module's documented hook-advisory
  convention; 3 new self-test fixtures (pass / over-cap / missing-section).
  Decomposer inline via `_tail_or_placeholder` (40-line budget ≡ the whole
  cap-conforming file; its 48KiB byte cap guards a rogue oversized write; absent →
  "(first iteration — no prior state)"). Sandbox proof
  `tests/automation/test-goal-iteration-state.sh` 14/14 (registered run-evals §2c):
  ONE real engine run (--max-iter 2, role-aware stub claude, paths parsed FROM the
  prompts) — iter-0 baseline prompt inlines the placeholder; the obedient evaluator
  stub writes a conforming file at the PROMPT-named path; schema CLI accepts it and
  rejects an over-cap copy; iter-1's decomposer prompt carries the file byte-for-byte
  (fenced block diffed against disk) plus the binding rule; engine pauses
  AWAITING_PUMP cleanly. run-evals 126/126. Absorbed:
  README Pipeline-Hardening deferred item — it explicitly called this "where the weaker
  model degrades most".)*
- **Problem:** long goal loops drift: repeated work, forgotten journeys, re-testing
  fixed regressions — because each iteration's agents reconstruct state from many
  artifacts instead of one fresh distillation.
- **Current state:** the evaluator already rewrites `journey-history.json` and appends
  to `evaluator-log.md`; the decomposer receives goal-slice + journey digest + lessons
  tail (`run-goal.sh:1221-1264` area). No single "state of the project right now" file.
- **Change spec:** the evaluator additionally writes
  `runs/goal-session-<sid>/state/iteration-state.md` (OVERWRITE each iteration, ≤40
  lines, template-driven): current journey table one-liner, active blockers, last 2
  verdicts + why, "do not redo" list. The decomposer prompt inlines it verbatim
  (small, so full inline — not a tail). Evaluator body + template + both dispatch
  prompts + artifact schema; version bumps; eval fixture for the template shape.
- **DoD:** fixture-validated format; decomposer prompt carries it; absent file =
  placeholder (first iteration); evals green.
- **Verify:** `./scripts/automation/run-evals.sh` + sandbox iteration shows the file.
- **Files:** `agents/goal-evaluator/body.md` + `agent.yaml`,
  `agents/goal-decomposer/body.md` + `agent.yaml`, `templates/iteration-state.md`
  (new), `scripts/automation/run-goal.sh`, `lib/artifact_schemas.py`, mirrors.
- **Rollback:** stop inlining (prompt line); file becomes inert.
- **Stop-and-ask:** if this meaningfully grows evaluator output cost, check the ≤40-line
  cap is enforced by the schema validator before shipping.
- **Trigger (from old README):** drift symptoms in real sessions — repeated work,
  forgotten journeys, loops re-testing fixed regressions.

### REL-7 · Auditor adversarial deep-think experiment
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** TODO *(absorbed:
  README Pipeline-Hardening "extended-thinking on auditor" — partially superseded:
  auditor already runs `--effort max` (default, `lib/agent_permissions.py`) and the
  adversarial fresh-context confirm exists for GOAL_ACHIEVED)*
- **Problem:** the remaining delta from the old item: an explicit adversarial preamble
  ("assume the implementation is buggy; find why") on the AUDITOR itself, and a
  measured check of whether it changes audit outcomes.
- **Current state:** `agents/auditor/body.md` has the severity decision tree + post-fix
  self-verification; no adversarial framing sentence.
- **Change spec:** add the adversarial framing to the auditor body (2-3 lines, version
  bump); measure over 2-3 phases (or REL-1 auditor fixtures): does it change verdicts
  or just tokens?
- **DoD:** body updated + mirrored; result recorded here (keep / revert with evidence).
- **Verify:** `python3 scripts/automation/sync-cli-assets.py --cli claude --check &&
  ./scripts/automation/run-evals.sh` + fixture/phase comparison.
- **Files:** `agents/auditor/body.md` + `agent.yaml`, mirrors.
- **Rollback:** revert body lines.
- **Trigger (from old README):** auditor returns PASS on phases that ship with bugs.

### REL-8 · Cost dimension for the effort-experiment tripwire
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** TODO
- **Source:** Superpowers 6 measured that capping model thinking increased turn count
  and ~doubled output — a COST backfire. Our tripwire watches quality only. Anchors
  verified 2026-07-07 @ `eb5c8f9`.
- **Problem:** the `CHAIN_AGENT_EFFORT` experiment auto-reverts on quality signals only
  (`evaluate_tripwire()`, `lib/analyze_telemetry.py:441-466`: any REGRESSION verdict,
  any regressed journey, ≥2-of-3 first-attempt review FAILs). If lowering an agent's
  effort doubles its output tokens — the measured Superpowers failure mode — the
  tripwire never fires and the "saving" quietly costs more than baseline.
- **Current state:** tripwire runner `run-goal.sh:1663-1677` (exit 3 = TRIP → banner,
  `unset CHAIN_AGENT_EFFORT` `:1675`, `experiment_reverted` event `:1674`). Knob-active
  iterations are marked by `iter_config` events (`run-goal.sh:1196-1197`; payload is
  `{key:"CHAIN_AGENT_EFFORT", value:"<agent=lvl,…>"}` — the agent list is parseable
  from `value`, verified). Per-agent output tokens already aggregated
  (`analyze_telemetry.py` `by_agent` `:96`, `output_tokens` `:53`, per-agent rows
  `:212`, JSON `:227`). The knob is headless-only (`agent_permissions.py:272-273`)
  and headless always emits `claude_usage` events — the data is guaranteed present
  exactly when the knob is active.
- **Change spec:**
  1. In `evaluate_tripwire()`: parse which agents the knob names from the `iter_config`
     event payload; per knob-active iteration compute those agents' output-token
     totals; baseline = median of the SAME agents' totals over the most recent ≤3
     non-knob iterations of the session.
  2. TRIP when the median knob-active total > baseline × (1 + PCT/100); PCT from
     `CHAIN_TRIPWIRE_COST_PCT` (default `50`; value `off` disables the cost dimension
     only). No non-knob baseline iterations available → SKIP the cost check with a
     printed warning (never trip blind).
  3. Distinguish trip reasons: the banner and the `experiment_reverted` event payload
     gain `reason: quality|cost`.
  4. Fixtures in the lib's self-test: (a) fabricated 2× output-token stream trips with
     `reason: cost`; (b) normal cost does not trip; (c) missing baseline skips with
     the warning. Ensure the self-test is registered in `run-evals.sh`.
  5. Docs: knob-table row (`.claude/model-orchestration.md:135`) and tripwire section
     (`docs/goal-mode-telemetry.md:182`) gain the cost dimension + PCT knob.
- **DoD:** all three fixtures green; evals green; quality dimension byte-identical when
  PCT=off.
- **Verify:** re-grep the lib's self-test entrypoint first (anchors-are-hints rule),
  then run it + `bash -n scripts/automation/run-goal.sh &&
  ./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/lib/analyze_telemetry.py`,
  `scripts/automation/run-goal.sh` (banner text, if any),
  `.claude/model-orchestration.md`, `docs/goal-mode-telemetry.md`.
- **Rollback:** `CHAIN_TRIPWIRE_COST_PCT=off`; or revert the function edit (the quality
  dimension is untouched).
- **Stop-and-ask:** if `iter_config` events stop recording which agents the knob names
  (grep the emitter at `run-goal.sh:1196-1197` first — today they do), extend the
  event payload in the same change — but map every reader of `iter_config` before
  adding a field (G3).

### REL-9 · Test-first spec weighting in the decomposer
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** DONE
  (implemented + verified in-session 2026-07-16 — S items self-close: all four
  change-spec points landed additively; agent.yaml 2.0.0→2.0.1 (the 1.2.1 anchor
  below predated TOKEN-2's 2.0.0 bump), mirror resynced + `--check` clean,
  run-evals 116/116, `grep TC- .claude/agents/goal-decomposer.md` green, template
  self-consistency read done (banned words appear only inside the quoted ban
  list; no template text violates its own contract). Two deliberate guards worth
  not "fixing" later: (1) the contract is PROSE inside the existing
  `## TESTING REQUIREMENTS` section, NO new heading — TOKEN-3's skip regex
  (`run-phase.sh` `_spec_lists_tests_reason`, case-insensitive
  `^#{2,}\s*tests?\b`) would match a `### Test scenarios` heading ALONE and
  grant the skip with zero TC- lines; (2) the template shows exactly TWO example
  TC- lines, so a verbatim-copied unfilled template can never reach the ≥3 skip
  threshold by itself. Stop-and-ask cleared: qa/browser-qa bodies list spec
  sections as an extraction guide, not a closed set — no companion edit. No
  lean/baseline carve-out added — the change spec names none, and baseline's
  own DoD wording maps to a TC- line trivially. Live proof rides the next real
  goal session's specs (per the DoD's observed-not-gated clause): the decomposer
  has been STANDARD-tier since TOKEN-2, so a MORE demanding template on the
  cheaper model is the thesis under live test — if the next session's specs
  degrade, TOKEN-2's watch item (single-line tier rollback) is the first
  suspect, not REL-9's rollback.)
- **Source:** Superpowers 6 measured finding: test specifications + interface
  definitions carry implementation quality; implementation bodies in plans are
  marginal contributors. Anchors verified 2026-07-07 @ `eb5c8f9`.
- **Problem:** the decomposer's spec template is outcome-oriented, but its
  `## TESTING REQUIREMENTS` is three skeletal lines while `## IN SCOPE` invites
  implementation bullets — the spec's detail budget is weighted toward the part that
  matters least for downstream quality.
- **Current state (post-change 2026-07-16; the pre-REL-9 anchors, verified
  2026-07-07, had rotted — tier and version were pre-TOKEN-2):** template at
  `agents/goal-decomposer/body.md:37-130`; `## TESTING REQUIREMENTS` `:101-129`
  carries the TC- contract (`:107-119`: shape line + two example TC- lines;
  vague-term ban aligned with the canonical goal-lint list,
  `lib/goal_lint.py:62-63` — "works well", "user-friendly", "fast", "properly",
  "intuitive", "correctly" — plus the bare forms "works"/"as expected"; one
  vocabulary, not two); `### Data-contract additions` `:86-88` requires exact
  field name(s) + type/shape alongside canonical module + endpoint; pre-write
  self-check `:194-203` is six items, item 6 (`:201`) = the D6 test-first check
  (spec validated against the contract before writing; IN SCOPE bullets stay
  coarse; shrink by cutting narrative, never TC-/Data-contract content). Spec
  consumers remain prompt-readers plus the J-ID regex `_spec_journeys()`
  (`goal-iter-lean.sh:200`) — both consume the additive content unchanged.
  `agent.yaml`: v2.0.1, `model_tier: standard` (since TOKEN-2).
- **Change spec:**
  1. `## TESTING REQUIREMENTS` contract: every DEFINITION OF DONE checkbox and every
     Data-contract addition must map to ≥1 concrete scenario line of the form
     `- TC-<n>: given <precondition>, when <action>, then <observable result>`; vague
     verbs banned ("works", "properly", "correctly", "as expected"). The `TC-` prefix
     deliberately matches TOKEN-3's skip-heuristic (a spec with ≥3 `TC-` lines lets
     full mode skip test-plan generation).
  2. `### Data-contract additions`: additionally require exact field name(s) +
     type/shape alongside the existing canonical module + endpoint.
  3. New rule near the pre-write self-check (`:184` region): implementation bullets in
     IN SCOPE stay coarse (name the surface/file, not the code); when shortening a
     spec, NEVER cut TESTING REQUIREMENTS or Data-contract additions (D6).
  4. Version-bump `agent.yaml` 1.2.1→1.2.2, resync mirrors, commit together (G2).
- **DoD:** rendered `.claude/agents/goal-decomposer.md` shows the TC- contract + rule;
  evals green; the next real session's iter spec contains TC- lines (observed, not
  gated).
- **Verify:** `python3 scripts/automation/sync-cli-assets.py --cli claude && grep -n
  "TC-" .claude/agents/goal-decomposer.md && ./scripts/automation/run-evals.sh`
- **Files:** `agents/goal-decomposer/body.md` + `agent.yaml`, mirrors.
- **Rollback:** revert the body edit + version bump; already-written specs keep working
  (format is additive).
- **Stop-and-ask:** if browser-qa or qa bodies enumerate the spec's section list as a
  CLOSED set (grep before editing), update them in the same change (G3); otherwise
  none beyond the ground rules.

### REL-10 · Benchmark scratch service-boot localization (fixture env manifest)
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** DONE 2026-07-12
  *(implemented + verified in the promoting session @ 5e87813077ae — S items may
  self-close. Offline: test-benchmark-runner.sh 54/54 (fixture.env exported correct /
  absent-manifest green), run-evals.sh 96/96. Live: benchmark rerun
  bench-20260712-1536 — journeys 0/3 → 3/3, predicate journeys_passing_after>=3
  CONFIRMED; the backend served 127.0.0.1:5177 via CHAIN_START_BACKEND_CMD and the
  browser lane produced PASS evidence both iterations. Run record:
  benchmarks/results/20260712-171324-5e87813077ae.json + POST bench-20260712-1536
  in benchmarks/experiments.md — cost REGRESS +43.1% vs baseline was PRE-REGISTERED:
  the previously-voided lane now executes and bills.)*
- **Source:** promoted 2026-07-11 from CAND-SVC-BOOT **variant (a) ONLY** by explicit
  user decision (EVO-1 promotion; bundling with REL-11 in one session user-authorized —
  G6 satisfied by that recorded authorization). The general boot-resolution fix
  (variant (b)) stays STAGED in §16. Root evidence: EVO-3 first real baseline
  (bench-20260710-2117 @ c48f25047126).
- **Problem:** the deterministic service-boot lane never consults the project's
  documented start command. Resolution order (`goal-iter-lean.sh:335-342`;
  `qa-phase.sh:73-81` same pattern): `CHAIN_START_BACKEND_CMD` env → else
  `bash scripts/start-backend.sh` if present → else nothing. The generic framework
  template (`scripts/start-backend.sh`: `cd apps/backend` + uvicorn, port 8000 +
  hash offset) ships in the subrepo set the benchmark assembly copies wholesale
  (`run-benchmark.sh:208-222`); the fixture has no `scripts/` dir of its own, so the
  FastAPI-flavored template lands uncontested and shadows the fixture
  project-template's documented command (`.venv/bin/python app.py` serving
  127.0.0.1:5177 — `benchmarks/fixtures/todo-app/.claude/project-template.md:102-106`;
  `/health` endpoint at `app.py:36-37`, port pinned at `app.py:42`). The health probe
  is blind the same way: default `http://localhost:8000/health`
  (`goal-iter-lean.sh:344-346`; hash-offset resolved it to :8763 in the baseline run) —
  the fixture's 5177 appears nowhere.
- **Evidence (carried from CAND-SVC-BOOT):**
  `benchmarks/results/20260710-224206-c48f25047126.json` — journeys 0/3 while the chain
  built all three to reviewer-PASS / COHERENCE-PASS / 15-of-15-pytest quality; ledger
  POST assessment under `## POST bench-20260710-2117` (`benchmarks/experiments.md`).
  Kept scratch: the iter-1 backend service log is the single line
  `cd: .../scratch/apps/backend: No such file or directory`
  (`runs/goal-bench-20260710-2117-iter-1/service-logs/qa-backend-8763.log`).
- **Current state:** all three boot knobs are ALREADY env-overridable —
  `CHAIN_START_BACKEND_CMD` (`goal-iter-lean.sh:335`, `qa-phase.sh:73`),
  `CHAIN_BACKEND_PORT` (`goal-iter-lean.sh:344`, `qa-phase.sh:84`; `common.sh:354`
  auto-assigns ONLY when unset), `CHAIN_BACKEND_HEALTH_URL` (`goal-iter-lean.sh:346`,
  `qa-phase.sh:86`). No engine change needed — the fix is purely runner-side.
- **Change spec (benchmark-local; NO engine edits):**
  1. New `benchmarks/fixtures/todo-app/fixture.env` — KEY=VALUE manifest:
     `START_CMD='.venv/bin/python app.py'`, `PORT=5177`,
     `HEALTH_URL='http://127.0.0.1:5177/health'` (kept consistent with the fixture
     project-template's SERVICE START COMMANDS — the chain creates `.venv` per that
     template).
  2. `run-benchmark.sh` sources it (when present) after assembly and exports
     `CHAIN_START_BACKEND_CMD` / `CHAIN_BACKEND_PORT` / `CHAIN_BACKEND_HEALTH_URL`
     into the engine's environment — the existing env-honesty capture records all
     three in the results JSON `chain_env` block for free.
  3. No fixture `scripts/start-backend.sh` (verified: no engine path ignores the env
     route — prefer minimal).
- **DoD:** runner test proves the three vars present + correct in the stub engine's
  environment when `fixture.env` exists AND assembly stays green when it is absent
  (other fixtures someday); post-fix benchmark rerun moves journeys 0→3.
- **Verify:** `bash tests/automation/test-benchmark-runner.sh &&
  ./scripts/automation/run-evals.sh`; rerun per §9 "When to benchmark" with
  `--predict 'journeys_passing_after>=3'` + `benchmark_compare.py` vs the recorded
  baseline.
- **Files:** `benchmarks/fixtures/todo-app/fixture.env` (new),
  `scripts/automation/run-benchmark.sh`, `tests/automation/test-benchmark-runner.sh`.
- **Rollback:** delete `fixture.env` + revert the runner hunk (engine untouched by
  construction).
- **Stop-and-ask:** any engine edit (`goal-iter-lean.sh` / `qa-phase.sh` /
  `common.sh`) starts looking necessary — that is variant (b) territory, which stayed
  staged.

### REL-11 · Headless scratch trust + missing-evidence tripwire
- **Priority:** P1 · **Effort:** M (honest re-grade: CAND proposed S for the guard-only
  shape; the promoted scope — controlled probe + user-global trust write with
  backup/revert safety + fake-HOME test harness + a three-site tripwire — is a full
  session for the canonical weaker-model executor. Per G8 this item does NOT
  self-certify DONE in the implementing session.) · **Risk:** MED (writes user-global
  `~/.claude.json`) · **Status:** DONE — implemented + live-verified
  2026-07-12 @ 5e87813077ae; certified 2026-07-12 by a fresh non-implementer
  session per G8. *(Evidence for the certifier: offline —
  test-benchmark-runner.sh 54/54 under fake HOME (trust present during engine run,
  reverted on success AND engine-failure paths, siblings preserved, backup kept,
  corrupt-json refusal pre-engine), test-goal-retro.sh 41/41 (tripwire fire/no-fire
  incl. the silent rc=0 void shape), run-evals.sh 96/96. Live — rerun
  bench-20260712-1536: 0 of 25 traces carry the trust banner (baseline: all),
  reports/qa/ populated, retro report persisted (EVO-2's first live artifact),
  trust key verified absent from ~/.claude.json post-run, missing-evidence tripwire
  fired 0 times consistent with zero voids. Run record: POST bench-20260712-1536.)*
  *(G8 certification 2026-07-12, fresh non-implementer session: trust write
  re-verified atomic (mkstemp + os.replace) and single-key (setdefault chain touches
  only projects[<scratch>]); timestamped backup precedes the first write; revert
  re-reads the LIVE file, pops exactly the scratch entry, and self-verifies absence.
  Exit paths enumerated from the code: clean success and engine-nonzero both hit the
  inline revert (ENGINE_RC captured, set -e survives); trust-write failure aborts
  pre-engine with no key written; runner crash and Ctrl-C/SIGTERM hit the EXIT trap
  (installed before the write, flag set before the write); a failed revert leaves
  the flag set so the final gate refuses exit 0 and prints manual-removal
  instructions + backup path; SIGKILL is uncoverable by construction — backup is the
  documented recovery. Test isolation confirmed: every runner invocation goes
  through run_runner with HOME + TMPDIR forced to per-case fixtures — the suite
  cannot address the real ~/.claude.json. All suites reproduced green (54/54, 41/41,
  96/96). Live evidence re-verified against the kept scratch: 25 trace logs
  (+ trace.jsonl index), 0 banner hits across all files; QA report/test-plan/
  evidence dirs present; retro report present; no projects entry for the 1536
  scratch in ~/.claude.json today. Observation, not residue: the 2026-07-10
  BASELINE scratch's entry (hasTrustDialogAccepted:false + default siblings,
  claude's own auto-creation, predates REL-11) is still present — remove it
  whenever the kept baseline scratch is cleaned. One small defect fixed in
  certification: `missing_evidence` was absent from docs/goal-mode-telemetry.md's
  event catalog — section added (name/shape were already eval-pinned by
  test-goal-retro.sh per G3).)*
- **Source:** promoted 2026-07-11 from CAND-HEADLESS-PERMS (fully promoted — CAND
  deleted) by explicit user decision, including explicit authorization of the
  trust-flag variant (the ask-first `~/.claude.json` write) and of bundling with
  REL-10 in one session. Root evidence: EVO-3 first real baseline
  (bench-20260710-2117).
- **Problem:** headless dispatches carry no permission flags beyond the per-agent deny
  overlay (`--disallowedTools` + budget, `lib/quota-retry.sh:603-645`) — write access
  relies entirely on the allow list in `.claude/settings.json`. Claude Code honors
  that list only in a TRUSTED workspace: trust is keyed by absolute path in
  `~/.claude.json` (`projects[<path>].hasTrustDialogAccepted`; verified live: the
  baseline scratch path sits in this machine's `~/.claude.json` with
  `hasTrustDialogAccepted: false`), a benchmark scratch is a fresh mktemp path every
  run — never trusted — and no headless run can answer the trust/permission prompt.
  NOT a missing-file problem: the scratch carried BOTH `settings.json` and the
  gitignored `settings.local.json`, byte-identical to the repo's
  (`run-benchmark.sh:218` `cp -a` copies gitignored files too), and every agent trace
  opens with "Ignoring 122 permissions.allow entries … this workspace has not been
  trusted". Friction counters were all zero — nothing surfaced the missing evidence;
  the damage mode is SILENT.
- **Evidence (carried from CAND-HEADLESS-PERMS):** kept-scratch traces
  (`runs/goal-session-bench-20260710-2117/trace/` in
  `~/.cache/chain-bench-tmp/bench-bench-20260710-2117.EMAuTK/scratch`): `0014-qa.log` —
  trust banner at line 1, tail: "I can't write the QA report due to permission
  restrictions" — the QA verdict exists ONLY in stdout, no artifact
  (`reports/qa/` empty); `0028-retro-analyst.log` — ends "am writing the report to the
  output path now", yet no `reports/goal-session-*-retro.md` exists while the
  engine-shell-written `state/retro-input.md` does (shell writes unaffected; agent
  Write blocked). Non-uniformity note: iteration-summarizer/reviewer wrote `reports/`
  files in the SAME untrusted workspace (trace `0026` wrote two) while both blocked
  dispatches were light-tier (qa, retro-analyst). Per-agent deny overlays are ruled
  out: `agent_permissions.py disallowed` returns IDENTICAL lists for
  qa/retro-analyst/reviewer/iteration-summarizer (no Write denial anywhere).
- **Probe protocol + findings (2026-07-11, user-authorized, 5 one-tool dispatches ≈
  cents):** fresh mktemp scratch under `~/.cache/chain-bench-tmp` (same parent as
  bench scratches), repo `.claude/settings*.json` copied in, git init + commit;
  `claude -p` dispatches with cwd=scratch, no permission flags (the engine's dispatch
  shape); prompts forced a single tool route ("Using ONLY the Write tool …" /
  "Using ONLY the Bash tool … `mkdir -p reports && echo BASH-OK > reports/...`"),
  with denials echoed verbatim. Sequence: P1 Write @ haiku untrusted → P2 Bash @
  haiku untrusted → pre-trust the path (the fix mechanism, by hand) → P3 Write @
  haiku trusted → P4 Bash @ haiku trusted → revert → P5 Write @ sonnet untrusted.
  Findings:
  - **(i) banner ↔ denial:** the "Ignoring 122 permissions.allow entries" banner
    appears on EVERY untrusted dispatch and none of the trusted ones, but it marks
    allow-list suspension, not denial per se — the Write DENIAL is model-tier
    dependent (see ii). P1 (haiku, untrusted): banner + `WRITE-TOOL-DENIED: Claude
    requested permissions to write to <path>, but you haven't granted it yet`,
    no artifact. P3 (haiku, trusted): no banner, artifact written.
  - **(ii) baseline non-uniformity EXPLAINED (and the CAND's per-agent-flag
    hypotheses ruled out):** deny overlays are identical across
    qa/retro-analyst/reviewer/iteration-summarizer; wrappers never capture stdout to
    files; agent-file `tools:` frontmatter is not applied to `-p` dispatches;
    directory pre-existence is ruled out (retro's target `reports/` existed —
    `run-goal.sh` mkdirs it — and was still denied). The discriminator is the
    dispatched MODEL: P5 (sonnet-5, same untrusted scratch, same
    nonexistent-parent target as P1) WROTE the file with the banner present.
    Untrusted headless Write: haiku-4-5 → permission request → auto-deny;
    sonnet-5 → proceeds. This exactly reproduces the baseline: qa and
    retro-analyst are the flow's only light-tier report writers → theirs were the
    only voided artifacts.
  - **(iii) pre-trust fully clears it:** P3 (haiku + trusted) wrote via the Write
    tool with no banner. The single per-run `projects[<scratch>]` key is necessary
    AND sufficient — no global state beyond it (stop-and-ask trigger NOT hit).
  - Extras pinned for the design: `claude` itself creates
    `projects[<path>]` (with `hasTrustDialogAccepted: false` + sibling default
    keys) on the first dispatch in an unknown dir, and concurrent claude processes
    rewrite `~/.claude.json` continuously (observed cache-key churn) — therefore
    the runner's revert must RE-READ the current file and pop the single
    `projects[<scratch>]` entry, NEVER restore the whole backup (that would clobber
    concurrent state); the backup is disaster recovery only. Bash-redirect writes
    are a separate lane: untrusted → per-command approval denied; trusted → the
    Bash sandbox still blocked a redirect into a not-yet-existing directory
    (P4: "Output redirection … was blocked … may only write to files in the
    allowed working directories"). Not REL-11's problem (trusted agents use the
    allow-listed Write tool), recorded for future triage. Probe logs:
    session scratchpad `probe-out/` (P1-P5).
- **Change spec:**
  1. **Scratch trust (user-authorized):** `run-benchmark.sh`, after mktemp and BEFORE
     engine launch, sets `projects["<abs scratch path>"].hasTrustDialogAccepted =
     true` in `~/.claude.json` via an atomic python3 edit (read → modify → write
     temp → `os.replace`), taking a timestamped backup of the file first. The entry
     is REMOVED (the whole `projects["<abs scratch path>"]` subtree — the path is
     mktemp-fresh, so the runner created it; the engine may add sibling keys under it
     during the run, all dangling once the scratch is deleted) immediately after the
     engine exits, with an EXIT-trap safety net covering every exit path (runner
     failure, Ctrl-C). No other key is ever touched. Tests run the runner under an
     overridden `HOME` with a fixture `claude.json` — the suite must NEVER write the
     real one.
  2. **Missing-evidence tripwire (wanted regardless of 1):** at the dispatch sites
     whose absent artifacts voided the baseline — full-mode QA
     (`qa-phase.sh`, expected `reports/qa/<phase>-qa.md`), lean browser-qa lane
     (`goal-iter-lean.sh`, expected LLM-lane results file), retro-analyst
     (`run-goal.sh` `_run_retro_analyst`, expected
     `reports/goal-session-<sid>-retro.md`) — when the dispatch returns without its
     expected report file on disk: a LOUD `[missing-evidence]` stderr banner naming
     agent + expected path, plus a `missing_evidence` telemetry event
     (`{agent, path}`). Non-blocking (banner, not gate). Shared helper in
     `lib/common.sh`; telemetry emission guarded like `common.sh:742` (no-op where
     telemetry.sh is not sourced / GOAL_SESSION_DIR unset).
- **DoD:** offline tests prove (trust) the key is present in the fixture
  `claude.json` during the stub engine run, ABSENT after both success and
  engine-failure exits, sibling keys byte-preserved, timestamped backup written; and
  (tripwire) the `missing_evidence` event + banner fire on a stub dispatch that
  writes nothing and do NOT fire when the report exists. Post-fix rerun: trust banner
  absent from every trace; QA report + retro report EXIST in scratch.
- **Verify:** `bash tests/automation/test-benchmark-runner.sh &&
  bash tests/automation/test-goal-retro.sh && ./scripts/automation/run-evals.sh`;
  rerun per §9.
- **Files:** `scripts/automation/run-benchmark.sh`, `scripts/automation/lib/common.sh`
  (tripwire helper), `scripts/automation/qa-phase.sh`,
  `scripts/automation/goal-iter-lean.sh`, `scripts/automation/run-goal.sh`,
  `tests/automation/test-benchmark-runner.sh`, `tests/automation/test-goal-retro.sh`.
- **Rollback:** revert the commit; any leftover `projects[<scratch>]` key is
  recoverable from the timestamped `~/.claude.json` backup the runner takes before
  its first write.
- **Stop-and-ask:** the probe shows the trust mechanism needs global state beyond the
  single per-run `projects[<scratch>]` key; the revert trap cannot be made to cover an
  exit path; the trust banner appears in ANY post-fix rerun trace (that is a RESULT to
  report, not to patch mid-run); anything that would weaken the spend gate or the
  revert trap (G5 — both are safety mechanisms; tests must prove the revert).

### REL-12 · Single-service frontend resolution for the lean browser lane
- **Priority:** P1 · **Effort:** S · **Risk:** LOW-MED · **Status:** DONE
  2026-07-14 (live evidence: §9 run C `bench-20260714-1539` — see the measurement
  note; staged 2026-07-14, user-approved; REL-10 family)
- **Problem:** on a single-service project (frontend server-rendered by the backend —
  the todo-app fixture, any Flask/Django app), the lean browser-qa lane boots the
  generic Next.js frontend template, fails twice, and tells browser-qa
  "Frontend available: no" → every journey SKIPPED, zero lean browser evidence.
  Proven live 2026-07-14: BOTH §9 runs' iter-0 lanes skipped all three journeys for
  exactly this (A′ probed :3822, B :3247 — derived defaults; ledger POSTs
  bench-20260714-0634 / -0830). Until fixed, lean iter-0 evidence is structurally
  impossible on such projects, and any future SPEED-2/3 flip re-measurement stays
  unresolvable at lean depth.
- **Current state:** REL-10's `fixture.env` localizes the BACKEND
  (`CHAIN_START_BACKEND_CMD`, port 5177) but nothing points the frontend at the same
  service; `run_browser_qa_boot_and_replay` (goal-iter-lean.sh) defaults
  `FRONTEND_URL=http://localhost:${CHAIN_FRONTEND_PORT:-3000}` and requires a
  frontend boot + health check before setting `FRONTEND_AVAILABLE=yes`.
- **Change spec:** two halves, both small. (a) ENGINE: in
  `run_browser_qa_boot_and_replay`, before attempting a frontend boot, probe
  `$FRONTEND_URL` directly; if it already answers (single service, server-rendered —
  e.g. `CHAIN_FRONTEND_URL` set to the backend URL), set `FRONTEND_AVAILABLE=yes`
  and skip the boot entirely. (b) FIXTURE: `benchmarks/fixtures/todo-app` env
  manifest adds `CHAIN_FRONTEND_URL=http://127.0.0.1:5177` (and the fixture's
  project-template STACK already names that URL — keep them consistent). Never
  silently skip: when the direct probe is what enabled the lane, log one line
  naming the URL.
- **DoD:** benchmark iter-0 browser-qa EXECUTES journeys on the todo-app fixture
  (SKIP-for-boot gone; failing-journey evidence recorded instead of `unknown`);
  parallel-bqa evals green (scenario with FRONTEND_URL pointing at the dummy backend
  port asserts "Frontend available: yes" reaches the prompt); run-evals green.
- **Verify:** `bash tests/automation/test-goal-parallel-bqa.sh` (new scenario) +
  `./scripts/automation/run-evals.sh`; live proof rides the next approved benchmark.
- **Files:** `scripts/automation/goal-iter-lean.sh` (boot short-circuit),
  `benchmarks/fixtures/todo-app` env manifest (REL-10's mechanism),
  `tests/automation/test-goal-parallel-bqa.sh`.
- **Rollback:** remove the probe short-circuit (boot path unchanged otherwise).
- **Stop-and-ask:** if the short-circuit would also fire on genuinely two-service
  projects whose frontend happens to answer on the backend URL (misconfig), prefer
  a loud log + proceed — but ask before adding any template-parsing heuristics.
- **Trigger:** hit live 2026-07-14; also the prerequisite for a resolvable
  SPEED-2/3 flip re-measurement at lean depth.
  *Measurement note (2026-07-14, §9 run C `bench-20260714-1539` @ 39e2a79de68a,
  knobs off):* DoD landed in full. Engine: the short-circuit fired in BOTH
  iterations, one loud line each naming the URL ("Frontend already answering at
  http://127.0.0.1:5177 (HTTP 200) — direct probe enabled the browser lane;
  skipping the frontend boot"). Iter-0 browser-qa EXECUTED all three journeys —
  verdict "FAIL (0/3 passed, 0 skipped)" with per-journey DOM diagnostics and
  three PNG evidence files (A′/B iter-0: SKIP ×3, empty evidence dir, unknown ×3)
  — failing evidence recorded instead of unknown, exactly the DoD. Composition
  bonus: with real iter-0 evidence the chain stayed lean and reached
  GOAL_ACHIEVED at −36.6% wall vs A′. Fixture: run-benchmark.sh needed one extra
  manifest mapping (CHAIN_FRONTEND_URL export — REL-10's mechanism extended);
  fixture project-template STACK's "Frontend URL" row now names
  http://127.0.0.1:5177 explicitly (was "N/A — same Flask server..."). Offline:
  parallel-bqa scenario J (80/80) + run-evals green. Evidence: ledger PRE/POST
  bench-20260714-1539; scratch kept at /tmp/bench-bench-20260714-1539.5Ro0t7.

### REL-13 · Chain temp off the quota'd tmpfs + disk-pressure automation (never interrupt on ENOSPC)
- **Priority:** P0 · **Effort:** M · **Risk:** LOW · **Status:** DONE
  *(implemented 2026-07-14: goal-mode chains kept halting mid-run on
  `Disk quota exceeded` — `/tmp` on the reference machine is a 13.3G tmpfs
  mounted `usrquota`, so EDQUOT fires long before the fs looks full, and one
  product pytest run wrote a 744MB basetemp under a live `iad.` dir while
  concurrent projects (tapeology, trendora) stacked theirs on top; leaked
  `bench-*` scratch (kept-on-failure, never in any janitor pattern) and
  `judgment-*` sandboxes accumulated for days, and interactive-mode subagents
  ignored the engine TMPDIR entirely (advisory prompt relay only). Fix, four
  layers. (1) Relocation: `chain_tmp_init` root default `/tmp` →
  `~/.cache/iad` (206G un-quota'd ext4), TMPDIR capped at 62 chars for
  Chromium's 108-char unix-socket limit (long ids → `<prefix>-<sha256[:8]>`,
  raw id in `.chain-run-id`), adoption now liveness-checked (a dead engine's
  inherited dir mints fresh instead), `bench-*`/`judgment-*` scratch moved
  under the root with `.owner-pid` liveness files; the user-global
  `~/.claude/settings.json` gained `env.TMPDIR=~/.cache/iad/shared` so
  interactive/dispatched agents in ALL projects write to disk too (probe
  verified: settings-env OVERRIDES a parent-exported TMPDIR for `claude -p`
  children, so agent-side writes age out via the 72h `shared/` sweep rather
  than per-iteration rotation — both lanes land on the big disk). (2)
  Multi-root janitor: sweeps `CHAIN_TMP_ROOT` + `CHAIN_TMP_LEGACY_ROOTS`
  (default `/tmp`; tests MUST pass `""`), new patterns `bench-*`
  (keep-newest-`CHAIN_BENCH_KEEP=2`), `judgment-*`, `shared/`
  (`CHAIN_TMP_SHARED_MAX_AGE_HOURS=72`); `--aggressive` reaps dead-pid run
  dirs at ANY age. (3) `chain_tmp_disk_guard`: statvfs on the root + a WRITE
  PROBE on /tmp (statvfs cannot see tmpfs user quotas; EDQUOT/ENOSPC on a
  32MB probe is the honest signal) → aggressive sweep under pressure; wired
  at engine preflight (`preflight_disk_space`, beside the GitHub preflight),
  the top of every iteration (halt-check block, never mid-iteration), and
  soft-mode in run-phase.sh/goal-iter-lean.sh; only a still-critical ROOT fs
  after sweeping pauses as resumable `AWAITING_DISK` (resume tuple, showcase
  tail kill, header, skill runbook all updated; `AWAITING_GITHUB_AUTH` also
  added to the resume tuple — pre-existing gap). (4) Agent self-service:
  `scripts/automation/tmp-doctor.sh` (`--status`/`--clean`/`--aggressive`,
  sources only chain-tmp.sh, zero permission prompts via the `scripts/*`
  allow) + the standing rule in core.md "Environment Errors" and
  anti-pattern #21: on ENOSPC/EDQUOT run tmp-doctor --aggressive, retry once,
  never rm arbitrary /tmp files, never ask the user. `~/.cache/iad` added to
  `additionalDirectories` (rm containment parity with /tmp). Regression:
  chain-tmp self-test 20→31 assertions (stale-adopt, socket budget,
  legacy-root sweep, bench retention, judgment reap, shared sweep, guard rc
  semantics), test-tmp-cleanup.sh 7→9 (default-root derivation, engine guard
  pathway), test-benchmark-runner.sh 54/54 (TMPDIR kept in the bench root
  fallback chain for harness compat). Delivers REL-2's disk-space row;
  rest of the doctor remains TODO.)*

### REL-14 · Browser-infra make-up lane (primary browser-qa preflight + screenshot-only recovery)
- **Priority:** P1 · **Effort:** M · **Risk:** MED · **Status:** IN-PROGRESS
  *(mini-spec authored 2026-07-17 in the user-approved throughput package; absorbs
  §16 CAND-BQA-PREFLIGHT — see its absorption note. IMPLEMENTED 2026-07-18, user-
  directed "do the next step": all five components as specced, TDD red→green via
  `tests/automation/test-browser-infra-makeup.sh` (27 asserts: probe/preflight
  one-retry/token attempts-counter/conservative classifier units + wiring greps +
  checkpoint-enum invariance) registered in run-evals §2c. As built: shared
  helpers `lib/replay-lane.sh:149/:165/:178/:209` (`bqa_services_probe`,
  `bqa_preflight`, `bqa_write_infra_token`, `bqa_results_infra_reason`); lean lane
  union `goal-iter-lean.sh:208`, preflight `:710`, post-scan `:750`; full lane
  preflight `browser-qa-phase.sh:303`, post-scan `:399`, blocked-stub after the
  merge; engine make-up scheduling + CHAIN_BQA_MAKEUP_JOURNEYS/_PREV_ATTEMPTS
  exports `run-goal.sh:1677-1703`, BINDING decomposer line + evaluator input line
  `run-goal.sh:2066` mirrored VERBATIM into the judgment harness
  (`run-judgment-evals.sh:267` — the two prompts must stay in lockstep);
  methodology A.3 carve-out (`skills/goal-evaluation-methodology.md` — note: the
  pre-REL-14 rail scored no-citation as `unknown`; token journeys now score
  `partial(pending-infra)`, never passing/failing/regressed on infra absence) +
  `pending_infra` boolean + two-strike rule in `agents/goal-evaluator/body.md`
  (agent.yaml 1.7.0); judgment fixture
  `tests/judgment/goal-evaluator/case-06-pending-infra-makeup/` AUTHORED with
  real spec-hashes (expected CONTINUE; harness --list discovers it, ~$2.38/run).
  Neighbors re-run green: replay-lane, replay-lane-full, goal-parallel-bqa,
  goal-checkpoints, goal-async-tail. G9 FIXTURE RUN DONE 2026-07-18
  (user-approved): PASS — got CONTINUE in 344s (opus-4-8, effort max);
  supplementary --keep-sandbox inspection confirmed the full contract, J-01 AND
  J-02 both `partial` + `pending_infra: true`, J-01's prior pass preserved (no
  REGRESSION over-call), eval.md reasons "browser evidence is owed" and "unit
  tests are not journey evidence" verbatim-class. STILL OUTSTANDING before
  DONE: (a) G8 fresh-session certification (non-implementer), (b) one
  real-session observation with CHAIN_BQA_PREFLIGHT=true (knob ships DEFAULT
  OFF per G4) — pairs naturally with SPEED-4's lean:full after-measurement.)*
- **Problem:** a browser-infra failure in the PRIMARY browser-qa lane costs a whole
  iteration. REL-5 gave the golden-replay lane SKIPPED-INFRA discipline
  (`lib/replay-lane.sh:185-215`: rc-6 → services re-check → ONE retry → second rc-6
  = SKIPPED-INFRA, never FAIL), but the primary LLM lane
  (`goal-iter-lean.sh:616-676` `run_browser_qa_llm`; full depth via Branch-A →
  `browser-qa-phase.sh`) has no preflight, no retry, and no infra state. Evidence:
  tapeology `goal-session-fast_wall` iter-4 (~4h, 0 journeys moved): code complete
  and API/CLI-proven, but Chrome MCP died → no screenshot → J-04 scored `partial` →
  iter-5 forced a full re-target (browser-qa ran twice across the pair, ~65m).
  Cross-repo chronic evidence: the harvest quotes in §16 CAND-BQA-PREFLIGHT
  (trendora ×2, tapeology structure_ui).
- **Change spec:** (1) *Preflight:* deterministic services probe (frontend 200 +
  backend health + headless-Chrome readiness where checkable; overlap-check vs
  `ensure_services_running`, `lib/common.sh:770`, per the candidate's triage note)
  immediately before `run_browser_qa_llm` and before Branch-A's browser-qa; on
  failure re-check + ONE retry (mirror `replay-lane.sh:196-203`); knob
  `CHAIN_BQA_PREFLIGHT`, default off for its first session (G4). (2) *Infra token,
  out-of-band:* a second preflight failure — or a post-scan classifier (results
  file whose rows are all SKIP with infra-taxonomy reasons, or a missing results
  file plus a captured MCP/Chrome error; catches mid-run Chrome death that no
  preflight can) — writes `$ITER_DIR/browser-infra.json`
  `{journeys, reason, attempts, detected_by}`. The merged `ui-test-results.md`
  verdict line stays `PASS|FAIL|SKIPPED` — the checkpoint greps in
  goal-iter-lean.sh and `verdicts.py` BrowserQAVerdict must NEVER see a new enum
  value. (3) *Evaluator contract:* one new dispatch input line (evaluator prompt,
  `run-goal.sh:2012` region) + body edit (`agents/goal-evaluator/body.md`):
  journeys named in `browser-infra.json` with no fresh screenshot score `partial`
  with gap text `pending-infra` and journey-history boolean `pending_infra: true` —
  NOT a new status enum (no `goal_gate.py` / renderer ripple). The
  no-screenshot-no-pass rail stays absolute; `partial` blocks GOAL_ACHIEVED exactly
  as today. (4) *Make-up scheduling:* next iteration, pre-decomposer, run-goal.sh
  reads the prior journey-history `pending_infra` set; if non-empty it inlines a
  BINDING decomposer line ("include these as verify-only targets; do NOT re-plan
  their implementation — code is present, only browser evidence is missing") AND,
  as an engine safety net, unions them into the executor's browser-qa journey set
  (the Required-set union mechanism). No developer work; the normal evaluator flips
  `partial(pending-infra)` → `passing` or `failing`, honestly. (5) *Two-strike
  rule:* `attempts` counts across iterations; 2 consecutive infra-blocked
  iterations for the same journey ⇒ the evaluator treats it as a human-owned
  blocker (STALLED-class, decomposer rule 6) — the engine never silently loops on
  dead infra.
- **DoD:** sandbox test forces a preflight double-failure → token written, merged
  verdict enum untouched, checkpoint greps still parse; a goal-evaluator judgment
  fixture scores `partial` + `pending_infra: true`; the make-up path re-verifies
  WITHOUT a developer dispatch; evals green; G8 fresh-session certification + one
  real-session observation.
- **Verify:** new `tests/automation/test-browser-infra-makeup.sh` ·
  `./scripts/automation/run-evals.sh` · judgment fixture run (G9 spend).
- **Files:** `scripts/automation/goal-iter-lean.sh`,
  `scripts/automation/browser-qa-phase.sh`, `scripts/automation/run-goal.sh`,
  `agents/goal-evaluator/body.md` (+ mirror, version bump),
  `scripts/automation/lib/replay-lane.sh` (shared probe helper), tests, this file.
- **Rollback:** preflight behind the knob; token/consumer edits revert cleanly —
  an absent `browser-infra.json` is byte-for-byte today's behavior everywhere.
- **Stop-and-ask:** anything that would touch the `PASS|FAIL|SKIPPED` verdict greps
  or `verdicts.py`; any judgment-fixture verdict-class flip; G9 for fixture spend.
- **Expected saving:** an iter-4-class infra loss becomes a ~30m screenshot-only
  make-up instead of a ~4h re-target iteration.

---

## 11. P1 — Security

The chain has NO third-party scanners today — protection is allow/deny permission
lists, the install gate (`hooks/install-security-gate.sh` →
`lib/install-gate.py` + `config/install-security-policy.json`), the dangerous-command
guard, and regex-grade `lib/scan_diff.py` wired into the achievement gate. These items
add real scanners with graceful degradation (deterministic tools = ideal weaker-model
territory).

### SEC-1 · Secrets scanner integration (gitleaks)
- **Priority:** P1 · **Effort:** M · **Risk:** LOW · **Status:** TODO
- **Problem:** `scan_diff.py` catches common credential shapes only (letter explicitly:
  "regex-grade… not exotic secrets").
- **Current state:** per-iteration diff scan via `goal_gate_build_diff_artifacts`
  (`lib/goal-gates.sh:57`) → `iter-<N>/scan-report.md`; CRITICAL blocks GOAL_ACHIEVED
  (`goal_gate_achievement`, `goal-gates.sh:107`). The scanned diff is the PRODUCT diff:
  harness bookkeeping is path-excluded via `CHAIN_SCAN_BOOKKEEPING_EXCLUDES` (SEC-5).
- **Change spec:** new `scripts/automation/lib/security_scan.sh`: if `gitleaks` (or
  `trufflehog`) is on PATH — run it in diff mode per iteration (append findings to
  `scan-report.md` with the same CRITICAL semantics) and full-tree on GOAL_ACHIEVED
  before the two-key confirm; if absent — one WARN line ("gitleaks not installed —
  regex scan only") and proceed. Diff mode MUST consume the same bookkeeping-excluded
  diff `goal_gate_build_diff_artifacts` builds (SEC-5) — feeding gitleaks the raw
  tracked+untracked tree reintroduces the self-scan recursion (anti-pattern #22); the
  full-tree pass on GOAL_ACHIEVED must likewise skip `runs/ reports/ docs/handoffs/
  docs/phases/`. Eval fixture: planted fake secret detected in a fixture diff (skip
  cleanly when tool absent so CI stays green).
- **DoD:** with gitleaks installed, planted secret → CRITICAL → gate demotion; without,
  behavior unchanged + warning; evals green both ways.
- **Verify:** `bash -n scripts/automation/lib/security_scan.sh &&
  ./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/lib/security_scan.sh` (new),
  `scripts/automation/lib/goal-gates.sh`, `run-evals.sh` fixture,
  `docs/TROUBLESHOOTING.md` install note.
- **Rollback:** remove the two call sites; regex scan remains.

### SEC-2 · Dependency audit step
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** TODO
- **Problem:** nothing audits the DEPENDENCIES the developer adds (the install gate
  vets install *commands*, not the resolved vulnerability state).
- **Current state:** install gate + `scan_diff.py` paid-SaaS dependency flags
  (WARN default / CRITICAL under `CHAIN_SCAN_STRICT_DEPS`).
- **Change spec:** extend `security_scan.sh` (SEC-1): if `package.json` present and
  `npm` available → `npm audit --omit=dev --audit-level=high --json` (parse count);
  if python deps present and `pip-audit` available → run it. High/critical findings →
  WARN rows in scan-report by default, CRITICAL under the existing
  `CHAIN_SCAN_STRICT_DEPS`. Graceful skip when tools absent. Runs on GOAL_ACHIEVED
  (full) — not per-iteration (too slow/noisy).
- **DoD:** fixture with a known-vulnerable pinned dep flags when tooling present, skips
  cleanly otherwise; evals green.
- **Verify:** `./scripts/automation/run-evals.sh` + manual run in a fixture repo.
- **Files:** `scripts/automation/lib/security_scan.sh`, gate call site, fixture.
- **Rollback:** remove the audit block.
- **Depends on:** SEC-1 (same script).

### SEC-3 · Pre-delivery security audit pass
- **Priority:** P1 · **Effort:** M · **Risk:** MED · **Status:** TODO
- **Problem:** GOAL_ACHIEVED certifies journeys + anti-goals + scans, but no one ever
  reads the security findings as a whole before the product is declared delivered.
- **Current state:** delivered wrap is written by the summarizer on GOAL_ACHIEVED;
  gates run mechanically.
- **Change spec:** on GOAL_ACHIEVED, after gates + confirm and before the delivered
  wrap: run SEC-1/SEC-2 full-tree, then ONE strong-tier dispatch that reads ONLY the
  findings reports (token-lean) and writes `reports/goal-session-<sid>-security-audit.md`
  with `**Verdict:** SECURITY-PASS|SECURITY-NOTES|SECURITY-FAIL`. Advisory by default
  (NOTES/FAIL do not block); blocking mode behind `CHAIN_SECURITY_AUDIT_BLOCKING`
  (default false). Register the verdict in `lib/verdicts.py` + fixture (G3).
- **DoD:** sandbox GOAL_ACHIEVED produces the report; blocking mode demotes to CONTINUE
  in a fixture; evals green.
- **Verify:** fixture + `./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/run-goal.sh` or `lib/goal-gates.sh`,
  `lib/verdicts.py`, template (new), fixture.
- **Rollback:** advisory default = zero behavior change; remove the dispatch call.
- **Stop-and-ask:** before ever flipping blocking mode on — user decision.
- **Depends on:** SEC-1, SEC-2.

### SEC-4 · CI security workflow
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** TODO
- **Problem:** CI runs only the offline eval suite; the FRAMEWORK repo itself gets no
  secret/dependency scanning.
- **Current state:** `.github/workflows/evals.yml` only.
- **Change spec:** add a security job: gitleaks action (pinned version) on the repo +
  `pip-audit`/`npm audit` where manifests exist; plus a documented copy-paste snippet in
  the docs for ADOPTING repos. Non-blocking (report) first; required-check upgrade is a
  human decision later.
- **DoD:** workflow green on current tree; snippet documented.
- **Verify:** CI run on a branch push; `grep -n security .github/workflows/*.yml`
- **Files:** `.github/workflows/evals.yml` (or new `security.yml`), docs.
- **Rollback:** delete the job.

### SEC-5 · Scan-input hygiene: the gate scans the product diff, never harness bookkeeping
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** DONE
  *(implemented 2026-07-11 from the tapeology `yahoo_fetch` handoff
  (`upstream-scanner-recursion-fix.md`): `goal_gate_build_diff_artifacts`
  (`lib/goal-gates.sh:57`) folded EVERY untracked file into the scanned diff with no
  path exclusion, so the harness's own `runs/`+`reports/` artifacts — including the
  scanner's previous `scan-report.md`, which quotes matched tokens — were re-scanned
  each build: self-referential CRITICAL findings compounding 1 → 3 → … and blocking
  GOAL_ACHIEVED on a clean product. Fix: `CHAIN_SCAN_BOOKKEEPING_EXCLUDES`
  (default `runs reports docs/handoffs docs/phases`, knob table in
  `.claude/model-orchestration.md`) applied as `:(exclude)` pathspec to BOTH the
  tracked diff and the untracked enumeration; untracked files now diffed by relative
  path (proper `a/… b/…` headers — the old absolute-path+sed combo mangled them to
  `bpath`, which also defeated `diff_bound.py`'s excludes); provenance footer on
  `scan-report.md`; empty/crashed scan-report now reads as WARN, not PASS;
  `scan_diff.py` self-test fixtures assembled at runtime (keyword+value split) with a
  self-scan structural guard. Deliberately PATH-based, never value-allowlisting —
  `case-05-secret-committed` still proves a fake credential in product source stays
  CRITICAL. Regression: `goal-gates.sh --self-test` cases 11/12 (git-backed:
  bookkeeping quoting a credential scans CLEAN untracked AND tracked; the same
  credential in product source stays CRITICAL). Residual accepted blind spot: a secret
  pasted ONLY into a handoff/report/spec is no longer scanned per-iteration — SEC-1's
  full-tree pass on GOAL_ACHIEVED is the designated cover; until then that text is
  agent-generated prose, the same class as the traces that caused the recursion.
  Anti-pattern #22.)*

### SEC-6 · Near-zero permission prompts without gutting the gates (interactive goal mode)
- **Priority:** P0 · **Effort:** M · **Risk:** MED (accepted, bounded) · **Status:** DONE
  *(implemented 2026-07-14: interactive goal mode was interrupted constantly by
  two distinct approval sources. (a) Claude Code's permission evaluator — any
  Bash segment not prefix-matching `permissions.allow` prompts; gaps were shell
  control flow (`for`/`do`/`done`/`if`…), ~50 common dev binaries (make,
  timeout, sqlite3, rg, tar, du, df…), path-qualified venv commands
  (`apps/backend/.venv/bin/python -m pytest` — the canonical project-template
  test command; `.venv/bin/*` does not match it), and scoped `rm -rf` of
  common dev artifacts (.venv, .mypy_cache, htmlcov, playwright-report…).
  (b) the install gate hard-blocking (exit 1 → "APPROVAL REQUIRED", confirmed
  in transcripts) every unpinned or non-allowlisted `pip/npm install` — the
  python allowlist was `["anthropic"]`, so agents building products halted on
  nearly every new dependency (tapeology needed yfinance/alpaca-py/mcp
  hand-added). Fix: (1) `policy/permissions.yaml` +~100 allow entries in five
  commented blocks (control flow, curated binaries, venv/pytest variants,
  scoped rm -rf artifacts, ss/netstat/wait/jobs; duplicate `pstree` removed)
  — re-rendered to 223 allow entries; deny hardened with the missing system
  dirs (/mnt /media /dev /bin /sbin) plus EMBEDDED-pattern guards
  (`Bash(* rm -rf /etc*)`, `* sudo rm*`, `*~/.ssh/id_*`, …) because
  keyword-prefixed segments (`do rm -rf /etc`) dodge prefix denies — deny
  beats allow and leading-glob matches anywhere; NEVER a bare `* rm -rf /*`
  (the /tmp-cleanup-swallowing bug). `guard-dangerous-commands.sh` mirrors
  both (patterns + a keyword-wrapped rm regex keeping the `(?!tmp)`
  carve-out; run-evals 2d gained the loop-wrapped block/allow smoke pair).
  (2) install gate: new policy knobs `on_unpinned_decision` /
  `on_unknown_decision` (install-gate.py `rule_decision`/`stricter` helpers,
  five `require_approval` sites now policy-tunable; absent knobs ⇒
  `require_approval`, so sibling copies that re-sync code but keep their JSON
  see zero change; invalid values fail closed; denylist always wins). Policy
  set to `warn` (proceed + banner + JSONL log) with ~30 python + ~35 npm
  common packages seeded into the allowlists; direct-URL/tarball/custom-index
  installs, curl|bash, denylist hits, unknown requirements files, and
  unpinned git clones ALL still hard-block. What is genuinely given up: human
  pre-approval of first-use registry names (typosquat exposure) — compensated
  by the seeded lists, the audit trail, and (3) the evidence loop:
  `scripts/automation/suggest-allowlist.sh` mines
  `reports/security/install-decisions.jsonl` (+ `--transcripts` banner scan)
  into ready-to-paste allowlist additions; wired into run-evals as a
  self-test. (4) User-global `~/.claude/settings.json` (machine-wide, covers
  tapeology/trendora immediately without a framework re-sync): generic allow
  additions + embedded-deny backstops + `env.TMPDIR` (REL-13) +
  `additionalDirectories` for the tmp root; backup kept at
  `settings.json.bak-sec6-rel13`. test-install-gate.sh rewritten: 16
  assertions incl. fixture-policy proofs (defaults stay require_approval;
  denylist beats warn; invalid knob fails closed). Sibling propagation
  deliberately deferred — their engines keep the strict gate until re-synced.
  CORRECTION (2026-07-15, SEC-7 forensics): the "confirmed in transcripts"
  install-gate hard-blocks were a misattribution — on the Claude backend the
  hook had been inert end-to-end (settings passed the nonexistent
  `$CLAUDE_TOOL_INPUT_COMMAND`, so `$1` was always empty; and its exit 1 is a
  NON-blocking PreToolUse error anyway). Zero live fires exist in any
  transcript; the matched strings were source-quoting. The live interrupters
  were the permission evaluator plus the user-level curl guard. SEC-6's policy
  work stands (it defines what the gate enforces); SEC-7 made the enforcement
  real.)*

### SEC-7 · Hook protocol fix: the Bash guards never received commands on Claude (+ curl-guard v2)
- **Priority:** P0 · **Effort:** S · **Risk:** LOW · **Status:** DONE
  *(implemented 2026-07-15, triggered by the user seeing a curl-guard "ask"
  interrupt mid-session. Forensics: (a) the ONLY "piped into a shell" fire in
  the corpus was a QUOTED fixture string inside a SEC-6 smoke-test for-loop —
  the user-level `~/.claude/hooks/guard-curl-exfil.sh` grepped the whole
  command line, needed no actual curl for its pipe branch (`cat x | bash`
  matched) and asked on any `-d`-ish flag with an unrecognized target
  (`docker run -d`, `curl -d "$API_URL"` → 9 asks in the tapeology/trendora
  goal sessions on 2026-07-14 alone); the settings `if: Bash(curl *)` gate
  fails open on unparseable commands (documented), so curl-less commands
  reached it too. (b) Docs-verified: hook input is JSON on stdin
  (`.tool_input.command`); `$CLAUDE_TOOL_INPUT_COMMAND` does not exist; exit 1
  is NON-blocking; the decision channel is stdout
  `hookSpecificOutput.permissionDecision` (deny = blocked, reason shown to the
  MODEL — no user prompt) — so BOTH repo Bash guards were inert on Claude
  (empty `$1` → instant exit 0; zero live fires in any transcript). Fixes:
  (1) user-level curl-guard v2 (machine-local, backup at
  `guard-curl-exfil.sh.bak-sec7`): quote-strips before matching, self-gates on
  a command-position curl invocation (anchored ERE with VAR=/sudo/env/timeout/
  do|then|else wrappers), scopes pipe/data patterns to the curl pipeline
  segment, passes variable-URL and RFC1918/localhost upload targets, and
  DENIES (never asks — user decision) real pipe-to-shell + literal-external
  uploads with an agent-readable reason; deliberate override
  `CURL_GUARD_ALLOW=1` prefix (logged); 12-case stdin matrix green incl. the
  verbatim offending fixture command. (2) Repo hooks two-mode protocol: argv
  (`$1`, byte-identical legacy contract for run-evals/Codex: banners + exit 1)
  vs stdin (Claude: block/require_approval → deny JSON exit 0 with remediation
  as the reason; warn → stderr banner, stdout reserved for JSON; fail-open on
  parse failure — secondary layer, availability beats strictness). Renderer
  templates drop the fake env var (`… install-security-gate.sh" || true`,
  guard keeps `2>/dev/null || true`; stdout JSON survives `|| true`);
  PostToolUse hooks share the argv bug via `$CLAUDE_TOOL_INPUT_FILE_PATH` —
  advisory-only, follow-up FIXME in `_hooks_block_for_claude`. (3) Same
  quoted-substring hardening in the gate itself: `install-gate.py` dispatcher
  tests curl|shell against a quote-stripped view (a quoted "curl … | bash"
  mention — fixture, echo, commit message — passes; live-proven when the
  freshly-rendered hook denied THIS session's own quoted-fixture verification
  command), and the hook fast-path mirrors it. Regression: run-evals 105→111
  (6 stdin-protocol smokes: guard deny/silent, gate deny/warn-no-JSON/silent/
  quoted-mention-pass); test-install-gate.sh 16→17 (quoted-mention case).
  Enforcement is now real on Claude: first-ever live deny observed in-session.)*

---

## 12. P1 — Product quality gates (the chain's OUTPUT, not the chain)

### QUAL-1 · Opt-in a11y + performance checks in browser QA
- **Priority:** P1 · **Effort:** L (2 slices) · **Risk:** LOW · **Status:** TODO
- **Problem:** the chain verifies journeys work, not that the product is accessible or
  fast — quality dimensions a non-technical owner can't spot in screenshots.
- **Current state:** deterministic browser lane = `lib/demo_runner.py` (Playwright);
  results merge via `merge_ui_test_results.py`; browser-qa results table feeds the
  evaluator. No a11y/perf tooling anywhere.
- **Change spec:**
  1. **Slice (a) — a11y.** Knob `CHAIN_PRODUCT_QUALITY_GATES=off|a11y|perf|all`
     (default `off`). In demo_runner verify/record modes when enabled: inject axe-core
     if resolvable from the PROJECT's node_modules (`require.resolve('axe-core')`
     equivalent); graceful skip + note when absent. Violations (serious/critical only)
     → advisory WARN rows appended to the results artifact — never FAIL.
  2. **Slice (b) — perf.** Simple budgets: page-load / first-contentful-paint ms via
     Playwright metrics vs thresholds read from `.claude/project-template.md` (add an
     optional "Performance budgets" template section). WARN rows only. Escalation
     WARN→FAIL documented as a future human decision, not built.
- **DoD:** knob off = byte-identical behavior; on + axe present = WARN rows appear;
  demo_runner self-test extended; evals green.
- **Verify:** `python3 scripts/automation/lib/demo_runner.py self-test &&
  ./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/lib/demo_runner.py`,
  `scripts/automation/lib/merge_ui_test_results.py` (if status vocab grows — grep
  readers first, G3), `templates/` + `.claude/project-template.md` section, docs.
- **Rollback:** knob.

---

## 13. P1 — Reporting & visualization

### REP-1 · Telemetry HTML dashboard
- **Priority:** P1 · **Effort:** M · **Risk:** LOW · **Status:** TODO
- **Problem:** timing/token/cost analysis is CLI-text only (`analyze_telemetry.py`);
  the human-facing HTML story has no operational view.
- **Current state:** all data already in `runs/goal-session-<sid>/telemetry.jsonl`;
  aggregations exist (`build_wall_report` `analyze_telemetry.py:273`, cost/by-model
  rollups); house HTML style = self-contained, inline CSS/SVG, base64 images, no
  network refs (`lib/render_iteration_summary.py`).
- **Change spec:** new `scripts/automation/lib/render_telemetry.py <telemetry.jsonl>` →
  `reports/goal-session-<sid>-telemetry.html`: per-iteration stacked timing bars
  (per-agent minutes, overlap-saved annotation), per-agent token/cost table, session
  trend lines (wall, cost, journeys passing per iteration) as inline SVG; `self-test`
  rendering a fixture JSONL. Optional non-blocking call from the showcase tail +
  `render-summary.sh` flag. Reuse the existing CSS constant approach.
- **DoD:** fixture renders; absent/partial telemetry (interactive mode: no token
  events) degrades gracefully to timing-only; evals green.
- **Verify:** `python3 scripts/automation/lib/render_telemetry.py --self-test &&
  ./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/lib/render_telemetry.py` (new),
  `scripts/automation/render-summary.sh`, showcase tail call (optional), docs.
- **Rollback:** standalone renderer; remove call sites.

### REP-2 · Session-index cost/time on iteration cards
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** TODO
- **Problem:** the session index shows journey progress but not "this iteration took
  90 min and $X" — the numbers an owner actually asks about.
- **Current state:** session index built by `render_iteration_summary.py session-index`
  (cards per iteration, journey×iteration matrix); wall/cost derivable from
  telemetry.jsonl.
- **Change spec:** cards gain wall minutes + est. cost (when token telemetry exists) +
  a tiny journeys-passing sparkline across iterations; read telemetry.jsonl directly
  (renderer already reads sibling artifacts); absent telemetry = omit silently.
- **DoD:** renderer self-test covers with/without telemetry; evals green.
- **Verify:** `python3 scripts/automation/lib/render_iteration_summary.py self-test &&
  ./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/lib/render_iteration_summary.py`.
- **Rollback:** revert renderer edit.

### REP-3 · Completion notification
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** TODO
- **Problem:** multi-hour sessions end (achieved, stalled, halted) with no signal; the
  human discovers it by polling.
- **Current state:** halt paths print banners to a log nobody watches live.
- **Change spec:** `notify_session_end()` in `lib/common.sh`: if `CHAIN_NOTIFY_WEBHOOK`
  set → POST a small JSON (sid, verdict, iterations, report link path); elif
  `notify-send` exists → desktop notification; else no-op. Called from the terminal
  halt paths (same sites as EVO-2's collector). Default: unset = no-op. Never fails the
  halt (`|| true`).
- **DoD:** stub webhook receives payload in a test; absent config = silent; evals green.
- **Verify:** targeted test + `./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/lib/common.sh`, `scripts/automation/run-goal.sh`,
  docs (env var table).
- **Rollback:** unset env (no-op by default).

### REP-4 · Iteration summaries must name the concrete change
- **Priority:** P0 (the user's top reporting complaint) · **Effort:** S ·
  **Risk:** LOW · **Status:** IN-PROGRESS — implemented 2026-07-28 (e619138,
  part of the SPEED-9..19 package); G8 certification pending.
- **Problem:** desk-session summaries never named one source file/screen; the
  "In plain words" opener was recycled filler ("Behind-the-scenes work —
  nothing visibly new this round"); "What you can do now" was copied verbatim
  from the prior summary BY INSTRUCTION.
- **Change spec (landed):** the opener must name the screen/page and what the
  user now sees (the generic sentence is allowed ONLY on zero-product-file
  iterations, and must still name the concrete area); the FIRST "What was done"
  bullet is fixed-format — `Product changes: <files/routes>` or exactly
  `No product change this iteration.`; "What you can do now" is re-derived from
  journey-history every iteration; plain-language skill hard rule 7 ("concrete
  beats generic"). H2 set unchanged (schema-enforced).
- **Verify:** run-evals (summary schema self-tests) · eyeball the next real
  session's summary: named screen in the opener, product-change first bullet.
- **Files:** `agents/iteration-summarizer/*`, `templates/iteration-summary.md`,
  `skills/plain-language.md`, mirrors.
- **Rollback:** revert three files + version.
- **Stop-and-ask:** none.

### REP-5 · Attribute the two-key CONFIRM_ACHIEVED dispatch
- **Priority:** P2 · **Effort:** S · **Risk:** LOW · **Status:** IN-PROGRESS —
  implemented 2026-07-29 (iteration-shape package); G8 certification pending.
- **Problem:** the two-key confirm dispatch (`lib/goal-gates.sh`) ran outside
  the per-agent telemetry — ~5 min per achieving iteration rendered as
  unattributed glue (desk: the evaluator bucket carried an invisible second
  dispatch).
- **Change spec (landed):** the dispatch is wrapped in guarded (`declare -F`)
  `record_agent_invocation_start/end` under the name `goal-evaluator-confirm`;
  the dispatch env keeps `CHAIN_CURRENT_AGENT=goal-evaluator` (pump permission
  resolution knows the evaluator's grants, not the telemetry label). Lands in
  the open iteration bucket — no analyzer change. Self-test stubs assert both
  events; `unset -f` at cleanup.
- **Verify:** `bash scripts/automation/lib/goal-gates.sh --self-test`.
- **Rollback:** revert (measurement only; no behavior change).
- **Stop-and-ask:** none.

---

## 14. P1 — Documentation & guides

### DOC-1 — DONE 2026-07-08, archived

### DOC-2 — DONE 2026-07-08, archived

### DOC-3 · `docs/TROUBLESHOOTING.md`
- **Priority:** P1 · **Effort:** M · **Risk:** LOW · **Status:** TODO
- **Problem:** troubleshooting knowledge is scattered (interactive doc §C, cli-providers
  §Troubleshooting, README known-limitations, exit-code lore in demo_runner) — a stuck
  adopter can't find the one table they need.
- **Current state:** no standalone guide (verified).
- **Change spec:** one symptom → check → fix table covering: every pause/halt status
  (`AWAITING_PUMP`, `AWAITING_GITHUB_AUTH`, `AWAITING_BLUEPRINT_APPROVAL`,
  `AWAITING_INTENT_REVIEW` when NEED-7 lands, `REGRESSION_HALT`, `STALLED`,
  `BUDGET_EXHAUSTED`, `ABORT_MALFORMED`); demo_runner exit codes (0/2/3/4/5/6); quota
  pause vs hard fail; checkpoint resume behavior; mirror-drift symptoms; pump restart
  rule; where every log lives. Cross-link instead of duplicating where a good section
  already exists (link the interactive doc's §C rather than copying it).
- **DoD:** every status/exit code above has a row; linked from README and quickstart.
- **Verify:** `grep -c "AWAITING" docs/TROUBLESHOOTING.md` (≥4) + link greps.
- **Files:** `docs/TROUBLESHOOTING.md` (new), README + quickstart links.
- **Rollback:** docs-only.

### DOC-4 · First-run onboarding walkthrough + FAQ
- **Priority:** P1 · **Effort:** M · **Risk:** LOW · **Status:** TODO
- **Problem:** no end-to-end "clean clone → first passing iteration" narrative with
  expected outputs; newcomers can't tell healthy from broken.
- **Current state:** README Quick Start (5 steps) + quickstart's 4-step setup exist but
  neither shows what SUCCESS looks like at each step.
- **Change spec:** `docs/FIRST-RUN.md`: prerequisites (with doctor once REL-2 lands) →
  `/goal-init` (NEED-1) or manual goal.md → first `run-goal.sh` → what appears on disk
  after iteration 0/1 (expected files, sample banner lines) → where to look when it
  differs (link DOC-3). Append a short FAQ (10-ish real questions: costs, models
  needed, can I stop mid-run, how do I change the goal mid-session, etc.).
- **DoD:** a newcomer can follow it without reading any other doc first; linked from
  README top.
- **Verify:** dry-read + link grep.
- **Files:** `docs/FIRST-RUN.md` (new), README link.
- **Rollback:** docs-only.

### DOC-5 — absorbed into PLAIN-1 (§19) 2026-07-26, archived

### DOC-6 · Architecture docs refresh
- **Priority:** P1 · **Effort:** M · **Risk:** LOW · **Status:** TODO
- **Problem:** `.claude/architecture/*.md` self-declare (via README's multi-CLI TODO)
  as describing the pre-migration Claude-only layout.
- **Current state:** stale references incl. planned-but-absent files
  (`hooks/lib/normalize-input.sh` / `normalize-output.sh`).
- **Change spec:** sweep each architecture doc against the current tree: fix the
  neutral-source/adapters story, remove references to files that don't exist, update
  agent/skill catalogs (19/14 or de-numbered), note goal-mode additions landed since.
  No restructuring — corrections only.
- **DoD:** no reference to a nonexistent path (`grep -o` audit script in the change);
  catalogs match the tree.
- **Verify:** a one-off path-existence check over the docs + evals green.
- **Files:** `.claude/architecture/*.md`.
- **Rollback:** docs-only.

### DOC-7 · Adopter bootstrap script
- **Priority:** P1 · **Effort:** M · **Risk:** LOW · **Status:** TODO
- **Problem:** adopting the framework into a product repo is a manual multi-file ritual
  (copy dirs, fill project-template, author goal.md, opt into hooks).
- **Current state:** subrepo guidance is prose (README "Subrepo Usage",
  `.claude/architecture/adoption-guide.md`).
- **Change spec:** `scripts/automation/bootstrap-project.sh <target-repo>`: copies the
  framework dirs (per the subrepo layout), instantiates `.claude/project-template.md`
  with placeholder markers, seeds `docs/goal.md` from the template with a banner
  "run /goal-init to fill this", prints the opt-in menu (hooks, proposer, knobs) and
  next steps. Idempotent (refuses to clobber non-placeholder files).
- **DoD:** bootstrap into an empty scratch repo passes `validate_goal_file` presence
  checks (structure), doctor (REL-2) if present, and prints next steps; running it
  twice is safe.
- **Verify:** scratch-repo run + rerun; `bash -n` + evals.
- **Files:** `scripts/automation/bootstrap-project.sh` (new), README command table,
  adoption guide link.
- **Rollback:** standalone script.
- **Depends on:** pairs with NEED-1 (not blocking).

---

## 15. P2 — EXPERIMENTAL (human sign-off REQUIRED before attempting)

Each of these needs: explicit user approval, a written design doc first (a short spec in
§16 staging → promoted), and a defined tripwire. A weaker model must NOT start these from
this file alone.

### EXP-1 · Parallel developers in git worktrees
- **Priority:** P2 · **Effort:** L · **Risk:** HIGH · **Status:** BLOCKED (human sign-off + design doc first)
- **Idea:** when an iteration's spec cleanly splits into disjoint file sets, run 2
  developer agents in separate worktrees and merge sequentially. Big win (dev ≈ 41m),
  big risk (merge conflicts, contract drift between halves, doubled cost on FAIL).
- **Preconditions:** SPEED-2/3 shipped and stable; EVO-3 benchmark exists; a real spec
  corpus showing splittable iterations are common enough to matter.
- **Tripwire:** any merge conflict or cross-half review FAIL → disable for the session.

### EXP-2 · OS-sandboxed chain runs (devcontainer)
- **Priority:** P2 · **Effort:** L · **Risk:** MED · **Status:** BLOCKED (human sign-off + design doc first)
- **Idea:** the Claude path has no OS sandbox (permission lists + hooks only). Package
  the whole chain in a devcontainer/docker profile so agent Bash runs inside a
  container with the repo mounted.
- **Preconditions:** inventory of everything the chain shells out to (playwright
  browsers, Chrome MCP, gh, node/python toolchains) — the container is only worth it
  if browser QA works inside it.
- **Tripwire:** browser-qa pass-rate drop vs host runs.

### EXP-3 · Telemetry-driven self-evolution loop
- **Priority:** P2 · **Effort:** L · **Risk:** HIGH · **Status:** BLOCKED (human sign-off + design doc first; also needs EVO-2 proven + SAFE-1/2)
- **Idea:** close the loop EVO-2 opens: sessions propose framework changes, a
  designated maintainer session implements from staging automatically. Architecture
  docs already mark this deferred (`feedback/` placeholder).
- **Preconditions:** EVO-2 retros proven useful for ≥3 sessions; SAFE-1/2 landed; human
  still approves every promotion (this experiment automates IMPLEMENTATION, never
  promotion).

### EXP-4 · Interactive full-fork browser-qa
- **Priority:** P2 · **Effort:** L · **Risk:** MED · **Status:** BLOCKED (cancellation handshake undesigned; human sign-off + design doc first)
- **Idea:** extend SPEED-3's `full` mode to the interactive backend.
- **Blocker (verified):** mid-session dispatch cancellation is undefined — killing the
  engine-side waiter strands the pump's subagent; stale `req.*`/`.res` files are only
  cleaned at engine start (`run-goal.sh:819`). Needs a cancellation handshake in the
  pump protocol (pairs with REL-3's PID work) + pump-side abort semantics.

### EXP-5 · Multi-CLI completion
- **Priority:** P2 · **Effort:** L · **Risk:** MED · **Status:** BLOCKED (no active Codex use-case; human sign-off first)
- **Idea:** finish the Codex path: `.codex/` tree refresh (`sync-cli-assets.py --cli
  codex`), per-agent `cli:` override routing (README TODO says "not wired up"),
  interactive Codex backend.
- **Preconditions:** an actual Codex use-case from the user; otherwise this stays
  parked (letter: this deployment is claude-only).

---

## 16. Candidate staging area

New ideas land here (from EVO-2 retros, sessions, or the user). Human promotes to a
numbered section per EVO-1. Format: one `###` block per candidate, item format optional
but appreciated.

### CAND-TIER · Conditional developer tiering (staged — do not start)
- **Proposed:** P2 · Effort M · Risk MED-HIGH · **Status:** staged; BLOCKED on EVO-3 +
  REL-1 + explicit user spend-class approval (same class as TOKEN-2).
- **Source:** Superpowers 6 "conditional implementer tiering" (≈$0.50-1.00/run saved by
  routing simple work to Haiku). NOTE: our developer is already `standard`/sonnet-5
  (`agents/developer/agent.yaml:5`), not strong — the addressable saving is smaller
  than theirs. Anchors verified 2026-07-07 @ `eb5c8f9`.
- **Sketch:** decomposer adds `Complexity: trivial|normal` to Goal Mode Metadata
  (`agents/goal-decomposer/body.md:43-50`) with STRICT trivial criteria (single
  file/config/copy change, no new endpoint, no data-contract addition, no new
  journey — anything else = normal). The lean engine greps it like `_spec_journeys()`
  (`goal-iter-lean.sh:299`); `trivial` + depth=lean + `CHAIN_DEV_TIER_EXPERIMENT=true`
  (default off) → wrap ONLY the first developer pass with
  `CHAIN_MODEL_OVERRIDE=$(python3 scripts/automation/lib/agent_permissions.py
  tier-model light)` (injection mechanism: `quota-retry.sh:551-576`), cleared
  immediately after. Fix-mode escalation unchanged and always wins
  (`goal-iter-lean.sh:219/:226`, `common.sh:726-743`). Tripwire: reuse REL-8's
  cost+quality machinery; additionally, any trivial-tagged iteration failing attempt-1
  review disables the knob for the rest of the session.
- **Why staged:** needs benchmark evidence (EVO-3) + judgment fixtures (REL-1) to prove
  quality holds; spend-class per G1; and the win may be small — re-evaluate after
  TOKEN-7 and REL-8 land.

### CAND-CAPS · Output-cap enforcement for report contracts (staged — thin)
- **Proposed:** P2 · Effort S · Risk LOW.
- **Source:** Superpowers 6 "terse reviewer contract" (−54% reviewer verbosity, verdict
  quality held). Our equivalents ALREADY exist in prose: reviewer output budgets
  (`agents/reviewer/body.md:32-40`: PASS ≤200 tok / NOTES ≤400 / FAIL ≤800), summarizer
  per-section caps (`agents/iteration-summarizer/body.md:77/:81/:139/:149/:216`),
  narrator strict-JSON recipe (`agents/demo-narrator/body.md:45-66`). Missing is only
  ENFORCEMENT/measurement.
- **Sketch:** (a) static: SAFE-2's contract linter additionally asserts each
  reviewer-class body states its output-budget table; (b) runtime: warn-only length
  check in `lib/artifact_schemas.py` for review reports exceeding their verdict-class
  budget; (c) measurement: existing per-agent output tokens
  (`analyze_telemetry.py:96/:212`) — no new instrumentation.
- **Why staged:** caps appear respected today; this is hygiene, not a win. Best
  absorbed into SAFE-2's session rather than run standalone.

### CAND-SVC-BOOT-GENERAL · engine boot resolution never reads the project-template (staged — do not start)
- *(Renamed from CAND-SVC-BOOT: variant (a) — the benchmark-local fix — was promoted to
  REL-10 on 2026-07-11 by explicit user decision; only the general variant (b) remains
  staged here. CAND-HEADLESS-PERMS from the same baseline was fully promoted to REL-11
  the same day.)*
- **Proposed:** P1 · Effort M (general boot-path fallback) · Risk MED (touches the
  engine's service boot).
- **Source:** EVO-3 first real baseline (bench-20260710-2117 @ c48f25047126) — README
  Known Limitation 1 ("QA expects `CHAIN_START_BACKEND_CMD` or `scripts/start-backend.sh`",
  `README.md:464`) made concrete. Staged 2026-07-11.
- **Problem:** the deterministic service-boot lane never consults the project's documented
  start command. Resolution order today (`goal-iter-lean.sh:335-342`; `qa-phase.sh:73-81`
  same pattern): `CHAIN_START_BACKEND_CMD` env → else `bash scripts/start-backend.sh` if
  the file exists → else nothing. Any adopter whose project-template documents a start
  command that differs from the generic framework template gets the wrong boot unless
  they hand-set the env vars (REL-10 fixed exactly this for the benchmark fixture, via
  the env route; every other deployment still relies on Known Limitation 1).
- **Sketch (root-cause hypothesis, not a design):** a middle resolution tier that
  reads the project-template's `SERVICE START COMMANDS` section before falling back to
  the generic script — needs a parse contract + eval fixture (G3) and care around
  `ensure_services_running` (`lib/common.sh:770`, `_start_service_with_retries` `:582`).
- **Why staged / verify idea:** engine boot-path changes are MED risk — human promotion
  required (EVO-1). Verify: a consumer-repo-shaped test fixture whose project-template
  documents a non-default start command boots it without any env override; the REL-10
  benchmark keeps passing with `fixture.env` deleted (the middle tier would subsume it).

### CAND-GLUE-TIME · Instrument goal-loop "glue" wall time (staged — do not start)
- *(First retro-loop harvest: drafted by the EVO-2 retro-analyst as RETRO-1 at the
  bench-20260712-1536 terminal halt; staged verbatim 2026-07-12, user-authorized per
  EVO-2's contract — promotion stays human, EVO-1.)*
- **Proposed (by the retro):** P2 · Effort M · Risk LOW.
- **Source:** retro report preserved at
  `benchmarks/results/20260712-171324-5e87813077ae.retro.md` (sibling of the run's
  results JSON); kept scratch `~/.cache/chain-bench-tmp/bench-bench-20260712-1536.ozxtwM`
  (traces + telemetry).
- **Problem (retro's words):** Iteration 1 showed 57.0m of unattributed wall time out
  of 74.3m total (77% of iteration), labeled as "glue" in the wall-time breakdown. No
  visibility into what synchronization, external waits, or queue delays this represents.
- **Evidence (retro's citation):** Agent economics — "goal-bench-20260712-1536-iter-1
  depth=full  verdict=CONTINUE  wall=74.3m ... unattributed (glue)       57.0m"
- **Sketch (retro's):** Add instrumentation to the goal-loop pump
  (scripts/automation/run-goal.sh and lib/goal_pump.sh) to emit telemetry events for
  queue depth, wait-for-agent latency, and post-verdict pause durations. Surface these
  in analyze_telemetry.py --wall output as separate line items instead of lumping them
  as "unattributed."
- **Verify idea (retro's):** Re-run a goal-mode session with the same budget and
  confirm that "glue" time is now broken into named, measurable components that sum to
  the original 57m.
- **Triage note (staging session, 2026-07-12):** the sketch's `lib/goal_pump.sh` does
  not exist (the digest-only retro-analyst guessed the path) and the benchmark run was
  headless — no interactive pump — so promotion needs a fresh look at where the 57m
  actually lives (dispatch startup, service boots, retries, sleeps) before adopting the
  sketch's event list.

### CAND-QA-ISOLATION · Isolate concurrent QA-lane state mutations (staged — do not start)
- *(First retro-loop harvest: drafted by the EVO-2 retro-analyst as RETRO-2 at the
  bench-20260712-1536 terminal halt; staged verbatim 2026-07-12, user-authorized per
  EVO-2's contract — promotion stays human, EVO-1.)*
- **Proposed (by the retro):** P1 · Effort M · Risk MED.
- **Source:** retro report preserved at
  `benchmarks/results/20260712-171324-5e87813077ae.retro.md`; kept scratch
  `~/.cache/chain-bench-tmp/bench-bench-20260712-1536.ozxtwM` (the cited lessons.md
  lives under its `scratch/runs/goal-session-bench-20260712-1536/state/`).
- **Problem (retro's words):** Concurrent qa and browser-qa-agent lanes drive Chrome
  against shared stateful server resources (Flask instance + todos.json). When both
  lanes run in parallel on mutation-heavy journeys, one lane's state changes pollute
  the other's evidence (screenshots show false negatives). The lessons tail documents
  a case where browser evidence contradicted itself due to concurrent state mutation
  mid-screenshot.
- **Evidence (retro's citation):** Lessons tail — "Two lanes of the same pipeline
  (`qa` and `browser-qa-agent`) drove Chrome against one Flask instance and one
  `todos.json` concurrently, and the resulting screenshots make a CORRECT app look
  BROKEN... because the other agent toggled state mid-run."
- **Sketch (retro's):** For goal-mode sessions on stateful apps (detected: journeys
  with mutations, or DATA_FILE persisted across runs), either (a) serialize the QA and
  browser-qa-agent lanes (add a depends-on gate), or (b) give each lane a private
  isolated copy of DATA_FILE (e.g., `todos-qa-lane-<uuid>.json`,
  `todos-browser-qa-lane-<uuid>.json`) and reconcile state deterministically before
  re-drive.
- **Verify idea (retro's):** Re-run a goal-mode session on a stateful app with
  mutation journeys; confirm that no screenshot contradicts its own results row, and
  that two lanes do not produce conflicting evidence for the same journey step.
- **Triage note (staging session, 2026-07-12):** the premise is structurally real —
  `run-phase.sh` runs Branch A (ui-impact → ui-test-design → browser-qa → demo)
  concurrently with Branch-QA (`qa-phase.sh`) under `CHAIN_SHARED_SERVICES=true` — but
  option (a) serialization pushes against the SPEED-2/SPEED-3 parallelization chain,
  so triage should weigh (a) vs (b) against §9 before promoting.

### CAND-AUDIT-DISPATCH · Full-depth audit step can be silently skipped (staged — do not start)
- *(EVO-5 first real harvest, 2026-07-12, over ~/Git/tapeology + ~/Git/trendora —
  cross-repo recurring symptom drafted from the digest; promotion human, EVO-1.)*
- **Proposed:** P1 · Effort M · Risk MED (engine orchestration).
- **Symptom (harvest evidence, cross-repo):** trendora
  `goal-session-i_can_see_the_wealthy_future_forever_with_my_loved_ones` iter-55
  lesson: "The audit step has silently NOT run for three consecutive iterations
  (53/54/55) — status.json keeps stopping at current_step: qa_complete /
  next_action: audit with no audit handoff written… This is an engine ORCHESTRATION
  gap (the auditor agent is never dispatched between QA and coherence/evaluator)."
  tapeology `goal-session-i_will_be_super_rich` lesson: "no `-audit.md` handoff was
  produced (status stopped at qa_complete) — full-depth iterations can finish
  without the audit step."
- **Sketch:** determine whether the goal-mode full-depth path at framework HEAD can
  still complete an iteration without dispatching the auditor (phase mode's
  `run-phase.sh:889-941` Step 9 is fail-loud with retries; both adopters ran
  vendored snapshots); if it can, make the dispatch mandatory-or-loud — at minimum
  give a missing audit handoff the REL-11 missing-evidence treatment
  (`warn_missing_evidence` banner + `missing_evidence` telemetry event).
- **Triage note (staging session, 2026-07-12):** highest-signal harvest finding —
  the same silent-void class REL-11 just closed for qa/browser-qa/retro-analyst,
  observed for the auditor in BOTH adopters; trendora's evaluator had to perform
  the audit's skeptical checks itself before declaring GOAL_ACHIEVED.

### CAND-BQA-PREFLIGHT · Browser-qa dispatch lacks a services/fixture preflight gate (staged — do not start)
- *(Absorbed into REL-14 on 2026-07-17 — the user-approved throughput package
  promoted the preflight as REL-14's component (1); the harvest evidence + triage
  note below remain as the historical record. Do not implement from this block.)*
- *(EVO-5 first real harvest, 2026-07-12 — cross-repo recurring symptom drafted
  from the digest; promotion human, EVO-1.)*
- **Proposed:** P1 · Effort M · Risk MED.
- **Symptom (harvest evidence, cross-repo, chronic):** trendora
  `goal-session-i_can_see_the_wealthy_future` iter-12: "the browser-qa (probes
  `/health` not `/api/health`; tears services down pre-test) … gaps were flagged
  every iter 3–12 via spec text and never fixed — durable fixes belong in
  `scripts/automation/*.sh`, not spec prose." trendora
  `goal-session-i_can_see_the_wealthy_future_forever` iter-27 (STALLED): "The
  browser-QA runner ran against the LIVE host with the seed env unset for FIVE
  straight iterations (23/24/25/26/27) despite an increasingly verbatim recipe."
  tapeology `goal-session-structure_ui` iter-4: "curl-confirming `:3301`/`:8301`
  before QA dispatch turned iter-3's SKIPPED 0/26 into iter-4's 18/18 populated
  PASS — the precondition is now a proven, not speculative, gate."
- **Sketch:** a deterministic services-up preflight (and, when the spec names one,
  a fixture/env-state check) in the browser-qa dispatch path — in
  `scripts/automation`, not spec prose — that refuses or loudly SKIPs the dispatch
  when the preflight fails, instead of burning a full browser pass against a dead
  or wrong-state host.
- **Triage note (staging session, 2026-07-12):** tapeology iter-4 already proved
  the gate live; orthogonal to CAND-QA-ISOLATION (service readiness vs concurrent
  state mutation) — check overlap with `ensure_services_running`
  (`lib/common.sh:770`) before promoting: the engine may have partial cover the
  vendored snapshots lacked.

### CAND-FULL-BQA-OVERLAP · Port review ∥ browser-qa overlap to the full pipeline (staged — do not start)
- *(Staged 2026-07-17 from the SPEED-6 reconciliation: SPEED-2/3's fork exists only
  in `goal-iter-lean.sh`; run-phase.sh full depth reviews sequentially inside Step 3
  (`run-phase.sh:674-726`) and only parallelizes the post-dev Branch-UI ∥ Branch-QA
  fanout (`_run_post_dev_fanout` `:254`, call `:745`).)*
- **Proposed:** P2 · Effort M · Risk MED.
- **Sketch:** port the SPEED-2/3 fork machinery so run-phase.sh forks browser-qa
  (or the whole Branch-A chain) after the first dev attempt to overlap the review
  rounds; headless-only, knob'd, kill-then-invalidate on review FAIL (SPEED-3's
  join/reap semantics, including the rc-70 pause translation). Companion
  measurement: the fanout-QA double-dispatch cost (fanout Branch-QA + the
  sequential Step 7 retry when its verdict fails there, `run-phase.sh:745` ff.).
- **Why staged:** re-check demand after SPEED-4 — the sharpened rubric makes full
  iterations the exception, shrinking the addressable saving; and the same
  real-session telemetry gate that parked SPEED-3's flip applies (the benchmark
  fixture failed to price the overlap three times).

### CAND-DEV-CONTEXT · Developer dispatch context slims as sessions grow (PROMOTED 2026-07-29)
- *(Sketch (a) — sliced goal view for the executor dispatches — was PROMOTED to
  **TOKEN-10** and implemented 2026-07-29 with the desk evidence attached.
  Sketches (b) scoped file digest and (c) read-vs-build time split remain
  staged here, unchanged.)*
- *(Staged 2026-07-17 from tapeology `fast_wall` forensics: developer run time grew
  monotonically 31 → 77 min across 6 iterations — the #1 wall-clock sink in every
  single iteration, 6.5h total.)*
- **Proposed:** P1 · Effort M · Risk MED.
- **Current state:** the lean developer dispatch feeds the FULL `docs/goal.md`
  (`goal-iter-lean.sh:757-776`) while decomposer + evaluator already receive the
  token-lean goal-slice (`run-goal.sh:1691-1692` / `:1978`); no per-dispatch
  file-scope digest exists (contrast TOKEN-7's pre-baked reviewer packet).
- **Sketch:** (a) cheapest first — point the developer dispatch at
  `$GOAL_SLICE_PATH` (targets verbatim, stable journeys digested); (b) REL-6-style
  scoped digest: blueprint slice + an iteration-relevant file list derived from the
  spec's IN SCOPE; (c) BEFORE building (b), add telemetry splitting developer
  read/context time vs build/test execution time — the growth may be project
  compile/test cost that no context digest fixes.
- **Why staged:** needs measurement (c) first to avoid optimizing the wrong term;
  D7's diff-only-context warning applies in spirit to over-slicing the developer's
  view of the product.

### CAND-VENDORED-SCAN-SCOPE · Vendored framework subtree trips adopter secret scans (staged — do not start)
- *(EVO-5 first real harvest, 2026-07-12 — cross-repo recurring symptom drafted
  from the digest; SEC-5-adjacent, staged at the sanctioned drafting ceiling;
  promotion human, EVO-1.)*
- **Proposed:** P2 · Effort S · Risk LOW.
- **Symptom (harvest evidence, cross-repo):** trendora `goal-session-mcp-loop`
  iter-27: vendored `incredible_auto_dev/` judgment fixtures
  (`tests/judgment/{auditor,reviewer,goal-evaluator}/case-*`, planted fake keys)
  "reliably light up as CRITICAL secret-assignment/aws-access-key findings but are
  NOT product anti-goal-#7 violations." tapeology `goal-session-yahoo_fetch`
  iter-6: "iter-5's scan CRITICAL came from vendored `incredible_auto_dev/**`
  judgment fixtures; the iter-6 pre-flight correctly moved those out."
- **Sketch:** SEC-5's `CHAIN_SCAN_BOOKKEEPING_EXCLUDES` default
  (`runs reports docs/handoffs docs/phases`) does not cover a vendored framework
  subtree; consider adding the vendored subtree dir to the default excludes for
  vendored deployments (or to the vendoring guidance in maintenance protocol §3.4),
  preserving SEC-5's path-based, never-value-allowlisting principle.
- **Triage note (staging session, 2026-07-12):** both adopters independently
  hand-worked around it (fixture relocation; path-prefix splitting by convention) —
  cheap to close structurally, and the scan stays CRITICAL-capable on product paths.

### CAND-JUDGE-REBASE · Judge goldens never re-validated on the Opus-5 cutover (staged — evidence attached)
- *(Staged 2026-07-25 by the CTX package session after its G9-approved judgment spot-run;
  promotion human, EVO-1.)*
- **Proposed:** P1 · Effort S (1 diagnostic dispatch + triage) or M (full re-baseline) ·
  Risk LOW (spend-gated).
- **Evidence:** `398bff9` moved the strong tier to `claude-opus-5` but its verification
  was `run-judgment-evals.sh --list` — an enumeration, not a dispatch; the 14 golden
  cases have NEVER been dispatched on Opus 5. The 2026-07-25 spot-run: goal-evaluator
  case-01 PASS (GOAL_ACHIEVED, 240 s); auditor case-01 expected PASS, got
  PASS_WITH_GAPS (247 s). The auditor's own verdict text shows it independently
  re-verified the product end-to-end ("confirmed the served HTML … across five states
  plus an HTML-injection attempt"), agreed the product is correct, and downgraded SOLELY
  on fixture-evidence fidelity (the planted QA screenshots are "stylized, annotated
  renderings rather than faithful captures") — precisely the over-verification the
  cutover commit's follow-up note predicted ("Opus 5 self-verifies without being told;
  the explicit 'verify your work' scaffolding in the judge bodies may now cause
  over-verification"). CTX-8's removed dispatch line has no plausible causal path to
  screenshot skepticism, and the goal-evaluator — same class of prompt edit —
  reproduced its golden exactly. Kept sandbox:
  `~/.cache/iad/shared/judgment-auditor-case-01-clean-pass-XhPIFr` (dispatch.log +
  verdict artifact).
- **Sketch:** (a) counterfactual first (~$2.38): re-run auditor case-01 with the
  pre-CTX-8 prompt line restored — same PASS_WITH_GAPS formally exonerates CTX-8;
  (b) full 14-case run on Opus 5 (~$29.52 est) to re-baseline the goldens;
  (c) per-failure triage: stale fixture evidence (upgrade the planted screenshots to
  faithful captures) vs judge-body "verify your work" scaffolding trimming per the
  cutover note — any judge-body edit then requires the full-run validation (G9/D4).
- **Why staged:** spend-class (G9) and judge-body scope — human promotion required.
- **RESOLVED (user-promoted 2026-07-25, executed 2026-07-25/26):**
  - Counterfactual (auditor case-01, pre-CTX-8 prompt restored): **FAIL** (316 s) —
    WORSE than the current prompt's PASS_WITH_GAPS ⇒ **CTX-8 formally exonerated**.
  - Full 14-case re-baseline on claude-opus-5: **13/14 PASS** — goal-evaluator 6/6,
    reviewer 4/4, auditor 3/4. Sole failure: auditor case-01-clean-pass (expected PASS,
    got PASS_WITH_GAPS, 270 s — same evidence-fidelity downgrade as the spot-run).
    Judges are stable on Opus 5; NO judge-body changes warranted.
  - Fixture fix: the case's two planted screenshots were regenerated as faithful
    Playwright captures of the fixture app's real states (UT-02 fresh-db
    `0 open · 0 done`; UT-01 seeded `1 open · 1 done` with Milk×2 open + Eggs×1 done) —
    all three of the auditor's cited objections addressed (missing "Open only" control,
    text the app never emits, styling the CSS cannot produce). Capture script:
    session scratchpad `capture_fixture_screens.py` (boots the fixture app, asserts the
    summary text, screenshots via headless chromium).
  - Confirmation dispatch (2026-07-26, user-approved): auditor case-01 on the fixed
    fixture → **PASS** (228 s). The golden suite stands **14/14 validated on
    claude-opus-5**. This candidate is CLOSED — the only surviving follow-up idea from
    the cutover note (trimming judge-body "verify your work" scaffolding) is NOT
    warranted on this evidence: the judges hold their goldens; only the fixture was
    stale. · Rich-reference fields: spec mockups + journey-tagged failing tests (staged — do not start)
- *(Staged 2026-07-25 by the context-engineering planning session — §18's source plan;
  blog rule 6 "simple specs → rich references"; promotion human, EVO-1.)*
- **Proposed:** P2 · Effort M · Risk MED.
- **Sketch (two independent halves):** (a) an optional
  `Reference: <path-to-html-mockup-or-screenshot>` line in the phase-spec header and in
  the decomposer's Goal Mode Metadata block — always its OWN line (the REL-14/CAND
  precedent: never annotate machine-parsed lines like `Target journeys:`);
  `ui-test-designer` + `browser-qa-agent` bodies gain "when a Reference is present,
  compare the rendered UI against it and cite divergences". Old specs parse unchanged
  (spec-optional = naturally inert). (b) the developer — NOT the decomposer, whose Rules
  (`agents/goal-decomposer/body.md:234`) forbid writing code — materializes
  journey-tagged TCs as failing tests first, named `tests/journeys/j<NN>_*`, making
  journeys executable acceptance (a TDD extension, not a new mechanism).
- **Why staged:** both halves touch dispatch-adjacent agent bodies and the spec grammar;
  promotion needs a fixture spec proving the Reference line flows through
  `goal_gate.py goal-slice` unchanged (G3) and a decision on where mockups live.
- **Verify idea:** run-evals + one fixture goal-iteration dry parse with a Reference
  line present and absent.

---

## 17. Absorbed-from-README ledger (traceability)

The README's "Token Optimization — Pending Work" and "Pipeline Hardening — Pending Work"
sections were removed on 2026-07-06 and absorbed here. Every pending item from those
sections, with its disposition:

| Old README item | Disposition |
|---|---|
| Step 0: establish telemetry baseline first | Absorbed → ground rule G8 + EVO-3 (benchmark = the baseline mechanism) |
| Tier-1 polish: per-agent project-template slicing | → **TOKEN-1** |
| Tier-2: orchestrator Opus→Sonnet | **DONE before absorption** — orchestrator is `standard` tier since the cutover (`agents/orchestrator/agent.yaml`, `config/model-tiers.yaml`) |
| Tier-2: goal-decomposer Opus→Sonnet | → **TOKEN-2** (guarded experiment; evaluator stays strong) |
| Tier-2: skip test-plan gen when spec has tests | → **TOKEN-3** |
| Tier-2: cap audit-failure full-rerun | → **TOKEN-4** |
| Tier-3 don't-touch list (qa tier, merge UI agents, eliminate retries) | → §3 do-NOTs **D1-D3** |
| "How to know when to stop" cost rule | → EVO-1 stop rule |
| Hardening: reviewer Opus→Sonnet | **STALE/DONE before absorption** — reviewer is `standard` tier already (`agents/reviewer/agent.yaml`) |
| Hardening: auditor extended-thinking + adversarial framing | Partially superseded (auditor at `--effort max`; adversarial fresh-context confirm exists for GOAL_ACHIEVED). Remaining delta → **REL-7** |
| Hardening: goal-mode iteration-state synthesis | → **REL-6** |
| Hardening trigger table ("signal that says do it now") | Absorbed into the **Trigger** lines of TOKEN-2 / REL-6 / REL-7 |
| Intro benchmark-evidence paragraph (May 2026, Opus 4.7 vs GPT-5.5) | Dropped as historical; cross-version measurement is now **EVO-3** |
| Shipped/[x] items in both sections | No action — they are history, recorded in git |

Also absorbed from `.claude/letter-to-future-sessions.md` "known limitations we chose
not to fix": pump PID-liveness → **REL-3**; cross-session lock → **REL-4**; scan_diff
is regex-grade → **SEC-1**; stall-detector blind spot → noted, no item (the evaluator's
STALLED judgment covers it; revisit only if it bites in practice → §16).

---

## 18. P1 — Context engineering (CTX-*, promoted 2026-07-25)

Source: Anthropic's blog "The new rules of context engineering for Claude 5 generation
models" (claude.com/blog, 2026-07-24) — six rule inversions: rules→judgment (delete
guardrail piles and conflicting directives), examples→interface design,
upfront→progressive disclosure, repetition→concision, manual memory→auto-memory,
simple specs→rich references. Mapped against this repo by the 2026-07-25 Fable-5
planning session; user approval of that plan = EVO-1 promotion of this section
(SPEED-4…7 approved-package precedent for the G6 multi-item exception).

Two constraints every CTX item respects: (1) **tier-aware relaxation** — standard
(sonnet-5) and strong (opus-5) are 5-gen models where judgment-style applies; the light
tier (haiku-4-5: qa, release-manager, retro-analyst) is NOT — literal checklists stay
literal for anything light-tier agents execute. (2) **Judges are protected** —
goal-evaluator, reviewer, auditor get NO semantic body edits in this series; changes to
the context they receive are validated by a G9-approved judgment spot-run (1 golden
case × 3 judges, abort if the printed estimate exceeds ~US$5). Frozen surfaces no CTX
item may touch: verdict formats (`.claude/workflow.md` §Verdict Formats,
`lib/verdicts.py`, `**Verdict:**` templates), the `Agent instructions:
.claude/agents/<name>.md` dispatch line (pump parses it,
`skills/goal-interactive-dispatch.md:130-139`), the `## Token and Questioning Policy`
heading in core.md, and the security hooks' deny logic.

### CTX-1 · Revive the PostToolUse hooks on Claude (stdin protocol, SEC-7 pattern)
- **Priority:** P0 · **Effort:** S · **Risk:** MED · **Status:** DONE 2026-07-25
- **Problem:** both PostToolUse hooks no-op on every fire on the Claude backend: the
  rendered settings pass `"$CLAUDE_TOOL_INPUT_FILE_PATH"` — an env var that never
  existed — so the hooks see an empty path and exit. The live artifact-schema feedback
  channel (schema warnings at the point of tool use — blog rule 2) is dead; it fires
  only inside run-evals, never in a real session.
- **Current state:** fake arg emitted by `_hooks_block_for_claude`
  (`adapters/claude/sync.py:204-209`, known FIXME; rendered into
  `.claude/settings.json` PostToolUse entries). Hooks read `$1` only:
  `hooks/post-edit-lint.sh:3`, `hooks/post-write-artifact-quality.sh:11-14`. The
  PreToolUse pair already has the fix pattern (SEC-7): argv `$1` preserved for
  Codex/tests, stdin JSON `.tool_input.command` with jq-primary/python3-fallback
  (`hooks/guard-dangerous-commands.sh:17-31`). Eval coverage for the PostToolUse pair
  is argv-only (`run-evals.sh` §5 ~:405-443).
- **Change spec:** (1) in `hooks/post-edit-lint.sh` and
  `hooks/post-write-artifact-quality.sh` add the guard's dual-mode input block: use
  `$1` when non-empty (Codex/argv contract unchanged), else read stdin JSON and extract
  `.tool_input.file_path // .tool_input.path // empty` (jq primary, python3 fallback);
  empty result → exit 0. Hooks stay advisory — warnings to stderr, always exit 0,
  NO decision JSON. (2) in `adapters/claude/sync.py` `_hooks_block_for_claude` delete
  the fake-arg branch so the rendered command is
  `bash "$CLAUDE_PROJECT_DIR/.claude/hooks/<name>" 2>/dev/null || true`; remove the
  FIXME. (3) resync. (4) add 4 stdin smokes to `run-evals.sh` §5: well-formed review
  via stdin → silent; malformed review via stdin → schema warning on stderr;
  syntax-error `.py` via stdin → lint warning; garbage/empty stdin → silent exit 0.
  Keep every existing argv smoke.
- **DoD:** printf-pipe smoke surfaces the schema warning; argv behavior byte-identical;
  evals green including the new checks.
- **Verify:** `printf '{"tool_input":{"file_path":"<bad-review-fixture>"}}' | bash
  .claude/hooks/post-write-artifact-quality.sh` shows the warning; then
  `./scripts/automation/run-evals.sh && python3 scripts/automation/sync-cli-assets.py
  --cli claude --check`
- **Files:** `hooks/post-edit-lint.sh`, `hooks/post-write-artifact-quality.sh`,
  `adapters/claude/sync.py`, `scripts/automation/run-evals.sh`, regenerated
  `.claude/hooks/*` + `.claude/settings.json` (+ codex mirrors via default sync).
- **Rollback:** revert hooks + adapter, resync — settings regenerate to the prior
  (inert) form.
- **Stop-and-ask:** if the live PostToolUse stdin payload turns out not to carry
  `.tool_input.file_path` for Write/Edit; if any smoke would require changing the
  PreToolUse guards' deny-JSON protocol.

### CTX-2 · Routing-table truth pass (CLAUDE.md "who reads what")
- **Priority:** P1 · **Effort:** S · **Risk:** MED · **Status:** DONE 2026-07-25
- **Problem:** the constitution's routing table over-claims readership, so agents hold
  contradictory directives (blog rule 1): "all agents read X" vs their own bodies.
- **Current state:** `CLAUDE.md` INSTRUCTION FILES table: workflow.md row says "All
  agents" (real inbound: `agents/goal-decomposer/body.md:21`,
  `agents/reviewer/body.md:73`, `ui-audit-phase.sh`); judgment-rubrics row says
  "evaluator, auditor, decomposer, reviewer" (real: `agents/auditor/body.md:177`
  direct; goal-evaluator transitively via `skills/goal-evaluation-methodology.md`);
  architecture/ row says "Reference (all agents)" — directly contradicted by
  `agents/orchestrator/body.md:16` "Do NOT read `.claude/architecture/*.md`";
  delegation-templates row says "Anyone dispatching agents" (real inbound:
  `model-orchestration.md:63` only). `.claude/workflow.md:70` artifact row claims
  architecture docs are read by "All agents (reference)".
- **Change spec:** edit the four CLAUDE.md reader cells to verified truth: workflow.md →
  "goal-decomposer, reviewer; on-demand pipeline reference for others";
  judgment-rubrics → "auditor (direct); goal-evaluator (via its methodology skill);
  anyone making verdict-class calls"; architecture/ → "framework maintainers only —
  pipeline agents must NOT read these (orchestrator rule)"; delegation-templates →
  "interactive maintainer sessions dispatching ad-hoc subagents". Same commit: fix
  `.claude/workflow.md:70` readers cell to "framework maintainers (reference)".
  `docs/cli-providers.md`: only if it claims AGENTS.md is committed, correct it
  (AGENTS.md is gitignored — `.gitignore:3-4` — and rendered at sync). Truth-only
  edits; no format churn.
- **DoD:** every "Who reads it" cell backed by a grep hit in a body/skill/script or
  explicitly marked on-demand; no cell contradicts an agent body.
- **Verify:** `./scripts/automation/run-evals.sh` (includes doc-drift checks).
- **Files:** `CLAUDE.md`, `.claude/workflow.md`, possibly `docs/cli-providers.md`.
- **Rollback:** revert.
- **Stop-and-ask:** CLAUDE.md is ask-first class — the 2026-07-25 plan approval is that
  ask; STOP if the edit grows beyond reader cells. Land between sessions (cache prefix).

### CTX-3 · Single-source the three duplicated tables + stale-value sweep
- **Priority:** P1 · **Effort:** M · **Risk:** MED · **Status:** IN-PROGRESS — implemented 2026-07-25, awaiting fresh-session verify (G8). Note: the DoD's "Opus 4.8 → 0" grep is satisfied for live docs; the only remaining hits are this item's own defect quotes in this file.
- **Problem:** the model-tier table is restated 4×, the pipeline stage table and the
  artifact map 2× each — and the copies have already diverged (decomposer tier, audit
  retry count), so different agents read contradictory facts (blog rules 1+4).
- **Current state:** tier table: `config/model-tiers.yaml` (authoritative) +
  `.claude/model-orchestration.md:22-26` (correct, reflects TOKEN-2
  decomposer=standard) + `.claude/workflow.md:238-246` (:242 wrongly lists
  decomposition under strong) + `.claude/architecture/agents.md:7-11` (:9 same
  staleness; `agents/goal-decomposer/agent.yaml` says `model_tier: standard`). Stage
  table: `.claude/workflow.md:15-29` (has the TOKEN-3 skip note) duplicated by
  `.claude/architecture/pipeline.md` (:57 "max 2 attempts" contradicts
  `run-phase.sh:102` `MAX_AUDIT_RETRIES=3`). Artifact map: `.claude/workflow.md:46-71`
  duplicated by `.claude/architecture/artifacts.md`. Stale model name:
  `docs/goal-mode-interactive.md:109-110` "strong tier is Opus 4.8".
- **Change spec:** direction — runtime copies live in `.claude/workflow.md` +
  `.claude/model-orchestration.md`; `architecture/` docs point, never restate.
  (1) workflow.md:238-246 tier table → 3-line pointer (resolution: `agent.yaml
  model_tier` → `config/model-tiers.yaml`; prose table only in model-orchestration §1,
  maintained per maintenance-protocol §6). (2) architecture/agents.md:7-11 → same
  pointer; spot-fix any stale per-agent tier in the catalog below (decomposer =
  standard). (3) architecture/pipeline.md → drop duplicated stage/retry specifics,
  point to workflow.md §Pipeline + §Retry Policy; fix or delete the ":57 max 2" text.
  (4) architecture/artifacts.md → drop rows verbatim-duplicating workflow.md:48-71;
  keep goal-mode-only rows + a pointer. (5) goal-mode-interactive.md:109-110 →
  tier-neutral wording ("the strong tier resolves via config/model-tiers.yaml").
  NEVER touch workflow.md §Verdict Formats. Pre-check
  `grep -rn "workflow.md" scripts/` for any cell-text dependency first.
- **DoD:** exactly one prose tier table remains (model-orchestration.md); no
  stage/artifact/tier fact stated in two files; decomposer shown standard everywhere or
  nowhere; `grep -rn "Opus 4.8" docs/ .claude/` → 0.
- **Verify:** the grep above + `./scripts/automation/run-evals.sh`.
- **Files:** `.claude/workflow.md`, `.claude/architecture/{agents,pipeline,artifacts}.md`,
  `docs/goal-mode-interactive.md` (all hand-authored — direct edits; default sync
  refreshes the AGENTS.md embed).
- **Rollback:** revert files.
- **Stop-and-ask:** any script found grepping workflow.md stage-table cell text.

### CTX-4 · Count-claims fix + doc-drift eval extended to `.claude/architecture/`
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** DONE 2026-07-25
- **Problem:** architecture docs assert wrong inventory numbers and nothing gates them,
  so they re-rot after every agent/skill addition.
- **Current state:** real counts: 20 `agents/*/` dirs, 15 `skills/*.md`, 5 `hooks/*.sh`,
  7 `commands/*.md`. Wrong: `.claude/architecture/README.md:12` "All 19 agents", `:14`
  "13 skills and 5 hooks"; `configuration.md:28` "19 agents … (12 phase-mode + 2 goal
  -mode)"; `skills-and-hooks.md:3` "Skills (9 total)"; `system-overview.md:~37` same
  "9 total" + the :35 grouping paragraph (real grouping per agents.md:3: 12 phase +
  4 goal + 4 showcase). `tests/automation/test-doc-drift.sh` scans README.md +
  CLAUDE.md only.
- **Change spec:** (1) fix every count to match the tree; prefer deleting hard numbers
  where they add nothing (rule 4), keep them where the doc is an inventory. (2) extend
  `test-doc-drift.sh` to scan `.claude/architecture/*.md` "N agents/skills/commands/
  hooks" claims against neutral-source counts, with a broken-fixture assertion first
  (file's existing pattern); it is already wired into run-evals §2c.
- **DoD:** drift test red on a seeded wrong count, green on the fixed tree.
- **Verify:** `bash tests/automation/test-doc-drift.sh && ./scripts/automation/run-evals.sh`
- **Files:** `.claude/architecture/{README,configuration,skills-and-hooks,system-overview}.md`,
  `tests/automation/test-doc-drift.sh`.
- **Rollback:** revert.

### CTX-5 · Stop requiring reads of nonexistent `docs/architecture/`
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** DONE 2026-07-25
- **Problem:** three "always read first" lists and two workflow rows require
  `docs/architecture/*.md`, but the directory does not exist until `update-docs.sh`
  creates it after the first finalized phase — every early dispatch burns a failed
  lookup plus "am I missing context?" doubt.
- **Current state:** required by `agents/developer/body.md:12`,
  `agents/orchestrator/body.md:12`, `.claude/workflow.md:17` and `:69`. Producer:
  `scripts/automation/update-docs.sh` (project mode, header :5-8).
- **Change spec:** append to all four sites: "(if present; created by update-docs.sh
  from the first finalized phase — absence is normal early on, skip silently)".
  Version-bump `agents/{developer,orchestrator}/agent.yaml`, resync.
- **DoD:** no instruction file lists docs/architecture/ as unconditional; mirrors
  regenerated.
- **Verify:** `python3 scripts/automation/sync-cli-assets.py --cli claude --check &&
  ./scripts/automation/run-evals.sh`
- **Files:** `agents/developer/body.md`, `agents/orchestrator/body.md`,
  `.claude/workflow.md`, two `agent.yaml` bumps, regenerated mirrors.
- **Rollback:** revert + resync.

### CTX-6 · Make the repo's own `docs/goal.md` pass its own validator (dogfooding)
- **Priority:** P1 · **Effort:** S · **Risk:** MED · **Status:** DONE 2026-07-25
- **Problem:** the framework hard-fails adopters whose goal.md lacks `## Must-have user
  journeys` + `## Anti-goals` (anti-pattern #18), yet this repo's own `docs/goal.md`
  has neither — `/goal` on this repo dies at validation, and the in-repo exemplar
  teaches the wrong shape (blog rule 6: the spec artifact IS the reference).
- **Current state:** `docs/goal.md` (1,705 B) has `## Non-Goals`, no journeys section.
  Validator: `validate_goal_file`, `run-goal.sh:658-699` (error strings :667/:673,
  journey-entry check ending :695). `render_iteration_summary.py:110-113` reads
  `## Vision` + `## Must-have user journeys` when present.
- **Change spec:** keep Vision/Target Users/Key Capabilities and the adopter note;
  rename `## Non-Goals` → `## Anti-goals` (entries already are veto-class); add
  `## Must-have user journeys` with the four journeys approved in the 2026-07-25 plan,
  in the exact `- **J-NN: <name>**` format, each with a verify: line naming observable
  evidence: J-01 adopter ships phase-1 to CLOSURE-PASS with all 6 UI artifacts
  (evidence: `runs/phase-1/status.json` + `reports/phase-1-*`); J-02 a goal session on
  a small goal reaches GOAL_ACHIEVED only through deterministic gates + two-key confirm
  (evidence: telemetry halt event + `gate-report.md` + confirm verdict); J-03 an
  interrupted session resumes from checkpoint without repeating completed steps
  (evidence: checkpoint markers + engine log skips); J-04 `run-evals.sh` runs offline
  <30 s, red on seeded mirror drift, green after resync (evidence: exit codes both
  states).
- **DoD:** the three validator greps pass; goal-lint deterministic pass clean.
- **Verify:** `grep -q '^## Must-have user journeys' docs/goal.md && grep -q
  '^## Anti-goals' docs/goal.md && grep -qE '^- \*\*J-[0-9]+:' docs/goal.md &&
  ./scripts/automation/run-evals.sh`
- **Files:** `docs/goal.md`.
- **Rollback:** revert file.
- **Stop-and-ask:** goal.md journeys/anti-goals are ask-first class — the 2026-07-25
  plan approval covered these four drafts; STOP if changing them materially.

### CTX-7 · core.md restructure: intent + gotchas + tier-aware checklists (~10.8 KB → ≤6 KB)
- **Priority:** P1 · **Effort:** M · **Risk:** HIGH · **Status:** TODO
- **Problem:** ~17 dispatch sites and all agent bodies route to `.claude/core.md`
  (10,775 B ≈ 2.7 K tokens per dispatch), and roughly a third of it duplicates content
  owned elsewhere. Anthropic removed >80% of Claude Code's system prompt for 5-gen
  models with no eval loss — this is the repo's equivalent move (rules 1+3+4).
- **Current state (measured section map):** behavioral principles :1-48 (2,153 B);
  code-quality checklist :50-63 (729 B); env-errors gotcha :66-73 (395 B); visual
  checklist :76-90 (1,038 B); testing :93-108 (773 B); external-integration :111-121
  (655 B); security :124-134 (531 B); `## Token and Questioning Policy` :137-163
  (1,224 B — HEADING IS LOAD-BEARING, named by ~20 dispatch sites + agent bodies);
  Definition of Done :166-189 (1,406 B — duplicates workflow.md verdict gates +
  judgment-rubrics §2); Handoff Requirements :192-203 (521 B — duplicates
  `agents/developer/body.md` handoff format); UI Visibility Rules :206-220 (1,304 B —
  overlaps workflow.md §UI Evolution Policy + UI-chain bodies/skills). No script greps
  any core.md section name except the policy heading.
- **Change spec:** rewrite `.claude/core.md` (hand-authored, direct edit):
  (1) behavioral principles → ~6 intent lines ("write code that reads like the
  surrounding code; build only what the spec names; when uncertain, state the
  assumption in the plan artifact and proceed unless it's irreversible…").
  (2) KEEP verbatim in checklist form — light-tier agents execute these literally:
  Code Quality, Visual Quality, Testing Requirements, External Integration Testing,
  Security Baseline, env-errors gotcha. (3) KEEP the `## Token and Questioning Policy`
  heading EXACTLY; trim its body to ~900 B. (4) DELETE Definition of Done (→ 2-line
  pointer to workflow.md §Verdict Formats + judgment-rubrics §2) and Handoff
  Requirements (developer body owns it); compress UI Visibility Rules to ~4 intent
  lines + pointer to workflow.md §UI Evolution Policy. (5) keep anti-pattern cites
  (#21, #15/#16) — pointing at the CTX-12 tree paths if that landed first. Target
  ≤6 KB. Default sync afterwards (AGENTS.md embeds core.md).
- **DoD:** `grep -c '^## Token and Questioning Policy' .claude/core.md` = 1;
  `wc -c` ≤ 6000; every deleted fact has a named live single source (commit message
  lists them); evals green; judgment spot-run shows no verdict-class flip.
- **Verify:** the two greps + `./scripts/automation/run-evals.sh` + the G9-approved
  spot-run (1 case × 3 judges); G8: pre-register predicted ~−1.2 K tokens/dispatch in
  `benchmarks/experiments.md` before a real-session/benchmark observation.
- **Files:** `.claude/core.md` (+ AGENTS.md regenerates via sync).
- **Rollback:** revert core.md, resync.
- **Stop-and-ask:** any script grepping core.md section names beyond the policy
  heading; any verdict-class flip in the spot-run; land between sessions (cache).

### CTX-8 · Dispatch-prompt concision + pump no-reread note
- **Priority:** P1 · **Effort:** S · **Risk:** MED · **Status:** DONE 2026-07-25 — refinement found during implementation: the pump note is CONDITIONAL on the `Agent instructions: .claude/agents/` pointer being present in the prompt, so non-agent dispatches (two-key confirms, ad-hoc) and the self-test's byte-exact round-trips stay untouched. G9 spot-run (2 of 3 judges, $4.76 est ≤ the $5 guard; reviewer covered by the offline verbatim-parity eval instead): goal-evaluator case-01 PASS; auditor case-01 flipped PASS→PASS_WITH_GAPS. User-promoted follow-up (2026-07-25/26): counterfactual with the old prompt scored WORSE (FAIL) and the full 14-case Opus-5 re-baseline passed 13/14 with the same single fixture-evidence failure — CTX-8 exonerated, fixture screenshots regenerated as faithful captures (see CAND-JUDGE-REBASE, §16).
- **Problem:** every dispatch prompt repeats "Apply the TOKEN AND QUESTIONING POLICY
  from .claude/core.md strictly." although all 18 agent bodies already carry that exact
  directive (rule 4). Separately, on the interactive backend the subagent's system
  prompt IS `.claude/agents/<name>.md`, yet the prompt still says "read this first" —
  pump-path agents re-Read their own 8-20 KB definition every dispatch.
- **Current state:** 17 engine sites: `dev-phase.sh:101`, `review-phase.sh:63`,
  `qa-phase.sh:147`, `generate-test-plan.sh:53`, `phase-audit.sh:80`,
  `run-phase.sh:168`, `render-summary.sh:91`, `finalize-phase.sh:161`,
  `goal-iter-lean.sh:840`, `run-goal.sh:300,365,433,476,1785,2092,2387`,
  `lib/common.sh:552`; plus 3 verbatim-parity copies in
  `run-judgment-evals.sh:293,375,449`. The `Agent instructions:` line is load-bearing
  (pump identity derivation) — untouchable. Backend-conditional prompt-note precedent:
  the TMPDIR bridge in `lib/interactive-dispatch.sh:183-185`.
- **Change spec:** (1) delete the policy line at all 17 engine sites AND the 3
  judgment-builder sites in the SAME commit (verbatim parity). (2) in
  `_interactive_invoke` (`lib/interactive-dispatch.sh`, directly after the TMPDIR
  bridge) append to the prompt: "Note: your agent definition (.claude/agents/… named
  above) is already loaded as your system prompt — do not Read it again; treat its
  'read this first' pointer as satisfied." (3) no other prompt-template changes.
- **DoD:** `grep -rn "TOKEN AND QUESTIONING" scripts/automation/ | wc -l` → 0 (agent
  bodies keep theirs); interactive self-test green; saving ~8-20 KB avoided re-read
  per interactive dispatch.
- **Verify:** the grep + `bash scripts/automation/lib/interactive-dispatch.sh
  --self-test && ./scripts/automation/run-evals.sh`; then the G9 spot-run (shared with
  CTX-7 when adjacent).
- **Files:** the 13 engine scripts, `scripts/automation/lib/interactive-dispatch.sh`,
  `scripts/automation/run-judgment-evals.sh`.
- **Rollback:** revert (pure line removals + one additive note).
- **Stop-and-ask:** if any judgment-builder prompt already diverges from its engine
  twin beyond this line — report the broken parity, don't paper over it.

### CTX-9 · iteration-summarizer rightsizing: goal-only templates → skill
- **Priority:** P1 · **Effort:** M · **Risk:** MED · **Status:** TODO
- **Problem:** the summarizer runs every iteration on both backends, but 3.3 KB of its
  18 KB body is templates used only in goal mode ("Cumulative project story") or once
  per session ("Delivered wrap", GOAL_ACHIEVED only) — detail that should load at the
  right time (rule 3), mirroring the goal-evaluator's body+methodology-skill pattern.
- **Current state:** `agents/iteration-summarizer/body.md` 18,038 B; `## Cumulative
  project story — goal mode only` :207 and `## Delivered wrap — goal mode,
  GOAL_ACHIEVED only` :255 (together :207-290 ≈ 3,299 B). Body already names
  `skills/visible-change-summarizer.md` (:23). Machine-parsed constraints living
  OUTSIDE the moved block: `render_iteration_summary.py` hard-requires `## In plain
  words` (:2402-2414 self-test); `lint_contracts.py` requires the body to name its
  verdict enum values.
- **Change spec:** (1) create `skills/iteration-story-templates.md` — H1 + the two H2
  sections moved verbatim (byte-identical templates ⇒ identical emitted artifacts;
  ≥20 content lines satisfies validate_skills). (2) replace the two body sections
  with: "Goal mode: read `.claude/skills/iteration-story-templates.md` and emit its
  Project-story section per its rules; on GOAL_ACHIEVED additionally its Delivered-wrap
  section. Phase mode: skip that skill entirely." (3) keep `## Verdict resolution`,
  `## Output contract`, `## In plain words` templates in the body untouched.
  (4) version-bump `agent.yaml`, resync.
- **DoD:** body ≤15 KB; renderer self-test green; lint_contracts green; skills
  validator green.
- **Verify:** `python3 scripts/automation/lib/render_iteration_summary.py self-test &&
  python3 scripts/automation/lib/lint_contracts.py lint &&
  ./scripts/automation/run-evals.sh`
- **Files:** `agents/iteration-summarizer/{body.md,agent.yaml}`, new
  `skills/iteration-story-templates.md`, regenerated mirrors.
- **Rollback:** move the sections back, delete the skill, resync.
- **Stop-and-ask:** any script grepping the summarizer BODY for the moved headings;
  renderer self-test failing after the move.

### CTX-10 · developer body "18 Rules" → intent + gotchas
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** TODO
- **Problem:** the developer (standard tier = sonnet-5, 5-gen — judgment applies)
  carries 18 flat imperative rules, 10 of which are "Frontend:" restatements of the
  DESIGN SYSTEM config and core.md's visual checklist (rule 1: guardrail duplication).
  The body also contradicts itself: :8 "CLAUDE.md is auto-loaded — do not Read it
  again" vs :37 process step 1 "Read CLAUDE.md, project-template.md, …".
- **Current state:** `agents/developer/body.md:111-129` (Rules), :8 vs :37 (conflict).
  Hard operational gotchas mixed into the rules: server-cleanup pkill list,
  `--skip-git` on create-next-app, never-commit list, backend-enforced state
  transitions.
- **Change spec:** rewrite `## Rules` as (a) GOTCHAS kept verbatim (the four above);
  (b) one intent paragraph replacing the 10 Frontend bullets: "UI work follows the
  DESIGN SYSTEM in `.claude/project-template.md` and the Visual Quality checklist in
  `.claude/core.md` — tokens not arbitrary values, library components not div soup,
  all interaction/loading/empty/error states, visually consistent with prior pages";
  (c) keep the scope/test-exactness lines (top failure modes — the allowed "highly
  important area" restatement). Fix the :37 conflict: drop CLAUDE.md from process
  step 1's read list. Version-bump, resync.
- **DoD:** every hard gotcha still present verbatim; no rule contradicts core.md; no
  internal contradiction; body ≤7.5 KB.
- **Verify:** `python3 scripts/automation/lib/lint_contracts.py lint &&
  ./scripts/automation/run-evals.sh`
- **Files:** `agents/developer/{body.md,agent.yaml}`, mirrors.
- **Rollback:** revert + resync.

### CTX-11 · goal-decomposer body split (evaluator pattern) — consistency, not tokens
- **Priority:** P2 · **Effort:** M · **Risk:** MED · **Status:** TODO
- **Problem:** the decomposer body (19,786 B, largest) interleaves its machine-parsed
  output-template contract with 9.1 KB of methodology; the evaluator already models
  the right shape (small contract body + mandatory methodology skill). Honest
  accounting: the methodology is needed on every planning dispatch, so this saves
  ~0 tokens — the payoff is structural consistency, safer future edits (methodology
  edits stop touching the parsed template), and enabling later conditional loading.
- **Current state:** methodology block `agents/goal-decomposer/body.md:130-231`
  (journey-priority rubric :130, depth :143, required-still-passing :173, baseline
  :199-216, anti-goal handling :217, pre-write self-check :221). Template :34-129 is
  machine-parsed downstream (`goal_gate.py goal-slice --targets` reads the raw
  `Target journeys:` line; `run-goal.sh:1978`) — MUST stay in the body byte-exact.
  Body names no skills today.
- **Change spec:** move :130-231 verbatim into new
  `skills/goal-decomposition-methodology.md` (H1 + existing H2s); body gains the
  evaluator-style header line: "Your methodology is
  `.claude/skills/goal-decomposition-methodology.md` — read it FIRST; in
  `Mode: baseline` you need only its Baseline section." plus a numbered input-list
  entry. Keep `## Rules`, the template, and `## Token and Questioning Policy` in the
  body. Pure move ONLY — the decomposer has no judgment fixtures, so semantic edits
  here are unvalidated. Version-bump, resync; note the shifted anchors on the §16
  CAND-TIER sketch (roadmap tolerates re-grep per its header).
- **DoD:** body ≤11 KB; template region byte-identical (diff shows pure move); skill
  passes validate_skills; evals green.
- **Verify:** `python3 scripts/automation/lib/lint_contracts.py lint &&
  ./scripts/automation/run-evals.sh` + `git diff` inspection for move-purity.
- **Files:** `agents/goal-decomposer/{body.md,agent.yaml}`, new
  `skills/goal-decomposition-methodology.md`, mirrors, roadmap anchor note.
- **Rollback:** fold the skill back, resync.
- **Stop-and-ask:** if the diff is not a pure move — any wording change to the rubric
  is a semantic judge-adjacent edit needing its own review.

### CTX-12 · anti-patterns.md → `.claude/anti-patterns/` tree (index + per-entry files)
- **Priority:** P1 · **Effort:** M · **Risk:** MED · **Status:** IN-PROGRESS — implemented 2026-07-25 (verbatim split byte-proven; pathless `#N` citations kept — numbers are frozen IDs), awaiting fresh-session verify (G8)
- **Problem:** a 36,104 B monolith of 23 entries; CLAUDE.md routes orchestrator +
  reviewer + auditor to it — up to ~9 K tokens per reader for content where any one
  dispatch needs 1-2 entries. Textbook progressive disclosure (rule 3).
- **Current state:** entries `## <N>. <title>`. Verified: NO script parses entry
  boundaries (all references are error-message/comment strings; `harvest-lessons.sh`
  is read-only; `condense.sh` touches the file only under `--human`). Reference
  inventory: `run-goal.sh:667,673,695` (#18); `run-phase.sh:292,310`,
  `ui-test-design-phase.sh:111,126`, `browser-qa-phase.sh:370` (#20);
  `lib/chain-tmp.sh:10` (#21); `lib/goal-gates.sh:45`; `lib/common.sh:404` (#12);
  `lib/checkpoint.sh:7` (#5); `lib/condense.sh:14,17`; `harvest-lessons.sh:18`;
  `CLAUDE.md:33`; `core.md:72` (#21) + `:120` (#15/#16); `maintenance-protocol.md`
  §2 + §4; `letter-to-future-sessions.md:54`; `skills/goal-authoring.md:7`.
- **Change spec:** (1) create `.claude/anti-patterns/README.md`: 3-line intro (what
  this is; read the index, open only matching entries; append protocol) + index table
  `| # | Title | Applies when | Rule (one line) |` (~2.5 KB). (2) move each entry
  verbatim to `.claude/anti-patterns/<NN>-<slug>.md` (zero-padded; numbering frozen;
  next entry = 24). (3) delete the monolith. (4) update every reference above (script
  strings → the entry file path; CLAUDE.md row → the README index;
  maintenance-protocol §2 → "create the next-numbered file + add an index row", §4
  condense clause adjusted). `skills/goal-authoring.md` is neutral-source — resync
  after. (5) add an eval check (test-doc-drift.sh or run-evals §3c): every `NN-*.md`
  has exactly one index row and vice versa, no numbering gaps/dupes (fixture-red
  first). ONE commit — atomic revert.
- **DoD:** monolith gone; `grep -rn "\.claude/anti-patterns\.md" scripts/ .claude/*.md
  CLAUDE.md skills/ agents/` → 0 live references; new eval check proven red-able;
  evals green.
- **Verify:** the grep + `./scripts/automation/run-evals.sh`.
- **Files:** `.claude/anti-patterns.md` → `.claude/anti-patterns/*` (24 files),
  ~10 scripts, `CLAUDE.md`, `.claude/{core,maintenance-protocol,
  letter-to-future-sessions}.md`, `skills/goal-authoring.md` (+resync),
  `tests/automation/test-doc-drift.sh` or `run-evals.sh`.
- **Rollback:** `git revert` of the single commit restores monolith + references.
- **Stop-and-ask:** any parser (not citation) of entry boundaries found → fall back to
  the in-file index variant (index table at top of the monolith) and record that here.

### CTX-13 · `escalate_model_on` must fail loud
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** DONE 2026-07-25
- **Problem:** when strong-tier resolution errors, the escalation ladder silently
  degrades — the retry runs on the default tier while logs claim nothing.
- **Current state:** `scripts/automation/lib/common.sh:857-869`:
  `tier-model strong 2>/dev/null || true` then `if [[ -n "$_m" ]]` with no else —
  empty result = silent no-op; the `[escalation]` line prints only on success.
- **Change spec:** add the else branch: stderr
  `[escalation] WARNING: strong-tier model resolution FAILED — retry continues on the
  agent's default tier (check config/model-tiers.yaml / agent_permissions.py)` plus a
  guarded `record_telemetry_event "model_escalation"
  '{"escalated":false,"reason":"tier-resolution-failed"}'`. Return 0 unchanged. Add a
  simulated-failure case (PATH-shadowed python3 or bad module path in a subshell) to
  `tests/automation/test-quota-retry.sh` or a sibling test.
- **DoD:** simulated failure prints the warning + emits the event; success path
  byte-identical.
- **Verify:** the new test + `./scripts/automation/run-evals.sh`.
- **Files:** `scripts/automation/lib/common.sh`, one test file.
- **Rollback:** revert.

### CTX-14 · GENERATED markers on rendered mirrors (without breaking `--check`)
- **Priority:** P2 · **Effort:** M · **Risk:** MED · **Status:** TODO
- **Problem:** `.claude/agents|skills|hooks|commands` + `.claude/settings.json` carry
  no in-file DO-NOT-EDIT signal although hand-editing mirrors is the documented #1
  silent-corruption risk (maintenance-protocol §3); a session landing in a mirror file
  has no point-of-use warning (rule 2: make the interface carry the instruction).
- **Current state:** agents are rendered (`render_agent_md`,
  `adapters/claude/sync.py:84-115`; straggler delete globs `*.md` :137-143);
  skills/hooks/commands are byte-verbatim `mirror_directory` copies
  (`adapters/lib/translate.py:237-267`, deletes dst files absent from src); settings
  fully rendered (:264-289). Constraints verified: a sentinel `.md` in skills would
  FAIL `validate_skills.py` (≥20 lines) — sentinel must be a dotfile;
  `mirror_directory` would stale-delete unknown dst files — needs an ignore rule.
- **Change spec:** all renderer-owned so `--check` stays truthful: (1) agents:
  `render_agent_md` emits `<!-- GENERATED from agents/<name>/ — edit the neutral
  source, then: python3 scripts/automation/sync-cli-assets.py -->` as the first body
  line after frontmatter (confirm validate_agents + the subagent loader tolerate it on
  ONE agent first). (2) skills/hooks/commands: each sync fn writes
  `.claude/<dir>/.GENERATED-DO-NOT-EDIT` (fixed 2-line content, idempotent);
  `mirror_directory` gains `ignore={".GENERATED-DO-NOT-EDIT"}` in its stale-delete
  set. Same for the codex adapter. (3) settings.json: `"_generated"` key via the
  passthrough header. Update maintenance-protocol §3 naming the markers. Commit
  regenerated mirrors.
- **DoD:** every mirror dir carries a marker; fresh sync reproduces them; `--check`
  green immediately after sync; hooks still execute; evals green.
- **Verify:** `python3 scripts/automation/sync-cli-assets.py && python3
  scripts/automation/sync-cli-assets.py --cli claude --check &&
  ./scripts/automation/run-evals.sh`
- **Files:** `adapters/claude/sync.py`, `adapters/codex/sync.py`,
  `adapters/lib/translate.py`, `adapters/claude/passthrough/*`,
  `.claude/maintenance-protocol.md`, regenerated mirrors.
- **Rollback:** revert adapters + resync (markers disappear on next render).
- **Stop-and-ask:** if `validate_agents.py` or Claude Code's subagent loader chokes on
  the post-frontmatter comment; if `mirror_directory` semantics are shared with a
  consumer that enumerates dst files.

---

## 19. P1 — Plain-language output (PLAIN-*, promoted 2026-07-26)

Source: direct user request 2026-07-26 — "the language to explain to me is very hard to
understand; make it simpler and clearer without impacting quality." Scoped by a Fable-5
planning session; user approval of that plan = EVO-1 promotion of this section
(SPEED-4…7 / §18 precedent). User-locked decisions: plain layer in **simple English**
(no bilingual layer for now); console rework covers **halts + pauses + verdicts only**
(diagnostic/tripwire lines stay technical); **goal-evaluator prose IS in scope** behind
a ~US$5 judgment spot-run; reviewer/auditor bodies untouched (judges-are-protected,
§18 constraint 2).

Hard rule for every PLAIN item: machine-parsed surfaces stay **byte-identical** — enum
tokens, `**Verdict:**`-class lines, H2 names, plain-words labels, JSON keys, artifact
paths, exit codes. Plain language is ADDED next to the codes, never replacing them.
Single source for the plain wording: the sentence table in
`scripts/automation/lib/plain-language.sh`; `docs/READING-REPORTS.md` and
`skills/plain-language.md` copy from it, never fork it.

### PLAIN-1 — DONE 2026-07-26, archived
