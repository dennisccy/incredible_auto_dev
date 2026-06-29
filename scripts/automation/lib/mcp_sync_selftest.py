"""Self-test for per-project MCP emission (framework mechanism "M1").

Locks in two invariants of the adapters' MCP wiring:

  1. INERT by default — with no `project-extensions/mcp-servers.yaml` overlay (the
     state of every project that hasn't opted in), the generated Claude settings
     and Codex config gain NO MCP keys and `.mcp.json` is never written. This is
     the guarantee that other projects sharing this framework are unaffected.

  2. ACTIVE on opt-in — given a server set, the Claude `.mcp.json` carries the
     server (type defaults to stdio), settings gains `enableAllProjectMcpServers`
     plus an `mcp__<name>` allow entry, and the Codex config emits
     `[mcp_servers.<name>]` with a nested `.env` table and no Claude-only keys.

The server set is injected by monkeypatching `translate.merged_mcp_servers`, so the
test exercises the real render paths with zero filesystem side effects.

Run:  python3 scripts/automation/lib/mcp_sync_selftest.py self-test
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

_FW = Path(__file__).resolve().parents[3]  # incredible_auto_dev/ (framework root)
sys.path.insert(0, str(_FW))

from adapters.lib import translate as T  # noqa: E402
from adapters.claude import sync as csync  # noqa: E402
from adapters.codex import sync as xsync  # noqa: E402

SAMPLE = {
    "trendora-window": {
        "type": "stdio",
        "command": "python3",
        "args": ["-m", "app.mcp.server"],
        "env": {"TRENDORA_DB": "data/trendora.db"},
        "timeout": 30000,
    }
}


def _with_servers(servers: dict, fn):
    """Run fn() with translate.merged_mcp_servers() returning `servers`."""
    orig = T.merged_mcp_servers
    T.merged_mcp_servers = lambda: dict(servers)
    try:
        return fn()
    finally:
        T.merged_mcp_servers = orig


def _check(cond: bool, msg: str) -> None:
    if not cond:
        raise AssertionError(msg)


def run() -> None:
    raw_allow = list(T.load_permissions().get("allow", []))

    # 1. INERT — empty server set perturbs nothing. (The allow list legitimately
    # already carries the Chrome *plugin* permission, so the check is exact-equality
    # against the policy, not "no mcp__ anywhere".)
    settings_obj = json.loads(_with_servers({}, csync.render_settings_json))
    config = _with_servers({}, xsync.render_config_toml)
    _check("enableAllProjectMcpServers" not in settings_obj,
           "inert: settings.json must not add enableAllProjectMcpServers")
    _check(settings_obj["permissions"]["allow"] == raw_allow,
           "inert: settings.json allow list must be unchanged")
    _check("mcp_servers." not in config, "inert: codex config must not emit mcp_servers")
    _check(_with_servers({}, lambda: csync.sync_mcp_json(dry_run=True)) == 0,
           "inert: .mcp.json must not be written with no servers")
    _check(_with_servers({}, lambda: csync.sync_settings_local(dry_run=True)) == 0,
           "inert: settings.local.json must be left untouched with no servers")

    # 2. NON-LEAK — .claude/settings.json is subtree-tracked, so it must stay
    # byte-identical even WITH a project overlay; MCP trust/allow must NOT appear
    # there (else one project's servers could ride a subtree push upstream).
    settings_obj = json.loads(_with_servers(SAMPLE, csync.render_settings_json))
    _check("enableAllProjectMcpServers" not in settings_obj,
           "non-leak: settings.json must never carry MCP trust (it is subtree-tracked)")
    _check(settings_obj["permissions"]["allow"] == raw_allow,
           "non-leak: settings.json allow must be overlay-invariant")

    # 3. ACTIVE — trust/allow land in the project-LOCAL settings.local.json (existing
    # local content preserved); the server lands in .mcp.json; codex in config.toml.
    local = csync._settings_local_with_mcp({"permissions": {"allow": ["Keep(*)"]}, "other": 1}, SAMPLE)
    _check(local["enableAllProjectMcpServers"] is True,
           "active: settings.local.json must enable project MCP servers")
    _check("mcp__trendora-window" in local["permissions"]["allow"],
           "active: settings.local.json must add the whole-server allow entry")
    _check("Keep(*)" in local["permissions"]["allow"] and local["other"] == 1,
           "active: settings.local.json must preserve existing local content")
    # Active writes go to the right FILES with the right content. Use temp paths so
    # this is independent of the project's real on-disk .mcp.json / settings.local.json.
    import tempfile
    with tempfile.TemporaryDirectory() as _td:
        _orig = (csync.MCP_JSON, csync.CLAUDE_SETTINGS_LOCAL)
        csync.MCP_JSON = Path(_td) / ".mcp.json"
        csync.CLAUDE_SETTINGS_LOCAL = Path(_td) / "settings.local.json"
        try:
            _check(_with_servers(SAMPLE, csync.sync_mcp_json) == 1,
                   "active: sync_mcp_json writes .mcp.json")
            _check("trendora-window" in json.loads(csync.MCP_JSON.read_text())["mcpServers"],
                   "active: .mcp.json contains the server")
            _check(_with_servers(SAMPLE, csync.sync_settings_local) == 1,
                   "active: sync_settings_local writes settings.local.json")
            _local = json.loads(csync.CLAUDE_SETTINGS_LOCAL.read_text())
            _check(_local["enableAllProjectMcpServers"] is True
                   and "mcp__trendora-window" in _local["permissions"]["allow"],
                   "active: settings.local.json carries trust + allow")
            _check(_with_servers(SAMPLE, lambda: csync.sync_settings_local(dry_run=True)) == 0,
                   "active: sync_settings_local is idempotent once written")
        finally:
            csync.MCP_JSON, csync.CLAUDE_SETTINGS_LOCAL = _orig

    server = csync._claude_mcp_server(SAMPLE["trendora-window"])
    _check(server["type"] == "stdio", "active: .mcp.json server type must be stdio")
    _check(server["command"] == "python3" and server["args"] == ["-m", "app.mcp.server"],
           "active: .mcp.json command/args must pass through")
    _check(server["env"] == {"TRENDORA_DB": "data/trendora.db"},
           "active: .mcp.json env must pass through")

    config = _with_servers(SAMPLE, xsync.render_config_toml)
    _check("[mcp_servers.trendora-window]" in config, "active: codex mcp_servers section")
    _check("[mcp_servers.trendora-window.env]" in config, "active: codex nested env table")
    section = config.split("[mcp_servers.trendora-window]", 1)[1].split("\n[", 1)[0]
    _check("type" not in section and "timeout" not in section,
           "active: codex must drop Claude-only keys (type/timeout)")


def main(argv: list[str]) -> int:
    if argv and argv[0] in ("self-test", "--self-test"):
        run()
        print("mcp_sync_selftest: OK")
        return 0
    sys.stdout.write(__doc__ or "")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
