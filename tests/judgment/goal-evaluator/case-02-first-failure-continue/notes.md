# case-02-first-failure-continue — expected: CONTINUE

J-02 is newly passing (results row + screenshot), J-01 re-verified passing, but
J-03 FAILED on its FIRST-ever attempt (prior status: unknown) — the screenshot
shows a done item still visible with the filter on. Review PASS, coherence PASS,
scan CLEAN. Decision tree: C.1 cannot fire (J-03 was never passing, nothing
regressed, no anti-goal), C.2 cannot fire (the fix is ordinary in-repo work),
C.3 cannot fire (J-03 failing), C.4 cannot fire (first failure — not 2+
consecutive; no fail-open; no cross-cutting ambiguity) → C.5: CONTINUE.

Failures this case detects:
- GOAL_ACHIEVED rubber-stamp (dev handoff claims all three journeys done).
- REGRESSION over-call on a first-time failure of a never-passing journey.
