---
description: Show the status of a goal-mode session (current iteration, last verdict, pause/halt state, dispatch activity) — read-only, never launches the engine.
argument-hint: "[session-id]"
allowed-tools: Bash(jq:*), Bash(cat:*), Bash(ls:*), Bash(find:*), Read
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
5. Summarize plainly whether the session is **running**, **paused** (and exactly
   how to resume — e.g. review the blueprint then `/goal-resume`), or **finished**
   (and the final verdict).
