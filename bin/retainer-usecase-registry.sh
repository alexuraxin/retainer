#!/usr/bin/env bash
# retainer: project use-case registry — built FROM CODE, not maintained by hand.
#
#   retainer-usecase-registry.sh [project dir]
# exit 0 — registry printed · 3 — no targets: no use-case dirs in the tree
#      2 — usage or THE CHECK IS NOT WORKING.
#
# WHY. The rule "a case follows a business use case, not a layer" is unexecutable while the use-case list
# has nowhere to come from: the agent enumerates layers because layers are visible in the tree and use cases are not. A registry
# kept by hand drifts from the code silently; this one is built from the tree on every call.
#
# AN EMPTY AREA IS PRINTED. A use-case dir without a single public name is not "nothing
# to show" but the registry's main finding: this section's behavior is described nowhere.
#
# BOUNDARY. The registry says WHAT the project can do and says nothing about quality: the description is taken from the
# docstring, and it is only as honest as the code is about its own name.
set -uo pipefail
SCAN="$(cd "$(dirname "$0")" && pwd)/retainer_usecase_registry.py"   # before cd: the script's path, not the project's

DIR="${1:-.}"
[ -d "$DIR" ] || { echo "usage: retainer-usecase-registry.sh [project dir]" >&2; exit 2; }
cd "$DIR" || exit 2
[ -f "$SCAN" ] || {
  echo "✗ use-case registry: retainer_usecase_registry.py is not next to the script — the check is NOT working" >&2
  exit 2; }
# Interpreter for parsing: the newest available — python 3.9 cannot parse modern syntax
# (`type X = ...`), and a working file is counted "not parsed". The first candidate is taken
# only when the variable is SET: an unset one expands to the existing `/bin/python3`, the oldest.
PY=""
for cand in "${RETAINER_LINT_VENV:-}/bin/python3" "./.venv/bin/python3" python3.13 python3.12 python3; do
  case "$cand" in
    "${RETAINER_LINT_VENV:-}/bin/python3") [ -n "${RETAINER_LINT_VENV:-}" ] || continue ;;
  esac
  command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ] || continue
  PY="$cand"
  break
done
[ -n "$PY" ] || {
  echo "✗ use-case registry: no python3 interpreter — the check is NOT working" >&2; exit 2; }

# Where to look for use cases: path patterns from the `usecase_globs` key, else two common layouts. The default does not
# replace config: with another layout a project would otherwise get "no targets" over a live use-case tree.
# The array is read MULTI-LINE (valid TOML wraps elements), a trailing comment is stripped.
GLOBS=""
if [ -f .retainer/config.toml ]; then
  GLOBS="$(awk '
    $0 ~ /^[[:space:]]*usecase_globs[[:space:]]*=/ { collecting = 1; sub(/^[^=]*=[[:space:]]*/, "") }
    collecting {
      sub(/[[:space:]]*#.*$/, "")
      printf "%s ", $0
      if ($0 ~ /\]/) { exit }
    }' .retainer/config.toml 2>/dev/null | tr -d '[]"'"'" | tr ',' ' ')"
fi
[ -n "$GLOBS" ] || GLOBS="*/logic/usecases/*.py */usecases/*.py"

# Word splitting is needed, shell EXPANSION of the pattern is not: `find` does that, and only it
# crosses the dir separator. Without `set -f` a nested layout is lost silently.
set -f
FILES=()
# shellcheck disable=SC2086  # word splitting is intentional here, glob disabled above
for pattern in $GLOBS; do
  while IFS= read -r -d '' path; do
    case "$(basename "$path")" in __init__.py) continue ;; esac
    # Foreign and build trees are not project code. Exclusions apply to files too, not only to the walk of
    # the dirs below: a vendored file would otherwise enter parsing together with the use cases.
    case "/${path#./}/" in
      */.venv/*|*/site-packages/*|*/node_modules/*|*/_build/*|*/build/*|*/dist/*|*/.tox/*) continue ;;
      */.mypy_cache/*|*/.ruff_cache/*|*/.pytest_cache/*|*/__pycache__/*) continue ;;
    esac
    FILES+=("$path")
  done < <(find . -path "./.git" -prune -o -path "./$pattern" -type f -print0 2>/dev/null)
done

# Dirs under the path pattern: "empty area" is counted over them — a dir without code files and a dir
# with just a package declaration.
DIRS=()
# shellcheck disable=SC2086  # word splitting is intentional, glob disabled above
for pattern in $GLOBS; do
  pdir="$(dirname "$pattern")"
  while IFS= read -r -d '' dir; do
    rel="${dir#./}"
    # Build and foreign trees are not project sections: calling a use-case dir inside built
    # docs or a virtualenv an empty area is just noise.
    case "/$rel/" in
      */_build/*|*/.venv/*|*/node_modules/*|*/build/*|*/dist/*|*/.tox/*|*/site-packages/*) continue ;;
      */.mypy_cache/*|*/.ruff_cache/*|*/.pytest_cache/*|*/__pycache__/*) continue ;;
    esac
    # A dir made only of non-code files (docs, data) is not a use-case section.
    # The absence of code is judged, not the presence of a document: a section with just a package declaration
    # stays in the list even with a README — an empty area must reach the output.
    if [ -z "$(find "$dir" -maxdepth 1 -name '*.py' -print -quit 2>/dev/null)" ] &&
      [ -n "$(find "$dir" -maxdepth 1 -type f ! -name '*.py' -print -quit 2>/dev/null)" ]; then
      continue
    fi
    DIRS+=("$rel")
  done < <(find . -path "./.git" -prune -o -path "./$pdir" -type d -print0 2>/dev/null)
done
set +f

if [ "${#FILES[@]}" -eq 0 ] && [ "${#DIRS[@]}" -eq 0 ]; then
  echo "▶ use-case registry: no use-case dirs found (path patterns: $GLOBS) — nothing to build"
  exit 3
fi

UNIQ=()
if [ "${#FILES[@]}" -gt 0 ]; then
  while IFS= read -r path; do UNIQ+=("$path"); done < <(printf '%s\n' "${FILES[@]}" | sort -u)
fi

OUT=""
RC=0
if [ "${#UNIQ[@]}" -gt 0 ]; then
  OUT="$("$PY" "$SCAN" "${UNIQ[@]}")"
  RC=$?
fi
# On the normal path the builder returns only 0: any other code means it did not finish.
if [ "$RC" -ne 0 ]; then
  echo "✗ use-case registry: build failed (code $RC) — the check is NOT working" >&2
  # The failing file's name is printed: without it the operator knows only the code and not what to fix.
  [ -n "$OUT" ] && printf '%s\n' "$OUT" | sed 's/^/    /' >&2
  exit 2
fi
if [ "${#UNIQ[@]}" -gt 0 ] && [ -z "$OUT" ]; then
  echo "✗ use-case registry: the builder returned empty output on a non-empty set — the check is NOT working" >&2
  exit 2
fi

echo "▶ use-case registry: ${#UNIQ[@]} files"
# Print only on non-empty output: `printf` with an empty string hands awk one empty line, and
# awk prints it as an "empty area" without a name — a finding about a dir that does not exist.
if [ -n "$OUT" ]; then
  printf '%s\n' "$OUT" | awk -F'|' '
    $2 == "" { printf "    %s — EMPTY: the behavior of this section is described nowhere\n", $1; next }
    { printf "    %s · %s — %s\n", $1, $2, ($3 == "" ? "(no description)" : $3) }
  '
fi

# A dir the builder said nothing about is an empty area, printed separately.
named=""
for dir in ${DIRS[@]+"${DIRS[@]}"}; do
  printf '%s\n' "$OUT" | grep -qF -- "$dir|" && continue
  case " $named " in *" $dir "*) continue ;; esac
  named="$named $dir"
  printf '    %s — EMPTY: the behavior of this section is described nowhere\n' "$dir"
done
