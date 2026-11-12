#!/usr/bin/env bash
# retainer: distribution set — which versioned tree files ship in the installed plugin.
#
#   retainer-dist-list.sh <tree dir>
# exit 0 — set printed (one path per line) · 1 — registry exists but is unusable: empty, names
#          something nonexistent, tree not under git · 2 — usage · 3 — no registry at all.
#
# "No registry" and "unusable registry" are DIFFERENT outcomes for the asker: the first is ordinary (the project
# never declared a set, compare by tree), the second means the declared set failed to build, and
# staying silent about it is not allowed — the very noise the selection exists to remove would return.
#
# Selection lives SEPARATE from the build because two ask for it: the distribution build and the check of
# executable code against the plugin cache. A second selection over the same registry would silently drift from the first —
# exactly the class this check catches.
#
# And it lives in a file that ITSELF SHIPS: the check runs from the installed box, while
# the build (`retainer-dist.sh`) is withdrawn from the distribution as a development tool. Asking for the set from something
# absent in the box means silently not asking at all.
#
# The tree dir is REQUIRED and becomes the working dir at once: both the registry and the list of
# versioned files are read by relative paths. A default "the tree the script runs from"
# would be a trap — from the box it points at the box itself, which has neither registry nor history.
#
# The registry knows two entry forms: a path — taken, a path with a minus sign — NOT taken, even when it lies
# under a taken dir. Without the second form the set is expressed only by listing every file, and that
# drifts from the tree on the first new one.
set -uo pipefail

TREE="${1:-}"
[ -n "$TREE" ] || { echo "usage: retainer-dist-list.sh <tree dir>" >&2; exit 2; }
[ -d "$TREE" ] || { echo "✗ distribution set: no directory $TREE" >&2; exit 1; }
cd "$TREE" || exit 1

MANIFEST=".claude-plugin/dist-manifest"
[ -f "$MANIFEST" ] || {
  echo "▶ distribution set: no registry $MANIFEST — the distributed set is not declared" >&2; exit 3; }
git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "✗ distribution set: tree is not under git — versioned cannot be told from working junk" >&2
  exit 1; }

# An entry is brought to canon BEFORE comparison: writing form is not a different path. Parsing it partially
# is not allowed, and this is measured: `hooks/` shipped, `hooks//` and `./hooks` did not, silently; with a withdrawal
# an invisible trailing space cancelled the cut entirely, and engine development tools shipped to projects in the box.
# None of these forms looks like an error when reading the registry by eye.
norm_entry() {  # norm_entry <entry> → no edge spaces, no `./`, no repeated or trailing `/`
  local e="$1"
  e="${e#"${e%%[![:space:]]*}"}"
  e="${e%"${e##*[![:space:]]}"}"
  while :; do case "$e" in ./*) e="${e#./}" ;; *) break ;; esac; done
  printf '%s' "$e" | sed 's#//*#/#g; s#/*$##'
}

entries=""
skips=""
while IFS= read -r line; do
  case "$(printf '%s' "$line" | tr -d '[:space:]')" in
    ''|'#'*) continue ;;
  esac
  case "$line" in
    # A minus sign may be followed by a space — the same entry: `- bin/dev` and `-bin/dev`
    # withdraw the same thing, and the difference is invisible to a registry reader.
    -*) skips="$skips$(norm_entry "${line#-}")
" ;;
    # A taken entry is normalized THE SAME WAY. The asymmetry was costly: `hooks/` passed the existence
    # check (`-e` on a dir is true) but matched no path at selection — and the
    # dir silently did not ship at all. The build handed out a guardless box, and the executable-code
    # check, having narrowed the list by the same selection, printed "matches" over what it did not
    # compare. Both failures are silent and have no floor: a full zero is caught, a shortfall is not.
    *) entries="$entries$(norm_entry "$line")
" ;;
  esac
done < "$MANIFEST"
[ -n "$entries" ] || { echo "✗ distribution set: registry is empty — nothing to distribute" >&2; exit 1; }

# A taken entry must yield at least one VERSIONED path. An on-disk existence check
# (`-e`) answered the wrong question: a dir on disk but not versioned (`dist`, any
# ignored one) passed it — and the set came out empty, silently. The same silence wrapped
# any entry form the comparison did not recognize.
#
# A missing path is a defect only among the TAKEN: the box would come out incomplete. Among the withdrawn it is
# harmless by definition — no file, so it does not ship anyway — and refusing on it would redden the build
# on every deletion of a stale tool, i.e. require editing the registry for something that is already
# gone.
TRACKED_ALL="$(git ls-files)"
missing=""
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  hit=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in "$entry" | "$entry"/*) hit=1; break ;; esac
  done <<TRACKED_EOF
$TRACKED_ALL
TRACKED_EOF
  [ "$hit" = 1 ] || missing="$missing $entry"
done <<ENTRIES_EOF
$entries
ENTRIES_EOF
[ -z "$missing" ] || {
  echo "✗ distribution set: registry names what yields no versioned file:$missing" >&2
  exit 1; }

# ONLY versioned files are taken: unversioned is one machine's working junk, and it must not be in
# another project. This also closes the case "the file is in no version, yet it is in the
# distribution".
printed=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  # A path enters the distribution if it is named in the registry itself or lies under a named dir.
  take=1
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$path" in "$entry" | "$entry"/*) take=0; break ;; esac
  done <<ENTRIES_EOF
$entries
ENTRIES_EOF
  [ "$take" = 0 ] || continue
  # Withdrawal beats taking: a path under a taken dir, named with a minus sign, does not ship.
  while IFS= read -r skip; do
    [ -n "$skip" ] || continue
    case "$path" in "$skip" | "$skip"/*) take=1; break ;; esac
  done <<SKIPS_EOF
$skips
SKIPS_EOF
  [ "$take" = 0 ] || continue
  printf '%s\n' "$path"
  printed=$((printed + 1))
done <<LS_EOF
$TRACKED_ALL
LS_EOF

# An empty set is a refusal, not an empty print: a reader getting zero lines with exit zero will build
# an empty box or narrow the check to nothing, and both outcomes are silent.
[ "$printed" != 0 ] || {
  echo "✗ distribution set: no versioned file matched the registry" >&2; exit 1; }
