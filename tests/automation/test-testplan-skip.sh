#!/usr/bin/env bash
# test-testplan-skip.sh — TOKEN-3 unit test: run-phase.sh Step 2 skips the
# test-plan generator dispatch when the phase spec already lists its own tests.
#
# Drives the REAL run-phase.sh in a sandbox repo (engine scripts embedded,
# consumer-repo layout) with the expensive step scripts replaced by stubs that
# record each dispatch to a canary and write the artifact/verdict the pipeline
# checks for. run-phase.sh's own control flow — checkpoint resume, the Step-2
# heuristic under test, verdict gates — runs for real. Resumes from checkpoint
# `planned` (backend-only plan) so every case exercises Step 2 and then the
# whole remaining pipeline to completion. No API calls; a few seconds per case.
#
# Heuristic under test (docs/improvement-roadmap.md TOKEN-3):
#   spec has a `## Test`-titled section OR >=3 `TC-` lines OR a still-fresh
#   generated plan (newer than the spec, >=3 TC- lines)
#   -> skip generation, log the matched arm loudly. Knob:
#   CHAIN_SKIP_TESTPLAN_IF_PRESENT, ships default TRUE since 2026-07-29 (the
#   desk session was the pre-registered "one observed clean phase").
#
#   1. knob on + `## Test Scenarios` section  -> skip, reason names the section
#   2. knob on + >=3 `TC-` lines              -> skip, reason names the count
#   3. knob on + spec without tests           -> generates exactly as today
#   4. knob unset (default TRUE) + tests      -> skips (the TOKEN-3 flip);
#      knob explicitly false + tests          -> generates (the rollback)
#   5. knob on + template's boilerplate `## TESTING REQUIREMENTS` heading only
#      -> generates (templates/phase-spec.md: "The test-plan-generator agent
#      will create the test plan" — TESTING REQUIREMENTS is not a test list)
#   6. SPEED-15 trim rung 3a: over the wall-clock budget (trim mode) with the
#      TOKEN-3 knob OFF — a spec with TC- lines skips the generator with the
#      rung-3a reason; a spec with NO test source still generates (the budget
#      never trims the only test source).
#   7. Fresh-plan second arm: no spec tests but an existing plan newer than
#      the spec with >=3 TC- lines -> skip; a STALE plan (older than the
#      spec) -> generates.
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

PHASE="phase-ts"
# Keep run-phase.sh's port logic pinned and its fuser cleanup away from real ports.
TEST_BE_PORT=48311
TEST_FE_PORT=48312

# Generate a stub step script into the sandbox: records its dispatch (plus the
# model-escalation env) to the canary, writes the artifact(s) + verdict line the
# pipeline's gates check, exits 0.
#   write_stub <script-name> <verdict-or-""> [repo-rel artifact path...]
write_stub() {
  local name="$1" verdict="$2"; shift 2
  local out="$SBX/scripts/automation/$name"
  {
    echo '#!/usr/bin/env bash'
    echo 'R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"'
    printf 'echo "%s model=%s" >> "%s"\n' "$name" '${CHAIN_MODEL_OVERRIDE:-none}' "$CANARY"
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
# a backend-only plan so the run resumes at Step 2.
make_sandbox() {
  local tag="$1"
  SBX="$WORK/proj-$tag"
  CANARY="$WORK/canary-$tag.log"
  : > "$CANARY"
  mkdir -p "$SBX"
  cp -r "$ENGINE_ROOT/scripts" "$SBX/"
  cp -r "$ENGINE_ROOT/config" "$SBX/"
  mkdir -p "$SBX/.claude/agents" "$SBX/docs/phases" "$SBX/runs/$PHASE" "$SBX/reports"
  touch "$SBX/.claude/agents/developer.md"   # ensure_cli_assets_synced marker

  write_stub generate-test-plan.sh  ""            "reports/qa/${PHASE}-test-plan.md"
  write_stub dev-phase.sh           ""            "docs/handoffs/${PHASE}-dev.md"
  write_stub review-phase.sh        "PASS"        "reports/reviews/${PHASE}-review.md"
  write_stub ui-impact-phase.sh     ""            "reports/phase-${PHASE}-user-visible-changes.md" "reports/phase-${PHASE}-ui-surface-map.md"
  write_stub qa-phase.sh            "PASS"        "reports/qa/${PHASE}-qa.md"
  write_stub phase-audit.sh         "PASS"        "docs/handoffs/${PHASE}-audit.md"
  write_stub phase-closure-check.sh "CLOSURE-PASS" "reports/phase-${PHASE}-closure-verdict.md"

  # Resume point: Step 1 done, backend-only plan on disk.
  printf '# %s Execution Plan\n\nFrontend Present: no\n' "$PHASE" > "$SBX/runs/$PHASE/plan.md"
  printf '{"phase":"%s","status":"in_progress","current_step":"planned"}\n' "$PHASE" \
    > "$SBX/runs/$PHASE/status.json"
}

# Stub claude: satisfies require_cli and absorbs the iteration-summarizer
# dispatch (exit 0, writes nothing — that path is non-blocking by design).
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<EOF
#!/usr/bin/env bash
echo "claude agent=\${CHAIN_CURRENT_AGENT:-unknown}" >> "\${CANARY_FILE:-/dev/null}"
exit 0
EOF
chmod +x "$STUB_DIR/claude"

unset GOAL_SESSION_DIR GOAL_SESSION_ID GOAL_ITER_INDEX CHAIN_SKIP_TESTPLAN_IF_PRESENT || true

# run_phase <tag> <knob: true|false|unset> [EXTRA_ENV=val ...]
run_phase() {
  local tag="$1" knob="$2"; shift 2
  local rc=0
  ( cd "$SBX" && env \
      PATH="$STUB_DIR:$PATH" \
      CANARY_FILE="$CANARY" \
      CHAIN_BACKEND_PORT="$TEST_BE_PORT" CHAIN_FRONTEND_PORT="$TEST_FE_PORT" \
      CHAIN_TMP_ROOT="$WORK/tmproot" CHAIN_TMP_JANITOR=false CHAIN_TMP_DISK_GUARD=false \
      CHAIN_DISABLE_TRACE=true \
      ${knob:+CHAIN_SKIP_TESTPLAN_IF_PRESENT="$knob"} \
      "$@" \
      bash scripts/automation/run-phase.sh "$PHASE" ) > "$WORK/run-$tag.log" 2>&1 || rc=$?
  return $rc
}

spec_common_head() {
  cat > "$SBX/docs/phases/${PHASE}.md" <<'EOF'
# Phase ts — TOKEN-3 heuristic test spec
## GOAL
Exercise Step 2's skip heuristic.
## IN SCOPE
- nothing (control-flow test)
EOF
}

# ══ Case 1: knob on + `## Test Scenarios` section → skip with logged reason ══
make_sandbox c1
spec_common_head
cat >> "$SBX/docs/phases/${PHASE}.md" <<'EOF'
## Test Scenarios
- open the page and see the widget
- reload and see the widget persist
EOF
rc=0; run_phase c1 true || rc=$?
[[ $rc -eq 0 ]] && assert "1: phase run completes (rc=0)" "pass" \
  || { assert "1: phase run completes (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/run-c1.log"; }
grep -q '^generate-test-plan.sh ' "$WORK/canary-c1.log" \
  && assert "1: NO generator dispatch when spec has a ## Test section" "fail" \
  || assert "1: NO generator dispatch when spec has a ## Test section" "pass"
grep -q 'Test plan: SKIPPED' "$WORK/run-c1.log" \
  && assert "1: skip is logged loudly" "pass" \
  || assert "1: skip is logged loudly" "fail"
grep -qi "## Test' section" "$WORK/run-c1.log" \
  && assert "1: logged reason names the matched heading heuristic" "pass" \
  || assert "1: logged reason names the matched heading heuristic" "fail"
[[ ! -f "$SBX/reports/qa/${PHASE}-test-plan.md" ]] \
  && assert "1: no test-plan artifact written" "pass" \
  || assert "1: no test-plan artifact written" "fail"
grep -q 'ALL CHECKS PASSED' "$WORK/run-c1.log" \
  && assert "1: pipeline still runs to completion after the skip" "pass" \
  || assert "1: pipeline still runs to completion after the skip" "fail"

# ══ Case 2: knob on + >=3 TC- lines (no test heading) → skip, count in reason ═
make_sandbox c2
spec_common_head
cat >> "$SBX/docs/phases/${PHASE}.md" <<'EOF'
## DEFINITION OF DONE
- TC-1: given a fresh DB, when POST /items, then 201 with the item body
- TC-2: given an item, when GET /items/1, then 200 with the same body
- TC-3: given bad input, when POST /items, then 422 with an error list
EOF
rc=0; run_phase c2 true || rc=$?
[[ $rc -eq 0 ]] && assert "2: phase run completes (rc=0)" "pass" \
  || { assert "2: phase run completes (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/run-c2.log"; }
grep -q '^generate-test-plan.sh ' "$WORK/canary-c2.log" \
  && assert "2: NO generator dispatch when spec has >=3 TC- lines" "fail" \
  || assert "2: NO generator dispatch when spec has >=3 TC- lines" "pass"
grep -q 'Test plan: SKIPPED' "$WORK/run-c2.log" \
  && grep -qE "3 'TC-' " "$WORK/run-c2.log" \
  && assert "2: logged reason carries the TC- line count (3)" "pass" \
  || assert "2: logged reason carries the TC- line count (3)" "fail"

# ══ Case 3: knob on + spec without tests → generates exactly as today ═════════
make_sandbox c3
spec_common_head
rc=0; run_phase c3 true || rc=$?
[[ $rc -eq 0 ]] && assert "3: phase run completes (rc=0)" "pass" \
  || { assert "3: phase run completes (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/run-c3.log"; }
grep -q '^generate-test-plan.sh ' "$WORK/canary-c3.log" \
  && assert "3: generator dispatched for a spec without tests" "pass" \
  || assert "3: generator dispatched for a spec without tests" "fail"
[[ -f "$SBX/reports/qa/${PHASE}-test-plan.md" ]] \
  && assert "3: test-plan artifact written" "pass" \
  || assert "3: test-plan artifact written" "fail"
grep -q 'Test plan: SKIPPED' "$WORK/run-c3.log" \
  && assert "3: no skip logged" "fail" \
  || assert "3: no skip logged" "pass"

# ══ Case 4: knob UNSET (ships default TRUE) + spec WITH tests → skips ═════════
make_sandbox c4
spec_common_head
cat >> "$SBX/docs/phases/${PHASE}.md" <<'EOF'
## Test Scenarios
- TC-1: a
- TC-2: b
- TC-3: c
EOF
rc=0; run_phase c4 "" || rc=$?
[[ $rc -eq 0 ]] && assert "4: phase run completes (rc=0)" "pass" \
  || { assert "4: phase run completes (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/run-c4.log"; }
grep -q '^generate-test-plan.sh ' "$WORK/canary-c4.log" \
  && assert "4: knob defaults ON (TOKEN-3 flip) — no generator dispatch" "fail" \
  || assert "4: knob defaults ON (TOKEN-3 flip) — no generator dispatch" "pass"
grep -q 'Test plan: SKIPPED' "$WORK/run-c4.log" \
  && assert "4: default-on skip logged loudly" "pass" \
  || assert "4: default-on skip logged loudly" "fail"

# ══ Case 4b: knob explicitly FALSE + spec WITH tests → generates (rollback) ═══
make_sandbox c4b
spec_common_head
cat >> "$SBX/docs/phases/${PHASE}.md" <<'EOF'
## Test Scenarios
- TC-1: a
- TC-2: b
- TC-3: c
EOF
rc=0; run_phase c4b false || rc=$?
[[ $rc -eq 0 ]] && assert "4b: phase run completes (rc=0)" "pass" \
  || { assert "4b: phase run completes (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/run-c4b.log"; }
grep -q '^generate-test-plan.sh ' "$WORK/canary-c4b.log" \
  && assert "4b: knob=false rollback — generator dispatched as before" "pass" \
  || assert "4b: knob=false rollback — generator dispatched as before" "fail"

# ══ Case 5: knob on + only the template's `## TESTING REQUIREMENTS` heading ═══
# templates/phase-spec.md ships this heading in EVERY spec and its comment says
# the generator is still expected to run — the heuristic must NOT match it.
make_sandbox c5
spec_common_head
cat >> "$SBX/docs/phases/${PHASE}.md" <<'EOF'
## TESTING REQUIREMENTS
- API: what endpoints must be verified
- Error cases: what invalid inputs must be rejected
EOF
rc=0; run_phase c5 true || rc=$?
[[ $rc -eq 0 ]] && assert "5: phase run completes (rc=0)" "pass" \
  || { assert "5: phase run completes (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/run-c5.log"; }
grep -q '^generate-test-plan.sh ' "$WORK/canary-c5.log" \
  && assert "5: boilerplate TESTING REQUIREMENTS heading does NOT suppress the generator" "pass" \
  || assert "5: boilerplate TESTING REQUIREMENTS heading does NOT suppress the generator" "fail"

# ══ Case 7: fresh-plan arm — no spec tests, plan newer than spec → skip ═══════
make_sandbox c7
spec_common_head
mkdir -p "$SBX/reports/qa"
sleep 0.1   # ensure the plan mtime is strictly newer than the spec's
cat > "$SBX/reports/qa/${PHASE}-test-plan.md" <<'EOF'
# Test plan (pre-existing)
- TC-1: given a, when b, then c
- TC-2: given d, when e, then f
- TC-3: given g, when h, then i
EOF
rc=0; run_phase c7 "" || rc=$?
[[ $rc -eq 0 ]] && assert "7: phase run completes (rc=0)" "pass" \
  || { assert "7: phase run completes (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/run-c7.log"; }
grep -q '^generate-test-plan.sh ' "$WORK/canary-c7.log" \
  && assert "7: fresh existing plan — no generator dispatch" "fail" \
  || assert "7: fresh existing plan — no generator dispatch" "pass"
grep -q 'existing test plan is fresh' "$WORK/run-c7.log" \
  && assert "7: logged reason names the fresh-plan arm" "pass" \
  || assert "7: logged reason names the fresh-plan arm" "fail"

# ══ Case 7b: STALE plan (older than the spec) → generates ═════════════════════
make_sandbox c7b
mkdir -p "$SBX/reports/qa"
cat > "$SBX/reports/qa/${PHASE}-test-plan.md" <<'EOF'
# Test plan (stale)
- TC-1: given a, when b, then c
- TC-2: given d, when e, then f
- TC-3: given g, when h, then i
EOF
sleep 0.1
spec_common_head   # spec written AFTER the plan → plan is stale
rc=0; run_phase c7b "" || rc=$?
[[ $rc -eq 0 ]] && assert "7b: phase run completes (rc=0)" "pass" \
  || { assert "7b: phase run completes (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/run-c7b.log"; }
grep -q '^generate-test-plan.sh ' "$WORK/canary-c7b.log" \
  && assert "7b: stale plan — generator dispatched (freshness arm refuses it)" "pass" \
  || assert "7b: stale plan — generator dispatched (freshness arm refuses it)" "fail"

# ══ Case 6: SPEED-15 rung 3a — over budget, knob OFF, spec with TC- lines ═════
make_sandbox c6
spec_common_head
cat >> "$SBX/docs/phases/${PHASE}.md" <<'EOF'
## DEFINITION OF DONE
- TC-1: given a fresh DB, when POST /items, then 201 with the item body
- TC-2: given an item, when GET /items/1, then 200 with the same body
- TC-3: given bad input, when POST /items, then 422 with an error list
EOF
rc=0; run_phase c6 false \
  CHAIN_ITER_START_EPOCH="$(( $(date +%s) - 99999 ))" \
  CHAIN_ITER_TIME_BUDGET_SECONDS=60 CHAIN_ITER_BUDGET_MODE=trim || rc=$?
[[ $rc -eq 0 ]] && assert "6: phase run completes (rc=0)" "pass" \
  || { assert "6: phase run completes (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/run-c6.log"; }
grep -q '^generate-test-plan.sh ' "$WORK/canary-c6.log" \
  && assert "6: NO generator dispatch when over budget with TC- lines (knob off)" "fail" \
  || assert "6: NO generator dispatch when over budget with TC- lines (knob off)" "pass"
grep -q 'iter-budget trim rung 3a' "$WORK/run-c6.log" \
  && assert "6: skip logged with the rung-3a reason" "pass" \
  || assert "6: skip logged with the rung-3a reason" "fail"

# ══ Case 6b: over budget but NO test source in the spec → still generates ═════
make_sandbox c6b
spec_common_head
rc=0; run_phase c6b false \
  CHAIN_ITER_START_EPOCH="$(( $(date +%s) - 99999 ))" \
  CHAIN_ITER_TIME_BUDGET_SECONDS=60 CHAIN_ITER_BUDGET_MODE=trim || rc=$?
[[ $rc -eq 0 ]] && assert "6b: phase run completes (rc=0)" "pass" \
  || { assert "6b: phase run completes (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/run-c6b.log"; }
grep -q '^generate-test-plan.sh ' "$WORK/canary-c6b.log" \
  && assert "6b: generator STILL dispatched — budget never trims the only test source" "pass" \
  || assert "6b: generator STILL dispatched — budget never trims the only test source" "fail"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
