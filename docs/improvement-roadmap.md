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
6. **REL-2…9, SEC-1…4, QUAL-1, REP-1…3, DOC-3…7** — as capacity allows; SEC-4 pairs
   with SAFE-1; REL-8 must land before any real `CHAIN_AGENT_EFFORT` use; REL-9 is
   cheap — do it early.
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
- **Priority:** P0 · **Effort:** L (2 slices) · **Risk:** MED · **Status:** TODO
- **Problem:** every session generates evidence about what hurt (halts, quota pauses,
  review-FAIL loops, wall-time spikes, lessons) — and none of it flows back into
  framework improvements. The feedback loop is the evolution engine's core.
- **Current state:** terminal halts are decided in the verdict/halt switch
  (`run-goal.sh:1777-1919`); the showcase tail is the proven non-blocking pattern
  (forked for CONTINUE, inline for halts, `run-goal.sh:1601-1612` / `:1770-1775`);
  wall/token aggregation exists (`lib/analyze_telemetry.py`, `build_wall_report` ~`:273`,
  JSON output supported); lessons tail inlining exists (`:520-525`).
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
     `_run_iteration_summarizer` wrapper pattern, `run-goal.sh:244-277`) reading ONLY
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
- **Priority:** P0 · **Effort:** L (3 slices) · **Risk:** MED · **Status:** TODO
- **Problem:** "did my framework change help or hurt?" currently has no answer a weaker
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
- **Priority:** P0 · **Effort:** S · **Risk:** LOW · **Status:** TODO
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
  6. Run REL-1 judgment fixtures (mark "pending REL-1" until it ships).
  7. Run EVO-3 benchmark before/after (mark "pending EVO-3" until it ships).
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
- **Priority:** P0 · **Effort:** M · **Risk:** LOW · **Status:** TODO
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

### SPEED-1 · Refactor browser-qa into a function (no behavior change)
- **Priority:** P1 · **Effort:** S · **Risk:** LOW · **Status:** TODO
- **Problem:** the browser-qa section of the lean executor is a ~290-line inline block;
  SPEED-2 needs to run it in a forked subshell.
- **Current state:** `scripts/automation/goal-iter-lean.sh:292-578` (two-lane logic:
  deterministic golden replay lane `~:379-460`, LLM lane + merge `~:460-576`);
  resume-skip guard `~:309-321`.
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
- **Priority:** P1 · **Effort:** M · **Risk:** MED · **Status:** TODO
- **Problem:** reviewer (~21m) and browser-qa (~20m) both need only the post-dev tree
  yet run sequentially — the single biggest safe parallelism left in the lean path.
- **Current state:** sequence is developer → review-1 → (fix → review-2) → browser-qa
  (`goal-iter-lean.sh:142-250` review loop; `step_invalidate_from developer-fix` on
  FAIL at `~:217`). The coherence fork is the copyable pattern: fork `~:252-290`, join
  `~:580-602`, reap in `cleanup_iter_servers` `~:90-107`. Feasibility verified: the
  checkpoint canonical order (`lib/checkpoint.sh:40`) is an INVALIDATION order, not an
  execution order — `step_invalidate_from developer-fix` already cascades deletion of
  browser-qa/coherence/evaluator markers AND their registered artifacts
  (`checkpoint.sh:188-225`), so an early-forked browser-qa result is auto-invalidated
  on the FAIL path with zero checkpoint changes. Browser-qa writes land under `runs/`
  + `reports/`, which are excluded from the tree hash (`checkpoint.sh:35`). Reviewer
  only reads/diffs (`review_diff_hint`, `lib/common.sh:377-388`).
- **Change spec:**
  1. Knob `CHAIN_LEAN_PARALLEL_BROWSER_QA=off|replay|full`, default `off`.
  2. In `replay` mode: after `step_mark_done developer` (`~:187`), fork service boot +
     lane-1 deterministic replay ONLY (`demo_runner.py --mode verify` — pure python,
     cleanly killable in both backends, no pump involvement) in a subshell copying the
     coherence-fork pattern (isolate `CHAIN_CURRENT_AGENT`, rc-file, PID). Join after
     review settles; feed `REPLAY_FAILED` into the LLM lane's target set exactly as the
     sequential path does (`~:524`).
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
  attributes the fork correctly; evals green.
- **Verify:** `bash tests/automation/test-goal-parallel-bqa.sh &&
  bash tests/automation/test-goal-checkpoints.sh && ./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/goal-iter-lean.sh`,
  `tests/automation/test-goal-parallel-bqa.sh` (new), docs knob table.
- **Rollback:** knob default `off` — no rollback needed; delete the fork block if it
  misbehaves.
- **Stop-and-ask:** any evidence of a result file appearing AFTER its invalidation
  (stale artifact certifying nothing) = stop, that's the exact race this design guards.
- **Trigger:** ship after SPEED-1; measure with EVO-3 or one real session before/after.
- **Depends on:** SPEED-1.

### SPEED-3 · Parallel review ∥ browser-qa — stage "full" (headless only)
- **Priority:** P1 · **Effort:** M · **Risk:** MED · **Status:** TODO
- **Problem:** replay mode only parallelizes the deterministic lane; the LLM browser-qa
  dispatch (~most of the 20m) still waits for review.
- **Current state:** as SPEED-2. The interactive backend is EXCLUDED: killing the
  engine-side waiter leaves the pump's subagent running against a request nobody reads
  (stale `req.*`/`.res` files are only cleaned at engine start, `run-goal.sh:819`) —
  that cancellation gap is EXP-4's problem, not this item's.
- **Change spec:** in `full` mode AND `CHAIN_AGENT_BACKEND != interactive`: fork the
  whole `run_browser_qa_section` (LLM lane included); join handles rc 70 exactly like
  the coherence join (`goal-iter-lean.sh:588-591`); same kill-then-invalidate FAIL
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
- **Priority:** P1 · **Effort:** L (slice per judge) · **Risk:** LOW · **Status:** TODO
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
  (`lib/goal-gates.sh`) → `iter-<N>/scan-report.md`; CRITICAL blocks GOAL_ACHIEVED
  (`goal-gates.sh:79-146`).
- **Change spec:** new `scripts/automation/lib/security_scan.sh`: if `gitleaks` (or
  `trufflehog`) is on PATH — run it in diff mode per iteration (append findings to
  `scan-report.md` with the same CRITICAL semantics) and full-tree on GOAL_ACHIEVED
  before the two-key confirm; if absent — one WARN line ("gitleaks not installed —
  regex scan only") and proceed. Eval fixture: planted fake secret detected in a
  fixture diff (skip cleanly when tool absent so CI stays green).
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
