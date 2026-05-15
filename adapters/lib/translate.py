"""
Shared helpers for the per-CLI sync adapters.

Loads the canonical neutral source (agents/, skills/, hooks/, policy/, config/,
adapters/tool-name-map.yaml) and exposes typed accessors so each adapter only
worries about formatting for its target CLI.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

import yaml


# ── Repo locations ────────────────────────────────────────────────────────────

REPO = Path(__file__).resolve().parents[2]

NEUTRAL_AGENTS = REPO / "agents"
NEUTRAL_SKILLS = REPO / "skills"
NEUTRAL_HOOKS = REPO / "hooks"
NEUTRAL_POLICY = REPO / "policy"
NEUTRAL_CONFIG = REPO / "config"
NEUTRAL_ADAPTERS = REPO / "adapters"

VALID_TIERS = ("strong", "standard", "light")
SUPPORTED_CLIS = ("claude", "codex")


# ── Data classes ──────────────────────────────────────────────────────────────


@dataclass
class AgentSpec:
    """One agent loaded from agents/<name>/agent.yaml."""

    name: str
    description: str
    model_tier: str
    body: str
    tools_allowed: list[str] = field(default_factory=list)
    tools_disallowed: list[str] = field(default_factory=list)
    max_budget_usd: float | None = None
    version: str | None = None
    last_updated: str | None = None
    claude_overrides: dict[str, Any] = field(default_factory=dict)
    codex_overrides: dict[str, Any] = field(default_factory=dict)


# ── Loaders ───────────────────────────────────────────────────────────────────


def load_yaml(path: Path) -> Any:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def load_agents() -> list[AgentSpec]:
    out: list[AgentSpec] = []
    for d in sorted(NEUTRAL_AGENTS.iterdir()):
        if not d.is_dir():
            continue
        spec_path = d / "agent.yaml"
        body_path = d / "body.md"
        if not spec_path.exists() or not body_path.exists():
            continue
        raw = load_yaml(spec_path) or {}
        tier = raw.get("model_tier", "standard")
        if tier not in VALID_TIERS:
            raise ValueError(f"{spec_path}: unknown model_tier '{tier}'")
        out.append(
            AgentSpec(
                name=raw.get("name", d.name),
                description=raw.get("description", "").strip(),
                model_tier=tier,
                body=body_path.read_text(encoding="utf-8"),
                tools_allowed=list(raw.get("tools_allowed") or []),
                tools_disallowed=list(raw.get("tools_disallowed") or []),
                max_budget_usd=float(raw["max_budget_usd"])
                if raw.get("max_budget_usd") is not None
                else None,
                version=raw.get("version"),
                last_updated=raw.get("last_updated"),
                claude_overrides=raw.get("claude") or {},
                codex_overrides=raw.get("codex") or {},
            )
        )
    return out


def load_model_tiers() -> dict[str, dict[str, str]]:
    """Return {tier: {cli: model_id}}."""
    doc = load_yaml(NEUTRAL_CONFIG / "model-tiers.yaml") or {}
    return doc.get("tiers", {})


def load_tool_name_map() -> dict[str, dict[str, str | None]]:
    """Return {neutral_name: {cli: native_name_or_None}}."""
    doc = load_yaml(NEUTRAL_ADAPTERS / "tool-name-map.yaml") or {}
    return doc.get("tools", {})


def load_permissions() -> dict[str, Any]:
    return load_yaml(NEUTRAL_POLICY / "permissions.yaml") or {}


def load_hook_bindings() -> dict[str, dict[str, list[str]]]:
    return load_yaml(NEUTRAL_POLICY / "hook-bindings.yaml") or {}


def load_mcp_servers() -> dict[str, Any]:
    doc = load_yaml(NEUTRAL_POLICY / "mcp-servers.yaml") or {}
    return doc.get("servers", {}) or {}


def load_passthrough(cli: str) -> dict[str, Any]:
    """Read every JSON fragment in adapters/<cli>/passthrough/. Returns dict keyed by basename without ext."""
    out: dict[str, Any] = {}
    p = NEUTRAL_ADAPTERS / cli / "passthrough"
    if not p.exists():
        return out
    for f in sorted(p.iterdir()):
        if f.is_file() and f.suffix == ".json":
            out[f.stem] = json.loads(f.read_text(encoding="utf-8"))
    return out


# ── Resolution helpers ────────────────────────────────────────────────────────


def resolve_model(tier: str, cli: str, tiers: dict[str, dict[str, str]] | None = None) -> str:
    """Tier name → concrete model id for the given CLI."""
    tiers = tiers or load_model_tiers()
    if tier not in tiers:
        raise ValueError(f"unknown tier {tier!r}; valid: {list(tiers)}")
    if cli not in tiers[tier]:
        raise ValueError(f"tier {tier!r} has no entry for cli {cli!r}")
    return tiers[tier][cli]


def map_tools(
    neutral_names: Iterable[str],
    cli: str,
    tool_map: dict[str, dict[str, str | None]] | None = None,
) -> list[str]:
    """Translate neutral tool names to the named CLI's vocabulary, dropping nulls.

    Names not in the map pass through unchanged — this preserves Claude-shaped
    tool names that appeared in legacy agent files (e.g. 'Read', 'Bash') so the
    Claude adapter is byte-equivalent without forcing a vocabulary rewrite.
    """
    tool_map = tool_map or load_tool_name_map()
    out: list[str] = []
    for n in neutral_names:
        if n in tool_map:
            mapped = tool_map[n].get(cli)
            if mapped is None:
                continue  # explicit "drop on this CLI"
            out.append(mapped)
        else:
            out.append(n)
    return out


# ── Output writers ────────────────────────────────────────────────────────────


def write_atomic(path: Path, content: str) -> None:
    """Write file only if content differs (idempotent sync)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        try:
            if path.read_text(encoding="utf-8") == content:
                return
        except OSError:
            pass
    path.write_text(content, encoding="utf-8")


def write_atomic_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        try:
            if path.read_bytes() == data:
                return
        except OSError:
            pass
    path.write_bytes(data)


def mirror_directory(src: Path, dst: Path, *, dry_run: bool = False) -> int:
    """Copy every file under src into dst (creating dst if needed). Removes
    files in dst that no longer exist in src. Returns number of files written.
    """
    if not src.exists():
        return 0
    if not dry_run:
        dst.mkdir(parents=True, exist_ok=True)
    written = 0
    src_files = {f.relative_to(src) for f in src.rglob("*") if f.is_file()}
    dst_files = (
        {f.relative_to(dst) for f in dst.rglob("*") if f.is_file()} if dst.exists() else set()
    )
    # write/update
    for rel in sorted(src_files):
        s = src / rel
        d = dst / rel
        data = s.read_bytes()
        if d.exists() and d.read_bytes() == data:
            continue
        if dry_run:
            written += 1
            continue
        d.parent.mkdir(parents=True, exist_ok=True)
        d.write_bytes(data)
        written += 1
    # delete stale
    for rel in dst_files - src_files:
        target = dst / rel
        if dry_run:
            continue
        target.unlink(missing_ok=True)
    return written
