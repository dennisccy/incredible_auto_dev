# goal-afx01-iter-3 Execution Plan

## What to Build
- Server-side open/done summary line on `/`: `<p id="summary">N open · M done</p>`,
  computed from the same items query the rows render from.

## Agents Required
- developer: yes -- add the count computation to `render_index`, a `<!--SUMMARY-->`
  placeholder in the template, and exact-string unit tests for mixed and empty lists.

## Frontend Present
yes

## Files to Create/Modify
- `app.py` -- compute counts in `render_index`, inject the summary line
- `templates/index.html` -- `<!--SUMMARY-->` placeholder between add form and filter toggle
- `test_items.py` -- exact-string summary assertions (mixed list, empty list)

## UI Evolution (required if Frontend Present: yes)
- New user-facing capability: at-a-glance open/done counts on the list page
- New information displayed: `N open · M done` line above the list
- New user actions: none (read-only line)
- UI surface changes: one summary line on the existing `/` page
- Navigation changes: none

## Visual Requirements (required if Frontend Present: yes)
- Component patterns: plain paragraph element, matching the app's minimal system-ui styling
- Layout: unchanged single-column page
- Key visual effects: none
- States to handle: empty list renders `0 open · 0 done` (the line is never hidden)

## Key Test Scenarios
- Mixed list (one open, one done) renders `<p id="summary">1 open · 1 done</p>` exactly.
- Empty list renders `<p id="summary">0 open · 0 done</p>` (line present, zeros shown).
- Marking an item done updates the counts after the redirect (J-04 browser check).
