#!/usr/bin/env python3
"""
install-gate.py — Pre-install supply-chain security policy engine.

Evaluates an installation command against the repo security policy and
returns a structured JSON decision.

Usage:
    python3 scripts/automation/lib/install-gate.py \\
        --command "pip install requests==2.31.0" \\
        [--policy config/install-security-policy.json] \\
        [--repo-root /path/to/repo]

Exit codes:
    0  allow / warn  (proceed; warning printed if warn)
    1  block         (do not proceed; reason printed)
    2  require_approval (do not proceed; override instructions printed)
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

# ── Constants ─────────────────────────────────────────────────────────────────

DECISIONS = ("allow", "warn", "block", "require_approval")

# Default policy path relative to repo root
DEFAULT_POLICY_PATH = "config/install-security-policy.json"

# ── Decision builder ──────────────────────────────────────────────────────────


def make_result(decision, reason, *, source_type="unknown", packages=None,
                checks=None, findings=None):
    return {
        "decision": decision,
        "reason": reason,
        "source_type": source_type,
        "packages": packages or [],
        "checks": checks or [],
        "findings": findings or [],
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


# ── Command parsers ───────────────────────────────────────────────────────────

def parse_pip_packages(args_str):
    """Return list of {name, version, pinned, direct_url} from pip install args."""
    packages = []
    tokens = args_str.split()
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        # Skip flags
        if tok.startswith("-"):
            # -r / --requirement takes a filename argument
            if tok in ("-r", "--requirement"):
                i += 2
                continue
            # Flags with no separate value
            i += 1
            continue
        # Direct URL install
        if tok.startswith("http://") or tok.startswith("https://") or tok.startswith("git+"):
            packages.append({"name": tok, "version": None, "pinned": False, "direct_url": True})
            i += 1
            continue
        # Package spec: name==ver, name>=ver, name[extra]==ver, etc.
        m = re.match(r"^([A-Za-z0-9_.\-]+(?:\[[^\]]+\])?)(==([^\s,;]+))?", tok)
        if m:
            name = m.group(1).lower().split("[")[0]  # strip extras
            version = m.group(3)
            pinned = version is not None and m.group(2) is not None  # only == counts as pinned
            packages.append({"name": name, "version": version, "pinned": pinned, "direct_url": False})
        i += 1
    return packages


def parse_npm_packages(args_str):
    """Return list of {name, version, pinned} from npm install args."""
    packages = []
    tokens = args_str.split()
    for tok in tokens:
        if tok.startswith("-") or tok in ("install", "i", "add"):
            continue
        # Scoped: @scope/name@version
        m = re.match(r"^(@?[A-Za-z0-9_.\-/]+)(?:@([^\s]+))?$", tok)
        if m:
            name = m.group(1).lower()
            version = m.group(2)
            # npm pins with exact version string (no range operators)
            pinned = bool(version and not re.search(r"[\^~><]", version))
            packages.append({"name": name, "version": version, "pinned": pinned})
    return packages


def extract_git_ref(args_str):
    """Return (url, ref, ref_type) from a git clone command."""
    url = None
    ref = None
    tokens = args_str.split()
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok in ("clone", "--depth", "--shallow-since", "--shallow-exclude",
                   "--single-branch", "--no-tags", "--recurse-submodules",
                   "--recursive", "--quiet", "-q", "--verbose", "-v"):
            i += 1
            if tok in ("--depth", "--shallow-since", "--shallow-exclude"):
                i += 1  # skip value
            continue
        if tok in ("-b", "--branch"):
            if i + 1 < len(tokens):
                ref = tokens[i + 1]
                i += 2
            continue
        if tok == "--":
            i += 1
            continue
        if tok.startswith("-"):
            i += 1
            continue
        if url is None:
            url = tok
        i += 1

    # Classify ref type
    ref_type = None
    if ref:
        # SHA (>=7 hex chars)
        if re.match(r"^[0-9a-f]{7,40}$", ref, re.IGNORECASE):
            ref_type = "sha"
        # Looks like a semver tag
        elif re.match(r"^v?\d+\.\d+", ref):
            ref_type = "tag"
        else:
            ref_type = "branch"
    return url, ref, ref_type


def extract_git_org(url):
    """Return org/user from a GitHub URL, or None."""
    if url is None:
        return None
    m = re.match(r"https?://github\.com/([^/]+)/", url)
    if m:
        return m.group(1).lower()
    m = re.match(r"git@github\.com:([^/]+)/", url)
    if m:
        return m.group(1).lower()
    return None


# ── Policy checks ─────────────────────────────────────────────────────────────

def check_denylist_python(packages, policy):
    """Return (blocked_pkg, entry) if any package is denylisted."""
    denylist = policy.get("python", {}).get("denylist", [])
    for pkg in packages:
        for entry in denylist:
            if pkg["name"].lower() == entry["package"].lower():
                # Version-specific deny
                if "version" in entry and entry["version"]:
                    if pkg["version"] == entry["version"]:
                        return pkg, entry
                else:
                    # Name-only deny (all versions)
                    return pkg, entry
    return None, None


def check_denylist_npm(packages, policy):
    """Return (blocked_pkg, entry) if any npm package is denylisted."""
    denylist = policy.get("npm", {}).get("denylist", [])
    for pkg in packages:
        for entry in denylist:
            if pkg["name"].lower() == entry.get("package", "").lower():
                if "version" in entry and entry["version"]:
                    if pkg.get("version") == entry["version"]:
                        return pkg, entry
                else:
                    return pkg, entry
    return None, None


def in_allowlist(name, allowlist):
    """Case-insensitive allowlist check."""
    return name.lower() in [a.lower() for a in allowlist]


def is_known_requirements_file(filepath, repo_root):
    """Return True if the requirements file is a committed repo file."""
    known_files = {
        "requirements.txt",
        "requirements-dev.txt",
        "requirements-test.txt",
    }
    p = Path(filepath)
    filename = p.name
    if filename in known_files:
        # Also accept path-qualified versions as long as they stay in the repo
        candidate = (Path(repo_root) / filepath).resolve()
        try:
            candidate.relative_to(Path(repo_root).resolve())
            return True
        except ValueError:
            pass
    return False


# ── Main evaluators ───────────────────────────────────────────────────────────

def evaluate_pip(cmd, policy, repo_root):
    """Evaluate a pip / pip3 / uv pip install command."""
    py_policy = policy.get("python", {})
    rules = py_policy.get("rules", {})
    allowlist = py_policy.get("allowlist", [])
    checks = []

    # Strip leading command tokens to get install args
    m = re.match(
        r"(?:~?\.?/?\S*/)?"  # optional path prefix
        r"(?:uv\s+pip\s+|pip3?\s+|\.venv/bin/pip\s+)"
        r"install\s+(.*)",
        cmd.strip(),
        re.IGNORECASE,
    )
    if not m:
        return make_result("allow", "Not a pip install command; skipping.", checks=["command_parse"])

    args_str = m.group(1).strip()

    checks.append("curl_pipe_check")

    # Requirements file path
    req_match = re.search(r"-r\s+(\S+)|--requirement\s+(\S+)", args_str)
    if req_match:
        checks.append("requirements_file")
        filepath = req_match.group(1) or req_match.group(2)
        if rules.get("allow_requirements_file", True) and is_known_requirements_file(filepath, repo_root):
            return make_result(
                "allow",
                f"Installing from committed requirements file: {filepath}",
                source_type="pypi",
                checks=checks,
            )
        return make_result(
            "require_approval",
            f"Requirements file '{filepath}' is not a recognised repo dependency file. "
            "Add it to the known files list or install packages explicitly.",
            source_type="pypi",
            checks=checks,
            findings=[f"unknown_requirements_file: {filepath}"],
        )

    packages = parse_pip_packages(args_str)
    if not packages:
        return make_result("allow", "No packages identified; allowing.", source_type="pypi", checks=checks)

    checks.append("direct_url")
    direct_url_pkgs = [p for p in packages if p.get("direct_url")]
    if direct_url_pkgs and rules.get("block_direct_url", True):
        urls = [p["name"] for p in direct_url_pkgs]
        return make_result(
            "block",
            f"Direct URL install is not allowed by policy: {', '.join(urls)}",
            source_type="url",
            packages=packages,
            checks=checks,
            findings=[f"direct_url: {u}" for u in urls],
        )

    checks.append("denylist")
    blocked_pkg, entry = check_denylist_python(packages, policy)
    if blocked_pkg:
        reason = entry.get("reason", "Package is on the security denylist.")
        return make_result(
            "block",
            f"Package '{blocked_pkg['name']}=={blocked_pkg['version']}' is blocked: {reason}",
            source_type="pypi",
            packages=packages,
            checks=checks,
            findings=[f"denylist: {blocked_pkg['name']}=={blocked_pkg['version']}"],
        )

    checks.append("allowlist")
    all_allowed = all(in_allowlist(p["name"], allowlist) for p in packages)
    if all_allowed:
        unpinned = [p for p in packages if not p["pinned"]]
        if unpinned and rules.get("require_pinned_version", True):
            names = ", ".join(p["name"] for p in unpinned)
            return make_result(
                "require_approval",
                f"Allowlisted package(s) require a pinned version (==): {names}. "
                "Pin the version explicitly or override the policy.",
                source_type="pypi",
                packages=packages,
                checks=checks,
                findings=[f"unpinned: {p['name']}" for p in unpinned],
            )
        return make_result(
            "allow",
            "All packages are in the allowlist.",
            source_type="pypi",
            packages=packages,
            checks=checks,
        )

    checks.append("version_pinning")
    unknown = [p for p in packages if not in_allowlist(p["name"], allowlist)]
    unpinned = [p for p in unknown if not p["pinned"]]

    if unpinned and rules.get("require_pinned_version", True):
        names = ", ".join(p["name"] for p in unpinned)
        return make_result(
            "require_approval",
            f"Unknown package(s) with unpinned version: {names}. "
            "Pin the version (==X.Y.Z) or add the package to the allowlist in "
            "config/install-security-policy.json.",
            source_type="pypi",
            packages=packages,
            checks=checks,
            findings=[f"unpinned_unknown: {p['name']}" for p in unpinned],
        )

    unknown_names = ", ".join(p["name"] for p in unknown)
    return make_result(
        "require_approval",
        f"Package(s) not in the allowlist: {unknown_names}. "
        "Add to config/install-security-policy.json allowlist to permit, or use "
        "CHAIN_INSTALL_GATE_BYPASS=true to override.",
        source_type="pypi",
        packages=packages,
        checks=checks,
        findings=[f"not_allowlisted: {p['name']}" for p in unknown],
    )


def evaluate_npm(cmd, policy, repo_root):
    """Evaluate an npm install / npm ci command."""
    npm_policy = policy.get("npm", {})
    rules = npm_policy.get("rules", {})
    allowlist = npm_policy.get("allowlist", [])
    checks = []

    m = re.match(
        r"(?:~?\.?/?\S*/)?npm\s+(install|i|ci|add)\s*(.*)",
        cmd.strip(),
        re.IGNORECASE,
    )
    if not m:
        return make_result("allow", "Not a recognisable npm install command; skipping.", checks=["command_parse"])

    subcommand = m.group(1).lower()
    args_str = m.group(2).strip()

    checks.append("package_json_install")
    if subcommand == "ci" or not args_str:
        if rules.get("allow_package_json_install", True):
            return make_result(
                "allow",
                "Installing from package.json / package-lock.json (committed deps).",
                source_type="npm",
                checks=checks,
            )

    checks.append("direct_url")
    if args_str and (args_str.startswith("http") or ".tgz" in args_str or ".tar.gz" in args_str):
        return make_result(
            "block",
            f"Direct URL/tarball npm install not allowed: {args_str}",
            source_type="url",
            checks=checks,
            findings=[f"direct_url: {args_str}"],
        )

    packages = parse_npm_packages(args_str) if args_str else []
    if not packages:
        return make_result("allow", "No packages identified; allowing.", source_type="npm", checks=checks)

    checks.append("denylist")
    blocked_pkg, entry = check_denylist_npm(packages, policy)
    if blocked_pkg:
        reason = entry.get("reason", "Package is on the security denylist.")
        return make_result(
            "block",
            f"npm package '{blocked_pkg['name']}' is blocked: {reason}",
            source_type="npm",
            packages=packages,
            checks=checks,
            findings=[f"denylist: {blocked_pkg['name']}"],
        )

    checks.append("allowlist")
    all_allowed = all(in_allowlist(p["name"], allowlist) for p in packages)
    if all_allowed:
        unpinned = [p for p in packages if not p["pinned"]]
        if unpinned and rules.get("require_pinned_version", True):
            names = ", ".join(p["name"] for p in unpinned)
            return make_result(
                "require_approval",
                f"Allowlisted npm package(s) require a pinned version (@X.Y.Z): {names}.",
                source_type="npm",
                packages=packages,
                checks=checks,
                findings=[f"unpinned: {p['name']}" for p in unpinned],
            )
        return make_result("allow", "All npm packages are in the allowlist.", source_type="npm",
                           packages=packages, checks=checks)

    checks.append("version_pinning")
    unknown = [p for p in packages if not in_allowlist(p["name"], allowlist)]
    unknown_names = ", ".join(p["name"] for p in unknown)
    return make_result(
        "require_approval",
        f"npm package(s) not in the allowlist: {unknown_names}. "
        "Add to config/install-security-policy.json npm.allowlist to permit.",
        source_type="npm",
        packages=packages,
        checks=checks,
        findings=[f"not_allowlisted: {p['name']}" for p in unknown],
    )


def evaluate_git_clone(cmd, policy, _repo_root):
    """Evaluate a git clone command."""
    git_policy = policy.get("git", {})
    rules = git_policy.get("rules", {})
    trusted_orgs = [o.lower() for o in git_policy.get("trusted_orgs", [])]
    checks = []

    m = re.match(r"(?:~?\.?/?\S*/)?git\s+clone\s+(.*)", cmd.strip(), re.IGNORECASE)
    if not m:
        return make_result("allow", "Not a git clone; skipping.", checks=["command_parse"])

    args_str = m.group(1).strip()
    url, ref, ref_type = extract_git_ref(args_str)
    org = extract_git_org(url)

    checks.append("git_ref_pinning")
    checks.append("trusted_org")

    pkg_info = [{"name": url or "unknown", "version": ref or "HEAD", "pinned": ref_type in ("sha", "tag")}]

    if rules.get("require_pinned_ref", True):
        if ref is None:
            return make_result(
                "require_approval",
                f"git clone without a pinned ref (tag or commit SHA): {url}. "
                "Use --branch <tag> or --branch <sha> to pin the ref.",
                source_type="git",
                packages=pkg_info,
                checks=checks,
                findings=["no_ref_specified"],
            )
        if ref_type == "branch":
            return make_result(
                "require_approval",
                f"git clone uses branch ref '{ref}' which is mutable. "
                "Use a tag or commit SHA instead for reproducibility.",
                source_type="git",
                packages=pkg_info,
                checks=checks,
                findings=[f"mutable_branch_ref: {ref}"],
            )

    if org and org in trusted_orgs:
        return make_result(
            "allow",
            f"git clone from trusted org '{org}' with pinned ref '{ref}'.",
            source_type="git",
            packages=pkg_info,
            checks=checks,
        )

    return make_result(
        "warn",
        f"git clone from unknown org/URL '{url}' with ref '{ref}'. "
        "Review the repository before proceeding. "
        "Add the org to git.trusted_orgs in config/install-security-policy.json to suppress this warning.",
        source_type="git",
        packages=pkg_info,
        checks=checks,
        findings=[f"unknown_org: {org or 'non-github'}"],
    )


def evaluate_curl_pipe(cmd, _policy, _repo_root):
    """Always block curl|bash and wget|bash patterns."""
    return make_result(
        "block",
        "Piping curl/wget output directly to a shell is always blocked. "
        "Download the script first, review it, then execute it explicitly.",
        source_type="url",
        checks=["curl_pipe_check"],
        findings=["curl_pipe_bash"],
    )


# ── Dispatcher ────────────────────────────────────────────────────────────────

def classify_and_evaluate(cmd, policy, repo_root):
    """Classify the command and run the appropriate evaluator."""

    bypass_var = policy.get("global", {}).get("bypass_env_var", "CHAIN_INSTALL_GATE_BYPASS")
    if os.environ.get(bypass_var, "").lower() in ("1", "true", "yes"):
        return make_result(
            "allow",
            f"Install gate bypassed via {bypass_var}=true.",
            source_type="unknown",
            checks=["bypass"],
        )

    cmd_stripped = cmd.strip()

    if re.search(r"(curl|wget)\s+.*\|\s*(bash|sh)\b", cmd_stripped, re.IGNORECASE):
        return evaluate_curl_pipe(cmd_stripped, policy, repo_root)

    if re.search(
        r"(?:^|[;&|]|\s)(pip3?|uv\s+pip|\.venv/bin/pip\d?)\s+install\b",
        cmd_stripped, re.IGNORECASE
    ):
        return evaluate_pip(cmd_stripped, policy, repo_root)

    if re.search(r"(?:^|[;&|]|\s)(?:~?\.?/?\S+/)?uv\s+add\b", cmd_stripped, re.IGNORECASE):
        rewritten = re.sub(r"uv\s+add\b", "pip install", cmd_stripped)
        return evaluate_pip(rewritten, policy, repo_root)

    if re.search(r"(?:^|[;&|]|\s)npm\s+(install|i|ci|add)\b", cmd_stripped, re.IGNORECASE):
        return evaluate_npm(cmd_stripped, policy, repo_root)

    if re.search(r"(?:^|[;&|]|\s)git\s+clone\b", cmd_stripped, re.IGNORECASE):
        return evaluate_git_clone(cmd_stripped, policy, repo_root)

    return None


# ── Logging ───────────────────────────────────────────────────────────────────

def log_decision(result, cmd, policy, repo_root):
    """Append decision to JSONL log file if logging is enabled."""
    if not policy.get("global", {}).get("log_all_decisions", True):
        return
    log_path_rel = policy.get("global", {}).get("log_file", "reports/security/install-decisions.jsonl")
    log_path = Path(repo_root) / log_path_rel
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        record = {**result, "command": cmd}
        with open(log_path, "a") as f:
            f.write(json.dumps(record) + "\n")
    except OSError:
        pass


# ── CLI entry point ───────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Pre-install security gate policy engine.")
    parser.add_argument("--command", required=True, help="The shell command to evaluate.")
    parser.add_argument(
        "--policy",
        default=None,
        help=f"Path to policy JSON file (default: {DEFAULT_POLICY_PATH} relative to repo root).",
    )
    parser.add_argument(
        "--repo-root",
        default=None,
        help="Repo root path (default: auto-detected from this script's location).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Evaluate without logging the decision.",
    )
    args = parser.parse_args()

    if args.repo_root:
        repo_root = Path(args.repo_root).resolve()
    else:
        repo_root = Path(__file__).resolve().parent.parent.parent.parent

    policy_path = Path(args.policy) if args.policy else (repo_root / DEFAULT_POLICY_PATH)
    try:
        with open(policy_path) as f:
            policy = json.load(f)
    except FileNotFoundError:
        result = make_result(
            "warn",
            f"Policy file not found at {policy_path}. Install gate is not enforcing policy. "
            "Create config/install-security-policy.json to enable enforcement.",
            checks=["policy_load"],
        )
        print(json.dumps(result))
        return 0
    except json.JSONDecodeError as e:
        result = make_result(
            "warn",
            f"Policy file is invalid JSON: {e}. Install gate disabled.",
            checks=["policy_load"],
        )
        print(json.dumps(result))
        return 0

    result = classify_and_evaluate(args.command, policy, repo_root)

    if result is None:
        sys.exit(0)

    if not args.dry_run:
        log_decision(result, args.command, policy, repo_root)

    print(json.dumps(result, indent=2))

    decision = result["decision"]
    if decision in ("allow", "warn"):
        sys.exit(0)
    elif decision == "block":
        sys.exit(1)
    elif decision == "require_approval":
        sys.exit(2)
    else:
        sys.exit(0)


if __name__ == "__main__":
    main()
