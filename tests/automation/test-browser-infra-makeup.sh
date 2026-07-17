#!/usr/bin/env bash
# test-browser-infra-makeup.sh — REL-14 unit test: the browser-infra make-up
# lane (primary browser-qa preflight + out-of-band token + make-up scheduling).
#
# Logic under test lives in lib/replay-lane.sh (sourceable, same style as
# test-replay-lane.sh):
#   bqa_services_probe        — pure probe (backend health + frontend), never boots
#   bqa_preflight             — probe → ensure_services_running → probe (ONE retry)
#   bqa_write_infra_token     — $ITER_DIR/browser-infra.json {journeys, reason,
#                               attempts, detected_by}; attempts carries across
#                               iterations via CHAIN_BQA_PREV_ATTEMPTS
#   bqa_results_infra_reason  — post-scan classifier: results with NO PASS/FAIL
#                               rows AND an infra-taxonomy reason → echoes reason
#
# The token is OUT-OF-BAND by design: the merged ui-test-results verdict enum
# must stay exactly PASS|FAIL|SKIPPED (REL-5 invariant; checkpoint greps parse
# it at four sites in goal-iter-lean.sh). Wiring is grep-asserted across
# goal-iter-lean.sh / browser-qa-phase.sh / run-goal.sh / run-judgment-evals.sh
# / the evaluator methodology + body (neutral sources).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}

WORK="$(mktemp -d)"
FE_PORT=48361
BE_PORT=48362
_srv_pids=()
cleanup() {
  local p
  for p in "${_srv_pids[@]:-}"; do kill "$p" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

start_dummy() {  # start_dummy <port> -> pid appended to _srv_pids
  ( cd "$WORK" && exec python3 -m http.server "$1" --bind 127.0.0.1 ) >/dev/null 2>&1 &
  _srv_pids+=("$!")
  local i
  for i in $(seq 1 30); do
    curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$1/" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

# Source the lib fresh in each scenario subshell so stubs stay contained.
LIB="$ENGINE_ROOT/scripts/automation/lib/replay-lane.sh"

# ── bqa_services_probe ────────────────────────────────────────────────────────
start_dummy "$BE_PORT" || echo "  WARN  dummy backend failed to start"
start_dummy "$FE_PORT" || echo "  WARN  dummy frontend failed to start"

probe() {  # probe <fe_url> <be_url> -> yes|no
  if ( set -euo pipefail
       source "$LIB"
       FRONTEND_URL="$1" QA_BACKEND_HEALTH_URL="$2" bqa_services_probe ) 2>/dev/null; then
    echo yes
  else
    echo no
  fi
}

[[ "$(probe "http://127.0.0.1:$FE_PORT/" "http://127.0.0.1:$BE_PORT/")" == "yes" ]] \
  && assert "probe: both services up -> 0" "pass" \
  || assert "probe: both services up -> 0" "fail"
[[ "$(probe "http://127.0.0.1:48399/" "http://127.0.0.1:$BE_PORT/")" == "no" ]] \
  && assert "probe: frontend down -> 1" "pass" \
  || assert "probe: frontend down -> 1" "fail"
[[ "$(probe "http://127.0.0.1:$FE_PORT/" "http://127.0.0.1:48398/")" == "no" ]] \
  && assert "probe: backend down -> 1" "pass" \
  || assert "probe: backend down -> 1" "fail"

# ── bqa_preflight (one retry via ensure_services_running) ─────────────────────
# Failure path: services down, stub ensure does nothing -> rc 1, exactly one re-check.
STAMP="$WORK/ensure-stamp"; : > "$STAMP"
if ( set -euo pipefail
     source "$LIB"
     ensure_services_running() { echo recheck >> "$STAMP"; }
     FRONTEND_URL="http://127.0.0.1:48399/" QA_BACKEND_HEALTH_URL="http://127.0.0.1:48398/" \
       bqa_preflight ) 2>/dev/null; then
  assert "preflight: dead services + no-op ensure -> 1" "fail"
else
  assert "preflight: dead services + no-op ensure -> 1" "pass"
fi
[[ "$(wc -l < "$STAMP")" == "1" ]] \
  && assert "preflight: exactly ONE ensure_services_running re-check" "pass" \
  || assert "preflight: exactly ONE ensure_services_running re-check (got $(wc -l < "$STAMP"))" "fail"

# Recovery path: first probe fails (dead port), stub ensure flips the URLs to
# the live dummies via the env the retry re-reads -> rc 0.
STAMP2="$WORK/ensure-stamp2"; : > "$STAMP2"
if ( set -euo pipefail
     source "$LIB"
     FRONTEND_URL="http://127.0.0.1:48399/"
     QA_BACKEND_HEALTH_URL="http://127.0.0.1:$BE_PORT/"
     ensure_services_running() { echo recheck >> "$STAMP2"; FRONTEND_URL="http://127.0.0.1:$FE_PORT/"; }
     bqa_preflight ) 2>/dev/null; then
  assert "preflight: ensure revives the service -> 0 after retry" "pass"
else
  assert "preflight: ensure revives the service -> 0 after retry" "fail"
fi
[[ "$(wc -l < "$STAMP2")" == "1" ]] \
  && assert "preflight: recovery used exactly one re-check" "pass" \
  || assert "preflight: recovery used exactly one re-check" "fail"

# ── bqa_write_infra_token ─────────────────────────────────────────────────────
IDIR="$WORK/iter-3"
( set -euo pipefail
  source "$LIB"
  unset CHAIN_BQA_PREV_ATTEMPTS || true
  bqa_write_infra_token "$IDIR" "J-04 J-06" "services preflight failed after retry" "preflight" ) 2>/dev/null || true
if [[ -f "$IDIR/browser-infra.json" ]] \
   && python3 - "$IDIR/browser-infra.json" <<'PY' 2>/dev/null; then
import json, sys
d = json.load(open(sys.argv[1]))
assert d["journeys"] == ["J-04", "J-06"], d
assert d["attempts"] == 1, d
assert d["detected_by"] == "preflight", d
assert "preflight failed" in d["reason"], d
PY
  assert "token: valid JSON, journeys list, attempts=1, detected_by" "pass"
else
  assert "token: valid JSON, journeys list, attempts=1, detected_by" "fail"
fi
# Only the token file is written — nothing else appears in the iter dir.
[[ "$(ls "$IDIR" | tr '\n' ' ')" == "browser-infra.json " ]] \
  && assert "token: writes ONLY browser-infra.json (out-of-band)" "pass" \
  || assert "token: writes ONLY browser-infra.json (got: $(ls "$IDIR" | tr '\n' ' '))" "fail"

( set -euo pipefail
  source "$LIB"
  CHAIN_BQA_PREV_ATTEMPTS=1 bqa_write_infra_token "$IDIR" "J-04" "still down" "postscan" ) 2>/dev/null || true
if python3 - "$IDIR/browser-infra.json" <<'PY' 2>/dev/null; then
import json, sys
d = json.load(open(sys.argv[1]))
assert d["attempts"] == 2, d
assert d["detected_by"] == "postscan", d
PY
  assert "token: CHAIN_BQA_PREV_ATTEMPTS=1 -> attempts=2 (cross-iteration counter)" "pass"
else
  assert "token: CHAIN_BQA_PREV_ATTEMPTS=1 -> attempts=2 (cross-iteration counter)" "fail"
fi

# ── bqa_results_infra_reason (post-scan classifier) ───────────────────────────
INFRA_MD="$WORK/results-infra.md"
cat > "$INFRA_MD" <<'EOF'
**Browser QA Verdict:** SKIPPED

| UT-J-04 | compute button | SKIP | browser infrastructure failure: Chrome did not become ready on port 9222 |
| UT-J-05 | resume sweep | SKIP | browser infrastructure failure: Chrome did not become ready on port 9222 |
EOF
MIXED_MD="$WORK/results-mixed.md"
cat > "$MIXED_MD" <<'EOF'
**Browser QA Verdict:** FAIL

| UT-J-04 | compute button | PASS | shot.png |
| UT-J-05 | resume sweep | SKIP | browser infrastructure failure: crash |
EOF
reason_out="$( ( set -euo pipefail; source "$LIB"; bqa_results_infra_reason "$INFRA_MD" ) 2>/dev/null || true )"
[[ "$reason_out" == *"browser infrastructure failure"* ]] \
  && assert "classifier: all-SKIP + infra taxonomy -> echoes reason" "pass" \
  || assert "classifier: all-SKIP + infra taxonomy -> echoes reason (got '$reason_out')" "fail"
if ( set -euo pipefail; source "$LIB"; bqa_results_infra_reason "$MIXED_MD" ) >/dev/null 2>&1; then
  assert "classifier: PASS row present -> 1 (never tokenizes real results)" "fail"
else
  assert "classifier: PASS row present -> 1 (never tokenizes real results)" "pass"
fi
if ( set -euo pipefail; source "$LIB"; bqa_results_infra_reason "$WORK/nope.md" ) >/dev/null 2>&1; then
  assert "classifier: missing file -> 1" "fail"
else
  assert "classifier: missing file -> 1" "pass"
fi

# ── wiring: goal-iter-lean.sh (lean lane) ─────────────────────────────────────
GIL="$ENGINE_ROOT/scripts/automation/goal-iter-lean.sh"
grep -q 'CHAIN_BQA_PREFLIGHT' "$GIL" \
  && assert "wiring(lean): preflight knob gate present" "pass" \
  || assert "wiring(lean): preflight knob gate present" "fail"
grep -q 'bqa_write_infra_token' "$GIL" \
  && assert "wiring(lean): token writer called" "pass" \
  || assert "wiring(lean): token writer called" "fail"
grep -q 'CHAIN_BQA_MAKEUP_JOURNEYS' "$GIL" \
  && assert "wiring(lean): make-up journeys unioned into the browser set" "pass" \
  || assert "wiring(lean): make-up journeys unioned into the browser set" "fail"
[[ "$(grep -c "grep -oE 'PASS|FAIL|SKIPPED'" "$GIL")" -ge 4 ]] \
  && assert "wiring(lean): all 4 checkpoint verdict greps still parse PASS|FAIL|SKIPPED" "pass" \
  || assert "wiring(lean): all 4 checkpoint verdict greps still parse PASS|FAIL|SKIPPED" "fail"

# ── wiring: browser-qa-phase.sh (full pipeline) ───────────────────────────────
BQP="$ENGINE_ROOT/scripts/automation/browser-qa-phase.sh"
grep -q 'CHAIN_BQA_PREFLIGHT' "$BQP" \
  && assert "wiring(full): preflight knob gate present" "pass" \
  || assert "wiring(full): preflight knob gate present" "fail"
grep -q 'bqa_write_infra_token' "$BQP" \
  && assert "wiring(full): token writer called (goal mode)" "pass" \
  || assert "wiring(full): token writer called (goal mode)" "fail"

# ── wiring: run-goal.sh (evaluator input + make-up scheduling) ────────────────
RG="$ENGINE_ROOT/scripts/automation/run-goal.sh"
grep -q 'browser-infra.json' "$RG" \
  && assert "wiring(engine): evaluator prompt names the browser-infra token" "pass" \
  || assert "wiring(engine): evaluator prompt names the browser-infra token" "fail"
grep -q 'Pending-infra make-up targets' "$RG" \
  && assert "wiring(engine): BINDING make-up line in the decomposer prompt" "pass" \
  || assert "wiring(engine): BINDING make-up line in the decomposer prompt" "fail"
grep -q 'CHAIN_BQA_MAKEUP_JOURNEYS' "$RG" \
  && assert "wiring(engine): make-up set exported to the executor" "pass" \
  || assert "wiring(engine): make-up set exported to the executor" "fail"
grep -q 'CHAIN_BQA_PREV_ATTEMPTS' "$RG" \
  && assert "wiring(engine): prior attempts carried for the two-strike counter" "pass" \
  || assert "wiring(engine): prior attempts carried for the two-strike counter" "fail"

# ── wiring: judgment harness prompt copy ──────────────────────────────────────
RJ="$ENGINE_ROOT/scripts/automation/run-judgment-evals.sh"
grep -q 'browser-infra.json' "$RJ" \
  && assert "wiring(judgment): harness prompt copy carries the token line" "pass" \
  || assert "wiring(judgment): harness prompt copy carries the token line" "fail"

# ── evaluator contract (neutral sources) ──────────────────────────────────────
EVB="$ENGINE_ROOT/agents/goal-evaluator/body.md"
EVM="$ENGINE_ROOT/skills/goal-evaluation-methodology.md"
grep -q 'pending-infra' "$EVM" \
  && assert "contract: methodology skill carves the pending-infra scoring rule" "pass" \
  || assert "contract: methodology skill carves the pending-infra scoring rule" "fail"
grep -q 'pending_infra' "$EVB" \
  && assert "contract: journey-history pending_infra boolean documented in body" "pass" \
  || assert "contract: journey-history pending_infra boolean documented in body" "fail"
grep -qi 'two consecutive.*infra\|infra.*two consecutive\|second consecutive' "$EVB" \
  && assert "contract: two-strike human-blocker rule stated" "pass" \
  || assert "contract: two-strike human-blocker rule stated" "fail"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
