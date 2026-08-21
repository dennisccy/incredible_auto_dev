#!/usr/bin/env bash
# test-maintenance-isolation.sh — full review depth WITHOUT application services.
#
# THE PROBLEM: "full depth" and "boot the app" were the same thing. Four separate
# mechanisms conspire to start services/browsers for a backend-only maintenance
# iteration, verified against the implementation:
#   1. detect_frontend_in_plan force-returns 0 whenever CHAIN_GOAL_TARGET_JOURNEYS
#      is non-empty — overriding a spec's "Frontend Present: no";
#   2. run-phase.sh's post-dev fanout calls _boot_shared_services (backend +
#      frontend start commands, QA_FRONTEND_REQUIRED=yes);
#   3. browser-qa-phase.sh drives the deterministic replay lane, whose partitioner
#      routes TARGET journeys as well as Required-still-passing ones — so an empty
#      required set does NOT make an iteration replay-safe;
#   4. qa-phase.sh self-boots the backend via ensure_services_running (and also
#      registers it as the quota-retry pre-hook), independent of any frontend.
# For a repair iteration on a damaged database — where backend boot warmup itself
# writes derived rows — that is a correctness hazard.
#
# Under test: goal_maintenance_isolation_required (lib/common.sh) as the single
# shared predicate, plus fail-closed refusals at every forbidden path. Default OFF.
#
# Host-safe by construction: no service, browser, or engine is started. Behaviour
# is proven by executing the real predicate and the real ensure_services_running
# chokepoint, and by structural assertions for the branch wiring.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
A="$ENGINE_ROOT/scripts/automation"
RP="$A/run-phase.sh"; QA="$A/qa-phase.sh"; BQA="$A/browser-qa-phase.sh"
RL="$A/lib/replay-lane.sh"; DEMO="$A/demo-phase.sh"; CM="$A/lib/common.sh"

PASS=0; FAIL=0
assert() { if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
source "$CM"
unset CHAIN_MAINTENANCE_ISOLATION CHAIN_GOAL_TARGET_JOURNEYS || true

SPEC_PLAIN="$WORK/plain.md"; SPEC_ISO="$WORK/iso.md"; PLAN_NO="$WORK/plan-no.md"
printf -- '- **Depth:** full\n- **Frontend Present:** no\n' > "$SPEC_PLAIN"
printf -- '- **Depth:** full\n- **Maintenance isolation:** required\n' > "$SPEC_ISO"
printf -- 'Frontend Present: no\n' > "$PLAN_NO"

# ── predicate: default OFF, both declaration forms ────────────────────────────
goal_maintenance_isolation_required "$SPEC_PLAIN" \
  && assert "default OFF: an ordinary spec does not activate isolation" "fail" \
  || assert "default OFF: an ordinary spec does not activate isolation" "pass"
goal_maintenance_isolation_required "$SPEC_ISO" \
  && assert "spec marker: 'Maintenance isolation: required' activates" "pass" \
  || assert "spec marker: 'Maintenance isolation: required' activates" "fail"
( CHAIN_MAINTENANCE_ISOLATION=true; goal_maintenance_isolation_required "$SPEC_PLAIN" ) \
  && assert "env: CHAIN_MAINTENANCE_ISOLATION activates session-wide" "pass" \
  || assert "env: CHAIN_MAINTENANCE_ISOLATION activates session-wide" "fail"

# ── 1/2. target-journey frontend forcing: preserved, then subordinated ────────
( CHAIN_GOAL_TARGET_JOURNEYS="J-10"; detect_frontend_in_plan "$PLAN_NO" ) 2>/dev/null \
  && assert "ordinary + target journey + 'Frontend Present: no' -> browser forcing PRESERVED" "pass" \
  || assert "ordinary + target journey + 'Frontend Present: no' -> browser forcing PRESERVED" "fail"
( CHAIN_GOAL_TARGET_JOURNEYS="J-10"; CHAIN_MAINTENANCE_ISOLATION=true; detect_frontend_in_plan "$PLAN_NO" ) 2>/dev/null \
  && assert "isolated + target journey -> frontend NOT forced" "fail" \
  || assert "isolated + target journey -> frontend NOT forced" "pass"
# isolation only ever REMOVES execution: an explicit yes plan is still not forced ON by isolation
printf -- 'Frontend Present: yes\n' > "$WORK/plan-yes.md"
( CHAIN_MAINTENANCE_ISOLATION=true; detect_frontend_in_plan "$WORK/plan-yes.md" ) 2>/dev/null \
  && assert "isolation never ADDS execution: even a 'yes' plan is withheld under isolation" "fail" \
  || assert "isolation never ADDS execution: even a 'yes' plan is withheld under isolation" "pass"

# ── 4/5/6. service boot is structurally impossible (real chokepoint executed) ──
_svc() { # -> "<backend_up>:<frontend_up>:<rc>"
  ( set +e
    export QA_BACKEND_HEALTH_URL="http://127.0.0.1:9/health"
    export QA_BACKEND_START_CMD="$WORK/never-run.sh"
    export QA_FRONTEND_URL="http://127.0.0.1:9"
    export QA_FRONTEND_START_CMD="$WORK/never-run.sh"
    export QA_FRONTEND_REQUIRED="yes"
    export ITER_DIR="$WORK/iter"
    [[ -n "${1:-}" ]] && export CHAIN_MAINTENANCE_ISOLATION="$1"
    ensure_services_running >/dev/null 2>&1; rc=$?
    printf '%s:%s:%s' "${QA_BACKEND_UP}" "${QA_FRONTEND_UP}" "$rc" )
}
printf '#!/bin/sh\ntouch "%s/SERVICE_STARTED"\n' "$WORK" > "$WORK/never-run.sh"; chmod +x "$WORK/never-run.sh"
rm -f "$WORK/SERVICE_STARTED"
r="$(_svc true)"
[[ "$r" == "no:no:1" ]] \
  && assert "isolation: ensure_services_running REFUSES (backend=no frontend=no, rc=1)" "pass" \
  || assert "isolation: ensure_services_running REFUSES (got '$r')" "fail"
[[ ! -e "$WORK/SERVICE_STARTED" ]] \
  && assert "isolation: backend start count = 0 (start command never executed)" "pass" \
  || assert "isolation: backend start count = 0 (start command never executed)" "fail"
[[ ! -e "$WORK/SERVICE_STARTED" ]] \
  && assert "isolation: frontend start count = 0 (start command never executed)" "pass" \
  || assert "isolation: frontend start count = 0 (start command never executed)" "fail"
[[ -s "$WORK/iter/maintenance-isolation-refusals" ]] \
  && assert "fail-closed: the refusal is RECORDED to an explicit marker, not silent" "pass" \
  || assert "fail-closed: the refusal is RECORDED to an explicit marker, not silent" "fail"

# 13. ordinary iterations unchanged — the chokepoint still attempts a real boot.
# Bounded: the sentinel fires the instant the start command is spawned, so we poll
# briefly and kill rather than waiting out the real 45s x 2 health-retry ladder.
rm -f "$WORK/SERVICE_STARTED"
( _svc "" >/dev/null 2>&1 ) & _ctl_pid=$!
for _i in $(seq 1 40); do [[ -e "$WORK/SERVICE_STARTED" ]] && break; sleep 0.25; done
kill -TERM "$_ctl_pid" 2>/dev/null || true; wait "$_ctl_pid" 2>/dev/null || true
pkill -P "$_ctl_pid" 2>/dev/null || true
[[ -e "$WORK/SERVICE_STARTED" ]] \
  && assert "ordinary: ensure_services_running still attempts the real service boot" "pass" \
  || assert "ordinary: ensure_services_running still attempts the real service boot" "fail"

# ── 4. shared fanout boot blocked, and start cmds withheld ────────────────────
_bs="$(grep -n '_boot_shared_services()' "$RP" | cut -d: -f1)"
awk "NR>=$_bs && NR<=$((_bs+14))" "$RP" | grep -q 'goal_maintenance_isolation_required' \
  && assert "isolation: _boot_shared_services refuses before wiring any start command" "pass" \
  || assert "isolation: _boot_shared_services refuses before wiring any start command" "fail"
awk "NR>=$_bs && NR<=$((_bs+14))" "$RP" | grep -q 'unset QA_BACKEND_START_CMD QA_FRONTEND_START_CMD' \
  && assert "isolation: start commands are UNSET, so a later self-boot has nothing to run" "pass" \
  || assert "isolation: start commands are UNSET, so a later self-boot has nothing to run" "fail"

# ── 7. browser QA blocked before any probe/dispatch ───────────────────────────
_g="$(grep -n 'goal_maintenance_isolation_required "\$SPEC"' "$BQA" | head -1 | cut -d: -f1)"
_run="$(grep -n 'Running browser QA for' "$BQA" | head -1 | cut -d: -f1)"
[[ -n "$_g" && -n "$_run" && "$_g" -lt "$_run" ]] \
  && assert "isolation: browser-qa refuses BEFORE probing services or dispatching" "pass" \
  || assert "isolation: browser-qa refuses BEFORE probing services or dispatching" "fail"
awk "NR>=$_g && NR<=$((_g+30))" "$BQA" | grep -q 'Browser QA Verdict:\*\* SKIPPED' \
  && assert "isolation: browser-qa writes an honest SKIPPED artifact (contract, not gap)" "pass" \
  || assert "isolation: browser-qa writes an honest SKIPPED artifact (contract, not gap)" "fail"
awk "NR>=$_g && NR<=$((_g+34))" "$BQA" | grep -q '^  exit 0$' \
  && assert "isolation: browser-qa exits before the replay call site" "pass" \
  || assert "isolation: browser-qa exits before the replay call site" "fail"

# ── 8. deterministic replay blocked at the function itself ────────────────────
_rl="$(grep -n '^replay_lane_partition_and_verify()' "$RL" | cut -d: -f1)"
awk "NR>=$_rl && NR<=$((_rl+14))" "$RL" | grep -q 'maintenance_isolation_refuse' \
  && assert "isolation: replay_lane_partition_and_verify refuses at entry (target-journey routing irrelevant)" "pass" \
  || assert "isolation: replay_lane_partition_and_verify refuses at entry" "fail"

# ── 9. demo / browser showcase blocked ───────────────────────────────────────
grep -q 'maintenance_isolation_refuse "demo_runner"' "$DEMO" \
  && assert "isolation: demo Playwright runner refuses (invocation count = 0)" "pass" \
  || assert "isolation: demo Playwright runner refuses (invocation count = 0)" "fail"
grep -q 'maintenance_isolation_refuse "demo golden auto-derive"' "$DEMO" \
  && assert "isolation: demo golden auto-derive refuses" "pass" \
  || assert "isolation: demo golden auto-derive refuses" "fail"

# ── 10/11. QA survives in static mode; reasoning lanes untouched ──────────────
grep -q 'MAINTENANCE ISOLATION IS ACTIVE' "$QA" \
  && assert "isolation: QA still runs, in explicit no-service static mode" "pass" \
  || assert "isolation: QA still runs, in explicit no-service static mode" "fail"
for kw in 'file-scoped' 'READ-ONLY' 'mutation accounting'; do
  grep -q "$kw" "$QA" \
    && assert "static QA retains capability: $kw" "pass" \
    || assert "static QA retains capability: $kw" "fail"
done
grep -q 'not skipped by accident' "$QA" \
  && assert "static QA must report the restriction as contract, not accident" "pass" \
  || assert "static QA must report the restriction as contract, not accident" "fail"
grep -q 'do NOT fabricate browser evidence\|Do NOT fabricate browser evidence' "$QA" \
  && assert "static QA is forbidden from fabricating browser evidence" "pass" \
  || assert "static QA is forbidden from fabricating browser evidence" "fail"
# developer/reviewer/auditor/coherence/evaluator are never gated by the predicate
if grep -rn "goal_maintenance_isolation_required" "$A" | grep -qE '(developer|reviewer|auditor|coherence|evaluator)-phase'; then
  assert "isolation does NOT gate developer/reviewer/auditor/coherence/evaluator" "fail"
else
  assert "isolation does NOT gate developer/reviewer/auditor/coherence/evaluator" "pass"
fi

# ── 6. single source of truth ────────────────────────────────────────────────
[[ "$(grep -rc 'Maintenance\[ -\]isolation' "$A" 2>/dev/null | awk -F: '{s+=$2} END{print s}')" == "1" ]] \
  && assert "one parser only: the marker regex exists in exactly one place" "pass" \
  || assert "one parser only: the marker regex exists in exactly one place" "fail"

# ══════════════════════════════════════════════════════════════════════════════
# PROPAGATION: the spec marker ALONE must activate isolation across the real
# wrapper→child boundary, with NO manually-set environment variable.
#
# This is the case the earlier suite missed. Most chokepoints are called with no
# spec path and can only read the environment, so a spec could declare isolation
# and still have services booted beneath it.
# ══════════════════════════════════════════════════════════════════════════════
SPEC_ITER9="$WORK/iter9.md"
cat > "$SPEC_ITER9" <<'SPEC'
- **Depth:** full
- **Depth enforcement:** required
- **Frontend Present:** no
- **Maintenance isolation:** required
- **Target journeys:** J-10
- **Required-still-passing journeys:** None
SPEC

# 1/2. materialization from the spec alone (no env pre-set)
r="$( unset CHAIN_MAINTENANCE_ISOLATION CHAIN_MAINTENANCE_ISOLATION_SOURCE
      apply_maintenance_isolation_from_spec "$SPEC_ITER9" >/dev/null 2>&1
      printf '%s' "${CHAIN_MAINTENANCE_ISOLATION:-unset}" )"
[[ "$r" == "true" ]] \
  && assert "propagation: spec marker ALONE exports CHAIN_MAINTENANCE_ISOLATION=true" "pass" \
  || assert "propagation: spec marker ALONE exports CHAIN_MAINTENANCE_ISOLATION=true (got '$r')" "fail"

# 3. real child-process inheritance across a fork
r="$( unset CHAIN_MAINTENANCE_ISOLATION CHAIN_MAINTENANCE_ISOLATION_SOURCE
      apply_maintenance_isolation_from_spec "$SPEC_ITER9" >/dev/null 2>&1
      bash -c 'printf "%s" "${CHAIN_MAINTENANCE_ISOLATION:-unset}"' )"
[[ "$r" == "true" ]] \
  && assert "propagation: a forked CHILD SHELL inherits isolation (real env inheritance)" "pass" \
  || assert "propagation: a forked CHILD SHELL inherits isolation (got '$r')" "fail"

# 4. no stale leakage into a later ordinary iteration
r="$( unset CHAIN_MAINTENANCE_ISOLATION CHAIN_MAINTENANCE_ISOLATION_SOURCE
      apply_maintenance_isolation_from_spec "$SPEC_ITER9" >/dev/null 2>&1
      apply_maintenance_isolation_from_spec "$SPEC_PLAIN" >/dev/null 2>&1
      printf '%s' "${CHAIN_MAINTENANCE_ISOLATION:-unset}" )"
[[ "$r" == "unset" ]] \
  && assert "no leakage: an isolated iteration does NOT leak into the next ordinary one" "pass" \
  || assert "no leakage: an isolated iteration does NOT leak into the next ordinary one (got '$r')" "fail"

# an operator's session-level declaration must NOT be wiped by an ordinary spec
r="$( export CHAIN_MAINTENANCE_ISOLATION=true; unset CHAIN_MAINTENANCE_ISOLATION_SOURCE
      apply_maintenance_isolation_from_spec "$SPEC_PLAIN" >/dev/null 2>&1
      printf '%s' "${CHAIN_MAINTENANCE_ISOLATION:-unset}" )"
[[ "$r" == "true" ]] \
  && assert "no leakage: an operator's session-level isolation survives an ordinary spec" "pass" \
  || assert "no leakage: an operator's session-level isolation survives an ordinary spec (got '$r')" "fail"

# ── WRAPPER → CHILD END-TO-END DRY RUN (the most important new test) ──────────
# spec → wrapper materializes → child inherits → chokepoints observe isolation.
# Sentinels prove zero service side effects. No agent, no real service, no browser.
E2E="$WORK/e2e"; mkdir -p "$E2E"
printf '#!/bin/sh\ntouch "%s/BACKEND_STARTED"\n' "$E2E" > "$E2E/start-backend.sh"
printf '#!/bin/sh\ntouch "%s/FRONTEND_STARTED"\n' "$E2E" > "$E2E/start-frontend.sh"
chmod +x "$E2E/start-backend.sh" "$E2E/start-frontend.sh"
cat > "$E2E/child.sh" <<'CHILD'
#!/usr/bin/env bash
# Stands in for run-phase.sh's children: consults the SAME predicate with no spec
# path, exactly as _boot_shared_services / replay-lane / demo do.
source "$ENGINE_ROOT/scripts/automation/lib/common.sh"
if goal_maintenance_isolation_required; then echo "CHILD_ISOLATION=active"; else echo "CHILD_ISOLATION=inactive"; fi
export QA_BACKEND_HEALTH_URL="http://127.0.0.1:9/health"
export QA_BACKEND_START_CMD="$E2E_DIR/start-backend.sh"
export QA_FRONTEND_URL="http://127.0.0.1:9"
export QA_FRONTEND_START_CMD="$E2E_DIR/start-frontend.sh"
export QA_FRONTEND_REQUIRED=yes
ensure_services_running >/dev/null 2>&1 || true
CHILD
chmod +x "$E2E/child.sh"

_e2e_out="$( unset CHAIN_MAINTENANCE_ISOLATION CHAIN_MAINTENANCE_ISOLATION_SOURCE
             export ENGINE_ROOT E2E_DIR="$E2E" ITER_DIR="$E2E/iter"
             apply_maintenance_isolation_from_spec "$SPEC_ITER9" >/dev/null 2>&1   # the wrapper step
             bash "$E2E/child.sh" 2>/dev/null )"                                    # the child dispatch
[[ "$_e2e_out" == *"CHILD_ISOLATION=active"* ]] \
  && assert "E2E: spec-only isolation crosses the wrapper→child boundary and the child OBSERVES it" "pass" \
  || assert "E2E: spec-only isolation crosses the wrapper→child boundary (got '$_e2e_out')" "fail"
[[ ! -e "$E2E/BACKEND_STARTED" ]] \
  && assert "E2E: backend start sentinel = 0 across the real boundary" "pass" \
  || assert "E2E: backend start sentinel = 0 across the real boundary" "fail"
[[ ! -e "$E2E/FRONTEND_STARTED" ]] \
  && assert "E2E: frontend start sentinel = 0 across the real boundary" "pass" \
  || assert "E2E: frontend start sentinel = 0 across the real boundary" "fail"

# control: WITHOUT the marker the same child does boot — proving the sentinels work
rm -f "$E2E/BACKEND_STARTED" "$E2E/FRONTEND_STARTED"
( unset CHAIN_MAINTENANCE_ISOLATION CHAIN_MAINTENANCE_ISOLATION_SOURCE
  export ENGINE_ROOT E2E_DIR="$E2E" ITER_DIR="$E2E/iter"
  # `|| true`: the helper returns 1 for a NON-isolated spec, which under the
  # inherited `set -e` would abort this control subshell before the child ran.
  apply_maintenance_isolation_from_spec "$SPEC_PLAIN" >/dev/null 2>&1 || true
  bash "$E2E/child.sh" >/dev/null 2>&1 ) & _ctl2=$!
for _i in $(seq 1 40); do [[ -e "$E2E/BACKEND_STARTED" ]] && break; sleep 0.25; done
kill -TERM "$_ctl2" 2>/dev/null || true; pkill -P "$_ctl2" 2>/dev/null || true
wait "$_ctl2" 2>/dev/null || true
[[ -e "$E2E/BACKEND_STARTED" ]] \
  && assert "E2E control: without the marker the SAME child does start the backend (sentinels are real)" "pass" \
  || assert "E2E control: without the marker the SAME child does start the backend" "fail"

# ── wiring: both entry points materialize before dispatch ─────────────────────
_rg_apply="$(grep -n 'apply_maintenance_isolation_from_spec "\$ITER_SPEC_PATH"' "$ENGINE_ROOT/scripts/automation/run-goal.sh" | head -1 | cut -d: -f1)"
_rg_disp="$(grep -n 'Dispatching FULL pipeline via run-phase.sh' "$ENGINE_ROOT/scripts/automation/run-goal.sh" | head -1 | cut -d: -f1)"
[[ -n "$_rg_apply" && -n "$_rg_disp" && "$_rg_apply" -lt "$_rg_disp" ]] \
  && assert "wiring: run-goal materializes isolation BEFORE child dispatch" "pass" \
  || assert "wiring: run-goal materializes isolation BEFORE child dispatch" "fail"
_rp_apply="$(grep -n 'apply_maintenance_isolation_from_spec "\$SPEC"' "$RP" | head -1 | cut -d: -f1)"
_rp_boot="$(grep -n '_boot_shared_services()' "$RP" | head -1 | cut -d: -f1)"
[[ -n "$_rp_apply" && -n "$_rp_boot" && "$_rp_apply" -lt "$_rp_boot" ]] \
  && assert "wiring: standalone run-phase materializes isolation before service logic" "pass" \
  || assert "wiring: standalone run-phase materializes isolation before service logic" "fail"

# ── qa-phase ordering: isolation resolved before ANY service setup ───────────
_qa_iso="$(grep -n 'apply_maintenance_isolation_from_spec "\$SPEC"' "$QA" | head -1 | cut -d: -f1)"
_qa_cmd="$(grep -n 'BACKEND_START_CMD="bash' "$QA" | head -1 | cut -d: -f1)"
_qa_call="$(grep -n '^  ensure_services_running$' "$QA" | head -1 | cut -d: -f1)"
[[ -n "$_qa_iso" && -n "$_qa_cmd" && "$_qa_iso" -lt "$_qa_cmd" ]] \
  && assert "qa ordering: isolation resolved BEFORE any start command is resolved" "pass" \
  || assert "qa ordering: isolation resolved BEFORE any start command is resolved" "fail"
[[ -n "$_qa_iso" && -n "$_qa_call" && "$_qa_iso" -lt "$_qa_call" ]] \
  && assert "qa ordering: isolation resolved BEFORE ensure_services_running" "pass" \
  || assert "qa ordering: isolation resolved BEFORE ensure_services_running" "fail"
grep -q 'Service startup bypassed' "$QA" \
  && assert "qa: isolated path BYPASSES ensure_services_running (not call-and-refuse)" "pass" \
  || assert "qa: isolated path BYPASSES ensure_services_running (not call-and-refuse)" "fail"
awk "/MAINTENANCE_ISOLATION\" == \"yes\"/{f=1} f&&/unset CHAIN_CLAUDE_PRE_RETRY_HOOK/{print;exit}" "$QA" | grep -q unset \
  && assert "qa: isolated path does NOT register the service retry hook" "pass" \
  || assert "qa: isolated path does NOT register the service retry hook" "fail"
grep -q 'prohibited by contract, not unavailable' "$QA" \
  && assert "qa: reports services as prohibited-by-contract, not unavailable" "pass" \
  || assert "qa: reports services as prohibited-by-contract, not unavailable" "fail"

echo ""
echo "  ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
