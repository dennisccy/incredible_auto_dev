## 18. Goal mode without Must-have journeys or Anti-goals

**Pattern:** A user authors `docs/goal.md` from the template but skips or leaves placeholder content in the **Must-have user journeys** and **Anti-goals** sections, then runs `./scripts/automation/run-goal.sh`. The goal-decomposer produces vague iter specs and the goal-evaluator has no concrete evidence to anchor its `GOAL_ACHIEVED` decision.

**Why it fails:** Goal mode uses an AI evaluator to decide when the loop terminates. Without specific journeys, the evaluator falls back on subjective judgment — best case it loops forever (related to anti-pattern #1), worst case it declares done prematurely on something that doesn't actually work for users. Anti-goals serve as veto criteria; without them the evaluator may rubber-stamp a violation (committed credentials, paid-SaaS dependency, accessibility regression) just because the journeys click through.

**Prevention:**
- `run-goal.sh` validates `docs/goal.md` on first run: it MUST contain a non-empty Must-have user journeys section with at least one journey, and a non-empty Anti-goals section. The script aborts with a clear error message if either is empty or contains only the template placeholders.
- Each journey in goal.md MUST have an ID (`J-NN`), numbered click/type/assert steps the browser-qa-agent can execute, and an "Acceptance" line describing the observable end state. The goal-evaluator references these by ID, so missing IDs break the journey-history tracking.
- Anti-goals MUST be concrete, checkable rules (e.g., "no hard-coded credentials in source files"), not aspirations ("be secure"). Concrete rules let the evaluator classify violations as critical (halts loop) vs minor (continues with fix recommendation).

**Example (bad):**
```
## Must-have user journeys
- TODO: fill in later

## Anti-goals
- Be secure.
- Be fast.
```

**Example (good):**
```
## Must-have user journeys
- **J-01: Sign up and log in**
  - Steps: 1. visit /signup  2. enter email+password  3. submit  4. expect /dashboard  5. log out  6. log in again  7. expect /dashboard
  - Acceptance: dashboard greeting shows the user's email

## Anti-goals
- No hard-coded credentials, API keys, or tokens in source.
- Auth tokens MUST NOT be stored in localStorage (httpOnly cookies only).
- No dependency on a paid SaaS service unless explicitly listed in Constraints.
```

---

