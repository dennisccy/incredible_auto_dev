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
   **Distinguish a machine reset from an orphan.** Compare the pid file's mtime
   against this boot: `ls -l --time-style=+%s runs/goal-session-<sid>/engine.pid`
   versus `awk '/^btime /{print $2}' /proc/stat`. A pid file written BEFORE the
   boot means the machine went down under the engine — a hardware event, not
   something the session did wrong. Report it that way, with:
   - **when** it died — the last pre-boot row of `~/.cache/iad/host-guard/hwmon/hwmon.csv`
     (or `logs/hwmon/hwmon.csv`), which is fsync'd per second and outlives the journal;
   - **what it was doing** — `current_iter` from `session.json` plus the last line
     of `runs/goal-session-<sid>/telemetry.jsonl`, and the machine-wide ledger
     `~/.cache/iad/host-guard/events.jsonl` for the cross-repo picture;
   - **why** — `scripts/automation/host-guard/reset-forensics.sh check` and the
     postmortem at `~/.cache/iad/host-guard/postmortems/latest.md`.
   Then point at `/goal-resume <sid>`, which clears the stale locks itself. Say
   plainly that a reset of this class is a hardware fault (see `docs/host-guard.md`
   § After a hardware reset), so resuming is safe and the iteration is not lost.
6. Summarize plainly whether the session is **running**, **paused** (and exactly
   how to resume — e.g. review the blueprint then `/goal-resume`; for
   `AWAITING_INTENT_REVIEW` point at `runs/goal-session-<sid>/intent-review.md`,
   the opt-in `--intent-checkpoint` "is this the product you wanted?" pause —
   resuming acknowledges it), **orphaned** (dead engine PID — `/goal-resume`),
   or **finished** (and the final verdict).
7. **Plain words first:** lead the summary with the status translated into a
   plain sentence (the wording table lives in `docs/READING-REPORTS.md`), with
   the raw code in parentheses — e.g. "The chain is paused and waiting for your
   blueprint review (`AWAITING_BLUEPRINT_APPROVAL`)." Same for the last verdict.
