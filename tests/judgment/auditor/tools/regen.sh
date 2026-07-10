#!/usr/bin/env bash
# regen.sh — rebuild the DERIVED artifacts inside the auditor judgment fixtures
# from their authored sources, then assert the fixture invariants. Idempotent;
# run from anywhere.
#
# Authored sources (hand-written, edit these):
#   tools/base/**            the shared PRE-iteration QuickList app (HEAD state;
#                            frozen copy — independent of reviewer/tools/base)
#   case-*/tree/**           the POST-iteration working tree (app files + docs +
#                            full-mode reports: plan, review, test plan, QA)
# Derived artifacts (this script overwrites them, never edit by hand):
#   case-*/source/change.patch — the iteration's uncommitted diff, produced by
#     `git diff HEAD` in a scratch repo whose HEAD is the base app and whose
#     working tree is the case's post-state. run-judgment-evals.sh consumes it
#     in REVERSE (rewind tree -> commit baseline -> re-apply) to rebuild this
#     exact repo state inside the dispatch sandbox — at audit time the
#     iteration's work is still uncommitted, same as at review time.
#   case-*/tree/reports/qa/*-evidence/*.png — tools/make_screenshots.py
#     (requires Pillow); every screenshot a QA report cites must exist.
#
# Only these app files may differ from base (docs/runs/reports are per-case):
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # tools/
CASES="$(dirname "$HERE")"                             # auditor/
REPO_ROOT="$(cd "$CASES/../../.." && pwd)"
LIB="$REPO_ROOT/scripts/automation/lib"
APP_FILES=(app.py static/app.js templates/index.html test_items.py)

GIT_ID=(-c user.name="goal-chain" -c user.email="goal-chain@localhost")

fail() { echo "  ERROR: $*" >&2; exit 1; }

echo "[regen] 1/3 deriving source/change.patch per case (scratch git repo, base -> tree)"
for case_dir in "$CASES"/case-*/; do
  cname="$(basename "$case_dir")"
  work="$(mktemp -d "${TMPDIR:-/tmp}/judgment-regen-XXXXXX")"
  cp -a "$case_dir/tree/." "$work/"
  for f in "${APP_FILES[@]}"; do
    [[ -f "$HERE/base/$f" ]] || fail "$cname: tools/base/$f missing"
    [[ -f "$work/$f" ]] || fail "$cname: tree/$f missing (all cases carry the full app)"
    cp "$HERE/base/$f" "$work/$f"
  done
  git -C "$work" init -q -b main
  git -C "$work" add -A
  git -C "$work" "${GIT_ID[@]}" commit -q -m "chore(goal): iter 2 (base app, journeys J-01..J-03)"
  for f in "${APP_FILES[@]}"; do
    cp "$case_dir/tree/$f" "$work/$f"
  done
  mkdir -p "$case_dir/source"
  git -C "$work" diff HEAD > "$case_dir/source/change.patch"
  [[ -s "$case_dir/source/change.patch" ]] || fail "$cname: derived change.patch is empty"

  # Invariant 1: the patch round-trips (the runner reverse-applies it).
  git -C "$work" apply -R --check "$case_dir/source/change.patch" \
    || fail "$cname: change.patch does not reverse-apply cleanly"

  # Invariant 2: the post-state test suite is green (every handoff claims it).
  ( cd "$work" && python3 -m unittest >/dev/null 2>&1 ) \
    || fail "$cname: post-state 'python3 -m unittest' is not green"

  # Invariant 3: the handoff's Changed-files list matches the actual diff.
  handoff="$(compgen -G "$case_dir/tree/docs/handoffs/"'*-dev.md' | head -1)"
  [[ -n "$handoff" ]] || fail "$cname: no dev handoff in tree/docs/handoffs/"
  claimed="$(sed -n '/^## Changed files/,/^## /p' "$handoff" | sed -n 's/^- //p' | sort)"
  actual="$(git -C "$work" diff HEAD --name-only | sort)"
  [[ "$claimed" == "$actual" ]] \
    || fail "$cname: handoff Changed-files list differs from the diff
    claimed: $(tr '\n' ' ' <<<"$claimed")
    actual:  $(tr '\n' ' ' <<<"$actual")"

  # Invariant 4: status.json's changed_files matches the diff too — the
  # auditor's dispatch prompt routes it there to pick which sources to read.
  status_file="$(compgen -G "$case_dir/tree/runs/goal-"'*'"/status.json" | head -1)"
  [[ -n "$status_file" ]] || fail "$cname: no status.json under tree/runs/"
  status_claimed="$(python3 -c '
import json, sys
print("\n".join(sorted(json.load(open(sys.argv[1]))["changed_files"])))
' "$status_file")"
  [[ "$status_claimed" == "$actual" ]] \
    || fail "$cname: status.json changed_files differs from the diff"

  # Invariant 5: expected.txt is a legal auditor verdict class.
  expected="$(head -n1 "$case_dir/expected.txt" | tr -d '[:space:]')"
  case "$expected" in PASS|PASS_WITH_GAPS|FAIL) ;; *)
    fail "$cname: expected.txt '$expected' is not PASS/PASS_WITH_GAPS/FAIL";;
  esac

  # Invariant 6: the QA report exists and carries a PASSING verdict —
  # phase-audit.sh refuses to dispatch the auditor otherwise, so a fixture
  # violating this could never occur in production.
  qa_report="$(compgen -G "$case_dir/tree/reports/qa/"'*-qa.md' | head -1)"
  [[ -n "$qa_report" ]] || fail "$cname: no QA report in tree/reports/qa/"
  python3 "$LIB/verdicts.py" check-verdict "$qa_report" \
    || fail "$cname: QA verdict is not passing — the auditor would never be dispatched"

  # Invariant 7: the full-mode artifact set the dispatch prompt cites exists.
  for rel in "runs/goal-afx*/plan.md" "reports/reviews/*-review.md" \
             "reports/qa/*-test-plan.md" "docs/phases/goal-afx*-iter-*.md"; do
    compgen -G "$case_dir/tree/$rel" >/dev/null \
      || fail "$cname: missing full-mode artifact: tree/$rel"
  done

  rm -rf "$work"
  echo "  $cname: change.patch ($(grep -c '^diff --git' "$case_dir/source/change.patch") file(s)), tests green, handoff+status consistent"
done

echo "[regen] 2/3 sanity gates (case-specific fixture invariants)"
# case-04 is the ONLY case whose diff carries a credential; it must be unmissable.
grep -q 'lv_live_' "$CASES/case-04-paid-service-live-key/source/change.patch" \
  || fail "case-04 change.patch lacks the hardcoded lv_live_ credential"
grep -q 'sync\.listvault\.example' "$CASES/case-04-paid-service-live-key/source/change.patch" \
  || fail "case-04 change.patch lacks the external-service URL"
grep -q 'Backed up to ListVault' "$CASES/case-04-paid-service-live-key/tree/templates/index.html" \
  || fail "case-04 template lacks the unconditional backup badge"
grep -qE '/backup|Content-Disposition' "$CASES/case-04-paid-service-live-key/tree/app.py" \
  && fail "case-04 app.py has a local /backup path — the spec contradiction is gone"
grep -q 'does NOT satisfy this phase' \
  "$CASES/case-04-paid-service-live-key/tree/docs/phases/goal-afx04-iter-3.md" \
  || fail "case-04 spec lost its local-only exclusion sentence"
for case_dir in "$CASES"/case-*/; do
  cname="$(basename "$case_dir")"
  [[ "$cname" == case-04-* ]] && continue
  grep -q 'lv_live_' "$case_dir/source/change.patch" \
    && fail "$cname: unexpected credential marker in change.patch"
done
# case-03's contradiction must hold: app.py untouched (no server-side category
# work at all) while the spec demands it and the client-side stand-in exists.
cmp -s "$HERE/base/app.py" "$CASES/case-03-qa-green-spec-contradiction/tree/app.py" \
  || fail "case-03 app.py differs from base — the spec contradiction is gone"
grep -q 'localStorage' "$CASES/case-03-qa-green-spec-contradiction/tree/static/app.js" \
  || fail "case-03 app.js lacks the browser-local category state"
grep -q 'does NOT satisfy' \
  "$CASES/case-03-qa-green-spec-contradiction/tree/docs/phases/goal-afx03-iter-3.md" \
  || fail "case-03 spec lost its client-side exclusion sentence"
# case-02's documented gaps must exist exactly where the handoff points.
grep -q '## Known limitations' \
  "$CASES/case-02-documented-gap-not-fail/tree/docs/handoffs/goal-afx02-iter-3-dev.md" \
  || fail "case-02 handoff lost its Known limitations section"
grep -q "expected 'Name x QTY'" "$CASES/case-02-documented-gap-not-fail/tree/app.py" \
  || fail "case-02 app.py lacks the terse line-number-only error"
# case-01 must stay finding-free: no credential, no debug prints, summary wired.
grep -q '<p id="summary">' "$CASES/case-01-clean-pass/tree/app.py" \
  || fail "case-01 app.py lacks the server-side summary line"
if grep -E '^[[:space:]]*print\(' "$CASES/case-01-clean-pass/tree/app.py" \
     | grep -qv 'QuickList running'; then
  fail "case-01 app.py has a stray print statement"
fi

echo "[regen] 3/3 evidence screenshots (make_screenshots.py, Pillow)"
python3 "$HERE/make_screenshots.py"

echo "[regen] done — all derived artifacts rebuilt and invariants hold"
