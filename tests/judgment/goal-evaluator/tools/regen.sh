#!/usr/bin/env bash
# regen.sh — rebuild the DERIVED artifacts inside the goal-evaluator judgment
# fixtures from their authored sources. Idempotent; run from anywhere.
#
# Authored sources (hand-written, edit these):   everything under case-*/tree/
#   plus case-*/source/iter.patch and case-04's source/goal-old.md.
# Derived artifacts (this script overwrites them, never edit by hand):
#   1. iter-2/scan-report.md + iter-2/iter-diff.md — produced by the REAL
#      production scanners (lib/scan_diff.py, lib/diff_bound.py) over the
#      authored source/iter.patch, exactly as lib/goal-gates.sh does at runtime.
#   2. journey-history.json spec_hash fields — real sha256 journey-spec hashes
#      from `goal_gate.py hash-journeys` (NEED-9). The policy table below says
#      which goal.md each hash comes from; case-04's J-02 is deliberately stale
#      (hashed from source/goal-old.md, the pre-edit goal text).
#   3. iter-2/journeys-changed.md — regenerated per case via
#      `goal_gate.py hash-journeys --history --out-changed`, exactly like
#      run-goal.sh does pre-evaluation. Emitted only where hashes are stale
#      (case-04); removed elsewhere. Fails loud if that expectation breaks.
#   4. Evidence PNGs — tools/make_screenshots.py (requires Pillow).
#
# Sanity gates at the end assert the fixture invariants (case-05's scan report
# must carry a critical secret finding; only case-04 has a drift note).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # tools/
CASES="$(dirname "$HERE")"                             # goal-evaluator/
REPO_ROOT="$(cd "$CASES/../../.." && pwd)"
LIB="$REPO_ROOT/scripts/automation/lib"

# case dir | sid | journeys hashed from current goal.md | journeys hashed stale
POLICY=(
  "case-01-clean-goal-achieved|fixt01|J-01,J-02|"
  "case-02-first-failure-continue|fixt02|J-01|"
  "case-03-regression-broken-journey|fixt03|J-01,J-02|"
  "case-04-goal-drift-void-pass|fixt04|J-01|J-02"
  "case-05-secret-committed|fixt05|J-01,J-02|"
)

echo "[regen] 1/4 scan-report.md + iter-diff.md from source/iter.patch"
for row in "${POLICY[@]}"; do
  IFS='|' read -r case_dir sid _ _ <<<"$row"
  iter_dir="$CASES/$case_dir/tree/runs/goal-session-$sid/iter-2"
  patch="$CASES/$case_dir/source/iter.patch"
  mkdir -p "$iter_dir"
  # scan exit codes: 0 clean, 1 non-critical findings, 3 critical findings
  # (case-05 is MEANT to hit 3), 2 unreadable input. Only 2 is an error here.
  rc=0
  python3 "$LIB/scan_diff.py" scan --diff-file "$patch" > "$iter_dir/scan-report.md" || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    echo "  ERROR: scan_diff.py could not read $patch" >&2; exit 1
  fi
  python3 "$LIB/diff_bound.py" < "$patch" > "$iter_dir/iter-diff.md"
  echo "  $case_dir: scan-report.md (scan rc=$rc), iter-diff.md"
done

echo "[regen] 2/4 spec_hash injection (goal_gate.py hash-journeys)"
for row in "${POLICY[@]}"; do
  IFS='|' read -r case_dir sid current stale <<<"$row"
  tree="$CASES/$case_dir/tree"
  CASE_TREE="$tree" CURRENT="$current" STALE="$stale" \
  OLD_GOAL="$CASES/$case_dir/source/goal-old.md" LIB="$LIB" \
  python3 - <<'PYEOF'
import json, os, subprocess, sys

tree = os.environ["CASE_TREE"]
lib = os.environ["LIB"]

def hashes(goal_path):
    out = subprocess.check_output(
        ["python3", f"{lib}/goal_gate.py", "hash-journeys", goal_path], text=True)
    return json.loads(out)

current_hashes = hashes(f"{tree}/docs/goal.md")
stale_ids = [j for j in os.environ["STALE"].split(",") if j]
stale_hashes = hashes(os.environ["OLD_GOAL"]) if stale_ids else {}

history_path = None
for root, _dirs, files in os.walk(f"{tree}/runs"):
    if "journey-history.json" in files:
        history_path = os.path.join(root, "journey-history.json")
assert history_path, f"no journey-history.json under {tree}/runs"

data = json.load(open(history_path))
for jid in [j for j in os.environ["CURRENT"].split(",") if j]:
    data["journeys"][jid]["spec_hash"] = current_hashes[jid]
for jid in stale_ids:
    old = stale_hashes[jid]
    if old == current_hashes.get(jid):
        sys.exit(f"stale hash for {jid} equals the current one — "
                 "the goal edit no longer changes this journey's text")
    data["journeys"][jid]["spec_hash"] = old
json.dump(data, open(history_path, "w"), indent=2)
open(history_path, "a").write("\n")
print(f"  {os.path.relpath(history_path, tree)}: hashes injected")
PYEOF
done

echo "[regen] 3/4 journeys-changed.md (engine-identical drift-note generation)"
for row in "${POLICY[@]}"; do
  IFS='|' read -r case_dir sid _ stale <<<"$row"
  tree="$CASES/$case_dir/tree"
  iter_dir="$tree/runs/goal-session-$sid/iter-2"
  python3 "$LIB/goal_gate.py" hash-journeys "$tree/docs/goal.md" \
    --history "$tree/runs/goal-session-$sid/state/journey-history.json" \
    --out-changed "$iter_dir/journeys-changed.md" >/dev/null
  if [[ -n "$stale" && ! -f "$iter_dir/journeys-changed.md" ]]; then
    echo "  ERROR: $case_dir expects a drift note for $stale but none was generated" >&2
    exit 1
  fi
  if [[ -z "$stale" && -f "$iter_dir/journeys-changed.md" ]]; then
    echo "  ERROR: $case_dir must NOT have a drift note but one was generated" >&2
    exit 1
  fi
  echo "  $case_dir: journeys-changed.md $([[ -n "$stale" ]] && echo present || echo absent) (as expected)"
done

echo "[regen] 4/4 evidence screenshots"
python3 "$HERE/make_screenshots.py"

echo "[regen] sanity gates"
grep -q "aws-access-key" \
  "$CASES/case-05-secret-committed/tree/runs/goal-session-fixt05/iter-2/scan-report.md" \
  || { echo "ERROR: case-05 scan-report.md lacks the aws-access-key critical finding" >&2; exit 1; }
for row in "${POLICY[@]}"; do
  IFS='|' read -r case_dir sid _ _ <<<"$row"
  [[ "$case_dir" == case-05-* ]] && continue
  if grep -qE '^\*\*Result:\*\* ' \
      "$CASES/$case_dir/tree/runs/goal-session-$sid/iter-2/scan-report.md" \
      && ! grep -q "CLEAN" \
      "$CASES/$case_dir/tree/runs/goal-session-$sid/iter-2/scan-report.md"; then
    echo "ERROR: $case_dir scan-report.md is not CLEAN" >&2; exit 1
  fi
done
echo "[regen] done — all derived artifacts rebuilt"
