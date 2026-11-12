#!/usr/bin/env bash
# retainer: adding a new component leaves a trace of the complexity decision.
# complexity: keep, step 7 — the minimum that works: there is no step below, and the advisor by kind of work
# checks the file NAME, does not judge paths and does not read the trace at all.
#
#   retainer-complexity-trace.sh [project dir]
# exit 0 — there were targets, each has a trace · 1 — a new file without a trace
#      2 — usage OR THE CHECK IS NOT WORKING · 3 — no targets: nothing to compare against or no new files
#
# The rule "take the complexity budget before a new component" rested on the agent's memory: the tool-policy
# resolver knows only agents, the advisor has no standing on this, the gate did not judge the class.
# A complexity decision made in the head is indistinguishable from one not made — here it must leave
# a line in the file itself, as a deferred-simplification marker leaves one at the cut site.
#
# WHAT IS NOT JUDGED, named rather than forgotten:
#   * files already in the base — no retroactive obligation: only what is added is judged;
#   * files already in the tree of the commit that adopted the kit — the earliest commit in HEAD's history that
#     added anything under .retainer/. A long-lived branch shows work from before the kit as added against the
#     base; that work made no decision under a rule that did not exist yet. A path deleted since the adoption is
#     NOT covered: a file created there again is new work. Without such a commit (the kit is not tracked) or in
#     a shallow history (the earliest visible commit "adds" every file) there is no cutoff, and the output says so;
#   * rename and move: detection is enabled explicitly, the R letter in the diff filter is not taken;
#   * generated and foreign — migration dirs, environments, vendored trees, test and
#     documentation dirs (by path SEGMENT, not prefix: managed projects keep tests in
#     app/core/tests and search/tests, a prefix would not cover them);
#   * __init__.py WITHOUT code — only a docstring and imports: that is a package declaration, not a component, and
#     demanding a decision line in it teaches skipping the step. Content is parsed by the standard
#     library of the language the step runs in: a line-based heuristic of our own would part from the
#     language at the first multi-line literal, and what is not understood counts as code: skipping it
#     opens a hole. A facade package that HAS code (a service registry, registration on import)
#     is judged like the rest: an exemption by one name would be a hole the size of the mechanism;
#   * a non-regular file: a broken link and a link to a directory.
#
# An unreadable directory BETWEEN the root and the file gives "no targets", not a refusal: git stops seeing the file
# as added before the step reaches reading. The refusal rests on the check root and on the file itself.
#
# The exemption list is CLOSED: a project cannot add a segment of its own. Generated content outside this
# list (own generation dirs) will require the marker, and regeneration erases it — the project's only
# move is then to turn the step off with the rigor regulator. No extension point was added on purpose: a second
# registry of the same truth drifts from the first silently, and no need for one has been observed.
#
# WHAT THE CHECK DOES NOT KNOW: whether what is written in the trace is true. The trace is a self-declaration of the same class as a
# review record: it is checkable that the decision is named, and named in a parseable form, not that it is right.
# Judging the substance of the rationale means building an over-engineering detector, and that is the reviewer's job.
#
# THE CEILING, and it is double. On a long-lived branch the diff against the base takes in everything added since
# divergence, including others' work made after the kit came in; the project's rigor regulator lifts it. And in a
# tree where the base branch is not at hand — a fresh CI clone pulling one commit — the step is SILENT. It is
# silent aloud, naming the reason: "enabled" and "working" diverge here, and telling them apart must be possible.
set -uo pipefail
CFGLIB="$(cd "$(dirname "$0")" && pwd)/retainer-config.sh"   # before cd into the project: the script's path
[ -f "$CFGLIB" ] || {
  echo "✗ complexity decision trace: retainer-config.sh is not next to the script — the check is NOT working" >&2; exit 2; }
# shellcheck source=bin/retainer-config.sh
. "$CFGLIB"

DIR="${1:-.}"
[ -d "$DIR" ] || { echo "usage: retainer-complexity-trace.sh [project dir]" >&2; exit 2; }
cd "$DIR" || exit 2

git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "▶ complexity decision trace: not a git repository — nothing to count new files against"; exit 3; }

# The base comes from the kit's shared resolver: the repository itself declares the main branch name, so a
# project on `master` is judged too. Work from before the kit is kept out by the adoption cutoff below, not by
# failing to find the base.
#
# No base — the step is SILENT with the "no targets" code, it does not refuse: a refusal would give such a project a forever
# red gate, because the runner puts anything other than 0/1/3 into failures. It is silent aloud, naming
# the reason: the mechanism does not work on such a tree, and that must be visible.
BASE="$(retainer_base_ref .)"
[ -n "$BASE" ] || {
  echo "▶ complexity decision trace: no comparison base (the repository declares no main branch) — nothing to count new files against"
  exit 3; }

BASE="$BASE" python3 - <<'PY'
import ast
import os
import re
import subprocess
import sys

BASE = os.environ["BASE"]
SUFFIXES = (".py", ".sh")
# Path segments that do not count as a component: own-but-not-a-component, generated and foreign.
# The list is closed: a project that needs a segment of its own turns the step off wholesale with the rigor regulator —
# it has no extension point, and that is a decision, not an omission.
SKIP = frozenset((
    "tests", "test", "docs", "presets",          # own, but not a component
    "migrations",                                 # generated
    ".venv", "venv", "site-packages", "node_modules", "vendor",   # a foreign tree in the repository
))
# Parsing is done by python regex, not grep: grep implementations diverge on character classes over
# non-ASCII text, and the trace may carry it.
#
# The whitespace classes between the words of the form are HORIZONTAL: a plain `\s` matches a newline, i.e.
# it glues the marker to the next line of the file. There are three positions where this is distinguishable — after `complexity:`,
# after `step` and after the digit; indentation before the hash carries no contract, the line-start
# anchor holds it.
#
# The line must start with a hash: the marker is a comment. Quoted text on one line is cut off by this. A line with a hash INSIDE
# a multi-line literal or heredoc the discriminator cannot cut off and does not try to — that would cost
# parsing the syntax of two languages.
#
# No capture groups: nobody reads the step value and the rationale, the presence of the form is checked.
MARK = re.compile(
    r"^[ \t]*#.*complexity:[ \t]*keep,[ \t]*step[ \t]*[1-7][ \t]*(?:—|–|-)[ \t]*\S",
    re.M,
)
HOWTO = (
    "  The trace is a COMMENT line in the file itself, next to the header (in .py also a hash,\n"
    "  not a docstring):\n"
    "      # complexity: keep, step <1-7> — <what breaks if the component is absent>\n"
    "  The step is from the implementation-choice ladder of the complexity-budget skill: 1 not needed at all ·\n"
    "  2 already in the codebase · 3 stdlib does it · 4 native platform feature · 5 installed\n"
    "  dependency · 6 one line · 7 the minimum that works.\n"
    "  No need to stop and ask: whoever creates the component makes the decision and\n"
    "  records it in this very line. An invisible complexity decision equals one not made."
)


def git(*args):
    """Stdout of a git call. A non-zero exit is a refusal: an answer git did not give is not an empty answer."""
    done = subprocess.run(["git"] + list(args), capture_output=True, text=True, check=False)
    if done.returncode != 0:
        sys.stdout.write("✗ complexity decision trace: git %s failed — the check is NOT working\n" % args[0])
        sys.exit(2)
    return done.stdout


def added():
    """Files added against the base, plus untracked ones.

    Ignored files are filtered by git's own `--exclude-standard`, not by the exclusion list below: built and
    temporary copies of code live exactly there.

    The separator is a NUL byte, diff paths are relative to the working dir: without the first a non-ASCII name
    arrives escaped and quoted, without the second the diff prints the path from the repository root, while
    it is opened from the working dir.
    """
    shown = git("diff", "-M", "--diff-filter=A", "--name-only", "--relative", "-z", BASE)
    fresh = git("ls-files", "--others", "--exclude-standard", "-z")
    rows = shown.split("\0") + fresh.split("\0")
    return sorted({row for row in rows if row})


def adoption():
    """(commit that adopted the kit, None) or (None, why there is no cutoff).

    The pathspec is anchored at the top (`:/`): the step may run from a subdirectory, and .retainer/ lives at the root.
    Anything but a plain "false" from the shallow probe counts as shallow: there the earliest visible commit
    shows every file as added, and taking it for the adoption would hide every committed file.
    """
    if git("rev-parse", "--is-shallow-repository").strip() != "false":
        return None, "shallow history — the kit adoption is not looked up, every file added against the base is judged"
    commits = git("log", "--diff-filter=A", "--format=%H", "--", ":/.retainer").split()
    if not commits:
        return None, "no commit adds .retainer/ — no adoption cutoff, every file added against the base is judged"
    return commits[-1], None


def before_kit(commit):
    """Paths from before the kit: in the adoption commit's tree and not deleted since.

    Both lists are relative to the working dir, like the diff in added(). Renames are off in the deletion log:
    a file moved away leaves its old path free, and a new file there is new work, as after a deletion.
    """
    tree = {row for row in git("ls-tree", "-r", "-z", "--name-only", commit).split("\0") if row}
    gone = git("log", "--no-renames", "--diff-filter=D", "--name-only", "--relative", "--format=", "-z",
               commit + "..HEAD").split("\0")
    return tree - {row for row in gone if row}


def package_only(body):
    """A package declaration without code: only a docstring and imports?

    A file that does not parse (broken syntax, not python) answers "has code".
    """
    try:
        tree = ast.parse(body)
    except (SyntaxError, ValueError):
        return False
    for node in tree.body:
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            continue
        if isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant):
            continue                 # module docstring and bare string literals
        return False
    return True


def read(rel):
    """File content or None. None means the check is not working, not "no trace"."""
    try:
        with open(rel, encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return None


# The filter order follows what is known at each step: extension and segments are visible from the name, file
# kind from stat, the content of a package declaration only from the body.
ADOPTED, NO_CUTOFF = adoption()
BEFORE_KIT = before_kit(ADOPTED) if ADOPTED else set()
targets = []
unread = []
older = 0
for rel in added():
    if not rel.endswith(SUFFIXES) or set(rel.lower().split("/")) & SKIP:
        continue
    if rel in BEFORE_KIT:
        older += 1
        continue
    # The path is named but absent on disk: nothing to judge with, and that is a refusal, not a skip.
    if not os.path.lexists(rel):
        unread.append(rel)
        continue
    if not os.path.isfile(rel):
        continue                     # a broken link and a link to a directory are not components
    body = read(rel)
    if body is None:
        unread.append(rel)
        continue
    if rel.endswith("__init__.py") and package_only(body):
        continue
    targets.append((rel, body))

if unread:
    sys.stdout.write("✗ complexity decision trace: diff files not read — the check is NOT working\n")
    for rel in unread:
        sys.stdout.write("    %s\n" % rel)
    sys.exit(2)

missing = [rel for rel, body in targets if not MARK.search(body)]
howto = []
if not targets:
    verdict, status = ["▶ complexity decision trace: no new components against %s — nothing to check" % BASE], 3
elif not missing:
    verdict, status = ["✔ all new components against %s have a complexity decision trace (%d)"
                       % (BASE, len(targets))], 0
else:
    verdict, status = ["✗ %s — new component without a complexity decision trace" % rel for rel in missing], 1
    howto = [HOWTO]
# What the cutoff did goes AFTER the verdict: the verdict stays the first line a summary reads.
if NO_CUTOFF:
    verdict.append("  " + NO_CUTOFF)
elif older:
    verdict.append("  %d file(s) already in the tree of the kit adoption %s are not judged" % (older, ADOPTED[:12]))
sys.stdout.write("\n".join(verdict + howto) + "\n")
sys.exit(status)
PY
