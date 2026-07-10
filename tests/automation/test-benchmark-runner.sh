#!/usr/bin/env bash
# test-benchmark-runner.sh — EVO-3 slice (b): spend-gated benchmark runner
# (scripts/automation/run-benchmark.sh) + pre-registration ledger
# (benchmarks/experiments.md).
#
# Every case drives a COPY of the runner inside a skeleton framework repo under
# mktemp — never this repo (the dirty-tree case dirties the skeleton copy, and
# ledger/results writes land there). Coverage:
#
#   R1-R4  Refusals fire BEFORE any side effect (no scratch dir, ledger
#          byte-identical, no results file): no args → plan+estimate then
#          exit 2 (G9); --hypothesis without --yes-spend → exit 2 (G9);
#          --yes-spend without --hypothesis → exit 2 (G8: prediction precedes
#          execution); dirty framework tree → exit 2 unless --allow-dirty.
#          All four run WITH CHAIN_BENCH_ENGINE_CMD set: the seam sits
#          DOWNSTREAM of the gates and must not weaken them (G5).
#   A      Success run (stub engine, --keep-scratch): scratch = subrepo
#          framework set (.claude/ scripts/ config/ templates/ CLAUDE.md) +
#          fixture overlay (fixture's project-template OVERWRITES the
#          framework placeholder; .venv/__pycache__/do-not-copy canaries
#          excluded), fresh git repo (1 commit, deterministic author) with a
#          local bare origin that satisfies ls-remote; results JSON schema +
#          counts match the stub's known artifacts; PRE precedes POST;
#          --predict all-true → CONFIRMED. The stub itself asserts the PRE
#          ledger entry exists BEFORE the engine runs.
#   B      Success run without --keep-scratch: scratch workspace removed;
#          --predict all-false → REFUTED.
#   C      Engine exits nonzero: still a RESULT (results JSON + POST written,
#          runner exits 0, engine_exit_code recorded); scratch KEPT and its
#          path printed; --predict true+false → MIXED.
#   D      Engine writes nothing + dirty tree with --allow-dirty +
#          --results-dir override: missing sources become literal
#          "unknown (<why>)" values; framework_dirty:true + diffstat
#          recorded; no --predict → MANUAL verdict line.
#
# No API calls, no network; stub engines fabricate all session artifacts.

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

RUNNER_SRC="$ENGINE_ROOT/scripts/automation/run-benchmark.sh"
LEDGER_SRC="$ENGINE_ROOT/benchmarks/experiments.md"

[[ -f "$RUNNER_SRC" ]] \
  && assert "runner exists (scripts/automation/run-benchmark.sh)" "pass" \
  || assert "runner exists (scripts/automation/run-benchmark.sh)" "fail"
[[ -f "$LEDGER_SRC" ]] \
  && assert "committed ledger exists (benchmarks/experiments.md)" "pass" \
  || assert "committed ledger exists (benchmarks/experiments.md)" "fail"
if grep -qi "append-only" "$LEDGER_SRC" 2>/dev/null; then
  assert "ledger header states the append-only rule" "pass"
else
  assert "ledger header states the append-only rule" "fail"
fi
if [[ ! -f "$RUNNER_SRC" || ! -f "$LEDGER_SRC" ]]; then
  echo ""
  echo "=== Results: $PASS passed, $FAIL failed (aborting: slice-(b) artifacts missing) ==="
  exit 1
fi

# ── Skeleton framework repo (consumer/subrepo layout) ─────────────────────────
# Canary files sit in every directory the runner must NOT copy into scratch.
SKEL="$WORK/skeleton"
mkdir -p "$SKEL/scripts/automation/lib" "$SKEL/.claude" "$SKEL/config" \
         "$SKEL/templates" "$SKEL/benchmarks/fixtures"
cp "$RUNNER_SRC" "$SKEL/scripts/automation/run-benchmark.sh"
cp "$ENGINE_ROOT/scripts/automation/lib/analyze_telemetry.py" "$SKEL/scripts/automation/lib/"
cp "$LEDGER_SRC" "$SKEL/benchmarks/experiments.md"
echo "FRAMEWORK-PLACEHOLDER project template (fixture copy must overwrite this)" \
  > "$SKEL/.claude/project-template.md"
echo "# skeleton core rules" > "$SKEL/.claude/core.md"
echo "# CLAUDE.md (skeleton)" > "$SKEL/CLAUDE.md"
printf 'tiers:\n  strong: skeleton-model\n' > "$SKEL/config/model-tiers.yaml"
echo "goal template" > "$SKEL/templates/project-goal.md"
for d in docs tests runs reports agents skills commands hooks policy; do
  mkdir -p "$SKEL/$d"
  echo "canary — must NOT be copied into scratch" > "$SKEL/$d/do-not-copy-canary.txt"
done
# Real fixture, minus its gitignored runtime dirs; then plant canary versions
# of those dirs to prove the runner's overlay excludes them.
( cd "$ENGINE_ROOT/benchmarks/fixtures" \
  && tar --exclude='todo-app/.venv' --exclude='todo-app/__pycache__' \
         --exclude='todo-app/.pytest_cache' --exclude='todo-app/todos.json' \
         -cf - todo-app ) \
  | ( cd "$SKEL/benchmarks/fixtures" && tar -xf - )
mkdir -p "$SKEL/benchmarks/fixtures/todo-app/.venv" \
         "$SKEL/benchmarks/fixtures/todo-app/__pycache__" \
         "$SKEL/benchmarks/fixtures/todo-app/.pytest_cache"
echo "venv canary" > "$SKEL/benchmarks/fixtures/todo-app/.venv/canary.txt"
echo "pycache canary" > "$SKEL/benchmarks/fixtures/todo-app/__pycache__/canary.txt"
echo "pytest canary" > "$SKEL/benchmarks/fixtures/todo-app/.pytest_cache/canary.txt"
git -C "$SKEL" init -q -b main
git -C "$SKEL" add -A
git -C "$SKEL" -c user.name=t -c user.email=t@t commit -qm "skeleton"
SKEL_SHA="$(git -C "$SKEL" rev-parse HEAD)"
TIERS_SHA="$(sha256sum "$SKEL/config/model-tiers.yaml" | awk '{print $1}')"

# ── Stub engines ──────────────────────────────────────────────────────────────
# Contract (documented in the runner header): the seam command runs with
# cwd=scratch, CHAIN_AGENT_BACKEND=headless, and CHAIN_BENCH_SESSION_ID set.
# BENCH_TEST_LEDGER / BENCH_TEST_CHECKFILE are test-side envs passed through.
STUBS="$WORK/stubs"
mkdir -p "$STUBS"

# stub-ok: assert the PRE entry already exists (prediction precedes execution),
# then fabricate a full set of plausible session artifacts and exit 0.
# Known ground truth: attempt-1 review FAILs = 1 (the attempt-2 FAIL-then-PASS
# and the clean attempt-1 PASS don't count), malformed verdicts = 1 (raw:"" —
# the valid-raw GOAL_ACHIEVED→CONTINUE demotion doesn't count), journeys 2/3
# passing (passing + already_passing), tokens in=1400 out=700, cost=0.30.
cat > "$STUBS/stub-ok.sh" <<'EOF'
#!/usr/bin/env bash
set -u
sid="${CHAIN_BENCH_SESSION_ID:?}"
{
  echo "cwd=$(pwd)"
  echo "backend=${CHAIN_AGENT_BACKEND:-}"
  if grep -q "^## PRE ${sid}" "${BENCH_TEST_LEDGER:?}" 2>/dev/null; then
    echo "pre=FOUND"
  else
    echo "pre=MISSING"
  fi
} > "${BENCH_TEST_CHECKFILE:?}"
d="runs/goal-session-${sid}"
mkdir -p "$d/state"
cat > "$d/session.json" <<EOS
{"session_id":"$sid","status":"STALLED","last_verdict":"CONTINUE","current_iter":2,"push_per_iter":true,"push_branch":"goal/$sid"}
EOS
cat > "$d/state/journey-history.json" <<'EOS'
{"journeys":{"J-01":{"status":"passing"},"J-02":{"status":"already_passing"},"J-03":{"status":"failing"}},"anti_goal_violations":[],"updated_at":"t"}
EOS
cat > "$d/telemetry.jsonl" <<EOS
{"ts":"t","session_id":"$sid","iter":1,"event":"review_verdict","cli":"claude","verdict":"FAIL","attempt":1,"iter_name":"goal-$sid-iter-1"}
{"ts":"t","session_id":"$sid","iter":1,"event":"review_verdict","cli":"claude","verdict":"PASS","attempt":2,"iter_name":"goal-$sid-iter-1"}
{"ts":"t","session_id":"$sid","iter":1,"event":"deterministic_gate","cli":"claude","raw":"","final":"CONTINUE"}
{"ts":"t","session_id":"$sid","iter":1,"event":"iter_end","cli":"claude","iter_name":"goal-$sid-iter-1","verdict":"CONTINUE","next_depth":"lean"}
{"ts":"t","session_id":"$sid","iter":2,"event":"review_verdict","cli":"claude","verdict":"PASS","attempt":1,"iter_name":"goal-$sid-iter-2"}
{"ts":"t","session_id":"$sid","iter":2,"event":"deterministic_gate","cli":"claude","raw":"GOAL_ACHIEVED","final":"CONTINUE"}
{"ts":"t","session_id":"$sid","iter":2,"event":"claude_usage","cli":"claude","agent":"developer","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":8000},"total_cost_usd":0.25,"duration_ms":65000}
{"ts":"t","session_id":"$sid","iter":2,"event":"claude_usage","cli":"claude","agent":"goal-evaluator","usage":{"input_tokens":400,"output_tokens":200},"total_cost_usd":0.05,"duration_ms":30000}
{"ts":"t","session_id":"$sid","iter":2,"event":"iter_end","cli":"claude","iter_name":"goal-$sid-iter-2","verdict":"STALLED","next_depth":"lean"}
EOS
exit 0
EOF

# stub-fail: same artifacts, but the engine "crashed" afterwards (exit 3).
sed 's/^exit 0$/exit 3/' "$STUBS/stub-ok.sh" > "$STUBS/stub-fail.sh"

# stub-empty: PRE check only; writes NO session artifacts; exits 0.
cat > "$STUBS/stub-empty.sh" <<'EOF'
#!/usr/bin/env bash
set -u
sid="${CHAIN_BENCH_SESSION_ID:?}"
{
  echo "cwd=$(pwd)"
  echo "backend=${CHAIN_AGENT_BACKEND:-}"
  if grep -q "^## PRE ${sid}" "${BENCH_TEST_LEDGER:?}" 2>/dev/null; then
    echo "pre=FOUND"
  else
    echo "pre=MISSING"
  fi
} > "${BENCH_TEST_CHECKFILE:?}"
exit 0
EOF
chmod +x "$STUBS"/*.sh

# ── Case helpers ──────────────────────────────────────────────────────────────
CASE=""; CTMP=""; CLEDGER=""; CHECKFILE=""
new_case() {  # $1 = case name
  local name="$1"
  CASE="$WORK/$name/repo"
  CTMP="$WORK/$name/tmp"          # TMPDIR handed to the runner: scratch lands here
  CHECKFILE="$WORK/$name/check.txt"
  mkdir -p "$WORK/$name" "$CTMP"
  cp -a "$SKEL" "$CASE"
  CLEDGER="$CASE/benchmarks/experiments.md"
}

RC=0; OUT=""
run_runner() {  # $1 = stub engine path ('' = no seam), rest = runner args
  local ec="$1"; shift
  RC=0
  if [[ -n "$ec" ]]; then
    OUT="$(cd "$CASE" && TMPDIR="$CTMP" \
             CHAIN_BENCH_ENGINE_CMD="bash $ec" \
             BENCH_TEST_LEDGER="$CLEDGER" BENCH_TEST_CHECKFILE="$CHECKFILE" \
             bash scripts/automation/run-benchmark.sh "$@" 2>&1)" || RC=$?
  else
    OUT="$(cd "$CASE" && TMPDIR="$CTMP" \
             bash scripts/automation/run-benchmark.sh "$@" 2>&1)" || RC=$?
  fi
}

no_side_effects() {  # $1 = case label for the assert message
  local label="$1"
  local tmp_entries
  tmp_entries="$(find "$CTMP" -mindepth 1 2>/dev/null | wc -l || true)"
  local results_count
  results_count="$(find "$CASE/benchmarks/results" -name '*.json' 2>/dev/null | wc -l || true)"
  if [[ "$tmp_entries" -eq 0 && "$results_count" -eq 0 ]] \
     && cmp -s "$CLEDGER" "$SKEL/benchmarks/experiments.md"; then
    assert "$label: refused before ANY side effect (no scratch, ledger untouched, no results)" "pass"
  else
    assert "$label: refused before ANY side effect (tmp=$tmp_entries results=$results_count)" "fail"
  fi
}

# ── R1: no args → plan + estimate, refuse exit 2 (G9) ────────────────────────
new_case r1
run_runner "$STUBS/stub-ok.sh"
[[ "$RC" -eq 2 ]] \
  && assert "R1: no args exits 2 even with the engine seam set (gates upstream of seam)" "pass" \
  || assert "R1: no args exits 2 even with the engine seam set (rc=$RC)" "fail"
if grep -qi "estimate" <<<"$OUT" && grep -q -- "--yes-spend" <<<"$OUT" && grep -qi "refus" <<<"$OUT"; then
  assert "R1: prints plan + cost/time estimate and the G9 refusal" "pass"
else
  assert "R1: prints plan + cost/time estimate and the G9 refusal" "fail"
fi
no_side_effects "R1"

# ── R2: hypothesis but no --yes-spend → exit 2 (G9) ──────────────────────────
new_case r2
run_runner "$STUBS/stub-ok.sh" --hypothesis "wall time drops" --predict 'journeys_passing_after>=2'
[[ "$RC" -eq 2 ]] && grep -q -- "--yes-spend" <<<"$OUT" \
  && assert "R2: --hypothesis without --yes-spend refused (exit 2, names the flag)" "pass" \
  || assert "R2: --hypothesis without --yes-spend refused (rc=$RC)" "fail"
no_side_effects "R2"

# ── R3: --yes-spend but no hypothesis → exit 2 (G8) ──────────────────────────
new_case r3
run_runner "$STUBS/stub-ok.sh" --yes-spend
[[ "$RC" -eq 2 ]] && grep -qi "hypothesis" <<<"$OUT" \
  && assert "R3: --yes-spend without --hypothesis refused (G8: prediction precedes execution)" "pass" \
  || assert "R3: --yes-spend without --hypothesis refused (rc=$RC)" "fail"
no_side_effects "R3"

# ── R4: dirty framework tree → exit 2 unless --allow-dirty ───────────────────
new_case r4
echo "dirt" > "$CASE/scripts/uncommitted-dirt.txt"
run_runner "$STUBS/stub-ok.sh" --yes-spend --hypothesis "h"
[[ "$RC" -eq 2 ]] && grep -qi "dirty" <<<"$OUT" && grep -q -- "--allow-dirty" <<<"$OUT" \
  && assert "R4: dirty framework tree refused (exit 2, names --allow-dirty)" "pass" \
  || assert "R4: dirty framework tree refused (rc=$RC)" "fail"
no_side_effects "R4"

# ── A: success + --keep-scratch + all-true predicates → CONFIRMED ────────────
new_case a
run_runner "$STUBS/stub-ok.sh" --yes-spend --keep-scratch \
  --hypothesis "the chain reaches 2/3 journeys in 2 lean iterations" \
  --predict 'journeys_passing_after>=2' --predict 'final_status==STALLED'
[[ "$RC" -eq 0 ]] \
  && assert "A: successful benchmark run exits 0" "pass" \
  || { assert "A: successful benchmark run exits 0 (rc=$RC)" "fail"; printf '%s\n' "$OUT" | tail -20; }

grep -q "^pre=FOUND$" "$CHECKFILE" 2>/dev/null \
  && assert "A: PRE ledger entry existed BEFORE the engine ran (stub-asserted)" "pass" \
  || assert "A: PRE ledger entry existed BEFORE the engine ran (stub-asserted)" "fail"
grep -q "^backend=headless$" "$CHECKFILE" 2>/dev/null \
  && assert "A: engine launched with CHAIN_AGENT_BACKEND=headless" "pass" \
  || assert "A: engine launched with CHAIN_AGENT_BACKEND=headless" "fail"

SCRATCH="$(find "$CTMP" -mindepth 2 -maxdepth 2 -type d -name scratch | head -n1)"
if [[ -n "$SCRATCH" && -d "$SCRATCH" ]]; then
  assert "A: --keep-scratch kept the scratch workspace" "pass"
else
  assert "A: --keep-scratch kept the scratch workspace" "fail"
  SCRATCH="$CTMP/__missing__"
fi
grep -q "^cwd=$SCRATCH$" "$CHECKFILE" 2>/dev/null \
  && assert "A: engine ran with cwd=scratch (REPO_ROOT resolves to scratch)" "pass" \
  || assert "A: engine ran with cwd=scratch (REPO_ROOT resolves to scratch)" "fail"

_missing=""
for p in .claude/core.md .claude/project-template.md scripts/automation/run-benchmark.sh \
         config/model-tiers.yaml templates/project-goal.md CLAUDE.md \
         app.py test_app.py docs/goal.md templates/index.html static/app.js .gitignore; do
  [[ -e "$SCRATCH/$p" ]] || _missing="$_missing $p"
done
[[ -z "$_missing" ]] \
  && assert "A: scratch has framework set + fixture overlay" "pass" \
  || assert "A: scratch has framework set + fixture overlay (missing:$_missing)" "fail"

if grep -q "EVO-3 benchmark fixture" "$SCRATCH/.claude/project-template.md" 2>/dev/null \
   && ! grep -q "FRAMEWORK-PLACEHOLDER" "$SCRATCH/.claude/project-template.md" 2>/dev/null; then
  assert "A: fixture project-template.md OVERWRITES the framework placeholder" "pass"
else
  assert "A: fixture project-template.md OVERWRITES the framework placeholder" "fail"
fi

_leaked=""
for d in tests runs reports agents skills commands hooks policy; do
  [[ -e "$SCRATCH/$d/do-not-copy-canary.txt" ]] && _leaked="$_leaked $d"
done
[[ -e "$SCRATCH/docs/do-not-copy-canary.txt" ]] && _leaked="$_leaked docs"
[[ -e "$SCRATCH/benchmarks" ]] && _leaked="$_leaked benchmarks(recursion)"
[[ -e "$SCRATCH/.git-canary" ]] && _leaked="$_leaked .git-canary"
for d in .venv __pycache__ .pytest_cache; do
  [[ -e "$SCRATCH/$d/canary.txt" ]] && _leaked="$_leaked $d"
done
[[ -z "$_leaked" ]] \
  && assert "A: do-not-copy set stayed out of scratch (docs/tests/runs/reports/neutral-sources/benchmarks/.venv)" "pass" \
  || assert "A: do-not-copy set leaked into scratch:$_leaked" "fail"

_commits="$(git -C "$SCRATCH" rev-list --count HEAD 2>/dev/null || echo 0)"
_author="$(git -C "$SCRATCH" log -1 --format='%an <%ae>' 2>/dev/null || true)"
[[ "$_commits" == "1" && "$_author" == "goal-chain <goal-chain@localhost>" ]] \
  && assert "A: scratch is a fresh git repo (1 commit, deterministic author)" "pass" \
  || assert "A: scratch is a fresh git repo (commits=$_commits author=$_author)" "fail"

_origin_url="$(git -C "$SCRATCH" remote get-url origin 2>/dev/null || true)"
if [[ -n "$_origin_url" && -f "$_origin_url/HEAD" ]] \
   && git -C "$SCRATCH" ls-remote --heads origin >/dev/null 2>&1; then
  assert "A: local bare origin wired up and ls-remote-reachable (GitHub preflight shape)" "pass"
else
  assert "A: local bare origin wired up and ls-remote-reachable (url=$_origin_url)" "fail"
fi

RESULTS_FILE="$(find "$CASE/benchmarks/results" -name '*.json' 2>/dev/null | head -n1 || true)"
[[ -n "$RESULTS_FILE" ]] \
  && assert "A: results JSON written under benchmarks/results/" "pass" \
  || { assert "A: results JSON written under benchmarks/results/" "fail"; RESULTS_FILE="/dev/null"; }

_pyout="$(python3 - "$RESULTS_FILE" "$SKEL_SHA" "$TIERS_SHA" <<'PYEOF'
import json, re, sys
path, skel_sha, tiers_sha = sys.argv[1], sys.argv[2], sys.argv[3]
bad = []
def check(name, cond):
    if not cond:
        bad.append(name)
try:
    r = json.load(open(path))
except Exception as e:
    print(f"unparseable: {e}"); sys.exit(0)
meta, out, eco = r.get("meta", {}), r.get("outcome", {}), r.get("economics", {})
check("framework_sha", meta.get("framework_sha") == skel_sha)
check("framework_dirty", meta.get("framework_dirty") is False)
check("fixture", meta.get("fixture") == "todo-app")
check("session_id", bool(re.match(r"^bench-\d{8}-\d{4}$", str(meta.get("session_id")))))
check("max_iter", meta.get("max_iter") == 2)
check("hypothesis", "2/3 journeys" in str(meta.get("hypothesis")))
check("model_tiers_sha256", meta.get("model_tiers_sha256") == tiers_sha)
env = meta.get("chain_env", {})
check("chain_env.backend", env.get("CHAIN_AGENT_BACKEND") == "headless")
check("chain_env.seam_visible", "CHAIN_BENCH_ENGINE_CMD" in env)
check("engine_exit_code", out.get("engine_exit_code") == 0)
check("final_status", out.get("final_status") == "STALLED")
check("last_verdict", out.get("last_verdict") == "CONTINUE")
check("iterations_used", out.get("iterations_used") == 2)
check("journeys_passing_after", out.get("journeys_passing_after") == 2)
check("journeys_total", out.get("journeys_total") == 3)
check("attempt1_review_fails", out.get("attempt1_review_fails") == 1)
check("malformed_verdicts", out.get("malformed_verdicts") == 1)
check("wall_seconds", isinstance(out.get("wall_seconds"), int) and out["wall_seconds"] >= 0)
agents = eco.get("agents", {})
sess = agents.get(meta.get("session_id"), {})
tot = sess.get("total", {})
check("economics.in_tokens", tot.get("gen_ai.usage.input_tokens") == 1400)
check("economics.out_tokens", tot.get("gen_ai.usage.output_tokens") == 700)
check("economics.cost", abs(float(tot.get("gen_ai.usage.total_cost_usd", 0)) - 0.30) < 1e-6)
check("economics.by_agent", set(sess.get("by_agent", {})) == {"developer", "goal-evaluator"})
print("ALL-OK" if not bad else "BAD: " + ", ".join(bad))
PYEOF
)"
[[ "$_pyout" == "ALL-OK" ]] \
  && assert "A: results JSON schema + counts match the stub's known artifacts" "pass" \
  || assert "A: results JSON schema + counts match the stub ($_pyout)" "fail"

SID_A="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['meta']['session_id'])" "$RESULTS_FILE" 2>/dev/null || echo none)"
_pre_ln="$(grep -n "^## PRE $SID_A" "$CLEDGER" | head -n1 | cut -d: -f1 || true)"
_post_ln="$(grep -n "^## POST $SID_A" "$CLEDGER" | head -n1 | cut -d: -f1 || true)"
if [[ -n "$_pre_ln" && -n "$_post_ln" && "$_pre_ln" -lt "$_post_ln" ]]; then
  assert "A: ledger has PRE then POST for the run id (in that order)" "pass"
else
  assert "A: ledger has PRE then POST for the run id (pre=$_pre_ln post=$_post_ln)" "fail"
fi
grep -q "verdict-vs-prediction: CONFIRMED" "$CLEDGER" \
  && assert "A: all-true predicates → CONFIRMED" "pass" \
  || assert "A: all-true predicates → CONFIRMED" "fail"
grep -qF "$(basename "$RESULTS_FILE")" "$CLEDGER" \
  && assert "A: POST entry cites the results file" "pass" \
  || assert "A: POST entry cites the results file" "fail"

# ── B: success without --keep-scratch → cleaned; all-false → REFUTED ─────────
new_case b
run_runner "$STUBS/stub-ok.sh" --yes-spend \
  --hypothesis "all journeys pass and the goal is achieved" \
  --predict 'journeys_passing_after>=3' --predict 'final_status==GOAL_ACHIEVED'
[[ "$RC" -eq 0 ]] \
  && assert "B: run exits 0" "pass" \
  || assert "B: run exits 0 (rc=$RC)" "fail"
_left="$(find "$CTMP" -mindepth 1 -maxdepth 1 | wc -l)"
[[ "$_left" -eq 0 ]] \
  && assert "B: scratch workspace removed on success (no --keep-scratch)" "pass" \
  || assert "B: scratch workspace removed on success (left=$_left)" "fail"
grep -q "verdict-vs-prediction: REFUTED" "$CLEDGER" \
  && assert "B: all-false predicates → REFUTED" "pass" \
  || assert "B: all-false predicates → REFUTED" "fail"

# ── C: engine exit 3 → still a RESULT; scratch kept; true+false → MIXED ──────
new_case c
run_runner "$STUBS/stub-fail.sh" --yes-spend \
  --hypothesis "engine survives" \
  --predict 'journeys_passing_after>=2' --predict 'final_status==GOAL_ACHIEVED'
[[ "$RC" -eq 0 ]] \
  && assert "C: nonzero engine is a RESULT, not a runner crash (runner exits 0)" "pass" \
  || assert "C: nonzero engine is a RESULT, not a runner crash (rc=$RC)" "fail"
RESULTS_C="$(find "$CASE/benchmarks/results" -name '*.json' 2>/dev/null | head -n1 || true)"
_ec="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['outcome']['engine_exit_code'])" "$RESULTS_C" 2>/dev/null || echo none)"
[[ "$_ec" == "3" ]] \
  && assert "C: engine_exit_code=3 recorded in results" "pass" \
  || assert "C: engine_exit_code=3 recorded in results (got $_ec)" "fail"
_kept="$(find "$CTMP" -mindepth 2 -maxdepth 2 -type d -name scratch | head -n1)"
[[ -n "$_kept" ]] \
  && assert "C: scratch kept on engine failure (without --keep-scratch)" "pass" \
  || assert "C: scratch kept on engine failure (without --keep-scratch)" "fail"
grep -qF "$CTMP" <<<"$OUT" \
  && assert "C: kept scratch path printed" "pass" \
  || assert "C: kept scratch path printed" "fail"
grep -q "verdict-vs-prediction: MIXED" "$CLEDGER" \
  && assert "C: true+false predicates → MIXED" "pass" \
  || assert "C: true+false predicates → MIXED" "fail"

# ── D: empty engine + dirty/--allow-dirty + --results-dir + MANUAL ───────────
new_case d
echo "dirt" > "$CASE/scripts/uncommitted-dirt.txt"
DOUT="$WORK/d/out"
run_runner "$STUBS/stub-empty.sh" --yes-spend --allow-dirty --results-dir "$DOUT" \
  --hypothesis "free-text prediction, graded by a human"
[[ "$RC" -eq 0 ]] \
  && assert "D: run exits 0" "pass" \
  || assert "D: run exits 0 (rc=$RC)" "fail"
RESULTS_D="$(find "$DOUT" -name '*.json' 2>/dev/null | head -n1 || true)"
[[ -n "$RESULTS_D" ]] \
  && assert "D: --results-dir override honored" "pass" \
  || { assert "D: --results-dir override honored" "fail"; RESULTS_D="/dev/null"; }
_pyout="$(python3 - "$RESULTS_D" <<'PYEOF'
import json, sys
bad = []
def check(name, cond):
    if not cond:
        bad.append(name)
try:
    r = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"unparseable: {e}"); sys.exit(0)
meta, out, eco = r.get("meta", {}), r.get("outcome", {}), r.get("economics", {})
check("framework_dirty", meta.get("framework_dirty") is True)
check("diffstat", isinstance(meta.get("framework_diffstat"), str) and len(meta["framework_diffstat"]) > 0)
for k in ("final_status", "last_verdict", "iterations_used",
          "journeys_passing_after", "journeys_total",
          "attempt1_review_fails", "malformed_verdicts"):
    v = out.get(k)
    check(k, isinstance(v, str) and v.startswith("unknown ("))
check("engine_exit_code", out.get("engine_exit_code") == 0)
check("economics.empty", eco.get("agents") == {})
check("economics.note", str(eco.get("note", "")).startswith("unknown ("))
print("ALL-OK" if not bad else "BAD: " + ", ".join(bad))
PYEOF
)"
[[ "$_pyout" == "ALL-OK" ]] \
  && assert "D: missing sources → literal 'unknown (<why>)'; dirty tree recorded with diffstat" "pass" \
  || assert "D: missing sources → literal 'unknown (<why>)' ($_pyout)" "fail"
grep -qF "verdict-vs-prediction: MANUAL — append CONFIRMED|REFUTED|MIXED after review" "$CLEDGER" \
  && assert "D: no --predict → MANUAL verdict line (runner never self-grades free text)" "pass" \
  || assert "D: no --predict → MANUAL verdict line (runner never self-grades free text)" "fail"
grep -q "^pre=FOUND$" "$CHECKFILE" 2>/dev/null \
  && assert "D: PRE entry preceded the engine here too" "pass" \
  || assert "D: PRE entry preceded the engine here too" "fail"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
