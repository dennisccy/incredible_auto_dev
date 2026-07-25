#!/usr/bin/env bash
# test-doc-drift.sh — Doc-drift eval (DOC-2): the numbered claims README.md and
# CLAUDE.md make must match the tree, and the README "## Agent Roles" table
# must stay in sync with agents/*/.
#
# Usage: bash tests/automation/test-doc-drift.sh
#
# Layout mirrors lint_contracts.py: fixture assertions FIRST (prove every check
# can actually go red), then the live-tree checks. A claim DOC-1 de-numbered
# produces no regex match and is skipped — only what is numbered gets verified.
#
# Checks:
#   - "N agents/skills/commands/hooks" claims vs neutral-source counts
#     (agents/*/ dirs, skills/*.md, commands/*.md, hooks/*.sh)
#   - "N-step pipeline" / "all N steps" claims vs run-phase.sh's own
#     'log "Step X/N --' banners (comments like "Step 4/5/6 retry" carry no
#     ' --' anchor and are ignored)
#   - README Agent Roles table lists every agents/*/ dir, and every table row
#     names a real agents/*/ dir (no ghost rows)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

# ── Core checkers (path-parameterized so fixtures can exercise them) ─────────
# All detail goes to stdout (callers capture with $()); return codes classify.

# _claims_status <file> <egrep-pattern> <expected>
# Every number inside a <pattern> match in <file> must equal <expected>.
# rc 0: claims exist and all match · rc 1: mismatch (stdout: offending numbers)
# rc 2: no numbered claim (de-numbered → caller skips)
_claims_status() {
  local file="$1" pattern="$2" expected="$3" nums
  nums=$(grep -hoE "$pattern" "$file" 2>/dev/null | grep -oE '[0-9]+' | sort -un || true)
  [[ -z "$nums" ]] && return 2
  [[ "$nums" == "$expected" ]] && return 0
  echo "$nums" | tr '\n' ' '
  return 1
}

# check_claims <label> <file> <pattern> <expected> — live-tree wrapper
check_claims() {
  local label="$1" file="$2" pattern="$3" expected="$4" rc=0 out
  out=$(_claims_status "$file" "$pattern" "$expected") || rc=$?
  case $rc in
    0) pass "$label: numbered claim matches tree ($expected)" ;;
    2) pass "$label: no numbered claim (de-numbered — skipped)" ;;
    *) fail "$label: doc claims [$out] but tree has $expected — fix the doc or de-number the claim" ;;
  esac
}

# _pipeline_step_count <script>
# Ground truth for step claims: the 'log "Step X/N --' banners the pipeline
# script itself emits. stdout: N on success, detail on failure.
# rc 0: ok · 1: no banners · 2: denominators disagree · 3: max step != N
_pipeline_step_count() {
  local script="$1" banners dens max_int
  banners=$(grep -ohE 'log "Step [0-9]+([.-][0-9]+)?/[0-9]+ --' "$script" 2>/dev/null || true)
  if [[ -z "$banners" ]]; then
    echo "no 'log \"Step X/N --' banners found"
    return 1
  fi
  dens=$(echo "$banners" | grep -oE '/[0-9]+ --' | grep -oE '[0-9]+' | sort -un)
  if [[ $(echo "$dens" | wc -l) -ne 1 ]]; then
    echo "denominators disagree: $(echo "$dens" | tr '\n' ' ')"
    return 2
  fi
  max_int=$(echo "$banners" | grep -oE 'Step [0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1)
  if [[ "$max_int" -ne "$dens" ]]; then
    echo "max integer step $max_int != declared denominator $dens"
    return 3
  fi
  echo "$dens"
}

# _table_check <readme> <agents-parent-dir>
# README "## Agent Roles" first-column names ↔ <agents-parent-dir>/*/ dirs.
# rc 0: in sync · 1: dir missing from table (stdout: names)
# rc 2: table row without a dir (stdout: names) · rc 3: table not found
_table_check() {
  local readme="$1" agents_dir="$2" table_names dir_names missing ghosts
  table_names=$(sed -n '/^## Agent Roles/,/^## /p' "$readme" 2>/dev/null \
    | grep -oE '^\| `[a-z0-9_-]+`' | tr -d '| `' | sort -u || true)
  [[ -z "$table_names" ]] && return 3
  dir_names=$(for d in "$agents_dir"/*/; do [[ -d "$d" ]] && basename "$d"; done | sort -u || true)
  missing=$(comm -23 <(printf '%s\n' "$dir_names") <(printf '%s\n' "$table_names"))
  ghosts=$(comm -13 <(printf '%s\n' "$dir_names") <(printf '%s\n' "$table_names"))
  if [[ -n "$missing" ]]; then
    echo "$missing" | tr '\n' ' '
    return 1
  fi
  if [[ -n "$ghosts" ]]; then
    echo "$ghosts" | tr '\n' ' '
    return 2
  fi
  return 0
}

# _antipattern_tree_status <tree-dir>
# CTX-12: .claude/anti-patterns/ index ↔ entry files. README.md rows (| N | …)
# must match NN-*.md files 1:1, and numbering must be 1..max with no gaps or
# dupes (numbering is frozen; next entry = max+1).
# rc 0: in sync · 1: file without index row (stdout: numbers) · 2: index row
# without file (stdout: numbers) · 3: numbering gap/dupe · 4: no README/rows
_antipattern_tree_status() {
  local dir="$1" idx="$1/README.md"
  [[ -f "$idx" ]] || { echo "no README.md"; return 4; }
  local file_nums row_nums
  file_nums=$(for f in "$dir"/[0-9][0-9]-*.md; do [[ -f "$f" ]] && basename "$f"; done \
    | grep -oE '^[0-9]+' | sort)
  row_nums=$(grep -oE '^\| *[0-9]+ *\|' "$idx" | grep -oE '[0-9]+' | awk '{printf "%02d\n",$1}' | sort)
  [[ -z "$row_nums" ]] && { echo "no index rows"; return 4; }
  local missing ghosts
  missing=$(comm -23 <(printf '%s\n' "$file_nums") <(printf '%s\n' "$row_nums"))
  ghosts=$(comm -13 <(printf '%s\n' "$file_nums") <(printf '%s\n' "$row_nums"))
  [[ -n "$missing" ]] && { echo "$missing" | tr '\n' ' '; return 1; }
  [[ -n "$ghosts" ]] && { echo "$ghosts" | tr '\n' ' '; return 2; }
  local cnt uniq_cnt max
  cnt=$(printf '%s\n' "$file_nums" | grep -c .)
  uniq_cnt=$(printf '%s\n' "$file_nums" | sort -u | grep -c .)
  max=$(printf '%s\n' "$file_nums" | sort -n | tail -1 | sed 's/^0*//')
  if [[ "$uniq_cnt" -ne "$cnt" || "$max" -ne "$cnt" ]]; then
    echo "numbering: count=$cnt unique=$uniq_cnt max=$max"
    return 3
  fi
  return 0
}

# ── Claim patterns (anchored: number must directly modify the noun) ──────────
AGENTS_CLAIM='\b[0-9]+ (specialized |neutral |focused )?agents\b'
SKILLS_CLAIM='\b[0-9]+ (reusable )?skills\b'
COMMANDS_CLAIM='\b[0-9]+ (slash |interactive )?commands\b'
HOOKS_CLAIM='\b[0-9]+ hooks\b'
STEP_PIPE_CLAIM='\b[0-9]+-step pipeline\b'
STEP_ALL_CLAIM='\ball [0-9]+ steps\b'

echo ""
echo "=== doc-drift eval (DOC-2) ==="
echo ""
echo "-- fixtures: every check must be able to go red --"

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

# Numbered-claim checker: match / mismatch / de-numbered-skip
printf 'This repo ships 3 specialized agents for the pipeline.\n' > "$FIX/readme-good.md"
printf 'This repo ships 42 specialized agents for the pipeline.\n' > "$FIX/readme-bad.md"
printf 'This repo ships specialized agents for the pipeline.\n' > "$FIX/readme-denumbered.md"

rc=0; _claims_status "$FIX/readme-good.md" "$AGENTS_CLAIM" 3 >/dev/null || rc=$?
[[ $rc -eq 0 ]] && pass "fixture: matching claim accepted" \
                || fail "fixture: matching claim rejected (rc=$rc)"

rc=0; _claims_status "$FIX/readme-bad.md" "$AGENTS_CLAIM" 3 >/dev/null || rc=$?
[[ $rc -eq 1 ]] && pass "fixture: wrong count goes red" \
                || fail "fixture: wrong count NOT caught (rc=$rc)"

rc=0; _claims_status "$FIX/readme-denumbered.md" "$AGENTS_CLAIM" 3 >/dev/null || rc=$?
[[ $rc -eq 2 ]] && pass "fixture: de-numbered claim skipped" \
                || fail "fixture: de-numbered claim not skipped (rc=$rc)"

# Pipeline-step ground truth: coherent / drifted denominator / incoherent max
cat > "$FIX/pipeline-good.sh" <<'EOF'
log "Step 1/3 -- plan..."
log "Step 2/3 -- build..."
log "Step 2.5/3 -- showcase..."
log "Step 3/3 -- ship..."
# comment mentioning Step 1/2/3 retry blocks must not count
EOF
cat > "$FIX/pipeline-drift.sh" <<'EOF'
log "Step 1/3 -- plan..."
log "Step 2/4 -- build..."
EOF
cat > "$FIX/pipeline-incoherent.sh" <<'EOF'
log "Step 1/3 -- plan..."
log "Step 2/3 -- build..."
EOF

rc=0; out=$(_pipeline_step_count "$FIX/pipeline-good.sh") || rc=$?
[[ $rc -eq 0 && "$out" == "3" ]] && pass "fixture: coherent banners yield step count (3)" \
                                 || fail "fixture: coherent banners misread (rc=$rc out=$out)"

rc=0; out=$(_pipeline_step_count "$FIX/pipeline-drift.sh") || rc=$?
[[ $rc -eq 2 ]] && pass "fixture: disagreeing denominators go red" \
                || fail "fixture: disagreeing denominators NOT caught (rc=$rc)"

rc=0; out=$(_pipeline_step_count "$FIX/pipeline-incoherent.sh") || rc=$?
[[ $rc -eq 3 ]] && pass "fixture: max step != denominator goes red" \
                || fail "fixture: incoherent numbering NOT caught (rc=$rc)"

# Roles table: complete / missing dir / ghost row / missing section
mkdir -p "$FIX/agents/alpha" "$FIX/agents/beta"
cat > "$FIX/readme-table.md" <<'EOF'
## Agent Roles

| Agent | What it does |
|-------|--------------|
| `alpha` | does alpha |
| `beta` | does beta |

## Commands
EOF

rc=0; _table_check "$FIX/readme-table.md" "$FIX/agents" >/dev/null || rc=$?
[[ $rc -eq 0 ]] && pass "fixture: complete table accepted" \
                || fail "fixture: complete table rejected (rc=$rc)"

mkdir "$FIX/agents/gamma"
rc=0; out=$(_table_check "$FIX/readme-table.md" "$FIX/agents") || rc=$?
[[ $rc -eq 1 && "$out" == *gamma* ]] && pass "fixture: dir missing from table goes red" \
                                     || fail "fixture: missing dir NOT caught (rc=$rc out=$out)"
rmdir "$FIX/agents/gamma"

rmdir "$FIX/agents/beta"
rc=0; out=$(_table_check "$FIX/readme-table.md" "$FIX/agents") || rc=$?
[[ $rc -eq 2 && "$out" == *beta* ]] && pass "fixture: ghost table row goes red" \
                                    || fail "fixture: ghost row NOT caught (rc=$rc out=$out)"

rc=0; _table_check "$FIX/readme-good.md" "$FIX/agents" >/dev/null || rc=$?
[[ $rc -eq 3 ]] && pass "fixture: missing Agent Roles section goes red" \
                || fail "fixture: missing section NOT caught (rc=$rc)"

# Anti-pattern tree: coherent / orphan file / ghost row / numbering gap
mkdir -p "$FIX/ap"
printf '## 1. alpha\n' > "$FIX/ap/01-alpha.md"
printf '## 2. beta\n'  > "$FIX/ap/02-beta.md"
cat > "$FIX/ap/README.md" <<'EOF'
| # | Entry | Applies when | Rule |
|---|-------|--------------|------|
| 1 | [01-alpha.md](01-alpha.md) | x | y |
| 2 | [02-beta.md](02-beta.md) | x | y |
EOF

rc=0; _antipattern_tree_status "$FIX/ap" >/dev/null || rc=$?
[[ $rc -eq 0 ]] && pass "fixture: coherent anti-pattern tree accepted" \
                || fail "fixture: coherent tree rejected (rc=$rc)"

printf '## 3. gamma\n' > "$FIX/ap/03-gamma.md"
rc=0; out=$(_antipattern_tree_status "$FIX/ap") || rc=$?
[[ $rc -eq 1 && "$out" == *03* ]] && pass "fixture: entry file without index row goes red" \
                                  || fail "fixture: orphan entry NOT caught (rc=$rc out=$out)"
rm "$FIX/ap/03-gamma.md"

printf '| 4 | [04-delta.md](04-delta.md) | x | y |\n' >> "$FIX/ap/README.md"
rc=0; out=$(_antipattern_tree_status "$FIX/ap") || rc=$?
[[ $rc -eq 2 && "$out" == *04* ]] && pass "fixture: index row without file goes red" \
                                  || fail "fixture: ghost row NOT caught (rc=$rc out=$out)"
sed -i '$ d' "$FIX/ap/README.md"

# Gap: files 01+03 with matching rows 1+3 — sets agree, numbering doesn't
rm "$FIX/ap/02-beta.md"
printf '## 3. gamma\n' > "$FIX/ap/03-gamma.md"
cat > "$FIX/ap/README.md" <<'EOF'
| # | Entry | Applies when | Rule |
|---|-------|--------------|------|
| 1 | [01-alpha.md](01-alpha.md) | x | y |
| 3 | [03-gamma.md](03-gamma.md) | x | y |
EOF
rc=0; out=$(_antipattern_tree_status "$FIX/ap") || rc=$?
[[ $rc -eq 3 ]] && pass "fixture: numbering gap goes red" \
                || fail "fixture: numbering gap NOT caught (rc=$rc out=$out)"

echo ""
echo "-- live tree --"

README="$REPO_ROOT/README.md"
CLAUDEMD="$REPO_ROOT/CLAUDE.md"

# Neutral source is the truth (CLAUDE.md G2), not the rendered .claude/ mirrors.
AGENT_COUNT=$(find "$REPO_ROOT/agents" -mindepth 1 -maxdepth 1 -type d | wc -l)
SKILL_COUNT=$(find "$REPO_ROOT/skills" -maxdepth 1 -name '*.md' | wc -l)
COMMAND_COUNT=$(find "$REPO_ROOT/commands" -maxdepth 1 -name '*.md' | wc -l)
HOOK_COUNT=$(find "$REPO_ROOT/hooks" -maxdepth 1 -name '*.sh' | wc -l)

for doc in "$README" "$CLAUDEMD"; do
  base=$(basename "$doc")
  check_claims "agents ($base)"   "$doc" "$AGENTS_CLAIM"   "$AGENT_COUNT"
  check_claims "skills ($base)"   "$doc" "$SKILLS_CLAIM"   "$SKILL_COUNT"
  check_claims "commands ($base)" "$doc" "$COMMANDS_CLAIM" "$COMMAND_COUNT"
  check_claims "hooks ($base)"    "$doc" "$HOOKS_CLAIM"    "$HOOK_COUNT"
done

# CTX-4: the architecture docs carry the same inventory claims and rot the
# same way — same checkers, same fixtures prove they can go red.
for doc in "$REPO_ROOT/.claude/architecture/"*.md; do
  base="architecture/$(basename "$doc")"
  check_claims "agents ($base)"   "$doc" "$AGENTS_CLAIM"   "$AGENT_COUNT"
  check_claims "skills ($base)"   "$doc" "$SKILLS_CLAIM"   "$SKILL_COUNT"
  check_claims "commands ($base)" "$doc" "$COMMANDS_CLAIM" "$COMMAND_COUNT"
  check_claims "hooks ($base)"    "$doc" "$HOOKS_CLAIM"    "$HOOK_COUNT"
done

# CTX-12: anti-patterns tree — index ↔ entries, frozen numbering, monolith retired
rc=0; out=$(_antipattern_tree_status "$REPO_ROOT/.claude/anti-patterns") || rc=$?
case $rc in
  0) pass "anti-patterns tree: index ↔ entries in sync" ;;
  1) fail "anti-patterns tree: entry files missing an index row: $out" ;;
  2) fail "anti-patterns tree: index rows without a file: $out" ;;
  3) fail "anti-patterns tree: numbering broken ($out)" ;;
  *) fail "anti-patterns tree: README/index missing ($out)" ;;
esac
if [[ -f "$REPO_ROOT/.claude/anti-patterns.md" ]]; then
  fail "anti-patterns: retired monolith .claude/anti-patterns.md re-appeared (the tree is canonical)"
else
  pass "anti-patterns: monolith retired (tree is canonical)"
fi

rc=0; STEP_COUNT=$(_pipeline_step_count "$REPO_ROOT/scripts/automation/run-phase.sh") || rc=$?
if [[ $rc -eq 0 ]]; then
  pass "pipeline: run-phase.sh banners declare $STEP_COUNT steps (coherent)"
  for doc in "$README" "$CLAUDEMD"; do
    base=$(basename "$doc")
    check_claims "N-step pipeline ($base)" "$doc" "$STEP_PIPE_CLAIM" "$STEP_COUNT"
    check_claims "all N steps ($base)"     "$doc" "$STEP_ALL_CLAIM"  "$STEP_COUNT"
  done
else
  fail "pipeline: run-phase.sh step banners unusable ($STEP_COUNT)"
fi

rc=0; out=$(_table_check "$README" "$REPO_ROOT/agents") || rc=$?
case $rc in
  0) pass "roles table: README Agent Roles ↔ agents/*/ in sync ($AGENT_COUNT agents)" ;;
  1) fail "roles table: agents/*/ dirs missing from README Agent Roles table: $out" ;;
  2) fail "roles table: rows without a matching agents/*/ dir: $out" ;;
  *) fail "roles table: '## Agent Roles' table not found in README.md" ;;
esac

# ── Results ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo ""

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
