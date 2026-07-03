---
description: Run exactly ONE more goal-mode iteration, then stop — reuses the engine's existing --max-iter cap (adds no new stop rule). Interactive dispatch.
argument-hint: "[session-id]"
allowed-tools: Bash(./scripts/automation/run-goal.sh:*), Bash(scripts/automation/goal-await-dispatch.sh:*), Bash(jq:*), Bash(cat:*), Bash(ls:*), Read, Task, Write
---
Run a **single** goal-mode iteration as the pump, then stop. This adds no new
stop rule — it caps the existing budget at one beyond the current iteration, so
the engine halts itself with `BUDGET_EXHAUSTED`. Follow
`.claude/skills/goal-interactive-dispatch.md`.

1. **Session id:** use the first token of `$ARGUMENTS`. If absent, pick the most
   recent `runs/goal-session-*` and state it.
2. Determine `current_iter`: read it from `runs/goal-session-<sid>/session.json`
   (treat a missing session as `0`).
3. **Launch the engine** in the background, capping iterations one beyond current,
   and capture its PID:
   - existing session: `./scripts/automation/run-goal.sh --session-id <sid> --resume --interactive --max-iter <current_iter+1>`
   - brand-new session: same without `--resume` (this runs the baseline iteration;
     the blueprint is auto-approved by default, so the one-beyond cap stops it).
4. **Run the pump loop** until `ENGINE_DONE`. Run it **QUIETLY** per the skill —
   tool calls only, no narration; the full timestamped chain log is at
   `runs/goal-session-<sid>/engine.log` (tell the user to `tail -f` it).
5. Report the iteration's verdict and how to continue (`/goal` to run to the goal,
   or `/goal-step` again for one more iteration).
