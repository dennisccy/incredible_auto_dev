# Feedback (placeholder)

This directory is reserved for the **self-evolution loop** — a future capability where the framework reads telemetry from goal-mode runs (in this and downstream projects) and proposes its own improvements as PRs against this repository.

That loop is **not implemented yet**. The current goal-mode pipeline only writes telemetry locally to `runs/goal-session-<sid>/telemetry.jsonl`. Nothing is exported from a project; nothing is sent to this repo automatically.

## What is implemented today (Part A)

- Goal mode emits structured JSONL telemetry per session — see [`docs/goal-mode-telemetry.md`](../docs/goal-mode-telemetry.md) for the schema.
- The data stays local to the project running goal mode.

## What is deferred (Part B, separate plan)

- An opt-in `--telemetry github` flag on `run-goal.sh` that posts a sanitized digest of the JSONL as a GitHub issue or `feedback/incoming/` PR against this repo.
- A `framework-improvement-proposer` agent that periodically reads accumulated `feedback/incoming/` and proposes targeted changes to `.claude/agents/*.md`, `.claude/anti-patterns.md`, default halt config, etc.
- PR-only application: the proposer's output is always a PR against `main`, never a direct commit. Existing reviewer/auditor agents review it. A human merges. There is no auto-merge of framework changes.

These were intentionally deferred because:
1. There is no telemetry to learn from yet — Part B before Part A is premature.
2. Self-modifying framework code on a tool used by humans needs deliberate review-gate design.
3. Sanitized export needs a careful privacy review (never leak code, paths, or secrets).

## When this folder will activate

After the framework has accumulated multiple sessions of real telemetry from real projects and there is a clear signal of patterns worth automating. Until then this README is the only file that lives here.
