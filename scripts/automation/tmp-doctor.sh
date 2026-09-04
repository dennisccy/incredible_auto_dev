#!/usr/bin/env bash
# tmp-doctor.sh — self-service temp hygiene for agents and humans (REL-13).
#
# THE standing answer to "No space left on device" / "Disk quota exceeded"
# during a run: run this (zero permission prompts — scripts/* is allow-listed),
# retry the failed command once, and NEVER rm arbitrary /tmp files or ask the
# user. Everything it removes is proven dead (pid-liveness) or stale (age);
# live sessions in any concurrent project are never touched.
#
# Usage:
#   ./scripts/automation/tmp-doctor.sh              # = --clean
#   ./scripts/automation/tmp-doctor.sh --status     # read-only usage report
#   ./scripts/automation/tmp-doctor.sh --clean      # normal janitor + soft disk guard
#   ./scripts/automation/tmp-doctor.sh --aggressive # pressure sweep (dead-pid dirs at any
#                                                   # age) + purge of the retired
#                                                   # ~/.cache/chain-bench-tmp root;
#                                                   # exit 2 if the hard floor is still
#                                                   # breached (mirrors the engine pause)
#
# Dependency-free on purpose (sources only lib/chain-tmp.sh, no common.sh) so
# agents can run it in ANY state, including a half-broken checkout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/chain-tmp.sh"

MODE="${1:---clean}"
case "$MODE" in
  --status|--clean|--aggressive) ;;
  -h|--help) sed -n '2,23p' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) echo "unknown mode: $MODE (use --status | --clean | --aggressive)" >&2; exit 64 ;;
esac

BASE="${CHAIN_TMP_ROOT:-$HOME/.cache/iad}"
RETIRED_BENCH_ROOT="$HOME/.cache/chain-bench-tmp"   # pre-relocation bench scratch root

print_status() {
  python3 - "$BASE" /tmp "$RETIRED_BENCH_ROOT" <<'PY'
import os, sys

def free_mb(path):
    try:
        st = os.statvfs(path)
        return st.f_bavail * st.f_frsize // (1024 * 1024)
    except OSError:
        return None

def du_mb(path):
    total = 0
    stack = [path]
    while stack:
        p = stack.pop()
        try:
            with os.scandir(p) as it:
                for e in it:
                    try:
                        if e.is_symlink():
                            continue
                        if e.is_dir(follow_symlinks=False):
                            stack.append(e.path)
                        else:
                            total += e.stat(follow_symlinks=False).st_size
                    except OSError:
                        pass
        except (OSError, NotADirectoryError):
            try:
                total += os.lstat(p).st_size
            except OSError:
                pass
    return total / (1024 * 1024)

def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (ValueError, ProcessLookupError):
        return False
    except PermissionError:
        return True

uid = os.getuid()
for root in sys.argv[1:]:
    if not os.path.isdir(root):
        continue
    fm = free_mb(root)
    print(f"\n{root}  (fs free: {fm} MB)" if fm is not None else f"\n{root}")
    rows = []
    try:
        entries = sorted(os.scandir(root), key=lambda e: e.name)
    except OSError:
        continue
    for e in entries:
        try:
            if e.stat(follow_symlinks=False).st_uid != uid:
                continue
        except OSError:
            continue
        size = du_mb(e.path)
        if size < 0.05 and not e.name.startswith(("iad.", "bench-", "judgment-")):
            continue  # keep the table readable: skip tiny foreign-ish files
        note = ""
        if e.name.startswith("iad."):
            pid = e.name.rsplit(".", 1)[-1]
            note = "LIVE" if pid.isdigit() and pid_alive(pid) else "dead"
        elif e.name.startswith(("bench-", "judgment-")):
            op = os.path.join(e.path, ".owner-pid")
            try:
                pid = open(op).read().strip()
                note = "LIVE" if pid.isdigit() and pid_alive(pid) else "dead"
            except OSError:
                note = "no-owner"
        rows.append((size, e.name, note))
    for size, name, note in sorted(rows, reverse=True)[:25]:
        print(f"  {size:9.1f} MB  {name}  {note}")
    if not rows:
        print("  (nothing of note owned by you)")
PY
}

case "$MODE" in
  --status)
    print_status
    ;;
  --clean)
    chain_tmp_janitor
    chain_tmp_disk_guard || true
    echo "[tmp-doctor] clean sweep done."
    print_status
    ;;
  --aggressive)
    chain_tmp_janitor --aggressive
    # One-shot purge of the retired pre-relocation bench root (never used by
    # live runs anymore; anything inside is a leak by definition).
    if [[ -d "$RETIRED_BENCH_ROOT" && -O "$RETIRED_BENCH_ROOT" ]]; then
      rm -rf -- "$RETIRED_BENCH_ROOT" 2>/dev/null || true
      echo "[tmp-doctor] purged retired root $RETIRED_BENCH_ROOT"
    fi
    # Retention sweep for the permission-economics events ledger (see
    # docs/goal-mode-telemetry.md "Permission economics" section): session-scoped
    # hook-events files older than 30 days are stale by construction (the session
    # is long over), so age them out here rather than let them accumulate forever.
    find "${XDG_CACHE_HOME:-$HOME/.cache}/iad/hook-events" -name '*.jsonl' -mtime +30 -delete 2>/dev/null || true
    rc=0
    chain_tmp_disk_guard --enforce || rc=$?
    echo "[tmp-doctor] aggressive sweep done."
    print_status
    if [[ "$rc" -eq 2 ]]; then
      echo "[tmp-doctor] WARNING: free space still under the hard floor — the machine is genuinely low on disk." >&2
      exit 2
    fi
    ;;
esac
