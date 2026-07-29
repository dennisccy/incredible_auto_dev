#!/usr/bin/env bash
# browser-confine.sh — put escaped QA browsers back inside the host-guard mask.
#
# WHY: host-guard confines process TREES, and a Chrome the MCP server spawns
# does inherit the mask. But the superpowers-chrome MCP does not always spawn:
#   - it RECONNECTS to a browser recorded in <profile>.meta.json whose port+pid
#     are still alive, and
#   - it ADOPTS an orphan Chrome found by scanning ps for its --user-data-dir.
# A browser born in an unconfined session therefore keeps its wide mask forever,
# no matter how many times the pump itself is confined. Worse, Chrome is spawned
# detached and unref'd, so once its MCP server exits the browser is reparented
# to init — invisible to host-guard-adopt.sh's `pgrep -P` descendant walk.
#
# An unconfined headed Chrome rasterizing across every core is precisely the
# bursty all-core profile that hard-resets this class of mini-PC (2026-07-29).
#
# WHAT IT DOES (four passes, all idempotent, all best-effort):
#   A. QA browsers  — re-taskset any main Chrome process holding a superpowers
#      browser profile; kill only when taskset fails AND the profile is ours.
#   B. MCP servers  — re-taskset the node servers themselves (never killed: the
#      pump's live session depends on them), so their FUTURE children are born
#      confined.
#   C. Stale files  — drop <profile>.meta.json / .mcp.lock whose pid is gone, so
#      the next dispatch cold-starts instead of "reconnecting" to a corpse.
#   D. Reap (--reap, opt-in) — TERM this project's own QA browsers at phase end.
#
# Absent/disabled host-guard.env (or HOST_GUARD_BROWSER_CONFINE=0) ⇒ no-op:
# the framework stays project-neutral.
#
# Usage: browser-confine.sh [--reap]
# Exit:  always 0 (advisory pass — never fail a QA phase over browser hygiene).
set -uo pipefail

REAP=0
case "${1:-}" in
  --reap) REAP=1 ;;
  "") ;;
  *) echo "usage: browser-confine.sh [--reap]" >&2; exit 2 ;;
esac

ROOT="${HOST_GUARD_ROOT:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)}"
ENV_FILE="$ROOT/project-extensions/host-guard/host-guard.env"
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE" 2>/dev/null
if [[ "${HOST_GUARD_ENABLED:-0}" != "1" || -z "${HOST_GUARD_CPU_LIST:-}" \
      || "${HOST_GUARD_BROWSER_CONFINE:-1}" == "0" ]]; then
  echo "[browser-confine] host-guard absent/disabled for $ROOT — nothing to do."
  exit 0
fi
if ! command -v taskset >/dev/null 2>&1; then
  echo "[browser-confine] taskset unavailable — cannot confine browsers." >&2
  exit 0
fi

MASK="$HOST_GUARD_CPU_LIST"
PROFILE_ROOT="${CHROME_PROFILE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/superpowers/browser-profiles}"
_proj="$ROOT"; [[ "$_proj" == */incredible_auto_dev ]] && _proj="${_proj%/incredible_auto_dev}"
BASE="$(basename "$_proj")"
OWN_DIRS=( "$PROFILE_ROOT/iad-qa-$BASE" "$PROFILE_ROOT/iad-qa-$BASE-qa" )
UID_SELF="$(id -u)"

# ── helpers ──────────────────────────────────────────────────────────────────
_expand() { # "0-3,8-11" → CPU ids, one per line
  local part a b i; local -a parts=()
  IFS=',' read -ra parts <<< "${1:-}"
  { for part in "${parts[@]}"; do
      if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
        a="${part%-*}"; b="${part#*-}"; (( b >= a )) && for (( i=a; i<=b; i++ )); do echo "$i"; done
      elif [[ "$part" =~ ^[0-9]+$ ]]; then echo "$part"; fi
    done; } | sort -n -u
}
_width() { _expand "${1:-}" | wc -l | tr -dc 0-9; }
_is_subset() { # $1 ⊆ $2
  local c; local -A super=()
  while read -r c; do [[ -n "$c" ]] && super["$c"]=1; done < <(_expand "${2:-}")
  while read -r c; do [[ -n "$c" ]] || continue; [[ -n "${super[$c]:-}" ]] || return 1; done < <(_expand "${1:-}")
  return 0
}
_cmdline() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null; }
_allowed() { awk -F'\t' '/^Cpus_allowed_list/{print $2}' "/proc/$1/status" 2>/dev/null; }
_descendants() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; _descendants "$c"; done; }

# Same-UID processes only: never touch another user's browser.
_scan() { # every arg must appear in the cmdline
  local p cmd want ok
  for p in /proc/[0-9]*; do
    p="${p#/proc/}"
    [[ "$p" == "$$" || "$p" == "$PPID" ]] && continue
    [[ "$(stat -c %u "/proc/$p" 2>/dev/null)" == "$UID_SELF" ]] || continue
    cmd="$(_cmdline "$p")"
    [[ -n "$cmd" ]] || continue
    ok=1
    for want in "$@"; do [[ "$cmd" == *"$want"* ]] || { ok=0; break; }; done
    (( ok )) && echo "$p"
  done
}

_confine_tree() { # taskset pid + descendants; rc 0 when the pid ends up inside
  local pid="$1" c
  taskset -a -c -p "$MASK" "$pid" >/dev/null 2>&1 || true
  for c in $(_descendants "$pid"); do
    taskset -a -c -p "$MASK" "$c" >/dev/null 2>&1 || true
  done
  # Second sweep: renderers forked while the first pass ran.
  for c in $(_descendants "$pid"); do
    taskset -a -c -p "$MASK" "$c" >/dev/null 2>&1 || true
  done
  _is_subset "$(_allowed "$pid")" "$MASK"
}

_owned() { # cmdline holds one of OUR pinned profile dirs (exact --user-data-dir arg)
  local cmd="$1" d
  for d in "${OWN_DIRS[@]}"; do
    [[ "$cmd" == *"--user-data-dir=$d "* || "$cmd" == *"--user-data-dir=$d" ]] && return 0
  done
  return 1
}

_sweep_profile_files() { # $1 profile dir → drop its meta/lock
  local d="$1" n="${1##*/}"
  rm -f "$PROFILE_ROOT/$n.meta.json" "$PROFILE_ROOT/$n.mcp.lock" 2>/dev/null || true
}

_terminate() { # TERM, then KILL after 3s
  local pid="$1" i
  kill -TERM "$pid" 2>/dev/null || return 1
  for i in 1 2 3; do
    sleep 1
    kill -0 "$pid" 2>/dev/null || return 0
  done
  kill -KILL "$pid" 2>/dev/null || true
  return 0
}

# Serialize concurrent passes (two QA lanes can dispatch at once). taskset is
# idempotent, so a lock timeout is not a reason to skip the work.
# NOTE the brace group: `exec 9>… 2>/dev/null` without it would apply the
# stderr redirection to the REST OF THE SCRIPT, silently swallowing every
# warning below. The group keeps 2>/dev/null scoped to the exec itself while
# fd 9 still lands on the calling shell.
mkdir -p "$PROFILE_ROOT" 2>/dev/null || true
{ exec 9>"$PROFILE_ROOT/.iad-confine.lock"; } 2>/dev/null || true
if command -v flock >/dev/null 2>&1; then flock -w 5 9 2>/dev/null || true; fi

n_qa=0; n_confined=0; n_kept=0; n_killed=0; n_mcp=0; n_mcp_confined=0; n_swept=0; n_reaped=0

# ── Pass A: QA browsers ──────────────────────────────────────────────────────
# Only MAIN browser processes: renderers/GPU helpers carry --type= and are
# handled by the tree walk (they are children of the main process).
for pid in $(_scan "$PROFILE_ROOT/"); do
  cmd="$(_cmdline "$pid")"
  [[ "$cmd" == *" --type="* ]] && continue
  n_qa=$(( n_qa + 1 ))
  allowed="$(_allowed "$pid")"
  if _owned "$cmd"; then
    # Ours: must sit exactly inside this project's mask.
    _is_subset "$allowed" "$MASK" && { n_kept=$(( n_kept + 1 )); continue; }
  else
    # Someone else's QA profile (e.g. the other project's, or a legacy
    # auto-disambiguated one). Only act when it is effectively unconfined —
    # narrowing a browser another project already confined would be rude and
    # pointless; leaving an all-CPU browser running is what resets the host.
    (( $(_width "$allowed") <= $(_width "$MASK") )) && { n_kept=$(( n_kept + 1 )); continue; }
  fi
  if _confine_tree "$pid"; then
    n_confined=$(( n_confined + 1 ))
    echo "[browser-confine] confined QA chrome pid $pid to $MASK."
    continue
  fi
  if _owned "$cmd"; then
    echo "[browser-confine] pid $pid could not be confined — terminating (own profile)." >&2
    if _terminate "$pid"; then
      n_killed=$(( n_killed + 1 ))
      for d in "${OWN_DIRS[@]}"; do
        [[ "$cmd" == *"--user-data-dir=$d"* ]] && _sweep_profile_files "$d"
      done
    fi
  else
    echo "[browser-confine] WARNING: chrome pid $pid ($allowed) is outside $MASK and is not ours to kill — close it manually." >&2
  fi
done

# ── Pass B: MCP servers (confine, never kill) ────────────────────────────────
# HOST_GUARD_MCP_MATCH holds the cmdline tokens that identify a Chrome-MCP
# server (ALL must match). It exists so tests can scope this pass to their own
# fake server — pass B is deliberately profile-root-independent, so without the
# seam a sandboxed run would reach the operator's real, live MCP server.
read -r -a _mcp_match <<< "${HOST_GUARD_MCP_MATCH:-superpowers-chrome mcp/dist/index.js}"
for pid in $(_scan "${_mcp_match[@]}"); do
  n_mcp=$(( n_mcp + 1 ))
  _is_subset "$(_allowed "$pid")" "$MASK" && continue
  if _confine_tree "$pid"; then
    n_mcp_confined=$(( n_mcp_confined + 1 ))
    echo "[browser-confine] confined Chrome-MCP server pid $pid to $MASK (its future browsers inherit it)."
  else
    echo "[browser-confine] WARNING: Chrome-MCP server pid $pid stays outside $MASK — browsers it spawns will be unconfined." >&2
  fi
done

# ── Pass C: stale meta/lock sweep ────────────────────────────────────────────
# The age guard keeps a racing MCP server's freshly-written file: it records the
# pid before the browser is up, so a <30s file with a dead pid may be mid-launch.
for f in "$PROFILE_ROOT"/*.meta.json "$PROFILE_ROOT"/*.mcp.lock; do
  [[ -e "$f" ]] || continue
  age=$(( EPOCHSECONDS - $(stat -c %Y "$f" 2>/dev/null || echo "$EPOCHSECONDS") ))
  (( age > 30 )) || continue
  fpid="$(sed -n 's/.*"pid"[: ]*\([0-9][0-9]*\).*/\1/p' "$f" 2>/dev/null | head -n 1)"
  [[ -n "$fpid" ]] || continue
  [[ -d "/proc/$fpid" ]] && continue
  rm -f "$f" 2>/dev/null && n_swept=$(( n_swept + 1 ))
done

# ── Pass D: reap (opt-in, engine backend only) ───────────────────────────────
if (( REAP )) && [[ "${CHAIN_BQA_REAP:-0}" == "1" && "${CHAIN_AGENT_BACKEND:-}" != "interactive" ]]; then
  for pid in $(_scan "$PROFILE_ROOT/"); do
    cmd="$(_cmdline "$pid")"
    [[ "$cmd" == *" --type="* ]] && continue
    _owned "$cmd" || continue
    _terminate "$pid" && n_reaped=$(( n_reaped + 1 ))
  done
  for d in "${OWN_DIRS[@]}"; do _sweep_profile_files "$d"; done
fi

echo "[browser-confine] qa_browsers=$n_qa confined=$n_confined kept=$n_kept killed=$n_killed mcp=$n_mcp mcp_confined=$n_mcp_confined swept=$n_swept reaped=$n_reaped"
exit 0
