#!/usr/bin/env bash
# test-intent-checkpoint.sh — end-to-end wiring test for the opt-in intent
# checkpoint (NEED-7) in run-goal.sh.
#
# Drives the REAL run-goal.sh in a sandbox repo with a stub `claude` on PATH
# that records which agent tried to dispatch and returns the transport code 70
# (so any run that proceeds past the gate pauses fast at the decomposer instead
# of running a pipeline). Scenarios:
#   1. --intent-checkpoint at 50% passing → pauses AWAITING_INTENT_REVIEW with
#      a deterministic intent-review.md, zero agent dispatches, telemetry halt.
#   2. --resume acknowledges the pause: marker touched, loop proceeds to the
#      decomposer, status leaves AWAITING_INTENT_REVIEW.
#   3. Fire-once: with the marker present the gate never fires again.
#   4. Below threshold (1/3 passing) → no fire, loop proceeds.
#   5. --intent-checkpoint-at 1 fires by iteration count even below threshold.
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
mkdir -p "$SBX/docs/phases" "$SBX/reports" "$SBX/src" "$SBX/.claude/agents"
# ensure_cli_assets_synced no-ops when the rendered marker exists.
touch "$SBX/.claude/agents/developer.md"
git init -q "$SBX"
echo "print('v1')" > "$SBX/src/app.py"
cat > "$SBX/docs/goal.md" <<'EOF'
# Goal

Tiny CSV exporter web app.

## Must-have user journeys

- **J-01: Open the page**
  - Steps: open /
  - Acceptance: page loads
- **J-02: Export CSV**
  - Steps: click export
  - Acceptance: csv downloads
- **J-03: Delete a row**
  - Steps: click delete
  - Acceptance: row gone

## Anti-goals

- no paid SaaS
EOF
git -C "$SBX" add -A
git -C "$SBX" -c user.email=t@t -c user.name=t commit -qm base

# Stub claude: record which agent dispatched, then fail with the transport
# code so run-goal.sh pauses fast (AWAITING_PUMP) instead of running agents.
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
CANARY="$WORK/dispatched-agents.log"
cat > "$STUB_DIR/claude" <<EOF
#!/usr/bin/env bash
echo "\${CHAIN_CURRENT_AGENT:-unknown}" >> "$CANARY"
exit 70
EOF
chmod +x "$STUB_DIR/claude"

# ── Session fixtures ──────────────────────────────────────────────────────────
# make_session <sid> <current_iter> <journeys-json>
make_session() {
  local sid="$1" iter="$2" journeys="$3"
  local sdir="$SBX/runs/goal-session-$sid"
  mkdir -p "$sdir/state"
  cat > "$sdir/session.json" <<EOF
{
  "session_id": "$sid",
  "started_at": "2026-07-08T00:00:00Z",
  "current_iter": $iter,
  "cli": "claude",
  "agent_backend": "headless",
  "halt_config": {"max_iterations": 60, "stall_window": 3, "regression_halt": true},
  "status": "in_progress",
  "last_verdict": "CONTINUE",
  "next_depth": "lean",
  "auto_release": false,
  "push_per_iter": false,
  "push_branch": ""
}
EOF
  printf '%s\n' "$journeys" > "$sdir/state/journey-history.json"
  : > "$sdir/state/evaluator-log.md"
  echo "# Lessons" > "$sdir/state/lessons.md"
  echo "The product is a tiny CSV exporter web app with one working page." \
    > "$sdir/state/project-story.md"
  cat > "$sdir/state/assumptions.md" <<'EOF'
# Assumption ledger

## iter-0 — goal-decomposer
**Ambiguity:** goal doesn't say which database
**We chose:** sqlite file storage
**Reversible:** yes

## iter-1 — goal-decomposer
**Ambiguity:** goal doesn't name an auth provider
**We chose:** local password accounts
**Reversible:** no
EOF
}

JOURNEYS_50='{"journeys":{"J-01":{"status":"passing","name":"Open the page","last_passing_iter":"iter-0"},"J-02":{"status":"failing","name":"Export CSV"}},"anti_goal_violations":[],"updated_at":""}'
JOURNEYS_33='{"journeys":{"J-01":{"status":"passing","name":"Open the page","last_passing_iter":"iter-0"},"J-02":{"status":"failing","name":"Export CSV"},"J-03":{"status":"unknown","name":"Delete a row"}},"anti_goal_violations":[],"updated_at":""}'

# A prior iteration summary so the review's report links have a real target.
echo "# Iteration 0 summary" > "$SBX/reports/phase-goal-it50-iter-0-iteration-summary.md"

# run_goal <sid> [extra flags...] — resume the session against the sandbox.
run_goal() {
  local sid="$1"; shift
  ( cd "$SBX" && PATH="$STUB_DIR:$PATH" \
      bash scripts/automation/run-goal.sh --session-id "$sid" --resume --no-push-per-iter "$@" )
}

# ── Scenario 1: fire at threshold (1/2 passing = 50%) ─────────────────────────
make_session it50 1 "$JOURNEYS_50"
SDIR="$SBX/runs/goal-session-it50"
REVIEW="$SDIR/intent-review.md"
MARKER="$SDIR/state/.intent-review-done"

: > "$CANARY"
rc=0; run_goal it50 --intent-checkpoint >"$WORK/s1.log" 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] && assert "S1: run exits 0 at the checkpoint" "pass" \
  || { assert "S1: run exits 0 at the checkpoint (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/s1.log"; }
status=$(python3 -c "import json; print(json.load(open('$SDIR/session.json'))['status'])" 2>/dev/null || echo "?")
[[ "$status" == "AWAITING_INTENT_REVIEW" ]] \
  && assert "S1: session status is AWAITING_INTENT_REVIEW" "pass" \
  || assert "S1: session status is AWAITING_INTENT_REVIEW (got $status)" "fail"
[[ -f "$REVIEW" ]] && assert "S1: intent-review.md written" "pass" \
  || assert "S1: intent-review.md written" "fail"
grep -q "J-02" "$REVIEW" 2>/dev/null \
  && assert "S1: review lists the still-failing journey (J-02)" "pass" \
  || assert "S1: review lists the still-failing journey (J-02)" "fail"
grep -q "local password accounts" "$REVIEW" 2>/dev/null \
  && assert "S1: review surfaces the 'Reversible: no' assumption" "pass" \
  || assert "S1: review surfaces the 'Reversible: no' assumption" "fail"
grep -q "sqlite file storage" "$REVIEW" 2>/dev/null \
  && assert "S1: review keeps the ledger tail (reversible entry too)" "pass" \
  || assert "S1: review keeps the ledger tail (reversible entry too)" "fail"
grep -q "tiny CSV exporter" "$REVIEW" 2>/dev/null \
  && assert "S1: review includes the project story" "pass" \
  || assert "S1: review includes the project story" "fail"
grep -q "goal-session-it50-index.html" "$REVIEW" 2>/dev/null \
  && assert "S1: review links the session index HTML" "pass" \
  || assert "S1: review links the session index HTML" "fail"
grep -q "phase-goal-it50-iter-0-iteration-summary.md" "$REVIEW" 2>/dev/null \
  && assert "S1: review links the latest iteration summary" "pass" \
  || assert "S1: review links the latest iteration summary" "fail"
if grep -qE '^goal-' "$CANARY" 2>/dev/null; then
  assert "S1: no agent dispatched before the pause ($(tr '\n' ' ' < "$CANARY"))" "fail"
else
  assert "S1: no agent dispatched before the pause" "pass"
fi
grep -q "AWAITING_INTENT_REVIEW" "$SDIR/telemetry.jsonl" 2>/dev/null \
  && assert "S1: telemetry halt event recorded" "pass" \
  || assert "S1: telemetry halt event recorded" "fail"
[[ ! -f "$MARKER" ]] && assert "S1: marker not yet touched (ack happens on resume)" "pass" \
  || assert "S1: marker not yet touched (ack happens on resume)" "fail"

# ── Scenario 2: --resume acknowledges and proceeds ────────────────────────────
: > "$CANARY"
rc=0; run_goal it50 --intent-checkpoint >"$WORK/s2.log" 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] && assert "S2: resumed run exits 0 (stub pauses at decomposer)" "pass" \
  || { assert "S2: resumed run exits 0 (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/s2.log"; }
[[ -f "$MARKER" ]] && assert "S2: resume touched the .intent-review-done marker" "pass" \
  || assert "S2: resume touched the .intent-review-done marker" "fail"
grep -qx "goal-decomposer" "$CANARY" 2>/dev/null \
  && assert "S2: loop proceeded to the decomposer after ack" "pass" \
  || assert "S2: loop proceeded to the decomposer after ack" "fail"
status=$(python3 -c "import json; print(json.load(open('$SDIR/session.json'))['status'])" 2>/dev/null || echo "?")
[[ "$status" != "AWAITING_INTENT_REVIEW" ]] \
  && assert "S2: status left AWAITING_INTENT_REVIEW (now $status)" "pass" \
  || assert "S2: status left AWAITING_INTENT_REVIEW" "fail"

# ── Scenario 3: fire-once — marker present, gate never fires again ────────────
: > "$CANARY"
rc=0; run_goal it50 --intent-checkpoint >"$WORK/s3.log" 2>&1 || rc=$?
grep -qx "goal-decomposer" "$CANARY" 2>/dev/null \
  && assert "S3: subsequent resume goes straight to the decomposer" "pass" \
  || assert "S3: subsequent resume goes straight to the decomposer" "fail"
status=$(python3 -c "import json; print(json.load(open('$SDIR/session.json'))['status'])" 2>/dev/null || echo "?")
[[ "$status" != "AWAITING_INTENT_REVIEW" ]] \
  && assert "S3: checkpoint did not re-fire (status $status)" "pass" \
  || assert "S3: checkpoint did not re-fire" "fail"

# ── Scenario 4: below threshold (1/3 passing) — no fire ───────────────────────
make_session it33 1 "$JOURNEYS_33"
: > "$CANARY"
rc=0; run_goal it33 --intent-checkpoint >"$WORK/s4.log" 2>&1 || rc=$?
[[ ! -f "$SBX/runs/goal-session-it33/intent-review.md" ]] \
  && assert "S4: below 50% writes no intent-review.md" "pass" \
  || assert "S4: below 50% writes no intent-review.md" "fail"
grep -qx "goal-decomposer" "$CANARY" 2>/dev/null \
  && assert "S4: below 50% proceeds to the decomposer" "pass" \
  || assert "S4: below 50% proceeds to the decomposer" "fail"

# ── Scenario 5: --intent-checkpoint-at 1 fires by iteration count ─────────────
make_session itat 1 "$JOURNEYS_33"
: > "$CANARY"
rc=0; run_goal itat --intent-checkpoint-at 1 >"$WORK/s5.log" 2>&1 || rc=$?
status=$(python3 -c "import json; print(json.load(open('$SBX/runs/goal-session-itat/session.json'))['status'])" 2>/dev/null || echo "?")
[[ "$rc" -eq 0 && "$status" == "AWAITING_INTENT_REVIEW" ]] \
  && assert "S5: --intent-checkpoint-at 1 pauses at iteration 1" "pass" \
  || { assert "S5: --intent-checkpoint-at 1 pauses at iteration 1 (rc=$rc status=$status)" "fail"; sed -n '1,40p' "$WORK/s5.log"; }
[[ -f "$SBX/runs/goal-session-itat/intent-review.md" ]] \
  && assert "S5: intent-review.md written for the -at variant" "pass" \
  || assert "S5: intent-review.md written for the -at variant" "fail"
if grep -qE '^goal-' "$CANARY" 2>/dev/null; then
  assert "S5: no agent dispatched before the -at pause" "fail"
else
  assert "S5: no agent dispatched before the -at pause" "pass"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
