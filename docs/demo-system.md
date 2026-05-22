# Demo system — layered author + deterministic runner

This is the internals reference for the product-demo feature. For *how to run it
and what to expect*, see the "Watch your app" section of the [README](../README.md).

## Why it is layered

The earlier design had a single agent drive Chrome live, deciding each
`navigate`/`click`/`type`/`screenshot` through the model over MCP round-trips.
That was slow, frequently mis-resolved elements, and **looped** when a step's
result didn't match the model's expectation. The fix is to split the work:

```
   AUTHOR (LLM, no browser)                 EXECUTOR (Playwright, no LLM)
   demo-narrator agent          demo.json   scripts/automation/lib/demo_runner.py
   reads verified QA flows  ─────────────▶  drives Chrome deterministically
   writes one JSON file                     live (Enter-to-advance) | record (headless)
```

- The **author** never opens a browser, so it can't loop and is cheap to run.
- The **executor** never calls the model, so it's fast and deterministic; the only blocking primitive in live mode is the user's `Enter` keypress.

`scripts/automation/demo-phase.sh` is the conductor: it boots the app
(idempotent), runs the author (cached — skipped when `reports/phase-<id>-demo.json`
is newer than the QA artifacts, unless `--reauthor`), then runs the executor.

## Reliability levers

1. **Verified flows as the source.** The author builds steps from flows browser-QA already passed this iteration (`reports/phase-<id>-ui-test-{plan,results}.md`, `-what-to-click.md`). A step that traces to a PASS `UT-XX` is marked `verified: true`.
2. **Semantic locators.** QA records exact visible text / field labels / URLs (not CSS). Playwright's `get_by_role` / `get_by_text` / `get_by_label` match on the same accessible-name abstraction, so a passing QA flow maps cleanly. The runner auto-degrades role→text→label, so the author writes a single hint.
3. **Auto-wait.** Playwright waits for actionability before each interaction — the single biggest fix for the old "act before the page is ready" flakiness.
4. **Relative URLs + base_url rewrite.** `goto` URLs are relative; the runner joins them to the real base URL and rewrites any stray absolute `localhost:*` URL. This is correct even when the start scripts use an offset dev-port (e.g. `:3017`).
5. **Bounded soft-skip.** A step that can't be performed within its timeout is logged as a soft note and skipped — never retried in a loop. The demo is showcase, never a pipeline gate.

## The executable demo-script JSON

Written by the author to `reports/phase-<id>-demo.json` (session mode:
`reports/goal-session-<sid>-demo.json`). The runner validates it and degrades to
a `SKIPPED` result on any problem.

```jsonc
{
  "schema_version": 1,
  "phase_id": "goal-money-iter-3",
  "base_url": "http://localhost:3000",   // informational; runner --base-url wins
  "iteration": 3,                          // optional (goal mode)
  "default_timeout_ms": 8000,              // clamped to [1000, 20000]
  "not_yet": false,                        // true → "nothing to show yet" (steps may be empty)
  "steps": [
    {
      "n": 1,                              // 1-based; maps to step-01.png
      "title": "Open the dashboard",
      "narration": "We start on the home dashboard.",
      "point_out": "the 'New Report' button in the sidebar",
      "journey": "J-04",                  // J-XX or "" ; groups the session feature gallery
      "new": true,                         // [NEW] badge
      "verified": true,                    // traces to a PASS UT this iteration
      "section": "highlights",             // "highlights" (screenshotted, cap 8) | "full_tour" (text-only; live plays it)
      "timeout_ms": 8000,                  // optional per-step override
      "action": { "type": "goto", "url": "/" },
      "expect": { "text": "Dashboard" }    // optional soft assertion → drives the verdict
    }
  ]
}
```

### Actions the author emits (only these)

| `type` | fields | notes |
|---|---|---|
| `goto` | `url` (relative path) | runner joins base_url + rewrites absolute localhost |
| `click` | `target` | auto-waits actionable |
| `fill` | `target`, `text` | auto-waits actionable |
| `expect` (per-step, optional) | `text` or `target` | soft; miss → soft note, never raises |

The runner itself handles waiting, element highlighting (live), screenshots
(record), and selector degradation — they are **not** author responsibilities.

### `target` shapes

`{role,name}` | `{text}` | `{label}` | `{placeholder}` | `{css}` (+ optional `nth`).
`resolve_spec()` maps these to an ordered list of locators (primary, then
degraded) which `demo_runner._find` tries in turn within a bounded budget.

## Runner CLI

```
python3 scripts/automation/lib/demo_runner.py \
  --json <demo.json> --mode live|record|session-live \
  --base-url <url> --out-dir reports/demo/<id> \
  --results <demo-results.md> --script-fallback <demo-script.md> \
  --repo-root <root> [--phase-id <id>] [--video] [--caption]

python3 scripts/automation/lib/demo_runner.py self-test   # no browser; in run-evals.sh
```

**Exit codes:** `0` ok / soft-skip · `2` bad args or invalid JSON · `3` Playwright
missing · `4` live mode with no `$DISPLAY`. `demo-phase.sh` maps 3/4 to a soft
SKIPPED and exit 0 (showcase never halts the pipeline).

### Output the runner writes (renderer-compatible)

The runner regenerates `demo-script.md` (captions) and `demo-results.md`
(verdict + Captured Steps table + soft notes) from the JSON so the existing
`render_iteration_summary.py` gallery renderer needs **no changes**. Verdict:
`RECORDED` (all matched) · `RECORDED_WITH_NOTES` (≥1 soft note) · `SKIPPED`
(nothing capturable) · `NOT_YET` (`not_yet: true`).

## Playwright on a fresh machine

The runner uses Playwright for Python. Browsers cache under
`~/.cache/ms-playwright`. If the import fails the runner prints:

```
python3 -m pip install --user playwright
# if the browser binary is missing too:
python3 -m playwright install chromium
```

It never installs silently (avoids polluting target projects and respects the
repo install gate).

## Env knobs

| Var | Effect |
|---|---|
| `CHAIN_DEMO_VIDEO=true` | record mode also saves a `.webm` video (ffmpeg from the Playwright cache) |
| `CHAIN_DEMO_CAPTION=true` | live mode overlays the current narration as an on-page banner |
| `CHAIN_DEMO_LIVE_FALLBACK_RECORD=true` | live mode with no display auto-falls back to record instead of erroring |

## Tests

- `demo_runner.py self-test` — pure logic (URL normalize, validation incl. `not_yet`, selector mapping, verdict, markdown emission, and a round-trip through the real renderer's parsers). Wired into `scripts/automation/run-evals.sh`.
- Hermetic browser checks: drive a local static page in record mode and assert screenshots + a parseable `demo-results.md`; a deliberately-bad selector must soft-skip and finish promptly (proves no loop/hang).
