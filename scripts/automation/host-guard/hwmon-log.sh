#!/usr/bin/env bash
# hwmon-log.sh — 1 Hz hardware telemetry sampler (host-guard crash forensics).
#
# WHY: hosts can hard-reset under bursty all-core load with NOTHING in the
# journal — an instant power/VRM/thermal trip. sysstat's 10-minute cadence
# straddles the spike. This sampler records temps/power/pressure every second
# and fsyncs each line, so the final pre-reset second survives the reboot.
#
# Usage: hwmon-log.sh {run|start|stop|status|watch}
#   run    — sample in the foreground (Ctrl+C stops)
#   start  — background daemon (nohup); pidfile logs/hwmon/hwmon.pid
#   stop   — stop the daemon
#   status — exit 0 iff the daemon is alive AND the csv is fresh; prints one line
#   watch  — live view: latest sample + session max Tctl/PPT (⚠ at Tctl ≥ 90°C)
#
# Output: <repo>/logs/hwmon/hwmon.csv (gitignored), ring-rotated at
# HOST_GUARD_SAMPLER_MAX_BYTES to hwmon.csv.1. Sensors are resolved BY NAME
# (k10temp/amdgpu/nvme/spd5118/acpitz) — hwmon indexes shift across boots.
# A missing sensor yields an empty CSV field, never a crash.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Repo root resolution (which repo's logs/ receives the csv):
#   1. HOST_GUARD_ROOT env override — the engine preflight passes its $REPO_ROOT;
#   2. framework placement  <root>/scripts/automation/host-guard/ → 3 dirs up;
#   3. project placement    <root>/project-extensions/host-guard/ → 2 dirs up.
if [[ -n "${HOST_GUARD_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$HOST_GUARD_ROOT" && pwd)"
elif [[ "$HERE" == */scripts/automation/host-guard ]]; then
  REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
else
  REPO_ROOT="$(cd "$HERE/../.." && pwd)"
fi
# Caps env: the project's declaration wins; a copy next to this script is the
# fallback (project-extensions placement keeps them side by side).
ENV_FILE="$REPO_ROOT/project-extensions/host-guard/host-guard.env"
[[ -f "$ENV_FILE" ]] || ENV_FILE="$HERE/host-guard.env"
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE" || true

INTERVAL="${HOST_GUARD_SAMPLER_INTERVAL:-1}"
MAX_BYTES="${HOST_GUARD_SAMPLER_MAX_BYTES:-10485760}"
# HOST_GUARD_HWMON_DIR lets the machine-global systemd user unit
# (iad-hwmon.service) put the csv in the cache root instead of one repo's logs/.
# Unset ⇒ per-repo placement, exactly as before.
LOG_DIR="${HOST_GUARD_HWMON_DIR:-$REPO_ROOT/logs/hwmon}"
CSV="$LOG_DIR/hwmon.csv"
PIDFILE="$LOG_DIR/hwmon.pid"
DAEMON_LOG="$LOG_DIR/hwmon.log"
# Where the machine-global sampler writes. One 1 Hz sampler is enough for the
# whole machine; a per-repo engine must not start a second writer when it is
# already running (that is how two repos ended up with two half-histories).
GLOBAL_CSV="${HOST_GUARD_HWMON_GLOBAL_DIR:-${CHAIN_TMP_ROOT:-$HOME/.cache/iad}/host-guard/hwmon}/hwmon.csv"
# Schema is APPEND-ONLY: new columns go at the END so every existing reader
# (field 1 = epoch, field 2 = tctl) keeps working against old and new files.
# cpu_mhz was added after the 2026-07-30 sync-flood reset — clock behaviour is
# the cheapest signal correlated with fabric/VRM transients that the previous
# schema could not see. (No ac_online column: /sys/class/power_supply is empty
# on this class of mini-PC, so it would be a permanently blank field.)
HEADER="epoch,tctl_c,gpu_edge_c,ppt_w,ppt_avg_w,nvme_c,dimm0_c,dimm1_c,acpitz_c,load1,mem_avail_mb,swap_free_mb,psi_cpu_avg10,psi_mem_avg10,cpu_mhz"

# ── Sensor resolution (by hwmon name, once at startup) ─────────────────────
TCTL="" GPU_TEMP="" PPT_NOW="" PPT_AVG="" NVME_T="" DIMM0="" DIMM1="" ACPITZ=""
resolve_sensors() {
  local h name
  for h in /sys/class/hwmon/hwmon*; do
    [[ -r "$h/name" ]] || continue
    IFS= read -r name < "$h/name" 2>/dev/null || continue
    case "$name" in
      k10temp)
        if [[ -r "$h/temp1_input" ]]; then TCTL="$h/temp1_input"; fi ;;
      amdgpu)
        if [[ -r "$h/temp1_input" ]]; then GPU_TEMP="$h/temp1_input"; fi
        if [[ -r "$h/power1_input" ]]; then PPT_NOW="$h/power1_input"; fi
        if [[ -r "$h/power1_average" ]]; then PPT_AVG="$h/power1_average"; fi ;;
      nvme)
        if [[ -z "$NVME_T" && -r "$h/temp1_input" ]]; then NVME_T="$h/temp1_input"; fi ;;
      spd5118)
        if [[ -z "$DIMM0" && -r "$h/temp1_input" ]]; then DIMM0="$h/temp1_input"
        elif [[ -z "$DIMM1" && -r "$h/temp1_input" ]]; then DIMM1="$h/temp1_input"; fi ;;
      acpitz)
        if [[ -r "$h/temp1_input" ]]; then ACPITZ="$h/temp1_input"; fi ;;
    esac
  done
  return 0
}

# ── Field readers (never fail, never fork; empty string on any problem) ────
_read_scaled() { # $1 sysfs path (may be empty), $2 integer divisor
  local p="${1:-}" div="${2:-1}" v=""
  [[ -n "$p" ]] || return 0
  IFS= read -r v < "$p" 2>/dev/null || v=""
  [[ "$v" =~ ^[0-9]+$ ]] || return 0
  printf '%s' $(( v / div ))
  return 0
}
_psi_avg10() { # $1 /proc/pressure/{cpu,memory} → the "some avg10" value
  local p="$1" line=""
  IFS= read -r line < "$p" 2>/dev/null || line=""
  [[ "$line" == *avg10=* ]] || return 0
  line="${line#*avg10=}"
  printf '%s' "${line%% *}"
  return 0
}
_cpu_mhz() { # mean current core clock in MHz ("" when cpufreq is unavailable)
  local sum=0 n=0 v f
  for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do
    [[ -r "$f" ]] || continue
    IFS= read -r v < "$f" 2>/dev/null || continue
    [[ "$v" =~ ^[0-9]+$ ]] || continue
    sum=$(( sum + v )); n=$(( n + 1 ))
  done
  (( n > 0 )) || return 0
  printf '%s' $(( sum / n / 1000 ))
  return 0
}
MEM_AVAIL_MB="" SWAP_FREE_MB=""
_mem_fields() {
  MEM_AVAIL_MB="" SWAP_FREE_MB=""
  local k v u
  while IFS=' ' read -r k v u; do
    case "$k" in
      MemAvailable:) MEM_AVAIL_MB=$(( v / 1024 )) ;;
      SwapFree:)     SWAP_FREE_MB=$(( v / 1024 )); break ;;
    esac
  done < /proc/meminfo
  return 0
}

# ── Subcommands ────────────────────────────────────────────────────────────
cmd_run() {
  mkdir -p "$LOG_DIR"
  resolve_sensors
  [[ -f "$CSV" ]] || printf '%s\n' "$HEADER" > "$CSV"
  local ts tctl gpu ppt pavg nvt d0 d1 az load1 rest psic psim size mhz
  while :; do
    ts=$EPOCHSECONDS
    tctl=$(_read_scaled "$TCTL" 1000)
    gpu=$(_read_scaled "$GPU_TEMP" 1000)
    ppt=$(_read_scaled "$PPT_NOW" 1000000)
    pavg=$(_read_scaled "$PPT_AVG" 1000000)
    nvt=$(_read_scaled "$NVME_T" 1000)
    d0=$(_read_scaled "$DIMM0" 1000)
    d1=$(_read_scaled "$DIMM1" 1000)
    az=$(_read_scaled "$ACPITZ" 1000)
    IFS=' ' read -r load1 rest < /proc/loadavg 2>/dev/null || load1=""
    _mem_fields
    psic=$(_psi_avg10 /proc/pressure/cpu)
    psim=$(_psi_avg10 /proc/pressure/memory)
    mhz=$(_cpu_mhz)
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$ts" "$tctl" "$gpu" "$ppt" "$pavg" "$nvt" "$d0" "$d1" "$az" \
      "$load1" "$MEM_AVAIL_MB" "$SWAP_FREE_MB" "$psic" "$psim" "$mhz" >> "$CSV"
    # fsync the csv so the last pre-crash line survives an instant reset
    # (uutils-compatible file-arg form; plain `sync` as fallback).
    sync "$CSV" 2>/dev/null || sync 2>/dev/null || true
    size=$(stat -c %s "$CSV" 2>/dev/null || echo 0)
    if [[ "$size" =~ ^[0-9]+$ ]] && (( size > MAX_BYTES )); then
      # Two generations, not one: at 1 Hz a 10 MiB file is ~4 days, and the
      # incident history that matters spans more than one reset. tapeology's
      # ring was 99.3% full when the machine went down.
      if [[ -f "$CSV.1" ]]; then mv -f "$CSV.1" "$CSV.2"; fi
      mv -f "$CSV" "$CSV.1"
      printf '%s\n' "$HEADER" > "$CSV"
    fi
    sleep "$INTERVAL"
  done
}

_file_fresh() { # true iff $1 was written within the last INTERVAL+5 s
  local f="${1:-}" mtime
  [[ -f "$f" ]] || return 1
  mtime=$(stat -c %Y "$f" 2>/dev/null || echo 0)
  (( EPOCHSECONDS - mtime <= INTERVAL + 5 ))
}
_csv_fresh() { _file_fresh "$CSV"; }
# A live machine-global sampler covers this repo too — the hardware it samples
# is the same hardware. Distinct file only; when this process IS the global
# sampler the two paths are identical and this is never consulted.
_global_fresh() { [[ "$GLOBAL_CSV" != "$CSV" ]] && _file_fresh "$GLOBAL_CSV"; }

cmd_start() {
  mkdir -p "$LOG_DIR"
  local pid=""
  if [[ -f "$PIDFILE" ]] && IFS= read -r pid < "$PIDFILE" 2>/dev/null \
     && [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    echo "hwmon-log: already running (pid $pid)"
    return 0
  fi
  # A sampler without our pidfile (e.g. the systemd user unit running `run`)
  # is still a sampler — never start a second writer on the same csv.
  if _csv_fresh; then
    echo "hwmon-log: already running (external sampler, csv fresh)"
    return 0
  fi
  if _global_fresh; then
    echo "hwmon-log: already running (machine-global sampler → $GLOBAL_CSV)"
    return 0
  fi
  nohup env HOST_GUARD_ROOT="$REPO_ROOT" bash "$HERE/hwmon-log.sh" run >> "$DAEMON_LOG" 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  printf '%s\n' "$pid" > "$PIDFILE"
  echo "hwmon-log: started (pid $pid) → $CSV"
}

cmd_stop() {
  local pid=""
  if [[ -f "$PIDFILE" ]] && IFS= read -r pid < "$PIDFILE" 2>/dev/null \
     && [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    rm -f "$PIDFILE"
    echo "hwmon-log: stopped (pid $pid)"
    return 0
  fi
  rm -f "$PIDFILE"
  echo "hwmon-log: not running"
}

cmd_status() {
  local pid="" now mtime age last=""
  if [[ -f "$PIDFILE" ]] && IFS= read -r pid < "$PIDFILE" 2>/dev/null \
     && [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    if [[ -f "$CSV" ]]; then
      now=$EPOCHSECONDS
      mtime=$(stat -c %Y "$CSV" 2>/dev/null || echo 0)
      age=$(( now - mtime ))
      if (( age <= INTERVAL + 5 )); then
        IFS= read -r last < <(tail -n 1 "$CSV" 2>/dev/null) || last=""
        echo "hwmon-log: running (pid $pid), csv fresh (${age}s old): $last"
        return 0
      fi
      echo "hwmon-log: running (pid $pid) but csv STALE (${age}s old)"
      return 1
    fi
    echo "hwmon-log: running (pid $pid) but no csv yet"
    return 1
  fi
  if _csv_fresh; then
    IFS= read -r last < <(tail -n 1 "$CSV" 2>/dev/null) || last=""
    echo "hwmon-log: running (external sampler), csv fresh: $last"
    return 0
  fi
  if _global_fresh; then
    IFS= read -r last < <(tail -n 1 "$GLOBAL_CSV" 2>/dev/null) || last=""
    echo "hwmon-log: running (machine-global sampler), csv fresh: $last"
    return 0
  fi
  echo "hwmon-log: not running"
  return 1
}

cmd_watch() {
  [[ -f "$CSV" ]] || { echo "hwmon-log: no csv yet — start the sampler first"; return 1; }
  local line ts tctl gpu ppt rest maxt=0 maxp=0 mark
  trap 'echo; exit 0' INT TERM
  echo "$HEADER"
  while :; do
    line=$(tail -n 1 "$CSV" 2>/dev/null || true)
    IFS=',' read -r ts tctl gpu ppt rest <<< "$line" || true
    if [[ "$tctl" =~ ^[0-9]+$ ]] && (( tctl > maxt )); then maxt=$tctl; fi
    if [[ "$ppt" =~ ^[0-9]+$ ]] && (( ppt > maxp )); then maxp=$ppt; fi
    mark=""
    if [[ "$tctl" =~ ^[0-9]+$ ]] && (( tctl >= 90 )); then mark=" ⚠ Tctl≥90"; fi
    printf '\r%s  [max: Tctl %s°C, PPT %sW]%s   ' "$line" "$maxt" "$maxp" "$mark"
    sleep "$INTERVAL"
  done
}

case "${1:-}" in
  run)    cmd_run ;;
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  watch)  cmd_watch ;;
  *) echo "Usage: $0 {run|start|stop|status|watch}" >&2; exit 2 ;;
esac
