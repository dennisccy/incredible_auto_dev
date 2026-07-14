# Goal Mode — Interactive Dispatch (Pump Protocol)

This skill defines how the foreground Claude Code session (the "pump") runs the
existing goal-mode engine so that every agent executes as an interactive
subagent — billed to the interactive plan allowance — instead of a headless
`claude -p` subprocess. The `/goal`, `/goal-resume`, and `/goal-step` commands
all follow this protocol. The engine's loop, stop rules, resume, and state are
unchanged; only the model invocation is redirected through a file channel
(`scripts/automation/lib/interactive-dispatch.sh`).

## When this runs

You are the pump when a `/goal*` command launched `run-goal.sh --interactive`.
You stay in the loop below until the engine process exits. Keep the session open
for the whole run; if it closes, the run pauses and `/goal-resume` continues it.

## Pump output discipline (run quietly)

You are plumbing, not a narrator. During the loop, reply with **tool calls only** —
do NOT emit chat for: awaiting requests, which agent you are dispatching, prompt
contents, a subagent's returned text, or writing `.res` files. Dispatch silently
and write results silently.

Emit prose ONLY at these moments:
- once at launch: the engine-log pointer line (see Launch step 4),
- when the engine exits: the final status block (see "When the engine exits"),
- at a pause that needs the user (blueprint approval, GitHub auth, regression).

Never echo or summarize a subagent's returned message — its real output is already
in the artifact files, and the full chain narrative is in the timestamped engine
log. Repeating it just burns the user's tokens. On a `WAITING` result, silently
re-call the await helper.

## Launch

1. Resolve the session id from the command argument, or generate one and state it.
2. Start the engine in the background (Bash with run_in_background), and capture
   its process id:
   `./scripts/automation/run-goal.sh --session-id <sid> --interactive <passthrough flags>`
   The engine creates and exports `CHAIN_DISPATCH_DIR=runs/goal-session-<sid>/dispatch`.
   The engine also tees its full, timestamped, headless-style log to
   `runs/goal-session-<sid>/engine.log` — you never read it; it is for the user.
3. Record the dispatch dir path and the engine pid for the loop.
4. Print exactly one pointer line for the user, then go quiet:
   `Engine running. Full chain log (headless-style, timestamped): tail -f runs/goal-session-<sid>/engine.log`

## The pump loop

Repeat until the engine exits. Run it QUIETLY per "Pump output discipline" — tool
calls only, no narration.

1. Run, in the **foreground** (one blocking Bash call, NOT a background job; set a
   Bash command timeout of ~540000 ms):
   `scripts/automation/goal-await-dispatch.sh --dispatch-dir <dir> --engine-pid <pid> --max-wait 500`
   It blocks until there is work, then prints exactly one of:
   - one or more request file paths → go to step 2;
   - `WAITING` → no work yet, engine still alive → silently re-run this same call
     (do not narrate, do not poll anything else);
   - `ENGINE_DONE` → the engine exited → leave the loop.
   It refreshes the pump heartbeat every second while it blocks, so a ≤500 s wait
   never trips `CHAIN_PUMP_HEARTBEAT_TIMEOUT`. `--max-wait` hands control back
   periodically so you make ONE clean blocking call per cycle instead of polling a
   background job (which is what caused the "updates very frequently" churn).
2. For each returned request path, read the request file. It is JSON with the
   fields `agent`, `prompt`, `cwd`, `res_path`, and `out`, plus an optional
   `model`. (Older engines may omit `out`/`model` — both are optional.)
3. Dispatch every returned request together: issue one Agent tool call per
   request in a single message, with `subagent_type` set to the request's
   `agent` and the request's `prompt` passed verbatim.
   - **Model:** if the request has a non-empty `model` field, pass it as the
     Agent tool's model parameter (the engine uses this for escalation retries
     and confirm passes). Otherwise pass no model override — the subagent runs
     on its own `.claude/agents/<agent>.md` model tier.
   - **Large prompts:** if the prompt exceeds ~8 KB, do NOT inline it into the
     Agent call (inlining giant prompts bloats your context and gets lost when
     the session summarizes). Instead write the prompt verbatim to
     `<dispatch-dir>/prompt-<request-basename>.md` with the Write tool, and
     dispatch with this exact wrapper as the subagent prompt:
     `Read <that path> IN FULL (paginate past any truncation if it is long) and follow its contents verbatim as your task instructions.`
     Delete that prompt file after you write the request's `.res`.
4. After each subagent returns: first write the subagent's final message
   VERBATIM to the request's `out` path (Write tool; skip if the request has no
   `out` field) — the engine captures it into the session trace for
   measurement. THEN write its exit code (0 on success, a non-zero number if it
   clearly failed) to that request's `res_path`, which equals the request path
   with `.ready` replaced by `.res`. The `.res` write is the completion signal,
   so it must come last.
5. Loop back to step 1, silently. When step 1 prints `ENGINE_DONE`, leave the loop.

## Mapping a request to a subagent

The `agent` field is one of the goal-mode agent names, which match the
`.claude/agents/<name>.md` filenames exactly: developer, reviewer, qa,
browser-qa-agent, goal-decomposer, coherence-auditor, goal-evaluator,
iteration-summarizer, readme-maintainer, goal-proposer, orchestrator, auditor, ui-impact-analyst,
ui-test-designer, ux-regression-reviewer, phase-closure-auditor, demo-narrator,
release-manager, product-manager. Use that name as `subagent_type`.

The prompt body always names its own instructions file as
`.claude/agents/<name>.md` (e.g. "Agent instructions: .claude/agents/goal-decomposer.md").
That line is the source of truth: if the `agent` field disagrees with the agent
the body identifies — even when `agent` is itself a valid name — dispatch as the
agent named in the body, not the `agent` field. (This should be rare; it means the
engine mislabeled the request, but the body is what actually defines the work.)

Fallback: if `agent` is `unattributed` or has no matching agent file, read the
prompt for that `.claude/agents/<name>.md` line and use that name. If none can be
found, dispatch with the `general-purpose` subagent.

## Concurrency

The engine's post-dev fanout runs up to two agents at once, so more than one
request can be ready in a single cycle. Always dispatch the full set returned by
one `goal-await-dispatch.sh` call together (multiple Agent calls in one message),
then write all of their `.res` files. Request file names are unique, so two
concurrent requests never collide.

## Heartbeat & in-flight claims

`goal-await-dispatch.sh` refreshes `<dir>/.pump-alive` while it waits, and — the
moment it hands a request to you — marks that request claimed by touching
`<req>.started`. The engine then uses two tiers, so a legitimately long agent is
never mistaken for a dead pump:

- **Not yet claimed** (no `.started`): if `.pump-alive` goes stale beyond
  `CHAIN_PUMP_HEARTBEAT_TIMEOUT`, the pump never picked the request up — the engine
  stops cleanly, leaving an `.awaiting-pump` marker.
- **Claimed** (`.started` present): the subagent is running; it is bounded only by
  `CHAIN_DISPATCH_INFLIGHT_TIMEOUT` (default 2h), NOT the idle heartbeat — so a
  30+ minute INITIAL BUILD does not trip a false "pump stale" abort.

Either way, a genuine pump loss pauses the session as `AWAITING_PUMP` (resumable)
rather than hanging. You do not manage these markers — `goal-await-dispatch.sh`
and the engine do.

## When the engine exits

Read `runs/goal-session-<sid>/session.json` and report its `status` field, which
is authoritative:

- `GOAL_ACHIEVED` — the goal is done; point to the session summary and the delivered wrap.
- `AWAITING_BLUEPRINT_APPROVAL` — ask the user to review `state/blueprint.md`, then `/goal-resume`.
- `AWAITING_GITHUB_AUTH` — ask the user to run `gh auth login`, then `/goal-resume`.
- `AWAITING_DISK` — free disk still under the hard floor after automatic cleanup; run `bash scripts/automation/tmp-doctor.sh --aggressive` yourself (no user approval needed), then `/goal-resume`. Only involve the user if the doctor exits 2 (the machine is genuinely out of disk).
- `AWAITING_PUMP` — the pump/session went away mid-iteration; re-open it and `/goal-resume` (it re-runs that iteration).
- `REGRESSION_HALT` — report the regression; resuming requires `--acknowledge-regression`.
- `STALLED` or `BUDGET_EXHAUSTED` — report it and suggest editing `docs/goal.md` or raising `--max-iter`.
- `ABORTED` — the run was interrupted; `/goal-resume` continues from the last iteration.

## Quota and pauses

Interactive usage limits surface as the pump being unable to dispatch. That is a
pause, not a failure: wait for the limit to reset, then continue the loop or run
`/goal-resume`. The engine never sleeps-until-reset in interactive mode, because
that behaviour lives in the headless `claude -p` path.

## Status without launching

`/goal-status` only reads `session.json`, the latest `iter-<N>/eval.md`, and the
dispatch dir. It never launches the engine and never writes anything.
