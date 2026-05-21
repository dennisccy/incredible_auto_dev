# App Blueprint — <session-id>

<!--
This is the coherence contract for the whole app. The goal-decomposer drafts it at baseline; you
approve it once (edit anything, then `--resume`); the coherence-auditor enforces it every iteration.

KEEP IT SHORT — one screen for a typical app. It must be reviewable in ~3 minutes. A sprawling
blueprint defeats the human-approval step and is harder to enforce.

REVIEW CHECKLIST (what to check before you resume):
  1. Information Architecture — are the nav sections sensible, and does every feature have an
     obvious home? Anything you'd struggle to find?
  2. Data Contract — is every "should-be-the-same-number-everywhere" value listed with exactly ONE
     source? Add any the AI missed; fix any wrong source. (This is what prevents the same value
     showing different numbers on different pages.)
-->

## Information Architecture

**Layout shell:** <e.g., left sidebar + main content; top nav + content; single-page dashboard>

**Navigation skeleton** (the persistent nav — every feature lives under one of these):

```
<App>
├── <Section A>        e.g. Dashboard
├── <Section B>        e.g. Strategies
│   ├── <sub-page>
│   └── <sub-page>
├── <Section C>        e.g. Backtests
└── <Section D>        e.g. Settings
```

**Feature / journey homes** (each must be reachable in ≤2 clicks from the nav):

| Feature / journey | Canonical home (route) | Nav section |
|---|---|---|
| <J-01 / feature> | `/<route>` | <Section> |
| <J-02 / feature> | `/<route>` | <Section> |

## Data Contract

Every value that appears in the UI and should read the same everywhere is registered here with **one**
canonical computing source and **one** serving endpoint. No page may recompute or re-fetch these from
anywhere else; UI may only re-format what the canonical endpoint returns.

| Value / entity | Computed by (single module/function) | Served by (single endpoint) | Notes |
|---|---|---|---|
| <e.g. total return> | `<module.path:function>` | `GET /<endpoint>` | <unit/format> |
| <e.g. Sharpe ratio> | `<module.path:function>` | `GET /<endpoint>` | <window/assumptions> |

<!-- For apps with no shared numeric/derived values, write "No shared canonical values." and leave the
table empty. The IA section still applies. -->
