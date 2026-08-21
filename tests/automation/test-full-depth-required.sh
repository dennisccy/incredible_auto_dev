#!/usr/bin/env bash
# test-full-depth-required.sh — fail-closed depth guard.
#
# THE INCIDENT THIS PREVENTS: run-goal.sh's depth arbiter is a COST ladder. When
# a full pass already ran inside the cadence window it demotes a spec's explicit
# `Depth: full` to lean ("full-cap", run-goal.sh) and dispatches goal-iter-lean.sh,
# which defaults CHAIN_LEAN_PARALLEL_BROWSER_QA to `replay` and forks a browser-QA
# service boot + replay lane the moment developer.done lands. That is correct for
# ordinary feature work. It is WRONG when full depth is the safety control itself
# — it silently removes the adversarial audit lane gating a destructive database
# write, and starts extra services against a knowingly damaged dataset.
#
# Logic under test:
#   lib/common.sh   goal_full_depth_required <spec_path>
#                     -> true iff CHAIN_REQUIRE_FULL_DEPTH is truthy OR the spec
#                        carries a `Depth enforcement: required` line. Default OFF,
#                        so ordinary projects and genuinely lean iterations are
#                        untouched.
#   run-goal.sh     _full_depth_pause  -> AWAITING_FULL_DEPTH before dispatch
#   goal-iter-lean.sh -> belt-and-braces: replay lane forced off under the requirement
#
# Structural assertions are grep/order based on purpose: cases 3-6 ("no mutation",
# "no replay", "no browser QA", "no second backend") are guaranteed by the guard
# halting BEFORE any dispatch, so the test proves the ORDERING and the exit rather
# than booting an engine (which would violate this repo's host-resource rules).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RG="$ENGINE_ROOT/scripts/automation/run-goal.sh"
LEAN="$ENGINE_ROOT/scripts/automation/goal-iter-lean.sh"

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

source "$ENGINE_ROOT/scripts/automation/lib/common.sh"
unset CHAIN_REQUIRE_FULL_DEPTH || true

SPEC_PLAIN="$WORK/spec-plain.md"
SPEC_REQ="$WORK/spec-required.md"
printf -- '- **Depth:** full\n- **Full trigger:** 1\n' > "$SPEC_PLAIN"
printf -- '- **Depth:** full\n- **Depth enforcement:** required\n' > "$SPEC_REQ"

# ── 1/8. default OFF: ordinary specs and other goals behave exactly as before ──
if goal_full_depth_required "$SPEC_PLAIN"; then
  assert "default: a plain 'Depth: full' spec does NOT trigger the guard (arbiter unchanged)" "fail"
else
  assert "default: a plain 'Depth: full' spec does NOT trigger the guard (arbiter unchanged)" "pass"
fi
if goal_full_depth_required ""; then
  assert "default: absent spec path does not trigger the guard (fail-open for unrelated goals)" "fail"
else
  assert "default: absent spec path does not trigger the guard (fail-open for unrelated goals)" "pass"
fi

# ── 2. the requirement is detectable both ways ────────────────────────────────
if goal_full_depth_required "$SPEC_REQ"; then
  assert "spec marker: 'Depth enforcement: required' triggers the guard" "pass"
else
  assert "spec marker: 'Depth enforcement: required' triggers the guard" "fail"
fi
if CHAIN_REQUIRE_FULL_DEPTH=true goal_full_depth_required "$SPEC_PLAIN"; then
  assert "env: CHAIN_REQUIRE_FULL_DEPTH=true triggers the guard session-wide" "pass"
else
  assert "env: CHAIN_REQUIRE_FULL_DEPTH=true triggers the guard session-wide" "fail"
fi
if CHAIN_REQUIRE_FULL_DEPTH=false goal_full_depth_required "$SPEC_PLAIN"; then
  assert "env: CHAIN_REQUIRE_FULL_DEPTH=false leaves the arbiter alone" "fail"
else
  assert "env: CHAIN_REQUIRE_FULL_DEPTH=false leaves the arbiter alone" "pass"
fi

# ── wiring: the guard runs at BOTH demotion sites, before dispatch ────────────
_line() { grep -n "$1" "$2" | head -1 | cut -d: -f1; }

if grep -q 'goal_full_depth_required "$ITER_SPEC_PATH"' "$RG"; then
  assert "wiring: run-goal.sh consults goal_full_depth_required" "pass"
else
  assert "wiring: run-goal.sh consults goal_full_depth_required" "fail"
fi

# NOTE: `DEPTH="lean"` appears at several unrelated sites (evidence-micro-path
# remap, parse default). Anchor on the arbiter's OWN substitution — the line
# immediately after its demotion banner — not the first match in the file.
_arb_guard="$(_line '_full_depth_pause "arbiter-demotion' "$RG")"
_arb_banner="$(_line 'the deterministic ladder demotes it to LEAN' "$RG")"
if [[ -n "$_arb_guard" && -n "$_arb_banner" && "$_arb_guard" -lt "$_arb_banner" ]]; then
  assert "site 1 (arbiter): the fail-closed guard precedes the arbiter's DEPTH=\"lean\" substitution" "pass"
else
  assert "site 1 (arbiter): the fail-closed guard precedes the arbiter's DEPTH=\"lean\" substitution" "fail"
fi

# ── site 3: an unparseable Depth line must not silently become lean either ────
_parse_guard="$(_line '_full_depth_pause "unparseable Depth' "$RG")"
_parse_default="$(_line "Could not parse Depth" "$RG")"
if [[ -n "$_parse_guard" && -n "$_parse_default" && "$_parse_guard" -lt "$_parse_default" ]]; then
  assert "site 3 (parse default): the guard precedes the 'Defaulting to lean' fallback" "pass"
else
  assert "site 3 (parse default): the guard precedes the 'Defaulting to lean' fallback" "fail"
fi

_nofin_guard="$(_line '_full_depth_pause "run-phase.sh lacks' "$RG")"
_nofin_fallback="$(_line 'does not yet support --no-finalize' "$RG")"
if [[ -n "$_nofin_guard" && -n "$_nofin_fallback" && "$_nofin_guard" -lt "$_nofin_fallback" ]]; then
  assert "site 2 (--no-finalize): the guard precedes the legacy lean fallback" "pass"
else
  assert "site 2 (--no-finalize): the guard precedes the legacy lean fallback" "fail"
fi

# ── 3-6. the halt happens BEFORE any dispatch, so nothing can be launched ─────
_pause_def="$(_line '_full_depth_pause() {' "$RG")"
_dispatch="$(_line 'Dispatching FULL pipeline via run-phase.sh' "$RG")"
if [[ -n "$_arb_guard" && -n "$_dispatch" && "$_arb_guard" -lt "$_dispatch" ]]; then
  assert "halt ordering: guard fires before ANY pipeline dispatch (no dev mutation, no replay, no QA, no 2nd backend)" "pass"
else
  assert "halt ordering: guard fires before ANY pipeline dispatch (no dev mutation, no replay, no QA, no 2nd backend)" "fail"
fi
if awk "NR>=$_pause_def && NR<=$((_pause_def + 45))" "$RG" | grep -q '^  exit 0$'; then
  assert "halt: the pause exits (never falls through to a lean dispatch)" "pass"
else
  assert "halt: the pause exits (never falls through to a lean dispatch)" "fail"
fi
if awk "NR>=$_pause_def && NR<=$((_pause_def + 45))" "$RG" | grep -qE 'bash .*(goal-iter-lean|run-phase)\.sh'; then
  assert "halt: the pause body launches no pipeline" "fail"
else
  assert "halt: the pause body launches no pipeline" "pass"
fi

# ── 7. requirement recorded as UNMET, never silently rewritten ────────────────
if awk "NR>=$_pause_def && NR<=$((_pause_def + 45))" "$RG" | grep -q 'depth-requirement-unmet'; then
  assert "record: an explicit depth-requirement-unmet marker is written" "pass"
else
  assert "record: an explicit depth-requirement-unmet marker is written" "fail"
fi
if awk "NR>=$_pause_def && NR<=$((_pause_def + 45))" "$RG" | grep -q 'AWAITING_FULL_DEPTH'; then
  assert "record: session status becomes AWAITING_FULL_DEPTH (resumable)" "pass"
else
  assert "record: session status becomes AWAITING_FULL_DEPTH (resumable)" "fail"
fi

# ── 10. a resume cannot inherit a stale lean dispatch decision ────────────────
if awk "NR>=$_pause_def && NR<=$((_pause_def + 45))" "$RG" | grep -q 'rm -f "$ITER_DIR/depth-dispatched"'; then
  assert "resume: the pause clears depth-dispatched so a retry cannot inherit stale 'lean'" "pass"
else
  assert "resume: the pause clears depth-dispatched so a retry cannot inherit stale 'lean'" "fail"
fi

# ── 4/9. replay lane: forced off under the requirement, untouched otherwise ───
if grep -q 'full-depth-required' "$LEAN"; then
  assert "replay guard: goal-iter-lean.sh forces the parallel browser-QA lane off under the requirement" "pass"
else
  assert "replay guard: goal-iter-lean.sh forces the parallel browser-QA lane off under the requirement" "fail"
fi
if grep -q '_BQA_REQUESTED="${CHAIN_LEAN_PARALLEL_BROWSER_QA:-replay}"' "$LEAN"; then
  assert "replay guard: legitimate lean replay default ('replay') is NOT globally disabled" "pass"
else
  assert "replay guard: legitimate lean replay default ('replay') is NOT globally disabled" "fail"
fi
_bqa_default="$(_line '_BQA_REQUESTED="${CHAIN_LEAN_PARALLEL_BROWSER_QA:-replay}"' "$LEAN")"
_bqa_guard="$(_line 'full-depth-required' "$LEAN")"
if [[ -n "$_bqa_guard" && -n "$_bqa_default" && "$_bqa_guard" -gt "$_bqa_default" ]]; then
  assert "replay guard: the override runs after mode resolution, so it wins" "pass"
else
  assert "replay guard: the override runs after mode resolution, so it wins" "fail"
fi

# ── status registration ──────────────────────────────────────────────────────
if "$ENGINE_ROOT/scripts/automation/lib/plain-language.sh" >/dev/null 2>&1 || true; then :; fi
if grep -q 'AWAITING_FULL_DEPTH' "$ENGINE_ROOT/scripts/automation/lib/plain-language.sh"; then
  assert "status: AWAITING_FULL_DEPTH is registered in the plain-language keys + explainer" "pass"
else
  assert "status: AWAITING_FULL_DEPTH is registered in the plain-language keys + explainer" "fail"
fi


# ══════════════════════════════════════════════════════════════════════════════
# PRECEDENCE: a hard full-depth requirement outranks the COST ladder.
#
# These cases EXECUTE the real arbiter text rather than grepping it: the ladder
# is inline in run-goal.sh, so we slice it out between two stable anchors and
# eval it in a sandbox with the external predicates stubbed. That proves actual
# branch behaviour without booting an engine (host-safe, no services, no DB).
# ══════════════════════════════════════════════════════════════════════════════
_arb_start="$(grep -n '_arb_decision="" _arb_reason=""' "$RG" | head -1 | cut -d: -f1)"
_arb_end="$(grep -n 'PRIOR_DEPTH==full: the evaluator itself asked for full' "$RG" | head -1 | cut -d: -f1)"
_arb_end=$(( _arb_end + 3 ))   # ..through the ladder's closing `fi`
awk -v s="$_arb_start" -v e="$_arb_end" 'NR>=s && NR<=e' "$RG" > "$WORK/arb-block.sh"
if bash -n "$WORK/arb-block.sh" 2>/dev/null; then
  assert "harness: the arbiter ladder slices out as a syntactically complete block" "pass"
else
  assert "harness: the arbiter ladder slices out as a syntactically complete block" "fail"
fi

# run_arb <hard:0|1> <budget_marker:0|1> <full_in_window:0|1> <prior_verdict> <prior_depth>
# -> echoes "<decision>:<reason>"
run_arb() {
  local hard="$1" budget="$2" inwin="$3" pv="$4" pd="$5"
  (
    set +e
    PRIOR_VERDICT="$pv"; PRIOR_DEPTH="$pd"
    CURRENT_ITER=8; LEAN_STREAK=0
    GOAL_SESSION_DIR_LOCAL="$WORK/sess"; JOURNEY_HISTORY="$WORK/jh.json"
    ITER_SPEC_PATH="$WORK/spec.md"; _budget_demoted=""; _use_legacy_allowlist=""
    mkdir -p "$WORK/sess/iter-7"
    _prev_coh_file="$WORK/sess/iter-7/coherence.md"
    _prev_budget_marker="$WORK/sess/iter-7/budget-breached"
    rm -f "$_prev_budget_marker"; [[ "$budget" == 1 ]] && : > "$_prev_budget_marker"
    printf -- '- **Depth:** full\n- **Full trigger:** 1\n' > "$ITER_SPEC_PATH"
    [[ "$hard" == 1 ]] && printf -- '- **Depth enforcement:** required\n' >> "$ITER_SPEC_PATH"
    goal_full_ran_in_window() { [[ "$inwin" == 1 ]]; }
    goal_cadence_forces_full() { return 1; }
    goal_new_fullstack_journey() { return 1; }
    record_telemetry_event() { :; }
    # shellcheck disable=SC1090
    . "$WORK/arb-block.sh" >/dev/null 2>&1
    printf '%s:%s' "$_arb_decision" "$_arb_reason"
  )
}

# 1. ordinary full + budget-breach -> still demoted to lean (cost policy intact)
r="$(run_arb 0 1 0 CONTINUE full)"
[[ "$r" == "lean:budget-breach" ]] \
  && assert "ordinary: Depth full + budget-breach -> lean (cost arbiter unchanged)" "pass" \
  || assert "ordinary: Depth full + budget-breach -> lean (got '$r')" "fail"

# 2. hard-required + budget-breach -> stays FULL
r="$(run_arb 1 1 0 CONTINUE full)"
[[ "$r" == "full:hard-full-required" ]] \
  && assert "precedence: hard-required + budget-breach -> FULL" "pass" \
  || assert "precedence: hard-required + budget-breach -> FULL (got '$r')" "fail"

# 3. hard-required + full-cap -> stays FULL
r="$(run_arb 1 0 1 CONTINUE full)"
[[ "$r" == "full:hard-full-required" ]] \
  && assert "precedence: hard-required + full-cap -> FULL" "pass" \
  || assert "precedence: hard-required + full-cap -> FULL (got '$r')" "fail"

# 4. hard-required + evaluator recommends lean -> stays FULL
r="$(run_arb 1 0 0 CONTINUE lean)"
[[ "$r" == "full:hard-full-required" ]] \
  && assert "precedence: hard-required + evaluator-recommends-lean -> FULL" "pass" \
  || assert "precedence: hard-required + evaluator-recommends-lean -> FULL (got '$r')" "fail"

# 9. ordinary full-cap and evaluator-lean demotions still fire for normal iters
r="$(run_arb 0 0 1 CONTINUE full)"
[[ "$r" == "lean:full-cap" ]] \
  && assert "ordinary: Depth full + full-cap -> lean (cost arbiter unchanged)" "pass" \
  || assert "ordinary: Depth full + full-cap -> lean (got '$r')" "fail"
r="$(run_arb 0 0 0 CONTINUE lean)"
[[ "$r" == "lean:evaluator-requested-lean" ]] \
  && assert "ordinary: Depth full + evaluator-lean -> lean (cost arbiter unchanged)" "pass" \
  || assert "ordinary: Depth full + evaluator-lean -> lean (got '$r')" "fail"

# sanctioned fulls still win for ordinary iterations
r="$(run_arb 0 1 1 ESCALATE lean)"
[[ "$r" == "full:prior-verdict-ESCALATE" ]] \
  && assert "ordinary: prior ESCALATE still grants full ahead of cost rungs" "pass" \
  || assert "ordinary: prior ESCALATE still grants full ahead of cost rungs (got '$r')" "fail"

# 6. AWAITING_FULL_DEPTH is no longer reachable from a COST demotion
r="$(run_arb 1 1 1 CONTINUE lean)"
[[ "$r" == full:* ]] \
  && assert "no cost-driven pause: hard-required never resolves lean, so the arbiter cannot pause on cost" "pass" \
  || assert "no cost-driven pause: hard-required never resolves lean (got '$r')" "fail"

# 5/8. genuine INABILITY still pauses: the --no-finalize and unparseable-depth
# guards are capability failures, not cost policy, and remain wired.
if grep -q '_full_depth_pause "run-phase.sh lacks --no-finalize"' "$RG" \
   && grep -q '_full_depth_pause "unparseable Depth' "$RG"; then
  assert "genuine inability: capability guards (--no-finalize, unparseable depth) still pause" "pass"
else
  assert "genuine inability: capability guards (--no-finalize, unparseable depth) still pause" "fail"
fi

# 7. the historical budget marker is read, never written/removed by the arbiter
if grep -qE '(rm|mv|:) *> *"\$_prev_budget_marker"' "$RG"; then
  assert "evidence: arbiter never deletes/overwrites the budget-breached marker" "fail"
else
  assert "evidence: arbiter never deletes/overwrites the budget-breached marker" "pass"
fi
if grep -q 'depth_cost_overridden' "$RG"; then
  assert "evidence: the overridden cost rung is recorded in telemetry" "pass"
else
  assert "evidence: the overridden cost rung is recorded in telemetry" "fail"
fi

echo ""
echo "  ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
