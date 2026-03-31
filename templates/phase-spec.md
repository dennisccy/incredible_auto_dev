# Phase N — <Phase Name>

## GOAL

<!-- One sentence: what capability does this phase deliver to the user? -->
<what users can now do that they could not before>

## BACKGROUND

<!-- Optional: why this phase now, what does it depend on? -->

## IN SCOPE

### Backend
- [ ] <specific API endpoint or service>
- [ ] <data model change>
- [ ] <state transition logic>

### Frontend (if applicable)
- [ ] <new page or component>
- [ ] <UI surface that exposes the new capability>
- [ ] Navigation updated to include link to new entity/workflow

### New user-facing capability
<!-- Required: what can the user now see or do? -->

### New information displayed
<!-- Required: what data is newly visible in the UI? -->

### New user actions
<!-- Required: what buttons, forms, or controls are added? -->

### UI surface changes
<!-- Required: what page, panel, card, or workflow is added or improved? -->

### Product surface delta
<!-- Required: how does the overall product experience change? -->

## OUT OF SCOPE

- <explicit exclusion>
- <explicit exclusion>

## DEFINITION OF DONE

- [ ] All in-scope items implemented and tested
- [ ] Unit tests pass (backend)
- [ ] No regressions in existing tests
- [ ] API endpoints return correct responses for valid and invalid inputs
- [ ] State transitions validated server-side and rejected when invalid
- [ ] UI surfaces the new capability (not just triggering an API call)
- [ ] Navigation updated if a new top-level entity was introduced
- [ ] Chrome MCP browser tests pass for key user flows
- [ ] Dev handoff written at `docs/handoffs/<phase>-dev.md`
- [ ] QA verdict: PASS

## TESTING REQUIREMENTS

<!-- Specify what must be tested, not how. The test-plan-generator agent will create the test plan. -->

- API: <what endpoints must be verified>
- State: <what transitions must be tested>
- Error cases: <what invalid inputs or forbidden transitions must be rejected>
- Browser: <what user flows must be verified via Chrome MCP>

## NOTES

<!-- Optional: constraints, decisions, references to prior phases. -->
