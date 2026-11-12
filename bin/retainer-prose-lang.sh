#!/usr/bin/env bash
# retainer: code prose language -- docstrings, comments and definition names in Latin script.
#
#   retainer-prose-lang.sh [--content] [project dir]
# --content judges what prose SAYS instead of its script (the always-on `prose_content` step calls
#      this mode): the narrative finder, `.sh` comments too, no key read.
# exit 0 -- targets existed, prose is Latin · 1 -- findings · 3 -- no targets: not a git repository,
#      no comparison base, or no new and changed files
#      2 -- usage or THE CHECK DOES NOT WORK (distinct from 0: a control that did not run has no
#      right to report "clean").
#
# SUBJECT -- prose, not text. A docstring, comment and definition name are read by everyone who comes
# to the code; a string a user sees is written in the user's language and is not checked at all.
# Banning string literals would make the step harmful: it would demand translating error messages.
#
# CEILING. Targets are the lines a change adds against the base: a new file is judged whole, an
# edited or moved one by its added lines only. Prose of old code is not the subject: a step that
# goes red over the whole tree of an existing project, or over every untouched line of a file a task
# edits, gets switched off entirely, and the rule stops working even for new code. A removed line is
# not judged either. The escape from a false positive is per finding -- the `retainer:allow-prose` mark.
# The project declares the prose language: the regulator is on where code prose is written in Latin.
set -uo pipefail
MODE=""
if [ "${1:-}" = --content ]; then MODE=content; shift; fi
TITLE="prose language"; FINDER=retainer_prose_lang.py
[ "$MODE" = content ] && { TITLE="prose content"; FINDER=retainer_prose_content.py; }
SCAN="$(cd "$(dirname "$0")" && pwd)/$FINDER"   # before cd into the project: the script's path, not the project's
CFGLIB="$(cd "$(dirname "$0")" && pwd)/retainer-config.sh"
[ -f "$CFGLIB" ] || {
  echo "✗ $TITLE: retainer-config.sh missing next to the script -- the check does NOT work" >&2; exit 2; }
# shellcheck source=bin/retainer-config.sh
. "$CFGLIB"

DIR="${1:-.}"
[ -d "$DIR" ] || { echo "usage: retainer-prose-lang.sh [--content] [project dir]" >&2; exit 2; }
cd "$DIR" || exit 2

[ -f "$SCAN" ] || {
  echo "✗ $TITLE: $FINDER missing next to the script -- the check does NOT work" >&2; exit 2; }
# Interpreter for parsing: the newest available, same chain as the kit's other parsers. The system
# python 3.9 reports "unparsed" for a working file with modern syntax.
PY=""
for cand in "${RETAINER_LINT_VENV:-}/bin/python3" "./.venv/bin/python3" python3.13 python3.12 python3; do
  # The first candidate is taken only when the variable is SET: unset it expands to
  # `/bin/python3`, the value `/` to `//bin/python3`, and on a merged-`/usr` system both are the oldest.
  case "$cand" in
    "${RETAINER_LINT_VENV:-}/bin/python3") [ -n "${RETAINER_LINT_VENV:-}" ] || continue ;;
  esac
  command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ] || continue
  PY="$cand"
  break
done
[ -n "$PY" ] || {
  echo "✗ $TITLE: no python3 interpreter -- the check does NOT work" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "▶ $TITLE: not a git repository -- nothing to count new files from"; exit 3; }

# The key is read HERE, not only by the runner: the runner default is "enabled", while a step with no
# declaration in [rigor] stays silent and exits 3. Config silence means "undeclared", not "Latin".
DECLARED_LANG=""
if [ "$MODE" != content ] && [ -f .retainer/config.toml ]; then
  DECLARED_LANG="$(awk '
    /^[[:space:]]*\[/ { inr = ($0 ~ /^[[:space:]]*\[rigor\][[:space:]]*$/) }
    inr && $0 ~ /^[[:space:]]*prose_lang[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, "");
      gsub(/["'"'"']/, ""); gsub(/[[:space:]]/, ""); print; exit
    }' .retainer/config.toml 2>/dev/null)"
fi
if [ "$MODE" != content ] && [ -z "$DECLARED_LANG" ]; then
  echo "▶ prose language: project did not declare a code prose language (key prose_lang in [rigor]) -- nothing to check"
  exit 3
fi
if [ "$DECLARED_LANG" = "false" ]; then
  echo "▶ prose language: regulator disabled by project -- nothing to check"
  exit 3
fi

# The base comes from the kit's shared resolver: the repository itself declares the main branch name.
# A second name (master) is not guessed: an abandoned master lists already-merged work as new. No
# base -- the step stays silent aloud, rather than refusing.
BASE="$(retainer_base_ref .)"
[ -n "$BASE" ] || {
  echo "▶ $TITLE: no comparison base (repository declared no main branch) -- nothing to count new files from"
  exit 3; }

# The comparison point is ONE commit, and the diff runs from it to the working tree: committed, staged
# and unstaged edits come in one list, with line numbers of the file as it lies now. No shared history
# with the base -- HEAD; an unborn HEAD -- the empty tree: uncommitted work is judged either way.
FROM="$(git merge-base "$BASE" HEAD 2>/dev/null)"
[ -n "$FROM" ] || FROM="$(git rev-parse --verify --quiet HEAD 2>/dev/null)"
[ -n "$FROM" ] || FROM="$(git hash-object -t tree /dev/null)"
# Porcelain diff output follows the user's config and attributes: with colour, an external diff tool,
# a textconv filter or a `-diff` attribute no line starts with `@@`, every edited file reads as
# "nothing added", and the step would report clean over code it never read. A user's inter-hunk
# context would merge two hunks and judge the untouched lines between them.
DIFF=(--no-ext-diff --no-color --no-textconv --text --inter-hunk-context=0)
unset GIT_DIFF_OPTS   # its context option is applied after -U0 and would widen every hunk

target() {  # target <path> -- 0 when the path is code prose the step judges
  case "$MODE:$1" in *.py|content:*.sh) ;; *) return 1 ;; esac
  case "/$1" in
    */.venv/*|*/build/*|*/dist/*|*/node_modules/*|*/generated/*) return 1 ;;
  esac
  [ -f "$1" ]
}
# added_ranges <path> [old path] -- lines of the current file the change added, as `3-7,12`. A hunk
# header `@@ -a,b +c,d @@` names new lines c..c+d-1 (d defaults to 1, d=0 is a pure deletion). A
# moved file is diffed with its old path, so its hunks are the edit, not the whole file. Paths are
# literal: as a glob, `t[1].py` would also take the hunks of `t1.py`. Exit 1 when git gave no diff
# (an unreadable file): the caller then judges the file whole, never skips it.
added_ranges() {
  local hunks p
  local -a spec
  spec=()
  for p in "$@"; do spec+=(":(literal)$p"); done
  hunks="$(git diff "${DIFF[@]}" -U0 -M "$FROM" -- "${spec[@]}" 2>/dev/null)" || return 1
  printf '%s\n' "$hunks" | awk '
    /^@@/ && match($0, /\+[0-9]+(,[0-9]+)?/) {
      n = split(substr($0, RSTART + 1, RLENGTH - 1), a, ","); cnt = (n > 1 ? a[2] : 1)
      if (cnt > 0) { out = out sep a[1] "-" (a[1] + cnt - 1); sep = "," }
    }
    END { printf "%s", out }'
}

filtered() {  # filtered <path> -- 0 when a clean filter rewrites the file before git diffs it
  local value
  value="$(git check-attr -z filter -- "$1" 2>/dev/null | tr '\0' '\n' | sed -n 3p)"
  [ -n "$value" ] && [ "$value" != unspecified ]
}

# Scanner arguments: `--added <ranges> <path>` per tracked file, `<path>` per file judged whole. Path
# lists from git are read only with -z: an escaped non-ASCII path breaks parsing silently while the
# run stays green. A moved file is listed as `R<score> <old> <new>`.
ARGS=()
COUNT=0
while IFS= read -r -d '' status; do
  old=""
  case "$status" in R*) IFS= read -r -d '' old ;; esac
  IFS= read -r -d '' path || break
  target "$path" || continue
  # A clean filter can change the line count, and git's numbers would then miss the file the
  # scanner reads: such a file is judged whole, like one git could not diff.
  if filtered "$path"; then
    ARGS+=("$path")
  elif ranges="$(added_ranges "$path" ${old:+"$old"})"; then
    [ -n "$ranges" ] || continue   # deletions only: nothing was added to judge
    ARGS+=(--added "$ranges" "$path")
  else
    ARGS+=("$path")
  fi
  COUNT=$((COUNT + 1))
done < <(git diff -z --name-status -M --diff-filter=AMR "$FROM" 2>/dev/null)
while IFS= read -r -d '' path; do
  target "$path" || continue
  ARGS+=("$path")
  COUNT=$((COUNT + 1))
done < <(git ls-files -o --exclude-standard -z 2>/dev/null)

if [ "$COUNT" -eq 0 ]; then
  echo "▶ $TITLE: no new or changed code files -- nothing to check"
  exit 3
fi

FOUND="$("$PY" "$SCAN" "${ARGS[@]}")"
RC=$?
# Scanner contract: 0 -- clean, 1 -- findings, anything else -- check failure, not clean.
if [ "$RC" != 0 ] && [ "$RC" != 1 ]; then
  echo "✗ $TITLE: scanner did not finish (code $RC) -- the check does NOT work" >&2
  [ -n "$FOUND" ] && printf '%s\n' "$FOUND" | sed 's/^/    /' >&2
  exit 2
fi
if [ "$RC" = 1 ] && [ -z "$FOUND" ]; then
  echo "✗ $TITLE: scanner returned findings with no output -- the check does NOT work" >&2
  exit 2
fi
if [ -n "$FOUND" ]; then
  if [ "$MODE" = content ]; then what="narrative in code prose"; else what="Cyrillic in code prose"; fi
  echo "✗ $TITLE: $what -- $COUNT files checked"
  printf '%s\n' "$FOUND" | sed 's/^/    /'
  # The advice is printed exactly where it works: an "unparsed" finding is not lifted by the mark --
  # it bypasses parsing entirely, and is fixed by the interpreter or syntax, not by a mark.
  if printf '%s' "$FOUND" | grep -qv ':unparsed$'; then
    echo "    lift a finding individually: the retainer:allow-prose mark on its line or the line above"
  fi
  if printf '%s' "$FOUND" | grep -q ':history$'; then
    echo "    a \"used to\" naming what a thing serves for reads as history: reword it"
    echo "    (\"a key used to sign requests\" -> \"a key that signs requests\") or mark the line"
  fi
  if printf '%s' "$FOUND" | grep -q ':unparsed$'; then
    echo "    \"unparsed\" lines are not lifted by the mark: the file did not parse -- check the syntax and"
    echo "    the interpreter version (it must understand the project's syntax)"
  fi
  exit 1
fi
if [ "$MODE" = content ]; then what="no narrative"; else what="no Cyrillic"; fi
echo "✓ $TITLE: $COUNT files, $what in prose"
