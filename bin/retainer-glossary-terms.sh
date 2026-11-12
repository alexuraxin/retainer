#!/usr/bin/env bash
# retainer: a term the code references is defined in the project glossary.
#
#   retainer-glossary-terms.sh [project dir]
# exit 0 — references exist and all resolve · 1 — a reference to an undefined term
#      3 — no targets: the project did not declare the `glossary_terms` key, no glossary, or no references in code
#      2 — usage, the declared glossary not found, or THE CHECK IS NOT WORKING.
#
# WHY. Domain words drift apart quietly: one module calls an entity a candidate, another an applicant, a third a
# record, and the argument about words resurfaces in the review of every task. A glossary cures this
# only when a reference to a term is machine-linked to the definition: otherwise the glossary goes stale and the
# code keeps referencing a word that is no longer in it.
#
# THE REFERENCE FORM is one: `:term:`Name``. A reference with a label — `:term:`Label <Name>`` — is parsed by
# the name in angle brackets: without this the step goes red on working documents, and a false positive costs
# trust in the whole check.
# Double brackets — `[[Name]]` — are NOT a reference form: the same notation writes a TOML table header,
# a shell conditional operator in a document code fence, and a link between documents.
# A definition is a glossary heading: a `## Name` line, or `  Name` in a sphinx glossary directive.
set -uo pipefail

# Reference search pattern. No substitutions are needed in it — it is a search pattern.
TERM_REF=':term:`[^`]+`'

DIR="${1:-.}"
[ -d "$DIR" ] || { echo "usage: retainer-glossary-terms.sh [project dir]" >&2; exit 2; }
cd "$DIR" || exit 2
git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "▶ term glossary: not a git repository — nothing to read the tree with"; exit 3; }

# The key is read HERE, not only by the runner: the runner default is "enabled", while the check runs only on the
# project's decision — otherwise a project with a live glossary goes red on already existing broken references.
RIGOR_GLOSSARY_TERMS=""
if [ -f .retainer/config.toml ]; then
  RIGOR_GLOSSARY_TERMS="$(awk '
    /^[[:space:]]*\[/ { inr = ($0 ~ /^[[:space:]]*\[rigor\][[:space:]]*$/) }
    inr && $0 ~ /^[[:space:]]*glossary_terms[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, "");
      gsub(/["'"'"']/, ""); gsub(/[[:space:]]/, ""); print; exit
    }' .retainer/config.toml 2>/dev/null)"
fi
if [ -z "$RIGOR_GLOSSARY_TERMS" ] || [ "$RIGOR_GLOSSARY_TERMS" = "false" ]; then
  echo "▶ term glossary: the project did not enable the term check (key glossary_terms in [rigor]) — nothing to check"
  exit 3
fi

# Glossary path: the key declared by the project, then the usual places. The list comes from the config: a project with
# a non-standard glossary name would otherwise get "clean" with zero references checked. A comment on the
# same line is stripped — the house config notation keeps a key and `# …` side by side.
GLOSSARY=""
if [ -f .retainer/config.toml ]; then
  declared="$(awk '
    /^[[:space:]]*\[/ { next }
    $0 ~ /^[[:space:]]*glossary[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, "");
      gsub(/["'"'"']/, ""); sub(/[[:space:]]+$/, ""); print; exit
    }' .retainer/config.toml 2>/dev/null)"
  # A declared and NOT found path is a refusal, not a fallback to the usual places: a fallback judges references by
  # a foreign glossary and names the wrong file to the operator.
  if [ -n "$declared" ] && [ ! -f "$declared" ]; then
    echo "✗ term glossary: the declared glossary «${declared}» is not in the tree — the check is NOT working" >&2
    exit 2
  fi
  [ -n "$declared" ] && GLOSSARY="$declared"
fi
if [ -z "$GLOSSARY" ]; then
  for cand in .retainer/GLOSSARY.md docs/glossary.md docs/GLOSSARY.md docs/pages/project/glossary.rst; do
    [ -f "$cand" ] && { GLOSSARY="$cand"; break; }
  done
fi
[ -n "$GLOSSARY" ] || {
  echo "▶ term glossary: no glossary in the tree — nothing to check references against"; exit 3; }

# References are collected over the staged code files: a reference in an unstaged file is invisible to the suite.
REFS=""
while IFS= read -r -d '' path; do
  case "$path" in
    *.py|*.sh|*.js|*.ts|*.html|*.md|*.rst) ;;
    *) continue ;;
  esac
  [ -f "$path" ] || continue
  while IFS= read -r term; do
    [ -n "$term" ] && REFS="$REFS$path|$term"$'\n'
  done < <(grep -oE "$TERM_REF" "$path" 2>/dev/null |
    sed -e 's/^:term:`//' -e 's/`$//' -e 's/^.*<\(.*\)>$/\1/')
done < <(git ls-files -z 2>/dev/null)

REFS="$(printf '%s' "$REFS" | sed '/^$/d' | sort -u)"
[ -n "$REFS" ] || {
  echo "▶ term glossary: no term references in the tree — nothing to check"; exit 3; }

# The comparison lives in the python part: case is folded by unicode, and the definition block indent
# is computed — in a line search, case folding on non-ASCII depends on the locale, and the indent is hardwired.
SCAN="$(cd "$(dirname "$0")" && pwd)/retainer_glossary_terms.py"
[ -f "$SCAN" ] || {
  echo "✗ term glossary: retainer_glossary_terms.py is not next to the script — the check is NOT working" >&2
  exit 2; }
PY_BIN=""
for cand in "${RETAINER_LINT_VENV:-}/bin/python3" "./.venv/bin/python3" python3.13 python3.12 python3; do
  case "$cand" in
    "${RETAINER_LINT_VENV:-}/bin/python3") [ -n "${RETAINER_LINT_VENV:-}" ] || continue ;;
  esac
  command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ] || continue
  PY_BIN="$cand"
  break
done
[ -n "$PY_BIN" ] || {
  echo "✗ term glossary: no python3 interpreter — the check is NOT working" >&2; exit 2; }

MISSING="$(printf '%s\n' "$REFS" | "$PY_BIN" "$SCAN" "$GLOSSARY")"
RC=$?
count="$(printf '%s\n' "$REFS" | wc -l | tr -d ' ')"
if [ "$RC" != 0 ] && [ "$RC" != 1 ]; then
  echo "✗ term glossary: the comparison did not run (code $RC) — the check is NOT working" >&2
  [ -n "$MISSING" ] && printf '%s\n' "$MISSING" | sed 's/^/    /' >&2
  exit 2
fi
if [ "$RC" = 1 ]; then
  echo "✗ term glossary: a reference leads nowhere ($GLOSSARY), references checked: $count"
  # The pair separator is the first bar: a term name may contain a bar, the remainder is printed whole.
  printf '%s\n' "$MISSING" | awk '{
    pos = index($0, "|")
    printf "    %s — term «%s» is not defined in the glossary\n", substr($0, 1, pos - 1), substr($0, pos + 1)
  }'
  exit 1
fi
echo "✓ term glossary: $count references, all resolve against $GLOSSARY"
