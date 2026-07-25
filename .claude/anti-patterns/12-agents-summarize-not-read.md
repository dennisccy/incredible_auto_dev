## 12. Agents that "summarize" instead of reading source code

**Pattern:** The auditor reads the dev handoff and QA report, concludes "tests pass and the handoff describes the implementation," and gives PASS.

**Why it fails:** The handoff is a summary written by the agent that implemented the code. It naturally omits mistakes. The QA report validates what the developer chose to test. Neither is a substitute for reading the actual source files.

**Prevention:** Auditor instructions explicitly state: "Read actual source files, not summaries. If you cannot verify a claim from code, trace through the implementation. Never trust a handoff summary alone."

---

