#!/usr/bin/env python3
"""retainer: gate on a declared "done" — the Stop event.

The commit hooks judge a commit, and CI judges a pull request. The moment the agent says "done"
and ends the turn is judged here: in a marathon "done" is said many times per session, and commits
happen less often.

NOT the whole suite is run: the runner is called on the tests matched to the session's OWN
working-tree edits — the paths its transcript shows it wrote, and the files of its own commits —
and only on a turn whose final message claims done. Files another session left in the tree are
not judged. A project's lint, declared as `lint_command`, is a second runner: it runs as declared
on such a turn with an own code edit, inside the same time ceiling as the tests.

There is deliberately NO bypass via an environment variable or a marker file: the agent sets either
for itself, and the protection becomes decoration. Only the owner's key lifts it — the same one as
the guard's.

Anti-loop is a refusal BUDGET, not a one-shot surrender on `stop_hook_active`: surrender lifts the
gate exactly when the agent says "done" a second time on red. When the budget is spent the gate
yields so the session does not jam for good.

The second judge on the same boundary reads the turn's CONTENT: with `ask_owner = off` the work may
not be handed back to the owner, and that ban had no executor — a regulator without a machine is a
rule in prose. A turn ending in a question or a wait form, with code edits in the tree, is refused
unless the message declares its ground as `handoff: <code> — <what is blocked>`. It keeps the
gate's own exemptions (no repository, the owner's key) and its own refusal budget, and it runs
BEFORE the suite: a refusal must not pay for a full run.
"""

from __future__ import annotations

import contextlib
import functools
import json
import os
import re
import shlex
import subprocess
import sys
import types
from pathlib import Path

# What to check on a turn: the repository, the refusal-budget slot, the test list, code edits and
# the reason no tests were found (emptiness comes in kinds, and each is fixed differently).
Names = list[str]
Scope = tuple[Path, str, Names, Names, Names]
Event = dict[str, object]

HOME = Path(os.environ.get("HOME") or Path.home())
STATE = HOME / ".cache" / "retainer" / "guard_state"
# Hoisted because the new readers pushed both literals over the over-use limit, and one home
# for "how this hook reads git" is worth more than the three spellings it replaces.
GIT = ("git", "-C")
UNLOCK = Path(".retainer") / "unlock"
BUDGET_MAX = 3
# Strictly below the hook's own timeout: else it is killed before it can speak. The lint and the
# tests share it: the lint runs first, the tests get what is left.
SUITE_TIMEOUT = 540
# How long a run waits for a host-wide suite slot before it gives up and runs nothing: a third of
# the time it has, so a queue behind CI jobs ends inside the ceiling, not as a false red on it.
SLOT_SHARE = 3
# The engine runner's exit when the slot wait passed with every slot busy and nothing ran.
SLOTS_BUSY_CODE = 3
# Parts of one message (reasons, the route, the red runs of a refusal) are set apart by a blank
# line.
PARAGRAPH = "\n\n"
TAIL_BYTES = (
    4000  # output tail in the refusal reason: the agent reads no more, and it eats context
)
NOT_RUN = None  # the runner is declared but did not start: neither "green" nor a tool code
HAVE_TOMLLIB = sys.version_info >= (3, 11)
if HAVE_TOMLLIB:
    import tomllib
CODE_SUFFIX = frozenset((".py", ".sh", ".json", ".toml", ".yml", ".yaml"))
# Test path form: `{stem}` is the changed module's name. The default is the engine's form; a
# project sets its own via the `test_layout` key in ITS `.retainer/config.toml` — one string, or a
# one-line array of them for a project with several code roots. Without it the hook looks for
# engine-form tests and in a project in another language finds nothing.
LAYOUT_DEFAULT = "tests/test_{stem}.sh"
# One string of the array form, in either quoting, and the whole one-line array around them. The
# array is read by this one reader on every interpreter: the line-by-line parse cannot assemble a
# multi-line array, and a second reader would mean understanding one file two ways.
_QUOTED = r"\"(?:[^\"\\]|\\.)*\"|'[^']*'"
ITEM_RE = re.compile(_QUOTED)
ARRAY_RE = re.compile(rf"^\[\s*((?:(?:{_QUOTED})\s*,\s*)*(?:{_QUOTED})?)\s*\]\s*(?:#.*)?$")
# A value written as an explicitly empty string: the setting is declared off, not broken.
EMPTY_RE = re.compile(r"^(?:\"\"|'')\s*(?:#.*)?$")
# MIRROR — the second matching method, for projects whose tests are laid out as a tree by layers.
# The `{stem}` substitution cannot express such a layout at all: a test dir carries the app and
# layer names, which are not derivable from the module name. Measured on a live Django project:
# substitution by name
# matches 7% of modules, the mirror 87%. The gap is not about the template: tests there are named
# by
# SCENARIO ("test_hh_callbacks_action"), not by module, and most modules have no same-named test.
#
# Rule: a module path maps into the test tree by prefix on each segment; if there is no exact test,
# the nearest existing DIRECTORY is taken. The project declares the root pair via the `test_mirror`
# key.
TEST_PREFIX = "test_"
# Suffixes the runner can COLLECT as tests. Not the same as `CODE_SUFFIX`: files like
# `test_data.json` and `test_settings.toml` are code by suffix and data in substance. Given as a
# target,
# they yield "no tests ran" with a non-zero code, i.e. a turn refusal on a red that does not exist:
# the
# agent has nothing to fix, and three such turns burn the refusal budget and lift the gate for the
# rest of the session.
RUNNABLE_SUFFIX = frozenset((".py", ".sh"))
# Per-turn cost cap. Counted by the target's WEIGHT, not by climb depth: climbing two levels can
# cost three files or sixty-seven. Without a cap an edit to `<src>/__init__.py` pulls the whole
# test tree
# on every "done" — exactly the tax the hook avoids by not running the whole suite.
# The default was chosen by measurement: on a live tree there are no targets weighing 24-50 files,
# and
# the boundary between 23 and 67 is natural.
MIRROR_LIMIT_DEFAULT = 25
# The "sources:tests" root pair — the parsed `test_mirror`.
Spec = tuple[str, str]
TABLE_RE = re.compile(r"^\s*\[", flags=re.MULTILINE)  # start of the first TOML table
# Escapes defined by the format. Anything not listed makes the string INVALID — the real
# parse fails the whole file on such a string rather than leaving the character as is: "leaving"
# would mean
# handing the runner a different command than written, silently.
_ESCAPES = types.MappingProxyType(
    {
        "b": "\b",
        "f": "\f",
        "n": "\n",
        "t": "\t",
        "r": "\r",
        '"': '"',
        "\\": "\\",
    }
)
# Numeric forms: \uXXXX and \UXXXXXXXX. The length is part of the form, so it is paired with the
# key.
_UNICODE_ESCAPES = types.MappingProxyType({"u": 4, "U": 8})
_HEX_BASE = 16
_HEX_LOWER = "".join(f"{digit:x}" for digit in range(_HEX_BASE))
_HEX = frozenset(_HEX_LOWER + _HEX_LOWER.upper())
_MAX_POINT = 0x10FFFF
_SURROGATE_LOW = 0xD800
_SURROGATE_HIGH = 0xDFFF
# Fences of the multi-line value form.
_FENCES = ('"""', "'''")
KEY_RE = r"^\s*[\"']?{0}[\"']?\s*=\s*(.+)$"
# No checks ran — which is not the same as "clean". The message is non-blocking: being unable to
# check must not lock the turn, else a project with an unassembled environment hits the gate every
# time and the refusal budget is spent on real red.
NO_MATCH = (
    "No test ran: no edit of the turn is matched to a test — the changed modules have no"
    " test of their own."
)
# A test by the module's name exists, but modules from different dirs lead to it. Said apart from
# NO_MATCH: "no test" sends the agent to write one, while here the test is there and the name is
# what to change.
NOT_UNIQUE = (
    "No test ran: no edit of the turn is matched to a test — a test by the module's name"
    " exists, but the name is not unique in the tree: modules from different dirs lead to it,"
    " so it belongs to none of them."
)
# The mirror has its own reason: it does not count namesakes at all (the target depends on the full
# path), and talking about
# a non-unique name would explain the refusal by a mechanism that did not work in this mode.
NO_MIRROR_MATCH = (
    "No test ran: no edit of the turn is matched to a test — the changed modules have neither"
    " a test of their own nor a test dir of their layer."
)
NO_RUNNER = "Tests are matched, but there is nothing to run them with"
BAD_COMMAND = "The run command is declared but cannot be parsed"
NOT_STARTED = "The test runner is declared but did not start"
# A skip, not a red: the machine was full for the whole wait and the turn's tests did not run, so a
# red stays unseen this turn. Said to the human on every turn it happens, a document-only turn
# included, and to the agent once per session.
SLOTS_BUSY = (
    "Tests not run: all suite slots on this machine stayed busy for the whole wait;"
    " the full suite runs once per PR"
)
# The lint runner has its own words: a broken lint setting named as the test command would send
# the owner to fix a healthy key.
BAD_LINT = "The lint command is declared but cannot be parsed"
LINT_NOT_STARTED = "The lint command is declared but did not start"
# A declared path form that does not read is said aloud, like a broken mirror: falling back to the
# engine form silently would leave the project's code unmatched while the gate looks alive.
BAD_LAYOUT = "The test path form is declared but the value cannot be parsed"
# A broken mirror setting is a refusal ALOUD. Silently falling back to the old mode is not allowed:
# the gate would vanish
# while looking functional, and there would be nowhere to learn about it.
BAD_MIRROR = "The test mirror is declared but the value cannot be parsed"
# The cap is its own key, hence its own reason: talking about the mirror when the cap is broken
# would
# send the owner to check a healthy setting.
BAD_LIMIT = "The target weight cap is declared but the value cannot be parsed"
# The mirror root parsed but is absent from the tree — a typo in the name. Silence is even less
# allowed:
# EVERYTHING stops matching, and the reason "the modules have no test of their own" sounds benign
# and is muted
# after the first turn. From the second turn the gate is dead and looks alive — exactly what the
# mirror exists to kill.
MISSING_ROOT = "The mirror root is declared but is absent from the tree"
# The tests root exists but has no test names. The mirror maps `<src>/<a>/…` to
# `<tests>/test_<a>/…`, so without a single `test_*` entry at the top level matching FROM THE
# SOURCES SIDE never works — this catches both swapped roots and identical ones.
# The wording about sources is deliberate: edits inside the test tree itself work without them.
BARE_TESTS_ROOT = (
    "The tests root is declared but has no entry with a test prefix —"
    " from the sources side the mirror will match nothing"
)
# A target was found but costs as much as the full suite. Silence is not allowed for the same
# reason: "nothing found" and
# "found but too expensive" are different states, fixed differently.
TOO_HEAVY = "A target was found but is heavier than the cap"
# A run that did not happen at all is stated by STATE, not baked into the hint: setup
# reasons also sound where a run did happen, and a claim of emptiness inside them would become
# false.
RAN_NOTHING = "No test ran."
HINT = (
    "The test path form is the `test_layout` key (a string or a one-line array) or `test_mirror`"
    " (with the weight cap `test_mirror_limit`), the run command is `test_command`, the lint"
    " command is `lint_command`; all in `<project>/.retainer/config.toml`, above the first table."
)
# ── handoff judge: the executor of `ask_owner = off` ─────────────────────────────────────────
# The regulator has two values and had no machine: the ban on blocking questions lived in prose,
# so a turn that handed the work back cost nothing. Codes of a LEGITIMATE handoff — the machine
# form of the exception list the cycle skill carries. A code outside the registry is not a ground.
HANDOFF_CODES = frozenset(
    ("destructive", "owner-key", "native-deny", "self-approval", "boundary", "pointless")
)
# The mark that makes a handoff deliberate: `handoff: <code> — <ground>`. Both dashes are taken:
# the form is typed by hand, and a judge reading only one of them would teach fixing the dash.
HANDOFF_MARK = re.compile(r"^[ \t>*-]*handoff:[ \t]*([a-z-]+)[ \t]*[-—]", re.MULTILINE)
# An ATTEMPT at the mark — any line starting with the word, whatever follows. It is told from
# the mark itself because a failed form must not free the turn: a line that is neither the ending
# nor a ground would otherwise become the last line, carry no question, and silence the judge.
HANDOFF_ATTEMPT = re.compile(r"^[ \t>*-]*handoff:", re.IGNORECASE)
# A question counts unless its `?` belongs to code or to an address: a word, `<`, `:` or `=`
# after it (`issues?state=open`, `(?<!x)`, `(?:a|b)`), or `(`, a backslash, `*` or `+` before it
# (a group opener, an escaped literal, a lazy quantifier). The shape comes from measurement on
# the project's own transcripts, not from taste; the counts live in the task, because the corpus
# is those same sessions and grows with each one, so a number written here would rot. Demanding
# that the question CLOSE the line costs a real handoff: the routine form here bolds the
# question and goes on in the same sentence, and that form is silent under the stricter rule.
ASKED = re.compile(r"(?<![(\\*+])\?(?![\w<:=])")
# Tail window of the wait forms, in characters. Taken from the same measurement: within the tail
# these forms mean a handoff, while over the WHOLE message they fire several times more often —
# retainer:allow-prose — the next line quotes the DATA the pattern matches, not prose
# `жду` sits in ordinary reports ("waiting for CI", "the PR is waiting for the merge"), and that
# is not a handoff.
HANDOFF_TAIL = 300
# Wait forms ADDRESSED TO THE OWNER — whole and bounded. A substring reads a finished check as a
# retainer:allow-prose — the next line quotes the DATA the pattern matches, not prose
# request: `подтверди` matched `подтвердил`. Whole forms in alternation, never a class:
# a Cyrillic class behaves differently across the tools this project runs. The boundary is written
# as a lookaround, not `\b`: a form ending in a dash has no word boundary after it at all.
WAIT_FORMS = re.compile(
    r"(?<!\w)(?:жду\s+тво\w+|жду\s+[«\"']?ок|жду\s+от\s+тебя|да[ёе]шь\s+[«\"']?ок"
    r"|дай\s+[«\"']?ок|подтверди|как\s+решишь|что\s+выбираешь|тво[йё]\s+выбор"
    r"|тво[ёе]\s+решение|решать\s+тебе|скажи,\s+и|скажешь\s+—"
    r"|waiting\s+for\s+you|let\s+me\s+know|your\s+call|up\s+to\s+you)(?!\w)",
    re.IGNORECASE,
)
# How a legitimate ground is put before the owner, shared by every text naming the handoff form.
# It names the one excluded code rather than the list, so it cannot drift from HANDOFF_CODES and
# does not offer a spent `boundary` back. No braces: two of its carriers go through `.format`.
ASK_TOOL = (
    "A legitimate ground other than `pointless` is a decision the owner makes: ask it in the same"
    " turn with the question tool, `AskUserQuestion`, the options listed and the recommended one"
    " first. A fork inside the task is not such a ground: it still goes to an `open-question`"
    " issue. The handoff line stays in the text for this gate, and it ends the text when the tool"
    " is unavailable or the question is dismissed. While that question is open, each turn boundary"
    " repeats only the handoff line, with one more line when something changed: no waiting turns."
)
# The refusal text names the way out, not only the ban: a refusal without one is read as a wall and
# the next turn repeats the same handoff in other words.
HANDOFF_REFUSAL = (
    "Work was handed to the owner while questions are switched off (ask_owner = off). Decide it"
    " yourself: name the default, record the fork as an `open-question` issue and carry on.\n\n"
    "A question about the task BOUNDARY is not a fork and is not quenched by this gate"
    " (`confirm_intake`): its ground is `handoff: boundary`, not a guessed default.\n\n"
    "A handoff that is legitimate carries its ground in the same message, on its own line:\n"
    "    handoff: <code> — <what exactly is blocked>\n"
    "Codes: destructive · owner-key · native-deny · self-approval · boundary · pointless.\n\n"
    + ASK_TOOL
    + "\n\nThe owner's key (.retainer/unlock) lifts this, as it lifts the whole gate."
)
# Policy resolver of the step. It lives in the engine beside the hook; the matrix has one owner,
# and a second reading of it in the hook would diverge from the resolver silently.
POLICY_STEP = "ask_owner"
POLICY_SCRIPT = "retainer-flow-policy.sh"
# The resolver answers in milliseconds; the cap is here for a hung process. It is SMALL on purpose:
# this timeout and `SUITE_TIMEOUT` are spent in the same invocation, and together they must stay
# below the hook's own 600 s — else the hook is killed and the red-run refusal is lost with it.
POLICY_TIMEOUT = 10
BAD_POLICY = (
    "The question gate could not be read: the policy resolver did not answer. The handoff judge is"
    " silent this turn — a broken setting must not refuse every turn"
)
# The cycle's own state is read through its one reader, never by a second copy of the path rule.
STATE_SCRIPT = "retainer-state.sh"
# A local read, so its ceiling is small: reads are memoised per invocation and a turn pays at
# most three (tree, active-issue, plan-checked), keeping the named ceilings under the hook's 600 s.
STATE_TIMEOUT = 3
# A boundary confirmed at intake: the plan of the session's active task was checked. After that a
# `handoff: boundary` asks about what is already settled, and it no longer frees the turn.
SPENT_CODE = "boundary"
BOUNDARY_SPENT = (
    "The boundary of #{0} was confirmed when its plan was checked, so `handoff: boundary` is no"
    " ground here (ask_owner = off). Name the step that is blocked and take it, or decide the fork"
    " yourself: name the default, record it as an `open-question` issue and carry on.\n\n"
    "A ground that does hold goes on its own line: handoff: <code> — <what exactly is blocked>,"
    " with destructive, owner-key, native-deny, self-approval or pointless.\n\n"
    + ASK_TOOL
    + "\n\nThe owner's key (.retainer/unlock) lifts this, as it lifts the whole gate."
)
# Budget slot of the judge, separate from the red-run one: a shared counter would silence the judge
# exactly in a long session, where the red run has already spent it.
HANDOFF_SLOT = "handoff-{0}"

# Reasons the key hint does not fit: the test is simply absent and setup is not at fault, or the
# broken setting is a different one — the advice would send to fix a healthy config.
NO_HINT = frozenset((NO_MATCH, NOT_UNIQUE, NO_MIRROR_MATCH, BAD_POLICY, SLOTS_BUSY))
# Reasons that are said regardless of whether other targets were found: a broken setting and
# a target dropped by weight. Both mean the changed module's tests were NOT run — silence here
# would pass the turn off as checked.
ALWAYS_SAID = frozenset(
    (
        BAD_MIRROR,
        BAD_LAYOUT,
        BAD_LIMIT,
        MISSING_ROOT,
        BARE_TESTS_ROOT,
        TOO_HEAVY,
        BAD_POLICY,
    )
)
# "Once per session" is ONLY for benign reasons: a project always has modules without a test of
# their own, and
# a word on every turn teaches it not to read. Everything else repeats until fixed, and this is not
# symmetry for its own sake: the agent cannot fix a broken setting at all (`.retainer/**` is under
# the
# guard, only the owner's key lifts it), and a target dropped by weight means the changed
# module's tests were not run. Silence on Stop is indistinguishable from a green run — the gate
# would vanish while
# looking functional. The benign reasons of the two modes share a slot deliberately: it is one and
# the same state,
# said in different words. The busy-slots skip has a slot too, read for the agent channel only
# (`_say`): the human hears every skip, the agent the first one of a session.
REASON_KIND = types.MappingProxyType(
    {
        NO_MATCH: "no-match",
        NOT_UNIQUE: "no-match",
        NO_MIRROR_MATCH: "no-match",
        SLOTS_BUSY: "slots-busy",
    }
)
# A document has no same-named test and cannot have: the source of the doc gates is the whole tree,
# not
# a file next to it. So this is not a name map but an explicit minimum. The same set is part of the
# end-to-end minimum of
# CI (bin/retainer-ci-scope.sh), and tests/test_stop_gate.sh guards that the lists match: two
# registries
# of one intent without a cross-check drift apart silently.
DOC_SUFFIX = frozenset((".md",))
# The end-to-end marker is in the header of the test itself, not a list here: a list in another
# file lags
# behind new scanners silently. The header means the first lines — a marker below them would mean
# it was placed not by the test's author but in passing inside the code.
MARKER = "# end-to-end:"
MARKER_LINES = 20
DOC_TESTS = (
    "tests/test_doc_links.sh",
    "tests/test_doc_skill_count.sh",
    "tests/test_docs_mechanisms.sh",
)
# The tools whose input names a file the session wrote, and the keys that carry the path.
WRITE_TOOLS = frozenset(("Edit", "MultiEdit", "Write", "NotebookEdit"))
WRITE_KEYS = ("file_path", "notebook_path")
# A transcript timestamp in the ISO form git reads as a `--since` bound.
ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$")
# The event field set when a turn re-enters after this hook refused it.
REENTRY = "stop_hook_active"
# A final message that claims the work is done, in either language of the corpus. Whole forms in
# alternation, bounded by lookarounds, as `WAIT_FORMS` is. A turn without one is not judged; its
# own edits are judged on the next turn that claims done while they are still uncommitted.
DONE_FORMS = re.compile(
    r"(?<!\w)(?:done|finished|complete[ds]?|fixed|ready|merged|shipped|implemented|resolved"
    r"|landed|pass(?:es|ed|ing)?|green|works|working"
    r"|готов[оаы]?|сделан[оаы]?|сделал[аи]?|исправлен[оаы]?|исправил[аи]?|починил[аи]?"
    r"|починен[оаы]?|собрал[аи]?|прогнал[аи]?|работает|зел[её]н\w*|прош[её]л"
    r"|прошл[аио]|проход[ия]т|заверш[её]н[оаы]?|завершил[аи]?|закрыт[оаы]?|закрыл[аи]?"
    r"|выполнен[оаы]?|смержен[оаы]?|влит[оаы]?|собран[оаы]?|записан[оаы]?)(?!\w)",
    re.IGNORECASE,
)


def _repo(cwd: Path) -> Path | None:
    """Root of the git tree or None — outside a repository the gate has nothing to check."""
    done = subprocess.run(
        ["git", "-C", str(cwd), "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=False,
    )
    return Path(done.stdout.strip()) if done.returncode == 0 else None


def _tree(event: Event) -> Path | None:
    """The repository this turn answers for: the cwd's, else the tree the session took its task in.

    The recorded tree is a fallback for a shell that left every repository; a cwd inside a
    repository wins.
    """
    return _tree_of(str(event.get("cwd") or "."), _session(event))


@functools.cache
def _tree_of(cwd: str, session: str) -> Path | None:
    """`_tree` resolved once per invocation: three readers want it, each `_repo` a subprocess."""
    repo = _repo(Path(cwd))
    if repo is not None:
        return repo
    taken = _state_read(session, ("tree",))
    return _repo(Path(taken)) if taken else None


def _session(event: Event) -> str:
    """The session the event names; empty when it names none."""
    return str(event.get("session_id") or "")


def _engine(script: str) -> list[str]:
    """The command running one of the engine's scripts, taken beside this hook, not the tree."""
    engine = Path(__file__).resolve().parent.parent
    return ["bash", str(engine / "bin" / script)]


def _changed(repo: Path) -> list[str]:
    """Working-tree paths that differ from the index and HEAD."""
    done = subprocess.run(
        # `core.quotepath=false`: a non-ASCII path arrives as `\320\244…` otherwise, `stat` on it
        # raises, and the standstill stamp degenerates to the bare name — the very false positive
        # the size and time were added to remove.
        [*GIT, str(repo), "-c", "core.quotepath=false", "status", "--porcelain=v1", "-uall"],
        capture_output=True,
        text=True,
        check=False,
    )
    if done.returncode != 0:
        return []
    rows = done.stdout.splitlines()
    lines = [line[3:] for line in rows if len(line) > 3]
    trimmed = [line.strip('"') for line in lines]
    return [path.rsplit(" -> ", 1)[-1] for path in trimmed]


def _mine(event: Event, repo: Path) -> list[str]:
    """The changed paths this session wrote; all of them when its transcript cannot tell.

    Files another session or the owner left in the tree are not this turn's work and are not
    judged.
    """
    changed = _changed(repo)
    named = str(event.get("transcript_path") or "")
    cwd = str(event.get("cwd") or ".")
    own = _own(named, cwd, repo) if named else None
    if own is None:
        return changed
    return [path for path in changed if path in own]


@functools.cache
def _own(transcript: str, cwd: str, repo: Path) -> frozenset[str] | None:
    """Paths the session wrote, relative to `repo`; None — the transcript cannot tell.

    Sources: the write-tool targets of the transcript and of its subagents' transcripts, and the
    files of the commits on HEAD's first-parent line since the session started. None, and so the
    whole tree is judged as before, when the main transcript does not read or holds nothing in a
    shape this reader knows: an empty set there would silence the gate on a format it cannot see.
    """
    records = _records(Path(transcript))
    start = _start(records)
    targets = _written(records)
    if start is None or targets is None:
        return None
    for side in _subagents(Path(transcript)):
        targets |= _written(_records(side)) or set()
    own = {_relative(repo, Path(cwd), target) for target in targets}
    return frozenset(own | _committed(repo, start))


def _records(transcript: Path) -> list[dict[str, object]]:
    """The transcript's records; empty when it does not read."""
    try:
        with transcript.open(encoding="utf-8", errors="replace") as lines:
            return [_record(line) for line in lines]
    except OSError:
        return []


def _record(line: str) -> dict[str, object]:
    """One transcript line as a dict; empty for a line that is not a JSON object."""
    try:
        parsed = json.loads(line)
    except ValueError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _start(records: list[dict[str, object]]) -> str | None:
    """The first timestamp of the session, in the ISO form git reads; None — there is none."""
    stamps = [str(record.get("timestamp")) for record in records]
    return next(filter(ISO_RE.match, stamps), None)


def _written(records: list[dict[str, object]]) -> set[str] | None:
    """The paths the write tools named; None — no record in the shape this reader knows.

    Unknown is no assistant record with a content list at all, or a write-tool block carrying
    none of the path keys: either means the format moved, and silence would read as clean.
    """
    known = [blocks for blocks in map(_blocks, records) if blocks is not None]
    named = [path for blocks in known for path in _targets_of(blocks)]
    if not known or "" in named:
        return None
    return set(named)


def _blocks(record: dict[str, object]) -> list[object] | None:
    """The content blocks of an assistant record; None for any other record."""
    message = record.get("message")
    if record.get("type") != "assistant" or not isinstance(message, dict):
        return None
    blocks = message.get("content")
    return blocks if isinstance(blocks, list) else None


def _targets_of(blocks: list[object]) -> list[str]:
    """The path each write-tool block names; an empty string where a block names none."""
    calls = [block for block in blocks if isinstance(block, dict)]
    writes = [call for call in calls if call.get("name") in WRITE_TOOLS]
    return [_path_of(call.get("input")) for call in writes]


def _path_of(tool_input: object) -> str:
    """The first path key a write tool's input carries; empty when it carries none."""
    if not isinstance(tool_input, dict):
        return ""
    paths = (tool_input.get(key) for key in WRITE_KEYS)
    return next((str(path) for path in paths if path), "")


def _subagents(transcript: Path) -> list[Path]:
    """The transcripts of the session's subagents, which the harness keeps beside its own."""
    return sorted(transcript.with_suffix("").joinpath("subagents").glob("*.jsonl"))


def _relative(repo: Path, cwd: Path, target: str) -> str:
    """A written path relative to the repository root; empty when it lies outside.

    The path is resolved to meet the root git names, which is already real: git says
    `/private/var/…` where a transcript says `/var/…`, and an unresolved comparison would put
    every own edit outside the tree.
    """
    path = Path(target)
    full = path if path.is_absolute() else cwd / path
    try:
        return full.resolve().relative_to(repo).as_posix()
    except (OSError, ValueError):
        return ""


def _committed(repo: Path, start: str) -> set[str]:
    """Files of the non-merge commits on HEAD's first-parent line made since `start`.

    Bounded by time, not by session: every session shares one git identity, so another
    session's commit on the same HEAD counts too — more is judged, never less.
    """
    log = [*GIT, repo.as_posix(), "-c", "core.quotepath=false", "log", "--first-parent"]
    since = ["--no-merges", f"--since={start}", "--name-only", "--format=", "HEAD"]
    listed = _read([*log, *since], GIT_TIMEOUT, dict(os.environ))
    return {path for path in listed.splitlines() if path}


def _claims_done(event: Event) -> bool:
    """Does this turn claim done, so that its edits are judged?

    Judged also when the claim cannot be read — no message — and when the turn re-enters after a
    refusal, so the refusal budget keeps holding a turn that answers a red run in other words.
    """
    if event.get(REENTRY):
        return True
    said = str(event.get("last_assistant_message") or "")
    return not said.strip() or bool(DONE_FORMS.search(said))


def _cfg(repo: Path, key: str) -> str:
    """A TOP-level string key from the project config; empty — no such key.

    Parsing is the same as the guard's: a real TOML parser where available, and a line-by-line head
    of the file on
    system python 3.9. A key below a table belongs to the table and does not count as top-level.
    """
    text = _cfg_text(repo)
    if not text:
        return ""
    if HAVE_TOMLLIB:
        parsed = _cfg_toml(text, key)
        if parsed is not None:
            return parsed
    hit = _cfg_line(text, key)
    return "" if hit is None else _bare(hit)


def _cfg_text(repo: Path) -> str:
    """Project config text; empty — the file is absent or unreadable."""
    try:
        return (repo / ".retainer" / "config.toml").read_text(encoding="utf-8")
    except OSError:
        return ""


def _cfg_line(text: str, key: str) -> str | None:
    """Declared key value in the flat part of the config; None — no such key there."""
    head = TABLE_RE.split(text, maxsplit=1)[0]
    pattern = KEY_RE.format(re.escape(key))
    hit = re.search(pattern, head, flags=re.MULTILINE)
    return None if hit is None else hit.group(1)


def _named(repo: Path, key: str) -> bool:
    """The key OCCURS in the flat part of the config — whether or not its value is readable.

    "No key" and "key present but value unreadable" are different states, while `_cfg` answers both
    with
    emptiness. A bare `test_mirror_limit = 3` and an unquoted `test_mirror = src:tests` are both
    treated by both parsers
    as "not set": the owner wrote a setting, the hook works with the default or the old
    mode, and there is nobody to say so. The `_cfg` parse is left untouched — it belongs to
    a separate task.
    """
    return _cfg_line(_cfg_text(repo), key) is not None


def _bare(declared: str) -> str:
    """Value of the line-by-line parse — the same TOML subset a real parse would return.

    A hash inside quotes is part of the value, not a comment start: cutting on it blindly would
    silently truncate the run command. A value that is NOT a string (number, boolean, array) is
    empty: the
    real parse yields a non-str here, and both paths must answer the same, else prod reads the
    config differently from the test.
    """
    text = declared.strip()
    for fence in _FENCES:
        if text.startswith(fence):
            return _fenced(text, fence)
    if text.startswith("'"):
        end = text.find("'", 1)
        return text[1:end] if end > 0 else ""
    if text.startswith('"'):
        return _drop_multiline(_unquote(text))
    return ""


def _drop_multiline(declared: str) -> str:
    """A value with a line break is empty: the line-by-line parse cannot assemble it."""
    return "" if "\n" in declared else declared


def _fenced(text: str, fence: str) -> str:
    """Content of the multi-line value form closed on the same line; else empty."""
    end = text.find(fence, len(fence))
    return text[len(fence) : end] if end > 0 else ""


def _unquote(text: str) -> str:
    """A double-quoted string with escapes resolved; an unclosed one runs to the end of the line.

    An escaped quote is an ordinary form for a run command (`pytest -k "a"`), so
    escapes are parsed rather than cutting the value short.

    An unclosed quote and an unknown escaped form make a broken string: the real parse on it
    yields empty, and returning a stub of the value here would mean understanding one file two
    ways.
    """
    out: list[str] = []
    idx = 1
    while idx < len(text):
        char = text[idx]
        if char == "\\":
            piece, idx = _escape(text, idx)
            if piece is None:
                return ""
            out.append(piece)
            continue
        if char == '"':
            return "".join(out)
        out.append(char)
        idx += 1
    return ""


def _escape(text: str, idx: int) -> tuple[str | None, int]:
    """An escape sequence and the position after it; None — the form is invalid."""
    after = idx + 2
    simple = _ESCAPES.get(text[idx + 1 : after])
    if simple is not None:
        return (simple, after)
    width = _UNICODE_ESCAPES.get(text[idx + 1 : after])
    if width is None:
        return (None, after)
    return _codepoint(text[after : after + width], width, after)


def _codepoint(digits: str, width: int, after: int) -> tuple[str | None, int]:
    """A character from its hexadecimal notation; None — the form is invalid.

    Not only the length and digit set are judged but the VALUE: beyond the range and inside
    a surrogate pair there is no character, and `chr` on such input crashes the hook — the gate
    vanishes.
    """
    hexed = all(char in _HEX for char in digits)
    if len(digits) != width or not hexed:
        return (None, after)
    point = int(digits, _HEX_BASE)
    surrogate = _SURROGATE_LOW <= point <= _SURROGATE_HIGH
    if point > _MAX_POINT or surrogate:
        return (None, after)
    return (chr(point), after + width)


def _cfg_toml(text: str, key: str) -> str | None:
    """A key from the parsed TOML; None — the file did not parse and the line-by-line path decides.

    A syntax error ANYWHERE in the file drops all keys at once here, while the line-by-line path
    errs
    only on its own line. Such asymmetry would mean one and the same broken config is understood
    differently depending on the interpreter the harness started the hook with.

    A multi-line value is dropped deliberately: the line-by-line parse cannot assemble it, and
    returning it here would mean understanding one file two ways.
    """
    try:
        parsed = tomllib.loads(text)
    except (ValueError, TypeError):
        return None
    declared = parsed.get(key)
    if not isinstance(declared, str):
        return ""
    return _drop_multiline(declared)


Rivals = dict[str, int]
# Path forms of `test_layout`, each with its rivals, in the order the project declared them.
Forms = list[tuple[str, Rivals]]
# Targets of a turn and the reasons there are not more of them.
Found = tuple[Names, Names]


def _match(repo: Path, path: str, layout: str, rivals: Rivals) -> str | None:
    """The test responsible for an edit: the test itself or the test of the same-named module.

    The test path form is taken from the project template — and "this is a test itself" is learned
    from the same place, by the head and
    tail of the template. None — the edit is matched to no test.
    """
    head, _, tail = layout.partition("{stem}")
    if head != layout and path.startswith(head) and path.endswith(tail):
        return path
    if Path(path).suffix not in CODE_SUFFIX:
        return None
    named = _test_path(path, layout)
    return None if named is None else _guess(repo, named, rivals)


def _guess(repo: Path, named: str, rivals: Rivals) -> str | None:
    """A target is fit if the file exists, lies inside the tree and one module leads to it.

    A test reached by modules from DIFFERENT dirs provably belongs to none of them.
    Running a foreign test would silently pass an edit off as checked — worse than an empty match,
    which
    the hook states aloud.
    """
    if rivals.get(named, 0) > 1:
        return None
    guess = repo / named
    if not _is_file(guess) or not _inside(repo, guess):
        return None
    return named


def _test_path(path: str, layout: str) -> str | None:
    """Where a module maps by the template; None — a template without a placeholder."""
    if "{stem}" not in layout:
        return None
    stem = Path(path).stem
    for prefix in ("retainer-", "retainer_"):
        stem = stem.removeprefix(prefix)
    return layout.replace("{stem}", stem.replace("-", "_"))


def _mirror_spec(declared: str) -> Spec | None:
    """The "sources:tests" root pair from `test_mirror`; None — the key is unset or does not parse.

    Strict parsing: an empty half, not exactly one separator, `..` inside — this is NOT a mirror. A
    guess
    here would cost more than a refusal: the root pair sets where the hook goes for targets, and a
    mistake in it
    silently sends the run to a foreign tree.
    """
    if not declared:
        return None
    halves = declared.split(":")
    if len(halves) != 2:  # "source" and "target" — the pair has no third meaning
        return None
    source, target = (half.strip().strip("/") for half in halves)
    if not _root_ok(source) or not _root_ok(target):
        return None
    source = str(Path(source))
    target = str(Path(target))
    if source == target:
        return None
    # The normalization before comparing is deliberate: `./src` is the same dir as `src`, and
    # comparing raw
    # strings would let `./src:src` through — a form this same parse declares normal.
    return source, target


def _root_ok(root: str) -> bool:
    """A root is fit: non-empty, no upward escape and EXACTLY one segment.

    One segment is not nitpicking: matching compares the first path segment with the whole root,
    and "server/apps" would be accepted silently, matching nothing and blaming the project ("no
    test of its own"
    instead of "root set wrongly"). Exactly the class the mirror exists for.
    """
    if not root or ".." in root:
        return False
    return len(Path(root).parts) == 1


def _mirror_limit(repo: Path) -> int | None:
    """The target weight cap; None — the value is declared but broken.

    The value is read as a STRING: `_cfg` does not return numbers (a bare `25` is "not set" for
    it), and
    a cap declared as a number would be silently replaced by the default.
    """
    declared = _cfg(repo, "test_mirror_limit")
    if not declared:
        # The key exists but the value does not — it was declared as a non-string (bare `25`). The
        # default here would silently
        # replace what the owner wrote.
        return None if _named(repo, "test_mirror_limit") else MIRROR_LIMIT_DEFAULT
    # `isdecimal`, NOT `isdigit`: the latter is true for superscript digits ("25²"), which `int`
    # does not
    # accept — the hook would crash with a traceback, and a crashed Stop hook means a vanished
    # gate, not a refusal.
    if not declared.isdecimal() or not int(declared):
        return None
    return int(declared)


def _weigh(target: Path) -> int:
    """How many test files a target pulls in: a file weighs one, a directory everything inside.

    The RUNNABLE is counted, not all code by suffix: a dir of only `test_users.json` and
    `test_input.yaml` would otherwise weigh more than zero, pass the lower bound and go to a runner
    that
    answers "no tests ran" with a non-zero code. A turn refusal on a red that does not exist is
    exactly what the
    bound exists to prevent.
    """
    if _is_file(target):
        return 1
    try:
        # The catch is needed both on the walk and on its elements: `glob` swallows an unreadable
        # dir itself, while
        # a symlink to an inaccessible place crashes it from inside — the walk also takes the
        # changed path itself as a target.
        found = [path for path in target.glob(f"**/{TEST_PREFIX}*") if _is_file(path)]
    except OSError:
        return 0
    return len([path for path in found if path.suffix in RUNNABLE_SUFFIX])


def _mirrored(path: str, spec: Spec) -> list[str] | None:
    """Segments of the mirror target for an edit; None — the edit is outside the sources root."""
    parts = Path(path).parts
    if not parts or parts[0] != spec[0]:
        return None
    mirrored = [f"{TEST_PREFIX}{part}" for part in parts[1:]]
    return [spec[1], *mirrored]


def _mirror_target(repo: Path, path: str, spec: Spec, limit: int) -> str | None:
    """Target for an edit: the same-named test, else the nearest test dir above it.

    The climb is needed because tests are named by scenario, not by module: most modules have no
    same-named test, while their layer's dir almost always exists. A target heavier than the cap is
    not
    taken — the hook states that with a separate reason, so "no target" and "expensive" do not
    blur.
    """
    if _inside_tests(path, spec):
        return _own_target(repo, path, limit)
    if Path(path).suffix not in CODE_SUFFIX:
        # The same filter as in substitution mode: an edit to a README or an image inside the
        # sources
        # would pull the tests of the whole layer on every turn. Documents go their own way — via
        # the doc minimum.
        return None
    mirrored = _mirrored(path, spec)
    return None if mirrored is None else _climb(repo, mirrored, limit)


def _climb(repo: Path, mirrored: list[str], limit: int) -> str | None:
    """The nearest existing target: the same-named test itself, else the dir above it.

    The climb stops BEFORE reaching the test tree root: the root is the whole suite, and "an edit
    to
    one module" would turn into a full run every turn. The weight cap would cut such a root
    by itself, but only where the suite is large; the boundary is needed at any size.
    """
    named = repo / Path(*mirrored)
    if _is_file(named):
        return _fits(repo, named, limit)
    for depth in range(len(mirrored) - 1, 1, -1):
        holder = repo / Path(*mirrored[:depth])
        if not _is_dir(holder):
            continue
        # The first existing dir is the answer, fit or not. Climbing higher at zero
        # weight is tempting (a real test might lie a floor up), but the climb does not tell
        # "higher in
        # my app" from "higher in the shared apps dir": the target would land on neighbors' tests,
        # and running a foreign test passes an edit off as checked — worse than an empty match.
        return _fits(repo, holder, limit)
    return None


def _fits(repo: Path, candidate: Path, limit: int) -> str | None:
    """A fit target lies inside the tree and weighs from one test up to the cap.

    Else there is none.

    The checks live in one place: judging a target found by two different paths with two copies of
    the condition
    means forgetting a copy someday — and handing the runner either a path for a root or the whole
    suite.

    The lower bound is not a formality. A dir WITHOUT tests (`tests/fixtures`, `tests/factories`,
    `tests/data`) meets the runner as emptiness — pytest answers "no tests ran" with a non-zero
    code, and
    the turn is refused on a red that does not exist. The agent has nothing to fix, while the
    message says to fix and
    say "done" again: three such turns burn the refusal budget, and for the rest of the session the
    gate is silent
    about real red. A zero weight means "no target", not "tests failed".
    """
    # `_inside` goes first: the weight is counted by walking the tree, and doing that before the
    # containment check means
    # walking a dir outside the repository (a symlink out) in full. A hook that overruns the
    # timeout is a vanished gate, not a refusal.
    if not _inside(repo, candidate):
        return None
    if _is_file(candidate) and candidate.suffix not in RUNNABLE_SUFFIX:
        # A FILE target must be something the runner can collect. `test_data.json` reaches here
        # by both paths — the mirror from a source and an edit inside the test tree — and a single
        # such
        # path in the list poisons the WHOLE run: pytest answers non-zero even when real tests
        # are alongside. Judge it here, not at each call: a third copy of the condition
        # would someday diverge from the first two.
        return None
    weight = _weigh(candidate)
    if not weight or weight > limit:
        return None
    return str(candidate.relative_to(repo))


def _inside_tests(path: str, spec: Spec) -> bool:
    """The edit lies in the test tree."""
    parts = Path(path).parts
    return bool(parts) and parts[0] == spec[1]


def _own_target(repo: Path, path: str, limit: int) -> str | None:
    """Target for an edit INSIDE the test tree.

    The test itself, and for anything else its directory.

    A file without a test prefix (`conftest.py`, fixtures, helpers) is not a runner target —
    nothing to collect from it.
    But it breaks the whole suite, so staying silent about it is worse than running the neighbors:
    its
    own directory serves as the target.
    """
    own = repo / path
    if own.name.startswith(TEST_PREFIX) and own.suffix in RUNNABLE_SUFFIX:
        # A deleted test does not become a target: the weight of a nonexistent path is zero, and
        # the lower bound of `_fits`
        # drops it where everything else is judged. There is deliberately no second check here.
        return _fits(repo, own, limit)
    if own.suffix not in CODE_SUFFIX:
        # A README and images next to tests do not pull a run — the same filter as outside the test
        # tree.
        # Without it an edit to `tests/README.md` takes the tree ROOT as target: there is no climb
        # here, and the `_climb`
        # bound does not guard such a target — a note edit would run the whole suite every turn.
        return None
    holder = own.parent
    return _fits(repo, holder, limit) if _is_dir(holder) else None


def _forms(repo: Path, layouts: list[str]) -> Forms:
    """Each path form with its rivals: from how many DIFFERENT tree dirs modules map to one test.

    Counted per form, since each form maps the whole tree on its own, and by target, not by file
    name: two different names converge to one test after normalization, and counting by names
    does not see that. The list is taken once, with the same view as the turn's edits — untracked
    included: a new module is created before it is committed.

    The dir in the key is deliberate. Namesakes in ONE dir are usually one module in two forms
    (wrapper and implementation), and the shared test belongs to both; refusing to run it would
    drop working
    coverage from the gate. Namesakes in DIFFERENT dirs are different modules, and there the name
    proves
    nothing.
    """
    done = subprocess.run(
        ["git", "-C", str(repo), "ls-files", "--cached", "--others", "--exclude-standard"],
        capture_output=True,
        text=True,
        check=False,
    )
    listed = done.stdout.splitlines()
    return [(layout, _rivals(_homes(listed, layout))) for layout in layouts]


def _rivals(homes: dict[str, set[str]]) -> Rivals:
    """How many different dirs lead to each target."""
    return {named: len(where) for named, where in homes.items()}


def _homes(listed: list[str], layout: str) -> dict[str, set[str]]:
    """Dirs of the modules leading to each target."""
    found: dict[str, set[str]] = {}
    for line in listed:
        if Path(line).suffix not in CODE_SUFFIX:
            continue
        named = _test_path(line, layout)
        if named:
            where = found.setdefault(named, set())
            where.add(str(Path(line).parent))
    return found


def _inside(repo: Path, guess: Path) -> bool:
    """The path lies INSIDE the repository — checked after normalization, not by text.

    `relative_to` is a lexical operation: it silently accepts a path with `..`.
    """
    try:
        return guess.resolve().is_relative_to(repo.resolve())
    except OSError:
        return False


def _docs(repo: Path, changed: list[str]) -> list[str]:
    """The doc minimum if the edits include a document; else empty.

    One set for any number of documents: each of these tests reads the whole tree, and running
    it once per file means paying for the same run twice.
    """
    if not any(Path(path).suffix in DOC_SUFFIX for path in changed):
        return []
    return [name for name in DOC_TESTS if _is_file(repo / name)]


def _crosscut(repo: Path) -> list[str]:
    """Tests whose INPUT is the whole tree.

    They declare themselves with a marker in their own header.

    Selection by names does not see such a test: it has no "own" source file. While the set was
    kept as
    a list in another file, it lagged behind new scanners — selection answered green while
    the full suite on the same tree went red on two tests that were not in the list.
    """
    found = []
    for path in sorted((repo / "tests").glob("test_*.sh")):
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue  # an unreadable file is skipped by selection, not a hook crash
        head = text.split("\n")[:MARKER_LINES]
        marked = any(line.startswith(MARKER) for line in head)
        if marked:
            found.append(str(path.relative_to(repo)))
    return found


def _targets(repo: Path, changed: list[str]) -> tuple[Names, Names]:
    """Tests matched to working-tree edits, and the reason if there are none.

    The matching is coarse: a test edit pulls the test itself, a script edit — the test of the same
    name,
    a document edit — the doc minimum. The limitation: an edit answered by neither a same-named
    test nor a doc gate pulls no run at all.

    The reason is returned next to the list because emptiness comes in kinds: no target at all, a
    target
    found but heavier than the cap, a broken mirror setting. One text for three states would teach
    fixing the wrong thing.
    """
    always = set(_docs(repo, changed)) | set(_crosscut(repo))
    declared = _cfg(repo, "test_mirror")
    spec = _mirror_spec(declared)
    if spec is None:
        # Declared but does not parse — this is not "not set". A forgotten quote also lands here
        # (`test_mirror = src:tests`): a quiet fallback to substitution would mean 7% matching
        # instead of 87% — exactly "the gate does not work but looks working".
        if declared or _named(repo, "test_mirror"):
            return sorted(always), [BAD_MIRROR]
        return _by_form(repo, changed, always)
    if not _roots_live(repo, spec):
        return sorted(always), [MISSING_ROOT]
    targets, reason = _by_mirror(repo, changed, spec, always)
    if _tests_root_ready(repo, spec):
        return targets, [reason]
    # Nothing to match from the sources side, but edits INSIDE the test tree do match and
    # must run: cutting them off lost the refusal on a red test — exactly the half whose
    # workability the reason itself speaks about.
    return targets, [BARE_TESTS_ROOT, reason]


def _roots_live(repo: Path, spec: Spec) -> bool:
    """Both roots are TOP-level dirs of the tree, checked against a listing.

    Not `is_dir()`: it asks the filesystem about path resolution, which is case-insensitive on
    macOS and Windows. `SRC` with a `src` dir would pass the check, while matching compares the
    first
    path segment character by character — NOTHING would match, and the hook would answer with a
    benign reason
    muted after the first turn. From the second turn, silence at a zero run.

    The listing also answers "the root turned out to be a file": `README.md` is not listed among
    dirs.
    """
    listed = {entry.name for entry in _listing(repo) if _is_dir(entry)}
    return all(root in listed for root in spec)


def _is_file(path: Path) -> bool:
    """The path is a file; an unreadable, inaccessible or broken path counts as absent.

    The catch follows the same standard as `_inside` and `_listing`: `is_file()` swallows only
    absence and kin, while permissions and a symlink to an inaccessible dir pass OUTWARD. A crashed
    hook
    is a vanished gate, not a turn refusal: the harness prints the traceback and lets the turn
    through.
    """
    try:
        return path.is_file()
    except OSError:
        return False


def _is_dir(path: Path) -> bool:
    """The path is a directory; an unreadable, inaccessible or broken path counts as absent."""
    try:
        return path.is_dir()
    except OSError:
        return False


def _listing(root: Path) -> list[Path]:
    """Directory contents; empty — the dir is absent or unreadable.

    The catch here follows the same standard as `_inside` and config parsing: an unreadable dir
    would crash the hook with a traceback, and a crashed Stop hook is a vanished gate, not a
    refusal.
    """
    try:
        return list(root.iterdir())
    except OSError:
        return []


def _tests_root_ready(repo: Path, spec: Spec) -> bool:
    """The tests root has at least one entry with a test prefix.

    Not a heuristic but a consequence of the construction: the mirror looks for a target by the
    path `<tests>/test_<segment>/…`, and
    without a single such entry at the top, sources cannot be matched in any tree. It also catches
    swapped roots (`tests:src`): otherwise such a case would answer with a benign reason
    muted after the first turn.
    """
    root = repo / spec[1]
    return any(entry.name.startswith(TEST_PREFIX) for entry in _listing(root))


def _by_mirror(
    repo: Path,
    changed: list[str],
    spec: Spec,
    always: set[str],
) -> tuple[list[str], str]:
    """Matching by dir mirror — the mode of projects whose tests are laid out by layers."""
    limit = _mirror_limit(repo)
    if limit is None:
        return sorted(always), BAD_LIMIT
    found = [_mirror_target(repo, path, spec, limit) for path in changed]
    matched = {target for target in found if target}
    return sorted(matched | always), _mirror_reason(repo, changed, found, spec)


def _mirror_reason(
    repo: Path,
    changed: list[str],
    found: list[str | None],
    spec: Spec,
) -> str:
    """Why not everything matched: a target dropped by weight or its absence.

    The overweight is counted by the DROPPED paths, not by an empty target list. Counting "when
    nothing was
    found" loses it on any turn where another edit matched alongside: the heavy module's tests
    were not run, and the turn passed as checked. Iterating over ALL paths is not allowed either —
    one matched under the real cap would match without a cap, and the overweight would sound on
    every successful turn.
    """
    dropped = [path for index, path in enumerate(changed) if not found[index]]
    return TOO_HEAVY if _heavy(repo, dropped, spec) else NO_MIRROR_MATCH


def _by_form(repo: Path, changed: Names, always: set[str]) -> Found:
    """Matching by the declared path forms, or the reason the forms do not read."""
    layouts = _layouts(repo)
    if layouts is None:
        return sorted(always), [BAD_LAYOUT]
    matched, reason = _by_layout(repo, changed, layouts)
    return sorted(matched | always), [reason]


def _layouts(repo: Path) -> list[str] | None:
    """The path forms of `test_layout`; None — the key is declared and its value does not read.

    A string is read by `_cfg`, an array by `_array`. Not declared, or declared an explicitly empty
    string — the engine form, as before.
    """
    raw = _cfg_line(_cfg_text(repo), "test_layout")
    if raw is None:
        return [LAYOUT_DEFAULT]
    if raw.lstrip().startswith("["):
        return _array(raw) or None
    single = _cfg(repo, "test_layout")
    if single:
        return [single]
    return [LAYOUT_DEFAULT] if EMPTY_RE.match(raw.strip()) else None


def _array(raw: str) -> list[str]:
    """Strings of a one-line array; empty — not such an array, or one of its strings is empty.

    Each string is read by `_bare`, the same subset as a single value: an escape the format does
    not define makes the string, and so the whole array, unreadable.
    """
    hit = ARRAY_RE.match(raw.strip())
    if hit is None:
        return []
    strings = [_bare(token) for token in ITEM_RE.findall(hit.group(1))]
    return strings if all(strings) else []


def _by_layout(repo: Path, changed: Names, layouts: Names) -> tuple[set[str], str]:
    """Matching by `{stem}` substitution — the default mode until the project declares a mirror.

    An edit takes the target of the first form that finds one: a project with two code roots lists
    a form per root, and a module of the second root finds its test there.
    """
    forms = _forms(repo, layouts)
    found = [_first(repo, path, forms) for path in changed]
    missed = [path for index, path in enumerate(changed) if not found[index]]
    return {path for path in found if path}, _layout_reason(repo, missed, forms)


def _first(repo: Path, path: str, forms: Forms) -> str | None:
    """The target of the first form that matches the edit; None — no form does."""
    for layout, rivals in forms:
        target = _match(repo, path, layout, rivals)
        if target:
            return target
    return None


def _layout_reason(repo: Path, missed: list[str], forms: Forms) -> str:
    """Why edits went unmatched: no test at all, or a test whose name several dirs share."""
    shared = any(
        _shared(repo, path, layout, rivals) for path in _code(missed) for layout, rivals in forms
    )
    return NOT_UNIQUE if shared else NO_MATCH


def _shared(repo: Path, path: str, layout: str, rivals: Rivals) -> bool:
    """A test by the module's name exists, and modules from different dirs lead to it."""
    named = _test_path(path, layout)
    if named is None or rivals.get(named, 0) <= 1:
        return False
    return _is_file(repo / named)


def _heavy(repo: Path, changed: list[str], spec: Spec) -> bool:
    """The edits had a target, and it was dropped by the weight cap, not by its absence."""
    return any(_mirror_target(repo, path, spec, limit=sys.maxsize) for path in changed)


def _code(changed: list[str]) -> list[str]:
    """Code edits of the turn: the not-run message is attached only to them.

    An edit to a notebook or a document that no test answers is the norm, and talking about it
    every turn teaches that the message can be left unread.
    """
    return [path for path in changed if Path(path).suffix in CODE_SUFFIX]


def _slot(event: Event) -> str:
    """Name of the budget slot — per session: two sessions overwrite a shared counter.

    The session id arrives in the event; an environment variable is a spare input for probes.
    Without
    both, there is one slot per machine, and a budget spent once is never restored.
    """
    named = os.environ.get("RETAINER_GUARD_SESSION") or _session(event)
    slot = named or "default"
    return f"stop-gate-{slot}"


def _budget(name: str, spend: bool = False) -> int:
    """How many refusals the gate spent in this session; `spend` — record one more.

    State lives where the guard's state lives and is split by session: two concurrent
    sessions overwrite a shared counter, and one's budget would lift the gate for the other.
    """
    slot = STATE / name
    try:
        spent = int(slot.read_text())
    except (OSError, ValueError):
        spent = 0
    if not spend:
        return spent
    with contextlib.suppress(OSError):
        # Could not write — the gate has worked anyway, the budget just did not move. The state
        # dir is created INSIDE the suppression: a failure on it crashes the hook, i.e. lifts the
        # gate.
        STATE.mkdir(parents=True, exist_ok=True)
        slot.write_text(str(spent + 1))
    return spent + 1


def _mute(scope: Scope, reason: str) -> bool:
    """This reason was already stated in the session — no need to state it again.

    Not everything is muted: a project always has modules without a test of their own, and a word
    on every turn teaches
    it not to read. A broken run command and a target dropped by weight, however, repeat until
    fixed: both mean the changed module's tests were not run, and this is not background noise.
    A skip on busy slots is muted for the agent only: the human hears it on every turn.
    """
    kind = REASON_KIND.get(reason)
    return bool(kind) and _said(f"{scope[1]}-{kind}")


def _said(slot: str) -> bool:
    """A muted reason was already reported in this session; mark if not yet."""
    mark = STATE / f"said-{slot}"
    if _is_file(mark):
        return True
    with contextlib.suppress(OSError):
        STATE.mkdir(parents=True, exist_ok=True)
        mark.write_text("1")
    return False


def _runner(repo: Path) -> list[str] | None:
    """What to run the chosen tests with: the project command or the engine runner.

    Empty — nothing to run with. None — a command is declared but does not parse (unpaired quote):
    this is not
    "nothing to run with" but a broken setting, and it must be reported in its own words.
    """
    command = _command(repo, "test_command")
    if command is None or command:
        return command
    engine = _engine_runner(repo)
    return engine if _is_file(Path(engine[1])) else []


def _engine_runner(repo: Path) -> list[str]:
    """The engine runner's command: the only one whose exit codes the gate reads beyond zero."""
    return ["bash", str(repo / "bin" / "retainer-suite.sh")]


def _command(repo: Path, key: str) -> list[str] | None:
    """A run command from the key: empty — not declared or declared `""`; None — does not parse.

    "Does not parse" covers both layers: a value the config reader cannot read (a quote of the
    file itself left open, a bare word, a multi-line string) and an unpaired quote inside the
    command. Read as "not declared", either would switch the runner off without a word.
    """
    declared = _cfg(repo, key)
    if not declared:
        raw = _cfg_line(_cfg_text(repo), key)
        return [] if raw is None or EMPTY_RE.match(raw.strip()) else None
    try:
        return shlex.split(declared)
    except ValueError:
        return None


def _run_suite(
    repo: Path,
    command: list[str],
    limit: int | None = None,
) -> tuple[int | None, str]:
    """Run a command within `limit` seconds. Code and output tail; NOT_RUN — it did not start.

    The code of a foreign command is not interpreted: non-zero is red. Each runner has its own code
    semantics, and declaring some of them "does not count" means passing a broken
    tool off as a passed check. No limit — the whole `SUITE_TIMEOUT`, read at the call; a limit
    spent before the start is an overrun at once, red like any other.
    """
    budget = SUITE_TIMEOUT if limit is None else limit
    # Both caps, one value: a current runner gives up and runs nothing, a runner copy older than
    # the give-up still ends its wait as a run instead of queueing past the ceiling.
    wait = str(budget // SLOT_SHARE)
    try:
        done = subprocess.run(
            command,
            cwd=str(repo),
            env={**os.environ, "SUITE_SLOT_GIVEUP": wait, "SUITE_SLOT_WAIT": wait},
            capture_output=True,
            text=True,
            timeout=budget,
            check=False,
        )
    except subprocess.TimeoutExpired:
        # A hung run is red: it happened and overran, rather than "did not start".
        return (1, "the run did not fit in the allotted time")
    except (OSError, ValueError, subprocess.SubprocessError):
        # ValueError arrives from the launch seam itself: a command containing a NUL byte is not
        # passed to the process. This is "the runner did not start", not a hook crash — the gate
        # must
        # state a verdict, not vanish.
        return (NOT_RUN, "")
    return (done.returncode, (done.stdout or "") + (done.stderr or ""))


def _scope(event: Event) -> Scope | None:
    """What to check on a turn: the repository, budget slot, tests, code edits.

    None — no gate on this turn at all: outside a repository, under the owner's key, with the
    refusal
    budget spent. An empty match does not belong here: `_judge` speaks about it.
    """
    repo = _tree(event)
    # The owner's key is the same PATH as the guard's: one door, not a second. Only a FILE is
    # recognized,
    # while an unreadable path reads as "no key" and the gate works: else a closed dir becomes
    # a way to lift the gate. With the guard the forms diverge — it judges the path's mtime, and a
    # dir under
    # this name opens the key for it; reconciling the forms remains a task.
    if repo is None or _is_file(repo / UNLOCK):
        return None
    slot = _slot(event)
    if event.get(REENTRY) and _budget(slot) >= BUDGET_MAX:
        return None  # budget spent — yield, else the session jams for good
    changed = _mine(event, repo)
    if not changed:
        # Nothing of this session's changed: the end-to-end set is pulled by an edit, not by a
        # turn, else a clean tree pays for every such test on every turn.
        return (repo, slot, [], [], [])
    targets, reasons = _targets(repo, changed)
    return (repo, slot, targets, _code(changed), reasons)


def _last_line(said: str) -> str:
    """The last meaningful line of the message — where a question to the owner actually stands.

    A mark line does not count as the ending: it is service text. An ATTEMPT at the mark is dropped
    on the same footing, valid or not — otherwise a misspelled code or a missing dash would turn
    the line into the ending, and the failed form would free the turn instead of holding it.
    The ending is still the LAST line: a question followed by an ordinary line is not a handoff,
    and that is the deliberate edge of the rule, not a hole.
    """
    spoken = (line for line in said.splitlines() if line.strip())
    lines = [line for line in spoken if not HANDOFF_ATTEMPT.match(line)]
    return lines[-1] if lines else ""


def _asks(said: str) -> bool:
    """Does the message end by handing the work out?

    Two forms, both measured on the corpus: a question closing the last line, and a wait form
    addressed to the owner in the tail. A question EARLIER in the message is not one — a report
    that names an open fork and then goes on working is not a handoff. A `?` inside a token is not
    one either: a tracker link and a pasted regex carry it without asking anything.
    """
    asked = bool(ASKED.search(_last_line(said)))
    return asked or bool(WAIT_FORMS.search(said[-HANDOFF_TAIL:]))


def _declared(said: str) -> bool:
    """Is the handoff declared by a mark with a code from the registry?

    A self-declaration, like `review-sha` and the complexity line: what is checked is the
    presence, the form and the code, never the truth of the ground. A code outside the registry
    does not count — otherwise any word after the colon would open the door.

    The mark covers the WHOLE turn, wherever in the message it stands: one ground per turn, as with
    `review-sha` on a commit. A second, unrelated question later in the same turn is freed by it —
    a declared edge, not an oversight.
    """
    codes = (found.group(1) for found in HANDOFF_MARK.finditer(said))
    return any(code in HANDOFF_CODES for code in codes)


@functools.cache
def _state_read(session: str, words: tuple[str, ...]) -> str:
    """One answer of the state reader, under the given session; empty on any failure.

    Memoised for the invocation: both judges ask the same questions on one boundary.
    """
    command = _engine(STATE_SCRIPT)
    if not _is_file(Path(command[1])):
        return ""
    env = _unseamed()
    if session:
        env["CLAUDE_CODE_SESSION_ID"] = session
    return _read([*command, *words], STATE_TIMEOUT, env)


def _marker(event: Event, repo: Path, name: str) -> str:
    """The digits of the session's own marker in this tree; empty when it holds none."""
    return _state_read(_session(event), ("get", name, str(repo)))


def _confirmed(event: Event, repo: Path) -> str:
    """The session's task whose boundary is behind it — its plan was checked; empty otherwise."""
    task = _marker(event, repo, "active-issue")
    checked = _marker(event, repo, "plan-checked") if task else ""
    return task if task and checked == task else ""


def _grounded(event: Event, repo: Path) -> bool:
    """Is the turn's handoff declared by a ground that still holds?

    `boundary` alone holds only while the boundary is open: once the session's task has a checked
    plan, intake is behind it. The markers are read only for that one case, so an ordinary turn
    pays no subprocess.
    """
    said = str(event.get("last_assistant_message") or "")
    if not _declared(said):
        return False
    codes = {found.group(1) for found in HANDOFF_MARK.finditer(said)} & HANDOFF_CODES
    return codes != {SPENT_CODE} or not _confirmed(event, repo)


def _policy(repo: Path) -> str | None:
    """The effective policy of the question gate; None — the resolver could not be read.

    The engine root is taken from the hook file, not from the checked tree: the resolver is the
    engine's, while the project only carries the config it reads.
    """
    command = _engine(POLICY_SCRIPT)
    if not _is_file(Path(command[1])):
        return None
    try:
        done = subprocess.run(
            [*command, POLICY_STEP],
            cwd=str(repo),
            capture_output=True,
            text=True,
            timeout=POLICY_TIMEOUT,
            check=False,
        )
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    answer = done.stdout.strip()
    return answer if done.returncode == 0 and answer in {"auto", "off"} else None


def _handed(event: Event, repo: Path) -> bool:
    """Did THIS turn hand work out while there is work in the tree or a task in the session?

    Uncommitted code edits live until the commit. A clean tree is judged too while the session has
    a task of its own: grooming, a plan and a role run leave no edits, and a stop there is a stop.
    With no task the session is between tasks, and a turn that only answers the owner is free.
    """
    said = str(event.get("last_assistant_message") or "")
    if not said or not _asks(said) or _grounded(event, repo):
        return False
    if _code(_mine(event, repo)):
        return True
    return bool(_marker(event, repo, "active-issue"))


def _exempt(event: Event, repo: Path) -> bool:
    """Is the turn freed before any judging at all?

    The owner's key lifts this judge as it lifts the whole gate, and a turn that handed nothing out
    is not its business. Both checks are cheap and stand before the resolver subprocess.
    """
    if _is_file(repo / UNLOCK):
        return True
    return not _handed(event, repo)


def _handoff(event: Event) -> tuple[bool, str]:
    """The judge of the turn boundary: was the refusal written, and what is there to say besides.

    True — the refusal is on stdout and the turn is over: the suite does not run, and a red run is
    judged by the next turn. The two exemptions of `_scope` are checked here as well, because the
    judge stands before it: without a repository the tree state cannot be read at all, and the
    owner's key lifts the whole gate, this judge included.
    """
    repo = _tree(event)
    if repo is None or _exempt(event, repo):
        return (False, "")
    policy = _policy(repo)
    if policy is None:
        return (False, BAD_POLICY)
    slot = HANDOFF_SLOT.format(_slot(event))
    repeat = bool(event.get(REENTRY))
    if policy != "off" or (repeat and _budget(slot) >= BUDGET_MAX):
        return (False, "")  # budget spent — yield, else the session jams for good
    if repeat:
        # Counted on RE-ASKS only: spending it on fresh turns too would make the limit cumulative
        # per session — three refusals anywhere and the judge yields for the rest of it.
        _budget(slot, spend=True)
    refusal = {"decision": "block", "reason": _refusal(event, repo)}
    sys.stdout.write(json.dumps(refusal, ensure_ascii=False))
    return (True, "")


def _refusal(event: Event, repo: Path) -> str:
    """The handoff refusal; once the boundary is confirmed it no longer offers `boundary`."""
    task = _confirmed(event, repo)
    return BOUNDARY_SPENT.format(task) if task else HANDOFF_REFUSAL


# ── the route of the task: a hint at the boundary, and the judge of standing still ─────────────
# The route does NOT travel as a `reason`. Three filters stand between that list and
# stdout and all three are the blindness this hint removes: `loud = not scope[2]` drops
# it before `_say` on any turn where tests matched, the `fresh` comprehension is gated on
# `scope[3]` — uncommitted code edits — and what survives is muted once per session. The
# route is wanted on every boundary that MOVED, and most of all on a clean tree between steps,
# so it is joined into the text both channels carry; `_fresh` drops it on a repeat.
ROUTE_SCRIPT = "retainer-route.sh"
ROUTE_SEAM = "RETAINER_ROUTE_"
ROUTE_HEAD = "route #"
ROUTE_GATE = " \u00b7 gate "
# Spent in the same invocation as POLICY_TIMEOUT and SUITE_TIMEOUT, and together they must
# stay under the hook's own 600 s. A hint is worth seconds: on a timeout the turn says
# nothing about the route and loses nothing else.
ROUTE_TIMEOUT = 15
# A local git read is the hook's cheapest call, but a ceiling it does have: a hung repository must
# cost the hint, not the turn.
#
# The NAMED ceilings of one invocation are SUITE_TIMEOUT, ROUTE_TIMEOUT, POLICY_TIMEOUT and this
# one, and 540 + 15 + 10 + 10 sits under the hook's own 600 s. That sum is not an upper bound and
# must not be read as one: `_policy` can be paid twice on a boundary both judges reach, and `_repo`
# and `_changed` carry no ceiling at all — local reads, deliberately uncapped, because a ceiling on
# them would turn an ordinary slow disk into a lost refusal.
#
# A tracker that HANGS, rather than refusing fast, is paid for by the hint and not by the turn: the
# route's own inner curl ceilings exceed ROUTE_TIMEOUT, so the subprocess is cut and the boundary
# says nothing about the route. `NOT CHECKED` is the answer for a tracker that ANSWERS badly; a
# hanging one costs silence, and that is the deliberate edge.
GIT_TIMEOUT = 10
# A step may legitimately take many turns — `code` does. What is not legitimate is a
# boundary where NOTHING moved: the same route step, the same head, the same changed files.
STANDSTILL = "standstill-"
# Three, not two: a turn spent reading moves nothing and must not read as standing still.
# defer: standstill fires on the third identical boundary, upgrade: counting the turn's tools
STANDSTILL_REPEATS = 3
# Its own budget, spent on RE-ASKS only for the reason the handoff judge spends its own that
# way: a cumulative limit would answer three times in a session that needed thirty pokes.
STANDSTILL_ASKS = 2
STANDSTILL_ASK = (
    "This turn boundary moved nothing: the route step, the head and the changed files are"
    " what they were {} boundaries ago. Standing still is not a step.\n\n{}\n\n"
    "Answer with one of two things, in this turn:\n"
    "  - the next concrete action on that step, taken now; or\n"
    "  - the ground, on its own line: handoff: <code> - <what exactly is blocked>\n"
    "A code outside the registry is not a ground: {}.\n\n" + ASK_TOOL
)
STANDSTILL_CODES = "destructive, owner-key, native-deny, self-approval, boundary, pointless"
# Once the session's task has a checked plan, `boundary` is spent and is not offered back.
STANDSTILL_CODES_SPENT = "destructive, owner-key, native-deny, self-approval, pointless"
# The slot of the last boundary fingerprint the route filter saw, per session.
ROUTE_SAID = "route-said-"


def _read(command: list[str], limit: int, env: dict[str, str]) -> str:
    """Stripped stdout of a command; empty on any failure or a non-zero exit.

    One home for the two reads the route needs, both of which must fail into silence: a
    hint that broke cannot be allowed to cost a turn.
    """
    try:
        done = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=limit,
            check=False,
            env=env,
        )
    except (OSError, ValueError, subprocess.SubprocessError):
        return ""
    if done.returncode != 0:
        return ""
    return done.stdout.strip()


def _unseamed() -> dict[str, str]:
    """The environment without the route command's test seams.

    The step is the first component of the standstill fingerprint, so a variable the agent
    can set must not reach the route: this file's rule is that only the owner's key lifts
    anything. The seams stay for the route script's own corpus, where nothing refuses, and
    the corpus of THIS hook substitutes a script in its fixture tree instead.
    """
    kept = {}
    for name, holds in os.environ.items():
        if not name.startswith(ROUTE_SEAM):
            kept[name] = holds
    return kept


def _route(repo: str, session: str) -> str:
    """The route text for this tree; empty when there is nothing to say.

    Read ONCE per invocation, in `main`, and carried in the scope from there: the standstill
    judge and the single write both want it, and two subprocesses would pay twice against the
    timeout budget shared with the suite. Exit code 3 is the command's own way of saying "no
    active task", and that is silence here as well.
    """
    # The ENGINE root, from this file — not the checked tree. A project laid out by the engine has
    # no `bin/` of its own and reaches engine commands through the plugin root, so a lookup in the
    # project would find nothing in every consumer and leave the mechanism alive only in the
    # engine's own repository. The resolver next door is resolved the same way, and the route takes
    # the project directory as its argument instead.
    command = _engine(ROUTE_SCRIPT)
    if not _is_file(Path(command[1])):
        return ""
    env = _unseamed()
    # The task marker is per session: the event names the session, inheritance may not.
    if session:
        env["CLAUDE_CODE_SESSION_ID"] = session
    return _read([*command, repo, "--line"], ROUTE_TIMEOUT, env)


def _spoken(event: Event) -> tuple[Path | None, str, str]:
    """The repository, its route and the boundary fingerprint — all resolved ONCE per turn.

    Returned together because several readers want them and each costs a subprocess: the
    standstill judge reads the fingerprint, the route filter reads it too, and the single write
    and the lone path read the route. No route — no fingerprint, and no slot is written for it.
    """
    repo = _unlocked(event)
    if repo is None:
        return (None, "", "")
    route = _route(str(repo), _session(event))
    if not route:
        return (repo, "", "")
    return (repo, route, _boundary(repo, route))


def _stored(slot: Path) -> tuple[str, str]:
    """The count and the fingerprint a slot holds; two empty strings when it holds neither."""
    was = ""
    with contextlib.suppress(OSError):
        was = slot.read_text()
    count, _, kept = was.partition("\n")
    return (count, kept.strip())


def _again(count: str) -> int:
    """One more than a stored count, and 1 when what was stored is not a number."""
    try:
        return int(count) + 1
    except ValueError:
        return 1


def _seen(name: str, mark: str) -> int:
    """How many boundaries in a row carried this fingerprint, counting this one.

    Stored beside the refusal budget and split by session for the same reason: a fingerprint
    shared between sessions would read one session's standstill as another's. A write that
    failed costs the count, not the turn.
    """
    slot = STATE / name
    held = _stored(slot)
    seen = _again(held[0]) if held[1] == mark else 1
    with contextlib.suppress(OSError):
        STATE.mkdir(parents=True, exist_ok=True)
        slot.write_text(f"{seen}\n{mark}")
    return seen


def _step(route: str) -> str:
    """The step line of the route without its gate and run.

    Those two move when a resolver changes while the work stands still, so they are not part
    of what tells one boundary from another.
    """
    heads = (said for said in route.splitlines() if said.startswith(ROUTE_HEAD))
    return next(heads, "").split(ROUTE_GATE)[0]


def _stamp(repo: Path, path: str) -> str:
    """A changed path with its size and modification time.

    The list of NAMES alone was identical across three turns of editing one file — the most
    ordinary shape of work there is — so the judge would have asked why it stopped while it
    was writing.
    """
    marks = ""
    with contextlib.suppress(OSError, ValueError):
        stat_of = (repo / path).stat()
        marks = f"{stat_of.st_size}:{stat_of.st_mtime_ns}"
    return f"{path}@{marks}"


def _boundary(repo: Path, route: str) -> str:
    """What this boundary looks like: the route step, the head, and the changed paths."""
    reading = [*GIT, str(repo), "rev-parse", "HEAD"]
    head = _read(reading, GIT_TIMEOUT, _unseamed())
    moved = [_stamp(repo, path) for path in sorted(_changed(repo))]
    return "|".join((_step(route), head, ",".join(moved)))


def _ask(event: Event, slot: str, route: str) -> bool:
    """Spend one ask and write the question; False when the budget is already spent."""
    asks = f"{slot}-asks"
    repeat = bool(event.get(REENTRY))
    if repeat and _budget(asks) >= STANDSTILL_ASKS:
        return False  # budget spent — yield, else the session jams for good
    if repeat:
        _budget(asks, spend=True)
    # The ask IS the event: the count starts over, so one episode costs at most the budget
    # and a later one starts whole.
    _seen(slot, "")
    ask = STANDSTILL_ASK.format(STANDSTILL_REPEATS, route, _ask_codes(event))
    said = {"decision": "block", "reason": ask}
    sys.stdout.write(json.dumps(said, ensure_ascii=False))
    return True


def _ask_codes(event: Event) -> str:
    """The codes the standstill ask offers: `boundary` only while the boundary is still open."""
    repo = _tree(event)
    spent = repo is not None and bool(_confirmed(event, repo))
    return STANDSTILL_CODES_SPENT if spent else STANDSTILL_CODES


def _standstill(event: Event, found: tuple[Path | None, str, str]) -> bool:
    """Did this boundary move nothing, and is that worth one question?

    True — the question is on stdout and the turn is over: the suite does not run, and a red
    run is judged by the next turn. It stands in `main` AFTER the handoff judge released the
    turn, so one boundary never writes twice, and it keeps that judge's exemptions: without a
    repository there is no boundary to fingerprint, the owner's key lifts the whole gate, and
    a turn that already declared its ground has answered before being asked. An empty route —
    no active task, or a broken hint — is no subject for judgement at all.
    """
    repo, route, mark = found
    if repo is None or not route:
        return False
    if _grounded(event, repo):
        return False
    slot = STANDSTILL + _slot(event)
    if _seen(slot, mark) < STANDSTILL_REPEATS:
        return False
    # Asked AFTER the fingerprint, so an ordinary boundary pays no subprocess for it. The judge
    # fires only where questions to the owner are forbidden: where they are allowed a human is at
    # the terminal and does the poking, and a design conversation over a tree with an active task
    # would otherwise be blocked every third turn. A broken setting judges nothing.
    if _policy(repo) != "off":
        return False
    return _ask(event, slot, route)


def _fresh(event: Event, found: tuple[Path | None, str, str]) -> str:
    """The route when this boundary's fingerprint differs from the last one; empty on a repeat.

    The last one seen is the last boundary both judges released in this session: a standstill
    question or a handoff refusal ends the turn before this filter. The judges themselves take the
    route unfiltered — the standstill question still names the step.
    """
    route, mark = found[1], found[2]
    if not mark:
        return route
    if _seen(ROUTE_SAID + _slot(event), mark) > 1:
        return ""
    return route


def _unlocked(event: Event) -> Path | None:
    """The repository whose route may be spoken — None where this hook does nothing at all.

    Not every absent scope is the same: a spent refusal budget leaves a tree with a task in
    it, while the owner's key is a deliberate lift of everything here.
    """
    repo = _tree(event)
    if repo is None or _is_file(repo / UNLOCK):
        return None
    return repo


def _lone(note: str, route: str) -> int:
    """Say the note and the route when the gate itself has nothing to check — or stay silent.

    With no scope there is no second write to clash with, and the note is the only thing said this
    turn. Without this the broken setting vanishes exactly in a long session, where the red-run
    budget is spent and the judge is the only one still working. The route goes out here
    for the same reason: `_scope` returns None with the budget spent, which is a long run,
    where knowing the next step is worth most. Outside a repository and under the owner's
    key the route arrives empty and this stays silent, deliberately.
    """
    text = PARAGRAPH.join([part for part in (note, route) if part])
    if text:
        said = {
            "systemMessage": text,
            "hookSpecificOutput": {"hookEventName": "Stop", "additionalContext": text},
        }
        sys.stdout.write(json.dumps(said, ensure_ascii=False))
    return 0


def _noted(scope: Scope, note: str) -> Scope:
    """The same scope with one more reason: everything said in a turn goes out as ONE object."""
    reasons = [*scope[4], note]
    return (*scope[:4], reasons)


def main() -> int:
    """Stop hook: "done" on a red run does not pass."""
    try:
        event = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return 0
    refused, note = _handoff(event)
    if refused:
        return 0
    # AFTER the handoff judge released the turn, never beside it: both judges can meet on
    # one boundary, and two writes to stdout read as invalid JSON as a whole — both
    # refusals would be lost with the budgets already charged.
    found = _spoken(event)
    if _standstill(event, found):
        return 0
    # After both judges of the boundary, never before them: a question turn without a done word is
    # still theirs to read. Only the runs wait for a turn that claims done.
    scope = _scope(event) if _claims_done(event) else None
    if scope is None:
        return _lone(note, _fresh(event, found))
    return _judge(_noted(scope, note) if note else scope, _fresh(event, found))


def _judge(scope: Scope, route: str) -> int:
    """Run the lint, then the matched tests; what is missing or broken is said, not kept silent.

    Everything said in a turn goes out as ONE object. Two consecutive `json.dumps` to stdout read
    as
    invalid JSON as a whole: the harness takes the output for plain text, and the turn refusal is
    lost — while
    the budget has already been charged. So the write here is single, and the layers only assemble
    fields.
    """
    lint = _lint(scope)
    tests = _tests(scope, lint[2])
    heard = _heard(scope) + lint[0] + tests[0]
    return _close(scope, heard, route, [tests[1], lint[1]])


def _heard(scope: Scope) -> list[str]:
    """Matching reasons said on this turn: all of them with no targets, else the loud ones.

    A reason sounds either when there is nothing to match or when it must sound on any outcome:
    a broken setting and a target dropped by weight. Otherwise the guarantee holds only in a
    project without end-to-end and doc tests — where they exist, the target list is never empty,
    and the setting refusal vanishes exactly in the project where the mirror is being configured.
    """
    loud = not scope[2]
    return [reason for reason in scope[4] if loud or reason in ALWAYS_SAID]


def _lint(scope: Scope) -> tuple[list[str], str, int]:
    """Lint run of a turn with code edits: its reasons, its red part, and the seconds left.

    The lint runs on any code edit, whether or not a test answers it, since its subject is the
    code, not a test map. It goes first and the tests get what is left, so the two stay inside
    one ceiling.
    """
    command = _command(scope[0], "lint_command") if scope[3] else []
    if command is None:
        return ([BAD_LINT], "", SUITE_TIMEOUT)
    if not command:
        return ([], "", SUITE_TIMEOUT)
    code, output, left = _timed(scope[0], command)
    if code == NOT_RUN:
        return ([LINT_NOT_STARTED], "", left)
    return ([], _red(code, "The lint command (`lint_command`) is red:", output), left)


def _timed(repo: Path, command: list[str]) -> tuple[int | None, str, int]:
    """A run within the whole ceiling, with the whole seconds of it left afterwards."""
    began = os.times().elapsed
    code, output = _run_suite(repo, command)
    # Whole seconds, rounded up: the tests get no more than is truly left.
    spent = int(os.times().elapsed - began) + 1
    return (code, output, SUITE_TIMEOUT - spent)


def _tests(scope: Scope, left: int) -> tuple[list[str], str]:
    """Test run of the turn's targets within `left` seconds: its reasons and its red part."""
    if not scope[2]:
        return ([], "")
    runner = _runner(scope[0])
    if not runner:
        return ([BAD_COMMAND if runner is None else NO_RUNNER], "")
    command = [*runner, *scope[2]]
    code, output = _run_suite(scope[0], command, left)
    if code == NOT_RUN:
        return ([NOT_STARTED], "")
    if code == SLOTS_BUSY_CODE and runner == _engine_runner(scope[0]):
        return ([SLOTS_BUSY], "")
    named = ", ".join(scope[2])
    return ([], _red(code, f"Tests matched to the edits: {named}", output))


def _red(code: int | None, head: str, output: str) -> str:
    """The red part of a run: its head and the tail of its output; empty — the run is green."""
    return PARAGRAPH.join((head, output[-TAIL_BYTES:])) if code else ""


def _close(scope: Scope, reasons: list[str], route: str, red: list[str]) -> int:
    """The turn's outcome: a refusal when any run is red, else only what is to be said."""
    parts = [part for part in red if part]
    if not parts:
        return _say(scope, reasons, route)
    _budget(scope[1], spend=True)
    return _say(scope, reasons, route, _refuse(parts))


def _say(
    scope: Scope,
    reasons: list[str],
    route: str,
    refusal: dict[str, object] | None = None,
) -> int:
    """The single write to stdout per turn — and the only place where the session mark is set.

    Reasons ACCUMULATE rather than overwrite each other: their message fields are identical, and
    merging
    dicts left one of two reasons — the second. Yet "said" counted for both, because
    the mark was set by whoever assembled the fields, not by whoever printed. A single broken
    setting
    thus vanished for good: the slot burnt, no word said.
    """
    said: dict[str, object] = dict(refusal or {})
    # The "once per session" mark is set HERE, where it is known what was said: while the text
    # assembler set it,
    # the slot burnt even on a turn where what was said did not reach the output. A turn without
    # code
    # edits is silent entirely — the mark is not touched on it, else the session's only word burns
    # where there was nothing to say. The one exception is a skipped run: a document-only turn
    # has tests too, and their skip must not read as green, so that turn sets the skip's mark.
    fresh = [SLOTS_BUSY] if SLOTS_BUSY in reasons else []
    if scope[3]:
        fresh = [reason for reason in reasons if _kept(scope, reason)]
    # A skip goes to the human on every turn and to the agent once per session: the agent channel
    # continues the turn, so a skip said there on every Stop re-prompts an idle session forever.
    heard = fresh
    if SLOTS_BUSY in fresh and _mute(scope, SLOTS_BUSY):
        heard = [reason for reason in fresh if reason != SLOTS_BUSY]
    # The route is joined HERE, after the reasons and outside their guard: it is said on
    # every boundary that moved, including a clean-tree turn where `fresh` is empty by
    # construction, and it goes out in the same write, because two writes would lose the turn
    # refusal. A repeat arrives here with the route already empty.
    text = _channel(scope, fresh, route)
    told = _channel(scope, heard, route)
    if text:
        said["systemMessage"] = text
    if told:
        said["hookSpecificOutput"] = {
            "hookEventName": "Stop",
            "additionalContext": told,
        }
    if said:
        sys.stdout.write(json.dumps(said, ensure_ascii=False))
    return 0


def _kept(scope: Scope, reason: str) -> bool:
    """A reason said to the human on a code turn: a busy-slots skip always, the rest unless muted.

    The skip goes first so `_mute` is not called for it here: `_mute` sets the mark, and the
    mark of the skip belongs to the agent channel.
    """
    return reason == SLOTS_BUSY or not _mute(scope, reason)


def _channel(scope: Scope, reasons: list[str], route: str) -> str:
    """The text of one channel: the message about its reasons, then the route."""
    return PARAGRAPH.join(part for part in (_message(scope, reasons), route) if part)


def _claims_silence(reason: str) -> bool:
    """The reason itself says no test ran — no need to repeat it a second time."""
    return reason.startswith(RAN_NOTHING.rstrip("."))


def _dotted(reason: str) -> str:
    """A reason as a sentence: the trailing period is put once and in one place."""
    return reason if reason.endswith(".") else f"{reason}."


def _message(scope: Scope, reasons: list[str]) -> str:
    """Text about all reasons of the turn; empty — nothing to say or they were already said.

    There are TWO addressees, with different channels: the human reads `systemMessage`, the agent
    only
    `additionalContext`. `systemMessage` alone is not enough: in an autonomous run there is no
    human at
    the terminal, and what is said only to them is said to no one. Neither of them blocks the turn.
    The one exception is a repeat skip on busy slots, said to the human alone (`_say`).

    There is NO muting here: "once per session" lives in `_say`, where it is known that what was
    said will reach
    the output. Only already-selected reasons arrive here.
    """
    if not reasons:
        return ""
    dotted = [_dotted(reason) for reason in reasons]
    already = any(_claims_silence(reason) for reason in reasons)
    if not scope[2] and not already:
        # No targets at all — say so directly. Benign reasons carry that fact in themselves, while
        # the setup ones did not, and "the mirror does not parse" sounded the same where the run
        # happened on other targets and where nothing ran.
        dotted.insert(0, RAN_NOTHING)
    text = " ".join(dotted)
    silent = all(reason in NO_HINT for reason in reasons)
    return text if silent else f"{text} {HINT}"


def _refuse(red: list[str]) -> dict[str, object]:
    """Turn refusal fields: the reason goes to the agent in the same object as the messages.

    Each red run brings its own part — the tests with their list, the lint with its output — so a
    red lint alone does not print an empty test list.
    """
    told = PARAGRAPH.join(red)
    # A Stop refusal is delivered as JSON on stdout: this event's protocol differs from the
    # guard's,
    # where a call is cancelled by exit code 2. Copying the guard's code there means not working.
    reason = (
        f"Done was declared on a red run. {told}"
        '\n\nFix it and say "done" again. There is no bypass: only the owner\'s key lifts it'
        " (.retainer/unlock), as with the guard."
    )
    return {"decision": "block", "reason": reason}


if __name__ == "__main__":
    sys.exit(main())
