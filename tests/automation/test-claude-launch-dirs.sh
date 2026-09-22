#!/usr/bin/env bash
# test-claude-launch-dirs.sh — policy `claude_launch_dirs` gives every declared
# project subdirectory a GENERATED, deny-only .claude/settings.json that carries the
# neutral policy's deny list.
#
# Why this exists: Claude Code reads the shared .claude/settings.json ONLY from the
# directory a session is started in (https://code.claude.com/docs/en/settings: "to use a
# file committed at the repository root, start Claude Code there"). A session started
# in a product subdirectory loads none of the project's deny rules. Observed
# 2026-09-22: TakeTwo's Goal Mode session, started in apps/backend, ran commands that
# its root live-spend deny rules exist to stop, with no rule denial.
#
# Offline, no API calls. Builds a scratch product layout (vendored framework + the
# root .claude symlink + apps/backend) and drives the REAL renderer.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1));
  else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}
# check_py <what> <args...> — runs the python program on stdin, which prints one
# "PASS|FAIL<TAB>label" line per check. A program that crashes (e.g. the file under
# test does not exist) is itself a failure, never a silently skipped check.
check_py() {
  local what="$1" verdict label out rc
  shift
  out="$(python3 - "$@" 2>&1)"; rc=$?
  if [[ $rc -ne 0 ]]; then
    assert "$what: the check itself failed (rc=$rc): $(printf '%s' "$out" | tail -n 1)" fail
    return
  fi
  while IFS=$'\t' read -r verdict label; do
    [[ -n "$verdict" ]] || continue
    if [[ "$verdict" == "PASS" ]]; then assert "$label" pass; else assert "$label" fail; fi
  done <<< "$out"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== test-claude-launch-dirs.sh =="

P="$WORK/product"
V="$P/incredible_auto_dev"
mkdir -p "$V/scripts/automation/lib" "$P/apps/backend"
for d in adapters agents skills hooks commands config policy .claude; do
  cp -r "$ENGINE_ROOT/$d" "$V/"
done
cp "$ENGINE_ROOT/scripts/automation/sync-cli-assets.py" "$V/scripts/automation/"
cp "$ENGINE_ROOT/scripts/automation/lib/agent_permissions.py" "$V/scripts/automation/lib/"
ln -s incredible_auto_dev/.claude "$P/.claude"
SYNC="$V/scripts/automation/sync-cli-assets.py"
POLICY="$V/policy/permissions.yaml"
ROOT_SETTINGS="$V/.claude/settings.json"
BE="$P/apps/backend/.claude/settings.json"
render() { python3 "$SYNC" --cli claude "$@"; }

# A product's own policy may already declare launch dirs; the scenarios below own
# the key, so start from a policy without it.
python3 - "$POLICY" <<'PY'
import sys, yaml
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().split("\n")
out, in_key = [], False
for ln in lines:
    if ln.startswith("claude_launch_dirs:"):
        in_key = True
        continue
    if in_key and ln.startswith("- "):
        continue
    in_key = False
    out.append(ln)
open(p, "w", encoding="utf-8").write("\n".join(out))
assert "claude_launch_dirs" not in (yaml.safe_load(open(p, encoding="utf-8")) or {})
PY
render >/dev/null 2>&1

echo "-- L0: nothing declared"
if render --check >/dev/null 2>&1; then assert "L0a the sandbox is drift-free with no launch dirs declared" pass
else assert "L0a the sandbox is drift-free with no launch dirs declared" fail; fi
if [[ ! -e "$BE" ]]; then assert "L0b nothing is rendered into apps/backend unless declared" pass
else assert "L0b apps/backend settings rendered without a declaration" fail; fi
cp "$ROOT_SETTINGS" "$WORK/root-before.json"

printf '\nclaude_launch_dirs:\n- apps/backend\n- apps/not-there\n' >> "$POLICY"

echo "-- L1: the drift check notices the missing file"
render --check > "$WORK/l1.out" 2>&1; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'claude/launch_dirs: would change 1' "$WORK/l1.out"; then
  assert "L1 --check fails and names claude/launch_dirs before the first render" pass
else assert "L1 --check did not flag the missing launch-dir settings (rc=$rc)" fail; fi

echo "-- L2: the render"
render > "$WORK/l2.out" 2>&1
if grep -q 'claude/launch_dirs: wrote 1' "$WORK/l2.out"; then assert "L2a the render writes exactly one launch-dir file" pass
else assert "L2a the render did not write one launch-dir file" fail; fi
check_py "L2b-e launch-dir file contents" "$BE" "$ROOT_SETTINGS" "$POLICY" <<'PY'
import json, sys, yaml
be = json.load(open(sys.argv[1], encoding="utf-8"))
root = json.load(open(sys.argv[2], encoding="utf-8"))
pol = yaml.safe_load(open(sys.argv[3], encoding="utf-8"))
def out(ok, label): print(("PASS" if ok else "FAIL") + "\t" + label)
out(be["permissions"]["deny"] == pol["deny"], "L2b the file carries the policy deny list verbatim, in order")
out(be["permissions"]["deny"] == root["permissions"]["deny"], "L2c it equals the root settings.json deny list")
out(set(be) == {"_comment", "permissions"} and set(be["permissions"]) == {"deny"},
    "L2d deny only: no allow rules, hooks or additional directories")
out("GENERATED" in be["_comment"] and "claude_launch_dirs" in be["_comment"],
    "L2e the file says it is generated, and from what")
PY
if [[ ! -e "$P/apps/not-there" ]]; then assert "L2f a declared directory that does not exist is skipped, not created" pass
else assert "L2f a missing declared directory was created" fail; fi
if cmp -s "$WORK/root-before.json" "$ROOT_SETTINGS"; then assert "L2g the root settings.json is unchanged by the declaration" pass
else assert "L2g the declaration changed the root settings.json" fail; fi

echo "-- L3: idempotence"
sha1="$(sha256sum "$BE" | cut -d' ' -f1)"
render > "$WORK/l3.out" 2>&1
sha2="$(sha256sum "$BE" | cut -d' ' -f1)"
if grep -q 'claude/launch_dirs: wrote 0' "$WORK/l3.out" && [[ "$sha1" == "$sha2" ]] && render --check >/dev/null 2>&1; then
  assert "L3 a second render writes nothing, the bytes are stable, --check is clean" pass
else assert "L3 the second render is not idempotent" fail; fi

echo "-- L4: a removed rule is drift and is restored"
python3 - "$BE" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
d["permissions"]["deny"].pop()
open(p, "w", encoding="utf-8").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PY
render --check > "$WORK/l4.out" 2>&1; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'claude/launch_dirs: would change 1' "$WORK/l4.out"; then
  assert "L4a --check flags a launch-dir file that lost one rule" pass
else assert "L4a a tampered launch-dir file was not flagged (rc=$rc)" fail; fi
render >/dev/null 2>&1
if [[ "$(sha256sum "$BE" | cut -d' ' -f1)" == "$sha1" ]]; then assert "L4b the render restores it byte-for-byte" pass
else assert "L4b the render did not restore the file" fail; fi

echo "-- L5: a deleted file is drift and is recreated"
rm -f "$BE"
if render --check >/dev/null 2>&1; then assert "L5a --check missed a deleted launch-dir file" fail
else assert "L5a --check flags a deleted launch-dir file" pass; fi
render >/dev/null 2>&1
if [[ -f "$BE" && "$(sha256sum "$BE" | cut -d' ' -f1)" == "$sha1" ]]; then assert "L5b the render recreates it identically" pass
else assert "L5b the deleted file was not recreated" fail; fi

echo "-- L6: the file follows the policy (it is not a snapshot)"
python3 - "$POLICY" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
anchor = "\nadditionalDirectories:"
assert s.count(anchor) == 1
s = s.replace(anchor, "\n- Bash(*launch-dir-policy-probe*)" + anchor)
open(p, "w", encoding="utf-8").write(s)
PY
if render --check >/dev/null 2>&1; then assert "L6a a new policy deny rule was not reported as drift" fail
else assert "L6a a new policy deny rule is reported as drift" pass; fi
render >/dev/null 2>&1
check_py "L6b policy change reaches both files" "$BE" "$ROOT_SETTINGS" <<'PY'
import json, sys
be = json.load(open(sys.argv[1], encoding="utf-8"))
root = json.load(open(sys.argv[2], encoding="utf-8"))
r = "Bash(*launch-dir-policy-probe*)"
ok = r in be["permissions"]["deny"] and r in root["permissions"]["deny"]
print(("PASS" if ok else "FAIL") + "\tL6b after one render the new rule is in BOTH the root and the launch-dir settings")
PY

echo "-- L7: entries that leave the project are rejected"
for bad in "../escape" "/tmp/abs-launch-dir"; do
  cp "$POLICY" "$WORK/policy.bak"
  python3 - "$POLICY" "$bad" <<'PY'
import sys
p, bad = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
old = "claude_launch_dirs:\n- apps/backend\n"
assert s.count(old) == 1
s = s.replace(old, "claude_launch_dirs:\n- " + bad + "\n")
open(p, "w", encoding="utf-8").write(s)
PY
  render > "$WORK/l7.out" 2>&1; rc=$?
  if [[ $rc -ne 0 ]] && grep -q 'must be a subdirectory of the project root' "$WORK/l7.out"; then
    assert "L7 '$bad' is refused with a named error" pass
  else assert "L7 '$bad' was accepted (rc=$rc)" fail; fi
  cp "$WORK/policy.bak" "$POLICY"
done

echo "-- L8: the tree under test"
python3 "$ENGINE_ROOT/scripts/automation/sync-cli-assets.py" --cli claude --check > "$WORK/l8.out" 2>&1; rc=$?
if [[ $rc -eq 0 ]] && grep -q 'claude/launch_dirs: would change 0' "$WORK/l8.out"; then
  assert "L8 the tree under test reports the launch_dirs category and has no launch-dir drift" pass
else assert "L8 launch-dir drift in the tree under test (rc=$rc)" fail; fi

echo
echo "== summary: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
