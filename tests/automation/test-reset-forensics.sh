#!/usr/bin/env bash
# test-reset-forensics.sh — the platform's own reset-reason register (HOST-2/3/7):
#   A. classification: fault vs planned reboot vs clean vs unreadable, and the
#      fault streak over recent boots
#   B. the postmortem bundle: who was running, the final pre-reset telemetry,
#      session tails, idempotency, and the no-op rule on healthy hosts
#   C. doctor rows (reset-reason, ras-logging) driven by the same fixtures
#   D. engine wiring: the call sites that make any of this fire
#
# Offline, no root, no journal, no model calls: every kernel log, boot list and
# registry record is a fixture, injected through the documented env seams.
#
# WHY THIS SUITE EXISTS: seven hard resets were investigated as software load
# problems while the CPU printed the cause on every boot. The regression this
# guards against is silence — a reader that reports CLEAN when it cannot read,
# or that never gets called.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RF="$ENGINE_ROOT/scripts/automation/host-guard/reset-forensics.sh"
DOCTOR="$ENGINE_ROOT/scripts/automation/doctor.sh"

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}
assert_eq() { # name expected actual
  if [[ "$2" == "$3" ]]; then assert "$1" pass; else echo "  FAIL  $1 (expected '$2', got '$3')"; FAIL=$((FAIL + 1)); fi
}
assert_has() { # name needle haystack
  if [[ "$3" == *"$2"* ]]; then assert "$1" pass; else echo "  FAIL  $1 (no '$2' in output)"; FAIL=$((FAIL + 1)); fi
}
assert_lacks() { # name needle haystack
  if [[ "$3" != *"$2"* ]]; then assert "$1" pass; else echo "  FAIL  $1 (unexpected '$2' in output)"; FAIL=$((FAIL + 1)); fi
}

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; return 0; }
trap cleanup EXIT

# ── Fixtures ────────────────────────────────────────────────────────────────
# The real lines this machine printed, verbatim — a paraphrase would let the
# parser drift away from the format it actually has to read.
FAULT_LINE='Jul 30 17:14:29 host kernel: x86/amd: Previous system reset reason [0x08000800]: an uncorrected error caused a data fabric sync flood event'
REBOOT_LINE='Jul 21 18:40:54 host kernel: x86/amd: Previous system reset reason [0x00080800]: software wrote 0x6 to reset control register 0xCF9'

mkdir -p "$WORK/klogs"
printf 'Jul 30 17:14:29 host kernel: Linux version 7.0.0-28-generic\nJul 30 17:14:29 host kernel: Command line: ro quiet\n' > "$WORK/klog-clean"
{ cat "$WORK/klog-clean"; printf '%s\n' "$FAULT_LINE"; }  > "$WORK/klog-fault"
{ cat "$WORK/klog-clean"; printf '%s\n' "$REBOOT_LINE"; } > "$WORK/klog-reboot"

# Four boots: two faults, one planned reboot, one clean.
cat > "$WORK/boots" <<'EOF'
IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
 -3 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1 Mon 2026-07-27 20:46:48 BST Tue 2026-07-28 01:07:32 BST
 -2 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2 Tue 2026-07-28 01:08:33 BST Wed 2026-07-29 14:00:08 BST
 -1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3 Wed 2026-07-29 14:03:25 BST Thu 2026-07-30 17:10:26 BST
  0 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa4 Thu 2026-07-30 17:14:29 BST Thu 2026-07-30 20:56:10 BST
EOF
cp "$WORK/klog-clean"  "$WORK/klogs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1.klog"
cp "$WORK/klog-reboot" "$WORK/klogs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2.klog"
cp "$WORK/klog-fault"  "$WORK/klogs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3.klog"
cp "$WORK/klog-fault"  "$WORK/klogs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa4.klog"

# A dead boot's registry: two engines and a pump from a boot that no longer is.
REG="$WORK/registry"; mkdir -p "$REG"
BOOT_EPOCH=1785400000        # pretend the current boot started here
_mkrec() { # <file> <kind> <pid> <root> <sid>
  cat > "$REG/$1" <<EOF
kind=$2
pid=$3
starttime=999999
boot_id=dead-beef-from-the-boot-that-died
host=testhost
epoch=1785351643
project_root=$4
session_id=$5
cpu_list=0-3,8-11
memory_high=10G
EOF
}
_mkrec "engine-101-999999.rec" engine 101 "$WORK/projA" desk
_mkrec "engine-102-999999.rec" engine 102 "$WORK/projB" ops
_mkrec "pump-103-999999.rec"   pump   103 "$WORK/projA" ""

for p in projA projB; do
  mkdir -p "$WORK/$p/logs/hwmon"
done
# Pre-reset samples (epoch < BOOT_EPOCH) plus, for projA, post-reboot samples a
# restarted sampler would append — the bundle must show the former, not the latter.
{ echo "epoch,tctl_c,gpu_edge_c,ppt_w,ppt_avg_w,nvme_c,dimm0_c,dimm1_c,acpitz_c,load1,mem_avail_mb,swap_free_mb,psi_cpu_avg10,psi_mem_avg10,cpu_mhz"
  for i in $(seq 1 25); do echo "$(( BOOT_EPOCH - 100 + i )),65,57,26,22,40,56,55,20,6.54,11513,28522,0.00,0.00,3900"; done
  echo "$(( BOOT_EPOCH + 5000 )),44,40,8,5,40,45,44,20,0.10,23000,28671,0.00,0.00,1200"
} > "$WORK/projA/logs/hwmon/hwmon.csv"
{ echo "epoch,tctl_c,gpu_edge_c,ppt_w,ppt_avg_w,nvme_c,dimm0_c,dimm1_c,acpitz_c,load1,mem_avail_mb,swap_free_mb,psi_cpu_avg10,psi_mem_avg10,cpu_mhz"
  echo "$(( BOOT_EPOCH - 3 )),74,60,37,30,41,57,56,21,7.28,11424,28522,0.00,0.00,4100"
} > "$WORK/projB/logs/hwmon/hwmon.csv"

mkdir -p "$WORK/projA/runs/goal-session-desk" "$WORK/projB/runs/goal-session-ops"
printf '{"event":"iter_start","iter":26}\n{"event":"coherence_pass","iter":26}\n' \
  > "$WORK/projA/runs/goal-session-desk/telemetry.jsonl"
printf '16:56:11 [browser-qa] dispatching J-05 UNIQUEMARKER_ENGINELOG\n' \
  > "$WORK/projA/runs/goal-session-desk/engine.log"
printf '{"status":"in_progress","current_iter":26}\n' \
  > "$WORK/projA/runs/goal-session-desk/session.json"
printf '{"event":"iter_start","iter":39}\n' > "$WORK/projB/runs/goal-session-ops/telemetry.jsonl"

PM="$WORK/postmortems"
export HOST_GUARD_RESET_BOOTS_FILE="$WORK/boots"
export HOST_GUARD_RESET_KLOG_DIR="$WORK/klogs"
export HOST_GUARD_POSTMORTEM_DIR="$PM"
export HOST_GUARD_REGISTRY_DIR="$REG"
export HOST_GUARD_BTIME_OVERRIDE="$BOOT_EPOCH"
export HOST_GUARD_EVENTS_FILE="$WORK/events.jsonl"

echo "── A. classification ───────────────────────────────────────────────────"

OUT="$(HOST_GUARD_RESET_KLOG_FILE="$WORK/klog-fault" bash "$RF" check)"
assert_has "check: fault reported as RESET"       "RESET|0x08000800|" "$OUT"
assert_has "check: cause text preserved"          "data fabric sync flood" "$OUT"
assert_has "check: streak counts fault boots only" "|2/4|" "$OUT"
assert_has "check: names the dead boot"           "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3" "$OUT"

# The single highest-value false positive to avoid: an ordinary `reboot` also
# prints a reset-reason line. Treating it as an incident would cry wolf forever.
OUT="$(HOST_GUARD_RESET_KLOG_FILE="$WORK/klog-reboot" bash "$RF" check)"
assert_has   "check: planned reboot is CLEAN"        "CLEAN|" "$OUT"
assert_has   "check: planned reboot says why"        "software-initiated reboot" "$OUT"
assert_lacks "check: planned reboot is not a RESET"  "RESET|" "$OUT"

OUT="$(HOST_GUARD_RESET_KLOG_FILE="$WORK/klog-clean" bash "$RF" check)"
assert_has "check: clean boot reported CLEAN" "CLEAN|" "$OUT"

# Unreadable ≠ clean. A reader that cannot see the register must SAY so, or it
# silently certifies every machine as healthy.
OUT="$(HOST_GUARD_RESET_KLOG_FILE="$WORK/does-not-exist" bash "$RF" check)"
assert_has "check: unreadable log → UNKNOWN, never CLEAN" "UNKNOWN|" "$OUT"
# The realistic failure: journalctl EXISTS but returns nothing because this user
# cannot read the kernel log. Without the liveness probe that case would look
# exactly like a healthy machine. (All file seams cleared: this simulates a real
# host where journalctl is the only kernel-log source.)
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/journalctl"; chmod +x "$WORK/bin/journalctl"
OUT="$(PATH="$WORK/bin:$PATH" HOST_GUARD_RESET_KLOG_FILE="" HOST_GUARD_RESET_KLOG_DIR="" \
       HOST_GUARD_RESET_BOOTS_FILE="" bash "$RF" check 2>/dev/null)"
assert_has   "check: silent journalctl → UNKNOWN, never CLEAN" "UNKNOWN|" "$OUT"
assert_has   "check: UNKNOWN explains how to fix access"        "systemd-journal" "$OUT"

echo ""
echo "── B. postmortem bundle ────────────────────────────────────────────────"

OUT="$(HOST_GUARD_RESET_KLOG_FILE="$WORK/klog-clean" bash "$RF" ensure-postmortem)"
assert_has "bundle: clean boot → NONE" "NONE|" "$OUT"
[[ -d "$PM" && -n "$(ls -A "$PM" 2>/dev/null)" ]] \
  && assert "bundle: NO-OP RULE — clean boot writes no file" fail \
  || assert "bundle: NO-OP RULE — clean boot writes no file" pass

OUT="$(HOST_GUARD_RESET_KLOG_FILE="$WORK/klog-fault" bash "$RF" ensure-postmortem)"
assert_has "bundle: fault → POSTMORTEM|…|new" "|new" "$OUT"
BUNDLE="$PM/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa3.md"
[[ -f "$BUNDLE" ]] && assert "bundle: named after the dead boot" pass || assert "bundle: named after the dead boot" fail
BODY="$(cat "$BUNDLE" 2>/dev/null)"

assert_has "bundle: verbatim reset line"        "0x08000800" "$BODY"
assert_has "bundle: boot history table"         "**FAULT**" "$BODY"
assert_has "bundle: marks the planned reboot"   "| reboot |" "$BODY"
assert_has "bundle: names both dead engines"    "$WORK/projA" "$BODY"
assert_has "bundle: names the second project"   "$WORK/projB" "$BODY"
assert_has "bundle: names the dead session"     "session_id=desk" "$BODY"
assert_has "bundle: keeps the pump record too"  "kind=pump" "$BODY"
assert_has "bundle: session telemetry tail"     '"event":"coherence_pass"' "$BODY"
assert_has "bundle: engine log tail"            "UNIQUEMARKER_ENGINELOG" "$BODY"
assert_has "bundle: session.json state"         '"status":"in_progress"' "$BODY"
assert_has "bundle: points at the runbook"      "docs/host-guard.md" "$BODY"

# The telemetry window must be BOOT-RELATIVE. A sampler that restarted after the
# reboot keeps appending, and a plain `tail` would present live idle data as the
# machine's dying breath.
assert_has   "bundle: final pre-reset sample selected" "$(( BOOT_EPOCH - 75 ))" "$BODY"
assert_lacks "bundle: post-reboot samples excluded"    "$(( BOOT_EPOCH + 5000 ))" "$BODY"

OUT="$(HOST_GUARD_RESET_KLOG_FILE="$WORK/klog-fault" bash "$RF" ensure-postmortem)"
assert_has "bundle: second run is idempotent" "|existing" "$OUT"
BEFORE="$(stat -c %Y "$BUNDLE")"
HOST_GUARD_RESET_KLOG_FILE="$WORK/klog-fault" bash "$RF" ensure-postmortem >/dev/null
assert_eq "bundle: existing bundle is not rewritten" "$BEFORE" "$(stat -c %Y "$BUNDLE")"
[[ -L "$PM/latest.md" ]] && assert "bundle: latest.md points at the newest" pass || assert "bundle: latest.md points at the newest" fail
assert_has "report: prints the bundle" "0x08000800" "$(HOST_GUARD_RESET_KLOG_FILE="$WORK/klog-fault" bash "$RF" report 2>/dev/null)"

echo ""
echo "── C. doctor rows ──────────────────────────────────────────────────────"

_doc() { # $1 check key — env overrides come from the caller's prefix
  env CHAIN_DOCTOR_REPO_ROOT="$WORK/projA" bash "$DOCTOR" --only "$1" 2>&1
}

OUT="$(HOST_GUARD_RESET_KLOG_FILE="$WORK/klog-fault" _doc reset-reason)"
assert_has "doctor: reset-reason FAILs after a hardware reset" "FAIL" "$OUT"
assert_has "doctor: row carries the code"                      "0x08000800" "$OUT"
assert_has "doctor: row points at the postmortem"              "$PM/" "$OUT"
assert_lacks "doctor: row is one line (no crash wrapper)"      "check crashed" "$OUT"

OUT="$(HOST_GUARD_RESET_KLOG_FILE="$WORK/klog-clean" _doc reset-reason)"
assert_has "doctor: clean boot PASSes" "PASS" "$OUT"

# ras-logging must stay quiet on hosts that never had the incident, and must not
# smuggle a newline into its row (systemctl prints AND exits non-zero). "No
# incident" now means no fault boot in the WINDOW (the streak), not merely a
# clean current register — so this fixture needs a genuinely fault-free history.
cat > "$WORK/boots-nohist" <<'EOF'
IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
 -1 cccccccccccccccccccccccccccccc01 Wed 2026-07-29 08:00:00 BST Wed 2026-07-29 20:00:00 BST
  0 cccccccccccccccccccccccccccccc02 Wed 2026-07-29 20:01:00 BST Thu 2026-07-30 08:00:00 BST
EOF
mkdir -p "$WORK/klogs-nohist"
cp "$WORK/klog-clean"  "$WORK/klogs-nohist/cccccccccccccccccccccccccccccc01.klog"
cp "$WORK/klog-reboot" "$WORK/klogs-nohist/cccccccccccccccccccccccccccccc02.klog"
OUT="$(HOST_GUARD_RESET_KLOG_FILE="$WORK/klog-clean" CHAIN_DOCTOR_RAS_STATE=inactive \
       HOST_GUARD_RESET_BOOTS_FILE="$WORK/boots-nohist" HOST_GUARD_RESET_KLOG_DIR="$WORK/klogs-nohist" \
       CHAIN_DOCTOR_JOURNALD_DIR="$WORK/nojournald" _doc ras-logging)"
assert_has   "doctor: ras-logging quiet without reset history" "PASS" "$OUT"
assert_lacks "doctor: ras-logging never crashes the wrapper"   "check crashed" "$OUT"

OUT="$(HOST_GUARD_RESET_KLOG_FILE="$WORK/klog-fault" CHAIN_DOCTOR_RAS_STATE=inactive \
       CHAIN_DOCTOR_JOURNALD_DIR="$WORK/nojournald" _doc ras-logging)"
assert_has "doctor: ras-logging WARNs once the host has history" "WARN" "$OUT"
assert_has "doctor: WARN names rasdaemon"                        "rasdaemon" "$OUT"

mkdir -p "$WORK/journald.d"; printf '[Journal]\nSyncIntervalSec=15s\n' > "$WORK/journald.d/99-iad-sync.conf"
OUT="$(HOST_GUARD_RESET_KLOG_FILE="$WORK/klog-fault" CHAIN_DOCTOR_RAS_STATE=active \
       CHAIN_DOCTOR_JOURNALD_DIR="$WORK/journald.d" _doc ras-logging)"
assert_has "doctor: ras-logging PASSes once both are in place" "PASS" "$OUT"

assert_has "doctor: reset-reason is a registered check" "reset-reason" "$(bash "$DOCTOR" --list)"
assert_has "doctor: ras-logging is a registered check"  "ras-logging"  "$(bash "$DOCTOR" --list)"

echo ""
echo "── B2. boot-walk + watermark (the crash-#16 blind spot) ────────────────"

# The 2026-08-10 22:30 shape: boot b2 dies of a fault, boot b3 logs the decode
# line but is then shut down CLEANLY, boot b4 (current) latches nothing. The
# old boot-0-only read reported CLEAN forever and never froze the evidence.
cat > "$WORK/boots-walk" <<'EOF'
IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
 -3 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb01 Mon 2026-08-04 08:00:00 BST Mon 2026-08-04 11:59:00 BST
 -2 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb02 Mon 2026-08-04 12:00:00 BST Mon 2026-08-04 22:30:01 BST
 -1 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb03 Mon 2026-08-04 22:30:22 BST Mon 2026-08-04 22:54:05 BST
  0 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb04 Tue 2026-08-05 00:05:18 BST Tue 2026-08-05 00:08:00 BST
EOF
mkdir -p "$WORK/klogs-walk" "$WORK/ghwmon"
cp "$WORK/klog-clean" "$WORK/klogs-walk/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb01.klog"
cp "$WORK/klog-clean" "$WORK/klogs-walk/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb02.klog"
cp "$WORK/klog-fault" "$WORK/klogs-walk/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb03.klog"
cp "$WORK/klog-clean" "$WORK/klogs-walk/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb04.klog"
WMF="$WORK/watermark"
_walk() { # no KLOG_FILE → boot-walk mode through the file seams
  HOST_GUARD_RESET_BOOTS_FILE="$WORK/boots-walk" HOST_GUARD_RESET_KLOG_DIR="$WORK/klogs-walk" \
  HOST_GUARD_RESET_WATERMARK_FILE="$WMF" HOST_GUARD_HWMON_GLOBAL_DIR="$WORK/ghwmon" bash "$RF" "$@"
}

OUT="$(_walk check)"
assert_has "walk: decode in an intermediate boot → RESET"   "RESET|0x08000800|" "$OUT"
assert_has "walk: names the boot that DIED, not boot -1"    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb02" "$OUT"
[[ -f "$WMF" ]] && assert "walk: check never writes the watermark" fail \
                || assert "walk: check never writes the watermark" pass

OUT="$(_walk ensure-postmortem)"
assert_has "walk: bundle named after the dead boot"  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb02.md|new" "$OUT"
assert_eq  "walk: watermark advanced to the newest boot" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb04" "$(cat "$WMF" 2>/dev/null)"
assert_has "walk: bundle carries the verbatim decode line" "0x08000800" \
  "$(cat "$PM/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb02.md" 2>/dev/null)"

OUT="$(_walk check)"
assert_has   "walk: frozen + advanced → CLEAN"       "CLEAN|" "$OUT"
assert_lacks "walk: no repeat RESET after the freeze" "RESET|" "$OUT"

# A gap can span SEVERAL faults (2026-08-10 had two in one day): decode lines in
# d2 (d1 died) and d4 (d3 died); every fault in the gap must get a bundle.
cat > "$WORK/boots-walk2" <<'EOF'
IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
 -4 dddddddddddddddddddddddddddddd01 Mon 2026-08-04 08:00:00 BST Mon 2026-08-04 11:59:00 BST
 -3 dddddddddddddddddddddddddddddd02 Mon 2026-08-04 12:00:00 BST Mon 2026-08-04 18:00:00 BST
 -2 dddddddddddddddddddddddddddddd03 Mon 2026-08-04 18:01:00 BST Mon 2026-08-04 22:30:01 BST
 -1 dddddddddddddddddddddddddddddd04 Mon 2026-08-04 22:30:22 BST Mon 2026-08-04 22:54:05 BST
  0 dddddddddddddddddddddddddddddd05 Tue 2026-08-05 00:05:18 BST Tue 2026-08-05 00:08:00 BST
EOF
mkdir -p "$WORK/klogs-walk2"
for b in 01 03 05; do cp "$WORK/klog-clean" "$WORK/klogs-walk2/dddddddddddddddddddddddddddddd$b.klog"; done
for b in 02 04; do cp "$WORK/klog-fault" "$WORK/klogs-walk2/dddddddddddddddddddddddddddddd$b.klog"; done
WMF2="$WORK/watermark2"
_walk2() {
  HOST_GUARD_RESET_BOOTS_FILE="$WORK/boots-walk2" HOST_GUARD_RESET_KLOG_DIR="$WORK/klogs-walk2" \
  HOST_GUARD_RESET_WATERMARK_FILE="$WMF2" HOST_GUARD_HWMON_GLOBAL_DIR="$WORK/ghwmon" bash "$RF" "$@"
}
OUT="$(_walk2 ensure-postmortem)"
assert_has "walk: multi-fault gap reports the newest bundle" "dddddddddddddddddddddddddddddd03.md" "$OUT"
[[ -f "$PM/dddddddddddddddddddddddddddddd01.md" ]] \
  && assert "walk: the OLDER fault in the gap got a bundle too" pass \
  || assert "walk: the OLDER fault in the gap got a bundle too" fail
assert_has "walk: multi-fault gap then reads CLEAN" "CLEAN|" "$(_walk2 check)"

# streak stays available to consumers (doctor's ras row) after the freeze.
assert_has "streak: counts fault boots independently of the watermark" "STREAK|2/" \
  "$(_walk2 streak)"

echo ""
echo "── D. engine wiring ────────────────────────────────────────────────────"

RG="$ENGINE_ROOT/scripts/automation/run-goal.sh"
grep -q '_host_guard_reset_forensics' "$RG" \
  && assert "wiring: engine preflight reads the reset register" pass \
  || assert "wiring: engine preflight reads the reset register" fail
# Ordering is the whole point: hg_sweep deletes the records that say who was
# running, so the postmortem has to be taken first.
_fx="$(grep -n '^[[:space:]]*_host_guard_reset_forensics[[:space:]]*$' "$RG" | head -n 1 | cut -d: -f1)"
_sw="$(grep -n '^[[:space:]]*hg_sweep[[:space:]]*$' "$RG" | head -n 1 | cut -d: -f1)"
if [[ -n "$_fx" && -n "$_sw" ]] && (( _fx < _sw )); then
  assert "wiring: forensics runs BEFORE the registry sweep" pass
else
  assert "wiring: forensics runs BEFORE the registry sweep" fail
fi
grep -q 'machine_reset' "$RG" \
  && assert "wiring: resume reports a reset-killed session" pass \
  || assert "wiring: resume reports a reset-killed session" fail
grep -q 'GOAL_SESSION_DIR="$GOAL_SESSION_DIR_LOCAL" GOAL_SESSION_ID="$SESSION_ID" \\' "$RG" \
  && assert "wiring: resume event carries its own session context" pass \
  || assert "wiring: resume event carries its own session context" fail
grep -q 'hg_event engine_start' "$RG" \
  && assert "wiring: engine start is ledgered" pass || assert "wiring: engine start is ledgered" fail
grep -q 'hg_event aggregate_ok' "$RG" \
  && assert "wiring: the HEALTHY aggregate verdict is ledgered too" pass \
  || assert "wiring: the HEALTHY aggregate verdict is ledgered too" fail
QR="$ENGINE_ROOT/scripts/automation/lib/quota-retry.sh"
grep -q 'hg_event dispatch_start' "$QR" && grep -q 'hg_event dispatch_end' "$QR" \
  && assert "wiring: every agent dispatch is bracketed in the ledger" pass \
  || assert "wiring: every agent dispatch is bracketed in the ledger" fail
grep -q 'iad-hwmon.service' "$ENGINE_ROOT/docs/host-guard.md" 2>/dev/null \
  && assert "wiring: the machine-global sampler unit is documented" pass \
  || assert "wiring: the machine-global sampler unit is documented" fail

echo ""
echo "──────────────────────────────────────────────────────────────────────"
echo "  PASS: $PASS   FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
