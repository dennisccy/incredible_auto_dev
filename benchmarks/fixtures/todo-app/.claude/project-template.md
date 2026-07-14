# Project Configuration — todo-app (EVO-3 benchmark fixture)

Filled for THIS app. Agents read this file to understand the stack, commands,
and constraints. The scaffold is deliberately bare — see docs/goal.md for what
to build.

---

## PROJECT GOAL

```
Goal document: docs/goal.md
```

---

## PROJECT

```
Name:        todo-app
Description: Single-page personal todo list backed by one local JSON file
Repository:  none — the benchmark runner copies this tree to a scratch dir and runs `git init` there
```

---

## STACK

```
Backend:
  Language:   Python 3.14
  Framework:  Flask 3
  ORM/DB lib: none — plain JSON file read/written via helpers in app.py
  Migrations: N/A
  Test runner: pytest
  Package mgr: pip (inside .venv/)
  Venv/env:   .venv/ at the project root — create with:
              python3 -m venv .venv && .venv/bin/pip install flask pytest

Frontend:
  Enabled:    yes
  Framework:  none — server-rendered template + vanilla JS (static/app.js)
  Language:   JavaScript (vanilla), HTML via Flask/Jinja template
  Styling:    plain CSS (none yet — add inline or a small static/style.css)
  Package mgr: none — no node, no build step

Database:
  Type:       JSON file
  Location:   todos.json beside app.py — created at runtime, never committed

Services:
  Backend URL:  http://127.0.0.1:5177
  Frontend URL: http://127.0.0.1:5177 — same Flask server serves the page and static assets
  Health check: http://127.0.0.1:5177/health
```

---

## DESIGN SYSTEM

```
Component library: none — hand-written HTML/CSS only
Icon library:      none — text labels suffice

Visual style:      minimal-light, single column
Color mode:        light

Color palette:
  Background:      #ffffff
  Surface:         #f6f6f6 — list rows / panels
  Border:          #dddddd
  Primary:         #2563eb — buttons and active filter
  Success:         #16a34a — done state accents
  Danger:          #dc2626
  Text primary:    #1f2937
  Text muted:      #6b7280

Typography:
  Font family:     system-ui stack; no webfonts
  Scale:           browser defaults; headings one step up

Spacing:           multiples of 8px; the page stays one centered column

Effects (use sparingly):
  - done items: strikethrough + muted text
  - no animations required
```

---

## TEST COMMANDS

```
Backend tests:  .venv/bin/python -m pytest -q
Frontend tests: N/A
Migrations:     N/A
Lint:           N/A
```

---

## SERVICE START COMMANDS

```
Start backend:  .venv/bin/python app.py    # serves http://127.0.0.1:5177
Start frontend: N/A — the backend serves the page
```

---

## PHASE SPECS

```
Phase spec directory:   docs/phases/
Phase spec naming:      goal mode writes goal-<sid>-iter-<N>.md here
```

---

## ROADMAP

Goal mode drives this project from docs/goal.md; there is no phase roadmap.

| Phase | Name | Status |
|-------|------|--------|
| — | (iterations decomposed from docs/goal.md) | — |

---

## ARCHITECTURE PRINCIPLES

```
- Single-file Flask app: all routes and store helpers live in app.py; no blueprints
  or packages unless a journey forces it.
- todos.json is the ONLY state, and all reads/writes go through the store helper(s)
  in app.py — never open the file elsewhere.
- No build step: static/app.js is plain vanilla JS served as-is.
- No new runtime dependencies beyond Flask (pytest is test-only).
- The port is fixed at 5177 — do not change it.
```

---

## DATA MODEL RULES

```
- todos.json holds a JSON array of todo objects.
- Each todo carries a stable id, its text, and a done boolean.
- If timestamps are ever added, they are UTC ISO 8601 strings.
```

---

## GIT WORKFLOW

```
Branch naming:      main only — the benchmark scratch repo commits directly to main
PR title format:    N/A — no remote, no PRs in benchmark runs
Main branch:        main
Never commit:
  - todos.json      (runtime store)
  - .venv/
  - __pycache__/
  - .pytest_cache/
```

---

## NOTES FOR AGENTS

```
- This project is the framework's EVO-3 benchmark fixture: the journeys in
  docs/goal.md are deliberately unimplemented in the scaffold; building them
  IS the task.
- Keep changes lean — the benchmark budget is 2 lean iterations.
```
