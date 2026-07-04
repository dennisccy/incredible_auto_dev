#!/usr/bin/env bash
# test-goal-checkpoints.sh — end-to-end wiring test for step-level
# checkpoint/resume in goal-iter-lean.sh (lib/checkpoint.sh).
#
# Drives the REAL goal-iter-lean.sh in a sandbox repo with a stub `claude` on
# PATH that records which agent tried to dispatch and returns the transport
# code 70. Three scenarios:
#   A. All markers + artifacts + tree verify → every agent step SKIPS
#      (zero claude dispatches for developer/reviewer/browser-qa; exit 0).
#   B. CHAIN_STEP_CHECKPOINTS=false → markers ignored, developer re-dispatches.
#   C. Product-tree drift → skips refused, developer re-dispatches.
#
# No API calls; runs in a few seconds.

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

# ── Sandbox project with the engine's scripts embedded (consumer-repo layout) ─
SBX="$WORK/proj"
mkdir -p "$SBX"
cp -r "$ENGINE_ROOT/scripts" "$SBX/"
mkdir -p "$SBX/docs/phases" "$SBX/docs/handoffs" "$SBX/reports/reviews" "$SBX/src"
git init -q "$SBX"
echo "print('v1')" > "$SBX/src/app.py"
cat > "$SBX/docs/goal.md" <<'EOF'
# Goal
## Must-have user journeys
- J-01: open the page. Acceptance: page loads.
## Anti-goals
- none
EOF

ITER="goal-cptest-iter-1"
cat > "$SBX/docs/phases/$ITER.md" <<'EOF'
# Iteration spec
## Goal Mode Metadata
- **Mode:** next
- **Depth:** lean
- **Target journeys:** J-01
- **Required-still-passing:** J-01
## IN SCOPE
- nothing (checkpoint wiring test)
EOF
git -C "$SBX" add -A
git -C "$SBX" -c user.email=t@t -c user.name=t commit -qm base

# Artifacts a prior (interrupted) attempt would have produced.
DEV_HANDOFF="$SBX/docs/handoffs/${ITER}-dev.md"
REVIEW_REPORT="$SBX/reports/reviews/${ITER}-review.md"
UI_TEST_RESULTS="$SBX/reports/phase-${ITER}-ui-test-results.md"
echo "handoff: implemented J-01" > "$DEV_HANDOFF"
printf '**Verdict:** PASS\n\nLooks good.\n' > "$REVIEW_REPORT"
printf '**Browser QA Verdict:** PASS\n\n| UT-J-01 | open page | PASS | shot.png |\n' > "$UI_TEST_RESULTS"

# Session env the outer run-goal.sh would export.
export GOAL_SESSION_DIR="$SBX/runs/goal-session-cptest"
export GOAL_ITER_INDEX=1
export GOAL_ITER_NAME="$ITER"
ITER_DIR="$GOAL_SESSION_DIR/iter-1"
mkdir -p "$ITER_DIR"

# Keep the lean script's port cleanup away from anything real.
export CHAIN_BACKEND_PORT=48213
export CHAIN_FRONTEND_PORT=48214

# Stub claude: record which agent dispatched, then fail with the transport
# code so the lean script pauses fast instead of running a whole pipeline.
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
CANARY="$WORK/dispatched-agents.log"
cat > "$STUB_DIR/claude" <<EOF
#!/usr/bin/env bash
echo "\${CHAIN_CURRENT_AGENT:-unknown}" >> "$CANARY"
exit 70
EOF
chmod +x "$STUB_DIR/claude"

# Write the completion markers with the sandbox's own checkpoint lib so the
# tree hash matches how the lean script will recompute it.
_bq_sig="$(
  cd "$SBX"
  # shellcheck source=/dev/null
  source "$SBX/scripts/automation/lib/common.sh"
  t="$(grep -iE 'Target journeys:' "docs/phases/$ITER.md" | head -1 | grep -oE 'J-[0-9]+' | sort -u | tr '\n' ' ')"
  r="$(grep -iE 'Required-still-passing' "docs/phases/$ITER.md" | head -1 | grep -oE 'J-[0-9]+' | sort -u | tr '\n' ' ')"
  step_mark_done developer      --dir "$ITER_DIR" "$DEV_HANDOFF"                                 >&2
  step_mark_done review-1       --dir "$ITER_DIR" --verdict PASS "$REVIEW_REPORT"                >&2
  step_mark_done browser-qa     --dir "$ITER_DIR" --verdict PASS --journeys "$t|$r" "$UI_TEST_RESULTS" >&2
  printf '%s|%s' "$t" "$r"
)"
[[ -f "$ITER_DIR/.steps/developer.done" ]] && assert "setup: markers written (sig='$_bq_sig')" "pass" || assert "setup: markers written" "fail"

run_lean() {
  ( cd "$SBX" && PATH="$STUB_DIR:$PATH" CHAIN_STEP_CHECKPOINTS="${1:-true}" \
      bash scripts/automation/goal-iter-lean.sh "$ITER" ) >"$WORK/lean.log" 2>&1
}

# ── Scenario A: full-skip resume — no expensive agent dispatches ──────────────
rc=0; run_lean true || rc=$?
[[ "$rc" -eq 0 ]] && assert "A: resumed lean iteration exits 0" "pass" \
  || { assert "A: resumed lean iteration exits 0 (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/lean.log"; }
if grep -qE '^(developer|reviewer|browser-qa-agent)$' "$CANARY" 2>/dev/null; then
  assert "A: no developer/reviewer/browser-qa dispatch on resume ($(tr '\n' ' ' < "$CANARY"))" "fail"
else
  assert "A: no developer/reviewer/browser-qa dispatch on resume" "pass"
fi
for s in developer reviewer browser-qa; do
  if grep -q "\"step\": *\"$s\"" "$GOAL_SESSION_DIR/telemetry.jsonl" 2>/dev/null \
     || grep -q "\"step\":\"$s\"" "$GOAL_SESSION_DIR/telemetry.jsonl" 2>/dev/null; then
    assert "A: telemetry has step_skipped for $s" "pass"
  else
    assert "A: telemetry has step_skipped for $s" "fail"
  fi
done

# ── Scenario B: knob off — markers ignored, developer re-dispatches ───────────
: > "$CANARY"
rc=0; run_lean false || rc=$?
grep -qx "developer" "$CANARY" 2>/dev/null \
  && assert "B: CHAIN_STEP_CHECKPOINTS=false re-dispatches developer" "pass" \
  || assert "B: CHAIN_STEP_CHECKPOINTS=false re-dispatches developer" "fail"
[[ "$rc" -eq 70 ]] && assert "B: transport failure pauses with exit 70" "pass" \
  || assert "B: transport failure pauses with exit 70 (rc=$rc)" "fail"
[[ -f "$ITER_DIR/.steps/developer.done" ]] \
  && assert "B: knob off leaves existing markers untouched" "pass" \
  || assert "B: knob off leaves existing markers untouched" "fail"

# ── Scenario C: tree drift — skips refused, cascade invalidates ───────────────
: > "$CANARY"
echo "print('v2 — drifted')" >> "$SBX/src/app.py"
rc=0; run_lean true || rc=$?
grep -qx "developer" "$CANARY" 2>/dev/null \
  && assert "C: tree drift re-dispatches developer" "pass" \
  || assert "C: tree drift re-dispatches developer" "fail"
[[ ! -f "$ITER_DIR/.steps/developer.done" && ! -f "$ITER_DIR/.steps/browser-qa.done" ]] \
  && assert "C: drift invalidated the marker cascade" "pass" \
  || assert "C: drift invalidated the marker cascade" "fail"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
