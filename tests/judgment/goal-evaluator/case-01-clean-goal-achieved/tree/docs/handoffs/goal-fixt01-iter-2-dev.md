# Dev Handoff — goal-fixt01-iter-2

**Status:** complete
**Date:** 2026-07-03T10:41:00Z

## What was implemented
- Fixed `/items/<id>/done` (app.py): the UPDATE statement was missing its WHERE
  clause parameter, so the flag never persisted. The row template now emits
  `class="item done"` and the badge span when `done=1`.
- Added the "Open only" toggle (templates/index.html, static/app.js): when active,
  rows with the `done` class get `display: none`.

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
`pytest -q` → 11 passed, 0 failed.

## Notes
No new dependencies. No config or schema changes.
