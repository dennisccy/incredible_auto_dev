#!/usr/bin/env bash
# test-closure-gate.sh — SPEED-17 unit test: deterministic phase-closure gate.
#
# Logic under test:
#   scripts/automation/lib/closure_gate.py  <phase> --repo-root <path>
#     -> mechanizes the phase-closure-auditor's Steps 1-4 (verdict presence,
#        UI artifact existence/content, cross-consistency, objective vagueness)
#        and writes reports/phase-<phase>-closure-verdict.md in the frozen
#        format (first line `**Verdict:** CLOSURE-PASS|CLOSURE-FAIL`) that
#        closure_verdict_passes (lib/common.sh) greps.
#
# Wiring greps:
#   - phase-closure-check.sh default path invokes closure_gate.py (no LLM),
#     with a loud deterministic-gate line.
#   - CHAIN_CLOSURE_LLM=true routes to the preserved agent-dispatch branch,
#     still wrapped in record_agent_invocation_start/end telemetry.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="$ENGINE_ROOT/scripts/automation/lib/closure_gate.py"
CHECK_SH="$ENGINE_ROOT/scripts/automation/phase-closure-check.sh"

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# closure_verdict_passes comes from the real lib so the frozen-format claim is
# tested against the actual consumer, not a re-implementation of its grep.
source "$ENGINE_ROOT/scripts/automation/lib/common.sh"

# ── fixture builder ───────────────────────────────────────────────────────────
# make_fixture <root> <frontend yes|no> — builds a complete happy tree.
make_fixture() {
  local root="$1" frontend="$2" p=p1
  rm -rf "$root"
  mkdir -p "$root/runs/$p" "$root/reports/reviews" "$root/reports/qa" "$root/docs/handoffs"
  printf '# Plan\n\nFrontend Present: %s\n' "$frontend" > "$root/runs/$p/plan.md"
  printf '**Verdict:** PASS\n' > "$root/reports/reviews/$p-review.md"
  printf '**Verdict:** PASS\n' > "$root/reports/qa/$p-qa.md"
  printf '**Verdict:** PASS_WITH_GAPS\n' > "$root/docs/handoffs/$p-audit.md"

  local rich=""
  for i in 1 2 3 4 5 6 7 8; do rich+="- content line $i with real substance"$'\n'; done

  if [[ "$frontend" == "yes" ]]; then
    for a in implementation-summary user-visible-changes ui-surface-map ui-test-plan; do
      printf '# Phase %s — %s\n\n%s' "$p" "$a" "$rich" > "$root/reports/phase-$p-$a.md"
    done
    printf '| Route | Component |\n|---|---|\n| /items | ItemList |\n%s' "$rich" \
      >> "$root/reports/phase-$p-ui-surface-map.md"
    cat > "$root/reports/phase-$p-what-to-click.md" <<'EOF'
# What to Click

- Prerequisite: frontend running at http://localhost:3000
- Prerequisite: at least one seed item exists
- Steps below cover the new create flow end to end
- Each step lists the exact expected outcome
- Time required: about 5 minutes
- Written by fixture

1. Open `http://localhost:3000` — **Expect:** dashboard loads without errors
2. Click the "New Item" button — **Expect:** the create form modal opens
3. Fill "Name" with "demo-1" and submit — **Expect:** row "demo-1" appears
EOF
    cat > "$root/reports/phase-$p-ui-test-results.md" <<'EOF'
# UI Test Results

**Browser QA Verdict:** PASS

**Overall:** 1/1 tests passed (0 skipped)

| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |
|---|---|---|---|---|---|---|---|
| UT-01 | Create item | smoke | P1 | row appears | row appeared | PASS | a.png |

## Environment

- Browser: Chromium
- Test Date: fixture
EOF
  else
    # Mirror write_na_ui_artifacts stubs (lib/common.sh).
    printf '# Phase %s — Implementation Summary\n\n**Status:** Backend-only phase (Frontend Present: no)\n\nNo UI-visible implementation. All changes are internal backend.\n' "$p" > "$root/reports/phase-$p-implementation-summary.md"
    printf '# Phase %s — User-Visible Changes\n\n**Status:** N/A — Backend-only phase (Frontend Present: no)\n\nNo user-visible changes. All changes are internal backend implementation.\n' "$p" > "$root/reports/phase-$p-user-visible-changes.md"
    printf '# Phase %s — UI Surface Map\n\n**Status:** N/A — Backend-only phase (Frontend Present: no)\n\nNo UI surfaces affected.\n' "$p" > "$root/reports/phase-$p-ui-surface-map.md"
    printf '# Phase %s — UI Test Plan\n\n**Status:** N/A — Backend-only phase. No UI tests required.\n' "$p" > "$root/reports/phase-$p-ui-test-plan.md"
    printf '# Phase %s — UI Test Results\n\n**Browser QA Verdict:** SKIPPED\n\n**Reason:** Backend-only phase (Frontend Present: no). No browser tests executed.\n' "$p" > "$root/reports/phase-$p-ui-test-results.md"
    printf '# Phase %s — What to Click\n\n**Status:** N/A — Backend-only phase. No UI verification steps.\n' "$p" > "$root/reports/phase-$p-what-to-click.md"
  fi
}

run_gate() {  # run_gate <root>; echoes exit code
  local rc=0
  python3 "$GATE" p1 --repo-root "$1" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

VERDICT_FILE() { echo "$1/reports/phase-p1-closure-verdict.md"; }

# ── (0) python self-test ──────────────────────────────────────────────────────
if python3 "$GATE" self-test >/dev/null 2>&1; then
  assert "closure_gate.py self-test green" "pass"
else
  assert "closure_gate.py self-test green" "fail"
fi

# ── (a) complete happy tree -> CLOSURE-PASS ───────────────────────────────────
ROOT="$WORK/happy"
make_fixture "$ROOT" yes
rc="$(run_gate "$ROOT")"
[[ "$rc" == "0" ]] \
  && assert "happy tree: exit 0" "pass" || assert "happy tree: exit 0 (got $rc)" "fail"
head -1 "$(VERDICT_FILE "$ROOT")" | grep -q '^\*\*Verdict:\*\* CLOSURE-PASS$' \
  && assert "happy tree: first line is CLOSURE-PASS" "pass" \
  || assert "happy tree: first line is CLOSURE-PASS" "fail"
closure_verdict_passes "$(VERDICT_FILE "$ROOT")" \
  && assert "happy tree: closure_verdict_passes (real consumer) accepts it" "pass" \
  || assert "happy tree: closure_verdict_passes (real consumer) accepts it" "fail"

# ── (b) missing what-to-click -> CLOSURE-FAIL naming it ──────────────────────
ROOT="$WORK/missing"
make_fixture "$ROOT" yes
rm -f "$ROOT/reports/phase-p1-what-to-click.md"
rc="$(run_gate "$ROOT")"
[[ "$rc" != "0" ]] \
  && assert "missing what-to-click: non-zero exit" "pass" \
  || assert "missing what-to-click: non-zero exit" "fail"
grep -q '^\*\*Verdict:\*\* CLOSURE-FAIL$' "$(VERDICT_FILE "$ROOT")" \
  && grep -q 'what-to-click' "$(VERDICT_FILE "$ROOT")" \
  && assert "missing what-to-click: CLOSURE-FAIL names the artifact" "pass" \
  || assert "missing what-to-click: CLOSURE-FAIL names the artifact" "fail"
closure_verdict_passes "$(VERDICT_FILE "$ROOT")" \
  && assert "missing what-to-click: consumer rejects the verdict" "fail" \
  || assert "missing what-to-click: consumer rejects the verdict" "pass"

# ── (c) all-SKIPPED ui-test-results: reason -> PASS+WARN; none -> FAIL ───────
ROOT="$WORK/skipped-reason"
make_fixture "$ROOT" yes
cat > "$ROOT/reports/phase-p1-ui-test-results.md" <<'EOF'
# UI Test Results

**Browser QA Verdict:** SKIPPED

**Reason:** frontend not running — single-service API project; browser QA not applicable this phase.

| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |
|---|---|---|---|---|---|---|---|
| UT-01 | Create item | smoke | P1 | row appears | frontend not running | SKIP | none |

## Environment

- Browser: none
EOF
rc="$(run_gate "$ROOT")"
[[ "$rc" == "0" ]] \
  && assert "all-SKIPPED with documented reason: CLOSURE-PASS" "pass" \
  || assert "all-SKIPPED with documented reason: CLOSURE-PASS (got exit $rc)" "fail"
grep -q '^- WARN:.*all-SKIPPED' "$(VERDICT_FILE "$ROOT")" \
  && assert "all-SKIPPED with reason: WARN line in verdict report" "pass" \
  || assert "all-SKIPPED with reason: WARN line in verdict report" "fail"

ROOT="$WORK/skipped-noreason"
make_fixture "$ROOT" yes
cat > "$ROOT/reports/phase-p1-ui-test-results.md" <<'EOF'
# UI Test Results

**Browser QA Verdict:** SKIPPED

**Overall:** 0/1 tests passed (1 skipped)

| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |
|---|---|---|---|---|---|---|---|
| UT-01 | Create item | smoke | P1 | row appears | - | SKIP | none |

## Environment

- Browser: none
EOF
rc="$(run_gate "$ROOT")"
[[ "$rc" != "0" ]] && grep -q 'no documented reason' "$(VERDICT_FILE "$ROOT")" \
  && assert "all-SKIPPED without reason: CLOSURE-FAIL" "pass" \
  || assert "all-SKIPPED without reason: CLOSURE-FAIL" "fail"

# ── (d) backend-only phase with N/A stubs -> CLOSURE-PASS ────────────────────
ROOT="$WORK/backend"
make_fixture "$ROOT" no
rc="$(run_gate "$ROOT")"
[[ "$rc" == "0" ]] \
  && assert "backend-only N/A stubs: CLOSURE-PASS" "pass" \
  || assert "backend-only N/A stubs: CLOSURE-PASS (got exit $rc)" "fail"

# ── (e) product vocabulary "todo"/"Todo" in the UI artifacts is NOT a placeholder
make_fixture "$ROOT" yes
for a in implementation-summary user-visible-changes ui-surface-map ui-test-plan; do
  printf -- '- Add a todo via the form; the heading Todo is visible; state lives in todo.json\n' >> "$ROOT/reports/phase-p1-$a.md"
done
rc="$(run_gate "$ROOT")"
head -1 "$(VERDICT_FILE "$ROOT")" | grep -q '^\*\*Verdict:\*\* CLOSURE-PASS$' \
  && assert "product noun 'todo' in artifacts: CLOSURE-PASS" "pass" \
  || assert "product noun 'todo' in artifacts: CLOSURE-PASS (got exit $rc: $(grep -m3 -i 'todo' "$(VERDICT_FILE "$ROOT")" | tr '\n' ' '))" "fail"
# ── (f) a real marker still fails
make_fixture "$ROOT" yes
printf -- '- TODO: wire the filter control\n' >> "$ROOT/reports/phase-p1-ui-test-plan.md"
rc="$(run_gate "$ROOT")"
head -1 "$(VERDICT_FILE "$ROOT")" | grep -q '^\*\*Verdict:\*\* CLOSURE-FAIL$' \
  && assert "uppercase TODO marker: CLOSURE-FAIL" "pass" \
  || assert "uppercase TODO marker: CLOSURE-FAIL (got exit $rc)" "fail"

# ── (g) vague what-to-click -> CLOSURE-FAIL ──────────────────────────────────
ROOT="$WORK/vague"
make_fixture "$ROOT" yes
cat > "$ROOT/reports/phase-p1-what-to-click.md" <<'EOF'
# What to Click

- Prerequisite: frontend running
- Prerequisite: seed data exists
- The steps below verify the phase
- Each step is quick
- Time required: 5 minutes
- Written by fixture

1. Test the form
2. Verify it works
3. Check the page
EOF
rc="$(run_gate "$ROOT")"
[[ "$rc" != "0" ]] && grep -qi 'vague' "$(VERDICT_FILE "$ROOT")" \
  && assert "vague what-to-click (Test the form class): CLOSURE-FAIL" "pass" \
  || assert "vague what-to-click (Test the form class): CLOSURE-FAIL" "fail"

# ── (g2) FAILed upstream verdict -> CLOSURE-FAIL naming the report ───────────
ROOT="$WORK/failgate"
make_fixture "$ROOT" yes
printf '**Verdict:** FAIL\n' > "$ROOT/reports/qa/p1-qa.md"
rc="$(run_gate "$ROOT")"
[[ "$rc" != "0" ]] && grep -q 'QA report' "$(VERDICT_FILE "$ROOT")" \
  && assert "FAILed QA verdict: CLOSURE-FAIL names the QA report" "pass" \
  || assert "FAILed QA verdict: CLOSURE-FAIL names the QA report" "fail"

# ── (h) escape-hatch wiring in phase-closure-check.sh ────────────────────────
grep -q 'CHAIN_CLOSURE_LLM:-false.*==.*true' "$CHECK_SH" \
  && assert "wiring: CHAIN_CLOSURE_LLM=true routes to the LLM dispatch branch" "pass" \
  || assert "wiring: CHAIN_CLOSURE_LLM=true routes to the LLM dispatch branch" "fail"
grep -q 'claude_with_quota_retry' "$CHECK_SH" \
  && assert "wiring: agent dispatch preserved as escape hatch" "pass" \
  || assert "wiring: agent dispatch preserved as escape hatch" "fail"
grep -q 'record_agent_invocation_start phase-closure-auditor' "$CHECK_SH" \
  && grep -q 'record_agent_invocation_end phase-closure-auditor' "$CHECK_SH" \
  && assert "wiring: telemetry wrapping preserved inside the LLM branch" "pass" \
  || assert "wiring: telemetry wrapping preserved inside the LLM branch" "fail"
grep -q 'DETERMINISTIC GATE: lib/closure_gate.py' "$CHECK_SH" \
  && assert "wiring: deterministic path announces itself loudly" "pass" \
  || assert "wiring: deterministic path announces itself loudly" "fail"
grep -q 'closure_gate.py" "\$PHASE" --repo-root' "$CHECK_SH" \
  && assert "wiring: default path invokes closure_gate.py" "pass" \
  || assert "wiring: default path invokes closure_gate.py" "fail"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
