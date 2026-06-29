---
description: Pause a running goal-mode session by cleanly stopping its (possibly detached) engine, leaving a resumable checkpoint. Use after Ctrl+C to make changes, then /goal-resume.
argument-hint: "[session-id]"
allowed-tools: Bash(cat:*), Bash(jq:*), Bash(ls:*), Bash(grep:*), Bash(kill:*), Bash(sleep:*), Read
---
Cleanly **pause** a goal-mode session. In interactive mode the engine runs as a
detached background process, so pressing Ctrl+C in the pump stops the pump but NOT
the engine — this command signals the engine to checkpoint and exit promptly. This
is **read + signal only**: never launch the engine, dispatch agents, or write
session files yourself (the engine's own `on_abort` writes the checkpoint).

Typical flow: Ctrl+C the running `/goal` to reclaim the prompt → `/goal-pause <sid>`
→ make your changes → `/goal-resume <sid>`.

1. **Session id:** first token of `$ARGUMENTS`. If absent, list `runs/goal-session-*`
   and pick the one with a live `engine.pid` (state which); if none is live, say the
   session is already stopped and exit.
2. **Find the engine:** read `runs/goal-session-<sid>/engine.pid`. If the file is
   missing, or `kill -0 <pid>` fails, or `/proc/<pid>/cmdline` does not contain
   `run-goal` (stale/reused PID), report that nothing is running for this session
   and stop — it is already paused/finished.
3. **Stop it cleanly:** send `kill -TERM <pid>`. This fires the engine's `on_abort`,
   which writes an `ABORTED` checkpoint (`current_iter` preserved) and exits in
   about a second. Poll `kill -0 <pid>` a few times with short `sleep`s (up to ~10s);
   if it is still alive, send `kill -KILL <pid>` as a fallback (the session stays
   resumable via `current_iter`, just without the tidy summary).
4. **Report:** read `runs/goal-session-<sid>/session.json` and tell the user the
   paused `current_iter` and `status`, and that resuming re-runs that in-flight
   iteration — so edits to `docs/goal.md` or the code made now will take effect.
   Resume with `/goal-resume <sid>`.

Note: only `SIGTERM` produces the clean checkpoint; killing the background task from
the client UI may `SIGKILL` and skip the summary. Prefer this command.
