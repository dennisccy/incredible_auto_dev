# Skill: Diff-to-UI Impact Classification

This skill describes how to analyze code file changes and classify their impact on user-visible UI.

## File Classification Rules

### Frontend-direct (UI changes certain)

File extensions in frontend directories (.tsx, .jsx, .ts in src/components/, .vue, .svelte):
- Page components: `pages/`, `views/`, `screens/`, `app/` + component name
- UI components: `components/`, `widgets/`, `ui/`
- Stylesheets: `.css`, `.scss`, `.less`, `.module.css`
- Forms: files containing "Form", "Modal", "Dialog" in name
- Tables/Lists: files containing "Table", "List", "Grid" in name
- Charts: files containing "Chart", "Graph", "Plot" in name
- Navigation: files containing "Nav", "Sidebar", "Menu", "Header", "Footer" in name
- Routing: `router/`, `routes/`, `App.tsx`, files with route definitions

### Backend-API (UI impact depends on frontend consumption)

- API route handlers: `routes/`, `routers/`, `controllers/`, `handlers/`, `endpoints/`
- New endpoints: look for new HTTP method definitions (GET, POST, PUT, DELETE, PATCH)
- Changed response shapes: look for changes to serializers, schemas, response models

### Backend-Internal (no direct UI impact)

- Database models: `models/`, `entities/`, `schema/` without API handler changes
- Business logic: `services/`, `domain/`, `use_cases/` not called from new API
- Migrations: `migrations/`, `alembic/`, `*.sql`
- Tests: `tests/`, `spec/`, `__tests__/`
- Utilities: `utils/`, `helpers/`, `lib/` not imported by frontend

### Config (potential env var or feature flag impact)

- `.env`, `.env.example`, `config.py`, `settings.py`, `constants.ts`
- Note any new env vars that affect runtime behavior

## Classification Output Format

When classifying a set of changed files, produce a table:

| File | Category | UI Impact | Explanation |
|------|----------|-----------|-------------|
| src/components/ItemForm.tsx | frontend-direct | direct | Form component directly shown to user |
| api/routes/items.py | backend-api | indirect | New POST /items endpoint, check if frontend consumes it |
| services/item_service.py | backend-internal | none | Business logic not exposed via API change |

## Inferring UI Impact from Backend-API Changes

When a new API endpoint exists, determine if it's consumed by the frontend:
1. Search the frontend code for the endpoint path (e.g., `/items`)
2. Search for API call patterns (fetch, axios, useQuery, useMutation, api.get, etc.)
3. If found: classify as "indirect — frontend consumes this API, surface affected"
4. If not found: classify as "not visible yet — backend capability without frontend wiring"

## Common Gotchas

- A new database migration does NOT automatically mean UI changed
- A new API endpoint does NOT mean it's exposed in the UI (check the frontend)
- A changed API response shape DOES mean the UI may show different data (check component that renders it)
- A renamed CSS class DOES affect the UI even if it looks the same
- Changes to auth middleware DO affect what users can see (permission gates)
