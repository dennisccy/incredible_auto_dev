#!/usr/bin/env bash
# test-goal-file-immutability.sh — docs/goal.md is human-owned.
#
# The goal-proposer (the only automated writer of docs/goal.md) was retired on
# 2026-09-01 together with the whole goal-mode M3 runtime invocation in
# run-goal.sh. This guard keeps it that way:
#   1. no live surface references the retired agent, skill or template
#      (historical evidence in the roadmap/archive/benchmarks is exempt);
#   2. no automation script writes the goal file;
#   3. run-goal.sh no longer invokes run_project_hook, while the GENERIC
#      project-hook API in lib/project-gates.sh stays intact (it is a reusable
#      extension mechanism, retired only from the goal-mode runtime path);
#   4. rendered mirrors are in sync with the neutral source;
#   5. the project-gates self-test is still green.
# Offline, API-free.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
PASS=0; FAIL=0
assert() { if [[ "$2" == pass ]]; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi; }

hits="$(grep -rn "goal-proposer\|goal-self-extension\|proposer-guidance" \
  agents skills commands scripts hooks policy config templates \
  CLAUDE.md README.md .claude/architecture .claude/model-orchestration.md docs/goal-mode-*.md 2>/dev/null || true)"
if [[ -z "$hits" ]]; then assert "no live reference to the retired goal-proposer" pass
else echo "$hits" | head -8; assert "no live reference to the retired goal-proposer" fail; fi

writes="$(grep -rnE --include='*.sh' '((>>?|tee( -a)?)[[:space:]]*"?\$?\{?GOAL_FILE\b|(>>?|tee( -a)?)[[:space:]]*"?docs/goal\.md|sed -i[^|;&]*(\$\{?GOAL_FILE|docs/goal\.md))' scripts/automation 2>/dev/null || true)"
if [[ -z "$writes" ]]; then assert "no automation script writes docs/goal.md" pass
else echo "$writes" | head -8; assert "no automation script writes docs/goal.md" fail; fi

grep -q 'run_project_hook' scripts/automation/run-goal.sh \
  && assert "run-goal.sh no longer invokes run_project_hook (M3 runtime path removed)" fail \
  || assert "run-goal.sh no longer invokes run_project_hook (M3 runtime path removed)" pass
grep -q '^run_project_hook()' scripts/automation/lib/project-gates.sh \
  && assert "generic run_project_hook API retained in lib/project-gates.sh" pass \
  || assert "generic run_project_hook API retained in lib/project-gates.sh" fail

python3 scripts/automation/sync-cli-assets.py --cli claude --check >/dev/null 2>&1 \
  && assert "claude mirrors in sync with the neutral source" pass \
  || assert "claude mirrors in sync with the neutral source" fail

bash scripts/automation/lib/project-gates.sh self-test >/dev/null 2>&1 \
  && assert "project-gates.sh self-test green (hook API intact)" pass \
  || assert "project-gates.sh self-test green (hook API intact)" fail

echo "  PASS: $PASS   FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
