#!/usr/bin/env bash
# test-iter-budget.sh — SPEED-15 unit test: the wall-clock iteration budget
# (armed by default: 3600s / trim). Sourceable helpers live in lib/common.sh:
#   iter_budget_init [t0]      — clock origin (falls back to CHAIN_ITER_START_EPOCH)
#   iter_budget_exceeded       — true iff budget>0 and elapsed>budget (default 3600)
#   iter_budget_check <label>  — warn ONCE per process + iter_budget telemetry; never gates
#   iter_budget_trim_active    — true only in trim mode (the default) AND over budget
#   iter_budget_trim_event <r> — telemetry per fired trim rung
# Engine wiring is grep-asserted; the trim ladder must never touch developer/
# reviewer/evaluator/QA/audit dispatches (only optional-breadth steps consult
# trim). Rollback: CHAIN_ITER_TIME_BUDGET_SECONDS=0 disarms; mode=warn keeps
# warnings only.
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

# ── armed by default (3600s / trim) ──────────────────────────────────────────
unset CHAIN_ITER_TIME_BUDGET_SECONDS CHAIN_ITER_BUDGET_MODE 2>/dev/null || true
iter_budget_init "$(( $(date +%s) - 9999 ))"
if iter_budget_exceeded; then
  assert "default budget (3600) -> 9999s elapsed IS exceeded (armed by default)" "pass"
else
  assert "default budget (3600) -> 9999s elapsed IS exceeded (armed by default)" "fail"
fi
if iter_budget_trim_active; then
  assert "default mode is trim -> trim active when over budget" "pass"
else
  assert "default mode is trim -> trim active when over budget" "fail"
fi
iter_budget_init "$(( $(date +%s) - 100 ))"
if iter_budget_exceeded; then
  assert "default budget (3600) -> 100s elapsed is under budget" "fail"
else
  assert "default budget (3600) -> 100s elapsed is under budget" "pass"
fi

# ── explicit 0 disarms everything (the rollback) ─────────────────────────────
export CHAIN_ITER_TIME_BUDGET_SECONDS=0
iter_budget_init "$(( $(date +%s) - 9999 ))"
if iter_budget_exceeded; then
  assert "budget=0 (rollback) -> never exceeded" "fail"
else
  assert "budget=0 (rollback) -> never exceeded" "pass"
fi
err="$(iter_budget_check "step-x" 2>&1 >/dev/null)" || true
[[ -z "$err" ]] \
  && assert "budget=0 -> check is silent" "pass" \
  || assert "budget=0 -> check is silent (got '$err')" "fail"
unset CHAIN_ITER_TIME_BUDGET_SECONDS

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

# ── run-phase.sh wiring (trim rungs 3a/3b + warn checks) ─────────────────────
RP="$ENGINE_ROOT/scripts/automation/run-phase.sh"
grep -q 'CHAIN_ITER_START_EPOCH:-}" ]]; then iter_budget_init' "$RP" \
  && assert "wiring: run-phase inits the clock ONLY under a goal iteration" "pass" \
  || assert "wiring: run-phase inits the clock ONLY under a goal iteration" "fail"
grep -q 'iter_budget_check "qa-loop"' "$RP" \
  && assert "wiring: run-phase warn check before the QA loop" "pass" \
  || assert "wiring: run-phase warn check before the QA loop" "fail"
grep -q 'iter_budget_check "audit"' "$RP" \
  && assert "wiring: run-phase warn check before the audit loop" "pass" \
  || assert "wiring: run-phase warn check before the audit loop" "fail"
grep -q 'iter-budget trim rung 3a' "$RP" \
  && assert "wiring: rung 3a (test-plan skip) present" "pass" \
  || assert "wiring: rung 3a (test-plan skip) present" "fail"
grep -q 'UX-REGRESSION-SKIPPED' "$RP" \
  && assert "wiring: rung 3b writes a SKIPPED (never FAIL) stub" "pass" \
  || assert "wiring: rung 3b writes a SKIPPED (never FAIL) stub" "fail"

# ── rung 2 wiring (replay-lane narrowing + deferred rows, both depths) ───────
RL="$ENGINE_ROOT/scripts/automation/lib/replay-lane.sh"
BQAP="$ENGINE_ROOT/scripts/automation/browser-qa-phase.sh"
grep -q 'replay_lane_deferred_budget_set' "$RL" \
  && assert "wiring: rung-2 decision helper lives in the shared lane lib" "pass" \
  || assert "wiring: rung-2 decision helper lives in the shared lane lib" "fail"
grep -q 'DEFERRED-BUDGET' "$RL" \
  && assert "wiring: deferred rows carry the DEFERRED-BUDGET verdict cell" "pass" \
  || assert "wiring: deferred rows carry the DEFERRED-BUDGET verdict cell" "fail"
grep -q 'replay_lane_write_deferred_rows "$UI_TEST_RESULTS"' "$LEAN" \
  && assert "wiring: lean merge site appends deferred rows" "pass" \
  || assert "wiring: lean merge site appends deferred rows" "fail"
grep -q 'replay_lane_write_deferred_rows "$UI_TEST_RESULTS"' "$BQAP" \
  && assert "wiring: full-depth merge site appends deferred rows" "pass" \
  || assert "wiring: full-depth merge site appends deferred rows" "fail"
grep -q 'iter_budget_init' "$BQAP" \
  && assert "wiring: browser-qa-phase picks up the engine clock" "pass" \
  || assert "wiring: browser-qa-phase picks up the engine clock" "fail"
grep -q 'DEFERRED-BUDGET' "$ENGINE_ROOT/scripts/automation/lib/goal_gate.py" \
  && assert "wiring: achievement gate blocks on DEFERRED-BUDGET rows" "pass" \
  || assert "wiring: achievement gate blocks on DEFERRED-BUDGET rows" "fail"
grep -q 'DEFERRED-BUDGET' "$ENGINE_ROOT/agents/goal-evaluator/body.md" \
  && grep -q 'DEFERRED-BUDGET' "$ENGINE_ROOT/skills/goal-evaluation-methodology.md" \
  && assert "wiring: evaluator contract (body + methodology) covers DEFERRED-BUDGET" "pass" \
  || assert "wiring: evaluator contract (body + methodology) covers DEFERRED-BUDGET" "fail"

# The trim ladder must never gate the spine: no trim consult may guard the
# developer/reviewer/evaluator dispatches (RG/LEAN) nor the dev/review/qa/
# audit/closure phase dispatches (RP).
if grep -nE 'iter_budget_(trim_active|exceeded)' "$RG" "$LEAN" | grep -qiE 'developer|reviewer|evaluator'; then
  assert "safety: trim never guards developer/reviewer/evaluator" "fail"
else
  assert "safety: trim never guards developer/reviewer/evaluator" "pass"
fi
if grep -nE 'iter_budget_(trim_active|exceeded)' "$RP" | grep -qiE 'dev-phase|review-phase|qa-phase|audit-phase|closure'; then
  assert "safety: run-phase trim never guards dev/review/qa/audit/closure" "fail"
else
  assert "safety: run-phase trim never guards dev/review/qa/audit/closure" "pass"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
