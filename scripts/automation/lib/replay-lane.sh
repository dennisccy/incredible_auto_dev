#!/usr/bin/env bash
# replay-lane.sh — the deterministic regression-replay lane, shared by BOTH
# goal-mode depths:
#   • lean  — goal-iter-lean.sh (run_browser_qa_boot_and_replay + section merge)
#   • full  — browser-qa-phase.sh (goal-session iterations only; plain phase
#             mode never calls into this file)
#
# ONE implementation, no copy-paste (P2 fix: previously the lane existed only in
# the lean executor, so every FULL goal-mode iteration structurally deferred its
# Required-still-passing re-verification to a follow-up lean pass — five
# evaluator-flagged recurrences and one extra terminal iteration in the
# 43-iteration production session).
#
# The lane, end to end:
#   1. Parse the iteration spec's journey sets (replay_lane_spec_journeys).
#   2. Partition Required-still-passing into replay-able (LINTABLE golden script
#      on file under runs/goal-session-<sid>/journey-scripts/) vs LLM journeys;
#      a golden that fails lint is quarantined (*.json.invalid) and its journey
#      routed to the LLM lane (replay_lane_partition_and_verify).
#   3. Replay the golden set with demo_runner.py --mode verify (no model in the
#      loop). rc contract (demo_runner.py docstring): 0 = all pass; 5 = journey
#      FAIL(s) → REPLAY_FAILED is re-confirmed by the LLM lane (a brittle
#      selector must not fake a regression and halt the session) and is NEVER
#      retried here — re-rolling assertions would mask real regressions; 6 =
#      browser-INFRA failure (launch/crash) → re-check services + retry ONCE
#      (REL-5), a second rc-6 records the lane as SKIPPED-INFRA (raw-artifact
#      verdict line + REPLAY_SKIPPED_INFRA global + telemetry — distinct from
#      FAIL and from the REL-12 frontend-skip) and falls back; any other rc =
#      lane infrastructure failure → no retry, ALL replay journeys fall back
#      to the LLM lane, byte-identical to running with
#      CHAIN_REGRESSION_REPLAY=false.
#   4. Merge replay + LLM results into the single authoritative
#      reports/phase-<iter>-ui-test-results.md the goal-evaluator AND the
#      deterministic achievement gate read (LLM listed last → wins on any
#      journey both lanes touched), then reconcile the raw replay artifact so
#      an overturned replay FAIL cannot survive on disk as a contradiction
#      (replay_lane_merge_results).
#
# Escape hatch: CHAIN_REGRESSION_REPLAY=false routes the whole regression set
# to the LLM lane at both depths (replay_lane_llm_regression_set).
#
# Callers set REPLAY_LANE_TAG so lane log lines keep their script's prefix —
# goal-iter-lean.sh's stdout stays byte-identical (benchmark runs diff
# normalized stdout).
#
# Dataflow is via GLOBALS, deliberately: goal-iter-lean.sh's SPEED-2 fork
# serializes exactly these names through its state file (_bqa_state_save), so
# they are a cross-process contract, not a style choice.
#   In:  REQUIRED_JOURNEYS, FRONTEND_AVAILABLE, FRONTEND_URL, REPO_ROOT,
#        CHAIN_REGRESSION_REPLAY (knob, default true),
#        REPLAY_LANE_CANARY_CAPABLE (SPEED-22; set only by goal-iter-lean.sh)
#   Set by replay_lane_paths: EVIDENCE_DIR, SID, JOURNEY_SCRIPTS_DIR,
#        REGRESSION_RESULTS, LLM_RESULTS, CANARY_RESULTS, DEMO_RUNNER,
#        MERGE_RESULTS
#   Out of partition+verify: R_REPLAY, R_LLM, _use_replay, REPLAY_FAILED,
#        REPLAY_SKIPPED_INFRA, REPLAY_MASS_FAIL, REPLAY_CANARIES (SPEED-22)

_REPLAY_LANE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_replay_lane_log()  { echo "[${REPLAY_LANE_TAG:-replay-lane}] $*"; }
_replay_lane_warn() { echo "[${REPLAY_LANE_TAG:-replay-lane}] $*" >&2; }

# Journey IDs from a spec line, e.g. `replay_lane_spec_journeys 'Target journeys:' "$SPEC"`
# → "J-01 J-03 ". First matching line wins. The `|| true` is load-bearing: a
# journey-less line ("Required-still-passing journeys: none — ...", every
# iteration-0 baseline spec) makes the inner grep exit 1, and every caller runs
# under set -e PLUS pipefail (inherited from sourcing lib/telemetry.sh) —
# without the guard the bare assignment kills the calling script SILENTLY
# (both 20260710/20260712 benchmark iter-0s died exactly there). Empty is a
# legitimate parse result; it must never be an exit.
replay_lane_spec_journeys() {
  grep -iE "$1" "$2" 2>/dev/null | head -1 | grep -oE 'J-[0-9]+' | sort -u | tr '\n' ' ' || true
}

# Lane path derivations for iteration/phase name $1 (goal-<sid>-iter-<N>).
# Every assignment is a pure derivation and the mkdir is idempotent, so
# recomputing in a fork and its parent is safe (single source of truth for the
# forkable unit, the join, and the reap in goal-iter-lean.sh).
replay_lane_paths() {
  local _rl_iter="$1"
  EVIDENCE_DIR="$REPO_ROOT/reports/qa/${_rl_iter}-evidence"
  SID="${_rl_iter#goal-}"; SID="${SID%-iter-*}"
  JOURNEY_SCRIPTS_DIR="$REPO_ROOT/runs/goal-session-${SID}/journey-scripts"
  mkdir -p "$JOURNEY_SCRIPTS_DIR"
  REGRESSION_RESULTS="$REPO_ROOT/reports/phase-${_rl_iter}-regression-replay-results.md"
  LLM_RESULTS="$REPO_ROOT/reports/phase-${_rl_iter}-ui-test-results.llm.md"
  CANARY_RESULTS="$REPO_ROOT/reports/phase-${_rl_iter}-ui-test-results.canary.md"
  DEMO_RUNNER="$_REPLAY_LANE_LIB_DIR/demo_runner.py"
  MERGE_RESULTS="$_REPLAY_LANE_LIB_DIR/merge_ui_test_results.py"
}

# One verify invocation over the golden set — extracted so the REL-5 retry is
# literally the same command. $1 = iter/phase name, $2 = journey csv.
_replay_lane_verify_once() {
  python3 "$DEMO_RUNNER" --mode verify \
    --scripts-dir "$JOURNEY_SCRIPTS_DIR" --journeys "$2" \
    --results "$REGRESSION_RESULTS" --evidence-dir "$EVIDENCE_DIR" \
    --base-url "$FRONTEND_URL" --phase-id "$1" --repo-root "$REPO_ROOT"
}

# REL-5: record the lane state SKIPPED-INFRA after a double browser-infra
# failure. Writes the distinct verdict line onto the RAW replay artifact (the
# goal-evaluator reads only the merged file — its body names the raw file "a
# lane artifact, not an input" — so this line is for humans, retro, and the
# eval fixtures), appends a dated footer explaining the routing, sets the
# REPLAY_SKIPPED_INFRA global (serialized across the SPEED-2 fork boundary by
# goal-iter-lean.sh's _bqa_state_save), and emits a telemetry event. Called
# while R_REPLAY still names the affected journeys. $1 = iter/phase name.
_replay_lane_mark_skipped_infra() {
  local _rl_iter="$1"
  REPLAY_SKIPPED_INFRA="yes"
  _replay_lane_warn "Replay lane verdict: SKIPPED-INFRA — browser-infra failure persisted after one retry (rc=6 twice); ALL replay journeys fall back to the LLM lane."
  local _tmp="$REGRESSION_RESULTS.tmp.$$"
  if [[ -f "$REGRESSION_RESULTS" ]]; then
    if awk 'BEGIN{done=0} /^\*\*Browser QA Verdict:\*\*/ && !done {print "**Browser QA Verdict:** SKIPPED-INFRA"; done=1; next} {print}' \
        "$REGRESSION_RESULTS" > "$_tmp" 2>/dev/null; then
      mv -f "$_tmp" "$REGRESSION_RESULTS" 2>/dev/null || rm -f "$_tmp" 2>/dev/null || true
    else
      rm -f "$_tmp" 2>/dev/null || true
    fi
  else
    # Defensive: the real runner writes the file before exiting 6; if it could
    # not, record the state anyway — absent beats silent.
    printf '**Browser QA Verdict:** SKIPPED-INFRA\n' > "$REGRESSION_RESULTS" 2>/dev/null || true
  fi
  {
    echo ""
    echo "---"
    echo ""
    echo "_SKIPPED-INFRA ($(date -u +%Y-%m-%d)): the deterministic replay lane hit browser-infrastructure failure twice (demo_runner rc 6; services re-checked + one retry between attempts). The replay journeys were NOT verified by replay this iteration and were routed to the LLM lane — see the merged ui-test-results.md for their authoritative verdicts. This is a lane state, not a journey verdict: no journey is recorded FAIL by infra._"
  } >> "$REGRESSION_RESULTS" 2>/dev/null || true
  if declare -F record_telemetry_event >/dev/null 2>&1; then
    record_telemetry_event "replay_lane_skipped_infra" "$(jq -cn --arg n "$_rl_iter" --arg j "${R_REPLAY% }" \
        '{iter_name:$n, journeys:$j, note:"browser-infra failure twice (rc 6, one retry after a service re-check); replay journeys routed to the LLM lane"}' 2>/dev/null \
      || printf '{"iter_name":"%s","journeys":"%s"}' "$_rl_iter" "${R_REPLAY% }")"
  fi
}

# ── REL-14: primary-lane browser-infra preflight + out-of-band token ──────────
# The REL-5 discipline above covers only the deterministic replay lane; these
# helpers extend it to the PRIMARY browser-qa dispatch (LLM lane in lean,
# browser-qa-phase.sh in full). The token is OUT-OF-BAND by design: the merged
# ui-test-results verdict enum stays PASS|FAIL|SKIPPED (the checkpoint greps
# and verdicts.py must never see a new value); the goal-evaluator reads
# $ITER_DIR/browser-infra.json separately and scores the listed journeys
# partial(pending-infra). All call sites gate on CHAIN_BQA_PREFLIGHT
# (default false — an absent token is byte-for-byte today's behavior).

# bqa_services_probe — pure probe, never boots. Backend health URL first, then
# the frontend. Ready = any HTTP status (same permissive regex as
# ensure_services_running: a 404 still proves the server answers).
bqa_services_probe() {
  local _bp_be="${QA_BACKEND_HEALTH_URL:-http://localhost:${CHAIN_BACKEND_PORT:-8000}/health}"
  local _bp_fe="${FRONTEND_URL:-http://localhost:${CHAIN_FRONTEND_PORT:-3000}}"
  local _bp_code
  _bp_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$_bp_be" 2>/dev/null || echo 000)"
  [[ "$_bp_code" =~ ^[1-5][0-9][0-9]$ ]] || return 1
  _bp_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$_bp_fe" 2>/dev/null || echo 000)"
  [[ "$_bp_code" =~ ^[1-5][0-9][0-9]$ ]] || return 1
  return 0
}

# bqa_browser_confine — put escaped QA browsers back inside the host-guard mask
# before dispatching. UNCONDITIONAL, unlike the REL-14 services preflight above:
# a browser that escaped confinement is a hardware-safety problem, not a QA
# convenience, so it must not depend on CHAIN_BQA_PREFLIGHT being opted in.
# No-ops when the project declares no host-guard.
bqa_browser_confine() {
  local bc; bc="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../host-guard/browser-confine.sh"
  [[ -f "$bc" ]] || return 0
  HOST_GUARD_ROOT="${HOST_GUARD_ROOT:-$REPO_ROOT}" bash "$bc" || true
  return 0
}

# bqa_preflight — probe → one re-check via ensure_services_running (idempotent:
# it returns immediately when services already answer) → probe again. Mirrors
# the REL-5 rc-6 retry shape above. Returns 0 = the dispatch may proceed;
# 1 = infra still down after the single retry (the caller writes the token and
# skips the dispatch instead of burning it against dead infra).
bqa_preflight() {
  bqa_services_probe && return 0
  _replay_lane_log "REL-14 preflight: services probe failed — re-checking services and retrying the probe once..."
  if declare -F ensure_services_running >/dev/null 2>&1; then ensure_services_running || true; fi
  bqa_services_probe && return 0
  return 1
}

# bqa_write_infra_token <iter_dir> <journeys-space-sep> <reason> <detected_by>
# The out-of-band REL-14 token. `attempts` counts CONSECUTIVE infra-blocked
# iterations: run-goal.sh exports CHAIN_BQA_PREV_ATTEMPTS from the previous
# iteration's token when it schedules a make-up; a fresh screenshot (journey
# scored passing/failing) resets the chain by not carrying the export forward.
bqa_write_infra_token() {
  local _bt_dir="$1" _bt_journeys="$2" _bt_reason="$3" _bt_by="$4"
  local _bt_attempts=$(( ${CHAIN_BQA_PREV_ATTEMPTS:-0} + 1 ))
  mkdir -p "$_bt_dir" 2>/dev/null || true
  BQA_JOURNEYS="$_bt_journeys" BQA_REASON="$_bt_reason" BQA_BY="$_bt_by" BQA_ATTEMPTS="$_bt_attempts" \
  python3 - "$_bt_dir/browser-infra.json" <<'PY' || _replay_lane_warn "REL-14: failed to write browser-infra.json (non-blocking)"
import json, os, sys
journeys = [j for j in os.environ.get("BQA_JOURNEYS", "").split() if j]
with open(sys.argv[1], "w") as f:
    json.dump({"journeys": journeys,
               "reason": os.environ.get("BQA_REASON", ""),
               "attempts": int(os.environ.get("BQA_ATTEMPTS", "1")),
               "detected_by": os.environ.get("BQA_BY", "")}, f, indent=1)
    f.write("\n")
PY
  _replay_lane_warn "REL-14: browser-infra token written ($_bt_by, attempt $_bt_attempts) for: ${_bt_journeys:-(none)} — $_bt_reason"
  if declare -F record_telemetry_event >/dev/null 2>&1; then
    record_telemetry_event "browser_infra_token" "$(jq -cn --arg j "$_bt_journeys" --arg r "$_bt_reason" --arg d "$_bt_by" --argjson a "$_bt_attempts" \
        '{journeys:$j, reason:$r, detected_by:$d, attempts:$a}' 2>/dev/null \
      || printf '{"journeys":"%s","detected_by":"%s"}' "$_bt_journeys" "$_bt_by")"
  fi
}

# bqa_results_infra_reason <merged-results-file>
# Post-scan classifier for mid-run browser death (which no preflight can
# catch): succeeds (and echoes the reason) ONLY when the results contain at
# least one row, NO PASS/FAIL row, and an explicit browser-infra taxonomy
# reason (demo_runner's "browser infrastructure failure" / a Chrome readiness
# error). Deliberately conservative: legitimate SKIPs (single-service
# projects, frontend-less iterations) must never be tokenized — a false
# negative just means today's behavior.
bqa_results_infra_reason() {
  local _br_f="$1"
  [[ -f "$_br_f" ]] || return 1
  grep -qE '\|[[:space:]]*(PASS|FAIL)[[:space:]]*\|' "$_br_f" && return 1
  grep -qE '^\|' "$_br_f" || return 1
  grep -m1 -oiE '(browser infrastructure failure|chrome (mcp )?did not become ready)[^|]*' "$_br_f" || return 1
}

# Partition Required-still-passing into replay (LINTABLE golden on file) vs LLM,
# then run the deterministic replay over the golden set. $1 = iter/phase name.
# Requires replay_lane_paths to have run. Sets R_REPLAY, R_LLM, _use_replay,
# REPLAY_FAILED, REPLAY_SKIPPED_INFRA (see the header's dataflow contract).
replay_lane_partition_and_verify() {
  local _rl_iter="$1"

  # FAIL-CLOSED: the deterministic replay drives a real browser against real
  # services. Under maintenance isolation that is forbidden regardless of how we
  # got here — note the partitioner routes TARGET journeys as well as
  # Required-still-passing ones, so an empty required set is NOT what makes an
  # iteration safe. Refuse rather than partition.
  #
  # "Cannot evaluate" counts as forbidden. This is a library: a caller that never
  # sourced common.sh has no predicate, and treating that as "not isolated" would
  # make the one state in which the contract is uncheckable the state that lets
  # the browser run. Both production callers (browser-qa-phase.sh,
  # goal-iter-lean.sh) source common.sh, so this branch is a backstop.
  if ! declare -F goal_maintenance_isolation_required >/dev/null 2>&1; then
    echo "[replay-lane] lib/common.sh not sourced — cannot evaluate maintenance isolation; refusing the replay lane (fail closed)" >&2
    return 0
  fi
  if goal_maintenance_isolation_required; then
    maintenance_isolation_refuse "replay_lane_partition_and_verify" "deterministic replay for ${_rl_iter}" || true
    return 0
  fi

  # Stale-artifact hygiene: a prior run/attempt's lane files must not survive
  # into this run — a merge would ingest them as current output, and a lane
  # that does not engage this run (no goldens, hatch off) would leave last
  # run's files masquerading as this iteration's. Absent beats stale.
  rm -f "$REGRESSION_RESULTS" "$LLM_RESULTS" "$CANARY_RESULTS" 2>/dev/null || true

  # A golden that fails validation is quarantined (renamed *.json.invalid) and
  # its journey routed to the LLM lane — previously an invalid golden produced
  # a replay SKIP that nothing re-confirmed (silently unverified journey). A
  # lint crash (no output) conservatively keeps the old file-exists behavior:
  # the verify runner re-validates at replay time anyway.
  local _lint_out=""
  if [[ -n "${REQUIRED_JOURNEYS// /}" ]]; then
    _lint_out="$(python3 "$DEMO_RUNNER" --mode lint --scripts-dir "$JOURNEY_SCRIPTS_DIR" \
      --journeys "$(echo "$REQUIRED_JOURNEYS" | tr ' ' ',' | sed 's/^,*//;s/,*$//')" 2>/dev/null || true)"
  fi
  R_REPLAY=""; R_LLM=""
  local _j
  for _j in $REQUIRED_JOURNEYS; do
    if [[ -f "$JOURNEY_SCRIPTS_DIR/$_j.json" ]]; then
      if printf '%s\n' "$_lint_out" | grep -q "^$_j invalid"; then
        _replay_lane_log "Golden for $_j failed lint — quarantining ($_j.json.invalid) and routing to the LLM lane: $(printf '%s\n' "$_lint_out" | grep -m1 "^$_j invalid" | cut -d' ' -f2-)"
        mv -f "$JOURNEY_SCRIPTS_DIR/$_j.json" "$JOURNEY_SCRIPTS_DIR/$_j.json.invalid" 2>/dev/null || true
        R_LLM+="$_j "
      else
        R_REPLAY+="$_j "
      fi
    else
      R_LLM+="$_j "
    fi
  done

  _use_replay="no"
  if [[ "${CHAIN_REGRESSION_REPLAY:-true}" == "true" && "$FRONTEND_AVAILABLE" == "yes" && -n "${R_REPLAY// /}" ]]; then
    _use_replay="yes"
  fi

  # Lane 1 — deterministic replay of the already-passing set (only if golden
  # scripts exist).
  REPLAY_FAILED=""
  REPLAY_SKIPPED_INFRA=""
  REPLAY_MASS_FAIL=""
  REPLAY_CANARIES=""
  if [[ "$_use_replay" == "yes" ]]; then
    _replay_lane_log "Regression (deterministic replay): $R_REPLAY"
    local _replay_csv _replay_rc=0
    _replay_csv="$(echo "$R_REPLAY" | tr ' ' ',' | sed 's/^,*//;s/,*$//')"
    _replay_lane_verify_once "$_rl_iter" "$_replay_csv" || _replay_rc=$?
    # REL-5: rc 6 is demo_runner's browser-INFRA class (launch timeout, mid-run
    # crash) — transient by nature, so re-check services and retry ONCE. Only
    # rc 6: an assertion failure (rc 5) is NEVER retried (re-rolling assertions
    # masks real regressions — the LLM re-confirm is the false-positive net),
    # and other rcs (3 = playwright missing, 2 = bad invocation, crash) are
    # deterministic failures a retry cannot fix.
    if [[ "$_replay_rc" -eq 6 ]]; then
      _replay_lane_log "Replay lane browser-infra failure (rc=6) — re-checking services and retrying the replay once..."
      if declare -F ensure_services_running >/dev/null 2>&1; then
        ensure_services_running || true
      fi
      _replay_rc=0
      _replay_lane_verify_once "$_rl_iter" "$_replay_csv" || _replay_rc=$?
    fi
    if [[ "$_replay_rc" -eq 5 ]]; then
      REPLAY_FAILED="$(grep -E '^\| UT-J-[0-9]+ ' "$REGRESSION_RESULTS" 2>/dev/null | grep -F '| FAIL |' | grep -oE 'J-[0-9]+' | sort -u | tr '\n' ' ')"
      _replay_lane_log "Replay flagged possible regression(s) — re-confirming via LLM: $REPLAY_FAILED"
      # SPEED-22 mass-false-FAIL detection: a MAJORITY-FAIL replay run (>2
      # FAILs and more than half the ran set) is far more likely selector/
      # environment drift than 3+ simultaneous real regressions (desk iter-14:
      # 8/9 false FAILs → 28 min of LLM overturns). Arm the canary probe: the
      # lean executor re-confirms the 2 lowest-ID FAILs FIRST and only fans
      # out to the full re-confirm set if a canary really fails. Detection is
      # gated on REPLAY_LANE_CANARY_CAPABLE=1 — set ONLY by goal-iter-lean.sh
      # (the full pipeline has no separate canary dispatch slot and stays
      # byte-identical). 8/9 triggers; 2/9 and 3/6 do not.
      REPLAY_MASS_FAIL=""
      REPLAY_CANARIES=""
      if [[ "${REPLAY_LANE_CANARY_CAPABLE:-}" == "1" && "${CHAIN_REPLAY_MASS_FAIL_BREAKER:-true}" == "true" ]]; then
        local _mf_ran _mf_fail
        _mf_ran="$(grep -cE '^\| UT-J-[0-9]+ ' "$REGRESSION_RESULTS" 2>/dev/null || true)"
        _mf_fail="$(echo "$REPLAY_FAILED" | wc -w)"
        if [[ "${_mf_fail:-0}" -gt 2 && "${_mf_ran:-0}" -gt 0 ]] && (( 2 * _mf_fail > _mf_ran )); then
          REPLAY_MASS_FAIL="yes"
          REPLAY_CANARIES="$(echo "$REPLAY_FAILED" | tr ' ' '\n' | grep -E '^J-[0-9]+$' | sort -t- -k2,2n | head -2 | tr '\n' ' ' || true)"
          _replay_lane_log "SPEED-22 mass-FAIL breaker armed: $_mf_fail of $_mf_ran replay journeys FAILed at once — canaries ${REPLAY_CANARIES% }will be re-checked before burning re-confirms on the whole set (CHAIN_REPLAY_MASS_FAIL_BREAKER=false disables)."
        fi
      fi
    elif [[ "$_replay_rc" -eq 6 ]]; then
      # REL-5: browser infra failed twice (one retry after a service re-check).
      # The lane's recorded state is SKIPPED-INFRA — distinct from FAIL (no
      # journey is "broken"; infra is unknown) and from the REL-12
      # frontend-skip (the frontend WAS answering at boot). Routing is the same
      # fallback as any lane failure, so every replay journey still gets an
      # LLM-lane verifier; the state itself lives on the RAW artifact +
      # REPLAY_SKIPPED_INFRA + telemetry and never enters the merged results
      # file — its **Browser QA Verdict:** stays agent/merge-written
      # PASS/FAIL/SKIPPED, so the checkpoint verdict greps cannot collapse it.
      _replay_lane_mark_skipped_infra "$_rl_iter"
      _use_replay="no"
      R_REPLAY=""
    elif [[ "$_replay_rc" -ne 0 ]]; then
      # Replay-lane infrastructure failure (non-6 rc = runner crash, missing
      # playwright, bad invocation). The replay journeys were NOT verified —
      # route ALL of them back to the LLM lane, byte-identical to running this
      # iteration with CHAIN_REGRESSION_REPLAY=false. Previously a replay crash
      # left them silently unverified for the iteration.
      _replay_lane_warn "Replay lane failed (rc=$_replay_rc) — falling back to the LLM lane for ALL regression journeys."
      _use_replay="no"
      R_REPLAY=""
    fi
  fi
}

# SPEED-15 rung-2 decision, in ONE place: over the wall-clock budget in trim
# mode with the replay lane engaged, the no-golden regression journeys (R_LLM)
# are DEFERRED to a later iteration instead of riding the slow LLM lane now.
# $1 (optional) = journeys to EXCLUDE from deferral because they are
# dispatched anyway — the caller's Target set: a journey listed as BOTH a
# target and a required-no-golden journey gets a real verdict row from the
# target dispatch, and a DEFERRED-BUDGET row beside it would contradict the
# record and wrongly block GOAL_ACHIEVED.
# Echoes the deferred set ("" = no narrowing). PURE — no logging/telemetry
# (callers capture via $(...)): the caller stores the result in
# REPLAY_DEFERRED_BUDGET ONCE per run, logs, and emits the trim event. The
# budget clock keeps ticking, so recomputing later could disagree with what
# was actually dispatched — never call this twice for one run. Replay-FAIL
# re-confirms are structurally exempt: replay_lane_llm_regression_set below
# always keeps them.
replay_lane_deferred_budget_set() {
  if [[ "${_use_replay:-no}" == "yes" ]] \
     && declare -F iter_budget_trim_active >/dev/null 2>&1 && iter_budget_trim_active \
     && [[ -n "${R_LLM// /}" ]]; then
    local _db_out="" _j
    for _j in $(echo "$R_LLM" | tr ' ' '\n' | grep -E '^J-[0-9]+$' | sort -u); do
      [[ " ${1:-} " == *" $_j "* ]] || _db_out+="$_j "
    done
    echo "$_db_out"
  else
    echo ""
  fi
}

# The regression journeys the LLM lane must cover this run, deduped:
#   replay engaged → the replay FAILs to re-confirm + the no-golden journeys
#     (minus the rung-2 deferred set when the caller armed
#     REPLAY_DEFERRED_BUDGET — replay-FAIL re-confirms are NEVER deferred: a
#     possible real regression must be re-confirmed this iteration);
#   replay off (hatch/no goldens/frontend down/crash) → the WHOLE required set,
#   so the DoD line "Required-still-passing journeys remain green" always has a
#   verifier at both depths. Same pipefail guard as replay_lane_spec_journeys:
#   an all-replay iteration has a legitimately empty LLM set.
replay_lane_llm_regression_set() {
  local _rl_set
  if [[ "${_use_replay:-no}" == "yes" ]]; then
    if [[ -n "${REPLAY_DEFERRED_BUDGET:-}" && -n "${REPLAY_DEFERRED_BUDGET// /}" ]]; then
      _rl_set="$REPLAY_FAILED"
    else
      _rl_set="$REPLAY_FAILED $R_LLM"
    fi
  else
    _rl_set="$REQUIRED_JOURNEYS"
  fi
  echo "$_rl_set" | tr ' ' '\n' | grep -E '^J-[0-9]+$' | sort -u | tr '\n' ' ' || true
}

# SPEED-15 rung 2, write side: after the merge, append one DEFERRED-BUDGET row
# per deferred journey to the merged results file $1 so the record is honest —
# the journey was NOT re-verified this iteration. The goal-evaluator contract
# scores a DEFERRED-BUDGET row as "keeps prior recorded status" (never a
# regression), and the deterministic achievement gate (goal_gate.py results)
# treats any DEFERRED-BUDGET row as blocking, so a deferred journey can never
# certify GOAL_ACHIEVED. No-op when the caller never armed the deferred set.
replay_lane_write_deferred_rows() {
  local _rl_merged="$1"
  [[ -n "${REPLAY_DEFERRED_BUDGET:-}" && -n "${REPLAY_DEFERRED_BUDGET// /}" && -f "$_rl_merged" ]] || return 0
  local _j
  {
    echo ""
    echo "## Deferred (iteration budget)"
    echo ""
    echo "_The wall-clock iteration budget was exceeded (SPEED-15 trim rung 2): the"
    echo "no-golden regression journeys below were NOT re-verified this iteration and"
    echo "keep their prior recorded status. They are re-queued for a later iteration_"
    echo ""
    echo "| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |"
    echo "|---------|------|------|----------|----------|--------|---------|----------|"
    for _j in $REPLAY_DEFERRED_BUDGET; do
      printf '| UT-%s | %s regression re-check | regression | P2 | re-verify per goal.md | not run this iteration | DEFERRED-BUDGET | deferred: over iteration wall-clock budget |\n' "$_j" "$_j"
    done
  } >> "$_rl_merged" 2>/dev/null || true
  _replay_lane_log "iter-budget trim (rung 2): DEFERRED-BUDGET rows appended for ${REPLAY_DEFERRED_BUDGET% }(prior statuses kept; GOAL_ACHIEVED blocked while any journey is deferred)."
}

# Merge replay + LLM lane outputs into $1 — the single authoritative results
# file the goal-evaluator and the deterministic achievement gate read. $2 = the
# LLM lane's output file. LLM listed LAST → wins on any journey both lanes
# touched (e.g. a replay-FAIL re-confirm). SPEED-22: when a canary results
# file exists (mass-FAIL probe ran), it merges as a MIDDLE input — its fresh
# canary verdicts beat the (possibly voided) replay rows, and the main LLM
# lane still wins where it re-tested a journey. On merge failure, degrade to a
# lane copy (LLM preferred) so the evaluator always has something to read.
replay_lane_merge_results() {
  local _rl_out="$1" _rl_llm="$2"
  local _rl_mid=()
  [[ -n "${CANARY_RESULTS:-}" && -f "${CANARY_RESULTS:-}" ]] && _rl_mid=("$CANARY_RESULTS")
  if ! python3 "$MERGE_RESULTS" "$_rl_out" "$REGRESSION_RESULTS" ${_rl_mid[@]+"${_rl_mid[@]}"} "$_rl_llm"; then
    _replay_lane_warn "results merge failed — falling back to a lane output."
    if [[ -f "$_rl_llm" ]]; then cp "$_rl_llm" "$_rl_out" 2>/dev/null || true
    elif [[ -f "$REGRESSION_RESULTS" ]]; then cp "$REGRESSION_RESULTS" "$_rl_out" 2>/dev/null || true; fi
    return 0
  fi
  replay_lane_reconcile_regression_artifact "$_rl_out"
}

# Reconcile the RAW replay artifact after a merge: any journey the replay lane
# FAILed but the merged file records as PASS was overturned by the LLM lane's
# re-confirmation (golden-script false positive — brittle selector, cleared
# fixture, stale expected string). Append a dated footer naming those journeys
# so no stale FAIL survives the iteration on disk: a human or fresh-context
# evaluator reading the raw artifact must not see an uncontradicted FAIL that
# the authoritative merged file already overturned.
replay_lane_reconcile_regression_artifact() {
  local _rl_merged="$1"
  [[ -f "$REGRESSION_RESULTS" && -f "$_rl_merged" ]] || return 0
  local _rl_overturned="" _j
  for _j in $(grep -E '^\| UT-J-[0-9]+ ' "$REGRESSION_RESULTS" 2>/dev/null | grep -F '| FAIL |' | grep -oE 'J-[0-9]+' | sort -u || true); do
    if grep -E "^\| UT-$_j " "$_rl_merged" 2>/dev/null | grep -qF '| PASS |'; then
      _rl_overturned+="$_j "
    fi
  done
  [[ -n "${_rl_overturned// /}" ]] || return 0
  {
    echo ""
    echo "---"
    echo ""
    echo "_Reconciliation ($(date -u +%Y-%m-%d)): the replay FAIL row(s) for ${_rl_overturned% } above were overturned by the LLM lane's re-confirmation this iteration (golden-script false positive). The authoritative merged verdicts are in $(basename "$_rl_merged"); the FAIL row(s) above are superseded._"
  } >> "$REGRESSION_RESULTS" 2>/dev/null || true
  _replay_lane_log "Reconciled replay artifact: FAIL overturned by LLM re-confirmation for ${_rl_overturned% }(footer appended to $(basename "$REGRESSION_RESULTS"))."
}

# Golden coverage: every PASSing journey in results file $1 should have a
# lintable golden so the replay lane keeps growing (browser-qa LLM time decays
# iteration over iteration). A gap is loud but non-gating — those journeys
# simply return to the LLM lane next iteration. $2 = iter/phase name for the
# telemetry event (no-op when telemetry.sh is not sourced). SPEED-23: the gap
# list is also PERSISTED to state/golden-gaps so the next iteration's nudge
# pick and the SPEED-21 auto-derivation can read it (empty gap → file removed).
replay_lane_golden_coverage() {
  local _rl_results="$1" _rl_iter="$2"
  local _pass_j _n_pass=0 _missing_golden="" _j
  _pass_j="$(grep -E '^\| UT-J-[0-9]+ ' "$_rl_results" 2>/dev/null | grep -F '| PASS |' | grep -oE 'J-[0-9]+' | sort -u | tr '\n' ' ' || true)"
  for _j in $_pass_j; do
    _n_pass=$((_n_pass + 1))
    [[ -f "$JOURNEY_SCRIPTS_DIR/$_j.json" ]] || _missing_golden+="$_j "
  done
  local _gaps_file="$REPO_ROOT/runs/goal-session-${SID}/state/golden-gaps"
  if [[ -n "${_missing_golden// /}" ]]; then
    _replay_lane_log "Golden coverage gap: PASSing journey(s) without a replay script: ${_missing_golden}— the browser-qa agent should write a golden per PASS (they fall back to the slower LLM lane next iteration)."
    mkdir -p "$(dirname "$_gaps_file")" 2>/dev/null || true
    echo "$_missing_golden" | tr ' ' '\n' | grep -E '^J-[0-9]+$' > "$_gaps_file" 2>/dev/null || true
  else
    rm -f "$_gaps_file" 2>/dev/null || true
  fi
  if declare -F record_telemetry_event >/dev/null 2>&1; then
    record_telemetry_event "golden_coverage" "$(jq -cn --argjson p "$_n_pass" --arg m "${_missing_golden% }" --arg n "$_rl_iter" '{passing:$p, missing_goldens:$m, iter_name:$n}' 2>/dev/null || printf '{"passing":%d,"missing_goldens":"%s"}' "$_n_pass" "${_missing_golden% }")"
  fi
}

# ── SPEED-21: golden auto-derivation from the verified demo ──────────────────
# replay_lane_autoderive_goldens <phase> <demo-json> <results-md>
# After a successful demo recording (record mode, goal iteration, runner rc 0),
# derive candidate goldens for PASSing journeys that lack one — plus PASS
# journeys parked in state/goldens-regen-pending (SPEED-22 voids park regen
# requests there) — capped at CHAIN_GOLDEN_AUTODERIVE_MAX (default 3) per
# iteration. Every candidate gets a REAL verify pass in a throwaway scripts-dir
# against $FRONTEND_URL before installation:
#   rc 0        → atomic install into journey-scripts/ + golden_autoderived
#   rc 5        → discard this candidate + golden_autoderive_rejected
#   rc 6/other  → browser infra unhealthy — discard ALL remaining candidates
# Gate: CHAIN_GOLDEN_AUTODERIVE (default true). Requires replay_lane_paths to
# have run (SID/JOURNEY_SCRIPTS_DIR/DEMO_RUNNER). NEVER gates the pipeline and
# never returns non-zero.
replay_lane_autoderive_goldens() {
  local _ad_iter="$1" _ad_demo="$2" _ad_results="$3"
  [[ "${CHAIN_GOLDEN_AUTODERIVE:-true}" == "true" ]] || return 0
  [[ -f "$_ad_demo" && -f "$_ad_results" ]] || return 0
  local _ad_regen="$REPO_ROOT/runs/goal-session-${SID}/state/goldens-regen-pending"
  local _ad_pass _ad_want="" _j
  _ad_pass="$(grep -E '^\| UT-J-[0-9]+ ' "$_ad_results" 2>/dev/null | grep -F '| PASS |' | grep -oE 'J-[0-9]+' | sort -u | tr '\n' ' ' || true)"
  for _j in $_ad_pass; do
    if [[ ! -f "$JOURNEY_SCRIPTS_DIR/$_j.json" ]]; then
      _ad_want+="$_j "
    elif [[ -f "$_ad_regen" ]] && grep -qx "$_j" "$_ad_regen" 2>/dev/null; then
      _ad_want+="$_j "
    fi
  done
  local _ad_cap="${CHAIN_GOLDEN_AUTODERIVE_MAX:-3}"
  [[ "$_ad_cap" =~ ^[0-9]+$ ]] || _ad_cap=3
  _ad_want="$(echo "$_ad_want" | tr ' ' '\n' | grep -E '^J-[0-9]+$' | head -n "$_ad_cap" | tr '\n' ' ' || true)"
  [[ -n "${_ad_want// /}" ]] || return 0
  local _ad_tmp="${CHAIN_TMPDIR:-${TMPDIR:-/tmp}}/golden-autoderive.$$"
  mkdir -p "$_ad_tmp" 2>/dev/null || return 0
  _replay_lane_log "SPEED-21: deriving golden candidate(s) from the verified demo for: ${_ad_want% }(cap ${_ad_cap}; CHAIN_GOLDEN_AUTODERIVE=false disables)."
  python3 "$DEMO_RUNNER" --mode derive --json "$_ad_demo" --scripts-dir "$_ad_tmp" \
    --journeys "$(echo "$_ad_want" | tr ' ' ',' | sed 's/^,*//;s/,*$//')" 2>/dev/null \
    | while IFS= read -r _line; do _replay_lane_log "SPEED-21 derive: $_line"; done || true
  local _ad_infra=""
  for _j in $_ad_want; do
    [[ -n "$_ad_infra" ]] && break
    local _cand="$_ad_tmp/$_j.json.candidate"
    [[ -s "$_cand" ]] || continue
    local _vdir="$_ad_tmp/verify-$_j"
    mkdir -p "$_vdir" 2>/dev/null || continue
    cp "$_cand" "$_vdir/$_j.json" 2>/dev/null || continue
    local _vrc=0
    python3 "$DEMO_RUNNER" --mode verify --scripts-dir "$_vdir" --journeys "$_j" \
      --results "$_vdir/results.md" --evidence-dir "$_vdir/evidence" \
      --base-url "$FRONTEND_URL" --phase-id "$_ad_iter" --repo-root "$REPO_ROOT" \
      >/dev/null 2>&1 || _vrc=$?
    if [[ "$_vrc" -eq 0 ]]; then
      # Atomic install: stage inside the destination dir, then rename.
      if cp "$_vdir/$_j.json" "$JOURNEY_SCRIPTS_DIR/.$_j.json.autoderive.$$" 2>/dev/null \
         && mv -f "$JOURNEY_SCRIPTS_DIR/.$_j.json.autoderive.$$" "$JOURNEY_SCRIPTS_DIR/$_j.json" 2>/dev/null; then
        _replay_lane_log "SPEED-21: golden INSTALLED for $_j (candidate replayed green against $FRONTEND_URL)."
        if [[ -f "$_ad_regen" ]]; then
          grep -vx "$_j" "$_ad_regen" > "$_ad_regen.tmp.$$" 2>/dev/null || true
          mv -f "$_ad_regen.tmp.$$" "$_ad_regen" 2>/dev/null || rm -f "$_ad_regen.tmp.$$" 2>/dev/null || true
          [[ -s "$_ad_regen" ]] || rm -f "$_ad_regen" 2>/dev/null || true
        fi
        if declare -F record_telemetry_event >/dev/null 2>&1; then
          record_telemetry_event "golden_autoderived" "$(jq -cn --arg j "$_j" --arg n "$_ad_iter" '{journey:$j, iter_name:$n}' 2>/dev/null || printf '{"journey":"%s"}' "$_j")"
        fi
      fi
    elif [[ "$_vrc" -eq 5 ]]; then
      _replay_lane_log "SPEED-21: candidate for $_j FAILED its verify pass — discarded (the LLM lane keeps covering it)."
      if declare -F record_telemetry_event >/dev/null 2>&1; then
        record_telemetry_event "golden_autoderive_rejected" "$(jq -cn --arg j "$_j" --arg n "$_ad_iter" '{journey:$j, iter_name:$n, reason:"verify-fail"}' 2>/dev/null || printf '{"journey":"%s"}' "$_j")"
      fi
    else
      _replay_lane_warn "SPEED-21: verify pass hit browser/runner trouble (rc=$_vrc) — discarding ALL remaining candidates this iteration (never gates)."
      _ad_infra=1
    fi
  done
  rm -rf "$_ad_tmp" 2>/dev/null || true
  return 0
}

# ── SPEED-22: mass-false-FAIL canary verdict + void ──────────────────────────
# replay_lane_canaries_all_pass <canary-results-md> <canaries-space-sep>
# True iff EVERY canary journey has a PASS row in the canary results file.
# Conservative by design: a missing file, an unparsable file, a missing row,
# or any non-PASS verdict returns 1 → the caller keeps today's full
# re-confirm behavior (a false negative just costs the old path).
replay_lane_canaries_all_pass() {
  local _cp_file="$1" _cp_set="$2" _j
  [[ -f "$_cp_file" && -n "${_cp_set// /}" ]] || return 1
  for _j in $_cp_set; do
    grep -E "^\| UT-$_j " "$_cp_file" 2>/dev/null | grep -qF '| PASS |' || return 1
  done
  return 0
}

# replay_lane_void_mass_fail <iter-name>
# All canaries re-checked GREEN → the mass replay FAIL is drift, not
# regression. Rewrite the raw replay artifact's FAIL rows to SKIP + voided
# note (merge_ui_test_results.py void — recomputes the headline and appends a
# dated loud footer), queue every voided journey for golden regeneration
# (state/goldens-regen-pending — SPEED-21 re-derives them verified-green from
# the next demo), clear REPLAY_FAILED so the main LLM dispatch does not
# re-confirm the whole set, and record replay_mass_fail_voided. If the void
# rewrite itself fails, keep today's behavior (REPLAY_FAILED intact).
replay_lane_void_mass_fail() {
  local _vm_iter="$1"
  local _vm_ids="${REPLAY_FAILED% }"
  [[ -n "${_vm_ids// /}" ]] || return 0
  # shellcheck disable=SC2086  # word-splitting the journey list is the point
  if ! python3 "$MERGE_RESULTS" void "$REGRESSION_RESULTS" $_vm_ids; then
    _replay_lane_warn "SPEED-22: void rewrite failed — keeping the full re-confirm set (conservative)."
    return 1
  fi
  local _vm_state="$REPO_ROOT/runs/goal-session-${SID}/state"
  mkdir -p "$_vm_state" 2>/dev/null || true
  { cat "$_vm_state/goldens-regen-pending" 2>/dev/null || true; echo "$_vm_ids" | tr ' ' '\n'; } \
    | grep -E '^J-[0-9]+$' | sort -u > "$_vm_state/goldens-regen-pending.tmp.$$" 2>/dev/null \
    && mv -f "$_vm_state/goldens-regen-pending.tmp.$$" "$_vm_state/goldens-regen-pending" 2>/dev/null \
    || rm -f "$_vm_state/goldens-regen-pending.tmp.$$" 2>/dev/null || true
  _replay_lane_log "SPEED-22: mass replay FAIL VOIDED for ${_vm_ids}(canaries ${REPLAY_CANARIES% }re-checked green) — prior statuses kept, goldens queued for regeneration, no further re-confirms this iteration."
  if declare -F record_telemetry_event >/dev/null 2>&1; then
    record_telemetry_event "replay_mass_fail_voided" "$(jq -cn --arg n "$_vm_iter" --arg j "$_vm_ids" --arg c "${REPLAY_CANARIES% }" '{iter_name:$n, journeys:$j, canaries:$c}' 2>/dev/null || printf '{"iter_name":"%s","journeys":"%s"}' "$_vm_iter" "$_vm_ids")"
  fi
  REPLAY_FAILED=""
  return 0
}

# ── SPEED-23: bounded golden-coverage nudge ──────────────────────────────────
# replay_lane_golden_nudge_pick <llm-journeys-space-sep>
# Picks ONE journey from (persisted golden gaps ∩ this run's LLM set) to turn
# from best-effort golden authoring into a REQUIRED deliverable this dispatch.
# Rotation: min nudge-count first (ties → lowest ID), counts persisted in
# state/golden-nudge.json — so one stubborn journey cannot monopolize the
# nudge. Echoes the journey ID (or nothing). PURE stdout — callers capture via
# $(...); the count update is a file write, so it survives the subshell. Gate:
# CHAIN_GOLDEN_NUDGE (default true).
replay_lane_golden_nudge_pick() {
  local _gn_set="$1"
  [[ "${CHAIN_GOLDEN_NUDGE:-true}" == "true" ]] || return 0
  local _gn_gaps="$REPO_ROOT/runs/goal-session-${SID}/state/golden-gaps"
  [[ -s "$_gn_gaps" && -n "${_gn_set// /}" ]] || return 0
  GN_SET="$_gn_set" python3 - "$_gn_gaps" "$REPO_ROOT/runs/goal-session-${SID}/state/golden-nudge.json" 2>/dev/null <<'PY' || true
import json, os, sys
try:
    gaps = set(open(sys.argv[1]).read().split())
except Exception:
    sys.exit(0)
llm = set(os.environ.get("GN_SET", "").split())
cands = sorted(gaps & llm)
if not cands:
    sys.exit(0)
try:
    counts = json.load(open(sys.argv[2]))
    if not isinstance(counts, dict):
        counts = {}
except Exception:
    counts = {}
pick = min(cands, key=lambda j: (int(counts.get(j, 0) or 0), j))
counts[pick] = int(counts.get(pick, 0) or 0) + 1
try:
    with open(sys.argv[2], "w") as f:
        json.dump(counts, f, indent=1)
        f.write("\n")
except Exception:
    pass
print(pick)
PY
}
