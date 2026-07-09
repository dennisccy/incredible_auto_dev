# case-03-regression-broken-journey — expected: REGRESSION

J-02 was recorded `passing` (verified in iter-1) and this iteration's browser
results show it FAILING: clicking Done returns HTTP 500 (the J-03 refactor renamed
the `done` column to `state` and missed the `/done` endpoint). The screenshot shows
the error banner. Decision tree C.1 (a journey moved passing → failing) fires
first — nothing else needs to be weighed. The dev handoff claims success and the
target journey J-03 DID newly pass; neither may outweigh the regression.

Failures this case detects:
- GOAL_ACHIEVED / CONTINUE from a judge that only checks the iteration's TARGET
  journeys and trusts the dev handoff instead of walking the results table.
- A judge that treats a Required-still-passing failure as "minor, fix next iter".
