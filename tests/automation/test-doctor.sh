#!/usr/bin/env bash
# test-doctor.sh — Unit tests for scripts/automation/doctor.sh (REL-2) and the
# warn-only engine wiring (run_doctor_preflight in run-goal.sh).
#
# Usage: ./tests/automation/test-doctor.sh
#
# Hermetic by construction: every check reads its world through an injection
# seam (PATH symlink-farm + shims for tool discovery, CHAIN_DOCTOR_REPO_ROOT
# for repo-relative paths, HOME for the plugin cache, CHAIN_TMP_ROOT for the
# tmp probe, PLAYWRIGHT_BROWSERS_PATH + PYTHONPATH for playwright,
# CHAIN_DOCTOR_AMBIENT for the ambient CHAIN_* snapshot, shimmed pgrep for
# process scans). No real system state is mutated and no network is touched
# (git remotes are local file:// bare repos, gh/jq/node/timeout are shims).
#
# The engine-wiring tests extract the REAL run_doctor_preflight() from
# run-goal.sh (awk, same pattern as test-github-preflight.sh) and prove the
# warn-only contract: a crashing doctor must never stop the engine.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/automation/doctor.sh"

PASS=0
FAIL=0
TMP_DIR=$(mktemp -d)
cleanup() { chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

assert() {
  local label="$1" result="$2"
  if [[ "$result" == "pass" ]]; then
    echo "  PASS  $label"; PASS=$((PASS + 1))
  else
    echo "  FAIL  $label"; FAIL=$((FAIL + 1))
  fi
}

# ── Fixture: PATH symlink farm (real tools the doctor legitimately needs) ───
FARM="$TMP_DIR/farm"
mkdir -p "$FARM"
for t in bash sh python3 git dd mkdir rmdir rm mv cp ls cat grep sed awk sort \
         tr head tail cut stat df date touch chmod find dirname basename wc \
         readlink env uname hostname paste mktemp sleep true false printf id ps; do
  p="$(command -v "$t" 2>/dev/null || true)"
  [[ -n "$p" ]] && ln -s "$p" "$FARM/$t" 2>/dev/null || true
done

# Shim dirs (searched BEFORE the farm). "healthy" fakes every external tool
# the doctor probes; variants drop or alter one tool per scenario.
mk_shims() {  # $1 = dir, $2 = mode (healthy | nojq | chromebusy)
  local d="$1" mode="$2"
  mkdir -p "$d"
  cat > "$d/gh" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "gh version 2.40.0"; exit 0; }
echo "Logged in to github.com account tester"; exit 0
SH
  cat > "$d/node" <<'SH'
#!/usr/bin/env bash
echo "v20.11.0"
SH
  cat > "$d/timeout" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "timeout (GNU coreutils) 9.4"; exit 0; }
shift            # drop the duration; run the wrapped command for real
exec "$@"
SH
  if [[ "$mode" != "nojq" ]]; then
    cat > "$d/jq" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "jq-1.7"; exit 0; }
exit 0
SH
  fi
  if [[ "$mode" == "chromebusy" ]]; then
    cat > "$d/pgrep" <<'SH'
#!/usr/bin/env bash
printf '4242 chrome\n4243 chromium\n'
exit 0
SH
  else
    cat > "$d/pgrep" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  fi
  chmod +x "$d"/*
}
SHIMS="$TMP_DIR/shims";       mk_shims "$SHIMS" healthy
SHIMS_NOJQ="$TMP_DIR/nojq";   mk_shims "$SHIMS_NOJQ" nojq
SHIMS_CHROME="$TMP_DIR/chromebusy"; mk_shims "$SHIMS_CHROME" chromebusy

# ── Fixture: fake HOME with an installed+enabled Chrome MCP plugin ──────────
FHOME="$TMP_DIR/home"
mkdir -p "$FHOME/.claude/plugins/cache/superpowers-marketplace/superpowers-chrome"
echo '{}' > "$FHOME/.claude/plugins/cache/superpowers-marketplace/superpowers-chrome/plugin.json"

# ── Fixture: healthy repo (origin = local bare; chrome plugin configured) ───
FREPO="$TMP_DIR/repo"
mkdir -p "$FREPO/.claude"
git init -q "$FREPO"
git -C "$FREPO" config user.email t@example.com
git -C "$FREPO" config user.name T
git -C "$FREPO" commit -q --allow-empty -m init
BARE="$TMP_DIR/remote.git"
git init -q --bare "$BARE"
git -C "$FREPO" remote add origin "file://$BARE"
cat > "$FREPO/.claude/settings.json" <<'JSON'
{
  "enabledPlugins": { "superpowers-chrome@superpowers-marketplace": true },
  "permissions": { "allow": ["mcp__plugin_superpowers-chrome_chrome__use_browser"] }
}
JSON

# Bare repo dir with NO chrome MCP anywhere (for the chrome-mcp FAIL case).
NREPO="$TMP_DIR/norepo"
mkdir -p "$NREPO"
git init -q "$NREPO"

# ── Fixture: fake playwright (import via PYTHONPATH; browsers dir) ──────────
PYDIR="$TMP_DIR/py"
mkdir -p "$PYDIR/playwright" "$TMP_DIR/browsers/chromium-1155"
printf '__version__ = "1.44.0"\n' > "$PYDIR/playwright/__init__.py"

FTMP="$TMP_DIR/tmproot"
mkdir -p "$FTMP"

# Run the doctor under the healthy fixture env. Extra env overrides may be
# passed as leading VAR=val words; extra doctor args after "--".
run_doctor() {
  local envs=() args=()
  local in_args=false
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then in_args=true; continue; fi
    $in_args && args+=("$a") || envs+=("$a")
  done
  env "PATH=$SHIMS:$FARM" "HOME=$FHOME" \
      "CHAIN_DOCTOR_REPO_ROOT=$FREPO" "CHAIN_TMP_ROOT=$FTMP" \
      "PLAYWRIGHT_BROWSERS_PATH=$TMP_DIR/browsers" "PYTHONPATH=$PYDIR" \
      "CHAIN_DOCTOR_AMBIENT=" "${envs[@]}" bash "$DOCTOR" "${args[@]}"
}

echo ""
echo "=== doctor.sh: healthy fixture ==="
echo ""

rc=0; out=$(run_doctor 2>&1) || rc=$?
[[ $rc -eq 0 ]] && assert "healthy table exits 0" "pass" \
                || assert "healthy table exits 0 (got $rc; out: $(printf '%s' "$out" | head -c 300))" "fail"
echo "$out" | grep -Eq '\[doctor\] summary: pass=[0-9]+ warn=0 fail=0 skip=0' \
  && assert "healthy summary: warn=0 fail=0 skip=0 (every row live since REL-4)" "pass" \
  || assert "healthy summary line (got: $(echo "$out" | grep -F '[doctor] summary' || echo none))" "fail"
echo "$out" | grep -Eq 'PASS +engine-lock +.*no engine locks' \
  && assert "engine-lock row PASSes when no lock is held (REL-4 protocol live)" "pass" \
  || assert "engine-lock row PASSes when no lock is held (REL-4 protocol live)" "fail"
echo "$out" | grep -Eq 'PASS +chrome-mcp +.*settings\.json' \
  && assert "chrome-mcp PASS says HOW it detected (settings.json)" "pass" \
  || assert "chrome-mcp detection detail" "fail"
for key in python3 node playwright gh-auth git-remote disk timeout jq \
           pump-heartbeat engine-lock tmp-health chrome-exclusive ambient-env; do
  echo "$out" | grep -Eq "PASS +$key " \
    && assert "row $key PASS on healthy fixture" "pass" \
    || assert "row $key PASS on healthy fixture" "fail"
done

# strict mode on a healthy table still exits 0
rc=0; run_doctor -- --strict-doctor >/dev/null 2>&1 || rc=$?
[[ $rc -eq 0 ]] && assert "--strict-doctor exits 0 with no FAIL rows" "pass" \
                || assert "--strict-doctor exits 0 with no FAIL rows (got $rc)" "fail"

echo ""
echo "=== doctor.sh: --list / --only ==="
echo ""

rc=0; out=$(run_doctor -- --list 2>&1) || rc=$?
n=$(echo "$out" | grep -c '^[a-z0-9-]*$' || true)
{ [[ $rc -eq 0 && $n -eq 14 ]]; } \
  && assert "--list prints the 14 check keys" "pass" \
  || assert "--list prints the 14 check keys (rc=$rc n=$n)" "fail"
echo "$out" | grep -qx "tmp-health" && echo "$out" | grep -qx "chrome-exclusive" \
  && assert "--list includes the evidence-born checks" "pass" \
  || assert "--list includes the evidence-born checks" "fail"

rc=0; out=$(run_doctor -- --only jq 2>&1) || rc=$?
rows=$(echo "$out" | grep -Ec '^  (PASS|WARN|FAIL|SKIP) ' || true)
{ [[ $rc -eq 0 && $rows -eq 1 ]]; } \
  && assert "--only jq runs exactly one check" "pass" \
  || assert "--only jq runs exactly one check (rc=$rc rows=$rows)" "fail"
echo "$out" | grep -Eq 'PASS +jq ' \
  && assert "--only jq reports the jq row" "pass" \
  || assert "--only jq reports the jq row" "fail"

rc=0; run_doctor -- --only no-such-check >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] && assert "--only with unknown key exits 2" "pass" \
                || assert "--only with unknown key exits 2 (got $rc)" "fail"

echo ""
echo "=== doctor.sh: a missing tool FAILs its row, everything else runs ==="
echo ""

rc=0; out=$(env "PATH=$SHIMS_NOJQ:$FARM" "HOME=$FHOME" \
    "CHAIN_DOCTOR_REPO_ROOT=$FREPO" "CHAIN_TMP_ROOT=$FTMP" \
    "PLAYWRIGHT_BROWSERS_PATH=$TMP_DIR/browsers" "PYTHONPATH=$PYDIR" \
    "CHAIN_DOCTOR_AMBIENT=" bash "$DOCTOR" 2>&1) || rc=$?
[[ $rc -eq 0 ]] && assert "missing jq: non-strict run still exits 0 (advisory)" "pass" \
                || assert "missing jq: non-strict run still exits 0 (got $rc)" "fail"
echo "$out" | grep -Eq 'FAIL +jq ' \
  && assert "missing jq: jq row FAILs" "pass" \
  || assert "missing jq: jq row FAILs" "fail"
echo "$out" | grep -Eq 'PASS +python3 ' && echo "$out" | grep -Eq 'PASS +git-remote ' \
  && assert "missing jq: other checks still run and PASS" "pass" \
  || assert "missing jq: other checks still run and PASS" "fail"
echo "$out" | grep -Eq '\[doctor\] summary: pass=[0-9]+ warn=0 fail=1 skip=0' \
  && assert "missing jq: summary counts exactly one FAIL" "pass" \
  || assert "missing jq: summary counts exactly one FAIL" "fail"

rc=0; env "PATH=$SHIMS_NOJQ:$FARM" "HOME=$FHOME" \
    "CHAIN_DOCTOR_REPO_ROOT=$FREPO" "CHAIN_TMP_ROOT=$FTMP" \
    "PLAYWRIGHT_BROWSERS_PATH=$TMP_DIR/browsers" "PYTHONPATH=$PYDIR" \
    "CHAIN_DOCTOR_AMBIENT=" bash "$DOCTOR" --strict-doctor >/dev/null 2>&1 || rc=$?
[[ $rc -eq 1 ]] && assert "missing jq: --strict-doctor exits 1" "pass" \
                || assert "missing jq: --strict-doctor exits 1 (got $rc)" "fail"

echo ""
echo "=== doctor.sh: evidence-born checks ==="
echo ""

# tmp-health: a root where writes fail must FAIL the row (EDQUOT class is
# exit-1-with-no-output, so the check must WRITE, not statfs).
ROTMP="$TMP_DIR/rotmp"
mkdir -p "$ROTMP"
chmod 555 "$ROTMP"
rc=0; out=$(run_doctor "CHAIN_TMP_ROOT=$ROTMP" 2>&1) || rc=$?
echo "$out" | grep -Eq 'FAIL +tmp-health ' \
  && assert "tmp-health FAILs when the tmp root refuses writes" "pass" \
  || assert "tmp-health FAILs when the tmp root refuses writes" "fail"
[[ $rc -eq 0 ]] && assert "tmp-health failure is still advisory (exit 0)" "pass" \
                || assert "tmp-health failure is still advisory (got $rc)" "fail"
chmod 755 "$ROTMP"

# chrome-exclusive: competing chrome processes → WARN naming PIDs (run D).
rc=0; out=$(env "PATH=$SHIMS_CHROME:$FARM" "HOME=$FHOME" \
    "CHAIN_DOCTOR_REPO_ROOT=$FREPO" "CHAIN_TMP_ROOT=$FTMP" \
    "PLAYWRIGHT_BROWSERS_PATH=$TMP_DIR/browsers" "PYTHONPATH=$PYDIR" \
    "CHAIN_DOCTOR_AMBIENT=" bash "$DOCTOR" --only chrome-exclusive 2>&1) || rc=$?
echo "$out" | grep -Eq 'WARN +chrome-exclusive +.*4242' \
  && assert "chrome-exclusive WARNs naming competing PIDs" "pass" \
  || assert "chrome-exclusive WARNs naming competing PIDs" "fail"

# ambient-env: engine-provided snapshot wins over the live environment.
rc=0; out=$(run_doctor "CHAIN_DOCTOR_AMBIENT=CHAIN_FOO CHAIN_BAR" -- --only ambient-env 2>&1) || rc=$?
echo "$out" | grep -Eq 'WARN +ambient-env +.*CHAIN_FOO' \
  && assert "ambient-env WARNs listing engine-snapshotted CHAIN_* vars" "pass" \
  || assert "ambient-env WARNs listing engine-snapshotted CHAIN_* vars" "fail"

# ambient-env standalone: computes from the live env when no snapshot is set.
rc=0; out=$(env "PATH=$SHIMS:$FARM" "HOME=$FHOME" \
    "CHAIN_DOCTOR_REPO_ROOT=$FREPO" "CHAIN_TMP_ROOT=$FTMP" \
    "CHAIN_ZZZ_TEST=1" bash "$DOCTOR" --only ambient-env 2>&1) || rc=$?
echo "$out" | grep -Eq 'WARN +ambient-env +.*CHAIN_ZZZ_TEST' \
  && assert "ambient-env (standalone) lists live CHAIN_* exports" "pass" \
  || assert "ambient-env (standalone) lists live CHAIN_* exports" "fail"

echo ""
echo "=== doctor.sh: pump heartbeat / engine lock ==="
echo ""

# Stale heartbeat + an unserviced request → WARN naming the session.
DISP="$FREPO/runs/goal-session-t1/dispatch"
mkdir -p "$DISP"
touch "$DISP/req.abc123.ready"
touch -d '2 hours ago' "$DISP/.pump-alive"
rc=0; out=$(run_doctor -- --only pump-heartbeat 2>&1) || rc=$?
echo "$out" | grep -Eq 'WARN +pump-heartbeat +.*t1' \
  && assert "stale heartbeat + unserviced request WARNs naming the session" "pass" \
  || assert "stale heartbeat + unserviced request WARNs naming the session" "fail"

# Fresh heartbeat → PASS even with a pending request (pump is alive).
touch "$DISP/.pump-alive"
rc=0; out=$(run_doctor -- --only pump-heartbeat 2>&1) || rc=$?
echo "$out" | grep -Eq 'PASS +pump-heartbeat ' \
  && assert "fresh heartbeat PASSes (live pump)" "pass" \
  || assert "fresh heartbeat PASSes (live pump)" "fail"
rm -rf "$FREPO/runs"

# engine-lock (REL-4 live): fresh → WARN naming the holder (a running session
# is legitimate — the doctor may be running inside it); stale → FAIL (crashed
# session left it); cross-host locks rule by the age TTL.
LOCK="$FREPO/runs/goal-session-t1/.engine.lock"
mkdir -p "$LOCK"
printf '%s\n' "$$" > "$LOCK/pid"
hostname > "$LOCK/host"
date +%s > "$LOCK/epoch"
rc=0; out=$(run_doctor -- --only engine-lock 2>&1) || rc=$?
echo "$out" | grep -Eq "WARN +engine-lock +.*$$" \
  && assert "fresh lock (live pid) → WARN naming the holder pid" "pass" \
  || assert "fresh lock (live pid) → WARN naming the holder pid" "fail"
rm -rf "$FREPO/runs"

# Stale phase lock (dead pid) → FAIL; also proves the repo-level twin is read.
PLOCK="$FREPO/runs/.phase.lock"
mkdir -p "$PLOCK"
printf '999999999\n' > "$PLOCK/pid"
hostname > "$PLOCK/host"
date +%s > "$PLOCK/epoch"
rc=0; out=$(run_doctor -- --only engine-lock 2>&1) || rc=$?
if echo "$out" | grep -Eq 'FAIL +engine-lock +.*stale' \
   && echo "$out" | grep -q 'phase.lock'; then
  assert "stale phase lock (dead pid) → FAIL naming the lock" "pass"
else
  assert "stale phase lock (dead pid) → FAIL naming the lock" "fail"
fi
[[ $rc -eq 0 ]] && assert "stale lock FAIL is still advisory (exit 0)" "pass" \
                || assert "stale lock FAIL is still advisory (got $rc)" "fail"
rm -rf "$FREPO/runs"

# Cross-host: young (under the TTL) → WARN fresh; older than TTL → FAIL stale.
LOCK="$FREPO/runs/goal-session-t2/.engine.lock"
mkdir -p "$LOCK"
printf '4242\n' > "$LOCK/pid"
printf 'some-other-host\n' > "$LOCK/host"
date +%s > "$LOCK/epoch"
rc=0; out=$(run_doctor -- --only engine-lock 2>&1) || rc=$?
echo "$out" | grep -Eq 'WARN +engine-lock ' \
  && assert "cross-host lock under the TTL → WARN (liveness unprovable)" "pass" \
  || assert "cross-host lock under the TTL → WARN (liveness unprovable)" "fail"
printf '%s\n' "$(( $(date +%s) - 200000 ))" > "$LOCK/epoch"
rc=0; out=$(run_doctor -- --only engine-lock 2>&1) || rc=$?
echo "$out" | grep -Eq 'FAIL +engine-lock +.*stale' \
  && assert "cross-host lock past the TTL → FAIL stale" "pass" \
  || assert "cross-host lock past the TTL → FAIL stale" "fail"
rm -rf "$FREPO/runs"

echo ""
echo "=== doctor.sh: chrome-mcp required for goal mode ==="
echo ""

rc=0; out=$(env "PATH=$SHIMS:$FARM" "HOME=$TMP_DIR/emptyhome" \
    "CHAIN_DOCTOR_REPO_ROOT=$NREPO" "CHAIN_TMP_ROOT=$FTMP" \
    "CHAIN_DOCTOR_AMBIENT=" bash "$DOCTOR" --only chrome-mcp 2>&1) || rc=$?
echo "$out" | grep -Eq 'FAIL +chrome-mcp ' \
  && assert "no chrome MCP anywhere → FAIL (required for goal mode)" "pass" \
  || assert "no chrome MCP anywhere → FAIL (required for goal mode)" "fail"

echo ""
echo "=== run-goal.sh wiring: warn-only by construction ==="
echo ""

FN_FILE="$TMP_DIR/preflight_fn.sh"
awk '/^run_doctor_preflight\(\) \{/{f=1} f{print} f&&/^\}/{exit}' \
  "$REPO_ROOT/scripts/automation/run-goal.sh" > "$FN_FILE"
[[ -s "$FN_FILE" ]] \
  && assert "run_doctor_preflight() exists in run-goal.sh" "pass" \
  || assert "run_doctor_preflight() exists in run-goal.sh" "fail"
# shellcheck disable=SC1090
source "$FN_FILE" 2>/dev/null || true

grep -q '_CHAIN_AMBIENT_AT_START' "$REPO_ROOT/scripts/automation/run-goal.sh" \
  && assert "run-goal.sh snapshots ambient CHAIN_* at engine start" "pass" \
  || assert "run-goal.sh snapshots ambient CHAIN_* at engine start" "fail"

# A crashing doctor must NOT stop the engine (the warn-only proof).
CRASH="$TMP_DIR/crash-doctor.sh"
MARK="$TMP_DIR/crash-invoked"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 97\n' "$MARK" > "$CRASH"
chmod +x "$CRASH"
SCRIPT_DIR="$REPO_ROOT/scripts/automation"   # the function's default lookup dir
_CHAIN_AMBIENT_AT_START=""
rc=0; out=$( (CHAIN_DOCTOR=true CHAIN_DOCTOR_BIN="$CRASH" run_doctor_preflight) 2>&1 ) || rc=$?
[[ $rc -eq 0 ]] && assert "crashing doctor: engine startup proceeds (rc 0)" "pass" \
                || assert "crashing doctor: engine startup proceeds (got $rc)" "fail"
[[ -f "$MARK" ]] && assert "crashing doctor: doctor was actually invoked" "pass" \
                 || assert "crashing doctor: doctor was actually invoked" "fail"
echo "$out" | grep -qi 'advisory\|continuing' \
  && assert "crashing doctor: engine says it is continuing (advisory)" "pass" \
  || assert "crashing doctor: engine says it is continuing (advisory)" "fail"

# CHAIN_DOCTOR=false skips the doctor entirely.
rm -f "$MARK"
rc=0; out=$( (CHAIN_DOCTOR=false CHAIN_DOCTOR_BIN="$CRASH" run_doctor_preflight) 2>&1 ) || rc=$?
{ [[ $rc -eq 0 && ! -f "$MARK" ]]; } \
  && assert "CHAIN_DOCTOR=false skips the doctor (never invoked)" "pass" \
  || assert "CHAIN_DOCTOR=false skips the doctor (rc=$rc invoked=$([[ -f $MARK ]] && echo yes || echo no))" "fail"
echo "$out" | grep -qi 'skip' \
  && assert "CHAIN_DOCTOR=false says so in the engine log" "pass" \
  || assert "CHAIN_DOCTOR=false says so in the engine log" "fail"

# Healthy doctor: table + the engine's one-line count summary reach the log.
OKDOC="$TMP_DIR/ok-doctor.sh"
cat > "$OKDOC" <<'SH'
#!/usr/bin/env bash
echo "  PASS  python3           3.12"
echo "[doctor] summary: pass=1 warn=0 fail=0 skip=0"
SH
chmod +x "$OKDOC"
rc=0; out=$( (CHAIN_DOCTOR=true CHAIN_DOCTOR_BIN="$OKDOC" run_doctor_preflight) 2>&1 ) || rc=$?
{ [[ $rc -eq 0 ]] && echo "$out" | grep -q 'PASS  python3' \
                  && echo "$out" | grep -q '\[run-goal\] doctor: .*pass=1'; } \
  && assert "healthy doctor: table + engine count summary land in the log" "pass" \
  || assert "healthy doctor: table + engine count summary land in the log (rc=$rc)" "fail"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo ""

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
