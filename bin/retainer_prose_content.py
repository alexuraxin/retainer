"""Narrative in code prose: comments and docstrings that retell history instead of behaviour.

Prints one finding per line: `path:line:marker`. Markers form a closed list: `issue` -- a task
or pull request number; `history` -- a phrase naming a previous state of the code. A date or a
number is not a marker: a measured fact is how a threshold justifies its value in place.

Quoted spans are examples, not statements, and a passive "is used to" states what a thing
serves for: neither is judged. "A key used to sign requests" is judged: the closed list cannot
tell it from history, and "a key that signs requests" says the same. Kit markers (`# prototype:`,
`# complexity:`) carry a task number by design and are skipped. A `.sh` file is judged by its
full-line comments; any other file is parsed as Python.

Arguments, exit codes and the `retainer:allow-prose` mark on the finding's line or the line
before are those of `retainer_prose_lang.py`.
"""

# complexity: keep, step 2 — without it nothing reads what a comment says

from __future__ import annotations

import ast
import io
import re
import sys
import tokenize
from collections.abc import Iterator

from retainer_prose_lang import PROSE_MARKER, lifted, main

MARKERS = (
    ("issue", re.compile(r"#\d{2,5}\b")),
    (
        "history",
        re.compile(
            r"\bused to\b"
            r"|\bpreviously\b|\bbefore the fix\b|\bthe previous revision\b"
            r"|\bthe old (?:code|version|check|form)\b|\ba live measurement\b"
            r"|\buntil (?:this|the) (?:fix|change)\b"
            r"|(?:^\s*|[.!?:;—]\s*)(?-i:Раньше)(?![а-яё])|(?<![а-яё])до правки(?![а-яё])",
            re.IGNORECASE,
        ),
    ),
)
# Not judged: quoted spans are examples, a passive "is used to" states what a thing serves for.
EXEMPT = re.compile(
    r"`[^`\n]*`|\"[^\"\n]*\"|«[^»\n]*»"
    r"|\b(?:is|are|be|been)\s+(?:(?:also|\w+ly)\s+)?used to\b",
    re.IGNORECASE,
)
SHELL_COMMENT = re.compile(r"[ \t]*#")
HOLDERS = (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)


def _marker(text: str) -> str | None:
    """Returns the first marker the text carries outside its exempt spans."""
    statement = EXEMPT.sub("", text)
    for name, pattern in MARKERS:
        if pattern.search(statement):
            return name
    return None


class _ContentScan:
    """Narrative findings in one file."""

    def __init__(self, path: str, source: str) -> None:
        """Keeps the text; a `.sh` file is not parsed."""
        self._lines = source.splitlines()
        self._shell = path.endswith(".sh")
        self._source = source

    def findings(self) -> list[tuple[int, int, str]]:
        """Returns `(line, line, marker)` for every narrative line, the mark not applied."""
        found = set()
        for line, text in self._prose():
            name = _marker(text)
            if name:
                found.add((line, line, name))
        return sorted(found)

    def _prose(self) -> Iterator[tuple[int, str]]:
        if self._shell:
            for number, text in enumerate(self._lines, start=1):
                if SHELL_COMMENT.match(text):
                    yield number, text.lstrip(" \t#")
            return
        yield from self._comments()
        yield from self._docstrings()

    def _comments(self) -> Iterator[tuple[int, str]]:
        for token in tokenize.generate_tokens(io.StringIO(self._source).readline):
            text = token.string.strip()
            if token.type == tokenize.COMMENT and not PROSE_MARKER.match(text):
                yield token.start[0], text.lstrip("#")

    def _docstrings(self) -> Iterator[tuple[int, str]]:
        for node in ast.walk(ast.parse(self._source)):
            if not isinstance(node, HOLDERS):
                continue
            text = ast.get_docstring(node, clean=False)
            for offset, line in enumerate((text or "").splitlines()):
                yield node.body[0].lineno + offset, line


def _find(path: str, source: str) -> list[tuple[int, int, str]]:
    found = _ContentScan(path, source).findings()
    return [finding for finding in found if not lifted(source, finding[0])]


if __name__ == "__main__":
    sys.exit(main(_find))
