# Goal Mode inside Claude Code (Interactive)

Run the **existing** Goal Mode engine from an interactive Claude Code session
with a one-word command, so the work executes as **subagents in your live
session** — billed to your **interactive plan allowance** — instead of as
headless `claude -p` subprocesses (the **Agent SDK** path, which draws from the
separate monthly Agent SDK credit).

This is an entry-point + execution-backend addition. The engine's loop, verdict
stop rules, resume, stall/regression halts, blueprint pause, session state, and
telemetry are **unchanged** — only the model invocation is redirected. For the
internals, see [`.claude/architecture/goal-mode.md`](../.claude/architecture/goal-mode.md).
For the programmatic (terminal/CI) path, see [`goal-mode-quickstart.md`](goal-mode-quickstart.md).

---

## How it works (one paragraph)

`run-goal.sh --interactive` sets `CHAIN_AGENT_BACKEND=interactive`. Every agent
call still flows through the one dispatch seam (`lib/quota-retry.sh`), but the
`interactive` backend (`lib/interactive-dispatch.sh`) writes the agent prompt to
a file channel under `runs/goal-session-<sid>/dispatch/` and blocks. The
foreground session — the **pump**, driven by the `/goal*` command — dispatches
that agent as a subagent (`subagent_type` = the agent's name, prompt verbatim),
then writes the result back. The pump protocol lives in
[`.claude/skills/goal-interactive-dispatch.md`](../.claude/skills/goal-interactive-dispatch.md).

---

## A. How to use it

### Prerequisites

- **Logged into Claude Code with your subscription.** Check with
  `claude auth status` — it should show your subscription, not an API key. If
  `ANTHROPIC_API_KEY` is set it takes precedence and bills the metered API;
  `unset` it to use the subscription.
- **Run from the project root**, so `.claude/settings.json` (security/quality
  hooks) and `.claude/commands/` (the slash commands) load.
- **Commands materialized.** They are generated from the neutral `commands/`
  source into `.claude/commands/`. They are committed, so a normal checkout has
  them; if missing, run `./scripts/automation/sync-cli-assets.sh --cli claude`
  once and commit the result.
- **`docs/goal.md` filled in** with `## Must-have user journeys` (each as
  `- **J-01: <name>** …`) and `## Anti-goals`. See `templates/project-goal.md`.

### Commands

| Command | What it does |
|---|---|
| `/goal [session-id] [flags]` | Start (or create) a session and run **until the goal is achieved, blocked, halted, or paused by the existing rules**. No iteration cap by default — set an optional budget with e.g. `/goal my-app --max-iter 50`. |
| `/goal-status [session-id]` | Read-only: current iteration, last verdict, pause/halt state, and whether a dispatch is in flight. Never launches the engine, never writes. |
| `/goal-resume [session-id] [flags]` | Resume a paused/halted session (blueprint approval, GitHub auth, quota reset, or a closed session). Resuming a blueprint pause counts as approval; a `REGRESSION_HALT` needs `--acknowledge-regression`. Cleanly stops a still-running prior engine first (no double-engine). |
| `/goal-pause [session-id]` | Cleanly stop a running session's (detached) engine, leaving a resumable `ABORTED` checkpoint. Use after Ctrl+C to make changes, then `/goal-resume`. |
| `/goal-step [session-id]` | Run exactly **one** more iteration, then stop. Reuses the engine's `--max-iter` cap (adds no new stop rule). |

### Worked example

```text
claude
```
then:
```text
/goal todo-app
```
Claude launches the engine in the background and becomes the pump, dispatching
each goal-mode agent (developer, reviewer, browser-qa, …) as a subagent and
streaming progress. Check in any time with `/goal-status todo-app`. If it pauses
(for example, for GitHub auth, or for blueprint review when you started with
`--require-blueprint-approval`), it tells you what to do, and you continue with
`/goal-resume todo-app`.

### What "interactive" means here

The work runs as subagents in **this** session and is billed to your
**interactive plan allowance**, not the Agent SDK credit. Keep the session open
while it runs. This is intended for **individual development use**; per
Anthropic's guidance, **shared/team production automation should use the
programmatic path with an API key** (`run-goal.sh` without `--interactive`).

---

## B. Known issues & limitations

- **Keep the session open.** The pump runs in your live session; closing it
  **pauses** the run. Resume with `/goal-resume`. Long runs rely on Claude
  Code's context auto-compaction.
- **Pausing to make a change (Ctrl+C).** Ctrl+C stops the *pump*, but in
  interactive mode the engine is a detached background process that the Ctrl+C
  does not reach — so to pause promptly, after Ctrl+C run `/goal-pause <sid>`
  (sends the engine a clean SIGTERM → it writes an `ABORTED` checkpoint in ~1s).
  Make your changes (including edits to `docs/goal.md` or the code), then
  `/goal-resume <sid>` — it re-runs the in-flight iteration, so your edits take
  effect. Three outcomes are all resumable: a clean `/goal-pause`; a hard kill
  (only the summary is skipped — `current_iter` is intact); and an untouched
  orphan, which self-aborts and records `AWAITING_PUMP` once dispatch can no longer
  reach the pump — within `CHAIN_PUMP_HEARTBEAT_TIMEOUT` (~30 min) if no agent had
  been picked up, or within `CHAIN_DISPATCH_INFLIGHT_TIMEOUT` if one was mid-flight.
- **Watch progress in the engine log.** The engine tees its full, timestamped,
  headless-style log to `runs/goal-session-<sid>/engine.log` — `tail -f` it for
  the real chain narrative (iteration banners, verdicts). The pump itself stays
  quiet on purpose; it surfaces only launch/pause/final-status lines so its own
  chatter does not bury the work or burn tokens.
- **Quota is a pause, not auto-resume.** If you hit your interactive usage limit
  the run pauses; continue after it resets. (The headless path's
  sleep-until-reset does **not** apply in interactive mode.)
- **Model tiering becomes live.** Each agent runs on its `.claude/agents/<name>.md`
  model tier (Opus for strong agents, Sonnet for standard, Haiku for light), so
  cost follows the tier. The **strong tier is Opus 4.8** — Anthropic's most capable
  Opus-tier model. It runs on Max; Pro may not grant it. If a
  tier's model is unavailable, set an interactive tier override (see Troubleshooting).
  Do **not** set
  `CLAUDE_CODE_SUBAGENT_MODEL` — it overrides every subagent and flattens the tiers.
- **Fidelity gaps vs headless.** The per-agent `--effort` downgrade and the
  token-usage telemetry sidecar are **not** carried into interactive mode. The
  per-call hard timeout now *does* have an interactive equivalent —
  `CHAIN_DISPATCH_INFLIGHT_TIMEOUT` bounds a single claimed subagent (defaulting to
  `CHAIN_CLAUDE_MAX_RUNTIME_SECONDS`). Per-agent tool/permission isolation and
  per-agent model **are** preserved (via the agent frontmatter).
- **Resume is iteration-level.** A session that stops mid-iteration re-runs that
  iteration from the decomposer on resume. `/goal-resume` first SIGTERMs any
  still-running prior engine for the session (via `runs/goal-session-<sid>/engine.pid`)
  so two engines never race.
- **Claude Code only.** The interactive backend is Claude-only; Codex always uses
  the programmatic path.
- **`--interactive` needs the pump.** Running `run-goal.sh --interactive` directly
  in a plain terminal will block waiting for a pump — use `/goal`, which provides
  one.
- **Billing premise (verify once).** This whole approach assumes that subagents
  dispatched from your interactive session draw on your interactive allowance and
  not the Agent SDK credit. Confirm it once (see Troubleshooting) before relying
  on the cost behavior.

---

## C. Troubleshooting

- **`/goal` not found** — the commands are not on disk. Run
  `./scripts/automation/sync-cli-assets.sh --cli claude` and commit
  `.claude/commands/`, then restart the session.
- **The run seems stuck** — run `/goal-status`. It now also checks the engine's
  liveness (via `engine.pid` + `kill -0`): a **dead PID with `status: in_progress`**
  means the engine was orphaned (e.g. a Ctrl+C that never reached it) — `/goal-resume`.
  If it shows `AWAITING_BLUEPRINT_APPROVAL` or `AWAITING_GITHUB_AUTH`, do the named
  step and `/goal-resume`. If it shows `AWAITING_PUMP` (or a `dispatch/.awaiting-pump`
  marker is present), the pump/session went away mid-iteration — re-open the session
  and `/goal-resume` to re-run that iteration cleanly.
- **I pressed Ctrl+C and the run kept going / I want to pause** — Ctrl+C stops the
  pump but not the detached engine. Run `/goal-pause <sid>` to stop it cleanly,
  make changes, then `/goal-resume <sid>`. (Prefer `/goal-pause` over killing the
  background task from the UI, which may SIGKILL and skip the clean checkpoint.)
- **Billing went to the Agent SDK credit, not the interactive allowance** — you
  likely launched the headless engine (`run-goal.sh` without `--interactive`), or
  `ANTHROPIC_API_KEY` / `CLAUDE_CODE_SUBAGENT_MODEL` is set. Use `/goal`, and
  check `claude auth status`. **To verify the billing once:** note `/usage`
  (interactive) and `/usage-credits` (Agent SDK) before and after one `/goal`
  iteration — the interactive figure should move and the Agent SDK credit should
  not.
- **Browser tests are SKIPPED** — the Chrome MCP plugin is not available to the
  subagent. Ensure the `superpowers-chrome` plugin is enabled for the session;
  the browser agents do not restrict `tools`, so they inherit the session's MCP.
- **A strong-tier agent fails to start on Pro** — your plan may not grant
  interactive Opus. Set an interactive tier override (see below).

### Tuning

| Variable | Default | Purpose |
|---|---|---|
| `CHAIN_PUMP_HEARTBEAT_TIMEOUT` | `1800` | PICKUP window only: seconds a *not-yet-claimed* request waits for the pump to take it before concluding the pump died. An alive idle pump refreshes the heartbeat every poll, so this no longer needs to cover a long agent's runtime — a claimed agent is governed by the inflight cap below. (Also how long an untouched orphan engine waits before self-aborting.) |
| `CHAIN_DISPATCH_INFLIGHT_TIMEOUT` | `7200` (= `CHAIN_CLAUDE_MAX_RUNTIME_SECONDS`) | Hard cap on a single **claimed**, in-flight subagent, measured from when the pump took the request (`dispatch/req.*.started`). This is what lets a legitimately long agent — e.g. the developer's INITIAL BUILD, routinely > 30 min — run without being mistaken for a dead pump. `0` = unlimited. |
| `CHAIN_DISPATCH_POLL_SECONDS` | `1` | Channel poll interval. |

The pump awaits work with a **single foreground** `goal-await-dispatch.sh
--max-wait 500` call per cycle (no background job to poll), which is what keeps
the session from "updating very frequently" while idle. The engine's full,
timestamped chain log is always at `runs/goal-session-<sid>/engine.log`.

> **Optional interactive tier-map (future-friendly):** if your plan lacks a
> tier's model, cap it (for example strong→Sonnet) rather than letting dispatch
> fail. This is a small follow-up (see below); today the tiers come straight from
> `config/model-tiers.yaml`.

---

## D. Future work / what may have to be done later

- **Codex interactive backend** — mirror the commands to `.codex/prompts/` and
  add a Codex dispatch path.
- **Automatic interactive tier-map** — detect plan model availability and cap the
  strong tier to an available model when interactive Opus is not granted.
- **`SubagentStop` hook binding** — the advisory `on-stop-check-artifacts` hook
  fires on main-session stop but not on subagent completion; bind it to
  `SubagentStop` for parity if the reminder is wanted.
- **Richer in-session telemetry** — the stream-json usage sidecar is absent in
  interactive mode, so per-agent token/cost capture is reduced; a pump-side
  accounting could restore it.
- **`.claude/` git retirement** — if the generated `.claude/` tree is later
  removed from git, ensure `.claude/commands/` is regenerated on setup (the
  runtime auto-sync keys on a single agent marker and will not create
  `commands/` on its own).
- **Re-evaluate on billing changes** — revisit if Anthropic changes the
  interactive vs Agent SDK billing split or subagent billing behavior.
