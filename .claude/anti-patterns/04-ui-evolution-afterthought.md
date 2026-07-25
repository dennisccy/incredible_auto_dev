## 4. UI evolution is an afterthought, not a pipeline gate

**Pattern:** QA runs unit tests, they pass, phase is declared done. Three phases later the product manager notices the user can't access the new feature because no navigation link was added.

**Why it fails:** Unit tests don't check whether the UI exposes the capability. A backend feature is invisible until the UI surfaces it.

**Prevention:** The UI Evolution Audit is part of every phase with `Frontend Present: yes`. `UI-FAIL` blocks overall QA PASS. Review checklist explicitly checks for navigation updates and detail/list pages.

---

