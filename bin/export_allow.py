"""export_allow: known-public paths, both as a model hint and as a FILTER on its findings.

The list used to play one role: it went into the prompt ("do not count as a finding") and relied
on the model obeying. It did not. Measured: `.gitea/workflows/gate.yml` was named in the list and
still came back as a finding -- a hint is a request, not a mechanism. On one tree, four runs gave
three "clean" and one refusal.

Hence the second role: after the answer, findings on files from the list are dropped by string
comparison. Half of the nondeterminism is closed here, however stable the model is.

FILTER BOUNDARY. A finding is dropped BY FILE, not by text match. A line pattern (`self-hosted`,
`ci@retainer`) is not a filter: a real secret sharing a line with an allowed word must stay a
finding. A file in the list is the owner's statement "this whole file is public by design", which
is checkable by eye; "a line where the word occurs" is not.

A separate module, not functions in `retainer_export_scan.py`: that one stays under the WPS202
ceiling of seven members, and the lint must not be loosened for reuse.
"""

from __future__ import annotations

from pathlib import Path

_COMMENT = "#"
# A sample counts as a PATH only if it carries a directory separator. A bare name (`self-hosted`)
# is not a path: otherwise an allowed word would suppress a finding in a file that merely shares
# it.
_SEP = "/"
# Junk the model decorates a finding line with: list bullet, path quote.
_TRIM = "-*• `"


def allow_list(path: Path) -> list[str]:
    """Known-public samples, one per line. Comments and blank lines are ignored."""
    try:
        rows = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    kept = []
    for row in rows:
        line = row.strip()
        if line and not line.startswith(_COMMENT):
            kept.append(line)
    return kept


def _target(row: str) -> str:
    """File a finding refers to. Empty: the line could not be parsed."""
    head = row.split(":", 1)[0]
    return head.strip().strip(_TRIM).strip()


def _matches(target: str, known: str) -> bool:
    """Whether ONE sample covers the finding's file: the file itself or a directory containing it.

    A separate function out of necessity: inline with `any()` the line fails the complexity
    threshold, and unrolling `any()` into a loop fails lint. The threshold exists precisely so
    such expressions get a name.
    """
    return target == known or target.startswith(f"{known}{_SEP}")


def _covered(target: str, paths: list[str]) -> bool:
    """Whether the finding's file is covered by the known-public list."""
    if not target:
        return False
    return any(_matches(target, known) for known in paths)


def drop_allowed(answer: str, allow: list[str]) -> str:
    """Model answer without findings on files from the list. Empty: nothing is left.

    An unparsed line STAYS: a filter that swallows what it did not understand is a way to switch
    the gate off with a malformed answer.
    """
    paths = [sample for sample in allow if _SEP in sample]
    kept = []
    for row in answer.splitlines():
        if not row.strip():
            continue
        if not _covered(_target(row), paths):
            kept.append(row)
    return "\n".join(kept).strip()
