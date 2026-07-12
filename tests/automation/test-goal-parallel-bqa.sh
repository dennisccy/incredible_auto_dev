#!/usr/bin/env bash
# test-goal-parallel-bqa.sh — end-to-end wiring test for SPEED-2: the parallel
# review ∥ browser-qa "replay" fork in goal-iter-lean.sh, behind the
# default-off knob CHAIN_LEAN_PARALLEL_BROWSER_QA.
#
# Drives the REAL goal-iter-lean.sh in a sandbox repo (modeled on
# test-goal-checkpoints.sh) with a role-aware stub `claude` on PATH, a stub
# demo_runner.py (replay lane), and dummy HTTP services on test ports so the
# service boot takes its already-healthy fast path. Scenarios:
#   A. knob unset (default off) → sequential path: NO fork artifacts, the
#      exact pre-change artifact tree, dispatch order unchanged.
#   B. replay + review PASS → fork ran (PID file, isolated agent name in
#      telemetry), join consumed its state, the LLM lane's target set is
#      IDENTICAL to scenario A's for the same inputs (replay-FAIL re-confirm
#      included), and the merged results rows match A's.
#   C. replay + review-1 FAIL, slow replay lane → CRITICAL ORDERING: the fork
#      is killed and waited DEAD (TERM stamp from inside demo_runner), its
#      lane files discarded, all BEFORE step_invalidate_from — and no lane
#      file exists post-invalidation (nor after a settle window).
#   D. tripwire: telemetry seeded with attempt-1 review FAILs in 2 of the last
#      3 iterations → fork skipped, decision persisted under state/, the
#      iter_config event says so, and the NEXT iteration stays skipped.
#   E. knob=full → logged warning ("full is SPEED-3"), behaves as replay.
#
# No API calls; a few seconds per scenario.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BE_PORT=48331
FE_PORT=48332

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}

WORK="$(mktemp -d)"
DUMMY_PIDS=()
cleanup() {
  for p in ${DUMMY_PIDS[@]+"${DUMMY_PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done
  fuser -k "${BE_PORT}/tcp" "${FE_PORT}/tcp" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── Sandbox builder (fresh per scenario; engine scripts embedded) ────────────
# Sets: SBX, ITER, ITER_DIR, DEV_HANDOFF, REVIEW_REPORT, UI_TEST_RESULTS,
# REGRESSION_RESULTS and exports the session env goal-iter-lean.sh expects.
make_sandbox() {
  local tag="$1"
  SBX="$WORK/proj-$tag"
  mkdir -p "$SBX"
  cp -r "$ENGINE_ROOT/scripts" "$SBX/"
  mkdir -p "$SBX/docs/phases" "$SBX/docs/handoffs" "$SBX/reports/reviews" "$SBX/src"
  git init -q "$SBX"
  echo "print('v1')" > "$SBX/src/app.py"
  cat > "$SBX/docs/goal.md" <<'EOF'
# Goal
## Must-have user journeys
- J-01: open the page. Acceptance: page loads.
- J-02: add an item. Acceptance: item appears.
## Anti-goals
- none
EOF
  ITER="goal-pbtest-iter-1"
  write_iter_spec 1
  git -C "$SBX" add -A
  git -C "$SBX" -c user.email=t@t -c user.name=t commit -qm base

  export GOAL_SESSION_DIR="$SBX/runs/goal-session-pbtest"
  set_iter 1
  # Golden replay script on file for J-01 → the replay lane engages.
  mkdir -p "$GOAL_SESSION_DIR/journey-scripts"
  echo '{"journey":"J-01","steps":[]}' > "$GOAL_SESSION_DIR/journey-scripts/J-01.json"

  # Stub demo_runner (replay lane): lint says every golden is ok; verify writes
  # a results table per STUB_REPLAY_VERDICT (exit 0 PASS / 5 FAIL), optionally
  # sleeping first, stamping start + TERM-kill files for ordering proofs.
  cat > "$SBX/scripts/automation/lib/demo_runner.py" <<'PYEOF'
#!/usr/bin/env python3
import os, signal, sys, time

def arg(name, default=""):
    if name in sys.argv:
        i = sys.argv.index(name)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default

mode = arg("--mode", "record")
journeys = [j for j in arg("--journeys").replace(",", " ").split() if j]

if mode == "lint":
    for j in journeys:
        print(f"{j} ok")
    sys.exit(0)

if mode == "verify":
    started = os.environ.get("STUB_REPLAY_STARTED_STAMP", "")
    if started:
        with open(started, "w") as f:
            f.write(str(os.getpid()))
    killed = os.environ.get("STUB_REPLAY_KILLED_STAMP", "")
    if killed:
        def on_term(signum, frame):
            with open(killed, "w") as f:
                f.write("TERM")
            sys.exit(143)
        signal.signal(signal.SIGTERM, on_term)
    time.sleep(float(os.environ.get("STUB_REPLAY_SLEEP", "0")))
    verdict = os.environ.get("STUB_REPLAY_VERDICT", "PASS")
    results = arg("--results")
    if results:
        rows = "\n".join(
            f"| UT-{j} | replay {j} | journey | P1 | works | stub says {verdict.lower()} | {verdict} | none |"
            for j in journeys)
        with open(results, "w") as f:
            f.write(f"**Browser QA Verdict:** {verdict}\n\n"
                    "| Test ID | Name | Type | Prio | Expected | Actual | Verdict | Evidence |\n"
                    "|---|---|---|---|---|---|---|---|\n" + rows + "\n")
    sys.exit(0 if verdict == "PASS" else 5)

sys.exit(0)
PYEOF
}

write_iter_spec() {
  local n="$1"
  cat > "$SBX/docs/phases/goal-pbtest-iter-$n.md" <<'EOF'
# Iteration spec
## Goal Mode Metadata
- **Mode:** next
- **Depth:** lean
- **Target journeys:** J-02
- **Required-still-passing:** J-01
## IN SCOPE
- add an item (parallel-bqa wiring test)
EOF
}

set_iter() {
  local n="$1"
  ITER="goal-pbtest-iter-$n"
  export GOAL_ITER_INDEX="$n"
  export GOAL_ITER_NAME="$ITER"
  ITER_DIR="$GOAL_SESSION_DIR/iter-$n"
  mkdir -p "$ITER_DIR"
  DEV_HANDOFF="$SBX/docs/handoffs/${ITER}-dev.md"
  REVIEW_REPORT="$SBX/reports/reviews/${ITER}-review.md"
  UI_TEST_RESULTS="$SBX/reports/phase-${ITER}-ui-test-results.md"
  REGRESSION_RESULTS="$SBX/reports/phase-${ITER}-regression-replay-results.md"
}

# ── Role-aware stub claude (keyed on CHAIN_CURRENT_AGENT, env-driven) ────────
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<'EOF'
#!/usr/bin/env bash
agent="${CHAIN_CURRENT_AGENT:-unknown}"
prompt="$*"
echo "$agent" >> "$CANARY"
n="$(wc -l < "$CANARY")"
printf '%s\n' "$prompt" > "$PROMPTS_DIR/prompt-${n}-${agent}.txt"
case "$agent" in
  developer)
    if [[ "$prompt" == *"FIX MODE"* && -n "${STUB_DEV_FIX_RC:-}" ]]; then exit "$STUB_DEV_FIX_RC"; fi
    out="$(printf '%s\n' "$prompt" | sed -n 's/^- Write dev handoff to: //p' | head -n1)"
    [[ -n "$out" ]] || exit 64
    echo "print('v2 built by stub')" > src/app.py
    printf 'handoff: implemented the iter spec (stub).\n' > "$out"
    exit 0 ;;
  reviewer)
    if [[ -n "${STUB_REVIEW_WAIT_FOR:-}" ]]; then
      w=0; while [[ ! -f "$STUB_REVIEW_WAIT_FOR" && $w -lt 100 ]]; do sleep 0.2; w=$((w+1)); done
    fi
    out="$(printf '%s\n' "$prompt" | sed -n 's/^Write your review report to: //p' | head -n1)"
    [[ -n "$out" ]] || exit 64
    printf '**Verdict:** %s\n\nStub review.\n' "${STUB_REVIEW_VERDICT:-PASS}" > "$out"
    exit 0 ;;
  browser-qa-agent)
    out="$(printf '%s\n' "$prompt" | sed -n 's/^Write your results to: //p' | head -n1)"
    [[ -n "$out" ]] || exit 64
    line="$(printf '%s\n' "$prompt" | sed -n 's/^GOAL-MODE LEAN MODE — test EXACTLY these journeys this run: //p' | head -n1)"
    journeys="$(printf '%s\n' "$line" | grep -oE 'J-[0-9]+' | sort -u | tr '\n' ' ' || true)"
    {
      printf '**Browser QA Verdict:** PASS\n\n'
      printf '| Test ID | Name | Type | Prio | Expected | Actual | Verdict | Evidence |\n'
      printf '|---|---|---|---|---|---|---|---|\n'
      for j in $journeys; do
        printf '| UT-%s | llm %s | journey | P1 | works | stub verified | PASS | none |\n' "$j" "$j"
      done
    } > "$out"
    exit 0 ;;
esac
exit 70
EOF
chmod +x "$STUB_DIR/claude"

# ── Dummy services on the test ports (already-healthy fast path) ─────────────
SRV_DIR="$WORK/srv"
mkdir -p "$SRV_DIR"
start_dummies() {
  local p
  for p in "$BE_PORT" "$FE_PORT"; do
    if ! curl -s -o /dev/null "http://localhost:${p}/"; then
      ( cd "$SRV_DIR" && exec python3 -m http.server "$p" ) >/dev/null 2>&1 &
      DUMMY_PIDS+=("$!")
    fi
  done
  for p in "$BE_PORT" "$FE_PORT"; do
    local i
    for i in $(seq 1 50); do
      curl -s -o /dev/null "http://localhost:${p}/" && break
      sleep 0.1
    done
  done
}

export CHAIN_BACKEND_PORT="$BE_PORT"
export CHAIN_FRONTEND_PORT="$FE_PORT"
export CHAIN_KILL_GRACE_SECONDS=1

# run_lean [env overrides via pre-exported STUB_*/knob]; stdout+stderr → $1
# Re-ensures the dummy services first: every lean exit port-kills them
# (cleanup_iter_servers), and a run without them would spin the real
# service-boot retry ladder for minutes.
run_lean() {
  local log="$1"
  start_dummies
  export CANARY PROMPTS_DIR
  ( cd "$SBX" && PATH="$STUB_DIR:$PATH" bash scripts/automation/goal-iter-lean.sh "$ITER" ) >"$log" 2>&1
}

new_capture() {
  CANARY="$WORK/canary-$1.log"; : > "$CANARY"
  PROMPTS_DIR="$WORK/prompts-$1"; mkdir -p "$PROMPTS_DIR"
}

llm_journeys_line() {  # the LLM lane's exact target-set line from the captured prompt
  grep -h '^GOAL-MODE LEAN MODE — test EXACTLY these journeys this run:' "$1"/prompt-*-browser-qa-agent.txt 2>/dev/null | head -n1
}

artifact_tree() {  # product-relative artifact list (scripts/ + .git/ excluded)
  ( cd "$SBX" && find . -type f -not -path './.git/*' -not -path './scripts/*' | sort )
}

# ══ Scenario A: knob unset (default off) — sequential, no fork artifacts ═════
make_sandbox A
new_capture A
start_dummies
unset CHAIN_LEAN_PARALLEL_BROWSER_QA 2>/dev/null || true
export STUB_REPLAY_VERDICT=FAIL   # replay flags J-01 → LLM re-confirms it (both scenarios)
rc=0; run_lean "$WORK/lean-A.log" || rc=$?
[[ "$rc" -eq 0 ]] && assert "A: off-mode lean iteration exits 0" "pass" \
  || { assert "A: off-mode lean iteration exits 0 (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/lean-A.log"; }
if ls "$ITER_DIR"/.bqa-replay-* >/dev/null 2>&1; then
  assert "A: no fork artifacts in off mode ($(ls "$ITER_DIR"/.bqa-replay-* | tr '\n' ' '))" "fail"
else
  assert "A: no fork artifacts in off mode" "pass"
fi
grep -q "Forking browser-qa service boot" "$WORK/lean-A.log" \
  && assert "A: off mode never forks" "fail" || assert "A: off mode never forks" "pass"
[[ "$(tr '\n' ' ' < "$CANARY")" == "developer reviewer browser-qa-agent " ]] \
  && assert "A: dispatch order developer→reviewer→browser-qa unchanged" "pass" \
  || assert "A: dispatch order developer→reviewer→browser-qa unchanged (got: $(tr '\n' ' ' < "$CANARY"))" "fail"
# The exact sequential artifact tree (verified pre-change against HEAD by the
# SPEED-2 snapshot proof) — a drift here means off mode is no longer identical.
EXPECTED_TREE="./docs/goal.md
./docs/handoffs/${ITER}-dev.md
./docs/phases/${ITER}.md
./reports/phase-${ITER}-regression-replay-results.md
./reports/phase-${ITER}-ui-test-results.llm.md
./reports/phase-${ITER}-ui-test-results.md
./reports/reviews/${ITER}-review.md
./runs/goal-session-pbtest/iter-1/.steps/browser-qa.done
./runs/goal-session-pbtest/iter-1/.steps/developer.done
./runs/goal-session-pbtest/iter-1/.steps/review-1.done
./runs/goal-session-pbtest/journey-scripts/J-01.json
./runs/goal-session-pbtest/telemetry.jsonl
./src/app.py"
if [[ "$(artifact_tree)" == "$EXPECTED_TREE" ]]; then
  assert "A: artifact tree identical to the pre-change sequential run" "pass"
else
  assert "A: artifact tree identical to the pre-change sequential run" "fail"
  diff <(printf '%s\n' "$EXPECTED_TREE") <(artifact_tree) | sed 's/^/        /'
fi
grep -q '"event":"iter_config"' "$GOAL_SESSION_DIR/telemetry.jsonl" \
  && grep -q '"key":"CHAIN_LEAN_PARALLEL_BROWSER_QA","value":"off"' "$GOAL_SESSION_DIR/telemetry.jsonl" \
  && assert "A: iter_config telemetry names the knob state (off)" "pass" \
  || assert "A: iter_config telemetry names the knob state (off)" "fail"
A_LLM_LINE="$(llm_journeys_line "$PROMPTS_DIR")"
[[ "$A_LLM_LINE" == *"J-01"* && "$A_LLM_LINE" == *"J-02"* ]] \
  && assert "A: LLM lane covers target + replay-FAIL re-confirm (J-01 J-02)" "pass" \
  || assert "A: LLM lane covers target + replay-FAIL re-confirm (got: $A_LLM_LINE)" "fail"
A_ROWS="$(grep -E '^\| UT-' "$UI_TEST_RESULTS" 2>/dev/null | sort)"

# ══ Scenario B: replay + review PASS — fork, join, identical LLM target set ══
make_sandbox B
new_capture B
start_dummies
export CHAIN_LEAN_PARALLEL_BROWSER_QA=replay
rc=0; run_lean "$WORK/lean-B.log" || rc=$?
[[ "$rc" -eq 0 ]] && assert "B: replay-mode lean iteration exits 0" "pass" \
  || { assert "B: replay-mode lean iteration exits 0 (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/lean-B.log"; }
grep -q "Forking browser-qa service boot + replay lane" "$WORK/lean-B.log" \
  && assert "B: fork launched" "pass" || assert "B: fork launched" "fail"
[[ -s "$ITER_DIR/.bqa-replay-pid" ]] \
  && assert "B: fork PID file written" "pass" || assert "B: fork PID file written" "fail"
grep -q "Consumed forked replay-lane results" "$WORK/lean-B.log" \
  && assert "B: join consumed the fork's results" "pass" \
  || assert "B: join consumed the fork's results" "fail"
[[ ! -f "$ITER_DIR/.bqa-replay-state" && ! -f "$ITER_DIR/.bqa-replay-rc" ]] \
  && assert "B: state/rc files cleaned after consume" "pass" \
  || assert "B: state/rc files cleaned after consume" "fail"
grep -q '"agent":"browser-qa-replay"' "$GOAL_SESSION_DIR/telemetry.jsonl" \
  && assert "B: fork telemetry attributed to the isolated agent name" "pass" \
  || assert "B: fork telemetry attributed to the isolated agent name" "fail"
[[ "$(tr '\n' ' ' < "$CANARY")" == "developer reviewer browser-qa-agent " ]] \
  && assert "B: fork dispatches no claude (canary unchanged)" "pass" \
  || assert "B: fork dispatches no claude (got: $(tr '\n' ' ' < "$CANARY"))" "fail"
B_LLM_LINE="$(llm_journeys_line "$PROMPTS_DIR")"
[[ -n "$B_LLM_LINE" && "$B_LLM_LINE" == "$A_LLM_LINE" ]] \
  && assert "B: LLM-lane target set identical to the sequential run's" "pass" \
  || assert "B: LLM-lane target set identical to the sequential run's (A='$A_LLM_LINE' B='$B_LLM_LINE')" "fail"
B_ROWS="$(grep -E '^\| UT-' "$UI_TEST_RESULTS" 2>/dev/null | sort)"
[[ -n "$B_ROWS" && "$B_ROWS" == "$A_ROWS" ]] \
  && assert "B: merged results rows identical to the sequential run's" "pass" \
  || assert "B: merged results rows identical to the sequential run's" "fail"
grep -q '"key":"CHAIN_LEAN_PARALLEL_BROWSER_QA","value":"replay"' "$GOAL_SESSION_DIR/telemetry.jsonl" \
  && assert "B: iter_config telemetry names the knob state (replay)" "pass" \
  || assert "B: iter_config telemetry names the knob state (replay)" "fail"

# ══ Scenario C: replay + review-1 FAIL — kill+wait BEFORE invalidation ═══════
make_sandbox C
new_capture C
start_dummies
export CHAIN_LEAN_PARALLEL_BROWSER_QA=replay
export STUB_REPLAY_VERDICT=PASS
export STUB_REPLAY_SLEEP=30
export STUB_REPLAY_STARTED_STAMP="$WORK/replay-started.stamp"
export STUB_REPLAY_KILLED_STAMP="$WORK/replay-killed.stamp"
export STUB_REVIEW_WAIT_FOR="$STUB_REPLAY_STARTED_STAMP"   # review FAIL lands only once the lane is mid-flight
export STUB_REVIEW_VERDICT=FAIL
export STUB_DEV_FIX_RC=70   # fix-mode developer "pauses" → script exits right after the invalidation point
rc=0; run_lean "$WORK/lean-C.log" || rc=$?
[[ "$rc" -eq 70 ]] && assert "C: fix-mode transport pause exits 70" "pass" \
  || { assert "C: fix-mode transport pause exits 70 (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/lean-C.log"; }
[[ -f "$STUB_REPLAY_STARTED_STAMP" ]] \
  && assert "C: replay lane was mid-flight when review failed" "pass" \
  || assert "C: replay lane was mid-flight when review failed" "fail"
[[ -f "$STUB_REPLAY_KILLED_STAMP" ]] \
  && assert "C: fork killed mid-sleep (TERM reached demo_runner)" "pass" \
  || assert "C: fork killed mid-sleep (TERM reached demo_runner)" "fail"
grep -q "Reaping the forked replay lane" "$WORK/lean-C.log" \
  && grep -q "lane files are discarded — safe to invalidate" "$WORK/lean-C.log" \
  && assert "C: kill+wait+discard logged before invalidation" "pass" \
  || assert "C: kill+wait+discard logged before invalidation" "fail"
# The reap lines must appear BEFORE the fix-mode developer dispatch output.
_reap_ln="$(grep -n "lane files are discarded" "$WORK/lean-C.log" | head -1 | cut -d: -f1 || true)"
_fix_ln="$(grep -n "Review FAIL — running developer in fix mode" "$WORK/lean-C.log" | head -1 | cut -d: -f1 || true)"
[[ -n "$_reap_ln" && -n "$_fix_ln" ]] && [[ "$_fix_ln" -lt "$_reap_ln" ]] \
  && assert "C: reap completes inside the FAIL branch (after its banner, before the fix dispatch)" "pass" \
  || assert "C: reap completes inside the FAIL branch (banner=$_fix_ln reap=$_reap_ln)" "fail"
sleep 2   # settle window: a survivor would land its late write here
[[ ! -f "$REGRESSION_RESULTS" ]] \
  && assert "C: no lane results file exists post-invalidation (incl. settle window)" "pass" \
  || assert "C: no lane results file exists post-invalidation" "fail"
[[ ! -f "$ITER_DIR/.bqa-replay-state" && ! -f "$ITER_DIR/.bqa-replay-rc" ]] \
  && assert "C: fork state/rc files discarded by the reap" "pass" \
  || assert "C: fork state/rc files discarded by the reap" "fail"
grep -qx "browser-qa-agent" "$CANARY" \
  && assert "C: no browser-qa dispatch after the pause" "fail" \
  || assert "C: no browser-qa dispatch after the pause" "pass"
unset STUB_REPLAY_SLEEP STUB_REPLAY_STARTED_STAMP STUB_REPLAY_KILLED_STAMP \
      STUB_REVIEW_WAIT_FOR STUB_REVIEW_VERDICT STUB_DEV_FIX_RC

# ══ Scenario D: tripwire — 2 of last 3 iterations FAILed review attempt 1 ════
make_sandbox D
new_capture D
start_dummies
export CHAIN_LEAN_PARALLEL_BROWSER_QA=replay
export STUB_REPLAY_VERDICT=PASS
# Seed telemetry the way goal-iter-lean.sh writes review_verdict events
# (payload merged at top level).
cat > "$GOAL_SESSION_DIR/telemetry.jsonl" <<'EOF'
{"verdict":"FAIL","attempt":1,"iter_name":"goal-pbtest-iter-90","ts":"2026-07-11T00:00:00Z","session_id":"pbtest","iter":90,"event":"review_verdict","cli":"claude"}
{"verdict":"PASS","attempt":2,"iter_name":"goal-pbtest-iter-90","ts":"2026-07-11T00:10:00Z","session_id":"pbtest","iter":90,"event":"review_verdict","cli":"claude"}
{"verdict":"PASS","attempt":1,"iter_name":"goal-pbtest-iter-91","ts":"2026-07-11T01:00:00Z","session_id":"pbtest","iter":91,"event":"review_verdict","cli":"claude"}
{"verdict":"FAIL","attempt":1,"iter_name":"goal-pbtest-iter-92","ts":"2026-07-11T02:00:00Z","session_id":"pbtest","iter":92,"event":"review_verdict","cli":"claude"}
EOF
rc=0; run_lean "$WORK/lean-D1.log" || rc=$?
[[ "$rc" -eq 0 ]] && assert "D: tripped iteration still completes sequentially (exit 0)" "pass" \
  || { assert "D: tripped iteration still completes sequentially (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/lean-D1.log"; }
grep -q "SPEED-2 tripwire TRIPPED" "$WORK/lean-D1.log" \
  && assert "D: tripwire tripped on 2-of-3 attempt-1 FAILs" "pass" \
  || assert "D: tripwire tripped on 2-of-3 attempt-1 FAILs" "fail"
[[ -s "$GOAL_SESSION_DIR/state/parallel-bqa-disabled" ]] \
  && assert "D: decision persisted (state/parallel-bqa-disabled)" "pass" \
  || assert "D: decision persisted (state/parallel-bqa-disabled)" "fail"
grep -q "Forking browser-qa service boot" "$WORK/lean-D1.log" \
  && assert "D: fork skipped when tripped" "fail" || assert "D: fork skipped when tripped" "pass"
grep -q '"key":"CHAIN_LEAN_PARALLEL_BROWSER_QA","value":"off","requested":"replay","reason":"tripwire"' \
    "$GOAL_SESSION_DIR/telemetry.jsonl" \
  && assert "D: iter_config records off/tripwire" "pass" \
  || assert "D: iter_config records off/tripwire" "fail"
# Next iteration in the SAME session: the persisted state keeps the fork off.
write_iter_spec 2
git -C "$SBX" add docs/phases >/dev/null 2>&1 && git -C "$SBX" -c user.email=t@t -c user.name=t commit -qm iter2 >/dev/null 2>&1
set_iter 2
rc=0; run_lean "$WORK/lean-D2.log" || rc=$?
grep -q "SPEED-2 tripwire state present" "$WORK/lean-D2.log" \
  && assert "D: next iteration skips the fork via the persisted state file" "pass" \
  || assert "D: next iteration skips the fork via the persisted state file" "fail"
grep -q "Forking browser-qa service boot" "$WORK/lean-D2.log" \
  && assert "D: no fork for the rest of the session" "fail" \
  || assert "D: no fork for the rest of the session" "pass"

# ══ Scenario E: knob=full — warning, behaves as replay ═══════════════════════
make_sandbox E
new_capture E
start_dummies
export CHAIN_LEAN_PARALLEL_BROWSER_QA=full
export STUB_REPLAY_VERDICT=PASS
rc=0; run_lean "$WORK/lean-E.log" || rc=$?
[[ "$rc" -eq 0 ]] && assert "E: full-mode lean iteration exits 0" "pass" \
  || { assert "E: full-mode lean iteration exits 0 (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/lean-E.log"; }
grep -q "CHAIN_LEAN_PARALLEL_BROWSER_QA=full is SPEED-3 (not implemented); using replay" "$WORK/lean-E.log" \
  && assert "E: full logs the SPEED-3 warning" "pass" \
  || assert "E: full logs the SPEED-3 warning" "fail"
grep -q "Forking browser-qa service boot + replay lane" "$WORK/lean-E.log" \
  && grep -q "Consumed forked replay-lane results" "$WORK/lean-E.log" \
  && assert "E: full behaves as replay (fork + join)" "pass" \
  || assert "E: full behaves as replay (fork + join)" "fail"
grep -q '"value":"replay","requested":"full"' "$GOAL_SESSION_DIR/telemetry.jsonl" \
  && assert "E: iter_config records replay/requested=full" "pass" \
  || assert "E: iter_config records replay/requested=full" "fail"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
