#!/usr/bin/env bash
# test-full-executor-quota.sh — a Goal Mode FULL executor (run-phase.sh) that
# exits QUOTA_EXHAUSTED_EXIT_CODE has NOT completed its iteration, and the quota
# handling below the engine has already ended. Contract under test:
#   - lower layers own automatic quota waiting: claude_with_quota_retry (bounded
#     by CHAIN_CLAUDE_MAX_QUOTA_RETRIES; long-duration limits and
#     CHAIN_DISABLE_AUTO_WAIT fail fast) and run-phase.sh's _run_step / step loops;
#   - when the rc still reaches run-goal.sh, Goal Mode neither waits nor
#     re-dispatches: it stops resumably BEFORE the coherence auditor and the
#     goal-evaluator (ABORTED, halt QUOTA_EXHAUSTED, exit 75) with current_iter
#     unchanged, nothing pushed and the run-phase checkpoint kept, and --resume
#     re-runs the SAME iteration from that checkpoint.
#
# The rc path is REAL end to end; only the model, the step leaves and the quota
# wait primitives are stubbed:
#   stub `claude` prints a usage-limit message
#     → REAL lib/quota-retry.sh (classification, retry budget, give-up decision)
#     → qa-phase.sh / demo-phase.sh stubs that dispatch through
#       claude_with_quota_retry
#     → REAL lib/parallel.sh fanout or REAL _run_step → REAL run-phase.sh
#     → REAL run-goal.sh.
# In the sandbox copy of lib/quota-retry.sh the four primitives that sleep or
# touch the machine-global sentinel are instant logging stubs: the sentinel is
# never read, written or cleared, and every quota wait is recorded with the
# function and script that performed it (STUB_WAIT_LOG) — who owns a wait is
# asserted without anyone sleeping.
#
# Sections (offline; stub claude, stub step scripts, dummy HTTP services):
#   W  wiring: the named constant; the quota check lives in the FULL dispatch
#      branch before the coherence section; run-goal.sh uses no quota wait
#      primitive; no doc or comment still describes an engine-level quota wait
#   A  fanout quota propagation (iteration 1): one run-phase.sh dispatch, no
#      engine wait, no coherence auditor / evaluator / eval artifact, current_iter
#      unchanged, nothing pushed, ABORTED + QUOTA_EXHAUSTED + exit 75, checkpoint
#      review_passed, resume instructions printed
#                               (RED on e3340e7: the engine waited and re-dispatched)
#   B  quota cleared → --resume: the SAME iteration resumes from review_passed
#      without redoing plan/dev/review; closure, then coherence → evaluator, then
#      the advance and the push
#   C  CHAIN_CLAUDE_MAX_QUOTA_RETRIES=1 spent by the REAL wrapper (two attempts,
#      one wrapper wait): Goal Mode starts no fresh executor with a fresh retry
#      budget — the quota a new budget would have consumed is left untouched
#   D  long-duration (monthly/org) limit: the wrapper fails fast without waiting
#      despite budget left; Goal Mode stops at once — no fallback wait, no
#      re-dispatch
#   E  already-waited rc 75: run-phase.sh's _run_step waits out the demo step's
#      quota (exactly one logged wait), then exits 75; the engine adds no second
#      wait
#   O  the Step 1 orchestrator's own quota exit reaches the same stop, with the
#      un-checkpointed plan step still owed
#   F  CHAIN_DISABLE_AUTO_WAIT=true: one dispatch, no wait, resumable ABORTED,
#      exit 75, nothing evaluated, advanced or pushed
#   G  reserved halts keep precedence: Branch UI exiting 79 / 78 / 70 while
#      Branch QA hits quota reaches the existing top-level halt, not a quota stop
#   H  lean characterization: a lean developer quota exit (goal-iter-lean.sh →
#      75) is untouched by the FULL arm — no quota stop, no wait; the engine's
#      pre-existing lean behaviour (it proceeds to the evaluator) is PINNED, not
#      endorsed (recorded debt, out of scope)
#
# shellcheck disable=SC2015,SC2016,SC2034,SC2329
# (SC2015: assert's pass arm always returns 0; SC2016: generated stub bodies are
# single-quoted on purpose; SC2034/SC2329: harness vars and trap-invoked cleanup.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
QR_LIB="$ENGINE_ROOT/scripts/automation/lib/quota-retry.sh"
# The quota code comes from its single definition.
RC75="$(bash -c 'source "$1" >/dev/null 2>&1; printf %s "${QUOTA_EXHAUSTED_EXIT_CODE:-}"' _ "$QR_LIB")"
[[ "$RC75" =~ ^[0-9]+$ ]] || { echo "cannot read QUOTA_EXHAUSTED_EXIT_CODE from $QR_LIB" >&2; exit 1; }
RC79="${BROWSER_EVIDENCE_GATE_UNAVAILABLE_EXIT_CODE:-79}"
RC78="${SPEC_FIELD_UNAVAILABLE_EXIT_CODE:-78}"
RC70="${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}"
# Hermetic: an inherited fail-fast knob or agent tag (e.g. evals run from inside
# an agent) would change what the engine does or how the stub claude plays roles.
unset CHAIN_DISABLE_AUTO_WAIT CHAIN_CURRENT_AGENT

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}

WORK="$(mktemp -d)"
DUMMY_PIDS=()
BE_PORT=48451
FE_PORT=48452
cleanup() {
  for p in ${DUMMY_PIDS[@]+"${DUMMY_PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done
  fuser -k "${BE_PORT}/tcp" "${FE_PORT}/tcp" 2>/dev/null || true
  pkill -KILL -f "$WORK/" 2>/dev/null || true
  if [[ -n "${KEEP_WORK:-}" ]]; then echo "KEEP_WORK set — sandbox kept at $WORK"; return 0; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

SRV_DIR="$WORK/srv"; mkdir -p "$SRV_DIR"
start_dummies() {
  local p i
  for p in "$BE_PORT" "$FE_PORT"; do
    if ! curl -s -o /dev/null "http://localhost:${p}/"; then
      ( cd "$SRV_DIR" && exec python3 -m http.server "$p" ) >/dev/null 2>&1 &
      DUMMY_PIDS+=("$!")
      disown "$!"   # run-phase's kill_phase_servers reaps these; no job notices
    fi
  done
  for p in "$BE_PORT" "$FE_PORT"; do
    for i in $(seq 1 50); do curl -s -o /dev/null "http://localhost:${p}/" && break; sleep 0.1; done
  done
}

# ── Stub claude: plays every agent; paths come from the dispatch prompts ─────
STUB_DIR="$WORK/bin"; mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "stub 0.0"; exit 0; }
agent="${CHAIN_CURRENT_AGENT:-unknown}"
iter="${GOAL_ITER_INDEX:-x}"
prompt="$*"
echo "$agent $iter" >> "$CANARY"
field() { printf '%s\n' "$prompt" | sed -n "s|^$1||p" | head -n1; }
# Agent-scoped quota wall for one iteration: each refusal spends one unit of the
# count file, which disappears when the quota "resets". STUB_QUOTA_MSG overrides
# the refusal text (e.g. a long-duration monthly/org limit).
if [[ -n "${STUB_QUOTA_AGENT:-}" && "$agent" == "$STUB_QUOTA_AGENT" && "$iter" == "${STUB_QUOTA_ITER:-}" \
      && -n "${STUB_QUOTA_COUNT:-}" && -f "$STUB_QUOTA_COUNT" ]]; then
  n="$(cat "$STUB_QUOTA_COUNT")"
  if [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]]; then
    n=$((n - 1))
    if [[ "$n" -gt 0 ]]; then echo "$n" > "$STUB_QUOTA_COUNT"; else rm -f "$STUB_QUOTA_COUNT"; fi
    echo "quota $agent $iter" >> "$CANARY.quota"
    msg="${STUB_QUOTA_MSG:-}"   # (no apostrophe inside ${…:-…}: bash would read it as an open quote)
    [[ -n "$msg" ]] || msg="You've hit your usage limit · resets 3am (UTC)"
    echo "$msg"
    exit 1
  fi
fi
case "$agent" in
  goal-decomposer)
    out="$(field 'Write the iteration spec to: ')"; mode="$(field 'Mode: ')"; [[ -n "$out" ]] || exit 64
    depth="${STUB_SPEC_DEPTH:-full}"
    mkdir -p "$(dirname "$out")"
    {
      echo "# Iteration spec (full-executor quota test)"; echo
      echo "## Goal Mode Metadata"; echo
      echo "- **Mode:** $mode"
      echo "- **Depth:** $depth"
      [[ "$depth" == "full" ]] && echo "- **Full trigger:** 1 - new journey"
      echo "- **Target journeys:** J-01"
      echo "- **Work kind:** verify-only"
      echo "- **Required-still-passing journeys:** none — test fixture"
      echo; echo "## IN SCOPE"; echo "### Backend"; echo "- none"; echo "### Frontend"; echo "- N/A"
      echo; echo "## OUT OF SCOPE"; echo "- x"
      echo; echo "## DEFINITION OF DONE"; echo "- [ ] done"
      echo; echo "## TESTING REQUIREMENTS"
      echo "- TC-1: given the page, when opened, then it loads"
      echo "- TC-2: given the page, when reloaded, then it loads"
      echo "- TC-3: given the page, when idle, then nothing changes"
    } > "$out"
    bp="$(printf '%s\n' "$prompt" | sed -n 's|.*draft the coherence blueprint to \([^ ]*\) per .*|\1|p' | head -n1)"
    if [[ -n "$bp" ]]; then
      mkdir -p "$(dirname "$bp")"
      printf '# Blueprint\n\n## Information Architecture\n- / (home)\n\n## Data Contract\n- none\n' > "$bp"
    fi
    exit 0 ;;
  orchestrator)
    out="$(field 'Write a concise execution plan to: ')"; [[ -n "$out" ]] || exit 64
    mkdir -p "$(dirname "$out")"; printf '# Execution Plan (stub)\n\nFrontend Present: yes\n' > "$out"; exit 0 ;;
  qa)
    out="$(field 'Write your QA report to: ')"; [[ -n "$out" ]] || exit 64
    mkdir -p "$(dirname "$out")"; printf '**Verdict:** PASS\n\nStub QA.\n' > "$out"; exit 0 ;;
  developer)
    out="$(field '- Write dev handoff to: ')"; [[ -n "$out" ]] || exit 64
    mkdir -p "$(dirname "$out")"; printf 'handoff (stub)\n' > "$out"; exit 0 ;;
  reviewer)
    out="$(field 'Write your review report to: ')"; [[ -n "$out" ]] || exit 64
    mkdir -p "$(dirname "$out")"; printf '**Verdict:** PASS\n\nStub review.\n' > "$out"; exit 0 ;;
  coherence-auditor)
    out="$(field 'Write your verdict to: ')"; [[ -n "$out" ]] || exit 64
    mkdir -p "$(dirname "$out")"; printf '**Verdict:** COHERENCE-PASS\n\n(stub audit)\n' > "$out"; exit 0 ;;
  goal-evaluator)
    ev="$(field 'Write your verdict to: ')"; name="$(field 'Iter name: ')"
    jh="$(printf '%s\n' "$prompt" | sed -n 's|^  Journey history: \([^ ]*\)  <--.*|\1|p' | head -n1)"
    el="$(printf '%s\n' "$prompt" | sed -n 's|^  Evaluator log: \([^ ]*\)  <--.*|\1|p' | head -n1)"
    [[ -n "$ev" && -n "$jh" && -n "$el" ]] || exit 64
    mkdir -p "$(dirname "$ev")" "$(dirname "$jh")" "$(dirname "$el")"
    printf '**Verdict:** CONTINUE\n**Depth Recommendation For Next Iteration:** full\n\n## Summary\n\nStub evaluation of %s.\n' "$name" > "$ev"
    printf '{"journeys":{"J-01":{"id":"J-01","name":"open the page","status":"failing","last_verified_iter":"%s","last_passing_iter":null,"first_seen_iter":"%s"}},"anti_goal_violations":[],"updated_at":"2026-09-15T00:00:00Z"}\n' "$name" "$name" > "$jh"
    printf '## %s\n\n**Verdict:** CONTINUE\n' "$name" >> "$el"
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$STUB_DIR/claude"

# ── Engine sandbox: the REAL engine + run-phase.sh, stub step leaves ─────────
ESBX="$WORK/engine"; mkdir -p "$ESBX"
cp -r "$ENGINE_ROOT/scripts" "$ENGINE_ROOT/config" "$ESBX/"
mkdir -p "$ESBX/docs/phases" "$ESBX/reports" "$ESBX/src" "$ESBX/.claude/agents"
touch "$ESBX/.claude/agents/developer.md"
git init -q "$ESBX"
git -C "$ESBX" config user.email t@t; git -C "$ESBX" config user.name t
echo "print('v1')" > "$ESBX/src/app.py"
cat > "$ESBX/docs/goal.md" <<'EOF'
# Goal

Tiny single-page app (full-executor quota fixture).

## Must-have user journeys

- **J-01: Open the page**
  - Steps: open /
  - Acceptance: page loads

## Anti-goals

- no paid SaaS
EOF

# Sandbox-only quota wait primitives: instant, attributable, sentinel-free. Later
# definitions win, so the REAL wrapper, _run_step and run-goal.sh call these.
cat >> "$ESBX/scripts/automation/lib/quota-retry.sh" <<'EOF'

# ── TEST FIXTURE (test-full-executor-quota.sh sandbox copy only) ─────────────
_quota_check_sentinel() { return 1; }
_quota_write_sentinel() { echo "write_sentinel until=$1 by=${FUNCNAME[1]:-?} script=$(basename "$0")" >> "${STUB_WAIT_LOG:-/dev/null}"; }
_quota_clear_sentinel() { :; }
_sleep_until_epoch() { echo "wait until=$1 now=$(date +%s) by=${FUNCNAME[1]:-?} script=$(basename "$0")" >> "${STUB_WAIT_LOG:-/dev/null}"; return 0; }
EOF

write_stub() {  # <script> <verdict-or-""> [repo-relative artifact; may reference ${P}]...
  local name="$1" verdict="$2" rel; shift 2
  {
    echo '#!/usr/bin/env bash'
    echo 'R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; P="$1"'
    printf 'echo "%s ${P##*-iter-}" >> "$CANARY"\n' "$name"
    for rel in "$@"; do
      printf 'mkdir -p "$(dirname "$R/%s")"\n' "$rel"
      printf 'printf "# stub %s\\n\\ncontent\\n" > "$R/%s"\n' "$name" "$rel"
      [[ -n "$verdict" ]] && printf 'printf "**Verdict:** %s\\n" >> "$R/%s"\n' "$verdict" "$rel"
    done
    echo 'exit 0'
  } > "$ESBX/scripts/automation/$name"
}
write_stub generate-test-plan.sh   ""                   'reports/qa/${P}-test-plan.md'
write_stub dev-phase.sh            ""                   'docs/handoffs/${P}-dev.md'
write_stub review-phase.sh         "PASS"               'reports/reviews/${P}-review.md'
write_stub ui-impact-phase.sh      ""                   'reports/phase-${P}-user-visible-changes.md' 'reports/phase-${P}-ui-surface-map.md' 'reports/phase-${P}-ui-test-plan.md' 'reports/phase-${P}-what-to-click.md'
write_stub ui-test-design-phase.sh ""                   'reports/phase-${P}-ui-test-plan.md' 'reports/phase-${P}-what-to-click.md'
write_stub ux-regression-phase.sh  "UX-REGRESSION-PASS" 'reports/phase-${P}-ux-regression.md'
write_stub phase-audit.sh          "PASS"               'docs/handoffs/${P}-audit.md'
write_stub phase-closure-check.sh  "CLOSURE-PASS"       'reports/phase-${P}-closure-verdict.md'
# Branch UI's browser step: a PASS results file, or a reserved exit (section G).
cat > "$ESBX/scripts/automation/browser-qa-phase.sh" <<'EOF'
#!/usr/bin/env bash
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; P="$1"
echo "browser-qa-phase.sh ${P##*-iter-}" >> "$CANARY"
if [[ -n "${STUB_BQA_EXIT:-}" ]]; then echo "[browser-qa stub] reserved exit $STUB_BQA_EXIT"; exit "$STUB_BQA_EXIT"; fi
mkdir -p "$R/reports"
printf '**Browser QA Verdict:** PASS\n\n| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n|---|---|---|---|---|---|---|---|\n| UT-J-01 | open page | journey | P1 | loads | ok | PASS | none |\n' \
  > "$R/reports/phase-${P}-ui-test-results.md"
exit 0
EOF
# Branch QA: dispatches the QA agent through the REAL quota wrapper.
cat > "$ESBX/scripts/automation/qa-phase.sh" <<'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/telemetry.sh"
P="$1"
echo "qa-phase.sh ${P##*-iter-}" >> "$CANARY"
mkdir -p "$REPO_ROOT/reports/qa"
record_agent_invocation_start qa
rc=0
claude_with_quota_retry -p "You are the QA agent (stub).

Write your QA report to: $REPO_ROOT/reports/qa/${P}-qa.md" || rc=$?
record_agent_invocation_end qa "$CHAIN_AGENT_START_EPOCH" "$rc"
exit "$rc"
EOF
# Demo step: a showcase no-op, or (section E) a demo-narrator dispatch through the
# REAL quota wrapper, so its refusal reaches run-phase.sh's _run_step.
cat > "$ESBX/scripts/automation/demo-phase.sh" <<'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P="$1"
echo "demo-phase.sh ${P##*-iter-}" >> "$CANARY"
[[ "${STUB_QUOTA_AGENT:-}" == "demo-narrator" ]] || exit 0
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/telemetry.sh"
record_agent_invocation_start demo-narrator
rc=0
claude_with_quota_retry -p "You are the demo-narrator agent (stub) for $P." || rc=$?
record_agent_invocation_end demo-narrator "$CHAIN_AGENT_START_EPOCH" "$rc"
exit "$rc"
EOF
for _f in "$STUB_DIR/claude" "$ESBX/scripts/automation/lib/quota-retry.sh" "$ESBX/scripts/automation/qa-phase.sh" "$ESBX/scripts/automation/demo-phase.sh" "$ESBX/scripts/automation/browser-qa-phase.sh"; do
  bash -n "$_f" || { echo "harness error: generated fixture $_f does not parse" >&2; exit 1; }
done
git -C "$ESBX" add -A; git -C "$ESBX" commit -qm base
REMOTE="$WORK/remote.git"; git init -q --bare "$REMOTE"; git -C "$ESBX" remote add origin "$REMOTE"

TMPROOT="$WORK/tmproot"; mkdir -p "$TMPROOT"
ENGINE_ENV=(
  CHAIN_DOCTOR=false CHAIN_GOAL_LINT=false CHAIN_SESSION_RETRO=false
  CHAIN_TMP_ROOT="$TMPROOT" CHAIN_TMP_LEGACY_ROOTS="" CHAIN_DISABLE_TRACE=true
  CHAIN_BACKEND_PORT="$BE_PORT" CHAIN_FRONTEND_PORT="$FE_PORT" CHAIN_BACKEND_HEALTH_URL="http://localhost:${BE_PORT}/"
  CHAIN_START_BACKEND_CMD="python3 -m http.server $BE_PORT --directory $SRV_DIR"
  CHAIN_START_FRONTEND_CMD="python3 -m http.server $FE_PORT --directory $SRV_DIR"
  CHAIN_SKIP_GITHUB_PREFLIGHT=true CHAIN_KILL_GRACE_SECONDS=1
  CHAIN_DEPTH_ARBITER=false CHAIN_ASYNC_SHOWCASE=false CHAIN_ZERO_CHANGE_SKIPS=false
  CHAIN_CLAUDE_MAX_QUOTA_RETRIES=0 CHAIN_CLAUDE_FALLBACK_SLEEP_SECONDS=3600
)

eng_paths() {  # <sid> <fresh|resume>
  ENG_SID="$1"; ENG_SESSION="$ESBX/runs/goal-session-$1"; ENG_LOG="$WORK/eng-$1.log"
  CANARY="$WORK/canary-$1.log"; WAITS="$WORK/waits-$1.log"; export CANARY
  local f
  if [[ "$2" == "fresh" ]]; then
    rm -rf "$ENG_SESSION"
    for f in "$CANARY" "$CANARY.quota" "$ENG_LOG" "$WAITS"; do : > "$f"; done
  else
    for f in "$CANARY" "$CANARY.quota" "$ENG_LOG" "$WAITS"; do echo "=== resume ===" >> "$f"; done
  fi
}
run_engine() {  # <sid> <fresh|resume> <max-iter> [ENV=val ...] → ENG_RC
  local sid="$1" mode="$2" max_iter="$3"; shift 3
  eng_paths "$sid" "$mode"
  local -a args=(--session-id "$sid" --max-iter "$max_iter")
  if [[ "$mode" == "resume" ]]; then args+=(--resume); fi
  ENG_RC=0; start_dummies
  ( cd "$ESBX" && exec env PATH="$STUB_DIR:$PATH" CANARY="$CANARY" STUB_WAIT_LOG="$WAITS" STUB_REMOTE="$REMOTE" \
      "${ENGINE_ENV[@]}" "$@" timeout 300 bash scripts/automation/run-goal.sh "${args[@]}" ) >> "$ENG_LOG" 2>&1 || ENG_RC=$?
}

sess() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("" if v is None else v)' "$ENG_SESSION/session.json" "$1" 2>/dev/null || echo "?"; }
phase_step() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("current_step",""))' "$ESBX/runs/$1/status.json" 2>/dev/null || echo "?"; }
n_line() { local n; n="$(grep -cxF -- "$1" "${2:-$CANARY}" 2>/dev/null || true)"; echo "${n:-0}"; }   # exact lines
n_grep() { local n; n="$(grep -c -- "$1" "$2" 2>/dev/null || true)"; echo "${n:-0}"; }
n_fixed() { local n; n="$(grep -cF -- "$1" "$2" 2>/dev/null || true)"; echo "${n:-0}"; }
first_at() { awk -v l="$1" '$0 == l { print NR; exit }' "${2:-$CANARY}"; }
last_at()  { awk -v l="$1" '$0 == l { n = NR } END { if (n) print n }' "${2:-$CANARY}"; }
line_of()  { grep -nF -- "$1" "$2" 2>/dev/null | head -n1 | cut -d: -f1 || true; }
pushed_iter() { local n; n="$(git -C "$REMOTE" log --format=%s "goal/$1" 2>/dev/null | grep -c "^goal($1): iter $2 " || true)"; echo "${n:-0}"; }
n_waits() { local n; n="$(grep -c -- "^wait .*${2:-}" "$1" 2>/dev/null || true)"; echo "${n:-0}"; }   # recorded quota waits
dispatches() { n_grep "^\[run-phase\]   Phase: $1\$" "$2"; }   # run-phase.sh runs of <phase> in <log>
tele() {  # <event> <iter> [field] → count, or the field's values space-joined
  python3 - "$ENG_SESSION/telemetry.jsonl" "$@" <<'PY'
import json, sys
path, ev, it = sys.argv[1], sys.argv[2], sys.argv[3]
field = sys.argv[4] if len(sys.argv) > 4 else ""
rows = []
try:
    with open(path) as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("event") == ev and str(d.get("iter")) == it:
                rows.append(d)
except OSError:
    pass
print(" ".join(str(r.get(field, "")) for r in rows) if field else len(rows))
PY
}
quota_halt() {  # <iter> — the engine recorded a QUOTA_EXHAUSTED halt at the executor for that iteration
  [[ " $(tele halt "$1" reason) " == *" QUOTA_EXHAUSTED "* && " $(tele halt "$1" detected_at_step) " == *" executor "* ]]
}
segment_after_resume() { awk 'f; $0 == "=== resume ===" { f = 1 }' "$1"; }

echo "=== test-full-executor-quota.sh ==="

# ══ W. wiring ═════════════════════════════════════════════════════════════════
RG="$ENGINE_ROOT/scripts/automation/run-goal.sh"; RP="$ENGINE_ROOT/scripts/automation/run-phase.sh"
PAR="$ENGINE_ROOT/scripts/automation/lib/parallel.sh"
grep -q 'QUOTA_EXHAUSTED_EXIT_CODE' "$RG" && ! grep -qE '(-eq|-ne|==|!=)[[:space:]]*"?75"?([^0-9]|$)' "$RG" \
  && assert "W1: run-goal.sh keys the FULL executor quota stop on QUOTA_EXHAUSTED_EXIT_CODE (no bare 75)" pass \
  || assert "W1: run-goal.sh keys the FULL executor quota stop on QUOTA_EXHAUSTED_EXIT_CODE (no bare 75)" fail
_full="$(line_of 'bash "$SCRIPT_DIR/run-phase.sh"' "$RG")"
_q="$(awk -v f="${_full:-999999}" 'NR > f && /QUOTA_EXHAUSTED_EXIT_CODE/ { print NR; exit }' "$RG")"
_lean="$(awk -v f="${_full:-999999}" 'NR > f && /bash "\$SCRIPT_DIR\/goal-iter-lean.sh"/ { print NR; exit }' "$RG")"
_coh="$(line_of '3b. Coherence auditor' "$RG")"
[[ -n "$_full" && -n "$_q" && -n "$_lean" && -n "$_coh" ]] && (( _full < _q && _q < _lean && _lean < _coh )) \
  && assert "W2: the quota check sits in the FULL dispatch branch (after run-phase.sh, before the lean fallback) and before the coherence auditor / evaluator section" pass \
  || assert "W2: quota check placement (full=${_full:-none} quota=${_q:-none} lean fallback=${_lean:-none} coherence=${_coh:-none})" fail
_arm="$(awk '/-eq "\$\{QUOTA_EXHAUSTED_EXIT_CODE:-75\}" \]\]; then/ { f = 1 } f { print } f && /^      fi$/ { exit }' "$RG")"
! grep -qE '_sleep_until_epoch|_quota_check_sentinel|_quota_write_sentinel|_quota_clear_sentinel|_quota_pause_begin|_quota_pause_end|_full_executor_quota_wait' "$RG" \
   && grep -qF 'exit "$_exec_rc"' <<<"$_arm" && ! grep -qE '(^|[^_[:alnum:]])(sleep|while|until)([^_[:alnum:]]|$)|run-phase\.sh"' <<<"$_arm" \
  && assert "W3: run-goal.sh owns no quota wait — no wait/sentinel/pause primitive anywhere, and the FULL quota arm exits without sleeping, looping or re-dispatching" pass \
  || assert "W3: engine-level quota wait remains (primitives: $(grep -noE '_sleep_until_epoch|_quota_check_sentinel|_quota_write_sentinel|_quota_clear_sentinel|_quota_pause_begin|_quota_pause_end|_full_executor_quota_wait' "$RG" | tr '\n' ' '); arm lines: $(wc -l <<<"$_arm"))" fail
_obsolete='run-goal\.sh waits for the reset|waits for the quota reset and re-dispatches|the engine waits the (same )?way|FULL-executor wait|full-pipeline` for the engine|_full_executor_quota_wait|quota auto-resume'
_docs=("$PAR" "$RP" "$RG" "$ENGINE_ROOT/.claude/architecture/pipeline.md" "$ENGINE_ROOT/.claude/architecture/goal-mode.md" "$ENGINE_ROOT/docs/goal-mode-telemetry.md")
! grep -qE "$_obsolete" "${_docs[@]}" && ! grep -q 'no FULL-executor 75 arm' "$PAR" \
  && assert "W4: no doc or comment it touches still describes an engine-level quota wait, re-dispatch, full-pipeline quota pause or quota auto-resume" pass \
  || assert "W4: obsolete engine-wait wording remains: $(grep -noE "$_obsolete|no FULL-executor 75 arm" "${_docs[@]}" 2>/dev/null | sed "s|$ENGINE_ROOT/||" | tr '\n' ' ')" fail

# ══ A. fanout quota propagation through the REAL run-phase.sh ════════════════
echo "── A: the post-dev fanout propagates quota exhaustion at iteration 1 ──"
printf '2\n' > "$WORK/a-count"
run_engine fa fresh 2 STUB_QUOTA_AGENT=qa STUB_QUOTA_ITER=1 STUB_QUOTA_COUNT="$WORK/a-count"
AP="goal-fa-iter-1"; A_RC=$ENG_RC
[[ "$(n_line 'qa-phase.sh 0')" == "1" && "$(n_line 'goal-evaluator 0')" == "1" && "$(pushed_iter fa 0)" == "1" ]] \
  && assert "A0: (seam) iteration 0 ran the FULL pipeline once, healthy — evaluated and pushed" pass \
  || { assert "A0: (seam) iteration 0 healthy (qa=$(n_line 'qa-phase.sh 0') eval=$(n_line 'goal-evaluator 0') pushed=$(pushed_iter fa 0) engine rc=$A_RC)" fail; tail -n 30 "$ENG_LOG"; }
[[ "$(n_line 'quota qa 1' "$CANARY.quota")" == "1" && "$(n_fixed "Fanout (Step 4-7/11) hit quota (exit $RC75)" "$ENG_LOG")" == "1" ]] && grep -qF 'Max quota retries (0) reached' "$ENG_LOG" \
  && assert "A1: (seam) the REAL chain delivered $RC75 to Goal Mode — the QA wrapper gave up, the fanout and run-phase.sh exited $RC75" pass \
  || assert "A1: (seam) rc path (QA refusals=$(n_line 'quota qa 1' "$CANARY.quota") fanout quota exits=$(n_fixed "Fanout (Step 4-7/11) hit quota (exit $RC75)" "$ENG_LOG"))" fail
[[ "$(dispatches "$AP" "$ENG_LOG")" == "1" && "$(n_line 'qa-phase.sh 1')" == "1" && "$(n_waits "$WAITS")" == "0" && "$(tele quota_pause_start 1)" == "0" ]] \
  && assert "A2: exactly one FULL run-phase.sh dispatch — no engine-level quota wait and no automatic re-dispatch" pass \
  || assert "A2: run-phase dispatches=$(dispatches "$AP" "$ENG_LOG") QA attempts=$(n_line 'qa-phase.sh 1') waits=$(n_waits "$WAITS") pauses=$(tele quota_pause_start 1) [$(tr '\n' '|' < "$WAITS")]" fail
[[ "$(n_line 'coherence-auditor 1')" == "0" && "$(n_line 'goal-evaluator 1')" == "0" \
   && ! -e "$ENG_SESSION/iter-1/eval.md" && ! -e "$ENG_SESSION/iter-1/.evaluated" && ! -e "$ENG_SESSION/iter-1/coherence.md" ]] \
  && assert "A3: no coherence auditor, no goal-evaluator, and no eval.md / .evaluated / coherence.md for the unfinished iteration" pass \
  || assert "A3: downstream ran (coh=$(n_line 'coherence-auditor 1') eval=$(n_line 'goal-evaluator 1') eval.md=$([[ -e "$ENG_SESSION/iter-1/eval.md" ]] && echo present || echo absent))" fail
[[ "$(sess current_iter)" == "1" && "$(sess last_verdict)" == "CONTINUE" && "$(pushed_iter fa 1)" == "0" && "$(tele iter_end 1)" == "0" ]] \
  && assert "A4: current_iter unchanged (1), last_verdict still iteration 0's, iteration 1 not pushed, no iter_end" pass \
  || assert "A4: state (iter=$(sess current_iter) verdict=$(sess last_verdict) pushed=$(pushed_iter fa 1) iter_end=$(tele iter_end 1))" fail
[[ "$A_RC" -eq "$RC75" && "$(sess status)" == "ABORTED" ]] && quota_halt 1 \
   && grep -qF '/goal-resume fa' "$ENG_LOG" && grep -qF -- '--resume --session-id fa' "$ENG_LOG" \
  && assert "A5: resumable stop — session ABORTED, halt QUOTA_EXHAUSTED at the executor, engine exit $RC75, resume instructions printed" pass \
  || assert "A5: stop (rc=$A_RC status=$(sess status) halt reasons='$(tele halt 1 reason)')" fail
[[ "$(phase_step "$AP")" == "review_passed" && "$(cat "$WORK/a-count" 2>/dev/null)" == "1" ]] \
  && assert "A6: run-phase.sh's checkpoint from before the interruption survives (review_passed); no automatic retry spent the remaining quota" pass \
  || assert "A6: checkpoint=$(phase_step "$AP") remaining quota=$(cat "$WORK/a-count" 2>/dev/null || echo spent)" fail

# ══ B. quota cleared → --resume continues the SAME iteration ═════════════════
echo "── B: quota clears; --resume ──"
rm -f "$WORK/a-count"
run_engine fa resume 2
segment_after_resume "$CANARY" > "$WORK/canary-fa-resume.log"; BC="$WORK/canary-fa-resume.log"
segment_after_resume "$ENG_LOG" > "$WORK/eng-fa-resume.log"; BL="$WORK/eng-fa-resume.log"
grep -qF "Resuming session 'fa' from iter 1" "$BL" && grep -qF 'RESUMING from checkpoint: review_passed' "$BL" \
   && [[ "$(dispatches "$AP" "$BL")" == "1" && "$(n_line 'orchestrator 1' "$BC")" == "0" && "$(n_line 'dev-phase.sh 1' "$BC")" == "0" \
         && "$(n_line 'review-phase.sh 1' "$BC")" == "0" && "$(n_line 'qa-phase.sh 1' "$BC")" == "1" ]] \
  && assert "B1: --resume re-ran the SAME iteration (1, $AP) from run-phase's review_passed checkpoint — plan/dev/review not redone, the fanout re-ran" pass \
  || assert "B1: resume path (dispatches=$(dispatches "$AP" "$BL") orchestrator=$(n_line 'orchestrator 1' "$BC") dev=$(n_line 'dev-phase.sh 1' "$BC") review=$(n_line 'review-phase.sh 1' "$BC") qa=$(n_line 'qa-phase.sh 1' "$BC"))" fail
_cl="$(first_at 'phase-closure-check.sh 1' "$BC")"; _co="$(first_at 'coherence-auditor 1' "$BC")"; _ev="$(first_at 'goal-evaluator 1' "$BC")"
[[ -n "$_cl" && -n "$_co" && -n "$_ev" && "$(n_line 'coherence-auditor 1' "$BC")" == "1" && "$(n_line 'goal-evaluator 1' "$BC")" == "1" \
   && "$(phase_step "$AP")" == "closure_passed" ]] && (( _cl < _co && _co < _ev )) \
  && assert "B2: the executor completed (closure_passed); only then did the coherence auditor and the evaluator run, once each" pass \
  || assert "B2: ordering (closure=${_cl:-none} coherence=${_co:-none} evaluator=${_ev:-none} step=$(phase_step "$AP"))" fail
_evl="$(line_of 'Step 3: goal-evaluator' "$BL")"; _pul="$(line_of 'push-per-iter: pushed iter 1' "$BL")"
[[ "$(sess current_iter)" == "2" && "$(sess last_verdict)" == "CONTINUE" && "$(sess status)" == "BUDGET_EXHAUSTED" \
   && "$(pushed_iter fa 1)" == "1" && -f "$ENG_SESSION/iter-1/.evaluated" && -n "$_evl" && -n "$_pul" ]] && (( _evl < _pul )) \
  && assert "B3: only after that evaluation was current_iter advanced (2) and iteration 1 pushed — once" pass \
  || assert "B3: final state (iter=$(sess current_iter) verdict=$(sess last_verdict) status=$(sess status) pushed=$(pushed_iter fa 1) evaluator line=${_evl:-none} push line=${_pul:-none} rc=$ENG_RC)" fail
[[ "$(segment_after_resume "$WAITS" | grep -c '^wait ' || true)" == "0" ]] \
  && assert "B4: the resumed run waited for nothing either" pass || assert "B4: the resumed run recorded quota waits" fail

# ══ C. the wrapper's retry budget is not reset by Goal Mode ══════════════════
echo "── C: CHAIN_CLAUDE_MAX_QUOTA_RETRIES=1 runs out inside the REAL wrapper ──"
printf '3\n' > "$WORK/c-count"
run_engine fc fresh 1 CHAIN_CLAUDE_MAX_QUOTA_RETRIES=1 STUB_QUOTA_AGENT=qa STUB_QUOTA_ITER=0 STUB_QUOTA_COUNT="$WORK/c-count"
CP="goal-fc-iter-0"
[[ "$(n_line 'quota qa 0' "$CANARY.quota")" == "2" && "$(n_line 'qa 0')" == "2" && "$(n_fixed 'Max quota retries (1) reached' "$ENG_LOG")" == "1" \
   && "$(n_waits "$WAITS" 'by=_claude_invoke script=qa-phase.sh')" == "1" ]] \
  && assert "C1: (seam) the REAL wrapper spent its whole budget — 2 attempts, 1 wrapper wait, then gave up with $RC75" pass \
  || assert "C1: (seam) wrapper budget (refusals=$(n_line 'quota qa 0' "$CANARY.quota") attempts=$(n_line 'qa 0') waits=[$(tr '\n' '|' < "$WAITS")])" fail
[[ "$(dispatches "$CP" "$ENG_LOG")" == "1" && "$(n_waits "$WAITS" 'script=run-goal.sh')" == "0" && "$(n_waits "$WAITS")" == "1" \
   && "$(tele quota_pause_start 0 agent)" == "qa" ]] \
  && assert "C2: Goal Mode did not reset that budget — no engine wait, no second run-phase.sh (the only quota pause is the wrapper's own)" pass \
  || assert "C2: dispatches=$(dispatches "$CP" "$ENG_LOG") engine waits=$(n_waits "$WAITS" 'script=run-goal.sh') pause agents='$(tele quota_pause_start 0 agent)'" fail
[[ "$(cat "$WORK/c-count" 2>/dev/null)" == "1" && "$ENG_RC" -eq "$RC75" && "$(sess status)" == "ABORTED" && "$(n_line 'goal-evaluator 0')" == "0" && "$(sess current_iter)" == "0" ]] && quota_halt 0 \
  && assert "C3: the quota a fresh retry budget would have consumed is untouched; resumable ABORTED stop (exit $RC75), nothing evaluated or advanced" pass \
  || assert "C3: remaining quota=$(cat "$WORK/c-count" 2>/dev/null || echo spent) rc=$ENG_RC status=$(sess status) eval=$(n_line 'goal-evaluator 0') iter=$(sess current_iter)" fail

# ══ D. a long-duration limit fails fast below and stops Goal Mode at once ════
echo "── D: a long-duration (monthly/org) limit ──"
printf '2\n' > "$WORK/d-count"
run_engine fd fresh 1 CHAIN_CLAUDE_MAX_QUOTA_RETRIES=3 STUB_QUOTA_AGENT=qa STUB_QUOTA_ITER=0 STUB_QUOTA_COUNT="$WORK/d-count" \
  STUB_QUOTA_MSG="You've hit your org's monthly usage limit"
DP="goal-fd-iter-0"
[[ "$(n_line 'quota qa 0' "$CANARY.quota")" == "1" && "$(n_fixed 'Long-duration limit detected (monthly/org). Skipping retry' "$ENG_LOG")" == "1" \
   && "$(n_fixed 'Max quota retries' "$ENG_LOG")" == "0" && "$(n_waits "$WAITS")" == "0" ]] \
  && assert "D1: (seam) the REAL wrapper classified the limit as long-duration and failed fast — no wait, no retry despite a budget of 3" pass \
  || assert "D1: (seam) long-duration path (refusals=$(n_line 'quota qa 0' "$CANARY.quota") waits=[$(tr '\n' '|' < "$WAITS")])" fail
[[ "$(dispatches "$DP" "$ENG_LOG")" == "1" && "$(tele quota_pause_start 0)" == "0" && "$(cat "$WORK/d-count" 2>/dev/null)" == "1" ]] \
  && assert "D2: Goal Mode stopped at once — no fallback (3600s) engine wait, no re-dispatch into the same monthly limit" pass \
  || assert "D2: dispatches=$(dispatches "$DP" "$ENG_LOG") pauses=$(tele quota_pause_start 0) remaining quota=$(cat "$WORK/d-count" 2>/dev/null || echo spent)" fail
[[ "$ENG_RC" -eq "$RC75" && "$(sess status)" == "ABORTED" && "$(n_line 'goal-evaluator 0')" == "0" && "$(sess current_iter)" == "0" \
   && "$(pushed_iter fd 0)" == "0" && "$(phase_step "$DP")" == "review_passed" ]] && quota_halt 0 \
  && assert "D3: resumable ABORTED stop (exit $RC75, QUOTA_EXHAUSTED) — not evaluated, advanced or pushed; checkpoint review_passed" pass \
  || assert "D3: stop (rc=$ENG_RC status=$(sess status) eval=$(n_line 'goal-evaluator 0') iter=$(sess current_iter) step=$(phase_step "$DP"))" fail

# ══ E. run-phase.sh's _run_step already waited: no second wait above it ══════
echo "── E: the demo step's quota is waited out by _run_step before it exits $RC75 ──"
EP="goal-fe-iter-0"
# Resume the executor from ui_impact_complete so the fanout is skipped and the
# demo runs in the sequential path, where run-phase.sh wraps it in _run_step.
mkdir -p "$ESBX/runs/$EP" "$ESBX/reports"
printf '{"phase":"%s","status":"in_progress","current_step":"ui_impact_complete"}\n' "$EP" > "$ESBX/runs/$EP/status.json"
printf '# %s Execution Plan\n\nFrontend Present: yes\n' "$EP" > "$ESBX/runs/$EP/plan.md"
printf '# user visible\n\ncontent\n' > "$ESBX/reports/phase-$EP-user-visible-changes.md"
printf '# Surface map\n- / (home)\n' > "$ESBX/reports/phase-$EP-ui-surface-map.md"
printf '1\n' > "$WORK/e-count"
run_engine fe fresh 1 STUB_QUOTA_AGENT=demo-narrator STUB_QUOTA_ITER=0 STUB_QUOTA_COUNT="$WORK/e-count"
[[ "$(n_line 'quota demo-narrator 0' "$CANARY.quota")" == "1" ]] && grep -qF 'RESUMING from checkpoint: ui_impact_complete' "$ENG_LOG" \
   && grep -qF "Quota exhaustion detected (exit $RC75). Waiting for reset" "$ENG_LOG" && grep -qF "Step 6.5 (demo) hit quota (exit $RC75)" "$ENG_LOG" \
  && assert "E1: (seam) the demo step's quota exit went through run-phase.sh's _run_step (sequential path), which then exited $RC75" pass \
  || assert "E1: (seam) _run_step demo path (refusals=$(n_line 'quota demo-narrator 0' "$CANARY.quota"))" fail
_ew="$(grep '^wait ' "$WAITS" || true)"
_ed="$(printf '%s\n' "$_ew" | sed -n 's/^wait until=\([0-9]*\) now=\([0-9]*\) .*/\1 \2/p' | awk '{ print $1 - $2 }')"
[[ "$(n_waits "$WAITS")" == "1" && "$(n_waits "$WAITS" 'by=_run_step script=run-phase.sh')" == "1" && "$_ed" =~ ^[0-9]+$ ]] && (( _ed >= 3590 && _ed <= 3600 )) \
  && assert "E2: the lower layer owned the wait — exactly one, by _run_step in run-phase.sh (fallback 3600s, stubbed instant)" pass \
  || assert "E2: waits=[$(tr '\n' '|' < "$WAITS")]" fail
[[ "$(n_waits "$WAITS" 'script=run-goal.sh')" == "0" && "$(tele quota_pause_start 0)" == "0" && "$(dispatches "$EP" "$ENG_LOG")" == "1" ]] \
  && assert "E3: after $RC75 reached Goal Mode there was no second wait and no re-dispatch" pass \
  || assert "E3: engine waits=$(n_waits "$WAITS" 'script=run-goal.sh') pauses=$(tele quota_pause_start 0) dispatches=$(dispatches "$EP" "$ENG_LOG")" fail
[[ "$ENG_RC" -eq "$RC75" && "$(sess status)" == "ABORTED" && "$(n_line 'goal-evaluator 0')" == "0" && "$(sess current_iter)" == "0" \
   && "$(phase_step "$EP")" == "quota_blocked" ]] && quota_halt 0 \
  && assert "E4: resumable ABORTED stop (exit $RC75, QUOTA_EXHAUSTED); the checkpoint is run-phase's own quota_blocked record, untouched by the engine" pass \
  || assert "E4: stop (rc=$ENG_RC status=$(sess status) eval=$(n_line 'goal-evaluator 0') iter=$(sess current_iter) step=$(phase_step "$EP"))" fail

# ══ O. the Step 1 orchestrator's own quota exit reaches the same stop ═══════
echo "── O: run-phase.sh exits $RC75 from Step 1 (orchestrator) ──"
printf '2\n' > "$WORK/o-count"
run_engine fo fresh 1 STUB_QUOTA_AGENT=orchestrator STUB_QUOTA_ITER=0 STUB_QUOTA_COUNT="$WORK/o-count"
OP="goal-fo-iter-0"
[[ "$(n_line 'quota orchestrator 0' "$CANARY.quota")" == "1" && "$(dispatches "$OP" "$ENG_LOG")" == "1" && ! -e "$ESBX/runs/$OP/plan.md" \
   && "$(n_line 'dev-phase.sh 0')" == "0" && "$(n_waits "$WAITS")" == "0" ]] \
  && assert "O1: a Step 1 orchestrator quota exit — one dispatch, no plan, nothing after Step 1, no wait at any layer" pass \
  || assert "O1: orchestrator path (refusals=$(n_line 'quota orchestrator 0' "$CANARY.quota") dispatches=$(dispatches "$OP" "$ENG_LOG") dev=$(n_line 'dev-phase.sh 0') waits=$(n_waits "$WAITS"))" fail
[[ "$ENG_RC" -eq "$RC75" && "$(sess status)" == "ABORTED" && "$(n_line 'goal-evaluator 0')" == "0" && "$(sess current_iter)" == "0" \
   && "$(phase_step "$OP")" == "starting" && "$(cat "$WORK/o-count" 2>/dev/null)" == "1" ]] && quota_halt 0 \
  && assert "O2: the same resumable stop (ABORTED, QUOTA_EXHAUSTED, exit $RC75); the un-checkpointed plan step stays owed (checkpoint starting)" pass \
  || assert "O2: stop (rc=$ENG_RC status=$(sess status) eval=$(n_line 'goal-evaluator 0') iter=$(sess current_iter) step=$(phase_step "$OP"))" fail

# ══ F. CHAIN_DISABLE_AUTO_WAIT=true ══════════════════════════════════════════
echo "── F: auto-wait disabled ──"
printf '2\n' > "$WORK/f-count"
run_engine ff fresh 1 CHAIN_DISABLE_AUTO_WAIT=true STUB_QUOTA_AGENT=qa STUB_QUOTA_ITER=0 STUB_QUOTA_COUNT="$WORK/f-count"
FP="goal-ff-iter-0"
[[ "$(n_line 'quota qa 0' "$CANARY.quota")" == "1" && "$(n_fixed "Fanout (Step 4-7/11) hit quota (exit $RC75)" "$ENG_LOG")" == "1" ]] \
   && grep -qF 'CHAIN_DISABLE_AUTO_WAIT=true — not retrying.' "$ENG_LOG" \
  && assert "F1: (seam) the wrapper failed fast (auto-wait disabled) and the fanout delivered $RC75 to Goal Mode" pass \
  || assert "F1: (seam) fail-fast path (refusals=$(n_line 'quota qa 0' "$CANARY.quota"))" fail
[[ "$(dispatches "$FP" "$ENG_LOG")" == "1" && "$(n_waits "$WAITS")" == "0" && "$(tele quota_pause_start 0)" == "0" ]] \
  && assert "F2: one executor dispatch, no wait at any layer" pass \
  || assert "F2: dispatches=$(dispatches "$FP" "$ENG_LOG") waits=$(n_waits "$WAITS")" fail
[[ "$ENG_RC" -eq "$RC75" && "$(sess status)" == "ABORTED" && "$(n_line 'goal-evaluator 0')" == "0" && "$(sess current_iter)" == "0" \
   && "$(pushed_iter ff 0)" == "0" && "$(phase_step "$FP")" == "review_passed" ]] && quota_halt 0 \
  && assert "F3: resumable ABORTED stop (exit $RC75, QUOTA_EXHAUSTED) — not evaluated, advanced or pushed; checkpoint review_passed" pass \
  || assert "F3: stop (rc=$ENG_RC status=$(sess status) eval=$(n_line 'goal-evaluator 0') iter=$(sess current_iter) pushed=$(pushed_iter ff 0) step=$(phase_step "$FP"))" fail

# ══ G. reserved halts outrank a simultaneous quota exit ══════════════════════
for _rx in "$RC79" "$RC78" "$RC70"; do
  echo "── G$_rx: Branch UI exits $_rx while Branch QA hits quota ──"
  printf '99\n' > "$WORK/g-count-$_rx"
  run_engine "fg$_rx" fresh 1 STUB_BQA_EXIT="$_rx" STUB_QUOTA_AGENT=qa STUB_QUOTA_ITER=0 STUB_QUOTA_COUNT="$WORK/g-count-$_rx"
  case "$_rx" in
    "$RC79") _want_status=GATE_BLOCKED;  _want_reason=GATE_BLOCKED_BROWSER_EVIDENCE ;;
    "$RC78") _want_status=GATE_BLOCKED;  _want_reason=GATE_BLOCKED_SPEC_FIELD_UNAVAILABLE ;;
    *)       _want_status=AWAITING_PUMP; _want_reason=AWAITING_PUMP ;;
  esac
  grep -qF "reserved lifecycle halt ([Branch-UI]=$_rx [Branch-QA]=$RC75) — exiting $_rx" "$ENG_LOG" && [[ "$(n_line 'quota qa 0' "$CANARY.quota")" == "1" ]] \
    && assert "G$_rx.1: (seam) the fanout saw both — Branch UI $_rx and Branch QA quota $RC75 — and kept $_rx" pass \
    || assert "G$_rx.1: (seam) collision (QA refusals=$(n_line 'quota qa 0' "$CANARY.quota"))" fail
  [[ "$(dispatches "goal-fg$_rx-iter-0" "$ENG_LOG")" == "1" && "$(n_waits "$WAITS")" == "0" ]] && ! quota_halt 0 \
    && assert "G$_rx.2: one executor dispatch, no wait, and no quota stop — the reserved halt is not handled as quota" pass \
    || assert "G$_rx.2: dispatches=$(dispatches "goal-fg$_rx-iter-0" "$ENG_LOG") waits=$(n_waits "$WAITS") halt reasons='$(tele halt 0 reason)'" fail
  [[ "$(sess status)" == "$_want_status" && " $(tele halt 0 reason) " == *" $_want_reason "* && "$(n_line 'goal-evaluator 0')" == "0" && "$(sess current_iter)" == "0" ]] \
    && assert "G$_rx.3: the existing top-level halt fired ($_want_status / $_want_reason), no evaluator, current_iter 0" pass \
    || assert "G$_rx.3: halt (status=$(sess status) reasons='$(tele halt 0 reason)' eval=$(n_line 'goal-evaluator 0') iter=$(sess current_iter) rc=$ENG_RC)" fail
done

# ══ H. lean characterization: the FULL arm does not touch the lean executor ══
echo "── H: lean developer quota exit ──"
printf '1\n' > "$WORK/h-count"
run_engine fh fresh 1 STUB_SPEC_DEPTH=lean STUB_QUOTA_AGENT=developer STUB_QUOTA_ITER=0 STUB_QUOTA_COUNT="$WORK/h-count"
[[ "$(n_fixed 'Dispatching LEAN pipeline via goal-iter-lean.sh' "$ENG_LOG")" == "1" && "$(n_line 'quota developer 0' "$CANARY.quota")" == "1" \
   && "$(n_line 'developer 0')" == "1" && "$(n_line 'reviewer 0')" == "0" && "$(n_line 'browser-qa-agent 0')" == "0" ]] \
  && assert "H1: (seam) the lean executor stopped at its quota-refused developer (goal-iter-lean.sh exit $RC75)" pass \
  || assert "H1: (seam) lean quota exit (dispatches=$(n_fixed 'Dispatching LEAN pipeline via goal-iter-lean.sh' "$ENG_LOG") refusals=$(n_line 'quota developer 0' "$CANARY.quota") dev=$(n_line 'developer 0') rev=$(n_line 'reviewer 0'))" fail
[[ "$(n_grep '^\[run-phase\]   Phase: ' "$ENG_LOG")" == "0" && "$(n_waits "$WAITS")" == "0" ]] && ! quota_halt 0 \
  && assert "H2: the FULL quota stop did not engage for lean — no run-phase.sh, no wait, no QUOTA_EXHAUSTED halt" pass \
  || assert "H2: FULL handling leaked into lean (run-phase runs=$(n_grep '^\[run-phase\]   Phase: ' "$ENG_LOG") waits=$(n_waits "$WAITS") halt reasons='$(tele halt 0 reason)')" fail
[[ "$(n_line 'goal-evaluator 0')" == "1" && "$(sess current_iter)" == "1" ]] \
  && assert "H3: PINNED pre-existing lean behaviour — after the lean quota exit the engine still proceeds to the evaluator (no lean rc-$RC75 handling; recorded debt)" pass \
  || assert "H3: pinned lean behaviour changed (eval=$(n_line 'goal-evaluator 0') iter=$(sess current_iter) status=$(sess status))" fail

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
