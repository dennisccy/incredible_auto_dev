#!/usr/bin/env bash
# Guard hook: secondary check for dangerous command patterns
# Primary protection is the deny rules in .claude/settings.json
# This hook provides a redundant safety layer for critical patterns
#
# Note: called with || true in settings.json so hook errors never block normal work.
# Deny rules in settings.json are what require user approval.

CMD="${1:-}"
[ -z "$CMD" ] && exit 0

DANGEROUS_PATTERNS=(
  # Destructive recursive deletes — system and home paths
  "rm -rf /"
  "rm -rf ~"
  "rm -rf /home"
  "rm -rf /root"
  "rm -rf /etc"
  "rm -rf /usr"
  "rm -rf /var"
  "rm -rf /boot"
  "rm -rf /lib"
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
    echo "GUARD: dangerous pattern detected: '$pattern'" >&2
    echo "GUARD: command was: $CMD" >&2
    exit 1
  fi
done

# Regex checks for patterns that require wildcard matching
DANGEROUS_REGEXES=(
  # mv/cp targeting system directories
  "^(mv|cp) .+ /(etc|usr|boot|lib|var|root|sys|proc)(/|$)"
  # rm -rf with any absolute path (other than /tmp)
  "^rm -rf /(?!tmp)"
  # chown with absolute path targets
  "^(sudo )?chown .+ /(etc|usr|home|root|var|boot)"
  # docker run mounting host filesystem sensitive directories
  "docker run .*(-v|--volume) /(etc|usr|root|home|var|boot|lib|sys|proc)"
)

for regex in "${DANGEROUS_REGEXES[@]}"; do
  if echo "$CMD" | grep -qP "$regex" 2>/dev/null; then
    echo "GUARD: dangerous pattern detected (regex): '$regex'" >&2
    echo "GUARD: command was: $CMD" >&2
    exit 1
  fi
done

exit 0
