# Skill: Visible Change Summarizer

This skill describes how to write user-facing change summaries that operators can understand without developer knowledge.

## Writing Principles

**Write for operators, not developers.**

Operators need to know:
1. What they can now try in the product
2. What looks different from before
3. What they should be cautious about (behavior changes)
4. What is coming later (not visible yet)

**Avoid developer jargon.**

Bad: "Added POST /api/v1/items endpoint with SQLAlchemy model persistence"
Good: "Users can now create new items and they are saved to the database"

Bad: "Refactored the ItemComponent to use useQuery hook"
Good: "The items list now loads faster and updates without page refresh"

Bad: "Implemented JWT authentication middleware"
Good: "Users must now log in to access the dashboard"

## User-Visible Changes Format

### What Users Can Now Do

List each new capability as a user action:
- "Create a new [thing] by clicking [where]"
- "View a list of all [things] at [route]"
- "Delete a [thing] from its detail page"
- "Filter [things] by [criteria] using the search bar"

### What Changed in the Visible UI

List each UI element that changed:
- "The navigation sidebar now includes a '[Things]' link"
- "The '[Thing] Detail' page now shows [new data]"
- "The '[Action]' button moved from [old location] to [new location]"
- "The form on [page] now has a new required field: [field name]"

### What Old Behavior Changed

List behavior that changed for existing users:
- "[Thing] now requires [field] to be filled in — previously it was optional"
- "Deleting a [thing] now asks for confirmation — previously it deleted immediately"
- "The [page] now loads data from the API instead of showing placeholder content"

### What Is Not Visible Yet

List backend capabilities without UI:
- "[Capability] was implemented in the backend but the UI does not yet show it"
- "The API now supports [feature] but there is no UI to use it"

## Quality Bar

Every entry must be:
- Specific: names the thing, not just "the feature"
- User-centric: describes what the user sees or does, not what the code does
- Concrete: can be verified by navigating to a URL or clicking something

## Length Guideline

- "What users can now do": 2–8 bullet points
- "What changed in UI": 2–8 bullet points  
- "What old behavior changed": 0–4 bullet points
- "What is not visible yet": 0–4 bullet points

If you have more than 8 items in any section, prioritize the most impactful.
