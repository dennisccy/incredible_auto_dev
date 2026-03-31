#!/usr/bin/env bash
# sync-agent-models.sh
# Reads config/agent-models.yaml and updates model: declarations in .claude/agents/*.md
# Run this after editing config/agent-models.yaml to propagate changes.
#
# Usage: ./scripts/automation/sync-agent-models.sh [--dry-run]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="$REPO_ROOT/config/agent-models.yaml"
AGENTS_DIR="$REPO_ROOT/.claude/agents"
DRY_RUN=false

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: config file not found: $CONFIG" >&2
  exit 1
fi

# Parse tier -> model from tiers: block
declare -A TIER_MODEL
while IFS= read -r line; do
  if [[ "$line" =~ ^[[:space:]]+(strong|standard|light):[[:space:]]+([a-z0-9_.:-]+) ]]; then
    TIER_MODEL["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
  fi
done < "$CONFIG"

if [[ ${#TIER_MODEL[@]} -eq 0 ]]; then
  echo "ERROR: could not parse tiers from $CONFIG" >&2
  exit 1
fi

echo "Tiers loaded:"
for tier in strong standard light; do
  echo "  $tier -> ${TIER_MODEL[$tier]:-MISSING}"
done
echo ""

# Parse agent -> tier from agents: block
in_agents=false
changed=0
skipped=0

while IFS= read -r line; do
  if [[ "$line" =~ ^agents: ]]; then
    in_agents=true
    continue
  fi
  [[ "$in_agents" == false ]] && continue
  [[ "$line" =~ ^[a-z] && "$line" == *: ]] && break

  if [[ "$line" =~ ^[[:space:]]+([a-z_-]+):[[:space:]]+(strong|standard|light) ]]; then
    agent="${BASH_REMATCH[1]}"
    tier="${BASH_REMATCH[2]}"
    model="${TIER_MODEL[$tier]:-}"

    if [[ -z "$model" ]]; then
      echo "  WARN: no model for tier '$tier' (agent: $agent), skipping"
      continue
    fi

    agent_file="$AGENTS_DIR/${agent}.md"
    if [[ ! -f "$agent_file" ]]; then
      echo "  WARN: agent file not found: $agent_file, skipping"
      continue
    fi

    current_model=$(grep -m1 "^model:" "$agent_file" | sed 's/^model:[[:space:]]*//')
    if [[ "$current_model" == "$model" ]]; then
      printf "  %-20s %-12s -> %-30s (already correct)\n" "$agent" "[$tier]" "$model"
      skipped=$((skipped + 1))
    else
      printf "  %-20s %-12s -> %-30s (was: %s)\n" "$agent" "[$tier]" "$model" "$current_model"
      if [[ "$DRY_RUN" == false ]]; then
        sed -i "s/^model: .*/model: $model/" "$agent_file"
      fi
      changed=$((changed + 1))
    fi
  fi
done < "$CONFIG"

echo ""
if [[ "$DRY_RUN" == true ]]; then
  echo "Dry run: $changed would change, $skipped already correct."
else
  echo "Done: $changed updated, $skipped already correct."
fi
