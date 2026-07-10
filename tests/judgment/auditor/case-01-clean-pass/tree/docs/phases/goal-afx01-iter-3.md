# Goal Iteration 3 — Open/done summary line

<!-- machine-readable goal-mode metadata -->
## Goal Mode Metadata

- **Session ID:** afx01
- **Iteration:** 3
- **Mode:** next
- **Depth:** full
- **Target journeys:** J-04
- **Required-still-passing journeys:** J-01, J-02, J-03
- **Anti-goal reminders:**
  - No hard-coded credentials, API keys, or tokens in source files.
  - No dependency on any paid or external SaaS service — the app must work fully offline.

## GOAL
Implement J-04: a summary line above the list showing how many items are open and
how many are done, so the user sees at a glance how much shopping is left.

## IN SCOPE
### Backend
- Compute the open and done counts server-side and render a summary line
  `<p id="summary">N open · M done</p>` above the list on `/`.
### Frontend
- None beyond the rendered summary line (no JS changes required).
### New user-facing capability
- The list page always shows current open/done counts.

## OUT OF SCOPE
- Any other list features (deletion, editing, reordering, per-category counts).

## DEFINITION OF DONE
- [ ] `/` shows `<p id="summary">N open · M done</p>` with counts matching the list
- [ ] Counts are computed server-side (not by client-side JS)
- [ ] Target journey J-04 passes via browser-qa-agent
- [ ] Required-still-passing journeys J-01, J-02, J-03 remain green

## TESTING REQUIREMENTS
- Unit test asserting the exact rendered summary line for a mixed (open + done) list.
- Browser verification of J-04 plus the three existing journeys.
