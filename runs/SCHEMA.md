# Run Artifact Schema

Each phase execution produces artifacts under `runs/<phase>/`.

## status.json

Machine-readable current state of a phase run. Written and updated by automation scripts.
Read by `run-phase.sh` to determine checkpoint resume behavior.

```json
{
  "phase": "<phase>",
  "current_step": "init | planned | test_plan_generated | dev_complete_attempt_N | review_passed | qa_passed | audit_passed | failed",
  "status": "in_progress | complete | blocked | failed",
  "started_at": "2026-01-01T10:00:00Z",
  "updated_at": "2026-01-01T11:30:00Z",
  "blockers": [],
  "changed_files": ["src/api/routes/resource.py"],
  "tests_run": true,
  "browser_checks_run": false,
  "next_action": "finalize | fix_review | fix_qa | fix_audit | none"
}
```

### current_step resume behavior

| `current_step` | Steps skipped on resume |
|---|---|
| `planned` | Plan |
| `test_plan_generated` | Plan, test plan |
| `dev_complete_attempt_*` | Plan, test plan; first dev pass (review re-runs) |
| `review_passed` | Plan, test plan, dev+review |
| `qa_passed` | Plan, test plan, dev+review, QA — audit and finalize run |
| `audit_passed` | Plan, test plan, dev+review, QA, audit — only finalize runs |
| `ui_impact_complete` | Plan, test plan, dev+review, UI impact analysis |
| `ui_test_designed` | Plan, test plan, dev+review, UI impact, UI test design |
| `browser_qa_complete` | Plan through browser QA |
| `post_dev_parallel_complete` | Plan through Steps 4–7 — only written by `run-phase.sh --fast` after the parallel post-dev fanout (UI chain + QA-validate) succeeds. Resumes proceed to Step 8. |
| `ux_regression_complete` | Plan through UX regression review |
| `closure_passed` | All steps — only finalize runs |
| `summary.json` has `status: "finalized"` | All steps — exits immediately |

### blockers format

Each entry in `blockers` is a string describing what is blocking progress:
```json
"blockers": ["QA failed: TC-03 state transition not enforced", "Review: missing input validation on POST /api/v1/resource"]
```

### changed_files

List of paths (relative to repo root) modified during dev. Used by the auditor agent to know which source files to inspect.

---

## summary.json

Human-readable final summary of a completed phase. Written by `finalize-phase.sh`.

```json
{
  "phase": "<phase>",
  "status": "finalized",
  "qa_passed": true,
  "audit_passed": true,
  "finalized_at": "2026-01-01T12:00:00Z",
  "artifacts": {
    "plan": "runs/<phase>/plan.md",
    "test_plan": "reports/qa/<phase>-test-plan.md",
    "review_report": "reports/reviews/<phase>-review.md",
    "qa_report": "reports/qa/<phase>-qa.md",
    "audit_report": "docs/handoffs/<phase>-audit.md",
    "status": "runs/<phase>/status.json"
  }
}
```

---

## plan.md

Written by the orchestrator agent at the start of each phase. Read by all subsequent agents.

Required fields (machine-read by scripts):
```
Frontend Present: yes
```
or
```
Frontend Present: no
```

This line controls whether `dev-phase.sh` runs the second frontend pass and whether `qa-phase.sh` runs Chrome MCP browser checks.

---

## UI Audit Artifacts

### reports/qa/\<phase\>-ui-audit.md

Optional standalone UI evolution audit, produced by `./scripts/automation/ui-audit-phase.sh <phase>`.
Also included as a section inside `reports/qa/<phase>-qa.md` when `Frontend Present: yes`.

```markdown
## UI Evolution Audit — <phase>

**Verdict:** UI-PASS | UI-PASS-WITH-GAPS | UI-FAIL

### Questions answered
1. Did the UI evolve to reflect the phase's new capability? <answer>
2. Can the user see/understand/control the new capability? <answer>
3. Is the UI still relying on old generic pages? <answer>
4. Is the implementation underexposed product-wise? <answer>

### Gaps (if any)
- <gap description>

### Recommendation
<action or none>
```

---

## Artifact locations (all phases)

| Artifact | Path |
|---|---|
| Phase spec | `docs/phases/<phase>-<name>.md` |
| Execution plan | `runs/<phase>/plan.md` |
| Phase status | `runs/<phase>/status.json` |
| Phase summary | `runs/<phase>/summary.json` |
| Test plan | `reports/qa/<phase>-test-plan.md` |
| Review report | `reports/reviews/<phase>-review.md` |
| QA report | `reports/qa/<phase>-qa.md` |
| UI audit report | `reports/qa/<phase>-ui-audit.md` |
| Audit report | `docs/handoffs/<phase>-audit.md` |
| Dev handoff | `docs/handoffs/<phase>-dev.md` |
| Frontend handoff | `docs/handoffs/<phase>-frontend.md` |
| Implementation summary | `reports/phase-{N}-implementation-summary.md` |
| User-visible changes | `reports/phase-{N}-user-visible-changes.md` |
| UI surface map | `reports/phase-{N}-ui-surface-map.md` |
| UI test plan | `reports/phase-{N}-ui-test-plan.md` |
| UI test results | `reports/phase-{N}-ui-test-results.md` |
| What to click | `reports/phase-{N}-what-to-click.md` |
| UX regression report | `reports/phase-{N}-ux-regression.md` |
| Closure verdict | `reports/phase-{N}-closure-verdict.md` |
| Iteration summary (MD) | `reports/phase-<phase>-iteration-summary.md` |
| HTML iteration summary | `reports/phase-<phase>-summary.html` |
| Goal-mode session index | `reports/goal-session-<sid>-index.html` |
| Demo script (per iter) | `reports/phase-<phase>-demo-script.md` |
| Demo results (per iter) | `reports/phase-<phase>-demo-results.md` |
| Demo screenshots (per iter) | `reports/demo/<phase>/step-NN.png` |
| Cumulative project story (goal mode) | `runs/goal-session-<sid>/state/project-story.md` |
| GOAL_ACHIEVED delivered wrap (MD) | `reports/goal-session-<sid>-delivered.md` |
| GOAL_ACHIEVED delivered wrap (HTML) | `reports/goal-session-<sid>-delivered.html` |

---

## UI Visibility Artifacts (per phase, in `reports/`)

Six artifacts are produced for every phase. For backend-only phases (`Frontend Present: no`), N/A stubs are written automatically.

### reports/phase-{N}-implementation-summary.md

Written by the developer as part of the dev handoff. Contains:
- Features implemented (plain-language, not code)
- Changed behavior (existing features that work differently)
- Backend-only items (complete but not UI-wired)
- Incomplete items (deferred or partial)
- Config/env changes
- Known limitations

### reports/phase-{N}-user-visible-changes.md

Written by the ui-impact-analyst. Contains:
- What users can now do
- What changed in the visible UI
- Behavior changes
- Not-visible-yet items (backend without UI)

### reports/phase-{N}-ui-surface-map.md

Written by the ui-impact-analyst. A table of every affected route, page, component, form, modal, table, chart, or navigation element. Each row has: route/page, component/element, change type, why changed, what to test (specific action).

### reports/phase-{N}-ui-test-plan.md

Written by the ui-test-designer. Structured test cases (UT-01, UT-02, ...) with:
- Type: smoke | happy-path | validation | error | regression | ux
- Exact numbered steps with specific URLs, button text, field names
- Exact expected results visible to the operator

### reports/phase-{N}-ui-test-results.md

Written by the browser-qa-agent. Contains:
- Browser QA Verdict: PASS | FAIL | SKIPPED
- Results table (test ID, expected, actual, verdict, evidence path)
- Per-test detail for failures and skips
- Environment info

### reports/phase-{N}-what-to-click.md

Written by the ui-test-designer. A 3–10 step operator guide to verify the phase in under 5 minutes. Contains exact URLs, exact actions, and exact expected outcomes. No developer knowledge required to follow.

### reports/phase-{N}-closure-verdict.md

Written by the phase-closure-auditor. Final gate before finalize. Contains:
- **Verdict:** CLOSURE-PASS | CLOSURE-FAIL
- Standard pipeline gate checks
- UI artifact existence and quality checks
- Cross-reference consistency checks
- Blocking issues (if any)

---

## Iteration summary + HTML report

### reports/phase-\<phase\>-iteration-summary.md

The conclusive per-iteration markdown. Written by the
`iteration-summarizer` agent (`.claude/agents/iteration-summarizer.md`)
between the closure check (Step 10) and finalize (Step 11) in phase mode,
and after the goal-evaluator step in goal mode. The agent reads every
relevant artifact and writes one MD that answers: what was done, what's
left, what direction we're moving in, and what's next.

Section structure (HTML renderer keys off these headings):
1. **Headline** — one-line outcome
2. **Direction** — `Signal: improving | holding | stalling | regressing | n/a`
   + a short Why + (goal mode) a 5-iter trend block + verbatim latest
   evaluator reasoning
3. **What was done** — 3–8 action bullets
4. **What's left** — failing journeys, closure blockers, Not-Visible-Yet,
   known limitations
5. **Next step** — recommendation, verbatim from `eval.md` in goal mode
6. **Quick verify** — numbered steps copied from `what-to-click.md`
   (full iters only)
7. **Artifacts** — pipe-table link list to underlying MDs with verdicts

Top of file: `**Verdict:** VALUE` where VALUE is one of GOAL_ACHIEVED,
CONTINUE, ESCALATE, REGRESSION, STALLED, PASS, FAIL, IN-PROGRESS. Plus
`**Iteration type:** phase | goal-lean | goal-full` and `**Date:**`.

The verdict line and required H2 sections are validated by
`lib/artifact_schemas.py` (artifact_type `iteration-summary`).

### reports/phase-\<phase\>-summary.html

Self-contained HTML view of one iteration. Written by
`scripts/automation/lib/render_iteration_summary.py` immediately after the
iteration-summary MD is generated. The renderer is deterministic: it only
reads the summary MD + journey-history.json + screenshot paths from
`ui-test-results.md`.

Hero + five collapsible accordions:
- **Hero** — verdict badge, direction-signal badge, headline, journey
  pills (goal mode), first browser-QA screenshot.
- **What was done** — bullets from the summary MD section.
- **What's left + Next step** — bullets + recommendation.
- **Direction signal** — Why + trend bullets + latest evaluator reasoning
  (open by default in goal mode).
- **Quick verify (5 min)** — numbered steps with paired screenshots.
- **Artifacts** — link table to source MDs.

Self-contained: inline CSS, inline SVG, base64-embedded PNGs. No
network refs. Pillow used when available to resize >500 KB screenshots.

Re-generate either or both files at any time with:

    bash scripts/automation/render-summary.sh <phase-id>
    bash scripts/automation/render-summary.sh <phase-id> --no-resummarize  # HTML only, no agent call

The renderer is non-blocking: failure never fails the pipeline.

### reports/goal-session-\<sid\>-index.html

Goal-mode-only. Written by every `write_session_summary` call (each
session boundary — CONTINUE, ABORT, GOAL_ACHIEVED, REGRESSION_HALT,
STALLED, BUDGET_EXHAUSTED). Contains the goal title, overall verdict, **the
cumulative plain-language "story so far"** (rendered from
`state/project-story.md`), **the latest iteration's narrated demo gallery**,
a journey progress matrix (rows × iterations), and one card per iteration
linking to its `phase-<iter-name>-summary.html`. When the session has
reached GOAL_ACHIEVED, a prominent banner links to the delivered wrap.

---

## Demo gallery (per iteration)

For frontend iterations, the `demo-narrator` agent
(`.claude/agents/demo-narrator.md`) runs immediately after browser QA — in
the same app-up window — and walks the **whole working product so far**,
flagging steps added/changed this iteration as `[NEW]`. It is a showcase,
not QA: a failed step is a soft note, never a hard pipeline fail.

### reports/phase-\<phase\>-demo-script.md

Plain-language narrated script of every demo step. Sections: **Highlights**
(up to 8 steps, each captured as a screenshot) and **Full tour** (text-only
extras). Each step records narration, exact action, and what to point out.

### reports/phase-\<phase\>-demo-results.md

The machine-readable companion. Top of file:
`**Demo Verdict:** RECORDED | RECORDED_WITH_NOTES | SKIPPED | NOT_YET`
plus a `## Captured Steps` pipe-table (Step | Title | New | Screenshot) and
an optional `## Soft notes` bullet list. The HTML renderer keys off the
table and the verdict badge.

### reports/demo/\<phase\>/step-NN.png

One PNG per Highlights step, captured by the agent via Chrome MCP against
the running app. Base64-embedded into the iteration HTML by the renderer.

---

## Cumulative project story (goal mode only)

### runs/goal-session-\<sid\>/state/project-story.md

A single flowing plain-language narrative of how the product has grown
across all iterations in the session. Maintained by the
`iteration-summarizer` agent on every iteration (it reads the existing
file, weaves in this iteration's "In plain words" content, and rewrites
the whole story). Capped at ~400 words; older filler is condensed as
newer content is added. Rendered as the leading section of the session
index HTML.

---

## Delivered wrap (goal mode, GOAL_ACHIEVED only)

When goal-evaluator returns `GOAL_ACHIEVED`, `run-goal.sh` triggers a
one-time polished "what we delivered" pass via the iteration-summarizer
in delivered mode.

### reports/goal-session-\<sid\>-delivered.md

Friendly, non-technical summary of everything the product can do, how it
came together (one short paragraph per major milestone), and a pointer to
the embedded walkthrough. No journey IDs, no file names.

### reports/goal-session-\<sid\>-delivered.html

Self-contained HTML companion. Goal-achieved hero, the delivered MD body,
and the latest demo gallery embedded. The session index surfaces a banner
linking to this page once it exists.
