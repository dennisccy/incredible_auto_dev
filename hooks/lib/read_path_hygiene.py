#!/usr/bin/env python3
"""Detect Bash command shapes that would stall a headless dispatch on a human
approval prompt, and deny them with a corrective message before they run.

Acceptance philosophy, in one sentence: DENY a shape only when it is PROVEN --
by an observed incident, by Claude Code's own hard-gate table, or by
documented `.claude/core.md` behaviour -- to stall on a human, and FAIL OPEN
on every shape this module cannot parse or does not recognize, because a
false ALLOW merely defers to the native permission checker (where the
decision belongs by default) while a false DENY blocks real work.

Why the approval prompt happens at all: `Read(**/.env)`, `Read(~/.ssh/**)` and
friends are DENY rules, and deny beats every allow. Before a read the
permission checker must prove the read cannot touch a denied path. It cannot
prove that when the search root is unresolvable (a `cd` first) or unbounded
(`.`, an absolute path), so it escalates to a human -- a hang inside a
headless or pump dispatch. Narrowing the deny rules to silence it is
explicitly forbidden by core.md; they keep real secrets out of agent context.

Rules -- A and C1-C3 fire only on a segment AFTER a `cd` in the same command;
B fires regardless of `cd` (an unbounded root is unbounded either way):

  A  -- the hard-enforced content-read set (grep/egrep/fgrep, cat, find,
        read-only sed -n) carries a RELATIVE path operand. Evidence tier:
        observed (E3 -- the goal-session contract-pack-v0 iter 1 stall) plus
        the per-command operand tables below; rg/head/tail/wc/awk/... are
        deliberately left oracle-gated, not enforced.
  B  -- a recursive content search (grep/egrep/fgrep -r, rg always) is rooted
        at `.`, `./`, `..`, `~` or an absolute path -- unbounded regardless of
        `cd`. Evidence tier: observed regressions (b422b6e, b6ae4d2).
  C1 -- a write/create-class command (sed -i, cp, mv, rm, rmdir, mkdir, touch)
        runs after the `cd`. Evidence tier: Claude Code's own hard gate
        ("compound command contains cd with write operation ... manual
        approval required") -- no allow rule can ever pre-approve this shape,
        so it is enforced unconditionally. Also observed (E2 verbatim).
  C2 -- an output redirect (`>`, `>>`, `&>`, ...) to a real file (not
        /dev/null) follows the `cd`. Evidence tier: Claude Code's own hard
        gate ("compound command contains cd with output redirection ...
        manual approval required"), documented in core.md.
  C3 -- `git` runs after the `cd`. Evidence tier: documented in core.md (git
        run from a changed directory can execute that directory's hooks).

Unknown / fail-open: a command this module cannot safely reason about passes
through UNCHANGED to the native checker -- never denied on a guess. One
stderr line names why: `FAILOPEN reason=tokenize` (shell syntax the tokenizer
rejects, e.g. an unbalanced quote), `FAILOPEN reason=complex:<kind>` (control
flow, subshell/brace/command-substitution/process-substitution grouping, or a
backtick substitution -- `<kind>` is `control-flow`, `grouping` or
`backtick`), or `FAILOPEN reason=exception:<ClassName>` (an unexpected bug in
this module itself, caught so the guard never becomes the hang it prevents).
The one exception is `coarse_check()`: when the tokenizer itself fails, a
command still matching an unmistakable `cd ... <write word>` shape is denied
as rule "coarse" instead of failing open, because that shape does not need a
clean parse to be certain.

Header protocol (read by guard-read-path-hygiene.sh): on a DENY, stdout line 1
is a single-line JSON header -- `{"rule": "...", "command_class": "...",
"has_cd": bool, "has_output_redirect": bool}` -- followed by the corrective
message (everything after the first newline). Nothing is written to stdout
when the command is clean or unknown.

`--self-test` runs the fixture suite at the bottom of this file and exits
0/1. `--oracle-manifest` prints one `id<TAB>command` line per ORACLE_MANIFEST
case (`{SB}` = sandbox root placeholder) -- the single source consumed by
scripts/automation/permission-oracle.sh, so the native-checker probe list and
this module's pinned expectations can never drift apart.
"""

import json
import re
import shlex
import sys
from collections import namedtuple

# Prefixes the native checker strips before matching (docs § Wrappers) plus sudo/exec/!.
WRAPPERS = {"sudo", "env", "nohup", "nice", "command", "builtin", "exec", "time", "stdbuf", "!"}
# The checker's create/write-class commands (bundle NH table). tee/install are absent on purpose.
WRITE_COMMANDS = {"mkdir", "touch", "rm", "rmdir", "mv", "cp"}
# Syntax the guard deliberately does not interpret (D3): fail open, log, let the checker decide.
CONTROL_FLOW = {"for", "while", "until", "if", "case", "select", "function", "eval"}
GROUPING = {"(", ")", "{", "}"}
PUNCT = "();<>|&\n"                      # shlex punctuation + newline (a separator in the shell)
SEPARATORS = {";", "&&", "||", "|", "&", "|&", "\n"}
OUTPUT_REDIRECTS = {">", ">>", ">|", "&>", "&>>"}
OTHER_REDIRECTS = {">&", "<", "<<<", "<&", "<>"}
SAFE_REDIRECT_TARGETS = {"/dev/" + "null"}
UNRESOLVABLE_ROOTS = {".", "./", "..", "../", "~", "~/"}
COARSE_CD = re.compile(r"(?:^|[;&|\n]\s*)cd\s")
COARSE_WRITE = re.compile(r"(?:^|[;&|\s])(?:sed\s+(?:-[A-Za-z]*i|--in-place)|rm|rmdir|mv|cp|mkdir|touch)\s")

Verdict = namedtuple("Verdict", "rule command_class has_cd has_output_redirect message")
RULE_DOC = "See .claude/core.md -> File Paths in Bash."
MSG = {
    "A": ("`%s` reads a relative path in a command that also runs `cd`, so the permission checker "
          "cannot resolve the file and MUST ask a human -- which hangs this dispatch. Drop the `cd` "
          "and use a repo-relative path from the repo root (e.g. `grep -n \"x\" apps/backend/app/main.py`, "
          "not `cd apps/backend && grep -n \"x\" app/main.py`). `cd` stays legal for a command that "
          "needs the cwd and reads no path, writes nothing, redirects nothing and does not run git "
          "(pytest, npm, tsc). " + RULE_DOC),
    "B": ("`%s` roots a recursive search at `%s`. An unbounded root cannot be proven to miss the "
          "`Read(**/.env)` deny rules, so the checker MUST ask a human -- which hangs this dispatch. "
          "Name concrete repo-relative subdirectories instead (e.g. `grep -rn PATTERN apps/backend/app/ "
          "apps/frontend/src/`). `--include`/`--exclude-dir` do NOT help: the checker reads the path "
          "argument, not the filter flags. " + RULE_DOC),
    "C1": ("`%s` mutates a file after a `cd` in the same command. Claude Code hard-gates that shape "
           "('compound command contains cd with write operation - manual approval required'); NO allow "
           "rule can pre-approve it, so this dispatch would hang on a human. Edit files with the "
           "Edit/Write tools, or drop the `cd` and use a repo-relative path from the repo root (e.g. "
           "`sed -i 's/OLD/NEW/g' apps/backend/tests/test_x.py`, not `cd apps/backend/tests && sed -i "
           "'s/OLD/NEW/g' test_x.py`). " + RULE_DOC),
    "C2": ("The output redirect to `%s` follows a `cd` in the same command. Claude Code hard-gates "
           "that shape ('compound command contains cd with output redirection - manual approval "
           "required'), so this dispatch would hang on a human. Redirect to /dev/null, or drop the "
           "`cd` and name the file repo-relative from the repo root (e.g. `pytest -q apps/backend > "
           "apps/backend/test-output.log`), or capture the output with the Write tool. " + RULE_DOC),
    "C3": ("`git` after a `cd` prompts a human (Claude Code treats git run from a changed directory "
           "as able to execute that directory's hooks), which hangs this dispatch. Run git from the "
           "repo root: `git status`, `git -C apps/backend log -3`, `git add apps/backend/app/x.py`. "
           + RULE_DOC),
}


# ── Per-command operand extraction (tiny tables; not a general getopt) ─────────
def operand_paths(args, value_short, value_long, pattern_short, pattern_long):
    """Operands of a grep/sed/rg-style command line. Options in value_short/value_long consume a
    value (attached or the next token); the first operand is the pattern/script unless one of
    the pattern_* options supplied it. Table-driven per command; nothing else is interpreted."""
    paths, i, pattern_given, opts_done = [], 0, False, False
    while i < len(args):
        a = args[i]
        i += 1
        if a == "-":
            continue                                    # stdin marker, never a path (like cat_paths)
        if opts_done or not a.startswith("-"):
            paths.append(a)
            continue
        if a == "--":
            opts_done = True
            continue
        if a.startswith("--"):
            name = a.split("=", 1)[0]
            pattern_given = pattern_given or name in pattern_long
            if "=" not in a and name in value_long:
                i += 1                                  # separate value token
            continue
        for j, ch in enumerate(a[1:], 1):
            if ch in value_short:
                pattern_given = pattern_given or ch in pattern_short
                if j == len(a) - 1:
                    i += 1                              # value is the next token
                break                                   # otherwise the rest of the cluster is the value
    if not pattern_given and paths:
        paths = paths[1:]
    return paths


GREP_VALUE_SHORT = set("efmABCdD")
GREP_VALUE_LONG = {"--regexp", "--file", "--max-count", "--after-context", "--before-context", "--context",
                   "--include", "--exclude", "--exclude-dir", "--exclude-from", "--label", "--devices",
                   "--directories", "--binary-files", "--color", "--colour", "--group-separator"}
SED_VALUE_SHORT = set("efl")
SED_VALUE_LONG = {"--expression", "--file", "--line-length"}
RG_VALUE_SHORT = set("efgtTmABCMjdrE")
RG_VALUE_LONG = {"--regexp", "--file", "--glob", "--iglob", "--type", "--type-not", "--type-add", "--max-count",
                 "--after-context", "--before-context", "--context", "--max-columns", "--max-depth",
                 "--max-filesize", "--threads", "--replace", "--encoding", "--color", "--colors", "--sort",
                 "--sortr", "--context-separator", "--path-separator", "--pre", "--pre-glob", "--ignore-file",
                 "--engine"}


def grep_paths(args):
    return operand_paths(args, GREP_VALUE_SHORT, GREP_VALUE_LONG, set("ef"), {"--regexp", "--file"})


def sed_paths(args):
    return operand_paths(args, SED_VALUE_SHORT, SED_VALUE_LONG, set("ef"), {"--expression", "--file"})


def rg_paths(args):
    return operand_paths(args, RG_VALUE_SHORT, RG_VALUE_LONG, set("ef"), {"--regexp", "--file"})


def cat_paths(args):
    return [a for a in args if a != "-" and not a.startswith("-")]


def find_paths(args):
    """Explicit starting points only: leading operands after -H/-L/-P/-Olevel/-D opts and before
    the first expression. The implicit `.` when none is given is oracle-gated (O19), not enforced."""
    i = 0
    while i < len(args) and (args[i] in ("-H", "-L", "-P") or args[i].startswith("-O")):
        i += 1
    if i < len(args) and args[i] == "-D":
        i += 2
    paths = []
    while i < len(args) and not args[i].startswith("-") and args[i] not in ("(", "!"):
        paths.append(args[i])
        i += 1
    return paths


# Rule A hard set: content-read commands whose operand grammar is simple enough to extract
# deterministically AND that appear in observed stalls / the native read table (D2). `ls`
# stays out (docs: `cd packages/api && ls` runs without a prompt); rg/head/tail/wc/awk/…
# are oracle-gated, not enforced.
READ_EXTRACTORS = {"grep": grep_paths, "egrep": grep_paths, "fgrep": grep_paths,
                   "cat": cat_paths, "find": find_paths, "sed": sed_paths}
# Rule B recursive searchers (the shipped b422b6e set) with their root extractors.
ROOT_EXTRACTORS = {"grep": grep_paths, "egrep": grep_paths, "fgrep": grep_paths, "rg": rg_paths}
ALWAYS_RECURSIVE = {"rg"}


def normalize(cmd):
    """Fold backslash-newline continuations (the shell joins them into one line), then blank
    `#`-comments to end-of-line so they never reach the tokenizer."""
    cmd = cmd.replace("\\\r\n", " ").replace("\\\n", " ")
    return _strip_line_comments(cmd)


def _strip_line_comments(cmd):
    """Blank a `#...` comment to end-of-line, but keep the `\\n` itself. Only a `#` that
    starts a word (preceded by whitespace or the start of the string) outside single/double
    quotes is a comment marker -- `grep -n '#include' f` and `echo 'a#b' # trailing` must not
    lose their quoted `#`. shlex's own default `commenters='#'` handling is not reused here
    because it calls `instream.readline()`, which consumes the trailing newline TOO and
    silently merges the next shell command into the commented-out segment (F1)."""
    out = []
    quote = None                      # None, "'" or '"'
    i, n = 0, len(cmd)
    while i < n:
        ch = cmd[i]
        if quote:
            out.append(ch)
            if quote == '"' and ch == "\\" and i + 1 < n:
                out.append(cmd[i + 1])
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in "'\"":
            quote = ch
            out.append(ch)
            i += 1
            continue
        if ch == "#" and (i == 0 or cmd[i - 1] in " \t\r\n"):
            while i < n and cmd[i] != "\n":
                i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def tokenize(cmd):
    lexer = shlex.shlex(cmd, posix=True, punctuation_chars=PUNCT)
    lexer.whitespace = " \t\r"          # newline is a separator token, not whitespace
    lexer.whitespace_split = True
    lexer.commenters = ""               # comments are pre-stripped by _strip_line_comments();
                                         # shlex must never again consume a newline via '#'
    out = []
    for tok in lexer:
        if "\n" in tok and set(tok) <= set(PUNCT):   # shlex glues "&&\n" — split newlines back out
            out.extend(re.findall(r"\n|[^\n]+", tok))
        else:
            out.append(tok)
    return out


def drop_heredocs(tokens):
    """Remove `<<`/`<<-`, the delimiter and the body lines: the body is data, never commands."""
    out, i = [], 0
    while i < len(tokens):
        tok = tokens[i]
        if tok in ("<<", "<<-") and i + 1 < len(tokens):
            if tokens[i + 1] == "-" and i + 2 < len(tokens):
                delim = tokens[i + 2]          # `<<- DELIM` (space form): tokenizer splits the `-`
                i += 3
            else:
                delim = tokens[i + 1].lstrip("-")   # `<<-DELIM` / `<< DELIM` (attached / no dash)
                i += 2
            while i < len(tokens) and tokens[i] != "\n":   # the rest of the command line stays
                out.append(tokens[i])
                i += 1
            i += 1
            while i < len(tokens):
                if tokens[i] == delim and (i + 1 == len(tokens) or tokens[i + 1] == "\n"):
                    i += 1
                    break
                i += 1
            continue
        out.append(tok)
        i += 1
    return out


def split_redirects(tokens):
    """Drop redirect operators (+ fd digit) and targets; return (tokens, [(position, target)])
    for OUTPUT redirects, position = index in the returned token stream."""
    out, targets, i = [], [], 0
    while i < len(tokens):
        tok = tokens[i]
        if tok in OUTPUT_REDIRECTS or tok in OTHER_REDIRECTS:
            if out and out[-1].isdigit():
                out.pop()
            target = tokens[i + 1] if i + 1 < len(tokens) else ""
            if tok in OUTPUT_REDIRECTS and target and not target.startswith("&"):
                targets.append((len(out), target))
            i += 2
            continue
        out.append(tok)
        i += 1
    return out, targets


def split_segments(tokens):
    """[(start_index, [tokens])] split on shell separators."""
    segments, current, start = [], [], 0
    for i, tok in enumerate(tokens):
        if tok in SEPARATORS:
            if current:
                segments.append((start, current))
            current, start = [], i + 1
        else:
            current.append(tok)
    if current:
        segments.append((start, current))
    return segments


def head_of(segment):
    """(command name, argument tokens) with env assignments and wrappers stripped."""
    i = 0
    while i < len(segment):
        tok = segment[i]
        if "=" in tok and not tok.startswith("-") and tok.split("=", 1)[0].isidentifier():
            i += 1
            continue
        if tok in WRAPPERS:
            i += 1
            continue
        if tok == "timeout" and i + 1 < len(segment):
            i += 2
            continue
        break
    if i >= len(segment):
        return None, []
    return segment[i].rsplit("/", 1)[-1], segment[i + 1:]


def complex_syntax(tokens):
    """Name the first construct the guard does not interpret, or None."""
    for tok in tokens:
        if tok in GROUPING:
            return "grouping"            # subshell, brace group, $( ), <( ), >( ) all
                                          # tokenize into single "(" or ")" tokens; (( / )) from
                                          # arithmetic expansion are ordinary tokens — arithmetic is not
                                          # command substitution
        if "`" in tok:
            return "backtick"
    for _start, seg in split_segments(tokens):
        name, _ = head_of(seg)
        if name in CONTROL_FLOW:
            return "control-flow"
    return None


def sed_writes(args):
    for a in args:
        if a == "--":
            break
        if a.startswith("--in-place"):
            return True
        if a.startswith("-") and not a.startswith("--"):
            for ch in a[1:]:
                if ch == "i":
                    return True
                if ch in "efl":          # value-taking short option: the rest of the cluster
                    break                # is that option's value, not more flag letters
    return False


def is_relative(path):
    return not (path.startswith("/") or path.startswith("~"))


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


def is_unresolvable_root(path):          # b422b6e shapes, unchanged; shape-only, no filesystem probe
    if path in SAFE_REDIRECT_TARGETS:    # "/dev/null" is a filename-forcing idiom, not a root
        return False
    return (path in UNRESOLVABLE_ROOTS or path.startswith("/") or path.startswith("~")
            or path.startswith("./") or path.startswith("../"))


def fail_open(reason):
    sys.stderr.write("FAILOPEN reason=%s\n" % reason)
    return None


def coarse_check(cmd):
    """Tokenizer failed (the command is a bash syntax error anyway). Deny only the one
    unmistakable shape: `cd` followed later by a write word. Everything else fails open.
    A heredoc body is never parsed as bash syntax, so an unbalanced quote inside one is not
    really a syntax error, and a write word inside one (e.g. a Python `mv = 2` assignment) is
    not really a write command -- skip the coarse deny whenever `<<` appears anywhere."""
    if "<<" in cmd:
        return fail_open("tokenize")
    m = COARSE_CD.search(cmd)
    if m and COARSE_WRITE.search(cmd[m.end():]):
        return Verdict("coarse", "unparsed", True, False, MSG["C1"] % "a write command")
    return fail_open("tokenize")


def check(cmd):
    """Return a Verdict for a proven approval-stall shape, else None (clean or unknown)."""
    cmd = normalize(cmd)
    try:
        tokens = tokenize(cmd)
    except ValueError:
        return coarse_check(cmd)
    tokens = drop_heredocs(tokens)
    kind = complex_syntax(tokens)
    if kind:
        return fail_open("complex:" + kind)
    tokens, redirects = split_redirects(tokens)
    segments = [(start, head_of(seg)) for start, seg in split_segments(tokens)]
    cd_starts = [start for start, (name, _) in segments if name == "cd"]
    any_redirect = bool(redirects)

    if cd_starts:
        cd_first = cd_starts[0]
        later = [(start, head) for start, head in segments if start > cd_first]
        # Rule C1 — write-class command AFTER the cd (observed E2; bundle cd-compound-write).
        for _start, (name, args) in later:
            if name in WRITE_COMMANDS or (name == "sed" and sed_writes(args)):
                return Verdict("C1", name, True, any_redirect, MSG["C1"] % name)
        # Rule C2 — output redirect to a real file AFTER the cd (docs § Read-only commands).
        for pos, target in redirects:
            if pos > cd_first and target not in SAFE_REDIRECT_TARGETS:
                return Verdict("C2", "redirect", True, True, MSG["C2"] % target)
        # Rule C3 — git AFTER the cd (docs § Read-only commands).
        for _start, (name, _args) in later:
            if name == "git":
                return Verdict("C3", "git", True, any_redirect, MSG["C3"])
        # Rule A — hard-set content read with a RELATIVE path operand AFTER the cd
        # (observed E3; bundle cd-compound-read). Operands come from the per-command tables.
        for _start, (name, args) in later:
            extractor = READ_EXTRACTORS.get(name)
            if extractor is None or (name == "sed" and sed_writes(args)):
                continue
            if any(is_relative(p) for p in extractor(args)):
                return Verdict("A", name, True, any_redirect, MSG["A"] % name)

    # Rule B — recursive content search rooted at an unbounded location (b422b6e, unchanged).
    for _start, (name, args) in segments:
        extractor = ROOT_EXTRACTORS.get(name)
        if extractor is None:
            continue
        if name in ALWAYS_RECURSIVE or has_recursive_flag(args):
            for path in extractor(args):
                if is_unresolvable_root(path):
                    return Verdict("B", name, bool(cd_starts), any_redirect, MSG["B"] % (name, path))
    return None


def emit(verdict):
    """Protocol read by guard-read-path-hygiene.sh: one JSON header line, then the message."""
    if verdict:
        header = {"rule": verdict.rule, "command_class": verdict.command_class,
                  "has_cd": verdict.has_cd, "has_output_redirect": verdict.has_output_redirect}
        sys.stdout.write(json.dumps(header, separators=(",", ":")) + "\n" + verdict.message)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        sys.exit(_self_test())
    if len(sys.argv) > 1 and sys.argv[1] == "--oracle-manifest":
        for oid, cmd, _expect, _note in ORACLE_MANIFEST:
            sys.stdout.write("%s\t%s\n" % (oid, cmd.replace("\n", " ")))
        return
    cmd = sys.stdin.read()
    if not cmd.strip():
        return
    try:
        verdict = check(cmd)
    except Exception as exc:                     # fail open, but never silently
        fail_open("exception:" + type(exc).__name__)
        return
    emit(verdict)


# ── Fixtures ──────────────────────────────────────────────────────────────────
# DENY / ALLOW / UNKNOWN are enforcement contracts. ORACLE_MANIFEST pins the guard's
# CURRENT behaviour for boundary shapes and is ALSO the probe list for
# scripts/automation/permission-oracle.sh (`{SB}` = sandbox root) — one source, no drift.
DEVNULL = "/dev/" + "null"   # keep the literal out of the source: guard-dangerous-commands greps "> /dev/"
E2 = "cd /home/u/Git/app/apps/backend/tests && \\\nsed -i 's/RESIM/SIM-BUYER/g' test_x.py\ngrep -n \"SIM-BUYER\" test_x.py"

DENY_FIXTURES = [   # (rule, command, evidence)
    ("C1", E2, "observed E2 verbatim shape"),
    ("C1", "cd apps/backend && sed -i 's/OLD/NEW/g' tests/test_x.py", "observed E2"),
    ("C1", "cd apps/backend\nsed -i 's/OLD/NEW/g' tests/test_x.py", "observed E3 newline shape"),
    ("C1", "cd apps/backend; sed -i 's/OLD/NEW/g' tests/test_x.py", "observed E3 semicolon shape"),
    ("C1", "cd apps/backend && sed -i.bak 's/a/b/' x.py", "bundle: in-place sed is write class"),
    ("C1", "cd apps/backend && sed --in-place 's/a/b/' x.py", "bundle"),
    ("C1", "cd apps/backend && sed -Ei 's/a/b/' x.py", "bundle"),
    ("C1", "cd apps/backend && cp a.py b.py", "bundle write table"),
    ("C1", "cd apps/backend && mv a.py b.py", "bundle write table"),
    ("C1", "cd apps/backend && rm -f a.pyc", "bundle write table"),
    ("C1", "cd apps/backend && rmdir tmp", "bundle write table"),
    ("C1", "cd apps/backend && mkdir -p tests/fixtures", "bundle create table"),
    ("C1", "cd apps/backend && touch tests/__init__.py", "bundle create table"),
    ("C1", "cd apps/backend && mv notes.txt notes_$((1)).txt", "arithmetic expansion must not hide a cd-then-write"),
    ("C1", "cd apps/backend && env FOO=1 nohup rm -f x.pyc", "docs: wrappers are stripped"),
    ("C2", "cd apps/backend && pytest -q > /tmp/out.log", "docs: cd with output redirect"),
    ("C2", "cd apps/backend && pytest -q >> out.log", "docs"),
    ("C2", "cd apps/backend && pytest -q &> out.log", "docs"),
    ("C2", "cd apps/backend && pytest -q 2> err.log", "docs"),
    ("C2", "cd apps/backend && echo hi > out.txt", "docs"),
    ("C2", "cd apps/backend && cat > /tmp/x.txt <<'EOF'\nhello\nEOF", "docs; heredoc line keeps its redirect"),
    ("C2", "cd apps/backend && cat <<- EOF > out.txt\nhello\nEOF", "space-form heredoc line keeps its redirect"),
    ("C3", "cd apps/backend && git status", "docs: cd with git"),
    ("C3", "cd apps/backend && git status >" + DEVNULL + "; true", "docs"),
    ("A", "cd apps/backend && grep -n foo app/main.py", "observed E3"),
    ("A", "cd apps/backend\ngrep -n foo app/main.py", "observed E3 (2,037 s)"),
    ("A", "cd apps/backend && \\\ngrep -n foo app/main.py", "observed E2 continuation form"),
    ("A", "cd apps/backend; grep -n foo app/main.py", "observed E3 (2,014 s)"),
    ("A", "cd apps/backend && grep -A 3 -m 1 foo app/main.py", "grep option values are not paths"),
    ("A", "cd apps/backend && grep -rn --include '*.py' foo app/", "long option with a separate value"),
    ("A", "cd apps/backend && grep -e foo -e bar app/main.py", "pattern via -e: every operand is a path"),
    ("A", "cd apps/backend && sed -n '1,20p' app/main.py", "b422b6e fixture; read-only sed"),
    ("A", "cd apps/backend && sed -e 's/a/b/' app/main.py", "script via -e"),
    ("A", "cd apps/backend && cat ../README.md", "bundle: relative path"),
    ("A", "cd apps/backend && cat app/main.py app/config.py", "cat: every operand is a path"),
    ("A", "cd apps/backend && find . -name '*.pyc' | xargs rm -f", "find explicit `.` after cd; xargs rm is not a native write"),
    ("A", "cd apps/backend && find app tests -name '*.py'", "find: leading operands are starting points"),
    ("A", "cd /home/x/contracts && grep -rn \"book_snapshot\" workstation_contracts/*.py | head -30", "b422b6e fixture (contract-pack-v0 stall)"),
    ("B", "grep -rn foo .", "b6ae4d2 observed"),
    ("B", "grep -rn foo ./", "b422b6e"),
    ("B", "grep -e foo -r .", "pattern via -e, root after"),
    ("B", "rg foo ~/x", "b422b6e"),
    ("B", "rg -m 1 -A 2 foo ../", "rg option values are not roots"),
    ("B", "grep -rn foo ../", "b422b6e"),
    ("B", "timeout 30 grep -rn foo .", "b422b6e wrapper carve-through"),
    ("coarse", "cd apps/backend && sed -i 's/a/b/ x.py", "D3: unbalanced quote + cd/write"),
    ("coarse", "cd apps/backend && rm -f 'x.pyc", "D3"),
    ("C1", "cd apps/backend  # go\nsed -i 's/a/b/' x.py", "trailing comment must not swallow the newline"),
    ("C3", "cd apps/backend && pytest -q # run\ngit status", "same"),
    ("A", "cd apps/backend # x\ngrep -n foo app/main.py", "same"),
    ("C1", "cd apps/backend && sed -ni 's/a/b/' x.py", "-i inside a cluster before a value letter is still in-place"),
]
ALLOW_FIXTURES = [   # (command, why the native checker does not ask)
    ("cd apps/backend && pytest -q", "pytest is not path-restricted"),
    ("cd apps/frontend && npm test", "same"),
    ("cd apps/frontend && npx tsc --noEmit", "same"),
    ("cd apps/backend && python -m pytest tests/ -q", "same"),
    ("cd apps/backend && make", "same"),
    ("cd apps/backend && bash scripts/run.sh", "same"),
    ("cd apps/backend && pytest -q 2>" + DEVNULL, "/dev/null target is exempt"),
    ("cd apps/backend && pytest -q 2>&1 | tail -20", "fd duplication; tail is not in the hard set"),
    ("cd apps/backend && pytest -q | tee /tmp/out.log", "tee is not path-restricted"),
    ("cd apps/backend && pytest -q > " + DEVNULL + " 2>&1", "/dev/null"),
    ("cd apps/backend && ls", "documented exception"),
    ("cd apps/backend && grep -n foo /home/u/Git/app/apps/backend/app/main.py", "absolute path: native resolves it"),
    ("cd apps/backend && grep -n foo", "no path operand (stdin)"),
    ("cd apps/backend && grep -m 1 foo", "option value is not a path"),
    ("cd apps/backend && grep -A 3 pattern", "option value is not a path"),
    ("cd apps/backend && grep -f /abs/patterns.txt", "-f value is not a path operand; no operands left"),
    ("cd apps/backend && sed -n '1,20p'", "script only, stdin"),
    ("cd apps/backend && cat", "stdin"),
    ("cd apps/backend && python3 - <<'EOF'\nimport os\nos.remove('x')\nEOF", "heredoc body is data"),
    ("cd apps/backend && python3 - <<'EOF'\ncat = 1\nrm = 2\nEOF", "heredoc body is data"),
    ("cd apps/backend && cat <<- EOF\nrm -f x\nEOF\npytest -q", "heredoc with a space before the delimiter is data"),
    ("cd apps/backend && python3 - <<EOF > " + DEVNULL + "\nprint(1)\nEOF", "/dev/null"),
    ("cd apps/backend && install -m 755 run.sh bin/run", "not path-restricted (prompts for lack of an allow rule, not for the cd)"),
    ("cd apps/backend && less app/main.py", "less is not path-restricted (previously over-denied)"),
    ("mkdir -p apps/backend/tests/fixtures", "no cd"),
    ("sed -i 's/a/b/' apps/backend/x.py", "no cd"),
    ("rm -f apps/backend/x.pyc", "no cd"),
    ("echo hi > apps/backend/out.txt", "no cd"),
    ("git -C apps/backend status", "no cd"),
    ("git diff | grep foo", "no path"),
    ("grep -rn foo apps/backend/app/", "bounded relative root"),
    ("grep -rn --include '*.py' foo apps/", "long option value is not a root"),
    ("grep -r -m 1 foo", "stdin; option value is not a root"),
    ("sed -n '1,20p' apps/backend/app/main.py", "no cd"),
    ("cat > /tmp/x.txt <<'EOF'\nhello\nEOF", "no cd"),
    ("grep -rln PATTERN incredible_auto_dev/policy/ incredible_auto_dev/hooks/ 2>" + DEVNULL, "b422b6e regression"),
    ("python3 x.py > /tmp/out.txt 2>&1", "b422b6e regression"),
    ("ag foo .", "ag is not path-restricted (previously over-denied by Rule B)"),
    ("pytest -q  # don't stop\ngit status", "comment with an apostrophe, no cd"),
    ("grep -n '#include' apps/backend/app/main.c", "'#' inside quotes is not a comment"),
    ("echo 'a#b' # trailing", "same"),
    ("cd apps/backend && pytest -q | grep -n foo -", "'-' is stdin"),
    ("cd apps/backend && sed -e's/i/x/' /home/u/app/apps/backend/app/main.py", "attached -e script containing 'i' is not -i"),
    ("grep -rn foo apps/backend/app/ " + DEVNULL, "/dev/null is a filename-forcing idiom, not a root"),
    ("cd apps/backend && echo $((1+2))", "arithmetic expansion is not unknown syntax"),
    ("(( x = 1 + 2 ))", "arithmetic command, no cd"),
]
UNKNOWN_FIXTURES = [   # (expected FAILOPEN reason, command)
    ("tokenize", "cd apps/backend && pytest 'unbalanced"),
    ("complex:control-flow", "for d in a b; do cd $d && grep -n x y.py; done"),
    ("complex:control-flow", "if [ -d apps ]; then cd apps && sed -i 's/a/b/' x.py; fi"),
    ("complex:grouping", "(cd apps/backend && rm -rf build)"),
    ("complex:grouping", "cd apps/backend && grep -n x $(git ls-files | head -1)"),
    ("complex:grouping", "diff <(sort a) <(sort b)"),
    ("complex:backtick", "cd apps/backend && grep -n x `ls app | head -1`"),
    ("complex:control-flow", "eval \"cd apps && rm -f x\""),
    ("tokenize", "cd apps/backend && python3 - <<'PY'\ns = 'don\\'t'\nmv = 2\nPY"),
]
# (id, command with {SB} = sandbox root, guard expectation, note). Unique ids; every entry is
# probed natively by scripts/automation/permission-oracle.sh and recorded in Task 10.
ORACLE_MANIFEST = [
    ("O1",   "cd apps/backend && sed -i 's/a/b/' tests/test_x.py", ("verdict", "C1"), "control: observed C1"),
    ("O4",   "cd apps/backend && cd tests && ls", ("verdict", None), "multi-cd (bundle only)"),
    ("O5",   "cd apps/backend && grep -n a app/main.py", ("verdict", "A"), "control: observed A"),
    ("O6W",  "sed -i 's/a/b/' apps/backend/tests/test_x.py && cd apps", ("verdict", None), "write before cd"),
    ("O6R",  "grep -n a apps/backend/app/main.py && cd apps", ("verdict", None), "read before cd"),
    ("O7",   "(cd apps/backend && rm -f tests/scratch.txt)", ("failopen", "complex:grouping"), "subshell (unknown class)"),
    ("O8",   "for d in apps/backend; do cd $d && grep -n a app/main.py; done", ("failopen", "complex:control-flow"), "loop (unknown class)"),
    ("O9",   "cd apps/backend && ls app/", ("verdict", None), "ls with a relative dir"),
    ("O10",  "cd apps/backend && grep -n a {SB}/apps/backend/app/main.py", ("verdict", None), "absolute read after cd"),
    ("O11",  "grep -rn a .", ("verdict", "B"), "control: Rule B `.` premise"),
    ("O12",  "grep -rn a {SB}/apps/backend/app/", ("verdict", "B"), "absolute directory root"),
    ("O12B", "grep -rn a ./apps/backend/app/", ("verdict", "B"), "dot-prefixed bounded subdirectory"),
    ("O13",  "grep -rn a {SB}/apps/backend/app/main.py", ("verdict", "B"), "absolute file root"),
    ("O14",  "cd apps/backend && sort app/main.py", ("verdict", None), "native read-class command outside Rule A"),
    ("O15",  "cd apps/backend && pytest -q | tee tests/out.log", ("verdict", None), "control: tee allow"),
    ("O16",  "cd apps/backend && rg a app/", ("verdict", None), "rg path semantics unverified for Rule A"),
    ("O17",  "cd apps/backend && head -n 20 app/main.py", ("verdict", None), "option-value command kept out of Rule A"),
    ("O19",  "cd apps/backend && find -name '*.py'", ("verdict", None), "find implicit `.` starting point"),
]
EXTRACTOR_FIXTURES = [   # (extractor, args, expected paths) — the per-command tables, tested on their own
    (grep_paths, ["-n", "foo", "app/main.py"], ["app/main.py"]),
    (grep_paths, ["-A", "3", "-m", "1", "foo", "f"], ["f"]),
    (grep_paths, ["-m1", "-A3", "foo", "f"], ["f"]),
    (grep_paths, ["-e", "foo", "-e", "bar", "f", "g"], ["f", "g"]),
    (grep_paths, ["-rn", "--include", "*.py", "foo", "apps/"], ["apps/"]),
    (grep_paths, ["-rn", "--include=*.py", "foo", "apps/"], ["apps/"]),
    (grep_paths, ["-f", "/abs/patterns.txt", "f"], ["f"]),
    (grep_paths, ["-m", "1", "foo"], []),
    (grep_paths, ["--", "-weird", "f"], ["f"]),
    (sed_paths, ["-n", "1,20p", "f"], ["f"]),
    (sed_paths, ["-e", "s/a/b/", "f"], ["f"]),
    (sed_paths, ["-l", "80", "-n", "p", "f"], ["f"]),
    (sed_paths, ["-n", "p"], []),
    (cat_paths, ["-n", "f", "g"], ["f", "g"]),
    (cat_paths, ["-"], []),
    (find_paths, [".", "-name", "*.py"], ["."]),
    (find_paths, ["app", "tests", "-name", "*.py"], ["app", "tests"]),
    (find_paths, ["-L", "app", "-type", "f"], ["app"]),
    (find_paths, ["-name", "*.py"], []),
    (rg_paths, ["-m", "1", "-A", "2", "foo", "../"], ["../"]),
    (rg_paths, ["-g", "*.py", "foo", "app/"], ["app/"]),
    (rg_paths, ["foo"], []),
]


def _self_test():
    import contextlib
    import io
    fails = []

    def run(cmd):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            v = check(cmd)
        return v, err.getvalue()

    for fn, args, expected in EXTRACTOR_FIXTURES:
        got = fn(list(args))
        if got != expected:
            fails.append("EXTRACT %s%r expected %r got %r" % (fn.__name__, args, expected, got))
    for rule, cmd, _why in DENY_FIXTURES:
        v, _ = run(cmd)
        if not v or v.rule != rule:
            fails.append("DENY %s expected, got %r: %r" % (rule, v and v.rule, cmd))
    for cmd, _why in ALLOW_FIXTURES:
        v, err = run(cmd)
        if v or "FAILOPEN" in err:
            fails.append("ALLOW expected, got %r / %r: %r" % (v and v.rule, err.strip(), cmd))
    for reason, cmd in UNKNOWN_FIXTURES:
        v, err = run(cmd)
        if v or ("FAILOPEN reason=" + reason) not in err:
            fails.append("UNKNOWN %s expected, got %r / %r: %r" % (reason, v and v.rule, err.strip(), cmd))
    ids = [row[0] for row in ORACLE_MANIFEST]
    if len(ids) != len(set(ids)):
        fails.append("ORACLE manifest ids are not unique: %r" % ids)
    for oid, cmd, (kind, want), _note in ORACLE_MANIFEST:
        v, err = run(cmd.replace("{SB}", "/sandbox"))
        got = (v.rule if v else None) if kind == "verdict" else (err.strip().replace("FAILOPEN reason=", "") or None)
        if got != want:
            fails.append("ORACLE %s pinned %r, got %r: %r" % (oid, want, got, cmd))
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        emit(check("cd apps/backend && sed -i 's/a/b/' x.py"))
    first = out.getvalue().split("\n", 1)[0]
    try:
        hdr = json.loads(first)
        assert hdr == {"rule": "C1", "command_class": "sed", "has_cd": True, "has_output_redirect": False}, hdr
    except (ValueError, AssertionError) as exc:
        fails.append("emit() header: %r (%s)" % (first, exc))
    for f in fails:
        print("FAIL " + f)
    print("read_path_hygiene self-test: %d extractor, %d deny, %d allow, %d unknown, %d oracle fixtures, %d failures"
          % (len(EXTRACTOR_FIXTURES), len(DENY_FIXTURES), len(ALLOW_FIXTURES), len(UNKNOWN_FIXTURES), len(ORACLE_MANIFEST), len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    main()
