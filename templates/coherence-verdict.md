# Iteration <N> — Coherence Audit

**Iteration:** <iter-name>
**Date:** <YYYY-MM-DD>
**Written by:** coherence-auditor

---

**Verdict:** COHERENCE-PASS | COHERENCE-WARN | COHERENCE-FAIL

<!-- COHERENCE-PASS: no objective violations; at most minor advisory notes -->
<!-- COHERENCE-WARN: only advisory issues; does NOT block GOAL_ACHIEVED -->
<!-- COHERENCE-FAIL: ≥1 objective violation; blocks GOAL_ACHIEVED, forces a consolidation iteration -->

---

## Data Contract check

<!-- For each registered value touched this iteration: OK, or a violation. -->

| Value / entity | Result | Evidence (file:line) |
|---|---|---|
| <value> | OK / DUPLICATE-COMPUTATION / NON-CANONICAL-SOURCE / UNREGISTERED | <path:line or "-"> |

## Information Architecture check

<!-- For each new page/route/feature this iteration: OK, or a violation. -->

| Feature / route | Result | Evidence (nav file inspected) |
|---|---|---|
| <route> | OK / NO-NAV-PATH / UNDISCOVERABLE / DUPLICATE-HOME / PARALLEL-SHELL | <path or "-"> |

## Blocking violations (FAIL only)

<!-- Each must name the rule, the offending file:line, and a concrete finite fix.
     Write "None" for PASS / WARN. -->

1. **<rule>** — <what is wrong> at `<file:line>`.
   **Fix:** <exact, finite remediation — which file to delete / which canonical endpoint to read /
   which nav link to add>.

## Advisory notes (non-blocking)

<!-- WARN-level observations: inconsistent labels, formatting drift, unregistered-but-new values.
     Write "None" if there are none. -->

- <note>
