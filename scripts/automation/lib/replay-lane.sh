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
#      loop). rc contract: 0 = all pass; 5 = journey FAIL(s) → REPLAY_FAILED is
#      re-confirmed by the LLM lane (a brittle selector must not fake a
#      regression and halt the session); any other rc = lane infrastructure
#      failure → ALL replay journeys fall back to the LLM lane, byte-identical
#      to running with CHAIN_REGRESSION_REPLAY=false.
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
#        CHAIN_REGRESSION_REPLAY (knob, default true)
#   Set by replay_lane_paths: EVIDENCE_DIR, SID, JOURNEY_SCRIPTS_DIR,
#        REGRESSION_RESULTS, LLM_RESULTS, DEMO_RUNNER, MERGE_RESULTS
#   Out of partition+verify: R_REPLAY, R_LLM, _use_replay, REPLAY_FAILED

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
  DEMO_RUNNER="$_REPLAY_LANE_LIB_DIR/demo_runner.py"
  MERGE_RESULTS="$_REPLAY_LANE_LIB_DIR/merge_ui_test_results.py"
}

# Partition Required-still-passing into replay (LINTABLE golden on file) vs LLM,
# then run the deterministic replay over the golden set. $1 = iter/phase name.
# Requires replay_lane_paths to have run. Sets R_REPLAY, R_LLM, _use_replay,
# REPLAY_FAILED (see the header's dataflow contract).
replay_lane_partition_and_verify() {
  local _rl_iter="$1"

  # Stale-artifact hygiene: a prior run/attempt's lane files must not survive
  # into this run — a merge would ingest them as current output, and a lane
  # that does not engage this run (no goldens, hatch off) would leave last
  # run's files masquerading as this iteration's. Absent beats stale.
  rm -f "$REGRESSION_RESULTS" "$LLM_RESULTS" 2>/dev/null || true

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
  if [[ "$_use_replay" == "yes" ]]; then
    _replay_lane_log "Regression (deterministic replay): $R_REPLAY"
    local _replay_csv _replay_rc=0
    _replay_csv="$(echo "$R_REPLAY" | tr ' ' ',' | sed 's/^,*//;s/,*$//')"
    python3 "$DEMO_RUNNER" --mode verify \
      --scripts-dir "$JOURNEY_SCRIPTS_DIR" --journeys "$_replay_csv" \
      --results "$REGRESSION_RESULTS" --evidence-dir "$EVIDENCE_DIR" \
      --base-url "$FRONTEND_URL" --phase-id "$_rl_iter" --repo-root "$REPO_ROOT" || _replay_rc=$?
    if [[ "$_replay_rc" -eq 5 ]]; then
      REPLAY_FAILED="$(grep -E '^\| UT-J-[0-9]+ ' "$REGRESSION_RESULTS" 2>/dev/null | grep -F '| FAIL |' | grep -oE 'J-[0-9]+' | sort -u | tr '\n' ' ')"
      _replay_lane_log "Replay flagged possible regression(s) — re-confirming via LLM: $REPLAY_FAILED"
    elif [[ "$_replay_rc" -ne 0 ]]; then
      # Replay-lane infrastructure failure (rc 6 = browser launch/crash; any
      # other rc = runner crash). The replay journeys were NOT verified — route
      # ALL of them back to the LLM lane, byte-identical to running this
      # iteration with CHAIN_REGRESSION_REPLAY=false. Previously a replay crash
      # left them silently unverified for the iteration.
      _replay_lane_warn "Replay lane failed (rc=$_replay_rc) — falling back to the LLM lane for ALL regression journeys."
      _use_replay="no"
      R_REPLAY=""
    fi
  fi
}

# The regression journeys the LLM lane must cover this run, deduped:
#   replay engaged → the replay FAILs to re-confirm + the no-golden journeys;
#   replay off (hatch/no goldens/frontend down/crash) → the WHOLE required set,
#   so the DoD line "Required-still-passing journeys remain green" always has a
#   verifier at both depths. Same pipefail guard as replay_lane_spec_journeys:
#   an all-replay iteration has a legitimately empty LLM set.
replay_lane_llm_regression_set() {
  local _rl_set
  if [[ "${_use_replay:-no}" == "yes" ]]; then
    _rl_set="$REPLAY_FAILED $R_LLM"
  else
    _rl_set="$REQUIRED_JOURNEYS"
  fi
  echo "$_rl_set" | tr ' ' '\n' | grep -E '^J-[0-9]+$' | sort -u | tr '\n' ' ' || true
}

# Merge replay + LLM lane outputs into $1 — the single authoritative results
# file the goal-evaluator and the deterministic achievement gate read. $2 = the
# LLM lane's output file. LLM listed LAST → wins on any journey both lanes
# touched (e.g. a replay-FAIL re-confirm). On merge failure, degrade to a lane
# copy (LLM preferred) so the evaluator always has something to read.
replay_lane_merge_results() {
  local _rl_out="$1" _rl_llm="$2"
  if ! python3 "$MERGE_RESULTS" "$_rl_out" "$REGRESSION_RESULTS" "$_rl_llm"; then
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
# telemetry event (no-op when telemetry.sh is not sourced).
replay_lane_golden_coverage() {
  local _rl_results="$1" _rl_iter="$2"
  local _pass_j _n_pass=0 _missing_golden="" _j
  _pass_j="$(grep -E '^\| UT-J-[0-9]+ ' "$_rl_results" 2>/dev/null | grep -F '| PASS |' | grep -oE 'J-[0-9]+' | sort -u | tr '\n' ' ' || true)"
  for _j in $_pass_j; do
    _n_pass=$((_n_pass + 1))
    [[ -f "$JOURNEY_SCRIPTS_DIR/$_j.json" ]] || _missing_golden+="$_j "
  done
  if [[ -n "${_missing_golden// /}" ]]; then
    _replay_lane_log "Golden coverage gap: PASSing journey(s) without a replay script: ${_missing_golden}— the browser-qa agent should write a golden per PASS (they fall back to the slower LLM lane next iteration)."
  fi
  if declare -F record_telemetry_event >/dev/null 2>&1; then
    record_telemetry_event "golden_coverage" "$(jq -cn --argjson p "$_n_pass" --arg m "${_missing_golden% }" --arg n "$_rl_iter" '{passing:$p, missing_goldens:$m, iter_name:$n}' 2>/dev/null || printf '{"passing":%d,"missing_goldens":"%s"}' "$_n_pass" "${_missing_golden% }")"
  fi
}
