"""
Codex adapter: render the neutral canonical source into `.codex/`.

Generates:
  .codex/agents/<name>.toml         (per-agent spec)
  .codex/agents/<name>.body.md      (instructions file referenced by the toml)
  .codex/config.toml                (model defaults, sandbox, hooks, MCP servers)
  .codex/skills/<name>.md           (mirrored from skills/)
  .codex/hooks/<name>.sh            (mirrored from hooks/)
  AGENTS.md (at project root)       (built from .claude/core.md + workflow.md; Codex auto-discovers)

Codex destination is project-local (.codex/) to avoid clobbering user-global
~/.codex/ when this framework runs on multiple projects. The first-run sync
step in run-phase.sh / run-goal.sh ensures Codex is configured to trust this
project root.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

_HERE = Path(__file__).resolve()
sys.path.insert(0, str(_HERE.parents[2]))

from adapters.lib import translate as T  # noqa: E402

CODEX_DIR = T.REPO / ".codex"
CODEX_AGENTS = CODEX_DIR / "agents"
CODEX_SKILLS = CODEX_DIR / "skills"
CODEX_HOOKS = CODEX_DIR / "hooks"
CODEX_CONFIG = CODEX_DIR / "config.toml"
AGENTS_MD = T.REPO / "AGENTS.md"


# ── Minimal TOML emitter ──────────────────────────────────────────────────────
# Hand-written to avoid an external dep. Handles the subset we need: strings,
# numbers, booleans, arrays of strings, inline tables, and sections.


def _toml_str(s: str) -> str:
    if "\n" in s:
        # multi-line; escape """ and backslash
        escaped = s.replace("\\", "\\\\").replace('"""', '\\"""')
        return f'"""\n{escaped}\n"""'
    escaped = s.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def _toml_value(v: Any) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return _toml_str(v)
    if isinstance(v, list):
        return "[" + ", ".join(_toml_value(x) for x in v) + "]"
    if v is None:
        return '""'
    raise TypeError(f"can't encode {v!r} ({type(v).__name__}) as TOML")


def _toml_kv(k: str, v: Any) -> str:
    return f"{k} = {_toml_value(v)}"


def _toml_section(title: str, fields: dict[str, Any]) -> str:
    lines = [f"[{title}]"]
    for k, v in fields.items():
        lines.append(_toml_kv(k, v))
    return "\n".join(lines)


# ── Agent files ───────────────────────────────────────────────────────────────


def render_agent_toml(spec: T.AgentSpec, tiers: dict) -> str:
    model = spec.codex_overrides.get("model_override") or T.resolve_model(
        spec.model_tier, "codex", tiers
    )
    sandbox = spec.codex_overrides.get("sandbox", "workspace-write")
    ask_for_approval = spec.codex_overrides.get("ask_for_approval", "on-request")

    meta = {
        "name": spec.name,
        "description": spec.description.replace("\n", " ").strip(),
    }
    if spec.version:
        meta["version"] = spec.version

    parts = [_toml_section("meta", meta)]
    parts.append(_toml_section("model", {"id": model}))
    parts.append(_toml_section("sandbox", {"mode": sandbox, "ask_for_approval": ask_for_approval}))

    tools_block: dict[str, Any] = {}
    if spec.tools_allowed:
        tools_block["allowed"] = T.map_tools(spec.tools_allowed, "codex")
    if spec.tools_disallowed:
        # Pass disallowed names through; Codex doesn't have first-class disallow but
        # PermissionRequest hook can consult this list.
        tools_block["disallowed"] = list(spec.tools_disallowed)
    if tools_block:
        parts.append(_toml_section("tools", tools_block))

    if spec.max_budget_usd is not None:
        parts.append(_toml_section("budget", {"max_usd": spec.max_budget_usd}))

    # MCP servers referenced by this agent (if any in escape-hatch)
    mcp_servers = spec.codex_overrides.get("mcp_servers") or []
    if mcp_servers:
        parts.append(_toml_section("mcp", {"servers": list(mcp_servers)}))

    # Instructions live next to the toml in a sibling .body.md
    parts.append(f'instructions_file = "{spec.name}.body.md"')
    return "\n\n".join(parts) + "\n"


def sync_agents(*, dry_run: bool = False) -> int:
    tiers = T.load_model_tiers()
    specs = T.load_agents()
    written = 0
    expected: set[Path] = set()
    for spec in specs:
        toml_path = CODEX_AGENTS / f"{spec.name}.toml"
        body_path = CODEX_AGENTS / f"{spec.name}.body.md"
        expected.add(toml_path)
        expected.add(body_path)
        rendered_toml = render_agent_toml(spec, tiers)
        if not (toml_path.exists() and toml_path.read_text(encoding="utf-8") == rendered_toml):
            if not dry_run:
                toml_path.parent.mkdir(parents=True, exist_ok=True)
                toml_path.write_text(rendered_toml, encoding="utf-8")
            written += 1
        if not (body_path.exists() and body_path.read_text(encoding="utf-8") == spec.body):
            if not dry_run:
                body_path.parent.mkdir(parents=True, exist_ok=True)
                body_path.write_text(spec.body, encoding="utf-8")
            written += 1
    if CODEX_AGENTS.exists():
        for f in list(CODEX_AGENTS.glob("*.toml")) + list(CODEX_AGENTS.glob("*.body.md")):
            if f not in expected:
                if dry_run:
                    written += 1
                    continue
                f.unlink()
    return written


# ── config.toml ───────────────────────────────────────────────────────────────


def render_config_toml() -> str:
    perms = T.load_permissions()
    bindings = T.load_hook_bindings()
    mcp = T.load_mcp_servers()
    tiers = T.load_model_tiers()

    parts: list[str] = []
    parts.append(_toml_section("model", {"default": tiers.get("standard", {}).get("codex", "gpt-5-codex")}))
    parts.append(
        _toml_section(
            "sandbox",
            {
                "default": perms.get("codex_default_sandbox", "workspace-write"),
                "ask_for_approval": perms.get("codex_default_approval", "on-request"),
            },
        )
    )

    # Hooks block: one [[hooks]] entry per (script, event) pair.
    hooks_text: list[str] = []
    for basename, mapping in bindings.items():
        for event in mapping.get("codex", []) or []:
            hooks_text.append("[[hooks]]")
            hooks_text.append(_toml_kv("event", event))
            hooks_text.append(_toml_kv("command", f"bash $CODEX_PROJECT_DIR/.codex/hooks/{basename}"))
            hooks_text.append("")
    if hooks_text:
        parts.append("\n".join(hooks_text).rstrip())

    # MCP servers
    for name, cfg in mcp.items():
        if not isinstance(cfg, dict):
            continue
        parts.append(_toml_section(f"mcp_servers.{name}", cfg))

    # Trust project root so Codex respects .codex/config.toml
    parts.append(_toml_section("project", {"path": str(T.REPO), "trusted": True}))

    return "\n\n".join(parts) + "\n"


def sync_config(*, dry_run: bool = False) -> int:
    rendered = render_config_toml()
    if CODEX_CONFIG.exists() and CODEX_CONFIG.read_text(encoding="utf-8") == rendered:
        return 0
    if dry_run:
        return 1
    CODEX_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    CODEX_CONFIG.write_text(rendered, encoding="utf-8")
    return 1


# ── Skills + hooks (verbatim mirror) ──────────────────────────────────────────


def sync_skills(*, dry_run: bool = False) -> int:
    return T.mirror_directory(T.NEUTRAL_SKILLS, CODEX_SKILLS, dry_run=dry_run)


def sync_hooks(*, dry_run: bool = False) -> int:
    # Same reasoning as Claude side: hooks are invoked via `bash <path>`.
    return T.mirror_directory(T.NEUTRAL_HOOKS, CODEX_HOOKS, dry_run=dry_run)


# ── AGENTS.md (project root, picked up by Codex automatically) ────────────────


def render_agents_md() -> str:
    """Synthesize an AGENTS.md from the existing framework docs.

    Codex auto-discovers AGENTS.md at the project root and uses it as global
    instructions. We surface the same rules Claude reads from CLAUDE.md so the
    two CLIs share a baseline behaviour set.
    """
    pieces: list[str] = []
    pieces.append("# AGENTS.md\n")
    pieces.append(
        "_This file is auto-generated by `adapters/codex/sync.py` from the neutral "
        "framework source. Edit `.claude/core.md` / `.claude/workflow.md` instead._\n"
    )
    claude_md = T.REPO / "CLAUDE.md"
    if claude_md.exists():
        pieces.append("\n## Project Constitution (from CLAUDE.md)\n")
        pieces.append(claude_md.read_text(encoding="utf-8"))
    for f in (T.REPO / ".claude" / "core.md", T.REPO / ".claude" / "workflow.md"):
        if f.exists():
            pieces.append(f"\n## {f.name}\n")
            pieces.append(f.read_text(encoding="utf-8"))
    return "\n".join(pieces)


def sync_agents_md(*, dry_run: bool = False) -> int:
    rendered = render_agents_md()
    if AGENTS_MD.exists() and AGENTS_MD.read_text(encoding="utf-8") == rendered:
        return 0
    if dry_run:
        return 1
    AGENTS_MD.write_text(rendered, encoding="utf-8")
    return 1


# ── Entry point ───────────────────────────────────────────────────────────────


def sync_all(*, dry_run: bool = False) -> dict[str, int]:
    return {
        "agents": sync_agents(dry_run=dry_run),
        "config": sync_config(dry_run=dry_run),
        "skills": sync_skills(dry_run=dry_run),
        "hooks": sync_hooks(dry_run=dry_run),
        "AGENTS.md": sync_agents_md(dry_run=dry_run),
    }


def main(argv: list[str]) -> int:
    dry_run = "--dry-run" in argv
    counts = sync_all(dry_run=dry_run)
    label = "would change" if dry_run else "wrote"
    for k, v in counts.items():
        print(f"  codex/{k}: {label} {v}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
