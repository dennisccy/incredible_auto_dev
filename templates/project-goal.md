# Project Goal

## Vision
<What is this project? What problem does it solve? One paragraph.>

## Target Users
<Who are the primary users? What are their needs?>

## Success Criteria
<How do you know when the project is successful? Measurable outcomes.>
- <criterion 1>
- <criterion 2>

## Key Capabilities
<What must the finished product be able to do? Prioritized list.>
1. <must-have capability>
2. <must-have capability>
3. <nice-to-have capability>

## Non-Goals
<What is explicitly out of scope for this project?>
- <non-goal 1>
- <non-goal 2>

## Constraints
<Technical, business, or timeline constraints that shape decisions.>
- <constraint 1>
- <constraint 2>

## Design Direction
<What should the product look and feel like? Keywords and references.>
- Visual style: <e.g., cyber-futuristic, minimal-clean, playful>
- Mood: <e.g., professional, high-tech, approachable>
- Reference: <URL or description of a visual reference — screenshot, site, or design system>

## Product Shape
<!--
OPTIONAL but high-leverage (especially for data-heavy apps). Goal mode keeps an app coherent across
many iterations by drafting a "blueprint" at the start — an Information Architecture (how the app is
navigated) and a Data Contract (each shared value has ONE source, so the same number never differs
across pages). The goal-decomposer drafts that blueprint from this section; if you leave this blank,
it proposes one from your journeys, and you review/approve it once at the first pause.

Filling in the canonical values below is the single best way to prevent the "the same metric shows
different numbers on different pages" problem.
-->

### Navigation / information architecture
<The main sections of the app and roughly what lives where. A short tree is enough; or leave blank.>
- <e.g., Dashboard | Strategies | Backtests | Settings>

### Canonical values (single source of truth)
<Values/metrics/entities that must read the SAME everywhere they appear. Name each one; the framework
will pin each to exactly one computing module + one endpoint. Or write "none".>
- <e.g., total return, CAGR, Sharpe ratio — each computed once, displayed everywhere from that source>

## Must-have user journeys
<!--
Required for goal mode (`./scripts/automation/run-goal.sh`). Optional / ignored by phase mode.

These are concrete, browser-testable scenarios. The goal-evaluator agent uses these as
the objective ground truth for "is the product done?" — every journey listed here must
pass via Chrome MCP before the AI evaluator can declare GOAL_ACHIEVED.

Write each journey with:
  - A unique ID (J-01, J-02, ...) used by the iter spec and evaluator log
  - A short name
  - A numbered list of click/type/assert steps the browser-qa-agent can execute
  - An "Acceptance" line describing the observable end state
-->

- **J-01: Sign up and log in**
  - Steps:
    1. Visit `/signup`
    2. Enter `user@example.com` / `password123`
    3. Submit form, expect redirect to `/dashboard`
    4. Click "Log out"
    5. Visit `/login`, enter same credentials, submit, expect `/dashboard` again
  - Acceptance: dashboard greeting shows the user's email address

- **J-02: <next journey>**
  - Steps:
    1. <step>
  - Acceptance: <observable end state>

## Anti-goals
<!--
Required for goal mode. Optional / ignored by phase mode.

These are veto criteria for the goal-evaluator. Even if every Must-have journey passes
in the browser, the evaluator MUST NOT declare GOAL_ACHIEVED if any anti-goal is
violated. Examples of useful anti-goals: security constraints, dependency limits,
licensing rules, performance floors, accessibility minima.

Write anti-goals as concrete, checkable rules — not aspirations. The evaluator
classifies violations as "critical" (halts loop with REGRESSION) or "minor"
(continues with a fix recommendation), so write them tightly enough that the
distinction is clear from context.
-->

- No hard-coded credentials, API keys, or tokens in source files.
- Auth tokens MUST NOT be stored in `localStorage` (use httpOnly cookies).
- No dependency on a paid SaaS service unless explicitly listed in Constraints.
- All form inputs must be keyboard-accessible (no `tabindex="-1"` on focusable controls).
