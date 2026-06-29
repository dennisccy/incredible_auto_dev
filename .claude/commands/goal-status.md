---
description: Show the status of a goal-mode session (current iteration, last verdict, pause/halt state, dispatch activity) — read-only, never launches the engine.
argument-hint: "[session-id]"
allowed-tools: Bash(jq:*), Bash(cat:*), Bash(ls:*), Bash(find:*), Bash(kill:*), Read
---
Report the status of a goal-mode session. This is **read-only**: do NOT launch
the engine, dispatch agents, or write anything.

1. **Session id:** use the first token of `$ARGUMENTS`. If absent, list
   `runs/goal-session-*` and pick the most recently modified one (state which).
2. Read `runs/goal-session-<sid>/session.json` and report: `current_iter`,
   `status`, `last_verdict`, `next_depth`, `agent_backend`, and `cli`.
3. Read the latest `runs/goal-session-<sid>/iter-*/eval.md` (highest N) and
   summarize its `**Verdict:**` line.
4. If `runs/goal-session-<sid>/dispatch/` exists, note whether a dispatch is in
   flight (a `req.*.ready` with no matching `.res`), which agent it is for, and
   whether an `.awaiting-pump` marker is present.
5. **Engine liveness:** if `runs/goal-session-<sid>/engine.pid` exists, read the
   PID and test it with `kill -0 <pid>`. A live PID means the engine is genuinely
   running; a dead PID with `status: in_progress` means the engine was
   interrupted/orphaned (e.g. a Ctrl+C that never reached the detached engine) —
   say so and point to `/goal-resume <sid>`. Also point the user at the full
   timestamped log: `tail -f runs/goal-session-<sid>/engine.log`.
6. Summarize plainly whether the session is **running**, **paused** (and exactly
   how to resume — e.g. review the blueprint then `/goal-resume`), **orphaned**
   (dead engine PID — `/goal-resume`), or **finished** (and the final verdict).
