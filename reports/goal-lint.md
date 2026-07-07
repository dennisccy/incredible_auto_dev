# goal-lint report — docs/goal.md

Run: 2026-07-07 · deterministic exit: 2 · semantic findings: 2

## Deterministic lint (goal_lint.py)

```
[goal-lint] ERROR no-journeys: no '- **J-NN: ...**' journey blocks found — see templates/project-goal.md
[goal-lint] docs/goal.md: 1 error(s), 0 warning(s) — advisory: lint never blocks the engine (CHAIN_GOAL_LINT=false to silence)
```

## Semantic findings

### Risky surface with no anti-goal coverage — line 18
> 4. Supply-chain security gates for all package installations
- **Problem:** the file names security-sensitive surfaces (package installation here, "security controls" on line 11) but contains no `## Anti-goals` section at all, so if goal mode were ever run against this file the evaluator would have zero veto rules bounding installs, network calls, or secrets.
- **Suggested rewrite:** add at the end of the file:

  ```markdown
  ## Anti-goals

  - No package installation bypasses the supply-chain security gate.
  - No secrets, API keys, or tokens committed to the repository.
  - No paid external services invoked by the pipeline without explicit user approval.
  ```

### Unmeasurable success criteria — line 7
> Provide a reusable, quality-gated, multi-agent development pipeline that automates phased software development using Claude AI agents.
- **Problem:** the file has no `## Success Criteria` section and no other measurable outcome — "reusable" and "quality-gated" give the evaluator nothing observable to score against.
- **Suggested rewrite:** add after `## Vision`:

  ```markdown
  ## Success Criteria

  - `./scripts/automation/run-evals.sh` exits 0 (all offline evals pass) on every commit to main.
  - A phase run on a template project completes all 11 steps and ends with an audit verdict of PASS.
  - A goal-mode session on a template project reaches GOAL_ACHIEVED with every Must-have journey passing.
  ```

## Summary

This `docs/goal.md` is intentionally meta: it describes the framework repository itself and tells adopting projects (lines 29-33) to replace it — it is documentation, not a runnable goal-mode contract, and `run-goal.sh` would abort on it at `validate_goal_file` (no journeys, no anti-goals). That is fine as long as nobody points goal mode at this repo. Highest-impact fix if goal mode should ever run here: author a real contract with `/goal-init` (journeys + anti-goals); otherwise the two rewrites above are optional hardening of the meta file.
