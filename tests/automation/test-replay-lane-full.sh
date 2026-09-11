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
#   T1-T5. FULL-depth TARGET attribution (two targets J-04 J-13, replay covers
#      J-01). Full-depth test-plan rows are generic (UT-01, UT-02 …), so the
#      merged headline may never infer target coverage from "some UT-XX row
#      passed": every target owes a machine-attributable UT-J-NN row.
#      T1 one target PASS + the other with NO attributable row → SKIPPED, J-13
#         MISSING, no infra token, replay rows intact, one dispatch (this is
#         the counterexample that FAILED on 5675f3a: the lane floor let a single
#         generic UT-01 PASS read as "all targets verified" → PASS).
#      T2 J-04 PASS + J-13 Chrome-SKIP → SKIPPED, token exactly J-13.
#      T3 both PASS → PASS, no token.  T4 J-04 FAIL + J-13 infra → FAIL,
#      token J-13, the FAIL row survives.  T5 generic rows only (UT-01 PASS,
#      UT-02 infra-SKIP, no target rows) → SKIPPED, both targets MISSING, no
#      fabricated token (fail closed, never PASS).
#   N1-N5. FULL depth WITHOUT an active replay lane (Required-still-passing:
#      none, no goldens → _use_replay=no, the LLM lane writes ui-test-results.md
#      directly, no merge). Fresh-evidence coverage is a Goal Mode browser-
#      result invariant, not a replay feature, so the same contract must
#      finalize that artifact: N1 J-04 PASS + J-13 absent → SKIPPED, J-13
#      MISSING, no token (FAILED on 913604b: the agent's own PASS headline
#      stood because the finalizer only ran inside the replay merge); N2 PASS +
#      infra → SKIPPED, token J-13; N3 both PASS → PASS; N4 FAIL + infra → FAIL,
#      token J-13 (FAILED on 913604b: the agent's PASS headline stood over a
#      FAIL row); N5 CHAIN_REGRESSION_REPLAY=false with a golden on file → the
#      hatch disables replay (verify never invoked) but not coverage → SKIPPED.
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
make_sandbox() {  # make_sandbox <tag> <phase> [<targets line>] [<required line>]
  local tag="$1" phase="$2" targets="${3:-J-02}" required="${4:-J-01, J-02}"
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
- J-04: compute a total. Acceptance: total appears.
- J-13: run the sweep. Acceptance: sweep summary appears.
## Anti-goals
- none
EOF
  cat > "$SBX/docs/phases/$PHASE.md" <<EOF
# Full-depth spec (replay-lane-full wiring test)
## Goal Mode Metadata
- **Mode:** next
- **Depth:** full
- **Target journeys:** $targets
- **Required-still-passing journeys:** $required
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
  # STUB_BQA_PLAN_INFRA=1: a second GENERIC test-plan row that hit browser infra.
  if [[ "${STUB_BQA_PLAN_INFRA:-}" == "1" ]]; then
    printf '| UT-02 | add an item | happy-path | P1 | item appears | %s | SKIP | none |\n' "$infra"
  fi
  # STUB_BQA_TARGET_ROWS="J-04=PASS J-13=INFRA": the target-attributed UT-J-NN
  # rows (PASS | FAIL | INFRA); a target absent from the list gets NO row.
  for kv in ${STUB_BQA_TARGET_ROWS:-}; do
    tj="${kv%%=*}"; tv="${kv#*=}"
    case "$tv" in
      INFRA) printf '| UT-%s | target %s | journey | P1 | acceptance | %s | SKIP | none |\n' "$tj" "$tj" "$infra" ;;
      FAIL)  printf '| UT-%s | target %s | journey | P1 | acceptance | total wrong | FAIL | reports/qa/x.png |\n' "$tj" "$tj" ;;
      *)     printf '| UT-%s | target %s | journey | P1 | acceptance | verified | PASS | reports/qa/x.png |\n' "$tj" "$tj" ;;
    esac
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

# ══ T1-T5: FULL-depth TARGET attribution (two targets, generic plan rows) ═════
# Spec: Target journeys J-04, J-13; Required-still-passing J-01 (golden on
# file → replay covers it). The only fresh evidence for the targets is the
# primary dispatch; its test-plan rows are generic (UT-01 …), so each target
# owes its own UT-J-NN row.
export CHAIN_BQA_PREFLIGHT=true GOAL_SESSION_DIR="" GOAL_ITER_INDEX=""
classify_of() { python3 "$ENGINE_ROOT/scripts/automation/lib/merge_ui_test_results.py" classify "$1" J-04 J-13 | awk -F'\t' '{printf "%s:%s ", $1, $2}'; }
run_target_case() {  # <tag> <iter> <STUB_BQA_TARGET_ROWS> [<STUB_BQA_PLAN_INFRA>]
  make_sandbox "$1" "goal-rlf-iter-$2" "J-04, J-13" "J-01"
  golden rlf "J-01"
  export GOAL_SESSION_DIR="$SBX/runs/goal-session-rlf" GOAL_ITER_INDEX="$2" STUB_CALLS="$WORK/calls-$1"
  export STUB_BQA_TARGET_ROWS="$3" STUB_BQA_PLAN_INFRA="${4:-}"
  : > "$STUB_CALLS"
  run_bqa "$WORK/log-$1.txt" "$1"
  TOKEN="$GOAL_SESSION_DIR/iter-$2/browser-infra.json"
  unset STUB_BQA_TARGET_ROWS STUB_BQA_PLAN_INFRA
}

# T1 (F1): J-04 fresh PASS, J-13 has NO attributable row (only a generic UT-01 PASS).
run_target_case T1 11 "J-04=PASS"
[[ "$BQA_RC" -eq 0 ]] && assert "T1: exits 0" pass || { assert "T1: exits 0 (rc=$BQA_RC)" fail; sed -n '1,40p' "$WORK/log-T1.txt"; }
grep -q '^\*\*Browser QA Verdict:\*\* SKIPPED' "$UI_TEST_RESULTS" 2>/dev/null \
  && assert "T1: one target PASS + one target with no attributable row → merged SKIPPED (never PASS on a generic UT-01 PASS)" pass \
  || { assert "T1: one target PASS + one target with no attributable row → merged SKIPPED (got: $(grep -m1 -oE 'Verdict:\*\* [A-Z]+' "$UI_TEST_RESULTS" 2>/dev/null))" fail; }
[[ "$(classify_of "$LLM_RESULTS")" == "J-04:PASS J-13:MISSING " ]] \
  && assert "T1: raw primary classifies J-04 PASS, J-13 MISSING" pass \
  || assert "T1: raw primary classifies J-04 PASS, J-13 MISSING (got: $(classify_of "$LLM_RESULTS"))" fail
grep -q 'J-13: MISSING' "$UI_TEST_RESULTS" 2>/dev/null \
  && assert "T1: the merged coverage note names J-13 as MISSING" pass \
  || assert "T1: the merged coverage note names J-13 as MISSING" fail
[[ ! -f "$TOKEN" ]] && assert "T1: no browser-infra token (a missing row is not infra evidence)" pass \
  || assert "T1: no browser-infra token (a missing row is not infra evidence; got $(token_journeys "$TOKEN"))" fail
grep -E '^\| UT-J-01 ' "$UI_TEST_RESULTS" 2>/dev/null | grep -qF '| PASS |' \
  && assert "T1: the replay PASS row (J-01) survives intact" pass || assert "T1: the replay PASS row (J-01) survives intact" fail
grep -E '^\| UT-01 ' "$UI_TEST_RESULTS" 2>/dev/null | grep -qF '| PASS |' \
  && assert "T1: the generic UT-01 test-plan row is retained" pass || assert "T1: the generic UT-01 test-plan row is retained" fail
[[ "$(wc -l < "$STUB_CALLS" | tr -dc 0-9)" == "1" ]] && assert "T1: exactly ONE browser-qa dispatch" pass || assert "T1: exactly ONE browser-qa dispatch" fail
grep -q '^- TARGET JOURNEY ATTRIBUTION.*J-04 J-13' "$WORK/prompt-T1.txt" \
  && assert "T1: the dispatch prompt requires one UT-J-NN row per target (J-04 J-13)" pass \
  || assert "T1: the dispatch prompt requires one UT-J-NN row per target (J-04 J-13)" fail
[[ ! -f "$SBX/runs/$PHASE/.steps/browser-qa.done" ]] || true

# T2 (F2): J-04 PASS + J-13 Chrome-SKIP.
run_target_case T2 12 "J-04=PASS J-13=INFRA"
grep -q '^\*\*Browser QA Verdict:\*\* SKIPPED' "$UI_TEST_RESULTS" 2>/dev/null \
  && assert "T2: J-04 PASS + J-13 infra-SKIP → merged SKIPPED" pass \
  || assert "T2: J-04 PASS + J-13 infra-SKIP → merged SKIPPED (got: $(grep -m1 -oE 'Verdict:\*\* [A-Z]+' "$UI_TEST_RESULTS" 2>/dev/null))" fail
[[ "$(token_journeys "$TOKEN")" == "J-13" ]] \
  && assert "T2: browser-infra.json journeys exactly [J-13] — J-04 is not pending-infra" pass \
  || assert "T2: browser-infra.json journeys exactly [J-13] (got: $(token_journeys "$TOKEN"))" fail
[[ "$(classify_of "$LLM_RESULTS")" == "J-04:PASS J-13:SKIP_INFRA " ]] \
  && assert "T2: raw primary classifies J-04 PASS, J-13 SKIP_INFRA" pass \
  || assert "T2: raw primary classifies J-04 PASS, J-13 SKIP_INFRA (got: $(classify_of "$LLM_RESULTS"))" fail
[[ "$(wc -l < "$STUB_CALLS" | tr -dc 0-9)" == "1" ]] && assert "T2: exactly ONE browser-qa dispatch" pass || assert "T2: exactly ONE browser-qa dispatch" fail

# T3 (F3): both targets PASS.
run_target_case T3 13 "J-04=PASS J-13=PASS"
grep -q '^\*\*Browser QA Verdict:\*\* PASS' "$UI_TEST_RESULTS" 2>/dev/null && ! grep -q 'Fresh-evidence coverage' "$UI_TEST_RESULTS" \
  && assert "T3: both targets PASS → merged PASS, no coverage note" pass \
  || assert "T3: both targets PASS → merged PASS (got: $(grep -m1 -oE 'Verdict:\*\* [A-Z]+' "$UI_TEST_RESULTS" 2>/dev/null))" fail
[[ ! -f "$TOKEN" ]] && assert "T3: no browser-infra token" pass || assert "T3: no browser-infra token" fail
[[ "$(wc -l < "$STUB_CALLS" | tr -dc 0-9)" == "1" ]] && assert "T3: exactly ONE browser-qa dispatch" pass || assert "T3: exactly ONE browser-qa dispatch" fail

# T4 (F4): J-04 FAIL + J-13 infra-SKIP.
run_target_case T4 14 "J-04=FAIL J-13=INFRA"
grep -q '^\*\*Browser QA Verdict:\*\* FAIL' "$UI_TEST_RESULTS" 2>/dev/null \
  && assert "T4: J-04 FAIL + J-13 infra → merged FAIL (a product defect dominates)" pass \
  || assert "T4: J-04 FAIL + J-13 infra → merged FAIL (got: $(grep -m1 -oE 'Verdict:\*\* [A-Z]+' "$UI_TEST_RESULTS" 2>/dev/null))" fail
grep -E '^\| UT-J-04 ' "$UI_TEST_RESULTS" 2>/dev/null | grep -qF '| FAIL |' \
  && assert "T4: the J-04 FAIL row survives unchanged" pass || assert "T4: the J-04 FAIL row survives unchanged" fail
[[ "$(token_journeys "$TOKEN")" == "J-13" ]] \
  && assert "T4: token only J-13" pass || assert "T4: token only J-13 (got: $(token_journeys "$TOKEN"))" fail

# T5: generic rows only — UT-01 PASS + UT-02 infra-SKIP, no UT-J-NN rows at all.
run_target_case T5 15 "" 1
grep -q '^\*\*Browser QA Verdict:\*\* SKIPPED' "$UI_TEST_RESULTS" 2>/dev/null \
  && assert "T5: generic rows only (one PASS, one infra-SKIP) → merged SKIPPED, never PASS" pass \
  || assert "T5: generic rows only → merged SKIPPED (got: $(grep -m1 -oE 'Verdict:\*\* [A-Z]+' "$UI_TEST_RESULTS" 2>/dev/null))" fail
[[ "$(classify_of "$LLM_RESULTS")" == "J-04:MISSING J-13:MISSING " ]] \
  && assert "T5: both targets classify MISSING (no attributable row)" pass \
  || assert "T5: both targets classify MISSING (got: $(classify_of "$LLM_RESULTS"))" fail
[[ ! -f "$TOKEN" ]] && assert "T5: no fabricated browser-infra token (the generic infra row cannot be attributed to a target)" pass \
  || assert "T5: no fabricated browser-infra token (got $(token_journeys "$TOKEN"))" fail
unset CHAIN_BQA_PREFLIGHT STUB_CALLS GOAL_SESSION_DIR GOAL_ITER_INDEX

# ══ N1-N5: FULL depth WITHOUT an active replay lane ══════════════════════════
export CHAIN_BQA_PREFLIGHT=true
headline_of() { grep -m1 -E '^\*\*Browser QA Verdict:\*\*' "$1" 2>/dev/null | grep -oE 'PASS|FAIL|SKIPPED' | head -1 || true; }
run_noreplay_case() {  # <tag> <iter> <STUB_BQA_TARGET_ROWS> [<required line>] [<golden journey>]
  make_sandbox "$1" "goal-rlf-iter-$2" "J-04, J-13" "${4:-none — no prior passing journeys}"
  [[ -n "${5:-}" ]] && golden rlf "$5"
  export GOAL_SESSION_DIR="$SBX/runs/goal-session-rlf" GOAL_ITER_INDEX="$2" STUB_CALLS="$WORK/calls-$1"
  export STUB_BQA_TARGET_ROWS="$3"
  : > "$STUB_CALLS"
  run_bqa "$WORK/log-$1.txt" "$1"
  TOKEN="$GOAL_SESSION_DIR/iter-$2/browser-infra.json"
  unset STUB_BQA_TARGET_ROWS
}

# N1: no replay, J-04 PASS + J-13 absent (only a generic UT-01 PASS beside it).
run_noreplay_case N1 21 "J-04=PASS"
[[ "$BQA_RC" -eq 0 ]] && assert "N1: exits 0" pass || { assert "N1: exits 0 (rc=$BQA_RC)" fail; sed -n '1,40p' "$WORK/log-N1.txt"; }
grep -q "^Write your results to: $UI_TEST_RESULTS\$" "$WORK/prompt-N1.txt" && [[ ! -f "$REGRESSION_RESULTS" ]] \
  && assert "N1: no replay lane engaged — the LLM lane wrote ui-test-results.md directly (no merge)" pass \
  || assert "N1: no replay lane engaged — the LLM lane wrote ui-test-results.md directly (no merge)" fail
[[ "$(headline_of "$UI_TEST_RESULTS")" == "SKIPPED" ]] \
  && assert "N1: no-replay J-04 PASS + J-13 absent → headline SKIPPED (the agent's PASS headline does not stand)" pass \
  || assert "N1: no-replay J-04 PASS + J-13 absent → headline SKIPPED (got: $(headline_of "$UI_TEST_RESULTS"))" fail
grep -q '^\*\*Fresh-evidence coverage:\*\* INCOMPLETE.*J-13: MISSING' "$UI_TEST_RESULTS" 2>/dev/null \
  && assert "N1: deterministic coverage note names J-13 MISSING" pass \
  || assert "N1: deterministic coverage note names J-13 MISSING" fail
[[ "$(classify_of "$UI_TEST_RESULTS")" == "J-04:PASS J-13:MISSING " ]] \
  && assert "N1: raw primary classifies J-04 PASS, J-13 MISSING" pass \
  || assert "N1: raw primary classifies J-04 PASS, J-13 MISSING (got: $(classify_of "$UI_TEST_RESULTS"))" fail
[[ ! -f "$TOKEN" ]] && assert "N1: no browser-infra token (a missing row is not infra)" pass || assert "N1: no browser-infra token (got $(token_journeys "$TOKEN"))" fail
grep -E '^\| UT-01 ' "$UI_TEST_RESULTS" 2>/dev/null | grep -qF '| PASS |' && grep -E '^\| UT-J-04 ' "$UI_TEST_RESULTS" 2>/dev/null | grep -qF '| PASS |' \
  && assert "N1: the agent's rows are preserved untouched (UT-01 PASS, UT-J-04 PASS)" pass \
  || assert "N1: the agent's rows are preserved untouched (UT-01 PASS, UT-J-04 PASS)" fail
[[ "$(wc -l < "$STUB_CALLS" | tr -dc 0-9)" == "1" ]] && assert "N1: exactly ONE browser-qa dispatch" pass || assert "N1: exactly ONE browser-qa dispatch" fail

# N2: no replay, J-04 PASS + J-13 Chrome-SKIP.
run_noreplay_case N2 22 "J-04=PASS J-13=INFRA"
[[ "$(headline_of "$UI_TEST_RESULTS")" == "SKIPPED" ]] \
  && assert "N2: no-replay J-04 PASS + J-13 infra → headline SKIPPED" pass \
  || assert "N2: no-replay J-04 PASS + J-13 infra → headline SKIPPED (got: $(headline_of "$UI_TEST_RESULTS"))" fail
[[ "$(token_journeys "$TOKEN")" == "J-13" ]] \
  && assert "N2: browser-infra.json journeys exactly [J-13]" pass || assert "N2: browser-infra.json journeys exactly [J-13] (got: $(token_journeys "$TOKEN"))" fail
[[ "$(wc -l < "$STUB_CALLS" | tr -dc 0-9)" == "1" ]] && assert "N2: exactly ONE browser-qa dispatch" pass || assert "N2: exactly ONE browser-qa dispatch" fail

# N3: no replay, both targets PASS.
run_noreplay_case N3 23 "J-04=PASS J-13=PASS"
[[ "$(headline_of "$UI_TEST_RESULTS")" == "PASS" ]] && ! grep -q 'Fresh-evidence coverage' "$UI_TEST_RESULTS" \
  && assert "N3: no-replay both targets PASS → headline PASS, no coverage note" pass \
  || assert "N3: no-replay both targets PASS → headline PASS (got: $(headline_of "$UI_TEST_RESULTS"))" fail
[[ ! -f "$TOKEN" ]] && assert "N3: no browser-infra token" pass || assert "N3: no browser-infra token" fail
[[ "$(wc -l < "$STUB_CALLS" | tr -dc 0-9)" == "1" ]] && assert "N3: exactly ONE browser-qa dispatch" pass || assert "N3: exactly ONE browser-qa dispatch" fail

# N4: no replay, J-04 FAIL + J-13 infra (the agent's own headline says PASS).
run_noreplay_case N4 24 "J-04=FAIL J-13=INFRA"
[[ "$(headline_of "$UI_TEST_RESULTS")" == "FAIL" ]] \
  && assert "N4: no-replay J-04 FAIL + J-13 infra → headline FAIL (a FAIL row outranks the agent's PASS headline)" pass \
  || assert "N4: no-replay J-04 FAIL + J-13 infra → headline FAIL (got: $(headline_of "$UI_TEST_RESULTS"))" fail
[[ "$(token_journeys "$TOKEN")" == "J-13" ]] && assert "N4: token only J-13" pass || assert "N4: token only J-13 (got: $(token_journeys "$TOKEN"))" fail
grep -E '^\| UT-J-04 ' "$UI_TEST_RESULTS" 2>/dev/null | grep -qF '| FAIL |' \
  && assert "N4: the J-04 FAIL row survives unchanged" pass || assert "N4: the J-04 FAIL row survives unchanged" fail

# N5: replay explicitly disabled (golden on file, CHAIN_REGRESSION_REPLAY=false).
export CHAIN_REGRESSION_REPLAY=false STUB_VERIFY_STAMP="$WORK/stamp-N5"
run_noreplay_case N5 25 "J-04=PASS" "J-01" "J-01"
unset CHAIN_REGRESSION_REPLAY STUB_VERIFY_STAMP
[[ ! -f "$WORK/stamp-N5" ]] && grep -q "^Write your results to: $UI_TEST_RESULTS\$" "$WORK/prompt-N5.txt" \
  && assert "N5: the hatch disabled replay (verify never invoked, results written directly)" pass \
  || assert "N5: the hatch disabled replay (verify never invoked, results written directly)" fail
[[ "$(headline_of "$UI_TEST_RESULTS")" == "SKIPPED" ]] && grep -q 'J-13: MISSING' "$UI_TEST_RESULTS" 2>/dev/null \
  && assert "N5: CHAIN_REGRESSION_REPLAY=false cannot bypass coverage — J-13 MISSING → SKIPPED" pass \
  || assert "N5: CHAIN_REGRESSION_REPLAY=false cannot bypass coverage (got: $(headline_of "$UI_TEST_RESULTS"))" fail
unset CHAIN_BQA_PREFLIGHT STUB_CALLS GOAL_SESSION_DIR GOAL_ITER_INDEX

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
