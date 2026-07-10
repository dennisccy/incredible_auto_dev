#!/usr/bin/env bash
# chain-tmp.sh — per-run TMPDIR isolation, owner-guarded cleanup, and a
# janitor for strays. Sourced by lib/common.sh so every pipeline script gets
# these; safe under `set -euo pipefail`.
#
# Why: multiple pipeline jobs (different projects) run concurrently on one
# machine as the same user. Tools the agents run (pytest, playwright/chromium,
# mktemp) write to shared /tmp and race each other's pruning (see
# .claude/anti-patterns.md #21). Giving each run its own short-lived dir —
# exported as TMPDIR — removes the sharing entirely; cleanup is then a single
# owner-guarded rm.
#
# API:
#   chain_tmp_init <run-id>    create+export, or ADOPT an inherited dir (nested)
#   chain_tmp_cleanup          remove the dir iff THIS process created it
#   chain_tmp_rotate <run-id>  cleanup (if owner) + fresh init — iteration boundary
#   chain_tmp_janitor          sweep strays from crashed/legacy runs (age+liveness)
#
# Knobs:
#   CHAIN_TMPDIR_DISABLE=true    leave the environment completely untouched
#   CHAIN_TMP_JANITOR=false      disable the janitor sweep
#   CHAIN_TMP_MAX_AGE_HOURS=24   janitor age gate
#   CHAIN_TMP_ROOT=/tmp          base dir (tests point this at a scratch dir)
#
# NOTE the /tmp/{claude,codex}-quota-exhausted sentinels (lib/quota-retry.sh)
# are INTENTIONALLY shared across concurrent jobs (quota is account-global):
# they stay in /tmp and the janitor never matches these names.

# chain_tmp_init <run-id> — creates /tmp/iad.<sanitized-id>.<pid> (SHORT path
# on purpose: unix sockets created under TMPDIR — e.g. Chromium's — have a
# 108-char path limit), exports TMPDIR/TMP/TEMP + CHAIN_TMPDIR +
# CHAIN_TMPDIR_OWNER_PID. Idempotent: when CHAIN_TMPDIR is already set and
# exists (run-phase.sh nested under run-goal.sh), the inherited dir is adopted
# WITHOUT taking ownership. Never fails the caller.
chain_tmp_init() {
  [[ "${CHAIN_TMPDIR_DISABLE:-false}" == "true" ]] && return 0
  if [[ -n "${CHAIN_TMPDIR:-}" && -d "${CHAIN_TMPDIR:-}" ]]; then
    export TMPDIR="$CHAIN_TMPDIR" TMP="$CHAIN_TMPDIR" TEMP="$CHAIN_TMPDIR"
    return 0
  fi
  local id="${1:-run}"
  id="$(printf '%s' "$id" | tr -c 'a-zA-Z0-9._-' '-' | cut -c1-60)"
  # ${BASHPID:-$$} for BOTH the name suffix and the owner record, so name and
  # owner always agree even when init runs in a subshell.
  local dir="${CHAIN_TMP_ROOT:-/tmp}/iad.${id}.${BASHPID:-$$}"
  if ! mkdir -p "$dir" 2>/dev/null; then
    echo "[chain-tmp] WARNING: cannot create $dir — keeping the shared default tmp." >&2
    return 0
  fi
  chmod 700 "$dir" 2>/dev/null || true
  export CHAIN_TMPDIR="$dir"
  export CHAIN_TMPDIR_OWNER_PID="${BASHPID:-$$}"
  export TMPDIR="$dir" TMP="$dir" TEMP="$dir"
  return 0
}

# chain_tmp_cleanup — remove CHAIN_TMPDIR iff this exact process created it.
# ${BASHPID:-$$} (not $$) so a stray call from a subshell can never delete the
# dir out from under the main script. Path-shape guard against a corrupted var.
chain_tmp_cleanup() {
  [[ -n "${CHAIN_TMPDIR:-}" ]] || return 0
  [[ "${CHAIN_TMPDIR_OWNER_PID:-}" == "${BASHPID:-$$}" ]] || return 0
  case "$CHAIN_TMPDIR" in
    */iad.*) rm -rf -- "$CHAIN_TMPDIR" 2>/dev/null || true ;;
  esac
  return 0
}

# chain_tmp_rotate <run-id> — iteration boundary for long-lived engines
# (run-goal.sh): drop the current dir (owner-guarded) and start a fresh one.
chain_tmp_rotate() {
  [[ "${CHAIN_TMPDIR_DISABLE:-false}" == "true" ]] && return 0
  chain_tmp_cleanup
  unset CHAIN_TMPDIR CHAIN_TMPDIR_OWNER_PID
  chain_tmp_init "${1:-run}"
}

# chain_tmp_janitor — reap strays owned by this user:
#   1. iad.* dirs older than the gate AND whose embedded owner pid is dead
#      (mtime alone is unsafe: writes to files INSIDE a dir don't touch the
#      dir's mtime, so a >24h live goal session could look stale).
#   2. legacy loose files in the base dir from pre-TMPDIR runs (quota/usage
#      mktemp leftovers, per-role service logs) — age-gated.
#   3. entries under /tmp/pytest-of-$USER (numbered basetemp dirs, garbage-*,
#      stale .lock) — age-gated so a live concurrent run (minutes old) is safe.
# NEVER touches the quota sentinels (no pattern matches their fixed names:
# 'claude-quota-??????.log' requires a 6-char suffix plus '.log', which
# 'claude-quota-exhausted' has neither of).
chain_tmp_janitor() {
  [[ "${CHAIN_TMP_JANITOR:-true}" == "true" ]] || return 0
  local max_age_hours="${CHAIN_TMP_MAX_AGE_HOURS:-24}"
  [[ "$max_age_hours" =~ ^[0-9]+$ ]] || max_age_hours=24
  local mmin=$(( max_age_hours * 60 ))
  local base="${CHAIN_TMP_ROOT:-/tmp}"

  local d pid
  for d in "$base"/iad.*; do
    [[ -e "$d" ]] || continue
    [[ -O "$d" ]] || continue
    [[ -n "$(find "$d" -maxdepth 0 -mmin "+$mmin" 2>/dev/null)" ]] || continue
    pid="${d##*.}"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      continue   # owning process still alive — never touch, whatever the age
    fi
    rm -rf -- "$d" 2>/dev/null || true
  done

  local pat
  for pat in 'claude-quota-??????.log' 'codex-quota-??????.log' \
             'claude-usage-??????.json' 'codex-usage-??????.json' \
             'qa-backend*.log' 'qa-frontend*.log' \
             'browser-qa-backend*.log' 'browser-qa-frontend*.log' \
             'fanout-backend*.log' 'fanout-frontend*.log' \
             'demo-backend*.log' 'demo-frontend*.log' \
             'goal-iter-backend*.log' 'goal-iter-frontend*.log'; do
    find "$base" -maxdepth 1 -type f -name "$pat" -uid "$(id -u)" \
      -mmin "+$mmin" -exec rm -f {} + 2>/dev/null || true
  done

  local pyroot="$base/pytest-of-$(id -un)"
  if [[ -d "$pyroot" && -O "$pyroot" ]]; then
    find "$pyroot" -mindepth 1 -maxdepth 1 -uid "$(id -u)" -mmin "+$mmin" \
      -exec rm -rf {} + 2>/dev/null || true
    rmdir "$pyroot" 2>/dev/null || true   # remove the root only if now empty
  fi
  return 0
}

# ── Self-test (only when invoked directly: `bash chain-tmp.sh self-test`) ────
# Hermetic and fast: everything runs against a scratch CHAIN_TMP_ROOT.
# Lifecycle subtests run in CHILD bash processes so ownership semantics
# (owner pid vs non-owner) are exercised for real, not simulated.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    self-test)
      _p=0; _f=0
      _ok()  { _p=$((_p+1)); echo "  OK: $*"; }
      _bad() { _f=$((_f+1)); echo "  FAIL: $*" >&2; }
      T=$(mktemp -d)
      SELF="${BASH_SOURCE[0]}"

      # init: creates the named dir, exports the TMPDIR family, records owner
      if CHAIN_TMP_ROOT="$T" bash -c '
           source "'"$SELF"'"
           chain_tmp_init "goal-x-iter-1"
           [[ "$CHAIN_TMPDIR" == "'"$T"'/iad.goal-x-iter-1.$BASHPID" ]] || exit 1
           [[ -d "$CHAIN_TMPDIR" ]] || exit 2
           [[ "$TMPDIR" == "$CHAIN_TMPDIR" && "$TMP" == "$CHAIN_TMPDIR" && "$TEMP" == "$CHAIN_TMPDIR" ]] || exit 3
           [[ "$CHAIN_TMPDIR_OWNER_PID" == "$BASHPID" ]] || exit 4
           chain_tmp_cleanup
           [[ ! -d "$CHAIN_TMPDIR" ]] || exit 5'; then
        _ok "init creates+exports+owns; owner cleanup removes"
      else
        _bad "init/cleanup lifecycle (subtest exit $?)"
      fi

      # adopt: a second init in the same process must keep the first dir;
      # an init in a CHILD process must adopt (no second dir, no ownership)
      if CHAIN_TMP_ROOT="$T" bash -c '
           source "'"$SELF"'"
           chain_tmp_init "outer"
           prev="$CHAIN_TMPDIR"
           chain_tmp_init "other"
           [[ "$CHAIN_TMPDIR" == "$prev" ]] || exit 1
           bash -c "source \"'"$SELF"'\"; chain_tmp_init nested; chain_tmp_cleanup"
           [[ -d "$prev" ]] || exit 2                      # child cleanup must be a no-op
           n=$(ls -d "'"$T"'"/iad.* 2>/dev/null | wc -l)
           [[ "$n" -eq 1 ]] || exit 3                      # child must not mint a second dir
           chain_tmp_cleanup
           [[ ! -d "$prev" ]] || exit 4'; then
        _ok "adopt: same-process re-init and child init reuse the dir; non-owner cleanup no-op"
      else
        _bad "adopt semantics (subtest exit $?)"
      fi

      # sanitize: hostile run-id cannot escape the base dir
      if CHAIN_TMP_ROOT="$T" bash -c '
           source "'"$SELF"'"
           chain_tmp_init "../evil id/x"
           b="$(basename "$CHAIN_TMPDIR")"
           [[ "$b" == iad.* && "$CHAIN_TMPDIR" != *"/../"* && "$(dirname "$CHAIN_TMPDIR")" == "'"$T"'" ]] || exit 1
           chain_tmp_cleanup'; then
        _ok "init sanitizes hostile run-ids"
      else
        _bad "run-id sanitization (subtest exit $?)"
      fi

      # rotate: old dir goes, fresh dir comes
      if CHAIN_TMP_ROOT="$T" bash -c '
           source "'"$SELF"'"
           chain_tmp_init "iter-0"; a="$CHAIN_TMPDIR"; touch "$a/x.log"
           chain_tmp_rotate "iter-1"; b="$CHAIN_TMPDIR"
           [[ ! -d "$a" && -d "$b" && "$b" == *iter-1* ]] || exit 1
           chain_tmp_cleanup'; then
        _ok "rotate clears the previous dir and exports a fresh one"
      else
        _bad "rotate (subtest exit $?)"
      fi

      # disable knob: env left completely untouched
      if CHAIN_TMP_ROOT="$T" bash -c '
           source "'"$SELF"'"
           CHAIN_TMPDIR_DISABLE=true chain_tmp_init "x"
           [[ -z "${CHAIN_TMPDIR:-}" && -z "${TMPDIR:-}" ]]'; then
        _ok "CHAIN_TMPDIR_DISABLE leaves the environment untouched"
      else
        _bad "disable knob created state"
      fi

      # cleanup path-shape guard: refuses to rm a non-iad path
      if CHAIN_TMP_ROOT="$T" bash -c '
           source "'"$SELF"'"
           mkdir -p "'"$T"'/notiad"
           CHAIN_TMPDIR="'"$T"'/notiad" CHAIN_TMPDIR_OWNER_PID="$BASHPID" chain_tmp_cleanup
           [[ -d "'"$T"'/notiad" ]]'; then
        _ok "cleanup refuses a non-iad path"
      else
        _bad "cleanup removed a non-iad path"
      fi

      # janitor: age + pid-liveness + pattern safety (incl. sentinels)
      mkdir -p "$T/iad.dead.999999999" "$T/iad.live.$$" "$T/iad.fresh.999999998"
      touch -d '2 days ago' "$T/iad.dead.999999999" "$T/iad.live.$$"
      : > "$T/claude-quota-AbC123.log";  touch -d '2 days ago' "$T/claude-quota-AbC123.log"
      : > "$T/claude-quota-XyZ789.log"                          # fresh — must survive
      : > "$T/fanout-backend-3101.log"; touch -d '2 days ago' "$T/fanout-backend-3101.log"
      : > "$T/claude-usage-Qq1Ww2.json"; touch -d '2 days ago' "$T/claude-usage-Qq1Ww2.json"
      : > "$T/claude-quota-exhausted";  touch -d '2 days ago' "$T/claude-quota-exhausted"
      : > "$T/codex-quota-exhausted";   touch -d '2 days ago' "$T/codex-quota-exhausted"
      _pyroot="$T/pytest-of-$(id -un)"
      mkdir -p "$_pyroot/garbage-1" "$_pyroot/pytest-7"
      touch -d '2 days ago' "$_pyroot/garbage-1"
      # Call the function directly — it is already defined above. Do NOT
      # `source "$SELF"` from a subshell of this script: there BASH_SOURCE==$0
      # and $1 is still "self-test", so the sourced copy re-enters this arm
      # and recurses forever.
      CHAIN_TMP_ROOT="$T" chain_tmp_janitor
      [[ ! -d "$T/iad.dead.999999999" ]]      && _ok "janitor reaps old dir with dead pid"    || _bad "old dead-pid dir survived"
      [[ -d "$T/iad.live.$$" ]]               && _ok "janitor keeps old dir with LIVE pid"    || _bad "live-pid dir was reaped"
      [[ -d "$T/iad.fresh.999999998" ]]       && _ok "janitor keeps fresh dir"                || _bad "fresh dir was reaped"
      [[ ! -f "$T/claude-quota-AbC123.log" ]] && _ok "janitor reaps old quota log"            || _bad "old quota log survived"
      [[ -f "$T/claude-quota-XyZ789.log" ]]   && _ok "janitor keeps fresh quota log"          || _bad "fresh quota log reaped"
      [[ ! -f "$T/fanout-backend-3101.log" ]] && _ok "janitor reaps old service log"          || _bad "old service log survived"
      [[ ! -f "$T/claude-usage-Qq1Ww2.json" ]] && _ok "janitor reaps old usage sidecar"       || _bad "old usage sidecar survived"
      if [[ -f "$T/claude-quota-exhausted" && -f "$T/codex-quota-exhausted" ]]; then
        _ok "janitor NEVER touches the quota sentinels"
      else
        _bad "a quota sentinel was deleted"
      fi
      [[ ! -d "$_pyroot/garbage-1" ]]         && _ok "janitor reaps old pytest-of entry"      || _bad "old pytest-of entry survived"
      [[ -d "$_pyroot/pytest-7" ]]            && _ok "janitor keeps fresh pytest-of entry"    || _bad "fresh pytest-of entry reaped"

      # janitor disable knob
      mkdir -p "$T/iad.dead2.999999997"; touch -d '2 days ago' "$T/iad.dead2.999999997"
      CHAIN_TMP_ROOT="$T" CHAIN_TMP_JANITOR=false chain_tmp_janitor
      [[ -d "$T/iad.dead2.999999997" ]]       && _ok "CHAIN_TMP_JANITOR=false disables the sweep" || _bad "janitor ran while disabled"

      rm -rf "$T"
      echo "[chain-tmp self-test] ${_p} pass, ${_f} fail"
      [[ "$_f" -eq 0 ]] || exit 1
      ;;
    *)
      echo "Usage: $0 self-test" >&2
      exit 2
      ;;
  esac
fi
