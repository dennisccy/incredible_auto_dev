# Phase N — What to Click (Operator Verification Guide)

**Phase:** <phase-id>
**Time required:** ~5 minutes
**Written by:** ui-test-designer

---

## Prerequisites

- Frontend running at `http://localhost:3000`
- <Any required login: e.g., "Log in as admin (username: admin@example.com, password: check .env)">
- <Any required seed data: e.g., "At least one item must exist — run seed script if needed">

---

## Verification Steps

<!-- Maximum 10 steps. Each step must have an exact action and exact expected outcome. -->
<!-- Prioritize: 1) core new feature works, 2) data persists, 3) old features still work. -->

1. Open `http://localhost:3000` in your browser
   - **Expect:** Dashboard loads, no error page

2. Click "<exact navigation label>" in the <sidebar/header/menu>
   - **Expect:** Navigate to `http://localhost:3000/<route>`; heading "<heading text>" is visible

3. Click the "<exact button label>" button
   - **Expect:** <What should appear: form, modal, redirect, etc.>

4. Fill in "<field name>" with "<test value>", then click "<submit button>"
   - **Expect:** <Exact success feedback: "Green message '<text>' appears", "Redirect to /path", etc.>

5. Refresh the page (press F5 or Cmd+R)
   - **Expect:** <Data still visible — confirms persistence>

<!-- Add up to 5 more steps as needed. -->

---

## What "Working Correctly" Looks Like

- <Key visual indicator of success, e.g., "The list shows your newly created item with a blue badge">
- <Second visual indicator>

## Common Issues

- **Blank page / error screen**: Check that the backend is running (`curl http://localhost:8000/health`)
- **Item not saving**: Check browser console for API errors
- <Phase-specific troubleshooting hint>
