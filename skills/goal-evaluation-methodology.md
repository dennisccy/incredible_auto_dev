# Goal Evaluation Methodology

Procedural methodology for the goal-evaluator. Follow it in order, every iteration. It turns
"be skeptical" into checkable steps: skepticism here means *every status change is backed by
an artifact you personally opened*, and *the verdict follows the decision tree below* — not
your overall impression of the iteration.

## A. Evidence walk (do this before forming ANY opinion)

1. **Deterministic reports first.** Read, if present in `runs/goal-session-<sid>/iter-<N>/`:
   - `scan-report.md` — deterministic secret/dependency/license scan of the product
     iteration diff (tracked + untracked; harness bookkeeping path-excluded). Findings here
     are facts; you do not need to re-derive them.
   - `iter-diff.md` — the bounded diff (complete file list + stats; hunks may be capped, and
     the header lists exactly what was excluded/truncated).
   - `journeys-changed.md` — goal-edit drift note, present only when a recorded-passing
     journey's `docs/goal.md` text changed since it was verified. Every listed journey's
     prior pass is VOID: it enters your journey table (step 2) as needing re-verification at
     the same evidence bar as a status change — a results row + screenshot against the
     CURRENT text — or it drops to `unknown`. Record the new `spec_hash` only for journeys
     you actually re-verified (body step 3).
   Fallback when absent: run `git diff <snapshot-sha>..HEAD --stat` first, then read only the
   hunks for files that plausibly affect journeys or anti-goals. Never paste a full raw diff
   into your reasoning.
2. **Journey table second.** Build (mentally or on scratch) a three-column table: journey →
   prior status (from the inlined journey digest, or `journey-history.json` if no digest was
   provided) → this-iteration result (from
   `reports/phase-<iter-name>-ui-test-results.md`).
3. **Per-journey evidence walk.** For each journey whose status CHANGED (or is claimed newly
   passing/failing):
   - Open its results row; note the exact test id.
   - Open its screenshot from `reports/qa/<iter-name>-evidence/` and confirm the image shows
     the acceptance state (not just "a page loaded"). The screenshot outranks every prose
     claim, including the dev handoff.
   - Record the citation (results row + screenshot filename). **No citation → the journey's
     status is `unknown`, and you say so.**
   - **Two carve-outs. First (REL-14):** when the journey is listed in this iteration's
     `<iter-dir>/browser-infra.json` (the engine's browser-infra token: services/Chrome
     failed, NOT the product) and there is no fresh screenshot, score it `partial` with the
     gap noted as `pending-infra`, and set `pending_infra: true` on it in journey-history —
     the code evidence stands, the browser evidence is OWED. Never `passing` (the
     no-screenshot rail is absolute), and never `failing`/`regressed` on infra absence
     alone. If the token shows `attempts >= 2` (two consecutive infra-blocked iterations),
     the browser infrastructure itself is the blocker: treat it as a human-owned action
     (STALLED-class, decision tree C.2) instead of scheduling a third silent retry. A fresh
     screenshot this iteration — pass or fail — clears `pending_infra` and scores normally.
   - **Second (maintenance isolation):** when this iteration's
     `ui-test-results.md` is all-SKIPPED and its `**Reason:**` line names maintenance
     isolation, the lane was FORBIDDEN by the iteration's contract, not missing — full
     reviewer/QA/auditor/coherence depth was retained while application-service boot,
     browser QA and the deterministic replay lane were prohibited. So this is neither an
     absent citation nor an infra failure: EVERY journey KEEPS its prior recorded status
     (never `unknown`, `failing` or `regressed` on that basis alone), you do NOT set
     `pending_infra` (nothing is owed by the infrastructure — the contract withheld it),
     and you state in the report that the iteration ran under maintenance isolation and
     which journeys therefore went unverified. It never runs the other way: an isolated
     iteration produced no browser evidence, so no journey may be promoted TO
     `passing`/`already_passing` on it, and a `GOAL_ACHIEVED` verdict on such an iteration
     must cite the earlier iteration whose evidence it rests on (the deterministic results
     gate counts only `FAIL` and `DEFERRED-BUDGET` cells, so an empty isolated table will
     not stop you — that judgment is yours).
4. **Stable-journey spot-check.** Journeys with unchanged `passing`/`already_passing` status
   that are in this iteration's **Required-still-passing set** (and have a stored golden
   script) are re-verified mechanically by the replay lane (`demo_runner.py --mode verify`)
   at BOTH depths — the lean executor and the full pipeline's browser-qa step; a required
   journey without a golden rides the LLM browser-qa lane the same iteration. Their rows
   are already merged into `ui-test-results.md` (the raw `regression-replay-results.md` is
   a lane artifact — the merged file wins where they disagree, and a reconciliation footer
   records any overturned replay FAIL).
   Stable journeys OUTSIDE that set carry over unverified this iteration. Do NOT re-read
   every screenshot: spot-check 2 stable journeys (or all, if fewer than 2 exist),
   preferring ones outside the replay set; if either spot-check contradicts its recorded
   status, widen to a full evidence walk.
   **DEFERRED-BUDGET rows (SPEED-15 trim rung 2):** a merged results row whose verdict cell
   is `DEFERRED-BUDGET` means the wall-clock iteration budget cut that journey's
   re-verification this run — it was NOT tested. The journey KEEPS its prior recorded
   status (never `regressed`, `failing`, or `unknown` on the strength of this row alone);
   note it as deferred in your report. A deferred journey can never support GOAL_ACHIEVED —
   the deterministic achievement gate blocks it mechanically until a later iteration
   re-verifies it.
5. **Pipeline health.** Note the review verdict (`reports/reviews/<iter-name>-review.md`).
   The checkable fail-open signal: the review verdict is FAIL yet browser results exist for
   this iteration — the lean pipeline proceeded past the failing review. That is an
   ESCALATE signal (tree below).
6. **Evidence durability (SPEED-9).** Evidence does not expire with time — it expires with
   CHANGE. When a journey's product code is unchanged since the iteration where its passing
   evidence was captured, that evidence remains valid: the `last_evidence_path` screenshot,
   its results row, AND the prior iteration's walkthrough recording (your dispatch prompt's
   "Prior walkthrough recording" line names the newest one). Check change against
   `iter-diff.md`'s file list vs the journey's surfaces; when the prompt's "Product diff
   this iteration" line says EMPTY, ALL prior evidence is automatically still valid. Do not
   demand a re-capture, and never downgrade a status for evidence age alone.
   Two precedence rails: (a) goal-edit drift ALWAYS wins over durability — a journey listed
   in `journeys-changed.md` needs fresh evidence against the CURRENT goal text no matter how
   unchanged the code is (A.1 rule, unchanged); (b) the no-screenshot rail (A.3) demands a
   screenshot EXISTS with a citation — durability only relaxes WHICH iteration it may come
   from, never whether one is needed.
7. **Capture defect ≠ product failure (SPEED-9).** When the code, tests, and/or replay
   confirm the behavior but the capture ARTIFACT itself is cosmetically defective — the
   screenshot shows a different-but-equally-valid data range than the spec's example
   numbers, the walkthrough recording is missing or badly cropped — score the journey from
   the code/replay/screenshot evidence that does exist, record the gap as `capture-defect`,
   and set `evidence_makeup: true` on the journey in journey-history (same shape and
   clearing rule as `pending_infra`: any fresh capture, pass or fail, clears it). The
   make-up capture rides the next iteration as a passenger task or a `Depth: evidence`
   recommendation — NEVER as a new iteration's goal.
   Distinction: `pending_infra` = the browser infrastructure failed and evidence is OWED;
   `evidence_makeup` = evidence exists and the product works — only the artifact's
   presentation is wrong. Rail: this never applies when the asserted BEHAVIOR is unmet — a
   screenshot showing wrong behavior is a failure, not a capture defect; only presentation
   (range choice, crop, missing recording) can be defective while the behavior is confirmed.

## B. Anti-goal checklist (per category — answer each with yes/no + citation)

Work from `scan-report.md` + `iter-diff.md` (fallback: your own bounded diff). For EACH
anti-goal in `docs/goal.md`, answer explicitly — "none observed" requires you actually looked:

| Category | How to check |
|----------|--------------|
| Secrets/credentials | scan-report findings; plus eyeball new config/env files in the diff file list |
| Paid/external SaaS | scan-report dependency findings; new entries in manifests (package.json, requirements*.txt, pyproject.toml) |
| License changes | scan-report; any LICENSE/license-field diff |
| Fabricated/substituted data | Compare what the spec sanctioned vs what the code actually ingests/serves (provider names, fixture files appearing in prod paths) |
| Goal-specific anti-goals | Read each one's verbatim text; check the diff files it implicates |

Severity: critical = secrets committed, unapproved paid dependency, license violation,
security backdoor, fabricated data presented as real. Everything else is minor. When unsure
whether critical: treat as critical and say you were unsure (fail-closed).

## C. Verdict decision tree (apply top-down; first match wins)

1. Any journey moved `passing`/`already_passing` → `failing`, OR a **critical** anti-goal
   violation is unresolved → **REGRESSION**.
2. Every unblock path for the current blocker is a **human-owned action** (credentials,
   network/IP access, paid service, an irreversible step needing sanction — see
   `.claude/judgment-rubrics.md` §3) → **STALLED** (list each unblock option explicitly in
   the Halt Justification).
3. Every Must-have journey is `passing`/`already_passing`, no unresolved anti-goal
   violations, coherence.md is not `COHERENCE-FAIL` (missing counts as NOT clean, and so does a
   crash-stub — recognizable by the sentence "Coherence auditor produced no output" in the
   file) → **GOAL_ACHIEVED**.
   (The outer loop will independently re-verify this with deterministic gates and a second
   fresh-context confirm; your GOAL_ACHIEVED is the first key, not the final word.)
4. The SAME journey has now failed 2+ consecutive iterations, OR the review lane failed and
   the pipeline proceeded fail-open, OR this lean iteration surfaced cross-cutting
   ambiguity/complexity → **ESCALATE** (next iteration runs the full pipeline).
5. Otherwise → **CONTINUE**. If coherence.md is `COHERENCE-FAIL`, the next-step
   recommendation MUST be a consolidation pass fixing the cited violations verbatim, before
   any new feature work.

## D. Worked examples

**Correct skeptical trace (real: mcp-loop iter-16).** Dev handoff reported the Stooq
ingestion tooling complete and tests green. The evaluator did NOT stop there: the spec's
mandatory live probe artifact showed `Access denied` for every symbol (per-IP export ACL),
zero symbols staged, and the sanctioned fallback branch explicitly taken. Journeys J-01..J-09
were re-verified unchanged via git-diff scope + replay evidence. Every unblock option (allowed
network, `STOOQ_API_KEY`, amending the goal's provider) was a human action, and the next step
(data-basis swap + ledger reset) was explicitly gated on human sanction → **STALLED**, with
the three options listed. The tests being green did not make the verdict CONTINUE; the
*blocker's ownership* decided it.

**Rubber-stamp counterexample (what NOT to do).** Handoff says "J-07 implemented, all 12 unit
tests pass; marking passing." The results file has no row for J-07 (browser lane skipped it)
and there is no screenshot. Wrong: `passing` because the code "clearly works". Right: status
`unknown`, gap noted ("browser lane skipped J-07 — no evidence"), verdict `CONTINUE` with
next-step "re-run browser QA for J-07". Unit tests are never journey evidence (a routing typo
can 404 the page while every unit test passes). *Contrast, and the one case where "no row" is
NOT `unknown`:* if the results file is all-SKIPPED because its `**Reason:**` line names
maintenance isolation, the lane was withheld by contract rather than skipped by accident, and
every journey keeps its prior status (A3, second carve-out). The test is the DECLARED reason,
never the bare absence of a row.

## E. Pre-finalize self-check (all five, in your head, before writing eval.md)

1. **Consistency**: does the verdict I'm about to write follow from the journey-history I
   just wrote via the decision tree? (E.g., any `regressed` status ⇒ verdict must be
   REGRESSION.)
2. **Citations**: does every status CHANGE in my eval.md table carry a results-row or
   screenshot citation the next agent could open?
3. **Anti-goals**: did I answer every category in section B explicitly (no blank "OK" rows I
   didn't actually check)?
4. **Coherence**: is coherence.md's verdict reflected — and vetoing — per the tree?
5. **Honesty**: is anything I couldn't verify marked `unknown` rather than guessed? If a
   screenshot contradicted prose anywhere, did the screenshot win?

If any answer is "no", fix the evaluation — do not ship it with a caveat.
