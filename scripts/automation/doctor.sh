#!/usr/bin/env bash
# doctor.sh — REL-2 preflight doctor: one PASS/WARN/FAIL row per environment
# check, a machine-greppable summary line, and NO gating by default.
#
# Sessions die mid-iteration on environment problems that were knowable at
# start (missing playwright, dead Chrome MCP, unauthenticated gh, low disk,
# stale pump). This prints the session-START environment truth. It is
# ADVISORY BY CONSTRUCTION: exit code is 0 regardless of findings unless
# --strict-doctor is passed (then exit 1 iff >=1 FAIL row). The engine calls
# it warn-only (run_doctor_preflight in run-goal.sh, CHAIN_DOCTOR=true
# default) — a broken doctor must never be able to stop a session.
#
# Boundary: this is session-start truth. The dispatch-time services/fixture
# gate is a SEPARATE staged item (CAND-BQA-PREFLIGHT, roadmap §16) — do not
# grow that gate here.
#
# Usage:
#   doctor.sh                  full table, exit 0
#   doctor.sh --list           print the check keys, one per line
#   doctor.sh --only <check>   run exactly one check (key from --list)
#   doctor.sh --strict-doctor  exit 1 when any row FAILs (CLI-only; the
#                              engine never passes this)
#
# Design rules:
#   - stdlib/bash + python3 only; zero model calls, zero spend.
#   - Checks OBSERVE; the single sanctioned write is the tmp-health probe,
#     inside the tmp root, cleaned up.
#   - Network probes are timeout-bounded and degrade to WARN, never hang.
#   - Each check is a function named after its --only key (dashes->underscores,
#     check_ prefix) and emits exactly one "STATUS|detail" line on stdout; the
#     wrapper turns a crashed/garbled check into a FAIL row, so one broken
#     probe can never abort the table (set -e is deliberately absent).
#
# Injection seams (how tests fake the world — no root, no system mutation):
#   PATH                       tool discovery (symlink farm +/- shims)
#   CHAIN_DOCTOR_REPO_ROOT     repo root override (runs/, .claude/ live here)
#   HOME                       plugin cache (~/.claude/plugins/cache) + defaults
#   CHAIN_TMP_ROOT             tmp root for tmp-health/disk (REL-13 default
#                              ~/.cache/iad)
#   CHAIN_PUMP_HEARTBEAT_TIMEOUT  pump pickup-staleness seconds (engine's own
#                              Tier A knob, lib/interactive-dispatch.sh)
#   CHAIN_DOCTOR_AMBIENT       engine-provided space-separated ambient CHAIN_*
#                              names (set-but-empty means "clean at start";
#                              unset means standalone -> compute from live env)
#   PLAYWRIGHT_BROWSERS_PATH   playwright browser cache dir
#   PYTHONPATH                 playwright import path

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# check_git_push_access (the engine's own ls-remote semantics) + chain-tmp
# helpers (_chain_tmp_free_mb) come from common.sh; engine_lock_classify (the
# SAME staleness verdict the engines acquire with) from engine-lock.sh.
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/engine-lock.sh
source "$SCRIPT_DIR/lib/engine-lock.sh"
ROOT="${CHAIN_DOCTOR_REPO_ROOT:-$REPO_ROOT}"

CHECKS=(python3 node playwright chrome-mcp gh-auth git-remote disk timeout jq
        pump-heartbeat engine-lock tmp-health chrome-exclusive mcp-affinity
        host-guard cpu-boost reset-reason ras-logging ambient-env)

# Run a command under GNU/uutils timeout when available (network probes must
# degrade, never hang). $1 = seconds, rest = command.
_bounded() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    "$@"
  fi
}

# ── Checks ──────────────────────────────────────────────────────────────────

# Engine floor: run-goal.sh uses datetime.UTC (python >= 3.11). The project
# template's stack section is per-project; this checks what the ENGINE needs.
check_python3() {
  command -v python3 >/dev/null 2>&1 || { echo "FAIL|python3 not found — the engine cannot run at all"; return; }
  local v
  v="$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null)" \
    || { echo "FAIL|python3 present but broken (cannot report a version)"; return; }
  if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    echo "PASS|$v (>= 3.11 engine floor)"
  else
    echo "FAIL|$v < 3.11 — run-goal.sh needs datetime.UTC (3.11+)"
  fi
}

check_node() {
  command -v node >/dev/null 2>&1 \
    && echo "PASS|$(node --version 2>/dev/null | head -n1)" \
    || echo "WARN|node not found — engine core runs without it, but product stacks usually need it"
}

check_playwright() {
  command -v python3 >/dev/null 2>&1 || { echo "WARN|python3 missing — cannot probe (see python3 row)"; return; }
  local ver
  ver="$(python3 -c 'import playwright
try:
    from importlib.metadata import version
    print(version("playwright"))
except Exception:
    print(getattr(playwright, "__version__", "?"))' 2>/dev/null)" \
    || { echo "FAIL|python3 cannot import playwright — pip install playwright && python3 -m playwright install chromium"; return; }
  local bp="${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}" match=""
  local d
  for d in "$bp"/chromium*; do [[ -d "$d" ]] && { match="$d"; break; }; done
  if [[ -n "$match" ]]; then
    echo "PASS|import ok ($ver); chromium at $match"
  else
    echo "FAIL|import ok ($ver) but no chromium under $bp — python3 -m playwright install chromium"
  fi
}

# Goal mode REQUIRES Chrome MCP (browser-qa-agent drives
# mcp__plugin_..._chrome__use_browser) — so absence is FAIL, not WARN.
# Detection is config-file truth (zero dispatch spend): the project settings
# that dispatched agents actually inherit, then generic MCP server configs.
check_chrome_mcp() {
  command -v python3 >/dev/null 2>&1 || { echo "WARN|python3 missing — cannot parse MCP/plugin settings"; return; }
  _DOC_ROOT="$ROOT" _DOC_HOME="$HOME" python3 - <<'PY'
import json, os
root, home = os.environ["_DOC_ROOT"], os.environ["_DOC_HOME"]

def load(p):
    try:
        with open(p) as f: return json.load(f)
    except Exception: return None

evidence, problems = [], []
for rel in (".claude/settings.json", ".claude/settings.local.json"):
    p = os.path.join(root, rel)
    d = load(p)
    if not d: continue
    for key, on in (d.get("enabledPlugins") or {}).items():
        if on and "chrome" in key.lower():
            name, _, market = key.partition("@")
            cache = os.path.join(home, ".claude", "plugins", "cache", market or "", name)
            if os.path.isdir(cache):
                evidence.append(f"plugin {key} enabled ({rel}) + installed ({cache})")
            else:
                problems.append(f"plugin {key} enabled ({rel}) but NOT in plugin cache ({cache})")
    allows = ((d.get("permissions") or {}).get("allow")) or []
    hits = [a for a in allows if a.startswith("mcp__") and "chrome" in a.lower()]
    if hits and evidence:
        evidence.append(f"allow {hits[0]} ({rel})")
for p, label in ((os.path.join(root, ".mcp.json"), ".mcp.json"),
                 (os.path.join(home, ".claude.json"), "~/.claude.json")):
    d = load(p)
    if not d: continue
    for name in (d.get("mcpServers") or {}):
        if "chrome" in name.lower():
            evidence.append(f"mcpServers.{name} ({label})")

if evidence:
    print("PASS|" + "; ".join(evidence[:2]))
elif problems:
    print("FAIL|" + problems[0] + " — REQUIRED for goal-mode browser QA")
else:
    print("FAIL|no Chrome MCP found (checked .claude/settings.json enabledPlugins/allow, "
          ".claude/settings.local.json, .mcp.json, ~/.claude.json) — REQUIRED for goal-mode browser QA")
PY
}

check_gh_auth() {
  command -v gh >/dev/null 2>&1 || { echo "WARN|gh not installed — PR/release flows degrade (push preflight is the git-remote row)"; return; }
  local rc=0
  _bounded 8 gh auth status >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0)   echo "PASS|gh auth status: authenticated" ;;
    124) echo "WARN|gh auth status timed out (8s) — network?" ;;
    *)   echo "WARN|gh auth status failed (rc $rc) — release-manager/PR flows will fail until 'gh auth login'" ;;
  esac
}

# Mirrors the engine's GitHub preflight EXACTLY by calling the same
# check_git_push_access (lib/common.sh): ls-remote over git's real credential
# path, prompt-proof, 20s-bounded.
check_git_remote() {
  local rc=0
  check_git_push_access "$ROOT" || rc=$?
  case "$rc" in
    0)   echo "PASS|origin ls-remote ok (same auth path the engine preflights)" ;;
    2)   echo "WARN|no 'origin' remote — fine locally; push-per-iter sessions would pause AWAITING_GITHUB_AUTH" ;;
    124) echo "WARN|origin ls-remote timed out — network?" ;;
    *)   echo "FAIL|origin unreachable/unauthenticated (rc $rc) — a pushing session pauses AWAITING_GITHUB_AUTH at start" ;;
  esac
}

# Same thresholds as the engine's REL-13 disk guard (soft 2048MB / hard 512MB,
# CHAIN_TMP_MIN_FREE_MB / CHAIN_TMP_HARD_MIN_FREE_MB) — but OBSERVE-only: the
# guard sweeps/pauses, the doctor just reports. Headroom covers a session's
# artifacts on the repo fs plus scratch on the tmp root fs.
check_disk() {
  local base="${CHAIN_TMP_ROOT:-$HOME/.cache/iad}"
  local soft="${CHAIN_TMP_MIN_FREE_MB:-2048}" hard="${CHAIN_TMP_HARD_MIN_FREE_MB:-512}"
  [[ "$soft" =~ ^[0-9]+$ ]] || soft=2048
  [[ "$hard" =~ ^[0-9]+$ ]] || hard=512
  local free_tmp="" free_repo=""
  if declare -F _chain_tmp_free_mb >/dev/null 2>&1; then
    free_tmp="$(_chain_tmp_free_mb "$base" 2>/dev/null || true)"
    free_repo="$(_chain_tmp_free_mb "$ROOT" 2>/dev/null || true)"
  fi
  [[ -n "$free_tmp" ]]  || free_tmp="$(df -Pm "$base" 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ -n "$free_repo" ]] || free_repo="$(df -Pm "$ROOT" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ ! "$free_tmp" =~ ^[0-9]+$ || ! "$free_repo" =~ ^[0-9]+$ ]]; then
    echo "WARN|cannot determine free space (tmp root '$base': '${free_tmp:-?}', repo: '${free_repo:-?}')"
    return
  fi
  local min="$free_tmp"; [[ "$free_repo" -lt "$min" ]] && min="$free_repo"
  local detail="tmp root $base: ${free_tmp}MB free; repo fs: ${free_repo}MB free (soft ${soft}/hard ${hard})"
  if   [[ "$min" -lt "$hard" ]]; then echo "FAIL|$detail — under the engine's hard floor"
  elif [[ "$min" -lt "$soft" ]]; then echo "WARN|$detail — under the soft threshold; the engine will sweep aggressively"
  else echo "PASS|$detail"
  fi
}

check_timeout() {
  command -v timeout >/dev/null 2>&1 \
    || { echo "FAIL|timeout not found — dispatch runtime caps and prompt-proof preflights depend on it"; return; }
  local v
  v="$(timeout --version 2>/dev/null | head -n1)"
  if [[ "$v" == *"GNU coreutils"* ]]; then
    echo "PASS|$v"
  else
    echo "WARN|timeout present but not GNU (${v:-unknown vendor}) — flag semantics may differ"
  fi
}

check_jq() {
  command -v jq >/dev/null 2>&1 \
    && echo "PASS|$(jq --version 2>&1 | head -n1)" \
    || echo "FAIL|jq not found — telemetry/dispatch/gates use it (python3 fallbacks are partial)"
}

# Real heartbeat protocol (lib/interactive-dispatch.sh Tier A): an alive idle
# pump touches <session>/dispatch/.pump-alive every ~1s; a request is the
# atomically-published req.*.ready, serviced when its .res appears, claimed
# when its .started appears. Only "unclaimed request + heartbeat older than
# CHAIN_PUMP_HEARTBEAT_TIMEOUT (or no heartbeat at all)" means a wedged
# channel — that is exactly when the engine's Tier A would abort the dispatch.
check_pump_heartbeat() {
  local hbto="${CHAIN_PUMP_HEARTBEAT_TIMEOUT:-1800}" now dir sid hb age
  [[ "$hbto" =~ ^[0-9]+$ ]] || hbto=1800
  now="$(date +%s)"
  local channels=0 bad="" fresh="" ident=""
  for dir in "$ROOT"/runs/goal-session-*/dispatch; do
    [[ -d "$dir" ]] || continue
    channels=$((channels + 1))
    sid="$(basename "$(dirname "$dir")")"; sid="${sid#goal-session-}"
    local pending=0 f base
    for f in "$dir"/req.*.ready; do
      [[ -e "$f" ]] || continue
      base="${f%.ready}"
      [[ -f "$base.res" || -f "$base.started" ]] || pending=$((pending + 1))
    done
    hb="$dir/.pump-alive"
    if [[ -f "$hb" ]]; then
      age=$(( now - $(stat -c %Y "$hb" 2>/dev/null || echo "$now") ))
    else
      age=-1
    fi
    if [[ "$pending" -gt 0 ]]; then
      if [[ "$age" -lt 0 ]]; then
        bad="$bad $sid($pending waiting, no pump heartbeat)"
      elif [[ "$age" -gt "$hbto" ]]; then
        bad="$bad $sid($pending waiting, heartbeat ${age}s > ${hbto}s)"
      fi
    fi
    if [[ "$age" -ge 0 && "$age" -le "$hbto" ]]; then
      # REL-3 (protocol v3): a heartbeat may carry the pump ident — surface it.
      ident="$(sed -n 's/^pid=//p' "$hb" 2>/dev/null | head -n1 | tr -dc 0-9)"
      fresh="$fresh $sid(${age}s${ident:+, pump pid $ident})"
    fi
  done
  if [[ -n "$bad" ]]; then
    echo "WARN|wedged channel(s):${bad} — dispatches will time out; resume the pump (/goal) or clean the channel"
  elif [[ "$channels" -eq 0 ]]; then
    echo "PASS|no interactive pump channels under runs/"
  elif [[ -n "$fresh" ]]; then
    echo "PASS|$channels channel(s); live pump heartbeat:${fresh}; no unserviced requests"
  else
    echo "PASS|$channels channel(s), none with unserviced requests"
  fi
}

# REL-4 cross-session lock, live protocol: goal sessions hold
# runs/goal-session-<sid>/.engine.lock, the phase runner holds the repo-level
# runs/.phase.lock. Verdicts come from the SAME engine_lock_classify the
# engines acquire with (lib/engine-lock.sh) — no second staleness opinion.
# Absent → PASS. FRESH → WARN naming the holder: a live session is legitimate
# (this doctor may be running INSIDE it as the engine preflight). STALE →
# FAIL: a session crashed hard (SIGKILL skips the release trap); the next
# engine start replaces it automatically — docs/TROUBLESHOOTING.md
# ("Engine refuses to start — lock held") covers manual removal.
check_engine_lock() {
  local locks=() l verdict state pid host age fresh="" stale=""
  for l in "$ROOT"/runs/goal-session-*/.engine.lock "$ROOT"/runs/.phase.lock; do
    [[ -e "$l" ]] && locks+=("$l")
  done
  if [[ ${#locks[@]} -eq 0 ]]; then
    echo "PASS|no engine locks under runs/ (goal-session + phase paths checked)"
    return
  fi
  for l in "${locks[@]}"; do
    verdict="$(engine_lock_classify "$l")"
    state="${verdict%%|*}"
    pid="$(printf '%s' "$verdict" | cut -d'|' -f2)"
    host="$(printf '%s' "$verdict" | cut -d'|' -f3)"
    age="$(printf '%s' "$verdict" | cut -d'|' -f4)"
    if [[ "$state" == "STALE" ]]; then
      stale="$stale ${l#"$ROOT"/}(pid ${pid:-?})"
    else
      fresh="$fresh ${l#"$ROOT"/}(pid ${pid:-?} on ${host:-?}, age ${age:-?}s)"
    fi
  done
  if [[ -n "$stale" ]]; then
    echo "FAIL|stale lock(s):${stale} — a session crashed hard; the next engine start replaces them (manual removal: docs/TROUBLESHOOTING.md)"
  else
    echo "WARN|live engine lock(s):${fresh} — a session appears to be running this repo (legitimate if it is yours, or if this doctor runs inside it)"
  fi
}

# EVIDENCE (REL-13 / the 2026-07 EDQUOT incident): the failure mode was every
# write exiting 1 with NO output — statfs looked fine because tmpfs user
# quotas are invisible to it. So this check WRITES (1MiB + fsync) into the
# configured tmp root; that write is the doctor's only sanctioned mutation
# and is removed afterwards.
check_tmp_health() {
  local base="${CHAIN_TMP_ROOT:-$HOME/.cache/iad}"
  if ! mkdir -p "$base" 2>/dev/null || [[ ! -w "$base" ]]; then
    echo "FAIL|tmp root $base is not writable — EDQUOT/perms class; engine scratch (REL-13) lives here"
    return
  fi
  local probe="$base/.doctor-probe.$$"
  local ok=1
  if command -v python3 >/dev/null 2>&1; then
    _DOC_PROBE="$probe" python3 - <<'PY' 2>/dev/null || ok=0
import os
p = os.environ["_DOC_PROBE"]
with open(p, "wb") as f:
    f.write(b"\0" * (1 << 20))
    f.flush()
    os.fsync(f.fileno())
os.unlink(p)
PY
  else
    { dd if=/dev/zero of="$probe" bs=4096 count=256 conv=fsync >/dev/null 2>&1 && rm -f "$probe"; } || ok=0
  fi
  rm -f "$probe" 2>/dev/null
  if [[ "$ok" -eq 1 ]]; then
    echo "PASS|1MiB write+fsync ok under $base"
  else
    echo "FAIL|write probe FAILED under $base — EDQUOT/ENOSPC class (REL-13 incident: writes exit 1 with no output); try tmp-doctor.sh --aggressive"
  fi
}

# ── Host-guard rows (machine-level assumptions, read-only) ──────────────────
# The doctor OBSERVES: it reads the project host-guard.env with sed rather than
# sourcing it (never import arbitrary env), and it never sweeps the registry —
# that is the engine's job.
_hg_env_val() { # $1 key → value from the project host-guard.env ("" when absent)
  sed -n "s/^[[:space:]]*$1=//p" "$ROOT/project-extensions/host-guard/host-guard.env" 2>/dev/null \
    | tail -n 1 | tr -d '"'"'"
}
_hg_expand() { # "0-3,8-11" → CPU ids, one per line
  local part a b i
  local -a parts=()
  IFS=',' read -ra parts <<< "${1:-}"
  { for part in "${parts[@]}"; do
      if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
        a="${part%-*}"; b="${part#*-}"; (( b >= a )) && for (( i=a; i<=b; i++ )); do echo "$i"; done
      elif [[ "$part" =~ ^[0-9]+$ ]]; then echo "$part"; fi
    done; } | sort -n -u
}
_hg_in_mask() { # $1 Cpus_allowed_list ⊆ $2 mask ?
  local c; local -A super=()
  while read -r c; do [[ -n "$c" ]] && super["$c"]=1; done < <(_hg_expand "$2")
  while read -r c; do [[ -n "$c" ]] || continue; [[ -n "${super[$c]:-}" ]] || return 1; done < <(_hg_expand "$1")
  return 0
}
_hg_allowed() { awk -F'\t' '/^Cpus_allowed_list/{print $2}' "/proc/$1/status" 2>/dev/null; }
_hg_cmdline() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null; }
_hg_qa_profile_root() { echo "${CHROME_PROFILE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/superpowers/browser-profiles}"; }

# EVIDENCE (run D, bench-20260715-0924): foreign Chrome processes caused
# Chrome MCP DevTools-port contention — journeys REFUTED 0/3 and a ~$16 run
# was lost. EVIDENCE (2026-07-29 reset): a framework QA Chrome that the MCP
# reconnected to, rather than spawned, keeps whatever CPU mask it was born
# with — an unconfined headed Chrome rasterizing on every core is exactly the
# burst profile that hard-resets this class of host. So: desktop Chrome is
# informational, an unconfined framework QA Chrome is a FAIL.
check_chrome_exclusive() {
  command -v pgrep >/dev/null 2>&1 || { echo "WARN|pgrep unavailable — cannot scan for competing chrome processes"; return; }
  local pids p cmd mask enabled proot
  pids="$(pgrep 'chrom|headless_shell' 2>/dev/null || true)"
  if [[ -z "$pids" ]]; then
    echo "PASS|no competing chrome/chromium processes"
    return
  fi
  enabled="$(_hg_env_val HOST_GUARD_ENABLED)"; mask="$(_hg_env_val HOST_GUARD_CPU_LIST)"
  proot="$(_hg_qa_profile_root)"
  local n_desktop=0 n_qa=0 n_loose=0 loose=""
  for p in $pids; do
    cmd="$(_hg_cmdline "$p")"
    if [[ "$cmd" == *"$proot"* ]]; then
      n_qa=$(( n_qa + 1 ))
      if [[ "$enabled" == "1" && -n "$mask" ]] && ! _hg_in_mask "$(_hg_allowed "$p")" "$mask"; then
        n_loose=$(( n_loose + 1 )); loose+="$p($(_hg_allowed "$p")) "
      fi
    else
      n_desktop=$(( n_desktop + 1 ))
    fi
  done
  if [[ "$enabled" != "1" || -z "$mask" ]]; then
    local total=$(( n_desktop + n_qa )) list
    list="$(pgrep -l 'chrom|headless_shell' 2>/dev/null | awk 'NR<=6 {printf "%s(%s) ", $1, $2}')"
    echo "WARN|$total chrome-family process(es) ($n_qa framework QA, $n_desktop other): ${list}— DevTools-port contention lost run D (~\$16); close them before browser-QA-heavy sessions"
    return
  fi
  if (( n_loose > 0 )); then
    echo "FAIL|$n_loose framework QA chrome process(es) OUTSIDE HOST_GUARD_CPU_LIST=$mask: ${loose}— an unconfined browser can hard-reset this host; run scripts/automation/host-guard/browser-confine.sh"
    return
  fi
  echo "PASS|$n_qa framework QA chrome process(es) confined to $mask; $n_desktop other chrome process(es) (informational — QA ports are pinned)"
}

# The Chrome MCP server spawns browsers as its own children, so they inherit
# ITS affinity. A server started before the pump was confined therefore keeps
# minting unconfined browsers no matter how often the browsers get re-tasksetted.
check_mcp_affinity() {
  command -v pgrep >/dev/null 2>&1 || { echo "WARN|pgrep unavailable — cannot scan for MCP servers"; return; }
  local p cmd mask enabled n=0 loose="" n_loose=0
  enabled="$(_hg_env_val HOST_GUARD_ENABLED)"; mask="$(_hg_env_val HOST_GUARD_CPU_LIST)"
  for p in $(pgrep -f 'mcp/dist/index.js' 2>/dev/null || true); do
    cmd="$(_hg_cmdline "$p")"
    [[ "$cmd" == *superpowers-chrome* ]] || continue
    n=$(( n + 1 ))
    if [[ "$enabled" == "1" && -n "$mask" ]] && ! _hg_in_mask "$(_hg_allowed "$p")" "$mask"; then
      n_loose=$(( n_loose + 1 )); loose+="$p($(_hg_allowed "$p")) "
    fi
  done
  (( n > 0 )) || { echo "PASS|no superpowers-chrome MCP server running"; return; }
  if [[ "$enabled" != "1" || -z "$mask" ]]; then
    echo "PASS|$n superpowers-chrome MCP server(s); this project declares no CPU mask to enforce"
    return
  fi
  if (( n_loose > 0 )); then
    echo "FAIL|$n_loose superpowers-chrome MCP server(s) outside HOST_GUARD_CPU_LIST=$mask: ${loose}— every Chrome they spawn inherits that wider mask; run scripts/automation/host-guard-adopt.sh --cli-root-of <pid>"
    return
  fi
  echo "PASS|$n superpowers-chrome MCP server(s) confined to $mask"
}

# EVIDENCE (2026-07-29 14:02:45 reset): trendora "0-3,8-11" + tapeology
# "4-7,12-15" — each session's own check green, union = every core. A per-scope
# ceiling is not a machine budget; this row shows the machine view.
check_host_guard() {
  local enabled mask mem
  enabled="$(_hg_env_val HOST_GUARD_ENABLED)"; mask="$(_hg_env_val HOST_GUARD_CPU_LIST)"
  mem="$(_hg_env_val HOST_GUARD_MEMORY_HIGH)"
  [[ "$enabled" == "1" ]] || { echo "PASS|this project declares no host-guard (project-extensions/host-guard/host-guard.env absent or disabled)"; return; }
  local lib="$SCRIPT_DIR/lib/host-guard-registry.sh"
  [[ -f "$lib" ]] || { echo "WARN|host-guard.env declares CPU mask $mask but lib/host-guard-registry.sh is missing — no machine-global bound"; return; }
  # shellcheck disable=SC1090
  ( source "$lib"
    hg_load_host_env
    local hostf n=0 r roots="" verdict
    hostf="$(hg_host_env_file)"
    while read -r r; do
      [[ -n "$r" ]] || continue
      n=$(( n + 1 ))
      roots+="$(_hg_rec_field "$r" kind):$(basename "$(_hg_rec_field "$r" project_root)")[$(_hg_rec_field "$r" cpu_list)] "
    done < <(hg_live_records)
    if [[ -z "${HOST_GUARD_GLOBAL_CPU_LIST:-}" ]]; then
      echo "WARN|mask=$mask mem=$mem, $n live guarded context(s): ${roots:-none} — but NO machine budget is configured ($hostf); concurrent projects are unbounded (docs/host-guard.md § Machine-global aggregate budget)"
      return
    fi
    if ! _hg_mask_is_subset "$mask" "$HOST_GUARD_GLOBAL_CPU_LIST"; then
      echo "FAIL|this project's mask $mask is NOT inside the machine budget HOST_GUARD_GLOBAL_CPU_LIST=$HOST_GUARD_GLOBAL_CPU_LIST ($hostf) — the engine will pause AWAITING_HOST_GUARD"
      return
    fi
    verdict="$(hg_aggregate_verdict "")"
    local n_eng=0 cap
    while read -r r; do
      [[ -n "$r" ]] || continue
      [[ "$(_hg_rec_field "$r" kind)" == "engine" ]] && n_eng=$(( n_eng + 1 ))
    done < <(hg_live_records)
    cap="${HOST_GUARD_MAX_ENGINES:-}"
    [[ "$cap" =~ ^[0-9]+$ ]] || cap="unlimited"
    case "$verdict" in
      OK) echo "PASS|mask=$mask mem=$mem inside machine budget ${HOST_GUARD_GLOBAL_CPU_LIST}/${HOST_GUARD_GLOBAL_MEMORY_BUDGET:-unset}; engines=$n_eng/$cap; $n live guarded context(s): ${roots:-none}" ;;
      *)  echo "WARN|${verdict#*|}" ;;
    esac
  )
}

# EVIDENCE: boost-off was applied live on 2026-07-28 as the hardware mitigation
# and silently reverted at the next reboot — the tmpfiles.d rule that persists
# it was never installed. A guard that does not verify its own premise is
# decoration, so this row checks BOTH the live knob and its persistence.
check_cpu_boost() {
  local p rule v required=0 hostf
  p="${HOST_GUARD_SYS_BOOST_PATH:-/sys/devices/system/cpu/cpufreq/boost}"
  rule="${CHAIN_DOCTOR_BOOST_RULE:-/etc/tmpfiles.d/cpufreq-boost.conf}"
  # Only a machine that ASKED for boost-off gets a FAIL. Elsewhere the row is
  # informational — the framework must not judge hosts that never opted in.
  hostf="${HOST_GUARD_HOST_ENV_FILE:-$HOME/.config/iad/host-guard-host.env}"
  if [[ -f "$hostf" ]] && grep -qE '^[[:space:]]*HOST_GUARD_REQUIRE_BOOST_OFF[[:space:]]*=[[:space:]]*"?1' "$hostf" 2>/dev/null; then
    required=1
  fi
  [[ -r "$p" ]] || { echo "PASS|no CPU boost knob at $p — this host exposes no boost control"; return; }
  v="$(tr -dc '0-9' < "$p" 2>/dev/null)"
  if [[ "$v" != "0" ]]; then
    if (( required )); then
      echo "FAIL|CPU boost is ON ($p=$v) but $hostf requires it off — goal mode will pause AWAITING_HOST_GUARD: echo 0 | sudo tee $p (persist: $rule, docs/host-guard.md § Boost persistence)"
    else
      echo "PASS|CPU boost is ON ($p=$v); this machine does not require it off (no HOST_GUARD_REQUIRE_BOOST_OFF=1 in $hostf)"
    fi
    return
  fi
  if [[ -f "$rule" ]]; then
    echo "PASS|CPU boost off and persisted ($rule)"
  elif (( required )); then
    echo "WARN|CPU boost is off but NOT persisted — it will silently re-enable at the next reboot; install $rule (docs/host-guard.md § Boost persistence)"
  else
    echo "PASS|CPU boost is off ($p=0)"
  fi
}

# EVIDENCE (2026-07-30 17:14:08, reset #7): the machine hard-reset with EVERY
# host-guard mitigation in force — masks inside the machine budget, 10G+10G under
# a 22G budget, boost off and persisted, QA browsers confined — at 65 °C, 26 W,
# 11.5 GB free, memory PSI 0.00. The cause was never visible to any of those
# checks; it was printed by the CPU itself on the next boot:
#   x86/amd: Previous system reset reason [0x08000800]: an uncorrected error
#            caused a data fabric sync flood event
# Seven of the last ten boots carried a fault-class line. This row surfaces the
# hardware's own verdict, which no software-side check can infer.
#
# FAIL (not WARN) when the last boot died: a host that resets under load is the
# single most destructive environment fact there is — it destroys whole
# iterations. The doctor still never gates (exit 0 by construction), so FAIL here
# costs nothing but attention, which is exactly what it should cost.
#
# This row is the doctor's SECOND sanctioned write (after the tmp-health probe):
# ensure-postmortem freezes the evidence bundle. It is idempotent, lives in the
# cache root, never touches a repo — and "the operator ran doctor right after a
# crash" is precisely when the bundle must be created, because the next engine
# preflight sweeps the registry records that say who was running.
check_reset_reason() {
  local script="$SCRIPT_DIR/host-guard/reset-forensics.sh" verdict pm path
  [[ -f "$script" ]] || { echo "PASS|reset-forensics.sh not present — no reset-reason reader on this install"; return; }
  verdict="$(_bounded 20 bash "$script" check 2>/dev/null)"
  case "$verdict" in
    RESET\|*)
      local hex cause streak prev
      IFS='|' read -r _ hex cause streak prev <<< "$verdict"
      : "$prev"
      pm="$(_bounded 30 bash "$script" ensure-postmortem 2>/dev/null)"
      path="${pm#POSTMORTEM|}"; path="${path%|*}"
      [[ "$pm" == POSTMORTEM\|* ]] || path="(bundle unavailable: ${pm})"
      echo "FAIL|the previous boot ended in a HARDWARE-asserted reset: $cause ($hex); $streak recent boots. No CPU mask or memory ceiling can prevent this — postmortem: $path (docs/host-guard.md § After a hardware reset)"
      ;;
    CLEAN\|*)  echo "PASS|${verdict#CLEAN|}" ;;
    UNKNOWN\|*) echo "WARN|${verdict#UNKNOWN|}" ;;
    *)         echo "WARN|reset-forensics.sh returned an unparseable verdict: ${verdict:-<empty>}" ;;
  esac
}

# Two host-level recording facilities that only matter once a machine HAS had a
# hardware reset, and that the chain cannot install for itself (both need root):
#   - journald's default SyncIntervalSec is 5 minutes, so the 2026-07-30 reset
#     erased the final 3m42s of journal; only the 1 Hz fsync'd hwmon csv survived.
#   - rasdaemon records the memory/fabric error itself (address, DIMM), which is
#     what turns "sync flood" into an actionable RMA or BIOS bug report.
# WARN, never FAIL: these improve the NEXT postmortem, they do not make the host
# unsafe. And on a machine with no reset history the row stays PASS — a framework
# must not nag hosts that never had the incident.
check_ras_logging() {
  local script="$SCRIPT_DIR/host-guard/reset-forensics.sh" hist=0 jdir ras missing=""
  if [[ -f "$script" ]] && [[ "$(_bounded 20 bash "$script" check 2>/dev/null)" == RESET\|* ]]; then
    hist=1
  fi
  jdir="${CHAIN_DOCTOR_JOURNALD_DIR:-/etc/systemd/journald.conf.d}"
  if ! grep -rqs 'SyncIntervalSec' "$jdir" 2>/dev/null; then
    missing+="journald SyncIntervalSec drop-in ($jdir); "
  fi
  # `systemctl is-active` PRINTS its verdict and exits non-zero for anything but
  # "active", so a `|| echo` fallback would append a second line and smuggle a
  # newline into this row (the wrapper reads only the last line and would call
  # the whole check crashed). First line only, always.
  ras="${CHAIN_DOCTOR_RAS_STATE:-$(systemctl is-active rasdaemon 2>/dev/null | head -n 1)}"
  [[ -n "$ras" ]] || ras="unknown"
  [[ "$ras" == "active" ]] || missing+="rasdaemon (is-active=$ras); "
  if [[ -z "$missing" ]]; then
    echo "PASS|crash recording hardened: journald sync drop-in present and rasdaemon active"
    return
  fi
  if (( hist == 0 )); then
    echo "PASS|no hardware-reset history on this host — journald/rasdaemon hardening is optional (missing: ${missing%; })"
    return
  fi
  echo "WARN|this host HAS hardware-reset history but the next postmortem will be poorer: ${missing%; }— see docs/host-guard.md § After a hardware reset (both need one sudo command)"
}

# EVIDENCE (§9 measurement discipline): benchmark/measurement runs record
# "no ambient CHAIN_* vars" as a precondition — stray knobs silently alter
# engine behavior. The engine snapshots names BEFORE its own exports
# (_CHAIN_AMBIENT_AT_START -> CHAIN_DOCTOR_AMBIENT); standalone runs compute
# from the live environment, minus the doctor's own control seams.
check_ambient_env() {
  local names=""
  if [[ -n "${CHAIN_DOCTOR_AMBIENT+set}" ]]; then
    names="$CHAIN_DOCTOR_AMBIENT"
  else
    names="$(compgen -A export CHAIN_ 2>/dev/null \
      | grep -Ev '^(CHAIN_DOCTOR|CHAIN_DOCTOR_AMBIENT|CHAIN_DOCTOR_BIN|CHAIN_DOCTOR_REPO_ROOT)$' \
      | sort | tr '\n' ' ' || true)"
  fi
  # Word-splitting the name list is the point here.
  # shellcheck disable=SC2086
  set -- $names
  if [[ $# -eq 0 ]]; then
    echo "PASS|no ambient CHAIN_* variables"
    return
  fi
  local shown=0 item="" list="" v
  for v in "$@"; do
    if [[ "$shown" -lt 4 ]]; then
      item="$v"
      [[ -n "${!v+set}" ]] && item="$v=$(printf '%.24s' "${!v}")"
      list="$list$item "
      shown=$((shown + 1))
    fi
  done
  [[ $# -gt 4 ]] && list="$list+$(($# - 4)) more "
  echo "WARN|$# ambient CHAIN_* var(s): ${list}— they silently alter engine behavior; measurement runs demand a clean env"
}

# ── Harness ─────────────────────────────────────────────────────────────────

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  echo ""
  echo "Checks: ${CHECKS[*]}"
}

N_PASS=0; N_WARN=0; N_FAIL=0; N_SKIP=0

run_check() {
  local key="$1" fn="check_${1//-/_}" out rc=0 verdict status detail
  out="$("$fn" 2>&1)" || rc=$?
  verdict="$(printf '%s\n' "$out" | sed -n '$p')"
  if [[ "$rc" -ne 0 || "$verdict" != *"|"* ]]; then
    status="FAIL"
    detail="check crashed (rc=$rc): $(printf '%.140s' "$out")"
  else
    status="${verdict%%|*}"
    detail="${verdict#*|}"
  fi
  case "$status" in
    PASS) N_PASS=$((N_PASS + 1)) ;;
    WARN) N_WARN=$((N_WARN + 1)) ;;
    SKIP) N_SKIP=$((N_SKIP + 1)) ;;
    *)    status="FAIL"; N_FAIL=$((N_FAIL + 1)) ;;
  esac
  printf '  %-4s  %-16s %s\n' "$status" "$key" "$detail"
}

STRICT=false
ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      printf '%s\n' "${CHECKS[@]}"
      exit 0
      ;;
    --only)
      [[ $# -ge 2 ]] || { echo "doctor: --only needs a check key (see --list)" >&2; exit 2; }
      ONLY="$2"; shift
      ;;
    --strict-doctor) STRICT=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "doctor: unknown argument '$1' (try --list, --only <check>, --strict-doctor)" >&2; exit 2 ;;
  esac
  shift
done

if [[ -n "$ONLY" ]]; then
  found=false
  for c in "${CHECKS[@]}"; do [[ "$c" == "$ONLY" ]] && found=true; done
  if [[ "$found" != "true" ]]; then
    echo "doctor: unknown check '$ONLY'; valid keys:" >&2
    printf '  %s\n' "${CHECKS[@]}" >&2
    exit 2
  fi
  TO_RUN=("$ONLY")
else
  TO_RUN=("${CHECKS[@]}")
fi

echo "[doctor] preflight environment check — repo: $ROOT"
for c in "${TO_RUN[@]}"; do
  run_check "$c"
done
echo "[doctor] summary: pass=$N_PASS warn=$N_WARN fail=$N_FAIL skip=$N_SKIP"
if [[ "$N_FAIL" -gt 0 || "$N_WARN" -gt 0 ]]; then
  echo "[doctor] advisory only — WARN/FAIL rows never block anything unless --strict-doctor is passed."
fi

if [[ "$STRICT" == "true" && "$N_FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
