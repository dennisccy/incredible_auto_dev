#!/usr/bin/env bash
# test-goal-parallel-bqa.sh — end-to-end wiring test for SPEED-2 + SPEED-3:
# the parallel review ∥ browser-qa forks in goal-iter-lean.sh ("replay" and
# "full" stages), behind the default-off knob CHAIN_LEAN_PARALLEL_BROWSER_QA.
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
#   E. SPEED-3 hard gate: knob=full + CHAIN_AGENT_BACKEND=interactive → logged
#      headless-only warning, behaves as replay, iter_config records
#      reason=interactive-backend (proven dispatch-free on a fully
#      checkpointed rerun so no pump handshake can hang the test).
#   F. SPEED-3 full + review PASS → the WHOLE section forked (the LLM dispatch
#      runs inside the fork WHILE review is still pending — witnessed), join
#      consumes + writes the browser-qa marker, final artifact tree and merged
#      rows IDENTICAL to sequential scenario A's.
#   G. SPEED-3 full + review-1 FAIL with the LLM dispatch IN FLIGHT → kill-
#      then-invalidate ordering, ZERO surviving fork processes (pgrep — the
#      SPEED-3 stop-and-ask trigger), all lane files (replay + LLM + merged)
#      discarded and none re-lands after a settle window, and the
#      parallel_bqa_wasted_dispatch cost event is recorded.
#   H. SPEED-3 full + transport 70 INSIDE the forked LLM lane → the join
#      re-raises the pause in the parent (exit 70) and the sandbox tree state
#      (file list + step markers) is IDENTICAL to the sequential rc-70 pause
#      tree; a follow-up run resumes: developer skips, browser-qa re-runs.
#   I. journey-less spec lines (every iteration-0 baseline spec says
#      "Required-still-passing journeys: none — ...") → the lean lane must
#      SURVIVE the journey-set parse and dispatch developer→reviewer→browser-qa.
#      Regression pin for the silent set -e + inherited-pipefail death that
#      killed BOTH benchmark iter-0 lean lanes (experiments.md POST
#      bench-20260713-2334): _spec_journeys' inner `grep -oE 'J-[0-9]+'` exits
#      1 on a journey-less line and, unguarded, the bare top-level assignment
#      kills the whole script before the developer step (pre-SPEED-2 position:
#      after review, killing browser-qa + coherence instead).
#   J. REL-12 single-service short-circuit: CHAIN_FRONTEND_URL pointing at the
#      dummy BACKEND port (the server-rendered-frontend case) → the direct
#      probe answers, ONE loud log line names the URL, the frontend boot and
#      readiness gate never run, and the dispatch prompt carries
#      "Frontend available: yes".
#   K. REL-5 flake discipline END-TO-END through the SPEED-2 fork: the forked
#      replay lane gets demo_runner rc=6 twice → exactly ONE retry (counter),
#      lane recorded SKIPPED-INFRA (raw artifact verdict line, fork state file
#      → the join's consume line is the reader-side proof, telemetry event),
#      whole required set falls back to the LLM lane, SKIPPED-INFRA never
#      enters the merged results file, missing-evidence tripwire stays silent,
#      browser-qa checkpoint marker carries the merged LLM PASS.
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
    # REL-5 knobs: per-invocation rc sequence via a counter file, so the lane's
    # retry semantics are provable across the fork boundary.
    seq = os.environ.get("STUB_REPLAY_RC_SEQ", "").split()
    if seq:
        attempt = 1
        cf = os.environ.get("STUB_REPLAY_COUNT_FILE", "")
        if cf:
            try:
                attempt = int(open(cf).read().strip() or "0") + 1
            except Exception:
                attempt = 1
            with open(cf, "w") as f:
                f.write(str(attempt))
        rc = seq[min(attempt, len(seq)) - 1]
        if rc == "6":
            # Mirror the real runner: a browser-infra crash still writes the
            # results file (SKIP rows naming the failure) before exiting 6.
            results = arg("--results")
            if results:
                rows = "\n".join(
                    f"| UT-{j} | replay {j} | journey | P1 | works | browser infrastructure failure: stub crash | SKIP | none |"
                    for j in journeys)
                with open(results, "w") as f:
                    f.write("**Browser QA Verdict:** SKIPPED\n\n"
                            "| Test ID | Name | Type | Prio | Expected | Actual | Verdict | Evidence |\n"
                            "|---|---|---|---|---|---|---|---|\n" + rows + "\n")
            sys.exit(6)
        if rc not in ("", "0"):
            sys.exit(int(rc))
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
      # Overlap witness: record whether the waited-for file EXISTED when the
      # wait ended (yes = the other lane was live mid-review; a timeout in a
      # buggy-sequential world records no).
      if [[ -n "${STUB_REVIEW_WITNESS:-}" ]]; then
        { [[ -f "$STUB_REVIEW_WAIT_FOR" ]] && echo yes || echo no; } > "$STUB_REVIEW_WITNESS"
      fi
    fi
    out="$(printf '%s\n' "$prompt" | sed -n 's/^Write your review report to: //p' | head -n1)"
    [[ -n "$out" ]] || exit 64
    printf '**Verdict:** %s\n\nStub review.\n' "${STUB_REVIEW_VERDICT:-PASS}" > "$out"
    exit 0 ;;
  browser-qa-agent)
    # SPEED-3 hooks: stamp when the dispatch STARTS (overlap/ordering proofs),
    # optionally hang mid-dispatch (kill-tree proof), optionally die with a
    # given rc BEFORE writing results (transport-70 pause proof).
    if [[ -n "${STUB_BQA_STARTED_STAMP:-}" ]]; then echo "$$" > "$STUB_BQA_STARTED_STAMP"; fi
    if [[ -n "${STUB_BQA_SLEEP:-}" ]]; then sleep "$STUB_BQA_SLEEP"; fi
    if [[ -n "${STUB_BQA_RC:-}" ]]; then exit "$STUB_BQA_RC"; fi
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

marker_field() {  # marker_field <iter-dir> <step> <field> — from a .steps marker
  jq -r --arg f "$3" '.[$f] // empty' "$1/.steps/$2.done" 2>/dev/null || true
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
# 2026-07-16: iter-1/review-packet.md added — the TOKEN-7 pre-baked review
# packet is built on the sequential path too (before the fork spawn point),
# so it belongs to the expected tree in every mode.
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
./runs/goal-session-pbtest/iter-1/review-packet.md
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

# ══ Scenario E: SPEED-3 hard gate — full + interactive backend → replay ═════
# Seed a fully-checkpointed iteration headless first, then re-run it with
# CHAIN_AGENT_BACKEND=interactive + knob=full: every step resume-skips, so the
# gate's parse-time decision is observable with ZERO dispatches (nothing can
# hang on a pump that does not exist).
make_sandbox E
new_capture E
start_dummies
unset CHAIN_LEAN_PARALLEL_BROWSER_QA 2>/dev/null || true
export STUB_REPLAY_VERDICT=PASS
rc=0; run_lean "$WORK/lean-E-seed.log" || rc=$?
[[ "$rc" -eq 0 ]] && assert "E: headless seed run exits 0" "pass" \
  || { assert "E: headless seed run exits 0 (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/lean-E-seed.log"; }
new_capture E2
start_dummies
export CHAIN_LEAN_PARALLEL_BROWSER_QA=full
export CHAIN_AGENT_BACKEND=interactive
rc=0; run_lean "$WORK/lean-E.log" || rc=$?
[[ "$rc" -eq 0 ]] && assert "E: interactive+full rerun exits 0" "pass" \
  || { assert "E: interactive+full rerun exits 0 (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/lean-E.log"; }
grep -q "CHAIN_LEAN_PARALLEL_BROWSER_QA=full is headless-only" "$WORK/lean-E.log" \
  && assert "E: interactive backend logs the headless-only warning" "pass" \
  || assert "E: interactive backend logs the headless-only warning" "fail"
grep -q '"value":"replay","requested":"full","reason":"interactive-backend"' "$GOAL_SESSION_DIR/telemetry.jsonl" \
  && assert "E: iter_config records replay/requested=full/reason=interactive-backend" "pass" \
  || assert "E: iter_config records replay/requested=full/reason=interactive-backend" "fail"
grep -q "Forking the FULL browser-qa section" "$WORK/lean-E.log" \
  && assert "E: interactive backend never full-forks" "fail" \
  || assert "E: interactive backend never full-forks" "pass"
[[ ! -s "$CANARY" ]] \
  && assert "E: rerun dispatched nothing (fully checkpointed — gate decision is parse-time)" "pass" \
  || assert "E: rerun dispatched nothing (got: $(tr '\n' ' ' < "$CANARY"))" "fail"
unset CHAIN_AGENT_BACKEND

# ══ Scenario F: SPEED-3 full + review PASS — whole section forked, join marks ═
make_sandbox F
new_capture F
start_dummies
export CHAIN_LEAN_PARALLEL_BROWSER_QA=full
export STUB_REPLAY_VERDICT=FAIL   # same inputs as A → same lane split + re-confirm
export STUB_BQA_STARTED_STAMP="$WORK/bqa-started-F.stamp"
export STUB_REVIEW_WAIT_FOR="$STUB_BQA_STARTED_STAMP"   # review ends only once the fork's LLM dispatch is live
export STUB_REVIEW_WITNESS="$WORK/review-witness-F"
rc=0; run_lean "$WORK/lean-F.log" || rc=$?
[[ "$rc" -eq 0 ]] && assert "F: full-mode lean iteration exits 0" "pass" \
  || { assert "F: full-mode lean iteration exits 0 (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/lean-F.log"; }
grep -q "Forking the FULL browser-qa section" "$WORK/lean-F.log" \
  && assert "F: full fork launched" "pass" || assert "F: full fork launched" "fail"
[[ "$(cat "$STUB_REVIEW_WITNESS" 2>/dev/null)" == "yes" ]] \
  && assert "F: LLM dispatch ran inside the fork WHILE review was pending (witness)" "pass" \
  || assert "F: LLM dispatch ran inside the fork WHILE review was pending (witness=$(cat "$STUB_REVIEW_WITNESS" 2>/dev/null))" "fail"
grep -q "Consumed forked full browser-qa results (verdict: PASS)" "$WORK/lean-F.log" \
  && assert "F: join consumed the fork's results" "pass" \
  || assert "F: join consumed the fork's results" "fail"
[[ ! -f "$ITER_DIR/.bqa-full-rc" && ! -f "$ITER_DIR/.bqa-full-pid" ]] \
  && assert "F: fork rc/pid files cleaned after consume" "pass" \
  || assert "F: fork rc/pid files cleaned after consume" "fail"
[[ "$(marker_field "$ITER_DIR" browser-qa verdict)" == "PASS" ]] \
  && assert "F: join wrote the browser-qa checkpoint marker (verdict PASS)" "pass" \
  || assert "F: join wrote the browser-qa checkpoint marker (verdict PASS)" "fail"
if [[ "$(artifact_tree)" == "$EXPECTED_TREE" ]]; then
  assert "F: artifact tree identical to the sequential run's" "pass"
else
  assert "F: artifact tree identical to the sequential run's" "fail"
  diff <(printf '%s\n' "$EXPECTED_TREE") <(artifact_tree) | sed 's/^/        /'
fi
F_LLM_LINE="$(llm_journeys_line "$PROMPTS_DIR")"
[[ -n "$F_LLM_LINE" && "$F_LLM_LINE" == "$A_LLM_LINE" ]] \
  && assert "F: LLM-lane target set identical to the sequential run's" "pass" \
  || assert "F: LLM-lane target set identical to the sequential run's (A='$A_LLM_LINE' F='$F_LLM_LINE')" "fail"
F_ROWS="$(grep -E '^\| UT-' "$UI_TEST_RESULTS" 2>/dev/null | sort)"
[[ -n "$F_ROWS" && "$F_ROWS" == "$A_ROWS" ]] \
  && assert "F: merged results rows identical to the sequential run's" "pass" \
  || assert "F: merged results rows identical to the sequential run's" "fail"
grep -q '"key":"CHAIN_LEAN_PARALLEL_BROWSER_QA","value":"full","requested":"full"' "$GOAL_SESSION_DIR/telemetry.jsonl" \
  && assert "F: iter_config records full/full" "pass" \
  || assert "F: iter_config records full/full" "fail"
unset STUB_BQA_STARTED_STAMP STUB_REVIEW_WAIT_FOR STUB_REVIEW_WITNESS

# ══ Scenario G: SPEED-3 full + review-1 FAIL — kill mid-dispatch, no orphans ═
make_sandbox G
new_capture G
start_dummies
export CHAIN_LEAN_PARALLEL_BROWSER_QA=full
export STUB_REPLAY_VERDICT=PASS   # replay lane finishes fast → LLM dispatch starts
export STUB_BQA_STARTED_STAMP="$WORK/bqa-started-G.stamp"
export STUB_BQA_SLEEP=30          # LLM dispatch hangs → review FAIL lands mid-dispatch
export STUB_REVIEW_WAIT_FOR="$STUB_BQA_STARTED_STAMP"
export STUB_REVIEW_VERDICT=FAIL
export STUB_DEV_FIX_RC=70         # fix-mode developer "pauses" right after the invalidation point
rc=0; run_lean "$WORK/lean-G.log" || rc=$?
[[ "$rc" -eq 70 ]] && assert "G: fix-mode transport pause exits 70" "pass" \
  || { assert "G: fix-mode transport pause exits 70 (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/lean-G.log"; }
[[ -f "$STUB_BQA_STARTED_STAMP" ]] \
  && assert "G: LLM dispatch was mid-flight inside the fork when review failed" "pass" \
  || assert "G: LLM dispatch was mid-flight inside the fork when review failed" "fail"
grep -q "Reaping the forked full browser-qa section" "$WORK/lean-G.log" \
  && grep -q "Forked full browser-qa section is dead and its lane files are discarded — safe to invalidate" "$WORK/lean-G.log" \
  && assert "G: kill+wait+discard logged before invalidation" "pass" \
  || assert "G: kill+wait+discard logged before invalidation" "fail"
_reap_ln="$(grep -n "Forked full browser-qa section is dead" "$WORK/lean-G.log" | head -1 | cut -d: -f1 || true)"
_fix_ln="$(grep -n "Review FAIL — running developer in fix mode" "$WORK/lean-G.log" | head -1 | cut -d: -f1 || true)"
[[ -n "$_reap_ln" && -n "$_fix_ln" ]] && [[ "$_fix_ln" -lt "$_reap_ln" ]] \
  && assert "G: reap completes inside the FAIL branch (after its banner, before the fix dispatch)" "pass" \
  || assert "G: reap completes inside the FAIL branch (banner=$_fix_ln reap=$_reap_ln)" "fail"
sleep 2   # settle window: a survivor would land its late write here
[[ ! -f "$UI_TEST_RESULTS" && ! -f "$REGRESSION_RESULTS" && ! -f "$SBX/reports/phase-${ITER}-ui-test-results.llm.md" ]] \
  && assert "G: no lane/merged results file exists post-invalidation (incl. settle window)" "pass" \
  || assert "G: no lane/merged results file exists post-invalidation" "fail"
_orphans="$(pgrep -f -- "$STUB_DIR/claude" 2>/dev/null || true; pgrep -f -- "$SBX/scripts" 2>/dev/null || true)"
[[ -z "$_orphans" ]] \
  && assert "G: ZERO fork processes survive the kill (pgrep — stop-and-ask trigger)" "pass" \
  || assert "G: ZERO fork processes survive the kill (survivors: $_orphans)" "fail"
grep -q '"event":"parallel_bqa_wasted_dispatch"' "$GOAL_SESSION_DIR/telemetry.jsonl" \
  && grep -q '"mode":"full".*"wasted":"one full browser-qa dispatch' "$GOAL_SESSION_DIR/telemetry.jsonl" \
  && grep -q '2-of-3 attempt-1-FAIL tripwire also spares this cost' "$GOAL_SESSION_DIR/telemetry.jsonl" \
  && assert "G: wasted-dispatch cost event recorded (with the tripwire-spares fact)" "pass" \
  || assert "G: wasted-dispatch cost event recorded (with the tripwire-spares fact)" "fail"
[[ ! -f "$ITER_DIR/.bqa-full-rc" && ! -f "$ITER_DIR/.bqa-full-pid" ]] \
  && assert "G: fork rc/pid files discarded by the reap" "pass" \
  || assert "G: fork rc/pid files discarded by the reap" "fail"
[[ "$(grep -cx 'browser-qa-agent' "$CANARY")" == "1" ]] \
  && assert "G: exactly one (killed) browser-qa dispatch — none after the pause" "pass" \
  || assert "G: exactly one (killed) browser-qa dispatch (got: $(grep -cx 'browser-qa-agent' "$CANARY"))" "fail"
unset STUB_BQA_SLEEP STUB_BQA_STARTED_STAMP STUB_REVIEW_WAIT_FOR STUB_REVIEW_VERDICT STUB_DEV_FIX_RC

# ══ Scenario H: SPEED-3 full + rc-70 in the forked LLM lane — pause parity ═══
# H1: the SEQUENTIAL pause tree (knob off, dispatch dies with 70 mid-section).
make_sandbox H1
new_capture H1
start_dummies
unset CHAIN_LEAN_PARALLEL_BROWSER_QA 2>/dev/null || true
export STUB_REPLAY_VERDICT=PASS
export STUB_BQA_RC=70
rc=0; run_lean "$WORK/lean-H1.log" || rc=$?
[[ "$rc" -eq 70 ]] && assert "H: sequential rc-70 pauses with exit 70" "pass" \
  || { assert "H: sequential rc-70 pauses with exit 70 (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/lean-H1.log"; }
H1_TREE="$(artifact_tree)"
H1_ITER_DIR="$ITER_DIR"
# H2: the FULL-FORK pause tree (same stubs; the 70 crosses the fork boundary).
make_sandbox H2
new_capture H2
start_dummies
export CHAIN_LEAN_PARALLEL_BROWSER_QA=full
rc=0; run_lean "$WORK/lean-H2.log" || rc=$?
[[ "$rc" -eq 70 ]] && assert "H: full-fork rc-70 pauses the ENGINE with exit 70 (join translation)" "pass" \
  || { assert "H: full-fork rc-70 pauses the ENGINE with exit 70 (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/lean-H2.log"; }
grep -q "browser-qa-agent (parallel full): interactive pump/dispatch unavailable (exit 70) — pausing" "$WORK/lean-H2.log" \
  && assert "H: join re-raises the pause with the parallel-full label" "pass" \
  || assert "H: join re-raises the pause with the parallel-full label" "fail"
H2_TREE="$(artifact_tree)"
if [[ "$H2_TREE" == "$H1_TREE" ]]; then
  assert "H: pause-at-join sandbox tree IDENTICAL to the sequential pause tree" "pass"
else
  assert "H: pause-at-join sandbox tree IDENTICAL to the sequential pause tree" "fail"
  diff <(printf '%s\n' "$H1_TREE") <(printf '%s\n' "$H2_TREE") | sed 's/^/        /'
fi
[[ ! -f "$ITER_DIR/.steps/browser-qa.done" && ! -f "$H1_ITER_DIR/.steps/browser-qa.done" ]] \
  && assert "H: browser-qa marker absent in BOTH pause trees (resume re-runs the section)" "pass" \
  || assert "H: browser-qa marker absent in BOTH pause trees" "fail"
[[ -f "$REGRESSION_RESULTS" && ! -f "$UI_TEST_RESULTS" ]] \
  && assert "H: replay results present, merged results absent (pause hit the LLM lane)" "pass" \
  || assert "H: replay results present, merged results absent" "fail"
[[ "$(marker_field "$ITER_DIR" developer tree_hash)" == "$(marker_field "$H1_ITER_DIR" developer tree_hash)" ]] \
  && [[ -n "$(marker_field "$ITER_DIR" developer tree_hash)" ]] \
  && assert "H: developer marker tree_hash identical across the two pause trees" "pass" \
  || assert "H: developer marker tree_hash identical across the two pause trees" "fail"
# H3: resume the paused full-mode sandbox — the pause must be genuinely resumable.
new_capture H3
start_dummies
unset STUB_BQA_RC
rc=0; run_lean "$WORK/lean-H3.log" || rc=$?
[[ "$rc" -eq 0 ]] && assert "H: resume after the join-pause completes (exit 0)" "pass" \
  || { assert "H: resume after the join-pause completes (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/lean-H3.log"; }
grep -q "Resume: developer already completed" "$WORK/lean-H3.log" \
  && assert "H: resume skips the developer build (checkpoint held)" "pass" \
  || assert "H: resume skips the developer build (checkpoint held)" "fail"
grep -q "Forking the FULL browser-qa section" "$WORK/lean-H3.log" \
  && assert "H: resume re-runs browser-qa (fresh full fork)" "pass" \
  || assert "H: resume re-runs browser-qa (fresh full fork)" "fail"
grep -q '^\*\*Browser QA Verdict:\*\* PASS' "$UI_TEST_RESULTS" 2>/dev/null \
  && assert "H: resumed browser-qa produced a real PASS verdict" "pass" \
  || assert "H: resumed browser-qa produced a real PASS verdict" "fail"
unset STUB_BQA_RC 2>/dev/null || true

# ══ Scenario I: journey-less spec lines — the lean lane must survive the parse ═
# I1 uses the exact decomposer baseline shape ("none — ..." in
# Required-still-passing); I2 hardens further with BOTH lines journey-less.
# Knob off: this is plain sequential mode — the parse runs top-level either way.
make_sandbox I
new_capture I1
start_dummies
unset CHAIN_LEAN_PARALLEL_BROWSER_QA 2>/dev/null || true
unset STUB_REPLAY_VERDICT STUB_REPLAY_SLEEP STUB_DEV_FIX_RC 2>/dev/null || true
unset STUB_REVIEW_WAIT_FOR STUB_REVIEW_WITNESS 2>/dev/null || true
unset STUB_BQA_STARTED_STAMP STUB_BQA_SLEEP STUB_BQA_RC 2>/dev/null || true
export STUB_REVIEW_VERDICT=PASS
cat > "$SBX/docs/phases/goal-pbtest-iter-1.md" <<'EOF'
# Iteration spec
## Goal Mode Metadata
- **Mode:** baseline
- **Depth:** lean
- **Target journeys:** J-01, J-02
- **Required-still-passing journeys:** none — no journey has been verified passing yet (iteration 0).
## IN SCOPE
- verify-only baseline (journey-less-parse regression pin)
EOF
rc=0; run_lean "$WORK/lean-I1.log" || rc=$?
[[ "$rc" -eq 0 ]] && assert "I1: journey-less Required-still-passing spec exits 0" "pass" \
  || { assert "I1: journey-less Required-still-passing spec exits 0 (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/lean-I1.log"; }
[[ "$(tr '\n' ' ' < "$CANARY")" == "developer reviewer browser-qa-agent " ]] \
  && assert "I1: lean lane survived the parse (developer→reviewer→browser-qa dispatched)" "pass" \
  || assert "I1: lean lane survived the parse (got: '$(tr '\n' ' ' < "$CANARY")')" "fail"
_i_prompt="$(ls "$PROMPTS_DIR"/prompt-*-browser-qa-agent.txt 2>/dev/null | head -n1)"
if [[ -n "$_i_prompt" ]] && grep -q 'test EXACTLY these journeys this run: J-01,J-02' "$_i_prompt"; then
  assert "I1: LLM lane still targets the parsed Target journeys (J-01,J-02)" "pass"
else
  assert "I1: LLM lane still targets the parsed Target journeys (got: $(grep -h 'test EXACTLY' "$_i_prompt" 2>/dev/null))" "fail"
fi
# The field signature of the death was iter_dispatch WITHOUT iter_config —
# assert the parse-survival marker directly.
jq -e 'select(.event=="iter_config")' "$GOAL_SESSION_DIR/telemetry.jsonl" >/dev/null 2>&1 \
  && assert "I1: iter_config telemetry event recorded (script got past the parse)" "pass" \
  || assert "I1: iter_config telemetry event recorded (script got past the parse)" "fail"

# I2: BOTH journey lines journey-less — parse yields empty sets, lane still runs.
new_capture I2
start_dummies
cat > "$SBX/docs/phases/goal-pbtest-iter-1.md" <<'EOF'
# Iteration spec
## Goal Mode Metadata
- **Mode:** baseline
- **Depth:** lean
- **Target journeys:** none yet — journeys are defined but this spec targets scaffold verification only
- **Required-still-passing journeys:** none — no journey has been verified passing yet (iteration 0).
## IN SCOPE
- verify-only baseline (both-lines journey-less regression pin)
EOF
step_dir="$GOAL_SESSION_DIR/iter-1"; rm -rf "$step_dir/.steps" 2>/dev/null || true
rc=0; run_lean "$WORK/lean-I2.log" || rc=$?
[[ "$rc" -eq 0 ]] && assert "I2: both-lines journey-less spec exits 0" "pass" \
  || { assert "I2: both-lines journey-less spec exits 0 (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/lean-I2.log"; }
[[ "$(tr '\n' ' ' < "$CANARY")" == "developer reviewer browser-qa-agent " ]] \
  && assert "I2: lean lane survived an entirely journey-less parse" "pass" \
  || assert "I2: lean lane survived an entirely journey-less parse (got: '$(tr '\n' ' ' < "$CANARY")')" "fail"

# ══ Scenario J: REL-12 single-service short-circuit — no frontend boot ═══════
# CHAIN_FRONTEND_URL points at the DUMMY BACKEND port (the "frontend is
# server-rendered by the backend" case): the direct probe must answer, enable
# the lane loudly, skip the frontend boot + readiness gate entirely, and the
# dispatch prompt must carry "Frontend available: yes".
make_sandbox J
new_capture J
start_dummies
unset CHAIN_LEAN_PARALLEL_BROWSER_QA 2>/dev/null || true
export STUB_REPLAY_VERDICT=PASS
export STUB_REVIEW_VERDICT=PASS
export CHAIN_FRONTEND_URL="http://localhost:${BE_PORT}"
rc=0; run_lean "$WORK/lean-J.log" || rc=$?
[[ "$rc" -eq 0 ]] && assert "J: single-service lean iteration exits 0" "pass" \
  || { assert "J: single-service lean iteration exits 0 (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/lean-J.log"; }
grep -q "Frontend already answering at http://localhost:${BE_PORT}" "$WORK/lean-J.log" \
  && grep -q "direct probe enabled the browser lane; skipping the frontend boot (REL-12 single-service short-circuit)" "$WORK/lean-J.log" \
  && assert "J: loud short-circuit line names the URL" "pass" \
  || assert "J: loud short-circuit line names the URL" "fail"
_j_prompt="$(ls "$PROMPTS_DIR"/prompt-*-browser-qa-agent.txt 2>/dev/null | head -n1)"
if [[ -n "$_j_prompt" ]] && grep -q '^Frontend available: yes' "$_j_prompt"; then
  assert "J: 'Frontend available: yes' reaches the dispatch prompt" "pass"
else
  assert "J: 'Frontend available: yes' reaches the dispatch prompt (got: $(grep -h '^Frontend available:' "$_j_prompt" 2>/dev/null))" "fail"
fi
grep -q "\[ensure_services_running\] frontend not healthy" "$WORK/lean-J.log" \
  && assert "J: no frontend boot attempted" "fail" \
  || assert "J: no frontend boot attempted" "pass"
grep -q "Waiting for frontend at" "$WORK/lean-J.log" \
  && assert "J: readiness gate skipped (probe hit decides alone)" "fail" \
  || assert "J: readiness gate skipped (probe hit decides alone)" "pass"
[[ "$(tr '\n' ' ' < "$CANARY")" == "developer reviewer browser-qa-agent " ]] \
  && assert "J: dispatch order unchanged (developer→reviewer→browser-qa)" "pass" \
  || assert "J: dispatch order unchanged (got: $(tr '\n' ' ' < "$CANARY"))" "fail"
unset CHAIN_FRONTEND_URL

# ══ Scenario K: REL-5 — forked replay lane hits browser-infra twice → SKIPPED-INFRA ═
# The lane (inside the SPEED-2 fork) gets rc=6 from demo_runner twice: it must
# retry exactly once (service re-check between attempts), record the lane state
# SKIPPED-INFRA on the RAW artifact + the fork state file (the join's consume
# line is the reader-side proof), fall back to the LLM lane for the WHOLE
# required set, keep SKIPPED-INFRA OUT of the merged results file (whose
# verdict greps only know PASS/FAIL/SKIPPED), and never trip the
# missing-evidence banner (the LLM lane wrote its own file).
make_sandbox K
new_capture K
start_dummies
export CHAIN_LEAN_PARALLEL_BROWSER_QA=replay
export STUB_REPLAY_VERDICT=PASS
export STUB_REVIEW_VERDICT=PASS
export STUB_REPLAY_RC_SEQ="6 6"
export STUB_REPLAY_COUNT_FILE="$WORK/replay-count-K"
rm -f "$STUB_REPLAY_COUNT_FILE"
rc=0; run_lean "$WORK/lean-K.log" || rc=$?
[[ "$rc" -eq 0 ]] && assert "K: double-infra lean iteration exits 0" "pass" \
  || { assert "K: double-infra lean iteration exits 0 (rc=$rc)" "fail"; sed -n '1,40p' "$WORK/lean-K.log"; }
[[ "$(cat "$STUB_REPLAY_COUNT_FILE" 2>/dev/null)" == "2" ]] \
  && assert "K: exactly one retry inside the fork (2 verify invocations)" "pass" \
  || assert "K: exactly one retry inside the fork (got $(cat "$STUB_REPLAY_COUNT_FILE" 2>/dev/null) invocations)" "fail"
grep -q "re-checking services and retrying the replay once" "$WORK/lean-K.log" \
  && assert "K: greppable retry log line" "pass" || assert "K: greppable retry log line" "fail"
grep -q "SKIPPED-INFRA — browser-infra failure persisted after one retry" "$WORK/lean-K.log" \
  && assert "K: greppable SKIPPED-INFRA verdict log line" "pass" \
  || assert "K: greppable SKIPPED-INFRA verdict log line" "fail"
grep -q '^\*\*Browser QA Verdict:\*\* SKIPPED-INFRA$' "$REGRESSION_RESULTS" \
  && assert "K: raw replay artifact records the exact SKIPPED-INFRA verdict line" "pass" \
  || assert "K: raw replay artifact records the exact SKIPPED-INFRA verdict line" "fail"
grep "Consumed forked replay-lane results" "$WORK/lean-K.log" | grep -q "SKIPPED-INFRA" \
  && assert "K: join consume line carries the state across the fork boundary (reader proof)" "pass" \
  || assert "K: join consume line carries the state across the fork boundary (reader proof)" "fail"
K_LLM_LINE="$(llm_journeys_line "$PROMPTS_DIR")"
[[ "$K_LLM_LINE" == *"J-01"* && "$K_LLM_LINE" == *"J-02"* ]] \
  && assert "K: whole required set fell back to the LLM lane (J-01 J-02)" "pass" \
  || assert "K: whole required set fell back to the LLM lane (got: $K_LLM_LINE)" "fail"
grep -q '^\*\*Browser QA Verdict:\*\* PASS' "$UI_TEST_RESULTS" 2>/dev/null \
  && ! grep -q 'SKIPPED-INFRA' "$UI_TEST_RESULTS" \
  && assert "K: merged results stay LLM-written PASS — SKIPPED-INFRA never enters the merged file" "pass" \
  || assert "K: merged results stay LLM-written PASS — SKIPPED-INFRA never enters the merged file" "fail"
grep -q "\[missing-evidence\]" "$WORK/lean-K.log" \
  && assert "K: missing-evidence tripwire stays silent (LLM lane wrote its file)" "fail" \
  || assert "K: missing-evidence tripwire stays silent (LLM lane wrote its file)" "pass"
[[ "$(marker_field "$ITER_DIR" browser-qa verdict)" == "PASS" ]] \
  && assert "K: browser-qa checkpoint marker written with the merged PASS" "pass" \
  || assert "K: browser-qa checkpoint marker written with the merged PASS (got: $(marker_field "$ITER_DIR" browser-qa verdict))" "fail"
grep -q '"event":"replay_lane_skipped_infra"' "$GOAL_SESSION_DIR/telemetry.jsonl" \
  && assert "K: replay_lane_skipped_infra telemetry event recorded" "pass" \
  || assert "K: replay_lane_skipped_infra telemetry event recorded" "fail"
unset STUB_REPLAY_RC_SEQ STUB_REPLAY_COUNT_FILE

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
