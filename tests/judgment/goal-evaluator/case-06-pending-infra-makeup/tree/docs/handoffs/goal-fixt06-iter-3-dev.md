# Dev Handoff — goal-fixt06-iter-3

**Status:** complete
**Frontend Present:** yes

## What was built
- `templates/index.html`: added the `Open only` checkbox (`#open-only`) above the list.
- `static/app.js`: toggle handler adds/removes the `hide-done` class on `#items`;
  CSS rule `#items.hide-done .item.done { display: none; }`.

## Tests
- `tests/test_filter.py`: 3 new unit tests (TC-1 hidden, TC-2 reappears with badge,
  TC-3 empty-list no error) — all green locally (`pytest -q`: 7 passed).

## Notes for review/QA
J-02 should now pass end-to-end in the browser. J-01 untouched (markup around the
add form unchanged).
