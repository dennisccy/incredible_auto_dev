# Skills and Hooks

## Skills (9 total, in `.claude/skills/`)

Skills are reusable instruction files that agents read during their workflow. They are not agents -- they are methodologies.

| Skill | File | Consuming Agent | Purpose |
|-------|------|----------------|---------|
| Diff-to-UI Impact | `diff-to-ui-impact.md` | ui-impact-analyst | Classify file changes by UI impact type (frontend-direct, backend-api, backend-internal, config, full-stack) |
| UI Workflow Inference | `ui-workflow-inference.md` | ui-impact-analyst | Infer user journeys from changed routes, components, and entry points |
| Visible Change Summarizer | `visible-change-summarizer.md` | ui-impact-analyst | Write plain-language user-facing change summaries for operators |
| Manual UI Test Plan Generator | `manual-ui-test-plan-generator.md` | ui-test-designer | Create human-executable test plans with exact steps and expected outcomes |
| What-to-Click Writer | `what-to-click-writer.md` | ui-test-designer | Write fast operator verification guides (5-minute check) |
| Browser Workflow Executor | `browser-workflow-executor.md` | browser-qa-agent | Execute browser flows via Chrome MCP (navigate, click, type, screenshot) |
| UI Regression Scout | `ui-regression-scout.md` | ux-regression-reviewer | Identify prior-phase user journeys affected by current changes |
| Phase Closure Gate | `phase-closure-gate.md` | phase-closure-auditor | Evaluate phase completion criteria (artifact existence, quality, consistency) |
| Architecture Doc Updater | `architecture-doc-updater.md` | update-docs.sh | Update framework or project architecture docs when source files drift |

## Hooks (5 total, in `.claude/hooks/`)

Hooks are shell scripts triggered by Claude Code at specific lifecycle points. They are configured in `.claude/settings.json`.

### guard-dangerous-commands.sh
- **Trigger:** PreToolUse (Bash tool)
- **Purpose:** Secondary safety layer for dangerous command patterns (rm -rf, dd, force-push main, credential reads). Primary protection is deny rules in `.claude/settings.json`.
- **Behavior:** Exits non-zero if a dangerous pattern is detected, blocking the command.

### install-security-gate.sh
- **Trigger:** PreToolUse (Bash tool)
- **Purpose:** Supply-chain security gate. Intercepts `pip install`, `npm install`, `git clone`, and `curl | bash` commands before execution.
- **Behavior:** Checks against `config/install-security-policy.json`. Returns allow, review_required, or deny. Logs all decisions to `reports/security/install-decisions.jsonl`.
- **Bypass:** Set `CHAIN_INSTALL_GATE_BYPASS=true` environment variable.

### post-edit-lint.sh
- **Trigger:** PostToolUse (Edit tool)
- **Purpose:** Lightweight syntax validation on edited source files.
- **Behavior:** Runs `python3 -m py_compile` on .py files. Reports syntax errors but does not block.

### post-write-artifact-quality.sh
- **Trigger:** PostToolUse (Write/Edit tool)
- **Purpose:** Warns when phase report artifacts (`reports/phase-*`) contain vague or too-short content.
- **Behavior:** Advisory only -- always exits 0. Prints warnings for placeholder lines or files under a minimum length.

### on-stop-check-artifacts.sh
- **Trigger:** Stop (session end)
- **Purpose:** Reminds the operator to check artifacts if a phase run is in progress.
- **Behavior:** Scans `runs/*/status.json` for in-progress phases and prints notices.
