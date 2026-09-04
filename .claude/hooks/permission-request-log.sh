#!/usr/bin/env bash
# PermissionRequest recorder — STAGE 1, LOG-ONLY. Fires when Claude Code is about to
# need a permission decision from a human: the exact event the autonomous pipeline can
# never answer. It emits NO decision (stdout stays empty; the native flow proceeds
# unchanged) and only appends a privacy-safe permission_request event (Task 2 schema:
# suggestion count/types/hash — never command or suggestion text) so
# lib/analyze_transcripts.py can count human prompts deterministically. A deny mode is a
# separate roadmap experiment (CAND-PERM-1 stage 2), not implemented here. Exit 0 always.
[ -t 0 ] && exit 0
_payload=$(cat 2>/dev/null || true)
[ -n "$_payload" ] || exit 0
_HOOK_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
[ -f "$_HOOK_DIR/lib/hook_events.py" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
printf '%s' "$_payload" | python3 "$_HOOK_DIR/lib/hook_events.py" --hook permission-request-log --event permission_request >/dev/null 2>&1 || true
exit 0
