#!/usr/bin/env bash
# chain-tmp.sh — per-run TMPDIR isolation, owner-guarded cleanup, a multi-root
# janitor for strays, and a disk-pressure guard. Sourced by lib/common.sh so
# every pipeline script gets these; safe under `set -euo pipefail`.
#
# Why: multiple pipeline jobs (different projects) run concurrently on one
# machine as the same user. Tools the agents run (pytest, playwright/chromium,
# mktemp) used to write to shared /tmp — on some machines a QUOTA'D tmpfs
# (EDQUOT long before the fs looks full) — and race each other's pruning (see
# .claude/anti-patterns/21-shared-tmp-accumulation.md). Each run now gets its own short-lived dir
# under CHAIN_TMP_ROOT (default ~/.cache/iad: big, unquota'd disk — NOT /tmp),
# exported as TMPDIR, so cleanup is a single owner-guarded rm. /tmp remains a
# LEGACY janitor root so pre-relocation strays still get reaped.
#
# API:
#   chain_tmp_init <run-id>    create+export, or ADOPT an inherited dir (nested)
#   chain_tmp_cleanup          remove the dir iff THIS process created it
#   chain_tmp_rotate <run-id>  cleanup (if owner) + fresh init — iteration boundary
#   chain_tmp_janitor [--aggressive]
#                              sweep strays from crashed/legacy runs. Normal:
#                              age+liveness gates. --aggressive (disk pressure):
#                              dead-pid run dirs reaped at ANY age; pattern
#                              sweeps use the aggressive age gate.
#   chain_tmp_disk_guard [--soft|--enforce]
#                              free-space check; under pressure runs the
#                              aggressive janitor. --enforce returns rc 2 when
#                              CHAIN_TMP_ROOT's fs is still under the hard
#                              floor AFTER sweeping (engines pause on that).
#                              /tmp quota pressure is sweep+WARN only — the
#                              chain no longer depends on /tmp.
#
# Knobs:
#   CHAIN_TMPDIR_DISABLE=true    leave the environment completely untouched
#   CHAIN_TMP_JANITOR=false      disable the janitor sweep
#   CHAIN_TMP_ROOT=~/.cache/iad  base dir (tests point this at a scratch dir)
#   CHAIN_TMP_LEGACY_ROOTS=/tmp  colon-separated extra janitor roots; set to ""
#                                to disable (tests MUST, for hermeticity)
#   CHAIN_TMP_MAX_AGE_HOURS=24   janitor age gate (normal mode)
#   CHAIN_TMP_AGGRESSIVE_MIN_AGE_MINUTES=60  pattern-sweep age gate, aggressive mode
#   CHAIN_TMP_SHARED_MAX_AGE_HOURS=72  blanket gate for $CHAIN_TMP_ROOT/shared
#   CHAIN_BENCH_KEEP=2           newest bench-* scratches always kept
#   CHAIN_TMP_DISK_GUARD=false   disable the disk guard
#   CHAIN_TMP_MIN_FREE_MB=2048   soft threshold on CHAIN_TMP_ROOT's fs → sweep
#   CHAIN_TMP_HARD_MIN_FREE_MB=512  post-sweep floor → rc 2 (enforce mode only)
#   CHAIN_TMP_PROBE_MB=32        /tmp write-probe size in MB; 0 skips the probe
#
# NOTE the /tmp/{claude,codex}-quota-exhausted sentinels (lib/quota-retry.sh)
# are INTENTIONALLY shared across concurrent jobs (quota is account-global):
# they stay at fixed /tmp paths and the janitor never matches these names.
#
# Concurrency: janitors from concurrent engines run UNLOCKED by design — every
# operation is an idempotent forced rm of a path proven dead (pid-liveness) or
# stale (age), so a lost race is a swallowed ENOENT. The bench keep-newest-N
# decision may transiently keep one extra dir across racing sweeps; harmless.

# chain_tmp_init <run-id> — creates $CHAIN_TMP_ROOT/iad.<id>.<pid> and exports
# TMPDIR/TMP/TEMP + CHAIN_TMPDIR + CHAIN_TMPDIR_OWNER_PID. The WHOLE TMPDIR
# must stay ≤ 62 chars: Chromium's singleton socket is
# $TMPDIR/.org.chromium.Chromium.XXXXXX/SingletonSocket (46 chars) against the
# 108-char sun_path limit — ids that don't fit are shortened to
# <prefix>-<sha256-first8>, with the raw id preserved in .chain-run-id.
# Idempotent: when CHAIN_TMPDIR is already set and exists (run-phase.sh nested
# under run-goal.sh), the inherited dir is adopted WITHOUT taking ownership —
# but only when its recorded owner is unset, self, or still alive; a stale
# inherit from a dead engine mints a fresh dir instead (the janitor may reap
# the dead one at any moment). Never fails the caller.
chain_tmp_init() {
  [[ "${CHAIN_TMPDIR_DISABLE:-false}" == "true" ]] && return 0
  if [[ -n "${CHAIN_TMPDIR:-}" && -d "${CHAIN_TMPDIR:-}" ]]; then
    local _own="${CHAIN_TMPDIR_OWNER_PID:-}"
    if [[ -z "$_own" || "$_own" == "${BASHPID:-$$}" ]] || kill -0 "$_own" 2>/dev/null; then
      export TMPDIR="$CHAIN_TMPDIR" TMP="$CHAIN_TMPDIR" TEMP="$CHAIN_TMPDIR"
      return 0
    fi
    unset CHAIN_TMPDIR CHAIN_TMPDIR_OWNER_PID   # stale inherit from a dead run — mint fresh
  fi
  local raw_id="${1:-run}" base="${CHAIN_TMP_ROOT:-$HOME/.cache/iad}"
  if ! mkdir -p "$base" 2>/dev/null; then base="/tmp"; fi
  mkdir -p "$base/shared" 2>/dev/null || true   # interactive-TMPDIR target self-heals
  # ${BASHPID:-$$} for BOTH the name suffix and the owner record, so name and
  # owner always agree even when init runs in a subshell.
  local pid="${BASHPID:-$$}" id
  id="$(printf '%s' "$raw_id" | tr -c 'a-zA-Z0-9._-' '-' | cut -c1-60)"
  local budget=$(( 62 - ${#base} - 1 - 4 - 1 - ${#pid} ))
  if (( ${#id} > budget )); then
    local h; h="$(printf '%s' "$raw_id" | sha256sum | cut -c1-8)"
    if (( budget >= 9 )); then id="${id:0:budget-9}-$h"; else id="$h"; fi
  fi
  local dir="$base/iad.${id}.${pid}"
  if ! mkdir -p "$dir" 2>/dev/null; then
    echo "[chain-tmp] WARNING: cannot create $dir — keeping the shared default tmp." >&2
    return 0
  fi
  chmod 700 "$dir" 2>/dev/null || true
  printf 'id=%s\nowner_pid=%s\ncreated=%s\n' "$raw_id" "$pid" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$dir/.chain-run-id" 2>/dev/null || true
  export CHAIN_TMPDIR="$dir"
  export CHAIN_TMPDIR_OWNER_PID="$pid"
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

# _chain_tmp_dir_owner_alive <dir> — liveness via the dir's .owner-pid file
# (written by run-benchmark.sh / run-judgment-evals.sh). Legacy leaked dirs
# lack the file → rc 1 → the age gate alone decides.
_chain_tmp_dir_owner_alive() {
  local f="$1/.owner-pid" p
  [[ -f "$f" ]] || return 1
  read -r p < "$f" 2>/dev/null || return 1
  [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null
}

# chain_tmp_janitor [--aggressive] — reap strays owned by this user across
# CHAIN_TMP_ROOT plus the legacy roots:
#   1. iad.* run dirs whose embedded owner pid is dead — with the age gate in
#      normal mode (mtime alone is unsafe: writes to files INSIDE a dir don't
#      touch the dir's mtime, so a >24h live goal session could look stale);
#      under --aggressive a dead pid is proof enough at ANY age.
#   2. bench-*/judgment-* scratch dirs — .owner-pid liveness + age gate;
#      bench keeps the newest CHAIN_BENCH_KEEP regardless.
#   3. legacy loose files in each root from pre-TMPDIR runs (quota/usage
#      mktemp leftovers, per-role service logs) — age-gated.
#   4. entries under <root>/pytest-of-$USER (numbered basetemp dirs,
#      garbage-*, stale .lock) — age-gated so a live concurrent run is safe.
#   5. entries under $CHAIN_TMP_ROOT/shared (the machine-wide interactive
#      TMPDIR target) — blanket 72h gate, faster for pytest basetemps inside;
#      never removes shared/ itself.
# NEVER touches the quota sentinels (no pattern matches their fixed names:
# 'claude-quota-??????.log' requires a 6-char suffix plus '.log', which
# 'claude-quota-exhausted' has neither of).
chain_tmp_janitor() {
  [[ "${CHAIN_TMP_JANITOR:-true}" == "true" ]] || return 0
  local aggressive=false
  [[ "${1:-}" == "--aggressive" ]] && aggressive=true
  local max_age_hours="${CHAIN_TMP_MAX_AGE_HOURS:-24}"
  [[ "$max_age_hours" =~ ^[0-9]+$ ]] || max_age_hours=24
  local mmin=$(( max_age_hours * 60 ))
  if $aggressive; then
    mmin="${CHAIN_TMP_AGGRESSIVE_MIN_AGE_MINUTES:-60}"
    [[ "$mmin" =~ ^[0-9]+$ ]] || mmin=60
  fi
  local base="${CHAIN_TMP_ROOT:-$HOME/.cache/iad}"
  mkdir -p "$base" 2>/dev/null || true

  # Roots: base + colon-split legacy list (default /tmp; "" disables — tests).
  local -a roots=("$base")
  local _legacy="${CHAIN_TMP_LEGACY_ROOTS-/tmp}" _r
  while [[ -n "$_legacy" ]]; do
    _r="${_legacy%%:*}"
    if [[ "$_legacy" == *:* ]]; then _legacy="${_legacy#*:}"; else _legacy=""; fi
    [[ -n "$_r" && "$_r" != "$base" && -d "$_r" ]] && roots+=("$_r")
  done

  local root d pid pat keep n pyroot
  for root in "${roots[@]}"; do
    for d in "$root"/iad.*; do
      [[ -e "$d" ]] || continue
      [[ -O "$d" ]] || continue
      if ! $aggressive; then
        [[ -n "$(find "$d" -maxdepth 0 -mmin "+$mmin" 2>/dev/null)" ]] || continue
      fi
      pid="${d##*.}"
      if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        continue   # owning process still alive — never touch, whatever the age
      fi
      rm -rf -- "$d" 2>/dev/null || true
    done

    keep="${CHAIN_BENCH_KEEP:-2}"
    [[ "$keep" =~ ^[0-9]+$ ]] || keep=2
    n=0
    # shellcheck disable=SC2045  # bench names are space-free by construction
    for d in $(ls -1dt "$root"/bench-* 2>/dev/null); do
      [[ -d "$d" && -O "$d" ]] || continue
      n=$((n+1)); (( n <= keep )) && continue
      _chain_tmp_dir_owner_alive "$d" && continue
      [[ -n "$(find "$d" -maxdepth 0 -mmin "+$mmin" 2>/dev/null)" ]] || continue
      rm -rf -- "$d" 2>/dev/null || true
    done

    for d in "$root"/judgment-*; do
      [[ -d "$d" && -O "$d" ]] || continue
      _chain_tmp_dir_owner_alive "$d" && continue
      [[ -n "$(find "$d" -maxdepth 0 -mmin "+$mmin" 2>/dev/null)" ]] || continue
      rm -rf -- "$d" 2>/dev/null || true
    done

    for pat in 'claude-quota-??????.log' 'codex-quota-??????.log' \
               'claude-usage-??????.json' 'codex-usage-??????.json' \
               'qa-backend*.log' 'qa-frontend*.log' \
               'browser-qa-backend*.log' 'browser-qa-frontend*.log' \
               'fanout-backend*.log' 'fanout-frontend*.log' \
               'demo-backend*.log' 'demo-frontend*.log' \
               'goal-iter-backend*.log' 'goal-iter-frontend*.log'; do
      find "$root" -maxdepth 1 -type f -name "$pat" -uid "$(id -u)" \
        -mmin "+$mmin" -exec rm -f {} + 2>/dev/null || true
    done

    pyroot="$root/pytest-of-$(id -un)"
    if [[ -d "$pyroot" && -O "$pyroot" ]]; then
      find "$pyroot" -mindepth 1 -maxdepth 1 -uid "$(id -u)" -mmin "+$mmin" \
        -exec rm -rf {} + 2>/dev/null || true
      rmdir "$pyroot" 2>/dev/null || true   # remove the root only if now empty
    fi
  done

  local sh="$base/shared" smin
  smin="${CHAIN_TMP_SHARED_MAX_AGE_HOURS:-72}"
  [[ "$smin" =~ ^[0-9]+$ ]] || smin=72
  smin=$(( smin * 60 ))
  $aggressive && smin="$mmin"
  if [[ -d "$sh" && -O "$sh" ]]; then
    find "$sh" -mindepth 1 -maxdepth 1 -uid "$(id -u)" -mmin "+$smin" \
      -exec rm -rf {} + 2>/dev/null || true
    local spy="$sh/pytest-of-$(id -un)"
    if [[ -d "$spy" ]]; then
      find "$spy" -mindepth 1 -maxdepth 1 -uid "$(id -u)" -mmin "+$mmin" \
        -exec rm -rf {} + 2>/dev/null || true
    fi
  fi
  return 0
}

# _chain_tmp_free_mb <path> — filesystem free MB via statvfs (authoritative
# for the unquota'd ext4 root; python3 keeps this dependency-free).
_chain_tmp_free_mb() {
  python3 - "$1" <<'PY' 2>/dev/null
import os, sys
st = os.statvfs(sys.argv[1])
print(st.f_bavail * st.f_frsize // (1024 * 1024))
PY
}

# _chain_tmp_write_probe <root> <mb> — rc 0: the target can absorb <mb> MB.
# statvfs on a QUOTA'D tmpfs reports fs free, not the user's remaining quota —
# an attempt-write is the only honest check (rc 3 on ENOSPC/EDQUOT).
_chain_tmp_write_probe() {
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import os, sys
root, mb = sys.argv[1], int(sys.argv[2])
p = os.path.join(root, ".iad-probe.%d" % os.getpid())
try:
    with open(p, "wb") as f:
        chunk = b"\0" * (1 << 20)
        for _ in range(mb):
            f.write(chunk)
except OSError as e:
    sys.exit(3 if e.errno in (28, 122) else 4)   # ENOSPC / EDQUOT
finally:
    try:
        os.remove(p)
    except OSError:
        pass
PY
}

# chain_tmp_disk_guard [--soft|--enforce] — rc 0 healthy/healed; rc 2
# (--enforce only): CHAIN_TMP_ROOT's filesystem is still under the hard floor
# AFTER an aggressive sweep — the engine turns that into a resumable
# AWAITING_DISK pause instead of a mid-run ENOSPC mystery. /tmp quota pressure
# is swept + WARNED but never rc 2: the chain no longer depends on /tmp, and
# leftover pressure there is foreign files we cannot (and must not) rm.
chain_tmp_disk_guard() {
  [[ "${CHAIN_TMP_DISK_GUARD:-true}" == "true" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  local mode="${1:---soft}" rc=0
  local base="${CHAIN_TMP_ROOT:-$HOME/.cache/iad}"
  mkdir -p "$base" 2>/dev/null || true
  local min="${CHAIN_TMP_MIN_FREE_MB:-2048}" hard="${CHAIN_TMP_HARD_MIN_FREE_MB:-512}" free
  [[ "$min" =~ ^[0-9]+$ ]] || min=2048
  [[ "$hard" =~ ^[0-9]+$ ]] || hard=512
  free="$(_chain_tmp_free_mb "$base" || true)"
  if [[ -n "$free" && "$free" -lt "$min" ]]; then
    echo "[chain-tmp] disk guard: ${free}MB free under $base (< ${min}MB) — aggressive sweep." >&2
    chain_tmp_janitor --aggressive
    free="$(_chain_tmp_free_mb "$base" || true)"
    if [[ -n "$free" && "$free" -lt "$hard" ]]; then
      echo "[chain-tmp] disk guard: ${free}MB free (< ${hard}MB hard floor) after sweep." >&2
      [[ "$mode" == "--enforce" ]] && rc=2
    fi
  fi
  local probe_mb="${CHAIN_TMP_PROBE_MB:-32}"
  [[ "$probe_mb" =~ ^[0-9]+$ ]] || probe_mb=32
  if [[ "$probe_mb" -gt 0 && -d /tmp && -w /tmp ]]; then
    if ! _chain_tmp_write_probe /tmp "$probe_mb"; then
      echo "[chain-tmp] disk guard: /tmp cannot absorb ${probe_mb}MB (quota/ENOSPC) — sweeping strays." >&2
      chain_tmp_janitor --aggressive
      if ! _chain_tmp_write_probe /tmp "$probe_mb"; then
        echo "[chain-tmp] WARNING: /tmp still over quota after sweep (likely foreign files); chain temp lives under $base — continuing." >&2
      fi
    fi
  fi
  return "$rc"
}

# ── Self-test (only when invoked directly: `bash chain-tmp.sh self-test`) ────
# Hermetic and fast: everything runs against a scratch CHAIN_TMP_ROOT, and
# every janitor/guard call passes CHAIN_TMP_LEGACY_ROOTS="" so the REAL /tmp
# is never swept from a test. Lifecycle subtests run in CHILD bash processes
# so ownership semantics (owner pid vs non-owner) are exercised for real.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    self-test)
      _p=0; _f=0
      _ok()  { _p=$((_p+1)); echo "  OK: $*"; }
      _bad() { _f=$((_f+1)); echo "  FAIL: $*" >&2; }
      # Pin the scratch root to a SHORT path: the session TMPDIR may point at
      # a deep dir (settings env → ~/.cache/iad/shared), which would push every
      # test dir past the 62-char socket budget and hash-shorten the names the
      # assertions below expect verbatim.
      T=$(TMPDIR=/tmp mktemp -d)
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

      # stale adopt: an inherited CHAIN_TMPDIR whose recorded owner is DEAD
      # must NOT be adopted — a fresh dir is minted instead (the janitor may
      # reap the dead one at any moment).
      mkdir -p "$T/iad.stale.999999999"
      if CHAIN_TMP_ROOT="$T" CHAIN_TMPDIR="$T/iad.stale.999999999" \
         CHAIN_TMPDIR_OWNER_PID=999999999 bash -c '
           source "'"$SELF"'"
           chain_tmp_init "fresh-after-stale"
           [[ "$CHAIN_TMPDIR" != "'"$T"'/iad.stale.999999999" ]] || exit 1
           [[ "$CHAIN_TMPDIR" == "'"$T"'"/iad.fresh-after-stale.* ]] || exit 2
           chain_tmp_cleanup'; then
        _ok "init refuses to adopt a dir owned by a dead pid (mints fresh)"
      else
        _bad "stale-owner adopt (subtest exit $?)"
      fi
      rm -rf "$T/iad.stale.999999999"

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

      # socket-length budget: a long run-id is shortened so the WHOLE TMPDIR
      # stays ≤ 62 chars (Chromium's 108-char sun_path limit minus the 46-char
      # singleton-socket suffix); the raw id is preserved in .chain-run-id.
      if CHAIN_TMP_ROOT="$T" bash -c '
           source "'"$SELF"'"
           long="goal-a-very-long-session-name-that-cannot-possibly-fit-iter-123"
           chain_tmp_init "$long"
           [[ "${#CHAIN_TMPDIR}" -le 62 ]] || exit 1
           grep -q "id=$long" "$CHAIN_TMPDIR/.chain-run-id" || exit 2
           [[ "$CHAIN_TMPDIR" == *".$BASHPID" ]] || exit 3
           chain_tmp_cleanup'; then
        _ok "init shortens long ids to the 62-char socket budget (raw id in marker)"
      else
        _bad "socket-length budget (subtest exit $?)"
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

      # disable knob: env left completely untouched (unset the session TMPDIR
      # first — settings env may pre-set it — so "still empty" proves init
      # created nothing)
      if CHAIN_TMP_ROOT="$T" bash -c '
           unset TMPDIR TMP TEMP CHAIN_TMPDIR CHAIN_TMPDIR_OWNER_PID
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
      CHAIN_TMP_ROOT="$T" CHAIN_TMP_LEGACY_ROOTS="" chain_tmp_janitor
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

      # janitor: legacy-root sweep (a stray in a second root is reaped)
      L=$(TMPDIR=/tmp mktemp -d)
      mkdir -p "$L/iad.legacydead.999999995"; touch -d '2 days ago' "$L/iad.legacydead.999999995"
      CHAIN_TMP_ROOT="$T" CHAIN_TMP_LEGACY_ROOTS="$L" chain_tmp_janitor
      [[ ! -d "$L/iad.legacydead.999999995" ]] && _ok "janitor sweeps legacy roots too" || _bad "legacy-root stray survived"
      rm -rf "$L"

      # janitor: bench-* retention — newest CHAIN_BENCH_KEEP survive, live
      # .owner-pid survives at any age/position, older dead ones are reaped
      mkdir -p "$T/bench-w.111111" "$T/bench-x.222222" "$T/bench-y.333333" "$T/bench-z.444444" "$T/bench-live.555555"
      touch -d '25 hours ago' "$T/bench-w.111111"
      touch -d '26 hours ago' "$T/bench-x.222222"
      touch -d '2 days ago'   "$T/bench-y.333333"
      touch -d '3 days ago'   "$T/bench-z.444444"
      touch -d '4 days ago'   "$T/bench-live.555555"
      echo "$$" > "$T/bench-live.555555/.owner-pid"
      touch -d '4 days ago'   "$T/bench-live.555555"   # keep the dir mtime old
      CHAIN_TMP_ROOT="$T" CHAIN_TMP_LEGACY_ROOTS="" chain_tmp_janitor
      if [[ -d "$T/bench-w.111111" && -d "$T/bench-x.222222" && ! -d "$T/bench-y.333333" && ! -d "$T/bench-z.444444" && -d "$T/bench-live.555555" ]]; then
        _ok "janitor keeps newest-2 bench scratches + live-owner; reaps the rest"
      else
        _bad "bench retention (w:$(test -d "$T/bench-w.111111" && echo y || echo n) x:$(test -d "$T/bench-x.222222" && echo y || echo n) y:$(test -d "$T/bench-y.333333" && echo y || echo n) z:$(test -d "$T/bench-z.444444" && echo y || echo n) live:$(test -d "$T/bench-live.555555" && echo y || echo n))"
      fi
      rm -rf "$T"/bench-*

      # janitor: judgment-* sandboxes — dead+old reaped, live-owner kept
      mkdir -p "$T/judgment-old.aaa" "$T/judgment-live.bbb"
      touch -d '2 days ago' "$T/judgment-old.aaa" "$T/judgment-live.bbb"
      echo "$$" > "$T/judgment-live.bbb/.owner-pid"
      touch -d '2 days ago' "$T/judgment-live.bbb"
      CHAIN_TMP_ROOT="$T" CHAIN_TMP_LEGACY_ROOTS="" chain_tmp_janitor
      [[ ! -d "$T/judgment-old.aaa" ]] && _ok "janitor reaps old judgment sandbox" || _bad "old judgment sandbox survived"
      [[ -d "$T/judgment-live.bbb" ]]  && _ok "janitor keeps live-owner judgment sandbox" || _bad "live judgment sandbox reaped"
      rm -rf "$T"/judgment-*

      # janitor: shared/ sweep — >72h entries reaped, fresh kept, shared/ kept
      mkdir -p "$T/shared/old-entry" "$T/shared/fresh-entry"
      touch -d '4 days ago' "$T/shared/old-entry"
      CHAIN_TMP_ROOT="$T" CHAIN_TMP_LEGACY_ROOTS="" chain_tmp_janitor
      [[ ! -d "$T/shared/old-entry" ]] && _ok "janitor reaps >72h shared/ entry" || _bad "old shared/ entry survived"
      [[ -d "$T/shared/fresh-entry" ]] && _ok "janitor keeps fresh shared/ entry" || _bad "fresh shared/ entry reaped"
      [[ -d "$T/shared" ]]             && _ok "janitor never removes shared/ itself" || _bad "shared/ was removed"

      # janitor disable knob
      mkdir -p "$T/iad.dead2.999999997"; touch -d '2 days ago' "$T/iad.dead2.999999997"
      CHAIN_TMP_ROOT="$T" CHAIN_TMP_LEGACY_ROOTS="" CHAIN_TMP_JANITOR=false chain_tmp_janitor
      [[ -d "$T/iad.dead2.999999997" ]]       && _ok "CHAIN_TMP_JANITOR=false disables the sweep" || _bad "janitor ran while disabled"
      rm -rf "$T/iad.dead2.999999997"

      # disk guard: enforce mode returns rc 2 when the (forced) hard floor is
      # breached after sweeping, and the aggressive pass reaps a FRESH dead-pid
      # dir (no age gate under pressure); soft mode never returns rc 2.
      mkdir -p "$T/iad.deadfresh.999999996"     # fresh mtime — only aggressive reaps it
      CHAIN_TMP_ROOT="$T" CHAIN_TMP_LEGACY_ROOTS="" CHAIN_TMP_PROBE_MB=0 \
        CHAIN_TMP_MIN_FREE_MB=999999999 CHAIN_TMP_HARD_MIN_FREE_MB=999999999 \
        chain_tmp_disk_guard --enforce 2>/dev/null
      _rc=$?
      [[ "$_rc" -eq 2 ]] && _ok "disk guard --enforce breaches hard floor → rc 2" || _bad "disk guard enforce rc was $_rc (want 2)"
      [[ ! -d "$T/iad.deadfresh.999999996" ]] && _ok "aggressive sweep reaps FRESH dead-pid dir (no age gate)" || _bad "aggressive sweep kept a fresh dead-pid dir"
      CHAIN_TMP_ROOT="$T" CHAIN_TMP_LEGACY_ROOTS="" CHAIN_TMP_PROBE_MB=0 \
        CHAIN_TMP_MIN_FREE_MB=999999999 CHAIN_TMP_HARD_MIN_FREE_MB=999999999 \
        chain_tmp_disk_guard --soft 2>/dev/null
      _rc=$?
      [[ "$_rc" -eq 0 ]] && _ok "disk guard --soft never escalates (rc 0)" || _bad "disk guard soft rc was $_rc (want 0)"
      CHAIN_TMP_ROOT="$T" CHAIN_TMP_LEGACY_ROOTS="" CHAIN_TMP_PROBE_MB=0 \
        chain_tmp_disk_guard --enforce 2>/dev/null
      _rc=$?
      [[ "$_rc" -eq 0 ]] && _ok "disk guard healthy thresholds → rc 0" || _bad "disk guard healthy rc was $_rc (want 0)"
      CHAIN_TMP_ROOT="$T" CHAIN_TMP_LEGACY_ROOTS="" CHAIN_TMP_DISK_GUARD=false \
        CHAIN_TMP_MIN_FREE_MB=999999999 CHAIN_TMP_HARD_MIN_FREE_MB=999999999 \
        chain_tmp_disk_guard --enforce 2>/dev/null
      _rc=$?
      [[ "$_rc" -eq 0 ]] && _ok "CHAIN_TMP_DISK_GUARD=false disables the guard" || _bad "disabled guard rc was $_rc (want 0)"

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
