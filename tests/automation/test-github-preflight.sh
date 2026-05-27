#!/usr/bin/env bash
# test-github-preflight.sh — Unit tests for check_git_push_access() in
# scripts/automation/lib/common.sh
#
# Usage: ./tests/automation/test-github-preflight.sh
#
# Verifies the GitHub push-access preflight: it distinguishes "no origin"
# (rc=2) from "auth/network failure" (rc=1+), passes against a reachable
# remote, and — most importantly — NEVER hangs on a credential prompt
# (GIT_TERMINAL_PROMPT=0). Uses local file:// bare repos and a reserved-TLD
# URL, so it needs no network and no credentials.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source common.sh (defines functions; does not execute a pipeline)
source "$REPO_ROOT/scripts/automation/lib/common.sh"

PASS=0
FAIL=0
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

assert() {
  local label="$1"
  local result="$2"   # "pass" or "fail"
  if [[ "$result" == "pass" ]]; then
    echo "  PASS  $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $label"
    FAIL=$((FAIL + 1))
  fi
}

# A work repo with a single commit.
WORK="$TMP_DIR/work"
git init -q "$WORK"
git -C "$WORK" config user.email test@example.com
git -C "$WORK" config user.name "Test"
git -C "$WORK" commit -q --allow-empty -m init

echo ""
echo "=== check_git_push_access tests ==="
echo ""

# 1. No origin remote → rc 2
rc=0; check_git_push_access "$WORK" || rc=$?
[[ $rc -eq 2 ]] && assert "no origin remote returns 2" "pass" \
                || assert "no origin remote returns 2 (got $rc)" "fail"

# 2. Reachable local bare remote → rc 0 (success path; offline, no creds)
BARE="$TMP_DIR/remote.git"
git init -q --bare "$BARE"
git -C "$WORK" remote add origin "file://$BARE"
rc=0; check_git_push_access "$WORK" || rc=$?
[[ $rc -eq 0 ]] && assert "reachable origin returns 0" "pass" \
                || assert "reachable origin returns 0 (got $rc)" "fail"

# 3. Bogus HTTPS remote → non-zero (NOT 2), and fails fast with no hang.
#    'invalid.invalid' is a reserved non-resolvable TLD (RFC 6761), so DNS
#    fails immediately; GIT_TERMINAL_PROMPT=0 guarantees no credential prompt.
git -C "$WORK" remote set-url origin "https://invalid.invalid/x.git"
start=$SECONDS
rc=0; check_git_push_access "$WORK" || rc=$?
elapsed=$((SECONDS - start))
{ [[ $rc -ne 0 && $rc -ne 2 ]]; } \
  && assert "bogus remote returns auth/network failure (not 2)" "pass" \
  || assert "bogus remote returns auth/network failure (not 2) (got $rc)" "fail"
[[ $elapsed -lt 25 ]] \
  && assert "bogus remote fails fast (${elapsed}s, no credential-prompt hang)" "pass" \
  || assert "bogus remote hung (${elapsed}s)" "fail"

# ── Integration: the real preflight_github_access() from run-goal.sh ────────
# Extract and source the ACTUAL shipped function (not a copy) so this test
# tracks the real code. Every call redirects </dev/null so the interactive
# `gh auth login` branch (guarded by `-t 0`) is never reached in tests.
echo ""
echo "=== preflight_github_access() tests ==="
echo ""

FN_FILE="$TMP_DIR/preflight_fn.sh"
awk '/^preflight_github_access\(\) \{/{f=1} f{print} f&&/^\}/{exit}' \
  "$REPO_ROOT/scripts/automation/run-goal.sh" > "$FN_FILE"
record_telemetry_event() { :; }   # stub: no telemetry in tests
# shellcheck disable=SC1090
source "$FN_FILE"

SESSION_ID="gh-preflight-test"
SESSION_JSON="$TMP_DIR/session.json"
make_session_json() { printf '{"session_id":"%s","status":"in_progress"}\n' "$SESSION_ID" > "$SESSION_JSON"; }
session_status() { python3 -c "import json; print(json.load(open('$SESSION_JSON'))['status'])"; }

# A) Neither push-per-iter nor auto-release → skip entirely (no session change)
make_session_json
PUSH_PER_ITER=false; AUTO_RELEASE=false; REPO_ROOT="$WORK"; CHAIN_SKIP_GITHUB_PREFLIGHT=false
rc=0; out=$( ( preflight_github_access ) </dev/null 2>&1 ) || rc=$?
{ [[ $rc -eq 0 && "$(session_status)" == "in_progress" ]]; } \
  && assert "skips when push-per-iter + auto-release both off" "pass" \
  || assert "skips when not pushing (rc=$rc status=$(session_status))" "fail"

# B) Escape hatch CHAIN_SKIP_GITHUB_PREFLIGHT=true → skip even with push on
make_session_json
PUSH_PER_ITER=true; AUTO_RELEASE=false; REPO_ROOT="$WORK"; CHAIN_SKIP_GITHUB_PREFLIGHT=true
rc=0; out=$( ( preflight_github_access ) </dev/null 2>&1 ) || rc=$?
{ [[ $rc -eq 0 && "$out" == *"CHAIN_SKIP_GITHUB_PREFLIGHT"* && "$(session_status)" == "in_progress" ]]; } \
  && assert "CHAIN_SKIP_GITHUB_PREFLIGHT=true bypasses the check" "pass" \
  || assert "escape hatch (rc=$rc)" "fail"
CHAIN_SKIP_GITHUB_PREFLIGHT=false

# C) Reachable origin + push on → prints OK, returns 0, no pause
make_session_json
git -C "$WORK" remote set-url origin "file://$BARE"
PUSH_PER_ITER=true; AUTO_RELEASE=false; REPO_ROOT="$WORK"
rc=0; out=$( ( preflight_github_access ) </dev/null 2>&1 ) || rc=$?
{ [[ $rc -eq 0 && "$out" == *"GitHub push access: OK"* && "$(session_status)" == "in_progress" ]]; } \
  && assert "reachable origin → OK, no pause" "pass" \
  || assert "reachable origin (rc=$rc status=$(session_status))" "fail"

# D) Bogus origin, non-interactive → pause AWAITING_GITHUB_AUTH, exit 0
make_session_json
git -C "$WORK" remote set-url origin "https://invalid.invalid/x.git"
PUSH_PER_ITER=true; AUTO_RELEASE=false; REPO_ROOT="$WORK"
rc=0; out=$( ( preflight_github_access ) </dev/null 2>&1 ) || rc=$?
[[ $rc -eq 0 ]] \
  && assert "bogus origin pauses with exit 0 (no abort, no hang)" "pass" \
  || assert "bogus origin exit code (got $rc)" "fail"
[[ "$(session_status)" == "AWAITING_GITHUB_AUTH" ]] \
  && assert "bogus origin sets status AWAITING_GITHUB_AUTH" "pass" \
  || assert "bogus origin status (got $(session_status))" "fail"
{ [[ "$out" == *"Resume:"* && "$out" == *"--resume"* ]]; } \
  && assert "pause message prints the resume command" "pass" \
  || assert "pause message missing resume command" "fail"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo ""

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
