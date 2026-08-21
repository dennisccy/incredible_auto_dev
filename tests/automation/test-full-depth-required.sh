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
# Slice the REAL function body (first column-0 `}` after its header) rather than
# guessing a line window: the per-path remedy `case` made a fixed +45 window stop
# short of the exit, which is an anchor defect, not a behaviour change.
# Materialize the slice ONCE into a file. `awk … | grep -q` is a pipefail
# landmine: grep -q exits on its first match, awk dies with SIGPIPE, and the
# pipeline's status becomes 141 — so the assertion failed at random (observed
# ~2 runs in 5 once the function body grew). Nothing here may depend on that race.
_pause_end="$(awk -v s="$_pause_def" 'NR>s && $0=="}" {print NR; exit}' "$RG")"
_pause_body="$WORK/pause-body.txt"
awk "NR>=$_pause_def && NR<=${_pause_end:-0}" "$RG" > "$_pause_body"
if [[ -n "$_pause_end" ]] && grep -q '^  exit 0$' "$_pause_body"; then
  assert "halt: the pause exits (never falls through to a lean dispatch)" "pass"
else
  assert "halt: the pause exits (never falls through to a lean dispatch)" "fail"
fi
if grep -qE 'bash .*(goal-iter-lean|run-phase)\.sh' "$_pause_body"; then
  assert "halt: the pause body launches no pipeline" "fail"
else
  assert "halt: the pause body launches no pipeline" "pass"
fi

# ── 7. requirement recorded as UNMET, never silently rewritten ────────────────
if grep -q 'depth-requirement-unmet' "$_pause_body"; then
  assert "record: an explicit depth-requirement-unmet marker is written" "pass"
else
  assert "record: an explicit depth-requirement-unmet marker is written" "fail"
fi
if grep -q 'AWAITING_FULL_DEPTH' "$_pause_body"; then
  assert "record: session status becomes AWAITING_FULL_DEPTH (resumable)" "pass"
else
  assert "record: session status becomes AWAITING_FULL_DEPTH (resumable)" "fail"
fi

# ── 10. a resume cannot inherit a stale lean dispatch decision ────────────────
if grep -q 'rm -f "$ITER_DIR/depth-dispatched"' "$_pause_body"; then
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


# ── resume: the new pause status must be in the resumable allowlist ──────────
# _full_depth_pause writes a status the operator clears by removing the CAUSE
# (cadence window, CHAIN_FULL_CADENCE_CAP, CHAIN_DEPTH_ARBITER) and resuming. If
# `--resume` does not reset that status to in_progress, the session is stuck in a
# pause it can never leave — and the requirement's only escape becomes deleting it.
_allow="$(grep -n 'RUN_MODE" == "resume" and d.get("status") in' "$RG" | head -1 | cut -d: -f1)"
sed -n "${_allow:-0}p" "$RG" > "$WORK/allow.txt"
sed -n "$((${_allow:-0} + 1))p" "$RG" > "$WORK/allow-next.txt"
if [[ -n "$_allow" ]] && grep -q 'AWAITING_FULL_DEPTH' "$WORK/allow.txt"; then
  assert "resume: AWAITING_FULL_DEPTH is in the resumable-status allowlist" "pass"
else
  assert "resume: AWAITING_FULL_DEPTH is in the resumable-status allowlist" "fail"
fi
if [[ -n "$_allow" ]] && grep -q 'in_progress' "$WORK/allow-next.txt"; then
  assert "resume: that allowlist is the one that resets the session to in_progress" "pass"
else
  assert "resume: that allowlist is the one that resets the session to in_progress" "fail"
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

# run_arb <hard:0|1> <budget_marker:0|1> <full_in_window:0|1> <prior_verdict> <prior_depth> [iso:0|1]
# -> echoes "<decision>:<reason>"; telemetry event names land in $WORK/arb-events.
# `iso` declares the requirement the OTHER way — a `Maintenance isolation: required`
# line and no `Depth enforcement:` line — which must reach the same precedence rung.
run_arb() {
  local hard="$1" budget="$2" inwin="$3" pv="$4" pd="$5" iso="${6:-0}"
  rm -f "$WORK/arb-events"
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
    [[ "$iso" == 1 ]] && printf -- '- **Maintenance isolation:** required\n' >> "$ITER_SPEC_PATH"
    goal_full_ran_in_window() { [[ "$inwin" == 1 ]]; }
    goal_cadence_forces_full() { return 1; }
    goal_new_fullstack_journey() { return 1; }
    record_telemetry_event() { printf '%s\n' "$1" >> "$WORK/arb-events"; }
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

# ══════════════════════════════════════════════════════════════════════════════
# LEGACY ALLOWLIST PATH: CHAIN_DEPTH_ARBITER=false must not defeat the
# requirement.
#
# THE HOLE: the whole precedence rung AND the _full_depth_pause backstop live
# inside `if [[ "${CHAIN_DEPTH_ARBITER:-true}" == "true" ... ]]`. With the knob
# off (or on the arbiter's own PRIOR_DEPTH==full rung) control falls through to
# the SPEED-10 allowlist, which has no goal_full_depth_required guard at all: a
# hard-required spec that names no `Full trigger:` was demoted to lean with a
# `depth_demoted` event and NO pause. The knob was even documented as a resume
# hatch for AWAITING_FULL_DEPTH — i.e. the advertised escape silently removed
# the control instead of the cause.
#
# Sliced and executed like the ladder above: the allowlist block is inline, so
# take it between its own `if` and the matching 2-space `fi`.
# ══════════════════════════════════════════════════════════════════════════════
_leg_start="$(grep -n 'DEPTH" == "full" && -n "\$_use_legacy_allowlist"' "$RG" | head -1 | cut -d: -f1)"
_leg_end="$(awk -v s="$_leg_start" 'NR>s && $0=="  fi" {print NR; exit}' "$RG")"
awk -v s="$_leg_start" -v e="$_leg_end" 'NR>=s && NR<=e' "$RG" > "$WORK/legacy-block.sh"
if [[ -n "$_leg_start" && -n "$_leg_end" ]] && bash -n "$WORK/legacy-block.sh" 2>/dev/null; then
  assert "harness: the legacy allowlist slices out as a syntactically complete block" "pass"
else
  assert "harness: the legacy allowlist slices out as a syntactically complete block" "fail"
fi

# run_legacy <hard:0|1> <full_trigger:0|1> <prior_verdict>
# -> "PAUSE:<reason>:<step>" when the guard pauses, else "DEPTH:<effective depth>"
run_legacy() {
  local hard="$1" trig="$2" pv="$3"
  # The pause stub cannot echo its result: the sourced block's stdout is
  # discarded (engine chatter) and `exit 0` skips the tail printf. Route both
  # outcomes through files instead.
  rm -f "$WORK/legacy-pause" "$WORK/legacy-depth"
  (
    set +e
    PRIOR_VERDICT="$pv"
    CURRENT_ITER=8; LEAN_STREAK=0; DEPTH="full"; _use_legacy_allowlist=1
    GOAL_SESSION_DIR_LOCAL="$WORK/sess"; ITER_SPEC_PATH="$WORK/legacy-spec.md"
    mkdir -p "$WORK/sess/iter-7"
    printf -- '- **Depth:** full\n' > "$ITER_SPEC_PATH"
    [[ "$trig" == 1 ]] && printf -- '- **Full trigger:** 1 — new journey\n' >> "$ITER_SPEC_PATH"
    [[ "$hard" == 1 ]] && printf -- '- **Depth enforcement:** required\n' >> "$ITER_SPEC_PATH"
    goal_cadence_forces_full() { return 1; }
    record_telemetry_event() { :; }
    _full_depth_pause() { printf 'PAUSE:%s:%s' "$1" "$2" > "$WORK/legacy-pause"; exit 0; }
    # shellcheck disable=SC1090
    . "$WORK/legacy-block.sh" >/dev/null 2>&1
    printf 'DEPTH:%s' "$DEPTH" > "$WORK/legacy-depth"
  )
  if [[ -s "$WORK/legacy-pause" ]]; then cat "$WORK/legacy-pause"; else cat "$WORK/legacy-depth" 2>/dev/null; fi
}

# a. hard-required + legacy path + no Full trigger -> PAUSE, never lean
r="$(run_legacy 1 0 CONTINUE)"
if [[ "$r" == PAUSE:*:depth-legacy-allowlist ]]; then
  assert "legacy allowlist: hard-required + no trigger -> AWAITING_FULL_DEPTH (step depth-legacy-allowlist)" "pass"
else
  assert "legacy allowlist: hard-required + no trigger -> AWAITING_FULL_DEPTH (got '$r')" "fail"
fi

# b. control — ordinary iteration on the same path still demotes to lean
r="$(run_legacy 0 0 CONTINUE)"
[[ "$r" == "DEPTH:lean" ]] \
  && assert "legacy allowlist control: ordinary + no trigger -> lean (SPEED-10 unchanged)" "pass" \
  || assert "legacy allowlist control: ordinary + no trigger -> lean (got '$r')" "fail"

# c. control — a hard-required spec that DOES name a trigger runs full, no pause
r="$(run_legacy 1 1 CONTINUE)"
[[ "$r" == "DEPTH:full" ]] \
  && assert "legacy allowlist control: hard-required + trigger -> full, no pause" "pass" \
  || assert "legacy allowlist control: hard-required + trigger -> full, no pause (got '$r')" "fail"

# d. control — ordinary spec with a trigger is untouched
r="$(run_legacy 0 1 CONTINUE)"
[[ "$r" == "DEPTH:full" ]] \
  && assert "legacy allowlist control: ordinary + trigger -> full (SPEED-10 unchanged)" "pass" \
  || assert "legacy allowlist control: ordinary + trigger -> full (got '$r')" "fail"

# e. CHAIN_DEPTH_ARBITER=false must never be offered as a way OUT of this pause.
#    It removes the precedence rung AND the backstop and routes to the legacy
#    allowlist — the path that used to demote a hard-required iteration. (The
#    knob's ordinary "spec asked full, ladder demoted it" log line is a different
#    message and stays; only pause-guidance contexts are checked here.)
_hatch_ok=pass
# Each of these files documents the pause on ONE line. The knob may appear there
# only as an explicit non-remedy, never in the list of things to try.
for f in "$ENGINE_ROOT/docs/goal-mode-quickstart.md" \
         "$ENGINE_ROOT/README.md" \
         "$ENGINE_ROOT/skills/goal-interactive-dispatch.md" \
         "$ENGINE_ROOT/.claude/skills/goal-interactive-dispatch.md"; do
  grep -h 'AWAITING_FULL_DEPTH' "$f" 2>/dev/null > "$WORK/awfd.txt" || true
  grep 'CHAIN_DEPTH_ARBITER=false' "$WORK/awfd.txt" > "$WORK/awfd-knob.txt" || true
  if [[ -s "$WORK/awfd-knob.txt" ]]; then
    grep -qE 'NOT remed|NOT a way|is not a way|never suggest|not a hatch' "$WORK/awfd-knob.txt" || _hatch_ok=fail
    # the old recommendation shapes must be gone outright
    grep -qiE 'restore the legacy allowlist: `?CHAIN_DEPTH_ARBITER=false|or `?CHAIN_DEPTH_ARBITER=false`?,' "$WORK/awfd-knob.txt" && _hatch_ok=fail
  fi
done
# run-goal.sh's own status-header entry for the pause
awk '/^#   AWAITING_FULL_DEPTH/{f=1} f&&/^#/{print} f&&!/^#/{exit}' "$RG" > "$WORK/hdr.txt"
grep -q 'CHAIN_DEPTH_ARBITER=false' "$WORK/hdr.txt" && _hatch_ok=fail
# _full_depth_pause: never as a bulleted option; if named at all, only as a denial
_fp_start="$(grep -n '^_full_depth_pause()' "$RG" | head -1 | cut -d: -f1)"
_fp_end="$(awk -v s="$_fp_start" 'NR>s && $0=="}" {print NR; exit}' "$RG")"
awk -v s="$_fp_start" -v e="$_fp_end" 'NR>=s && NR<=e' "$RG" > "$WORK/pause-fn.sh"
grep -qE 'echo "[[:space:]]*\*.*CHAIN_DEPTH_ARBITER=false' "$WORK/pause-fn.sh" && _hatch_ok=fail
if grep -q 'CHAIN_DEPTH_ARBITER' "$WORK/pause-fn.sh"; then
  grep -qiE 'is NOT|not a hatch|does not|never' "$WORK/pause-fn.sh" || _hatch_ok=fail
else
  _hatch_ok=fail   # the ruling requires the denial to be stated, not just omitted
fi
assert "guidance: CHAIN_DEPTH_ARBITER=false is denied, never offered, as an AWAITING_FULL_DEPTH remedy" "$_hatch_ok"

# f. the pause guidance is per-path, not one generic arbiter-only list
if grep -q 'depth-legacy-allowlist' "$RG" \
   && grep -q 'remedy=' "$RG" \
   && grep -q 'no-finalize' "$RG"; then
  assert "guidance: _full_depth_pause carries per-path remedy text and a marker remedy= field" "pass"
else
  assert "guidance: _full_depth_pause carries per-path remedy text and a marker remedy= field" "fail"
fi


# ══════════════════════════════════════════════════════════════════════════════
# MAINTENANCE ISOLATION *IS* A FULL-DEPTH REQUIREMENT.
#
# The contract's own words are "full reviewer/QA/auditor/coherence/evaluator depth
# REQUIRED; application-service and browser execution FORBIDDEN" — but
# goal_full_depth_required never consulted isolation, so the first half was
# advertised and not enforced. Two live holes:
#   (a) an isolated `Depth: full` spec could still be cost-demoted by the arbiter
#       (full-cap / budget-breach / evaluator-lean) unless the operator ALSO wrote
#       `Depth enforcement: required`;
#   (b) an isolated `Depth: lean`/`evidence` spec dispatched goal-iter-lean.sh,
#       which has no isolation handling at all: its boot unit calls
#       ensure_services_running bare, the refusal is swallowed inside the parallel
#       fork, SKIPPED rows blame "frontend not running", no `**Reason:** maintenance
#       isolation` line ever reaches ui-test-results.md — so the evaluator's
#       carve-out cannot fire and journeys go `unknown`. With the fork off, the
#       inline path aborts the executor under `set -e` AFTER developer+reviewer
#       already mutated the tree.
# Fix: isolation implies the hard requirement (so the existing precedence rung and
# the existing pause sites cover it), and a non-full isolated spec pauses BEFORE
# dispatch. No lean spec is ever promoted.
# ══════════════════════════════════════════════════════════════════════════════
_iso_spec="$WORK/iso-spec.md"; _plain_spec="$WORK/plain-spec.md"
printf -- '- **Depth:** full\n- **Maintenance isolation:** required\n' > "$_iso_spec"
printf -- '- **Depth:** full\n' > "$_plain_spec"

goal_full_depth_required "$_plain_spec" \
  && assert "predicate: a plain spec is still NOT a full-depth requirement (default OFF)" "fail" \
  || assert "predicate: a plain spec is still NOT a full-depth requirement (default OFF)" "pass"
goal_full_depth_required "$_iso_spec" \
  && assert "predicate: a spec declaring maintenance isolation IS a full-depth requirement" "pass" \
  || assert "predicate: a spec declaring maintenance isolation IS a full-depth requirement" "fail"
( CHAIN_MAINTENANCE_ISOLATION=true; goal_full_depth_required "$_plain_spec" ) \
  && assert "predicate: session-level CHAIN_MAINTENANCE_ISOLATION IS a full-depth requirement" "pass" \
  || assert "predicate: session-level CHAIN_MAINTENANCE_ISOLATION IS a full-depth requirement" "fail"

# arbiter: an isolated full spec that never says `Depth enforcement:` must still
# outrank a cost rung, and must record the rung it overrode.
r="$(run_arb 0 0 1 CONTINUE full 1)"
if [[ "$r" == "full:hard-full-required" ]] && grep -q 'depth_cost_overridden' "$WORK/arb-events" 2>/dev/null; then
  assert "precedence: isolated full + full-cap -> FULL, overridden rung telemetered" "pass"
else
  assert "precedence: isolated full + full-cap -> FULL, overridden rung telemetered (got '$r')" "fail"
fi

# The pre-dispatch guard: sliced from run-goal.sh and executed, like the ladder.
_ireq_start="$(grep -n 'apply_maintenance_isolation_from_spec "\$ITER_SPEC_PATH"' "$RG" | head -1 | cut -d: -f1)"
_ireq_end="$(awk -v s="$_ireq_start" 'NR>s && /record_telemetry_event "iter_dispatch"/ {print NR; exit}' "$RG")"
awk -v s="$_ireq_start" -v e="$_ireq_end" 'NR>=s && NR<e' "$RG" > "$WORK/iso-guard.sh"
if [[ -n "$_ireq_start" && -n "$_ireq_end" ]] && bash -n "$WORK/iso-guard.sh" 2>/dev/null; then
  assert "harness: the isolation/full-depth guard slices out as a complete block" "pass"
else
  assert "harness: the isolation/full-depth guard slices out as a complete block" "fail"
fi

# run_iso_guard <spec:iso|plain> <depth> -> "PAUSE:<reason>:<step>" | "OK:<depth>"
run_iso_guard() {
  local kind="$1" depth="$2"
  rm -f "$WORK/iso-pause" "$WORK/iso-ok"
  (
    set +e
    unset CHAIN_MAINTENANCE_ISOLATION CHAIN_MAINTENANCE_ISOLATION_SOURCE
    DEPTH="$depth"; TARGET_JOURNEYS=""
    ITER_SPEC_PATH="$WORK/guard-spec.md"
    printf -- '- **Depth:** %s\n' "$depth" > "$ITER_SPEC_PATH"
    [[ "$kind" == iso ]] && printf -- '- **Maintenance isolation:** required\n' >> "$ITER_SPEC_PATH"
    record_telemetry_event() { :; }
    _full_depth_pause() { printf 'PAUSE:%s:%s' "$1" "$2" > "$WORK/iso-pause"; exit 0; }
    # shellcheck disable=SC1090
    . "$WORK/iso-guard.sh" >/dev/null 2>&1
    printf 'OK:%s' "$DEPTH" > "$WORK/iso-ok"
  )
  if [[ -s "$WORK/iso-pause" ]]; then cat "$WORK/iso-pause"; else cat "$WORK/iso-ok" 2>/dev/null; fi
}

r="$(run_iso_guard iso lean)"
[[ "$r" == PAUSE:*:isolation-requires-full ]] \
  && assert "isolation: a Depth-lean isolated spec PAUSES before any dispatch" "pass" \
  || assert "isolation: a Depth-lean isolated spec PAUSES before any dispatch (got '$r')" "fail"
r="$(run_iso_guard iso evidence)"
[[ "$r" == PAUSE:*:isolation-requires-full ]] \
  && assert "isolation: a Depth-evidence isolated spec PAUSES before any dispatch" "pass" \
  || assert "isolation: a Depth-evidence isolated spec PAUSES before any dispatch (got '$r')" "fail"
r="$(run_iso_guard iso full)"
[[ "$r" == "OK:full" ]] \
  && assert "isolation: an isolated FULL spec is dispatched, not paused" "pass" \
  || assert "isolation: an isolated FULL spec is dispatched, not paused (got '$r')" "fail"
r="$(run_iso_guard plain lean)"
[[ "$r" == "OK:lean" ]] \
  && assert "isolation control: an ordinary lean iteration is untouched (no promotion, no pause)" "pass" \
  || assert "isolation control: an ordinary lean iteration is untouched (got '$r')" "fail"

# ── operator-only spec lines must not be silently rewritten away on resume ────
# The depth-parse pause fires exactly when the spec's `Depth:` line does not
# grep; that is also the condition under which --resume declines to reuse the
# spec and re-runs the decomposer, which regenerates the file and — being
# forbidden to emit them — drops `Depth enforcement:` / `Maintenance isolation:`.
# The engine must at minimum say so loudly and record it.
_redisp="$(grep -n 'step_invalidate_from decomposer "\$ITER_DIR"' "$RG" | head -1 | cut -d: -f1)"
if [[ -n "$_redisp" ]] && { awk -v s="$_redisp" 'NR>=s-24 && NR<=s' "$RG" > "$WORK/redisp.txt"; grep -q 'will DROP operator-only line' "$WORK/redisp.txt"; }; then
  assert "resume: regenerating a spec that carries operator-only lines warns loudly" "pass"
else
  assert "resume: regenerating a spec that carries operator-only lines warns loudly" "fail"
fi
if [[ -n "$_redisp" ]] && { awk -v s="$_redisp" 'NR>=s-24 && NR<=s' "$RG" > "$WORK/redisp.txt"; grep -q 'spec_regenerated' "$WORK/redisp.txt"; }; then
  assert "resume: the dropped operator lines are recorded as telemetry" "pass"
else
  assert "resume: the dropped operator lines are recorded as telemetry" "fail"
fi
if grep -q 'still-unparseable' "$RG" \
   && grep -q 'still-unparseable' "$ENGINE_ROOT/docs/goal-mode-quickstart.md" \
   && grep -q 'still-unparseable' "$ENGINE_ROOT/skills/goal-interactive-dispatch.md"; then
  assert "resume: depth-parse guidance says to fix the line BEFORE resuming" "pass"
else
  assert "resume: depth-parse guidance says to fix the line BEFORE resuming" "fail"
fi

# isolation-requires-full must be registered everywhere the other steps are
_reg_ok=pass
for f in "$RG" "$ENGINE_ROOT/docs/goal-mode-telemetry.md" \
         "$ENGINE_ROOT/docs/goal-mode-quickstart.md" \
         "$ENGINE_ROOT/README.md" \
         "$ENGINE_ROOT/skills/goal-interactive-dispatch.md" \
         "$ENGINE_ROOT/.claude/skills/goal-interactive-dispatch.md"; do
  grep -q 'isolation-requires-full' "$f" || _reg_ok=fail
done
assert "registration: isolation-requires-full appears in the engine, telemetry doc, quickstart, README and skill" "$_reg_ok"

echo ""
echo "  ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
