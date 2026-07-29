#!/usr/bin/env bash
# test-host-guard-browser.sh — QA-browser confinement:
#   A. host-guard/browser-confine.sh behavior against fake browser processes
#      (no-op without host-guard, re-taskset a wide browser, leave a confined
#      one alone, kill only our own profile when taskset is impossible, never
#      kill a foreign profile, confine but never kill an MCP server, sweep
#      stale meta/lock files with the mid-launch age guard, opt-in reap)
#   B. the identity helpers (ensure_qa_browser_env / strip_display_for_headless_qa)
#      and the cross-language parity of the port-offset arithmetic
#   C. wiring assertions: every browser dispatch surface calls the pass, and
#      host-guard-adopt.sh calls it on BOTH exits (including the common
#      "already confined" early return)
#
# Offline, API-free, spawns only its own fakes inside a mktemp sandbox.
# The fakes are plain `bash` loops carrying a crafted argv — no real Chrome.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AUTO="$ENGINE_ROOT/scripts/automation"
BC="$AUTO/host-guard/browser-confine.sh"

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}
assert_eq() { if [[ "$2" == "$3" ]]; then assert "$1" pass; else echo "  FAIL  $1 (expected '$2', got '$3')"; FAIL=$((FAIL + 1)); fi; }

WORK="$(mktemp -d)"
cleanup() { pkill -KILL -f "$WORK/" 2>/dev/null; rm -rf "$WORK"; return 0; }
trap cleanup EXIT

wait_for() {
  local deadline=$(( $(date +%s) + $1 )); shift
  while ! "$@" 2>/dev/null; do
    [[ $(date +%s) -ge $deadline ]] && return 1
    sleep 0.2
  done
  return 0
}

PROJ="$WORK/proj"
PROOT="$WORK/cache/superpowers/browser-profiles"
mkdir -p "$PROJ/project-extensions/host-guard" "$PROOT"
BASE="$(basename "$PROJ")"
printf 'while :; do sleep 1; done\n' > "$WORK/fake-chrome"

# Every fake is uniquely identifiable by the sandbox path in its argv, so the
# EXIT trap's pkill can never reach a process this test did not start.
spawn() { # <argv...> → pid of the live fake
  setsid bash "$WORK/fake-chrome" "$@" >/dev/null 2>&1 &
  local marker="$1" pid=""
  wait_for 5 bash -c "pgrep -f 'fake-chrome $marker' >/dev/null"
  pid="$(pgrep -f "fake-chrome $marker" | tail -1)"
  echo "$pid"
}
allowed() { awk -F'\t' '/^Cpus_allowed_list/{print $2}' "/proc/$1/status" 2>/dev/null; }
alive() { kill -0 "$1" 2>/dev/null; }
dead() { ! kill -0 "$1" 2>/dev/null; }

# HOST_GUARD_MCP_MATCH is scoped to this sandbox in EVERY run below: pass B is
# deliberately profile-root-independent, so an unscoped run inside a developer's
# session would reach their real, live Chrome-MCP server.
# Args after `--` go to the script; anything before is extra environment.
run_bc() {
  local -a envs=() args=()
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--" ]]; then shift; args=("$@"); break; fi
    envs+=("$1"); shift
  done
  env HOST_GUARD_ROOT="$PROJ" CHROME_PROFILE_ROOT="$PROOT" \
      HOST_GUARD_MCP_MATCH="$WORK/no-such-mcp" "${envs[@]}" bash "$BC" "${args[@]}"
}

# The sandbox's fake MCP server carries the mktemp-unique $WORK path in its
# argv, so matching on that can never select a real server. NEVER widen this to
# the production default here.
MCP_MATCH="$WORK/superpowers-chrome mcp/dist/index.js"

echo "── A. browser-confine.sh behavior ─────────────────────────────────────"

# A0. Project-neutrality: no host-guard.env at all ⇒ nothing happens.
P0="$(spawn --user-data-dir=$PROOT/iad-qa-$BASE --remote-debugging-port=10001)"
BEFORE="$(allowed "$P0")"
OUT="$(run_bc)"
[[ "$OUT" == *"nothing to do"* ]] && assert "no host-guard.env → no-op message" pass || assert "no host-guard.env → no-op message" fail
assert_eq "no host-guard.env → affinity untouched" "$BEFORE" "$(allowed "$P0")"

cat > "$PROJ/project-extensions/host-guard/host-guard.env" <<'EOF'
HOST_GUARD_ENABLED=1
HOST_GUARD_CPU_LIST="0"
EOF

# A0b. Explicit opt-out still no-ops.
OUT="$(run_bc HOST_GUARD_BROWSER_CONFINE=0)"
[[ "$OUT" == *"nothing to do"* ]] && assert "HOST_GUARD_BROWSER_CONFINE=0 → no-op" pass || assert "HOST_GUARD_BROWSER_CONFINE=0 → no-op" fail
assert_eq "opt-out → affinity untouched" "$BEFORE" "$(allowed "$P0")"

# A1. A wide browser on OUR profile is re-tasksetted, not killed.
OUT="$(run_bc)"
assert_eq "wide own-profile browser confined" "0" "$(allowed "$P0")"
alive "$P0" && assert "wide own-profile browser kept alive" pass || assert "wide own-profile browser kept alive" fail
[[ "$OUT" == *"confined=1"* ]] && assert "summary counts the confinement" pass || assert "summary counts the confinement ($OUT)" fail

# A2. An already-confined browser is left alone.
OUT="$(run_bc)"
[[ "$OUT" == *"kept=1"* ]] && assert "already-confined browser kept, not re-confined" pass || assert "already-confined browser kept, not re-confined ($OUT)" fail

# A3. A foreign profile already confined ELSEWHERE is not yanked into our mask
# (its width is within ours — another project owns it).
P_FGN="$(spawn --user-data-dir=$PROOT/other-project --remote-debugging-port=10002)"
taskset -a -c -p 1 "$P_FGN" >/dev/null 2>&1
OUT="$(run_bc)"
assert_eq "foreign confined browser untouched" "1" "$(allowed "$P_FGN")"
alive "$P_FGN" && assert "foreign confined browser alive" pass || assert "foreign confined browser alive" fail

# A4. A foreign profile that is effectively UNCONFINED does get narrowed —
# leaving an all-CPU browser running is the thing that resets the host.
P_FGN2="$(spawn --user-data-dir=$PROOT/other-wide --remote-debugging-port=10003)"
run_bc >/dev/null
assert_eq "foreign UNCONFINED browser narrowed" "0" "$(allowed "$P_FGN2")"
alive "$P_FGN2" && assert "foreign unconfined browser not killed" pass || assert "foreign unconfined browser not killed" fail

# A5. Renderer/helper processes (--type=) are not treated as main browsers;
# they ride the parent's tree walk.
P_REND="$(spawn --type=renderer --user-data-dir=$PROOT/iad-qa-$BASE --remote-debugging-port=10004)"
OUT="$(run_bc)"
[[ "$OUT" == *"qa_browsers=3"* ]] && assert "renderer excluded from main-browser count" pass || assert "renderer excluded from main-browser count ($OUT)" fail
pkill -KILL -f "fake-chrome --type=renderer" 2>/dev/null

# A6. When taskset cannot work, OUR browser is terminated and its profile
# bookkeeping swept; a FOREIGN one is only warned about.
SHIM="$WORK/shim"; mkdir -p "$SHIM"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SHIM/taskset"; chmod +x "$SHIM/taskset"
P_OWN2="$(spawn --user-data-dir=$PROOT/iad-qa-$BASE-qa --remote-debugging-port=10005)"
printf '{"port":10005,"pid":%s}' "$P_OWN2" > "$PROOT/iad-qa-$BASE-qa.meta.json"
printf '{"pid":%s}' "$P_OWN2" > "$PROOT/iad-qa-$BASE-qa.mcp.lock"
P_FGN3="$(spawn --user-data-dir=$PROOT/other-wide2 --remote-debugging-port=10006)"
OUT="$(env PATH="$SHIM:$PATH" HOST_GUARD_ROOT="$PROJ" CHROME_PROFILE_ROOT="$PROOT" \
        HOST_GUARD_MCP_MATCH="$WORK/no-such-mcp" bash "$BC" 2>&1)"
wait_for 8 dead "$P_OWN2" && assert "taskset impossible → own browser terminated" pass || assert "taskset impossible → own browser terminated" fail
[[ -f "$PROOT/iad-qa-$BASE-qa.meta.json" ]] && assert "terminated browser's meta.json swept" fail || assert "terminated browser's meta.json swept" pass
[[ -f "$PROOT/iad-qa-$BASE-qa.mcp.lock" ]] && assert "terminated browser's mcp.lock swept" fail || assert "terminated browser's mcp.lock swept" pass
alive "$P_FGN3" && assert "taskset impossible → foreign browser NOT killed" pass || assert "taskset impossible → foreign browser NOT killed" fail
[[ "$OUT" == *"not ours to kill"* ]] && assert "foreign unconfinable browser warns" pass || assert "foreign unconfinable browser warns" fail
pkill -KILL -f "fake-chrome --user-data-dir=$PROOT/other-wide2" 2>/dev/null

# A7. MCP servers are confined, never killed.
P_MCP="$(spawn $WORK/superpowers-chrome/mcp/dist/index.js --port=1)"
OUT="$(env HOST_GUARD_ROOT="$PROJ" CHROME_PROFILE_ROOT="$PROOT" \
        HOST_GUARD_MCP_MATCH="$MCP_MATCH" bash "$BC")"
assert_eq "MCP server confined" "0" "$(allowed "$P_MCP")"
alive "$P_MCP" && assert "MCP server never killed" pass || assert "MCP server never killed" fail
[[ "$OUT" == *"mcp_confined=1"* ]] && assert "summary counts the MCP confinement" pass || assert "summary counts the MCP confinement ($OUT)" fail
OUT="$(env PATH="$SHIM:$PATH" HOST_GUARD_ROOT="$PROJ" CHROME_PROFILE_ROOT="$PROOT" \
        HOST_GUARD_MCP_MATCH="$MCP_MATCH" bash "$BC" 2>&1)"
alive "$P_MCP" && assert "unconfinable MCP server still not killed" pass || assert "unconfinable MCP server still not killed" fail
pkill -KILL -f "fake-chrome $WORK/superpowers-chrome" 2>/dev/null

# A8. Stale-file sweep, with the mid-launch age guard.
printf '{"port":19999,"pid":999999}' > "$PROOT/ghost.meta.json"
touch -t 202601010000 "$PROOT/ghost.meta.json"
printf '{"port":19998,"pid":999998}' > "$PROOT/justborn.meta.json"      # fresh + dead pid
printf '{"port":19997,"pid":%s}' "$P0" > "$PROOT/liveone.meta.json"
touch -t 202601010000 "$PROOT/liveone.meta.json"
run_bc >/dev/null
[[ -f "$PROOT/ghost.meta.json" ]]    && assert "stale dead-pid meta swept" fail || assert "stale dead-pid meta swept" pass
[[ -f "$PROOT/justborn.meta.json" ]] && assert "fresh dead-pid meta kept (mid-launch guard)" pass || assert "fresh dead-pid meta kept (mid-launch guard)" fail
[[ -f "$PROOT/liveone.meta.json" ]]  && assert "live-pid meta kept" pass || assert "live-pid meta kept" fail

# A9. Reap is opt-in, engine-mode only, and hits only our own profiles.
run_bc -- --reap >/dev/null
alive "$P0" && assert "reap: no-op without CHAIN_BQA_REAP" pass || assert "reap: no-op without CHAIN_BQA_REAP" fail
run_bc CHAIN_BQA_REAP=1 CHAIN_AGENT_BACKEND=interactive -- --reap >/dev/null
alive "$P0" && assert "reap: no-op in interactive backend" pass || assert "reap: no-op in interactive backend" fail
run_bc CHAIN_BQA_REAP=1 CHAIN_AGENT_BACKEND=headless -- --reap >/dev/null
wait_for 8 dead "$P0" && assert "reap: own browser reaped when opted in" pass || assert "reap: own browser reaped when opted in" fail
alive "$P_FGN" && assert "reap: foreign browser survives" pass || assert "reap: foreign browser survives" fail
pkill -KILL -f "fake-chrome --user-data-dir=$PROOT" 2>/dev/null

echo ""
echo "── B. identity helpers + offset parity ────────────────────────────────"

helper_env() { # REPO_ROOT suffix [preset...] → "profile port"
  env -u CHROME_WS_PROFILE -u CHROME_WS_PORT "${@:3}" bash -c "
    source '$AUTO/lib/common.sh' >/dev/null 2>&1
    REPO_ROOT='$1'
    ensure_qa_browser_env '$2'
    echo \"\$CHROME_WS_PROFILE \$CHROME_WS_PORT\""
}
read -r PROF PORT <<< "$(helper_env /x/myproj '')"
assert_eq "browser-qa lane profile" "iad-qa-myproj" "$PROF"
[[ "$PORT" -ge 10000 && "$PORT" -le 10999 ]] && assert "browser-qa lane port in 10000-10999" pass || assert "browser-qa lane port in 10000-10999 ($PORT)" fail
read -r PROF2 PORT2 <<< "$(helper_env /x/myproj qa)"
assert_eq "qa lane profile carries the suffix" "iad-qa-myproj-qa" "$PROF2"
[[ "$PORT2" -ge 11000 && "$PORT2" -le 11999 ]] && assert "qa lane port in 11000-11999" pass || assert "qa lane port in 11000-11999 ($PORT2)" fail
[[ "$PORT" != "$PORT2" ]] && assert "concurrent lanes get different ports" pass || assert "concurrent lanes get different ports" fail
read -r PROF3 PORT3 <<< "$(env CHROME_WS_PROFILE=operator CHROME_WS_PORT=9999 bash -c "
    source '$AUTO/lib/common.sh' >/dev/null 2>&1; REPO_ROOT=/x/myproj; ensure_qa_browser_env ''
    echo \"\$CHROME_WS_PROFILE \$CHROME_WS_PORT\"")"
assert_eq "operator profile override respected" "operator" "$PROF3"
assert_eq "operator port override respected"    "9999"     "$PORT3"

# Vendored layout: the offset must key off the PROJECT root, not the subtree.
read -r PROF4 PORT4 <<< "$(helper_env /x/myproj/incredible_auto_dev '')"
assert_eq "vendored layout resolves to project name" "iad-qa-myproj" "$PROF4"
assert_eq "vendored layout resolves to project port" "$PORT" "$PORT4"

# DISPLAY stripping (engine-mode headless) + the debug escape hatch.
OUT="$(env DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 bash -c "
  source '$AUTO/lib/common.sh' >/dev/null 2>&1
  strip_display_for_headless_qa; echo \"[\${DISPLAY:-}][\${WAYLAND_DISPLAY:-}]\"")"
assert_eq "DISPLAY stripped for headless QA" "[][]" "$OUT"
OUT="$(env DISPLAY=:0 CHAIN_BQA_HEADED=1 bash -c "
  source '$AUTO/lib/common.sh' >/dev/null 2>&1
  strip_display_for_headless_qa; echo \"[\${DISPLAY:-}]\"")"
assert_eq "CHAIN_BQA_HEADED=1 keeps DISPLAY" "[:0]" "$OUT"

# The port offset is implemented three times (common.sh, host-guard-exec.sh,
# and the doctor's docs) — they must never drift apart.
for p in /x/alpha /y/beta /z/gamma; do
  a="$(bash -c "source '$AUTO/lib/common.sh' >/dev/null 2>&1; REPO_ROOT='$p'; _project_port_offset")"
  b="$(printf '%s' "$p" | sha1sum | cut -c1-4)"; b=$(( 16#$b % 1000 ))
  c="$(python3 -c "import hashlib,sys; print(int(hashlib.sha1(sys.argv[1].encode()).hexdigest()[:4],16)%1000)" "$p")"
  assert_eq "offset parity bash/exec/python for $p" "$a|$a" "$b|$c"
done

echo ""
echo "── C. dispatch-surface wiring ─────────────────────────────────────────"

for f in browser-qa-phase.sh qa-phase.sh goal-iter-lean.sh ui-audit-phase.sh; do
  grep -q 'ensure_qa_browser_env' "$AUTO/$f" && assert "$f pins the QA browser identity" pass || assert "$f pins the QA browser identity" fail
  grep -q 'strip_display_for_headless_qa' "$AUTO/$f" && assert "$f runs QA headless" pass || assert "$f runs QA headless" fail
  grep -qE 'bqa_browser_confine|browser-confine\.sh' "$AUTO/$f" && assert "$f runs the confinement pass" pass || assert "$f runs the confinement pass" fail
done

# The confinement pass must NOT be gated behind the opt-in REL-14 preflight:
# an escaped browser is a hardware-safety problem, not a QA convenience.
grep -q 'CHAIN_BQA_PREFLIGHT' "$AUTO/lib/replay-lane.sh" \
  && sed -n '/^bqa_browser_confine()/,/^}/p' "$AUTO/lib/replay-lane.sh" | grep -q 'CHAIN_BQA_PREFLIGHT' \
  && assert "confinement pass is unconditional (not preflight-gated)" fail \
  || assert "confinement pass is unconditional (not preflight-gated)" pass

# host-guard-adopt.sh must sweep on BOTH exits — the "already confined" early
# return is the COMMON path, and skipping it there is exactly how an escaped
# browser survives every adoption.
# Structural, not line-number-based: the block from the "already confined"
# message up to its `exit 0` must contain the pass.
awk '/already confined \(/{inblk=1} inblk{print} inblk&&/^  exit 0/{exit}' "$AUTO/host-guard-adopt.sh" \
  | grep -q '_browser_pass' \
  && assert "adopt: confinement pass runs on the already-confined early exit" pass \
  || assert "adopt: confinement pass runs on the already-confined early exit" fail
N_PASSES="$(grep -c '^  _browser_pass$' "$AUTO/host-guard-adopt.sh")"
[[ "$N_PASSES" -ge 2 ]] && assert "adopt: confinement pass runs on both exits" pass || assert "adopt: confinement pass runs on both exits ($N_PASSES)" fail
grep -q 'hg_register pump' "$AUTO/host-guard-adopt.sh" && assert "adopt: registers the pump in the machine registry" pass || assert "adopt: registers the pump in the machine registry" fail

# The pump wrapper must NOT pin a profile: it serves both QA lanes at once and
# an explicit profile would collapse them onto one shared browser.
grep -q 'CHROME_WS_PROFILE=' "$AUTO/host-guard-exec.sh" && assert "exec: does not pin a shared pump profile" fail || assert "exec: does not pin a shared pump profile" pass
grep -q 'CHROME_WS_PROFILE' "$ENGINE_ROOT/adapters/claude/sync.py" \
  && ! grep -q 'setdefault("CHROME_WS_PROFILE"' "$ENGINE_ROOT/adapters/claude/sync.py" \
  && assert "sync.py documents why settings.local.json carries no browser pin" pass \
  || assert "sync.py documents why settings.local.json carries no browser pin" fail

echo ""
echo "──────────────────────────────────────────────────────────────────────"
echo "  PASS: $PASS   FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
