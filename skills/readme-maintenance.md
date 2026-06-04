# README Maintenance (marker-scoped)

How to keep a project's `README.md` current **without ever destroying a human's
hand-written content**. Used by the `readme-maintainer` agent each iteration in
goal mode. The technique: manage only two HTML-comment-delimited regions and leave
everything else untouched.

## The managed markers

Exactly two regions are yours to write. Everything outside them is off-limits.

```
<!-- AUTO:capabilities -->
## What it does
... (you own this) ...
<!-- /AUTO:capabilities -->

<!-- AUTO:how-to-run -->
## How to run
... (you own this) ...
<!-- /AUTO:how-to-run -->
```

Match the open/close markers literally, including the `AUTO:` / `/AUTO:` prefixes.
The marker lines themselves are part of the managed region — keep them so the next
run can find the block again.

## The three cases

**Case A — `README.md` is absent.** Copy `templates/project-readme.md` to
`README.md`, set the title and one-line description from `docs/goal.md` (fall back
to the repo directory name), then fill the two AUTO blocks. The template already
contains the markers in the right places.

**Case B — `README.md` exists and contains the markers.** Replace ONLY the text
between each `<!-- AUTO:x -->` and its matching `<!-- /AUTO:x -->`. Do not touch a
single byte outside the markers — not the intro, not badges, not the license line.
Use Edit with the whole marker-delimited block as the `old_string` so the change is
surgical.

**Case C — `README.md` exists but has NO markers.** Insert the two managed blocks
without deleting any existing prose. Put the capabilities block just after the
project's intro/first paragraph, and the how-to-run block as a new section below it.
If the README already has a hand-written "How to run" / "Getting started" section,
place the managed block adjacent to it rather than duplicating — prefer adding your
markers around content you are taking over, and leave genuinely separate human
sections alone.

## Filling the "capabilities" block

- Source from `reports/phase-<id>-user-visible-changes.md`,
  `-implementation-summary.md`, and `-iteration-summary.md` (read what exists).
- Describe the product **as it stands now**, cumulatively — a short paragraph plus a
  bullet list of what a user can do. No file names, no agent names, no journey IDs,
  no verdict words.

## Filling the "how-to-run" block

- Every command is copied or faithfully derived from `.claude/project-template.md`:
  Stack, Test commands, Service start commands, and Backend/Frontend URLs.
- Cover, in order: prerequisites → install → start backend → start frontend → run
  tests → local URLs. Use fenced code blocks with the real commands.
- If a required field in `project-template.md` is still an unfilled placeholder
  (it looks like `<e.g., ...>`), do NOT invent a command. Emit a visible marker
  instead, for example `<!-- TODO: set 'Start backend' in .claude/project-template.md -->`,
  and continue with the fields that are filled.

## Safety and idempotency

- Edit only `README.md`. Never modify code, config, or other docs.
- Running again with no project change must yield no diff — write stable, ordered
  content (same bullet order, same command order) so re-runs are clean.
- Confirm project structure with Glob/Grep (entry points, top-level dirs) before
  describing it; do not assume a layout.
