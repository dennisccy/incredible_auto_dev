# Maintenance Protocol

How future sessions (of any model tier) safely maintain this framework's instruction and
state files. When this protocol and momentum conflict, the protocol wins.

## 1. Edit permissions by file class

**Agents may edit autonomously** (normal pipeline output — no approval needed):
- `runs/**` (session state, iteration artifacts), `reports/**`, `docs/handoffs/**`
- `runs/goal-session-<sid>/state/lessons.md`, `evaluator-log.md`, `journey-history.json`,
  `blueprint.md` (additive edits per the decomposer's rules)
- Project source code within an iteration's declared scope

**Edit only with a matching approved task** (a plan the user approved, or an explicit ask):
- `agents/*/body.md`, `agents/*/agent.yaml`, `skills/*.md`, `commands/*.md` — and ALWAYS
  version-bump the touched `agent.yaml`, resync mirrors, and commit both (see §3)
- `scripts/automation/**` (pipeline logic — every behavior change needs a self-test)
- `.claude/model-orchestration.md`, `.claude/judgment-rubrics.md`,
  `.claude/delegation-templates.md`, this file

**Ask the user first, every time** (these change what the product/pipeline IS):
- `CLAUDE.md` (the constitution — also invalidates every dispatch's prompt-cache prefix)
- `docs/goal.md` journeys/anti-goals (the product contract)
- `config/model-tiers.yaml` (model spend), gate defaults (`CHAIN_GOAL_GATES` etc.) in scripts
- Deleting anything under `runs/` or `reports/` (history)

## 2. Lessons learned — where and how

- **Goal-session lessons** (product/project-specific): the evaluator appends to
  `runs/goal-session-<sid>/state/lessons.md` per its format. Signal only — no routine entries.
- **Framework lessons** (pipeline/tooling pitfalls that transcend one project): append a
  numbered entry to `.claude/anti-patterns.md` following its existing format (symptom → root
  cause → rule). One entry per distinct failure mode; cite the session/iteration where it bit.
- Format discipline: every lesson states (a) the trigger condition ("Applies to:"), (b) the
  concrete mistake, (c) the checkable rule that prevents it. A lesson without a checkable
  rule is a war story — rewrite it until it's a rule.

## 3. The resync invariant (the #1 silent-corruption risk)

`.claude/agents/`, `.claude/skills/`, `.claude/commands/` are BUILD PRODUCTS rendered from
`agents/`, `skills/`, `commands/` by `scripts/automation/sync-cli-assets.py`. The runtime
sync is a no-op when the mirrors already exist, so:

1. Never hand-edit the mirrors; edit the neutral source.
2. After any neutral-source edit: `python3 scripts/automation/sync-cli-assets.py --cli claude`,
   then commit source AND mirrors together.
3. Verify with `python3 scripts/automation/sync-cli-assets.py --cli claude --check` (exit 0 =
   in sync). This runs in `run-evals.sh` — a red eval here means someone broke the invariant.
4. **Vendored deployments (framework embedded in a product repo):** a deployment MAY
   localize `scripts/dev.sh`, `scripts/start-backend.sh`, and `scripts/start-frontend.sh`
   to its own app layout — these three are per-project templates and their localized
   versions must NEVER be pushed upstream. When syncing a vendored copy upstream
   (clone-and-apply), copy ONLY the files your session's commits actually changed
   (`git log <range> --name-only`), never a whole-tree copy/rsync — a vendored tree
   accumulates product debris and localizations that do not belong in the framework.

## 4. Condensation rule (growth control)

When any append-only knowledge file exceeds **~200 lines** (`lessons.md`,
`.claude/anti-patterns.md`, `letter-to-future-sessions.md` handoff section):
1. Condense duplicate/superseded entries into their general rule (keep the rule, drop the
   retelling); move historical examples to `<file>.archive.md` beside the original.
2. Do it in a dedicated commit touching nothing else, message `chore(<file>): condense`.
3. Never condense `evaluator-log.md` or `journey-history.json` — they are chronological
   records, and the scripts pre-trim/inline them already.

## 5. Cache stability

Dispatch prompts share a cached prefix (CLAUDE.md + system prompt). Do not edit CLAUDE.md,
`.claude/core.md`, or `.claude/workflow.md` mid-session — every subsequent dispatch pays a
full cache miss, and agents within one iteration may see two different constitutions. Batch
such edits between sessions (they're user-approval-class anyway, §1).

## 6. Model-table maintenance

When Anthropic ships/retires models: update `config/model-tiers.yaml` (the ONE source),
resync, update the table in `.claude/model-orchestration.md` in the same commit, and run the
preflight (`claude -p --model <id> 'reply OK'` per id). Never re-pin a per-agent
`model_override` in `agent.yaml` except as a deliberate temporary exception with a comment
saying why and when to remove it.

## 7. After every pipeline-behavior change

1. Add/extend a self-test in the module you touched; wire it into `run-evals.sh` if new.
2. `./scripts/automation/run-evals.sh` must be green before commit.
3. If the change alters an artifact format (verdict line, report path, JSON schema): grep for
   every reader of that artifact and update them in the SAME commit (see
   `.claude/anti-patterns.md` — writer/reader drift is a documented failure class).
