#!/usr/bin/env bash
# project-gates.sh — generic, opt-in pipeline gates (framework mechanism "M2").
#
# A project may place an executable hook at
#   <project-root>/project-extensions/gates/<gate-name>.sh
# to gate the pipeline at a defined point (e.g. "post-decompose"). The hook
# receives iteration context via the environment the caller exports
# (SESSION_ID, ITER, ITER_NAME, SPEC_PATH, SESSION_DIR, LEDGER_PATH,
# GATE_VERDICT_PATH, REPO_ROOT). A NON-ZERO exit means "block this iteration".
#
# Absent hook ⇒ no-op (return 0). project-extensions/ lives OUTSIDE the framework
# subtree, so projects that have not opted in behave exactly as before and the
# mechanism never travels upstream with the framework.

# run_project_gate <gate-name>
#   Returns 0 if the gate is absent or passes; the gate's non-zero exit if it
#   blocks. Honours PROJECT_GATES_ROOT (defaults to $REPO_ROOT) for testability.
run_project_gate() {
  local gate_name="$1"
  local root="${PROJECT_GATES_ROOT:-${REPO_ROOT:-.}}"
  local gate="$root/project-extensions/gates/${gate_name}.sh"
  [[ -f "$gate" ]] || return 0
  bash "$gate"
}

# run_project_hook <hook-name>
#   A generic opt-in pipeline HOOK (sibling to run_project_gate, framework mechanism "M3"). Where a
#   GATE's non-zero exit means "block", a HOOK's exit code is an ACTION SIGNAL the caller interprets:
#     absent hook            → return 0   (no-op; caller proceeds exactly as before — backward compatible)
#     present hook, exit 0   → "nothing to do" (caller continues its normal path, e.g. halt as usual)
#     present hook, exit 10  → "continue"      (PROJECT_HOOK_CONTINUE — the caller should keep looping)
#     any other non-zero     → propagated as an error
#   Hooks live at <project-root>/project-extensions/hooks/<hook-name>.sh, OUTSIDE the framework subtree,
#   so projects that have not opted in behave exactly as before and the mechanism never travels upstream.
#   The caller exports the iteration/session context the hook needs (SESSION_ID, SESSION_DIR, REPO_ROOT,
#   LEDGER_PATH, GOAL_MD, …) just as the gate caller does.
PROJECT_HOOK_CONTINUE=10
run_project_hook() {
  local hook_name="$1"
  local root="${PROJECT_GATES_ROOT:-${REPO_ROOT:-.}}"
  local hook="$root/project-extensions/hooks/${hook_name}.sh"
  [[ -f "$hook" ]] || return 0
  bash "$hook"
}

# ── Self-test (run-evals.sh): bash scripts/automation/lib/project-gates.sh self-test
if [[ "${BASH_SOURCE[0]}" == "${0}" && "${1:-}" == "self-test" ]]; then
  set -euo pipefail
  _t="$(mktemp -d)"; trap 'rm -rf "$_t"' EXIT
  export PROJECT_GATES_ROOT="$_t"

  # 1. Absent gate ⇒ no-op.
  run_project_gate post-decompose || { echo "FAIL: absent gate must be a no-op (return 0)"; exit 1; }

  # 2. Present gate that exits 0 ⇒ pass, and receives the context env.
  mkdir -p "$_t/project-extensions/gates"
  cat > "$_t/project-extensions/gates/post-decompose.sh" <<'GATE'
#!/usr/bin/env bash
[[ "$ITER" == "5" && -n "$SPEC_PATH" ]] || exit 2
exit 0
GATE
  ITER=5 SPEC_PATH=/tmp/spec.md run_project_gate post-decompose \
    || { echo "FAIL: passing gate must return 0 and see context env"; exit 1; }

  # 3. Present gate that exits non-zero ⇒ block (code propagates).
  printf '#!/usr/bin/env bash\nexit 7\n' > "$_t/project-extensions/gates/post-decompose.sh"
  if run_project_gate post-decompose; then echo "FAIL: blocking gate must return non-zero"; exit 1; fi

  # 4. Absent HOOK ⇒ no-op (return 0) — a project that has not opted in is unaffected.
  run_project_hook post-goal || { echo "FAIL: absent hook must be a no-op (return 0)"; exit 1; }

  # 5. Present hook, exit 0 ⇒ "nothing to do" (return 0), and it sees the context env.
  mkdir -p "$_t/project-extensions/hooks"
  cat > "$_t/project-extensions/hooks/post-goal.sh" <<'HOOK'
#!/usr/bin/env bash
[[ -n "$SESSION_ID" ]] || exit 2
exit 0
HOOK
  SESSION_ID=demo run_project_hook post-goal \
    || { echo "FAIL: exit-0 hook must return 0 and see context env"; exit 1; }

  # 6. Present hook, exit 10 ⇒ "continue" (PROJECT_HOOK_CONTINUE propagates verbatim).
  printf '#!/usr/bin/env bash\nexit 10\n' > "$_t/project-extensions/hooks/post-goal.sh"
  set +e; SESSION_ID=demo run_project_hook post-goal; _rc=$?; set -e
  [[ "$_rc" == "$PROJECT_HOOK_CONTINUE" ]] \
    || { echo "FAIL: continue hook must return $PROJECT_HOOK_CONTINUE (got $_rc)"; exit 1; }

  echo "project-gates self-test: OK"
fi
