#!/usr/bin/env bash
# lib/host-guard-registry.sh — machine-global aggregate bound for host-guard.
#
# WHY: host-guard's per-session caps (CPU affinity mask, MemoryHigh) are each
# verified IN ISOLATION. Two projects can therefore both pass while the MACHINE
# is over budget — the 2026-07-29 14:02:45 hard reset happened with two goal
# modes holding COMPLEMENTARY masks ("0-3,8-11" + "4-7,12-15"): every per-session
# check green, union = all 16 CPUs = every physical core lit by one burst. Memory
# had the same shape (14G + 14G against 27.3G of RAM). A per-scope ceiling on
# shared hardware is not evidence the hardware is safe.
#
# This library adds the missing machine view:
#   - a HOST budget file (one per machine, outside every repo) declaring the
#     aggregate CPU list and memory budget every guarded session must fit inside;
#   - a REGISTRY of live guarded contexts (engines, adopted pumps, wrapped
#     pumps) so any session can see what else is running right now;
#   - a BOOST check, because a guard that silently loses its own hardware
#     assumption (the Jul-28 boost-off mitigation did not survive a reboot —
#     the tmpfiles.d rule was never installed) is not a guard.
#
# NEUTRALITY: no host budget file ⇒ enforcement off. The registry is still
# maintained (it is cheap and makes `doctor.sh` honest), and the aggregate
# verdict degrades to a loud WARN when 2+ projects are live without a budget.
#
# CONCURRENCY: no locks. Every writer owns a unique filename
# (<kind>-<pid>-<starttime>.rec) and writes it with tmp+rename, so readers can
# never see a torn record. The classic two-racers TOCTOU is solved by ORDERING —
# register FIRST, verify SECOND: both racers see each other, and both compute the
# same loser from a total order (epoch, starttime, pid). Exactly one pauses.
#
# STALENESS: pid-based, never time-based. Iteration gaps here are legitimately
# unbounded (thermal cooldowns up to 30 min, interactive dispatches up to 2 h),
# so any mtime TTL would evict live sessions. A record is stale iff the boot_id
# differs (the machine rebooted), the pid is gone, or the pid is alive with a
# different start time (recycled). Heartbeat mtime is advisory reporting only.
#
# ASSUMPTION: the registry lives on a local filesystem (rename atomicity and
# `kill -0` validity are both meaningless over NFS).

# Re-source guard: run-goal.sh sources this once, but host-guard-adopt.sh and
# host-guard-exec.sh may source it inside an already-sourced shell.
if [[ -n "${_HOST_GUARD_REGISTRY_LOADED:-}" ]]; then return 0 2>/dev/null || true; fi
_HOST_GUARD_REGISTRY_LOADED=1

# ── Mask set math ─────────────────────────────────────────────────────────────
# _host_guard_mask_width (run-goal.sh) counts CPUs; that is not enough here.
# "0-7" and "0-3,8-11" both have width 8 but are DISJOINT sets — the exact
# distinction a machine-global bound turns on. These work on sets.

_hg_mask_expand() { # "0-3,8-11" → one CPU id per line, sorted, deduped
  local list="${1:-}" part a b i
  [[ -n "$list" ]] || return 0
  local -a parts=()
  IFS=',' read -ra parts <<< "$list"
  {
    for part in "${parts[@]}"; do
      if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
        a="${part%-*}"; b="${part#*-}"
        if (( b >= a )); then for (( i=a; i<=b; i++ )); do echo "$i"; done; fi
      elif [[ "$part" =~ ^[0-9]+$ ]]; then
        echo "$part"
      fi
    done
  } | sort -n -u
}

_hg_mask_is_subset() { # $1 ⊆ $2 ? (empty subset is trivially true)
  local c
  local -A super=()
  while read -r c; do [[ -n "$c" ]] && super["$c"]=1; done < <(_hg_mask_expand "${2:-}")
  while read -r c; do
    [[ -n "$c" ]] || continue
    [[ -n "${super[$c]:-}" ]] || return 1
  done < <(_hg_mask_expand "${1:-}")
  return 0
}

_hg_mask_union() { # any number of mask strings → "0,1,2,8,9" (canonical, sorted)
  local l
  { for l in "$@"; do _hg_mask_expand "$l"; done; } | sort -n -u | paste -sd, -
}

_hg_mem_to_bytes() { # "14G" | "512M" | "2048K" | "123" → bytes; rc 1 on junk
  local v="${1:-}" n u
  [[ "$v" =~ ^([0-9]+)([KMGTkmgt]?)$ ]] || { echo ""; return 1; }
  n="${BASH_REMATCH[1]}"; u="${BASH_REMATCH[2]}"
  case "$u" in
    K|k) echo $(( n * 1024 )) ;;
    M|m) echo $(( n * 1024 * 1024 )) ;;
    G|g) echo $(( n * 1024 * 1024 * 1024 )) ;;
    T|t) echo $(( n * 1024 * 1024 * 1024 * 1024 )) ;;
    *)   echo "$n" ;;
  esac
  return 0
}

_hg_bytes_to_h() { # bytes → "13.7G" for human-readable messages
  local b="${1:-0}"
  awk -v b="$b" 'BEGIN{ if (b >= 1073741824) printf "%.1fG", b/1073741824;
                        else if (b >= 1048576) printf "%.1fM", b/1048576;
                        else printf "%dB", b }'
}

# ── Process identity ──────────────────────────────────────────────────────────

_hg_boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown"; }

# /proc/<pid>/stat field 22 (starttime). The comm field can contain spaces and
# parentheses, so strip through the LAST ')' before counting — same idiom the
# dispatch waiter and test-pump-liveness.sh use for pid-recycling defense.
_hg_proc_starttime() {
  local pid="${1:-}"
  [[ -n "$pid" ]] || return 0
  sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}'
}

# hg_pid_matches <pid> <starttime> — rc 0 iff that pid is alive AND is still the
# SAME process. After a machine reset the box comes back with the same pid space,
# so a pidfile left by the dead boot can point at an innocent live process.
# `kill -0` alone cannot tell them apart; the start time can.
hg_pid_matches() {
  local pid="${1:-}" stt="${2:-}"
  [[ "$pid" =~ ^[0-9]+$ && -n "$stt" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [[ "$(_hg_proc_starttime "$pid")" == "$stt" ]]
}

# hg_boot_epoch — unix time this boot started (/proc/stat btime).
# HOST_GUARD_BTIME_OVERRIDE is the test seam: no test can reboot a machine.
hg_boot_epoch() {
  if [[ -n "${HOST_GUARD_BTIME_OVERRIDE:-}" ]]; then
    echo "$HOST_GUARD_BTIME_OVERRIDE"; return 0
  fi
  awk '/^btime /{print $2; exit}' /proc/stat 2>/dev/null || echo 0
}

# hg_file_predates_boot <path> — rc 0 iff the file was last written BEFORE this
# boot began, i.e. it is a leftover from a machine that went down without
# cleaning up. rc 1 when the file is missing, unreadable, or current.
hg_file_predates_boot() {
  local f="${1:-}" mt bt
  [[ -f "$f" ]] || return 1
  mt="$(stat -c %Y "$f" 2>/dev/null)" || return 1
  bt="$(hg_boot_epoch)"
  [[ "$mt" =~ ^[0-9]+$ && "$bt" =~ ^[0-9]+$ ]] || return 1
  (( mt < bt ))
}

# ── Registry ──────────────────────────────────────────────────────────────────

hg_registry_dir() {
  echo "${HOST_GUARD_REGISTRY_DIR:-${CHAIN_TMP_ROOT:-$HOME/.cache/iad}/host-guard/registry}"
}

hg_host_env_file() {
  echo "${HOST_GUARD_HOST_ENV_FILE:-$HOME/.config/iad/host-guard-host.env}"
}

# hg_load_host_env — source the machine budget if present. Deliberately unscoped
# (matches how run-goal.sh sources the project host-guard.env), so the
# HOST_GUARD_GLOBAL_* values stay visible to the caller.
hg_load_host_env() {
  local f; f="$(hg_host_env_file)"
  [[ -f "$f" ]] || return 0
  # shellcheck disable=SC1090
  source "$f"
  return 0
}

_hg_rec_field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }

# hg_register <kind> <pid> <project_root> <session_id> <cpu_list> <memory_high>
# Echoes the record path (empty on failure). ALWAYS returns 0 — a registry
# problem must never take down an engine that is otherwise correctly confined.
# Idempotent: re-registering the same (kind,pid,starttime) is the heartbeat.
hg_register() {
  local kind="${1:-}" pid="${2:-}" root="${3:-}" sid="${4:-}" cpus="${5:-}" mem="${6:-}"
  local dir stt rec tmp
  dir="$(hg_registry_dir)"
  mkdir -p "$dir" 2>/dev/null || { echo ""; return 0; }
  stt="$(_hg_proc_starttime "$pid")"
  [[ -n "$stt" ]] || { echo ""; return 0; }
  rec="$dir/$kind-$pid-$stt.rec"
  if [[ -f "$rec" ]]; then
    touch "$rec" 2>/dev/null || true
    echo "$rec"; return 0
  fi
  tmp="$rec.tmp.$$"
  if printf 'kind=%s\npid=%s\nstarttime=%s\nboot_id=%s\nhost=%s\nepoch=%s\nproject_root=%s\nsession_id=%s\ncpu_list=%s\nmemory_high=%s\n' \
       "$kind" "$pid" "$stt" "$(_hg_boot_id)" "$(hostname 2>/dev/null || echo unknown)" \
       "$(date +%s)" "$root" "$sid" "$cpus" "$mem" > "$tmp" 2>/dev/null \
     && mv -f "$tmp" "$rec" 2>/dev/null; then
    echo "$rec"; return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  echo ""; return 0
}

hg_record_is_live() { # $1 record path → rc 0 live, rc 1 stale
  local rec="${1:-}" pid stt bid
  [[ -f "$rec" ]] || return 1
  bid="$(_hg_rec_field "$rec" boot_id)"
  [[ "$bid" == "$(_hg_boot_id)" ]] || return 1          # machine rebooted
  pid="$(_hg_rec_field "$rec" pid)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1                # holder gone
  stt="$(_hg_rec_field "$rec" starttime)"
  [[ "$(_hg_proc_starttime "$pid")" == "$stt" ]] || return 1   # pid recycled
  return 0
}

hg_sweep() { # drop stale records; racing sweepers are harmless (rm -f)
  local r
  for r in "$(hg_registry_dir)"/*.rec; do
    [[ -e "$r" ]] || continue
    hg_record_is_live "$r" || rm -f "$r" 2>/dev/null || true
  done
  return 0
}

hg_live_records() { # print paths of live records, one per line
  local r
  for r in "$(hg_registry_dir)"/*.rec; do
    [[ -e "$r" ]] || continue
    hg_record_is_live "$r" && echo "$r"
  done
  return 0
}

hg_release() { # drop THIS process's engine record (best effort)
  local stt; stt="$(_hg_proc_starttime "$$")"
  [[ -n "$stt" ]] || return 0
  rm -f "$(hg_registry_dir)/engine-$$-$stt.rec" 2>/dev/null || true
  return 0
}

# ── Durable machine-wide event ledger ─────────────────────────────────────────
# WHY: after the 2026-07-30 hardware reset nothing on disk could answer the one
# question forensics needs — "what was the machine doing, across BOTH repos, in
# the final seconds?". The aggregate verdict is silent when it passes,
# telemetry.jsonl is per-session and never fsync'd, and engine.log only exists in
# interactive mode. This ledger is one fsync'd line per chain event for the whole
# machine, so the postmortem can reconstruct a cross-repo timeline.
#
# DURABILITY: `sync <file>` after each append — the same idiom that made the
# hwmon sampler the only artifact to survive the power-cut with its last second
# intact. Event rate is a few per minute, so the cost is irrelevant.
#
# CONCURRENCY: single-line O_APPEND writes from concurrent engines do not
# interleave on a local filesystem (lines stay far below the atomic-write bound;
# oversized payloads are dropped rather than truncated, so a reader never meets
# half a JSON object). Same local-fs assumption the registry already makes.

hg_events_file() {
  echo "${HOST_GUARD_EVENTS_FILE:-${CHAIN_TMP_ROOT:-$HOME/.cache/iad}/host-guard/events.jsonl}"
}

_hg_json_esc() { # minimal JSON string escaping for the fields we control
  local s="${1:-}"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"
  printf '%s' "$s"
}

# hg_event <type> [json-object] — best effort, ALWAYS returns 0.
# The optional second argument is a JSON OBJECT whose body is spliced into the
# event (e.g. '{"iter":3}'). Never let a ledger problem touch the engine.
hg_event() {
  local type="${1:-}" payload="${2:-}"
  [[ -n "$type" ]] || return 0
  # NO-OP RULE (roadmap §20): no machine budget file and no project host-guard
  # ⇒ this function writes nothing at all, on any host.
  [[ -f "$(hg_host_env_file)" || "${HOST_GUARD_ENABLED:-0}" == "1" ]] || return 0

  local f dir extra="" iso size max
  f="$(hg_events_file)"; dir="$(dirname "$f")"
  mkdir -p "$dir" 2>/dev/null || return 0

  if [[ "$payload" == \{*\} ]]; then
    extra="${payload#\{}"; extra="${extra%\}}"
    extra="${extra//$'\n'/ }"
    if (( ${#extra} > 900 )); then
      extra=',"payload_dropped":true'      # never emit half an object
    elif [[ -n "$extra" ]]; then
      extra=",$extra"
    fi
  fi

  printf -v iso '%(%Y-%m-%dT%H:%M:%S)T' -1
  printf '{"ts":%s,"iso":"%s","boot":"%s","host":"%s","pid":%s,"event":"%s","project":"%s","sid":"%s","agent":"%s"%s}\n' \
    "$EPOCHSECONDS" "$iso" "$(_hg_boot_id)" \
    "$(_hg_json_esc "${HOSTNAME:-unknown}")" "$$" "$(_hg_json_esc "$type")" \
    "$(_hg_json_esc "${REPO_ROOT:-$PWD}")" "$(_hg_json_esc "${GOAL_SESSION_ID:-${SESSION_ID:-}}")" \
    "$(_hg_json_esc "${CHAIN_CURRENT_AGENT:-}")" "$extra" >> "$f" 2>/dev/null || return 0
  # fsync so the final pre-reset lines survive an instant power-cut reset
  sync "$f" 2>/dev/null || sync 2>/dev/null || true

  max="${HOST_GUARD_EVENTS_MAX_BYTES:-5242880}"
  size="$(stat -c %s "$f" 2>/dev/null || echo 0)"
  if [[ "$size" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]] && (( size > max )); then
    if command -v flock >/dev/null 2>&1; then
      # A racing rotator doing the same mv is harmless; skip rather than wait.
      ( flock -n 9 && mv -f "$f" "$f.1" ) 9>"$dir/.events.lock" 2>/dev/null || true
    else
      mv -f "$f" "$f.1" 2>/dev/null || true
    fi
  fi
  return 0
}

# hg_self_is_junior_to <own_rec> <other_rec> — rc 0 when SELF loses.
# Total order over (epoch, starttime, pid): both sides compute the same answer
# from the same files, so a conflict never ends in both-pause or neither-pause.
hg_self_is_junior_to() {
  local a b
  a="$(_hg_rec_field "$1" epoch)"; b="$(_hg_rec_field "$2" epoch)"
  [[ "$a" =~ ^[0-9]+$ ]] || a=0; [[ "$b" =~ ^[0-9]+$ ]] || b=0
  (( a > b )) && return 0
  (( a < b )) && return 1
  a="$(_hg_rec_field "$1" starttime)"; b="$(_hg_rec_field "$2" starttime)"
  [[ "$a" =~ ^[0-9]+$ ]] || a=0; [[ "$b" =~ ^[0-9]+$ ]] || b=0
  (( a > b )) && return 0
  (( a < b )) && return 1
  a="$(_hg_rec_field "$1" pid)"; b="$(_hg_rec_field "$2" pid)"
  [[ "$a" =~ ^[0-9]+$ ]] || a=0; [[ "$b" =~ ^[0-9]+$ ]] || b=0
  (( a > b ))
}

# ── Host-level assumption checks ──────────────────────────────────────────────

# hg_boost_ok — CPU boost must be OFF when the host budget says so. Read-only:
# the engine never sudo's. Prints the failure reason on stdout.
hg_boost_ok() {
  [[ "${HOST_GUARD_REQUIRE_BOOST_OFF:-0}" == "1" ]] || return 0
  local p v
  p="${HOST_GUARD_SYS_BOOST_PATH:-/sys/devices/system/cpu/cpufreq/boost}"
  if [[ ! -r "$p" ]]; then
    echo "CPU boost knob $p is missing or unreadable — the boost-off assumption cannot be verified (kernel or cpufreq driver changed?). Set HOST_GUARD_REQUIRE_BOOST_OFF=0 in $(hg_host_env_file) if this host has no boost control."
    return 1
  fi
  v="$(tr -dc '0-9' < "$p" 2>/dev/null)"
  if [[ "$v" != "0" ]]; then
    echo "CPU boost is ON ($p reads '${v:-?}', expected 0) — the hardware mitigation is inactive. Re-apply and persist it: echo 0 | sudo tee $p && printf 'w $p - - - - 0\\n' | sudo tee /etc/tmpfiles.d/cpufreq-boost.conf (see docs/host-guard.md § Boost persistence)."
    return 1
  fi
  return 0
}

# ── Arbitration ───────────────────────────────────────────────────────────────
# _hg_arbitrate <own_rec> <detail> <live_rec>... → "PAUSE|<msg>" | "WARN|<msg>"
# Someone has to yield. Compare against every OTHER live engine record: if we are
# junior to all of them we pause; otherwise we warn and keep running while the
# junior session pauses itself on its own next check. Extracted so every breach
# class (mask, memory, engine count) yields by the same deterministic rule.
_hg_arbitrate() {
  local own_rec="${1:-}" detail="${2:-}"; shift 2 2>/dev/null || true
  local other kind junior=0 senior_desc=""
  for other in "$@"; do
    [[ "$other" == "$own_rec" ]] && continue
    kind="$(_hg_rec_field "$other" kind)"
    [[ "$kind" == "engine" ]] || continue
    if hg_self_is_junior_to "$own_rec" "$other"; then
      junior=1
      senior_desc="session '$(_hg_rec_field "$other" session_id)' in $(_hg_rec_field "$other" project_root) (pid $(_hg_rec_field "$other" pid))"
      break
    fi
  done
  if (( junior )); then
    echo "PAUSE|$detail. The older session holds the budget: $senior_desc. Stop or narrow that session, or widen the budget in $(hg_host_env_file), then resume."
  else
    echo "WARN|$detail. This session started first, so it keeps running; the newer session is expected to pause itself."
  fi
  return 0
}

# ── Aggregate verdict ─────────────────────────────────────────────────────────
# hg_aggregate_verdict <own_rec> → "OK" | "WARN|<msg>" | "PAUSE|<msg>"
#
# Memory is summed as per-project MAX, not a plain total: a project's engine
# scope and its adopted-pump scope are separate cgroups that each carry the same
# MemoryHigh, so a naive sum double-counts every project and no sane budget
# would ever pass. MemoryHigh is a reclaim/throttle high-water anyway, not a
# reservation — max-per-project is the figure that matches the incident math.
hg_aggregate_verdict() {
  local own_rec="${1:-}"
  local global_cpus="${HOST_GUARD_GLOBAL_CPU_LIST:-}"
  local global_mem="${HOST_GUARD_GLOBAL_MEMORY_BUDGET:-}"
  local -a live=()
  local r
  while read -r r; do [[ -n "$r" ]] && live+=("$r"); done < <(hg_live_records)

  # Distinct project roots among live registrants (for the no-budget warning).
  local -A roots=() proj_mem=()
  local -a masks=()
  local root mem bytes
  for r in "${live[@]}"; do
    root="$(_hg_rec_field "$r" project_root)"
    [[ -n "$root" ]] && roots["$root"]=1
    masks+=("$(_hg_rec_field "$r" cpu_list)")
    mem="$(_hg_rec_field "$r" memory_high)"
    bytes="$(_hg_mem_to_bytes "$mem" 2>/dev/null)" || bytes=""
    if [[ -n "$root" && -n "$bytes" ]]; then
      if [[ -z "${proj_mem[$root]:-}" ]] || (( bytes > proj_mem[$root] )); then
        proj_mem["$root"]="$bytes"
      fi
    fi
  done

  # (0) Concurrent-engine cap, checked BEFORE the budget early-return so it works
  # on a machine that configures only the cap. This is the honest mitigation for
  # a host whose resets are HARDWARE (2026-07-30: an uncorrected data fabric sync
  # flood with every mask/memory check green — see docs/host-guard.md § After a
  # hardware reset): fewer simultaneous engines shrinks the exposure window, a
  # narrower mask does not. Absent or invalid ⇒ unlimited ⇒ today's behaviour.
  local cap="${HOST_GUARD_MAX_ENGINES:-}"
  if [[ "$cap" =~ ^[0-9]+$ ]] && (( cap >= 1 )); then
    local n_eng=0 er
    for er in "${live[@]}"; do
      [[ "$(_hg_rec_field "$er" kind)" == "engine" ]] && n_eng=$(( n_eng + 1 ))
    done
    if (( n_eng > cap )); then
      _hg_arbitrate "$own_rec" \
        "$n_eng goal-mode engines are live but this machine allows HOST_GUARD_MAX_ENGINES=$cap ($(hg_host_env_file)) — it is recovering from hardware-asserted resets, so concurrent engines are capped until the hardware soaks clean" \
        "${live[@]}"
      return 0
    fi
  fi

  # No machine budget configured: enforcement is off, but say so loudly once
  # two different projects are guarded at the same time — that is exactly the
  # configuration that reset this host.
  if [[ -z "$global_cpus" ]]; then
    if (( ${#roots[@]} >= 2 )); then
      echo "WARN|no machine-global budget is configured ($(hg_host_env_file) is absent or sets no HOST_GUARD_GLOBAL_CPU_LIST) while ${#roots[@]} guarded sessions are live — their CPU masks union to $(_hg_mask_union "${masks[@]}"), which nothing is checking. See docs/host-guard.md § Machine-global aggregate budget."
      return 0
    fi
    echo "OK"; return 0
  fi

  local detail=""

  # (a) own mask ⊆ global. This one is NOT arbitrated by seniority: a session
  # whose own declared mask exceeds the machine budget is misconfigured, and
  # being the oldest session on the box does not make it safe. Pause always.
  local own_cpus; own_cpus="$(_hg_rec_field "$own_rec" cpu_list)"
  if [[ -n "$own_cpus" ]] && ! _hg_mask_is_subset "$own_cpus" "$global_cpus"; then
    echo "PAUSE|this session's CPU mask ($own_cpus) is not inside the machine budget HOST_GUARD_GLOBAL_CPU_LIST=$global_cpus ($(hg_host_env_file)). Narrow HOST_GUARD_CPU_LIST in this project's project-extensions/host-guard/host-guard.env, or widen the machine budget."
    return 0
  fi

  # (b) union of every live mask ⊆ global. Pairwise-subset implies this, but
  # check it explicitly: it is what catches a hand-edited record, a session
  # that started before this upgrade, or a registry that lost a write.
  if [[ -z "$detail" && ${#masks[@]} -gt 0 ]]; then
    local union; union="$(_hg_mask_union "${masks[@]}")"
    if ! _hg_mask_is_subset "$union" "$global_cpus"; then
      detail="the CPU masks of the ${#live[@]} live guarded session(s) union to $union, which exceeds the machine budget HOST_GUARD_GLOBAL_CPU_LIST=$global_cpus"
    fi
  fi

  # (c) per-project memory ceilings must fit the machine budget.
  if [[ -z "$detail" && -n "$global_mem" ]]; then
    local budget total=0 k
    if budget="$(_hg_mem_to_bytes "$global_mem")"; then
      for k in "${!proj_mem[@]}"; do total=$(( total + proj_mem[$k] )); done
      if (( total > budget )); then
        detail="the memory ceilings of the ${#roots[@]} live project(s) sum to $(_hg_bytes_to_h "$total"), over the machine budget HOST_GUARD_GLOBAL_MEMORY_BUDGET=$global_mem"
      fi
    fi
  fi

  [[ -n "$detail" ]] || { echo "OK"; return 0; }

  _hg_arbitrate "$own_rec" "$detail" "${live[@]}"
  return 0
}
