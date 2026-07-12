#!/usr/bin/env bash
# harvest-lessons.sh — EVO-5: cross-project lesson harvesting (read-only digest).
#
# For each repo path given, prints a per-repo grouped digest of what its
# goal-mode sessions left behind:
#   1. sessions       — the halt-relevant line of every
#                       runs/goal-session-*/session.json
#                       (status · last_verdict · current_iter)
#   2. lessons tails  — the last 20 lines of every
#                       runs/goal-session-*/state/lessons.md
#   3. retro reports  — paths of reports/goal-session-*-retro.md when present
#                       (EVO-2-era extension: retro proposals surface in the
#                       digest alongside the lessons they grew from)
#
# READ-ONLY AND JUDGMENT-FREE by contract (roadmap EVO-5): the script writes
# nothing anywhere and draws no conclusions — it is a digest for a human+session
# to review. Recurring symptoms across repos become either numbered
# .claude/anti-patterns.md entries (maintenance protocol §2 format: symptom →
# root cause → checkable rule) or docs/improvement-roadmap.md §16 staging items,
# drafted by the reviewing session and promoted only by the human (EVO-1).
#
# Graceful on everything: a missing runs/, zero sessions, absent lessons.md,
# unreadable session.json, or a nonexistent repo argument all yield labeled
# empty sections — the script always exits 0 once past argument parsing.
#
# Usage:
#   ./scripts/automation/harvest-lessons.sh <repo-path>...
#
# Exit codes: 0 digest printed (including all-empty digests); 2 usage error.
#
# Procedure: see the EVO-5 entry in docs/improvement-roadmap.md — quarterly or
# after each delivered project, run this over the known adopter repos.
set -euo pipefail

TAIL_LINES=20

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//'; }

if [[ $# -eq 0 ]]; then
  echo "usage: $0 <repo-path>...   (--help for details)" >&2
  exit 2
fi
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

# One "status=… last_verdict=… current_iter=…" line from a session.json.
# Prints the literal values (no interpretation); unreadable/misshapen files
# become the house "unknown (<why>)" convention. Always exits 0.
session_line() {
  HARVEST_SESSION_JSON="$1" python3 - <<'PYEOF'
import json, os
path = os.environ["HARVEST_SESSION_JSON"]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"unknown (session.json unreadable: {type(e).__name__})")
    raise SystemExit(0)
if not isinstance(data, dict):
    print("unknown (session.json is not a JSON object)")
    raise SystemExit(0)
def field(key):
    v = data.get(key)
    return "absent" if v is None else v
print(f"status={field('status')} last_verdict={field('last_verdict')} "
      f"current_iter={field('current_iter')}")
PYEOF
}

first_repo=true
for repo in "$@"; do
  $first_repo || echo
  first_repo=false

  echo "================================================================================"
  if [[ ! -d "$repo" ]]; then
    echo "[harvest] repo: $repo"
    echo "================================================================================"
    echo "  (not a directory — skipped)"
    continue
  fi
  abs="$(cd "$repo" && pwd -P)"
  echo "[harvest] repo: $abs"
  echo "================================================================================"

  # Session dirs, deterministically ordered regardless of locale.
  sessions=()
  if [[ -d "$abs/runs" ]]; then
    while IFS= read -r _d; do
      [[ -n "$_d" ]] && sessions+=("$_d")
    done < <(find "$abs/runs" -mindepth 1 -maxdepth 1 -type d \
                  -name 'goal-session-*' 2>/dev/null | LC_ALL=C sort)
  fi

  echo ""
  echo "-- sessions (runs/goal-session-*/session.json: status · last_verdict · current_iter) --"
  if [[ ! -d "$abs/runs" ]]; then
    echo "  (runs/ absent — no goal-mode sessions recorded)"
  elif [[ ${#sessions[@]} -eq 0 ]]; then
    echo "  (no runs/goal-session-* directories)"
  else
    for d in "${sessions[@]}"; do
      if [[ -f "$d/session.json" ]]; then
        echo "  $(basename "$d"): $(session_line "$d/session.json")"
      else
        echo "  $(basename "$d"): unknown (session.json missing)"
      fi
    done
  fi

  echo ""
  echo "-- lessons tails (runs/goal-session-*/state/lessons.md, last $TAIL_LINES lines each) --"
  found_lessons=false
  if [[ ${#sessions[@]} -gt 0 ]]; then
    for d in "${sessions[@]}"; do
      f="$d/state/lessons.md"
      [[ -f "$f" ]] || continue
      found_lessons=true
      echo "  == $(basename "$d") =="
      tail -n "$TAIL_LINES" "$f" | sed 's/^/  | /'
    done
  fi
  $found_lessons || echo "  (no lessons.md files found)"

  echo ""
  echo "-- retro reports (reports/goal-session-*-retro.md) --"
  retros=()
  if [[ -d "$abs/reports" ]]; then
    while IFS= read -r _f; do
      [[ -n "$_f" ]] && retros+=("$_f")
    done < <(find "$abs/reports" -mindepth 1 -maxdepth 1 -type f \
                  -name 'goal-session-*-retro.md' 2>/dev/null | LC_ALL=C sort)
  fi
  if [[ ${#retros[@]} -eq 0 ]]; then
    echo "  (none found)"
  else
    for f in "${retros[@]}"; do
      echo "  ${f#"$abs/"}"
    done
  fi
done

exit 0
