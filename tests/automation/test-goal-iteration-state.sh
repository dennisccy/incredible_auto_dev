#!/usr/bin/env bash
# test-goal-iteration-state.sh — REL-6 end-to-end wiring proof: the
# goal-evaluator writes runs/goal-session-<sid>/state/iteration-state.md (a
# ≤40-line template-driven digest) and the NEXT decomposer dispatch inlines it
# VERBATIM; iteration 0 inlines the placeholder instead.
#
# Drives the REAL run-goal.sh (ONE engine invocation, --max-iter 2) in a
# sandbox repo with a role-aware stub `claude`:
#   iteration 0 (baseline): the decomposer stub writes a lean verify-only spec
#     — its captured prompt must inline the PLACEHOLDER ("first iteration — no
#     prior state"); the lean executor stubs run; the goal-evaluator stub obeys
#     its (REL-6-extended) dispatch prompt: writes eval.md, journey-history,
#     an evaluator-log entry, AND a conforming iteration-state.md — every path
#     parsed from the prompt itself, so the wiring under test is the prompt.
#   iteration 1: the decomposer stub captures its prompt — it must carry the
#     evaluator's file byte-for-byte inside the fenced block — then exits 70,
#     pausing the engine cleanly (AWAITING_PUMP; engine exit 0).
# Also asserts the artifact-schema CLI accepts the stub-written file and
# rejects an over-cap copy (G3: the ≤40-line cap is validator-enforced).
#
# No API calls; dummy HTTP services on test ports keep the REL-12 probe fast.

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
  pkill -f "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── Sandbox project (consumer-repo layout, engine scripts embedded) ──────────
SBX="$WORK/proj"
mkdir -p "$SBX"
cp -r "$ENGINE_ROOT/scripts" "$SBX/"
mkdir -p "$SBX/docs/phases" "$SBX/docs/handoffs" "$SBX/reports/reviews" "$SBX/src" \
         "$SBX/.claude/agents"
# ensure_cli_assets_synced no-ops when the rendered marker exists.
touch "$SBX/.claude/agents/developer.md"
git init -q "$SBX"
echo "print('v1')" > "$SBX/src/app.py"
cat > "$SBX/docs/goal.md" <<'EOF'
# Goal

Tiny single-page app (iteration-state wiring fixture).

## Must-have user journeys

- **J-01: Open the page**
  - Steps: open /
  - Acceptance: page loads

## Anti-goals

- no paid SaaS
EOF
git -C "$SBX" add -A
git -C "$SBX" -c user.email=t@t -c user.name=t commit -qm base

SID="istest"
SDIR="$SBX/runs/goal-session-$SID"
STATE_FILE="$SDIR/state/iteration-state.md"
TMPROOT="$WORK/tmproot"
mkdir -p "$TMPROOT"

# ── Dummy services (REL-12 direct probe answers → no boot ladders) ───────────
SRV_DIR="$WORK/srv"
mkdir -p "$SRV_DIR"
for p in "$BE_PORT" "$FE_PORT"; do
  ( cd "$SRV_DIR" && exec python3 -m http.server "$p" ) >/dev/null 2>&1 &
  DUMMY_PIDS+=("$!")
done
for p in "$BE_PORT" "$FE_PORT"; do
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://localhost:${p}/" && break
    sleep 0.1
  done
done

# ── Role-aware stub claude (paths parsed FROM the prompt — the wiring under
#    test is the dispatch prompt itself, so hardcoding paths here would pass
#    vacuously) ────────────────────────────────────────────────────────────────
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
CANARY="$WORK/canary.log"; : > "$CANARY"
PROMPTS_DIR="$WORK/prompts"; mkdir -p "$PROMPTS_DIR"
export CANARY PROMPTS_DIR
cat > "$STUB_DIR/claude" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "stub 0.0"; exit 0; }
agent="${CHAIN_CURRENT_AGENT:-unknown}"
prompt="$*"
echo "$agent" >> "$CANARY"
n="$(wc -l < "$CANARY")"
printf '%s\n' "$prompt" > "$PROMPTS_DIR/prompt-${n}-${agent}.txt"
case "$agent" in
  goal-decomposer)
    # Second decomposer dispatch = iteration 1: the prompt is captured (the
    # assertion surface); pause the engine via the transport code.
    d_count="$(ls "$PROMPTS_DIR"/prompt-*-goal-decomposer.txt 2>/dev/null | wc -l)"
    [[ "$d_count" -gt 1 ]] && exit 70
    out="$(printf '%s\n' "$prompt" | sed -n 's/^Write the iteration spec to: //p' | head -n1)"
    [[ -n "$out" ]] || exit 64
    cat > "$out" <<'SPEC'
# Iteration spec (stub baseline)
## Goal Mode Metadata
- **Mode:** baseline
- **Depth:** lean
- **Target journeys:** J-01
- **Required-still-passing journeys:** none — baseline establishes the initial state
## IN SCOPE
- verify-only baseline (iteration-state wiring test)
SPEC
    exit 0 ;;
  developer)
    out="$(printf '%s\n' "$prompt" | sed -n 's/^- Write dev handoff to: //p' | head -n1)"
    [[ -n "$out" ]] || exit 64
    printf 'handoff: baseline verify (stub).\n' > "$out"
    exit 0 ;;
  reviewer)
    out="$(printf '%s\n' "$prompt" | sed -n 's/^Write your review report to: //p' | head -n1)"
    [[ -n "$out" ]] || exit 64
    printf '**Verdict:** PASS\n\nStub review.\n' > "$out"
    exit 0 ;;
  browser-qa-agent)
    out="$(printf '%s\n' "$prompt" | sed -n 's/^Write your results to: //p' | head -n1)"
    [[ -n "$out" ]] || exit 64
    {
      printf '**Browser QA Verdict:** PASS\n\n'
      printf '| Test ID | Name | Type | Prio | Expected | Actual | Verdict | Evidence |\n'
      printf '|---|---|---|---|---|---|---|---|\n'
      printf '| UT-J-01 | open page | journey | P1 | loads | stub verified | PASS | none |\n'
    } > "$out"
    exit 0 ;;
  goal-evaluator)
    ev="$(printf '%s\n' "$prompt" | sed -n 's/^Write your verdict to: //p' | head -n1)"
    jh="$(printf '%s\n' "$prompt" | sed -n 's/^  Journey history: \([^ ]*\)  <--.*/\1/p' | head -n1)"
    el="$(printf '%s\n' "$prompt" | sed -n 's/^  Evaluator log: \([^ ]*\)  <--.*/\1/p' | head -n1)"
    st="$(printf '%s\n' "$prompt" | sed -n 's/^  Iteration state: \([^ ]*\)  <--.*/\1/p' | head -n1)"
    [[ -n "$ev" && -n "$jh" && -n "$el" ]] || exit 64
    # An obedient evaluator: verdict, history, log entry — and (REL-6) the
    # iteration-state digest at the path the prompt named. Missing prompt line
    # → st empty → no file → the placeholder/verbatim assertions go RED.
    mkdir -p "$(dirname "$ev")" "$(dirname "$jh")"
    printf '**Verdict:** CONTINUE\n**Depth Recommendation For Next Iteration:** lean\n\n## Summary\n\nBaseline: J-01 failing.\n' > "$ev"
    printf '{"journeys":{"J-01":{"id":"J-01","name":"open the page","status":"failing","last_verified_iter":"goal-istest-iter-0","last_passing_iter":null,"first_seen_iter":"goal-istest-iter-0"}},"anti_goal_violations":[],"updated_at":"2026-07-17T00:00:00Z"}\n' > "$jh"
    printf '## Iteration 0 — goal-istest-iter-0\n\n**Verdict:** CONTINUE\n' >> "$el"
    if [[ -n "$st" ]]; then
      mkdir -p "$(dirname "$st")"
      cat > "$st" <<'STATE'
# Iteration State — istest

**After iteration:** 0 · **Date:** 2026-07-17 · **Verdict:** CONTINUE

## Journeys

0 passing · 1 failing (J-01) — 1 total

## Active blockers

- none

## Last 2 verdicts

- iter 0: CONTINUE — baseline: J-01 failing, needs implementation (STATE-MARKER-1740)
- iter -1: n/a — first evaluated iteration

## Do not redo

- nothing yet (STATE-MARKER-1741)
STATE
    fi
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$STUB_DIR/claude"

echo "=== REL-6: one engine run — baseline placeholder, evaluator write, verbatim inline ==="

rc=0
( cd "$SBX" && env "PATH=$STUB_DIR:$PATH" \
    CHAIN_DOCTOR=false CHAIN_GOAL_LINT=false CHAIN_SESSION_RETRO=false \
    CHAIN_TMP_ROOT="$TMPROOT" CHAIN_TMP_LEGACY_ROOTS="" \
    CHAIN_BACKEND_PORT="$BE_PORT" CHAIN_FRONTEND_PORT="$FE_PORT" \
    CHAIN_KILL_GRACE_SECONDS=1 \
    timeout 240 bash scripts/automation/run-goal.sh \
      --session-id "$SID" --max-iter 2 --no-push-per-iter ) \
  > "$WORK/engine.log" 2>&1 || rc=$?

[[ "$rc" -eq 0 ]] && assert "engine run exits 0 (iter 0 complete, iter 1 paused AWAITING_PUMP)" "pass" \
  || { assert "engine run exits 0 (rc=$rc)" "fail"; sed -n '1,50p' "$WORK/engine.log"; }
grep -q "Interactive pump/dispatch unavailable during goal-decomposer" "$WORK/engine.log" \
  && assert "engine paused at the ITERATION-1 decomposer (not earlier)" "pass" \
  || assert "engine paused at the ITERATION-1 decomposer (not earlier)" "fail"

# ── 1. Iteration-0 decomposer prompt: placeholder, never a file inline ──────
P0="$(ls "$PROMPTS_DIR"/prompt-*-goal-decomposer.txt 2>/dev/null | sort -V | head -n1)"
P1="$(ls "$PROMPTS_DIR"/prompt-*-goal-decomposer.txt 2>/dev/null | sort -V | tail -n1)"
[[ -n "$P0" && -n "$P1" && "$P0" != "$P1" ]] \
  && assert "two decomposer dispatches captured (iter 0 + iter 1)" "pass" \
  || assert "two decomposer dispatches captured (got: $(ls "$PROMPTS_DIR" 2>/dev/null | tr '\n' ' '))" "fail"
grep -q "^Iteration state (single-file digest" "$P0" \
  && assert "iter-0 decomposer prompt carries the Iteration state block" "pass" \
  || assert "iter-0 decomposer prompt carries the Iteration state block" "fail"
grep -qF "(first iteration — no prior state)" "$P0" \
  && assert "iter-0 decomposer prompt inlines the PLACEHOLDER" "pass" \
  || assert "iter-0 decomposer prompt inlines the PLACEHOLDER" "fail"
grep -q "STATE-MARKER" "$P0" \
  && assert "iter-0 prompt has no state-file content (placeholder only)" "fail" \
  || assert "iter-0 prompt has no state-file content (placeholder only)" "pass"

# ── 2. Evaluator prompt carries the write instruction; the file landed ───────
PE="$(ls "$PROMPTS_DIR"/prompt-*-goal-evaluator.txt 2>/dev/null | head -n1)"
[[ -n "$PE" ]] && grep -q "^  Iteration state: " "$PE" \
  && grep -q "templates/iteration-state.md" "$PE" \
  && assert "evaluator prompt instructs the iteration-state overwrite (path + template named)" "pass" \
  || assert "evaluator prompt instructs the iteration-state overwrite (path + template named)" "fail"
[[ -f "$STATE_FILE" ]] \
  && assert "evaluator wrote state/iteration-state.md at the prompt-named path" "pass" \
  || assert "evaluator wrote state/iteration-state.md at the prompt-named path" "fail"
if python3 "$SBX/scripts/automation/lib/artifact_schemas.py" validate "$STATE_FILE" >/dev/null 2>&1; then
  assert "schema CLI accepts the conforming state file" "pass"
else
  assert "schema CLI accepts the conforming state file" "fail"
fi
OVER="$WORK/state-over-cap/state/iteration-state.md"
mkdir -p "$(dirname "$OVER")"
{ cat "$STATE_FILE" 2>/dev/null; for i in $(seq 1 45); do echo "- appended junk $i"; done; } > "$OVER"
if python3 "$SBX/scripts/automation/lib/artifact_schemas.py" validate "$OVER" >/dev/null 2>&1; then
  assert "schema CLI rejects an over-cap copy (>40 lines)" "fail"
else
  assert "schema CLI rejects an over-cap copy (>40 lines)" "pass"
fi

# ── 3. Iteration-1 decomposer prompt: the file VERBATIM, no placeholder ──────
_extract_state_block() {  # fenced block following the Iteration state label
  awk '/^Iteration state \(single-file digest/{lab=1;next}
       lab&&/^```$/{c++; if(c==2) exit; next}
       lab&&c==1{print}' "$1"
}
if [[ -f "$STATE_FILE" ]] && diff -q <(_extract_state_block "$P1") "$STATE_FILE" >/dev/null 2>&1; then
  assert "iter-1 decomposer prompt inlines the state file VERBATIM (byte-for-byte block)" "pass"
else
  assert "iter-1 decomposer prompt inlines the state file VERBATIM (byte-for-byte block)" "fail"
  diff <(_extract_state_block "$P1") "$STATE_FILE" 2>/dev/null | head -10 | sed 's/^/        /' || true
fi
grep -q "STATE-MARKER-1740" "$P1" && grep -q "STATE-MARKER-1741" "$P1" \
  && assert "iter-1 prompt carries both marker lines (verbatim content reached the reader)" "pass" \
  || assert "iter-1 prompt carries both marker lines (verbatim content reached the reader)" "fail"
grep -qF "(first iteration — no prior state)" "$P1" \
  && assert "iter-1 prompt no longer shows the placeholder" "fail" \
  || assert "iter-1 prompt no longer shows the placeholder" "pass"
grep -q "Do not redo.*BINDING\|BINDING — do not re-plan" "$P1" \
  && assert "iter-1 prompt states the do-not-redo binding rule" "pass" \
  || assert "iter-1 prompt states the do-not-redo binding rule" "fail"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
