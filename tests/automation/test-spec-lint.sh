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
    esac
    echo "- **Work kind:** verify-only"
    echo "- **Required-still-passing journeys:** J-02"
    echo; echo "## IN SCOPE"; echo "### Backend"
    if [[ "$kind" == "baselinework" ]]; then echo "- [ ] add the endpoint"; else echo "- none"; fi
    echo "### Frontend"; echo "- N/A"
    echo; echo "## OUT OF SCOPE"; echo "- x"
    echo; echo "## DEFINITION OF DONE"; echo "- [ ] done"
    echo; echo "## TESTING REQUIREMENTS"; echo "- TC-1: given x, when y, then z"
  } > "$out"
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
_bold=$(grep -n 'TARGET_JOURNEYS=\$(grep -m1' "$RG" | head -1 | cut -d: -f1)
_plain=$(grep -n "HARD-2: plain-form fallback" "$RG" | head -1 | cut -d: -f1)
_boldpat=$(grep -c 'Target journeys:\\\*\\\*' "$RG" 2>/dev/null || true)
[[ -n "$_bold" && -n "$_plain" && "$_bold" -lt "$_plain" ]] \
  && assert "W4: the bold 'Target journeys' grep still runs FIRST; the plain fallback is second" "pass" \
  || assert "W4: bold-before-plain target precedence (bold=$_bold plain=$_plain)" "fail"
grep -q 'Work kind' "$ENGINE_ROOT/agents/goal-decomposer/body.md" \
  && grep -q 'Spec lint (deterministic — HARD-2)' "$ENGINE_ROOT/agents/goal-decomposer/body.md" \
  && assert "W5: the decomposer contract documents Work kind and the spec-lint rules" "pass" \
  || assert "W5: decomposer contract updated" "fail"
python3 "$ENGINE_ROOT/scripts/automation/sync-cli-assets.py" --cli claude --check >/dev/null 2>&1 \
  && assert "W6: sync-cli-assets --check is clean (generated mirrors match the neutral source)" "pass" \
  || assert "W6: mirror drift check clean" "fail"

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
