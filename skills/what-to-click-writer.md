# Skill: What-to-Click Writer

This skill describes how to write a fast operator verification guide that lets someone confirm a phase worked in under 5 minutes.

## Audience

The reader is:
- Not a developer
- Not familiar with the internal architecture
- Has 5 minutes
- Wants to confirm "the feature works" at a basic level
- Has access to a running instance of the app

## Guide Structure

```
# Phase N — What to Click (Operator Verification Guide)

**Time required:** ~5 minutes
**Prerequisites:** 
  - Frontend running at http://localhost:3000 (or production URL)
  - [Any required login credentials or test data]

## Steps

1. [First step]
   - **Expect:** [exact text or element to see]

2. [Second step]
   - **Expect:** [exact text or element to see]

...

## If Something Looks Wrong

- [Most common problem and quick fix]
```

## Step Writing Rules

**Maximum 10 steps total.** If the feature requires more, you are covering too much.

**Each step must have**:
- Exact URL (not "go to the items page" but "navigate to http://localhost:3000/items")
- Exact action (not "click the button" but "click the blue 'Add Item' button in the upper right")
- Exact expected outcome (not "it should work" but "you should see a green toast 'Item created successfully'")

**Prioritize**:
1. The single most important new thing the phase adds — can the user actually use it?
2. The save/persist check — does data survive a page refresh?
3. The most obvious regression — does the most-used prior feature still work?

**Do not include**:
- Backend API calls
- Developer-facing checks
- Long lists of edge cases
- Steps that require developer tools

## Example (good)

```
## Steps

1. Open http://localhost:3000 in your browser
   - **Expect:** Dashboard page loads, no error messages

2. Click "New Report" in the left sidebar
   - **Expect:** Form page opens at /reports/new

3. Fill in "Title" with any text, select a category, click "Save"
   - **Expect:** Page redirects to /reports/1 with a green "Saved successfully" message

4. Refresh the page (F5)
   - **Expect:** Report still shows the title and category you entered — data persisted

5. Click "Reports" in the left sidebar
   - **Expect:** Your new report appears in the list
```

## Example (bad — too vague)

```
## Steps

1. Go to the app
2. Test the new feature
3. Check that it works correctly
```

## Length Calibration

- 3 steps minimum (smoke, happy path, one regression check)
- 10 steps maximum
- 5–7 steps is ideal

If the phase had no user-visible changes (backend-only), write:
```
**Status:** No UI verification required. Backend-only phase.
```
