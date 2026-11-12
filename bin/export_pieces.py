"""retainer: the exported tree cut into question-sized pieces for the semantic pass.

Every readable file goes into exactly one piece; a file larger than one piece is split by lines,
and its lines carry their real number so a finding can still name it. A single line longer than a
piece goes alone into its own piece. Nothing readable is dropped.
"""

# complexity: keep, step 7 — without it the semantic pass reads one capped question, not the tree

from __future__ import annotations

import os
from pathlib import Path

SKIP_DIRS = frozenset((".git", "__pycache__", ".venv", "node_modules"))
SKIP_SUFFIX = frozenset((".png", ".jpg", ".jpeg", ".gif", ".ico", ".pdf", ".zip", ".gz"))


def _read(root: Path, path: Path) -> str | None:
    """File text, if it takes part in the check at all. None — skip."""
    if not path.is_file() or path.suffix.lower() in SKIP_SUFFIX:
        return None
    if SKIP_DIRS & set(path.relative_to(root).parts):
        return None
    # Another encoding is read with replacement marks, and an unreadable file raises: skipping
    # either would publish what nobody read. Binaries are left to the NUL gate in make-public.sh.
    return path.read_text(encoding="utf-8", errors="replace")


def _walk(root: Path) -> list[Path]:
    """Every path under root, sorted; an unreadable directory raises instead of being skipped."""
    found: list[Path] = []
    for top, _dirs, names in os.walk(root, onerror=_refuse):
        found.extend(Path(top) / name for name in names)
    return sorted(found)


def _refuse(error: OSError) -> None:
    """os.walk's error hook: an unlisted directory is not an empty one."""
    raise error


def _pack(rows: list[str], limit: int) -> list[list[str]]:
    """Consecutive rows grouped so a group stays within limit; an oversize row stands alone."""
    groups: list[list[str]] = []
    size = 0
    for row in rows:
        if groups and size + 1 + len(row) <= limit:
            groups[-1].append(row)
            size += len(row) + 1
        else:
            groups.append([row])
            size = len(row)
    return groups


def _ranged(name: str, group: list[str]) -> str:
    """A block of numbered lines headed by the file and its line range."""
    first = group[0].split("|")[0]
    last = group[-1].split("|")[0]
    return "\n".join([f"=== {name} (lines {first}-{last}) ===", *group])


def _blocks(name: str, text: str, limit: int) -> list[str]:
    """One block for a file that fits, numbered line ranges for one that does not."""
    whole = f"=== {name} ===\n{text}"
    if len(whole) <= limit:
        return [whole]
    # split("\n"), not splitlines(): the numbers must match what an editor shows for file:line.
    lines = enumerate(text.rstrip("\n").split("\n"), start=1)
    numbered = [f"{number}| {line}" for number, line in lines]
    # Half a piece per range: a range plus its header must fit inside a piece next to others.
    return [_ranged(name, group) for group in _pack(numbered, limit // 2)]


def pieces(root: Path, allow: list[str], limit: int) -> list[str]:
    """Question contexts: the known-public line plus blocks packed up to limit, in order.

    An empty tree gives no pieces.
    """
    head = "Known public (not a finding): {}".format(", ".join(allow)) if allow else ""
    room = limit - len(head) - 1
    blocks = []
    for path in _walk(root):
        text = _read(root, path)
        if text is not None:
            blocks.extend(_blocks(str(path.relative_to(root)), text, room))
    return ["\n".join([head, *group]) for group in _pack(blocks, room)]
