#!/usr/bin/env bash
# run-evals.sh — Offline eval suite for the harness itself.
#
# Runs all the cheap, fast, deterministic checks that detect harness drift
# without spending API credits:
#
#   - bash syntax check on every script in scripts/automation/
#   - python self-tests on every lib module that has one
#   - agent frontmatter validation (required fields, model whitelist, etc.)
#   - artifact-schema CLI sanity check
#   - hook script smoke check (well-formed and malformed inputs)
#
# Designed to run in <30 seconds and exit non-zero on the first failure of any
# class. Use as a CI gate on PRs — if this fails, the harness is in a bad
# state and downstream pipelines will fail in confusing ways.
#
# Usage:
#   ./scripts/automation/run-evals.sh             # run everything, fail on first issue
#   ./scripts/automation/run-evals.sh --verbose   # print per-check progress
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

VERBOSE=false
[[ "${1:-}" == "--verbose" ]] && VERBOSE=true

PASSES=0
FAILS=0
FAILED_CHECKS=()

_log() { echo "[evals] $*"; }
_pass() { PASSES=$((PASSES+1)); $VERBOSE && _log "  PASS: $*"; return 0; }
_fail() { FAILS=$((FAILS+1)); FAILED_CHECKS+=("$1"); _log "  FAIL: $*"; return 0; }

_log "Running offline eval suite from $REPO_ROOT"

# ── 1. Bash syntax checks ────────────────────────────────────────────────────
_log "1. bash syntax checks"
for script in scripts/automation/*.sh scripts/automation/lib/*.sh .claude/hooks/*.sh; do
  [[ -f "$script" ]] || continue
  if bash -n "$script" 2>/dev/null; then
    _pass "syntax: $script"
  else
    _fail "syntax: $script (run 'bash -n $script' to see the error)"
  fi
done

# ── 2. Python self-tests for lib modules ─────────────────────────────────────
_log "2. python self-tests"

_run_self_test() {
  local module="$1"
  local args="${2:-self-test}"
  if [[ ! -f "$module" ]]; then
    _fail "self-test: $module not found"
    return
  fi
  local out
  if out=$(python3 "$module" $args 2>&1); then
    _pass "self-test: $module"
  else
    _fail "self-test: $module (output: $(echo "$out" | head -3 | tr '\n' ' '))"
  fi
}

_run_self_test scripts/automation/lib/artifact_schemas.py self-test
_run_self_test scripts/automation/lib/analyze_telemetry.py --self-test
_run_self_test scripts/automation/lib/replay_trace.py self-test
_run_self_test scripts/automation/lib/agent_permissions.py self-test
_run_self_test scripts/automation/lib/render_iteration_summary.py self-test
_run_self_test scripts/automation/lib/demo_runner.py self-test

# Telemetry has its own test mode (sourced + invoked with "test" arg)
if bash scripts/automation/lib/telemetry.sh test >/dev/null 2>&1; then
  _pass "self-test: telemetry.sh test"
else
  _fail "self-test: telemetry.sh test"
fi

# ── 3. Agent frontmatter validation ──────────────────────────────────────────
_log "3. agent frontmatter validation"
if python3 scripts/automation/lib/validate_agents.py >/dev/null 2>&1; then
  _pass "agents: all *.md files in .claude/agents/ have valid frontmatter"
else
  python3 scripts/automation/lib/validate_agents.py
  _fail "agents: validate_agents.py reported issues"
fi

# ── 3b. Skill drift validation ───────────────────────────────────────────────
_log "3b. skill drift validation"
_run_self_test scripts/automation/lib/validate_skills.py --self-test
if python3 scripts/automation/lib/validate_skills.py >/dev/null 2>&1; then
  _pass "skills: all *.md files in .claude/skills/ are well-formed"
else
  python3 scripts/automation/lib/validate_skills.py
  _fail "skills: validate_skills.py reported issues"
fi

# ── 4. verdicts.py CLI sanity ────────────────────────────────────────────────
_log "4. verdicts.py CLI"
if python3 scripts/automation/lib/verdicts.py passing-verdicts >/dev/null 2>&1 \
  && python3 scripts/automation/lib/verdicts.py all-verdicts >/dev/null 2>&1 \
  && python3 scripts/automation/lib/verdicts.py validate-status in_progress >/dev/null 2>&1 \
  && python3 scripts/automation/lib/verdicts.py validate-step planned >/dev/null 2>&1; then
  _pass "verdicts.py CLI commands work"
else
  _fail "verdicts.py CLI (run python3 scripts/automation/lib/verdicts.py to debug)"
fi

# Negative case
if python3 scripts/automation/lib/verdicts.py validate-status definitely_invalid >/dev/null 2>&1; then
  _fail "verdicts.py accepted an invalid status (negative case failed)"
else
  _pass "verdicts.py rejects invalid status"
fi

# ── 5. Hook integration: artifact quality + schema ───────────────────────────
_log "5. post-write-artifact-quality.sh smoke checks"

# Well-formed review → silent pass (no warnings on stderr)
tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/reports/reviews"
cat > "$tmpdir/reports/reviews/eval-good-review.md" <<'EOF'
# Code Review

## Verdict

**Verdict:** PASS

## Findings

None.
EOF
out=$(bash .claude/hooks/post-write-artifact-quality.sh \
  "$tmpdir/reports/reviews/eval-good-review.md" 2>&1)
if [[ -z "$out" ]]; then
  _pass "hook: well-formed review is silent"
else
  _fail "hook: well-formed review produced output: $out"
fi

# Malformed review → must surface schema warning
cat > "$tmpdir/reports/reviews/eval-bad-review.md" <<'EOF'
# Review with no verdict
EOF
out=$(bash .claude/hooks/post-write-artifact-quality.sh \
  "$tmpdir/reports/reviews/eval-bad-review.md" 2>&1 || true)
if [[ "$out" == *"missing or invalid verdict"* ]]; then
  _pass "hook: malformed review surfaces schema warning"
else
  _fail "hook: malformed review did not surface warning (got: $out)"
fi
rm -rf "$tmpdir"

# ── 6. Stream-renderer fixture roundtrip ─────────────────────────────────────
_log "6. claude_stream_renderer.py fixture"
sidecar=$(mktemp)
out=$(printf '%s\n' \
  '{"type":"system","subtype":"init","model":"x","session_id":"abc"}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}' \
  '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"num_turns":1,"total_cost_usd":0.001,"session_id":"abc","usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":50,"cache_creation_input_tokens":0}}' \
  | CHAIN_CLAUDE_USAGE_SIDECAR="$sidecar" python3 scripts/automation/lib/claude_stream_renderer.py 2>&1)
if [[ -s "$sidecar" ]] && python3 -c "import json; d=json.load(open('$sidecar')); assert d['usage']['input_tokens']==10" 2>/dev/null; then
  _pass "renderer: stream-json fixture writes correct sidecar"
else
  _fail "renderer: stream-json fixture failed (out: $out)"
fi
rm -f "$sidecar"

# ── Summary ──────────────────────────────────────────────────────────────────
echo
_log "Summary: ${PASSES} pass, ${FAILS} fail"

if [[ "$FAILS" -gt 0 ]]; then
  echo
  _log "Failed checks:"
  for c in "${FAILED_CHECKS[@]}"; do
    _log "  - $c"
  done
  exit 1
fi

_log "All offline evals passed."
exit 0
