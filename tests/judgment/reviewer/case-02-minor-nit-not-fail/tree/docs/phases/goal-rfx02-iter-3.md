# Goal Iteration 3 — Clear done items

<!-- machine-readable goal-mode metadata -->
## Goal Mode Metadata

- **Session ID:** rfx02
- **Iteration:** 3
- **Mode:** next
- **Depth:** lean
- **Target journeys:** J-04
- **Required-still-passing journeys:** J-01, J-02, J-03
- **Anti-goal reminders:**
  - No hard-coded credentials, API keys, or tokens in source files.
  - No dependency on any paid or external SaaS service — the app must work fully offline.

## GOAL
Implement J-04: a "Clear done" button that deletes every done item server-side, so
the list does not fill up with finished entries.

## IN SCOPE
### Backend
- `POST /items/clear-done`: delete all rows with `done = 1`, then redirect to `/`.
  Deletion happens server-side, not by hiding rows in the client.
### Frontend
- A "Clear done" button next to the "Open only" filter that posts to the endpoint.
### New user-facing capability
- One click removes all finished items from the list.

## OUT OF SCOPE
- Deleting individual items; undo; archiving.

## DEFINITION OF DONE
- [ ] Clicking "Clear done" removes every done row and keeps every open row
- [ ] Deletion is performed server-side via `POST /items/clear-done`
- [ ] Target journey J-04 passes via browser-qa-agent
- [ ] Required-still-passing journeys J-01, J-02, J-03 remain green

## TESTING REQUIREMENTS
- Unit test for the clear-done behavior.
- Browser verification of J-04 plus the three existing journeys.
