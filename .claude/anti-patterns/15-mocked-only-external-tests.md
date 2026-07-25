## 15. Mocked-only tests for external integrations pass while live adapter is broken

**Pattern:** Adapter tests mock all HTTP/browser calls. Tests pass. But the real site changed its HTML structure, blocks headless browsers, or requires auth. No one discovers this until manual testing.

**Why it fails:** Mocked tests validate the parsing logic against a frozen snapshot of the external system. They never detect selector drift, bot detection, geo-blocking, or TLS fingerprint rejection. 100% mocked test coverage gives false confidence that the integration works.

**Prevention:** For phases that add external integrations (scrapers, APIs, webhooks), the developer must include at least one test marked `@pytest.mark.integration` (or equivalent) that hits the real external system. QA functional test plan must include a live integration test case. These tests may be slow/flaky and skipped in CI, but must exist and be run at least once during the phase. The dev handoff must explicitly state whether live testing was successful or document the blocker if it wasn't.

**Example (bad):** All Tesco adapter tests use `_build_tile_html()` fixtures. Tests pass. Tesco changes its CSS classes → live adapter returns 0 results. Bot detection blocks headless Playwright → adapter gets HTTP 403. Neither is caught until a human clicks through the UI.

**Example (good):** One test marked `@pytest.mark.integration` calls `TescoAdapter().search("milk")` against the real Tesco site and asserts `len(results) > 0`. This test is slow but catches selector drift, bot detection, and infrastructure issues immediately.

---

