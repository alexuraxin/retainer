#!/usr/bin/env bash
# retainer: reconciles the declared scope of a task with the actual one.
#
#   retainer-scope-check.sh <owner/repo> <task number> [--base <ref>]
# exit 0 — all new module-level names are declared in the task body
#      1 — there are undeclared names (listed)
#      2 — usage / no token / tracker did not answer / not a git repo (fail-closed: unknown != allowed)
#
# Task sprawl is not caught by a diff-boundary check: a change that removed a guard in seven forms
# touched EXACTLY the declared files, the scope grew inside them. But sprawl leaves a checkable
# trace — new module-level names that were not in the plan. Those are what we check: a name is in
# the diff but not named in the task body -> red.
#
# The ratchet is symmetric to the mutation probe: declaring in the task is possible at any time (the
# body is editable), quietly adding to the code is not.
#
# Boundaries: only MODULE-level names are checked (functions and constants), not local variables or
# function bodies — an internal edit of a declared function is not new scope. The check does not
# judge whether a name is appropriate and does not replace review.
set -uo pipefail
# The PLUGIN tree (where the command runs from) — not to be confused with the checked tree below.
SELF="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=bin/retainer-config.sh
. "$SELF/bin/retainer-config.sh"

REPO="${1:-}"; NUM="${2:-}"; shift 2 2>/dev/null || true
BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 || exit 2 ;;
    *) echo "usage: retainer-scope-check.sh <owner/repo> <task number> [--base <ref>]" >&2; exit 2 ;;
  esac
done
usage(){ echo "usage: retainer-scope-check.sh <owner/repo> <task number> [--base <ref>]" >&2; exit 2; }
case "$REPO" in */*) ;; *) usage ;; esac
case "$NUM" in ''|*[!0-9]*) usage ;; esac

# The checked tree is the one the command is CALLED FROM, not where the script lies: commands are
# distributed by the plugin and called from the project by absolute path (`bash ~/retainer/bin/…`),
# so the script location points at the plugin. Measuring a foreign tree finds files that cannot be
# in the project's task, and does not measure the task's own edits at all.
TARGET="${RETAINER_SCOPE_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[ -n "$TARGET" ] || { echo "not a git repository: $PWD — nothing to check the scope against"; exit 2; }
git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "not a git repository: $TARGET — nothing to check the scope against"; exit 2; }
if [ -z "$BASE" ]; then
  BASE="$(retainer_base_ref "$TARGET")"
fi
[ -n "$BASE" ] || {
  echo "cannot determine the diff base: the repository declares no main branch — pass --base"; exit 2; }

# The <owner/repo> argument sets WHERE the task body is read; the diff comes from the calling tree.
# There are two sources and they need not match — a mismatch is stated aloud. It is not a refusal:
# checking scope against a fork tree or a clone under another name is a legitimate case.
# The LAST TWO path segments are compared, not a substring: `owner/project` matches
# `owner/project-stand` and `superowner/project` as a substring, so the warning would be silent
# exactly on the most confusable pairs.
ORIGIN_URL="$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)"
ORIGIN_PAIR="$(printf '%s' "${ORIGIN_URL%.git}" | awk -F'[/:]' 'NF >= 2 { printf "%s/%s", $(NF - 1), $NF }')"
if [ -z "$ORIGIN_URL" ]; then
  echo "  · tree $TARGET has no remote origin — cannot verify it is $REPO"
elif [ "$ORIGIN_PAIR" != "$REPO" ]; then
  echo "  ⚠ the diff is taken from $TARGET ($ORIGIN_PAIR) and the task body from $REPO: these are different repositories"
fi

API="${GITEA_URL:-$(retainer_cfg tracker_url http://localhost:3000)}/api/v1"
TOKEN="$(retainer_token)"
[ -n "$TOKEN" ] || { echo "no tracker token — cannot read the task body or check the scope"; exit 2; }

body="$(curl -s --max-time 15 -H "Authorization: token $TOKEN" "$API/repos/$REPO/issues/$NUM" \
        | python3 -c '
import json, sys

try:
    issue = json.load(sys.stdin)
except ValueError:
    sys.exit(3)
if not isinstance(issue, dict) or "body" not in issue:
    sys.exit(3)                                  # a tracker error arrives as valid json without body
sys.stdout.write(str(issue.get("body") or ""))
')" || { echo "task body #$NUM not read (tracker silent or answer not parsed) — nothing to check against"; exit 2; }

# Comments are part of the declaration too: decisions along the way are written there, and declaring a name there is legitimate.
comments="$(curl -s --max-time 15 -H "Authorization: token $TOKEN" \
            "$API/repos/$REPO/issues/$NUM/comments" | python3 -c '
import json, sys

try:
    rows = json.load(sys.stdin)
except ValueError:
    sys.exit(0)                                  # there may be no comments — not a refusal
if not isinstance(rows, list):
    sys.exit(0)
for row in rows:
    if isinstance(row, dict):
        sys.stdout.write(str(row.get("body") or "") + "\x1e")
')"

# Documents are joined by a record separator, not a newline: the «Sample» section is read in each one on its own.
TARGET="$TARGET" BASE="$BASE" DECLARED="$body"$'\x1e'"$comments" NUM="$NUM" python3 - <<'PY'
import os
import os.path
import re
import subprocess
import sys

# Absolute path: a relative one (".") would name the tree while telling nothing.
ROOT = os.path.realpath(os.environ["TARGET"])
BASE = os.environ["BASE"]
NUM = os.environ["NUM"]
# Template hints are cut out BEFORE parsing — the technique is already adopted in the tree
# (`bin/retainer_ready_check.py`). Without it the check takes the task skeleton's OWN hint for a
# declaration: it holds both the sample-address form and the negation form. A tick that cannot be
# trusted is worse than none. A fence is NOT cut — see below why.
HINT = re.compile(r"<!--.*?-->", re.DOTALL)
# Fenced code is deliberately NOT cut: a plan often shows a new constant or path in a code block,
# and cutting would drop the declaration. This does not open self-satisfaction: the skeleton hint is
# an HTML comment, and it is cut inside a fence too.
# The body and each comment, hints cut in each. The name check reads them joined; the «Sample»
# section is read per document, because the skeleton ends on it and a comment's first lines would
# otherwise land inside an unfilled section.
DOCUMENTS = [HINT.sub("", doc) for doc in os.environ["DECLARED"].split("\x1e")]
DECLARED = "\n".join(DOCUMENTS)
HEADING = re.compile(r"^#{1,6}\s")
SAMPLE_HEADING = re.compile(r"^#{1,6}\s+Samples?\s*:?\s*$", re.IGNORECASE)


def sample_section_named(text):
    """Whether the document's «Sample» section holds a line with content once its list marker is stripped."""
    inside = False
    for line in text.splitlines():
        if HEADING.match(line):
            inside = bool(SAMPLE_HEADING.match(line))
            continue
        if inside and re.sub(r"^\s*-", "", line, count=1).strip():
            return True
    return False

# MODULE-level names in added lines: python functions and constants, shell functions and top-level
# variables. Leading indentation means "inside" — not new scope.
# We catch a SIGNAL, not every name: functions (new logic) and UPPER-case registries (a new source
# of truth — the very "parallel registries" class). Lower-case script variables do not count:
# `body=`, `comments=` are local mechanics, and requiring their declaration would drown the signal
# in noise and teach to bypass the check.
PATTERNS = (
    re.compile(r"^def\s+(\w+)\s*\("),
    re.compile(r"^class\s+(\w+)"),
    re.compile(r"^([A-Z_][A-Z_0-9]*)\s*(?::[^=]+)?=\s*\S"),
    re.compile(r"^(\w[\w-]*)\s*\(\)\s*\{"),
)
SUFFIXES = (".py", ".sh")
SKIP = ("tests/", "presets/", "docs/")


def match_name(line):
    """Module-level name in the line, or None. Indentation means "inside" — not new scope."""
    for pattern in PATTERNS:
        hit = pattern.match(line)
        if hit:
            return hit.group(1)
    return None


_BASE_CACHE = {}


def base_names(rel):
    """Module-level names the file had in the BASE (an empty set for a new file)."""
    if rel in _BASE_CACHE:
        return _BASE_CACHE[rel]
    out = subprocess.run(["git", "-C", ROOT, "show", "%s:%s" % (BASE, rel)],
                         capture_output=True, text=True, check=False)
    found = set()
    if out.returncode == 0:
        for line in out.stdout.splitlines():
            hit = match_name(line)
            if hit:
                found.add(hit)
    _BASE_CACHE[rel] = found
    return found


def file_at_base(rel):
    """Whether the file existed in the base. Without it "no names in the base" is indistinguishable from "no file"."""
    out = subprocess.run(["git", "-C", ROOT, "cat-file", "-e", "%s:%s" % (BASE, rel)],
                         capture_output=True, text=True, check=False)
    return out.returncode == 0


def added_names():
    out = subprocess.run(["git", "-C", ROOT, "diff", "--unified=0", BASE, "--", "*.py", "*.sh"],
                         capture_output=True, text=True, check=False)
    if out.returncode != 0:
        print("✗ git diff in %s against %s failed" % (ROOT, BASE))
        sys.exit(2)
    fresh = subprocess.run(["git", "-C", ROOT, "ls-files", "--others", "--exclude-standard",
                            "*.py", "*.sh"], capture_output=True, text=True, check=False)
    chunks = [out.stdout]
    for rel in fresh.stdout.splitlines():
        rel = rel.strip()
        if rel and not any(rel.startswith(s) for s in SKIP):
            chunks.append("+++ b/%s\n" % rel)
            try:
                with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
                    chunks.append("".join("+" + line for line in fh))
            except OSError:
                continue
    names = {}
    fresh_files = set()
    path = None
    for row in "".join(chunks).splitlines():
        if row.startswith("+++ b/"):
            path = row[6:]
            continue
        if not row.startswith("+") or row.startswith("+++") or path is None:
            continue
        if any(path.startswith(s) for s in SKIP) or not path.endswith(SUFFIXES):
            continue
        if not base_names(path) and not file_at_base(path):
            fresh_files.add(path)                 # no such file in the base: its content IS the task
            continue
        hit = match_name(row[1:])
        if hit:
            names.setdefault(hit, path)
    # A name that was ALREADY in the base is not new scope: an edit inside a declared function
    # rewrites the line with its definition, and without this check it would read as a new entity.
    for name, rel in list(names.items()):
        if name in base_names(rel):
            del names[name]
    return names, sorted(fresh_files)


names, fresh_files = added_names()
undeclared_files = [rel for rel in fresh_files
                    if not re.search(re.escape(rel.split("/")[-1]), DECLARED)]
if not names and not fresh_files:
    # The tree is named here too: "nothing to check" without it is indistinguishable from measuring a foreign repository.
    print("· no new module-level scope in the diff — nothing to check (%s against %s)" % (ROOT, BASE))
    sys.exit(0)

# Declared = the name occurs in the task body or its comments. The form is free: a plan is written
# in prose, not as a machine list, and demanding a format would break what works.
undeclared = [(name, path) for name, path in sorted(names.items())
              if not re.search(r"\b%s\b" % re.escape(name), DECLARED)]
# A sample is part of the declaration, not a separate discipline: a new code file repeats the form of
# something, and without an address review has nothing to compare against. A negation counts on a
# par with an address: "no new kinds" is a checkable statement, while silence is indistinguishable
# from an omission. Two forms count: the `Sample:` line anywhere, or content under a «Sample» heading.
sample_missing = bool(fresh_files) and not re.search(
    r"Sample:|No new kinds of code", DECLARED) and not any(
    sample_section_named(doc) for doc in DOCUMENTS)

print("── task scope #%s: %s against %s — new names %d, new files %d ──"
      % (NUM, ROOT, BASE, len(names), len(fresh_files)))
if not undeclared and not undeclared_files and not sample_missing:
    print("  ✓ all new scope is declared in the task body or its comments")
    sys.exit(0)
if sample_missing:
    print("  ✗ neither a sample address (a `Sample:` line or an entry under «## Sample») nor a")
    print("    \"No new kinds of code\" line in the task,")
    print("    yet the diff has %d new code files — review has nothing to compare the form with" % len(fresh_files))
for rel in undeclared_files:
    print("  ✗ new file not declared in the task: %s" % rel)
if undeclared:
    print("  ✗ not declared in the task (this is the sprawl inside the declared files):")
    for name, path in undeclared:
        print("      %s — %s" % (name, path))
print("  Declare what THIS task really needs, in the task body or a comment on it. For the rest")
print("  ask 'same work, or another?': the same subject is absorbed and declared here, a different")
print("  one is routed by that step rather than split off by reflex.")
sys.exit(1)
PY
