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

Running two projects' goal modes on one host: give them **complementary masks**
(e.g. `0-3,8-11` and `4-7,12-15` on an 8-core/16-thread part) so a burst can
never light every core, and size `MEMORY_HIGH` so the sum fits in RAM.

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
   blocks intact. Failure pauses the session `AWAITING_HOST_GUARD` (resumable).
5. **Iteration gate** (`host_guard_iteration_gate`, top of loop) — thermal
   cooldown between iterations (wait out heat-soak, bounded), and — when
   `HOST_GUARD_REQUIRE_PUMP_CONFINED=1` — pump-cpuset verification (via the
   `pid=` line in `.pump-alive`, or the CLI root captured at engine launch)
   with automatic in-place re-confinement; pauses only when that fails.
6. **Forensics sampler** (`host-guard/hwmon-log.sh`) — 1 Hz temps/power/
   pressure/memory to `<repo>/logs/hwmon/hwmon.csv`, fsync per line, so the
   final pre-reset second survives a hard reset. `{run|start|stop|status|watch}`;
   `status`/`start` recognize an externally-run sampler (e.g. a systemd user
   unit running `run`) by csv freshness and never double-run.

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
millisecond-scale power transient. Incident forensics and the cap-widening
verification ladder live in the originating project:
`trendora/project-extensions/host-guard/README.md`.
