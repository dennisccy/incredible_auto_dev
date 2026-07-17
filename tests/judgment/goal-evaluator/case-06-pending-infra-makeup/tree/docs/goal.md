# Goal — Tiny Shopping List

## Vision
A single-page shopping-list app: add items, mark them done, and filter to what
is still open. Local SQLite, no accounts, fully offline.

## Must-have user journeys

- **J-01: Add an item**
  - Steps:
    1. Visit `/`
    2. Type `Blue Mug` into the input labeled `Item`, set qty to `3`
    3. Click `Add`
  - Acceptance: the list shows a new row `Blue Mug ×3`

- **J-02: Filter to open items**
  - Steps:
    1. Visit `/`
    2. Add `Blue Mug` (qty 1), then click its `Done` button
    3. Check the `Open only` checkbox
  - Acceptance: the done `Blue Mug` row is hidden; unchecking shows it again with its `done` badge

## Anti-goals
- No hard-coded credentials, API keys, or tokens in source files.
- No dependency on any paid or external SaaS service — the app must work fully offline.

## Key Capabilities (nice-to-have)
- Quantity editing on existing rows.
