#!/usr/bin/env bash
# run-benchmark.sh — EVO-3 slice (b): spend-gated goal-mode benchmark runner.
#
# Copies the framework's documented subrepo set + the todo-app fixture into a
# scratch git repo (with a LOCAL BARE origin, so the engine's GitHub preflight
# and push-per-iter exercise their real code paths with zero network), runs
# the goal engine there capped at 2 iterations, extracts a results JSON, and
# keeps a pre-registered PRE/POST record in benchmarks/experiments.md.
#
# ── SPEND WARNING (ground rule G9) ────────────────────────────────────────────
# A REAL benchmark run dispatches ~2 lean goal-mode iterations of a tiny app:
# several HOURS of wall clock and order-of-DOLLARS of API spend. The script
# always prints the plan + estimate first and REFUSES to run without
# --yes-spend. It also REFUSES without --hypothesis: the PRE ledger entry is
# written BEFORE the engine launches (G8 — prediction precedes execution).
#
# Usage:
#   ./scripts/automation/run-benchmark.sh              # plan + estimate, refuse (exit 2)
#   ./scripts/automation/run-benchmark.sh \
#       --hypothesis '<one-line prediction>' [--predict '<expr>']... \
#       --yes-spend [--keep-scratch] [--results-dir DIR] [--allow-dirty]
#
# Flags:
#   --hypothesis STR   One-line prediction. REQUIRED to run (G8).
#   --predict EXPR     Machine-checkable predicate over the scalar keys of the
#                      results JSON's meta+outcome blocks; repeatable. Grammar:
#                      KEY OP VALUE with OP one of == != >= <= > <  (e.g.
#                      'journeys_passing_after>=3', 'final_status==STALLED').
#                      All true → CONFIRMED, all false → REFUTED, anything
#                      else (mix, unknown key, unknown value) → MIXED.
#                      Without any --predict the POST verdict line is MANUAL —
#                      the runner never self-grades a free-text hypothesis.
#   --yes-spend        Actually run (G9: the user has approved the estimate).
#   --keep-scratch     Keep the scratch workspace on success (it is always
#                      kept when the engine exits nonzero or the runner fails).
#   --results-dir DIR  Where the results JSON lands (default:
#                      benchmarks/results/ in this repo; tests override).
#   --allow-dirty      Run despite a dirty framework working tree, recording
#                      framework_dirty:true + a diffstat line in the results.
#                      Without it a dirty tree refuses: results attributed to
#                      a sha the tree does not match are worthless. When the
#                      dirt is a previous run's ledger/results, commit those
#                      first instead.
#
# Exit codes:
#   0  benchmark protocol completed — results JSON + POST ledger entry
#      written. The ENGINE's exit code (possibly nonzero: a paused or halted
#      engine is still a RESULT) is recorded inside the results JSON.
#   2  refused (no --yes-spend / no --hypothesis / dirty tree) or usage error.
#      Refusals fire BEFORE any side effect: no scratch, no ledger append,
#      no results file.
#   1  runner failure (assembly/extraction crashed); scratch kept, path printed.
#
# ── TEST SEAM (CHAIN_BENCH_ENGINE_CMD) ────────────────────────────────────────
# When CHAIN_BENCH_ENGINE_CMD is set, it is run (bash -c, cwd=scratch, with
# CHAIN_AGENT_BACKEND=claude and CHAIN_BENCH_SESSION_ID /
# CHAIN_BENCH_MAX_ITER exported) INSTEAD of the real
# `run-goal.sh --session-id <sid> --max-iter 2`. This exists ONLY so the
# offline suite (tests/automation/test-benchmark-runner.sh) can drive stub
# engines. The spend/hypothesis/dirty gates sit UPSTREAM of the seam, so it
# cannot be used to dodge them (G5) — and the seam value lands in the results
# JSON's chain_env block, so a stubbed run is visibly stubbed.
#
# Scratch workspace layout (mktemp -d under $TMPDIR):
#   <work>/scratch             framework subrepo set (.claude/ scripts/ config/
#                              templates/ CLAUDE.md [+ .mcp.json]) + fixture
#                              overlay (fixture files WIN collisions — its
#                              .claude/project-template.md replaces the
#                              framework placeholder), fresh git repo on main
#                              (deterministic author), origin = local bare repo
#   <work>/scratch-origin.git  the local bare origin (satisfies the engine's
#                              ls-remote preflight + per-iter push, no network)
#   <work>/engine.log          engine stdout/stderr (also streamed live)
#
# Ledger format contract (grep-able): PRE entries start `## PRE <session-id>`,
# POST entries start `## POST <session-id>` — pinned by the test suite.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/automation/lib"
FIXTURE="$REPO_ROOT/benchmarks/fixtures/todo-app"
LEDGER="$REPO_ROOT/benchmarks/experiments.md"

log() { echo "[benchmark] $*"; }

# ── Arguments ─────────────────────────────────────────────────────────────────
YES_SPEND=false
KEEP_SCRATCH=false
ALLOW_DIRTY=false
HYPOTHESIS=""
RESULTS_DIR="$REPO_ROOT/benchmarks/results"
declare -a PREDICTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes-spend)    YES_SPEND=true ;;
    --keep-scratch) KEEP_SCRATCH=true ;;
    --allow-dirty)  ALLOW_DIRTY=true ;;
    --hypothesis)
      [[ -n "${2:-}" ]] || { echo "--hypothesis needs a value" >&2; exit 2; }
      HYPOTHESIS="$2"; shift ;;
    --predict)
      [[ -n "${2:-}" ]] || { echo "--predict needs a value" >&2; exit 2; }
      PREDICTS+=("$2"); shift ;;
    --results-dir)
      [[ -n "${2:-}" ]] || { echo "--results-dir needs a value" >&2; exit 2; }
      RESULTS_DIR="$2"; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

FRAMEWORK_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown (not a git repo)")"

# ── Plan + estimate (always printed — the G9 confirmation surface) ────────────
cat <<PLAN
[benchmark] plan:
  fixture:    benchmarks/fixtures/todo-app  (copied with the framework subrepo set into a scratch repo)
  engine:     run-goal.sh --session-id bench-<UTCdate-hhmm> --max-iter 2  (headless; local bare origin)
  framework:  sha ${FRAMEWORK_SHA}
  records:    results JSON under ${RESULTS_DIR} + PRE/POST entries in benchmarks/experiments.md
  estimate:   ~2 lean goal-mode iterations of a tiny app — several HOURS wall clock,
              order-of-DOLLARS API spend (rough ±3x; every dispatched agent bills real tokens)
PLAN

# ── Refusal gates — all BEFORE any side effect ────────────────────────────────
if ! $YES_SPEND; then
  echo
  echo "[benchmark] REFUSING to run: a benchmark run spends real API tokens (ground rule G9)."
  echo "            Re-run with --yes-spend after the user has approved the estimate above,"
  echo "            plus --hypothesis '<one-line prediction>' (G8)."
  exit 2
fi
if [[ -z "$HYPOTHESIS" ]]; then
  echo
  echo "[benchmark] REFUSING to run: no --hypothesis given. Prediction precedes execution"
  echo "            (ground rule G8): the PRE entry in benchmarks/experiments.md is written"
  echo "            BEFORE the engine launches, and it needs your one-line prediction."
  exit 2
fi
DIRTY=false
DIFFSTAT=""
_porcelain="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null || true)"
if [[ -n "$_porcelain" ]]; then
  if ! $ALLOW_DIRTY; then
    echo
    echo "[benchmark] REFUSING to run: the framework working tree is dirty — results would be"
    echo "            attributed to sha ${FRAMEWORK_SHA}, which the tree does not match."
    echo "            Commit first (including any previous run's ledger/results), or pass"
    echo "            --allow-dirty to run anyway with framework_dirty:true recorded."
    exit 2
  fi
  DIRTY=true
  _stat="$(git -C "$REPO_ROOT" diff HEAD --stat 2>/dev/null | tail -n1 | sed 's/^ *//')"
  _untracked="$(grep -c '^??' <<<"$_porcelain" || true)"
  DIFFSTAT="${_stat:-no tracked changes}; ${_untracked} untracked path(s)"
  log "WARNING: running on a dirty tree (--allow-dirty): $DIFFSTAT"
fi
if [[ ! -d "$FIXTURE" ]]; then
  echo "[benchmark] fixture missing: $FIXTURE — broken checkout?" >&2
  exit 1
fi

# ── Side effects begin: pre-registration, then scratch assembly ───────────────
SESSION_ID="bench-$(date -u +%Y%m%d-%H%M)"
NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "session: $SESSION_ID (framework sha ${FRAMEWORK_SHA})"

if [[ ! -f "$LEDGER" ]]; then
  # Normally committed with the framework; recreate a minimal header if absent
  # so the append-only record never silently lands nowhere.
  mkdir -p "$(dirname "$LEDGER")"
  {
    echo "# Benchmark experiments ledger (EVO-3)"
    echo
    echo "**APPEND-ONLY.** (Header auto-recreated by run-benchmark.sh — the committed"
    echo "version in the framework repo carries the full entry-format contract.)"
    echo
    echo "<!-- entries are appended below this line — do not edit anything beneath it -->"
  } > "$LEDGER"
  log "ledger was missing — recreated header: $LEDGER"
fi
{
  printf -- '\n---\n\n'
  printf '## PRE %s · %s\n' "$SESSION_ID" "$NOW_UTC"
  printf -- '- framework-sha: %s (dirty: %s)\n' "$FRAMEWORK_SHA" "$DIRTY"
  if [[ "$DIRTY" == "true" ]]; then
    printf -- '- framework-diffstat: %s\n' "$DIFFSTAT"
  fi
  printf -- '- fixture: todo-app · max-iter 2\n'
  printf -- '- hypothesis: %s\n' "$HYPOTHESIS"
  if [[ ${#PREDICTS[@]} -gt 0 ]]; then
    printf -- '- metrics + prediction (mechanical --predict): %s\n' "$(IFS=';'; echo "${PREDICTS[*]}")"
  else
    printf -- '- metrics + prediction: stated in the hypothesis (free text — POST verdict will be MANUAL)\n'
  fi
} >> "$LEDGER"
log "PRE entry appended to benchmarks/experiments.md (prediction registered before execution)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bench-${SESSION_ID}.XXXXXX")"
SCRATCH="$WORK/scratch"
ORIGIN="$WORK/scratch-origin.git"
# From here on, any runner failure keeps the scratch for forensics.
trap '_rc=$?; if [[ $_rc -ne 0 ]]; then echo "[benchmark] FAILED (rc=$_rc) — scratch workspace kept for forensics: '"$WORK"'" >&2; fi' EXIT
mkdir -p "$SCRATCH"
log "scratch workspace: $WORK"

# Framework subrepo set (README "Subrepo Usage"): .claude/ scripts/ config/
# templates/ + CLAUDE.md (+ .mcp.json when present). Deliberately NOT copied:
# .git, runs/, reports/, docs/, tests/, benchmarks/ (recursion!), and the
# neutral sources (agents/ skills/ commands/ hooks/ policy/) — the runtime
# reads the rendered .claude/ tree.
for d in .claude scripts config templates; do
  if [[ ! -d "$REPO_ROOT/$d" ]]; then
    echo "[benchmark] framework dir missing from subrepo set: $d" >&2
    exit 1
  fi
  cp -a "$REPO_ROOT/$d" "$SCRATCH/"
done
cp "$REPO_ROOT/CLAUDE.md" "$SCRATCH/"
if [[ -f "$REPO_ROOT/.mcp.json" ]]; then
  cp "$REPO_ROOT/.mcp.json" "$SCRATCH/"
fi

# Fixture overlay — fixture files WIN collisions (tar extract overwrites), so
# the fixture's filled .claude/project-template.md replaces the framework
# placeholder and its docs/goal.md becomes the scratch goal file. Runtime dirs
# (.venv/ __pycache__/ .pytest_cache/) and the runtime store (todos.json) are
# never part of the benchmark input.
( cd "$FIXTURE" \
  && tar --exclude='.venv' --exclude='__pycache__' --exclude='.pytest_cache' \
         --exclude='todos.json' -cf - . ) \
  | ( cd "$SCRATCH" && tar -xf - )

git -C "$SCRATCH" init -q -b main
git -C "$SCRATCH" add -A
git -C "$SCRATCH" -c user.name="goal-chain" -c user.email="goal-chain@localhost" \
  commit -q -m "chore(bench): scratch assembly — framework @ ${FRAMEWORK_SHA:0:12} + todo-app fixture"
git init -q --bare "$ORIGIN"
git -C "$SCRATCH" remote add origin "$ORIGIN"
log "scratch repo ready (1 commit on main; origin = local bare $ORIGIN)"

# ── Engine launch ─────────────────────────────────────────────────────────────
# Environment honesty: everything CHAIN_* in the engine's environment is
# recorded in the results JSON — results are only comparable when config is
# visible. The exports below are part of that environment on purpose.
# "claude" IS the headless dispatch backend (quota-retry.sh accepts
# interactive|claude|codex only); pinning it keeps a production pump's
# CHAIN_AGENT_BACKEND=interactive from leaking into the benchmark engine.
export CHAIN_AGENT_BACKEND=claude
export CHAIN_BENCH_SESSION_ID="$SESSION_ID"
export CHAIN_BENCH_MAX_ITER=2
CHAIN_ENV_LINES="$(env | LC_ALL=C sort | grep '^CHAIN_' || true)"

ENGINE_LOG="$WORK/engine.log"
ENGINE_RC=0
_t0="$(date +%s)"
if [[ -n "${CHAIN_BENCH_ENGINE_CMD:-}" ]]; then
  log "TEST SEAM active — running CHAIN_BENCH_ENGINE_CMD instead of run-goal.sh (recorded in results)"
  ( cd "$SCRATCH" && bash -c "$CHAIN_BENCH_ENGINE_CMD" ) 2>&1 | tee "$ENGINE_LOG" || ENGINE_RC=$?
else
  log "launching engine: run-goal.sh --session-id $SESSION_ID --max-iter 2 (headless)"
  ( cd "$SCRATCH" && bash scripts/automation/run-goal.sh --session-id "$SESSION_ID" --max-iter 2 ) \
    2>&1 | tee "$ENGINE_LOG" || ENGINE_RC=$?
fi
_t1="$(date +%s)"
WALL_SECONDS=$(( _t1 - _t0 ))
log "engine exit code: $ENGINE_RC (a nonzero/paused engine is a RESULT, recorded as such)"

# ── Results extraction ────────────────────────────────────────────────────────
if [[ -f "$REPO_ROOT/config/model-tiers.yaml" ]]; then
  TIERS_SHA256="$(sha256sum "$REPO_ROOT/config/model-tiers.yaml" | awk '{print $1}')"
else
  TIERS_SHA256="unknown (config/model-tiers.yaml missing)"
fi
TELEMETRY="$SCRATCH/runs/goal-session-$SESSION_ID/telemetry.jsonl"
if [[ -f "$TELEMETRY" ]]; then
  AGENTS_JSON="$(python3 "$LIB/analyze_telemetry.py" --json "$TELEMETRY")"
  TELEMETRY_MISSING=""
else
  AGENTS_JSON='{}'
  TELEMETRY_MISSING="telemetry.jsonl missing"
fi

case "$FRAMEWORK_SHA" in
  *" "*) _sha12="nosha" ;;
  *)     _sha12="${FRAMEWORK_SHA:0:12}" ;;
esac
mkdir -p "$RESULTS_DIR"
RESULTS_FILE="$RESULTS_DIR/$(date -u +%Y%m%d-%H%M%S)-${_sha12}.json"

_predicts=""
if [[ ${#PREDICTS[@]} -gt 0 ]]; then
  _predicts="$(printf '%s\n' "${PREDICTS[@]}")"
fi

# One python pass builds + validates the results JSON, evaluates the --predict
# predicates, and appends the POST ledger entry. Everything crosses via env —
# no shell interpolation into code.
BENCH_RESULTS_FILE="$RESULTS_FILE" \
BENCH_REPO_ROOT="$REPO_ROOT" \
BENCH_SCRATCH="$SCRATCH" \
BENCH_LEDGER="$LEDGER" \
BENCH_SESSION_ID="$SESSION_ID" \
BENCH_DATE_UTC="$NOW_UTC" \
BENCH_FRAMEWORK_SHA="$FRAMEWORK_SHA" \
BENCH_DIRTY="$DIRTY" \
BENCH_DIFFSTAT="$DIFFSTAT" \
BENCH_HYPOTHESIS="$HYPOTHESIS" \
BENCH_PREDICTS="$_predicts" \
BENCH_CHAIN_ENV="$CHAIN_ENV_LINES" \
BENCH_TIERS_SHA256="$TIERS_SHA256" \
BENCH_ENGINE_RC="$ENGINE_RC" \
BENCH_WALL_SECONDS="$WALL_SECONDS" \
BENCH_MAX_ITER=2 \
BENCH_AGENTS_JSON="$AGENTS_JSON" \
BENCH_TELEMETRY_MISSING="$TELEMETRY_MISSING" \
python3 - <<'PYEOF'
import json
import os
import sys
import time

env = os.environ
sid = env["BENCH_SESSION_ID"]
scratch = env["BENCH_SCRATCH"]
repo_root = env["BENCH_REPO_ROOT"]
sess_dir = os.path.join(scratch, "runs", f"goal-session-{sid}")

def unknown(why):
    return f"unknown ({why})"

# outcome — session.json
final_status = last_verdict = iterations_used = unknown("scratch session.json missing")
session_path = os.path.join(sess_dir, "session.json")
if os.path.isfile(session_path):
    try:
        s = json.load(open(session_path, encoding="utf-8"))
    except Exception:
        s = None
        final_status = last_verdict = iterations_used = unknown("scratch session.json unreadable")
    if isinstance(s, dict):
        final_status = s.get("status") if s.get("status") is not None else unknown("status absent from session.json")
        last_verdict = s.get("last_verdict") if s.get("last_verdict") is not None else unknown("last_verdict null/absent in session.json")
        iterations_used = s.get("current_iter") if isinstance(s.get("current_iter"), int) else unknown("current_iter absent from session.json")

# outcome — journey-history.json ({"journeys": {id: {"status": ...}}};
# passing statuses per lib/goal_gate.py PASSING_STATUSES)
journeys_passing = journeys_total = unknown("journey-history.json missing")
jh_path = os.path.join(sess_dir, "state", "journey-history.json")
if os.path.isfile(jh_path):
    try:
        jh = json.load(open(jh_path, encoding="utf-8"))
        journeys = jh.get("journeys")
        if isinstance(journeys, dict):
            journeys_total = len(journeys)
            journeys_passing = sum(
                1 for j in journeys.values()
                if isinstance(j, dict) and j.get("status") in {"passing", "already_passing"}
            )
        else:
            journeys_passing = journeys_total = unknown("journeys key malformed in journey-history.json")
    except Exception:
        journeys_passing = journeys_total = unknown("journey-history.json unreadable")

# outcome — telemetry counters (mirrors lib/retro_collect.sh semantics)
VALID = {"GOAL_ACHIEVED", "CONTINUE", "ESCALATE", "REGRESSION", "STALLED"}
attempt1_review_fails = malformed_verdicts = unknown("telemetry.jsonl missing")
tel_path = os.path.join(sess_dir, "telemetry.jsonl")
if os.path.isfile(tel_path):
    rf = mf = 0
    try:
        for raw in open(tel_path, encoding="utf-8"):
            raw = raw.strip()
            if not raw:
                continue
            try:
                e = json.loads(raw)
            except Exception:
                continue
            ev = e.get("event")
            if ev == "review_verdict" and e.get("attempt") == 1 and e.get("verdict") == "FAIL":
                rf += 1
            elif ev == "deterministic_gate" and e.get("raw") not in VALID:
                mf += 1
        attempt1_review_fails, malformed_verdicts = rf, mf
    except Exception:
        attempt1_review_fails = malformed_verdicts = unknown("telemetry.jsonl unreadable")

chain_env = {}
for line in env["BENCH_CHAIN_ENV"].splitlines():
    if "=" in line:
        k, v = line.split("=", 1)
        chain_env[k] = v

meta = {
    "date_utc": env["BENCH_DATE_UTC"],
    "framework_sha": env["BENCH_FRAMEWORK_SHA"],
    "framework_dirty": env["BENCH_DIRTY"] == "true",
    "fixture": "todo-app",
    "session_id": sid,
    "max_iter": int(env["BENCH_MAX_ITER"]),
    "hypothesis": env["BENCH_HYPOTHESIS"],
    "predict": [p for p in env["BENCH_PREDICTS"].splitlines() if p.strip()],
    "chain_env": chain_env,
    "model_tiers_sha256": env["BENCH_TIERS_SHA256"],
}
if meta["framework_dirty"]:
    meta["framework_diffstat"] = env["BENCH_DIFFSTAT"]
outcome = {
    "engine_exit_code": int(env["BENCH_ENGINE_RC"]),
    "final_status": final_status,
    "last_verdict": last_verdict,
    "iterations_used": iterations_used,
    "journeys_passing_after": journeys_passing,
    "journeys_total": journeys_total,
    "attempt1_review_fails": attempt1_review_fails,
    "malformed_verdicts": malformed_verdicts,
    "wall_seconds": int(env["BENCH_WALL_SECONDS"]),
}
economics = {"agents": json.loads(env["BENCH_AGENTS_JSON"])}
if env["BENCH_TELEMETRY_MISSING"]:
    economics["note"] = unknown(env["BENCH_TELEMETRY_MISSING"])

results = {"meta": meta, "outcome": outcome, "economics": economics}
with open(env["BENCH_RESULTS_FILE"], "w", encoding="utf-8") as f:
    json.dump(results, f, indent=2, sort_keys=False)
    f.write("\n")

# Validate before declaring success: re-read and check the required keys.
reread = json.load(open(env["BENCH_RESULTS_FILE"], encoding="utf-8"))
required = {
    "meta": ["date_utc", "framework_sha", "framework_dirty", "fixture", "session_id",
             "max_iter", "hypothesis", "predict", "chain_env", "model_tiers_sha256"],
    "outcome": ["engine_exit_code", "final_status", "last_verdict", "iterations_used",
                "journeys_passing_after", "journeys_total", "attempt1_review_fails",
                "malformed_verdicts", "wall_seconds"],
    "economics": ["agents"],
}
missing = [f"{blk}.{k}" for blk, keys in required.items() for k in keys
           if k not in reread.get(blk, {})]
if meta["framework_dirty"] and "framework_diffstat" not in reread["meta"]:
    missing.append("meta.framework_diffstat")
if missing:
    print(f"[benchmark] results validation FAILED — missing keys: {', '.join(missing)}",
          file=sys.stderr)
    sys.exit(1)

# --predict evaluation over the flattened meta+outcome scalars.
flat = {}
for blk in (meta, outcome):
    for k, v in blk.items():
        if isinstance(v, (str, int, float, bool)) or v is None:
            flat.setdefault(k, v)

def evaluate(expr):
    """Return (True|False|None, detail). None = unevaluable."""
    for op in ("==", "!=", ">=", "<=", ">", "<"):
        if op in expr:
            key, val = expr.split(op, 1)
            key, val = key.strip(), val.strip().strip("\"'")
            break
    else:
        return None, "unparseable (need KEY OP VALUE)"
    if key not in flat:
        return None, f"key '{key}' not in results"
    cur = flat[key]
    if cur is None or (isinstance(cur, str) and cur.startswith("unknown (")):
        return None, f"{key}={cur!r} (unevaluable)"
    def num(x):
        try:
            return float(x)
        except (TypeError, ValueError):
            return None
    a, b = num(cur), num(val)
    if a is not None and b is not None:
        cur_c, val_c = a, b
    elif op in ("==", "!="):
        cur_c, val_c = str(cur), str(val)
    else:
        return None, f"non-numeric ordering comparison ({key}={cur!r})"
    res = {"==": cur_c == val_c, "!=": cur_c != val_c, ">=": cur_c >= val_c,
           "<=": cur_c <= val_c, ">": cur_c > val_c, "<": cur_c < val_c}[op]
    return res, f"{key}={cur!r}"

predicts = meta["predict"]
predicate_lines = []
if predicts:
    outcomes = []
    for p in predicts:
        r, detail = evaluate(p)
        outcomes.append(r)
        shown = {True: "true", False: "false", None: "unevaluable"}[r]
        predicate_lines.append(f"- predicate: {p} → {shown} ({detail})")
    if all(r is True for r in outcomes):
        verdict_line = "verdict-vs-prediction: CONFIRMED"
    elif all(r is False for r in outcomes):
        verdict_line = "verdict-vs-prediction: REFUTED"
    else:
        verdict_line = "verdict-vs-prediction: MIXED"
else:
    verdict_line = ("verdict-vs-prediction: MANUAL — append CONFIRMED|REFUTED|MIXED "
                    "after review")

cost = "unknown"
total = economics["agents"].get(sid, {}).get("total", {})
if "gen_ai.usage.total_cost_usd" in total:
    cost = f"${total['gen_ai.usage.total_cost_usd']}"
results_path = env["BENCH_RESULTS_FILE"]
if results_path.startswith(repo_root + os.sep):
    results_path = os.path.relpath(results_path, repo_root)
headline = (f"status={final_status} last_verdict={last_verdict} "
            f"journeys={journeys_passing}/{journeys_total} iters={iterations_used} "
            f"engine_exit={outcome['engine_exit_code']} wall={outcome['wall_seconds']}s "
            f"cost={cost}")

with open(env["BENCH_LEDGER"], "a", encoding="utf-8") as f:
    f.write(f"\n## POST {sid} · {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n")
    f.write(f"- results: {results_path}\n")
    f.write(f"- headline: {headline}\n")
    for line in predicate_lines:
        f.write(line + "\n")
    f.write(f"- {verdict_line}\n")

print(f"[benchmark] headline: {headline}")
print(f"[benchmark] {verdict_line}")
PYEOF

log "results: $RESULTS_FILE"
log "POST entry appended to benchmarks/experiments.md"

# ── Scratch retention ─────────────────────────────────────────────────────────
if [[ "$ENGINE_RC" -ne 0 ]]; then
  log "engine exited nonzero — scratch workspace kept for forensics: $WORK"
elif $KEEP_SCRATCH; then
  log "--keep-scratch: scratch workspace kept: $WORK"
else
  rm -rf "$WORK"
  log "scratch workspace removed (success — pass --keep-scratch to keep it)"
fi
exit 0
