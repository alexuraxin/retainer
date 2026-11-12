#!/usr/bin/env python3
"""The project hot core into the session context — feeding instead of hoping it is read.

What this is
────────────
A `SessionStart` event hook. Sections declared by the project with the `start` key (default —
"What NOT to do" and "Known pitfalls"), the route of the task in work and the session mode go into
the agent's context through `hookSpecificOutput.additionalContext`. Matchers: `startup`, `resume`,
`clear`, `compact`.

The session mode is the one line the OWNER sees too, through `systemMessage`: the autonomy level,
the merge step, the question gate and a link to the settings page. In a marathon the agent merges
by itself; without this line the owner learns it after the merge, too late to switch merge to
manual. All three values come from the engine's `retainer-flow-policy.sh`; a value it does not give
is shown as `unknown`, and the line with the link stays — a missing line would look exactly like
"nothing to say".

Only the terminal draws `systemMessage`. On any other surface the agent is told, beside the
mode line, to say it at the start of its first reply, on a new conversation only (`startup`,
`clear`): on `resume` and `compact` the conversation is already under way, and the line would
repeat mid-run. In a marathon the agent is also told to end the run's final report with the
settings link, once; that ask goes on every matcher, since a compaction rebuilds its context.

`compact` is significant in this list on its own: after compaction the context is rebuilt, and a
core fed once at start would go away with it. `fork` is deliberately NOT included — a fork inherits
the parent's context, and re-feeding it would duplicate.

`UserPromptSubmit` is not included either: the coverage equals that of the `SessionStart` +
`PreToolUse` pair, while it is paid for on every turn.

Failure class
─────────────
Fail-open, like the neighbouring advisor and in contrast to the guard: any internal failure is
silence and exit code zero. A hook that crashed session start through its own error would cost more
than everything it feeds. A missing library is silence too. A corrupted library file
(`SyntaxError`) is NOT caught and is not part of the failure class: the plugin is copied as a whole
tree, and a broken file goes red on the gate before release.

The `sys.path` boundary
───────────────────────
The hook is called by absolute path, so its directory lands in `sys.path[0]` by itself and the
neighbour loads without a path edit (ADR 0005). Two modes are not covered by that: loading the
module by path (which is how the corpus takes it) and running with `-P` / `PYTHONSAFEPATH=1`,
where the script directory is removed from the path. Inserting the directory below closes both.

A foreign tree
──────────────
The sign of a tree the engine answers for is `.retainer/config.toml` upward through the
directories. Outside such a tree the project core, the route and the mode stay silent: feeding
foreign context in a foreign project is noise from which it is impossible to tell what it refers
to.

Missing tools
─────────────
One exception to that silence: on a fresh `startup`, in any directory, the owner is told which
required or recommended machine tools are missing (`bin/retainer-install.sh --summary`). A clean
machine has no project yet, and that is where the line is needed. It is not repeated on `resume`,
`clear` or `compact`, and it is not remembered either: a tool installed between sessions simply
stops being named.
"""

from __future__ import annotations

import contextlib
import importlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from types import MappingProxyType, ModuleType

_UTF8 = "utf-8"
MARKER = Path(".retainer", "config.toml")
_HEADER = "Project context ({document}) — fed by the mechanism, not read by the agent:"
_ROUTE_SCRIPT = "retainer-route.sh"
# Session start is synchronous, so the ceiling is tight: a slow tracker costs silence,
# not a delayed session. The phase walk breaks as soon as it finds the branch, so the
# usual cost is one page.
_ROUTE_TIMEOUT = 10
_POLICY_SCRIPT = "retainer-flow-policy.sh"
# The ceiling of ONE resolver call; the usual cost is a bash start.
_POLICY_TIMEOUT = 3
_INSTALL_SCRIPT = "retainer-install.sh"
# The summary script's path; the corpus points it at a stub, the real one reads this machine.
_INSTALL_ENV = "RETAINER_INSTALL_SUMMARY"
# A machine check is a dozen `command -v` calls; a slow one costs the line, not the session.
_INSTALL_TIMEOUT = 2
# What may reach the owner's screen: the mode line this hook builds, and the installer summary in
# its own form only — one line naming the command.
_OWNER = re.compile(r"\A(?:Session mode: |retainer: [^\n]*/retainer:install\Z)")
_FRESH = "startup"
_MODE_STEPS = ("level", "merge", "ask_owner")
_UNKNOWN = "unknown"
# The words the resolver answers with — step policies and levels. Anything else is shown as
# `unknown`: a stray line of resolver output must not reach the owner's screen.
_POLICY_WORDS = MappingProxyType(
    {word: word for word in ("auto", "ask", "off", "manual", "assisted", "marathon")},
)
_MODE_LINE = "Session mode: {level} · merge {merge} · questions {ask_owner} — settings: {url}"
_MODE_PREFIX = _MODE_LINE.partition("{")[0]
# The terminal draws `systemMessage`; any other surface is treated as one that does not. Claude
# Code sets this variable for the processes it starts.
_ENTRYPOINT_ENV = "CLAUDE_CODE_ENTRYPOINT"
_TERMINAL = "cli"
# A conversation starts on these; on `resume` and `compact` it is already under way.
_FIRST_TURN = frozenset((_FRESH, "clear"))
_SAY_FIRST = (
    "The owner's surface does not show the `Session mode:` line above: say that line to them,"
    " as it is, at the start of your first reply. Once."
)
_SAY_LAST = (
    "In a marathon, end the final report of the run with one line: settings — {url}. Once, not on"
    " every step."
)
# The settings server's port rule (`bin/retainer_settings_server.py#wanted_port`), except that 0
# gives the default too: an ephemeral port cannot be named in a link.
_SETTINGS_PORT_ENV = "RETAINER_SETTINGS_PORT"
_SETTINGS_PORT = 8765
_PORT_MAX = 65535
_SETTINGS_URL = "http://127.0.0.1:{port}/retainer-settings.html"

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))
# The ENGINE's scripts, from this file — not the fed tree. A project has no `bin/` of its own,
# and a lookup there would find nothing outside the engine's repository. ADR 0005.
_BIN = _HERE.parent / "bin"
_ROUTE = _BIN / _ROUTE_SCRIPT
_POLICY = _BIN / _POLICY_SCRIPT
_INSTALL = Path(os.environ.get(_INSTALL_ENV) or _BIN / _INSTALL_SCRIPT)
# Import by call, not by statement: a statement after the path edit would give E402, and one
# wrapped
# in a catch would also assign `None` to a module, which strict mypy accepts only with a
# suppression. Neither is needed here.
_LIB: ModuleType | None = None
with contextlib.suppress(ImportError):
    _LIB = importlib.import_module("project_context")


def _core(root: Path) -> str:
    """The project core for this tree; empty when there is no library or nothing was declared."""
    if _LIB is None:
        return ""
    core = str(_LIB.core(root))
    if not core:
        return ""
    said = _HEADER.format(document=_LIB.document(root)[0])
    return f"{said}\n\n{core}"


def _run(
    script: Path,
    args: tuple[str, ...],
    timeout: int,
    cwd: Path | None = None,
    session: object = None,
) -> str | None:
    """Stdout of an engine bash script that exited 0; None when absent, failed or too slow.

    Fail-open, like everything in this hook. The task marker is per session and the event names the
    session, inheritance may not: a compacted session keeps its id, and this is the moment it must
    find its own task again.
    """
    if not script.is_file():
        return None
    env = dict(os.environ)
    if session:
        env["CLAUDE_CODE_SESSION_ID"] = str(session)
    try:
        done = subprocess.run(
            ["bash", str(script), *args],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
            env=env,
        )
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    return done.stdout.strip() if done.returncode == 0 else None


def _owner(root: Path | None, event: dict[str, object]) -> list[str]:
    """The lines the owner sees: the session mode inside a managed tree, missing tools on a start.

    The mode line is empty only where the engine carries no resolver at all; a resolver answer
    outside its own words is shown as `unknown`, so a stray line of its output never reaches the
    owner's screen. The link is on the port the settings server picks from the same variable.
    """
    summary = (
        _run(_INSTALL, ("--summary",), _INSTALL_TIMEOUT) if event.get("source") == _FRESH else None
    )
    lines = [summary]
    if root and _POLICY.is_file():
        raw = os.environ.get(_SETTINGS_PORT_ENV, "")
        port = int(raw) if raw.isdecimal() else 0
        if not 0 < port <= _PORT_MAX:
            port = _SETTINGS_PORT
        lines.insert(
            0,
            _MODE_LINE.format(
                url=_SETTINGS_URL.format(port=port),
                **{
                    step: _POLICY_WORDS.get(
                        _run(_POLICY, (step,), _POLICY_TIMEOUT, cwd=root) or "",
                        _UNKNOWN,
                    )
                    for step in _MODE_STEPS
                },
            ),
        )
    return [line for line in lines if line and _OWNER.match(line)]


def _asks(owner: list[str], event: dict[str, object]) -> list[str]:
    """What the agent is told to say about the mode line; never shown to the owner.

    Nothing without the mode line. The first-reply ask on a new conversation on a surface other
    than the terminal; the final-report ask in a marathon, on every matcher.
    """
    mode = next((line for line in owner if line.startswith(_MODE_PREFIX)), "")
    if not mode:
        return []
    asks = []
    drawn = os.environ.get(_ENTRYPOINT_ENV, "") == _TERMINAL
    if event.get("source") in _FIRST_TURN and not drawn:
        asks.append(_SAY_FIRST)
    if mode.startswith(f"{_MODE_PREFIX}marathon "):
        url = mode.rsplit(" ", 1)[-1]
        asks.append(_SAY_LAST.format(url=url))
    return asks


def _tree_root(event: dict[str, object]) -> Path | None:
    """The nearest directory up from the event's cwd that the engine answers for."""
    cwd = Path(str(event.get("cwd") or "."))
    tree = (cwd, *cwd.parents)
    return next((up for up in tree if (up / MARKER).is_file()), None)


def _said(event: dict[str, object]) -> dict[str, object]:
    """The hook's JSON answer for this event; empty — nothing to say.

    The core, the route and the mode are INDEPENDENT. `_core` is empty when the neighbour library
    did not import or the project declared nothing, and neither is a reason to lose the route; the
    route is empty when no task is active, which is no reason to lose the core. Only the tree test
    is shared: outside a tree the engine answers for, all three stay silent. The missing-tools line
    is not bound to a tree.
    """
    root = _tree_root(event)
    # The route is fed at session start for the same reason the core is: after compaction the
    # context is rebuilt, and a route the agent held in its head goes away with it.
    found = (
        (
            _core(root),
            _run(_ROUTE, (str(root), "--full"), _ROUTE_TIMEOUT, session=event.get("session_id")),
        )
        if root
        else ()
    )
    owner = _owner(root, event)
    parts = [part for part in (*found, *owner) if part]
    # The asks are never empty strings, so they join after the filter.
    parts.extend(_asks(owner, event))
    if not parts:
        return {}
    said: dict[str, object] = {
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": "\n\n".join(parts),
        },
    }
    if owner:
        said["systemMessage"] = "\n".join(owner)
    return said


def main() -> None:
    """Entry point: feeding cancels and delays nothing, so any failure is exit code zero."""
    said: dict[str, object] = {}
    with contextlib.suppress(Exception):
        said = _said(json.loads(sys.stdin.read() or "{}"))
    with contextlib.suppress(Exception):
        if said:
            # Write BYTES and set the encoding ourselves: in an eight-bit non-UTF-8 locale the text
            # stdout does not accept non-ASCII, and the core would vanish without a trace.
            text = json.dumps(said, ensure_ascii=False)
            sys.stdout.buffer.write(text.encode(_UTF8))
        # Close HERE, inside the suppression: what was written sits in the buffer, and a broken
        # pipe
        # fails not at the write but at interpreter finalisation — outside any suppression.
        sys.stdout.close()
    sys.exit(0)


if __name__ == "__main__":
    main()
