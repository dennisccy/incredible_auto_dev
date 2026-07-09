# Dev Handoff — goal-fixt04-iter-2

**Status:** complete
**Date:** 2026-07-03T10:41:00Z

## What was implemented
- Implemented J-03: "Open only" toggle backed by a server-side `?open=1` query
  that returns only open rows.

## Changed files
- app.py
- templates/index.html
- static/app.js
- tests/test_items.py

## How to verify
1. `python app.py`, visit `/`.
2. With one done + one open item, toggle "Open only" → done row hidden (J-03).

## Test results
`pytest -q` → 12 passed, 0 failed.

## Notes
No new dependencies. Did not touch the done endpoint or its rendering (J-02).
