#!/usr/bin/env bash
# Guard hook: secondary check for dangerous command patterns
# Primary protection is the deny rules in .claude/settings.json
# This hook provides a redundant safety layer for critical patterns
#
# Two input/output modes (SEC-7):
#   argv mode  — command as $1 (run-evals 2d, test harness, Codex): GUARD
#     lines on stderr + exit 1 on match (the historical contract).
#   stdin mode — the Claude Code PreToolUse protocol: JSON on stdin
#     (.tool_input.command; $CLAUDE_TOOL_INPUT_COMMAND never existed). On
#     match the hook emits permissionDecision "deny" JSON on stdout and exits
#     0 — the settings wrapper is `|| true`, so the exit code carries no
#     signal on Claude and the stdout JSON is the enforcement channel. This
#     makes the guard genuinely enforcing on Claude for these catastrophic
#     patterns. Fail-open on missing/unparseable input.

CMD="${1:-}"
INPUT_MODE="argv"
if [ -z "$CMD" ] && [ ! -t 0 ]; then
  _payload=$(cat 2>/dev/null || true)
  if [ -n "$_payload" ]; then
    if command -v jq >/dev/null 2>&1; then
      CMD=$(printf '%s' "$_payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || CMD=""
    else
      CMD=$(printf '%s' "$_payload" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command") or "")' 2>/dev/null) || CMD=""
    fi
    if [ -n "$CMD" ]; then INPUT_MODE="stdin"; fi
  fi
fi
[ -z "$CMD" ] && exit 0

# On match: argv mode → GUARD stderr + exit 1; stdin mode → deny JSON on
# stdout + exit 0 (Claude decision protocol).
_deny() {
  echo "GUARD: $1" >&2
  echo "GUARD: command was: $CMD" >&2
  if [ "$INPUT_MODE" = "stdin" ]; then
    _reason="guard-dangerous-commands: $1. Command: $CMD. This pattern is categorically denied (secondary safety layer mirroring the settings deny list). Use a narrower, safer command instead."
    if command -v jq >/dev/null 2>&1; then
      jq -cn --arg r "$_reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    else
      python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":sys.argv[1]}}, separators=(",",":")))' "$_reason"
    fi
    exit 0
  fi
  exit 1
}

DANGEROUS_PATTERNS=(
  # Destructive recursive deletes — system and home paths.
  # NOTE: deliberately NO bare "rm -rf /" entry — as a fixed-substring match it
  # hits EVERY absolute-path rm, including the /tmp cleanup the permission
  # allow-list explicitly permits (on the Codex backend this hook is the real
  # enforcement gate, so the false positive banned /tmp removals outright).
  # Bare `rm -rf /` and `rm -rf /<non-tmp>` are caught by the anchored regex
  # `^rm -rf /(?!tmp)` in DANGEROUS_REGEXES below.
  "rm -rf ~"
  "rm -rf /home"
  "rm -rf /root"
  "rm -rf /etc"
  "rm -rf /usr"
  "rm -rf /var"
  "rm -rf /boot"
  "rm -rf /lib"
  "rm -rf /opt"
  "rm -rf /srv"
  "rm -rf /mnt"
  "rm -rf /media"
  "rm -rf /dev"
  # Disk/filesystem operations
  "dd if="
  "mkfs"
  "fdisk"
  "parted"
  "> /dev/"
  # Secrets
  "cat ~/.ssh/id_rsa"
  "cat ~/.ssh/id_ed25519"
  "cat ~/.aws/credentials"
  "cat /etc/shadow"
  # Docker destructive / privilege-escalating operations
  "docker system prune"
  "docker volume prune"
  "docker run --privileged"
  "docker run --network=host"
  "docker run --pid="
  "docker run --cap-add"
  "docker exec --privileged"
  # System package installation (autonomous agents must not install host packages)
  "sudo apt install"
  "sudo apt-get install"
  "sudo apt upgrade"
  "sudo apt-get upgrade"
  "apt install"
  "apt-get install"
  # Sudo destructive operations
  "sudo rm"
  "sudo dd"
  "sudo mkfs"
  "sudo mount"
  "sudo chown"
  # Broad ownership changes
  "chown -R"
  # Broad recursive permission changes to system paths
  "chmod -R 777"
  "chmod -R 666"
  "chmod -R 000"
  # Parent-traversing recursive deletes
  "rm -rf ../"
  "rm -rf ../../"
)

for pattern in "${DANGEROUS_PATTERNS[@]}"; do
  if echo "$CMD" | grep -qF "$pattern"; then
    _deny "dangerous pattern detected: '$pattern'"
  fi
done

# Regex checks for patterns that require wildcard matching
DANGEROUS_REGEXES=(
  # mv/cp targeting system directories
  "^(mv|cp) .+ /(etc|usr|boot|lib|var|root|sys|proc)(/|$)"
  # rm -rf with any absolute path (other than /tmp) — anchored at command
  # start OR after a shell chain separator (;, &&, ||, |, &), so `x && rm -rf /etc`
  # is caught while `rm -rf /tmp/...` cleanup stays permitted.
  "(^|[;&|][[:space:]]*)rm -rf /(?!tmp)"
  # Keyword/wrapper-prefixed rm -rf of absolute paths (other than /tmp): the
  # shell-control-flow allow entries (for/do/then/...) put destructive commands
  # mid-segment where the anchored regex above never fires — e.g.
  # `for i in 1; do rm -rf /etc; done` or `timeout 30 rm -rf /usr`. Same /tmp
  # carve-out as above so tmp cleanup inside loops stays permitted.
  "(^|[;&|][[:space:]]*)(do|then|else|env|nohup|timeout[[:space:]]+[0-9]+[a-z]*)[[:space:]]+(sudo[[:space:]]+)?rm -rf /(?!tmp)"
  # chown with absolute path targets
  "^(sudo )?chown .+ /(etc|usr|home|root|var|boot)"
  # docker run mounting host filesystem sensitive directories
  "docker run .*(-v|--volume) /(etc|usr|root|home|var|boot|lib|sys|proc)"
)

for regex in "${DANGEROUS_REGEXES[@]}"; do
  if echo "$CMD" | grep -qP "$regex" 2>/dev/null; then
    _deny "dangerous pattern detected (regex): '$regex'"
  fi
done

exit 0
