"""Checks of a task's readiness for autonomous work — parsing the body and comments.

Lives in a separate file, not as a string inside bash: there are eight checks, each with a regex
and
an explanation, and inside a heredoc they stop being readable or lintable.

Division of duties: here we only FIND problems and print them one per line; the header, verdict and
exit code are assembled by the calling script. So the parser has neither formatting nor output
modes —
and it stays within the engine linter's limits without relaxations.

Input — paths to JSON in the environment: ISSUE (task body), COMMENTS (comments), SIBLINGS (the
repository's open tasks, ALL pages), NUM (number of the one being checked). Output — problem lines;
empty = the form is complete.

The FORM is checked, not the meaning: whether there is a file list, whether a criterion is named,
whether boundaries are named, whether pitfalls were found by reading code, whether an impact
label names who suffers. The meaning ("the criterion is worded so that a failing test can be
written from it") is invisible to the machine and is left to a human.

The main rule of the parser: "not parsed" never equals "fine". A tracker error arrives as valid
JSON,
and without an explicit check of its markers the most broken input would give the most permissive
answer — "the task can be taken" exactly when the check could not be done.
"""

from __future__ import annotations

import json
import os
import re
import sys

CLASH_SHOWN = 3
WORK_LABELS = frozenset(("ready", "in-progress"))
# A file name and the places a task claims in it: `:<line>` per line, `#<section>`, or `*`.
Claims = dict[str, set[str]]
COLLISION_HINT = (
    "a collision is judged by place: name the lines (`file.py:12-30`) or the section"
    + " (`file.md#heading`) in the files block of both tasks, a bare file name claims all of it"
)
# The sufferer axis: a task names whom it hits, or it is not filed at all. Exact names, not a
# prefix — a project's own `impact-<anything>` would otherwise pass for an answer.
IMPACT_LABELS = frozenset(("impact-user", "impact-maker"))
NO_IMPACT = (
    "no impact label: name who suffers — impact-user (whoever uses the product: what they see"
    " while it is not fixed) or impact-maker (whoever makes it: the price now in minutes, runs,"
    " repeats); label it, or close it if neither fits — then it watches only the machinery"
)
Label = dict[str, object]

# A tuple, not a dict: a module constant must be immutable. A block has one pattern, with
# alternatives inside: projects write differently, while the requirement is only that the block
# EXISTS;
# a narrow list would turn the readiness check into a wording check. The exception is the
# acceptance
# block: its shape is read by the machine at the exit (the merge lock), and a narrow pattern here
# is
# not a whim but the condition for entry and exit to answer the same way.
# Template hints are stripped BEFORE parsing. Otherwise a files block with a hint comment between
# the
# heading and the list closes at the heading itself — and a task written to the canon yields no
# files.
# This also removes the question of example paths inside a hint.
COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)
# Fenced code is stripped for the same reason and in the same pass: a task ABOUT the task form
# quotes
# the template whole, and a quoted `## Files:` inside ``` would be taken for a real block.
FENCE = re.compile(r"^[ \t]*```.*?^[ \t]*```", re.DOTALL | re.MULTILINE)
# Start of the files block: the HEADING first, failing that the loose form (`**Files:**` in bold).
HEAD_FILES = re.compile(r"^[ \t]*#{1,6}[ \t]*\**[ \t]*files", re.IGNORECASE | re.MULTILINE)
LOOSE_FILES = re.compile(r"files\s*[:—]", re.IGNORECASE)
# End of the files block — three conditions, any one closes it. The block is the LAST section of
# the
# canon, so "up to the next heading" is not enough: some open tasks have no heading after it at
# all,
# and the rule would degenerate into "to the end of the body" — the footer would leak into the
# block
# as phantom files.
#   1) the next heading;
#   2) a thematic break `---` that sets off the footer;
#   3) a blank line followed by PROSE — the end of the enumeration.
# The third must require a blank line before it (otherwise "## Files" + a path line without a dash
# loses the only path) and must let through a list item of ANY kind: bullet and numbered. The
# template numbers items itself, and a `**Pitfall:**` in the footer is indistinguishable from a
# `* item` bullet if `*` is excluded wholesale.
BLOCK_END = re.compile(
    r"^[ \t]*#{1,6}\s|^---[ \t]*$|\n\n(?![ \t]*(?:[-*+][ \t]|\d+[.)][ \t]))\S",
    re.MULTILINE,
)
# Acceptance heading: the same literal the machine reads at the exit — the match is guarded by a
# test.
# Whitespace as the class `[ \t]`, not `\s`: the pattern is applied to the whole body, and `\s`
# would
# step over a line break, while the exit reads the body line by line and cannot.
AC_HEAD = r"^#{1,6}[ \t]*(?:acceptance[ \t]+criteria|критери[йи][ \t]+при[её]мки)\b"
# A heading is not enough: the exit requires an ITEM under it, before the next heading. A heading
# added above a list that stayed in another section is rejected by the exit.
# The FIRST occurrence of the heading is judged — like the exit, which takes the first and looks no
# further.
# A search over the body slides forward by itself and would take any: a body with an empty
# canonical
# heading above and a filled one below would be answered differently by the two machines. Hence the
# skip from the start of the body with a lookahead.
# Character classes are aligned with the exit on ASCII whitespace: the next heading does NOT allow
# indentation (the exit has `^#{1,6}\s+`), the item bracket is empty, full of spaces or carries a
# mark.
# Unicode whitespace (`\xa0`, `\u2028` and kin) is taken by the exit under `\s` but not by the
# entry;
# it does not occur in tracker bodies, and aligning this edge is deferred as a separate task since
# it
# touches the exit's parser.
# The mark is searched in one case: the pattern is fed a lowercased body (`_form_problems`).
AC_BLOCK = (
    rf"\A(?:(?!{AC_HEAD})[\s\S])*{AC_HEAD}[^\n]*"
    rf"(?:\n(?!#{{1,6}}[ \t]).*)*?\n[ \t]*[-*][ \t]*\[(?:[ \t]*|x)\]"
)

# Each block is searched ONE way — by a pattern over the body. The acceptance block requires a
# heading
# (`^#{1,6}`), while the others make do with a mention: the differing strictness is expressed by
# the
# pattern itself, not by a branch in code that would have to be read separately from the list.
BLOCKS = (
    ("file list", r"files:|files —|## files"),
    ("plan by steps", r"plan:|## plan|work order|steps:"),
    # Acceptance is judged by the HEADING, not a mention: the merge lock rejects checkboxes under
    # any
    # other heading, and a task ABOUT the block's form inevitably mentions the phrase in prose.
    (
        'acceptance under the "## Acceptance Criteria" (or "## Критерии приёмки") heading'
        + " with items under it",
        AC_BLOCK,
    ),
    ('boundaries "what not to do"', r"boundaries|not to do|outside the task|out of scope"),
)
# Address in code: `path/file.ext:NUMBER`. A pitfall found by READING always has an address; a
# presumed one does not. The negative lookbehind cuts off `host:port` in links — otherwise any
# tracker
# link would count as grooming, and that is the most common kind of comment in this same thread.
CODE_REF = re.compile(r"(?<![:/\w])[\w./-]+\.[a-zA-Z]{1,6}:\d+")
# A dependency counts only when the number stands NEXT to a marker word. Otherwise "after all this
# history … #212" in a neighbouring sentence would read as a blocker.
DEP_NEAR = re.compile(
    r"(?:blocked by|blocked|blocks|depends on|waits for|after)[^\n.;!?]{0,30}?(?<![\w/])#(\d+)",
    re.IGNORECASE,
)
# A file named in the files block, with the PLACE in it when the body names one: a line or a
# range after a colon (`pay.py:12`, `pay.py:12-30`) or a section after a hash (`SKILL.md#intake`).
# Two places in one file are two mentions: `pay.py:12, pay.py:40`. A line list (`pay.py:12,40`,
# `pay.py:12;40`, `pay.py:12-30,40`), a number longer than five digits, or a range in another
# spelling (`pay.py:12 - 30`, `pay.py:12..30`, `pay.py:12 to 30`, `pay.py:244 and :361`), an
# open range (`pay.py:12-`, `pay.py:12+`) and a section list (`SKILL.md#a, #b`, `SKILL.md#a,b`)
# are not read as a place: after a place no digit and no `#` may follow on the same line, across
# punctuation and at most one word, no dash or plus may follow a line at once, and no mark of
# punctuation may stand right before a word — so the mention claims the whole
# file, never its first place alone. A line anchor of a web view (`pay.py#L120`) is lines, not a
# section, and claims the whole file too.
# File NAME: the last path segment, necessarily with an extension. The extension cuts off both
# directories (`app/core/services/`) and prose like "yes/no", "form/template" — otherwise they
# would land in the file list and give false collisions. A name without directories — because one
# task writes `process_mirror.html` and a neighbour the full path to the same file, and a
# comparison by spelling would miss that collision. The class `[\w.-]` does not take a slash, so
# the match already starts after the last separator.
PLACE_TOKEN = re.compile(
    r"([\w.-]+\.[a-zA-Z]{1,6})(?![\w/])"
    # The first line is read by a lookahead, so the last-line group holds a lone line as well.
    r"(?:(?::(?=(\d+))(?:\d{1,5}[-–])?(\d{1,5})|(#(?![Ll]\d)[\w-]+(?![\w-])))"
    # Nothing that reads as another place may follow on the line: see the comment above.
    r"(?![-–—−+]|\S\w|[^\w\n]*(?:\w+[^\w\n]*)?[\d#]))?",
)
# A mention with no place claims the whole file.
WHOLE = "*"


def _load(env_key: str) -> object:
    """JSON by a path from the environment.

    A broken or missing input is not a crash but emptiness.
    """
    try:
        with open(os.environ.get(env_key, ""), encoding="utf-8") as source:
            return json.load(source)
    except (OSError, ValueError):
        return None


def _claims(body: str) -> Claims:
    """Files from the files block, reduced to names, each with the places the body names in it.

    Comparison is by name, not spelling: one task writes `process_mirror.html`, a neighbour
    `app/core/templates/core/process_mirror.html`. It is one file, and an exact string comparison
    would miss the collision.

    A place is `:<line>` for every line of a named range and the line after it, or `#<section>`;
    a mention without a place, or with a range that runs backwards, claims the whole file (`*`).
    The line after each range is claimed, so two ranges that touch share it: git refuses to merge
    edits on adjacent lines.

    The block is searched by HEADING, failing that by the first substring occurrence. The function
    also serves the SIBLINGS' bodies (collision search), so losing a block here is a failure in the
    permissive direction.
    """
    text = FENCE.sub("", COMMENT.sub("", body))
    head = HEAD_FILES.search(text) or LOOSE_FILES.search(text)
    if head is None:
        return {}
    # The end is searched from the END of the marker: so the marker itself does not close the
    # block, and in the loose form (`**Files:** path`) the path on the same line stays inside.
    text = text[head.end() :]
    claims: Claims = {}
    for token in PLACE_TOKEN.finditer(BLOCK_END.split(text, maxsplit=1)[0]):
        spots = set(
            map(
                ":{}".format,
                range(
                    int(token[2] or 1),
                    int(token[3] or -1) + 2,
                ),
            ),
        )
        # A forward range claims at least two lines, its own and the next: one comes from a range
        # backwards by one.
        spots = spots if len(spots) > 1 else set()
        spots = spots or {(token[4] or WHOLE).lower()}
        claims.setdefault(token[1], set()).update(spots)
    return claims


def _collisions(num: int, claims: Claims, siblings: list[object]) -> list[str]:
    """Places already claimed by another open task — in progress or labelled ready.

    Two tasks promising one place will collide on the first commit. Caught BEFORE the start, from
    the declared lists, not after the fact by a merge conflict. Two claims on one file overlap when
    they share a place, or when their places are not all of one kind — the whole file against
    anything, lines against a section, which cannot be compared without reading the file. Both
    tests are one comparison: disjoint sets keep the size of their union equal to the sum of their
    sizes, and one kind means one first character, so the smallest and the largest place agree on
    it.
    """
    hits: set[str] = set()
    for task in siblings:
        if not isinstance(task, dict) or task.get("number") == num:
            continue
        labels = task.get("labels") or []
        names = {str(label.get("name")) for label in labels}
        theirs = _claims(
            str(task.get("body") or "") if names & WORK_LABELS else "",
        )
        hits.update(
            "#{}: {}".format(task.get("number"), name)
            for name in claims.keys() & theirs.keys()
            if (
                len(claims[name] | theirs[name]),
                min(claims[name] | theirs[name])[0],
            )
            != (
                len(claims[name]) + len(theirs[name]),
                max(claims[name] | theirs[name])[0],
            )
        )
    return sorted(hits)


def _deps_open(body: str, siblings: list[object]) -> list[int]:
    """Numbers of tasks named as dependencies that are still open."""
    live: set[int] = set()
    for task in siblings:
        if isinstance(task, dict) and task.get("state") == "open":
            live.add(int(task.get("number") or 0))
    named = {int(ref) for ref in DEP_NEAR.findall(body)}
    return sorted(named & live)


def _form_problems(body: str, comments: object, labels: list[Label]) -> list[str]:
    """Complaints about the form: missing body blocks, absent grooming, no sufferer named."""
    low = FENCE.sub("", COMMENT.sub("", body)).lower()
    found = []
    for name, pat in BLOCKS:
        if not re.search(pat, low, re.MULTILINE):
            found.append(f'no block "{name}"')
    texts = []
    if isinstance(comments, list):
        texts = [str(note.get("body", "")) for note in comments]
    if not any(CODE_REF.search(text) for text in texts):
        found.append("no grooming: not a single code address (file:line) in the comments")
    if not IMPACT_LABELS & {str(label.get("name")) for label in labels}:
        found.append(NO_IMPACT)
    return found


def _link_problems(body: str, num: int, siblings: object) -> list[str]:
    """Complaints about links.

    An unreadable sibling list is a problem, not a silent "all clean".
    """
    if not isinstance(siblings, list):
        return ["repository task list not received — dependencies and collisions NOT checked"]
    found = [f"dependency not closed: #{dep}" for dep in _deps_open(body, siblings)]
    claims = _claims(body)
    if not claims:
        found.append("the files block has no file — collisions with siblings cannot be checked")
        return found
    clash = _collisions(num, claims, siblings)
    for place in clash[:CLASH_SHOWN]:
        found.append(f"a claim on one file collides with sibling task {place}")
    rest = len(clash) - CLASH_SHOWN
    if rest > 0:
        found.append(f"and more collisions: {rest}")
    if clash:
        found.append(COLLISION_HINT)
    return found


def main() -> int:
    """Problems one per line; 0 — the form is complete, 1 — it is not, 2 — no data."""
    issue = _load("ISSUE")
    if not isinstance(issue, dict) or "state" not in issue:
        sys.stdout.write("tracker did not return the task — readiness cannot be checked\n")
        return 2
    if issue.get("state") != "open":
        sys.stdout.write(f"task is not open (state: {issue.get('state')}) — nothing to take\n")
        return 1
    body = str(issue.get("body") or "")
    num = int(os.environ.get("NUM", "0"))
    problems = _form_problems(body, _load("COMMENTS"), issue.get("labels") or [])
    problems.extend(_link_problems(body, num, _load("SIBLINGS")))
    for problem in problems:
        sys.stdout.write(f"{problem}\n")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
