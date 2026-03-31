# Dev Handoff — Phase N

## Summary

<!-- 2-3 sentences: what was built and what the user can now do. -->

## Files Changed

<!-- List every file created or modified. Used by release-manager to stage the correct files. -->

### New files
- `path/to/new/file.py` — <purpose>

### Modified files
- `path/to/modified/file.py` — <what changed and why>

## Key Design Decisions

<!-- Explain non-obvious choices. "Why X instead of Y?" -->

1. **<Decision>**: <rationale>
2. **<Decision>**: <rationale>

## API Changes

<!-- List new or changed endpoints. Format: METHOD /path — description -->

- `POST /api/v1/<resource>` — <what it does>
- `GET /api/v1/<resource>/{id}` — <what it returns>

## Data Model Changes

<!-- List new tables, columns, or migrations. -->

- New table: `<table_name>` — <purpose>
- Migration: `<migration_file>` — <what it does>

## State Transitions

<!-- List new or changed state machine transitions. -->

- `<entity>`: `<from_state>` → `<to_state>` via `<trigger>`

## How to Test

```bash
# Run backend tests
<test command from project-template.md>

# Start the application
<start command from project-template.md>

# Key endpoints to verify manually
curl http://localhost:<port>/api/v1/<resource>
```

## Known Limitations

<!-- Be honest. What is deferred, approximated, or fragile? -->

- <limitation>

## Next Phase Suggestions

<!-- Optional: what would make sense as the next phase? -->
