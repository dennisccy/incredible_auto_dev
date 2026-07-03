# Model Orchestration Rules

Read this when you dispatch work to other agents/models: the orchestrator, the goal-mode
pump (`/goal`), any interactive main-loop session in this repo, and humans tuning the chain.
Written 2026-07 for the post-Fable model set. Rules are mandatory unless the user overrides.

---

## 1. The model table — verify, never trust from memory

Model names rot. The table below was true when written; **at session start, if you are about
to dispatch by explicit model id, verify availability first**:

```bash
claude -p --model claude-opus-4-8 'reply OK'     # each id you plan to use
```

If a listed model errors, STOP using this table's ids and re-derive from
`config/model-tiers.yaml` (the runtime source of truth — agents' frontmatter is rendered
from it). Update this table in the same commit that changes the tier map.

| Tier | Claude model | Used for | Why |
|------|--------------|----------|-----|
| strong | `claude-opus-4-8` | goal-evaluator, goal-decomposer, auditor, goal-proposer, two-key confirms, escalated retries | Judgment: verdicts, scoping, skeptical audit. Mistakes here mis-certify or mis-direct whole sessions |
| standard | `claude-sonnet-5` | developer, orchestrator, product-manager, reviewer, browser-qa, coherence-auditor, all showcase agents | Building and structured review. High volume — this tier dominates token spend |
| light | `claude-haiku-4-5` | qa (procedural mode), release-manager | Fully proceduralized tasks with exact steps and output formats |

Effort: headless dispatches get `--effort` from `scripts/automation/lib/agent_permissions.py`
(`EFFORT_DEFAULT=max`). At `max`: goal-evaluator, goal-decomposer, auditor, goal-proposer,
reviewer, developer, orchestrator, product-manager, browser-qa-agent, coherence-auditor, and
the two-key confirm. At `medium` (structured/showcase): qa, release-manager,
ui-test-designer, ui-impact-analyst, phase-closure-auditor, iteration-summarizer,
readme-maintainer, demo-narrator, ux-regression-reviewer. Do not raise a medium agent to
"fix" quality — its work is procedural; and do not lower a max judge's effort to save tokens — lower the *context you feed it* instead
(see `.claude/workflow.md` and the digest tools in `scripts/automation/lib/goal_gate.py`).

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
| `CHAIN_DISABLE_EFFORT_OVERRIDE` | `true` → everyone back to `--effort max` | `lib/quota-retry.sh` |

If you disable a gate/routing knob for an experiment, **re-enable it in the same session**
and say so in your report — a silently disabled gate is the #1 way this system degrades
(see `.claude/letter-to-future-sessions.md`).
