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

# service_owner_write_as <port> <role> <pid> <instance> <owner_token>
#                        [lifecycle] [health_url] [revision]
# lifecycle defaults to "persistent": this writer is only reached from the
# managed-service boot path, and those ARE the application.
service_owner_write_as() {
  local port="$1" role="$2" pid="$3" inst="$4" tok="$5"
  local lifecycle="${6:-persistent}" health_url="${7:-}" revision="${8:-}"
  local health_re="${9:-$(service_health_regex "$role")}"
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
    echo "lifecycle=$lifecycle"
    echo "health_url=$health_url"
    echo "health_re=$health_re"
    echo "revision=$revision"
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
  service_owner_write_as "$1" "$2" "$3" "$4" \
    "${CHAIN_SERVICE_OWNER_TOKEN:-$(engine_token_self)}"
}

# service_owner_register <port> <role> <pid> <instance> <lifecycle> <health_url> <revision>
# The full-fidelity registration used by the managed-service boot path: it is
# what lets a later sweep tell a persistent application service from a stray
# verification server, and a current service from one serving stale code.
service_owner_register() {
  service_owner_write_as "$1" "$2" "$3" "$4" \
    "${CHAIN_SERVICE_OWNER_TOKEN:-$(engine_token_self)}" "${5:-persistent}" "${6:-}" "${7:-}" "${8:-}"
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

# service_pid_starttime <pid> — the pid's stable within-boot identity, or "".
service_pid_starttime() { _engine_starttime "${1:-}"; }

# service_signal_tree <pid> [grace_seconds] [expected_identity]
#
# Terminate a process and its descendants with identity bound at SIGNAL time.
#
# The idiom this replaces — snapshot pids, TERM, sleep, `kill -0`, KILL — checks
# EXISTENCE before the escalation, not IDENTITY. A target that exits during the
# grace window and has its pid recycled receives the KILL, and an ownership
# check performed before the sequence cannot prevent that: the check happens
# once, the signals happen seconds later.
#
# lib/proc_signal.py pins every process by pidfd before the first signal, so a
# recycled pid is structurally unreachable; without pidfd it revalidates the
# start time immediately before each signal. When `expected_identity` is given
# and no longer matches, NOTHING is signalled.
#
# Best-effort and set -e safe. Always returns 0 except on identity refusal (1).
# service_signal_tree <pid> [grace] [expected_identity] [required_scope]
#
# `required_scope` is the ownership stamp the CALLER verified. Passing it is
# what binds the ownership decision to the act: proc_signal.py pins the pid,
# then re-reads the stamp from the pinned process, so a process that was
# replaced between the shell's check and this call cannot inherit the decision.
service_signal_tree() {
  local pid="${1:-}" grace="${2:-${CHAIN_KILL_GRACE_SECONDS:-2}}" want="${3:-}" scope="${4:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  [[ "$grace" =~ ^[0-9]+$ ]] || grace=2
  # SPAWNED MODE. Both the remembered identity and the expected ownership scope
  # are REQUIRED. An empty value used to mean "omit that flag", i.e. silently
  # drop the check — the opposite of what a missing proof should do. A missing
  # identity also covers "the process is already gone", where refusing is the
  # correct no-op.
  if [[ -z "$want" || -z "$scope" ]]; then
    _svc_vlog "refusing to signal pid $pid: missing $( [[ -z "$want" ]] && printf identity || printf scope ) — verification cannot be skipped"
    return 1
  fi
  local helper="$(dirname "${BASH_SOURCE[0]}")/proc_signal.py"
  if [[ -f "$helper" ]] && command -v python3 >/dev/null 2>&1; then
    python3 "$helper" tree "$pid" --grace "$grace" \
      --identity "$want" --require-env "CHAIN_SERVICE_OWNER_SCOPE=$scope" 2>/dev/null
    local rc=$?
    [[ $rc -eq 3 ]] && return 1     # verification failed: nothing was signalled
    return 0
  fi
  # Fallback: same guarantee, weaker window. Revalidate before EVERY signal.
  local p now
  if [[ -n "$want" ]]; then
    [[ "$(service_pid_starttime "$pid")" == "$want" ]] || return 1
  fi
  if [[ -n "$scope" ]]; then
    [[ "$(engine_proc_env "$pid" CHAIN_SERVICE_OWNER_SCOPE 2>/dev/null)" == "$scope" ]] || return 1
  fi
  # Descendants are held to the SAME ownership stamp as the root. Checking only
  # their start times (as this loop used to) verifies "still the same process"
  # while saying nothing about whose process it is — so an unstamped child in
  # the tree was signalled purely for being there.
  local -a tree=() ids=()
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    now="$(service_pid_starttime "$p")"
    [[ -n "$now" ]] || continue
    [[ "$(engine_proc_env "$p" CHAIN_SERVICE_OWNER_SCOPE 2>/dev/null)" == "$scope" ]] || {
      _svc_vlog "fallback: skipping pid $p in the tree of $pid — it does not carry our ownership stamp"
      continue
    }
    tree+=("$p"); ids+=("$now")
  done < <(_svc_pid_tree "$pid")
  local i
  for i in ${!tree[@]+"${!tree[@]}"}; do
    [[ "$(service_pid_starttime "${tree[$i]}")" == "${ids[$i]}" \
       && "$(engine_proc_env "${tree[$i]}" CHAIN_SERVICE_OWNER_SCOPE 2>/dev/null)" == "$scope" ]] \
      && kill -TERM "${tree[$i]}" 2>/dev/null || true
  done
  [[ "$grace" -gt 0 ]] && sleep "$grace"
  for i in ${!tree[@]+"${!tree[@]}"}; do
    [[ "$(service_pid_starttime "${tree[$i]}")" == "${ids[$i]}" \
       && "$(engine_proc_env "${tree[$i]}" CHAIN_SERVICE_OWNER_SCOPE 2>/dev/null)" == "$scope" ]] \
      && kill -KILL "${tree[$i]}" 2>/dev/null || true
  done
  return 0
}

# NOTE: there is deliberately no bare "kill this pid tree" helper here any more.
# The previous `_svc_kill_tree <pid>` shim passed neither an identity nor an
# ownership stamp, so every caller silently dropped the verification it had just
# performed — which is precisely how the ownership-to-signal race survived a
# round of hardening. Signalling helpers that accept a pid ALONE are a trap:
# call service_signal_tree with the identity and scope you verified.

# service_signal_child <pid> [grace] [identity] — CHILD MODE.
#
# For a process this shell FORKED rather than exec'd — `( ... ) &` — there is no
# usable environ stamp: /proc's environ is frozen at the last exec, and a forked
# subshell never execs, so a variable the parent exported at runtime is absent
# from the child's environ. Requiring a stamp there does not make the teardown
# safer, it just makes it refuse to reap our own forks.
#
# The honest proof for that case is the kernel's parent link, and it is strong:
# an un-`wait`ed child's pid cannot be recycled while the parent still holds it.
# proc_signal.py verifies it AFTER pinning, so it is a real check and not a
# bypass. rc 0 signalled (or nothing to do), rc 1 refused.
service_signal_child() {
  local pid="${1:-}" grace="${2:-${CHAIN_KILL_GRACE_SECONDS:-2}}" want="${3:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  [[ "$grace" =~ ^[0-9]+$ ]] || grace=2
  [[ -n "$want" ]] || want="$(service_pid_starttime "$pid")"
  [[ -n "$want" ]] || return 1          # already gone: nothing to signal
  local me="${BASHPID:-$$}"
  local helper="$(dirname "${BASH_SOURCE[0]}")/proc_signal.py"
  if [[ -f "$helper" ]] && command -v python3 >/dev/null 2>&1; then
    python3 "$helper" tree "$pid" --grace "$grace" \
      --identity "$want" --require-ppid "$me" 2>/dev/null
    local rc=$?
    [[ $rc -eq 3 ]] && return 1
    return 0
  fi
  # Fallback: verify the parent link, then hold each signal to the start time.
  local ppid; ppid="$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null)"
  [[ "$ppid" == "$me" ]] || return 1
  local p now
  local -a tree=() ids=()
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    now="$(service_pid_starttime "$p")"
    [[ -n "$now" ]] || continue
    tree+=("$p"); ids+=("$now")
  done < <(_svc_pid_tree "$pid")
  local i
  for i in ${!tree[@]+"${!tree[@]}"}; do
    [[ "$(service_pid_starttime "${tree[$i]}")" == "${ids[$i]}" ]] \
      && kill -TERM "${tree[$i]}" 2>/dev/null || true
  done
  [[ "$grace" -gt 0 ]] && sleep "$grace"
  for i in ${!tree[@]+"${!tree[@]}"}; do
    [[ "$(service_pid_starttime "${tree[$i]}")" == "${ids[$i]}" ]] \
      && kill -KILL "${tree[$i]}" 2>/dev/null || true
  done
  return 0
}

# service_terminate_listener <pid> [grace] — DISCOVERY MODE.
#
# For a pid the framework did NOT spawn (a listener it just found), there is no
# trustworthy prior identity to carry. Reading the ownership stamp in the shell
# and handing it back to the signaller proves nothing: a process that replaced
# the one we looked at supplies its own self-consistent stamp and satisfies the
# very check it should fail. So the ownership decision is delegated to
# proc_signal.py, which pins the process and decides against the PINNED object —
# one observation, no gap. rc 0 signalled (or nothing to do), rc 1 refused.
service_terminate_listener() {
  local pid="${1:-}" grace="${2:-${CHAIN_KILL_GRACE_SECONDS:-2}}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  [[ "$grace" =~ ^[0-9]+$ ]] || grace=2
  local scope="${CHAIN_SERVICE_OWNER_SCOPE:-}"
  [[ -n "$scope" ]] || { _svc_vlog "refusing: no ownership scope for this process"; return 1; }
  local helper="$(dirname "${BASH_SOURCE[0]}")/proc_signal.py"
  if [[ -f "$helper" ]] && command -v python3 >/dev/null 2>&1; then
    python3 "$helper" tree "$pid" --grace "$grace" \
      --owner-scope "$scope" --owner-repo "$(service_repo_hash)" 2>/dev/null
    local rc=$?
    [[ $rc -eq 3 ]] && return 1
    return 0
  fi
  # Fallback: one read, then hold every signal to exactly that stamp.
  local found; found="$(engine_proc_env "$pid" CHAIN_SERVICE_OWNER_SCOPE 2>/dev/null)"
  [[ -n "$found" ]] || return 1
  if [[ "$found" != "$scope" ]]; then
    local their_repo="${found%%.*}" their_tok="${found#*.}"
    [[ "$their_repo" == "$(service_repo_hash)" ]] || return 1
    engine_token_alive "$their_tok" >/dev/null 2>&1 && return 1   # live foreign owner
  fi
  service_signal_tree "$pid" "$grace" "$(service_pid_starttime "$pid")" "$found"
}

# ── Lifecycle policy ─────────────────────────────────────────────────────────
# Ownership answers "may this process be terminated by us?".
# Lifecycle policy answers "SHOULD it be?" — a different question, and the one
# that decides whether a healthy application service survives a phase boundary.
#
#   persistent  the application itself (backend / frontend). Survives phase
#               boundaries, iteration boundaries and Goal Mode completion while
#               it is healthy and serving the current revision.
#   ephemeral   anything else we own on the port — chiefly a verification server
#               an agent started and abandoned. Always reaped.
#
# A persistent service is released ONLY when the restart is VERIFIED to be
# required: it is unhealthy, or it is serving a revision older than the working
# tree (it would otherwise hand the next step results from pre-fix code).

# service_tree_revision — a content hash of the WORKING TREE (not HEAD), so an
# uncommitted fix by the developer agent changes it. "" outside a git repo.
#
# Self-sufficient on purpose: it must not depend on lib/checkpoint.sh having
# been sourced, because it is consulted from teardown paths that source only
# this file. Prefers chain_tree_hash when it IS available (identical algorithm,
# plus that function's configured excludes).
service_tree_revision() {
  local h=''
  if declare -F chain_tree_hash >/dev/null 2>&1; then
    h="$(chain_tree_hash "${REPO_ROOT:-$PWD}" 2>/dev/null || printf '')"
    [[ -n "$h" ]] && { printf '%s' "$h"; return 0; }
  fi
  local root="${REPO_ROOT:-$PWD}" idx
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || { printf ''; return 0; }
  idx="$(mktemp "${TMPDIR:-/tmp}/svc-tree-index.XXXXXX")" || { printf ''; return 0; }
  rm -f "$idx"            # git add wants to create the index itself
  if GIT_INDEX_FILE="$idx" git -C "$root" add -A -- . 2>/dev/null; then
    h="$(GIT_INDEX_FILE="$idx" git -C "$root" write-tree 2>/dev/null || printf '')"
  fi
  rm -f "$idx"
  printf '%s' "$h"
}

# service_service_healthy <port> — probe the health URL recorded at boot.
# rc 0 healthy, 1 not healthy, 2 no recorded URL (cannot tell).
# Three different questions, previously conflated into one:
#   reachability — is a socket open and speaking HTTP?   (curl got a status)
#   identity     — is it the service we expect?          (service_verify_reuse)
#   health       — is the application actually serving?  (THIS function)
#
# The boot gate's `ready_re` answers reachability and is deliberately permissive
# — the backend's is `^[1-5][0-9][0-9]$`, so "any HTTP status" proves uvicorn is
# routing even on a project with no /health route. Using it for HEALTH meant an
# application returning 500 was preserved across phase boundaries and handed to
# QA as a satisfied dependency.
#
# Health uses an explicit contract, defaulting to 2xx/3xx:
#   1. CHAIN_SERVICE_HEALTHY_<ROLE> in the environment (project contract file),
#   2. else the `health_re` recorded when the service was registered,
#   3. else `^[23]`.
# An application whose valid readiness response is NOT 2xx stays supported — it
# just has to say so, e.g. CHAIN_SERVICE_HEALTHY_BACKEND='^(2|3|404)'.
service_health_regex() {   # <role> [recorded_health_re]
  local role="${1:-}" recorded="${2:-}"
  local var="CHAIN_SERVICE_HEALTHY_$(printf '%s' "$role" | tr '[:lower:]-' '[:upper:]_')"
  if [[ -n "${!var:-}" ]]; then printf '%s' "${!var}"
  elif [[ -n "$recorded" ]]; then printf '%s' "$recorded"
  else printf '%s' '^[23]'; fi
}

service_service_healthy() {
  local port="${1:-}" rec url code role re
  rec="$(service_owner_record_path "$port")"
  [[ -r "$rec" ]] || return 2
  url="$(_svc_rec_field "$rec" health_url)"
  [[ -n "$url" ]] || return 2
  role="$(_svc_rec_field "$rec" role)"
  re="$(service_health_regex "$role" "$(_svc_rec_field "$rec" health_re)")"
  code=$(curl -s -o /dev/null --max-time "${CHAIN_HEALTH_PROBE_TIMEOUT:-10}" \
          -w "%{http_code}" "$url" 2>/dev/null || true)
  if [[ "$code" =~ $re ]]; then return 0; fi
  _svc_vlog "port $port ($role): status ${code:-none} does not satisfy the health contract ${re} — not healthy"
  return 1
}

# service_record_listener_bound <port> — rc 0 iff the port's record actually
# describes a process that is listening RIGHT NOW: some current listener must
# carry the record's CHAIN_SERVICE_INSTANCE.
#
# Without this, a record outlives the service it describes and the next thing to
# take the port inherits its metadata. Concretely: a registered persistent
# backend exits, an agent's verification server binds the same port, answers
# 200, and — because the working tree has not changed — the record says
# "persistent, current, healthy". The leak would be preserved as the application
# and reused as the dependency. A record is a claim about a process, so it is
# only usable while that process is demonstrably still the one on the port.
service_record_listener_bound() {
  local port="${1:-}" rec inst p
  rec="$(service_owner_record_path "$port")"
  [[ -r "$rec" ]] || return 1
  inst="$(_svc_rec_field "$rec" instance)"
  [[ -n "$inst" ]] || return 1
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    service_pid_carries_instance "$p" "$inst" && return 0
  done < <(service_listener_pids "$port")
  return 1
}

# service_restart_required <port> — rc 0 when a restart is PROVEN necessary.
# Unprovable is not proven: a missing revision on either side means we preserve
# (the reviewer's contract is "explicitly ephemeral, or a VERIFIED restart").
service_restart_required() {
  local port="${1:-}" rec rev_then rev_now rc=0
  rec="$(service_owner_record_path "$port")"
  [[ -r "$rec" ]] || return 1
  service_service_healthy "$port" || rc=$?
  [[ $rc -eq 1 ]] && return 0                 # unhealthy: restart is required
  rev_then="$(_svc_rec_field "$rec" revision)"
  rev_now="$(service_tree_revision)"
  if [[ -z "$rev_then" || -z "$rev_now" ]]; then
    # No revision on one side (a project outside git). Freshness cannot be
    # PROVEN stale, and the contract is "explicitly ephemeral, or a VERIFIED
    # restart" — so preserve, and say why, rather than guess either way.
    _svc_vlog "port $port: cannot verify the serving revision (no git tree hash) — preserving the running service; code-freshness enforcement needs a git working tree"
    return 1
  fi
  [[ "$rev_then" != "$rev_now" ]]
}

# service_release <port> <caller> — POLICY-aware cleanup, the verb the pipeline's
# between-step sweeps use. Ownership is still required to touch anything.
#   rc 0  the port is in an acceptable state to proceed: nothing of ours there,
#         a healthy current persistent service PRESERVED, or ours terminated.
#   rc 1  refused — a listener we cannot prove we own is still there.
service_release() {
  local port="${1:-}" caller="${2:-unknown}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 0

  local -a pids=()
  local p
  while IFS= read -r p; do [[ -n "$p" ]] && pids+=("$p"); done < <(service_listener_pids "$port")
  if [[ ${#pids[@]} -eq 0 ]]; then
    service_owner_terminate "$port" "$caller"        # handles records + invisible listeners
    return $?
  fi

  # Every listener must be ours before policy even becomes relevant.
  local verdict
  for p in "${pids[@]}"; do
    verdict="$(service_pid_ownership "$p")"
    case "$verdict" in
      MINE|DEAD|GONE) ;;
      *) service_owner_terminate "$port" "$caller"; return $? ;;   # reuses the refusal path
    esac
  done

  local rec lifecycle
  rec="$(service_owner_record_path "$port")"
  lifecycle=""
  if [[ -r "$rec" ]]; then
    if service_record_listener_bound "$port"; then
      lifecycle="$(_svc_rec_field "$rec" lifecycle)"
    else
      # The record describes a process that is no longer the one on this port.
      # Whatever is here now is NOT the registered application, so it inherits
      # none of its lifecycle or revision identity — it is an ephemeral
      # occupant we happen to own, and it is reaped. Drop the misleading record.
      _svc_log "port $port: the ownership record describes a service that is no longer the listener — treating the current process as ephemeral, not as the registered application."
      _svc_event "services_record_unbound" \
        "$(printf '{"port":%s,"caller":"%s"}' "$port" "$caller")"
      service_owner_release "$port"
    fi
  fi

  if [[ "$lifecycle" == "persistent" ]]; then
    if service_restart_required "$port"; then
      _svc_log "releasing the $( _svc_rec_field "$rec" role ) on port $port ($caller): a restart is required (unhealthy, or serving an older revision than the working tree)."
      _svc_event "services_released_for_restart" \
        "$(printf '{"port":%s,"caller":"%s"}' "$port" "$caller")"
      service_owner_terminate "$port" "$caller"
      return $?
    fi
    _svc_vlog "preserving the healthy application service on port $port ($caller) — ownership permits termination, lifecycle policy does not require it"
    _svc_event "services_preserved" \
      "$(printf '{"port":%s,"caller":"%s"}' "$port" "$caller")"
    return 0
  fi

  # Unrecorded but scope-owned (an agent's abandoned verification server), or an
  # explicitly ephemeral service: always reaped. This is the requirement the old
  # blind port sweep actually served.
  service_owner_terminate "$port" "$caller"
  return $?
}

# ── Project service contracts (runtime configuration) ────────────────────────
# Documentation does not export environment variables. `.claude/project-template.md`
# is sliced into agent PROMPTS and never sourced, so a contract declared only
# there never reaches the shell that has to enforce it. The supported mechanism
# is a small file the framework sources:
#
#     <project>/.claude/service-contracts.sh
#
# exporting CHAIN_SERVICE_VERIFY_<ROLE> and/or CHAIN_SERVICE_HEALTHY_<ROLE>.
# `templates/service-contracts.sh` is the starting point. Override the location
# with CHAIN_SERVICE_CONTRACTS_FILE. Values already present in the environment
# WIN — an operator or CI can always override the file for one invocation.
#
# It is shell, and it is sourced, so it carries the same trust as any other
# script in the project's own checkout. Idempotent; silent when absent.
service_contracts_load() {
  [[ -n "${_SERVICE_CONTRACTS_LOADED:-}" ]] && return 0
  local f="${CHAIN_SERVICE_CONTRACTS_FILE:-${REPO_ROOT:-$PWD}/.claude/service-contracts.sh}"
  _SERVICE_CONTRACTS_LOADED=1
  [[ -r "$f" ]] || return 0
  # Pre-existing environment wins: snapshot, source, restore anything that was
  # already set so an explicit override is never clobbered by the file.
  local -a names=() n prev
  while IFS= read -r n; do names+=("$n"); done < <(
    grep -oE 'CHAIN_SERVICE_(VERIFY|HEALTHY)_[A-Z0-9_]+' "$f" 2>/dev/null | sort -u)
  local -A kept=()
  for n in ${names[@]+"${names[@]}"}; do
    [[ -n "${!n:-}" ]] && kept["$n"]="${!n}"
  done
  # shellcheck source=/dev/null
  source "$f" || { _svc_log "WARNING: failed to load service contracts from $f"; return 1; }
  for n in "${!kept[@]}"; do export "$n=${kept[$n]}"; done
  _svc_vlog "service contracts loaded from $f (${#names[@]} declaration(s))"
  return 0
}

# ── Reuse verification ───────────────────────────────────────────────────────
# A 2xx (or any `ready_re` match) proves SOMETHING is listening. It does not
# prove it is the service we need, nor that it runs the revision under test.
#
# Contract: the project supplies CHAIN_SERVICE_VERIFY_<ROLE> (e.g.
# CHAIN_SERVICE_VERIFY_BACKEND). It is run with the response body on stdin and
# "<url> <port>" as arguments; exit 0 means "this is the expected service".
# Declare it in .claude/project-template.md so every run inherits it.
#
# rc 0 verified · 1 verifier ran and rejected · 2 no verifier configured.
service_verify_reuse() {
  local role="${1:-}" url="${2:-}" port="${3:-}"
  local var="CHAIN_SERVICE_VERIFY_$(printf '%s' "$role" | tr '[:lower:]-' '[:upper:]_')"
  local verifier="${!var:-}"
  [[ -n "$verifier" ]] || return 2
  curl -s --max-time "${CHAIN_HEALTH_PROBE_TIMEOUT:-10}" "$url" 2>/dev/null \
    | bash -c "$verifier" "verify-$role" "$url" "$port" >/dev/null 2>&1
}

# service_reuse_decision <role> <url> <port> [observed_status] — echoes
# REUSE | RESTART | BLOCKED. Called only when the endpoint is already answering.
service_reuse_decision() {
  local role="${1:-}" url="${2:-}" port="${3:-}" code="${4:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || { echo "REUSE"; return 0; }   # portless URL: as before

  local -a pids=()
  local p
  while IFS= read -r p; do [[ -n "$p" ]] && pids+=("$p"); done < <(service_listener_pids "$port")

  local ours=1
  if [[ ${#pids[@]} -eq 0 ]]; then
    ours=0                      # listening but invisible to us => not ours
  else
    for p in "${pids[@]}"; do
      case "$(service_pid_ownership "$p")" in
        MINE|DEAD|GONE) ;;
        *) ours=0; break ;;
      esac
    done
  fi

  if [[ $ours -eq 1 ]]; then
    local rec lifecycle
    rec="$(service_owner_record_path "$port")"
    lifecycle=""
    # Persistent metadata is only usable while the record still describes the
    # process actually listening — otherwise a replacement would be reused as
    # though it were the registered application at the registered revision.
    if [[ -r "$rec" ]] && service_record_listener_bound "$port"; then
      lifecycle="$(_svc_rec_field "$rec" lifecycle)"
    fi
    # Ours and registered as the managed service: reuse only when it is current.
    if [[ "$lifecycle" == "persistent" ]]; then
      if service_restart_required "$port"; then echo "RESTART"; else echo "REUSE"; fi
      return 0
    fi
    # Ours but never registered as a managed service (an agent leak that happens
    # to answer): we cannot vouch for its configuration or revision. Replace it.
    echo "RESTART"; return 0
  fi

  # Not ours. Identity and health are SEPARATE requirements and both must hold.
  # A verifier matches a marker in the body; a service can emit that marker in a
  # 500 error page, so passing identity alone would accept a broken dependency.
  # We cannot restart someone else's service, so failing either check is BLOCKED.
  [[ -n "$code" ]] || code=$(curl -s -o /dev/null \
      --max-time "${CHAIN_HEALTH_PROBE_TIMEOUT:-10}" -w "%{http_code}" "$url" 2>/dev/null || true)
  local hre; hre="$(service_health_regex "$role")"
  if ! [[ "$code" =~ $hre ]]; then
    _svc_vlog "external $role on port $port answered ${code:-none}, which does not satisfy the health contract ${hre}"
    echo "BLOCKED"; return 0
  fi
  service_verify_reuse "$role" "$url" "$port"
  case $? in
    0) echo "REUSE" ;;
    *) echo "BLOCKED" ;;
  esac
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
  # Each entry is "<pid>|<identity>|<scope>": the pid ALONE is not enough to act
  # on later. Capturing the identity and the ownership stamp here, and handing
  # both to the signaller, is what stops a process replaced between this check
  # and the signal from inheriting the decision made about its predecessor.
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

  # NOTE: the verdict above is advisory — it exists to produce a good refusal
  # message. The AUTHORITATIVE decision is made inside service_terminate_listener
  # against the pinned process, so nothing read here can be stale by the time the
  # signal is sent.
  local _p_pid _refused=0
  for _p_pid in ${owned[@]+"${owned[@]}"}; do
    if ! service_terminate_listener "$_p_pid" "${CHAIN_KILL_GRACE_SECONDS:-2}"; then
      _refused=$((_refused + 1))
      _svc_log "kill refused ($caller): pid $_p_pid on port $port no longer matches what was verified — it was replaced or recycled between the ownership check and the signal; nothing was signalled."
      _svc_event "services_kill_refused" \
        "$(printf '{"port":%s,"caller":"%s","pid":%s,"verdict":"REPLACED"}' "$port" "$caller" "$_p_pid")"
    fi
  done
  _svc_event "services_terminated" \
    "$(printf '{"port":%s,"caller":"%s","pids":%d,"refused":%d}' "$port" "$caller" "${#owned[@]}" "$_refused")"
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
