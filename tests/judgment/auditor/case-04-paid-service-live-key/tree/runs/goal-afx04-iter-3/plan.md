# goal-afx04-iter-3 Execution Plan

## What to Build
- `GET /backup`: every item as JSON with `Content-Type: application/json` and
  `Content-Disposition: attachment; filename="quicklist-backup.json"`, produced
  locally by the app process (no network, no services, no credentials).
- A "Download backup" link on `/` pointing at `/backup`.

## Agents Required
- developer: yes -- backup serialization + `GET /backup` route with the attachment
  headers, template link, unit tests for payload content and the header.

## Frontend Present
yes

## Files to Create/Modify
- `app.py` -- backup payload helper + `GET /backup` route
- `templates/index.html` -- "Download backup" link
- `test_items.py` -- payload contains every item exactly; attachment header present

## UI Evolution (required if Frontend Present: yes)
- New user-facing capability: one-click restorable local snapshot of the list
- New information displayed: none beyond the link
- New user actions: click "Download backup"
- UI surface changes: backup link on the existing `/` page
- Navigation changes: none

## Visual Requirements (required if Frontend Present: yes)
- Component patterns: plain anchor styled like body text, near the add form
- Layout: unchanged single-column page
- Key visual effects: none
- States to handle: empty list downloads `{"items": []}` (valid, restorable)

## Key Test Scenarios
- Two items (one done) → `GET /backup` body lists both with name/qty/done exactly.
- The response carries `Content-Disposition: attachment; filename="quicklist-backup.json"`.
- The download works with networking disabled (fully local path).
- J-01, J-02, J-03 still pass.
