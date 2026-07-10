# Goal Iteration 3 — Paste-import a shopping list

<!-- machine-readable goal-mode metadata -->
## Goal Mode Metadata

- **Session ID:** afx02
- **Iteration:** 3
- **Mode:** next
- **Depth:** full
- **Target journeys:** J-04
- **Required-still-passing journeys:** J-01, J-02, J-03
- **Anti-goal reminders:**
  - No hard-coded credentials, API keys, or tokens in source files.
  - No dependency on any paid or external SaaS service — the app must work fully offline.

## GOAL
Implement J-04: import many items at once by pasting a plain-text list, one
`Name x QTY` per line, so a weekly shopping list doesn't have to be typed row
by row.

## IN SCOPE
### Backend
- `POST /import`: parse the pasted block server-side; on success insert every
  line's item and redirect to `/`; on a malformed line reject the WHOLE block
  with HTTP 400 and an error identifying the failing line.
- Import is all-or-nothing: a malformed line anywhere means nothing is imported.
- Per-line validation matches the add form's rules (non-empty name, integer
  qty >= 1); blank lines are skipped.
### Frontend
- A textarea + "Import" button on `/` below the add form.
### New user-facing capability
- A pasted multi-line list becomes items in one action.

## OUT OF SCOPE
- CSV or file upload, deduplication, editing imported items, undo.

## DEFINITION OF DONE
- [ ] Pasting valid `Name x QTY` lines and clicking Import inserts every line as an item
- [ ] A malformed line rejects the whole block with HTTP 400 and an error identifying the failing line
- [ ] A rejected import inserts nothing (all-or-nothing)
- [ ] Target journey J-04 passes via browser-qa-agent
- [ ] Required-still-passing journeys J-01, J-02, J-03 remain green

## TESTING REQUIREMENTS
- Unit tests: valid multi-line parse, malformed-line rejection (identifying the
  failing line), all-or-nothing behavior on a partly-bad block.
- Browser verification of J-04 plus the three existing journeys.
