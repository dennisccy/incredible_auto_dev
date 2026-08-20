#!/usr/bin/env bash
# fabric-pin.sh — pin the AMD APU's fabric/memory/SoC clocks at their top
# P-state. Mitigation rung A for the 0x08000800 incident (data fabric sync
# flood, 16 hard resets on the GEEKOM A7 Max since 2026-07-20).
#
# WHY THIS KNOB: MemTest86+ ran 20.5 h at ~90 °C with ZERO resets — an
# environment with no OS power management and no DF/UCLK P-state transitions —
# while under Linux the machine resets at near-idle and under load alike
# (58 °C/16 W and 67 °C/22 W deaths on 2026-08-10). CPU-core C-states were
# falsified as a cause on 2026-08-08 with the limit verifiably active. The
# remaining OS-active-only variable this host exposes is the fabric clock
# visibly stepping 500/1600/1960 MHz under `auto` DPM. Writing `high` to
# power_dpm_force_performance_level pins fclk/mclk/socclk at their top level,
# eliminating those transitions. Cost: a few watts at idle. Rollback: `release`
# (or remove the iad-fabric-pin.service unit and reboot).
#
# VERIFY ONLY by journal tag + sysfs (the standing host-guard lesson —
# "installed" ≠ enabled ≠ ran):
#   journalctl -t iad-fabric-pin -b 0
#   grep '\*' /sys/class/drm/card*/device/pp_dpm_fclk   # star on the TOP row
#
# Usage: fabric-pin.sh apply | release | status
# Needs root for apply/release (the pp sysfs nodes are root-writable).
set -u

TAG="iad-fabric-pin"

_log() { logger -t "$TAG" -- "$*" 2>/dev/null; echo "[$TAG] $*"; }

_card() { # the amdgpu device dir exposing the perf-level + fabric-clock knobs
  local d
  for d in /sys/class/drm/card*/device; do
    [[ -f "$d/power_dpm_force_performance_level" && -f "$d/pp_dpm_fclk" ]] || continue
    printf '%s\n' "$d"
    return 0
  done
  return 1
}

_pinned() { # $1 device dir — 0 when the ACTIVE (*) fclk row is the last (top) row
  local d="$1" starred top
  starred="$(grep -n '\*' "$d/pp_dpm_fclk" 2>/dev/null | tail -n 1 | cut -d: -f1)"
  top="$(wc -l < "$d/pp_dpm_fclk" 2>/dev/null)"
  [[ -n "$starred" && -n "$top" && "$starred" == "$top" ]]
}

cmd_apply() {
  local d="" i
  # The unit starts at multi-user.target, but amdgpu may still be probing on a
  # cold boot — wait for the sysfs nodes rather than failing the one shot.
  for i in $(seq 1 30); do
    d="$(_card)" && break
    sleep 1
  done
  if [[ -z "$d" ]]; then
    _log "apply FAILED: no amdgpu device with power_dpm_force_performance_level + pp_dpm_fclk after 30s"
    return 1
  fi
  if ! printf 'high\n' > "$d/power_dpm_force_performance_level" 2>/dev/null; then
    _log "apply FAILED: cannot write 'high' to $d/power_dpm_force_performance_level (need root)"
    return 1
  fi
  # The SMU applies the forced level asynchronously on some boots.
  for i in 1 2 3 4 5; do
    _pinned "$d" && break
    sleep 1
  done
  local lvl fclk mclk soc
  lvl="$(cat "$d/power_dpm_force_performance_level" 2>/dev/null)"
  fclk="$(tr '\n' ' ' < "$d/pp_dpm_fclk" 2>/dev/null)"
  mclk="$(tr '\n' ' ' < "$d/pp_dpm_mclk" 2>/dev/null)"
  soc="$(tr '\n' ' ' < "$d/pp_dpm_socclk" 2>/dev/null)"
  if _pinned "$d"; then
    _log "applied: perf_level=$lvl dev=$d fclk=[$fclk] mclk=[$mclk] socclk=[$soc]"
    return 0
  fi
  _log "apply WROTE but fclk is NOT pinned at top: perf_level=$lvl fclk=[$fclk] — investigate before trusting this soak day"
  return 1
}

cmd_release() {
  local d
  d="$(_card)" || { _log "release: no amdgpu pp sysfs found"; return 1; }
  if printf 'auto\n' > "$d/power_dpm_force_performance_level" 2>/dev/null; then
    _log "released: perf_level=auto dev=$d"
    return 0
  fi
  _log "release FAILED: cannot write 'auto' to $d/power_dpm_force_performance_level (need root)"
  return 1
}

cmd_status() {
  local d
  d="$(_card)" || { echo "no amdgpu pp sysfs found"; return 1; }
  echo "device: $d"
  echo "perf_level: $(cat "$d/power_dpm_force_performance_level" 2>/dev/null)"
  echo "fclk:  $(tr '\n' ' ' < "$d/pp_dpm_fclk" 2>/dev/null)"
  echo "mclk:  $(tr '\n' ' ' < "$d/pp_dpm_mclk" 2>/dev/null)"
  echo "socclk: $(tr '\n' ' ' < "$d/pp_dpm_socclk" 2>/dev/null)"
  if _pinned "$d"; then echo "verdict: PINNED (fclk active level is top)"; else echo "verdict: NOT PINNED"; fi
}

case "${1:-}" in
  apply)   cmd_apply ;;
  release) cmd_release ;;
  status)  cmd_status ;;
  *) echo "Usage: $0 {apply|release|status}" >&2; exit 2 ;;
esac
