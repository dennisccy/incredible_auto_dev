#!/usr/bin/env bash
# test-qa-lane-gate.sh — anti-pattern 36 regression test: run-phase.sh never
# lets a QA PASS stand beside a required browser lane that is not PASS.
#
# The bug (goal-taketwo iter 12): the browser lane read `Browser QA Verdict:
# FAIL`, the QA agent wrote `**Verdict:** PASS` / "All validations passed", and
# run-phase.sh went on to the audit, closure and "ALL CHECKS PASSED".
#
# Same phase-mode sandbox harness as test-audit-rerun-cap.sh: engine scripts
# copied, step scripts stubbed (canary via $CANARY_FILE), run-phase.sh's own
# logic runs for real. Each case resumes from checkpoint `browser_qa_complete`
# (Steps 1-6 skipped, Step 7 QA loop live) with a pre-seeded browser-lane
# results file and a Frontend Present: yes plan unless noted.
#
#   A. QA agent PASS + lane FAIL  -> phase fails qa_failed; QA report rewritten
#      to FAIL naming the failing rows; no dev fix loop, no audit, no closure,
#      no "ALL CHECKS PASSED"; the browser rows are not converted to PASS.
#   B. QA agent PASS + lane PASS  -> completes; QA report byte-identical.
#   C. QA agent PASS + lane SKIPPED (Chrome infra) -> fails like A.
#   D. backend-only phase (Frontend Present: no, no lane file) + QA PASS ->
#      completes; gate is a no-op.
#   E. QA agent FAIL + lane FAIL  -> the ordinary Step 7 fix loop still owns an
#      agent FAIL (dev fix-mode runs), unchanged semantics.
#
# No API calls; a few seconds per case.
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

PHASE="phase-qlg"
TEST_BE_PORT=48331
TEST_FE_PORT=48332

# write_stub <name> <verdict|""> [rel...] — records "<name>" to $CANARY_FILE,
# writes each artifact with the verdict line, exits 0.
write_stub() {
  local name="$1" verdict="$2"; shift 2
  local out="$SBX/scripts/automation/$name"
  {
    echo '#!/usr/bin/env bash'
    echo 'R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"'
    printf 'echo "%s" >> "%s"\n' "$name" '${CANARY_FILE:-/dev/null}'
    local rel
    for rel in "$@"; do
      printf 'mkdir -p "$R/%s"\n' "$(dirname "$rel")"
      printf 'printf "# stub %s\\n\\n" > "$R/%s"\n' "$name" "$rel"
      [[ -n "$verdict" ]] && printf 'printf "**Verdict:** %s\\n\\nAll validations passed.\\n" >> "$R/%s"\n' "$verdict" "$rel"
    done
    echo 'exit 0'
  } > "$out"
}

# make_sandbox <tag> <qa-verdict> <lane-headline|none> <frontend yes|no>
make_sandbox() {
  local tag="$1" qa_verdict="$2" lane="$3" frontend="$4"
  SBX="$WORK/proj-$tag"
  CANARY="$WORK/canary-$tag.log"
  : > "$CANARY"
  mkdir -p "$SBX"
  cp -r "$ENGINE_ROOT/scripts" "$SBX/"
  cp -r "$ENGINE_ROOT/config" "$SBX/"
  mkdir -p "$SBX/.claude/agents" "$SBX/docs/phases" "$SBX/runs/$PHASE" "$SBX/reports"
  touch "$SBX/.claude/agents/developer.md"
  printf '# Phase qlg — QA-lane gate test spec\n## GOAL\nExercise the QA-lane gate.\n' > "$SBX/docs/phases/${PHASE}.md"

  write_stub dev-phase.sh           ""                     "docs/handoffs/${PHASE}-dev.md"
  write_stub review-phase.sh        "PASS"                 "reports/reviews/${PHASE}-review.md"
  write_stub qa-phase.sh            "$qa_verdict"          "reports/qa/${PHASE}-qa.md"
  write_stub ux-regression-phase.sh "UX-REGRESSION-PASS"   "reports/phase-${PHASE}-ux-regression.md"
  write_stub phase-audit.sh         "PASS"                 "docs/handoffs/${PHASE}-audit.md"
  write_stub phase-closure-check.sh "CLOSURE-PASS"         "reports/phase-${PHASE}-closure-verdict.md"

  if [[ "$lane" != "none" ]]; then
    {
      printf '# Phase %s — UI Test Results\n\n**Browser QA Verdict:** %s\n\n## Results Table\n' "$PHASE" "$lane"
      printf '| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n|---|---|---|---|---|---|---|---|\n'
      printf '| UT-J-01 | upload | browser | P1 | ok | ok | PASS | a.png |\n'
      [[ "$lane" == "FAIL" ]] && printf '| UT-J-06 | correction | browser | P1 | ok | replay miss | FAIL | b.png |\n'
      [[ "$lane" == "SKIPPED" ]] && printf '| UT-J-06 | correction | browser | P1 | ok | Chrome did not become ready | SKIP | - |\n'
      true
    } > "$SBX/reports/phase-${PHASE}-ui-test-results.md"
    cp "$SBX/reports/phase-${PHASE}-ui-test-results.md" "$WORK/lane-$tag.orig"
  fi

  printf '# %s Execution Plan\n\nFrontend Present: %s\n' "$PHASE" "$frontend" > "$SBX/runs/$PHASE/plan.md"
  printf '{"phase":"%s","status":"in_progress","current_step":"browser_qa_complete"}\n' "$PHASE" \
    > "$SBX/runs/$PHASE/status.json"
}

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/claude"
chmod +x "$STUB_DIR/claude" 2>/dev/null || true

unset GOAL_SESSION_DIR GOAL_SESSION_ID GOAL_ITER_INDEX CHAIN_GOAL_TARGET_JOURNEYS CHAIN_MAINTENANCE_ISOLATION || true

run_phase() {
  local tag="$1" rc=0
  ( cd "$SBX" && env \
      PATH="$STUB_DIR:$PATH" \
      CANARY_FILE="$CANARY" \
      CHAIN_BACKEND_PORT="$TEST_BE_PORT" CHAIN_FRONTEND_PORT="$TEST_FE_PORT" \
      CHAIN_TMP_ROOT="$WORK/tmproot" CHAIN_TMP_JANITOR=false CHAIN_TMP_DISK_GUARD=false \
      CHAIN_DISABLE_TRACE=true \
      bash scripts/automation/run-phase.sh "$PHASE" ) > "$WORK/run-$tag.log" 2>&1 || rc=$?
  return $rc
}

count() { local c; c="$(grep -c "^$1\$" "$CANARY" 2>/dev/null || true)"; echo "${c:-0}"; }
qa_passes() { python3 "$SBX/scripts/automation/lib/verdicts.py" check-verdict "$SBX/reports/qa/${PHASE}-qa.md"; }
step_is() { grep -q "\"current_step\": \"$1\"" "$SBX/runs/$PHASE/status.json"; }

# ══ Case A: QA PASS + lane FAIL — the iter-12 false green ═══════════════════
make_sandbox a PASS FAIL yes
rc=0; run_phase a || rc=$?
[[ $rc -ne 0 ]] && assert "A: phase fails (rc=$rc)" "pass" \
  || { assert "A: phase fails (rc=0 — the false green is back)" "fail"; sed -n '1,60p' "$WORK/run-a.log"; }
step_is qa_failed && assert "A: checkpoint records qa_failed" "pass" \
  || assert "A: checkpoint records qa_failed (got: $(tr '\n' ' ' < "$SBX/runs/$PHASE/status.json"))" "fail"
qa_passes && assert "A: QA report no longer reads as passing" "fail" || assert "A: QA report no longer reads as passing" "pass"
grep -q '^\*\*Verdict:\*\* FAIL$' "$SBX/reports/qa/${PHASE}-qa.md" && grep -q 'UT-J-06: FAIL' "$SBX/reports/qa/${PHASE}-qa.md" \
  && assert "A: QA report says FAIL and names the failing lane row" "pass" \
  || assert "A: QA report says FAIL and names the failing lane row" "fail"
cmp -s "$SBX/reports/phase-${PHASE}-ui-test-results.md" "$WORK/lane-a.orig" \
  && assert "A: browser-lane results untouched (FAIL never converted)" "pass" \
  || assert "A: browser-lane results untouched (FAIL never converted)" "fail"
[[ "$(count qa-phase.sh)" == "1" && "$(count dev-phase.sh)" == "0" ]] \
  && assert "A: QA ran once and no futile dev fix loop ran" "pass" \
  || assert "A: QA ran once and no futile dev fix loop ran (qa=$(count qa-phase.sh) dev=$(count dev-phase.sh))" "fail"
[[ "$(count phase-audit.sh)" == "0" && "$(count phase-closure-check.sh)" == "0" ]] \
  && assert "A: audit and closure never ran on the gated FAIL" "pass" \
  || assert "A: audit and closure never ran (audit=$(count phase-audit.sh) closure=$(count phase-closure-check.sh))" "fail"
grep -q 'ALL CHECKS PASSED' "$WORK/run-a.log" \
  && assert "A: no ALL CHECKS PASSED banner" "fail" || assert "A: no ALL CHECKS PASSED banner" "pass"

# ══ Case B: QA PASS + lane PASS — consistent, unchanged ══════════════════════
make_sandbox b PASS PASS yes
rc=0; run_phase b || rc=$?
[[ $rc -eq 0 ]] && assert "B: phase completes (rc=0)" "pass" \
  || { assert "B: phase completes (rc=$rc)" "fail"; sed -n '1,60p' "$WORK/run-b.log"; }
qa_passes && ! grep -q 'Browser lane gate' "$SBX/reports/qa/${PHASE}-qa.md" \
  && assert "B: QA report still passing and not annotated" "pass" \
  || assert "B: QA report still passing and not annotated" "fail"
[[ "$(count phase-audit.sh)" == "1" ]] && assert "B: audit ran" "pass" || assert "B: audit ran (got $(count phase-audit.sh))" "fail"

# ══ Case C: QA PASS + lane SKIPPED (browser infra) — unverified is not PASS ══
make_sandbox c PASS SKIPPED yes
rc=0; run_phase c || rc=$?
[[ $rc -ne 0 ]] && step_is qa_failed && ! qa_passes \
  && assert "C: SKIPPED required lane fails QA (qa_failed)" "pass" \
  || assert "C: SKIPPED required lane fails QA (rc=$rc)" "fail"
[[ "$(count phase-audit.sh)" == "0" ]] && assert "C: audit never ran" "pass" || assert "C: audit never ran" "fail"

# ══ Case D: backend-only phase — lane not required, gate is a no-op ══════════
make_sandbox d PASS none no
rc=0; run_phase d || rc=$?
[[ $rc -eq 0 ]] && qa_passes && ! grep -q 'Browser lane gate' "$SBX/reports/qa/${PHASE}-qa.md" \
  && assert "D: backend-only phase completes with its QA PASS intact" "pass" \
  || { assert "D: backend-only phase completes with its QA PASS intact (rc=$rc)" "fail"; sed -n '1,60p' "$WORK/run-d.log"; }

# ══ Case E: QA agent FAIL — the ordinary fix loop still owns it ══════════════
make_sandbox e FAIL FAIL yes
rc=0; run_phase e || rc=$?
[[ $rc -ne 0 ]] && step_is qa_failed && assert "E: agent FAIL still fails qa_failed" "pass" \
  || assert "E: agent FAIL still fails qa_failed (rc=$rc)" "fail"
[[ "$(count dev-phase.sh)" -ge 1 ]] \
  && assert "E: dev fix-mode ran for an agent-owned QA FAIL (unchanged semantics)" "pass" \
  || assert "E: dev fix-mode ran for an agent-owned QA FAIL (dev=$(count dev-phase.sh))" "fail"
grep -q 'Browser lane gate' "$SBX/reports/qa/${PHASE}-qa.md" \
  && assert "E: agent FAIL report not annotated by the gate" "fail" || assert "E: agent FAIL report not annotated by the gate" "pass"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
