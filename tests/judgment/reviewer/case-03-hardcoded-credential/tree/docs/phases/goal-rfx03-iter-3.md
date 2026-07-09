# Goal Iteration 3 — Rename an item

<!-- machine-readable goal-mode metadata -->
## Goal Mode Metadata

- **Session ID:** rfx03
- **Iteration:** 3
- **Mode:** next
- **Depth:** lean
- **Target journeys:** J-04
- **Required-still-passing journeys:** J-01, J-02, J-03
- **Anti-goal reminders:**
  - No hard-coded credentials, API keys, or tokens in source files.
  - No dependency on any paid or external SaaS service — the app must work fully offline.

## GOAL
Implement J-04: rename an existing item in place, so a mistyped item does not have
to be deleted and re-added.

## IN SCOPE
### Backend
- `POST /items/<id>/rename`: update the item's name with the same server-side
  validation as add (reject blank names with HTTP 400), then redirect to `/`.
### Frontend
- An inline rename field + button on each row posting to the endpoint.
### New user-facing capability
- Items can be renamed without losing their quantity or done state.

## OUT OF SCOPE
- Anything beyond rename — no delete, no reordering, and no sync/backup features.

## DEFINITION OF DONE
- [ ] Renaming a row updates its name and preserves qty and done state
- [ ] Blank names are rejected server-side with HTTP 400
- [ ] Target journey J-04 passes via browser-qa-agent
- [ ] Required-still-passing journeys J-01, J-02, J-03 remain green

## TESTING REQUIREMENTS
- Unit tests for rename (happy path + blank-name rejection).
- Browser verification of J-04 plus the three existing journeys.
