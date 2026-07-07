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
