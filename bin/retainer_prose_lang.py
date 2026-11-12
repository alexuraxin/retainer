"""Cyrillic in code prose: docstrings, comments, definition names.

Prints one finding per line: `path:line:kind`. String literals other than docstrings are not
inspected at all -- text a user sees is written in the user's language, and banning it would make
the check harmful. A file that failed to parse is printed with kind `unparsed`: silence about it
would read as clean.

Arguments: `[--added <ranges>] <path>`, repeated; `<ranges>` is `3-7,12`. A path with `--added`
is judged by the lines the change added: a finding is kept when its span meets them. A path
without it is judged whole. A file that did not parse or could not be read is reported whatever
the lines: the check did not run on it.

The `retainer:allow-prose` mark on the finding's line or the line before lifts it -- a per-finding
escape from a false positive, without turning the regulator off.
"""

from __future__ import annotations

import ast
import io
import pathlib
import re
import sys
import tokenize
from collections.abc import Callable
from typing import NamedTuple

ALLOW = "retainer:allow-prose"
# Kit markers: the form is set by the complexity step (retainer-complexity-trace.sh), not the file
# author. Matched from the comment start against a closed word list -- the escape is no wider than
# the marker itself.
PROSE_MARKER = re.compile(r"#\s*(complexity|prototype):")
LONE_CR = re.compile("\r(?!\n)")
# A finder judges one file: `(path, text) -> [(first line, last line, kind)]`.
Finder = Callable[[str, str], "list[tuple[int, int, str]]"]


class _Target(NamedTuple):
    """A path and the lines its change added; None -- the file is judged whole."""

    path: str
    added: set[int] | None

    @classmethod
    def parse(cls, argv: list[str]) -> list[_Target]:
        """Reads `[--added <ranges>] <path>` pairs from the arguments."""
        targets = []
        added: set[int] | None = None
        words = iter(argv)
        for word in words:
            if word == "--added":
                added = cls._ranges(next(words))
                continue
            targets.append(cls(word, added))
            added = None
        return targets

    @classmethod
    def _ranges(cls, spec: str) -> set[int]:
        lines: set[int] = set()
        for part in spec.split(","):
            first, _, last = part.partition("-")
            end = int(last or first)
            lines.update(range(int(first), end + 1))
        return lines


class _ProseScan:
    """Prose findings in one parsed file."""

    def __init__(self, source: str) -> None:
        """Keeps the text and its tree."""
        self._source = source
        self._tree = ast.parse(source)
        # An imported name with no line of its own (Python 3.9) is placed by its import statement:
        # a finding at line 0 would meet no added line.
        self._spans = {
            id(alias): (node.lineno, node.end_lineno or node.lineno)
            for node in ast.walk(self._tree)
            if isinstance(node, (ast.Import, ast.ImportFrom))
            for alias in node.names
            if not getattr(alias, "lineno", 0)
        }

    def findings(self) -> list[tuple[int, int, str]]:
        """Returns `(first line, last line, kind)` for every finding in the file."""
        return sorted(self._comments() | self._docstrings() | self._names())

    def _cyrillic(self, text: str) -> bool:
        return any("\u0400" <= char <= "\u04ff" for char in text)

    def _comments(self) -> set[tuple[int, int, str]]:
        found = set()
        for token in tokenize.generate_tokens(io.StringIO(self._source).readline):
            if token.type != tokenize.COMMENT:
                continue
            text = token.string.strip()
            if PROSE_MARKER.match(text):
                continue
            if self._cyrillic(text):
                found.add((token.start[0], token.start[0], "comment"))
        return found

    def _docstrings(self) -> set[tuple[int, int, str]]:
        holders = (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)
        found = set()
        for node in ast.walk(self._tree):
            if not isinstance(node, holders):
                continue
            text = ast.get_docstring(node, clean=False)
            if text and self._cyrillic(text):
                holder = node.body[0]
                found.add((holder.lineno, holder.end_lineno or holder.lineno, "docstring"))
        return found

    def _names(self) -> set[tuple[int, int, str]]:
        found = set()
        for node in ast.walk(self._tree):
            name = getattr(node, "name", None) or getattr(node, "arg", None)
            if isinstance(name, str) and self._cyrillic(name):
                line = getattr(node, "lineno", 0)
                span = self._spans.get(id(node), (line, line))
                found.add((span[0], span[1], "name"))
        return found


def _read(path: str) -> tuple[str, bool]:
    """Returns the text with universal newlines, and whether a lone CR is in it.

    A lone CR breaks a line for Python but not for git, so git's line numbers would miss the
    finding: such a file is judged whole.
    """
    with pathlib.Path(path).open(encoding="utf-8", newline="") as source_file:
        raw = source_file.read()
    text = raw.replace("\r\n", "\n").replace("\r", "\n")
    return text, bool(LONE_CR.search(raw))


def lifted(source: str, line: int) -> bool:
    """Whether the mark stands on the line or the line before; every finder applies it."""
    nearby = source.splitlines()[max(line - 2, 0) : line]
    return ALLOW in "".join(nearby)


def _lang(path: str, source: str) -> list[tuple[int, int, str]]:
    found = _ProseScan(source).findings()
    return [finding for finding in found if not lifted(source, finding[0])]


def _scan(path: str, added: set[int] | None, finder: Finder) -> list[str]:
    source, whole = _read(path)
    return [
        f"{path}:{first}:{kind}"
        for first, last, kind in finder(path, source)
        if whole or added is None or added.intersection(range(first, last + 1))
    ]


def main(finder: Finder = _lang) -> int:
    """Prints findings; exit 1 -- findings exist, 2 -- a file could not be read.

    `finder` judges each file; the default judges prose for Cyrillic.
    """
    lines: list[str] = []
    broken = False
    for path, added in _Target.parse(sys.argv[1:]):
        try:
            lines.extend(_scan(path, added, finder))
        except (SyntaxError, ValueError, tokenize.TokenError):
            lines.append(f"{path}:0:unparsed")
        except OSError as err:
            # No permission, no file, not text: the check did not run -- that is not clean.
            lines.append(f"{path}:0:unreadable ({err.strerror})")
            broken = True
    for line in lines:
        sys.stdout.write(line)
        sys.stdout.write("\n")
    if broken:
        return 2
    return 1 if lines else 0


if __name__ == "__main__":
    sys.exit(main())
