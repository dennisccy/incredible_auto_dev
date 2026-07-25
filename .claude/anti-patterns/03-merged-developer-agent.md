## 3. Merged backend+frontend into one developer agent reduces flexibility

**Pattern (anti):** Splitting implementation into separate backend-only and frontend-only agents with separate model invocations.

**Why it's a false economy:** The backend agent writes the handoff, then the frontend agent reads it and adds another handoff. Two sequential long-context invocations for work that shares context. Each agent re-reads the spec, plan, and existing code from scratch.

**Prevention:** A single developer agent handles both. The plan marks `Frontend Present: yes/no`. On yes, the agent implements backend first, then frontend in the same session. Alternatively, run two passes of the same developer agent (backend pass, then frontend pass) using the same agent definition with different context flags.

---

