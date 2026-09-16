#!/usr/bin/env bash
# service-owner.sh — HARD-5: service ownership and lifecycle authority.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE INVARIANT
#
#     Framework service cleanup may terminate a process ONLY with per-process
#     proof of ownership read from /proc/<pid>/environ.
#
#     A configured port, a matching repository cwd, a matching command line, an
#     absent registry record, or a process that merely "looks stale" is NEVER
#     proof.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY THE ORIGINAL HARD-5 MIGRATION RULE WAS UNSAFE
#
# The approved plan's state table said `NO_RECORD ⇒ allow (legacy)`: a port with
# no ownership record could still be blind-killed, "until the next boot writes
# records". That rule preserves the exact defect HARD-5 exists to remove. A
# pre-existing PRODUCT service — started by the operator, by scripts/dev.sh, by
# an IDE task, or by a product-side pump — will NEVER have a framework record,
# by definition. It is permanently in the NO_RECORD state, so `NO_RECORD ⇒
# allow` means "always allowed to kill the product's stack".
#
# That is what happened on 2026-09-15: trading_workstation's backend and
# frontend were killed on :8319/:3319, the framework's own deterministic offset
# ports for that checkout, by teardown paths that had no way to tell a product
# service from a stray agent-started one.
#
# So NO_RECORD here means REFUSE, and the registry is not the authority at all.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHERE AUTHORITY ACTUALLY LIVES
#
# Two stamps are placed in the ENVIRONMENT of processes the framework starts.
# environ is inherited across fork AND exec, so every descendant carries them —
# including a process reparented to init after its launcher died, and including
# a server an AGENT started inside our dispatch (the agent's shell inherited
# them from us). A process that merely recycled a recorded pid carries neither.
#
#   CHAIN_SERVICE_OWNER_SCOPE=<repo12>.<owner_token>
#       "this process was spawned inside our lifecycle". Set once per
#       lifecycle owner (goal engine / phase runner / standalone step script).
#       This is what makes an abandoned developer verification server safely
#       reapable WITHOUT a blind port sweep — the old reason the sweep existed.
#
#   CHAIN_SERVICE_INSTANCE=<32 hex>
#       "this process IS the managed service we launched for this boot". Set
#       per service spawn; ties a live process to a registry record.
#
# The registry (see below) is an OBSERVABILITY and janitor record — it explains
# who owns what, drives the doctor row and the blocker messages, and lets the
# janitor reap dead records. It is deliberately NOT the kill authority, so a
# corrupt or unreadable registry can neither authorize an unsafe kill nor wedge
# the pipeline: authority is a direct procfs read that needs no registry at all.
#
# ─────────────────────────────────────────────────────────────────────────────
# NO PERMISSIVE MODE
#
# The approved plan proposed CHAIN_SERVICE_OWNERSHIP=enforce|warn|off with a
# `warn` rollout that still killed. That is not implemented, deliberately: a
# switch that silently restores blind termination restores the incident. There
# is no knob that weakens this layer. Rollback is `git revert`.
# CHAIN_SERVICE_OWNERSHIP_VERBOSE=1 only adds logging.
#
# Re-source safe; no side effects at source time.

if [[ -n "${_SERVICE_OWNER_SOURCED:-}" ]]; then return 0 2>/dev/null || true; fi
_SERVICE_OWNER_SOURCED=1

# shellcheck source=engine-identity.sh
source "$(dirname "${BASH_SOURCE[0]}")/engine-identity.sh"

# ── Logging / telemetry (both optional; never fatal) ─────────────────────────
_svc_log() { echo "[services] $*" >&2; }
_svc_vlog() { [[ "${CHAIN_SERVICE_OWNERSHIP_VERBOSE:-0}" == "1" ]] && _svc_log "$*"; return 0; }
_svc_event() {
  declare -F record_telemetry_event >/dev/null 2>&1 || return 0
  record_telemetry_event "$1" "$2" 2>/dev/null || true
}

# ── Project identity ─────────────────────────────────────────────────────────
# Same normalization as _project_port_offset in common.sh: a vendored framework
# checkout and its product root must resolve to ONE project, because they share
# one port namespace.
service_project_root() {
  local r="${1:-${REPO_ROOT:-$PWD}}"
  [[ "$r" == */incredible_auto_dev ]] && r="${r%/incredible_auto_dev}"
  printf '%s' "$r"
}

service_repo_hash() {
  printf '%s' "$(service_project_root "${1:-}")" | sha1sum | cut -c1-12
}

# ── Registry location ────────────────────────────────────────────────────────
# Outside the repository on purpose: runs/ is committed by the showcase push, and
# a lock/pid artifact must never ship as certified evidence.
service_registry_root() {
  echo "${CHAIN_SERVICE_REGISTRY_DIR:-${CHAIN_TMP_ROOT:-$HOME/.cache/iad}/services}"
}

service_registry_dir() { echo "$(service_registry_root)/$(service_repo_hash "${1:-}")"; }

service_owner_record_path() { echo "$(service_registry_dir)/${1}.owner"; }

# ── Ownership scope ──────────────────────────────────────────────────────────
service_owner_scope_value() { # <project_root> <owner_token>
  printf '%s.%s' "$(service_repo_hash "${1:-}")" "${2:-}"
}

# service_owner_scope_init [project_root] [owner_kind] — establish THIS process
# tree as a lifecycle owner. Idempotent and inheritance-preserving: a child that
# already inherited a scope keeps it, so one engine's whole tree reports one
# owner and a child script never fragments ownership of services its parent
# booted.
service_owner_scope_init() {
  local root="${1:-${REPO_ROOT:-$PWD}}" kind="${2:-standalone}"
  if [[ -n "${CHAIN_SERVICE_OWNER_SCOPE:-}" ]]; then
    export CHAIN_SERVICE_OWNER_SCOPE
    return 0
  fi
  local tok
  tok="$(engine_token_self)"
  if [[ -z "$tok" ]]; then
    # No procfs identity => we cannot prove ownership of anything we start, so
    # we must never claim any. Leave the scope unset: every termination path
    # then refuses, which is the correct fail-closed posture.
    _svc_log "WARNING: cannot mint a process identity token on this host — service ownership is unprovable, so ALL framework service termination will be refused."
    _svc_event "services_identity_unavailable" '{"reason":"no procfs token"}'
    return 1
  fi
  export CHAIN_SERVICE_OWNER_TOKEN="$tok"
  export CHAIN_SERVICE_OWNER_KIND="$kind"
  export CHAIN_SERVICE_OWNER_SCOPE="$(service_owner_scope_value "$root" "$tok")"
  _svc_vlog "lifecycle owner: kind=$kind scope=$CHAIN_SERVICE_OWNER_SCOPE"
  return 0
}

service_instance_mint() {
  local v
  v="$(head -c16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [[ -n "$v" ]] || v="$(date +%s%N)$$"
  printf '%s' "$v"
}

# ── Per-process ownership verdict (THE authority) ────────────────────────────
# service_pid_ownership <pid> — echoes one of:
#   MINE        this process carries OUR scope stamp
#   DEAD        our repo lineage, owner token provably dead => reclaimable
#   FOREIGN     a different live/unprovable owner, or a different project
#   UNOWNED     no scope stamp at all (a pre-existing/product/external process)
#   GONE        the process no longer exists (nothing to decide, nothing to kill)
#   UNREADABLE  environ could not be read (other user, no procfs, zombie)
# rc is always 0; the verdict is on stdout. Only MINE and DEAD authorize a kill.
# GONE is distinct from UNREADABLE so a service that exits between being listed
# and being inspected — the normal race during our OWN teardown — is skipped
# silently instead of logging a refusal for a process nobody needs killed.
service_pid_ownership() {
  local pid="${1:-}" scope rc=0
  [[ "$pid" =~ ^[0-9]+$ ]] || { echo "UNREADABLE"; return 0; }
  scope="$(engine_proc_env "$pid" CHAIN_SERVICE_OWNER_SCOPE)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    if [[ ! -e "/proc/$pid" ]]; then echo "GONE"; else echo "UNREADABLE"; fi
    return 0
  fi
  if [[ -z "$scope" ]]; then echo "UNOWNED"; return 0; fi
  if [[ -n "${CHAIN_SERVICE_OWNER_SCOPE:-}" && "$scope" == "$CHAIN_SERVICE_OWNER_SCOPE" ]]; then
    echo "MINE"; return 0
  fi
  # Same project, different owner: reclaimable only if that owner is PROVABLY
  # dead. engine_token_alive is conservative — unprovable counts as alive — so
  # an ambiguous identity never authorizes a kill.
  local their_repo="${scope%%.*}" their_tok="${scope#*.}"
  if [[ "$their_repo" == "$(service_repo_hash)" ]] && ! engine_token_alive "$their_tok" >/dev/null 2>&1; then
    echo "DEAD"; return 0
  fi
  echo "FOREIGN"; return 0
}

# service_pid_carries_instance <pid> <instance> — rc 0 iff this exact managed
# service instance. Used for record↔process correlation, not for authority.
service_pid_carries_instance() {
  local pid="${1:-}" want="${2:-}" got rc=0
  [[ -n "$want" ]] || return 1
  got="$(engine_proc_env "$pid" CHAIN_SERVICE_INSTANCE)" || rc=$?
  [[ $rc -eq 0 && "$got" == "$want" ]]
}

service_pid_in_our_scope() { [[ "$(service_pid_ownership "${1:-}")" == "MINE" ]]; }

# ── Listener discovery ───────────────────────────────────────────────────────
# Every pid with a LISTEN socket on <port>. `ss` reports pids only for sockets
# this user owns, which is exactly the set we could ever legitimately touch.
service_listener_pids() {
  local port="${1:-}" out=""
  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  if command -v ss >/dev/null 2>&1; then
    out="$(ss -tlnpH "sport = :$port" 2>/dev/null \
            | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -un)"
  fi
  if [[ -z "$out" ]] && command -v lsof >/dev/null 2>&1; then
    out="$(lsof -ti "tcp:$port" -sTCP:LISTEN 2>/dev/null | sort -un)"
  fi
  printf '%s\n' $out
}

service_port_is_listening() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  ss -tln 2>/dev/null | grep -q ":${port} "
}

# ── Registry records (advisory) ──────────────────────────────────────────────
_svc_rec_field() { sed -n "s/^${2}=//p" "$1" 2>/dev/null | head -n1; }

service_owner_write_as() { # <port> <role> <service_pid> <instance> <owner_token>
  local port="$1" role="$2" pid="$3" inst="$4" tok="$5"
  local dir rec tmp
  dir="$(service_registry_dir)"
  mkdir -p "$dir" 2>/dev/null || {
    export CHAIN_SERVICE_OWNER_WRITE_FAILED=1
    _svc_log "WARNING: cannot create the ownership registry at $dir — the service on port $port starts, but its ownership is unrecorded."
    _svc_event "services_registry_error" "$(printf '{"op":"dir","port":%s}' "$port")"
    return 1
  }
  rec="$(service_owner_record_path "$port")"
  tmp="$rec.$$.tmp"
  {
    echo "v=2"
    echo "port=$port"
    echo "role=$role"
    echo "owner_token=$tok"
    echo "owner_kind=${CHAIN_SERVICE_OWNER_KIND:-standalone}"
    echo "scope=$(service_owner_scope_value "" "$tok")"
    echo "instance=$inst"
    echo "service_pid=$pid"
    echo "service_starttime=$(_engine_starttime "$pid")"
    echo "boot_id=$(_engine_boot8)"
    echo "host=$(hostname 2>/dev/null || echo unknown-host)"
    echo "project_root=$(service_project_root)"
    echo "session_id=${GOAL_SESSION_ID:-}"
    echo "iter=${GOAL_ITER_INDEX:-}"
    echo "epoch=$(date +%s)"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$rec" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null || true
    export CHAIN_SERVICE_OWNER_WRITE_FAILED=1
    _svc_log "WARNING: could not write the ownership record for port $port."
    _svc_event "services_registry_error" "$(printf '{"op":"write","port":%s}' "$port")"
    return 1
  }
  _svc_vlog "recorded port=$port role=$role pid=$pid instance=${inst:0:8}…"
  return 0
}

service_owner_write() { # <port> <role> <service_pid> <instance>
  service_owner_write_as "$1" "$2" "$3" "$4" "${CHAIN_SERVICE_OWNER_TOKEN:-$(engine_token_self)}"
}

service_owner_release() {
  local rec; rec="$(service_owner_record_path "${1:-}")"
  rm -f "$rec" 2>/dev/null || true
  return 0
}

# service_owner_classify <port> — record state, for messages/doctor/janitor.
# NO_RECORD and REGISTRY_ERROR are distinct and never collapse into each other.
# Note: this describes the RECORD, not the authority — see service_pid_ownership.
service_owner_classify() {
  local port="${1:-}" dir rec
  dir="$(service_registry_dir)"
  if [[ -e "$dir" && ! -r "$dir" ]]; then echo "REGISTRY_ERROR:dir"; return 0; fi
  rec="$(service_owner_record_path "$port")"
  [[ -e "$rec" ]] || { echo "NO_RECORD"; return 0; }
  [[ -r "$rec" ]] || { echo "REGISTRY_ERROR:read"; return 0; }
  local v tok
  v="$(_svc_rec_field "$rec" v)"
  tok="$(_svc_rec_field "$rec" owner_token)"
  if [[ "$v" != "2" || -z "$tok" ]]; then
    # A writer may be mid-write: give it a grace window before calling the file
    # corrupt. Either way the state is NOT NO_RECORD and NEVER authorizes a kill.
    local age now mtime grace="${CHAIN_SERVICE_OWNER_INIT_GRACE:-60}"
    now="$(date +%s)"; mtime="$(stat -c %Y "$rec" 2>/dev/null || echo 0)"
    age=$(( now - mtime ))
    if [[ "$age" -lt "$grace" ]]; then echo "GRACE"; else echo "REGISTRY_ERROR:malformed"; fi
    return 0
  fi
  if [[ -n "${CHAIN_SERVICE_OWNER_TOKEN:-}" && "$tok" == "$CHAIN_SERVICE_OWNER_TOKEN" ]]; then
    echo "MINE"; return 0
  fi
  if ! engine_token_alive "$tok" >/dev/null 2>&1; then echo "DEAD"; return 0; fi
  echo "FOREIGN:$tok"; return 0
}

# ── Termination ──────────────────────────────────────────────────────────────
# _svc_pid_tree <pid> — children before parents, snapshotted BEFORE signalling
# so reparented grandchildren stay reachable for the KILL sweep.
_svc_pid_tree() {
  local p="${1:-}" c
  [[ -n "$p" ]] || return 0
  for c in $(pgrep -P "$p" 2>/dev/null || true); do _svc_pid_tree "$c"; done
  printf '%s\n' "$p"
}

_svc_kill_tree() {
  local pid="${1:-}" p grace="${CHAIN_KILL_GRACE_SECONDS:-2}"
  [[ -n "$pid" ]] || return 0
  local -a tree=()
  while IFS= read -r p; do [[ -n "$p" ]] && tree+=("$p"); done < <(_svc_pid_tree "$pid")
  for p in ${tree[@]+"${tree[@]}"}; do kill -TERM "$p" 2>/dev/null || true; done
  [[ "$grace" =~ ^[0-9]+$ ]] || grace=2
  [[ "$grace" -gt 0 ]] && sleep "$grace"
  for p in ${tree[@]+"${tree[@]}"}; do
    if kill -0 "$p" 2>/dev/null; then kill -KILL "$p" 2>/dev/null || true; fi
  done
  return 0
}

# service_owner_terminate <port> <caller>
#
# The ONLY sanctioned port-scoped teardown in the framework. Semantics:
#   rc 0 — the port now holds no framework-owned service. Either nothing was
#          listening (idempotent no-op), or every listener was PROVEN ours and
#          has been terminated by pid tree.
#   rc 1 — REFUSED. At least one listener could not be proven ours, so nothing
#          was signalled at all. The port is still occupied by that process.
#
# Refusal is all-or-nothing per port on purpose: if we cannot account for every
# listener, we do not get to kill the ones we recognise and hope.
service_owner_terminate() {
  local port="${1:-}" caller="${2:-unknown}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0

  local -a pids=()
  local p
  while IFS= read -r p; do [[ -n "$p" ]] && pids+=("$p"); done < <(service_listener_pids "$port")

  if [[ ${#pids[@]} -eq 0 ]]; then
    # No pid we can see. Two very different situations:
    #   (a) genuinely nothing listening  -> idempotent success
    #   (b) the port IS listening but the socket belongs to ANOTHER USER, so
    #       `ss -p` / `lsof` withhold the pid from us.
    # (b) must not be reported as success: the caller would be told the port is
    # clear, spawn into it, and fail to bind for a reason nothing explained.
    if service_port_is_listening "$port"; then
      _svc_log "kill refused ($caller): port $port is listening but no owning pid is visible to this user — it belongs to another user's process. Not ours to terminate."
      _svc_event "services_kill_refused" \
        "$(printf '{"port":%s,"caller":"%s","verdict":"INVISIBLE"}' "$port" "$caller")"
      return 1
    fi
    # Drop our own stale record so the registry does not accumulate ghosts;
    # never touch a record we do not own.
    local st; st="$(service_owner_classify "$port")"
    [[ "$st" == "MINE" || "$st" == "DEAD" ]] && service_owner_release "$port"
    return 0
  fi

  # Fail closed when this process has no provable identity of its own.
  if [[ -z "${CHAIN_SERVICE_OWNER_SCOPE:-}" ]]; then
    _svc_log "kill refused ($caller): port $port — this process has no ownership scope, so it cannot prove it owns anything."
    _svc_event "services_kill_refused" \
      "$(printf '{"port":%s,"caller":"%s","reason":"no-owner-scope"}' "$port" "$caller")"
    return 1
  fi

  local verdict
  local -a owned=()
  # `owned` may legitimately end up empty when every listener was GONE — that is
  # a successful no-op, not a refusal.
  for p in "${pids[@]}"; do
    verdict="$(service_pid_ownership "$p")"
    case "$verdict" in
      MINE|DEAD) owned+=("$p") ;;
      GONE)      continue ;;   # already exited; nothing to authorize or kill
      *)
        local rec_state cmd
        rec_state="$(service_owner_classify "$port")"
        cmd="$(tr -d '\n' < "/proc/$p/comm" 2>/dev/null || echo '?')"
        _svc_log "kill refused ($caller): port $port is held by pid $p ($cmd) which is $verdict — no proof this session started it. Record state: $rec_state. Our scope: ${CHAIN_SERVICE_OWNER_SCOPE}."
        _svc_event "services_kill_refused" \
          "$(printf '{"port":%s,"caller":"%s","pid":%s,"verdict":"%s","record":"%s"}' \
             "$port" "$caller" "$p" "$verdict" "${rec_state%%:*}")"
        return 1
        ;;
    esac
  done

  for p in ${owned[@]+"${owned[@]}"}; do _svc_kill_tree "$p"; done
  _svc_event "services_terminated" \
    "$(printf '{"port":%s,"caller":"%s","pids":%d}' "$port" "$caller" "${#owned[@]}")"
  _svc_vlog "terminated ${#owned[@]} owned listener(s) on port $port ($caller)"

  # Let the kernel actually reap the killed processes and close their listening
  # sockets before judging. Without this bounded wait the check races a process
  # we SIGKILLed microseconds ago and reports a false "incomplete" — which would
  # make every normal teardown look like a failure.
  local _w=0
  while [[ $_w -lt "${CHAIN_SERVICE_RELEASE_WAIT:-5}" ]]; do
    service_port_is_listening "$port" || break
    sleep 0.5
    _w=$((_w + 1))
  done

  # Report honestly if something survived: a caller must never be told a port is
  # clear when it is not.
  if service_port_is_listening "$port"; then
    _svc_log "WARNING ($caller): port $port is still listening after terminating its owned processes — treat the service as NOT torn down."
    _svc_event "services_terminate_incomplete" \
      "$(printf '{"port":%s,"caller":"%s"}' "$port" "$caller")"
    return 1
  fi
  service_owner_release "$port"
  return 0
}

# service_pid_kill_allowed <pid> <caller> — the pid-scoped gate used by the
# stale-server helpers, which previously killed on a cwd match alone. A shared
# checkout is not an owner: every engine on this host has the same cwd.
service_pid_kill_allowed() {
  local pid="${1:-}" caller="${2:-unknown}" verdict
  verdict="$(service_pid_ownership "$pid")"
  case "$verdict" in
    MINE|DEAD) return 0 ;;
    GONE)      return 1 ;;   # nothing there; caller's kill would be a no-op anyway
    *)
      _svc_log "kill refused ($caller): pid $pid is $verdict — a matching directory or command line is not proof of ownership."
      _svc_event "services_kill_refused" \
        "$(printf '{"caller":"%s","pid":%s,"verdict":"%s","scope":"pid"}' "$caller" "$pid" "$verdict")"
      return 1 ;;
  esac
}

# service_port_blocker <port> <role> <context> — the operational blocker printed
# when the framework needs a port it may not reclaim. Names the actual process
# and the remedies, so an operator can act without guessing.
service_port_blocker() {
  local port="${1:-}" role="${2:-service}" ctx="${3:-service startup}" p cmd verdict
  _svc_log "BLOCKED ($ctx): port $port is required for the $role but is held by a process this session does not own."
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-160)"
    verdict="$(service_pid_ownership "$p")"
    _svc_log "  holder: pid $p [$verdict] $cmd"
  done < <(service_listener_pids "$port")
  _svc_log "  The framework will NOT terminate it: it cannot prove it started it, and killing an unowned listener is the 2026-09-15 incident this rule exists to prevent."
  _svc_log "  Remedies: (a) make the existing $role healthy so this run can reuse it; (b) stop it yourself, then re-run; (c) start the stack via this framework so it is owned."
  _svc_event "services_port_blocked" \
    "$(printf '{"port":%s,"role":"%s","context":"%s"}' "$port" "$role" "$ctx")"
  return 0
}

# ── Maintenance ──────────────────────────────────────────────────────────────
service_registry_janitor() {
  local dir rec tok inst spid removed=0
  dir="$(service_registry_dir)"
  [[ -d "$dir" && -r "$dir" ]] || return 0
  local max_age_days="${CHAIN_SERVICE_RECORD_MAX_AGE_DAYS:-7}"
  for rec in "$dir"/*.owner; do
    [[ -e "$rec" ]] || continue
    local drop=0
    if [[ ! -r "$rec" ]]; then continue; fi
    tok="$(_svc_rec_field "$rec" owner_token)"
    inst="$(_svc_rec_field "$rec" instance)"
    spid="$(_svc_rec_field "$rec" service_pid)"
    # Dead owner AND the recorded service process is gone or recycled.
    if [[ -n "$tok" ]] && ! engine_token_alive "$tok" >/dev/null 2>&1; then
      if ! service_pid_carries_instance "$spid" "$inst"; then drop=1; fi
    fi
    if [[ -n "$(find "$rec" -mtime "+$max_age_days" 2>/dev/null)" ]]; then drop=1; fi
    if [[ $drop -eq 1 ]]; then rm -f "$rec" 2>/dev/null && removed=$((removed + 1)); fi
  done
  [[ $removed -gt 0 ]] && _svc_vlog "janitor removed $removed stale ownership record(s)"
  return 0
}

# service_owner_doctor — one "STATUS|detail" line for the doctor table.
service_owner_doctor() {
  local dir; dir="$(service_registry_dir)"
  if [[ -e "$dir" && ! -r "$dir" ]]; then
    echo "FAIL|ownership registry is unreadable ($dir) — every service teardown will refuse (fail-closed)."; return 0
  fi
  if [[ ! -d "$dir" ]]; then echo "PASS|no ownership records yet (registry: $dir)"; return 0; fi
  local total=0 foreign=0 bad=0 rec st
  for rec in "$dir"/*.owner; do
    [[ -e "$rec" ]] || continue
    total=$((total + 1))
    st="$(service_owner_classify "$(basename "$rec" .owner)")"
    case "$st" in
      FOREIGN*) foreign=$((foreign + 1)) ;;
      REGISTRY_ERROR*) bad=$((bad + 1)) ;;
    esac
  done
  if [[ $bad -gt 0 ]]; then
    echo "FAIL|$bad malformed ownership record(s) in $dir — run: service-owner.sh repair <port>"; return 0
  fi
  if [[ $foreign -gt 0 ]]; then
    echo "WARN|$foreign of $total ownership record(s) belong to another live owner — concurrent runs share this checkout's ports."; return 0
  fi
  echo "PASS|$total ownership record(s), none foreign"
}

# ── CLI (operator surface) ───────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-status}" in
    status)
      echo "registry: $(service_registry_dir)"
      echo "scope:    ${CHAIN_SERVICE_OWNER_SCOPE:-<none — terminations will refuse>}"
      for f in "$(service_registry_dir)"/*.owner; do
        [[ -e "$f" ]] || continue
        echo "--- $(basename "$f")  [$(service_owner_classify "$(basename "$f" .owner)")]"
        cat "$f"
      done
      ;;
    classify) service_owner_classify "${2:-}" ;;
    owns)     service_pid_ownership "${2:-}" ;;
    doctor)   service_owner_doctor ;;
    janitor)  service_registry_janitor ;;
    repair)
      rec="$(service_owner_record_path "${2:-}")"
      [[ -e "$rec" ]] || { echo "no record for port ${2:-}"; exit 1; }
      echo "--- $rec"; cat "$rec"; echo
      read -r -p "Remove this record? [y/N] " a
      [[ "$a" == "y" || "$a" == "Y" ]] && rm -f "$rec" && echo "removed."
      ;;
    *) echo "usage: service-owner.sh {status|classify <port>|owns <pid>|doctor|janitor|repair <port>}" >&2; exit 2 ;;
  esac
fi
