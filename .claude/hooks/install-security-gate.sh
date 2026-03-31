#!/usr/bin/env bash
# install-security-gate.sh — Pre-install supply-chain security hook
#
# Claude Code PreToolUse hook for the Bash tool.
# Intercepts install commands before execution, evaluates them against
# the repo security policy, and blocks/warns/requires approval as appropriate.
#
# Usage (invoked by Claude Code):
#   bash .claude/hooks/install-security-gate.sh "$CLAUDE_TOOL_INPUT_COMMAND"
#
# Exit codes:
#   0  Allow / warn (proceed)
#   1  Block / require approval (command will not execute)
#
# To bypass in an emergency:
#   export CHAIN_INSTALL_GATE_BYPASS=true
# Then re-run the operation. Unset afterwards.

set -euo pipefail

COMMAND="${1:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE_SCRIPT="$REPO_ROOT/scripts/automation/lib/install-gate.py"
POLICY_FILE="$REPO_ROOT/config/install-security-policy.json"

# ── Fast path: skip non-install commands immediately ─────────────────────────
if ! echo "$COMMAND" | grep -qiE \
    "(pip3?\s+install|pip3?install|uv\s+pip\s+install|uv\s+add|\.venv/bin/pip|npm\s+(install|i|ci|add)|git\s+clone|(curl|wget)\s+.*\|.*(bash|sh))"; then
  exit 0
fi

# ── Infrastructure failure guard ─────────────────────────────────────────────
if [[ ! -f "$GATE_SCRIPT" ]]; then
  echo "[install-gate] WARNING: Gate script not found at $GATE_SCRIPT — skipping enforcement." >&2
  exit 0
fi
if [[ ! -f "$POLICY_FILE" ]]; then
  echo "[install-gate] WARNING: Policy file not found at $POLICY_FILE — skipping enforcement." >&2
  exit 0
fi

# ── Bypass check ──────────────────────────────────────────────────────────────
if [[ "${CHAIN_INSTALL_GATE_BYPASS:-false}" == "true" || "${CHAIN_INSTALL_GATE_BYPASS:-false}" == "1" ]]; then
  echo "[install-gate] Bypass active (CHAIN_INSTALL_GATE_BYPASS=true). Skipping checks." >&2
  exit 0
fi

# ── Run policy engine ─────────────────────────────────────────────────────────
RESULT_JSON=""
GATE_EXIT=0
RESULT_JSON=$(python3 "$GATE_SCRIPT" \
  --command "$COMMAND" \
  --policy "$POLICY_FILE" \
  --repo-root "$REPO_ROOT" \
  2>/dev/null) || GATE_EXIT=$?

# If the Python script itself failed unexpectedly, fail-open.
if [[ $GATE_EXIT -gt 2 ]]; then
  echo "[install-gate] WARNING: Gate script error (exit $GATE_EXIT) — skipping enforcement." >&2
  exit 0
fi

if [[ -z "$RESULT_JSON" ]]; then
  exit 0
fi

DECISION=$(echo "$RESULT_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('decision','allow'))" 2>/dev/null || echo "allow")
REASON=$(echo "$RESULT_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('reason',''))" 2>/dev/null || echo "")

# ── Act on decision ───────────────────────────────────────────────────────────
case "$DECISION" in
  allow)
    exit 0
    ;;

  warn)
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  [install-gate] SECURITY WARNING                         ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo "  Command: $COMMAND"
    echo "  Warning: $REASON"
    echo ""
    exit 0
    ;;

  block)
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  [install-gate] BLOCKED — SUPPLY CHAIN SECURITY POLICY  ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo "  Command:  $COMMAND"
    echo "  Reason:   $REASON"
    echo ""
    echo "  This command is blocked by the install security policy."
    echo "  Review config/install-security-policy.json to understand"
    echo "  the policy, or contact the repository maintainer."
    echo ""
    exit 1
    ;;

  require_approval)
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  [install-gate] APPROVAL REQUIRED                        ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo "  Command:  $COMMAND"
    echo "  Reason:   $REASON"
    echo ""
    echo "  Options:"
    echo "    1. Pin the version or add the package to the allowlist:"
    echo "       config/install-security-policy.json"
    echo "    2. Emergency bypass (use with care):"
    echo "       export CHAIN_INSTALL_GATE_BYPASS=true"
    echo "       # re-run your command"
    echo "       unset CHAIN_INSTALL_GATE_BYPASS"
    echo ""
    exit 1
    ;;

  *)
    exit 0
    ;;
esac
