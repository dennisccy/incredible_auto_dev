## 29. A plan metadata line can silently suppress an entire verification lane

**Applies to:** goal mode; any pipeline step whose execution is gated on a model-written metadata line rather than on the work the spec demands.

**Pattern:** The browser-QA lane ran only when the orchestrator's plan contained `Frontend Present: yes` (`detect_frontend_in_plan`). In ops-hardening iter-8 the spec itself mis-wrote `Frontend Present: no` while its own DoD named browser journeys to verify — so the ENTIRE browser lane (browser-qa, ui artifacts) was skipped, journeys J-01/J-03/J-04 fell to `unknown`, J-05 stayed `regressed` unverified, and the iteration closed CLOSURE-FAIL. Every later iteration worked around it by hand-writing `Frontend Present: yes` into specs whose diffs contained zero frontend files — a standing landmine had anyone written the honest-looking "no".

**Why it fails:** The gate keyed on a MODEL-authored line (twice removed from ground truth) instead of the engine's own knowledge that this iteration names user journeys — which are user-visible by contract and therefore always need browser evidence. One wrong word in generated prose disabled a verification lane with no error, no log line, and downstream artifacts (`N/A stubs`) that look intentional.

**Prevention:** The engine exports its parsed journey list (`CHAIN_GOAL_TARGET_JOURNEYS`, run-goal.sh) and `detect_frontend_in_plan` (lib/common.sh) force-returns frontend-present whenever it is non-empty, logging the override (`forcing browser lane despite plan`). Phase mode is untouched (the variable is only set by run-goal.sh). Rule: a lane that produces required evidence must be gated on engine-parsed facts (journey list, diff contents), never solely on model-written plan prose; when prose and facts disagree, run the lane and log the contradiction.

**Detection:** a goal iteration whose spec/DoD names `J-` journeys but whose reports directory has `N/A` browser stubs; journeys dropping to `unknown` after an iteration that claimed completion.
