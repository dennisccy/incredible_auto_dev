#!/usr/bin/env bash
# test-golden-autoderive.sh — SPEED-21 + SPEED-23 unit test: golden
# auto-derivation from the verified demo, and the bounded golden-coverage
# nudge. Logic under test lives in lib/replay-lane.sh:
#   replay_lane_autoderive_goldens <phase> <demo-json> <results-md>
#     -> derive candidates (stub demo_runner --mode derive), REAL-verify each
#        (stub --mode verify with per-journey rc), install green ones
#        atomically, reject rc-5, abort the batch on rc-6, honor the cap and
#        the CHAIN_GOLDEN_AUTODERIVE knob, and clear goldens-regen-pending
#        entries on install.
#   replay_lane_golden_coverage — persists the gap list to state/golden-gaps.
#   replay_lane_golden_nudge_pick — one gap ∩ LLM-set journey per run,
#        min-count rotation persisted in state/golden-nudge.json, knob-gated.
# The REAL derive transform is covered by demo_runner.py self-test
# (_t_derive_*); here demo_runner is a stub so install/reject/cap semantics
# are provable without a browser.
#
# shellcheck disable=SC1090,SC2034
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

ITER="goal-adtest-iter-3"
SBX="$WORK/proj"
mkdir -p "$SBX"
cp -r "$ENGINE_ROOT/scripts" "$SBX/"
mkdir -p "$SBX/reports"
LIB="$SBX/scripts/automation/lib/replay-lane.sh"

# Stub demo_runner: derive writes candidates (unless STUB_DERIVE_REJECT names
# the journey); verify exits per STUB_VERIFY_RC_MAP ("J-05:5 J-06:0", default
# 0) and appends each verified journey to STUB_VERIFY_COUNT_FILE.
cat > "$SBX/scripts/automation/lib/demo_runner.py" <<'PYEOF'
#!/usr/bin/env python3
import os, sys

def arg(name, default=""):
    if name in sys.argv:
        i = sys.argv.index(name)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default

mode = arg("--mode")
journeys = [j for j in arg("--journeys").replace(",", " ").split() if j]

if mode == "derive":
    rejects = os.environ.get("STUB_DERIVE_REJECT", "").split()
    outdir = arg("--scripts-dir")
    for j in journeys:
        if j in rejects:
            print(f"{j} rejected: stub says no")
            continue
        p = os.path.join(outdir, f"{j}.json.candidate")
        with open(p, "w") as f:
            f.write('{"schema_version":1,"journey":"%s","steps":[{"n":1,"action":{"type":"goto","url":"/"},"expect":{"text":"x"}}]}' % j)
        print(f"{j} derived {p}")
    sys.exit(0)

if mode == "verify":
    cf = os.environ.get("STUB_VERIFY_COUNT_FILE", "")
    if cf:
        with open(cf, "a") as f:
            f.write(" ".join(journeys) + "\n")
    rc = 0
    rcmap = dict(kv.split(":") for kv in os.environ.get("STUB_VERIFY_RC_MAP", "").split() if ":" in kv)
    if journeys and journeys[0] in rcmap:
        rc = int(rcmap[journeys[0]])
    results = arg("--results")
    if results:
        with open(results, "w") as f:
            f.write("**Browser QA Verdict:** PASS\n")
    sys.exit(rc)

sys.exit(0)
PYEOF

# Merged results fixture: PASS rows for the given journeys.
write_results() {  # write_results <out> <J-XX>...
  local out="$1"; shift
  {
    echo "**Browser QA Verdict:** PASS"
    echo ""
    echo "| Test ID | Name | Type | Prio | Expected | Actual | Verdict | Evidence |"
    echo "|---|---|---|---|---|---|---|---|"
    local j
    for j in "$@"; do
      echo "| UT-$j | llm $j | journey | P1 | works | ok | PASS | none |"
    done
  } > "$out"
}

# run_autoderive <results-file> — fresh production-discipline subshell.
run_autoderive() {
  local results="$1"
  (
    set -euo pipefail
    source "$LIB"
    REPO_ROOT="$SBX"
    FRONTEND_URL="http://localhost:9"
    CHAIN_TMPDIR="$WORK/tmp"
    replay_lane_paths "$ITER"
    replay_lane_autoderive_goldens "$ITER" "$SBX/reports/phase-$ITER-demo.json" "$results"
  )
}

reset_state() {
  rm -rf "$SBX/runs" "$WORK/tmp" "$WORK/verify-count"
  mkdir -p "$WORK/tmp"
  echo '{"steps":[]}' > "$SBX/reports/phase-$ITER-demo.json"
}

GDIR="$SBX/runs/goal-session-adtest/journey-scripts"
STATE="$SBX/runs/goal-session-adtest/state"

echo "=== test-golden-autoderive.sh ==="

# ── 1. Install: green candidates land in journey-scripts/ ────────────────────
reset_state
write_results "$WORK/res1.md" J-05 J-06
STUB_VERIFY_COUNT_FILE="$WORK/verify-count" run_autoderive "$WORK/res1.md" >/dev/null 2>&1
[[ -f "$GDIR/J-05.json" && -f "$GDIR/J-06.json" ]] \
  && assert "1: green candidates installed for both gap journeys" pass \
  || assert "1: green candidates installed for both gap journeys" fail
[[ "$(wc -l < "$WORK/verify-count" 2>/dev/null)" == "2" ]] \
  && assert "1: each candidate got its own REAL verify pass" pass \
  || assert "1: each candidate got its own REAL verify pass (got $(cat "$WORK/verify-count" 2>/dev/null))" fail
python3 -c "import json,sys; json.load(open('$GDIR/J-05.json'))" 2>/dev/null \
  && assert "1: installed golden is valid JSON" pass \
  || assert "1: installed golden is valid JSON" fail

# ── 2. Reject: a verify-FAIL candidate is discarded, others still install ────
reset_state
write_results "$WORK/res2.md" J-05 J-06
STUB_VERIFY_RC_MAP="J-05:5" run_autoderive "$WORK/res2.md" >"$WORK/log2" 2>&1
[[ ! -f "$GDIR/J-05.json" && -f "$GDIR/J-06.json" ]] \
  && assert "2: rc-5 candidate discarded; the green one still installs" pass \
  || assert "2: rc-5 candidate discarded; the green one still installs" fail
grep -q 'FAILED its verify pass' "$WORK/log2" \
  && assert "2: rejection is loud" pass \
  || assert "2: rejection is loud" fail

# ── 3. Infra: rc-6 discards ALL remaining candidates ─────────────────────────
reset_state
write_results "$WORK/res3.md" J-05 J-06
STUB_VERIFY_RC_MAP="J-05:6" STUB_VERIFY_COUNT_FILE="$WORK/verify-count" \
  run_autoderive "$WORK/res3.md" >"$WORK/log3" 2>&1
[[ ! -f "$GDIR/J-05.json" && ! -f "$GDIR/J-06.json" ]] \
  && assert "3: rc-6 discards every remaining candidate (nothing installed)" pass \
  || assert "3: rc-6 discards every remaining candidate (nothing installed)" fail
[[ "$(wc -l < "$WORK/verify-count" 2>/dev/null)" == "1" ]] \
  && assert "3: no further verify passes after the infra rc" pass \
  || assert "3: no further verify passes after the infra rc" fail

# ── 4. Cap: CHAIN_GOLDEN_AUTODERIVE_MAX bounds the batch ─────────────────────
reset_state
write_results "$WORK/res4.md" J-01 J-02 J-03 J-04
CHAIN_GOLDEN_AUTODERIVE_MAX=2 STUB_VERIFY_COUNT_FILE="$WORK/verify-count" \
  run_autoderive "$WORK/res4.md" >/dev/null 2>&1
[[ "$(ls "$GDIR" 2>/dev/null | grep -c '\.json$')" == "2" ]] \
  && assert "4: cap=2 installs at most 2 goldens per iteration" pass \
  || assert "4: cap=2 installs at most 2 goldens per iteration (got: $(ls "$GDIR" 2>/dev/null | tr '\n' ' '))" fail

# ── 5. Knob off: nothing derived, nothing installed ──────────────────────────
reset_state
write_results "$WORK/res5.md" J-05
CHAIN_GOLDEN_AUTODERIVE=false run_autoderive "$WORK/res5.md" >/dev/null 2>&1
[[ ! -d "$GDIR" || -z "$(ls "$GDIR" 2>/dev/null)" ]] \
  && assert "5: CHAIN_GOLDEN_AUTODERIVE=false is a full no-op" pass \
  || assert "5: CHAIN_GOLDEN_AUTODERIVE=false is a full no-op" fail

# ── 6. Regen-pending: an EXISTING golden flagged for regen is re-derived ─────
reset_state
mkdir -p "$GDIR" "$STATE"
echo '{"old":"golden"}' > "$GDIR/J-07.json"
printf 'J-07\nJ-08\n' > "$STATE/goldens-regen-pending"
write_results "$WORK/res6.md" J-07
run_autoderive "$WORK/res6.md" >/dev/null 2>&1
grep -q 'schema_version' "$GDIR/J-07.json" \
  && assert "6: regen-pending golden overwritten with the fresh derivation" pass \
  || assert "6: regen-pending golden overwritten with the fresh derivation" fail
if grep -qx "J-07" "$STATE/goldens-regen-pending" 2>/dev/null; then
  assert "6: installed journey cleared from goldens-regen-pending" fail
else
  assert "6: installed journey cleared from goldens-regen-pending" pass
fi
grep -qx "J-08" "$STATE/goldens-regen-pending" 2>/dev/null \
  && assert "6: un-regenerated journey stays pending" pass \
  || assert "6: un-regenerated journey stays pending" fail

# ── 7. Coverage persists the gap list (SPEED-23 input) ───────────────────────
reset_state
mkdir -p "$GDIR"
echo '{"g":1}' > "$GDIR/J-01.json"
write_results "$WORK/res7.md" J-01 J-04 J-07
(
  set -euo pipefail
  source "$LIB"
  REPO_ROOT="$SBX"
  replay_lane_paths "$ITER"
  replay_lane_golden_coverage "$WORK/res7.md" "$ITER" >/dev/null
)
[[ "$(cat "$STATE/golden-gaps" 2>/dev/null | tr '\n' ' ')" == "J-04 J-07 " ]] \
  && assert "7: golden-gaps persisted (missing goldens only)" pass \
  || assert "7: golden-gaps persisted (got '$(cat "$STATE/golden-gaps" 2>/dev/null | tr '\n' ' ')')" fail
echo '{"g":1}' > "$GDIR/J-04.json"; echo '{"g":1}' > "$GDIR/J-07.json"
(
  set -euo pipefail
  source "$LIB"
  REPO_ROOT="$SBX"
  replay_lane_paths "$ITER"
  replay_lane_golden_coverage "$WORK/res7.md" "$ITER" >/dev/null
)
[[ ! -f "$STATE/golden-gaps" ]] \
  && assert "7: gap file removed once coverage is complete" pass \
  || assert "7: gap file removed once coverage is complete" fail

# ── 8. Nudge pick: gaps ∩ LLM set, min-count rotation, knob ──────────────────
nudge() {  # nudge <llm-set>
  (
    set -euo pipefail
    source "$LIB"
    REPO_ROOT="$SBX"
    SID="adtest"
    replay_lane_golden_nudge_pick "$1"
  )
}
reset_state
mkdir -p "$STATE"
printf 'J-04\nJ-07\n' > "$STATE/golden-gaps"
p1="$(nudge "J-04 J-07 J-08 ")"
p2="$(nudge "J-04 J-07 J-08 ")"
p3="$(nudge "J-04 J-07 J-08 ")"
[[ "$p1" == "J-04" && "$p2" == "J-07" && "$p3" == "J-04" ]] \
  && assert "8: min-count rotation (J-04 → J-07 → J-04)" pass \
  || assert "8: min-count rotation (got '$p1' '$p2' '$p3')" fail
[[ -z "$(nudge "J-08 J-09 ")" ]] \
  && assert "8: no gap in the LLM set → no nudge" pass \
  || assert "8: no gap in the LLM set → no nudge" fail
[[ -z "$(CHAIN_GOLDEN_NUDGE=false nudge "J-04 ")" ]] \
  && assert "8: CHAIN_GOLDEN_NUDGE=false disables the nudge" pass \
  || assert "8: CHAIN_GOLDEN_NUDGE=false disables the nudge" fail

# ── 9. Wiring greps ──────────────────────────────────────────────────────────
grep -q 'replay_lane_autoderive_goldens' "$ENGINE_ROOT/scripts/automation/demo-phase.sh" \
  && assert "9: demo-phase.sh hooks the auto-derivation after a green record run" pass \
  || assert "9: demo-phase.sh hooks the auto-derivation after a green record run" fail
grep -q 'REQUIRED DELIVERABLE (golden-coverage nudge)' "$ENGINE_ROOT/scripts/automation/goal-iter-lean.sh" \
  && assert "9: lean browser-qa prompt carries the nudge deliverable" pass \
  || assert "9: lean browser-qa prompt carries the nudge deliverable" fail
grep -q 'REQUIRED DELIVERABLE (golden-coverage nudge)' "$ENGINE_ROOT/scripts/automation/browser-qa-phase.sh" \
  && assert "9: full-depth browser-qa prompt carries the nudge deliverable" pass \
  || assert "9: full-depth browser-qa prompt carries the nudge deliverable" fail
grep -q '"derive"' "$ENGINE_ROOT/scripts/automation/lib/demo_runner.py" \
  && assert "9: demo_runner exposes --mode derive" pass \
  || assert "9: demo_runner exposes --mode derive" fail
grep -q 'golden_nudge' "$ENGINE_ROOT/scripts/automation/goal-iter-lean.sh" \
  && grep -q 'golden_nudge' "$ENGINE_ROOT/scripts/automation/browser-qa-phase.sh" \
  && assert "9: nudge telemetry recorded at both depths" pass \
  || assert "9: nudge telemetry recorded at both depths" fail

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
