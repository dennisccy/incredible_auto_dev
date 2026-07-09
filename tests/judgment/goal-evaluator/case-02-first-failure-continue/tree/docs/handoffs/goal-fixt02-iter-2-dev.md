# Dev Handoff — goal-fixt02-iter-2

**Status:** complete
**Date:** 2026-07-03T10:41:00Z

## What was implemented
- Implemented J-02: `/items/<id>/done` persists the flag and the row re-renders
  with the `done` badge and strikethrough.
- Implemented J-03: added the "Open only" toggle that hides done rows.
- With this, all three journeys are implemented and the product goal should be met.

## Changed files
- app.py
- templates/index.html
- static/app.js
- tests/test_items.py

## How to verify
1. `python app.py`, visit `/`.
2. Add `Blue Mug` qty 3 → row appears (J-01).
3. Click Done on the row → strikethrough + `done` badge (J-02).
4. Toggle "Open only" with one done + one open item → done row hidden (J-03).

## Test results
`pytest -q` → 12 passed, 0 failed.

## Notes
No new dependencies. No config or schema changes.
