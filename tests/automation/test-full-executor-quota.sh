#!/usr/bin/env bash
# test-full-executor-quota.sh — a Goal Mode FULL executor (run-phase.sh) that
# exits QUOTA_EXHAUSTED_EXIT_CODE has NOT completed its iteration. The engine
# must not run the coherence auditor or the goal-evaluator over it, must not
# advance current_iter, must not push it as a successful iteration, and must
# retry the SAME iteration from run-phase.sh's own checkpoints after the
# existing quota wait (run-phase.sh's _run_step contract: "sleep until the quota
# resets, then the caller retries"; its fanout exits 75 "for the outer loop").
#
# The rc path is REAL end to end — only the model and the step leaves are stubs:
#   stub `claude` prints a usage-limit message
#     → REAL lib/quota-retry.sh (CHAIN_CLAUDE_MAX_QUOTA_RETRIES=0: the wrapper's
#       own waits are already spent → 75; it never writes the shared sentinel)
#     → a qa-phase.sh stub that dispatches through claude_with_quota_retry
#     → REAL lib/parallel.sh post-dev fanout → REAL run-phase.sh
#     → REAL run-goal.sh.
# CHAIN_CLAUDE_FALLBACK_SLEEP_SECONDS only shortens the existing wait.
#
# Sections (offline; stub claude, stub step scripts, dummy HTTP services):
#   W  wiring: the named constant, the check right after the FULL dispatch and
#      before the coherence section, parallel.sh's rationale no longer cites the
#      missing arm
#   S  the wait helper in isolation (stubbed quota primitives): a live sentinel's
#      reset epoch wins; else CHAIN_CLAUDE_FALLBACK_SLEEP_SECONDS (unset or
#      garbage → 3600, "08" is decimal); auto-wait disabled or a zero wait stops
#      resumably instead of re-dispatching in a tight loop
#   Q  automatic recovery: the QA agent refuses for two fanout attempts, then its
#      quota resets. Snapshots taken at every QA attempt prove nothing downstream
#      happened while the quota was unresolved; the run proves the SAME iteration
#      resumed from review_passed, re-ran only the un-checkpointed fanout, waited
#      between attempts, and was evaluated, advanced and pushed once — after the
#      executor completed.   (RED on dcc39e2: one attempt, then evaluated + pushed)
#   U  persistent account-wide quota (every agent refuses): the engine keeps
#      waiting between FULL re-dispatches — no coherence auditor, no evaluator, no
#      fabricated COHERENCE-PASS crash stub, no advance, no push — until stopped
#      the way /goal-pause stops it (SIGTERM).
#                            (RED: crash-stub PASS written, evaluator dispatched)
#   R  quota cleared → --resume: the SAME iteration resumes from the same
#      run-phase checkpoint and only then is evaluated, advanced and pushed.
#   D  CHAIN_DISABLE_AUTO_WAIT=true: the engine honours it — one executor
#      dispatch, no wait, a resumable ABORTED stop (exit 75) with nothing
#      evaluated, advanced or pushed.   (RED: waited, re-dispatched, evaluated)
#   X  reserved halts keep precedence: Branch UI exiting 79 / 78 / 70 while
#      Branch QA hits quota reaches the EXISTING top-level halt — one executor
#      dispatch, no quota wait, no evaluator.
#   L  lean control: a lean developer quota exit (goal-iter-lean.sh → 75) is not
#      touched by the FULL handling — one dispatch, no quota wait. The engine's
#      pre-existing lean behaviour after that exit (it proceeds to the
#      evaluator) is PINNED, not endorsed: lean has no engine rc-75 handling
#      (recorded debt, out of scope for the FULL fix).
#
# Never writes the machine-global quota sentinel and refuses to start while a LIVE
# one exists (every stub dispatch would sleep until it resets). A sentinel another
# session writes mid-run is outside the test's control: the wrapper would sleep
# on it, and the run fails at its timeout instead of hanging.
#
# shellcheck disable=SC2015,SC2016,SC2034,SC2329
# (SC2015: assert's pass arm always returns 0; SC2016: generated stub bodies are
# single-quoted on purpose; SC2034/SC2329: harness vars and trap-invoked cleanup.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
QR_LIB="$ENGINE_ROOT/scripts/automation/lib/quota-retry.sh"
# The quota code and sentinel path come from their single definition.
RC75="$(bash -c 'source "$1" >/dev/null 2>&1; printf %s "${QUOTA_EXHAUSTED_EXIT_CODE:-}"' _ "$QR_LIB")"
SENTINEL="$(bash -c 'source "$1" >/dev/null 2>&1; printf %s "${_QUOTA_SENTINEL:-}"' _ "$QR_LIB")"
[[ "$RC75" =~ ^[0-9]+$ && -n "$SENTINEL" ]] || { echo "cannot read QUOTA_EXHAUSTED_EXIT_CODE/_QUOTA_SENTINEL from $QR_LIB" >&2; exit 1; }
RC79="${BROWSER_EVIDENCE_GATE_UNAVAILABLE_EXIT_CODE:-79}"
RC78="${SPEC_FIELD_UNAVAILABLE_EXIT_CODE:-78}"
RC70="${DISPATCH_UNAVAILABLE_EXIT_CODE:-70}"
WAIT_S=3                         # CHAIN_CLAUDE_FALLBACK_SLEEP_SECONDS for every engine run
ARM_PHRASE="FULL executor exited quota exhaustion (exit $RC75)"
# Hermetic: an inherited fail-fast knob or agent tag (e.g. evals run from inside
# an agent) would change what the engine does or how the stub claude plays roles.
unset CHAIN_DISABLE_AUTO_WAIT CHAIN_CURRENT_AGENT

_live="$(cat "$SENTINEL" 2>/dev/null || true)"
if [[ "$_live" =~ ^[0-9]+$ ]] && (( _live > $(date +%s) )); then
  echo "ABORT: the machine-global quota sentinel $SENTINEL is LIVE (another session is waiting out a quota window until epoch $_live)." >&2
  echo "       Every stub dispatch here would sleep until then. This test never writes it; re-run after it expires." >&2
  exit 1
fi

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
refuse() {
  echo "quota $agent $iter" >> "$CANARY.quota"
  echo "You've hit your usage limit · resets 3am (UTC)"
  exit 1
}
# Account-wide quota wall: while the file exists EVERY agent refuses.
[[ -n "${STUB_QUOTA_ALL:-}" && -f "$STUB_QUOTA_ALL" ]] && refuse
# Agent-scoped wall for one iteration: each refusal spends one unit of the count
# file, which disappears when the quota "resets".
if [[ -n "${STUB_QUOTA_AGENT:-}" && "$agent" == "$STUB_QUOTA_AGENT" && "$iter" == "${STUB_QUOTA_ITER:-}" \
      && -n "${STUB_QUOTA_COUNT:-}" && -f "$STUB_QUOTA_COUNT" ]]; then
  n="$(cat "$STUB_QUOTA_COUNT")"
  if [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]]; then
    n=$((n - 1))
    if [[ "$n" -gt 0 ]]; then echo "$n" > "$STUB_QUOTA_COUNT"; else rm -f "$STUB_QUOTA_COUNT"; fi
    refuse
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
write_stub demo-phase.sh           ""
write_stub ux-regression-phase.sh  "UX-REGRESSION-PASS" 'reports/phase-${P}-ux-regression.md'
write_stub phase-audit.sh          "PASS"               'docs/handoffs/${P}-audit.md'
write_stub phase-closure-check.sh  "CLOSURE-PASS"       'reports/phase-${P}-closure-verdict.md'
# Branch UI's browser step: a PASS results file, or a reserved exit (section X).
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
# Branch QA: dispatches the QA agent through the REAL quota wrapper, and records
# what the engine had done by the time each attempt started.
cat > "$ESBX/scripts/automation/qa-phase.sh" <<'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/telemetry.sh"
P="$1"; N="${P##*-iter-}"; SD="${GOAL_SESSION_DIR:-}"
echo "qa-phase.sh $N" >> "$CANARY"
_c="$SNAP_DIR/qa-count-$P"; A=$(( $(cat "$_c" 2>/dev/null || echo 0) + 1 )); echo "$A" > "$_c"
# Scenario U arms the account-wide wall from inside the fanout's first attempt.
if [[ -n "${STUB_ARM_QUOTA_ALL_ITER:-}" && "$N" == "$STUB_ARM_QUOTA_ALL_ITER" && "$A" -eq 1 ]]; then : > "$STUB_QUOTA_ALL"; fi
_json() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("" if v is None else v)' "$1" "$2" 2>/dev/null; }
_tele() { python3 -c 'import json,sys
n=0
try:
    for l in open(sys.argv[1]):
        try: d=json.loads(l)
        except ValueError: continue
        n += d.get("event")==sys.argv[2] and str(d.get("iter"))==sys.argv[3]
except OSError: pass
print(n)' "$SD/telemetry.jsonl" "$1" "$N"; }
{
  printf 'ts=%s\n' "$(date +%s.%N)"
  printf 'step=%s\n' "$(_json "$REPO_ROOT/runs/$P/status.json" current_step)"
  printf 'current_iter=%s\n' "$(_json "$SD/session.json" current_iter)"
  printf 'last_verdict=%s\n' "$(_json "$SD/session.json" last_verdict)"
  printf 'coh=%s\n' "$(grep -cxF "coherence-auditor $N" "$CANARY" || true)"
  printf 'eval=%s\n' "$(grep -cxF "goal-evaluator $N" "$CANARY" || true)"
  for f in eval.md .evaluated coherence.md; do
    printf '%s=%s\n' "$f" "$([[ -e "$SD/iter-$N/$f" ]] && echo present || echo absent)"
  done
  printf 'iter_end=%s\n' "$(_tele iter_end)"
  printf 'pushed=%s\n' "$(git -C "$STUB_REMOTE" log --format=%s "goal/$GOAL_SESSION_ID" 2>/dev/null | grep -c "^goal($GOAL_SESSION_ID): iter $N " || true)"
} > "$SNAP_DIR/$P-qa-$A.snap"
mkdir -p "$REPO_ROOT/reports/qa"
record_agent_invocation_start qa
rc=0
claude_with_quota_retry -p "You are the QA agent (stub).

Write your QA report to: $REPO_ROOT/reports/qa/${P}-qa.md" || rc=$?
record_agent_invocation_end qa "$CHAIN_AGENT_START_EPOCH" "$rc"
exit "$rc"
EOF
git -C "$ESBX" add -A; git -C "$ESBX" commit -qm base
REMOTE="$WORK/remote.git"; git init -q --bare "$REMOTE"; git -C "$ESBX" remote add origin "$REMOTE"

TMPROOT="$WORK/tmproot"; mkdir -p "$TMPROOT"
SNAP_DIR="$WORK/snaps"; mkdir -p "$SNAP_DIR"
ENGINE_ENV=(
  CHAIN_DOCTOR=false CHAIN_GOAL_LINT=false CHAIN_SESSION_RETRO=false
  CHAIN_TMP_ROOT="$TMPROOT" CHAIN_TMP_LEGACY_ROOTS="" CHAIN_DISABLE_TRACE=true
  CHAIN_BACKEND_PORT="$BE_PORT" CHAIN_FRONTEND_PORT="$FE_PORT" CHAIN_BACKEND_HEALTH_URL="http://localhost:${BE_PORT}/"
  CHAIN_START_BACKEND_CMD="python3 -m http.server $BE_PORT --directory $SRV_DIR"
  CHAIN_START_FRONTEND_CMD="python3 -m http.server $FE_PORT --directory $SRV_DIR"
  CHAIN_SKIP_GITHUB_PREFLIGHT=true CHAIN_KILL_GRACE_SECONDS=1
  CHAIN_DEPTH_ARBITER=false CHAIN_ASYNC_SHOWCASE=false CHAIN_ZERO_CHANGE_SKIPS=false
  CHAIN_CLAUDE_MAX_QUOTA_RETRIES=0 CHAIN_CLAUDE_FALLBACK_SLEEP_SECONDS="$WAIT_S"
)

eng_paths() {  # <sid> <fresh|resume>
  ENG_SID="$1"; ENG_SESSION="$ESBX/runs/goal-session-$1"; ENG_LOG="$WORK/eng-$1.log"
  CANARY="$WORK/canary-$1.log"; export CANARY
  if [[ "$2" == "fresh" ]]; then
    rm -rf "$ENG_SESSION"; : > "$CANARY"; : > "$CANARY.quota"; : > "$ENG_LOG"
  else
    echo "=== resume ===" >> "$CANARY"; echo "=== resume ===" >> "$ENG_LOG"
  fi
}
engine_args() {  # <sid> <fresh|resume> <max-iter> → ENG_ARGS
  ENG_ARGS=(--session-id "$1" --max-iter "$3")
  if [[ "$2" == "resume" ]]; then ENG_ARGS+=(--resume); fi
}
run_engine() {  # <sid> <fresh|resume> <max-iter> [ENV=val ...] — foreground → ENG_RC
  local sid="$1" mode="$2" max_iter="$3"; shift 3
  eng_paths "$sid" "$mode"; engine_args "$sid" "$mode" "$max_iter"
  ENG_RC=0; start_dummies
  ( cd "$ESBX" && exec env PATH="$STUB_DIR:$PATH" CANARY="$CANARY" SNAP_DIR="$SNAP_DIR" STUB_REMOTE="$REMOTE" \
      "${ENGINE_ENV[@]}" "$@" timeout 600 bash scripts/automation/run-goal.sh "${ENG_ARGS[@]}" ) >> "$ENG_LOG" 2>&1 || ENG_RC=$?
}
run_engine_bg() {  # same arguments — background → ENG_BG_PID
  local sid="$1" mode="$2" max_iter="$3"; shift 3
  eng_paths "$sid" "$mode"; engine_args "$sid" "$mode" "$max_iter"
  start_dummies
  ( cd "$ESBX" && exec env PATH="$STUB_DIR:$PATH" CANARY="$CANARY" SNAP_DIR="$SNAP_DIR" STUB_REMOTE="$REMOTE" \
      "${ENGINE_ENV[@]}" "$@" timeout 600 bash scripts/automation/run-goal.sh "${ENG_ARGS[@]}" ) >> "$ENG_LOG" 2>&1 &
  ENG_BG_PID=$!
}

sess() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("" if v is None else v)' "$ENG_SESSION/session.json" "$1" 2>/dev/null || echo "?"; }
phase_step() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("current_step",""))' "$ESBX/runs/$1/status.json" 2>/dev/null || echo "?"; }
n_line() { local n; n="$(grep -cxF -- "$1" "${2:-$CANARY}" 2>/dev/null || true)"; echo "${n:-0}"; }   # exact lines
n_grep() { local n; n="$(grep -c -- "$1" "$2" 2>/dev/null || true)"; echo "${n:-0}"; }
n_fixed() { local n; n="$(grep -cF -- "$1" "$2" 2>/dev/null || true)"; echo "${n:-0}"; }
first_at() { awk -v l="$1" '$0 == l { print NR; exit }' "${2:-$CANARY}"; }
last_at()  { awk -v l="$1" '$0 == l { n = NR } END { if (n) print n }' "${2:-$CANARY}"; }
pushed_iter() { local n; n="$(git -C "$REMOTE" log --format=%s "goal/$1" 2>/dev/null | grep -c "^goal($1): iter $2 " || true)"; echo "${n:-0}"; }
snapv() { sed -n "s/^$2=//p" "$1" 2>/dev/null; }
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
gap_ge() {  # <snapA> <snapB> <seconds> — attempt B started at least <seconds> after A
  python3 -c 'import sys; sys.exit(0 if float(sys.argv[2]) - float(sys.argv[1]) >= float(sys.argv[3]) else 1)' \
    "$(snapv "$1" ts)" "$(snapv "$2" ts)" "$3" 2>/dev/null
}
slept_ok() {  # every recorded quota_pause_end sleep was a real (non-zero) wait; S pins the exact length
  local s; [[ -n "$1" ]] || return 1
  for s in $1; do [[ "$s" =~ ^[0-9]+$ && "$s" -ge 1 ]] || return 1; done
}
segment_after_resume() { awk 'f; $0 == "=== resume ===" { f = 1 }' "$1"; }

echo "=== test-full-executor-quota.sh ==="

# ══ W. wiring ═════════════════════════════════════════════════════════════════
RG="$ENGINE_ROOT/scripts/automation/run-goal.sh"; PAR="$ENGINE_ROOT/scripts/automation/lib/parallel.sh"
grep -q 'QUOTA_EXHAUSTED_EXIT_CODE' "$RG" && ! grep -qE '(-eq|-ne|==|!=)[[:space:]]*"?75"?([^0-9]|$)' "$RG" \
  && assert "W1: run-goal.sh keys the FULL executor quota handling on QUOTA_EXHAUSTED_EXIT_CODE (no bare 75)" pass \
  || assert "W1: run-goal.sh keys the FULL executor quota handling on QUOTA_EXHAUSTED_EXIT_CODE (no bare 75)" fail
_full="$(grep -n 'bash "$SCRIPT_DIR/run-phase.sh"' "$RG" | head -n1 | cut -d: -f1 || true)"
_q="$(awk -v f="${_full:-999999}" 'NR > f && /QUOTA_EXHAUSTED_EXIT_CODE/ { print NR; exit }' "$RG")"
_coh="$(grep -n '3b. Coherence auditor' "$RG" | head -n1 | cut -d: -f1 || true)"
[[ -n "$_full" && -n "$_q" && -n "$_coh" ]] && (( _q - _full <= 2 && _q < _coh )) \
  && assert "W2: the FULL dispatch's exit code is checked for quota right after run-phase.sh returns, before the coherence auditor / evaluator section" pass \
  || assert "W2: quota check placement (full dispatch=${_full:-none} first quota check after it=${_q:-none} coherence=${_coh:-none})" fail
! grep -q 'no FULL-executor 75 arm' "$PAR" && grep -q 'QUOTA_EXHAUSTED_EXIT_CODE' "$PAR" \
  && assert "W3: parallel.sh no longer justifies reserved-over-quota by a missing run-goal.sh arm" pass \
  || assert "W3: parallel.sh still cites the missing FULL-executor 75 arm as its ordering rationale" fail

# ══ S. the wait helper in isolation (stubbed primitives; no shared sentinel) ══
S_FN="$(sed -n '/^_full_executor_quota_wait() {/,/^}/p' "$RG")"
S_LOG="$WORK/s-calls.log"
s_run() {  # <live-sentinel-remaining or ""> <fallback or UNSET> <auto-wait on|off> → S_RC, calls in $S_LOG
  : > "$S_LOG"
  # Not `( … ) || S_RC=$?`: that context suppresses set -e inside the subshell, and
  # the engine runs the helper under set -euo pipefail.
  set +e
  ( set -euo pipefail
    eval "$S_FN"
    _quota_check_sentinel() { [[ -n "$S_REMAINING" ]] || return 1; echo "$S_REMAINING"; }
    _sleep_until_epoch()    { echo "sleep $1" >> "$S_LOG"; }
    _quota_pause_begin()    { echo "pause_begin ${CHAIN_CURRENT_AGENT:-unset} $1" >> "$S_LOG"; }
    _quota_pause_end()      { echo "pause_end ${CHAIN_CURRENT_AGENT:-unset}" >> "$S_LOG"; }
    _quota_clear_sentinel() { echo "clear" >> "$S_LOG"; }
    _engine_step_done()      { echo "step_done" >> "$S_LOG"; }
    record_telemetry_event() { echo "telemetry $1 $2" >> "$S_LOG"; }
    write_session_summary()  { echo "summary $1 $2" >> "$S_LOG"; }
    explain_goal_status()    { :; }
    CURRENT_ITER=4; ITER_NAME=goal-s-iter-4; SESSION_ID=s; REPO_ROOT="$WORK"; S_REMAINING="$1"
    unset CHAIN_CURRENT_AGENT
    if [[ "$2" == UNSET ]]; then unset CHAIN_CLAUDE_FALLBACK_SLEEP_SECONDS; else export CHAIN_CLAUDE_FALLBACK_SLEEP_SECONDS="$2"; fi
    if [[ "$3" == off ]]; then export CHAIN_DISABLE_AUTO_WAIT=true; else unset CHAIN_DISABLE_AUTO_WAIT; fi
    echo "now $(date +%s)" >> "$S_LOG"
    _full_executor_quota_wait "$RC75" 2>/dev/null
    echo "returned agent=${CHAIN_CURRENT_AGENT:-unset}" >> "$S_LOG"
  )
  S_RC=$?
  set -e
}
s_waited_between() {  # <min> <max> — the sleep target sits <min>..<max> seconds after the call
  local v; v="$(awk '$1 == "now" { n = $2 } $1 == "sleep" { s = $2 } END { if (s != "") print s - n }' "$S_LOG")"
  [[ -n "$v" ]] && (( v >= $1 && v <= $2 ))
}
s_at() { awk -v p="$1" 'index($0, p) == 1 { print NR; exit }' "$S_LOG"; }
if [[ -n "$S_FN" ]]; then
  s_run 5400 60 on
  _b="$(s_at 'pause_begin full-pipeline')"; _s="$(s_at 'sleep ')"; _e="$(s_at 'pause_end full-pipeline')"; _c="$(s_at 'clear')"; _r="$(s_at 'returned agent=unset')"
  [[ "$S_RC" -eq 0 && -n "$_b" && -n "$_s" && -n "$_e" && -n "$_c" && -n "$_r" ]] && (( _b < _s && _s < _e && _e < _c && _c < _r )) && s_waited_between 5400 5402 \
    && assert "S1: a live sentinel's reset epoch wins over the fallback; pause telemetry (full-pipeline) brackets the sleep, then the sentinel is cleared; the agent tag does not leak" pass \
    || assert "S1: live-sentinel wait (rc=$S_RC calls: $(tr '\n' '|' < "$S_LOG"))" fail
  s_run "" 120 on
  [[ "$S_RC" -eq 0 ]] && s_waited_between 120 122 \
    && assert "S2: no live sentinel → waits CHAIN_CLAUDE_FALLBACK_SLEEP_SECONDS (120s)" pass \
    || assert "S2: fallback wait (rc=$S_RC calls: $(tr '\n' '|' < "$S_LOG"))" fail
  s_run "" UNSET on;  _s3=$S_RC; s_waited_between 3600 3602 && _s3w=yes || _s3w=no
  s_run "" 1h on;     _s4=$S_RC; s_waited_between 3600 3602 && _s4w=yes || _s4w=no
  s_run "" 08 on;     _s5=$S_RC; s_waited_between 8 10     && _s5w=yes || _s5w=no
  [[ "$_s3$_s3w $_s4$_s4w $_s5$_s5w" == "0yes 0yes 0yes" ]] \
    && assert "S3: an unset or non-numeric fallback waits _run_step's 3600s default; '08' is read as decimal (no octal crash)" pass \
    || assert "S3: fallback parsing (unset rc=$_s3 wait=$_s3w; '1h' rc=$_s4 wait=$_s4w; '08' rc=$_s5 wait=$_s5w)" fail
  s_run 5400 60 off
  [[ "$S_RC" -eq "$RC75" && -z "$(s_at 'sleep ')" && -z "$(s_at 'returned')" && -n "$(s_at 'step_done')" ]] && grep -q '^telemetry halt .*"reason":"QUOTA_EXHAUSTED"' "$S_LOG" && grep -qx 'summary ABORTED 4' "$S_LOG" \
    && assert "S4: CHAIN_DISABLE_AUTO_WAIT=true → no wait even with a live sentinel; resumable ABORTED stop (full-pipeline bracket closed, halt QUOTA_EXHAUSTED, exit $RC75)" pass \
    || assert "S4: auto-wait disabled (rc=$S_RC calls: $(tr '\n' '|' < "$S_LOG"))" fail
  s_run "" 0 on
  [[ "$S_RC" -eq "$RC75" && -z "$(s_at 'sleep ')" && -z "$(s_at 'returned')" ]] && grep -qx 'summary ABORTED 4' "$S_LOG" \
    && assert "S5: a zero wait (fallback 0, no live sentinel) stops the same way instead of re-dispatching in a tight loop" pass \
    || assert "S5: zero wait (rc=$S_RC calls: $(tr '\n' '|' < "$S_LOG"))" fail
else
  assert "S0: _full_executor_quota_wait() is not defined in run-goal.sh" fail
fi

# ══ Q. automatic recovery through the REAL run-phase.sh fanout ═══════════════
echo "── Q: QA quota exhausted for two fanout attempts, then reset ──"
printf '2\n' > "$WORK/q-count"
run_engine fq fresh 2 STUB_QUOTA_AGENT=qa STUB_QUOTA_ITER=1 STUB_QUOTA_COUNT="$WORK/q-count"
QP="goal-fq-iter-1"
[[ "$(n_line 'qa-phase.sh 0')" == "1" && "$(n_line 'goal-evaluator 0')" == "1" && "$(pushed_iter fq 0)" == "1" ]] \
  && assert "Q0: (seam) iteration 0 ran the FULL pipeline once, healthy — evaluated and pushed" pass \
  || { assert "Q0: (seam) iteration 0 healthy (qa=$(n_line 'qa-phase.sh 0') eval=$(n_line 'goal-evaluator 0') pushed=$(pushed_iter fq 0) engine rc=$ENG_RC)" fail; tail -n 30 "$ENG_LOG"; }
_ref="$(n_line 'quota qa 1' "$CANARY.quota")"; _fan="$(n_fixed "Fanout (Step 4-7/11) hit quota (exit $RC75)" "$ENG_LOG")"
[[ "$_ref" == "2" && "$_fan" == "2" ]] && grep -q 'Max quota retries (0) reached' "$ENG_LOG" \
  && assert "Q1: the REAL chain delivered $RC75 to the engine twice (QA refusal → quota-retry → fanout → run-phase.sh exit)" pass \
  || assert "Q1: rc path (QA refusals=$_ref, run-phase fanout quota exits=$_fan)" fail
[[ "$(n_fixed "$ARM_PHRASE" "$ENG_LOG")" == "2" ]] \
  && assert "Q2: run-goal.sh named both FULL executor quota exits instead of treating them as a result" pass \
  || assert "Q2: engine quota handling lines: $(n_fixed "$ARM_PHRASE" "$ENG_LOG") (want 2)" fail
[[ "$(n_grep "^\[run-phase\]   Phase: $QP\$" "$ENG_LOG")" == "3" && "$(cat "$SNAP_DIR/qa-count-$QP" 2>/dev/null)" == "3" ]] \
  && assert "Q3: the SAME iteration's FULL executor was re-dispatched until it completed (3 run-phase.sh runs, 3 QA attempts)" pass \
  || assert "Q3: re-dispatch (run-phase runs=$(n_grep "^\[run-phase\]   Phase: $QP\$" "$ENG_LOG") QA attempts=$(cat "$SNAP_DIR/qa-count-$QP" 2>/dev/null || echo 0))" fail
for _a in 2 3; do
  _s="$SNAP_DIR/$QP-qa-$_a.snap"
  if [[ -f "$_s" && "$(snapv "$_s" coh)" == "0" && "$(snapv "$_s" eval)" == "0" \
        && "$(snapv "$_s" eval.md)" == "absent" && "$(snapv "$_s" .evaluated)" == "absent" && "$(snapv "$_s" coherence.md)" == "absent" \
        && "$(snapv "$_s" current_iter)" == "1" && "$(snapv "$_s" last_verdict)" == "CONTINUE" \
        && "$(snapv "$_s" pushed)" == "0" && "$(snapv "$_s" iter_end)" == "0" && "$(snapv "$_s" step)" == "review_passed" ]]; then
    assert "Q4.$_a: when retry $_a began (quota unresolved) nothing downstream had happened — no coherence auditor, no evaluator, no eval.md/.evaluated/coherence.md, current_iter 1, last_verdict still iteration 0's, nothing pushed, no iter_end, run-phase checkpoint review_passed" pass
  else
    assert "Q4.$_a: retry-$_a snapshot: $([[ -f "$_s" ]] && tr '\n' ' ' < "$_s" || echo 'MISSING — the iteration was never retried')" fail
  fi
done
_slept="$(tele quota_pause_end 1 sleep_seconds)"
[[ "$(tele quota_pause_start 1)" == "2" && "$(tele quota_pause_end 1)" == "2" ]] && slept_ok "$_slept" \
  && gap_ge "$SNAP_DIR/$QP-qa-1.snap" "$SNAP_DIR/$QP-qa-2.snap" $((WAIT_S - 1)) \
  && gap_ge "$SNAP_DIR/$QP-qa-2.snap" "$SNAP_DIR/$QP-qa-3.snap" $((WAIT_S - 1)) \
  && grep -qx '\*\*Quota pauses:\*\* 2' "$ENG_SESSION/summary.md" \
  && assert "Q5: each retry followed a real quota wait (2 quota_pause events with non-zero sleeps, attempts ≥$((WAIT_S - 1))s apart, 'Quota pauses: 2')" pass \
  || assert "Q5: wait evidence (pause starts=$(tele quota_pause_start 1) ends=$(tele quota_pause_end 1) slept='$_slept')" fail
[[ "$(n_line 'orchestrator 1')" == "1" && "$(n_line 'dev-phase.sh 1')" == "1" && "$(n_line 'review-phase.sh 1')" == "1" \
   && "$(n_fixed 'RESUMING from checkpoint: review_passed' "$ENG_LOG")" == "2" ]] \
  && assert "Q6: checkpointed work was not redone — plan/dev/review ran once; both retries resumed from review_passed" pass \
  || assert "Q6: checkpoint reuse (orchestrator=$(n_line 'orchestrator 1') dev=$(n_line 'dev-phase.sh 1') review=$(n_line 'review-phase.sh 1') resumes=$(n_fixed 'RESUMING from checkpoint: review_passed' "$ENG_LOG"))" fail
[[ "$(n_line 'ui-impact-phase.sh 1')" == "3" && "$(n_line 'browser-qa-phase.sh 1')" == "3" && "$(n_line 'qa-phase.sh 1')" == "3" \
   && "$(n_line 'ux-regression-phase.sh 1')" == "1" && "$(n_line 'phase-audit.sh 1')" == "1" && "$(n_line 'phase-closure-check.sh 1')" == "1" ]] \
   && grep -qx '\*\*Verdict:\*\* PASS' "$ESBX/reports/qa/$QP-qa.md" \
  && assert "Q7: un-checkpointed work was not skipped — the fanout re-ran per attempt; QA passed; UX/audit/closure ran once, after it" pass \
  || assert "Q7: re-run of un-checkpointed work (ui-impact=$(n_line 'ui-impact-phase.sh 1') bqa=$(n_line 'browser-qa-phase.sh 1') qa=$(n_line 'qa-phase.sh 1') ux=$(n_line 'ux-regression-phase.sh 1') audit=$(n_line 'phase-audit.sh 1') closure=$(n_line 'phase-closure-check.sh 1'))" fail
_lq="$(last_at 'qa-phase.sh 1')"; _cl="$(first_at 'phase-closure-check.sh 1')"; _co="$(first_at 'coherence-auditor 1')"; _ev="$(first_at 'goal-evaluator 1')"
[[ -n "$_lq" && -n "$_cl" && -n "$_co" && -n "$_ev" && "$_lq" -lt "$_cl" && "$_cl" -lt "$_co" && "$_co" -lt "$_ev" \
   && "$(n_line 'coherence-auditor 1')" == "1" && "$(n_line 'goal-evaluator 1')" == "1" ]] \
  && assert "Q8: coherence auditor and evaluator ran exactly once, only after the executor completed (last QA < closure < coherence < evaluator)" pass \
  || assert "Q8: ordering (last qa=${_lq:-none} closure=${_cl:-none} coherence=${_co:-none} evaluator=${_ev:-none}; coh=$(n_line 'coherence-auditor 1') eval=$(n_line 'goal-evaluator 1'))" fail
[[ "$(sess current_iter)" == "2" && "$(sess last_verdict)" == "CONTINUE" && "$(sess status)" == "BUDGET_EXHAUSTED" \
   && "$(pushed_iter fq 1)" == "1" && "$(phase_step "$QP")" == "closure_passed" && -f "$ENG_SESSION/iter-1/.evaluated" ]] \
  && assert "Q9: iteration 1 was advanced and pushed exactly once, after normal evaluation (current_iter 2, closure_passed)" pass \
  || assert "Q9: final state (iter=$(sess current_iter) verdict=$(sess last_verdict) status=$(sess status) pushed=$(pushed_iter fq 1) step=$(phase_step "$QP") rc=$ENG_RC)" fail

# ══ U. persistent account-wide quota: waits, never evaluates ═════════════════
echo "── U: every agent refuses from iteration 1's first QA attempt on ──"
UP="goal-fu-iter-1"
run_engine_bg fu fresh 2 STUB_QUOTA_ALL="$WORK/u-quota-all" STUB_ARM_QUOTA_ALL_ITER=1
_deadline=$((SECONDS + 420))
while (( SECONDS < _deadline )); do
  [[ -f "$ENG_SESSION/telemetry.jsonl" && "$(tele quota_pause_end 1)" -ge 2 && "$(cat "$SNAP_DIR/qa-count-$UP" 2>/dev/null || echo 0)" -ge 3 ]] && break
  kill -0 "$ENG_BG_PID" 2>/dev/null || break
  sleep 1
done
_engine_alive=no; kill -0 "$ENG_BG_PID" 2>/dev/null && _engine_alive=yes
_epid="$(cat "$ENG_SESSION/engine.pid" 2>/dev/null || true)"
[[ -n "$_epid" ]] && kill -TERM "$_epid" 2>/dev/null || true      # /goal-pause: SIGTERM → on_abort
for _i in $(seq 1 90); do kill -0 "$ENG_BG_PID" 2>/dev/null || break; sleep 1; done
kill -0 "$ENG_BG_PID" 2>/dev/null && { kill -KILL "$ENG_BG_PID" 2>/dev/null || true; }
ENG_RC=0; wait "$ENG_BG_PID" 2>/dev/null || ENG_RC=$?
_att="$(cat "$SNAP_DIR/qa-count-$UP" 2>/dev/null || echo 0)"
[[ "$_engine_alive" == "yes" && "$(tele quota_pause_end 1)" -ge 2 && "$_att" -ge 3 && "$(n_fixed "$ARM_PHRASE" "$ENG_LOG")" -ge 2 ]] \
  && assert "U1: while the quota stayed exhausted the engine kept waiting and re-dispatching the FULL executor (still running before the stop)" pass \
  || assert "U1: engine alive before stop=$_engine_alive, quota waits=$(tele quota_pause_end 1), QA attempts=$_att, quota lines=$(n_fixed "$ARM_PHRASE" "$ENG_LOG")" fail
slept_ok "$(tele quota_pause_end 1 sleep_seconds)" \
  && gap_ge "$SNAP_DIR/$UP-qa-1.snap" "$SNAP_DIR/$UP-qa-2.snap" $((WAIT_S - 1)) \
  && gap_ge "$SNAP_DIR/$UP-qa-2.snap" "$SNAP_DIR/$UP-qa-3.snap" $((WAIT_S - 1)) \
  && assert "U2: no busy loop — every re-dispatch came after a real quota wait (≥$((WAIT_S - 1))s)" pass \
  || assert "U2: wait spacing (slept='$(tele quota_pause_end 1 sleep_seconds)')" fail
[[ "$(n_line 'coherence-auditor 1')" == "0" && "$(n_line 'goal-evaluator 1')" == "0" \
   && ! -e "$ENG_SESSION/iter-1/coherence.md" && ! -e "$ENG_SESSION/iter-1/eval.md" && ! -e "$ENG_SESSION/iter-1/.evaluated" ]] \
  && assert "U3: no coherence auditor, no evaluator, and no fabricated COHERENCE-PASS crash stub or eval artifact for the unfinished iteration" pass \
  || assert "U3: downstream while unresolved (coh=$(n_line 'coherence-auditor 1') eval=$(n_line 'goal-evaluator 1') coherence.md=$([[ -e "$ENG_SESSION/iter-1/coherence.md" ]] && head -n 3 "$ENG_SESSION/iter-1/coherence.md" | tr '\n' ' ' || echo absent))" fail
[[ "$(sess current_iter)" == "1" && "$(sess last_verdict)" == "CONTINUE" && "$(pushed_iter fu 1)" == "0" && "$(tele iter_end 1)" == "0" ]] \
  && assert "U4: current_iter unchanged (1), last_verdict still iteration 0's, iteration 1 not pushed, no iter_end" pass \
  || assert "U4: state (iter=$(sess current_iter) verdict=$(sess last_verdict) pushed=$(pushed_iter fu 1) iter_end=$(tele iter_end 1))" fail
[[ "$(sess status)" == "ABORTED" && "$(phase_step "$UP")" == "review_passed" ]] && grep -qF 'Aborted by user signal' "$ENG_LOG" \
   && ! grep -qF 'treating as ABORTED' "$ENG_LOG" \
  && assert "U5: only the /goal-pause SIGTERM ended the wait — resumable ABORTED, run-phase checkpoint still review_passed" pass \
  || assert "U5: stop state (status=$(sess status) step=$(phase_step "$UP") signal-stop=$(n_fixed 'Aborted by user signal' "$ENG_LOG") evaluator-abort=$(n_fixed 'treating as ABORTED' "$ENG_LOG") rc=$ENG_RC)" fail

# ══ R. quota cleared → --resume re-runs the SAME iteration from its checkpoint ═
echo "── R: quota cleared, --resume ──"
rm -f "$WORK/u-quota-all"
run_engine fu resume 2 STUB_QUOTA_ALL="$WORK/u-quota-all"
segment_after_resume "$CANARY" > "$WORK/canary-fu-resume.log"
segment_after_resume "$ENG_LOG" > "$WORK/eng-fu-resume.log"
RC_="$WORK/canary-fu-resume.log"; RL_="$WORK/eng-fu-resume.log"
grep -q "Resuming session 'fu' from iter 1" "$RL_" && grep -qF 'RESUMING from checkpoint: review_passed' "$RL_" \
   && [[ "$(n_line 'orchestrator 1' "$RC_")" == "0" && "$(n_line 'dev-phase.sh 1' "$RC_")" == "0" && "$(n_line 'review-phase.sh 1' "$RC_")" == "0" && "$(n_line 'qa-phase.sh 1' "$RC_")" == "1" ]] \
  && assert "R1: resume re-ran iteration 1 from run-phase's review_passed checkpoint (no plan/dev/review redo; one fanout)" pass \
  || assert "R1: resume path (orchestrator=$(n_line 'orchestrator 1' "$RC_") dev=$(n_line 'dev-phase.sh 1' "$RC_") review=$(n_line 'review-phase.sh 1' "$RC_") qa=$(n_line 'qa-phase.sh 1' "$RC_"))" fail
_cl="$(first_at 'phase-closure-check.sh 1' "$RC_")"; _co="$(first_at 'coherence-auditor 1' "$RC_")"; _ev="$(first_at 'goal-evaluator 1' "$RC_")"
[[ -n "$_cl" && -n "$_co" && -n "$_ev" && "$_cl" -lt "$_co" && "$_co" -lt "$_ev" \
   && "$(n_line 'coherence-auditor 1' "$RC_")" == "1" && "$(n_line 'goal-evaluator 1' "$RC_")" == "1" ]] \
  && assert "R2: coherence auditor and evaluator ran once each, only after the resumed executor completed" pass \
  || assert "R2: ordering after resume (closure=${_cl:-none} coherence=${_co:-none} evaluator=${_ev:-none})" fail
[[ "$(sess current_iter)" == "2" && "$(sess last_verdict)" == "CONTINUE" && "$(sess status)" == "BUDGET_EXHAUSTED" \
   && "$(pushed_iter fu 1)" == "1" && "$(phase_step "$UP")" == "closure_passed" ]] \
  && assert "R3: only then was iteration 1 advanced and pushed (current_iter 2, closure_passed)" pass \
  || assert "R3: final state (iter=$(sess current_iter) verdict=$(sess last_verdict) status=$(sess status) pushed=$(pushed_iter fu 1) step=$(phase_step "$UP") rc=$ENG_RC)" fail

# ══ D. CHAIN_DISABLE_AUTO_WAIT=true: fail fast, resumably, without evaluating ══
echo "── D: auto-wait disabled — the QA agent refuses at iteration 0 ──"
printf '2\n' > "$WORK/d-count"     # finite, so code that waited anyway would still finish
run_engine fd fresh 1 CHAIN_DISABLE_AUTO_WAIT=true STUB_QUOTA_AGENT=qa STUB_QUOTA_ITER=0 STUB_QUOTA_COUNT="$WORK/d-count"
DP="goal-fd-iter-0"
[[ "$(n_line 'quota qa 0' "$CANARY.quota")" -ge 1 ]] && grep -qF 'CHAIN_DISABLE_AUTO_WAIT=true — not retrying.' "$ENG_LOG" \
   && [[ "$(n_fixed "Fanout (Step 4-7/11) hit quota (exit $RC75)" "$ENG_LOG")" -ge 1 ]] \
  && assert "D1: (seam) the wrapper failed fast and the fanout delivered $RC75 to the engine" pass \
  || assert "D1: (seam) fail-fast quota path (refusals=$(n_line 'quota qa 0' "$CANARY.quota"))" fail
[[ "$(n_grep "^\[run-phase\]   Phase: $DP\$" "$ENG_LOG")" == "1" && "$(tele quota_pause_start 0)" == "0" ]] \
  && assert "D2: the engine honoured CHAIN_DISABLE_AUTO_WAIT — no quota wait, no re-dispatch" pass \
  || assert "D2: waits=$(tele quota_pause_start 0) executor dispatches=$(n_grep "^\[run-phase\]   Phase: $DP\$" "$ENG_LOG")" fail
[[ "$ENG_RC" -eq "$RC75" && "$(sess status)" == "ABORTED" && "$(n_line 'goal-evaluator 0')" == "0" && "$(sess current_iter)" == "0" \
   && "$(pushed_iter fd 0)" == "0" && "$(phase_step "$DP")" == "review_passed" && " $(tele engine_step 0 step) " == *" full-pipeline "* ]] \
   && grep -qE '"reason": *"QUOTA_EXHAUSTED"' "$ENG_SESSION/telemetry.jsonl" 2>/dev/null \
  && assert "D3: resumable ABORTED stop (exit $RC75, halt QUOTA_EXHAUSTED, full-pipeline wall time recorded) — not evaluated, not advanced, not pushed, checkpoint review_passed" pass \
  || assert "D3: stop state (rc=$ENG_RC status=$(sess status) eval=$(n_line 'goal-evaluator 0') iter=$(sess current_iter) pushed=$(pushed_iter fd 0) step=$(phase_step "$DP"))" fail

# ══ X. reserved halts outrank a simultaneous quota exit ══════════════════════
for _rx in "$RC79" "$RC78" "$RC70"; do
  echo "── X$_rx: Branch UI exits $_rx while Branch QA hits quota ──"
  printf '99\n' > "$WORK/x-count-$_rx"
  run_engine "fx$_rx" fresh 1 STUB_BQA_EXIT="$_rx" STUB_QUOTA_AGENT=qa STUB_QUOTA_ITER=0 STUB_QUOTA_COUNT="$WORK/x-count-$_rx"
  case "$_rx" in
    "$RC79") _want_status=GATE_BLOCKED;  _want_reason='"reason": *"GATE_BLOCKED_BROWSER_EVIDENCE"' ;;
    "$RC78") _want_status=GATE_BLOCKED;  _want_reason='"reason": *"GATE_BLOCKED_SPEC_FIELD_UNAVAILABLE"' ;;
    *)       _want_status=AWAITING_PUMP; _want_reason='"reason": *"AWAITING_PUMP", *"detected_at_step": *"executor"' ;;
  esac
  grep -qF "reserved lifecycle halt ([Branch-UI]=$_rx [Branch-QA]=$RC75) — exiting $_rx" "$ENG_LOG" && [[ "$(n_line 'quota qa 0' "$CANARY.quota")" == "1" ]] \
    && assert "X$_rx.1: (seam) the fanout saw both — Branch UI $_rx and Branch QA quota $RC75 — and kept $_rx" pass \
    || assert "X$_rx.1: (seam) collision (QA refusals=$(n_line 'quota qa 0' "$CANARY.quota"))" fail
  [[ "$(n_grep "^\[run-phase\]   Phase: goal-fx$_rx-iter-0\$" "$ENG_LOG")" == "1" && "$(tele quota_pause_start 0)" == "0" && "$(n_fixed "$ARM_PHRASE" "$ENG_LOG")" == "0" ]] \
    && assert "X$_rx.2: one executor dispatch and no quota wait — the reserved halt is not retried as quota" pass \
    || assert "X$_rx.2: dispatches=$(n_grep "^\[run-phase\]   Phase: goal-fx$_rx-iter-0\$" "$ENG_LOG") quota waits=$(tele quota_pause_start 0)" fail
  [[ "$(sess status)" == "$_want_status" && "$(n_line 'goal-evaluator 0')" == "0" && "$(sess current_iter)" == "0" ]] \
     && grep -qE "$_want_reason" "$ENG_SESSION/telemetry.jsonl" 2>/dev/null \
    && assert "X$_rx.3: the existing top-level halt fired ($_want_status), no evaluator, current_iter 0" pass \
    || assert "X$_rx.3: halt (status=$(sess status) eval=$(n_line 'goal-evaluator 0') iter=$(sess current_iter) rc=$ENG_RC)" fail
done

# ══ L. lean control: the FULL handling does not touch the lean executor ══════
echo "── L: lean developer quota exit ──"
printf '1\n' > "$WORK/l-count"
run_engine fl fresh 1 STUB_SPEC_DEPTH=lean STUB_QUOTA_AGENT=developer STUB_QUOTA_ITER=0 STUB_QUOTA_COUNT="$WORK/l-count"
[[ "$(n_fixed 'Dispatching LEAN pipeline via goal-iter-lean.sh' "$ENG_LOG")" == "1" && "$(n_line 'quota developer 0' "$CANARY.quota")" == "1" \
   && "$(n_line 'developer 0')" == "1" && "$(n_line 'reviewer 0')" == "0" && "$(n_line 'browser-qa-agent 0')" == "0" ]] \
  && assert "L1: (seam) the lean executor stopped at its quota-refused developer (goal-iter-lean.sh exit $RC75)" pass \
  || assert "L1: (seam) lean quota exit (dispatches=$(n_fixed 'Dispatching LEAN pipeline via goal-iter-lean.sh' "$ENG_LOG") refusals=$(n_line 'quota developer 0' "$CANARY.quota") dev=$(n_line 'developer 0') rev=$(n_line 'reviewer 0'))" fail
[[ "$(n_grep '^\[run-phase\]   Phase: ' "$ENG_LOG")" == "0" && "$(tele quota_pause_start 0)" == "0" && "$(n_fixed "$ARM_PHRASE" "$ENG_LOG")" == "0" ]] \
  && assert "L2: the FULL quota handling did not engage for lean — no run-phase.sh, no quota wait, no re-dispatch" pass \
  || assert "L2: FULL handling leaked into lean (run-phase runs=$(n_grep '^\[run-phase\]   Phase: ' "$ENG_LOG") waits=$(tele quota_pause_start 0))" fail
[[ "$(n_line 'goal-evaluator 0')" == "1" && "$(sess current_iter)" == "1" ]] \
  && assert "L3: PINNED pre-existing lean behaviour — after the lean quota exit the engine still proceeds to the evaluator (no lean rc-$RC75 handling; recorded debt)" pass \
  || assert "L3: pinned lean behaviour changed (eval=$(n_line 'goal-evaluator 0') iter=$(sess current_iter) status=$(sess status))" fail

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
