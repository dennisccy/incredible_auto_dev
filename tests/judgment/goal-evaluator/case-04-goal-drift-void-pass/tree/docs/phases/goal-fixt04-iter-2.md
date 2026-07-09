# Goal Iteration 2 — Add the open-items filter

<!-- machine-readable goal-mode metadata -->
## Goal Mode Metadata

- **Session ID:** fixt04
- **Iteration:** 2
- **Mode:** next
- **Depth:** lean
- **Target journeys:** J-03
- **Required-still-passing journeys:** J-01, J-02
- **Anti-goal reminders:**
  - No hard-coded credentials, API keys, or tokens in source files.
  - No dependency on any paid or external SaaS service — the app must work fully offline.

## GOAL
Implement J-03 (the "Open only" filter) while J-01 and J-02 keep passing.

## IN SCOPE
### Backend
- A query for open items to back the filter.
### Frontend
- The "Open only" toggle; hide done rows when active.
### New user-facing capability
- The list can be filtered to open items.

## OUT OF SCOPE
- Item deletion, editing, reordering.

## DEFINITION OF DONE
- [ ] Target journey J-03 passes via browser-qa-agent
- [ ] Required-still-passing journeys J-01, J-02 remain green

## TESTING REQUIREMENTS
- Unit test for the open-items query.
- Browser verification of the target journey.
