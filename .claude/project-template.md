# Project Configuration Template

Copy this file into your project's `.claude/` directory and fill in every section.
Agents read this file to understand your project's stack, conventions, and constraints.

---

## PROJECT GOAL

```
Goal document: docs/goal.md
```

Fill in `docs/goal.md` (use `templates/project-goal.md` as a starting point).
The goal doc covers vision, target users, success criteria, and key capabilities only.
Scope boundaries, design system, and constraints are defined below in this file.
All agents read both files before starting any phase to ensure alignment.

---

## PROJECT

```
Name:        <your project name>
Description: <one-line description of what this project does>
Repository:  <git remote URL>
```

---

## STACK

Define your technology stack. Agents use this to know which commands to run and which files to touch.

```
Backend:
  Language:   <e.g., Python 3.12>
  Framework:  <e.g., FastAPI, Django, Express, Rails>
  ORM/DB lib: <e.g., SQLAlchemy 2.0, Prisma, ActiveRecord>
  Migrations: <e.g., Alembic, Flyway, Prisma Migrate, rake db:migrate>
  Test runner: <e.g., pytest, jest, rspec>
  Package mgr: <e.g., pip + uv, npm, cargo, bundler>
  Venv/env:   <e.g., apps/backend/.venv/, node_modules/ (auto)>

Frontend:
  Enabled:    yes/no
  Framework:  <e.g., Next.js 15 App Router, Vue 3, SvelteKit> (or "N/A")
  Language:   <e.g., TypeScript>
  Styling:    <e.g., CSS modules, Tailwind, styled-components>
  Package mgr: <e.g., npm, pnpm, yarn>

Database:
  Type:       <e.g., SQLite, PostgreSQL, MySQL, MongoDB>
  Location:   <e.g., apps/backend/app.db, postgresql://localhost:5432/mydb>

Services:
  Backend URL:  http://localhost:<port>
  Frontend URL: http://localhost:<port>  (or "N/A")
  Health check: <e.g., http://localhost:8000/health>
```

---

## DESIGN SYSTEM

Define your project's visual identity. Agents use this to ensure consistent, polished UI output.

```
Component library: <e.g., shadcn/ui, Radix + Tailwind, Material UI, Chakra UI>
Icon library:      <e.g., Lucide, Heroicons, Phosphor>

Visual style:      <e.g., cyber-dark, minimal-light, corporate-clean>
Color mode:        <dark / light / system>

Color palette:
  Background:      <e.g., #0a0a0f — deep dark base>
  Surface:         <e.g., #12121a — card/panel background>
  Border:          <e.g., #1e1e2e — subtle borders>
  Primary:         <e.g., #00f0ff — neon cyan accent>
  Secondary:       <e.g., #7c3aed — electric purple>
  Success:         <e.g., #10b981>
  Warning:         <e.g., #f59e0b>
  Danger:          <e.g., #ef4444>
  Text primary:    <e.g., #e2e8f0 — high contrast on dark>
  Text muted:      <e.g., #64748b>

Typography:
  Font family:     <e.g., Inter for body, JetBrains Mono for code/data>
  Scale:           <e.g., Tailwind default: text-sm/base/lg/xl/2xl>

Spacing:           <e.g., Tailwind default 4px grid: p-1/p-2/p-3/p-4/p-6/p-8>

Effects (use sparingly):
  - <e.g., glassmorphism on cards: backdrop-blur-md bg-white/5 border border-white/10>
  - <e.g., glow on primary actions: shadow-[0_0_15px_rgba(0,240,255,0.3)]>
  - <e.g., subtle gradient borders on hero sections>
  - <e.g., smooth transitions: transition-all duration-200>

Responsive breakpoints: <e.g., sm:640px md:768px lg:1024px xl:1280px>
```

---

## TEST COMMANDS

Agents will run these to validate their work. Be exact.

```
Backend tests:  <e.g., cd apps/backend && .venv/bin/python -m pytest tests/ -v>
Frontend tests: <e.g., cd apps/frontend && npm test -- --passWithNoTests> (or "N/A")
Migrations:     <e.g., cd apps/backend && .venv/bin/alembic upgrade head> (or "N/A")
Lint:           <e.g., cd apps/backend && .venv/bin/ruff check .> (or "N/A")
```

---

## SERVICE START COMMANDS

Used by qa-phase.sh to auto-start services during QA validation.

```
Start backend:  <e.g., bash scripts/start-backend.sh> (or set CHAIN_START_BACKEND_CMD env var)
Start frontend: <e.g., bash scripts/start-frontend.sh> (or set CHAIN_START_FRONTEND_CMD env var)
```

---

## PHASE SPECS

```
Phase spec directory:   docs/phases/
Phase spec naming:      <phase-id>.md  OR  <phase-id>-<name>.md
                        Example: phase-3.md  OR  phase-3-user-auth.md
```

---

## ROADMAP

| Phase | Name | Status |
|-------|------|--------|
| phase-1 | ... | ✅ Complete / 🔄 In Progress / Future |
| phase-2 | ... | Future |

---

## ARCHITECTURE PRINCIPLES

List project-specific rules ALL agents must follow when writing code.
Example:
- Keep API routes thin — business logic lives in services, not routers
- All database access goes through the repository layer
- Frontend never contains business logic — calls backend APIs only
- Every resource has explicit status transitions; invalid transitions are rejected

```
- <principle 1>
- <principle 2>
- <principle 3>
```

---

## DATA MODEL RULES

Project-specific conventions for data modeling.
Example:
- Use UUID string primary keys (not auto-increment integers)
- All timestamps are UTC ISO 8601 strings
- JSON fields only where schema flexibility is explicitly required

```
- <rule 1>
- <rule 2>
```

---

## GIT WORKFLOW

```
Branch naming:      phase/<phase-id>
PR title format:    feat: <phase-id> — <one-line summary>
Main branch:        main
Never commit:
  - .env
  - *.db  (or your specific database file)
  - credentials.json
  - <any other project-specific secrets or large binaries>
```

---

## OUT OF SCOPE DEFAULT

Unless explicitly required in a phase spec, the following are NEVER implemented:

```
- <out-of-scope item 1>  (e.g., user authentication)
- <out-of-scope item 2>  (e.g., payment processing)
- <out-of-scope item 3>  (e.g., third-party integrations)
```

---

## NOTES FOR AGENTS

Any additional context that doesn't fit the above categories:

```
- <note 1>
- <note 2>
```
