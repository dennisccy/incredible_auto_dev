#!/usr/bin/env bash
# test-summary-dedupe.sh — SPEED-5 unit test: run-phase.sh defers the Step 10.5
# iteration-summarizer + HTML render when invoked as a goal-mode full iteration
# (--no-finalize AND a goal-<sid>-iter-<N> phase name): the goal engine's
# post-evaluator showcase tail runs the summarizer again on the SAME output file
# (reports/phase-<iter>-iteration-summary.md) with verdict context, so the
# pre-evaluator run here is pure duplication (~2 dispatches/iter measured).
# Escape hatch: CHAIN_FULL_ITER_SUMMARY=true restores the pre-evaluator run.
#
# Same sandbox harness as test-testplan-skip.sh: the REAL run-phase.sh in a
# consumer-repo sandbox, expensive step scripts stubbed, stub `claude` on PATH
# recording every dispatch to a canary. The summarizer dispatch is visible as
# `claude agent=iteration-summarizer` (run-phase.sh exports CHAIN_CURRENT_AGENT
# before the call). The sandbox MUST ship .claude/agents/iteration-summarizer.md
# or run-phase.sh skips the dispatch entirely and every case goes vacuous.
#
#   1. goal-iter name + --no-finalize -> summarizer DEFERRED (no dispatch),
#      loud log naming the showcase tail + the escape hatch, pipeline completes
#   2. plain phase name + --no-finalize -> summarizer runs (standalone phase
#      mode keeps its only summary; test-engine-lock.sh drives this shape)
#   3. goal-iter name, no flag (manual rerun) -> summarizer runs
#   4. goal-iter name + --no-finalize + CHAIN_FULL_ITER_SUMMARY=true -> runs
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

# Keep run-phase.sh's port logic pinned and its fuser cleanup away from real ports.
TEST_BE_PORT=48321
TEST_FE_PORT=48322

# Generate a stub step script into the sandbox: records its dispatch to the
# canary, writes the artifact(s) + verdict line the pipeline's gates check.
#   write_stub <script-name> <verdict-or-""> [repo-rel artifact path...]
write_stub() {
  local name="$1" verdict="$2"; shift 2
  local out="$SBX/scripts/automation/$name"
  {
    echo '#!/usr/bin/env bash'
    echo 'R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"'
    printf 'echo "%s" >> "%s"\n' "$name" "$CANARY"
    local rel
    for rel in "$@"; do
      printf 'mkdir -p "$R/%s"\n' "$(dirname "$rel")"
      printf 'printf "# stub %s\\n\\n" > "$R/%s"\n' "$name" "$rel"
      if [[ -n "$verdict" ]]; then
        printf 'printf "**Verdict:** %s\\n" >> "$R/%s"\n' "$verdict" "$rel"
      fi
    done
    echo 'exit 0'
  } > "$out"
}

# Fresh sandbox per case: engine scripts + config embedded, stub claude on PATH,
# every dispatching step script stubbed, checkpoint pre-seeded to `planned` with
# a backend-only plan. PHASE is per-case (goal-iter vs plain names under test).
make_sandbox() {
  local tag="$1"
  PHASE="$2"
  SBX="$WORK/proj-$tag"
  CANARY="$WORK/canary-$tag.log"
  : > "$CANARY"
  mkdir -p "$SBX"
  cp -r "$ENGINE_ROOT/scripts" "$SBX/"
  cp -r "$ENGINE_ROOT/config" "$SBX/"
  mkdir -p "$SBX/.claude/agents" "$SBX/docs/phases" "$SBX/runs/$PHASE" "$SBX/reports"
  touch "$SBX/.claude/agents/developer.md"            # ensure_cli_assets_synced marker
  touch "$SBX/.claude/agents/iteration-summarizer.md" # WITHOUT this the dispatch is skipped and the test goes vacuous

  write_stub generate-test-plan.sh  ""            "reports/qa/${PHASE}-test-plan.md"
  write_stub dev-phase.sh           ""            "docs/handoffs/${PHASE}-dev.md"
  write_stub review-phase.sh        "PASS"        "reports/reviews/${PHASE}-review.md"
  write_stub ui-impact-phase.sh     ""            "reports/phase-${PHASE}-user-visible-changes.md" "reports/phase-${PHASE}-ui-surface-map.md"
  write_stub qa-phase.sh            "PASS"        "reports/qa/${PHASE}-qa.md"
  write_stub phase-audit.sh         "PASS"        "docs/handoffs/${PHASE}-audit.md"
  write_stub phase-closure-check.sh "CLOSURE-PASS" "reports/phase-${PHASE}-closure-verdict.md"

  # Minimal spec + resume point: Step 1 done, backend-only plan on disk.
  printf '# %s — summary-dedupe control-flow spec\n## GOAL\nExercise Step 10.5.\n## IN SCOPE\n- nothing (control-flow test)\n' "$PHASE" \
    > "$SBX/docs/phases/${PHASE}.md"
  printf '# %s Execution Plan\n\nFrontend Present: no\n' "$PHASE" > "$SBX/runs/$PHASE/plan.md"
  printf '{"phase":"%s","status":"in_progress","current_step":"planned"}\n' "$PHASE" \
    > "$SBX/runs/$PHASE/status.json"
}

# Stub claude: satisfies require_cli and records every agent dispatch (the
# summarizer is the only one left un-stubbed at the step-script level).
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<EOF
#!/usr/bin/env bash
echo "claude agent=\${CHAIN_CURRENT_AGENT:-unknown}" >> "\${CANARY_FILE:-/dev/null}"
exit 0
EOF
chmod +x "$STUB_DIR/claude"

unset GOAL_SESSION_DIR GOAL_SESSION_ID GOAL_ITER_INDEX CHAIN_FULL_ITER_SUMMARY || true

# run_phase <tag> <full-iter-summary-knob: true|""> [extra run-phase args...]
run_phase() {
  local tag="$1" knob="$2"; shift 2
  local rc=0
  ( cd "$SBX" && env \
      PATH="$STUB_DIR:$PATH" \
      CANARY_FILE="$CANARY" \
      CHAIN_BACKEND_PORT="$TEST_BE_PORT" CHAIN_FRONTEND_PORT="$TEST_FE_PORT" \
      CHAIN_TMP_ROOT="$WORK/tmproot" CHAIN_TMP_JANITOR=false CHAIN_TMP_DISK_GUARD=false \
      CHAIN_DISABLE_TRACE=true \
      ${knob:+CHAIN_FULL_ITER_SUMMARY="$knob"} \
      bash scripts/automation/run-phase.sh "$PHASE" "$@" ) > "$WORK/run-$tag.log" 2>&1 || rc=$?
  return $rc
}

summarizer_dispatched() {
  grep -q '^claude agent=iteration-summarizer$' "$CANARY"
}

# ══ Case 1: goal-iter name + --no-finalize → summarizer deferred ══════════════
make_sandbox c1 "goal-sx-iter-1"
rc=0; run_phase c1 "" --no-finalize || rc=$?
[[ $rc -eq 0 ]] && assert "1: phase run completes (rc=0)" "pass" \
  || { assert "1: phase run completes (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/run-c1.log"; }
summarizer_dispatched \
  && assert "1: NO summarizer dispatch in goal-mode full iteration" "fail" \
  || assert "1: NO summarizer dispatch in goal-mode full iteration" "pass"
grep -q 'summary deferred to the goal-mode showcase' "$WORK/run-c1.log" \
  && assert "1: deferral is logged loudly" "pass" \
  || assert "1: deferral is logged loudly" "fail"
grep -q 'CHAIN_FULL_ITER_SUMMARY=true' "$WORK/run-c1.log" \
  && assert "1: log names the escape hatch" "pass" \
  || assert "1: log names the escape hatch" "fail"
grep -q 'ALL CHECKS PASSED' "$WORK/run-c1.log" \
  && assert "1: pipeline still runs to completion after the deferral" "pass" \
  || assert "1: pipeline still runs to completion after the deferral" "fail"

# ══ Case 2: plain phase name + --no-finalize → summarizer runs ════════════════
make_sandbox c2 "phase-sd"
rc=0; run_phase c2 "" --no-finalize || rc=$?
[[ $rc -eq 0 ]] && assert "2: phase run completes (rc=0)" "pass" \
  || { assert "2: phase run completes (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/run-c2.log"; }
summarizer_dispatched \
  && assert "2: standalone --no-finalize phase keeps its summarizer" "pass" \
  || assert "2: standalone --no-finalize phase keeps its summarizer" "fail"

# ══ Case 3: goal-iter name WITHOUT --no-finalize (manual rerun) → runs ════════
make_sandbox c3 "goal-sx-iter-1"
rc=0; run_phase c3 "" || rc=$?
[[ $rc -eq 0 ]] && assert "3: phase run completes (rc=0)" "pass" \
  || { assert "3: phase run completes (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/run-c3.log"; }
summarizer_dispatched \
  && assert "3: manual rerun on a goal-iter name keeps its summarizer" "pass" \
  || assert "3: manual rerun on a goal-iter name keeps its summarizer" "fail"

# ══ Case 4: goal-iter + --no-finalize + escape hatch → runs ═══════════════════
make_sandbox c4 "goal-sx-iter-1"
rc=0; run_phase c4 "true" --no-finalize || rc=$?
[[ $rc -eq 0 ]] && assert "4: phase run completes (rc=0)" "pass" \
  || { assert "4: phase run completes (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/run-c4.log"; }
summarizer_dispatched \
  && assert "4: CHAIN_FULL_ITER_SUMMARY=true restores the pre-evaluator run" "pass" \
  || assert "4: CHAIN_FULL_ITER_SUMMARY=true restores the pre-evaluator run" "fail"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
