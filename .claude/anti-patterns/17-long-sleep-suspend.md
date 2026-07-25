## 17. Long `sleep` blocks the chain across system suspend/resume

**Pattern:** Quota-retry logic calls `sleep 11137` (e.g. 3 hours) to wait for the Anthropic reset. The user closes the laptop lid, system suspends. On wake the next day, the sleep continues ticking monotonically instead of noticing that wall-clock time already passed the reset — the chain blocks for many hours past the intended wake-up.

**Why it fails:** On Linux, `sleep N` in coreutils may sleep against the monotonic clock (pauses during suspend) or depend on the kernel honoring RTC wake-up. Across suspend/hibernate, neither guarantee is reliable: a 3-hour sleep that straddles an overnight suspend can block for 12+ hours. The pipeline is not crashed — it is silently wedged in a sleep that the user can only detect by inspecting `/proc/<pid>/wchan`.

**Prevention:** Long waits must target an absolute wall-clock epoch, not a duration. `lib/quota-retry.sh::_sleep_until_epoch` polls `date +%s` against the target epoch in ≤60-second chunks — on resume, the very next poll sees the epoch has passed and the sleep exits. Any new pipeline script that needs to wait more than ~60 seconds MUST use `_sleep_until_epoch` rather than `sleep $secs`.

**Example (bad):** `sleep "$sleep_secs"` where `sleep_secs` may be hours — stuck indefinitely if the laptop suspends.
**Example (good):** `_sleep_until_epoch "$reset_epoch"` — guaranteed to return within 60s of wall clock reaching the target.

---

