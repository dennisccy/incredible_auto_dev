# Goal Iteration 3 — Change an item's quantity

<!-- machine-readable goal-mode metadata -->
## Goal Mode Metadata

- **Session ID:** rfx04
- **Iteration:** 3
- **Mode:** next
- **Depth:** lean
- **Target journeys:** J-04
- **Required-still-passing journeys:** J-01, J-02, J-03
- **Anti-goal reminders:**
  - No hard-coded credentials, API keys, or tokens in source files.
  - No dependency on any paid or external SaaS service — the app must work fully offline.

## GOAL
Implement J-04: change an item's quantity in place, with the same server-side
input discipline the add form already has.

## IN SCOPE
### Backend
- `POST /items/<id>/qty`: update the item's quantity, then redirect to `/`.
- The SERVER must reject `qty < 1` or non-integer input with HTTP 400 — exactly
  the parity rule `POST /items` already enforces. Client-side checks alone do
  NOT satisfy this requirement.
### Frontend
- A quantity field + "Update" button on each row posting to the endpoint.
### New user-facing capability
- Quantities can be corrected without deleting and re-adding the item.

## OUT OF SCOPE
- Renaming, deleting, reordering items.

## DEFINITION OF DONE
- [ ] Updating a row's quantity persists and renders the new value
- [ ] The server rejects `qty < 1` or non-integer input with HTTP 400
      (client-side validation alone does not satisfy this item)
- [ ] Target journey J-04 passes via browser-qa-agent
- [ ] Required-still-passing journeys J-01, J-02, J-03 remain green

## TESTING REQUIREMENTS
- Unit tests covering the quantity update AND the server-side rejection path.
- Browser verification of J-04 plus the three existing journeys.
