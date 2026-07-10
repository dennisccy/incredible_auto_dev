# Project Goal

## Vision
A single-page personal todo list: add tasks, mark them done, and filter the list —
one small Flask app that keeps everything in one local JSON file.

## Target Users
One person tracking their own tasks in a browser on their own machine.

## Success Criteria
- All Must-have journeys below pass in a real browser.
- Todos survive a server restart (the JSON store is the only state).

## Key Capabilities
1. Add a todo from the page.
2. Toggle a todo between open and done, persisted across reloads.
3. Filter the list to open or done todos.

## Non-Goals
- Multi-user support, sharing, or sync.
- Any storage other than the single local JSON file.

## Constraints
- Stack is fixed: Flask + vanilla JS + pytest; no new runtime dependencies beyond Flask.
- Server binds 127.0.0.1:5177; storage is todos.json beside app.py, created at runtime.

## Design Direction
- Visual style: minimal-clean, single column, readable at a glance.
- Mood: calm, utilitarian.
- Reference: a plain paper checklist.

## Product Shape

### Navigation / information architecture
- One page at / — header, add form, todo list, filter controls. The only other route is /health.

### Canonical values (single source of truth)
- The todo collection: read and written ONLY through the JSON-store helper(s) in app.py;
  every view of the list (full, open, done) derives from that one store.

## Must-have user journeys

- **J-01: Add a todo via the form**
  - Steps:
    1. Visit http://127.0.0.1:5177/
    2. Type "buy milk" into the new-todo input.
    3. Submit the add form.
  - Acceptance: "buy milk" appears as an item in the todo list, and it is still listed after a page reload.

- **J-02: Toggle a todo done**
  - Steps:
    1. With "buy milk" listed, click its done control.
    2. Observe the item's visual state change.
    3. Reload the page.
  - Acceptance: the item shows a visibly distinct done treatment (strikethrough or checked marker) both before and after the reload.

- **J-03: Filter open vs done**
  - Steps:
    1. Add a second todo "walk dog", then mark "walk dog" done.
    2. Click the "Open" filter control.
    3. Click the "Done" filter control.
  - Acceptance: the Open view shows "buy milk" but not "walk dog"; the Done view shows "walk dog" but not "buy milk".

## Anti-goals

- No user accounts, sessions, or auth of any kind — the app must never ask for credentials.
- No external network calls, third-party services, or paid APIs at runtime — storage is
  the local todos.json file only, and every page asset is served from 127.0.0.1:5177.
