# CLI Providers — Claude or Codex

The framework runs on two AI CLIs: **Claude Code** and **OpenAI Codex CLI**. Pick which one drives a given run with `--cli claude` or `--cli codex`. Both consume the same canonical asset source — there is no duplication of agents, skills, hooks, or settings between the two.

---

## Quick start

```bash
# Phase mode (per-run choice; defaults to claude)
./scripts/automation/run-phase.sh phase-1                 # claude (default)
./scripts/automation/run-phase.sh phase-1 --cli codex     # codex
./scripts/automation/run-phase.sh phase-1 --cli=codex     # equivalent

# Goal mode (per-session choice; pinned in session.json)
./scripts/automation/run-goal.sh --session-id myapp --cli codex
./scripts/automation/run-goal.sh --resume --session-id myapp           # uses persisted CLI
./scripts/automation/run-goal.sh --resume --session-id myapp --cli claude --force-cli   # override
```

The first run on a fresh checkout auto-materializes the per-CLI tree (`.claude/` or `.codex/`) from the neutral source. No separate setup step.

---

## How the layers fit together

```
LAYER 1 — canonical source (in git)
  agents/<name>/agent.yaml + body.md   neutral spec + shared instruction prose
  skills/*.md                          shared documentation files
  hooks/*.sh                           shared shell scripts
  policy/permissions.yaml              neutral allow/deny lists
  policy/hook-bindings.yaml            which hook fires on which CLI events
  policy/mcp-servers.yaml              MCP server definitions
  config/model-tiers.yaml              tier → per-CLI model id
  adapters/tool-name-map.yaml          neutral tool name → per-CLI native
  adapters/claude/passthrough/         Claude-only fragments
  adapters/codex/passthrough/          Codex-only fragments

       │ generated at run time (idempotent)
       ▼
LAYER 2 — build product (gitignored)
  .claude/agents/*.md, settings.json, hooks/, skills/   for Claude Code
  .codex/agents/*.toml, config.toml, hooks/, skills/    for Codex CLI
  AGENTS.md (project root)                              Codex auto-loads this

       │ consumed by the dispatcher
       ▼
LAYER 3 — runtime
  scripts/automation/lib/quota-retry.sh
    agent_with_quota_retry → _claude_invoke | _codex_invoke
```

---

## Adding or editing agents

1. Edit `agents/<name>/agent.yaml` (model tier, tools, budget) and/or `agents/<name>/body.md` (instruction prose).
2. Run any phase or goal command — sync runs automatically and regenerates the per-CLI files.

To force a regeneration without running anything:

```bash
./scripts/automation/sync-cli-assets.sh             # both CLIs
./scripts/automation/sync-cli-assets.sh --cli codex # one CLI
./scripts/automation/sync-cli-assets.sh --check     # CI gate; non-zero on drift
```

Field reference for `agents/<name>/agent.yaml`:

| Field | Required | Notes |
|---|---|---|
| `name` | yes | Must match directory name |
| `description` | yes | One-line agent purpose |
| `model_tier` | yes | `strong` \| `standard` \| `light` (resolved per-CLI in `config/model-tiers.yaml`) |
| `tools_allowed` | no | Neutral tool names; mapped to per-CLI vocab in `adapters/tool-name-map.yaml` |
| `tools_disallowed` | no | Tool patterns to deny (passed to Claude as `--disallowedTools`; consulted by Codex's PermissionRequest hook) |
| `max_budget_usd` | no | Per-invocation hard cap |
| `body` | yes | Path to instruction prose (`body.md` by convention) |
| `claude:` | no | Escape-hatch object for Claude-only overrides (e.g. `model_override`) |
| `codex:` | no | Escape-hatch object for Codex-only overrides (`sandbox`, `ask_for_approval`, `mcp_servers`) |

---

## Adding skills

Drop a markdown file in `skills/`. Both CLIs see it (the per-CLI sync mirrors the directory). Codex agents `Read` the file at runtime via their normal file-read tool — there is no native Codex skill concept.

## Adding hooks

1. Write a `hooks/<name>.sh` shell script.
2. Add a row to `policy/hook-bindings.yaml`:
   ```yaml
   my-hook.sh:
     claude: [PreToolUse:Bash]   # event[:matcher] tokens
     codex:  [PreToolUse, PermissionRequest]
   ```
3. Hooks read normalized input via `hooks/lib/normalize-input.sh` (TBD; currently each hook handles per-CLI env vars itself).

Hooks bound to events that don't exist on a CLI (e.g., `SessionStart` is Codex-only) are simply skipped on the other side.

## Adding permissions

Edit `policy/permissions.yaml`. The `allow` and `deny` lists translate directly to Claude's `permissions.allow` / `permissions.deny`. Codex has no native allow/deny lists — it uses sandbox modes (`workspace-write`, `read-only`, `danger-full-access`) plus a PermissionRequest hook for finer-grained gating. The `codex_default_sandbox` and `codex_default_approval` keys in `policy/permissions.yaml` set the default for Codex.

---

## What lives only on one CLI

Some concepts are CLI-specific. They live in `adapters/<cli>/passthrough/` rather than the neutral source:

- **Claude plugins** (`enabledPlugins`, marketplaces) — Claude-only. Edit `adapters/claude/passthrough/enabledPlugins.json` and `adapters/claude/passthrough/marketplaces.json`.
- **Codex profiles** — Codex-only. Place TOML fragments in `adapters/codex/passthrough/` (currently empty).

The adapter for that CLI splices these into its generated config; the other CLI ignores them entirely.

---

## State and telemetry

Every persistent artifact gains a `cli` field so you can tell which provider ran the work:

- `runs/<phase>/status.json` — `cli` set on first write
- `runs/goal-session-<sid>/session.json` — `cli` set on session creation; `--resume` reads it
- `runs/.../trace.jsonl` — `cli` per record
- `runs/.../telemetry.jsonl` — `cli` per event

A goal-mode resume that passes a different `--cli` than the persisted value errors out unless `--force-cli` is also passed (which mixes CLIs in the session — telemetry will reflect that).

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Error: 'codex' CLI not found` | Codex CLI not installed | `npm install -g @openai/codex` (or use `--cli claude`) |
| `Error: --cli must be claude or codex` | Typo or unsupported value | Use exactly `claude` or `codex` |
| Sync writes nothing | Tree already up-to-date | Use `--resync` to force, or set `CHAIN_RESYNC_CLI_ASSETS=true` |
| Generated file edited by hand | Drift | Re-run sync; commit the diff to neutral source instead |
| `sync-cli-assets.sh --check` exits non-zero in CI | A generated file was hand-edited | Move the edit to neutral source and re-run sync |
| Codex run says "config profile X not found" | Claude `-p` flag not translated correctly | Should be auto-translated — file an issue with the failing command |

---

## Architectural notes

- **Per-run / per-session, not per-agent.** The CLI is fixed for the duration of a phase or goal session. Mixing CLIs within one run is supported by the architecture (per-agent `cli:` override in `agent.yaml`) but disabled by default.
- **First-run sync is automatic.** `run-phase.sh` and `run-goal.sh` call `ensure_cli_assets_synced` before any agent invocation. If the marker file (e.g., `.claude/agents/developer.md`) is present, sync is skipped.
- **Claude is the default.** `CHAIN_CLI` defaults to `claude` if unset and no `--cli` flag is passed. Existing Claude-only callers see no behaviour change.
- **`claude_with_quota_retry` is now an alias.** All step scripts continue to call it; behaviour now depends on `$CHAIN_CLI`.
- **Codex's Claude-equivalent flags are translated.** The framework calls everything as `-p <prompt>`; `_codex_invoke` strips the `-p` and passes the prompt positionally to `codex exec`.
- **Per-call env contracts (Claude-only).** `claude_with_quota_retry` reads two env vars before invoking the Claude CLI:
  - `CHAIN_CURRENT_AGENT=<name>` — set by each step-wrapper script (`dev-phase.sh`, `qa-phase.sh`, the inline orchestrator/iteration-summarizer/delivered blocks in `run-phase.sh` and `run-goal.sh`, etc.). Drives both the per-agent permission overlay (`agent_permissions.py disallowed/budget`) and the per-agent `--effort` resolution (`agent_permissions.py effort`).
  - `CHAIN_DISABLE_EFFORT_OVERRIDE=true` — restore `--effort max` for every agent regardless of the override map. Useful when troubleshooting whether the effort drop is degrading a structured agent's output.
  Codex callers do not see these vars; the `--effort` flag is Claude-specific.

---

## What's not there yet

- **Mixed-CLI runs.** Architecture supports it; per-agent `cli:` override would unlock it. Wait for a real use case.
- **Codex profiles** for non-default tiers. Generated config sticks to a single profile.
- **MCP server definitions in neutral source.** `policy/mcp-servers.yaml` is a stub; Claude MCP currently lives in `adapters/claude/passthrough/`.
- **Hardened Codex error/quota patterns.** The regex catches obvious cases; first real Codex run end-to-end will reveal what to add.
