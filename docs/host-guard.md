# Host-guard — hardware protection for goal-mode load

Some hosts (small-form-factor mini-PCs especially) hard-reset under the bursty
all-core load an autonomous dev chain generates: an instant power/VRM/thermal
transient trip, with nothing in the journal. Host-guard is the framework's
opt-in defense: a project declares resource ceilings, and every heavy execution
path respects them. **With no declaration, every hook is a byte-for-byte no-op**
— the framework stays project-neutral.

## Activation contract

Create `project-extensions/host-guard/host-guard.env` in the project repo —
plain `KEY=VALUE` bash assignments, `HOST_GUARD_*` names only. Machine-specific;
do not copy between checkouts. `HOST_GUARD_ENABLED=0` (or deleting the file)
disables everything.

| Knob | Meaning | Typical |
|---|---|---|
| `HOST_GUARD_ENABLED` | Master switch | `1` |
| `HOST_GUARD_CPU_LIST` | SMT-aware affinity mask for all heavy work | `"0-3,8-11"` |
| `HOST_GUARD_BLAS_THREADS` | OMP/OpenBLAS/MKL/numexpr cap per process | physical cores in mask |
| `HOST_GUARD_CPUQUOTA` | systemd scope average-CPU backstop | `"800%"` |
| `HOST_GUARD_MEMORY_HIGH` | scope memory ceiling (reclaim/throttle, no OOM-kill) | `"14G"` |
| `HOST_GUARD_TASKS_MAX` | fork-storm bound | `2048` |
| `HOST_GUARD_REQUIRE_PUMP_CONFINED` | verify + auto-confine the interactive pump session each iteration | `1` |
| `HOST_GUARD_ADOPT` | `0` disables the in-place auto-confine (pause immediately instead) | `1` (default) |
| `HOST_GUARD_CLI_PATTERN` | regex matching the CLI process when walking up to the session root | `claude\|codex` (default) |
| `HOST_GUARD_REQUIRE_MARKERS` + `HOST_GUARD_MARKER_FILES` | require HOST-GUARD cap blocks in listed launcher scripts | project-specific |
| `HOST_GUARD_TCTL_PAUSE` / `_RESUME` / `_MAX_WAIT` | thermal gate thresholds (°C, °C, s) | `90` / `80` / `1800` |
| `HOST_GUARD_SAMPLER_INTERVAL` / `_MAX_BYTES` | forensics sampler cadence / csv ring size | `1` / `10485760` |
| `HOST_GUARD_BROWSER_CONFINE` | `0` disables the QA-browser confinement pass | `1` (default) |

## Machine-global aggregate budget

Everything in the table above bounds **one session**. That is not the same as
bounding the machine, and the difference is not academic:

> On 2026-07-29 at 14:02:45 the reference host hard-reset with two goal modes
> running under *complementary* masks — `0-3,8-11` and `4-7,12-15`. Each session
> passed every check it had. Their union was all 16 CPUs: every physical core
> available to a single burst. The memory ceilings had the same shape, 14G + 14G
> against 27.3G of RAM. **Complementary masks are not a safety property — they
> are a guarantee that the machine can be fully lit.** (Earlier revisions of this
> document recommended them. That advice was wrong and is retracted.)

So a second file, owned by the machine rather than by any repo, declares what
*all* guarded sessions may consume together:

```bash
# ~/.config/iad/host-guard-host.env   (never committed to any project)
HOST_GUARD_GLOBAL_CPU_LIST="0-3,8-11"   # every session's mask must be a SUBSET
HOST_GUARD_GLOBAL_MEMORY_BUDGET="22G"   # Σ over projects of max(MemoryHigh)
HOST_GUARD_REQUIRE_BOOST_OFF=1          # /sys/.../cpufreq/boost must read 0
HOST_GUARD_MAX_ENGINES=1                # concurrent goal engines (absent = unlimited)
```

`HOST_GUARD_MAX_ENGINES` caps how many goal-mode engines may run at once across
the whole machine. Over the cap, the **junior** engine takes the ordinary
resumable `AWAITING_HOST_GUARD` pause and continues when the senior finishes;
the senior only warns. Absent ⇒ unlimited.

It exists for one situation: a host whose resets turn out to be **hardware**
(see § After a hardware reset). Nothing a guard can do prevents those, so a
narrower CPU mask is theatre — but be clear-eyed that this knob is not a fix
either. It buys **exposure time, not prevention**: fewer hours under load means
fewer chances to trip, and nothing more. On the incident host the fault fired at
load 1.53 as readily as under two concurrent sessions, so the cap was released
within hours in favour of the real remediation. Its durable use is narrower and
better: pinning a soak week to a single project so one variable moves at a time.

Every guarded context publishes a record (pid, start time, boot id, project,
mask, memory ceiling) into a registry under
`${CHAIN_TMP_ROOT:-~/.cache/iad}/host-guard/registry/`, so any session can see
the whole machine. Preflight and every iteration boundary then check:

1. CPU **boost** is off (when required) — see *Boost persistence* below;
2. this session's mask ⊆ the global list — a violation always pauses, seniority
   does not excuse a misconfigured session;
3. the **union** of all live masks ⊆ the global list (checked explicitly, so a
   hand-edited record or a session started before this feature still trips it);
4. the per-project memory ceilings sum within the budget. Memory is summed as
   *max per project*, because a project's engine scope and its adopted-pump
   scope are separate cgroups carrying the same ceiling — a naive sum would
   double-count every project.

**Who yields.** Sessions register *before* they verify, so two engines starting
at the same instant each see the other. Both then compute the same loser from a
total order — `(epoch, start time, pid)` — and the junior one pauses
`AWAITING_HOST_GUARD` while the senior logs a warning and continues. There is no
lock, and no outcome where both pause or neither does.

**Staleness is pid-based, never time-based.** A record dies when its pid is gone,
when the pid was recycled (start time differs), or when the boot id no longer
matches. Iteration gaps here are legitimately unbounded — a thermal cooldown can
last 30 minutes — so an mtime TTL would evict live sessions.

Absent budget file ⇒ enforcement off, exactly as before. The registry is still
maintained, and once two *different* projects are guarded simultaneously the
engine says so loudly rather than pretending the machine is bounded.

A future `narrow` conflict mode (re-exec the junior session inside the remaining
budget instead of pausing) is deliberately **not** implemented: an already-running
pump tree cannot be narrowed safely mid-session.

## Boost persistence

The guard verifies its own premises. CPU boost was disabled on this class of host
as a hardware mitigation, applied live — and silently reverted at the next reboot
because the persistence rule was never installed. Nothing noticed for a day. With
`HOST_GUARD_REQUIRE_BOOST_OFF=1` a re-enabled boost now pauses the engine.

```bash
echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost
printf 'w /sys/devices/system/cpu/cpufreq/boost - - - - 0\n' \
  | sudo tee /etc/tmpfiles.d/cpufreq-boost.conf
sudo systemd-tmpfiles --create /etc/tmpfiles.d/cpufreq-boost.conf
cat /sys/devices/system/cpu/cpufreq/boost      # must print 0
```

`scripts/automation/doctor.sh --only cpu-boost` reports both the live knob and
whether the rule that survives a reboot exists.

## After a hardware reset — root-cause runbook

**Read this before tightening anything.** On 2026-07-30 17:14:08 this host reset
with every host-guard mitigation in force: both projects inside `0-3,8-11`,
10G+10G against a 22G budget, boost off and persisted, QA browsers confined,
both engines registered in the machine-global registry, every check green. At
T-1s the 1 Hz sampler recorded 65 °C, 26 W, load 6.54, 11.5 GB free, memory PSI
0.00. The cause was never visible to any software check — the CPU printed it on
the next boot:

```
x86/amd: Previous system reset reason [0x08000800]: an uncorrected error
         caused a data fabric sync flood event
```

A data fabric sync flood is an **uncorrectable SoC/Infinity-Fabric error**. The
hardware asserts reset immediately; the kernel is never notified, so there is no
panic, no OOM, no thermal event and no log — which is exactly why six earlier
resets were misread as load problems. Seven of the last ten boots carried a
fault-class line, and one of them fired at load 1.53 and 22 W: this is hardware
**marginality**, not a load limit. Concurrency only changes how often it trips.

The chain's job is therefore to surface, preserve, recover and cap — never to
pretend it can prevent this:

```bash
scripts/automation/host-guard/reset-forensics.sh check       # what the platform says
scripts/automation/host-guard/reset-forensics.sh report      # the newest postmortem
scripts/automation/doctor.sh --only reset-reason             # same verdict as a row
```

Every engine preflight writes one idempotent bundle per dead boot into
`~/.cache/iad/host-guard/postmortems/<boot-id>.md`: the verbatim reset line, the
fault streak, the registry records naming which projects and sessions were
running, the final pre-reset second of hardware telemetry from every sampler,
those sessions' telemetry/engine-log tails, and the machine-wide event ledger.
Run it **before** resuming a session — the preflight registry sweep is what
erases the "who was running" evidence.

### Fixing it (all need root; run them yourself, one change per soak week)

```bash
# 1. journald syncs every 5 min by default — the 07-30 reset erased the final
#    3m42s of journal. 15 s keeps the tail.
sudo mkdir -p /etc/systemd/journald.conf.d \
  && printf '[Journal]\nSyncIntervalSec=15s\n' | sudo tee /etc/systemd/journald.conf.d/99-iad-sync.conf \
  && sudo systemctl restart systemd-journald

# 2. rasdaemon records the memory/fabric error itself (address, DIMM) — this is
#    what turns "sync flood" into an actionable RMA or firmware bug report.
sudo apt-get install -y rasdaemon && sudo systemctl enable --now rasdaemon

# 3. One-time: firmware crash records the kernel could not write.
sudo sh -c 'ls -la /sys/fs/pstore/ && head -c 4000 /sys/fs/pstore/* 2>/dev/null'

# 4. BIOS/AGESA age is the single most common fix for this signature.
sudo dmidecode -s bios-version && sudo dmidecode -s bios-release-date

# 5. The definitive DRAM check — run a full pass overnight.
sudo apt-get install -y memtest86+ && sudo update-grub
```

Then, in this order, one per week so causality stays readable: **update the
BIOS**; set memory to **baseline JEDEC** instead of the EXPO/XMP profile; if
memtest reports errors, reseat/swap the SO-DIMM and RMA. A commonly reported
workaround for this signature is limiting deep C-states (it costs idle power and
reverts on reboot):

```bash
for f in /sys/devices/system/cpu/cpu*/cpuidle/state[2-9]/disable; do echo 1 | sudo tee "$f" >/dev/null; done
```

2026-08-07, this host: that loop is now PERSISTENT via the root unit
`/etc/systemd/system/iad-cstate-limit.service` (re-applied at boot and on
resume from sleep). The volatile form above kept evaporating on the ~daily
fault resets, so it never actually soaked — `host_state` events in the machine
ledger recorded `cstate_disabled` all zeros through five more resets (Aug 4–7).
Soak journal: `~/.cache/iad/host-guard/soak-log.md`.
Enabled + verified 2026-08-07 21:02:21 BST — the install earlier that day was
`cp`-only and sat disabled through fault reset #3 at 17:46 (near-idle). Verify
activation by `journalctl -t iad-cstate-limit -b 0` + sysfs `state[23]/disable`
= 1 on all CPUs, never by unit-file presence or `is-active` (oneshot without
`RemainAfterExit` reads `inactive (dead)` after success).

`doctor.sh --only ras-logging` verifies what it can read without root (the
journald drop-in and the rasdaemon unit) and stays silent on hosts that have no
reset history.

**Acceptance:** seven consecutive days with `reset-reason` reporting CLEAN on
every boot. That replaces the "7-day zero-unclean-shutdown soak" HOST-1 claimed,
which reset #7 refuted.

## Machine-global hardware sampler

One 1 Hz sampler covers the machine — it is the only artifact that survives a
power-cut with its last second intact, because it fsyncs every line.

```bash
cp scripts/automation/host-guard/iad-hwmon.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now iad-hwmon.service
loginctl show-user "$USER" --property=Linger      # must print Linger=yes
tail -2 ~/.cache/iad/host-guard/hwmon/hwmon.csv
```

No root is needed (it is a `--user` unit). It writes
`~/.cache/iad/host-guard/hwmon/hwmon.csv`, restarts itself after every reset,
and keeps two rotated generations (~8 days). Per-repo samplers remain as a
fallback: an engine preflight only starts one when no machine-global sampler is
fresh, so migrating a project is just retiring its old unit. If a project still
runs its own `hwmon-log.service`, disable it after enabling this one.

## Machine-wide event ledger

`~/.cache/iad/host-guard/events.jsonl` — one fsync'd JSON line per chain event
for the WHOLE machine (engine start/stop, iteration start, every agent dispatch
and its exit code, each healthy aggregate verdict, every pause). It exists
because after a reset nothing could answer "what were both repos doing in the
final seconds?": the aggregate verdict was silent when it passed,
`telemetry.jsonl` is per-session and never fsync'd, and `engine.log` only exists
in interactive mode. Filter by `.project` for one repo, `.boot` for one boot.

## Browser QA confinement

Confining process *trees* is not enough for browser QA. The Chrome MCP does not
always spawn its browser: it **reconnects** to one recorded in
`<profile>.meta.json` and **adopts** orphans it finds by scanning for its
`--user-data-dir`. A browser born in an unconfined session therefore keeps its
wide CPU mask forever. And because Chrome is spawned detached, it outlives its
MCP server and is reparented to init — out of reach of any descendant walk.

`host-guard/browser-confine.sh` closes that hole. It runs before every browser
dispatch (`browser-qa-phase.sh`, `qa-phase.sh`, `goal-iter-lean.sh`,
`ui-audit-phase.sh`) and on **both** exits of `host-guard-adopt.sh` — including
the "already confined" early return, which is the common path and exactly where
an escaped browser would otherwise go unnoticed. It:

- re-tasksets any browser under the profile root that is outside the mask,
  preferring re-confinement over killing so warm browsers survive;
- kills only when taskset fails *and* the profile is this project's own; another
  project's browser is confined-if-unconfined and otherwise left alone, never
  killed;
- confines Chrome-MCP servers too (never kills them — the live pump depends on
  its server) so their *future* browsers are born inside the mask;
- sweeps `.meta.json` / `.mcp.lock` files whose pid is gone, with a 30 s age
  guard so a server mid-launch is not disturbed.

Engine-mode QA additionally runs the browser **headless** (`DISPLAY` and
`WAYLAND_DISPLAY` are unset before the dispatch, which is the only signal the MCP
uses), dropping GPU compositing and the raster thread pool. Screenshots are
unaffected. `CHAIN_BQA_HEADED=1` restores a visible browser for debugging;
`CHAIN_BQA_REAP=1` additionally terminates this project's QA browsers when an
engine-mode phase finishes (default is leave-warm — a cold start costs seconds
and an idle browser inside the mask costs nothing).

| Var | Meaning | Default |
|---|---|---|
| `CHROME_WS_PROFILE` / `CHROME_WS_PORT` | pinned QA browser identity, per project and lane (`iad-qa-<project>` on `10000+hash`, the qa lane on `11000+hash`) | set by `ensure_qa_browser_env` |
| `CHAIN_BQA_HEADED` | `1` keeps a visible browser in engine mode | `0` |
| `CHAIN_BQA_REAP` | `1` reaps this project's QA browsers at phase end (engine mode only) | `0` |
| `HOST_GUARD_BROWSER_CONFINE` | `0` disables the pass entirely | `1` |

Pump sessions deliberately get **no** profile pin. A Claude Code `env` setting
overrides the inherited process environment, so a pinned value there would clobber
the per-lane profile the phase scripts export and collapse the two concurrently
running QA lanes (`run-phase.sh` Branch-QA and Branch-UI) onto one shared browser.
Pump browsers are made safe by affinity instead, which needs no name.

## Enforcement layers (all in `scripts/automation/`)

1. **Engine self-wrap** (`run-goal.sh`, top of script) — re-execs the whole
   engine under `systemd-run --user --scope` with `AllowedCPUs` (cgroup cpuset,
   inherited by every descendant, cannot be widened from inside) +
   CPUQuota/MemoryHigh/TasksMax, plus `taskset -c` (also the no-user-bus
   fallback). Covers **headless** runs completely.
2. **In-place adoption** (`host-guard-adopt.sh`) — interactive dispatches run
   inside the foreground CLI session, which the self-wrap cannot reach; this
   script retrofits the confinement onto the ALREADY-RUNNING session tree, so
   no special launch command is needed. Mechanics: systemd scope adoption
   (busctl `StartTransientUnit` with the `PIDs` property + `set-property`) for
   the CPUQuota/MemoryHigh/TasksMax ceilings, plus `taskset -a -c -p` on the
   root and every existing descendant for the hard CPU mask (all threads,
   inherited by all future children — works with no systemd at all).
   `--cli-root-of <pid>` walks up to the outermost ancestor matching
   `HOST_GUARD_CLI_PATTERN`. Invoked automatically by the `/goal` command at
   session start and by the iteration gate on an unconfined pump.
3. **Pump wrapper** (`host-guard-exec.sh`) — optional belt-and-braces: launch
   the CLI confined from birth (`scripts/automation/host-guard-exec.sh claude`),
   which additionally sets the BLAS/OMP thread-cap env vars (impossible to
   inject into a running process). The fallback when adoption fails.
4. **Preflight** (`preflight_host_guard`) — before the loop: forensics sampler
   alive (auto-started if not), affinity wrap took effect, launcher marker
   blocks intact, and the machine-global budget + boost assumption hold.
   Failure pauses the session `AWAITING_HOST_GUARD` (resumable).
5. **Iteration gate** (`host_guard_iteration_gate`, top of loop) — thermal
   cooldown between iterations (wait out heat-soak, bounded); pump-cpuset
   verification when `HOST_GUARD_REQUIRE_PUMP_CONFINED=1` (via the `pid=` line
   in `.pump-alive`, or the CLI root captured at engine launch) with automatic
   in-place re-confinement, pausing only when that fails; then a re-check of the
   machine-global budget and boost, since the *other* project's session may have
   started after this one's preflight.
6. **Machine-global bound** (`lib/host-guard-registry.sh`) — the live-session
   registry and the aggregate CPU/memory/boost checks described above. This is
   the layer that sees more than one project at a time.
7. **Browser confinement** (`host-guard/browser-confine.sh`) — QA browsers and
   Chrome-MCP servers that escaped the process tree, see below.
8. **Forensics sampler** (`host-guard/hwmon-log.sh`) — 1 Hz temps/power/
   pressure/memory/clock, fsync per line, so the final pre-reset second survives
   a hard reset. Writes `~/.cache/iad/host-guard/hwmon/hwmon.csv` under the
   machine-global unit, else `<repo>/logs/hwmon/hwmon.csv`.
   `{run|start|stop|status|watch}`; `status`/`start` recognize an externally-run
   sampler — including the machine-global one — by csv freshness and never
   double-run.
9. **Reset-reason forensics** (`host-guard/reset-forensics.sh`) — reads the
   platform's own reset register each boot and freezes a postmortem bundle when
   the last boot died. `{check|ensure-postmortem|report}`; doctor row
   `reset-reason`. The only layer that can explain a reset no software caused.
10. **Machine event ledger** (`hg_event`, `lib/host-guard-registry.sh`) — one
   fsync'd line per chain event for the whole machine, including the healthy
   aggregate verdict that used to be silent.

## When `AWAITING_HOST_GUARD` fires

Read the printed reason, fix it, then
`./scripts/automation/run-goal.sh --resume --session-id <sid>` (or
`/goal-resume`). Pump-related pauses are rare by construction — the engine
auto-confines a running pump in place before ever pausing — so a pause means
adoption itself failed: relaunch the CLI via `host-guard-exec.sh` and resume.
Do not disable flags to silence the pause; the caps exist because unconfined
load has hard-reset a host.

## Origin

Built after a GEEKOM A7 Max (Ryzen 9 7940HS) hard-reset five times in eight
days (2026-07-20 → 2026-07-28) under goal-mode load, three of the resets
captured at 1 Hz with benign temperatures and low package power — a
millisecond-scale power transient.

A sixth reset on 2026-07-29 came *after* per-session confinement was in place,
and produced the machine-global layer: two correctly-confined projects were
still collectively unbounded, a QA browser could keep a pre-confinement CPU
mask, and the boost mitigation had silently lapsed at a reboot. Incident
forensics and the cap-widening verification ladder live in the originating
project: `trendora/project-extensions/host-guard/README.md`.

A **seventh** reset on 2026-07-30 17:14:08 ended that line of reasoning. It
happened with the machine-global layer deployed to both projects, armed, and
green on every check. The answer had been in the kernel log the whole time —
`Previous system reset reason [0x08000800]: an uncorrected error caused a data
fabric sync flood event`, present on seven of the last ten boots, once at load
1.53. The root cause is **hardware** (DDR5/Infinity-Fabric marginality on
non-ECC SO-DIMMs, BIOS 1.26 dated 09/2025), and no CPU mask, memory ceiling or
browser confinement can prevent it.

Three generations of guard were built to stop something the CPU was already
naming on every boot. That is the lesson recorded as anti-pattern 27: **read the
platform's own postmortem registers before iterating on software mitigations.**
Since then these layers surface the hardware's verdict, preserve the evidence,
recover honestly, and cap concurrency — see § After a hardware reset for the
remediation that actually applies.
