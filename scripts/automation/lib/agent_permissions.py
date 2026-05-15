"""
Per-agent permission and budget lookup.

Every claude invocation in this framework runs through `claude_with_quota_retry`
in `lib/quota-retry.sh`, which sets `CHAIN_CURRENT_AGENT` to the name of the
current agent. This module looks up that name and returns:

  - Disallowed tool patterns (HARD_DEFAULT_DENIALS + frontmatter additions)
    → passed to claude as --disallowedTools to limit blast radius
  - Optional max_budget_usd → passed as --max-budget-usd if set

Hard defaults: no agent except `release-manager` can `git push`, `gh pr merge`,
`gh pr close`, or `gh release` operations. This is enforced even if the agent
file does not list a `disallowed_tools:` field.

Optional frontmatter fields recognized:

  disallowed_tools: ["Bash(rm -rf *)", "WebFetch"]   # ADDED to hard defaults
  max_budget_usd: 1.50                                # only enforced if set

CLI:
    python3 agent_permissions.py disallowed <agent>   # space-joined list to stdout
    python3 agent_permissions.py budget <agent>       # USD value or empty
    python3 agent_permissions.py self-test
"""
from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any

# These tools are denied for every agent EXCEPT release-manager. Centralizes
# the principle that only the release-manager talks to GitHub / pushes refs.
HARD_DEFAULT_DENIALS_NON_RELEASE: tuple[str, ...] = (
    "Bash(git push *)",
    "Bash(git push)",
    "Bash(git push --force *)",
    "Bash(gh pr merge *)",
    "Bash(gh pr close *)",
    "Bash(gh release *)",
    "Bash(git tag *)",
)

# Tools denied for ALL agents (release-manager included). For dangerous
# operations that should never happen mid-pipeline.
HARD_DEFAULT_DENIALS_ALL: tuple[str, ...] = (
    "Bash(rm -rf /*)",
    "Bash(rm -rf /)",
    "Bash(git push --force origin main)",
    "Bash(git push --force origin master)",
    "Bash(git push -f origin main)",
    "Bash(git push -f origin master)",
)

RELEASE_AGENT_NAME = "release-manager"

# Reads from the legacy `.claude/agents/<name>.md` (frontmatter) by default to
# preserve back-compat for any external caller that imports this module.
# In the multi-CLI world, the same per-agent permissions live in
# `agents/<name>/agent.yaml` under `tools_disallowed:` and `max_budget_usd:`.
# Both layouts are accepted; if neither file is present, defaults apply.
DEFAULT_AGENTS_DIR = Path(".claude/agents")
NEUTRAL_AGENTS_DIR = Path("agents")


def _parse_frontmatter(text: str) -> dict[str, Any] | None:
    if not text.startswith("---"):
        return None
    end = text.find("\n---", 3)
    if end == -1:
        return None
    block = text[3:end].strip()
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
                # Tolerate quoted strings: "Bash(git push *)", "WebFetch"
                items: list[str] = []
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
            # strip wrapping quotes from scalars
            v = value
            if (v.startswith('"') and v.endswith('"')) or (
                v.startswith("'") and v.endswith("'")
            ):
                v = v[1:-1]
            fields[key] = v
    return fields


def _split_top_level(s: str) -> list[str]:
    """Split a comma list, respecting parens (so 'Bash(a, b), Edit' → 2 items)."""
    out: list[str] = []
    depth = 0
    cur: list[str] = []
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


def _agent_file(agent: str, agents_dir: Path = DEFAULT_AGENTS_DIR) -> Path | None:
    candidate = agents_dir / f"{agent}.md"
    return candidate if candidate.is_file() else None


def _neutral_agent_yaml(agent: str, neutral_dir: Path = NEUTRAL_AGENTS_DIR) -> Path | None:
    candidate = neutral_dir / agent / "agent.yaml"
    return candidate if candidate.is_file() else None


def _neutral_yaml_field(path: Path, key: str) -> Any:
    """Load a single top-level field from agents/<name>/agent.yaml. Returns
    None if the file or key is missing. Avoids a hard dep on PyYAML when the
    caller only needs one field — but uses PyYAML when available since these
    files are small and YAML-safe parsing is the right thing.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None
    try:
        import yaml  # type: ignore[import-untyped]

        doc = yaml.safe_load(text) or {}
        return doc.get(key)
    except Exception:
        # PyYAML not installed: do a minimal scan for top-level "key:" lines.
        # This is good enough for the small set of fields we read.
        for line in text.splitlines():
            if line.startswith(f"{key}:"):
                _, _, val = line.partition(":")
                return val.strip()
        return None


def disallowed_for(agent: str, agents_dir: Path = DEFAULT_AGENTS_DIR) -> list[str]:
    """Return the full list of disallowed tool patterns for the named agent.

    Looks in BOTH the legacy .claude/agents/<name>.md frontmatter and the
    neutral agents/<name>/agent.yaml; entries from either source are merged.
    The neutral source is the source of truth post-migration; the legacy
    layout is a fallback during the transition period.
    """
    denials: list[str] = list(HARD_DEFAULT_DENIALS_ALL)
    if agent != RELEASE_AGENT_NAME:
        denials.extend(HARD_DEFAULT_DENIALS_NON_RELEASE)

    # Legacy .claude/agents/<name>.md
    f = _agent_file(agent, agents_dir)
    if f is not None:
        try:
            fm = _parse_frontmatter(f.read_text(encoding="utf-8")) or {}
        except OSError:
            fm = {}
        extra = fm.get("disallowed_tools") or []
        if isinstance(extra, list):
            for item in extra:
                if isinstance(item, str) and item not in denials:
                    denials.append(item)

    # Neutral agents/<name>/agent.yaml
    n = _neutral_agent_yaml(agent)
    if n is not None:
        extra2 = _neutral_yaml_field(n, "tools_disallowed") or []
        if isinstance(extra2, list):
            for item in extra2:
                if isinstance(item, str) and item not in denials:
                    denials.append(item)
    return denials


def budget_for(agent: str, agents_dir: Path = DEFAULT_AGENTS_DIR) -> float | None:
    """Return max_budget_usd from neutral source first, falling back to the
    legacy frontmatter. None if neither defines a budget.
    """
    # Neutral first
    n = _neutral_agent_yaml(agent)
    if n is not None:
        raw = _neutral_yaml_field(n, "max_budget_usd")
        if raw is not None:
            try:
                v = float(raw)
                if v > 0:
                    return v
            except (TypeError, ValueError):
                pass
    # Legacy fallback
    f = _agent_file(agent, agents_dir)
    if f is None:
        return None
    try:
        fm = _parse_frontmatter(f.read_text(encoding="utf-8")) or {}
    except OSError:
        return None
    raw = fm.get("max_budget_usd")
    if raw is None:
        return None
    try:
        v = float(raw)
        return v if v > 0 else None
    except (TypeError, ValueError):
        return None


# ── CLI ──────────────────────────────────────────────────────────────────────

def _cmd_disallowed(args: list[str]) -> int:
    if not args:
        print("Usage: agent_permissions.py disallowed <agent>", file=sys.stderr)
        return 2
    items = disallowed_for(args[0])
    # Single line, space-separated. Each item may contain spaces (e.g.,
    # "Bash(git push *)"), so the receiver must pass this whole string as ONE
    # arg to claude (claude will split on spaces while respecting parens).
    print(" ".join(items))
    return 0


def _cmd_budget(args: list[str]) -> int:
    if not args:
        print("Usage: agent_permissions.py budget <agent>", file=sys.stderr)
        return 2
    b = budget_for(args[0])
    if b is None:
        print("")  # empty = no budget set
    else:
        print(f"{b}")
    return 0


def _self_test() -> int:
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)
        # release-manager: only ALL denials, no NON_RELEASE denials
        (d / "release-manager.md").write_text(
            "---\nname: release-manager\ndescription: x\nmodel: claude-haiku-4-5\nversion: 1.0.0\nlast_updated: 2026-05-04\n---\n",
            encoding="utf-8",
        )
        # developer: gets NON_RELEASE denials + custom additions + budget
        (d / "developer.md").write_text(
            "---\nname: developer\ndescription: x\nmodel: claude-opus-4-7\n"
            "version: 1.0.0\nlast_updated: 2026-05-04\n"
            'disallowed_tools: ["Bash(rm -rf /home/*)", "WebFetch"]\n'
            "max_budget_usd: 2.50\n"
            "---\n",
            encoding="utf-8",
        )
        # plain: no extras, no budget
        (d / "plain.md").write_text(
            "---\nname: plain\ndescription: x\nmodel: claude-sonnet-4-6\n"
            "version: 1.0.0\nlast_updated: 2026-05-04\n---\n",
            encoding="utf-8",
        )

        rd = disallowed_for("release-manager", agents_dir=d)
        assert "Bash(git push *)" not in rd, "release-manager must NOT have git push denial"
        assert any("rm -rf" in s for s in rd), "release-manager must still have ALL denials"

        dd = disallowed_for("developer", agents_dir=d)
        assert "Bash(git push *)" in dd, "developer must have git push denial"
        assert "Bash(rm -rf /home/*)" in dd, "developer must have custom denial"
        assert "WebFetch" in dd, "developer must have WebFetch denial"

        pd = disallowed_for("plain", agents_dir=d)
        assert "Bash(git push *)" in pd

        assert budget_for("developer", agents_dir=d) == 2.5
        assert budget_for("plain", agents_dir=d) is None
        assert budget_for("release-manager", agents_dir=d) is None
        assert budget_for("nonexistent-agent", agents_dir=d) is None

    print("self-test passed")
    return 0


_COMMANDS = {
    "disallowed": _cmd_disallowed,
    "budget": _cmd_budget,
    "self-test": lambda _args: _self_test(),
}


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in _COMMANDS:
        print(f"Usage: agent_permissions.py <command> [args]", file=sys.stderr)
        print(f"Commands: {', '.join(_COMMANDS)}", file=sys.stderr)
        sys.exit(2)
    sys.exit(_COMMANDS[sys.argv[1]](sys.argv[2:]))
