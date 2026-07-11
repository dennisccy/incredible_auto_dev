#!/usr/bin/env bash
# test-goal-retro.sh — EVO-2 slices (a)+(b): session-retro collector +
# terminal-halt wiring + retro-analyst drafting dispatch
# (lib/retro_collect.sh + run-goal.sh write_session_summary/_run_retro_analyst).
#
# Part 1 drives lib/retro_collect.sh directly against synthetic session dirs:
#   1a. Full fixture → every stable section header, the right verdict sequence,
#       correct friction counters (attempt-1 review FAILs, malformed rewrites,
#       quota pauses), economics table, lessons tail, halt context.
#   1b. Degraded fixture (no telemetry.jsonl, empty lessons, quota source
#       deliberately omitted) → exit 0, explicit `unknown (<why>)` /
#       "none recorded" lines, output lands ONLY in state/.
#
# Part 2 drives the REAL run-goal.sh in a sandbox repo (consumer layout; stub
# `claude` on PATH: transport code 70 for gating dispatches, and it plays the
# retro-analyst drafting model — writing a minimal report to the output path
# parsed from the dispatch prompt, or exiting STUB_RETRO_RC when that is set):
#   W1. STALLED terminal halt        → retro-input.md AND the retro report
#       (reports/goal-session-<sid>-retro.md) BOTH exist, engine exits 0.
#   W2. AWAITING_PUMP resumable pause → NEITHER file exists, exit 0.
#   W3. CHAIN_SESSION_RETRO=false, STALLED → NEITHER file, exit 0.
#   W4. Collector forced to fail, STALLED → engine exit code UNCHANGED (0),
#       summary still written, non-fatal warning logged, NO agent dispatch
#       (no orphan retro report).
#   W5. Retro-analyst dispatch forced to fail, STALLED → halt exit code
#       unchanged (0), retro-input.md exists, no report, one warning logged —
#       plus the REL-11 [missing-evidence] banner (report absent after dispatch).
#   W6. Retro-analyst dispatch exits 0 but writes NOTHING (the baseline's
#       silent-void shape) → REL-11 tripwire: [missing-evidence] banner in the
#       engine log AND a missing_evidence telemetry event ({agent, path});
#       engine exit code still unchanged (0). W1 asserts the tripwire does NOT
#       fire when the report exists.
#
# Part 1c drives lib/common.sh warn_missing_evidence directly: banner + event
# with GOAL_SESSION_DIR set, banner-only (no crash) without telemetry sourced.
#
# No API calls, no network; runs in a few seconds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

COLLECTOR="$ENGINE_ROOT/scripts/automation/lib/retro_collect.sh"

# ── Part 1a: collector against a FULL synthetic session ──────────────────────
FIX="$WORK/fix-full"
mkdir -p "$FIX/state" "$FIX/iter-1"
cat > "$FIX/session.json" <<'EOF'
{"session_id":"fixfull","status":"STALLED","last_verdict":"CONTINUE","total_iterations":3,"finished_at":"2026-07-10T05:00:00Z","quota_pause_count":2,"parked_wip_sha":"abc1234","current_iter":3,"started_at":"2026-07-10T04:00:00Z"}
EOF
cat > "$FIX/telemetry.jsonl" <<'EOF'
{"ts":"t","session_id":"fixfull","iter":0,"event":"iter_end","cli":"claude","iter_name":"goal-fixfull-iter-0","verdict":"CONTINUE","next_depth":"lean"}
{"ts":"t","session_id":"fixfull","iter":1,"event":"review_verdict","cli":"claude","verdict":"FAIL","attempt":1,"iter_name":"goal-fixfull-iter-1"}
{"ts":"t","session_id":"fixfull","iter":1,"event":"review_verdict","cli":"claude","verdict":"PASS","attempt":2,"iter_name":"goal-fixfull-iter-1"}
{"ts":"t","session_id":"fixfull","iter":1,"event":"deterministic_gate","cli":"claude","raw":"","final":"CONTINUE"}
{"ts":"t","session_id":"fixfull","iter":1,"event":"iter_end","cli":"claude","iter_name":"goal-fixfull-iter-1","verdict":"CONTINUE","next_depth":"lean"}
{"ts":"t","session_id":"fixfull","iter":2,"event":"review_verdict","cli":"claude","verdict":"PASS","attempt":1,"iter_name":"goal-fixfull-iter-2"}
{"ts":"t","session_id":"fixfull","iter":2,"event":"deterministic_gate","cli":"claude","raw":"GOAL_ACHIEVED","final":"CONTINUE"}
{"ts":"t","session_id":"fixfull","iter":2,"event":"claude_usage","cli":"claude","agent":"developer","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":8000},"total_cost_usd":0.25,"duration_ms":65000}
{"ts":"t","session_id":"fixfull","iter":2,"event":"claude_usage","cli":"claude","agent":"goal-evaluator","usage":{"input_tokens":400,"output_tokens":200},"total_cost_usd":0.05,"duration_ms":30000}
{"ts":"t","session_id":"fixfull","iter":2,"event":"iter_end","cli":"claude","iter_name":"goal-fixfull-iter-2","verdict":"STALLED","next_depth":"lean"}
EOF
seq 1 30 | sed 's/^/lesson line /' > "$FIX/state/lessons.md"

rc=0; bash "$COLLECTOR" "$FIX" STALLED >/dev/null 2>&1 || rc=$?
RETRO="$FIX/state/retro-input.md"
[[ "$rc" -eq 0 && -f "$RETRO" ]] \
  && assert "1a: collector exits 0 and writes state/retro-input.md" "pass" \
  || assert "1a: collector exits 0 and writes state/retro-input.md (rc=$rc)" "fail"

_missing=""
for h in "## Outcome" "## Verdict sequence" "## Agent economics" "## Friction counters" "## Lessons tail" "## Halt context"; do
  grep -qF "$h" "$RETRO" 2>/dev/null || _missing="$_missing '$h'"
done
[[ -z "$_missing" ]] \
  && assert "1a: all stable section headers present" "pass" \
  || assert "1a: all stable section headers present (missing:$_missing)" "fail"

if printf '%s\n' "$(grep -E '^iter [0-9]+: ' "$RETRO" 2>/dev/null)" \
   | diff -q - <(printf 'iter 0: CONTINUE\niter 1: CONTINUE\niter 2: STALLED\n') >/dev/null 2>&1; then
  assert "1a: verdict sequence matches iter_end events in order" "pass"
else
  assert "1a: verdict sequence matches iter_end events in order" "fail"
fi

grep -qE '^\- \*\*Quota pauses:\*\* 2 ' "$RETRO" 2>/dev/null \
  && assert "1a: quota-pause count = 2 (from session.json)" "pass" \
  || assert "1a: quota-pause count = 2 (from session.json)" "fail"
grep -qE '^\- \*\*Attempt-1 review FAILs:\*\* 1 ' "$RETRO" 2>/dev/null \
  && assert "1a: attempt-1 review-FAIL count = 1 (attempt-2 not counted)" "pass" \
  || assert "1a: attempt-1 review-FAIL count = 1 (attempt-2 not counted)" "fail"
grep -qE '^\- \*\*Malformed-verdict rewrites:\*\* 1 ' "$RETRO" 2>/dev/null \
  && assert "1a: malformed count = 1 (valid-raw demotion not counted)" "pass" \
  || assert "1a: malformed count = 1 (valid-raw demotion not counted)" "fail"

grep -q '| developer | 1 | 65 | 1000 | 500 |' "$RETRO" 2>/dev/null \
  && assert "1a: economics table carries per-agent row" "pass" \
  || assert "1a: economics table carries per-agent row" "fail"

if grep -q 'lesson line 30' "$RETRO" 2>/dev/null && ! grep -q 'lesson line 5$' "$RETRO" 2>/dev/null; then
  assert "1a: lessons tail is the ~20-line tail (has 30, not 5)" "pass"
else
  assert "1a: lessons tail is the ~20-line tail (has 30, not 5)" "fail"
fi

grep -q '"parked_wip_sha": "abc1234"' "$RETRO" 2>/dev/null \
  && assert "1a: halt context includes parked_wip_sha" "pass" \
  || assert "1a: halt context includes parked_wip_sha" "fail"

# ── Part 1b: degraded fixture — deliberately omitted sources ─────────────────
FIX2="$WORK/fix-degraded"
mkdir -p "$FIX2/state"
# quota_pause_count omitted from session.json AND no .quota-pause-count file:
# the quota counter has NO source → must be a literal `unknown (<why>)`.
printf '{"session_id":"fixdeg","status":"BUDGET_EXHAUSTED","current_iter":1}\n' > "$FIX2/session.json"
touch "$FIX2/state/lessons.md"

rc=0; bash "$COLLECTOR" "$FIX2" BUDGET_EXHAUSTED >/dev/null 2>&1 || rc=$?
RETRO2="$FIX2/state/retro-input.md"
[[ "$rc" -eq 0 && -f "$RETRO2" ]] \
  && assert "1b: degraded inputs still exit 0 with retro-input.md" "pass" \
  || assert "1b: degraded inputs still exit 0 with retro-input.md (rc=$rc)" "fail"
grep -qE '^\- \*\*Quota pauses:\*\* unknown \(' "$RETRO2" 2>/dev/null \
  && assert "1b: sourceless quota counter is literal 'unknown (<why>)'" "pass" \
  || assert "1b: sourceless quota counter is literal 'unknown (<why>)'" "fail"
if grep -qE '^\- \*\*Attempt-1 review FAILs:\*\* unknown \(' "$RETRO2" 2>/dev/null \
   && grep -qE '^\- \*\*Malformed-verdict rewrites:\*\* unknown \(' "$RETRO2" 2>/dev/null; then
  assert "1b: telemetry-less counters degrade to 'unknown (<why>)'" "pass"
else
  assert "1b: telemetry-less counters degrade to 'unknown (<why>)'" "fail"
fi
grep -q 'none recorded' "$RETRO2" 2>/dev/null \
  && assert "1b: missing sections degrade to explicit 'none recorded'" "pass" \
  || assert "1b: missing sections degrade to explicit 'none recorded'" "fail"
_stray="$(find "$FIX2" -newer "$FIX2/session.json" -type f ! -path "$FIX2/state/*" 2>/dev/null || true)"
[[ -z "$_stray" ]] \
  && assert "1b: collector wrote nothing outside <session-dir>/state/" "pass" \
  || assert "1b: collector wrote nothing outside <session-dir>/state/ ($_stray)" "fail"

# ── Part 1c: warn_missing_evidence helper (REL-11), driven directly ──────────
HLP="$WORK/helper-sess"
mkdir -p "$HLP"
_hout="$(GOAL_SESSION_DIR="$HLP" GOAL_SESSION_ID="helper-test" bash -c '
  source "'"$ENGINE_ROOT"'/scripts/automation/lib/common.sh"
  source "'"$ENGINE_ROOT"'/scripts/automation/lib/telemetry.sh"
  warn_missing_evidence "qa" "/expected/report.md"
' 2>&1)" || true
if grep -q "\[missing-evidence\] agent 'qa' returned WITHOUT its expected report" <<<"$_hout" \
   && grep -qF "/expected/report.md" <<<"$_hout"; then
  assert "1c: helper prints the loud banner naming agent + expected path" "pass"
else
  assert "1c: helper prints the loud banner naming agent + expected path" "fail"
fi
if [[ -f "$HLP/telemetry.jsonl" ]] \
   && grep -q '"event":"missing_evidence"' "$HLP/telemetry.jsonl" \
   && grep -q '"agent":"qa"' "$HLP/telemetry.jsonl" \
   && grep -q '"path":"/expected/report.md"' "$HLP/telemetry.jsonl"; then
  assert "1c: missing_evidence telemetry event recorded ({agent, path})" "pass"
else
  assert "1c: missing_evidence telemetry event recorded ({agent, path})" "fail"
fi
# Without telemetry.sh sourced (phase-mode shape): banner only, no crash.
_hrc=0
_hout2="$(bash -c '
  source "'"$ENGINE_ROOT"'/scripts/automation/lib/common.sh"
  warn_missing_evidence "qa" "/expected/report.md"
' 2>&1)" || _hrc=$?
if [[ "$_hrc" -eq 0 ]] && grep -q "\[missing-evidence\]" <<<"$_hout2"; then
  assert "1c: telemetry-less caller still gets the banner and exits 0" "pass"
else
  assert "1c: telemetry-less caller still gets the banner and exits 0 (rc=$_hrc)" "fail"
fi

# ── Part 2: wiring through the REAL run-goal.sh ───────────────────────────────
SBX="$WORK/proj"
mkdir -p "$SBX"
cp -r "$ENGINE_ROOT/scripts" "$SBX/"
mkdir -p "$SBX/docs/phases" "$SBX/reports"
# Rendered-mirror marker so ensure_cli_assets_synced is a no-op (the sandbox has
# no neutral asset source to render from — same shape as a consumer repo with
# committed mirrors).
mkdir -p "$SBX/.claude/agents"
echo "stub" > "$SBX/.claude/agents/developer.md"
# _run_retro_analyst skips (by design) when the agent file is absent; the
# sandbox needs the marker so the dispatch path is actually exercised.
echo "stub" > "$SBX/.claude/agents/retro-analyst.md"
git init -q "$SBX"
cat > "$SBX/docs/goal.md" <<'EOF'
# Goal
## Must-have user journeys
- J-01: open the page. Acceptance: page loads.
## Anti-goals
- none
EOF
git -C "$SBX" add -A
git -C "$SBX" -c user.email=t@t -c user.name=t commit -qm base

# Stub claude: gating dispatches (decomposer etc.) fail with the transport code
# so the engine pauses AWAITING_PUMP fast (W2) — W1/W3/W4/W5 halt at loop top
# before any gating dispatch. A retro-analyst dispatch (slice b, fired from
# inside write_session_summary on terminal halts) instead plays the drafting
# model: exit STUB_RETRO_RC when set (W5), else write a minimal report to the
# output path named in the prompt (W1).
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<'EOF'
#!/usr/bin/env bash
prompt="$*"
if [[ "$prompt" == *"retro-analyst agent"* ]]; then
  [[ -n "${STUB_RETRO_RC:-}" ]] && exit "$STUB_RETRO_RC"
  # W6: the baseline's silent-void shape — dispatch "succeeds", writes nothing.
  [[ -n "${STUB_RETRO_SILENT:-}" ]] && exit 0
  out="$(printf '%s\n' "$prompt" | sed -n 's/^Output path (the retro report): //p' | head -n1)"
  [[ -n "$out" ]] || exit 64
  mkdir -p "$(dirname "$out")"
  printf '# Session retro — stub\n\n> **PROPOSALS ONLY** — stub-authored report.\n\n## Candidate items\n\nnothing recurred worth proposing (stub).\n' > "$out"
  exit 0
fi
exit 70
EOF
chmod +x "$STUB_DIR/claude"

# Fabricate a resumable mid-session state (current_iter=1, push explicitly off
# so the GitHub preflight is skipped and no branch lifecycle runs).
make_session() {
  local sid="$1"
  local d="$SBX/runs/goal-session-$sid"
  mkdir -p "$d/state"
  cat > "$d/session.json" <<EOF
{
  "session_id": "$sid",
  "started_at": "2026-07-10T00:00:00Z",
  "current_iter": 1,
  "cli": "claude",
  "agent_backend": "headless",
  "halt_config": {"max_iterations": 0, "stall_window": 3, "regression_halt": true},
  "status": "in_progress",
  "last_verdict": "CONTINUE",
  "next_depth": "lean",
  "auto_release": false,
  "push_per_iter": false,
  "push_branch": ""
}
EOF
  echo '{"journeys":{},"anti_goal_violations":[],"updated_at":""}' > "$d/state/journey-history.json"
  printf 'lesson: keep tests offline\n' > "$d/state/lessons.md"
  : > "$d/state/evaluator-log.md"
  echo "0" > "$d/.quota-pause-count"
}

# Three identical journey-history hashes → is_stalled(3) fires at loop top
# (a zero-dispatch terminal STALLED halt).
make_stalled() {
  printf 'aaaa\naaaa\naaaa\n' > "$SBX/runs/goal-session-$1/.history-hashes"
}

run_engine() {  # run_engine <sid> [ENV=val ...] — engine log in $WORK/engine-<sid>.log
  local sid="$1"; shift
  ( cd "$SBX" && PATH="$STUB_DIR:$PATH" \
      CHAIN_BACKEND_PORT=48311 CHAIN_FRONTEND_PORT=48312 \
      env "$@" bash scripts/automation/run-goal.sh --resume --session-id "$sid" ) \
    >"$WORK/engine-$sid.log" 2>&1
}

session_status() {
  python3 -c "import json; print(json.load(open('$SBX/runs/goal-session-$1/session.json')).get('status'))" 2>/dev/null || echo "unreadable"
}

# ── W1: STALLED terminal halt → retro fires ──────────────────────────────────
make_session w1; make_stalled w1
rc=0; run_engine w1 || rc=$?
D1="$SBX/runs/goal-session-w1"
[[ "$rc" -eq 0 && "$(session_status w1)" == "STALLED" ]] \
  && assert "W1: engine halted STALLED with exit 0" "pass" \
  || { assert "W1: engine halted STALLED with exit 0 (rc=$rc, status=$(session_status w1))" "fail"; sed -n '1,25p' "$WORK/engine-w1.log"; }
[[ -f "$D1/state/retro-input.md" ]] \
  && assert "W1: STALLED terminal halt produced state/retro-input.md" "pass" \
  || assert "W1: STALLED terminal halt produced state/retro-input.md" "fail"
grep -q '^\- \*\*Terminal status:\*\* STALLED' "$D1/state/retro-input.md" 2>/dev/null \
  && assert "W1: retro-input.md records the STALLED terminal status" "pass" \
  || assert "W1: retro-input.md records the STALLED terminal status" "fail"
# Slice (b): the same terminal halt also dispatches the retro-analyst, which
# (stub-played) writes the report — the item DoD's "both files".
[[ -f "$SBX/reports/goal-session-w1-retro.md" ]] \
  && assert "W1: retro-analyst dispatch produced reports/goal-session-w1-retro.md" "pass" \
  || assert "W1: retro-analyst dispatch produced reports/goal-session-w1-retro.md" "fail"
if ! grep -q "retro-analyst dispatch failed" "$WORK/engine-w1.log" 2>/dev/null \
   && ! grep -q "retro-analyst not dispatched" "$WORK/engine-w1.log" 2>/dev/null; then
  assert "W1: clean dispatch — no retro-analyst warning in engine log" "pass"
else
  assert "W1: clean dispatch — no retro-analyst warning in engine log" "fail"
fi
# REL-11 no-fire side: report exists → no tripwire banner, no telemetry event.
if ! grep -q '\[missing-evidence\]' "$WORK/engine-w1.log" 2>/dev/null \
   && ! grep -q '"event":"missing_evidence"' "$D1/telemetry.jsonl" 2>/dev/null; then
  assert "W1: missing-evidence tripwire does NOT fire when the report exists" "pass"
else
  assert "W1: missing-evidence tripwire does NOT fire when the report exists" "fail"
fi

# ── W2: AWAITING_PUMP resumable pause → no retro ─────────────────────────────
make_session w2   # no stall hashes; decomposer dispatch hits the stub's exit 70
rc=0; run_engine w2 || rc=$?
D2="$SBX/runs/goal-session-w2"
[[ "$rc" -eq 0 && "$(session_status w2)" == "AWAITING_PUMP" ]] \
  && assert "W2: engine paused AWAITING_PUMP with exit 0" "pass" \
  || { assert "W2: engine paused AWAITING_PUMP with exit 0 (rc=$rc, status=$(session_status w2))" "fail"; sed -n '1,25p' "$WORK/engine-w2.log"; }
[[ -f "$D2/summary.md" && ! -f "$D2/state/retro-input.md" ]] \
  && assert "W2: resumable pause wrote summary.md but NO retro-input.md" "pass" \
  || assert "W2: resumable pause wrote summary.md but NO retro-input.md" "fail"
[[ ! -f "$SBX/reports/goal-session-w2-retro.md" ]] \
  && assert "W2: resumable pause dispatched no retro-analyst (no report)" "pass" \
  || assert "W2: resumable pause dispatched no retro-analyst (no report)" "fail"

# ── W3: CHAIN_SESSION_RETRO=false → no retro on a terminal halt ──────────────
make_session w3; make_stalled w3
rc=0; run_engine w3 CHAIN_SESSION_RETRO=false || rc=$?
D3="$SBX/runs/goal-session-w3"
[[ "$rc" -eq 0 && "$(session_status w3)" == "STALLED" && ! -f "$D3/state/retro-input.md" ]] \
  && assert "W3: CHAIN_SESSION_RETRO=false suppresses the retro on STALLED" "pass" \
  || assert "W3: CHAIN_SESSION_RETRO=false suppresses the retro on STALLED (rc=$rc, status=$(session_status w3))" "fail"
[[ ! -f "$SBX/reports/goal-session-w3-retro.md" ]] \
  && assert "W3: knob off also suppresses the retro-analyst dispatch (no report)" "pass" \
  || assert "W3: knob off also suppresses the retro-analyst dispatch (no report)" "fail"

# ── W4: broken collector → engine exit code unchanged, summary intact ────────
printf '#!/usr/bin/env bash\nexit 1\n' > "$SBX/scripts/automation/lib/retro_collect.sh"
make_session w4; make_stalled w4
rc=0; run_engine w4 || rc=$?
D4="$SBX/runs/goal-session-w4"
[[ "$rc" -eq 0 && "$(session_status w4)" == "STALLED" ]] \
  && assert "W4: broken collector leaves engine exit code unchanged (0)" "pass" \
  || { assert "W4: broken collector leaves engine exit code unchanged (rc=$rc)" "fail"; sed -n '1,25p' "$WORK/engine-w4.log"; }
[[ -f "$D4/summary.md" && ! -f "$D4/state/retro-input.md" ]] \
  && assert "W4: summary.md still written; no retro-input.md" "pass" \
  || assert "W4: summary.md still written; no retro-input.md" "fail"
grep -q "session retro collector failed (non-blocking)" "$WORK/engine-w4.log" 2>/dev/null \
  && assert "W4: non-fatal warning logged" "pass" \
  || assert "W4: non-fatal warning logged" "fail"
# Slice (b): no digest → no dispatch. The wrapper must refuse (one message)
# rather than send the agent off without its single input file.
[[ ! -f "$SBX/reports/goal-session-w4-retro.md" ]] \
  && assert "W4: broken collector → no retro-analyst dispatch (no orphan report)" "pass" \
  || assert "W4: broken collector → no retro-analyst dispatch (no orphan report)" "fail"
grep -q "retro-analyst not dispatched" "$WORK/engine-w4.log" 2>/dev/null \
  && assert "W4: wrapper logged the not-dispatched reason" "pass" \
  || assert "W4: wrapper logged the not-dispatched reason" "fail"

# ── W5: retro-analyst dispatch fails → halt exit code unchanged ──────────────
# W4 replaced the sandbox collector with `exit 1`; restore the real one so the
# digest exists and the DISPATCH (forced to exit 1 via STUB_RETRO_RC) is the
# only failing piece.
cp "$ENGINE_ROOT/scripts/automation/lib/retro_collect.sh" "$SBX/scripts/automation/lib/retro_collect.sh"
make_session w5; make_stalled w5
rc=0; run_engine w5 STUB_RETRO_RC=1 || rc=$?
D5="$SBX/runs/goal-session-w5"
[[ "$rc" -eq 0 && "$(session_status w5)" == "STALLED" ]] \
  && assert "W5: failed retro dispatch leaves engine exit code unchanged (0)" "pass" \
  || { assert "W5: failed retro dispatch leaves engine exit code unchanged (rc=$rc)" "fail"; sed -n '1,25p' "$WORK/engine-w5.log"; }
[[ -f "$D5/state/retro-input.md" && ! -f "$SBX/reports/goal-session-w5-retro.md" ]] \
  && assert "W5: digest written, no report (dispatch failed)" "pass" \
  || assert "W5: digest written, no report (dispatch failed)" "fail"
grep -q "retro-analyst dispatch failed (non-blocking)" "$WORK/engine-w5.log" 2>/dev/null \
  && assert "W5: non-blocking dispatch-failure warning logged" "pass" \
  || assert "W5: non-blocking dispatch-failure warning logged" "fail"
# REL-11: a failed dispatch also left no report → tripwire fires here too.
grep -q "\[missing-evidence\] agent 'retro-analyst'" "$WORK/engine-w5.log" 2>/dev/null \
  && assert "W5: missing-evidence banner also fires on a failed dispatch with no report" "pass" \
  || assert "W5: missing-evidence banner also fires on a failed dispatch with no report" "fail"

# ── W6: dispatch exits 0, writes NOTHING → REL-11 tripwire fires ──────────────
# The baseline benchmark's exact silent-void shape (rc=0, no artifact).
make_session w6; make_stalled w6
rc=0; run_engine w6 STUB_RETRO_SILENT=1 || rc=$?
D6="$SBX/runs/goal-session-w6"
[[ "$rc" -eq 0 && "$(session_status w6)" == "STALLED" ]] \
  && assert "W6: silent retro dispatch leaves engine exit code unchanged (0)" "pass" \
  || { assert "W6: silent retro dispatch leaves engine exit code unchanged (rc=$rc)" "fail"; sed -n '1,25p' "$WORK/engine-w6.log"; }
[[ -f "$D6/state/retro-input.md" && ! -f "$SBX/reports/goal-session-w6-retro.md" ]] \
  && assert "W6: digest written, no report (dispatch silently wrote nothing)" "pass" \
  || assert "W6: digest written, no report (dispatch silently wrote nothing)" "fail"
if grep -q "\[missing-evidence\] agent 'retro-analyst' returned WITHOUT its expected report" "$WORK/engine-w6.log" 2>/dev/null \
   && grep -qF "reports/goal-session-w6-retro.md" "$WORK/engine-w6.log" 2>/dev/null; then
  assert "W6: [missing-evidence] banner names retro-analyst + the expected path" "pass"
else
  assert "W6: [missing-evidence] banner names retro-analyst + the expected path" "fail"
fi
if grep -q '"event":"missing_evidence"' "$D6/telemetry.jsonl" 2>/dev/null \
   && grep -q '"agent":"retro-analyst"' "$D6/telemetry.jsonl" 2>/dev/null \
   && grep -qF 'goal-session-w6-retro.md' "$D6/telemetry.jsonl" 2>/dev/null; then
  assert "W6: missing_evidence telemetry event recorded ({agent, path})" "pass"
else
  assert "W6: missing_evidence telemetry event recorded ({agent, path})" "fail"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
