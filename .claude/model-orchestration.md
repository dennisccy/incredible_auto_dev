# Model Orchestration Rules

Read this when you dispatch work to other agents/models: the orchestrator, the goal-mode
pump (`/goal`), any interactive main-loop session in this repo, and humans tuning the chain.
Written 2026-07 for the post-Fable model set. Rules are mandatory unless the user overrides.

---

## 1. The model table — verify, never trust from memory

Model names rot. The table below was true when written; **at session start, if you are about
to dispatch by explicit model id, verify availability first**:

```bash
claude -p --model claude-opus-5 'reply OK'     # each id you plan to use
```

If a listed model errors, STOP using this table's ids and re-derive from
`config/model-tiers.yaml` (the runtime source of truth — agents' frontmatter is rendered
from it). Update this table in the same commit that changes the tier map.

| Tier | Claude model | Used for | Why |
|------|--------------|----------|-----|
| strong | `claude-opus-5` | goal-evaluator, auditor, goal-proposer, two-key confirms, escalated retries | Judgment: verdicts, scoping, skeptical audit. Mistakes here mis-certify or mis-direct whole sessions |
| standard | `claude-sonnet-5` | goal-decomposer (TOKEN-2 experiment 2026-07-15; effort stays max, D4 guard still covers it), developer, orchestrator, product-manager, reviewer, browser-qa, coherence-auditor, iteration-summarizer | Building and structured review. High volume — this tier dominates token spend. The summarizer deliberately STAYS here: REP-4 raised its concreteness bar, and it is the human's primary reading surface |
| light | `claude-haiku-4-5` | qa (procedural mode), release-manager, demo-narrator + readme-maintainer (TOKEN-9 experiment 2026-07-28: schema-constrained writers with deterministic safety nets — demo JSON is linted/executed by demo_runner.py, README edits are marker-scoped; revert per-agent on lint failures or AUTO-block corruption) | Fully proceduralized tasks with exact steps and output formats |

Effort: headless dispatches get `--effort` from `scripts/automation/lib/agent_permissions.py`
(`EFFORT_DEFAULT=max`). At `max`: goal-evaluator, goal-decomposer, auditor, goal-proposer,
reviewer, developer, orchestrator, product-manager, browser-qa-agent, coherence-auditor, and
the two-key confirm. At `medium` (structured/showcase): qa, release-manager,
ui-test-designer, ui-impact-analyst, phase-closure-auditor, iteration-summarizer,
readme-maintainer, demo-narrator, ux-regression-reviewer. Do not raise a medium agent to
"fix" quality — its work is procedural; and do not lower a max judge's effort to save tokens — lower the *context you feed it* instead
(see `.claude/workflow.md` and the digest tools in `scripts/automation/lib/goal_gate.py`).

Output style (STYLE-1, opt-in, default off): headless dispatches may also carry a Claude
Code output style, resolved by the wave-1 table in `lib/agent_permissions.py`
(`OUTPUT_STYLE_OVERRIDES`), armed by `CHAIN_OUTPUT_STYLES=true`. Wave 1 sets `Concise` on
developer, qa, browser-qa-agent, orchestrator, ui-impact-analyst, ux-regression-reviewer —
long, machine-consumed, non-judge steps. Judges (`JUDGE_AGENTS`) are refused by construction
(D4 — never lower a judge's effort/output to save tokens); `Learning` is refused outright
(it asks the human to write code, stalling headless runs); an unknown style name fails the
dispatch loudly instead of the CLI's silent fallback to default. The interactive backend has
no native style support for Agent-tool subagents, so a resolved style is emulated by
appending a prompt block instead (trace records `<name>(emulated)`); Codex ignores the whole
mechanism (no `--settings` equivalent). Every dispatch proves its effective style by reading
the stream-json `init` event back into the trace/telemetry sidecar; a requested-vs-effective
mismatch fires a loud `WARNING` and an `output_style_mismatch` telemetry event. The experiment
knobs (`CHAIN_OUTPUT_STYLES`, `CHAIN_AGENT_OUTPUT_STYLE`) act only in goal mode
(`GOAL_SESSION_DIR` set); the debug override (`CHAIN_OUTPUT_STYLE_OVERRIDE`) works in any
mode. See `docs/goal-mode-quickstart.md` to try it and `docs/improvement-roadmap.md` §16
CAND-STYLE for status.

## 2. The commander does not go into the field

The main conversation (orchestrator/pump/interactive session) exists to route work and hold
conclusions, not to do bulk work itself.

**Delegate** any of: reading more than ~3 files to answer one question; repo-wide scans;
batch edits across files; browser checks; anything whose raw output would exceed ~100 lines
in your context.

**Do NOT delegate**: a single-file edit you already understand; reading one known file;
decisions the user just made (re-deriving them wastes tokens and risks drift).

- ✚ Right: "Which endpoints serve factor data?" → dispatch one search agent, receive 5
  file:line conclusions.
- ✖ Wrong: main loop greps 40 files itself, pastes 300 lines of matches into its own context,
  then summarizes. The context is now polluted for the rest of the session.

## 3. The delegation package — every dispatch prompt has three parts

1. **Goal + motivation** — what to produce and *why it matters downstream* (one sentence of
   why prevents most wrong-direction work).
2. **Acceptance criteria** — binary, checkable statements. "Works correctly" is not a
   criterion; "`pytest tests/test_ingest_seed.py` exits 0 and the new row appears in
   `GET /api/factors`" is.
3. **Reporting format** — exactly what to return (see §4).

Ready-to-fill templates per task type live in `.claude/delegation-templates.md`.

## 4. Reporting contract

- Subagents return **conclusions + `file:line` references only**. Never raw file dumps.
- Output longer than ~50 lines goes to a **file**; the reply reports the path plus a ≤5-line
  summary.
- **Prompt file-indirection**: never inline a prompt >8KB into a dispatch. Write it to a
  scratch file and dispatch: *"Read <path> IN FULL (paginate past any truncation) and follow
  it verbatim."* Delivery stays byte-exact and the dispatcher's context stays lean. (Proven
  in goal-session mcp-loop iter-16: inlining 50KB prompts caused pump-context summarization
  that lost loop state.)

## 5. Upgrade / downgrade paths

Escalation exists because retrying the same model on the same failure is the single most
common token waste in agent chains.

- **Light model errs once** on a task → re-dispatch one tier up, with the failure output
  included inline. Do not retry light twice.
- **Mid-tier fails the same subtask twice** → escalate to strong with the **complete failure
  trace** (the actual reports/diffs/test output — not your summary of them).
- **Retry the same thing at most 2 rounds total.** A third identical attempt is evidence the
  approach is wrong, not that the dice are unlucky → change approach or escalate
  (see `.claude/judgment-rubrics.md` §4 wrong-direction signals).
- **Downgrade after the pattern is solved**: once strong has produced one correct instance of
  a repetitive change, batch-apply the remaining instances with a cheaper model, giving it
  the solved instance as the worked example.
- Mechanics: the goal/phase pipelines do this automatically for developer fix-retries
  (`CHAIN_MODEL_ESCALATION=true` bumps attempt ≥2 to the strong tier). For ad-hoc dispatches,
  set the model explicitly per the table.

- ✚ Right: haiku release-manager mangles a rebase → rerun once on sonnet with the error
  inline; done.
- ✖ Wrong: sonnet developer fails the same failing test twice; dispatcher tries sonnet a
  third time with the same prompt "but more carefully". (Correct: strong tier, full failure
  trace, or change the approach.)

## 6. Verification is never self-verification

An agent's claim about its own work is a hypothesis, not evidence.

- **Acceptance review** goes to a **fresh-context agent** (the chain's reviewer/qa/auditor
  stages exist for this; don't skip them to save a dispatch).
- **Files**: verify by **read-back** (open the file; confirm content, not just existence).
- **Code**: verify by **tests or actual execution** — a passing targeted test or a real HTTP
  call, not "the code looks right".
- **High-risk judgments** (ship/no-ship, destructive migrations, "goal achieved"): get a
  **second opinion** — an independent agent with adversarial framing ("find a reason this is
  NOT done"). The goal pipeline's two-key GOAL_ACHIEVED confirm is this rule in code; imitate
  it for anything comparably irreversible.

## 7. Environment knobs

| Variable | Effect | Defined in (scripts/automation/…) |
|----------|--------|-----------------------------------|
| `CHAIN_MODEL_OVERRIDE` | Force the next dispatch(es) onto a specific model id (both backends) | `lib/quota-retry.sh` |
| `CHAIN_EFFORT_OVERRIDE` | Force effort for the next dispatch(es) (headless) | `lib/quota-retry.sh` |
| `CHAIN_MODEL_ESCALATION` | default `true`; dev fix-retries run on the strong tier | `lib/common.sh` |
| `CHAIN_DISABLE_MODEL_ROUTING` | `true` → headless stops passing `--model` (ambient default) | `lib/quota-retry.sh` |
| `CHAIN_GOAL_GATES` | default `true`; deterministic verdict gates | `lib/goal-gates.sh` |
| `CHAIN_GOAL_CONFIRM` | default `true`; the two-key GOAL_ACHIEVED confirm pass | `lib/goal-gates.sh` |
| `CHAIN_SCAN_STRICT_DEPS` | `true` → new paid-SaaS dependencies become CRITICAL (block certification); default warn | `lib/scan_diff.py` |
| `CHAIN_SCAN_DEP_ALLOWLIST` | package names (space/comma) never classified as paid-SaaS | `lib/scan_diff.py` |
| `CHAIN_SCAN_BOOKKEEPING_EXCLUDES` | space-separated path prefixes excluded from the gate's scanned diff (default `runs reports docs/handoffs docs/phases` — the harness's own generated output; the scanner reads product changes only) | `lib/goal-gates.sh` |
| `CHAIN_DISABLE_EFFORT_OVERRIDE` | `true` → everyone back to `--effort max` | `lib/quota-retry.sh` |
| `CHAIN_STEP_CHECKPOINTS` | default `true`; step-level resume markers — a stall/quota kill never redoes a completed developer/reviewer/browser-qa step | `lib/checkpoint.sh` |
| `CHAIN_AGENT_TIMEOUTS` | default `true`; per-agent runtime caps (~2.5-3× measured typicals) instead of one flat 7200s | `lib/quota-retry.sh` |
| `CHAIN_TIMEOUT_<AGENT>` | per-agent cap override in seconds (e.g. `CHAIN_TIMEOUT_REVIEWER=5400`); wins over yaml/table | `lib/quota-retry.sh` |
| `CHAIN_CLAUDE_TIMEOUT_RETRIES` | default `1`; in-place retries after a headless runtime-cap kill | `lib/quota-retry.sh` |
| `CHAIN_DISPATCH_REQUEUE_ON_TIMEOUT` | default `true`; one requeue after an interactive inflight timeout before pausing | `lib/interactive-dispatch.sh` |
| `CHAIN_LEAN_PARALLEL_COHERENCE` | default `true`; lean iterations run the coherence audit concurrently with browser-qa | `goal-iter-lean.sh` |
| `CHAIN_LEAN_PARALLEL_BROWSER_QA` | default `off` (SPEED-2 experiment — G4: no default flip with the knob); `replay` forks the browser-qa service boot + deterministic replay lane right after the developer step so it overlaps the ~21-min review, joined once review settles; a review-1 FAIL kills the fork and discards its lane files BEFORE any step invalidation; tripwire: attempt-1 review FAILs in ≥2 of the last 3 iterations persist `runs/goal-session-<sid>/state/parallel-bqa-disabled` (fork off for the rest of the session); `full` (SPEED-3) forks the WHOLE browser-qa section (LLM lane included) on HEADLESS backends only — the join re-raises an in-fork transport exit (70) as the usual resumable pause, and a review-1 FAIL kills the fork tree (in-flight dispatch included) then logs a `parallel_bqa_wasted_dispatch` cost event; on the interactive backend `full` demotes to `replay` with a warning (the cancellation gap is EXP-4's); the tripwire covers both stages | `goal-iter-lean.sh` |
| `CHAIN_ASYNC_SHOWCASE` | default `true`; demo/summary/README/renders run in the background overlapping the next decomposer (CONTINUE/ESCALATE only; joined + committed before the next executor dispatch) | `run-goal.sh` |
| `CHAIN_SESSION_RETRO` | default `true`; terminal halts (GOAL_ACHIEVED/STALLED/REGRESSION_HALT/BUDGET_EXHAUSTED) freeze a deterministic evidence snapshot to `state/retro-input.md` AND then dispatch the retro-analyst (light tier) to draft `reports/goal-session-<sid>-retro.md` improvement proposals from it (EVO-2); the drafting dispatch is skipped when the digest is missing; resumable pauses never fire either step; non-blocking — set `false` to disable both | `run-goal.sh`, `lib/retro_collect.sh` |
| `CHAIN_REQUIRE_FULL_DEPTH` | default off (unset), **operator-set only**; truthy makes full depth a HARD requirement for a spec that already asks for it — it PREVENTS demotion (the arbiter resolves such an iteration to full ahead of every cost rung, recording the rung it overrode as `depth_cost_overridden`; the legacy-allowlist path pauses instead of demoting), and where full still cannot be dispatched the engine pauses `AWAITING_FULL_DEPTH` BEFORE dispatch instead of running lean. It never PROMOTES a lean/evidence spec — write `Depth: full` in the spec to require full. Per-iteration form: a `Depth enforcement: required` spec line — the decomposer is forbidden to emit it (anti-pattern 25) | `lib/common.sh`, `run-goal.sh`, `goal-iter-lean.sh` |
| `CHAIN_MAINTENANCE_ISOLATION` | default off (unset), **operator-set only**; truthy (`true`/`1`/`yes`/`on`/`required`) keeps full reviewer/QA/auditor/coherence/evaluator depth while FORBIDDING application-service boot, browser QA, the deterministic replay lane and the demo showcase. Every chokepoint refuses fail-closed (`maintenance_isolation_refuse` → refusals marker + `maintenance_isolation_refused` event); `apply_maintenance_isolation_from_spec` materializes the spec form into the environment before any child dispatch and stamps `CHAIN_MAINTENANCE_ISOLATION_SOURCE=spec\|env`. Per-iteration form: a `Maintenance isolation: required` spec line (decomposer forbidden) | `lib/common.sh`, `run-goal.sh`, `run-phase.sh`, `qa-phase.sh`, `browser-qa-phase.sh`, `demo-phase.sh`, `lib/replay-lane.sh`, `lib/closure_gate.py` |
| `CHAIN_AGENT_EFFORT` | opt-in experiment, e.g. `developer=high`; **judges are refused by a hardcoded guard**; auto-reverted by the telemetry tripwire on quality movement | `lib/agent_permissions.py` |
| `CHAIN_OUTPUT_STYLES` | default `false`; `true` arms the wave-1 table in `lib/agent_permissions.py` (`OUTPUT_STYLE_OVERRIDES`) — goal mode only | `lib/agent_permissions.py`, `lib/quota-retry.sh`, `lib/interactive-dispatch.sh` |
| `CHAIN_AGENT_OUTPUT_STYLE` | per-agent experiment map, e.g. `developer=Concise,qa=Concise` (same grammar as `CHAIN_AGENT_EFFORT`); judges refused | `lib/agent_permissions.py`, `lib/quota-retry.sh`, `lib/interactive-dispatch.sh` |
| `CHAIN_OUTPUT_STYLE_OVERRIDE` | debug: forces one style on every agent incl. judges (loud NOTICE); wins over all; works in any mode | `lib/agent_permissions.py`, `lib/quota-retry.sh`, `lib/interactive-dispatch.sh` |
| `CHAIN_DOCTOR` | default `true`; run-goal.sh prints the REL-2 preflight doctor table (PASS/WARN/FAIL environment truth) at engine start, WARN-ONLY BY CONSTRUCTION — crash/nonzero/hang all degrade to a log line and the session proceeds; gating exists only as the doctor CLI's own `--strict-doctor` flag (exit 1 on ≥1 FAIL; the engine never passes it) | `run-goal.sh`, `doctor.sh` |

If you disable a gate/routing knob for an experiment, **re-enable it in the same session**
and say so in your report — a silently disabled gate is the #1 way this system degrades
(see `.claude/letter-to-future-sessions.md`).
