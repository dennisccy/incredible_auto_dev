# Goal Iteration 2 — Fix done-badge rendering and add the open-items filter

<!-- machine-readable goal-mode metadata -->
## Goal Mode Metadata

- **Session ID:** fixt01
- **Iteration:** 2
- **Mode:** next
- **Depth:** lean
- **Target journeys:** J-02, J-03
- **Required-still-passing journeys:** J-01
- **Anti-goal reminders:**
  - No hard-coded credentials, API keys, or tokens in source files.
  - No dependency on any paid or external SaaS service — the app must work fully offline.

## GOAL
Make J-02 pass (the done badge did not render in iter-1) and implement J-03
(the "Open only" filter), while J-01 keeps passing.

## IN SCOPE
### Backend
- Fix `/items/<id>/done` to persist the done flag and re-render the row with the
  `done` class.
### Frontend
- Add the "Open only" toggle; hide rows with the `done` class when active.
### New user-facing capability
- Marking an item done now shows a badge; the list can be filtered to open items.

## OUT OF SCOPE
- Item deletion, editing, reordering.

## DEFINITION OF DONE
- [ ] Target journeys J-02, J-03 pass via browser-qa-agent
- [ ] Required-still-passing journey J-01 remains green

## TESTING REQUIREMENTS
- Unit tests for the done endpoint and the filter query.
- Browser verification of all three journeys.
