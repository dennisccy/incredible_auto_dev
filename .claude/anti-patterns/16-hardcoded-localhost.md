## 16. Hardcoded localhost in service configuration breaks non-local access

**Pattern:** API URLs, CORS origins, and service bindings all use `localhost` or `127.0.0.1`. Works on the dev machine's browser. Breaks when accessed from another machine via private IP, from a VM host, through Docker, or behind a reverse proxy.

**Why it fails:** The frontend sends API requests to the hardcoded `localhost:8000`. A user on another machine resolves `localhost` to their own loopback — the backend isn't there. Even if the backend is reachable by IP, restrictive CORS blocks the request. Even if CORS allows it, the backend only listens on `127.0.0.1` and rejects non-loopback connections.

**Prevention:** Reviewer checklist flags any hardcoded `localhost`/`127.0.0.1` in:
- API client URLs → must be configurable via env var or derived dynamically (e.g., `window.location.hostname`)
- CORS origins → must use `*`, a port-range regex (e.g. `http://(localhost|127\.0\.0\.1):\d+`), or be configurable in dev mode
- Service bindings → dev scripts must bind to `0.0.0.0`, not `127.0.0.1`
- Dev scripts (`dev.sh`, `start-frontend.sh`) → must pass host/port via env var, not hardcoded URL strings

**Sub-pattern — auto-dev-chain port drift:** `ensure_phase_ports` in `lib/common.sh` assigns a hashed preferred port and falls back to the next free port if taken (e.g., 3101 → 3102 when a stale server holds 3101). A CORS whitelist of specific ports (e.g. `[..., "http://localhost:3101"]`) will reject the fallback port and the QA/browser-QA frontend will fail to fetch data, while `curl` still works. Use a regex or env-driven allowlist so any dev port works.

**Example (bad):** `const API_BASE = "http://localhost:8000"` — works only from the same machine.
**Example (good):** `const API_BASE = \`http://${window.location.hostname}:${API_PORT}\`` — works from any hostname the user accesses the frontend with.
**Example (CORS bad):** `allow_origins=["http://localhost:3101"]` — breaks when chain falls back to 3102.
**Example (CORS good, FastAPI):** `allow_origin_regex=r"http://(localhost|127\.0\.0\.1):\d+"`.

---

