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
| `reason` | string | `BUDGET_EXHAUSTED` \| `STALLED` \| `REGRESSION_HALT` \| `ABORTED` |
| `detected_at_step` | string | Where the halt was detected (e.g., `pre_decomposer`, `post_evaluator`) |

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

Enabled by default headless; opt out with `export CHAIN_TELEMETRY_TOKENS=false`. To opt out of cache hygiene (`--exclude-dynamic-system-prompt-sections`): `export CHAIN_CLAUDE_DISABLE_CACHE_HYGIENE=true`.

Aggregate per-session and per-agent with:
```bash
python3 scripts/automation/lib/analyze_telemetry.py runs/goal-session-<sid>/telemetry.jsonl
```

### Timing / experiment events

| Event | Written by | Payload highlights |
|---|---|---|
| `step_skipped` | `goal-iter-lean.sh`, `run-goal.sh` | `{step, iter_name, reason:"checkpoint"}` — a resume reused a completed step instead of re-running it |
| `dispatch_wait` | `lib/interactive-dispatch.sh` | `{agent, wait_seconds, run_seconds, status, rc}` — pickup-wait vs run split per interactive dispatch attempt (`ok` \| `pickup-timeout` \| `inflight-timeout` \| `inflight-timeout-requeued`) |
| `review_verdict` | `goal-iter-lean.sh` | `{verdict, attempt, iter_name}` — reviewer outcome per attempt (feeds the tripwire) |
| `iter_config` | `run-goal.sh` | `{key, value}` — an opt-in experiment knob (e.g. `CHAIN_AGENT_EFFORT`) was active this iteration |
| `golden_coverage` | `goal-iter-lean.sh`, `browser-qa-phase.sh` (goal iterations) | `{passing, missing_goldens, iter_name}` — PASSing journeys still lacking a replay golden |
| `experiment_reverted` | `run-goal.sh` | `{key, value}` — the tripwire auto-reverted an experiment knob |

### `missing_evidence` (REL-11 tripwire)
Written when a dispatch returns — any exit code, including 0 — without its expected report artifact on disk: full-mode QA (`qa-phase.sh`), the lean browser-qa LLM lane (`goal-iter-lean.sh`; quota pauses excluded), and the retro-analyst (`run-goal.sh`). The telemetry counterpart of the loud `[missing-evidence]` stderr banner (`lib/common.sh` `warn_missing_evidence`). Non-blocking — a tripwire, never a gate.

| Field | Type | Description |
|---|---|---|
| `agent` | string | Dispatching agent whose report is missing (`qa` \| `browser-qa-agent` \| `retro-analyst`) |
| `path` | string | The expected report path that was absent |

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
iterations; `run-goal.sh` runs it each iteration while `CHAIN_AGENT_EFFORT` is
set and auto-reverts the knob on TRIP:

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
