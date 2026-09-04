## 32. A guard or allowlist modelled on prose instead of the enforcer's own rules

**Pattern:** six allow entries were added to silence prompts nobody had observed
(`Bash(nohup *)` cannot match anything — the checker strips `nohup` before rule matching;
`Bash(setsid *)` cannot pre-approve an exec wrapper by documented design), and `core.md`
listed `tee`/`install` as hard-gated after a `cd` (they are not path-restricted at all)
while omitting `rmdir`, redirects and `git` (which are) — and the first guard denied
absolute-path reads, `ag`/`less` after a `cd`, and any "Nth non-flag argument" as a path
(`head -n 20`), none of which the checker gates.

**Why it fails:** the enforcer (Claude Code's permission checker) has a fixed
path-restricted command table, a fixed wrapper list and fixed compound rules. A rule
written from a symptom or from memory either never matches (a dead entry that only
weakens review — the classifier was correctly blocking `nohup uvicorn --host 0.0.0.0`) or
misdescribes the gate, so agents avoid harmless shapes and walk into gated ones. Both
cost a human click or a retry turn, and neither was visible in any metric.

**Prevention:** Applies to any framework rule that mirrors an external enforcer
(permission allowlist entries, PreToolUse guards, prompt rules about what prompts).
Derive the rule set from the enforcer's documented or observed behaviour (docs § Bash
permission rules; the installed bundle's path-restricted table; a sandboxed native-oracle
probe), record the evidence tier next to each rule, keep unverified shapes in a
non-enforcing oracle manifest that the probe script reads, and enforce only commands whose
operand grammar the guard actually models. Deterministic denial rules stay aligned with
demonstrated native behaviour; advisory style rules may be broader. An allow entry with no
demonstrated prompt it removes is removed. After a Claude Code upgrade re-verify that the
bundle still contains `cd-compound-write`, `cd-compound-redirect`, `cd-git-compound`, then
re-run `scripts/automation/permission-oracle.sh`.

**Example (bad):** `- Bash(setsid *)  # detached engine prompts without it` — the engine
is launched with `run_in_background`, never with setsid; 221 direct `setsid` calls
succeeded before the entry existed.

**Example (good):** `WRITE_COMMANDS = {"mkdir","touch","rm","rmdir","mv","cp"}  # bundle
2.1.260 NH table, create/write class` with an evidence-tagged fixture per member.

**Detection:** `python3 hooks/lib/read_path_hygiene.py --self-test` (evidence-tagged
deny/allow/unknown matrix + oracle manifest); the acceptance run's `permission_request`
event log. Regression test: `run-evals.sh` §2d.
