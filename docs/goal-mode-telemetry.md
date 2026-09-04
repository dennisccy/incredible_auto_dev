# Goal Mode Telemetry Schema

Goal-mode runs write structured telemetry to `runs/goal-session-<sid>/telemetry.jsonl`. Each line is a single JSON object describing one event. The file is append-only across the lifetime of a session (and across `--resume` calls).

This file documents the event schema. The data stays local: nothing is transmitted from the project. A future plan may add an opt-in sanitized export to feed framework self-evolution, but this plan only captures the data.

## Common fields

Every event includes:

| Field | Type | Description |
|---|---|---|
| `ts` | string | ISO 8601 UTC timestamp (e.g., `2026-05-04T12:34:56Z`) |
| `session_id` | string | The goal session id (matches `runs/goal-session-<sid>/`) |
| `iter` | number \| null | Current iteration index (0 = baseline). `null` for session-level events. |
| `event` | string | Event type — one of the values listed below |

Event-specific fields are merged at the top level of the JSON object.

## Event types

### `session_start`
Written by `run-goal.sh` when a session starts (or resumes).

| Field | Type | Description |
|---|---|---|
| `mode` | string | `new` or `resume` |
| `max_iterations` | number | Configured cap (`0` = unlimited / no cap, the default) |
| `stall_window` | number | Configured stall window |
| `auto_release` | boolean | Whether `--auto-release` was passed |

### `session_end`
Written when the loop halts.

| Field | Type | Description |
|---|---|---|
| `final_verdict` | string | `GOAL_ACHIEVED` \| `BUDGET_EXHAUSTED` \| `STALLED` \| `REGRESSION_HALT` \| `ABORTED` |
| `total_iterations` | number | Iterations completed (excluding the final halt detection) |
| `wall_time_seconds` | number | Total elapsed wall time |
| `quota_pause_count` | number | Number of times `claude_with_quota_retry` slept for quota |

### `iter_start`
Written before goal-decomposer is invoked for an iteration.

| Field | Type | Description |
|---|---|---|
| `iter_name` | string | The synthetic phase name (`goal-<sid>-iter-<N>`) |
| `prior_verdict` | string \| null | Verdict from previous iteration (null on iter 0) |
| `prior_depth` | string \| null | Depth used in previous iteration |

### `decomposer_start`, `decomposer_end`
Wrap the goal-decomposer agent invocation.

| Field | Type | Description |
|---|---|---|
| `agent` | string | Always `goal-decomposer` |
| `mode` | string | `--baseline` or `--next` |
| `exit_status` | number | (end only) Process exit code |
| `duration_seconds` | number | (end only) Wall time |
| `retries` | number | (end only) Quota-retry count for this invocation |

### `iter_dispatch`
Records which pipeline was chosen for this iteration.

| Field | Type | Description |
|---|---|---|
| `depth` | string | `lean` or `full` |
| `target_journeys` | array of strings | Journey IDs this iteration targets (e.g., `["J-01","J-03"]`) |
| `maintenance_isolation` | string | The RAW `${CHAIN_MAINTENANCE_ISOLATION:-false}` literal as it stands after `apply_maintenance_isolation_from_spec` has materialized any `Maintenance isolation: required` spec line — `"true"` when the spec declared it, `"false"` when unset, but any operator-set truthy value (`"1"`, `"yes"`, `"on"`, `"required"`, `"TRUE"`) is emitted verbatim, so consume it with the same truthy set the engine uses rather than `== "true"`. A string on both the jq and the jq-less path, never a boolean. The only per-iteration record that the app/browser lanes were withheld by contract |

### `agent_invocation_start`, `agent_invocation_end`
Wrap each agent call inside an iteration (developer, reviewer, browser-qa-agent, etc.).

| Field | Type | Description |
|---|---|---|
| `agent` | string | Agent name |
| `exit_status` | number | (end only) Process exit code |
| `duration_seconds` | number | (end only) Wall time, INCLUDING any quota-pause sleep |
| `quota_sleep_seconds` | number | (end only) Seconds of that wall time spent in quota-pause sleeps (SPEED-13) |
| `active_seconds` | number | (end only) `duration_seconds − quota_sleep_seconds` — the honest work time (SPEED-13) |
| `retries` | number | (end only) Quota-retry count for this invocation |

### `quota_pause_start`, `quota_pause_end`
Recorded around quota-exhaustion sleeps inside `claude_with_quota_retry`.

| Field | Type | Description |
|---|---|---|
| `agent` | string | Agent that triggered the pause |
| `reset_epoch` | number | (start only) Epoch the sleep targets |
| `sleep_seconds` | number | (end only) Total seconds slept |

> Note: These events are emitted directly by `lib/quota-retry.sh` at its sleep
> sites (both claude and codex paths; SPEED-13). They no-op outside goal mode —
> `record_telemetry_event` is disabled when no goal session is active. The same
> path increments the session's `.quota-pause-count` file.

### `evaluator_start`, `evaluator_end`
Wrap the goal-evaluator agent invocation.

| Field | Type | Description |
|---|---|---|
| `agent` | string | Always `goal-evaluator` |
| `exit_status` | number | (end only) Process exit code |
| `duration_seconds` | number | (end only) Wall time |
| `retries` | number | (end only) Quota-retry count |

### `iter_end`
Written after the evaluator returns and state is updated.

| Field | Type | Description |
|---|---|---|
| `iter_name` | string | The synthetic phase name |
| `verdict` | string | The evaluator's verdict |
| `next_depth` | string | The evaluator's next-iteration depth recommendation |
| `journey_deltas` | object | Counts: `{newly_passing, newly_failing, regressed, anti_goal_violations}` |

### `halt`
Written when a hard halt fires before normal `iter_end`.

| Field | Type | Description |
|---|---|---|
| `reason` | string | Includes `BUDGET_EXHAUSTED`, `STALLED`, `REGRESSION_HALT`, `ABORT_MALFORMED`, `DECOMPOSER_FAILED`, `GATE_BLOCKED_POST_DECOMPOSE`, `machine_reset`, and the resumable pauses `AWAITING_BLUEPRINT_APPROVAL`, `AWAITING_INTENT_REVIEW`, `AWAITING_PUMP`, `AWAITING_GITHUB_AUTH`, `AWAITING_DISK`, `AWAITING_HOST_GUARD`, `AWAITING_FULL_DEPTH`. `ABORTED` is a session *status* only — the SIGINT trap writes the summary, not a halt event. Not a closed enum: `grep -n 'record_telemetry_event "halt"' scripts/automation/run-goal.sh` is the ground truth |
| `detected_at_step` | string | Where the halt was detected (e.g., `pre_decomposer`, `post_evaluator`; `AWAITING_FULL_DEPTH` uses `depth-arbiter`, `depth-parse`, `full-dispatch`, `depth-legacy-allowlist` or `isolation-requires-full` — the five sites that could otherwise have silently run at less than the required depth) |
| `demotion_reason` | string | `AWAITING_FULL_DEPTH` only: why full depth could not be dispatched — `arbiter-demotion:<rung>`, `unparseable Depth line in <spec-path>`, `run-phase.sh lacks --no-finalize`, `legacy-allowlist:no-qualifying-trigger (…)`, or `maintenance isolation requires full depth but this spec resolved to <depth>`. Mirrors the `reason=` field of `iter-<N>/depth-requirement-unmet`, which also carries a `remedy=` line naming the one action that unblocks that specific step |

### `iter_push` (opt-in)
Written by `run-goal.sh` after each iteration when `--push-per-iter` is enabled. One event per iteration. Captures whether the per-iter commit + push succeeded and which branch received the commit.

| Field | Type | Description |
|---|---|---|
| `branch` | string | The push branch name (e.g., `goal/my-app`) |
| `commit_sha` | string | SHA of the commit created (empty on commit/add failure) |
| `success` | boolean | True if commit + push both succeeded, OR the iteration was deliberately skipped (no changes / halt verdict) |
| `error` | string | Failure reason: `"add failed"`, `"commit failed"`, `"push failed"`. Empty on success. |
| `skipped` | string | When success is true but no commit was made: `"no_changes"` (clean working tree) or `"halt_verdict"` (REGRESSION / STALLED). Absent on actual commits. |
| `verdict` | string | The iteration verdict that triggered the eligibility check |

To enable: pass `--push-per-iter` (and optionally `--push-branch <name>`) to `run-goal.sh`. See [goal-mode-quickstart.md](goal-mode-quickstart.md) for the full flow.

### `claude_usage` (default-on headless; best-effort interactive)
Written by `claude_with_quota_retry` after a successful Claude invocation when `CHAIN_TELEMETRY_TOKENS=true` — which is the **default** for the headless backend (`lib/quota-retry.sh`). Captures Claude API usage from the stream-json `result` event via `lib/claude_stream_renderer.py`. Set `CHAIN_TELEMETRY_TOKENS=false` to opt out. **Interactive-pump path (protocol v2, TOKEN-5):** the pump extracts each dispatch's token totals from its own Claude Code session transcript (`~/.claude/projects/<project>/<session>/subagents/agent-<id>.jsonl`, per-message usage summed — the recipe lives in `skills/goal-interactive-dispatch.md`) and writes them to the request's `usage_path` sidecar; `lib/interactive-dispatch.sh` validates it and emits the same event through the same telemetry helper. Best-effort: a pre-v2 pump, a failed extraction, or a malformed sidecar (skipped with one warning) records no event for that dispatch — absence means "unknown", never estimated. Interactive events omit `total_cost_usd` (no per-call USD price on the interactive plan; the analyzer's cost column reads 0 for them).

On the interactive backend (pump protocol v4, TOKEN-11a) the same event comes from the usage sidecar that `lib/pump_finish.py` writes when the pump calls `goal-await-dispatch.sh --finish`: it sums the subagent transcript's per-message usage (deduped by `message.id`) and never estimates — when the transcript lookup fails no sidecar is written and the dispatch is recorded as usage-unknown. The pump's OWN turns are not in this event; use `lib/analyze_transcripts.py` (below) for those.

| Field | Type | Description |
|---|---|---|
| `agent` | string | The agent context that drove the call (set by `record_agent_invocation_start`) |
| `usage.input_tokens` | number | Non-cached input tokens |
| `usage.output_tokens` | number | Output tokens generated |
| `usage.cache_read_input_tokens` | number | Input tokens served from prompt cache |
| `usage.cache_creation_input_tokens` | number | Input tokens written to prompt cache |
| `total_cost_usd` | number | Total cost reported by the API for this invocation |
| `duration_ms` | number | Wall-clock duration of the claude call |
| `duration_api_ms` | number | API-side duration |
| `num_turns` | number | Number of model turns (assistant/tool_use cycles) |
| `is_error` | boolean | True if the result event was an error |
| `subtype` | string | `success` \| `error_max_turns` \| etc. |
| `output_style` | string \| null | The **effective** Claude Code output style, read from the stream-json `system/init` event by `lib/claude_stream_renderer.py` and carried in through the usage sidecar. `default` when no style is active; null on CLIs that do not report it (older `claude`, Codex) — null means *unknown*, never "default" |
| `available_output_styles` | string \| null | Comma-joined list of the output styles Claude Code reports as available, read from the same stream-json `system/init` event by `lib/claude_stream_renderer.py` (`:189-190`) and carried in through the usage sidecar. null when the CLI does not report the field — observed on CLI 2.1.237 |
| `output_style_requested` | string | The style the engine **requested** for this dispatch (STYLE-1; e.g. `Concise`). Absent when no style was requested. Interactive-backend rows read `<name>(emulated)` — subagents never receive a style natively, so the seam appends the emulation block to the prompt instead. Compare against `output_style` to know whether the arm actually ran. The trace row (`trace/trace.jsonl`) carries the same `output_style_requested` key next to its effective `output_style`. |

Enabled by default headless; opt out with `export CHAIN_TELEMETRY_TOKENS=false`. To opt out of cache hygiene (`--exclude-dynamic-system-prompt-sections`): `export CHAIN_CLAUDE_DISABLE_CACHE_HYGIENE=true`.

Aggregate per-session and per-agent with:
```bash
python3 scripts/automation/lib/analyze_telemetry.py runs/goal-session-<sid>/telemetry.jsonl
```

### Timing / experiment events

| Event | Written by | Payload highlights |
|---|---|---|
| `step_skipped` | `goal-iter-lean.sh`, `run-goal.sh`, `run-phase.sh` | `{step, iter_name|phase, reason}` — a step was skipped instead of dispatched. Reasons: `checkpoint` (resume reused a completed step), `zero-change` (SPEED-14), `iter-budget-trim` (SPEED-15 rungs 3a/3b: `test-plan`/`ux-regression`, payload key `phase`), `ui-combined` (SPEED-24: `ui-test-design` folded into the ui-impact dispatch, payload key `phase`) |
| `dispatch_wait` | `lib/interactive-dispatch.sh` | `{agent, wait_seconds, run_seconds, status, rc}` — pickup-wait vs run split per interactive dispatch attempt (`ok` \| `pickup-timeout` \| `inflight-timeout` \| `inflight-timeout-requeued`) |
| `review_verdict` | `lib/telemetry.sh` `record_review_verdict` (called by `goal-iter-lean.sh` at both review attempts and by `run-phase.sh` Step 3 in full-depth iterations; the Step 7/9 hardening reviews of phase mode emit nothing) | `{verdict, attempt, iter_name}` — reviewer outcome per attempt (feeds the tripwire). `verdict` is `PASS` \| `PASS_WITH_NOTES` \| `FAIL`, or `""` when the dispatched reviewer returned without a parseable `**Verdict:**` line (quota pauses and resume-skipped reviews emit no event) |
| `iter_config` | `run-goal.sh` | `{key, value}` — an opt-in experiment knob was active this iteration. One event per active knob: `CHAIN_AGENT_EFFORT` carries the effort map; `CHAIN_OUTPUT_STYLES` (STYLE-1) carries the whole arm string (`CHAIN_OUTPUT_STYLES=… CHAIN_AGENT_OUTPUT_STYLE=… CHAIN_OUTPUT_STYLE_OVERRIDE=…`, sanitized). Any `iter_config` event marks the iteration knob-active for the tripwire window |
| `golden_coverage` | `goal-iter-lean.sh`, `browser-qa-phase.sh` (goal iterations) | `{passing, missing_goldens, iter_name}` — PASSing journeys still lacking a replay golden (also persisted to `state/golden-gaps`, SPEED-23) |
| `experiment_reverted` | `run-goal.sh` | `{key, value}` — the tripwire auto-reverted an experiment knob |
| `spec_regenerated` | `run-goal.sh` | `{iter_name, dropped}` — a resume re-ran the goal-decomposer over an existing spec that carried an operator-only line (`Maintenance isolation: required` / `Depth enforcement: required`), which regeneration destroys because the decomposer is forbidden to write them (anti-pattern 25). Paired with a loud `WARNING: regenerating … will DROP operator-only line(s)` on stderr. `dropped` names the operative line found; the probe uses the predicates, so when both are present the isolation one is named |
| `depth_full_granted` / `depth_demoted` | `run-goal.sh` | `{reason, prior_verdict, prior_depth}` — the SPEED-20 deterministic depth arbiter granted a spec-requested full (`prior-verdict-*`, `prior-coherence-fail`, `cadence-due`, `new-fullstack-journey`) or demoted it to lean (`budget-breach`, `full-cap`, `evaluator-requested-*`, legacy `no-full-trigger`) |
| `depth_cost_overridden` | `run-goal.sh` | `{requirement:"hard-full-required", overridden_cost_rung, prior_verdict, prior_depth}` — the iteration was hard-required full (`CHAIN_REQUIRE_FULL_DEPTH` or a `Depth enforcement: required` spec line) and the precedence rung overrode a COST rung that would otherwise have demoted it: `budget-breach`, `full-cap`, or `evaluator-requested-lean`/`evaluator-requested-evidence`. Evidence only — the overridden rung's on-disk marker (e.g. the previous iteration's `budget-breached`) is deliberately left untouched. Without jq the payload carries `requirement` + `overridden_cost_rung` only |
| `maintenance_isolation_refused` | `lib/common.sh` `maintenance_isolation_refuse` (called from `_boot_shared_services`, `ensure_services_running`, `browser-qa-phase.sh`, `replay_lane_partition_and_verify`, `demo-phase.sh` and `run-goal.sh`'s showcase-join) | `{operation, detail}` — a path forbidden under maintenance isolation was reached and REFUSED rather than degraded. `operation` is the refusing site (`ensure_services_running`, `_boot_shared_services`, `browser-qa-phase`, `replay_lane_partition_and_verify`, `demo-phase`, `demo_runner`, `demo golden auto-derive`, `async-showcase-join`). The same call appends a tab-separated `<utc-timestamp>\toperation=…\tdetail=…` line to `runs/goal-session-<sid>/iter-<N>/maintenance-isolation-refusals`, so the refusal survives even where telemetry is unavailable |
| `iter_budget` | `lib/common.sh` (any budget-aware script) | `{budget, elapsed, mode, at_step}` — first over-budget check of the process (SPEED-15; defaults 3600s/trim) |
| `iter_budget_trim` | `run-goal.sh`, `goal-iter-lean.sh`, `run-phase.sh`, `browser-qa-phase.sh` | `{rung}` — a trim rung actually shed work (`showcase-defer`, `replay-narrow`, `testplan-skip`, `ux-regression-skip`) |
| `goal_slice_fallback` | `lib/common.sh` (executor dispatch sites) | `{iter_name, rc}` — the TOKEN-10 executor goal-slice build failed; the dispatch fell back loudly to the full `docs/goal.md` |
| `golden_autoderived` / `golden_autoderive_rejected` | `lib/replay-lane.sh` (via `demo-phase.sh`) | `{journey, iter_name}` — a SPEED-21 demo-derived golden candidate replayed green and was installed, or failed its verify pass and was discarded |
| `golden_nudge` | `goal-iter-lean.sh`, `browser-qa-phase.sh` | `{journey, iter_name}` — SPEED-23 promoted this journey's golden to a REQUIRED deliverable this dispatch |
| `replay_mass_fail_voided` / `replay_mass_fail_confirmed` | `lib/replay-lane.sh` / `goal-iter-lean.sh` | `{iter_name, journeys, canaries}` — SPEED-22 mass-false-FAIL breaker outcome: green canaries voided the replay FAILs (drift), or a canary failure kept the full re-confirm path |

### `missing_evidence` (REL-11 tripwire)
Written when a dispatch returns — any exit code, including 0 — without its expected report artifact on disk: full-mode QA (`qa-phase.sh`), the lean browser-qa LLM lane (`goal-iter-lean.sh`; quota pauses excluded), the retro-analyst (`run-goal.sh`), the developer's dev handoff (`goal-iter-lean.sh` lean, `dev-phase.sh` full), the ui-impact-analyst's user-visible-changes report (`ui-impact-phase.sh`, alongside the SKIPPED stub), and the ux-regression review (`ux-regression-phase.sh`). The telemetry counterpart of the loud `[missing-evidence]` stderr banner (`lib/common.sh` `warn_missing_evidence`). Non-blocking — a tripwire, never a gate.

| Field | Type | Description |
|---|---|---|
| `agent` | string | Dispatching agent whose report is missing (`qa` \| `browser-qa-agent` \| `retro-analyst` \| `developer` \| `ui-impact-analyst` \| `ux-regression-reviewer`) |
| `path` | string | The expected report path that was absent |

### `output_style_mismatch` (STYLE-1)
Written when the output style the engine requested for a dispatch is **not** the one that actually ran. The headless seam (`lib/quota-retry.sh`) compares the requested name against the effective `output_style` from the stream-json `init` event after each invocation — the CLI ignores an unknown or unapplied `--settings` style silently, so this readback is the only ground truth. The interactive seam (`lib/interactive-dispatch.sh`) writes it when a valid style has no emulation text and the dispatch therefore went out unstyled. Non-blocking — the work already happened — but **any occurrence invalidates that dispatch's membership in the arm**: exclude it before comparing styled vs unstyled numbers.

| Field | Type | Description |
|---|---|---|
| `agent` | string | The agent context of the dispatch |
| `requested` | string | The style the engine asked for (empty = none) |
| `effective` | string | The style that actually ran (`default` when none; empty on the interactive backend, where there is nothing to read back) |
| `backend` | string | `headless` \| `interactive` |
| `reason` | string | Interactive only: `no-emulation-text` |

### `browser_teardown` (per-dispatch QA browser teardown)
Written by `qa_browser_step_teardown` (`lib/common.sh`) right after a browser dispatch
(browser-qa-agent / qa) returns — one row per browser acted on. The engine emits it;
agents never close tabs themselves.

| Field | Type | Description |
|---|---|---|
| `backend` | string | `headless` (engine lane) or `interactive` (pump session's MCP browser) |
| `mode` | string | `close-all` (headless: every page on the lane's pinned port) or `tabs` (interactive: exact-origin tabs only) |
| `lane` | string | headless only — the pinned lane profile (`CHROME_WS_PROFILE`) |
| `profile` | string | interactive only — the MCP browser profile from its `.meta.json` |
| `origin` | string | interactive only — the normalized app origin that was matched (`scheme://host:port`) |
| `closed_tabs` | number | Pages closed over CDP |
| `remaining_tabs` | number | Pages still open in that browser afterwards (headless: 0 when it exited cleanly) |
| `clean_exit` | boolean | headless only — Chrome exited on its own after the close (no reap needed) |
| `reaped` | number | headless only — browsers terminated by the lane-scoped reap (0 on a clean exit) |

### Wall-time report and tripwire

Where do the ~2 hours of an iteration go? Per-iteration wall breakdown (per-agent
minutes, resume-skips, pump wait, parallel-overlap savings, unattributed glue):

```bash
python3 scripts/automation/lib/analyze_telemetry.py --wall runs/goal-session-<sid>/telemetry.jsonl
python3 scripts/automation/lib/analyze_telemetry.py --wall --iter 4 ...   # one iteration
```

`run-goal.sh` prints this automatically after every `iter_end` and embeds the
full report in `runs/goal-session-<sid>/summary.md`; the per-iteration HTML page
carries it as a "Timing" accordion.

The experiment tripwire (exit 3 = TRIP) judges the last `--window` knob-active
iterations; `run-goal.sh` runs it each iteration while `CHAIN_AGENT_EFFORT` or
any `CHAIN_OUTPUT_STYLE*` knob is set, and auto-reverts every active knob on
TRIP (one `experiment_reverted` event per key):

- **Quality dimension** — any `REGRESSION` verdict, any journey regression, an
  unparseable review verdict, or first-attempt review `FAIL`s in ≥2 iterations of
  the window. "Unparseable" is a `review_verdict` event with an empty `verdict`:
  `goal-iter-lean.sh` (and `run-phase.sh` Step 3 in full-depth iterations, via
  the same helper) writes one when the reviewer was dispatched and came back
  without a parseable `**Verdict:**` line (quota pauses excluded, and a
  resume-skipped review emits no event at all).
- **Cost dimension** (ground rule D5: an earlier "be terser" change *increased*
  turns and roughly doubled output tokens) — per agent, the median of
  `usage.output_tokens` and of `num_turns` over the styled `claude_usage` rows
  in the window (`output_style_requested` set) against the same agent's unstyled
  rows in the session. TRIPs above **1.5×**, and only with **≥3 rows on each
  side**. Reasons are prefixed `cost:`.

```bash
python3 scripts/automation/lib/analyze_telemetry.py --tripwire --window 3 runs/goal-session-<sid>/telemetry.jsonl
```

## Reading the telemetry

```bash
# All events for a session
jq -c '.' runs/goal-session-<sid>/telemetry.jsonl

# Total quota pause time
jq -s '[.[] | select(.event=="quota_pause_end") | .sleep_seconds] | add' \
  runs/goal-session-<sid>/telemetry.jsonl

# Per-agent latency summary
jq -s '
  group_by(.agent)
  | map({
      agent: .[0].agent,
      invocations: length,
      total_seconds: ([.[] | .duration_seconds // 0] | add),
      avg_seconds: ([.[] | .duration_seconds // 0] | add / length)
    })
' < <(jq -c 'select(.event=="agent_invocation_end")' runs/goal-session-<sid>/telemetry.jsonl)

# Iteration-by-iteration verdicts
jq -c 'select(.event=="iter_end") | {iter, verdict, next_depth}' \
  runs/goal-session-<sid>/telemetry.jsonl

# Per-agent token usage and cost (requires CHAIN_TELEMETRY_TOKENS=true during run)
python3 scripts/automation/lib/analyze_telemetry.py runs/goal-session-<sid>/telemetry.jsonl

# Or as JSON for downstream tooling
python3 scripts/automation/lib/analyze_telemetry.py --json runs/goal-session-<sid>/telemetry.jsonl
```

## Stability

The schema is additive: new event types and new fields may be introduced in future versions. Consumers should ignore unknown event types and unknown fields.

The `event` field values listed above are stable — they will not be renamed or removed without a deprecation cycle.

## Pump-side economics (`lib/analyze_transcripts.py`, TOKEN-12)

`claude_usage` rows cover subagent dispatches only. The foreground pump's own turns — and
what actually fills a subagent's context — are visible only in the Claude Code session
transcript, so this read-only analyzer reads it directly:

```bash
python3 scripts/automation/lib/analyze_transcripts.py ~/.claude/projects/<slug>/<session>.jsonl [--json]
python3 scripts/automation/lib/analyze_transcripts.py --compare <A.jsonl> <B.jsonl>      # deltas, %
```

Pump side: usage-bearing turns (deduped by `message.id`, last snapshot wins), output /
cache_read / cache_creation / input totals, cache_read per turn (≈ the pump's context size),
per-tool call counts with average input and result bytes, Agent dispatches, **pump turns per
dispatch** (usage-bearing turns between consecutive Agent calls — the plumbing cost TOKEN-11a
attacks), resolved `message.model` per turn (EXP-6 records it), compaction events.
Subagent side (`toolUseResult.agentType` → `<session>/subagents/agent-<id>.jsonl`): invocations,
turns per invocation, output and cache_read per invocation, tool-result bytes by tool with
**image reads counted separately** (PNG bytes are not tokens), and the five largest tool results
with the first 80 chars of the input that produced them. Missing subagent transcripts are
skipped, never estimated.

Recorded PRE (2026-09-01, tapeology, largest session): pump 1,751 turns, 890M cache_read
(~508K/turn), 1.41M output, 325 dispatches, 5.4 pump turns per dispatch; developer 124
turns/inv, 39M cache_read/inv; evaluator 52 turns/inv; browser-qa 64 turns/inv with 13
screenshot read-backs.

## Permission economics (2026-09-04)

Every human permission prompt is a stall the autonomous pipeline cannot resolve on its own.
Two pieces close the loop: a log-only `PermissionRequest` recorder hook
(`hooks/permission-request-log.sh`, stage 1 of CAND-PERM-1 — no decision, no deny mode) and
a deterministic extension of the TOKEN-12 transcript analyzer
(`lib/analyze_transcripts.py`) that classifies every Bash tool-use result and derives
retry/stall/prompt metrics from it. A stage-2 deny mode is a separate, not-yet-built roadmap
experiment.

**Classification** (deterministic, from the transcript's `toolDenialKind` / `toolUseResult` /
gap between issue and result):

| class | rule |
|---|---|
| `hook_deny` (+ rule id) | `toolDenialKind == "permission-rule"` and content starts with `guard-`; rule id parsed from `guard-<name>: [<id>]`, `?` for pre-tag transcripts |
| `settings_deny` | `toolDenialKind == "permission-rule"` and content starts with `Permission to use` |
| `automode_deny` | `toolDenialKind in {"automode-blocked","automode-unavailable"}` |
| `user_deny` | `toolDenialKind == "user-rejected"` |
| `stall` | no `toolDenialKind`, not an error, `toolUseResult` has none of `timedOutAfterMs`/`backgroundTaskId`/`interrupted`, gap ≥ 600 s (a foreground Bash call cannot legitimately run that long without a timeout marker) |
| `ambiguous_gap` | same shape, 120 s ≤ gap < 600 s — reported, never counted as a stall |

**Metrics.** The sequence-dependent Bash metrics (`identical_command_retries`,
`same_rule_retries`, `retry_loops`) are derived **after the whole transcript is parsed**, from
Bash tool-uses in **issue order** (the order the assistant emitted them) joined with each
use's final classification — never from result-arrival order, which differs whenever one
turn issues several Bash calls or results land out of sequence. Bash commands are normalized
by collapsing whitespace before comparison.

| metric | definition | role |
|---|---|---|
| `post_denial_tool_turns` | denials (any class) whose next assistant row contains any tool_use | economics/behaviour only — a Read after a denied `sed` is recovery, not failure |
| `immediate_bash_retries` | Bash denials whose next assistant row contains a Bash tool_use | economics |
| `identical_command_retries` | denied Bash uses followed, within the next 3 Bash uses in issue order, by the identical normalized command (once per denial) | hard tripwire (0) |
| `same_rule_retries` | hook-denied Bash uses whose next Bash use in issue order is again hook-denied with the same rule id | tripwire (warn > 0) |
| `retry_loops` | maximal runs of ≥ 3 consecutive denied Bash uses in issue order (any denial class) | hard tripwire (0) |
| `human_prompts` / `prompt_outcomes` | count of `permission_request` events; outcome of the matching `tool_use_id`: `user_deny`, `allowed_after_wait` (gap ≥ 120 s), `allowed_fast`, `unmatched` | hard gate (0) once the recorder is proven live |
| `stalls`, `stall_seconds`, `ambiguous_gaps` | as classified above | hard gate (`stalls == 0`) |
| `fail_opens` (by reason), `malformed_event_rows` | tallied from the events file | diagnostics |

**The PermissionRequest recorder.** `hooks/permission-request-log.sh` is bound to Claude
Code's `PermissionRequest` event (log-only, stage 1 — see `.claude/architecture/skills-and-hooks.md`).
It pipes the hook's stdin JSON into `hooks/lib/hook_events.py --event permission_request`,
which appends one line to a session-scoped events file:

```
<cache>/iad/hook-events/<project-slug>/<session-id>.jsonl
```

Directories are created `0700` and files `0600` (explicit modes, tightened best-effort if
found wider). Each row is privacy-safe by construction: `session_id`, `agent_id`,
`agent_type`, `tool_use_id`, `tool_name`, `permission_mode`, plus (`permission_request` rows
only) `suggestion_count`, `suggestion_types`, and `suggestions_sha` (a hash of the raw
suggestion list, never the list itself). **No raw command text and no command hash are ever
recorded by default.** `IAD_HOOK_EVENTS_RAW=1` is an explicit, default-off diagnostic switch
that additionally records `cmd_raw` (the first 2000 chars of the Bash command) — opt-in only,
never set by the pipeline itself.

The analyzer reads that same file to compute `human_prompts` and `prompt_outcomes`:

```bash
python3 scripts/automation/lib/analyze_transcripts.py <pump-session.jsonl> \
  --events <cache>/iad/hook-events/<slug>/<session>.jsonl   # default: derived from the transcript path
python3 scripts/automation/lib/analyze_transcripts.py <pump-session.jsonl> --stall-gap 300  # override the 600s stall floor
```

`--events` defaults to one direct `open()` of the derived path above (never a directory
scan); a missing events file makes `human_prompts` / `malformed_event_rows` report `null`
rather than `0`, so a PRE session recorded before the recorder existed is never mistaken for
a session with zero prompts. `--stall-gap` overrides the 600 s `stall` floor only; the 120 s
`ambiguous_gap` lower bound is fixed.

Permission metrics are reported separately from token metrics on purpose: a session can be
token-cheap and permission-expensive (a human sitting on a dialog) or the reverse, and
conflating the two would hide either failure mode.
