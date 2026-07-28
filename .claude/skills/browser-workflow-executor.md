# Skill: Browser Workflow Executor

This skill describes how to execute browser-based QA flows using Chrome MCP.

## Chrome MCP Tool

Use the `mcp__plugin_superpowers-chrome_chrome__use_browser` tool for all browser interactions.

## Basic Operations

### Navigate to a URL
```json
{
  "action": "navigate",
  "url": "http://localhost:3000/path"
}
```
After navigation, wait for the page to load before proceeding.

### Click an element
```json
{
  "action": "click",
  "element": "Save"
}
```
Can use button text, link text, or CSS selector. Prefer text-based selectors for readability.

### Type text into a field
```json
{
  "action": "type",
  "text": "value to type"
}
```
First click the field, then type.

### Take a screenshot
```json
{
  "action": "screenshot"
}
```
Take ONE screenshot per test, at the acceptance state (the state the expected-result describes), plus one on failure.

### Get page text content
```json
{
  "action": "get_text"
}
```
Use to verify specific text is present on the page.

## Test Execution Pattern

For each test case UT-XX:

1. Set up preconditions (navigate to starting URL, create required data if needed)
2. Execute each step from the test plan
3. After each action, verify the expected intermediate state
4. At the end, verify the expected final state
5. Take ONE screenshot at the acceptance state (add one more only on failure)
6. Record: PASS or FAIL with evidence

## Evidence Collection

Screenshots directory: `reports/qa/<phase>-evidence/`
Create before taking screenshots: `mkdir -p reports/qa/<phase>-evidence/`

One screenshot per test, taken at the acceptance state; add one more only on failure.

Naming convention:
- `UT-01-result.png` — acceptance state (one per test)
- `UT-02-fail.png` — failure state (for FAIL tests)

## Verification Techniques

Batch assertions: verify ALL of a state's expected strings in ONE `get_text` call over the relevant container — never one call per assertion.

### Verify text is present
Get page text and check for the expected string.

### Verify element exists
Try to interact with the element — if interaction succeeds, element exists.

### Verify URL after navigation
Check that the current URL matches expected after redirects.

### Verify form error appears
After invalid form submission, check for error text near the submitted field.

### Verify item appears in list
Navigate to list page, check that item name appears in the page text.

## Handling Common Issues

### Page not loaded yet
Wait and retry the get_text action. If still not loaded after 3 attempts, mark as SKIPPED — timeout.

### Element not found
A failing selector gets at most 2 recovery attempts: one alternative locator, then one `get_text` to confirm the element truly is not rendered. If still not found, mark specific step as failed with "element not found: <description>". If a selector fails because the page genuinely changed this iteration, that is a finding — record it; the budget exists to stop exploratory wandering, not to suppress real failures.

### Console error
Note it as WARN in test results. Only mark as FAIL if it prevents the test from completing.

### Unexpected redirect
Note the actual URL vs expected URL. Mark as FAIL if it means the feature is not accessible.
