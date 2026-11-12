#!/usr/bin/env python3
"""retainer: semantic pass over the showcase export.

The regex scan catches listed formats: AWS keys, GitHub/Slack tokens, private key blocks.
Anything outside them — an internal host, a home path, a person's name, a piece of a working
config — used to pass the publish gate unnoticed. Here a MODEL looks at the remainder: it judges
meaning, not form, and so catches what has no pattern in advance.

    retainer_export_scan.py <export dir> [--allow <file>]

exit 0 — nothing suspicious found · 1 — found (addresses on stdout) · 2 — the check did not run.

**Fail-closed by construction.** Model silence, a missing key, a network failure are code 2, not a
pass: otherwise the check is removed by cutting the network, and publishing an unready tree is
irreversible.

The known-public list lives in a FILE (`--allow`, default `.retainer/export-allow.txt` next to the
export), not in code: it changes more often than code, and editing the script for a host name is an
invitation to edit the script. It works TWICE: as a hint in the question and as a filter on
findings
after the answer (`bin/export_allow.py`) — a hint is a request, not a mechanism, and the model
broke it.

**Determinism.** The question goes with zero temperature, and the answers still differ from run to
run. A fail-closed gate on the publish path that goes red at random stops being read, so one answer
does not decide: a non-clean piece is asked a second time, and its findings block only when both
answers name the same file (`bin/export_answer.py`). A silent ask is repeated once before the pass
gives up.
"""

from __future__ import annotations

import os
import subprocess
import sys
from functools import partial
from pathlib import Path

from export_allow import allow_list
from export_answer import (
    VERDICT_LINE_CLEAN,
    VERDICT_LINE_FINDINGS,
    asked,
    confirmed,
    is_clean,
    rest,
)
from export_pieces import pieces

HERE = Path(__file__).resolve().parent
OK, FOUND, BROKEN = 0, 1, 2
# The blocking texts of the pieces that block, and whether a first answer was dropped whole by the
# known-public list. No `| None` here: a runtime union alias fails to import on Python 3.9.
Outcome = tuple[list[str], bool]
MAX_BYTES = (
    60_000  # this much text goes into one question: beyond it the model reads worse, not better
)
ASK_TIMEOUT = (
    300  # seconds per question: the reasoner thinks long, and the publish gate is infrequent
)
# A string because it goes into argv. Zero narrows the spread of answers, it does not remove it:
# the second ask confirms a finding. Second opinion has the opposite job: its default is untouched.
TEMPERATURE = "0"

QUESTION = (
    "You are checking the tree BEFORE publication to a public repository. "
    "Find lines that must not be published: internal hosts and addresses, home paths of a "
    "specific machine, names and contacts of people, pieces of working configs, traces of "
    "internal infrastructure. Do not count documentation examples, public domains, "
    "names of open projects and test fixtures as findings.\n"
    "Reason if you need to, then end the answer with exactly one last line: "
    f"{VERDICT_LINE_CLEAN} if it can be published, or {VERDICT_LINE_FINDINGS} after the "
    'findings, listed one per line in the format "file:line — what is wrong". '
    "Any doubt goes into the findings list."
)


def _ask(question: str, context: str) -> str | None:
    """Second-opinion answer. None — did not run (no key, network, soft refusal of the module)."""
    # Seam for a hermetic suite (sample: RETAINER_MAKE_PUBLIC): replaces ONLY whoever is asked.
    # Network in tests is not allowed, while answer parsing and fail-closed must be checked.
    asker = os.environ.get("RETAINER_SECOND_OPINION") or str(HERE / "second_opinion.py")
    waited = int(os.environ.get("RETAINER_EXPORT_SCAN_TIMEOUT") or ASK_TIMEOUT)
    # Temperature is set in the environment of the CHILD call: a value from the environment is not
    # inherited, so verdict spread cannot be restored by exporting a variable from outside.
    try:
        done = subprocess.run(
            [sys.executable, asker, question],
            env=dict(os.environ, RETAINER_SO_TEMPERATURE=TEMPERATURE),
            input=context,
            capture_output=True,
            text=True,
            timeout=waited,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if done.returncode != 0:
        return None
    # The second-opinion CLI prints a header "=== SECOND OPINION … ===": that is a frame, not the
    # model's answer. The verdict is looked for in the first substantive line UNDER it — otherwise
    # "CLEAN" would never match the start of the output, and a clean export would read as a
    # finding.
    rows = [row.strip() for row in done.stdout.splitlines()]
    rows = [row for row in rows if row and not row.startswith("===")]
    answer = "\n".join(rows)
    # A soft message of the module ("no key", "timeout") is NOT a verdict: taking it for "clean"
    # means removing the check by a network failure.
    if not answer or answer.startswith("⚠"):
        return None
    return answer


def _target(args: list[str]) -> tuple[Path, list[str]] | None:
    """Arguments → (export dir, known-public). None — the input is unusable.

    The list is loaded HERE, not in the caller: it is needed twice — as a hint in the question and
    as
    a filter on findings — and a second file read would diverge from the first exactly when the
    list is edited.
    """
    if not args:
        sys.stderr.write("usage: retainer_export_scan.py <export dir> [--allow <file>]\n")
        return None
    root = Path(args[0])
    if not root.is_dir():
        sys.stderr.write(f"no export directory: {root}\n")
        return None
    allow_path = root / ".retainer/export-allow.txt"
    if len(args) > 2 and args[1] == "--allow":
        allow_path = Path(args[2])
    return (root, allow_list(allow_path))


def _judged(context: str, allow: list[str]) -> tuple[str, bool] | None:
    """One piece → (the text that blocks it, its first answer was dropped whole by the list).

    None — an ask stayed silent after its retry. Findings on known-public files are dropped from
    each answer before it is judged.
    """
    ask = partial(_ask, QUESTION, context)
    first = asked(ask)
    if first is None:
        return None
    left = rest(first, allow)
    if not left:
        return "", not is_clean(first)
    second = asked(ask)
    if second is None:
        return None
    return confirmed(left, rest(second, allow)), False


def _verdict(outcome: Outcome, count: int) -> int:
    """The outcome of every piece → exit code, printing the verdict on the way."""
    blocking, dropped = outcome
    if blocking:
        sys.stdout.write("".join(f"{text}\n" for text in blocking))
        sys.stdout.write(f"semantic pass — findings in {len(blocking)} of {count} pieces\n")
        return FOUND
    note = " (findings dropped by the known-public list)" if dropped else ""
    sys.stdout.write(f"semantic pass — clean ✓ ({count} pieces){note}\n")
    return OK


def _ask_all(contexts: list[str], allow: list[str]) -> Outcome | None:
    """Every piece judged in order → (blocking texts, a first answer dropped whole by the list).

    None — a piece was silent; the blocking texts gathered so far are printed first.
    """
    kept: list[str] = []
    dropped = False
    for number, context in enumerate(contexts, start=1):
        judged = _judged(context, allow)
        if judged is None:
            sys.stdout.write("".join(f"{text}\n" for text in kept))
            sys.stderr.write(f"semantic pass did not run on piece {number} of {len(contexts)}")
            sys.stderr.write(f" (pieces {number}..{len(contexts)} not asked) — ")
            sys.stderr.write("no key, network or timeout; export NOT ready: ")
            sys.stderr.write('silence is not "clean"\n')
            return None
        if judged[0]:
            kept.append(judged[0])
        dropped = dropped or judged[1]
    return kept, dropped


def main() -> int:
    """CLI: export dir from argv, one question per piece, decision via the exit code."""
    parsed = _target(sys.argv[1:])
    if parsed is None:
        return BROKEN
    root, allow = parsed
    contexts = pieces(root, allow, MAX_BYTES)
    if not contexts:
        sys.stderr.write("the export has no readable files — nothing to check\n")
        return BROKEN
    outcome = _ask_all(contexts, allow)
    if outcome is None:
        return BROKEN
    return _verdict(outcome, len(contexts))


if __name__ == "__main__":
    try:
        sys.exit(main())
    # A crash, an unreadable file or directory included, must not read as "found private content".
    except Exception as crash:
        sys.stderr.write(f"semantic pass crashed ({crash!r}) — export NOT ready\n")
        sys.exit(BROKEN)
