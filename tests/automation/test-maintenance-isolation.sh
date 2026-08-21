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
# Window covers the entry guard: the fail-closed "predicate undefined" branch
# (below) sits between the function head and the refusal.
awk "NR>=$_rl && NR<=$((_rl+24))" "$RL" | grep -q 'maintenance_isolation_refuse' \
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

# ══════════════════════════════════════════════════════════════════════════════
# INTEGRATION GUARDS — the engine paths an isolated iteration actually reaches.
# Every case below is a place that predates the contract and would otherwise
# report the withheld lane as an infrastructure gap, abort the step outright, or
# execute the app anyway from a context that was built before isolation applied.
# ══════════════════════════════════════════════════════════════════════════════
RG="$A/run-goal.sh"

# ── the N/A stub run-phase.sh writes when the browser lane is gated off ───────
# Under isolation detect_frontend_in_plan returns 1, so run-phase.sh Step 6 takes
# its backend-only branch and browser-qa-phase.sh — with its honest SKIPPED
# artifact — is never entered. The stub it writes instead must not report a
# contract decision as "Backend-only phase (Frontend Present: no)".
NA_ISO="$WORK/na-iso"; NA_ORD="$WORK/na-ord"
( REPO_ROOT="$NA_ISO"; CHAIN_MAINTENANCE_ISOLATION=true
  write_na_ui_artifacts p1 ui-test-results >/dev/null 2>&1 )
_na_iso="$(cat "$NA_ISO/reports/phase-p1-ui-test-results.md" 2>/dev/null || true)"
grep -q '^\*\*Browser QA Verdict:\*\* SKIPPED$' <<<"$_na_iso" \
  && assert "na-stub: the isolated ui-test-results stub is SKIPPED" "pass" \
  || assert "na-stub: the isolated ui-test-results stub is SKIPPED" "fail"
grep -qE '^\*\*Reason:\*\* .*Maintenance isolation' <<<"$_na_iso" \
  && assert "na-stub: it carries a **Reason:** line naming maintenance isolation" "pass" \
  || assert "na-stub: it carries a **Reason:** line naming maintenance isolation" "fail"
grep -qi 'backend-only' <<<"$_na_iso" \
  && assert "na-stub: it never claims 'Backend-only phase' (contract, not absence)" "fail" \
  || assert "na-stub: it never claims 'Backend-only phase' (contract, not absence)" "pass"
( REPO_ROOT="$NA_ORD"; unset CHAIN_MAINTENANCE_ISOLATION
  write_na_ui_artifacts p1 ui-test-results >/dev/null 2>&1 )
grep -qi 'Backend-only phase' "$NA_ORD/reports/phase-p1-ui-test-results.md" \
  && assert "na-stub control: an ordinary backend-only phase keeps its existing wording" "pass" \
  || assert "na-stub control: an ordinary backend-only phase keeps its existing wording" "fail"

# ...and the same holds for the other five: run-phase.sh writes N/A stubs for
# ui-test-plan / what-to-click (Step 5) and the ui-impact pair (Step 4) at the
# same moment, and closure_gate.py iterates all SIX. One honest artifact among
# five "Backend-only phase" stubs is still a phase that reports a contract
# decision as an absent frontend.
NA_ALL="$WORK/na-all"; NA_ALL_ORD="$WORK/na-all-ord"
( REPO_ROOT="$NA_ALL"; CHAIN_MAINTENANCE_ISOLATION=true
  write_na_ui_artifacts p1 >/dev/null 2>&1 )
( REPO_ROOT="$NA_ALL_ORD"; unset CHAIN_MAINTENANCE_ISOLATION
  write_na_ui_artifacts p1 >/dev/null 2>&1 )
_na_bad=""
for _a in implementation-summary user-visible-changes ui-surface-map ui-test-plan what-to-click; do
  _f="$NA_ALL/reports/phase-p1-${_a}.md"
  if ! grep -qi 'maintenance isolation' "$_f" 2>/dev/null; then _na_bad+="${_a}:no-contract-wording "; fi
  if grep -qi 'backend-only' "$_f" 2>/dev/null; then _na_bad+="${_a}:says-backend-only "; fi
done
[[ -z "$_na_bad" ]] \
  && assert "na-stub: all six isolated stubs report the contract, none claims 'Backend-only'" "pass" \
  || assert "na-stub: all six isolated stubs report the contract, none claims 'Backend-only' ($_na_bad)" "fail"
grep -q 'no application service may be started' "$NA_ALL/reports/phase-p1-what-to-click.md" \
  && assert "na-stub: what-to-click states WHY no click path exists (app execution forbidden)" "pass" \
  || assert "na-stub: what-to-click states WHY no click path exists (app execution forbidden)" "fail"
_na_ord_bad=""
for _a in implementation-summary user-visible-changes ui-surface-map ui-test-plan what-to-click; do
  if ! grep -qi 'backend-only' "$NA_ALL_ORD/reports/phase-p1-${_a}.md" 2>/dev/null; then
    _na_ord_bad+="${_a} "
  fi
done
[[ -z "$_na_ord_bad" ]] \
  && assert "na-stub control: the ordinary six keep their existing backend-only wording" "pass" \
  || assert "na-stub control: the ordinary six keep their existing backend-only wording ($_na_ord_bad)" "fail"

# ── the SKIPPED artifact must satisfy the deterministic closure gate ──────────
# closure_gate.py accepts an all-SKIPPED browser-QA file only with a `**Reason:**`
# line or a `## Reason` section; the lane's own heredoc explains itself under a
# different heading, which the gate cannot see. (The end-to-end producer→gate
# case lives in test-closure-gate.sh.)
awk "NR>=$_g && NR<=$((_g+36))" "$BQA" | grep -qE '^\*\*Reason:\*\*' \
  && assert "browser-qa SKIPPED artifact carries the **Reason:** line closure_gate.py requires" "pass" \
  || assert "browser-qa SKIPPED artifact carries the **Reason:** line closure_gate.py requires" "fail"

# ── the refusal marker resolves for chokepoints that never see ITER_DIR ───────
# maintenance_isolation_refuse resolves its marker dir through goal_iter_dir
# (lib/checkpoint.sh, sourced by common.sh itself) and then ITER_DIR. browser-qa,
# demo and the replay lane run as children with the exported GOAL_SESSION_DIR /
# GOAL_ITER_INDEX only, so pin that resolution: a refusal nobody records is a
# silent degrade.
MK="$WORK/mk-sess"
( unset ITER_DIR GOAL_ITER_NAME
  export GOAL_SESSION_DIR="$MK" GOAL_ITER_INDEX=3
  maintenance_isolation_refuse "chokepoint-under-test" "no ITER_DIR in scope" >/dev/null 2>&1 || true )
[[ -s "$MK/iter-3/maintenance-isolation-refusals" ]] \
  && grep -q 'operation=chokepoint-under-test' "$MK/iter-3/maintenance-isolation-refusals" \
  && assert "refusal marker: resolves from exported GOAL_SESSION_DIR/GOAL_ITER_INDEX with ITER_DIR unset" "pass" \
  || assert "refusal marker: resolves from exported GOAL_SESSION_DIR/GOAL_ITER_INDEX with ITER_DIR unset" "fail"

# ── the async showcase tail was forked BEFORE isolation applied ───────────────
# run-goal.sh forks iteration N-1's showcase tail as a subshell carrying the
# pre-isolation environment; demo-phase.sh inside it boots services. Joining it
# normally would therefore start the app during an isolated iteration N, so the
# isolated join reaps it instead of waiting it out.
_sj="$(grep -n '_engine_step_begin "showcase-join"' "$RG" | head -1 | cut -d: -f1)"
_sj_block="$(awk "NR>=$_sj && NR<=$((_sj+18))" "$RG")"
grep -q 'goal_maintenance_isolation_required' <<<"$_sj_block" \
  && assert "showcase-join: the isolated join consults the isolation predicate" "pass" \
  || assert "showcase-join: the isolated join consults the isolation predicate" "fail"
grep -q '_join_showcase_tail --kill' <<<"$_sj_block" \
  && assert "showcase-join: an isolated iteration REAPS the pre-isolation tail instead of waiting for it" "pass" \
  || assert "showcase-join: an isolated iteration REAPS the pre-isolation tail instead of waiting for it" "fail"
grep -q 'kill_phase_servers' <<<"$_sj_block" \
  && assert "showcase-join: --kill returns before the join's own teardown, so servers are cleared explicitly" "pass" \
  || assert "showcase-join: --kill returns before the join's own teardown, so servers are cleared explicitly" "fail"

# ── demo-phase resolves isolation BEFORE its own self-boot ────────────────────
# ensure_services_running refuses under isolation and returns 1; demo-phase.sh
# runs under `set -e`, so a guard placed after the boot block never executes —
# the step dies on the refusal instead of skipping as a documented decision.
_d_iso="$(grep -n 'goal_maintenance_isolation_required' "$DEMO" | head -1 | cut -d: -f1)"
_d_boot="$(grep -n '^  ensure_services_running$' "$DEMO" | head -1 | cut -d: -f1)"
[[ -n "$_d_iso" && -n "$_d_boot" && "$_d_iso" -lt "$_d_boot" ]] \
  && assert "demo ordering: isolation is resolved BEFORE the self-boot block" "pass" \
  || assert "demo ordering: isolation is resolved BEFORE the self-boot block (guard $_d_iso, boot $_d_boot)" "fail"

# Executed for real: the session walkthrough is the mode that reaches the boot
# block (record mode is routed away by detect_frontend_in_plan). Ports are pinned
# so the canonical-port reclaim is a no-op — nothing on this host is touched.
D_SBX="$WORK/demo-sbx"
mkdir -p "$D_SBX/docs/phases" "$D_SBX/reports" "$D_SBX/runs/goal-session-isotest/state"
cp -r "$ENGINE_ROOT/scripts" "$D_SBX/"
printf '#!/bin/sh\ntouch "%s/DEMO_BOOT_ATTEMPTED"\n' "$D_SBX" > "$D_SBX/scripts/start-backend.sh"
printf '#!/bin/sh\ntouch "%s/DEMO_BOOT_ATTEMPTED"\n' "$D_SBX" > "$D_SBX/scripts/start-frontend.sh"
chmod +x "$D_SBX/scripts/start-backend.sh" "$D_SBX/scripts/start-frontend.sh"
_demo_rc=0
_demo_out="$( CHAIN_MAINTENANCE_ISOLATION=true CHAIN_BACKEND_PORT=48351 CHAIN_FRONTEND_PORT=48352 \
              bash "$D_SBX/scripts/automation/demo-phase.sh" isotest --session 2>&1 )" || _demo_rc=$?
[[ "$_demo_rc" -eq 0 ]] \
  && assert "demo under isolation: exits 0 as a documented skip (not an abort)" "pass" \
  || assert "demo under isolation: exits 0 as a documented skip (got rc $_demo_rc)" "fail"
[[ ! -e "$D_SBX/DEMO_BOOT_ATTEMPTED" ]] \
  && assert "demo under isolation: no start command was executed (sentinel count = 0)" "pass" \
  || assert "demo under isolation: no start command was executed (sentinel count = 0)" "fail"
[[ "$(grep -c '^\[demo\] SKIPPED' <<<"$_demo_out")" == "1" ]] \
  && assert "demo under isolation: exactly ONE skip message" "pass" \
  || assert "demo under isolation: exactly ONE skip message (got $(grep -c '^\[demo\] SKIPPED' <<<"$_demo_out"))" "fail"
grep -q 'Playwright not available' <<<"$_demo_out" \
  && assert "demo under isolation: never reports the withheld runner as a missing Playwright install" "fail" \
  || assert "demo under isolation: never reports the withheld runner as a missing Playwright install" "pass"
grep -q 'did not respond after' <<<"$_demo_out" \
  && assert "demo under isolation: never reports the withheld app as an unresponsive frontend" "fail" \
  || assert "demo under isolation: never reports the withheld app as an unresponsive frontend" "pass"

# ── the shared-services flag must stay UNSET under isolation ──────────────────
# _boot_shared_services returns before `export CHAIN_SHARED_SERVICES=true`: no
# shared service exists, and the flag is exactly what makes each child skip its
# own boot AND its own teardown. Executed by slicing the real function out.
_bs_end="$(awk -v s="$_bs" 'NR>s && /^}$/{print NR; exit}' "$RP")"
awk -v s="$_bs" -v e="$_bs_end" 'NR>=s && NR<=e' "$RP" > "$WORK/boot-shared.sh"
r="$( set +e
      # shellcheck disable=SC1090
      . "$WORK/boot-shared.sh"
      export CHAIN_MAINTENANCE_ISOLATION=true ITER_DIR="$WORK/bss-iter"
      unset CHAIN_SHARED_SERVICES
      _boot_shared_services >/dev/null 2>&1
      printf '%s' "${CHAIN_SHARED_SERVICES:-unset}" )"
[[ "$r" == "unset" ]] \
  && assert "fanout: CHAIN_SHARED_SERVICES is NOT exported under isolation (no shared service exists)" "pass" \
  || assert "fanout: CHAIN_SHARED_SERVICES is NOT exported under isolation (got '$r')" "fail"
awk -v s="$_bs" -v e="$_bs_end" 'NR>=s && NR<=e' "$RP" | grep -qi 'CHAIN_SHARED_SERVICES' \
  && assert "fanout: the isolated branch documents why the flag is withheld" "pass" \
  || assert "fanout: the isolated branch documents why the flag is withheld" "fail"

# ── the static-QA brief must say ONE thing ───────────────────────────────────
# The isolated path sets QA_BACKEND_UP=no to keep every downstream probe honest,
# which used to append "the backend did NOT become healthy after retries" plus a
# dependency hint directly beneath the "prohibited by contract, not unavailable"
# note — telling the QA agent the service both was withheld and failed. Executed
# by slicing the real note builder out of qa-phase.sh.
_note_s="$(grep -n 'Build services context note' "$QA" | head -1 | cut -d: -f1)"
_note_e="$(grep -n 'Pre-retry hook' "$QA" | head -1 | cut -d: -f1)"
awk -v s="$_note_s" -v e="$((_note_e-1))" 'NR>=s && NR<=e' "$QA" > "$WORK/qa-note.sh"
_qa_note="$( set +e
             _qa_dep_hint() { echo "STUB-DEP-HINT"; }
             MAINTENANCE_ISOLATION=yes; QA_BACKEND_UP=no; FRONTEND_PRESENT=no
             BACKEND_HEALTH_URL="http://127.0.0.1:9/health"; FRONTEND_URL="http://127.0.0.1:9"
             QA_BACKEND_LOG="$WORK/be.log"; QA_FRONTEND_LOG="$WORK/fe.log"
             QA_BACKEND_LOG_TAIL="STUB-LOG-TAIL"
             # shellcheck disable=SC1090
             . "$WORK/qa-note.sh" >/dev/null 2>&1
             printf '%s' "$SERVICES_NOTE" )"
grep -q 'by contract rather than by circumstance' <<<"$_qa_note" \
  && assert "qa brief: the isolated note states the restriction is a contract decision" "pass" \
  || assert "qa brief: the isolated note states the restriction is a contract decision" "fail"
grep -q 'did NOT become healthy' <<<"$_qa_note" \
  && assert "qa brief: the isolated note does NOT also claim the backend failed to start" "fail" \
  || assert "qa brief: the isolated note does NOT also claim the backend failed to start" "pass"
grep -q 'STUB-DEP-HINT' <<<"$_qa_note" \
  && assert "qa brief: no missing-dependency hint for a service nobody tried to start" "fail" \
  || assert "qa brief: no missing-dependency hint for a service nobody tried to start" "pass"
# control: an ordinary iteration whose backend really did fail still gets told
_qa_note_ord="$( set +e
                 _qa_dep_hint() { echo "STUB-DEP-HINT"; }
                 MAINTENANCE_ISOLATION=no; QA_BACKEND_UP=no; FRONTEND_PRESENT=no
                 BACKEND_HEALTH_URL="http://127.0.0.1:9/health"; FRONTEND_URL="http://127.0.0.1:9"
                 QA_BACKEND_LOG="$WORK/be.log"; QA_FRONTEND_LOG="$WORK/fe.log"
                 QA_BACKEND_LOG_TAIL="STUB-LOG-TAIL"
                 # shellcheck disable=SC1090
                 . "$WORK/qa-note.sh" >/dev/null 2>&1
                 printf '%s' "$SERVICES_NOTE" )"
grep -q 'did NOT become healthy' <<<"$_qa_note_ord" \
  && assert "qa brief control: a real boot failure is still reported for ordinary iterations" "pass" \
  || assert "qa brief control: a real boot failure is still reported for ordinary iterations" "fail"

# ── telemetry: the jq-less fallback keeps the isolation field ─────────────────
# iter_dispatch is the only record of whether an iteration ran isolated; a host
# without jq must not silently drop it.
_it="$(grep -n 'record_telemetry_event "iter_dispatch"' "$RG" | head -1 | cut -d: -f1)"
sed -n "${_it}p" "$RG" > "$WORK/iter-dispatch.sh"
sed -n "${_it}p" "$RG" | grep -q 'maintenance_isolation:\$mi' \
  && assert "telemetry: iter_dispatch records maintenance_isolation on the jq path" "pass" \
  || assert "telemetry: iter_dispatch records maintenance_isolation on the jq path" "fail"
r="$( set +e
      record_telemetry_event() { printf '%s' "$2"; }
      DEPTH="full"; TARGET_JOURNEYS="J-10"; CHAIN_MAINTENANCE_ISOLATION=true
      PATH=""   # jq unreachable -> the printf fallback runs
      # shellcheck disable=SC1090
      . "$WORK/iter-dispatch.sh" )"
[[ "$r" == *'"maintenance_isolation":"true"'* ]] \
  && assert "telemetry: the jq-less fallback still records maintenance_isolation" "pass" \
  || assert "telemetry: the jq-less fallback still records maintenance_isolation (got '$r')" "fail"

# ── replay lane: fail CLOSED when the predicate cannot be evaluated ───────────
# The lane is sourced as a library. `declare -F <predicate> && <predicate>` reads
# "not isolated" when common.sh was never sourced — the one state in which the
# contract cannot be checked at all is the state that used to let the browser run.
cat > "$WORK/rl-nocommon.sh" <<'RLEOF'
#!/usr/bin/env bash
# Deliberately sources ONLY the lane lib: no common.sh, so the isolation
# predicate is undefined — the exact state the guard must fail CLOSED on.
# shellcheck disable=SC1090
source "$RL_PATH"
REQUIRED_JOURNEYS="J-01"
FRONTEND_AVAILABLE="no"
replay_lane_partition_and_verify "iter-x" >/dev/null
printf 'R_LLM=<%s>' "${R_LLM:-}"
RLEOF
_rl_err="$WORK/rl.err"
r="$( cd "$WORK" && RL_PATH="$RL" bash "$WORK/rl-nocommon.sh" 2>"$_rl_err" || true )"
grep -q 'lib/common.sh not sourced' "$_rl_err" \
  && grep -q 'fail closed' "$_rl_err" \
  && assert "replay lane: an unevaluatable contract refuses the lane and says why" "pass" \
  || assert "replay lane: an unevaluatable contract refuses the lane and says why" "fail"
[[ "$r" == "R_LLM=<>" ]] \
  && assert "replay lane: nothing is partitioned or verified when the predicate is unavailable" "pass" \
  || assert "replay lane: nothing is partitioned or verified when the predicate is unavailable (got '$r')" "fail"
# every production caller sources common.sh, so the fail-closed branch is a
# backstop rather than a path any pipeline takes.
grep -q 'source "$SCRIPT_DIR/lib/common.sh"' "$BQA" \
  && grep -q 'source "$SCRIPT_DIR/lib/common.sh"' "$A/goal-iter-lean.sh" \
  && assert "replay lane: both production callers source common.sh (backstop, not a live path)" "pass" \
  || assert "replay lane: both production callers source common.sh (backstop, not a live path)" "fail"

echo ""
echo "  ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
