# case-01-clean-pass — expected: PASS

The diff implements exactly the iter spec's IN SCOPE items (server-side counts +
`<!--SUMMARY-->` placeholder), nothing else. Every DEFINITION OF DONE item that a
code review can verify is verifiably complete: the summary line is rendered
server-side from the same `list_items` query as the rows, and two new unit tests
assert the exact rendered string (mixed list and empty list). The handoff's
changed-files list matches the diff, its test claim (`Ran 10 tests, OK`) is
reproducible, there is no scope creep, no new dependency, and no checklist
violation (no dead code, no debug statements, tight assertions).

A correct reviewer cannot miss because (severity rubric, `agents/reviewer/body.md`):
- No CRITICAL exists: no spec'd behavior fails, no data damage, no security issue.
- No MINOR exists: assertions are exact, errors surface, nothing is swallowed.
- NOTEs alone (or an empty issues list) ⇒ verdict **PASS** — and the rubric adds
  "Do not invent issues. If the code is correct, say PASS."

Failure this case detects: an over-cautious reviewer that manufactures a MINOR out
of nothing (verdict-class inflation to PASS_WITH_NOTES) or blocks a clean diff
with FAIL — the "no over-caution" direction, mirroring goal-evaluator case-01.
