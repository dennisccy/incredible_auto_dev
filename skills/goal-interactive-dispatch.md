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

## Launch

1. Resolve the session id from the command argument, or generate one and state it.
2. Start the engine in the background (Bash with run_in_background), and capture
   its process id:
   `./scripts/automation/run-goal.sh --session-id <sid> --interactive <passthrough flags>`
   The engine creates and exports `CHAIN_DISPATCH_DIR=runs/goal-session-<sid>/dispatch`.
3. Record the dispatch dir path and the engine pid for the loop.

## The pump loop

Repeat until the engine exits:

1. Run `scripts/automation/goal-await-dispatch.sh --dispatch-dir <dir> --engine-pid <pid>`
   (in the background). It blocks until one or more unanswered requests are ready
   and prints their file paths, or prints `ENGINE_DONE` once the engine has
   exited. It refreshes the pump heartbeat on each poll.
2. For each returned request path, read the request file. It is JSON with the
   fields `agent`, `prompt`, `cwd`, and `res_path`.
3. Dispatch every returned request together: issue one Agent tool call per
   request in a single message, with `subagent_type` set to the request's
   `agent` and the request's `prompt` passed verbatim. Do not pass a model
   override — the subagent runs on its own `.claude/agents/<agent>.md` model tier.
4. After each subagent returns, write its exit code (0 on success, a non-zero
   number if it clearly failed) to that request's `res_path`, which equals the
   request path with `.ready` replaced by `.res`.
5. Loop again. When `goal-await-dispatch.sh` prints `ENGINE_DONE`, leave the loop.

## Mapping a request to a subagent

The `agent` field is one of the goal-mode agent names, which match the
`.claude/agents/<name>.md` filenames exactly: developer, reviewer, qa,
browser-qa-agent, goal-decomposer, coherence-auditor, goal-evaluator,
iteration-summarizer, orchestrator, auditor, ui-impact-analyst, ui-test-designer,
ux-regression-reviewer, phase-closure-auditor, demo-narrator, release-manager,
product-manager. Use that name as `subagent_type`.

Fallback: if `agent` is `unattributed` or has no matching agent file, read the
prompt — it names its own instructions file as `.claude/agents/<name>.md`; use
that name. If none can be found, dispatch with the `general-purpose` subagent.

## Concurrency

The engine's post-dev fanout runs up to two agents at once, so more than one
request can be ready in a single cycle. Always dispatch the full set returned by
one `goal-await-dispatch.sh` call together (multiple Agent calls in one message),
then write all of their `.res` files. Request file names are unique, so two
concurrent requests never collide.

## Heartbeat

`goal-await-dispatch.sh` refreshes `<dir>/.pump-alive` while it waits. If you
stop pumping, the engine's blocked dispatches notice the stale heartbeat after
`CHAIN_PUMP_HEARTBEAT_TIMEOUT` seconds and stop cleanly, leaving an
`.awaiting-pump` marker, so the session can be resumed instead of hanging.

## When the engine exits

Read `runs/goal-session-<sid>/session.json` and report its `status` field, which
is authoritative:

- `GOAL_ACHIEVED` — the goal is done; point to the session summary and the delivered wrap.
- `AWAITING_BLUEPRINT_APPROVAL` — ask the user to review `state/blueprint.md`, then `/goal-resume`.
- `AWAITING_GITHUB_AUTH` — ask the user to run `gh auth login`, then `/goal-resume`.
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
