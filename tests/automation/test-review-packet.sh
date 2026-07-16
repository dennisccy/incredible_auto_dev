#!/usr/bin/env bash
# test-review-packet.sh — contract test for TOKEN-7: build_review_packet in
# lib/common.sh (the pre-baked review packet reviewer-class dispatches read
# packet-first).
#
# Contract under test (G3: new artifact contract ⇒ eval fixture in the SAME change):
#   build_review_packet <out-file> [base-ref]     (git repo = the caller's CWD)
#     • header NAMES the base ref ("Review packet — bounded diff vs <ref>") and
#       states the truncation semantics (truncations/exclusions NAMED; git
#       commands only for those files);
#     • section 1 = the review_diff_hint first command pre-executed: the
#       REVIEW_DIFF_EXCLUDE_PATTERNS-excluded diff, bounded by diff_bound.py —
#       oversized files carry the inline "[diff_bound] ... omitted" marker and
#       are NAMED in the bounded header's **Truncated** list;
#     • excluded paths (lockfiles, runs/, reports/, docs/handoffs/, binaries)
#       never render hunks in the body;
#     • section 2 = the hint's second command pre-executed: a --stat of ONLY
#       the excluded paths (dependency-lockfile visibility), or the literal
#       "(no changes in excluded paths)";
#     • atomic + fail-closed: non-zero on build failure (bad ref, not a repo)
#       with NO packet file and NO tmp litter left behind — a failed build must
#       never yield a packet that reads as "(no changes)".
#
# No API calls; runs in ~a second.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
assert() {
  if [[ "$2" == "pass" ]]; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}
assert_contains() {  # assert_contains <label> <file> <fixed-string>
  if grep -qF "$3" "$2" 2>/dev/null; then assert "$1" "pass"; else assert "$1 (missing: $3)" "fail"; fi
}
assert_not_contains() {  # assert_not_contains <label> <file> <fixed-string>
  if grep -qF "$3" "$2" 2>/dev/null; then assert "$1 (leaked: $3)" "fail"; else assert "$1" "pass"; fi
}

WORK="$(mktemp -d "${CHAIN_TMP_ROOT:-${TMPDIR:-$HOME/.cache/iad}}/review-packet-test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=../../scripts/automation/lib/common.sh
source "$ENGINE_ROOT/scripts/automation/lib/common.sh"

# ── Fixture repo: baseline commit, then a working set that exercises every
#    packet clause (normal hunk, oversized file, lockfile churn, harness churn,
#    binary asset) left UNCOMMITTED — the engine-time repo state. ─────────────
REPO="$WORK/repo"
mkdir -p "$REPO/src" "$REPO/runs/iter" "$REPO/docs/handoffs"
cd "$REPO"
git init -q -b main
echo "def handler(): return 1" > src/app.py
echo '{"lockfileVersion": 1}' > package-lock.json
echo "prior run log" > runs/iter/log.md
git add -A
git -c user.name=t -c user.email=t@localhost commit -qm baseline

echo "def handler(): return 2" > src/app.py                    # normal hunk
python3 -c "print('\n'.join(f'line {i}' for i in range(600)))" > src/big.py
git add src/big.py                                             # oversized (staged = still uncommitted work)
echo '{"lockfileVersion": 2, "churn": true}' > package-lock.json
echo "current run log" > runs/iter/log.md
printf 'PNGFAKE' > docs/handoffs/evidence.png
git add docs/handoffs/evidence.png

echo "=== 1. packet header names the base ref + truncation semantics ==="
OUT="$WORK/iter-dir/review-packet.md"
rc=0
build_review_packet "$OUT" HEAD || rc=$?
[[ "$rc" -eq 0 && -s "$OUT" ]] && assert "build succeeds and writes the packet (mkdir -p of the out dir included)" "pass" \
  || assert "build succeeds and writes the packet (rc=$rc)" "fail"
assert_contains "header names the base ref" "$OUT" "# Review packet — bounded diff vs HEAD"
assert_contains "header states the truncation contract" "$OUT" "Truncations and exclusions are NAMED below"
assert_contains "header scopes the git commands to truncated/excluded files" "$OUT" "ONLY for files marked truncated or excluded"

echo "=== 2. bounded body: normal hunks in, noise out, oversize truncated+NAMED ==="
assert_contains "normal source hunk rendered" "$OUT" "+def handler(): return 2"
assert_contains "oversized file carries the inline diff_bound marker" "$OUT" "more diff lines omitted"
assert_contains "oversized file is NAMED in the bounded Truncated list" "$OUT" "src/big.py"
assert_not_contains "lockfile hunks never render" "$OUT" "lockfileVersion"
assert_not_contains "runs/ churn never renders" "$OUT" "current run log"

echo "=== 3. excluded-path stat: lockfile visibility without lockfile hunks ==="
assert_contains "stat section present" "$OUT" "## Excluded-path stat (dependency/lockfile visibility)"
assert_contains "stat lists the changed lockfile" "$OUT" "package-lock.json"
assert_contains "stat guidance points at the manifest, not the lockfile" "$OUT" "review the matching package.json/pyproject"

echo "=== 4. custom base ref is named verbatim ==="
git -c user.name=t -c user.email=t@localhost tag base-tag
OUT2="$WORK/p2.md"
build_review_packet "$OUT2" base-tag \
  && assert_contains "custom ref in the header" "$OUT2" "bounded diff vs base-tag" \
  || assert "custom ref build" "fail"

echo "=== 5. clean-excludes diff → literal no-changes stat line ==="
git checkout -q -- package-lock.json
git reset -q -- docs/handoffs/evidence.png && rm -f docs/handoffs/evidence.png
git checkout -q -- runs/iter/log.md 2>/dev/null || git -C "$REPO" checkout -q -- runs/iter/log.md
OUT3="$WORK/p3.md"
build_review_packet "$OUT3" HEAD \
  && assert_contains "no-changes stat marker" "$OUT3" "(no changes in excluded paths)" \
  || assert "clean-excludes build" "fail"
assert_contains "normal hunk still rendered on the clean-excludes build" "$OUT3" "+def handler(): return 2"

echo "=== 6. fail-closed: bad ref / not a repo → rc!=0, no file, no tmp litter ==="
rc=0; build_review_packet "$WORK/bad.md" NO_SUCH_REF 2>/dev/null || rc=$?
[[ "$rc" -ne 0 ]] && assert "bad ref returns non-zero" "pass" || assert "bad ref returns non-zero (rc=0)" "fail"
[[ ! -e "$WORK/bad.md" ]] && assert "bad ref leaves no packet file" "pass" || assert "bad ref leaves no packet file" "fail"
NONREPO="$WORK/nonrepo"; mkdir -p "$NONREPO"
rc=0; ( cd "$NONREPO" && GIT_CEILING_DIRECTORIES="$WORK" build_review_packet "$NONREPO/p.md" HEAD 2>/dev/null ) || rc=$?
[[ "$rc" -ne 0 ]] && assert "outside a repo returns non-zero" "pass" || assert "outside a repo returns non-zero (rc=0)" "fail"
[[ ! -e "$NONREPO/p.md" ]] && assert "outside a repo leaves no packet file" "pass" || assert "outside a repo leaves no packet file" "fail"
if compgen -G "$WORK/*.tmp.*" >/dev/null || compgen -G "$WORK/iter-dir/*.tmp.*" >/dev/null; then
  assert "no tmp litter left behind" "fail"
else
  assert "no tmp litter left behind" "pass"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -gt 0 ]] && exit 1
exit 0
