#!/usr/bin/env bash
# test-browser-evidence-lifecycle.sh — the browser evidence coverage gate's
# FAILURE must propagate to a resumable top-level halt: a leaf-level fail-closed
# (2d723ae) is not enough while the phase runner warns-and-continues past a
# generic non-zero and the goal engine evaluates whatever artifacts exist.
#
# Reserved condition: BROWSER_EVIDENCE_GATE_UNAVAILABLE_EXIT_CODE (79) — "the
# deterministic fresh-evidence coverage gate could not be established". Not a
# product FAIL, not browser infra, not agent quality, not quota, not STALLED.
#
# Sections (offline; stub `claude`, stub step scripts, a merger wrapper that
# forces `finalize`/merge failures via STUB_FINALIZE_RC / STUB_MERGE_RC, dummy
# HTTP services; the REAL browser-qa-phase.sh, run-phase.sh, goal-iter-lean.sh
# and run-goal.sh run):
#   A. the reserved rc is defined once, unused by any other contract
#   P. FULL depth through the REAL run-phase.sh
#      P1 sequential Step 6 (resume from ui_test_designed): gate failure →
#         run-phase exits 79, browser_qa_complete NOT recorded, no downstream
#         step dispatched               (RED on 2d723ae: warn, continue, complete)
#      P2 post-dev parallel fanout (from review_passed): Branch A 79 → fanout
#         79 → run-phase 79, NO post_dev_parallel_complete, NO SKIP_BROWSER_QA
#         promotion from the SKIPPED stub (RED: soft rc, stub promoted, completed)
#      P3/P4 healthy sequential / parallel: unchanged (rc 0, one dispatch)
#      P5 quarantine belt: the raw PASS cannot be moved aside → it stays at the
#         results path, yet run-phase still exits 79 and dispatches nothing
#   E. lean + full through the REAL run-goal.sh
#      E1 lean gate failure → executor 79 → GATE_BLOCKED (reason
#         GATE_BLOCKED_BROWSER_EVIDENCE), no coherence, no evaluator,
#         current_iter unchanged             (RED: evaluator dispatched)
#      E2 quarantine belt: raw PASS remains, evaluator still never runs
#      E3 resume after the fault is removed: the SAME iteration re-runs, browser
#         evidence is re-collected, the evaluator is reached — no approval step
#      E4 healthy lean: unchanged (evaluator reached, one browser dispatch)
#      E5 FULL path: run-phase.sh exiting 79 → the identical GATE_BLOCKED halt
#   W. wiring: one constant, guard order, engine halt placed before coherence.
#
# shellcheck disable=SC2015,SC2016,SC2034,SC2329
# (SC2015: assert's pass arm always returns 0; SC2016: the wiring greps match
# literal `$VAR` text in the scripts on purpose; SC2034/SC2329: harness vars and
# trap-invoked cleanup.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RC79="${BROWSER_EVIDENCE_GATE_UNAVAILABLE_EXIT_CODE:-79}"

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}

WORK="$(mktemp -d)"
DUMMY_PIDS=()
BE_PORT=48381
FE_PORT=48382
cleanup() {
  for p in ${DUMMY_PIDS[@]+"${DUMMY_PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done
  fuser -k "${BE_PORT}/tcp" "${FE_PORT}/tcp" 2>/dev/null || true
  pkill -KILL -f "$WORK/" 2>/dev/null || true
  if [[ -n "${KEEP_WORK:-}" ]]; then echo "KEEP_WORK set — sandbox kept at $WORK"; return 0; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

SRV_DIR="$WORK/srv"; mkdir -p "$SRV_DIR"
start_dummies() {
  local p i
  for p in "$BE_PORT" "$FE_PORT"; do
    if ! curl -s -o /dev/null "http://localhost:${p}/"; then
      ( cd "$SRV_DIR" && exec python3 -m http.server "$p" ) >/dev/null 2>&1 &
      DUMMY_PIDS+=("$!")
    fi
  done
  for p in "$BE_PORT" "$FE_PORT"; do
    for i in $(seq 1 50); do curl -s -o /dev/null "http://localhost:${p}/" && break; sleep 0.1; done
  done
}

# Merger wrapper: forces the deterministic gate to fail on demand; otherwise
# runs the REAL module unchanged.
install_merge_stub() {  # <sandbox>
  cat > "$1/scripts/automation/lib/merge_ui_test_results.py" <<PYEOF
#!/usr/bin/env python3
import os, runpy, sys
REAL = "$ENGINE_ROOT/scripts/automation/lib/merge_ui_test_results.py"
sub = sys.argv[1] if len(sys.argv) > 1 else ""
forced = ""
if sub == "finalize":
    forced = os.environ.get("STUB_FINALIZE_RC", "")
elif sub not in ("classify", "void", "self-test", "--self-test"):
    forced = os.environ.get("STUB_MERGE_RC", "")
if forced:
    sys.stderr.write(f"[stub merger] forced failure rc={forced} for '{sub or 'merge'}' (simulated: cannot write results)\\n")
    sys.exit(int(forced))
sys.argv[0] = REAL
runpy.run_path(REAL, run_name="__main__")
PYEOF
}

# The browser agent stub (both harnesses): writes the template header, one
# generic UT-01 PASS row, a PASS row per journey the prompt asked for (lean
# "test EXACTLY" line or the full-depth ALSO line) and, when STUB_BQA_TARGET_ROWS
# names targets, one UT-J-NN attribution row each. Other roles are handled by the
# engine stub below.
bqa_rows() {  # <prompt> → results markdown on stdout
  local prompt="$1" line journeys j
  line="$(printf '%s\n' "$prompt" | sed -n 's/^GOAL-MODE LEAN MODE — test EXACTLY these journeys this run: //p' | head -n1)"
  local also; also="$(printf '%s\n' "$prompt" | sed -n 's/^- ALSO execute these regression journeys this run: //p' | head -n1)"; also="${also%%. For each*}"
  journeys="$(printf '%s\n%s\n' "$line" "$also" | grep -oE 'J-[0-9]+' | sort -u | tr '\n' ' ' || true)"
  printf '**Browser QA Verdict:** PASS\n\n'
  printf '| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n'
  printf '|---|---|---|---|---|---|---|---|\n'
  printf '| UT-01 | generic UI test | smoke | P1 | loads | ok | PASS | none |\n'
  for j in $journeys; do printf '| UT-%s | journey %s | journey | P1 | acceptance | verified | PASS | reports/qa/x.png |\n' "$j" "$j"; done
  for j in ${STUB_BQA_TARGET_ROWS:-}; do
    printf '%s\n' "$journeys" | grep -qw "$j" && continue
    printf '| UT-%s | target %s | journey | P1 | acceptance | verified | PASS | reports/qa/x.png |\n' "$j" "$j"
  done
}
export -f bqa_rows

STUB_DIR="$WORK/bin"; mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "stub 0.0"; exit 0; }
agent="${CHAIN_CURRENT_AGENT:-browser-qa-agent}"
prompt="$*"
echo "$agent" >> "$CANARY"
case "$agent" in
  goal-decomposer)
    iter="$(printf '%s\n' "$prompt" | sed -n 's/^Iter name: //p' | head -1)"
    [[ -n "$iter" ]] || exit 64
    {
      echo "## Goal Mode Metadata"; echo
      echo "- **Session ID:** s"; echo "- **Iteration:** 0"; echo "- **Mode:** baseline"
      if [[ "${STUB_SPEC_DEPTH:-lean}" == "full" ]]; then echo "- **Depth:** full"; echo "- **Full trigger:** 1 - new journey"; else echo "- **Depth:** lean"; fi
      echo "- **Target journeys:** J-04, J-13"
      echo "- **Work kind:** verify-only"
      echo "- **Required-still-passing journeys:** J-01"
      echo; echo "## IN SCOPE"; echo "### Backend"; echo "- none"; echo "### Frontend"; echo "- N/A"
      echo; echo "## OUT OF SCOPE"; echo "- x"
      echo; echo "## DEFINITION OF DONE"; echo "- [ ] done"
      echo; echo "## TESTING REQUIREMENTS"; echo "- TC-1: given x, when y, then z"
    } > "docs/phases/${iter}.md"
    exit 0 ;;
  developer)
    out="$(printf '%s\n' "$prompt" | sed -n 's/^- Write dev handoff to: //p' | head -n1)"; [[ -n "$out" ]] || exit 64
    printf 'handoff: verify-only (stub).\n' > "$out"; exit 0 ;;
  reviewer)
    out="$(printf '%s\n' "$prompt" | sed -n 's/^Write your review report to: //p' | head -n1)"; [[ -n "$out" ]] || exit 64
    printf '**Verdict:** PASS\n\nStub review.\n' > "$out"; exit 0 ;;
  browser-qa-agent)
    out="$(printf '%s\n' "$prompt" | sed -n 's/^Write your results to: //p' | head -n1)"; [[ -n "$out" ]] || exit 64
    mkdir -p "$(dirname "$out")"
    bqa_rows "$prompt" > "$out"; exit 0 ;;
esac
exit 70
EOF
chmod +x "$STUB_DIR/claude"

echo "=== test-browser-evidence-lifecycle.sh ==="

# ══ A. the reserved rc ════════════════════════════════════════════════════════
COMMON="$ENGINE_ROOT/scripts/automation/lib/common.sh"
grep -qE '^: "\$\{BROWSER_EVIDENCE_GATE_UNAVAILABLE_EXIT_CODE:=79\}"' "$COMMON" && grep -q '^export BROWSER_EVIDENCE_GATE_UNAVAILABLE_EXIT_CODE' "$COMMON" \
  && assert "A1: BROWSER_EVIDENCE_GATE_UNAVAILABLE_EXIT_CODE=79 is defined once in lib/common.sh and exported" pass \
  || assert "A1: BROWSER_EVIDENCE_GATE_UNAVAILABLE_EXIT_CODE=79 is defined once in lib/common.sh and exported" fail
_others="$(grep -rhoE '[A-Z_]+_EXIT_CODE:?[-=][0-9]+' "$ENGINE_ROOT/scripts/automation/" | grep -v BROWSER_EVIDENCE | grep -oE '[0-9]+$' | sort -u | tr '\n' ' ')"
_fixed="130 137 143 86"   # signal exits + the engine-lock refusal (literal in the scripts)
[[ " $_others " != *" 79 "* && " $_fixed " != *" 79 "* ]] \
  && assert "A2: 79 collides with no other reserved code (named: $_others; fixed: $_fixed)" pass \
  || assert "A2: 79 collides with another reserved code (named: $_others; fixed: $_fixed)" fail

# ══ P. FULL depth through the REAL run-phase.sh ═══════════════════════════════
write_stub() {  # <sandbox> <script-name> <verdict-or-""> [repo-rel artifact path...]
  local sbx="$1" name="$2" verdict="$3"; shift 3
  local out="$sbx/scripts/automation/$name"
  {
    echo '#!/usr/bin/env bash'
    echo 'R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"'
    printf 'echo "%s" >> "$CANARY"\n' "$name"
    local rel
    for rel in "$@"; do
      printf 'mkdir -p "$R/%s"\n' "$(dirname "$rel")"
      printf 'printf "# stub %s\\n\\ncontent\\n" > "$R/%s"\n' "$name" "$rel"
      [[ -n "$verdict" ]] && printf 'printf "**Verdict:** %s\\n" >> "$R/%s"\n' "$verdict" "$rel"
    done
    echo 'exit 0'
  } > "$out"
}
make_phase_sandbox() {  # <tag> <current_step>
  local tag="$1" step="$2"
  PHASE="goal-lc-iter-3"
  SBX="$WORK/phase-$tag"; CANARY="$WORK/canary-$tag.log"; : > "$CANARY"; export CANARY
  mkdir -p "$SBX"
  cp -r "$ENGINE_ROOT/scripts" "$SBX/"; cp -r "$ENGINE_ROOT/config" "$SBX/"
  mkdir -p "$SBX/.claude/agents" "$SBX/docs/phases" "$SBX/runs/$PHASE" "$SBX/reports" "$SBX/src"
  touch "$SBX/.claude/agents/developer.md"
  git init -q "$SBX"; echo "print('v1')" > "$SBX/src/app.py"
  cat > "$SBX/docs/goal.md" <<'EOF'
# Goal
## Must-have user journeys
- J-01: open the page. Acceptance: page loads.
- J-04: compute a total. Acceptance: total appears.
- J-13: run the sweep. Acceptance: sweep summary appears.
## Anti-goals
- none
EOF
  cat > "$SBX/docs/phases/$PHASE.md" <<'EOF'
# Full-depth spec (lifecycle test)
## Goal Mode Metadata
- **Mode:** next
- **Depth:** full
- **Target journeys:** J-04, J-13
- **Required-still-passing journeys:** none — no prior passing journeys
## IN SCOPE
- exercise the browser evidence lifecycle (wiring test)
EOF
  printf '# %s Execution Plan\n\nFrontend Present: yes\n' "$PHASE" > "$SBX/runs/$PHASE/plan.md"
  printf '{"phase":"%s","status":"in_progress","current_step":"%s"}\n' "$PHASE" "$step" > "$SBX/runs/$PHASE/status.json"
  printf '# UI test plan\n| UT-01 | generic UI test | smoke | P1 |\n' > "$SBX/reports/phase-$PHASE-ui-test-plan.md"
  printf '# what to click\n1. click\n' > "$SBX/reports/phase-$PHASE-what-to-click.md"
  printf '# Surface map\n- / (home)\n' > "$SBX/reports/phase-$PHASE-ui-surface-map.md"
  printf '# user visible\n\ncontent\n' > "$SBX/reports/phase-$PHASE-user-visible-changes.md"
  git -C "$SBX" add -A; git -C "$SBX" -c user.email=t@t -c user.name=t commit -qm base
  write_stub "$SBX" generate-test-plan.sh   ""            "reports/qa/${PHASE}-test-plan.md"
  write_stub "$SBX" dev-phase.sh            ""            "docs/handoffs/${PHASE}-dev.md"
  write_stub "$SBX" review-phase.sh         "PASS"        "reports/reviews/${PHASE}-review.md"
  write_stub "$SBX" ui-impact-phase.sh      ""            "reports/phase-${PHASE}-user-visible-changes.md" "reports/phase-${PHASE}-ui-surface-map.md" "reports/phase-${PHASE}-ui-test-plan.md" "reports/phase-${PHASE}-what-to-click.md"
  write_stub "$SBX" ui-test-design-phase.sh ""            "reports/phase-${PHASE}-ui-test-plan.md" "reports/phase-${PHASE}-what-to-click.md"
  write_stub "$SBX" qa-phase.sh             "PASS"        "reports/qa/${PHASE}-qa.md"
  write_stub "$SBX" demo-phase.sh           ""
  write_stub "$SBX" ux-regression-phase.sh  "UX-REGRESSION-PASS" "reports/phase-${PHASE}-ux-regression.md"
  write_stub "$SBX" phase-audit.sh          "PASS"        "docs/handoffs/${PHASE}-audit.md"
  write_stub "$SBX" phase-closure-check.sh  "CLOSURE-PASS" "reports/phase-${PHASE}-closure-verdict.md"
  install_merge_stub "$SBX"
  UI_TEST_RESULTS="$SBX/reports/phase-${PHASE}-ui-test-results.md"
}
run_phase() {  # <tag> [ENV=val ...] → RC
  local tag="$1"; shift
  RC=0; start_dummies
  ( cd "$SBX" && env PATH="$STUB_DIR:$PATH" CANARY="$CANARY" \
      CHAIN_BACKEND_PORT="$BE_PORT" CHAIN_FRONTEND_PORT="$FE_PORT" CHAIN_BACKEND_HEALTH_URL="http://localhost:${BE_PORT}/" \
      CHAIN_TMP_ROOT="$WORK/tmproot" CHAIN_TMP_JANITOR=false CHAIN_TMP_DISK_GUARD=false \
      CHAIN_DISABLE_TRACE=true CHAIN_KILL_GRACE_SECONDS=1 STUB_BQA_TARGET_ROWS="J-04 J-13" \
      "$@" timeout 300 bash scripts/automation/run-phase.sh "$PHASE" --no-finalize ) > "$WORK/run-$tag.log" 2>&1 || RC=$?
}
step_of() { python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('current_step',''))" "$SBX/runs/$PHASE/status.json" 2>/dev/null; }
headline_of() { grep -m1 -E '^\*\*Browser QA Verdict:\*\*' "$1" 2>/dev/null | grep -oE 'PASS|FAIL|SKIPPED' | head -1 || true; }
n_canary() { local n; n="$(grep -c "^$1" "$CANARY" 2>/dev/null)"; echo "${n:-0}"; }
downstream_ran() { grep -qE '^(qa-phase|demo-phase|ux-regression-phase|phase-audit|phase-closure-check)\.sh' "$CANARY"; }

# P1 — sequential Step 6 (resume from ui_test_designed): forced finalizer failure.
make_phase_sandbox P1 ui_test_designed
run_phase P1 STUB_FINALIZE_RC=1
[[ "$RC" -eq "$RC79" ]] && assert "P1: sequential run-phase exits the reserved rc ($RC79)" pass || { assert "P1: sequential run-phase exits the reserved rc (got rc=$RC)" fail; }
[[ "$(step_of)" == "ui_test_designed" ]] && assert "P1: browser_qa_complete NOT recorded (current_step stays ui_test_designed)" pass \
  || assert "P1: browser_qa_complete NOT recorded (current_step now '$(step_of)')" fail
! downstream_ran && assert "P1: no downstream step dispatched (no QA/demo/ux/audit/closure)" pass || assert "P1: downstream steps ran after the gate failure" fail
[[ "$(n_canary browser-qa-agent)" == "1" ]] && assert "P1: exactly one browser-qa dispatch (no retry)" pass || assert "P1: browser-qa dispatches: $(n_canary browser-qa-agent)" fail
[[ "$(headline_of "$UI_TEST_RESULTS")" == "SKIPPED" ]] && grep -qi 'FRAMEWORK FAILURE' "$UI_TEST_RESULTS" && assert "P1: results path holds the framework-failure SKIPPED stub" pass || assert "P1: results path holds the framework-failure SKIPPED stub" fail
grep -q 'browser evidence' "$WORK/run-P1.log" && ! grep -q 'exited with error -- continuing' "$WORK/run-P1.log" \
  && assert "P1: the guard names the browser evidence gate and never warns-and-continues" pass \
  || assert "P1: the guard names the browser evidence gate and never warns-and-continues" fail

# P2 — post-dev parallel fanout (from review_passed): forced finalizer failure in Branch A.
make_phase_sandbox P2 review_passed
run_phase P2 STUB_FINALIZE_RC=1
[[ "$RC" -eq "$RC79" ]] && assert "P2: fanout run-phase exits the reserved rc ($RC79)" pass || assert "P2: fanout run-phase exits the reserved rc (got rc=$RC)" fail
[[ "$(step_of)" == "review_passed" ]] && assert "P2: post_dev_parallel_complete NOT recorded (current_step stays review_passed)" pass \
  || assert "P2: post_dev_parallel_complete NOT recorded (current_step now '$(step_of)')" fail
! grep -q 'sequential retry will pick up' "$WORK/run-P2.log" && ! grep -q 'Post-dev fanout complete' "$WORK/run-P2.log" \
  && assert "P2: the fanout failure is not softened into a warning + completion" pass \
  || assert "P2: the fanout failure was softened into a warning + completion" fail
! grep -qE '^(ux-regression-phase|phase-audit|phase-closure-check)\.sh' "$CANARY" \
  && assert "P2: nothing after the fanout dispatched" pass || assert "P2: steps after the fanout dispatched" fail
[[ "$(n_canary browser-qa-agent)" == "1" ]] && assert "P2: exactly one browser-qa dispatch" pass || assert "P2: browser-qa dispatches: $(n_canary browser-qa-agent)" fail

# P3 — healthy sequential control.
make_phase_sandbox P3 ui_test_designed
run_phase P3
[[ "$RC" -eq 0 ]] && assert "P3: healthy sequential run completes (rc 0)" pass || { assert "P3: healthy sequential run completes (rc=$RC)" fail; tail -20 "$WORK/run-P3.log"; }
[[ "$(step_of)" != "ui_test_designed" ]] && downstream_ran && assert "P3: healthy run records browser QA complete and dispatches downstream" pass \
  || assert "P3: healthy run records browser QA complete and dispatches downstream (step '$(step_of)')" fail
[[ "$(n_canary browser-qa-agent)" == "1" && "$(headline_of "$UI_TEST_RESULTS")" == "PASS" ]] && assert "P3: one browser-qa dispatch, merged/finalized PASS" pass \
  || assert "P3: one browser-qa dispatch, PASS (dispatches=$(n_canary browser-qa-agent), headline=$(headline_of "$UI_TEST_RESULTS"))" fail

# P4 — healthy parallel control.
make_phase_sandbox P4 review_passed
run_phase P4
[[ "$RC" -eq 0 ]] && grep -q 'Post-dev fanout complete' "$WORK/run-P4.log" && assert "P4: healthy fanout run completes with post_dev_parallel_complete" pass \
  || { assert "P4: healthy fanout run completes (rc=$RC)" fail; tail -20 "$WORK/run-P4.log"; }
[[ "$(n_canary browser-qa-agent)" == "1" && "$(headline_of "$UI_TEST_RESULTS")" == "PASS" ]] && assert "P4: one browser-qa dispatch, PASS" pass \
  || assert "P4: one browser-qa dispatch, PASS (dispatches=$(n_canary browser-qa-agent))" fail

# P5 — quarantine belt: the raw PASS cannot be moved aside (a READ-ONLY
# directory occupies the *.unverified.md path, so `mv` cannot create the entry;
# deterministic for a non-root user — skipped as root), so it STAYS at the
# authoritative results path and no stub can replace it.
occupy_aside() { mkdir -p "$1"; chmod 555 "$1"; }
if [[ "$(id -u)" != "0" ]]; then
make_phase_sandbox P5 ui_test_designed
occupy_aside "${UI_TEST_RESULTS%.md}.unverified.md"
run_phase P5 STUB_FINALIZE_RC=1
[[ "$(headline_of "$UI_TEST_RESULTS")" == "PASS" ]] && assert "P5: (seam) the raw agent PASS remains at the results path when quarantine fails" pass \
  || assert "P5: (seam) expected the raw PASS to remain (got '$(headline_of "$UI_TEST_RESULTS")')" fail
[[ "$RC" -eq "$RC79" && "$(step_of)" == "ui_test_designed" ]] && ! downstream_ran \
  && assert "P5: even so, run-phase exits $RC79, records nothing and dispatches nothing" pass \
  || assert "P5: even so, run-phase exits $RC79, records nothing and dispatches nothing (rc=$RC step='$(step_of)')" fail
chmod 755 "${UI_TEST_RESULTS%.md}.unverified.md" 2>/dev/null || true
fi

# ══ E. lean + full through the REAL run-goal.sh ═══════════════════════════════
ESBX="$WORK/engine"; mkdir -p "$ESBX"
cp -r "$ENGINE_ROOT/scripts" "$ESBX/"
mkdir -p "$ESBX/docs/phases" "$ESBX/reports" "$ESBX/src" "$ESBX/.claude/agents"
touch "$ESBX/.claude/agents/developer.md"
git init -q "$ESBX"; echo "print('v1')" > "$ESBX/src/app.py"
cat > "$ESBX/docs/goal.md" <<'EOF'
# Goal

Tiny CSV exporter web app.

## Must-have user journeys

- **J-01: Open the page**
  - Steps: open /
  - Acceptance: page loads
- **J-04: Compute a total**
  - Steps: click total
  - Acceptance: total appears
- **J-13: Run the sweep**
  - Steps: click sweep
  - Acceptance: sweep summary appears

## Anti-goals

- no paid SaaS
EOF
git -C "$ESBX" add -A; git -C "$ESBX" -c user.email=t@t -c user.name=t commit -qm base
install_merge_stub "$ESBX"
cp "$ESBX/scripts/automation/run-phase.sh" "$WORK/run-phase.real"
TMPROOT="$WORK/tmproot-engine"; mkdir -p "$TMPROOT"
run_engine() {  # <sid> <mode: fresh|resume> [ENV=val ...] → ENG_RC, ENG_LOG, ENG_SESSION, CANARY
  local sid="$1" mode="$2"; shift 2
  ENG_SID="$sid"; ENG_LOG="$WORK/eng-$sid-$mode.log"
  CANARY="$WORK/canary-eng-$sid-$mode.log"; : > "$CANARY"; export CANARY
  ENG_SESSION="$ESBX/runs/goal-session-$sid"
  local -a args=(--session-id "$sid" --max-iter 1 --no-push-per-iter)
  if [[ "$mode" == "resume" ]]; then args+=(--resume); else rm -rf "$ENG_SESSION" "$ESBX/docs/phases"/*.md 2>/dev/null; fi
  ENG_RC=0; start_dummies
  ( cd "$ESBX" && env PATH="$STUB_DIR:$PATH" CANARY="$CANARY" \
      CHAIN_DOCTOR=false CHAIN_GOAL_LINT=false CHAIN_SESSION_RETRO=false \
      CHAIN_TMP_ROOT="$TMPROOT" CHAIN_TMP_LEGACY_ROOTS="" CHAIN_DISABLE_TRACE=true \
      CHAIN_BACKEND_PORT="$BE_PORT" CHAIN_FRONTEND_PORT="$FE_PORT" CHAIN_BACKEND_HEALTH_URL="http://localhost:${BE_PORT}/" \
      CHAIN_SKIP_GITHUB_PREFLIGHT=true CHAIN_KILL_GRACE_SECONDS=1 \
      "$@" timeout 300 bash scripts/automation/run-goal.sh "${args[@]}" ) > "$ENG_LOG" 2>&1 || ENG_RC=$?
}
eng_status() { python3 -c "import json; print(json.load(open('$ENG_SESSION/session.json')).get('status','?'))" 2>/dev/null || echo '?'; }
eng_iter()   { python3 -c "import json; print(json.load(open('$ENG_SESSION/session.json')).get('current_iter','?'))" 2>/dev/null || echo '?'; }
eng_n()      { local n; n="$(grep -c "^$1$" "$CANARY" 2>/dev/null)"; echo "${n:-0}"; }
ERES="$ESBX/reports/phase-goal-SID-iter-0-ui-test-results.md"

# E1 — lean gate failure → top-level resumable halt before coherence/evaluator.
run_engine lc1 fresh STUB_FINALIZE_RC=1
RES1="${ERES/SID/lc1}"
[[ "$(eng_status)" == "GATE_BLOCKED" ]] && assert "E1: lean browser evidence gate failure → session GATE_BLOCKED" pass \
  || assert "E1: lean browser evidence gate failure → GATE_BLOCKED (got '$(eng_status)', engine rc=$ENG_RC)" fail
grep -q '"reason": *"GATE_BLOCKED_BROWSER_EVIDENCE"' "$ENG_SESSION/telemetry.jsonl" 2>/dev/null && grep -q "\"rc\": *$RC79" "$ENG_SESSION/telemetry.jsonl" 2>/dev/null \
  && assert "E1: halt telemetry carries reason GATE_BLOCKED_BROWSER_EVIDENCE and rc $RC79" pass \
  || assert "E1: halt telemetry carries reason GATE_BLOCKED_BROWSER_EVIDENCE and rc $RC79" fail
[[ "$(eng_n goal-evaluator)" == "0" && "$(eng_n coherence-auditor)" == "0" ]] \
  && assert "E1: no coherence-auditor and no goal-evaluator dispatch after the gate failure" pass \
  || assert "E1: coherence/evaluator dispatched (coh=$(eng_n coherence-auditor) eval=$(eng_n goal-evaluator))" fail
[[ "$(eng_n browser-qa-agent)" == "1" ]] && assert "E1: exactly one browser-qa dispatch (no retry)" pass || assert "E1: browser-qa dispatches: $(eng_n browser-qa-agent)" fail
[[ "$(eng_iter)" == "0" ]] && assert "E1: current_iter unchanged (0)" pass || assert "E1: current_iter unchanged (got $(eng_iter))" fail
[[ ! -f "$ENG_SESSION/iter-0/.steps/browser-qa.done" ]] && assert "E1: browser-qa.done DOES NOT EXIST" pass || assert "E1: browser-qa.done DOES NOT EXIST" fail
[[ -f "$ENG_SESSION/iter-0/browser-evidence-gate-unavailable" ]] && assert "E1: the iteration carries the browser-evidence-gate-unavailable marker" pass \
  || assert "E1: the iteration carries the browser-evidence-gate-unavailable marker" fail
grep -q 'NOT evaluated' "$ENG_LOG" && grep -q 'goal-resume' "$ENG_LOG" && ! grep -qi 'product code' "$ENG_LOG" \
  && assert "E1: operator message: not evaluated, not advanced, resume — no blame on product code" pass \
  || assert "E1: operator message: not evaluated, not advanced, resume — no blame on product code" fail
[[ "$(headline_of "$RES1")" == "SKIPPED" ]] && ! grep -qF '| FAIL |' "$RES1" && [[ ! -f "$ENG_SESSION/iter-0/browser-infra.json" ]] \
  && assert "E1: results path = SKIPPED framework stub; no FAIL, no infra token" pass \
  || assert "E1: results path = SKIPPED framework stub; no FAIL, no infra token (headline '$(headline_of "$RES1")')" fail

# E2 — quarantine belt: the raw PASS cannot be moved aside (read-only obstacle
# directory) and stays authoritative on disk; the rc is the only boundary.
RES2="${ERES/SID/lc2}"
if [[ "$(id -u)" != "0" ]]; then
mkdir -p "$(dirname "$RES2")"; occupy_aside "${RES2%.md}.unverified.md"
run_engine lc2 fresh STUB_FINALIZE_RC=1
[[ "$(headline_of "$RES2")" == "PASS" ]] && assert "E2: (seam) the raw agent PASS remains at the results path" pass \
  || assert "E2: (seam) expected the raw PASS to remain (got '$(headline_of "$RES2")')" fail
[[ "$(eng_status)" == "GATE_BLOCKED" && "$(eng_n goal-evaluator)" == "0" && "$(eng_iter)" == "0" ]] \
  && assert "E2: the evaluator still never runs — GATE_BLOCKED, no evaluator, current_iter 0 (the rc is the safety boundary)" pass \
  || assert "E2: evaluator boundary (status='$(eng_status)' eval=$(eng_n goal-evaluator) iter=$(eng_iter))" fail
chmod 755 "${RES2%.md}.unverified.md" 2>/dev/null || true
fi

# E3 — resume after the fault is removed: the SAME iteration re-runs, no approval.
run_engine lc1 resume
[[ "$(eng_status)" != "GATE_BLOCKED" ]] && assert "E3: /goal-resume leaves GATE_BLOCKED (status now '$(eng_status)')" pass \
  || assert "E3: resume leaves GATE_BLOCKED" fail
[[ "$(eng_n browser-qa-agent)" -ge 1 && "$(eng_n goal-evaluator)" -ge 1 ]] \
  && assert "E3: the same iteration re-collected browser evidence and reached the evaluator" pass \
  || assert "E3: resume re-collects + reaches evaluator (bqa=$(eng_n browser-qa-agent) eval=$(eng_n goal-evaluator))" fail
[[ "$(eng_iter)" == "0" ]] && ! grep -qi 'approv' "$ENG_LOG" \
  && assert "E3: same iteration (0) re-ran with nothing but --resume — no approval step" pass \
  || assert "E3: same iteration, no approval (iter=$(eng_iter))" fail
[[ "$(headline_of "${ERES/SID/lc1}")" == "PASS" ]] && assert "E3: the re-collected results finalize PASS" pass || assert "E3: the re-collected results finalize PASS (got '$(headline_of "${ERES/SID/lc1}")')" fail

# E4 — healthy lean control: the evaluator is reached with one browser dispatch.
run_engine lc4 fresh
[[ "$(eng_status)" != "GATE_BLOCKED" && "$(eng_n goal-evaluator)" == "1" && "$(eng_n browser-qa-agent)" == "1" ]] \
  && assert "E4: healthy lean iteration reaches the evaluator with exactly one browser dispatch (status '$(eng_status)')" pass \
  || assert "E4: healthy lean (status='$(eng_status)' eval=$(eng_n goal-evaluator) bqa=$(eng_n browser-qa-agent))" fail
[[ -f "$ENG_SESSION/iter-0/.steps/browser-qa.done" && "$(headline_of "${ERES/SID/lc4}")" == "PASS" ]] \
  && assert "E4: healthy lean writes browser-qa.done with a PASS headline" pass || assert "E4: healthy lean checkpoint + PASS" fail
E4_SEQ="$(tr '\n' ' ' < "$CANARY")"

# E5 — FULL path: run-phase.sh exiting the reserved rc reaches the identical halt.
printf '#!/usr/bin/env bash\n# stub run-phase.sh (accepts --no-finalize)\necho "run-phase.sh" >> "$CANARY"\nexit %s\n' "$RC79" > "$ESBX/scripts/automation/run-phase.sh"
run_engine lc5 fresh STUB_SPEC_DEPTH=full CHAIN_DEPTH_ARBITER=false
cp "$WORK/run-phase.real" "$ESBX/scripts/automation/run-phase.sh"
_fd="$(cat "$ENG_SESSION/iter-0/depth-dispatched" 2>/dev/null)"
[[ "$(eng_status)" == "GATE_BLOCKED" && "$_fd" == "full" && "$(eng_n goal-evaluator)" == "0" && "$(eng_iter)" == "0" ]] \
  && assert "E5: the FULL pipeline exiting $RC79 reaches the identical GATE_BLOCKED halt (no evaluator, iter 0)" pass \
  || assert "E5: full path halt (status='$(eng_status)' depth='$_fd' eval=$(eng_n goal-evaluator) iter=$(eng_iter))" fail
grep -q '"reason": *"GATE_BLOCKED_BROWSER_EVIDENCE"' "$ENG_SESSION/telemetry.jsonl" 2>/dev/null \
  && assert "E5: full path halt telemetry carries GATE_BLOCKED_BROWSER_EVIDENCE" pass || assert "E5: full path halt telemetry" fail

# ══ W. wiring ═════════════════════════════════════════════════════════════════
RP="$ENGINE_ROOT/scripts/automation/run-phase.sh"; RG="$ENGINE_ROOT/scripts/automation/run-goal.sh"
GIL="$ENGINE_ROOT/scripts/automation/goal-iter-lean.sh"; BQP="$ENGINE_ROOT/scripts/automation/browser-qa-phase.sh"; RL="$ENGINE_ROOT/scripts/automation/lib/replay-lane.sh"
grep -q '_is_browser_evidence_gate_unavailable' "$RP" && [[ "$(grep -c 'BROWSER_EVIDENCE_GATE_UNAVAILABLE_EXIT_CODE' "$RP")" -ge 2 ]] \
  && assert "W1: run-phase.sh classifies the reserved rc and _guard_step_rc exits on it" pass || assert "W1: run-phase.sh guard wiring" fail
_g="$(grep -n '^_guard_step_rc()' "$RP" | cut -d: -f1)"; _w="$(grep -n 'exited with error -- continuing' "$RP" | head -1 | cut -d: -f1)"
[[ -n "$_g" && -n "$_w" && "$_g" -lt "$_w" ]] && assert "W2: the fatal guard is defined before any warn-and-continue site" pass || assert "W2: guard ordering" fail
_halt="$(grep -n 'GATE_BLOCKED_BROWSER_EVIDENCE' "$RG" | head -1 | cut -d: -f1)"; _coh="$(grep -n '3b. Coherence auditor' "$RG" | head -1 | cut -d: -f1)"
[[ -n "$_halt" && -n "$_coh" && "$_halt" -lt "$_coh" ]] && assert "W3: run-goal.sh halts on the reserved rc BEFORE the coherence auditor / evaluator section" pass \
  || assert "W3: run-goal.sh halt placement (halt=$_halt coherence=$_coh)" fail
[[ "$(grep -c 'BROWSER_EVIDENCE_GATE_UNAVAILABLE_EXIT_CODE' "$GIL")" -ge 2 && "$(grep -c 'BROWSER_EVIDENCE_GATE_UNAVAILABLE_EXIT_CODE' "$BQP")" -ge 2 && "$(grep -c 'BROWSER_EVIDENCE_GATE_UNAVAILABLE_EXIT_CODE' "$RL")" -ge 1 ]] \
  && assert "W4: both executors and the lib helper exit/return the reserved rc (no literal generic 1)" pass || assert "W4: executor/helper exit codes" fail
! grep -qE 'bqa_coverage_gate_fail_closed[^;]*; exit 1;' "$GIL" "$BQP" \
  && assert "W5: no fail-closed site still exits generic 1" pass || assert "W5: a fail-closed site still exits generic 1" fail

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
