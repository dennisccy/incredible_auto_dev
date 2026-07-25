## 7. Reviewer and QA validator that fix code bypass the feedback loop

**Pattern:** The reviewer notices a bug and edits the file to fix it "since it's obvious." The QA validator notices a test failure and patches the test to pass.

**Why it fails:** The developer agent doesn't learn from the correction. On the next phase, the same mistake recurs because the developer never saw it as a fix — only the reviewer did. More critically: reviewer fixes can silently introduce new bugs that QA was supposed to catch, but QA didn't see the reviewer's changes.

**Prevention:**
- Reviewer NEVER edits source files — writes the report only
- QA NEVER fixes test failures — writes them as blockers
- Only the developer (and auditor, for critical post-QA issues) modifies source code

---

