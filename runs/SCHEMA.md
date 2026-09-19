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
| `post_dev_parallel_complete` | Plan through Steps 4–7 — written by `run-phase.sh` after the parallel post-dev fanout (UI chain + QA-validate) succeeds. Backend-only phases skip the fanout and never write this label. Resumes proceed to Step 8. |
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
| Coherence blueprint (goal mode) | `runs/goal-session-<sid>/state/blueprint.md` |
| Coherence audit per iter (goal mode) | `runs/goal-session-<sid>/iter-<N>/coherence.md` |
| Goal-edit drift note (goal mode) | `runs/goal-session-<sid>/iter-<N>/journeys-changed.md` |
| Canonical spec-field halt marker (goal mode, HARD-2) | `runs/goal-session-<sid>/iter-<N>/spec-field-unavailable` — written when the executor exited 78 because a `## Goal Mode Metadata` machine field could not be read at runtime (`reason=`, `rc=`, `spec=`, `iter=`, `detected_at_step=`). The iteration is neither evaluated nor advanced |
| Spec-lint report (goal mode, HARD-2) | `runs/goal-session-<sid>/iter-<N>/spec-lint.txt` and `.json` — the deterministic iteration-spec lint's findings (`[spec-lint] ERROR\|WARN <rule> <name>: <msg>` lines; the JSON adds the parsed metadata and `work_kind_derived`, and — HARD-3, when the side-effect preflight ran — a `side_effects` block: `policy`, `availability` of the ledger, `journeys_checked` with their `roles` and `statuses`, `mutating`/`unknown`/`none`, the declared-none / observed-mutating `conflicts`, the `sticky` journeys, `policy_intent` / `policy_intent_where` / `policy_intent_hidden` / `restrictive` (the metadata section's policy lines decide — anything but a plain `allowed`, optionally followed by a dash note, in any label shape, is restrictive; lines elsewhere count only when the section has none; when the reading with code fences and HTML comments paired finds nothing restrictive, a reading that ignores them decides and `policy_intent_hidden` says so), the explicit `prohibitions` found (`section`, `line`, `text`, `pattern`; `fence_blind: true` marks one found only by the second scan, which ignores code fences because a stray fence can shift the pairing without a trace; an item's wrapped lines and continuation paragraphs are scanned as one text; on an OUT OF SCOPE item naming an activity — creating/editing/… ledger rows, launching/starting/triggering/… a run — is a prohibition; on a TC / DoD item a sentence that names one is a prohibition when a negation reaches it: a verbal negation (not, never, cannot, avoid, forbid, out of scope, …) anywhere in the sentence, or a noun-phrase negation (no, none, nothing, without, except, …) before the activity in its own clause, inside its phrase or as its predicate — unless the negation is about "pre-existing" data or is the "no …" result of a refused request; an activity on pre-existing rows only, or carved out for a journey's own step ("beyond J-04's own step 1"), is not one anywhere; the exact rule is the comment above `_ACTIVITY_PARTS` in `lib/iter_spec.py`), the `declaration_digest` and `build_id` it was checked against; this is the preflight view even after the ledger file is refreshed for the evaluator; HARD-3 B3 adds `conflict_journeys` — the journeys an emitted E13/E16 finding NAMED — and `retain_required`, the Required-still-passing subset of those, which is what the engine records as the iteration's obligation). When the engine passed an obligation set (`--retain-journeys`), a top-level `obligations` block records `{retain, kept, dropped}` so no reader has to parse E17's message text. Written on every linted iteration, clean or not. `spec-lint.stderr` holds the linter's own stderr and is what `spec_lint_crash` samples |
| Spec obligations (goal mode, HARD-3 B3, engine-owned) | `runs/goal-session-<sid>/iter-<N>/spec-obligations.json` — `{iter_name, attempt, recorded_at, rule_ids:["E13"/"E16"], journeys:[J-NN,...]}`. Written by `run-goal.sh` ONLY when this iteration's first spec was rejected under E13/E16 and the finding named Required-still-passing journeys (`side_effects.retain_required` in `spec-lint.json`); the union is taken with whatever is already recorded, so a resumed iteration never narrows its own obligation. Read by every later spec lint of the SAME iteration — the re-plan and any resume — as `iter_spec.py lint --retain-journeys`, which raises `E17` when a listed journey appears in neither `Target journeys:` nor `Required-still-passing journeys:` nor the engine's make-up set. The path IS the scope: no other iteration can read it, and nothing carries it forward. Written atomically (tmp + `os.replace`) and read FAIL-CLOSED: a file that exists but carries no readable journey list halts `GATE_BLOCKED` (`detected_at_step:"spec-obligations"`, telemetry `spec_obligation_unreadable`) instead of being read as "no obligation". Lifetime = the iteration directory; no separate cleanup — an operator who deliberately retires an obligation (the journey was removed from `docs/goal.md`) DELETES this file, or dispatches with `CHAIN_SPEC_LINT=warn` |
| Side-effect ledger per iteration (goal mode, HARD-3) | `runs/goal-session-<sid>/iter-<N>/side-effects.json` — see "Journey side-effect ledger" below; `side-effects.preflight.json` beside it is the iteration's frozen preflight view |
| Side-effect sidecar (goal mode, HARD-3, engine-owned) | `runs/goal-session-<sid>/state/journey-side-effects.json` |
| Replay side-effect run records (goal mode, HARD-3) | `runs/goal-session-<sid>/iter-<N>/replay-side-effects.json` (current) and `replay-side-effects.<stamp>-<pid>-<n>.json` (archived, never deleted) |
| Read-only endpoint exceptions (owner-authored, optional, HARD-3) | `project-extensions/side-effects/read-only-endpoints.txt` |
| Evidence-mode refusal marker (goal mode, HARD-1) | `runs/goal-session-<sid>/iter-<N>/evidence-mode-refused` — written by `goal-iter-lean.sh` when an evidence-only dispatch was refused because the spec plans implementation work (`reason=`, `spec=`, `work=`); the engine re-dispatches the iteration lean. On the evidence micro-path the dev handoff carries `**Developer status:** NOT_DISPATCHED` and the review file carries `**Review status:** NOT_DISPATCHED` (no verdict line) |
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

## Coherence blueprint + audit (goal mode only)

### runs/goal-session-\<sid\>/state/blueprint.md

The coherence contract for the whole app. Drafted by the `goal-decomposer` in baseline mode,
reviewed/approved once by the human (the loop pauses with status `AWAITING_BLUEPRINT_APPROVAL` until
`--resume`, or `--auto-approve-blueprint` skips the pause), and enforced every iteration by the
`coherence-auditor`. Two sections:

- **Information Architecture** — layout shell, navigation skeleton, and the canonical home for each
  feature/entity (each reachable in ≤2 clicks from the persistent nav).
- **Data Contract** — one row per displayed value/entity: the single module that computes it and the
  single endpoint that serves it. No surface may recompute or re-fetch a registered value elsewhere.

Approval is recorded by the marker file `state/blueprint.approved`. A
`state/blueprint.reapproval-requested` marker (written by the decomposer only when it changes the nav
skeleton) triggers another approval pause. Template: `templates/blueprint.md`.

### runs/goal-session-\<sid\>/iter-\<N\>/coherence.md

Written by the `coherence-auditor` after each building iteration (skipped at baseline — no code yet).
Top line: `**Verdict:** COHERENCE-PASS | COHERENCE-WARN | COHERENCE-FAIL`. Contains a Data-Contract
check table, an Information-Architecture check table, blocking violations (FAIL only — each with a
`file:line` and a concrete finite fix), and advisory notes. The `goal-evaluator` treats
`COHERENCE-FAIL` as a veto on `GOAL_ACHIEVED` and drives a consolidation `CONTINUE`. A missing file is
treated as a non-blocking PASS. Template: `templates/coherence-verdict.md`.

---

## Goal-edit drift note (goal mode only)

### runs/goal-session-\<sid\>/iter-\<N\>/journeys-changed.md

Written by `run-goal.sh` (pre-evaluator step 3c) via `goal_gate.py hash-journeys --history
--out-changed`; the same call removes a stale note when nothing is flagged. Present ONLY when a
journey recorded `passing`/`already_passing` in `state/journey-history.json` carries a `spec_hash`
that no longer matches its current `docs/goal.md` block — i.e. the user edited the goal mid-session
(the intended veto mechanism). One bullet per journey: id, name, recorded status, and
`old → new` hash prefixes.

Readers:
- **goal-evaluator** — every listed journey's prior pass is void: re-verify it against the CURRENT
  text this iteration (then record the new `spec_hash` in `journey-history.json`) or demote it to
  `unknown`. `spec_hash` is written ONLY by the goal-evaluator, and only for journeys verified that
  iteration.
- **Achievement gate** (`lib/goal-gates.sh` check 6 → `goal_gate.py drift`) — refuses
  `GOAL_ACHIEVED` while any listed journey still counts as passing without a re-recorded
  `spec_hash`; fails closed on an unparsable note or unreadable history.

Histories without `spec_hash` (pre-NEED-9 sessions) parse everywhere and are never demoted by this
mechanism — a missing hash means "unknown", not "stale".

---

## Journey side-effect ledger (goal mode only, HARD-3)

A journey's **side-effect status** is `mutating`, `none` or `unknown`: `mutating` when the
owner declared `- Side effects: mutating — <note>` in its `docs/goal.md` block OR a
deterministic replay observed it send a same-project POST/PUT/PATCH/DELETE that no later
complete replay of the SAME golden script cleared (an observation always outranks a `none`
declaration); `none` when the owner declared `none`, nothing was observed, and the
observations could be read; `unknown` otherwise (no line, an invalid one, or unreadable
observations). Only a WELL-FORMED declaration line is dropped before a journey's `spec_hash`
is computed (journey-hash-neutral); a malformed declaration-shaped line is ordinary journey
text (editing it is goal-edit drift). Declaration provenance is the `declaration_digest`
below plus `side_effect_declaration_changed` telemetry.

### runs/goal-session-\<sid\>/iter-\<N\>/side-effects.json

Written by `run-goal.sh` via `lib/goal_gate.py side-effects` (atomically): once BEFORE the
goal-decomposer (`built_at_step: "preflight"`, stamped with a fresh `build_id` that the spec
lint must see — an existing file is removed first, and a file that survives a failed build
carries another build id, so the lint reads it as unavailable) and refreshed before the
goal-evaluator (`"pre-evaluator"`, keeping the preflight file if the refresh fails). The
iteration's first COMPLETE preflight build is also kept as `side-effects.preflight.json`
(`--freeze`). A later preflight of the same iteration reuses it — `frozen: true`,
`frozen_at`, a new `build_id` — only when the spec already written will be re-linted WITHOUT
re-planning (the decomposer checkpoint is valid), its `input_fingerprint` (declaration digest,
auth list, exception file, classifier version, journey set) is unchanged and the fresh build
is complete: such a spec is judged against the evidence it was planned against, never its
own replay's observations. A spec about to be (re)written — no valid checkpoint, or a re-plan
after a frozen view was rejected — is planned against a fresh build, which becomes the new
frozen view. Changed inputs are rebuilt too. Readers:
the spec lint (`iter_spec.py lint --side-effects … --side-effects-build-id …`), both browser
lanes (`CHAIN_SIDE_EFFECTS_FILE`), the decomposer and evaluator prompts. Shape:

```json
{"schema_version": 1, "build_id": "<id|null>", "input_fingerprint": "<sha256>", "frozen": false,
 "built_at": "...", "built_at_step": "preflight", "declarations_seeded_from": null,
 "iter": 9, "iter_name": "goal-<sid>-iter-9", "complete": true, "errors": [],
 "declaration_digest": "<sha256>", "declaration_digest_prev": "<sha256|null>",
 "declaration_digest_changed_iter": 7, "declaration_digest_changed_this_iter": false,
 "readonly_endpoints": {"path": "...", "present": true, "sha256": "...", "entries": [["POST", "/api/policy/evaluate"]], "invalid": [], "error": null},
 "ignore_paths": ["/login", "/logout", "/auth", "/session", "/token", "/csrf"], "ignore_paths_default": true,
 "ignore_paths_rejected": [], "run_records_pending": [],
 "journeys": {"J-04": {"name": "...", "declared": "mutating", "declaration_valid": true,
   "declaration_errors": [], "declaration_hash": "<sha256>", "note": "...",
   "observed_mutating": true, "observed_iter": 8, "observed_iter_name": "goal-<sid>-iter-8",
   "observation_complete": true, "observation_basis": "recorded", "observation_established": true,
   "observation_sticky": false, "sticky_detail": null, "observed_at": "2026-09-17T00:00:00.000000Z",
   "golden_sha256": "<sha256>", "declaration_conflict": false, "unattributed": false,
   "ambiguous": false, "attribution_reason": null, "stated_values": [],
   "requests": [{"method": "POST", "path": "/api/runs", "class": "mutating", "count": 1}],
   "exceptions_applied": [], "auth_ignored": [{"method": "POST", "path": "/api/login"}],
   "status": "mutating", "status_source": "declared+observed",
   "step_hints": [{"n": 1, "text": "click Run", "words": ["run"]}]}},
 "summary": {"mutating": ["J-04"], "none": [], "unknown": []}, "conflicts": [], "declaration_errors": []}
```

`complete: false` (with `errors`) means observed mutations or read-only exceptions could not be
established (corrupt sidecar, unreadable per-run record, unreadable exception file); declared
mutations and any mutation that can still be read stay `mutating`, and a declared `none` whose
observations cannot be read is `unknown` (`status_source: "declared-unverified"`). A spec with
`Side-effect policy: none` fails closed on an incomplete, missing or stale ledger (E15);
any other policy only warns (W11). `declaration_digest` = sha256 over the sorted parsed
declarations (journey, value, normalized note, `declaration_hash`) plus the exception file's
sha256 — formatting-only edits of a well-formed line do not change it; value, note, exception
edits and ANY edit of a malformed line do. `observation_basis`: `recorded`, `reclassified`
(the exception file, the auth list or the classifier rules changed since the observation, so
the stored `{method, path}` sample was re-classified with the current rules) or
`reclassification-unverifiable` (a truncated sample — kept mutating, fail closed).
`observation_sticky` marks a mutation a newer complete clean replay could not clear because it
replayed a different golden script (`sticky_detail` names that replay). When the sidecar holds
no declaration record (a new session, or a sidecar moved aside), the newest earlier
`iter-<K>/side-effects.json` is the provenance baseline (`declarations_seeded_from`), so a
declaration flip made at the same time is still reported. `declaration_conflict`
(and the top-level `conflicts` list) marks a journey observed mutating whose own definition
declares `none` — or, for an `unattributed` / `ambiguous` id, any of whose stated values is
`none` (the prompts call that a POSSIBLE conflict). The ledger never lists fewer journeys than the certified drift gate
(`_journey_blocks`), and never trusts a `none` a shifted fence reading may have
misattributed. An id no definition covers is `unattributed` (`attribution_reason`
`no-definition` — only nested references name it — or `fenced-header` — its only header
sits inside a code fence). An id WITH a definition whose header also appears inside a code
fence is `ambiguous` (`fenced-header`): a stray fence can shift the pairing of every later
fence without a trace, so either block may be the journey (goal-lint's duplicate-id ERROR
already asks the owner to rename an example that reuses a real id). A header read as fenced
still ends the live block above it (as in the certified splitter), so one journey's block never
runs on through another's lines. A live definition whose `Side effects: mutating` line only a
fence-ignoring read sees (a stray fence may have hidden it) is `ambiguous`
(`fenced-declaration`): it counts as mutating. For all of these, an extra header's own list item is read (never a neighbour's lines),
`stated_values` lists the values stated there — provenance, never reported as `declared`: a
stated `mutating` makes the journey mutating, a `none` is never trusted — the observations
still count, `status_source` is `unattributed` / `ambiguous` (or `observed`), an
observed write against a stated `none` is a POSSIBLE `declaration_conflict`, the digest
records the attribution, and goal-lint reports it (`side-effects-unattributed` WARN, or the
`side-effects-invalid` ERROR of the ambiguous definition). Code fences are paired the
CommonMark way: same character, closer at least as long with nothing after it, at the same
blockquote depth and at most 3 columns deeper than the opener; an opener may sit on a
list-item line and then ends with its item; a quoted fence ends with its quote; a top-level
opener that is never closed is ordinary text. A declaration-shaped line inside a fence is journey
text (never a declaration, never dropped from `spec_hash`). A nested header is a definition
when its own item carries a declaration or a numbered step, or when it names a journey no
top-level header defines; a bare or titled mention of a top-level journey is a reference. `run_records_pending` lists per-run records the sidecar has not merged yet (they are
applied in memory; the preflight's record step merges them).

### runs/goal-session-\<sid\>/state/journey-side-effects.json

The engine-owned sidecar. Two writers, both read-modify-write under an exclusive `flock` on the
`state/` directory itself (no lock file, `CHAIN_SIDE_EFFECT_LOCK_TIMEOUT` seconds, default 10)
with atomic replace: the replay lane (`demo_runner.py --side-effects-out`) and the preflight
record step (`goal_gate.py side-effects --record-digest`), which first merges every per-run
record whose `run_id` is not in `merged_runs` yet (repair — telemetry
`side_effect_observations_repaired`, only for records that observed a journey) and then writes `declarations`, `declaration_digest`,
`declaration_digest_prev`, `declaration_digest_changed_iter`, `readonly_endpoints_sha256`,
`ignore_paths` (the auth/session exclusion list in force — a change emits
`side_effect_declaration_changed` with `source:"auth-ignore-paths"`) and
`declaration_conflicts` (the declared-none / observed-mutating conflicts already reported).
Per journey (`journeys.<J>`): `last_attempt` (the newest observation), `latest` (the newest
complete-or-mutating observation — display), `mutating_history` (last 5) and the status
evidence `goldens.<golden_sha256|"unidentified">: {mutating, clean}` — the newest mutating
observation (request samples unioned across uncleared observations) and the newest COMPLETE
clean replay of that golden (with its request sample, so a request an exclusion let through
is re-checked if the exclusion is withdrawn). A mutation counts until a strictly newer
complete clean replay of the SAME golden exists: a partial, blind or other-golden replay never
clears it, and a mutation without a golden identity or with an unreadable `observed_at` is
never cleared. Whether a journey has uncleared evidence does not depend on the order the
observations were merged in (a union's request sample can, and only by holding more
requests). At most 50 goldens are kept per journey: only entries with nothing left to prove
are dropped, and a dropped entry's clean time stays in `cleared_goldens` (at most 500).
`merged_runs` lists every merged run id (bounded at 100 000), including runs that observed no
journey. A corrupt or
wrongly-shaped sidecar is never overwritten by either writer; moving it aside loses nothing,
because the next ledger is rebuilt from the per-run records.

### runs/goal-session-\<sid\>/iter-\<N\>/replay-side-effects.json

One replay run's observations (`demo_runner.py --side-effects-run-out`): `run_id`, `iter`,
`iter_name`, `observed_at` (microsecond UTC), `classifier_version` (3 since the auth exclusions name
endpoints rather than subtrees — an observation recorded under another version is re-classified
by the ledger with the current rules), the exception file's
path/sha256/invalid lines, the auth ignore list (and any rejected entries), `journeys.<J>`
observation records (with `golden_sha256`, the identity of the golden script's executable
content) and `sidecar: {path, updated, message, clear_refused?}`. Written even when the sidecar
update fails. Before every verify call, at replay-lane entry and when a forked lane is reaped,
an existing record is ARCHIVED beside it as `replay-side-effects.<stamp>-<pid>-<n>.json` —
never deleted: all of them together are the session's durable observation history, which the
ledger reads. The record is written BEFORE the sidecar update (then rewritten with the
update's outcome), so an interruption can never leave an observation only in the sidecar.
After each verify call `lib/replay-lane.sh` emits `side_effect_observed` /
`side_effect_exception_applied` / `side_effect_clear_refused` /
`side_effect_sidecar_update_failed` from the current record — never from one observed before
that call started.
Observation records keep only `{method, path, class, count}` per distinct request (at most 20;
`truncated` says when more existed) — never a query string, header or body.

### project-extensions/side-effects/read-only-endpoints.txt (owner-authored, optional)

One `METHOD /path-prefix` per line (`#` comments), e.g. `POST /api/policy/evaluate` for an
endpoint that computes without persisting. Matching is method-exact and whole-segment-prefix
(`/api/policy/evaluate/42` yes, `/api/policy/evaluate-and-save` no); a path with a dot segment,
a backslash or an encoded separator never matches. Lines naming a non-mutating method, a
relative path, a bare `/` or such a path are reported and never applied. Its sha256 is part of
the declaration digest, and every applied exception is reported in the results row and in
telemetry. The framework never writes this file.

### Replay results row suffix

With the observer on, every replayed journey's Actual cell (`UT-J-<n>` rows of
`regression-replay-results.md`, and therefore of the merged `ui-test-results.md`) ends with
`; side effects: N mutating request(s) (POST /api/runs)` or `; side effects: none observed`,
optionally followed by `; read-only exception applied: POST /api/…` and
`; auth request(s) not counted: POST /api/login`; a FAILed replay reads
`; side effects before the replay stopped: …`; a replay whose observer could not attach reads
`; side effects: NOT observed (…)`. The 8-cell row shape is unchanged.

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
