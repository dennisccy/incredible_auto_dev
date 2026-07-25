#!/usr/bin/env bash
# condense.sh — deterministic condensation for append-only markdown state files
# (maintenance protocol §4). NO model calls, ever: entries are moved VERBATIM by
# line-oriented rules; nothing is summarized, paraphrased, or deleted. LLM
# semantic condensation was explicitly rejected for these files (rule-loss risk,
# roadmap TOKEN-6) — do not add it here.
#
# WHAT AN "ENTRY" IS (grounded in protocol §2 and the shipped formats):
#   a block starting at an unfenced `## ` heading whose heading carries an
#   integer age key, in one of the real formats this repo writes:
#     ## iter-<N> — <ISO timestamp>     state/lessons.md      (evaluator body §5)
#     ## iter-<N> — <agent>             state/assumptions.md  (evaluator body §5b)
#     ## Iteration <N> — <phase>        iteration-keyed logs
#     ## <N>. <title>                   numbered-entry style (the retired
#                                       anti-patterns monolith; now a per-entry
#                                       tree at .claude/anti-patterns/, which
#                                       never needs condensing)
#   A block runs to the next unfenced `## ` heading or EOF. Everything before
#   the first `## ` heading (title/preamble) is never touched. `## ` lines
#   inside ``` fences are content, not boundaries (entries may quote goal.md
#   sections inside fences).
#
# WHAT MOVES: blocks whose key is NOT among the newest KEEP distinct keys in the
# file (default 5; --keep N or CHAIN_CONDENSE_KEEP_ITERS) are appended VERBATIM
# to <file>.archive.md beside the file. The archive is append-only and is never
# overwritten. Runs only when the file exceeds --min-lines (default 200 — §4's
# "~200 lines" mandate; CHAIN_CONDENSE_MIN_LINES); otherwise a no-op.
#
# WHAT NEVER LEAVES THE LIVE FILE (the whole point — §4.1 "keep the rule, drop
# the retelling"): lines matching the protocol §2 rule-class formats stay in
# place under a `[condensed: ...]` heading stub, regardless of age:
#     **Rule:** ...        **Prevention:** ...
#     **Applies to:** ...  **AGENT RULE — <title>:** ...
#   (+ each tag's continuation lines up to a blank line / next **tag / heading /
#   fence). The full original block — rules included — still goes to the
#   archive, so nothing is ever lost. Keyless `## ` blocks and malformed lines
#   are tolerated: kept in place with one warning, never guessed at, never moved.
#
# STRUCTURAL GUARDS (not knob-dependent):
#   - any path under .claude/ is REFUSED unless --human is passed. Protocol §4
#     rule 2: .claude/ knowledge files condense only in a dedicated,
#     human-triggered commit. The engine NEVER passes --human.
#   - evaluator-log.md and journey-history.json are ALWAYS refused (§4 rule 3:
#     chronological records — never condensed), --human included.
#   - only .md files are accepted.
#
# Usage:
#   condense.sh [--keep N] [--min-lines N] [--human] <file.md>
#   condense.sh --self-test
# Exit codes: 0 = success or no-op · 2 = refused by a guard · 1 = error
#
# Idempotent: a second run over the same file moves nothing (surviving stubs are
# marked `[condensed:` and are never candidates again; remaining entries are
# within the newest-K window).

set -euo pipefail

usage() { sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

KEEP="${CHAIN_CONDENSE_KEEP_ITERS:-5}"
MIN_LINES="${CHAIN_CONDENSE_MIN_LINES:-200}"
HUMAN="false"
SELF_TEST="false"
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)      KEEP="${2:?--keep needs a value}"; shift 2 ;;
    --min-lines) MIN_LINES="${2:?--min-lines needs a value}"; shift 2 ;;
    --human)     HUMAN="true"; shift ;;
    --self-test) SELF_TEST="true"; shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          echo "[condense] unknown flag: $1" >&2; exit 1 ;;
    *)           TARGET="$1"; shift ;;
  esac
done

# ── Core ────────────────────────────────────────────────────────────────────
_condense_main() {
  local target="$1" base resolved archive ts

  [[ "$KEEP" =~ ^[0-9]+$ && "$KEEP" -ge 1 ]] \
    || { echo "[condense] --keep must be a positive integer (got '$KEEP')" >&2; return 1; }
  [[ "$MIN_LINES" =~ ^[0-9]+$ ]] \
    || { echo "[condense] --min-lines must be a non-negative integer (got '$MIN_LINES')" >&2; return 1; }
  [[ -f "$target" ]] || { echo "[condense] not a file: $target" >&2; return 1; }

  base="$(basename "$target")"
  # §4 rule 3: chronological records are NEVER condensed — not even by a human run.
  case "$base" in
    evaluator-log.md|journey-history.json)
      echo "[condense] REFUSED: $base is a chronological record (protocol §4 rule 3) — never condensed." >&2
      return 2 ;;
  esac
  [[ "$base" == *.md ]] \
    || { echo "[condense] REFUSED: only markdown knowledge files are condensable (got $base)." >&2; return 2; }

  # §4 rule 2 hard guard: .claude/ knowledge files condense only in a dedicated
  # human-triggered commit. The engine NEVER passes --human.
  resolved="$(realpath "$target" 2>/dev/null || readlink -f "$target")"
  if [[ "$resolved" == */.claude/* && "$HUMAN" != "true" ]]; then
    echo "[condense] REFUSED: $target is under .claude/ — condense it only in a dedicated" >&2
    echo "  human-triggered commit (maintenance protocol §4 rule 2): re-run with --human." >&2
    return 2
  fi

  archive="${target}.archive.md"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  python3 - "$target" "$archive" "$KEEP" "$MIN_LINES" "$ts" <<'PYCORE'
import os, re, sys, tempfile

target, archive, keep, min_lines, ts = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]

with open(target, encoding="utf-8", errors="replace") as f:
    lines = f.read().splitlines()
total = len(lines)
if total <= min_lines:
    print(f"[condense] {target}: {total} lines <= threshold {min_lines} — nothing to do (no-op)")
    sys.exit(0)

# The shipped heading formats (see header): iter-<N>, Iteration <N>, <N>.
HEAD_KEY = re.compile(r"^##\s+(?:iter-(\d+)\b|Iteration\s+(\d+)\b|(\d+)\.(?:\s|$))")
# Protocol §2 rule-class tags — these lines never leave the live file.
RULE = re.compile(r"^\*\*(?:Rule|Prevention|Applies to|AGENT RULE)[^*]*:\*\*")
FENCE = re.compile(r"^\s{0,3}```")

def head_key(line):
    m = HEAD_KEY.match(line)
    return int(next(g for g in m.groups() if g is not None)) if m else None

# Split into preamble + heading blocks, fence-aware.
blocks, warns = [], []
cur = {"head": None, "key": None, "stub": False, "lines": []}
in_fence = False
for i, ln in enumerate(lines, 1):
    if FENCE.match(ln):
        in_fence = not in_fence
        cur["lines"].append(ln)
        continue
    if not in_fence and ln.startswith("## "):
        blocks.append(cur)
        k = head_key(ln)
        if k is None and "[condensed:" not in ln:
            warns.append(f"line {i}: unrecognized '## ' heading ({ln[:60]!r}) — block kept in place")
        cur = {"head": ln, "key": k, "stub": "[condensed:" in ln, "lines": [ln]}
    else:
        cur["lines"].append(ln)
blocks.append(cur)
if in_fence:
    warns.append("unclosed ``` fence at EOF — headings after it were treated as fenced content")

keys = sorted({b["key"] for b in blocks if b["key"] is not None}, reverse=True)
keep_keys = set(keys[:keep])
candidates = [b for b in blocks
              if b["key"] is not None and not b["stub"] and b["key"] not in keep_keys]

def split_rules(body):
    """Rule segments (tag line + continuation up to blank/**tag/heading/fence),
    fence-aware so quoted examples are not mistaken for live rules."""
    segs, in_f, i = [], False, 0
    while i < len(body):
        ln = body[i]
        if FENCE.match(ln):
            in_f = not in_f; i += 1; continue
        if not in_f and RULE.match(ln):
            seg = [ln]; i += 1
            while i < len(body):
                nxt = body[i]
                if not nxt.strip() or nxt.startswith("**") or nxt.startswith("#") or FENCE.match(nxt):
                    break
                seg.append(nxt); i += 1
            segs.append(seg)
        else:
            i += 1
    return segs

moved_keys, rule_lines_kept, out_chunks, archive_chunks = [], 0, [], []
cand_ids = {id(b) for b in candidates}
for b in blocks:
    if id(b) not in cand_ids:
        out_chunks.append(b["lines"])
        continue
    rules = split_rules(b["lines"][1:])
    archive_chunks.append(list(b["lines"]))
    moved_keys.append(b["key"])
    if rules:
        stub = [b["head"].rstrip() + f"  [condensed: body → {os.path.basename(archive)}]"]
        for seg in rules:
            stub.extend(seg)
            rule_lines_kept += len(seg)
        stub.append("")
        out_chunks.append(stub)

if not moved_keys:
    print(f"[condense] {target}: {total} lines, all {len(keys)} entry keys within the newest {keep} — nothing to move (no-op)")
    for w in warns:
        print(f"[condense] WARN: {w}", file=sys.stderr)
    sys.exit(0)

# Archive first (append-only; header only on creation), then atomically replace
# the live file — a failure between the two duplicates into the archive at
# worst; it never loses content.
new_archive = not os.path.exists(archive)
with open(archive, "a", encoding="utf-8") as f:
    if new_archive:
        f.write(f"# {os.path.basename(target)} — archive\n\n"
                f"Entries moved out of `{os.path.basename(target)}` by "
                f"scripts/automation/lib/condense.sh (maintenance protocol §4).\n"
                f"Append-only: nothing here is ever deleted or rewritten.\n")
    f.write(f"\n<!-- condense.sh {ts}: moved {len(moved_keys)} entries (keep-iters={keep}) -->\n\n")
    for chunk in archive_chunks:
        while chunk and not chunk[-1].strip():
            chunk.pop()
        f.write("\n".join(chunk) + "\n\n")

out_lines = [ln for chunk in out_chunks for ln in chunk]
new_text = "\n".join(out_lines).rstrip("\n") + "\n"
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(target)) or ".", suffix=".condense-tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(new_text)
    os.replace(tmp, target)
except BaseException:
    os.unlink(tmp)
    raise

after = new_text.count("\n")
mk = sorted(set(moved_keys))
print(f"[condense] {target}: moved {len(moved_keys)} entries (keys {mk[0]}..{mk[-1]}) → {archive}; "
      f"kept {rule_lines_kept} rule line(s) in place; lines {total} → {after}")
for w in warns:
    print(f"[condense] WARN: {w}", file=sys.stderr)
PYCORE
}

# ── Self-test (embedded fixtures; run: condense.sh --self-test) ─────────────
_condense_self_test() {
  local td fails=0 rc out err live archive snap_live snap_arch
  td="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand now: td is a function-local, gone at trap time
  trap "rm -rf '$td'" EXIT
  err="$td/err"

  _run() { rc=0; out="$(bash "${BASH_SOURCE[0]}" "$@" 2>"$err")" || rc=$?; }

  # Fixture A — lessons.md-style, >200 lines, mixed ages, ONE buried old rule.
  live="$td/lessons.md"
  {
    printf '# Goal Session x — Lessons Learned\n\nAppend-only ledger (preamble).\n\n'
    printf '## iter-1 — 2026-06-01T00:00:00Z\n\n'
    printf '**Verdict:** CONTINUE\n'
    printf '**Lesson:** buried lesson one; the retelling that should be archived.\n'
    printf '**Applies to:** any iter touching auth middleware (BURIED-RULE-SENTINEL)\n\n'
    local i
    for i in $(seq 2 58); do
      printf '## iter-%s — 2026-06-01T00:00:00Z\n\n**Verdict:** CONTINUE\n**Lesson:** routine lesson %s.\n\n' "$i" "$i"
    done
  } > "$live"

  # 1. mixed-age entries: old ones move, newest 5 iterations stay.
  _run "$live"
  if [[ "$rc" -eq 0 ]] \
     && grep -q '^## iter-58 ' "$live" && grep -q '^## iter-54 ' "$live" \
     && ! grep -q '^## iter-53 ' "$live" \
     && ! grep -q 'buried lesson one' "$live" \
     && grep -q '^## iter-53 ' "$live.archive.md" \
     && grep -q 'buried lesson one' "$live.archive.md" \
     && [[ "$(grep -c '^## iter-' "$live.archive.md")" -eq 53 ]] \
     && printf '%s' "$out" | grep -q 'moved 53 entries'; then
    echo "  PASS condense: mixed ages → 53 old entries archived, newest 5 iterations kept live"
  else
    echo "  FAIL condense: mixed-age move (rc=$rc, out=$out)"; fails=1
  fi

  # 2. the buried old rule survives IN the live file (heading stub marked).
  if grep -q 'BURIED-RULE-SENTINEL' "$live" \
     && grep -q '^## iter-1 .*\[condensed:' "$live" \
     && grep -q 'BURIED-RULE-SENTINEL' "$live.archive.md"; then
    echo "  PASS condense: buried old rule (**Applies to:**) survives live under a [condensed:] stub"
  else
    echo "  FAIL condense: buried rule lost (live=$(grep -c 'BURIED-RULE-SENTINEL' "$live"))"; fails=1
  fi

  # 6. idempotency: an immediate second run moves nothing and changes no byte.
  snap_live="$td/snap-live"; snap_arch="$td/snap-arch"
  cp "$live" "$snap_live" 2>/dev/null || :
  cp "$live.archive.md" "$snap_arch" 2>/dev/null || :
  _run --min-lines 0 "$live"
  if [[ "$rc" -eq 0 ]] && cmp -s "$live" "$snap_live" && cmp -s "$live.archive.md" "$snap_arch" \
     && printf '%s' "$out" | grep -q 'nothing to move'; then
    echo "  PASS condense: second run is a byte-identical no-op (idempotent)"
  else
    echo "  FAIL condense: idempotency (rc=$rc, out=$out)"; fails=1
  fi

  # 3. malformed lines: keyless '## ' block tolerated, kept in place, one warn.
  live="$td/assumptions.md"
  {
    printf '# Assumptions\n\nstray preamble prose kept as-is\n\n'
    printf '## totally unkeyed heading\n\nkeyless content that must stay (KEYLESS-SENTINEL)\n\n'
    local i
    for i in $(seq 1 7); do
      printf '## iter-%s — goal-evaluator\n\n**Ambiguity:** a%s\n**We chose:** c%s\n**Reversible:** yes\n\n' "$i" "$i" "$i"
    done
  } > "$live"
  _run --min-lines 0 "$live"
  if [[ "$rc" -eq 0 ]] \
     && grep -q 'KEYLESS-SENTINEL' "$live" && grep -q '^## totally unkeyed heading' "$live" \
     && grep -q 'unrecognized' "$err" \
     && ! grep -q '^## iter-1 ' "$live" && grep -q '^## iter-1 ' "$live.archive.md" \
     && grep -q '^## iter-3 ' "$live"; then
    echo "  PASS condense: malformed/keyless block kept in place with a warning; keyed old entries still move"
  else
    echo "  FAIL condense: malformed tolerance (rc=$rc, err=$(cat "$err"))"; fails=1
  fi

  # 4. under-threshold file (default 200): byte-identical no-op, no archive.
  live="$td/short.md"
  printf '# Short\n\n## iter-1 — x\n\nold but the file is tiny\n' > "$live"
  _run "$live"
  if [[ "$rc" -eq 0 ]] && grep -q 'old but the file is tiny' "$live" \
     && [[ ! -e "$live.archive.md" ]] && printf '%s' "$out" | grep -q 'nothing to do'; then
    echo "  PASS condense: file under 200 lines → no-op, no archive created"
  else
    echo "  FAIL condense: under-threshold no-op (rc=$rc, out=$out)"; fails=1
  fi

  # 5. .claude/ hard guard: refused without --human; accepted with it.
  mkdir -p "$td/.claude"
  live="$td/.claude/knowledge.md"
  {
    printf '# K\n\n'
    local i
    for i in $(seq 1 7); do printf '## iter-%s — x\n\nbody %s\n\n' "$i" "$i"; done
  } > "$live"
  cp "$live" "$td/snap-claude"
  _run --min-lines 0 "$live"
  local rc_refused=$rc
  local refused_ok=0
  if [[ "$rc_refused" -eq 2 ]] && cmp -s "$live" "$td/snap-claude" && [[ ! -e "$live.archive.md" ]] \
     && grep -q 'human' "$err"; then refused_ok=1; fi
  _run --min-lines 0 --human "$live"
  if [[ "$refused_ok" -eq 1 && "$rc" -eq 0 ]] && grep -q '^## iter-1 ' "$live.archive.md"; then
    echo "  PASS condense: .claude/ path refused (exit 2, untouched) without --human; runs with it"
  else
    echo "  FAIL condense: .claude/ guard (refused rc=$rc_refused ok=$refused_ok, human rc=$rc)"; fails=1
  fi

  # 7. chronological records are refused even with --human (§4 rule 3).
  live="$td/evaluator-log.md"
  printf '# L\n\n## Iteration 1 — x\n\nrow\n' > "$live"
  _run --min-lines 0 --human "$live"
  local rc_eval=$rc
  live="$td/journey-history.json"
  printf '{}\n' > "$live"
  _run --min-lines 0 --human "$live"
  if [[ "$rc_eval" -eq 2 && "$rc" -eq 2 ]]; then
    echo "  PASS condense: evaluator-log.md / journey-history.json always refused (chronological records)"
  else
    echo "  FAIL condense: never-condense guard (evaluator-log rc=$rc_eval, journey rc=$rc)"; fails=1
  fi

  # 8. archives are appended to, never overwritten.
  live="$td/appendix.md"
  {
    printf '# A\n\n'
    local i
    for i in $(seq 1 7); do printf '## iter-%s — x\n\nbody %s\n\n' "$i" "$i"; done
  } > "$live"
  printf 'PRE-EXISTING-ARCHIVE-SENTINEL\n' > "$live.archive.md"
  _run --min-lines 0 "$live"
  if [[ "$rc" -eq 0 ]] && [[ "$(head -1 "$live.archive.md")" == "PRE-EXISTING-ARCHIVE-SENTINEL" ]] \
     && grep -q '^## iter-1 ' "$live.archive.md"; then
    echo "  PASS condense: existing archive preserved — new entries appended after it"
  else
    echo "  FAIL condense: archive append (rc=$rc, head=$(head -1 "$live.archive.md" 2>/dev/null))"; fails=1
  fi

  # 9. '## ' headings and rule tags inside ``` fences are content, not entries.
  live="$td/fenced.md"
  {
    printf '# F\n\n'
    local i
    for i in $(seq 1 7); do printf '## iter-%s — x\n\nbody %s\n\n' "$i" "$i"; done
    printf '## iter-9 — x\n\nquoted example:\n\n```\n## iter-1 — fake heading inside fence\n**Rule:** fenced fake rule\n```\n\nafter the fence\n\n'
  } > "$live"
  _run --min-lines 0 "$live"
  if [[ "$rc" -eq 0 ]] \
     && grep -q '^## iter-1 — fake heading inside fence' "$live" \
     && grep -q 'fenced fake rule' "$live" \
     && [[ "$(grep -c '^## iter-' "$live.archive.md")" -eq 3 ]] \
     && printf '%s' "$out" | grep -q 'kept 0 rule'; then
    echo "  PASS condense: fenced '## ' headings / rule tags treated as content (3 real entries moved)"
  else
    echo "  FAIL condense: fence awareness (rc=$rc, out=$out, archived=$(grep -c '^## iter-' "$live.archive.md" 2>/dev/null))"; fails=1
  fi

  if [[ "$fails" -eq 0 ]]; then echo "condense self-test: OK"; else echo "condense self-test: FAILURES"; exit 1; fi
}

if [[ "$SELF_TEST" == "true" ]]; then
  _condense_self_test
  exit 0
fi

[[ -n "$TARGET" ]] || { echo "[condense] usage: condense.sh [--keep N] [--min-lines N] [--human] <file.md>  (or --self-test)" >&2; exit 1; }
_condense_main "$TARGET"
