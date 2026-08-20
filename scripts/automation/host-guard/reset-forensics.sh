#!/usr/bin/env bash
# reset-forensics.sh — the platform's own postmortem, read at every boot.
#
# WHY: seven hard resets on this host were debugged as software load problems
# through three generations of guard (per-scope caps → machine-global aggregate
# → QA-browser confinement) while the CPU had been printing the answer into the
# kernel log on every single boot:
#
#   x86/amd: Previous system reset reason [0x08000800]: an uncorrected error
#            caused a data fabric sync flood event
#
# A data fabric sync flood is an uncorrectable SoC/Infinity-Fabric error: the
# hardware asserts reset immediately, the OS is never notified, and NOTHING
# software does can prevent it. The 2026-07-30 17:14:08 reset happened with the
# machine-global aggregate bound armed and every check green — both projects
# inside 0-3,8-11, 10G+10G under a 22G budget, boost off and persisted, QA
# browsers confined — at 65 °C, 26 W, 11.5 GB free, memory PSI 0.00.
#
# So this script does not try to PREVENT anything. It makes every reset
# self-documenting: read the register, and when the last boot died, freeze what
# the chain was doing into a bundle BEFORE the engine's own registry sweep
# (run-goal.sh preflight) erases the only record of who was running.
#
# Usage / stdout contract — exactly one line, ALWAYS exit 0 (advisory by
# construction, like doctor.sh; a broken forensics reader must never stop a run):
#   check              RESET|<hex>|<cause>|<hits>/<boots>|<crashed_boot_id>
#                      CLEAN|<why>
#                      UNKNOWN|<why>
#   ensure-postmortem  POSTMORTEM|<path>|new   POSTMORTEM|<path>|existing
#                      NONE|<why>              UNKNOWN|<why>
#   streak             STREAK|<hits>/<boots>   UNKNOWN|<why>
#   report             print the newest bundle (rc 1 when there is none)
#
# NO-OP RULE (roadmap §20): a host whose kernel prints no reset-reason line —
# every non-AMD box, and every AMD box that has never reset — reports CLEAN and
# writes nothing at all. No config file is required for the read-only paths.
#
# BOOT-WALK + WATERMARK (fix for the 2026-08-10 crash-#16 blind spot): the
# decode line is printed by the boot AFTER a crash, and the original detector
# read ONLY boot 0's kernel log. A fault whose decode line lands in an
# intermediate boot that is then shut down cleanly (crash 22:30 → short boot →
# clean poweroff 22:54) was therefore invisible forever — and because
# ensure-postmortem gates on the same read, its evidence was never frozen.
# Now detection walks every boot NEWER than a persisted watermark (the last
# boot already examined; bounded to the last $WINDOW boots when no watermark
# is usable) and reports the newest unprocessed fault. `check` never writes;
# `ensure-postmortem` freezes one bundle PER unprocessed fault, then advances
# the watermark. The HOST_GUARD_RESET_KLOG_FILE seam keeps the original
# register-anchored single-boot behavior and never touches the watermark.
#
# Injection seams (how tests fake the world — no root, no journal, no API):
#   HOST_GUARD_RESET_KLOG_FILE       stands in for `journalctl -k -b 0`
#   HOST_GUARD_RESET_KLOG_DIR        per-boot logs: <dir>/<boot-id>.klog (streak)
#   HOST_GUARD_RESET_BOOTS_FILE      stands in for `journalctl --list-boots`
#   HOST_GUARD_RESET_JOURNAL_TAIL_FILE  stands in for `journalctl -b <dead> -n 80`
#   HOST_GUARD_POSTMORTEM_DIR        bundle dir (default <tmp-root>/host-guard/postmortems)
#   HOST_GUARD_RESET_BOOT_WINDOW     how many recent boots the streak scans (10)
#   HOST_GUARD_RESET_WATERMARK_FILE  last-examined-boot marker (default <tmp-root>/host-guard/reset-watermark)
#   HOST_GUARD_REGISTRY_DIR / CHAIN_TMP_ROOT / HOST_GUARD_EVENTS_FILE (via the lib)
#
# COST: every kernel-log read is a STREAM into `grep -m1`/`grep -q`, which exits
# at the first hit and SIGPIPEs the producer, so nothing is ever slurped into
# memory. Measured on the incident host: ~10 ms per boot, ~120 ms for a 10-boot
# streak. Do NOT "optimize" this with a head bound — the line lands at kernel
# log line 942 here, and a bound short enough to matter would report CLEAN on a
# machine that had just reset.
#
# No `set -e` and no `pipefail`: SIGPIPE on the producer is EXPECTED, and every
# failure path degrades to UNKNOWN rather than to a dead script.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The registry library owns the paths this bundle joins over (registry dir,
# record fields, boot id, events ledger). Source it when present; keep tiny
# local fallbacks so a vendored copy that is missing the lib still reports.
if [[ -f "$HERE/../lib/host-guard-registry.sh" ]]; then
  # shellcheck source=../lib/host-guard-registry.sh
  source "$HERE/../lib/host-guard-registry.sh"
fi
if ! declare -f hg_registry_dir >/dev/null 2>&1; then
  hg_registry_dir() { echo "${HOST_GUARD_REGISTRY_DIR:-${CHAIN_TMP_ROOT:-$HOME/.cache/iad}/host-guard/registry}"; }
  _hg_rec_field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }
  _hg_boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown"; }
  hg_boot_epoch() { awk '/^btime /{print $2; exit}' /proc/stat 2>/dev/null || echo 0; }
fi

RESET_PAT='Previous system reset reason'
# NOT every reset-reason line is an incident. An ordinary `reboot` writes 0x6 to
# the legacy reset control register 0xCF9, and the SoC dutifully reports it on
# the next boot ("[0x00080800]: software wrote 0x6 to reset control register
# 0xCF9"). Counting that as a fault would make every planned reboot look like a
# crash and would cry wolf on hosts that never had an incident.
BENIGN_PAT='software wrote|reset control register'
WINDOW="${HOST_GUARD_RESET_BOOT_WINDOW:-10}"
POSTMORTEM_DIR="${HOST_GUARD_POSTMORTEM_DIR:-${CHAIN_TMP_ROOT:-$HOME/.cache/iad}/host-guard/postmortems}"
EVENTS_FILE="${HOST_GUARD_EVENTS_FILE:-${CHAIN_TMP_ROOT:-$HOME/.cache/iad}/host-guard/events.jsonl}"
GLOBAL_HWMON="${HOST_GUARD_HWMON_GLOBAL_DIR:-${CHAIN_TMP_ROOT:-$HOME/.cache/iad}/host-guard/hwmon}/hwmon.csv"
WATERMARK_FILE="${HOST_GUARD_RESET_WATERMARK_FILE:-${CHAIN_TMP_ROOT:-$HOME/.cache/iad}/host-guard/reset-watermark}"

# ── Boot enumeration ────────────────────────────────────────────────────────

_boots_stream() { # `journalctl --list-boots` text; rc 1 when unavailable
  local out=""
  if [[ -n "${HOST_GUARD_RESET_BOOTS_FILE:-}" ]]; then
    [[ -r "$HOST_GUARD_RESET_BOOTS_FILE" ]] || return 1
    cat "$HOST_GUARD_RESET_BOOTS_FILE"
    return 0
  fi
  command -v journalctl >/dev/null 2>&1 || return 1
  out="$(journalctl --list-boots --no-pager 2>/dev/null)"
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# Rows only (drop the "IDX BOOT ID …" header): "<idx> <boot-id> <rest…>".
_boot_rows() { _boots_stream | awk '$1 ~ /^-?[0-9]+$/ {print}'; }

_prev_boot_id() { _boot_rows | awk '$1 == "-1" {print $2; exit}'; }

_is_benign() { grep -qiE "$BENIGN_PAT" <<< "${1:-}"; }

_boot_reset_line() { # $1 boot id → that boot's reset-reason line (empty if none)
  local bid="${1:-}" f
  if [[ -n "${HOST_GUARD_RESET_KLOG_DIR:-}" ]]; then
    f="$HOST_GUARD_RESET_KLOG_DIR/$bid.klog"
    [[ -r "$f" ]] || return 1
    grep -i -m1 "$RESET_PAT" "$f" 2>/dev/null
    return 0
  fi
  command -v journalctl >/dev/null 2>&1 || return 1
  journalctl -k -b "$bid" --no-pager 2>/dev/null | grep -i -m1 "$RESET_PAT"
  return 0
}

_boot_first_epoch() { # $1 boot id → epoch of that boot's first entry ("" if unknown)
  # Parsed from the boot list ("<idx> <bid> <Day> <date> <time> <tz> …") so it
  # works through the BOOTS_FILE seam too. Degrades to "" — callers fall back
  # to the current boot's btime, which is the pre-watermark behavior.
  local bid="${1:-}" row
  [[ -n "$bid" ]] || return 0
  row="$(_boot_rows | awk -v b="$bid" '$2 == b {print; exit}')"
  [[ -n "$row" ]] || return 0
  date -d "$(awk '{print $4" "$5" "$6}' <<< "$row")" +%s 2>/dev/null || true
}

_wm_read() { [[ -r "$WATERMARK_FILE" ]] && head -n 1 "$WATERMARK_FILE" 2>/dev/null; return 0; }

_wm_write() { # atomic-enough: a torn watermark must never mark a fault as seen
  local bid="${1:-}"
  [[ -n "$bid" ]] || return 0
  mkdir -p "$(dirname "$WATERMARK_FILE")" 2>/dev/null || return 0
  if printf '%s\n' "$bid" > "$WATERMARK_FILE.tmp.$$" 2>/dev/null; then
    mv -f "$WATERMARK_FILE.tmp.$$" "$WATERMARK_FILE" 2>/dev/null
  fi
  rm -f "$WATERMARK_FILE.tmp.$$" 2>/dev/null
  return 0
}

# ── Detection (sets globals; both subcommands share it) ─────────────────────

_DET_STATUS="" _DET_LINE="" _DET_HEX="" _DET_CAUSE="" _DET_WHY=""
_DET_HITS=0 _DET_TOTAL=0 _DET_PREV="" _DET_ROWS=""
# Walk-mode extras: the boot that LOGGED the reported fault's decode line, the
# full unprocessed-fault list ("<crashed>|<detecting>|<line>" per line), and the
# newest enumerated boot (watermark target). All empty in KLOG_FILE legacy mode.
_DET_DETBOOT="" _DET_FAULTS="" _DET_LAST_ROW_BID=""

_streak() { # fills _DET_HITS/_DET_TOTAL/_DET_ROWS over the last $WINDOW boots
  # _DET_HITS counts FAULT-class boots only; a planned reboot is recorded in the
  # table as "reboot" so the history stays readable without inflating the count.
  local idx bid rest row hit line
  _DET_HITS=0 _DET_TOTAL=0 _DET_ROWS=""
  while read -r row; do
    [[ -n "$row" ]] || continue
    idx="$(awk '{print $1}' <<< "$row")"
    bid="$(awk '{print $2}' <<< "$row")"
    rest="$(awk '{$1=""; $2=""; sub(/^ +/, ""); print}' <<< "$row")"
    _DET_TOTAL=$(( _DET_TOTAL + 1 ))
    line="$(_boot_reset_line "$bid")"
    if [[ -z "$line" ]]; then
      hit="no"
    elif _is_benign "$line"; then
      hit="reboot"
    else
      hit="**FAULT**"; _DET_HITS=$(( _DET_HITS + 1 ))
    fi
    _DET_ROWS+="$hit|$idx|$bid|$rest"$'\n'
  done < <(_boot_rows | tail -n "$WINDOW")
  return 0
}

_parse_fault_line() { # $1 decode line → _DET_HEX/_DET_CAUSE
  _DET_HEX="$(sed -n 's/.*reset reason \[\([^]]*\)\].*/\1/p' <<< "${1:-}")"
  _DET_CAUSE="$(sed -n 's/.*reset reason \[[^]]*\]:[[:space:]]*//p' <<< "${1:-}")"
  [[ -n "$_DET_CAUSE" ]] || _DET_CAUSE="${1:-}"
}

_classify_current_line() { # register-anchored classification of _DET_LINE (legacy path)
  if [[ -z "$_DET_LINE" ]]; then
    _DET_STATUS="CLEAN"
    _DET_WHY="no reset-reason line in this boot's kernel log — the previous shutdown was orderly (or this platform exposes no reset-reason register)"
    return 0
  fi
  if _is_benign "$_DET_LINE"; then
    _DET_STATUS="CLEAN"
    _DET_WHY="previous boot ended in a software-initiated reboot, not a fault (${_DET_LINE#*: })"
    return 0
  fi
  _DET_STATUS="RESET"
  _parse_fault_line "$_DET_LINE"
  _streak
  _DET_PREV="$(_prev_boot_id)"
  return 0
}

_detect() {
  _DET_STATUS="" _DET_LINE="" _DET_HEX="" _DET_CAUSE="" _DET_WHY=""
  _DET_PREV="" _DET_DETBOOT="" _DET_FAULTS="" _DET_LAST_ROW_BID=""
  local n=0

  # Seam: a single stand-in for the CURRENT boot's kernel log keeps the original
  # register-anchored behavior — and never touches the watermark.
  if [[ -n "${HOST_GUARD_RESET_KLOG_FILE:-}" ]]; then
    if [[ ! -r "$HOST_GUARD_RESET_KLOG_FILE" ]]; then
      _DET_STATUS="UNKNOWN"
      _DET_WHY="HOST_GUARD_RESET_KLOG_FILE=$HOST_GUARD_RESET_KLOG_FILE is not readable"
      return 0
    fi
    _DET_LINE="$(grep -i -m1 "$RESET_PAT" "$HOST_GUARD_RESET_KLOG_FILE" 2>/dev/null)"
    _classify_current_line
    return 0
  fi

  if [[ -z "${HOST_GUARD_RESET_KLOG_DIR:-}" ]]; then
    if command -v journalctl >/dev/null 2>&1; then
      # Liveness probe first: journalctl can exist and still return nothing when
      # this user cannot read the kernel log. Without the probe, "no permission"
      # and "no reset line" would both look CLEAN — the exact false negative this
      # whole script exists to prevent.
      if [[ -z "$(journalctl -k -b 0 --no-pager -n 1 2>/dev/null)" ]]; then
        _DET_STATUS="UNKNOWN"
        _DET_WHY="journalctl returned no kernel log for this boot — this user probably cannot read it; fix with: sudo usermod -aG systemd-journal \$USER (then log out and back in)"
        return 0
      fi
    elif [[ -r /var/log/kern.log ]]; then
      # kern.log carries history but cannot be scoped to THIS boot, so a hit here
      # is not evidence that the LAST boot died. Report honestly, never guess.
      n="$(grep -c -i "$RESET_PAT" /var/log/kern.log 2>/dev/null)"
      [[ "$n" =~ ^[0-9]+$ ]] || n=0
      _DET_STATUS="UNKNOWN"
      _DET_WHY="journalctl is unavailable; /var/log/kern.log carries $n reset-reason line(s) but cannot be scoped to the current boot — install systemd-journal access for an authoritative read"
      return 0
    else
      _DET_STATUS="UNKNOWN"
      _DET_WHY="no readable kernel log (no journalctl, no /var/log/kern.log) — the platform reset-reason register cannot be read on this host"
      return 0
    fi
  fi

  # Boot-walk: examine every boot newer than the watermark (bounded to the last
  # $WINDOW boots when no watermark is usable) for a non-benign decode line.
  # A decode line in boot N is evidence that boot N-1 died — including decode
  # lines that landed in an intermediate boot the operator later shut down
  # cleanly, the case the old boot-0-only read was blind to.
  local rows
  rows="$(_boot_rows)"
  if [[ -z "$rows" ]]; then
    # No boot enumeration — degrade to the original single-boot read.
    _DET_LINE="$(journalctl -k -b 0 --no-pager 2>/dev/null | grep -i -m1 "$RESET_PAT")"
    _classify_current_line
    return 0
  fi

  local total wm seen_wm=0 idx0=0 inset row bid prevbid="" line
  total="$(awk 'END{print NR}' <<< "$rows")"
  wm="$(_wm_read)"
  if [[ -n "$wm" ]] && ! awk '{print $2}' <<< "$rows" | grep -qx "$wm"; then
    wm=""  # watermark rotated out of journal retention — fall back to the window bound
  fi
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    idx0=$(( idx0 + 1 ))
    bid="$(awk '{print $2}' <<< "$row")"
    if [[ -n "$wm" ]]; then
      inset=$seen_wm                       # only boots AFTER the watermark boot
      [[ "$bid" == "$wm" ]] && seen_wm=1
    else
      inset=$(( idx0 > total - WINDOW ? 1 : 0 ))
    fi
    if (( inset )); then
      line="$(_boot_reset_line "$bid")"
      if [[ -n "$line" ]] && ! _is_benign "$line"; then
        _DET_FAULTS+="${prevbid:-unknown}|$bid|$line"$'\n'
      fi
    fi
    prevbid="$bid"
  done <<< "$rows"
  _DET_LAST_ROW_BID="$prevbid"

  if [[ -z "$_DET_FAULTS" ]]; then
    _DET_STATUS="CLEAN"
    line="$(_boot_reset_line "$prevbid")"
    if [[ -n "$line" ]] && _is_benign "$line"; then
      _DET_WHY="previous boot ended in a software-initiated reboot, not a fault (${line#*: })"
    else
      _DET_WHY="no unprocessed fault reset in the examined boot history${wm:+ (watermark $wm)}"
    fi
    return 0
  fi

  # Report the NEWEST unprocessed fault; ensure-postmortem bundles every one.
  # printf, not a herestring: _DET_FAULTS already ends in \n and <<< would add
  # a second, making tail -n 1 return the empty line.
  local newest rest
  newest="$(printf '%s' "$_DET_FAULTS" | tail -n 1)"
  _DET_PREV="${newest%%|*}"
  rest="${newest#*|}"
  _DET_DETBOOT="${rest%%|*}"
  _DET_LINE="${rest#*|}"
  _DET_STATUS="RESET"
  _parse_fault_line "$_DET_LINE"
  _streak
  return 0
}

# ── Bundle rendering ────────────────────────────────────────────────────────

_STALE_ROOTS=""   # newline-separated project roots seen in stale records
_STALE_SESSIONS="" # newline-separated "<root>|<sid>" for stale ENGINE records

_render_records() { # section 3 — and harvest roots/sessions for 4 and 5
  local dir cur r bid kind root sid
  dir="$(hg_registry_dir)"
  cur="$(_hg_boot_id)"
  _STALE_ROOTS="" _STALE_SESSIONS=""
  local found=0
  for r in "$dir"/*.rec; do
    [[ -e "$r" ]] || continue
    bid="$(_hg_rec_field "$r" boot_id)"
    # Records from the CURRENT boot belong to something running right now —
    # they are not evidence about the boot that died.
    [[ "$bid" != "$cur" ]] || continue
    found=$(( found + 1 ))
    kind="$(_hg_rec_field "$r" kind)"
    root="$(_hg_rec_field "$r" project_root)"
    sid="$(_hg_rec_field "$r" session_id)"
    printf '### %s\n\n' "$(basename "$r")"
    printf '```\n'
    cat "$r" 2>/dev/null
    printf '```\n\n'
    [[ -z "$root" ]] || _STALE_ROOTS+="$root"$'\n'
    if [[ "$kind" == "engine" && -n "$root" && -n "$sid" ]]; then
      _STALE_SESSIONS+="$root|$sid"$'\n'
    fi
  done
  if (( found == 0 )); then
    printf 'No registry records from a previous boot survive in `%s`.\n' "$dir"
    printf 'Either nothing was running, or an engine preflight already swept them\n'
    printf '(the sweep is boot-id keyed — run this script BEFORE resuming a session).\n\n'
  fi
  _STALE_ROOTS="$(printf '%s' "$_STALE_ROOTS" | sort -u)"
  _STALE_SESSIONS="$(printf '%s' "$_STALE_SESSIONS" | sort -u)"
  return 0
}

_render_csv_tail() { # $1 csv path, $2 label, $3 upper-bound epoch — samples PRECEDING the detecting boot
  local csv="$1" label="$2" bt="${3:-}" rows last mt
  [[ -f "$csv" ]] || return 0
  [[ -n "$bt" ]] || bt="$(hg_boot_epoch)"
  # Boot-relative, never a plain tail: a sampler that restarted after the reboot
  # keeps appending, and tailing it would label live idle data "time of death".
  # For a late-detected fault the bound is the DETECTING boot's first entry, so
  # samples from intermediate boots never masquerade as the dying breath.
  rows="$(awk -F, -v b="$bt" '$1 ~ /^[0-9]+$/ && $1 + 0 < b' "$csv" 2>/dev/null | tail -n 20)"
  printf '### %s\n\n' "$label"
  printf -- '- file: `%s`\n' "$csv"
  if [[ -z "$rows" ]]; then
    mt="$(date -d "@$(stat -c %Y "$csv" 2>/dev/null || echo 0)" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)"
    printf -- '- no samples from before this boot survive here (rotated away, or this sampler only started after the reboot). Last written %s.\n\n' "${mt:-unknown}"
    return 0
  fi
  last="$(tail -n 1 <<< "$rows" | cut -d, -f1)"
  printf -- '- **final sample before the reset: %s** — the closest thing to a time of death\n\n' \
    "$(date -d "@$last" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "epoch $last")"
  printf '```\n%s\n```\n\n' "$rows"
  return 0
}

_render() {
  local now before=""
  now="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  # Telemetry upper bound: the first entry of the boot that logged the decode
  # line. Empty (→ current btime) in legacy mode or when the row is unparsable.
  [[ -z "${_DET_DETBOOT:-}" ]] || before="$(_boot_first_epoch "$_DET_DETBOOT")"

  printf '# Machine reset postmortem — boot %s\n\n' "${_DET_PREV:-unknown}"
  printf 'Generated %s by `scripts/automation/host-guard/reset-forensics.sh`.\n\n' "$now"
  printf 'Boot `%s` did not shut down. The platform reset-reason register says\n' "${_DET_PREV:-unknown}"
  printf 'the HARDWARE asserted reset, so the kernel was never notified and no software\n'
  printf 'guard — CPU mask, memory ceiling, browser confinement — could have prevented\n'
  printf 'it. Remediation is firmware/hardware: see `docs/host-guard.md` §\n'
  printf 'After a hardware reset — root-cause runbook.\n\n'

  printf '## 1. Reset reason (the platform, verbatim)\n\n```\n%s\n```\n\n' "$_DET_LINE"
  printf -- '- code: `%s`\n' "${_DET_HEX:-unknown}"
  printf -- '- cause: %s\n' "${_DET_CAUSE:-unknown}"
  printf -- '- hardware-fault resets among the last %s boots: **%s** (planned reboots excluded)\n\n' "$_DET_TOTAL" "$_DET_HITS"

  printf '## 2. Recent boot history\n\n'
  if [[ -n "$_DET_ROWS" ]]; then
    printf '| verdict | idx | boot id | first → last entry |\n|---|---|---|---|\n'
    local hit idx bid rest
    while IFS='|' read -r hit idx bid rest; do
      [[ -n "$idx" ]] || continue
      printf '| %s | %s | `%s` | %s |\n' "$hit" "$idx" "$bid" "$rest"
    done <<< "$_DET_ROWS"
    printf '\n'
  else
    printf 'Boot history unavailable (`journalctl --list-boots` returned nothing).\n\n'
  fi

  printf '## 3. What was running (registry records from the dead boot)\n\n'
  _render_records

  printf '## 4. Hardware telemetry, final seconds (1 Hz, fsync per line)\n\n'
  _render_csv_tail "$GLOBAL_HWMON" "machine-global sampler" "$before"
  local root
  while read -r root; do
    [[ -n "$root" ]] || continue
    _render_csv_tail "$root/logs/hwmon/hwmon.csv" "$(basename "$root")" "$before"
    [[ -f "$root/logs/hwmon/hwmon.csv" ]] || _render_csv_tail "$root/logs/hwmon/hwmon.csv.1" "$(basename "$root") (rotated)" "$before"
  done <<< "$_STALE_ROOTS"
  printf 'Columns: `%s`\n\n' "epoch,tctl_c,gpu_edge_c,ppt_w,ppt_avg_w,nvme_c,dimm0_c,dimm1_c,acpitz_c,load1,mem_avail_mb,swap_free_mb,psi_cpu_avg10,psi_mem_avg10[,cpu_mhz]"

  printf '## 5. Session artifacts at the moment of death\n\n'
  local sid sdir
  while IFS='|' read -r root sid; do
    [[ -n "$root" && -n "$sid" ]] || continue
    sdir="$root/runs/goal-session-$sid"
    printf '### %s — session `%s`\n\n' "$(basename "$root")" "$sid"
    if [[ -f "$sdir/telemetry.jsonl" ]]; then
      printf 'telemetry.jsonl (last 20):\n\n```\n'
      tail -n 20 "$sdir/telemetry.jsonl" 2>/dev/null
      printf '```\n\n'
    fi
    if [[ -f "$sdir/engine.log" ]]; then
      printf 'engine.log (last 40):\n\n```\n'
      tail -n 40 "$sdir/engine.log" 2>/dev/null
      printf '```\n\n'
    fi
    if [[ -f "$sdir/session.json" ]]; then
      printf 'session.json:\n\n```json\n'
      cat "$sdir/session.json" 2>/dev/null
      printf '```\n\n'
    fi
  done <<< "$_STALE_SESSIONS"
  [[ -n "$_STALE_SESSIONS" ]] || printf 'No engine session could be identified from the surviving records.\n\n'

  printf '## 6. Machine-wide chain event ledger (previous boot)\n\n'
  if [[ -f "$EVENTS_FILE" ]]; then
    printf 'Last 40 events not belonging to the current boot — `%s`:\n\n```\n' "$EVENTS_FILE"
    grep -v "$(_hg_boot_id)" "$EVENTS_FILE" 2>/dev/null | tail -n 40
    printf '```\n\n'
  else
    printf 'No event ledger at `%s` yet (written by hg_event once a guarded engine runs).\n\n' "$EVENTS_FILE"
  fi

  printf '## 6b. Host mitigations — which experiment was running?\n\n'
  printf 'Read NOW (the boot after the reset), so PERSISTED settings are accurate and a\n'
  printf 'runtime-only change has already reverted. For what was truly in force during the\n'
  printf 'run, use the `host_state` event in §6 — the engine records it at start.\n\n'
  if declare -f hg_host_mitigations >/dev/null 2>&1; then
    printf '```json\n%s\n```\n\n' "$(hg_host_mitigations)"
  fi
  local hostenv
  hostenv="${HOST_GUARD_HOST_ENV_FILE:-$HOME/.config/iad/host-guard-host.env}"
  if [[ -f "$hostenv" ]]; then
    printf 'Machine budget (`%s`):\n\n```\n' "$hostenv"
    grep -vE '^\s*#|^\s*$' "$hostenv" 2>/dev/null
    printf '```\n\n'
  fi

  printf '## 7. Journal tail of the dead boot\n\n'
  printf 'NOTE: a quiet system can log NOTHING for many minutes before a hard reset\n'
  printf '(and journald may also sync lazily) — trust §4 for the time of death.\n\n```\n'
  if [[ -n "${HOST_GUARD_RESET_JOURNAL_TAIL_FILE:-}" ]]; then
    tail -n 80 "$HOST_GUARD_RESET_JOURNAL_TAIL_FILE" 2>/dev/null
  elif command -v journalctl >/dev/null 2>&1; then
    if [[ -n "${_DET_PREV:-}" && "$_DET_PREV" != "unknown" ]]; then
      journalctl -b "$_DET_PREV" -n 80 --no-pager 2>/dev/null
    else
      journalctl -b -1 -n 80 --no-pager 2>/dev/null
    fi
  fi
  printf '```\n\n'

  printf '## Next steps\n\n'
  printf '1. Run the root-cause runbook in `docs/host-guard.md` (journald sync interval,\n'
  printf '   rasdaemon, pstore, BIOS version, overnight memtest).\n'
  printf '2. Change ONE hardware variable per soak week so causality stays readable.\n'
  printf '3. Acceptance: seven consecutive days with `doctor.sh --only reset-reason`\n'
  printf '   reporting CLEAN on every boot.\n'
  return 0
}

_link_latest() {
  local target="$1"
  ln -sfn "$(basename "$target")" "$POSTMORTEM_DIR/latest.md" 2>/dev/null || true
}

# ── Subcommands ─────────────────────────────────────────────────────────────

cmd_check() {
  _detect
  case "$_DET_STATUS" in
    RESET) printf 'RESET|%s|%s|%s/%s|%s\n' "${_DET_HEX:-unknown}" "$_DET_CAUSE" \
             "$_DET_HITS" "$_DET_TOTAL" "${_DET_PREV:-unknown}" ;;
    CLEAN) printf 'CLEAN|%s\n' "$_DET_WHY" ;;
    *)     printf 'UNKNOWN|%s\n' "$_DET_WHY" ;;
  esac
  return 0
}

cmd_ensure_postmortem() {
  _detect
  case "$_DET_STATUS" in
    CLEAN)
      # Walk mode examined every boot in range and found nothing unprocessed —
      # advance the watermark so the next run only pays for boots it has not
      # seen. Legacy KLOG_FILE mode sets no _DET_LAST_ROW_BID and never writes.
      [[ -z "${_DET_LAST_ROW_BID:-}" ]] || _wm_write "$_DET_LAST_ROW_BID"
      printf 'NONE|%s\n' "$_DET_WHY"; return 0 ;;
    RESET) ;;
    *)     printf 'UNKNOWN|%s\n' "$_DET_WHY"; return 0 ;;
  esac

  mkdir -p "$POSTMORTEM_DIR" 2>/dev/null \
    || { printf 'UNKNOWN|cannot create postmortem dir %s\n' "$POSTMORTEM_DIR"; return 0; }

  # One bundle PER unprocessed fault — a detection gap can span several resets
  # (2026-08-10 had two in one day). Legacy mode carries exactly one fault, the
  # current register, synthesized into the same record shape. Oldest first so
  # latest.md ends on the newest bundle; the one-line output contract reports
  # the newest fault's bundle.
  local faults="${_DET_FAULTS:-}"
  [[ -n "$faults" ]] || faults="${_DET_PREV:-unknown}|$(_hg_boot_id)|$_DET_LINE"$'\n'
  local rec rest name out tmp result="" failed=0
  while IFS= read -r rec; do
    [[ -n "$rec" ]] || continue
    _DET_PREV="${rec%%|*}"
    rest="${rec#*|}"
    _DET_DETBOOT="${rest%%|*}"
    _DET_LINE="${rest#*|}"
    _parse_fault_line "$_DET_LINE"
    name="$_DET_PREV"
    [[ -n "$name" && "$name" != "unknown" ]] || name="prev-of-$_DET_DETBOOT"
    out="$POSTMORTEM_DIR/$name.md"
    if [[ -f "$out" ]]; then
      _link_latest "$out"
      result="POSTMORTEM|$out|existing"
      continue
    fi
    tmp="$out.tmp.$$"
    _render > "$tmp" 2>/dev/null
    if mv -f "$tmp" "$out" 2>/dev/null; then
      _link_latest "$out"
      result="POSTMORTEM|$out|new"
    else
      rm -f "$tmp" 2>/dev/null || true
      failed=1
      result="UNKNOWN|cannot write $out"
    fi
  done <<< "$faults"

  # The watermark advances only when every bundle in the gap is on disk — a
  # write failure must leave the fault visible to the next run.
  if (( ! failed )) && [[ -n "${_DET_FAULTS:-}" && -n "${_DET_LAST_ROW_BID:-}" ]]; then
    _wm_write "$_DET_LAST_ROW_BID"
  fi
  printf '%s\n' "${result:-UNKNOWN|no bundle produced}"
  return 0
}

cmd_streak() { # fault-boot count over the last $WINDOW boots, verdict-independent
  # For consumers (doctor's ras-logging row) that need "has this host EVER
  # faulted recently", which the watermark-consuming check can no longer answer
  # once the bundles are frozen.
  _streak
  if (( _DET_TOTAL == 0 )); then
    printf 'UNKNOWN|no boot history available\n'
  else
    printf 'STREAK|%s/%s\n' "$_DET_HITS" "$_DET_TOTAL"
  fi
  return 0
}

cmd_report() {
  local newest=""
  if [[ -f "$POSTMORTEM_DIR/latest.md" ]]; then
    newest="$POSTMORTEM_DIR/latest.md"
  else
    newest="$(ls -1t "$POSTMORTEM_DIR"/*.md 2>/dev/null | head -n 1)"
  fi
  [[ -n "$newest" && -f "$newest" ]] || { echo "no postmortem bundle in $POSTMORTEM_DIR" >&2; return 1; }
  cat "$newest"
}

case "${1:-}" in
  check)             cmd_check ;;
  ensure-postmortem) cmd_ensure_postmortem ;;
  streak)            cmd_streak ;;
  report)            cmd_report ;;
  *) echo "Usage: $0 {check|ensure-postmortem|streak|report}" >&2; exit 2 ;;
esac
