#!/usr/bin/env bash
# engine-identity.sh — process identity primitives (HARD-4A, sub-commit A0).
#
# A pid is not an identity. After a machine reset the box comes back with the
# same pid space, and within one boot pids recycle, so a recorded pid can point
# at an innocent live process. The identity of a process is the triple
#
#     <pid> . <proc starttime> . <boot id prefix>
#
# which is exactly the model lib/host-guard-registry.sh already uses for its
# holder records (hg_record_is_live) and lib/engine-lock.sh uses for boot-id
# staleness. This file factors that triple into a token so later packages can
# say "mine" vs "a dead engine's" about anything the engine spawned.
#
# Deliberately NOT an identity source: a command line. Matching a whole
# /proc/<pid>/cmdline for a program name is anti-pattern 30 — the haystack
# contains config paths and wrapper boilerplate, and the shortest-lived
# candidate wins. Identity here comes only from procfs facts the process
# cannot accidentally impersonate.
#
# Dependency-free (bash + procfs + coreutils) and safe to re-source: every
# definition is idempotent and nothing here has side effects at source time.
#
# Scope note: HARD-4A's second sub-commit (A1 — run-goal.sh prologue reorder,
# lock-before-mutation ordering, owner-guarded engine.pid, signal-time takeover
# revalidation) is NOT implemented here. A0 is a pure addition and is the only
# part HARD-5 depends on.

# Re-source guard: keep the exported token stable across nested sources.
if [[ -n "${_ENGINE_IDENTITY_SOURCED:-}" ]]; then return 0 2>/dev/null || true; fi
_ENGINE_IDENTITY_SOURCED=1

# First 8 hex of the kernel boot id. Changes on every reboot, so a record from a
# previous boot can never be mistaken for a live one. Empty on a host without
# procfs — callers treat an empty boot id as "unprovable", never as "matching".
_engine_boot8() { cut -c1-8 /proc/sys/kernel/random/boot_id 2>/dev/null; }

# Field 22 of /proc/<pid>/stat (starttime, in clock ticks since boot). The
# `sed 's/.*) //'` strips the comm field, which may itself contain spaces and
# parentheses — same idiom as host-guard-registry.sh:_hg_proc_starttime. After
# the strip, starttime is field 20. Empty for a dead/unreadable pid.
_engine_starttime() {
  sed 's/.*) //' "/proc/${1:-$$}/stat" 2>/dev/null | awk '{print $20}'
}

# engine_token_mint [pid] — the identity token for a pid, or "" when procfs
# cannot supply the facts (never a partial token: an unprovable identity must
# not masquerade as a provable one).
engine_token_mint() {
  local p="${1:-$$}" s b
  s="$(_engine_starttime "$p")"
  b="$(_engine_boot8)"
  if [[ -n "$s" && -n "$b" ]]; then echo "$p.$s.$b"; else echo ""; fi
}

# engine_token_alive <token> — rc 0 when the token's process is alive OR its
# liveness cannot be disproven; rc 1 ONLY when it is provably dead, with the
# reason on stdout.
#
# The asymmetry is deliberate and is the safety posture of this whole layer
# (same as engine_lock_classify): "alive" is the conservative answer. A caller
# uses rc 1 to justify reclaiming a resource, so rc 1 must require proof. An
# empty or malformed token is unprovable => rc 0 => nothing is reclaimed.
engine_token_alive() {
  local t="${1:-}" pid stt boot cur now
  IFS=. read -r pid stt boot <<< "$t"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0          # unparseable => unprovable
  cur="$(_engine_boot8)"
  if [[ -n "$boot" && -n "$cur" && "$boot" != "$cur" ]]; then
    echo "recorded in a previous boot"; return 1
  fi
  if ! kill -0 "$pid" 2>/dev/null && [[ ! -e "/proc/$pid" ]]; then
    echo "pid $pid is dead"; return 1
  fi
  now="$(_engine_starttime "$pid")"
  if [[ -n "$stt" && -n "$now" && "$stt" != "$now" ]]; then
    echo "pid $pid recycled"; return 1
  fi
  return 0
}

# engine_token_self — this process's token, preferring an inherited one so every
# script in one engine's tree reports the SAME identity.
engine_token_self() { echo "${CHAIN_ENGINE_TOKEN:-$(engine_token_mint "$$")}"; }

# engine_proc_env <pid> <name> — the value of one variable in a process's LAUNCH
# environment (/proc/<pid>/environ, NUL-separated), or "" when absent.
# rc 0 = environ was read (empty output means "not set"); rc 2 = NOT readable
# (no such pid, another user's process, a zombie, or no procfs).
#
# This is the one honest way to ask "was this process started by us?": environ
# is inherited across fork AND exec, so a stamp placed in a launcher's
# environment is present on every descendant — including ones reparented to init
# after their launcher died — and is absent from an unrelated process that
# merely recycled the pid.
engine_proc_env() {
  local pid="${1:-}" name="${2:-}"
  [[ "$pid" =~ ^[0-9]+$ && -n "$name" ]] || return 2
  [[ -r "/proc/$pid/environ" ]] || return 2
  local val
  val="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n "s/^${name}=//p" | head -n1)" || return 2
  printf '%s' "$val"
  return 0
}
