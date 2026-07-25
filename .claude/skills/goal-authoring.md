# Skill: goal-authoring — interviewing for, playing back, and checking `docs/goal.md`

Used by `/goal-init` (interview → author) and, once it ships, by `/goal-lint` (checklist
reuse). `docs/goal.md` is the product constitution: the goal-evaluator treats its
Must-have journeys as objective ground truth and its Anti-goals as veto rules, so its
quality decides every downstream iteration. Vague journeys are the documented #1
failure mode (`.claude/anti-patterns/01-vague-acceptance-criteria.md`, `18-goal-journeys-anti-goals.md`).

## Interview ground rules

- ONE topic at a time — never a wall of questions. Follow the section order below
  (it is the order of `templates/project-goal.md`).
- Offer 2-4 multiple-choice options where sensible (marked ⊕ below) — picking a letter
  beats facing a blank page. Always accept free-text instead.
- Plain conversation only: assume no special tools, forms, or UI beyond text.
- The user's words win. Suggest sharper phrasings, but never write content the user
  has not confirmed. "Unknown" is acceptable — leave optional sections lean rather
  than inventing detail.
- Push every vague answer one step toward observable: "how would a browser test tell
  this passed?"

## Interview script (template section order)

1. **Vision** — what is the product, for whom, what problem does it solve? Target:
   one paragraph.
2. **Target Users** — who they are and what they need. ⊕ offer archetypes if unsure
   (solo-developer tool, internal team app, consumer web app, data dashboard).
3. **Success Criteria** — measurable outcomes. Reject unmeasurable ones ("popular",
   "fast"): ask for a number, an observable state, or drop the criterion.
4. **Key Capabilities** — prioritized list; split must-have from nice-to-have.
5. **Non-Goals** — explicitly out of scope. ⊕ suggest candidates from what the user
   did NOT mention (auth? payments? mobile? multi-user? persistence?).
6. **Constraints** — technical / business / timeline. ⊕ stack preference, single
   process vs services, offline-capable, no paid services.
7. **Design Direction** — visual style, mood, optional reference. ⊕ minimal-clean /
   professional-dense / playful / cyber-futuristic.
8. **Product Shape** (optional, high-leverage) — navigation sketch plus canonical
   values (metrics/entities that must read the SAME everywhere; each is pinned to one
   source). Explain the payoff in one line — it prevents "the same number differs
   across pages" — and accept "skip" without pushing.
9. **Must-have user journeys** — the core. For EACH journey collect:
   - a unique id `J-NN` (zero-padded, sequential; never reuse or renumber),
   - a short name,
   - numbered steps a browser agent can execute — every step names a concrete URL,
     visible label, or input value,
   - one `Acceptance:` line describing the observable end state.
   Quality bar: steps executable without guessing; the Acceptance line contains no
   vague words ("works well", "fast", "properly", "intuitive", "user-friendly",
   "correctly"); the end state is visible on the page — not "the data is saved" but
   "the new row shows `<the value entered>`". 2-6 journeys is the right starting
   size; each must be independently runnable from a fresh page load.
   Merge advisory (throughput): when two candidate journeys exercise the SAME
   screen/surface and the same risk class (e.g., "add an item" and "edit that
   item's name" on one CRUD page), prefer ONE journey with multiple numbered
   acceptance bullets over two separate journeys — each journey is the unit the
   engine plans, verifies, and iterates on, so needless splits buy extra
   iterations, not extra safety. Keep journeys separate when they cross surfaces,
   differ in risk (payment vs display), or would stop being independently
   runnable from a fresh page load when merged.
10. **Anti-goals** — veto rules the evaluator enforces even when every journey
    passes. Concrete and checkable, never aspirations ("secure" ✗ → "no credentials
    in source files" ✓). ⊕ offer the template's defaults: no hard-coded secrets; no
    auth tokens in `localStorage`; no paid SaaS unless listed in Constraints;
    keyboard-accessible form inputs.

## Playback format (before ANY write)

Present exactly this shape, then ask for explicit confirmation:

    Here is what I understood:
    - Vision: <one line>
    - Target users: <one line>        - Success criteria: <one line>
    - Key capabilities: <one line>    - Non-goals: <one line>
    - Constraints: <one line>         - Design direction: <one line>
    - Product shape: <one line, or "skipped">
    Journeys (one line each):
    - J-01 <name> — <acceptance, one line>
    - J-02 <name> — <acceptance, one line>
    Anti-goals (verbatim, exactly as they will be written):
    - <anti-goal 1>
    - <anti-goal 2>

    Shall I write this to docs/goal.md?

No write happens before an explicit yes. That yes is the user approval required for
editing `docs/goal.md` (ask-first class, `.claude/maintenance-protocol.md` §1).
Corrections → update, re-play only the changed lines, re-confirm.

## Update mode (a real `docs/goal.md` already exists)

- Read the existing file FIRST and summarize each section in one line so the user
  sees the current state before deciding what to change.
- Interview only the sections the user wants changed.
- Playback becomes a diff: for each changed section show old → new; list unchanged
  sections by name only. Confirmation still precedes any write.
- Never edit between `<!-- AUTO:journeys -->` and `<!-- /AUTO:journeys -->` — that
  block is goal-proposer territory (`skills/goal-self-extension.md`). Never reuse or
  renumber an existing `J-NN`; new journeys take the next free id at the existing
  zero-padding width.

## Structural checklist (run after writing; fix and re-check on any failure)

If `scripts/automation/lib/goal_lint.py` exists, run
`python3 scripts/automation/lib/goal_lint.py docs/goal.md` INSTEAD of this list.
Otherwise all five rules must hold — 1-4 mirror `validate_goal_file` in
`scripts/automation/run-goal.sh`, which aborts the engine at startup when one fails:

1. Heading `## Must-have user journeys` present at line start.
2. Heading `## Anti-goals` present at line start.
3. At least one journey bullet matching `^- \*\*J-[0-9]+:`.
4. The Anti-goals section has at least one non-empty bullet containing neither
   "TODO" nor "placeholder".
5. No leftover template placeholders: `grep -n '<' docs/goal.md` and confirm every
   hit is intentional markup (an HTML comment, a code literal), not an unfilled
   `<...>` fill-in copied from the template.

Additionally (template contract, not engine-enforced): every journey has numbered
steps and an `Acceptance:` line — browser-qa and the goal-evaluator parse these.
