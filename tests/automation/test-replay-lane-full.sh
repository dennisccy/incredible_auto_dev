#!/usr/bin/env bash
# test-replay-lane-full.sh — end-to-end wiring test for the deterministic
# regression-replay lane on the FULL pipeline path (P2 fix): browser-qa-phase.sh
# must run the shared lane (lib/replay-lane.sh) for goal-session iterations and
# stay byte-identical for plain phase mode.
#
# Drives the REAL browser-qa-phase.sh in a sandbox repo (modeled on
# test-goal-parallel-bqa.sh) with a stub `claude` on PATH (captures the exact
# dispatch prompt), a stub demo_runner.py (replay lane), and dummy HTTP services
# on test ports. CHAIN_SHARED_SERVICES=true throughout — the post-dev fanout
# context this step actually runs in under run-phase.sh (and it keeps the
# sandbox's dummy services alive: the standalone path's stale-server reclaim
# would kill them).
#
# Scenarios:
#   A. PLAIN PHASE MODE (phase name `phase-1`): the lane must no-op SILENTLY —
#      no runs/goal-session-* dir created, no regression-replay artifact, no
#      goal addendum in the dispatch prompt, results written directly to
#      ui-test-results.md. (Prompt-level byte-identity vs pre-change HEAD is
#      proven once, out-of-band, in the change's verification notes; here we
#      pin the invariants that keep it true.)
#   B. GOAL ITERATION, golden on file for J-01 (J-02 none), replay PASS →
#      regression-replay-results.md written with the UT-J-01 row; prompt
#      addendum: J-01 listed as replay-verified, J-02 listed as ALSO-execute,
#      GOLDEN REPLAY SCRIPTS paragraph present, results redirected to the
#      .llm.md lane file; merged ui-test-results.md carries BOTH lanes' rows
#      with exactly one headline verdict.
#   C. REPLAY FAIL (rc 5) → J-01 routed to the LLM lane for re-confirmation
#      (prompt says so); stub LLM passes it → merged verdict PASS and the RAW
#      replay artifact gains the dated reconciliation footer (companion fix:
#      no stale FAIL survives the iteration on disk).
#   D. CHAIN_REGRESSION_REPLAY=false escape hatch → verify never invoked, the
#      WHOLE required set rides the LLM lane, results written directly to
#      ui-test-results.md (no merge).
#   E. LLM dispatch dies without writing (rc 1) → the merge still produces
#      ui-test-results.md from the replay lane's rows (not a SKIPPED stub) and
#      the script propagates rc 1.
#   F. REL-14 target-aware post-scan, the exact incident shape: replay PASSes
#      J-01, the LLM lane's raw output says Chrome never started (every row a
#      browser-infra SKIP) → browser-infra.json lists exactly the owed journey
#      (J-02), the merged headline is SKIPPED (never PASS), the replay PASS row
#      survives, exactly ONE browser-qa dispatch.
#   G. Mixed: the test-plan row PASSes, the id-keyed regression journey J-02 is
#      an infra-SKIP → token names ONLY J-02, headline SKIPPED, one dispatch.
#   H. Healthy with the knob on → merged PASS, NO token, one dispatch (the
#      healthy path's dispatch count is unchanged by the classifier).
#
# No API calls; a few seconds per scenario.
#
# shellcheck disable=SC2015,SC2034,SC2329
# (SC2015: assert's pass arm always returns 0, so `&& pass || fail` is safe;
# SC2034: the seq loop var is intentionally unused; SC2329: cleanup runs via trap.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BE_PORT=48341
FE_PORT=48342

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
  local tag="$1" phase="$2"
  SBX="$WORK/proj-$tag"
  PHASE="$phase"
  mkdir -p "$SBX"
  cp -r "$ENGINE_ROOT/scripts" "$SBX/"
  mkdir -p "$SBX/docs/phases" "$SBX/reports" "$SBX/runs/$PHASE" "$SBX/src"
  git init -q "$SBX"
  echo "print('v1')" > "$SBX/src/app.py"
  cat > "$SBX/docs/goal.md" <<'EOF'
# Goal
## Must-have user journeys
- J-01: open the page. Acceptance: page loads.
- J-02: add an item. Acceptance: item appears.
## Anti-goals
- none
EOF
  cat > "$SBX/docs/phases/$PHASE.md" <<'EOF'
# Full-depth spec (replay-lane-full wiring test)
## Goal Mode Metadata
- **Mode:** next
- **Depth:** full
- **Target journeys:** J-02
- **Required-still-passing journeys:** J-01, J-02
## IN SCOPE
- exercise browser-qa (wiring test)
EOF
  cat > "$SBX/runs/$PHASE/plan.md" <<'EOF'
# Plan
Frontend Present: yes
EOF
  cat > "$SBX/reports/phase-$PHASE-ui-test-plan.md" <<'EOF'
# UI test plan
| UT-01 | open the page | smoke | P1 |
EOF
  cat > "$SBX/reports/phase-$PHASE-ui-surface-map.md" <<'EOF'
# Surface map
- / (home)
EOF
  git -C "$SBX" add -A
  git -C "$SBX" -c user.email=t@t -c user.name=t commit -qm base

  UI_TEST_RESULTS="$SBX/reports/phase-${PHASE}-ui-test-results.md"
  LLM_RESULTS="$SBX/reports/phase-${PHASE}-ui-test-results.llm.md"
  REGRESSION_RESULTS="$SBX/reports/phase-${PHASE}-regression-replay-results.md"

  # Stub demo_runner (replay lane): lint says every golden is ok; verify writes
  # production-shaped rows per STUB_REPLAY_VERDICT, exits STUB_REPLAY_RC (or the
  # real contract: 0 PASS / 5 FAIL), and stamps STUB_VERIFY_STAMP when set.
  cat > "$SBX/scripts/automation/lib/demo_runner.py" <<'PYEOF'
#!/usr/bin/env python3
import os, sys

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
    stamp = os.environ.get("STUB_VERIFY_STAMP", "")
    if stamp:
        with open(stamp, "w") as f:
            f.write(" ".join(journeys))
    verdict = os.environ.get("STUB_REPLAY_VERDICT", "PASS")
    rc = os.environ.get("STUB_REPLAY_RC", "")
    results = arg("--results")
    if results and rc != "6":
        rows = "\n".join(
            f"| UT-{j} | replay {j} | regression | P1 | replays clean | stub {verdict.lower()} | {verdict} | none |"
            for j in journeys)
        with open(results, "w") as f:
            f.write("**Browser QA Verdict:** " + ("PASS" if verdict == "PASS" else "FAIL") + "\n\n"
                    "| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n"
                    "|---|---|---|---|---|---|---|---|\n" + rows + "\n")
    if rc:
        sys.exit(int(rc))
    sys.exit(5 if verdict == "FAIL" else 0)

sys.exit(0)
PYEOF
}

golden() {  # $1 = session id, $2 = journey id
  mkdir -p "$SBX/runs/goal-session-$1/journey-scripts"
  echo '{"journey":"'"$2"'","steps":[]}' > "$SBX/runs/goal-session-$1/journey-scripts/$2.json"
}

# ── Stub claude: captures the exact prompt; answers the test plan + any goal
# addendum journeys with PASS rows (or dies with STUB_BQA_RC before writing).
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<'EOF'
#!/usr/bin/env bash
prompt="$*"
printf '%s\n' "$prompt" > "$PROMPT_OUT"
[[ -n "${STUB_CALLS:-}" ]] && echo 1 >> "$STUB_CALLS"
if [[ -n "${STUB_BQA_RC:-}" ]]; then exit "$STUB_BQA_RC"; fi
out="$(printf '%s\n' "$prompt" | sed -n 's/^Write your results to: //p' | head -n1)"
[[ -n "$out" ]] || exit 64
also="$(printf '%s\n' "$prompt" | sed -n 's/^- ALSO execute these regression journeys this run: //p' | head -n1)"
# Only the journey-set portion (before ". For each:") — the instruction text
# that follows carries the literal example "UT-J-01", which is not a journey
# this run was asked to execute (scenario B makes the same cut).
also="${also%%. For each*}"
journeys="$(printf '%s\n' "$also" | grep -oE 'J-[0-9]+' | sort -u | tr '\n' ' ' || true)"
# STUB_BQA_INFRA: "" = every row PASS; "regr" = the id-keyed regression rows are
# browser-infra SKIPs; "all" = the test-plan row too (Chrome never started).
infra="browser infrastructure failure: Chrome did not become ready on port 9222 within 15000ms"
mode="${STUB_BQA_INFRA:-}"
{
  if [[ "$mode" == "all" ]]; then printf '**Browser QA Verdict:** SKIPPED\n\n'; else printf '**Browser QA Verdict:** PASS\n\n'; fi
  printf '| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n'
  printf '|---|---|---|---|---|---|---|---|\n'
  if [[ "$mode" == "all" ]]; then
    printf '| UT-01 | open the page | smoke | P1 | loads | %s | SKIP | none |\n' "$infra"
  else
    printf '| UT-01 | open the page | smoke | P1 | loads | stub verified | PASS | none |\n'
  fi
  for j in $journeys; do
    if [[ -n "$mode" ]]; then
      printf '| UT-%s | llm %s | regression | P1 | works | %s | SKIP | none |\n' "$j" "$j" "$infra"
    else
      printf '| UT-%s | llm %s | regression | P1 | works | stub re-verified | PASS | none |\n' "$j" "$j"
    fi
  done
} > "$out"
exit 0
EOF
chmod +x "$STUB_DIR/claude"

# ── Dummy services on the test ports ─────────────────────────────────────────
SRV_DIR="$WORK/srv"
mkdir -p "$SRV_DIR"
start_dummies() {
  local p
  for p in "$BE_PORT" "$FE_PORT"; do
    if ! curl -s -o /dev/null "http://localhost:${p}/"; then
      ( cd "$SRV_DIR" && exec python3 -m http.server "$p" ) >/dev/null 2>&1 &
      DUMMY_PIDS+=("$!")
    fi
  done
  for p in "$BE_PORT" "$FE_PORT"; do
    local i
    for i in $(seq 1 50); do
      curl -s -o /dev/null "http://localhost:${p}/" && break
      sleep 0.1
    done
  done
}

export CHAIN_BACKEND_PORT="$BE_PORT"
export CHAIN_FRONTEND_PORT="$FE_PORT"
# Health URL must answer 2xx on the dummy (it has no /health route).
export CHAIN_BACKEND_HEALTH_URL="http://localhost:${BE_PORT}/"
export CHAIN_SHARED_SERVICES=true

run_bqa() {  # stdout+stderr → $1; rc in global BQA_RC
  local log="$1"
  start_dummies
  PROMPT_OUT="$WORK/prompt-$2.txt"
  export PROMPT_OUT
  BQA_RC=0
  ( cd "$SBX" && PATH="$STUB_DIR:$PATH" bash scripts/automation/browser-qa-phase.sh "$PHASE" ) >"$log" 2>&1 || BQA_RC=$?
}

echo "=== test-replay-lane-full.sh ==="

# ══ Scenario A: plain phase mode — the lane must no-op silently ═══════════════
make_sandbox A "phase-1"
run_bqa "$WORK/log-A.txt" A
[[ "$BQA_RC" -eq 0 ]] && assert "A: phase-mode browser-qa exits 0" pass \
  || { assert "A: phase-mode browser-qa exits 0 (rc=$BQA_RC)" fail; sed -n '1,30p' "$WORK/log-A.txt"; }
if compgen -G "$SBX/runs/goal-session-*" >/dev/null; then
  assert "A: no goal-session dir created in phase mode" fail
else
  assert "A: no goal-session dir created in phase mode" pass
fi
[[ ! -f "$REGRESSION_RESULTS" ]] && assert "A: no regression-replay artifact in phase mode" pass \
  || assert "A: no regression-replay artifact in phase mode" fail
grep -q "GOAL-MODE REGRESSION" "$WORK/prompt-A.txt" \
  && assert "A: no goal addendum in the phase-mode prompt" fail \
  || assert "A: no goal addendum in the phase-mode prompt" pass
grep -q "^Write your results to: $UI_TEST_RESULTS\$" "$WORK/prompt-A.txt" \
  && assert "A: results path is ui-test-results.md (no .llm.md lane)" pass \
  || assert "A: results path is ui-test-results.md (no .llm.md lane)" fail
grep -q '| UT-01 ' "$UI_TEST_RESULTS" 2>/dev/null \
  && assert "A: test-plan results written" pass \
  || assert "A: test-plan results written" fail

# ══ Scenario B: goal iteration — replay + LLM lanes, merged results ═══════════
make_sandbox B "goal-rlf-iter-3"
golden rlf "J-01"
export STUB_VERIFY_STAMP="$WORK/stamp-B"
run_bqa "$WORK/log-B.txt" B
unset STUB_VERIFY_STAMP
[[ "$BQA_RC" -eq 0 ]] && assert "B: goal-iteration browser-qa exits 0" pass \
  || { assert "B: goal-iteration browser-qa exits 0 (rc=$BQA_RC)" fail; sed -n '1,40p' "$WORK/log-B.txt"; }
[[ "$(cat "$WORK/stamp-B" 2>/dev/null)" == "J-01" ]] \
  && assert "B: deterministic replay ran over exactly the golden set" pass \
  || assert "B: deterministic replay ran over exactly the golden set" fail
grep -q '^| UT-J-01 ' "$REGRESSION_RESULTS" 2>/dev/null \
  && assert "B: regression-replay-results.md written with the UT-J row" pass \
  || assert "B: regression-replay-results.md written with the UT-J row" fail
grep -q '^- Deterministic replay has ALREADY re-verified.*J-01' "$WORK/prompt-B.txt" \
  && assert "B: prompt names the replay-verified set (J-01)" pass \
  || assert "B: prompt names the replay-verified set (J-01)" fail
# Only the journey-set portion (before ". For each:") — the instruction text
# that follows legitimately contains the literal example "UT-J-01".
also_set="$(grep '^- ALSO execute these regression journeys this run:' "$WORK/prompt-B.txt" | sed 's/\. For each.*//' || true)"
[[ "$also_set" == *"J-02"* && "$also_set" != *"J-01"* ]] \
  && assert "B: no-golden journey (J-02) routed to the LLM lane, replay-verified (J-01) excluded" pass \
  || { assert "B: no-golden journey (J-02) routed to the LLM lane, replay-verified (J-01) excluded" fail; echo "    got: $also_set"; }
grep -q 'GOLDEN REPLAY SCRIPTS' "$WORK/prompt-B.txt" \
  && assert "B: golden-script authoring paragraph present (full path writes goldens now)" pass \
  || assert "B: golden-script authoring paragraph present (full path writes goldens now)" fail
grep -q "^Write your results to: $LLM_RESULTS\$" "$WORK/prompt-B.txt" \
  && assert "B: LLM lane redirected to the .llm.md lane file" pass \
  || assert "B: LLM lane redirected to the .llm.md lane file" fail
grep -q '^| UT-J-01 ' "$UI_TEST_RESULTS" 2>/dev/null && grep -q '^| UT-J-02 ' "$UI_TEST_RESULTS" 2>/dev/null \
  && assert "B: merged results carry BOTH lanes' journey rows" pass \
  || assert "B: merged results carry BOTH lanes' journey rows" fail
[[ "$(grep -c '\*\*Browser QA Verdict:\*\*' "$UI_TEST_RESULTS" 2>/dev/null)" == "1" ]] \
  && assert "B: exactly one headline verdict in the merged file" pass \
  || assert "B: exactly one headline verdict in the merged file" fail

# ══ Scenario C: replay FAIL → LLM re-confirm + reconciliation footer ══════════
make_sandbox C "goal-rlf-iter-4"
golden rlf "J-01"
export STUB_REPLAY_VERDICT=FAIL
run_bqa "$WORK/log-C.txt" C
unset STUB_REPLAY_VERDICT
also_line="$(grep '^- ALSO execute these regression journeys this run:' "$WORK/prompt-C.txt" || true)"
[[ "$also_line" == *"J-01"* ]] \
  && assert "C: replay-FAILed journey routed to the LLM lane for re-confirmation" pass \
  || { assert "C: replay-FAILed journey routed to the LLM lane for re-confirmation" fail; echo "    got: $also_line"; }
grep -q 'flagged possible regression' "$WORK/prompt-C.txt" \
  && assert "C: prompt carries the re-confirmation instruction" pass \
  || assert "C: prompt carries the re-confirmation instruction" fail
grep -E '^\| UT-J-01 ' "$UI_TEST_RESULTS" 2>/dev/null | grep -qF '| PASS |' \
  && grep -q '^\*\*Browser QA Verdict:\*\* PASS' "$UI_TEST_RESULTS" 2>/dev/null \
  && assert "C: LLM re-confirm overrides the replay FAIL in the merged file" pass \
  || assert "C: LLM re-confirm overrides the replay FAIL in the merged file" fail
grep -q 'Reconciliation' "$REGRESSION_RESULTS" 2>/dev/null \
  && assert "C: raw replay artifact reconciled (footer; no stale FAIL survives)" pass \
  || assert "C: raw replay artifact reconciled (footer; no stale FAIL survives)" fail

# ══ Scenario D: escape hatch — whole required set to the LLM lane ═════════════
make_sandbox D "goal-rlf-iter-5"
golden rlf "J-01"
export CHAIN_REGRESSION_REPLAY=false
export STUB_VERIFY_STAMP="$WORK/stamp-D"
run_bqa "$WORK/log-D.txt" D
unset CHAIN_REGRESSION_REPLAY STUB_VERIFY_STAMP
[[ ! -f "$WORK/stamp-D" ]] && assert "D: hatch off — deterministic verify never invoked" pass \
  || assert "D: hatch off — deterministic verify never invoked" fail
also_line="$(grep '^- ALSO execute these regression journeys this run:' "$WORK/prompt-D.txt" || true)"
[[ "$also_line" == *"J-01"* && "$also_line" == *"J-02"* ]] \
  && assert "D: hatch off — WHOLE required set rides the LLM lane" pass \
  || { assert "D: hatch off — WHOLE required set rides the LLM lane" fail; echo "    got: $also_line"; }
grep -q "^Write your results to: $UI_TEST_RESULTS\$" "$WORK/prompt-D.txt" \
  && assert "D: hatch off — results written directly (no merge lane)" pass \
  || assert "D: hatch off — results written directly (no merge lane)" fail

# ══ Scenario E: LLM dispatch dies — replay rows still land, rc propagates ═════
make_sandbox E "goal-rlf-iter-6"
golden rlf "J-01"
export STUB_BQA_RC=1
run_bqa "$WORK/log-E.txt" E
unset STUB_BQA_RC
[[ "$BQA_RC" -eq 1 ]] && assert "E: LLM-lane failure rc propagated (1)" pass \
  || assert "E: LLM-lane failure rc propagated (got $BQA_RC)" fail
grep -q '^| UT-J-01 ' "$UI_TEST_RESULTS" 2>/dev/null \
  && assert "E: merged results still carry the replay lane's rows (not a stub)" pass \
  || assert "E: merged results still carry the replay lane's rows (not a stub)" fail

# ══ Scenario F: REL-14 target-aware post-scan — the exact incident shape ═════
# Owed set = targets (J-02) ∪ the id-keyed regression journeys the LLM lane
# runs (J-02; J-01 is replay-verified). Chrome never starts for the LLM lane.
token_journeys() { python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["journeys"]))' "$1" 2>/dev/null || echo "(no token)"; }
make_sandbox F "goal-rlf-iter-7"
golden rlf "J-01"
export GOAL_SESSION_DIR="$SBX/runs/goal-session-rlf" GOAL_ITER_INDEX=7
export CHAIN_BQA_PREFLIGHT=true STUB_BQA_INFRA=all STUB_CALLS="$WORK/calls-F"
: > "$STUB_CALLS"
run_bqa "$WORK/log-F.txt" F
TOKEN_F="$GOAL_SESSION_DIR/iter-7/browser-infra.json"
[[ "$BQA_RC" -eq 0 ]] && assert "F: incident iteration exits 0 (infra is not a product failure)" pass \
  || { assert "F: incident iteration exits 0 (rc=$BQA_RC)" fail; sed -n '1,40p' "$WORK/log-F.txt"; }
[[ "$(token_journeys "$TOKEN_F")" == "J-02" ]] \
  && assert "F: browser-infra.json lists exactly the owed journey the LLM lane never reached (J-02)" pass \
  || assert "F: browser-infra.json lists exactly the owed journey (got: $(token_journeys "$TOKEN_F"))" fail
grep -q '"detected_by": "postscan"' "$TOKEN_F" 2>/dev/null \
  && assert "F: token detected_by=postscan" pass || assert "F: token detected_by=postscan" fail
grep -q '^\*\*Browser QA Verdict:\*\* SKIPPED' "$UI_TEST_RESULTS" 2>/dev/null \
  && assert "F: merged headline is SKIPPED — the replay PASS cannot satisfy the LLM lane's obligation" pass \
  || { assert "F: merged headline is SKIPPED — the replay PASS cannot satisfy the LLM lane's obligation" fail; head -12 "$UI_TEST_RESULTS" 2>/dev/null | sed 's/^/        /'; }
grep -E '^\| UT-J-01 ' "$UI_TEST_RESULTS" 2>/dev/null | grep -qF '| PASS |' \
  && assert "F: the replay PASS row (J-01) survives intact" pass \
  || { assert "F: the replay PASS row (J-01) survives intact" fail; sed -n '1,20p' "$UI_TEST_RESULTS" 2>/dev/null | sed 's/^/        /'; grep -i 'replay\|merge\|lane' "$WORK/log-F.txt" | sed 's/^/        LOG: /' | head -20; }
! grep -qF '| FAIL |' "$UI_TEST_RESULTS" 2>/dev/null \
  && assert "F: no journey marked FAIL because of infra" pass \
  || assert "F: no journey marked FAIL because of infra" fail
[[ "$(wc -l < "$STUB_CALLS" | tr -dc 0-9)" == "1" ]] \
  && assert "F: exactly ONE browser-qa dispatch (no retry, no second agent)" pass \
  || assert "F: exactly ONE browser-qa dispatch (got $(wc -l < "$STUB_CALLS" | tr -dc 0-9))" fail

# ══ Scenario G: mixed — plan row PASS, regression journey infra-SKIP ══════════
make_sandbox G "goal-rlf-iter-8"
golden rlf "J-01"
export GOAL_ITER_INDEX=8 STUB_BQA_INFRA=regr STUB_CALLS="$WORK/calls-G"
: > "$STUB_CALLS"
run_bqa "$WORK/log-G.txt" G
TOKEN_G="$GOAL_SESSION_DIR/iter-8/browser-infra.json"
[[ "$(token_journeys "$TOKEN_G")" == "J-02" ]] \
  && assert "G: token names ONLY the infra-blocked journey (J-02); the passing plan row is not tokenized" pass \
  || assert "G: token names ONLY the infra-blocked journey (got: $(token_journeys "$TOKEN_G"))" fail
grep -q '^\*\*Browser QA Verdict:\*\* SKIPPED' "$UI_TEST_RESULTS" 2>/dev/null \
  && assert "G: merged headline SKIPPED while an owed regression journey is infra-blocked" pass \
  || assert "G: merged headline SKIPPED while an owed regression journey is infra-blocked" fail
grep -E '^\| UT-01 ' "$UI_TEST_RESULTS" 2>/dev/null | grep -qF '| PASS |' \
  && assert "G: the fresh plan-row PASS is recorded" pass || assert "G: the fresh plan-row PASS is recorded" fail
[[ "$(wc -l < "$STUB_CALLS" | tr -dc 0-9)" == "1" ]] \
  && assert "G: exactly ONE browser-qa dispatch" pass || assert "G: exactly ONE browser-qa dispatch" fail

# ══ Scenario H: healthy with the knob on — PASS, no token, one dispatch ═══════
make_sandbox H "goal-rlf-iter-9"
golden rlf "J-01"
export GOAL_ITER_INDEX=9 STUB_CALLS="$WORK/calls-H"
unset STUB_BQA_INFRA
: > "$STUB_CALLS"
run_bqa "$WORK/log-H.txt" H
[[ ! -f "$GOAL_SESSION_DIR/iter-9/browser-infra.json" ]] \
  && assert "H: healthy run writes NO browser-infra token" pass || assert "H: healthy run writes NO browser-infra token" fail
grep -q '^\*\*Browser QA Verdict:\*\* PASS' "$UI_TEST_RESULTS" 2>/dev/null && ! grep -q 'Fresh-evidence coverage' "$UI_TEST_RESULTS" \
  && assert "H: healthy run merges PASS with no coverage note" pass || assert "H: healthy run merges PASS with no coverage note" fail
[[ "$(wc -l < "$STUB_CALLS" | tr -dc 0-9)" == "1" ]] \
  && assert "H: exactly ONE browser-qa dispatch — the healthy path's dispatch count is unchanged" pass \
  || assert "H: exactly ONE browser-qa dispatch (got $(wc -l < "$STUB_CALLS" | tr -dc 0-9))" fail
unset CHAIN_BQA_PREFLIGHT STUB_CALLS GOAL_SESSION_DIR GOAL_ITER_INDEX

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
