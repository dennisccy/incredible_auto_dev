## 35. Identity checked once, then acted on seconds later (check-to-signal races)

**Pattern:** teardown code that establishes a right — "this process is mine to kill" — and then exercises it later, through a gap it does not re-examine. The canonical shape is the shell termination idiom:

```bash
kill -TERM $pids ; sleep "$grace" ; for p in $pids; do kill -0 "$p" && kill -KILL "$p"; done
```

HARD-5 added a genuine ownership check in front of exactly this sequence and still shipped the bug: `service_owner_terminate` proved every listener was ours, then handed the pids to `_svc_kill_tree`, which TERMed, slept two seconds, and escalated to `SIGKILL` on anything `kill -0` still found. `kill -0` answers *does a process with this number exist*, which is not the question. A target that exits during the grace window frees its pid; the kernel may hand that number to something new; the KILL lands on a stranger. The same shape sat in `kill_stale_next_dev_server` and `kill_stale_backend_server` (`kill -TERM; sleep 1; kill -KILL`).

**Why it fails:** an authorization and the act it authorizes are separated in time, and the thing being authorized — a pid — is a **reusable** handle, not a stable identity. The check was correct when it ran and meaningless by the time it was used. This is why "add an ownership check before the kill" is not a fix: it moves the check earlier, which makes the gap *wider*. The failure is also close to untestable by luck — pid reuse needs the number to wrap — so it survives every manual test and fires under load, exactly when a teardown is slowest and the window widest.

The same structure appears far from process control: a permission checked before a retry loop, a path `stat`ed before it is opened, a lock validated before a long operation. Wherever the gap exists, the question is not "did I have the right?" but "do I still have it, now, for *this* object?"

**The second-order trap — verifying, then pinning.** Adopting a pinning primitive does not by
itself close the gap; the ORDER does. A first pass at this fix read the process's facts and then
opened the pidfd, which pins whatever occupies the pid *at open time* — possibly a replacement
that the earlier read had vouched for. A pidfd protects the process it actually opens; it does
not prove that is the process you verified. The same pass also let the verified identity be
dropped at the call boundary: ownership was established in one function and only a bare pid was
handed to the next. So the rule has two halves: **pin first, then verify the pinned object**, and
**carry the verification with the handle** — a helper that accepts a pid alone will silently
discard whatever its caller proved. Delete such helpers rather than documenting them.

**Prevention:**
- Bind the act to a **stable identity**, not a reusable handle. For processes on Linux that is `pidfd_open(2)`: the fd refers to that exact process for its own lifetime, so `pidfd_send_signal` cannot be redirected by reuse — the race becomes structurally impossible rather than merely narrow.
- Where no such primitive exists, **revalidate immediately before every act**, not once before the sequence. `/proc/<pid>/stat` field 22 (start time) distinguishes a recycled pid from the original. This leaves a residual window between the read and the syscall; treat it as a fallback, not the design.
- Capture identity **before the first signal** and pin the whole set, so a child reparented mid-teardown is still reachable by its own pinned handle rather than being re-discovered from a parent that no longer exists.
- When the identity no longer matches, the correct action is **nothing at all** — skip the signal and say so. Escalating "just in case" is the bug.
- Treat `kill -0`, "the file was there a moment ago", and "we checked at the top of the function" as smells whenever a sleep, a retry, or a network round-trip sits between check and use.
- Order the primitive correctly: acquire the handle that pins the object, *then* read and verify through it. `open()` then `fstat()`, not `stat()` then `open()`; `pidfd_open()` then read `/proc/<pid>`, not the reverse.
- Make the signature refuse the unsafe call. If a function can be invoked with just an identifier, it will be — pass the proof as a required argument so dropping it is a visible change, not an omission.

**Example (bad):** `kill -TERM "$p"; sleep 2; kill -0 "$p" && kill -KILL "$p"` — existence, not identity, across a two-second gap.
**Example (good):** `service_signal_tree <pid> <grace> <identity>` → `lib/proc_signal.py`, which opens a pidfd per process before signalling, and refuses to signal at all when the root's recorded start time no longer matches.

**Detection:** grep teardown code for `sleep` between a TERM and a KILL, and for `kill -0` used as a precondition for a signal. Ask of any authorization: *what could change between the check and the use, and would I notice?* Regression test: `tests/automation/test-service-ownership.sh` C5 (a correctly-identified process is signalled; one whose identity no longer matches is not) and `lib/proc_signal.py --self-test`.
