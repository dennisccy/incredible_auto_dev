#!/usr/bin/env bash
# parallel.sh — run two phase-step branches concurrently with prefixed,
# interleaved log output and a single aggregated exit code.
#
# Used by run-phase.sh's post-dev fanout: Branch A (UI chain
# ui-impact → ui-test-design → browser-qa → demo) runs in parallel with
# Branch B (qa-validate).
#
# Contract:
#
#   parallel_run <label-A> <cmd-A...> -- <label-B> <cmd-B...>
#
# Both commands run as background jobs whose stdout/stderr are piped through
# `sed` to receive a `[<label>]` prefix on every line. The parent waits for
# both, captures their exit codes, and:
#
#   - Signal exit (130 SIGINT, 137 SIGKILL, 143 SIGTERM): if either child
#     exits with a signal code, the parent forwards SIGTERM to the other,
#     waits, and exits with the same signal code so run-phase.sh's outer
#     retry-loop signal guard can abort cleanly.
#   - Quota exhaustion (exit 75): if either child exits 75, the parent exits
#     75 immediately so the outer quota loop can sleep + retry the whole
#     fanout.
#   - Soft failures: any other non-zero exit on either child is reported as a
#     warning. The parent exit code is the WORSE of the two children's exit
#     codes (0 ≪ other non-zero). The CALLER decides whether soft failures
#     halt the pipeline or are treated as "continue with warning" (matches
#     the existing non-blocking pattern for Step 6.5 demo / Step 10.5
#     summarizer).
#
# Reading the prefixed output: lines are interleaved as they arrive — this is
# fine for showcase / progress watchers; the per-branch artifacts (handoffs,
# reports) capture the authoritative output regardless. If a clean per-branch
# log is needed for debugging, tee the parent's stdout into a file and grep
# by prefix.

# Forward SIGTERM/SIGINT to a list of PIDs (best-effort).
_parallel_kill_children() {
  local sig="${1:-TERM}"; shift
  local pid
  for pid in "$@"; do
    [[ -z "$pid" ]] && continue
    if kill -0 "$pid" 2>/dev/null; then
      kill -"$sig" "$pid" 2>/dev/null || true
    fi
  done
}

# NOTE: `wait` MUST run in the same shell as the one that backgrounded the
# job. Calling `wait` inside `$( ... )` puts it in a subshell where the PID
# is not a child, and wait returns 127 (or 255 in some bash builds). So the
# caller below uses plain `wait $pid; rc=$?` directly.

# parallel_run <label-A> <cmd-A...> -- <label-B> <cmd-B...>
# Returns the aggregated exit code (worse of the two children).
parallel_run() {
  local label_a label_b
  local -a cmd_a=() cmd_b=()
  local seen_sep=false

  label_a="$1"; shift
  if [[ -z "$label_a" ]]; then
    echo "[parallel] usage: parallel_run <label-A> <cmd-A...> -- <label-B> <cmd-B...>" >&2
    return 2
  fi
  # Gather command-A tokens until the literal `--` separator.
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--" ]]; then
      seen_sep=true
      shift
      break
    fi
    cmd_a+=("$1")
    shift
  done
  if ! $seen_sep; then
    echo "[parallel] missing '--' separator between branch commands" >&2
    return 2
  fi
  label_b="$1"; shift
  if [[ -z "$label_b" ]]; then
    echo "[parallel] missing label for branch B" >&2
    return 2
  fi
  cmd_b=("$@")
  if [[ ${#cmd_a[@]} -eq 0 || ${#cmd_b[@]} -eq 0 ]]; then
    echo "[parallel] both branches need at least one command token" >&2
    return 2
  fi

  echo "[parallel] launching: [$label_a] '${cmd_a[*]}' || [$label_b] '${cmd_b[*]}'"

  # Stamp lines with the branch label. `sed -u` keeps output unbuffered so
  # progress lines arrive interleaved in (roughly) real time.
  # The subshell explicitly exits with ${PIPESTATUS[0]} so the command's exit
  # status (not sed's) is what the parent's `wait` sees.
  local pid_a pid_b
  ( "${cmd_a[@]}" 2>&1 | sed -u "s|^|[$label_a] |"; exit "${PIPESTATUS[0]}" ) &
  pid_a=$!
  ( "${cmd_b[@]}" 2>&1 | sed -u "s|^|[$label_b] |"; exit "${PIPESTATUS[0]}" ) &
  pid_b=$!

  # Trap parent signals → forward to both branches and exit with the signal
  # code so the outer retry loop can detect a clean signal abort.
  local _forwarded_signal=""
  _parallel_forward_term() { _forwarded_signal="TERM"; _parallel_kill_children TERM "$pid_a" "$pid_b"; }
  _parallel_forward_int()  { _forwarded_signal="INT";  _parallel_kill_children TERM "$pid_a" "$pid_b"; }
  trap _parallel_forward_term TERM
  trap _parallel_forward_int  INT

  local rc_a=0 rc_b=0
  wait "$pid_a" 2>/dev/null || rc_a=$?
  wait "$pid_b" 2>/dev/null || rc_b=$?

  trap - TERM INT

  # Signal-induced exit: propagate the signal code so the outer retry sees a
  # clean abort and re-runs the in-flight step on resume. Mirrors the policy
  # used by browser-qa-phase.sh and run-phase.sh's _is_signal_exit.
  local rc
  if [[ -n "$_forwarded_signal" ]]; then
    case "$_forwarded_signal" in
      INT)  rc=130 ;;
      TERM) rc=143 ;;
      *)    rc=137 ;;
    esac
    echo "[parallel] forwarded signal=$_forwarded_signal — exiting $rc" >&2
    return "$rc"
  fi
  if [[ "$rc_a" -eq 130 || "$rc_a" -eq 137 || "$rc_a" -eq 143 ]]; then
    echo "[parallel] [$label_a] killed by signal (exit $rc_a) — forwarding to [$label_b] and aborting." >&2
    _parallel_kill_children TERM "$pid_b"
    wait "$pid_b" 2>/dev/null || true
    return "$rc_a"
  fi
  if [[ "$rc_b" -eq 130 || "$rc_b" -eq 137 || "$rc_b" -eq 143 ]]; then
    echo "[parallel] [$label_b] killed by signal (exit $rc_b) — forwarding to [$label_a] and aborting." >&2
    _parallel_kill_children TERM "$pid_a"
    wait "$pid_a" 2>/dev/null || true
    return "$rc_b"
  fi

  # Quota exhaustion (75): propagate immediately so run-phase.sh's outer
  # _run_step quota guard sleeps + retries the whole fanout.
  local _quota=${QUOTA_EXHAUSTED_EXIT_CODE:-75}
  if [[ "$rc_a" -eq "$_quota" || "$rc_b" -eq "$_quota" ]]; then
    echo "[parallel] quota exhaustion detected ([$label_a]=$rc_a [$label_b]=$rc_b) — exiting $_quota" >&2
    return "$_quota"
  fi

  # Soft failures: print a one-line summary and return the worse exit code.
  if [[ "$rc_a" -ne 0 || "$rc_b" -ne 0 ]]; then
    echo "[parallel] branch exit codes: [$label_a]=$rc_a [$label_b]=$rc_b" >&2
    if [[ "$rc_a" -ge "$rc_b" ]]; then
      return "$rc_a"
    else
      return "$rc_b"
    fi
  fi

  echo "[parallel] both branches completed cleanly: [$label_a]=0 [$label_b]=0"
  return 0
}

# Quick self-check (only runs when this script is invoked directly).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    self-test)
      echo "parallel_run self-test"
      # Two successful branches in parallel.
      if parallel_run A bash -c 'sleep 0.1; echo "A done"; exit 0' \
                   -- B bash -c 'sleep 0.05; echo "B done"; exit 0'; then
        echo "  OK: both-success"
      else
        echo "  FAIL: both-success exited $?"
        exit 1
      fi
      # A fails (soft, exit 5), B ok — should return 5.
      _rc=0
      parallel_run A bash -c 'exit 5' -- B bash -c 'true' || _rc=$?
      if [[ "$_rc" -eq 5 ]]; then
        echo "  OK: soft-fail-A returned 5"
      else
        echo "  FAIL: soft-fail-A returned $_rc, expected 5"
        exit 1
      fi
      # A exits 75 quota — should return 75.
      _rc=0
      parallel_run A bash -c 'exit 75' -- B bash -c 'sleep 0.05; true' || _rc=$?
      if [[ "$_rc" -eq 75 ]]; then
        echo "  OK: quota-propagates returned 75"
      else
        echo "  FAIL: quota-propagates returned $_rc, expected 75"
        exit 1
      fi
      echo "self-test passed"
      ;;
    *)
      echo "Usage: $0 self-test" >&2
      echo "       source $0 ; parallel_run <label> <cmd...> -- <label> <cmd...>" >&2
      exit 2
      ;;
  esac
fi
