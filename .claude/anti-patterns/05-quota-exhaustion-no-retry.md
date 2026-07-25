## 5. Quota exhaustion mid-pipeline without retry causes data loss

**Pattern:** A 6-stage pipeline runs unattended. At stage 4 (QA), Claude hits the usage quota and exits. The partial run state is lost. The pipeline must restart from scratch.

**Why it fails:** Wasted compute. Worse, if stage 3 (dev) made changes that weren't committed, the developer re-implements the same code differently on retry, causing drift.

**Prevention:**
- Checkpoint/resume via `runs/<phase>/status.json` — completed stages are skipped on re-run
- `quota-retry.sh` wraps every Claude invocation — detects quota messages, parses the reset time, sleeps and retries automatically
- Never start a long pipeline before verifying quota headroom

---

