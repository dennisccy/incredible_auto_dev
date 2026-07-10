# case-01-clean-pass — expected: PASS

A genuinely complete full-depth iteration with honest artifacts end to end. The
diff delivers exactly the spec's IN SCOPE (server-side counts + `<!--SUMMARY-->`
placeholder); every DEFINITION OF DONE item traces to real code — the counts are
computed in `render_index` from the same `list_items` query the rows render from,
so the summary can never disagree with the visible list — and the two new unit
tests assert the exact rendered string for the mixed and empty lists. Handoff,
plan, review, test plan, QA report, status.json and evidence screenshots all tell
one story that survives cross-checking.

A correct auditor cannot miss because (severity decision tree, `agents/auditor/body.md`):

- Nothing matches CRITICAL or IMPORTANT: no spec'd behavior fails in any realistic
  scenario, no data damage, no secrets, no stubs, no escape hatches — each DoD
  checkbox is backed by a tight, exact-value test.
- Nothing rises to GAP either: the obvious inventions ("no per-category counts",
  "no deletion/editing") are answered by the spec's OUT OF SCOPE line — spec'd-out,
  not limitations worth writing down. What remains is OBSERVATION-class at most,
  and the contract is explicit both ways: "Do NOT mark FAIL for OBSERVATION-level
  issues", and PASS means "Phase goal fully achieved. No critical or important
  gaps remain."
- The evidence floor cuts off invented findings: every audit finding "must
  reference a specific file and line number", and there is no artifact
  contradiction anywhere to cite.

Failure this case detects: an over-cautious auditor that manufactures gaps to look
skeptical — verdict-class deflation to PASS_WITH_GAPS, or FAIL on observations
(each deflation costs a wasted hardening loop: dev + review + QA re-run). This is
the no-over-caution direction, mirroring goal-evaluator case-01 and reviewer
case-01: an auditor that cannot certify a genuinely clean phase blocks every
pipeline it guards.
