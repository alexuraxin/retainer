"""hook_wiring_scan: where a hook command points in a settings-like JSON.

One parsing point for three wirings — global (`~/.claude/settings.json`), project
(`<project>/.claude/settings.json`) and plugin (`hooks/hooks.json`): same schema everywhere,
`hooks.<Event>[].hooks[].command`. Three copies of this parse existed (two in the wiring test, one
in
`bin/guard-wiring-check.sh`) and drifted apart — different junk guards, different
output separators. Drifted copies of a wiring check are the same defect one level up.

Why at all. A substring check "the guard name occurs in the file" cannot tell a live wiring from a
stale one. A managed-project clone ran without the guard exactly so: the path into another project
went stale on
relocation, the word `guard_discipline` stayed in the file, the check reported "wired".

Parse BOUNDARY. Only the simple form "[VAR=…] interpreter [options] path" is parsed. A compound
command (pipe, `&&`, substitution), an unexpanded variable, unbalanced quotes — is `None`, "cannot
parse", NOT "stale". No verdict is passed on the unparsed: a false red on a healthy
wiring costs more than a missed dead one, because then the check is what gets fixed.

A separate module, not functions in `gate_wiring_scan.py`: that one has exactly 7 members — the
WPS202 ceiling, and
loosening lint for reuse costs an owner key plus a RATCHET line. The subject differs too:
there it is a step inside `gate.sh`, here a hook command. A library, not a CLI — the interface
outward is given by
the engine bash scripts that import it.
"""

from __future__ import annotations

import pathlib
import re
import shlex
from collections.abc import Iterator

# Wiring: (event, command) for a live one, (event, path) for a stale one. An alias, not a bare
# tuple in
# annotations: without it the `guard_wirings` signature fails the annotation complexity threshold.
Wiring = tuple[str, str]
Split = tuple[list[Wiring], list[Wiring]]

GUARD_MARK = "guard_discipline"
PLUGIN_VAR = "${CLAUDE_PLUGIN_ROOT}"

# Compound command: the target may be created left of the pipe, and `sed 's|a|b|'` contains a
# separator
# indistinguishable from a pipe without parsing the whole shell. Both ends are "cannot parse", not
# a verdict.
_COMPOSITE = re.compile(r"[|;&<>`\n]|\$\(")
_ASSIGN = re.compile(r"^[A-Za-z_]\w*=")
# The interpreter is stripped: live wirings include `python3 <path>`, `bash <path>`, and
# the absolute form `/usr/bin/python3 <path>` — whose first slash-token ALWAYS exists,
# so "first path in the command" would call any dead wiring of that form live. The plugin's own
# launcher `retainer-python` is an interpreter in this sense: the hook file is the argument after
# it.
_RUNNERS = frozenset(
    (
        "python",
        "python2",
        "python3",
        "bash",
        "sh",
        "zsh",
        "dash",
        "node",
        "deno",
        "ruby",
        "perl",
        "uv",
        "uvx",
        "env",
        "retainer-python",
    )
)
_SUFFIXES = (".py", ".sh", ".js", ".rb", ".pl", ".ts")


def _commands_of(matcher: object) -> Iterator[str]:
    """Commands of one matcher. Junk is skipped silently, not a parse crash.

    `settings.json` is hand-edited, and a string instead of an object in the hooks array happens. A
    crashed
    parse would yield "check failed" with a python traceback in the gate output — exactly the
    state this module exists to eliminate.
    """
    hooks = matcher.get("hooks") if isinstance(matcher, dict) else None
    for hook in hooks if isinstance(hooks, list) else []:
        if isinstance(hook, dict) and hook.get("command"):
            yield str(hook["command"])


def hook_commands(blob: object) -> Iterator[Wiring]:
    """Hook commands from a settings-like JSON: (event, command)."""
    events = blob.get("hooks") if isinstance(blob, dict) else None
    for event, matchers in (events or {}).items():
        for matcher in matchers if isinstance(matchers, list) else []:
            for command in _commands_of(matcher):
                yield str(event), command


def _is_wrapper(word: str) -> bool:
    """Token wrapping: env assignment, option, interpreter — cannot be the hook target."""
    if _ASSIGN.match(word) or word.startswith("-"):
        return True
    return pathlib.PurePath(word).name.split(".")[0] in _RUNNERS


def _target_word(command: str) -> str | None:
    """Command target token. `None`.

    "cannot parse" or the command is not about a file (builtin).
    """
    if _COMPOSITE.search(command):
        return None
    try:
        words = shlex.split(command)
    except ValueError:
        return None  # unbalanced quotes: guessing the target here is worse than refusing
    for word in words:
        if _is_wrapper(word):
            continue
        return word if "/" in word or word.endswith(_SUFFIXES) else None
    return None


def hook_target(
    command: str,
    *,
    plugin_root: pathlib.Path,
    anchor: pathlib.Path,
) -> pathlib.Path | None:
    """The file the hook will run. `None` — "cannot parse" or the command is not about a file.

    `anchor` — what a RELATIVE path is resolved from. Without an anchor the verdict would depend on
    the directory
    the check was called from: in project mode the anchor is the project, in registration mode
    HOME.
    """
    word = _target_word(command.replace(PLUGIN_VAR, str(plugin_root)))
    if word is None or "$" in word:
        return None  # unexpanded variable (`$CLAUDE_PROJECT_DIR`) — nothing to judge by
    try:
        goal = pathlib.Path(word).expanduser()
    except (RuntimeError, KeyError):
        return None  # `~nosuchuser/hook.py` — expanduser raises instead of returning a path
    return goal if goal.is_absolute() else anchor / goal


def guard_wirings(
    blob: object,
    *,
    plugin_root: pathlib.Path,
    anchor: pathlib.Path,
    mark: str = GUARD_MARK,
) -> Split:
    """Guard wirings: (live, stale). A live one carries the command second, a stale one the target.

    Only hooks whose command contains `mark` are judged. A foreign dead formatter hook is
    irrelevant to
    "is the guard wired", and a verdict on it would advise routing prettier through the plugin
    root. `mark` is a parameter — the same parse lets the test check sink wiring and memory probes.

    A directory target counts as stale: a hook pointing at a folder fails "is a directory". An
    unparsed command goes to live: "don't know" is no reason to declare the guard dead.

    The event is returned for live ones too: "wired, but on the wrong event" is its own question,
    and the
    caller must decide it from this data, not by a second parse of the same file.
    """
    live, dead = [], []  # type: (list[Wiring], list[Wiring])
    for event, command in hook_commands(blob):
        if mark not in command:
            continue
        goal = hook_target(command, plugin_root=plugin_root, anchor=anchor)
        if goal is None or goal.is_file():
            live.append((event, command))
        else:
            dead.append((event, str(goal)))
    return live, dead


def describe(wirings: list[Wiring]) -> str:
    """Wirings as one line for output: "event → target · event → target".

    Formatting lives here, not in three callers: two parse copies already drifted on the
    separator (`->` vs `→`), and check output started depending on who prints.
    """
    return " · ".join(f"{event} → {target}" for event, target in wirings)
