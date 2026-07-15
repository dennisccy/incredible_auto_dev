#!/usr/bin/env bash
# install-security-gate.sh — Pre-install supply-chain security hook
#
# Claude Code PreToolUse hook for the Bash tool.
# Intercepts install commands before execution, evaluates them against
# the repo security policy, and blocks/warns/requires approval as appropriate.
#
# Two input/output modes (SEC-7):
#   argv mode  — command passed as $1 (test harness, run-evals 2d, Codex).
#     Output contract unchanged: banners on stdout; exit 0 = allow/warn,
#     exit 1 = block/require_approval.
#   stdin mode — the Claude Code PreToolUse protocol: JSON payload on stdin,
#     command at .tool_input.command ($CLAUDE_TOOL_INPUT_COMMAND never existed;
#     exit 1 is a NON-blocking hook error on Claude). The decision travels as
#     hookSpecificOutput JSON on stdout with exit 0: block/require_approval →
#     permissionDecision "deny" with the remediation as the reason (the AGENT
#     reads it and adapts — never a user prompt); warn → banner on stderr,
#     stdout stays empty. Invariant: stdout in stdin mode is either empty or
#     exactly one JSON object.
#
# Fail-open on missing/unparseable input: this is a SECONDARY layer (the
# settings permissions deny list is primary); availability beats strictness —
# a broken hook must never stall the pipeline, and a parse failure means we
# cannot even name the command we would be blocking.
#
# To bypass in an emergency:
#   export CHAIN_INSTALL_GATE_BYPASS=true
# Then re-run the operation. Unset afterwards.

set -euo pipefail

COMMAND="${1:-}"
INPUT_MODE="argv"
if [[ -z "$COMMAND" && ! -t 0 ]]; then
  _payload=$(cat 2>/dev/null || true)
  if [[ -n "$_payload" ]]; then
    if command -v jq >/dev/null 2>&1; then
      COMMAND=$(printf '%s' "$_payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || COMMAND=""
    else
      COMMAND=$(printf '%s' "$_payload" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command") or "")' 2>/dev/null) || COMMAND=""
    fi
    if [[ -n "$COMMAND" ]]; then INPUT_MODE="stdin"; fi
  fi
fi
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE_SCRIPT="$REPO_ROOT/scripts/automation/lib/install-gate.py"
POLICY_FILE="$REPO_ROOT/config/install-security-policy.json"

# ── Fast path: skip non-install commands immediately ─────────────────────────
# The curl|shell alternation runs against a QUOTE-STRIPPED view: a command that
# merely quotes a "curl … | bash" string (test fixtures, echo, commit messages)
# is not an executable pipe. install-gate.py applies the same rule.
STRIPPED=$(printf '%s' "$COMMAND" | sed -E "s/'[^']*'//g" | sed -E 's/"[^"]*"//g') || STRIPPED="$COMMAND"
if ! echo "$COMMAND" | grep -qiE \
    "(pip3?\s+install|pip3?install|uv\s+pip\s+install|uv\s+add|\.venv/bin/pip|npm\s+(install|i|ci|add)|git\s+clone)" \
   && ! echo "$STRIPPED" | grep -qiE "(curl|wget)\s+.*\|.*(bash|sh)"; then
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

# ── Decision output helpers ───────────────────────────────────────────────────
_emit_deny_json() {  # $1 = permissionDecisionReason (jq/json.dumps handle escaping)
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  else
    python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":sys.argv[1]}}, separators=(",",":")))' "$1"
  fi
}

_warn_banner() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║  [install-gate] SECURITY WARNING                         ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo "  Command: $COMMAND"
  echo "  Warning: $REASON"
  echo ""
}

_block_banner() {
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
}

_approval_banner() {
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
}

# ── Act on decision ───────────────────────────────────────────────────────────
case "$DECISION" in
  allow)
    exit 0
    ;;

  warn)
    # stdin (Claude) mode reserves stdout for decision JSON — the warn banner
    # goes to stderr (debug logs); the durable record is the decisions JSONL.
    if [[ "$INPUT_MODE" == "stdin" ]]; then _warn_banner >&2; else _warn_banner; fi
    exit 0
    ;;

  block)
    if [[ "$INPUT_MODE" == "stdin" ]]; then
      _block_banner >&2
      _emit_deny_json "[install-gate] BLOCKED — supply-chain security policy. Command: $COMMAND. Reason: $REASON Fix: install from the package registry with a pinned version (pkg==X.Y.Z), or add the package to the allowlist in config/install-security-policy.json. Emergency bypass: export CHAIN_INSTALL_GATE_BYPASS=true, re-run, then unset it."
      exit 0
    fi
    _block_banner
    exit 1
    ;;

  require_approval)
    if [[ "$INPUT_MODE" == "stdin" ]]; then
      _approval_banner >&2
      _emit_deny_json "[install-gate] APPROVAL REQUIRED by supply-chain policy. Command: $COMMAND. Reason: $REASON Options: (1) pin the version or add the package to the allowlist in config/install-security-policy.json; (2) emergency bypass: export CHAIN_INSTALL_GATE_BYPASS=true, re-run, then unset it."
      exit 0
    fi
    _approval_banner
    exit 1
    ;;

  *)
    exit 0
    ;;
esac
