# Proposer Guidance — <project name>

<!--
Read FIRST by the goal-proposer agent (goal-mode continuous improvement — opt-in, default-off).
The agent itself is generic (agents/goal-proposer/body.md); THIS file carries every
project-specific judgment it uses. Copy this template to

    project-extensions/proposer-guidance.md

and fill in every section. Its presence — together with project-extensions/hooks/post-goal.sh —
is the two-file opt-in that makes run-goal.sh dispatch the proposer once every Must-have journey
passes (see docs/goal-mode-quickstart.md, "Continuous improvement (opt-in)").

Keep ALL SIX section headings: the proposer reads each one by name. A fully-worked example
project follows the skeleton — replace it with your own content (or delete it) when filling in.
-->

## Usefulness lens
<!-- What "useful" means for THIS product — the ranking criterion for improvement candidates.
     The proposer forms its shortlist by this lens, NOT by single-metric outliers. State who
     the user is, what decision/outcome an improvement must serve, and what does not count. -->
- An improvement is useful iff it helps <user> <make which decision / reach which outcome>
  faster or more correctly.
- Useful: <concrete example of a qualifying improvement>
- NOT useful: <e.g. cosmetic restyling alone; metrics no user decision consumes; anything an
  Anti-goal forbids>

## Read / MCP tools
<!-- The read-only surfaces the proposer may survey, in the order to read them. Include the
     pre-screen snapshot IF your post-goal hook writes one into the session state dir (name the
     exact file, or write "none"), your app's read-only APIs/CLI queries, and the UI pages to
     inspect for UX/structure gaps. The proposer never runs product write-paths, starts
     services, or places orders. -->
- Pre-screen snapshot: `<filename in SESSION_DIR/, e.g. usage-scan.json — or "none">`
- <read-only tool / endpoint / query 1>
- <read-only tool / endpoint / query 2>
- <UI pages to inspect for UX/structure/missing-dimension gaps>

## Validation screen
<!-- The survivor filter: what counts as VALIDATED for an evidence-backed candidate. For data
     products this is typically an out-of-sample hold-out; other products may define usage
     evidence, error-log evidence, or "none" (then every candidate stays speculative). -->
- Screen: <e.g. "a discovered pattern must also hold on the hold-out slice (most recent N
  weeks/rows), which must not be touched during discovery" — or "none">
- `robustness: robust` ⇔ <the exact condition>. Everything else — including every
  UX/structure/vision-gap candidate — is `speculative`.

## Proposal format — `enhancement-proposals.jsonl` schema
<!-- One JSON object per line, APPENDED (never rewritten) best-first to
     SESSION_DIR/enhancement-proposals.jsonl. Keep these keys; extend if your project needs
     more. -->
Each line:

```json
{"id": "EP-NN", "kind": "<metric|view|ux|structure|vision-gap>", "title": "<≤80 chars>",
 "evidence": "<what in the product's own data supports this — source + number>",
 "robustness": "<robust|speculative>", "benefit": "<one line: who gains what>",
 "build_size": "<S|M>", "promoted": <bool>, "journey": "<J-NN or null>"}
```

- `id`: next free `EP-NN` across the whole file; never reuse one.
- `robustness`: per the Validation screen above. `kind: vision-gap` entries are ALWAYS
  `speculative`.
- `promoted`/`journey`: set only when the proposal is appended to the goal's
  `<!-- AUTO:journeys -->` block.

## Consistency requirement
<!-- The Data-Contract rule EVERY promoted journey must bake into its Acceptance, so a new
     surface can never fork a canonical value. Name your canonical values and their single
     source (they live in SESSION_DIR/blueprint.md's Data Contract). -->
- Every new surface displaying <canonical value(s)> MUST read them from <the canonical
  endpoint/module named in the blueprint's Data Contract> — never recompute them in a new
  code path.
- A journey that introduces a NEW shared value must register it in the blueprint's Data
  Contract as part of the journey's acceptance.

## Walkthrough requirement
<!-- The showcase rule every promoted journey must bake into its Acceptance. -->
- Each promoted journey's Acceptance MUST require a demo-narrator walkthrough of the new
  surface with its steps flagged `[NEW]`, reachable from <the app's main navigation>.

---

# Worked example — `expense-insights` (replace or delete)

<!-- A complete, filled-in guidance for a hypothetical personal-expense tracker with an
     insights dashboard (Flask + SQLite + a read-only JSON API). This is the expected level of
     specificity. -->

## Usefulness lens
- An improvement is useful iff it helps the household user answer "where is my money going and
  what should I change?" faster or more correctly.
- Useful: a breakdown that explains ≥15% of monthly spend variance; a data-quality fix that
  removes duplicate transactions; a navigation change putting a frequently-needed view ≤2
  clicks from the Dashboard.
- NOT useful: cosmetic restyling alone; metrics no household decision consumes; anything the
  Anti-goals forbid (e.g. investment advice).

## Read / MCP tools
- Pre-screen snapshot: `spend-scan.json` (written into `SESSION_DIR/` by
  `project-extensions/hooks/post-goal.sh`; per-category monthly totals + variance for the last
  12 months) — start here.
- `GET /api/summary?month=YYYY-MM` — canonical spend/income/net for one month.
- `GET /api/transactions?from=&to=` — raw rows, read-only.
- `sqlite3 data/expenses.db` — SELECT-only drill-downs the API lacks.
- UI pages `/` (Dashboard), `/months`, `/categories` — inspect for UX/structure gaps.

## Validation screen
- Screen: hold-out on time. A candidate pattern (e.g. "restaurant spend spikes in months with
  ≥2 weekend trips") must be discovered on months 1–9 of the last 12 and ALSO hold on months
  10–12, which must not be touched during discovery.
- `robustness: robust` ⇔ the pattern's direction and rough magnitude (±50%) persist on the
  hold-out months. Everything else — including every UX/structure/vision-gap candidate — is
  `speculative`.

## Proposal format — `enhancement-proposals.jsonl` schema
As the skeleton above. An example line as actually appended:

```json
{"id": "EP-03", "kind": "view", "title": "Category-trend view: restaurants dominate variance", "evidence": "spend-scan.json: restaurants = 38% of 12-mo variance; holds on months 10-12 (41%)", "robustness": "robust", "benefit": "user sees the one category driving overspend without exporting CSVs", "build_size": "S", "promoted": true, "journey": "J-07"}
```

## Consistency requirement
- Monthly total spend, income, and net are canonical: every new view MUST read them from
  `GET /api/summary` (the blueprint Data Contract's single source) — never re-sum transactions
  in a new code path.
- A journey introducing a new shared value (e.g. "category variance share") must register it in
  `SESSION_DIR/blueprint.md`'s Data Contract in the same iteration.

## Walkthrough requirement
- Each promoted journey's Acceptance ends with: "demo-narrator walkthrough shows the new view
  with its steps flagged `[NEW]`, reachable from the Dashboard nav".
