# Anti-Patterns — documented failure modes (index)

One file per numbered entry, split from the former monolith (CTX-12) so a reader loads
only what matches the situation: scan this index, open the matching `<NN>-<slug>.md`,
nothing else. Numbering is FROZEN forever — files keep their original `## <N>. <title>`
headings; the next new entry takes the next free number (24) as `<NN>-<slug>.md` plus a
row here (maintenance protocol §2).

| # | Entry | Applies when | Rule (one line) |
|---|-------|--------------|-----------------|
| 1 | [01-vague-acceptance-criteria.md](01-vague-acceptance-criteria.md) | authoring phase specs | Every DEFINITION OF DONE item must be specific and testable |
| 2 | [02-hardcoded-stack-paths.md](02-hardcoded-stack-paths.md) | editing agent bodies/prompts | Stack commands live in project-template.md; agents reference, never inline |
| 3 | [03-merged-developer-agent.md](03-merged-developer-agent.md) | restructuring agents | One developer handles backend+frontend, driven by `Frontend Present:` |
| 4 | [04-ui-evolution-afterthought.md](04-ui-evolution-afterthought.md) | frontend-affecting phases | UI Evolution Audit gates QA; UI-FAIL blocks overall PASS |
| 5 | [05-quota-exhaustion-no-retry.md](05-quota-exhaustion-no-retry.md) | dispatch/retry plumbing | Checkpoint and resume on quota exits; never restart from scratch |
| 6 | [06-review-without-file-line.md](06-review-without-file-line.md) | writing review reports | Every finding carries file:line and a concrete fix task |
| 7 | [07-reviewer-qa-fixing-code.md](07-reviewer-qa-fixing-code.md) | reviewer/qa behavior | Judges report; only the developer fixes |
| 8 | [08-freeform-agent-conversation.md](08-freeform-agent-conversation.md) | inter-agent communication | Filesystem artifacts only; no agent-to-agent chat |
| 9 | [09-missing-functional-test-plans.md](09-missing-functional-test-plans.md) | QA pipeline | Derive an explicit test plan from the spec before QA runs |
| 10 | [10-supply-chain-attacks.md](10-supply-chain-attacks.md) | package installs | Every install goes through the security gate |
| 11 | [11-spec-without-definition-of-done.md](11-spec-without-definition-of-done.md) | phase spec authoring | Numbered, testable DEFINITION OF DONE in every spec |
| 12 | [12-agents-summarize-not-read.md](12-agents-summarize-not-read.md) | audit/review evidence | Verify claims from actual source code, not summaries |
| 13 | [13-backend-without-ui-verification.md](13-backend-without-ui-verification.md) | user-facing phases | 6 UI artifacts required; invisible features fail closure |
| 14 | [14-vague-test-steps.md](14-vague-test-steps.md) | test plan authoring | Exact URL, element, input, and expected outcome per step |
| 15 | [15-mocked-only-external-tests.md](15-mocked-only-external-tests.md) | external integrations | At least one live integration test; mocks alone prove nothing |
| 16 | [16-hardcoded-localhost.md](16-hardcoded-localhost.md) | service configuration | Bind addresses and URLs configurable; no localhost literals |
| 17 | [17-long-sleep-suspend.md](17-long-sleep-suspend.md) | wait/retry code | Sleep toward an absolute epoch with polling, never one long duration |
| 18 | [18-goal-journeys-anti-goals.md](18-goal-journeys-anti-goals.md) | goal.md authoring | Goal mode refuses to start without Must-have journeys + Anti-goals |
| 19 | [19-timeout-swallows-ctrl-c.md](19-timeout-swallows-ctrl-c.md) | timeout-wrapped dispatch | Use `timeout --foreground` so Ctrl-C reaches the child |
| 20 | [20-next-build-against-dev.md](20-next-build-against-dev.md) | Next.js projects | Never `next build` against a live `next dev`; separate distDir |
| 21 | [21-shared-tmp-accumulation.md](21-shared-tmp-accumulation.md) | temp files | Per-run TMPDIR isolation via chain-tmp.sh; never raw shared /tmp |
| 22 | [22-scanner-flags-own-output.md](22-scanner-flags-own-output.md) | scan scoping | Scan the product; exclude the pipeline's own bookkeeping paths |
| 23 | [23-prompt-argv-execve.md](23-prompt-argv-execve.md) | passing prompts to child processes | Prompt-sized content goes via stdin or file, never argv/env |
| 24 | [24-evidence-chasing-iterations.md](24-evidence-chasing-iterations.md) | evaluator/decomposer evidence demands | Evidence expires with change, not time; capture gaps ride the make-up lane or Depth: evidence — never an iteration goal |
