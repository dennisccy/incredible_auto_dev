#!/usr/bin/env bash
# test-depth-cadence.sh — SPEED-4 unit test: the hardening-cadence machinery
# that keeps the sharpened lean-first depth rubric honest.
#
# Logic under test lives in lib/common.sh (sourceable, like test-github-preflight):
#   goal_lean_streak <session_dir> <current_iter>
#     -> echoes the count of consecutive trailing `lean` values in
#        iter-(N-1)..iter-1 depth-dispatched files (missing file or any other
#        value breaks the streak; iter-0 baseline never counted).
#   goal_cadence_forces_full <streak> <current_iter>
#     -> true iff K>0 && current_iter>K && streak>=K, K=CHAIN_HARDENING_CADENCE
#        (default 4, 0 disables).
# The streak is recomputed from idempotent per-iteration files every pass, so a
# resumed/re-entered iteration cannot double-count (covered by re-running the
# same computation twice below).
#
# Wiring + rubric are grep-asserted: run-goal.sh must inline the streak into
# the decomposer prompt, log + telemeter the backstop override, and write
# depth-dispatched in every dispatch branch; the decomposer rubric must carry
# the numbered-trigger form and must NOT retain the old "requires new tests
# beyond browser smoke" full trigger (the bug that sent every iteration full).
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
unset CHAIN_HARDENING_CADENCE || true

SDIR="$WORK/goal-session-x"
seed_depths() {  # seed_depths <iter1> <iter2> ... (value per iter, "-" = no file)
  rm -rf "$SDIR"; mkdir -p "$SDIR"
  local i=1 v
  for v in "$@"; do
    mkdir -p "$SDIR/iter-$i"
    [[ "$v" != "-" ]] && printf '%s' "$v" > "$SDIR/iter-$i/depth-dispatched"
    i=$((i + 1))
  done
}

# ── goal_lean_streak ──────────────────────────────────────────────────────────
seed_depths lean lean lean lean
val=$(goal_lean_streak "$SDIR" 5 2>/dev/null || true)
[[ "$val" == "4" ]] \
  && assert "streak: 4 trailing leans from iter-5 -> 4" "pass" \
  || assert "streak: 4 trailing leans from iter-5 -> 4 (got '$val')" "fail"

seed_depths lean lean full lean
val=$(goal_lean_streak "$SDIR" 5 2>/dev/null || true)
[[ "$val" == "1" ]] \
  && assert "streak: full at iter-3 resets -> 1" "pass" \
  || assert "streak: full at iter-3 resets -> 1 (got '$val')" "fail"

seed_depths lean lean lean -
val=$(goal_lean_streak "$SDIR" 5 2>/dev/null || true)
[[ "$val" == "0" ]] \
  && assert "streak: missing iter-4 file breaks the streak -> 0" "pass" \
  || assert "streak: missing iter-4 file breaks the streak -> 0 (got '$val')" "fail"

seed_depths lean
val=$(goal_lean_streak "$SDIR" 1 2>/dev/null || true)
[[ "$val" == "0" ]] \
  && assert "streak: current_iter=1 has no prior iters (iter-0 never counted) -> 0" "pass" \
  || assert "streak: current_iter=1 has no prior iters -> 0 (got '$val')" "fail"

seed_depths lean lean lean lean
v1=$(goal_lean_streak "$SDIR" 5 2>/dev/null || true)
v2=$(goal_lean_streak "$SDIR" 5 2>/dev/null || true)
[[ "$v1" == "$v2" && -n "$v1" ]] \
  && assert "streak: recompute on resume re-entry is idempotent" "pass" \
  || assert "streak: recompute on resume re-entry is idempotent (got '$v1'/'$v2')" "fail"

# ── goal_cadence_forces_full ──────────────────────────────────────────────────
cadence() {  # cadence <K-or-""> <streak> <iter> -> yes|no
  local k="$1" s="$2" i="$3"
  if env_k="$k" bash -c '
      set -euo pipefail
      source "'"$ENGINE_ROOT"'/scripts/automation/lib/common.sh"
      [[ -n "${env_k}" ]] && export CHAIN_HARDENING_CADENCE="${env_k}"
      goal_cadence_forces_full "'"$s"'" "'"$i"'"' 2>/dev/null; then
    echo yes
  else
    echo no
  fi
}

[[ "$(cadence "" 4 5)" == "yes" ]] \
  && assert "cadence: default K=4, streak=4, iter=5 -> forces full" "pass" \
  || assert "cadence: default K=4, streak=4, iter=5 -> forces full" "fail"
[[ "$(cadence "" 3 5)" == "no" ]] \
  && assert "cadence: streak=3 < K=4 -> no override" "pass" \
  || assert "cadence: streak=3 < K=4 -> no override" "fail"
[[ "$(cadence "" 4 4)" == "no" ]] \
  && assert "cadence: current_iter must exceed K (iter=4, K=4) -> no override" "pass" \
  || assert "cadence: current_iter must exceed K (iter=4, K=4) -> no override" "fail"
[[ "$(cadence 0 9 10)" == "no" ]] \
  && assert "cadence: CHAIN_HARDENING_CADENCE=0 disables" "pass" \
  || assert "cadence: CHAIN_HARDENING_CADENCE=0 disables" "fail"
[[ "$(cadence 2 2 3)" == "yes" ]] \
  && assert "cadence: K=2, streak=2, iter=3 -> forces full" "pass" \
  || assert "cadence: K=2, streak=2, iter=3 -> forces full" "fail"

# ── run-goal.sh wiring ────────────────────────────────────────────────────────
RG="$ENGINE_ROOT/scripts/automation/run-goal.sh"
grep -q 'Consecutive lean iterations dispatched:' "$RG" \
  && assert "wiring: decomposer prompt carries the lean-streak line" "pass" \
  || assert "wiring: decomposer prompt carries the lean-streak line" "fail"
grep -q 'Hardening cadence:' "$RG" \
  && assert "wiring: backstop override logs loudly" "pass" \
  || assert "wiring: backstop override logs loudly" "fail"
grep -q 'depth_cadence_override' "$RG" \
  && assert "wiring: override records a telemetry event" "pass" \
  || assert "wiring: override records a telemetry event" "fail"
[[ "$(grep -c 'depth-dispatched' "$RG" || true)" -ge 3 ]] \
  && assert "wiring: depth-dispatched written in the dispatch branches (full/fallback/lean)" "pass" \
  || assert "wiring: depth-dispatched written in the dispatch branches (full/fallback/lean)" "fail"

# ── decomposer rubric (neutral source) ────────────────────────────────────────
BODY="$ENGINE_ROOT/agents/goal-decomposer/body.md"
grep -q 'requires new tests beyond browser smoke' "$BODY" \
  && assert "rubric: old everything-goes-full test trigger removed" "fail" \
  || assert "rubric: old everything-goes-full test trigger removed" "pass"
grep -q 'Hardening cadence' "$BODY" \
  && assert "rubric: hardening-cadence trigger documented" "pass" \
  || assert "rubric: hardening-cadence trigger documented" "fail"
grep -q 'NOT a full trigger' "$BODY" \
  && assert "rubric: unit-tests-alone-do-not-force-full stated explicitly" "pass" \
  || assert "rubric: unit-tests-alone-do-not-force-full stated explicitly" "fail"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
