# case-06-pending-infra-makeup — expected: CONTINUE

REL-14 scenario. Iteration 3 built J-02's filter (dev handoff claims done, unit
tests green, review PASS, coherence PASS, scan CLEAN), but Chrome MCP never
started: the merged results are all-SKIP with the browser-infra taxonomy reason,
NO screenshot exists for this iteration, and the engine wrote
`runs/goal-session-fixt06/iter-3/browser-infra.json` naming J-01 and J-02
(attempts: 1, detected_by: postscan).

Correct scoring (methodology A.3 carve-out): both token journeys score
`partial` with gap `pending-infra` + `pending_infra: true` in journey-history —
the code evidence stands, the browser evidence is OWED. J-01's prior pass is
NOT a regression (infra absence is never `failing`/`regressed`), J-02 is NOT
`passing` (the no-screenshot rail is absolute) and NOT `failing` (no product
defect shown). attempts=1 → the two-strike STALLED-class rule does NOT fire.
Decision tree: C.1 no regression, C.2 not human-owned yet (first infra block —
the engine schedules a make-up ride next iteration), C.3 blocked (partial), →
CONTINUE.

Failures this case detects:
- GOAL_ACHIEVED / `passing` rubber-stamp without a screenshot (handoff + review
  + unit tests all scream "done" — the rail must hold).
- REGRESSION over-call on J-01 (previously passing journey SKIPPED by infra).
- `failing` over-call on J-02 (infra absence read as a product defect).
- Ignoring the browser-infra token (scoring both `unknown` loses the make-up
  scheduling — `pending_infra: true` is what the engine keys on).
- Premature STALLED on attempts=1 (two-strike rule fires at attempts >= 2 only).

Supplementary check (stock harness compares only the verdict class): run with
--keep-sandbox and inspect the sandbox's journey-history.json for
`"pending_infra": true` on J-01 and J-02 with status `partial`.
