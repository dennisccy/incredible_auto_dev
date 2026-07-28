# Goal Mode — Interactive Dispatch (Pump Protocol)

version: 3.0.0 (protocol v3 — pump pid-liveness ident; bump with every change to this file)

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
   fields `agent`, `prompt`, `cwd`, `res_path`, `out`, and `usage_path`, plus an
   optional `model`. (Older engines may omit `out`/`usage_path`/`model` — all
   three are optional.)
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
4. After each subagent returns, write the result files in this order:
   1. the subagent's final message VERBATIM to the request's `out` path (Write
      tool; skip if the request has no `out` field) — the engine captures it
      into the session trace for measurement;
   2. optionally, the usage sidecar to the request's `usage_path` (see "Usage
      sidecar" below; best-effort — on ANY extraction failure just skip this
      step, never write guesses);
   3. its exit code (0 on success, a non-zero number if it clearly failed) to
      the request's `res_path`, which equals the request path with `.ready`
      replaced by `.res`. The `.res` write is the completion signal, so it must
      come LAST — the engine reads `out`/`usage_path` only after it appears.
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

## Host-guard confinement (interactive pump)

The engine's own self-wrap (run-goal.sh) confines only the HEADLESS engine tree.
Interactive dispatches — every subagent, and every `pytest`/build/browser those
subagents run through Bash — execute as descendants of THIS foreground CLI
session, so they inherit whatever CPU/memory confinement this session was
launched with, and nothing can retrofit it afterwards. When the project declares
host caps (`project-extensions/host-guard/host-guard.env`), the session must be
launched through the wrapper:

    scripts/automation/host-guard-exec.sh claude

With `HOST_GUARD_REQUIRE_PUMP_CONFINED=1`, the engine verifies the pump's cpuset
(via the `pid=` line in `.pump-alive`) at each iteration boundary and pauses the
session (`AWAITING_HOST_GUARD`, resumable) if the pump is wider than
`HOST_GUARD_CPU_LIST`. If that pause fires, relaunch the CLI via the wrapper and
`/goal-resume` — do not disable the flag to make the pause go away; the caps
exist because unconfined goal-mode load has hard-reset the host.

## Usage sidecar (token telemetry — protocol v2, optional, best-effort)

Headless dispatches record per-invocation token usage (`claude_usage` telemetry
events); interactive dispatches historically recorded none. Protocol v2 closes
that gap: after a subagent returns, the pump MAY write a JSON sidecar to the
request's `usage_path` (before `.res`). When present and well-formed, the engine
emits the same `claude_usage` telemetry event the headless sidecar produces
(same keys, agent attribution included) and enriches the session trace. When
absent, engine behavior is byte-identical to protocol v1.

Sidecar shape (`usage` object required, all four fields non-negative numbers;
the rest optional passthrough):

```json
{"model": "<resolvedModel>", "num_turns": 18, "duration_ms": 318100,
 "usage": {"input_tokens": 4879, "output_tokens": 54996,
           "cache_read_input_tokens": 969645, "cache_creation_input_tokens": 89317}}
```

HONESTY RULE: the numbers must come from the transcript extraction below. If any
step fails — file missing, ambiguous match, jq error — write NO sidecar (the
engine treats absence as "unknown", which is the correct answer). NEVER estimate
or fabricate counts. Do not put a `total_cost_usd` in the sidecar: the transcript
does not expose cost, and interactive-plan dispatches have no per-call USD price.

Extraction recipe (one Bash call per dispatch, after the subagent returns and
before writing `.res`; run it QUIETLY per the output discipline). Substitute
`<AGENT_TYPE>` with the `subagent_type` you dispatched and `<USAGE_PATH>` with
the request's `usage_path`:

```bash
sid="${CLAUDE_CODE_SESSION_ID:?}"   # exported to every Bash tool call
t="$(ls -t "$HOME"/.claude/projects/*/"$sid".jsonl 2>/dev/null | head -1)"
[ -s "$t" ] || exit 0
# Newest completed dispatch of this agent type in the pump's own transcript.
row="$(jq -c --arg a "<AGENT_TYPE>" \
  'select(.toolUseResult.agentType? == $a) | .toolUseResult | {agentId, resolvedModel, totalDurationMs}' \
  "$t" 2>/dev/null | tail -1)"
[ -n "$row" ] || exit 0
id="$(printf '%s' "$row" | jq -r '.agentId // empty')"
a="${t%.jsonl}/subagents/agent-$id.jsonl"
[ -s "$a" ] || exit 0
# Per-dispatch totals = per-message usage summed over the subagent transcript,
# deduplicated by message.id (streaming snapshots repeat ids; keep each id's
# LAST row). This matches the run-cumulative semantics of the headless sidecar.
jq -s --argjson meta "$row" '
  [.[] | select(.type=="assistant" and .message.usage != null)]
  | group_by(.message.id) | map(.[-1].message.usage)
  | {model: ($meta.resolvedModel // null), num_turns: length,
     duration_ms: ($meta.totalDurationMs // 0),
     usage: {input_tokens:                (map(.input_tokens // 0) | add // 0),
             output_tokens:               (map(.output_tokens // 0) | add // 0),
             cache_read_input_tokens:     (map(.cache_read_input_tokens // 0) | add // 0),
             cache_creation_input_tokens: (map(.cache_creation_input_tokens // 0) | add // 0)}}
' "$a" > "<USAGE_PATH>" 2>/dev/null || rm -f "<USAGE_PATH>"
```

Caveats:
- Do NOT use the parent transcript's `toolUseResult.usage` / `totalTokens` as
  the counts — they are a final-API-call snapshot, not the dispatch total
  (verified: they equal the subagent transcript's last row and under-report
  earlier calls).
- If you dispatched two or more concurrent requests with the SAME agent type,
  `tail -1` may mis-attribute. Disambiguate by also comparing
  `.toolUseResult.prompt` against the prompt you dispatched (first ~120 chars);
  if it stays ambiguous, skip the sidecar for those dispatches.
- This reads the Claude Code transcript format observed on CLI 2.1.205/2.1.206
  (`~/.claude/projects/<project-slug>/<session>.jsonl` +
  `<session>/subagents/agent-<id>.jsonl`). If a future CLI changes it, the
  recipe fails closed (no sidecar, dispatch unaffected).

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
