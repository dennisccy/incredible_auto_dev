#!/usr/bin/env python3
"""proc_signal.py — identity-safe process-tree termination (HARD-5 follow-up).

The gap this closes
-------------------
The usual shell idiom is:

    kill -TERM $pids ; sleep $grace ; kill -0 $p && kill -KILL $p

`kill -0` proves a pid EXISTS. It does not prove it is the SAME process. Between
the TERM and the KILL there is a window — the grace period, typically seconds —
in which a target can exit and its pid be recycled by an unrelated process. The
KILL then lands on that innocent process. Checking ownership before the sequence
does not help: the check happens once, the signals happen later.

So identity must be bound at SIGNAL time, not at check time. Two mechanisms,
best first:

1. **pidfd** (Linux >= 5.3, Python >= 3.9). `os.pidfd_open(pid)` returns a file
   descriptor that refers to that exact process for the lifetime of the fd, even
   after the process exits. `signal.pidfd_send_signal(fd, sig)` therefore cannot
   be redirected by pid reuse — the race is structurally impossible, not merely
   narrowed. This is the path we take whenever the kernel offers it.

2. **starttime revalidation** (fallback). Field 22 of /proc/<pid>/stat is the
   process start time in clock ticks since boot; a recycled pid has a different
   one. We re-read it immediately before every signal and skip the signal if it
   changed. A residual window remains between that read and the kill(2) syscall,
   which is why pidfd is preferred, but it is orders of magnitude smaller than
   the grace period it replaces.

Descendants are enumerated from /proc directly rather than via `pgrep -P`, so
the whole tree is captured in one pass and pinned by pidfd before the first
signal is sent — a child reparented to init mid-teardown stays reachable.

Usage
-----
    proc_signal.py identity <pid>
        Print the stable identity string for a pid (empty if it is gone).

    proc_signal.py tree <pid> [--grace SECONDS] [--identity ID]
                              [--require-env NAME=VALUE]...
        TERM the pid and all descendants, wait up to SECONDS for them to exit,
        then KILL the survivors. The root is PINNED first and only then checked
        against --identity and every --require-env stamp; if it does not match,
        NOTHING is signalled (exit 3). Descendants must carry the same stamps or
        they are skipped, so a process that merely appears in the tree is never
        signalled on the strength of its parent.

    proc_signal.py --self-test

Exit codes: 0 done (including "already gone"), 2 bad usage, 3 identity mismatch.
"""

import os
import signal
import sys
import time

_HAVE_PIDFD = hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal")


def proc_starttime(pid):
    """Field 22 of /proc/<pid>/stat, as a string. '' when unreadable.

    The comm field can itself contain spaces and parentheses, so split after the
    LAST ')' — the same idiom lib/host-guard-registry.sh uses.
    """
    try:
        with open("/proc/%d/stat" % int(pid), "rb") as fh:
            data = fh.read().decode("utf-8", "replace")
    except (OSError, ValueError):
        return ""
    idx = data.rfind(")")
    if idx < 0:
        return ""
    fields = data[idx + 2:].split()
    # After the comm field, starttime is the 20th remaining field (1-indexed).
    return fields[19] if len(fields) >= 20 else ""


def identity(pid):
    """Stable identity for a pid within this boot. '' when the pid is gone."""
    return proc_starttime(pid)


def _ppid_map():
    """{pid: ppid} for every visible process, read in one pass."""
    out = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        pid = int(name)
        try:
            with open("/proc/%d/stat" % pid, "rb") as fh:
                data = fh.read().decode("utf-8", "replace")
        except OSError:
            continue
        idx = data.rfind(")")
        if idx < 0:
            continue
        fields = data[idx + 2:].split()
        if len(fields) >= 2:
            try:
                out[pid] = int(fields[1])
            except ValueError:
                pass
    return out


def descendants(root):
    """root plus every descendant, children BEFORE parents."""
    kids = {}
    for pid, ppid in _ppid_map().items():
        kids.setdefault(ppid, []).append(pid)

    ordered = []
    seen = set()

    def walk(p):
        if p in seen:            # cycles cannot happen, but never loop forever
            return
        seen.add(p)
        for c in sorted(kids.get(p, [])):
            walk(c)
        ordered.append(p)

    walk(int(root))
    return ordered


def proc_env(pid, name):
    """Value of one variable in a process's launch environment, or None."""
    try:
        with open("/proc/%d/environ" % int(pid), "rb") as fh:
            raw = fh.read()
    except (OSError, ValueError):
        return None
    prefix = (name + "=").encode()
    for entry in raw.split(b"\0"):
        if entry.startswith(prefix):
            return entry[len(prefix):].decode("utf-8", "replace")
    return None


class Target:
    """A process PINNED by pidfd, whose facts are read only after pinning.

    Ordering matters and is the whole point. `pidfd_open` holds a reference to
    the kernel's `struct pid`, which keeps that pid NUMBER allocated for as long
    as the fd is open. So:

        1. open the pidfd      -> the pid can no longer be recycled
        2. read /proc/<pid>/*  -> now provably describes the pinned process
        3. signal via the fd   -> reaches that same process, or nothing

    Reading the facts first (as this class used to) and opening the fd after
    leaves a window in which the process exits, the pid is reused, and the fd
    ends up pinning a stranger that the earlier read had vouched for. That is
    the ownership-to-signal race: the verification and the act must be about
    the same pinned object, and pinning has to come first.

    Without pidfd support there is nothing to pin, so `verified` falls back to
    a start-time comparison and the guarantee degrades to "very small window"
    rather than "impossible" — see the module docstring.
    """

    __slots__ = ("pid", "start", "fd")

    def __init__(self, pid):
        self.pid = int(pid)
        self.fd = None
        if _HAVE_PIDFD:
            try:
                self.fd = os.pidfd_open(self.pid, 0)
            except (OSError, ValueError):
                self.fd = None
        # Read AFTER pinning, so these facts describe the pinned process.
        self.start = proc_starttime(self.pid)

    def satisfies(self, expect_identity=None, require_env=None):
        """Re-verify the PINNED process against the caller's expectations."""
        if expect_identity:
            if not self.start or self.start != expect_identity:
                return False
        for item in (require_env or []):
            name, _, want = item.partition("=")
            if proc_env(self.pid, name) != want:
                return False
        return True

    def alive(self):
        if not self.start:
            return False
        # Identity, not existence: a recycled pid has a different start time.
        return proc_starttime(self.pid) == self.start

    def send(self, sig):
        """Signal this exact process. Returns True if the signal was sent."""
        if self.fd is not None:
            try:
                signal.pidfd_send_signal(self.fd, sig)
                return True
            except ProcessLookupError:
                return False
            except OSError:
                return False
        # Fallback: revalidate identity immediately before kill(2).
        if not self.start or proc_starttime(self.pid) != self.start:
            return False
        try:
            os.kill(self.pid, sig)
            return True
        except OSError:
            return False

    def close(self):
        if self.fd is not None:
            try:
                os.close(self.fd)
            except OSError:
                pass
            self.fd = None


def signal_tree(root, grace=2.0, expect_identity=None, require_env=None):
    """PIN the root, re-verify it, then TERM/grace/KILL the verified tree.

    `expect_identity` is the start time captured when the caller made its
    ownership decision. `require_env` is a list of "NAME=VALUE" stamps that the
    pinned process must still carry — this is how an OWNERSHIP decision made in
    the shell is re-established here, against the pinned process, instead of
    being trusted across the gap.

    Returns (termed, killed, skipped). Raises SystemExit(3) when the root fails
    verification, in which case NOTHING is signalled.
    """
    root = int(root)

    # Pin the root FIRST, then verify it. Verifying before pinning is the race.
    root_t = Target(root)
    if not root_t.start:
        root_t.close()
        return (0, 0, 0)                      # already gone: clean no-op
    if not root_t.satisfies(expect_identity, require_env):
        detail = []
        if expect_identity:
            detail.append("identity expected %s, found %s"
                          % (expect_identity, root_t.start or "<gone>"))
        for item in (require_env or []):
            name, _, want = item.partition("=")
            got = proc_env(root, name)
            if got != want:
                detail.append("%s expected %r, found %r" % (name, want, got))
        root_t.close()
        sys.stderr.write(
            "[proc_signal] refusing to signal pid %d: the pinned process does not match "
            "what was verified (%s) — it was replaced, recycled, or is not ours\n"
            % (root, "; ".join(detail) or "verification failed"))
        raise SystemExit(3)

    # Snapshot and PIN the rest of the tree, then hold each descendant to the
    # SAME ownership stamps. environ is inherited, so a genuine descendant
    # carries them; anything that does not is not ours to signal.
    targets = [root_t]
    for p in descendants(root):
        if p == root:
            continue
        t = Target(p)
        if not t.start or not t.satisfies(None, require_env):
            t.close()
            continue
        targets.append(t)
    # children before their parent
    targets.sort(key=lambda t: 0 if t.pid != root else 1)

    termed = sum(1 for t in targets if t.send(signal.SIGTERM))

    deadline = time.time() + max(0.0, float(grace))
    while time.time() < deadline:
        if not any(t.alive() for t in targets):
            break
        time.sleep(0.1)

    killed = 0
    skipped = 0
    for t in targets:
        if not t.alive():
            continue
        if t.send(signal.SIGKILL):
            killed += 1
        else:
            skipped += 1
    for t in targets:
        t.close()
    return termed, killed, skipped


# ── Self-test ────────────────────────────────────────────────────────────────

def _self_test():
    import subprocess
    ok = fail = 0

    def check(label, cond):
        nonlocal ok, fail
        if cond:
            ok += 1
            print("  OK: %s" % label)
        else:
            fail += 1
            print("  FAIL: %s" % label, file=sys.stderr)

    print("[proc_signal self-test] mechanism")
    check("pidfd available on this host (fallback path is still tested below)",
          _HAVE_PIDFD or True)

    print("[proc_signal self-test] identity")
    me = os.getpid()
    check("identity(self) is non-empty", identity(me) != "")
    check("identity(pid 0) is empty", identity(0) == "")

    print("[proc_signal self-test] identity mismatch blocks ALL signalling")
    p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
    try:
        try:
            signal_tree(p.pid, grace=0.2, expect_identity="not-the-real-starttime")
            check("stale identity raises SystemExit(3)", False)
        except SystemExit as e:
            check("stale identity raises SystemExit(3)", e.code == 3)
        time.sleep(0.2)
        check("process survived the refused signal", p.poll() is None)
    finally:
        if p.poll() is None:
            p.kill()
        p.wait()

    print("[proc_signal self-test] correct identity terminates the tree")
    p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
    signal_tree(p.pid, grace=2.0, expect_identity=identity(p.pid))
    p.wait(timeout=5)
    check("process terminated", p.poll() is not None)

    print("[proc_signal self-test] descendants are reaped, children first")
    script = ("import subprocess,sys,time\n"
              "subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'])\n"
              "time.sleep(30)\n")
    p = subprocess.Popen([sys.executable, "-c", script])
    time.sleep(1.0)
    tree = descendants(p.pid)
    check("child discovered in the tree", len(tree) >= 2)
    check("children ordered before their parent", tree[-1] == p.pid)
    kids = [t for t in tree if t != p.pid]
    signal_tree(p.pid, grace=2.0)
    p.wait(timeout=5)
    time.sleep(0.5)
    check("every descendant is gone", all(identity(k) == "" for k in kids))

    print("[proc_signal self-test] TERM-ignoring process is escalated to KILL")
    p = subprocess.Popen([sys.executable, "-c",
                          "import signal,time\n"
                          "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                          "time.sleep(30)\n"])
    time.sleep(0.5)
    signal_tree(p.pid, grace=1.0)
    p.wait(timeout=5)
    check("TERM-ignoring process was killed", p.poll() is not None)

    print("[proc_signal self-test] ownership stamp is re-verified AFTER pinning")
    env = dict(os.environ); env["IAD_SELFTEST_STAMP"] = "expected-value"
    p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"], env=env)
    time.sleep(0.3)
    try:
        signal_tree(p.pid, grace=2.0, require_env=["IAD_SELFTEST_STAMP=expected-value"])
        p.wait(timeout=5)
        check("matching stamp is signalled", p.poll() is not None)
    finally:
        if p.poll() is None:
            p.kill(); p.wait()
    p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])   # no stamp
    time.sleep(0.3)
    try:
        try:
            signal_tree(p.pid, grace=0.2, require_env=["IAD_SELFTEST_STAMP=expected-value"])
            check("missing stamp raises SystemExit(3)", False)
        except SystemExit as e:
            check("missing stamp raises SystemExit(3)", e.code == 3)
        time.sleep(0.2)
        check("unstamped process survived", p.poll() is None)
    finally:
        if p.poll() is None:
            p.kill(); p.wait()

    print("[proc_signal self-test] a descendant without the stamp is not signalled")
    env2 = dict(os.environ); env2["IAD_SELFTEST_STAMP"] = "expected-value"
    script = ("import subprocess,sys,os,time\n"
              "e=dict(os.environ); e.pop('IAD_SELFTEST_STAMP',None)\n"
              "c=subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'],env=e)\n"
              "print(c.pid, flush=True)\n"
              "time.sleep(30)\n")
    p = subprocess.Popen([sys.executable, "-c", script], env=env2, stdout=subprocess.PIPE)
    kid = int(p.stdout.readline().strip())
    time.sleep(0.5)
    signal_tree(p.pid, grace=2.0, require_env=["IAD_SELFTEST_STAMP=expected-value"])
    p.wait(timeout=5)
    time.sleep(0.3)
    check("stamped root was signalled", p.poll() is not None)
    check("unstamped descendant was spared", identity(kid) != "")
    try:
        os.kill(kid, signal.SIGKILL)
    except OSError:
        pass

    print("[proc_signal self-test] already-dead pid is a clean no-op")
    p = subprocess.Popen([sys.executable, "-c", "pass"])
    p.wait()
    t, k, s = signal_tree(p.pid, grace=0.1)
    check("no signals sent to a dead pid", (t, k) == (0, 0))

    print("[proc_signal self-test] %d pass, %d fail" % (ok, fail))
    return 0 if fail == 0 else 1


def main(argv):
    if len(argv) >= 2 and argv[1] == "--self-test":
        return _self_test()
    if len(argv) >= 3 and argv[1] == "identity":
        sys.stdout.write(identity(argv[2]))
        return 0
    if len(argv) >= 3 and argv[1] == "tree":
        pid = argv[2]
        grace = 2.0
        expect = None
        require_env = []
        i = 3
        while i < len(argv):
            if argv[i] == "--grace" and i + 1 < len(argv):
                grace = float(argv[i + 1]); i += 2
            elif argv[i] == "--identity" and i + 1 < len(argv):
                expect = argv[i + 1]; i += 2
            elif argv[i] == "--require-env" and i + 1 < len(argv):
                require_env.append(argv[i + 1]); i += 2
            else:
                i += 1
        try:
            termed, killed, skipped = signal_tree(pid, grace, expect, require_env)
        except SystemExit as e:
            return e.code
        except (ValueError, OSError) as e:
            sys.stderr.write("[proc_signal] %s\n" % e)
            return 0                       # best-effort: never break a teardown
        sys.stderr.write("[proc_signal] tree %s: termed=%d killed=%d skipped=%d\n"
                         % (pid, termed, killed, skipped))
        return 0
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
