# goal-afx02-iter-3 Execution Plan

## What to Build
- `POST /import`: server-side parse of a pasted `Name x QTY`-per-line block,
  all-or-nothing insert, HTTP 400 identifying the failing line on malformed input.
- Import form (textarea + button) on `/` below the add form.

## Agents Required
- developer: yes -- parse/validate helper, single-transaction insert, `/import`
  route, template form, unit tests for parse/reject/atomicity.

## Frontend Present
yes

## Files to Create/Modify
- `app.py` -- `parse_import_block`, `import_items`, `POST /import` route
- `templates/index.html` -- import form (textarea + Import button)
- `test_items.py` -- parse happy path, malformed-line rejection, all-or-nothing

## UI Evolution (required if Frontend Present: yes)
- New user-facing capability: paste a whole list, get every line as an item
- New information displayed: none beyond the imported rows appearing in the list
- New user actions: paste into the import box and click "Import"
- UI surface changes: import form on the existing `/` page below the add form
- Navigation changes: none

## Visual Requirements (required if Frontend Present: yes)
- Component patterns: plain textarea + button, matching the app's minimal styling
- Layout: unchanged single-column page; import form sits under the add form
- Key visual effects: none
- States to handle: malformed paste surfaces the server's 400 error page naming
  the failing line; empty textarea blocked by `required`

## Key Test Scenarios
- `Blue Mug x 3` + `Milk x 1` pasted → both rows appear with quantities (J-04).
- A malformed second line → HTTP 400 whose body identifies line 2; NOTHING imported.
- A zero-qty line → HTTP 400 identifying the line (same rule as the add form).
- J-01, J-02, J-03 still pass after the template change.
