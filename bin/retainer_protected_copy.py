"""Copies of protected files in the project tree.

Searched by CONTENT, not by name: the copy is named differently. Size filter first, hash only for
size matches — walking the whole tree for each protected file did not finish in three minutes.

Prints one line per finding: copy and original, tab-separated; the caller assembles the verdict.
Small functions are an engine linter requirement (ceilings on module members and local names).
"""

from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path

SKIP_DIRS = frozenset((".git", "node_modules", ".venv", "__pycache__", "build", "dist"))
MAX_BYTES = 1048576  # rules never exceed a megabyte; hashing more only wastes time
MIN_BYTES = 1  # an empty file matches any empty one, and there is nothing to protect in it


def _digest(path: Path) -> str:
    """SHA-256 of a file; an unreadable file yields an empty string, not a crashed walk."""
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        return ""


def _prune(dirs: list[str], base: str, skip_roots: list[str]) -> None:
    """Prune the walk: service directories and foreign worktrees are not descended into.

    Paths are compared ABSOLUTE and with a trailing separator (the caller script appends it): the
    walk starts from a relative root while git yields absolute paths, so an as-is comparison never
    matched and the skip silently did nothing.
    """
    full = os.path.abspath(base) + os.sep  # noqa: WPS336 — a path, not text assembly
    keep = [name for name in dirs if name not in SKIP_DIRS]
    keep = [name for name in keep if not name.endswith("_cache")]
    if any(root and full.startswith(root) for root in skip_roots):
        keep = []
    dirs.clear()
    dirs.extend(keep)


def _targets(argv: list[str]) -> tuple[Path, dict[Path, Path]]:
    """Walk root and protected files: resolved path → as named in the config."""
    root = Path(argv[0]) if argv else Path(".")
    found: dict[Path, Path] = {}
    for name in argv[1:]:
        target = root / name
        if target.is_file():
            found[target.resolve()] = target
    return root, found


def _add(sized: dict[int, list[Path]], path: Path) -> None:
    """Record a file in the by-size split if it can be a copy of rules at all."""
    try:
        size = path.stat().st_size if path.is_file() else 0
    except OSError:
        return
    if MIN_BYTES <= size <= MAX_BYTES:
        sized.setdefault(size, []).append(path)


def _sized(root: Path, skip_roots: list[str]) -> dict[int, list[Path]]:
    """Tree files bucketed by size: a copy always matches in size, and it comes for free."""
    sized: dict[int, list[Path]] = {}
    for base, dirs, names in os.walk(root):
        _prune(dirs, base, skip_roots)
        for name in names:
            _add(sized, Path(base) / name)
    return sized


def _report(
    root: Path,
    real: Path,
    guarded: dict[Path, Path],
    sized: dict[int, list[Path]],
) -> int:
    """Print copies of one protected file; return their count."""
    want = _digest(real)
    hits = 0
    for other in sized.get(real.stat().st_size, []):
        # A file itself declared protected is not a copy: it has the same protection. A versioned
        # hook
        # and its installed copy go as such a pair when both are protected.
        if not want or other.resolve() in guarded:
            continue
        if _digest(other) == want:
            copy_at = other.relative_to(root)
            orig_at = guarded[real].relative_to(root)
            sys.stdout.write(f"{copy_at}\t{orig_at}\n")
            hits += 1
    return hits


def main() -> int:
    """Print "copy — original" pairs, one per line.

    Exit code: 0 — no copies, 1 — found, 2 — input not parsed.
    """
    root, guarded = _targets(sys.argv[1:])
    if not guarded:
        return 2
    skip = os.environ.get("SKIP_ROOTS", "")
    sized = _sized(root, skip.split(os.pathsep))
    found = sum(_report(root, real, guarded, sized) for real in guarded)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
