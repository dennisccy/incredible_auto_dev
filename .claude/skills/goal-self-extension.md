# Skill: goal-self-extension — appending auto-journeys to `docs/goal.md` safely

Used by the `goal-proposer` agent (goal-mode continuous improvement). It is how the loop grows its own
goal — by appending **new Must-have journeys** into a marker-delimited block of `docs/goal.md` — WITHOUT
ever touching human-authored journeys or the Anti-goals. It reuses the exact surgical-marker method of
the `readme-maintenance` skill.

`docs/goal.md` is the project's constitution and is otherwise human-owned. The ONLY part an agent may
write is the managed block between the markers below. Everything else — every human journey, the Key
Capabilities, and especially the **Anti-goals** — is off-limits.

## The marker convention

A single managed block lives **inside the `## Must-have user journeys` section**, below the
human-authored journeys and above `## Anti-goals`:

```
<!-- AUTO:journeys -->
... (only the goal-proposer writes here; one or more `- **J-NN: …**` journeys) ...
<!-- /AUTO:journeys -->
```

- Match the open/close markers **literally**, including the `AUTO:` / `/AUTO:` prefixes. The marker
  lines themselves are part of the managed region.
- If the block does **not** exist yet, create it ONCE: insert the two marker lines (with nothing between
  them) at the end of the `## Must-have user journeys` section, immediately before the `## Anti-goals`
  heading. Do this with a single surgical Edit whose `old_string` is the `## Anti-goals` heading line and
  whose `new_string` is the empty marker block followed by that same heading.

## Appending a journey (Case B — surgical, marker-only)

1. **Pick the next free id.** Scan `docs/goal.md` for every `J-NN` (human journeys AND any already in the
   AUTO block) and also `journey-history.json`; choose `J-<max+1>` (zero-padded to match the existing
   width, e.g. `J-07`). Never reuse or renumber an existing id.
2. **Write the journey in the existing shape** so the decomposer/evaluator treat it as first-class (they
   parse `goal.md` as free text — no registration step). Match the human journeys' format exactly:
   ```
   - **J-NN: <short title>**
     - Steps: <the click-path / capability to build>
     - Acceptance: <objective, checkable pass criteria>
   ```
   Bake the project's hard requirements into **Acceptance** (e.g. the consistency rule — reads the
   canonical endpoint / registers any new shared value in the Data Contract — and the walkthrough
   requirement — a `[NEW]`-flagged demo-narrator walkthrough of the new surface).
3. **Edit only the marker block.** Use `Edit` with the WHOLE current marker-delimited block as
   `old_string` and the same block with your journey appended as `new_string`. Do not touch a single byte
   outside the markers. Re-read the block first so your `old_string` matches verbatim.
4. **Idempotency.** Before appending, confirm an equivalent journey (same target capability) is not
   already present in the block or elsewhere in `goal.md`. If it is, do not duplicate it.

## Hard rules

- Edit `goal.md` **only** between `<!-- AUTO:journeys -->` and `<!-- /AUTO:journeys -->` (or the one-time
  block creation in step "marker convention"). Never modify human journeys, Key Capabilities, or
  Anti-goals — they are the constitution.
- Never rename the `## Must-have user journeys` heading or change the `J-NN` bullet shape.
- Append at most 1–2 journeys per cycle; keep each small and buildable.
- If you have nothing worth promoting, **leave `goal.md` untouched** — an empty extension is the correct,
  honest outcome (the loop then finalizes).
