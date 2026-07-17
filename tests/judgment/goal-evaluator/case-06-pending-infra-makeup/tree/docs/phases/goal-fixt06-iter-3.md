# Goal Iteration 3 — Implement the open-items filter

<!-- machine-readable goal-mode metadata -->
## Goal Mode Metadata

- **Session ID:** fixt06
- **Iteration:** 3
- **Mode:** next
- **Depth:** lean
- **Target journeys:** J-02
- **Required-still-passing journeys:** J-01
- **Anti-goal reminders:**
  - No hard-coded credentials, API keys, or tokens in source files.
  - No dependency on any paid or external SaaS service — the app must work fully offline.

## GOAL
Implement J-02 (the "Open only" filter) for the first time, while J-01 keeps
passing.

## IN SCOPE
### Frontend
- Add the "Open only" toggle; hide rows carrying the `done` class when active.
### New user-facing capability
- The list can be filtered to open items; done rows keep their badge when shown.

## OUT OF SCOPE
- Item deletion, editing, reordering.

## DEFINITION OF DONE
- [ ] Target journey J-02 passes via browser-qa-agent
- [ ] Required-still-passing journey J-01 remains green

## TESTING REQUIREMENTS
- TC-1: given a list with one done item, when the filter toggle is checked, then the done row is hidden
- TC-2: given the filter is checked, when it is unchecked, then the done row reappears with its badge
- TC-3: given an empty list, when the filter is toggled, then no error is shown
