#!/usr/bin/env bash
# retainer: prototype debt is marked in the code and collected FROM the code.
#
#   retainer-prototype-debt.sh [project directory]
# exit 0 — markers exist and each carries a task number (inventory printed) · 1 — a marker without a
#      number · 3 — no targets: the project did not declare the `prototype_debt` key, or there are no markers in the tree
#      at all · 2 — usage, or THE CHECK DOES NOT WORK.
#
# WHY. The debt journal marks weakened CHECKS, the error journal — caught DEFECTS. Code
# knowingly accepted below the standard — a prototype that will be replaced — is marked by neither, and
# in half a year it is indistinguishable from the norm: a reader repeats its shape, taking it for a project decision.
#
# MARKER FORM, and the task number in it is mandatory:
#
#   # prototype: #<task number> — <what will replace it>
#
# Without a number the marker is useless: it says "this is not the norm" and not where that was agreed.
# The inventory is collected FROM the code by this same command — a hand-maintained list drifts from the tree
# silently, and drifts toward "less debt than it seems".
#
# WHAT THE MARKER DOES NOT JUSTIFY — that is policy prose, not a machine: secrets, data handling,
# tests, migrations, review. The marker makes debt visible, not permitted.
set -uo pipefail

DIR="${1:-.}"
[ -d "$DIR" ] || { echo "usage: retainer-prototype-debt.sh [project directory]" >&2; exit 2; }
cd "$DIR" || exit 2
git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "▶ prototype debt: not a git repository — nothing to read the tree with"; exit 3; }

# The key is read HERE, not only by the runner: the runner default is "enabled", and without reading the key
# here the check goes red on a project that does not enable the debt inventory. It is enabled by the key
# `prototype_debt` in `[rigor]`, not by the word "prototype" appearing in a comment.
RIGOR_PROTOTYPE_DEBT=""
if [ -f .retainer/config.toml ]; then
  RIGOR_PROTOTYPE_DEBT="$(awk '
    /^[[:space:]]*\[/ { inr = ($0 ~ /^[[:space:]]*\[rigor\][[:space:]]*$/) }
    inr && $0 ~ /^[[:space:]]*prototype_debt[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, "");
      gsub(/["'"'"']/, ""); gsub(/[[:space:]]/, ""); print; exit
    }' .retainer/config.toml 2>/dev/null)"
fi
if [ -z "$RIGOR_PROTOTYPE_DEBT" ] || [ "$RIGOR_PROTOTYPE_DEBT" = "false" ]; then
  echo "▶ prototype debt: the project did not enable the debt inventory (key prototype_debt in [rigor]) — nothing to check"
  exit 3
fi

# Tracked code files: the suite will not see a marker in an unstaged file, and it cannot be judged.
# Path lists from git are read only with -z — an escaped non-ASCII path otherwise breaks parsing silently.
MARKED=""
while IFS= read -r -d '' path; do
  case "$path" in
    *.py|*.sh|*.js|*.ts|*.tsx|*.jsx|*.vue|*.go|*.html|*.sql) ;;
    *) continue ;;
  esac
  [ -f "$path" ] || continue
  # The marker is the START of a comment, not a mention of the word in text: otherwise the rule's own
  # documentation lands in the inventory.
  # Case is enumerated as whole forms: the case-insensitive flag is locale- and grep-implementation-dependent,
  # and a capitalized marker would silently drop out of the inventory.
  while IFS= read -r hit; do
    MARKED="$MARKED$path:$hit"$'\n'
  # Openers cover every supported extension, `<!--` among them: markup is written only that way.
  # A missing opener does not go red: the marker drops out and the debt is printed as "no debt declared".
  done < <(grep -nE '^[[:space:]]*(#|--|//|\{#|<!--)[[:space:]]*(prototype|Prototype|PROTOTYPE):' "$path" 2>/dev/null)
done < <(git ls-files -z 2>/dev/null)

MARKED="$(printf '%s' "$MARKED" | sed '/^$/d')"
if [ -z "$MARKED" ]; then
  echo "▶ prototype debt: no markers in the tree — no debt declared"
  exit 3
fi

# The task number is part of the form. A line without it is printed separately: it is a finding, not a debt entry.
NUMBERED="$(printf '%s\n' "$MARKED" | grep -E '(prototype|Prototype|PROTOTYPE):[[:space:]]*#[0-9]+' || true)"
UNNUMBERED="$(printf '%s\n' "$MARKED" | grep -vE '(prototype|Prototype|PROTOTYPE):[[:space:]]*#[0-9]+' || true)"

if [ -n "$UNNUMBERED" ]; then
  echo "✗ prototype debt: marker without a task number — debt is declared and there is nowhere to read what was agreed"
  printf '%s\n' "$UNNUMBERED" | sed 's/^/    /'
  echo "    form: # prototype: #<task number> — <what will replace it>"
  echo "    to mention the form in code without declaring debt: precede it with a second comment character"
  exit 1
fi

count="$(printf '%s\n' "$NUMBERED" | wc -l | tr -d ' ')"
echo "✓ prototype debt: $count markers, each with a task number"
printf '%s\n' "$NUMBERED" | sed 's/^/    /'
