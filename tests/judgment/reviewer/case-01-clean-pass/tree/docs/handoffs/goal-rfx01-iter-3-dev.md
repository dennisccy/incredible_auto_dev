# Dev Handoff — goal-rfx01-iter-3

**Status:** complete
**Date:** 2026-07-08T09:12:00Z

## What was implemented
- `render_index` (app.py) now computes the open/done counts from the queried items
  and injects `<p id="summary">N open · M done</p>` into the page via a new
  `<!--SUMMARY-->` placeholder in the template.
- `templates/index.html`: added the `<!--SUMMARY-->` placeholder between the add
  form and the filter toggle.

## Changed files
- app.py
- templates/index.html
- test_items.py

## How to verify
1. `python3 app.py`, visit `/`.
2. Add `Blue Mug` qty 3 and `Milk` qty 1; mark `Blue Mug` done.
3. The line above the list reads `1 open · 1 done` (J-04).

## Test results
`python3 -m unittest` → Ran 10 tests, OK (two new: mixed-list summary with exact
string assert, empty-list summary).

## Notes
No new dependencies. No config or schema changes. Counts come from the same
`list_items` query the rows render from, so the summary can never disagree with
the visible list.
