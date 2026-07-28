#!/usr/bin/env bash
# test-iter-budget.sh — SPEED-15 unit test: the wall-clock iteration budget
# (warn-first). Sourceable helpers live in lib/common.sh:
#   iter_budget_init [t0]      — clock origin (falls back to CHAIN_ITER_START_EPOCH)
#   iter_budget_exceeded       — true iff budget>0 and elapsed>budget
#   iter_budget_check <label>  — warn ONCE per process + iter_budget telemetry; never gates
#   iter_budget_trim_active    — true only in trim mode AND over budget
# Engine wiring is grep-asserted; the ladder must never touch developer/
# reviewer/evaluator dispatches (only showcase-class steps consult trim).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

source "$ENGINE_ROOT/scripts/automation/lib/common.sh"

# ── budget off (default) ─────────────────────────────────────────────────────
unset CHAIN_ITER_TIME_BUDGET_SECONDS CHAIN_ITER_BUDGET_MODE 2>/dev/null || true
iter_budget_init "$(( $(date +%s) - 9999 ))"
if iter_budget_exceeded; then
  assert "budget off (default 0) -> never exceeded" "fail"
else
  assert "budget off (default 0) -> never exceeded" "pass"
fi
err="$(iter_budget_check "step-x" 2>&1 >/dev/null)" || true
[[ -z "$err" ]] \
  && assert "budget off -> check is silent" "pass" \
  || assert "budget off -> check is silent (got '$err')" "fail"

# ── over budget: warn once, never gate ───────────────────────────────────────
export CHAIN_ITER_TIME_BUDGET_SECONDS=10
iter_budget_init "$(( $(date +%s) - 100 ))"
iter_budget_exceeded \
  && assert "elapsed 100s > budget 10s -> exceeded" "pass" \
  || assert "elapsed 100s > budget 10s -> exceeded" "fail"
# Bare calls (not $(...)): the warn-once flag must persist in THIS shell,
# exactly as the engine's bare call sites use it.
rc=0; iter_budget_check "goal-evaluator" 2>"$WORK/w1" || rc=$?
err="$(cat "$WORK/w1")"
[[ "$rc" -eq 0 ]] \
  && assert "check always returns 0 (signal, not gate)" "pass" \
  || assert "check always returns 0 (signal, not gate) (rc=$rc)" "fail"
echo "$err" | grep -q 'over the 10s budget' \
  && assert "first check warns loudly with the budget and step" "pass" \
  || assert "first check warns loudly (got '$err')" "fail"
iter_budget_check "coherence" 2>"$WORK/w2" || true
err2="$(cat "$WORK/w2")"
[[ -z "$err2" ]] \
  && assert "second check in the same process is silent (warn once)" "pass" \
  || assert "second check silent (got '$err2')" "fail"

# ── under budget ─────────────────────────────────────────────────────────────
iter_budget_init "$(date +%s)"
if iter_budget_exceeded; then
  assert "fresh iteration under budget -> not exceeded" "fail"
else
  assert "fresh iteration under budget -> not exceeded" "pass"
fi

# ── trim consult ─────────────────────────────────────────────────────────────
iter_budget_init "$(( $(date +%s) - 100 ))"
export CHAIN_ITER_BUDGET_MODE=warn
if iter_budget_trim_active; then
  assert "warn mode -> trim never active even over budget" "fail"
else
  assert "warn mode -> trim never active even over budget" "pass"
fi
export CHAIN_ITER_BUDGET_MODE=trim
iter_budget_trim_active \
  && assert "trim mode + over budget -> trim active" "pass" \
  || assert "trim mode + over budget -> trim active" "fail"
export CHAIN_ITER_TIME_BUDGET_SECONDS=0
if iter_budget_trim_active; then
  assert "trim mode with budget off -> inactive" "fail"
else
  assert "trim mode with budget off -> inactive" "pass"
fi
unset CHAIN_ITER_TIME_BUDGET_SECONDS CHAIN_ITER_BUDGET_MODE

# ── child-process origin (CHAIN_ITER_START_EPOCH) ────────────────────────────
export CHAIN_ITER_START_EPOCH="$(( $(date +%s) - 500 ))"
export CHAIN_ITER_TIME_BUDGET_SECONDS=10
iter_budget_init
iter_budget_exceeded \
  && assert "init without args reads exported CHAIN_ITER_START_EPOCH" "pass" \
  || assert "init without args reads exported CHAIN_ITER_START_EPOCH" "fail"
unset CHAIN_ITER_START_EPOCH CHAIN_ITER_TIME_BUDGET_SECONDS

# ── engine wiring ────────────────────────────────────────────────────────────
RG="$ENGINE_ROOT/scripts/automation/run-goal.sh"
grep -q 'export CHAIN_ITER_START_EPOCH' "$RG" \
  && assert "wiring: engine exports the iteration start epoch" "pass" \
  || assert "wiring: engine exports the iteration start epoch" "fail"
grep -q 'iter_budget_check "goal-evaluator"' "$RG" \
  && assert "wiring: boundary check before the evaluator" "pass" \
  || assert "wiring: boundary check before the evaluator" "fail"
grep -q 'iter_budget_check "coherence-auditor"' "$RG" \
  && assert "wiring: boundary check before the coherence step" "pass" \
  || assert "wiring: boundary check before the coherence step" "fail"
grep -q 'iter_budget_trim_active' "$RG" \
  && assert "wiring: showcase tail consults trim mode" "pass" \
  || assert "wiring: showcase tail consults trim mode" "fail"
LEAN="$ENGINE_ROOT/scripts/automation/goal-iter-lean.sh"
grep -q 'iter_budget_check "browser-qa"' "$LEAN" \
  && assert "wiring: boundary check before the browser-qa section" "pass" \
  || assert "wiring: boundary check before the browser-qa section" "fail"
# The trim ladder must never gate the spine: no trim consult may guard the
# developer/reviewer/evaluator dispatches.
if grep -nE 'iter_budget_(trim_active|exceeded)' "$RG" "$LEAN" | grep -qiE 'developer|reviewer|evaluator'; then
  assert "safety: trim never guards developer/reviewer/evaluator" "fail"
else
  assert "safety: trim never guards developer/reviewer/evaluator" "pass"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
