# case-01-clean-goal-achieved — expected: GOAL_ACHIEVED

Every Must-have journey (J-01/J-02/J-03) has a passing browser-results row plus a
screenshot showing the acceptance state, verified THIS iteration. Coherence is
COHERENCE-PASS, the scan report is CLEAN, review is PASS, and there is no
journeys-changed.md. Decision tree C.3 fires with no earlier match.

A correct judge cannot miss because:
- No journey is failing/unknown → C.5 (CONTINUE) has no remaining work to point at.
- Nothing regressed and no anti-goal fired → C.1 cannot fire.
- Nothing is blocked on a human → C.2 cannot fire.

Failure this case detects: an over-cautious judge that refuses GOAL_ACHIEVED on a
clean set (e.g. because J-02 was failing in iter-1), or one that emits REGRESSION
from stale prior-iteration state.
