#!/usr/bin/env bash
# test-project-template-slice.sh — contract test for TOKEN-1: the
# project_template_slice helper in lib/common.sh (per-agent project-template
# slicing) and the reviewer prompt-mirror gate.
#
# Contract under test (G3: new artifact contract ⇒ eval fixture in the SAME change):
#   project_template_slice <agent> [template_path]
#     • known agent → the mapped `## ` sections of the template, emitted VERBATIM
#       (heading line through the line before the next `## ` heading, trailing
#       `---` separator included), in MAP order;
#     • a mapped section missing from the template → a loud inline marker
#       "[slice: section 'X' not found in <path>]" — never a silent omission;
#     • unknown agent → the FULL template on stdout (safe fallback) + one
#       diagnostic line on stderr (stdout must stay clean prompt content);
#     • template file missing → "[slice: template file not found: <path>]";
#     • always returns 0 (dispatch prompts embed it via $(...) under set -e).
#   Map (kept next to the helper): release-manager → GIT WORKFLOW;
#   reviewer → ARCHITECTURE PRINCIPLES, DESIGN SYSTEM, TEST COMMANDS;
#   qa → STACK, TEST COMMANDS, SERVICE START COMMANDS.
#
# Also gated here: the judgment runner's reviewer builder must stay VERBATIM-
# faithful to the production lean reviewer dispatch (goal-iter-lean.sh
# run_reviewer) — writer/reader drift between those two prompts is exactly the
# REL-1 failure mode (fixtures testing a prompt production no longer sends).
# The gate extracts both prompt templates, normalizes the known variable-name
# differences, and fails on any other byte difference.
#
# No API calls; runs in well under a second.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}
assert_eq() {  # assert_eq <label> <expected> <got>
  if [[ "$2" == "$3" ]]; then
    assert "$1" "pass"
  else
    assert "$1" "fail"
    diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed 's/^/        /' || true
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=../../scripts/automation/lib/common.sh
source "$ENGINE_ROOT/scripts/automation/lib/common.sh"

# ── Fixture template (every mapped heading + decoys, template-shaped) ────────
FIXTURE="$WORK/project-template.md"
cat > "$FIXTURE" <<'EOF'
# Project Configuration Template

Intro prose that no slice should ever include.

## PROJECT

```
Name: FixtureApp
```

---

## STACK

```
Backend:
  Language: Python 3.12
Services:
  Backend URL: http://localhost:8000
  Frontend URL: http://localhost:3000
```

---

## DESIGN SYSTEM

```
Component library: fixture-ui
```

---

## TEST COMMANDS

```
Backend tests: cd apps/backend && pytest -q
```

---

## SERVICE START COMMANDS

```
Start backend: bash scripts/start-backend.sh
```

---

## ARCHITECTURE PRINCIPLES

```
- keep API routes thin
```

---

## GIT WORKFLOW

```
Branch naming: phase/<phase-id>
Never commit:
  - .env
```

---

## NOTES FOR AGENTS

```
- decoy note
```
EOF

echo "=== 1. exact-match per-agent slices (fixture template) ==="

EXPECTED_RM='## GIT WORKFLOW

```
Branch naming: phase/<phase-id>
Never commit:
  - .env
```

---
'
got="$(project_template_slice release-manager "$FIXTURE")"
assert_eq "release-manager slice == GIT WORKFLOW section verbatim" "${EXPECTED_RM%$'\n'}" "$got"

EXPECTED_REVIEWER='## ARCHITECTURE PRINCIPLES

```
- keep API routes thin
```

---

## DESIGN SYSTEM

```
Component library: fixture-ui
```

---

## TEST COMMANDS

```
Backend tests: cd apps/backend && pytest -q
```

---
'
got="$(project_template_slice reviewer "$FIXTURE")"
assert_eq "reviewer slice == ARCHITECTURE PRINCIPLES + DESIGN SYSTEM + TEST COMMANDS (map order)" "${EXPECTED_REVIEWER%$'\n'}" "$got"

EXPECTED_QA='## STACK

```
Backend:
  Language: Python 3.12
Services:
  Backend URL: http://localhost:8000
  Frontend URL: http://localhost:3000
```

---

## TEST COMMANDS

```
Backend tests: cd apps/backend && pytest -q
```

---

## SERVICE START COMMANDS

```
Start backend: bash scripts/start-backend.sh
```

---
'
got="$(project_template_slice qa "$FIXTURE")"
assert_eq "qa slice == STACK + TEST COMMANDS + SERVICE START COMMANDS (map order)" "${EXPECTED_QA%$'\n'}" "$got"

case "$got" in
  *"decoy note"*|*"Intro prose"*) assert "slices never leak unmapped sections" "fail" ;;
  *) assert "slices never leak unmapped sections" "pass" ;;
esac

echo "=== 2. unknown agent → full file + stderr diagnostic ==="
out="$(project_template_slice totally-unknown-agent "$FIXTURE" 2>"$WORK/unknown.err")"
assert_eq "unknown agent emits the FULL template on stdout" "$(cat "$FIXTURE")" "$out"
if [[ -s "$WORK/unknown.err" ]] && grep -q "totally-unknown-agent" "$WORK/unknown.err"; then
  assert "unknown agent logs one diagnostic line to stderr (names the agent)" "pass"
else
  assert "unknown agent logs one diagnostic line to stderr (got: $(cat "$WORK/unknown.err" 2>/dev/null))" "fail"
fi

echo "=== 3. missing mapped section → loud inline marker ==="
NO_DESIGN="$WORK/no-design.md"
sed '/^## DESIGN SYSTEM$/,/^## TEST COMMANDS$/{/^## TEST COMMANDS$/!d;}' "$FIXTURE" > "$NO_DESIGN"
out="$(project_template_slice reviewer "$NO_DESIGN")"
if printf '%s\n' "$out" | grep -qF "[slice: section 'DESIGN SYSTEM' not found in $NO_DESIGN]"; then
  assert "missing section produces the loud marker (path included)" "pass"
else
  assert "missing section produces the loud marker (got: $(printf '%s' "$out" | head -3))" "fail"
fi
if [[ "$out" == *"## ARCHITECTURE PRINCIPLES"* && "$out" == *"## TEST COMMANDS"* ]]; then
  assert "other mapped sections still emitted around the marker" "pass"
else
  assert "other mapped sections still emitted around the marker" "fail"
fi

echo "=== 4. missing template file → loud marker, rc 0 ==="
rc=0
out="$(project_template_slice qa "$WORK/nonexistent.md")" || rc=$?
[[ "$rc" -eq 0 ]] && assert "missing template returns 0 (set -e safe in prompt substitution)" "pass" \
  || assert "missing template returns 0 (rc=$rc)" "fail"
if printf '%s\n' "$out" | grep -qF "[slice: template file not found: $WORK/nonexistent.md]"; then
  assert "missing template emits the loud not-found marker" "pass"
else
  assert "missing template emits the loud not-found marker (got: $out)" "fail"
fi

echo "=== 5. real template: the map matches the real headings (sufficiency canaries) ==="
for agent in release-manager reviewer qa; do
  out="$(project_template_slice "$agent" "$ENGINE_ROOT/.claude/project-template.md")"
  if printf '%s\n' "$out" | grep -q "^\[slice:"; then
    assert "real-template slice for $agent has no missing-section marker" "fail"
    printf '%s\n' "$out" | grep "^\[slice:" | sed 's/^/        /'
  else
    assert "real-template slice for $agent has no missing-section marker" "pass"
  fi
done
out="$(project_template_slice release-manager "$ENGINE_ROOT/.claude/project-template.md")"
[[ "$out" == *"Never commit:"* ]] \
  && assert "release-manager real slice carries the never-commit list" "pass" \
  || assert "release-manager real slice carries the never-commit list" "fail"

echo "=== 6. reviewer prompt-mirror gate (production vs judgment builder) ==="
# Production: the run_reviewer -p "..." template in goal-iter-lean.sh.
PROD="$(sed -n '/^  claude_with_quota_retry -p "You are the reviewer agent for goal-mode lean iteration\.$/,/^" || _rc=\$?$/p' \
          "$ENGINE_ROOT/scripts/automation/goal-iter-lean.sh" \
        | sed -e '1s/^  claude_with_quota_retry -p "//' -e '$d')"
# Judgment builder: the PROMPT_EOF heredoc body in _prepare_reviewer.
MIRROR="$(sed -n '/^You are the reviewer agent for goal-mode lean iteration\.$/,/^PROMPT_EOF$/p' \
            "$ENGINE_ROOT/scripts/automation/run-judgment-evals.sh" \
          | sed '$d')"
[[ -n "$PROD" ]]   && assert "extracted the production reviewer prompt template" "pass" \
  || assert "extracted the production reviewer prompt template" "fail"
[[ -n "$MIRROR" ]] && assert "extracted the judgment builder's reviewer prompt template" "pass" \
  || assert "extracted the judgment builder's reviewer prompt template" "fail"
# Normalize the builder's variable spellings to production's. These four renames
# are the ONLY sanctioned differences between the two templates.
MIRROR_NORM="$(printf '%s\n' "$MIRROR" | sed \
  -e 's|\$ITER_SPEC_PATH|$SPEC|g' \
  -e 's|\$VERDICT_FILE|$REVIEW_REPORT|g' \
  -e 's|\$DIFF_HINT|$(review_diff_hint HEAD)|g' \
  -e 's|\$TEMPLATE_SLICE|$(project_template_slice reviewer)|g')"
if [[ "$PROD" == "$MIRROR_NORM" ]]; then
  assert "judgment builder mirrors the production reviewer prompt byte-for-byte (after sanctioned renames)" "pass"
else
  assert "judgment builder mirrors the production reviewer prompt byte-for-byte (after sanctioned renames)" "fail"
  diff <(printf '%s\n' "$PROD") <(printf '%s\n' "$MIRROR_NORM") | sed 's/^/        /' || true
fi
# The production prompt must actually inline the slice (TOKEN-1 shape), not
# instruct a full-file read.
if printf '%s\n' "$PROD" | grep -q 'project_template_slice reviewer'; then
  assert "production reviewer prompt inlines the pre-sliced template" "pass"
else
  assert "production reviewer prompt inlines the pre-sliced template" "fail"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
