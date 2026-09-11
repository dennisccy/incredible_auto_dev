#!/usr/bin/env bash
# test-browser-evidence-closure.sh — browser / evidence closure reliability:
# the REAL goal-iter-lean.sh in a sandbox, driven through the exact production
# incident shape, proving the merged results and the REL-14 browser-infra
# token are target-specific and honest — with NO change to the number of
# model dispatches.
#
# The incident: the deterministic replay lane PASSes the stable journeys
# (J-01, J-02) while the LLM browser-qa dispatch — the only fresh evidence for
# this iteration's targets (J-04, J-13) — never gets a working Chrome. Before
# this package the merged headline said PASS (any surviving PASS row won) and
# the post-scan, run over the MERGED file, saw those replay PASS rows and
# suppressed the browser-infra token for the targets. Nothing downstream could
# tell that the targets were never verified.
#
# Scenarios (stub `claude` on PATH, stub demo_runner.py for the replay lane,
# dummy HTTP services on test ports; the default parallel-replay knob):
#   R1  incident — targets all infra-SKIP: token journeys EXACTLY J-04 J-13,
#       merged headline SKIPPED (never PASS), replay PASS rows intact, no FAIL
#       invented, the browser-qa checkpoint NOT written (a resume re-collects),
#       dispatch sequence developer → reviewer → browser-qa-agent (3 calls).
#   R1b same shape with CHAIN_BQA_PREFLIGHT unset (the default): no token —
#       the token stays opt-in — but the headline is still SKIPPED (honesty of
#       the merged headline is not knob-gated).
#   R2  mixed — J-04 PASS, J-13 infra-SKIP: token EXACTLY J-13; J-04 is not
#       pending-infra; headline SKIPPED.
#   R3  J-04 FAIL, J-13 infra-SKIP: headline FAIL (a product defect is never
#       hidden by infra handling); token EXACTLY J-13.
#   R7  healthy — every target PASS: merged PASS, no token, checkpoint written,
#       dispatch sequence IDENTICAL to R1's (the invocation-count invariant
#       NO_STEADY_STATE_AGENT_CALL_INCREASE).
#   S   structural pin: the new deterministic path (classifier + coverage
#       contract) contains no agent-dispatch primitive at all.
#
# No API calls; a few seconds per scenario.
#
# shellcheck disable=SC2015,SC2034,SC2329
# (SC2015: assert's pass arm always returns 0, so `&& pass || fail` is safe;
# SC2034: the seq loop var is intentionally unused; SC2329: cleanup runs via trap.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BE_PORT=48371
FE_PORT=48372

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

# ── Sandbox builder (fresh per scenario; engine scripts embedded) ────────────
make_sandbox() {
  local tag="$1" n="$2"
  SBX="$WORK/proj-$tag"
  mkdir -p "$SBX"
  cp -r "$ENGINE_ROOT/scripts" "$SBX/"
  mkdir -p "$SBX/docs/phases" "$SBX/docs/handoffs" "$SBX/reports/reviews" "$SBX/src"
  git init -q "$SBX"
  echo "print('v1')" > "$SBX/src/app.py"
  cat > "$SBX/docs/goal.md" <<'EOF'
# Goal
## Must-have user journeys
- J-01: log in. Acceptance: dashboard shows.
- J-02: browse items. Acceptance: list renders.
- J-04: compute a total. Acceptance: total appears.
- J-13: run the sweep. Acceptance: sweep summary appears.
## Anti-goals
- none
EOF
  ITER="goal-bectest-iter-$n"
  cat > "$SBX/docs/phases/$ITER.md" <<'EOF'
# Iteration spec
## Goal Mode Metadata
- **Mode:** next
- **Depth:** lean
- **Target journeys:** J-04, J-13
- **Required-still-passing:** J-01, J-02
## IN SCOPE
- compute + sweep (evidence-closure wiring test)
EOF
  git -C "$SBX" add -A
  git -C "$SBX" -c user.email=t@t -c user.name=t commit -qm base

  export GOAL_SESSION_DIR="$SBX/runs/goal-session-bectest"
  export GOAL_ITER_INDEX="$n" GOAL_ITER_NAME="$ITER"
  ITER_DIR="$GOAL_SESSION_DIR/iter-$n"
  mkdir -p "$ITER_DIR" "$GOAL_SESSION_DIR/journey-scripts"
  UI_TEST_RESULTS="$SBX/reports/phase-${ITER}-ui-test-results.md"
  # Goldens for the stable journeys → the replay lane engages for J-01, J-02.
  echo '{"journey":"J-01","steps":[]}' > "$GOAL_SESSION_DIR/journey-scripts/J-01.json"
  echo '{"journey":"J-02","steps":[]}' > "$GOAL_SESSION_DIR/journey-scripts/J-02.json"

  # Stub demo_runner: lint ok; verify writes production-shaped PASS rows.
  cat > "$SBX/scripts/automation/lib/demo_runner.py" <<'PYEOF'
#!/usr/bin/env python3
import sys

def arg(name, default=""):
    if name in sys.argv:
        i = sys.argv.index(name)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default

mode = arg("--mode", "record")
journeys = [j for j in arg("--journeys").replace(",", " ").split() if j]
if mode == "lint":
    for j in journeys:
        print(f"{j} ok")
    sys.exit(0)
if mode == "verify":
    results = arg("--results")
    if results:
        rows = "\n".join(
            f"| UT-{j} | replay {j} | regression | P1 | replays clean | stub pass | PASS | none |"
            for j in journeys)
        with open(results, "w") as f:
            f.write("**Browser QA Verdict:** PASS\n\n"
                    "| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n"
                    "|---|---|---|---|---|---|---|---|\n" + rows + "\n")
    sys.exit(0)
sys.exit(0)
PYEOF
}

# ── Role-aware stub claude (keyed on CHAIN_CURRENT_AGENT) ─────────────────────
# browser-qa-agent rows come from STUB_BQA_VERDICTS ("J-04=INFRA J-13=FAIL";
# default PASS): INFRA = a browser-infra SKIP row with the production taxonomy.
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<'EOF'
#!/usr/bin/env bash
agent="${CHAIN_CURRENT_AGENT:-unknown}"
prompt="$*"
echo "$agent" >> "$CANARY"
case "$agent" in
  developer)
    out="$(printf '%s\n' "$prompt" | sed -n 's/^- Write dev handoff to: //p' | head -n1)"
    [[ -n "$out" ]] || exit 64
    echo "print('v2 built by stub')" > src/app.py
    printf 'handoff: implemented the iter spec (stub).\n' > "$out"
    exit 0 ;;
  reviewer)
    out="$(printf '%s\n' "$prompt" | sed -n 's/^Write your review report to: //p' | head -n1)"
    [[ -n "$out" ]] || exit 64
    printf '**Verdict:** PASS\n\nStub review.\n' > "$out"
    exit 0 ;;
  browser-qa-agent)
    out="$(printf '%s\n' "$prompt" | sed -n 's/^Write your results to: //p' | head -n1)"
    [[ -n "$out" ]] || exit 64
    line="$(printf '%s\n' "$prompt" | sed -n 's/^GOAL-MODE LEAN MODE — test EXACTLY these journeys this run: //p' | head -n1)"
    printf '%s\n' "$line" > "$PROMPT_LINE_OUT"
    journeys="$(printf '%s\n' "$line" | grep -oE 'J-[0-9]+' | sort -u | tr '\n' ' ' || true)"
    infra="browser infrastructure failure: Chrome did not become ready on port 9222 within 15000ms"
    rows=""; any_fail=no; any_pass=no
    for j in $journeys; do
      v="PASS"
      for kv in ${STUB_BQA_VERDICTS:-}; do [[ "${kv%%=*}" == "$j" ]] && v="${kv#*=}"; done
      case "$v" in
        INFRA) rows+="| UT-$j | llm $j | journey | P1 | works | $infra | SKIP | none |"$'\n' ;;
        FAIL)  rows+="| UT-$j | llm $j | journey | P1 | works | button did nothing | FAIL | reports/qa/x.png |"$'\n'; any_fail=yes ;;
        *)     rows+="| UT-$j | llm $j | journey | P1 | works | stub verified | PASS | reports/qa/x.png |"$'\n'; any_pass=yes ;;
      esac
    done
    head="PASS"
    [[ "$any_fail" == yes ]] && head="FAIL"
    [[ "$any_fail" == no && "$any_pass" == no ]] && head="SKIPPED"
    {
      printf '**Browser QA Verdict:** %s\n\n' "$head"
      printf '| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n'
      printf '|---|---|---|---|---|---|---|---|\n'
      printf '%s' "$rows"
    } > "$out"
    exit 0 ;;
esac
exit 70
EOF
chmod +x "$STUB_DIR/claude"

# ── Dummy services on the test ports (already-healthy fast path) ─────────────
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

export CHAIN_BACKEND_PORT="$BE_PORT"
export CHAIN_FRONTEND_PORT="$FE_PORT"
export CHAIN_KILL_GRACE_SECONDS=1

run_lean() {  # stdout+stderr → $1; rc in global LEAN_RC
  local log="$1"
  start_dummies
  export CANARY PROMPT_LINE_OUT
  LEAN_RC=0
  ( cd "$SBX" && PATH="$STUB_DIR:$PATH" bash scripts/automation/goal-iter-lean.sh "$ITER" ) >"$log" 2>&1 || LEAN_RC=$?
}
new_capture() {
  CANARY="$WORK/canary-$1.log"; : > "$CANARY"
  PROMPT_LINE_OUT="$WORK/llm-line-$1.txt"; : > "$PROMPT_LINE_OUT"
}
dispatches() { tr '\n' ' ' < "$CANARY"; }
token_journeys() { python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["journeys"]))' "$1" 2>/dev/null || echo "(no token)"; }
headline() { grep -m1 -E '^\*\*Browser QA Verdict:\*\*' "$1" 2>/dev/null | grep -oE 'PASS|FAIL|SKIPPED' | head -1 || true; }
row_verdict() { grep -E "^\| UT-$2 " "$1" 2>/dev/null | head -1 | awk -F'|' '{print $8}' | tr -d ' ' || true; }

echo "=== test-browser-evidence-closure.sh ==="

# ══ R1: the exact incident shape ═════════════════════════════════════════════
make_sandbox R1 1
new_capture R1
export CHAIN_BQA_PREFLIGHT=true STUB_BQA_VERDICTS="J-04=INFRA J-13=INFRA"
run_lean "$WORK/lean-R1.log"
[[ "$LEAN_RC" -eq 0 ]] && assert "R1: incident iteration exits 0 (infra is not a product failure)" pass \
  || { assert "R1: incident iteration exits 0 (rc=$LEAN_RC)" fail; sed -n '1,40p' "$WORK/lean-R1.log"; }
[[ "$(cat "$PROMPT_LINE_OUT")" == *"J-04"* && "$(cat "$PROMPT_LINE_OUT")" == *"J-13"* && "$(cat "$PROMPT_LINE_OUT")" != *"J-01"* ]] \
  && assert "R1: the LLM dispatch owed exactly the targets (J-04 J-13); J-01/J-02 rode the replay" pass \
  || assert "R1: the LLM dispatch owed exactly the targets (got: $(cat "$PROMPT_LINE_OUT"))" fail
[[ "$(token_journeys "$ITER_DIR/browser-infra.json")" == "J-04 J-13" ]] \
  && assert "R1: browser-infra.json lists EXACTLY J-04 J-13 (the replay PASS rows did not mask them)" pass \
  || assert "R1: browser-infra.json lists EXACTLY J-04 J-13 (got: $(token_journeys "$ITER_DIR/browser-infra.json"))" fail
grep -q '"detected_by": "postscan"' "$ITER_DIR/browser-infra.json" 2>/dev/null && grep -q '"attempts": 1' "$ITER_DIR/browser-infra.json" 2>/dev/null \
  && assert "R1: token detected_by=postscan, attempts=1 (contract preserved)" pass \
  || assert "R1: token detected_by=postscan, attempts=1 (contract preserved)" fail
[[ "$(headline "$UI_TEST_RESULTS")" == "SKIPPED" ]] \
  && assert "R1: merged headline is SKIPPED — never PASS on replay rows alone" pass \
  || { assert "R1: merged headline is SKIPPED (got: $(headline "$UI_TEST_RESULTS"))" fail; head -14 "$UI_TEST_RESULTS" 2>/dev/null | sed 's/^/        /'; }
[[ "$(row_verdict "$UI_TEST_RESULTS" J-01)" == "PASS" && "$(row_verdict "$UI_TEST_RESULTS" J-02)" == "PASS" ]] \
  && assert "R1: replay PASS rows (J-01 J-02) survive the merge intact" pass \
  || assert "R1: replay PASS rows (J-01 J-02) survive the merge intact" fail
[[ "$(row_verdict "$UI_TEST_RESULTS" J-04)" == "SKIP" && "$(row_verdict "$UI_TEST_RESULTS" J-13)" == "SKIP" ]] && ! grep -qF '| FAIL |' "$UI_TEST_RESULTS" \
  && assert "R1: targets recorded SKIP (not FAIL) — no journey is failed because of infra" pass \
  || assert "R1: targets recorded SKIP (not FAIL) — no journey is failed because of infra" fail
grep -q '^\*\*Fresh-evidence coverage:\*\* INCOMPLETE' "$UI_TEST_RESULTS" 2>/dev/null \
  && assert "R1: merged file carries the coverage note naming the undelivered obligation" pass \
  || assert "R1: merged file carries the coverage note naming the undelivered obligation" fail
[[ ! -f "$ITER_DIR/.steps/browser-qa.done" ]] \
  && assert "R1: browser-qa checkpoint NOT written (a resume re-collects the owed evidence)" pass \
  || assert "R1: browser-qa checkpoint NOT written (a resume re-collects the owed evidence)" fail
[[ "$(dispatches)" == "developer reviewer browser-qa-agent " ]] \
  && assert "R1: dispatch sequence developer → reviewer → browser-qa-agent (3 model calls, no extra)" pass \
  || assert "R1: dispatch sequence (got: $(dispatches))" fail
R1_DISPATCHES="$(dispatches)"

# ══ R1b: same shape, CHAIN_BQA_PREFLIGHT unset (default) ═════════════════════
make_sandbox R1b 2
new_capture R1b
unset CHAIN_BQA_PREFLIGHT
export STUB_BQA_VERDICTS="J-04=INFRA J-13=INFRA"
run_lean "$WORK/lean-R1b.log"
[[ ! -f "$ITER_DIR/browser-infra.json" ]] \
  && assert "R1b: knob off (default) → no token (the token stays opt-in; global default untouched)" pass \
  || assert "R1b: knob off (default) → no token (the token stays opt-in; global default untouched)" fail
[[ "$(headline "$UI_TEST_RESULTS")" == "SKIPPED" ]] \
  && assert "R1b: knob off → merged headline is STILL SKIPPED (headline honesty is not knob-gated)" pass \
  || assert "R1b: knob off → merged headline is STILL SKIPPED (got: $(headline "$UI_TEST_RESULTS"))" fail
[[ "$(dispatches)" == "$R1_DISPATCHES" ]] \
  && assert "R1b: dispatch sequence unchanged" pass || assert "R1b: dispatch sequence unchanged (got: $(dispatches))" fail

# ══ R2: mixed — J-04 PASS, J-13 infra-SKIP ═══════════════════════════════════
make_sandbox R2 3
new_capture R2
export CHAIN_BQA_PREFLIGHT=true STUB_BQA_VERDICTS="J-04=PASS J-13=INFRA"
run_lean "$WORK/lean-R2.log"
[[ "$(token_journeys "$ITER_DIR/browser-infra.json")" == "J-13" ]] \
  && assert "R2: token names ONLY J-13 — the verified target J-04 is not pending-infra" pass \
  || assert "R2: token names ONLY J-13 (got: $(token_journeys "$ITER_DIR/browser-infra.json"))" fail
[[ "$(row_verdict "$UI_TEST_RESULTS" J-04)" == "PASS" ]] \
  && assert "R2: J-04's fresh PASS is recorded" pass || assert "R2: J-04's fresh PASS is recorded" fail
[[ "$(headline "$UI_TEST_RESULTS")" == "SKIPPED" ]] \
  && assert "R2: merged headline SKIPPED while a required target is infra-blocked" pass \
  || assert "R2: merged headline SKIPPED (got: $(headline "$UI_TEST_RESULTS"))" fail
[[ "$(dispatches)" == "$R1_DISPATCHES" ]] \
  && assert "R2: dispatch sequence unchanged" pass || assert "R2: dispatch sequence unchanged (got: $(dispatches))" fail

# ══ R3: J-04 FAIL, J-13 infra-SKIP ═══════════════════════════════════════════
make_sandbox R3 4
new_capture R3
export STUB_BQA_VERDICTS="J-04=FAIL J-13=INFRA"
run_lean "$WORK/lean-R3.log"
[[ "$(headline "$UI_TEST_RESULTS")" == "FAIL" ]] \
  && assert "R3: a real product FAIL dominates — merged headline FAIL" pass \
  || assert "R3: a real product FAIL dominates (got: $(headline "$UI_TEST_RESULTS"))" fail
[[ "$(row_verdict "$UI_TEST_RESULTS" J-04)" == "FAIL" ]] \
  && assert "R3: the FAIL row survives (infra handling never hides a defect)" pass \
  || assert "R3: the FAIL row survives (infra handling never hides a defect)" fail
[[ "$(token_journeys "$ITER_DIR/browser-infra.json")" == "J-13" ]] \
  && assert "R3: J-13 still receives infra attribution alongside the FAIL" pass \
  || assert "R3: J-13 still receives infra attribution (got: $(token_journeys "$ITER_DIR/browser-infra.json"))" fail

# ══ R7: healthy — every target PASS ══════════════════════════════════════════
make_sandbox R7 5
new_capture R7
unset STUB_BQA_VERDICTS
run_lean "$WORK/lean-R7.log"
[[ "$LEAN_RC" -eq 0 ]] && assert "R7: healthy iteration exits 0" pass \
  || { assert "R7: healthy iteration exits 0 (rc=$LEAN_RC)" fail; sed -n '1,40p' "$WORK/lean-R7.log"; }
[[ "$(headline "$UI_TEST_RESULTS")" == "PASS" ]] && ! grep -q 'Fresh-evidence coverage' "$UI_TEST_RESULTS" \
  && assert "R7: merged PASS with no coverage note" pass \
  || assert "R7: merged PASS with no coverage note (got: $(headline "$UI_TEST_RESULTS"))" fail
[[ ! -f "$ITER_DIR/browser-infra.json" ]] \
  && assert "R7: no browser-infra token" pass || assert "R7: no browser-infra token" fail
[[ -f "$ITER_DIR/.steps/browser-qa.done" ]] \
  && assert "R7: browser-qa checkpoint written (PASS verdict)" pass || assert "R7: browser-qa checkpoint written (PASS verdict)" fail
[[ "$(dispatches)" == "$R1_DISPATCHES" && "$(dispatches)" == "developer reviewer browser-qa-agent " ]] \
  && assert "R7: dispatch sequence IDENTICAL to the incident run — NO_STEADY_STATE_AGENT_CALL_INCREASE" pass \
  || assert "R7: dispatch sequence (got: $(dispatches); R1 had: $R1_DISPATCHES)" fail
unset CHAIN_BQA_PREFLIGHT

# ══ S: structural pin — the new deterministic path dispatches nothing ════════
MERGE_PY="$ENGINE_ROOT/scripts/automation/lib/merge_ui_test_results.py"
RL="$ENGINE_ROOT/scripts/automation/lib/replay-lane.sh"
! grep -qE 'claude_with_quota_retry|record_agent_invocation_start|_interactive_invoke|subprocess|os\.system' "$MERGE_PY" \
  && assert "S: merge_ui_test_results.py (classifier + coverage contract) has no dispatch primitive" pass \
  || assert "S: merge_ui_test_results.py (classifier + coverage contract) has no dispatch primitive" fail
_new_fns="$(awk '/^bqa_classify_primary_results\(\)|^bqa_primary_infra_scan\(\)|^replay_lane_merge_results\(\)/{p=1} p{print} p&&/^}/{p=0}' "$RL")"
[[ -n "$_new_fns" ]] && ! grep -qE 'claude|agent_invocation|_interactive_invoke|run_browser_qa' <<<"$_new_fns" \
  && assert "S: the classifier/scan/merge helpers in replay-lane.sh call no agent" pass \
  || assert "S: the classifier/scan/merge helpers in replay-lane.sh call no agent" fail
[[ "$(grep -c 'run_browser_qa_llm "' "$ENGINE_ROOT/scripts/automation/goal-iter-lean.sh")" == "2" ]] \
  && assert "S: goal-iter-lean.sh still has exactly 2 browser-qa dispatch sites (canary probe + main lane)" pass \
  || assert "S: goal-iter-lean.sh browser-qa dispatch sites changed ($(grep -c 'run_browser_qa_llm "' "$ENGINE_ROOT/scripts/automation/goal-iter-lean.sh"))" fail

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
