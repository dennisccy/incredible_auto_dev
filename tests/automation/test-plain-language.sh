#!/usr/bin/env bash
# test-plain-language.sh — PLAIN-1 self-test for scripts/automation/lib/plain-language.sh
# and its wiring into run-goal.sh / run-phase.sh.
#
# The lib ADDS plain-English explanation lines next to status/verdict codes; it must
# never touch a machine-parsed surface. Four assertion families:
#   (a) map completeness — every advertised key produces non-empty output
#   (b) coverage — every status run-goal.sh can emit, and every GoalEvalVerdict value,
#       has a map entry (discovery is grep-based so new halt sites self-enroll)
#   (c) purity + pins — helper output contains no machine-parsed marker and no
#       substring another test counts with grep -c; the pinned console literals are
#       still byte-present in the engine scripts
#   (d) wiring — both engines source the lib and actually call it
#
# API-free, no dispatch, runs in <2s.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ENGINE_ROOT"

LIB="scripts/automation/lib/plain-language.sh"
RUN_GOAL="scripts/automation/run-goal.sh"
RUN_PHASE="scripts/automation/run-phase.sh"

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}

if [[ ! -f "$LIB" ]]; then
  assert "lib exists: $LIB" fail
  echo "test-plain-language: $PASS pass, $FAIL fail"
  exit 1
fi

# shellcheck disable=SC1090
source "$LIB"

# ── (a) map completeness ─────────────────────────────────────────────────────
while IFS= read -r _k; do
  [[ -z "$_k" ]] && continue
  _out="$(explain_goal_status "$_k")"
  if [[ -n "$_out" && "$_out" == *"$_k"* ]]; then
    # output must NOT merely echo the key back — require at least one lowercase word
    :
  fi
  if [[ -n "$_out" ]] && grep -q '[a-z]' <<<"$_out"; then
    assert "status '$_k' has a plain explanation" pass
  else
    assert "status '$_k' has a plain explanation" fail
  fi
done < <(plain_goal_status_keys)

while IFS= read -r _k; do
  [[ -z "$_k" ]] && continue
  _out="$(explain_goal_verdict "$_k" lean)"
  if [[ -n "$_out" ]] && grep -q '[a-z]' <<<"$_out"; then
    assert "verdict '$_k' has a plain gloss" pass
  else
    assert "verdict '$_k' has a plain gloss" fail
  fi
done < <(plain_goal_verdict_keys)

while IFS= read -r _k; do
  [[ -z "$_k" ]] && continue
  _out="$(explain_phase "$_k")"
  if [[ -n "$_out" ]] && grep -q '[a-z]' <<<"$_out"; then
    assert "phase key '$_k' has a plain line" pass
  else
    assert "phase key '$_k' has a plain line" fail
  fi
done < <(plain_phase_keys)

# Unknown keys must be safe (rc 0, no crash under set -e) and print no gloss.
_unk_out="$(explain_goal_verdict "NO_SUCH_VERDICT" lean)" && assert "unknown verdict is rc-0 and silent" "$([[ -z "$_unk_out" ]] && echo pass || echo fail)"
_unk_st="$(explain_goal_status "NO_SUCH_STATUS")" && assert "unknown status is rc-0 (pointer only)" "$([[ "$_unk_st" != *"NO_SUCH_STATUS"* ]] && echo pass || echo fail)"

# ── (b) coverage ─────────────────────────────────────────────────────────────
_status_keys="$(plain_goal_status_keys)"
_emitted="$( { grep -oE 'write_session_summary "[A-Z_]+"' "$RUN_GOAL" | cut -d'"' -f2; grep -oE 'd\["status"\] = "[A-Z_]+"' "$RUN_GOAL" | cut -d'"' -f4; } | sort -u)"
if [[ -z "$_emitted" ]]; then
  assert "status discovery grep found emitted statuses" fail
else
  assert "status discovery grep found emitted statuses" pass
fi
while IFS= read -r _s; do
  [[ -z "$_s" ]] && continue
  if grep -qx "$_s" <<<"$_status_keys"; then
    assert "emitted status '$_s' is in the plain map" pass
  else
    assert "emitted status '$_s' is in the plain map" fail
  fi
done <<<"$_emitted"

_verdict_keys="$(plain_goal_verdict_keys)"
_enum_vals="$(python3 -c 'import sys; sys.path.insert(0, "scripts/automation/lib"); from verdicts import GoalEvalVerdict; print("\n".join(m.value for m in GoalEvalVerdict))')"
while IFS= read -r _v; do
  [[ -z "$_v" ]] && continue
  if grep -qx "$_v" <<<"$_verdict_keys"; then
    assert "GoalEvalVerdict '$_v' is in the plain map" pass
  else
    assert "GoalEvalVerdict '$_v' is in the plain map" fail
  fi
done <<<"$_enum_vals"

# ── (c) purity of helper output + pinned literals in the engines ─────────────
_all_out="$(
  while IFS= read -r _k; do [[ -n "$_k" ]] && explain_goal_status "$_k" demo-sid "$ENGINE_ROOT"; done < <(plain_goal_status_keys)
  while IFS= read -r _k; do [[ -n "$_k" ]] && explain_goal_verdict "$_k" lean && explain_goal_verdict "$_k" full; done < <(plain_goal_verdict_keys)
  while IFS= read -r _k; do [[ -n "$_k" ]] && explain_phase "$_k"; done < <(plain_phase_keys)
)"
for _banned in '**Verdict:**' 'Depth Recommendation' 'Target journeys:' 'depth-dispatched' 'FULL-RERUN mode' 'FIX-ONLY mode' '**Browser QA Verdict:**'; do
  if grep -qF "$_banned" <<<"$_all_out"; then
    assert "helper output never contains machine marker '$_banned'" fail
  else
    assert "helper output never contains machine marker '$_banned'" pass
  fi
done
if grep -qE '^##[[:space:]]' <<<"$_all_out"; then
  assert "helper output never opens an H2 heading" fail
else
  assert "helper output never opens an H2 heading" pass
fi

# Pinned console literals other tests / parsers depend on must remain byte-present.
grep -qF '[run-goal] Verdict: $VERDICT (next depth: $NEXT_DEPTH)' "$RUN_GOAL" \
  && assert "pin: run-goal verdict line untouched" pass || assert "pin: run-goal verdict line untouched" fail
grep -qF "Interactive pump/dispatch unavailable during goal-decomposer" "$RUN_GOAL" \
  && assert "pin: decomposer pump line untouched" pass || assert "pin: decomposer pump line untouched" fail
grep -qF 'ALL CHECKS PASSED' "$RUN_PHASE" \
  && assert "pin: run-phase ALL CHECKS PASSED untouched" pass || assert "pin: run-phase ALL CHECKS PASSED untouched" fail
grep -qF 'Test plan: SKIPPED' "$RUN_PHASE" \
  && assert "pin: run-phase 'Test plan: SKIPPED' untouched" pass || assert "pin: run-phase 'Test plan: SKIPPED' untouched" fail

# ── (d) wiring ───────────────────────────────────────────────────────────────
grep -qF 'lib/plain-language.sh' "$RUN_GOAL" \
  && assert "run-goal.sh sources the lib" pass || assert "run-goal.sh sources the lib" fail
grep -qF 'lib/plain-language.sh' "$RUN_PHASE" \
  && assert "run-phase.sh sources the lib" pass || assert "run-phase.sh sources the lib" fail
_calls_status="$(grep -c 'explain_goal_status ' "$RUN_GOAL" || true)"
if [[ "$_calls_status" -ge 15 ]]; then
  assert "run-goal.sh calls explain_goal_status at every halt/pause (found $_calls_status)" pass
else
  assert "run-goal.sh calls explain_goal_status at every halt/pause (found $_calls_status, need >=15)" fail
fi
grep -q 'explain_goal_verdict ' "$RUN_GOAL" \
  && assert "run-goal.sh calls explain_goal_verdict" pass || assert "run-goal.sh calls explain_goal_verdict" fail
_calls_phase="$(grep -c 'explain_phase ' "$RUN_PHASE" || true)"
if [[ "$_calls_phase" -ge 4 ]]; then
  assert "run-phase.sh calls explain_phase at review/QA/final sites (found $_calls_phase)" pass
else
  assert "run-phase.sh calls explain_phase at review/QA/final sites (found $_calls_phase, need >=4)" fail
fi

# The stable pointer line: every status explanation must point at the reading guide.
_ptr_ok=pass
while IFS= read -r _k; do
  [[ -z "$_k" ]] && continue
  explain_goal_status "$_k" | grep -qF 'docs/READING-REPORTS.md' || _ptr_ok=fail
done < <(plain_goal_status_keys)
assert "every status explanation ends with the READING-REPORTS pointer" "$_ptr_ok"

echo "test-plain-language: $PASS pass, $FAIL fail"
[[ "$FAIL" -eq 0 ]]
