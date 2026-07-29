#!/usr/bin/env bash
# test-ui-combined.sh — SPEED-24 unit test: goal-mode full iterations combine
# the ui-impact-analyst + ui-test-designer into ONE dispatch inside Branch A
# of run-phase.sh's post-dev fanout; under-delivery falls back to the separate
# designer dispatch; plain phases and the knob-off hatch keep the two-dispatch
# chain byte-identical.
#
# Drives the REAL run-phase.sh (fanout path: Frontend Present: yes, dummy HTTP
# services on test ports for the shared boot) with every dispatching step
# script stubbed. The ui-impact stub records CHAIN_UI_COMBINED_DISPATCH and
# honors STUB_COMBINED_DELIVERS so all four scenarios are provable:
#   1. combined delivers      -> designer dispatch SKIPPED, run completes
#   2. combined under-delivers-> loud fallback, designer dispatched
#   3. CHAIN_UI_COMBINED=false-> two dispatches, combined env never set
#   4. plain phase            -> two dispatches even with the knob defaulted on
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BE_PORT=48351
FE_PORT=48352

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}

WORK="$(mktemp -d)"
DUMMY_PIDS=()
cleanup() {
  for p in ${DUMMY_PIDS[@]+"${DUMMY_PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done
  fuser -k "${BE_PORT}/tcp" "${FE_PORT}/tcp" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

SRV_DIR="$WORK/srv"
mkdir -p "$SRV_DIR"
start_dummies() {
  local p i
  for p in "$BE_PORT" "$FE_PORT"; do
    if ! curl -s -o /dev/null "http://localhost:${p}/"; then
      ( cd "$SRV_DIR" && exec python3 -m http.server "$p" ) >/dev/null 2>&1 &
      DUMMY_PIDS+=("$!")
    fi
  done
  for p in "$BE_PORT" "$FE_PORT"; do
    for i in $(seq 1 50); do
      curl -s -o /dev/null "http://localhost:${p}/" && break
      sleep 0.1
    done
  done
}

# write_stub <script-name> <verdict-or-""> [repo-rel artifact path...]
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
      printf 'printf "# stub %s\\n\\ncontent\\n" > "$R/%s"\n' "$name" "$rel"
      if [[ -n "$verdict" ]]; then
        printf 'printf "**Verdict:** %s\\n" >> "$R/%s"\n' "$verdict" "$rel"
      fi
    done
    echo 'exit 0'
  } > "$out"
}

make_sandbox() {  # make_sandbox <tag> <phase-name>
  local tag="$1"
  PHASE="$2"
  SBX="$WORK/proj-$tag"
  CANARY="$WORK/canary-$tag.log"
  : > "$CANARY"
  mkdir -p "$SBX"
  cp -r "$ENGINE_ROOT/scripts" "$SBX/"
  cp -r "$ENGINE_ROOT/config" "$SBX/"
  mkdir -p "$SBX/.claude/agents" "$SBX/docs/phases" "$SBX/runs/$PHASE" "$SBX/reports"
  touch "$SBX/.claude/agents/developer.md"

  write_stub generate-test-plan.sh   ""            "reports/qa/${PHASE}-test-plan.md"
  write_stub dev-phase.sh            ""            "docs/handoffs/${PHASE}-dev.md"
  write_stub review-phase.sh         "PASS"        "reports/reviews/${PHASE}-review.md"
  write_stub ui-test-design-phase.sh ""            "reports/phase-${PHASE}-ui-test-plan.md" "reports/phase-${PHASE}-what-to-click.md"
  write_stub qa-phase.sh             "PASS"        "reports/qa/${PHASE}-qa.md"
  write_stub demo-phase.sh           ""
  write_stub ux-regression-phase.sh  "UX-REGRESSION-PASS" "reports/phase-${PHASE}-ux-regression.md"
  write_stub phase-audit.sh          "PASS"        "docs/handoffs/${PHASE}-audit.md"
  write_stub phase-closure-check.sh  "CLOSURE-PASS" "reports/phase-${PHASE}-closure-verdict.md"

  # browser-qa needs its own verdict line format.
  cat > "$SBX/scripts/automation/browser-qa-phase.sh" <<EOF
#!/usr/bin/env bash
R="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/../.." && pwd)"
echo "browser-qa-phase.sh" >> "$CANARY"
mkdir -p "\$R/reports"
printf '**Browser QA Verdict:** PASS\n\n| UT-1 | n | ui | P1 | e | a | PASS | x.png |\n' > "\$R/reports/phase-${PHASE}-ui-test-results.md"
exit 0
EOF

  # ui-impact stub: records the combined env, delivers the two impact reports
  # always and the designer artifacts only when combined AND allowed to.
  cat > "$SBX/scripts/automation/ui-impact-phase.sh" <<EOF
#!/usr/bin/env bash
R="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/../.." && pwd)"
echo "ui-impact-phase.sh combined=\${CHAIN_UI_COMBINED_DISPATCH:-0}" >> "$CANARY"
mkdir -p "\$R/reports"
printf '# stub user-visible\n\ncontent\n' > "\$R/reports/phase-${PHASE}-user-visible-changes.md"
printf '# stub surface map\n\ncontent\n' > "\$R/reports/phase-${PHASE}-ui-surface-map.md"
if [[ "\${CHAIN_UI_COMBINED_DISPATCH:-}" == "1" && "\${STUB_COMBINED_DELIVERS:-yes}" == "yes" ]]; then
  printf '# stub combined ui test plan\n\n- TC-1: x\n' > "\$R/reports/phase-${PHASE}-ui-test-plan.md"
  printf '# stub combined what to click\n\n1. click\n' > "\$R/reports/phase-${PHASE}-what-to-click.md"
fi
exit 0
EOF

  printf '# %s Execution Plan\n\nFrontend Present: yes\n' "$PHASE" > "$SBX/runs/$PHASE/plan.md"
  printf '{"phase":"%s","status":"in_progress","current_step":"planned"}\n' "$PHASE" \
    > "$SBX/runs/$PHASE/status.json"
  cat > "$SBX/docs/phases/${PHASE}.md" <<'EOF'
# UI-combined wiring test spec
## GOAL
Exercise Branch-A's combined UI dispatch.
## IN SCOPE
- frontend widget (wiring test)
## Test Scenarios
- TC-1: a
- TC-2: b
- TC-3: c
EOF
}

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/claude"
chmod +x "$STUB_DIR/claude"

unset GOAL_SESSION_DIR GOAL_SESSION_ID GOAL_ITER_INDEX CHAIN_UI_COMBINED STUB_COMBINED_DELIVERS || true

run_phase() {  # run_phase <tag> [EXTRA_ENV=val ...]
  local tag="$1"; shift
  local rc=0
  start_dummies
  ( cd "$SBX" && env \
      PATH="$STUB_DIR:$PATH" \
      CANARY_FILE="$CANARY" \
      CHAIN_BACKEND_PORT="$BE_PORT" CHAIN_FRONTEND_PORT="$FE_PORT" \
      CHAIN_TMP_ROOT="$WORK/tmproot" CHAIN_TMP_JANITOR=false CHAIN_TMP_DISK_GUARD=false \
      CHAIN_DISABLE_TRACE=true CHAIN_KILL_GRACE_SECONDS=1 \
      "$@" \
      bash scripts/automation/run-phase.sh "$PHASE" ) > "$WORK/run-$tag.log" 2>&1 || rc=$?
  return $rc
}

echo "=== test-ui-combined.sh ==="

# ══ Case 1: goal iteration + combined delivers → designer dispatch skipped ════
make_sandbox c1 "goal-uic-iter-1"
rc=0; run_phase c1 || rc=$?
[[ $rc -eq 0 ]] && assert "1: goal-iter run completes (rc=0)" pass \
  || { assert "1: goal-iter run completes (rc=$rc)" fail; tail -30 "$WORK/run-c1.log"; }
grep -q 'ui-impact-phase.sh combined=1' "$WORK/canary-c1.log" \
  && assert "1: ui-impact dispatched in combined mode" pass \
  || assert "1: ui-impact dispatched in combined mode" fail
grep -q '^ui-test-design-phase.sh' "$WORK/canary-c1.log" \
  && assert "1: separate designer dispatch SKIPPED" fail \
  || assert "1: separate designer dispatch SKIPPED" pass
grep -q 'combined dispatch delivered the UI test plan' "$WORK/run-c1.log" \
  && assert "1: skip is logged loudly" pass \
  || assert "1: skip is logged loudly" fail

# ══ Case 2: combined under-delivers → loud fallback to the designer ═══════════
make_sandbox c2 "goal-uic-iter-1"
rc=0; run_phase c2 STUB_COMBINED_DELIVERS=no || rc=$?
[[ $rc -eq 0 ]] && assert "2: goal-iter run completes (rc=0)" pass \
  || { assert "2: goal-iter run completes (rc=$rc)" fail; tail -30 "$WORK/run-c2.log"; }
grep -q 'ui-impact-phase.sh combined=1' "$WORK/canary-c2.log" \
  && assert "2: ui-impact dispatched in combined mode" pass \
  || assert "2: ui-impact dispatched in combined mode" fail
grep -q '^ui-test-design-phase.sh' "$WORK/canary-c2.log" \
  && assert "2: designer dispatched as the fallback" pass \
  || assert "2: designer dispatched as the fallback" fail
grep -q 'UNDER-DELIVERED' "$WORK/run-c2.log" \
  && assert "2: fallback is logged loudly" pass \
  || assert "2: fallback is logged loudly" fail

# ══ Case 3: knob off → two dispatches, combined env never set ═════════════════
make_sandbox c3 "goal-uic-iter-1"
rc=0; run_phase c3 CHAIN_UI_COMBINED=false || rc=$?
[[ $rc -eq 0 ]] && assert "3: goal-iter run completes (rc=0)" pass \
  || { assert "3: goal-iter run completes (rc=$rc)" fail; tail -30 "$WORK/run-c3.log"; }
grep -q 'ui-impact-phase.sh combined=0' "$WORK/canary-c3.log" \
  && assert "3: knob off — ui-impact runs WITHOUT the combined env" pass \
  || assert "3: knob off — ui-impact runs WITHOUT the combined env" fail
grep -q '^ui-test-design-phase.sh' "$WORK/canary-c3.log" \
  && assert "3: knob off — separate designer dispatch kept" pass \
  || assert "3: knob off — separate designer dispatch kept" fail

# ══ Case 4: plain phase → two dispatches even with the knob defaulted on ══════
make_sandbox c4 "phase-uc"
rc=0; run_phase c4 || rc=$?
[[ $rc -eq 0 ]] && assert "4: plain phase run completes (rc=0)" pass \
  || { assert "4: plain phase run completes (rc=$rc)" fail; tail -30 "$WORK/run-c4.log"; }
grep -q 'ui-impact-phase.sh combined=0' "$WORK/canary-c4.log" \
  && assert "4: plain phase — no combined env" pass \
  || assert "4: plain phase — no combined env" fail
grep -q '^ui-test-design-phase.sh' "$WORK/canary-c4.log" \
  && assert "4: plain phase — separate designer dispatch kept" pass \
  || assert "4: plain phase — separate designer dispatch kept" fail

# ══ Wiring greps (real scripts + neutral agent source) ════════════════════════
grep -q 'CHAIN_UI_COMBINED_DISPATCH' "$ENGINE_ROOT/scripts/automation/ui-impact-phase.sh" \
  && assert "wiring: ui-impact-phase.sh has the combined branch" pass \
  || assert "wiring: ui-impact-phase.sh has the combined branch" fail
grep -q 'CHAIN_UI_COMBINED:-true' "$ENGINE_ROOT/scripts/automation/run-phase.sh" \
  && assert "wiring: Branch-A gate defaults on for goal iterations" pass \
  || assert "wiring: Branch-A gate defaults on for goal iterations" fail
grep -q '## Combined mode' "$ENGINE_ROOT/agents/ui-impact-analyst/body.md" \
  && assert "wiring: analyst body carries the Combined mode section" pass \
  || assert "wiring: analyst body carries the Combined mode section" fail
grep -q 'manual-ui-test-plan-generator' "$ENGINE_ROOT/agents/ui-impact-analyst/body.md" \
  && grep -q 'what-to-click-writer' "$ENGINE_ROOT/agents/ui-impact-analyst/body.md" \
  && assert "wiring: combined mode names the designer's exact skills" pass \
  || assert "wiring: combined mode names the designer's exact skills" fail

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
