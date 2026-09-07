#!/usr/bin/env bash
# test-evidence-work-guard.sh — HARD-1: the deterministic implementation-work
# guard for the evidence path (TenSteps policy-state-core-v1 iter-7 regression).
#
# What failed: a `Depth: lean` spec whose Target journeys were all recorded
# passing was demoted lean → evidence by run-goal.sh's SPEED-9 backstop although
# its `## IN SCOPE → ### Backend` listed a real fix; the executor then skipped
# developer+reviewer, wrote a stub handoff and a FABRICATED `**Verdict:** PASS`
# review, and labelled both skips `reason:"checkpoint"`.
#
# Invariants pinned here:
#   1. dispatch_depth == evidence  ⇒  has_implementation_work(spec) == false
#      (engine guard in the depth block AND executor self-refusal, exit 76)
#   2. prior ESCALATE never yields a dispatch shallower than full (knob)
#   3. every step_skipped event carries its true reason (checkpoint | evidence-mode)
#   4. no artifact claims a verdict for a step that did not run — the evidence
#      review artifact is an explicit NON-verdict status, valid ONLY on the
#      engine's evidence dispatch (never a bypass in a normal lean iteration)
#
# Parts:
#   P. lib/iter_spec.py has-implementation-work + the bash wrapper (unit)
#   D. the REAL depth block of run-goal.sh, extracted between two stable
#      markers and run with the cost helpers stubbed (behavioural)
#   W. wiring greps (ordering + knob names)
#   X. the REAL goal-iter-lean.sh in a sandbox with a stub `claude`
#
# Offline, no model calls. Signals only ever target this test's own dummies.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}

WORK="$(mktemp -d)"
DUMMY_PIDS=()
cleanup() {
  local p
  for p in "${DUMMY_PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done
  pkill -KILL -f "$WORK/" 2>/dev/null
  rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

RG="$ENGINE_ROOT/scripts/automation/run-goal.sh"
LEAN="$ENGINE_ROOT/scripts/automation/goal-iter-lean.sh"
PROBE="$ENGINE_ROOT/scripts/automation/lib/iter_spec.py"

# ── Spec fixtures ─────────────────────────────────────────────────────────────
SPECS="$WORK/specs"; mkdir -p "$SPECS"

# The TenSteps iter-7 shape: lean, all targets passing, two concrete Backend bullets.
write_iter7_spec() {  # $1 path [$2 depth]
  cat > "$1" <<SPEC
# Goal Iteration 7 — Close the AG-18 provenance gap

## Goal Mode Metadata

- **Session ID:** hardtest
- **Iteration:** 7
- **Mode:** next
- **Depth:** ${2:-lean}
- **Frontend Present:** no — correcting the backend data is sufficient
- **Target journeys:** J-02, J-03, J-04
- **Required-still-passing journeys:** J-01, J-05

## GOAL

Every page shows the real introducing commit instead of the stale placeholder.

## IN SCOPE

### Backend

- [ ] \`apps/backend/app/policy/versions.py::_policy_core_v1_pending_identity()\` (lines 144-163): replace the hardcoded pending placeholder with a resolved identity built from the SAME helper.
- [ ] \`apps/backend/tests/test_policy_versions.py\`: remove the carve-out so the stamp is asserted through the git-verifiable branch.
- [ ] No other backend file changes.

### Frontend

- (none — the pages already render whatever the backend serves)

### New user-facing capability

None new.

### Data-contract additions

None.

## OUT OF SCOPE

- Any new run launch, sweep, or portfolio run.

## DEFINITION OF DONE

- [ ] \`resolve_stamp("policy-core-v1")\` names commit c141c81 (TC-1)
- [ ] J-02 passes via browser-qa-agent (TC-7)

## TESTING REQUIREMENTS

- TC-1: given the fix, when resolve_stamp is called, then commit == c141c81
- TC-2: given the test file, when run, then it passes
- TC-3: given the tree, when git diff --stat is checked, then only two files appear
SPEC
}

# The TenSteps iter-9 shape: confirm-only, no implementation work anywhere.
write_iter9_spec() {  # $1 path [$2 depth]
  cat > "$1" <<SPEC
# Goal Iteration 9 — Confirm-and-close pass

## Goal Mode Metadata

- **Session ID:** hardtest
- **Iteration:** 9
- **Mode:** next
- **Depth:** ${2:-evidence}
- **Frontend Present:** no — no code changes this iteration
- **Target journeys:** J-01, J-02, J-03, J-04, J-05
- **Required-still-passing journeys:** same as Target journeys

## GOAL

Re-verify all five must-have journeys still pass, byte-unchanged.

## IN SCOPE

### Backend
- (none — no backend file is edited this iteration)

### Frontend
- N/A

### New user-facing capability
None.

### Data-contract additions
None.

## OUT OF SCOPE

- Any code change to app/policy/versions.py.

## DEFINITION OF DONE

- [ ] J-01 passes via deterministic replay
- [ ] J-02 passes via deterministic replay

## TESTING REQUIREMENTS

- TC-1: given J-01's stored golden script, when replayed, then PASS
- TC-2: given J-02's stored golden script, when replayed, then PASS
- TC-3: given docs/goal.md, when inspected, then the amendment is present
SPEC
}

PROBE_OUT=""; PROBE_RC=0
probe() {  # probe <spec> → sets PROBE_RC (exit code) and PROBE_OUT (the probe's JSON stdout)
  PROBE_OUT="$(python3 "$PROBE" has-implementation-work "$1" 2>/dev/null)"; PROBE_RC=$?
}
jf() { printf '%s' "$PROBE_OUT" | jq -r "$1" 2>/dev/null || echo "?"; }

# ── Part P: probe unit cases ──────────────────────────────────────────────────
echo "== P. probe"
write_iter7_spec "$SPECS/iter7.md"
probe "$SPECS/iter7.md"; rc=$PROBE_RC
[[ "$rc" == "0" && "$(jf .backend_bullets)" == "2" ]] \
  && assert "P1: iter-7 shape (two concrete Backend bullets) -> has work, backend_bullets=2" "pass" \
  || assert "P1: iter-7 shape -> has work (rc=$rc json=$PROBE_OUT)" "fail"

write_iter9_spec "$SPECS/iter9.md"
probe "$SPECS/iter9.md"; rc=$PROBE_RC
[[ "$rc" == "1" ]] \
  && assert "P2: iter-9 shape (- none / - N/A) -> provably none" "pass" \
  || assert "P2: iter-9 shape -> provably none (rc=$rc json=$PROBE_OUT)" "fail"

cat > "$SPECS/fillers.md" <<'SPEC'
## Goal Mode Metadata
- **Depth:** lean
- **Target journeys:** J-01
## IN SCOPE
### Backend
- [ ] <specific change>
- [ ] No code changes
- Nothing
### Frontend
- none
## OUT OF SCOPE
- x
SPEC
probe "$SPECS/fillers.md"; rc=$PROBE_RC
[[ "$rc" == "1" ]] \
  && assert "P3: placeholders and fillers (<...>, 'No code changes', 'Nothing') never count" "pass" \
  || assert "P3: placeholders and fillers never count (rc=$rc json=$PROBE_OUT)" "fail"

cat > "$SPECS/outofscope.md" <<'SPEC'
## Goal Mode Metadata
- **Depth:** lean
- **Target journeys:** J-01
## IN SCOPE
### Backend
- none
## OUT OF SCOPE
### Backend
- [ ] rewrite the replay engine
- [ ] add a migration
SPEC
probe "$SPECS/outofscope.md"; rc=$PROBE_RC
[[ "$rc" == "1" ]] \
  && assert "P4: Backend bullets only under OUT OF SCOPE do not count" "pass" \
  || assert "P4: Backend bullets only under OUT OF SCOPE do not count (rc=$rc)" "fail"

cat > "$SPECS/dod-only.md" <<'SPEC'
## Goal Mode Metadata
- **Depth:** lean
- **Frontend Present:** yes
- **Target journeys:** J-01
## IN SCOPE
### New user-facing capability
None.
### UI surface changes
None.
## DEFINITION OF DONE
- [ ] J-01 passes via browser-qa-agent (TC-1)
- [ ] Dev handoff written
## TESTING REQUIREMENTS
- TC-1: given the page, when opened, then it renders
- TC-2: given the API, when called, then it answers
- TC-3: given the tree, when diffed, then nothing changed
SPEC
probe "$SPECS/dod-only.md"; rc=$PROBE_RC
[[ "$rc" == "1" ]] \
  && assert "P5: DoD checkboxes, TC lines and 'Frontend Present: yes' are never implementation work" "pass" \
  || assert "P5: DoD/TC/Frontend Present never count (rc=$rc json=$PROBE_OUT)" "fail"

cat > "$SPECS/loose.md" <<'SPEC'
## Goal Mode Metadata
- **Depth:** lean
- **Target journeys:** J-01
## IN SCOPE
- [ ] Fix versions.py so the stamp names commit c141c81
## OUT OF SCOPE
- x
SPEC
probe "$SPECS/loose.md"; rc=$PROBE_RC
[[ "$rc" == "0" && "$(jf .loose_bullets)" == "1" ]] \
  && assert "P6: a concrete bullet directly under IN SCOPE (no ###) counts, loose_bullets=1" "pass" \
  || assert "P6: loose IN SCOPE bullet counts (rc=$rc json=$PROBE_OUT)" "fail"

cat > "$SPECS/frontend-variant.md" <<'SPEC'
## Goal Mode Metadata
- **Depth:** lean
- **Target journeys:** J-01
## IN SCOPE
### Backend
- none
### Frontend (if applicable)
- [ ] apps/frontend/app/backtests/page.tsx: render the source-identity badge
## OUT OF SCOPE
- x
SPEC
probe "$SPECS/frontend-variant.md"; rc=$PROBE_RC
[[ "$rc" == "0" && "$(jf .frontend_bullets)" == "1" ]] \
  && assert "P7: '### Frontend (if applicable)' header variant with a real bullet counts" "pass" \
  || assert "P7: Frontend header variant counts (rc=$rc json=$PROBE_OUT)" "fail"

probe "$SPECS/does-not-exist.md"; rc=$PROBE_RC
[[ "$rc" == "2" ]] \
  && assert "P8a: missing spec -> exit 2 (unreadable)" "pass" \
  || assert "P8a: missing spec -> exit 2 (rc=$rc)" "fail"
printf '# Sentinel\n\nAll remaining work is human-blocked.\n' > "$SPECS/sentinel.md"
probe "$SPECS/sentinel.md"; rc=$PROBE_RC
[[ "$rc" == "2" ]] \
  && assert "P8b: spec without '## IN SCOPE' -> exit 2 (unparseable)" "pass" \
  || assert "P8b: no IN SCOPE -> exit 2 (rc=$rc)" "fail"

# Bash wrapper: fail closed — only a provable 'none' (rc 1) returns 1.
( source "$ENGINE_ROOT/scripts/automation/lib/common.sh" 2>/dev/null
  r7=0; goal_spec_has_implementation_work "$SPECS/iter7.md" || r7=$?
  r9=0; goal_spec_has_implementation_work "$SPECS/iter9.md" || r9=$?
  rm=0; goal_spec_has_implementation_work "$SPECS/does-not-exist.md" || rm=$?
  rs=0; goal_spec_has_implementation_work "$SPECS/sentinel.md" || rs=$?
  echo "$r7 $r9 $rm $rs"
  [[ "${EVIDENCE_MODE_REFUSED_EXIT_CODE:-}" == "76" ]] && echo "code-ok" || echo "code-missing"
) > "$WORK/wrapper.out" 2>/dev/null
read -r r7 r9 rm rs < <(head -1 "$WORK/wrapper.out")
[[ "${r7:-x}" == "0" && "${r9:-x}" == "1" && "${rm:-x}" == "0" && "${rs:-x}" == "0" ]] \
  && assert "P9: wrapper goal_spec_has_implementation_work: work->0, none->1, missing->0, sentinel->0 (fail closed)" "pass" \
  || assert "P9: wrapper fail-closed semantics (got '$(head -1 "$WORK/wrapper.out")')" "fail"
grep -q '^code-ok$' "$WORK/wrapper.out" \
  && assert "P10: EVIDENCE_MODE_REFUSED_EXIT_CODE=76 is exported by lib/common.sh" "pass" \
  || assert "P10: EVIDENCE_MODE_REFUSED_EXIT_CODE=76 is exported by lib/common.sh" "fail"

grep -q 'def has_bullet' "$ENGINE_ROOT/scripts/automation/lib/common.sh" \
  && assert "P11: goal_new_fullstack_journey's parser is untouched (still inline in common.sh — consolidation is HARD-2)" "pass" \
  || assert "P11: goal_new_fullstack_journey's parser is untouched" "fail"

# ── Part D: the REAL depth block, extracted and driven ────────────────────────
echo "== D. depth block"
# Boundaries: the two stable engine comments/log lines. The block covers the
# Depth parse, the spec-declared evidence guard, the arbiter, the legacy
# allowlist, the escalate promotion, the cadence backstop and the evidence
# backstop — exactly the code that decides what gets dispatched.
_start=$(grep -n '^  # Parse depth$' "$RG" | head -1 | cut -d: -f1)
_end=$(grep -n 'echo "\[run-goal\] Iter spec depth: \$DEPTH"' "$RG" | head -1 | cut -d: -f1)
DEPTH_BLOCK="$WORK/depth-block.sh"
if [[ -n "$_start" && -n "$_end" && "$_end" -gt "$_start" ]]; then
  sed -n "${_start},$((_end - 1))p" "$RG" > "$DEPTH_BLOCK"
  assert "D0: depth block extracted (lines $_start-$((_end-1)))" "pass"
else
  assert "D0: depth block markers found in run-goal.sh" "fail"
  : > "$DEPTH_BLOCK"
fi

SESS="$WORK/goal-session-hardtest"; mkdir -p "$SESS/iter-7" "$SESS/state"
cat > "$SESS/state/journey-history.json" <<'EOF2'
{"journeys":{
 "J-01":{"id":"J-01","status":"passing"},"J-02":{"id":"J-02","status":"passing"},
 "J-03":{"id":"J-03","status":"already_passing"},"J-04":{"id":"J-04","status":"passing"},
 "J-05":{"id":"J-05","status":"passing"}},"anti_goal_violations":[]}
EOF2

# run_depth <spec> <prior_verdict> <current_iter> [env assignments...] → prints DEPTH; telemetry to $WORK/tele.jsonl
run_depth() {
  local spec="$1" pv="$2" ci="$3"; shift 3
  : > "$WORK/tele.jsonl"
  env "$@" bash -c '
    set -uo pipefail
    SCRIPT_DIR="'"$ENGINE_ROOT"'/scripts/automation"
    source "$SCRIPT_DIR/lib/common.sh" 2>/dev/null
    # Stub every COST helper and the pause; keep the HARD-1 helpers real.
    record_telemetry_event() { printf "{\"event\":\"%s\",\"data\":%s}\n" "$1" "${2:-{}}" >> "'"$WORK"'/tele.jsonl"; }
    goal_full_depth_required() { return 1; }
    goal_maintenance_isolation_required() { return 1; }
    _full_depth_pause() { echo "PAUSE:$1" >&2; exit 99; }
    goal_cadence_forces_full() { return 1; }
    goal_full_ran_in_window() { return 1; }
    goal_new_fullstack_journey() { return 1; }
    ITER_SPEC_PATH="'"$spec"'"; JOURNEY_HISTORY="'"$SESS"'/state/journey-history.json"
    GOAL_SESSION_DIR_LOCAL="'"$SESS"'"; ITER_DIR="'"$SESS"'/iter-'"$ci"'"; mkdir -p "$ITER_DIR"
    PRIOR_VERDICT="'"$pv"'"; PRIOR_DEPTH="${PRIOR_DEPTH_OVERRIDE:-lean}"; CURRENT_ITER='"$ci"'; LEAN_STREAK=1
    _use_legacy_allowlist=""; _budget_demoted=""
    source "'"$DEPTH_BLOCK"'"
    echo "DEPTH=$DEPTH"
  ' 2>"$WORK/depth.err" | sed -n 's/^DEPTH=//p'
}
tele_has() { grep -q "\"event\":\"$1\"" "$WORK/tele.jsonl" 2>/dev/null && grep "\"event\":\"$1\"" "$WORK/tele.jsonl" | grep -q "$2"; }

d=$(run_depth "$SPECS/iter7.md" CONTINUE 7)
[[ "$d" == "lean" ]] && tele_has depth_evidence_refused '"site":"backstop"' \
  && assert "D1: iter-7 shape + all targets passing + CONTINUE -> stays LEAN (depth_evidence_refused site=backstop)" "pass" \
  || assert "D1: iter-7 shape stays lean (got '$d'; tele: $(tr '\n' ' ' < "$WORK/tele.jsonl" | cut -c1-200); err: $(head -3 "$WORK/depth.err" | tr '\n' ' '))" "fail"
grep -q depth_evidence_override "$WORK/tele.jsonl" \
  && assert "D1b: no depth_evidence_override emitted for the refused demotion" "fail" \
  || assert "D1b: no depth_evidence_override emitted for the refused demotion" "pass"

write_iter9_spec "$SPECS/iter9-lean.md" lean
d=$(run_depth "$SPECS/iter9-lean.md" CONTINUE 9)
[[ "$d" == "evidence" ]] && tele_has depth_evidence_override '"from":"lean"' \
  && assert "D2: genuine evidence-only lean spec + all passing + CONTINUE -> demoted to EVIDENCE (no forced developer)" "pass" \
  || assert "D2: genuine evidence-only spec still demotes to evidence (got '$d'; err: $(head -3 "$WORK/depth.err" | tr '\n' ' '))" "fail"

write_iter7_spec "$SPECS/iter7-evidence.md" evidence
d=$(run_depth "$SPECS/iter7-evidence.md" CONTINUE 7)
[[ "$d" == "lean" ]] && tele_has depth_evidence_refused '"site":"spec-declared"' \
  && assert "D3: spec-declared 'Depth: evidence' + implementation work -> dispatched as LEAN (site=spec-declared)" "pass" \
  || assert "D3: spec-declared evidence with work -> lean (got '$d')" "fail"

d=$(run_depth "$SPECS/iter7.md" ESCALATE 8)
[[ "$d" == "full" ]] && tele_has depth_escalate_override '"to":"full"' \
  && assert "D4: prior ESCALATE + 'Depth: lean' -> promoted to FULL (depth_escalate_override)" "pass" \
  || assert "D4: prior ESCALATE + lean -> full (got '$d'; err: $(head -3 "$WORK/depth.err" | tr '\n' ' '))" "fail"

d=$(run_depth "$SPECS/iter9-lean.md" ESCALATE 9)
[[ "$d" == "full" ]] \
  && assert "D4b: prior ESCALATE + evidence-only lean spec -> FULL (never demoted below full after ESCALATE)" "pass" \
  || assert "D4b: prior ESCALATE + evidence-only spec -> full (got '$d')" "fail"

d=$(run_depth "$SPECS/iter9-lean.md" ESCALATE 9 CHAIN_ESCALATE_FORCES_FULL=false)
[[ "$d" == "lean" ]] \
  && assert "D4c: CHAIN_ESCALATE_FORCES_FULL=false -> no promotion, and ESCALATE no longer arms the evidence backstop (stays lean, not evidence)" "pass" \
  || assert "D4c: knob off -> lean, not evidence (got '$d')" "fail"

d=$(run_depth "$SPECS/iter7.md" ESCALATE 0)
[[ "$d" == "lean" ]] \
  && assert "D4d: iteration 0 is exempt from the ESCALATE promotion" "pass" \
  || assert "D4d: iteration 0 exempt (got '$d')" "fail"

d=$(run_depth "$SPECS/iter7.md" CONTINUE 7 CHAIN_EVIDENCE_WORK_GUARD=false)
[[ "$d" == "evidence" ]] \
  && assert "D5: rollback CHAIN_EVIDENCE_WORK_GUARD=false restores the pre-HARD-1 demotion" "pass" \
  || assert "D5: rollback knob restores the old demotion (got '$d')" "fail"

d=$(run_depth "$SPECS/sentinel.md" CONTINUE 7)
[[ "$d" == "lean" ]] \
  && assert "D6: an unparseable spec (no IN SCOPE, no Depth line) is never demoted to evidence (fail closed -> lean)" "pass" \
  || assert "D6: unparseable spec -> lean (got '$d')" "fail"

# ── Part W: wiring greps ──────────────────────────────────────────────────────
echo "== W. wiring"
_bs=$(grep -n 'SPEED-9 evidence backstop' "$RG" | head -1 | cut -d: -f1)
_bs_end=$(grep -n 'echo "\[run-goal\] Iter spec depth: \$DEPTH"' "$RG" | head -1 | cut -d: -f1)
_backstop="$(sed -n "${_bs:-0},${_bs_end:-0}p" "$RG")"
printf '%s' "$_backstop" | grep -q 'goal_spec_has_implementation_work' \
  && assert "W1: evidence backstop consults goal_spec_has_implementation_work" "pass" \
  || assert "W1: evidence backstop consults goal_spec_has_implementation_work" "fail"
printf '%s' "$_backstop" | grep -q 'depth_evidence_refused' \
  && assert "W2: evidence backstop records depth_evidence_refused" "pass" \
  || assert "W2: evidence backstop records depth_evidence_refused" "fail"
printf '%s' "$_backstop" | grep -q '"ESCALATE"' \
  && assert "W3: ESCALATE is no longer in the evidence backstop's allow-list" "fail" \
  || assert "W3: ESCALATE is no longer in the evidence backstop's allow-list" "pass"
grep -q 'CHAIN_EVIDENCE_WORK_GUARD' "$RG" && grep -q 'CHAIN_ESCALATE_FORCES_FULL' "$RG" \
  && assert "W4: both knobs present in run-goal.sh" "pass" \
  || assert "W4: both knobs present in run-goal.sh" "fail"
_esc=$(grep -n 'depth_escalate_override' "$RG" | head -1 | cut -d: -f1)
_cad=$(grep -n 'SPEED-4 hardening-cadence backstop' "$RG" | head -1 | cut -d: -f1)
[[ -n "$_esc" && -n "$_cad" && -n "$_bs" && "$_esc" -lt "$_cad" && "$_cad" -lt "$_bs" ]] \
  && assert "W5: ordering escalate-promotion < cadence backstop < evidence backstop" "pass" \
  || assert "W5: ordering escalate-promotion < cadence backstop < evidence backstop (esc=$_esc cad=$_cad bs=$_bs)" "fail"
_h76=$(grep -n 'EVIDENCE_MODE_REFUSED_EXIT_CODE' "$RG" | head -1 | cut -d: -f1)
_h70=$(grep -n 'if \[\[ "\$_exec_rc" -eq "\${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}" \]\]' "$RG" | head -1 | cut -d: -f1)
[[ -n "$_h76" && -n "$_h70" && "$_h76" -lt "$_h70" ]] \
  && assert "W6: the exit-76 belt handler precedes the executor exit-70 check" "pass" \
  || assert "W6: exit-76 handler precedes the exit-70 check (h76=$_h76 h70=$_h70)" "fail"
grep -q 'EVIDENCE mode: skipping developer' "$LEAN" && grep -q 'EVIDENCE mode: skipping reviewer' "$LEAN" \
  && assert "W7: grep-pinned evidence-mode log substrings preserved for test-evidence-depth.sh" "pass" \
  || assert "W7: grep-pinned evidence-mode log substrings preserved" "fail"
grep -q '_review_not_dispatched' "$LEAN" \
  && assert "W8: goal-iter-lean.sh defines the evidence-only review status predicate" "pass" \
  || assert "W8: goal-iter-lean.sh defines _review_not_dispatched" "fail"

# ── Part X: the REAL executor in a sandbox ────────────────────────────────────
echo "== X. executor"
SBX="$WORK/proj"
mkdir -p "$SBX"
cp -r "$ENGINE_ROOT/scripts" "$SBX/"
mkdir -p "$SBX/docs/phases" "$SBX/docs/handoffs" "$SBX/reports/reviews" "$SBX/src" "$SBX/.claude/agents"
touch "$SBX/.claude/agents/developer.md"
git init -q "$SBX"
echo "print('v1')" > "$SBX/src/app.py"
cat > "$SBX/docs/goal.md" <<'EOF2'
# Goal
## Must-have user journeys
- **J-01: Old chapter readable**
  - Steps:
    1. Visit /backtests
  - Acceptance: the list renders
- **J-02: Inspect one instance**
  - Steps:
    1. Visit /backtests/policy
  - Acceptance: facts render
- **J-03: Trace a position**
  - Steps:
    1. Visit /backtests/policy
  - Acceptance: trace renders
- **J-04: Replay a portfolio**
  - Steps:
    1. Visit /backtests
  - Acceptance: run detail renders
- **J-05: Read the contract**
  - Steps:
    1. Visit /docs
  - Acceptance: docs render
## Anti-goals
- none
EOF2
git -C "$SBX" add -A
git -C "$SBX" -c user.email=t@t -c user.name=t commit -qm base

export GOAL_SESSION_DIR="$SBX/runs/goal-session-hardtest"
export GOAL_SESSION_ID="hardtest"
mkdir -p "$GOAL_SESSION_DIR/state"
cp "$SESS/state/journey-history.json" "$GOAL_SESSION_DIR/state/journey-history.json"

# Ports: pinned so the lean script's port sweep never touches anything real.
BE_PORT=48331; FE_PORT=48332
export CHAIN_BACKEND_PORT="$BE_PORT" CHAIN_FRONTEND_PORT="$FE_PORT" CHAIN_KILL_GRACE_SECONDS=1
export CHAIN_LEAN_PARALLEL_BROWSER_QA=off CHAIN_LEAN_PARALLEL_COHERENCE=false CHAIN_REGRESSION_REPLAY=false
SRV_DIR="$WORK/srv"; mkdir -p "$SRV_DIR"; echo ok > "$SRV_DIR/index.html"
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

# Role-aware stub claude: records the agent to the canary; developer/reviewer
# behave per STUB_* env; every other agent exits 70 (transport pause) so the
# executor stops right after the dispatch under test.
STUB_DIR="$WORK/bin"; mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<'EOF2'
#!/usr/bin/env bash
agent="${CHAIN_CURRENT_AGENT:-unknown}"
prompt="$*"
echo "$agent" >> "$CANARY"
case "$agent" in
  developer)
    if [[ "$prompt" == *"FIX MODE"* ]]; then exit 70; fi
    out="$(printf '%s\n' "$prompt" | sed -n 's/^- Write dev handoff to: //p' | head -n1)"
    [[ -n "$out" ]] || exit 64
    echo "print('v2 built by stub')" > src/app.py
    printf 'handoff: implemented the iter spec (stub).\n' > "$out"
    exit 0 ;;
  reviewer)
    out="$(printf '%s\n' "$prompt" | sed -n 's/^Write your review report to: //p' | head -n1)"
    [[ -n "$out" ]] || exit 64
    if [[ "${STUB_REVIEW_MODE:-verdict}" == "status-file" ]]; then
      printf '**Review status:** NOT_DISPATCHED\n\nA reviewer that wrote this line by mistake.\n' > "$out"
    else
      printf '**Verdict:** %s\n\nStub review.\n' "${STUB_REVIEW_VERDICT:-PASS}" > "$out"
    fi
    exit 0 ;;
esac
exit 70
EOF2
chmod +x "$STUB_DIR/claude"

set_iter() {  # set_iter <n> <spec-writer> [depth]
  ITER="goal-hardtest-iter-$1"
  export GOAL_ITER_INDEX="$1" GOAL_ITER_NAME="$ITER"
  ITER_DIR="$GOAL_SESSION_DIR/iter-$1"; rm -rf "$ITER_DIR"; mkdir -p "$ITER_DIR"
  "$2" "$SBX/docs/phases/$ITER.md" "${3:-}"
  DEV_HANDOFF="$SBX/docs/handoffs/${ITER}-dev.md"
  REVIEW_REPORT="$SBX/reports/reviews/${ITER}-review.md"
  rm -f "$DEV_HANDOFF" "$REVIEW_REPORT" "$SBX/reports/phase-${ITER}-ui-test-results.md"
  rm -f "$GOAL_SESSION_DIR/telemetry.jsonl"
  CANARY="$WORK/canary-$1.log"; : > "$CANARY"; export CANARY
  git -C "$SBX" checkout -q -- src/app.py 2>/dev/null || true
}
run_lean() {  # run_lean <log> [env...]
  local log="$1"; shift
  start_dummies
  ( cd "$SBX" && env PATH="$STUB_DIR:$PATH" "$@" bash scripts/automation/goal-iter-lean.sh "$ITER" ) >"$log" 2>&1
}

# X1 — executor refuses an evidence dispatch for a spec that plans work.
set_iter 7 write_iter7_spec lean
rc=0; run_lean "$WORK/x1.log" CHAIN_LEAN_EVIDENCE_ONLY=true || rc=$?
[[ "$rc" -eq 76 ]] \
  && assert "X1: evidence dispatch of the iter-7 spec is REFUSED with exit 76" "pass" \
  || assert "X1: evidence dispatch refused with exit 76 (rc=$rc; $(grep -m1 -i 'refus\|error' "$WORK/x1.log" | cut -c1-160))" "fail"
[[ ! -s "$CANARY" ]] \
  && assert "X1b: no agent was dispatched before the refusal" "pass" \
  || assert "X1b: no agent dispatched before the refusal (canary: $(tr '\n' ' ' < "$CANARY"))" "fail"
[[ ! -f "$DEV_HANDOFF" && ! -f "$REVIEW_REPORT" ]] \
  && assert "X1c: no dev handoff and no review artifact were written" "pass" \
  || assert "X1c: no dev handoff / review artifact written" "fail"
[[ -f "$ITER_DIR/evidence-mode-refused" ]] && grep -q 'reason=implementation-work-in-spec' "$ITER_DIR/evidence-mode-refused" \
  && assert "X1d: iter-<N>/evidence-mode-refused marker records the reason" "pass" \
  || assert "X1d: evidence-mode-refused marker with reason" "fail"
grep -q '"event": *"evidence_mode_refused"' "$GOAL_SESSION_DIR/telemetry.jsonl" 2>/dev/null \
  && assert "X1e: telemetry evidence_mode_refused emitted" "pass" \
  || assert "X1e: telemetry evidence_mode_refused emitted" "fail"

# X2 — a genuine evidence-only iteration runs capture-only with honest artifacts.
set_iter 9 write_iter9_spec evidence
rc=0; run_lean "$WORK/x2.log" CHAIN_LEAN_EVIDENCE_ONLY=true || rc=$?
[[ "$rc" -eq 70 ]] \
  && assert "X2: genuine evidence-only iteration proceeds to the browser lane (pauses on the stub's transport 70)" "pass" \
  || assert "X2: genuine evidence-only proceeds (rc=$rc; $(grep -m2 -iE 'skipp|refus|error' "$WORK/x2.log" | tr '\n' ' ' | cut -c1-220))" "fail"
[[ "$(sort -u "$CANARY" | tr '\n' ' ' | xargs)" == "browser-qa-agent" ]] \
  && assert "X2b: only browser-qa-agent was dispatched (no developer, no reviewer)" "pass" \
  || assert "X2b: only browser-qa-agent dispatched (canary: $(tr '\n' ' ' < "$CANARY"))" "fail"
grep -q 'NOT_DISPATCHED' "$DEV_HANDOFF" 2>/dev/null \
  && assert "X2c: dev handoff states NOT_DISPATCHED" "pass" \
  || assert "X2c: dev handoff states NOT_DISPATCHED" "fail"
grep -qE '^\*\*Review status:\*\* NOT_DISPATCHED' "$REVIEW_REPORT" 2>/dev/null \
  && assert "X2d: review artifact carries '**Review status:** NOT_DISPATCHED'" "pass" \
  || assert "X2d: review artifact carries the explicit status" "fail"
grep -qE '^\*\*Verdict:\*\*' "$REVIEW_REPORT" 2>/dev/null \
  && assert "X2e: evidence-only review artifact contains NO verdict line" "fail" \
  || assert "X2e: evidence-only review artifact contains NO verdict line" "pass"
grep -q 'running developer in fix mode' "$WORK/x2.log" \
  && assert "X2f: the fix-mode retry did not fire on the evidence-only iteration" "fail" \
  || assert "X2f: the fix-mode retry did not fire on the evidence-only iteration" "pass"
python3 "$ENGINE_ROOT/scripts/automation/lib/artifact_schemas.py" validate "$REVIEW_REPORT" >/dev/null 2>&1 \
  && assert "X2g: artifact_schemas.py accepts the evidence-only review status artifact" "pass" \
  || assert "X2g: artifact_schemas.py accepts the evidence-only review status artifact" "fail"
_ss="$(grep '"event": *"step_skipped"' "$GOAL_SESSION_DIR/telemetry.jsonl" 2>/dev/null)"
printf '%s' "$_ss" | grep -q '"reason": *"evidence-mode"' && ! printf '%s' "$_ss" | grep -q '"reason": *"checkpoint"' \
  && assert "X2h: step_skipped events carry reason=evidence-mode (never 'checkpoint')" "pass" \
  || assert "X2h: step_skipped reasons honest (got: $(printf '%s' "$_ss" | tr '\n' ' ' | cut -c1-200))" "fail"
grep '"event": *"iter_dispatch"' "$GOAL_SESSION_DIR/telemetry.jsonl" 2>/dev/null | grep -q '"depth": *"evidence"' \
  && assert "X2i: iter_dispatch reports depth=evidence" "pass" \
  || assert "X2i: iter_dispatch reports depth=evidence" "fail"

# X3 — real-review parsing unchanged (fixture files through the real helpers).
for v in PASS PASS_WITH_NOTES FAIL; do
  printf '**Verdict:** %s\n\nreal review\n' "$v" > "$WORK/rv-$v.md"
done
printf 'no verdict, no status\n' > "$WORK/rv-none.md"
( source "$ENGINE_ROOT/scripts/automation/lib/common.sh" 2>/dev/null
  a=0; verdict_passes "$WORK/rv-PASS.md" || a=$?
  b=0; verdict_passes "$WORK/rv-PASS_WITH_NOTES.md" || b=$?
  c=0; verdict_passes "$WORK/rv-FAIL.md" || c=$?
  d=0; verdict_passes "$WORK/rv-none.md" || d=$?
  echo "$a $b $c $d" ) > "$WORK/vp.out" 2>/dev/null
[[ "$(cat "$WORK/vp.out")" == "0 0 1 1" ]] \
  && assert "X3: verdict_passes unchanged for PASS / PASS_WITH_NOTES / FAIL / verdict-less" "pass" \
  || assert "X3: verdict_passes unchanged (got '$(cat "$WORK/vp.out")')" "fail"
cp "$WORK/rv-none.md" "$SBX/reports/reviews/goal-hardtest-iter-99-review.md"
python3 "$ENGINE_ROOT/scripts/automation/lib/artifact_schemas.py" validate "$SBX/reports/reviews/goal-hardtest-iter-99-review.md" >/dev/null 2>&1 \
  && assert "X3b: a verdict-less review file WITHOUT the explicit status is still rejected by the schema" "fail" \
  || assert "X3b: a verdict-less review file WITHOUT the explicit status is still rejected by the schema" "pass"

# X4 — NO bypass in normal mode: a normal lean run whose reviewer writes the
# status line is a review failure (fix mode fires), never a legal skip.
set_iter 8 write_iter7_spec lean
rc=0; run_lean "$WORK/x4.log" STUB_REVIEW_MODE=status-file || rc=$?
grep -q 'running developer in fix mode' "$WORK/x4.log" \
  && assert "X4: normal lean + 'Review status: NOT_DISPATCHED' -> treated as review failure, fix mode fires" "pass" \
  || assert "X4: normal lean + status file -> fix mode fires (rc=$rc; canary: $(tr '\n' ' ' < "$CANARY"))" "fail"
[[ "$(grep -c '^developer$' "$CANARY")" -ge 2 ]] \
  && assert "X4b: the fix-mode developer was re-dispatched (second developer dispatch on the canary)" "pass" \
  || assert "X4b: fix-mode developer re-dispatched (canary: $(tr '\n' ' ' < "$CANARY"))" "fail"
grep '"event": *"review_verdict"' "$GOAL_SESSION_DIR/telemetry.jsonl" 2>/dev/null | grep -q '"verdict": *""' \
  && assert "X4c: review_verdict telemetry recorded an EMPTY verdict (not a pass)" "pass" \
  || assert "X4c: review_verdict recorded empty verdict ($(grep 'review_verdict' "$GOAL_SESSION_DIR/telemetry.jsonl" 2>/dev/null | head -1 | cut -c1-160))" "fail"
[[ ! -f "$ITER_DIR/.steps/review-1.done" ]] \
  && assert "X4d: review-1 checkpoint was not marked as a passing review" "pass" \
  || assert "X4d: review-1 checkpoint not marked (marker exists)" "fail"

# X5 — rollback knob: the belt is disarmed, the old (dangerous) behaviour returns.
set_iter 7 write_iter7_spec lean
rc=0; run_lean "$WORK/x5.log" CHAIN_LEAN_EVIDENCE_ONLY=true CHAIN_EVIDENCE_WORK_GUARD=false || rc=$?
[[ "$rc" -eq 70 && "$(sort -u "$CANARY" | tr '\n' ' ' | xargs)" == "browser-qa-agent" ]] \
  && assert "X5: CHAIN_EVIDENCE_WORK_GUARD=false disarms the executor belt (proceeds to browser-qa)" "pass" \
  || assert "X5: rollback knob disarms the belt (rc=$rc canary: $(tr '\n' ' ' < "$CANARY"))" "fail"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
