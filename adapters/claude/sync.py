"""
Claude adapter: render the neutral canonical source into `.claude/`.

Generates:
  .claude/agents/<name>.md     (frontmatter + body)
  .claude/settings.json        (permissions + hooks + passthrough plugins)
  .claude/skills/<name>.md     (mirrored from skills/)
  .claude/hooks/<name>.sh      (mirrored from hooks/)
  .claude/commands/<name>.md   (slash commands, mirrored from commands/)

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

# Load the per-agent permission policy (the single source of truth for tool
# denials) so we can MATERIALIZE each agent's disallowed_tools into frontmatter.
# Headless `claude -p` applies these via --disallowedTools at runtime; subagent
# dispatch (the interactive backend) instead reads them from the agent's
# frontmatter, so writing them here keeps the two execution paths equivalent.
import importlib.util as _ilu  # noqa: E402
_AP_PATH = T.REPO / "scripts" / "automation" / "lib" / "agent_permissions.py"
_ap_spec = _ilu.spec_from_file_location("agent_permissions", _AP_PATH)
_agent_permissions = _ilu.module_from_spec(_ap_spec)
_ap_spec.loader.exec_module(_agent_permissions)

CLAUDE_DIR = T.REPO / ".claude"
CLAUDE_AGENTS = CLAUDE_DIR / "agents"
CLAUDE_SKILLS = CLAUDE_DIR / "skills"
CLAUDE_HOOKS = CLAUDE_DIR / "hooks"
CLAUDE_COMMANDS = CLAUDE_DIR / "commands"
CLAUDE_SETTINGS = CLAUDE_DIR / "settings.json"
CLAUDE_SETTINGS_LOCAL = CLAUDE_DIR / "settings.local.json"
MCP_JSON = T.PROJECT_ROOT / ".mcp.json"


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


def _disallowed_tools_for(spec: T.AgentSpec) -> list[str]:
    """Full deny list for an agent: hard defaults (all agents) + the non-release
    git/merge denials (unless this is the release agent) + any agent.yaml extras.
    Mirrors agent_permissions.disallowed_for but reads the already-loaded spec
    (no filesystem access) so sync stays deterministic and CWD-independent."""
    ap = _agent_permissions
    denials: list[str] = list(ap.HARD_DEFAULT_DENIALS_ALL)
    if spec.name != ap.RELEASE_AGENT_NAME:
        denials.extend(ap.HARD_DEFAULT_DENIALS_NON_RELEASE)
    for x in (spec.tools_disallowed or []):
        if isinstance(x, str) and x and x not in denials:
            denials.append(x)
    return denials


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
    _denials = _disallowed_tools_for(spec)
    if _denials:
        fields["disallowed_tools"] = _yaml_inline_list(_denials)
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


def sync_commands(*, dry_run: bool = False) -> int:
    # Slash commands are a Claude Code concept: project `.claude/commands/*.md`
    # are auto-discovered as `/<filename>`. Mirrored verbatim from neutral source.
    return T.mirror_directory(T.NEUTRAL_COMMANDS, CLAUDE_COMMANDS, dry_run=dry_run)


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
            # Claude Code passes hook input as JSON on stdin (.tool_input.*);
            # $CLAUDE_TOOL_INPUT_COMMAND / $CLAUDE_TOOL_INPUT_FILE_PATH were
            # never real env vars, so every hook reads stdin itself (argv
            # remains the test-harness / Codex path): the PreToolUse guards
            # extract .tool_input.command and return decisions as
            # hookSpecificOutput JSON on stdout with exit 0 (SEC-7); the
            # PostToolUse hooks extract .tool_input.file_path and stay
            # advisory (stderr warnings only, CTX-1). Every hook is wrapped
            # `|| true`: on Claude the exit code carries no signal (exit 1 is
            # a NON-blocking error; stdout JSON is the decision channel) and a
            # hook crash must never surface into the transcript.
            # install-security-gate keeps stderr un-redirected so its warn
            # banners reach debug logs.
            tail = " || true" if basename == "install-security-gate.sh" else " 2>/dev/null || true"
            cmd_path = f"$CLAUDE_PROJECT_DIR/.claude/hooks/{basename}"
            entries.append(
                {
                    "matcher": matcher,
                    "hooks": [
                        {
                            "type": "command",
                            "command": f'bash "{cmd_path}"{tail}',
                        }
                    ],
                }
            )
        out[event] = entries
    return out


# ── MCP servers (project .mcp.json + settings trust) ──────────────────────────

# Keys Claude Code understands in a .mcp.json server entry; CLI-specific extras
# in the neutral server cfg are dropped so the generated file stays valid.
_CLAUDE_MCP_KEYS = ("command", "args", "env", "url", "headers", "timeout")


def _claude_mcp_server(cfg: dict) -> dict:
    out: dict = {"type": cfg.get("type", "stdio")}
    for k in _CLAUDE_MCP_KEYS:
        if k in cfg:
            out[k] = cfg[k]
    return out


def _mcp_allow_entries(servers: dict) -> list[str]:
    """Whole-server allow tokens (mcp__<name>) in deterministic order, so every
    tool a configured server exposes is usable headlessly without a prompt."""
    return [f"mcp__{name}" for name in sorted(servers)]


def _settings_local_with_mcp(existing: dict, servers: dict) -> dict:
    """Merge MCP trust + allow into an existing settings.local.json object,
    preserving everything already there. This goes to the project-LOCAL settings
    file so the shared, subtree-tracked settings.json is never touched."""
    desired = dict(existing)
    desired["enableAllProjectMcpServers"] = True
    perms = dict(desired.get("permissions") or {})
    allow = list(perms.get("allow") or [])
    for entry in _mcp_allow_entries(servers):
        if entry not in allow:
            allow.append(entry)
    perms["allow"] = allow
    desired["permissions"] = perms
    return desired


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
    # Additional working directories (policy `additionalDirectories`). Claude
    # Code's built-in rm containment only permits deletion inside the session's
    # working directories — /tmp must be granted here or agents can create
    # temp files (pytest, playwright, logs) they can never remove.
    if perms.get("additionalDirectories"):
        settings["permissions"]["additionalDirectories"] = list(perms["additionalDirectories"])
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


def sync_mcp_json(*, dry_run: bool = False) -> int:
    """Write .mcp.json at the project root from the merged server set. With no
    servers (the default until a project opts in) do nothing — never create or
    delete the file — so generated config is byte-identical to before."""
    servers = T.merged_mcp_servers()
    if not servers:
        return 0
    obj = {"mcpServers": {name: _claude_mcp_server(cfg) for name, cfg in servers.items()}}
    rendered = json.dumps(obj, indent=2, ensure_ascii=False) + "\n"
    if MCP_JSON.exists() and MCP_JSON.read_text(encoding="utf-8") == rendered:
        return 0
    if dry_run:
        return 1
    MCP_JSON.write_text(rendered, encoding="utf-8")
    return 1


def sync_settings_local(*, dry_run: bool = False) -> int:
    """Emit the project's MCP trust + allow into .claude/settings.local.json — the
    project-LOCAL settings file — so the shared, subtree-tracked .claude/settings.json
    is NEVER altered by a project overlay (and can never carry one project's servers
    upstream). Existing local settings are preserved. No servers ⇒ left untouched."""
    servers = T.merged_mcp_servers()
    if not servers:
        return 0
    existing: dict = {}
    if CLAUDE_SETTINGS_LOCAL.exists():
        try:
            existing = json.loads(CLAUDE_SETTINGS_LOCAL.read_text(encoding="utf-8")) or {}
        except (OSError, json.JSONDecodeError):
            existing = {}
    rendered = json.dumps(_settings_local_with_mcp(existing, servers), indent=2, ensure_ascii=False) + "\n"
    if CLAUDE_SETTINGS_LOCAL.exists() and CLAUDE_SETTINGS_LOCAL.read_text(encoding="utf-8") == rendered:
        return 0
    if dry_run:
        return 1
    CLAUDE_SETTINGS_LOCAL.write_text(rendered, encoding="utf-8")
    return 1


# ── Entry point ───────────────────────────────────────────────────────────────


def sync_all(*, dry_run: bool = False) -> dict[str, int]:
    return {
        "agents": sync_agents(dry_run=dry_run),
        "settings": sync_settings(dry_run=dry_run),
        "mcp": sync_mcp_json(dry_run=dry_run),
        "mcp_local": sync_settings_local(dry_run=dry_run),
        "skills": sync_skills(dry_run=dry_run),
        "hooks": sync_hooks(dry_run=dry_run),
        "commands": sync_commands(dry_run=dry_run),
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
