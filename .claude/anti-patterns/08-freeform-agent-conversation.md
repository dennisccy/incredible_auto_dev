## 8. Free-form agent conversation leads to hallucinated agreements

**Pattern:** Two agents "discuss" a design decision in chat. Agent B says "OK I'll implement it your way." Agent B then implements something different because its actual context window didn't include the full conversation.

**Why it fails:** Chat messages between agents are not in each agent's context window. Agents only have access to what was in their initial prompt and what they've read from files in the current session.

**Prevention:** Agents communicate ONLY through filesystem artifacts. No "pass a message to the next agent." The orchestrator writes a plan to a file; the developer reads that file. The developer writes a handoff; the reviewer reads that file. This is the only reliable inter-agent communication.

---

