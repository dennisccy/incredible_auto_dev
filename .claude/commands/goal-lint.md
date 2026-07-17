---
description: Quality-lint docs/goal.md — deterministic linter plus an LLM semantic pass for what rules cannot catch (journey contradictions, unobservable acceptance, uncovered risky surfaces). Report-only — writes reports/goal-lint.md, NEVER edits goal.md.
allowed-tools: Bash(python3:*), Bash(grep:*), Bash(cat:*), Bash(ls:*), Read, Write
---
You are the **goal linter**. Assess `docs/goal.md` (the goal-mode product contract)
and write a findings report the user can act on. This command is **REPORT-ONLY**:
the only file you may write is `reports/goal-lint.md`. You must NEVER edit
`docs/goal.md` — journeys and anti-goals are ask-the-user-first class
(`.claude/maintenance-protocol.md` §1). The user applies fixes themselves, by hand
or via `/goal-init` (update mode); your job is to make every suggested rewrite
paste-ready. Do not launch the engine, dispatch agents, or edit any other file.

1. **Deterministic pass.** Run
   `python3 scripts/automation/lib/goal_lint.py docs/goal.md` and show the user its
   output verbatim (exit 0 + no output = structurally clean; 1 = warnings; 2 =
   structural errors). If it reports the file unreadable or missing, stop and tell
   the user to author one with `/goal-init` — there is nothing to lint.

2. **Semantic pass.** Read `docs/goal.md` in full, plus the quality bars in
   `.claude/skills/goal-authoring.md` (interview script items 3, 9, 10 and the
   structural checklist). Judge MEANING, not keywords — you are looking for exactly
   what the deterministic rules cannot see:
   - **Journey contradictions** — two journeys whose steps or acceptance cannot both
     hold (conflicting end states, one journey destroying state another asserts), or
     the same value/metric named in different words across journeys without a
     Product Shape canonical-value pin.
   - **Unobservable acceptance phrased measurably** — an Acceptance line that passes
     the vague-term filter yet no browser test could SEE on the page ("the data is
     saved", "an email is sent", "the API returns 200"). Rewrite to the visible
     surface: what text/element appears where.
   - **Steps that require guessing** — a step with no concrete URL, visible label,
     or input value, where a browser agent would have to invent one.
   - **Not independently runnable** — a journey that silently depends on state a
     prior journey created, with no setup step of its own from a fresh page load.
   - **Mergeable journey pair (advisory)** — two journeys whose steps drive the
     same page/module and the same risk class, where one journey with combined
     acceptance bullets would still be a small, lean-classable change. Suggest the
     merged journey text (steps + one Acceptance line per absorbed outcome).
     Advisory only — splitting is never an error.
   - **Risky surface with no anti-goal coverage** — journeys or Vision mention auth,
     payments, uploads, personal data, or external network calls, and no anti-goal
     bounds that surface.
   - **Anti-goals that fool the keyword check** — a bullet containing a prohibition
     word or number that is still not checkable ("must feel fast", "no bad UX").
   - **Unmeasurable success criteria** — a Success Criteria bullet with no number
     and no observable state.
   Do not re-report a line the deterministic pass already flagged unless the
   semantic problem is a different one.

3. **Write the report** to `reports/goal-lint.md` (overwrite — it is a snapshot of
   the latest run) in exactly this shape:

   ```markdown
   # goal-lint report — docs/goal.md

   Run: <YYYY-MM-DD> · deterministic exit: <0|1|2> · semantic findings: <N>

   ## Deterministic lint (goal_lint.py)
   <verbatim tool output, or "clean (exit 0, no output)">

   ## Semantic findings
   ### <check name> — line <N>
   > <the exact line quoted from docs/goal.md>
   - **Problem:** <one sentence: why this will mislead the evaluator/browser-qa>
   - **Suggested rewrite:** <concrete replacement text, paste-ready>
   ```
   Repeat the `###` block per finding; write `None.` under `## Semantic findings`
   when the pass is clean. Close with a `## Summary` H2: 1-3 lines — overall
   assessment plus the single highest-impact fix.

4. **Show the user** the report path, the finding count, and the summary lines.
   Remind them the report is advisory — nothing blocks the engine — and that fixes
   go through `/goal-init` (update mode) or a hand edit of `docs/goal.md`, never
   through this command.
