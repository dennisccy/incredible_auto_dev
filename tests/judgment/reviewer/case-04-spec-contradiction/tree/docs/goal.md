# Project Goal

## Vision
QuickList is a single-user, local-first shopping-list web app. A user adds items with
quantities, marks them done while shopping, and filters the list down to what is still
open. It runs entirely on the local machine (Python stdlib `http.server` + SQLite +
vanilla JS) with no accounts and no network dependencies.

## Target Users
One household keeping a shared shopping list on a kitchen laptop.

## Success Criteria
- All Must-have journeys pass in a real browser.
- The app starts with `python3 app.py` and works fully offline.

## Key Capabilities
1. Add an item with a quantity.
2. Mark an item as done.
3. Filter the list to open (not-done) items.
4. Change an item's quantity in place.

## Non-Goals
- Multi-user accounts or sync.
- Mobile app.

## Constraints
- Python stdlib (`http.server`) + SQLite + vanilla JS only; no third-party packages;
  no external services.
- Tests run with `python3 -m unittest` from the project root.

## Must-have user journeys

- **J-01: Add an item**
  - Steps:
    1. Visit `/`
    2. Type `Blue Mug` in the item field and `3` in the qty field
    3. Click "Add"
    4. Expect a list row showing `Blue Mug` with quantity `3`
  - Acceptance: the new item row is visible in the list with its quantity

- **J-02: Mark an item done**
  - Steps:
    1. Visit `/` with at least one open item present
    2. Click the "Done" button on the `Blue Mug` row
    3. Expect the row to show a `done` badge and strikethrough styling
  - Acceptance: the item row shows the done badge and strikethrough

- **J-03: Filter to open items**
  - Steps:
    1. Visit `/` with one done item and one open item present
    2. Toggle "Open only"
    3. Expect done items hidden; open items still visible
  - Acceptance: with the filter on, no done item rows are visible

- **J-04: Change an item's quantity**
  - Steps:
    1. Visit `/` with the `Blue Mug` (qty 3) item present
    2. Change the row's quantity field to `5` and click "Update"
    3. Expect the row to read `Blue Mug × 5`
  - Acceptance: the row shows the new quantity; invalid quantities are rejected

## Anti-goals

- No hard-coded credentials, API keys, or tokens in source files.
- No dependency on any paid or external SaaS service — the app must work fully offline.
- No fabricated demo data presented as real user data.
- SQLite only — no external database service.
