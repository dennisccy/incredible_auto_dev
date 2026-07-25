## 10. Supply-chain attacks target autonomous agents

**Pattern:** A compromised PyPI or npm package gets installed by an agent during a phase run. The agent has no reason to be suspicious — it's just running the install command from the spec.

**Why it fails:** Autonomous agents install packages without human review. A single compromised dependency can exfiltrate secrets, modify the codebase, or establish persistence — all while the pipeline continues normally.

**Prevention:** The install security gate intercepts every `pip install`, `npm install`, `git clone`, and `curl|bash` command. On Claude Code it reads the PreToolUse JSON from stdin (`.tool_input.command` — `$CLAUDE_TOOL_INPUT_COMMAND` never existed; SEC-7 fixed the plumbing) and enforces via an agent-visible `permissionDecision:"deny"` with the remediation in the reason (pin the version / edit the `config/install-security-policy.json` allowlist / `CHAIN_INSTALL_GATE_BYPASS=true`) — never a user prompt. Registry packages are warn-mode (SEC-6: proceed + logged banner); direct URLs, tarballs, custom indexes, denylist hits, unknown requirements files, unpinned git clones, and real (unquoted — quoted mentions pass) `curl|bash` deny. All decisions are logged to `reports/security/install-decisions.jsonl`. The gate is a non-negotiable pipeline component — it is not "paranoia."

---

