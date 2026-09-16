# Troubleshooting

Operational failures with a known shape. Sections are added by the roadmap item
that ships the behavior they explain.

## Engine refuses to start — lock held (exit 86)

**Symptom:** `run-goal.sh` or `run-phase.sh` exits within seconds with

    [engine-lock] REFUSED: another engine for goal session 'x' is already running.
    [engine-lock]   lock : runs/goal-session-x/.engine.lock
    [engine-lock]   held : pid 12345 on myhost (age 240s) — process is alive (kill -0)

and exit code **86** (`ENGINE_LOCK_REFUSED_EXIT` — deliberately distinct from
70 = transport, 75 = quota, 130/137/143 = signals).

**What it means:** the REL-4 cross-session lock found a LIVE holder. One live
engine per goal session id (`runs/goal-session-<sid>/.engine.lock`) and one
phase pipeline per repo (`runs/.phase.lock`, held by every `run-phase.sh`
including goal-mode full-depth iterations) — two engines racing one repo used
to corrupt each other's worktree silently, so the second start now refuses
fast instead.

**How staleness is decided** (`scripts/automation/lib/engine-lock.sh` — the
doctor's `engine-lock` row uses the same verdict):

- **Same host:** `kill -0 <pid>`. Dead pid → stale. A live pid is also checked
  against the command recorded in the lock (`/proc/<pid>/cmdline`) so a pid
  RECYCLED after a crash/reboot cannot impersonate the holder; when the probe
  cannot run, the lock counts as fresh — a lock is never stolen on a maybe.
- **Other host:** liveness is unprovable, so age decides — older than
  `CHAIN_ENGINE_LOCK_CROSS_HOST_TTL` (default 86400s = 24h, longer than any
  plausible session including quota sleeps) → stale.
- **No metadata inside the dir:** the acquirer crashed mid-write or is still
  writing — younger than `CHAIN_ENGINE_LOCK_INIT_GRACE` (default 60s) → fresh,
  else stale.

**Stale locks fix themselves:** the next engine start replaces a stale lock
with one logged warning (`[engine-lock] WARNING: replacing stale lock …`). A
SIGKILLed or crashed session never costs more than that warning on restart.

**What to do when refused:**

1. Believe the message first. Find the holder: `ps -p <pid> -o cmd=`, or read
   `runs/goal-session-<sid>/engine.log` / `session.json`. If it is a session
   you want, let it run — or pause it properly (`/goal-pause <sid>`), which
   exits the engine and releases the lock.
2. Pauses and resumes need no lock care: every `AWAITING_*` pause exits the
   engine (releasing the lock) and `--resume` re-acquires it. A paused session
   can never block its own resume.
3. **Manual removal is the last resort**, only when the holder is provably
   gone on a host you cannot reach (cross-host TTL not yet expired):
   `rm -rf runs/goal-session-<sid>/.engine.lock` (or `runs/.phase.lock`).
   On the same host, prefer just re-running — the engine's own stale
   detection is stricter than a by-hand judgment.

**Preflight visibility:** `scripts/automation/doctor.sh --only engine-lock` —
PASS (no locks), WARN (fresh lock, names the holder — legitimate when a
session is running, including the one running the doctor), FAIL (stale lock).

## "port N is held by a process this session does not own" (service ownership)

**Symptom.** A run stops with `[services] BLOCKED (<role> startup): port <N> is required for the
<role> but is held by a process this session does not own`, followed by the holding pid and its
command line. Or a teardown logs `[services] kill refused (<caller>): port <N> is held by pid <P>
(<comm>) which is UNOWNED/FOREIGN`.

**What it means.** Since HARD-5 the framework terminates an app service only when
`/proc/<pid>/environ` proves *this* lifecycle started it. It is telling you, truthfully, that
something else owns that port. Before HARD-5 it would have run `fuser -k -9` and killed it —
which is how a goal session killed a live product backend and frontend on 2026-09-15.

**This is usually correct behaviour, not a bug.** The normal causes, in order:

1. **You started the stack yourself** (`scripts/dev.sh`, an IDE task, a product-side pump). If it
   is **healthy**, the framework reuses it and you will never see this message — the blocker only
   appears when the existing service is *unhealthy*, and the framework cannot fix someone else's
   broken service. Restart it yourself, then re-run.
2. **A second run on the same checkout.** Ports come from `sha1(project_root)`, so two concurrent
   runs of one project share them. `FOREIGN` names the other owner. Stop that run first.
3. **An orphan from a pre-HARD-5 run**, or from any process started outside the framework. It
   carries no ownership stamp so it is never reclaimed automatically. Stop it once, by pid:
   `kill <pid>` (the blocker message prints the pid and the command line). Everything started
   after this change is stamped, so this does not recur.

**What NOT to do.** Do not "fix" it with `fuser -k` or `pkill -f`. That is the defect this layer
removes: a port and a command line are not proof of ownership, and on a shared checkout they name
the operator's own services.

**Inspecting ownership.**

```bash
scripts/automation/lib/service-owner.sh status          # registry + this shell's scope
scripts/automation/lib/service-owner.sh classify 8319   # record state for a port
scripts/automation/lib/service-owner.sh owns 12345      # MINE|DEAD|FOREIGN|UNOWNED|UNREADABLE
scripts/automation/doctor.sh --only service-owners      # one PASS/WARN/FAIL row
```

**Registry problems.** The registry (`~/.cache/iad/services/<repo12>/`) is *observability*, not
the kill authority, so a corrupt registry can neither authorize an unsafe kill nor wedge a run. A
malformed record is reported by the doctor and removed with
`service-owner.sh repair <port>` after it prints the record for confirmation.

**Operator override in `scripts/dev.sh` only.** `dev.sh` refuses to clear a port it does not own
and prints the holder. Re-run it as `DEV_FORCE=1 ./scripts/dev.sh` to override deliberately for
that invocation. There is no equivalent switch anywhere in the pipeline: a knob that silently
restored blind termination would restore the incident.
