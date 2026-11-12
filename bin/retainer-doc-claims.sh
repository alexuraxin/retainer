#!/usr/bin/env bash
# retainer: marked factual claims in documents are verified by execution.
#
#   retainer-doc-claims.sh [project dir]
# exit 0 -- all marked claims confirmed · 1 -- a mismatch · 2 -- usage
#      3 -- no targets: no marked claims found in the documents.
#
# "A document promises a property the tree lacks" is the most common defect class of a project: it
# is relied on in decisions, checking it is cheap, and nobody checks.
#
# A one-off proofreading does not cure the class -- it finds what exists today and goes stale at the
# next edit. So a factual claim must carry its CHECK beside it.
#
# FORM. A marked block in the document itself, next to the claim:
#
#     <!-- claim: <command> -->
#
# The command runs from the project root; zero means the claim holds, otherwise a mismatch with the
# document and line address.
#
# WHY ONLY MARKED. Recognizing promises in prose means building a natural-language detector that
# errs both ways; a marked block is cheap and catches nothing extra. The cost: an unmarked promise
# stays invisible, which is more honest than a detector that cannot be trusted.
#
# WHY THE CHECK LIVES IN THE DOCUMENT. A separate registry drifts from the text: the claim is edited
# in one file and the check in another, and the second step is forgotten.
set -uo pipefail

DIR="${1:-.}"
[ -d "$DIR" ] || { echo "usage: retainer-doc-claims.sh [project dir]" >&2; exit 2; }
cd "$DIR" || exit 2

command -v git >/dev/null 2>&1 || {
  echo "✗ marked claims: no git -- targets cannot be collected, the check does NOT work" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "▶ marked claims: not a git repository -- nothing to check"; exit 3; }

MARK='claim:'
OPEN='<!--'
found=0
failed=0

while IFS= read -r -d '' doc; do
  [ -f "$doc" ] || continue
  line=0
  while IFS= read -r row; do
    line=$((line + 1))
    case "$row" in *"$OPEN"*"$MARK"*) ;; *) continue ;; esac
    # A marker inside backticks is a form EXAMPLE, not a claim. Without this, documentation
    # explaining the mark itself would run as a command.
    case "$row" in *'`'*"$OPEN"*) continue ;; esac
    # The command is everything between the marker and the closing comment bracket.
    cmd="${row#*"$MARK"}"
    cmd="${cmd%%-->*}"
    # Edge whitespace is stripped so `<!-- claim: cmd -->` and `<!--claim:cmd-->` are the same.
    cmd="$(printf '%s' "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$cmd" ] || continue
    found=$((found + 1))
    if out="$(sh -c "$cmd" 2>&1)"; then
      printf '  ✓ %s:%s -- confirmed\n' "$doc" "$line"
    else
      failed=$((failed + 1))
      printf '  ✗ %s:%s -- claim NOT confirmed\n' "$doc" "$line"
      printf '      command: %s\n' "$cmd"
      printf '%s' "$out" | head -3 | sed 's/^/      /'
    fi
  done < "$doc"
# `-z`, not line by line: `git ls-files` quotes non-ASCII names with octal escapes, such a path
# never reaches the file, and the document silently drops out of the check.
done < <(git ls-files -z '*.md' 2>/dev/null)

if [ "$found" -eq 0 ]; then
  echo "▶ marked claims: none found -- no targets"
  echo "  To mark: <!-- claim: <command> --> next to a factual claim."
  exit 3
fi
if [ "$failed" -gt 0 ]; then
  echo "✗ the document promises what is not there: mismatches $failed of $found"
  exit 1
fi
echo "✔ marked claims confirmed by execution: $found"
