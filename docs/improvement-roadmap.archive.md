# Improvement roadmap — archive

Full bodies of DONE items, moved out of `docs/improvement-roadmap.md` per its §2 step 8
(growth rule): the active file keeps a one-line stub per archived item. Item format
legend: active file §4.

---

### NEED-1 · `/goal-init` intake interview
- **Priority:** P0 · **Effort:** M · **Risk:** LOW · **Status:** DONE (2026-07-07)
- **Problem:** goal.md quality decides everything downstream, but adopters author it by
  hand from a template with no guidance loop. Vague journeys → infinite review loops
  (anti-pattern #1) and products that miss intent.
- **Current state:** authoring guidance only in `templates/project-goal.md` comments and
  `docs/goal-mode-quickstart.md`. The engine validates structure at start:
  `validate_goal_file` at `scripts/automation/run-goal.sh:533-573` (called ~`:709`)
  checks: file exists, `## Must-have user journeys` heading, `## Anti-goals` heading,
  ≥1 `- **J-NN:` entry, ≥1 concrete non-placeholder anti-goal. Slash-command format:
  see `commands/goal.md` / `commands/goal-status.md` (frontmatter + instruction body).
- **Change spec:**
  1. New `commands/goal-init.md`: interviews the user section-by-section in the order of
     `templates/project-goal.md` (Vision → Target Users → Success Criteria → Key
     Capabilities → Product Shape → Must-have journeys with J-NN IDs, numbered steps,
     and an observable Acceptance line each → Anti-goals). One topic at a time;
     multiple-choice options where sensible; conversational (no special tools assumed).
  2. After the interview, play back "here is what I understood" — one line per journey
     plus anti-goals verbatim — and get explicit confirmation BEFORE writing
     `docs/goal.md`. If a goal.md already exists, offer update mode (show diff of what
     would change) instead of overwrite.
  3. Final self-check: the four `validate_goal_file` rules above + no leftover `<...>`
     template placeholders. (Once NEED-3 ships, run `goal_lint.py` instead.)
  4. New `skills/goal-authoring.md`: the interview script, playback format, and the
     structural checklist — shared later by `/goal-lint` (NEED-4).
- **DoD:** `/goal-init` in a scratch repo produces a goal.md that passes
  `validate_goal_file`; playback-before-write and update-mode behavior are specified in
  the command body; skill and command are mirrored into `.claude/`.
- **Verify:** `python3 scripts/automation/sync-cli-assets.py --cli claude && ls
  .claude/commands/goal-init.md .claude/skills/goal-authoring.md &&
  ./scripts/automation/run-evals.sh`
- **Files:** `commands/goal-init.md` (new), `skills/goal-authoring.md` (new),
  mirrors via sync.
- **Rollback:** delete the two new files + mirrors; nothing else references them.
- **Note (2026-07-07):** implementation complete — `commands/goal-init.md` +
  `skills/goal-authoring.md` written, mirrors rendered, Verify block + full eval
  suite green (78 pass / 0 fail). Left IN-PROGRESS per G8 (Effort M, no
  self-certification). Fresh-session verification remaining: run `/goal-init` in a
  scratch repo, confirm the produced goal.md passes `validate_goal_file` and the
  playback-before-write + update-mode behaviors match the command body, then flip
  to DONE and archive per §2.8.
- **Verified (2026-07-07, fresh session per G8):** DoD checked line by line.
  Verify block re-run green — sync wrote 0 (mirrors drift-free), both mirror files
  present, evals 78 pass / 0 fail. Scratch-repo test-drive (fresh git repo with the
  rendered command/skill/template copied in): CREATE round produced a 3-journey
  goal.md that passes the real `validate_goal_file` (function extracted verbatim
  from `run-goal.sh`; harness red-green-tested first) with zero `<...>` placeholders;
  transcript shows interview → playback → explicit "yes" → write, and both scripted
  vague answers ("popular", "works properly") were pushed to observable per the
  skill. UPDATE round on that goal.md (with an injected `AUTO:journeys` block holding
  J-04): diff-shaped playback (old → new, unchanged by name), explicit "yes" before
  edit, git diff exactly two surgical hunks, AUTO block and J-01..03 byte-identical
  (md5-verified), new journey correctly assigned J-05, validator still passes.

### NEED-2 · Quickstart names `/goal-init` first
- **Priority:** P0 · **Effort:** S · **Risk:** LOW · **Status:** DONE (2026-07-07)
- **Problem:** even after NEED-1 ships, adopters following the quickstart will still
  hand-author goal.md and never discover the interview.
- **Current state:** `docs/goal-mode-quickstart.md` "4-step setup" (~line 18) says to
  author goal.md manually from the template.
- **Change spec:** setup step 1 becomes "run `/goal-init` inside Claude Code (interview →
  drafted goal.md)"; manual authoring stays as the alternative path. Add `/goal-init` to
  the quickstart's See-also list (~line 302).
- **DoD:** quickstart names `/goal-init` before manual authoring.
- **Verify:** `grep -n "goal-init" docs/goal-mode-quickstart.md` (≥2 hits).
- **Files:** `docs/goal-mode-quickstart.md`.
- **Rollback:** revert the doc edit.
- **Verified (2026-07-07, self-certified per §2 step 7 — Effort S):** setup step 1 now
  opens with "**Recommended:** run `/goal-init` inside Claude Code" (interview →
  drafted goal.md) with manual template authoring kept as the explicit alternative
  path; `/goal-init` added to See-also linking `commands/goal-init.md`. Verify block
  green: grep shows 2 hits (step 1 + See-also); full eval suite 78 pass / 0 fail.

### NEED-3 · Deterministic goal linter (`goal_lint.py`)
- **Priority:** P0 · **Effort:** M · **Risk:** LOW · **Status:** DONE (2026-07-07)
- **Problem:** `validate_goal_file` checks presence, not quality. Vague acceptance
  criteria are the documented #1 failure mode and nothing catches them before a session
  burns iterations on them.
- **Current state:** structure checks only (`run-goal.sh:533-573`). Anti-goal bullet
  parsing lives at `run-goal.sh:558-572`; journey-block regexes exist in
  `scripts/automation/lib/goal_gate.py` (~`:158`, `_journey_blocks` /
  `_JOURNEY_HEADER_RE`). Lib self-test convention: see `lib/checkpoint.sh` self-test
  and `run-evals.sh` §2 registry.
- **Change spec:**
  1. New `scripts/automation/lib/goal_lint.py` (stdlib-only). Checks: duplicate J-NN
     IDs; journey missing numbered steps or an `Acceptance` line; leftover `<...>`
     template placeholders; vague words in Acceptance lines ("works well", "fast",
     "properly", "intuitive", "user-friendly", "correctly"); anti-goals phrased as
     aspirations with no checkable condition; empty Product Shape section while ≥2
     journeys reference the same value/metric. Exit codes: 0 clean, 1 warnings,
     2 structural errors. Subcommand `self-test` with fixtures for each rule.
  2. Warn-only engine wiring: in `run-goal.sh` immediately after the
     `validate_goal_file` call (~`:709`), behind `CHAIN_GOAL_LINT` (default `true`):
     `python3 "$SCRIPT_DIR/lib/goal_lint.py" "$GOAL_FILE" || true` — print warnings,
     NEVER block the engine (style must not gate execution).
  3. Register in `run-evals.sh` §2: `goal_lint.py self-test`.
- **DoD:** self-test green; engine start on a deliberately vague goal.md prints warnings
  and proceeds; evals green.
- **Verify:** `python3 scripts/automation/lib/goal_lint.py self-test && bash -n
  scripts/automation/run-goal.sh && ./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/lib/goal_lint.py` (new), `scripts/automation/run-goal.sh`
  (2-3 lines), `scripts/automation/run-evals.sh` (1 line).
- **Rollback:** remove the run-goal.sh call and the eval line; the lib is inert alone.
- **Note (2026-07-07, implementer):** implemented per change spec; Verify block green
  locally (self-test + `bash -n` + evals 79-pass), and a sandbox engine start on a
  deliberately vague goal.md printed 6 warnings then proceeded to iteration 0
  (`CHAIN_GOAL_LINT=false` control run printed none). Left IN-PROGRESS pending
  fresh-session verification per G8.
- **Verified (2026-07-07, fresh session per G8):** DoD checked line by line.
  Verify block re-run green: `goal_lint.py self-test` passed, `bash -n run-goal.sh`
  clean, evals 79 pass / 0 fail (self-test registered at `run-evals.sh:127`; fixtures
  cover all six rules plus the 0/1/2 exit-code contract and negative cases). Wiring
  confirmed at `run-goal.sh:709-713` — immediately after `validate_goal_file`, behind
  `CHAIN_GOAL_LINT` default-true, `|| true`. Sandbox engine start (fresh framework
  copy, dispatch pointed at a dead local endpoint so zero API tokens spent): a
  deliberately vague goal.md printed 5 warnings (vague-acceptance ×2, placeholder,
  aspirational-anti-goal, product-shape-empty — the last confirmed firing on a real
  file, not just fixtures) then proceeded to Iteration 0 / Step 1 baseline-decomposer
  dispatch; `CHAIN_GOAL_LINT=false` control run printed no lint output and proceeded
  identically. Intake tie-in: `/goal-init` flow test-driven in a second scratch repo
  (create-mode goal.md authored per `skills/goal-authoring.md`; interview
  self-answered — no live user in the verifying session): produced file passes the
  command's step-5 self-check (`goal_lint.py` exit 0, silent) and the real
  `validate_goal_file` at engine startup (reached "Initializing new session" →
  iteration 0 with no validation error).

### NEED-4 · `/goal-lint` LLM semantic pass
- **Priority:** P0 · **Effort:** S · **Risk:** LOW · **Status:** DONE (2026-07-07)
- **Problem:** deterministic rules can't catch contradictions between journeys,
  unmeasurable acceptance phrased measurably, or risky surfaces (auth, payments,
  uploads) with no anti-goal coverage.
- **Current state:** no semantic review of goal.md exists anywhere.
- **Change spec:** new `commands/goal-lint.md`: (1) run
  `python3 scripts/automation/lib/goal_lint.py docs/goal.md` and show output; (2) apply
  the semantic checklist from `skills/goal-authoring.md` (NEED-1); (3) write findings to
  `reports/goal-lint.md` in the format: quoted line → problem → concrete suggested
  rewrite. REPORT-ONLY — the command must never edit goal.md (it is user-approval class
  per maintenance protocol §1).
- **DoD:** command exists + mirrored; body forbids editing goal.md; running it on the
  framework's own `docs/goal.md` produces a sane report.
- **Verify:** `python3 scripts/automation/sync-cli-assets.py --cli claude --check`
  after sync; manual run on `docs/goal.md`.
- **Files:** `commands/goal-lint.md` (new) + mirror.
- **Rollback:** delete the command + mirror.
- **Depends on:** NEED-3 (uses the linter), NEED-1 (shares the skill checklist).
- **Note (2026-07-07, implementer — Effort S, self-verified per §2.7):** command
  authored with the seven-check semantic checklist (journey contradictions,
  unobservable-but-measurably-phrased acceptance, guess-requiring steps,
  non-independent journeys, uncovered risky surfaces, keyword-fooling anti-goals,
  unmeasurable success criteria) drawn from `skills/goal-authoring.md` items 3/9/10
  plus the NEED-4 problem statement; body forbids editing goal.md and restricts
  writes to `reports/goal-lint.md` (allowed-tools has no Edit). Verify block green:
  mirror synced, `--check` OK, evals 79 pass / 0 fail. Sanity run on the framework's
  own meta `docs/goal.md` produced a sane `reports/goal-lint.md`: deterministic exit 2
  (`no-journeys` — expected, the file is the documented replace-me meta goal) shown
  verbatim, 2 semantic findings in the quoted-line → problem → paste-ready-rewrite
  format (missing anti-goal coverage for the supply-chain surface; no measurable
  success criterion), summary correctly identifies the file as documentation rather
  than a runnable contract; `docs/goal.md` untouched by the run.

### NEED-5 · Assumption ledger — writers
- **Priority:** P0 · **Effort:** M · **Risk:** MED · **Status:** DONE (2026-07-07)
- **Problem:** the decomposer and evaluator make silent interpretation calls ("the spec
  is ambiguous about X, we chose Y") that the human never sees until the product is
  wrong. Judgment-rubrics §3 only covers the extreme case (STALLED on conflicting
  readings); everyday interpretation choices vanish.
- **Current state:** no assumptions artifact exists. The proven pattern for append-only
  session files is `lessons.md`: appended by the evaluator, pre-trimmed and inlined into
  prompts via `_tail_or_placeholder` (`run-goal.sh:520-525`), never read whole.
- **Change spec:**
  1. New session file `runs/goal-session-<sid>/state/assumptions.md`, append-only.
     Entry format: `## iter-<N> — <agent>` then `**Ambiguity:** …` / `**We chose:** …` /
     `**Reversible:** yes|no`.
  2. `agents/goal-decomposer/body.md`: add a rule (Rules section, ~`:189-199`) — when a
     spec decision required interpreting the goal, append an entry; zero entries is fine
     (signal only, no routine entries — same discipline as lessons).
  3. `agents/goal-evaluator/body.md`: add step "5b" beside the lessons step
     (~`:112-129`) — same, for scoring-time interpretations (e.g. "accepted truncated
     email as 'shows email'").
  4. Dispatch prompts: decomposer prompt block (`run-goal.sh:1241-1281`) and evaluator
     "Prior session state" block (~`:1523-1526`) gain the ledger path (append-target)
     plus an inlined tail via `_tail_or_placeholder`, exactly like `LESSONS_TAIL`.
  5. Version-bump both touched `agent.yaml` files; resync mirrors.
- **DoD:** rendered `.claude/agents/goal-{decomposer,evaluator}.md` contain the ledger
  instructions; both dispatch prompts reference the path; an absent ledger renders as
  placeholder text (no crash); evals green.
- **Verify:** `python3 scripts/automation/sync-cli-assets.py --cli claude && grep -l
  assumptions .claude/agents/goal-decomposer.md .claude/agents/goal-evaluator.md &&
  bash -n scripts/automation/run-goal.sh && ./scripts/automation/run-evals.sh`
- **Files:** `agents/goal-decomposer/body.md`, `agents/goal-evaluator/body.md`, both
  `agent.yaml` (version bump), `scripts/automation/run-goal.sh`, mirrors.
- **Rollback:** revert body edits + prompt lines; existing sessions' assumptions.md
  files become inert.
- **Stop-and-ask:** if the evaluator's prompt assembly has structurally changed from the
  anchors (no `LESSONS_TAIL`-style inlining found), stop — the inline pattern is the
  design, not an implementation detail.
- **Note (2026-07-07):** implemented this session — writer rules in both agent bodies
  (decomposer Rules bullet, evaluator step 5b), `ASSUMPTIONS_FILE` + `ASSUMPTIONS_TAIL`
  wired into both dispatch prompts (tail recomputed fresh at the evaluator site), both
  agent.yaml bumped to 1.3.0, mirrors resynced. Stop-and-ask checked: `LESSONS_TAIL`
  inlining intact at implementation time. Verify block green (sync ok, grep found
  ledger text in both rendered agents, `bash -n` ok, evals 79/79). Left IN-PROGRESS
  per G8 — a FRESH session must verify and flip to DONE.
- **Verified (2026-07-07, fresh session per G8):** DoD checked line by line.
  (1) Ledger instructions present in both rendered agents — decomposer Rules bullet
  (`.claude/agents/goal-decomposer.md:207`, exact entry format + signal-only
  discipline), evaluator step 5b (`goal-evaluator.md:140-144`) plus the append-tooling
  note (`:38`). (2) Both dispatch prompts carry `$ASSUMPTIONS_FILE` as append target
  with an inlined `$ASSUMPTIONS_TAIL` (decomposer `run-goal.sh:1273/:1276`, evaluator
  `:1544/:1553`; tails built at `:1226`/`:1498`, the evaluator site recomputed fresh so
  same-iteration decomposer entries are visible; `ASSUMPTIONS_FILE` defined `:213`,
  before both uses). (3) Absent-ledger behavior functionally tested — the function
  extracted verbatim and run under `set -euo pipefail`: missing file → "(no assumptions
  recorded yet)", empty file → placeholder, populated file → tail; no crash on any
  path. (4) Verify block re-run verbatim green: sync wrote 0 (mirrors drift-free,
  working tree clean before/after), grep matched both rendered agents, `bash -n` ok,
  evals 79 pass / 0 fail. Both agent.yaml confirmed at 1.3.0; the NEED-5 commit
  carries neutral source + mirrors together (G2). Cross-check per the verification
  instructions: /goal-init CREATE round in a scratch repo (command/skill/template
  copied in; `validate_goal_file` extracted verbatim and red-green-tested first —
  three structurally bad files each fail with the matching specific error) produced a
  3-journey goal.md that passes `validate_goal_file` with zero template placeholders;
  `goal_lint.py` (itself red-tested: exit 2 `no-journeys` on a bad file) exits 0 on it.

### NEED-6 · Assumption ledger — surfacing
- **Priority:** P0 · **Effort:** M · **Risk:** MED · **Status:** DONE (2026-07-07)
- **Problem:** a ledger nobody sees changes nothing. The human needs assumptions in the
  iteration summary and HTML report so they can veto early (by editing goal.md — the
  goal slice is rebuilt every iteration at `run-goal.sh:1221-1225`, so edits take effect
  next iteration).
- **Current state:** iteration-summarizer inputs are wired in `_run_iteration_summarizer`
  (`run-goal.sh:244-277`, with `eval_log_inline`-style tail injection ~`:231-232`).
  Summary template: `templates/iteration-summary.md`. The HTML renderer parses H2
  sections generically via `_split_h2_sections`
  (`scripts/automation/lib/render_iteration_summary.py:137-154`) and renders sections in
  `render_html_iteration` (~`:1160-1165`); it skips absent sections.
- **Change spec:**
  1. `templates/iteration-summary.md`: new `## Assumptions made` H2 (after
     `## Next step`).
  2. `agents/iteration-summarizer/body.md`: add the assumptions tail to its inputs and
     the new section to its output contract ("none recorded" when empty). Version-bump.
  3. `_run_iteration_summarizer` wrapper: inline the assumptions tail like the evaluator
     log tail.
  4. Renderer: `_render_assumptions(data)` + insertion in `render_html_iteration`
     (collapsed accordion, house style); extend the renderer's `self-test` with a
     summary containing the new section AND one without it.
- **DoD:** renderer self-test covers both cases; HTML shows the section when present,
  nothing when absent; artifact-schema validation (if it checks section lists) updated;
  evals green.
- **Verify:** `python3 scripts/automation/lib/render_iteration_summary.py self-test &&
  ./scripts/automation/run-evals.sh`
- **Files:** `templates/iteration-summary.md`, `agents/iteration-summarizer/body.md` +
  `agent.yaml`, `scripts/automation/run-goal.sh`,
  `scripts/automation/lib/render_iteration_summary.py`, mirrors.
- **Rollback:** revert; old summaries without the section keep rendering (renderer skips
  absent sections).
- **Stop-and-ask:** if `lib/artifact_schemas.py` hard-fails on unknown H2 sections
  (check before adding the template section), coordinate the schema change in the same
  commit or stop.
- **Depends on:** NEED-5.
- **Note (2026-07-07):** implemented this session. Stop-and-ask checked FIRST — code
  read (`artifact_schemas.py:193-196` checks required-H2 presence only) AND empirically
  validated (a summary with the new section passes `validate_path`), so no schema change
  needed; `Assumptions made` deliberately NOT added to `required_h2` (old summaries must
  keep validating). Template gains `## Assumptions made` after `## Next step` (one plain
  bullet per ledger entry — the ledger's own `## iter-N` headings must never be copied
  in, they'd fracture `_split_h2_sections`; "none recorded" when empty/phase mode).
  Summarizer body: inline-tail input + authoring section; agent.yaml 1.0.0→1.1.0.
  `_run_iteration_summarizer` inlines `_tail_or_placeholder "$ASSUMPTIONS_FILE" 200`
  exactly like the evaluator-log tail. Renderer: `_render_assumptions` (collapsed
  accordion, house style, bullets or plain "none recorded" text) inserted after
  What's-left+Next-step; self-test covers WITH (goal fixture, bullet asserted in HTML)
  and WITHOUT (phase fixture, accordion asserted absent). Verify block green: renderer
  self-test pass, `bash -n` ok, sync --check ok, evals 79/79. Left IN-PROGRESS per
  G8 — a FRESH session must verify and flip to DONE.
- **Verified (2026-07-07, fresh session per G8):** DoD checked line by line.
  (1) Self-test coverage confirmed in the code, not just by exit status: the goal
  fixture carries the section (asserts exactly 1 extracted bullet, and both
  "Assumptions made" + the bullet's text in the rendered HTML); the phase fixture
  omits it (asserts "Assumptions made" absent from that HTML). Re-run fresh: pass,
  exit 0. (2) Present/absent behavior re-proven independently of the self-test
  fixtures — a synthetic summary run through `load_iteration` +
  `render_html_iteration` three ways: WITH section → accordion with the bullet;
  section stripped → no accordion at all; body `none recorded` → accordion renders
  it affirmatively. (3) Schema: `artifact_schemas.py:193-196` checks required-H2
  presence only (unknown sections cannot fail); iteration-summary `required_h2`
  (`:111-118`) deliberately excludes "Assumptions made" so old summaries keep
  validating; empirical `validate` CLI exit 0 on a section-carrying summary.
  (4) Verify block re-run verbatim green: self-test pass, evals 79 pass / 0 fail.
  Placement confirmed (template H2 order: … Next step, Assumptions made, Quick
  verify, Artifacts); `ASSUMPTIONS_FILE` defined `run-goal.sh:213` before its `:241`
  use; sync --check "would change 0" everywhere; agent.yaml at 1.1.0; commit 43159db
  carries neutral source + mirrors together (G2). Cross-check per the verification
  instructions: /goal-init drive in a scratch repo produced a 3-journey goal.md that
  passes `goal_lint.py` (exit 0) and `validate_goal_file` extracted verbatim from
  `run-goal.sh` (PASS; negative control: absent file rejected with the specific
  error, exit 1).

### NEED-9 · Goal-edit drift detection
- **Priority:** P0 · **Effort:** M · **Risk:** MED · **Status:** DONE (2026-07-07)
- **Problem:** the user may edit `docs/goal.md` mid-session (that's the intended veto
  mechanism — the goal slice is rebuilt every iteration, `run-goal.sh:1221-1225`). But
  if the edited journey was already `passing`, `journey-history.json` keeps certifying
  it against the OLD text: a stale pass that can survive all the way into GOAL_ACHIEVED.
- **Current state:** journey state lives in `runs/goal-session-<sid>/state/
  journey-history.json` (rewritten by the evaluator each iteration); pre-eval snapshot
  + deterministic artifacts are built at `run-goal.sh:1460-1475`; the achievement gate
  (`scripts/automation/lib/goal-gates.sh:79-146`) requires every journey
  passing/already_passing. No journey-text hashing exists anywhere.
- **Change spec:**
  1. `lib/goal_gate.py`: new subcommand `hash-journeys <goal.md>` — stable hash (e.g.
     sha256 of normalized text) per `J-NN` block, JSON output. Reuse `_journey_blocks`.
  2. Pre-eval artifact build (`run-goal.sh:1460-1475`): compare current hashes against
     hashes recorded in journey-history (see step 4); for journeys whose recorded state
     is passing/already_passing but whose hash changed, write
     `iter-<N>/journeys-changed.md` listing them.
  3. `agents/goal-evaluator/body.md` (+ methodology skill if it enumerates inputs): read
     `journeys-changed.md` when present; listed journeys must be demoted to
     needs-reverify (not counted as passing) until re-verified against the NEW text;
     record new hashes when writing journey-history. Version-bump.
  4. Journey-history schema: entries gain a `spec_hash` field (writer: evaluator;
     tolerate absence for old sessions — treat missing hash as "unknown, no demotion").
  5. Achievement gate (`goal-gates.sh:79-146`): refuse GOAL_ACHIEVED when
     `journeys-changed.md` for the current iteration lists any journey not re-verified
     this iteration. Add an eval fixture (changed-hash → gate demotes).
- **DoD:** hash subcommand + self-test; changed-passing journey produces the note and
  the gate demotion in the fixture; old journey-history files (no `spec_hash`) still
  parse; evals green.
- **Verify:** `python3 scripts/automation/lib/goal_gate.py self-test 2>/dev/null ||
  python3 scripts/automation/lib/goal_gate.py hash-journeys docs/goal.md &&
  bash -n scripts/automation/run-goal.sh && ./scripts/automation/run-evals.sh`
- **Files:** `scripts/automation/lib/goal_gate.py`,
  `scripts/automation/lib/goal-gates.sh`, `scripts/automation/run-goal.sh`,
  `agents/goal-evaluator/body.md` + `agent.yaml`, `run-evals.sh` fixture, mirrors.
- **Rollback:** stop writing `journeys-changed.md` (one call site); the schema field is
  additive and tolerated-if-absent by design.
- **Stop-and-ask:** if journey-history.json is written anywhere other than the evaluator
  (grep first!), map every writer before adding the field — schema drift across writers
  is exactly the bug class G3 exists for.
- **Slices:** (a) hashing + change detection + pre-eval note; (b) evaluator body + gate
  wiring + fixture.
- **Note (2026-07-07):** slice (a) done, slice (b) pending. Writer census (stop-and-ask
  fired; user approved proceeding): the evaluator is the sole writer of journey ENTRIES;
  `run-goal.sh:760` only seeds the empty skeleton at session init;
  `render_iteration_summary.py:2563/2682/2860` are temp-dir self-test fixtures. Safe for
  slice (b) to add `spec_hash` with the evaluator as sole field writer. Interface built:
  `goal_gate.py hash-journeys <goal.md>` bare → flat `{"J-NN": sha256}` (what the
  evaluator should record); with `--history/--out-changed` run-goal.sh step 3c writes or
  removes `iter-<N>/journeys-changed.md` (self-tested). Slice (b) should also add a
  `runs/SCHEMA.md` entry for journeys-changed.md once it becomes an agent-consumed
  contract (deliberately not documented there yet — siblings like
  journey-history.pre.json aren't either). Known non-goal: a journey deleted from
  goal.md while recorded passing has no current hash → unknown, not flagged (orphan
  reconciliation stays evaluator/lint territory).
- **Note (2026-07-07, session 2):** slice (b) done — both slices now implemented; item
  stays IN-PROGRESS awaiting fresh-session verification (G8): re-run the Verify block,
  then flip to DONE + archive per §2.8. What landed: evaluator contract (body.md step 3)
  makes the evaluator record `spec_hash` per journey it verified this iteration (sole
  writer; carry-over journeys keep their old value or stay absent) and voids the prior
  pass of every journey listed in `iter-<N>/journeys-changed.md` — re-verify against the
  CURRENT text or demote to `unknown` ("needs-reverify" maps to `unknown`: additive, no
  new status value for readers to learn); methodology §A.1 bullet + evaluator dispatch
  prompt line added; agent.yaml 1.3.0→1.4.0; mirrors resynced. Gate: new
  `goal_gate.py drift <note> <history>` (parser lives beside the note's writer;
  round-tripped in the self-test; fail-closed exit 2 on unparsable note/unreadable
  history) wired as achievement-gate check 6 in `lib/goal-gates.sh` — a listed journey
  still passing without a re-recorded hash demotes GOAL_ACHIEVED. Fixtures (run inside
  run-evals.sh): changed-hash demotes / re-recorded hash certifies / absent note never
  blocks (gate self-test), plus drift unit cases incl. old-history tolerance (python
  self-test). `runs/SCHEMA.md` entry added per the session-1 note. Verified in-session:
  both self-tests red→green, Verify block ok, evals 79/79.
- **Verified (2026-07-07, fresh session per G8):** DoD checked line by line.
  (1) Hash subcommand + self-test: `goal_gate.py self-test` fresh pass (exit 0);
  `hash-journeys` exercised bare on the repo's own `docs/goal.md` (→ `{}`, correct:
  the framework goal.md has no `J-NN` blocks) and on a real 3-journey file (three
  64-hex sha256 values); formatting-invariance (trailing whitespace, CRLF) asserted
  inside the self-test. (2) Fixture: `goal-gates.sh --self-test` 14/14 incl. the
  three drift cases — the note is built by the REAL writer from a stale-hash history
  (existence asserted), changed-hash journey demotes GOAL_ACHIEVED→CONTINUE with
  `FAIL drift` recorded in gate-report.md, re-recorded spec_hash certifies, note
  removed → stale hash alone never blocks. (3) Old-history tolerance asserted in the
  python self-test: entry without `spec_hash` never flagged, missing history file →
  no note, drift subcommand tolerates pre-NEED-9 histories, spec_hash-carrying
  history still parses in `cmd_journeys`. (4) Evals green twice — standalone and
  inside the verbatim Verify block — 79 pass / 0 fail each; `bash -n` ok. Wiring
  re-confirmed at the anchors: gate check 6 `goal-gates.sh:145-158`; note builder
  `run-goal.sh:1503-1510` + evaluator dispatch prompt line `:1556`; evaluator
  contract in `body.md` (input #14, `spec_hash` recording rules, GOAL_ACHIEVED drift
  veto) + methodology §A.1; `runs/SCHEMA.md:364` documents journeys-changed.md;
  agent.yaml at 1.4.0; sync --check "would change 0" everywhere; commits 0263ffa
  (slice a) + e0ebb55 (slice b) carry neutral source + mirrors together (G2).
  Cross-check per the verification instructions: /goal-init drive in a scratch repo
  produced a 3-journey goal.md that passes `goal_lint.py` (exit 0),
  `validate_goal_file` extracted verbatim from `run-goal.sh` (PASS), and
  `hash-journeys` (all three journeys hashed); negative controls: absent file and
  placeholder-only Anti-goals both rejected (exit 1, specific errors).
