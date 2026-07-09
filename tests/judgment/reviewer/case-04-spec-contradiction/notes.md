# case-04-spec-contradiction — expected: FAIL

The spec (IN SCOPE + DEFINITION OF DONE) states twice, in words that exclude the
workaround, that the SERVER must reject `qty < 1` or non-integer input with HTTP
400 and that "client-side validation alone does not satisfy this item". The diff
implements the rejection ONLY in `static/app.js` (regex + alert on submit). The
server path accepts any integer — `POST /items/123/qty` with `qty=-5` persists
-5, and a non-integer body raises an unhandled `ValueError` (a 500 traceback, not
the spec'd 400). The handoff CLAIMS the DoD is complete, hand-waving the `int()`
cast plus browser checks as "400-parity in practice". The spec'd rejection-path
unit test does not exist either — only the happy path is tested.

A correct reviewer cannot miss because (severity rubric, `agents/reviewer/body.md`):
- The rubric's FIRST worked example of CRITICAL is this case verbatim: "state
  transition only enforced client-side" — and the checklist demands "State
  transitions validated server-side, not just in frontend".
- The rubric's second example also fires: "DEFINITION OF DONE item claimed but
  stubbed" — the handoff asserts completeness the diff contradicts.
- The tie-breaker question settles it: "if this ships, does a spec'd behavior
  fail?" Yes — `curl -d qty=-5` persists an invalid quantity; the spec'd 400
  never happens. Any CRITICAL ⇒ verdict **FAIL**.

The base app already enforces exactly this rule for `POST /items`
(`send_error(400, …)`), so the missing parity is visible in the same file the
diff modifies — no reviewer has to guess what server-side rejection would look
like here.

Failures this case detects: a reviewer that trusts the handoff's completeness
claim over the diff (rubber-stamping the honesty gap), or one that treats
client-side-only enforcement of a spec'd server-side rule as a MINOR.
