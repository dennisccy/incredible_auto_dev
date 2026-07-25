## 1. Vague acceptance criteria cause infinite review loops

**Pattern:** Phase specs contain requirements like "works correctly", "handles all cases", or "the UI should look nice."

**Why it fails:** The reviewer and the developer use different interpretations of "correct". Each review cycle produces a FAIL for a different reason. After 3 loops the pipeline halts with no clear fix.

**Prevention:** Every item in DEFINITION OF DONE must be:
- Specific: "POST /api/items returns 201 with the created item's ID"
- Testable: a concrete pass/fail condition, not a judgment
- Scoped: tied to this phase only, not aspirational future state

**Example (bad):** "The form submission should work."
**Example (good):** "Submitting a valid form creates a record in the database and redirects to the detail page. Submitting an invalid form shows field-level error messages and does not create a record."

---

