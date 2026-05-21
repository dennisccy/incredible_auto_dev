# Skill: Coherence Audit

How to audit one goal-mode iteration for coherence drift against the session blueprint. Used by the
`coherence-auditor` agent. The whole point is to catch the two failure modes that make autonomously
built apps unusable: **scattered structure** and **divergent copies of the same value**.

The bar for a hard FAIL is intentionally narrow and objective. Subjective polish is WARN.

## Inputs

- `runs/goal-session-<sid>/state/blueprint.md` — the contract (IA + Data Contract).
- The iteration diff: `git diff <snapshot-sha>` (SHA passed in the prompt), plus `git status` /
  `git diff HEAD` for uncommitted changes.
- `reports/phase-<iter-name>-ui-surface-map.md` — changed surfaces, if present.
- The iteration spec — its "Data-contract additions" / "Blueprint conformance" fields.

## Part A — Data Contract violations (objective → FAIL)

The Data Contract lists, per displayed value/entity: the value name, the single canonical computing
module/function, and the single serving endpoint.

For each registered value:

1. **Duplicate computation.** Search the diff for a new implementation that computes the same value.
   Signals: a new function whose name or math matches the registered concept (e.g. a second
   `sharpe`, `cagr`, `total_return`, `_compute_*`) living outside the registered module.
   → FAIL: "duplicate computation of `<value>`".

2. **Non-canonical source.** Search new UI surfaces for fetches of the value from an endpoint other
   than the registered one, or for client-side recomputation.
   → FAIL: "`<value>` served from non-canonical source".

3. **Re-format is fine.** Reading the canonical endpoint and changing units/precision/labels for
   display is NOT a violation.

For each NEW value the iteration displays that is not yet in the contract:

4. If it is conceptually the same as a registered value (a synonym or re-derivation) → FAIL
   ("duplicate of `<existing value>`").
5. If it is genuinely new but unregistered → WARN ("unregistered value `<x>` — decomposer should add
   it to the Data Contract next iteration").

Tracing tip: confirm a violation by pointing at two places — the registered canonical source in the
blueprint, and the new offending `file:line` in the diff. If you cannot point at both, it is not a
FAIL.

## Part B — Information Architecture violations (objective → FAIL)

The IA section defines the nav skeleton (sidebar/top-nav/sections) and the canonical home for each
feature/entity.

For each new page/route/feature in this iteration:

1. **No navigation path.** Read the nav/sidebar/router components (e.g. `Sidebar.tsx`, `Nav.tsx`,
   `App.tsx`, the router config). If no link reaches the new route → FAIL ("hidden feature: `<route>`
   has no nav path"). Cite the nav file you inspected.

2. **Reachability.** Count clicks from the home/landing surface to the feature using the nav
   structure: 1 click (top-level link) or 2 clicks (one submenu/section) is fine. 3+ clicks, or only
   reachable by typing a URL → FAIL ("undiscoverable: `<route>` is >2 clicks").

3. **Duplicate home.** If the feature is a second page for an entity that already has a canonical home
   in the IA → FAIL ("duplicate home for `<entity>`; consolidate into `<existing home>`").

4. **Parallel shell.** If the iteration introduces its own layout/nav instead of placing the page in
   the blueprint's shell → FAIL ("parallel shell; place `<route>` under `<IA section>`").

Static analysis is authoritative. A live Chrome MCP check is an optional confirmation, never a
dependency — the gate must not be flaky when no server is running.

## Part C — Advisory (WARN only, never FAIL)

- Same entity labelled differently across pages.
- Same value formatted inconsistently (e.g. `12.3%` here, `0.123` there).
- New page that is reachable and in its correct home but visually drifts from the established style.
- Unregistered-but-genuinely-new value (see A5).

## Writing the verdict

- `COHERENCE-FAIL` if Part A or Part B produced ≥1 violation.
- `COHERENCE-WARN` if only Part C / A5 notes exist.
- `COHERENCE-PASS` otherwise.

Every FAIL line = the rule + the offending `file:line` + a concrete finite fix (which file to delete,
which canonical endpoint to read, which nav link to add). The decomposer turns these directly into the
next iteration's consolidation work, so vague fixes defeat the gate.
