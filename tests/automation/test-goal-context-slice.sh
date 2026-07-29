#!/usr/bin/env bash
# test-goal-context-slice.sh — TOKEN-10 unit + wiring test: the developer and
# browser-qa dispatches get a token-lean GOAL SLICE instead of the whole
# docs/goal.md (which grows with every proposer-promoted journey).
#
# Drives the REAL goal-iter-lean.sh in a sandbox repo (modeled on
# test-goal-parallel-bqa.sh: role-aware stub `claude` on PATH capturing every
# dispatch prompt, stub demo_runner.py for the replay lane, dummy HTTP services
# on test ports) plus direct unit calls to goal_slice_for_exec (lib/common.sh)
# against the REAL goal_gate.py builder. Scenarios:
#   A. Default: the developer prompt names the SLICED goal file (not goal.md);
#      the slice keeps the anti-goals + target journey VERBATIM and digests the
#      stable passing journey to one line. The browser-qa prompt names its own
#      slice, and a REQUIRED-but-passing journey riding the LLM lane (no
#      golden) stays VERBATIM in it — every journey the LLM executes keeps its
#      step definitions.
#   B. Hatch: CHAIN_DEV_FULL_GOAL=true → both prompts name docs/goal.md,
#      exactly as before TOKEN-10.
#   C. Forced builder failure (goal_gate.py removed) → both prompts fall back
#      to docs/goal.md with a loud [goal-slice] WARNING; the run still
#      completes (fail-safe, never blocks).
#   D. dev-phase.sh + browser-qa-phase.sh wiring greps (full pipeline) + agent
#      body wording (neutral source).
#
# No API calls; a few seconds per scenario.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BE_PORT=48341
FE_PORT=48342

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

ITER="goal-ctxtest-iter-1"

# ── Sandbox builder ──────────────────────────────────────────────────────────
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

Vision: a tiny test product.

## Must-have user journeys

- **J-01: Open** — open the page
  - Acceptance: page loads
- **J-02: Add** — add an item
  - Acceptance: item appears
- **J-03: Stable** — view the stable thing
  - Acceptance: STABLE-THING-STEP-MARKER shows
- **J-04: Required** — view the required thing
  - Acceptance: REQUIRED-THING-STEP-MARKER shows

## Anti-goals

- Never delete user data without confirmation (ANTI-GOAL-VERBATIM-MARKER)
EOF
  cat > "$SBX/docs/phases/$ITER.md" <<'EOF'
# Iteration spec
## Goal Mode Metadata
- **Mode:** next
- **Depth:** lean
- **Target journeys:** J-02
- **Required-still-passing journeys:** J-01, J-04
## IN SCOPE
- add an item (context-slice wiring test)
EOF
  git -C "$SBX" add -A
  git -C "$SBX" -c user.email=t@t -c user.name=t commit -qm base

  export GOAL_SESSION_DIR="$SBX/runs/goal-session-ctxtest"
  export GOAL_ITER_INDEX=1
  export GOAL_ITER_NAME="$ITER"
  mkdir -p "$GOAL_SESSION_DIR/iter-1" "$GOAL_SESSION_DIR/state" "$GOAL_SESSION_DIR/journey-scripts"
  # History: J-01/J-03/J-04 stable passing; J-02 (the target) unknown → the
  # builder digests passing journeys unless targeted.
  cat > "$GOAL_SESSION_DIR/state/journey-history.json" <<'EOF'
{"journeys": {"J-01": {"status": "passing", "name": "Open"},
              "J-03": {"status": "passing", "name": "Stable"},
              "J-04": {"status": "passing", "name": "Required"}}}
EOF
  # Golden for J-01 only → replay covers J-01; J-04 rides the LLM lane.
  echo '{"journey":"J-01","steps":[]}' > "$GOAL_SESSION_DIR/journey-scripts/J-01.json"

  # Stub demo_runner: lint ok, verify writes PASS rows (replay lane engages).
  cat > "$SBX/scripts/automation/lib/demo_runner.py" <<'PYEOF'
#!/usr/bin/env python3
import sys

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
    results = arg("--results")
    if results:
        rows = "\n".join(
            f"| UT-{j} | replay {j} | journey | P1 | works | stub pass | PASS | none |"
            for j in journeys)
        with open(results, "w") as f:
            f.write("**Browser QA Verdict:** PASS\n\n"
                    "| Test ID | Name | Type | Prio | Expected | Actual | Verdict | Evidence |\n"
                    "|---|---|---|---|---|---|---|---|\n" + rows + "\n")
    sys.exit(0)
sys.exit(0)
PYEOF
}

# ── Role-aware stub claude (captures every dispatch prompt) ──────────────────
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
    out="$(printf '%s\n' "$prompt" | sed -n 's/^- Write dev handoff to: //p' | head -n1)"
    [[ -n "$out" ]] || exit 64
    echo "print('v2 built by stub')" > src/app.py
    printf 'handoff: implemented the iter spec (stub).\n' > "$out"
    exit 0 ;;
  reviewer)
    out="$(printf '%s\n' "$prompt" | sed -n 's/^Write your review report to: //p' | head -n1)"
    [[ -n "$out" ]] || exit 64
    printf '**Verdict:** PASS\n\nStub review.\n' > "$out"
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

# ── Dummy services ───────────────────────────────────────────────────────────
SRV_DIR="$WORK/srv"
mkdir -p "$SRV_DIR"
start_dummies() {
  local p i
  for p in "$BE_PORT" "$FE_PORT"; do
    if ! curl -s -o /dev/null "http://localhost:${p}/"; then
      ( cd "$SRV_DIR" && exec python3 -m http.server "$p" ) >/dev/null 2>&1 &
      DUMMY_PIDS+=("$!")
    fi
  done
  for p in "$BE_PORT" "$FE_PORT"; do
    for i in $(seq 1 50); do
      curl -s -o /dev/null "http://localhost:${p}/" && break
      sleep 0.1
    done
  done
}

export CHAIN_BACKEND_PORT="$BE_PORT"
export CHAIN_FRONTEND_PORT="$FE_PORT"
export CHAIN_KILL_GRACE_SECONDS=1

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

dev_prompt()  { cat "$1"/prompt-*-developer.txt 2>/dev/null | head -60; }
bqa_prompt()  { cat "$1"/prompt-*-browser-qa-agent.txt 2>/dev/null | head -60; }

echo "=== test-goal-context-slice.sh ==="

# ── A. Default: sliced context for developer + browser-qa ────────────────────
make_sandbox a
new_capture a
rc=0; run_lean "$WORK/run-a.log" || rc=$?
[[ $rc -eq 0 ]] && assert "A: lean run completes (rc=0)" pass \
  || { assert "A: lean run completes (rc=$rc)" fail; tail -20 "$WORK/run-a.log"; }
dev_prompt "$PROMPTS_DIR" | grep -q 'Project goal (SLICED' \
  && assert "A: developer prompt names the SLICED goal view" pass \
  || assert "A: developer prompt names the SLICED goal view" fail
dev_prompt "$PROMPTS_DIR" | grep -q 'goal-slice-exec.md' \
  && assert "A: developer slice path is the per-iteration goal-slice-exec.md" pass \
  || assert "A: developer slice path is the per-iteration goal-slice-exec.md" fail
# The slice paths come from the CAPTURED PROMPTS (the executor derives its
# iter dir itself — asserting a hardcoded path would test the harness, not
# the wiring).
DEV_SLICE="$(dev_prompt "$PROMPTS_DIR" | grep -oE '[^ ]*goal-slice-exec\.md' | head -1)"
[[ -n "$DEV_SLICE" && -s "$DEV_SLICE" ]] \
  && assert "A: developer slice file exists and is non-empty" pass \
  || assert "A: developer slice file exists and is non-empty (path: '$DEV_SLICE')" fail
grep -q 'ANTI-GOAL-VERBATIM-MARKER' "$DEV_SLICE" 2>/dev/null \
  && assert "A: anti-goals VERBATIM in the developer slice" pass \
  || assert "A: anti-goals VERBATIM in the developer slice" fail
grep -q 'item appears' "$DEV_SLICE" 2>/dev/null \
  && assert "A: target journey J-02 VERBATIM in the developer slice" pass \
  || assert "A: target journey J-02 VERBATIM in the developer slice" fail
grep -q 'STABLE-THING-STEP-MARKER' "$DEV_SLICE" 2>/dev/null \
  && assert "A: stable J-03 digested out of the developer slice" fail \
  || assert "A: stable J-03 digested out of the developer slice" pass
bqa_prompt "$PROMPTS_DIR" | grep -q 'goal-slice-bqa.md' \
  && assert "A: browser-qa prompt names its own slice" pass \
  || assert "A: browser-qa prompt names its own slice" fail
BQA_SLICE="$(bqa_prompt "$PROMPTS_DIR" | grep -oE '[^ ]*goal-slice-bqa\.md' | head -1)"
[[ -n "$BQA_SLICE" && -s "$BQA_SLICE" ]] \
  && assert "A: browser-qa slice file exists and is non-empty" pass \
  || assert "A: browser-qa slice file exists and is non-empty (path: '$BQA_SLICE')" fail
grep -q 'REQUIRED-THING-STEP-MARKER' "$BQA_SLICE" 2>/dev/null \
  && assert "A: LLM-lane journey J-04 (passing, no golden) stays VERBATIM in the bqa slice" pass \
  || assert "A: LLM-lane journey J-04 (passing, no golden) stays VERBATIM in the bqa slice" fail
grep -q 'STABLE-THING-STEP-MARKER' "$BQA_SLICE" 2>/dev/null \
  && assert "A: stable J-03 digested out of the bqa slice" fail \
  || assert "A: stable J-03 digested out of the bqa slice" pass

# ── B. Hatch: CHAIN_DEV_FULL_GOAL=true restores the full goal file ──────────
make_sandbox b
new_capture b
rc=0; CHAIN_DEV_FULL_GOAL=true run_lean "$WORK/run-b.log" || rc=$?
[[ $rc -eq 0 ]] && assert "B: lean run completes (rc=0)" pass \
  || { assert "B: lean run completes (rc=$rc)" fail; tail -20 "$WORK/run-b.log"; }
dev_prompt "$PROMPTS_DIR" | grep -q '^Project goal: .*docs/goal.md' \
  && assert "B: hatch — developer prompt names docs/goal.md" pass \
  || assert "B: hatch — developer prompt names docs/goal.md" fail
dev_prompt "$PROMPTS_DIR" | grep -q 'SLICED' \
  && assert "B: hatch — no SLICED wording in the developer prompt" fail \
  || assert "B: hatch — no SLICED wording in the developer prompt" pass
bqa_prompt "$PROMPTS_DIR" | grep -q '^Project goal: .*docs/goal.md' \
  && assert "B: hatch — browser-qa prompt names docs/goal.md" pass \
  || assert "B: hatch — browser-qa prompt names docs/goal.md" fail

# ── C. Builder failure → loud fallback to the full goal file ────────────────
make_sandbox c
rm -f "$SBX/scripts/automation/lib/goal_gate.py"   # force the builder to crash
new_capture c
rc=0; run_lean "$WORK/run-c.log" || rc=$?
[[ $rc -eq 0 ]] && assert "C: lean run still completes (fail-safe, rc=0)" pass \
  || { assert "C: lean run still completes (rc=$rc)" fail; tail -20 "$WORK/run-c.log"; }
dev_prompt "$PROMPTS_DIR" | grep -q '^Project goal: .*docs/goal.md' \
  && assert "C: fallback — developer prompt names docs/goal.md" pass \
  || assert "C: fallback — developer prompt names docs/goal.md" fail
grep -q '\[goal-slice\] WARNING' "$WORK/run-c.log" \
  && assert "C: fallback is LOUD (goal-slice WARNING in the log)" pass \
  || assert "C: fallback is LOUD (goal-slice WARNING in the log)" fail

# ── D. Full-pipeline wiring + agent bodies (grep) ────────────────────────────
DP="$ENGINE_ROOT/scripts/automation/dev-phase.sh"
grep -q 'goal_slice_for_exec' "$DP" \
  && assert "D: dev-phase.sh builds the executor slice for goal iterations" pass \
  || assert "D: dev-phase.sh builds the executor slice for goal iterations" fail
grep -q 'GOAL_CONTEXT_LINE' "$DP" \
  && assert "D: dev-phase.sh injects the goal-context line into the prompt" pass \
  || assert "D: dev-phase.sh injects the goal-context line into the prompt" fail
BQAP="$ENGINE_ROOT/scripts/automation/browser-qa-phase.sh"
grep -q 'goal_slice_for_exec' "$BQAP" \
  && assert "D: browser-qa-phase.sh builds the executor slice" pass \
  || assert "D: browser-qa-phase.sh builds the executor slice" fail
grep -q '_bqa_goal_ref' "$BQAP" \
  && assert "D: browser-qa-phase.sh regression lane names the sliced file" pass \
  || assert "D: browser-qa-phase.sh regression lane names the sliced file" fail
grep -q 'CHAIN_DEV_FULL_GOAL' "$ENGINE_ROOT/scripts/automation/lib/common.sh" \
  && assert "D: full-goal escape hatch present in the shared helper" pass \
  || assert "D: full-goal escape hatch present in the shared helper" fail
grep -q 'goal_slice_fallback' "$ENGINE_ROOT/scripts/automation/lib/common.sh" \
  && assert "D: fallback telemetry event wired" pass \
  || assert "D: fallback telemetry event wired" fail
grep -q 'The project-goal file named in your dispatch prompt' "$ENGINE_ROOT/agents/developer/body.md" \
  && assert "D: developer body defers to the dispatch prompt's goal file" pass \
  || assert "D: developer body defers to the dispatch prompt's goal file" fail
grep -q 'the goal file named in your dispatch prompt' "$ENGINE_ROOT/agents/browser-qa-agent/body.md" \
  && assert "D: browser-qa body wording updated" pass \
  || assert "D: browser-qa body wording updated" fail

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
