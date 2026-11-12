"""Check of term references against the project glossary.

Input: the glossary path as the first argument, `path|term` lines on stdin. Output: `path|term`
lines
for references that do not resolve, and exit code 1 if there are any.

Parsing and comparison live here, not in the wrapper, for two reasons. Case is folded by unicode
(`casefold`): the "case-insensitive" flag of a line search depends on the locale and does not fold
non-ASCII text in a byte locale. The definition block indent is the minimum inside the directive:
a glossary aligns definitions at any number of spaces.
"""

from __future__ import annotations

import pathlib
import re
import sys


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip())


HEADING = re.compile(r"^##+\s+(?P<name>.+?)\s*$")
DIRECTIVE = re.compile(r"^\s*\.\.\s+glossary::")


class _Glossary:
    """Term names declared by the project glossary."""

    def __init__(self, path: pathlib.Path) -> None:
        """Read the glossary and remember its lines."""
        self._lines = path.read_text(encoding="utf-8").splitlines()

    def defined(self) -> set[str]:
        """Term names in folded case."""
        names = self._headings() | self._directive_terms()
        return {name.casefold() for name in names}

    def _headings(self) -> set[str]:
        found = set()
        for line in self._lines:
            matched = HEADING.match(line)
            if matched:
                found.add(matched.group("name"))
        return found

    def _directive_terms(self) -> set[str]:
        found: set[str] = set()
        for start in self._directive_starts():
            found |= self._terms_after(start)
        return found

    def _directive_starts(self) -> list[int]:
        return [num for num, line in enumerate(self._lines) if DIRECTIVE.match(line)]

    def _terms_after(self, start: int) -> set[str]:
        body = []
        for line in self._lines[start + 1 :]:
            if line.strip() and not line.startswith((" ", "\t")):
                break
            if line.strip():
                body.append(line)
        return self._base_indented(body)

    def _base_indented(self, body: list[str]) -> set[str]:
        if not body:
            return set()
        base = min(_indent(line) for line in body)
        same = [line.strip() for line in body if _indent(line) == base]
        return {name for name in same if not name.endswith((".", ":"))}


def _unresolved(rows: list[str], defined: set[str]) -> list[str]:
    missing = []
    for raw in rows:
        path, _, term = raw.partition("|")
        if term and term.casefold() not in defined:
            missing.append(f"{path}|{term}")
    return missing


def main() -> int:
    """Print unresolved references.

    Code 1 means there are some, 2 means the glossary was not read.
    """
    if len(sys.argv) < 2:
        sys.stdout.write("usage: retainer_glossary_terms.py <glossary>\n")
        return 2
    try:
        defined = _Glossary(pathlib.Path(sys.argv[1])).defined()
    except OSError as err:
        sys.stdout.write(f"REFUSED|{err}\n")
        return 2
    missing = _unresolved(sys.stdin.read().splitlines(), defined)
    for line in missing:
        sys.stdout.write(line)
        sys.stdout.write("\n")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
