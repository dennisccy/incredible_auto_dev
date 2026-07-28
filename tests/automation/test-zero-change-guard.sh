#!/usr/bin/env bash
# test-zero-change-guard.sh — SPEED-14 unit test: zero-change iteration guards.
#
# Logic under test:
#   goal_product_diff_empty <snapshot_sha> <repo_root>   (lib/goal-gates.sh)
#     -> 0 ONLY when the tracked diff vs the snapshot is empty AND no untracked
#        product files exist, with CHAIN_SCAN_BOOKKEEPING_EXCLUDES applied to
#        both layers. Missing snapshot or git error -> 1 (fail-safe: "changed").
#
# Wiring greps:
#   - run-goal.sh readme guard: the empty-change set now SKIPS (the old hole
#     dispatched the agent when _changed was empty).
#   - run-goal.sh coherence step: zero-change deterministic PASS stub with
#     distinct text, and goal_gate.py must classify that stub as certifiable
#     (NOT a crash stub) under --for-achievement.
#   - goal-iter-lean.sh coherence fork: skipped on empty product diff.
#   - run-goal.sh showcase tail: demo record reused on empty product diff.
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

source "$ENGINE_ROOT/scripts/automation/lib/goal-gates.sh"

# ── fixture repo ──────────────────────────────────────────────────────────────
REPO="$WORK/repo"
mkdir -p "$REPO/apps" "$REPO/runs"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t && git -C "$REPO" config user.name t
echo "base" > "$REPO/apps/app.py"
git -C "$REPO" add -A && git -C "$REPO" commit -qm base
SNAP="$(git -C "$REPO" rev-parse HEAD)"

# ── goal_product_diff_empty truth table ───────────────────────────────────────
goal_product_diff_empty "$SNAP" "$REPO" \
  && assert "empty tree vs snapshot -> empty (0)" "pass" \
  || assert "empty tree vs snapshot -> empty (0)" "fail"

echo "bookkeeping" > "$REPO/runs/note.md"
goal_product_diff_empty "$SNAP" "$REPO" \
  && assert "bookkeeping-only untracked change (runs/) -> still empty" "pass" \
  || assert "bookkeeping-only untracked change (runs/) -> still empty" "fail"

echo "new" > "$REPO/apps/new.py"
goal_product_diff_empty "$SNAP" "$REPO" \
  && assert "untracked product file -> NOT empty" "fail" \
  || assert "untracked product file -> NOT empty" "pass"
rm -f "$REPO/apps/new.py"

echo "changed" >> "$REPO/apps/app.py"
goal_product_diff_empty "$SNAP" "$REPO" \
  && assert "tracked product change -> NOT empty" "fail" \
  || assert "tracked product change -> NOT empty" "pass"
git -C "$REPO" checkout -q -- apps/app.py

goal_product_diff_empty "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$REPO" \
  && assert "bogus snapshot sha -> fail-safe NOT empty" "fail" \
  || assert "bogus snapshot sha -> fail-safe NOT empty" "pass"

goal_product_diff_empty "" "$REPO" \
  && assert "missing snapshot -> fail-safe NOT empty" "fail" \
  || assert "missing snapshot -> fail-safe NOT empty" "pass"

# ── run-goal.sh wiring ────────────────────────────────────────────────────────
RG="$ENGINE_ROOT/scripts/automation/run-goal.sh"
grep -q 'changed no files at all' "$RG" \
  && assert "wiring: readme guard skips the truly-empty change set" "pass" \
  || assert "wiring: readme guard skips the truly-empty change set" "fail"
grep -q 'Zero-change iteration: the product diff since the iteration snapshot is empty' "$RG" \
  && assert "wiring: coherence zero-change deterministic PASS stub present" "pass" \
  || assert "wiring: coherence zero-change deterministic PASS stub present" "fail"
grep -q '"coherence-auditor", iter_name:\$n, reason:"zero-change"' "$RG" \
  && assert "wiring: coherence skip emits step_skipped reason=zero-change" "pass" \
  || assert "wiring: coherence skip emits step_skipped reason=zero-change" "fail"
grep -q 'walkthrough reused from' "$RG" \
  && assert "wiring: showcase demo reuses prior recording on empty diff" "pass" \
  || assert "wiring: showcase demo reuses prior recording on empty diff" "fail"

LEAN="$ENGINE_ROOT/scripts/automation/goal-iter-lean.sh"
grep -q 'coherence fork skipped — zero-change iteration' "$LEAN" \
  && assert "wiring: lean coherence fork skipped on empty diff" "pass" \
  || assert "wiring: lean coherence fork skipped on empty diff" "fail"

# ── goal_gate.py classification of the zero-change stub ───────────────────────
STUB="$WORK/coherence-zero.md"
printf '**Verdict:** COHERENCE-PASS\n\n(Zero-change iteration: the product diff since the iteration snapshot is empty — nothing to audit. Deterministic pass without dispatch; set CHAIN_ZERO_CHANGE_SKIPS=false to always dispatch.)\n' > "$STUB"
if python3 "$ENGINE_ROOT/scripts/automation/lib/goal_gate.py" coherence "$STUB" --for-achievement >/dev/null 2>&1; then
  assert "gate: zero-change PASS is certifiable (not a crash stub)" "pass"
else
  assert "gate: zero-change PASS is certifiable (not a crash stub)" "fail"
fi
CRASH="$WORK/coherence-crash.md"
printf '**Verdict:** COHERENCE-PASS\n\n(Coherence auditor produced no output; treated as a non-blocking pass.)\n' > "$CRASH"
if python3 "$ENGINE_ROOT/scripts/automation/lib/goal_gate.py" coherence "$CRASH" --for-achievement >/dev/null 2>&1; then
  assert "gate: crash stub still blocks certification" "fail"
else
  assert "gate: crash stub still blocks certification" "pass"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
