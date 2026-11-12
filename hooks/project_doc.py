#!/usr/bin/env python3
"""What a project wrote about itself.

The declaration table, the project document, section extraction.

Split from `project_context.py` by measurement, not by taste: that file hit the WPS202 ceiling
(seven
module members), and the choice was between loosening lint and splitting. Splitting is more honest
-- the seam
here is real: READING sources versus DECIDING what of the read to serve.

The heading is matched by PREFIX
────────────────────────────────
An exact match will not do, and this is measured: in the engine template the section is called
`## Known pitfalls / mines (do not rediscover, do not "fix" out of ignorance)`, in a live project
--
`## Known pitfalls`. The table would have to declare the tail character for character. The FIRST
match from the top is taken; a second heading with the same prefix is ignored.

A code fence is not a heading
─────────────────────────────
The "pitfalls" section accumulates code examples by nature. A line `# do not write this` inside a
fence would
cut the section in the middle, and a `## Known pitfalls` SHOWN as a sample would stand in for the
real one.
Boundaries are therefore looked for in a copy where the hashes inside fences are replaced with
spaces. The closer must
match the opener by character and be no shorter: otherwise a nested fence closes the outer one, and
the
substitution returns in a form one character further from the checked one.

Source boundaries
─────────────────
The reader's entry point (`CLAUDE.md`, `AGENTS.md`) cannot be a project document: it is loaded
whole, and serving from it would put the same lines into context twice. The path leads only INTO
the
tree -- an absolute one, one containing `..` and one leading out of the tree by a symlink are
rejected, the
resolved path is compared.

The key is read by name, without parsing TOML sections: `[docs] project_context` is called a
section in the
documentation, but here any occurrence of the key name matches. There is no second key of that name
in the engine
configs, and parsing sections would cost that very second parser of the format.
"""

from __future__ import annotations

import contextlib
import re
from pathlib import Path

# A table row: key, one target mask, value. The field semantics are ONE for both engine tables --
# in `write_advice.rules` it is (kind, mask, skill), in `context.rules` -- (when, mask, heading).
Rule = tuple[str, str, str]

_UTF8 = "utf-8"
_FIELDS = 3
# Field indices are named: `rule[0]` in several places reads worse than `rule[_KEY]`, and
# unpacking into a tuple on every iteration would cost three locals against a ceiling of five.
_KEY = 0
_MASK = 1
_SAYS = 2

_HERE = Path(__file__).resolve().parent
# The SHIPPED DEFAULT: travels with the plugin next to the work-kinds table. Needed so that the
# mechanism
# works on a project that does not know about it yet -- otherwise it would be silent for everyone
# who did not add
# the declaration, i.e. for everyone at once.
SHIPPED = _HERE / "context.rules"
# The PROJECT's declaration. If present, it replaces the shipped one wholly. The hot core must not
# be lost
# silently in that case: an empty `start` in the project table names a gate step.
PROJECT_RULES = Path(".retainer", "context.rules")
MARKER = Path(".retainer", "config.toml")
_CUT = "  … truncated at the ceiling of {limit} lines"

# Conventional names of the project document -- the same list the gate step walks.
_DOCS = (Path(".retainer", "PROJECT.md"), Path(".foreman", "PROJECT.md"))
_ENTRY = frozenset(("CLAUDE.md", "AGENTS.md"))
# The key value in three forms: in double quotes, in single quotes, bare up to a trailing comment.
# The form matters: reading via `sed | tr -d '" '` does NOT strip a trailing comment, and the
# declared
# document turns into a name that does not exist.
_DOC_KEY = re.compile(
    r"^[ \t]*project_context[ \t]*=[ \t]*(?:\"([^\"]*)\"|'([^']*)'|([^#\n]*))",
    re.MULTILINE,
)
# The closer is matched against the OPENER: the same character and no shorter. Independent
# alternatives
# closed a four-backtick fence with a nested triple, and a backtick fence with a tilde one, the
# masking
# stopped before the end of the block, and a heading from the sample stayed visible.
#
# After the closer only whitespace is allowed -- as in CommonMark. A typo like "``` tail" does not
# close the fence, and the section behind it vanishes SILENTLY. The trade is deliberate: not
# closing a fence
# means not serving a section, while closing it early meant serving a FOREIGN one -- a forgery from
# a sample.
# The first is seen by an empty core, the second is seen by nothing.
_FENCED = re.compile(
    r"^[ \t]*(?P<fence>(?P<mark>[`~])(?P=mark){2,})[^\n]*(?:\n.*?)??"
    r"(?:^[ \t]*(?P=fence)(?P=mark)*[ \t]*$|\Z)",
    re.MULTILINE | re.DOTALL,
)


def rules(path: Path) -> list[Rule]:
    """A line-by-line table by PATH: lines `key | masks separated by commas | value`.

    The path is an argument, not derived inside: this same function reads the work-kinds table of
    the
    advisor, which has its own home and its own substitution seam via the environment.

    The format is line-based, not TOML: the tree already has two minimal parses of one format, and
    the engine
    separately guards the class "diverging parses of one truth".
    """
    text = ""
    # `errors="replace"`, not a bare read: a non-UTF-8 file raises `UnicodeDecodeError`, which does
    # not fall under
    # `OSError` and would switch the mechanism off wholly -- without a trace.
    with contextlib.suppress(OSError):
        text = path.read_text(encoding=_UTF8, errors="replace")
    found: list[Rule] = []
    for line in text.splitlines():
        parts = [chunk.strip() for chunk in line.split("|")]
        if line.lstrip().startswith("#") or len(parts) != _FIELDS:
            continue
        for mask in parts[_MASK].split(","):
            found.append((parts[_KEY], mask.strip(), parts[_SAYS]))
    return found


def table(root: Path) -> tuple[Path, bool]:
    """Which context table is in force: (path, whether it is declared by the PROJECT).

    Replacement, not merge: a project that added a line must see exactly what it wrote.
    Loss of the hot core is caught by the gate step's summary.
    """
    own = root / PROJECT_RULES
    if own.is_file():
        return own, True
    return SHIPPED, False


def declared(root: Path) -> str:
    """The document name declared by the `project_context` key; empty -- not declared."""
    text = ""
    with contextlib.suppress(OSError):
        text = (root / MARKER).read_text(encoding=_UTF8, errors="replace")
    found = _DOC_KEY.search(text)
    if found is None:
        return ""
    return next(filter(None, found.groups()), "").strip()


def document(root: Path) -> tuple[Path | None, str]:
    """The project document and its text; (None, "") -- there is no document.

    The path and the text are returned TOGETHER, because nobody asks for them apart: the reader
    needs
    the text, the report -- the address. With two calls the document would be opened twice per
    request.
    """
    # An empty declaration gives `Path(".")` -- a directory, not a file, so it is filtered out by
    # the same condition
    # as an absolute path, an exit via `..` and the reader's entry point.
    for name in (Path(declared(root) or "."), *_DOCS):
        if name.is_absolute() or ".." in name.parts or name.name in _ENTRY:
            continue
        # The RESOLVED path is compared: `is_file()` dereferences a link, and without this a
        # committed
        # symlink would feed a file from anywhere on the machine into context. BOTH sides are
        # resolved --
        # the project directory may itself lie under a link (`/tmp` on macOS).
        doc = (root / name).resolve()
        if doc.is_file() and root.resolve() in doc.parents:
            with contextlib.suppress(OSError):
                return doc, doc.read_text(encoding=_UTF8, errors="replace")
    return None, ""


def blank(block: re.Match[str]) -> str:
    """The same block with hash-spaces: the length is kept, headings inside vanish."""
    return block.group(0).replace("#", " ")


def bounds(text: str, title: str) -> tuple[int, int] | None:
    """Section bounds in the SOURCE text: (start, end) or None -- there is no section."""
    if not title:
        return None
    masked = _FENCED.sub(blank, text)
    head = re.search(rf"^(#{{1,6}})[ \t]+{re.escape(title)}", masked, re.MULTILINE)
    if head is None:
        return None
    # Cutting starts AFTER the heading: the end pattern would match it itself, and the section
    # would come out empty.
    stop = rf"^#{{1,{len(head.group(1))}}}[ \t]"
    tail = masked[head.end() :]
    cut = re.split(stop, tail, maxsplit=1, flags=re.MULTILINE)
    return head.start(), head.end() + len(cut[0])


def section(text: str, title: str, limit: int) -> list[str]:
    """Section lines under the ceiling; empty -- there is no section.

    An excess over the ceiling is cut with a VISIBLE line: a silent cut is indistinguishable from a
    short
    section, and the mechanism would serve half a document without saying so.
    """
    edge = bounds(text, title)
    if edge is None:
        return []
    body = text[edge[0] : edge[1]].splitlines()
    if len(body) > limit:
        return [*body[:limit], _CUT.format(limit=limit)]
    return body
