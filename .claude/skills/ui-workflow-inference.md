# Skill: UI Workflow Inference

This skill describes how to infer user journeys from code changes, even without running the application.

## Entry Point Discovery

From route definitions, identify entry points:
- React Router: `<Route path="/foo" element={<FooPage />} />`
- Next.js: files in `pages/` or `app/` directory map to routes
- Vue Router: `routes` array in router.ts
- Express/FastAPI: annotated route handlers

Map each changed page/view to its URL path.

## User Journey Template

For each entry point, construct the implied journey:

```
Entry: <URL or navigation element>
Pre-condition: <what must be true for user to reach this>
Steps:
  1. User navigates to <URL> OR clicks <element>
  2. User sees <what is rendered>
  3. User can perform <available actions>
  4. After action: user sees <outcome>
Exit: <where user ends up>
```

## Journey Types to Always Check

### Create flow
- Entry: "New X" button or navigation to create form
- Happy path: Fill valid data → Submit → See created item
- Validation path: Submit invalid data → See field errors
- Error path: Submit valid data → Backend error → See error message

### List/view flow
- Entry: Navigate to list page
- Happy path: Items appear in list, can click to view detail
- Empty state: What does user see with no items?
- Pagination/filtering: If list has many items, how does user navigate?

### Edit flow
- Entry: "Edit" button on detail view
- Happy path: Change data → Save → See updated item
- Cancel path: Make changes → Cancel → Item unchanged

### Delete flow
- Entry: "Delete" button
- Confirmation: Is there a confirmation dialog?
- Happy path: Confirm → Item removed → User sees feedback
- Error path: Delete fails → User sees error

### Auth-gated flows
- If auth middleware changed: which pages became accessible/inaccessible?

## Navigation Completeness Check

For every new entity type or capability added:
1. Is there a list page?
2. Is there a detail page?
3. Is there a create flow?
4. Is there a navigation link to the list page?
5. Is the link reachable from the main navigation?

Missing items in this checklist = "hidden capability".
