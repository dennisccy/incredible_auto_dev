#!/usr/bin/env bash
# test-depth-arbiter.sh — SPEED-20 unit test: the deterministic depth arbiter
# that stops the decomposer from self-certifying full passes.
#
# Logic under test lives in lib/common.sh (sourceable, like test-depth-cadence):
#   goal_full_ran_in_window <session_dir> <current_iter>
#     -> true iff a full dispatch is recorded in the last W-1 iterations
#        (W = CHAIN_FULL_CADENCE_CAP, default 4; 0/1 disables; iter-0 never
#        counted) — i.e. granting full NOW would exceed 1 full per W window.
#   goal_new_fullstack_journey <spec_path> <journey_history>
#     -> true iff the spec provably plans a brand-new full-stack journey:
#        Backend + Frontend bullets, non-"none" Data-contract additions, and
#        ≥1 target journey never recorded as implemented. Fail-closed.
#
# Wiring + rubric are grep-asserted: run-goal.sh must gate the ladder on
# CHAIN_DEPTH_ARBITER, emit depth_full_granted/depth_demoted telemetry, parse
# TARGET_JOURNEYS before the arbiter, keep the legacy SPEED-10 allowlist as
# the escape hatch, suppress the SPEED-4 cadence re-promotion after a
# budget-breach demotion, and write the budget-breached marker; the decomposer
# rubric must carry the tightened Data-model-migration trigger and the
# binding-evaluator-recommendation language.
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
unset CHAIN_FULL_CADENCE_CAP || true

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

# ── goal_full_ran_in_window ───────────────────────────────────────────────────
seed_depths lean lean full lean
if goal_full_ran_in_window "$SDIR" 5; then
  assert "window: full at iter-3 inside W=4 window of iter-5 -> capped" "pass"
else
  assert "window: full at iter-3 inside W=4 window of iter-5 -> capped" "fail"
fi

seed_depths full lean lean lean
if goal_full_ran_in_window "$SDIR" 5; then
  assert "window: full at iter-1 is OUTSIDE the W=4 window of iter-5 -> not capped" "fail"
else
  assert "window: full at iter-1 is OUTSIDE the W=4 window of iter-5 -> not capped" "pass"
fi

seed_depths lean lean lean lean
if goal_full_ran_in_window "$SDIR" 5; then
  assert "window: no full anywhere -> not capped" "fail"
else
  assert "window: no full anywhere -> not capped" "pass"
fi

seed_depths lean lean lean full
if CHAIN_FULL_CADENCE_CAP=0 goal_full_ran_in_window "$SDIR" 5; then
  assert "window: CHAIN_FULL_CADENCE_CAP=0 disables the cap" "fail"
else
  assert "window: CHAIN_FULL_CADENCE_CAP=0 disables the cap" "pass"
fi

seed_depths full lean lean lean
if CHAIN_FULL_CADENCE_CAP=6 goal_full_ran_in_window "$SDIR" 5; then
  assert "window: W=6 widens the window to include iter-1's full" "pass"
else
  assert "window: W=6 widens the window to include iter-1's full" "fail"
fi

seed_depths - - - -
if goal_full_ran_in_window "$SDIR" 5; then
  assert "window: missing depth-dispatched files -> not capped" "fail"
else
  assert "window: missing depth-dispatched files -> not capped" "pass"
fi

# ── goal_new_fullstack_journey ────────────────────────────────────────────────
HIST="$WORK/journey-history.json"
cat > "$HIST" <<'EOF'
{"journeys": {"J-01": {"status": "passing"}, "J-02": {"status": "already_passing"}, "J-09": {"status": "failing"}}}
EOF

write_spec() {  # write_spec <targets> <backend-bullet> <frontend-bullet> <contract-line>
  cat > "$WORK/spec.md" <<EOF
# Goal Iteration 9 — test spec

## Goal Mode Metadata

- **Depth:** full
- **Full trigger:** 1 — test
- **Target journeys:** $1

## IN SCOPE

### Backend
$2

### Frontend (if applicable)
$3

### Data-contract additions
$4

## OUT OF SCOPE

- nothing
EOF
}

write_spec "J-15" "- [ ] Add /api/dash endpoint" "- [ ] Dashboard page" '`dash_total: int >= 0` — stats.py, /api/dash'
if goal_new_fullstack_journey "$WORK/spec.md" "$HIST"; then
  assert "fullstack: backend+frontend+contract+unknown journey -> new" "pass"
else
  assert "fullstack: backend+frontend+contract+unknown journey -> new" "fail"
fi

write_spec "J-09" "- [ ] Add /api/dash endpoint" "- [ ] Dashboard page" '`dash_total: int >= 0` — stats.py, /api/dash'
if goal_new_fullstack_journey "$WORK/spec.md" "$HIST"; then
  assert "fullstack: failing-status journey counts as never-implemented -> new" "pass"
else
  assert "fullstack: failing-status journey counts as never-implemented -> new" "fail"
fi

write_spec "J-15" "- [ ] Add /api/dash endpoint" "- [ ] Dashboard page" "none"
if goal_new_fullstack_journey "$WORK/spec.md" "$HIST"; then
  assert "fullstack: Data-contract additions 'none' -> NOT new" "fail"
else
  assert "fullstack: Data-contract additions 'none' -> NOT new" "pass"
fi

write_spec "J-15" "- [ ] Add /api/dash endpoint" "<no frontend work>" '`dash_total: int >= 0`'
if goal_new_fullstack_journey "$WORK/spec.md" "$HIST"; then
  assert "fullstack: no concrete Frontend bullet -> NOT new" "fail"
else
  assert "fullstack: no concrete Frontend bullet -> NOT new" "pass"
fi

write_spec "J-01, J-02" "- [ ] Add /api/dash endpoint" "- [ ] Dashboard page" '`dash_total: int >= 0`'
if goal_new_fullstack_journey "$WORK/spec.md" "$HIST"; then
  assert "fullstack: every target already implemented -> NOT new" "fail"
else
  assert "fullstack: every target already implemented -> NOT new" "pass"
fi

write_spec "J-15" "- [ ] Add /api/dash endpoint" "- [ ] Dashboard page" '`dash_total: int >= 0`'
if goal_new_fullstack_journey "$WORK/spec.md" "$WORK/does-not-exist.json"; then
  assert "fullstack: unreadable journey-history fails CLOSED -> NOT new" "fail"
else
  assert "fullstack: unreadable journey-history fails CLOSED -> NOT new" "pass"
fi

# '- none' filler bullets must not satisfy the backend/frontend/contract tests
# (the whole point is a content check the decomposer cannot pencil-whip).
write_spec "J-15" "- none" "- [ ] Dashboard page" '`dash_total: int >= 0`'
if goal_new_fullstack_journey "$WORK/spec.md" "$HIST"; then
  assert "fullstack: '- none' Backend bullet -> NOT new" "fail"
else
  assert "fullstack: '- none' Backend bullet -> NOT new" "pass"
fi
write_spec "J-15" "- [ ] Add /api/dash endpoint" "- [ ] N/A" '`dash_total: int >= 0`'
if goal_new_fullstack_journey "$WORK/spec.md" "$HIST"; then
  assert "fullstack: '- N/A' Frontend bullet -> NOT new" "fail"
else
  assert "fullstack: '- N/A' Frontend bullet -> NOT new" "pass"
fi
write_spec "J-15" "- [ ] Add /api/dash endpoint" "- [ ] Dashboard page" "- none"
if goal_new_fullstack_journey "$WORK/spec.md" "$HIST"; then
  assert "fullstack: bullet-form '- none' Data-contract -> NOT new" "fail"
else
  assert "fullstack: bullet-form '- none' Data-contract -> NOT new" "pass"
fi

# Sections OUTSIDE the IN SCOPE block must not count.
cat > "$WORK/spec.md" <<'EOF'
# Out-of-scope decoy spec

## Goal Mode Metadata

- **Depth:** full
- **Full trigger:** 1 — test
- **Target journeys:** J-15

## IN SCOPE

### Backend
- [ ] Add /api/dash endpoint

## OUT OF SCOPE

### Frontend (if applicable)
- [ ] Dashboard page (explicitly excluded this iteration)

### Data-contract additions
`dash_total: int >= 0`
EOF
if goal_new_fullstack_journey "$WORK/spec.md" "$HIST"; then
  assert "fullstack: Frontend/contract under OUT OF SCOPE -> NOT new" "fail"
else
  assert "fullstack: Frontend/contract under OUT OF SCOPE -> NOT new" "pass"
fi

# ── run-goal.sh wiring ────────────────────────────────────────────────────────
RG="$ENGINE_ROOT/scripts/automation/run-goal.sh"
grep -q 'CHAIN_DEPTH_ARBITER' "$RG" \
  && assert "wiring: arbiter knob present in run-goal.sh" "pass" \
  || assert "wiring: arbiter knob present in run-goal.sh" "fail"
grep -q 'depth_full_granted' "$RG" \
  && assert "wiring: granted fulls record depth_full_granted telemetry" "pass" \
  || assert "wiring: granted fulls record depth_full_granted telemetry" "fail"
grep -q 'evaluator-requested-' "$RG" \
  && assert "wiring: binding-recommendation demotion reason present" "pass" \
  || assert "wiring: binding-recommendation demotion reason present" "fail"
grep -q '"full-cap"' "$RG" \
  && assert "wiring: full-cap window demotion reason present" "pass" \
  || assert "wiring: full-cap window demotion reason present" "fail"
grep -q 'new-fullstack-journey' "$RG" \
  && assert "wiring: new-fullstack-journey grant present" "pass" \
  || assert "wiring: new-fullstack-journey grant present" "fail"
grep -q 'goal_full_ran_in_window' "$RG" \
  && assert "wiring: engine calls goal_full_ran_in_window" "pass" \
  || assert "wiring: engine calls goal_full_ran_in_window" "fail"
grep -q 'goal_new_fullstack_journey' "$RG" \
  && assert "wiring: engine calls goal_new_fullstack_journey" "pass" \
  || assert "wiring: engine calls goal_new_fullstack_journey" "fail"
[[ "$(grep -c 'budget-breached' "$RG" || true)" -ge 2 ]] \
  && assert "wiring: budget-breached marker is both written and read" "pass" \
  || assert "wiring: budget-breached marker is both written and read" "fail"
grep -q 'CHAIN_DEPTH_ALLOWLIST' "$RG" \
  && assert "wiring: legacy SPEED-10 allowlist retained as escape hatch" "pass" \
  || assert "wiring: legacy SPEED-10 allowlist retained as escape hatch" "fail"
[[ "$(grep -c '_budget_demoted' "$RG" || true)" -ge 2 ]] \
  && assert "wiring: SPEED-4 cadence re-promotion suppressed after budget demotion" "pass" \
  || assert "wiring: SPEED-4 cadence re-promotion suppressed after budget demotion" "fail"
grep -q 'BINDING by default' "$RG" \
  && assert "wiring: decomposer prompt carries the binding-recommendation line" "pass" \
  || assert "wiring: decomposer prompt carries the binding-recommendation line" "fail"

# TARGET_JOURNEYS must be parsed BEFORE the arbiter consumes it.
_tj_line="$(grep -n 'Target journeys:\\\*\\\*' "$RG" | head -1 | cut -d: -f1)"
_arb_line="$(grep -n 'CHAIN_DEPTH_ARBITER' "$RG" | head -1 | cut -d: -f1)"
if [[ -n "$_tj_line" && -n "$_arb_line" && "$_tj_line" -lt "$_arb_line" ]]; then
  assert "wiring: TARGET_JOURNEYS parsed before the arbiter ladder" "pass"
else
  assert "wiring: TARGET_JOURNEYS parsed before the arbiter ladder (tj=$_tj_line arb=$_arb_line)" "fail"
fi

# ── decomposer rubric (neutral source) ────────────────────────────────────────
BODY="$ENGINE_ROOT/agents/goal-decomposer/body.md"
grep -q 'adds/changes persisted schema' "$BODY" \
  && assert "rubric: old additive-schema-counts-as-full trigger removed" "fail" \
  || assert "rubric: old additive-schema-counts-as-full trigger removed" "pass"
grep -q 'Data-model migration' "$BODY" \
  && assert "rubric: tightened Data-model-migration trigger present" "pass" \
  || assert "rubric: tightened Data-model-migration trigger present" "fail"
grep -q 'NOT this trigger' "$BODY" \
  && assert "rubric: purely-additive-is-not-a-migration stated explicitly" "pass" \
  || assert "rubric: purely-additive-is-not-a-migration stated explicitly" "fail"
grep -q 'BINDING by default' "$BODY" \
  && assert "rubric: evaluator recommendation binding-by-default stated" "pass" \
  || assert "rubric: evaluator recommendation binding-by-default stated" "fail"
grep -q 'binding by default' "$BODY" \
  && assert "rubric: self-check 4 carries the binding language" "pass" \
  || assert "rubric: self-check 4 carries the binding language" "fail"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
