#!/usr/bin/env bash
# retro_collect.sh — deterministic session-retro evidence collector (EVO-2 slice a).
#
# Usage: retro_collect.sh <session-dir> <terminal-status>
#
# Freezes end-of-session evidence into <session-dir>/state/retro-input.md so the
# retro drafting agent (EVO-2 slice b) can propose framework improvements from
# ONE self-contained file. run-goal.sh's write_session_summary invokes this as a
# subprocess on TERMINAL halts only (GOAL_ACHIEVED | STALLED | REGRESSION_HALT |
# BUDGET_EXHAUSTED), guarded by CHAIN_SESSION_RETRO and non-blocking (`|| ...`).
# Note: ABORT_MALFORMED halts arrive at that choke point as status "ABORTED"
# (run-goal.sh halt switch), indistinguishable from Ctrl-C — so they do NOT get
# a retro in slice (a).
#
# Contract:
#   - Deterministic: pure read/format of existing artifacts. No model dispatch.
#   - Every number cites a real source (telemetry.jsonl, session.json,
#     state/*.md, iter-*/ markers). A counter with no reliable source is the
#     literal `unknown (<why>)` — never a guess.
#   - Missing inputs degrade to explicit "none recorded" lines; still exit 0.
#   - Writes ONLY <session-dir>/state/retro-input.md; never mutates its inputs.
#   - Exits nonzero only for unusable arguments (missing/invalid session dir).
#
# Section layout is a STABLE contract — slice (b)'s agent reads only this file.
# Do not rename or reorder the `## ` headers without updating that consumer.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SESSION_DIR="${1:-}"
TERMINAL_STATUS="${2:-unknown}"

if [[ -z "$SESSION_DIR" || ! -d "$SESSION_DIR" ]]; then
  echo "[retro-collect] Usage: retro_collect.sh <session-dir> <terminal-status> (got: '${SESSION_DIR:-}')" >&2
  exit 2
fi

TELEMETRY="$SESSION_DIR/telemetry.jsonl"
SESSION_JSON="$SESSION_DIR/session.json"
LESSONS_FILE="$SESSION_DIR/state/lessons.md"
OUT="$SESSION_DIR/state/retro-input.md"
mkdir -p "$SESSION_DIR/state"

# Read one scalar field out of session.json; prints nothing when the file or
# the key is absent (callers substitute their own `unknown (<why>)` text).
_sj() {
  python3 -c "
import json, sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception:
    sys.exit(0)
print('' if v is None else v)
" "$SESSION_JSON" "$1" 2>/dev/null || true
}

_sid="$(_sj session_id)"
[[ -z "$_sid" ]] && { _sid="$(basename "$SESSION_DIR")"; _sid="${_sid#goal-session-}"; }

# ── Outcome fields ────────────────────────────────────────────────────────────
_final_verdict="$(_sj last_verdict)"
[[ -z "$_final_verdict" ]] && _final_verdict="unknown (last_verdict absent from session.json)"
_iters="$(_sj total_iterations)"
[[ -z "$_iters" ]] && _iters="$(_sj current_iter)"
[[ -z "$_iters" ]] && _iters="unknown (total_iterations/current_iter absent from session.json)"
_halted_at="$(_sj finished_at)"
[[ -z "$_halted_at" ]] && _halted_at="unknown (finished_at absent from session.json)"

# ── Verdict sequence ──────────────────────────────────────────────────────────
# Primary source: telemetry iter_end events (FINAL post-gate verdicts).
# Fallback: iter-*/.evaluated markers (raw pre-gate verdicts, labeled as such).
_verdict_seq=""
_verdict_src=""
if [[ -f "$TELEMETRY" ]]; then
  _verdict_seq="$(python3 -c "
import json, sys
out = []
for raw in open(sys.argv[1], encoding='utf-8'):
    raw = raw.strip()
    if not raw:
        continue
    try:
        e = json.loads(raw)
    except Exception:
        continue
    if e.get('event') != 'iter_end':
        continue
    it = e.get('iter')
    if it is None:
        name = e.get('iter_name') or ''
        it = name.rsplit('-', 1)[-1] if '-' in name else '?'
    out.append(f\"iter {it}: {e.get('verdict', '?')}\")
print('\n'.join(out))
" "$TELEMETRY" 2>/dev/null || true)"
  _verdict_src="telemetry iter_end events (final post-gate verdicts)"
fi
if [[ -z "$_verdict_seq" ]]; then
  _verdict_seq="$(python3 -c "
import glob, json, os, re, sys
rows = []
for p in glob.glob(os.path.join(sys.argv[1], 'iter-*', '.evaluated')):
    try:
        d = json.load(open(p))
        rows.append((int(d.get('iter', -1)), d.get('verdict', '?')))
    except Exception:
        continue
print('\n'.join(f'iter {i}: {v}' for i, v in sorted(rows)))
" "$SESSION_DIR" 2>/dev/null || true)"
  _verdict_src="iter-*/.evaluated markers (raw pre-gate verdicts)"
fi
if [[ -z "$_verdict_seq" ]]; then
  _verdict_seq="none recorded (no iter_end events in telemetry.jsonl, no iter-*/.evaluated markers)"
  _verdict_src="—"
fi

# ── Agent economics ───────────────────────────────────────────────────────────
# From analyze_telemetry.py --json (claude_usage events). Rendered as a markdown
# table; degrades to an explicit "none recorded" line.
_econ_table="none recorded (telemetry.jsonl missing)"
_wall_block="(per-step wall breakdown unavailable)"
if [[ -f "$TELEMETRY" ]]; then
  _econ_table="$(python3 "$SCRIPT_DIR/analyze_telemetry.py" --json "$TELEMETRY" 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
rows = []
for sid, s in data.items():
    for agent, r in sorted((s.get('by_agent') or {}).items()):
        rows.append((agent, r))
    total = s.get('total')
    if total:
        rows.append(('TOTAL', total))
if not rows:
    sys.exit(0)
print('| Agent | Invocations | Wall (s) | In tokens | Out tokens | Est. cost (USD) |')
print('|---|---|---|---|---|---|')
for agent, r in rows:
    print('| {} | {} | {} | {} | {} | {:.4f} |'.format(
        agent,
        r.get('invocations', 0),
        round(int(r.get('duration_ms', 0) or 0) / 1000),
        r.get('gen_ai.usage.input_tokens', 0),
        r.get('gen_ai.usage.output_tokens', 0),
        float(r.get('gen_ai.usage.total_cost_usd', 0) or 0)))
" 2>/dev/null || true)"
  [[ -z "$_econ_table" ]] && _econ_table="none recorded (no claude_usage events in telemetry.jsonl — token telemetry may be off)"
  _wall_block="$(python3 "$SCRIPT_DIR/analyze_telemetry.py" --wall "$TELEMETRY" 2>/dev/null || echo "(per-step wall breakdown unavailable)")"
fi

# ── Friction counters ─────────────────────────────────────────────────────────
# Quota pauses: session.json quota_pause_count (written by write_session_summary
# just before this collector runs); fallback to the raw counter file.
_quota="$(_sj quota_pause_count)"
if [[ -z "$_quota" ]]; then
  _quota="$(cat "$SESSION_DIR/.quota-pause-count" 2>/dev/null || true)"
fi
[[ -z "$_quota" ]] && _quota="unknown (quota_pause_count absent from session.json and .quota-pause-count missing)"

# Attempt-1 review FAILs: review_verdict telemetry events (goal-iter-lean.sh)
# with attempt==1 and verdict==FAIL.
_review_fails="unknown (telemetry.jsonl missing)"
# Malformed verdicts: deterministic_gate events whose raw verdict is not a valid
# token. The gates' .malformed-verdict-count file only tracks CONSECUTIVE
# strikes and is reset on every well-formed verdict (lib/goal-gates.sh), so it
# cannot serve as a session total.
_malformed="unknown (telemetry.jsonl missing)"
if [[ -f "$TELEMETRY" ]]; then
  read -r _review_fails _malformed <<<"$(python3 -c "
import json, sys
VALID = {'GOAL_ACHIEVED', 'CONTINUE', 'ESCALATE', 'REGRESSION', 'STALLED'}
review_fails = malformed = 0
for raw in open(sys.argv[1], encoding='utf-8'):
    raw = raw.strip()
    if not raw:
        continue
    try:
        e = json.loads(raw)
    except Exception:
        continue
    ev = e.get('event')
    if ev == 'review_verdict' and e.get('attempt') == 1 and e.get('verdict') == 'FAIL':
        review_fails += 1
    elif ev == 'deterministic_gate' and e.get('raw') not in VALID:
        malformed += 1
print(review_fails, malformed)
" "$TELEMETRY" 2>/dev/null || echo "unknown unknown")"
  [[ "$_review_fails" == "unknown" ]] && _review_fails="unknown (telemetry.jsonl unreadable)"
  [[ "$_malformed" == "unknown" ]] && _malformed="unknown (telemetry.jsonl unreadable)"
fi

# ── Lessons tail ──────────────────────────────────────────────────────────────
if [[ -s "$LESSONS_FILE" ]]; then
  _lessons_tail="$(tail -n 20 "$LESSONS_FILE" 2>/dev/null || echo "none recorded (state/lessons.md unreadable)")"
elif [[ -f "$LESSONS_FILE" ]]; then
  _lessons_tail="none recorded (state/lessons.md is empty)"
else
  _lessons_tail="none recorded (state/lessons.md missing)"
fi

# ── Halt context ──────────────────────────────────────────────────────────────
_halt_ctx="$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print('none recorded (session.json missing or unreadable)')
    sys.exit(0)
ctx = {k: d.get(k) for k in ('status', 'last_verdict')}
if 'parked_wip_sha' in d:
    ctx['parked_wip_sha'] = d['parked_wip_sha']
print(json.dumps(ctx, indent=2))
" "$SESSION_JSON" 2>/dev/null || echo "none recorded (session.json missing or unreadable)")"

# ── Assemble (single write; only file this script creates) ────────────────────
cat > "$OUT" <<EOF
# Retro input — session ${_sid}

Deterministic end-of-session evidence snapshot (EVO-2 slice a). Generated by
scripts/automation/lib/retro_collect.sh — no model wrote this. Counters marked
\`unknown (<why>)\` had no reliable source; treat them as gaps, not zeros.

## Outcome

- **Terminal status:** ${TERMINAL_STATUS}
- **Final verdict:** ${_final_verdict}
- **Iterations used:** ${_iters}
- **Halted at (UTC):** ${_halted_at}

## Verdict sequence

Source: ${_verdict_src}

\`\`\`
${_verdict_seq}
\`\`\`

## Agent economics

Source: analyze_telemetry.py --json telemetry.jsonl (claude_usage events)

${_econ_table}

Per-step wall breakdown (analyze_telemetry.py --wall):

\`\`\`
${_wall_block}
\`\`\`

## Friction counters

- **Quota pauses:** ${_quota} (source: session.json quota_pause_count / .quota-pause-count)
- **Attempt-1 review FAILs:** ${_review_fails} (source: telemetry review_verdict events, attempt 1)
- **Malformed-verdict rewrites:** ${_malformed} (source: telemetry deterministic_gate events with an invalid raw verdict; the gates' .malformed-verdict-count only tracks consecutive strikes)

## Lessons tail

Last 20 lines of state/lessons.md:

\`\`\`
${_lessons_tail}
\`\`\`

## Halt context

session.json halt-relevant fields:

\`\`\`json
${_halt_ctx}
\`\`\`
EOF

echo "[retro-collect] Wrote $OUT"
exit 0
