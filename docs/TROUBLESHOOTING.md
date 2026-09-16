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

## "port N answers but could not be verified as the expected backend/frontend"

**Symptom.** A run stops with `[services] BLOCKED (<role> reuse verification)` and
`port N answers (status 200) but this session cannot verify it is the expected <role>`.

**What it means.** Something is already serving on the port, this session did not start it, and
the project has not said how to recognise it. A 2xx proves a socket is open — not that it is your
API, and not that it runs the revision under test. Rather than test an unknown service, the run
stops. It does **not** kill the listener and does **not** move to another port (that would break
frontend/backend pairing and silently test something else).

**Fix, in order of preference.**

1. **Declare the contract** in `.claude/project-template.md` (section "Service reuse contract"):
   `CHAIN_SERVICE_VERIFY_BACKEND` / `CHAIN_SERVICE_VERIFY_FRONTEND`. The command gets the response
   body on stdin and `<url> <port>` as arguments; exit 0 means "this is the expected service".
   Pin the build where you can, so a stale external instance is rejected rather than accepted.
2. **Let the framework own it**: stop your own stack and re-run. A service the run starts is
   registered, reused while its revision matches the working tree, and restarted when it does not.
3. **Move your stack off the project's offset ports** if you want it running alongside.

**Related: "is ours but not current — restarting it".** Not an error. The service this run started
is serving an older revision than the working tree (the developer agent changed code), so it is
being replaced. Without this a phase would verify the tree as it was *before* the fix.

**Related: services staying up between phases.** Also intended. Ownership permits termination;
lifecycle policy does not require it. A healthy application service on the current revision now
survives phase boundaries, iteration boundaries and Goal Mode completion — look for
`services_preserved` in telemetry. Only ephemeral services (an agent's abandoned verification
server) and services needing a verified restart are reaped.

## Configuring the service contracts (where they actually live)

`.claude/project-template.md` is sliced into agent **prompts**. Nothing sources it, so a contract
declared only there never reaches the shell that enforces it. The runtime mechanism is a file the
framework sources from `ensure_phase_ports`, before anything probes, reuses or tears down a
service:

```bash
cp incredible_auto_dev/templates/service-contracts.sh .claude/service-contracts.sh
$EDITOR .claude/service-contracts.sh
```

```bash
export CHAIN_SERVICE_VERIFY_BACKEND='jq -e ".service == \"myapp-api\""'   # body on stdin
export CHAIN_SERVICE_HEALTHY_BACKEND='^(2|3|404)'                        # only if not 2xx/3xx
```

Values already in the environment win, so CI or an operator can override one run without editing
the file. `CHAIN_SERVICE_CONTRACTS_FILE` relocates it. Check what a run actually picked up:

```bash
bash -c 'REPO_ROOT=$PWD; source incredible_auto_dev/scripts/automation/lib/service-owner.sh;
         service_contracts_load; echo "${CHAIN_SERVICE_VERIFY_BACKEND:-<unset>}"'
```

## "status 500 ... does not satisfy the health contract"

Reachability, identity and health are three different questions and the framework now keeps them
apart:

| Question | Mechanism | Default |
|---|---|---|
| Is a socket open and speaking HTTP? | the boot gate's readiness regex | permissive — any status (`^[1-5][0-9][0-9]$` for the backend), because some projects have no `/health` route |
| Is it the service we expect? | `CHAIN_SERVICE_VERIFY_<ROLE>` | none — an unowned service without a contract fails closed |
| Is the application actually serving? | `CHAIN_SERVICE_HEALTHY_<ROLE>` | `^[23]` |

A service returning 500 is reachable but **not healthy**, so it is not preserved across a phase
boundary and not reused as a satisfied dependency — it is restarted. If your application's valid
readiness response genuinely is not 2xx/3xx, say so explicitly with
`CHAIN_SERVICE_HEALTHY_<ROLE>`; the framework will not infer it, because inferring it is what let
a 500 pass as healthy.

## "the ownership record describes a service that is no longer the listener"

A registered service exited and something else took its port. The record's `persistent` lifecycle
and recorded revision describe the process that is gone, so they are **not** applied to whatever
is there now — otherwise an agent's abandoned verification server would be preserved as the
application and reused as the dependency simply because it answers 200 and the working tree has
not changed. The current occupant is treated as ephemeral: reaped if this session owns it,
refused if not. The stale record is dropped. Nothing is wrong; this line is the framework
declining to believe a record it can no longer tie to a live process.
