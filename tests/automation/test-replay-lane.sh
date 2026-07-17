#!/usr/bin/env bash
# test-replay-lane.sh — unit tests for scripts/automation/lib/replay-lane.sh,
# the ONE shared implementation of the deterministic regression-replay lane
# (P2 fix: the lane must exist at BOTH goal-mode depths — goal-iter-lean.sh and
# the FULL pipeline's browser-qa-phase.sh both source this lib; no copy-paste).
#
# Sources the real lib in a sandbox with a stub demo_runner.py (lint + verify
# knobs via STUB_* env) and the REAL merge_ui_test_results.py. Each scenario
# runs in a fresh `set -euo pipefail` subshell — the same shell discipline the
# production callers run under, so the load-bearing `|| true` guards are
# actually exercised (see the journey-less-spec death in test-goal-parallel-bqa
# scenario I).
#
# Covered:
#   1. replay_lane_spec_journeys: Target/Required parse; journey-less line
#      ("Required-still-passing journeys: none — ...") survives set -e+pipefail.
#   2. replay_lane_paths: SID derivation + all lane path globals + mkdir.
#   3. Partition: golden on file → R_REPLAY; missing → R_LLM; lint-invalid →
#      quarantined (*.json.invalid) + R_LLM.
#   4. Verify rc=0 → _use_replay=yes, REPLAY_FAILED empty, results file has the
#      UT-J row.
#   5. Verify rc=5 (journey FAIL) → REPLAY_FAILED extracted for LLM re-confirm.
#   6. Verify rc=6 TWICE (persistent browser-infra, REL-5): ONE retry after a
#      service re-check, then the lane records SKIPPED-INFRA (raw artifact
#      verdict line + footer, REPLAY_SKIPPED_INFRA=yes, greppable log lines)
#      and falls back: _use_replay=no, R_REPLAY cleared (ALL regression
#      journeys ride the LLM lane).
#   7. CHAIN_REGRESSION_REPLAY=false escape hatch → verify never invoked.
#   8. Stale-artifact hygiene: a prior run's REGRESSION_RESULTS/LLM_RESULTS are
#      removed at partition entry (a lane that does not run this iteration must
#      not leave last run's files masquerading as current output).
#   9. replay_lane_llm_regression_set: replay on → REPLAY_FAILED+R_LLM (deduped);
#      hatch off → the whole REQUIRED set.
#  10. Merge: replay FAIL overturned by LLM PASS → merged PASS + dated
#      reconciliation footer appended to the RAW replay artifact (companion 1:
#      no stale FAIL survives the iteration); un-overturned FAIL → no footer.
#  11. Merge crash → lane-file cp fallback (LLM file preferred).
#  12. REL-5 flake discipline: infra-then-success → the retry rescues the lane
#      (normal PASS path, no SKIPPED-INFRA); infra-then-FAIL → the retry's rc=5
#      feeds REPLAY_FAILED unchanged; a clean rc=5 is NEVER retried
#      (invocation-count-proven, zero service re-checks); a non-6 failure
#      (rc=3) keeps the old no-retry generic fallback; SKIPPED-INFRA journeys
#      still feed replay_lane_llm_regression_set (whole REQUIRED set).
#
# No API calls; runs in a couple of seconds.
#
# shellcheck disable=SC1090,SC1091,SC2015,SC2034,SC2329
# (SC1090/91: the lib path is computed per-sandbox; SC2034: FRONTEND_* et al are
# consumed by the sourced lib; SC2329: cleanup runs via trap; SC2015: assert's
# pass arm always returns 0, so the `&& pass || fail` idiom is safe here.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

ITER="goal-rltest-iter-2"

# ── Sandbox: engine scripts + stub demo_runner ──────────────────────────────
SBX="$WORK/proj"
mkdir -p "$SBX"
cp -r "$ENGINE_ROOT/scripts" "$SBX/"
mkdir -p "$SBX/docs/phases" "$SBX/reports"

LIB="$SBX/scripts/automation/lib/replay-lane.sh"

# Stub demo_runner.py: lint says ok unless STUB_LINT_INVALID names the journey;
# verify writes production-shaped rows per STUB_REPLAY_VERDICT and exits
# STUB_REPLAY_RC (default: 0 for PASS, 5 for FAIL — the real runner's contract),
# stamping STUB_VERIFY_STAMP so tests can prove it did / did not run.
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
    bad = os.environ.get("STUB_LINT_INVALID", "").split()
    for j in journeys:
        if j in bad:
            print(f"{j} invalid: step 1 has no action")
        else:
            print(f"{j} ok")
    sys.exit(0)

if mode == "verify":
    stamp = os.environ.get("STUB_VERIFY_STAMP", "")
    if stamp:
        with open(stamp, "w") as f:
            f.write(" ".join(journeys))
    # REL-5 knobs: a per-invocation rc sequence driven by a counter file, so
    # retry semantics (exactly-once, rescue, never-on-5) are provable.
    attempt = 1
    cf = os.environ.get("STUB_REPLAY_COUNT_FILE", "")
    if cf:
        try:
            attempt = int(open(cf).read().strip() or "0") + 1
        except Exception:
            attempt = 1
        with open(cf, "w") as f:
            f.write(str(attempt))
    verdict = os.environ.get("STUB_REPLAY_VERDICT", "PASS")
    rc = os.environ.get("STUB_REPLAY_RC", "")
    seq = os.environ.get("STUB_REPLAY_RC_SEQ", "").split()
    if seq:
        rc = seq[min(attempt, len(seq)) - 1]
    results = arg("--results")
    if results and rc == "6":
        # Mirror the real runner: a browser-infra crash still writes the
        # results file (SKIP rows naming the infra failure) before exiting 6.
        rows = "\n".join(
            f"| UT-{j} | replay {j} | regression | P1 | replays clean | browser infrastructure failure: stub crash | SKIP | none |"
            for j in journeys)
        with open(results, "w") as f:
            f.write("**Browser QA Verdict:** SKIPPED\n\n"
                    "## Results Table\n"
                    "| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n"
                    "|---|---|---|---|---|---|---|---|\n" + rows + "\n")
    if results and rc != "6":
        rows = "\n".join(
            f"| UT-{j} | replay {j} | regression | P1 | replays clean | stub {verdict.lower()} | {verdict} | none |"
            for j in journeys)
        with open(results, "w") as f:
            f.write("**Browser QA Verdict:** " + ("PASS" if verdict == "PASS" else "FAIL") + "\n\n"
                    "## Results Table\n"
                    "| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n"
                    "|---|---|---|---|---|---|---|---|\n" + rows + "\n")
    if rc:
        sys.exit(int(rc))
    sys.exit(5 if verdict == "FAIL" else 0)
PYEOF

# Run a lane scenario in a fresh production-discipline subshell. Env knobs are
# passed via the caller's environment. Prints the outcome globals on one line.
run_partition() {  # $1 = REQUIRED_JOURNEYS value
  (
    set -euo pipefail
    # shellcheck source=/dev/null
    source "$LIB"
    REPO_ROOT="$SBX"
    REQUIRED_JOURNEYS="$1"
    FRONTEND_AVAILABLE="${FRONTEND_AVAILABLE_OVERRIDE:-yes}"
    FRONTEND_URL="http://localhost:9"
    # REL-5: the retry path re-checks services when the function exists (in
    # production common.sh provides it; this stamping stub proves call counts —
    # scenarios without STUB_SVC_STAMP also prove the lib survives its absence).
    if [[ -n "${STUB_SVC_STAMP:-}" ]]; then
      ensure_services_running() { echo recheck >> "$STUB_SVC_STAMP"; }
    fi
    replay_lane_paths "$ITER"
    if [[ -n "${RUN_PARTITION_LOG:-}" ]]; then
      replay_lane_partition_and_verify "$ITER" > "$RUN_PARTITION_LOG" 2>&1
    else
      replay_lane_partition_and_verify "$ITER" >/dev/null
    fi
    printf 'R_REPLAY=<%s>|R_LLM=<%s>|use=<%s>|failed=<%s>\n' \
      "${R_REPLAY:-}" "${R_LLM:-}" "${_use_replay:-}" "${REPLAY_FAILED:-}"
    if [[ -n "${REPLAY_SKIPPED_INFRA:-}" ]]; then
      printf 'skipinfra=<%s>\n' "$REPLAY_SKIPPED_INFRA"
    fi
  )
}

reset_goldens() {
  rm -rf "$SBX/runs" "$SBX/reports"
  mkdir -p "$SBX/reports"
}

golden() {  # $1 = journey id
  mkdir -p "$SBX/runs/goal-session-rltest/journey-scripts"
  echo '{"journey":"'"$1"'","steps":[]}' > "$SBX/runs/goal-session-rltest/journey-scripts/$1.json"
}

echo "=== test-replay-lane.sh ==="

# ── 0. Lib exists and parses ─────────────────────────────────────────────────
if [[ -f "$LIB" ]] && bash -n "$LIB" 2>/dev/null; then
  assert "lib exists and parses (bash -n)" pass
else
  assert "lib exists and parses (bash -n)" fail
  echo "  (scripts/automation/lib/replay-lane.sh missing — nothing else can pass)"
  echo ""
  echo "RESULT: $PASS passed, $((FAIL + 1)) failed"
  exit 1
fi

# ── 1. Spec journey parsing ──────────────────────────────────────────────────
SPEC="$SBX/docs/phases/$ITER.md"
cat > "$SPEC" <<'EOF'
# Goal Iteration 2

- **Target journeys:** J-01, J-03
- **Required-still-passing journeys:** J-02, J-04
EOF

out="$( (set -euo pipefail; source "$LIB"; replay_lane_spec_journeys 'Target journeys:' "$SPEC") )"
[[ "$out" == "J-01 J-03 " ]] && assert "spec_journeys: Target parse" pass || { assert "spec_journeys: Target parse (got '<$out>')" fail; }

out="$( (set -euo pipefail; source "$LIB"; replay_lane_spec_journeys 'Required-still-passing' "$SPEC") )"
[[ "$out" == "J-02 J-04 " ]] && assert "spec_journeys: Required parse" pass || { assert "spec_journeys: Required parse (got '<$out>')" fail; }

cat > "$SPEC.baseline" <<'EOF'
- **Required-still-passing journeys:** none — baseline establishes the initial state
EOF
rc=0
out="$( (set -euo pipefail; source "$LIB"; replay_lane_spec_journeys 'Required-still-passing' "$SPEC.baseline"; echo "SURVIVED") )" || rc=$?
[[ "$rc" -eq 0 && "$out" == *SURVIVED* ]] && assert "spec_journeys: journey-less line survives set -e + pipefail" pass \
  || assert "spec_journeys: journey-less line survives set -e + pipefail (rc=$rc)" fail

# ── 2. Lane paths ────────────────────────────────────────────────────────────
out="$( (
  set -euo pipefail
  source "$LIB"
  REPO_ROOT="$SBX"
  replay_lane_paths "$ITER"
  printf '%s|%s|%s|%s|%s\n' "$SID" "$JOURNEY_SCRIPTS_DIR" "$REGRESSION_RESULTS" "$LLM_RESULTS" "$EVIDENCE_DIR"
) )"
want="rltest|$SBX/runs/goal-session-rltest/journey-scripts|$SBX/reports/phase-$ITER-regression-replay-results.md|$SBX/reports/phase-$ITER-ui-test-results.llm.md|$SBX/reports/qa/$ITER-evidence"
[[ "$out" == "$want" ]] && assert "paths: SID + lane path globals" pass || { assert "paths: SID + lane path globals" fail; echo "    got:  $out"; echo "    want: $want"; }
[[ -d "$SBX/runs/goal-session-rltest/journey-scripts" ]] && assert "paths: journey-scripts dir created" pass || assert "paths: journey-scripts dir created" fail

# ── 3. Partition: golden / missing / lint-invalid ────────────────────────────
reset_goldens
golden "J-01"
golden "J-03"
out="$(STUB_LINT_INVALID="J-03" STUB_VERIFY_STAMP="$WORK/stamp3" run_partition "J-01 J-02 J-03 ")"
[[ "$out" == "R_REPLAY=<J-01 >|R_LLM=<J-02 J-03 >|use=<yes>|failed=<>" ]] \
  && assert "partition: golden→replay, missing→LLM, lint-invalid→LLM" pass \
  || { assert "partition: golden→replay, missing→LLM, lint-invalid→LLM" fail; echo "    got: $out"; }
[[ -f "$SBX/runs/goal-session-rltest/journey-scripts/J-03.json.invalid" && ! -f "$SBX/runs/goal-session-rltest/journey-scripts/J-03.json" ]] \
  && assert "partition: invalid golden quarantined (.json.invalid)" pass \
  || assert "partition: invalid golden quarantined (.json.invalid)" fail

# ── 4. Verify rc=0 (all pass) ────────────────────────────────────────────────
[[ -f "$SBX/reports/phase-$ITER-regression-replay-results.md" ]] \
  && grep -q '^| UT-J-01 ' "$SBX/reports/phase-$ITER-regression-replay-results.md" \
  && assert "verify rc=0: regression results file written with UT-J row" pass \
  || assert "verify rc=0: regression results file written with UT-J row" fail
[[ "$(cat "$WORK/stamp3" 2>/dev/null)" == "J-01" ]] \
  && assert "verify rc=0: runner invoked with exactly the replay set" pass \
  || assert "verify rc=0: runner invoked with exactly the replay set" fail

# ── 5. Verify rc=5: FAIL rows → REPLAY_FAILED ───────────────────────────────
reset_goldens
golden "J-01"
out="$(STUB_REPLAY_VERDICT=FAIL run_partition "J-01 J-02 ")"
[[ "$out" == "R_REPLAY=<J-01 >|R_LLM=<J-02 >|use=<yes>|failed=<J-01 >" ]] \
  && assert "verify rc=5: REPLAY_FAILED extracted for LLM re-confirm" pass \
  || { assert "verify rc=5: REPLAY_FAILED extracted for LLM re-confirm" fail; echo "    got: $out"; }

# ── 6. Verify rc=6 twice (REL-5): one retry + re-check → SKIPPED-INFRA ──────
reset_goldens
golden "J-01"
rm -f "$WORK/count6"; : > "$WORK/svc6"
out="$(STUB_REPLAY_RC_SEQ='6 6' STUB_REPLAY_COUNT_FILE="$WORK/count6" \
       STUB_SVC_STAMP="$WORK/svc6" RUN_PARTITION_LOG="$WORK/lane6.log" \
       run_partition "J-01 J-02 ")"
want="R_REPLAY=<>|R_LLM=<J-02 >|use=<no>|failed=<>
skipinfra=<yes>"
[[ "$out" == "$want" ]] \
  && assert "verify rc=6 twice: fallback + REPLAY_SKIPPED_INFRA=yes" pass \
  || { assert "verify rc=6 twice: fallback + REPLAY_SKIPPED_INFRA=yes" fail; echo "    got: $out"; }
[[ "$(cat "$WORK/count6" 2>/dev/null)" == "2" ]] \
  && assert "verify rc=6 twice: exactly ONE retry (2 verify invocations)" pass \
  || assert "verify rc=6 twice: exactly ONE retry (got $(cat "$WORK/count6" 2>/dev/null) invocations)" fail
[[ "$(grep -c recheck "$WORK/svc6" 2>/dev/null)" == "1" ]] \
  && assert "verify rc=6 twice: exactly one ensure_services_running re-check" pass \
  || assert "verify rc=6 twice: exactly one ensure_services_running re-check (got $(grep -c recheck "$WORK/svc6" 2>/dev/null))" fail
grep -q "browser-infra failure (rc=6) — re-checking services and retrying the replay once" "$WORK/lane6.log" \
  && assert "verify rc=6 twice: greppable retry log line" pass \
  || assert "verify rc=6 twice: greppable retry log line" fail
grep -q "SKIPPED-INFRA — browser-infra failure persisted after one retry" "$WORK/lane6.log" \
  && assert "verify rc=6 twice: greppable SKIPPED-INFRA verdict log line" pass \
  || assert "verify rc=6 twice: greppable SKIPPED-INFRA verdict log line" fail
REG6="$SBX/reports/phase-$ITER-regression-replay-results.md"
grep -q '^\*\*Browser QA Verdict:\*\* SKIPPED-INFRA$' "$REG6" \
  && assert "verify rc=6 twice: raw artifact verdict line is exactly SKIPPED-INFRA" pass \
  || { assert "verify rc=6 twice: raw artifact verdict line is exactly SKIPPED-INFRA" fail; head -3 "$REG6" 2>/dev/null | sed 's/^/        /'; }
grep -q 'routed to the LLM lane' "$REG6" \
  && assert "verify rc=6 twice: raw artifact footer explains the routing" pass \
  || assert "verify rc=6 twice: raw artifact footer explains the routing" fail

# ── 7. Escape hatch ──────────────────────────────────────────────────────────
reset_goldens
golden "J-01"
rm -f "$WORK/stamp7"
out="$(CHAIN_REGRESSION_REPLAY=false STUB_VERIFY_STAMP="$WORK/stamp7" run_partition "J-01 ")"
[[ "$out" == "R_REPLAY=<J-01 >|R_LLM=<>|use=<no>|failed=<>" && ! -f "$WORK/stamp7" ]] \
  && assert "hatch: CHAIN_REGRESSION_REPLAY=false — verify never invoked" pass \
  || { assert "hatch: CHAIN_REGRESSION_REPLAY=false — verify never invoked" fail; echo "    got: $out"; }

# ── 8. Stale-artifact hygiene at partition entry ─────────────────────────────
reset_goldens
echo "stale replay" > "$SBX/reports/phase-$ITER-regression-replay-results.md"
echo "stale llm"    > "$SBX/reports/phase-$ITER-ui-test-results.llm.md"
out="$(run_partition "J-02 ")"   # no goldens → verify never runs → files must STILL be gone
if [[ ! -f "$SBX/reports/phase-$ITER-regression-replay-results.md" && ! -f "$SBX/reports/phase-$ITER-ui-test-results.llm.md" ]]; then
  assert "hygiene: stale lane artifacts removed at partition entry" pass
else
  assert "hygiene: stale lane artifacts removed at partition entry" fail
fi

# ── 9. LLM regression set ────────────────────────────────────────────────────
out="$( (
  set -euo pipefail
  source "$LIB"
  _use_replay=yes REPLAY_FAILED="J-05 " R_LLM="J-02 J-05 " REQUIRED_JOURNEYS="J-01 J-02 J-05 "
  replay_lane_llm_regression_set
) )"
[[ "$out" == "J-02 J-05 " ]] && assert "llm_regression_set: replay on → REPLAY_FAILED+R_LLM deduped" pass \
  || { assert "llm_regression_set: replay on → REPLAY_FAILED+R_LLM deduped" fail; echo "    got: <$out>"; }

out="$( (
  set -euo pipefail
  source "$LIB"
  _use_replay=no REPLAY_FAILED="" R_LLM="" REQUIRED_JOURNEYS="J-01 J-02 "
  replay_lane_llm_regression_set
) )"
[[ "$out" == "J-01 J-02 " ]] && assert "llm_regression_set: hatch off → whole REQUIRED set" pass \
  || { assert "llm_regression_set: hatch off → whole REQUIRED set" fail; echo "    got: <$out>"; }

# ── 10. Merge + reconciliation footer (companion 1) ──────────────────────────
merge_case() {  # $1 = llm rows file content;  seeds replay file with J-06 PASS + J-07 FAIL
  reset_goldens
  REG="$SBX/reports/phase-$ITER-regression-replay-results.md"
  LLM="$SBX/reports/phase-$ITER-ui-test-results.llm.md"
  MERGED="$SBX/reports/phase-$ITER-ui-test-results.md"
  rm -f "$MERGED"
  cat > "$REG" <<'EOF'
**Browser QA Verdict:** FAIL

## Results Table
| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |
|---|---|---|---|---|---|---|---|
| UT-J-06 | view dashboard | regression | P1 | e | ok | PASS | none |
| UT-J-07 | filter table | regression | P1 | e | step 3 failed | FAIL | none |
EOF
  printf '%s\n' "$1" > "$LLM"
  (
    set -euo pipefail
    source "$LIB"
    REPO_ROOT="$SBX"
    replay_lane_paths "$ITER"
    _use_replay=yes
    replay_lane_merge_results "$MERGED" "$LLM"
  )
}

merge_case '**Browser QA Verdict:** PASS

## Results Table
| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |
|---|---|---|---|---|---|---|---|
| UT-J-07 | filter table | regression | P1 | e | re-confirmed by LLM | PASS | none |'
grep -q '^\*\*Browser QA Verdict:\*\* PASS' "$SBX/reports/phase-$ITER-ui-test-results.md" \
  && grep -E '^\| UT-J-07 ' "$SBX/reports/phase-$ITER-ui-test-results.md" | grep -qF '| PASS |' \
  && assert "merge: LLM re-confirm overrides replay FAIL (merged PASS)" pass \
  || assert "merge: LLM re-confirm overrides replay FAIL (merged PASS)" fail
grep -q 'Reconciliation' "$SBX/reports/phase-$ITER-regression-replay-results.md" \
  && grep -q 'J-07' <(grep 'Reconciliation' "$SBX/reports/phase-$ITER-regression-replay-results.md") \
  && assert "merge: reconciliation footer names the overturned journey (companion 1)" pass \
  || assert "merge: reconciliation footer names the overturned journey (companion 1)" fail

merge_case '**Browser QA Verdict:** PASS

## Results Table
| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |
|---|---|---|---|---|---|---|---|
| UT-J-20 | new feature | smoke | P1 | e | ok | PASS | none |'
grep -q '^\*\*Browser QA Verdict:\*\* FAIL' "$SBX/reports/phase-$ITER-ui-test-results.md" \
  && assert "merge: un-overturned replay FAIL survives (merged FAIL)" pass \
  || assert "merge: un-overturned replay FAIL survives (merged FAIL)" fail
grep -q 'Reconciliation' "$SBX/reports/phase-$ITER-regression-replay-results.md" \
  && assert "merge: no footer when nothing was overturned" fail \
  || assert "merge: no footer when nothing was overturned" pass

# ── 11. Merge crash → lane-file fallback ─────────────────────────────────────
reset_goldens
REG="$SBX/reports/phase-$ITER-regression-replay-results.md"
LLM="$SBX/reports/phase-$ITER-ui-test-results.llm.md"
MERGED="$SBX/reports/phase-$ITER-ui-test-results.md"
echo "replay rows" > "$REG"
echo "llm rows" > "$LLM"
rm -f "$MERGED"
(
  set -euo pipefail
  source "$LIB"
  REPO_ROOT="$SBX"
  replay_lane_paths "$ITER"
  MERGE_RESULTS="$SBX/nonexistent-merge.py"   # force the merge to crash
  _use_replay=yes
  replay_lane_merge_results "$MERGED" "$LLM" 2>/dev/null
)
[[ "$(cat "$MERGED" 2>/dev/null)" == "llm rows" ]] \
  && assert "merge crash: falls back to copying the LLM lane file" pass \
  || assert "merge crash: falls back to copying the LLM lane file" fail

# ── 12. REL-5 flake discipline: rescue / infra-then-FAIL / never-retry-5 / non-6 ──
# 12a. infra-then-success: the retry rescues the lane — normal PASS path,
# no SKIPPED-INFRA state, raw artifact is the retry's own output.
reset_goldens
golden "J-01"
rm -f "$WORK/count12a"; : > "$WORK/svc12a"
out="$(STUB_REPLAY_RC_SEQ='6 0' STUB_REPLAY_COUNT_FILE="$WORK/count12a" \
       STUB_SVC_STAMP="$WORK/svc12a" RUN_PARTITION_LOG="$WORK/lane12a.log" \
       run_partition "J-01 J-02 ")"
[[ "$out" == "R_REPLAY=<J-01 >|R_LLM=<J-02 >|use=<yes>|failed=<>" && "$(cat "$WORK/count12a" 2>/dev/null)" == "2" ]] \
  && assert "12a rescue: retry turns an infra blip into a normal PASS lane" pass \
  || { assert "12a rescue: retry turns an infra blip into a normal PASS lane" fail; echo "    got: $out ($(cat "$WORK/count12a" 2>/dev/null) invocations)"; }
grep -q '^\*\*Browser QA Verdict:\*\* PASS' "$SBX/reports/phase-$ITER-regression-replay-results.md" \
  && assert "12a rescue: raw artifact is the retry's normal output (no SKIPPED-INFRA)" pass \
  || assert "12a rescue: raw artifact is the retry's normal output (no SKIPPED-INFRA)" fail

# 12b. infra-then-FAIL: the retry's rc=5 takes the normal REPLAY_FAILED path
# (first-observation assertion FAILs are re-confirmed by the LLM lane as today).
reset_goldens
golden "J-01"
rm -f "$WORK/count12b"
out="$(STUB_REPLAY_VERDICT=FAIL STUB_REPLAY_RC_SEQ='6 5' STUB_REPLAY_COUNT_FILE="$WORK/count12b" \
       RUN_PARTITION_LOG="$WORK/lane12b.log" run_partition "J-01 J-02 ")"
[[ "$out" == "R_REPLAY=<J-01 >|R_LLM=<J-02 >|use=<yes>|failed=<J-01 >" && "$(cat "$WORK/count12b" 2>/dev/null)" == "2" ]] \
  && assert "12b infra-then-FAIL: retry's assertion FAIL feeds REPLAY_FAILED unchanged" pass \
  || { assert "12b infra-then-FAIL: retry's assertion FAIL feeds REPLAY_FAILED unchanged" fail; echo "    got: $out ($(cat "$WORK/count12b" 2>/dev/null) invocations)"; }

# 12c. A clean assertion failure (rc=5) is NEVER retried. Discriminating
# sequence: a (forbidden) retry would hit rc=0 and flip the outcome.
reset_goldens
golden "J-01"
rm -f "$WORK/count12c"; : > "$WORK/svc12c"
out="$(STUB_REPLAY_VERDICT=FAIL STUB_REPLAY_RC_SEQ='5 0' STUB_REPLAY_COUNT_FILE="$WORK/count12c" \
       STUB_SVC_STAMP="$WORK/svc12c" run_partition "J-01 J-02 ")"
[[ "$out" == "R_REPLAY=<J-01 >|R_LLM=<J-02 >|use=<yes>|failed=<J-01 >" && "$(cat "$WORK/count12c" 2>/dev/null)" == "1" ]] \
  && assert "12c: assertion failure (rc=5) NEVER retried — 1 invocation, FAIL propagates as today" pass \
  || { assert "12c: assertion failure (rc=5) NEVER retried" fail; echo "    got: $out ($(cat "$WORK/count12c" 2>/dev/null) invocations)"; }
[[ ! -s "$WORK/svc12c" ]] \
  && assert "12c: zero service re-checks on an assertion failure" pass \
  || assert "12c: zero service re-checks on an assertion failure" fail

# 12d. A non-6 lane failure (rc=3, playwright missing) keeps the old no-retry
# generic fallback — no retry, no re-check, no SKIPPED-INFRA state.
reset_goldens
golden "J-01"
rm -f "$WORK/count12d"; : > "$WORK/svc12d"
out="$(STUB_REPLAY_RC_SEQ='3' STUB_REPLAY_COUNT_FILE="$WORK/count12d" \
       STUB_SVC_STAMP="$WORK/svc12d" RUN_PARTITION_LOG="$WORK/lane12d.log" \
       run_partition "J-01 J-02 ")"
[[ "$out" == "R_REPLAY=<>|R_LLM=<J-02 >|use=<no>|failed=<>" && "$(cat "$WORK/count12d" 2>/dev/null)" == "1" && ! -s "$WORK/svc12d" ]] \
  && assert "12d: non-6 failure (rc=3) keeps the old generic fallback — no retry, no state" pass \
  || { assert "12d: non-6 failure (rc=3) keeps the old generic fallback — no retry, no state" fail; echo "    got: $out ($(cat "$WORK/count12d" 2>/dev/null) invocations)"; }
grep -q "Replay lane failed (rc=3) — falling back to the LLM lane" "$WORK/lane12d.log" \
  && assert "12d: generic fallback warn text unchanged" pass \
  || assert "12d: generic fallback warn text unchanged" fail

# 12e. Reader decision (recorded in REL-5): SKIPPED-INFRA journeys still feed
# the LLM lane — the regression set after a double-6 is the WHOLE required set.
out="$( (
  set -euo pipefail
  source "$LIB"
  _use_replay=no REPLAY_FAILED="" R_LLM="J-02 " REQUIRED_JOURNEYS="J-01 J-02 " REPLAY_SKIPPED_INFRA=yes
  replay_lane_llm_regression_set
) )"
[[ "$out" == "J-01 J-02 " ]] && assert "12e: SKIPPED-INFRA → whole REQUIRED set feeds the LLM lane" pass \
  || { assert "12e: SKIPPED-INFRA → whole REQUIRED set feeds the LLM lane" fail; echo "    got: <$out>"; }

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
