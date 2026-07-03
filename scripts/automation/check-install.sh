#!/usr/bin/env bash
# check-install.sh — CLI wrapper for the install security gate
# Usage: ./scripts/automation/check-install.sh "pip install requests==2.31.0"
#
# Evaluates a hypothetical install command against the security policy
# without actually running it. Useful for checking before adding to CI.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

COMMAND="${1:-}"
if [[ -z "$COMMAND" ]]; then
  echo "Usage: $0 \"<install command>\"" >&2
  echo "  Example: $0 \"pip install requests==2.31.0\"" >&2
  exit 1
fi

GATE_SCRIPT="$REPO_ROOT/scripts/automation/lib/install-gate.py"
POLICY_FILE="$REPO_ROOT/config/install-security-policy.json"

if [[ ! -f "$GATE_SCRIPT" ]]; then
  echo "Error: install-gate.py not found at $GATE_SCRIPT" >&2
  exit 1
fi

echo "Evaluating: $COMMAND"
echo ""

python3 "$GATE_SCRIPT" \
  --command "$COMMAND" \
  --policy "$POLICY_FILE" \
  --repo-root "$REPO_ROOT" \
  --dry-run \
  2>&1 | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    decision = data.get('decision', 'unknown')
    reason = data.get('reason', '')
    packages = data.get('packages', [])
    print(f'Decision:  {decision.upper()}')
    print(f'Reason:    {reason}')
    if packages:
        print(f'Packages:  {[p.get(\"name\") for p in packages]}')
except Exception as e:
    print(f'Could not parse result: {e}')
"
