## 19. `timeout`-wrapped child swallows terminal Ctrl-C

**Pattern:** A long-running command is wrapped with GNU `timeout` for a runtime cap (e.g. `timeout 7200 claude --print "$prompt"`). The user presses Ctrl-C in the terminal and… nothing happens. The shell prints no abort message, no trap fires, and the prompt does not return for many seconds — sometimes minutes — until the wrapped command happens to finish on its own.

**Why it fails:** GNU `timeout` defaults to placing its child in a **new process group** via `setpgid(2)`. Terminal Ctrl-C delivers SIGINT to the foreground process group only, which now contains just the parent shell — *not* the wrapped command. The shell receives the signal and queues the trap, but then has to wait for the pipeline to complete before running the trap; the wrapped command never received SIGINT, so it keeps running. From the user's perspective the script is unresponsive. Eventually the command exits naturally and only then does the queued trap fire — by which point the user has assumed Ctrl-C was lost and probably reached for `kill -9` or closed the terminal.

This is especially bad for AI-agent scripts: the wrapped `claude` keeps consuming API credits long after the user thought they aborted.

**Prevention:** pass `--foreground` to `timeout` (or otherwise keep the child in the parent's process group). With `--foreground`, the wrapped command stays in the parent's pgrp and terminal Ctrl-C reaches it directly. The documented downside — grandchildren of the wrapped command are not timed out — is acceptable for harness use cases where the wrapped command (e.g., `claude`) manages its own subprocesses.

**Example (bad):** `timeout --kill-after=60 7200 claude -p "$prompt" 2>&1 | tee log` — terminal Ctrl-C does NOT reach claude. Trap is queued but blocked.
**Example (good):** `timeout --foreground --kill-after=60 7200 claude -p "$prompt" 2>&1 | tee log` — terminal Ctrl-C reaches claude immediately; trap fires within milliseconds.

**Detection:** if `kill -INT $shell_pid` exits the shell quickly but terminal Ctrl-C feels "stuck", that's the smoking gun. Confirm with `ps -o pid,pgid,cmd <child_pid>` — if the child's PGID differs from the parent shell's, you've got the bug.

---

