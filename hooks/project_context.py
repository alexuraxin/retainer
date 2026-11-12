#!/usr/bin/env python3
"""What the project wrote about itself to feed into context -- and to whom.

Failure this exists for
───────────────────────
A project's pitfalls live in its `PROJECT.md` and reach the agent's context at no stage unless the
agent itself decides to open the file: "the file exists but is not read". A requirement "you must
open the file" is weaker than feeding: it needs the agent's decision, costs a whole document and is
executed formally.

There are three readers: `session_context.py` at session start (the hot core), `write_advice.py` on
a file write (the cold layer for the kind of file being edited) and the gate step
`retainer-hot-context.sh`, which calls `audit` via `python3 -c`. Three copies of one parser would
drift apart silently -- a class the engine guards separately (ADR 0005).

Reading the sources lives in the neighboring `project_doc.py`: that seam is real -- READING versus
the DECISION what to feed -- and the split paid for the WPS202 ceiling more honestly than a lint
relaxation.

What is NOT done, and this is named
───────────────────────────────────
Sections are not parsed by meaning: the text is fed as is. A heading changed in the document yields
emptiness here -- silently, because a hint has no right to stop work. The gate step, not the hook,
makes this loss visible: `audit` names every declared section absent from the document.

The fed text is NOT put in an untrusted frame (`untrusted.py`), and this is a decision, not an
oversight. The frame marks FOREIGN origin -- tool output, a second model's answer. Here the source
is the same as `CLAUDE.md` and `AGENTS.md`: the project's own document, which the harness loads
with
no frame at all. Marking it foreign would assert a difference that does not exist. The trust
boundary is the guard's -- the presence of `.retainer/config.toml` in the tree.
"""

from __future__ import annotations

import fnmatch
from pathlib import Path

from project_doc import _CUT, _KEY, _MASK, _SAYS, document, rules, section, table

# Hot core key. The mask field of such rows is empty: they are bound to an event, not to a write
# target.
CORE_KEY = "start"
# Feed ceilings. Without them the mechanism itself becomes the bloated file it was made against,
# and the size is judged only by a gate step the project may switch off.
CORE_LINES = 400
COLD_LINES = 120
# A mask no file name can match: a NUL byte cannot occur in names.
_NEVER = "\x00"


def core(root: Path) -> str:
    """The project hot core: sections declared with the `start` key, under a shared ceiling."""
    text = document(root)[1]
    found: list[str] = []
    seen: set[str] = set()
    for rule in rules(table(root)[0]):
        if rule[_KEY] != CORE_KEY:
            continue
        block = section(text, rule[_SAYS], CORE_LINES)
        # Dedup by the heading line, not by the declared name: two different prefixes point to one
        # section, and it would be fed twice verbatim.
        if block and block[0] not in seen:
            seen.add(block[0])
            found.extend(block)
    if len(found) > CORE_LINES:
        found = [*found[:CORE_LINES], _CUT.format(limit=CORE_LINES)]
    return "\n".join(found)


def advice(root: Path, names: list[str]) -> tuple[str, str, str] | None:
    """The section for the kind of file being edited: (heading, body, document address) or None.

    The address is returned with the body, not fetched by the caller in a second call: the document
    is already open here, and a second call would read it again on every file write.
    """
    found = rules(table(root)[0])
    cold = [rule for rule in found if rule[_KEY] != CORE_KEY]
    # The document is opened ONLY when cold rules exist. The shipped table has none at all, so
    # otherwise the whole document would be read on every write in every project -- for a None.
    if not cold:
        return None
    doc = document(root)
    for rule in cold:
        # An empty mask is replaced by `_NEVER`: a rule with one is broken, and an empty target
        # name (a
        # write without a path) would match an empty mask and feed a section out of nowhere.
        if not fnmatch.filter(names, rule[_MASK] or _NEVER):
            continue
        body = section(doc[1], rule[_SAYS], COLD_LINES)
        if body:
            return rule[_SAYS], "\n".join(body), str(doc[0])
    return None


def audit(root: Path) -> dict[str, object]:
    """Summary for the gate step.

    The size layering and the drift of the declared from the document.

    DATA here, not a verdict: whether to go red or stay silent is the gate step's call. The
    `project_table`
    field is given for that -- on the shipped default a missing section is normal, on a project
    declaration it is not.

    Core lines are counted by what is actually fed (`core`), not by separate arithmetic: a second
    count of the same thing would drift from the first silently.
    """
    doc, text = document(root)
    found = rules(table(root)[0])
    hot = len(core(root).splitlines())
    named = [rule[_SAYS] for rule in found]
    return {
        "document": str(doc or ""),
        "project_table": table(root)[1],
        "core_declared": any(rule[_KEY] == CORE_KEY for rule in found),
        "core": hot,
        "layer": max(len(text.splitlines()) - hot, 0),
        "missing": [title for title in named if not section(text, title, CORE_LINES)],
    }
