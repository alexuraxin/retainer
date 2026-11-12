#!/usr/bin/env bash
# retainer: the volume of mandatory reading and reports inside the policy.
# Criterion: a heading with a checkmark — or "done"/"closed"/"completed" next to a date — is a
# REPORT, not a rule. A bare "Definition of Done" (no date, no ✅) is a rule and must not flag.
#
#   retainer-hot-context.sh [project dir] [--budget N] [--cold-budget N]
# exit 0 — clean · 1 — bloated OR what is declared does not match the document · 2 — usage · 3 —
#          no instructions, no targets. Two reproaches under one code, but not one text:
#          a mismatch is not cured by a budget, and the `--budget` hint is not attached to it.
#
# LAYERING. The project document is read by TWO mechanisms and differently: sections declared with
# the "start" key are fed into context at every session start, the rest selectively, one section
# per kind of file being edited. Judging them by one budget means either forbidding the project a
# detailed document or allowing what always sits in context to bloat. So the core is judged by
# `--budget` and the cold layer by `--cold-budget`.
#
# Layering is switched on by `hooks/project_context.py` reading the table. There is deliberately no
# parser of its own here: the table has three readers, and a third copy of the parser would drift
# silently.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

DIR="."; BUDGET=400; COLD_BUDGET=800
usage(){ echo "usage: retainer-hot-context.sh [dir] [--budget N] [--cold-budget N]" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --budget) BUDGET="${2:?}"; shift 2 ;;
    --cold-budget) COLD_BUDGET="${2:?}"; shift 2 ;;
    -*) usage ;;
    *) DIR="$1"; shift ;;
  esac
done
case "$BUDGET" in ''|*[!0-9]*) echo "--budget: number only" >&2; exit 2 ;; esac
case "$COLD_BUDGET" in ''|*[!0-9]*) echo "--cold-budget: number only" >&2; exit 2 ;; esac
[ -d "$DIR" ] || usage
cd "$DIR" || exit 2

# What counts as mandatory reading: the agent instructions + the policy declared in the config.
#
# There are TWO queues and they must not be added together. A project may have several readers and
# their reading orders do not intersect: Claude Code goes through CLAUDE.md and the policy, an
# external agent (Codex, Roo Code, Gemini CLI) loads AGENTS.md on every request and does not know
# CLAUDE.md at all. The sum is a volume that NOBODY reads: neither queue exceeds the budget, yet
# the step would be red with no way to clear it — both files are under native deny, and the agent
# cannot edit them under any key.
# A queue is a NEWLINE-separated list, not a space-separated one: a document name with a space
# (`my context.md`) would split into two nonexistent files.
NL="
"
DOCS=""
AGENTS_DOCS=""
# Documents the reader loads WHOLE. They cannot be layered: the premise of layering is "the rest
# is not in context, it is fed selectively", while the entry point, the policy and tooling lie there
# in full. The criterion here is ORIGIN, not the file name: a list of names does not close it — the
# same document can be declared both as the policy and as the project context, and then the volume
# measurement would be switched off by one config line.
WHOLE=""
add(){ [ -n "$1" ] && [ -f "$1" ] && case "$NL$DOCS$NL" in *"$NL$1$NL"*) ;; *) DOCS="$DOCS$1$NL" ;; esac; }
add_agents(){ [ -n "$1" ] && [ -f "$1" ] && case "$NL$AGENTS_DOCS$NL" in *"$NL$1$NL"*) ;; *) AGENTS_DOCS="$AGENTS_DOCS$1$NL" ;; esac; }
whole(){ [ -n "$1" ] && [ -f "$1" ] && WHOLE="$WHOLE$1$NL"; }
add CLAUDE.md; whole CLAUDE.md
for f in .retainer/PROJECT.md .foreman/PROJECT.md; do add "$f"; done
add_agents AGENTS.md; whole AGENTS.md
# The value of a [docs] key with the TRAILING COMMENT cut off. The `sed | tr -d '" '` form did not
# strip it: a line `regulations = "AGENTS.md"   # project policy: …` gave the name
# `AGENTS.md#projectpolicy:…`, no such file exists, and the declared document silently dropped out
# of the measurement — the step looked fine over an unchecked document.
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
# The `project_context` key is NOT read here: the library reads it, and its answer arrives as the
# summary below. A second reader of one key would drift from the first silently.
REGS="$(cfg_doc regulations)"; add "$REGS"; whole "$REGS"
# The policy goes by different names, and naming it in the config gets forgotten — yet it is the
# one that grows with reports. Overlooking the thickest document yields a measurement that looks fine.
for f in tooling.md docs/tooling.md tooling*.md; do add "$f"; whole "$f"; done

# ── layering of the project document ───────────────────────────────────────────────────────────
# We ask the same library the hooks use: core lines, cold-layer lines, whether the project declared
# the table, whether it has "start", which declared sections were not found in the document.
# The parse is not repeated here: three copies of one parser drift silently — a class the engine
# guards separately.
HOT_DOC=""; HOT_LINES=0; COLD_LINES=0; OWN_TABLE=0; CORE_DECLARED=0; LOST=""
STRATA="$(HOOKS="$HERE/../hooks" ROOT="$PWD" python3 - 2>/dev/null <<'PYSTRATA'
import os
import sys
from pathlib import Path

sys.path.insert(0, os.environ["HOOKS"])
import project_context

root = Path(os.environ["ROOT"]).resolve()
report = project_context.audit(Path(os.environ["ROOT"]))
# The path is returned RELATIVE: the measurement queue uses relative names while the library
# resolves links, and on macOS `/tmp` is itself a link — a string prefix cut would miss, and the
# document would land in the queue twice, whole and as core.
named = report["document"]
fields = (
    str(Path(str(named)).relative_to(root)) if named else "",
    str(report["core"]),
    str(report["layer"]),
    "1" if report["project_table"] else "0",
    "1" if report["core_declared"] else "0",
    # An empty section name is a finding too: the project wrote a rule that does nothing.
    # Without the substitution it would collapse into an empty string and the step would stay silent.
    "; ".join(str(name) or "(empty section name)" for name in report["missing"]),
)
sys.stdout.write("\n".join(fields))
PYSTRATA
)"
if [ -n "$STRATA" ]; then
  # One field per line, not tab-separated: a tab is a WHITESPACE character, and `read` with it in
  # IFS swallows a leading empty field. No document -> first field empty -> all six values
  # shifted to one, and the "declared section not found" finding was lost exactly when nothing is
  # fed at all.
  {
    read -r HOT_DOC
    read -r HOT_LINES
    read -r COLD_LINES
    read -r OWN_TABLE
    read -r CORE_DECLARED
    read -r LOST
  } <<EOF
$STRATA
EOF
  # The library answers with an absolute path, the queue uses relative ones — bring to one form.
  HOT_DOC="${HOT_DOC#"$PWD/"}"
  [ -n "$HOT_DOC" ] && [ -f "$HOT_DOC" ] || HOT_DOC=""
  # The project document enters the queue FROM HERE: the library reads the key, not a second parse here.
  add "$HOT_DOC"
  # The same document may have entered the queue as read whole — as the policy, tooling or an entry
  # point. Then it cannot be layered: it lies in context in full.
  case "$NL$WHOLE" in *"$NL$HOT_DOC$NL"*) HOT_DOC="" ;; esac
fi
[ -n "$DOCS$AGENTS_DOCS" ] || { echo "▶ hot context: no instructions found"; exit 3; }

# A queue = (reader, files). Each is counted separately and judged by its own budget.
total=0
stale=0
report=""
queue_over=0
measure(){
  total=0
  stale=0
  report=""
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    n="$(wc -l < "$doc" | tr -d ' ')"
    # The project document enters the core queue by its DECLARED sections, not whole: the rest is
    # not in context — it is fed selectively and judged by its own budget below.
    unit="lines"
    [ -n "$HOT_DOC" ] && [ "$doc" = "$HOT_DOC" ] && { n="$HOT_LINES"; unit="core lines"; }
    total=$((total + n))
    # A report section: a heading with a checkmark, or "done"/"closed"/"completed" plus a date.
    s="$(grep -cE '^#{2,4} .*✅|^#{2,4} .*([Dd]one|[Cc]losed|[Cc]ompleted).*[0-9]{4}-[0-9]{2}' "$doc" 2>/dev/null | head -1)"
    s="${s:-0}"
    stale=$((stale + s))
    report="$report  · $doc — $n $unit, report sections: $s
"
  done <<MEASURE
$1
MEASURE
}

# $1 — reader (for the report), $2 — queue files. Prints the queue summary, accumulates red flags.
show_queue(){
  [ -n "$2" ] || return 0
  measure "$2"
  printf '▶ hot context · %s: %s lines (budget %s)\n' "$1" "$total" "$BUDGET"
  printf '%s' "$report"
  [ "$total" -gt "$BUDGET" ] && {
    queue_over=1
    over_msg="$over_msg  Queue '$1': $total lines against a budget of $BUDGET. Every closed wave appends its own report here.
"
  }
  [ "$stale" -gt 0 ] && stale_total=$((stale_total + stale))
  return 0
}

stale_total=0
over_msg=""
show_queue "Claude Code" "$DOCS"
show_queue "external agent (AGENTS.md)" "$AGENTS_DOCS"

# The cold layer has its own queue and budget: it is fed one section per kind of file being edited,
# and does not sit in context always.
lost_msg=""
if [ -n "$HOT_DOC" ]; then
  printf '▶ hot context · project cold layer: %s lines (budget %s)\n' \
    "$COLD_LINES" "$COLD_BUDGET"
  printf '  · %s — core %s lines, cold layer %s lines\n' "$HOT_DOC" "$HOT_LINES" "$COLD_LINES"
  [ "$COLD_LINES" -gt "$COLD_BUDGET" ] && {
    queue_over=1
    over_msg="$over_msg  Project cold layer: $COLD_LINES lines against a budget of $COLD_BUDGET.
"
  }
fi

# A mismatch of what is DECLARED with the document. Only the PROJECT table is judged: on the shipped
# default a missing section is normal (not every project has one), and going red on it would be red
# by construction.
if [ "$OWN_TABLE" = 1 ]; then
  [ -n "$LOST" ] && lost_msg="$lost_msg  Declared but not found in the document: $LOST.
  A renamed heading silences the feed SILENTLY — the mechanism feeds what it found and does not argue.
"
  [ "$CORE_DECLARED" = 0 ] && lost_msg="$lost_msg  The project table declares no hot core (not a single \"start\" line).
  A project table replaces the shipped one entirely, so the core is not fed at all right now.
"
fi

if [ "$queue_over" -eq 0 ] && [ "$stale_total" -eq 0 ] && [ -z "$lost_msg" ]; then
  exit 0
fi
{
  # Two different reproaches, and they must not be mixed: "bloated" is about volume, "does not
  # match" is about a declared section missing from the document. The second is not cured by a budget.
  [ "$queue_over" -eq 1 ] || [ "$stale_total" -gt 0 ] && echo "✗ mandatory reading is bloated."
  printf '%s' "$over_msg"
  [ -n "$lost_msg" ] && echo "✗ project context: what is declared does not match the document."
  printf '%s' "$lost_msg"
  # The budget hint goes only with the VOLUME reproach. A declared-vs-document mismatch is not cured
  # by a budget, and a general closing line would read as "tweak the number and it will pass".
  [ "$stale_total" -gt 0 ] && cat <<'EOF'
  Found REPORT sections (a heading with a checkmark or the word "done" + a date). A section that
  reports what was DONE is not policy: it belongs in a journal. A rule the agent reaches after
  reading six such sections works worse than a rule that lies first.
EOF
  [ "$queue_over" -eq 1 ] && \
    echo "  The budget is configurable (--budget), but tuning the budget is not the same as cleanup."
} >&2
exit 1
