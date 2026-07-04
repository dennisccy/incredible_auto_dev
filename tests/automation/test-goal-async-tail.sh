#!/usr/bin/env bash
# test-goal-async-tail.sh — wiring tests for Track-2 parallelization:
#   1. goal-iter-lean.sh forks the coherence-auditor concurrently with the
#      browser-qa section, marks its checkpoint on success, and
#   2. falls back cleanly (no marker, no stale artifact) when the fork crashes;
#   3. run-goal.sh's showcase fork/join: fork returns immediately, join commits
#      ONLY showcase paths (the next iteration's spec stays uncommitted), and
#      --kill reaps without committing.
#
# No API calls; a stub `claude` plays every agent. Runs in a few seconds.

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

# ── Sandbox project (consumer-repo layout, engine scripts embedded) ───────────
SBX="$WORK/proj"
mkdir -p "$SBX"
cp -r "$ENGINE_ROOT/scripts" "$SBX/"
mkdir -p "$SBX/docs/phases" "$SBX/docs/handoffs" "$SBX/reports/reviews" "$SBX/src"
git init -q "$SBX"
git -C "$SBX" config user.email t@t
git -C "$SBX" config user.name t
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
- nothing (async-tail wiring test)
EOF
git -C "$SBX" add -A
git -C "$SBX" commit -qm base

DEV_HANDOFF="$SBX/docs/handoffs/${ITER}-dev.md"
REVIEW_REPORT="$SBX/reports/reviews/${ITER}-review.md"
UI_TEST_RESULTS="$SBX/reports/phase-${ITER}-ui-test-results.md"
echo "handoff" > "$DEV_HANDOFF"
printf '**Verdict:** PASS\n' > "$REVIEW_REPORT"
printf '**Browser QA Verdict:** PASS\n\n| UT-J-01 | open page | PASS | shot.png |\n' > "$UI_TEST_RESULTS"

export GOAL_SESSION_ID="cptest"
export GOAL_SESSION_DIR="$SBX/runs/goal-session-cptest"
export GOAL_ITER_INDEX=1
export GOAL_ITER_NAME="$ITER"
ITER_DIR="$GOAL_SESSION_DIR/iter-1"
mkdir -p "$ITER_DIR" "$GOAL_SESSION_DIR/state"
printf '# Blueprint\n\nIA + data contract.\n' > "$GOAL_SESSION_DIR/state/blueprint.md"
export GOAL_BLUEPRINT_FILE="$GOAL_SESSION_DIR/state/blueprint.md"
export CHAIN_BACKEND_PORT=48215
export CHAIN_FRONTEND_PORT=48216

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
CANARY="$WORK/dispatched-agents.log"
cat > "$STUB_DIR/claude" <<EOF
#!/usr/bin/env bash
echo "\${CHAIN_CURRENT_AGENT:-unknown}" >> "$CANARY"
if [[ "\${CHAIN_CURRENT_AGENT:-}" == "coherence-auditor" ]]; then
  if [[ "\${COH_STUB_MODE:-ok}" == "ok" ]]; then
    printf '**Verdict:** COHERENCE-PASS\n\n(stub audit)\n' > "$ITER_DIR/coherence.md"
    exit 0
  fi
  exit 1
fi
exit 70
EOF
chmod +x "$STUB_DIR/claude"

_mark_prior_steps() {
  ( cd "$SBX"
    # shellcheck source=/dev/null
    source "$SBX/scripts/automation/lib/common.sh"
    step_mark_done developer  --dir "$ITER_DIR" "$DEV_HANDOFF"
    step_mark_done review-1   --dir "$ITER_DIR" --verdict PASS "$REVIEW_REPORT"
    t="$(grep -iE 'Target journeys:' "docs/phases/$ITER.md" | head -1 | grep -oE 'J-[0-9]+' | sort -u | tr '\n' ' ')"
    r="$(grep -iE 'Required-still-passing' "docs/phases/$ITER.md" | head -1 | grep -oE 'J-[0-9]+' | sort -u | tr '\n' ' ')"
    step_mark_done browser-qa --dir "$ITER_DIR" --verdict PASS --journeys "$t|$r" "$UI_TEST_RESULTS"
  ) >/dev/null 2>&1
}
_mark_prior_steps

run_lean() {
  ( cd "$SBX" && PATH="$STUB_DIR:$PATH" COH_STUB_MODE="${1:-ok}" \
      bash scripts/automation/goal-iter-lean.sh "$ITER" ) >"$WORK/lean.log" 2>&1
}

# ── Scenario 1: coherence fork dispatches, output + checkpoint land ───────────
rc=0; run_lean ok || rc=$?
[[ "$rc" -eq 0 ]] && assert "1: lean exits 0 with parallel coherence" "pass" \
  || { assert "1: lean exits 0 with parallel coherence (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/lean.log"; }
grep -qx "coherence-auditor" "$CANARY" 2>/dev/null \
  && assert "1: coherence-auditor was dispatched by the fork" "pass" \
  || assert "1: coherence-auditor was dispatched by the fork" "fail"
grep -q "COHERENCE-PASS" "$ITER_DIR/coherence.md" 2>/dev/null \
  && assert "1: coherence.md written with a verdict" "pass" \
  || assert "1: coherence.md written with a verdict" "fail"
[[ -f "$ITER_DIR/.steps/coherence.done" ]] \
  && assert "1: coherence checkpoint recorded (run-goal.sh will reuse, not re-dispatch)" "pass" \
  || assert "1: coherence checkpoint recorded" "fail"
if grep -qE '^(developer|reviewer|browser-qa-agent)$' "$CANARY" 2>/dev/null; then
  assert "1: dev/review/browser-qa still skipped (checkpoints held)" "fail"
else
  assert "1: dev/review/browser-qa still skipped (checkpoints held)" "pass"
fi

# ── Scenario 2: fork crash → clean fallback (no marker, no stale artifact) ────
: > "$CANARY"
rm -f "$ITER_DIR/.steps/coherence.done" "$ITER_DIR/coherence.md"
rc=0; run_lean crash || rc=$?
[[ "$rc" -eq 0 ]] && assert "2: lean still exits 0 when the coherence fork crashes" "pass" \
  || assert "2: lean still exits 0 when the coherence fork crashes (rc=$rc)" "fail"
[[ ! -f "$ITER_DIR/.steps/coherence.done" && ! -f "$ITER_DIR/coherence.md" ]] \
  && assert "2: no checkpoint and no stale coherence.md after the crash" "pass" \
  || assert "2: no checkpoint and no stale coherence.md after the crash" "fail"
grep -q "falling back to the sequential dispatch" "$WORK/lean.log" \
  && assert "2: fallback to run-goal.sh's sequential dispatch announced" "pass" \
  || assert "2: fallback to run-goal.sh's sequential dispatch announced" "fail"

# ── Scenario 3: showcase fork/join unit (functions extracted from run-goal.sh) ─
eval "$(sed -n '/^_run_showcase_steps() {/,/^}/p; /^_fork_showcase_tail() {/,/^}/p; /^_join_showcase_tail() {/,/^}/p' "$ENGINE_ROOT/scripts/automation/run-goal.sh")"
declare -F _fork_showcase_tail >/dev/null && declare -F _join_showcase_tail >/dev/null \
  && assert "3: fork/join functions extracted from run-goal.sh" "pass" \
  || { assert "3: fork/join functions extracted from run-goal.sh" "fail"; exit 1; }

REPO_ROOT="$SBX"
CURRENT_ITER=7
PUSH_PER_ITER=true
SHOWCASE_STAMP="$SBX/reports/showcase-stamp.md"
_run_iteration_summarizer() { sleep 1; echo "summary of $1" > "$SHOWCASE_STAMP"; }
_run_readme_maintainer()    { :; }
_render_iter_html()         { :; }
_render_session_index_html(){ :; }
kill_phase_servers()        { :; }
SCRIPT_DIR="$WORK/stub-scripts"
mkdir -p "$SCRIPT_DIR"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SCRIPT_DIR/demo-phase.sh"
chmod +x "$SCRIPT_DIR/demo-phase.sh"

# The next iteration's decomposer writes its spec while the tail runs — the
# join must NOT commit it (scoped add).
echo "next spec" > "$SBX/docs/phases/goal-cptest-iter-2.md"

_t0=$SECONDS
_fork_showcase_tail "$ITER" "lean"
_fork_elapsed=$((SECONDS - _t0))
[[ "$_fork_elapsed" -le 1 && -n "$_SHOWCASE_PID" ]] \
  && assert "3: fork returns immediately while the group runs (${_fork_elapsed}s)" "pass" \
  || assert "3: fork returns immediately (elapsed ${_fork_elapsed}s, pid='$_SHOWCASE_PID')" "fail"

_head_before="$(git -C "$SBX" rev-parse HEAD)"
_join_showcase_tail
_head_after="$(git -C "$SBX" rev-parse HEAD)"
[[ "$_head_before" != "$_head_after" ]] \
  && git -C "$SBX" log -1 --format=%s | grep -q "showcase artifacts" \
  && assert "3: join committed the showcase artifacts" "pass" \
  || assert "3: join committed the showcase artifacts" "fail"
git -C "$SBX" show --stat HEAD | grep -q "showcase-stamp" \
  && assert "3: showcase output is in the join commit" "pass" \
  || assert "3: showcase output is in the join commit" "fail"
if git -C "$SBX" ls-files --error-unmatch docs/phases/goal-cptest-iter-2.md >/dev/null 2>&1; then
  assert "3: next iteration's spec stays uncommitted (scoped add)" "fail"
else
  assert "3: next iteration's spec stays uncommitted (scoped add)" "pass"
fi

# --kill: reap fast, no commit.
_run_iteration_summarizer() { sleep 30; }
_fork_showcase_tail "$ITER" "lean"
_head_before="$(git -C "$SBX" rev-parse HEAD)"
_t0=$SECONDS
_join_showcase_tail --kill
_kill_elapsed=$((SECONDS - _t0))
_head_after="$(git -C "$SBX" rev-parse HEAD)"
[[ "$_kill_elapsed" -le 5 && "$_head_before" == "$_head_after" && -z "$_SHOWCASE_PID" ]] \
  && assert "3: --kill reaps fast without committing (${_kill_elapsed}s)" "pass" \
  || assert "3: --kill reaps fast without committing (elapsed ${_kill_elapsed}s)" "fail"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
