## 38. A verdict qualified with a caveat reports a contradicted acceptance clause as a pass

**Applies to:** any results row whose verdict gates the Definition of Done — the browser lane's journey rows (`UT-J-NN`) above all — and any parser that accepts an annotated verdict cell (`PASS (with caveat)`) as the bare token.

**Pattern:** goal-taketwo iter 19 (2026-09-25). J-01's Acceptance requires Take 1's Processing summary to list six stages "each `Done` … and none `Reused from cache`". Before running J-01, the browser lane executed the iteration's UI test plan, whose Setup B imported `cold-ingest.mp4` three times. `docs/goal.md` reserves that fixture for J-01 only ("so every J-01 attempt ingests cold"). The setup warmed the evidence cache, J-01's Take 1 read `Reused from cache`, and the agent wrote the journey row as `PASS (with disclosed test-contamination caveat, not a product defect)` with the headline `Browser QA Verdict: PASS`. The caveat was honest and fully disclosed. But the parser deliberately reads `PASS (…)` as PASS (anti-pattern 28's tolerance), so the fresh-evidence contract and the QA-lane gate (anti-pattern 36) both saw a passing target. Only the maintainer session caught it, by reading the row against the goal text.

**Why it fails:** a caveat moves a judgement ("the failure does not count") from the evaluator to the executing agent, which is the party least placed to make it (anti-pattern 25). A verdict cell that carries conditions is not a verdict. Tolerant parsing is right for formatting drift (`**PASS**`), but wrong for words that change the meaning. The root cause here was upstream of the lane: a test plan that used a journey-reserved fixture as setup data can never produce clean evidence for that journey in the same run.

**Prevention:**
- The browser-qa-agent writes a Verdict cell as exactly `PASS`, `FAIL` or `SKIP`. Causes go in Actual. An observation that contradicts any acceptance clause is `FAIL` whatever the cause.
- `qa_lane_gate.py` blocks a journey row whose verdict cell carries words after the token (`verdict_qualifier()`: letters or digits after the token; emphasis and symbols alone stay bare). Non-journey rows keep the tolerant reading, because their priorities already decide blocking.
- The manual-ui-test-plan-generator skill forbids using a journey-reserved fixture as setup input for any other test case.
- Regression: `qa_lane_gate.py self-test` (T–W) and `tests/automation/test-qa-lane-gate.sh` case H, which reproduces the iter-19 row. The unpatched gate passes it with exit 0; the patched gate blocks it with exit 3.

**Detection:** a journey row whose Verdict cell reads `PASS (…)`, `PASS — …` or `PASS: …`; an Actual cell that quotes an acceptance clause as "contradicted" beside a PASS; a test plan whose Preconditions name a fixture that the goal reserves for a different journey.
