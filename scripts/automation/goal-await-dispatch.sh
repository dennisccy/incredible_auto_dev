#!/usr/bin/env bash
# goal-await-dispatch.sh — pump-side helper for the interactive dispatch backend.
#
# The "pump" is the foreground Claude Code session running /goal. It launches the
# goal-mode engine (run-goal.sh --interactive) in the background, then repeatedly
# calls this helper. Each call BLOCKS until either:
#   - one or more UNANSWERED requests are published in the dispatch dir, in which
#     case it prints their file paths (one per line) and exits 0; or
#   - the engine process has exited and nothing is left to service, in which case
#     it prints "ENGINE_DONE" and exits 0.
#
# Each poll touches the pump heartbeat (.pump-alive) so the engine's
# _interactive_invoke (lib/interactive-dispatch.sh) knows the pump is alive and
# does not abort dispatches while the pump is merely waiting.
#
# The pump then, for each printed request path R:
#   - reads R (JSON: {agent, prompt, cwd, res_path})
#   - dispatches subagent_type=<agent> with <prompt> verbatim (no model override)
#   - writes the subagent's exit code to "${R%.ready}.res"
# and calls this helper again. See skills/goal-interactive-dispatch.md.
#
# Usage:
#   goal-await-dispatch.sh --dispatch-dir <dir> --engine-pid <pid> [--poll <secs>]
#   goal-await-dispatch.sh --self-test
set -euo pipefail

# ── Self-test (no engine, no blocking) ────────────────────────────────────────
if [[ "${1:-}" == "--self-test" ]]; then
  t=$(mktemp -d); fails=0
  # A guaranteed-dead pid: spawn a no-op, reap it.
  ( exit 0 ) & deadpid=$!; wait "$deadpid" 2>/dev/null || true

  # Scenario 1: engine gone, nothing pending → ENGINE_DONE
  out=$("$0" --dispatch-dir "$t" --engine-pid "$deadpid" --poll 1 2>/dev/null || true)
  if [[ "$out" == "ENGINE_DONE" ]]; then echo "  PASS await: engine-done → ENGINE_DONE"; else echo "  FAIL await: engine-done (got '$out')"; fails=1; fi

  # Scenario 2: an unanswered ready request is listed
  r="$t/req.aaaaaa.ready"; printf '{"agent":"developer","prompt":"x"}\n' > "$r"
  out=$("$0" --dispatch-dir "$t" --engine-pid "$$" --poll 1 2>/dev/null || true)
  if [[ "$out" == "$r" ]]; then echo "  PASS await: lists unanswered request"; else echo "  FAIL await: lists pending (got '$out')"; fails=1; fi

  # Scenario 3: an ALREADY-answered ready request (has a .res sibling) is skipped,
  # so with the engine gone it reports ENGINE_DONE rather than re-listing it.
  echo 0 > "${r%.ready}.res"
  out=$("$0" --dispatch-dir "$t" --engine-pid "$deadpid" --poll 1 2>/dev/null || true)
  if [[ "$out" == "ENGINE_DONE" ]]; then echo "  PASS await: skips already-answered request"; else echo "  FAIL await: skips answered (got '$out')"; fails=1; fi

  # Scenario 4: live engine, no UNANSWERED request (the one from scenario 2 now
  # has a .res), and --max-wait elapses → WAITING. Also proves --max-wait is a
  # recognized arg (not "Unknown argument").
  out=$("$0" --dispatch-dir "$t" --engine-pid "$$" --poll 1 --max-wait 1 2>/dev/null || true)
  if [[ "$out" == "WAITING" ]]; then echo "  PASS await: --max-wait elapsed → WAITING"; else echo "  FAIL await: max-wait (got '$out')"; fails=1; fi

  # Heartbeat file is created.
  if [[ -f "$t/.pump-alive" ]]; then echo "  PASS await: touches pump heartbeat"; else echo "  FAIL await: no heartbeat"; fails=1; fi

  rm -rf "$t"
  [[ "$fails" -eq 0 ]] && echo "goal-await-dispatch self-test: OK" || echo "goal-await-dispatch self-test: FAILED"
  exit "$fails"
fi

# ── Normal mode ───────────────────────────────────────────────────────────────
DIR=""; PID=""; POLL=1; MAXWAIT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dispatch-dir) DIR="$2"; shift 2 ;;
    --engine-pid)   PID="$2"; shift 2 ;;
    --poll)         POLL="$2"; shift 2 ;;
    --max-wait)     MAXWAIT="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$DIR" ]] || { echo "ERROR: --dispatch-dir is required" >&2; exit 2; }

# Print unanswered ready requests (a .ready file with no .res sibling yet).
_list_pending() {
  local f
  for f in "$DIR"/req.*.ready; do
    [[ -e "$f" ]] || continue
    [[ -e "${f%.ready}.res" ]] && continue
    printf '%s\n' "$f"
  done
}

# Branch priority inside the loop: pending > ENGINE_DONE > WAITING > sleep, so a
# request that appears at the last moment is always returned, never masked by the
# bounded-wait sentinel.
START_EPOCH=$(date +%s)
while true; do
  touch "$DIR/.pump-alive" 2>/dev/null || true
  pending="$(_list_pending)"
  if [[ -n "$pending" ]]; then
    printf '%s\n' "$pending"
    exit 0
  fi
  if [[ -n "$PID" ]] && ! kill -0 "$PID" 2>/dev/null; then
    # Engine gone — re-check once for a publish/exit race, then declare done.
    pending="$(_list_pending)"
    if [[ -n "$pending" ]]; then printf '%s\n' "$pending"; exit 0; fi
    echo "ENGINE_DONE"
    exit 0
  fi
  # Bounded foreground wait: when --max-wait is set and elapses with the engine
  # still alive and nothing pending, hand control back to the pump so it can
  # re-call deterministically (no background job for the pump to poll). 0 = block
  # forever (the original behavior).
  if [[ "$MAXWAIT" -gt 0 ]] && (( $(date +%s) - START_EPOCH >= MAXWAIT )); then
    echo "WAITING"
    exit 0
  fi
  sleep "$POLL"
done
