---
description: Run Goal Mode until the goal is achieved or an existing rule halts/pauses it, inside this Claude Code session (interactive dispatch — bills to your interactive plan allowance).
argument-hint: "[session-id] [extra run-goal.sh flags]"
allowed-tools: Bash(./scripts/automation/run-goal.sh:*), Bash(scripts/automation/goal-await-dispatch.sh:*), Bash(jq:*), Bash(cat:*), Bash(ls:*), Bash(taskset:*), Read, Task, Write
---
You are the **pump** for goal mode. Run the EXISTING goal-mode engine until the
goal is achieved, blocked, halted, or paused by its existing rules. Do NOT add
new stop conditions or iteration limits — "until goal" is the intended default.

First read `.claude/skills/goal-interactive-dispatch.md` and follow it exactly.

1. **Session id:** parse `$ARGUMENTS`. The first token is the session id; if there
   is no first token, generate one like `interactive-<YYYY-MM-DD>-<short>` and
   tell the user what you chose. Any remaining tokens are passthrough flags.
2. **Host-guard check** (only when `project-extensions/host-guard/host-guard.env`
   exists with `HOST_GUARD_ENABLED=1` and `HOST_GUARD_REQUIRE_PUMP_CONFINED=1`):
   compare `taskset -cp $$` against `HOST_GUARD_CPU_LIST`. If this session's
   affinity is wider than the mask, STOP and tell the user to relaunch Claude
   Code via `scripts/automation/host-guard-exec.sh claude` — subagents and their
   Bash children inherit THIS session's cpuset, confinement can only be applied
   at launch, and the engine's iteration gate pauses (AWAITING_HOST_GUARD) on an
   unconfined pump, so starting now would waste a session.
3. **Launch the engine** in the background (Bash with run_in_background) and
   capture its PID:
   `./scripts/automation/run-goal.sh --session-id <sid> --interactive <passthrough flags>`
4. **Run the pump loop** from the skill: await requests with
   `scripts/automation/goal-await-dispatch.sh` (foreground, `--max-wait 500`),
   dispatch each returned request as a subagent (`subagent_type` = the request's
   `agent`, `prompt` passed verbatim; pass the request's `model` as the Agent
   tool's model parameter when present, otherwise no model override; prompts
   >8 KB go through the file-indirection wrapper in the skill), write the
   subagent's final message to the request's `out` path, then write each result
   file, and repeat until `ENGINE_DONE`. Dispatch concurrently-ready requests
   together in one message. Run the loop **QUIETLY**: reply with tool calls only —
   no narration of await/dispatch/result steps and no echoing of prompts or
   subagent text. Surface prose only at launch (the engine-log pointer), at
   pauses, and in the final status block. The full chain narrative is in the
   timestamped `runs/goal-session-<sid>/engine.log` (tell the user to `tail -f`
   it); you do not read it.
5. **On exit**, read `runs/goal-session-<sid>/session.json` and report the final
   `status` and the next step.

This runs the work as interactive subagents in THIS session (billed to your
interactive plan allowance), not as headless `claude -p`. Keep the session open
while it runs; if it stops, use `/goal-resume`. Intended for individual
development use — shared/team production automation should use the programmatic
path (`run-goal.sh` without `--interactive`) with an API key.
