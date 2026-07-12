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
  Opus 4.8 / Sonnet 5 (or whatever `config/model-tiers.yaml` says when you read this).
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
5. **SPEED-1 → SPEED-2 → SPEED-3** (strict order), **TOKEN-1…7** (TOKEN-2 requires
   EVO-3 + REL-1 to exist; TOKEN-7 is independent of the SPEED chain).
6. **REL-2…11, SEC-1…4, QUAL-1, REP-1…3, DOC-3…7** — as capacity allows; SEC-4 pairs
   with SAFE-1; REL-8 must land before any real `CHAIN_AGENT_EFFORT` use; REL-9 is
   cheap — do it early; REL-10/REL-11 were user-promoted 2026-07-11 (one bundled
   session) and verify together via the §9 benchmark rerun.
7. **EXP-** items only with explicit human sign-off and a written design doc first.

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

### TOKEN-1 · Per-agent project-template slicing
- **Priority:** P1 · **Effort:** M · **Risk:** LOW · **Status:** TODO  *(absorbed:
  README Token-Opt Tier-1 polish)*
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
- **Priority:** P1 · **Effort:** S · **Risk:** MED · **Status:** BLOCKED (needs EVO-3 +
  REL-1) *(absorbed: README Token-Opt Tier-2; the orchestrator half is already DONE —
  see §17 ledger)*
- **Problem:** the decomposer runs on the strong tier every iteration; spec-writing may
  be within standard-tier reach now that it receives the goal slice + journey digest.
- **Current state:** `agents/goal-decomposer/agent.yaml` `model_tier: strong`;
  goal-evaluator MUST stay strong (adversarial judgment — old README said the same);
  judge-effort guard (D4) stays regardless of tier.
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
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** TODO *(absorbed:
  README Token-Opt Tier-2)*
- **Problem:** full-mode Step 2 generates a functional test plan even when the phase
  spec already contains explicit test scenarios — a wasted dispatch.
- **Current state:** `run-phase.sh` Step 2 always runs the qa test-plan generator.
- **Change spec:** deterministic heuristic (spec contains a `## Test` section or ≥3
  `TC-` lines) → skip generation and note the skip in the run log; NEVER skip silently.
  Knob `CHAIN_SKIP_TESTPLAN_IF_PRESENT` default `true` after one observed clean phase.
- **DoD:** sandbox phase with tests-in-spec skips with a logged reason; phase without
  them generates as today; evals green.
- **Verify:** `bash -n scripts/automation/run-phase.sh && ./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/run-phase.sh`.
- **Rollback:** knob.

### TOKEN-4 · Cap the audit-failure full-rerun
- **Priority:** P1 · **Effort:** S · **Risk:** MED · **Status:** TODO *(absorbed:
  README Token-Opt Tier-2)*
- **Problem:** on audit FAIL, the hardening loop (`run-phase.sh:855-908`,
  `MAX_AUDIT_RETRIES=3`) re-runs developer + reviewer + full QA on EVERY failed
  attempt — the most expensive retry in the pipeline. (The old README cited
  `:649-679`; the loop has moved — verified 2026-07-06.)
- **Current state:** full rerun per attempt as above; the dev pass inside it already
  escalates to the strong tier (`escalate_model_on`, `run-phase.sh:887`; the
  dev/review-loop equivalent is `:583`); a QA FAIL inside hardening hard-fails the
  phase (`audit_qa_failed`).
- **Change spec:** after the FIRST full rerun, subsequent audit FAILs in the same phase
  switch to fix-only mode (developer fix + reviewer + audit re-check, no full QA rerun),
  logged. Knob `CHAIN_AUDIT_RERUN_CAP=1`.
- **DoD:** sandbox test of the audit-fail path shows the cap; evals green.
- **Verify:** targeted test + `./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/run-phase.sh`.
- **Rollback:** knob (cap=0 → old behavior).
- **Stop-and-ask:** if telemetry shows audits legitimately need full reruns (fix-only
  passes audit but phase ships bugs), revert and mark STALE with evidence.
- **Trigger:** telemetry shows the audit-fail full-rerun firing more than rarely.

### TOKEN-5 · Interactive pump token-usage telemetry
- **Priority:** P1 · **Effort:** M · **Risk:** MED · **Status:** TODO
- **Problem:** interactive (pump) sessions record NO token usage — documented gap
  (`docs/goal-mode-telemetry.md:133`) — so all cost work is blind in interactive mode.
- **Current state:** headless gets `claude_usage` events from the stream renderer
  sidecar (`lib/quota-retry.sh:583-593`, `lib/telemetry.sh:139-159`); the pump protocol
  result files carry no usage field (`skills/goal-interactive-dispatch.md`).
- **Change spec:** extend the pump result contract with an optional usage object
  (input/output/cache tokens if the pump session can obtain them); engine side parses
  and emits `claude_usage` telemetry when present; absent field = today's behavior.
  Bump the skill's `version:`. Document: a RUNNING pump predates the protocol — restart
  the pump session after this change (letter's rule).
- **DoD:** with a stub pump writing the field, telemetry shows usage events; without
  it, no errors; evals green.
- **Verify:** stub-pump test + `./scripts/automation/run-evals.sh`
- **Files:** `skills/goal-interactive-dispatch.md` (+ mirror + version),
  `scripts/automation/lib/interactive-dispatch.sh`,
  `scripts/automation/goal-await-dispatch.sh`, telemetry docs.
- **Rollback:** engine tolerates the field's absence by design; revert engine parse.
- **Stop-and-ask:** if the pump genuinely cannot access its own usage numbers, record
  that finding here and mark STALE — do not fake estimates.

### TOKEN-6 · Condensation helper for append-only state files
- **Priority:** P1 · **Effort:** M · **Risk:** LOW · **Status:** TODO
- **Problem:** maintenance protocol §4 mandates condensing knowledge files at ~200
  lines, but no mechanism exists (verified) — they grow until someone notices prompt
  bloat.
- **Current state:** manual-only. Files affected: `runs/.../state/lessons.md`,
  `assumptions.md` (NEED-5), `.claude/anti-patterns.md` (~287 lines — already over).
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
- **Priority:** P1 · **Effort:** M · **Risk:** MED · **Status:** TODO
- **Source:** Superpowers 6 release notes (primeradiant.com/blog/2026/superpowers-6.html):
  pre-generated diff packages cut review tokens + wall ≈10% on THEIR benchmark — treat
  as hypothesis here, measure per G8. Anchors verified 2026-07-07 @ `eb5c8f9`.
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
- **Priority:** P1 · **Effort:** M · **Risk:** LOW · **Status:** TODO
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
- **DoD:** runs clean on a healthy machine; each check individually testable
  (`--only <check>`); engine wiring warn-only; evals green.
- **Verify:** `bash scripts/automation/doctor.sh && bash -n
  scripts/automation/run-goal.sh && ./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/doctor.sh` (new), `scripts/automation/run-goal.sh`
  (1 call), README command table.
- **Rollback:** knob / remove call.

### REL-3 · Pump PID-liveness
- **Priority:** P1 · **Effort:** M · **Risk:** MED · **Status:** TODO *(absorbed known
  gap: letter "Known limitations", `letter-to-future-sessions.md:60-72`)*
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
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** TODO *(absorbed known
  gap: letter)*
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
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** TODO
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
- **Files:** `scripts/automation/goal-iter-lean.sh`, possibly
  `agents/browser-qa-agent/body.md` (+version, mirror).
- **Rollback:** remove retry block.

### REL-6 · Iteration-state synthesis
- **Priority:** P1 · **Effort:** M · **Risk:** MED · **Status:** TODO *(absorbed:
  README Pipeline-Hardening deferred item — it explicitly called this "where the weaker
  model degrades most")*
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
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** TODO
- **Source:** Superpowers 6 measured finding: test specifications + interface
  definitions carry implementation quality; implementation bodies in plans are
  marginal contributors. Anchors verified 2026-07-07 @ `eb5c8f9`.
- **Problem:** the decomposer's spec template is outcome-oriented, but its
  `## TESTING REQUIREMENTS` is three skeletal lines while `## IN SCOPE` invites
  implementation bullets — the spec's detail budget is weighted toward the part that
  matters least for downstream quality.
- **Current state:** the template lives inside `agents/goal-decomposer/body.md:37-110`;
  `## TESTING REQUIREMENTS` at `:101-105` ("Browser: <journeys>", "Unit/integration:
  <code paths>", "Error cases: <invalid inputs>"); `### Data-contract additions` at
  `:86-87` (canonical module + serving endpoint); pre-write self-check at `:184`. Spec
  consumers are prompt-readers only (`goal-iter-lean.sh:121/:152/:284/:414`) plus the
  J-ID regex `_spec_journeys()` (`goal-iter-lean.sh:299`) — additive spec content
  breaks no parser. `agent.yaml`: v1.2.1, `model_tier: strong`.
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

### DOC-5 · "Reading the reports" guide
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** TODO
- **Problem:** the chain produces MD summaries, HTML reports, demo galleries, a session
  index, gate reports — nothing tells the owner which one to open and what to look for.
- **Current state:** partial coverage spread across README sections + `runs/SCHEMA.md`
  (machine-oriented).
- **Change spec:** `docs/READING-REPORTS.md`: per artifact — what it is, who it's for
  (owner vs maintainer), when it appears, the 3 things to check (e.g. session index:
  journey matrix trend, latest verdict, assumptions section once NEED-6 lands).
  One screenshot-free page; link from README "Outputs" table and the session-index
  footer if the renderer has one.
- **DoD:** every report artifact in `runs/SCHEMA.md`'s human-facing set has an entry.
- **Verify:** cross-check list vs `runs/SCHEMA.md`; link greps.
- **Files:** `docs/READING-REPORTS.md` (new), README.
- **Rollback:** docs-only.

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
