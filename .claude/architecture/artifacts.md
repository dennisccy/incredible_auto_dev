# Artifacts

All inter-agent communication happens through filesystem artifacts. The runtime-routed
artifact tables — core pipeline, UI visibility (6 per phase), and goal-mode artifacts,
each with producers and consumers — are maintained ONCE in `.claude/workflow.md`
(§Communication Model and §Goal Mode Pipeline): that is the copy agents read, and it
wins on any disagreement. This document adds only what workflow.md does not carry —
the showcase/security artifact inventory, backend-only stubs, and the goal-mode
schemas.

## Showcase, Security, and Standalone Artifacts

| Artifact | Path | Producer | Consumers |
|----------|------|----------|-----------|
| UI audit report | `reports/qa/<phase>-ui-audit.md` | ui-audit-phase.sh | qa (standalone) |
| Browser evidence | `reports/qa/<phase>-evidence/*.png` | browser-qa-agent | phase-closure-auditor |
| Iteration summary (MD) | `reports/phase-<phase>-iteration-summary.md` | iteration-summarizer | render_iteration_summary.py, human |
| HTML iteration summary | `reports/phase-<phase>-summary.html` | render_iteration_summary.py | human |
| Goal-mode session index | `reports/goal-session-<sid>-index.html` | render_iteration_summary.py | human |
| Demo script (executable JSON) | `reports/phase-<phase>-demo.json` | demo-narrator | demo_runner.py |
| Demo script (captions) | `reports/phase-<phase>-demo-script.md` | demo_runner.py | render_iteration_summary.py, human |
| Demo results | `reports/phase-<phase>-demo-results.md` | demo_runner.py | render_iteration_summary.py, human |
| Demo screenshots | `reports/demo/<phase>/step-NN.png` | demo_runner.py | render_iteration_summary.py |
| Cumulative project story | `runs/goal-session-<sid>/state/project-story.md` | iteration-summarizer (goal mode) | render_iteration_summary.py, human |
| Delivered wrap (MD) | `reports/goal-session-<sid>-delivered.md` | iteration-summarizer (delivered mode, GOAL_ACHIEVED only) | render_iteration_summary.py, human |
| Delivered wrap (HTML) | `reports/goal-session-<sid>-delivered.html` | render_iteration_summary.py (`delivered` command) | human |
| Install decisions | `reports/security/install-decisions.jsonl` | install-security-gate.sh | human review |

## Verdict Formats

Machine-parsed: every verdict is a `**Verdict:**` line with an exact value. The
complete vocabulary lives in code — `scripts/automation/lib/verdicts.py` (one enum per
report class) — validated at write time by `lib/artifact_schemas.py`. The runtime-routed
prose copy of the core report classes is `.claude/workflow.md` §Verdict Formats; each
emitting agent's body names its own enum values (enforced by `lib/lint_contracts.py`).
Emit verdict lines EXACTLY as those sources specify.

## Backend-Only N/A Stubs

When `Frontend Present: no`, the pipeline writes N/A stub files for the 6 UI visibility artifacts automatically via `write_na_ui_artifacts()` in `lib/common.sh`. These stubs:

- Contain the phase number and a "Backend-only phase" status line
- Are accepted by the phase-closure-auditor as valid for backend-only phases
- Are written only if the file does not already exist (no overwriting)

## Goal-Mode Artifacts

Goal mode adds a parallel artifact tree under `runs/goal-session-<sid>/`. Per-iteration code/test artifacts still use the existing `runs/<iter-name>/` and `reports/...<iter-name>...` paths, where the iteration name `goal-<sid>-iter-<N>` is treated as a "phase name" — so all phase-mode artifacts are produced for goal-mode iterations too. The goal-mode artifact table and both verdict tables (evaluator + loop-level halts) live in `.claude/workflow.md` §Goal Mode Pipeline. Not listed there:

| Artifact | Path | Producer | Consumers |
|----------|------|----------|-----------|
| Goal spec (extended) | `docs/goal.md` (with Must-have user journeys + Anti-goals sections) | Human | goal-decomposer, goal-evaluator, all phase agents |
| History hashes | `runs/goal-session-<sid>/.history-hashes` | run-goal.sh | run-goal.sh (stall detection) |

### journey-history.json schema

```json
{
  "journeys": {
    "J-01": {
      "id": "J-01",
      "name": "Sign up and log in",
      "status": "passing | failing | partial | already_passing | regressed | unknown",
      "last_verified_iter": "goal-<sid>-iter-<N>",
      "last_passing_iter": "goal-<sid>-iter-<N> | null",
      "first_seen_iter": "goal-<sid>-iter-<N>",
      "last_evidence_path": "reports/qa/<iter-name>-evidence/UT-J-01-*.png"
    }
  },
  "anti_goal_violations": [
    {
      "iter": "goal-<sid>-iter-<N>",
      "anti_goal": "verbatim text from goal.md",
      "severity": "critical | minor",
      "evidence": "file:line or commit description",
      "resolved": false
    }
  ],
  "updated_at": "<ISO timestamp>"
}
```

### Telemetry schema

See [`docs/goal-mode-telemetry.md`](../../docs/goal-mode-telemetry.md). Each line of `telemetry.jsonl` is one JSON object with common fields (`ts`, `session_id`, `iter`, `event`) plus event-specific fields. Stable across schema versions: consumers should ignore unknown event types and unknown fields.

### Goal-mode verdicts

Evaluator verdicts (`GOAL_ACHIEVED` / `CONTINUE` / `ESCALATE` / `REGRESSION` /
`STALLED`) and the loop-level halt verdicts are specified in `.claude/workflow.md`
§Goal Mode Pipeline (vocabulary: `lib/verdicts.py` `GoalEvalVerdict`).
