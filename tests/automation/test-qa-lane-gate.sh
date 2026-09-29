#!/usr/bin/env bash
# test-qa-lane-gate.sh — anti-pattern 36 regression test: run-phase.sh never
# lets a QA PASS stand beside a required browser lane that is not PASS, and a
# QA failure caused by that lane is retried in a way that can actually succeed.
#
# The bug (goal-taketwo iter 12): the browser lane read `Browser QA Verdict:
# FAIL`, the QA agent wrote `**Verdict:** PASS` / "All validations passed", and
# run-phase.sh went on to the audit, closure and "ALL CHECKS PASSED".
#
# Same phase-mode sandbox harness as test-audit-rerun-cap.sh: engine scripts
# copied, step scripts stubbed (canary via $CANARY_FILE), run-phase.sh's own
# logic runs for real. Each case resumes from a checkpoint (default
# `browser_qa_complete`: Steps 1-6 skipped, Step 7 QA loop live) with a
# pre-seeded browser-lane results file and a Frontend Present: yes plan unless
# noted. The browser-lane stub (browser-qa-phase.sh) writes the case's "re-run"
# lane, so a re-run can keep the lane red or show it fixed. MAX_RETRIES is 3.
#
#   A.  QA agent PASS + lane FAIL, the lane stays red -> every QA attempt is
#       gated to FAIL; each fix attempt runs dev + review and then RE-RUNS the
#       browser lane (a QA retry against a stale lane could never pass); after 3
#       QA attempts the phase fails qa_failed; no audit, closure or "ALL CHECKS
#       PASSED"; the lane rows are never converted to PASS.
#   A2. Same, but the fix works: the re-run lane reads PASS -> completes.
#   B.  QA agent PASS + lane PASS  -> completes; QA report byte-identical.
#   C.  QA agent PASS + lane SKIPPED (Chrome infra), stays SKIPPED -> the lane is
#       re-run WITHOUT a dev fix (nothing in the code failed to verify); qa_failed.
#   C2. Same, but the re-run lane reads PASS -> completes with no dev fix.
#   C3. QA agent FAIL (its own checks) + a SKIPPED lane that stays SKIPPED -> the
#       agent's FAIL still gets a dev fix every attempt (the lane-only route is
#       for a QA failure the lane alone caused), and the lane re-runs after it.
#   D.  backend-only phase (Frontend Present: no, no lane file) + QA PASS ->
#       completes; gate is a no-op.
#   E.  QA agent FAIL + lane FAIL -> the fix loop owns the agent FAIL (dev runs)
#       and re-runs the failing lane before each retry.
#   F.  QA agent PASS + the only failing row is a check the PRE-RUN test plan
#       marks P2 (goal-taketwo iter 13's UT-06) -> completes; QA recorded as
#       PASS_WITH_NOTES citing the row; audit runs.
#   G.  QA agent PASS + a failing row the pre-run plan marks P1 -> gated like A.
#   H.  QA agent PASS + lane headline PASS whose only journey row reads
#       `PASS (with disclosed … caveat, not a product defect)` (goal-taketwo iter 19,
#       anti-pattern 38) -> gated like A: a qualified journey PASS is not a pass.
#   K.  A QA PASS already on record (checkpoint audit_passed) beside a lane that
#       now fails -> the QA loop re-opens at the fix step (no QA re-run first),
#       and the steps that trusted the overturned verdict (UX regression, audit)
#       run again.
#   M.  Resume from qa_failed with a SKIPPED lane -> the lane re-runs BEFORE QA
#       (not the demo), so a recovered browser lets the phase pass.
#   M2. Resume from qa_failed with a FAILING lane on the same code -> neither a
#       lane re-run nor a QA run first (both would repeat what is on record): the
#       loop starts at its fix step, then re-runs the lane, then QA.
#   N.  The gate crashes after the Step 9 hardening QA re-run -> fails closed
#       (audit_qa_failed), never lets the agent's PASS stand unchecked.
#   P.  The lane-status read crashes on a failing attempt -> fails closed
#       (qa_failed); no fix route is chosen on an unread lane.
#   Q.  The lane re-run keeps hitting the usage quota -> the phase stops
#       resumably with exit 75 at checkpoint browser_lane_pending (not the
#       artifact-guessing quota_blocked), and the resume re-runs the lane first.
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

# write_lane <dest> <FAIL|PASS|SKIPPED|P2FAIL|P1FAIL|QUALIFIED>
write_lane() {
  local dest="$1" lane="$2"
  if [[ "$lane" == "P2FAIL" || "$lane" == "P1FAIL" ]]; then
    {
      printf '# Phase %s — UI Test Results\n\n**Browser QA Verdict:** FAIL\n\n## Results Table\n' "$PHASE"
      printf '| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n|---|---|---|---|---|---|---|---|\n'
      printf '| UT-J-01 | upload | journey | P1 | ok | ok | PASS | a.png |\n'
      if [[ "$lane" == "P2FAIL" ]]; then
        printf '| UT-01 | smoke | smoke | P1 | ok | ok | PASS | s.png |\n'
        printf '| UT-06 | lifecycle | regression | P2 | excluded | still listed | FAIL | f.png |\n'
      else
        printf '| UT-01 | smoke | smoke | P1 | ok | error | FAIL | s.png |\n'
      fi
    } > "$dest"
  elif [[ "$lane" == "QUALIFIED" ]]; then
    {
      printf '# Phase %s — UI Test Results\n\n**Browser QA Verdict:** PASS\n\n## Results Table\n' "$PHASE"
      printf '| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n|---|---|---|---|---|---|---|---|\n'
      printf '| UT-01 | smoke | smoke | P1 | ok | ok | PASS | s.png |\n'
      printf '| **UT-J-01** | upload | journey | P1 | none Reused from cache | Reused from cache (setup warmed it) | PASS (with disclosed test-contamination caveat, not a product defect) | a.png |\n'
    } > "$dest"
  else
    {
      printf '# Phase %s — UI Test Results\n\n**Browser QA Verdict:** %s\n\n## Results Table\n' "$PHASE" "$lane"
      printf '| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n|---|---|---|---|---|---|---|---|\n'
      printf '| UT-J-01 | upload | browser | P1 | ok | ok | PASS | a.png |\n'
      [[ "$lane" == "FAIL" ]] && printf '| UT-J-06 | correction | browser | P1 | ok | replay miss | FAIL | b.png |\n'
      [[ "$lane" == "SKIPPED" ]] && printf '| UT-J-06 | correction | browser | P1 | ok | Chrome did not become ready | SKIP | - |\n'
      true
    } > "$dest"
  fi
}

# make_sandbox <tag> <qa-verdict> <lane|none> <frontend yes|no> [re-run lane] [checkpoint]
#   re-run lane: what browser-qa-phase.sh writes when the engine re-runs the lane
#   (default: the same as <lane>, i.e. the lane stays as it is).
make_sandbox() {
  local tag="$1" qa_verdict="$2" lane="$3" frontend="$4" rerun="${5:-$3}" checkpoint="${6:-browser_qa_complete}"
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
  write_stub demo-phase.sh          ""
  # The browser lane: writes the case's re-run lane (never the engine's business
  # to convert it — the rows are whatever the lane produced).
  cat > "$SBX/scripts/automation/browser-qa-phase.sh" <<'STUB'
#!/usr/bin/env bash
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
echo "browser-qa-phase.sh" >> "${CANARY_FILE:-/dev/null}"
[[ -f "$R/.lane-rerun-rc" ]] && exit "$(cat "$R/.lane-rerun-rc")"
[[ -f "$R/.lane-rerun.md" ]] && cp "$R/.lane-rerun.md" "$R/reports/phase-$1-ui-test-results.md"
exit 0
STUB

  # The pre-run UI test plan (the gate's only priority source).
  printf '# UI test plan\n\n| ID | Name | Type | Priority | Surface |\n|---|---|---|---|---|\n| UT-01 | smoke | smoke | P1 | / |\n| UT-06 | lifecycle | regression | P2 | / |\n' \
    > "$SBX/reports/phase-${PHASE}-ui-test-plan.md"
  if [[ "$lane" != "none" ]]; then
    write_lane "$SBX/reports/phase-${PHASE}-ui-test-results.md" "$lane"
    cp "$SBX/reports/phase-${PHASE}-ui-test-results.md" "$WORK/lane-$tag.orig"
    write_lane "$SBX/.lane-rerun.md" "$rerun"
  fi

  printf '# %s Execution Plan\n\nFrontend Present: %s\n' "$PHASE" "$frontend" > "$SBX/runs/$PHASE/plan.md"
  printf '{"phase":"%s","status":"in_progress","current_step":"%s"}\n' "$PHASE" "$checkpoint" \
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
      CHAIN_DISABLE_TRACE=true CHAIN_CLAUDE_FALLBACK_SLEEP_SECONDS=0 \
      bash scripts/automation/run-phase.sh "$PHASE" ) > "$WORK/run-$tag.log" 2>&1 || rc=$?
  return $rc
}

count() { local c; c="$(grep -c "^$1\$" "$CANARY" 2>/dev/null || true)"; echo "${c:-0}"; }
counts() { echo "qa=$(count qa-phase.sh) dev=$(count dev-phase.sh) lane=$(count browser-qa-phase.sh) audit=$(count phase-audit.sh)"; }
qa_passes() { python3 "$SBX/scripts/automation/lib/verdicts.py" check-verdict "$SBX/reports/qa/${PHASE}-qa.md"; }
step_is() { grep -q "\"current_step\": \"$1\"" "$SBX/runs/$PHASE/status.json"; }
lane_is() { cmp -s "$SBX/reports/phase-${PHASE}-ui-test-results.md" "$1"; }

# ══ Case A: QA PASS + lane FAIL that stays red — the iter-12 false green ═════
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
lane_is "$WORK/lane-a.orig" \
  && assert "A: browser-lane results never converted (still the lane's own FAIL)" "pass" \
  || assert "A: browser-lane results never converted (still the lane's own FAIL)" "fail"
[[ "$(count qa-phase.sh)" == "3" && "$(count dev-phase.sh)" == "2" && "$(count browser-qa-phase.sh)" == "2" ]] \
  && assert "A: each fix attempt re-ran the browser lane before QA retried (3 QA, 2 dev, 2 lane)" "pass" \
  || assert "A: each fix attempt re-ran the browser lane before QA retried ($(counts))" "fail"
[[ "$(count phase-audit.sh)" == "0" && "$(count phase-closure-check.sh)" == "0" ]] \
  && assert "A: audit and closure never ran on the gated FAIL" "pass" \
  || assert "A: audit and closure never ran (audit=$(count phase-audit.sh) closure=$(count phase-closure-check.sh))" "fail"
grep -q 'ALL CHECKS PASSED' "$WORK/run-a.log" \
  && assert "A: no ALL CHECKS PASSED banner" "fail" || assert "A: no ALL CHECKS PASSED banner" "pass"

# ══ Case A2: the fix works — the re-run lane passes ═══════════════════════════
make_sandbox a2 PASS FAIL yes PASS
rc=0; run_phase a2 || rc=$?
[[ $rc -eq 0 ]] && qa_passes && assert "A2: phase completes once the re-run lane passes" "pass" \
  || { assert "A2: phase completes once the re-run lane passes (rc=$rc)" "fail"; sed -n '1,80p' "$WORK/run-a2.log"; }
[[ "$(count qa-phase.sh)" == "2" && "$(count dev-phase.sh)" == "1" && "$(count browser-qa-phase.sh)" == "1" && "$(count phase-audit.sh)" == "1" ]] \
  && assert "A2: one fix, one lane re-run, QA retried once, audit ran" "pass" \
  || assert "A2: one fix, one lane re-run, QA retried once, audit ran ($(counts))" "fail"

# ══ Case B: QA PASS + lane PASS — consistent, unchanged ══════════════════════
make_sandbox b PASS PASS yes
rc=0; run_phase b || rc=$?
[[ $rc -eq 0 ]] && assert "B: phase completes (rc=0)" "pass" \
  || { assert "B: phase completes (rc=$rc)" "fail"; sed -n '1,60p' "$WORK/run-b.log"; }
qa_passes && ! grep -q 'Browser lane gate' "$SBX/reports/qa/${PHASE}-qa.md" \
  && assert "B: QA report still passing and not annotated" "pass" \
  || assert "B: QA report still passing and not annotated" "fail"
[[ "$(count phase-audit.sh)" == "1" && "$(count browser-qa-phase.sh)" == "0" ]] \
  && assert "B: audit ran; the passing lane was not re-run" "pass" || assert "B: audit ran; lane not re-run ($(counts))" "fail"

# ══ Case C: QA PASS + lane SKIPPED (browser infra) that stays SKIPPED ════════
make_sandbox c PASS SKIPPED yes
rc=0; run_phase c || rc=$?
[[ $rc -ne 0 ]] && step_is qa_failed && ! qa_passes \
  && assert "C: SKIPPED required lane fails QA (qa_failed)" "pass" \
  || assert "C: SKIPPED required lane fails QA (rc=$rc)" "fail"
[[ "$(count dev-phase.sh)" == "0" && "$(count browser-qa-phase.sh)" == "2" && "$(count qa-phase.sh)" == "3" ]] \
  && assert "C: an evidence-less lane is re-run with NO dev fix (3 QA, 0 dev, 2 lane)" "pass" \
  || assert "C: an evidence-less lane is re-run with NO dev fix ($(counts))" "fail"
[[ "$(count phase-audit.sh)" == "0" ]] && assert "C: audit never ran" "pass" || assert "C: audit never ran" "fail"

# ══ Case C2: the browser recovers on the re-run ══════════════════════════════
make_sandbox c2 PASS SKIPPED yes PASS
rc=0; run_phase c2 || rc=$?
[[ $rc -eq 0 && "$(count dev-phase.sh)" == "0" && "$(count browser-qa-phase.sh)" == "1" && "$(count phase-audit.sh)" == "1" ]] \
  && assert "C2: a recovered lane lets the phase pass with no dev fix" "pass" \
  || { assert "C2: a recovered lane lets the phase pass with no dev fix (rc=$rc $(counts))" "fail"; sed -n '1,80p' "$WORK/run-c2.log"; }

# ══ Case C3: an agent-owned FAIL beside a SKIPPED lane still gets its fix ════
make_sandbox c3 FAIL SKIPPED yes
rc=0; run_phase c3 || rc=$?
[[ $rc -ne 0 ]] && step_is qa_failed && assert "C3: phase fails qa_failed" "pass" || assert "C3: phase fails qa_failed (rc=$rc)" "fail"
[[ "$(count dev-phase.sh)" == "2" && "$(count browser-qa-phase.sh)" == "2" ]] \
  && assert "C3: the agent's own FAIL got a dev fix each attempt, then a lane re-run" "pass" \
  || assert "C3: the agent's own FAIL got a dev fix each attempt, then a lane re-run ($(counts))" "fail"

# ══ Case D: backend-only phase — lane not required, gate is a no-op ══════════
make_sandbox d PASS none no
rc=0; run_phase d || rc=$?
[[ $rc -eq 0 ]] && qa_passes && ! grep -q 'Browser lane gate' "$SBX/reports/qa/${PHASE}-qa.md" \
  && assert "D: backend-only phase completes with its QA PASS intact" "pass" \
  || { assert "D: backend-only phase completes with its QA PASS intact (rc=$rc)" "fail"; sed -n '1,60p' "$WORK/run-d.log"; }

# ══ Case E: QA agent FAIL beside a failing lane ══════════════════════════════
make_sandbox e FAIL FAIL yes
rc=0; run_phase e || rc=$?
[[ $rc -ne 0 ]] && step_is qa_failed && assert "E: agent FAIL still fails qa_failed" "pass" \
  || assert "E: agent FAIL still fails qa_failed (rc=$rc)" "fail"
[[ "$(count dev-phase.sh)" == "2" && "$(count browser-qa-phase.sh)" == "2" ]] \
  && assert "E: dev fix-mode ran for the agent FAIL, and the failing lane re-ran after each fix" "pass" \
  || assert "E: dev fix-mode ran, and the failing lane re-ran after each fix ($(counts))" "fail"
grep -q 'Browser lane gate' "$SBX/reports/qa/${PHASE}-qa.md" \
  && assert "E: agent FAIL report not annotated by the gate" "fail" || assert "E: agent FAIL report not annotated by the gate" "pass"

# ══ Case F: only a pre-run-P2 check fails — a finding, not a DoD failure ═════
make_sandbox f PASS P2FAIL yes
rc=0; run_phase f || rc=$?
[[ $rc -eq 0 ]] && assert "F: phase completes (rc=0)" "pass" \
  || { assert "F: phase completes (rc=$rc)" "fail"; sed -n '1,60p' "$WORK/run-f.log"; }
qa_passes && grep -q '^\*\*Verdict:\*\* PASS_WITH_NOTES$' "$SBX/reports/qa/${PHASE}-qa.md" \
  && assert "F: QA recorded as PASS_WITH_NOTES, never plain PASS" "pass" \
  || assert "F: QA recorded as PASS_WITH_NOTES, never plain PASS" "fail"
grep -q 'UT-06: FAIL (pre-run plan priority P2)' "$SBX/reports/qa/${PHASE}-qa.md" \
  && assert "F: the P2 finding is cited in the QA report" "pass" \
  || assert "F: the P2 finding is cited in the QA report" "fail"
[[ "$(count phase-audit.sh)" == "1" && "$(count browser-qa-phase.sh)" == "0" ]] \
  && assert "F: audit ran; a findings-only lane is not re-run" "pass" || assert "F: audit ran; lane not re-run ($(counts))" "fail"

# ══ Case G: a pre-run-P1 check fails — DoD failure, blocks ═══════════════════
make_sandbox g PASS P1FAIL yes
rc=0; run_phase g || rc=$?
[[ $rc -ne 0 ]] && step_is qa_failed && ! qa_passes \
  && grep -q 'UT-01: FAIL (pre-run plan priority P1)' "$SBX/reports/qa/${PHASE}-qa.md" \
  && assert "G: a failing pre-run-P1 check fails QA (qa_failed), row cited" "pass" \
  || assert "G: a failing pre-run-P1 check fails QA (rc=$rc)" "fail"
[[ "$(count phase-audit.sh)" == "0" ]] && assert "G: audit never ran" "pass" || assert "G: audit never ran" "fail"

# ══ Case H: a qualified journey PASS — the iter-19 caveated green ════════════
make_sandbox h PASS QUALIFIED yes
rc=0; run_phase h || rc=$?
[[ $rc -ne 0 ]] && step_is qa_failed && ! qa_passes \
  && grep -q 'UT-J-01: qualified PASS' "$SBX/reports/qa/${PHASE}-qa.md" \
  && assert "H: a qualified journey PASS fails QA (qa_failed), row cited" "pass" \
  || { assert "H: a qualified journey PASS fails QA (rc=$rc)" "fail"; sed -n '1,60p' "$WORK/run-h.log"; }
lane_is "$WORK/lane-h.orig" \
  && assert "H: browser-lane results untouched" "pass" || assert "H: browser-lane results untouched" "fail"
[[ "$(count phase-audit.sh)" == "0" ]] && assert "H: audit never ran" "pass" || assert "H: audit never ran" "fail"

# ══ Case K: a recorded QA PASS overturned by the lane re-opens the QA loop ═══
make_sandbox k PASS FAIL yes PASS audit_passed
mkdir -p "$SBX/reports/qa"
printf '# QA\n\n**Verdict:** PASS\n\nAll validations passed.\n' > "$SBX/reports/qa/${PHASE}-qa.md"
rc=0; run_phase k || rc=$?
[[ $rc -eq 0 ]] && qa_passes && assert "K: overturned QA re-opens the loop and the fixed phase completes" "pass" \
  || { assert "K: overturned QA re-opens the loop and the fixed phase completes (rc=$rc)" "fail"; sed -n '1,80p' "$WORK/run-k.log"; }
[[ "$(count dev-phase.sh)" == "1" && "$(count browser-qa-phase.sh)" == "1" && "$(count qa-phase.sh)" == "1" ]] \
  && assert "K: fix first — no QA re-run before the fix (1 dev, 1 lane, 1 QA)" "pass" \
  || assert "K: fix first — no QA re-run before the fix ($(counts))" "fail"
[[ "$(count ux-regression-phase.sh)" == "1" && "$(count phase-audit.sh)" == "1" ]] \
  && assert "K: UX regression and audit re-ran (they trusted the overturned verdict)" "pass" \
  || assert "K: UX regression and audit re-ran (ux=$(count ux-regression-phase.sh) $(counts))" "fail"

# ══ Case M: resume from qa_failed re-runs a SKIPPED lane before QA ═══════════
make_sandbox m PASS SKIPPED yes PASS qa_failed
mkdir -p "$SBX/reports/qa"
printf '# QA\n\n**Verdict:** FAIL\n\nlane SKIPPED\n' > "$SBX/reports/qa/${PHASE}-qa.md"
rc=0; run_phase m || rc=$?
[[ $rc -eq 0 ]] && qa_passes && assert "M: resumed phase passes once the lane recovers" "pass" \
  || { assert "M: resumed phase passes once the lane recovers (rc=$rc)" "fail"; sed -n '1,80p' "$WORK/run-m.log"; }
[[ "$(grep -m1 -E '^(browser-qa|qa)-phase\.sh$' "$CANARY" || true)" == "browser-qa-phase.sh" \
   && "$(count browser-qa-phase.sh)" == "1" && "$(count qa-phase.sh)" == "1" && "$(count dev-phase.sh)" == "0" ]] \
  && assert "M: the lane re-ran BEFORE QA; one QA attempt, no dev fix" "pass" \
  || assert "M: the lane re-ran BEFORE QA ($(counts); first=$(grep -m1 -E '^(browser-qa|qa)-phase\.sh$' "$CANARY" || true))" "fail"
[[ "$(count demo-phase.sh)" == "0" ]] && assert "M: the showcase demo is not re-run for a lane re-run" "pass" \
  || assert "M: the showcase demo is not re-run for a lane re-run (demo=$(count demo-phase.sh))" "fail"

# ══ Case N: the gate crashes after the Step 9 hardening QA re-run ════════════
make_sandbox n PASS PASS yes
mv "$SBX/scripts/automation/lib/qa_lane_gate.py" "$SBX/scripts/automation/lib/qa_lane_gate_real.py"
cat > "$SBX/scripts/automation/lib/qa_lane_gate.py" <<'PY'
#!/usr/bin/env python3
# Test double: the real gate, except its 2nd `apply` crashes (the Step 9 hardening call).
import os, runpy, sys
here = os.path.dirname(os.path.abspath(__file__))
if sys.argv[1:2] == ["apply"]:
    cnt = os.path.join(here, ".gate-apply-calls")
    n = (int(open(cnt).read()) if os.path.exists(cnt) else 0) + 1
    open(cnt, "w").write(str(n))
    if n == 2:
        raise SystemExit("simulated qa_lane_gate crash")
runpy.run_path(os.path.join(here, "qa_lane_gate_real.py"), run_name="__main__")
PY
cat > "$SBX/scripts/automation/phase-audit.sh" <<'STUB'
#!/usr/bin/env bash
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
echo "phase-audit.sh" >> "${CANARY_FILE:-/dev/null}"
v=PASS; [[ "$(grep -c '^phase-audit.sh$' "${CANARY_FILE:-/dev/null}" || true)" == "1" ]] && v=FAIL
mkdir -p "$R/docs/handoffs"; printf '# stub audit\n\n**Verdict:** %s\n' "$v" > "$R/docs/handoffs/$1-audit.md"
exit 0
STUB
rc=0; run_phase n || rc=$?
[[ $rc -ne 0 ]] && step_is audit_qa_failed \
  && assert "N: a gate crash after the hardening QA re-run fails closed (audit_qa_failed)" "pass" \
  || { assert "N: a gate crash after the hardening QA re-run fails closed (rc=$rc)" "fail"; sed -n '1,90p' "$WORK/run-n.log"; }
[[ "$(count phase-audit.sh)" == "1" ]] && assert "N: no second audit on an unchecked QA verdict" "pass" \
  || assert "N: no second audit on an unchecked QA verdict (audit=$(count phase-audit.sh))" "fail"

# ══ Case M2: qa_failed resume, failing lane on unchanged code ═══════════════
make_sandbox m2 PASS FAIL yes PASS qa_failed
mkdir -p "$SBX/reports/qa"
printf '# QA\n\n**Verdict:** FAIL\n\nlane FAIL\n' > "$SBX/reports/qa/${PHASE}-qa.md"
rc=0; run_phase m2 || rc=$?
[[ $rc -eq 0 ]] && qa_passes && assert "M2: resumed phase fixes and passes" "pass" \
  || { assert "M2: resumed phase fixes and passes (rc=$rc)" "fail"; sed -n '1,80p' "$WORK/run-m2.log"; }
[[ "$(grep -m1 -E '^(dev|browser-qa|qa)-phase\.sh$' "$CANARY" || true)" == "dev-phase.sh" \
   && "$(count qa-phase.sh)" == "1" && "$(count dev-phase.sh)" == "1" && "$(count browser-qa-phase.sh)" == "1" ]] \
  && assert "M2: fix first (no repeat lane or QA run on unchanged code), then lane re-run, then QA" "pass" \
  || assert "M2: fix first, then lane re-run, then QA ($(counts); first=$(grep -m1 -E '^(dev|browser-qa|qa)-phase\.sh$' "$CANARY" || true))" "fail"

# ══ Case P: lane-status cannot be read on a failing attempt ══════════════════
make_sandbox p FAIL FAIL yes
mv "$SBX/scripts/automation/lib/qa_lane_gate.py" "$SBX/scripts/automation/lib/qa_lane_gate_real.py"
cat > "$SBX/scripts/automation/lib/qa_lane_gate.py" <<'PY2'
#!/usr/bin/env python3
# Test double: the real gate, except `lane-status` crashes.
import os, runpy, sys
here = os.path.dirname(os.path.abspath(__file__))
if sys.argv[1:2] == ["lane-status"]:
    raise SystemExit("simulated lane-status crash")
runpy.run_path(os.path.join(here, "qa_lane_gate_real.py"), run_name="__main__")
PY2
rc=0; run_phase p || rc=$?
[[ $rc -ne 0 ]] && step_is qa_failed && grep -q 'could not be evaluated' "$WORK/run-p.log" \
   && [[ "$(count dev-phase.sh)" == "0" && "$(count browser-qa-phase.sh)" == "0" ]] \
  && assert "P: an unreadable lane status fails closed; no fix route chosen" "pass" \
  || { assert "P: an unreadable lane status fails closed (rc=$rc $(counts))" "fail"; sed -n '1,80p' "$WORK/run-p.log"; }

# ══ Case Q: the lane re-run keeps hitting the usage quota ════════════════════
make_sandbox q PASS SKIPPED yes
echo 75 > "$SBX/.lane-rerun-rc"
rc=0; run_phase q || rc=$?
[[ $rc -eq 75 && "$(count qa-phase.sh)" == "1" ]] && step_is browser_lane_pending \
  && assert "Q: quota during the lane re-run stops resumably (exit 75, checkpoint browser_lane_pending)" "pass" \
  || { assert "Q: quota during the lane re-run stops resumably (rc=$rc $(counts))" "fail"; sed -n '1,80p' "$WORK/run-q.log"; }
rm -f "$SBX/.lane-rerun-rc"; write_lane "$SBX/.lane-rerun.md" PASS; : > "$CANARY"
rc=0; run_phase q-resume || rc=$?
[[ $rc -eq 0 && "$(grep -m1 -E '^(browser-qa|qa)-phase\.sh$' "$CANARY" || true)" == "browser-qa-phase.sh" \
   && "$(count phase-audit.sh)" == "1" ]] && qa_passes \
  && assert "Q: the resume re-runs the lane first, then QA passes and the audit runs" "pass" \
  || { assert "Q: the resume re-runs the lane first ($(counts) rc=$rc)" "fail"; sed -n '1,80p' "$WORK/run-q-resume.log"; }

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
