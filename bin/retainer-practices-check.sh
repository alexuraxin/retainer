#!/usr/bin/env bash
# retainer: the project practices record form is enforced on the rules the diff touched.
#
#   retainer-practices-check.sh [project dir]
# exit 0 -- every touched rule carries the form · 1 -- a touched rule has no address or no date
#      3 -- no targets: no .retainer/practices.md, or the diff touched no recorded rule (a freshly
# scaffolded file with no rules yet is "no targets", not a failure)
#      2 -- usage, or the check cannot run (no git, or the config library is not next to the script)
#
# WHY DIFF-TOUCHED ONLY. Judging the whole file would redden a project's gate on legacy rules it did
# not edit this task; that old debt is cleared in the project by its own tracker, not here. A rule is
# "touched" when the diff changed a line of its block, and only then is its form required (ratchet up).
#
# FORM (presets/practices.md.template): `Sample: <file>:<line>` for the address and `Distilled: <date>`
# for when it was taken from the code. Without an address a rule cannot be checked against the tree;
# without a date a stale rule reads as a fresh one, and the reader cannot tell them apart.
#
# complexity: keep, step 2 -- reuses the gate-step form (retainer-doc-claims.sh) and the diff-touched
# collection (retainer-prose-lang.sh); the practices record form is held by nothing otherwise.
set -uo pipefail
CFGLIB="$(cd "$(dirname "$0")" && pwd)/retainer-config.sh"   # before cd into the project: the script's path
[ -f "$CFGLIB" ] || {
  echo "✗ practices form: retainer-config.sh is not next to the script -- the check does NOT work" >&2; exit 2; }
# shellcheck source=bin/retainer-config.sh
. "$CFGLIB"

DIR="${1:-.}"
[ -d "$DIR" ] || { echo "usage: retainer-practices-check.sh [project dir]" >&2; exit 2; }
cd "$DIR" || exit 2

command -v git >/dev/null 2>&1 || {
  echo "✗ practices form: no git -- the touched rules cannot be collected, the check does NOT work" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "▶ practices form: not a git repository -- nothing to check"; exit 3; }

PRACTICES=".retainer/practices.md"
[ -f "$PRACTICES" ] || { echo "▶ practices form: no $PRACTICES -- nothing to check"; exit 3; }

BASE="$(retainer_base_ref .)"

# The new-file line numbers the diff changed in the practices file, from the base plus the unstaged and
# staged changes -- so the gate sees the working tree it is about to publish. `--unified=0` gives the
# exact lines; a hunk header `@@ -a,b +c,d @@` names new lines c..c+d-1 (d defaults to 1).
new_lines() {
  awk '/^@@/ {
    if (match($0, /\+[0-9]+(,[0-9]+)?/)) {
      spec = substr($0, RSTART + 1, RLENGTH - 1); n = split(spec, a, ","); cnt = (n > 1 ? a[2] : 1);
      for (i = 0; i < cnt; i++) print a[1] + i;
    }
  }'
}
# Porcelain diff output follows the user's config and attributes: with colour, an external diff tool,
# a textconv filter or a `-diff` attribute no line starts with `@@`, and a touched rule would read as
# untouched. A user's inter-hunk context would merge two hunks and mark the rules between them touched.
DIFF=(--no-ext-diff --no-color --no-textconv --text --inter-hunk-context=0)
unset GIT_DIFF_OPTS   # its context option is applied after -U0 and would widen every hunk
CHANGED="$(
  { [ -n "$BASE" ] && git diff "${DIFF[@]}" --unified=0 "$BASE"...HEAD -- "$PRACTICES" 2>/dev/null
    git diff "${DIFF[@]}" --unified=0 -- "$PRACTICES" 2>/dev/null
    git diff "${DIFF[@]}" --unified=0 --cached -- "$PRACTICES" 2>/dev/null
  } | new_lines | sort -un | tr '\n' ' ')"

[ -n "$CHANGED" ] || { echo "▶ practices form: the diff did not touch $PRACTICES -- nothing to check"; exit 3; }

# Parse rules of BOTH forms (`**rule**` as a paragraph and `- **rule**` as a list item), bound each
# block by the next rule or the next `#` section header, keep the ones a changed line falls into, and
# require the address and the date inside that block.
REPORT="$(awk -v changed="$CHANGED" '
  BEGIN { n = split(changed, ca, " "); for (i = 1; i <= n; i++) if (ca[i] != "") chg[ca[i]] = 1; rules = 0; cur = 0; }
  /^#+[[:space:]]/ { cur = 0; next; }                                  # a markdown header (# , ## , …) ends the block; a prose "#91" does not
  /^(- )?\*\*/    { rules++; cur = rules; start[cur] = NR; last[cur] = NR; blk[cur] = $0 "\n"; next; }
                  { if (cur > 0) { blk[cur] = blk[cur] $0 "\n"; last[cur] = NR; } }
  END {
    touched = 0; failed = 0;
    for (r = 1; r <= rules; r++) {
      hit = 0;
      for (L = start[r]; L <= last[r]; L++) if (L in chg) { hit = 1; break; }
      if (!hit) continue;
      touched++;
      b = blk[r];
      addr = (b ~ /Sample:[[:space:]]*[A-Za-z0-9_.\/-]+:[0-9]+/);
      date = (b ~ /Distilled:[[:space:]]*[0-9]/);
      if (addr && date) continue;
      failed++;
      miss = "";
      if (!addr) miss = miss " an address (Sample: <file>:<line>)";
      if (!date) miss = miss " a date (Distilled: <date>)";
      printf "  ✗ %s:%d -- the touched rule lacks%s\n", FILENAME, start[r], miss;
    }
    printf "RESULT rules=%d touched=%d failed=%d\n", rules, touched, failed;
  }
' "$PRACTICES")"

TOUCHED="$(printf '%s\n' "$REPORT" | sed -n 's/^RESULT .*touched=\([0-9]*\).*/\1/p')"
FAILED="$(printf '%s\n' "$REPORT" | sed -n 's/^RESULT .*failed=\([0-9]*\)$/\1/p')"
FINDINGS="$(printf '%s\n' "$REPORT" | grep -v '^RESULT ' || true)"

# No recorded rule the diff touched -- a file with no rules yet (a fresh scaffold), or a diff that
# changed only prose. The record form recognizes one kind of entry: a `**bold**` rule phrase. Prose
# that is not a rule carries no bold lead, so "nothing recognized" is "no rules", not a broken check.
[ "${TOUCHED:-0}" = 0 ] && { echo "▶ practices form: no recorded rule the diff touched -- nothing to check"; exit 3; }
if [ "${FAILED:-0}" != 0 ]; then
  printf '%s\n' "$FINDINGS"
  echo "✗ practices form: $FAILED touched rule(s) without the form. Without an address a rule cannot be checked against the tree; without a date a stale rule reads as fresh."
  echo "  Form: Sample: <file>:<line>   ·   Distilled: <date>  (presets/practices.md.template)."
  exit 1
fi
echo "✔ practices form: $TOUCHED touched rule(s) carry the address and the date"
exit 0
