#!/usr/bin/env bash
# host-guard-exec.sh — run ANY command under the project's host-guard caps.
#
# WHY: the engine's self-wrap (run-goal.sh) confines headless runs, but
# interactive-pump dispatches execute INSIDE the foreground CLI session
# (Claude Code / Codex) — children of a process the engine never wrapped.
# Launch that CLI through this wrapper and every subagent, pytest, bundler,
# and browser it spawns inherits the same cgroup/affinity confinement:
#
#   scripts/automation/host-guard-exec.sh claude
#   scripts/automation/host-guard-exec.sh -- codex --some-flag
#
# The engine can enforce this: with HOST_GUARD_REQUIRE_PUMP_CONFINED=1 in
# host-guard.env, run-goal.sh's iteration gate verifies the pump process's
# cpuset and pauses (AWAITING_HOST_GUARD, resumable) if it is unconfined.
#
# Repo root: $HOST_GUARD_ROOT override, else git toplevel of $PWD, else $PWD.
# Absent or disabled host-guard.env ⇒ exec the command unwrapped (with a
# warning): the framework stays project-neutral.
set -euo pipefail

[[ "${1:-}" == "--" ]] && shift
if [[ $# -eq 0 ]]; then
  echo "Usage: $0 [--] <command> [args...]" >&2
  exit 2
fi

ROOT="${HOST_GUARD_ROOT:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)}"
ENV_FILE="$ROOT/project-extensions/host-guard/host-guard.env"
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE" || true

if [[ "${HOST_GUARD_ENABLED:-0}" != "1" || -z "${HOST_GUARD_CPU_LIST:-}" ]] \
   || ! command -v taskset >/dev/null 2>&1; then
  echo "[host-guard-exec] no enabled host-guard.env under $ROOT (or no taskset) — running UNCONFINED." >&2
  exec "$@"
fi

# BLAS/OpenMP/numexpr worker caps for every descendant (mirrors the launcher
# HOST-GUARD blocks): N numpy processes must not oversubscribe the mask with
# nested thread pools.
if [[ "${HOST_GUARD_BLAS_THREADS:-}" =~ ^[0-9]+$ ]]; then
  export OMP_NUM_THREADS="$HOST_GUARD_BLAS_THREADS"
  export OPENBLAS_NUM_THREADS="$HOST_GUARD_BLAS_THREADS"
  export MKL_NUM_THREADS="$HOST_GUARD_BLAS_THREADS"
  export NUMEXPR_NUM_THREADS="$HOST_GUARD_BLAS_THREADS"
fi

# Opt-in headless pump QA (HOST_GUARD_PUMP_HEADLESS_QA=1): strip the session's
# display env so pump-dispatched browser QA launches Chrome HEADLESS (the
# Chrome MCP picks headless purely from absent DISPLAY/WAYLAND_DISPLAY —
# lib/common.sh strip_display_for_headless_qa; engine-mode lanes already do
# this). Added after the 2026-08-07 gnome-shell SIGSEGV: the headed pump QA
# Chrome was a standing compositor-stress source, and the session teardown
# killed the pump. CHAIN_BQA_HEADED=1 remains the headed debugging escape.
if [[ "${HOST_GUARD_PUMP_HEADLESS_QA:-0}" == "1" ]]; then
  unset DISPLAY WAYLAND_DISPLAY
  echo "[host-guard-exec] HOST_GUARD_PUMP_HEADLESS_QA=1 — DISPLAY/WAYLAND_DISPLAY stripped (QA browsers go headless)." >&2
fi

# NOTE: no CHROME_WS_PROFILE pin here. The pump serves BOTH QA lanes (run-phase.sh
# runs Branch-QA and Branch-UI concurrently), and an explicit profile disables the
# Chrome-MCP's per-lane auto-disambiguation — the two lanes would end up sharing one
# browser and stepping on each other's tabs. Pump browsers are made safe by affinity
# instead: host-guard/browser-confine.sh confines everything under the profile root,
# named or not. Engine-mode lanes pin per-lane identities themselves (lib/common.sh
# ensure_qa_browser_env), where the export is actually honored.

# Publish this wrapped pump into the machine-global registry (exec preserves
# both the pid and its start time, so this record tracks the CLI tree's root).
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/lib/host-guard-registry.sh" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/lib/host-guard-registry.sh" 2>/dev/null \
    && hg_register pumpexec "$$" "$ROOT" "${HOST_GUARD_SESSION_ID:-}" \
         "$HOST_GUARD_CPU_LIST" "${HOST_GUARD_MEMORY_HIGH:-18G}" >/dev/null 2>&1 || true
fi

_PROPS=( -p "CPUQuota=${HOST_GUARD_CPUQUOTA:-800%}"
         -p "MemoryHigh=${HOST_GUARD_MEMORY_HIGH:-18G}"
         -p "TasksMax=${HOST_GUARD_TASKS_MAX:-2048}" )

# --expand-environment=no: systemd ExecStart otherwise $-expands argv ("$$"→"$").
if systemd-run --user --scope --quiet --expand-environment=no -p "AllowedCPUs=$HOST_GUARD_CPU_LIST" true 2>/dev/null; then
  echo "[host-guard-exec] confining '$1' to CPUs $HOST_GUARD_CPU_LIST (cpuset + CPUQuota=${HOST_GUARD_CPUQUOTA:-800%}, MemoryHigh=${HOST_GUARD_MEMORY_HIGH:-18G})." >&2
  exec systemd-run --user --scope --quiet --collect --expand-environment=no \
    --unit "chain-pump-hostguard-$$" \
    -p "AllowedCPUs=$HOST_GUARD_CPU_LIST" "${_PROPS[@]}" \
    taskset -c "$HOST_GUARD_CPU_LIST" "$@"
elif systemd-run --user --scope --quiet --expand-environment=no -p CPUQuota=10% true 2>/dev/null; then
  echo "[host-guard-exec] confining '$1' to CPUs $HOST_GUARD_CPU_LIST (taskset + scope backstops; cpuset not delegated)." >&2
  exec systemd-run --user --scope --quiet --collect --expand-environment=no \
    --unit "chain-pump-hostguard-$$" \
    "${_PROPS[@]}" \
    taskset -c "$HOST_GUARD_CPU_LIST" "$@"
else
  echo "[host-guard-exec] confining '$1' to CPUs $HOST_GUARD_CPU_LIST (taskset only; no user manager)." >&2
  exec taskset -c "$HOST_GUARD_CPU_LIST" "$@"
fi
