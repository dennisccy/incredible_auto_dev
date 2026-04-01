# Phase N — Implementation Summary

**Phase:** <phase-id>
**Date:** <YYYY-MM-DD>
**Written by:** developer

---

## Features Implemented

<!-- List each feature or capability added in this phase. Be specific about what it does, not how it works. -->

- **<Feature name>**: <What it does. One sentence.>

---

## Changed Behavior

<!-- List existing functionality that now works differently. Important for regression testing. -->

- **<Existing feature>**: Previously <old behavior>. Now <new behavior>.

<!-- None if no existing behavior changed. -->

---

## Backend-Only Items

<!-- List capabilities implemented in backend but NOT yet wired to the UI. -->
<!-- These are complete implementations that users cannot yet access through the interface. -->

- `<endpoint or model>` — <what it does> — no UI wiring exists yet

<!-- None if all items have corresponding UI. -->

---

## Incomplete Items

<!-- List items from the phase spec that are partially implemented or deferred. -->
<!-- Be honest — do not omit items that are not fully done. -->

- **<Item from spec>**: <What is done vs what is missing>

<!-- None if all spec items are complete. -->

---

## Config and Environment Changes

<!-- List new environment variables, config file changes, or settings. -->

- `ENV_VAR_NAME` — <what it controls> — default: `<value>`
- Migration: `<migration file>` — <what it changes in the schema>

<!-- None if no config changes. -->

---

## Known Limitations

<!-- List constraints, workarounds, or known fragile areas introduced in this phase. -->
<!-- Do not minimize — honest limitations help the reviewer and QA. -->

- <Limitation or workaround>

<!-- None if no known limitations. -->
