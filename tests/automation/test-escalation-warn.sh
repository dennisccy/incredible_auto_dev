#!/usr/bin/env bash
# test-escalation-warn.sh — CTX-13: escalate_model_on must fail LOUD when
# strong-tier resolution errors. Previously an empty resolution was a silent
# no-op: the fix-mode retry ran on the agent's default tier while the logs
# claimed nothing (violates the repo's fail-loud doctrine).
#
# Contract under test (lib/common.sh escalate_model_on):
#   • resolution succeeds → CHAIN_MODEL_OVERRIDE exported, "[escalation] retry
#     runs on the strong tier: <model>" printed, NO warning;
#   • resolution fails (empty output) → NO override exported, a WARNING naming
#     the fallback-to-default-tier consequence printed to stderr;
#   • both paths return 0 (escalation must never fail the caller).
#
# No API calls; runs in well under a second.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

echo ""
echo "=== escalation fail-loud (CTX-13) ==="

# ── 1. Success path: override exported, no WARNING ───────────────────────────
out=$(cd "$REPO_ROOT" && bash -c '
  source scripts/automation/lib/common.sh
  escalate_model_on 2>&1
  echo "OVERRIDE=${CHAIN_MODEL_OVERRIDE:-unset}"
') || true
if [[ "$out" == *"[escalation] retry runs on the strong tier:"* \
      && "$out" != *"WARNING"* && "$out" != *"OVERRIDE=unset"* ]]; then
  pass "success path: override exported, no warning"
else
  fail "success path unexpected output: $out"
fi

# ── 2. Failure path: PATH-shadowed python3 → WARNING, no override, rc 0 ──────
shadow=$(mktemp -d)
trap 'rm -rf "$shadow"' EXIT
printf '#!/usr/bin/env bash\nexit 1\n' > "$shadow/python3"
chmod +x "$shadow/python3"

out=$(cd "$REPO_ROOT" && PATH="$shadow:$PATH" bash -c '
  source scripts/automation/lib/common.sh
  escalate_model_on 2>&1
  rc=$?
  echo "RC=$rc"
  echo "OVERRIDE=${CHAIN_MODEL_OVERRIDE:-unset}"
') || true
if [[ "$out" == *"WARNING: strong-tier model resolution FAILED"* ]]; then
  pass "failure path: loud warning printed"
else
  fail "failure path: no warning (got: $out)"
fi
if [[ "$out" == *"RC=0"* && "$out" == *"OVERRIDE=unset"* ]]; then
  pass "failure path: rc 0 and no override exported"
else
  fail "failure path: wrong rc/override state (got: $out)"
fi

# ── 3. Disabled path: CHAIN_MODEL_ESCALATION=false → silent no-op ────────────
out=$(cd "$REPO_ROOT" && CHAIN_MODEL_ESCALATION=false bash -c '
  source scripts/automation/lib/common.sh
  escalate_model_on 2>&1
  echo "OVERRIDE=${CHAIN_MODEL_OVERRIDE:-unset}"
') || true
if [[ "$out" == "OVERRIDE=unset" ]]; then
  pass "disabled path: silent no-op"
else
  fail "disabled path produced output: $out"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo ""

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
