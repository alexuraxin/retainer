#!/usr/bin/env bash
# retainer: a copy of a protected file anywhere in the tree.
# Compared by CONTENT, not by name: the copy is named differently, and a name heuristic misses.
#
#   retainer-protected-copy.sh [project dir]
# exit 0 — no copies · 1 — copies found · 2 — usage or THE CHECK DOES NOT WORK · 3 — no targets.
set -uo pipefail
SCAN="$(cd "$(dirname "$0")" && pwd)/retainer_protected_copy.py"

DIR="${1:-.}"
[ -d "$DIR" ] || { echo "usage: retainer-protected-copy.sh [project dir]" >&2; exit 2; }
cd "$DIR" || exit 2

CONFIG=".retainer/config.toml"
# Order matters: a broken engine is judged BEFORE the absence of targets, or "the check does not
# work" masquerades as "no targets" — exactly the confusion the exit codes keep apart.
[ -f "$SCAN" ] || { echo "✗ protected copies: no parser next to the script — the check does NOT work" >&2; exit 2; }
[ -f "$CONFIG" ] || { echo "▶ protected copies: no $CONFIG — protected list not declared, skipped"; exit 3; }

# From the protected list only concrete FILES are taken: a directory pattern has no single content.
# set -f is mandatory — or bash expands the pattern into real files BEFORE the pattern check, and the
# filter never fires.
set -f
FILES=()
# Elements are read LINE BY LINE with escape parsing — the same subset of forms as the runner and
# the guard. A grep parse with word splitting cuts an element at an escaped quote and breaks a path
# with a space; a path dropped from the comparison lets a protected file be kept as a copy under
# another name, and the check stays silent.
while IFS= read -r pat; do
  [ -n "$pat" ] || continue
  case "$pat" in *\**) continue ;; esac
  [ -f "$pat" ] && FILES+=("$pat")
done <<PROTECTED_EOF
$(awk -v q="'" '
  /^[[:space:]]*protected[[:space:]]*=/ { inside = 1 }
  inside {
    line = $0
    pos = 1
    while (pos <= length(line)) {
      char = substr(line, pos, 1)
      if (char == "#") break                     # comment outside a value: the rest is not ours
      if (char == "\"" || char == q) { pos = emit(line, pos, char); continue }
      if (char == "]") { inside = 0; break }
      pos++
    }
  }
  function emit(src, from, fence) {               # a quoted element; fence is the quote kind
    out = ""
    idx = from + 1
    while (idx <= length(src)) {
      ch = substr(src, idx, 1)
      # Only double quotes have escapes: in a literal string a backslash is a plain character.
      if (ch == "\\" && fence == "\"") { out = out substr(src, idx + 1, 1); idx += 2; continue }
      if (ch == fence) { print out; return idx + 1 }
      out = out ch
      idx++
    }
    return idx                                    # unclosed quote: the element did not happen
  }
' "$CONFIG")
PROTECTED_EOF
set +f
[ "${#FILES[@]}" -gt 0 ] || {
  echo "▶ protected copies: no concrete files in the list — nothing to compare"; exit 3; }

# git worktrees are checkouts of the same repository, not copies: skipped, but their count is printed.
SKIP_ROOTS=""
wt=0
if command -v git >/dev/null 2>&1; then
  while IFS= read -r line; do
    p="${line%% *}"
    [ -n "$p" ] && [ "$p" != "$PWD" ] || continue
    SKIP_ROOTS="$SKIP_ROOTS${SKIP_ROOTS:+:}$p/"
    wt=$((wt + 1))
  done < <(git worktree list 2>/dev/null)
fi
[ "$wt" -gt 0 ] && printf '  · git worktrees skipped: %s (these are checkouts, not copies)\n' "$wt"

# An array, not word splitting: a path with a space would otherwise go as two nonexistent arguments.
out="$(SKIP_ROOTS="$SKIP_ROOTS" python3 "$SCAN" . "${FILES[@]}")"
rc=$?
case "$rc" in
  0) printf '▶ protected copies: none found (files checked: %s)\n' "${#FILES[@]}"; exit 0 ;;
  1) ;;
  *) echo "✗ protected copies: parsing failed (code $rc) — the check does NOT work" >&2; exit 2 ;;
esac

printf '%s\n' "$out" | while IFS="$(printf '\t')" read -r copy orig; do
  [ -n "$copy" ] && printf '  ✗ %s — copy of protected %s (content matches byte for byte)\n' "$copy" "$orig"
done
cat >&2 <<'EOF'
✗ copies of protected files found. Protection works by PATH: a copy under another name has no protection
  but reads as rules. Delete the copy — or, if it is needed, declare it protected too.
EOF
exit 1
