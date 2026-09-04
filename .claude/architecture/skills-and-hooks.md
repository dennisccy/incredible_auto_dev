# Skills and Hooks

## Skills (in `.claude/skills/`)

Skills are reusable instruction files that agents read during their workflow. They are not agents -- they are methodologies.

| Skill | File | Consuming Agent | Purpose |
|-------|------|----------------|---------|
| Diff-to-UI Impact | `diff-to-ui-impact.md` | ui-impact-analyst | Classify file changes by UI impact type (frontend-direct, backend-api, backend-internal, config, full-stack) |
| UI Workflow Inference | `ui-workflow-inference.md` | ui-impact-analyst | Infer user journeys from changed routes, components, and entry points |
| Visible Change Summarizer | `visible-change-summarizer.md` | ui-impact-analyst | Write plain-language user-facing change summaries for operators |
| Plain Language | `plain-language.md` | iteration-summarizer, demo-narrator, readme-maintainer | Shared plain-English writing standard for owner-facing prose: short sentences, IDs with friendly names, the canonical status/verdict word table (single source: `lib/plain-language.sh`) |
| Manual UI Test Plan Generator | `manual-ui-test-plan-generator.md` | ui-test-designer | Create human-executable test plans with exact steps and expected outcomes |
| What-to-Click Writer | `what-to-click-writer.md` | ui-test-designer | Write fast operator verification guides (5-minute check) |
| Browser Workflow Executor | `browser-workflow-executor.md` | browser-qa-agent | Execute browser flows via Chrome MCP (navigate, click, type, screenshot) |
| UI Regression Scout | `ui-regression-scout.md` | ux-regression-reviewer | Identify prior-phase user journeys affected by current changes |
| Phase Closure Gate | `phase-closure-gate.md` | phase-closure-auditor | Evaluate phase completion criteria (artifact existence, quality, consistency) |
| Architecture Doc Updater | `architecture-doc-updater.md` | update-docs.sh | Update framework or project architecture docs when source files drift |

## Hooks (7 total, in `.claude/hooks/`)

Hooks are shell scripts triggered by Claude Code at specific lifecycle points. They are configured in `.claude/settings.json`.

### guard-dangerous-commands.sh
- **Trigger:** PreToolUse (Bash tool)
- **Purpose:** Secondary safety layer for dangerous command patterns (rm -rf, dd, force-push main, credential reads). Primary protection is deny rules in `.claude/settings.json`.
- **Behavior (SEC-7 two-mode):** argv mode (command as `$1` — test harness/Codex): GUARD lines on stderr + exit 1. Claude mode (PreToolUse JSON on stdin, `.tool_input.command`): emits `permissionDecision:"deny"` JSON on stdout with exit 0 — the settings wrapper is `|| true`, so the stdout JSON is the enforcement channel and the exit code carries no signal.

### guard-read-path-hygiene.sh
- **Trigger:** PreToolUse (Bash tool)
- **Purpose:** Enforces `.claude/core.md` § "File Paths in Bash" so a dispatch never stalls on a human approval prompt it cannot get. Denies (a) a `cd` in a compound whose later segment is a CONTENT READ with a path argument, and (b) a recursive content search rooted at `.`, `~` or an absolute path. Both forms leave the search root unresolvable or unbounded, and since `Read(**/.env)` and friends are deny rules the checker cannot prove the read misses them — so it escalates to the human. Carve-outs match core.md: `cd` before a non-read (pytest/npm/tsc) and a piped read with no path argument stay legal, and redirect targets (`2>/dev/null`) are not read arguments.
- **Behavior (SEC-7 two-mode):** same contract as `guard-dangerous-commands.sh`. Detection lives in `hooks/lib/read_path_hygiene.py`; the deny reason names the rewrite so the agent self-corrects instead of waiting. Fail-open on unparseable input or a missing `python3`.

### install-security-gate.sh
- **Trigger:** PreToolUse (Bash tool)
- **Purpose:** Supply-chain security gate. Intercepts `pip install`, `npm install`, `git clone`, and real (unquoted) `curl | bash` commands before execution.
- **Behavior (SEC-7 two-mode):** decisions come from `scripts/automation/lib/install-gate.py` + `config/install-security-policy.json`: allow / warn (registry packages, SEC-6 — proceed with a logged banner) / block / require_approval. argv mode: banners on stdout, block/require_approval exit 1. Claude mode (stdin JSON): block/require_approval → agent-visible `permissionDecision:"deny"` with remediation, exit 0; warn → banner on stderr only. All decisions log to `reports/security/install-decisions.jsonl`.
- **Bypass:** Set `CHAIN_INSTALL_GATE_BYPASS=true` environment variable.

### post-edit-lint.sh
- **Trigger:** PostToolUse (Edit tool)
- **Purpose:** Lightweight syntax validation on edited source files.
- **Behavior:** Runs `python3 -m py_compile` on .py files. Reports syntax errors but does not block.

### post-write-artifact-quality.sh
- **Trigger:** PostToolUse (Write/Edit tool)
- **Purpose:** Two advisory checks on pipeline report artifacts:
  1. Vague-content / thin-file heuristic (`reports/phase-*` only) — flags placeholder lines (TBD/TODO/etc) and files under a minimum line count.
  2. Schema validation via `scripts/automation/lib/artifact_schemas.py` — verifies the verdict line is parseable, the verdict value is in the expected enum, and required H2 sections are present. Covers `reports/reviews/<phase>-review.md`, `reports/qa/<phase>-qa.md`, `docs/handoffs/<phase>-audit.md`, `reports/phase-<N>-closure-verdict.md`, `reports/phase-<N>-ux-regression.md`, `reports/phase-<N>-ui-test-results.md`.
- **Behavior:** Advisory only -- always exits 0. Prints structured warnings to stderr; does not block writes. Run `python3 scripts/automation/lib/artifact_schemas.py list` to see all recognized artifact types and their required sections.

### on-stop-check-artifacts.sh
- **Trigger:** Stop (session end)
- **Purpose:** Reminds the operator to check artifacts if a phase run is in progress.
- **Behavior:** Scans `runs/*/status.json` for in-progress phases and prints notices.

### permission-request-log.sh
- **Trigger:** PermissionRequest (Claude Code is about to need a human permission decision)
- **Purpose:** Stage-1, log-only recorder for the permission-economics telemetry (TOKEN-12 extension) — records that a human prompt was about to happen so `lib/analyze_transcripts.py` can count them deterministically. A deny mode (stage 2) is a separate roadmap experiment (CAND-PERM-1), not implemented here.
- **Behavior:** Pipes the PermissionRequest JSON on stdin into `hooks/lib/hook_events.py` (`--event permission_request`), which appends a privacy-safe event (suggestion count/types/hash only — never command or suggestion text). No stdout, no decision, exit 0 always — the native flow proceeds unchanged.
