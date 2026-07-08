#!/usr/bin/env bash
# install-git-hooks.sh — OPT-IN pre-commit eval guard (roadmap SAFE-1).
#
# Installs a .git/hooks/pre-commit that runs the fast pure-python eval subset
# (every `_run_self_test` registration in scripts/automation/run-evals.sh;
# ~0.5s today, target <10s) so a red eval cannot land in a commit unnoticed.
#
# OPT-IN by design: no pipeline script ever calls this — a human runs it once
# per clone. The hook is a local convenience; CI (.github/workflows/evals.yml)
# stays the authoritative gate. Bypass a blocked commit with
# `git commit --no-verify` (CI will still catch a real failure).
#
# Usage:
#   bash scripts/automation/install-git-hooks.sh              # install
#   bash scripts/automation/install-git-hooks.sh --force      # replace a foreign pre-commit (backed up to pre-commit.bak)
#   bash scripts/automation/install-git-hooks.sh --uninstall  # remove the guard hook
#   bash scripts/automation/install-git-hooks.sh --self-test  # offline behavioral test in a scratch repo
#
# Rollback: --uninstall, or just delete .git/hooks/pre-commit (local-only file).
set -euo pipefail

MARKER="chain-eval-guard"   # identifies hooks written by this installer
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

_log() { echo "[install-git-hooks] $*"; }

# ── The hook body (quoted heredoc: expands at COMMIT time, not install time) ──
_write_hook() {
  local target="$1"
  cat > "$target" <<'HOOK'
#!/usr/bin/env bash
# pre-commit eval guard — chain-eval-guard v1
# Installed by scripts/automation/install-git-hooks.sh (roadmap SAFE-1).
# Runs the fast pure-python eval subset: every `_run_self_test` registration
# in scripts/automation/run-evals.sh. Blocks the commit if any fails.
# Bypass ONCE (emergency only): git commit --no-verify   — CI still gates.
set -uo pipefail

repo_root="$(git rev-parse --show-toplevel)" || exit 1
cd "$repo_root"
evals="scripts/automation/run-evals.sh"

_block() {
  echo "✗ pre-commit eval guard: $1" >&2
  echo "  Full suite:  ./scripts/automation/run-evals.sh --verbose" >&2
  echo "  Bypass once: git commit --no-verify   (CI will still catch real failures)" >&2
  echo "  Reinstall:   bash scripts/automation/install-git-hooks.sh --force" >&2
  exit 1
}

[[ -f "$evals" ]] || _block "$evals not found — cannot determine the fast eval subset."
command -v python3 >/dev/null 2>&1 || _block "python3 not found on PATH."

# The subset is derived from run-evals.sh at commit time so it never drifts
# from the suite. Zero matches means the registration format changed — fail
# loud rather than silently passing forever.
registrations="$(grep -E '^_run_self_test[[:space:]]' "$evals" || true)"
[[ -n "$registrations" ]] || _block "no _run_self_test registrations found in $evals — hook out of date."

total=0
failed=0
start=$SECONDS
while read -r _ module arg; do
  [[ -n "${module:-}" ]] || continue
  total=$((total + 1))
  if ! out="$(python3 "$module" "${arg:-self-test}" 2>&1)"; then
    failed=$((failed + 1))
    echo "✗ FAIL: python3 $module ${arg:-self-test}" >&2
    echo "$out" | head -5 | sed 's/^/    /' >&2
  fi
done <<< "$registrations"

if [[ "$failed" -gt 0 ]]; then
  _block "$failed of $total fast self-tests failed — commit blocked."
fi
echo "pre-commit eval guard: $total pure-python self-tests passed in $((SECONDS - start))s (full suite: ./scripts/automation/run-evals.sh)"
exit 0
HOOK
  chmod +x "$target"
}

# ── install / uninstall ──────────────────────────────────────────────────────
_hook_path() {
  git rev-parse --git-path hooks/pre-commit 2>/dev/null \
    || { _log "ERROR: not inside a git repository."; exit 1; }
}

_install() {
  local force="${1:-false}"
  local hook; hook="$(_hook_path)"
  mkdir -p "$(dirname "$hook")"

  if [[ -f "$hook" ]] && ! grep -q "$MARKER" "$hook"; then
    if [[ "$force" != "true" ]]; then
      _log "ERROR: $hook exists and was not installed by this script."
      _log "Re-run with --force to replace it (the old hook is backed up to pre-commit.bak)."
      exit 1
    fi
    cp "$hook" "${hook}.bak"
    _log "existing foreign hook backed up to ${hook}.bak"
  fi

  _write_hook "$hook"
  _log "installed $hook"
  _log "it runs the fast pure-python eval subset (<10s) before every commit."
  _log "full suite: ./scripts/automation/run-evals.sh · bypass once: git commit --no-verify"

  local hooks_path
  hooks_path="$(git config --get core.hooksPath 2>/dev/null || true)"
  if [[ -n "$hooks_path" ]]; then
    _log "WARNING: core.hooksPath=$hooks_path is set — git will NOT run hooks from $(dirname "$hook")."
  fi
}

_uninstall() {
  local hook; hook="$(_hook_path)"
  if [[ ! -f "$hook" ]]; then
    _log "nothing to do: $hook does not exist."
    return 0
  fi
  if ! grep -q "$MARKER" "$hook"; then
    _log "ERROR: $hook was not installed by this script — refusing to delete it."
    exit 1
  fi
  rm -f "$hook"
  _log "removed $hook"
}

# ── self-test (offline, scratch repo; wired into run-evals.sh) ───────────────
_self_test() {
  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  — expand NOW: $tmp is a function local, gone when EXIT fires
  trap "rm -rf '$tmp'" EXIT
  # Isolate from user/system git config (gpg signing, core.hooksPath, ...).
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  local _fail=0
  _assert() { # <label> <command...>
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "  ok: $label"; else echo "  FAIL: $label" >&2; _fail=1; fi
  }
  _assert_not() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "  FAIL: $label" >&2; _fail=1; else echo "  ok: $label"; fi
  }

  cd "$tmp"
  git init -q repo && cd repo
  git config user.email t@t && git config user.name t

  # Minimal fake suite: two _run_self_test registrations over tiny fixtures.
  mkdir -p scripts/automation/lib
  printf 'import sys; sys.exit(0)\n' > scripts/automation/lib/ok.py
  printf 'import sys; sys.exit(0)\n' > scripts/automation/lib/flaky.py
  cat > scripts/automation/run-evals.sh <<'EOF'
_run_self_test scripts/automation/lib/ok.py self-test
_run_self_test scripts/automation/lib/flaky.py self-test
EOF

  # 1. install: hook exists, executable, carries the marker
  _assert "install succeeds"            bash "$SCRIPT_PATH"
  local hook=".git/hooks/pre-commit"
  _assert "hook file exists"            test -f "$hook"
  _assert "hook is executable"          test -x "$hook"
  _assert "hook carries marker"         grep -q "$MARKER" "$hook"
  _assert "reinstall is idempotent"     bash "$SCRIPT_PATH"

  # 2. green path: commit passes when all self-tests pass
  echo a > a.txt && git add a.txt
  _assert "commit allowed when subset green" git commit -q -m ok

  # 3. red path: a deliberately broken self-test blocks the commit
  printf 'import sys; sys.exit(1)\n' > scripts/automation/lib/flaky.py
  echo b > b.txt && git add b.txt
  _assert_not "commit BLOCKED when a self-test is broken" git commit -q -m broken
  _assert "blocked commit did not land"  test "$(git rev-list --count HEAD)" = "1"

  # 4. restore: commit passes again
  printf 'import sys; sys.exit(0)\n' > scripts/automation/lib/flaky.py
  git add scripts/automation/lib/flaky.py
  _assert "commit allowed after restore" git commit -q -m restored

  # 5. fail-loud: missing run-evals.sh blocks (never silently passes)
  mv scripts/automation/run-evals.sh scripts/automation/run-evals.sh.away
  echo c > c.txt && git add c.txt
  _assert_not "commit BLOCKED when run-evals.sh is missing" git commit -q -m no-suite
  mv scripts/automation/run-evals.sh.away scripts/automation/run-evals.sh
  git reset -q c.txt

  # 6. foreign-hook safety: refuse without --force, replace+backup with it
  printf '#!/bin/sh\nexit 0\n' > "$hook" && chmod +x "$hook"
  _assert_not "install refuses to clobber a foreign hook" bash "$SCRIPT_PATH"
  _assert "install --force replaces foreign hook"         bash "$SCRIPT_PATH" --force
  _assert "foreign hook backed up"                        test -f "${hook}.bak"
  _assert "replacement carries marker"                    grep -q "$MARKER" "$hook"

  # 7. uninstall removes our hook; refuses a foreign one
  _assert "uninstall removes the guard hook" bash "$SCRIPT_PATH" --uninstall
  _assert "hook gone after uninstall"        test ! -f "$hook"
  printf '#!/bin/sh\nexit 0\n' > "$hook" && chmod +x "$hook"
  _assert_not "uninstall refuses a foreign hook" bash "$SCRIPT_PATH" --uninstall

  if [[ "$_fail" -ne 0 ]]; then echo "self-test FAILED" >&2; exit 1; fi
  echo "self-test passed"
}

case "${1:-}" in
  --self-test) _self_test ;;
  --uninstall) _uninstall ;;
  --force)     _install true ;;
  "")          _install false ;;
  *) _log "ERROR: unknown option '$1' (expected --force, --uninstall or --self-test)"; exit 1 ;;
esac
