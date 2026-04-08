#!/usr/bin/env bash
# update-docs.sh — Update architecture documentation
# Usage:
#   ./scripts/automation/update-docs.sh --framework     # Update framework docs (.claude/architecture/)
#   ./scripts/automation/update-docs.sh phase-3          # Update project docs (docs/architecture/) after a phase
#
# Framework mode: reads source files and updates .claude/architecture/*.md for drift
# Project mode: reads phase artifacts and updates docs/architecture/*.md
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

MODE=""
PHASE=""

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --framework) MODE="framework" ;;
    --help|-h)
      echo "Usage:"
      echo "  $0 --framework          Update framework architecture docs"
      echo "  $0 <phase-id>           Update project architecture docs after a phase"
      exit 0
      ;;
    *)
      if [[ -z "$MODE" ]]; then
        MODE="project"
        PHASE="$arg"
      fi
      ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "Usage: $0 --framework | $0 <phase-id>" >&2
  exit 1
fi

require_claude

log() { echo "[update-docs] $*"; }

if [[ "$MODE" == "framework" ]]; then
  log "Updating framework architecture documentation..."

  cd "$REPO_ROOT"
  claude_with_quota_retry -p "You are updating the framework's architecture documentation.

Read the architecture doc updater skill: .claude/skills/architecture-doc-updater.md

Source of truth files to read:
- .claude/agents/*.md (all agent definitions)
- .claude/skills/*.md (all skill files)
- .claude/hooks/*.sh (all hook scripts — first 10 lines for purpose)
- scripts/automation/*.sh (list for count)
- templates/* (list for count)
- config/agent-models.yaml (model tier assignments)
- scripts/automation/run-phase.sh (pipeline steps — look for 'Step N/11' comments)
- CLAUDE.md (constitution tables)

Architecture docs to update:
- .claude/architecture/system-overview.md
- .claude/architecture/pipeline.md
- .claude/architecture/agents.md
- .claude/architecture/artifacts.md
- .claude/architecture/skills-and-hooks.md
- .claude/architecture/configuration.md

For each doc:
1. Read the current content
2. Compare counts, lists, and tables against source files
3. Update only sections that have drifted
4. Do not rewrite sections that are already accurate

Rules:
- Factual only — document what exists, never invent
- Maintain existing structure
- Update counts and tables, do not add commentary
- If everything is accurate, make no changes

Report what you changed (or 'no changes needed') and STOP."

  log "Framework docs update complete."

elif [[ "$MODE" == "project" ]]; then
  if [[ -z "$PHASE" ]]; then
    echo "Error: project mode requires a phase argument" >&2
    echo "Usage: $0 <phase-id>" >&2
    exit 1
  fi

  log "Updating project architecture documentation for $PHASE..."

  # Create docs/architecture/ from template if it does not exist
  if [[ ! -d "$REPO_ROOT/docs/architecture" ]]; then
    mkdir -p "$REPO_ROOT/docs/architecture"
    if [[ -f "$REPO_ROOT/templates/architecture-overview.md" ]]; then
      cp "$REPO_ROOT/templates/architecture-overview.md" "$REPO_ROOT/docs/architecture/overview.md"
      log "Created docs/architecture/overview.md from template"
    fi
  fi

  cd "$REPO_ROOT"
  claude_with_quota_retry -p "You are updating the project's architecture documentation after phase $PHASE completed.

Read the architecture doc updater skill: .claude/skills/architecture-doc-updater.md

Context files to read:
- docs/goal.md (project goal — vision and key capabilities)
- .claude/project-template.md (stack, architecture principles)

Phase artifacts to read:
- runs/$PHASE/plan.md (what was planned)
- docs/handoffs/${PHASE}-dev.md (what was built)
- reports/phase-${PHASE}-implementation-summary.md (implementation details)
- reports/phase-${PHASE}-user-visible-changes.md (user-visible changes)

Architecture docs to update:
- docs/architecture/overview.md (or create if missing)

For the overview doc:
1. Read current content
2. Add new components, endpoints, models built in this phase
3. Update data model if schema changed
4. Update API endpoint list if routes changed
5. Mark capability status (complete/in-progress)

Rules:
- Factual only — document what the phase actually built
- Add to existing tables, do not replace them
- Do not remove entries from prior phases
- If no architecture-relevant changes, make no changes

Report what you changed (or 'no changes needed') and STOP."

  log "Project docs update for $PHASE complete."
fi
