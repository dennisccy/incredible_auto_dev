## 30. Process identity resolved by substring-matching a whole command line

**Pattern:** `goal-await-dispatch.sh` resolved the pump's long-lived `claude` session binary by walking `/proc` ancestry and taking the first process whose **entire** `/proc/<pid>/cmdline` contained the substring `claude`. Some CLI harnesses run every Bash tool call as `bash -c 'source ~/.claude/shell-snapshots/snapshot-bash-<n>.sh …'`. That wrapper's cmdline contains `claude` — from the `.claude` **path component**, not from the program — and it lives for exactly one tool call. So the helper stamped the wrapper's pid into `.pump-alive` and `<req>.started`, the wrapper exited the instant the helper returned, and the engine's protocol-v3 fast-pause correctly concluded "pump pid is dead" and halted the session `AWAITING_PUMP` — **on the first dispatch of every run**, before any developer mutation. The failure looked like a pump/session problem, so the standing workaround was to hand-export `CHAIN_PUMP_PID` per session.

**Why it fails:** A command line is not an identity. It is a haystack containing the program, its arguments, config paths, snapshot paths and env-setup boilerplate — any of which may embed the tool's own name. The identity lives in exactly two places: `/proc/<pid>/comm` and the basename of `argv[0]`. Matching the haystack turns every ancestor that merely *mentions* the tool into a candidate, and the shortest-lived candidate wins because the walk stops at the first hit — the wrapper is always nearer than the real binary. The bug was invisible on hosts whose wrapper cmdline happened not to contain the string, which is why it shipped.

**Prevention:** Applies to any code that identifies a process by inspecting `/proc`, `ps` output, or a process table.
- Match the **program**: `comm`, or `${argv0##*/}`. Never grep a whole cmdline for a name that could appear as a path component.
- When a legacy whole-cmdline scan must be kept for coverage (e.g. `node …/cli.js` installs where `comm` is `node`), run it as a **second** pass and exclude shells (`bash|sh|dash|zsh|ksh|busybox`) — a shell is a transient wrapper, never the long-lived binary you are looking for.
- Make the failure asymmetric on purpose: a **miss** must degrade to the safe default (here: no ident → contentless protocol-v2 files → the engine keeps both timeout nets). A false **positive** breaks the run, so bias every rule toward precision.
- A liveness anchor must outlive what it anchors. Before recording a pid as "this work is alive", check that the process you picked is not shorter-lived than the work.

**Example (bad):** `grep -qa 'claude' "/proc/$anc/cmdline" && PUMP=$anc` — matches `bash -c 'source ~/.claude/…'`.
**Example (good):** `comm=$(tr -d '\n' < /proc/$anc/comm); a0=$(tr '\0' '\n' < /proc/$anc/cmdline | head -1); a0=${a0##*/}; [[ "$comm" == *claude* || "$a0" == *claude* ]] && PUMP=$anc`

**Detection:** `[interactive-dispatch] pump is gone: pump pid <N> is dead … (claimed dispatch)` within seconds of the first dispatch, while the session is plainly still open; `pid=` in `<dispatch-dir>/.pump-alive` naming a pid that no longer exists and was never the CLI. 30-second repro: `bash -c '# ~/.claude/x.sh
echo $$; grep -c claude /proc/$$/cmdline'` — a shell that matches while owning nothing. Regression test: `goal-await-dispatch.sh --self-test`, scenario 6b.
