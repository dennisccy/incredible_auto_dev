#!/usr/bin/env bash
# suggest-allowlist.sh — evidence loop for the supply-chain install gate (SEC-6).
#
# The install gate logs every decision to reports/security/install-decisions.jsonl.
# This read-only helper aggregates the warn/require_approval/block records and
# prints ready-to-paste allowlist additions for config/install-security-policy.json,
# so the allowlist grows from real project evidence instead of guesswork.
#
# Usage:
#   ./scripts/automation/suggest-allowlist.sh [--log <path>] [--top N]
#   ./scripts/automation/suggest-allowlist.sh --transcripts   # also scan ~/.claude transcripts for gate banners
#   ./scripts/automation/suggest-allowlist.sh --self-test
#
# Read-only: never edits the policy. Suggestions exclude direct-URL and denylist
# findings (those are blocked by design, never allowlist candidates).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

LOG_PATH="$REPO_ROOT/reports/security/install-decisions.jsonl"
POLICY_PATH="$REPO_ROOT/config/install-security-policy.json"
TOP_N=20
DO_TRANSCRIPTS=false
DO_SELF_TEST=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log) LOG_PATH="$2"; shift 2 ;;
    --top) TOP_N="$2"; shift 2 ;;
    --transcripts) DO_TRANSCRIPTS=true; shift ;;
    --self-test) DO_SELF_TEST=true; shift ;;
    *) echo "unknown arg: $1 (usage: [--log <path>] [--top N] [--transcripts] [--self-test])" >&2; exit 64 ;;
  esac
done

suggest_from_log() {
  local log="$1" policy="$2" top="$3"
  python3 - "$log" "$policy" "$top" <<'PY'
import json, sys
from collections import Counter

log_path, policy_path, top_n = sys.argv[1], sys.argv[2], int(sys.argv[3])

try:
    with open(policy_path) as f:
        policy = json.load(f)
except OSError:
    policy = {}
allow = {
    "pypi": {n.lower() for n in policy.get("python", {}).get("allowlist", [])},
    "npm": {n.lower() for n in policy.get("npm", {}).get("allowlist", [])},
}
deny = {
    "pypi": {(e.get("package") or "").lower() for e in policy.get("python", {}).get("denylist", [])},
    "npm": {(e.get("package") or "").lower() for e in policy.get("npm", {}).get("denylist", [])},
}

counts = Counter()
candidates = {"pypi": Counter(), "npm": Counter()}
try:
    lines = open(log_path).read().splitlines()
except OSError:
    print(f"no decisions logged yet ({log_path} missing) - nothing to suggest.")
    sys.exit(0)

for line in lines:
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except json.JSONDecodeError:
        continue
    dec = rec.get("decision", "unknown")
    counts[dec] += 1
    if dec not in ("warn", "require_approval", "block"):
        continue
    st = rec.get("source_type")
    if st not in candidates:
        continue  # url / git / unknown records are never allowlist candidates
    for pkg in rec.get("packages", []):
        name = (pkg.get("name") or "").strip()
        if not name or pkg.get("direct_url"):
            continue  # never suggest allowlisting a URL
        low = name.lower()
        if low in allow[st] or low in deny[st]:
            continue
        candidates[st][low] += 1

print("decision counts:")
for dec in ("allow", "warn", "require_approval", "block"):
    print(f"  {dec:17s} {counts.get(dec, 0)}")
print()
labels = {"pypi": "python", "npm": "npm"}
any_suggested = False
for st, label in labels.items():
    top = [n for n, _ in candidates[st].most_common(top_n)]
    if not top:
        continue
    any_suggested = True
    print(f'"{label}": {{"allowlist_additions": {json.dumps(top)}}}')
if not any_suggested:
    print("no new allowlist candidates (every flagged package is already listed or URL/denylisted).")
PY
}

scan_transcripts() {
  # Project transcript dir: $PWD with '/' -> '-' (Claude Code convention).
  # Best-effort: transcripts also embed the hook SOURCE, whose lines contain the
  # literal $COMMAND placeholder — those are filtered out.
  local slug dir
  slug="$(pwd | tr '/' '-')"
  dir="$HOME/.claude/projects/$slug"
  if [[ ! -d "$dir" ]]; then
    echo "no transcript dir at $dir"
    return 0
  fi
  echo "gate banners in the 20 newest transcripts under $dir:"
  ls -t "$dir"/*.jsonl 2>/dev/null | head -20 \
    | xargs -r grep -h -oE '(APPROVAL REQUIRED|SUPPLY CHAIN SECURITY POLICY|Command: [^"\\]{1,120})' 2>/dev/null \
    | grep -vF '$COMMAND' | sort | uniq -c | sort -rn | head -30 || true
}

self_test() {
  local t
  t="$(mktemp -d "${TMPDIR:-/tmp}/suggest-allowlist.XXXXXX")"
  # Hermetic fixture policy: empty allowlists so live seeding never masks candidates.
  cat > "$t/policy.json" <<'EOF'
{"python": {"allowlist": [], "denylist": []}, "npm": {"allowlist": [], "denylist": []}}
EOF
  cat > "$t/decisions.jsonl" <<'EOF'
{"decision":"require_approval","source_type":"pypi","packages":[{"name":"yfinance","pinned":false,"direct_url":false}]}
{"decision":"warn","source_type":"npm","packages":[{"name":"lightweight-charts","pinned":true,"direct_url":false}]}
{"decision":"block","source_type":"url","packages":[{"name":"https://evil.example.com/x.whl","pinned":false,"direct_url":true}]}
{"decision":"allow","source_type":"pypi","packages":[{"name":"fastapi","pinned":true,"direct_url":false}]}
EOF
  local out rc=0
  out="$(suggest_from_log "$t/decisions.jsonl" "$t/policy.json" 20)"
  if grep -q "yfinance" <<<"$out" && grep -q "lightweight-charts" <<<"$out" \
     && ! grep -q "evil.example.com" <<<"$out"; then
    echo "self-test OK"
  else
    echo "self-test FAILED — output was:" >&2
    echo "$out" >&2
    rc=1
  fi
  rm -rf "$t"
  return "$rc"
}

if $DO_SELF_TEST; then
  self_test
  exit $?
fi

suggest_from_log "$LOG_PATH" "$POLICY_PATH" "$TOP_N"
if $DO_TRANSCRIPTS; then
  echo
  scan_transcripts
fi
