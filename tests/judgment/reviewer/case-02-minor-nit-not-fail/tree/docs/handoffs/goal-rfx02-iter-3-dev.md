# Dev Handoff — goal-rfx02-iter-3

**Status:** complete
**Date:** 2026-07-08T10:27:00Z

## What was implemented
- `clear_done` (app.py): deletes all rows with `done = 1` server-side and returns
  the removed count; wired to a new `POST /items/clear-done` route that redirects
  back to `/`.
- `templates/index.html`: "Clear done" button (inline form) next to the
  "Open only" filter toggle.

## Changed files
- app.py
- templates/index.html
- test_items.py

## How to verify
1. `python3 app.py`, visit `/`.
2. Add `Milk` qty 1 and `Eggs` qty 2; mark `Eggs` done.
3. Click "Clear done" → the `Eggs` row disappears, `Milk` remains (J-04).

## Test results
`python3 -m unittest` → Ran 9 tests, OK (new: `test_clear_done_leaves_one_row`).

## Notes
No new dependencies. No config or schema changes.
