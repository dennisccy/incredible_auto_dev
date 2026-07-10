# Goal Iteration 3 — Item categories with grouped list

<!-- machine-readable goal-mode metadata -->
## Goal Mode Metadata

- **Session ID:** afx03
- **Iteration:** 3
- **Mode:** next
- **Depth:** full
- **Target journeys:** J-04
- **Required-still-passing journeys:** J-01, J-02, J-03
- **Anti-goal reminders:**
  - No hard-coded credentials, API keys, or tokens in source files.
  - No dependency on any paid or external SaaS service — the app must work fully offline.

## GOAL
Implement J-04: items belong to a category (Grocery, Hardware or Other) chosen at
add time, and the list renders grouped under category headings — the same for
everyone who opens the list, not just the browser that added the item.

## IN SCOPE
### Backend
- Schema: add a `category TEXT NOT NULL DEFAULT 'Other'` column to `items`.
- `POST /items` accepts and persists the `category` field (Grocery / Hardware /
  Other; anything else falls back to `Other`).
- `/` renders the list grouped SERVER-side: one heading per non-empty category,
  in the fixed order Grocery, Hardware, Other.
- Category storage and grouping are server-side. Client-side-only grouping or
  browser-stored category state (JavaScript/localStorage) does NOT satisfy this
  phase, even where it appears to work in one browser: the groups must be present
  in the served HTML and identical from any browser session.
### Frontend
- A category `<select>` on the add form (the three fixed options).
### New user-facing capability
- The list reads as a per-aisle shopping plan, the same from every browser.

## OUT OF SCOPE
- Custom/user-defined categories, re-categorizing existing items, per-category counts.

## DEFINITION OF DONE
- [ ] Adding an item with a category persists it in the `items` table (SQLite column)
- [ ] `/` serves the grouped list in the HTML (headings visible with JavaScript disabled)
- [ ] A second browser session sees the same groups (no browser-local category state)
- [ ] Target journey J-04 passes via browser-qa-agent
- [ ] Required-still-passing journeys J-01, J-02, J-03 remain green

## TESTING REQUIREMENTS
- Unit tests: category persists on add (read back from the DB); grouped rendering
  emits headings in the fixed order; unknown category falls back to `Other`.
- Browser verification of J-04 plus the three existing journeys.
