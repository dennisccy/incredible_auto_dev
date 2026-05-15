# Skill: UI Regression Scout

This skill describes how to identify user journeys from prior phases that may be affected by current changes.

## Finding Prior Phase Artifacts

1. List files in `docs/handoffs/` directory
2. Identify handoffs from prior phases (e.g., `phase-1-dev.md`, `phase-2-frontend.md`)
3. Read each prior phase's "What Was Built" and "Files Changed" sections

## Identifying Shared Components

From the current phase's `ui-surface-map.md`, collect all changed components.

From prior phase handoffs, collect all components those phases touched.

Find the intersection: components that were changed in this phase AND were part of prior features.

For each shared component:
- Name the prior feature it served
- Describe the current phase's change to that component
- Assess the regression risk:
  - **High risk**: Component is central to prior feature's workflow
  - **Medium risk**: Component is a dependency of prior feature
  - **Low risk**: Component is cosmetically similar but functionally separate

## Navigation Integrity Check

The navigation structure (sidebar, main menu, tabs) is a shared component for ALL features.

If the current phase changed:
- `Sidebar.tsx`, `Nav.tsx`, `Navigation.tsx`, `App.tsx`, layout components
- Router configuration
- Auth middleware or permission checks

→ Check that all prior phase features are still reachable.

Method:
1. List all routes added in prior phases (from prior handoffs)
2. Verify each route is still in the current router configuration
3. Verify navigation links to those routes still exist

## Discoverability Assessment

For each capability added in the CURRENT phase:
1. Open the home/dashboard page (conceptually)
2. How many clicks does it take to reach the new feature?
   - 1 click (navigation link) = discoverable
   - 2 clicks (submenu or secondary nav) = acceptable
   - 3+ clicks = undiscoverable, flag it
   - Not accessible from navigation at all = hidden capability

## Flag Levels

**Hidden capability**: Feature exists in backend or frontend but has NO navigation path to it.
Action: Add navigation entry or document explicitly why it is intentionally hidden.

**Undiscoverable capability**: Feature exists but requires >2 clicks or obscure navigation.
Action: Suggest a more prominent entry point.

**Potential regression**: Prior feature shares a component with current changes.
Action: Manual regression test recommended for the specific prior feature.

**Label confusion**: UI label doesn't match what the feature does or what the spec calls it.
Action: Align label with spec terminology.
