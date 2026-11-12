#!/usr/bin/env bash
# retainer: reconcile two registries of one intent — `protected` and `deny`.
#
#   retainer-deny-sync.sh [project dir]
# exit 0 — no divergence · 1 — findings · 2 — usage · 3 — no targets (no config or no
#          settings files: nothing to compare against, and that is not cleanliness).
# Under a CI marker the class "closed only by the project registry" does not raise the exit
# code: the home registry is unobservable there by construction, so no verdict is issued on it
# (see `gap_local`). Other classes still raise it, including alongside it in the same run.
#
# `protected` in `.retainer/config.toml` and `deny` in the harness settings files close the same
# intent by different mechanisms, and they drift apart silently. It reads two ways, both costly:
#   path under `deny` but not in `protected` — the project registry does not name it: a config
#     reader thinks the path is open although the harness closed it tight;
#   path in `protected` but not closed under `deny` — closed by nothing: the guard judges only
#     `Bash`, write tools are held by `deny` alone. Until a rule exists, `Write` on the path goes through.
#
# The rule's tool is SIGNIFICANT, and exactly ONE is: for file checks the harness applies only
# `Edit(path)`, and it holds a write by any edit tool. A `Write(path)` rule is applied by
# nothing; found in a registry, it is named on a separate line — the owner sees it and thinks
# the path is closed.
# Measured with a live harness 2.1.241, not read from docs: `Write(//target)` did not stop a write,
# `Edit(//target)` stopped `Write`, `NotebookEdit`, and a write to a file nested in a directory target.
# The version is named because the criterion here is a claim about harness behavior, not about the
# settings file format. `MultiEdit` is not listed as a separate tool in that version and is not
# covered by the measurement: its rule does not count as closure, like any non-`Edit` — while in the
# reverse direction ("under deny, but not under the guard") it is judged as before. Dead entries are
# filtered out for `Write` only, because only it was measured: extending that to the unverified
# would change a verdict on a guess.
#
# THE RULE'S REGISTRY IS SIGNIFICANT TOO. The project `.claude/settings.json` is applied only by a
# session opened in that directory; a session from anywhere else does not read it and writes to the
# path freely. So a path counts as closed only by a rule in the HOME registry — it acts regardless of
# the launch directory. A path closed by a project rule alone gets its own verdict: it has protection,
# but for exactly one way of starting a session.
# The entry form is significant for the same reason: a rule's address depends on what anchors it.
# Closure is an entry whose address does not depend on the launch place: `//full/path` (two slashes
# are the filesystem root) or `~/path` from the home directory. ONE leading slash anchors on the
# settings source — in the home registry on `~/.claude/…`, in the project one on the project root —
# so a full path written with one slash closes nothing. Such an entry, a bare entry and `./…` are
# named on a separate line and suppress the clean verdict: they close not what they appear to.
# Measured with a live harness run, not derived from docs.
#
# A path counts as closed when ANY rule covers it once its form is resolved and its pattern read:
# one rule on the tree root or on a directory above it covers every entry, `hooks/*.py` covers
# `hooks/guard.py` and not `hooks/hooks.json`. The pattern is read with path segments: `*` and `?`
# stay inside one segment, `**` crosses them. Three shapes are NOT read as closure and are named
# "check by eye": an entry that starts with a pattern (`**/secrets.env`), a bracket class
# (`[gh]*.py`), and the root written with a trailing slash (an unmeasured form). Two more are not
# read and stay silent: a bare pattern (`h*`, not `h*/**`) closes only a regular file that exists —
# a directory or a path not on disk is not taken as closed — and a pattern above the root
# (`/x/repo-*/…`) is not matched against the tree. Each errs red, never green.
# The bound of all of it is the PATH: a rule names one tree, and a second worktree or a clone of
# the same repository at another path is not covered until a rule names that path.
# `set -f` here is not hygiene but the subject: lists are iterated unquoted, and without it the shell
# expands `.claude/**` against the working tree. Files on disk would be compared instead of what
# the registries say — the same config would give a different verdict on an empty directory.
set -uo pipefail -f

BOX="$(cd "$(dirname "$0")/.." && pwd)"   # engine root is taken BEFORE cd into the project dir

DIR="${1:-.}"
[ -d "$DIR" ] || { echo "usage: retainer-deny-sync.sh [project dir]" >&2; exit 2; }
cd "$DIR" || exit 2

CONFIG=".retainer/config.toml"
NL='
'
# File lists are kept LINE BY LINE, not word by word. A space in the home directory name is common
# (the machine owner's first and last name), and word iteration tore every home path into two
# nonexistent ones: the registry was not read at all. Closure attested by an unreadable file is
# attested by nothing.
SETTINGS=".claude/settings.json
.claude/settings.local.json"
HOME_SETTINGS="$HOME/.claude/settings.json
$HOME/.claude/settings.local.json"

[ -f "$CONFIG" ] || {
  echo "▶ protected/deny reconciliation: no $CONFIG — nothing to check"; exit 3; }

# The registry is read EXACTLY as the guard reads it: on a membership claim any parsing divergence
# means a green verdict over an unprotected tree.
#
#   * TOP-LEVEL only — a list under a table (`[rigor]` above) is invisible to the guard;
#   * any entry form — a one-line list and a multi-line list are the same;
#   * on a repeated declaration the LAST one wins, as with key overwrite;
#   * comments are not entries: the guard parses the format, not the text.
PROTECTED_RAW="$(awk '
  BEGIN { top = 1 }
  /^[[:space:]]*\[[A-Za-z_]/ { top = 0; next }
  /^[[:space:]]*protected[[:space:]]*=/ {
    if (!top) { next }
    body = ""; line = $0
    sub(/^[^=]*=[[:space:]]*/, "", line)
    while (1) {
      sub(/[[:space:]]*#.*$/, "", line)
      body = body line
      if (index(body, "]") > 0) { break }
      if ((getline line) <= 0) { break }
    }
    sub(/.*\[/, "", body); sub(/\].*/, "", body)
    found = body
    next
  }
  END { print found }
' "$CONFIG" | grep -o "[\"'][^\"']*[\"']" | sed "s/^[\"']//; s/[\"']$//")"

HERE_ABS="$(pwd -P)"
HERE_LOG="$PWD"

# One file is written in the registries in different forms: `CLAUDE.md`, `./CLAUDE.md`, absolute,
# `.claude/**`. The form is a way of writing, not another path, and is reduced to one BEFORE comparing.
# `stem` drops the pattern tail and answers one question: does the entry name a path at all (an
# entry starting with a pattern leaves nothing). Comparison keeps the pattern (`rule_norm`), and
# `covered` reads what it covers.
stem() { printf '%s' "$1" | sed -e 's#^\(\./\)*##' -e 's#\*.*$##' -e 's#/*$##'; }
rule_norm() { printf '%s' "$1" | sed -e 's#^\(\./\)*##' -e 's#/*$##'; }

# The literal directory of a pattern: the segments before the first one holding `*`, `?` or `[`.
# Cut by segment, not at the star: `docs/a*b/c` lies in `docs`, and `docs/a` names no directory.
lit_dir() {
  printf '%s' "$1" | awk -F/ '{
    out = ""
    for (i = 1; i <= NF; i++) {
      if ($i ~ /[*?[]/) { break }
      out = (i == 1) ? $i : out "/" $i
    }
    print out }'
}

# Does the pattern match the path — or, with `up`, one of its ancestors? `up` is for a pattern
# written as `<pattern>/**`: it closes everything below what it matches. A bare pattern is matched
# against the path itself only: that a pattern matching a directory closes its contents is not
# measured, and reading it so could err green.
# `*` and `?` stay inside one segment; `**/` crosses segments (`a/**/b` also matches `a/b`), and
# `**` elsewhere is a plain `*`. Regex metacharacters are escaped, and the regex reaches awk through
# the environment: `-v` would undo the escapes (`a\.b` → `a.b`). A bracket is escaped too: a class
# is not parsed, and a path without a bracket never matches it.
glob_covers() {  # glob_covers <pattern> <path> [up]
  GLOB_SRC="$1" GLOB_PATH="$2" GLOB_UP="${3:-}" awk 'BEGIN {
    s = ENVIRON["GLOB_SRC"]; n = length(s); re = ""
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (c == "*" && substr(s, i + 1, 2) == "*/" && (i == 1 || substr(s, i - 1, 1) == "/")) {
        re = re "(.*/)?"; i += 2
      } else if (c == "*") {
        re = re "[^/]*"
        while (substr(s, i + 1, 1) == "*") { i++ }
      } else if (c == "?") { re = re "[^/]" }
      else if (index(".^$+(){}|\\[]", c)) { re = re "\\" c }
      else { re = re c }
    }
    re = "^" re "$"
    p = ENVIRON["GLOB_PATH"]
    while (p != "") {
      if (p ~ re) { exit 0 }
      if (ENVIRON["GLOB_UP"] == "" || index(p, "/") == 0) { break }
      sub(/\/[^\/]*$/, "", p)
    }
    exit 1 }'
}

# ── entry form: the address a rule ACTUALLY points to ─────────────────────────
# The harness parses the form, and it differs from how the eye reads it:
#
#   `//path`        absolute path from the filesystem root — the only form by which the
#                   home registry closes a foreign tree;
#   `~/path`        from the home directory;
#   `/path`         from the SETTINGS SOURCE: for the home registry it is `~/.claude/path`, for
#                   the project one — the project root. A full filesystem path written with one
#                   slash closes NOTHING although it looks absolute;
#   `path`, `./path`  from the session directory — such an entry has no address until it is known
#                   where the session will be opened.
#
# The harness has five settings sources, each with its own one-slash anchor. Here there are two:
# home and project. `.claude/settings.local.json` is parsed as project although its anchor is the
# session LAUNCH directory, not the project root; they differ only in a session opened from a
# subdirectory. A deliberate default: both files are read as one list, and the verdict does not
# change — cleanliness requires closure by the HOME registry, and both branches give a nonzero code.
#
# Measured, not read from docs: a rule of each form was run through a live harness, judging by
# the file's presence on disk. A full path written with one slash lets the write through; `//` and
# `~/` stop it. There is ONE parse for the whole run — both list comparison and the wiring check
# call this function: two parses gave a rule counted in one step and invisible in another.
deny_addr() {  # deny_addr <rule entry> <registry: home|project> → address or empty
  # shellcheck disable=SC2088  # the tilde here is rule TEXT from a foreign file, not a shell path
  case "$1" in
    "~/"*) printf '%s' "$HOME/${1#"~/"}" ;;
    //*)   printf '%s' "${1#/}" ;;
    /*)    if [ "$2" = home ]; then printf '%s' "$HOME/.claude$1"; else printf '%s' "$HERE_LOG$1"; fi ;;
    *)     printf '' ;;
  esac
}

# Address of an entry IN THIS TREE — one parse for two consumers: an ordinary rule and a dead
# `Write`. A second copy would give "counted here, not visible there".
# Empty means "the entry is not about this tree": a foreign project from the shared home registry
# or a relative entry in it. The silence is deliberate — the output would grow with every project
# on the machine.
# Where an address lies against THIS tree: a path from its root; `**` for the root itself or for a
# literal directory above it (`<ancestor>` or `<ancestor>/**` — a directory target closes what is
# nested); nothing, with code 1, for another tree. A pattern above the root (`/x/repo-*/…`) is not
# read: which trees it names is not derived here, and the step stays red on them.
tree_own() {  # tree_own <address> → path from the tree root, `**`, or nothing
  local addr="$1" anc
  case "$addr" in
    "$HERE_ABS"/*) printf '%s' "${addr#"$HERE_ABS"/}"; return 0 ;;
    "$HERE_LOG"/*) printf '%s' "${addr#"$HERE_LOG"/}"; return 0 ;;
  esac
  anc="$(rule_norm "$addr")"; anc="${anc%/\*\*}"
  [ -n "$anc" ] || return 1
  # Quoted, the ancestor is compared literally: a pattern in it matches no real directory.
  case "$HERE_ABS/" in "$anc"/*) printf '**'; return 0 ;; esac
  case "$HERE_LOG/" in "$anc"/*) printf '**'; return 0 ;; esac
  return 1
}

rule_own() {  # rule_own <rule entry> <registry: home|project> → path from the tree root or empty
  local pat="$1" reg="$2" addr
  # A ONE-slash entry starting at the tree root does not address it — but speaks ABOUT it:
  # the owner wrote it about this path, so it cannot be left unmentioned.
  case "$pat" in
    "$HERE_ABS"/*) printf '%s' "${pat#"$HERE_ABS"/}"; return 0 ;;
    "$HERE_LOG"/*) printf '%s' "${pat#"$HERE_LOG"/}"; return 0 ;;
  esac
  addr="$(deny_addr "$pat" "$reg")"
  if [ -n "$addr" ]; then
    tree_own "$addr"
  elif [ "$reg" = project ]; then
    printf '%s' "$pat"
  fi
}

# In CI there is nobody to paste rules: no harness there, and the runner checkout root differs from
# the owner's machine — printed paths would be plausible and unfit, so the paste block stays silent:
# one line instead of the whole registry.
# The marker also decides the VERDICT on closure by the home registry (the `gap_local` block): that
# registry cannot address the runner checkout by construction. Other verdicts are untouched — but
# "untouched" does not mean "all observable": a path closed by ONE home rule is not covered by it in
# the runner checkout and arrives as "closed by nothing". It stays red deliberately.
# The presence check means `CI=false` also counts as the marker; other places of the box judge the
# marker the same way, and tightening the detector is a separate decision.
in_ci() { [ -n "${CI:-}${GITEA_ACTIONS:-}${GITHUB_ACTIONS:-}" ]; }

# ── paste-ready rules block ──────────────────────────────────────────────────
# A finding is handed over as text to paste, not as advice to add rules: which path to close with
# which tool is known to this run, not to the verdict reader.
#
# The path is printed ABSOLUTE — the rule goes to a file shared by all projects, where a relative
# one means nothing. The root is LOGICAL (`$PWD`): the owner sees the project by that path and
# compares by eye exactly it; the physical form is still accepted on read.
# An already absolute path is not prefixed with the root — otherwise the rule would point to a
# nonexistent place while the check after pasting stayed green and left the file open.
# A pattern (`.retainer/**`) stays a pattern: globs are not expanded here (`set -f` above), or
# file names that happen to be on disk would leak into the rules.
#
# Prints TEXT ONLY. Writing it is the owner's act: the engine does not write into foreign settings,
# neither itself nor under a key, and that is a boundary, not an omission.
deny_block() {
  local gaps="$1" path full rendered="" manual=""
  # Iterated LINE BY LINE: a space in a path is a legal file name, and word iteration tore such a
  # path into two rules, each closing the wrong file.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    # A backslash in a path would make the paste invalid JSON, and a broken settings file drops ALL
    # of deny at once. Such a path goes in a SEPARATE paragraph under the block: a comment inside
    # the block would itself make the pasted text invalid. A quote cannot occur: the `protected`
    # extractor strips them together with the entry delimiters.
    case "$path" in
      *'\'*)
        manual="$manual    $path
"
        continue ;;
    esac
    # Exactly TWO leading slashes — that is the "absolute path from the filesystem root" form.
    # One slash anchors the rule on the settings source (`~/.claude/…` for the home registry where
    # the block is pasted), and the printed rule would turn the check green over an open tree. The
    # slash is prepended to an already absolute path, not to a concatenation: `//` + absolute gave three.
    case "$path" in /*) full="/$path" ;; *) full="/$HERE_LOG/$path" ;; esac
    rendered="$rendered      \"Edit($full)\",
"
  done <<GAPS_EOF
$gaps
GAPS_EOF
  if in_ci; then
    echo "  Ready rules are not printed: CI run, nobody to paste them and nowhere to paste."
    return 0
  fi
  if [ -n "$manual" ]; then
    echo "  These paths are not printed as rules — they contain a backslash, pasting would break the settings JSON:"
    printf '%s' "$manual"
    echo
  fi
  [ -n "$rendered" ] || return 0
  echo "  Ready rules — paste into permissions.deny of ~/.claude/settings.json:"
  echo
  # Indent SIX spaces, not four: four is the findings-list indent, and parsing output by indent
  # (the test itself) would merge rules with addresses into one list. Different blocks, different
  # indent; the rules also read as one piece to copy whole.
  #
  # The last line has no comma: the block is declared paste-ready, and "drop the comma if it goes
  # at the end" is work shifted to the owner, costing broken JSON and a dropped deny.
  printf '%s' "$rendered" | sed '$ s/,$//'
  echo
}

# Registries are collected SEPARATELY: they close differently, and a merged list lost the difference.
found_project=""; found_home=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  [ -f "$path" ] && found_project="$found_project$path$NL"
done <<SETTINGS_EOF
$SETTINGS
SETTINGS_EOF
while IFS= read -r path; do
  [ -n "$path" ] || continue
  [ -f "$path" ] && found_home="$found_home$path$NL"
done <<HOME_SETTINGS_EOF
$HOME_SETTINGS
HOME_SETTINGS_EOF
found_settings="$found_project$found_home"

# "Nothing to compare against" and "nothing is closed" differ only for the comparison; for the
# project it is the same outcome: no path is closed under write tools. So the early exit prints the
# same ready rules as a finding — otherwise a fresh machine (no settings yet) would get "nothing to
# check" in exactly the state of maximum hole. The exit code stays: the check did not compare, and
# may not pass that off as a finding.
all_gaps() {
  local pat
  printf '%s\n' "$PROTECTED_RAW" | while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    # The same filter as the ordinary pass: an entry not reducing to a path (`**/secrets.env`) is not
    # printed as a rule there — and must not be here, or one input gets two answers depending on
    # whether settings exist on the machine.
    [ -n "$(stem "$pat")" ] || continue
    printf '%s\n' "$pat"
  done
}

[ -n "$found_settings" ] || {
  echo "▶ protected/deny reconciliation: no settings files — no path is closed against writes"
  deny_block "$(all_gaps)"; exit 3; }

# The whole `deny` block as text. Block bounds are the key name and the closing bracket: no JSON
# parsing is needed, the subject is path mentions inside the block.
deny_text() {  # deny_text <list of settings files, one per line>
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    sed -n '/"deny"[[:space:]]*:/,/\]/p' "$path"
  done <<DENY_TEXT_EOF
$1
DENY_TEXT_EOF
}
DENY_PROJECT="$(deny_text "$found_project")"
DENY_HOME="$(deny_text "$found_home")"
# Emptiness is checked on both at once and WITHOUT a third pass over the files: the concatenation
# answers only "is there a deny block anywhere", and as text it is unfit — substitution eats the
# newline, and the last project line would fuse with the first home one.
[ -n "$DENY_PROJECT$DENY_HOME" ] || {
  echo "▶ protected/deny reconciliation: no deny block in any settings file — no path is closed against writes"
  deny_block "$(all_gaps)"; exit 3; }

PROTECTED="$PROTECTED_RAW"


# Coverage is by path segments, not by substring: `hooks/guard.py` is not covered by a mention of
# `hooks/guard.py.bak`, while `.claude/**` covers `.claude/agents` — the same subtree named with
# different precision.
#
# Coverage is ONE-SIDED: only an entry that is wider or equal covers. The reverse — `.claude/**`
# under deny against one file in protected — is not coverage but exactly the case the step exists
# for: the harness closed the subtree, the guard watches one file, the rest of the subtree is unwatched.
#
# An entry of the list may be a pattern (rules keep theirs). `**` covers everything; a literal
# path or `<literal>/**` covers what lies under it; `<pattern>/**` covers what lies under a
# directory the pattern matches; a bare pattern covers an existing file it matches. A bracket is read as a
# literal character, so a bracket-class rule covers nothing but its own text — the class syntax is
# not parsed, and the error is red. A needle that is itself a pattern is covered by the same text,
# by `**`, or through its literal directory under a rule that closes a whole directory.
covered() {  # covered <path or pattern> <list of paths or patterns, one per line>
  local needle lit hay base up
  needle="$(rule_norm "$1")"
  case "$needle" in *[*?[]*) lit="$(lit_dir "$needle")" ;; *) lit="$needle" ;; esac
  while IFS= read -r hay; do
    [ -n "$hay" ] || continue
    [ "$hay" = "$needle" ] && return 0
    [ "$hay" = '**' ] && return 0
    base="$hay"; up=""
    case "$base" in */'**') base="${base%/\*\*}"; up=up ;; esac
    case "$base" in
      *[*?]*)
        if [ -n "$up" ]; then glob_covers "$base" "$lit" up && return 0
        # A bare pattern covers an entry only when it is a regular file on disk: matching a
        # directory is not taken to close its contents, and an entry not on disk may be either. The
        # literal directory of a pattern entry is a directory, so a pattern entry never gets here.
        elif [ -f "$lit" ]; then glob_covers "$base" "$lit" && return 0
        fi ;;
      *) case "$lit" in "$base" | "$base"/*) return 0 ;; esac ;;
    esac
  done <<EOF
$2
EOF
  return 1
}

# Membership of a path in the HOME registry — by the rule's address, not by the entry text. The
# comparison goes through `covered`, i.e. by segments: a pattern tail (`Edit(~/.claude/hooks/**)`)
# closes the whole directory, and comparing addresses head-on would lose that tail.
# The tool name is ANCHORED at the start of the entry, as in list comparison: cutting by the
# `Edit\(…\)` pattern finds `Edit(` inside `MultiEdit(`, and a rule about another tool would be
# counted as this one. The cost is that of any imaginary closure: guard wiring declared closed
# when `Edit` goes through it.
home_closes() {  # home_closes <tool> <path> → 0 if a home rule covers it
  local tool="$1" want="$2" rule pat addr list=""
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    pat="${rule#*(}"; pat="${pat%)}"
    addr="$(deny_addr "$pat" home)"
    [ -n "$addr" ] || continue
    # An address that starts with a pattern (`//**/hooks`) is not read as closure, as everywhere.
    [ -n "$(lit_dir "$(rule_norm "$addr")")" ] || continue
    list="$list$(rule_norm "$addr")$NL"
  done <<HOME_CLOSES_EOF
$(printf '%s' "$DENY_HOME" | grep -oE '[A-Za-z_][A-Za-z_0-9]*\([^)]*\)' | grep "^$tool(")
HOME_CLOSES_EOF
  covered "$want" "$list"
}

# The subject is narrowed to THIS project. The global settings list paths of all projects on the
# machine, and foreign ones do not bear on "do two registries agree HERE": their protected lives in
# their tree. The rule is taken whole, `tool(path)`: the path as the owner wrote it, the tool decides
# what the path is closed against.
# The root is taken in TWO forms: logical and resolved. On macOS `/tmp` and `/var` are symlinks, and
# the owner writes the form they see; comparing with one of them would drop the path of the project's
# OWN tree as foreign — silently, since foreign paths are skipped as routine.
#
# EACH registry is parsed separately and by the same parse: they differ not by entry form but by
# where the rule acts, and merging them into one list would decide that silently.
# The whole-tree and "does not reduce to a path" branches run AFTER the root cut: `Edit(<root>/**)`
# looks like a path before the cut and like the same whole tree as `Edit(**)` after it. Deciding
# before would give one claim four verdicts by entry form. A whole-tree rule is emitted as
# `tool|**`, and `covered` reads it as covering every entry.
# Rules are read LINE BY LINE, as they are printed: a file name with a space is legal, and word
# splitting tore the rule into a "path start" and a tail.
scan_rules() {  # scan_rules <deny block text> <registry: home|project> → `tool|path`,
  #                     `!unbound|entry`, `!homerel|entry`, `!anchor|entry`
  local rules rule tool pat addr own waddr reg="${2:-project}"
  rules="$(printf '%s' "$1" | grep -oE '[A-Za-z_][A-Za-z_0-9]*\([^)]*\)' | sort -u)"
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    # A rule argument without a parenthesis is not a path: declaring `-rf` from `Bash(rm -rf x)` an
    # unclosed path would demand adding it to protected.
    case "$rule" in *"("*) ;; *) continue ;; esac
    # A shell command is not a path: for `Bash(...)` the argument is a command with flags, and its
    # segments mean nothing in a path registry.
    case "$rule" in Bash\(*) continue ;; esac
    tool="${rule%%(*}"
    pat="${rule#*(}"; pat="${pat%)}"
    # The harness does not apply a `Write(path)` rule to file checks at all, so it is not closure in
    # any form or registry. The filter runs BEFORE the entry-form branches: advice "change the form
    # to `//…`" would be followed by the owner and answered by the next run with "now erase it" —
    # two rounds, the second created by this check.
    if [ "$tool" = Write ]; then
      # Exactly one stays silent: an entry addressing a FOREIGN tree — cut by the inner `*)` on the
      # parsed address. A relative entry has no tree at all: it is about the session launch dir, and
      # silence would mean it is never named in any project while the harness warns about it on
      # every start.
      waddr="$(deny_addr "$pat" "$reg")"
      case "$pat" in
        "$HERE_ABS"/*|"$HERE_LOG"/*) ;;   # about this tree, written with one slash
        *) case "$waddr" in
             # No address — the entry is relative: it has no tree, and silence would mean it is
             # never named in any project.
             "") ;;
             # The tree root, a directory above it, or a path inside: the same reading as an `Edit`
             # rule. Under a whole-tree entry the owner most likely thinks everything is closed, so it
             # cannot be left unmentioned; it suppresses the clean tick, because it closes nothing.
             # A foreign tree stays silent: output would grow with every project.
             *) tree_own "$waddr" >/dev/null || continue ;;
           esac ;;
      esac
      printf '!write_%s|%s\n' "$reg" "$pat"
      continue
    fi
    # An entry is reduced to an ADDRESS by one parse (`deny_addr`) — the one by which the wiring
    # step reads the registry. Two parses give "counted here, open there": a rule recognized as
    # closure in list comparison stayed invisible to the second step of the same run.
    # An entry with ONE slash starting at this tree's root is closure in no registry, and cannot be
    # left unmentioned: the owner sees it and thinks the path is closed. In the home registry it
    # points to `~/.claude/<root>/…`, in the project one to `<root>/<root>/…`.
    # Checked BEFORE the root cut and on the entry itself: after normalization the project case looks
    # like an address inside the tree and gave a finding on a nonexistent path, with advice to add
    # that phantom to `protected`. An entry of a FOREIGN tree does not get here and stays silent.
    case "$pat" in
      //*) ;;
      "$HERE_ABS"/*|"$HERE_LOG"/*) printf '!anchor|%s\n' "$pat"; continue ;;
    esac
    addr="$(deny_addr "$pat" "$reg")"
    if [ -n "$addr" ]; then
      own="$(tree_own "$addr")" || continue
    else
      # No address — the entry is relative, anchored at the session directory. In the project
      # registry it is parsed as is (the session is opened here, or the file is not read at all).
      own="$pat"
    fi
    # The whole tree: with an address in either registry, or relative in the project one. A
    # relative `**` in the HOME registry has no tree and stays "check by eye" below.
    if [ "$(rule_norm "$own")" = '**' ] && { [ -n "$addr" ] || [ "$reg" = project ]; }; then
      printf '%s|**\n' "$tool"
      continue
    fi
    if [ -z "$(stem "$own")" ]; then
      # A rule on the project root (`Edit(<root>/`) leaves neither a path nor a pattern after the
      # cut: printing an empty line in the "check by eye" block would tell the reader to check what
      # is not there. The `!unbound` label starts with a character impossible in a tool name — or a
      # foreign `unbound(x)` rule would land in the service list.
      [ -n "$own" ] || own="<project-root>"
      printf '!unbound|%s\n' "$own"
      continue
    fi
    # A relative entry in the HOME registry does not close this project: the settings file is shared
    # by all projects of the machine, and where such an entry points is a question not for the tree
    # but for where the session is opened. The filter runs AFTER the stem check: an entry not
    # reducing to a path stays what it was — "check by eye", not a finding with an address that
    # cannot be put in the registry.
    if [ -z "$addr" ] && [ "$reg" = home ]; then
      printf '!homerel|%s\n' "$pat"
      continue
    fi
    # A bracket class is not read, so such an `Edit` rule closes nothing here: it is named to
    # check by eye, and the reverse direction still judges it as a path.
    case "$tool|$own" in Edit\|*'['*) printf '!unbound|%s\n' "$own" ;; esac
    printf '%s|%s\n' "$tool" "$own"
  done <<SCAN_EOF
$rules
SCAN_EOF
}

# The parse is filtered by the label BEFORE the first vertical bar: a tool name does not contain
# it, while a path may — a legal file name.
tool_paths() {  # tool_paths <parse> <label>
  printf '%s\n' "$1" | awk -v mark="$2" '
    index($0, mark "|") == 1 { print substr($0, length(mark) + 2) }'
}

HOME_RULES="$(scan_rules "$DENY_HOME" home)"
PROJECT_RULES="$(scan_rules "$DENY_PROJECT" project)"
ANY_RULES="$HOME_RULES
$PROJECT_RULES"

# The reverse direction does NOT distinguish the registry: a path under a rule and outside
# `protected` is an observation hole wherever the rule is written. The guard does not know it either way.
# A whole-tree rule is not such a hole: it is wider than any `protected` list by design.
DENY_OWN="$(printf '%s\n' "$ANY_RULES" | awk '
  /^[^|]*\|\*\*$/ { next }
  /^!unbound\|/ { next }
  /^!homerel\|/ { next }
  /^!anchor\|/ { next }
  /^!write_/ { next }
  index($0, "|") > 1 { sub(/^[^|]*\|/, ""); print }')"

# Relative entries of the HOME registry: they do not point at this tree and are not closure.
# They cannot be left unmentioned — the owner sees the rule and thinks the path is closed.
homerel="$(tool_paths "$HOME_RULES" '!homerel' | sort -u)"
# One-slash entries that look like a path of this tree. Collected from BOTH registries: the form
# is unfit in either, only the address differs. Kept apart from relative ones: the advice differs —
# this one is replaced with a working form, that one is erased.
anchored="$(tool_paths "$ANY_RULES" '!anchor' | sort -u)"
# Dead `Write` entries. Kept AT parse time, not derived later: the advice depends on whether the
# path is closed by a working `Edit`, which is decided by address parsing. The registry name has no
# vertical bar, so the split is on the FIRST bar and a path with a bar stays whole.
writeopen=""   # among dead entries there is one under which the path is closed by nothing
writedead="$( { tool_paths "$HOME_RULES" '!write_home' | sed 's#^#home|#'
  tool_paths "$PROJECT_RULES" '!write_project' | sed 's#^#project|#'; } | sort -u)"

unbound=""   # the rule does not reduce to a path: neither a finding nor cleanliness
# The list is kept LINE BY LINE like all the others: a space in an entry is a legal file name, and
# a space-separated list printed such an entry on two lines, neither an address. Dedup compares the
# whole entry, with line boundaries.
while IFS= read -r own; do
  [ -n "$own" ] || continue
  case "$NL$unbound" in *"$NL$own$NL"*) continue ;; esac
  unbound="$unbound$own$NL"
done <<UNBOUND_EOF
$(tool_paths "$ANY_RULES" '!unbound')
UNBOUND_EOF

# Line by line too: the list is normalized whole, and word splitting here turned a path with a space
# into two entries before the comparison — a finding would be lifted by the wrong path.
# Both registries keep their patterns: `covered` reads them.
norm_list() {  # norm_list <list>
  while IFS= read -r raw; do
    [ -n "$raw" ] || continue
    rule_norm "$raw"; echo
  done <<NORM_EOF
$1
NORM_EOF
}
PROTECTED_NORM="$(norm_list "$PROTECTED")"
HOME_EDIT_NORM="$(norm_list "$(tool_paths "$HOME_RULES" Edit)")"
ANY_EDIT_NORM="$(norm_list "$(tool_paths "$ANY_RULES" Edit)")"


gap_guard=""   # under deny but outside protected — an observation hole
gap_deny=""    # under the guard but open to the write tool — held by nothing
gap_local=""   # closed, but only for sessions of this directory — a write from another one goes through
# Rules are printed for what is missing IN THE HOME registry, not for what is missing altogether:
# a paste must close the path in one go, and a path held by a project rule would stay red even
# after the owner did what was printed.
insert_gaps=""

# The report is by paths, the lists by entries: one path arrives from the project and global
# settings in different forms, and without merging it would be named a finding twice.
seen_deny=" "; seen_guard=" "
# Entries are iterated LINE BY LINE: a space in a path is a legal file name, and word iteration made
# one path into two, each judged separately. In the verdict that gave two nonexistent addresses, and
# in the printed rules — two rules closing the wrong file.
while IFS= read -r pat; do
  [ -n "$pat" ] || continue
  key="$(stem "$pat")"
  if [ -z "$key" ]; then
    case "$NL$unbound" in *"$NL$pat$NL"*) continue ;; esac
    unbound="$unbound$pat$NL"
    continue
  fi
  # Closure is computed TWICE: by the home registry (acts regardless of the launch dir) and by both
  # (closes somewhere). The difference between the answers is exactly the protection that depends
  # on where the session is opened.
  covered "$pat" "$HOME_EDIT_NORM" && continue
  dkey="$(rule_norm "$pat")"; dkey="${dkey%/\*\*}"
  case "$seen_deny" in *" $dkey "*) continue ;; esac
  seen_deny="$seen_deny$dkey "
  insert_gaps="$insert_gaps$pat
"
  # Not closed anywhere — the path is held by nothing. Closed, but only by the project registry — a
  # verdict about the launch dir: the rule exists, but does not act everywhere. One path does not go
  # into both lists: the advice to the owner differs.
  if covered "$pat" "$ANY_EDIT_NORM"; then
    gap_local="$gap_local$pat
"
  else
    gap_deny="$gap_deny$pat
"
  fi
done <<PROTECTED_EOF
$PROTECTED
PROTECTED_EOF
while IFS= read -r own; do
  [ -n "$own" ] || continue
  covered "$own" "$PROTECTED_NORM" && continue
  dkey="$(rule_norm "$own")"; dkey="${dkey%/\*\*}"
  case "$seen_guard" in *" $dkey "*) continue ;; esac
  seen_guard="$seen_guard$dkey "
  gap_guard="$gap_guard$own
"
done <<DENY_OWN_EOF
$DENY_OWN
DENY_OWN_EOF

rc=0
if [ -n "$gap_guard" ]; then
  echo "✗ under deny, but not under the guard — the guard does not know these paths:"
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    printf '    %s\n' "$pat"
  done <<GAP_GUARD_EOF
$gap_guard
GAP_GUARD_EOF
  echo "  The project registry does not name them: a config reader thinks they are open. Add them to protected."
  rc=1
fi
if [ -n "$gap_deny" ]; then
  echo "✗ under the guard, but open to the write tool — nobody will stop an edit of these:"
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    printf '    %s — no Edit rule\n' "$pat"
  done <<GAP_EOF
$gap_deny
GAP_EOF
  echo "  The guard judges only Bash; edit tools are held by deny alone, and they are held by the Edit"
  echo "  rule — it applies to all of them at once."
  rc=1
fi
if [ -n "$gap_local" ]; then
  # In CI this verdict is not issued: the home registry is a property of the MACHINE, not the
  # repository, its rules address the owner's tree, and they cannot match the runner checkout root.
  # The list is printed — the finding does not vanish — but the exit code is not raised.
  # Head and tail are kept WHOLE in variables: the tail is one sentence over two lines, and printing
  # it by halves gave a stub that reads as finished output.
  if in_ci; then
    gap_local_head="▶ closure by the home registry is not judged here — CI run:"
    gap_local_tail="  Home-registry rules address the owner's tree, and the runner checkout lives in another
  root: \"not seen\" here does not mean \"not closed\". A local run issues the verdict."
  else
    gap_local_head="✗ closed only for sessions of this directory — a session from another directory will write to it:"
    gap_local_tail="  The project settings apply only to a session opened in this directory. From anywhere else
  the rule is not read, and a write to the path goes through. Duplicate it in the home registry."
    rc=1
  fi
  echo "$gap_local_head"
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    printf '    %s — Edit rule only in the project registry\n' "$pat"
  done <<GAP_LOCAL_EOF
$gap_local
GAP_LOCAL_EOF
  printf '%s\n' "$gap_local_tail"
fi
# ONE block is printed for both verdicts: it is pasted whole, and two blocks in a row would be
# merged by hand into one list — with that very comma in the middle the paste-ready block avoids.
[ -n "$insert_gaps" ] && deny_block "$insert_gaps"
# ── PROJECT CORE: membership, not agreement ───────────────────────────────────
# Everything above judges AGREEMENT of two registries, so a consensual removal passes green: the
# path is removed from both `protected` and `deny` — no divergence, and no protection either. The
# cheapest mutation was the least visible: nothing left to compare, and the step answered "agree".
#
# The core is not a list of names (every project has its own files) but what makes protection stop
# being readable or open without the owner: the config itself, the unlock key, the gate command.
# Their membership in `protected` is REQUIRED, not compared: a registry emptied of everything must
# go red, not count as clean.
#
# The stand is exempt, and that is no relaxation: it declares itself by the machine marker
# `stand = true`, its `protected` is empty ON PURPOSE — a stand exists to edit the protected
# without the owner's key, and control moves to promotion. Demanding the core of it would turn the
# development tool red. The skip is said aloud: a silent one is indistinguishable from a passed check.
# Config keys are read ONLY before the first table and in both quote forms — as the guard reads
# them. A parse accepting one form would be defeated by a quote-style or indent change, i.e. an edit
# that reads as formatting.
cfg_top() {  # cfg_top <key>
  awk -v key="$1" '
    /^[[:space:]]*\[[A-Za-z_]/ { exit }
    $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
      sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, "")
      sub(/[[:space:]]+$/, ""); gsub(/^["\047]|["\047]$/, "")
      val = $0
    }
    END { print val }' "$CONFIG" 2>/dev/null
}

core_gap=""
core_note=""
# The stand marker is not honored on self-declaration: the config whose membership the check
# protects cannot serve as its own excuse — or one line in it lifts the verdict along with the
# explanation. A stand is told apart by what a project cannot fake: its tree IS the box the script
# runs from. For a managed project the gate calls the engine from elsewhere, and the equality is false.
BOX_ABS="$(cd "$BOX" 2>/dev/null && pwd -P)"
if [ "$(cfg_top stand)" = "true" ] && [ "$HERE_ABS" = "$BOX_ABS" ]; then
  echo "▶ core not checked: the engine tree is run on itself — this is a stand"
else
  # The unlock key is required even where it is not declared: the guard then takes its default,
  # i.e. the file exists and opens the protection. Demanding membership of the declared one and
  # staying silent on the undeclared would lock one door and leave an identical one open next to it.
  core_unlock="$(cfg_top unlock_file)"
  if grep -qE '^[[:space:]]*unlock_file[[:space:]]*=' "$CONFIG" && [ -z "$core_unlock" ]; then
    # An empty value is a SEPARATE finding, not a caveat to the path list: in the guard the key path
    # collapses to the repository root, the root's mtime is always fresher than the threshold, and
    # the project is unlocked permanently. Covering the default in the registry does not cure this.
    core_note="yes"
  fi
  [ -n "$core_unlock" ] || core_unlock=".retainer/unlock"

  # `gate_command` is a command, not a path: the engine canon writes it as `bash scripts/gate.sh`.
  # Requiring membership of the whole string means requiring an entry that cannot exist in `protected`.
  core_gate="$(cfg_top gate_command | sed -E 's/^[[:space:]]*(bash|sh|python3?|zsh)[[:space:]]+//; s/[[:space:]].*$//')"
  # Not every gate command reduces to a path: `make gate` is a build target, no file behind it.
  # Requiring membership of the word `make` would print a finding that cannot be closed.
  case "$core_gate" in */*) ;; *) core_gate="" ;; esac

  core_paths="$CONFIG
$core_unlock"
  [ -n "$core_gate" ] && core_paths="$core_paths
$core_gate"

  while IFS= read -r cpath; do
    [ -n "$cpath" ] || continue
    covered "$cpath" "$PROTECTED_NORM" || core_gap="$core_gap
$cpath"
  done <<CORE_EOF
$core_paths
CORE_EOF
fi

if [ -n "$core_note" ]; then
  echo "✗ the unlock key is declared EMPTY — the guard treats the whole repository as unlocked:"
  echo "    unlock_file = \"\" in $CONFIG"
  echo "  The key path collapses to the tree root, and its mtime is always fresher than the unlock threshold."
  echo "  Either name the key as a path or do not declare it at all — then the default applies."
  rc=1
fi
if [ -n "$core_gap" ]; then
  echo "✗ unprotected: what the protection itself rests on — registry agreement will not show it:"
  while IFS= read -r cpath; do
    [ -n "$cpath" ] || continue
    printf '    %s — not covered by any protected entry\n' "$cpath"
  done <<CORE_GAP_EOF
$core_gap
CORE_GAP_EOF
  echo "  Without the config the protection cannot be read, without the key it cannot be opened at the"
  echo "  owner's will, without the gate command it cannot be verified. These paths must always be under protected."
  rc=1
fi

# ── the guard's global self-protection against deny ──────────────────────────
# The paths by which the guard is wired (`~/.claude/settings.json`, `~/.claude/hooks`, the managed
# registry, the global key) lie OUTSIDE the repositories, and no project's `protected` has them — there is nothing
# to compare them with the project list. They are closed by an `Edit` rule — the same as everywhere:
# it applies to all edit tools, and a `Write` rule next to it adds nothing.
#
# The list is taken FROM THE GUARD ITSELF as machine output (`--global-protected`): a second list
# of our own would drift from it silently — the same class this step exists for.
#
# Counted by the HOME registry, and that is not incidental: wiring paths lie outside repositories,
# and a project rule does not act on them in any session except the one opened here — including the
# one from which the guard is edited. A counted project rule would mean a green verdict over the
# protection of the whole machine, removable by one entry from a neighboring directory.
GUARD="$BOX/hooks/guard_discipline.py"
if [ -f "$GUARD" ] && command -v python3 >/dev/null 2>&1; then
  global_gap=""
  # Wiring paths lie under `$HOME`, and a space in the machine owner's name is common: word
  # iteration tore such a path into two addresses, neither of which existed.
  while IFS= read -r gpath; do
    [ -n "$gpath" ] || continue
    gmiss=""
    # The registry is read by the SAME normalization as in list comparison, not by text search.
    # Substring search did not tell forms apart, and here the difference is the opposite: `Edit(/hooks)`
    # in the home registry points to `~/.claude/hooks` — exactly the wiring, and truly closes it —
    # while `Edit(/Users/…/.claude/hooks)` closes nothing. As text they look alike.
    home_closes Edit "$gpath" || gmiss="Edit"
    [ -n "$gmiss" ] || continue
    global_gap="$global_gap$gpath
"
  done <<GLOBAL_EOF
$(python3 "$GUARD" --global-protected 2>/dev/null)
GLOBAL_EOF
  if [ -n "$global_gap" ]; then
    echo "✗ guard wiring open to the write tool — one edit switches the protection off:"
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      printf '    %s — no Edit rule\n' "$item"
    done <<GLOBAL_GAP_EOF
$global_gap
GLOBAL_GAP_EOF
    echo "  These paths lie outside the repositories; a project key neither opens nor closes them. The rules"
    echo "  are added to the harness home settings — the owner does this."
    rc=1
  fi
fi

if [ -n "$writedead" ]; then
  echo "▶ Write rules — the harness does not apply them:"
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    wreg="${item%%|*}"; wpat="${item#*|}"
    # The advice depends on whether the path is closed by a WORKING `Edit`, not on whether an entry
    # of that name lies nearby: an `Edit` rule of an unfit form is not closure, and "erase, the pair
    # holds" would be a lie over it. A HOME entry is judged by the home registry: calling it a
    # duplicate next to a project-only `Edit` would contradict the verdict above, where the path is
    # named closed only for sessions of its directory. A project entry is judged by both registries —
    # closure by a home rule is legitimate there, and "erase" over it is right.
    case "$wreg" in home) wlist="$HOME_EDIT_NORM" ;; *) wlist="$ANY_EDIT_NORM" ;; esac
    if covered "$(rule_own "$wpat" "$wreg")" "$wlist"; then
      printf '    Write(%s) — path is closed by an Edit rule, erase this entry\n' "$wpat"
      continue
    fi
    # Below are entries under which the path is closed by NOTHING. They suppress the clean tick: the
    # owner sees the rule, thinks the path is closed and reads the output top to bottom, and a
    # "✔ agree" under a line about an unclosed path answers their question with an untruth. A
    # duplicate next to a working `Edit` does not suppress the tick — no false "closed" arises there.
    #
    # ONE advice for all entry forms. Splitting it by form — relative, one slash, pattern, tree
    # root — would say the same thing in four texts: the entry does not work, erase it, and write the
    # closure as an `Edit` rule in an addressable form. This very text names the form, and which
    # path to close is the subject of the neighboring blocks.
    writeopen="yes"
    printf '    Write(%s) — erase: gives no closure, only Edit closes\n' "$wpat"
  done <<WRITEDEAD_EOF
$writedead
WRITEDEAD_EOF
  echo "  The harness file checks match only Edit(path) — it holds a write by all edit tools at"
  echo "  once. Closing form — //<full path> or ~/<path from home>."
  echo "  While an entry lies in the registry, the harness prints a warning about it on every start."
fi

if [ -n "$anchored" ]; then
  echo "▶ entries with a single slash — they do not close this path:"
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    printf '    %s\n' "$rule"
  done <<ANCHORED_EOF
$anchored
ANCHORED_EOF
  echo "  A single slash anchors on the settings SOURCE, not on the filesystem root: in the home"
  echo "  registry it is ~/.claude/<path>, in the project one — <project root>/<path>. A full path"
  echo "  written so points to a place that does not exist although it looks absolute. REPLACE the entry with the form"
  echo "  //<full path> or ~/<path from the home directory>: while the old one lies in the registry, this"
  echo "  block is printed on every run, and the clean verdict is never printed."
fi

if [ -n "$homerel" ]; then
  echo "▶ relative entries in the home registry — they do not point at this project:"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    printf '    %s\n' "$rel"
  done <<HOMEREL_EOF
$homerel
HOMEREL_EOF
  echo "  The settings file is shared by all projects of the machine, and a relative entry in it does not point at"
  echo "  this tree. A path is closed by //<full path> or ~/<path from the home directory> —"
  echo "  write it in and erase the relative one: while it lies in the registry, this block is printed on"
  echo "  every run. One slash is not enough: it anchors the entry on the settings file itself."
fi

if [ -n "$unbound" ]; then
  echo "▶ rule does not reduce to a path — check by eye:"
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    printf '    %s\n' "$pat"
  done <<UNBOUND_PRINT_EOF
$unbound
UNBOUND_PRINT_EOF
  echo "  The entry starts with a pattern, holds a bracket class or names the tree root with a trailing"
  echo "  slash: it is not read as closure, and which file is meant cannot be derived from here."
  echo "  The step verdict does not change — worth knowing."
fi
# The clean line is suppressed by `homerel` and `unbound` alike: both categories mean "something was
# not understood", not "everything agrees". An owner who wrote a relative rule reads the output top
# to bottom and decides by the tick that the path is closed — exactly the reading the check exists against.
# `anchored` also suppresses the tick: a path named by an entry of the wrong form may not be in
# `protected` at all — then there is no finding, the code is zero, and the tick would be printed right
# under the line saying the entry anchors in the wrong place.
# `writeopen` also suppresses it — a dead entry over a path closed by nothing: there may be no
# verdict before it at all (the path is not in `protected`), while the reader decides by the tick.
# The tick names what it does NOT cover: in CI closure by the home registry is not judged, and the
# output is read top to bottom and decided by it. The branch is reachable only in CI — outside it a
# nonempty `gap_local` raises the exit code, and the tick is never reached.
if [ "$rc" = 0 ] && [ -z "$unbound" ] && [ -z "$homerel" ] && [ -z "$anchored" ] &&
  [ -z "$writeopen" ]; then
  if [ -n "$gap_local" ]; then
    echo "✔ protected and deny registries agree — except closure by the home registry: not judged in CI"
  else
    echo "✔ protected and deny registries agree"
  fi
fi
exit "$rc"
