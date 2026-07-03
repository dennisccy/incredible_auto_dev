# Delegation Templates

Fill-in dispatch prompts for the five common task types. Used by the orchestrator, the
goal-mode pump, and any interactive session dispatching subagents in this repo. Every
template follows the three-part delegation package from `.claude/model-orchestration.md`
(goal+motivation, acceptance criteria, reporting format) — fill every `<...>` slot; delete a
slot only if you replace it with "none".

Rules that apply to ALL templates:
- Pick model/effort per the tier table in `.claude/model-orchestration.md` §1.
- Prompts >8KB: write to a scratch file and dispatch the file-indirection wrapper (§4).
- The subagent returns conclusions + `file:line`; long output goes to a file, reported by path.

---

## 1. Search / locate

```
GOAL: Find <what> in <repo/area>, because <what the answer unblocks>.
SCOPE: Look in <dirs/globs>; ignore <dirs, e.g. runs/, node_modules/>.
ACCEPTANCE:
- Every claim carries file:line.
- Explicitly state what you did NOT find (searched-but-absent is a result).
- If >10 hits, group by role and give counts, not an exhaustive dump.
REPORT: ≤20 lines — one line per finding: `path:line — what it is / why it matters`.
No file contents unless a single line is load-bearing.
```

## 2. Implementation

```
GOAL: Implement <feature/change> in <files/area>, so that <user-visible outcome>.
CONTEXT: Spec/plan at <path>. Follow existing patterns in <reference file>. Stack commands
come from .claude/project-template.md (do not assume paths).
CONSTRAINTS: Touch only <files/area>. No new dependencies unless listed: <list or "none">.
Follow the simplicity bar in .claude/agents/developer.md.
ACCEPTANCE (all binary):
- [ ] <exact test command> exits 0, including new test(s) for <behavior>
- [ ] <endpoint/page/flow> verified by <concrete check — curl call, browser step>
- [ ] No changes outside <scope>
REPORT: files changed (path — one line each), test command + result verbatim, known
issues honestly listed. If blocked: STOP and report the blocker with the failure trace —
do not work around it by weakening the acceptance criteria.
```

## 3. Refactoring

```
GOAL: Refactor <what> to <target shape>, because <cost of current shape>. Behavior must
not change.
BASELINE: Run <test command> BEFORE touching anything; record the pass count. If it is not
green at baseline, STOP and report — never refactor on a red baseline.
CONSTRAINTS: No public API/contract changes unless listed: <list or "none">. No behavior
changes; no drive-by fixes (report them instead).
ACCEPTANCE:
- [ ] Same test suite green after, same count (or more if you added tests)
- [ ] <the specific structural property achieved — e.g., "module X no longer imports Y">
- [ ] Diff reviewable: each commit/step does one mechanical transformation
REPORT: before/after structure (≤10 lines), test evidence before AND after, anything you
deliberately did not touch and why.
```

## 4. Research / investigation

```
GOAL: Answer: <the question>. This decides <the decision it feeds>.
SOURCES: Start with <files/dirs/URLs>; you may follow references one hop out.
ACCEPTANCE:
- Every claim cites its source (file:line, URL, command output).
- Distinguish VERIFIED (you saw it) from INFERRED (you concluded it) from UNKNOWN
  (you looked and could not determine). Unknown is an acceptable answer; guessing is not.
- Contradictory evidence is reported, not smoothed over.
REPORT: Answer first (1-3 sentences), then evidence per claim, then unknowns/caveats.
≤40 lines; anything longer goes to a file, path reported.
```

## 5. Review / verification

```
GOAL: Review <artifact/diff/claim> against <spec/criteria>, adversarially — your job is to
find what is WRONG, not to confirm it is fine. You have fresh context precisely so the
author's framing does not anchor you.
INPUTS: <diff/files/report paths>. The original acceptance criteria: <paste or path>.
METHOD: For each criterion, verify by evidence (run the test, open the file, trace the
code path) — never by the author's claim. Apply the severity rubric in
.claude/agents/reviewer.md (CRITICAL blocks; volume of MINORs does not).
ACCEPTANCE:
- Every finding: file:line + concrete failure scenario + one-line fix.
- Zero findings is a legitimate result ONLY with evidence you actually checked each
  criterion (list what you ran/read per criterion).
REPORT: Verdict line first (PASS / PASS_WITH_NOTES / FAIL), then findings ranked by
severity, then the checked-criteria list.
```
