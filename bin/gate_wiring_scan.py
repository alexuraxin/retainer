"""gate_wiring_scan: locates the "guard wiring check" step in a project's gate.sh.

Single source of truth for two consumers: `adopt-managed-plugin.sh` (REPLACE the step with an
engine
call) and `guard-wiring-check.sh --project` (REPORT whether the project has migrated). If they
diverged, a script would say "move it by hand" while the project appends a home-grown check, and
from
outside "migrated" would be indistinguishable from "home-grown under the right commit message".

The step is recognized by SIGNATURE, not by an anchor comment: the gates of already-distributed
projects predate the template and are signed differently (live form:
`grep -q guard_discipline "$PLUGIN_HOOKS" || { ... }`). The signature is a grep whose target is a
wiring file (`settings.json` / plugin `hooks.json`) AND whose pattern is a guard marker; values of
simple assignments are substituted, otherwise the target hides in a variable. Ambiguity (block
balance does not close, a guard PROBE landed inside the bounds) means refusal: breaking someone
else's gate is worse than not arriving.

A library, not a CLI: the engine's bash scripts that import it provide the outside interface.
"""

from __future__ import annotations

import re
from pathlib import Path

Span = tuple[int, int]
Found = tuple[int, int, str]

ANCHOR = "guard_registration"
ENGINE_CALL = "guard-wiring-check.sh"
DEFAULT_GATE = "scripts/gate.sh"
MAX_SPAN = 60

# Step signature. Each feature alone is noisy (`settings.json` is grepped for other reasons,
# `guard_discipline` sits in the hook's own path); together they give almost no false hits.
_WIRING = re.compile(
    r"grep\b(?=.*(?:settings\.json|hooks\.json))"
    r"(?=.*(?:guard_discipline|enabledPlugins|[\w-]+@[\w-]+))",
)
_ASSIGN = re.compile(r"^\s*([A-Za-z_]\w*)=[\"']?(.*?)[\"']?\s*$")
_GATE_KEY = re.compile(r"^\s*gate_command\s*=")
_COMMENT = re.compile(r"^\s*#")
# Nesting is counted by `if`/`fi` and `{`/`}` -- both live forms of the step are written with them.
# A step inside `case`/`for` will not balance, and we refuse rather than cut blindly.
_OPENS = re.compile(r"^\s*if\b|\{\s*$")
_CLOSES = re.compile(r"^\s*(fi\b|\})")  # `fi\b`, else `files=...` would count as a block close
# The block header is pulled in upward: comments, simple assignments, the enclosing `if`. Anything
# else (blank line, echo, a foreign command) is the step boundary.
_HEADER = re.compile(r"^\s*(#|[A-Za-z_]\w*=|if\b)")
# A guard probe is NOT wiring: it proves the guard BLOCKS. If it landed inside the bounds, the
# bounds drifted and a replacement would delete a check that does not belong here.
_PROBE = re.compile(r"guard_discipline\.py|selfcheck_guard")


def gate_path(project: Path) -> str:
    """Gate path relative to the project root: `gate_command` from .retainer/config.toml."""
    config = project / ".retainer" / "config.toml"
    if not config.is_file():
        return DEFAULT_GATE
    for line in config.read_text(encoding="utf-8", errors="replace").splitlines():
        if not _GATE_KEY.match(line):
            continue
        rhs = line.split("=", 1)[-1]
        for word in rhs.strip(" \"'").split():
            if word.endswith(".sh"):  # "bash app/scripts/gate.sh" -> the script token
                return word
        break
    return DEFAULT_GATE


def _resolve(line: str, known: dict[str, str]) -> str:
    """Line plus the values of variables it mentions: the grep target is often hidden in `$VAR`."""
    text = line.rstrip()  # no newline: the signature lookaheads must not cross onto a new line
    for name, subst in known.items():
        if f"${name}" in line or f"${{{name}}}" in line:
            text = f"{text} {subst}"
    return text


def wiring_hits(lines: list[str]) -> list[int]:
    """0-based line numbers where the gate ITSELF checks guard wiring. Empty: no such step."""
    known: dict[str, str] = {}
    hits = []
    for idx, line in enumerate(lines):
        assign = _ASSIGN.match(line)
        if assign:
            known[assign[1]] = assign[2]
        elif _WIRING.search(_resolve(line, known)):
            hits.append(idx)
    return hits


def _balance(lines: list[str], first: int, last: int) -> int:
    """Where to move the bounds: -1 start higher, +1 end lower, 0 block balanced."""
    depth = [0]
    for line in lines[first : last + 1]:
        if _COMMENT.match(line):
            continue
        opens = bool(_OPENS.search(line))
        closes = bool(_CLOSES.match(line))
        depth.append(depth[-1] + opens - closes)
    if min(depth) < 0:
        return -1
    return 1 if depth[-1] > 0 else 0


def _span_around(lines: list[str], hits: list[int]) -> Span | None:
    """Step bounds around the check lines: pull in the header above and balance the block."""
    start, end = hits[0], hits[-1]
    while start and _HEADER.match(lines[start - 1]):
        start -= 1
    for _ in range(MAX_SPAN):
        move = _balance(lines, start, end)
        if move < 0:
            return None  # the block closes ABOVE the step start -- bounds cannot be reconciled
        if move > 0:  # a tail past EOF cannot balance: exit by the counter
            end += 1
            continue
        body = "".join(lines[start : end + 1])
        if _PROBE.search(body):
            return None
        return (start, end + 1)
    return None


def _anchor_span(lines: list[str]) -> Span | None:
    """Step bounds by the anchor comment: from the header comment to the closing `fi`."""
    start = -1
    for idx, line in enumerate(lines):
        if ANCHOR in line:
            start = idx
            break
    if start < 0:
        return None
    while start and _COMMENT.match(lines[start - 1]):
        start -= 1
    for end, tail in enumerate(lines[start:], start):
        if tail.rstrip() == "fi":
            return (start, end + 1)
    return None


def find_span(lines: list[str], *, anchor_only: bool = False) -> Found | None:
    """Wiring step bounds: (start, end-exclusive, how found), 0-based. None: not found."""
    span = _anchor_span(lines)
    if span:
        return (span[0], span[1], "anchor")
    if anchor_only:
        return None
    hits = wiring_hits(lines)
    span = _span_around(lines, hits) if hits else None
    if span is None:
        return None
    return (span[0], span[1], "signature")
