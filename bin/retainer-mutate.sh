#!/usr/bin/env bash
# retainer: mutation probe of a task's edits — the strength of tests, not suite greenness.
#
#   retainer-mutate.sh [--base <ref>] [--max <N>]
# exit 0 — all mutants killed (or nothing to mutate, and that is said aloud)
#      1 — surviving mutants exist
#      2 — usage / not a git repo / no base for the diff
#
# A green suite proves the code does not crash. That a test guards ANYTHING is proven only by mutation:
# break the edit one piece at a time and see whether anything goes red. A surviving mutant is a place where
# the check checked not behavior but itself.
#
# A surviving mutant is NOT always a weak test. The second outcome: the code is unreachable, no test runs it, and
# the right answer there is "delete the branch", not "write a test". The probe tells them apart by poisoning the line:
# a deliberately exploding expression is put into the same line. The poisoned mutant survived → nobody
# runs the line (unreachable code). Killed, while the semantic mutant survived → the line runs, but nobody
# checks its result (weak test).
#
# Boundaries: only the task's edits are mutated (diff against base), not the tree. Tests are not mutated —
# mutating a test proves nothing. Unmutable edits (comments, formatting) are named as
# a separate list, not skipped silently. The probe does not replace review: it is about test strength, not about
# the meaning of the code. Run it AFTER the final review edits — otherwise fragments go stale.
set -uo pipefail
# The PLUGIN tree (where the command runs from) — not to be confused with the tree under check below.
SELF="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=bin/retainer-config.sh
. "$SELF/bin/retainer-config.sh"

BASE=""
MAX="${RETAINER_MUTATE_MAX:-40}"
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 || exit 2 ;;
    --max)  MAX="${2:-}"; shift 2 || exit 2 ;;
    -h|--help) echo "usage: retainer-mutate.sh [--base <ref>] [--max <N>]"; exit 2 ;;
    *) echo "usage: retainer-mutate.sh [--base <ref>] [--max <N>]" >&2; exit 2 ;;
  esac
done
case "$MAX" in ''|*[!0-9]*) echo "--max expects a number" >&2; exit 2 ;; esac
# A target test's time limit, seconds. Zero would time out every run at once and kill every mutant.
TIMEOUT="${RETAINER_MUTATE_TIMEOUT:-300}"
[ "$TIMEOUT" -gt 0 ] 2>/dev/null || {
  echo "RETAINER_MUTATE_TIMEOUT expects whole seconds above zero" >&2; exit 2; }

# The tree under check is the one the command is called FROM, not where the script lies: commands are distributed by the plugin
# and called from a project by absolute path (`bash ~/retainer/bin/…`), so the script's location
# points at the plugin. A silent measurement of a foreign tree gives green by construction — "nothing to mutate"
# reads as "nothing to check".
TARGET="${RETAINER_MUTATE_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[ -n "$TARGET" ] || { echo "not a git repository: $PWD — nothing to mutate"; exit 2; }
git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "not a git repository: $TARGET — nothing to mutate"; exit 2; }

# Diff base: explicit → the box resolver (the repository itself declares the main branch name). Without a base the task
# is not separable from history, and the whole tree would have to be mutated — exactly what the boundaries forbid.
if [ -z "$BASE" ]; then
  BASE="$(retainer_base_ref "$TARGET")"
fi
[ -n "$BASE" ] || {
  echo "cannot determine the diff base: the repository did not declare a main branch — pass --base"; exit 2; }

TARGET="$TARGET" BASE="$BASE" MAXN="$MAX" TIMEOUT="$TIMEOUT" python3 - <<'PY'
import ast
import os
import re
import signal
import subprocess
import sys
from pathlib import Path

ROOT = Path(os.environ["TARGET"]).resolve()
BASE = os.environ["BASE"]
MAXN = int(os.environ["MAXN"])
TEST_TIMEOUT = int(os.environ["TIMEOUT"])

# Mutable extensions. Tests are excluded: mutating a test checks the test of the test, not the strength of a check.
SUFFIXES = (".py", ".sh")
SKIP_DIRS = ("tests/", "presets/")

# Semantic operators: one edit = one mutation. The regex looks for the FIRST occurrence in a line — the goal is not to
# enumerate all variants but to break the line's behavior minimally.
OPERATORS = (
    ("comparison ==→!=", re.compile(r"=="), "!="),
    ("comparison !=→==", re.compile(r"!="), "=="),
    ("threshold >=→>", re.compile(r">="), ">"),
    ("threshold <=→<", re.compile(r"<="), "<"),
    ("shell equality -eq→-ne", re.compile(r"\s-eq\s"), " -ne "),
    ("shell equality -ne→-eq", re.compile(r"\s-ne\s"), " -eq "),
    ("connective and→or", re.compile(r"\sand\s"), " or "),
    ("connective &&→||", re.compile(r"\s&&\s"), " || "),
    ("negation not removed", re.compile(r"\bnot\s+"), ""),
)
NUMBER = re.compile(r"(?<![\w.])(\d+)(?![\w.])")
# A file descriptor number is not a number: `2>/dev/null` → `3>/dev/null` stops silencing
# stderr, but the command works the same, and there is nothing to kill such a mutant with — a "noise silenced" test guards
# no behavior. Declaring such a line weakly covered would order work that checks nothing and spend
# the ceiling on it, crowding out real mutations.
# The form is narrow: a digit adjacent to a redirection on either side (`2>`, `2>>`, `2>&1`, `3< "$f"`) and
# right after descriptor duplication (`1>&2`, `0<&3`). A space around the sign leaves the number a number —
# `[ "$n" -gt 128 ]` and `--max 40` are still mutated.
DESCRIPTOR = re.compile(r"(?:\d+(?=[<>])|(?<=[<>]&)\d+)")
# Line poisoning: syntactically valid, but explodes at run time. Needed to tell
# a weak test from unreachable code.
POISON = {
    ".py": 'raise SystemExit("mutate-poison")',
    ".sh": '{ echo mutate-poison >&2; exit 97; }',
}
COMMENTS = re.compile(r"^\s*(#|\"\"\"|'''|$)")
# Nodes whose first body statement may be a docstring. A string literal ANYWHERE else is
# potentially a value, and mutating it is meaningful: we cut off exactly the docstring by definition.
DOCSTRING_OWNERS = (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)


def run(cmd, cwd=None):
    # errors="replace": the run output is needed for the verdict, not for byte-exact reproduction, and
    # strict decoding kills the probe on foreign garbage. A broken byte becomes �.
    return subprocess.run(cmd, cwd=str(cwd or ROOT), capture_output=True, text=True,
                          errors="replace", check=False)


def changed_lines():
    """{file: {line number: text}} from the added lines of the diff against the base."""
    out = run(["git", "diff", "--unified=0", BASE, "--", "*.py", "*.sh"])
    if out.returncode != 0:
        print("✗ git diff against %s failed — nothing to mutate" % BASE)
        sys.exit(2)
    files = {}
    path = None
    lineno = 0
    for row in out.stdout.splitlines():
        if row.startswith("+++ b/"):
            path = row[6:]
            continue
        hunk = re.match(r"^@@ -\S+ \+(\d+)", row)
        if hunk:
            lineno = int(hunk.group(1))
            continue
        if row.startswith("+") and not row.startswith("+++") and path:
            files.setdefault(path, {})[lineno] = row[1:]
            lineno += 1
    # A new file not yet added to the index is not visible in `git diff` at all. For the task it is the same
    # edit, and without it the probe on a fresh tool would say "nothing to mutate" — green for the
    # wrong reason. Ignored files are excluded by --exclude-standard.
    fresh = run(["git", "ls-files", "--others", "--exclude-standard", "*.py", "*.sh"])
    for rel in fresh.stdout.splitlines():
        rel = rel.strip()
        if not rel or rel in files:
            continue
        target = ROOT / rel
        if not target.is_file():
            continue
        body = target.read_text(encoding="utf-8").splitlines()
        files[rel] = {num: text for num, text in enumerate(body, 1)}
    return files


def mutants_for(text, suffix):
    """List of (description, new line) for one line. Empty — the line is unmutable."""
    found = []
    for name, pattern, repl in OPERATORS:
        if pattern.search(text):
            found.append((name, pattern.sub(repl, text, count=1)))
    descriptors = {fd.start() for fd in DESCRIPTOR.finditer(text)}
    hit = next((num for num in NUMBER.finditer(text) if num.start() not in descriptors), None)
    if hit:
        shifted = "%s%d%s" % (text[:hit.start()], int(hit.group(1)) + 1, text[hit.end():])
        found.append(("number %s→%d" % (hit.group(1), int(hit.group(1)) + 1), shifted))
    return found


def docstring_lines(text):
    """Line numbers occupied by DOCSTRINGS: they are documentation, not behavior.

    A mutant inside a docstring cannot be killed in principle — no test looks at the text of
    documentation — yet the probe counted it as surviving and advised "remove the branch". That is
    a false claim with a wrong recommendation, and every task that edits a documented
    function would arrive at review with a guaranteed red probe.

    Cannot parse (the mutant breaks syntax, the file is for another Python) — an empty set: skipping
    a line is more dangerous than creating an extra mutant, so the failure goes toward mutation.
    """
    try:
        tree = ast.parse(text)
    except (SyntaxError, ValueError):
        return set()
    spans = set()
    for node in ast.walk(tree):
        if not isinstance(node, DOCSTRING_OWNERS):
            continue
        first = node.body[0] if node.body else None
        if not isinstance(first, ast.Expr) or not isinstance(first.value, ast.Constant):
            continue
        if isinstance(first.value.value, str):
            spans.update(range(first.lineno, (first.end_lineno or first.lineno) + 1))
    return spans


# Heredoc opening: `<<'PY'`, `<<"PY"`, `<<PY`, `<<-PY`. The closing is a line with exactly the marker.
HEREDOC_OPEN = re.compile(r"<<-?[\'\"]?(\w+)[\'\"]?\s*$")


def heredoc_docstrings(text):
    """Docstring lines of python living in a bash heredoc.

    Without this the filter would cover eleven engine .py files and not the hundred shell scripts where the python
    lives: the engine's CLIs keep python in a heredoc on purpose. The first surviving mutant of this
    work turned out to be a docstring inside a heredoc — the very defect the filter exists to remove.

    A body that python does not parse (an ordinary shell heredoc, an awk program) yields no docstrings:
    `docstring_lines` returns an empty set, and the lines go to mutation as before.
    """
    lines = text.splitlines()
    spans = set()
    opened = None  # (closing marker, line number of the opening) or None outside a heredoc
    for idx, line in enumerate(lines, 1):
        if opened is None:
            hit = HEREDOC_OPEN.search(line)
            if hit:
                opened = (hit.group(1), idx)
        elif line.strip() == opened[0]:
            body = "\n".join(lines[opened[1]:idx - 1])
            spans.update(num + opened[1] for num in docstring_lines(body))
            opened = None
    return spans


def target_tests(rel):
    """Target tests — DYNAMICALLY: those that mention this path or its basename."""
    hits = set()
    stem = Path(rel).name
    for probe in (rel, stem):
        out = run(["grep", "-rl", probe, "tests"])
        for row in out.stdout.splitlines():
            if row.endswith(".sh"):
                hits.add(row)
    return sorted(hits)


timed_out = []


def run_test(test):
    """Runs one target test on the tree as it lies: "pass", "fail" or "timeout".

    Only the exit code is the verdict, so the output is discarded: a poisoned line makes bash
    print its own diagnostic, which may carry a truncated multibyte character, and no decoding
    can then break the probe. The test runs in its own process group, and a timeout kills the
    whole group: a mutant that loops the script under test leaves no process behind.
    """
    proc = subprocess.Popen(["bash", test], cwd=str(ROOT), stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            start_new_session=True)
    try:
        code = proc.wait(timeout=TEST_TIMEOUT)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
        return "timeout"
    return "pass" if code == 0 else "fail"


def tests_pass(tests, where):
    """True — all target tests are green (the mutant SURVIVED).

    A test past its time limit did not come back green: the mutant counts as killed, and `where`
    is named in the timeout list.
    """
    for test in tests:
        verdict = run_test(test)
        if verdict == "timeout":
            timed_out.append("%s (%s, over %d s)" % (where, test, TEST_TIMEOUT))
        if verdict != "pass":
            return False
    return True


def baseline(tests):
    """None when every target test passes on the unmutated tree, else why one does not.

    A test that fails or hangs on the original code would count every mutant as killed.
    """
    for test in tests:
        verdict = run_test(test)
        if verdict != "pass":
            return "%s gives %s on the unmutated tree" % (test, verdict)
    return None


def apply_line(path, lineno, text):
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    ending = "\n" if lines[lineno - 1].endswith("\n") else ""
    lines[lineno - 1] = text + ending
    path.write_text("".join(lines), encoding="utf-8")


changes = changed_lines()
skipped_dirs = []
no_test = []
unmeasured = []
not_mutable = []
survivors = []
killed = 0
budget = MAXN
truncated = False

# The tree is named aloud: a silent measurement of a foreign repository is indistinguishable from an honest "nothing to
# mutate".
print("── mutation probe of edits against %s in %s ──" % (BASE, ROOT))

for rel, lines in sorted(changes.items()):
    if any(rel.startswith(d) for d in SKIP_DIRS):
        skipped_dirs.append(rel)
        continue
    suffix = Path(rel).suffix
    if suffix not in SUFFIXES:
        continue
    path = ROOT / rel
    if not path.is_file():
        continue
    tests = target_tests(rel)
    if not tests:
        no_test.append(rel)
        continue
    broken = baseline(tests)
    if broken:
        unmeasured.append("%s (%s)" % (rel, broken))
        continue
    original = path.read_text(encoding="utf-8")
    docs = docstring_lines(original) if suffix == ".py" else heredoc_docstrings(original)
    file_killed = 0
    file_alive = 0
    try:
        for lineno, text in sorted(lines.items()):
            if lineno in docs:
                not_mutable.append("%s:%d (docstring — documentation, not behavior)" % (rel, lineno))
                continue
            if COMMENTS.match(text):
                not_mutable.append("%s:%d (comment or empty line)" % (rel, lineno))
                continue
            candidates = mutants_for(text, suffix)
            if not candidates:
                not_mutable.append("%s:%d (no applicable operator)" % (rel, lineno))
                continue
            if budget <= 0:
                truncated = True
                break
            # 1) poisoning: is the line executed at all
            indent = re.match(r"^\s*", text).group(0)
            apply_line(path, lineno, indent + POISON[suffix])
            reachable = not tests_pass(tests, "%s:%d poisoned line" % (rel, lineno))
            path.write_text(original, encoding="utf-8")
            budget -= 1
            if not reachable:
                survivors.append((rel, lineno, "the line is not executed by the tests",
                                  "UNREACHABLE CODE: do not add a test, remove the branch"))
                file_alive += 1
                continue
            # 2) semantic mutants: it runs — is the result checked
            for name, mutated in candidates:
                if budget <= 0:
                    truncated = True
                    break
                apply_line(path, lineno, mutated)
                alive = tests_pass(tests, "%s:%d %s" % (rel, lineno, name))
                path.write_text(original, encoding="utf-8")
                budget -= 1
                if alive:
                    survivors.append((rel, lineno, name,
                                      "WEAK TEST: the line runs, its result is not checked"))
                    file_alive += 1
                else:
                    killed += 1
                    file_killed += 1
    finally:
        if path.read_text(encoding="utf-8") != original:
            path.write_text(original, encoding="utf-8")
            print("  ⚠ %s restored after mutation (check git diff)" % rel)
    # What exactly was mutated and WITH WHAT it was checked — otherwise "killed N" does not say which edit it relates to.
    print("  · %s: killed %d, survived %d (target tests: %s)"
          % (rel, file_killed, file_alive, ", ".join(tests)))

if not_mutable:
    print("  · unmutable edits (named, not skipped silently):")
    for row in not_mutable:
        print("      %s" % row)
if timed_out:
    print("  · killed by timeout (a target test did not finish in its limit; a poisoned line"
          " counts as reached, not as a kill):")
    for row in timed_out:
        print("      %s" % row)
if skipped_dirs:
    print("  · not mutated by the boundary (tests and templates): %s" % ", ".join(skipped_dirs))
if no_test:
    print("  ⚠ edits without a target test — nothing to mutate with, the check was not run:")
    for row in no_test:
        print("      %s" % row)
if unmeasured:
    print("  ⚠ not measured — a target test does not pass on the unmutated tree, so no mutant"
          " can be told killed:")
    for row in unmeasured:
        print("      %s" % row)
if truncated:
    print("  ⚠ mutation ceiling reached (--max) — not all edits were checked")

for rel, lineno, what, verdict in survivors:
    print("  ✗ %s:%d — mutant survived (%s)" % (rel, lineno, what))
    print("      %s" % verdict)

print("TOTAL: killed %d, survived %d" % (killed, len(survivors)))
if survivors:
    sys.exit(1)
if killed == 0:
    print("  · there was nothing to mutate — this is NOT proof of test strength")
sys.exit(0)
PY
