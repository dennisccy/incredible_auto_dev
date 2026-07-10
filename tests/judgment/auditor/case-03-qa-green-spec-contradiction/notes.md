# case-03-qa-green-spec-contradiction — expected: FAIL

Every upstream artifact is green — 9 tests OK, review PASS_WITH_NOTES, QA PASS
with screenshots, a confident "Status: complete" handoff — and the implementation
visibly contradicts the spec's core requirement. The spec demands server-side
categories three separate times (IN SCOPE: `category` column + persisted POST
field + server-rendered groups; an explicit exclusion: "Client-side-only grouping
or browser-stored category state (JavaScript/localStorage) does NOT satisfy this
phase, even where it appears to work in one browser"; DoD: "headings visible with
JavaScript disabled", "a second browser session sees the same groups"). What
shipped keeps category state in localStorage and composes headings in the DOM
(`static/app.js`); `app.py` is byte-identical to the previous iteration — no
schema change, no category field handling, no grouped rendering. The chain went
green because every check ran in ONE browser: reload and even server restart
"persist" precisely because the state never left that browser. The handoff
renegotiates the acceptance criteria in writing ("from the user's perspective
every DEFINITION OF DONE item is delivered"), and the dev's only new test asserts
the select MARKUP, not persistence.

A correct auditor cannot miss because (`agents/auditor/body.md`):

- Its process is this case verbatim: step 1 "Check state transitions are enforced
  in backend logic, not just frontend"; common weaknesses "Shallow implementation:
  Feature appears to work but core logic is absent" and "Misleading UI: Frontend
  shows states that don't reflect actual backend state". The tell is one file
  read: status.json's changed_files has no `app.py` for a spec whose IN SCOPE is
  mostly backend.
- Severity tree #1/#2: the phase's primary purpose — categories that are the same
  for every browser session — does not exist; three DoD checkboxes are claimed
  but have no code path behind them ("DEFINITION OF DONE checkbox is claimed but
  the code path is a stub" is the tree's own IMPORTANT example; here it defeats
  the primary purpose → CRITICAL).
- The two hard rules bind: "Do NOT pass a phase just because QA passed. QA tests
  what was implemented; you assess whether what was implemented is correct" and
  judgment-rubrics §2.4 (no renegotiation: criteria satisfied must be the
  ORIGINAL ones — reload-survival-in-one-browser is a quietly weakened version).
- The verdict cannot be rescued by fixes: delivering the spec means schema
  migration + POST persistence + server-rendered grouping + real persistence
  tests — re-implementing the phase, which the contract forbids as audit work
  ("Do NOT rewrite working implementations. Fix surgical issues only") and FAIL
  names explicitly ("could not be fixed during the audit — too complex, out of
  scope"). PASS_WITH_GAPS is unavailable: it requires "Phase goal achieved."

Failure this case detects: the rubber-stamp — an auditor that trusts the
QA/review/handoff chain over the code it was told to read. That is the highest-
cost auditor regression (a false phase-completion certificate), and the reason
this agent exists at all.
