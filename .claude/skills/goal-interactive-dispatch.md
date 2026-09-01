# Goal Mode — Interactive Dispatch (Pump Protocol)

version: 4.0.0 (protocol v4 — finish-in-await: one Bash call closes the previous dispatch and awaits the next, requests arrive as JSON; bump with every change to this file)

This skill defines how the foreground Claude Code session (the "pump") runs the
existing goal-mode engine so that every agent executes as an interactive
subagent — billed to the interactive plan allowance — instead of a headless
`claude -p` subprocess. The `/goal`, `/goal-resume`, and `/goal-step` commands
all follow this protocol. The engine's loop, stop rules, resume, and state are
unchanged; only the model invocation is redirected through a file channel
(`scripts/automation/lib/interactive-dispatch.sh`).

**Protocol version 2** adds the optional per-dispatch usage sidecar (token
telemetry — see "Usage sidecar" below). Every field it adds is optional: a pump
that ignores it behaves exactly like protocol v1. **A RUNNING pump predates any
protocol change** — pump behavior comes from this file as loaded at pump start,
so after upgrading it, restart the pump session before resuming
(`.claude/letter-to-future-sessions.md`, "How this system degrades": *"The pump
protocol changes but a running pump predates it"*).

**Protocol version 3** (REL-3) adds an optional pump identity to the files
`goal-await-dispatch.sh` already maintains: the heartbeat (`.pump-alive`) and
each claim marker (`<req>.started`) may now carry `pid=` / `host=`
(/ `starttime=`) lines naming the long-lived pump process — the `claude`
session binary, resolved once per await call by /proc ancestry
(`CHAIN_PUMP_PID` overrides it; set-but-empty disables ident entirely). The
engine uses it for one thing: on a CLAIMED dispatch whose `host` matches, a
provably dead — or starttime-recycled — pid pauses the session `AWAITING_PUMP`
within one poll interval instead of waiting out the inflight cap. Every field
is optional and the writes preserve the old mtime semantics, so an older pump
(contentless files) or a cross-host pump keeps the two timeout tiers below
byte-identical to protocol v2; you as the pump do nothing new — the helper
writes the fields. Same restart rule as v2: a RUNNING pump predates the
protocol — restart the pump session after upgrading this file
(`.claude/letter-to-future-sessions.md`, "How this system degrades").

**Protocol version 4** (TOKEN-11a, 2026-09-01) removes the pump's per-dispatch
plumbing turns. The await helper now (a) prints each request as one JSON line
(`--print-json`: agent, prompt, model, paths) so you never Read a request file,
and (b) takes `--finish <req.ready>=<agent>=<rc>` so ONE Bash call both completes
the previous dispatch — `out`, the usage sidecar and `.res` are written by
`lib/pump_finish.py` from your session's own transcript — and blocks for the next
request. You no longer write `out`, `usage_path` or `.res` yourself and you never
re-emit a subagent's final message. A dispatch costs two of your turns: the Bash
call and the Agent call. Engine side nothing changed (`interactive-dispatch.sh`
reads the same files). Same restart rule as v2/v3: **a RUNNING pump predates the
protocol — restart the pump session after upgrading this file.**

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
calls only, no narration. **Two turns per dispatch: one Bash call, one Agent call.**

1. Run, in the **foreground** (one blocking Bash call, NOT a background job; set a
   Bash command timeout of 600000 ms):
   `scripts/automation/goal-await-dispatch.sh --dispatch-dir <dir> --engine-pid <pid> --max-wait 590 --print-json [--finish <req.ready>=<agent>=<rc> ...]`
   — with one `--finish` per subagent that returned since your previous call
   (none on the very first call). The helper first completes those dispatches
   (writes each request's `out`, its usage sidecar when the transcript lookup
   succeeds, then `.res` LAST — the engine's completion signal), then blocks
   until there is work and prints exactly one of:
   - one or more request lines, each a single JSON object with `path`, `agent`,
     `prompt`, `cwd`, `res_path`, `out`, `usage_path` and optionally `model` →
     go to step 2;
   - `WAITING` → no work yet, engine still alive → silently re-run the same call
     (without `--finish`, those dispatches are already closed);
   - `ENGINE_DONE` → the engine exited → leave the loop.
   It refreshes the pump heartbeat every second while it blocks, so a ≤590 s wait
   never trips `CHAIN_PUMP_HEARTBEAT_TIMEOUT`.
2. Do NOT Read the request file — everything you need is in the JSON line(s).
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
     Delete that prompt file after the dispatch has been finished.
4. When the subagent(s) return, do NOT write any file and do NOT echo their
   replies. Go straight back to step 1 with one `--finish <path>=<agent>=<rc>`
   per returned request — `<path>` is the request's `path`, `<agent>` its
   `agent`, `<rc>` 0 on success or a small non-zero number if the subagent
   clearly failed. That single call closes them and awaits the next work.
5. When step 1 prints `ENGINE_DONE`, leave the loop.

## Mapping a request to a subagent

The `agent` field is one of the goal-mode agent names, which match the
`.claude/agents/<name>.md` filenames exactly: developer, reviewer, qa,
browser-qa-agent, goal-decomposer, coherence-auditor, goal-evaluator,
iteration-summarizer, readme-maintainer, orchestrator, auditor, ui-impact-analyst,
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

## Host-guard confinement (interactive pump)

The engine's own self-wrap (run-goal.sh) confines only the HEADLESS engine tree.
Interactive dispatches — every subagent, and every `pytest`/build/browser those
subagents run through Bash — execute as descendants of THIS foreground CLI
session and inherit ITS confinement. When the project declares host caps
(`project-extensions/host-guard/host-guard.env`), that confinement is applied
automatically — no special launch command is required:

- the `/goal` command runs `scripts/automation/host-guard-adopt.sh
  --cli-root-of $$` at session start, which confines the RUNNING CLI process
  tree in place (scope adoption for memory/task/quota ceilings + a hard
  `taskset` CPU mask on the tree, inherited by all future children);
- with `HOST_GUARD_REQUIRE_PUMP_CONFINED=1`, the engine re-verifies the pump at
  every iteration boundary (via the `pid=` line in `.pump-alive` or the CLI
  root it captured at launch) and auto-confines it again if needed, pausing
  (`AWAITING_HOST_GUARD`, resumable) only when in-place confinement fails.

Optional belt-and-braces: launching the CLI through
`scripts/automation/host-guard-exec.sh claude` confines it from birth and also
sets the BLAS/OMP thread-cap env vars (those cannot be injected into a running
process). If the pause ever fires, relaunch via that wrapper and `/goal-resume`
— do not disable the flag to make the pause go away; the caps exist because
unconfined goal-mode load has hard-reset the host.

## Usage sidecar (token telemetry — written by the finish helper since protocol v4)

Headless dispatches record per-invocation token usage (`claude_usage` telemetry
events). Interactive dispatches get the same event from the usage sidecar, which
`lib/pump_finish.py` writes when you pass `--finish`: it locates your session's
transcript (`$HOME/.claude/projects/<slug>/$CLAUDE_CODE_SESSION_ID.jsonl`), the
newest not-yet-consumed Agent result of the finished `agent` type (prompt-matched
when two dispatches of one type are in flight), the subagent transcript
`<session>/subagents/agent-<id>.jsonl`, and sums its per-message usage deduped by
`message.id` (streaming snapshots repeat ids; the last row wins). Shape:

```json
{"model": "<resolvedModel>", "num_turns": 18, "duration_ms": 318100,
 "usage": {"input_tokens": 4879, "output_tokens": 54996,
           "cache_read_input_tokens": 969645, "cache_creation_input_tokens": 89317}}
```

HONESTY RULE (unchanged): the numbers come from the transcript or not at all. If
any step fails — transcript missing, no attribution row, subagent file absent,
schema drift — the helper writes NO sidecar (the engine records "unknown", which
is the correct answer), writes a stub `out` line naming the reason, and still
writes `.res`. It never estimates. `total_cost_usd` is never written: interactive
dispatches have no per-call USD price. The `out` file receives the subagent's
final assistant text from the same transcript — you never re-emit it.

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
  30+ minute INITIAL BUILD does not trip a false "pump stale" abort. Protocol v3:
  when the claim carries the pump ident (`pid=`/`host=`/`starttime=`) and the
  host matches the engine's, a provably dead or pid-recycled pump fast-pauses
  `AWAITING_PUMP` within one poll — the 2h cap remains the net for cross-host
  pumps and pre-v3 claims.

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
- `AWAITING_FULL_DEPTH` — nothing was dispatched: the iteration declared full depth a HARD requirement (`CHAIN_REQUIRE_FULL_DEPTH`, a `Depth enforcement: required` line in its spec, or a `Maintenance isolation: required` line — isolation requires full depth by contract) and the engine could not dispatch it, so it halted BEFORE any developer mutation, browser lane or service boot. Report the engine's `reason:` line and `runs/goal-session-<sid>/iter-<N>/depth-requirement-unmet` — it records `requested`, `actual`, `reason`, `step` and `remedy`. Relay THAT remedy, which depends on `step`: `depth-arbiter` (the cost ladder could not grant full) — let the cadence window pass or re-run with `CHAIN_FULL_CADENCE_CAP=1`; `depth-parse` — fix the spec's `Depth:` line so it parses **before** resuming (a still-unparseable line makes `--resume` re-run the decomposer, which rewrites the spec and drops operator-only lines); `full-dispatch` — the installed `run-phase.sh` has no `--no-finalize` flag, so update/restore the framework checkout; `depth-legacy-allowlist` — add the qualifying `Full trigger: <1-4> — <reason>` line to the spec, or re-enable the deterministic arbiter (unset `CHAIN_DEPTH_ARBITER`; at iteration 0, which the arbiter exempts, only the `Full trigger:` line helps); `isolation-requires-full` — the spec declared maintenance isolation, which REQUIRES full depth, but resolved to lean/evidence: write `Depth: full` (plus a `Full trigger:` line when the arbiter is skipped) or drop the isolation declaration. Then `/goal-resume`. NEVER clear the requirement itself (unset `CHAIN_REQUIRE_FULL_DEPTH`, edit the spec line) to make the pause go away — the requirement is why the pause exists — and never suggest `CHAIN_DEPTH_ARBITER=false`, which removes the precedence rung and the guard rather than resolving anything.
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
