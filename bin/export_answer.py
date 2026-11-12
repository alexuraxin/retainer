"""export_answer: reading ONE model answer of the semantic pass, and confirming its findings.

An answer is clean when it is the single word CLEAN, or ends with the verdict line VERDICT: CLEAN
and no finding row contradicts it. A non-clean answer is filtered by the known-public list; what is
left blocks a piece only when a second, independent ask of the same piece names the same file. The
model's answers differ from run to run even at zero temperature, so a row seen once is a doubt, not
a finding; both answers of an unconfirmed piece are still printed to stderr for a person to read.

Fail-closed where the form is unreadable: when the second ask is not clean either, an answer with
text left but no finding row blocks, whatever rows the other carries. Paths are compared as
written, less a leading `./`.

A separate module, not functions in `retainer_export_scan.py`: that one stays under the WPS202
ceiling of seven members.
"""

# complexity: keep, step 7 — without it one unconfirmed model row refuses every publish

from __future__ import annotations

import re
import sys
from collections.abc import Callable

from export_allow import drop_allowed

VERDICT_CLEAN = "CLEAN"
VERDICT_LINE_CLEAN = "VERDICT: CLEAN"
VERDICT_LINE_FINDINGS = "VERDICT: FINDINGS"
# A finding ROW contradicts a clean verdict: a line that starts — after list bullets, numbers,
# quote, bold and code marks — with `path:line` (or `path:80-81`), then a dash or a colon and text,
# the form the question asks findings in. A line number or a `host:port` in prose is not a row.
FINDING_SHAPE = re.compile(
    r"^(?:[ >*+•`-]|\d+[.)] )*"  # leading marks and list numbers (rows arrive stripped)
    r"(?P<path>[\w./~-]+):\d+(?:-\d+)?[*`]*"  # path:line, a hyphen range, closing marks
    r"(?:[ \t]*[—–]|[ \t]+-[ \t]|:[ \t])",  # a separator; after — or – the text may wrap
    re.MULTILINE,
)
UNCONFIRMED = "semantic pass — unconfirmed by a second ask, not blocking:"


def split_verdict(answer: str) -> tuple[str, str]:
    """(verdict, what the known-public filter reads). The verdict is the LAST line, whole.

    A line that only starts like a verdict is not one, and nothing but that line is removed.
    A FINDINGS verdict with nothing above it is not "nothing found": the answer stays whole.
    """
    rows = answer.splitlines() or [""]
    last = rows[-1].strip().strip("*")
    last = last.strip().removesuffix(".").upper()
    if last not in {VERDICT_LINE_CLEAN, VERDICT_LINE_FINDINGS}:
        return "", answer
    body = "\n".join(rows[:-1])
    if last == VERDICT_LINE_FINDINGS and not body.strip():
        return last, answer
    return last, body


def is_clean(answer: str) -> bool:
    """The one clean test: the single word CLEAN, or a clean verdict no finding contradicts."""
    if answer.strip().rstrip(".!").upper() == VERDICT_CLEAN:
        return True
    verdict, _body = split_verdict(answer)
    if verdict != VERDICT_LINE_CLEAN:
        return False
    return FINDING_SHAPE.search(answer) is None


def rest(answer: str, allow: list[str]) -> str:
    """What of an answer can block: empty for a clean answer, else the text the list leaves."""
    if is_clean(answer):
        return ""
    return drop_allowed(split_verdict(answer)[1], allow)


def _files(text: str) -> set[str]:
    """The files the finding rows of a text name; a leading `./` does not make another file."""
    return {row.group("path").removeprefix("./") for row in FINDING_SHAPE.finditer(text)}


def confirmed(first: str, second: str) -> str:
    """The text that blocks a piece, from the rests of two asks. Empty: the piece is clean.

    Blocks when the second ask left text and the two name a shared file, or either has no finding
    row. Whatever does not block is written to stderr: an unconfirmed doubt is shown, not dropped.
    """
    texts = "\n".join(dict.fromkeys((first, second)))
    one = _files(first)
    two = _files(second)
    if second and (not one or not two or one & two):
        return texts
    sys.stderr.write(f"{UNCONFIRMED}\n{texts}\n")
    return ""


def asked(ask: Callable[[], str | None]) -> str | None:
    """One ask of a piece; a silent ask (None) is repeated once."""
    answer = ask()
    if answer is None:
        return ask()
    return answer
