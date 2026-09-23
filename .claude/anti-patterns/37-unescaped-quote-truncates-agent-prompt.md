## 37. An unescaped double quote inside a `-p "…"` prompt silently truncates what the agent receives

**Applies to:** any engine script that builds an agent prompt as a multi-line bash double-quoted string passed as `claude_with_quota_retry -p "…"`, `agent_with_quota_retry -p "…"` or `claude -p "…"`, and every edit to such prompt text.

**Pattern:** run-phase.sh's orchestrator prompt contained `CRITICAL FORMAT: Write this as a plain inline line "Frontend Present: yes" or "Frontend Present: no"`. The first inner `"` closed the prompt string. Bash glued `Frontend` onto it and split everything after into stray argv words, so the orchestrator received a prompt ending mid-sentence at `…plain inline line Frontend`. The plan contract's items 4-6 (files, UI Evolution, key test scenarios) and "Keep it concise" were never delivered. `bash -n` is clean, the engine logs nothing, and the interactive dispatcher forwards only the `-p` value. Found at goal-taketwo iter 13 (2026-09-23) only because that orchestrator noticed the dangling sentence and read the script to recover the instruction.

**Why it fails:** inside a double-quoted bash word, `"` ends the word unless escaped. A prompt edited as prose looks correct in the source, and nothing downstream compares the delivered prompt with the source text. Quotes inside `$( … )` are a fresh context and legal, which is why eyeballing does not scale.

**Prevention:** `scripts/automation/lib/prompt_quote_lint.py` walks every agent-invocation `-p "` word the way bash does (backslash escapes, `$( … )`, backticks and `${ … }` nesting) and requires the real end of the word to be followed by a separator, a redirection, a `\`-newline continuation, a flag or end of line. `run-evals.sh` runs its self-test and `check-engine` (every `scripts/automation/*.sh` and `lib/*.sh`). Rule: inside an agent prompt, quote literals with single quotes or backticks, or escape them as `\"`; never with a bare `"`.

**Detection:** a subagent reporting that its instructions "stop mid-sentence"; a plan or report missing sections its prompt template names; `prompt_quote_lint.py check` output.
