"""
scan_diff.py — deterministic secret / dependency / license scan of a unified
diff (stdlib regex only; no external tools, no model tokens).

Anti-goal detection used to be 100% the goal-evaluator reading a raw diff —
silent-failure-prone as models get weaker and diffs get bigger. This scanner
gives the loop (lib/goal-gates.sh) and the evaluator (iter-N/scan-report.md) a
mechanical first pass over the caller-provided diff. goal-gates.sh feeds it
the product diff (tracked + untracked, harness bookkeeping path-excluded via
CHAIN_SCAN_BOOKKEEPING_EXCLUDES — the scanner must never read the pipeline's
own generated reports), including the data/config paths the bounded diff view
truncates (secrets hide there).

Scans ADDED lines ('+' prefix) only. Severities:
  critical — private keys, cloud/API credentials (always blocking)
  warn     — new dependencies (including known paid-SaaS clients), LICENSE
             changes, placeholder-looking secret assignments

Paid-SaaS dependency policy (project-tunable — whether a paid service is
allowed is a per-project Anti-goals question the evaluator judges; the scanner
only surfaces the signal):
  default                       — paid-SaaS additions are WARN findings
  CHAIN_SCAN_STRICT_DEPS=true   — paid-SaaS additions become CRITICAL (block
                                  GOAL_ACHIEVED certification via the gate)
  CHAIN_SCAN_DEP_ALLOWLIST      — space/comma-separated package names (case-
                                  insensitive) never classified as paid-SaaS

CLI:
    git diff <sha> | python3 scan_diff.py scan [--json]
    python3 scan_diff.py scan --diff-file <path> [--json]
    python3 scan_diff.py self-test

Exit codes: 0 no findings; 1 warn-level only; 3 at least one critical.
Default output is a small markdown report; --json emits the raw findings.
"""
from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import asdict, dataclass

# (rule-name, compiled regex) — all matched against a single added line.
_CRITICAL_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("private-key-block", re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY(?: BLOCK)?-----")),
    ("aws-access-key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("github-token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b")),
    ("stripe-live-key", re.compile(r"\bsk_live_[A-Za-z0-9]{16,}\b")),
    ("openai-style-key", re.compile(r"\bsk-[A-Za-z0-9_-]{28,}\b")),
    ("slack-token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b")),
    ("google-api-key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),
]

_GENERIC_SECRET = re.compile(
    r"""(?ix)(password|passwd|secret|api[_-]?key|auth[_-]?token|access[_-]?token)
        \w*\s*[:=]\s*["']([^"']{8,})["']""",
)
# Values that make a generic-secret match a fixture/placeholder, not a leak.
_PLACEHOLDER = re.compile(
    r"(?i)(example|placeholder|dummy|sample|changeme|change-me|redacted|fake|"
    r"your[-_ ]|<[^>]+>|x{4,}|\*{4,}|test)"
)

# Paid/metered SaaS client packages, matched against dependency names.
# Whether adding one is a violation depends on the PROJECT's Anti-goals, so by
# default these are WARN findings the evaluator weighs; CHAIN_SCAN_STRICT_DEPS
# makes them CRITICAL, and CHAIN_SCAN_DEP_ALLOWLIST exempts named packages.
_PAID_SAAS = {
    "stripe", "twilio", "sendgrid", "@sendgrid/mail", "mailgun", "mailgun-js",
    "launchdarkly", "launchdarkly-server-sdk", "datadog", "dd-trace",
    "newrelic", "algolia", "algoliasearch", "pusher", "ably", "auth0",
    "openai", "anthropic", "mixpanel", "amplitude", "segment",
    "analytics-node", "@segment/analytics-node", "twilio-node",
}

# Added dependency lines in the manifests this framework's stacks use.
_DEP_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    # package.json:   "name": "^1.2.3",
    ("package.json", re.compile(r'^\s*"(@?[A-Za-z0-9_./-]+)"\s*:\s*"[~^]?\d')),
    # requirements.txt / constraints: name==1.2 / name>=1.2 / bare name
    ("requirements", re.compile(r"^\s*([A-Za-z0-9_.-]+)\s*(?:[=<>!~]=?|$)")),
    # pyproject.toml:  "name>=1.2" entries or name = "^1.2"
    ("pyproject", re.compile(r'^\s*"?([A-Za-z0-9_.-]+)"?\s*(?:=\s*"|>=|==)')),
]

_MANIFEST_FILE = re.compile(
    r"(package\.json|requirements[^/]*\.txt|constraints[^/]*\.txt|pyproject\.toml|Pipfile|Gemfile|go\.mod|Cargo\.toml)$"
)
_LICENSE_FILE = re.compile(r"(^|/)(LICENSE|LICENCE|COPYING)([._-].*)?$", re.IGNORECASE)


@dataclass
class Finding:
    severity: str   # critical | warn
    rule: str
    file: str
    excerpt: str


def _paid_saas_severity() -> str:
    """WARN by default; CRITICAL only when the project opts into strict mode."""
    return "critical" if os.environ.get("CHAIN_SCAN_STRICT_DEPS", "").lower() == "true" else "warn"


def _dep_allowlist() -> set[str]:
    raw = os.environ.get("CHAIN_SCAN_DEP_ALLOWLIST", "")
    return {d.strip().lower() for d in raw.replace(",", " ").split() if d.strip()}


def _added_lines(diff_text: str):
    """Yield (file_path, added_line_content) for every '+' line."""
    current = ""
    for raw in diff_text.splitlines():
        if raw.startswith("+++ "):
            current = raw[4:].strip()
            if current.startswith("b/"):
                current = current[2:]
            continue
        if raw.startswith("+") and not raw.startswith("+++"):
            yield current, raw[1:]


def scan(diff_text: str) -> list[Finding]:
    findings: list[Finding] = []
    seen: set[tuple[str, str, str]] = set()

    def add(severity: str, rule: str, file: str, excerpt: str) -> None:
        key = (rule, file, excerpt[:60])
        if key in seen:
            return
        seen.add(key)
        findings.append(Finding(severity, rule, file, excerpt.strip()[:160]))

    for path, line in _added_lines(diff_text):
        for rule, pat in _CRITICAL_PATTERNS:
            if pat.search(line):
                add("critical", rule, path, line)
        m = _GENERIC_SECRET.search(line)
        if m:
            value = m.group(2)
            if _PLACEHOLDER.search(value) or _PLACEHOLDER.search(line):
                add("warn", "secret-assignment-placeholder", path, line)
            else:
                add("critical", "secret-assignment", path, line)
        if _MANIFEST_FILE.search(path):
            for _kind, dep_pat in _DEP_PATTERNS:
                dm = dep_pat.match(line)
                if dm:
                    dep = dm.group(1).lower().strip()
                    if not dep or dep in {"python", "node", "version", "name", "description"}:
                        continue
                    if dep in _PAID_SAAS and dep not in _dep_allowlist():
                        add(_paid_saas_severity(), "paid-saas-dependency", path, f"new dependency: {dep}")
                    else:
                        add("warn", "new-dependency", path, f"new dependency: {dep}")
                    break
        if _LICENSE_FILE.search(path):
            add("warn", "license-change", path, line)

    return findings


def render_markdown(findings: list[Finding]) -> str:
    if not findings:
        return ("# Diff scan report\n\n**Result:** CLEAN — no secret, dependency, "
                "or license findings on added lines.\n")
    crit = [f for f in findings if f.severity == "critical"]
    out = ["# Diff scan report", "",
           f"**Result:** {'CRITICAL' if crit else 'WARNINGS'} — "
           f"{len(crit)} critical, {len(findings) - len(crit)} warn", ""]
    for f in findings:
        out.append(f"- **{f.severity.upper()}** `{f.rule}` in `{f.file}`: {f.excerpt}")
    out.append("")
    out.append("_Generated by lib/scan_diff.py over the caller-provided diff "
               "(goal-gates.sh feeds product changes only — harness "
               "bookkeeping is path-excluded)._")
    return "\n".join(out) + "\n"


def _cmd_scan(args: list[str]) -> int:
    text = ""
    if "--diff-file" in args:
        path = args[args.index("--diff-file") + 1]
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError as e:
            print(f"cannot read diff file: {e}", file=sys.stderr)
            return 2
    else:
        text = sys.stdin.read()
    findings = scan(text)
    if "--json" in args:
        print(json.dumps({"findings": [asdict(f) for f in findings]}, indent=2))
    else:
        print(render_markdown(findings), end="")
    if any(f.severity == "critical" for f in findings):
        return 3
    return 1 if findings else 0


def _self_test() -> int:
    clean_diff = """diff --git a/app/x.py b/app/x.py
+++ b/app/x.py
+def hello():
+    return "world"
"""
    assert scan(clean_diff) == []

    # Fixture tokens are assembled at runtime — keyword AND value split — so
    # this file's own diff never contains a line matching its own patterns
    # (editing the scanner must not trip the scanner; enforced by the
    # self-scan guard at the end of this test).
    fake_aws = "AKIA" + "IOSFODNN7EXAMPLE"
    key_name = "pass" + "word"
    pw = "hunter2" * 2
    placeholder_val = "example" + "-not-real"
    secret_diff = (
        "diff --git a/config/settings.py b/config/settings.py\n"
        "+++ b/config/settings.py\n"
        f'+AWS_KEY = "{fake_aws}"\n'
        f'+{key_name} = "{pw}"\n'
        f'+test_{key_name} = "{placeholder_val}"\n'
    )
    f = scan(secret_diff)
    rules = {x.rule for x in f}
    assert "aws-access-key" in rules
    assert "secret-assignment" in rules
    assert any(x.rule == "secret-assignment-placeholder" and x.severity == "warn" for x in f), \
        "placeholder secret must be warn, not critical"
    assert any(x.severity == "critical" for x in f)

    dep_diff = """diff --git a/apps/backend/requirements.txt b/apps/backend/requirements.txt
+++ b/apps/backend/requirements.txt
+stripe==7.0.0
+openai==1.30.0
+numpy==1.26.0
diff --git a/apps/frontend/package.json b/apps/frontend/package.json
+++ b/apps/frontend/package.json
+    "launchdarkly": "^3.0.0",
+    "lodash": "^4.17.21",
"""
    # Default policy: paid-SaaS additions are WARN (the evaluator judges them
    # against the project's Anti-goals) — an AI-app project adding its SDK must
    # not be mechanically blocked from certification.
    os.environ.pop("CHAIN_SCAN_STRICT_DEPS", None)
    os.environ.pop("CHAIN_SCAN_DEP_ALLOWLIST", None)
    f = scan(dep_diff)
    assert not any(x.severity == "critical" for x in f), "no criticals by default"
    saas = {x.excerpt for x in f if x.rule == "paid-saas-dependency"}
    plain = {x.excerpt for x in f if x.rule == "new-dependency"}
    assert "new dependency: stripe" in saas
    assert "new dependency: openai" in saas
    assert "new dependency: launchdarkly" in saas
    assert "new dependency: numpy" in plain
    assert "new dependency: lodash" in plain

    # Strict mode: paid-SaaS additions become CRITICAL (blocking).
    os.environ["CHAIN_SCAN_STRICT_DEPS"] = "true"
    f = scan(dep_diff)
    crit = {x.excerpt for x in f if x.severity == "critical"}
    assert "new dependency: stripe" in crit and "new dependency: openai" in crit
    # Allowlist beats strict for the named packages.
    os.environ["CHAIN_SCAN_DEP_ALLOWLIST"] = "openai, anthropic"
    f = scan(dep_diff)
    assert "new dependency: openai" in {x.excerpt for x in f if x.rule == "new-dependency"}, \
        "allowlisted package must be a plain new-dependency"
    assert "new dependency: stripe" in {x.excerpt for x in f if x.severity == "critical"}
    os.environ.pop("CHAIN_SCAN_STRICT_DEPS", None)
    os.environ.pop("CHAIN_SCAN_DEP_ALLOWLIST", None)

    lic_diff = """diff --git a/LICENSE b/LICENSE
+++ b/LICENSE
+Proprietary. All rights reserved.
"""
    f = scan(lic_diff)
    assert any(x.rule == "license-change" for x in f)

    # Removed lines are never findings.
    removed = (
        "diff --git a/a.py b/a.py\n"
        "+++ b/a.py\n"
        f'-{key_name} = "{pw}"\n'
    )
    assert scan(removed) == []

    # Markdown render includes the verdict word the evaluator keys on.
    assert "CLEAN" in render_markdown([])
    assert "CRITICAL" in render_markdown([Finding("critical", "x", "f", "e")])

    # Structural guard: this file's own source, scanned as fully-added lines,
    # must never yield a critical finding — otherwise any edit to the scanner
    # trips the scanner on its own diff (the failure mode that once fed the
    # goal-gate recursion). Keep fixture secrets keyword/value-split.
    with open(__file__, encoding="utf-8") as fh:
        own_lines = fh.read().splitlines()
    own_diff = (
        "diff --git a/scan_diff.py b/scan_diff.py\n"
        "+++ b/scan_diff.py\n"
        + "\n".join("+" + line for line in own_lines) + "\n"
    )
    own_criticals = [x for x in scan(own_diff) if x.severity == "critical"]
    assert not own_criticals, \
        f"scan_diff.py's own source trips its scanner: {own_criticals}"

    print("self-test passed")
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    if argv[0] == "scan":
        return _cmd_scan(argv[1:])
    if argv[0] == "self-test":
        return _self_test()
    print(f"unknown command: {argv[0]}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
