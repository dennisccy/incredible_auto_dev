#!/usr/bin/env bash
# permission-oracle.sh — native-alignment probe for hooks/lib/read_path_hygiene.py.
# Operator-run; spends one small Haiku call per manifest entry (G9). Runs ONLY inside a
# throwaway sandbox tree of dummy files; mutation fixtures are safe if they unexpectedly
# execute. The probe list is `read_path_hygiene.py --oracle-manifest` (one source, no drift).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/iad-oracle.XXXXXX")"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/apps/backend/tests" "$SB/apps/backend/app" "$SB/docs"
printf 'a = 1\n' > "$SB/apps/backend/app/main.py"
printf 'a = 1\n' > "$SB/apps/backend/tests/test_x.py"
printf 'scratch\n' > "$SB/apps/backend/tests/scratch.txt"
printf '# goal\n' > "$SB/docs/goal.md"
printf 'DUMMY=1\n' > "$SB/.env"                      # lets the user-level Read(**/.env) deny rule apply
git -C "$SB" init -q && git -C "$SB" add -A && git -C "$SB" -c user.email=o@x -c user.name=o commit -qm init
mapfile -t ALLOW < <(jq -r '.permissions.allow[]' "$REPO_ROOT/.claude/settings.json")
probe() {   # $1 id  $2 command  → "<id> NATIVE_ASK|native_allow|INCONCLUSIVE <command>"
  local out
  out=$(cd "$SB" && claude -p --model haiku --max-turns 2 --permission-mode dontAsk \
        --settings '{"disableAllHooks":true}' --allowedTools "${ALLOW[@]}" --output-format json \
        "Run exactly this Bash command once, then stop. Do not modify it and do not run anything else: $2" 2>/dev/null || true)
  if printf '%s' "$out" | jq -e '(.permission_denials // []) | length > 0' >/dev/null 2>&1; then echo "$1 NATIVE_ASK   $2"
  elif printf '%s' "$out" | jq -e '.num_turns' >/dev/null 2>&1; then echo "$1 native_allow $2"
  else echo "$1 INCONCLUSIVE $2"; fi
}
while IFS=$'\t' read -r oid cmd; do
  probe "$oid" "${cmd//\{SB\}/$SB}"
done < <(python3 "$REPO_ROOT/hooks/lib/read_path_hygiene.py" --oracle-manifest)
