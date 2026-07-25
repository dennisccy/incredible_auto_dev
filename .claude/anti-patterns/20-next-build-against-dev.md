## 20. `next build` against a live `next dev` corrupts `.next` and SKIPs the demo

**Pattern:** A production `next build` (or a typecheck/lint step that triggers a build) runs while the demo/QA `next dev` server is up. Both write the **same** `apps/frontend/.next` directory, so the build deletes/renames the webpack chunks the dev server is serving. The dev server then answers **every** request with HTTP 500 (`MODULE_NOT_FOUND`, a require stack through `.next/server/...`/`webpack-runtime.js`) and never recovers on its own. The per-iteration demo / browser-QA then report "Frontend did not respond after 90s of retries" and record **SKIPPED**, even though the server is up — it is just 500ing.

**Why it fails:** `next dev` lazily reads compiled chunks from `.next`; a concurrent `next build` clobbers them. The corruption is sticky — only removing `.next` and letting `next dev` rebuild fixes it. In the post-dev fanout this cascades: the shared-services boot tries to start the frontend, fails on the corrupt build, kills it, and every parallel branch (demo, browser-qa) then waits out its readiness budget against a dead port.

**Prevention (harness side, already done):** the harness now self-heals. `_start_service_with_retries` (in `scripts/automation/lib/common.sh`) detects the corrupt-`.next` signature, clears `.next`, and grants one guaranteed-cold rebuild attempt with a longer budget (`CHAIN_FRONTEND_HEAL_TIMEOUT`, default 180s) instead of killing a still-compiling server; `_kill_pid_tree` now escalates TERM→KILL so a surviving worker can't re-corrupt `.next` or squat the port; and the readiness gate `_wait_for_frontend_ready` heals once on the standalone path. Recovery costs a full cold compile per occurrence, so it is a cost, not a free pass.

**Prevention (project side, optional but better):** give build/QA/typecheck commands their own dist dir so they never touch the dev build. Next.js reads `distDir` from `next.config.{js,ts}` (NOT an env var by default), so wire it through config — e.g. `distDir: process.env.NEXT_DIST_DIR || '.next'` — and run builds with `NEXT_DIST_DIR=.next-qa next build`. Agents MUST NOT run a production `next build` while the demo/QA `next dev` is up unless the build is isolated this way.

**Detection:** the frontend start log (`$QA_FRONTEND_LOG` — under the run's `CHAIN_TMPDIR`, e.g. `.../fanout-frontend-<port>.log`) showing `MODULE_NOT_FOUND` / `Cannot find module` with a `GET / 500` and a `.next/server/...` require stack is the signature. `_next_build_is_corrupt` in `common.sh` greps for exactly this.

---

