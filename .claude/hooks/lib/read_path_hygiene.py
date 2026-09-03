#!/usr/bin/env python3
"""Detect Bash commands that would stall a dispatch on a human approval prompt.

Enforces `.claude/core.md` -> "File Paths in Bash". Reads a shell command on
stdin; prints ONE corrective sentence when the command violates a rule, prints
nothing when it is clean. Any parse failure is silent (fail open) -- this guard
exists to stop hangs, never to become one.

Why the approval prompt happens at all: `Read(**/.env)`, `Read(~/.ssh/**)` and
friends are DENY rules, and deny beats every allow. Before a read the permission
checker must prove the read cannot touch a denied path. It cannot prove that when
the search root is unresolvable (a `cd` first) or unbounded (`.`, an absolute
path), so it escalates to a human -- which, inside a headless or pump dispatch,
is a hang. Narrowing the deny rules to silence it is explicitly forbidden by
core.md; they keep real secrets out of agent context.

Rule A -- `cd` in a compound whose later segment is a CONTENT READ carrying a
path argument. Reads only: `cd x && pytest` stays legal per core.md, and a piped
read with no path (`git diff | grep foo`) is untouched.

Rule B -- a RECURSIVE content search rooted at `.`, `./`, `..`, `~` or an
absolute path. Unbounded root, same escalation.
"""

import shlex
import sys

# Commands that read file CONTENT (so a path argument triggers the deny-rule
# proof the checker cannot complete). `ls` is absent on purpose: it lists names,
# does not read content, and is not what escalates.
#
# Value = how many non-flag arguments the command needs before one of them is a
# PATH rather than a pattern/script. grep-family and sed/awk spend their first
# non-flag argument on the pattern or program text, so they need two.
MIN_NONFLAG_ARGS = {
    "grep": 2, "egrep": 2, "fgrep": 2, "rg": 2, "ag": 2, "ack": 2,
    "sed": 2, "awk": 2, "gawk": 2,
    "cat": 1, "head": 1, "tail": 1, "less": 1, "more": 1, "nl": 1,
    "wc": 1, "find": 1, "strings": 1, "xxd": 1, "od": 1, "zcat": 1,
}

RECURSIVE_SEARCHERS = {"grep", "egrep", "fgrep", "ag", "ack"}
ALWAYS_RECURSIVE = {"rg"}

# Prefixes to look through when identifying a segment's real command: wrapper
# commands, and the shell control-flow keywords that put a command mid-segment
# (`for d in a; do cd $d && grep -n x y.py; done`). guard-dangerous-commands.sh
# needs the same carve-out for the same reason.
WRAPPERS = {
    "sudo", "env", "nohup", "command", "builtin", "exec", "time", "stdbuf",
    "do", "then", "else", "elif", "!",
}

SEPARATORS = {";", "&&", "||", "|", "&", "(", ")", "{", "}", "|&", "\n"}

# Redirect operators. Their targets are NOT read arguments — `2>/dev/null` must
# not read as "grep searching /dev/null". An optional file-descriptor digit can
# precede the operator (`2>`, `2>&1`).
REDIRECTS = {">", ">>", ">|", ">&", "<", "<<", "<<<", "<&", "&>", "&>>"}

UNRESOLVABLE_ROOTS = {".", "./", "..", "../", "~", "~/"}


def tokenize(cmd):
    lexer = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    return list(lexer)


def strip_redirects(tokens):
    """Drop redirect operators, their targets, and any leading fd digit."""
    out = []
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok in REDIRECTS:
            if out and out[-1].isdigit():
                out.pop()
            i += 2  # the operator and the file/fd it points at
            continue
        out.append(tok)
        i += 1
    return out


def split_segments(tokens):
    """Split a token list into command segments on shell separators."""
    segments, current = [], []
    for tok in strip_redirects(tokens):
        if tok in SEPARATORS:
            if current:
                segments.append(current)
            current = []
        else:
            current.append(tok)
    if current:
        segments.append(current)
    return segments


def head_of(segment):
    """(command name, argument tokens) with env assignments and wrappers stripped."""
    i = 0
    while i < len(segment):
        tok = segment[i]
        # VAR=value prefixes
        if "=" in tok and not tok.startswith("-") and tok.split("=", 1)[0].isidentifier():
            i += 1
            continue
        if tok in WRAPPERS:
            i += 1
            continue
        # `timeout 30 grep ...` / `timeout 30s grep ...`
        if tok == "timeout" and i + 1 < len(segment):
            i += 2
            continue
        break
    if i >= len(segment):
        return None, []
    name = segment[i].rsplit("/", 1)[-1]
    return name, segment[i + 1:]


def nonflag_args(args):
    return [a for a in args if not a.startswith("-")]


def has_recursive_flag(args):
    for a in args:
        if not a.startswith("-"):
            continue
        if a.startswith("--"):
            if a in ("--recursive", "--dereference-recursive"):
                return True
            continue
        if "r" in a[1:] or "R" in a[1:]:
            return True
    return False


def is_unresolvable_root(path):
    return (
        path in UNRESOLVABLE_ROOTS
        or path.startswith("/")
        or path.startswith("~")
        or path.startswith("./")
        or path.startswith("../")
    )


def check(cmd):
    try:
        tokens = tokenize(cmd)
    except ValueError:
        return None  # unbalanced quotes etc. -- fail open
    segments = split_segments(tokens)

    saw_cd = False
    for segment in segments:
        name, args = head_of(segment)
        if name is None:
            continue

        if name == "cd":
            saw_cd = True
            continue

        if name not in MIN_NONFLAG_ARGS:
            continue

        plain = nonflag_args(args)
        min_args = MIN_NONFLAG_ARGS[name]

        # Rule A: a content read with a path argument, after a `cd`.
        if saw_cd and len(plain) >= min_args:
            return (
                "`%s` reads a path after a `cd`, so the permission checker cannot "
                "resolve the search root and MUST ask a human -- which hangs this "
                "dispatch. Drop the `cd` and use a repo-relative path from the repo "
                "root instead (e.g. `grep -n \"x\" apps/backend/app/main.py`, not "
                "`cd apps/backend && grep -n \"x\" app/main.py`). Commands that truly "
                "need a subdirectory (pytest, npm, tsc) may still `cd`. "
                "See .claude/core.md -> File Paths in Bash." % name
            )

        # Rule B: a recursive content search rooted at an unbounded location.
        recursive = name in ALWAYS_RECURSIVE or (
            name in RECURSIVE_SEARCHERS and has_recursive_flag(args)
        )
        if recursive and len(plain) >= min_args:
            for path in plain[min_args - 1:]:
                if is_unresolvable_root(path):
                    return (
                        "`%s` roots a recursive search at `%s`. An unbounded or "
                        "absolute root cannot be proven to miss the `Read(**/.env)` "
                        "deny rules, so the checker MUST ask a human -- which hangs "
                        "this dispatch. Name concrete repo-relative subdirectories "
                        "instead (e.g. `grep -rn PATTERN apps/backend/app/ "
                        "apps/frontend/src/`). `--include`/`--exclude-dir` do NOT "
                        "help: the checker reads the path argument, not the filter "
                        "flags. See .claude/core.md -> File Paths in Bash."
                        % (name, path)
                    )

    return None


def main():
    cmd = sys.stdin.read()
    if not cmd.strip():
        return
    try:
        verdict = check(cmd)
    except Exception:
        return  # fail open: this guard must never become the hang it prevents
    if verdict:
        sys.stdout.write(verdict)


if __name__ == "__main__":
    main()
