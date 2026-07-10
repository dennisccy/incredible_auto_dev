# Model-Cutover Playbook (EVO-4)

This file: `docs/model-cutover-playbook.md` — cross-linked from
`.claude/letter-to-future-sessions.md` (deployment section) and
`.claude/maintenance-protocol.md` §6.

The strict ordered checklist for changing which Claude models this framework runs on.
Written 2026-07-11 for a maintainer session that does NOT have this repo's history in
its head: every step states its exact commands, the evidence that proves it worked, and
what failure means. Follow the steps IN ORDER. Do not improvise between them.

Run this from an **interactive session with the user reachable** — three steps below
are hard user checkpoints and cannot be answered by an unattended run.

---

## When to run this playbook

- Anthropic **ships or retires a model** that any tier in `config/model-tiers.yaml`
  uses or should use (roadmap EVO-1, source #6).
- A listed model id **starts erroring** on dispatch — the letter's "The model table
  rots" tripwire (`.claude/letter-to-future-sessions.md`). That symptom means run this
  playbook NOW.
- **Before retiring a tier**, and before ANY edit to `config/model-tiers.yaml` for any
  reason — that file is ask-the-user-first class (`.claude/maintenance-protocol.md` §1).

## Before you start

Required reading (short): `.claude/maintenance-protocol.md` §3 + §6 ·
`.claude/model-orchestration.md` §1 (the table you will update) ·
`docs/improvement-roadmap.md` §3 ground rules G1/G8/G9 and §9 "When to benchmark".

Preconditions: clean `git status`; `./scripts/automation/run-evals.sh` green before you
change anything; you know the candidate model id(s) exactly (typos here waste a
checkpoint).

### The three user checkpoints (unmissable)

| Where | What the user must approve | Class |
|---|---|---|
| Step 2 | The tier change itself (old id → new id, per tier) | Ask-first (G1; model spend) |
| Step 6 | Judgment-fixture run — the runner prints its own cost estimate | G9 spend gate |
| Step 7 | EACH benchmark run — ~$11 and ~1.5h+ wall per run at baseline scale | G9 spend gate (per run) |

Steps 1, 3, 4, 5, 8, 9 spend nothing beyond step 1's preflight cents (still tell the
user about those — no silent spend, however small).

---

## The checklist

### Step 1 — Preflight every candidate id  *(spend: cents — tell the user anyway)*

```bash
claude -p --model <candidate-id> 'reply OK'     # once per candidate id
```

- **Expected evidence:** each call returns a completion (any sane "OK"-ish reply) and
  exits 0.
- **Failure means:** the id is wrong or not available to this account. **Abort path:**
  STOP — never write an unverified id into `config/model-tiers.yaml`. Re-check the id
  with the user; a deprecation announcement is not evidence an id works here.

### Step 2 — USER CHECKPOINT 1: get approval, then flip `config/model-tiers.yaml`

Present to the user: which tier(s) change, old id → new id, and why (release /
retirement / cost). Only after an explicit yes:

```bash
$EDITOR config/model-tiers.yaml     # edit tiers.<tier>.claude — nothing else
```

- **Expected evidence:** `git diff config/model-tiers.yaml` shows ONLY the intended
  id line(s).
- **Rules:** this file is the ONE source of model ids. Never "cut over" by adding a
  per-agent `model_override` in `agents/*/agent.yaml` — that pin is only for commented
  temporary exceptions, and the evals fail on uncommented ones. Do not change any
  agent's `model_tier:` here either — moving an agent BETWEEN tiers is a separate
  spend-class experiment (see roadmap TOKEN-2), not a cutover.
- **Note (claude-only deployment):** the `codex:` column can stay untouched unless you
  are actually maintaining the Codex path (letter: `.codex/` is stale by choice; run
  `sync-cli-assets.py --cli codex` before any Codex use).

### Step 3 — Resync mirrors + drift check

```bash
python3 scripts/automation/sync-cli-assets.py --cli claude
python3 scripts/automation/sync-cli-assets.py --cli claude --check   # exit 0 = in sync
grep -h "^model:" .claude/agents/*.md | sort | uniq -c               # tier census
```

- **Expected evidence:** `--check` exits 0; the census shows ONLY the new id(s), with
  per-tier counts summing to the full agent catalog (no line with an old id remains).
- **Failure means:** mirrors drifted or the render didn't pick up the yaml. **Abort
  path:** do not proceed with stale mirrors — that is the §3 resync invariant breaking;
  re-run the sync and investigate before anything else.

### Step 4 — Update the table in `.claude/model-orchestration.md` (same commit)

Edit §1: the tier→model table rows AND the `claude -p --model …` example line, so the
doc a dispatcher reads matches the yaml the runtime resolves.

```bash
grep -n '<old-id>' .claude/model-orchestration.md    # expect: no hits
grep -rn '<old-id>' config/ agents/ .claude/agents/ scripts/ templates/   # expect: no hits
```

- **Expected evidence:** both greps come back empty. Historical records (`benchmarks/
  experiments.md`, `benchmarks/results/*.json`, roadmap archive, the letter's old
  deployment notes) legitimately keep old ids — they are history; NEVER rewrite them.
- **Commit boundary (protocol §6):** yaml + regenerated mirrors + this table land in
  ONE commit — but run step 5 first, then commit.

### Step 5 — Offline evals green, then commit steps 2–4

```bash
./scripts/automation/run-evals.sh    # expect: "Summary: N pass, 0 fail"
git add config/model-tiers.yaml .claude/agents/ .claude/model-orchestration.md   # + .codex/ only if you synced codex too
git commit -m "chore(models): cutover <tier>=<new-id> (tiers + mirrors + orchestration table)"
```

- **Expected evidence:** 0 fail; one commit containing the yaml, the rendered mirrors,
  and the orchestration table together.
- **Failure means:** a fixture caught real drift (often an uncommented `model_override`
  or a half-rendered mirror). **Abort path:** fix before committing; never commit a red
  suite (G3).

### Step 6 — USER CHECKPOINT 2 (G9): judgment fixtures (REL-1)

The eval suite checks parsers, not judgment. This step checks that the NEW judge
models still emit the right verdict classes on the frozen golden cases in
`tests/judgment/` (goal-evaluator, reviewer, auditor).

```bash
./scripts/automation/run-judgment-evals.sh          # prints plan + cost estimate, then refuses (exit 2)
# show the printed estimate to the user; only after an explicit yes:
./scripts/automation/run-judgment-evals.sh --yes-spend
# targeted re-run of a single judge/case if needed:
./scripts/automation/run-judgment-evals.sh --yes-spend --judge reviewer
```

- **Expected evidence:** the pass/fail table shows every case's verdict class correct
  (13 cases as of 2026-07: 5 evaluator, 4 reviewer, 4 auditor); exit 0.
- **Failure means:** the new model regresses on judgment — the single biggest cutover
  risk (silent judge regression mis-certifies whole sessions). **Abort path:** do NOT
  proceed to step 7. Either roll back (section below) or the user explicitly accepts
  the regression in writing. Never edit a fixture or tune a prompt "to make it pass".

### Step 7 — USER CHECKPOINT 3 (G9 per run): benchmark before AND after, then compare

Standing rule: roadmap §9 "When to benchmark". Each run costs real tokens
(baseline scale: ~$11, ~85 min wall; budget up to hours) and needs its own user
approval + its own PRE ledger entry — the runner enforces both refusals.

**Before-measurement:** the pre-cutover number can be an EXISTING results JSON whose
framework state matches pre-cutover main (as of writing:
`benchmarks/results/20260710-224206-c48f25047126.json`, the recorded baseline). If no
comparable pre-cutover result exists, run the benchmark ONCE **before** step 2's flip
— the runner stamps whatever sha the tree is on, and a dirty tree is refused.

```bash
# after the cutover commit (tree clean), with fresh user approval:
./scripts/automation/run-benchmark.sh \
  --hypothesis 'Post-cutover <tier>=<new-id>: journeys and cost hold vs baseline' \
  --predict 'journeys_passing_after>=<pre-run value>' \
  --yes-spend
# <pre-run value> = the "journeys_passing_after" number in the pre JSON's "outcome" block
# then:
python3 scripts/automation/lib/benchmark_compare.py \
  benchmarks/results/<pre>.json benchmarks/results/<post>.json
git add benchmarks/ && git commit -m "docs(bench): post-cutover benchmark run + ledger"
```

- **Expected evidence:** runner exits 0 with a results JSON + POST ledger entry;
  compare prints the delta table with verdict **OK** (exit 0).
- **Failure means:** compare exit 3 = **REGRESS** (wall or cost +>25%, or
  journeys-passing dropped) → do NOT proceed with the cutover without an explicit
  human decision; rollback is the default. Compare exit 4 = **UNKNOWN** (verdict
  inputs incomparable — the tool never guesses) → treat the same way: no proceed
  without the user. Whatever completed IS the measurement — a rerun for a prettier
  number needs fresh approval and a fresh PRE entry (§9).

### Step 8 — First-session watchlist  *(spend: none — observe the next real session)*

On the first real goal session after the cutover, check three things:

```bash
ls runs/goal-<sid>-iter-*/gate-report.md          # must appear on any GOAL_ACHIEVED
grep '\[escalation\]' runs/goal-session-<sid>/engine.log   # fix-retries name the NEW strong id
python3 scripts/automation/lib/analyze_telemetry.py runs/goal-session-<sid>/telemetry.jsonl
```

- **Expected evidence:** gate-report.md present for any GOAL_ACHIEVED (its absence is
  the letter's "a gate got disabled" degradation sign, cutover or not); `[escalation]`
  lines cite the new strong-tier id; the telemetry per-model rows show ONLY new ids,
  with per-agent wall in the same order as §9's typicals and per-agent cost in the same
  order as the recorded baseline's `by_agent` numbers (`benchmarks/results/`).
- **Failure means:** routing didn't actually cut over (check
  `CHAIN_DISABLE_MODEL_ROUTING` / stale mirrors) or the new model's economics are off →
  bring the numbers to the user; rollback stays on the table.

### Step 9 — Append a dated note to the letter's deployment section

One dated line in `.claude/letter-to-future-sessions.md` (deployment section): what
flipped, the commit sha, fixture/benchmark outcome, anything the next session should
watch. This is the provenance trail the next cutover session will look for first.

---

## Rollback (the mirror of steps 2–6)

Triggers: step 6 fixture failure, step 7 REGRESS/UNKNOWN, step 8 watchlist red — or
the user says so. Rollback is cheap BECAUSE steps 2–4 landed as one commit.

1. Tell the user you are rolling back and why (it restores the previously-approved
   state, so no new spend approval is needed for the flip itself).
2. `git revert <cutover-commit>` — or hand-restore the old ids in
   `config/model-tiers.yaml` if the revert won't apply cleanly.
3. Resync + check: `python3 scripts/automation/sync-cli-assets.py --cli claude` then
   `--cli claude --check` (exit 0); the step-3 census grep must show the OLD ids again.
4. Confirm `.claude/model-orchestration.md` §1 matches the yaml again (the revert
   normally covers it — verify with the step-4 greps against the reverted-away id).
5. `./scripts/automation/run-evals.sh` green.
6. Re-run the judgment fixtures (G9: estimate + user yes) to prove the restored judges
   still hit their golden verdicts: `./scripts/automation/run-judgment-evals.sh --yes-spend`.
7. Append a dated rollback note to the letter's deployment section (what was reverted,
   why, evidence). Never delete the failed attempt's ledger/results entries —
   `benchmarks/experiments.md` is append-only history.

---

## Cross-references

- Roadmap §9 "When to benchmark" — the standing benchmark rule this playbook's step 7
  instantiates (`docs/improvement-roadmap.md`).
- REL-1 judgment fixtures — cases in `tests/judgment/`, runner
  `scripts/automation/run-judgment-evals.sh` (its header documents every flag).
- `.claude/maintenance-protocol.md` §6 — the one-commit rule this playbook expands.
- `.claude/model-orchestration.md` §1 — the table step 4 updates; its "verify, never
  trust from memory" preflight is step 1.
- `.claude/letter-to-future-sessions.md` — "The model table rots" (the tripwire that
  triggers this playbook) and the deployment section (steps 9 / R7 write there).
