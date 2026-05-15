"""
Claude adapter: render the neutral canonical source into `.claude/`.

Generates:
  .claude/agents/<name>.md     (frontmatter + body)
  .claude/settings.json        (permissions + hooks + passthrough plugins)
  .claude/skills/<name>.md     (mirrored from skills/)
  .claude/hooks/<name>.sh      (mirrored from hooks/)

Leaves alone:
  .claude/core.md, workflow.md, anti-patterns.md, project-template.md
  .claude/architecture/
  .claude/settings.local.json, .example
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

# Make the adapters package importable when this file is run directly.
_HERE = Path(__file__).resolve()
sys.path.insert(0, str(_HERE.parents[2]))

from adapters.lib import translate as T  # noqa: E402

CLAUDE_DIR = T.REPO / ".claude"
CLAUDE_AGENTS = CLAUDE_DIR / "agents"
CLAUDE_SKILLS = CLAUDE_DIR / "skills"
CLAUDE_HOOKS = CLAUDE_DIR / "hooks"
CLAUDE_SETTINGS = CLAUDE_DIR / "settings.json"


# ── Agent file rendering ──────────────────────────────────────────────────────

# Field ordering matches today's hand-written .claude/agents/*.md files so
# semantic equivalence is straightforward to verify after migration.
FRONTMATTER_FIELDS = ("name", "description", "model", "tools", "disallowed_tools",
                      "max_budget_usd", "version", "last_updated")


def _yaml_inline_list(items: list[str]) -> str:
    """[a, b, c] form, with strings only quoted when they would otherwise parse weirdly."""
    rendered = []
    for it in items:
        if any(c in it for c in ", []#&*!|>'\"%@`") or it != it.strip():
            rendered.append(json.dumps(it))  # safe quoting
        else:
            rendered.append(it)
    return "[" + ", ".join(rendered) + "]"


def render_agent_md(spec: T.AgentSpec, tiers: dict) -> str:
    model = spec.claude_overrides.get("model_override") or T.resolve_model(
        spec.model_tier, "claude", tiers
    )
    fields: dict[str, str] = {
        "name": spec.name,
        "description": spec.description.replace("\n", " ").strip(),
        "model": model,
    }
    if spec.tools_allowed:
        # Map neutral tool names → Claude vocabulary; pass-through if unknown.
        mapped = T.map_tools(spec.tools_allowed, "claude")
        fields["tools"] = _yaml_inline_list(mapped)
    if spec.tools_disallowed:
        fields["disallowed_tools"] = _yaml_inline_list(spec.tools_disallowed)
    if spec.max_budget_usd is not None:
        fields["max_budget_usd"] = f"{spec.max_budget_usd:g}"
    if spec.version:
        fields["version"] = spec.version
    if spec.last_updated:
        fields["last_updated"] = str(spec.last_updated)

    lines = ["---"]
    for k in FRONTMATTER_FIELDS:
        if k in fields:
            lines.append(f"{k}: {fields[k]}")
    lines.append("---")
    body = spec.body
    if not body.startswith("\n"):
        lines.append("")  # blank line before body for readability
    return "\n".join(lines) + "\n" + body


def sync_agents(*, dry_run: bool = False) -> int:
    """Generate .claude/agents/<name>.md for every neutral spec; remove stragglers."""
    tiers = T.load_model_tiers()
    specs = T.load_agents()
    written = 0
    expected_files = set()
    for spec in specs:
        out = CLAUDE_AGENTS / f"{spec.name}.md"
        expected_files.add(out)
        rendered = render_agent_md(spec, tiers)
        if out.exists() and out.read_text(encoding="utf-8") == rendered:
            continue
        if dry_run:
            written += 1
            continue
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(rendered, encoding="utf-8")
        written += 1
    # remove any agents/*.md not in the neutral source
    if CLAUDE_AGENTS.exists():
        for f in CLAUDE_AGENTS.glob("*.md"):
            if f not in expected_files:
                if dry_run:
                    written += 1
                    continue
                f.unlink()
    return written


# ── Skills + hooks (verbatim mirror) ──────────────────────────────────────────


def sync_skills(*, dry_run: bool = False) -> int:
    return T.mirror_directory(T.NEUTRAL_SKILLS, CLAUDE_SKILLS, dry_run=dry_run)


def sync_hooks(*, dry_run: bool = False) -> int:
    # Hooks are invoked as `bash <path>` from settings.json, so the executable
    # bit doesn't matter. Don't touch mode — keeps git-status quiet.
    return T.mirror_directory(T.NEUTRAL_HOOKS, CLAUDE_HOOKS, dry_run=dry_run)


# ── settings.json ─────────────────────────────────────────────────────────────


def _hooks_block_for_claude() -> dict:
    """Reconstruct the .claude/settings.json `hooks` block from policy/hook-bindings.yaml.

    Each Claude binding is a token like "PreToolUse:Bash" or "Stop"; we group
    by event and emit the standard claude hooks-array shape.
    """
    bindings = T.load_hook_bindings()
    by_event: dict[str, list[tuple[str, str]]] = {}  # event → [(matcher, basename)]
    for basename, mapping in bindings.items():
        for token in mapping.get("claude", []) or []:
            if ":" in token:
                event, matcher = token.split(":", 1)
            else:
                event, matcher = token, ".*"
            by_event.setdefault(event, []).append((matcher, basename))

    out: dict = {}
    # Preserve the historical event order (PreToolUse, PostToolUse, Stop)
    event_order = ["PreToolUse", "PostToolUse", "Stop", "SessionStart", "UserPromptSubmit"]
    for event in event_order + [e for e in by_event if e not in event_order]:
        if event not in by_event:
            continue
        entries = []
        for matcher, basename in by_event[event]:
            # Hooks that may legitimately fail are wrapped with `2>/dev/null || true`
            # to match the historical shape. install-security-gate is the exception:
            # its non-zero exit is meaningful.
            tail = "" if basename == "install-security-gate.sh" else " 2>/dev/null || true"
            cmd_path = f"$CLAUDE_PROJECT_DIR/.claude/hooks/{basename}"
            if basename in {"install-security-gate.sh", "guard-dangerous-commands.sh"}:
                arg = ' "$CLAUDE_TOOL_INPUT_COMMAND"'
            elif event == "PostToolUse":
                arg = ' "$CLAUDE_TOOL_INPUT_FILE_PATH"'
            else:
                arg = ""
            entries.append(
                {
                    "matcher": matcher,
                    "hooks": [
                        {
                            "type": "command",
                            "command": f'bash "{cmd_path}"{arg}{tail}',
                        }
                    ],
                }
            )
        out[event] = entries
    return out


def render_settings_json() -> str:
    perms = T.load_permissions()
    passthrough = T.load_passthrough("claude")

    settings: dict = {}
    # Header comments first (preserved verbatim from migration)
    header = passthrough.get("header") or {}
    for k, v in header.items():
        settings[k] = v
    if "enabledPlugins" in passthrough:
        settings["enabledPlugins"] = passthrough["enabledPlugins"]
    if "marketplaces" in passthrough:
        settings["extraKnownMarketplaces"] = passthrough["marketplaces"]
    settings["permissions"] = {
        "allow": list(perms.get("allow", [])),
        "deny": list(perms.get("deny", [])),
    }
    settings["hooks"] = _hooks_block_for_claude()
    # ensure_ascii=False keeps em-dashes and other unicode readable
    return json.dumps(settings, indent=2, ensure_ascii=False) + "\n"


def sync_settings(*, dry_run: bool = False) -> int:
    rendered = render_settings_json()
    if CLAUDE_SETTINGS.exists() and CLAUDE_SETTINGS.read_text(encoding="utf-8") == rendered:
        return 0
    if dry_run:
        return 1
    CLAUDE_SETTINGS.write_text(rendered, encoding="utf-8")
    return 1


# ── Entry point ───────────────────────────────────────────────────────────────


def sync_all(*, dry_run: bool = False) -> dict[str, int]:
    return {
        "agents": sync_agents(dry_run=dry_run),
        "settings": sync_settings(dry_run=dry_run),
        "skills": sync_skills(dry_run=dry_run),
        "hooks": sync_hooks(dry_run=dry_run),
    }


def main(argv: list[str]) -> int:
    dry_run = "--dry-run" in argv
    counts = sync_all(dry_run=dry_run)
    label = "would change" if dry_run else "wrote"
    for k, v in counts.items():
        print(f"  claude/{k}: {label} {v}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
