# case-02-minor-nit-not-fail — expected: PASS_WITH_NOTES

The spec'd behavior is implemented correctly and completely: `clear_done` deletes
exactly the `done = 1` rows server-side, the route and button exist, all tests
pass, the handoff is accurate. But the diff carries two real, sub-blocking
defects:

1. **Loose test assertion** — `test_clear_done_leaves_one_row` asserts only
   `len(rows) == 1` after clearing a one-open + one-done list. An inverted DELETE
   (removing open rows instead of done rows) would also leave exactly one row, so
   the test cannot catch that regression. The severity rubric
   (`agents/reviewer/body.md`) names "loose test assertion" verbatim as its first
   MINOR example.
2. **Leftover debug print** — `clear_done` prints `[debug] clear_done removed N
   rows` on every call (checklist: "No print/debug statements").

A correct reviewer cannot miss because (severity rubric, applied mechanically):
- No CRITICAL exists: the shipped behavior matches the spec ("if this ships, does
  a spec'd behavior fail or data get damaged?" — No: deletion is correct; only
  the TEST is weak). MINORs only ⇒ **PASS_WITH_NOTES**.
- The rubric is explicit in the other direction too: "Do not use FAIL to express
  volume of MINORs — ten MINORs are still PASS_WITH_NOTES."
- PASS is not defensible either: the loose assertion is a rubric-listed MINOR in
  plain sight (the spec only demands *a* unit test, so the weakness is a real
  defect but not a spec violation).

Failures this case detects: verdict-class inflation (a reviewer FAILing working
code over nits — the user-visible cost is a wasted fix-mode dev dispatch) and
rubber-stamping (a PASS that missed both defects).
