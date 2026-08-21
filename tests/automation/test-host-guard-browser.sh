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
# Section A's fakes must carry the profile names browser-confine.sh derives for
# $PROJ: iad-qa-<base>-<path-hash offset>. Same derivation as
# lib/common.sh:_project_port_offset — section B (B10) proves the two agree by
# reaping a profile name that came out of ensure_qa_browser_env itself.
# Computed inline because helper_env is only defined in section B.
_h="$(printf '%s' "$PROJ" | sha1sum | cut -c1-4)"
OWN="iad-qa-$BASE-$(( 16#$_h % 1000 ))"
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
P0="$(spawn --user-data-dir=$PROOT/$OWN --remote-debugging-port=10001)"
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
P_REND="$(spawn --type=renderer --user-data-dir=$PROOT/$OWN --remote-debugging-port=10004)"
OUT="$(run_bc)"
[[ "$OUT" == *"qa_browsers=3"* ]] && assert "renderer excluded from main-browser count" pass || assert "renderer excluded from main-browser count ($OUT)" fail
pkill -KILL -f "fake-chrome --type=renderer" 2>/dev/null

# A6. When taskset cannot work, OUR browser is terminated and its profile
# bookkeeping swept; a FOREIGN one is only warned about.
SHIM="$WORK/shim"; mkdir -p "$SHIM"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SHIM/taskset"; chmod +x "$SHIM/taskset"
P_OWN2="$(spawn --user-data-dir=$PROOT/$OWN-qa --remote-debugging-port=10005)"
printf '{"port":10005,"pid":%s}' "$P_OWN2" > "$PROOT/$OWN-qa.meta.json"
printf '{"pid":%s}' "$P_OWN2" > "$PROOT/$OWN-qa.mcp.lock"
P_FGN3="$(spawn --user-data-dir=$PROOT/other-wide2 --remote-debugging-port=10006)"
OUT="$(env PATH="$SHIM:$PATH" HOST_GUARD_ROOT="$PROJ" CHROME_PROFILE_ROOT="$PROOT" \
        HOST_GUARD_MCP_MATCH="$WORK/no-such-mcp" bash "$BC" 2>&1)"
wait_for 8 dead "$P_OWN2" && assert "taskset impossible → own browser terminated" pass || assert "taskset impossible → own browser terminated" fail
[[ -f "$PROOT/$OWN-qa.meta.json" ]] && assert "terminated browser's meta.json swept" fail || assert "terminated browser's meta.json swept" pass
[[ -f "$PROOT/$OWN-qa.mcp.lock" ]] && assert "terminated browser's mcp.lock swept" fail || assert "terminated browser's mcp.lock swept" pass
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
[[ "$PROF" =~ ^iad-qa-myproj-[0-9]{1,3}$ ]] && assert "browser-qa lane profile = iad-qa-<base>-<offset>" pass || assert "browser-qa lane profile = iad-qa-<base>-<offset> (got $PROF)" fail
[[ "$PORT" -ge 10000 && "$PORT" -le 10999 ]] && assert "browser-qa lane port in 10000-10999" pass || assert "browser-qa lane port in 10000-10999 ($PORT)" fail
assert_eq "profile offset equals port offset (browser-qa lane)" "$(( PORT - 10000 ))" "${PROF##*-}"
read -r PROF2 PORT2 <<< "$(helper_env /x/myproj qa)"
[[ "$PROF2" =~ ^iad-qa-myproj-[0-9]{1,3}-qa$ ]] && assert "qa lane profile carries offset then suffix" pass || assert "qa lane profile carries offset then suffix (got $PROF2)" fail
[[ "$PORT2" -ge 11000 && "$PORT2" -le 11999 ]] && assert "qa lane port in 11000-11999" pass || assert "qa lane port in 11000-11999 ($PORT2)" fail
[[ "$PORT" != "$PORT2" ]] && assert "concurrent lanes get different ports" pass || assert "concurrent lanes get different ports" fail
# Same directory NAME, different paths (every benchmark scratch is ".../scratch"):
# the profiles MUST differ — sharing one while the ports differ is the G8
# stage-1 ECONNREFUSED failure.
read -r PROF_A PORT_A <<< "$(helper_env /tmp/a/scratch '')"
read -r PROF_B PORT_B <<< "$(helper_env /tmp/b/scratch '')"
[[ "$PROF_A" != "$PROF_B" ]] && assert "same basename, different path → different profiles" pass || assert "same basename, different path → different profiles (both $PROF_A)" fail
read -r PROF3 PORT3 <<< "$(env CHROME_WS_PROFILE=operator CHROME_WS_PORT=9999 bash -c "
    source '$AUTO/lib/common.sh' >/dev/null 2>&1; REPO_ROOT=/x/myproj; ensure_qa_browser_env ''
    echo \"\$CHROME_WS_PROFILE \$CHROME_WS_PORT\"")"
assert_eq "operator profile override respected" "operator" "$PROF3"
assert_eq "operator port override respected"    "9999"     "$PORT3"

# Vendored layout: the offset must key off the PROJECT root, not the subtree.
read -r PROF4 PORT4 <<< "$(helper_env /x/myproj/incredible_auto_dev '')"
assert_eq "vendored layout resolves to project profile" "$PROF" "$PROF4"
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

# B10. Reap works WITHOUT host-guard.env (the framework repo and every benchmark
# scratch have none): confinement is skipped, Pass D still runs, own profile dies,
# foreign survives, and the own meta/lock files are swept.
PROJ_NOHG="$WORK/proj-nohg"; mkdir -p "$PROJ_NOHG"
read -r OWN_PROF _ <<< "$(helper_env "$PROJ_NOHG" '')"
P_OWN="$(spawn "--user-data-dir=$PROOT/$OWN_PROF" --remote-debugging-port=10999)"
P_OTHER="$(spawn "--user-data-dir=$PROOT/iad-qa-elsewhere-7" --remote-debugging-port=10998)"
printf '{"port":10999,"pid":%s}\n' "$P_OWN" > "$PROOT/$OWN_PROF.meta.json"
OUT="$(env HOST_GUARD_ROOT="$PROJ_NOHG" CHROME_PROFILE_ROOT="$PROOT" HOST_GUARD_MCP_MATCH="$WORK/no-such-mcp" CHAIN_BQA_REAP=1 CHAIN_AGENT_BACKEND=claude bash "$BC" --reap 2>&1)"
wait_for 8 dead "$P_OWN" && assert "reap without host-guard: own browser reaped" pass || assert "reap without host-guard: own browser reaped" fail
alive "$P_OTHER" && assert "reap without host-guard: foreign browser survives" pass || assert "reap without host-guard: foreign browser survives" fail
[[ ! -f "$PROOT/$OWN_PROF.meta.json" ]] && assert "reap sweeps the reaped profile's meta" pass || assert "reap sweeps the reaped profile's meta" fail
[[ "$OUT" == *"reap only"* ]] && assert "reap without host-guard announces confinement skipped" pass || assert "reap without host-guard announces confinement skipped ($OUT)" fail
pkill -KILL -f "fake-chrome --user-data-dir=$PROOT" 2>/dev/null

# B11. qa_browser_reap_on_exit (lib/common.sh): the engine-exit hook. Default on,
# never for the interactive backend, CHAIN_BQA_REAP_ON_EXIT=0 opts out.
# `2>&1 >/dev/null` (in that order) forwards the hook's STDERR to the caller and
# drops browser-confine's stdout summary — B12 asserts on the stderr skip line.
# $PRE (when set in the extra env) runs inside the SAME shell that then calls the
# hook — B13 uses it to acquire an engine lock carrying that shell's own $$.
reap_on_exit() { # <backend> <on-exit-knob> [extra env...] → runs the hook in a clean env
  env -u CHROME_WS_PROFILE -u CHROME_WS_PORT CHROME_PROFILE_ROOT="$PROOT" \
      HOST_GUARD_MCP_MATCH="$WORK/no-such-mcp" \
      CHAIN_AGENT_BACKEND="$1" CHAIN_BQA_REAP_ON_EXIT="$2" "${@:3}" bash -c "
    source '$AUTO/lib/common.sh' >/dev/null 2>&1
    REPO_ROOT='$PROJ_NOHG'
    eval \"\${PRE:-}\"
    qa_browser_reap_on_exit" 2>&1 >/dev/null
}
P_OWN="$(spawn "--user-data-dir=$PROOT/$OWN_PROF" --remote-debugging-port=10999)"
reap_on_exit interactive 1
alive "$P_OWN" && assert "exit hook: no-op in interactive backend" pass || assert "exit hook: no-op in interactive backend" fail
reap_on_exit claude 0
alive "$P_OWN" && assert "exit hook: CHAIN_BQA_REAP_ON_EXIT=0 opts out" pass || assert "exit hook: CHAIN_BQA_REAP_ON_EXIT=0 opts out" fail
reap_on_exit claude 1
wait_for 8 dead "$P_OWN" && assert "exit hook: headless engine reaps its own browser" pass || assert "exit hook: headless engine reaps its own browser" fail
# HOST_GUARD_ROOT is a documented operator override; inherited from the launching
# shell it would aim Pass D at ANOTHER project's browsers while the sibling guard
# (keyed on $REPO_ROOT/runs) stayed blind. The lanes pinned their identity from
# REPO_ROOT, so the reap must too.
P_OWN="$(spawn "--user-data-dir=$PROOT/$OWN_PROF" --remote-debugging-port=10999)"
reap_on_exit claude 1 HOST_GUARD_ROOT=/some/other/project
wait_for 8 dead "$P_OWN" && assert "exit hook: an inherited HOST_GUARD_ROOT cannot redirect the reap" pass || assert "exit hook: an inherited HOST_GUARD_ROOT cannot redirect the reap" fail
pkill -KILL -f "fake-chrome --user-data-dir=$PROOT" 2>/dev/null

# B12. A LIVE sibling engine in the same checkout blocks the exit reap. The QA
# browser identity is per project PATH, but the REL-4 engine lock is per SESSION
# (runs/goal-session-<sid>/.engine.lock), so two headless sessions in one
# checkout satisfy the owner predicate independently and would reap each other's
# browser mid-dispatch. The lock is written by engine-lock.sh's own acquire, so
# the layout can never drift from the real one; only the pid is rewritten.
SIB_LOCK="$PROJ_NOHG/runs/goal-session-other/.engine.lock"
bash -c "source '$AUTO/lib/engine-lock.sh'; acquire_engine_lock '$SIB_LOCK' 'sibling engine'" >/dev/null 2>&1
P_SIB="$(spawn "--sibling-engine=$WORK/other")"   # a live pid that is not a browser
echo "$P_SIB" > "$SIB_LOCK/pid"
P_OWN="$(spawn "--user-data-dir=$PROOT/$OWN_PROF" --remote-debugging-port=10999)"
OUT="$(reap_on_exit claude 1)"
alive "$P_OWN" && assert "exit hook: live sibling engine blocks the reap" pass || assert "exit hook: live sibling engine blocks the reap" fail
[[ "$OUT" == *"exit reap skipped"*"$SIB_LOCK"*"pid $P_SIB"* ]] && assert "exit hook: skip line names the sibling lock and pid" pass || assert "exit hook: skip line names the sibling lock and pid ($OUT)" fail
# Same lock, same recorded pid — but the holder is now provably gone. (A literal
# "dead" pid would be a flake: pid_max on this host is in the millions.)
kill -KILL "$P_SIB" 2>/dev/null
wait_for 8 dead "$P_SIB" && assert "sibling fake is provably dead before the second reap" pass || assert "sibling fake is provably dead before the second reap" fail
reap_on_exit claude 1
wait_for 8 dead "$P_OWN" && assert "exit hook: dead sibling lock does not block the reap" pass || assert "exit hook: dead sibling lock does not block the reap" fail
rm -rf "$PROJ_NOHG/runs"
pkill -KILL -f "fake-chrome --user-data-dir=$PROOT" 2>/dev/null

# B13. The branch EVERY real engine exit takes: the only lock in the checkout is
# our own, and it must not be read as a sibling — that would turn the default-on
# reap into a silent no-op. The lock has to record the calling shell's $$, so it
# is acquired via $PRE inside the hook's own shell, using the real helper.
P_OWN="$(spawn "--user-data-dir=$PROOT/$OWN_PROF" --remote-debugging-port=10999)"
OUT="$(reap_on_exit claude 1 \
  PRE="source '$AUTO/lib/engine-lock.sh'; acquire_engine_lock '$PROJ_NOHG/runs/goal-session-self/.engine.lock' self >/dev/null")"
wait_for 8 dead "$P_OWN" && assert "exit hook: our OWN engine lock does not block the reap" pass || assert "exit hook: our OWN engine lock does not block the reap" fail
[[ -z "$OUT" ]] && assert "exit hook: own lock prints no skip line" pass || assert "exit hook: own lock prints no skip line ($OUT)" fail
rm -rf "$PROJ_NOHG/runs"
pkill -KILL -f "fake-chrome --user-data-dir=$PROOT" 2>/dev/null

# B14. The exit hook is reap-ONLY. Passes A-C scan the whole profile root and
# (pass B) the DEFAULT Chrome-MCP match, neither of which the hook scopes — so an
# engine exiting anywhere (a test sandbox included) would re-taskset browsers and
# MCP servers that are not its own into its mask. At exit there is nothing to
# gain from confining a browser we are about to kill. $PROJ carries a
# host-guard.env (mask "0"), so without the guard the passes WOULD run here.
P_FGN4="$(spawn "--user-data-dir=$PROOT/other-wide3" --remote-debugging-port=10997)"
BEFORE4="$(allowed "$P_FGN4")"
P_OWN="$(spawn "--user-data-dir=$PROOT/$OWN" --remote-debugging-port=10996)"
reap_on_exit claude 1 PRE="REPO_ROOT='$PROJ'"
wait_for 8 dead "$P_OWN" && assert "exit hook: reaps under a guarded project too" pass || assert "exit hook: reaps under a guarded project too" fail
assert_eq "exit hook is reap-only: a foreign browser's affinity is untouched" "$BEFORE4" "$(allowed "$P_FGN4")"
pkill -KILL -f "fake-chrome --user-data-dir=$PROOT" 2>/dev/null

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
# The engine-exit reap must ride run-goal.sh's single composed EXIT trap: a
# second `trap … EXIT` would silently drop the first one's cleanup.
grep -q 'qa_browser_reap_on_exit' "$AUTO/run-goal.sh" && assert "run-goal.sh exit trap calls qa_browser_reap_on_exit" pass || assert "run-goal.sh exit trap calls qa_browser_reap_on_exit" fail
awk '/^_goal_engine_on_exit\(\)/,/^}/' "$AUTO/run-goal.sh" | grep -q 'qa_browser_reap_on_exit' && assert "the call sits inside _goal_engine_on_exit (single composed trap)" pass || assert "the call sits inside _goal_engine_on_exit" fail
# The skip line and browser-confine's warnings must reach the engine log: the
# call site may not redirect the hook's stderr away.
awk '/^_goal_engine_on_exit\(\)/,/^}/' "$AUTO/run-goal.sh" | grep -q 'qa_browser_reap_on_exit 2>/dev/null' && assert "the exit-trap call keeps the hook's stderr" fail || assert "the exit-trap call keeps the hook's stderr" pass
# Anchored so the prose in the trap's own comment ("never add a second `trap …
# EXIT`") is not counted as a second installation.
grep -cE '^[[:space:]]*trap [^#]*EXIT' "$AUTO/run-goal.sh" | grep -qx '1' && assert "run-goal.sh still has exactly one EXIT trap" pass || assert "run-goal.sh still has exactly one EXIT trap" fail

grep -q 'CHROME_WS_PROFILE' "$ENGINE_ROOT/adapters/claude/sync.py" \
  && ! grep -q 'setdefault("CHROME_WS_PROFILE"' "$ENGINE_ROOT/adapters/claude/sync.py" \
  && assert "sync.py documents why settings.local.json carries no browser pin" pass \
  || assert "sync.py documents why settings.local.json carries no browser pin" fail

echo ""
echo "──────────────────────────────────────────────────────────────────────"
echo "  PASS: $PASS   FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
