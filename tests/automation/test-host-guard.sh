#!/usr/bin/env bash
# test-host-guard.sh — machine-global host-guard aggregate bound:
#   A. lib/host-guard-registry.sh unit semantics (mask SET math — not just
#      widths, memory parsing, atomic+idempotent registration, pid/starttime/
#      boot_id staleness, seniority total order, per-project memory grouping,
#      the boost assumption check, and the aggregate verdict's PAUSE/WARN/OK
#      classification)
#   B. run-goal.sh wiring: the REAL engine in a sandbox with a stub `claude` —
#      a junior session pauses AWAITING_HOST_GUARD against a live senior
#      registrant, a senior warns and proceeds, and a re-enabled CPU boost
#      pauses at preflight and clears on --resume once boost is back off.
#   C. interactive pump headless preflight (HOST_GUARD_PUMP_HEADLESS_QA=1):
#      the pump's launch environment decides whether its Chrome MCP runs
#      headed, so the iteration gate reads /proc/<pump>/environ BEFORE the
#      iteration's first model dispatch — hg_pid_display_env /
#      hg_pump_display_verdict unit semantics (fake procfs root + real
#      processes: DISPLAY, WAYLAND_DISPLAY, neither, empty value, gone pid,
#      unreadable), then the REAL engine with --interactive: a display-bound
#      pump pauses AWAITING_HOST_GUARD with nothing dispatched (no req.* file,
#      no Step 1), a display-less pump proceeds to Step 1, policy off and the
#      CHAIN_BQA_HEADED=1 escape are no-ops, an unidentifiable live pump
#      pauses (never a silent bypass).
#
# Offline, no model calls. Every victim process is spawned by this test into a
# throwaway sandbox; signals only ever target those.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$ENGINE_ROOT/scripts/automation/lib/host-guard-registry.sh"

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}
assert_eq() { # name expected actual
  if [[ "$2" == "$3" ]]; then assert "$1" pass; else echo "  FAIL  $1 (expected '$2', got '$3')"; FAIL=$((FAIL + 1)); fi
}

WORK="$(mktemp -d)"
_SPAWNED_PGIDS=()
cleanup() {
  local pg
  for pg in "${_SPAWNED_PGIDS[@]:-}"; do
    [[ -n "$pg" ]] && kill -KILL -- "-$pg" 2>/dev/null
  done
  pkill -KILL -f "$WORK/" 2>/dev/null
  if [[ -n "${KEEP_WORK:-}" ]]; then echo "KEEP_WORK set — sandbox kept at $WORK"; return 0; fi
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

wait_for() {
  local deadline=$(( $(date +%s) + $1 )); shift
  while ! "$@" 2>/dev/null; do
    [[ $(date +%s) -ge $deadline ]] && return 1
    sleep 0.2
  done
  return 0
}

export HOST_GUARD_REGISTRY_DIR="$WORK/registry"
export HOST_GUARD_HOST_ENV_FILE="$WORK/host-guard-host.env"
export HOST_GUARD_SYS_BOOST_PATH="$WORK/boost"
mkdir -p "$HOST_GUARD_REGISTRY_DIR"

# shellcheck disable=SC1090
source "$LIB"

echo "── A. registry library units ──────────────────────────────────────────"

# 1. Mask expansion.
assert_eq "expand 0-3,8-11 → 8 ids"        "0 1 2 3 8 9 10 11" "$(_hg_mask_expand '0-3,8-11' | tr '\n' ' ' | sed 's/ $//')"
assert_eq "expand single value"            "5"                 "$(_hg_mask_expand '5' | tr '\n' ' ' | sed 's/ $//')"
assert_eq "expand mixed 0,2-3"             "0 2 3"             "$(_hg_mask_expand '0,2-3' | tr '\n' ' ' | sed 's/ $//')"
assert_eq "expand reversed range ignored"  ""                  "$(_hg_mask_expand '3-1' | tr '\n' ' ' | sed 's/ $//')"
assert_eq "expand junk ignored"            ""                  "$(_hg_mask_expand 'a-b' | tr '\n' ' ' | sed 's/ $//')"
assert_eq "expand empty"                   ""                  "$(_hg_mask_expand '' | tr '\n' ' ' | sed 's/ $//')"

# 2. Subset — the SET test the old width-only helper could not make. "0-7" and
# "0-3,8-11" have identical widths but are disjoint; treating width as the
# criterion is what let two complementary masks both pass.
_hg_mask_is_subset "0-3,8-11" "0-5,8-13" && assert "subset: 0-3,8-11 ⊆ 0-5,8-13" pass || assert "subset: 0-3,8-11 ⊆ 0-5,8-13" fail
_hg_mask_is_subset "4-7,12-15" "0-3,8-11" && assert "subset: complementary mask rejected" fail || assert "subset: complementary mask rejected" pass
_hg_mask_is_subset "0-7" "0-3,8-11" && assert "subset: same width, different set rejected" fail || assert "subset: same width, different set rejected" pass
_hg_mask_is_subset "0-3,8-11" "0-3,8-11" && assert "subset: identical lists" pass || assert "subset: identical lists" fail
_hg_mask_is_subset "" "0-3" && assert "subset: empty is a subset" pass || assert "subset: empty is a subset" fail

# 3. Union.
assert_eq "union of complementary masks = 16 CPUs" "16" "$(_hg_mask_union '0-3,8-11' '4-7,12-15' | tr ',' '\n' | wc -l | tr -dc 0-9)"
_hg_mask_is_subset "$(_hg_mask_union '0-3,8-11' '4-7,12-15')" "0-3,8-11" \
  && assert "union of complementary masks exceeds either" fail || assert "union of complementary masks exceeds either" pass

# 4. Memory parsing.
assert_eq "mem 14G"    "15032385536" "$(_hg_mem_to_bytes 14G)"
assert_eq "mem 512M"   "536870912"   "$(_hg_mem_to_bytes 512M)"
assert_eq "mem 2048K"  "2097152"     "$(_hg_mem_to_bytes 2048K)"
assert_eq "mem bare"   "123"         "$(_hg_mem_to_bytes 123)"
_hg_mem_to_bytes "14GB"     >/dev/null 2>&1 && assert "mem rejects 14GB"     fail || assert "mem rejects 14GB"     pass
_hg_mem_to_bytes "infinity" >/dev/null 2>&1 && assert "mem rejects infinity" fail || assert "mem rejects infinity" pass
_hg_mem_to_bytes "-1"       >/dev/null 2>&1 && assert "mem rejects -1"       fail || assert "mem rejects -1"       pass

# 5. Registration: atomic, complete, idempotent.
setsid sleep 300 & V1=$!; _SPAWNED_PGIDS+=("$V1")
setsid sleep 300 & V2=$!; _SPAWNED_PGIDS+=("$V2")
wait_for 5 test -d "/proc/$V1"; wait_for 5 test -d "/proc/$V2"

REC1="$(hg_register engine "$V1" /fake/projA sessA "0-3,8-11" 10G)"
[[ -f "$REC1" ]] && assert "register: record written" pass || assert "register: record written" fail
assert_eq "register: field count" "10" "$(wc -l < "$REC1" | tr -dc 0-9)"
assert_eq "register: cpu_list"    "0-3,8-11" "$(_hg_rec_field "$REC1" cpu_list)"
assert_eq "register: project"     "/fake/projA" "$(_hg_rec_field "$REC1" project_root)"
_EPOCH1="$(_hg_rec_field "$REC1" epoch)"
sleep 1
REC1B="$(hg_register engine "$V1" /fake/projA sessA "0-3,8-11" 10G)"
assert_eq "register: idempotent path"   "$REC1" "$REC1B"
assert_eq "register: epoch not rewritten" "$_EPOCH1" "$(_hg_rec_field "$REC1" epoch)"

# 6. Staleness is pid-based, never time-based.
hg_record_is_live "$REC1" && assert "live: running pid" pass || assert "live: running pid" fail
cp "$REC1" "$WORK/recycled.rec"; sed -i 's/^starttime=.*/starttime=1/' "$WORK/recycled.rec"
hg_record_is_live "$WORK/recycled.rec" && assert "stale: recycled pid detected" fail || assert "stale: recycled pid detected" pass
cp "$REC1" "$WORK/rebooted.rec"; sed -i 's/^boot_id=.*/boot_id=dead-beef/' "$WORK/rebooted.rec"
hg_record_is_live "$WORK/rebooted.rec" && assert "stale: boot_id mismatch detected" fail || assert "stale: boot_id mismatch detected" pass
REC2="$(hg_register engine "$V2" /fake/projB sessB "4-7,12-15" 10G)"
kill -KILL "$V2" 2>/dev/null; wait "$V2" 2>/dev/null
wait_for 5 bash -c "! kill -0 $V2 2>/dev/null"
hg_record_is_live "$REC2" && assert "stale: dead pid detected" fail || assert "stale: dead pid detected" pass
hg_sweep
[[ -f "$REC2" ]] && assert "sweep: dead record removed" fail || assert "sweep: dead record removed" pass
[[ -f "$REC1" ]] && assert "sweep: live record kept" pass || assert "sweep: live record kept" fail

# 7. Seniority is a total order, so two racers never both pause / both proceed.
mk_rec() { # path epoch starttime pid
  printf 'kind=engine\npid=%s\nstarttime=%s\nboot_id=x\nhost=h\nepoch=%s\nproject_root=/p\nsession_id=s\ncpu_list=0\nmemory_high=1G\n' \
    "$4" "$3" "$2" > "$1"
}
mk_rec "$WORK/old.rec" 1000 500 100
mk_rec "$WORK/new.rec" 2000 400  90
hg_self_is_junior_to "$WORK/new.rec" "$WORK/old.rec" && assert "seniority: newer epoch loses" pass || assert "seniority: newer epoch loses" fail
hg_self_is_junior_to "$WORK/old.rec" "$WORK/new.rec" && assert "seniority: older epoch wins" fail || assert "seniority: older epoch wins" pass
mk_rec "$WORK/tie_a.rec" 1000 500 100
mk_rec "$WORK/tie_b.rec" 1000 400 100
hg_self_is_junior_to "$WORK/tie_a.rec" "$WORK/tie_b.rec" && assert "seniority: epoch tie → starttime" pass || assert "seniority: epoch tie → starttime" fail
mk_rec "$WORK/pid_a.rec" 1000 500 101
mk_rec "$WORK/pid_b.rec" 1000 500 100
hg_self_is_junior_to "$WORK/pid_a.rec" "$WORK/pid_b.rec" && assert "seniority: full tie → pid" pass || assert "seniority: full tie → pid" fail

# 8. Boost assumption.
export HOST_GUARD_REQUIRE_BOOST_OFF=1
echo 0 > "$WORK/boost"; hg_boost_ok >/dev/null && assert "boost: 0 passes" pass || assert "boost: 0 passes" fail
echo 1 > "$WORK/boost"; hg_boost_ok >/dev/null && assert "boost: 1 fails" fail || assert "boost: 1 fails" pass
[[ "$(hg_boost_ok)" == *"boost is ON"* ]] && assert "boost: message names the problem" pass || assert "boost: message names the problem" fail
mv "$WORK/boost" "$WORK/boost.hidden"
hg_boost_ok >/dev/null && assert "boost: missing knob fails" fail || assert "boost: missing knob fails" pass
HOST_GUARD_REQUIRE_BOOST_OFF=0 hg_boost_ok >/dev/null && assert "boost: not required → passes" pass || assert "boost: not required → passes" fail
mv "$WORK/boost.hidden" "$WORK/boost"; echo 0 > "$WORK/boost"

# 9. Aggregate verdict.
rm -f "$HOST_GUARD_REGISTRY_DIR"/*.rec
setsid sleep 300 & S1=$!; _SPAWNED_PGIDS+=("$S1")   # senior, project A
setsid sleep 300 & S2=$!; _SPAWNED_PGIDS+=("$S2")   # junior, project B
wait_for 5 test -d "/proc/$S1"; wait_for 5 test -d "/proc/$S2"
seed() { # kind pid root sid cpus mem epoch → path
  local stt; stt="$(_hg_proc_starttime "$2")"
  local p="$HOST_GUARD_REGISTRY_DIR/$1-$2-$stt.rec"
  printf 'kind=%s\npid=%s\nstarttime=%s\nboot_id=%s\nhost=h\nepoch=%s\nproject_root=%s\nsession_id=%s\ncpu_list=%s\nmemory_high=%s\n' \
    "$1" "$2" "$stt" "$(_hg_boot_id)" "$7" "$3" "$4" "$5" "$6" > "$p"
  echo "$p"
}
A_REC="$(seed engine "$S1" /fake/projA sessA "0-3,8-11" 10G 1000)"
B_REC="$(seed engine "$S2" /fake/projB sessB "4-7,12-15" 10G 2000)"

unset HOST_GUARD_GLOBAL_CPU_LIST HOST_GUARD_GLOBAL_MEMORY_BUDGET
V="$(hg_aggregate_verdict "$B_REC")"
[[ "$V" == WARN\|*"no machine-global budget"* ]] && assert "verdict: 2 projects, no budget → WARN" pass || assert "verdict: 2 projects, no budget → WARN ($V)" fail

export HOST_GUARD_GLOBAL_CPU_LIST="0-3,8-11" HOST_GUARD_GLOBAL_MEMORY_BUDGET="22G"
V="$(hg_aggregate_verdict "$B_REC")"
[[ "$V" == PAUSE\|* ]] && assert "verdict: own mask outside budget → PAUSE" pass || assert "verdict: own mask outside budget → PAUSE ($V)" fail
V="$(hg_aggregate_verdict "$A_REC")"
[[ "$V" == WARN\|*"union"* ]] && assert "verdict: senior sees union violation → WARN" pass || assert "verdict: senior sees union violation → WARN ($V)" fail

# Both masks legal, memory over budget → junior pauses, senior warns.
sed -i 's|^cpu_list=.*|cpu_list=0-3,8-11|' "$B_REC"
sed -i 's/^memory_high=.*/memory_high=14G/' "$A_REC" "$B_REC"
V="$(hg_aggregate_verdict "$B_REC")"
[[ "$V" == PAUSE\|*"memory"* ]] && assert "verdict: memory sum over budget → junior PAUSE" pass || assert "verdict: memory sum over budget → junior PAUSE ($V)" fail
V="$(hg_aggregate_verdict "$A_REC")"
[[ "$V" == WARN\|*"memory"* ]] && assert "verdict: memory sum over budget → senior WARN" pass || assert "verdict: memory sum over budget → senior WARN ($V)" fail

# Memory is grouped per project (engine + pump of ONE project must not double
# count — they are separate cgroups carrying the same ceiling).
sed -i 's/^memory_high=.*/memory_high=10G/' "$A_REC" "$B_REC"
P_REC="$(seed pump "$S1" /fake/projA sessA "0-3,8-11" 10G 1001)"
V="$(hg_aggregate_verdict "$B_REC")"
assert_eq "verdict: per-project max, not naive sum" "OK" "$V"
rm -f "$P_REC"

# A stale conflicting registrant must not hold the budget hostage.
sed -i 's|^cpu_list=.*|cpu_list=4-7,12-15|' "$A_REC"
kill -KILL "$S1" 2>/dev/null; wait "$S1" 2>/dev/null
wait_for 5 bash -c "! kill -0 $S1 2>/dev/null"
V="$(hg_aggregate_verdict "$B_REC")"
assert_eq "verdict: stale registrant ignored" "OK" "$V"

# The explicit union check catches a registrant that never ran preflight
# (hand-edited env, or a session started before this upgrade).
setsid sleep 300 & S3=$!; _SPAWNED_PGIDS+=("$S3")
wait_for 5 test -d "/proc/$S3"
G_REC="$(seed engine "$S3" /fake/projC sessC "4-7,12-15" 1G 3000)"
V="$(hg_aggregate_verdict "$B_REC")"
[[ "$V" == WARN\|*"union"* || "$V" == PAUSE\|*"union"* ]] && assert "verdict: union check catches unpreflighted registrant" pass || assert "verdict: union check catches unpreflighted registrant ($V)" fail
rm -f "$G_REC"

# hg_release drops only our own record.
OWN="$(hg_register engine "$$" /fake/self selfsid "0-3,8-11" 1G)"
hg_release
[[ -f "$OWN" ]] && assert "release: own record removed" fail || assert "release: own record removed" pass
[[ -f "$B_REC" ]] && assert "release: other records kept" pass || assert "release: other records kept" fail

# The registry must survive the chain-tmp janitor (it lives under the same root).
CHAIN_TMP_ROOT="$WORK/tmproot" HOST_GUARD_REGISTRY_DIR="$WORK/tmproot/host-guard/registry" \
  bash -c "
    source '$ENGINE_ROOT/scripts/automation/lib/host-guard-registry.sh'
    mkdir -p \"\$HOST_GUARD_REGISTRY_DIR\"
    hg_register engine $$ /fake/janitor s '0' 1G >/dev/null
    source '$ENGINE_ROOT/scripts/automation/lib/chain-tmp.sh' 2>/dev/null
    declare -F chain_tmp_janitor >/dev/null && chain_tmp_janitor >/dev/null 2>&1
    ls \"\$HOST_GUARD_REGISTRY_DIR\"/*.rec >/dev/null 2>&1
  " && assert "registry survives the chain-tmp janitor" pass || assert "registry survives the chain-tmp janitor" fail

# 12. Pid identity across a reboot (HOST-6). A machine reset reuses the pid
# space, so `kill -0` alone will happily confirm a pid recorded by the boot that
# died — the start time is what tells the two apart.
setsid sleep 300 & VP=$!; _SPAWNED_PGIDS+=("$VP")
wait_for 5 test -d "/proc/$VP"
_VP_STT="$(_hg_proc_starttime "$VP")"
hg_pid_matches "$VP" "$_VP_STT" && assert "pid_matches: live pid with its own starttime" pass || assert "pid_matches: live pid with its own starttime" fail
hg_pid_matches "$VP" "1" && assert "pid_matches: recycled pid rejected" fail || assert "pid_matches: recycled pid rejected" pass
hg_pid_matches "$VP" "" && assert "pid_matches: missing starttime rejected" fail || assert "pid_matches: missing starttime rejected" pass
kill -KILL "$VP" 2>/dev/null; wait "$VP" 2>/dev/null
wait_for 5 bash -c "! kill -0 $VP 2>/dev/null"
hg_pid_matches "$VP" "$_VP_STT" && assert "pid_matches: dead pid rejected" fail || assert "pid_matches: dead pid rejected" pass

# 13. Boot-relative file age (HOST-7): "was this written before the machine came
# up?" is how a resume tells a crash from a normal stop. No test can reboot a
# host, so the boot epoch has an override seam.
: > "$WORK/agefile"
HOST_GUARD_BTIME_OVERRIDE=1 hg_file_predates_boot "$WORK/agefile" \
  && assert "predates_boot: current file is not stale" fail || assert "predates_boot: current file is not stale" pass
HOST_GUARD_BTIME_OVERRIDE=9999999999 hg_file_predates_boot "$WORK/agefile" \
  && assert "predates_boot: file older than boot detected" pass || assert "predates_boot: file older than boot detected" fail
HOST_GUARD_BTIME_OVERRIDE=9999999999 hg_file_predates_boot "$WORK/nope" \
  && assert "predates_boot: missing file is not stale" fail || assert "predates_boot: missing file is not stale" pass

# 14. Durable event ledger (HOST-4). The ledger is the only cross-repo record of
# what the machine was doing; it must be valid JSON, must respect the no-op rule,
# and concurrent engines must not shred each other's lines.
EVENTS="$WORK/events.jsonl"
( export HOST_GUARD_EVENTS_FILE="$EVENTS" HOST_GUARD_HOST_ENV_FILE="$WORK/absent.env" HOST_GUARD_ENABLED=0
  source "$LIB"; hg_event noop_check '{"x":1}' )
[[ -f "$EVENTS" ]] && assert "event: no-op rule (no host env, not enabled) writes nothing" fail || assert "event: no-op rule (no host env, not enabled) writes nothing" pass

printf 'HOST_GUARD_GLOBAL_CPU_LIST="0-3"\n' > "$WORK/host-guard-host.env"
HOST_GUARD_EVENTS_FILE="$EVENTS" REPO_ROOT=/fake/projA GOAL_SESSION_ID=sessA \
  CHAIN_CURRENT_AGENT=developer hg_event iter_start '{"iter":7}'
assert_eq "event: one line written" "1" "$(wc -l < "$EVENTS" | tr -dc 0-9)"
if command -v jq >/dev/null 2>&1; then
  jq -e . "$EVENTS" >/dev/null 2>&1 && assert "event: valid JSON" pass || assert "event: valid JSON" fail
  assert_eq "event: carries project"  "/fake/projA" "$(jq -r '.project' "$EVENTS")"
  assert_eq "event: carries session"  "sessA"       "$(jq -r '.sid' "$EVENTS")"
  assert_eq "event: carries agent"    "developer"   "$(jq -r '.agent' "$EVENTS")"
  assert_eq "event: carries type"     "iter_start"  "$(jq -r '.event' "$EVENTS")"
  assert_eq "event: splices payload"  "7"           "$(jq -r '.iter' "$EVENTS")"
  assert_eq "event: carries boot id"  "$(_hg_boot_id)" "$(jq -r '.boot' "$EVENTS")"
else
  grep -q '"event":"iter_start"' "$EVENTS" && assert "event: carries type (no jq)" pass || assert "event: carries type (no jq)" fail
fi

# An oversized payload must be DROPPED, never truncated: half a JSON object in
# the ledger would break every reader for every later line.
: > "$EVENTS"
HOST_GUARD_EVENTS_FILE="$EVENTS" hg_event big "{\"blob\":\"$(head -c 1200 /dev/zero | tr '\0' 'x')\"}"
if command -v jq >/dev/null 2>&1; then
  jq -e . "$EVENTS" >/dev/null 2>&1 && assert "event: oversized payload still valid JSON" pass || assert "event: oversized payload still valid JSON" fail
fi
grep -q 'payload_dropped' "$EVENTS" && assert "event: oversized payload dropped, not truncated" pass || assert "event: oversized payload dropped, not truncated" fail

: > "$EVENTS"
# Wait on THESE pids only: a bare `wait` would also block on the long-lived
# `sleep 300` victim processes the registration tests keep alive, stalling the
# suite for minutes.
_APPENDERS=()
for _i in $(seq 1 20); do
  ( HOST_GUARD_EVENTS_FILE="$EVENTS" hg_event "concurrent$_i" '{"n":1}' ) &
  _APPENDERS+=("$!")
done
wait "${_APPENDERS[@]}"
assert_eq "event: 20 concurrent appenders → 20 lines" "20" "$(wc -l < "$EVENTS" | tr -dc 0-9)"
if command -v jq >/dev/null 2>&1; then
  assert_eq "event: every concurrent line is valid JSON" "20" "$(jq -c . "$EVENTS" 2>/dev/null | wc -l | tr -dc 0-9)"
fi

HOST_GUARD_EVENTS_FILE="$EVENTS" HOST_GUARD_EVENTS_MAX_BYTES=200 hg_event rotate_me '{"n":1}'
[[ -f "$EVENTS.1" ]] && assert "event: ring rotation at max bytes" pass || assert "event: ring rotation at max bytes" fail

# 15. Concurrent-engine cap (HOST-8). On a host whose resets are HARDWARE, the
# honest mitigation is fewer engines, not a narrower mask.
CAPREG="$WORK/capreg"; mkdir -p "$CAPREG"
setsid sleep 300 & C1=$!; _SPAWNED_PGIDS+=("$C1")
setsid sleep 300 & C2=$!; _SPAWNED_PGIDS+=("$C2")
wait_for 5 test -d "/proc/$C1"; wait_for 5 test -d "/proc/$C2"
CAP_SENIOR="$(HOST_GUARD_REGISTRY_DIR="$CAPREG" hg_register engine "$C1" /fake/capA sA "0-3" 4G)"
sleep 1
CAP_JUNIOR="$(HOST_GUARD_REGISTRY_DIR="$CAPREG" hg_register engine "$C2" /fake/capB sB "0-3" 4G)"
_cap_verdict() { # $1 own_rec, $2 cap
  HOST_GUARD_REGISTRY_DIR="$CAPREG" HOST_GUARD_GLOBAL_CPU_LIST="0-3" \
    HOST_GUARD_MAX_ENGINES="$2" hg_aggregate_verdict "$1"
}
case "$(_cap_verdict "$CAP_JUNIOR" 1)" in
  PAUSE\|*) assert "cap: junior engine pauses over HOST_GUARD_MAX_ENGINES=1" pass ;;
  *)        assert "cap: junior engine pauses over HOST_GUARD_MAX_ENGINES=1" fail ;;
esac
_cap_verdict "$CAP_JUNIOR" 1 | grep -q 'HOST_GUARD_MAX_ENGINES=1' \
  && assert "cap: pause message names the knob" pass || assert "cap: pause message names the knob" fail
case "$(_cap_verdict "$CAP_SENIOR" 1)" in
  WARN\|*) assert "cap: senior engine warns and keeps running" pass ;;
  *)       assert "cap: senior engine warns and keeps running" fail ;;
esac
assert_eq "cap: cap=2 with 2 engines is OK"    "OK" "$(_cap_verdict "$CAP_JUNIOR" 2)"
# The case that matters most on a capped host: ONE engine under cap=1 must run.
# An off-by-one here (>= instead of >) would pause every single session forever.
SOLOREG="$WORK/soloreg"; mkdir -p "$SOLOREG"
CAP_SOLO="$(HOST_GUARD_REGISTRY_DIR="$SOLOREG" hg_register engine "$C1" /fake/solo s1 "0-3" 4G)"
assert_eq "cap: the ONLY engine runs under cap=1" "OK" \
  "$(HOST_GUARD_REGISTRY_DIR="$SOLOREG" HOST_GUARD_GLOBAL_CPU_LIST="0-3" \
     HOST_GUARD_MAX_ENGINES=1 hg_aggregate_verdict "$CAP_SOLO")"
assert_eq "cap: absent cap = unlimited"        "OK" "$(_cap_verdict "$CAP_JUNIOR" '')"
assert_eq "cap: junk cap ignored"              "OK" "$(_cap_verdict "$CAP_JUNIOR" 'abc')"
assert_eq "cap: cap=0 ignored (never lock out)" "OK" "$(_cap_verdict "$CAP_JUNIOR" 0)"
# A pump is not an engine: only engines count toward the cap.
HOST_GUARD_REGISTRY_DIR="$CAPREG" hg_register pump "$C1" /fake/capA sA "0-3" 4G >/dev/null
assert_eq "cap: pump records do not count as engines" "OK" "$(_cap_verdict "$CAP_JUNIOR" 2)"

# 16. Pump display environment (HOST_GUARD_PUMP_HEADLESS_QA). Fake procfs root
# first — deterministic, platform-independent — then real processes.
FPROC="$WORK/fakeproc"; mkdir -p "$FPROC/101" "$FPROC/102" "$FPROC/103" "$FPROC/104" "$FPROC/105"
printf 'HOME=/h\0DISPLAY=:1\0PATH=/bin\0' > "$FPROC/101/environ";              printf 'State:\tS (sleeping)\n' > "$FPROC/101/status"
printf 'HOME=/h\0WAYLAND_DISPLAY=wayland-0\0' > "$FPROC/102/environ";        printf 'State:\tS (sleeping)\n' > "$FPROC/102/status"
printf 'HOME=/h\0PATH=/bin\0' > "$FPROC/103/environ";                          printf 'State:\tS (sleeping)\n' > "$FPROC/103/status"
printf 'HOME=/h\0DISPLAY=\0' > "$FPROC/104/environ";                            printf 'State:\tS (sleeping)\n' > "$FPROC/104/status"
: > "$FPROC/105/environ";                                                        printf 'State:\tZ (zombie)\n' > "$FPROC/105/status"
pdv() { HOST_GUARD_PROC_ROOT="$FPROC" hg_pump_display_verdict "$1"; }
assert_eq "display: DISPLAY=:1 in the pump env → display-bound" "display-bound: DISPLAY=:1" "$(pdv 101)"
assert_eq "display: WAYLAND_DISPLAY only → display-bound"        "display-bound: WAYLAND_DISPLAY=wayland-0" "$(pdv 102)"
assert_eq "display: neither variable → display-less"            "display-less" "$(pdv 103)"
assert_eq "display: present-but-empty DISPLAY counts as absent" "display-less" "$(pdv 104)"
case "$(pdv 105)" in unreadable:*) assert "display: zombie (empty environ) → unreadable, never a fact" pass ;; *) assert "display: zombie (empty environ) → unreadable, never a fact (got '$(pdv 105)')" fail ;; esac
case "$(pdv 999999)" in unreadable:*) assert "display: gone pid → unreadable" pass ;; *) assert "display: gone pid → unreadable (got '$(pdv 999999)')" fail ;; esac
case "$(pdv abc)" in unreadable:*) assert "display: junk pid → unreadable" pass ;; *) assert "display: junk pid → unreadable (got '$(pdv abc)')" fail ;; esac
case "$(HOST_GUARD_PROC_ROOT="$WORK/no-such-proc" hg_pump_display_verdict 101)" in unreadable:*) assert "display: no procfs at all (non-Linux) → unreadable" pass ;; *) assert "display: no procfs at all (non-Linux) → unreadable" fail ;; esac
chmod 000 "$FPROC/101/environ"
if [[ "$(id -u)" != "0" ]]; then
  case "$(pdv 101)" in unreadable:*) assert "display: permission-denied environ → unreadable" pass ;; *) assert "display: permission-denied environ → unreadable (got '$(pdv 101)')" fail ;; esac
fi
chmod 644 "$FPROC/101/environ"
# Real processes: the helper reads the REAL /proc of a process this test spawned.
setsid env -u WAYLAND_DISPLAY DISPLAY=:9 sleep 300 & RP_HEADED=$!; _SPAWNED_PGIDS+=("$RP_HEADED")
setsid env -u DISPLAY -u WAYLAND_DISPLAY sleep 300 & RP_HEADLESS=$!; _SPAWNED_PGIDS+=("$RP_HEADLESS")
setsid env -u DISPLAY WAYLAND_DISPLAY=wayland-1 sleep 300 & RP_WAYLAND=$!; _SPAWNED_PGIDS+=("$RP_WAYLAND")
wait_for 5 test -d "/proc/$RP_HEADED"; wait_for 5 test -d "/proc/$RP_HEADLESS"; wait_for 5 test -d "/proc/$RP_WAYLAND"
assert_eq "display(real): process launched with DISPLAY=:9 → display-bound" "display-bound: DISPLAY=:9" "$(hg_pump_display_verdict "$RP_HEADED")"
assert_eq "display(real): process launched display-less → display-less" "display-less" "$(hg_pump_display_verdict "$RP_HEADLESS")"
assert_eq "display(real): WAYLAND_DISPLAY → display-bound" "display-bound: WAYLAND_DISPLAY=wayland-1" "$(hg_pump_display_verdict "$RP_WAYLAND")"
[[ "$(hg_pid_display_env "$RP_HEADED")" == "DISPLAY=:9" ]] \
  && assert "display(real): hg_pid_display_env prints the present variables verbatim" pass \
  || assert "display(real): hg_pid_display_env prints the present variables verbatim (got '$(hg_pid_display_env "$RP_HEADED")')" fail

echo ""
echo "── B. run-goal.sh wiring (real engine, stub claude) ────────────────────"

SBX="$WORK/proj"
mkdir -p "$SBX"
cp -r "$ENGINE_ROOT/scripts" "$SBX/"
mkdir -p "$SBX/docs/phases" "$SBX/reports" "$SBX/src" "$SBX/.claude/agents" \
         "$SBX/project-extensions/host-guard" "$SBX/logs/hwmon"
touch "$SBX/.claude/agents/developer.md"
git init -q "$SBX"
echo "print('v1')" > "$SBX/src/app.py"
cat > "$SBX/docs/goal.md" <<'EOF'
# Goal

Tiny CSV exporter web app.

## Must-have user journeys

- **J-01: Open the page**
  - Steps: open /
  - Acceptance: page loads

## Anti-goals

- no paid SaaS
EOF
git -C "$SBX" add -A
git -C "$SBX" -c user.email=t@t -c user.name=t commit -qm base

# Project host-guard: mask "0" so the engine is confinable on any host, and a
# stub sampler so preflight check 1 passes without a real hwmon reader.
cat > "$SBX/project-extensions/host-guard/host-guard.env" <<'EOF'
HOST_GUARD_ENABLED=1
HOST_GUARD_CPU_LIST="0"
HOST_GUARD_MEMORY_HIGH="10G"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$SBX/project-extensions/host-guard/hwmon-log.sh"
chmod +x "$SBX/project-extensions/host-guard/hwmon-log.sh"

STUB_DIR="$WORK/bin"; mkdir -p "$STUB_DIR"
printf '#!/usr/bin/env bash\necho "stub 0.0"\n' > "$STUB_DIR/claude"
chmod +x "$STUB_DIR/claude"

TMPROOT="$WORK/tmproot2"; mkdir -p "$TMPROOT"
ENG_REG="$WORK/registry-engine"; mkdir -p "$ENG_REG"
ENG_BOOST="$WORK/boost-engine"; echo 0 > "$ENG_BOOST"
HOSTENV="$WORK/engine-host.env"

# CHROME_PROFILE_ROOT / HOST_GUARD_MCP_MATCH are scoped to the sandbox because
# the engine's EXIT trap reaps QA browsers (lib/common.sh:qa_browser_reap_on_exit)
# — unscoped, a test engine's exit would scan the developer's real profile root.
run_goal_bg() { # log, then run-goal args
  local log="$1"; shift
  ( cd "$SBX" && env "PATH=$STUB_DIR:$PATH" \
      CHAIN_DOCTOR=false CHAIN_GOAL_LINT=false CHAIN_SKIP_GITHUB_PREFLIGHT=true \
      CHAIN_TMP_ROOT="$TMPROOT" CHAIN_TMP_LEGACY_ROOTS="" \
      CHAIN_BACKEND_PORT=48491 CHAIN_FRONTEND_PORT=48492 \
      HOST_GUARD_REGISTRY_DIR="$ENG_REG" \
      HOST_GUARD_HOST_ENV_FILE="$HOSTENV" \
      HOST_GUARD_SYS_BOOST_PATH="$ENG_BOOST" \
      CHROME_PROFILE_ROOT="$SBX/.chrome-profiles" \
      HOST_GUARD_MCP_MATCH="$SBX/no-such-mcp" \
      setsid bash scripts/automation/run-goal.sh "$@" ) >"$log" 2>&1 &
  _SPAWNED_PGIDS+=("$!")
}
status_of() { python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('status',''))" "$1" 2>/dev/null; }
is_paused() { [[ "$(status_of "$1")" == "AWAITING_HOST_GUARD" ]]; }

# B1. Junior session pauses against a live senior registrant that exhausts the
# machine budget.
cat > "$HOSTENV" <<'EOF'
HOST_GUARD_GLOBAL_CPU_LIST="0"
HOST_GUARD_GLOBAL_MEMORY_BUDGET="12G"
HOST_GUARD_REQUIRE_BOOST_OFF=1
EOF
setsid sleep 300 & SENIOR=$!; _SPAWNED_PGIDS+=("$SENIOR")
wait_for 5 test -d "/proc/$SENIOR"
SEN_STT="$(_hg_proc_starttime "$SENIOR")"
printf 'kind=engine\npid=%s\nstarttime=%s\nboot_id=%s\nhost=h\nepoch=1\nproject_root=/fake/senior\nsession_id=seniorsid\ncpu_list=0\nmemory_high=10G\n' \
  "$SENIOR" "$SEN_STT" "$(_hg_boot_id)" > "$ENG_REG/engine-$SENIOR-$SEN_STT.rec"

run_goal_bg "$WORK/hg1.log" --session-id hg1 --max-iter 1
SJ1="$SBX/runs/goal-session-hg1/session.json"
if wait_for 90 is_paused "$SJ1"; then
  assert "engine: junior session pauses AWAITING_HOST_GUARD" pass
  grep -q "seniorsid" "$WORK/hg1.log" && assert "engine: pause message names the senior session" pass || assert "engine: pause message names the senior session" fail
  grep -qi "memory" "$WORK/hg1.log" && assert "engine: pause message names the memory budget" pass || assert "engine: pause message names the memory budget" fail
else
  assert "engine: junior session pauses AWAITING_HOST_GUARD (status=$(status_of "$SJ1"))" fail
  assert "engine: pause message names the senior session" fail
  assert "engine: pause message names the memory budget" fail
fi
# The paused STATUS is written before the process exits; the lock is released in
# the EXIT trap that follows. Polling for it is the honest assertion — checking
# the instant the status flips races the trap, and the race widens with every
# fsync on the cleanup path (the durable event ledger added two).
if wait_for 20 bash -c "! [[ -d '$SBX/runs/goal-session-hg1/.engine.lock' ]]"; then
  assert "engine: lock released on host-guard pause" pass
else
  assert "engine: lock released on host-guard pause" fail
fi
ls "$ENG_REG"/engine-*.rec 2>/dev/null | grep -qv "engine-$SENIOR-" && assert "engine: junior's own record released on pause" fail || assert "engine: junior's own record released on pause" pass

# B2. With the budget raised the same session proceeds (WARN path, not PAUSE).
kill -KILL "$SENIOR" 2>/dev/null; wait "$SENIOR" 2>/dev/null
sed -i 's/HOST_GUARD_GLOBAL_MEMORY_BUDGET=.*/HOST_GUARD_GLOBAL_MEMORY_BUDGET="22G"/' "$HOSTENV"
# Getting PAST the host-guard preflight is the assertion — how far the run then
# travels (a dispatch, a later gate) is another test's business.
past_host_guard() { grep -q 'Step 1\|Step 0\|GitHub access preflight\|baseline' "$1"; }
run_goal_bg "$WORK/hg2.log" --session-id hg2 --max-iter 1
SJ2="$SBX/runs/goal-session-hg2/session.json"
if wait_for 90 past_host_guard "$WORK/hg2.log"; then
  assert "engine: budget satisfied → session proceeds past host-guard" pass
else
  assert "engine: budget satisfied → session proceeds past host-guard (status=$(status_of "$SJ2"))" fail
fi
[[ "$(status_of "$SJ2")" == "AWAITING_HOST_GUARD" ]] && assert "engine: budget satisfied → no host-guard pause" fail || assert "engine: budget satisfied → no host-guard pause" pass
wait_for 20 bash -c "ls '$ENG_REG'/engine-*.rec >/dev/null 2>&1" \
  && assert "engine: registers itself while running" pass || assert "engine: registers itself while running" fail
pkill -KILL -f "$SBX/" 2>/dev/null; sleep 0.5

# B3. Boost regression pauses at preflight; clearing it lets --resume through.
echo 1 > "$ENG_BOOST"
rm -f "$ENG_REG"/*.rec
run_goal_bg "$WORK/hg3.log" --session-id hg3 --max-iter 1
SJ3="$SBX/runs/goal-session-hg3/session.json"
if wait_for 90 is_paused "$SJ3"; then
  assert "engine: CPU boost ON pauses at preflight" pass
  grep -qi "boost is ON" "$WORK/hg3.log" && assert "engine: boost pause explains the knob" pass || assert "engine: boost pause explains the knob" fail
else
  assert "engine: CPU boost ON pauses at preflight (status=$(status_of "$SJ3"))" fail
  assert "engine: boost pause explains the knob" fail
fi

echo 0 > "$ENG_BOOST"
run_goal_bg "$WORK/hg3b.log" --session-id hg3 --resume --max-iter 1
if wait_for 90 past_host_guard "$WORK/hg3b.log"; then
  assert "engine: resume passes once boost is back off" pass
else
  assert "engine: resume passes once boost is back off (status=$(status_of "$SJ3"))" fail
fi
pkill -KILL -f "$SBX/" 2>/dev/null

echo ""
echo "── C. interactive pump headless preflight (real engine, --interactive) ──"
# The pump is a fake CLI root this test launched with a known environment;
# HOST_GUARD_PUMP_ROOT_PID hands it to the gate exactly as the engine's own
# launch-time capture would. The engine runs with --interactive, so the first
# model dispatch would be a req.* file in the dispatch channel — its ABSENCE is
# the proof that a pause landed before any model work.
set_headless_policy() { # 1|0
  sed -i '/^HOST_GUARD_PUMP_HEADLESS_QA=/d' "$SBX/project-extensions/host-guard/host-guard.env"
  [[ "$1" == "1" ]] && echo 'HOST_GUARD_PUMP_HEADLESS_QA=1' >> "$SBX/project-extensions/host-guard/host-guard.env"
  return 0
}
reached_step1() { grep -q 'Step 1: goal-decomposer' "$1"; }
no_dispatch() { ! ls "$1"/dispatch/req.* >/dev/null 2>&1; }
# The gate writes the session summary (status flips) BEFORE _host_guard_pause
# prints its reason and records the halt event, and the engine's stdout reaches
# the console log through a timestamping tee — so wait for the reason line and
# the telemetry row, not just the status flip, before reading either.
paused_logged() { is_paused "$1" && grep -q '\[run-goal\]   reason:' "$2" && grep -q 'iteration_gate' "$3" 2>/dev/null; }
setsid env -u WAYLAND_DISPLAY DISPLAY=:9 sleep 300 & PUMP_HEADED=$!; _SPAWNED_PGIDS+=("$PUMP_HEADED")
setsid env -u DISPLAY -u WAYLAND_DISPLAY sleep 300 & PUMP_HEADLESS=$!; _SPAWNED_PGIDS+=("$PUMP_HEADLESS")
setsid env -u DISPLAY WAYLAND_DISPLAY=wayland-0 sleep 300 & PUMP_WAYLAND=$!; _SPAWNED_PGIDS+=("$PUMP_WAYLAND")
wait_for 5 test -d "/proc/$PUMP_HEADED"; wait_for 5 test -d "/proc/$PUMP_HEADLESS"; wait_for 5 test -d "/proc/$PUMP_WAYLAND"
rm -f "$ENG_REG"/*.rec

# C1 (R15). Policy on, pump launched WITH DISPLAY → resumable pause before any dispatch.
set_headless_policy 1
export HOST_GUARD_PUMP_ROOT_PID="$PUMP_HEADED"
run_goal_bg "$WORK/hg4.log" --session-id hg4 --max-iter 1 --interactive
SJ4="$SBX/runs/goal-session-hg4/session.json"
if wait_for 90 paused_logged "$SJ4" "$WORK/hg4.log" "$SBX/runs/goal-session-hg4/telemetry.jsonl"; then
  assert "pump: display-bound pump + headless policy → AWAITING_HOST_GUARD (resumable)" pass
  grep -q 'DISPLAY=:9' "$WORK/hg4.log" && assert "pump: pause reason names the offending variable" pass || assert "pump: pause reason names the offending variable" fail
  grep -q 'host-guard-exec.sh' "$WORK/hg4.log" && assert "pump: pause reason tells the operator to relaunch via host-guard-exec.sh" pass || assert "pump: pause reason tells the operator to relaunch via host-guard-exec.sh" fail
  no_dispatch "$SBX/runs/goal-session-hg4" && assert "pump: NO model dispatch was published before the pause (no req.* file)" pass || assert "pump: NO model dispatch was published before the pause" fail
  reached_step1 "$WORK/hg4.log" && assert "pump: paused BEFORE Step 1 (goal-decomposer never started)" fail || assert "pump: paused BEFORE Step 1 (goal-decomposer never started)" pass
  grep -q '"detected_at_step":"iteration_gate"' "$SBX/runs/goal-session-hg4/telemetry.jsonl" 2>/dev/null \
    && assert "pump: halt telemetry attributes the pause to the iteration gate" pass || assert "pump: halt telemetry attributes the pause to the iteration gate" fail
else
  assert "pump: display-bound pump + headless policy → AWAITING_HOST_GUARD (status=$(status_of "$SJ4"))" fail
  for _n in "names the offending variable" "tells the operator to relaunch" "no req.* file" "paused BEFORE Step 1" "halt telemetry"; do assert "pump: $_n" fail; done
fi
pkill -KILL -f "$SBX/" 2>/dev/null; sleep 0.5

# C2 (R14). Policy on, pump launched display-less → the gate proceeds to Step 1.
export HOST_GUARD_PUMP_ROOT_PID="$PUMP_HEADLESS"
run_goal_bg "$WORK/hg5.log" --session-id hg5 --max-iter 1 --interactive
SJ5="$SBX/runs/goal-session-hg5/session.json"
if wait_for 90 reached_step1 "$WORK/hg5.log"; then
  assert "pump: display-less pump + headless policy → proceeds to Step 1" pass
  grep -q 'display-less' "$WORK/hg5.log" && assert "pump: the gate logs the verified display-less pump" pass || assert "pump: the gate logs the verified display-less pump" fail
else
  assert "pump: display-less pump + headless policy → proceeds to Step 1 (status=$(status_of "$SJ5"))" fail
  assert "pump: the gate logs the verified display-less pump" fail
fi
[[ "$(status_of "$SJ5")" == "AWAITING_HOST_GUARD" ]] && assert "pump: healthy pump never pauses" fail || assert "pump: healthy pump never pauses" pass
pkill -KILL -f "$SBX/" 2>/dev/null; sleep 0.5

# C3. WAYLAND_DISPLAY alone is display-bound too.
export HOST_GUARD_PUMP_ROOT_PID="$PUMP_WAYLAND"
run_goal_bg "$WORK/hg6.log" --session-id hg6 --max-iter 1 --interactive
SJ6="$SBX/runs/goal-session-hg6/session.json"
if wait_for 90 paused_logged "$SJ6" "$WORK/hg6.log" "$SBX/runs/goal-session-hg6/telemetry.jsonl"; then
  assert "pump: WAYLAND_DISPLAY-bound pump → pause" pass
  grep -q 'WAYLAND_DISPLAY=wayland-0' "$WORK/hg6.log" && assert "pump: pause names WAYLAND_DISPLAY" pass || assert "pump: pause names WAYLAND_DISPLAY" fail
else
  assert "pump: WAYLAND_DISPLAY-bound pump → pause (status=$(status_of "$SJ6"))" fail; assert "pump: pause names WAYLAND_DISPLAY" fail
fi
pkill -KILL -f "$SBX/" 2>/dev/null; sleep 0.5

# C4 (R16). Policy OFF: a display-bound pump is not the gate's business.
set_headless_policy 0
export HOST_GUARD_PUMP_ROOT_PID="$PUMP_HEADED"
run_goal_bg "$WORK/hg7.log" --session-id hg7 --max-iter 1 --interactive
if wait_for 90 reached_step1 "$WORK/hg7.log"; then
  assert "pump: policy off → display-bound pump proceeds (no new gate behavior)" pass
else
  assert "pump: policy off → display-bound pump proceeds (status=$(status_of "$SBX/runs/goal-session-hg7/session.json"))" fail
fi
grep -q 'display' "$WORK/hg7.log" && assert "pump: policy off → the gate says nothing about displays" fail || assert "pump: policy off → the gate says nothing about displays" pass
pkill -KILL -f "$SBX/" 2>/dev/null; sleep 0.5

# C5 (R16). Policy on + CHAIN_BQA_HEADED=1 (the headed debugging escape) → no-op.
set_headless_policy 1
export CHAIN_BQA_HEADED=1
run_goal_bg "$WORK/hg8.log" --session-id hg8 --max-iter 1 --interactive
if wait_for 90 reached_step1 "$WORK/hg8.log"; then
  assert "pump: CHAIN_BQA_HEADED=1 escape → display-bound pump proceeds" pass
else
  assert "pump: CHAIN_BQA_HEADED=1 escape → display-bound pump proceeds (status=$(status_of "$SBX/runs/goal-session-hg8/session.json"))" fail
fi
unset CHAIN_BQA_HEADED
pkill -KILL -f "$SBX/" 2>/dev/null; sleep 0.5

# C6. Policy on, no usable pump pid (root pid gone, heartbeat has no ident) but
# a LIVE heartbeat → loud pause, never a silent bypass (mirrors the cpuset check).
setsid sleep 1 & GONE=$!; wait "$GONE" 2>/dev/null || true
export HOST_GUARD_PUMP_ROOT_PID="$GONE"
run_goal_bg "$WORK/hg9.log" --session-id hg9 --max-iter 1 --interactive
SJ9="$SBX/runs/goal-session-hg9/session.json"
if wait_for 90 paused_logged "$SJ9" "$WORK/hg9.log" "$SBX/runs/goal-session-hg9/telemetry.jsonl"; then
  assert "pump: unidentifiable live pump under the headless policy → pause (cannot verify ≠ verified)" pass
  grep -q 'cannot verify' "$WORK/hg9.log" && assert "pump: the pause says it could not verify, not that the pump is headed" pass || assert "pump: the pause says it could not verify, not that the pump is headed" fail
else
  assert "pump: unidentifiable live pump under the headless policy → pause (status=$(status_of "$SJ9"))" fail
  assert "pump: the pause says it could not verify, not that the pump is headed" fail
fi
pkill -KILL -f "$SBX/" 2>/dev/null; sleep 0.5
unset HOST_GUARD_PUMP_ROOT_PID
set_headless_policy 0

echo ""
echo "──────────────────────────────────────────────────────────────────────"
echo "  PASS: $PASS   FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
