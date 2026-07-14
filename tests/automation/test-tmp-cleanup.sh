#!/usr/bin/env bash
# test-tmp-cleanup.sh — per-run tmp isolation trap mechanics:
#   1. an OWNER script's EXIT trap archives service-log tails on failure and
#      removes the tmp dir (the run-phase.sh contract)
#   2. success exit removes the dir WITHOUT archiving
#   3. a NESTED script adopts the dir and its cleanup is a no-op
#   4. rotate at an iteration boundary swaps dirs (the run-goal.sh contract)
#   5. default root derives from $HOME (~/.cache/iad — the REL-13 relocation)
#   6. engine-style disk-guard pathway (aggressive sweep + rc 2 enforce)
# Offline, no model, <5s. Janitor/guard subtests pass CHAIN_TMP_LEGACY_ROOTS=""
# so the REAL /tmp is never swept from a test.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/scripts/automation/lib/chain-tmp.sh"

PASS=0
FAIL=0
assert() {
  local label="$1" result="$2"
  if [[ "$result" == "pass" ]]; then
    echo "  PASS  $label"; PASS=$((PASS+1))
  else
    echo "  FAIL  $label"; FAIL=$((FAIL+1))
  fi
}

# Pin the scratch to a SHORT path: the session TMPDIR may point at a deep dir
# (settings env → ~/.cache/iad/shared), which would push test dirs past the
# 62-char socket budget and hash-shorten the names asserted verbatim below.
T=$(TMPDIR=/tmp mktemp -d)
trap 'rm -rf "$T"' EXIT

# ── 1. Owner + failure exit → archive + removal (run-phase.sh trap contract) ──
mkdir -p "$T/runs/phX"
rc=0
CHAIN_TMP_ROOT="$T" RUN_DIR="$T/runs/phX" bash -c '
  set -euo pipefail
  source "'"$LIB"'"
  chain_tmp_init "phX"
  echo "service says hi" > "$CHAIN_TMPDIR/fanout-backend-1.log"
  _on_exit() {
    local rc="$1"
    if [[ "$rc" -ne 0 && -n "${CHAIN_TMPDIR:-}" && -d "${CHAIN_TMPDIR:-}" ]]; then
      mkdir -p "$RUN_DIR/service-logs"
      local f
      for f in "$CHAIN_TMPDIR"/*.log; do
        [[ -f "$f" ]] && tail -c 200000 "$f" > "$RUN_DIR/service-logs/$(basename "$f")"
      done
    fi
    chain_tmp_cleanup
  }
  trap "_on_exit \$?" EXIT
  exit 3' || rc=$?
[[ $rc -eq 3 ]] \
  && assert "owner: exit code preserved through EXIT trap" "pass" \
  || assert "owner: exit code preserved through EXIT trap (got $rc)" "fail"
grep -q "service says hi" "$T/runs/phX/service-logs/fanout-backend-1.log" 2>/dev/null \
  && assert "owner: service-log tail archived on failure" "pass" \
  || assert "owner: service-log tail archived on failure" "fail"
if ls -d "$T"/iad.* >/dev/null 2>&1; then
  assert "owner: tmp dir removed on failure exit" "fail"
else
  assert "owner: tmp dir removed on failure exit" "pass"
fi

# ── 2. Owner + success exit → removal, NO archive ─────────────────────────────
rm -rf "$T/runs/phX/service-logs"
CHAIN_TMP_ROOT="$T" RUN_DIR="$T/runs/phX" bash -c '
  set -euo pipefail
  source "'"$LIB"'"
  chain_tmp_init "phY"
  echo "quiet log" > "$CHAIN_TMPDIR/qa-backend-1.log"
  _on_exit() {
    local rc="$1"
    if [[ "$rc" -ne 0 && -n "${CHAIN_TMPDIR:-}" && -d "${CHAIN_TMPDIR:-}" ]]; then
      mkdir -p "$RUN_DIR/service-logs"
      local f
      for f in "$CHAIN_TMPDIR"/*.log; do
        [[ -f "$f" ]] && tail -c 200000 "$f" > "$RUN_DIR/service-logs/$(basename "$f")"
      done
    fi
    chain_tmp_cleanup
  }
  trap "_on_exit \$?" EXIT
  exit 0'
if ls -d "$T"/iad.* >/dev/null 2>&1; then
  assert "owner: tmp dir removed on success exit" "fail"
else
  assert "owner: tmp dir removed on success exit" "pass"
fi
if [[ -d "$T/runs/phX/service-logs" ]]; then
  assert "owner: success exit does NOT archive logs" "fail"
else
  assert "owner: success exit does NOT archive logs" "pass"
fi

# ── 3. Nested adopt: child cleanup no-op; parent cleanup removes ──────────────
rc=0
CHAIN_TMP_ROOT="$T" bash -c '
  set -euo pipefail
  source "'"$LIB"'"
  chain_tmp_init "outer"
  outer="$CHAIN_TMPDIR"
  # Nested "run-phase.sh": inherits CHAIN_TMPDIR, adopts, its cleanup is a no-op.
  bash -c "source \"'"$LIB"'\"; chain_tmp_init nested-should-adopt; chain_tmp_cleanup"
  [[ -d "$outer" ]] || exit 10          # child must NOT have removed it
  n=$(ls -d "'"$T"'"/iad.* | wc -l)
  [[ "$n" -eq 1 ]] || exit 11           # child must NOT have created a second dir
  chain_tmp_cleanup
  [[ ! -d "$outer" ]] || exit 12' || rc=$?
[[ $rc -eq 0 ]] \
  && assert "nested: adopt + owner-guarded cleanup" "pass" \
  || assert "nested: adopt + owner-guarded cleanup (subtest exit $rc)" "fail"

# ── 4. Rotate boundary (run-goal.sh contract) ─────────────────────────────────
rc=0
CHAIN_TMP_ROOT="$T" bash -c '
  set -euo pipefail
  source "'"$LIB"'"
  chain_tmp_init "iter-0"; a="$CHAIN_TMPDIR"; touch "$a/x.log"
  chain_tmp_rotate "iter-1"; b="$CHAIN_TMPDIR"
  [[ ! -d "$a" && -d "$b" && "$b" == *iter-1* ]] || exit 20
  chain_tmp_cleanup' || rc=$?
[[ $rc -eq 0 ]] \
  && assert "rotate: previous dir cleared, fresh dir exported" "pass" \
  || assert "rotate: previous dir cleared, fresh dir exported (subtest exit $rc)" "fail"

# ── 5. Default root derives from $HOME (REL-13 relocation off quota'd /tmp) ───
rc=0
bash -c '
  set -euo pipefail
  unset CHAIN_TMP_ROOT CHAIN_TMPDIR CHAIN_TMPDIR_OWNER_PID
  export HOME="'"$T"'/fakehome"
  source "'"$LIB"'"
  chain_tmp_init "x"
  [[ "$CHAIN_TMPDIR" == "'"$T"'/fakehome/.cache/iad/iad.x."* ]] || exit 30
  [[ -d "'"$T"'/fakehome/.cache/iad/shared" ]] || exit 31   # interactive target self-heals
  chain_tmp_cleanup' || rc=$?
[[ $rc -eq 0 ]] \
  && assert "default root: \$HOME/.cache/iad (+ shared/ self-heal)" "pass" \
  || assert "default root: \$HOME/.cache/iad (subtest exit $rc)" "fail"

# ── 6. Engine-style disk-guard pathway (run-goal.sh contract) ─────────────────
# Forced-impossible thresholds → aggressive sweep runs (fresh dead-pid stray
# reaped despite zero age) and --enforce reports rc 2; healthy thresholds → 0.
rc=0
bash -c '
  set -euo pipefail
  source "'"$LIB"'"
  export CHAIN_TMP_ROOT="'"$T"'" CHAIN_TMP_LEGACY_ROOTS="" CHAIN_TMP_PROBE_MB=0
  mkdir -p "'"$T"'/iad.guardstray.999999994"
  g=0
  CHAIN_TMP_MIN_FREE_MB=999999999 CHAIN_TMP_HARD_MIN_FREE_MB=999999999 \
    chain_tmp_disk_guard --enforce 2>/dev/null || g=$?
  [[ "$g" -eq 2 ]] || exit 40
  [[ ! -d "'"$T"'/iad.guardstray.999999994" ]] || exit 41
  chain_tmp_disk_guard --enforce 2>/dev/null || exit 42' || rc=$?
[[ $rc -eq 0 ]] \
  && assert "disk guard: enforce rc 2 under pressure, sweep ran, healthy rc 0" "pass" \
  || assert "disk guard: engine pathway (subtest exit $rc)" "fail"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
