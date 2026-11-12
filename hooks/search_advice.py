#!/usr/bin/env python3
r"""The search-hint branch of the write advisor: a grep for a code name is pointed at the graph.

What it judges
──────────────
The pattern of a `Grep` call, or of a `grep`/`rg`/`egrep` in a `Bash` command. It speaks only
when the pattern is ONE identifier that reads as a code name -- an underscore or an inner capital
(`_attach_costs`, `MapEdge`), optionally wrapped in `\b` -- and graphify is installed. A phrase, a
regex, a plain word and a path are silent: the graph answers who calls a function, not where a
string appears, and a hint on every grep would be noise the agent learns to skip.

The answer it names is the engine command, by absolute path: in a project the command is not on
PATH, and a bare name would lead nowhere. The command rebuilds a stale graph itself, so the hint
never points at an answer about code that is no longer there.

What it does NOT do: judge whether the tree has a graph yet (the first query builds one), read a
pattern from a file (`grep -f` is silent), or parse a pipeline beyond the first search command.

The caller climbs to the managed tree and owns the once-per-turn mark: this module receives the
mark function and asks it only when it is about to speak, so a silent call never spends the mark.
"""

# complexity: keep, step 2 — without it a grep for a function name never meets the graph

from __future__ import annotations

import re
import shlex
import shutil
from collections.abc import Callable
from pathlib import Path

Event = dict[str, object]

_MARK = "graph-search"
_SEARCH_TOOLS = frozenset(("grep", "egrep", "rg"))
# Options whose value is the next word: the pattern is not that value.
_VALUED = frozenset(
    (
        "-A",
        "-B",
        "-C",
        "-d",
        "-m",
        "-g",
        "-t",
        "--context",
        "--directories",
        "--glob",
        "--max-count",
        "--type",
    )
)
# Options that read the patterns from a file: the command line then holds no pattern at all.
_FROM_FILE = frozenset(("-f", "--file"))
_WORD = re.compile(r"\\b(?P<name>[A-Za-z_]\w*)\\b|(?P<bare>[A-Za-z_]\w*)")
# A code name: an underscore before a letter or digit, or an inner capital; at least one lowercase
# letter (a CONSTANT is no graph node); a dunder like `__init__` names too many nodes to answer.
_CODE_NAME = re.compile(r"(?=\w*[a-z])(?!__\w*__\Z)\w*(?:_[A-Za-z0-9]|[a-z][A-Z])\w*")
_SHORTEST = 4
_TEXT = (
    'The code graph answers "{name}" without a grep: {command} explain "{name}" -- where it'
    " is defined, who calls it, what it depends on; it rebuilds the graph first when the code"
    " changed. Grep stays the tool for strings, properties and templates."
)


def _search_words(command: str) -> list[str]:
    """The words after the first search command in a shell line; empty when there is none."""
    # An unquoted `\b` would lose its backslash to the shell parse and glue a `b` to the name.
    try:
        words = shlex.split(command.replace(r"\b", ""))
    except ValueError:
        return []
    tools = [Path(word).name in _SEARCH_TOOLS for word in words]
    if True not in tools:
        return []
    first = tools.index(True) + 1
    return words[first:]


def _bash_pattern(command: str) -> str:
    """The pattern of the first search command in a shell line; empty when there is none."""
    words = iter(_search_words(command))
    for word in words:
        if word in _FROM_FILE:
            return ""
        if word in _VALUED:
            next(words, "")
        elif not word.startswith("-"):
            return word
    return ""


def _name(pattern: str) -> str:
    """The code name the pattern is, or empty when it is anything else."""
    found = _WORD.fullmatch(pattern)
    if found is None:
        return ""
    name = found.group("name") or found.group("bare") or ""
    if len(name) < _SHORTEST or not _CODE_NAME.fullmatch(name):
        return ""
    return name


def hint(event: Event, plugin_root: Path, checked: Callable[[Event, str], bool]) -> str:
    """The hint text for this call, or empty; `checked` is asked only when it would speak."""
    args = event.get("tool_input")
    if not isinstance(args, dict):
        return ""
    tool = event.get("tool_name")
    if tool == "Grep":
        pattern = str(args.get("pattern", ""))
    elif tool == "Bash":
        pattern = _bash_pattern(str(args.get("command", "")))
    else:
        return ""
    name = _name(pattern)
    if not name or shutil.which("graphify") is None or checked(event, _MARK):
        return ""
    command = plugin_root / "bin" / "retainer-graph.sh"
    return _TEXT.format(name=name, command=command)
