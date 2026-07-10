# case-02-documented-gap-not-fail — expected: PASS_WITH_GAPS

The spec'd import capability is fully implemented and works: server-side parse,
all-or-nothing insert, HTTP 400 identifying the failing line, tight tests (13,
green), QA green with evidence. But real, user-observable, GAP-class limitations
exist and are honestly documented in the handoff's "Known limitations" section
(and carried into the QA report's notes):

1. The 400 error names the failing line NUMBER but never echoes the offending
   text (`app.py:74`) — a long paste means counting lines by hand.
2. No upper bound on qty on import (`app.py:79` checks `>= 1` only, matching the
   add form) — `Rice x 999999999` imports an absurd-but-harmless row.

A third is discoverable by tracing: a successful import redirects to `/` with no
"imported N items" feedback — the user counts rows to know what happened. The
spec required none of the three.

A correct auditor cannot miss because (severity decision tree + verdict contract,
`agents/auditor/body.md`):

- Not FAIL: FAIL requires CRITICAL issues remaining. Nothing here matches the
  tree's first two levels — no spec'd behavior fails in a realistic scenario, no
  data damage or partial flow (the tie question "does a spec'd behavior fail or
  data get damaged?" answers No on every finding). Both documented items match
  level 3 verbatim — "a real limitation the spec didn't require solving, worth
  writing down"; the tree's own GAP example IS "error message is accurate but
  terse". The contract adds: "Do NOT mark FAIL for OBSERVATION-level issues" and
  "Do NOT fix GAP or OBSERVATION-level issues" (fixing them is scope creep).
- Not plain PASS: PASS means "Phase goal FULLY achieved" with no gaps worth
  recording — but the auditor's own findings section must carry these GAPs (the
  handoff already names two of them), and the PASS_WITH_GAPS definition matches
  this state word for word: "Phase goal achieved. Known limitations exist but
  are acceptable. Gaps are documented."

Failures this case detects, in both directions: severity inflation (an auditor
that turns documented GAPs into FAIL burns a full hardening loop — dev + review +
QA rerun — on a healthy phase) and gap-blindness (a rubber-stamp PASS that reads
the handoff's own "Known limitations" section and still certifies "no gaps").
This is the middle-class calibration case, the auditor edition of reviewer
case-02 (PASS_WITH_NOTES).
