#!/usr/bin/env bash
# host-guard-adopt.sh — confine an ALREADY-RUNNING process tree to the
# project's host-guard caps, in place, no relaunch required.
#
# WHY: interactive-pump dispatches run inside the foreground CLI session
# (Claude Code / Codex). host-guard-exec.sh confines that session from birth,
# but requiring a special launch command is a footgun — this script retrofits
# the confinement onto the live session instead:
#
#   1. systemd scope adoption (busctl StartTransientUnit with the PIDs
#      property + set-property): moves the process under a transient user
#      scope carrying CPUQuota/MemoryHigh/TasksMax (and AllowedCPUs where the
#      cpuset controller is delegated to user units — many distros delegate
#      only cpu/memory/pids, in which case AllowedCPUs is a silent no-op).
#   2. taskset -a -c -p on the target AND every existing descendant: the hard
#      CPU mask — all threads, inherited by all future children. This is the
#      layer that actually prevents power-transient resets, and it works with
#      no systemd at all.
#
# Usage:
#   host-guard-adopt.sh <pid>                confine this pid('s tree)
#   host-guard-adopt.sh --cli-root-of <pid>  walk UP from <pid> to the
#       outermost ancestor whose cmdline matches HOST_GUARD_CLI_PATTERN
#       (default 'claude|codex') and confine THAT tree; falls back to <pid>
#       itself when no ancestor matches.
#
# Idempotent: re-running a fully-confined target just refreshes its scope
# ceilings in place (set-property) and re-sweeps escaped browsers.
# Absent/disabled host-guard.env ⇒ no-op (framework stays project-neutral).
# Limitation: BLAS/OMP thread-cap env vars cannot be injected into a running
# process — only wrapper-launched (host-guard-exec.sh) sessions get those.
set -euo pipefail

MODE_ROOT=0
if [[ "${1:-}" == "--cli-root-of" ]]; then MODE_ROOT=1; shift; fi
PID="${1:?usage: host-guard-adopt.sh [--cli-root-of] <pid>}"
[[ "$PID" =~ ^[0-9]+$ && -r "/proc/$PID/status" ]] \
  || { echo "[host-guard-adopt] pid '$PID' is not a running process" >&2; exit 1; }

ROOT="${HOST_GUARD_ROOT:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)}"
ENV_FILE="$ROOT/project-extensions/host-guard/host-guard.env"
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE" || true
if [[ "${HOST_GUARD_ENABLED:-0}" != "1" || -z "${HOST_GUARD_CPU_LIST:-}" ]]; then
  echo "[host-guard-adopt] no enabled host-guard.env under $ROOT — nothing to do."
  exit 0
fi
command -v taskset >/dev/null 2>&1 \
  || { echo "[host-guard-adopt] taskset not available" >&2; exit 1; }

_width() { # "0-3,8-11" → 8; 0 when unparseable
  local list="${1:-}" n=0 part a b
  [[ -n "$list" ]] || { echo 0; return 0; }
  local -a parts=()
  IFS=',' read -ra parts <<< "$list"
  for part in "${parts[@]}"; do
    if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
      a="${part%-*}"; b="${part#*-}"
      if (( b >= a )); then n=$(( n + b - a + 1 )); fi
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      n=$(( n + 1 ))
    fi
  done
  echo "$n"
}
_ppid() { awk '/^PPid:/{print $2}' "/proc/$1/status" 2>/dev/null || true; }
_allowed_n() { _width "$(awk -F'\t' '/^Cpus_allowed_list/{print $2}' "/proc/$1/status" 2>/dev/null)"; }
_hg_scope_unit() { # chain-*-hostguard scope unit already holding $1, if any
  sed -n 's#.*/\(chain-\(pump\|goal\)-hostguard-[^/]*\.scope\).*#\1#p' "/proc/$1/cgroup" 2>/dev/null | head -n 1
}

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Publish this pump into the machine-global registry so a concurrent project's
# engine can see its CPU/memory footprint when it computes the aggregate.
# Best effort — a registry problem must never fail an otherwise-good adoption.
_register_pump() {
  # shellcheck disable=SC1091
  source "$_SELF_DIR/lib/host-guard-registry.sh" 2>/dev/null || return 0
  hg_register pump "$TARGET" "$ROOT" "${HOST_GUARD_SESSION_ID:-}" \
    "$HOST_GUARD_CPU_LIST" "${HOST_GUARD_MEMORY_HIGH:-18G}" >/dev/null 2>&1 || true
}

# Re-confine QA browsers that escaped the process tree. The Chrome MCP reuses
# and adopts browsers it did not spawn, and detached Chromes outlive their MCP
# server (reparented to init) — neither is reachable by the descendant walk
# below, so a taskset of the pump tree alone leaves them unconfined.
_browser_pass() {
  [[ -f "$_SELF_DIR/host-guard/browser-confine.sh" ]] || return 0
  HOST_GUARD_ROOT="$ROOT" bash "$_SELF_DIR/host-guard/browser-confine.sh" || true
}

TARGET="$PID"
if [[ "$MODE_ROOT" == "1" ]]; then
  _pat="${HOST_GUARD_CLI_PATTERN:-claude|codex}" _p="$PID" _best=""
  while [[ "$_p" =~ ^[0-9]+$ ]] && (( _p > 1 )); do
    if tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null | grep -qE "$_pat"; then _best="$_p"; fi
    _p="$(_ppid "$_p")"
  done
  if [[ -n "$_best" ]]; then
    TARGET="$_best"
  else
    echo "[host-guard-adopt] no ancestor of $PID matches '$_pat' — confining $PID itself."
  fi
fi

WIDTH="$(_width "$HOST_GUARD_CPU_LIST")"
if (( WIDTH == 0 )); then
  echo "[host-guard-adopt] unparseable HOST_GUARD_CPU_LIST='$HOST_GUARD_CPU_LIST'" >&2
  exit 1
fi
ALLOWED_N="$(_allowed_n "$TARGET")"
SCOPE_UNIT="$(_hg_scope_unit "$TARGET")"
if (( ALLOWED_N <= WIDTH )) && [[ -n "$SCOPE_UNIT" ]]; then
  # Confined = mask narrow enough AND ceilings carried by a hostguard scope.
  # The old width-only check is vacuous at a full-machine mask (16 ≤ 16 is
  # always true), which left MemoryHigh/TasksMax unapplied on the pump from the
  # 2026-07-30 mask release until 2026-08-07. Refresh the ceilings so env-file
  # edits converge on the live scope on every adopt.
  systemctl --user set-property "$SCOPE_UNIT" \
    "CPUQuota=${HOST_GUARD_CPUQUOTA:-800%}" \
    "MemoryHigh=${HOST_GUARD_MEMORY_HIGH:-18G}" \
    "TasksMax=${HOST_GUARD_TASKS_MAX:-2048}" 2>/dev/null || true
  echo "[host-guard-adopt] pid $TARGET already confined ($(awk -F'\t' '/^Cpus_allowed_list/{print $2}' "/proc/$TARGET/status") in $SCOPE_UNIT) — ceilings refreshed."
  # An already-confined pump is the COMMON case, and it is exactly when an
  # escaped browser goes unnoticed — sweep before returning, never after.
  _register_pump
  _browser_pass
  exit 0
fi

# 1) Scope adoption — aggregate memory/task/quota ceilings for the whole tree.
if [[ -n "$SCOPE_UNIT" ]]; then
  # Already inside a hostguard scope (mask just too wide): refresh the existing
  # unit's ceilings instead of racing StartTransientUnit against it.
  UNIT="$SCOPE_UNIT"
  systemctl --user set-property "$UNIT" \
    "CPUQuota=${HOST_GUARD_CPUQUOTA:-800%}" \
    "MemoryHigh=${HOST_GUARD_MEMORY_HIGH:-18G}" \
    "TasksMax=${HOST_GUARD_TASKS_MAX:-2048}" 2>/dev/null || true
  systemctl --user set-property "$UNIT" "AllowedCPUs=$HOST_GUARD_CPU_LIST" 2>/dev/null || true
  echo "[host-guard-adopt] pid $TARGET already in $UNIT — ceilings refreshed."
elif busctl call --user org.freedesktop.systemd1 /org/freedesktop/systemd1 \
     org.freedesktop.systemd1.Manager StartTransientUnit 'ssa(sv)a(sa(sv))' \
     "chain-pump-hostguard-$TARGET.scope" fail 1 PIDs au 1 "$TARGET" 0 >/dev/null 2>&1; then
  UNIT="chain-pump-hostguard-$TARGET.scope"
  systemctl --user set-property "$UNIT" \
    "CPUQuota=${HOST_GUARD_CPUQUOTA:-800%}" \
    "MemoryHigh=${HOST_GUARD_MEMORY_HIGH:-18G}" \
    "TasksMax=${HOST_GUARD_TASKS_MAX:-2048}" 2>/dev/null || true
  # Engages only where the cpuset controller is delegated to user units.
  systemctl --user set-property "$UNIT" "AllowedCPUs=$HOST_GUARD_CPU_LIST" 2>/dev/null || true
  echo "[host-guard-adopt] scope $UNIT adopted pid $TARGET (CPUQuota=${HOST_GUARD_CPUQUOTA:-800%}, MemoryHigh=${HOST_GUARD_MEMORY_HIGH:-18G}, TasksMax=${HOST_GUARD_TASKS_MAX:-2048})."
else
  echo "[host-guard-adopt] scope adoption unavailable — applying the CPU mask only."
fi

# 2) Hard CPU mask NOW — target + every existing descendant; future children
# inherit. -a covers all threads of each process. At a full-width mask the
# taskset is a per-process no-op, so skip the whole tree recursion.
_descendants() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; _descendants "$c"; done; }
if (( ALLOWED_N > WIDTH )); then
  taskset -a -c -p "$HOST_GUARD_CPU_LIST" "$TARGET" >/dev/null 2>&1 || true
  for _c in $(_descendants "$TARGET"); do
    taskset -a -c -p "$HOST_GUARD_CPU_LIST" "$_c" >/dev/null 2>&1 || true
  done
fi

if (( $(_allowed_n "$TARGET") <= WIDTH )); then
  echo "[host-guard-adopt] confined pid $TARGET (and descendants) to CPUs $HOST_GUARD_CPU_LIST."
  _register_pump
  _browser_pass
  exit 0
fi
echo "[host-guard-adopt] FAILED to confine pid $TARGET (Cpus_allowed_list unchanged)." >&2
exit 1
