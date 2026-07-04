#!/usr/bin/env bash
# checkpoint.sh — step-level checkpoint/resume for goal-mode iterations.
#
# Problem this solves: a transport stall (exit 70), quota kill, or Ctrl-C used
# to restart the whole iteration from the decomposer, re-running the most
# expensive step (the ~41-min developer) even though its artifacts were already
# on disk (anti-pattern #5: checkpoint/resume, never restart). These helpers
# record a marker after each completed step so a resumed iteration lands on the
# first genuinely incomplete step.
#
# Markers live next to the existing `.evaluated` marker:
#   runs/goal-session-<sid>/iter-<N>/.steps/<step>.done   (one JSON object)
#   {v, step, iter, iter_name, ts, tree_hash, artifacts, verdict, journeys}
#
# Safety model (conservative by construction — any doubt means re-run):
#   - A marker is written ONLY after the agent exited 0 AND its gating artifact
#     exists. Exit-70/75/timeout paths never mark.
#   - Skips that reuse developer output also require the working tree to hash
#     identically to where this iteration LAST left it (mtime-latest marker),
#     so a manual edit or `git reset` during a pause forces a fresh build.
#   - Running any step invalidates its own and all downstream markers
#     (including `.evaluated`), so a stale artifact can never certify a verdict
#     it did not earn.
#
# Environment:
#   CHAIN_STEP_CHECKPOINTS    true (default) → markers written and honored.
#                             false → never skip, never write (debug escape hatch).
#   CHAIN_STEP_HASH_EXCLUDES  Space-separated pathspecs excluded from the tree
#                             hash (default: harness artifact dirs, so report
#                             writes don't churn the product hash).
#
# Sourced by lib/common.sh. Self-test: `bash lib/checkpoint.sh --self-test`.

: "${CHAIN_STEP_CHECKPOINTS:=true}"
: "${CHAIN_STEP_HASH_EXCLUDES:=runs reports docs/handoffs docs/phases}"

# Canonical step order for the lean iteration + outer-loop steps. Invalidation
# cascades from a step to everything after it. `evaluator` is a pseudo-step
# mapping to the pre-existing `.evaluated` marker + eval.md.
_CHAIN_STEP_ORDER=(decomposer developer review-1 developer-fix review-2 browser-qa coherence evaluator)

# Resolve this iteration's directory. Prefers the env run-goal.sh exports
# (GOAL_SESSION_DIR + GOAL_ITER_INDEX); falls back to deriving both from an
# iter name of the documented form `goal-<sid>-iter-<N>`.
goal_iter_dir() {
  local name="${1:-${GOAL_ITER_NAME:-}}"
  if [[ -n "${GOAL_SESSION_DIR:-}" && -n "${GOAL_ITER_INDEX:-}" ]]; then
    printf '%s' "$GOAL_SESSION_DIR/iter-$GOAL_ITER_INDEX"
    return 0
  fi
  if [[ "$name" =~ ^goal-(.+)-iter-([0-9]+)$ ]]; then
    printf '%s' "${REPO_ROOT:-.}/runs/goal-session-${BASH_REMATCH[1]}/iter-${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

# Hash the product working tree (tracked + untracked-unignored files) without
# touching the real index or worktree: temp index + `git add -A` + write-tree.
# `git stash create` is unsuitable for equality checks (its commit objects embed
# timestamps); write-tree is deterministic for identical trees. Harness artifact
# dirs are excluded so report/telemetry writes don't churn the hash. Any git
# failure → empty output → callers treat the tree as unverifiable (re-run).
chain_tree_hash() {
  local repo="${1:-${REPO_ROOT:-.}}"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { printf ''; return 0; }
  local tmp_index e excludes=() h=""
  for e in $CHAIN_STEP_HASH_EXCLUDES; do
    excludes+=(":(exclude)$e")
  done
  tmp_index="$(mktemp "${TMPDIR:-/tmp}/chain-tree-index.XXXXXX")" || { printf ''; return 0; }
  rm -f "$tmp_index"   # git add wants to create the index file itself
  if GIT_INDEX_FILE="$tmp_index" git -C "$repo" add -A -- . "${excludes[@]}" 2>/dev/null; then
    h="$(GIT_INDEX_FILE="$tmp_index" git -C "$repo" write-tree 2>/dev/null || printf '')"
  fi
  rm -f "$tmp_index"
  printf '%s' "$h"
}

# The tree hash recorded by the mtime-latest marker of this iteration — i.e.
# "where this iteration last left the tree". Empty when there is no marker or
# the latest marker could not hash (both mean: cannot verify).
iter_latest_tree_hash() {
  local dir="${1:-$(goal_iter_dir)}" latest
  [[ -d "$dir/.steps" ]] || { printf ''; return 0; }
  latest="$(ls -1t "$dir/.steps"/*.done 2>/dev/null | head -1)"
  [[ -n "$latest" ]] || { printf ''; return 0; }
  _checkpoint_json_field "$latest" tree_hash
}

# Read one string field from a marker file. Prints empty on any parse problem.
_checkpoint_json_field() {
  local file="$1" field="$2"
  [[ -s "$file" ]] || { printf ''; return 0; }
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg f "$field" '.[$f] // empty' "$file" 2>/dev/null || printf ''
  else
    _CP_FILE="$file" _CP_FIELD="$field" python3 -c '
import json, os
try:
    v = json.load(open(os.environ["_CP_FILE"])).get(os.environ["_CP_FIELD"], "")
    print(v if isinstance(v, str) else "")
except Exception:
    pass' 2>/dev/null || printf ''
  fi
}

# step_field <step> <field> [iter-dir] — field from a step's marker (or empty).
step_field() {
  local step="$1" field="$2" dir="${3:-$(goal_iter_dir)}"
  _checkpoint_json_field "$dir/.steps/$step.done" "$field"
}

# step_mark_done <step> [--verdict V] [--journeys J] [--dir D] [artifact ...]
# Records the completion marker (atomic tmp+mv). Call ONLY after the agent
# exited 0 and its gating artifact exists. No-op when checkpoints are off.
step_mark_done() {
  [[ "$CHAIN_STEP_CHECKPOINTS" == "true" ]] || return 0
  local step="$1"; shift
  local verdict="" journeys="" dir="" artifacts=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --verdict)  verdict="${2:-}"; shift 2 ;;
      --journeys) journeys="${2:-}"; shift 2 ;;
      --dir)      dir="${2:-}"; shift 2 ;;
      *)          artifacts+=("$1"); shift ;;
    esac
  done
  [[ -n "$dir" ]] || dir="$(goal_iter_dir)" || return 0
  mkdir -p "$dir/.steps" 2>/dev/null || return 0
  local ts hash tmp
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  hash="$(chain_tree_hash)"
  tmp="$dir/.steps/$step.done.tmp.$$"
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg s "$step" --arg i "${GOAL_ITER_INDEX:-}" --arg n "${GOAL_ITER_NAME:-}" \
       --arg t "$ts" --arg h "$hash" --arg v "$verdict" --arg j "$journeys" \
       --args '{v:1, step:$s, iter:$i, iter_name:$n, ts:$t, tree_hash:$h,
                artifacts:$ARGS.positional, verdict:$v, journeys:$j}' \
       -- "${artifacts[@]}" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  else
    _CP_S="$step" _CP_I="${GOAL_ITER_INDEX:-}" _CP_N="${GOAL_ITER_NAME:-}" _CP_T="$ts" \
    _CP_H="$hash" _CP_V="$verdict" _CP_J="$journeys" _CP_A="$(printf '%s\n' "${artifacts[@]:-}")" \
    python3 -c '
import json, os
arts = [a for a in os.environ.get("_CP_A", "").split("\n") if a]
print(json.dumps({"v": 1, "step": os.environ["_CP_S"], "iter": os.environ["_CP_I"],
                  "iter_name": os.environ["_CP_N"], "ts": os.environ["_CP_T"],
                  "tree_hash": os.environ["_CP_H"], "artifacts": arts,
                  "verdict": os.environ["_CP_V"], "journeys": os.environ["_CP_J"]}))' \
      > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  fi
  mv -f "$tmp" "$dir/.steps/$step.done" 2>/dev/null || rm -f "$tmp"
}

# step_done_valid <step> [--verify-tree] [--dir D] [artifact ...]
# Returns 0 (safe to skip) iff checkpoints are on, the marker exists and
# parses, every listed artifact exists non-empty, and — with --verify-tree —
# the current tree hashes identically to the iteration's latest recorded hash.
step_done_valid() {
  [[ "$CHAIN_STEP_CHECKPOINTS" == "true" ]] || return 1
  local step="$1"; shift
  local verify_tree="" dir="" artifacts=() a
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --verify-tree) verify_tree=1; shift ;;
      --dir)         dir="${2:-}"; shift 2 ;;
      *)             artifacts+=("$1"); shift ;;
    esac
  done
  [[ -n "$dir" ]] || dir="$(goal_iter_dir)" || return 1
  local marker="$dir/.steps/$step.done"
  [[ -s "$marker" ]] || return 1
  [[ "$(_checkpoint_json_field "$marker" step)" == "$step" ]] || return 1
  for a in "${artifacts[@]:-}"; do
    [[ -z "$a" || -s "$a" ]] || return 1
  done
  if [[ -n "$verify_tree" ]]; then
    local want have
    want="$(iter_latest_tree_hash "$dir")"
    [[ -n "$want" ]] || return 1
    have="$(chain_tree_hash)"
    [[ -n "$have" && "$have" == "$want" ]] || return 1
  fi
  return 0
}

# step_invalidate_from <step> [iter-dir]
# Deletes the given step's marker and every downstream marker, plus the
# artifacts those markers registered (belt-and-braces: a stale verdict file
# must never survive a fresh upstream run). The `evaluator` pseudo-step maps
# to the pre-existing `.evaluated` marker + eval.md. Call before a step RUNS.
step_invalidate_from() {
  [[ "$CHAIN_STEP_CHECKPOINTS" == "true" ]] || return 0
  local from="$1" dir="${2:-$(goal_iter_dir)}"
  [[ -n "$dir" ]] || return 0
  local hit="" s marker a
  for s in "${_CHAIN_STEP_ORDER[@]}"; do
    [[ "$s" == "$from" ]] && hit=1
    [[ -n "$hit" ]] || continue
    if [[ "$s" == "evaluator" ]]; then
      rm -f "$dir/.evaluated" "$dir/eval.md" 2>/dev/null || true
      continue
    fi
    marker="$dir/.steps/$s.done"
    [[ -f "$marker" ]] || continue
    while IFS= read -r a; do
      [[ -n "$a" && -f "$a" ]] && rm -f "$a" 2>/dev/null
    done < <(
      if command -v jq >/dev/null 2>&1; then
        jq -r '.artifacts[]? // empty' "$marker" 2>/dev/null
      else
        _CP_FILE="$marker" python3 -c '
import json, os
try:
    for a in json.load(open(os.environ["_CP_FILE"])).get("artifacts", []):
        print(a)
except Exception:
    pass' 2>/dev/null
      fi
    )
    rm -f "$marker" 2>/dev/null || true
  done
  return 0
}

# ── Self-test (run directly: `bash checkpoint.sh --self-test`) ────────────────
_checkpoint_self_test() {
  local fails=0 work repo dir
  work="$(mktemp -d)"
  repo="$work/proj"
  mkdir -p "$repo/runs" "$repo/reports" "$repo/src"
  git -C "$work" init -q "$repo" 2>/dev/null || git init -q "$repo"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  echo "code v1" > "$repo/src/app.py"

  export REPO_ROOT="$repo"
  export GOAL_SESSION_DIR="$repo/runs/goal-session-t"
  export GOAL_ITER_INDEX="3"
  export GOAL_ITER_NAME="goal-t-iter-3"
  export CHAIN_STEP_CHECKPOINTS="true"
  dir="$(goal_iter_dir)"
  mkdir -p "$dir"

  # 1 — mark + valid round-trip (with tree verification)
  local handoff="$repo/docs-handoff-dev.md"; echo "handoff" > "$handoff"
  ( cd "$repo" && step_mark_done developer --verdict "" "$handoff" )
  if ( cd "$repo" && step_done_valid developer --verify-tree "$handoff" ); then
    echo "  PASS checkpoint: mark + valid round-trip"
  else echo "  FAIL checkpoint: mark + valid round-trip"; fails=1; fi

  # 2 — excluded dirs don't churn the hash
  echo "log line" > "$repo/runs/engine.log"; echo "report" > "$repo/reports/r.md"
  if ( cd "$repo" && step_done_valid developer --verify-tree "$handoff" ); then
    echo "  PASS checkpoint: excluded dirs don't churn the tree hash"
  else echo "  FAIL checkpoint: excluded dirs churned the hash"; fails=1; fi

  # 3 — product-tree drift invalidates the skip
  echo "code v2" > "$repo/src/app.py"
  if ( cd "$repo" && step_done_valid developer --verify-tree "$handoff" ); then
    echo "  FAIL checkpoint: tree drift not detected"; fails=1
  else echo "  PASS checkpoint: tree drift invalidates skip"; fi
  echo "code v1" > "$repo/src/app.py"   # restore

  # 4 — missing artifact invalidates the skip
  if ( cd "$repo" && step_done_valid developer --verify-tree "$work/nonexistent.md" ); then
    echo "  FAIL checkpoint: missing artifact not detected"; fails=1
  else echo "  PASS checkpoint: missing artifact invalidates skip"; fi

  # 5 — invalidation cascade removes downstream markers/artifacts + .evaluated
  local review="$repo/review.md" coher="$dir/coherence.md"
  echo "review PASS" > "$review"; echo "coherence" > "$coher"; echo "eval" > "$dir/eval.md"
  ( cd "$repo" && step_mark_done review-1 --verdict PASS "$review" )
  ( cd "$repo" && step_mark_done coherence --verdict COHERENCE-PASS "$coher" )
  touch "$dir/.evaluated"
  ( cd "$repo" && step_invalidate_from review-1 )
  if [[ ! -f "$dir/.steps/review-1.done" && ! -f "$dir/.steps/coherence.done" \
        && ! -f "$coher" && ! -f "$dir/.evaluated" && ! -f "$dir/eval.md" \
        && -f "$dir/.steps/developer.done" && -f "$handoff" ]]; then
    echo "  PASS checkpoint: invalidation cascade (markers+artifacts down, upstream kept)"
  else echo "  FAIL checkpoint: invalidation cascade"; fails=1; fi

  # 6 — knob off: never skip, never write
  if ( cd "$repo" && CHAIN_STEP_CHECKPOINTS=false step_done_valid developer "$handoff" ); then
    echo "  FAIL checkpoint: knob off but skip allowed"; fails=1
  else echo "  PASS checkpoint: CHAIN_STEP_CHECKPOINTS=false never skips"; fi
  ( cd "$repo" && CHAIN_STEP_CHECKPOINTS=false step_mark_done review-2 "$review" )
  if [[ -f "$dir/.steps/review-2.done" ]]; then
    echo "  FAIL checkpoint: knob off but marker written"; fails=1
  else echo "  PASS checkpoint: CHAIN_STEP_CHECKPOINTS=false never writes"; fi

  # 7 — non-git dir: hash empty, tree-verified skip refused
  local plain="$work/plain"; mkdir -p "$plain"
  if [[ -z "$(cd "$plain" && REPO_ROOT="$plain" chain_tree_hash "$plain")" ]]; then
    echo "  PASS checkpoint: non-git tree hash is empty (unverifiable → re-run)"
  else echo "  FAIL checkpoint: non-git tree hash not empty"; fails=1; fi

  # 8 — goal_iter_dir derives from the iter name when env is absent
  local derived
  derived="$(GOAL_SESSION_DIR="" GOAL_ITER_INDEX="" goal_iter_dir "goal-my-app-iter-7")"
  if [[ "$derived" == "$repo/runs/goal-session-my-app/iter-7" ]]; then
    echo "  PASS checkpoint: goal_iter_dir derived from iter name"
  else echo "  FAIL checkpoint: goal_iter_dir derivation ($derived)"; fails=1; fi

  rm -rf "$work"
  if [[ "$fails" -eq 0 ]]; then echo "checkpoint self-test: OK"; else echo "checkpoint self-test: FAILED"; fi
  return "$fails"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" && "${1:-}" == "--self-test" ]]; then
  _checkpoint_self_test
  exit $?
fi
