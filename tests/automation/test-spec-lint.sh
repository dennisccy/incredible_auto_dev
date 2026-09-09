#!/usr/bin/env bash
# test-spec-lint.sh — HARD-2: the deterministic iteration-spec parser/lint governor.
#
# Invariant under test: an iteration spec reaches developer/browser dispatch only
# when the deterministic structural preflight could PARSE and VALIDATE it. With
# CHAIN_SPEC_LINT=block, lint errors, a linter crash and an unreadable spec all
# fail closed BEFORE any dispatch. The governed agent's prose is never evidence
# that its own spec is safe (anti-pattern 25).
#
#   L. lib/iter_spec.py metadata + lint via the CLI (unit)
#   E. the REAL run-goal.sh engine in a sandbox with a stub `claude` (end-to-end)
#   W. wiring greps and ordering
#   R. HARD-1 regressions still hold
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0; FAIL=0
assert() {  # assert <name> pass|fail
  if [[ "$2" == "pass" ]]; then PASS=$((PASS+1)); echo "  PASS  $1"
  else FAIL=$((FAIL+1)); echo "  FAIL  $1"; fi
}
WORK="$(mktemp -d)"
cleanup() {
  [[ -n "${DUMMY_PIDS:-}" ]] && kill ${DUMMY_PIDS[@]:-} 2>/dev/null
  pkill -f "$WORK" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

PROBE="$ENGINE_ROOT/scripts/automation/lib/iter_spec.py"
RG="$ENGINE_ROOT/scripts/automation/run-goal.sh"
SPECS="$WORK/specs"; mkdir -p "$SPECS"

# ── spec fixtures ────────────────────────────────────────────────────────────
# md <file> [depth] [workkind] [extra-metadata] [mode] [targets]
md() {
  local f="$1" depth="${2:-lean}" wk="${3:-}" extra="${4:-}" mode="${5:-next}" tj="${6:-J-01, J-02}"
  {
    echo "## Goal Mode Metadata"; echo
    echo "- **Session ID:** hardtest"
    echo "- **Iteration:** 3"
    echo "- **Mode:** $mode"
    echo "- **Depth:** $depth"
    echo "- **Target journeys:** $tj"
    echo "- **Required-still-passing journeys:** J-03"
    [[ -n "$wk" ]] && echo "- **Work kind:** $wk"
    [[ -n "$extra" ]] && printf '%s\n' "$extra"
  } > "$f"
}
add_work()   { { echo; echo "## IN SCOPE"; echo "### Backend"; echo "- [ ] add the endpoint";
                 echo "### Frontend"; echo "- none"; } >> "$1"; }
add_nowork() { { echo; echo "## IN SCOPE"; echo "### Backend"; echo "- none";
                 echo "### Frontend"; echo "- N/A"; } >> "$1"; }
add_tail()   { { echo; echo "## OUT OF SCOPE"; echo "- x"; echo;
                 echo "## DEFINITION OF DONE"; echo "- [ ] done"; echo;
                 echo "## TESTING REQUIREMENTS"; echo "- TC-1: given x, when y, then z"; } >> "$1"; }

LINT_OUT=""; LINT_RC=0
lint() { LINT_OUT="$(python3 "$PROBE" lint "$@" 2>&1)"; LINT_RC=$?; }
has_rule() { printf '%s' "$LINT_OUT" | grep -qE "^\[spec-lint\] (ERROR|WARN) $1 "; }

echo "== L. linter (CLI)"

# L1 — a valid lean spec with real work is clean and dispatchable.
md "$SPECS/lean.md" lean implementation; add_work "$SPECS/lean.md"; add_tail "$SPECS/lean.md"
lint "$SPECS/lean.md"
[[ "$LINT_RC" == "0" ]] && ! has_rule E07 \
  && assert "L1: a valid lean spec with implementation work lints clean (rc 0) — dispatch permitted" "pass" \
  || assert "L1: valid lean spec clean (rc=$LINT_RC; $LINT_OUT)" "fail"

# L2 — a valid full spec is clean and dispatchable.
md "$SPECS/full.md" full implementation "- **Full trigger:** 2 — prior coherence FAIL"
add_work "$SPECS/full.md"; add_tail "$SPECS/full.md"
lint "$SPECS/full.md"
[[ "$LINT_RC" == "0" ]] && ! has_rule W08 \
  && assert "L2: a valid full spec with a Full trigger lints clean (rc 0) — dispatch permitted" "pass" \
  || assert "L2: valid full spec clean (rc=$LINT_RC; $LINT_OUT)" "fail"

# L3 — a genuine evidence-only spec is clean (HARD-1's legitimate path survives).
md "$SPECS/evidence.md" evidence evidence-only; add_nowork "$SPECS/evidence.md"; add_tail "$SPECS/evidence.md"
lint "$SPECS/evidence.md"
[[ "$LINT_RC" == "0" ]] \
  && assert "L3: a genuine evidence-only spec lints clean (rc 0) — dispatch permitted subject to HARD-1" "pass" \
  || assert "L3: genuine evidence spec clean (rc=$LINT_RC; $LINT_OUT)" "fail"

# L4 — the TenSteps iter-7 shape: lean + real backend work. Clean apart from W01.
md "$SPECS/iter7.md" lean; add_work "$SPECS/iter7.md"; add_tail "$SPECS/iter7.md"
lint "$SPECS/iter7.md"
[[ "$LINT_RC" == "0" ]] && has_rule W01 && ! has_rule E07 \
  && assert "L4: the iter-7 shape (lean + backend work, no Work kind) is rc 0 with W01 only" "pass" \
  || assert "L4: iter-7 shape rc 0 + W01 (rc=$LINT_RC; $LINT_OUT)" "fail"
python3 "$PROBE" lint "$SPECS/iter7.md" --json-out "$WORK/l4.json" >/dev/null 2>&1
[[ "$(python3 -c "import json;print(json.load(open('$WORK/l4.json'))['work_kind_derived'])" 2>/dev/null)" == "implementation" ]] \
  && assert "L4b: the JSON report derives work_kind=implementation from IN SCOPE" "pass" \
  || assert "L4b: work_kind_derived=implementation in the JSON report" "fail"

# L5 — the loss case: the same spec declared evidence-only.
md "$SPECS/iter7-ev.md" lean evidence-only; add_work "$SPECS/iter7-ev.md"; add_tail "$SPECS/iter7-ev.md"
lint "$SPECS/iter7-ev.md"
[[ "$LINT_RC" == "1" ]] && has_rule E07 && printf '%s' "$LINT_OUT" | grep -q '1 backend' \
  && assert "L5: Work kind evidence-only + backend work -> E07, naming the bullet count" "pass" \
  || assert "L5: E07 names the bullets (rc=$LINT_RC; $LINT_OUT)" "fail"

# L6 — evidence depth after ESCALATE.
lint "$SPECS/evidence.md" --prior-verdict ESCALATE
[[ "$LINT_RC" == "1" ]] && has_rule E10 \
  && assert "L6: Depth evidence after a prior ESCALATE -> E10" "pass" \
  || assert "L6: E10 after ESCALATE (rc=$LINT_RC; $LINT_OUT)" "fail"

# L7 — the silent-disarm case: a plain-form Target journeys line.
md "$SPECS/plain.md" lean implementation; add_work "$SPECS/plain.md"; add_tail "$SPECS/plain.md"
sed -i 's/- \*\*Target journeys:\*\* /Target journeys: /' "$SPECS/plain.md"
lint "$SPECS/plain.md"
[[ "$LINT_RC" == "1" ]] && has_rule E02 && printf '%s' "$LINT_OUT" | grep -q '\*\*Target journeys:\*\*' \
  && assert "L7: a plain-form 'Target journeys:' -> E02, quoting the canonical bold form" "pass" \
  || assert "L7: E02 quotes the canonical form (rc=$LINT_RC; $LINT_OUT)" "fail"

# L8 — targets present but naming no id.
md "$SPECS/noids.md" lean implementation "" next "TBD"; add_work "$SPECS/noids.md"; add_tail "$SPECS/noids.md"
lint "$SPECS/noids.md"
[[ "$LINT_RC" == "1" ]] && has_rule E04 \
  && assert "L8: 'Target journeys:' naming no J-<n> id -> E04" "pass" \
  || assert "L8: E04 empty target ids (rc=$LINT_RC; $LINT_OUT)" "fail"

# L9 — a baseline spec that plans work.
md "$SPECS/baseline.md" lean "" "" baseline; add_work "$SPECS/baseline.md"; add_tail "$SPECS/baseline.md"
lint "$SPECS/baseline.md"
[[ "$LINT_RC" == "1" ]] && has_rule E09 \
  && assert "L9: a baseline (iteration 0) spec with implementation work -> E09" "pass" \
  || assert "L9: E09 baseline with work (rc=$LINT_RC; $LINT_OUT)" "fail"
lint "$SPECS/lean.md" --mode-expected baseline
[[ "$LINT_RC" == "1" ]] && has_rule E09 \
  && assert "L9b: the engine's own --mode-expected baseline also triggers E09 (spec prose cannot dodge it)" "pass" \
  || assert "L9b: --mode-expected baseline triggers E09" "fail"

# L10 — missing metadata section.
{ echo "# no metadata"; echo; } > "$SPECS/nometa.md"; add_work "$SPECS/nometa.md"; add_tail "$SPECS/nometa.md"
lint "$SPECS/nometa.md"
[[ "$LINT_RC" == "1" ]] && has_rule E01 \
  && assert "L10: a spec with no '## Goal Mode Metadata' section -> E01 (malformed metadata blocks)" "pass" \
  || assert "L10: E01 missing metadata (rc=$LINT_RC; $LINT_OUT)" "fail"

# L11 — invalid enum values.
md "$SPECS/baddepth.md" deep implementation; add_work "$SPECS/baddepth.md"; add_tail "$SPECS/baddepth.md"
lint "$SPECS/baddepth.md"; r1=$LINT_RC; has_rule E03 && e3=y || e3=n
md "$SPECS/badwk.md" lean nonsense; add_work "$SPECS/badwk.md"; add_tail "$SPECS/badwk.md"
lint "$SPECS/badwk.md"; r2=$LINT_RC; has_rule E05 && e5=y || e5=n
[[ "$r1" == "1" && "$e3" == "y" && "$r2" == "1" && "$e5" == "y" ]] \
  && assert "L11: invalid Depth -> E03 and invalid Work kind -> E05" "pass" \
  || assert "L11: E03/E05 invalid enums (depth rc=$r1/$e3 wk rc=$r2/$e5)" "fail"

# L12 — a sentinel spec warns but never blocks.
md "$SPECS/sentinel.md" lean; echo "All remaining work is human-blocked." >> "$SPECS/sentinel.md"
lint "$SPECS/sentinel.md"
[[ "$LINT_RC" == "0" ]] && has_rule W07 \
  && assert "L12: a sentinel spec (no IN SCOPE) is W07 at rc 0 — never blocked" "pass" \
  || assert "L12: sentinel W07 rc 0 (rc=$LINT_RC; $LINT_OUT)" "fail"

# L13 — an unreadable spec is exit 2, distinct from a lint error.
lint "$SPECS/does-not-exist.md"
[[ "$LINT_RC" == "2" ]] \
  && assert "L13: an unreadable spec exits 2 (distinct from rc 1 lint errors) so callers can fail closed" "pass" \
  || assert "L13: unreadable spec exits 2 (rc=$LINT_RC)" "fail"

# L14 — operator-only lines are never findings.
md "$SPECS/op.md" full implementation "- **Full trigger:** 1 — x
Depth enforcement: required
Maintenance isolation: required"
add_work "$SPECS/op.md"; add_tail "$SPECS/op.md"
lint "$SPECS/op.md"
[[ "$LINT_RC" == "0" ]] && ! has_rule E02 && ! has_rule E03 \
  && assert "L14: operator-only lines (Depth enforcement / Maintenance isolation) are never a finding" "pass" \
  || assert "L14: operator-only lines inert (rc=$LINT_RC; $LINT_OUT)" "fail"

# L15 — E11 needs the engine's independent journey history, not the spec's claim.
cat > "$WORK/hist-bad.json" <<'EOF'
{"journeys": {"J-01": {"status": "passing"}, "J-02": {"status": "failing"}}}
EOF
cat > "$WORK/hist-ok.json" <<'EOF'
{"journeys": {"J-01": {"status": "passing"}, "J-02": {"status": "already_passing"}}}
EOF
lint "$SPECS/evidence.md" --journey-history "$WORK/hist-bad.json"; rb=$LINT_RC; has_rule E11 && eb=y || eb=n
lint "$SPECS/evidence.md" --journey-history "$WORK/hist-ok.json"; ro=$LINT_RC
[[ "$rb" == "1" && "$eb" == "y" && "$ro" == "0" ]] \
  && assert "L15: E11 fires only when the engine's journey-history says a target is not passing" "pass" \
  || assert "L15: E11 uses journey-history (bad rc=$rb/$eb ok rc=$ro)" "fail"

# L16 — metadata subcommand: canonical read, bold/plain recorded.
python3 "$PROBE" metadata "$SPECS/plain.md" > "$WORK/md.json" 2>/dev/null; mrc=$?
python3 - "$WORK/md.json" <<'PY' && ok=y || ok=n
import json, sys
m = json.load(open(sys.argv[1]))
assert m["depth"] == "lean", m["depth"]
assert m["target_journeys"] == ["J-01", "J-02"], m["target_journeys"]
assert m["bold"]["depth"] is True
assert m["bold"]["target_journeys"] is False   # plain form recorded as such
assert m["present"]["target_journeys"] is True
assert m["required_journeys"] == ["J-03"]
PY
[[ "$mrc" == "0" && "$ok" == "y" ]] \
  && assert "L16: 'metadata' reads depth/targets/required and records bold-vs-plain per field" "pass" \
  || assert "L16: metadata canonical read (rc=$mrc ok=$ok)" "fail"

# L17 — the self-tests carry the per-rule fixtures.
python3 "$PROBE" self-test >/dev/null 2>&1 \
  && assert "L17: iter_spec.py self-test (HARD-1 probe fixtures + HARD-2 lint fixtures) passes" "pass" \
  || assert "L17: iter_spec.py self-test passes" "fail"
python3 "$ENGINE_ROOT/scripts/automation/lib/artifact_schemas.py" self-test >/dev/null 2>&1 \
  && assert "L18: artifact_schemas.py self-test passes with the iteration-spec schema" "pass" \
  || assert "L18: artifact_schemas.py self-test passes" "fail"
python3 -c "
import sys; sys.path.insert(0,'$ENGINE_ROOT/scripts/automation/lib')
import artifact_schemas as A
assert A.match_schema('docs/phases/phase-7.md') is None
assert A.match_schema('docs/phases/goal-x-iter-3.md').artifact_type == 'iteration-spec'
" 2>/dev/null \
  && assert "L19: the iteration-spec schema matches goal specs only — phase mode is untouched" "pass" \
  || assert "L19: iteration-spec schema excludes phase-N.md" "fail"

# ── Part E: the REAL engine ──────────────────────────────────────────────────
echo "== E. real engine (sandbox, stub claude)"
SBX="$WORK/proj"; mkdir -p "$SBX"
cp -r "$ENGINE_ROOT/scripts" "$SBX/"
mkdir -p "$SBX/docs/phases" "$SBX/reports" "$SBX/src" "$SBX/.claude/agents"
touch "$SBX/.claude/agents/developer.md"
git init -q "$SBX"
echo "print('v1')" > "$SBX/src/app.py"
cat > "$SBX/docs/goal.md" <<'EOF'
# Goal

Tiny CSV exporter web app.

## Must-have user journeys

- **J-01: Open the page**
  - Steps: open /
  - Acceptance: page loads
- **J-02: Export CSV**
  - Steps: click export
  - Acceptance: csv downloads

## Anti-goals

- no paid SaaS
EOF
git -C "$SBX" add -A
git -C "$SBX" -c user.email=t@t -c user.name=t commit -qm base
TMPROOT="$WORK/tmproot"; mkdir -p "$TMPROOT"
STUB_DIR="$WORK/bin"; mkdir -p "$STUB_DIR"

# Stub claude: the goal-decomposer writes a spec of the shape named by
# STUB_SPEC_KIND (a second dispatch writes STUB_SPEC_KIND_2 when set, which is
# how the one automatic re-plan is observed). Every other agent exits 70, so the
# engine pauses immediately after the first real dispatch — if the lint gate
# let a malformed spec through, the canary shows it.
cat > "$STUB_DIR/claude" <<'EOF2'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "stub 0.0"; exit 0; }
agent="${CHAIN_CURRENT_AGENT:-unknown}"
echo "$agent" >> "$CANARY"
if [[ "$agent" == "goal-decomposer" ]]; then
  iter="$(printf '%s\n' "$*" | sed -n 's/^Iter name: //p' | head -1)"
  [[ -n "$iter" ]] || exit 64
  n=$(grep -c '^goal-decomposer$' "$CANARY")
  # transport loss on the RE-PLAN dispatch (exit 70) must pause, not be
  # recorded as a spec-lint failure.
  [[ -n "${STUB_DECOMP_70_ON_ATTEMPT:-}" && "$n" == "$STUB_DECOMP_70_ON_ATTEMPT" ]] && exit 70
  kind="$STUB_SPEC_KIND"
  [[ "$n" -ge 2 && -n "${STUB_SPEC_KIND_2:-}" ]] && kind="$STUB_SPEC_KIND_2"
  printf '%s\n' "$*" > "$CANARY.prompt-$n"
  out="docs/phases/${iter}.md"
  # Iteration 0 is the BASELINE iteration: the engine lints it with
  # --mode-expected baseline, and a baseline spec that plans implementation work
  # is E09 by design. These fixtures are therefore verify-only baseline specs,
  # so each failure is attributable to the ONE rule the case is about.
  {
    echo "## Goal Mode Metadata"; echo
    echo "- **Session ID:** s"
    echo "- **Iteration:** 0"
    echo "- **Mode:** baseline"
    case "$kind" in
      good)        echo "- **Depth:** lean"; echo "- **Target journeys:** J-01" ;;
      plaintarget) echo "- **Depth:** lean"; echo "Target journeys: J-01" ;;
      badenum)     echo "- **Depth:** deep"; echo "- **Target journeys:** J-01" ;;
      baselinework) echo "- **Depth:** lean"; echo "- **Target journeys:** J-01" ;;
      badmode)     echo "- **Depth:** deep"; echo "- **Target journeys:** J-01" ;;
      full78)      echo "- **Depth:** full"; echo "- **Full trigger:** 1 - new journey"; echo "- **Target journeys:** J-01" ;;
      evidence)    echo "- **Depth:** evidence"; echo "- **Target journeys:** J-01" ;;
      outsidefield) echo "- **Target journeys:** J-01" ;;
    esac
    echo "- **Work kind:** verify-only"
    echo "- **Required-still-passing journeys:** J-02"
    echo; echo "## IN SCOPE"; echo "### Backend"
    if [[ "$kind" == "baselinework" ]]; then echo "- [ ] add the endpoint"; else echo "- none"; fi
    echo "### Frontend"; echo "- N/A"
    echo; echo "## OUT OF SCOPE"; echo "- x"
    echo; echo "## DEFINITION OF DONE"; echo "- [ ] done"
    echo; echo "## TESTING REQUIREMENTS"; echo "- TC-1: given x, when y, then z"
    if [[ "$kind" == "outsidefield" ]]; then
      # the machine field exists, but as PROSE outside the metadata section
      printf '\n## NOTES\n\n- **Depth:** lean\n' >> "$out"
    fi
  } > "$out"
  if [[ -n "${STUB_CORRUPT_HISTORY:-}" ]]; then
    sid="$(printf '%s' "$iter" | sed -E 's/^goal-(.*)-iter-[0-9]+$/\1/')"
    printf '{ not json at all' > "runs/goal-session-$sid/state/journey-history.json"
  fi
  exit 0
fi
exit 70
EOF2
chmod +x "$STUB_DIR/claude"

SID_N=0
run_engine() {  # run_engine <spec-kind> [env=val ...] -> sets ENG_RC, ENG_LOG, ENG_SESSION, CANARY
  SID_N=$((SID_N+1))
  local kind="$1"; shift
  ENG_SID="lint$SID_N"
  ENG_LOG="$WORK/eng-$SID_N.log"
  CANARY="$WORK/canary-$SID_N.log"; : > "$CANARY"; export CANARY
  ENG_SESSION="$SBX/runs/goal-session-$ENG_SID"
  rm -rf "$ENG_SESSION" "$SBX/docs/phases"/*.md 2>/dev/null
  ENG_RC=0
  ( cd "$SBX" && env "PATH=$STUB_DIR:$PATH" CANARY="$CANARY" \
      STUB_SPEC_KIND="$kind" \
      CHAIN_DOCTOR=false CHAIN_GOAL_LINT=false CHAIN_SESSION_RETRO=false \
      CHAIN_TMP_ROOT="$TMPROOT" CHAIN_TMP_LEGACY_ROOTS="" \
      CHAIN_BACKEND_PORT=48731 CHAIN_FRONTEND_PORT=48732 \
      CHAIN_SKIP_GITHUB_PREFLIGHT=true \
      "$@" timeout 240 bash scripts/automation/run-goal.sh --session-id "$ENG_SID" --max-iter 1 \
        --no-push-per-iter \
  ) > "$ENG_LOG" 2>&1 || ENG_RC=$?
}
eng_status() { python3 -c "
import json,sys
try: print(json.load(open('$ENG_SESSION/session.json')).get('status','?'))
except Exception: print('?')
" 2>/dev/null; }
eng_has_event() { grep -q "\"event\": *\"$1\"" "$ENG_SESSION/telemetry.jsonl" 2>/dev/null; }
eng_dispatched() { local n; n="$(grep -c "^$1$" "$CANARY" 2>/dev/null)"; echo "${n:-0}"; }

# E1 — a clean spec dispatches: the gate is not simply blocking everything.
run_engine good
[[ "$(eng_dispatched developer)" -ge 1 ]] && eng_has_event spec_lint \
  && assert "E1: a clean spec passes the gate and the developer IS dispatched (gate is not a blanket block)" "pass" \
  || assert "E1: clean spec dispatches (rc=$ENG_RC status=$(eng_status) canary=$(tr '\n' ' ' < "$CANARY"))" "fail"
[[ -f "$ENG_SESSION/iter-0/spec-lint.txt" && -f "$ENG_SESSION/iter-0/spec-lint.json" ]] \
  && assert "E1b: the durable diagnostic iter-0/spec-lint.{txt,json} is written on the clean path too" "pass" \
  || assert "E1b: spec-lint.{txt,json} written" "fail"

# E2 — a malformed spec blocks, and NOTHING was dispatched past the decomposer.
run_engine badenum
st="$(eng_status)"
[[ "$st" == "GATE_BLOCKED" ]] \
  && assert "E2: a spec with an invalid Depth halts GATE_BLOCKED in block mode" "pass" \
  || assert "E2: malformed spec -> GATE_BLOCKED (got '$st', rc=$ENG_RC)" "fail"
[[ "$(eng_dispatched developer)" == "0" && "$(eng_dispatched browser-qa-agent)" == "0" && "$(eng_dispatched reviewer)" == "0" ]] \
  && assert "E2b: no developer, reviewer or browser-qa dispatch happened before the block" "pass" \
  || assert "E2b: no dispatch before the block (canary: $(tr '\n' ' ' < "$CANARY"))" "fail"
[[ "$(eng_dispatched goal-decomposer)" == "2" ]] \
  && assert "E2c: the decomposer was re-planned exactly ONCE (2 dispatches), then the session halted" "pass" \
  || assert "E2c: exactly one automatic re-plan (goal-decomposer dispatches: $(eng_dispatched goal-decomposer))" "fail"
eng_has_event spec_replan \
  && assert "E2d: telemetry spec_replan records the automatic re-plan" "pass" \
  || assert "E2d: spec_replan emitted" "fail"
grep -q '"reason": *"GATE_BLOCKED_SPEC_LINT"' "$ENG_SESSION/telemetry.jsonl" 2>/dev/null \
  && grep -q '"detected_at_step": *"spec-lint"' "$ENG_SESSION/telemetry.jsonl" 2>/dev/null \
  && assert "E2e: halt telemetry carries reason GATE_BLOCKED_SPEC_LINT at step spec-lint" "pass" \
  || assert "E2e: halt reason/step recorded" "fail"
grep -q 'E03' "$ENG_SESSION/iter-0/spec-lint.txt" 2>/dev/null \
  && assert "E2f: the durable diagnostic names the failing rule (E03)" "pass" \
  || assert "E2f: diagnostic names the rule" "fail"
grep -q 'SPEC LINT ERRORS' "$CANARY.prompt-2" 2>/dev/null \
  && assert "E2g: the re-plan prompt quotes the lint errors back to the decomposer" "pass" \
  || assert "E2g: re-plan prompt carries the errors" "fail"

# E3 — the re-plan actually rescues a fixable spec.
run_engine plaintarget STUB_SPEC_KIND_2=good
[[ "$(eng_dispatched goal-decomposer)" == "2" && "$(eng_dispatched developer)" -ge 1 ]] \
  && assert "E3: a spec fixed by the single re-plan proceeds to dispatch (no halt)" "pass" \
  || assert "E3: re-plan rescues a fixable spec (decomp=$(eng_dispatched goal-decomposer) dev=$(eng_dispatched developer) status=$(eng_status))" "fail"

# E4 — warn mode surfaces the same finding without blocking.
run_engine badenum CHAIN_SPEC_LINT=warn
[[ "$(eng_status)" != "GATE_BLOCKED" && "$(eng_dispatched developer)" -ge 1 ]] \
  && assert "E4: CHAIN_SPEC_LINT=warn surfaces the finding loudly and still dispatches (rollback knob)" "pass" \
  || assert "E4: warn mode dispatches (status=$(eng_status) dev=$(eng_dispatched developer))" "fail"
grep -q 'spec lint found' "$ENG_LOG" \
  && assert "E4b: warn mode logs the error count loudly" "pass" \
  || assert "E4b: warn mode logs loudly" "fail"
[[ "$(eng_dispatched goal-decomposer)" == "1" ]] \
  && assert "E4c: warn mode does not spend a re-plan" "pass" \
  || assert "E4c: warn mode does not re-plan (decomp=$(eng_dispatched goal-decomposer))" "fail"

# E5 — off disables the gate entirely.
run_engine badenum CHAIN_SPEC_LINT=off
[[ "$(eng_status)" != "GATE_BLOCKED" ]] && ! eng_has_event spec_lint \
  && assert "E5: CHAIN_SPEC_LINT=off skips the gate entirely (escape hatch)" "pass" \
  || assert "E5: off skips the gate (status=$(eng_status))" "fail"

# E6 — LINTER CRASH fails closed in block mode and is never re-planned.
CRASH_LIB="$WORK/crashlib"; mkdir -p "$CRASH_LIB"
cat > "$WORK/crash-iter_spec.py" <<'EOF3'
#!/usr/bin/env python3
import sys
if sys.argv[1:2] == ["lint"]:
    print("boom: simulated linter crash", file=sys.stderr)
    sys.exit(2)
sys.exit(0)
EOF3
cp "$SBX/scripts/automation/lib/iter_spec.py" "$WORK/iter_spec.py.real"
cp "$WORK/crash-iter_spec.py" "$SBX/scripts/automation/lib/iter_spec.py"
run_engine good
cp "$WORK/iter_spec.py.real" "$SBX/scripts/automation/lib/iter_spec.py"
st="$(eng_status)"
[[ "$st" == "GATE_BLOCKED" ]] \
  && assert "E6: a LINTER CRASH (exit 2) fails closed to GATE_BLOCKED in block mode" "pass" \
  || assert "E6: linter crash fails closed (got '$st', rc=$ENG_RC)" "fail"
[[ "$(eng_dispatched developer)" == "0" && "$(eng_dispatched browser-qa-agent)" == "0" ]] \
  && assert "E6b: a linter crash dispatches no developer and no browser lane" "pass" \
  || assert "E6b: no dispatch after a linter crash (canary: $(tr '\n' ' ' < "$CANARY"))" "fail"
[[ "$(eng_dispatched goal-decomposer)" == "1" ]] \
  && assert "E6c: a linter crash is NEVER re-planned (the planner is not what broke)" "pass" \
  || assert "E6c: crash not re-planned (decomp=$(eng_dispatched goal-decomposer))" "fail"
eng_has_event spec_lint_crash \
  && assert "E6d: telemetry spec_lint_crash distinguishes a crash from a spec error" "pass" \
  || assert "E6d: spec_lint_crash emitted" "fail"
grep -q '"detected_at_step": *"spec-lint-crash"' "$ENG_SESSION/telemetry.jsonl" 2>/dev/null \
  && assert "E6e: the halt records detected_at_step spec-lint-crash, distinct from spec-lint" "pass" \
  || assert "E6e: halt step is spec-lint-crash" "fail"

# E7 — the same crash under warn mode continues, loudly.
cp "$WORK/crash-iter_spec.py" "$SBX/scripts/automation/lib/iter_spec.py"
run_engine good CHAIN_SPEC_LINT=warn
cp "$WORK/iter_spec.py.real" "$SBX/scripts/automation/lib/iter_spec.py"
[[ "$(eng_status)" != "GATE_BLOCKED" ]] && eng_has_event spec_lint_crash && grep -q 'continuing UNVERIFIED' "$ENG_LOG" \
  && assert "E7: warn mode continues after a linter crash, saying UNVERIFIED, with spec_lint_crash recorded" "pass" \
  || assert "E7: warn mode continues loudly after a crash (status=$(eng_status))" "fail"

# E8 — an UNREADABLE spec fails closed in block mode.
# The decomposer writes the spec, then a directory replaces it: the engine's own
# existence check passes and only the linter's read fails.
cat > "$STUB_DIR/claude.unreadable" <<'EOF4'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "stub 0.0"; exit 0; }
agent="${CHAIN_CURRENT_AGENT:-unknown}"
echo "$agent" >> "$CANARY"
if [[ "$agent" == "goal-decomposer" ]]; then
  iter="$(printf '%s\n' "$*" | sed -n 's/^Iter name: //p' | head -1)"
  out="docs/phases/${iter}.md"
  printf '## Goal Mode Metadata\n\n- **Depth:** lean\n- **Target journeys:** J-01\n' > "$out"
  chmod 000 "$out"
  exit 0
fi
exit 70
EOF4
cp "$STUB_DIR/claude" "$WORK/claude.good"
cp "$STUB_DIR/claude.unreadable" "$STUB_DIR/claude"
run_engine good
cp "$WORK/claude.good" "$STUB_DIR/claude"
chmod 644 "$SBX/docs/phases"/*.md 2>/dev/null
st="$(eng_status)"
[[ "$st" == "GATE_BLOCKED" && "$(eng_dispatched developer)" == "0" ]] \
  && assert "E8: an UNREADABLE spec fails closed to GATE_BLOCKED with no developer dispatch" "pass" \
  || assert "E8: unreadable spec fails closed (got '$st', dev=$(eng_dispatched developer))" "fail"

# E9 — the engine's own knowledge of the iteration (mode baseline) blocks a
# spec that plans work, even though the spec's own prose declares verify-only.
run_engine baselinework
[[ "$(eng_status)" == "GATE_BLOCKED" && "$(eng_dispatched developer)" == "0" ]] \
  && grep -q 'E09' "$ENG_SESSION/iter-0/spec-lint.txt" 2>/dev/null \
  && assert "E9: a baseline spec that plans implementation work is blocked by E09 (engine fact beats spec prose)" "pass" \
  || assert "E9: E09 blocks a baseline spec with work (status=$(eng_status) dev=$(eng_dispatched developer))" "fail"

# ── Part G: G8 verification fixes ────────────────────────────────────────────
echo "== G. G8 verification fixes"

# G-A: machine metadata is scoped to the canonical section.
ga() { md "$1" "${2:-lean}" "${3:-implementation}"; }
ga "$SPECS/ga1.md" lean implementation
sed -i '/- \*\*Depth:\*\* lean/d' "$SPECS/ga1.md"
add_work "$SPECS/ga1.md"; printf '\n## OUT OF SCOPE\n\n- **Depth:** lean\n' >> "$SPECS/ga1.md"
lint "$SPECS/ga1.md"
dep=$(python3 "$PROBE" metadata "$SPECS/ga1.md" | python3 -c 'import json,sys;print(json.load(sys.stdin)["depth"])')
[[ "$LINT_RC" == "1" ]] && has_rule E01 && [[ "$dep" == "None" ]] \
  && assert "GA1: a bold Depth line under OUT OF SCOPE does NOT satisfy the machine field (E01, depth=None)" "pass" \
  || assert "GA1: field outside metadata never satisfies it (rc=$LINT_RC depth=$dep)" "fail"

ga "$SPECS/ga2.md" lean implementation
sed -i 's/- \*\*Target journeys:\*\* J-01, J-02/Target journeys: J-01/' "$SPECS/ga2.md"
add_work "$SPECS/ga2.md"; printf '\n## NOTES\n\n- **Target journeys:** J-99\n' >> "$SPECS/ga2.md"
lint "$SPECS/ga2.md"
tj=$(python3 "$PROBE" metadata "$SPECS/ga2.md" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(",".join(d["target_journeys"]),d["bold"]["target_journeys"])')
[[ "$tj" == "J-01 False" ]] && has_rule E02 \
  && assert "GA2: plain form inside metadata wins over a bold J-99 outside; E02 still fires; J-99 has no influence" "pass" \
  || assert "GA2: metadata-scoped precedence (parsed='$tj' rc=$LINT_RC)" "fail"

ga "$SPECS/ga3.md" lean implementation
sed -i 's/- \*\*Depth:\*\* lean/- **Depth:** lean\n- **Depth:** evidence/' "$SPECS/ga3.md"
add_work "$SPECS/ga3.md"
lint "$SPECS/ga3.md"
[[ "$LINT_RC" == "1" ]] && has_rule E12 \
  && assert "GA3: two conflicting Depth values INSIDE metadata -> E12, never resolved by regex order" "pass" \
  || assert "GA3: E12 duplicate/conflict (rc=$LINT_RC; $LINT_OUT)" "fail"

ga "$SPECS/ga3b.md" lean implementation
sed -i 's/- \*\*Depth:\*\* lean/- **Depth:** lean\n- **Depth:** lean/' "$SPECS/ga3b.md"
add_work "$SPECS/ga3b.md"
lint "$SPECS/ga3b.md"
[[ "$LINT_RC" == "0" ]] && ! has_rule E12 \
  && assert "GA3b: a repeated field with the SAME value is not a conflict" "pass" \
  || assert "GA3b: identical repeat is not E12 (rc=$LINT_RC)" "fail"

# G-B: an unverifiable independent history is never "all targets passing".
cat > "$WORK/h-malformed.json" <<'EOF5'
{ not json at all
EOF5
echo '{"journeys": []}' > "$WORK/h-shape.json"
echo '{"journeys": {"J-01": "passing", "J-02": 42}}' > "$WORK/h-rec.json"
gb_rc() { python3 "$PROBE" lint "$SPECS/evidence.md" --journey-history "$1" >/dev/null 2>&1; echo $?; }
[[ "$(gb_rc "$WORK/h-malformed.json")" == "2" ]] \
  && assert "GB1: malformed journey-history JSON -> rc 2 INPUT failure (never a clean evidence spec)" "pass" \
  || assert "GB1: malformed history -> rc 2 (got $(gb_rc "$WORK/h-malformed.json"))" "fail"
[[ "$(gb_rc "$WORK/h-shape.json")" == "2" ]] \
  && assert "GB2: wrongly-shaped journey-history ('journeys' not an object) -> rc 2" "pass" \
  || assert "GB2: wrong shape -> rc 2" "fail"
[[ "$(gb_rc "$WORK/h-rec.json")" == "2" ]] \
  && assert "GB2b: a journey record with no usable status -> rc 2" "pass" \
  || assert "GB2b: unusable record -> rc 2" "fail"
[[ "$(gb_rc "$WORK/hist-bad.json")" == "1" ]] \
  && assert "GB3: a valid history with a failing target still gives E11 (rc 1), unchanged" "pass" \
  || assert "GB3: valid history + failing target -> E11" "fail"
[[ "$(gb_rc "$WORK/hist-ok.json")" == "0" ]] \
  && assert "GB4: a valid history with every target passing lints clean" "pass" \
  || assert "GB4: all passing -> clean" "fail"
python3 "$PROBE" lint "$SPECS/evidence.md" >/dev/null 2>&1 \
  && assert "GB5: no --journey-history supplied -> E11 skipped (backward compatibility preserved)" "pass" \
  || assert "GB5: history not supplied -> skip" "fail"
chmod 000 "$WORK/hist-ok.json"
[[ "$(gb_rc "$WORK/hist-ok.json")" == "2" ]] \
  && assert "GB1b: an unreadable journey-history file -> rc 2, not silently 'all passing'" "pass" \
  || assert "GB1b: unreadable history -> rc 2" "fail"
chmod 644 "$WORK/hist-ok.json"

# G-B end-to-end: corruption during the session must halt before dispatch.
run_engine evidence STUB_CORRUPT_HISTORY=1
[[ "$(eng_status)" == "GATE_BLOCKED" && "$(eng_dispatched developer)" == "0" && "$(eng_dispatched browser-qa-agent)" == "0" ]] \
  && assert "GB6: a corrupt journey-history at lint time halts GATE_BLOCKED with zero developer/browser dispatch" "pass" \
  || assert "GB6: corrupt history blocks end-to-end (status=$(eng_status) dev=$(eng_dispatched developer))" "fail"
grep -q 'INPUT-FAILURE' "$ENG_SESSION/iter-0/spec-lint.txt" 2>/dev/null \
  && assert "GB6b: the durable diagnostic records the INPUT-FAILURE rather than a lint verdict" "pass" \
  || assert "GB6b: diagnostic records INPUT-FAILURE" "fail"
[[ "$(eng_dispatched goal-decomposer)" == "1" ]] \
  && assert "GB6c: an input-verification failure is never re-planned" "pass" \
  || assert "GB6c: input failure not re-planned (decomp=$(eng_dispatched goal-decomposer))" "fail"

# G-C: an invalid CHAIN_SPEC_LINT never degrades to warn.
run_engine badmode CHAIN_SPEC_LINT=blok
[[ "$(eng_status)" == "GATE_BLOCKED" ]] \
  && assert "GC1: CHAIN_SPEC_LINT=blok is REFUSED (GATE_BLOCKED), never interpreted as warn" "pass" \
  || assert "GC1: invalid mode refused (status=$(eng_status))" "fail"
[[ "$(eng_dispatched developer)" == "0" && "$(eng_dispatched browser-qa-agent)" == "0" ]] \
  && assert "GC1b: an invalid mode dispatches no developer and no browser lane" "pass" \
  || assert "GC1b: invalid mode -> zero dispatch (canary: $(tr '\n' ' ' < "$CANARY"))" "fail"
grep -q "is not a valid mode" "$ENG_LOG" && grep -q "NOT treated as 'warn'" "$ENG_LOG" \
  && assert "GC1c: the engine prints an explicit invalid-config diagnostic naming the valid values" "pass" \
  || assert "GC1c: explicit invalid-config diagnostic" "fail"
eng_has_event spec_lint_config_invalid && grep -q '"detected_at_step": *"spec-lint-config"' "$ENG_SESSION/telemetry.jsonl" \
  && assert "GC1d: telemetry spec_lint_config_invalid + halt step spec-lint-config" "pass" \
  || assert "GC1d: config-invalid telemetry" "fail"
! eng_has_event spec_lint \
  && assert "GC1e: the lint never ran under an invalid mode (no spec_lint event) — no warn-style continuation" "pass" \
  || assert "GC1e: no lint run under an invalid mode" "fail"

# G-D: loose IN SCOPE bullets.
md "$SPECS/gd1.md" lean verify-only "" baseline
printf '\n## IN SCOPE\n\n- verify-only baseline\n' >> "$SPECS/gd1.md"
lint "$SPECS/gd1.md" --mode-expected baseline
[[ "$LINT_RC" == "0" ]] && has_rule W06 && ! has_rule E09 \
  && assert "GD1: a harmless descriptive loose bullet stays W06 — no false blocking contradiction" "pass" \
  || assert "GD1: descriptive loose bullet not blocking (rc=$LINT_RC; $LINT_OUT)" "fail"
md "$SPECS/gd2.md" lean verify-only "" baseline
printf '\n## IN SCOPE\n\n- change users.py so login persists the token\n' >> "$SPECS/gd2.md"
lint "$SPECS/gd2.md" --mode-expected baseline
[[ "$LINT_RC" == "1" ]] && has_rule E09 && has_rule E08 \
  && assert "GD2: an ACTIONABLE loose bullet cannot smuggle real work past a verify-only baseline (E08+E09)" "pass" \
  || assert "GD2: actionable loose bullet blocks (rc=$LINT_RC; $LINT_OUT)" "fail"
md "$SPECS/gd3.md" evidence evidence-only
printf '\n## IN SCOPE\n\n- add the export endpoint\n' >> "$SPECS/gd3.md"
lint "$SPECS/gd3.md"
[[ "$LINT_RC" == "1" ]] && has_rule E07 \
  && assert "GD3: an actionable loose bullet also blocks an evidence spec (E07)" "pass" \
  || assert "GD3: actionable loose bullet blocks evidence (rc=$LINT_RC)" "fail"
md "$SPECS/gd4.md" lean implementation
printf '\n## IN SCOPE\n\n- add the export endpoint\n' >> "$SPECS/gd4.md"
lint "$SPECS/gd4.md"
[[ "$LINT_RC" == "0" ]] && has_rule W06 \
  && assert "GD4: the same bullet in a plain lean implementation spec is only W06 (no new false block)" "pass" \
  || assert "GD4: lean spec unaffected (rc=$LINT_RC; $LINT_OUT)" "fail"
python3 "$PROBE" has-implementation-work "$SPECS/gd2.md" >/dev/null 2>&1
[[ "$?" == "0" ]] \
  && assert "GD5: HARD-1's probe still counts loose bullets conservatively (unchanged, fails toward running the developer)" "pass" \
  || assert "GD5: HARD-1 probe unchanged on loose bullets" "fail"

# G-E: the engine's plain-form target fallback is section-scoped.
run_engine outsidefield
grep -q 'E01' "$ENG_SESSION/iter-0/spec-lint.txt" 2>/dev/null && [[ "$(eng_status)" == "GATE_BLOCKED" ]] \
  && assert "GE1: a Depth line living only outside Goal Mode Metadata blocks end-to-end (E01)" "pass" \
  || assert "GE1: misplaced field blocks end-to-end (status=$(eng_status))" "fail"
grep -q '_spec_field "$ITER_SPEC_PATH" target_journeys' "$RG" \
  && assert "GE2: the engine's Target-journeys read goes through the canonical section-scoped parser, not a whole-document grep" "pass" \
  || assert "GE2: target journeys read canonically" "fail"

# G-T: telemetry counts must be truthful on the CLEAN path (zero errors).
run_engine good
python3 - "$ENG_SESSION/telemetry.jsonl" <<'PYT' && assert "GT1: the clean-path spec_lint event carries truthful attempt/rc/errors/warnings/mode (no jq degradation on a zero count)" "pass" || assert "GT1: spec_lint event is complete on the clean path" "fail"
import json, sys
ev = None
for line in open(sys.argv[1]):
    try: e = json.loads(line)
    except Exception: continue
    if e.get("event") == "spec_lint":
        ev = e.get("data") if isinstance(e.get("data"), dict) else e
if ev is None:
    sys.exit(1)
missing = [k for k in ("attempt", "rc", "errors", "warnings", "mode") if k not in ev]
if missing:
    print("missing keys:", missing, file=sys.stderr); sys.exit(1)
if ev["rc"] != 0 or ev["errors"] != 0 or ev["attempt"] != 1 or ev["mode"] != "block":
    print("unexpected values:", ev, file=sys.stderr); sys.exit(1)
sys.exit(0)
PYT

# G-G: resume after a spec-lint GATE_BLOCKED (F5).
run_engine badenum
[[ "$(eng_status)" == "GATE_BLOCKED" ]] || assert "GG0: precondition — badenum halted" "fail"
BLOCKED_SESSION="$ENG_SESSION"; BLOCKED_SPEC="$SBX/docs/phases/goal-$ENG_SID-iter-0.md"
BLOCKED_SID="$ENG_SID"
# The human fixes the spec by hand. Resume must RE-LINT it, not treat the block
# as approval, and must not re-run the decomposer while the spec still parses.
sed -i 's/- \*\*Depth:\*\* deep/- **Depth:** lean/' "$BLOCKED_SPEC"
CANARY="$WORK/canary-resume.log"; : > "$CANARY"; export CANARY
RES_RC=0
( cd "$SBX" && env "PATH=$STUB_DIR:$PATH" CANARY="$CANARY" STUB_SPEC_KIND=good \
    CHAIN_DOCTOR=false CHAIN_GOAL_LINT=false CHAIN_SESSION_RETRO=false \
    CHAIN_TMP_ROOT="$TMPROOT" CHAIN_TMP_LEGACY_ROOTS="" \
    CHAIN_BACKEND_PORT=48731 CHAIN_FRONTEND_PORT=48732 CHAIN_SKIP_GITHUB_PREFLIGHT=true \
    timeout 240 bash scripts/automation/run-goal.sh --session-id "$BLOCKED_SID" --resume --max-iter 1 --no-push-per-iter \
) > "$WORK/resume.log" 2>&1 || RES_RC=$?
_rst="$(python3 -c "
import json
try: print(json.load(open('$BLOCKED_SESSION/session.json')).get('status','?'))
except Exception: print('?')" 2>/dev/null)"
_rdc="$(grep -c '^goal-decomposer$' "$CANARY" 2>/dev/null)"; _rdc="${_rdc:-0}"
[[ "$_rdc" == "0" ]] \
  && assert "GG1: resume does NOT re-dispatch the decomposer while the hand-fixed spec still parses" "pass" \
  || assert "GG1: no decomposer re-dispatch on resume (count=$_rdc canary: $(tr '\n' ' ' < "$CANARY"))" "fail"
grep -q 'spec-lint' "$WORK/resume.log" || grep -q 'spec_lint' "$BLOCKED_SESSION/telemetry.jsonl" \
  && assert "GG2: resume RE-LINTS the hand-fixed spec rather than treating the block as approval" "pass" \
  || assert "GG2: resume re-lints the spec" "fail"
_rdev="$(grep -c '^developer$' "$CANARY" 2>/dev/null)"; _rdev="${_rdev:-0}"
[[ "$_rst" != "GATE_BLOCKED" && "$_rdev" -ge 1 ]] \
  && assert "GG3: the corrected spec then passes the gate and the iteration dispatches" "pass" \
  || assert "GG3: corrected spec dispatches (status=$_rst canary=$(tr '\n' ' ' < "$CANARY"))" "fail"

# G-H: transport loss during the automatic re-plan (F6).
run_engine badenum STUB_DECOMP_70_ON_ATTEMPT=2
[[ "$(eng_status)" == "AWAITING_PUMP" ]] \
  && assert "GH1: transport loss (exit 70) on the re-plan dispatch pauses AWAITING_PUMP, not GATE_BLOCKED" "pass" \
  || assert "GH1: re-plan transport loss pauses (status=$(eng_status))" "fail"
[[ "$(eng_dispatched developer)" == "0" ]] \
  && assert "GH2: a transport pause during the re-plan dispatches no developer" "pass" \
  || assert "GH2: no developer on a re-plan transport pause" "fail"

# G-F: quickstart recovery documentation.
grep -q 'GATE_BLOCKED. (spec lint)' "$ENGINE_ROOT/docs/goal-mode-quickstart.md" \
  && grep -q 'spec-lint.txt' "$ENGINE_ROOT/docs/goal-mode-quickstart.md" \
  && grep -q 'goal-resume' "$ENGINE_ROOT/docs/goal-mode-quickstart.md" \
  && assert "GF1: goal-mode-quickstart.md documents the spec-lint GATE_BLOCKED recovery path" "pass" \
  || assert "GF1: quickstart recovery note present" "fail"

# ── Part W: wiring ───────────────────────────────────────────────────────────
echo "== W. wiring"
grep -q 'CHAIN_SPEC_LINT' "$RG" && grep -q 'GATE_BLOCKED_SPEC_LINT' "$RG" && grep -q 'spec_replan' "$RG" \
  && assert "W1: run-goal.sh carries CHAIN_SPEC_LINT, GATE_BLOCKED_SPEC_LINT and spec_replan" "pass" \
  || assert "W1: knob + halt reason + replan event present" "fail"
_mark=$(grep -n 'step_mark_done decomposer' "$RG" | head -1 | cut -d: -f1)
_lint=$(grep -n 'HARD-2 deterministic spec lint' "$RG" | head -1 | cut -d: -f1)
_gate=$(grep -n 'Post-decompose gate (generic, project-local' "$RG" | head -1 | cut -d: -f1)
_disp=$(grep -n 'Dispatching LEAN pipeline' "$RG" | head -1 | cut -d: -f1)
[[ -n "$_mark" && -n "$_lint" && -n "$_gate" && -n "$_disp" && "$_mark" -lt "$_lint" && "$_lint" -lt "$_gate" && "$_gate" -lt "$_disp" ]] \
  && assert "W2: ordering decomposer < spec-lint < project post-decompose gate < executor dispatch" "pass" \
  || assert "W2: gate ordering (mark=$_mark lint=$_lint gate=$_gate dispatch=$_disp)" "fail"
grep -q '"GATE_BLOCKED")' "$RG" || grep -q '"AWAITING_FULL_DEPTH", "GATE_BLOCKED"' "$RG" \
  && assert "W3: GATE_BLOCKED is in the resume status-reset list (a fixed spec can resume)" "pass" \
  || assert "W3: GATE_BLOCKED in the resume reset list" "fail"
# W4 (rewritten): the old contract was "the whole-document bold grep runs FIRST,
# the canonical parser is only a fallback". That contract WAS the split brain and
# is retired. DEPTH and TARGET_JOURNEYS now come from the canonical parser; the
# legacy grep survives only for a spec with no metadata section (phase mode).
grep -q '_spec_field "$ITER_SPEC_PATH" depth' "$RG" && grep -q '_spec_field "$ITER_SPEC_PATH" target_journeys' "$RG" \
  && assert "W4: DEPTH and TARGET_JOURNEYS are read through the canonical _spec_field accessor" "pass" \
  || assert "W4: canonical accessor used for DEPTH and TARGET_JOURNEYS" "fail"
grep -q '_depth_rc" -eq 3' "$RG" && grep -q '_tj_rc" -eq 3' "$RG" \
  && assert "W4b: the legacy grep survives only behind the probe's exit-3 (no metadata section = phase mode)" "pass" \
  || assert "W4b: legacy grep gated on exit 3" "fail"
grep -q 'iter_spec.py" field' "$ENGINE_ROOT/scripts/automation/lib/replay-lane.sh" \
  && assert "W4c: the browser lane's journey sets come from the canonical parser too" "pass" \
  || assert "W4c: replay lane uses the canonical parser" "fail"
grep -q '_spec_full_trigger_present' "$RG" \
  && assert "W4d: 'Full trigger:' presence is canonical too (a NOTES line cannot grant full depth)" "pass" \
  || assert "W4d: Full trigger presence is canonical" "fail"
grep -q 'Work kind' "$ENGINE_ROOT/agents/goal-decomposer/body.md" \
  && grep -q 'Spec lint (deterministic — HARD-2)' "$ENGINE_ROOT/agents/goal-decomposer/body.md" \
  && assert "W5: the decomposer contract documents Work kind and the spec-lint rules" "pass" \
  || assert "W5: decomposer contract updated" "fail"
python3 "$ENGINE_ROOT/scripts/automation/sync-cli-assets.py" --cli claude --check >/dev/null 2>&1 \
  && assert "W6: sync-cli-assets --check is clean (generated mirrors match the neutral source)" "pass" \
  || assert "W6: mirror drift check clean" "fail"

# ── Part M: one canonical machine-field source (post-G8 blocker 1) ───────────
echo "== M. canonical machine fields"
mk_split() {  # mk_split <file> <outside-depth> <outside-targets> <inside-depth> <inside-targets>
  { echo "## NOTES"; echo
    echo "- **Depth:** $2"
    echo "- **Target journeys:** $3"; echo
    echo "## Goal Mode Metadata"; echo
    echo "- **Mode:** next"
    echo "- **Depth:** $4"
    echo "- **Target journeys:** $5"
    echo "- **Required-still-passing journeys:** J-02"
    echo "- **Work kind:** implementation"
    echo "- **Full trigger:** 2 - coherence FAIL"; echo
    echo "## IN SCOPE"; echo "### Backend"; echo "- [ ] add it"; echo
    echo "## OUT OF SCOPE"; echo "- x"; echo
    echo "## DEFINITION OF DONE"; echo "- [ ] done"; echo
    echo "## TESTING REQUIREMENTS"; echo "- TC-1: given x, when y, then z"; } > "$1"
}
canon() { python3 "$PROBE" field "$1" "$2"; }

mk_split "$SPECS/m1.md" evidence J-99 lean "J-01"
[[ "$(canon "$SPECS/m1.md" depth)" == "lean" ]] \
  && assert "M1: an external '**Depth:** evidence' before the metadata section has ZERO effect (canonical depth is lean)" "pass" \
  || assert "M1: canonical depth wins (got '$(canon "$SPECS/m1.md" depth)')" "fail"
lint "$SPECS/m1.md"
has_rule W12 \
  && assert "M1b: the shadowed external copy is reported as prose with zero runtime influence (W12, non-blocking)" "pass" \
  || assert "M1b: shadowed external field reported (rc=$LINT_RC; $LINT_OUT)" "fail"
[[ "$(canon "$SPECS/m1.md" target_journeys)" == "J-01" ]] \
  && assert "M2: an external '**Target journeys:** J-99' has ZERO influence (canonical list is J-01)" "pass" \
  || assert "M2: canonical targets win (got '$(canon "$SPECS/m1.md" target_journeys)')" "fail"
( source "$ENGINE_ROOT/scripts/automation/lib/replay-lane.sh" 2>/dev/null
  printf '%s' "$(replay_lane_spec_journeys 'Target journeys:' "$SPECS/m1.md")" ) > "$WORK/m2.out" 2>/dev/null
grep -q 'J-01' "$WORK/m2.out" && ! grep -q 'J-99' "$WORK/m2.out" \
  && assert "M2b: the browser lane's target set is J-01 only - J-99 never reaches it" "pass" \
  || assert "M2b: browser lane targets canonical (got '$(cat "$WORK/m2.out")')" "fail"
mk_split "$SPECS/m3.md" full "J-98, J-99" lean "J-01, J-03"
[[ "$(canon "$SPECS/m3.md" depth)" == "lean" && "$(canon "$SPECS/m3.md" target_journeys)" == "J-01, J-03" ]] \
  && assert "M3: conflicting external duplicates are prose - runtime uses the canonical section only" "pass" \
  || assert "M3: canonical only (depth=$(canon "$SPECS/m3.md" depth) tj=$(canon "$SPECS/m3.md" target_journeys))" "fail"
md "$SPECS/m4.md" lean implementation
sed -i 's/- \*\*Target journeys:\*\* J-01, J-02/Target journeys: J-01, J-02/' "$SPECS/m4.md"
add_work "$SPECS/m4.md"; add_tail "$SPECS/m4.md"
lint "$SPECS/m4.md"
[[ "$(canon "$SPECS/m4.md" target_journeys)" == "J-01, J-02" && "$LINT_RC" == "1" ]] && has_rule E02 \
  && assert "M4: a plain-form field inside metadata is READ canonically for compatibility and still blocks with E02" "pass" \
  || assert "M4: plain form read + E02 (canon='$(canon "$SPECS/m4.md" target_journeys)' rc=$LINT_RC)" "fail"
run_engine good
_dd="$(cat "$ENG_SESSION/iter-0/depth-dispatched" 2>/dev/null)"
[[ "$_dd" == "lean" ]] \
  && assert "M5: the depth the engine DISPATCHED matches the canonical metadata the linter validated" "pass" \
  || assert "M5: dispatched depth matches canonical (depth-dispatched='$_dd')" "fail"
# M7 — the legacy short label the pre-HARD-2 prefix grep accepted.
{ echo "## Goal Mode Metadata"; echo "- **Mode:** next"; echo "- **Depth:** lean"
  echo "- **Target journeys:** J-01"; echo "- **Required-still-passing:** J-02"
  echo "- **Work kind:** implementation"; } > "$SPECS/m7.md"
add_work "$SPECS/m7.md"; add_tail "$SPECS/m7.md"
[[ "$(canon "$SPECS/m7.md" required_journeys)" == "J-02" ]] \
  && assert "M7: the legacy short label 'Required-still-passing:' (no trailing 'journeys') is still read canonically" "pass" \
  || assert "M7: short-label compatibility (got '$(canon "$SPECS/m7.md" required_journeys)')" "fail"
lint "$SPECS/m7.md"
[[ "$LINT_RC" == "0" ]] \
  && assert "M7b: a legacy short-label spec still lints clean (no new false block)" "pass" \
  || assert "M7b: short-label spec lints clean (rc=$LINT_RC; $LINT_OUT)" "fail"

printf '# Phase 7\n\nTarget journeys: J-05\n' > "$SPECS/phase-7.md"
( source "$ENGINE_ROOT/scripts/automation/lib/replay-lane.sh" 2>/dev/null
  printf '%s' "$(replay_lane_spec_journeys 'Target journeys:' "$SPECS/phase-7.md")" ) > "$WORK/m6.out" 2>/dev/null
grep -q 'J-05' "$WORK/m6.out" \
  && assert "M6: a phase-mode spec with no metadata section still parses via the legacy grep (phase mode untouched)" "pass" \
  || assert "M6: phase-mode fallback preserved (got '$(cat "$WORK/m6.out")')" "fail"

# ── Part LG: the loose-bullet compatibility grammar (post-G8 blocker 2) ──────
echo "== LG. loose-bullet grammar"
loose_case() {  # loose_case <id> <bullet> <expect-blocked yes|no> <name>
  local f="$SPECS/loose-$1.md"
  md "$f" lean verify-only "" baseline
  printf '\n## IN SCOPE\n\n- %s\n' "$2" >> "$f"
  lint "$f" --mode-expected baseline
  local blocked=no; [[ "$LINT_RC" == "1" ]] && blocked=yes
  if [[ "$blocked" == "$3" ]]; then assert "$4" "pass"
  else assert "$4 (rc=$LINT_RC; $(printf '%s' "$LINT_OUT" | head -1 | cut -c1-90))" "fail"; fi
}
loose_case l1 "verify-only baseline" no "L1: '- verify-only baseline' stays a non-blocking compatibility case"
lint "$SPECS/loose-l1.md" --mode-expected baseline
has_rule W06 && assert "L1b: the harmless legacy bullet still reports W06" "pass" || assert "L1b: W06 on the legacy bullet" "fail"
loose_case l1c "verify-only baseline (iteration-state wiring test)" no "L1c: the exact legacy fixture form used by test-goal-iteration-state stays non-blocking"
loose_case l2 "review the authentication flow and change login behavior to persist tokens" yes "L2: a descriptive opener followed by 'change ... persist' is ACTIONABLE"
loose_case l3 "document the new login behavior and implement persistence" yes "L3: 'document ... and implement ...' is ACTIONABLE"
loose_case l4 "verify the flow by adding persistent token storage" yes "L4: 'verify ... by adding ...' is ACTIONABLE"
loose_case l4b "inspect the account screen and update the login behavior" yes "L4b: 'inspect ... and update ...' is ACTIONABLE"
loose_case l5 "frobnicate the widget" yes "L5: unknown non-allowlisted phrasing is ACTIONABLE by default (fails safe)"
loose_case l6 "capture screenshots for J-01 and J-02" no "L6: a capture-only legacy descriptor with no construction clause stays descriptive"
loose_case l6b "evidence capture for the export flow" no "L6b: an evidence-capture descriptor stays descriptive"
lint "$SPECS/loose-l2.md" --mode-expected baseline
has_rule E08 && has_rule E09 \
  && assert "L2b: the actionable mixed-action bullet raises BOTH E08 (verify-only) and E09 (baseline)" "pass" \
  || assert "L2b: E08+E09 on the actionable bullet" "fail"
python3 "$PROBE" has-implementation-work "$SPECS/loose-l1.md" >/dev/null 2>&1
[[ "$?" == "0" ]] \
  && assert "L7: HARD-1's probe STILL counts the harmless loose bullet as work (unchanged, conservative)" "pass" \
  || assert "L7: HARD-1 probe unchanged by the narrowed classifier" "fail"

# ── Part RCF: the replay lane never degrades on an accessor FAILURE ──────────
echo "== RCF. replay-lane accessor rc handling"
# A private lib dir so `dirname "${BASH_SOURCE[0]}"` resolves to OUR stub probe.
RCF="$WORK/rcf"; mkdir -p "$RCF/lib"
cp "$ENGINE_ROOT/scripts/automation/lib/replay-lane.sh" "$RCF/lib/"
cp "$ENGINE_ROOT/scripts/automation/lib/iter_spec.py" "$RCF/lib/iter_spec.py.real"
# A goal-mode spec WITH metadata, plus prose the legacy grep would happily find.
{ echo "## NOTES"; echo "- **Target journeys:** J-99"
  echo "- **Required-still-passing journeys:** J-98"; echo
  echo "## Goal Mode Metadata"; echo "- **Mode:** next"; echo "- **Depth:** lean"
  echo "- **Target journeys:** J-01"; echo "- **Required-still-passing journeys:** J-02"
  echo "- **Work kind:** implementation"; echo
  echo "## IN SCOPE"; echo "### Backend"; echo "- [ ] add it"; } > "$RCF/spec.md"
printf '# Phase 7\n\nTarget journeys: J-05\n' > "$RCF/phase.md"
cat > "$RCF/lib/crash.py" <<'EOF8'
#!/usr/bin/env python3
import sys
sys.exit(2)
EOF8

rcf_call() {  # rcf_call <probe: real|crash> <label> <spec> -> stdout to $WORK/rcf.out, rc echoed
  cp "$RCF/lib/${1}" "$RCF/lib/iter_spec.py" 2>/dev/null || cp "$RCF/lib/iter_spec.py.real" "$RCF/lib/iter_spec.py"
  local _rc=0
  ( set +e
    # shellcheck disable=SC1090
    source "$RCF/lib/replay-lane.sh" 2>/dev/null
    replay_lane_spec_journeys "$2" "$3" ) > "$WORK/rcf.out" 2>"$WORK/rcf.err" || _rc=$?
  echo "$_rc"
}

_rc="$(rcf_call crash.py 'Target journeys:' "$RCF/spec.md")"
_out="$(cat "$WORK/rcf.out")"
[[ "$_rc" != "0" ]] && [[ -z "$_out" ]] && ! grep -q 'J-99' "$WORK/rcf.out" \
  && assert "RCF1: accessor rc2 on a metadata-bearing spec FAILS (rc!=0) and prints nothing - J-99 never returned" "pass" \
  || assert "RCF1: rc2 fails without leaking prose (rc=$_rc out='$_out')" "fail"
grep -qi 'refusing' "$WORK/rcf.err" \
  && assert "RCF1b: the failure is announced on stderr, naming the refusal to fall back" "pass" \
  || assert "RCF1b: loud stderr on accessor failure ($(head -c 120 "$WORK/rcf.err"))" "fail"
[[ "$_rc" == "78" ]] \
  && assert "RCF1c: it returns the reserved SPEC_FIELD_UNAVAILABLE_EXIT_CODE (78), not a generic 1" "pass" \
  || assert "RCF1c: distinct failure code (got $_rc)" "fail"
# Under `set -e` - how both real callers assign - the failure aborts.
( set -e
  # shellcheck disable=SC1090
  source "$RCF/lib/replay-lane.sh" 2>/dev/null
  X="$(replay_lane_spec_journeys 'Target journeys:' "$RCF/spec.md")"
  echo "NOT-ABORTED" ) > "$WORK/rcf-sete.out" 2>/dev/null
! grep -q 'NOT-ABORTED' "$WORK/rcf-sete.out" \
  && assert "RCF1d: under 'set -e' (both real callers' shape) the failure ABORTS - it cannot read as a valid empty set" "pass" \
  || assert "RCF1d: set -e aborts on the failure" "fail"

_rc="$(rcf_call crash.py 'Required-still-passing' "$RCF/spec.md")"
[[ "$_rc" != "0" ]] && ! grep -q 'J-98' "$WORK/rcf.out" \
  && assert "RCF2: required-journeys behaves identically on rc2 - J-98 prose never leaks" "pass" \
  || assert "RCF2: required journeys fail closed (rc=$_rc out='$(cat "$WORK/rcf.out")')" "fail"

_rc="$(rcf_call iter_spec.py.real 'Target journeys:' "$RCF/phase.md")"
grep -q 'J-05' "$WORK/rcf.out" && [[ "$_rc" == "0" ]] \
  && assert "RCF3: rc3 (phase-mode spec, no metadata section) still uses the legacy grep and returns J-05" "pass" \
  || assert "RCF3: phase-mode fallback preserved (rc=$_rc out='$(cat "$WORK/rcf.out")')" "fail"

_rc="$(rcf_call iter_spec.py.real 'Target journeys:' "$RCF/spec.md")"
grep -q 'J-01' "$WORK/rcf.out" && ! grep -q 'J-99' "$WORK/rcf.out" && [[ "$_rc" == "0" ]] \
  && assert "RCF4: rc0 returns the canonical J-01 only - external J-99 has no influence" "pass" \
  || assert "RCF4: rc0 canonical (rc=$_rc out='$(cat "$WORK/rcf.out")')" "fail"

grep -q '3)' "$ENGINE_ROOT/scripts/automation/lib/replay-lane.sh" \
  && ! grep -qE 'if \[\[ "\$_rc" -eq 0 \]\]; then' "$ENGINE_ROOT/scripts/automation/lib/replay-lane.sh" \
  && assert "RCF5 (structural): the implementation branches on rc==3 explicitly, not on 'anything nonzero'" "pass" \
  || assert "RCF5: explicit rc==3 branch" "fail"
grep -q 'SPEC_FIELD_UNAVAILABLE_EXIT_CODE' "$ENGINE_ROOT/scripts/automation/lib/common.sh" \
  && assert "RCF5b: the failure code is a named reserved constant in lib/common.sh" "pass" \
  || assert "RCF5b: named failure constant" "fail"

# ── Part LW: write/wire are construction verbs; one exact legacy shape is not ─
echo "== LW. write/wire loose-bullet edge"
loose_case lw1 "verify-only baseline (iteration-state wiring test)" no \
  "LW1: the exact legacy descriptor with 'wiring' in a parenthetical stays non-blocking"
lint "$SPECS/loose-lw1.md" --mode-expected baseline
has_rule W06 && assert "LW1b: the legacy descriptor still reports W06" "pass" || assert "LW1b: W06 on the legacy descriptor" "fail"
loose_case lw2 "verify the login flow by writing persistent session state" yes \
  "LW2: 'verify ... by writing ...' is ACTIONABLE (E08+E09)"
loose_case lw3 "confirm the feature by wiring token persistence into the login path" yes \
  "LW3: 'confirm ... by wiring ...' is ACTIONABLE"
loose_case lw4 "write persistent session state" yes "LW4: a bare 'write ...' instruction is ACTIONABLE"
loose_case lw5 "wire token persistence into the login path" yes "LW5: a bare 'wire ...' instruction is ACTIONABLE"
lint "$SPECS/loose-lw2.md" --mode-expected baseline
has_rule E08 && has_rule E09 \
  && assert "LW2b: the writing bullet raises BOTH E08 (verify-only) and E09 (baseline)" "pass" \
  || assert "LW2b: E08+E09 on the writing bullet" "fail"
_lw_unchanged=yes
for f in lw1 lw2 lw3 lw4 lw5; do
  python3 "$PROBE" has-implementation-work "$SPECS/loose-$f.md" >/dev/null 2>&1 || _lw_unchanged=no
done
[[ "$_lw_unchanged" == "yes" ]] \
  && assert "LW6: HARD-1's has-implementation-work still counts every one of these loose bullets as work (unchanged)" "pass" \
  || assert "LW6: HARD-1 probe unchanged across the LW cases" "fail"

# ── Part P78: rc 78 stays safety-fatal through run-phase.sh ─────────────────
echo "== P78. run-phase fatal propagation"
RP="$ENGINE_ROOT/scripts/automation/run-phase.sh"
# Drive the REAL guard: extract it plus its two predicates and the new one.
{ sed -n '/^_is_signal_exit()/,/^}/p' "$RP"
  sed -n '/^_is_transport_failure()/,/^}/p' "$RP"
  sed -n '/^_is_spec_field_unavailable()/,/^}/p' "$RP"
  echo 'log() { echo "$*"; }'
  sed -n '/^_guard_step_rc()/,/^}/p' "$RP"; } > "$WORK/guard.sh"
guard_rc() {  # guard_rc <rc> -> exit code of the guard (0 = fell through)
  local _g=0
  ( set +e; # shellcheck disable=SC1090
    . "$WORK/guard.sh"; _guard_step_rc "$1" "Step 6 (browser-qa)" ) > "$WORK/guard.out" 2>&1 || _g=$?
  echo "$_g"
}
[[ "$(guard_rc 78)" == "78" ]] \
  && assert "P78-1: _guard_step_rc exits 78 for a canonical spec-field failure (never falls through to the caller's warning)" "pass" \
  || assert "P78-1: guard exits 78 (got $(guard_rc 78))" "fail"
grep -qi 'canonical Goal Mode Metadata field lookup UNAVAILABLE' "$WORK/guard.out" \
  && assert "P78-1b: it says WHY, naming the canonical metadata lookup rather than an agent-quality failure" "pass" \
  || assert "P78-1b: explicit diagnostic ($(head -c 90 "$WORK/guard.out"))" "fail"
# The guard runs BEFORE the warn-and-continue at both the sequential browser-QA
# site and the post-dev fanout site, so neither can convert 78 into a retry.
_bqa_guard=$(grep -n '_guard_step_rc "$bqa_rc"' "$RP" | head -1 | cut -d: -f1)
_bqa_warn=$(grep -n 'Warning: browser-qa-phase.sh exited with error' "$RP" | head -1 | cut -d: -f1)
[[ -n "$_bqa_guard" && -n "$_bqa_warn" && "$_bqa_guard" -lt "$_bqa_warn" ]] \
  && assert "P78-1c: the sequential browser-QA guard precedes 'Warning: ... continuing'" "pass" \
  || assert "P78-1c: guard precedes the bqa warning (guard=$_bqa_guard warn=$_bqa_warn)" "fail"
_fan_guard=$(grep -n '_guard_step_rc "$fanout_rc"' "$RP" | head -1 | cut -d: -f1)
_fan_warn=$(grep -n 'sequential retry will pick up any failed step' "$RP" | head -1 | cut -d: -f1)
[[ -n "$_fan_guard" && -n "$_fan_warn" && "$_fan_guard" -lt "$_fan_warn" ]] \
  && assert "P78-2: the post-dev FANOUT guard precedes 'sequential retry will pick up any failed step'" "pass" \
  || assert "P78-2: fanout guard precedes sequential recovery (guard=$_fan_guard warn=$_fan_warn)" "fail"
grep -q 'return "$_rc"' "$RP" && grep -q 'browser-qa-phase.sh.*aborting chain' "$RP" \
  && assert "P78-2b: the fanout branch propagates the browser-QA rc out of the fork rather than swallowing it" "pass" \
  || assert "P78-2b: fanout branch propagates rc" "fail"
_t70="$(guard_rc 70)"; _t75="$(guard_rc 75)"; _t130="$(guard_rc 130)"; _t143="$(guard_rc 143)"; _t1="$(guard_rc 1)"
[[ "$_t70" == "70" && "$_t130" == "130" && "$_t143" == "143" && "$_t75" == "0" && "$_t1" == "0" ]] \
  && assert "P78-3: rc 70 transport, 130/143 signals stay fatal; rc 75 quota and rc 1 still fall through unchanged" "pass" \
  || assert "P78-3: existing rc semantics unchanged (70=$_t70 75=$_t75 130=$_t130 143=$_t143 1=$_t1)" "fail"

# ── Part G78: rc 78 halts the top-level engine on BOTH depth paths ───────────
echo "== G78. engine-level fatal propagation"
cp "$SBX/scripts/automation/goal-iter-lean.sh" "$WORK/lean.real"
cp "$SBX/scripts/automation/run-phase.sh" "$WORK/phase.real"
printf '#!/usr/bin/env bash\nexit 78\n' > "$WORK/exit78.sh"

cp "$WORK/exit78.sh" "$SBX/scripts/automation/goal-iter-lean.sh"
run_engine good
cp "$WORK/lean.real" "$SBX/scripts/automation/goal-iter-lean.sh"
_g78_session="$ENG_SESSION"; _g78_sid="$ENG_SID"
[[ "$(eng_status)" == "GATE_BLOCKED" ]] \
  && assert "G78-1: a LEAN executor exiting 78 halts the engine GATE_BLOCKED" "pass" \
  || assert "G78-1: lean rc78 -> GATE_BLOCKED (got '$(eng_status)')" "fail"
grep -q '"reason": *"GATE_BLOCKED_SPEC_FIELD_UNAVAILABLE"' "$ENG_SESSION/telemetry.jsonl" 2>/dev/null \
  && grep -q '"detected_at_step": *"executor-spec-field"' "$ENG_SESSION/telemetry.jsonl" 2>/dev/null \
  && assert "G78-1b: halt telemetry carries GATE_BLOCKED_SPEC_FIELD_UNAVAILABLE at step executor-spec-field" "pass" \
  || assert "G78-1b: halt telemetry reason/step" "fail"
[[ "$(eng_dispatched coherence-auditor)" == "0" && "$(eng_dispatched goal-evaluator)" == "0" ]] \
  && assert "G78-1c: neither the coherence auditor nor the goal-evaluator ran on the un-evaluated iteration" "pass" \
  || assert "G78-1c: no coherence/evaluator after rc78 (canary: $(tr '\n' ' ' < "$CANARY"))" "fail"
_ci="$(python3 -c "
import json
try: print(json.load(open('$ENG_SESSION/session.json')).get('current_iter','?'))
except Exception: print('?')" 2>/dev/null)"
[[ "$_ci" == "0" ]] \
  && assert "G78-1d: current_iter was NOT advanced (still 0)" "pass" \
  || assert "G78-1d: current_iter unchanged (got '$_ci')" "fail"
[[ -f "$ENG_SESSION/iter-0/spec-field-unavailable" ]] \
  && grep -q 'reason=canonical-spec-field-unavailable' "$ENG_SESSION/iter-0/spec-field-unavailable" \
  && assert "G78-1e: a durable iter-0/spec-field-unavailable artifact records the reason and rc" "pass" \
  || assert "G78-1e: durable halt artifact" "fail"
grep -q 'refused to report an empty journey set\|refused to fall back' "$ENG_LOG" \
  && assert "G78-1f: the operator message says the legacy fallback was deliberately refused" "pass" \
  || assert "G78-1f: operator message explains the refusal" "fail"

# Full path: the engine dispatches run-phase.sh, which exits 78.
printf '#!/usr/bin/env bash\n# --no-finalize\nexit 78\n' > "$SBX/scripts/automation/run-phase.sh"
run_engine full78 CHAIN_DEPTH_ARBITER=false
cp "$WORK/phase.real" "$SBX/scripts/automation/run-phase.sh"
_fd="$(cat "$ENG_SESSION/iter-0/depth-dispatched" 2>/dev/null)"
[[ "$(eng_status)" == "GATE_BLOCKED" ]] && [[ "$_fd" == "full" ]] \
  && assert "G78-2: the FULL pipeline exiting 78 reaches the identical top-level GATE_BLOCKED halt" "pass" \
  || assert "G78-2: full rc78 -> GATE_BLOCKED (status='$(eng_status)' depth='$_fd')" "fail"
[[ "$(eng_dispatched goal-evaluator)" == "0" ]] \
  && assert "G78-2b: the full path also stops before the evaluator (lean and full do not diverge)" "pass" \
  || assert "G78-2b: no evaluator on the full path" "fail"

# Resume: fix the fault, resume, and the SAME iteration re-runs with the checks.
CANARY="$WORK/canary-g78resume.log"; : > "$CANARY"; export CANARY
( cd "$SBX" && env "PATH=$STUB_DIR:$PATH" CANARY="$CANARY" STUB_SPEC_KIND=good \
    CHAIN_DOCTOR=false CHAIN_GOAL_LINT=false CHAIN_SESSION_RETRO=false \
    CHAIN_TMP_ROOT="$TMPROOT" CHAIN_TMP_LEGACY_ROOTS="" \
    CHAIN_BACKEND_PORT=48731 CHAIN_FRONTEND_PORT=48732 CHAIN_SKIP_GITHUB_PREFLIGHT=true \
    timeout 240 bash scripts/automation/run-goal.sh --session-id "$_g78_sid" --resume --max-iter 1 --no-push-per-iter \
) > "$WORK/g78-resume.log" 2>&1 || true
_rci="$(python3 -c "
import json
try:
    d=json.load(open('$_g78_session/session.json')); print(d.get('current_iter','?'), d.get('status','?'))
except Exception: print('? ?')" 2>/dev/null)"
grep -q '^developer$' "$CANARY" \
  && assert "G78-3: after fixing the fault, resume re-runs the SAME iteration and dispatches the developer" "pass" \
  || assert "G78-3: resume re-runs the iteration (canary: $(tr '\n' ' ' < "$CANARY"))" "fail"
grep -q 'spec_lint' "$_g78_session/telemetry.jsonl" 2>/dev/null \
  && assert "G78-3b: resume re-runs the deterministic spec lint (the halt was never treated as approval)" "pass" \
  || assert "G78-3b: resume re-lints" "fail"
[[ "${_rci%% *}" == "0" ]] \
  && assert "G78-3c: the iteration index did not advance across the halt and the resume" "pass" \
  || assert "G78-3c: iteration index unchanged (got '$_rci')" "fail"

# ── Part GS: the evaluator goal slice uses the canonical target list ─────────
echo "== GS. evaluator goal-slice target source"
GS="$WORK/gs"; mkdir -p "$GS"
# J-01 and J-99 are BOTH already passing. goal-slice keeps targets verbatim and
# digests stable-passing NON-targets, so which one stays verbatim is exactly the
# observable difference between the canonical list and a shadow line.
cat > "$GS/goal.md" <<'EOF9'
# Goal

A tiny exporter.

## Must-have user journeys

- **J-01: Open the page**
  - Steps: open /
  - Acceptance: the page loads and shows the table header
- **J-99: Export the CSV**
  - Steps: click export
  - Acceptance: a csv file downloads with a header row

## Anti-goals

- no paid SaaS
EOF9
cat > "$GS/history.json" <<'EOF9'
{"journeys": {"J-01": {"status": "passing"}, "J-99": {"status": "already_passing"}},
 "anti_goal_violations": [], "updated_at": ""}
EOF9
cat > "$GS/spec.md" <<'EOF9'
## NOTES

- **Target journeys:** J-99

## Goal Mode Metadata

- **Mode:** next
- **Depth:** lean
- **Target journeys:** J-01
- **Required-still-passing journeys:** J-99
- **Work kind:** implementation

## IN SCOPE
### Backend
- [ ] add it
EOF9
# Drive the REAL pre-evaluator slice lines, extracted from run-goal.sh between
# its own stable anchors, with the canonical variable set exactly as the engine
# sets it. This exercises the shipped code path, not a paraphrase of it.
_gs_start=$(grep -n 'HARD-2: the evaluator.s goal slice keeps THIS iteration' "$RG" | head -1 | cut -d: -f1)
_gs_end=$(grep -n -- '--out "\$GOAL_SLICE_PATH" 2>/dev/null || true' "$RG" | head -1 | cut -d: -f1)
[[ -n "$_gs_start" && -n "$_gs_end" && "$_gs_start" -lt "$_gs_end" ]] \
  && assert "GS0: the pre-evaluator goal-slice block was located for extraction" "pass" \
  || assert "GS0: locate the goal-slice block (start=$_gs_start end=$_gs_end)" "fail"
sed -n "${_gs_start:-1},${_gs_end:-1}p" "$RG" > "$GS/slice-block.sh"
run_slice() {  # run_slice <canonical TARGET_JOURNEYS>
  rm -f "$GS/goal-slice.md"
  ( set +u
    SCRIPT_DIR="$ENGINE_ROOT/scripts/automation"
    GOAL_FILE="$GS/goal.md"; JOURNEY_HISTORY="$GS/history.json"
    GOAL_SLICE_PATH="$GS/goal-slice.md"; ITER_SPEC_PATH="$GS/spec.md"
    TARGET_JOURNEYS="$1"
    # shellcheck disable=SC1090
    . "$GS/slice-block.sh" ) >/dev/null 2>&1
}
# The canonical read of this very spec, exactly what the depth block produces.
_gs_canon="$(python3 "$PROBE" field "$GS/spec.md" target_journeys)"
[[ "$_gs_canon" == "J-01" ]] \
  && assert "GS1: the canonical parser reads J-01 from the metadata section (the NOTES J-99 is prose)" "pass" \
  || assert "GS1: canonical target is J-01 (got '$_gs_canon')" "fail"

run_slice "$_gs_canon"
# T1 + T2: the canonical target stays VERBATIM (its acceptance text survives);
# the non-target passing journey is digested away.
grep -q 'shows the table header' "$GS/goal-slice.md" \
  && assert "T2/GS2: the canonical target J-01 stays VERBATIM in the evaluator slice even though it is already passing" "pass" \
  || assert "T2/GS2: canonical target verbatim ($(head -c 120 "$GS/goal-slice.md" | tr '\n' ' '))" "fail"
! grep -q 'a csv file downloads with a header row' "$GS/goal-slice.md" \
  && assert "T1/GS3: the shadow J-99 from NOTES is NOT treated as a target — its journey body is digested, not verbatim" "pass" \
  || assert "T1/GS3: shadow J-99 inert ($(grep -c 'csv file downloads' "$GS/goal-slice.md") verbatim hits)" "fail"

# Control: had the OLD whole-document grep still been in force it would have
# passed J-99, and the slice would look the other way round. Prove the fixture
# actually discriminates.
_gs_old="$(grep -m1 -E 'Target journeys:' "$GS/spec.md" 2>/dev/null | sed -E 's/.*Target journeys:\*?\*?[[:space:]]*//' | tr -d ' ')"
run_slice "$_gs_old"
grep -q 'a csv file downloads with a header row' "$GS/goal-slice.md" && ! grep -q 'shows the table header' "$GS/goal-slice.md" \
  && assert "T1/GS4 (control): with the OLD grep value ($_gs_old) the slice would have kept J-99 verbatim and digested J-01 — the fixture discriminates" "pass" \
  || assert "T1/GS4: control fixture discriminates (old='$_gs_old')" "fail"

# Structural: no fresh whole-document target parse remains at the slice site.
# CODE lines only — the block's own comment explains why the grep was removed.
sed -n "${_gs_start:-1},${_gs_end:-1}p" "$RG" | sed 's/#.*//' | grep -qE '\b(grep|sed|awk)\b' \
  && assert "GS5: the pre-evaluator slice block runs no fresh whole-document grep/sed/awk parse" "fail" \
  || assert "GS5: the pre-evaluator slice block runs no fresh whole-document grep/sed/awk parse" "pass"
sed -n "${_gs_start:-1},${_gs_end:-1}p" "$RG" | grep -q '_spec_targets="\$TARGET_JOURNEYS"' \
  && assert "GS6: it reuses the already-validated canonical TARGET_JOURNEYS variable" "pass" \
  || assert "GS6: reuses canonical TARGET_JOURNEYS" "fail"

# The developer's sliced goal view is the other target consumer.
grep -q 'CHAIN_GOAL_TARGET_JOURNEYS+x' "$ENGINE_ROOT/scripts/automation/dev-phase.sh" \
  && assert "GS7: dev-phase.sh prefers the canonical exported CHAIN_GOAL_TARGET_JOURNEYS for its goal slice (is-set test)" "pass" \
  || assert "GS7: dev-phase prefers the canonical export" "fail"
_dp_export=$(grep -n 'export CHAIN_GOAL_TARGET_JOURNEYS' "$RG" | head -1 | cut -d: -f1)
_dp_disp=$(grep -n 'Dispatching FULL pipeline' "$RG" | head -1 | cut -d: -f1)
[[ -n "$_dp_export" && -n "$_dp_disp" && "$_dp_export" -lt "$_dp_disp" ]] \
  && assert "GS7b: the canonical export happens before any executor dispatch, so the child always sees it" "pass" \
  || assert "GS7b: export precedes dispatch (export=$_dp_export dispatch=$_dp_disp)" "fail"
# GS7c (rewritten): the old contract was "standalone dev-phase falls straight
# back to the whole-document grep". That is no longer correct for a Goal Mode
# iteration spec — standalone reaches the canonical accessor first, and the
# legacy parse is reachable only after rc 3 (no metadata section).
grep -q '_spec_field "$SPEC" target_journeys' "$ENGINE_ROOT/scripts/automation/dev-phase.sh" \
  && assert "GS7c: standalone dev-phase asks the canonical accessor for a Goal Mode spec (not the whole-document grep)" "pass" \
  || assert "GS7c: standalone dev-phase uses _spec_field" "fail"
grep -q '_dev_tj_rc" -eq 3' "$ENGINE_ROOT/scripts/automation/dev-phase.sh" \
  && assert "GS7d: dev-phase's whole-document parse is reachable ONLY after accessor rc 3" "pass" \
  || assert "GS7d: legacy parse gated on rc 3" "fail"

# GS8 — the decomposer resume-skip check is a whole-document PRESENCE test, but
# it yields no machine value and the lint blocks such a spec before any dispatch.
{ echo "## Goal Mode Metadata"; echo "- **Mode:** next"; echo "- **Target journeys:** J-01"
  echo "- **Work kind:** implementation"; echo; echo "## NOTES"; echo "- **Depth:** lean"; echo
  echo "## IN SCOPE"; echo "### Backend"; echo "- [ ] add it"; } > "$SPECS/gs8.md"
add_tail "$SPECS/gs8.md"
_gs8_skip=no
grep -qiE '(\*\*)?Depth:(\*\*)?[[:space:]]*(lean|full|evidence)' "$SPECS/gs8.md" && _gs8_skip=yes
_gs8_depth="$(python3 "$PROBE" field "$SPECS/gs8.md" depth)"
lint "$SPECS/gs8.md"
[[ "$_gs8_skip" == "yes" && -z "$_gs8_depth" && "$LINT_RC" == "1" ]] && has_rule E01 \
  && assert "GS8: the resume-skip presence grep can match prose, but yields NO machine depth and the spec is blocked by E01 before dispatch (fail closed)" "pass" \
  || assert "GS8: prose-only Depth fails closed (skip=$_gs8_skip depth='$_gs8_depth' rc=$LINT_RC)" "fail"
grep -q 'Target journeys: %s' "$RG" && grep -q '"${TARGET_JOURNEYS' "$RG" \
  && assert "GS9: the per-iteration push message reports the canonical TARGET_JOURNEYS variable, not a fresh parse" "pass" \
  || assert "GS9: push message uses the canonical variable" "fail"

# ── Part DP: dev-phase target precedence (canonical, never a shadow) ────────
echo "== DP. dev-phase target precedence"
DP="$WORK/dp"; mkdir -p "$DP"
{ echo "## NOTES"; echo; echo "- **Target journeys:** J-99"; echo
  echo "## Goal Mode Metadata"; echo
  echo "- **Mode:** next"; echo "- **Depth:** lean"; echo "- **Target journeys:** J-01"
  echo "- **Work kind:** implementation"; echo
  echo "## IN SCOPE"; echo "### Backend"; echo "- [ ] add it"; } > "$DP/goal-spec.md"
printf '# Phase 7\n\nTarget journeys: J-05\n' > "$DP/phase-spec.md"
# Extract the REAL precedence block from dev-phase.sh and drive it.
DPH="$ENGINE_ROOT/scripts/automation/dev-phase.sh"
sed -n '/HARD-2: the target list decides/,/^  fi$/p' "$DPH" > "$DP/block.sh"
[[ -s "$DP/block.sh" ]] && grep -q '_dev_tj_rc" -ne 0' "$DP/block.sh" \
  && assert "DP0: the real dev-phase precedence block was extracted (env branch + rc0/rc3/fail-closed)" "pass" \
  || assert "DP0: extract the dev-phase block" "fail"
# dp_run <lib-dir> <spec> <env-mode: set|empty|unset> -> stdout '<rc>|<targets>'
dp_run() {
  ( set +e
    # shellcheck disable=SC1090
    source "$1/common.sh" 2>/dev/null
    SPEC="$2"
    case "$3" in
      set)   export CHAIN_GOAL_TARGET_JOURNEYS="J-01" ;;
      empty) export CHAIN_GOAL_TARGET_JOURNEYS="" ;;
      unset) unset CHAIN_GOAL_TARGET_JOURNEYS ;;
    esac
    # shellcheck disable=SC1090
    . "$DP/block.sh"
    printf '0|%s' "${_dev_targets-}" ) 2>"$DP/err" || printf '%s|' "$?"
}
LIBR="$ENGINE_ROOT/scripts/automation/lib"

_r="$(dp_run "$LIBR" "$DP/goal-spec.md" set)"
[[ "$_r" == "0|J-01" ]] \
  && assert "DP1: engine-exported canonical J-01 is used; the NOTES J-99 has zero influence" "pass" \
  || assert "DP1: exported canonical wins (got '$_r')" "fail"

_r="$(dp_run "$LIBR" "$DP/goal-spec.md" empty)"
[[ "$_r" == "0|" ]] \
  && assert "DP2: an exported EMPTY canonical value is authoritative — J-99 is NOT resurrected by the legacy grep" "pass" \
  || assert "DP2: set-empty is authoritative (got '$_r')" "fail"

_r="$(dp_run "$LIBR" "$DP/goal-spec.md" unset)"
[[ "$_r" == "0|J-01" ]] \
  && assert "DP3: a STANDALONE Goal Mode invocation reaches the canonical accessor and gets J-01, not the shadow J-99" "pass" \
  || assert "DP3: standalone uses the canonical accessor (got '$_r')" "fail"

# rc 2: a crashed accessor on a spec that HAS a metadata section.
DPCR="$DP/crashlib"; mkdir -p "$DPCR"
cp "$LIBR/common.sh" "$DPCR/"
printf '#!/usr/bin/env python3\nimport sys\nsys.exit(2)\n' > "$DPCR/iter_spec.py"
_r="$(dp_run "$DPCR" "$DP/goal-spec.md" unset)"
[[ "$_r" == "78|" ]] \
  && assert "DP4: accessor rc 2 fails closed with the reserved 78 — no developer dispatch, no shadow target" "pass" \
  || assert "DP4: rc2 fails closed with 78 (got '$_r')" "fail"
grep -q 'Refusing to fall back' "$DP/err" && ! grep -q 'J-99' "$DP/err" \
  && assert "DP4b: the refusal is announced and the shadow J-99 appears nowhere in the output" "pass" \
  || assert "DP4b: refusal announced without the shadow" "fail"

_r="$(dp_run "$LIBR" "$DP/phase-spec.md" unset)"
[[ "$_r" == "0|J-05" ]] \
  && assert "DP5: a genuine phase-mode spec with NO metadata section still uses the legacy parse via rc 3 (J-05)" "pass" \
  || assert "DP5: rc3 legacy compatibility preserved (got '$_r')" "fail"

# DP6 — set-empty and unset take DIFFERENT branches, pinned behaviourally.
# With a crashed accessor, SET-empty must still succeed (env branch) while UNSET
# must fail closed (accessor branch). That is only possible if the two are
# distinguished by "is set", not by "is non-empty".
_re="$(dp_run "$DPCR" "$DP/goal-spec.md" empty)"
_ru="$(dp_run "$DPCR" "$DP/goal-spec.md" unset)"
[[ "$_re" == "0|" && "$_ru" == "78|" ]] \
  && assert "DP6: SET-empty takes the environment branch while UNSET reaches _spec_field — the two are distinguished by 'is set', not by 'is non-empty'" "pass" \
  || assert "DP6: set-empty vs unset distinguished (empty='$_re' unset='$_ru')" "fail"
grep -q 'CHAIN_GOAL_TARGET_JOURNEYS+x' "$DPH" \
  && assert "DP6b (structural): the test is the '+x' is-set form, not -n" "pass" \
  || assert "DP6b: is-set test used" "fail"
grep -q 'CHAIN_GOAL_TARGET_JOURNEYS:-' "$DPH" \
  && assert "DP6c: no residual '-n \${CHAIN_GOAL_TARGET_JOURNEYS:-}' non-empty test remains" "fail" \
  || assert "DP6c: no residual non-empty test remains" "pass"

# ── Part R: HARD-1 and HARD-3 boundaries ─────────────────────────────────────
echo "== R. HARD-1 regressions and scope"
python3 "$PROBE" has-implementation-work "$SPECS/iter7.md" >/dev/null 2>&1; r7=$?
python3 "$PROBE" has-implementation-work "$SPECS/evidence.md" >/dev/null 2>&1; r9=$?
python3 "$PROBE" has-implementation-work "$SPECS/does-not-exist.md" >/dev/null 2>&1; rm2=$?
[[ "$r7" == "0" && "$r9" == "1" && "$rm2" == "2" ]] \
  && assert "R1: HARD-1 has-implementation-work is byte-for-byte unchanged (work=0, none=1, unreadable=2)" "pass" \
  || assert "R1: HARD-1 probe semantics unchanged (iter7=$r7 evidence=$r9 missing=$rm2)" "fail"
grep -q 'CHAIN_EVIDENCE_WORK_GUARD' "$RG" && grep -q 'CHAIN_ESCALATE_FORCES_FULL' "$RG" \
  && grep -q 'depth_evidence_refused' "$RG" \
  && assert "R2: the HARD-1 depth guards and their knobs are still wired in run-goal.sh" "pass" \
  || assert "R2: HARD-1 guards still wired" "fail"
grep -q '_review_not_dispatched' "$ENGINE_ROOT/scripts/automation/goal-iter-lean.sh" \
  && grep -qE '^\s*\[\[ "\$\{CHAIN_LEAN_EVIDENCE_ONLY:-false\}" == "true" \]\] \|\| return 1' "$ENGINE_ROOT/scripts/automation/goal-iter-lean.sh" \
  && assert "R3: NOT_DISPATCHED review semantics are unchanged (still evidence-dispatch-gated)" "pass" \
  || assert "R3: _review_not_dispatched unchanged" "fail"
grep -q 'def has_bullet' "$ENGINE_ROOT/scripts/automation/lib/common.sh" \
  && assert "R4: goal_new_fullstack_journey's parser was NOT migrated (no gratuitous consolidation)" "pass" \
  || assert "R4: goal_new_fullstack_journey untouched" "fail"
# Reserved-id bookkeeping comments naming HARD-3 are expected; an actual
# implementation (a knob, a ledger path, a digest) is not.
if grep -hE 'side_effect|side-effects\.json|CHAIN_SIDE_EFFECT|declaration_digest|Side-effect policy' \
     "$PROBE" "$RG" "$ENGINE_ROOT/scripts/automation/lib/artifact_schemas.py" 2>/dev/null \
   | grep -vqiE 'reserved|hard-3'; then
  assert "R5: no HARD-3 side-effect implementation leaked into HARD-2" "fail"
else
  assert "R5: no HARD-3 side-effect implementation leaked into HARD-2" "pass"
fi
python3 -c "
import sys; sys.path.insert(0,'$ENGINE_ROOT/scripts/automation/lib')
import iter_spec
assert 'E06' not in iter_spec._RULE_TEXT, 'E06 is reserved for HARD-3'
assert 'W02' not in iter_spec._RULE_TEXT, 'W02 is reserved for HARD-3'
" 2>/dev/null \
  && assert "R6: rule ids E06/W02 stay RESERVED for HARD-3's side-effect policy" "pass" \
  || assert "R6: E06/W02 reserved for HARD-3" "fail"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
