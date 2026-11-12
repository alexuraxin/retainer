#!/usr/bin/env bash
# retainer: dead links in the must-read instruction documents.
#
#   retainer-doc-links.sh [project dir]
# exit 0 -- links alive · 1 -- dead links found · 3 -- no targets: no instruction documents or no paths in them
#      2 -- usage or THE CHECK DOES NOT WORK (distinct from 0:
# a control that did not run has no right to report "clean").
#
# A link = a path with a separator whose first segment is an existing directory, or a path under `~`.
# Prose with a slash, bare names, patterns and absolute paths outside home are not links.
# A line marked `retainer:allow-link` is not scanned -- an exit from a false positive without
# switching the regulator off entirely.
set -uo pipefail
SCAN="$(cd "$(dirname "$0")" && pwd)/retainer_doc_links.py"   # resolved before cd into the project: the script's path, not the project's

DIR="${1:-.}"
[ -d "$DIR" ] || { echo "usage: retainer-doc-links.sh [project dir]" >&2; exit 2; }
cd "$DIR" || exit 2

if [ ! -f "$SCAN" ]; then
  echo "✗ dead links: retainer_doc_links.py is not next to the script -- the check does NOT work" >&2
  exit 2
fi
command -v python3 >/dev/null 2>&1 || { echo "✗ dead links: python3 missing -- the check does NOT work" >&2; exit 2; }

# Instruction documents: the typical names PLUS what the project declared as documents in its config
# (section [docs] -- policy, context, fact-architecture). The list must come from the config: a project
# with a non-standard policy name would otherwise get "clean" with zero instructions checked.
DOCS=""
# DOCS is space-joined and the scan loop word-splits it, so a document whose name contains whitespace
# cannot be scanned as one entry. Such a name is reported and skipped rather than listed as checked:
# listing it as checked over an unscanned body is the very "clean over an unchecked document" class.
add_doc(){
  [ -n "$1" ] || return 0
  [ -f "$1" ] || return 0
  case "$1" in *[[:space:]]*)
    printf '  ▶ dead links: %s has whitespace in its name — not scanned (DOCS is one entry per space)\n' "$1" >&2
    return 0 ;;
  esac
  case " $DOCS " in *" $1 "*) ;; *) DOCS="$DOCS $1" ;; esac
}
# `.foreman/` is the state directory of early Retainer versions (bin/retainer-migrate.sh); old projects keep PROJECT.md there.
for f in CLAUDE.md AGENTS.md ONBOARDING.md .retainer/PROJECT.md .foreman/PROJECT.md; do add_doc "$f"; done
# The [docs] keys name a project's instruction documents under a non-standard policy name. They are read
# with cfg_doc -- the same awk subset as bin/retainer-hot-context.sh and the runner reference
# hooks/stop_gate.py: it honors quotes, escaping and fences and cuts a trailing comment, so a value like
# `regulations = "AGENTS.md"   # policy` reads as the path and not a glued pseudo-name that no file matches
# and that drops the document from the scan silently. The copies in the two readers are held identical by
# the input table in tests/test_config_readers.sh.
cfg_doc(){  # cfg_doc <key> — the declared path or empty
  [ -f .retainer/config.toml ] || return 0
  # The subset of forms is the same as the runner's and the guard's: an escaped quote is part of the
  # value, not its end. Cutting at the first closing quote silently drops a document `"a\"b.md"`
  # from the measurement, and the step looks fine over an unchecked file.
  awk -v k="$1" -v q="'" '
    $0 ~ ("^[[:space:]]*" k "[[:space:]]*=") {
      sub(/^[^=]*=[[:space:]]*/, "")
      c = substr($0, 1, 1)
      if (substr($0, 1, 3) == "\"\"\"") {    # fence: the content between triple quotes
        rest = substr($0, 4)
        i = index(rest, "\"\"\"")
        print (i > 0 ? substr(rest, 1, i - 1) : "")
        exit
      }
      if (c == "\"") {                    # double quotes: escaping is parsed
        print unquote($0)
        exit
      }
      if (substr($0, 1, 3) == q q q) {     # triple single-quote fence: the content between them
        rest = substr($0, 4)
        i = index(rest, q q q)
        print (i > 0 ? substr(rest, 1, i - 1) : "")
        exit
      }
      if (c == q) {                       # literal string: by format it has no escaping
        $0 = substr($0, 2)
        i = index($0, c)
        if (i > 0) $0 = substr($0, 1, i - 1)
        print
        exit
      }
      sub(/[[:space:]]*#.*$/, "")          # bare value: cut the comment and trailing spaces
      sub(/[[:space:]]+$/, "")
      print
      exit
    }
    function unquote(src) {
      out = ""
      idx = 2
      while (idx <= length(src)) {
        ch = substr(src, idx, 1)
        if (ch == "\\") { out = out substr(src, idx + 1, 1); idx += 2; continue }
        if (ch == "\"") { return out }
        out = out ch
        idx++
      }
      return ""                            # unclosed quote: no value
    }' .retainer/config.toml 2>/dev/null
}
for key in regulations project_context architecture; do add_doc "$(cfg_doc "$key")"; done
for f in tooling.md docs/tooling.md; do add_doc "$f"; done
[ -n "$DOCS" ] || { echo "▶ dead links: no instruction documents found -- nothing to check"; exit 3; }

# Transient and created-on-demand state files: the unlock key lives 30 minutes, the deviation journal
# is created at the first deviation, the handoff manifest at the end of a wave. Requiring them to
# exist means requiring the project to always be in one specific state.
TRANSIENT="unlock active-issue plan-checked bypass.log conveyor.off handoff.md requirements.md DEVIATION-JOURNAL.md ERROR-JOURNAL.md"

dead=0
checked=0
# Filtering by the first segment is SILENT -- a defect separate from the filter itself. The rule's
# intent is right: `owner/repo`, `ruff/mypy`, `CLAUDE.md/AGENTS.md` are prose with a slash, not
# links. But silence inverts the intent: the MORE broken a path, the surer it is skipped. A link
# whose root vanished entirely has no first segment -- and is not checked at all.
# Measured on a live project: the same file gave "✗ no path" while the directory existed, and
# "clean, 1 paths checked" after the directory was removed. Green matched the MORE broken state,
# and a link into the removed early-version state directory was never named.
# The exit code does NOT change: a skip is not a finding. Making it a finding would paint
# `owner/repo` red in every document. Only the silence changes.
unchecked=0
skipped=""
for doc in $DOCS; do
  docdir="$(dirname "$doc")"
  # Scan line by line so a line can be excluded with a marker -- otherwise the only exit from a
  # false positive is to switch the regulator off entirely.
  scan_in="$(grep -v 'retainer:allow-link' "$doc")"
  tokens="$(printf '%s\n' "$scan_in" > "$doc.links.tmp" && python3 "$SCAN" "$doc.links.tmp")"
  rc=$?
  rm -f "$doc.links.tmp"
  if [ "$rc" -ne 0 ]; then
    echo "✗ dead links: parsing $doc failed (code $rc) -- the check does NOT work" >&2
    exit 2
  fi
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    case "$token" in
      \~/*) probe="${token/#\~/$HOME}" ;;
      /*)   continue ;;                       # absolute outside home -- layout illustration, not a link
      *)
        probe="$token"
        # The last segment has an extension, or the path ends with `/`. A stub like `sources/Pre`
        # (a file name with a space) is not a link: the parser takes only unambiguous links.
        # This rule goes FIRST: both filters are joined by "and", the order does not change the
        # verdict, but the second became loud -- and all prose like `ruff/mypy` and `N/A` would land
        # in its list. A skip drowning in prose reads exactly as the silence this change removes.
        case "$probe" in */) ;; *.*) ;; *) continue ;; esac
        # The first segment must be a DIRECTORY of this repository. Otherwise `owner/repo`,
        # `CLAUDE.md/AGENTS.md` are not broken links but prose with a slash. The filter stays but
        # is now LOUD: what is skipped is named aloud, otherwise a vanished root is invisible.
        if [ ! -d "${probe%%/*}" ]; then
          unchecked=$((unchecked + 1))
          skipped="$skipped
  · $doc: $token"
          continue
        fi
        ;;
    esac
    case " $TRANSIENT " in *" $(basename "$token") "*) continue ;; esac
    checked=$((checked + 1))
    [ -e "$probe" ] && continue
    # A document outside the root may reference relative to itself -- legitimate, not a dead link.
    [ "$docdir" != "." ] && [ -e "$docdir/$probe" ] && continue
    printf '  ✗ %s: no path %s\n' "$doc" "$token"
    dead=$((dead + 1))
  done <<EOF
$tokens
EOF
done

# The skipped list is printed on BOTH verdicts and before the summary line: on a clean run it is the
# only trace of what was not checked, on a dirty one it frames the scope in which findings were counted.
say_skipped(){
  [ "$unchecked" -eq 0 ] && return 0
  printf '  not checked (first segment absent from this tree) -- slash prose or a vanished root:%s\n' "$skipped"
}

# Zero PATHS with instructions found is cleanliness, not "no targets": the step's target is
# the instruction document, not a link inside it. A prose-only document is checked and carries
# no dead links; returning 3 here would declare a healthy project the wrong address.
if [ "$dead" -eq 0 ]; then
  say_skipped
  printf '▶ dead links: clean (checked %s · not checked %s, in:%s)\n' "$checked" "$unchecked" "$DOCS"
  exit 0
fi
say_skipped >&2
printf '✗ dead links: %s (checked %s · not checked %s). An instruction that cannot be trusted makes the agent improvise.\n' "$dead" "$checked" "$unchecked" >&2
printf '  False positive -- mark the line `retainer:allow-link`, do not switch the check off.\n' >&2
exit 1
