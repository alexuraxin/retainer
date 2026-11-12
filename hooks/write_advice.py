#!/usr/bin/env python3
"""Advisor on write events: the skill matching the kind of file being edited is picked.

What this is and how it differs from its neighbor
─────────────────────────────────────────────────
Next to it on the same event stands the guard (`guard_discipline.py`). It is fail-closed and judges
the IRREVERSIBLE: it cancels the call with exit 2. This hook is the opposite in failure class: it
is
fail-open, cancels nothing and never exits with a code other than zero. Any failure inside is
silence.

It does not judge protected paths at all and has nothing to do with protection: its subject is the
choice of a tool for the work, not the right to write a file.

The failure it exists for: the check "which skill is needed" fires once, at the first step of a
session, for the kind of work at that moment. Later the kind changes (tracker -> layout) and there
is
no reclassification: there is no "what type of work is this" step at all. So the hook, not the
agent's memory, executes the rule -- memory has already been tried.

What is judged
──────────────
The write target: the path of `Write`/`Edit`, the redirect and `tee` targets of `Bash`. Redirects
are
mandatory -- the very HTML was written via a heredoc into `cat >`, and a detector on write tools
alone would miss the case entirely.

What is NOT judged, named rather than forgotten: a write via `sed -i`, `cp`, `mv`, `install`,
`awk > file` and via a script that opens the file itself; masks are case-sensitive, so `page.HTML`
slips by. Heredoc bodies are not parsed, so text like > style.css inside HTML gives a hint without
a
real layout write -- the price of a narrow regex, taken instead of a copy of the guard's lexer.

When what was said arrives
──────────────────────────
The hook stands BEFORE the call, but the agent reads what it said together with the tool result:
the
order in the transcript is the call, the file write, the hook attachment, the result. So the first
file of a kind of work is written without the hint, and it saves everything after it. More cannot
be
promised: the mechanism does not do that.

The message has two addressees on different channels -- the human reads `systemMessage`, the agent
only `additionalContext`; both are written.

The table of work kinds is data, not code: `write_advice.rules` next to this file. Adding a work
kind
means adding a row, not editing the hook.

Three branches, and they are independent
────────────────────────────────────────
The first names a SKILL for the kind of file being edited. The second feeds a project-context
SECTION for the same kind -- the pitfalls the project wrote about itself, which the agent reads
only if it decides to open the file. The third, in `search_advice.py`, judges not a write but a
search: a grep for a code name gets the code-graph command. The event, channel and failure class
of the branches coincide, so they live in one hook: three hooks would mean three python processes
per call in every project.

Any of them may fire -- the texts are printed separated by a blank line, in a fixed order. The
"checked in this turn" mark of each branch is SEPARATE (skill name, section heading, the search
key), otherwise one would silence another and the later hint would never appear.

Table parsing and section extraction live in neighbors: `project_context.py` decides what to feed
and relies on `project_doc.py`, which reads the sources. They have three readers -- this hook, the
session start hook and the gate step -- and this file has exactly seven functions, the WPS202
ceiling. Loading the neighbor is fail-open: no module means silence and exit zero.
"""

from __future__ import annotations

import contextlib
import fnmatch
import importlib
import json
import os
import re
import sys
from pathlib import Path
from types import ModuleType

# Harness event: values are heterogeneous (string / argument dict) -- the honest type is `object`.
Event = dict[str, object]

_UTF8 = "utf-8"

HOME = Path.home()
# State lives where the "done" gate state does: one home per engine.
STATE = HOME / ".cache" / "retainer" / "guard_state"
# Seam for the probe: the corpus swaps the table without touching the shipped one. It can also mute
# the hint -- it is not protection, and the price is accepted deliberately. Read at process start,
# and the hook is launched on every call, so no separate re-reading is needed.
RULES_ENV = "RETAINER_ADVICE_RULES"
_HERE = Path(__file__).resolve().parent
RULES = Path(os.environ.get(RULES_ENV) or _HERE / "write_advice.rules")
# Marker of a tree the engine is responsible for. Outside such a tree the hook is silent: a hint in
# a
# foreign directory is noise from which one cannot tell what it refers to.
MARKER = Path(".retainer", "config.toml")
_WRITE_TOOLS = frozenset(("Write", "Edit"))

# The hook is called by absolute path, so its directory lands in `sys.path[0]` by itself, and the
# neighbor loads without a path edit (ADR 0005). This does not cover two modes: loading the module
# BY
# PATH (the corpus takes it so -- otherwise the probe would read the live file and go green on a
# mutant) and a launch with `-P` / `PYTHONSAFEPATH=1`, where the script directory is removed from
# the
# path. The insertion below closes both.
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))
# Import by CALL, not by statement: a statement after the path edit would give E402, and wrapped in
# a
# catch it would also assign `None` to a module, which strict mypy accepts only with a suppression.
#
# The failure class mirrors the guard (ADR 0005 §2): there a load failure is closed with exit 2,
# here
# the advisor must stay silent. A corrupted library file (`SyntaxError`) is NOT caught and is not
# in
# the failure class: the plugin is copied as a whole tree, and a broken file goes red at the gate
# before release.
_LIB: ModuleType | None = None
with contextlib.suppress(ImportError):
    _LIB = importlib.import_module("project_context")
# The third branch, the search hint, lives in its own neighbor for the same ceiling, loaded the
# same way.
_SEARCH: ModuleType | None = None
with contextlib.suppress(ImportError):
    _SEARCH = importlib.import_module("search_advice")
# Redirect target. The `2>&1` form has no target and is defused by the character CLASS: `&` is
# excluded from it, so there is nothing to match after `>`. A check for a descriptor before `>` is
# absent deliberately -- it would cut `1>`, `&>` and `2>`, exactly the forms that write to a named
# file, and would create a blind spot instead of closing one.
# The opening quote is optional but allowed: a path through a directory variable is written quoted
# (`cat > "$SCRATCH/page.html"`), and without it the most likely form of the observed case would
# not
# be caught at all. The same class eats the closing one.
_REDIRECT = re.compile(r">>?\s*[\"']?([^\s;|&<>()'\"]+)")
_TEE = re.compile(r"(?:^|[\s|;&])tee\b(?:\s+-\S+)*\s+[\"']?([^\s;|&<>()'\"]+)")
# Mark name: a skill has a colon, a session id only safe characters.
_UNSAFE = re.compile(r"[^\w.-]+")
_TEXT = (
    "Work kind: {worktype} (write target: {target}). The skill for it is not taken in this"
    " session: {skill}.\nTake it before the next edit of the same kind. If you think it is not"
    " needed here, record that in the task rather than deciding silently."
)
_CONTEXT = (
    'Project context for this kind of work -- section "{section}" from {document}.'
    " Fed by the mechanism, not read by the agent:\n\n{body}"
)


def _targets(event: Event) -> list[str]:
    """Where the call writes: the path for write tools, redirect and `tee` targets for Bash."""
    args = event.get("tool_input")
    if not isinstance(args, dict):
        return []
    name = event.get("tool_name")
    if name in _WRITE_TOOLS:
        return [str(args.get("file_path", ""))]
    if name != "Bash":
        return []
    command = str(args.get("command", ""))
    return _REDIRECT.findall(command) + _TEE.findall(command)


def _skill(event: Event, names: list[str]) -> str:
    """First branch: the skill for the kind of file being edited.

    If it is not taken in this session.

    The text is assembled here, not at the caller: the kind name and target are known exactly at
    the
    moment of the match, and dragging them further means holding three values where one is needed.
    """
    if _LIB is None:
        return ""
    for worktype, mask, skill in _LIB.rules(RULES):
        found = fnmatch.filter(names, mask)
        if not found:
            continue
        seen = str(event.get("transcript_path") or "")
        if _checked(event, skill) or _taken(seen, skill):
            return ""
        return _TEXT.format(worktype=worktype, target=found[0], skill=skill)
    return ""


def _context(event: Event, root: Path, names: list[str]) -> str:
    """Second branch: the project-context section for the kind of file being edited.

    The "checked in this turn" mark is its OWN here -- the key is the section heading, not the
    skill
    name. A shared key would mean that the branch that fires first silences the second for the
    whole turn.

    No section with the declared heading in the document -- silence: a hint has no right to stop
    work. The gate step, which reads the same table, makes this loss visible.
    """
    if _LIB is None:
        return ""
    hit = _LIB.advice(root, names)
    if hit is None or _checked(event, str(hit[0])):
        return ""
    title, body, doc = hit
    return _CONTEXT.format(section=title, document=doc, body=body)


def _taken(transcript: str, skill: str) -> bool:
    """Is the skill taken in this session?

    Markers are exact: a skill tool call and the slash form. Searching for the bare name would
    count
    any MENTION as taking -- including the text of this very hint, which goes into the same
    transcript, and the mechanism would silence itself from the second firing.

    Transcript unavailable -- the answer is "not taken", not "taken": there is nothing to check
    with,
    and silence here is indistinguishable from a passed check. An extra hint cancels nothing, a
    lost
    one cancels the whole mechanism.
    """
    seek = re.compile(
        r'"skill"\s*:\s*"{0}"|<command-name>/{0}</command-name>'.format(re.escape(skill)),
    )
    try:
        with Path(transcript).open(encoding=_UTF8, errors="replace") as lines:
            return any(seek.search(line) for line in lines)
    except OSError:
        return False


def _checked(event: Event, skill: str) -> bool:
    """Was this kind of work already checked in this turn? Mark it if not yet.

    The mark is set in BOTH outcomes -- when it spoke and when it stayed silent: it is about the
    check, not about what was said. Otherwise, with the skill taken, the transcript would be read
    on
    every write, and in a long session it is megabytes.

    A subagent is counted separately: its session id, turn and transcript are the same as the main
    thread's, and on a shared slot only whoever wrote first would get the hint.

    State unwritable (no HOME, a read-only directory) -- the answer is "not checked". The hint
    still
    works, but there is no saving on transcript reading: the price of fail-open in this direction.
    """
    turn = str(event.get("prompt_id") or event.get("session_id") or "-")
    name = f"advice-{event.get('session_id')}-{event.get('agent_id')}-{skill}"
    slot = STATE / _UNSAFE.sub("_", name)
    seen = ""
    with contextlib.suppress(OSError):
        seen = slot.read_text(encoding=_UTF8)
    if seen == turn:
        return True
    with contextlib.suppress(OSError):
        STATE.mkdir(parents=True, exist_ok=True)
        slot.write_text(turn, encoding=_UTF8)
    return False


def _advise(event: Event) -> str:
    """The advice text for this call; empty -- nothing to say.

    Both branches judge ONE and the same input -- the write target names -- so the names are
    computed
    here and passed on, not fetched by each branch anew.

    The entry point assembles the protocol shape: the decision is here, the output there.
    """
    # The climb is its own, not shared with the guard, and the difference is named: the guard
    # solves the
    # same question with the plugin cache excluded and the file path normalized. Neither is needed
    # here -- the project config does not ship in the distribution, and cwd arrives as a directory.
    # If
    # either of the two diverges, come here too.
    #
    # The repository root, not cwd, is needed by the second branch: the project document and the
    # declaration table lie next to the config, and from a subdirectory they cannot be found
    # otherwise.
    cwd = Path(str(event.get("cwd") or "."))
    tree = (cwd, *cwd.parents)
    root = next((up for up in tree if (up / MARKER).is_file()), None)
    if root is None:
        return ""
    names = [Path(target).name for target in _targets(event)]
    # The search branch judges the search pattern, not the write targets; the turn mark is handed
    # to it and asked only when it is about to speak.
    search = "" if _SEARCH is None else _SEARCH.hint(event, _HERE.parent, _checked)
    return "\n\n".join(
        said for said in (_skill(event, names), _context(event, root, names), search) if said
    )


def main() -> None:
    """Entry point: the advisor cancels no calls, so any failure here is silence and exit 0.

    Everything is suppressed: a broken payload, an unreadable table, an unavailable transcript. A
    hook
    that dropped a file write because of its own error would cost more than everything it advises.
    """
    said = ""
    with contextlib.suppress(Exception):
        said = _advise(json.loads(sys.stdin.read() or "{}"))
    # Printing is under the same suppression as the decision. Outside it a closed stdout gives a
    # traceback and exit 1: the harness will not cancel the call anyway, but a human would get
    # Python
    # garbage from a mechanism whose whole value is not being noise.
    with contextlib.suppress(Exception):
        if said:
            # Write BYTES. Not for POSIX and C -- there Python itself enables UTF-8 mode and a text
            # stdout accepts non-ASCII. For an EIGHT-BIT non-UTF-8 locale (`en_US.ISO8859-1`): a
            # text
            # write fails there, and the advice vanishes without a trace. We set the encoding
            # ourselves.
            sys.stdout.buffer.write(
                json.dumps(
                    {
                        "systemMessage": said,
                        "hookSpecificOutput": {
                            "hookEventName": "PreToolUse",
                            "additionalContext": said,
                        },
                    },
                    ensure_ascii=False,
                ).encode(_UTF8),
            )
        # Close HERE, inside the suppression. What was written sits in the buffer and the write
        # does not
        # touch the descriptor, so a broken pipe fails not here but at interpreter finalization --
        # outside any suppression, with exit 120 and "Exception ignored" on stderr. A closed stream
        # has
        # nothing to flush at finalization.
        sys.stdout.close()
    sys.exit(0)


if __name__ == "__main__":
    main()
