# Phase N — UI Surface Map

**Phase:** <phase-id>
**Date:** <YYYY-MM-DD>
**Written by:** ui-impact-analyst

---

## Affected UI Surfaces

<!-- List each route, page, component, form, modal, table, chart, or navigation element that changed. -->
<!-- "What to Test" must be a specific action, not "verify it works". -->

| Route / Page | Component / Element | Change Type | Why Changed | What to Test |
|-------------|--------------------|-----------:|------------|-------------|
| `/example` | `ExampleList` | New page | Phase adds X capability | Verify list loads and shows X items |
| `/example/new` | `ExampleForm` | New form | User can now create X | Submit valid form, verify redirect to detail |
| `/example/:id` | `ExampleDetail` | New page | User can view X details | Verify all fields display correctly |
| `/` | `Sidebar` | Navigation added | New top-level section | Verify "Example" link appears and is clickable |

<!-- Add one row per affected surface. -->
<!-- Change Type options: New page | New component | Updated layout | Added navigation | Changed behavior | Removed element | New form | New table | New modal -->

---

## Backend-Only Changes (No UI Impact)

<!-- List backend changes that have no corresponding UI surface impact. -->

- `<service/model/migration>` — <what it does> — no UI surface affected

<!-- None if all changes have UI impact. -->

---

## Summary

- **Frontend surfaces changed:** <N>
- **New pages/routes:** <N>
- **Modified components:** <N>
- **Navigation changes:** yes/no
- **Backend-only changes:** <N>
