#!/usr/bin/env python3
"""
One-shot migration: extract a CLI-neutral canonical source tree from the existing
.claude/ layout. Run once; not re-run after migration.

Produces:
  agents/<name>/agent.yaml            — neutral agent spec (model_tier, tools, ...)
  agents/<name>/body.md               — instruction prose (verbatim from old body)
  skills/<name>.md                    — copies from .claude/skills/
  hooks/<name>.sh                     — copies from .claude/hooks/
  policy/permissions.yaml             — neutral allow/deny lists
  policy/hook-bindings.yaml           — hook → CLI events mapping
  policy/mcp-servers.yaml             — placeholder (no neutral MCP today)
  config/model-tiers.yaml             — tier → per-CLI model id (replaces agent-models.yaml)
  adapters/tool-name-map.yaml         — neutral tool name → per-CLI native
  adapters/claude/passthrough/enabledPlugins.json  — claude-only plugins fragment
  adapters/claude/passthrough/marketplaces.json    — claude-only marketplaces fragment

Idempotent: rerunning overwrites the generated files. Existing .claude/ is left untouched.
"""

from __future__ import annotations

import json
import re
import shutil
import sys
from pathlib import Path
from typing import Any

import yaml

REPO = Path(__file__).resolve().parents[3]
CLAUDE = REPO / ".claude"

OUT_AGENTS = REPO / "agents"
OUT_SKILLS = REPO / "skills"
OUT_HOOKS = REPO / "hooks"
OUT_POLICY = REPO / "policy"
OUT_CONFIG = REPO / "config"
OUT_ADAPTERS = REPO / "adapters"

# ── Frontmatter parser (mirrors lib/agent_permissions.py) ──────────────────────


def parse_frontmatter(text: str) -> tuple[dict[str, Any], str]:
    """Return (frontmatter_dict, body_text). Empty dict if no frontmatter."""
    if not text.startswith("---"):
        return {}, text
    end = text.find("\n---", 3)
    if end == -1:
        return {}, text
    block = text[3:end].strip()
    body_start = end + len("\n---")
    # skip the trailing newline of the closing ---
    if body_start < len(text) and text[body_start] == "\n":
        body_start += 1
    body = text[body_start:]
    fields: dict[str, Any] = {}
    for line in block.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        key = key.strip()
        value = value.strip()
        if value.startswith("[") and value.endswith("]"):
            inner = value[1:-1].strip()
            if not inner:
                fields[key] = []
            else:
                items = []
                for raw in _split_top_level(inner):
                    raw = raw.strip()
                    if raw.startswith('"') and raw.endswith('"'):
                        raw = raw[1:-1]
                    elif raw.startswith("'") and raw.endswith("'"):
                        raw = raw[1:-1]
                    if raw:
                        items.append(raw)
                fields[key] = items
        elif value:
            v = value
            if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
                v = v[1:-1]
            fields[key] = v
    return fields, body


def _split_top_level(s: str) -> list[str]:
    out, depth, cur = [], 0, []
    for ch in s:
        if ch in "([":
            depth += 1
            cur.append(ch)
        elif ch in ")]":
            depth -= 1
            cur.append(ch)
        elif ch == "," and depth == 0:
            out.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    if cur:
        out.append("".join(cur).strip())
    return out


# ── Model tier resolution ─────────────────────────────────────────────────────

# Inverse mapping from current Claude model ids → neutral tier name.
# Source of truth lives in config/agent-models.yaml; this is just for migration.
CLAUDE_MODEL_TO_TIER = {
    "claude-opus-4-7": "strong",
    "claude-sonnet-4-6": "standard",
    "claude-haiku-4-5": "light",
}


def model_to_tier(model_id: str) -> str:
    if not model_id:
        return "standard"
    return CLAUDE_MODEL_TO_TIER.get(model_id, "standard")


# ── Migration steps ────────────────────────────────────────────────────────────


def migrate_agents() -> int:
    src = CLAUDE / "agents"
    OUT_AGENTS.mkdir(parents=True, exist_ok=True)
    count = 0
    for md in sorted(src.glob("*.md")):
        name = md.stem
        text = md.read_text(encoding="utf-8")
        fm, body = parse_frontmatter(text)
        if not fm:
            print(f"  skip {md.name}: no frontmatter", file=sys.stderr)
            continue

        spec: dict[str, Any] = {
            "name": fm.get("name", name),
            "description": fm.get("description", "").strip(),
            "model_tier": model_to_tier(fm.get("model", "")),
        }
        if "tools" in fm and fm["tools"]:
            spec["tools_allowed"] = fm["tools"]
        if "disallowed_tools" in fm and fm["disallowed_tools"]:
            spec["tools_disallowed"] = fm["disallowed_tools"]
        if "max_budget_usd" in fm:
            try:
                spec["max_budget_usd"] = float(fm["max_budget_usd"])
            except (TypeError, ValueError):
                pass
        # Preserve provenance metadata for traceability
        if "version" in fm:
            spec["version"] = fm["version"]
        if "last_updated" in fm:
            spec["last_updated"] = fm["last_updated"]
        spec["body"] = "body.md"

        # Capture original Claude model id as an escape-hatch override so the
        # Claude adapter can emit identical frontmatter byte-for-byte if needed.
        if "model" in fm:
            spec.setdefault("claude", {})["model_override"] = fm["model"]

        out_dir = OUT_AGENTS / name
        out_dir.mkdir(parents=True, exist_ok=True)
        write_yaml(out_dir / "agent.yaml", spec)
        (out_dir / "body.md").write_text(body, encoding="utf-8")
        count += 1
    print(f"agents: migrated {count}")
    return count


def migrate_skills() -> int:
    src = CLAUDE / "skills"
    OUT_SKILLS.mkdir(parents=True, exist_ok=True)
    count = 0
    for md in sorted(src.glob("*.md")):
        shutil.copy2(md, OUT_SKILLS / md.name)
        count += 1
    print(f"skills: copied {count}")
    return count


def migrate_hooks() -> int:
    src = CLAUDE / "hooks"
    OUT_HOOKS.mkdir(parents=True, exist_ok=True)
    count = 0
    for sh in sorted(src.glob("*.sh")):
        shutil.copy2(sh, OUT_HOOKS / sh.name)
        count += 1
    # Make sure hooks/lib exists for the normalize shim placeholders
    (OUT_HOOKS / "lib").mkdir(exist_ok=True)
    print(f"hooks: copied {count} (lib/ placeholder created)")
    return count


def migrate_settings() -> None:
    """Split .claude/settings.json into neutral policy + claude passthrough."""
    settings_path = CLAUDE / "settings.json"
    settings = json.loads(settings_path.read_text(encoding="utf-8"))

    OUT_POLICY.mkdir(parents=True, exist_ok=True)
    passthrough = OUT_ADAPTERS / "claude" / "passthrough"
    passthrough.mkdir(parents=True, exist_ok=True)

    # 1. permissions.yaml — neutral allow/deny + codex defaults
    perms = settings.get("permissions", {})
    perm_doc = {
        "allow": perms.get("allow", []),
        "deny": perms.get("deny", []),
        "codex_default_sandbox": "workspace-write",
        "codex_default_approval": "on-request",
    }
    write_yaml(OUT_POLICY / "permissions.yaml", perm_doc)

    # 2. hook-bindings.yaml — translate Claude hooks block to neutral form.
    # Schema: { <hook_script_basename>: { claude: [events], codex: [events] } }
    bindings: dict[str, dict[str, list[str]]] = {}
    for event_name, entries in settings.get("hooks", {}).items():
        for entry in entries:
            matcher = entry.get("matcher", "*")
            for hook in entry.get("hooks", []):
                cmd = hook.get("command", "")
                m = re.search(r"\.claude/hooks/([^\s\"]+)", cmd)
                if not m:
                    continue
                basename = m.group(1)
                bindings.setdefault(basename, {"claude": [], "codex": []})
                # Preserve the matcher alongside the event name so the adapter
                # can recreate the original Claude binding faithfully.
                token = f"{event_name}:{matcher}" if matcher and matcher != ".*" else event_name
                if token not in bindings[basename]["claude"]:
                    bindings[basename]["claude"].append(token)
    # Sensible Codex defaults: any hook that runs PreToolUse on Claude also runs
    # under PreToolUse + PermissionRequest on Codex. Stop runs Stop. PostToolUse
    # runs PostToolUse. Migration is conservative — operator can refine later.
    for basename, mapping in bindings.items():
        codex_events = []
        for token in mapping["claude"]:
            event = token.split(":", 1)[0]
            if event == "PreToolUse":
                codex_events.extend(["PreToolUse", "PermissionRequest"])
            elif event in ("PostToolUse", "Stop"):
                codex_events.append(event)
            else:
                codex_events.append(event)
        # de-dup, preserve order
        seen = set()
        mapping["codex"] = [e for e in codex_events if not (e in seen or seen.add(e))]
    write_yaml(OUT_POLICY / "hook-bindings.yaml", bindings)

    # 3. mcp-servers.yaml — placeholder. Nothing in current settings.
    write_yaml(
        OUT_POLICY / "mcp-servers.yaml",
        {
            "_comment": "Neutral MCP server definitions. None currently. "
            "Add entries here to make a server available to both CLIs.",
            "servers": {},
        },
    )

    # 4. Claude-only passthrough fragments
    if "enabledPlugins" in settings:
        (passthrough / "enabledPlugins.json").write_text(
            json.dumps(settings["enabledPlugins"], indent=2) + "\n", encoding="utf-8"
        )
    if "extraKnownMarketplaces" in settings:
        (passthrough / "marketplaces.json").write_text(
            json.dumps(settings["extraKnownMarketplaces"], indent=2) + "\n",
            encoding="utf-8",
        )
    # Preserve top-level _comment / _doc as a passthrough header file
    header = {k: v for k, v in settings.items() if k.startswith("_")}
    if header:
        (passthrough / "header.json").write_text(
            json.dumps(header, indent=2) + "\n", encoding="utf-8"
        )

    print("settings: split into policy + adapters/claude/passthrough/")


def write_model_tiers() -> None:
    """Build config/model-tiers.yaml from the existing agent-models.yaml."""
    src = OUT_CONFIG / "agent-models.yaml"
    if not src.exists():
        print(f"  skip model-tiers: {src} not present", file=sys.stderr)
        return
    legacy = yaml.safe_load(src.read_text(encoding="utf-8"))
    legacy_tiers = legacy.get("tiers", {})
    # Codex equivalents — operator can refine in adapters/codex/passthrough/profiles.toml later.
    tiers = {
        "strong": {
            "claude": legacy_tiers.get("strong", "claude-opus-4-7"),
            "codex": "gpt-5.1-codex",
        },
        "standard": {
            "claude": legacy_tiers.get("standard", "claude-sonnet-4-6"),
            "codex": "gpt-5-codex",
        },
        "light": {
            "claude": legacy_tiers.get("light", "claude-haiku-4-5"),
            "codex": "gpt-5-codex-mini",
        },
    }
    OUT_CONFIG.mkdir(parents=True, exist_ok=True)
    write_yaml(
        OUT_CONFIG / "model-tiers.yaml",
        {
            "_comment": (
                "Neutral model-tier mapping. Each agent picks a tier in "
                "agents/<name>/agent.yaml; the per-CLI model id is resolved "
                "here at sync time. Edit then re-run sync-cli-assets.sh."
            ),
            "tiers": tiers,
            "_legacy_agent_assignments": legacy.get("agents", {}),
        },
    )
    print("config: wrote model-tiers.yaml")


def write_tool_name_map() -> None:
    """Neutral tool name → per-CLI native. Used by adapters when generating agent specs."""
    OUT_ADAPTERS.mkdir(parents=True, exist_ok=True)
    mapping = {
        "_comment": (
            "Neutral tool name → per-CLI native name. null on a CLI = drop the tool "
            "for that CLI (no equivalent). Adapters consult this when emitting "
            "agent tool lists."
        ),
        "tools": {
            "read": {"claude": "Read", "codex": "read_file"},
            "write": {"claude": "Write", "codex": "write_file"},
            "edit": {"claude": "Edit", "codex": "apply_patch"},
            "bash": {"claude": "Bash", "codex": "shell"},
            "grep": {"claude": "Grep", "codex": "grep"},
            "glob": {"claude": "Glob", "codex": "glob"},
            "skill": {"claude": "Skill", "codex": None},
            "webfetch": {"claude": "WebFetch", "codex": "web_fetch"},
            "websearch": {"claude": "WebSearch", "codex": "web_search"},
            "agent": {"claude": "Agent", "codex": None},
            "todowrite": {"claude": "TodoWrite", "codex": None},
            "notebookedit": {"claude": "NotebookEdit", "codex": None},
        },
    }
    write_yaml(OUT_ADAPTERS / "tool-name-map.yaml", mapping)
    print("adapters: wrote tool-name-map.yaml")


# ── YAML writer (deterministic ordering, no surprises) ────────────────────────


def write_yaml(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        yaml.safe_dump(
            data,
            fh,
            sort_keys=False,
            allow_unicode=True,
            width=100,
            default_flow_style=False,
        )


def main() -> int:
    if not CLAUDE.exists():
        print(f"Error: {CLAUDE} not found. Run from repo root.", file=sys.stderr)
        return 1
    print(f"Extracting neutral source from {CLAUDE} into {REPO}/")
    migrate_agents()
    migrate_skills()
    migrate_hooks()
    migrate_settings()
    write_model_tiers()
    write_tool_name_map()
    print("Done. Next: build the sync adapters.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
