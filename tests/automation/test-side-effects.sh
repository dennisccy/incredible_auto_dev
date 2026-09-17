#!/usr/bin/env bash
# test-side-effects.sh — HARD-3: journey side-effect model + contradiction preflight.
#
# Invariants under test (plan WP3 §5):
#   * every journey has a side-effect status in {none, mutating, unknown}, derived from the
#     owner's optional goal.md line `- Side effects: none | mutating — <note>` AND from
#     deterministic replay observation — an observed mutation always outranks a `none`;
#   * an explicit no-mutation prohibition (OUT OF SCOPE / TC- / DoD) that meets a known-mutating
#     target or required journey blocks BEFORE any dispatch whatever the spec's
#     `Side-effect policy` says (E16) — flipping `none` to `allowed` never bypasses it;
#   * `Side-effect policy: none` never dispatches over a mutating journey (E13) and fails CLOSED
#     when its deterministic ledger is unavailable (E15, not re-plannable);
#   * `unknown` never blocks unless CHAIN_SIDE_EFFECT_STRICT=true (W09/W10 -> E14);
#   * a WELL-FORMED declaration is journey-hash-neutral but declaration-digest-visible; a
#     malformed one is journey text (drift) and digest-visible;
#   * an observed mutation stays until a complete clean replay of the SAME golden, per-run records
#     are never deleted, and unreadable observations never read as `none`;
#   * CHAIN_SPEC_LINT=warn never relaxes E15;
#   * prompts are byte-identical when no side-effect context applies.
#
#   C. classifier + observer units (lib/demo_runner.py)
#   S. sidecar read-modify-write (lib/demo_runner.py)
#   D. declarations, spec_hash invariance, declaration digest, ledger (lib/goal_gate.py)
#   G. goal_lint.py rules
#   L. iter_spec.py preflight rules, incl. the exact TenSteps iteration-9 contradiction
#   O. the observer end-to-end through the REAL run_verify (fake Playwright)
#   E. the REAL run-goal.sh engine in a sandbox (ordering, re-plan, fail-closed, telemetry)
#   P. browser-lane / evaluator prompt capture, with and without context
#   W. wiring greps
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$ENGINE_ROOT/scripts/automation/lib"
PROBE="$LIB/iter_spec.py"
GG="$LIB/goal_gate.py"
GL="$LIB/goal_lint.py"
RG="$ENGINE_ROOT/scripts/automation/run-goal.sh"
PASS=0; FAIL=0
assert() {  # assert <name> pass|fail
  if [[ "$2" == "pass" ]]; then PASS=$((PASS+1)); echo "  PASS  $1"
  else FAIL=$((FAIL+1)); echo "  FAIL  $1"; fi
}
WORK="$(mktemp -d)"
# Only processes this test started, by recorded pid — never a pattern sweep
# (HARD-5: an owner-blind kill in a test harness is still an owner-blind kill).
DUMMY_PIDS=()
cleanup() {
  local _p
  for _p in ${DUMMY_PIDS[@]+"${DUMMY_PIDS[@]}"}; do kill "$_p" 2>/dev/null || true; done
  chmod -R u+rwX "$WORK" 2>/dev/null || true
  if [[ -n "${SE_TEST_KEEP_WORK:-}" ]]; then echo "(kept work dir: $WORK)"; return 0; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# run_py_cases: python on stdin prints "pass<TAB>name" / "fail<TAB>name" lines.
# A crash (RED phase: missing function) fails the block loudly instead of passing
# vacuously.
run_py_cases() {
  local _out _st _name _n=0
  _out="$(cd "$WORK" && PYTHONPATH="$LIB${PYTHONPATH:+:$PYTHONPATH}" python3 - 2>&1)"
  while IFS=$'\t' read -r _st _name; do
    case "$_st" in
      pass|fail) assert "$_name" "$_st"; _n=$((_n+1)) ;;
    esac
  done <<< "$_out"
  if [[ "$_n" -eq 0 || "$_out" == *Traceback* ]]; then
    assert "python case block ran to completion ($(printf '%s' "$_out" | grep -v -E '^(pass|fail)	' | tail -4 | tr '\n' ' '))" "fail"
  fi
}

# ── Part C: classifier + observer units ──────────────────────────────────────
echo "== C. classify_request + observer units"
run_py_cases <<'PY'
import os
def case(name, cond):
    print(("pass" if cond else "fail") + "\t" + name)
from demo_runner import (classify_request, SideEffectRecorder, parse_readonly_endpoints,
                         side_effect_ignore_paths, render_side_effect_suffix)
FE, BE = "http://localhost:3017", "http://localhost:8017"
case("C1: same-project POST fetch -> mutating", classify_request("POST", "fetch", FE + "/api/runs", FE) == "mutating")
case("C2: a GET is never a side effect", classify_request("GET", "fetch", FE + "/api/runs", FE) is None)
case("C3: a POST sub-resource request (image, script, stylesheet) is ignored (resource type)",
     all(classify_request("POST", t, FE + "/api/x", FE) is None for t in ("image", "script", "stylesheet")))
case("C3b: every write channel counts — beacons (ping) and unclassified (other) requests too",
     all(classify_request("POST", t, FE + "/api/drafts", FE) == "mutating" for t in ("ping", "beacon", "other")))
case("C4: development-asset POSTs are ignored (/_next/, /__nextjs, /sockjs-node, /@vite, /__vite)",
     all(classify_request("POST", "fetch", FE + p, FE) is None
         for p in ("/_next/data/x.json", "/__nextjs_original-stack-frame", "/sockjs-node/info",
                   "/@vite/client", "/__vite_ping")))
case("C5: a POST to the backend port from the frontend base is the same project -> mutating",
     classify_request("POST", "xhr", BE + "/api/runs", FE) == "mutating"
     and classify_request("PUT", "fetch", "http://127.0.0.1:8017/api/runs/1", FE) == "mutating"
     and classify_request("PATCH", "fetch", FE + "/api/runs/1", FE) == "mutating"
     and classify_request("DELETE", "fetch", FE + "/api/runs/1", FE) == "mutating")
case("C5b: a form POST navigation (resource type document) is a mutation",
     classify_request("POST", "document", FE + "/runs/new", FE) == "mutating")
case("C6: a POST to an external analytics host is ignored",
     classify_request("POST", "fetch", "https://analytics.example.com/collect", FE) is None)
case("C7: POST /api/login -> ignored-auth", classify_request("POST", "fetch", FE + "/api/login", FE) == "ignored-auth")
case("C7b: the default auth list covers logout/auth/session/token/csrf, behind an optional /api[/vN] prefix",
     all(classify_request("POST", "fetch", FE + p, FE) == "ignored-auth"
         for p in ("/logout", "/auth/callback", "/api/session", "/api/v1/token", "/csrf",
                   "/api/auth/callback/credentials"))
     and classify_request("DELETE", "fetch", FE + "/api/session", FE) == "ignored-auth")
case("C7d: an auth word deeper in the path, a PUT/PATCH, or a resource id is a real mutation",
     all(classify_request(m, "fetch", FE + p, FE) == "mutating" for m, p in (
         ("PATCH", "/api/chat/session/7"), ("DELETE", "/api/workouts/session/9"),
         ("POST", "/api/trading/session/start"), ("POST", "/api/users/42/token"),
         ("POST", "/api/api-keys/token"), ("PUT", "/api/settings/auth"), ("PUT", "/api/session"),
         ("PATCH", "/api/auth/password"), ("DELETE", "/api/auth/users/5"))))
case("C7c: an auth word that is only part of a segment is still a mutation",
     classify_request("POST", "fetch", FE + "/api/login-history/clear", FE) == "mutating"
     and classify_request("POST", "fetch", FE + "/api/sessions", FE) == "mutating")
os.environ["CHAIN_SIDE_EFFECT_IGNORE_PATHS"] = "/signin, /api/refresh"
case("C8: CHAIN_SIDE_EFFECT_IGNORE_PATHS REPLACES the default list",
     classify_request("POST", "fetch", FE + "/api/signin", FE) == "ignored-auth"
     and classify_request("POST", "fetch", FE + "/api/login", FE) == "mutating"
     and side_effect_ignore_paths() == ("/signin", "/api/refresh"))
os.environ["CHAIN_SIDE_EFFECT_IGNORE_PATHS"] = ""
case("C8b: a SET-empty override disables every auth exclusion (distinct from UNSET)",
     classify_request("POST", "fetch", FE + "/api/login", FE) == "mutating" and side_effect_ignore_paths() == ())
del os.environ["CHAIN_SIDE_EFFECT_IGNORE_PATHS"]
case("C8c: UNSET restores the documented default list",
     side_effect_ignore_paths() == ("/login", "/logout", "/auth", "/session", "/token", "/csrf"))
from demo_runner import side_effect_ignore_paths_report
eff, rej = side_effect_ignore_paths_report({"CHAIN_SIDE_EFFECT_IGNORE_PATHS": "/login, /api, api/v1, /, /v2"})
case("C8d: an override naming '/' or an API root (/api, api/v1, /v2) is REJECTED and reported, never applied",
     eff == ("/login",) and rej == ("/api", "api/v1", "/", "/v2")
     and classify_request("POST", "fetch", FE + "/api/runs", FE, ignored_paths=eff) == "mutating")
entries, invalid = parse_readonly_endpoints(
    "# owner-authored read-only endpoints\n"
    "POST /api/policy/evaluate\n"
    "\n"
    "put /api/preview   # trailing comment\n"
    "GET /api/x\n"
    "POST\n"
    "POST /\n"
    "POST api/no-slash\n")
case("C9: exception file: one 'METHOD /path-prefix' per line; comments and blanks ignored",
     ("POST", "/api/policy/evaluate") in entries and ("PUT", "/api/preview") in entries and len(entries) == 2)
case("C9b: invalid exception lines are REPORTED and never applied (GET, no path, bare '/', relative)",
     len(invalid) == 4 and {i[0] for i in invalid} == {5, 6, 7, 8})
case("C10: a listed read-only POST -> ignored-readonly",
     classify_request("POST", "fetch", FE + "/api/policy/evaluate", FE, readonly_endpoints=entries) == "ignored-readonly")
case("C10b: exceptions match on whole path segments (…/evaluate/42 yes, …/evaluate-and-save no)",
     classify_request("POST", "fetch", FE + "/api/policy/evaluate/42", FE, readonly_endpoints=entries) == "ignored-readonly"
     and classify_request("POST", "fetch", FE + "/api/policy/evaluate-and-save", FE, readonly_endpoints=entries) == "mutating")
case("C10c: exceptions are method-specific (DELETE on a POST exception stays mutating)",
     classify_request("DELETE", "fetch", FE + "/api/policy/evaluate", FE, readonly_endpoints=entries) == "mutating")
case("C10d: a dot-segment path never matches an exception or an auth exclusion (conservative)",
     classify_request("POST", "fetch", FE + "/api/policy/evaluate/../../runs", FE, readonly_endpoints=entries) == "mutating"
     and classify_request("POST", "fetch", FE + "/api/runs/%2e%2e/login", FE) == "mutating")
case("C11: the SAME read-only POST with no exception file is mutating",
     classify_request("POST", "fetch", FE + "/api/policy/evaluate", FE, readonly_endpoints=()) == "mutating")
case("C11b: an encoded separator or backslash never rides a dev-asset, auth or read-only exemption",
     classify_request("POST", "fetch", FE + "/_next/..%2Fapi/runs", FE) == "mutating"
     and classify_request("POST", "fetch", FE + "/api/policy/evaluate%2F..%2Fsave", FE, readonly_endpoints=entries) == "mutating")
case("C11c: with a local base, LAN / private / loopback / single-label / .local backends are the same project",
     all(classify_request("POST", "fetch", h + "/api/runs", FE) == "mutating" for h in (
         "http://192.168.1.20:8000", "http://10.1.2.3", "http://127.0.0.2:9000", "http://myhost:8000",
         "http://app.local", "http://[::1]:8000"))
     and classify_request("POST", "fetch", "http://93.184.216.34/api/runs", FE) is None)
class Req:
    def __init__(self, m, t, u):
        self.method, self.resource_type, self.url = m, t, u
rec = SideEffectRecorder(FE, readonly_endpoints=entries)
for r in (Req("GET", "document", FE + "/"), Req("POST", "fetch", FE + "/api/runs?x=secret"),
          Req("POST", "fetch", FE + "/api/runs"), Req("POST", "fetch", FE + "/api/login"),
          Req("POST", "fetch", FE + "/api/policy/evaluate"), Req("POST", "image", FE + "/px")):
    rec.on_request(r)
s = rec.summary()
case("C12: the recorder counts per class and keeps only {method, path} (no query string, no body)",
     s["mutating_count"] == 2 and s["auth_count"] == 1 and s["readonly_count"] == 1
     and {"method": "POST", "path": "/api/runs", "class": "mutating", "count": 2} in s["requests"]
     and "secret" not in repr(s))
case("C12b: an applied read-only exception is retained as evidence",
     s["exceptions_applied"] == [{"method": "POST", "path": "/api/policy/evaluate"}])
case("C12c: an applied auth exclusion is retained as evidence too",
     s["auth_ignored"] == [{"method": "POST", "path": "/api/login"}])
class Broken:
    @property
    def method(self):
        raise RuntimeError("boom")
rec.on_request(Broken())
case("C13: an observer exception is swallowed per request and counted",
     rec.summary()["observer_errors"] == 1 and rec.summary()["mutating_count"] == 2)
rec2 = SideEffectRecorder(FE)
for i in range(25):
    rec2.on_request(Req("POST", "fetch", f"{FE}/api/items/{i}"))
s2 = rec2.summary()
case("C14: the stored sample is capped at 20 distinct requests and says it was truncated",
     len(s2["requests"]) == 20 and s2["truncated"] is True and s2["mutating_count"] == 25)
case("C15: row suffix names the mutating requests and every applied exclusion (read-only and auth)",
     render_side_effect_suffix(s) == "; side effects: 2 mutating request(s) (POST /api/runs); "
                                     "read-only exception applied: POST /api/policy/evaluate; "
                                     "auth request(s) not counted: POST /api/login")
case("C15b: row suffix when nothing mutated",
     render_side_effect_suffix(SideEffectRecorder(FE).summary()) == "; side effects: none observed")
case("C15c: a partial replay says so",
     render_side_effect_suffix(SideEffectRecorder(FE).summary(), partial=True)
     == "; side effects before the replay stopped: none observed")
case("C15d: the suffix never contains a table pipe",
     "|" not in render_side_effect_suffix({"mutating_count": 1, "requests": [
         {"method": "POST", "path": "/a|b", "class": "mutating", "count": 1}], "exceptions_applied": []}))
PY

# ── Part S: sidecar read-modify-write ────────────────────────────────────────
echo "== S. sidecar merge"
run_py_cases <<'PY'
import json, os, subprocess, sys, tempfile
def case(name, cond):
    print(("pass" if cond else "fail") + "\t" + name)
from demo_runner import merge_side_effect_observations, update_side_effects_sidecar, uncleared_mutations
G1, G2 = "1" * 64, "2" * 64
def obs(n, complete=True, verdict="PASS", path="/api/runs", it=8, golden=G1):
    reqs = [{"method": "POST", "path": path, "class": "mutating", "count": n}] if n else []
    return {"run_id": f"r{it}", "iter": it, "iter_name": f"goal-x-iter-{it}", "verdict": verdict,
            "observed_at": f"2026-09-17T00:{it:02d}:00.000000Z", "golden_sha256": golden,
            "complete": complete, "mutating_count": n, "auth_count": 0, "readonly_count": 0,
            "requests": reqs, "truncated": False, "exceptions_applied": [],
            "readonly_endpoints_sha256": None, "ignore_paths": ["/login"], "observer_errors": 0}
def still(m, jid="J-04"):
    return [x["iter"] for x in uncleared_mutations(m["journeys"][jid])]
def merged(base, *seq):
    m = json.loads(json.dumps(base))
    for jid, o in seq:
        m = merge_side_effect_observations(m, {jid: o})
    return m
base = {"schema_version": 1, "declaration_digest": "d1", "declarations": {"J-04": {"declared": "none"}},
        "journeys": {"J-02": {"latest": obs(0, it=3)}}}
m = merged(base, ("J-04", obs(1)))
case("S1: merging J-04 keeps J-02's record untouched", m["journeys"]["J-02"] == base["journeys"]["J-02"])
case("S2: engine-owned keys (declarations / digest) survive an observer write",
     m["declaration_digest"] == "d1" and m["declarations"] == base["declarations"])
case("S3: a complete observation becomes 'latest' and 'last_attempt', and is status evidence",
     m["journeys"]["J-04"]["latest"]["mutating_count"] == 1 and m["journeys"]["J-04"]["last_attempt"]["run_id"] == "r8"
     and still(m) == [8] and m["merged_runs"] == ["r8"])
m2 = merged(m, ("J-04", obs(0, complete=False, verdict="FAIL", it=9)))
case("S4: a PARTIAL zero-mutation replay never clears a recorded mutation",
     still(m2) == [8] and m2["journeys"]["J-04"]["last_attempt"]["iter"] == 9)
m3 = merged(base, ("J-02", obs(2, complete=False, verdict="FAIL", it=9)))
case("S5: a PARTIAL replay that did mutate upgrades the journey", still(m3, "J-02") == [9])
m4 = merged(m, ("J-04", obs(0, it=10)))
case("S6: a strictly newer COMPLETE clean replay of the SAME golden clears the mutation",
     still(m4) == [] and m4["journeys"]["J-04"]["latest"]["mutating_count"] == 0)
notes = {}
m5 = merge_side_effect_observations(json.loads(json.dumps(m)), {"J-04": obs(0, it=10, golden=G2)}, notes=notes)
case("S6b: a complete clean replay of a DIFFERENT golden (a re-derived script) never clears it, and says so",
     still(m5) == [8] and notes.get("J-04", {}).get("mutating_iter") == 8)
m6 = merged({}, ("J-04", obs(1, golden=None)), ("J-04", obs(0, it=10, golden=None)))
case("S6c: a mutation recorded without a golden identity is never cleared", still(m6) == [8])
m7 = merged({}, ("J-04", obs(0, it=10)), ("J-04", obs(1)), ("J-04", obs(0, it=11, golden=G2)))
m7b = merged({}, ("J-04", obs(0, it=11, golden=G2)), ("J-04", obs(0, it=10)), ("J-04", obs(1)))
case("S6d: a late merge of an older record is order-independent (cleared stays cleared)",
     still(m7) == [] and still(m7b) == [])
m8 = merged(m4, ("J-04", obs(1, it=12)))
case("S6e: a mutation AFTER the clearing replay counts again", still(m8) == [12])
case("S7: mutation provenance survives in mutating_history",
     [h["iter"] for h in m4["journeys"]["J-04"]["mutating_history"]] == [8])
mm = json.loads(json.dumps(base))
for i in range(12):
    mm = merge_side_effect_observations(mm, {"J-09": obs(1, it=i)})
case("S8: mutating_history is bounded (last 5)", len(mm["journeys"]["J-09"]["mutating_history"]) == 5)
again = merge_side_effect_observations(json.loads(json.dumps(m5)), {"J-04": obs(0, it=10, golden=G2)},
                                       now=m5["observations_updated_at"])
case("S8b: merging the same run twice changes nothing", again == m5)
d = tempfile.mkdtemp()
p = os.path.join(d, "state", "journey-side-effects.json")
ok, msg = update_side_effects_sidecar(p, {"J-04": obs(1)})
data = json.load(open(p))
case("S9: the sidecar is created when absent (state dir included)", ok and data["journeys"]["J-04"]["latest"]["mutating_count"] == 1)
case("S9b: no temp or lock files are left beside the sidecar", sorted(os.listdir(os.path.dirname(p))) == ["journey-side-effects.json"])
open(p, "w").write("{ corrupt")
before = open(p, "rb").read()
ok, msg = update_side_effects_sidecar(p, {"J-04": obs(1)})
case("S10: a CORRUPT sidecar is never overwritten (write refused, bytes unchanged)",
     (not ok) and open(p, "rb").read() == before and "not overwritten" in msg)
os.remove(p)
code = ("import sys; sys.path.insert(0, %r)\n"
        "from demo_runner import update_side_effects_sidecar\n"
        "for i in range(25):\n"
        "    ok, m = update_side_effects_sidecar(%r, {sys.argv[1] + '-' + str(i): {'complete': True, 'mutating_count': 1, 'requests': [], 'iter': i}})\n"
        "    assert ok, m\n") % (os.environ["PYTHONPATH"].split(":")[0], p)
procs = [subprocess.Popen([sys.executable, "-c", code, tag]) for tag in ("J-7", "J-8")]
rcs = [pr.wait() for pr in procs]
data = json.load(open(p))
case("S11: two concurrent writers lose no update (directory lock + atomic replace)",
     rcs == [0, 0] and len(data["journeys"]) == 50)
PY

# ── Part D: declarations, spec_hash, digest, ledger ──────────────────────────
echo "== D. declarations + digest + ledger (goal_gate.py)"
mkdir -p "$WORK/repo/docs" "$WORK/repo/project-extensions/side-effects" "$WORK/repo/state"
cat > "$WORK/repo/docs/goal.md" <<'EOF'
# Goal

A policy console.

## Must-have user journeys

- **J-01: Open the dashboard**
  - Steps:
    1. Visit `/`
  - Acceptance: the dashboard lists the runs

- **J-02: Inspect one policy instance (facts only)**
  - Steps:
    1. Visit `/policy`, choose `false_break`, press Evaluate
  - Acceptance: the facts panel shows the allowed size
  - Side effects: none — evaluating a policy computes facts and persists nothing

- **J-03: Trace a position**
  - Steps:
    1. Visit `/trace`
  - Acceptance: two rows render
  - Side effects: read-only

- **J-04: Replay a small portfolio under the new engine while v17 rows stay readable**
  - Steps:
    1. Open Backtests → Portfolio run; keep all six playbooks checked; set top symbols to
       5, start 2015-01-01, end 2015-06-30, walk-forward (never the form's default
       universe or date span); click Run; wait for completion, which takes under 60 s
    2. Land on Run detail; assert the header reads `Engine policy-core-v1`
  - Acceptance: the new ledger row carries `engine_version = policy-core-v1`
  - **Side effects:** Mutating — step 1 clicks Run, which launches a portfolio run and appends a ledger row

- **J-05: Read the external contract from the API docs**
  - Steps:
    1. Visit `/docs`; assert the operations are listed
  - Acceptance: the four policy operations are listed

## Anti-goals

- no paid SaaS
EOF
printf 'POST /api/policy/evaluate\n' > "$WORK/repo/project-extensions/side-effects/read-only-endpoints.txt"
run_py_cases <<'PY'
import hashlib, json, os, re, subprocess, sys
def case(name, cond):
    print(("pass" if cond else "fail") + "\t" + name)
import goal_gate as G
repo = os.path.abspath("repo")
goal_path = os.path.join(repo, "docs", "goal.md")
text = open(goal_path, encoding="utf-8").read()
decls = G.parse_side_effect_declarations(text)
case("D1: 'none', 'mutating' (bold/Mixed-case/em dash) and absent parse as declared",
     decls["J-02"]["declared"] == "none" and decls["J-04"]["declared"] == "mutating"
     and decls["J-01"]["declared"] is None and decls["J-01"]["valid"] is True)
case("D1b: the note is normalized and kept",
     decls["J-04"]["note"] == "step 1 clicks Run, which launches a portfolio run and appends a ledger row")
case("D2: 'read-only' is NOT a third value — invalid, treated as unknown",
     decls["J-03"]["declared"] is None and decls["J-03"]["valid"] is False
     and "read-only" in " ".join(decls["J-03"]["errors"])
     and "read-only-endpoints.txt" in " ".join(decls["J-03"]["errors"]))
def one(line):
    t = "- **J-09: X**\n  - Steps:\n    1. Visit `/`\n  - Acceptance: y\n" + line + "\n"
    return G.parse_side_effect_declarations(t)["J-09"]
case("D3: harmless formatting normalizes (case, whitespace, bold, -, en/em dash)",
     all(one(l)["declared"] == v and one(l)["valid"] for l, v in (
         ("  - side effects:   NONE", "none"),
         ("  - **Side effects:** mutating - creates a note", "mutating"),
         ("  - Side effects: **mutating** – creates a note", "mutating"),
         ("  - Side Effects: none — reads only", "none"),
         ("  - Side effects: `none`", "none"),
     )))
nm = one("  - Side-effects: mutating — creates a run")
nn = one("  - Side-effects: none")
case("D4: a near-miss label is invalid; its mutating intent is still honoured (conservative), a none is not",
     nm["valid"] is False and nm["declared"] == "mutating" and nn["valid"] is False and nn["declared"] is None)
sm = one("  - Side effects: mutating: creates a run")
sn = one("  - Side effects: none (reads only)")
case("D5: a malformed note separator is an error: 'mutating' stays mutating, 'none' becomes unknown",
     sm["valid"] is False and sm["declared"] == "mutating" and sn["valid"] is False and sn["declared"] is None)
dup = G.parse_side_effect_declarations(
    "- **J-09: X**\n  - Side effects: none\n  - Side effects: mutating — creates\n")["J-09"]
same = G.parse_side_effect_declarations(
    "- **J-09: X**\n  - Side effects: none\n  - Side effects: none\n")["J-09"]
glued_none, glued_mut = one("  - Side effects: none-destructive"), one("  - Side effects: mutating-creates a run")
case("D5b: a hyphen glued to the value ('none-destructive') is invalid; a glued 'mutating-…' still counts as mutating",
     glued_none["declared"] is None and not glued_none["valid"]
     and glued_mut["declared"] == "mutating" and not glued_mut["valid"])
case("D6: duplicate lines are an error; a none/mutating conflict resolves to mutating, a repeated none to unknown",
     dup["valid"] is False and dup["declared"] == "mutating" and same["valid"] is False and same["declared"] is None)
fenced = G.parse_side_effect_declarations(
    "- **J-09: X**\n  - Steps:\n    ```\n    - Side effects: none\n    ```\n")["J-09"]
case("D6b: a declaration-shaped line inside a code fence is not a declaration", fenced["declared"] is None and not fenced["lines"])
irregular = ("## Must-have user journeys\n\n- **J-01: A**\n  - Steps:\n    1. Visit `/`\n"
             "  - Side effects: none — reads\n\n\n\n- **J-02: B**\n  - Steps:\n    1. click Run\n"
             "  - Side effects: mutating — launches a run\n\n- **J-03: C**\n  - Side effects: none\n")
irr = G.parse_side_effect_declarations(irregular)
case("D6c: uneven blank lines between journeys never attribute a declaration to the wrong journey",
     irr["J-01"]["declared"] == "none" and irr["J-01"]["valid"] and irr["J-02"]["declared"] == "mutating"
     and irr["J-03"]["declared"] == "none" and len(irr["J-01"]["lines"]) == 1)
case("D6d: ... and the certified spec_hash stays declaration-neutral on the same irregular text",
     G._journey_hashes(irregular) == G._journey_hashes(re.sub(r"(?m)^  - Side effects:.*\n", "", irregular)))
# spec_hash invariance
blk = ("- **J-09: Create a note**\n  - Steps:\n    1. Visit `/notes`\n    2. Click New\n"
       "  - Acceptance: a note row appears\n")
h0 = G._journey_hashes(blk)["J-09"]
variants = [
    blk + "  - Side effects: mutating — creates a note row\n",
    blk.replace("  - Acceptance", "  - Side effects: none\n  - Acceptance"),
    blk + "  - **Side effects:** none\n\n",
    (blk + "  - Side effects: mutating — x\n").replace("\n", "\r\n"),
    blk + "  * side effects:  **None**  –  reads\n",
]
case("D7: spec_hash(block) == spec_hash(block + a WELL-FORMED Side effects line), for every form and position",
     all(G._journey_hashes(v)["J-09"] == h0 for v in variants))
malformed = [
    blk + "  - Side effects: read-only\n",
    blk + "  - Side effect: mutating — creates a note row\n",
    blk + "  Side effects: none\n",
    blk + "  - Side effects: none (the list still shows 5 rows)\n",
]
case("D7b: a MALFORMED declaration-shaped line is journey text — adding it is goal-edit drift",
     all(G._journey_hashes(v)["J-09"] != h0 for v in malformed))
def pair_moves(a, b):
    ga, gb = blk + a + "\n", blk + b + "\n"
    da = G.declaration_digest(G.parse_side_effect_declarations(ga), {"sha256": None})
    db = G.declaration_digest(G.parse_side_effect_declarations(gb), {"sha256": None})
    return G._journey_hashes(ga) != G._journey_hashes(gb) and da != db
case("D7c: editing inside a malformed line (prose after 'side effect:', a '(…)' or '.' tail, a comma) moves BOTH spec_hash and digest",
     all(pair_moves(a, b) for a, b in (
         ("    side effect: the ledger gains exactly one row", "    side effect: the ledger gains two rows"),
         ("  - Side effects: none (5 rows)", "  - Side effects: none (50 rows)"),
         ("  - Side effects: none. badge OK", "  - Side effects: none. badge FAILED"),
         ("  - Side effects: (tbd) — 5 runs", "  - Side effects: (tbd) — 9 runs"),
         ("  - Side effects: mutating, named Alpha", "  - Side effects: mutating, named Beta"))))
case("D8: spec_hash still changes when the journey's own text changes",
     G._journey_hashes(blk.replace("a note row", "two note rows"))["J-09"] != h0)
nest = ("## Must-have user journeys\n\n- **J-01: Parent**\n  - Steps:\n    1. Open Runs; click Run\n"
        "  - **J-02: Child**\n    - Steps:\n      1. Visit `/r`\n    - Side effects: none — reads\n"
        "- **J-10: Recover**\n  - Steps:\n    1. Visit `/c`\n  - **J-10 CLOSED — owner note**\n    - detail\n"
        "  - Side effects: none — reads the restored layer\n\n## Anti-goals\n")
nd = G.parse_side_effect_declarations(nest)
case("D8b: a declaration belongs to its innermost journey (J-01 does not inherit nested J-02's none)",
     nd["J-01"]["declared"] is None and nd["J-02"]["declared"] == "none")
case("D8c: a nested owner note with the SAME id is part of the journey, not a second definition",
     nd["J-10"]["declared"] == "none" and nd["J-10"]["valid"])
nref = ("## Must-have user journeys\n\n- **J-10: Recover**\n  1. Open /data\n  2. Click **Restore**\n"
        "    - **J-11** depends on this restore finishing first.\n  - Acceptance: rows are back\n"
        "  - Side effects: mutating — restores deleted rows\n\n- **J-11: Regenerate**\n  1. Open /derived\n"
        "  - Acceptance: renders\n  - Side effects: none\n\n## Anti-goals\n")
nr = G.parse_side_effect_declarations(nref)
case("D8d: a nested bold-id REFERENCE to another journey never takes over its parent's declaration",
     nr["J-10"]["declared"] == "mutating" and nr["J-10"]["valid"]
     and nr["J-11"]["declared"] == "none" and nr["J-11"]["valid"])
fenced_hdr = ("- **J-01: Export**\n  1. Open /export\n  2. The page shows, for example:\n     ```\n"
              "     - **J-99: example**\n     ```\n  - Side effects: {}\n")
fa, fb = fenced_hdr.format("mutating — writes the export log"), fenced_hdr.format("none")
pa, pb = G.parse_side_effect_declarations(fa), G.parse_side_effect_declarations(fb)
case("D8e: a journey header inside a code fence is not a journey — the real declaration stays attributed, hash-neutral and digest-visible",
     pa["J-01"]["declared"] == "mutating" and ("J-99" not in pa or pa["J-99"].get("unattributed"))
     and G._journey_hashes(fa)["J-01"] == G._journey_hashes(fb)["J-01"]
     and G.declaration_digest(pa, {"sha256": None}) != G.declaration_digest(pb, {"sha256": None}))
fence_goal = ("# Goal\n\nA snippet:\n\n~~~markdown\n```bash\nmake run\n~~~\n\n## Must-have user journeys\n\n"
              "- **J-04: Run**\n  1. Open /runs and click **Run**\n  - Acceptance: listed\n"
              "  - Side effects: mutating — launches a run\n\n## Anti-goals\n- none\n")
unclosed_goal = fence_goal.replace("~~~markdown\n```bash\nmake run\n~~~\n", "```bash\nmake run\n")
lf, lu = G.build_side_effect_ledger(fence_goal), G.build_side_effect_ledger(unclosed_goal)
case("D8f: a ~~~ block holding a ``` line, or an unclosed fence, never hides the journeys below it",
     lf["journeys"].get("J-04", {}).get("status") == "mutating"
     and lu["journeys"].get("J-04", {}).get("status") == "mutating")
fh = ("## Must-have user journeys\n\n- **J-01: Export**\n  1. Open /export\n  2. Help shows:\n"
      "     ~~~markdown\n     ```\n     - Side effects: none\n     ~~~\n  - Acceptance: exported\n\n## Anti-goals\n")
fh_without = fh.replace("     - Side effects: none\n", "")
fhd = G.parse_side_effect_declarations(fh)["J-01"]
case("D8g: a declaration-shaped line inside a CommonMark fence is journey text: no declaration, still in spec_hash",
     fhd["declared"] is None and not fhd["lines"]
     and G._journey_hashes(fh)["J-01"] != G._journey_hashes(fh_without)["J-01"])
sub = ("## Must-have user journeys\n\n- **J-05: Checkout**\n  1. Open /cart\n  2. Click **Pay**\n"
       "  - Acceptance: placed\n  - Side effects: mutating — places an order\n  - **J-06: Refund** (a sub-flow)\n"
       "    - Acceptance: refunded\n    - Side effects: none — reads the order list\n\n## Anti-goals\n")
sd6 = G.parse_side_effect_declarations(sub)
case("D8h: a NAMED nested journey is a definition of its own, and its parent keeps its own declaration",
     sd6["J-05"]["declared"] == "mutating" and sd6["J-06"]["declared"] == "none" and sd6["J-06"]["valid"])
sub2 = sub.replace("    - Side effects: none — reads the order list\n", "")
case("D8h2: a NAMED nested journey without its own steps or declaration is still its own definition",
     "J-06" in [v["jid"] for v in G.side_effect_journey_views(sub2)]
     and G.parse_side_effect_declarations(sub2)["J-05"]["declared"] == "mutating")
ref_only = ("## Must-have user journeys\n\n- **J-05: Checkout**\n  1. Click **Pay**\n  - Acceptance: placed\n"
            "    - **J-12** follows on from this\n  - Side effects: mutating — places an order\n\n## Anti-goals\n")
ro6 = G.build_side_effect_ledger(ref_only)
case("D8i: a journey id seen only as a nested reference still appears in the ledger (unattributed, fail-closed)",
     ro6["journeys"].get("J-12", {}).get("unattributed") is True
     and ro6["journeys"]["J-05"]["declared"] == "mutating")
import iter_spec as IS
shift = ("# Goal\n\nRun it with:\n\n```bash\nmake run\n\n## Must-have user journeys\n\n"
         "- **J-01: Checkout**\n  1. Open /cart and click **Pay**\n  - Acceptance: placed\n"
         "  - Side effects: mutating — places an order\n\nA template for new journeys:\n\n```\n"
         "- **J-02: Refund**\n  - Side effects: none\n```\n\n"
         "- **J-02: Refund**\n  1. Open /orders and click **Refund**\n  - Acceptance: refunded\n"
         "  - Side effects: mutating — refunds the order\n\n```\nmake test\n```\n\n## Anti-goals\n- none\n")
ls_ = G.build_side_effect_ledger(shift)
j2 = ls_["journeys"].get("J-02", {})
case("D8j: a stray top-level fence that shifts every later fence never lets a fenced example's `none` stand for "
     "the real journey (the id is ambiguous: its stated `mutating` counts)",
     j2.get("status") == "mutating" and j2.get("ambiguous") is True
     and j2.get("attribution_reason") == "fenced-header" and j2.get("declared") == "none"
     and ls_["journeys"].get("J-01", {}).get("status") == "mutating"
     and ls_["journeys"]["J-01"].get("unattributed") is True and ls_["journeys"]["J-01"].get("declared") is None
     and G.parse_side_effect_declarations(shift)["J-02"]["valid"] is False)
F = IS.fenced_line_flags
case("D8k: fences pair the CommonMark way — a 4-space-indented fence never closes a top-level one, a list-item "
     "opener counts, a quoted fence ends with its quote, CRLF and ~~~/``` mixes are handled",
     F(["```bash", "make run", "", "- item", "    ```", "    code", "    ```", "tail"])
     == [False, False, False, False, True, True, True, False]
     and F(["- ```bash", "  make run", "  ```", "- **J-01: X**"]) == [True, True, True, False]
     and F(["> ```bash", "> make run", "", "text", "```", "code", "```", "after"])
     == [True, True, False, False, True, True, True, False]
     and F(["```\r", "x\r", "```\r", "y"]) == [True, True, True, False]
     and F(["~~~", "```", "~~~", "z"]) == [True, True, True, False])
titled = ("## Must-have user journeys\n\n- **J-01: Checkout**\n  1. Open /cart and click **Pay**\n"
          "  - Acceptance: placed\n  - Related:\n    - **J-03: Browse** — the catalog must still list it\n"
          "  - **J-03:** must still pass afterwards\n  - Side effects: mutating — places an order\n\n"
          "- **J-03: Browse**\n  1. Open /catalog\n  - Acceptance: listed\n  - Side effects: none\n\n## Anti-goals\n")
td = G.parse_side_effect_declarations(titled)
case("D8l: a titled mention of a journey defined at top level is a reference, not a second definition",
     td["J-03"]["declared"] == "none" and td["J-03"]["valid"] and td["J-01"]["declared"] == "mutating"
     and not td["J-03"].get("unattributed"))
fixed = shift.replace("```bash\nmake run\n", "```bash\nmake run\n```\n")
sugg = G.render_side_effect_suggestions(ls_, "docs/goal.md")
j2_sugg = next((ln for ln in sugg.splitlines() if ln.startswith("J-02")), "")
case("D8m: an ambiguous or unattributed journey is reported as such (status source, reason, --suggest, the lint's "
     "and the prompts' wording — never as 'declared') and an attribution change moves the declaration digest",
     j2.get("status_source") == "ambiguous"
     and "rename the example's id" in j2_sugg and "no 'Side effects:' line" not in j2_sugg
     and "declared mutating" not in IS._mutating_desc("J-02", j2, {"target"})
     and "cannot be tied to it with certainty" in IS._mutating_desc("J-02", j2, {"target"})
     and IS._status_list(["J-02"], {"J-02": j2}, True) == "J-02 (ambiguous declaration)"
     and G.declaration_digest(G.parse_side_effect_declarations(shift), {"sha256": None})
     != G.declaration_digest(G.parse_side_effect_declarations(fixed), {"sha256": None}))
lf_doc = ("- **J-01: Export**\n  1. Open /export\n     ```\n     - Side effects: none\n     ```\n"
          "  - Acceptance: exported\n")
case("D29: CRLF line endings never change which declaration-shaped lines the certified hash drops",
     G._journey_hashes(lf_doc.replace("\n", "\r\n"))["J-01"] == G._journey_hashes(lf_doc)["J-01"])
bor_goal = ("# Goal\n\n## Must-have user journeys\n\n"
            "- **J-01: Checkout**\n  1. Open /cart and click **Pay**\n  - Acceptance: listed\n"
            "  - Side effects: mutating — places an order\n\n"
            "- **J-02: Browse**\n  1. Open /catalog\n  - Acceptance: listed\n"
            "  - Side effects: none — the catalog only reads\n\n"
            "## Writing a journey\n\nJourneys follow this shape (example only):\n\n```markdown\n"
            "- **J-02: Save a filter**\n  1. Open /catalog and click **Save filter**\n"
            "  - Side effects: mutating — saves a filter\n```\n\n## Anti-goals\n- none\n")
bor_side = os.path.join(repo, "borrowed-sidecar.json")
json.dump({"schema_version": 1, "journeys": {"J-02": {"latest": {
    "iter": 8, "iter_name": "goal-x-iter-8", "complete": True, "verdict": "PASS", "mutating_count": 1,
    "auth_count": 0, "readonly_count": 0,
    "requests": [{"method": "POST", "path": "/api/catalog/track", "class": "mutating", "count": 1}],
    "truncated": False, "exceptions_applied": [], "readonly_endpoints_sha256": None,
    "ignore_paths": ["/login", "/logout", "/auth", "/session", "/token", "/csrf"]}}}}, open(bor_side, "w"))
lb = G.build_side_effect_ledger(bor_goal, sidecar=bor_side, readonly_path=os.path.join(repo, "absent-ro.txt"))
bor_led_path = os.path.join(repo, "borrowed-ledger.json")
json.dump(lb, open(bor_led_path, "w"))
b2 = lb["journeys"]["J-02"]
case("D8n: a fenced example that reuses a journey id makes it ambiguous but is never reported as its declaration, "
     "and an observed write is still surfaced as a (possible) DECLARATION CONFLICT",
     b2["declared"] == "none" and b2["declaration_conflict"] is True and b2["status"] == "mutating"
     and b2.get("ambiguous") is True and b2["stated_values"] == ["mutating", "none"] and lb["conflicts"] == ["J-02"]
     and IS._status_list(["J-02"], {"J-02": b2}, True).startswith(
         "J-02 (ambiguous declaration; AMBIGUOUS, one block says none, but observed")
     and "POSSIBLE DECLARATION CONFLICT" in IS.render_side_effect_context("evaluator", bor_led_path)
     and "J-02 is declared 'none'" not in IS.render_side_effect_context("evaluator", bor_led_path))
nb_goal = ("# Goal\n\n## Must-have user journeys\n\n- **J-01: Checkout**\n  1. Open /cart and click **Pay**\n"
           "  - The help panel shows this template:\n    ```\n    - **J-02: Browse**\n      1. Open /catalog\n"
           "    ```\n  - Side effects: mutating — places an order\n\n- **J-02: Browse**\n  1. Open /catalog\n"
           "  - Side effects: none\n\n## Anti-goals\n- none\n")
lnb = G.build_side_effect_ledger(nb_goal)
case("D8o: a fenced template inside one journey never lends that journey's declaration to the id it mentions "
     "(the id is ambiguous, so its own 'none' is not trusted, but J-01's 'mutating' is not borrowed)",
     lnb["journeys"]["J-02"]["status"] == "unknown" and lnb["journeys"]["J-02"]["declared"] == "none"
     and lnb["journeys"]["J-02"]["stated_values"] == ["none"] and lnb["journeys"]["J-02"].get("ambiguous") is True
     and lnb["journeys"]["J-01"]["declared"] == "mutating")
li_goal = ("# Goal\n\nSetup:\n\n- ```bash\n  make run\n\n## Must-have user journeys\n\n- **J-02: Browse**\n"
           "  1. Open /catalog\n  - Acceptance: listed\n  - Side effects: none\n\n- **J-03: Export**\n"
           "  1. Open /export\n  2. The page shows:\n     ```\n     EXPORTED\n     ```\n  - Side effects: none\n\n"
           "## Anti-goals\n- none\n")
lli = G.build_side_effect_ledger(li_goal)
case("D8p: a fence opened on a list-item line ends with its item, so it never hides or shifts the journeys below",
     callable(getattr(IS, "fence_scan", None)) and IS.fence_scan(li_goal.split("\n"))[1] == []
     and IS.fenced_line_flags(li_goal.split("\n"))[4:7] == [True] * 3
     and lli["journeys"]["J-02"]["status"] == "none" and lli["journeys"]["J-03"]["status"] == "none")
absorbed = shift.replace("```\nmake test\n```", "```bash\nmake test\n```")
la = G.build_side_effect_ledger(absorbed)
case("D8q: a stray fence whose shift a later ```bash block absorbs (no unclosed opener left) still never lets the "
     "fenced example's 'none' stand for J-02",
     IS.fence_scan(absorbed.split("\n"))[1] == [] and la["journeys"]["J-02"]["status"] == "mutating"
     and la["journeys"]["J-02"].get("ambiguous") is True)
c1_goal = ("# Goal\n\n## Must-have user journeys\n\n"
           "- **J-02: Browse**\n  1. Open /catalog\n  - Side effects: none\n\n"
           "- **J-04: Run backtest**\n  1. Open /playbooks/ca786 and click **Run**\n  2. The log panel shows:\n"
           "     ```text\n     run started\n"
           "  - Side effects: mutating — launches a run and appends a ledger row\n\n"
           "- **J-05: Logs**\n  1. Open /logs\n  2. The page shows:\n     ```\n     tail\n     ```\n"
           "  - Side effects: none\n\n## Anti-goals\n- none\n")
c1_side = os.path.join(repo, "c1-sidecar.json")
json.dump({"schema_version": 1, "journeys": {"J-05": {"latest": {
    "iter": 8, "iter_name": "goal-x-iter-8", "complete": True, "verdict": "PASS", "mutating_count": 1,
    "auth_count": 0, "readonly_count": 0,
    "requests": [{"method": "POST", "path": "/api/logs/ack", "class": "mutating", "count": 1}],
    "truncated": False, "exceptions_applied": [], "readonly_endpoints_sha256": None,
    "ignore_paths": ["/login", "/logout", "/auth", "/session", "/token", "/csrf"]}}}}, open(c1_side, "w"))
lc1 = G.build_side_effect_ledger(c1_goal, sidecar=c1_side, readonly_path=os.path.join(repo, "absent-ro.txt"))
c1_led = os.path.join(repo, "c1-ledger.json")
json.dump(lc1, open(c1_led, "w"))
c1_j4, c1_j5 = lc1["journeys"]["J-04"], lc1["journeys"]["J-05"]
c1_spec = ("## Goal Mode Metadata\n\n- **Session ID:** s\n- **Iteration:** 9\n- **Mode:** next\n- **Depth:** lean\n"
           "- **Target journeys:** J-04\n- **Required-still-passing journeys:** J-02\n- **Work kind:** verify-only\n"
           "- **Side-effect policy:** none\n\n## GOAL\n\nConfirm J-04.\n\n## IN SCOPE\n\n### Backend\n- none\n\n"
           "## OUT OF SCOPE\n\n- Any new portfolio run launch, sweep, or ledger write\n\n## DEFINITION OF DONE\n\n"
           "- [ ] J-04 passes\n\n## TESTING REQUIREMENTS\n\n"
           "- TC-4: given J-04's golden, when replayed, then the ledger row count is unchanged\n")
c1_rules = sorted({e["rule"] for e in IS.lint_spec(c1_spec, side_effects=c1_led)["errors"]})
c1_ctx = IS.render_side_effect_context("evaluator", c1_led)
case("D8r: an unclosed fence inside a journey's step never makes a later journey's lines its declaration — J-04 "
     "stays mutating (its fenced line counts, flagged ambiguous) so the TenSteps iteration-9 spec is E13/E16, "
     "J-05's 'none' is never trusted, and an observed J-05 write is a POSSIBLE conflict",
     c1_j4["status"] == "mutating" and c1_j4["declared"] is None and c1_j4.get("ambiguous") is True
     and c1_j4["attribution_reason"] == "fenced-declaration" and c1_j4["declaration_conflict"] is False
     and "move the example out of the journey" in G.attribution_problem(c1_j4)
     and c1_j5["status"] == "mutating" and c1_j5.get("unattributed") is True
     and c1_j5["declaration_conflict"] is True and lc1["conflicts"] == ["J-05"]
     and "UNATTRIBUTED, a block says none" in IS._status_list(["J-05"], {"J-05": c1_j5}, True)
     and "POSSIBLE DECLARATION CONFLICT" in c1_ctx and "declared 'none'" not in c1_ctx
     and {"E13", "E16"} <= set(c1_rules))
def ledger(goal_text, sidecar=None, ro=None):
    return G.build_side_effect_ledger(goal_text, sidecar=sidecar, readonly_path=ro)
ro = os.path.join(repo, "project-extensions", "side-effects", "read-only-endpoints.txt")
L0 = ledger(text, ro=ro)
flipped = text.replace("**Side effects:** Mutating — step 1 clicks Run",
                       "**Side effects:** none — step 1 clicks Run")
L1 = ledger(flipped, ro=ro)
case("D9: flipping J-04 mutating -> none changes the declaration digest and J-04's declaration_hash ...",
     L0["declaration_digest"] != L1["declaration_digest"]
     and L0["journeys"]["J-04"]["declaration_hash"] != L1["journeys"]["J-04"]["declaration_hash"])
case("D9b: ... while EVERY journey spec_hash stays equal (journey-hash-neutral)",
     G._journey_hashes(text) == G._journey_hashes(flipped))
ro2 = os.path.join(repo, "ro2.txt")
open(ro2, "w").write("POST /api/policy/evaluate\nPOST /api/preview\n")
case("D10: editing read-only-endpoints.txt changes the digest (goal text untouched)",
     ledger(text, ro=ro2)["declaration_digest"] != L0["declaration_digest"])
case("D10b: an absent exception file also yields a distinct digest",
     ledger(text, ro=os.path.join(repo, "absent.txt"))["declaration_digest"] != L0["declaration_digest"])
noted = text.replace("appends a ledger row", "appends one ledger row")
reformatted = text.replace("  - Side effects: none — evaluating", "  -   side effects:   **none**  —   evaluating")
case("D11: a note edit changes the digest; a formatting-only edit does not",
     ledger(noted, ro=ro)["declaration_digest"] != L0["declaration_digest"]
     and ledger(reformatted, ro=ro)["declaration_digest"] == L0["declaration_digest"])
added = text.replace("## Anti-goals", "- **J-06: New undeclared journey**\n  - Steps:\n    1. Visit `/x`\n  - Acceptance: y\n\n## Anti-goals")
case("D12: adding an UNDECLARED journey does not change the declaration digest",
     ledger(added, ro=ro)["declaration_digest"] == L0["declaration_digest"])
st = {j: L0["journeys"][j]["status"] for j in L0["journeys"]}
case("D13: status matrix without observations: none/mutating/unknown(absent)/unknown(invalid)",
     st == {"J-01": "unknown", "J-02": "none", "J-03": "unknown", "J-04": "mutating", "J-05": "unknown"}
     and L0["complete"] is True)
def sc(path, jid, method="POST", req="/api/runs", n=1, it=8, ro_sha=None, truncated=False, cls="mutating"):
    rec = {"latest": {"iter": it, "iter_name": f"goal-x-iter-{it}", "complete": True, "verdict": "PASS",
                      "mutating_count": n if cls == "mutating" else 0,
                      "auth_count": 0, "readonly_count": n if cls == "ignored-readonly" else 0,
                      "requests": [{"method": method, "path": req, "class": cls, "count": n}],
                      "truncated": truncated, "exceptions_applied": [],
                      "readonly_endpoints_sha256": ro_sha,
                      "ignore_paths": ["/login", "/logout", "/auth", "/session", "/token", "/csrf"]}}
    json.dump({"schema_version": 1, "journeys": {jid: rec}}, open(path, "w"))
    return path
sc_path = os.path.join(repo, "state", "sc.json")
L2 = ledger(text, sidecar=sc(sc_path, "J-02"), ro=ro)
case("D14: observation OUTRANKS a 'none' declaration (J-02 observed POST /api/runs -> mutating)",
     L2["journeys"]["J-02"]["status"] == "mutating" and L2["journeys"]["J-02"]["declared"] == "none"
     and L2["journeys"]["J-02"]["observed_mutating"] is True and L2["journeys"]["J-02"]["observed_iter"] == 8)
L3 = ledger(text, sidecar=sc(sc_path, "J-01"), ro=ro)
case("D14b: an undeclared journey with an observed mutation is mutating", L3["journeys"]["J-01"]["status"] == "mutating")
L4 = ledger(text, sidecar=sc(sc_path, "J-02", req="/api/policy/evaluate", ro_sha=None), ro=ro)
case("D15: an observation recorded BEFORE the read-only exception existed is reclassified — J-02 follows its declaration",
     L4["journeys"]["J-02"]["status"] == "none" and L4["journeys"]["J-02"]["observation_basis"] == "reclassified")
ro_sha = hashlib.sha256(open(ro, "rb").read()).hexdigest()
L5 = ledger(text, sidecar=sc(sc_path, "J-02", req="/api/policy/evaluate", ro_sha=ro_sha, cls="ignored-readonly"),
            ro=os.path.join(repo, "absent.txt"))
case("D15b: removing the exception makes the same recorded POST mutating again",
     L5["journeys"]["J-02"]["status"] == "mutating")
L6 = ledger(text, sidecar=sc(sc_path, "J-02", req="/api/policy/evaluate", ro_sha="0" * 64, truncated=True), ro=ro)
case("D15c: a truncated sample cannot be reclassified — the journey stays mutating (conservative)",
     L6["journeys"]["J-02"]["status"] == "mutating"
     and L6["journeys"]["J-02"]["observation_basis"] == "reclassification-unverifiable")
clean_ev = {"iter": 9, "iter_name": "goal-x-iter-9", "run_id": "r9", "observed_at": "2026-09-17T00:09:00.000000Z",
            "complete": True, "verdict": "PASS", "golden_sha256": "d" * 64, "mutating_count": 0, "auth_count": 0,
            "readonly_count": 1, "truncated": False, "classifier_version": 2,
            "requests": [{"method": "POST", "path": "/api/policy/evaluate", "class": "ignored-readonly", "count": 1}],
            "exceptions_applied": [{"method": "POST", "path": "/api/policy/evaluate"}], "auth_ignored": [],
            "readonly_endpoints_sha256": ro_sha, "readonly_endpoints_error": None,
            "ignore_paths": ["/login", "/logout", "/auth", "/session", "/token", "/csrf"]}
gpath = os.path.join(repo, "state", "golden-clean.json")
json.dump({"schema_version": 1, "journeys": {"J-02": {"latest": dict(clean_ev), "last_attempt": dict(clean_ev),
           "goldens": {"d" * 64: {"clean": dict(clean_ev)}}}}}, open(gpath, "w"))
kept = ledger(text, sidecar=gpath, ro=ro)["journeys"]["J-02"]
dropped = ledger(text, sidecar=gpath, ro=os.path.join(repo, "absent.txt"))["journeys"]["J-02"]
case("D15d: a request a clean replay did not count (read-only exception) counts again once the exception is withdrawn",
     kept["status"] == "none" and kept["exceptions_applied"] and dropped["status"] == "mutating"
     and dropped["observation_basis"] == "reclassified")
bad = os.path.join(repo, "state", "bad.json")
open(bad, "w").write("{ not json")
L7 = ledger(text, sidecar=bad, ro=ro)
case("D16: a corrupt sidecar makes the ledger INCOMPLETE, but declared mutations stay known",
     L7["complete"] is False and L7["errors"] and L7["journeys"]["J-04"]["status"] == "mutating")
case("D16a: ... and a declared none whose observations cannot be read is UNKNOWN, never none",
     L7["journeys"]["J-02"]["status"] == "unknown" and L7["journeys"]["J-02"]["status_source"] == "declared-unverified")
case("D16b: an absent sidecar is a complete ledger (no observations yet)",
     ledger(text, sidecar=os.path.join(repo, "state", "nope.json"), ro=ro)["complete"] is True)
unread = os.path.join(repo, "unreadable.txt")
open(unread, "w").write("POST /api/x\n")
os.chmod(unread, 0)
readable_anyway = os.access(unread, os.R_OK)
L8 = ledger(text, ro=unread)
case("D17: an unreadable exception file makes the ledger incomplete",
     readable_anyway or (L8["complete"] is False and any("read-only-endpoints" in e or "unreadable" in e for e in L8["errors"])))
os.chmod(unread, 0o644)
hints = L0["journeys"]["J-04"]["step_hints"]
case("D18: J-04's step hints name step 1 (continuation lines included: 'click Run')",
     hints and hints[0]["n"] == 1 and "click Run" in hints[0]["text"])
# CLI
def cli(*args):
    p = subprocess.run([sys.executable, os.path.join(os.environ["PYTHONPATH"].split(":")[0], "goal_gate.py")] + list(args),
                       capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr
out = os.path.join(repo, "ledger.json")
side = os.path.join(repo, "state", "journey-side-effects.json")
if os.path.exists(side):
    os.remove(side)
rc, so, se = cli("side-effects", goal_path, "--sidecar", side, "--out", out, "--iter", "0",
                 "--iter-name", "goal-x-iter-0", "--step", "preflight", "--record-digest")
led = json.load(open(out))
case("D19: CLI writes the ledger (plan keys present) and exits 0 when complete",
     rc == 0 and all(k in led for k in ("declaration_digest", "journeys"))
     and all(k in led["journeys"]["J-04"] for k in ("declared", "declaration_hash", "note", "observed_mutating",
                                                   "observed_iter", "requests", "status")))
sd = json.load(open(side))
case("D19b: the first --record-digest creates the engine-owned sidecar and emits NO per-journey change events",
     sd.get("declaration_digest") == led["declaration_digest"] and sd.get("declaration_digest_prev") is None
     and "side_effect_declaration_changed" not in so)
flip_goal = os.path.join(repo, "docs", "goal-flip.md")
open(flip_goal, "w").write(flipped)
rc, so, se = cli("side-effects", flip_goal, "--sidecar", side, "--out", out, "--iter", "3",
                 "--iter-name", "goal-x-iter-3", "--step", "preflight", "--record-digest",
                 "--readonly-endpoints", ro)
evs = [l.split("\t", 1) for l in so.splitlines() if "\t" in l]
ch = [json.loads(p) for e, p in evs if e == "side_effect_declaration_changed"]
sd2 = json.load(open(side))
case("D20: a mutating -> none flip emits side_effect_declaration_changed {journey, from, to, iter}",
     any(c.get("journey") == "J-04" and c.get("from") == "mutating" and c.get("to") == "none" and c.get("iter") == 3 for c in ch))
case("D20b: the sidecar records declaration_digest_prev and the new digest",
     sd2["declaration_digest_prev"] == sd["declaration_digest"] and sd2["declaration_digest"] != sd["declaration_digest"])
rc, so, se = cli("side-effects", flip_goal, "--sidecar", side, "--out", out, "--iter", "4",
                 "--iter-name", "goal-x-iter-4", "--step", "preflight", "--record-digest",
                 "--readonly-endpoints", ro2)
evs = [l.split("\t", 1) for l in so.splitlines() if "\t" in l]
ch = [json.loads(p) for e, p in evs if e == "side_effect_declaration_changed"]
case("D20c: an exception-file edit is provenance-visible (declaration_changed with source read-only-endpoints)",
     any(c.get("source") == "read-only-endpoints" for c in ch))
rc, so, se = cli("side-effects", flip_goal, "--sidecar", side, "--out", out, "--iter", "5",
                 "--iter-name", "goal-x-iter-5", "--step", "preflight", "--record-digest",
                 "--readonly-endpoints", ro2)
case("D20d: an unchanged declaration set emits no change event", "side_effect_declaration_changed" not in so)
os.environ["CHAIN_SIDE_EFFECT_IGNORE_PATHS"] = "/login, /signin, /api"
rc, so, se = cli("side-effects", flip_goal, "--sidecar", side, "--out", out, "--iter", "6",
                 "--iter-name", "goal-x-iter-6", "--step", "preflight", "--record-digest",
                 "--readonly-endpoints", ro2)
del os.environ["CHAIN_SIDE_EFFECT_IGNORE_PATHS"]
evs = [l.split("\t", 1) for l in so.splitlines() if "\t" in l]
ch = [json.loads(p) for e, p in evs if e == "side_effect_declaration_changed"]
led6 = json.load(open(out))
case("D20e: overriding the auth exclusions is provenance-visible (source auth-ignore-paths) and flagged in the ledger",
     any(c.get("source") == "auth-ignore-paths" and c.get("to") == ["/login", "/signin"]
         and c.get("rejected") == ["/api"] for c in ch)
     and led6["ignore_paths_default"] is False and led6["ignore_paths_rejected"] == ["/api"]
     and json.load(open(side))["ignore_paths"] == ["/login", "/signin"])
rc, so, se = cli("side-effects", flip_goal, "--sidecar", side, "--record-digest")
case("D20f: --record-digest without --out is refused (the change events would have nowhere to go)",
     rc == 2 and "needs --out" in se)
digest_before = json.load(open(side))["declaration_digest"]
os.makedirs(os.path.join(repo, "out-is-a-dir"), exist_ok=True)
rc, so, se = cli("side-effects", goal_path, "--sidecar", side, "--out", os.path.join(repo, "out-is-a-dir"),
                 "--iter", "7", "--iter-name", "goal-x-iter-7", "--step", "preflight", "--record-digest",
                 "--readonly-endpoints", ro2)
case("D20g: when the ledger cannot be written, nothing is recorded (the digest and its events are not lost)",
     rc == 2 and json.load(open(side))["declaration_digest"] == digest_before and "\t" not in so)
open(side, "w").write("{ corrupt")
rc, so, se = cli("side-effects", goal_path, "--sidecar", side, "--out", out, "--record-digest")
case("D21: CLI exits 3 (ledger written, incomplete) for a corrupt sidecar — and never rewrites it",
     rc == 3 and json.load(open(out))["complete"] is False and open(side).read() == "{ corrupt")
rc, so, se = cli("side-effects", os.path.join(repo, "docs", "missing.md"), "--out", os.path.join(repo, "l2.json"))
case("D21b: CLI exits 2 and writes nothing when goal.md is unreadable",
     rc == 2 and not os.path.exists(os.path.join(repo, "l2.json")))
sug_goal = os.path.join(repo, "docs", "goal-suggest.md")
open(sug_goal, "w").write(text.replace("1. Visit `/`\n", "1. Visit `/`, type a title, click Save\n"))
before = open(sug_goal, "rb").read()
rc, so, se = cli("side-effects", sug_goal, "--suggest")
case("D22: --suggest prints paste-ready lines: mutating for a step that saves, none for a read-only journey, and the invalid J-03",
     rc == 0 and re.search(r"(?m)^J-01 .*\n  evidence: step 1 mentions save.*\n  suggest:  - Side effects: mutating — ", so)
     and re.search(r"(?m)^J-05 .*\n  suggest:  - Side effects: none — ", so)
     and re.search(r"(?m)^J-03 .*INVALID declaration", so) and "read-only-endpoints.txt" in so
     and not re.search(r"(?m)^J-02 |^J-04 ", so))
case("D22b: --suggest never edits the goal file", open(sug_goal, "rb").read() == before)
# The per-run records are the durable observation history: a sidecar that
# missed an update, or was moved aside, is rebuilt from them.
sess = os.path.join(repo, "runs", "goal-session-rb")
os.makedirs(os.path.join(sess, "state"))
os.makedirs(os.path.join(sess, "iter-2"))
rb_side = os.path.join(sess, "state", "journey-side-effects.json")
rec2 = {"run_id": "goal-rb-iter-2:1", "iter": 2, "observed_at": "2026-09-17T01:00:00.000000Z",
        "journeys": {"J-02": {"run_id": "goal-rb-iter-2:1", "iter": 2, "iter_name": "goal-rb-iter-2",
                              "observed_at": "2026-09-17T01:00:00.000000Z", "golden_sha256": "c" * 64,
                              "complete": True, "verdict": "PASS", "mutating_count": 1, "auth_count": 0,
                              "readonly_count": 0, "truncated": False, "exceptions_applied": [],
                              "requests": [{"method": "POST", "path": "/api/policy/save", "class": "mutating", "count": 1}],
                              "classifier_version": 2, "readonly_endpoints_sha256": None,
                              "ignore_paths": ["/login", "/logout", "/auth", "/session", "/token", "/csrf"]}},
        "sidecar": {"path": rb_side, "updated": False, "message": "sidecar update failed: could not lock"}}
json.dump(rec2, open(os.path.join(sess, "iter-2", "replay-side-effects.json"), "w"))
json.dump({"schema_version": 1, "journeys": {}}, open(rb_side, "w"))
rbo = os.path.join(sess, "iter-3", "side-effects.json")
rc, so, se = cli("side-effects", goal_path, "--sidecar", rb_side, "--out", rbo, "--iter", "3",
                 "--iter-name", "goal-rb-iter-3", "--step", "preflight", "--record-digest", "--readonly-endpoints", ro)
rl = json.load(open(rbo))
evs = [l.split("\t", 1) for l in so.splitlines() if "\t" in l]
case("D24: a run record the sidecar never merged still counts: J-02 (declared none) is MUTATING, a declaration conflict",
     rc == 0 and rl["journeys"]["J-02"]["status"] == "mutating" and rl["conflicts"] == ["J-02"]
     and rl["run_records_pending"])
case("D24b: the preflight record repairs the sidecar and reports it (observations_repaired + declaration_conflict)",
     "goal-rb-iter-2:1" in json.load(open(rb_side))["merged_runs"]
     and {"side_effect_observations_repaired", "side_effect_declaration_conflict"} <= {e for e, _ in evs})
os.rename(rb_side, rb_side + ".corrupt-moved-aside")
rc, so, se = cli("side-effects", goal_path, "--sidecar", rb_side, "--out", rbo, "--readonly-endpoints", ro)
case("D24c: a sidecar moved aside loses nothing — the ledger is rebuilt from the per-run records",
     rc == 0 and json.load(open(rbo))["journeys"]["J-02"]["status"] == "mutating")
open(os.path.join(sess, "iter-2", "replay-side-effects.20260917T010101000000000-1-1.json"), "w").write("{ torn")
rc, so, se = cli("side-effects", goal_path, "--sidecar", rb_side, "--out", rbo, "--readonly-endpoints", ro)
case("D24d: an unreadable per-run record makes the ledger INCOMPLETE (its observations are unknown)",
     rc == 3 and json.load(open(rbo))["complete"] is False)
# --freeze: a resumed preflight keeps the iteration's first view
fz = os.path.join(repo, "runs", "goal-session-fz")
os.makedirs(os.path.join(fz, "state"))
os.makedirs(os.path.join(fz, "iter-4"))
fz_side = os.path.join(fz, "state", "journey-side-effects.json")
fz_out = os.path.join(fz, "iter-4", "side-effects.json")
fz_snap = os.path.join(fz, "iter-4", "side-effects.preflight.json")
def fz_build(goal, bid):
    return cli("side-effects", goal, "--sidecar", fz_side, "--out", fz_out, "--iter", "4",
               "--iter-name", "goal-fz-iter-4", "--step", "preflight", "--record-digest", "--build-id", bid,
               "--freeze", fz_snap, "--readonly-endpoints", ro)
def jload(path):
    try:
        return json.load(open(path))
    except (OSError, ValueError):
        return {"journeys": {}}
rc1, _, _ = fz_build(goal_path, "b1")
first = jload(fz_out)
rec4 = json.loads(json.dumps(rec2))
rec4.update(run_id="goal-fz-iter-4:1", iter=4, observed_at="2026-09-17T02:00:00.000000Z")
for o in rec4["journeys"].values():
    o.update(run_id="goal-fz-iter-4:1", iter=4, iter_name="goal-fz-iter-4", observed_at=rec4["observed_at"])
json.dump(rec4, open(os.path.join(fz, "iter-4", "replay-side-effects.json"), "w"))
rc2, _, _ = fz_build(goal_path, "b2")
again = jload(fz_out)
case("D25: --freeze: a resumed preflight reuses the iteration's first view (its own replay's J-02 write is not in it)",
     rc1 == 0 and rc2 == 0 and first["journeys"].get("J-02", {}).get("status") == "none"
     and again["journeys"].get("J-02", {}).get("status") == "none" and again.get("frozen") is True
     and again["build_id"] == "b2" and os.path.exists(fz_snap))
fz_goal = os.path.join(repo, "docs", "goal-fz.md")
open(fz_goal, "w").write(noted)
rc3, _, _ = fz_build(fz_goal, "b3")
changed = jload(fz_out)
case("D25b: ... but changed inputs (a declaration edit) are rebuilt, and that view is what gets frozen",
     rc3 == 0 and not changed.get("frozen") and changed["journeys"].get("J-02", {}).get("status") == "mutating"
     and jload(fz_snap).get("build_id") == "b3")
# a sidecar moved aside keeps its declaration history through the newest earlier ledger
sd_dir = os.path.join(repo, "runs", "goal-session-sd")
os.makedirs(os.path.join(sd_dir, "state"))
sd_side = os.path.join(sd_dir, "state", "journey-side-effects.json")
def sd_build(goal, it):
    os.makedirs(os.path.join(sd_dir, f"iter-{it}"), exist_ok=True)
    return cli("side-effects", goal, "--sidecar", sd_side,
               "--out", os.path.join(sd_dir, f"iter-{it}", "side-effects.json"), "--iter", str(it),
               "--iter-name", f"goal-sd-iter-{it}", "--step", "preflight", "--record-digest",
               "--readonly-endpoints", ro)
sd_build(goal_path, 1)
os.rename(sd_side, sd_side + ".moved-aside")
rc, so, se = sd_build(flip_goal, 2)
evs = [l.split("\t", 1) for l in so.splitlines() if "\t" in l]
ch = [json.loads(x) for e, x in evs if e == "side_effect_declaration_changed"]
case("D26: after the sidecar is moved aside, a simultaneous mutating->none flip is still reported (baseline: the iter-1 ledger)",
     any(c.get("journey") == "J-04" and c.get("from") == "mutating" and c.get("to") == "none" for c in ch)
     and json.load(open(os.path.join(sd_dir, "iter-2", "side-effects.json")))["declaration_digest_changed_this_iter"] is True)
em_dir = os.path.join(repo, "runs", "goal-session-em")
os.makedirs(os.path.join(em_dir, "state"))
os.makedirs(os.path.join(em_dir, "iter-1"))
em_side = os.path.join(em_dir, "state", "journey-side-effects.json")
json.dump({"run_id": "goal-em-iter-1:1", "iter": 1, "observed_at": "2026-09-17T03:00:00.000000Z", "journeys": {},
           "sidecar": {"path": em_side, "updated": False, "message": "no journey was replayed"}},
          open(os.path.join(em_dir, "iter-1", "replay-side-effects.json"), "w"))
outs = []
for it in (2, 3):
    rc, so, se = cli("side-effects", goal_path, "--sidecar", em_side, "--out", os.path.join(em_dir, f"l{it}.json"),
                     "--iter", str(it), "--step", "preflight", "--record-digest", "--readonly-endpoints", ro)
    outs.append(so)
nd_dir = os.path.join(repo, "runs", "goal-session-nd")
os.makedirs(os.path.join(nd_dir, "state"))
os.makedirs(os.path.join(nd_dir, "iter-0"))
open(os.path.join(nd_dir, "iter-0", "side-effects.json"), "w").write("[]")
rc, so, se = cli("side-effects", goal_path, "--sidecar", os.path.join(nd_dir, "state", "journey-side-effects.json"),
                 "--out", os.path.join(nd_dir, "iter-1", "side-effects.json"), "--iter", "1", "--step", "preflight",
                 "--record-digest", "--readonly-endpoints", ro)
case("D28: a malformed earlier ledger ('[]') never breaks the declaration baseline", rc == 0 and "Traceback" not in se)
case("D27: a run record that observed no journey is merged once, silently (no repair event, nothing pending)",
     "side_effect_observations_repaired" not in "".join(outs)
     and json.load(open(os.path.join(em_dir, "l3.json")))["run_records_pending"] == []
     and "goal-em-iter-1:1" in json.load(open(em_side))["merged_runs"])
case("D23: goal_gate self-test passes (pins hash invariance + digest sensitivity)",
     subprocess.run([sys.executable, os.path.join(os.environ["PYTHONPATH"].split(":")[0], "goal_gate.py"), "self-test"],
                    capture_output=True).returncode == 0)
PY

# ── Part G: goal_lint.py ─────────────────────────────────────────────────────
echo "== G. goal_lint.py rules"
GL_OUT="$(python3 "$GL" "$WORK/repo/docs/goal.md" 2>&1)"; GL_RC=$?
printf '%s' "$GL_OUT" | grep -qE '^\[goal-lint\] ERROR side-effects-invalid line [0-9]+: .*J-03' && [[ "$GL_RC" == "2" ]] \
  && assert "G1: an invalid 'Side effects:' value is a goal-lint ERROR naming the journey (exit 2)" "pass" \
  || assert "G1: side-effects-invalid ERROR (rc=$GL_RC; $GL_OUT)" "fail"
if printf '%s' "$GL_OUT" | grep -qE '^\[goal-lint\] WARN side-effects-undeclared'; then
  assert "G2: undeclared journeys whose steps name no state-changing action (J-01, J-05) must not be flagged ($GL_OUT)" "fail"
else
  assert "G2: a journey whose steps name no state-changing action is NOT flagged" "pass"
fi
cat > "$WORK/undeclared.md" <<'EOF'
# Goal

## Must-have user journeys

- **J-01: Launch a run**
  - Steps:
    1. Open Backtests; set the dates;
       click Run and wait
  - Acceptance: a new run row appears

- **J-02: Read the run list**
  - Steps:
    1. Visit `/run-list`
  - Acceptance: rows render

## Anti-goals

- no paid SaaS
EOF
GU_OUT="$(python3 "$GL" "$WORK/undeclared.md" 2>&1)"; GU_RC=$?
printf '%s' "$GU_OUT" | grep -qE '^\[goal-lint\] WARN side-effects-undeclared line [0-9]+: .*J-01.*step 1' && [[ "$GU_RC" == "1" ]] \
  && assert "G3: an undeclared journey whose step mentions a mutating action ('click Run', continuation line) is a WARN naming the step" "pass" \
  || assert "G3: side-effects-undeclared WARN (rc=$GU_RC; $GU_OUT)" "fail"
printf '%s' "$GU_OUT" | grep -q 'J-02' \
  && assert "G3b: a word inside a code span ('/run-list') never triggers the warning" "fail" \
  || assert "G3b: code spans are not scanned for mutating words" "pass"
python3 "$GL" self-test >/dev/null 2>&1 \
  && assert "G4: goal_lint.py self-test passes (clean fixture stays finding-free with declarations)" "pass" \
  || assert "G4: goal_lint.py self-test" "fail"
cat > "$WORK/unattributed.md" <<'EOF'
# Goal

## Must-have user journeys

- **J-05: Checkout**
  1. Open /cart and click **Pay**
  - Acceptance: an order is placed
    - **J-12** follows on from this checkout
  - Side effects: mutating — places an order

## Anti-goals

- no paid SaaS
EOF
GA_OUT="$(python3 "$GL" "$WORK/unattributed.md" 2>&1)"
printf '%s' "$GA_OUT" | grep -qE '^\[goal-lint\] WARN side-effects-unattributed line [0-9]+: journey J-12: it is only mentioned inside other journeys' \
  && ! printf '%s' "$GA_OUT" | grep -q 'side-effects-invalid' \
  && assert "G6: a journey id the side-effect parser cannot attribute is a goal-lint WARN naming why" "pass" \
  || assert "G6: side-effects-unattributed WARN ($GA_OUT)" "fail"
cat > "$WORK/nested-note.md" <<'EOF'
# Goal

## Must-have user journeys

- **J-10: Recover the raw layer**
  - Steps:
    1. Visit `/recovery`
  - Acceptance: the restored rows render
  - **J-10 CLOSED — owner note, 2026-09-01**
    - evidence kept in the dev handoff
  - Side effects: none — the recovery page only reads the restored layer

- **J-11: Launch a rebuild**
  - Steps:
    1. Open Rebuild; click Run
  - Acceptance: a rebuild row appears

## Anti-goals

- no paid SaaS
EOF
GN_OUT="$(python3 "$GL" "$WORK/nested-note.md" 2>&1)"
if printf '%s' "$GN_OUT" | grep -q 'side-effects-invalid'; then
  assert "G5: a nested owner note under the same journey id is not a second definition ($GN_OUT)" "fail"
else
  printf '%s' "$GN_OUT" | grep -qE 'WARN side-effects-undeclared .*J-11 step 1' \
    && assert "G5: a nested same-id owner note keeps J-10's declaration valid; J-11's 'click Run' is still flagged" "pass" \
    || assert "G5: nested note + undeclared J-11 ($GN_OUT)" "fail"
fi

# ── Part L: iter_spec.py preflight rules ─────────────────────────────────────
echo "== L. preflight lint rules (iter_spec.py)"
SPECS="$WORK/specs"; mkdir -p "$SPECS"
LED_DECL="$WORK/ledger-declared.json"
python3 "$GG" side-effects "$WORK/repo/docs/goal.md" --out "$LED_DECL" >/dev/null 2>&1
# Observed-only ledger: J-04 is NOT declared mutating in this goal (declared none);
# the replay lane saw POST /api/runs in iteration 8.
sed 's/\*\*Side effects:\*\* Mutating — step 1 clicks Run/**Side effects:** none — step 1 clicks Run/' \
  "$WORK/repo/docs/goal.md" > "$WORK/repo/docs/goal-observed.md"
cat > "$WORK/sidecar-observed.json" <<'EOF'
{"schema_version": 1, "journeys": {"J-04": {"latest": {"iter": 8, "iter_name": "goal-x-iter-8",
 "complete": true, "verdict": "PASS", "mutating_count": 1, "auth_count": 0, "readonly_count": 0,
 "requests": [{"method": "POST", "path": "/api/runs", "class": "mutating", "count": 1}],
 "truncated": false, "exceptions_applied": [], "readonly_endpoints_sha256": null,
 "ignore_paths": ["/login", "/logout", "/auth", "/session", "/token", "/csrf"]}}}}
EOF
LED_OBS="$WORK/ledger-observed.json"
python3 "$GG" side-effects "$WORK/repo/docs/goal-observed.md" --sidecar "$WORK/sidecar-observed.json" \
  --readonly-endpoints "$WORK/none.txt" --out "$LED_OBS" >/dev/null 2>&1
# All-none ledger: every journey declared none.
python3 - "$WORK/repo/docs/goal.md" "$WORK/goal-allnone.md" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
t = re.sub(r"(?m)^  - (\*\*)?Side effects:(\*\*)?.*$", "", t)
t = re.sub(r"(?m)^(  - Acceptance:.*)$", r"\1\n  - Side effects: none — reads only", t)
open(sys.argv[2], "w").write(t)
PY
LED_NONE="$WORK/ledger-allnone.json"
python3 "$GG" side-effects "$WORK/goal-allnone.md" --readonly-endpoints "$WORK/none.txt" --out "$LED_NONE" >/dev/null 2>&1
# All-unknown ledger: no declarations at all.
python3 - "$WORK/repo/docs/goal.md" "$WORK/goal-unknown.md" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
t = re.sub(r"(?m)^  - (\*\*)?Side effects:(\*\*)?.*\n", "", t)
open(sys.argv[2], "w").write(t)
PY
LED_UNK="$WORK/ledger-unknown.json"
python3 "$GG" side-effects "$WORK/goal-unknown.md" --readonly-endpoints "$WORK/none.txt" --out "$LED_UNK" >/dev/null 2>&1
[[ -s "$LED_DECL" && -s "$LED_OBS" && -s "$LED_NONE" && -s "$LED_UNK" ]] \
  && assert "L0: the four fixture ledgers were built by the real goal_gate.py builder" "pass" \
  || assert "L0: fixture ledgers built" "fail"

# spec <file> <policy|-> <targets> <required> [out-of-scope-line] [tc-line] [dod-line]
spec() {
  local f="$1" pol="$2" tj="$3" rq="$4" oos="${5:-- Any code change to the engine}" tc="${6:-- TC-1: given the page, when opened, then the run list renders}" dod="${7:-- [ ] Target journeys pass via browser-qa-agent}"
  {
    echo "# Goal Iteration 9 — fixture"; echo
    echo "## Goal Mode Metadata"; echo
    echo "- **Session ID:** x"
    echo "- **Iteration:** 9"
    echo "- **Mode:** next"
    echo "- **Depth:** lean"
    echo "- **Target journeys:** $tj"
    echo "- **Required-still-passing journeys:** $rq"
    echo "- **Work kind:** verify-only"
    [[ "$pol" != "-" ]] && echo "- **Side-effect policy:** $pol"
    echo; echo "## GOAL"; echo; echo "Confirm; no code change, no new run."
    echo; echo "## IN SCOPE"; echo; echo "### Backend"; echo "- (none — no backend file is edited)"
    echo "### Frontend"; echo "- (none)"
    echo; echo "## OUT OF SCOPE"; echo; printf '%s\n' "$oos"
    echo; echo "## DEFINITION OF DONE"; echo; printf '%s\n' "$dod"
    echo; echo "## TESTING REQUIREMENTS"; echo; printf '%s\n' "$tc"
    echo; echo "## NOTES"; echo; echo "- the ledger row count is unchanged in prose here, which is not a machine constraint"
  } > "$f"
}
LINT_OUT=""; LINT_RC=0
export PROBE
lint() { LINT_OUT="$(python3 "$PROBE" lint "$@" 2>&1)"; LINT_RC=$?; }
has_rule() { printf '%s' "$LINT_OUT" | grep -qE "^\[spec-lint\] (ERROR|WARN) $1 "; }
rule_line() { printf '%s' "$LINT_OUT" | grep -E "^\[spec-lint\] (ERROR|WARN) $1 " | head -1; }

# TenSteps iteration-9 prohibitions, verbatim.
OOS9='- Any new portfolio run launch, sweep, or ledger write — the confirm pass reads existing runs and golden scripts only.'
TC9='- TC-4: given J-04'"'"'s stored golden script, when replayed, then run 80f6033fc85e43cb9a54ef35bc3bb151 is cited, `cli_profile --compare-run` on it prints `[profile] IDENTICAL`, and the ledger'"'"'s row count is unchanged before and after the replay (no new run created).'
TCROW='- TC-2: given the ledger, when the confirm pass finishes, then the ledger row count unchanged'

spec "$SPECS/l1.md" none "J-01, J-04" "J-02"
lint "$SPECS/l1.md" --side-effects "$LED_DECL"
[[ "$LINT_RC" == "1" ]] && has_rule E13 && rule_line E13 | grep -q 'J-04' && rule_line E13 | grep -q 'declared' \
  && rule_line E13 | grep -q 'step 1' \
  && assert "L1: policy none + target J-04 DECLARED mutating -> E13 naming J-04, the source and its step" "pass" \
  || assert "L1: E13 declared (rc=$LINT_RC; $LINT_OUT)" "fail"
spec "$SPECS/l2.md" none "J-04" "J-02"
lint "$SPECS/l2.md" --side-effects "$LED_OBS"
[[ "$LINT_RC" == "1" ]] && rule_line E13 | grep -q 'observed POST /api/runs in iter-8' \
  && assert "L2: an OBSERVED-only mutation (J-04 declared none) -> E13 'observed POST /api/runs in iter-8'" "pass" \
  || assert "L2: E13 observed (rc=$LINT_RC; $LINT_OUT)" "fail"
spec "$SPECS/l3.md" allowed "J-01, J-04" "J-02"
lint "$SPECS/l3.md" --side-effects "$LED_DECL"
[[ "$LINT_RC" == "0" ]] && ! has_rule E13 && ! has_rule E16 \
  && assert "L3: policy allowed + a mutating journey + no prohibition -> clean" "pass" \
  || assert "L3: allowed is clean (rc=$LINT_RC; $LINT_OUT)" "fail"
spec "$SPECS/l4.md" none "J-01, J-04" "J-02, J-05"
lint "$SPECS/l4.md" --side-effects "$LED_NONE"
[[ "$LINT_RC" == "0" ]] && ! has_rule E13 && ! has_rule W09 \
  && assert "L4: policy none + every checked journey declared none -> clean" "pass" \
  || assert "L4: all-none clean (rc=$LINT_RC; $LINT_OUT)" "fail"
spec "$SPECS/l5.md" none "J-01" "J-05"
lint "$SPECS/l5.md" --side-effects "$LED_UNK"
[[ "$LINT_RC" == "0" ]] && has_rule W09 && ! has_rule E14 \
  && assert "L5: policy none + unknown journeys -> W09 (warning only)" "pass" \
  || assert "L5: W09 (rc=$LINT_RC; $LINT_OUT)" "fail"
lint "$SPECS/l5.md" --side-effects "$LED_UNK" --strict-side-effects
[[ "$LINT_RC" == "1" ]] && has_rule E14 && ! has_rule W09 \
  && assert "L6: the same under strict mode -> E14" "pass" \
  || assert "L6: E14 strict (rc=$LINT_RC; $LINT_OUT)" "fail"
for pol in allowed none -; do
  spec "$SPECS/l7-$pol.md" "$pol" "J-04" "J-02" "- Any code change to the engine" "$TCROW"
  lint "$SPECS/l7-$pol.md" --side-effects "$LED_DECL"
  _ok=n
  [[ "$LINT_RC" == "1" ]] && has_rule E16 && rule_line E16 | grep -q 'J-04' && _ok=y
  [[ "$pol" == "none" ]] && { has_rule E13 || _ok=n; }
  [[ "$pol" == "-" ]] && { has_rule W02 || _ok=n; }
  [[ "$_ok" == y ]] \
    && assert "L7[$pol]: TC 'ledger row count unchanged' + mutating target -> E16 (policy '$pol')" "pass" \
    || assert "L7[$pol]: E16 (rc=$LINT_RC; $LINT_OUT)" "fail"
done
# The exact TenSteps iteration-9 contradiction.
for pol in allowed none -; do
  spec "$SPECS/l8-$pol.md" "$pol" "J-01, J-02, J-03, J-04, J-05" "same as Target journeys" "$OOS9" "$TC9"
  lint "$SPECS/l8-$pol.md" --side-effects "$LED_DECL"
  _n16="$(printf '%s' "$LINT_OUT" | grep -cE '^\[spec-lint\] ERROR E16 ' || true)"
  _ok=n
  [[ "$LINT_RC" == "1" && "${_n16:-0}" -ge 2 ]] && printf '%s' "$LINT_OUT" | grep -E '^\[spec-lint\] ERROR E16 ' | grep -q 'Any new portfolio run launch' \
    && printf '%s' "$LINT_OUT" | grep -E '^\[spec-lint\] ERROR E16 ' | grep -q 'click Run' && _ok=y
  [[ "$pol" == "none" ]] && { has_rule E13 || _ok=n; }
  [[ "$_ok" == y ]] \
    && assert "L8[$pol]: TenSteps iter-9 OUT OF SCOPE + TC-4 vs mutating J-04 -> E16 per prohibition, naming J-04's step (policy '$pol')" "pass" \
    || assert "L8[$pol]: iter-9 contradiction (rc=$LINT_RC n16=$_n16; $LINT_OUT)" "fail"
done
spec "$SPECS/l9.md" allowed "J-01" "J-05" "- Any code change to the engine" "$TCROW"
lint "$SPECS/l9.md" --side-effects "$LED_UNK"
[[ "$LINT_RC" == "0" ]] && has_rule W10 && ! has_rule E16 \
  && assert "L9: the same prohibition with only UNKNOWN journeys -> W10 (warning)" "pass" \
  || assert "L9: W10 (rc=$LINT_RC; $LINT_OUT)" "fail"
lint "$SPECS/l9.md" --side-effects "$LED_UNK" --strict-side-effects
[[ "$LINT_RC" == "1" ]] && has_rule E14 \
  && assert "L9b: ... and E14 in strict mode" "pass" \
  || assert "L9b: E14 for prohibition+unknown under strict (rc=$LINT_RC; $LINT_OUT)" "fail"
spec "$SPECS/l10.md" none "J-01" "J-02"
lint "$SPECS/l10.md" --side-effects "$WORK/does-not-exist.json"
[[ "$LINT_RC" == "1" ]] && has_rule E15 \
  && assert "L10: policy none + ledger ABSENT -> E15 (fail closed)" "pass" \
  || assert "L10: E15 absent (rc=$LINT_RC; $LINT_OUT)" "fail"
printf '{ corrupt' > "$WORK/ledger-corrupt.json"
lint "$SPECS/l10.md" --side-effects "$WORK/ledger-corrupt.json"
[[ "$LINT_RC" == "1" ]] && has_rule E15 \
  && assert "L10b: policy none + CORRUPT ledger -> E15" "pass" \
  || assert "L10b: E15 corrupt (rc=$LINT_RC; $LINT_OUT)" "fail"
python3 - "$LED_NONE" "$WORK/ledger-otherbuild.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["build_id"] = "an-earlier-build"
json.dump(d, open(sys.argv[2], "w"))
PY
lint "$SPECS/l10.md" --side-effects "$WORK/ledger-otherbuild.json" --side-effects-build-id "this-build"
[[ "$LINT_RC" == "1" ]] && has_rule E15 && rule_line E15 | grep -q 'stale' \
  && assert "L10e: a ledger left over from another build (the build that should have replaced it failed) -> E15" "pass" \
  || assert "L10e: stale ledger (rc=$LINT_RC; $LINT_OUT)" "fail"
printf '\xff\xfe{ bad bytes' > "$WORK/ledger-bytes.json"
lint "$SPECS/l10.md" --side-effects "$WORK/ledger-bytes.json"
[[ "$LINT_RC" == "1" ]] && has_rule E15 \
  && assert "L10f: an undecodable ledger is unavailable evidence (E15), never a linter crash" "pass" \
  || assert "L10f: undecodable ledger (rc=$LINT_RC; $LINT_OUT)" "fail"
cp "$LED_NONE" "$WORK/ledger-unreadable.json"; chmod 000 "$WORK/ledger-unreadable.json"
if [[ -r "$WORK/ledger-unreadable.json" ]]; then
  assert "L10c: (skipped — running as a user that can read a mode-000 file)" "pass"
else
  lint "$SPECS/l10.md" --side-effects "$WORK/ledger-unreadable.json"
  [[ "$LINT_RC" == "1" ]] && has_rule E15 \
    && assert "L10c: policy none + UNREADABLE ledger -> E15" "pass" \
    || assert "L10c: E15 unreadable (rc=$LINT_RC; $LINT_OUT)" "fail"
fi
chmod 644 "$WORK/ledger-unreadable.json"
python3 - "$LED_DECL" "$WORK/ledger-incomplete.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["complete"] = False; d["errors"] = ["sidecar unreadable: fixture"]
json.dump(d, open(sys.argv[2], "w"))
PY
spec "$SPECS/l10d.md" none "J-04" "J-02"
lint "$SPECS/l10d.md" --side-effects "$WORK/ledger-incomplete.json"
[[ "$LINT_RC" == "1" ]] && has_rule E15 && has_rule E13 \
  && assert "L10d: an INCOMPLETE ledger is unavailable evidence (E15) yet its declared mutations still count (E13)" "pass" \
  || assert "L10d: incomplete ledger (rc=$LINT_RC; $LINT_OUT)" "fail"
for pol in allowed -; do
  spec "$SPECS/l11-$pol.md" "$pol" "J-01" "J-02"
  lint "$SPECS/l11-$pol.md" --side-effects "$WORK/does-not-exist.json"
  [[ "$LINT_RC" == "0" ]] && has_rule W11 && ! has_rule E15 \
    && assert "L11[$pol]: policy '$pol' + ledger absent -> W11 only, dispatch permitted" "pass" \
    || assert "L11[$pol]: W11 (rc=$LINT_RC; $LINT_OUT)" "fail"
done
spec "$SPECS/l12.md" "nothing mutates" "J-01" "J-02"
lint "$SPECS/l12.md" --side-effects "$LED_DECL"
[[ "$LINT_RC" == "1" ]] && has_rule E06 \
  && assert "L12: an invalid Side-effect policy value -> E06" "pass" \
  || assert "L12: E06 (rc=$LINT_RC; $LINT_OUT)" "fail"
spec "$SPECS/l12b.md" - "J-01" "J-02"
lint "$SPECS/l12b.md"
[[ "$LINT_RC" == "0" ]] && has_rule W02 \
  && assert "L12b: no Side-effect policy line -> W02 (even without --side-effects)" "pass" \
  || assert "L12b: W02 (rc=$LINT_RC; $LINT_OUT)" "fail"
spec "$SPECS/l12c.md" allowed "J-01" "J-02"
sed -i 's/^- \*\*Side-effect policy:\*\* allowed/Side-effect policy: allowed/' "$SPECS/l12c.md"
lint "$SPECS/l12c.md"
[[ "$LINT_RC" == "1" ]] && has_rule E02 && rule_line E02 | grep -q 'Side-effect policy' \
  && assert "L12c: a plain-form Side-effect policy line -> E02 naming the canonical bold form" "pass" \
  || assert "L12c: E02 policy (rc=$LINT_RC; $LINT_OUT)" "fail"
# The tripwire: a re-plan that flips none -> allowed but keeps the prohibition.
spec "$SPECS/l13.md" allowed "J-01, J-02, J-03, J-04, J-05" "same as Target journeys" "$OOS9" "$TC9"
lint "$SPECS/l13.md" --side-effects "$LED_DECL"
[[ "$LINT_RC" == "1" ]] && has_rule E16 && ! has_rule E13 \
  && assert "L13: a none->allowed flip with the prohibition UNCHANGED is still blocked by E16 (the plan's tripwire)" "pass" \
  || assert "L13: flip still blocked (rc=$LINT_RC; $LINT_OUT)" "fail"
# The corrected TenSteps spec: allowed + invariant TCs + a rephrased exclusion.
OOSFIX='- Launching portfolio runs beyond J-04'"'"'s own step 1, sweeps, or edits to pre-existing ledger rows — the confirm pass otherwise reads existing runs only.'
TCFIX='- TC-4: given J-04'"'"'s stored golden script, when replayed, then run 80f6033fc85e43cb9a54ef35bc3bb151 is cited, `cli_profile --compare-run` on it prints `[profile] IDENTICAL`, and no PRE-EXISTING ledger row is edited or deleted (J-04'"'"'s own Run step may append its new row).'
spec "$SPECS/l14.md" allowed "J-01, J-02, J-03, J-04, J-05" "same as Target journeys" "$OOSFIX" "$TCFIX"
lint "$SPECS/l14.md" --side-effects "$LED_DECL"
[[ "$LINT_RC" == "0" ]] && ! has_rule E13 && ! has_rule E16 && ! has_rule W10 \
  && assert "L14: the corrected iter-9 spec (allowed + invariant TC-4 + rephrased exclusion) passes" "pass" \
  || assert "L14: corrected spec passes (rc=$LINT_RC; $LINT_OUT)" "fail"
spec "$SPECS/l15.md" none "J-01" "J-04"
lint "$SPECS/l15.md" --side-effects "$LED_DECL"
rule_line E13 | grep -qi 'may NOT be dropped' && ! rule_line E13 | grep -qi 'drop it from Target' \
  && assert "L15: a mutating REQUIRED journey is never offered as droppable" "pass" \
  || assert "L15: required journey not droppable ($LINT_OUT)" "fail"
spec "$SPECS/l15b.md" none "J-04" "J-02"
lint "$SPECS/l15b.md" --side-effects "$LED_DECL"
rule_line E13 | grep -qi 'drop it from Target journeys' \
  && assert "L15b: a mutating TARGET-only journey may be dropped from targets (never from Required)" "pass" \
  || assert "L15b: target journey droppable ($LINT_OUT)" "fail"
spec "$SPECS/l16.md" none "J-01" "J-02"
lint "$SPECS/l16.md" --side-effects "$LED_DECL" --makeup-journeys "J-04"
[[ "$LINT_RC" == "1" ]] && rule_line E13 | grep -q 'J-04' \
  && assert "L16: an engine-scheduled make-up journey is part of the checked set" "pass" \
  || assert "L16: make-up journeys checked (rc=$LINT_RC; $LINT_OUT)" "fail"
spec "$SPECS/l17.md" none "J-04" "J-02" "- Any code change to the engine" "$TCROW"
lint "$SPECS/l17.md"
[[ "$LINT_RC" == "0" ]] && ! has_rule E13 && ! has_rule E16 && ! has_rule E15 \
  && assert "L17: without --side-effects the ledger rules are skipped (HARD-2 standalone compatibility)" "pass" \
  || assert "L17: no ledger -> no ledger rules (rc=$LINT_RC; $LINT_OUT)" "fail"
spec "$SPECS/l18.md" allowed "J-04" "J-02"
lint "$SPECS/l18.md" --side-effects "$LED_DECL"
! has_rule E16 \
  && assert "L18: prohibition-shaped prose in GOAL/NOTES is not a machine constraint (only OUT OF SCOPE, TC-, DoD)" "pass" \
  || assert "L18: prose ignored ($LINT_OUT)" "fail"
spec "$SPECS/l18b.md" allowed "J-04" "J-02" "- Any code change to the engine" "- TC-1: given x, when y, then z" "- [ ] no new rows appear in the ledger"
lint "$SPECS/l18b.md" --side-effects "$LED_DECL"
has_rule E16 && rule_line E16 | grep -q 'DEFINITION OF DONE' \
  && assert "L18b: a DoD prohibition is scanned too" "pass" \
  || assert "L18b: DoD prohibition (rc=$LINT_RC; $LINT_OUT)" "fail"
# A re-planned spec explains the rejected wording in BACKGROUND / NOTES; that
# prose — TC- bullets included — must not block the corrected spec again.
spec "$SPECS/l18c.md" allowed "J-04" "J-02" "$OOSFIX" "$TCFIX"
python3 - "$SPECS/l18c.md" <<'PY'
import sys
t = open(sys.argv[1]).read()
t = t.replace("## GOAL\n\nConfirm; no code change, no new run.\n",
              "## GOAL\n\nConfirm; no code change, no new run.\n\n## BACKGROUND\n\n"
              "- TC-4 asserted that the ledger row count is unchanged, but J-04's own step launches a run.\n")
t = t.rstrip("\n") + "\n- TC-4 (old wording \"no new run\") was a spec/journey contradiction.\n"
open(sys.argv[1], "w").write(t)
PY
lint "$SPECS/l18c.md" --side-effects "$LED_DECL"
[[ "$LINT_RC" == "0" ]] && ! has_rule E16 \
  && assert "L18c: TC- bullets under BACKGROUND / NOTES are prose, not machine constraints" "pass" \
  || assert "L18c: TC prose ignored (rc=$LINT_RC; $LINT_OUT)" "fail"
_l18d=y
for form in '- [ ] TC-3: given the ledger, when the replay ends, then the ledger row count is unchanged' \
            '1. TC-3: given the ledger, when replayed, then the number of ledger rows is unchanged' \
            '| TC-3 | replay J-04 | ledger row count unchanged |' \
            $'- **TC-3** (J-04 confirm-only):\n  - then: no new portfolio runs exist'; do
  spec "$SPECS/l18d.md" allowed "J-04" "J-02" "- Any code change to the engine" "$form"
  lint "$SPECS/l18d.md" --side-effects "$LED_DECL"
  { has_rule E16 && rule_line E16 | grep -q 'TC-3'; } || { _l18d=n; echo "      (not caught: $form)"; }
done
[[ "$_l18d" == y ]] \
  && assert "L18d: checkbox, numbered, table and sub-bulleted TC- lines are scanned (and close wording variants)" "pass" \
  || assert "L18d: TC forms" "fail"
_l18f=y
for form in "- TC-4: given J-04's golden, when replayed (launching a new run is expected — J-04 step 1), then no pre-existing ledger row is edited or deleted" \
            "- TC-4: J-04's own Run step is expected to be adding a new ledger row; no pre-existing row changes" \
            "- TC-4: after creating the new ledger entries in step 1, the inspector lists them" \
            "- TC-4: given the ledger, when J-04 replays, then the pre-existing ledger row count is unchanged"; do
  spec "$SPECS/l18f.md" allowed "J-04" "J-02" "- Any code change to the engine" "$form"
  lint "$SPECS/l18f.md" --side-effects "$LED_DECL"
  if has_rule E16; then _l18f=n; echo "      (false positive: $form)"; fi
done
spec "$SPECS/l18f.md" allowed "J-04" "J-02" "- Launching a new backtest run from the UI" "- TC-1: given x, when y, then z" \
  "- [ ] No creating or editing of ledger rows during the confirm pass"
lint "$SPECS/l18f.md" --side-effects "$LED_DECL"
[[ "$(printf '%s' "$LINT_OUT" | grep -cE '^\[spec-lint\] ERROR E16 ' || true)" -ge 2 ]] || { _l18f=n; echo "      (negated / OUT OF SCOPE forms not caught: $LINT_OUT)"; }
[[ "$_l18f" == y ]] \
  && assert "L18f: affirmative invariants (the wording the fix text asks for) never hit E16; OUT OF SCOPE and negated forms still do" "pass" \
  || assert "L18f: negation-aware patterns" "fail"
_l18g=y
for form in '### TC-4 — the ledger row count is unchanged' '- `TC-4`: the ledger row count is unchanged' \
            '- TC-4a: the ledger row count is unchanged'; do
  spec "$SPECS/l18g.md" allowed "J-04" "J-02" "- Any code change to the engine" "$form"
  lint "$SPECS/l18g.md" --side-effects "$LED_DECL"
  { has_rule E16 && rule_line E16 | grep -q 'TC-4'; } || { _l18g=n; echo "      (not caught: $form)"; }
done
spec "$SPECS/l18g.md" allowed "J-04" "J-02" "- Any new portfolio run launch"
sed -i 's/^## OUT OF SCOPE$/## NOT IN SCOPE/' "$SPECS/l18g.md"
lint "$SPECS/l18g.md" --side-effects "$LED_DECL"
{ has_rule E16 && rule_line E16 | grep -q 'OUT OF SCOPE'; } || { _l18g=n; echo "      (NOT IN SCOPE heading not scanned)"; }
[[ "$_l18g" == y ]] \
  && assert "L18g: heading-form, backticked and suffixed TC ids and a 'NOT IN SCOPE' heading are scanned" "pass" \
  || assert "L18g: more TC shapes" "fail"
_l18h=y
for form in "- TC-4: then the existing ledger's row count is unchanged" "- TC-4: the existing ledger stays untouched" \
            "- TC-4: as in the previous iteration, the ledger row count is unchanged" \
            "- TC-4: then the Prior ledger row count is unchanged after the replay"; do
  spec "$SPECS/l18h.md" allowed "J-04" "J-02" "- Any code change to the engine" "$form"
  lint "$SPECS/l18h.md" --side-effects "$LED_DECL"
  has_rule E16 || { _l18h=n; echo "      (missed: $form)"; }
done
spec "$SPECS/l18h.md" allowed "J-04" "J-02" "- The existing ledger is left untouched by the confirm pass"
lint "$SPECS/l18h.md" --side-effects "$LED_DECL"
has_rule E16 || { _l18h=n; echo "      (missed: OUT OF SCOPE 'existing ledger left untouched')"; }
[[ "$_l18h" == y ]] \
  && assert "L18h: 'existing' / 'prior' / 'previous' wording never hides a whole-ledger or row-count prohibition" "pass" \
  || assert "L18h: qualified prohibitions" "fail"
_l18i=y
for pair in "tc|- TC-4: then no row is edited, launching a new run is expected" \
            "dod|- [ ] Without errors, starting a new run from J-04 succeeds" \
            "tc|- TC-4: Creating or editing ledger rows does not happen during the replay" "tc|- TC-4: Avoid launching a new run" \
            "dod|- [ ] Launching a new backtest run is not part of this pass"; do
  where="${pair%%|*}"; line="${pair#*|}"
  if [[ "$where" == tc ]]; then
    spec "$SPECS/l18i.md" allowed "J-04" "J-02" "- Any code change to the engine" "$line"
  else
    spec "$SPECS/l18i.md" allowed "J-04" "J-02" "- Any code change to the engine" "- TC-1: given x, when y, then z" "$line"
  fi
  lint "$SPECS/l18i.md" --side-effects "$LED_DECL"
  { has_rule E16 && rule_line E16 | grep -q 'is a prohibition when a negation reaches it'; } \
    || { _l18i=n; echo "      (not read as a prohibition, or without the rule's rewrite advice: $line)"; }
done
spec "$SPECS/l18i.md" allowed "J-04" "J-02" "- Any code change to the engine" \
  "- TC-4: then no pre-existing row is edited; launching a new run is expected" \
  "- [ ] Starting a new run from J-04 succeeds and shows its row"
lint "$SPECS/l18i.md" --side-effects "$LED_DECL"
if has_rule E16; then _l18i=n; echo "      (a rewrite the rule allows was flagged: $(rule_line E16))"; fi
[[ "$_l18i" == y ]] \
  && assert "L18i: a TC / DoD sentence that names an activity and holds a negation that reaches it is E16 with the rewrite advice; the rewrites are clean" "pass" \
  || assert "L18i: negation scope" "fail"
spec "$SPECS/l18j.md" allowed "J-04" "J-02" "- Any code change to the engine" $'### TC-4 — replay J-04\n\nthe ledger row count is unchanged after the replay'
lint "$SPECS/l18j.md" --side-effects "$LED_DECL"
has_rule E16 && rule_line E16 | grep -q 'TC-4' \
  && assert "L18j: the body of a '### TC-4' heading is part of that test case" "pass" \
  || assert "L18j: heading TC body ($LINT_OUT)" "fail"
_l18k=y
for pair in "tc|- TC-4: then the replay completes without creating, editing or deleting ledger rows" \
            "tc|- TC-4: never (even on retry) starting a new run" \
            "tc|- TC-4: the pass does not, at any point, launch a new run" \
            "tc|- TC-4: do not click Run to launch a new run" \
            "dod|- [ ] No creating, editing, or deleting of ledger rows" \
            "dod|- [ ] The confirm pass completes without, at any point, launching a new run" \
            "oos|- Editing (or deleting) ledger rows" \
            "oos|- Launching – even for a smoke check – a new portfolio run"; do
  where="${pair%%|*}"; line="${pair#*|}"
  case "$where" in
    tc) spec "$SPECS/l18k.md" allowed "J-04" "J-02" "- Any code change to the engine" "$line" ;;
    dod) spec "$SPECS/l18k.md" allowed "J-04" "J-02" "- Any code change to the engine" "- TC-1: given x, when y, then z" "$line" ;;
    *) spec "$SPECS/l18k.md" allowed "J-04" "J-02" "$line" ;;
  esac
  lint "$SPECS/l18k.md" --side-effects "$LED_DECL"
  has_rule E16 || { _l18k=n; echo "      (missed: $line)"; }
done
[[ "$_l18k" == y ]] \
  && assert "L18k: a negation still reaches the activity across a verb list, a comma or parenthetical aside or a pass-through verb" "pass" \
  || assert "L18k: coordinated / aside negations" "fail"
_l18l=y
for line in "- TC-4: launching a new run must not modify any pre-existing ledger row" \
            "- TC-4: launching a new run adds one ledger row and does not edit or delete any pre-existing row" \
            "- TC-4: when launching a new run, pre-existing rows are not edited" \
            "- TC-4: no pre-existing ledger row is edited while launching a new run" \
            "- TC-4: whether or not launching a new run succeeds, the list renders" \
            "- TC-4: launching a new run shows the new row within 2 seconds" \
            "- TC-12: given an invalid date range, when the user clicks Run, then a validation error is shown and no run is launched."; do
  spec "$SPECS/l18l.md" allowed "J-04" "J-02" "- Any code change to the engine" "$line"
  lint "$SPECS/l18l.md" --side-effects "$LED_DECL"
  if has_rule E16; then _l18l=n; echo "      (false positive: $line)"; fi
done
spec "$SPECS/l18l.md" allowed "J-04" "J-02" "- Any code change to the engine" \
  "- TC-4: launching a new run must not modify pre-existing rows or launch a second new run"
lint "$SPECS/l18l.md" --side-effects "$LED_DECL"
has_rule E16 || { _l18l=n; echo "      (an activity joined by 'or' to a pre-existing object escaped)"; }
[[ "$_l18l" == y ]] \
  && assert "L18l: invariants on pre-existing data, positive wording, idioms and negative-path checks are never E16 ('or' still joins an activity)" "pass" \
  || assert "L18l: invariant wording" "fail"
_l18m=y
spec "$SPECS/l18m.md" allowed "J-04" "J-02" "- Full-archive verification runs — not applicable; no run is launched this iteration."
lint "$SPECS/l18m.md" --side-effects "$LED_DECL"
has_rule E16 || { _l18m=n; echo "      (missed: 'no run is launched')"; }
spec "$SPECS/l18m.md" allowed "J-04" "J-02" "- Any code change to the engine" \
  "- TC-4: given a malformed submission, when it is submitted, then it is refused and no record is written."
lint "$SPECS/l18m.md" --side-effects "$LED_DECL"
if has_rule E16; then _l18m=n; echo "      (false positive on a negative-path assertion)"; fi
for line in "- TC-12: given an unknown key, when POST /api/runs is called, then the API responds 400 naming the unknown key, and no run is created." \
            "- TC-13: given an invalid date range, when the user clicks Run, then a validation error is shown and no run is launched."; do
  spec "$SPECS/l18m.md" allowed "J-04" "J-02" "- Any code change to the engine" "$line"
  lint "$SPECS/l18m.md" --side-effects "$LED_DECL"
  if has_rule E16; then _l18m=n; echo "      (false positive on a negative-path run assertion: $line)"; fi
done
[[ "$_l18m" == y ]] \
  && assert "L18m: 'no run is launched' (TenSteps iter-7/8 wording) is a prohibition; a negative-path 'no record is written' is not" "pass" \
  || assert "L18m: passive wording" "fail"
_l18n=y
spec "$SPECS/l18n.md" allowed "J-04" "J-02" "- Any code change to the engine" "- TC-4: the ledger row count is unchanged"
python3 - "$SPECS/l18n.md" <<'PY'
import sys
t = open(sys.argv[1]).read()
t = t.replace("Confirm; no code change, no new run.", "Confirm; no code change, no new run.\n\n```bash\nmake run\n")
t = t.replace("## NOTES", "```\nmake test\n```\n\n## NOTES")
open(sys.argv[1], "w").write(t)
PY
lint "$SPECS/l18n.md" --side-effects "$LED_DECL"
{ has_rule E16 && rule_line E16 | grep -q 'TC-4'; } || { _l18n=n; echo "      (a shifted fence hid TC-4: $LINT_OUT)"; }
spec "$SPECS/l18n.md" allowed "J-04" "J-02" "- Any new portfolio run launch"
python3 - "$SPECS/l18n.md" <<'PY'
import sys
t = open(sys.argv[1]).read()
open(sys.argv[1], "w").write("```markdown\n" + t + "```\n")
PY
lint "$SPECS/l18n.md" --side-effects "$LED_DECL"
{ has_rule E16 && rule_line E16 | grep -q 'OUT OF SCOPE'; } || { _l18n=n; echo "      (a wholly fenced spec hid its prohibition: $LINT_OUT)"; }
[[ "$_l18n" == y ]] \
  && assert "L18n: a stray fence that shifts the pairing, or a spec wrapped in a fence, never hides a prohibition" "pass" \
  || assert "L18n: fence-blind prohibition scan" "fail"
PYTHONPATH="$LIB" python3 - <<'PY' && assert "L18o: the labelled negation table — every prohibition wording is reported, every other line is not" "pass" || assert "L18o: negation table" "fail"
import sys
import iter_spec as S
T = ("## Goal Mode Metadata\n- **Depth:** lean\n\n## OUT OF SCOPE\n{oos}\n\n## TESTING REQUIREMENTS\n{tc}\n\n"
     "## DEFINITION OF DONE\n{dod}\n")
# (expected: P = a prohibition, I = not one; where; line) — review rounds 4-7 plus the implementer's. The
# rule (iter_spec.py): a TC / DoD sentence that names an activity is a prohibition when a negation reaches
# it — a verbal negation anywhere in the sentence, a noun-phrase negation (no, none, without, …) before it in
# its own clause, inside its phrase or as its predicate — unless the negation is about "pre-existing" data
# or is a "no …" result of a refused request.
CASES = [
    ('P', 'tc', '- TC-4: then the replay completes without altering, creating or deleting ledger rows'),
    ('P', 'tc', '- TC-4: then the replay completes without touching, creating or deleting ledger rows'),
    ('P', 'tc', '- TC-4: then the replay completes without mutating, adding or removing ledger rows'),
    ('P', 'tc', '- TC-4: then the replay completes without reordering or deleting ledger rows'),
    ('P', 'tc', '- TC-4: the confirm pass finishes without queueing or starting a new run'),
    ('P', 'tc', '- TC-4: the confirm pass finishes without scheduling, queuing or launching a new run'),
    ('P', 'dod', '- [ ] Confirmed without amending, editing or deleting ledger entries'),
    ('P', 'tc', '- TC-4: the confirm pass completes without editing the ledger or launching a new run'),
    ('P', 'tc', '- TC-4: the confirm pass completes without modifying the ledger or launching a new run'),
    ('P', 'dod', '- [ ] The pass completes without touching the ledger or starting a new run'),
    ('P', 'tc', '- TC-4: the confirm pass completes without anyone launching a new run'),
    ('P', 'tc', '- TC-4: the confirm pass completes without the user launching a new run'),
    ('P', 'tc', '- TC-4: the confirm pass completes without the browser lane launching a new run'),
    ('P', 'tc', '- TC-4: the replay completes without Playwright starting a new run'),
    ('P', 'dod', '- [ ] The replay completes without the engine triggering any new run'),
    ('P', 'tc', '- TC-4: never re-launching a new run'),
    ('P', 'tc', '- TC-4: the retry completes without re-adding ledger rows'),
    ('P', 'tc', '- TC-4: the retry completes without re-writing ledger rows'),
    ('P', 'tc', '- TC-4: the retry completes without re-inserting ledger rows'),
    ('P', 'tc', '- TC-4: the replay does not itself launch a new run'),
    ('P', 'tc', '- TC-4: the replay must not go on to launch a new run'),
    ('P', 'tc', '- TC-4: the confirm must not end up launching a new run'),
    ('P', 'tc', '- TC-4: the replay must not then launch a new run'),
    ('P', 'tc', '- TC-4: without *any* user launching a new run'),
    ('P', 'tc', '- TC-4: without the need of launching a new run'),
    ('P', 'tc', '- TC-4: never, even once, launching a new run'),
    ('P', 'tc', '- TC-4: without (re)creating ledger rows'),
    ('P', 'tc', '- TC-4: never launching a new run (J-04 excluded)'),
    ('P', 'tc', '- TC-4: the replay does not launch or start a new run'),
    ('P', 'tc', '- TC-4: do NOT under any circumstances launch a new run'),
    ('P', 'tc', '- TC-4: there is no launching of new runs'),
    ('P', 'dod', '- [ ] Not launching any new portfolio run'),
    ('P', 'dod', '- [ ] Verified without, e.g., launching a new run'),
    ('P', 'tc', '- TC-4: without launching a new run or editing ledger rows'),
    ('P', 'tc', '- TC-4: no ledger rows are edited and no one starts a new run'),
    ('P', 'tc', '- TC-4: without launching a single new run'),
    ('P', 'tc', '- TC-4: without launching a new backtest run'),
    ('P', 'tc', '- TC-4: without launching yet another new run'),
    ('P', 'tc', '- TC-4: without launching a brand new portfolio run'),
    ('P', 'tc', '- TC-4: the confirm pass must never launch a new run.'),
    ('P', 'tc', '- TC-4: the tester must not accidentally launch a new run'),
    ('P', 'tc', '- TC-4: the operator should not click **Run** to launch a new run'),
    ('P', 'tc', '- TC-4: the replay does not (and must not) launch a new run'),
    ('P', 'tc', '- TC-4: the replay neither launches a new run nor edits ledger rows'),
    ('P', 'tc', '- TC-4: nor does it launch a new run'),
    ('P', 'tc', '- TC-4: launching a new run must not be part of this pass'),
    ('P', 'tc', '- TC-4: launching a new run should not be part of the confirm pass'),
    ('P', 'tc', '- TC-4: launching a new run is not expected to happen'),
    ('P', 'tc', '- TC-4: launching a new run is not OK in this pass'),
    ('P', 'tc', '- TC-4: starting a new run does not belong in this iteration'),
    ('P', 'tc', '- TC-4: editing ledger rows will not be tolerated'),
    ('P', 'tc', "- TC-4: creating ledger rows is not in this iteration's scope"),
    ('P', 'tc', "- TC-4: launching a new run isn't allowed"),
    ('P', 'tc', '- TC-4: launching a new run is NOT allowed during the confirm pass'),
    ('P', 'tc', '- TC-4: launching a new run is not permitted'),
    ('P', 'tc', '- TC-4: launching a new run must not happen'),
    ('P', 'tc', '- TC-4: launching a new run is out of scope'),
    ('P', 'tc', '- TC-4: launching a new run is not part of this pass'),
    ('P', 'tc', '- TC-4: launching a new run must not occur during the confirm pass'),
    ('P', 'tc', '- TC-4: launching a new run from the confirm page is not allowed'),
    ('P', 'tc', '- TC-4: launching a new run — not allowed'),
    ('P', 'tc', '- TC-4: launching a new run: not allowed'),
    ('P', 'dod', '- [ ] Launching a new run is excluded from this pass'),
    ('P', 'dod', '- [ ] Launching a new run must not be attempted'),
    ('P', 'dod', '- [ ] Launching a new run: forbidden'),
    ('P', 'dod', '- [ ] Forbidden: launching a new run'),
    ('P', 'dod', '- [ ] Not allowed: launching a new run or editing ledger rows'),
    ('P', 'dod', '- [ ] Launching a new run is never acceptable'),
    ('P', 'dod', '- [ ] Adding ledger rows is not allowed'),
    ('P', 'dod', "- [ ] Adding ledger rows doesn't happen"),
    ('P', 'dod', "- [ ] Adding ledger rows won't happen"),
    ('P', 'oos', '- Launching a new run'),
    ('P', 'oos', '- Re-launching a new run'),
    ('P', 'oos', '- Relaunching or starting a new run'),
    ('P', 'oos', '- Editing (or deleting) ledger rows'),
    ('P', 'oos', '- Launching – even for a smoke check – a new portfolio run'),
    ('P', 'oos', '- Launch a new run'),
    ('P', 'oos', '- Create or edit ledger rows'),
    ('P', 'oos', '- New run launches'),
    ('P', 'oos', '- Starting any new runs'),
    ('P', 'oos', '- Ledger row edits or new ledger rows'),
    ('I', 'tc', '- TC-4: launching a new run must not modify any pre-existing ledger row'),
    ('P', 'tc', '- TC-4: launching a new run is not blocked by the confirm dialog'),
    ('P', 'tc', '- TC-4: starting a new run does not require a page reload'),
    ('P', 'tc', '- TC-4: appending ledger rows does not rewrite earlier rows'),
    ('P', 'tc', '- TC-4: no confirm dialog blocks launching a new run'),
    ('I', 'tc', '- TC-4: no error appears when launching a new run'),
    ('I', 'tc', '- TC-4: whether or not launching a new run succeeds, the list renders'),
    ('I', 'tc', "- TC-4: J-04's Run step may add a new ledger row; no pre-existing ledger row is edited"),
    ('I', 'tc', '- TC-4: given no run exists yet, when the user starts a new run, then a row is added'),
    ('P', 'tc', '- TC-4: the page does not reload when launching a new run'),
    ('P', 'tc', '- TC-4: the list does not flicker while starting a new run'),
    ('P', 'tc', '- TC-4: the Run button is not disabled after launching a new run'),
    ('I', 'tc', '- TC-4: no spinner remains after launching a new run'),
    ('I', 'tc', '- TC-4: no stale data is shown after launching a new run'),
    ('P', 'tc', '- TC-4: the dialog does not appear twice when launching a new run'),
    ('P', 'tc', '- TC-4: the app never crashes when launching a new run'),
    ('I', 'tc', '- TC-4: nothing breaks when launching a new run'),
    ('I', 'tc', '- TC-4: no confirmation is needed before launching a new run'),
    ('P', 'tc', '- TC-4: without reloading the page, launching a new run shows the new row'),
    ('P', 'tc', '- TC-4: without errors, launching a new run adds one row'),
    ('I', 'tc', '- TC-4: no console errors while launching a new run'),
    ('P', 'tc', '- TC-4: no network errors during launching a new run'),
    ('P', 'tc', '- TC-4: the user is never asked twice before launching a new run'),
    ('P', 'tc', '- TC-4: the user never sees a stale row after launching a new run'),
    ('P', 'tc', '- TC-4: there is no delay in launching a new run'),
    ('P', 'tc', '- TC-4: no extra clicks are needed for launching a new run'),
    ('I', 'tc', '- TC-4: no double-submit when launching a new run'),
    ('I', 'tc', '- TC-4: no duplicate rows when launching a new run twice'),
    ('P', 'tc', '- TC-4: without a page reload, starting a new run shows its row'),
    ('P', 'tc', '- TC-4: a user without admin rights can still launch a new run'),
    ('P', 'tc', '- TC-4: never more than one spinner while launching a new run'),
    ('P', 'dod', '- [ ] No regressions in launching a new run'),
    ('I', 'dod', '- [ ] No flakiness when adding ledger rows'),
    ('I', 'dod', '- [ ] Not only listing but also launching a new run works'),
    ('P', 'dod', '- [ ] No manual steps required for launching a new run'),
    ('P', 'dod', '- [ ] No failures in the replay, including launching a new run'),
    ('I', 'dod', '- [ ] Launching a new run is expected and succeeds'),
    ('P', 'dod', '- [ ] Launching a new run does not fail'),
    ('P', 'dod', '- [ ] Launching a new run is not slow'),
    ('P', 'dod', '- [ ] Launching a new run is not broken'),
    ('P', 'dod', '- [ ] Launching a new run is not expected to fail'),
    ('P', 'dod', '- [ ] Adding ledger rows is not blocked'),
    ('P', 'dod', '- [ ] Adding ledger rows does not corrupt the file'),
    ('I', 'dod', '- [ ] Adding ledger rows must not change pre-existing rows'),
    ('I', 'dod', '- [ ] No pre-existing ledger row is edited while launching a new run'),
    ('P', 'dod', '- [ ] No old run is touched by launching a new run'),
    ('I', 'dod', '- [ ] No pre-existing row is edited or deleted (J-04 may add its own new run)'),
    ('I', 'dod', '- [ ] J-04 passes (its step 1 launches a new run; no pre-existing ledger row changes)'),
    ('P', 'tc', '- TC-4: the replay may be creating a report, but never deleting ledger rows'),
    ('P', 'tc', '- TC-4: when adding a note, never deleting ledger rows'),
    ('P', 'oos', '- Launching\xa0a new run'),
    ('P', 'tc', '- TC-4: without launching\xa0a new run'),
    ('I', 'tc', '- TC-12: given a `param_overrides` payload containing an unknown key, when `POST /api/runs` is called, then the API responds 400 naming the unknown key, and no run is created.'),
    ('I', 'tc', '- TC-12: given an invalid date range, when the user clicks Run, then a validation error is shown and no run is launched.'),
    ('I', 'tc', '- TC-12: given an invalid form, when submitted, then it is refused and no record is written.'),
    ('P', 'tc', '- TC-4: no user who launches a new run sees an error'),
    ('P', 'tc', '- TC-4: launching a new run is not required to view the list'),
    ('P', 'tc', '- TC-4: then the replay completes without creating, editing or deleting ledger rows'),
    ('P', 'tc', '- TC-4: without writing, appending or editing any ledger rows'),
    ('P', 'tc', '- TC-4: then the replay finishes without launching, starting or triggering a new run'),
    ('P', 'tc', '- TC-4: never creating, editing, or deleting ledger entries during the replay'),
    ('P', 'dod', '- [ ] The confirm pass is done without creating, editing or deleting ledger rows'),
    ('P', 'tc', '- TC-4: no creating, editing or appending of ledger rows'),
    ('P', 'tc', '- TC-4: the pass does not, at any point, launch a new run'),
    ('P', 'tc', '- TC-4: without starting a new backtest run'),
    ('P', 'tc', '- TC-4: avoid launching a new run'),
    ('P', 'tc', '- TC-4: Creating or editing ledger rows does not happen'),
    ('P', 'dod', '- [ ] Launching a new backtest run is not part of this pass'),
    ('P', 'dod', '- [ ] Launching a new backtest run is not broken by the refactor'),
    ('P', 'tc', '- TC-4: the confirm dialog prevents launching a new run twice on a double click'),
    ('P', 'tc', '- TC-4: then no row is edited, launching a new run is expected'),
    ('I', 'tc', "- TC-4: no pre-existing ledger row is edited or deleted; J-04's own Run step may add its new row"),
    ('I', 'tc', '- TC-4: then the pre-existing ledger row count is unchanged and one new row is appended'),
    ('I', 'tc', '- TC-4: when launching a new run, pre-existing rows are not edited'),
    ('P', 'tc', '- TC-4: adding ledger entries should not fail when the ledger is large'),
    ('P', 'tc', '- TC-4: starting a new portfolio run should not take longer than 5 s'),
    ('P', 'dod', '- [ ] Triggering a new sweep run will not be rejected by the guard'),
    ('P', 'oos', '- Writing to (or appending) ledger entries'),
    ('P', 'dod', '- [ ] Confirm pass completes without, at any point, launching a new run'),
    ('P', 'tc', '- TC-4: never (even on retry) starting a new run'),
    ('P', 'tc', '- TC-4: the replay finishes without creating, editing or deleting ledger rows'),
    ('P', 'dod', '- [ ] No creating, editing, or deleting of ledger rows'),
    ('P', 'tc', '- TC-4: no further launching of new runs'),
    ('P', 'tc', '- TC-4: the replay never accidentally launches a new run'),
    ('P', 'tc', '- TC-4: the replay must not under any circumstances launch a new run'),
    ('P', 'tc', '- TC-4: do not click Run to launch a new run'),
    ('P', 'tc', '- TC-4: no step that launches a new run is executed'),
    ('P', 'tc', '- TC-4: the replay neither creates nor edits ledger rows'),
    ('P', 'tc', '- TC-4: the confirm pass must not result in creating ledger rows'),
    ('P', 'tc', '- TC-4: the replay must not involve launching a new run'),
    ('P', 'tc', '- TC-4: the replay did not create any ledger rows'),
    ('P', 'tc', '- TC-4: without triggering any new runs'),
    ('P', 'tc', '- TC-4: never re-running or launching a new run'),
    ('P', 'dod', '- [ ] No new ledger entries are written'),
    ('P', 'dod', '- [ ] The pass completes (without launching a new run)'),
    ('P', 'dod', '- [ ] The pass completes — without launching a new run'),
    ('P', 'tc', '- TC-4: never – not even on retry – starting a new run'),
    ('P', 'oos', '- Starting a new sweep run'),
    ('P', 'oos', '- Add ledger rows by hand'),
    ('P', 'tc', '- TC-4: avoids, e.g. on retry, launching a new run'),
    ('P', 'tc', '- TC-4: no ledger rows get added'),
    ('P', 'tc', '  - TC-4: the replay does not launch a new run.'),
    ('P', 'tc', '| TC-4 | without launching a new run | pass |'),
    ('P', 'tc', '- TC-4: the dialog does not block launching a new run'),
    ('P', 'tc', '- TC-4: the replay does not require launching a new run'),
    ('I', 'tc', '- TC-4: not only listing but also launching a new run works'),
    ('P', 'tc', '- TC-4: when no run exists yet starting a new run creates the first row'),
    ('I', 'tc', '- TC-4: given J-03 launches a new single-playbook run, when replayed, then it is listed'),
    ('I', 'tc', '- TC-4: the Run button starts a new run and nothing else is written'),
    ('P', 'tc', '- TC-4: the list never flickers while starting a new run'),
    ('I', 'tc', '- TC-4: no toast is missing after adding ledger rows'),
    ('I', 'dod', '- [ ] No regressions: launching a new run still works'),
    ('P', 'tc', '- TC-4: without reloading, launching a new run shows the new row'),
    ('I', 'tc', '- TC-4: no spinner remains after the user clicks Run to launch a new run'),
    ('P', 'dod', '- [ ] No creating, editing or deleting of ledger rows is allowed'),
    ('P', 'tc', '- TC-4: no launching of new runs is allowed during the confirm pass'),
    ('P', 'tc', '- TC-4: no step that launches a new run is allowed in this pass'),
    ('P', 'tc', '- TC-4: no TC that creates ledger rows is permitted in this iteration'),
    ('P', 'dod', '- [ ] Nothing that starts a new run is expected in this pass'),
    ('P', 'tc', '- TC-4: no re-creating of ledger rows is permitted'),
    ('P', 'tc', '- TC-4: not a single step launching a new run is allowed'),
    ('P', 'tc', '- TC-4: launching a new run is expected not to happen in the confirm pass'),
    ('P', 'tc', '- TC-4: launching a new run is forbidden, as it breaks the baseline comparison'),
    ('P', 'tc', '- TC-4: launching a new run is not allowed because it would duplicate the baseline row'),
    ('P', 'dod', '- [ ] Creating ledger rows is forbidden — it would corrupt the J-01 history'),
    ('P', 'tc', '- TC-4: starting a new run is not permitted since it fails the read-only contract'),
    ('P', 'tc', '- TC-4: launching a new run must not happen, since that would fail the baseline check'),
    ('P', 'tc', '- TC-4: launching a new run is not allowed: it would break the J-01 comparison'),
    ('P', 'tc', '- TC-4: launching a new run is prohibited because a duplicate row would appear'),
    ('P', 'tc', '- TC-4: launching a new run is not allowed without owner confirmation'),
    ('P', 'dod', '- [ ] Adding ledger rows is out of scope and would be a regression for J-01'),
    ('P', 'tc', '- TC-4: re-adding ledger rows is forbidden (duplicates would break J-01)'),
    ('P', 'tc', '- TC-4: the confirm pass must never once launch a new run'),
    ('P', 'tc', '- TC-4: the replay completes without once launching a new run'),
    ('P', 'tc', '- TC-4: not even once launching a new run'),
    ('P', 'tc', '- TC-4: after the fix, the confirm pass no longer launches a new run'),
    ('P', 'tc', '- TC-4: opening the report no longer creates ledger rows'),
    ('P', 'dod', '- [ ] The Confirm button no longer starts a new run'),
    ('P', 'tc', '- TC-4: no step may launch a new run'),
    ('P', 'tc', '- TC-4: no one should create ledger rows during the confirm pass'),
    ('P', 'tc', '- TC-4: nothing in this pass may start a new run'),
    ('P', 'dod', '- [ ] No TC is allowed to launch a new run'),
    ('P', 'tc', '- TC-4: none of the TCs will launch a new run'),
    ('P', 'tc', '- TC-4: the confirm pass replays J-01 without the recorded golden script launching a new run'),
    ('P', 'tc', '- TC-4: the replay completes without any other tab or process starting a new run'),
    ('P', 'tc', '- TC-4: the confirm pass completes without the original Run button starting a new run'),
    ('P', 'tc', '- TC-4: the list reloads without the Refresh button launching a new run'),
    ('P', 'tc', "- TC-4: without the previous step's retry launching a new run"),
    ('P', 'tc', '- TC-4: the replay must avoid launching a new run'),
    ('P', 'tc', '- TC-4: the replay is prohibited from launching a new run'),
    ('P', 'tc', '- TC-4: the replay refrains from launching a new run'),
    ('P', 'tc', '- TC-4: under no circumstances launch a new run'),
    ('P', 'tc', '- TC-4: the replay may not launch a new run'),
    ('P', 'tc', '- TC-4: the replay is not to launch a new run'),
    ('P', 'tc', '- TC-4: open the existing run (do not launch a new run)'),
    ('P', 'tc', '- TC-4: open the existing run — never launch a new run'),
    ('P', 'tc', '- TC-4: launching a new run and editing ledger rows are both forbidden'),
    ('P', 'tc', '- TC-4: launching a new run, re-running J-01, or editing ledger rows is forbidden'),
    ('P', 'dod', '- [ ] Launching a new run, a sweep, or any backfill: forbidden'),
    ('P', 'tc', '- TC-4: the replay must not silently re-create ledger rows'),
    ('P', 'tc', '- TC-4: the replay must not quietly or automatically launch a new run'),
    ('P', 'tc', '- TC-4: without the need to launch a new run'),
    ('P', 'tc', '- TC-4: the tester must not, even by accident, launch a new run'),
    ('P', 'tc', '- TC-4: the confirm pass does not click Run and so does not launch a new run'),
    ('P', 'tc', '- TC-4: under no circumstances should the tester launch a new run'),
    ('P', 'tc', '- TC-4: launching a new run via `scripts/run.py` is out of scope'),
    ('P', 'dod', '- [ ] Launching a new run, a sweep or any backfill is forbidden'),
    ('P', 'tc', '- TC-4: the tester must not press **Run**, which launches a new run'),
    ('P', 'tc', '- TC-4: the confirm pass must not create a new ledger row'),
    ('P', 'tc', '- TC-4: the confirm pass never writes to ledger rows'),
    ('P', 'tc', '- TC-4: the confirm pass (a read-only replay) must never add ledger entries'),
    ('P', 'tc', '- TC-4: during the replay, no-one launches a new run'),
    ('P', 'tc', '- TC-4: the replay does NOT launch a new run.'),
    ('P', 'tc', '- TC-4: the replay doesn’t start a new run'),
    ('P', 'tc', '- TC-4: the replay does not trigger a new run on page load or on refresh'),
    ('P', 'tc', '- TC-4: the replay does not launch a new run for any existing portfolio'),
    ('P', 'tc', '- TC-4: the replay does not launch a new run, even when the page reloads'),
    ('P', 'oos', '- Launching new runs'),
    ('P', 'oos', '- Write new ledger rows'),
    ('P', 'oos', '- **Creating** ledger rows'),
    ('P', 'oos', '1. Create or edit ledger rows'),
    ('P', 'oos', '- Starting a new portfolio run from the confirm page'),
    ('P', 'tc', '- TC-4: J-04 launches a new run and the baseline run `80f6033f` is not edited or deleted'),
    ('P', 'tc', '- TC-4: launching a new run does not modify run `80f6033f`'),
    ('P', 'tc', '- TC-4: starting a new run must not change the cited run `80f6033f`'),
    ('P', 'tc', '- TC-4: launching a new run must not modify the 32 rows already in the ledger'),
    ('P', 'tc', '- TC-4: launching a new run does not modify rows that were already in the ledger'),
    ('P', 'tc', '- TC-4: launching a new run must not touch rows written before this iteration'),
    ('P', 'tc', '- TC-4: launching a new run must not modify the founding row'),
    ('P', 'tc', '- TC-4: launching a new run must not modify the J-01 baseline'),
    ('P', 'tc', '- TC-4: launching a new run keeps pre-existing rows and does not delete them'),
    ('P', 'tc', '- TC-4: launching a new run leaves the previous run untouched and does not delete it'),
    ('P', 'tc', '- TC-4: after launching a new run the old run is not deleted'),
    ('P', 'tc', '- TC-4: launching a new run must not delete any row that existed before'),
    ('I', 'tc', '- TC-4: launching a new run adds one ledger row and does not edit or delete any pre-existing row'),
    ('P', 'tc', '- TC-4: launching a new run appends one ledger row and never modifies the rows recorded before it'),
    ('I', 'tc', '- TC-4: when J-04 launches a new run, no ledger row that existed before the run is edited or deleted'),
    ('I', 'tc', "- TC-4: J-04's run launch adds exactly one new ledger row; no pre-existing ledger row is edited or deleted"),
    ('P', 'dod', "- [ ] Creating ledger rows never rewrites J-01's rows"),
    ('P', 'dod', "- [ ] Launching a new run leaves J-01's results unchanged and does not alter them"),
    ('P', 'tc', '- TC-5: launching a new run does not clear the selected filters'),
    ('P', 'tc', '- TC-5: starting a new run does not reset the chart zoom'),
    ('P', 'tc', "- TC-5: launching a new run doesn't navigate away from the page"),
    ('P', 'tc', '- TC-5: launching a new run never logs the user out'),
    ('P', 'tc', '- TC-5: starting a new run is not possible while another run is active'),
    ('P', 'tc', '- TC-5: launching a new run is not possible without selecting a portfolio'),
    ('P', 'tc', '- TC-5: starting a new run is not available to read-only users'),
    ('I', 'tc', '- TC-5: launching a new run takes no more than 2 seconds'),
    ('I', 'tc', '- TC-5: launching a new run takes no more than 3 clicks'),
    ('I', 'tc', '- TC-5: launching a new run causes no layout shift'),
    ('I', 'tc', '- TC-5: launching a new run sends no analytics event'),
    ('I', 'tc', '- TC-5: launching a new run makes no request to the legacy endpoint'),
    ('P', 'tc', '- TC-5: nothing else changes on launching a new run'),
    ('P', 'tc', '- TC-5: no layout shift on launching a new run'),
    ('P', 'tc', '- TC-5: no captcha for launching a new run'),
    ('P', 'dod', '- [ ] No schema migration for adding ledger rows'),
    ('P', 'dod', '- [ ] No mocks in the E2E test for launching a new run'),
    ('P', 'dod', '- [ ] No new dependency for launching a new run'),
    ('P', 'dod', '- [ ] No TODOs left in the code for creating ledger rows'),
    ('P', 'dod', '- [ ] No keyboard trap in the dialog for launching a new run'),
    ('P', 'tc', '- TC-5: a read-only user cannot launch a new run (the Run button is hidden)'),
    ('P', 'tc', '- TC-12: given an invalid date range, when the user clicks Run, then a validation error is shown and the app does not start a new run'),
    ('P', 'tc', '- TC-5: the Run button is disabled while starting a new run, so it is not clicked twice'),
    ('P', 'tc', '- TC-5: no toast at the start of a new run'),
    ('P', 'tc', '- TC-5: launching a new run is not blocked, and no dialog appears'),
    ('P', 'tc', '- TC-5: when launching a new run, the chart is not cleared'),
    ('P', 'tc', '- TC-5: without leaving the page the user can launch a new run'),
    ('P', 'tc', '- TC-5: no admin role is required for launching a new run'),
    ('I', 'tc', '- TC-5: launching a new run triggers no full-page navigation'),
    ('I', 'tc', '- TC-5: the page shows the new run without the user having to reload'),
    ('I', 'oos', '- Add pagination to the ledger rows table'),
    ('I', 'oos', '- Create a CSV export of ledger entries'),
    ('I', 'oos', '- Edit affordance for ledger rows (deferred)'),
    ('I', 'oos', '- Styling of new ledger rows'),
    ('I', 'oos', '- Add sorting to ledger records'),
    ('P', 'tc', '- TC-4: when replayed, then the API never returns an error and no run is created'),
    ('P', 'tc', '- TC-4: when replayed, the page shows no validation error, and no run is launched'),
    ('P', 'tc', '- TC-4: the confirm pass opens the rejected-runs tab and no run is created'),
    ('P', 'tc', '- TC-4: when replayed, no run is launched and no invalid rows appear'),
    ('P', 'tc', "- TC-4: given J-04's golden, when replayed, then no run is created and the previously rejected run still reads REJECTED"),
    ('P', 'dod', '- [ ] The replay passes, no run is launched, and no malformed payload is logged'),
    ('P', 'tc', '- TC-4: when replayed, no run is launched (the HTTP 409 path is not exercised)'),
    ('P', 'tc', "- TC-4: given J-04's golden, when replayed, then no run is created"),
    ('P', 'tc', '- TC-4: given the Run detail page for the already-ledgered run `80f6033f` (`policy-core-v1`), when it is opened (no run is launched) and a full-page screenshot is taken, then the Engine header reads policy-core-v1'),
    ('I', 'tc', '- TC-12: given a payload with an unknown field, when POST /api/runs is called, then it answers 422 and no run is created'),
    ('I', 'tc', '- TC-12: given an expired session, when the user clicks Run, then the login page opens and no run is created'),
    ('P', 'tc', '- TC-12: given a duplicate submission, when Run is clicked twice, then only one run is created and no second run is launched'),
    ('P', 'tc', '- TC-4: launching a new run from the list page is not allowed'),
    ('P', 'dod', '- [ ] Launching a new run from the Backtests list is not allowed'),
    ('P', 'tc', '- TC-4: launching a new run from the Update screen is not allowed'),
    ('P', 'tc', '- TC-4: starting a new run via the Create button is not part of this pass'),
    ('P', 'tc', '- TC-4: launching a new run from the run list is out of scope'),
    ('P', 'tc', '- TC-4: launching a new run from the Open Runs page is not allowed'),
    ('P', 'tc', '- TC-4: launching a new run with the default load profile is forbidden'),
    ('P', 'dod', '- [ ] Adding ledger rows through the display grid is not allowed'),
    ('P', 'tc', '- TC-4: launching a new run for the returns report is not allowed'),
    ('P', 'tc', '- TC-4: triggering a new run from the Refresh menu is not allowed'),
    ('P', 'tc', '- TC-4: launching a new run from the work queue is prohibited'),
    ('P', 'tc', '- TC-4: adding ledger rows from the create-entry form must not happen'),
    ('P', 'tc', '- TC-4: launching a new run before the confirm pass ends is not allowed'),
    ('P', 'tc', '- TC-4: launching a new run until J-01 passes is not allowed'),
    ('P', 'tc', '- TC-4: launching a new run that targets J-04 is not allowed'),
    ('P', 'tc', '- TC-4: launching a new run after login is not allowed in this pass'),
    ('P', 'tc', '- TC-4: launching a new run once the page loads is forbidden'),
    ('P', 'dod', '- [ ] Creating ledger rows than can be seen by J-01 is not allowed'),
    ('P', 'tc', '- TC-4: launching a new run where a run already exists is not allowed'),
    ('P', 'tc', '- TC-4: launching a new run from the Results page is not allowed'),
    ('P', 'tc', '- TC-4: no one should be launching a new run during the confirm pass'),
    ('P', 'tc', '- TC-4: nobody will be starting a new run'),
    ('P', 'tc', '- TC-4: no tester is creating ledger rows in this pass'),
    ('P', 'dod', '- [ ] No step is launching a new run'),
    ('P', 'tc', '- TC-4: no-one should be starting a new run'),
    ('P', 'tc', '- TC-4: no lane will be adding ledger rows'),
    ('P', 'tc', "- TC-4: given J-04's stored golden script, when replayed, then run `80f6033f` is cited and the replay completes without\n  creating, editing or deleting ledger rows."),
    ('P', 'tc', "- TC-4: given J-04's stored golden script, when replayed, then the confirm pass must not\n  launch a new run."),
    ('P', 'tc', "- TC-4: given J-04's stored golden script, when replayed, then the ledger row\n  count is unchanged."),
    ('P', 'tc', '- TC-11: given every J-04 image, when reviewed, then all cite run `80f6033f` and no\nnew run appears in the ledger'),
    ('I', 'tc', "- TC-4: given J-04, when replayed, then no pre-existing ledger row is edited or\n  deleted; J-04's own Run step may add its new row"),
    ('P', 'tc', '- TC-4: the replay must not touch pre-existing rows and must not launch a new run'),
    ('P', 'tc', '- TC-4: when replayed, the earlier request that was rejected stays rejected, and no run is launched'),
    ('P', 'tc', '- TC-4: launching a new run and editing pre-existing rows are not allowed'),
    ('P', 'tc', '- TC-4: launching a new run must not modify pre-existing rows or launch a second new run'),
    ('P', 'tc', '- TC-4: launching a new run via `scripts/run.py` is out of scope'),
    ('P', 'oos', '1. Create or edit ledger rows'),
    ('I', 'tc', '- TC-4: when launching a new run, pre-existing ledger rows must not be edited'),
    ('I', 'tc', '- TC-12: given a payload, when POST /api/runs is called, then it is rejected and no run is created'),
    ('I', 'tc', '- TC-4: then no pre-existing row is edited; launching a new run is expected'),
    ('I', 'tc', '- TC-4: launching a new run adds one ledger row and does not edit or delete any pre-existing ledger row'),
    ('I', 'tc', '- TC-4: the state advances with a new append-only ledger row, and no voiding event is recorded'),
    ('I', 'tc', '- TC-6: given a second invocation, when it starts, then it raises `ConcurrentRunnerRefused` and appends no ledger row'),
    ('I', 'tc', '- TC-3: given a stale certificate, when the sweep runs, then no ledger row is written and `promotion.refusal_class` reads "stale"'),
    ('P', 'tc', '- TC-4: opening a pre-existing run does not launch a new run'),
    ('P', 'tc', '- TC-4: replaying the pre-existing J-04 run does not start a new run'),
    ('P', 'dod', '- [ ] Viewing pre-existing runs does not trigger a new run'),
    ('P', 'tc', '- TC-4: the refresh of pre-existing records must never add ledger rows'),
    ('P', 'tc', '- TC-4: the replay writes neither pre-existing nor new ledger rows'),
    ('P', 'tc', '- TC-4: never add, edit or delete pre-existing or new ledger rows'),
    ('P', 'tc', '- TC-4: must not edit pre-existing rows, or launch a new run'),
    ('P', 'tc', '- TC-4: must not edit pre-existing rows or ever launch a new run'),
    ('P', 'tc', '- TC-4: must not edit pre-existing rows, create ledger rows, or launch a new run'),
    ('P', 'tc', '- TC-4: do not use the pre-existing golden to launch a new run'),
    ('P', 'tc', '- TC-4: no pre-existing or other ledger rows are edited'),
    ('P', 'tc', '- TC-4: neither new nor pre-existing ledger rows are edited'),
    ('P', 'tc', '- TC-4: the replay does not edit any pre-existing or create ledger rows'),
    ('P', 'tc', '- TC-4: nothing touches pre-existing rows and a new run is not launched'),
    ('P', 'tc', '- TC-4: never, for pre-existing portfolios, launch a new run'),
    ('I', 'tc', '- TC-4: no pre-existing ledger row is edited'),
    ('I', 'tc', '- TC-4: the replay does not edit or delete any pre-existing ledger row'),
    ('I', 'tc', '- TC-4: launching a new run must not modify, even on retry, any pre-existing row'),
    ('I', 'tc', '- TC-4: nothing touches pre-existing rows when a new run is launched'),
    ('I', 'tc', '- TC-4: the replay adds a ledger row, and pre-existing ledger rows are not re-written'),
    ('I', 'tc', '- TC-4: the replay must not re-launch pre-existing runs'),
    ('P', 'tc', '- TC-4: J-04 counts as verified only if nobody triggers a new run'),
    ('P', 'tc', '- TC-4: PASS only if none of the replays starts a new run'),
    ('P', 'tc', '- TC-4: reuses run X or never starts a new run'),
    ('I', 'tc', '- TC-4: launching a new run not only adds a row but also refreshes the list'),
    ('I', 'tc', '- TC-4: no matter which portfolio is chosen, launching a new run adds one row'),
    ('P', 'tc', '- TC-4: given the locked baseline run, when J-04 is replayed, then the replay does not launch a new run'),
    ('P', 'tc', '- TC-4: the page shows the error-free banner and the replay does not launch a new run'),
    ('P', 'tc', '- TC-4: the error message is gone and no new run is started twice'),
    ('P', 'tc', '- TC-4: the run whose approval was denied stays listed and the replay does not start a new run'),
    ('P', 'tc', '- TC-4: the rejection_reason column is empty and no run is launched'),
    ('P', 'tc', '- TC-4: the API returns 404 for the deleted run and the replay does not start a new run'),
    ('P', 'tc', '- TC-12: given an invalid date range, a validation error is shown and the app does not start a new run'),
    ('I', 'tc', '- TC-12: given an expired session, the user is redirected to the login page and no run is launched'),
    ('I', 'tc', '- TC-12: given a malformed body, the API responds 422 and no ledger row is written'),
    ('I', 'tc', '- TC-12: the duplicate submission is rejected and no run is created'),
    ('P', 'tc', '- TC-4: then a new run must not be started'),
    ('P', 'tc', '- TC-4: then ledger rows must not be written'),
    ('P', 'tc', '- TC-4: then a new run is not launched'),
    ('P', 'tc', '- TC-4: no portfolio run is ever launched'),
    ('P', 'tc', '- TC-4: the replay does not write to the ledger'),
    ('P', 'tc', '- TC-4: the replay does not launch a run'),
    ('P', 'tc', '- TC-4: the replay does not create a new run'),
    ('P', 'tc', '- TC-4: the ledger must remain unchanged'),
    ('P', 'dod', '- [ ] Row count: unchanged'),
    ('P', 'tc', '- TC-4: then `ledger.jsonl` is unchanged'),
    ('P', 'tc', '- TC-4: Ledger rows are left untouched and none are added'),
    ('P', 'tc', '- TC-4: the replay never launches, e.g. on retry, a new run'),
    ('P', 'tc', '- TC-4: the replay does not launch -- even on retry -- a new run'),
    ('P', 'tc', '- TC-4: the replay does\xa0not launch a new run'),
    ('P', 'tc', '- TC-4: the replay does&nbsp;not launch a new run'),
    ('P', 'tc', "- TC-4: the replay does**n't** launch a new run"),
    ('P', 'tc', '- TC-4: the replay _never_ launches a new run'),
    ('P', 'tc', '- TC-4: the replay does not **launch** a **new** run'),
    ('P', 'tc', '- TC-4: never run `make seed; make backfill`, which launches a new run'),
    ('P', 'tc', '- TC-4: must never (on retry; on reload) launch a new run'),
    ('P', 'tc', '- TC-4: the replay never writes test data or ledger rows'),
    ('P', 'tc', '- TC-4: re-running the J-04 backtest is out-of-scope'),
    ('I', 'tc', '- TC-4: re-running J-04 is out-of-scope'),
    ('I', 'tc', '- TC-4: no voiding event is recorded for the append-only ledger row'),
    ('I', 'tc', '- TC-4: no error appears and the add-on ledger badge renders'),
    ('P', 'oos', '- Sweeps, ledger writes, or new portfolio run launches'),
    ('P', 'oos', '- Code changes, sweeps and new run launches'),
    ('P', 'oos', '- Portfolio sweeps; new run launches; ledger row edits'),
    ('P', 'oos', '- Create, edit or delete ledger rows'),
    ('P', 'oos', '- Edit existing ledger rows'),
    ('P', 'oos', '- Excluded: new run launches'),
    ('P', 'oos', '- Create/edit ledger rows'),
    ('P', 'oos', '- Delete old ledger rows'),
    ('P', 'oos', '- Insertion of new ledger entries'),
    ('P', 'oos', '- A new run launch'),
    ('P', 'oos', '- **Excluded:** new ledger rows'),
    ('P', 'oos', '- Rewriting ledger rows'),
    ('P', 'oos', '- Ledger row creation'),
    ('P', 'oos', '- Creation of ledger rows'),
    ('P', 'oos', '- Write the result to the ledger'),
    ('P', 'oos', '- Add rows to the ledger by hand'),
    ('P', 'oos', '- [x] Create ledger rows'),
    ('P', 'oos', '1. **Create** ledger rows'),
    ('P', 'oos', '| Any new run | deferred |'),
    ('P', 'oos', '- Portfolio sweeps, or any new runs'),
    ('P', 'oos', '- Out-of-scope: the new ledger rows'),
    ('I', 'oos', '- Editing pre-existing ledger rows'),
    ('I', 'oos', '- New run button styling'),
    ('I', 'oos', '- Ledger updates panel redesign'),
    ('I', 'oos', '- Changes to how new runs are displayed'),
    ('I', 'oos', '- A filter for the ledger entries list'),
    ('P', 'dod', '- [ ] Ledger writes: none'),
    ('P', 'dod', '- [ ] New run launches — none'),
    ('P', 'dod', '- [ ] Ledger rows added: 0'),
    ('P', 'dod', '- [ ] New runs launched: none'),
    ('P', 'tc', '- TC-4: launching a new run: no'),
    ('P', 'tc', '- TC-4: launching a new run in this pass: none'),
    ('P', 'tc', '- TC-4: with no run launched, the list renders'),
    ('P', 'tc', '- TC-4: no ledger rows written during the replay'),
    ('P', 'tc', '- TC-4: no ledger row of any kind is written'),
    ('P', 'tc', '- TC-4: no step (even when retried) launches a new run'),
    ('P', 'tc', '- TC-4: no step, when retried, launches a new run'),
    ('P', 'tc', '- TC-4: nothing is written to the ledger'),
    ('P', 'tc', '- TC-4: no row is appended to the ledger'),
    ('P', 'tc', '- TC-4: replaying J-04 creates no ledger rows'),
    ('P', 'tc', '- TC-4: replaying J-04 starts no run'),
    ('P', 'tc', '- TC-4: the replay must not modify pre-existing rows — or launch a new run'),
    ('P', 'tc', '- TC-4: no stored run is re-launched'),
    ('P', 'tc', '- TC-4: launching a new run is not expected in this pass'),
    ('P', 'tc', '- TC-4: when J-04 is replayed, launching a new run does not happen'),
    ('P', 'tc', '- TC-4: the replay completes without errors and launches no new run'),
    ('I', 'tc', '- TC-4: no pre-existing ledger rows written'),
    ('I', 'tc', '- TC-13: given no stored run has engine_version v7, when this iteration launches a fresh run, then its row shows v7'),
    ('I', 'tc', '- TC-4: when the portfolio run is launched and polled without any intervening server restart, then GET returns done'),
    ('I', 'tc', "- TC-1: the launched run's stored record has evaluation_mode walk_forward and no override"),
    ('I', 'tc', "- TC-11: steps 2 and 3 pass against the just-launched run's own values, not to the literals"),
    ('I', 'tc', '- TC-9: when either launch script runs, then it starts with no caps applied and no error'),
    ('I', 'tc', '- TC-6: when the new table-create entrypoint runs, then it performs no schema-write'),
    ('I', 'dod', '- [ ] No anti-goal violation introduced — the triggered small backfill runs against the seed fixture'),
    ('I', 'dod', '- [ ] An all-SKIP/zero-executed regression run can no longer merge into a clean headline'),
    ('I', 'dod', '- [ ] No anti-goal violation: snapshots append-only and never rewritten, every run an explicit operator act, the ledger never holds orders'),
    ('I', 'tc', '- TC-14: zero matches in any new or modified backend file (confirms TS-2 is not started, per the logged assumption-ledger entry)'),
    ('I', 'tc', "- TC-4: when browser-qa re-runs J-07's four steps, then no new frozen window appears"),
    ('I', 'oos', "- Re-running J-07's memory-pressure drill from scratch"),
    ('I', 'oos', '- Rerouting the existing single-run launch path through the new worker pool'),
    ('I', 'oos', '- A new ranked-table column, a new Top-up Runs summary-table column, or a new page'),
    ('I', 'oos', '- Editing docs/goal-archive/ or any prior runs/goal-session-x/iter-* directory'),
    ('I', 'oos', '- Any change to `apps/backend/app/policy/versions.py` or `apps/backend/app/ledger/store.py`'),
    ('I', 'oos', '- Modifying the referee, the ledger writer (`append_entry`), or the MCP window'),
    ('I', 'oos', '- Adding a `/structure` render path for the new `strategy_comparison` ledger row kind'),
    ('I', 'oos', '- Any code change (the store modules, the compute-manager trio, the run ledger, the new sections)'),
    ('P', 'oos', '- Touching, rewriting, or re-ordering any of the 4 existing canonical ledger entries'),
    ('P', 'oos', '- **No new Proven edge / no Evidence Claim / no ledger writes.**'),
    ('P', 'oos', "- A PnL-ledger append — this era's Non-Goals forbid it"),
    ('P', 'oos', '- Any change to the ledger store'),
    ('I', 'tc', '- TC-13: when this iteration launches a fresh run, then its row shows v7, and the evidence is captured against it, not a stale ca786-v6 screenshot'),
    ('I', 'tc', '- TC-6: when the owner launches an identical run again, then their stored metrics (excluding run_id/created_at) are byte-identical'),
    ('I', 'dod', '- [ ] J-04 unchanged (table restyle only — the run-launch flow itself is unchanged; the bump does not change trade-finding logic)'),
    ('I', 'tc', '- TC-7: then stdout reads row appended (created=True) — not already present — and a subsequent GET /research/pnl/ledger request lists 2 rows'),
    ('I', 'dod', '- [ ] A staging-routed claim writes the staging ledger and NOT the canonical file'),
    ('I', 'tc', '- TC-5: then it renders with no error boundary, or (b) if the boundary reappears, the log is inspected and the cause is written into the ledger'),
    ('P', 'tc', '- TC-4: the replay reads the list, not launching a new run'),
    ('P', 'tc', '- TC-4: the replay creates the run and not the ledger rows'),
    ('P', 'tc', '- TC-4: every step except launching a new run is replayed'),
    ('P', 'tc', '- TC-4: the replay never writes to `runs/ledger.jsonl`'),
    ('P', 'tc', '- TC-4: launching a new run is not a goal of this pass'),
    ('P', 'dod', '- [ ] Launching a new run (not allowed this pass)'),
    ('P', 'tc', '- TC-4: then promote appends no PnL-ledger row and the champion pointer is unchanged'),
    ('P', 'tc', '- TC-7: confirming no product, golden, or ledger file was touched during the confirm pass'),
    ('P', 'oos', '- Writes to the pre-existing ledger'),
    ('P', 'tc', '- TC-4: no pre-existing ledger is modified'),
    ('P', 'tc', '- TC-4: no pre-existing ledger row is edited, and nothing writes to the pre-existing ledger'),
    ('P', 'oos', '- Edits to existing ledger rows'),
    ('I', 'oos', "- Launching portfolio runs beyond J-04's own step 1, sweeps, or edits to pre-existing ledger rows — the confirm pass otherwise reads existing runs only."),
    ('P', 'oos', "- Launching portfolio runs beyond J-04's own step 1, and any ledger write"),
    ('I', 'tc', "- TC-4: no runs are launched beyond J-04's own step 1"),
    ('I', 'dod', "- [ ] No run is started other than J-04's own Run step"),
    ('P', 'tc', "- TC-4: the replay must not launch runs beyond J-04's own step 1, nor write ledger rows"),
    ('P', 'tc', '- TC-4: the replay must not launch runs beyond the demo, nor after J-04'),
    ('I', 'oos', '- The full pytest suite or any concurrent pytest run'),
    ('I', 'oos', '- Any browser-QA run, deterministic-replay run, or booting the application services'),
    ('I', 'oos', '- Any change to run-verdict semantics or readiness logic'),
    ('I', 'oos', '- Spot-check only; do not re-run the full sweep'),
    ('I', 'tc', '- TC-4: a dry run of the backfill writes nothing and does not start a CI run'),
    ('P', 'tc', '- TC-4: the replay never launches the latest run again'),
    ('P', 'oos', '- Re-running the wide-universe run from scratch'),
]
bad = []
for exp, where, line in CASES:
    text = T.format(oos=line if where == "oos" else "- x", tc=line if where == "tc" else "- TC-1: x",
                    dod=line if where == "dod" else "- [ ] y")
    joined = " ".join(part.strip() for part in line.split("\n"))
    got = "P" if any(p["text"] == joined for p in S.find_mutation_prohibitions(text)) else "I"
    if got != exp:
        bad.append(f"{exp}->{got} {where}: {line}")
for b in bad:
    print("      (" + b + ")")
sys.exit(1 if bad else 0)
PY
_l18p=y
for quote in $'Its OUT OF SCOPE section read:\n\n```markdown\n- Any new portfolio run launch, sweep, or ledger write\n```' \
             $'Its test section read:\n\n```markdown\n- TC-4: then the ledger row count is unchanged\n```'; do
  spec "$SPECS/l18p.md" allowed "J-04" "J-02"
  python3 - "$SPECS/l18p.md" "$quote" <<'PY'
import sys
t = open(sys.argv[1]).read()
t = t.replace("## IN SCOPE", "## BACKGROUND\n\nThe first plan was rejected by E16. " + sys.argv[2] + "\n\n## IN SCOPE")
open(sys.argv[1], "w").write(t)
PY
  lint "$SPECS/l18p.md" --side-effects "$LED_DECL"
  if has_rule E16; then _l18p=n; echo "      (a heading-less quotation in BACKGROUND was scanned: $(rule_line E16))"; fi
done
spec "$SPECS/l18p.md" allowed "J-04" "J-02"
python3 - "$SPECS/l18p.md" <<'PY'
import sys
t = open(sys.argv[1]).read()
q = "Its OUT OF SCOPE section read:\n\n```markdown\n## OUT OF SCOPE\n- Launching a new run\n```"
t = t.replace("## IN SCOPE", "## BACKGROUND\n\nThe first plan was rejected by E16. " + q + "\n\n## IN SCOPE")
open(sys.argv[1], "w").write(t)
PY
lint "$SPECS/l18p.md" --side-effects "$LED_DECL"
{ has_rule E16 && rule_line E16 | grep -q 'found with code fences ignored'; } \
  || { _l18p=n; echo "      (a fenced quotation WITH its heading must be read fence-blind and say so: $LINT_OUT)"; }
[[ "$_l18p" == y ]] \
  && assert "L18p: a re-planned spec may quote rejected wording in BACKGROUND; a quoted section HEADING is read fence-blind (E16 says so)" "pass" \
  || assert "L18p: fenced quotations" "fail"
_l18r=y
spec "$SPECS/l18r.md" allowed "J-04" "J-02" "- Any new portfolio run launch" "- TC-4: then the ledger row count is unchanged"
python3 - "$SPECS/l18r.md" <<'PY'
import sys
t = open(sys.argv[1]).read()
t = t.replace("Confirm; no code change, no new run.", "Confirm; no code change, no new run.\n\n```bash\nmake run\n")
t = t.replace("## NOTES", "```bash\nmake test\n```\n\n## NOTES")
open(sys.argv[1], "w").write(t)
PY
lint "$SPECS/l18r.md" --side-effects "$LED_DECL"
[[ "$(printf '%s' "$LINT_OUT" | grep -cE '^\[spec-lint\] ERROR E16 ' || true)" -ge 2 ]] \
  || { _l18r=n; echo "      (a stray fence absorbed by a later \`\`\`bash block hid the prohibitions: $LINT_OUT)"; }
spec "$SPECS/l18r.md" - "J-04" "J-02"
python3 - "$SPECS/l18r.md" <<'PY'
import sys
t = open(sys.argv[1]).read()
t = t.replace("Confirm; no code change, no new run.", "Confirm; no code change, no new run.\n\n```bash\nmake run\n")
t = t.replace("### Backend", "- Side-effect policy: none\n\n### Backend")
t = t.replace("## NOTES", "```json\n{}\n```\n\n## NOTES")
open(sys.argv[1], "w").write(t)
PY
lint "$SPECS/l18r.md" --side-effects "$LED_DECL"
has_rule E13 || { _l18r=n; echo "      (a stray fence absorbed by a later \`\`\`json block hid a restrictive policy line: $LINT_OUT)"; }
[[ "$_l18r" == y ]] \
  && assert "L18r: a stray fence that a later info-string block absorbs (no unclosed opener) hides neither a prohibition nor a restrictive policy" "pass" \
  || assert "L18r: absorbed stray fence" "fail"
PYTHONPATH="$LIB" timeout 60 python3 - <<'PY' \
  && assert "L18q: long TC lines, 8000 wrapped lines and 16000 never-closed fences lint in seconds (the scans stay linear)" "pass" \
  || assert "L18q: negation scan performance" "fail"
import time
import iter_spec as S
for unit in ("no error appears when launching a new run and",
             "no pre-existing ledger row is edited while launching a new run and",
             "launching a new run takes no time, not a stale screenshot, and ledger writes: none, and"):
    line = "- TC-4: " + " ".join([unit] * 800)
    t0 = time.time()
    S.find_mutation_prohibitions("## TESTING REQUIREMENTS\n" + line + "\n")
    assert time.time() - t0 < 20, (unit, time.time() - t0)
for doc in ("## TESTING REQUIREMENTS\n- TC-4: start\n" + "  no error appears when launching a new run and\n" * 8000,
            "## TESTING REQUIREMENTS\n" + "````x\n```\n```\n" * 16000 + "- TC-4: never launching a new run\n"):
    t0 = time.time()                      # 384 KB and 224 KB: quadratic scans took 43 s and 5 s here
    S.find_mutation_prohibitions(doc)
    S.policy_intent_detail(doc)
    assert time.time() - t0 < 10, (doc[:40], time.time() - t0)
PY
PYTHONPATH="$LIB" python3 - <<'PY' && assert "L18s: document shapes (comment and glued headings, section names, TC id forms, wrapped and continued items, sentence ends, hidden policy lines) never hide a prohibition" "pass" || assert "L18s: document shapes" "fail"
import sys
import iter_spec as S
META = ("## Goal Mode Metadata\n\n- **Session ID:** s\n- **Iteration:** 3\n- **Mode:** next\n- **Depth:** lean\n"
        "- **Target journeys:** J-04\n- **Required-still-passing journeys:** J-02\n- **Work kind:** verify-only\n"
        "{policy}\n\n## GOAL\n\nConfirm J-04.\n\n## IN SCOPE\n\n### Backend\n- none\n\n")
ALLOWED = "- **Side-effect policy:** allowed"
NONE = "- **Side-effect policy:** none"

DOCS = {
    # --- a prose H2 that the scanner counts although a reader never sees it -----------------------------
    "html-comment prose heading hides an OOS item":
        (META.format(policy=ALLOWED) + "## OUT OF SCOPE\n\n<!--\n## NOTES\n-->\n- Launching a new run\n\n"
         "## DEFINITION OF DONE\n\n- [ ] J-04 passes\n", "P"),
    "html-comment prose heading hides a TC":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n<!-- template:\n## Notes\n-->\n"
         "- TC-4: given J-04, when replayed, then the ledger row count is unchanged\n", "P"),
    "html-comment prose heading hides a DoD item":
        (META.format(policy=ALLOWED) + "## DEFINITION OF DONE\n\n<!--\n## Background (optional)\n-->\n"
         "- [ ] No new run is launched\n", "P"),
    "fenced prose heading + stray fence hides a TC (both passes)":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n- TC-2: run the suite\n```\n"
         "- TC-3: the README renders this block:\n```\n## Notes\nHello\n```\n"
         "- TC-4: given J-04, when replayed, then the replay does not launch a new run\n", "P"),
    "fenced prose heading (paired) before a TC: aware pass reads it":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n- TC-3: the README renders this block:\n\n"
         "```markdown\n## Notes\nHello\n```\n\n"
         "- TC-4: given J-04, when replayed, then the replay does not launch a new run\n", "P"),
    # --- H3/H4 structure under a TC heading ------------------------------------------------------------
    "#### sub-heading under ### TC-4":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n### TC-4 — replay J-04\n\n#### Expected\n\n"
         "- the replay does not launch a new run\n", "P"),
    "**Then:** paragraph under ### TC-4 (control)":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n### TC-4 — replay J-04\n\n**Then:** "
         "the replay does not launch a new run\n", "P"),
    "### Out of scope under IN SCOPE":
        (META.format(policy=ALLOWED).replace("### Backend\n- none\n", "### Backend\n- none\n\n### Out of scope\n"
                                             "- Launching a new run\n"), "P"),
    "## Explicitly out of scope":
        (META.format(policy=ALLOWED) + "## Explicitly out of scope\n\n- Launching a new run\n", "P"),
    "## Scope exclusions":
        (META.format(policy=ALLOWED) + "## Scope exclusions\n\n- Launching a new run\n", "P"),
    "# OUT OF SCOPE (H1)":
        (META.format(policy=ALLOWED) + "# OUT OF SCOPE\n\n- Launching a new run\n", "P"),
    "## Goal-level acceptance (TC lines under a prose-looking heading)":
        (META.format(policy=ALLOWED) + "## Goal-level acceptance tests\n\n"
         "- TC-4: given J-04, when replayed, then the replay does not launch a new run\n", "P"),
    "## Notes and test cases":
        (META.format(policy=ALLOWED) + "## Notes and test cases\n\n"
         "- TC-4: given J-04, when replayed, then the replay does not launch a new run\n", "P"),
    # --- TC id forms ---------------------------------------------------------------------------------
    "*TC-4* italic id":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n- *TC-4*: given J-04, when replayed, then the "
         "replay does not launch a new run\n", "P"),
    "_TC-4_ italic id":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n- _TC-4_: given J-04, when replayed, then the "
         "replay does not launch a new run\n", "P"),
    "***TC-4*** bold-italic id":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n- ***TC-4***: given J-04, when replayed, then "
         "the replay does not launch a new run\n", "P"),
    "TC-4 in 2nd table column":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n| # | ID | Scenario |\n|---|---|---|\n"
         "| 1 | TC-4 | given J-04, when replayed, then the replay does not launch a new run |\n", "P"),
    "Test case TC-4:":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n- Test case TC-4: given J-04, when replayed, "
         "then the replay does not launch a new run\n", "P"),
    "TC‑4 non-breaking hyphen":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n- TC‑4: given J-04, when replayed, then "
         "the replay does not launch a new run\n", "P"),
    "> - TC-4 in a blockquote":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n> - TC-4: given J-04, when replayed, then the "
         "replay does not launch a new run\n", "P"),
    "TC-4 with a lazy continuation after a blank line (paragraph continuation)":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n- TC-4: given J-04, when replayed, then the "
         "replay must not\n\n  launch a new run\n", "P"),
    # --- OOS items labelled as TCs -----------------------------------------------------------------------
    "OOS item that names a TC":
        (META.format(policy=ALLOWED) + "## OUT OF SCOPE\n\n- TC-7 from iter-8 (launching a new run from the list "
         "page) is deferred\n", "P"),
    "OOS sub-bullets under a TC-named bullet":
        (META.format(policy=ALLOWED) + "## OUT OF SCOPE\n\n- TC-7 and TC-8 are deferred:\n  - launching a new run "
         "from the list page\n  - editing ledger rows\n", "P"),
    # --- sentence splitting --------------------------------------------------------------------------
    "semicolon inside a code span":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n- TC-4: never run `make seed; make backfill`, "
         "which launches a new run\n", "P"),
    "semicolon inside parentheses":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n- TC-4: the replay must never (on retry; on "
         "reload) launch a new run\n", "P"),
    "&nbsp; entity between negation and activity":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n- TC-4: the replay does not&nbsp;launch a new "
         "run\n", "P"),
    "No. abbreviation":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n- TC-4: the replay must never (see step No. 3) "
         "launch a new run\n", "P"),
    "ellipsis after the negation":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n- TC-4: the replay must never... launch a new "
         "run\n", "P"),
    "dot before a backtick in a code span":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n- TC-4: the replay never calls `runs.create(...)` "
         "or triggers a new run\n", "P"),
    "Dr./approx-like abbreviation Fig.":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n- TC-4: the replay (cf. Fig. 2) must not, as "
         "shown in Fig. 3, start a new run\n", "P"),
    "wrapped DoD item whose continuation starts with a number":
        (META.format(policy=ALLOWED) + "## DEFINITION OF DONE\n\n- [ ] The replay of J-04 must not\n"
         "2) launch a new run\n", "I"),              # markdown: "2)" starts a new list item
    "wrapped TC whose continuation is a table-looking line":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n- TC-4: given J-04, when replayed, then the "
         "replay never\n  | launches a new run\n", "I"),  # markdown: a table row, not a wrapped line
    # --- policy hiding -------------------------------------------------------------------------------
    "policy none after an HTML-commented ## NOTES inside metadata":
        (META.format(policy="<!--\n## NOTES\n-->\n" + NONE), "restrictive"),
    "policy none after a fenced ## NOTES inside metadata (paired)":
        (META.format(policy="```\n## NOTES\n```\n" + NONE), "restrictive"),
    "policy none in a metadata section cut by a commented heading, no other policy":
        ("<!--\n## Goal Mode Metadata (old)\n-->\n" + META.format(policy=NONE), "restrictive"),
    "wrapped line that starts with a TC id continues its item":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n- TC-5: the confirm pass must not repeat\n"
         "  TC-4's step 1, i.e. launching a new run\n", "P"),
    "negated lead-in with the activity on a sub-bullet":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n- TC-4: when J-04 is replayed, the replay must "
         "not:\n  - launch a new run\n  - edit ledger rows\n", "P"),
    "a positive lead-in does not lend its sub-bullets a negation (control)":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n- TC-4: when J-04 is replayed, no error "
         "appears; the replay then:\n  - launches a new run\n", "I"),
    "a quoted TC inside a fence in NOTES after a fenced TC section stays prose (control)":
        (META.format(policy=ALLOWED) + "## TESTING REQUIREMENTS\n\n- TC-1: run the suite:\n\n```\nmake test\n```\n\n"
         "## NOTES\n\nThe rejected plan said:\n\n```\n- TC-4: the ledger row count is unchanged\n```\n", "I"),
}
bad = []
for name, (text, want) in DOCS.items():
    ps = [p for p in S.find_mutation_prohibitions(text) if "J-04 passes" not in p["text"]]
    if want in ("P", "I"):
        got = "P" if ps else "I"
    else:
        md, det = S.read_metadata(text), S.policy_intent_detail(text)
        got = "restrictive" if (md.get("side_effect_policy") == "none" or det["intent"] == "none") else "open"
    if got != want:
        bad.append(f"{name}: want {want}, got {got}")
for b in bad:
    print("      (" + b + ")")
sys.exit(1 if bad else 0)
PY
spec "$SPECS/l18e.md" allowed "J-04" "J-02"
sed -i 's/^## OUT OF SCOPE$/## OUT OF SCOPE (this iteration)/; s/^## DEFINITION OF DONE$/## Definition of Done (DoD)/' "$SPECS/l18e.md"
python3 - "$SPECS/l18e.md" <<'PY'
import sys
t = open(sys.argv[1]).read()
t = t.replace("- Any code change to the engine", "- Launching a new backtest run from the UI")
t = t.replace("- [ ] Target journeys pass via browser-qa-agent", "- [ ] The ledger is left untouched by the confirm pass")
open(sys.argv[1], "w").write(t)
PY
lint "$SPECS/l18e.md" --side-effects "$LED_DECL"
[[ "$(printf '%s' "$LINT_OUT" | grep -cE '^\[spec-lint\] ERROR E16 ' || true)" -ge 2 ]] \
  && rule_line E16 | grep -q 'OUT OF SCOPE' && printf '%s' "$LINT_OUT" | grep -qE 'ERROR E16 .*DEFINITION OF DONE' \
  && assert "L18e: suffixed OUT OF SCOPE / Definition of Done headings are still scanned" "pass" \
  || assert "L18e: heading variants (rc=$LINT_RC; $LINT_OUT)" "fail"
python3 "$PROBE" self-test >/dev/null 2>&1 \
  && assert "L19: iter_spec.py self-test passes (HARD-1 + HARD-2 + HARD-3 fixtures)" "pass" \
  || assert "L19: iter_spec.py self-test" "fail"
[[ "$(python3 "$PROBE" field "$SPECS/l3.md" side_effect_policy 2>/dev/null)" == "allowed" ]] \
  && python3 "$PROBE" metadata "$SPECS/l3.md" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["side_effect_policy"]=="allowed" and d["bold"]["side_effect_policy"] else 1)' \
  && assert "L19b: 'metadata' and 'field' expose side_effect_policy canonically" "pass" \
  || assert "L19b: side_effect_policy accessor" "fail"
python3 "$PROBE" lint "$SPECS/l8-allowed.md" --side-effects "$LED_DECL" --json-out "$WORK/l8.json" >/dev/null 2>&1
python3 - "$WORK/l8.json" <<'PY' && assert "L20: the lint JSON carries a side_effects block (policy, statuses, prohibitions, digest)" "pass" || assert "L20: side_effects block in lint JSON" "fail"
import json, sys
se = json.load(open(sys.argv[1]))["side_effects"]
assert se["policy"] == "allowed", se
assert se["availability"] == "ok", se
assert se["statuses"]["J-04"] == "mutating", se
assert len(se["prohibitions"]) == 2, se["prohibitions"]
assert {p["section"] for p in se["prohibitions"]} == {"OUT OF SCOPE", "TC-4"}, se["prohibitions"]
assert se["declaration_digest"], se
PY
_l22=y
for label in '- **Side effect policy:** none' '- **Side-effects policy:** none' \
             '- **Side-effect policy**: none' '* **Side-effect policy:** none'; do
  spec "$SPECS/l22.md" - "J-01" "J-02"
  python3 - "$SPECS/l22.md" "$label" <<'PY'
import sys
t = open(sys.argv[1]).read()
t = t.replace("- **Work kind:** verify-only\n", "- **Work kind:** verify-only\n" + sys.argv[2] + "\n")
open(sys.argv[1], "w").write(t)
PY
  lint "$SPECS/l22.md" --side-effects "$LED_DECL"
  { [[ "$LINT_RC" == "1" ]] && has_rule E02 && rule_line E02 | grep -q 'Side-effect policy'; } \
    || { _l22=n; echo "      (not caught: $label -> rc=$LINT_RC)"; }
done
[[ "$_l22" == y ]] \
  && assert "L22: a near-miss Side-effect policy label is E02 (re-planned), never a silently absent policy" "pass" \
  || assert "L22: near-miss policy labels" "fail"
_l22b=y
for label in '- **Side‑effect policy:** none' '- **Side-effect policy:** `none`' \
             '- **Side-effect policy:** none — nothing changes'; do
  spec "$SPECS/l22b.md" - "J-04" "J-02"
  python3 - "$SPECS/l22b.md" "$label" <<'PY'
import sys
t = open(sys.argv[1]).read()
t = t.replace("- **Work kind:** verify-only\n", "- **Work kind:** verify-only\n" + sys.argv[2] + "\n")
open(sys.argv[1], "w").write(t)
PY
  lint "$SPECS/l22b.md" --side-effects "$LED_DECL"
  has_rule E13 || { _l22b=n; echo "      (no E13 for: $label)"; }
  lint "$SPECS/l22b.md" --side-effects "$WORK/does-not-exist.json"
  { has_rule E15 && ! has_rule W11; } || { _l22b=n; echo "      (no E15 for: $label)"; }
done
[[ "$_l22b" == y ]] \
  && assert "L22b: a policy line that reads as 'none' in a form the parser cannot use still gets E13 / E15 (never a silent pass)" "pass" \
  || assert "L22b: restrictive intent" "fail"
_l22c=y
for notes in "- Side-effect policy: none → allowed (E13: J-04 is mutating)" \
             $'<!--\n- **Side-effect policy:** none | allowed\n-->'; do
  spec "$SPECS/l22c.md" allowed "J-04" "J-02"
  printf '%s\n' "$notes" >> "$SPECS/l22c.md"
  lint "$SPECS/l22c.md" --side-effects "$LED_DECL"
  if has_rule E13; then _l22c=n; echo "      (false positive for NOTES/comment: $notes)"; fi
done
for value in 'not allowed' 'no' 'read-only' 'forbidden' '~~allowed~~ none'; do
  spec "$SPECS/l22c.md" "$value" "J-04" "J-02"
  lint "$SPECS/l22c.md" --side-effects "$LED_DECL"
  { has_rule E06 && has_rule E13; } || { _l22c=n; echo "      (value not restrictive: $value)"; }
done
for label in '- *Side-effect policy:* none' '1. **Side-effect policy:** none' '| Side-effect policy | none |' \
             '> - **Side-effect policy:** none' '- **Side\u200b-effect policy:** none'; do
  spec "$SPECS/l22c.md" - "J-04" "J-02"
  python3 - "$SPECS/l22c.md" "$label" <<'PY'
import sys
t = open(sys.argv[1]).read()
t = t.replace("- **Work kind:** verify-only\n", "- **Work kind:** verify-only\n" + sys.argv[2].encode().decode("unicode_escape") + "\n")
open(sys.argv[1], "w").write(t)
PY
  lint "$SPECS/l22c.md" --side-effects "$LED_DECL"
  { has_rule E02 && has_rule E13; } || { _l22c=n; echo "      (label shape not caught: $label)"; }
done
[[ "$_l22c" == y ]] \
  && assert "L22c: only the metadata section decides when it has a policy line; any value but 'allowed' and any label shape is restrictive" "pass" \
  || assert "L22c: policy intent" "fail"
_l22d=y
for label in '- **Side-effect policy** none' '- **Side-effect policy (this iteration):** none' \
             '- **Side-effect policy for J-04:** none' '- Side-effect policy is none' \
             '- `Side-effect policy`: none' '- <b>Side-effect policy:</b> none'; do
  spec "$SPECS/l22d.md" - "J-04" "J-02"
  python3 - "$SPECS/l22d.md" "$label" <<'PY'
import sys
t = open(sys.argv[1]).read()
t = t.replace("- **Work kind:** verify-only\n", "- **Work kind:** verify-only\n" + sys.argv[2] + "\n")
open(sys.argv[1], "w").write(t)
PY
  lint "$SPECS/l22d.md" --side-effects "$LED_DECL"
  { has_rule E02 && has_rule E13; } || { _l22d=n; echo "      (no E02 + E13 for: $label)"; }
  lint "$SPECS/l22d.md" --side-effects "$WORK/does-not-exist.json"
  { has_rule E02 && has_rule E15 && ! has_rule W11; } || { _l22d=n; echo "      (no E02 + E15 for: $label)"; }
  [[ "$(python3 "$PROBE" policy-intent "$SPECS/l22d.md")" == "none" ]] || { _l22d=n; echo "      (policy-intent not none: $label)"; }
done
[[ "$_l22d" == y ]] \
  && assert "L22d: a policy label with no separator, a qualifier, backticks or HTML still reads as a restrictive policy (E02 + E13 / E15)" "pass" \
  || assert "L22d: separator-less policy labels" "fail"
_l22e=y
for value in 'allowed | none' 'allowed/none' 'allowed or none' 'allowed (but none for J-02)' 'allowed — but none for J-02'; do
  spec "$SPECS/l22e.md" "$value" "J-04" "J-02"
  lint "$SPECS/l22e.md" --side-effects "$WORK/does-not-exist.json"
  { has_rule E06 && has_rule E15; } || { _l22e=n; echo "      (ambiguous value not restrictive: $value)"; }
done
spec "$SPECS/l22e.md" "allowed — J-04's Run step adds one row" "J-04" "J-02"
lint "$SPECS/l22e.md" --side-effects "$WORK/does-not-exist.json"
{ has_rule W11 && ! has_rule E15; } || { _l22e=n; echo "      (a plain 'allowed — <note>' was read as restrictive)"; }
[[ "$_l22e" == y ]] \
  && assert "L22e: an ambiguous policy value ('allowed | none', 'allowed (but none …)') is restrictive; 'allowed — <note>' is not" "pass" \
  || assert "L22e: ambiguous policy values" "fail"
_l22f=y
spec "$SPECS/l22f.md" - "J-04" "J-02"
python3 - "$SPECS/l22f.md" <<'PY'
import sys
t = open(sys.argv[1]).read()
t = t.replace("- **Work kind:** verify-only\n", "- **Work kind:** verify-only\n<!-- draft\n- **Side-effect policy**: none\n")
open(sys.argv[1], "w").write(t)
PY
lint "$SPECS/l22f.md" --side-effects "$LED_DECL"
has_rule E13 || { _l22f=n; echo "      (an unclosed comment hid the policy: $LINT_OUT)"; }
spec "$SPECS/l22f.md" - "J-04" "J-02"
python3 - "$SPECS/l22f.md" <<'PY'
import sys
t = open(sys.argv[1]).read()
t = t.replace("- **Work kind:** verify-only\n", "- **Work kind:** verify-only\n```text\n- **Side-effect policy**: none\n")
t = t.replace("## NOTES", "```\nmake test\n```\n\n## NOTES")
open(sys.argv[1], "w").write(t)
PY
python3 "$PROBE" lint "$SPECS/l22f.md" --side-effects "$WORK/does-not-exist.json" --json-out "$WORK/l22f.json" >/dev/null 2>&1
python3 - "$WORK/l22f.json" <<'PY' || { _l22f=n; echo "      (a stray fence hid the policy)"; }
import json, sys
d = json.load(open(sys.argv[1]))
se = d["side_effects"]
assert se["restrictive"] and se["policy_intent_hidden"], se
assert any(e["rule"] == "E15" and "code fence or HTML comment" in e["msg"] for e in d["errors"]), d["errors"]
PY
[[ "$_l22f" == y ]] \
  && assert "L22f: an unclosed comment or a stray fence never hides a restrictive policy line (E13 / E15, reported as hidden)" "pass" \
  || assert "L22f: hidden policy lines" "fail"
[[ "$(python3 "$PROBE" policy-intent "$SPECS/l22b.md")" == "none" \
   && "$(python3 "$PROBE" policy-intent "$SPECS/l3.md")" == "allowed" && -z "$(python3 "$PROBE" policy-intent "$SPECS/l12b.md")" ]] \
  && python3 "$PROBE" ledger-ok "$LED_DECL" && ! python3 "$PROBE" ledger-ok "$LED_DECL" --build-id other-build 2>/dev/null \
  && ! python3 "$PROBE" ledger-ok "$WORK/does-not-exist.json" 2>/dev/null \
  && assert "L25: 'policy-intent' and 'ledger-ok' (the engine's fallback probes) answer correctly" "pass" \
  || assert "L25: fallback probes" "fail"
spec "$SPECS/l23.md" allowed "J-01" "J-04"
lint "$SPECS/l23.md" --side-effects "$LED_OBS" --json-out "$WORK/l23.json"
python3 - "$WORK/l23.json" "$LED_OBS" "$SPECS/l23.md" <<'PY' && assert "L23: a journey declared none but observed mutating is named as a DECLARATION CONFLICT to lanes, evaluator and report" "pass" || assert "L23: declaration conflict rendering" "fail"
import json, subprocess, sys
res = json.load(open(sys.argv[1]))
assert res["side_effects"]["conflicts"] == ["J-04"], res["side_effects"]
def ctx(mode):
    return subprocess.run([sys.executable, __import__("os").environ["PROBE"], "side-effect-context", "--mode", mode,
                           "--side-effects", sys.argv[2], "--spec", sys.argv[3]], capture_output=True, text=True).stdout
ev, lane = ctx("evaluator"), ctx("lane")
assert "J-04 (DECLARED NONE, but observed POST /api/runs in iter-8)" in ev, ev
assert "DECLARATION CONFLICT: J-04 is declared 'none' in docs/goal.md" in ev and "never excused" in ev, ev
assert "DECLARATION CONFLICT: J-04 is declared 'none'" in lane and "name the step that changes data" in lane, lane
PY
spec "$SPECS/l24.md" none "J-01, J-04" "J-02"
sed -i 's/^- \*\*Mode:\*\* next$/- **Mode:** baseline/' "$SPECS/l24.md"
lint "$SPECS/l24.md" --side-effects "$LED_DECL" --mode-expected baseline
[[ "$LINT_RC" == "1" ]] && rule_line E13 | grep -q 'baseline' && ! rule_line E13 | grep -qi 'drop it from Target' \
  && assert "L24: in a baseline spec the fix never suggests dropping a journey" "pass" \
  || assert "L24: baseline fix text ($LINT_OUT)" "fail"
spec "$SPECS/l21.md" - "J-01, J-04" "J-02"
lint "$SPECS/l21.md" --side-effects "$LED_DECL"
_se_rules="$(printf '%s' "$LINT_OUT" | grep -oE '^\[spec-lint\] (ERROR|WARN) (E06|E13|E14|E15|E16|W02|W09|W10|W11) ' | awk '{print $3}' | sort -u | tr '\n' ' ')"
[[ "$LINT_RC" == "0" && "$_se_rules" == "W02 " ]] \
  && assert "L21: an OLD spec (no policy line, no prohibition) gets W02 and nothing else — dispatch unchanged" "pass" \
  || assert "L21: old spec compatible (rc=$LINT_RC rules='$_se_rules'; $LINT_OUT)" "fail"

# ── Part O: observer end-to-end through the REAL run_verify (fake Playwright) ─
echo "== O. observer end-to-end (demo_runner.py --mode verify)"
DEMO_RUNNER_UNDER_TEST="${DEMO_RUNNER_UNDER_TEST:-$LIB/demo_runner.py}"
FAKEPW="$WORK/fakepw"; mkdir -p "$FAKEPW/playwright"
: > "$FAKEPW/playwright/__init__.py"
# A deterministic stand-in for playwright.sync_api: actions fire the requests the
# plan file (FAKE_PW_PLAN) names for "<action>:<key>", to every request handler
# registered on the context (or, when context.on is unsupported, the page).
cat > "$FAKEPW/playwright/sync_api.py" <<'PYEOF'
import json, os
from urllib.parse import urljoin, urlsplit


def _plan():
    try:
        with open(os.environ["FAKE_PW_PLAN"]) as fh:
            return json.load(fh)
    except Exception:
        return {}


class Request:
    def __init__(self, method, resource_type, url):
        self._m, self._t, self._u = method, resource_type, url

    @property
    def method(self):
        return self._m

    @property
    def resource_type(self):
        return self._t

    @property
    def url(self):
        return self._u


class _Locator:
    def __init__(self, page, key):
        self.page, self.key = page, key

    @property
    def first(self):
        return self

    def wait_for(self, state="visible", timeout=None):
        if state == "visible" and self.key in self.page.plan.get("missing", []):
            raise TimeoutError(f"fake: {self.key!r} is not visible")

    def click(self, timeout=None):
        self.page._fire("click:" + str(self.key))

    def fill(self, text, timeout=None):
        self.page._fire("fill:" + str(self.key))

    def count(self):
        return 0

    def evaluate(self, *a, **k):
        return None

    def scroll_into_view_if_needed(self, *a, **k):
        return None


class Page:
    def __init__(self, ctx):
        self.ctx, self.plan, self.origin = ctx, ctx.plan, ""

    def on(self, event, handler):
        if self.plan.get("page_on_fails"):
            raise RuntimeError("fake: page.on unsupported")
        self.ctx.handlers.setdefault(event, []).append(handler)

    def goto(self, url, wait_until=None, timeout=None):
        u = urlsplit(url)
        self.origin = f"{u.scheme}://{u.netloc}"
        if self.plan.get("crash_on") == "goto:" + (u.path or "/"):
            raise RuntimeError("fake: the browser crashed")
        self._fire("goto:" + (u.path or "/"))

    def wait_for_load_state(self, *a, **k):
        return None

    def get_by_role(self, role, name=None):
        return _Locator(self, name or role)

    def get_by_text(self, text):
        return _Locator(self, text)

    def get_by_label(self, v):
        return _Locator(self, v)

    def get_by_placeholder(self, v):
        return _Locator(self, v)

    def get_by_test_id(self, v):
        return _Locator(self, v)

    def locator(self, v):
        return _Locator(self, v)

    def screenshot(self, path=None, **k):
        if path:
            with open(path, "wb") as fh:
                fh.write(b"\x89PNG fake")

    def evaluate(self, *a, **k):
        return None

    def wait_for_timeout(self, ms):
        return None

    def _fire(self, key):
        for method, rtype, url in self.plan.get("requests", {}).get(key, []):
            full = url if "://" in url else urljoin(self.origin + "/", url)
            for h in list(self.ctx.handlers.get("request", [])):
                h(Request(method, rtype, full))


class Context:
    def __init__(self, plan, index):
        self.plan, self.handlers, self.index = plan, {}, index

    def on(self, event, handler):
        if self.plan.get("context_on_fails"):
            raise AttributeError("fake: context.on unsupported")
        self.handlers.setdefault(event, []).append(handler)

    def new_page(self):
        if self.plan.get("crash_new_page") == self.index:
            raise RuntimeError("fake: the browser crashed while opening a page")
        return Page(self)

    def close(self):
        return None


class Browser:
    def __init__(self):
        self.plan, self.contexts = _plan(), 0

    def new_context(self, **kw):
        self.contexts += 1
        return Context(self.plan, self.contexts)

    def close(self):
        return None


class _Chromium:
    def launch(self, **kw):
        if _plan().get("launch_fails"):
            raise RuntimeError("fake: chromium launch failed")
        return Browser()


class _PW:
    chromium = _Chromium()

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def sync_playwright():
    return _PW()
PYEOF
OBS="$WORK/obs"; mkdir -p "$OBS/scripts" "$OBS/repo/project-extensions/side-effects" "$OBS/ev"
printf 'POST /api/policy/evaluate\n' > "$OBS/repo/project-extensions/side-effects/read-only-endpoints.txt"
golden() {  # golden <J-id> <json-steps>
  printf '{"schema_version": 1, "journey": "%s", "name": "%s fixture", "default_timeout_ms": 2000, "steps": %s}\n' \
    "$1" "$1" "$2" > "$OBS/scripts/$1.json"
}
golden J-02 '[{"n":1,"action":{"type":"goto","url":"/policy"}},{"n":2,"action":{"type":"click","target":{"role":"button","name":"Evaluate"}},"expect":{"text":"facts"}}]'
golden J-04 '[{"n":1,"action":{"type":"goto","url":"/backtests/new"}},{"n":2,"action":{"type":"click","target":{"role":"button","name":"Run"}},"expect":{"text":"Engine"}}]'
golden J-06 '[{"n":1,"action":{"type":"goto","url":"/login"}},{"n":2,"action":{"type":"fill","target":{"label":"Email"},"text":"a@b.c"}},{"n":3,"action":{"type":"click","target":{"role":"button","name":"Sign in"}}},{"n":4,"action":{"type":"goto","url":"/dashboard"},"expect":{"text":"Welcome"}}]'
golden J-07 '[{"n":1,"action":{"type":"goto","url":"/items"}},{"n":2,"action":{"type":"click","target":{"role":"button","name":"Save"}},"expect":{"text":"Saved"}},{"n":3,"action":{"type":"goto","url":"/items/1"}}]'
golden J-08 '[{"n":1,"action":{"type":"goto","url":"/about"},"expect":{"text":"About"}}]'
cat > "$OBS/plan.json" <<'EOF'
{"missing": ["Saved"],
 "requests": {
  "click:Evaluate": [["POST", "fetch", "/api/policy/evaluate"], ["GET", "fetch", "/api/policy/catalog"]],
  "click:Run": [["POST", "fetch", "http://localhost:48801/api/runs"], ["POST", "image", "/pixel"]],
  "click:Sign in": [["POST", "fetch", "/api/login"]],
  "click:Save": [["POST", "xhr", "/api/items"]],
  "goto:/about": [["POST", "fetch", "https://stats.example.com/collect"], ["POST", "fetch", "/_next/data/about.json"], ["GET", "document", "/about"]]
 }}
EOF
SIDE="$OBS/repo/runs/goal-session-obs/state/journey-side-effects.json"
RUNREC="$OBS/repo/runs/goal-session-obs/iter-8/replay-side-effects.json"
verify() {  # verify <out-results> [extra args...] -> VRC
  local out="$1"; shift
  VRC=0
  PYTHONPATH="$FAKEPW" FAKE_PW_PLAN="${FAKE_PLAN:-$OBS/plan.json}" python3 "$DEMO_RUNNER_UNDER_TEST" --mode verify \
    --scripts-dir "${VSCRIPTS:-$OBS/scripts}" --journeys "${VJOURNEYS:-J-02,J-04,J-06,J-07,J-08,J-09}" \
    --results "$out" --evidence-dir "$OBS/ev" --base-url "http://localhost:38801" \
    --phase-id "${VPHASE:-goal-obs-iter-8}" --repo-root "$OBS/repo" "$@" >"$out.log" 2>&1 || VRC=$?
}
row() { grep -E "^\| UT-$2 " "$1" | head -1; }
verify "$OBS/res.md" --side-effects-out "$SIDE" --side-effects-run-out "$RUNREC"
[[ "$VRC" == "5" ]] \
  && assert "O1: the replay verdict contract is unchanged (J-07 FAILs -> rc 5; no observer effect on rc)" "pass" \
  || assert "O1: rc 5 expected (got $VRC: $(tail -3 "$OBS/res.md.log" | tr '\n' ' '))" "fail"
row "$OBS/res.md" J-04 | grep -qF '; side effects: 1 mutating request(s) (POST /api/runs) | PASS |' \
  && assert "O2: J-04's row names its observed mutation (image POST not counted)" "pass" \
  || assert "O2: J-04 row suffix ($(row "$OBS/res.md" J-04))" "fail"
row "$OBS/res.md" J-02 | grep -qF '; side effects: none observed; read-only exception applied: POST /api/policy/evaluate | PASS |' \
  && assert "O2b: J-02's read-only POST is suppressed AND the applied exception is shown" "pass" \
  || assert "O2b: J-02 row ($(row "$OBS/res.md" J-02))" "fail"
row "$OBS/res.md" J-06 | grep -qF '; side effects: none observed; auth request(s) not counted: POST /api/login | PASS |' \
  && row "$OBS/res.md" J-08 | grep -qF '; side effects: none observed | PASS |' \
  && assert "O2c: auth POSTs (reported as not counted), external analytics and dev-asset POSTs are not mutations" "pass" \
  || assert "O2c: J-06/J-08 rows ($(row "$OBS/res.md" J-06) / $(row "$OBS/res.md" J-08))" "fail"
row "$OBS/res.md" J-07 | grep -qF '; side effects before the replay stopped: 1 mutating request(s) (POST /api/items) | FAIL |' \
  && assert "O2d: a FAILed replay reports what it mutated before it stopped" "pass" \
  || assert "O2d: J-07 row ($(row "$OBS/res.md" J-07))" "fail"
row "$OBS/res.md" J-09 | grep -q 'side effects' \
  && assert "O2e: a SKIPped journey (no golden) carries no side-effect claim" "fail" \
  || assert "O2e: a SKIPped journey (no golden) carries no side-effect claim" "pass"
PYTHONPATH="$LIB" python3 - "$OBS/res.md" <<'PY' && assert "O3: the results rows keep the 8-cell shape and verdicts merge_ui_test_results.py reads" "pass" || assert "O3: row shape / merge parse" "fail"
import sys
import merge_ui_test_results as M
rows = {r["test_id"]: r for r in M.parse_rows(open(sys.argv[1]).read())}
assert {k: r["verdict"] for k, r in rows.items()} == {
    "UT-J-02": "PASS", "UT-J-04": "PASS", "UT-J-06": "PASS", "UT-J-07": "FAIL", "UT-J-08": "PASS", "UT-J-09": "SKIP"}, rows
assert all(len(r["cells"]) == 7 for r in rows.values()), [len(r["cells"]) for r in rows.values()]
PY
python3 - "$SIDE" <<'PY' && assert "O4: the sidecar records per-journey observations (latest / last_attempt), partial FAIL upgrades, SKIP untouched" "pass" || assert "O4: sidecar content" "fail"
import json, sys
j = json.load(open(sys.argv[1]))["journeys"]
assert set(j) == {"J-02", "J-04", "J-06", "J-07", "J-08"}, set(j)
l4 = j["J-04"]["latest"]
assert l4["mutating_count"] == 1 and l4["complete"] is True and l4["iter"] == 8 and l4["iter_name"] == "goal-obs-iter-8", l4
assert l4["requests"] == [{"method": "POST", "path": "/api/runs", "class": "mutating", "count": 1}], l4["requests"]
assert j["J-02"]["latest"]["readonly_count"] == 1 and j["J-02"]["latest"]["mutating_count"] == 0
assert j["J-02"]["latest"]["exceptions_applied"] == [{"method": "POST", "path": "/api/policy/evaluate"}]
assert j["J-06"]["latest"]["auth_count"] == 1 and j["J-06"]["latest"]["mutating_count"] == 0
assert j["J-06"]["latest"]["auth_ignored"] == [{"method": "POST", "path": "/api/login"}], j["J-06"]["latest"]
g4 = l4["golden_sha256"]
assert isinstance(g4, str) and len(g4) == 64 and list(j["J-04"]["goldens"]) == [g4], j["J-04"].get("goldens")
assert l4["classifier_version"] == 2 and l4["observed_at"].endswith("Z"), l4
l7 = j["J-07"]["latest"]
assert l7["complete"] is False and l7["mutating_count"] == 1 and l7["verdict"] == "FAIL", l7
assert j["J-07"]["mutating_history"][0]["sample"] == ["POST /api/items"]
assert all(r["latest"]["readonly_endpoints_sha256"] for r in j.values())
PY
python3 - "$RUNREC" <<'PY' && assert "O5: the per-run record names the iteration, the exception file digest and a successful sidecar update" "pass" || assert "O5: run record" "fail"
import json, sys
r = json.load(open(sys.argv[1]))
assert r["iter"] == 8 and r["iter_name"] == "goal-obs-iter-8", r
assert r["sidecar"]["updated"] is True, r["sidecar"]
assert r["readonly_endpoints"]["present"] is True and r["readonly_endpoints"]["sha256"]
assert sorted(r["journeys"]) == ["J-02", "J-04", "J-06", "J-07", "J-08"]
PY
cat > "$OBS/goal.md" <<'EOF'
# Goal

## Must-have user journeys

- **J-02: Evaluate**
  - Steps:
    1. Visit `/policy`, press Evaluate
  - Acceptance: facts render
  - Side effects: none — evaluating persists nothing

- **J-04: Run**
  - Steps:
    1. Open Backtests; click Run
  - Acceptance: Engine header shows
  - Side effects: none — (wrong on purpose: the replay observed a POST)

- **J-07: Save**
  - Steps:
    1. Visit `/items`, click Save
  - Acceptance: Saved shows

## Anti-goals

- no paid SaaS
EOF
PYTHONPATH="$LIB" python3 "$GG" side-effects "$OBS/goal.md" --sidecar "$SIDE" --repo-root "$OBS/repo" --out "$OBS/led.json" >/dev/null 2>&1
python3 - "$OBS/led.json" <<'PY' && assert "O6: the next ledger: J-04 observed-mutating beats its none, J-02 follows none through the exception, J-07 mutating" "pass" || assert "O6: ledger from observations" "fail"
import json, sys
j = json.load(open(sys.argv[1]))["journeys"]
assert j["J-04"]["status"] == "mutating" and j["J-04"]["status_source"] == "observed", j["J-04"]
assert j["J-02"]["status"] == "none" and j["J-02"]["exceptions_applied"], j["J-02"]
assert j["J-07"]["status"] == "mutating", j["J-07"]
PY
# A later COMPLETE replay whose golden no longer mutates clears J-04; a FAILed
# replay that saw nothing never does.
cat > "$OBS/plan-nopost.json" <<'EOF'
{"missing": ["Saved", "Engine"], "requests": {}}
EOF
FAKE_PLAN="$OBS/plan-nopost.json" VJOURNEYS="J-04" VPHASE="goal-obs-iter-9" verify "$OBS/res9.md" --side-effects-out "$SIDE"
python3 -c "import json,sys; j=json.load(open('$SIDE'))['journeys']['J-04']; sys.exit(0 if j['latest']['mutating_count']==1 and j['last_attempt']['iter']==9 else 1)" \
  && assert "O7: a FAILed replay that observed nothing does NOT clear J-04's recorded mutation" "pass" \
  || assert "O7: partial replay must not downgrade" "fail"
cat > "$OBS/plan-clean.json" <<'EOF'
{"requests": {}}
EOF
FAKE_PLAN="$OBS/plan-clean.json" VJOURNEYS="J-04" VPHASE="goal-obs-iter-10" verify "$OBS/res10.md" --side-effects-out "$SIDE"
PYTHONPATH="$LIB" python3 -c "import json,sys; from demo_runner import uncleared_mutations as u; j=json.load(open('$SIDE'))['journeys']['J-04']; sys.exit(0 if j['latest']['mutating_count']==0 and j['latest']['iter']==10 and [h['iter'] for h in j['mutating_history']]==[8] and u(j)==[] else 1)" \
  && assert "O7b: a COMPLETE clean replay of the SAME golden clears the mutation (history keeps iter-8)" "pass" \
  || assert "O7b: complete clean replay clears" "fail"
# O7c — the LLM lane / SPEED-21 re-derived J-04's golden into one that never
# clicks Run: its clean replay must NOT clear the recorded mutation.
SWAP="$OBS/swap"; mkdir -p "$SWAP/scripts"
cp "$OBS/scripts/J-04.json" "$SWAP/scripts/J-04.json"
SWAP_SIDE="$OBS/repo/runs/goal-session-swap/state/journey-side-effects.json"
SWAP_REC="$OBS/repo/runs/goal-session-swap/iter-9/replay-side-effects.json"
VSCRIPTS="$SWAP/scripts" VJOURNEYS="J-04" VPHASE="goal-swap-iter-8" verify "$OBS/res-swap8.md" --side-effects-out "$SWAP_SIDE"
printf '%s\n' '{"schema_version": 1, "journey": "J-04", "name": "J-04 re-derived", "default_timeout_ms": 2000, "steps": [{"n": 1, "action": {"type": "goto", "url": "/runs/80f6"}}, {"n": 2, "action": {"type": "click", "target": {"role": "link", "name": "Compare"}}, "expect": {"text": "Engine"}}]}' \
  > "$SWAP/scripts/J-04.json"
FAKE_PLAN="$OBS/plan-clean.json" VSCRIPTS="$SWAP/scripts" VJOURNEYS="J-04" VPHASE="goal-swap-iter-9" \
  verify "$OBS/res-swap9.md" --side-effects-out "$SWAP_SIDE" --side-effects-run-out "$SWAP_REC"
PYTHONPATH="$LIB" python3 "$GG" side-effects "$OBS/goal.md" --sidecar "$SWAP_SIDE" --repo-root "$OBS/repo" --out "$OBS/led-swap.json" >/dev/null 2>&1
PYTHONPATH="$LIB" python3 - "$SWAP_SIDE" "$SWAP_REC" "$OBS/led-swap.json" "$OBS/res-swap9.md" <<'PY' && assert "O7c: a clean replay of a DIFFERENT (re-derived) golden never clears J-04's mutation; the run record and the ledger say so" "pass" || assert "O7c: golden swap" "fail"
import json, sys
from demo_runner import uncleared_mutations
j = json.load(open(sys.argv[1]))["journeys"]["J-04"]
assert j["latest"]["iter"] == 9 and j["latest"]["mutating_count"] == 0, j["latest"]
assert [m["iter"] for m in uncleared_mutations(j)] == [8], j
assert len(j["goldens"]) == 2, j["goldens"]
rec = json.load(open(sys.argv[2]))
assert rec["sidecar"]["clear_refused"]["J-04"]["mutating_iter"] == 8, rec["sidecar"]
led = json.load(open(sys.argv[3]))["journeys"]["J-04"]
assert led["status"] == "mutating" and led["observation_sticky"] and led["observed_iter"] == 8, led
assert "| PASS |" in open(sys.argv[4]).read()
PY
# O14 — the sidecar update times out (a writer holds the state/ lock): the
# observation is not lost; the next preflight reads and repairs it.
LOCK_DIR="$OBS/repo/runs/goal-session-lock/state"; mkdir -p "$LOCK_DIR"
LOCK_SIDE="$LOCK_DIR/journey-side-effects.json"; printf '{"schema_version": 1, "journeys": {}}\n' > "$LOCK_SIDE"
LOCK_REC="$OBS/repo/runs/goal-session-lock/iter-5/replay-side-effects.json"
python3 -c 'import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY); fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").write("locked"); time.sleep(60)' "$LOCK_DIR" "$OBS/lock-ready" &
LOCK_PID=$!; DUMMY_PIDS+=("$LOCK_PID")
for _ in $(seq 1 100); do [[ -f "$OBS/lock-ready" ]] && break; sleep 0.1; done
CHAIN_SIDE_EFFECT_LOCK_TIMEOUT=0.3 VJOURNEYS="J-04" VPHASE="goal-lock-iter-5" \
  verify "$OBS/res-lock.md" --side-effects-out "$LOCK_SIDE" --side-effects-run-out "$LOCK_REC"
kill "$LOCK_PID" 2>/dev/null; wait "$LOCK_PID" 2>/dev/null
LOCK_RC=$VRC
PYTHONPATH="$LIB" python3 "$GG" side-effects "$OBS/goal.md" --sidecar "$LOCK_SIDE" --repo-root "$OBS/repo" \
  --out "$OBS/led-lock.json" --iter 6 --iter-name goal-lock-iter-6 --step preflight --record-digest > "$OBS/lock-events.txt" 2>/dev/null
python3 - "$LOCK_REC" "$OBS/led-lock.json" "$LOCK_SIDE" "$OBS/lock-events.txt" "$OBS/res-lock.md" "$LOCK_RC" <<'PY' && assert "O14: a sidecar lock timeout loses nothing: the run record keeps J-04's mutation, the next ledger counts it and the preflight repairs the sidecar" "pass" || assert "O14: lock timeout recovery" "fail"
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["sidecar"]["updated"] is False and "could not lock" in rec["sidecar"]["message"], rec["sidecar"]
assert sys.argv[6] == "0" and "1 mutating request(s) (POST /api/runs) | PASS |" in open(sys.argv[5]).read()
led = json.load(open(sys.argv[2]))
assert led["complete"] and led["journeys"]["J-04"]["status"] == "mutating", led["journeys"]["J-04"]
assert led["run_records_pending"], led
side = json.load(open(sys.argv[3]))
assert rec["run_id"] in side["merged_runs"] and side["journeys"]["J-04"]["latest"]["mutating_count"] == 1, side
events = [l.split("\t", 1)[0] for l in open(sys.argv[4]) if "\t" in l]
assert "side_effect_observations_repaired" in events and "side_effect_declaration_conflict" in events, events
PY
verify "$OBS/res-off.md"
if grep -q 'side effects' "$OBS/res-off.md"; then
  assert "O8: without the observer flags the results rows are unchanged (no suffix)" "fail"
else
  assert "O8: without the observer flags the results rows are unchanged (no suffix)" "pass"
fi
cat > "$OBS/plan-crash.json" <<'EOF'
{"missing": ["Saved"], "crash_new_page": 2,
 "requests": {"click:Run": [["POST", "fetch", "/api/runs"]]}}
EOF
rm -f "$OBS/side-crash.json"
FAKE_PLAN="$OBS/plan-crash.json" VJOURNEYS="J-04,J-07,J-08" verify "$OBS/res-crash.md" --side-effects-out "$OBS/side-crash.json"
[[ "$VRC" == "6" ]] && python3 -c "import json,sys; j=json.load(open('$OBS/side-crash.json'))['journeys']; sys.exit(0 if j['J-04']['latest']['mutating_count']==1 and 'J-08' not in j and 'latest' not in j['J-07'] and j['J-07']['last_attempt']['verdict']=='INFRA' else 1)" \
  && assert "O9: a browser crash still records the journeys observed before it (rc 6 contract kept)" "pass" \
  || assert "O9: infra crash path (rc=$VRC; $(cat "$OBS/side-crash.json" 2>/dev/null | head -c 300))" "fail"
printf '{"context_on_fails": true, "missing": [], "requests": {"click:Run": [["POST", "fetch", "/api/runs"]]}}\n' > "$OBS/plan-ctx.json"
FAKE_PLAN="$OBS/plan-ctx.json" VJOURNEYS="J-04" verify "$OBS/res-ctx.md" --side-effects-out "$OBS/side-ctx.json"
row "$OBS/res-ctx.md" J-04 | grep -qF '1 mutating request(s) (POST /api/runs)' \
  && assert "O10: when context.on is unavailable the page-level observer still records the mutation" "pass" \
  || assert "O10: page fallback ($(row "$OBS/res-ctx.md" J-04))" "fail"
printf '{"context_on_fails": true, "page_on_fails": true, "missing": [], "requests": {"click:Run": [["POST", "fetch", "/api/runs"]]}}\n' > "$OBS/plan-blind.json"
FAKE_PLAN="$OBS/plan-blind.json" VJOURNEYS="J-04" VPHASE="goal-obs-iter-11" verify "$OBS/res-blind.md" --side-effects-out "$SIDE"
row "$OBS/res-blind.md" J-04 | grep -qF 'side effects: NOT observed' \
  && python3 -c "import json,sys; j=json.load(open('$SIDE'))['journeys']['J-04']; sys.exit(0 if j['latest']['iter']==10 and j['last_attempt']['complete'] is False else 1)" \
  && assert "O11: a BLIND observation says so in the row and can never clear a recorded status" "pass" \
  || assert "O11: blind observer ($(row "$OBS/res-blind.md" J-04))" "fail"
printf '{ corrupt' > "$OBS/side-corrupt.json"
VJOURNEYS="J-04,J-07" verify "$OBS/res-corrupt.md" --side-effects-out "$OBS/side-corrupt.json" --side-effects-run-out "$OBS/run-corrupt.json"
[[ "$VRC" == "5" && "$(cat "$OBS/side-corrupt.json")" == "{ corrupt" ]] \
  && python3 -c "import json,sys; r=json.load(open('$OBS/run-corrupt.json')); sys.exit(0 if r['sidecar']['updated'] is False and 'not overwritten' in r['sidecar']['message'] else 1)" \
  && grep -q 'sidecar NOT updated' "$OBS/res-corrupt.md.log" \
  && assert "O12: a corrupt sidecar is left untouched, said loudly, and the replay verdict is unaffected" "pass" \
  || assert "O12: corrupt sidecar handling (rc=$VRC)" "fail"
printf '%s' '{"schema_version": 1, "journeys": {"J-04": {"mutating_history": 5, "latest": 7}}}' > "$OBS/side-odd.json"
VJOURNEYS="J-04,J-07" verify "$OBS/res-odd.md" --side-effects-out "$OBS/side-odd.json" --side-effects-run-out "$OBS/run-odd.json"
[[ "$VRC" == "5" ]] && python3 -c "import json,sys; r=json.load(open('$OBS/run-odd.json')); sys.exit(0 if r['sidecar']['updated'] is False and 'not overwritten' in r['sidecar']['message'] else 1)" \
  && [[ "$(cat "$OBS/side-odd.json")" == '{"schema_version": 1, "journeys": {"J-04": {"mutating_history": 5, "latest": 7}}}' ]] \
  && row "$OBS/res-odd.md" J-04 | grep -qF '1 mutating request(s)' \
  && assert "O12b: a sidecar with wrongly-shaped records is refused, never crashes the replay (rc 5 kept, row intact, file untouched)" "pass" \
  || assert "O12b: odd sidecar shape (rc=$VRC; $(tail -2 "$OBS/res-odd.md.log" | tr '\n' ' '))" "fail"
CHAIN_SIDE_EFFECT_IGNORE_PATHS="" VJOURNEYS="J-06" verify "$OBS/res-noauth.md" --side-effects-run-out "$OBS/run-noauth.json"
row "$OBS/res-noauth.md" J-06 | grep -qF '1 mutating request(s) (POST /api/login)' \
  && assert "O13: CHAIN_SIDE_EFFECT_IGNORE_PATHS='' makes the sign-in POST count (set-empty is honoured end-to-end)" "pass" \
  || assert "O13: set-empty ignore list ($(row "$OBS/res-noauth.md" J-06))" "fail"

# ── Part R: the replay lane (lib/replay-lane.sh) ─────────────────────────────
echo "== R. replay lane wiring (observer flags, telemetry, prompt block)"
RSBX="$WORK/rl"; mkdir -p "$RSBX/lib" "$RSBX/runs/goal-session-rl/journey-scripts" "$RSBX/runs/goal-session-rl/iter-3" "$RSBX/reports"
cp "$LIB/replay-lane.sh" "$LIB/iter_spec.py" "$LIB/merge_ui_test_results.py" "$RSBX/lib/"
cat > "$RSBX/lib/demo_runner.py" <<'PYEOF'
import json, os, sys
argv = sys.argv[1:]
def arg(n):
    return argv[argv.index(n) + 1] if n in argv and argv.index(n) + 1 < len(argv) else ""
mode = arg("--mode")
js = [j for j in arg("--journeys").split(",") if j]
if mode == "lint":
    for j in js:
        print(f"{j} ok")
    sys.exit(0)
with open(os.environ["STUB_ARGV"], "a") as fh:
    fh.write(" ".join(argv) + "\n")
with open(arg("--results"), "w") as fh:
    fh.write("**Browser QA Verdict:** PASS\n\n| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n"
             "|---|---|---|---|---|---|---|---|\n"
             + "".join(f"| UT-{j} | r | regression | P1 | e | a | PASS | none |\n" for j in js))
run = arg("--side-effects-run-out")
if run:
    os.makedirs(os.path.dirname(run), exist_ok=True)
    state = os.environ.get("STUB_SIDECAR_STATE", "ok")
    side = {"path": arg("--side-effects-out"), "updated": state != "failed",
            "message": "sidecar update failed: could not lock x within 10s" if state == "failed" else "updated"}
    if state == "refused":
        side["clear_refused"] = {"J-04": {"golden_sha256": "b" * 64, "mutating_golden_sha256": "a" * 64,
                                          "mutating_iter": 2, "mutating_iter_name": "goal-rl-iter-2",
                                          "sample": ["POST /api/runs"]}}
    import datetime
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    if os.environ.get("STUB_OLD_RECORD"):
        stamp = "2020-01-01T00:00:00.000000Z"
    if os.environ.get("STUB_NO_TIMESTAMP"):
        stamp = None
    json.dump({"run_id": "stub", "iter": 3, "iter_name": arg("--phase-id"), "observed_at": stamp,
               "sidecar": side, "journeys": {"J-04": {
        "mutating_count": 1, "auth_count": 1, "readonly_count": 1, "complete": True, "verdict": "PASS",
        "golden_sha256": "a" * 64,
        "requests": [{"method": "POST", "path": "/api/runs", "class": "mutating", "count": 1}],
        "exceptions_applied": [{"method": "POST", "path": "/api/policy/evaluate"}],
        "auth_ignored": [{"method": "POST", "path": "/api/login"}]}}}, open(run, "w"))
sys.exit(0)
PYEOF
echo '{"journey":"J-04","steps":[]}' > "$RSBX/runs/goal-session-rl/journey-scripts/J-04.json"
rl_run() {  # rl_run -> RL_ARGV / RL_EVENTS / RL_LOG files (fresh per call)
  : > "$WORK/rl-argv.txt"; : > "$WORK/rl-events.txt"
  ( set -euo pipefail
    export STUB_ARGV="$WORK/rl-argv.txt"
    # shellcheck source=/dev/null
    source "$RSBX/lib/replay-lane.sh"
    REPO_ROOT="$RSBX"; REQUIRED_JOURNEYS="J-04"; FRONTEND_AVAILABLE=yes; FRONTEND_URL="http://localhost:9"
    goal_maintenance_isolation_required() { return 1; }
    record_telemetry_event() { printf '%s\t%s\n' "$1" "$2" >> "$WORK/rl-events.txt"; }
    replay_lane_paths "goal-rl-iter-3"
    replay_lane_partition_and_verify "goal-rl-iter-3" >"$WORK/rl-log.txt" 2>&1
  )
}
rl_run
grep -qF -- "--side-effects-out $RSBX/runs/goal-session-rl/state/journey-side-effects.json" "$WORK/rl-argv.txt" \
  && grep -qF -- "--side-effects-run-out $RSBX/runs/goal-session-rl/iter-3/replay-side-effects.json" "$WORK/rl-argv.txt" \
  && assert "R1: the verify call carries the engine-owned sidecar and this iteration's run record by default" "pass" \
  || assert "R1: observer flags ($(cat "$WORK/rl-argv.txt"))" "fail"
python3 - "$WORK/rl-events.txt" <<'PY' && assert "R2: side_effect_observed + side_effect_exception_applied are emitted from the run record" "pass" || assert "R2: lane telemetry ($(cat "$WORK/rl-events.txt"))" "fail"
import json, sys
ev = [l.rstrip("\n").split("\t", 1) for l in open(sys.argv[1]) if "\t" in l]
obs = [json.loads(p) for e, p in ev if e == "side_effect_observed"]
exc = [json.loads(p) for e, p in ev if e == "side_effect_exception_applied"]
assert obs == [{"iter_name": "goal-rl-iter-3", "journey": "J-04", "mutating_count": 1, "auth_count": 1,
                "readonly_count": 1, "sample": ["POST /api/runs"], "complete": True, "golden": "a" * 12}], obs
assert exc == [{"iter_name": "goal-rl-iter-3", "journey": "J-04", "kind": "read-only", "method": "POST",
                "path": "/api/policy/evaluate"},
               {"iter_name": "goal-rl-iter-3", "journey": "J-04", "kind": "auth", "method": "POST",
                "path": "/api/login"}], exc
assert not [e for e, _ in ev if e in ("side_effect_sidecar_update_failed", "side_effect_clear_refused")], ev
PY
STUB_SIDECAR_STATE=failed rl_run
grep -q '^side_effect_sidecar_update_failed	.*"journeys": \["J-04"\]' "$WORK/rl-events.txt" \
  && grep -q 'side-effect sidecar was NOT updated' "$WORK/rl-log.txt" \
  && assert "R2b: a failed sidecar update is loud (side_effect_sidecar_update_failed + a warning), never silent" "pass" \
  || assert "R2b: sidecar update failure ($(cat "$WORK/rl-events.txt"))" "fail"
STUB_OLD_RECORD=1 rl_run
if grep -q '^side_effect_' "$WORK/rl-events.txt"; then
  assert "R2d: a record older than the replay run is never reported as that run's" "fail"
else
  assert "R2d: a record older than the replay run is never reported as that run's" "pass"
fi
STUB_NO_TIMESTAMP=1 rl_run
if ! grep -q '^side_effect_' "$WORK/rl-events.txt" && grep -q 'carries no readable observed_at' "$WORK/rl-log.txt"; then
  assert "R2e: a run record without a timestamp is not reported, and says so" "pass"
else
  assert "R2e: timestamp-less record ($(cat "$WORK/rl-events.txt"))" "fail"
fi
STUB_SIDECAR_STATE=refused rl_run
grep -q '^side_effect_clear_refused	.*"mutating_iter": 2' "$WORK/rl-events.txt" \
  && grep -q 'stays MUTATING' "$WORK/rl-log.txt" \
  && assert "R2c: a clean replay that cannot clear an earlier mutation emits side_effect_clear_refused" "pass" \
  || assert "R2c: clear refused ($(cat "$WORK/rl-events.txt"))" "fail"
echo '{"stale": true}' > "$RSBX/runs/goal-session-rl/iter-3/replay-side-effects.json"
CHAIN_SIDE_EFFECT_OBSERVER=false rl_run
if grep -q -- '--side-effects' "$WORK/rl-argv.txt" || [[ -s "$WORK/rl-events.txt" ]]; then
  assert "R3: CHAIN_SIDE_EFFECT_OBSERVER=false passes no observer flag and emits nothing" "fail"
else
  assert "R3: CHAIN_SIDE_EFFECT_OBSERVER=false passes no observer flag and emits nothing" "pass"
fi
[[ ! -f "$RSBX/runs/goal-session-rl/iter-3/replay-side-effects.json" ]] \
  && grep -lq '"stale": true' "$RSBX/runs/goal-session-rl/iter-3/"replay-side-effects.*.json 2>/dev/null \
  && assert "R4: a previous run's record is ARCHIVED at partition entry (never read as this run's, never deleted)" "pass" \
  || assert "R4: stale run record archived ($(ls "$RSBX/runs/goal-session-rl/iter-3/"))" "fail"
_r3b=y
for v in 0 off no FALSE; do
  CHAIN_SIDE_EFFECT_OBSERVER="$v" rl_run
  grep -q -- '--side-effects' "$WORK/rl-argv.txt" && _r3b=n
done
CHAIN_SIDE_EFFECT_OBSERVER=flase rl_run
grep -q -- '--side-effects-out' "$WORK/rl-argv.txt" || _r3b=n
grep -q "CHAIN_SIDE_EFFECT_OBSERVER='flase'" "$WORK/rl-log.txt" || _r3b=n
[[ "$_r3b" == y ]] \
  && assert "R3b: 0/off/no/FALSE disable the observer; an unrecognised value keeps it ON and says so" "pass" \
  || assert "R3b: observer knob parsing ($(cat "$WORK/rl-log.txt" | head -3))" "fail"
( source "$RSBX/lib/replay-lane.sh"
  [[ -z "$(side_effects_prompt_block "" "$SPECS/l3.md")" ]] || exit 1
  [[ -z "$(side_effects_prompt_block "$WORK/nope.json" "$SPECS/l3.md")" ]] || exit 1
  [[ -z "$(side_effects_prompt_block "$LED_UNK" "$SPECS/l12b.md")" ]] || exit 1
  out="$(side_effects_prompt_block "$LED_DECL" "$SPECS/l3.md")"
  [[ "$out" == "SIDE-EFFECT CONTEXT (deterministic, engine-built): spec Side-effect policy: allowed; MUTATING: J-04 (declared); NONE: J-02; Unknown: J-01."$'\n'* ]] || exit 1
  printf '%s' "$out" | grep -qF 'Execute every numbered step EXACTLY as written even when it creates or changes data.' || exit 1
  printf '%s' "$out" | grep -qF 'In each row'"'"'s Actual cell name any create/update/delete you performed or write "no data changed".' || exit 1
  [[ "$out" != *"full-depth run"* ]] || exit 1
  full="$(side_effects_prompt_block "$LED_DECL" "$SPECS/l3.md" full)"
  [[ "$full" == "$out (In this full-depth run, a numbered step also means a numbered step of a UT- test case you were asked to execute.)" ]] || exit 1
) && assert "R5: side_effects_prompt_block renders the plan's block only when context applies (empty otherwise); 'full' adds the UT- note" "pass" \
  || assert "R5: side_effects_prompt_block" "fail"

# ── Part E: the REAL run-goal.sh engine ──────────────────────────────────────
echo "== E. real engine (sandbox, stub claude)"
ESBX="$WORK/eproj"; mkdir -p "$ESBX"
cp -r "$ENGINE_ROOT/scripts" "$ESBX/"
mkdir -p "$ESBX/docs/phases" "$ESBX/reports" "$ESBX/src" "$ESBX/.claude/agents"
touch "$ESBX/.claude/agents/developer.md"
git init -q "$ESBX"
echo "print('v1')" > "$ESBX/src/app.py"
cat > "$ESBX/docs/goal.md" <<'EOF'
# Goal

A tiny backtest console.

## Must-have user journeys

- **J-01: Open the page**
  - Steps:
    1. Visit `/`
  - Acceptance: the page loads

- **J-02: Inspect a policy**
  - Steps:
    1. Visit `/policy`, press Evaluate
  - Acceptance: the facts panel renders
  - Side effects: none — evaluating persists nothing

- **J-04: Replay a small portfolio**
  - Steps:
    1. Open Backtests → Portfolio run; keep all six playbooks checked; set top symbols to
       5, start 2015-01-01, end 2015-06-30, walk-forward (never the form's default
       universe or date span); click Run; wait for completion, which takes under 60 s
    2. Land on Run detail
  - Acceptance: the new ledger row carries the new engine stamp
  - Side effects: mutating — step 1 launches a portfolio run and appends a ledger row

## Anti-goals

- no paid SaaS
EOF
git -C "$ESBX" add -A
git -C "$ESBX" -c user.email=t@t -c user.name=t commit -qm base
ETMP="$WORK/etmp"; mkdir -p "$ETMP"
ESTUB="$WORK/ebin"; mkdir -p "$ESTUB"
export OOS9 TC9 OOSFIX TCFIX
cat > "$ESTUB/claude" <<'EOF2'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "stub 0.0"; exit 0; }
agent="${CHAIN_CURRENT_AGENT:-unknown}"
echo "$agent" >> "$CANARY"
[[ "$agent" == "goal-decomposer" ]] || exit 70
iter="$(printf '%s\n' "$*" | sed -n 's/^Iter name: //p' | head -1)"
[[ -n "$iter" ]] || exit 64
n=$(grep -c '^goal-decomposer$' "$CANARY")
printf '%s\n' "$*" > "$CANARY.prompt-$n"
kind="$STUB_SPEC_KIND"
[[ "$n" -ge 2 && -n "${STUB_SPEC_KIND_2:-}" ]] && kind="$STUB_SPEC_KIND_2"
pol="" tj="J-01, J-02, J-04" rq="same as Target journeys"
oos='- Any code change to the engine'
tc='- TC-1: given the page, when opened, then it renders'
case "$kind" in
  iter9-none)    pol="none";    oos="$OOS9"; tc="$TC9" ;;
  iter9-allowed) pol="allowed"; oos="$OOS9"; tc="$TC9" ;;
  iter9-absent)  pol="";        oos="$OOS9"; tc="$TC9" ;;
  fixed)         pol="allowed"; oos="$OOSFIX"; tc="$TCFIX" ;;
  nonenone)      pol="none";    tj="J-02"; rq="none" ;;
  noneunknown)   pol="none";    tj="J-01"; rq="none" ;;
  allowedplain)  pol="allowed" ;;
esac
{
  echo "# Goal Iteration 0 — $kind"; echo
  echo "## Goal Mode Metadata"; echo
  echo "- **Session ID:** s"; echo "- **Iteration:** 0"; echo "- **Mode:** baseline"
  echo "- **Depth:** lean"
  echo "- **Target journeys:** $tj"
  echo "- **Required-still-passing journeys:** $rq"
  echo "- **Work kind:** verify-only"
  [[ -n "$pol" ]] && echo "- **Side-effect policy:** $pol"
  echo; echo "## GOAL"; echo; echo "Confirm; no code change, no new run."
  echo; echo "## IN SCOPE"; echo; echo "### Backend"; echo "- (none — no backend file is edited)"
  echo "### Frontend"; echo "- (none)"
  echo; echo "## OUT OF SCOPE"; echo; printf '%s\n' "$oos"
  echo; echo "## DEFINITION OF DONE"; echo; echo "- [ ] every target journey verified"
  echo; echo "## TESTING REQUIREMENTS"; echo; printf '%s\n' "$tc"
} > "docs/phases/${iter}.md"
exit 0
EOF2
chmod +x "$ESTUB/claude"
E_N=0
e_invoke() {  # e_invoke <sid> <kind> <extra-args-string> [env=val ...]
  local sid="$1" kind="$2" extra="$3"; shift 3
  E_LOG="$WORK/e-$sid-$(date +%s%N).log"
  CANARY="$WORK/ecanary-$sid-$(date +%s%N).log"; : > "$CANARY"; export CANARY
  E_SESSION="$ESBX/runs/goal-session-$sid"
  E_RC=0
  # shellcheck disable=SC2086  # $extra is a deliberate word list (--resume)
  ( cd "$ESBX" && env "PATH=$ESTUB:$PATH" CANARY="$CANARY" STUB_SPEC_KIND="$kind" \
      CHAIN_DOCTOR=false CHAIN_GOAL_LINT=false CHAIN_SESSION_RETRO=false \
      CHAIN_TMP_ROOT="$ETMP" CHAIN_TMP_LEGACY_ROOTS="" \
      CHAIN_BACKEND_PORT=48853 CHAIN_FRONTEND_PORT=48854 CHAIN_SKIP_GITHUB_PREFLIGHT=true \
      "$@" timeout 240 bash scripts/automation/run-goal.sh --session-id "$sid" --max-iter 1 \
        --no-push-per-iter $extra \
  ) > "$E_LOG" 2>&1 || E_RC=$?
}
e_run() {  # e_run <kind> [env=val ...]  (fresh session; E_PRESEED_SIDECAR seeds the sidecar)
  E_N=$((E_N+1)); E_SID="se$E_N"
  rm -rf "$ESBX/runs/goal-session-$E_SID" "$ESBX/docs/phases"/*.md
  if [[ -n "${E_PRESEED_SIDECAR:-}" ]]; then
    mkdir -p "$ESBX/runs/goal-session-$E_SID/state"
    printf '%s' "$E_PRESEED_SIDECAR" > "$ESBX/runs/goal-session-$E_SID/state/journey-side-effects.json"
  fi
  # A directory where the ledger file belongs: the build can neither remove it
  # nor write the ledger (goal_gate.py exits 2) — a wholly unavailable ledger.
  [[ -n "${E_PRESEED_LEDGER_DIR:-}" ]] && mkdir -p "$ESBX/runs/goal-session-$E_SID/iter-0/side-effects.json/x"
  local kind="$1"; shift
  e_invoke "$E_SID" "$kind" "" "$@"
}
e_status() { python3 -c "import json; print(json.load(open('$E_SESSION/session.json')).get('status','?'))" 2>/dev/null || echo '?'; }
e_count() { local n; n="$(grep -c "^$1\$" "$CANARY" 2>/dev/null)"; echo "${n:-0}"; }
e_event() { grep -q "\"event\": *\"$1\"" "$E_SESSION/telemetry.jsonl" 2>/dev/null; }
e_halt() { grep -q "\"reason\": *\"$1\"" "$E_SESSION/telemetry.jsonl" 2>/dev/null && grep -q "\"detected_at_step\": *\"$2\"" "$E_SESSION/telemetry.jsonl" 2>/dev/null; }

# E1 — the TenSteps iteration-9 contradiction, re-planned into the corrected spec.
e_run iter9-allowed STUB_SPEC_KIND_2=fixed
[[ "$(e_count goal-decomposer)" == "2" && "$(e_count developer)" -ge 1 && "$(e_status)" != "GATE_BLOCKED" ]] \
  && assert "E1: iter-9 prohibitions vs mutating J-04 (policy allowed) -> ONE re-plan -> the corrected spec dispatches" "pass" \
  || assert "E1: re-plan rescues (decomp=$(e_count goal-decomposer) dev=$(e_count developer) status=$(e_status))" "fail"
grep -q 'SPEC LINT ERRORS' "$CANARY.prompt-2" 2>/dev/null && grep -q 'ERROR E16' "$CANARY.prompt-2" \
  && grep -q "J-04" "$CANARY.prompt-2" && grep -q 'click Run' "$CANARY.prompt-2" \
  && assert "E1b: the re-plan prompt quotes E16 naming J-04 and its 'click Run' step" "pass" \
  || assert "E1b: re-plan prompt carries E16" "fail"
e_event spec_replan \
  && assert "E1c: spec_replan recorded" "pass" || assert "E1c: spec_replan recorded" "fail"
python3 - "$E_SESSION/telemetry.jsonl" <<'PY' && assert "E1d: spec_lint events carry side_effect_policy, side_effect_rules and prohibitions (attempt 1 E16, attempt 2 clean)" "pass" || assert "E1d: spec_lint side-effect fields" "fail"
import json, sys
evs = []
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("event") == "spec_lint":
        evs.append(e)
assert len(evs) == 2, evs
a1, a2 = evs
assert a1["attempt"] == 1 and a1["side_effect_policy"] == "allowed" and "E16" in a1["side_effect_rules"], a1
assert a1["prohibitions"] == 2, a1
assert a2["attempt"] == 2 and a2["rc"] == 0 and a2["prohibitions"] == 0 and "E16" not in a2["side_effect_rules"], a2
PY
python3 - "$E_SESSION/iter-0/side-effects.json" <<'PY' && assert "E1e: iter-0/side-effects.json is the engine's preflight ledger (J-04 mutating, digest present)" "pass" || assert "E1e: preflight ledger" "fail"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["built_at_step"] == "preflight" and d["iter"] == 0 and d["complete"] is True, d
assert d["journeys"]["J-04"]["status"] == "mutating" and d["journeys"]["J-02"]["status"] == "none"
assert len(d["declaration_digest"]) == 64
PY
_l=$(grep -n 'Side-effect ledger (preflight)' "$E_LOG" | head -1 | cut -d: -f1)
_d=$(grep -n 'Step 1: goal-decomposer' "$E_LOG" | head -1 | cut -d: -f1)
_s=$(grep -n 'Spec lint REJECTED' "$E_LOG" | head -1 | cut -d: -f1)
_x=$(grep -n 'Dispatching LEAN pipeline' "$E_LOG" | head -1 | cut -d: -f1)
[[ -n "$_l" && -n "$_d" && -n "$_s" && -n "$_x" && "$_l" -lt "$_d" && "$_d" -lt "$_s" && "$_s" -lt "$_x" ]] \
  && assert "E1f: runtime order is ledger build < decomposer < lint (re-plan) < executor dispatch" "pass" \
  || assert "E1f: runtime order (ledger=$_l decomposer=$_d lint=$_s dispatch=$_x)" "fail"
[[ -s "$E_SESSION/state/journey-side-effects.json" ]] && python3 -c "import json,sys; d=json.load(open('$E_SESSION/state/journey-side-effects.json')); sys.exit(0 if d['declaration_digest'] and d['declarations']['J-04']['declared']=='mutating' else 1)" \
  && assert "E1g: the engine-owned sidecar records the declaration digest and declarations" "pass" \
  || assert "E1g: sidecar bookkeeping" "fail"
python3 - "$E_SESSION/iter-0/spec-lint.json" <<'PY' && assert "E1h: the lint verified the ledger against this run's preflight build id (freshness check armed)" "pass" || assert "E1h: build id checked" "fail"
import json, sys
se = json.load(open(sys.argv[1]))["side_effects"]
assert se["availability"] == "ok" and isinstance(se["build_id"], str) and se["build_id"], se
PY

# E2 — the tripwire: the re-plan flips none -> allowed and keeps the prohibition.
e_run iter9-none STUB_SPEC_KIND_2=iter9-allowed
[[ "$(e_status)" == "GATE_BLOCKED" && "$(e_count developer)" == "0" && "$(e_count browser-qa-agent)" == "0" && "$(e_count goal-decomposer)" == "2" ]] \
  && assert "E2: a none->allowed re-plan with the prohibition unchanged is still blocked (GATE_BLOCKED, zero dispatch)" "pass" \
  || assert "E2: flip blocked (status=$(e_status) dev=$(e_count developer) decomp=$(e_count goal-decomposer))" "fail"
grep -q 'ERROR E13' "$CANARY.prompt-2" 2>/dev/null && grep -q 'ERROR E16' "$CANARY.prompt-2" \
  && grep -q '^\[spec-lint\] ERROR E16 ' "$E_SESSION/iter-0/spec-lint.txt" && ! grep -q '^\[spec-lint\] ERROR E13 ' "$E_SESSION/iter-0/spec-lint.txt" \
  && e_halt GATE_BLOCKED_SPEC_LINT spec-lint \
  && assert "E2b: attempt 1 hit E13+E16; attempt 2 (allowed) still E16 -> GATE_BLOCKED_SPEC_LINT" "pass" \
  || assert "E2b: flip diagnostics" "fail"

# E3 — E15 fails closed immediately: policy none + an unreadable ledger input.
E_PRESEED_SIDECAR='{ corrupt' e_run nonenone
[[ "$(e_status)" == "GATE_BLOCKED" && "$(e_count developer)" == "0" && "$(e_count browser-qa-agent)" == "0" ]] \
  && e_halt GATE_BLOCKED_SIDE_EFFECT_LEDGER side-effect-ledger \
  && assert "E3: policy none + an incomplete ledger -> GATE_BLOCKED_SIDE_EFFECT_LEDGER with ZERO executor dispatch" "pass" \
  || assert "E3: E15 fail-closed (status=$(e_status) dev=$(e_count developer))" "fail"
[[ "$(e_count goal-decomposer)" == "1" ]] && grep -q '^\[spec-lint\] ERROR E15 ' "$E_SESSION/iter-0/spec-lint.txt" \
  && assert "E3b: E15 is NOT re-planned (one decomposer dispatch) and is recorded in spec-lint.txt" "pass" \
  || assert "E3b: E15 not re-planned (decomp=$(e_count goal-decomposer))" "fail"
[[ "$(cat "$E_SESSION/state/journey-side-effects.json")" == "{ corrupt" ]] && e_event side_effect_ledger_unavailable \
  && grep -q 'goal_gate.py side-effects' "$E_LOG" \
  && assert "E3c: the corrupt sidecar is untouched, side_effect_ledger_unavailable is recorded and the remedy printed" "pass" \
  || assert "E3c: ledger-unavailable handling" "fail"
rm -f "$E_SESSION/state/journey-side-effects.json"
e_invoke "$E_SID" nonenone "--resume"
[[ "$(e_count goal-decomposer)" == "0" && "$(e_count developer)" -ge 1 && "$(e_status)" != "GATE_BLOCKED" ]] \
  && assert "E3d: after the input is fixed, --resume RE-CHECKS the same spec (no re-plan) and dispatches" "pass" \
  || assert "E3d: resume after E15 (decomp=$(e_count goal-decomposer) dev=$(e_count developer) status=$(e_status))" "fail"

# E4 — the same unavailable ledger under policy allowed is W11 only.
E_PRESEED_SIDECAR='{ corrupt' e_run allowedplain
[[ "$(e_status)" != "GATE_BLOCKED" && "$(e_count developer)" -ge 1 ]] \
  && grep -q '^\[spec-lint\] WARN W11 ' "$E_SESSION/iter-0/spec-lint.txt" && ! grep -q 'E15' "$E_SESSION/iter-0/spec-lint.txt" \
  && e_event side_effect_ledger_unavailable \
  && assert "E4: policy allowed + an incomplete ledger -> W11 + side_effect_ledger_unavailable; dispatch continues" "pass" \
  || assert "E4: W11 path (status=$(e_status) dev=$(e_count developer))" "fail"

# E5 — warn mode surfaces E16 without blocking.
e_run iter9-allowed CHAIN_SPEC_LINT=warn
[[ "$(e_count developer)" -ge 1 && "$(e_count goal-decomposer)" == "1" ]] && grep -q 'dispatching anyway' "$E_LOG" \
  && assert "E5: CHAIN_SPEC_LINT=warn logs E16 loudly and dispatches without a re-plan" "pass" \
  || assert "E5: warn mode (dev=$(e_count developer))" "fail"

# E5b — ... but warn mode never relaxes E15's fail-closed check.
E_PRESEED_SIDECAR='{ corrupt' e_run nonenone CHAIN_SPEC_LINT=warn
[[ "$(e_status)" == "GATE_BLOCKED" && "$(e_count developer)" == "0" && "$(e_count browser-qa-agent)" == "0" ]] \
  && e_halt GATE_BLOCKED_SIDE_EFFECT_LEDGER side-effect-ledger && grep -q '"lint_mode": *"warn"' "$E_SESSION/telemetry.jsonl" \
  && grep -q 'CHAIN_SPEC_LINT=warn does not relax this' "$E_LOG" \
  && assert "E5b: CHAIN_SPEC_LINT=warn + E15 still halts GATE_BLOCKED_SIDE_EFFECT_LEDGER with zero dispatch" "pass" \
  || assert "E5b: warn never relaxes E15 (status=$(e_status) dev=$(e_count developer))" "fail"

# E5c — CHAIN_SPEC_LINT=off is an announced kill switch for the whole lint.
E_PRESEED_SIDECAR='{ corrupt' e_run nonenone CHAIN_SPEC_LINT=off
[[ "$(e_count developer)" -ge 1 ]] && grep -q 'CHAIN_SPEC_LINT=off: the spec lint does not run, so the HARD-3 side-effect preflight' "$E_LOG" \
  && assert "E5c: CHAIN_SPEC_LINT=off skips the preflight too, and says so" "pass" \
  || assert "E5c: lint off (dev=$(e_count developer))" "fail"

# E5d/E5e — the lint dies before its side-effect pass: the engine decides E15
# itself (fail closed), in warn mode too; with a usable ledger warn continues.
CRASH_PY="$WORK/crashlint"; mkdir -p "$CRASH_PY"
cat > "$CRASH_PY/sitecustomize.py" <<'PYEOF'
import os, sys
if os.environ.get("STUB_LINT_CRASH") and sys.argv[:1] and sys.argv[0].endswith("iter_spec.py") \
        and sys.argv[1:2] == ["lint"]:
    sys.stderr.write("stub: the linter crashed before its side-effect pass\n")
    sys.stderr.flush()
    os._exit(int(os.environ.get("STUB_LINT_CRASH_RC", "2")))
PYEOF
E_PRESEED_SIDECAR='{ corrupt' e_run nonenone CHAIN_SPEC_LINT=warn STUB_LINT_CRASH=1 PYTHONPATH="$CRASH_PY"
[[ "$(e_status)" == "GATE_BLOCKED" && "$(e_count developer)" == "0" ]] \
  && e_halt GATE_BLOCKED_SIDE_EFFECT_LEDGER side-effect-ledger && grep -q '"lint_rc": *2' "$E_SESSION/telemetry.jsonl" \
  && grep -q 'the spec lint did not finish (exit 2)' "$E_LOG" && e_event spec_lint_crash \
  && assert "E5d: warn mode + a linter that died before its side-effect pass + policy none + an unusable ledger -> GATE_BLOCKED, zero dispatch" "pass" \
  || assert "E5d: lint crash fallback (status=$(e_status) dev=$(e_count developer))" "fail"
E_PRESEED_SIDECAR='{ corrupt' e_run nonenone CHAIN_SPEC_LINT=warn STUB_LINT_CRASH=1 STUB_LINT_CRASH_RC=1 PYTHONPATH="$CRASH_PY"
[[ "$(e_status)" == "GATE_BLOCKED" && "$(e_count developer)" == "0" ]] \
  && e_halt GATE_BLOCKED_SIDE_EFFECT_LEDGER side-effect-ledger && grep -q 'the spec lint did not finish (exit 1)' "$E_LOG" \
  && e_event spec_lint_crash \
  && assert "E5d2: the same with a traceback-style exit 1 (no findings, no JSON) -> GATE_BLOCKED, zero dispatch, spec_lint_crash recorded" "pass" \
  || assert "E5d2: rc-1 crash fallback (status=$(e_status) dev=$(e_count developer))" "fail"
e_run nonenone CHAIN_SPEC_LINT=warn STUB_LINT_CRASH=1 PYTHONPATH="$CRASH_PY"
[[ "$(e_status)" != "GATE_BLOCKED" && "$(e_count developer)" -ge 1 ]] && grep -q 'continuing UNVERIFIED' "$E_LOG" \
  && assert "E5e: the same crash with a usable ledger keeps HARD-2's warn behaviour (continues UNVERIFIED)" "pass" \
  || assert "E5e: crash with a usable ledger (status=$(e_status) dev=$(e_count developer))" "fail"

# E6 — CHAIN_SIDE_EFFECT_PREFLIGHT=false disables only the ledger rules.
e_run iter9-allowed CHAIN_SIDE_EFFECT_PREFLIGHT=false
[[ "$(e_count developer)" -ge 1 ]] && ! grep -q 'E16' "$E_SESSION/iter-0/spec-lint.txt" \
  && grep -q 'CHAIN_SIDE_EFFECT_PREFLIGHT=false' "$E_LOG" \
  && assert "E6: CHAIN_SIDE_EFFECT_PREFLIGHT=false (the rollback) skips E13-E16 and says so" "pass" \
  || assert "E6: preflight rollback (dev=$(e_count developer))" "fail"

# E7 — a typo never disables the preflight.
e_run iter9-allowed CHAIN_SIDE_EFFECT_PREFLIGHT=flase
[[ "$(e_status)" == "GATE_BLOCKED" && "$(e_count developer)" == "0" ]] && grep -q "CHAIN_SIDE_EFFECT_PREFLIGHT='flase'" "$E_LOG" \
  && assert "E7: an unrecognised CHAIN_SIDE_EFFECT_PREFLIGHT value keeps the preflight ON (fail closed) and says so" "pass" \
  || assert "E7: knob typo (status=$(e_status))" "fail"

# E8/E9 — unknown journeys: warning by default (with telemetry), error in strict mode.
e_run noneunknown
[[ "$(e_count developer)" -ge 1 ]] && grep -q '^\[spec-lint\] WARN W09 ' "$E_SESSION/iter-0/spec-lint.txt" \
  && grep -q '"event": *"side_effect_unknown"' "$E_SESSION/telemetry.jsonl" && grep -q '"journeys": *\["J-01"\]' "$E_SESSION/telemetry.jsonl" \
  && assert "E8: policy none + an unknown J-01 -> W09, dispatch continues, side_effect_unknown recorded" "pass" \
  || assert "E8: W09 path (dev=$(e_count developer))" "fail"
e_run noneunknown CHAIN_SIDE_EFFECT_STRICT=true
[[ "$(e_status)" == "GATE_BLOCKED" && "$(e_count developer)" == "0" && "$(e_count goal-decomposer)" == "2" ]] \
  && grep -q '^\[spec-lint\] ERROR E14 ' "$E_SESSION/iter-0/spec-lint.txt" \
  && assert "E9: CHAIN_SIDE_EFFECT_STRICT=true turns it into E14 (one re-plan, then GATE_BLOCKED)" "pass" \
  || assert "E9: strict (status=$(e_status) decomp=$(e_count goal-decomposer))" "fail"

# E10 — an owner edit flips J-04's declaration between runs: provenance-visible.
e_run allowedplain
cp "$ESBX/docs/goal.md" "$WORK/goal.md.orig"
sed -i 's/  - Side effects: mutating — step 1 launches/  - Side effects: none — step 1 launches/' "$ESBX/docs/goal.md"
e_invoke "$E_SID" allowedplain "--resume"
cp "$WORK/goal.md.orig" "$ESBX/docs/goal.md"
python3 - "$E_SESSION/telemetry.jsonl" "$E_SESSION/state/journey-side-effects.json" <<'PY' && assert "E10: a mutating->none edit emits side_effect_declaration_changed and moves declaration_digest_prev" "pass" || assert "E10: declaration change provenance" "fail"
import json, sys
ch = []
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("event") == "side_effect_declaration_changed":
        ch.append(e)
assert any(c.get("journey") == "J-04" and c.get("from") == "mutating" and c.get("to") == "none" and c.get("iter") == 0
           for c in ch), ch
s = json.load(open(sys.argv[2]))
assert s["declaration_digest_prev"] and s["declaration_digest_prev"] != s["declaration_digest"], s
PY

# E12 — a wholly UNAVAILABLE ledger (the build could not write it at all).
E_PRESEED_LEDGER_DIR=1 e_run nonenone
[[ "$(e_status)" == "GATE_BLOCKED" && "$(e_count developer)" == "0" ]] \
  && e_halt GATE_BLOCKED_SIDE_EFFECT_LEDGER side-effect-ledger \
  && grep -q '^\[spec-lint\] ERROR E15 ' "$E_SESSION/iter-0/spec-lint.txt" && grep -q 'Side-effect ledger (preflight) UNAVAILABLE' "$E_LOG" \
  && assert "E12: policy none + a ledger the build could not write (goal_gate rc 2) -> GATE_BLOCKED, zero dispatch" "pass" \
  || assert "E12: unavailable ledger under none (status=$(e_status) dev=$(e_count developer))" "fail"
E_PRESEED_LEDGER_DIR=1 e_run allowedplain
[[ "$(e_status)" != "GATE_BLOCKED" && "$(e_count developer)" -ge 1 ]] \
  && grep -q '^\[spec-lint\] WARN W11 ' "$E_SESSION/iter-0/spec-lint.txt" \
  && assert "E12b: the same unavailable ledger under policy allowed -> W11 only, dispatch continues" "pass" \
  || assert "E12b: unavailable ledger under allowed (status=$(e_status) dev=$(e_count developer))" "fail"

# E13r — a resumed iteration is re-linted against the evidence it was planned
# against, not against its own replay's observations.
e_run noneunknown
python3 - "$E_SESSION/iter-0" <<'PY'
import json, os, sys
d = sys.argv[1]
t = "2026-09-17T05:00:00.000000Z"
obs = {"run_id": "goal-se-iter-0:1", "iter": 0, "iter_name": "goal-x-iter-0", "observed_at": t,
       "golden_sha256": "e" * 64, "complete": True, "verdict": "PASS", "mutating_count": 1, "auth_count": 0,
       "readonly_count": 0, "truncated": False, "exceptions_applied": [], "auth_ignored": [],
       "requests": [{"method": "POST", "path": "/api/pages", "class": "mutating", "count": 1}],
       "classifier_version": 2, "readonly_endpoints_sha256": None, "readonly_endpoints_error": None,
       "ignore_paths": ["/login", "/logout", "/auth", "/session", "/token", "/csrf"]}
json.dump({"run_id": obs["run_id"], "iter": 0, "observed_at": t, "journeys": {"J-01": obs},
           "sidecar": {"path": "x", "updated": False, "message": "pending"}},
          open(os.path.join(d, "replay-side-effects.json"), "w"))
PY
e_invoke "$E_SID" noneunknown "--resume"
[[ "$(e_count goal-decomposer)" == "0" && "$(e_count developer)" -ge 1 && "$(e_status)" != "GATE_BLOCKED" ]] \
  && ! grep -q '^\[spec-lint\] ERROR E13 ' "$E_SESSION/iter-0/spec-lint.txt" \
  && python3 -c "import json,sys; d=json.load(open('$E_SESSION/iter-0/side-effects.json')); sys.exit(0 if d.get('frozen') and d['journeys']['J-01']['status']=='unknown' else 1)" \
  && assert "E13r: resuming after the iteration's own replay observed a write re-lints against the FROZEN preflight view (no re-plan, no block)" "pass" \
  || assert "E13r: resume stability (decomp=$(e_count goal-decomposer) dev=$(e_count developer) status=$(e_status))" "fail"

# E13s — a resume that RE-RUNS the decomposer (no step checkpoints) plans and
# lints against the current evidence, never the frozen view.
e_run noneunknown
python3 - "$E_SESSION/iter-0" <<'PY'
import json, os, sys
d = sys.argv[1]
t = "2026-09-17T06:00:00.000000Z"
obs = {"run_id": "goal-se-iter-0:2", "iter": 0, "iter_name": "goal-x-iter-0", "observed_at": t,
       "golden_sha256": "f" * 64, "complete": True, "verdict": "PASS", "mutating_count": 1, "auth_count": 0,
       "readonly_count": 0, "truncated": False, "exceptions_applied": [], "auth_ignored": [],
       "requests": [{"method": "POST", "path": "/api/pages", "class": "mutating", "count": 1}],
       "classifier_version": 2, "readonly_endpoints_sha256": None, "readonly_endpoints_error": None,
       "ignore_paths": ["/login", "/logout", "/auth", "/session", "/token", "/csrf"]}
json.dump({"run_id": obs["run_id"], "iter": 0, "observed_at": t, "journeys": {"J-01": obs},
           "sidecar": {"path": "x", "updated": False, "message": "pending"}},
          open(os.path.join(d, "replay-side-effects.json"), "w"))
PY
e_invoke "$E_SID" noneunknown "--resume" CHAIN_STEP_CHECKPOINTS=false
grep -q '^\[spec-lint\] ERROR E13 ' "$E_SESSION/iter-0/spec-lint.txt" \
  && python3 -c "import json,sys; d=json.load(open('$E_SESSION/iter-0/side-effects.json')); sys.exit(1 if d.get('frozen') else 0)" \
  && [[ "$(e_count developer)" == "0" ]] \
  && assert "E13s: without step checkpoints a resume re-plans against the CURRENT evidence (E13 for the observed write, nothing dispatched)" "pass" \
  || assert "E13s: checkpoint-less resume (dev=$(e_count developer) status=$(e_status))" "fail"

# E13t — a frozen resume whose spec is rejected re-plans against the current evidence.
e_run iter9-none STUB_SPEC_KIND_2=iter9-allowed
python3 - "$E_SESSION/iter-0" <<'PY'
import json, os, sys
d = sys.argv[1]
t = "2026-09-17T07:00:00.000000Z"
obs = {"run_id": "goal-se-iter-0:3", "iter": 0, "iter_name": "goal-x-iter-0", "observed_at": t,
       "golden_sha256": "c" * 64, "complete": True, "verdict": "PASS", "mutating_count": 1, "auth_count": 0,
       "readonly_count": 0, "truncated": False, "exceptions_applied": [], "auth_ignored": [],
       "requests": [{"method": "POST", "path": "/api/policy/save", "class": "mutating", "count": 1}],
       "classifier_version": 2, "readonly_endpoints_sha256": None, "readonly_endpoints_error": None,
       "ignore_paths": ["/login", "/logout", "/auth", "/session", "/token", "/csrf"]}
json.dump({"run_id": obs["run_id"], "iter": 0, "observed_at": t, "journeys": {"J-02": obs},
           "sidecar": {"path": "x", "updated": False, "message": "pending"}},
          open(os.path.join(d, "replay-side-effects.json"), "w"))
PY
e_invoke "$E_SID" iter9-allowed "--resume"
grep -q 'Re-planning a resumed iteration' "$E_LOG" && grep -q 'J-02 (DECLARED NONE, but observed' "$CANARY.prompt-1" 2>/dev/null \
  && assert "E13t: re-planning a resumed iteration rebuilds the ledger — the rewrite sees the write its own replay observed" "pass" \
  || assert "E13t: re-plan after a frozen resume ($(grep -c 'Re-planning a resumed' "$E_LOG" || true))" "fail"

# E11 — an ABSENT policy line does not disarm E16 either.
e_run iter9-absent STUB_SPEC_KIND_2=fixed
grep -q 'ERROR E16' "$CANARY.prompt-2" 2>/dev/null && grep -q 'WARN W02' "$CANARY.prompt-2" \
  && [[ "$(e_count developer)" -ge 1 ]] \
  && assert "E11: with NO policy line the iter-9 prohibitions still hit E16 (and W02), then the fix dispatches" "pass" \
  || assert "E11: absent-policy E16 (dev=$(e_count developer))" "fail"

# ── Part P: prompts + observer through the REAL lean executor ────────────────
echo "== P. lean end-to-end: replay observation -> next-iteration E13 -> prompts"
# Free ports per run: two suites running at once must never share (or kill) each other's servers.
read -r P_BE P_FE < <(python3 -c 'import socket
socks = [socket.socket() for _ in range(2)]
for s in socks:
    s.bind(("127.0.0.1", 0))
print(*[s.getsockname()[1] for s in socks])')
SRV_DIR="$WORK/srv"; mkdir -p "$SRV_DIR"
for _p in "$P_BE" "$P_FE"; do
  ( cd "$SRV_DIR" && exec python3 -m http.server "$_p" ) >/dev/null 2>&1 &
  DUMMY_PIDS+=("$!")
done
for _p in "$P_BE" "$P_FE"; do
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://localhost:${_p}/" && break; sleep 0.1; done
done
mk_psbx() {  # mk_psbx <dir> <goal-variant: declared|legacy>
  local d="$1"
  mkdir -p "$d"
  cp -r "$ENGINE_ROOT/scripts" "$d/"
  mkdir -p "$d/docs/phases" "$d/docs/handoffs" "$d/reports/reviews" "$d/src" "$d/.claude/agents"
  touch "$d/.claude/agents/developer.md"
  git init -q "$d"
  echo "print('v1')" > "$d/src/app.py"
  {
    printf '# Goal\n\nA tiny backtest console.\n\n## Must-have user journeys\n\n'
    printf -- '- **J-01: Open the page**\n  - Steps:\n    1. Visit `/`\n  - Acceptance: the page loads\n\n'
    printf -- '- **J-04: Replay a portfolio**\n  - Steps:\n    1. Open Backtests; click Run\n  - Acceptance: the Engine header shows\n'
    [[ "$2" == "declared" ]] && printf -- '  - Side effects: none — (deliberately wrong: the replay will observe a POST)\n'
    printf '\n## Anti-goals\n\n- no paid SaaS\n'
  } > "$d/docs/goal.md"
  git -C "$d" add -A
  git -C "$d" -c user.email=t@t -c user.name=t commit -qm base
}
PSBX="$WORK/pproj"; mk_psbx "$PSBX" declared
P_SID="pe"
mkdir -p "$PSBX/runs/goal-session-$P_SID/journey-scripts"
printf '%s\n' '{"schema_version": 1, "journey": "J-04", "name": "Replay a portfolio", "default_timeout_ms": 2000, "steps": [{"n": 1, "journey": "J-04", "action": {"type": "goto", "url": "/backtests/new"}}, {"n": 2, "journey": "J-04", "action": {"type": "click", "target": {"role": "button", "name": "Run"}}, "expect": {"text": "Engine"}}]}' \
  > "$PSBX/runs/goal-session-$P_SID/journey-scripts/J-04.json"
printf '%s\n' '{"requests": {"click:Run": [["POST", "fetch", "/api/runs"]]}}' > "$WORK/p-plan.json"
PSTUB="$WORK/pbin"; mkdir -p "$PSTUB"
P_PROMPTS="$WORK/pprompts"; mkdir -p "$P_PROMPTS"
cat > "$PSTUB/claude" <<'EOF3'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "stub 0.0"; exit 0; }
agent="${CHAIN_CURRENT_AGENT:-unknown}"
prompt="$*"
echo "$agent" >> "$CANARY"
n="$(grep -c "^${agent}\$" "$CANARY")"
printf '%s\n' "$prompt" > "$P_PROMPTS/${agent}-${n}.txt"
case "$agent" in
  goal-decomposer)
    out="$(printf '%s\n' "$prompt" | sed -n 's/^Write the iteration spec to: //p' | head -n1)"
    [[ -n "$out" ]] || exit 64
    # iteration 1 plans real work, so HARD-1's evidence backstop keeps it lean
    # and the scripted developer pause (exit 70) ends the run there.
    case "$n" in
      1) mode=baseline; it=0; pol="${P_POL0-allowed}"; wk=verify-only; be='- (none)' ;;
      2) mode=next; it=1; pol=none; wk=implementation; be='- [ ] add the run badge to the run list' ;;
      *) mode=next; it=1; pol=allowed; wk=implementation; be='- [ ] add the run badge to the run list' ;;
    esac
    {
      printf '# Goal Iteration %s\n\n## Goal Mode Metadata\n\n' "$it"
      printf -- '- **Mode:** %s\n- **Depth:** lean\n- **Target journeys:** J-01\n' "$mode"
      printf -- '- **Required-still-passing journeys:** J-04\n- **Work kind:** %s\n' "$wk"
      [[ -n "$pol" ]] && printf -- '- **Side-effect policy:** %s\n' "$pol"
      printf '\n## IN SCOPE\n\n### Backend\n%s\n### Frontend\n- (none)\n' "$be"
      printf '\n## OUT OF SCOPE\n\n- Any code change\n\n## DEFINITION OF DONE\n\n- [ ] journeys verified\n'
      printf '\n## TESTING REQUIREMENTS\n\n- TC-1: given the page, when opened, then it renders\n'
    } > "$out"
    exit 0 ;;
  developer)
    [[ "$n" -ge 2 ]] && exit 70
    out="$(printf '%s\n' "$prompt" | sed -n 's/^- Write dev handoff to: //p' | head -n1)"
    printf 'handoff: verify-only (stub)\n' > "$out"; exit 0 ;;
  reviewer)
    out="$(printf '%s\n' "$prompt" | sed -n 's/^Write your review report to: //p' | head -n1)"
    printf '**Verdict:** PASS\n\nStub review.\n' > "$out"; exit 0 ;;
  browser-qa-agent)
    out="$(printf '%s\n' "$prompt" | sed -n 's/^Write your results to: //p' | head -n1)"
    {
      printf '**Browser QA Verdict:** PASS\n\n'
      printf '| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n'
      printf '|---|---|---|---|---|---|---|---|\n'
      printf '| UT-J-01 | open page | journey | P1 | loads | no data changed | PASS | none |\n'
    } > "$out"; exit 0 ;;
  goal-evaluator)
    ev="$(printf '%s\n' "$prompt" | sed -n 's/^Write your verdict to: //p' | head -n1)"
    jh="$(printf '%s\n' "$prompt" | sed -n 's/^  Journey history: \([^ ]*\)  <--.*/\1/p' | head -n1)"
    el="$(printf '%s\n' "$prompt" | sed -n 's/^  Evaluator log: \([^ ]*\)  <--.*/\1/p' | head -n1)"
    mkdir -p "$(dirname "$ev")" "$(dirname "$jh")"
    printf '**Verdict:** CONTINUE\n**Depth Recommendation For Next Iteration:** lean\n\n## Summary\n\nstub\n' > "$ev"
    printf '{"journeys":{"J-01":{"id":"J-01","name":"Open the page","status":"passing"},"J-04":{"id":"J-04","name":"Replay a portfolio","status":"passing"}},"anti_goal_violations":[],"updated_at":"2026-09-16T00:00:00Z"}\n' > "$jh"
    printf '## Iteration 0\n\n**Verdict:** CONTINUE\n' >> "$el"
    exit 0 ;;
esac
exit 0
EOF3
chmod +x "$PSTUB/claude"
p_run() {  # p_run <sandbox> <sid> <max-iter> [env=val ...]
  local d="$1" sid="$2" mi="$3"; shift 3
  CANARY="$WORK/pcanary-$sid.log"; : > "$CANARY"
  P_RC=0
  ( cd "$d" && env "PATH=$PSTUB:$PATH" CANARY="$CANARY" P_PROMPTS="$P_PROMPTS/$sid" \
      PYTHONPATH="$FAKEPW" FAKE_PW_PLAN="$WORK/p-plan.json" \
      CHAIN_DOCTOR=false CHAIN_GOAL_LINT=false CHAIN_SESSION_RETRO=false \
      CHAIN_TMP_ROOT="$WORK/ptmp" CHAIN_TMP_LEGACY_ROOTS="" \
      CHAIN_BACKEND_PORT="$P_BE" CHAIN_FRONTEND_PORT="$P_FE" CHAIN_SKIP_GITHUB_PREFLIGHT=true \
      CHAIN_KILL_GRACE_SECONDS=1 "$@" \
      timeout 400 bash scripts/automation/run-goal.sh --session-id "$sid" --max-iter "$mi" --no-push-per-iter \
  ) > "$WORK/p-$sid.log" 2>&1 || P_RC=$?
}
mkdir -p "$WORK/ptmp" "$P_PROMPTS/$P_SID" "$P_PROMPTS/legacy"
p_run "$PSBX" "$P_SID" 2
PS="$PSBX/runs/goal-session-$P_SID"
PP="$P_PROMPTS/$P_SID"
[[ "$P_RC" == "0" ]] && grep -q 'Interactive pump/dispatch unavailable during iteration 1' "$WORK/p-$P_SID.log" \
  && assert "P0: the engine completed iteration 0 and paused in iteration 1's executor (as scripted)" "pass" \
  || { assert "P0: engine flow (rc=$P_RC)" "fail"; sed -n '1,40p' "$WORK/p-$P_SID.log" | sed 's/^/      /'; }
grep -E '^\| UT-J-04 ' "$PSBX/reports/phase-goal-$P_SID-iter-0-ui-test-results.md" 2>/dev/null \
  | grep -qF '; side effects: 1 mutating request(s) (POST /api/runs) | PASS |' \
  && assert "P1: the iter-0 merged results carry the replay's observed mutation on UT-J-04" "pass" \
  || assert "P1: merged J-04 row ($(grep -E '^\| UT-J-04 ' "$PSBX/reports/phase-goal-$P_SID-iter-0-ui-test-results.md" 2>/dev/null))" "fail"
python3 - "$PS" <<'PY' && assert "P2: sidecar + run record + side_effect_observed telemetry after the real replay lane" "pass" || assert "P2: observation artifacts" "fail"
import json, sys, os
s = sys.argv[1]
side = json.load(open(os.path.join(s, "state", "journey-side-effects.json")))
l = side["journeys"]["J-04"]["latest"]
assert l["mutating_count"] == 1 and l["iter"] == 0 and l["complete"] is True, l
run = json.load(open(os.path.join(s, "iter-0", "replay-side-effects.json")))
assert run["journeys"]["J-04"]["mutating_count"] == 1 and run["sidecar"]["updated"] is True, run
obs = [json.loads(x) for x in open(os.path.join(s, "telemetry.jsonl")) if '"side_effect_observed"' in x]
assert any(o.get("journey") == "J-04" and o.get("mutating_count") == 1 for o in obs), obs
PY
BQA0="$PP/browser-qa-agent-1.txt"
grep -qxF 'SIDE-EFFECT CONTEXT (deterministic, engine-built): spec Side-effect policy: allowed; MUTATING: (none); NONE: J-04; Unknown: J-01.' "$BQA0" \
  && awk '/^  2\. Execute the steps with Chrome MCP/{getline nx; print nx; exit}' "$BQA0" | grep -q '^SIDE-EFFECT CONTEXT' \
  && assert "P3: the iter-0 LLM browser lane prompt carries the context block right after the two numbered instructions" "pass" \
  || assert "P3: lean lane block ($(grep -n 'SIDE-EFFECT' "$BQA0" 2>/dev/null | head -2))" "fail"
EV0="$PP/goal-evaluator-1.txt"
grep -qF "  Side-effect ledger (deterministic): $PS/iter-0/side-effects.json <-- policy: allowed; MUTATING: J-04 (DECLARED NONE, but observed POST /api/runs in iter-0); NONE: (none); Unknown: J-01; declaration digest " "$EV0" \
  && grep -qF "DECLARATION CONFLICT: J-04 is declared 'none' in docs/goal.md, yet the deterministic replay observed a mutation" "$EV0" \
  && grep -qF 'classify it as a spec/journey contradiction rather than a product regression' "$EV0" \
  && assert "P4: the evaluator prompt names the REFRESHED ledger (this iteration's observed POST), the declaration conflict and the scoring rule" "pass" \
  || assert "P4: evaluator ledger line ($(grep -n 'Side-effect ledger' "$EV0" 2>/dev/null | head -2))" "fail"
D1P="$PP/goal-decomposer-2.txt"
grep -qF 'Side-effect ledger (deterministic, engine-built): ' "$D1P" && grep -qF 'MUTATING: J-04 (DECLARED NONE, but observed POST /api/runs in iter-0)' "$D1P" \
  && grep -qF 'Side-effect rule (BINDING' "$D1P" && grep -qF -- '- **Side-effect policy:** none | allowed' "$D1P" \
  && assert "P5: the iter-1 decomposer prompt carries the ledger digest line, the rule and the new metadata field" "pass" \
  || assert "P5: decomposer prompt" "fail"
grep -q 'ERROR E13 ' "$PP/goal-decomposer-3.txt" 2>/dev/null && grep -q 'observed POST /api/runs in iter-0' "$PP/goal-decomposer-3.txt" \
  && [[ "$(grep -c '^developer$' "$CANARY")" == "2" ]] \
  && assert "P6: iter-1 'policy none' over the OBSERVED-mutating J-04 -> E13 -> one re-plan -> 'allowed' dispatches" "pass" \
  || assert "P6: iter-1 E13 re-plan (dev=$(grep -c '^developer$' "$CANARY"))" "fail"
python3 - "$PS/iter-1/side-effects.json" <<'PY' && assert "P7: iter-1's preflight ledger: J-04 mutating by observation although declared none" "pass" || assert "P7: iter-1 ledger" "fail"
import json, sys
j = json.load(open(sys.argv[1]))["journeys"]["J-04"]
assert j["status"] == "mutating" and j["declared"] == "none" and j["status_source"] == "observed", j
assert j["observed_iter"] == 0 and j["requests"][0]["path"] == "/api/runs", j
PY
grep -q '"event": *"side_effect_declaration_conflict"' "$PS/telemetry.jsonl" \
  && assert "P7c: the iter-1 preflight records the declared-none / observed-mutating conflict (side_effect_declaration_conflict)" "pass" \
  || assert "P7c: declaration conflict telemetry" "fail"
BQA1="$PP/browser-qa-agent-2.txt"
if [[ -f "$BQA1" ]]; then
  assert "P7b: (iteration 1 never reached its browser lane — the scripted developer pause comes first)" "fail"
else
  assert "P7b: iteration 1 paused before any browser dispatch (scripted developer pause)" "pass"
fi
# The legacy shape: no declarations, no policy line, no golden -> byte-identical prompts.
LSBX="$WORK/lproj"; mk_psbx "$LSBX" legacy
p_run "$LSBX" legacy 1 P_POL0=
BQAL="$P_PROMPTS/legacy/browser-qa-agent-1.txt"
EVL="$P_PROMPTS/legacy/goal-evaluator-1.txt"
_between="$(awk '/^  2\. Execute the steps with Chrome MCP/{f=1;n=0;next} /^Frontend URL:/{if(f)print n; f=0} f{n++; if($0!="")print "nonblank"}' "$BQAL" 2>/dev/null | tr '\n' ' ')"
[[ -f "$BQAL" && -f "$EVL" && "$_between" == "1 " ]] && ! grep -q 'SIDE-EFFECT' "$BQAL" && ! grep -q 'Side-effect ledger' "$EVL" \
  && assert "P8: no declaration + no policy -> lane and evaluator prompts carry NO side-effect text (byte-identical shape)" "pass" \
  || assert "P8: legacy prompts (between='$_between'; files: $(ls "$P_PROMPTS/legacy" 2>/dev/null | tr '\n' ' '))" "fail"
grep -qF 'Side-effect ledger (deterministic, engine-built): ' "$P_PROMPTS/legacy/goal-decomposer-1.txt" \
  && grep -qF 'Unknown: J-01, J-04' "$P_PROMPTS/legacy/goal-decomposer-1.txt" \
  && assert "P8b: the decomposer is still told that every journey is unknown (it chooses the policy)" "pass" \
  || assert "P8b: legacy decomposer ledger line" "fail"
grep -q '^\[spec-lint\] WARN W02 ' "$LSBX/runs/goal-session-legacy/iter-0/spec-lint.txt" 2>/dev/null \
  && ! grep -qE '^\[spec-lint\] (ERROR|WARN) (E1[3-6]|W09|W10|W11) ' "$LSBX/runs/goal-session-legacy/iter-0/spec-lint.txt" \
  && assert "P8c: a legacy spec only gains W02 — no side-effect contradiction is invented" "pass" \
  || assert "P8c: legacy spec lint" "fail"

# ── Part P2: the FULL-depth browser lane prompt (browser-qa-phase.sh) ────────
echo "== P2. full-depth browser lane prompt"
FSBX="$WORK/fproj"; FPHASE="goal-fp-iter-2"
mkdir -p "$FSBX"
cp -r "$ENGINE_ROOT/scripts" "$FSBX/"
mkdir -p "$FSBX/docs/phases" "$FSBX/reports" "$FSBX/runs/$FPHASE" "$FSBX/src"
git init -q "$FSBX"
cp "$ESBX/docs/goal.md" "$FSBX/docs/goal.md"
cat > "$FSBX/docs/phases/$FPHASE.md" <<'EOF'
# Full-depth spec
## Goal Mode Metadata
- **Mode:** next
- **Depth:** full
- **Target journeys:** J-04
- **Required-still-passing journeys:** J-01
- **Side-effect policy:** allowed
## IN SCOPE
- exercise browser-qa (wiring test)
EOF
printf '# Plan\nFrontend Present: yes\n' > "$FSBX/runs/$FPHASE/plan.md"
printf '# UI test plan\n| UT-01 | open the page | smoke | P1 |\n' > "$FSBX/reports/phase-$FPHASE-ui-test-plan.md"
printf '# Surface map\n- / (home)\n' > "$FSBX/reports/phase-$FPHASE-ui-surface-map.md"
git -C "$FSBX" add -A
git -C "$FSBX" -c user.email=t@t -c user.name=t commit -qm base
FSTUB="$WORK/fbin"; mkdir -p "$FSTUB"
cat > "$FSTUB/claude" <<'EOF4'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$PROMPT_OUT"
out="$(printf '%s\n' "$*" | sed -n 's/^Write your results to: //p' | head -n1)"
[[ -n "$out" ]] || exit 64
printf '**Browser QA Verdict:** PASS\n\n| Test ID | Name | Type | Priority | Expected | Actual | Verdict | Evidence |\n|---|---|---|---|---|---|---|---|\n| UT-01 | open | smoke | P1 | loads | ok | PASS | none |\n| UT-J-04 | t | journey | P1 | a | ok | PASS | none |\n| UT-J-01 | r | regression | P1 | a | ok | PASS | none |\n' > "$out"
exit 0
EOF4
chmod +x "$FSTUB/claude"
FLED="$WORK/f-ledger.json"
python3 "$GG" side-effects "$FSBX/docs/goal.md" --out "$FLED" >/dev/null 2>&1
f_run() {  # f_run <tag> [env...]
  local tag="$1"; shift
  F_RC=0
  ( cd "$FSBX" && env "PATH=$FSTUB:$PATH" PROMPT_OUT="$WORK/fprompt-$tag.txt" \
      CHAIN_BACKEND_PORT="$P_BE" CHAIN_FRONTEND_PORT="$P_FE" \
      CHAIN_BACKEND_HEALTH_URL="http://localhost:${P_BE}/" CHAIN_SHARED_SERVICES=true \
      CHAIN_REGRESSION_REPLAY=false CHAIN_GOLDEN_NUDGE=false "$@" bash scripts/automation/browser-qa-phase.sh "$FPHASE" \
  ) > "$WORK/f-$tag.log" 2>&1 || F_RC=$?
}
f_run with CHAIN_SIDE_EFFECTS_FILE="$FLED"
f_run without
python3 - "$WORK/fprompt-with.txt" "$WORK/fprompt-without.txt" <<'PY' && assert "P9: the full-depth goal-lanes note gains exactly the context block (the rest of the prompt is byte-identical)" "pass" || assert "P9: full lane prompt ($(head -c 300 "$WORK/f-with.log"))" "fail"
import sys
w = open(sys.argv[1]).read()
wo = open(sys.argv[2]).read()
start = w.index("\nSIDE-EFFECT CONTEXT (deterministic, engine-built): spec Side-effect policy: allowed; MUTATING: J-04 (declared); NONE: (none); Unknown: J-01.\n")
tail = 'write "no data changed". (In this full-depth run, a numbered step also means a numbered step of a UT- test case you were asked to execute.)'
end = w.index(tail, start) + len(tail)
assert "GOAL-MODE REGRESSION LANES" in w[:start], "the block belongs to the goal-lanes note"
assert w[:start] + w[end:] == wo, "only the block differs"
assert "SIDE-EFFECT" not in wo
PY
FPH="phase-9"
cp "$FSBX/docs/phases/$FPHASE.md" "$FSBX/docs/phases/$FPH.md"
mkdir -p "$FSBX/runs/$FPH"; cp "$FSBX/runs/$FPHASE/plan.md" "$FSBX/runs/$FPH/plan.md"
cp "$FSBX/reports/phase-$FPHASE-ui-test-plan.md" "$FSBX/reports/phase-$FPH-ui-test-plan.md"
( cd "$FSBX" && env "PATH=$FSTUB:$PATH" PROMPT_OUT="$WORK/fprompt-phase.txt" CHAIN_SIDE_EFFECTS_FILE="$FLED" \
    CHAIN_BACKEND_PORT="$P_BE" CHAIN_FRONTEND_PORT="$P_FE" CHAIN_BACKEND_HEALTH_URL="http://localhost:${P_BE}/" \
    CHAIN_SHARED_SERVICES=true bash scripts/automation/browser-qa-phase.sh "$FPH" ) > "$WORK/f-phase.log" 2>&1 || true
[[ -f "$WORK/fprompt-phase.txt" ]] && ! grep -q 'SIDE-EFFECT' "$WORK/fprompt-phase.txt" \
  && assert "P9b: plain phase mode never carries the block, even with CHAIN_SIDE_EFFECTS_FILE set" "pass" \
  || assert "P9b: phase mode untouched" "fail"

# ── Part W: wiring ───────────────────────────────────────────────────────────
echo "== W. wiring"
LEAN="$ENGINE_ROOT/scripts/automation/goal-iter-lean.sh"
FULLQA="$ENGINE_ROOT/scripts/automation/browser-qa-phase.sh"
RL="$LIB/replay-lane.sh"
_w1_missing=""
for pat in 'journey-side-effects.json' 'CHAIN_SIDE_EFFECT_PREFLIGHT' 'CHAIN_SIDE_EFFECT_STRICT' 'Side-effect ledger' \
           'GATE_BLOCKED_SIDE_EFFECT_LEDGER' 'side_effect_ledger_unavailable' 'side_effect_unknown' \
           'CHAIN_SIDE_EFFECTS_FILE' '--strict-side-effects' '--makeup-journeys' '--side-effects-build-id' \
           'side_effect_declaration_conflict' '--freeze' 'side-effects.preflight.json' 'policy-intent' 'ledger-ok'; do
  grep -qF -- "$pat" "$RG" || _w1_missing+="$pat "
done
[[ -z "$_w1_missing" ]] \
  && assert "W1: run-goal.sh carries the ledger path, both knobs, the halt reason and the lint flags" "pass" \
  || assert "W1: run-goal.sh wiring (missing: $_w1_missing)" "fail"
grep -q 'side_effects_prompt_block' "$LEAN" && grep -q 'side_effects_prompt_block' "$FULLQA" \
  && grep -q 'SIDE-EFFECT CONTEXT' "$LIB/iter_spec.py" && grep -q 'side_effects_prompt_block()' "$RL" \
  && assert "W2: both browser lanes render SIDE-EFFECT CONTEXT through the one helper in lib/replay-lane.sh" "pass" \
  || assert "W2: lane prompt wiring" "fail"
grep -q -- '--side-effects-out' "$RL" && grep -q 'CHAIN_SIDE_EFFECT_OBSERVER' "$RL" \
  && assert "W3: the replay lane passes --side-effects-out behind CHAIN_SIDE_EFFECT_OBSERVER" "pass" \
  || assert "W3: observer wiring" "fail"
_wl=$(grep -n 'HARD-3 side-effect ledger (preflight)' "$RG" | head -1 | cut -d: -f1)
_wd=$(grep -n 'Step 1: goal-decomposer' "$RG" | head -1 | cut -d: -f1)
_ws=$(grep -n 'HARD-2 deterministic spec lint' "$RG" | head -1 | cut -d: -f1)
_we=$(grep -n 'HARD-3 E15' "$RG" | head -1 | cut -d: -f1)
_wr=$(grep -n 'Spec lint REJECTED' "$RG" | head -1 | cut -d: -f1)
_wx=$(grep -n 'Dispatching LEAN pipeline' "$RG" | head -1 | cut -d: -f1)
[[ -n "$_wl" && -n "$_wd" && -n "$_ws" && -n "$_we" && -n "$_wr" && -n "$_wx" \
   && "$_wl" -lt "$_wd" && "$_wd" -lt "$_ws" && "$_ws" -lt "$_we" && "$_we" -lt "$_wr" && "$_wr" -lt "$_wx" ]] \
  && assert "W4: source order: ledger build < decomposer < lint < E15 fail-closed check < re-plan < executor dispatch" "pass" \
  || assert "W4: source order (ledger=$_wl decomp=$_wd lint=$_ws e15=$_we replan=$_wr dispatch=$_wx)" "fail"
_wp=$(grep -n 'HARD-3 side-effect ledger (pre-evaluator refresh)' "$RG" | head -1 | cut -d: -f1)
_wv=$(grep -n 'Step 3: goal-evaluator' "$RG" | head -1 | cut -d: -f1)
[[ -n "$_wp" && -n "$_wv" && "$_wp" -lt "$_wv" ]] && grep -q '_SE_EVAL_LINE' "$RG" \
  && assert "W5: the ledger is refreshed before the evaluator dispatch, whose prompt carries the ledger line" "pass" \
  || assert "W5: pre-evaluator refresh ($_wp < $_wv)" "fail"
DB="$ENGINE_ROOT/agents/goal-decomposer/body.md"
EB="$ENGINE_ROOT/agents/goal-evaluator/body.md"
QB="$ENGINE_ROOT/agents/browser-qa-agent/body.md"
MS="$ENGINE_ROOT/skills/goal-evaluation-methodology.md"
grep -q '^## Side-effect policy' "$DB" && grep -q 'E16' "$DB" && grep -q 'E15' "$DB" && grep -q 'Side-effect policy:\*\* none | allowed' "$DB" \
  && grep -q 'side-effects.json' "$EB" && grep -q 'spec/journey contradiction' "$EB" \
  && grep -q 'Side-effect context' "$QB" && grep -q 'side-effects.json' "$MS" && grep -q '^6\. \*\*Side effects' "$MS" \
  && assert "W6: decomposer / evaluator / browser-qa contracts and the evaluator methodology document HARD-3" "pass" \
  || assert "W6: agent contracts" "fail"
[[ "$(sed -n 's/^version: //p' "$ENGINE_ROOT/agents/goal-decomposer/agent.yaml")" == "2.8.0" \
   && "$(sed -n 's/^version: //p' "$ENGINE_ROOT/agents/goal-evaluator/agent.yaml")" == "1.13.0" \
   && "$(sed -n 's/^version: //p' "$ENGINE_ROOT/agents/browser-qa-agent/agent.yaml")" == "1.4.0" ]] \
  && assert "W7: agent versions bumped (decomposer 2.8.0, evaluator 1.13.0, browser-qa-agent 1.4.0)" "pass" \
  || assert "W7: agent version bumps" "fail"
python3 "$ENGINE_ROOT/scripts/automation/sync-cli-assets.py" --cli claude --check >/dev/null 2>&1 \
  && assert "W8: sync-cli-assets --check is clean (mirrors match the neutral sources)" "pass" \
  || assert "W8: mirror drift check" "fail"
grep -qE '^  - Side effects: mutating — ' "$ENGINE_ROOT/templates/project-goal.md" \
  && grep -q 'read-only-endpoints.txt' "$ENGINE_ROOT/templates/project-goal.md" \
  && grep -q '## Side effects' "$ENGINE_ROOT/commands/goal-lint.md" && grep -q -- '--suggest' "$ENGINE_ROOT/commands/goal-lint.md" \
  && assert "W9: the goal template shows the line; /goal-lint reports a Side effects section (report-only)" "pass" \
  || assert "W9: template + goal-lint command" "fail"
_tdoc="$ENGINE_ROOT/docs/goal-mode-telemetry.md"
_miss=""
for ev in side_effect_observed side_effect_declaration_changed side_effect_exception_applied side_effect_unknown \
          side_effect_ledger_unavailable GATE_BLOCKED_SIDE_EFFECT_LEDGER side_effect_rules \
          side_effect_clear_refused side_effect_sidecar_update_failed side_effect_declaration_conflict \
          side_effect_observations_repaired CHAIN_SIDE_EFFECT_LOCK_TIMEOUT; do
  grep -q "$ev" "$_tdoc" || _miss+="$ev "
done
[[ -z "$_miss" ]] && grep -q 'journey-side-effects.json' "$ENGINE_ROOT/runs/SCHEMA.md" \
  && grep -q 'replay-side-effects.json' "$ENGINE_ROOT/runs/SCHEMA.md" && grep -q 'read-only-endpoints.txt' "$ENGINE_ROOT/runs/SCHEMA.md" \
  && assert "W10: telemetry doc lists every new event/field; runs/SCHEMA.md lists every new artifact" "pass" \
  || assert "W10: docs (missing: $_miss)" "fail"
grep -q 'tests/automation/test-side-effects.sh' "$ENGINE_ROOT/scripts/automation/run-evals.sh" \
  && assert "W11: run-evals.sh runs this suite" "pass" || assert "W11: run-evals wiring" "fail"
if grep -nE 'rm .*REPLAY_SIDE_EFFECTS_RUN' "$RL" "$LEAN" "$FULLQA" >/dev/null \
   || [[ "$(grep -c 'replay_side_effects_retire "\${REPLAY_SIDE_EFFECTS_RUN' "$RL" "$LEAN" | awk -F: '{s+=$2} END {print s}')" -lt 3 ]]; then
  assert "W13: per-run side-effect records are archived (partition entry + both fork reaps), never deleted" "fail"
else
  assert "W13: per-run side-effect records are archived (partition entry + both fork reaps), never deleted" "pass"
fi
python3 - "$RG" <<'PY' && assert "W14: every preflight ledger build resets SIDE_EFFECTS_FROZEN before it can fail" "pass" || assert "W14: frozen flag reset" "fail"
import sys
body = open(sys.argv[1]).read().split("_side_effect_ledger_build() {", 1)[1].split("\n}\n", 1)[0]
reset = body.find("SIDE_EFFECTS_FROZEN=false")
fail_return = body.find("return 0")
assert 0 <= reset < fail_return, (reset, fail_return)
PY
if grep -nE '(^|[^_])(pkill|fuser -k|killall)\b' "$SCRIPT_DIR/test-side-effects.sh" | grep -v 'grep -nE' >/dev/null; then
  assert "W12: this harness never kills by pattern or port (HARD-5)" "fail"
else
  assert "W12: this harness never kills by pattern or port (HARD-5)" "pass"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
