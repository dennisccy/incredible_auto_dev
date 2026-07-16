#!/usr/bin/env bash
# test-audit-rerun-cap.sh — TOKEN-4 unit test: run-phase.sh Step 9's
# audit-failure hardening caps the expensive FULL rerun (dev + review + full QA)
# at CHAIN_AUDIT_RERUN_CAP completed passes (default 1); later audit FAILs in
# the same run switch to fix-only mode (dev + review + audit re-check, NO full
# QA rerun), loudly logged each time. cap=0 restores the pre-TOKEN-4 behavior
# (full rerun on every failed attempt) — the documented rollback.
#
# Same phase-mode sandbox harness as test-testplan-skip.sh: engine scripts
# embedded, step scripts stubbed (canary via $CANARY_FILE), run-phase.sh's own
# loop logic runs for real. Resumes from checkpoint `audit_failed`, which skips
# Steps 1-8 and re-enters the Step 9 audit loop directly. The audit stub walks
# a per-case verdict sequence ($AUDIT_SEQ); MAX_AUDIT_RETRIES is 3.
#
#   A. default cap (unset -> 1), audit FAIL,FAIL,PASS:
#      hardening pass 1 = FULL (QA fires once), pass 2 = FIX-ONLY (no QA),
#      strong-tier escalation env visible to dev in BOTH modes, run completes.
#   B. cap=0, same sequence: FULL rerun both times (QA fires twice) — rollback.
#   C. QA FAIL inside a full hardening pass still hard-fails the phase as
#      audit_qa_failed (unchanged semantics).
#   D. audit always-FAIL: attempts still exhaust at MAX_AUDIT_RETRIES=3 with
#      audit_failed; QA fired only in the first (full) hardening pass.
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

PHASE="phase-arc"
TEST_BE_PORT=48321
TEST_FE_PORT=48322

# Stub step script: records "name model=<CHAIN_MODEL_OVERRIDE>" to $CANARY_FILE,
# writes artifact(s) + verdict, exits 0. write_stub <name> <verdict|""> [rel...]
write_stub() {
  local name="$1" verdict="$2"; shift 2
  local out="$SBX/scripts/automation/$name"
  {
    echo '#!/usr/bin/env bash'
    echo 'R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"'
    printf 'echo "%s model=%s" >> "%s"\n' "$name" '${CHAIN_MODEL_OVERRIDE:-none}' '${CANARY_FILE:-/dev/null}'
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

# make_sandbox <tag> <qa-verdict> — checkpoint pre-seeded to audit_failed so the
# run re-enters the Step 9 audit loop directly (Steps 1-8 skipped, backend-only).
make_sandbox() {
  local tag="$1" qa_verdict="$2"
  SBX="$WORK/proj-$tag"
  CANARY="$WORK/canary-$tag.log"
  : > "$CANARY"
  mkdir -p "$SBX"
  cp -r "$ENGINE_ROOT/scripts" "$SBX/"
  cp -r "$ENGINE_ROOT/config" "$SBX/"
  mkdir -p "$SBX/.claude/agents" "$SBX/docs/phases" "$SBX/runs/$PHASE" "$SBX/reports"
  touch "$SBX/.claude/agents/developer.md"

  cat > "$SBX/docs/phases/${PHASE}.md" <<'EOF'
# Phase arc — TOKEN-4 audit-rerun-cap test spec
## GOAL
Exercise the Step 9 hardening-mode switch.
EOF

  write_stub dev-phase.sh           ""             "docs/handoffs/${PHASE}-dev.md"
  write_stub review-phase.sh        "PASS"         "reports/reviews/${PHASE}-review.md"
  write_stub qa-phase.sh            "$qa_verdict"  "reports/qa/${PHASE}-qa.md"
  write_stub phase-closure-check.sh "CLOSURE-PASS" "reports/phase-${PHASE}-closure-verdict.md"

  # Stateful auditor: verdict = next word of $AUDIT_SEQ per call (last repeats).
  cat > "$SBX/scripts/automation/phase-audit.sh" <<'EOF'
#!/usr/bin/env bash
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
echo "phase-audit.sh model=${CHAIN_MODEL_OVERRIDE:-none}" >> "${CANARY_FILE:-/dev/null}"
n=0; [[ -f "$R/.audit-calls" ]] && n="$(cat "$R/.audit-calls")"
n=$((n+1)); printf '%s' "$n" > "$R/.audit-calls"
read -r -a seq <<< "${AUDIT_SEQ:-PASS}"
idx=$((n-1)); [[ $idx -ge ${#seq[@]} ]] && idx=$(( ${#seq[@]} - 1 ))
mkdir -p "$R/docs/handoffs"
printf '# stub audit\n\n**Verdict:** %s\n' "${seq[$idx]}" > "$R/docs/handoffs/${1}-audit.md"
exit 0
EOF

  printf '# %s Execution Plan\n\nFrontend Present: no\n' "$PHASE" > "$SBX/runs/$PHASE/plan.md"
  printf '{"phase":"%s","status":"blocked","current_step":"audit_failed"}\n' "$PHASE" \
    > "$SBX/runs/$PHASE/status.json"
}

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB_DIR/claude" 2>/dev/null || true

unset GOAL_SESSION_DIR GOAL_SESSION_ID GOAL_ITER_INDEX CHAIN_AUDIT_RERUN_CAP AUDIT_SEQ || true

# run_phase <tag> <audit-seq> <cap: ""=unset>
run_phase() {
  local tag="$1" seq="$2" cap="$3" rc=0
  ( cd "$SBX" && env \
      PATH="$STUB_DIR:$PATH" \
      CANARY_FILE="$CANARY" \
      AUDIT_SEQ="$seq" \
      CHAIN_BACKEND_PORT="$TEST_BE_PORT" CHAIN_FRONTEND_PORT="$TEST_FE_PORT" \
      CHAIN_TMP_ROOT="$WORK/tmproot" CHAIN_TMP_JANITOR=false CHAIN_TMP_DISK_GUARD=false \
      CHAIN_DISABLE_TRACE=true \
      ${cap:+CHAIN_AUDIT_RERUN_CAP="$cap"} \
      bash scripts/automation/run-phase.sh "$PHASE" ) > "$WORK/run-$tag.log" 2>&1 || rc=$?
  return $rc
}

count() { local c; c="$(grep -c "^$1 " "$CANARY" 2>/dev/null || true)"; echo "${c:-0}"; }

# ══ Case A: default cap (1) — full rerun once, then fix-only ══════════════════
make_sandbox a PASS
rc=0; run_phase a "FAIL FAIL PASS" "" || rc=$?
[[ $rc -eq 0 ]] && assert "A: run completes after audit passes on attempt 3 (rc=0)" "pass" \
  || { assert "A: run completes after audit passes on attempt 3 (rc=$rc)" "fail"; sed -n '1,50p' "$WORK/run-a.log"; }
[[ "$(count phase-audit.sh)" == "3" ]] \
  && assert "A: auditor ran 3 times" "pass" || assert "A: auditor ran 3 times (got $(count phase-audit.sh))" "fail"
[[ "$(count dev-phase.sh)" == "2" && "$(count review-phase.sh)" == "2" ]] \
  && assert "A: dev+review ran in BOTH hardening passes" "pass" \
  || assert "A: dev+review ran in BOTH hardening passes (dev=$(count dev-phase.sh) review=$(count review-phase.sh))" "fail"
[[ "$(count qa-phase.sh)" == "1" ]] \
  && assert "A: full QA fired exactly ONCE (cap=1: second pass is fix-only)" "pass" \
  || assert "A: full QA fired exactly ONCE (got $(count qa-phase.sh))" "fail"
[[ "$(grep -c 'FULL-RERUN mode' "$WORK/run-a.log" || true)" == "1" ]] \
  && assert "A: full-rerun pass logged loudly, once" "pass" \
  || assert "A: full-rerun pass logged loudly, once" "fail"
[[ "$(grep -c 'FIX-ONLY mode' "$WORK/run-a.log" || true)" == "1" ]] \
  && assert "A: fix-only pass logged loudly, once" "pass" \
  || assert "A: fix-only pass logged loudly, once" "fail"
[[ "$(grep -c '^dev-phase.sh model=none' "$CANARY" || true)" == "0" ]] \
  && assert "A: strong-tier escalation env present for dev in BOTH modes" "pass" \
  || assert "A: strong-tier escalation env present for dev in BOTH modes ($(grep '^dev-phase.sh' "$CANARY" | tr '\n' ' '))" "fail"

# ══ Case B: cap=0 — uncapped, pre-TOKEN-4 behavior (documented rollback) ══════
make_sandbox b PASS
rc=0; run_phase b "FAIL FAIL PASS" "0" || rc=$?
[[ $rc -eq 0 ]] && assert "B: run completes (rc=0)" "pass" \
  || { assert "B: run completes (rc=$rc)" "fail"; sed -n '1,50p' "$WORK/run-b.log"; }
[[ "$(count qa-phase.sh)" == "2" ]] \
  && assert "B: cap=0 restores a full QA rerun on EVERY failed attempt" "pass" \
  || assert "B: cap=0 restores a full QA rerun on EVERY failed attempt (got $(count qa-phase.sh))" "fail"
[[ "$(grep -c 'FIX-ONLY mode' "$WORK/run-b.log" || true)" == "0" ]] \
  && assert "B: no fix-only pass under cap=0" "pass" \
  || assert "B: no fix-only pass under cap=0" "fail"

# ══ Case C: QA FAIL inside the full hardening pass → audit_qa_failed ══════════
make_sandbox c FAIL
rc=0; run_phase c "FAIL" "" || rc=$?
[[ $rc -ne 0 ]] && assert "C: phase hard-fails (rc=$rc)" "pass" \
  || assert "C: phase hard-fails (rc=0 unexpectedly)" "fail"
grep -q 'QA failed during audit hardening' "$WORK/run-c.log" \
  && assert "C: audit_qa_failed hard-fail message unchanged" "pass" \
  || assert "C: audit_qa_failed hard-fail message unchanged" "fail"
grep -q '"current_step": "audit_qa_failed"' "$SBX/runs/$PHASE/status.json" \
  && assert "C: checkpoint records audit_qa_failed" "pass" \
  || assert "C: checkpoint records audit_qa_failed (got: $(cat "$SBX/runs/$PHASE/status.json" 2>/dev/null | tr '\n' ' '))" "fail"

# ══ Case D: audit never passes → exhausts at MAX_AUDIT_RETRIES, QA only once ══
make_sandbox d PASS
rc=0; run_phase d "FAIL FAIL FAIL" "" || rc=$?
[[ $rc -ne 0 ]] && assert "D: phase fails after MAX_AUDIT_RETRIES (rc=$rc)" "pass" \
  || assert "D: phase fails after MAX_AUDIT_RETRIES (rc=0 unexpectedly)" "fail"
grep -q '"current_step": "audit_failed"' "$SBX/runs/$PHASE/status.json" \
  && assert "D: checkpoint records audit_failed" "pass" \
  || assert "D: checkpoint records audit_failed" "fail"
[[ "$(count phase-audit.sh)" == "3" ]] \
  && assert "D: auditor capped at 3 attempts" "pass" \
  || assert "D: auditor capped at 3 attempts (got $(count phase-audit.sh))" "fail"
[[ "$(count qa-phase.sh)" == "1" && "$(count dev-phase.sh)" == "2" ]] \
  && assert "D: two hardening passes, only the first ran full QA" "pass" \
  || assert "D: two hardening passes, only the first ran full QA (qa=$(count qa-phase.sh) dev=$(count dev-phase.sh))" "fail"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
