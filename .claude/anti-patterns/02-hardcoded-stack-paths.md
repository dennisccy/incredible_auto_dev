## 2. Hardcoded stack paths in agent prompts break portability

**Pattern:** Agent definitions or scripts contain paths like `apps/backend/.venv/bin/python -m pytest` or `cd apps/backend && alembic upgrade head` embedded directly.

**Why it fails:** When the framework is adopted by a new project, every agent file needs manual editing. Agents in the pipeline inherit the wrong paths and fail silently.

**Prevention:** All stack-specific commands live in `.claude/project-template.md`. Agent definitions reference the template: "Run the test command from project-template.md." Scripts use env vars (`CHAIN_START_BACKEND_CMD`) or conventionally-named scripts (`scripts/start-backend.sh`).

---

