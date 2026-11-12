"""Candidate file links from an instruction document.

Prints one path per line; the calling script checks existence. Selection is deliberately narrow:
a false positive costs trust in the whole check, a missed prose mention costs nothing.
"""

from __future__ import annotations

import re
import sys

# A path must carry a SEPARATOR. A bare file name (`AGENTS.md`, `gate.sh`) is not a link:
# documents name files by bare name all the time, and requiring them to exist at the root
# guarantees false positives, after which the check gets skipped.
# ASCII only: non-Latin prose with a slash is not a path.
TOKEN = re.compile(r"~?\.{0,2}/?[A-Za-z0-9._-]+(?:/[A-Za-z0-9._~-]+)+/?")
# Trim ONLY on the right: the left side can hold only `~`, `.` or a letter -- the regex captures
# nothing else, and a leading dot is significant.
TRIM_RIGHT = ".,;:`)»\"'"

# There is deliberately NO separate filter for patterns (`tests/test_*.sh`, `core/{models,views}`),
# although it suggests itself. It is unreachable: `{` and `*` are not in the character classes, so
# the match stops at them, and the stub (`tests/test_`) is dropped later -- it has neither an
# extension nor a trailing slash. A mutation probe confirmed: removing such a filter failed no
# assertion. A check that cannot fail is not protection but a comment pretending to be code;
# better deleted than left uncovered.


def _candidates(text: str) -> list[str]:
    """Unique candidate paths in order of appearance."""
    seen: list[str] = []
    for match in TOKEN.finditer(text):
        token = match.group(0).rstrip(TRIM_RIGHT)
        if token and token not in seen:
            seen.append(token)
    return seen


def main() -> int:
    """Print candidates. An unreadable document is exit 2, not an empty list."""
    if len(sys.argv) < 2:
        return 2
    try:
        with open(sys.argv[1], encoding="utf-8") as source:
            text = source.read()
    except OSError:
        return 2
    for token in _candidates(text):
        sys.stdout.write(f"{token}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
