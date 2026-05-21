# Goal Mode — Architecture

Goal mode is a parallel pipeline alongside phase mode. Where phase mode executes one human-authored phase spec at a time, goal mode iterates `decompose → execute → evaluate` against a persistent project goal until the goal-evaluator declares the goal achieved or a hard halt fires.

This document describes how goal mode works internally. For user-facing usage, see [`docs/goal-mode-quickstart.md`](../../docs/goal-mode-quickstart.md). For the high-level mode comparison, see [`system-overview.md`](system-overview.md).

## Why a separate mode

Phase mode requires a human to author N phase specs up front. That works for projects with a clear, decomposed roadmap. It does not work for "I want a working todo app with auth" — the human shouldn't have to translate that goal into seven phases of click-by-click work.

Goal mode closes that gap. The user authors `docs/goal.md` with:
- The same fields phase mode reads (Vision, Target Users, Success Criteria, etc.)
- Two additional sections required by goal mode: **Must-have user journeys** and **Anti-goals**

Then `./scripts/automation/run-goal.sh` takes over: it generates iteration specs, executes them, evaluates progress, and loops until done.

## Components

```
run-goal.sh         outer loop, halt logic, quota auto-resume, telemetry capture
goal-iter-lean.sh   single lean iteration: developer → reviewer → browser-qa
run-phase.sh        existing 11-step pipeline (used unchanged for full iterations,
                    invoked with --no-finalize so release runs only at session end)

.claude/agents/goal-decomposer.md   reads goal + state, writes next iter spec; drafts the blueprint at baseline
.claude/agents/goal-evaluator.md    reads iter outputs + history + coherence, emits verdict
.claude/agents/coherence-auditor.md audits the iter diff vs state/blueprint.md (IA + data contract)

scripts/automation/lib/telemetry.sh  records structured JSONL events
config/agent-models.yaml             three goal-mode entries (goal-decomposer, goal-evaluator → strong; coherence-auditor → standard)
```

All other agents (developer, reviewer, qa, auditor, browser-qa-agent, ui-impact-analyst, ui-test-designer, ux-regression-reviewer, phase-closure-auditor, release-manager, orchestrator, product-manager) and all skills are reused unchanged.

## Data flow per iteration

```
                          docs/goal.md
                                │
                                ▼
                       goal-decomposer
                                │
                                ▼
                docs/phases/goal-<sid>-iter-<N>.md
                                │
            ┌───────────────────┴────────────────────┐
            ▼                                        ▼
   depth: lean                               depth: full
   goal-iter-lean.sh                         run-phase.sh --no-finalize
   developer→reviewer→browser-qa             (full 11-step pipeline)
            │                                        │
            └───────────────────┬────────────────────┘
                                ▼
                       coherence-auditor   (reads state/blueprint.md;
                                │            writes iter-<N>/coherence.md)
                                ▼
                          goal-evaluator
                                │
                                ▼
                  runs/goal-session-<sid>/iter-<N>/eval.md
                  + updated state/journey-history.json
                  + appended state/evaluator-log.md
                  + (optional) appended state/lessons.md when there is a non-obvious takeaway
```

The synthetic phase name `goal-<sid>-iter-<N>` (where `<sid>` is the session id and `<N>` is the iteration index) is used wherever existing scripts and agents expect a "phase" name. This means agents, skills, and `run-phase.sh` consume goal-mode artifacts without modification — the file naming convention does the routing.

## Halt conditions

The outer loop checks halts in this order, each iteration, before invoking the decomposer:

1. **`BUDGET_EXHAUSTED`** — `current_iter >= max_iterations` (default 30, override with `--max-iter`)
2. **`STALLED`** — last `stall_window` (default 3) journey-history hashes are identical, meaning no journey newly passed/failed/regressed
3. **`REGRESSION_HALT`** — prior iteration's evaluator emitted `REGRESSION` and the user has not passed `--acknowledge-regression`

After the evaluator runs, the verdict directly drives the loop:

| Evaluator verdict | Loop behavior |
|---|---|
| `GOAL_ACHIEVED` | Halt with success; optionally invoke release-manager (with `--auto-release`) |
| `CONTINUE` | Loop with evaluator's recommended depth |
| `ESCALATE` | Loop; next iteration MUST run as full |
| `REGRESSION` | Halt with `REGRESSION_HALT` |
| `STALLED` | Halt with `STALLED` (evaluator-driven, separate from hash-based detection above) |

**Quota exhaustion is NOT a halt.** The wrapped `claude_with_quota_retry` library transparently sleeps until the quota resets, then resumes the same agent invocation. Telemetry records the quota pause for observability.

**Blueprint approval pause.** At the top of the loop, before the first building iteration (and again only when the decomposer flags a *structural* blueprint change via `state/blueprint.reapproval-requested`), the loop sets `session.json.status = AWAITING_BLUEPRINT_APPROVAL` and exits 0 so the human can review `state/blueprint.md`. `--resume` continues (resuming counts as approval and creates `state/blueprint.approved`); `--auto-approve-blueprint` skips the pause. This is the one human checkpoint in an otherwise unattended run. The gate sits at the top of the loop precisely so the baseline-drafted blueprint is never re-drafted out from under the human.

**Coherence veto.** The `coherence-auditor` runs after dispatch and writes `iter-<N>/coherence.md` with `COHERENCE-PASS | COHERENCE-WARN | COHERENCE-FAIL`. It hard-fails only on objective rules — a Data-Contract value recomputed/served via a new path, or a new feature with no nav path / a duplicate home. The goal-evaluator treats `COHERENCE-FAIL` as a structural veto: it will not emit `GOAL_ACHIEVED` while coherence is failing, and instead emits `CONTINUE` driving a consolidation iteration. Repeated coherence failures fall through to the existing `STALLED`/`ESCALATE` paths, so the gate cannot loop forever. An auditor that produces no output is treated as a non-blocking PASS.

## State

```
runs/goal-session-<sid>/
├── session.json                # halt config, current iter, status, last verdict, next depth
├── telemetry.jsonl             # structured event log (see docs/goal-mode-telemetry.md)
├── state/
│   ├── journey-history.json    # per-journey status, anti-goal violations, timestamps
│   ├── evaluator-log.md        # append-only chronicle of evaluator decisions
│   ├── lessons.md              # append-only ledger of non-obvious takeaways; goal-decomposer reads before planning
│   ├── blueprint.md            # coherence contract: information architecture + data contract (drafted at baseline, human-approved, enforced each iter)
│   ├── blueprint.approved      # marker: human approved the blueprint (created on first --resume, or by --auto-approve-blueprint)
│   └── blueprint.reapproval-requested  # transient: decomposer flagged a structural change → triggers a re-approval pause
├── iter-0/eval.md              # baseline evaluation (no coherence.md — no code yet)
├── iter-1/eval.md + coherence.md   # first dev iteration: evaluation + coherence audit
├── iter-N/eval.md + coherence.md   # ...
├── .history-hashes             # one journey-history hash per line (stall detection)
└── summary.md                  # written when the loop halts
```

Per-iteration code/test artifacts use the `goal-<sid>-iter-<N>` prefix and live under the existing `runs/<iter-name>/` and `reports/` paths so existing agents need no path changes.

## Resume semantics

`run-goal.sh --resume --session-id <id>` reads `session.json` and continues from `current_iter`. If a prior run died mid-iteration, that iteration is rerun from scratch — every iteration is idempotent (a new spec is written, dev/review/QA/browser-qa overwrite their own artifacts).

If the prior status is `REGRESSION_HALT`, resume requires `--acknowledge-regression` so the user must explicitly take responsibility for proceeding past a known regression.

## Per-iteration push (default ON)

`run-goal.sh` populates a single per-session feature branch (default `goal/<sid>`, override with `--push-branch <name>`) with one commit per successful iteration. The push is direct shell `git` — no model invocation, no agent, no token cost. **Default ON** for new sessions; pass `--no-push-per-iter` to opt out.

**Resolution table** (applied on every invocation):

| `PUSH_FLAG_USER` | `session.json push_per_iter` | Effective value |
|---|---|---|
| `--no-push-per-iter` | any | OFF for this run (logs a warning if the session was previously on) |
| `--push-per-iter` | `true` | `continuing` |
| `--push-per-iter` | `false` / missing | `opting-in` |
| (default, no flag) | `true` | `continuing` |
| (default, no flag) | `false` (explicit) | OFF (respect prior explicit choice) |
| (default, no flag) | missing (pre-feature session) | `opting-in` (adopt the new default) |

**Branch lifecycle:**

- **New session with push enabled (the default):** creates `<push_branch>` (default `goal/<sid>`) from current HEAD, switches to it. Errors if the branch already exists.
- **New session with `--no-push-per-iter`:** no branch is created; iter commits stay local.
- **Resume of a session that was already pushing** (`session.json` has `push_per_iter: true`): reads the session's recorded `push_branch`, switches to it. Errors if the branch has been deleted locally — that's a real anomaly and the script refuses to silently recover.
- **Resume + `--push-per-iter` opting in mid-session:** the branch is created from current HEAD if missing, or joined if it already exists. Iter commits accumulate from this point forward — prior iters' code stays on whatever branch the session was previously running against.
- **Resume + `--no-push-per-iter` mid-session opt-out:** push is disabled for this run; the session's persisted value is also flipped to `false` so subsequent resumes-without-flag respect it.
- **Resume of a pre-feature session** (`push_per_iter` key never written): adopts the default-on; the script logs a one-line note and tells the user how to opt out.

`session.json` carries two fields: `push_per_iter` (bool) and `push_branch` (string), persisted on every resume so the chosen state survives.

**Per-iter behaviour (after the evaluator returns a verdict):**

| Verdict | Push action |
|---|---|
| `CONTINUE`, `ESCALATE`, `GOAL_ACHIEVED` | `git add -A`, commit with auto-generated message (verdict + journey deltas), `git push -u origin HEAD`. Skipped silently if working tree has no changes. |
| `REGRESSION`, `STALLED` | Skipped — the branch is left at the previous iter's HEAD so the user can inspect partial state without remote noise. |
| Any failure (commit conflict, push rejected, network) | Logged as `[run-goal] push-per-iter: WARNING ...`, recorded as `iter_push` telemetry event with `success: false`. Does not halt the loop. |

**PR creation:** unchanged. The branch accumulates commits; the existing `--auto-release` flow (or a manual `gh pr create`) opens the PR at the end. The `summary.md` written at session halt includes a ready-to-paste `gh pr create` command when `push_per_iter` is on.

The commit message format:

```
goal(<sid>): iter <N> — <VERDICT> (passing+X failing+Y regressed+Z)

Target journeys: J-XX, J-YY
Verdict: <VERDICT>
Newly passing: X
Newly failing: Y
Regressed: Z
Anti-goal violations: W
Iter spec: docs/phases/goal-<sid>-iter-<N>.md
Iter eval: runs/goal-session-<sid>/iter-<N>/eval.md
```

## Backward compatibility

Phase mode is unchanged. The only modification to phase-mode code is the additive `--no-finalize` flag on `run-phase.sh` — when not passed (the default), every existing phase-mode invocation behaves identically.

`docs/phases/` may now contain synthetic specs named `goal-<sid>-iter-<N>.md` alongside real phase specs. Phase mode scripts only consume names they're explicitly given on the command line, so collisions are not possible unless a user manually invokes `run-phase.sh goal-<sid>-iter-<N>`.

## Self-evolution (future)

Telemetry capture is a foundation for a future "self-evolution" loop where this framework reads accumulated telemetry from downstream projects and proposes its own improvements as PRs. That loop is explicitly NOT part of goal mode today — see `feedback/README.md` for the placeholder.

## See also

- [`docs/goal-mode-quickstart.md`](../../docs/goal-mode-quickstart.md) — user guide
- [`docs/goal-mode-telemetry.md`](../../docs/goal-mode-telemetry.md) — telemetry schema
- [`agents.md`](agents.md) — full agent inventory
- [`pipeline.md`](pipeline.md) — phase-mode pipeline (the "full" inner pipeline of goal mode)
- [`.claude/anti-patterns.md`](../anti-patterns.md) — anti-pattern #18 covers goal-mode authoring
