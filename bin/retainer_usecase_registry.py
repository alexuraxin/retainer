"""Project use-case registry, built from code.

Prints one line per use case: `dir|name|first docstring line`. A dir that matches a path
pattern and holds no use case is printed as `dir||(empty)` — an empty
area is worth more than silence: it shows that this section's behavior is described nowhere.

A use case is a top-level class or function with a public name. Its first docstring line is the
description: a registry built from code is only as honest as the code is about its own name.
"""

from __future__ import annotations

import ast
import pathlib
import sys

Entry = tuple[str, str]
# A module-level type alias is evaluated at runtime, and the system interpreter here is 3.9:
# it cannot build a union via the vertical bar. In signatures the future import defers
# annotations, so the same notation is fine there.


def _first_line(
    node: ast.Module | ast.ClassDef | ast.FunctionDef | ast.AsyncFunctionDef,
) -> str:
    text = (ast.get_docstring(node, clean=True) or "").strip()
    return text.splitlines()[0] if text else ""


def _scan_file(path: pathlib.Path) -> list[Entry]:
    tree = ast.parse(path.read_text(encoding="utf-8"))
    holders = (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)
    return [
        (node.name, _first_line(node))
        for node in tree.body
        if isinstance(node, holders) and not node.name.startswith("_")
    ]


class ScanFailedError(Exception):
    """A file could not be read or parsed — a failure, not an empty use case."""


def _safe_scan(path: pathlib.Path) -> list[Entry]:
    try:
        return _scan_file(path)
    except (SyntaxError, ValueError, OSError) as err:
        raise ScanFailedError(f"{path}: {err}") from err


def _grouped(paths: list[pathlib.Path]) -> dict[str, list[Entry]]:
    by_dir: dict[str, list[Entry]] = {}
    for path in paths:
        key = str(path.parent)
        by_dir.setdefault(key, [])
        by_dir[key].extend(_safe_scan(path))
    return by_dir


def _report(paths: list[pathlib.Path]) -> list[str]:
    lines = []
    for key, entries in sorted(_grouped(paths).items()):
        if not entries:
            lines.append(f"{key}||(empty)")
        for name, text in sorted(entries):
            lines.append(f"{key}|{name}|{text}")
    return lines


def main() -> int:
    """Print the registry; 3 — no files passed, 2 — a file could not be read."""
    paths = [pathlib.Path(arg) for arg in sys.argv[1:]]
    if not paths:
        return 3
    try:
        lines = _report(paths)
    except ScanFailedError as err:
        sys.stdout.write(f"FAILED|{err}\n")
        return 2
    for line in lines:
        sys.stdout.write(line)
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
