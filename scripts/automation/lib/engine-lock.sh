#!/usr/bin/env bash
# lib/engine-lock.sh — REL-4 cross-session engine lock.
#
# "One repo, one live session" used to be a convention; this makes it a
# mechanism. run-goal.sh takes runs/goal-session-<sid>/.engine.lock (one live
# engine per session id), run-phase.sh takes the repo-level runs/.phase.lock
# (one phase pipeline per repo — goal-mode full-depth iterations invoke
# run-phase.sh as a child, so they hold it for the iteration's duration).
#
# Mechanics:
#   - Acquisition is mkdir-atomic: the lock is a DIRECTORY; whoever mkdirs it
#     owns it. Metadata files inside (pid / host / epoch / cmd) identify the
#     holder — the preflight doctor reads the same files for its engine-lock
#     row, so keep the layout stable.
#   - Held lock → staleness verdict, never a silent wait:
#       same host  : kill -0 <pid>; alive but /proc cmdline no longer matches
#                    the recorded cmd → pid was RECYCLED after a crash → stale
#                    (same cmdline sanity the resume self-heal uses on
#                    engine.pid). Liveness probes that can't run degrade to
#                    FRESH (refuse) — never steal a lock on a maybe.
#       cross host : kill -0 can't cross hosts, so age decides — older than
#                    CHAIN_ENGINE_LOCK_CROSS_HOST_TTL (default 86400s = 24h,
#                    longer than any plausible session incl. quota sleeps) →
#                    stale. Crashed remote holders block that ONE lock path
#                    until the TTL or a manual removal (TROUBLESHOOTING).
#       no metadata: acquirer crashed mid-write, or a racing acquirer is
#                    still writing — younger (dir mtime) than
#                    CHAIN_ENGINE_LOCK_INIT_GRACE (default 60s) → fresh,
#                    else stale.
#     FRESH → refuse fast: message naming pid/host/age + the TROUBLESHOOTING
#     section, exit code ENGINE_LOCK_REFUSED_EXIT (86 — distinct from 70
#     transport, 75 quota, 130/137/143 signals).
#     STALE → replace with ONE logged warning and carry on. When in doubt the
#     design prefers refusing over stealing, but a proven-dead holder must
#     never cost the user a restart ("strictly less availability-risky than
#     no lock").
#   - Release rides the callers' EXISTING composed EXIT traps (pause exits,
#     Ctrl-C via on_abort/_run_phase_aborted, normal exits all funnel there).
#     Owner-only: release compares the recorded pid to $$ so a refused second
#     engine can never delete the holder's lock. A SIGKILLed holder skips its
#     trap by definition — that is exactly the dead-pid stale case above.
#
# Ops notes: docs/TROUBLESHOOTING.md § "Engine refuses to start — lock held".

# Idempotent under re-source (run-goal.sh and run-phase.sh both source this).
ENGINE_LOCK_REFUSED_EXIT=86

# The one lock this process currently holds (one engine = one lock).
_ENGINE_LOCK_HELD="${_ENGINE_LOCK_HELD:-}"

_engine_lock_host() { hostname 2>/dev/null || uname -n 2>/dev/null || echo "unknown-host"; }

# _engine_lock_meta <lockdir> <name> — print a metadata file's first line, or "".
_engine_lock_meta() {
  head -n1 "$1/$2" 2>/dev/null || true
}

# _engine_lock_age_secs <lockdir> — seconds since acquisition (epoch file),
# falling back to the dir's mtime; prints "" when neither is readable.
_engine_lock_age_secs() {
  local now epoch
  now="$(date +%s)"
  epoch="$(_engine_lock_meta "$1" epoch | tr -dc 0-9)"
  if [[ -z "$epoch" ]]; then
    epoch="$(stat -c %Y "$1" 2>/dev/null | tr -dc 0-9)"
  fi
  [[ -n "$epoch" ]] || { echo ""; return 0; }
  echo $(( now - epoch ))
}

# engine_lock_classify <lockdir> — verdict on an EXISTING lock, read-only
# (the doctor's engine-lock row calls this too; never mutate here).
# stdout: "FRESH|<pid>|<host>|<age>|<why>"  or  "STALE|<pid>|<host>|<age>|<why>"
engine_lock_classify() {
  local dir="$1" pid host cmd age ttl grace myhost
  pid="$(_engine_lock_meta "$dir" pid | tr -dc 0-9)"
  host="$(_engine_lock_meta "$dir" host)"
  cmd="$(_engine_lock_meta "$dir" cmd)"
  age="$(_engine_lock_age_secs "$dir")"
  myhost="$(_engine_lock_host)"
  ttl="${CHAIN_ENGINE_LOCK_CROSS_HOST_TTL:-86400}"
  grace="${CHAIN_ENGINE_LOCK_INIT_GRACE:-60}"
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=86400
  [[ "$grace" =~ ^[0-9]+$ ]] || grace=60

  if [[ -z "$pid" ]]; then
    if [[ -n "$age" && "$age" -gt "$grace" ]]; then
      echo "STALE||${host:-?}|${age:-?}|no metadata and older than the ${grace}s init grace — acquirer crashed mid-write"
    else
      echo "FRESH||${host:-?}|${age:-?}|no metadata yet — a racing acquirer may still be initializing (${grace}s grace)"
    fi
    return 0
  fi

  if [[ -n "$host" && "$host" != "$myhost" ]]; then
    if [[ -n "$age" && "$age" -gt "$ttl" ]]; then
      echo "STALE|$pid|$host|${age:-?}|cross-host lock older than the ${ttl}s TTL (CHAIN_ENGINE_LOCK_CROSS_HOST_TTL)"
    else
      echo "FRESH|$pid|$host|${age:-?}|held on another host; liveness unprovable — age under the ${ttl}s TTL"
    fi
    return 0
  fi

  if kill -0 "$pid" 2>/dev/null; then
    # Same-host pid is alive — but pids get recycled across crashes/reboots.
    # If /proc says the live process is something else entirely, the holder
    # is gone. Unreadable /proc or missing cmd metadata → assume FRESH.
    if [[ -n "$cmd" && -r "/proc/$pid/cmdline" ]] && ! grep -qa -- "$cmd" "/proc/$pid/cmdline" 2>/dev/null; then
      echo "STALE|$pid|${host:-$myhost}|${age:-?}|pid is alive but runs '$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | head -c 60)', not '$cmd' — pid recycled after a crash"
    else
      echo "FRESH|$pid|${host:-$myhost}|${age:-?}|process is alive (kill -0)"
    fi
  else
    echo "STALE|$pid|${host:-$myhost}|${age:-?}|process is dead (kill -0 failed)"
  fi
  return 0
}

# acquire_engine_lock <lockdir> <label>
#   0                        → acquired (fresh, or stale lock replaced loudly)
#   ENGINE_LOCK_REFUSED_EXIT → a live holder owns it; message already printed
# Set-e-safe: call as `acquire_engine_lock "$dir" "label" || exit $?`.
acquire_engine_lock() {
  local dir="$1" label="${2:-engine}" attempt verdict state pid host age why
  mkdir -p "$(dirname "$dir")" 2>/dev/null || true

  for attempt in 1 2 3; do
    if mkdir "$dir" 2>/dev/null; then
      {
        echo "$$"              > "$dir/pid"
        _engine_lock_host      > "$dir/host"
        date +%s               > "$dir/epoch"
        basename -- "$0" 2>/dev/null > "$dir/cmd"
      } 2>/dev/null || true
      _ENGINE_LOCK_HELD="$dir"
      return 0
    fi

    # mkdir lost: somebody holds it (or a stale corpse does). Rule on it.
    verdict="$(engine_lock_classify "$dir")"
    state="${verdict%%|*}"
    pid="$(echo "$verdict" | cut -d'|' -f2)"
    host="$(echo "$verdict" | cut -d'|' -f3)"
    age="$(echo "$verdict" | cut -d'|' -f4)"
    why="$(echo "$verdict" | cut -d'|' -f5-)"

    if [[ "$state" == "STALE" ]]; then
      echo "[engine-lock] WARNING: replacing stale lock $dir (pid ${pid:-?} on ${host:-?}, age ${age:-?}s — ${why})." >&2
      rm -rf "$dir" 2>/dev/null || true
      continue   # re-race the mkdir; a concurrent starter may win — that's fine
    fi

    echo "[engine-lock] REFUSED: another $label is already running." >&2
    echo "[engine-lock]   lock : $dir" >&2
    echo "[engine-lock]   held : pid ${pid:-?} on ${host:-?} (age ${age:-?}s) — ${why}" >&2
    echo "[engine-lock]   If that engine is truly gone, see docs/TROUBLESHOOTING.md" >&2
    echo "[engine-lock]   (\"Engine refuses to start — lock held\") before touching the lock by hand." >&2
    return "$ENGINE_LOCK_REFUSED_EXIT"
  done

  echo "[engine-lock] REFUSED: could not acquire $dir after 3 attempts (racing starters?)." >&2
  echo "[engine-lock]   See docs/TROUBLESHOOTING.md (\"Engine refuses to start — lock held\")." >&2
  return "$ENGINE_LOCK_REFUSED_EXIT"
}

# release_engine_lock [lockdir] — remove the lock IF this process owns it.
# No arg → whatever acquire_engine_lock recorded. Owner check is by recorded
# pid (and host), so a refused second engine's EXIT trap is a harmless no-op
# and a cross-host takeover can't be deleted from the losing side. Always
# returns 0: release runs inside EXIT traps and must never mask an exit code.
release_engine_lock() {
  local dir="${1:-$_ENGINE_LOCK_HELD}" pid host
  [[ -n "$dir" && -e "$dir" ]] || { _ENGINE_LOCK_HELD=""; return 0; }
  pid="$(_engine_lock_meta "$dir" pid | tr -dc 0-9)"
  host="$(_engine_lock_meta "$dir" host)"
  if [[ "$pid" == "$$" && ( -z "$host" || "$host" == "$(_engine_lock_host)" ) ]]; then
    rm -rf "$dir" 2>/dev/null || true
    [[ "$dir" == "$_ENGINE_LOCK_HELD" ]] && _ENGINE_LOCK_HELD=""
  fi
  return 0
}
