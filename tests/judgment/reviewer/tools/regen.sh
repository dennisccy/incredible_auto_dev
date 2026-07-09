#!/usr/bin/env bash
# regen.sh — rebuild the DERIVED artifact inside the reviewer judgment fixtures
# from its authored sources, then assert the fixture invariants. Idempotent; run
# from anywhere.
#
# Authored sources (hand-written, edit these):
#   tools/base/**            the shared PRE-iteration QuickList app (HEAD state)
#   case-*/tree/**           the POST-iteration working tree (app files + docs)
# Derived artifact (this script overwrites it, never edit by hand):
#   case-*/source/change.patch — the iteration's uncommitted diff, produced by
#   `git diff HEAD` in a scratch repo whose HEAD is the base app and whose
#   working tree is the case's post-state. run-judgment-evals.sh consumes it in
#   REVERSE (rewind tree -> commit baseline -> re-apply) to rebuild this exact
#   repo state inside the dispatch sandbox, so the reviewer's production
#   `git diff HEAD` command shows precisely this patch.
#
# Only these app files may differ from base (docs/runs are per-case by design):
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # tools/
CASES="$(dirname "$HERE")"                             # reviewer/
APP_FILES=(app.py static/app.js templates/index.html test_items.py)

GIT_ID=(-c user.name="goal-chain" -c user.email="goal-chain@localhost")

fail() { echo "  ERROR: $*" >&2; exit 1; }

echo "[regen] deriving source/change.patch per case (scratch git repo, base -> tree)"
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

  # Invariant 4: expected.txt is a legal reviewer verdict class.
  expected="$(head -n1 "$case_dir/expected.txt" | tr -d '[:space:]')"
  case "$expected" in PASS|PASS_WITH_NOTES|FAIL) ;; *)
    fail "$cname: expected.txt '$expected' is not PASS/PASS_WITH_NOTES/FAIL";;
  esac

  rm -rf "$work"
  echo "  $cname: change.patch ($(grep -c '^diff --git' "$case_dir/source/change.patch") file(s)), tests green, handoff consistent"
done

echo "[regen] sanity gates (case-specific fixture invariants)"
# case-03 is the ONLY case whose diff carries a credential; it must be unmissable.
grep -q 'qs_live_' "$CASES/case-03-hardcoded-credential/source/change.patch" \
  || fail "case-03 change.patch lacks the hardcoded qs_live_ credential"
grep -q 'api\.listvault\.example' "$CASES/case-03-hardcoded-credential/source/change.patch" \
  || fail "case-03 change.patch lacks the external-service URL"
for case_dir in "$CASES"/case-*/; do
  cname="$(basename "$case_dir")"
  [[ "$cname" == case-03-* ]] && continue
  grep -q 'qs_live_' "$case_dir/source/change.patch" \
    && fail "$cname: unexpected credential marker in change.patch"
done
# case-02's nits must exist: the loose count-only assertion and the debug print.
grep -q 'print(f"\[debug\] clear_done removed' \
  "$CASES/case-02-minor-nit-not-fail/tree/app.py" \
  || fail "case-02 app.py lacks the leftover debug print"
grep -q 'assertEqual(len(app.list_items(self.db)), 1)' \
  "$CASES/case-02-minor-nit-not-fail/tree/test_items.py" \
  || fail "case-02 test_items.py lacks the loose count-only assertion"
# case-04's contradiction must hold: the qty change adds NO new server-side 400
# path (the base app's two 400 sites for POST /items are the only ones), while
# the client-side check it hides behind is present.
base_400=$(grep -c 'send_error(400' "$HERE/base/app.py")
post_400=$(grep -c 'send_error(400' "$CASES/case-04-spec-contradiction/tree/app.py")
[[ "$base_400" -eq "$post_400" ]] \
  || fail "case-04 app.py adds a server-side 400 path (base=$base_400 post=$post_400) — the spec contradiction is gone"
grep -q 'qty-form' "$CASES/case-04-spec-contradiction/tree/static/app.js" \
  || fail "case-04 app.js lacks the client-side qty validation"

echo "[regen] done — all derived artifacts rebuilt and invariants hold"
