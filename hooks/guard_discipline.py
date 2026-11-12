"""Guard of the irreversible.

Destructive acts on the working tree, secret egress, wiring of the guard itself.

What this hook does and does NOT do
────────────────────────────────────
It sits on PreToolUse and judges ONLY Bash. The write tools (Edit/Write/NotebookEdit) are held by a
single harness `deny`: that fires before the hook and is not lifted by the owner's key, so a second
rule over the same paths would mean two truths about one thing. The Bash layer stays because deny
does not see `sed -i`, `echo >` or `cp`.

The write tools carry a NEIGHBOUR — the advisor `write_advice.py`. It judges no paths and cannot
cancel a call: its subject is the kind of file being edited and the skill for it. This creates no
two truths about one thing, because the questions differ: the guard owns the right to write, the
advisor the choice of tool for the work.

So a `protected` path is closed exactly as far as a FOREIGN registry closed it, and the hook does
not know this: with no `Edit(path)` rule the path is open to every write tool, and the guard will
not notice. Whether the registries agree is judged by the gate step `deny_sync`
(`bin/retainer-deny-sync.sh`), which also names the missing rule. Here it is an assumption, not a
property.

Four rules:

* **new dependency** — a command adding a package via a language package manager: the project must
maintain it, and
  so this is the owner's decision, not the agent's; the `guard_dependency` regulator is on by
  default;
* **destructive act** — `rm -rf`, `dd`, `git reset --hard`, force-push and the like, which destroy
work without a
  trace; enabled by `guard_destructive` in the project config;
* **secret egress** — a command reads a secret file and sends it to an external host, or pulls code
  from an unsafe source straight into the shell; enabled by `guard_egress`;
* **the guard's own wiring** — a write to `~/.claude/settings.json`, `~/.claude/hooks` (and the
  same two under `CLAUDE_CONFIG_DIR` when it is set) and the registry of
  managed repositories: editing them turns protection off silently, and there is no way to find
  out.

There are no procedural rules here: no task-cycle steps, no merge lock, no review attestations, no
rollback
of what was written, no repeat counting, no comment parsing. The `.retainer/bypass.log` journal is
written as
before — it is an observation, no tasks are filed from it.

The repository is determined BY PATH: from cwd the hook climbs up until it finds
`<repo>/.retainer/config.toml`, and takes the rules FROM THAT config. One hook serves several
projects at once. The key (`unlock`) is issued by the owner in their terminal.
"""

from __future__ import annotations

import contextlib
import json
import os
import re
import shlex
import sys
import time
import types
from pathlib import Path
from typing import Any

# Parsed config.toml: values are heterogeneous (string / list of strings / bool) — the honest type
# is `Any`.
Config = dict[str, Any]


def _join(*parts: str) -> str:
    """Build a regex from named parts without `+` concatenation (one string.

    Not a set of meanings).
    """
    return "".join(parts)


# The hook runs under the system python3 (on macOS 3.9, without tomllib). So depending on tomllib
# is not allowed, otherwise the guard silently crashes under the very interpreter that calls it
# (exactly the
# class "recorded as working — does not work"). With tomllib (3.11+) we use it; without it, or
# when it rejects the file — a minimal parser for our format (string values and flags, arrays
# skipped, everything up to the first [table]).
_HAVE_TOMLLIB = sys.version_info >= (
    3,
    11,
)  # tomllib is stdlib since 3.11, no separate probe needed
if _HAVE_TOMLLIB:
    import tomllib


# Escapes defined by the format. Anything not here makes the string INVALID: returning
# a stub would mean understanding the same file differently than the runner understands it.
_BACKSLASH = "\\"
_ESCAPES = types.MappingProxyType(
    {
        "b": "\b",
        "f": "\f",
        "n": "\n",
        "t": "\t",
        "r": "\r",
        '"': '"',
        _BACKSLASH: _BACKSLASH,
    }
)
# Numeric forms: \uXXXX and \UXXXXXXXX. The length is part of the form, so it is paired with the
# key.
_UNICODE_ESCAPES = types.MappingProxyType({"u": 4, "U": 8})
_HEX_BASE = 16
_MAX_POINT = 0x10FFFF
_SURROGATE_LOW = 0xD800
_SURROGATE_HIGH = 0xDFFF
# Fences of the multiline value form.
_FENCES = ('"""', "'''")


def _parse_scalar(rhs: str) -> str:
    """Value of a scalar key — the same subset of forms the runner reads.

    A hash inside quotes is part of the value, not the start of a comment. An escaped quote does
    not
    end the value. A bare value is returned as is: boolean flags are written exactly so.
    """
    text = rhs.strip()
    for fence in _FENCES:
        if text.startswith(fence):
            return _fenced(text, fence)
    if text.startswith("'"):
        end = text.find("'", 1)
        return text[1:end] if end > 0 else ""
    if text.startswith('"'):
        return _drop_multiline(_unquote(text))
    # A bare value (`true`, `42`) is returned AS IS: the guard's boolean flags arrive exactly
    # so, and the trailing comment is cut by `_flag` itself. The runner answers emptiness on a
    # non-string —
    # it needs only string values; here emptiness would take from the owner the OFF switch:
    # `_flag` reads the decision to turn off only from an explicit `false`, and an unread value
    # leaves the gate ON.
    return text


def _fenced(text: str, fence: str) -> str:
    """Content of a multiline value form closed on the same line; otherwise empty."""
    end = text.find(fence, len(fence))
    return text[len(fence) : end] if end > 0 else ""


def _drop_multiline(declared: str) -> str:
    """A value with a line break is empty: a line-by-line parse cannot assemble it."""
    return "" if "\n" in declared else declared


def _unquote(text: str) -> str:
    """A double-quoted string with escapes removed; unclosed — empty.

    An unclosed quote and an unknown escaped form are a broken string: the real parse on it
    fails the file, and a stub here would mean two understandings of one file.
    """
    out: list[str] = []
    idx = 1
    while idx < len(text):
        char = text[idx]
        if char == _BACKSLASH:
            piece, idx = _escape(text, idx)
            if piece is None:
                return ""
            out.append(piece)
            continue
        if char == '"':
            return "".join(out)
        out.append(char)
        idx += 1
    return ""


def _escape(text: str, idx: int) -> tuple[str | None, int]:
    """Escaped sequence and the position after it; None — the form is invalid."""
    after = idx + 2
    simple = _ESCAPES.get(text[idx + 1 : after])
    if simple is not None:
        return (simple, after)
    width = _UNICODE_ESCAPES.get(text[idx + 1 : after])
    if width is None:
        return (None, after)
    return _codepoint(text[after : after + width], width, after)


def _codepoint(digits: str, width: int, after: int) -> tuple[str | None, int]:
    """A character by hexadecimal notation; None — the form is invalid.

    The VALUE is judged too: beyond the range there is no character at all, in a surrogate pair it
    is single and
    unfit for text. The real parse rejects such a record entirely, and a stub instead of a refusal
    would give two understandings of one file.
    """
    # `isascii` and `isalnum` cut off the sign, spaces and non-ASCII digits — everything `int`
    # would silently
    # accept or fail on differently; the rest is judged by the parse itself.
    shaped = digits.isascii() and digits.isalnum()
    if len(digits) != width or not shaped:
        return (None, after)
    try:
        point = int(digits, _HEX_BASE)
    except ValueError:
        return (None, after)
    surrogate = _SURROGATE_LOW <= point <= _SURROGATE_HIGH
    if point > _MAX_POINT or surrogate:
        return (None, after)
    return (chr(point), after + width)


# The sign "config not parsed" travels inside the parsed dict under a key the line parse cannot
# produce: its keys never hold a line break. A file declaring that key as a quoted key is refused,
# which fails closed. The value is the line of the construct that never closed, `0` for a file
# not in UTF-8.
_UNPARSED_KEY = "\nunparsed"


def _collect_array(first: str, lines: list[str], idx: int) -> tuple[int, bool]:
    """Skip a TOML array (possibly multiline) from `first` to `]`; return (idx, closed).

    The elements are not read. The skip itself carries the load — without it the lines of an array
    are read as `key = value`. An array that reaches the end of the text without `]` is not valid
    TOML, and every key after its opener is lost.
    """
    array_text = first
    while "]" not in array_text and idx < len(lines):
        array_text = f"{array_text} {lines[idx]}"
        idx += 1
    return idx, "]" in array_text


def _skip_fenced(rhs: str, lines: list[str], idx: int) -> tuple[int, bool]:
    """Skip the lines of a multiline value; return (idx after its closer, closed).

    A fence counts only at the START of a value: a fence inside a trailing comment opens nothing.
    The content of a multiline value is not read as `key = value`, and a value that reaches the end
    of the text without its closer is not valid TOML.
    """
    fence = next((mark for mark in _FENCES if rhs.startswith(mark)), "")
    if not fence or rhs.find(fence, len(fence)) >= 0:
        return idx, True
    for pos, text in enumerate(lines[idx:], start=idx):
        if fence in text:
            return pos + 1, True
    return len(lines), False


def _parse_kv(config: Config, line: str, lines: list[str], idx: int) -> int:
    """Parse `key = value` into config; return the new idx.

    `idx` on entry is the number of this line counted from one. An array is stored as an empty
    list: the type is kept, so a flag written as an array keeps its gate on and a key address falls
    to the default, as on the real parser.
    """
    if "=" not in line:
        return idx
    key, _, rhs = line.partition("=")
    key, rhs = key.strip(), rhs.strip()
    if not key:
        return idx
    if rhs.startswith("["):
        config[key] = []
        after, closed = _collect_array(rhs, lines, idx)
    else:
        config[key] = _parse_scalar(rhs)
        after, closed = _skip_fenced(rhs, lines, idx)
    if not closed:
        config[_UNPARSED_KEY] = idx
    return after


def _parse_config_fallback(text: str) -> Config:
    """Minimal parse for our format, everything up to the first [table].

    The sign "config not parsed" is set only by a construct that opens and never closes — the one
    error that loses the keys after it. An empty result, an empty value and a fence found as a
    substring all occur in valid configs, so none of them is a sign.

    Lines are split on the line feed only: `splitlines` also breaks on U+0085, U+2028 and U+2029,
    which TOML allows inside a comment or a string, and a split there can open a false construct.

    Not observable, by decision: a line with no `=` loses its own key, and a nested multiline array
    stops at its first `]`, so the keys after it are lost here while the real parser reads them.
    An early stop is not observable either: a `]` inside a string or a comment of an array, or an
    escaped closer inside a multiline value, ends the construct early and its rest is read as keys.
    """
    config: Config = {}
    lines = text.split("\n")
    idx = 0
    while idx < len(lines):
        line = lines[idx].strip()
        idx += 1
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):  # [tables] began — the needed top-level keys have already passed
            break
        idx = _parse_kv(config, line, lines, idx)
    return config


def _parse_config(text: str) -> Config:
    """Parsed config.toml.

    The real parser rejects a file on a syntax error anywhere in it, and an empty answer would turn
    every opt-in gate off. So a rejected file is read by the line parse, the path the system python
    takes anyway: on a broken file both interpreters give one verdict. A rejection is any
    `ValueError`: an integer past the interpreter's digit limit is not a `TOMLDecodeError`. Nesting
    past the recursion limit still crashes the hook — named, not solved.
    """
    if not _HAVE_TOMLLIB:
        return _parse_config_fallback(text)
    try:
        return tomllib.loads(text)
    except ValueError:
        return _parse_config_fallback(text)


HOME = Path.home()
_UNLOCK_TTL_MINUTES = 30
_SECONDS_PER_MINUTE = 60
UNLOCK_TTL_SECONDS = _UNLOCK_TTL_MINUTES * _SECONDS_PER_MINUTE
# How many characters of a command to write to the bypass journal. The limit is generous on
# purpose: the journal is
# the only corpus by which a false positive is told from a real one, and too
# tight a clip invalidates that conclusion in BOTH directions — the command is cut
# in the middle, a tail with the destructive act does not reach the record, and a head without it
# does not
# reproduce the block.
_JOURNAL_DETAIL_MAX = 4000
_JOURNAL_CLIP_MARK = "…[truncated, {total} chars total]"

# Names/keys of the discipline layout — in constants (one point of truth, not a smeared literal).
_RETAINER = ".retainer"
_CONFIG_NAME = "config.toml"
_BYPASS_LOG = "bypass.log"
_COMMENT_MARK = "#"
_BOOL_WORDS = frozenset(("true", "false"))
_UNLOCK_KEY = "unlock_file"
_DEFAULT_UNLOCK = f"{_RETAINER}/unlock"

# File reading encoding: the literal was repeated at the threshold, and diverged values would give
# a different
# parse of one and the same file in different places.
_ENC = "utf-8"

# GLOBAL SELF-PROTECTION. The guard's own wiring lies OUTSIDE managed repositories
# (~/.claude/settings.json registers the hook; ~/.claude/hooks — user-level hooks).
# The project-aware model finds rules by repo, and these files are not in a repo — so without
# separate protection the guard itself can be silently turned off via a settings.json edit. The
# hole is
# closed: these paths are protected ALWAYS, regardless of repository. Own global key — and the
# key itself is in the set: a key the agent could write would lift everything else.
GLOBAL_UNLOCK = HOME / _RETAINER / "unlock"
# Registry of managed repos: the owner registers a repo by an abs-path line in THEIR terminal;
# the guard snapshots the protected files of ALL of them on every Bash. env override — for tests.
# In GLOBAL_PROTECTED: the agent does not de-register.
MANAGED_REGISTRY = Path(
    os.environ.get("RETAINER_MANAGED_REGISTRY")
    or str(HOME / ".config" / "retainer" / "managed-repos")
)
# The harness reads its settings from `CLAUDE_CONFIG_DIR` when that is set. Both directories are
# protected: a session started without the variable still reads `~/.claude`.
_CONFIG_ENV = "CLAUDE_CONFIG_DIR"
_CLAUDE_DIR_SOURCES = (str(HOME / ".claude"), os.environ.get(_CONFIG_ENV, ""))
_CLAUDE_DIRS = tuple(dict.fromkeys(Path(raw) for raw in _CLAUDE_DIR_SOURCES if raw))
GLOBAL_PROTECTED = (
    *(claude_dir / name for claude_dir in _CLAUDE_DIRS for name in ("settings.json", "hooks")),
    MANAGED_REGISTRY,
    GLOBAL_UNLOCK,
)
# Plugin manager service area: it holds engine COPIES, and each carries its own
# `.retainer/config.toml`. Climbing to a config recognized a copy as a managed repository, and a
# stale
# snapshot protected ITSELF from cleanup: `rm -rf` of a displaced version wiped the unprotected and
# rolled back
# the protected, leaving a shell. There is nothing to protect there — a copy does not execute
# discipline:
# the installed version does, and in the directory layout `${CLAUDE_PLUGIN_ROOT}` resolves
# to the engine working tree itself. The tree itself lies OUTSIDE the cache and is protected as
# before.
PLUGIN_CACHE = HOME / ".claude" / "plugins" / "cache"

BLOCK = 2  # PreToolUse/PostToolUse: code 2 cancels the call, stderr goes to the agent
# Guard-probe mode (selfcheck_guard.py): the block/pass decision is issued NORMALLY, but WITHOUT
# side effects (_snapshot/_backup) — otherwise a "reading" probe would run backup_command
# and trim the shared snapshot.
_PROBE_ENV = "RETAINER_GUARD_PROBE"
# Probe marker in a journal record. Read by THREE consumers (the guard on dedup, the threshold
# alert,
# task auto-filing), so the field name is one point of truth, not a literal in each.
_PROBE_FIELD = "probe"
_PROBE = os.environ.get(_PROBE_ENV) == "1"

# Destructive commands. Opt-in: `guard_destructive = true` (or legacy `guard_git = true`).
# A plain `git push` and a single `rm file`/`rm -f file` are NOT touched — only irreversible scale.
# The git verb is bound to a subcommand (so `commit -m "reset --hard"` does not fire); rm — to the
# COMMAND
# POSITION (start/separator/sudo|do…), not to text in quotes, otherwise "rm -rf" in a commit
# message
# was falsely cut (lesson: exact patterns, not -f/rm substrings).
# [^|;&\n] — the match does not stretch across line breaks.
# git with optional global flags, before the subcommand. Flags that TAKE AN ARGUMENT (`-C <path>`,
# `-c a=b`, `--git-dir <path>`) are listed separately: otherwise `(?:-\S+\s+)*` ate `-C`, and the
# path
# after it was read as the subcommand, and `git -C <path> reset --hard` went past the gate.
_GIT_ARG_FLAG = r"(?:-c|-C|--git-dir|--work-tree|--namespace|--exec-path)(?:=\S+|\s+\S+)"
_GIT = _join(r"\bgit\s+(?:", _GIT_ARG_FLAG, r"\s+|-\S+\s+)*")
# Characters by which a command position is recognized. Inside quotes they are data: an alternation
# in a
# search pattern is not a command launch, and EXACTLY they are defused, not the whole quoted word.
_CMD_POS_CHARS = ";|&(`\n"
# Wrappers that do not change the meaning of the next command, and shell keywords. ONE registry:
# `_CMD_POS`
# is built from it, not repeating the list inside the regex — a divergence cannot be expressed.
_CMD_WRAPPERS = (
    "sudo",
    "xargs",
    "time",
    "nohup",
    "watch",
    "env",
    "command",
    "exec",
    "nice",
)
_SHELL_KEYWORDS = ("then", "do", "else")
# command position: line start / separator / after a wrapper — not text in quotes.
# Assignments before a command (`FOO=1 rm -rf`, `env FOO=1 rm -rf`) are a normal shell form, and
# the verb
# after them stands at the same command position.
_CMD_POS = _join(
    r"(?:^|[",
    _CMD_POS_CHARS,
    r"]|\b(?:",
    "|".join((*_CMD_WRAPPERS, *_SHELL_KEYWORDS)),
    r")\s+)\s*(?:\w+=\S*\s+)*",
)
DANGEROUS_CMD = tuple(
    re.compile(pat)
    for pat in (
        _join(_GIT, r"reset\b[^|;&\n]*--hard"),
        _join(_GIT, r"clean\b[^|;&\n]*\s-[a-eg-z]*f"),  # clean -f/-fd/-fdx
        _join(_GIT, r"branch\b[^|;&\n]*\s-D\b"),
        _join(_GIT, r"checkout\b[^|;&\n]*(?:--\s+)?\.(?:\s|$)"),  # checkout . / checkout -- .
        _join(_GIT, r"restore\b[^|;&\n]*(?<![-\w])\.(?:\s|$)"),  # restore . (discard)
        # `--force-with-lease` is NOT included here: it is parsed separately. A force without a
        # lease and
        # `-f` remain destructive always — they overwrite others' work without asking. So do a `+`
        # refspec (a force without a lease), and the forms that delete remote refs: an empty
        # source `:ref`, `--delete`/`-d` and `--mirror`.
        _join(
            _GIT,
            r"push\b[^|;&\n]*(?:--force(?!-with-lease)\b|\s-f\b|\s--(?:delete|mirror)\b|\s-d\b"
            r"|\s[+:]\S)",
        ),
        # recursive rm by command position (not by text in quotes): rm -rf/-fr/-r/--recursive
        _join(_CMD_POS, r"rm\s+(?:-[a-zA-Z]*[rR]|--recursive)"),
        # find wiping its matches: -delete, or -exec/-execdir running rm
        _join(_CMD_POS, r"find\b[^|;&\n]*\s-(?:delete\b|exec(?:dir)?\s+(?:\S*/)?rm\b)"),
        # dd (overwrite), shutdown/reboot/poweroff (shuts the machine down), chmod -R (mass
        # permissions)
        _join(_CMD_POS, r"dd\s"),
        _join(_CMD_POS, r"(?:shutdown|reboot|poweroff)\b"),
        _join(_CMD_POS, r"chmod\s+(?:-[a-zA-Z]*R|--recursive)"),
    )
)
# ── new dependency: the owner's decision, not the agent's ────────────────────────
# A package is installed by a LANGUAGE manager — one whose package ends up in code that must then
# be maintained.
# System managers (`brew` and kin) are not judged: they install a tool on the machine, not a
# dependency into the project. The global form (`npm i -g`, `pip install --user`) is judged on a
# par with the
# local one: a package does not stop being a code dependency because of where it is installed.
#
# The registry is CLOSED and filled by fact: here the managers present in the stack. `cargo`,
# `gem`,
# `bundle`, `yarn`, `pnpm`, `go get` and others are added by a line on the day the form was met
# live — together with its own case. An entry "for the future" guards nothing, and drags a tail of
# case,
# ratchet corpus lines and registry-reconciliation lines behind it at once.
#
# A path prefix before the manager name must be parsed: `.venv/bin/pip install X` is a working
# form, and a rule that knows only the bare name would block the textbook form and pass the one
# actually used. A call via module (`python3 -m pip install`) is its own entry.
_DEP_PATH = r"(?:[\w.~$-]*/)*"
# The manager with the verb is taken by a NAMED group: the refusal gets it, not the whole match
# with what
# the command position ate — otherwise the agent read "new dependency (& pip install)".
_DEPENDENCY_ADD = tuple(
    re.compile(pat)
    for pat in (
        # a separate add verb: it has no disputable forms, the package is always named
        _join(_CMD_POS, _DEP_PATH, r"(?P<mgr>(?:poetry|uv)\s+add)\b"),
        _join(_CMD_POS, _DEP_PATH, r"(?P<mgr>npm\s+(?:i|install|add))\b"),
        _join(_CMD_POS, _DEP_PATH, r"(?P<mgr>(?:pip[\d.]*|uv\s+pip)\s+install)\b"),
        _join(_CMD_POS, _DEP_PATH, r"(?P<mgr>python[\d.]*\s+-m\s+pip\s+install)\b"),
    )
)
# Flags that take the NEXT word, whose value is never a package: a manifest and an index address.
# The list is incomplete by construction, so it alone does not judge: what remains is filtered out
# by the
# PATH marker — `--target ./vendor`, `--find-links /wheels`, `--prefix ./web`, `--python
# .venv/bin/python`
# pass without being listed here.
_DEP_FLAG_TAKES_VALUE = frozenset(
    (
        "-r",
        "--requirement",
        "-c",
        "--constraint",
        "-i",
        "--index-url",
        "--extra-index-url",
        "--trusted-host",
        "--proxy",
        "--python",
        "--registry",
    )
)
# A path is not a dependency install target: own project (`.`, `-e .`), a wheel dir, a venv.
# The trade is named aloud: `pip install ../otherlib` and `pip install /path/pkg.whl` pass this way
# too —
# installing a package BY PATH is read as work with one's own tree, not as a new dependency.
_DEP_PATH_MARKS = (".", "/")
# Bootstrap of the manager itself is not a project's new dependency, but a condition of its
# operation.
_DEP_BOOTSTRAP = frozenset(("pip", "setuptools", "wheel", "npm"))
_DEP_SEGMENT_END = re.compile(r"[;|&\n]")


# Destructive verbs as a separate registry: needed where the command is NOT parsed and the command
# position cannot be established. Reconciled with the patterns and the refusal text.
_DESTRUCTIVE_VERBS = (
    "reset",
    "clean",
    "branch",
    "checkout",
    "restore",
    "force",
    "rm",
    "dd",
    "shutdown",
    "reboot",
    "poweroff",
    "chmod",
)
# Shell launchers: the content of their quoted argument is a COMMAND, not data, and is checked
# recursively. Masking quotes uniformly is not allowed: `sh -c '<destructive>'` would stop being
# caught.
_LAUNCHERS = frozenset(("sh", "bash", "zsh", "dash", "ksh", "eval"))
# The harness session scratchpad is a service area that it itself hands out for temporary
# files; there is no project work there by construction. Verbs with a PARSEABLE target: for git
# verbs the target is
# the repository, and "lies in the scratchpad" is undefined for them.
# The marker is strict: `claude-<uid>` as a number and a mandatory `scratchpad` segment. A bare
# `claude-` prefix
# is too little — any dir named by the agent fits it, and the exception would become
# a skeleton key: create `/tmp/claude-whatever` and clean up anything under that name.
# Temp roots: the harness scratchpad lies under the same paths, so it needs no separate entry. The
# trailing
# slash is mandatory — it demands depth: `rm -rf /tmp` remains destructive, because
# it wipes other processes' temp, not one's own dir.
_TEMP_ROOTS = ("/tmp/", "/private/tmp/", "/var/folders/")
# Directories restorable by a run: wiping them is an ordinary gate step, not a loss of work.
_RESTORABLE_NAMES = frozenset(("__pycache__", ".pytest_cache"))
# The substitution value is unknown at parse time, so a stand-in path under a
# temp root is taken instead: a suffix leading out of the root by dots, a prefix will not pass
# normalization.
# A stand-in is shorter than the real one (`mktemp -d` gives a deeper dir), i.e. the rule is
# stricter
# than reality — the error goes toward refusal, not passing.
_MKTEMP_STANDIN = "/tmp/retainer-mktemp-standin"
# Three entry forms: `c="$(mktemp -d)"`, `c=$(mktemp -d)`, `c=`mktemp -d``. The command parse tears
# an unquoted one into separate tokens, so the form is looked for in the command TEXT, not in the
# value.
_MKTEMP_RE = re.compile(r"([A-Za-z_]\w*)=[\"']?(?:\$\s*\(|`)\s*mktemp\b([^)`]*)")
# Whitelist of the `mktemp` entry: only flags without a value. Everything else — a parent, a
# template, a flag
# with a value — makes the real path unknown, and the stand-in does not describe it.
_MKTEMP_SHORT_OK = re.compile(r"^-[dqu]+$")
_MKTEMP_LONG_OK = frozenset(("--directory", "--quiet", "--dry-run"))
_NAME_ONLY = re.compile(r"^[A-Za-z_]\w*$")
# Utilities that add targets FROM INPUT: the target list in the command text is incomplete for
# them, so judging
# by it is not allowed. They stand in the wrapper registry for another reason — there the question
# is the verb position.
_TARGETS_FROM_INPUT = frozenset(("xargs",))
_SUBSTITUTION = re.compile(r"[$`]")  # the value becomes known only at launch — not a literal
_PATH_TARGET_VERBS = frozenset(("rm", "dd", "chmod"))
_FLAG_PREFIX = "-"  # one literal per module: tells a flag from a positional argument
_LAUNCH_DEPTH_MAX = 4  # launcher nesting: deeper is no longer an entry form but a craft
_LAUNCH_FLAG = re.compile(
    r"^-[a-z]*c$"
)  # -c, -lc, -ic; but not --norc (a double dash does not fit)

# The harness native deny. It fires BEFORE the hook and is NOT lifted by the owner key:
# the guard promised "touch unlock", but for paths duplicated in deny the promise was false —
# the owner issued the key, and the edit still did not go through. There are two lists, because
# deny is both
# user-level and project-level.
_DENY_FILES = (".claude/settings.json", ".claude/settings.local.json")
_DENY_MARK = "deny"

# Egress exfiltration (opt-in `guard_egress`): a command READS a secret file AND sends it out — but
# NOT in an
# auth header. The idea is from tuzlu07x/retainer (MCP risk score); here — a light Bash-level
# heuristic.
# IMPORTANT: the secret must be READ (cat/base64/@file/< file), not merely be in a URL —
# otherwise `?reset_token=…` or the path `/app.key` in an ordinary REST curl is falsely cut.
_SECRET = (
    r"\.env\b(?:\.[\w.-]+)?"
    r"|id_rsa(?!\.pub)|id_ed25519(?!\.pub)|id_dsa(?!\.pub)"
    r"|\.pem\b|\.p12\b|\.pfx\b|\.aws/credentials|\.netrc\b|\.git-credentials\b|\.npmrc\b|\.pypirc\b"
    r"|[\w.-]*_token\b|[\w.-]*\.key\b|/gitea_token\b|/deepseek_key\b"
    r"|\bsecrets?\.(?:ya?ml|json|toml|env|txt)\b|\bcredentials\.(?:json|ya?ml|txt)\b"
)
# A secret in a READ CONTEXT: after cat/base64/… , in `@file` (curl -d/-F @file) or in `< file`.
_SECRET_READ = re.compile(
    _join(
        r"(?:cat|base64|xxd|od|nl|head|tail|less|more|gpg|openssl)\s+[^|;&]*(?:",
        _SECRET,
        r")|@[^\s|;&]*(?:",
        _SECRET,
        r")|<\s*[^\s|;&<>]*(?:",
        _SECRET,
        # `--post-file=` (wget) and `--upload-file=` (curl) are also a file read, and straight
        # out. A normal flag of a normal tool from _NET_TOOL, not an encoding bypass.
        r")|--(?:post|upload)-file(?:=|\s+)[^\s|;&]*(?:",
        _SECRET,
        r")",
    ),
    re.IGNORECASE,
)
# A secret is read not only from a FILE but by a command that is secret by nature
# (frisk/guiderails):
# secret managers (pass/gopass/op/bw/secret-tool) and decryption (gpg/age/sops/openssl -d).
_SECRET_CMD = re.compile(
    r"\b(?:pass|gopass)\s+show\b|\bop\s+read\b|\bbw\s+get\b|\bsecret-tool\s+lookup\b"
    r"|\bgpg\b[^|;&]*(?:--decrypt|\s-d\b)|\bage\b[^|;&]*(?:--decrypt|\s-d\b)"
    r"|\bsops\b[^|;&]*(?:--decrypt|\s-d\b)|\bopenssl\s+enc\b[^|;&]*\s-d\b",
    re.IGNORECASE,
)
# A literal secret VALUE right in the command — a hardcoded/stolen token goes
# out (frisk). Prefixes are narrow (low FP): AWS AKIA, GitHub ghp_/pat, Slack xox,
# JWT eyJ.., a PEM private key block. An entropy detector and a heuristic by env-var NAME
# are NOT taken — high FP on legit `curl -u user:$API_TOKEN`.
_TOKEN_VALUE = re.compile(
    r"\bAKIA[0-9A-Z]{16}\b"
    r"|\bghp_[A-Za-z0-9]{36}\b|\bgithub_pat_[A-Za-z0-9_]{22,}\b"
    r"|\bxox[baprs]-[A-Za-z0-9-]{10,}\b"
    r"|\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+"
    r"|-----BEGIN [A-Z ]*PRIVATE KEY-----"
)
# A password inside a URL, `scheme://user:password@host`: redacted in the journal only. The user
# part may be empty and ends at the first `:`; the password runs to the last `@` before a `/` or
# whitespace, so a raw `@` inside it leaves no tail. Kept out of _TOKEN_VALUE: that set also feeds
# the egress detector.
_URL_PASSWORD = re.compile(r"(://[^\s/:]*:)[^\s/]+@")
_NET_TOOL = re.compile(r"\b(?:curl|wget|nc|ncat|netcat|telnet|ftp)\b")
# Only a REAL auth header lifts the gate (not any -H — otherwise a decorative header would smuggle
# -d @secret).
_AUTH_CTX = re.compile(r"(?:authorization|extraheader|bearer)", re.IGNORECASE)
# External host. We exclude localhost AND private RFC1918/link-local
# (10/172.16-31/192.168/169.254):
# egress there is internal, not exfiltration to the internet
# (borrowed RFC1918 detection from nirecom/agents).
_LOCAL = (
    r"localhost|127\.0\.0\.1|0\.0\.0\.0|\[?::1"
    r"|10\.\d|192\.168\.|169\.254\.|172\.(?:1[6-9]|2\d|3[01])\."
)
_EXTERNAL = re.compile(
    _join(
        r"https?://(?!",
        _LOCAL,
        r")[\w.-]+|/dev/tcp/(?!",
        _LOCAL,
        r")|\b(?:nc|ncat|netcat|telnet)\s+(?:-\S+\s+)*(?!",
        _LOCAL,
        r")[a-zA-Z0-9][\w.-]*\s+\d",
    ),
    re.IGNORECASE,
)
# Fetch-exec: download and execute at once in the shell (borrowed from frisk). We flag ONLY the
# dangerous form —
# non-TLS http:// (MITM-able) or TLS to a bare IP (unattributable). HTTPS-to-host
# (`curl https://get.docker.com|sh`) is a legitimate installer, NOT touched: otherwise we would
# break
# ordinary tool installation. localhost/RFC1918 are excluded too (a dev installer from local
# http ≠ MITM) — consistent with the egress detector.
_FETCH_EXEC = re.compile(
    _join(
        r"\b(?:curl|wget)\b[^|]*?(?:http://(?!",
        _LOCAL,
        r")|https://(?!",
        _LOCAL,
        r")(?:\d{1,3}\.){3}\d{1,3})[^|]*\|\s*(?:sudo\s+)?(?:bash|sh|zsh|dash|python3?|perl|ruby|node)\b",
    ),
    re.IGNORECASE,
)


def _egress_exfil(command: str) -> bool:
    """A secret is READ (not in a URL) and goes to an EXTERNAL host, but NOT via an auth header.

    A Bash-level heuristic (defense-in-depth): trivially bypassed by encoding (base64→python),
    a variable with the URL, gluing via `;`, a `localhost.evil` subdomain, IPv6. It raises the
    bar against direct injection-exfiltration, does NOT lock the channel. Full control — at the
    MCP level.
    """
    reads_secret = (
        _SECRET_READ.search(command) or _SECRET_CMD.search(command) or _TOKEN_VALUE.search(command)
    )
    if reads_secret and _NET_TOOL.search(command) and not _AUTH_CTX.search(command):
        return bool(_EXTERNAL.search(command))
    return False


# Parsing a command into real write targets.
_CMD_SEP = ";"  # command separator: also substituted in place of a line break
_QUOTE_CHARS = frozenset(('"', "'"))
_SHELL_OPS = frozenset((_CMD_SEP, "&&", "||", "|", "&"))
_ASSIGN = re.compile(r"^([A-Za-z_]\w*)=(.*)$", re.DOTALL)
_VAR_REF = re.compile(r"\$\{?([A-Za-z_]\w*)\}?")


def _normalize(target: Path) -> Path:
    """Absolute path without touching the FS (the file may not exist yet.

    Write creates a new one).
    """
    parts: list[str] = []
    for part in target.parts:
        if part == "..":
            if parts:
                parts.pop()
        elif part != ".":
            parts.append(part)
    return Path(*parts)


def _resolve(raw: str, cwd: str) -> Path:
    """Raw path from tool_input → normalized absolute (relative — from cwd)."""
    target = Path(raw).expanduser()
    if not target.is_absolute():
        target = Path(cwd or ".") / target
    return _normalize(target)


def _find_repo(start: Path) -> Path | None:
    """The nearest directory up the tree with `.retainer/config.toml` — a managed repository.

    The plugin cache is excluded entirely: it holds engine SNAPSHOTS, each with its own config, and
    the climb recognized a snapshot as a project. A snapshot differs from the working tree not in
    content (it
    matches byte for byte) but in WHO controls it: the cache — the plugin manager.
    """
    probe = start if start.is_dir() else start.parent
    if probe == PLUGIN_CACHE or PLUGIN_CACHE in probe.parents:
        return None
    for candidate in (probe, *probe.parents):
        if (candidate / _RETAINER / _CONFIG_NAME).is_file():
            return candidate
    return None


def _load(repo: Path) -> Config:
    """Parsed config.toml of the repository; an empty dict — no file, or the parse failed outright.

    The encoding is named: under a non-UTF-8 locale every byte decodes, and a broken file would
    pass for a readable one. A file that is not UTF-8 carries the sign "config not parsed": a
    decode error left to fly crashes the hook, and a crash cancels not the command but the
    protection.
    """
    try:
        text = (repo / _RETAINER / _CONFIG_NAME).read_text(encoding="utf-8")
    except OSError:
        return {}
    except UnicodeDecodeError:
        return {_UNPARSED_KEY: 0}
    try:
        return _parse_config(text)
    except (ValueError, KeyError, IndexError):
        return {}


def _flag(config: Config, key: str, default: bool = False) -> bool:
    """Boolean flag from the config, independent of the parser (tomllib → bool, minimal → string).

    The trailing comment is cut: the minimal parser returns everything after `=` as one string, and
    the canon
    of the config writes the explanation on the same line (`guard_egress = true   # catches
    exfil`). No key — `default`.
    The key EXISTS but the value does not reduce to a boolean — the gate stays ON: otherwise a
    one-character
    typo turns protection off silently. The decision to turn off is read only from an explicit
    `false`.
    """
    if key not in config:
        return default
    raw = config.get(key)
    if isinstance(raw, bool):
        return raw
    if isinstance(raw, str):
        word = raw.split(_COMMENT_MARK, 1)[0].strip().lower()
        if word in _BOOL_WORDS:
            return word == "true"
    # The value was not read by any path: a number, a date, a table, a broken entry form. The
    # answer does not
    # depend on the interpreter — otherwise one and the same valid config would give different
    # protection.
    return True


def _unlock_path(repo: Path, config: Config) -> Path:
    """Address of the owner key inside the repository.

    The value is not a string (number, date, array) — the default address is read: `Path /
    non-string`
    crashes the hook, and a crash cancels not the command but the protection — all opt-in gates go
    silent at once.
    """
    declared = config.get(_UNLOCK_KEY, _DEFAULT_UNLOCK)
    address = declared if isinstance(declared, str) else _DEFAULT_UNLOCK
    return repo / address


def _unlocked(repo: Path, config: Config) -> bool:
    """The owner lifted protection manually for THIS repo.

    A key is an EMPTY regular file: `touch` creates it empty. A non-empty file at the address
    is not a key — it neither lifts protection nor is deleted. A stale key is self-cleaned.
    """
    unlock = _unlock_path(repo, config)
    # Only a FILE can be the owner key. An empty key value gives `repo / ""` —
    # the repository root: `stat()` on a directory always passes, and a directory would pass for a
    # key.
    if not unlock.is_file():
        return False
    try:
        key_stat = unlock.stat()
    except OSError:
        return False
    # A key is empty by construction (`touch`). A non-empty file at the address is not a key:
    # it does not lift protection, and a stale one is left in place instead of being deleted
    # (the config named it by mistake).
    if key_stat.st_size != 0:
        return False
    if time.time() - key_stat.st_mtime >= UNLOCK_TTL_SECONDS:
        with contextlib.suppress(OSError):
            unlock.unlink()
        return False
    return True


def _global_unlocked() -> bool:
    """The owner lifted GLOBAL protection (the guard's wiring) and the key has not gone stale.

    A key is an EMPTY regular file: a directory or a non-empty file with that name is not a key.
    The path here is fixed, but a twin in one file must not diverge from the fixed one — the
    divergence would survive an edit.
    """
    if not GLOBAL_UNLOCK.is_file():
        return False
    try:
        key_stat = GLOBAL_UNLOCK.stat()
    except OSError:
        return False
    if key_stat.st_size != 0:
        return False
    if time.time() - key_stat.st_mtime >= UNLOCK_TTL_SECONDS:
        with contextlib.suppress(OSError):
            GLOBAL_UNLOCK.unlink()
        return False
    return True


def _lex_segments(command: str) -> list[list[str]] | None:
    """Command → word segments respecting quotes. None — could not parse."""
    lexer = shlex.shlex(_split_lines(command), posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
    except ValueError:
        return None
    segments: list[list[str]] = []
    current: list[str] = []
    for token in tokens:
        if token in _SHELL_OPS:
            if current:
                segments.append(current)
            current = []
        else:
            current.append(token)
    if current:
        segments.append(current)
    return segments


def _split_lines(command: str) -> str:
    """After a line break OUTSIDE quotes add `;`: in the shell that is the same command separator.

    The lexer eats a line break as a space, so without substituting a separator a multiline
    command arrives as one segment. Inside quotes a line break is part of the data.

    The separator is placed AFTER the line break, not instead of it: the lexer cuts a comment to
    the end of
    the line, and a separator in place of the break would end up in the comment together with the
    next command.
    """
    out: list[str] = []
    quote = ""
    for char in command:
        piece, quote = _sep_char(char, quote)
        out.append(piece)
    return "".join(out)


def _sep_char(char: str, quote: str) -> tuple[str, str]:
    """A character and quote state: a command separator outside quotes is surrounded by spaces.

    Spaces are mandatory: the lexer glues a separator to a neighboring character (`);` — one
    token), and
    then the command after it lands in a foreign segment. A detached separator is seen by the lexer
    itself.
    """
    if quote:
        return char, ("" if char == quote else quote)
    if char in _QUOTE_CHARS:
        return char, char
    if char == "\n":
        return f"\n {_CMD_SEP} ", ""
    return (f" {_CMD_SEP} " if char == _CMD_SEP else char), ""


def _quoted_char(char: str, quote: str) -> tuple[str, str]:
    """A character INSIDE quotes.

    What goes into the command view and whether the quote stayed open.
    """
    if char == quote:
        return "", ""
    return (" " if char in _CMD_POS_CHARS else char), quote


def _view_char(char: str, quote: str) -> tuple[str, str, bool]:
    """A character outside escaping.

    What goes into the view, which quote is open, whether escaping began.

    Returned as a triple, not by mutating state outside: both variables have exactly one author.
    """
    if quote:
        if char == "\\" and quote != "'":
            return "", quote, True
        emitted, quote = _quoted_char(char, quote)
        return emitted, quote, False
    if char == "\\":
        return "", "", True
    if char in {"'", '"'}:
        return "", char, False
    return char, "", False


def _cmd_view(command: str) -> str:
    """Command for the destructive match.

    Quotes removed, command-position characters defused inside them.

    Quotes in the shell affect only the splitting into words: a quoted flag remains a flag.
    What makes the quoted into data is only that a separator inside quotes does not launch a
    command.
    """
    seen: list[str] = []
    quote = ""
    escaped = False
    for char in command:
        if escaped:
            # An escaped character is data both in and out of quotes: `\;` is a semicolon,
            # not a separator. It is defused the same way as a quoted one.
            seen.append(" " if char in _CMD_POS_CHARS else char)
            escaped = False
            continue
        emitted, quote, escaped = _view_char(char, quote)
        seen.append(emitted)
    return "".join(seen)


def _is_wrapper(word: str) -> bool:
    """A wrapper that does not change the meaning of the next command, or its numeric argument."""
    return Path(word).name in _CMD_WRAPPERS or word.isdigit()


def _launcher_argv(words: list[str]) -> list[str]:
    """Words of a segment without assignments and wrappers — what actually runs."""
    argv = [word for word in words if not _ASSIGN.match(word)]
    while argv and _is_wrapper(argv[0]):
        argv = argv[1:]
    return argv


def _launcher_script(argv: list[str]) -> list[str]:
    """Launcher script: everything after `eval`, otherwise the argument following the `-c` flag."""
    if Path(argv[0]).name == "eval":
        return argv[1:]
    for index, word in enumerate(argv[1:], start=1):
        if _LAUNCH_FLAG.match(word):
            return argv[index + 1 : index + 2]
    return []


def _launcher_scripts(command: str) -> list[str]:
    """Shell launcher arguments: their content is checked as a COMMAND, not as data."""
    segments = _lex_segments(command)
    if segments is None:
        return []
    scripts: list[str] = []
    for words in segments:
        argv = _launcher_argv(words)
        if argv and Path(argv[0]).name in _LAUNCHERS:
            scripts.extend(_launcher_script(argv))
    return [script.lstrip("$") for script in scripts]


# Command position for the UNPARSED remainder. One wider than usual: a launch via the shell
# (`bash -c rm -rf …`). The parse would have seen it through recursion into the launcher, but there
# is none here — the command
# did not parse. Passing such a form would trade false positives for a hole.
_UNPARSED_POS = _join(
    r"(?:", _CMD_POS, r"|\b(?:", "|".join(sorted(_LAUNCHERS)), r")\s+(?:-\S+\s+)*)"
)


def _unparsed_destructive(command: str) -> bool:
    """The command does not parse (broken quote): destructive verb AT THE COMMAND POSITION blocks.

    Fail-safe here is PROHIBITING: since the position cannot be established by the parse, we judge
    by text. But exactly
    by position, not by occurrence anywhere: a verb inside a string literal or in
    message text is data, and a block on any mention gave false positives on every script
    with the word `rm`.
    """
    view = _cmd_view(_strip_heredocs(command))
    hits = (re.search(_join(_UNPARSED_POS, rf"{verb}\b"), view) for verb in _DESTRUCTIVE_VERBS)
    return any(hits)


# Heredoc start: `<<WORD`, `<<'WORD'`, `<<-WORD`. The body up to the delimiter line is DATA.
_HEREDOC_OPEN = re.compile(r"<<-?\s*([\'\"]?)(\w+)\1")
# A pipe into a shell on the opening line (`cat <<EOF | bash`, `| sudo /bin/sh`): a coarse string
# match, not a parse of the pipeline.
_PIPE_TO_SHELL = re.compile(
    _join(
        r"\|\s*(?:(?:",
        "|".join(_CMD_WRAPPERS),
        r")\s+)*(?:\S*/)?(?:",
        "|".join(sorted(_LAUNCHERS)),
        r")(?:[\s;&|)]|$)",
    )
)


def _heredoc_owner_launches(line: str) -> bool:
    """Does the line opening a heredoc feed it to the SHELL? Then the body is commands.

    Not data. The shell is either the line's first command or the target of a pipe on it.
    """
    words = (_lex_segments(line) or [[]])[0]
    if any(Path(word).name in _LAUNCHERS for word in words):
        return True
    return bool(_PIPE_TO_SHELL.search(line))


def _strip_heredocs(command: str) -> str:
    """Strip the BODIES of heredocs not addressed to the shell.

    A line break is a command position, so a heredoc body was parsed as a sequence of
    commands: a python script with the string literal `rm -rf` was cut as destructive. That was a
    live
    class of false positives — and a noise generator, because every firing files a task.

    A body fed to `bash`/`sh` is NOT counted as data: there it is commands, and recursion into the
    launcher must see it. The delimiter is searched by the whole line, as the shell does.
    """
    out: list[str] = []
    ender = ""
    for line in command.splitlines():
        if ender:
            if line.strip() == ender:
                ender = ""
            continue
        out.append(line)
        opened = _HEREDOC_OPEN.search(line)
        if opened and not _heredoc_owner_launches(line):
            ender = opened.group(2)
    return "\n".join(out)


# Republishing a rebased branch. `--force-with-lease` is by meaning not destructive:
# it REFUSES if the remote branch moved ahead — exactly the operation it was invented for.
# Without it the agent had no safe way to publish the rebased: a plain push is rejected,
# force is closed, and "delete the branch and push again" CLOSES its PR irreversibly (two PRs
# with review verdicts were lost). Meanwhile rebasing is mandatory — the merge lock demands it.
_LEASE_PUSH = re.compile(_join(_GIT, r"push\b[^|;&\n]*--force-with-lease"))
# Task branch: a name from the flow (`issue-<N>-<slug>`), not an arbitrary one.
_ISSUE_REF = re.compile(r"(?<![\w/-])issue-\d+")
# Branches on which a lease grants no right UNDER ANY conditions.
_NEVER_FORCED = re.compile(r"(?<![\w/-])(?:main|master)(?![\w-])")


def _lease_push_ok(view: str) -> bool:
    """Is `--force-with-lease` allowed?

    Only with an EXPLICITLY named `issue-*` branch and not on main.

    Branch not named (`git push --force-with-lease` without a refspec) — nothing to judge by: the
    target is determined by
    upstream, which is not visible from the command text. Such a form stays closed, and this is no
    nitpick:
    it is exactly there that a force goes to the branch where the agent happens to stand.
    """
    if _NEVER_FORCED.search(view):
        return False
    return bool(_ISSUE_REF.search(view))


def _segment_verb(words: list[str]) -> tuple[str, list[str]]:
    """Verb of a segment and its positional arguments; leading assignments are skipped.

    An assignment before a verb is a normal form (`VAR=x rm …`), and the lexer puts it in the same
    segment. Wrappers (`command`, `sudo`, `env`, `time`…) are skipped for the same reason: the verb
    behind
    them is the same. There is one wrapper registry in the module — a second list would drift from
    the first.
    """
    plain = [word for word in words if not word.startswith(_FLAG_PREFIX)]
    while plain and _skippable(plain[0]):
        plain = plain[1:]
    return (plain[0] if plain else ""), plain[1:]


def _skippable(word: str) -> bool:
    """A word before the verb that does not change the command meaning: an assignment or a wrapper.

    `xargs` is not skipped: it ADDS to the arguments what came from input, so the target list
    in the segment text is incomplete. The wrapper registry answers "does the verb stand at the
    command
    position" — for `xargs` that is true; here another question is asked: "are all targets
    visible", and the answer is no.
    """
    if Path(word).name in _TARGETS_FROM_INPUT:
        return False
    return bool(_ASSIGN.match(word)) or _is_wrapper(word)


def _scratch_targets(
    segments: list[list[str]],
    variables: dict[str, str],
) -> list[str] | None:
    """Targets of verbs with a parseable path.

    None — at least one target did not resolve to a path.
    """
    targets: list[str] = []
    for words in segments:
        found = _segment_verb(words)  # (verb, positional arguments)
        if found[0] not in _PATH_TARGET_VERBS:
            continue
        for token in found[1]:
            path = _expand(token, variables)
            if path is None:
                return None
            targets.append(path)
    return targets


def _assigned_counts(segments: list[list[str]]) -> dict[str, int]:
    """How many times a name is the target of an assignment ANYWHERE in the command.

    The FACT of assignment is counted, not value readability nor position. Position will not do
    here:
    `export d=…`, `declare`, `readonly`, `local`, `eval "d=…"` set the value by a modifier,
    and walking leading assignments did not see them — the name stayed "untouched", i.e. kept
    the stand-in path or the default from the environment. One word before the assignment lifted
    the rule.

    A form that cannot be counted (`read name`) poisons the name by the same count: "could not
    read"
    must read as "cannot decide", not as "can".
    """
    counts: dict[str, int] = {}
    for words in segments:
        for name in _assigned_in(words):
            counts[name] = counts.get(name, 0) + 1
    return counts


def _assigned_in(words: list[str]) -> list[str]:
    """Names to which a segment assigns a value: the form `name=…` plus `read` arguments."""
    # The verb is asked of a shared helper: it skips both leading assignments (`IFS= read -r d`
    # is the canonical idiom) and wrappers like `command`, so no word list is needed.
    reads = Path(_segment_verb(words)[0]).name == "read"
    names: list[str] = []
    for word in words:
        match = _ASSIGN.match(word)
        if match:
            names.append(match.group(1))
        elif reads and _NAME_ONLY.match(word):
            names.append(word)  # `read name` — the value comes from input, it cannot be read
    return names


def _leading_mktemp(words: list[str]) -> tuple[str, str]:
    """Name and stand-in path of a leading `mktemp -d` assignment; an empty name — no such form.

    The form is looked for from the START of the segment and only if the first word is an
    assignment: otherwise an argument like
    `echo "d=$(mktemp -d)"` is indistinguishable from an assignment, and a decoy in data would lift
    the rule without
    creating any directory.

    The entry is judged by a WHITELIST: nothing but flags without a value, one of which asks for a
    directory. The parent is set both by a flag (`-p`, `--tmpdir`, `-t`) and by a positional
    template
    (`mktemp -d "$HOME/tXXXXXX"`) — in both cases the real directory lies anywhere, up to
    the working tree, and the stand-in path does not describe it.

    The value tail AFTER the closing paren carries the stand-in path itself, so dots at the
    assignment
    site are judged by the same normalization as dots at the use site. A tail with a substitution
    inside — fail-closed: the path is unknown.
    """
    if not words or not _ASSIGN.match(words[0]):
        return ("", "")
    joined = " ".join(words)
    hit = _MKTEMP_RE.match(joined)  # the value may be torn by the lexer into tokens
    if hit is None or not _mktemp_plain(hit.group(2) or ""):
        return ("", "")
    tail = joined[hit.end() :]
    if tail[:1] not in {")", "`"}:
        return ("", "")  # the closing of the substitution is not visible — nothing to parse
    rest = tail[1:].strip()
    if _SUBSTITUTION.search(rest):
        return ("", "")  # another substitution in the tail: the path is unknown
    return (hit.group(1), _MKTEMP_STANDIN + rest)


def _mktemp_plain(flags: str) -> bool:
    """In a `mktemp` entry only flags without a value, and one of them asks for a directory."""
    wants_dir = False
    for word in flags.split():
        if word in _MKTEMP_LONG_OK:
            wants_dir = wants_dir or word == "--directory"
        elif _MKTEMP_SHORT_OK.match(word):
            wants_dir = wants_dir or "d" in word
        else:
            return False  # a parent, a template, a flag with a value — the path becomes unknown
    return wants_dir


def _mktemp_vars(segments: list[list[str]]) -> dict[str, str]:
    """Names that got a directory from `mktemp -d` by a leading assignment → stand-in path."""
    found: dict[str, str] = {}
    for words in segments:
        name, stand_in = _leading_mktemp(words)
        if name:
            found[name] = stand_in
    return found


def _restorable_target(path: str) -> bool:
    """The target is certainly restorable: a system temp dir or a cache restorable by a run.

    The path is normalized BEFORE the prefix comparison. Without normalization
    `…/scratchpad/../../<project>` matched
    by the start of the string, yet wiped the working tree — i.e. the exception opened with dots.

    The root registry is compared only with an absolute target: a relative one cannot be resolved,
    and this is
    the same fail-closed as before. An excess of dots eating the root lands in the same place. The
    cache name, on the contrary,
    does not depend on the current dir — `rm -rf app/__pycache__` is written exactly so.

    A managed repository INSIDE a temp root remains work: a project cloned into
    `/tmp` does not become temporary, and the suite sandbox lies exactly there — without this
    caveat
    the extension would lift protection from everything verified in it.
    """
    normalized = _normalize(Path(path))
    text = str(normalized)
    if not text.startswith("/") or _find_repo(normalized) is not None:
        return normalized.name in _RESTORABLE_NAMES
    if any(text.startswith(root) for root in _TEMP_ROOTS):
        return True
    return normalized.name in _RESTORABLE_NAMES


def _scratch_only(command: str) -> bool:
    """All command targets are certainly restorable — the destructive act on them is empty.

    The rule judged the VERB and did not look at the TARGET, so cleaning a temp dir was blocked
    with the same words as wiping the working tree, and went into the bypass journal on a par with
    a real
    destructive act — with live labels and shifted thresholds. The cost is not two tickets: a noisy
    rule
    teaches people to read it as a nuisance.

    The marker is the PREFIX OF A NORMALIZED PATH, not an environment variable: the agent sets the
    variable
    for itself, and a barrier rule must not rely on it (the same class is closed for the probe
    mode). The `TMPDIR` value from the environment serves as a DEFAULT and is compared with the
    fixed registry
    on a par with any path; an assignment in the command itself overrides it.

    The directory from `mktemp -d` is unknown in advance, so a path under a temp root is
    substituted.
    The substitution does NOT override a literal: a name assigned a real path in the command is
    judged by
    that, and a name assigned twice gets no exception at all — which value survives to the
    verb does not follow from the text.

    The exception is issued PER SEGMENT: each segment on which a destructive act matched must
    itself
    have a verb with a parseable target and all targets restorable. Otherwise one cache cleanup
    would lift
    the rule for the whole line, including `git reset --hard` behind the ampersands.

    The rest is fail-closed: a target must resolve to a path (`rm -rf "$WT"` with an assignment
    from another
    command remains destructive); at least one target must exist. Git verbs give no targets — their
    target is the repository, and "lies in temp" is undefined for them.
    """
    # The heredoc body is stripped before parsing: the shell does not execute the text inside it,
    # and a decoy
    # `d=$(mktemp -d)` from there would lift the rule without creating any directory.
    segments = _lex_segments(_strip_heredocs(command))
    if not segments:
        return False  # nothing to parse (including when a comment ate everything) — cannot decide
    if _LITERAL_SEP.search(_strip_heredocs(command)):
        return False
    variables = _destructive_vars(segments)
    return all(_segment_restorable(words, variables) for words in segments)


# Text the lexer reads as a separator while the shell does not: an escaped `;` (`find -exec … \;`),
# an escaped line break (a continued command), a quoted lone `;`. The lexer cuts one command apart
# there, so the per-segment check would miss the act after the cut. Fail-closed: no exception.
_LITERAL_SEP = re.compile(r"\\[;\n]|(['\"]);\1")


def _destructive_vars(segments: list[list[str]]) -> dict[str, str]:
    """Variable map for the destructive parse: environment, command literals, mktemp substitutions.

    The copy is deliberate: the literal map is built by a shared helper that is also read by the
    parse of writes to
    protected files — its behavior is not moved by this edit.
    """
    # Invariant: a stand-in path goes only to a name untouched by anything but the substitution
    # itself. The FACT of assignment is judged, not value readability: an unreadable value
    # (`d=$HOME`, `` d=`pwd` ``) must poison the name, not roll it back to the stand-in path.
    counts = _assigned_counts(segments)
    variables = _once_assigned(_mktemp_vars(segments), counts)
    variables.update(_once_assigned(_readable_vars(segments), counts))
    # The environment is a default, and it acts only while the command did not touch the name at
    # all: a value
    # assigned in the command itself may be unreadable, and then there is nothing to decide by.
    if not counts.get("TMPDIR"):
        variables.setdefault("TMPDIR", os.environ.get("TMPDIR", ""))
    return variables


def _once_assigned(
    source: dict[str, str],
    counts: dict[str, int],
) -> dict[str, str]:
    """Names with a non-empty value assigned in the command EXACTLY once.

    A second assignment is fail-closed: which value survives to the verb does not follow from the
    text.
    """
    kept: dict[str, str] = {}
    for name, path in source.items():
        if path and counts.get(name, 0) < 2:
            kept[name] = path
    return kept


def _readable_vars(segments: list[list[str]]) -> dict[str, str]:
    """Literal values of assignments: a value with a substitution is not a path."""
    kept: dict[str, str] = {}
    for name, path in _shell_vars(segments).items():
        if not _SUBSTITUTION.search(path):
            kept[name] = path
    return kept


def _segment_restorable(words: list[str], variables: dict[str, str]) -> bool:
    """A segment is safe: either it has no destructive act, or all its targets are restorable."""
    joined = " ".join(words)
    if not any(pattern.search(joined) for pattern in DANGEROUS_CMD):
        return True
    verb, _ = _segment_verb(words)
    if verb not in _PATH_TARGET_VERBS:
        return False
    targets = _scratch_targets([words], variables)
    if not targets:
        return False
    return all(_restorable_target(path) for path in targets)


def _destructive_hit(command: str, depth: int = 0) -> bool:
    """Destructive act in a command: by the defused view plus recursion into shell launchers."""
    view = _cmd_view(_strip_heredocs(command))
    if any(pattern.search(view) for pattern in DANGEROUS_CMD):
        return not _scratch_only(command)
    if _LEASE_PUSH.search(view) and not _lease_push_ok(view):
        return True
    if depth >= _LAUNCH_DEPTH_MAX:
        return False
    if _lex_segments(command) is None:
        return _unparsed_destructive(command)
    return any(_destructive_hit(script, depth + 1) for script in _launcher_scripts(command))


def _shell_vars(segments: list[list[str]]) -> dict[str, str]:
    """Variables assigned by a literal IN THE SAME command (they set the paths) + HOME."""
    found = {"HOME": str(HOME)}
    for words in segments:
        for word in words:
            assign = _ASSIGN.match(word)
            if not assign:
                break
            found[assign.group(1)] = assign.group(2)
    return found


def _expand(token: str, variables: dict[str, str]) -> str | None:
    """Substitute known variables. An unknown $… remained → None (cannot decide)."""
    expanded = token
    for name in _VAR_REF.findall(token):
        known = variables.get(name)
        if known is None:
            return None
        expanded = expanded.replace(f"${{{name}}}", known).replace(f"${name}", known)
    if "$" in expanded:
        return None
    return expanded


# Refusal headers by the REASON, not by one sample. The header is read first, and it must
# name what fired: for an edit of the protected the FILE is guarded, for a destructive act and
# egress — the
# operation, and the path in them is merely the project address.
_HEAD_PROTECTED = "⛔ PROTECTED DISCIPLINE FILE"
_HEAD_DESTRUCTIVE = "⛔ DESTRUCTIVE OPERATION IN THE PROJECT"
_HEAD_EGRESS = "⛔ POSSIBLE SECRET EGRESS FROM THE PROJECT"
_HEAD_FETCH = "⛔ CODE DOWNLOAD STRAIGHT INTO THE SHELL IN THE PROJECT"


def _deny_names(place: Path) -> set[str]:
    """What is mentioned at all in the `deny` block of this settings file.

    No file or block — empty.
    """
    try:
        said = place.read_text(encoding=_ENC)
    except OSError:
        return set()
    if _DENY_MARK not in said:
        return set()
    return set(re.findall(r"[\w./~$-]+", said))


def _under_native_deny(path: Path) -> bool:
    """Is the path duplicated in the harness native `deny`? Then the owner key will not open it.

    Compared by SUBSTRING against the deny rules, not by parsing their syntax: there are many entry
    forms
    (`Edit(path)`, glob, `**`), and our own parser of a foreign format would drift from it
    silently. The task
    here is not to judge the rule but not to lie to the agent about the key; a false "the key will
    not help" is cheaper than
    a false "the key will help", for which the task was created.
    """
    roots = (HOME, Path.cwd())
    places = [root / rel for root in roots for rel in _DENY_FILES]
    forms = {str(path), path.name}
    return any(_deny_names(place) & forms for place in places)


_KEY_HINT = "Only the owner can lift the protection, in their own terminal:\n  touch {unlock}\n"


def _unlock_hint(path: Path, unlock: Path) -> str:
    """What lifts this prohibition: the owner key or nothing.

    Under the guard the key works. Under the harness native `deny` it does not: deny fires BEFORE
    the hook and
    is not lifted by the key, so the second ending names the owner as the executor of the edit.
    """
    if not _under_native_deny(path):
        return _KEY_HINT.format(unlock=unlock)
    return (
        "THIS path is also closed by the harness native deny — it fires BEFORE\n"
        "the guard, and the owner key does not lift it. The owner makes the edit themselves,\n"
        "by a command in their own terminal, or removes the path from deny in settings.\n"
        f"(The guard key — {unlock} — opens nothing here.)\n"
    )


def _refuse(path: Path, reason: str, how: str, unlock: Path, head: str = _HEAD_PROTECTED) -> None:
    """Refuse: an explanation to the agent in stderr + exit with code 2.

    `head` is the refusal header. The default is the former one, because in seven calls out of ten
    it is the
    FILE that is guarded. In the other three the OPERATION is guarded, and the common header lied
    about them: `path`
    received the repository root, and the root is not listed in `protected` and is not a protected
    file.
    The agent read the header, went to look at the protected list, did not find the root there —
    and
    drew the wrong conclusion. Of six auto-parsed incidents the header stood on two, and both
    required a replay to understand what exactly fired.

    A guarded OPERATION is a Bash command the guard itself refuses, and the guard's key lifts it:
    its refusal always names the key. The native `deny` check is for a guarded file.
    """
    hint = _KEY_HINT.format(unlock=unlock)
    if head == _HEAD_PROTECTED:
        hint = _unlock_hint(path, unlock)
    sys.stderr.write(
        f"\n{head}: {path}\n"
        f"   Guarded: {reason}\n\n{how}\n\n"
        "This rule is enforced by Claude Code, not by you. It cannot be bypassed with your own\n"
        "tools — and you should not try.\n\n"
        "If the rule really must change — do NOT bypass it.\n"
        "Show the owner the exact diff and explain why the previous rule\n"
        "is wrong.\n" + hint
    )
    sys.exit(BLOCK)


def _clip(detail: str) -> str:
    """Truncation of a journal record.

    With a marker and the full length, so the cut is not taken for the whole.
    """
    if len(detail) <= _JOURNAL_DETAIL_MAX:
        return detail
    return detail[:_JOURNAL_DETAIL_MAX] + _JOURNAL_CLIP_MARK.format(total=len(detail))


def _journal_detail(detail: str) -> str:
    """Detail as the journal stores it.

    One home: both the record and the comparison with the recorded.
    """
    # Never journal a LITERAL secret value: _TOKEN_VALUE catches a token in the command, but
    # the journal is read by eye and quoted in tasks. Without redaction the anti-exfiltration
    # itself would leak
    # the caught secret.
    # ORDER IS MANDATORY: redaction first, then truncation. Otherwise a secret at the truncation
    # boundary
    # is cut in half, and its tail goes into the journal already unrecognizable to the redactor.
    redacted = _TOKEN_VALUE.sub("<redacted-secret>", detail)
    return _clip(_URL_PASSWORD.sub(r"\1<redacted-secret>@", redacted))


def _journal(repo: Path | None, reason: str, detail: str) -> None:
    """Local bypass journal of the discipline (no network).

    A probe is MARKED; errors do not break the block.

    The journal is an observation: lines accumulate and are read by a human, no tasks are filed
    from them.

    A probe record is not skipped but carries `probe: true`. Earlier a probe did not journal at
    all, and
    diagnostics left no trace: "the guard was checked" and "the guard was not checked" looked the
    same
    in the journal. The consumer — the threshold alert — does not count marked records, so a probe
    does not move the thresholds.
    """
    detail = _journal_detail(detail)
    log_path = (
        (HOME / _RETAINER / _BYPASS_LOG) if repo is None else (repo / _RETAINER / _BYPASS_LOG)
    )
    record: Config = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "reason": reason,
        "detail": detail,
    }
    if _PROBE:
        record[_PROBE_FIELD] = True
    entry = json.dumps(record, ensure_ascii=False)
    with contextlib.suppress(OSError):  # the journal is auxiliary, it does not break the block
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("a") as fh:
            fh.write(f"{entry}\n")


# The guard's own wiring: `~/.claude/settings.json` registers the hook, `~/.claude/hooks` holds its
# code, the managed-repo registry decides where it works, and the global key lifts the check of all
# three. An edit of any of them turns protection off silently, so the path is closed regardless of
# repository and under its own key. A project key is closed the same way by its own check.
#
# The match is deliberately coarse: a redirect TO the path or a write verb with the path in one
# command segment.
# The command-target parse was removed together with protected-write — it was the home of the class
# "the guard judges the command
# text, not the write target", which was fixed fifteen times. Precision is not needed here: nobody
# legitimately writes into the
# guard's wiring, and the cost of a rare false refusal (lifted by the key) is lower than the cost
# of a parse.
_GLOBAL_WRITE_VERBS = (
    r"rm|mv|cp|tee|touch|mkdir|truncate|install|ln|chmod|patch|ed|dd|python3?|perl|jq"
)
_MSG_KEY = (
    "The command writes the owner key. A key the agent issues to itself lifts the protection it\n"
    "was meant to hold, so it is issued only by the owner, outside this hook."
)


def _global_forms(ref: str) -> tuple[re.Pattern[str], ...]:
    """Forms of writing TO this path: a redirect, a write verb in one segment, `sed -i`."""
    quoted = re.escape(ref)
    return (
        re.compile(_join(r">>?\s*['\"]?[\w./~$-]*", quoted)),
        re.compile(_join(r"\b(?:", _GLOBAL_WRITE_VERBS, r")\b[^|;&\n]*?", quoted)),
        re.compile(_join(r"\bsed\b[^|;&\n]*?\s-i[^|;&\n]*?", quoted)),
    )


def _global_refs(groot: Path) -> list[str]:
    """Forms in which the path is written: absolute, three home ones, two by `CLAUDE_CONFIG_DIR`.

    Outside HOME — only absolute and the config-dir ones.
    """
    refs = [str(groot)]
    # An unset variable reads as `.`, and an absolute path is never under it.
    with contextlib.suppress(ValueError):
        under = groot.relative_to(Path(os.environ.get(_CONFIG_ENV, "")))
        refs.extend((f"${_CONFIG_ENV}/{under}", f"${{{_CONFIG_ENV}}}/{under}"))
    try:
        rel = str(groot.relative_to(HOME))
    except ValueError:
        return refs
    refs.extend((f"~/{rel}", f"$HOME/{rel}", f"${{HOME}}/{rel}"))
    return refs


def _writes_to(command: str, target: Path, cwd: str) -> bool:
    """A write form in the command is aimed at `target`.

    The path is matched in its absolute and home forms, and relative to `cwd` when the target lies
    under it. A relative form without a `/` is not used: from inside the target's own directory it
    is a bare name, and it would cut every command that mentions the word.
    """
    # Quotes break the anchor (`"$HOME"/…` is not equal to `$HOME/…` as a substring) — we strip
    # them from a COPY of the command: quoting $HOME is idiomatic and does not look like a bypass.
    view = command.replace("'", "").replace('"', "")
    refs = _global_refs(target)
    base = _resolve(".", cwd)
    if base in target.parents:
        relative = str(target.relative_to(base))
        if "/" in relative:
            refs.append(relative)
    return any(form.search(view) for ref in refs for form in _global_forms(ref))


def _bash_block_global_write(command: str, cwd: str) -> None:
    """Bash writes into the guard's own wiring or its global key → block. Reading is allowed."""
    for groot in GLOBAL_PROTECTED:
        if _writes_to(command, groot, cwd):
            _journal(
                _find_repo(_resolve(".", cwd)),
                "global-protection-blocked",
                str(groot),
            )
            _refuse(
                groot,
                "the guard's own wiring",
                "The command writes into the guard's wiring."
                " Reading is allowed — changing is not.",
                GLOBAL_UNLOCK,
            )


def _bash_block_key_issue(command: str, cwd: str) -> None:
    """Bash writes the cwd repository's owner key while that key is not issued → block.

    A valid key may be touched again: its lifetime is the owner's rule, not this check. An address
    equal to the repository (`unlock_file` empty or `.`) is no key, and as a target it would match
    every write in the tree — the check is silent then.
    """
    repo = _find_repo(_resolve(".", cwd))
    if repo is None:
        return
    config = _load(repo)
    unlock = _unlock_path(repo, config)
    if unlock == repo or _unlocked(repo, config):
        return
    if _writes_to(command, unlock, cwd):
        _journal(repo, "key-issue-blocked", str(unlock))
        _refuse(unlock, "the owner key", _MSG_KEY, unlock)


_MSG_DESTRUCTIVE = (
    "reset --hard / clean / branch -D / checkout . / restore . / force-push / "
    "push +ref, :ref, --delete, --mirror / rm -rf / find -delete, -exec rm / "
    "dd / chmod -R / shutdown / reboot / poweroff\n"
    "destroy work without a trace. They require the owner key."
)
_MSG_EGRESS = (
    "The command reads a secret file AND sends data to an EXTERNAL host (not in an auth header).\n"
    "This is what injection exfiltration looks like. If it is legitimate — the owner key."
)
_MSG_FETCH = (
    "curl/wget with http:// (MITM) or a bare IP, piped into bash/sh, executes\n"
    "unattributable code. Download to a file, inspect, then run. If legitimate — the owner key."
)


def _bash_block_destructive(command: str, cwd: str) -> None:
    """Opt-in gates by cwd repo: destructive act, egress, fetch-exec."""
    cwd_repo = _find_repo(_resolve(".", cwd))
    if cwd_repo is None:
        return
    ccfg = _load(cwd_repo)
    if _unlocked(cwd_repo, ccfg):
        return  # the repo is unlocked by the owner — opt-in gates are silent
    unlock = _unlock_path(cwd_repo, ccfg)
    # destructive gate: a plain push and a single rm are not touched — only irreversible scale.
    if (_flag(ccfg, "guard_destructive") or _flag(ccfg, "guard_git")) and _destructive_hit(
        command
    ):
        _journal(cwd_repo, "destructive-blocked", command)
        _refuse(
            cwd_repo,
            "destructive operation",
            _MSG_DESTRUCTIVE,
            unlock,
            _HEAD_DESTRUCTIVE,
        )
    if not _flag(ccfg, "guard_egress"):
        return
    # egress gate: secret file + sending to an external host (not an auth header) = egress.
    if _egress_exfil(command):
        _journal(cwd_repo, "egress-exfil-blocked", command)
        _refuse(
            cwd_repo,
            "possible secret egress",
            _MSG_EGRESS,
            unlock,
            _HEAD_EGRESS,
        )
    # fetch-exec gate: downloading code straight into the shell from an unsafe source.
    if _FETCH_EXEC.search(command):
        _journal(cwd_repo, "fetch-exec-blocked", command)
        _refuse(
            cwd_repo,
            "code download straight into the shell from an unsafe source",
            _MSG_FETCH,
            unlock,
            _HEAD_FETCH,
        )


_MSG_DEPENDENCY = (
    "A new dependency is the owner's decision, not the agent's: it must then be maintained,\n"
    "updated and explained to an external reviewer. Show what it gives and what\n"
    "replaces it without it (stdlib, an already installed dependency, ten lines of your own).\n"
    "Language package managers are judged: pip, poetry, uv, npm. Restoring\n"
    "the declared (npm ci, pip install -r, poetry install, uv sync) is not touched by the rule.\n"
    "The owner installs, or their key."
)
_HEAD_DEPENDENCY = "⛔ NEW DEPENDENCY IN THE PROJECT"


def _dependency_is_target(word: str) -> bool:
    """The word names the install TARGET: not a flag and not a path (`.`/`./…`, `/…`)."""
    return not word.startswith(_FLAG_PREFIX) and not word.startswith(_DEP_PATH_MARKS)


def _dependency_positional(tail: str) -> list[str]:
    """Positional words of the tail: without flags, without flag values, without paths."""
    words = []
    skip_value = False
    for word in tail.split():
        take = skip_value
        skip_value = not take and word in _DEP_FLAG_TAKES_VALUE
        if not take and not skip_value and _dependency_is_target(word):
            words.append(word)
    return words


def _dependency_names_package(tail: str) -> bool:
    """A PACKAGE is named, not a manifest, own project or bootstrap of the manager itself.

    ALL positional words are judged, not the first: `pip install wheel requests` installs both. A
    manifest
    next to a package does not lift the rule: `pip install -c c.txt requests` installs `requests`.
    """
    return any(word not in _DEP_BOOTSTRAP for word in _dependency_positional(tail))


def _dependency_in_view(view: str) -> str | None:
    """Dependency addition in the DEFUSED view of the command.

    Return the manager with the verb.
    """
    for pattern in _DEPENDENCY_ADD:
        # ALL occurrences of the pattern are iterated: the chain `pip install -r req.txt && pip
        # install X`
        # does not name a package by the first occurrence, and stopping at it would lift the rule.
        for found in pattern.finditer(view):
            # The tail is taken to the end of THIS command: past the separator stands another one,
            # and its words
            # are not a package of this one.
            tail = _DEP_SEGMENT_END.split(view[found.end() :], 1)[0]
            if _dependency_names_package(tail):
                return found.group("mgr").strip()
    return None


def _dependency_hit(command: str, depth: int = 0) -> str | None:
    """The command ADDS a dependency — return the manager with the verb; restore → None.

    The same view as for the destructive act is parsed: a verb inside quotes and in a heredoc body
    is data,
    not a command, otherwise a document that says `pip install …` could not be written. Launchers
    are recursed into: `bash -c '<verb>'` would otherwise lift the rule entirely.
    """
    hit = _dependency_in_view(_cmd_view(_strip_heredocs(command)))
    if hit is not None or depth >= _LAUNCH_DEPTH_MAX:
        return hit
    for script in _launcher_scripts(command):
        hit = _dependency_hit(script, depth + 1)
        if hit is not None:
            return hit
    return None


def _bash_block_dependency(command: str, cwd: str) -> None:
    """Install of a NEW dependency in a managed repository → block.

    The `guard_dependency` regulator is read with default ON: the rule works in a project
    that did not declare it. Lifted by the owner key or `guard_dependency = false`.
    """
    repo = _find_repo(_resolve(".", cwd))
    if repo is None:
        return
    config = _load(repo)
    if _unlocked(repo, config) or not _flag(config, "guard_dependency", default=True):
        return
    verb = _dependency_hit(command)
    if verb is None:
        return
    _journal(repo, "dependency-blocked", command)
    _refuse(
        repo,
        f"new dependency ({verb})",
        _MSG_DEPENDENCY,
        _unlock_path(repo, config),
        _HEAD_DEPENDENCY,
    )


_HEAD_UNPARSED = "⛔ PROJECT CONFIG NOT PARSED"
_MSG_UNPARSED = (
    "A value in .retainer/config.toml opens and never closes (an array or a multiline string),\n"
    "or the file is not UTF-8. Every key after the break is lost, so the guard does not know\n"
    "which gates the project turned on — it refuses every command here until the file is fixed.\n"
    "The owner key lifts this refusal: at the declared unlock_file, or at the default\n"
    ".retainer/unlock when the declared one is lost after the break or broken itself."
)


def _bash_block_unparsed(cwd: str) -> None:
    """The cwd repository's config lost keys to a syntax error → every command is refused.

    The owner key is checked first and lifts the refusal at the declared address. The default
    address is the way out only when the declared one is lost after the break or broken: where a
    custom address was read, nothing guards writes to the default one. The sign is tested by its
    presence: its value is `0` for a file that is not UTF-8.
    """
    repo = _find_repo(_resolve(".", cwd))
    if repo is None:
        return
    config = _load(repo)
    if _UNPARSED_KEY not in config or _unlocked(repo, config):
        return
    lost = _UNLOCK_KEY not in config or _unlock_path(repo, config) == repo
    if lost and _unlocked(repo, {}):
        return
    line = config[_UNPARSED_KEY]
    where = f"line {line} never closes" if line else "the file is not UTF-8"
    _journal(repo, "config-unparsed-blocked", where)
    _refuse(
        repo,
        f"config not parsed ({where})",
        _MSG_UNPARSED,
        _unlock_path(repo, {} if lost else config),
        _HEAD_UNPARSED,
    )


def _handle_bash(args: Config, cwd: str) -> None:
    """PreToolUse for Bash: wiring, config parsed, owner key → dependency → destructive, egress."""
    command = str(args.get("command", ""))
    if not _global_unlocked():
        _bash_block_global_write(command, cwd)
    _bash_block_unparsed(cwd)
    _bash_block_key_issue(command, cwd)
    _bash_block_dependency(command, cwd)
    _bash_block_destructive(command, cwd)


def main() -> None:
    """Hook entry point: ONLY Bash is judged, write tools are closed by the native deny.

    The only argument is `--global-protected`: it prints the global self-protection paths, one
    per line. This is a MACHINE INTERFACE for reconciliation with the harness `deny`: the list must
    be taken from the guard
    itself, otherwise it would drift from the guard silently — the same class as a registry in two
    places.
    """
    if sys.argv[1:2] == ["--global-protected"]:
        for path in GLOBAL_PROTECTED:
            sys.stdout.write(f"{path}\n")
        sys.exit(0)
    payload = json.load(sys.stdin)
    if payload.get("tool_name", "") == "Bash":
        _handle_bash(payload.get("tool_input", {}), payload.get("cwd", ""))
    sys.exit(0)


if __name__ == "__main__":
    main()
