# Skill: Plain Language

How to write the prose a product owner reads. This is the shared writing standard
for owner-facing sections (plain-words blocks, stories, narrations, README text,
recommendations). It does not change any machine-parsed format.

## Who you are writing for

- The product owner. Not a developer.
- Not a native English reader. Dense English costs them real effort.
- They have two questions: "is my product OK?" and "what should I do next?"
- They do not know the pipeline's internal names, and they should not need to.

## Hard rules

1. **Short sentences.** One idea per sentence. Prefer under ~20 words. Split long
   sentences instead of chaining clauses with dashes and parentheses.
2. **Everyday words.** "stopped" not "halted"; "broken" not "regressed" (say
   "worked before, broken now"); "check" not "audit" — unless the code word itself
   is the subject, then explain it once.
3. **No bare internal names in plain sections.** No agent names, no file paths, no
   environment variables, no ticket codes (REL-14, EVO-1, §16). If one must
   appear, say in words what it is: "the roadmap's staging list (§16), which a
   human reviews".
4. **Every ID carries its friendly name.** Write `J-04 "Sign in with email"`,
   never a bare ID list. Same for UT-nn tests: say what the test checks.
5. **Describe what the user sees, not the code.** "The login page rejects a
   correct password", not a function, class, endpoint, or stack trace.
6. **End with an action.** Say what happens next, or what the owner should do,
   in one sentence a non-programmer could act on.
7. **Concrete beats generic:** name the screen and the value the user sees, not
   "improvements were made".

## Status words (single source)

The canonical plain sentences for every session status and evaluator verdict live
in `scripts/automation/lib/plain-language.sh`, and the owner-facing glossary is
`docs/READING-REPORTS.md`. Reuse those words; do not invent new translations.
Quick table for the most common codes:

| Code | Plain words |
|---|---|
| CONTINUE | normal progress — the chain builds the next piece by itself |
| ESCALATE | something tricky came up; the next round is slower and more careful |
| REGRESSION | something that worked before is broken now |
| STALLED | the chain cannot make progress alone and is asking for help |
| GOAL_ACHIEVED | every must-have journey works; the session finishes |
| passing / failing / regressed | working / broken / worked before, broken now |

## Three examples

- Bad: "Added POST /api/v1/items endpoint with SQLAlchemy persistence."
  Good: "You can now create new items, and they are saved."
- Bad: "J-02, J-05 remain failing; BQA lane SKIPPED-INFRA."
  Good: "Two journeys are not working yet: J-02 \"Mark an item done\" and J-05
  \"Filter the list\". The browser test could not run this round, so J-05 was
  not re-checked."
- Bad: "Iter-4 verdict demoted per gate; see eval.md."
  Good: "A safety rule overrode the evaluator's claim this round — the stricter
  answer wins. The evaluation file explains which rule fired."

## Never simplify these

Machine-parsed surfaces must stay byte-identical. Plain language is added NEXT TO
them, never instead of them:

- Verdict lines (the bold `Verdict:` marker lines scripts grep) and their
  ALL-CAPS values.
- Required section headings (H2 names like `In plain words`), the three
  `What you can do now / What changed this time / What's next` labels, and any
  field label a template marks as required.
- JSON files, keys, and schemas; artifact file names and paths; exit codes.
- Evidence references: keep exact file paths and screenshot names in evidence
  fields — precision there is the point.
