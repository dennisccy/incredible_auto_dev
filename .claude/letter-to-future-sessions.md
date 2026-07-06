# Letter to Future Sessions

Written 2026-07-03 by the last Fable-5 session, at the end of the hardening pass that
prepared this chain for the Opus/Sonnet/Haiku era. Read this when you're about to do
framework work; it says where this system breaks and what we most wish we'd been told.

The living improvement backlog is [`docs/improvement-roadmap.md`](../docs/improvement-roadmap.md)
— pick up framework work there (one item per session, per its ground rules), and put new
pain into its §16 staging section.

## The three things that matter most (nobody asked for these)

1. **Trust the gates more than any single verdict — including your own.** The most
   dangerous outputs in this chain are confident verdicts. GOAL_ACHIEVED now has to survive
   `journey-history` math, a coherence check, a full-diff secret scan, a regression diff,
   AND a fresh-context confirm (`lib/goal-gates.sh`). That layering is the design: no single
   model output — however smart the model — certifies anything alone. When you add a new
   high-stakes decision, give it the same shape: mechanical check first, fresh-context
   second opinion for what math can't check. Do not "simplify" a gate away because recent
   iterations were all clean; clean streaks are what gates are FOR.

2. **Writer→reader contracts rot silently — grep for the reader before changing a writer.**
   Nearly every real bug found in the 2026-07 audit was one side of a contract changing
   without the other: a verdict template that its own parser rejected, a gate grep that
   matched the template's placeholder line, a test whose expected vocabulary predated a
   rename, a results table one column wider than its parser. Before you change ANY artifact
   format (verdict line, table, JSON field, path), grep for every consumer and update them
   in the same commit — then add a fixture to `run-evals.sh` that would have caught the
   drift. The eval suite is <30s and free; there is no excuse for an unwired self-test.

3. **Token discipline is a quality feature, not a cost feature.** The judges degrade when
   fed megabytes (raw diffs, whole goal files, every screenshot). The slice/digest/bounded
   artifacts exist so the evaluator reads MORE SIGNAL, not just fewer tokens. If a judge
   seems to be missing things, check what it was fed before blaming the model — and never
   "fix" it by inlining everything again. Every bounded artifact names what it omitted;
   agents can always Read the full file.

## How this system degrades (watch for these; each has a tripwire)

- **A gate gets disabled and forgotten.** `CHAIN_GOAL_GATES=false`,
  `CHAIN_MODEL_ESCALATION=false`, `CHAIN_DISABLE_MODEL_ROUTING=true`,
  `CHAIN_GOAL_CONFIRM=false` are one-shot escape hatches. If you set one, re-enable it in
  the same session and say so in your report. Symptom of the failure: sessions start
  certifying with no `gate-report.md` in the iter dirs.
- **Neutral source and `.claude/` mirrors drift.** The runtime sync is a no-op when mirrors
  exist; editing one side only is invisible until behavior diverges. Tripwire: the
  `sync-cli-assets --check` eval goes red — run the resync and commit BOTH sides
  (`.claude/maintenance-protocol.md` §3).
- **The model table rots.** Anthropic ships/retires models; `config/model-tiers.yaml` is the
  only place ids live. On any model-availability change: preflight each id
  (`claude -p --model <id> 'reply OK'`), flip the tier, resync, update
  `.claude/model-orchestration.md`'s table in the same commit. Never re-pin a per-agent
  `model_override` except as a commented temporary exception — the evals fail on it.
- **Append-only files grow until they poison prompts.** `lessons.md`, `anti-patterns.md`,
  goal.md journeys. The dispatch wrappers pre-trim/slice the big ones, but condensation
  (maintenance protocol §4) still has to happen — a 500-line lessons file is a smell.
- **Skills edited without version bumps.** The rendered agent frontmatter carries
  `version:`; bump it with every body/skill change so drift between what an agent file says
  and what a long-running session loaded is diagnosable.
- **The pump protocol changes but a running pump predates it.** Pump behavior (out files,
  model overrides, >8KB file-indirection) comes from `.claude/skills/goal-interactive-dispatch.md`
  loaded at pump start — after changing it, restart the pump session before resuming.

## Known limitations we chose NOT to fix (so you don't rediscover them as bugs)

- A pump that dies during a CLAIMED dispatch waits out `CHAIN_DISPATCH_INFLIGHT_TIMEOUT`
  (default 2h) before pausing — distinguishing "dead pump" from "long agent" needs a
  PID-liveness protocol change we judged not worth it yet.
- Two different sessions on the same repo race (no cross-session lock). One repo, one live
  session.
- `scan_diff.py` is regex-grade: it catches the common credential shapes and paid-SaaS
  manifests, not exotic secrets. It reduces the evaluator's burden; it does not replace the
  anti-goal checklist.
- The stall detector counts journey-state freezes only; a session doing real non-journey
  work (refactors) for many iterations can look "stalled" to a human while the hash rightly
  keeps changing only when journeys move. The evaluator's STALLED judgment covers the rest.

## Honesty clause (inherited from the rubrics — applies to YOU)

Rubrics, gates, and multi-sample verification raise the floor; they cannot fully replace
top-model taste on ambiguous or novel judgment. When you hit a call the rubrics don't
cover: escalate to the strong tier at max effort, get a second fresh-context opinion, or
stop and ask the user (`.claude/judgment-rubrics.md` §3). Unknown is a first-class answer.
Never fabricate — the chain's value rests entirely on its artifacts being true.

## Deployment note — Trendora, 2026-07-03 (the session that authored this letter)

Everything below is THAT deployment's transient state, recorded for provenance — not
framework requirements. Other projects can ignore this section.

- All hardening work packages landed (WP1 judgment docs/scaffolding, WP2 measurement,
  WP-B bug/contract fixes, WP-T token reductions, WP3 gates/routing/ladder, WP4
  consolidation + cutover). Evals: 74/74.
- The model cutover commit is live (strong=opus-4-8; builders=sonnet-5). Until 2026-07-07
  the user MAY revert that single commit to spend the remaining Fable days, re-applying it
  on cutover day.
- Not done, deliberately: golden vs-Fable baselines (user opted out); pump PID-liveness;
  cross-session lock; `.codex/` tree refresh (this deployment is claude-only — run
  `sync-cli-assets.py --cli codex` before any codex use).
- First post-cutover session should watch: `gate-report.md` appearing on any GOAL_ACHIEVED,
  `analyze_telemetry.py <session>/telemetry.jsonl` per-model rows, and whether sonnet-5
  fix-retries escalate correctly (look for `[escalation]` lines in the engine log).
