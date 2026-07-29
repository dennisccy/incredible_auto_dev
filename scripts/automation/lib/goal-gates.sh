#!/usr/bin/env bash
# goal-gates.sh — deterministic verdict gates for goal mode.
#
# Sourced by run-goal.sh. Historically every quality decision (goal reached?
# regressed? anti-goal violated?) rested on ONE goal-evaluator output parsed by
# grep; nothing mechanical cross-checked it. These gates make the high-stakes
# transitions fail-closed:
#
#   goal_gate_filter_verdict   the single seam run-goal.sh calls between
#                              parsing the evaluator's verdict and acting on
#                              it. Echoes the FINAL verdict on stdout (all
#                              diagnostics go to stderr / gate-report.md):
#     ① malformed/unknown verdict → CONTINUE once, ABORT_MALFORMED when it
#       repeats (the old code fail-opened to CONTINUE forever)
#     ② GOAL_ACHIEVED → deterministic achievement gate: every journey passing
#       in journey-history.json, coherence not FAIL/stub, no FAIL cells in the
#       browser results, no critical scan findings, no passing→failing
#       regressions vs the pre-iteration snapshot, no goal-edited journey
#       still passing on its OLD text (journeys-changed.md drift check).
#       Any miss → demoted to CONTINUE with a written gate-report.md
#     ③ gates green → two-key confirm: ONE fresh-context adversarial
#       evaluator dispatch (strong tier, max effort) must answer
#       CONFIRM_ACHIEVED; anything else demotes to CONTINUE (fail-closed)
#     ④ other verdicts → regression cross-check is reported; with
#       CHAIN_STRICT_REGRESSION_HALT=true an undeclared regression escalates
#       the verdict to REGRESSION
#
#   goal_gate_build_diff_artifacts   writes iter-diff.md (bounded diff view)
#       and scan-report.md (secret/dependency/license scan of the product diff,
#       tracked + untracked, harness bookkeeping path-excluded via
#       CHAIN_SCAN_BOOKKEEPING_EXCLUDES) for the evaluator to consume.
#       Best-effort.
#
# Escape hatch: CHAIN_GOAL_GATES=false disables gating (filter echoes the
# verdict through unchanged). Re-enable it in the same session — a silently
# disabled gate is the #1 degradation mode (.claude/letter-to-future-sessions.md).
#
# Self-test: bash scripts/automation/lib/goal-gates.sh --self-test

_GOAL_GATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Harness bookkeeping namespaces NEVER fed to the secret scanner: the gate must
# scan product changes, not the pipeline's own generated output (scan-report /
# iter-diff / trace / summaries quote findings → self-referential CRITICAL
# recursion; see .claude/anti-patterns/22-scanner-flags-own-output.md). Same set as CHAIN_STEP_HASH_EXCLUDES
# (lib/checkpoint.sh). Space-separated, env-overridable; note ':=' re-applies
# the default when the var is exported EMPTY (a single space means "no
# exclusions").
: "${CHAIN_SCAN_BOOKKEEPING_EXCLUDES:=runs reports docs/handoffs docs/phases}"

goal_gates_enabled() {
  [[ "${CHAIN_GOAL_GATES:-true}" == "true" ]]
}

# Build iter-diff.md + scan-report.md for an iteration. Never fails the caller.
# $1 iter_dir   $2 snapshot_sha (may be empty)   $3 repo_root
goal_gate_build_diff_artifacts() {
  local iter_dir="$1" snapshot_sha="$2" repo_root="$3"
  local full_diff
  full_diff="$(mktemp)" || return 0
  # One exclusion pathspec for BOTH layers (tracked diff + untracked
  # enumeration): the scanner must never read the harness's own output.
  local _ex _uf _count=0
  local _scan_pathspec=(".")
  for _ex in $CHAIN_SCAN_BOOKKEEPING_EXCLUDES; do
    _scan_pathspec+=(":(exclude)$_ex")
  done
  {
    if [[ -n "$snapshot_sha" ]]; then
      git -C "$repo_root" diff "$snapshot_sha" -- "${_scan_pathspec[@]}" 2>/dev/null || true
    else
      git -C "$repo_root" diff HEAD~1 -- "${_scan_pathspec[@]}" 2>/dev/null || \
        git -C "$repo_root" diff HEAD -- "${_scan_pathspec[@]}" 2>/dev/null || true
    fi
    # Untracked files are the iteration's new files (work is committed only at
    # the push step, AFTER evaluation) — the scanner must see them too. With
    # bookkeeping excluded, the cap counts PRODUCT files only (bookkeeping used
    # to be able to exhaust it and silently hide product files from the scan).
    # Relative path on purpose: --no-index with an absolute path renders
    # headers as a/home/... which the old sed mangled to 'bpath' — relative
    # paths give proper a/... b/... headers for scan_diff/diff_bound to parse.
    while IFS= read -r _uf; do
      [[ -z "$_uf" ]] && continue
      _count=$((_count + 1))
      [[ $_count -gt 200 ]] && break
      git -C "$repo_root" diff --no-index -- /dev/null "$_uf" 2>/dev/null || true
    done < <(git -C "$repo_root" ls-files --others --exclude-standard -- "${_scan_pathspec[@]}" 2>/dev/null)
  } > "$full_diff" 2>/dev/null || true

  python3 "$_GOAL_GATES_DIR/scan_diff.py" scan --diff-file "$full_diff" \
    > "$iter_dir/scan-report.md" 2>/dev/null || true
  # Provenance footer (must never contain a literal result-line marker): which
  # inputs produced this report, so CLEAN/CRITICAL disagreements are debuggable.
  printf '\n_Scan scope: changes since %s; %s untracked file(s) scanned (cap 200); bookkeeping excluded: %s_\n' \
    "${snapshot_sha:-HEAD~1}" "$(( _count > 200 ? 200 : _count ))" "$CHAIN_SCAN_BOOKKEEPING_EXCLUDES" \
    >> "$iter_dir/scan-report.md" 2>/dev/null || true
  python3 "$_GOAL_GATES_DIR/diff_bound.py" < "$full_diff" \
    > "$iter_dir/iter-diff.md" 2>/dev/null || true
  rm -f "$full_diff" 2>/dev/null || true
  return 0
}

# SPEED-14: deterministic "did this iteration change the product at all?" probe.
# Same pathspec discipline as goal_gate_build_diff_artifacts above (bookkeeping
# namespaces excluded, both layers: tracked diff + untracked enumeration).
# Returns 0 ONLY when the tracked diff vs the snapshot is empty AND no untracked
# product files exist. Missing snapshot or any git error → 1 (fail-safe: treat
# as "changed" so nothing gets skipped on bad data).
# $1 snapshot_sha   $2 repo_root
goal_product_diff_empty() {
  local snapshot_sha="$1" repo_root="$2"
  [[ -n "$snapshot_sha" && -n "$repo_root" ]] || return 1
  local _ex
  local _scan_pathspec=(".")
  for _ex in $CHAIN_SCAN_BOOKKEEPING_EXCLUDES; do
    _scan_pathspec+=(":(exclude)$_ex")
  done
  local _tracked _untracked
  _tracked=$(git -C "$repo_root" diff --name-only "$snapshot_sha" -- "${_scan_pathspec[@]}" 2>/dev/null) || return 1
  _untracked=$(git -C "$repo_root" ls-files --others --exclude-standard -- "${_scan_pathspec[@]}" 2>/dev/null) || return 1
  [[ -z "$_tracked" && -z "$_untracked" ]]
}

# Deterministic achievement gate. Writes $1/gate-report.md. Returns 0 iff every
# check passes. Args:
#   $1 iter_dir  $2 journey_history  $3 coherence_md  $4 coherence_expected(true|false)
#   $5 results_md  $6 pre_history
goal_gate_achievement() {
  local iter_dir="$1" history="$2" coherence_md="$3" coherence_expected="$4"
  local results_md="$5" pre_history="$6"
  local report="$iter_dir/gate-report.md"
  local failures=0
  local lines=("# GOAL_ACHIEVED deterministic gate report" "")

  local _out _rc

  # 1. Every journey passing in journey-history.json (fail-closed on unreadable).
  _rc=0; _out="$(python3 "$_GOAL_GATES_DIR/goal_gate.py" journeys "$history" 2>&1)" || _rc=$?
  if [[ $_rc -eq 0 ]]; then
    lines+=("- PASS journeys: all passing/already_passing — $_out")
  else
    lines+=("- FAIL journeys (rc=$_rc): $_out")
    failures=$((failures + 1))
  fi

  # 2. Coherence: only when a coherence run was expected this iteration.
  if [[ "$coherence_expected" == "true" ]]; then
    _rc=0; python3 "$_GOAL_GATES_DIR/goal_gate.py" coherence "$coherence_md" --for-achievement >/dev/null 2>&1 || _rc=$?
    if [[ $_rc -eq 0 ]]; then
      lines+=("- PASS coherence: verdict is PASS/WARN and not a crash stub")
    else
      lines+=("- FAIL coherence (rc=$_rc): COHERENCE-FAIL, crash-stub, or unreadable ($coherence_md)")
      failures=$((failures + 1))
    fi
  else
    lines+=("- SKIP coherence: no coherence audit expected this iteration (baseline / no blueprint)")
  fi

  # 3. Browser results: no FAIL cells in this iteration's results table.
  if [[ -f "$results_md" ]]; then
    _rc=0; python3 "$_GOAL_GATES_DIR/goal_gate.py" results "$results_md" >/dev/null 2>&1 || _rc=$?
    if [[ $_rc -eq 0 ]]; then
      lines+=("- PASS results: no FAIL rows in $results_md")
    else
      lines+=("- FAIL results (rc=$_rc): FAIL row(s) present in $results_md")
      failures=$((failures + 1))
    fi
  else
    lines+=("- WARN results: $results_md missing — relying on journey-history + confirm pass")
  fi

  # 4. Diff scan: no CRITICAL findings (secrets / paid-SaaS deps / etc.).
  #    A report with no result line means the scanner crashed (the build
  #    redirect fails open to an empty file) — treat it like a missing report,
  #    never as a pass.
  if [[ -f "$iter_dir/scan-report.md" ]] \
     && grep -q '^\*\*Result:\*\*' "$iter_dir/scan-report.md" 2>/dev/null; then
    if grep -q '^\*\*Result:\*\* CRITICAL' "$iter_dir/scan-report.md" 2>/dev/null; then
      lines+=("- FAIL scan: critical findings in $iter_dir/scan-report.md")
      failures=$((failures + 1))
    else
      lines+=("- PASS scan: no critical findings ($iter_dir/scan-report.md)")
    fi
  else
    lines+=("- WARN scan: scan-report.md missing or without a result line (diff artifacts were not built)")
  fi

  # 5. No passing→failing regressions vs the pre-iteration snapshot.
  _rc=0; _out="$(python3 "$_GOAL_GATES_DIR/goal_gate.py" regressions "$pre_history" "$history" 2>&1)" || _rc=$?
  if [[ $_rc -eq 0 ]]; then
    lines+=("- PASS regressions: no prior-passing journey lost")
  else
    lines+=("- FAIL regressions (rc=$_rc): ${_out//$'\n'/; }")
    failures=$((failures + 1))
  fi

  # 6. Goal-edit drift (NEED-9): journeys flagged in journeys-changed.md
  #    (goal.md text edited after they last passed) must have been re-verified
  #    against the NEW text — spec_hash re-recorded by the evaluator — or
  #    demoted out of passing. A stale pass must never certify.
  if [[ -f "$iter_dir/journeys-changed.md" ]]; then
    _rc=0; _out="$(python3 "$_GOAL_GATES_DIR/goal_gate.py" drift "$iter_dir/journeys-changed.md" "$history" 2>&1)" || _rc=$?
    if [[ $_rc -eq 0 ]]; then
      lines+=("- PASS drift: every goal-edited journey re-verified or demoted")
    else
      lines+=("- FAIL drift (rc=$_rc): ${_out//$'\n'/; }")
      failures=$((failures + 1))
    fi
  else
    lines+=("- PASS drift: no goal-edit drift note this iteration")
  fi

  lines+=("" "**Gate result:** $([[ $failures -eq 0 ]] && echo PASS || echo "FAIL ($failures check(s) failed)")")
  printf '%s\n' "${lines[@]}" > "$report" 2>/dev/null || true
  [[ $failures -eq 0 ]]
}

# Two-key confirm: one fresh-context adversarial evaluator dispatch on the
# strong tier. Requires `**Verdict:** CONFIRM_ACHIEVED` in eval-confirm.md.
# Args: $1 iter_dir  $2 goal_slice(or goal file)  $3 journey_history  $4 eval_md
goal_gate_confirm_achieved() {
  local iter_dir="$1" goal_ref="$2" history="$3" eval_md="$4"
  local confirm_out="$iter_dir/eval-confirm.md"
  rm -f "$confirm_out" 2>/dev/null || true

  local strong_model digest
  strong_model="$(python3 "$_GOAL_GATES_DIR/agent_permissions.py" tier-model strong 2>/dev/null || true)"
  digest="$(python3 "$_GOAL_GATES_DIR/goal_gate.py" digest "$history" 2>/dev/null || echo '(digest unavailable)')"

  local _rc=0
  # REP-5: attribute this dispatch in the per-agent telemetry economics — its
  # ~5 min per achieving iteration was previously an unattributed wall-clock
  # gap. Guarded (declare -F): --self-test and standalone sourcing run without
  # telemetry.sh. The telemetry label is goal-evaluator-confirm; the dispatch
  # env below keeps CHAIN_CURRENT_AGENT=goal-evaluator because pump permission
  # resolution knows the evaluator's tool grants, not the telemetry label.
  local _confirm_start=""
  if declare -F record_agent_invocation_start >/dev/null 2>&1; then
    record_agent_invocation_start "goal-evaluator-confirm"   # bare call: $(...) would lose CHAIN_AGENT_START_EPOCH to a subshell
    _confirm_start="${CHAIN_AGENT_START_EPOCH:-}"
  fi
  # The dispatch's own stdout must NOT leak into the caller's command
  # substitution — route it to a log file.
  CHAIN_MODEL_OVERRIDE="${strong_model}" \
  CHAIN_EFFORT_OVERRIDE="max" \
  CHAIN_CURRENT_AGENT="goal-evaluator" \
  claude_with_quota_retry -p "You are a fresh-context CONFIRMATION evaluator — the second key on a two-key GOAL_ACHIEVED decision. A first evaluator declared the goal achieved and the deterministic gates passed. Your ONLY job is to try to REFUTE that conclusion. Default to REJECT when uncertain.

Read, in this order:
1. $iter_dir/gate-report.md — the deterministic gate results
2. Journey digest (inline below)
3. $goal_ref — the goal (vision, anti-goals, journeys; stable ones may be digested)
4. $eval_md — the first evaluator's verdict you are auditing
5. Spot-check evidence for any journey you doubt: its browser-results row and screenshot (paths are cited in $eval_md)

Journey digest:
\`\`\`
$digest
\`\`\`

Checklist — hunt for a reason it is NOT done:
- A journey whose 'passing' claim lacks a citable results row or screenshot
- An acceptance criterion in the goal that no journey/evidence actually covers
- A quietly weakened or renegotiated acceptance criterion
- An anti-goal category nobody explicitly cleared
- Any contradiction between the gate report, the digest, and the eval

Do NOT re-run tests or browsers. Do NOT read raw diffs or every screenshot — this is a bounded audit of the CLAIMS against their cited evidence.

Write EXACTLY one file: $confirm_out
First line MUST be either:
**Verdict:** CONFIRM_ACHIEVED
or
**Verdict:** REJECT
followed by a '## Reasoning' section (max ~15 lines; cite what you checked).
STOP after writing the file." \
    >> "$iter_dir/confirm-dispatch.log" 2>&1 || _rc=$?

  if declare -F record_agent_invocation_end >/dev/null 2>&1; then
    record_agent_invocation_end "goal-evaluator-confirm" "$_confirm_start" "$_rc"
  fi

  if [[ $_rc -ne 0 ]]; then
    echo "[goal-gates] confirm dispatch failed (rc=$_rc) — fail-closed (demote)." >&2
    return 1
  fi
  if [[ ! -f "$confirm_out" ]]; then
    echo "[goal-gates] confirm evaluator wrote no output — fail-closed (demote)." >&2
    return 1
  fi
  if grep -m1 -qE '^\*\*Verdict:\*\* CONFIRM_ACHIEVED[[:space:]]*$' "$confirm_out"; then
    return 0
  fi
  echo "[goal-gates] confirm evaluator did not CONFIRM (see $confirm_out) — demoting." >&2
  return 1
}

# The seam. Echoes the FINAL verdict on stdout. Everything else → stderr/files.
# Args:
#   $1 verdict        (as parsed from eval.md; may be empty)
#   $2 iter_dir       $3 eval_md   $4 journey_history
#   $5 coherence_md   $6 coherence_expected(true|false)
#   $7 results_md     $8 session_dir   $9 goal_ref (slice or full goal path)
goal_gate_filter_verdict() {
  local verdict="$1" iter_dir="$2" eval_md="$3" history="$4"
  local coherence_md="$5" coherence_expected="$6" results_md="$7"
  local session_dir="$8" goal_ref="$9"
  local counter_file="$session_dir/.malformed-verdict-count"

  if ! goal_gates_enabled; then
    echo "[goal-gates] CHAIN_GOAL_GATES=false — gates disabled; passing verdict through unchanged." >&2
    printf '%s\n' "$verdict"
    return 0
  fi

  # ① Shape check (runtime schema validation — previously never invoked).
  local shape_rc=0
  python3 "$_GOAL_GATES_DIR/artifact_schemas.py" validate "$eval_md" >&2 2>/dev/null || shape_rc=$?
  case "$verdict" in
    GOAL_ACHIEVED|CONTINUE|ESCALATE|REGRESSION|STALLED) : ;;
    *) shape_rc=1 ;;
  esac
  if [[ $shape_rc -ne 0 ]]; then
    local n
    n="$(cat "$counter_file" 2>/dev/null || echo 0)"
    n=$((n + 1))
    echo "$n" > "$counter_file" 2>/dev/null || true
    if [[ $n -ge 2 ]]; then
      echo "[goal-gates] malformed/unknown evaluator verdict ${n}x consecutively ('$verdict') — ABORT_MALFORMED (was: silent CONTINUE forever)." >&2
      printf 'ABORT_MALFORMED\n'
      return 0
    fi
    echo "[goal-gates] malformed/unknown evaluator verdict ('$verdict') — treating as CONTINUE (1st strike; 2 consecutive aborts the session)." >&2
    printf 'CONTINUE\n'
    return 0
  fi
  rm -f "$counter_file" 2>/dev/null || true

  if [[ "$verdict" == "GOAL_ACHIEVED" ]]; then
    # ② Deterministic gates.
    if ! goal_gate_achievement "$iter_dir" "$history" "$coherence_md" "$coherence_expected" "$results_md" "$iter_dir/journey-history.pre.json"; then
      echo "[goal-gates] GOAL_ACHIEVED demoted to CONTINUE — deterministic gate failed. Report: $iter_dir/gate-report.md" >&2
      printf 'CONTINUE\n'
      return 0
    fi
    echo "[goal-gates] deterministic gates PASS ($iter_dir/gate-report.md)." >&2
    # ③ Two-key confirm (skippable for tests/emergencies via env).
    if [[ "${CHAIN_GOAL_CONFIRM:-true}" == "true" ]]; then
      if ! goal_gate_confirm_achieved "$iter_dir" "$goal_ref" "$history" "$eval_md"; then
        printf 'CONTINUE\n'
        return 0
      fi
      echo "[goal-gates] two-key confirm: CONFIRM_ACHIEVED ($iter_dir/eval-confirm.md)." >&2
    else
      echo "[goal-gates] two-key confirm SKIPPED (CHAIN_GOAL_CONFIRM=false)." >&2
    fi
    printf 'GOAL_ACHIEVED\n'
    return 0
  fi

  # ④ Non-achievement verdicts: cross-check regressions the evaluator may have
  # missed. Report-only by default (protects long-running sessions); strict
  # mode escalates the verdict itself.
  local reg_rc=0 reg_out=""
  reg_out="$(python3 "$_GOAL_GATES_DIR/goal_gate.py" regressions "$iter_dir/journey-history.pre.json" "$history" 2>/dev/null)" || reg_rc=$?
  if [[ $reg_rc -eq 3 && "$verdict" != "REGRESSION" && "$verdict" != "ESCALATE" ]]; then
    echo "[goal-gates] NOTE: deterministic regression check found prior-passing journeys now failing (${reg_out//$'\n'/; }) but the evaluator said '$verdict'." >&2
    if [[ "${CHAIN_STRICT_REGRESSION_HALT:-false}" == "true" ]]; then
      echo "[goal-gates] CHAIN_STRICT_REGRESSION_HALT=true — escalating verdict to REGRESSION." >&2
      printf 'REGRESSION\n'
      return 0
    fi
  fi
  printf '%s\n' "$verdict"
  return 0
}

# ── Self-test (run directly: `bash goal-gates.sh --self-test`) ────────────────
_goal_gates_self_test() {
  local fails=0 d
  d="$(mktemp -d)"
  mkdir -p "$d/iter-3" "$d/session"

  # Fixtures
  local HIST_PASS="$d/hist-pass.json" HIST_FAIL="$d/hist-fail.json" PRE="$d/iter-3/journey-history.pre.json"
  printf '{"journeys":{"J-01":{"status":"passing","name":"A"},"J-02":{"status":"already_passing","name":"B"}}}' > "$HIST_PASS"
  printf '{"journeys":{"J-01":{"status":"passing","name":"A"},"J-02":{"status":"failing","name":"B"}}}' > "$HIST_FAIL"
  cp "$HIST_PASS" "$PRE"
  local COH="$d/iter-3/coherence.md" RES="$d/iter-3/results.md" EVALF="$d/iter-3/eval.md"
  printf '**Verdict:** COHERENCE-PASS\nok\n' > "$COH"
  printf '| T1 | n | ui | P1 | e | a | PASS | x.png |\n' > "$RES"
  printf '**Verdict:** GOAL_ACHIEVED\n**Depth Recommendation For Next Iteration:** lean\n\n## Summary\n\nok\n' > "$EVALF"
  printf '# scan\n\n**Result:** CLEAN — nothing.\n' > "$d/iter-3/scan-report.md"

  # Stub the dispatch seam: writes CONFIRM or REJECT per $STUB_CONFIRM.
  claude_with_quota_retry() {
    local out
    out="$(printf '%s\n' "$@" | grep -oE '[^ ]*/eval-confirm\.md' | head -1)"
    [[ -z "$out" ]] && out="$d/iter-3/eval-confirm.md"
    if [[ "${STUB_CONFIRM:-yes}" == "yes" ]]; then
      printf '**Verdict:** CONFIRM_ACHIEVED\n\n## Reasoning\n\nstub\n' > "$out"
    else
      printf '**Verdict:** REJECT\n\n## Reasoning\n\nstub doubt\n' > "$out"
    fi
    return 0
  }

  # REP-5: the confirm dispatch must fire the guarded attribution hooks. The
  # stubs log to a file because the seam runs inside $(...) subshells.
  local REP5_LOG="$d/rep5.log"
  record_agent_invocation_start() { echo "start $1" >> "$REP5_LOG"; CHAIN_AGENT_START_EPOCH=12345; }
  record_agent_invocation_end()   { echo "end $1 t0=$2 rc=$3" >> "$REP5_LOG"; }

  local v

  # 1. All green + confirm yes → GOAL_ACHIEVED survives.
  STUB_CONFIRM=yes
  v="$(goal_gate_filter_verdict GOAL_ACHIEVED "$d/iter-3" "$EVALF" "$HIST_PASS" "$COH" true "$RES" "$d/session" "$d/goal.md" 2>/dev/null)"
  [[ "$v" == "GOAL_ACHIEVED" ]] && echo "  PASS goal-gates: clean GOAL_ACHIEVED survives" || { echo "  FAIL goal-gates: clean survive (got '$v')"; fails=1; }
  if grep -q '^start goal-evaluator-confirm$' "$REP5_LOG" 2>/dev/null \
     && grep -q '^end goal-evaluator-confirm t0=12345 rc=0$' "$REP5_LOG" 2>/dev/null; then
    echo "  PASS goal-gates: confirm dispatch attributed (REP-5 start+end events)"
  else
    echo "  FAIL goal-gates: confirm dispatch attribution (REP-5) — got: $(cat "$REP5_LOG" 2>/dev/null | tr '\n' ';')"; fails=1
  fi

  # 2. A failing journey demotes despite the evaluator's verdict.
  v="$(goal_gate_filter_verdict GOAL_ACHIEVED "$d/iter-3" "$EVALF" "$HIST_FAIL" "$COH" true "$RES" "$d/session" "$d/goal.md" 2>/dev/null)"
  [[ "$v" == "CONTINUE" ]] && echo "  PASS goal-gates: failing journey demotes GOAL_ACHIEVED" || { echo "  FAIL goal-gates: failing journey (got '$v')"; fails=1; }
  grep -q "FAIL journeys" "$d/iter-3/gate-report.md" || { echo "  FAIL goal-gates: gate-report missing journeys failure"; fails=1; }

  # 3. Coherence crash-stub blocks certification.
  printf '**Verdict:** COHERENCE-PASS\n\n(Coherence auditor produced no output; treated as a non-blocking pass.)\n' > "$COH"
  v="$(goal_gate_filter_verdict GOAL_ACHIEVED "$d/iter-3" "$EVALF" "$HIST_PASS" "$COH" true "$RES" "$d/session" "$d/goal.md" 2>/dev/null)"
  [[ "$v" == "CONTINUE" ]] && echo "  PASS goal-gates: coherence crash-stub blocks certification" || { echo "  FAIL goal-gates: stub block (got '$v')"; fails=1; }
  printf '**Verdict:** COHERENCE-PASS\nok\n' > "$COH"

  # 4. Confirm REJECT demotes even when deterministic gates pass.
  STUB_CONFIRM=no
  v="$(goal_gate_filter_verdict GOAL_ACHIEVED "$d/iter-3" "$EVALF" "$HIST_PASS" "$COH" true "$RES" "$d/session" "$d/goal.md" 2>/dev/null)"
  [[ "$v" == "CONTINUE" ]] && echo "  PASS goal-gates: two-key REJECT demotes" || { echo "  FAIL goal-gates: two-key reject (got '$v')"; fails=1; }
  STUB_CONFIRM=yes

  # 5. Malformed verdict: 1st strike CONTINUE, 2nd consecutive ABORT_MALFORMED.
  printf 'no verdict here\n' > "$EVALF"
  v="$(goal_gate_filter_verdict "" "$d/iter-3" "$EVALF" "$HIST_PASS" "$COH" true "$RES" "$d/session" "$d/goal.md" 2>/dev/null)"
  [[ "$v" == "CONTINUE" ]] && echo "  PASS goal-gates: malformed verdict 1st strike → CONTINUE" || { echo "  FAIL goal-gates: malformed 1st (got '$v')"; fails=1; }
  v="$(goal_gate_filter_verdict "" "$d/iter-3" "$EVALF" "$HIST_PASS" "$COH" true "$RES" "$d/session" "$d/goal.md" 2>/dev/null)"
  [[ "$v" == "ABORT_MALFORMED" ]] && echo "  PASS goal-gates: malformed x2 → ABORT_MALFORMED" || { echo "  FAIL goal-gates: malformed 2nd (got '$v')"; fails=1; }
  printf '**Verdict:** GOAL_ACHIEVED\n**Depth Recommendation For Next Iteration:** lean\n\n## Summary\n\nok\n' > "$EVALF"

  # 6. Valid verdict resets the malformed counter.
  v="$(goal_gate_filter_verdict CONTINUE "$d/iter-3" "$EVALF" "$HIST_PASS" "$COH" true "$RES" "$d/session" "$d/goal.md" 2>/dev/null)"
  [[ "$v" == "CONTINUE" && ! -f "$d/session/.malformed-verdict-count" ]] \
    && echo "  PASS goal-gates: valid verdict resets malformed counter" || { echo "  FAIL goal-gates: counter reset"; fails=1; }

  # 7. Undeclared regression: report-only by default; strict mode escalates.
  cp "$HIST_PASS" "$PRE"
  v="$(goal_gate_filter_verdict CONTINUE "$d/iter-3" "$EVALF" "$HIST_FAIL" "$COH" true "$RES" "$d/session" "$d/goal.md" 2>/dev/null)"
  [[ "$v" == "CONTINUE" ]] && echo "  PASS goal-gates: undeclared regression is report-only by default" || { echo "  FAIL goal-gates: default regression (got '$v')"; fails=1; }
  v="$(CHAIN_STRICT_REGRESSION_HALT=true goal_gate_filter_verdict CONTINUE "$d/iter-3" "$EVALF" "$HIST_FAIL" "$COH" true "$RES" "$d/session" "$d/goal.md" 2>/dev/null)"
  [[ "$v" == "REGRESSION" ]] && echo "  PASS goal-gates: strict mode escalates undeclared regression" || { echo "  FAIL goal-gates: strict regression (got '$v')"; fails=1; }

  # 8. Gates disabled → verdict passes through unchanged.
  v="$(CHAIN_GOAL_GATES=false goal_gate_filter_verdict GOAL_ACHIEVED "$d/iter-3" "$EVALF" "$HIST_FAIL" "$COH" true "$RES" "$d/session" "$d/goal.md" 2>/dev/null)"
  [[ "$v" == "GOAL_ACHIEVED" ]] && echo "  PASS goal-gates: CHAIN_GOAL_GATES=false passes through" || { echo "  FAIL goal-gates: disable hatch (got '$v')"; fails=1; }

  # 9. scan_diff critical finding blocks achievement.
  printf '# scan\n\n**Result:** CRITICAL — 1 critical, 0 warn\n\n- **CRITICAL** `aws-access-key` in `config.py`: AKIA...\n' > "$d/iter-3/scan-report.md"
  v="$(goal_gate_filter_verdict GOAL_ACHIEVED "$d/iter-3" "$EVALF" "$HIST_PASS" "$COH" true "$RES" "$d/session" "$d/goal.md" 2>/dev/null)"
  [[ "$v" == "CONTINUE" ]] && echo "  PASS goal-gates: critical scan finding blocks certification" || { echo "  FAIL goal-gates: scan block (got '$v')"; fails=1; }

  # 9b. Empty scan-report (scanner crash fails open to an empty file) must
  #     read as the WARN/missing branch, never as a PASS.
  : > "$d/iter-3/scan-report.md"
  v="$(goal_gate_filter_verdict GOAL_ACHIEVED "$d/iter-3" "$EVALF" "$HIST_PASS" "$COH" true "$RES" "$d/session" "$d/goal.md" 2>/dev/null)"
  if [[ "$v" == "GOAL_ACHIEVED" ]] && grep -q -- '- WARN scan:' "$d/iter-3/gate-report.md" \
     && ! grep -q -- '- PASS scan:' "$d/iter-3/gate-report.md"; then
    echo "  PASS goal-gates: empty scan-report reads as WARN, not PASS"
  else
    echo "  FAIL goal-gates: empty scan-report handling (got '$v')"; fails=1
  fi
  printf '# scan\n\n**Result:** CLEAN — nothing.\n' > "$d/iter-3/scan-report.md"

  # 10. Goal-edit drift (NEED-9): the note is built by the REAL writer
  #     (hash-journeys) from a stale-hash history. A flagged journey whose
  #     spec_hash was never re-recorded blocks certification; re-recording
  #     the current hash (= re-verified against the new text) certifies;
  #     no note → a stale hash alone never blocks (pre-NEED-9 tolerance).
  printf '# scan\n\n**Result:** CLEAN — nothing.\n' > "$d/iter-3/scan-report.md"
  printf '# g\n\n- **J-01: A**\n  - Acceptance: freshly edited text\n- **J-02: B**\n  - Acceptance: unchanged\n' > "$d/goal-drift.md"
  local ZERO64="0000000000000000000000000000000000000000000000000000000000000000"
  local HIST_STALE="$d/hist-stale.json"
  printf '{"journeys":{"J-01":{"status":"passing","name":"A","spec_hash":"%s"},"J-02":{"status":"already_passing","name":"B"}}}' "$ZERO64" > "$HIST_STALE"
  python3 "$_GOAL_GATES_DIR/goal_gate.py" hash-journeys "$d/goal-drift.md" \
    --history "$HIST_STALE" --out-changed "$d/iter-3/journeys-changed.md" >/dev/null 2>&1
  [[ -f "$d/iter-3/journeys-changed.md" ]] || { echo "  FAIL goal-gates: drift fixture note not written"; fails=1; }
  cp "$HIST_STALE" "$PRE"
  v="$(goal_gate_filter_verdict GOAL_ACHIEVED "$d/iter-3" "$EVALF" "$HIST_STALE" "$COH" true "$RES" "$d/session" "$d/goal.md" 2>/dev/null)"
  [[ "$v" == "CONTINUE" ]] && echo "  PASS goal-gates: changed-hash journey demotes GOAL_ACHIEVED" || { echo "  FAIL goal-gates: drift demote (got '$v')"; fails=1; }
  grep -q "FAIL drift" "$d/iter-3/gate-report.md" || { echo "  FAIL goal-gates: gate-report missing drift failure"; fails=1; }
  local _h01 HIST_REVERIFIED="$d/hist-reverified.json"
  _h01="$(python3 "$_GOAL_GATES_DIR/goal_gate.py" hash-journeys "$d/goal-drift.md" 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["J-01"])')"
  printf '{"journeys":{"J-01":{"status":"passing","name":"A","spec_hash":"%s"},"J-02":{"status":"already_passing","name":"B"}}}' "$_h01" > "$HIST_REVERIFIED"
  v="$(goal_gate_filter_verdict GOAL_ACHIEVED "$d/iter-3" "$EVALF" "$HIST_REVERIFIED" "$COH" true "$RES" "$d/session" "$d/goal.md" 2>/dev/null)"
  [[ "$v" == "GOAL_ACHIEVED" ]] && echo "  PASS goal-gates: re-verified journey (spec_hash re-recorded) certifies" || { echo "  FAIL goal-gates: drift re-verified (got '$v')"; fails=1; }
  rm -f "$d/iter-3/journeys-changed.md"
  v="$(goal_gate_filter_verdict GOAL_ACHIEVED "$d/iter-3" "$EVALF" "$HIST_STALE" "$COH" true "$RES" "$d/session" "$d/goal.md" 2>/dev/null)"
  [[ "$v" == "GOAL_ACHIEVED" ]] && echo "  PASS goal-gates: no drift note → stale hash alone never blocks" || { echo "  FAIL goal-gates: drift absent-note (got '$v')"; fails=1; }

  # 11. build_diff_artifacts scans the PRODUCT diff only (recursion guard):
  #     bookkeeping quoting a credential — the harness's own prior scan
  #     output, summaries, handoffs — must not trip the scanner, untracked OR
  #     tracked, while the same credential in product source must. The output
  #     iter dir lives OUTSIDE the fixture repo so the just-written report is
  #     not itself untracked in the scanned tree. Fake key is string-split so
  #     THIS file never contains a pattern-matching literal (see case 12).
  CHAIN_SCAN_BOOKKEEPING_EXCLUDES="runs reports docs/handoffs docs/phases"
  local _fk="AKIA""IOSFODNN7EXAMPLE"
  local G="$d/case11-repo" ITER11="$d/iter-11" _git11=(git -C "$d/case11-repo" -c user.email=t@t -c user.name=t -c commit.gpgsign=false)
  mkdir -p "$ITER11"
  git -c init.defaultBranch=main init -q "$G"
  "${_git11[@]}" commit -q --allow-empty -m base
  local SNAP11; SNAP11="$("${_git11[@]}" rev-parse HEAD)"
  mkdir -p "$G/runs/s1/iter-1" "$G/reports" "$G/docs/handoffs" "$G/apps"
  printf 'prior finding: aws-access-key %s\n' "$_fk" > "$G/runs/s1/iter-1/scan-report.md"
  printf 'iteration summary quoting %s\n' "$_fk" > "$G/reports/summary.md"
  printf 'dev handoff quoting %s\n' "$_fk" > "$G/docs/handoffs/x-dev.md"
  printf 'def ok():\n    return 1\n' > "$G/apps/app.py"
  goal_gate_build_diff_artifacts "$ITER11" "$SNAP11" "$G"
  grep -q '^\*\*Result:\*\* CLEAN' "$ITER11/scan-report.md" \
    && echo "  PASS goal-gates: untracked bookkeeping quoting a credential scans CLEAN" \
    || { echo "  FAIL goal-gates: bookkeeping exclusion, untracked ($ITER11/scan-report.md)"; fails=1; }
  printf 'KEY = "%s"\n' "$_fk" > "$G/apps/config.py"
  goal_gate_build_diff_artifacts "$ITER11" "$SNAP11" "$G"
  if grep -q '^\*\*Result:\*\* CRITICAL' "$ITER11/scan-report.md" \
     && grep -q 'apps/config.py' "$ITER11/scan-report.md"; then
    echo "  PASS goal-gates: credential in product source still CRITICAL, path cited"
  else
    echo "  FAIL goal-gates: product-source detection ($ITER11/scan-report.md)"; fails=1
  fi
  rm -f "$G/apps/config.py"
  "${_git11[@]}" add reports/summary.md
  "${_git11[@]}" commit -q -m bookkeeping
  printf 'edited summary still quoting %s\n' "$_fk" > "$G/reports/summary.md"
  goal_gate_build_diff_artifacts "$ITER11" "$SNAP11" "$G"
  grep -q '^\*\*Result:\*\* CLEAN' "$ITER11/scan-report.md" \
    && echo "  PASS goal-gates: tracked bookkeeping edit quoting a credential scans CLEAN" \
    || { echo "  FAIL goal-gates: bookkeeping exclusion, tracked ($ITER11/scan-report.md)"; fails=1; }

  # 12. Structural guard: this library's own source must never contain a
  #     secret-shaped literal (exit 3 = critical finding in scan_diff.py).
  local _rc12=0
  git diff --no-index -- /dev/null "$_GOAL_GATES_DIR/goal-gates.sh" 2>/dev/null | \
    python3 "$_GOAL_GATES_DIR/scan_diff.py" scan >/dev/null 2>&1 || _rc12=$?
  [[ "$_rc12" -ne 3 ]] \
    && echo "  PASS goal-gates: goal-gates.sh source is free of secret-shaped literals" \
    || { echo "  FAIL goal-gates: goal-gates.sh contains a scanner-tripping literal"; fails=1; }

  unset -f claude_with_quota_retry record_agent_invocation_start record_agent_invocation_end
  rm -rf "$d"
  if [[ $fails -eq 0 ]]; then echo "goal-gates self-test: OK"; else echo "goal-gates self-test: FAILED"; fi
  return $fails
}

if [[ "${BASH_SOURCE[0]}" == "${0}" && "${1:-}" == "--self-test" ]]; then
  _goal_gates_self_test
  exit $?
fi
