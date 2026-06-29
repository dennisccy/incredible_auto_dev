---
description: Resume a paused or halted goal-mode session inside this Claude Code session (interactive dispatch).
argument-hint: "[session-id] [extra run-goal.sh flags]"
allowed-tools: Bash(./scripts/automation/run-goal.sh:*), Bash(scripts/automation/goal-await-dispatch.sh:*), Bash(jq:*), Bash(cat:*), Bash(ls:*), Read, Task
---
Resume an existing goal-mode session as the **pump**. Follow
`.claude/skills/goal-interactive-dispatch.md` exactly.

1. **Session id:** use the first token of `$ARGUMENTS`. If absent, list
   `runs/goal-session-*` and either ask which to resume or pick the most recent
   and state it. Remaining tokens are passthrough flags.
2. Check `runs/goal-session-<sid>/session.json` `status`. If it is
   `REGRESSION_HALT`, the engine requires `--acknowledge-regression`; if the user
   did not pass it, explain and stop rather than guessing.
3. **Launch the engine** in the background with `--resume` and capture its PID:
   `./scripts/automation/run-goal.sh --session-id <sid> --resume --interactive <passthrough flags>`
   (run-goal.sh clears stale dispatch files on start; resuming from a blueprint
   pause counts as approval of `state/blueprint.md`. If a prior engine for this
   session is still running — e.g. you Ctrl+C'd the pump but the detached engine
   kept going — run-goal.sh stops it cleanly first, so it is safe to just resume.)
4. **Run the pump loop** until `ENGINE_DONE`, then read
   `runs/goal-session-<sid>/session.json` and report the final `status`. Run the
   loop **QUIETLY** per the skill — tool calls only, no narration; the full
   timestamped chain log is at `runs/goal-session-<sid>/engine.log` (tell the user
   to `tail -f` it).

Like `/goal`, this runs the work as interactive subagents in this session. Keep
the session open while it runs.
