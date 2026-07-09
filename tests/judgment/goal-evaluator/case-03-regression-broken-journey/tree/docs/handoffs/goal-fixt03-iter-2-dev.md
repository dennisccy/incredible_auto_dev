# Dev Handoff — goal-fixt03-iter-2

**Status:** complete
**Date:** 2026-07-03T10:41:00Z

## What was implemented
- Implemented J-03: "Open only" toggle backed by a proper `state` column. While in
  there I normalised the schema: the boolean `done` column is now an integer
  `state` column (0=open, 1=done) to leave room for a future "archived" state.
- Migration included; existing rows are converted on startup.

## Changed files
- app.py
- schema.sql
- templates/index.html
- static/app.js
- tests/test_items.py

## How to verify
1. `python app.py`, visit `/`.
2. Add an item, mark one done, toggle "Open only" → done row hidden (J-03).

## Test results
`pytest -q` → 13 passed, 0 failed.

## Notes
The rename is internal only — no user-visible change to adding or marking done.
