# goal-afx03-iter-3 Execution Plan

## What to Build
- Persistent item categories: `category` column on `items` (default `Other`),
  accepted by `POST /items`, and a server-side grouped rendering of `/` with one
  heading per non-empty category (Grocery, Hardware, Other order).
- Category `<select>` on the add form.

## Agents Required
- developer: yes -- schema default + column, POST field handling with fallback to
  `Other`, grouped `render_index`, template select, unit tests for persistence,
  grouping order and the fallback.

## Frontend Present
yes

## Files to Create/Modify
- `app.py` -- schema, `add_item(category)`, grouped `render_index`
- `templates/index.html` -- category select on the add form
- `test_items.py` -- persistence read-back, heading order, unknown-category fallback
- `static/app.js` -- no changes expected (grouping is server-rendered)

## UI Evolution (required if Frontend Present: yes)
- New user-facing capability: the list reads as a per-aisle plan, identical from every browser
- New information displayed: category headings above their items
- New user actions: choose a category while adding an item
- UI surface changes: grouped list with headings on `/`; select on the add form
- Navigation changes: none

## Visual Requirements (required if Frontend Present: yes)
- Component patterns: native `<select>`; heading rows inside the existing list
- Layout: unchanged single-column page
- Key visual effects: none
- States to handle: items with no category render under `Other`; empty categories
  omit their heading

## Key Test Scenarios
- Add `Milk` ×1 as `Grocery` → the row read back from the DB carries `Grocery`.
- Served HTML groups items under `Grocery` / `Hardware` / `Other` headings in that
  fixed order, JavaScript disabled.
- A second browser session sees the same groups (no browser-local state).
- Unknown category value posted → row persists under `Other`.
- J-01, J-02, J-03 still pass.
