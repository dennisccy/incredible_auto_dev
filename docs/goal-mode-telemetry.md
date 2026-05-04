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
| `max_iterations` | number | Configured cap |
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
| `duration_seconds` | number | (end only) Wall time |
| `retries` | number | (end only) Quota-retry count for this invocation |

### `quota_pause_start`, `quota_pause_end`
Recorded around quota-exhaustion sleeps inside `claude_with_quota_retry`.

| Field | Type | Description |
|---|---|---|
| `agent` | string | Agent that triggered the pause |
| `sleep_seconds` | number | (end only) Total seconds slept |

> Note: The quota-pause events are recorded by goal-mode wrapper logic in `run-goal.sh` and `goal-iter-lean.sh`, not by `lib/quota-retry.sh` directly (so phase mode is unaffected). The wrapper observes the script's exit/retry behavior and emits these events when the wrapper detects a quota-retry path was taken.

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
```

## Stability

The schema is additive: new event types and new fields may be introduced in future versions. Consumers should ignore unknown event types and unknown fields.

The `event` field values listed above are stable — they will not be renamed or removed without a deprecation cycle.
