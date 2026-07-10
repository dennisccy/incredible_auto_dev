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
    python3 agent_permissions.py effort <agent>       # --effort value (max|medium)
    python3 agent_permissions.py model <agent>        # resolved model id or empty
    python3 agent_permissions.py tier-model <tier>    # tier's claude model id or empty
    python3 agent_permissions.py self-test
"""
from __future__ import annotations

import os
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
#
# NOTE: deliberately NO `Bash(rm -rf /*)` entry. In Claude Code permission
# patterns `*` matches any suffix, so that pattern denies EVERY absolute-path
# rm — including the /tmp cleanup the settings allow-list explicitly permits
# (deny always beats allow). Root/home protection comes from the exact
# `Bash(rm -rf /)` plus the enumerated system dirs below, mirroring
# policy/permissions.yaml, plus Claude Code's built-in rm circuit breaker.
HARD_DEFAULT_DENIALS_ALL: tuple[str, ...] = (
    "Bash(rm -rf /)",
    "Bash(rm -rf ~)",
    "Bash(rm -rf ~/*)",
    "Bash(rm -rf /home*)",
    "Bash(rm -rf /root*)",
    "Bash(rm -rf /etc*)",
    "Bash(rm -rf /usr*)",
    "Bash(rm -rf /var*)",
    "Bash(rm -rf /boot*)",
    "Bash(rm -rf /lib*)",
    "Bash(rm -rf /opt*)",
    "Bash(rm -rf /srv*)",
    "Bash(rm -rf /sys*)",
    "Bash(rm -rf /proc*)",
    "Bash(git push --force origin main)",
    "Bash(git push --force origin master)",
    "Bash(git push -f origin main)",
    "Bash(git push -f origin master)",
)

RELEASE_AGENT_NAME = "release-manager"

# Per-agent `--effort` override map for the Claude CLI. Default is "max" for
# all agents; this dict lists agents that have been deliberately downgraded
# to a lighter effort because their work is structured / mechanical and does
# not benefit from maximum reasoning effort. Downgrade reduces output token
# count and per-call latency without changing model tier.
#
# Set CHAIN_DISABLE_EFFORT_OVERRIDE=true in the environment to restore
# `--effort max` for every agent (escape hatch for users who want to revert).
EFFORT_DEFAULT = "max"
EFFORT_OVERRIDES: dict[str, str] = {
    "release-manager":       "medium",
    "ui-test-designer":      "medium",
    "phase-closure-auditor": "medium",
    "ui-impact-analyst":     "medium",
    "qa":                    "medium",  # both generate-mode and validate-mode
    # Non-gating narrative/showcase agents: their output quality bar is
    # readable prose from already-written artifacts, not judgment. Judges,
    # gates, and browser-qa stay at max.
    "iteration-summarizer":  "medium",
    "readme-maintainer":     "medium",
    "demo-narrator":         "medium",
    "ux-regression-reviewer": "medium",
}

# Per-agent runtime caps (seconds), ~2.5-3x the typical durations measured from
# goal-session telemetry (tape_to_profit: developer ~41m, reviewer ~21m,
# browser-qa ~20m, evaluator ~17m, decomposer ~8m, coherence ~4m). One flat
# 7200s cap previously let a hung 20-minute reviewer burn a full 2 hours before
# the watchdog fired. Agents NOT listed here (the full-pipeline-only chain:
# orchestrator, qa, ui-*, auditor, release-manager, ...) fall back to the flat
# CHAIN_CLAUDE_MAX_RUNTIME_SECONDS / CHAIN_DISPATCH_INFLIGHT_TIMEOUT global —
# zero behavior change for run-phase.sh.
#
# Resolution precedence (implemented by the shell seam, lib/quota-retry.sh):
#   CHAIN_TIMEOUT_<AGENT> env  >  agents/<name>/agent.yaml max_runtime_seconds
#   >  this table  >  flat global. An EXPLICITLY exported flat global keeps
#   today's meaning and disables the per-agent table entirely.
AGENT_TIMEOUTS_SECONDS: dict[str, int] = {
    "goal-decomposer":      1800,   # typical ~8m
    "developer":            7200,   # typical ~41m; initial builds vary — keep 2h
    "reviewer":             3600,   # typical ~21m (observed hang burned 7200s)
    "browser-qa-agent":     4500,   # typical ~20m; grows with journey count
    "coherence-auditor":    1200,   # typical ~4m
    "goal-evaluator":       3600,   # typical ~17m
    "goal-proposer":        3600,
    "iteration-summarizer": 1800,
    "readme-maintainer":    1800,
    "demo-narrator":        1800,
}

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


# Judges make verdict-class calls; lowering their effort to save time is the
# one lever .claude/model-orchestration.md forbids ("lower the context you feed
# it, not the effort"). The CHAIN_AGENT_EFFORT experiment knob below refuses
# them by construction — the two-key GOAL_ACHIEVED confirm dispatches as
# goal-evaluator, so it is covered too.
JUDGE_AGENTS = frozenset({
    "goal-evaluator", "goal-decomposer", "auditor", "reviewer", "goal-proposer",
})


def _experiment_effort_override(agent: str) -> str | None:
    """Opt-in speed experiment: CHAIN_AGENT_EFFORT="developer=high[,agent=lvl]".

    Applies ONLY to non-judge agents; judges are refused loudly. Pair with the
    telemetry tripwire (analyze_telemetry.py --tripwire) — run-goal.sh reverts
    the knob automatically when quality moves. Headless-only in effect: the
    interactive pump path does not apply --effort.
    """
    raw = os.environ.get("CHAIN_AGENT_EFFORT", "").strip()
    if not raw:
        return None
    for part in raw.split(","):
        key, _, value = part.partition("=")
        if key.strip() != agent or not value.strip():
            continue
        if agent in JUDGE_AGENTS:
            print(
                f"[agent-permissions] CHAIN_AGENT_EFFORT refused for judge "
                f"'{agent}' — judges keep their effort (model-orchestration.md: "
                f"trim the context fed to a judge, never its effort).",
                file=sys.stderr,
            )
            return None
        return value.strip()
    return None


def effort_for(agent: str) -> str:
    """Return the `--effort` flag value for the named agent.

    Default `EFFORT_DEFAULT` ("max") unless the agent is in the override map.
    An opt-in CHAIN_AGENT_EFFORT experiment override wins for non-judge agents
    only. The CHAIN_DISABLE_EFFORT_OVERRIDE env var is honored by the calling
    shell wrapper, not here — this function returns the policy value
    regardless, and the caller decides whether to apply it.
    """
    experiment = _experiment_effort_override(agent)
    if experiment:
        return experiment
    return EFFORT_OVERRIDES.get(agent, EFFORT_DEFAULT)


def timeout_for(agent: str, neutral_dir: Path = NEUTRAL_AGENTS_DIR) -> int | None:
    """Return the per-agent runtime cap in seconds, or None when the agent has
    no specific cap (callers fall back to the flat global).

    Order: agents/<name>/agent.yaml `max_runtime_seconds` (optional, per-project
    tuning) > the built-in AGENT_TIMEOUTS_SECONDS table. Env overrides
    (CHAIN_TIMEOUT_<AGENT>) are the calling shell's job, not this function's —
    same division of labor as effort_for().
    """
    n = _neutral_agent_yaml(agent, neutral_dir)
    if n is not None:
        raw = _neutral_yaml_field(n, "max_runtime_seconds")
        if raw is not None:
            try:
                v = int(float(raw))
                if v > 0:
                    return v
            except (TypeError, ValueError):
                pass
    return AGENT_TIMEOUTS_SECONDS.get(agent)


def _tiers_file(tiers_path: Path | None = None) -> Path | None:
    """Locate config/model-tiers.yaml: CWD first (scripts run from the repo
    root, where config/ is real or a symlink), then relative to this file's
    tree (the framework root when vendored)."""
    candidates = [Path("config/model-tiers.yaml")]
    if tiers_path is not None:
        candidates.insert(0, tiers_path)
    try:
        candidates.append(Path(__file__).resolve().parents[3] / "config" / "model-tiers.yaml")
    except IndexError:
        pass
    for c in candidates:
        if c.is_file():
            return c
    return None


def tier_model_for(tier: str, cli: str = "claude", tiers_path: Path | None = None) -> str:
    """Resolve a tier name (strong|standard|light) to a concrete model id via
    config/model-tiers.yaml. Returns "" when the tier/file is missing — callers
    treat empty as "no override available" and must not fail hard."""
    path = _tiers_file(tiers_path)
    if path is None:
        return ""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return ""
    try:
        import yaml  # type: ignore[import-untyped]

        doc = yaml.safe_load(text) or {}
        return str((doc.get("tiers") or {}).get(tier, {}).get(cli) or "")
    except Exception:
        # Minimal indentation-based scan: find the tier under `tiers:`, then
        # its `<cli>:` child. Good enough for this small fixed-shape file.
        in_tiers = False
        in_target_tier = False
        for line in text.splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            if not line.startswith(" "):
                in_tiers = stripped == "tiers:"
                in_target_tier = False
                continue
            if in_tiers and line.startswith("  ") and not line.startswith("    "):
                in_target_tier = stripped == f"{tier}:"
                continue
            if in_target_tier and line.startswith("    ") and stripped.startswith(f"{cli}:"):
                return stripped.partition(":")[2].strip().strip("'\"")
        return ""


def model_for(agent: str, agents_dir: Path = DEFAULT_AGENTS_DIR) -> str:
    """Resolve the model id the named agent should run on.

    Resolution order (mirrors adapters/claude/sync.py):
      1. `model:` in the rendered .claude/agents/<name>.md frontmatter (what
         interactive subagents actually inherit — the authoritative render)
      2. `claude.model_override:` in agents/<name>/agent.yaml
      3. `model_tier:` in agents/<name>/agent.yaml → config/model-tiers.yaml

    Returns "" when nothing resolves. Callers must treat empty as "pass no
    --model flag" — never as an error.
    """
    f = _agent_file(agent, agents_dir)
    if f is not None:
        try:
            fm = _parse_frontmatter(f.read_text(encoding="utf-8")) or {}
        except OSError:
            fm = {}
        m = fm.get("model")
        if isinstance(m, str) and m.strip():
            return m.strip()

    n = _neutral_agent_yaml(agent)
    if n is not None:
        claude_block = _neutral_yaml_field(n, "claude")
        if isinstance(claude_block, dict):
            override = claude_block.get("model_override")
            if isinstance(override, str) and override.strip():
                return override.strip()
        else:
            # yaml-lite fallback: model_override is nested but the key name is
            # unique within agent.yaml, so a flat scan is safe.
            try:
                for line in n.read_text(encoding="utf-8").splitlines():
                    s = line.strip()
                    if s.startswith("model_override:"):
                        return s.partition(":")[2].strip().strip("'\"")
            except OSError:
                pass
        tier = _neutral_yaml_field(n, "model_tier")
        if isinstance(tier, str) and tier.strip():
            return tier_model_for(tier.strip())
    return ""


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


def _cmd_effort(args: list[str]) -> int:
    """Print the --effort value for the named agent (max | medium | …)."""
    if not args:
        print("Usage: agent_permissions.py effort <agent>", file=sys.stderr)
        return 2
    print(effort_for(args[0]))
    return 0


def _cmd_model(args: list[str]) -> int:
    """Print the resolved model id for the named agent (empty = no routing)."""
    if not args:
        print("Usage: agent_permissions.py model <agent>", file=sys.stderr)
        return 2
    print(model_for(args[0]))
    return 0


def _cmd_tier_model(args: list[str]) -> int:
    """Print the claude model id for a tier from config/model-tiers.yaml."""
    if not args:
        print("Usage: agent_permissions.py tier-model <tier>", file=sys.stderr)
        return 2
    print(tier_model_for(args[0]))
    return 0


def _cmd_timeout(args: list[str]) -> int:
    """Print the per-agent runtime cap in seconds (empty = no specific cap)."""
    if not args:
        print("Usage: agent_permissions.py timeout <agent>", file=sys.stderr)
        return 2
    t = timeout_for(args[0])
    print("" if t is None else f"{t}")
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

        # rm-ban regression (the /tmp cleanup bug): Claude Code pattern `*`
        # matches ANY suffix and deny beats allow, so a default denial like
        # "Bash(rm -rf /*)" silently swallowed every /tmp removal. Assert no
        # default denial matches a legitimate /tmp cleanup for ANY agent class,
        # while root/system-dir wipes stay denied.
        def _bash_pat_matches(pattern: str, cmd: str) -> bool:
            if not (pattern.startswith("Bash(") and pattern.endswith(")")):
                return False
            body = pattern[5:-1]
            if body.endswith("*"):
                return cmd.startswith(body[:-1])
            return cmd == body

        for _agent in ("plain", "developer", "release-manager"):
            _dl = disallowed_for(_agent, agents_dir=d)
            _tmp_hits = [
                p for p in _dl
                if p in HARD_DEFAULT_DENIALS_ALL + HARD_DEFAULT_DENIALS_NON_RELEASE
                and _bash_pat_matches(p, "rm -rf /tmp/pytest-of-user/pytest-1")
            ]
            assert not _tmp_hits, f"{_agent}: default denial swallows /tmp removals: {_tmp_hits}"
            assert "Bash(rm -rf /)" in _dl, f"{_agent}: exact-root denial missing"
            assert "Bash(rm -rf /home*)" in _dl and "Bash(rm -rf /etc*)" in _dl, (
                f"{_agent}: system-dir denials missing"
            )
            assert any(_bash_pat_matches(p, "rm -rf /home/someone") for p in _dl), (
                f"{_agent}: /home wipe must stay denied"
            )

        assert budget_for("developer", agents_dir=d) == 2.5
        assert budget_for("plain", agents_dir=d) is None
        assert budget_for("release-manager", agents_dir=d) is None
        assert budget_for("nonexistent-agent", agents_dir=d) is None

        # model_for: frontmatter model wins; missing agent resolves to "".
        assert model_for("developer", agents_dir=d) == "claude-opus-4-7"
        assert model_for("release-manager", agents_dir=d) == "claude-haiku-4-5"
        assert model_for("nonexistent-agent-zz", agents_dir=d) == ""

        # tier_model_for: parse a fixture tiers file (both with and without PyYAML
        # the indentation scan must succeed on this shape).
        tiers = d / "model-tiers.yaml"
        tiers.write_text(
            "_comment: fixture\ntiers:\n  strong:\n    claude: claude-test-strong\n"
            "    codex: gpt-x\n  light:\n    claude: claude-test-light\n",
            encoding="utf-8",
        )
        assert tier_model_for("strong", tiers_path=tiers) == "claude-test-strong"
        assert tier_model_for("light", tiers_path=tiers) == "claude-test-light"
        assert tier_model_for("nope", tiers_path=tiers) == ""

        # Per-agent timeouts — table hit, yaml max_runtime_seconds override,
        # unknown agent → None (callers fall back to the flat global cap).
        assert timeout_for("reviewer") == 3600, "reviewer cap from the builtin table"
        assert timeout_for("coherence-auditor") == 1200
        assert timeout_for("developer") == 7200
        assert timeout_for("orchestrator") is None, "full-pipeline agents keep the flat global"
        assert timeout_for("some-unknown-agent") is None
        neutral = d / "neutral-agents"
        (neutral / "reviewer").mkdir(parents=True)
        (neutral / "reviewer" / "agent.yaml").write_text(
            "name: reviewer\nmodel_tier: standard\nmax_runtime_seconds: 900\n",
            encoding="utf-8",
        )
        assert timeout_for("reviewer", neutral_dir=neutral) == 900, "agent.yaml overrides the table"
        (neutral / "developer").mkdir(parents=True)
        (neutral / "developer" / "agent.yaml").write_text(
            "name: developer\nmax_runtime_seconds: not-a-number\n",
            encoding="utf-8",
        )
        assert timeout_for("developer", neutral_dir=neutral) == 7200, "bad yaml value falls back to table"

        # CHAIN_AGENT_EFFORT experiment knob — applies to non-judges only.
        _prev_exp = os.environ.get("CHAIN_AGENT_EFFORT")
        try:
            os.environ["CHAIN_AGENT_EFFORT"] = "developer=high,reviewer=low,goal-evaluator=low"
            assert effort_for("developer") == "high", "experiment knob applies to developer"
            assert effort_for("reviewer") == "max", "judge guard: reviewer keeps its effort"
            assert effort_for("goal-evaluator") == "max", "judge guard: evaluator keeps its effort"
            assert effort_for("browser-qa-agent") == "max", "agents not named keep policy"
            os.environ["CHAIN_AGENT_EFFORT"] = "malformed-no-equals"
            assert effort_for("developer") == "max", "malformed knob value is ignored"
        finally:
            if _prev_exp is None:
                os.environ.pop("CHAIN_AGENT_EFFORT", None)
            else:
                os.environ["CHAIN_AGENT_EFFORT"] = _prev_exp

        # Effort overrides — defaults to "max" except for the listed lighter agents.
        assert effort_for("developer") == "max", "developer must stay at --effort max"
        assert effort_for("auditor") == "max", "auditor must stay at --effort max"
        assert effort_for("release-manager") == "medium", "release-manager must drop to medium"
        assert effort_for("ui-test-designer") == "medium"
        assert effort_for("phase-closure-auditor") == "medium"
        assert effort_for("ui-impact-analyst") == "medium"
        assert effort_for("qa") == "medium", "qa must drop to medium for both modes"
        assert effort_for("iteration-summarizer") == "medium", "showcase agents drop to medium"
        assert effort_for("readme-maintainer") == "medium"
        assert effort_for("demo-narrator") == "medium"
        assert effort_for("ux-regression-reviewer") == "medium"
        assert effort_for("goal-evaluator") == "max", "judges stay at max"
        assert effort_for("browser-qa-agent") == "max", "browser-qa stays at max"
        assert effort_for("some-unknown-agent") == "max", "default must be max"

    print("self-test passed")
    return 0


_COMMANDS = {
    "disallowed": _cmd_disallowed,
    "budget": _cmd_budget,
    "effort": _cmd_effort,
    "model": _cmd_model,
    "tier-model": _cmd_tier_model,
    "timeout": _cmd_timeout,
    "self-test": lambda _args: _self_test(),
}


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in _COMMANDS:
        print(f"Usage: agent_permissions.py <command> [args]", file=sys.stderr)
        print(f"Commands: {', '.join(_COMMANDS)}", file=sys.stderr)
        sys.exit(2)
    sys.exit(_COMMANDS[sys.argv[1]](sys.argv[2:]))
