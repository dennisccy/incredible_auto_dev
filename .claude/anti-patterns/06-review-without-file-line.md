## 6. Review reports without file:line references are useless

**Pattern:** Review report says "the validation logic has issues" or "error handling could be improved."

**Why it fails:** The developer reads the report, doesn't know which file or line to fix, makes a guess, and the reviewer flags the same "issue" again in the next loop.

**Prevention:** Every finding in a review report MUST include:
- Exact file path
- Line number or function name
- Specific problem description
- Specific fix description

**Example (bad):** "Error handling is insufficient."
**Example (good):** "`apps/backend/routers/items.py:47` — `create_item` does not catch `IntegrityError` from SQLAlchemy. Add a try/except that returns 409 Conflict when a duplicate key is detected."

---

