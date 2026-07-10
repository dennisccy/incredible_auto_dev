# todo-app — EVO-3 benchmark fixture (bare scaffold)

This directory is the **fixture project** for the framework's automated benchmark
harness (`docs/improvement-roadmap.md` EVO-3). It is a runnable but deliberately
BARE Flask scaffold: the Must-have journeys in `docs/goal.md` (add a todo, toggle
done with persistence, filter open/done) are **intentionally unimplemented**. The
benchmark measures the goal-mode chain BUILDING those journeys, not verifying
pre-built ones — feature code checked in here would corrupt the measurement.

What ships: `app.py` (shell page, `/health`, and the runtime-created `todos.json`
store primitive), a minimal `templates/index.html` + `static/app.js` shell,
scaffold tests (`test_app.py` — green on the bare tree), a filled
`.claude/project-template.md`, and a goal_lint-clean `docs/goal.md`.

## How the benchmark consumes it (slice (b), not yet built)

`scripts/automation/run-benchmark.sh` will: copy this directory to a scratch dir →
`git init` there → run `run-goal.sh --session-id bench-<date> --max-iter 2`
headless → extract metrics into `benchmarks/results/`. Never run the engine
against this directory in place, and never `git init` here — the scratch copy is
the run target. Every benchmark run spends real API tokens (G9: confirm with the
user first).

## Hand-verify the scaffold

```bash
cd benchmarks/fixtures/todo-app
python3 -m venv .venv && .venv/bin/pip install flask pytest    # once
.venv/bin/python -m pytest -q                                  # 3 tests green
.venv/bin/python app.py &                                      # serves 127.0.0.1:5177
curl -s http://127.0.0.1:5177/health                           # {"status":"ok"}
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5177/  # 200
kill %1
python3 ../../../scripts/automation/lib/goal_lint.py docs/goal.md  # exit 0, silent
```

`todos.json` (runtime store), `.venv/`, `__pycache__/`, and `.pytest_cache/` are
gitignored; delete them freely.

## Nesting note

The `.claude/project-template.md` and `docs/goal.md` in this tree are FIXTURE
CONTENT for the app-under-benchmark (same precedent as `tests/judgment/*/tree/`).
Framework tooling — `sync-cli-assets.py`, the eval suite — must never treat them
as this repo's own configuration. The fixture is authored independently of the
judgment fixtures: same proven stack shape, zero shared files, so the two eval
assets can never drift into coupling.
