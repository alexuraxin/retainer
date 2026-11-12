#!/usr/bin/env bash
# retainer: close a task with ONE command — the cleanup step of the gitea-flow.
#
#   retainer-task-close.sh <owner/repo> <task number>
#   retainer-task-close.sh <owner/repo> --pr <PR number>   — post-merge cleanup
# exit 0 — done · 1 — the tracker refused / a tail remained · 2 — usage, no token, or run over
#          another copy of the engine (the print modes `--print-refs`/`--print-ac` are not affected).
#
# `PATCH state=closed` does not touch labels — we remove them ourselves, BEFORE closing. The agent must
# still call the command: it folds three actions into one, and a forgotten call shows on the next
# retainer-preflight.sh (the closed-labels check). An already closed task is the normal path: labels
# are removed, the state is not touched (that is also how a historical tail is cleaned).
#
# The --pr mode: merge is the only point of the cycle where the TRACKER closes the task by `Closes #N`, while
# cleanup stays a promise. Here it is bound to the merge: the PR body is read, ALL tasks named in
# it are cleaned, and the result is verified in the same run — a remaining label reddens at once, not on the
# next preflight. The boundary is honest: the command still has to be called; what can no longer be forgotten is
# one task out of ten and a partial result.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=bin/retainer-config.sh
. "$ROOT/bin/retainer-config.sh"

# Labels that ASSERT activity: on a closed task each of them lies. `not-decomposed`
# is not among them — on a closed task it is a legitimate trace (closed without decomposing).
# The list must match `work` in the closed-labels block of retainer-preflight.sh: one fixes exactly
# what the other reddens on. The lists (not the values) are compared by tests/test_task_close.sh.
WORK_LABELS="in-progress ready blocked"

# --print-refs: print the numbers of the tasks the PR closes, and exit. Changes nothing.
# Needed so the closing-reference parse exists in ONE place: the Gitea forms are listed here and
# code markup is accounted for here too, and a second copy of the list would certainly drift from the first.
PRINT_REFS=0
if [ "${1:-}" = --print-refs ]; then PRINT_REFS=1; shift; fi
PRINT_AC=0
if [ "${1:-}" = --print-ac ]; then PRINT_AC=1; shift; fi

# The same shared seam as for starting (home — bin/retainer-config.sh). The local half of closing is the marker
# of the active task; removed in the wrong tree, it leaves the guard and the memory probe with a foreign number.
#
# The PRINT modes are not affected by the refusal: they write to no tree, and the merge lock reads them.
# Empty output there means zero checked tasks — i.e. the report and the checked criteria stop
# being checked SILENTLY.
if [ "$PRINT_REFS" = 0 ] && [ "$PRINT_AC" = 0 ]; then
  retainer_refuse_foreign_engine_tree "$ROOT" \
    "The active-task marker would be removed here, but it was set there" || exit $?
fi

REPO="${1:-}"; NUM="${2:-}"
usage(){
  echo "usage: retainer-task-close.sh [--print-refs|--print-ac] <owner/repo> {<task number> | --pr <PR number>}" >&2
  exit 2
}
case "$REPO" in */*) ;; *) usage ;; esac
PR_MODE=0
if [ "$NUM" = --pr ]; then
  PR_MODE=1; PR_NUM="${3:-}"
  case "$PR_NUM" in ''|*[!0-9]*) usage ;; esac
else
  case "$NUM" in ''|*[!0-9]*) usage ;; esac
fi

# GITEA_URL is the same seam as in preflight and the pipeline: without it the hint "remove with command X"
# would lead to a different host than the one where the check found the tail.
API="${GITEA_URL:-$(retainer_cfg tracker_url http://localhost:3000)}/api/v1"
TOKEN="$(retainer_token)"
[ -n "$TOKEN" ] || { echo "no tracker token — cannot close the task"; exit 2; }

api(){ curl -s --max-time 15 -H "Authorization: token $TOKEN" "$@"; }

# ── --pr mode: cleanup bound to the merge ──────────────────────────────────────
# Closing references are read from the PR body — the same text the tracker itself closes by. The Gitea forms
# (`Closes`/`Fixes`/`Resolves`, any case) are listed here, not guessed one by one.
pr_close_refs(){
  api "$API/repos/$REPO/pulls/$1" | python3 -c '
import json, re, sys

REF = re.compile(r"\b(?:clos(?:e|es|ed)|fix(?:e[sd])?|resolv(?:e|es|ed))\s+#(\d+)", re.IGNORECASE)
# Code markup is the only sign that tells a quotation from an instruction: code blocks and inline code
# are cut out BEFORE parsing, so `Closes #7` in backticks does not count as a reference.
FENCE = re.compile(r"^```.*?^```", re.S | re.M)   # code block: from a line with ``` to a line with ```
INLINE = re.compile(r"`[^`\n]*`")                 # inline code in single backticks

def strip_code(text):
    return INLINE.sub(" ", FENCE.sub(" ", text))

try:
    pr = json.load(sys.stdin)
except ValueError:
    sys.exit(3)
if not isinstance(pr, dict) or "body" not in pr:
    sys.exit(3)                                   # a tracker error arrives as valid json without body
seen = []
for num in REF.findall(strip_code(str(pr.get("body") or ""))):
    if num not in seen:
        seen.append(num)
sys.stdout.write(" ".join(seen))
'
}

# Verification AFTER cleanup: empty means clean, otherwise the text of the discrepancy. Tracker silence is split off with code 3:
# "not read" is not "clean", otherwise the check would go green exactly where there is nothing to check with.
verify_clean(){
  api "$API/repos/$REPO/issues/$1" | WL="$WORK_LABELS" python3 -c '
import json, os, sys

try:
    issue = json.load(sys.stdin)
except ValueError:
    sys.exit(3)
if not isinstance(issue, dict) or issue.get("state") not in ("open", "closed"):
    sys.exit(3)
work = set(os.environ["WL"].split())
left = [str(lab.get("name")) for lab in (issue.get("labels") or []) if lab.get("name") in work]
if issue["state"] != "closed":
    sys.stdout.write("remained OPEN after the merge — the closing link did not fire")
elif left:
    sys.stdout.write("working labels remain: %s" % " ".join(left))
'
}

if [ "$PRINT_REFS" = 1 ]; then
  # In this mode the PR number is passed as the second argument without --pr: it is the subject of the query.
  case "$NUM" in ''|*[!0-9]*) usage ;; esac
  pr_close_refs "$NUM" || exit 1
  echo
  exit 0
fi

if [ "$PR_MODE" = 1 ]; then
  refs="$(pr_close_refs "$PR_NUM")" || {
    echo "✗ body of PR #$PR_NUM not read — which tasks it closes is unknown"; exit 1; }
  if [ -z "$refs" ]; then
    echo "✗ the body of PR #$PR_NUM has no closing link at all — nothing to clean, and that is suspicious"
    echo "  either the PR really closes no tasks, or the link was lost when the body was edited"
    exit 1
  fi
  # What exactly was recognised is said aloud, BEFORE acting. A near miss was invisible precisely because the
  # report named only the TOTAL ("tasks: 3"): three instead of one looked like normal work. The list of
  # numbers before cleanup makes an extra reference noticeable where it can still be cancelled.
  echo "▶ PR #$PR_NUM closes tasks: $(printf '#%s ' $refs)"
  rc=0; total=0
  for ref in $refs; do
    total=$((total + 1))
    bash "$0" "$REPO" "$ref" || rc=1
  done
  for ref in $refs; do
    if left="$(verify_clean "$ref")"; then
      [ -n "$left" ] && { echo "✗ #$ref: $left"; rc=1; }
    else
      echo "✗ #$ref: state after cleanup not read — nothing to verify with"; rc=1
    fi
  done
  if [ "$rc" = 0 ]; then
    echo "✔ PR #$PR_NUM: post-merge cleanup done and verified (tasks: $total)"
  else
    echo "✗ PR #$PR_NUM: cleanup incomplete — tail above, the merge step is not closed"
  fi
  exit "$rc"
fi

# Criteria parsing is ONE home. The merge lock uses the same parse (via --print-ac):
# closing by `Closes #N` is done by the tracker, and a check living only here does not run at all
# on the real closing path. A second copy of the canon rule would drift from the first.
ac_state(){   # $1 — task url; prints ok | none | ? | open<TAB>items | unknown<TAB>headings
  api "$1" | python3 -c '
import json, os, re, sys

# The block heading at any markup depth and in any case — the canon sets the form, not the spelling.
# The sample literal must match, character for character, what the readiness check reads on entry:
# if they drift, entry admits a body that gets a refusal here. The match is guarded by a test.
HEAD = re.compile(r"^#{1,6}[ \t]*(?:acceptance[ \t]+criteria|критери[йи][ \t]+при[её]мки)\b", re.IGNORECASE)
NEXT = re.compile(r"^#{1,6}\s+")
DONE = re.compile(r"^\s*[-*]\s*\[[xX]\]")
OPEN = re.compile(r"^\s*[-*]\s*\[\s*\]")
# Template hints and fenced code are cut out BEFORE parsing — by the same move as in the readiness
# check. A task ABOUT the block form quotes that form in full, and a quoted checkbox would otherwise
# read as a real one: a body without a single criterion would get a refusal with nothing to fix.
COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)
FENCE = re.compile(r"^[ \t]*```.*?^[ \t]*```", re.DOTALL | re.MULTILINE)
try:
    body = str(json.load(sys.stdin).get("body") or "")
except (ValueError, AttributeError):
    print("?"); sys.exit()
lines = FENCE.sub("", COMMENT.sub("", body)).splitlines()
# Headings under which the body has checkboxes. A heading without text and a heading with a tab inside
# do not break the refusal message: the first would come out an empty line, the second two false items,
# because a tab in the value separates fields.
loose, head = [], "(no heading)"
for line in lines:
    if NEXT.match(line):
        head = line.lstrip("#").strip().replace("\t", " ") or "(no heading)"
    elif (DONE.match(line) or OPEN.match(line)) and head not in loose:
        loose.append(head)
start = next((i for i, line in enumerate(lines) if HEAD.match(line)), None)
if start is None:
    # No block — but "nothing to judge" and "there is something to judge with, and I did not recognise the form" are DIFFERENT answers.
    # One value for both makes a form miss indistinguishable from a task without criteria, and the parse
    # is silent exactly where it erred. The headings are named: otherwise the assignee has nothing to fix.
    print(("unknown\t" + "\t".join(loose)) if loose else "none"); sys.exit()
rest = lines[start + 1:]
stop = next((i for i, line in enumerate(rest) if NEXT.match(line)), len(rest))
block = rest[:stop]
unchecked = [line.strip() for line in block if OPEN.match(line)]
if not any(DONE.match(line) for line in block) and not unchecked:
    # The canonical heading exists, but there are no checkboxes under it. If there are none in the whole body — nothing
    # to judge. If there are — the canon block is empty, and the criteria lie elsewhere, and a skip here turns
    # the cure prescribed by the refusal ("name the block with the canon") into a silent pass: the heading added
    # on top, the list left in place, the verdict went green with unchecked items.
    print(("unknown\t" + "\t".join(loose)) if loose else "none"); sys.exit()
print("ok" if not unchecked else "open\t" + "\t".join(unchecked))
'
}

ISSUE="$API/repos/$REPO/issues/$NUM"
if [ "$PRINT_AC" = 1 ]; then
  # Empty output is not "no criteria" but "the parse did not run": no python3, a cut reply, a killed
  # process. Exiting with zero from here is not allowed. Consumers read the value as `$(… || printf "?")`, and
  # code 0 with empty stdout hands them an empty string — the very one the default branch reads
  # as "nothing to judge". A refusal here turns it into "not checked" for all three consumers at once.
  ac_out="$(ac_state "$ISSUE")"
  [ -n "$ac_out" ] || exit 1
  printf '%s\n' "$ac_out"
  exit 0
fi

# The state and ids of the working labels are taken from the task itself: the label id is already in its reply, a separate
# lookup by repository would be a second request for the same numbers.
#
# The parse prints the result as ONE piece and only after assembling it whole, and bash checks the exit code.
# Otherwise a failure mid-parse (no python3, a label without `id`, a cut reply) yields a partial
# stdout that reads as "no working labels" — and a command written against "closed and
# left the label" would reproduce that case itself, reporting with a tick.
info="$(api "$ISSUE" | WL="$WORK_LABELS" python3 -c '
import json, os, sys

try:
    issue = json.load(sys.stdin)
except ValueError:
    sys.exit(3)
if not isinstance(issue, dict) or issue.get("state") not in ("open", "closed"):
    sys.exit(3)
work = set(os.environ["WL"].split())
hits = [lab for lab in (issue.get("labels") or []) if lab.get("name") in work]
if any(lab.get("id") is None for lab in hits):
    sys.exit(3)                                   # a label without id cannot be removed — silence is not allowed
sys.stdout.write("%s\n%s\n%s\n" % (
    issue["state"],
    " ".join(str(lab["id"]) for lab in hits),
    " ".join(str(lab["name"]) for lab in hits),
))
')" || { echo "⚠ tracker did not return the task #$NUM (or the reply is not parsed) — neither labels nor state touched"; exit 1; }
state="$(printf '%s\n' "$info" | sed -n 1p)"
label_ids="$(printf '%s\n' "$info" | sed -n 2p)"
label_names="$(printf '%s\n' "$info" | sed -n 3p)"

# 1. Labels go FIRST. The reverse order (close, then remove) leaves exactly the same tail if the
#    second request does not arrive — i.e. reproduces the defect the script is written against.
removed=0
for lid in $label_ids; do
  code="$(api -o /dev/null -w '%{http_code}' -X DELETE "$ISSUE/labels/$lid")"
  case "$code" in
    200|204) removed=$((removed + 1)) ;;
    *) echo "✗ label id $lid not removed (code $code); removed before the failure: $removed — task #$NUM stayed labeled, state unchanged"; exit 1 ;;
  esac
done

# 2. Closing. An already closed task is the normal path: both a tail cleanup and the ordinary post-merge cleanup, where
#    the tracker itself closed the task (close-on-merge by `Closes #N`).
closed_now=0
if [ "$state" = open ]; then
  # A task closed MANUALLY (without a PR) does not complete without a report either — the merge lock does not
  # reach it by definition. The checkable fact is judged: a comment exists, is not a service one
  # (`review-sha`), not from a bot. The machine does not judge substance.
  rep="$(api "$API/repos/$REPO/issues/$NUM/comments" | python3 -c '
import json, re, sys

SERVICE = re.compile(r"review-sha[*_`]*\s*:|^[\s>*_`-]*plan-checked[*_`]*\s*:", re.IGNORECASE | re.MULTILINE)
try:
    rows = json.load(sys.stdin)
except ValueError:
    print("?"); sys.exit()
if not isinstance(rows, list):
    print("?"); sys.exit()
for row in rows:
    if not isinstance(row, dict):
        continue
    body = str(row.get("body") or "")
    if not body.strip() or SERVICE.search(body):
        continue
    if str(((row.get("user") or {}).get("login")) or "").endswith("-bot"):
        continue
    print("yes"); sys.exit()
print("none")
')"
  case "${rep:-?}" in
    yes) ;;
    '?') echo "✗ comments of task #$NUM not parsed — whether a report exists is unknown; not closing"; exit 1 ;;
    *)   echo "✗ task #$NUM has no result comment — not closing."
         echo "  No comment about the results and the work done — the task is not complete."
         echo "  Labels removed: $removed. Add a report and repeat."
         exit 1 ;;
  esac
  # Creating via the API does not apply the template, so the canon is guarded at CLOSING —
  # on the pattern of the report check above. The checkable fact is judged: the body has an Acceptance Criteria block and all its
  # checkboxes are checked. The machine does not judge the substance of the criteria and will not pretend to.
  #
  # A task WITHOUT checkboxes at all closes as before: old tasks must not be broken, and demanding the
  # canon retroactively from the whole tracker makes the check noisy — a noisy one is bypassed.
  # Checkboxes EXIST but no canonical block — not that case: there is something to judge with, and a silent skip
  # here would mean the block form is guarded by nothing.
  ac="$(ac_state "$ISSUE")"
  [ -n "$ac" ] || ac='?'          # the parse did not run: that is "not checked", not "nothing to judge"
  case "${ac%%$'\t'*}" in
    ok|none) ;;
    '?')     echo "✗ body of task #$NUM not parsed — criteria state unknown; not closing"; exit 1 ;;
    unknown) echo "✗ task #$NUM has checkboxes, but none under an Acceptance Criteria heading — not closing."
             echo "  The checkboxes were found under other headings:"
             printf '%s\n' "$ac" | tr '\t' '\n' | tail -n +2 | sed 's/^/    /'
             echo "  Name the criteria block «## Acceptance Criteria» (or «## Критерии приёмки») and keep the items right under it:"
             echo "  a subheading between the heading and the list breaks the block at itself."
             echo "  Labels removed: $removed."
             exit 1 ;;
    *)       echo "✗ task #$NUM has unchecked items in Acceptance Criteria — not closing:"
             printf '%s\n' "$ac" | tr '\t' '\n' | tail -n +2 | sed 's/^/    /'
             echo "  Check what is done or move what is not done to a separate task."
             echo "  Labels removed: $removed."
             exit 1 ;;
  esac
  code="$(api -o /dev/null -w '%{http_code}' -X PATCH -H 'Content-Type: application/json' \
          -d '{"state":"closed"}' "$ISSUE")"
  case "$code" in
    200|201) closed_now=1 ;;
    *) echo "✗ task #$NUM NOT closed (code $code); labels removed: $removed — partial state, repeat"; exit 1 ;;
  esac
fi

# 3. The clock is stopped by the stopwatch OWNER, not by whoever closed the task. The Gitea stopwatch
#    is one per user: after close-on-merge the task arrives here already closed, and the rule
#    "stop only what we closed ourselves" would leave it ticking forever — the next `start` would hit
#    409, and the duration measurement would die silently from the very first task. The reverse error is no less
#    costly: a stop on a foreign task kills the measurement of the one running right now.
clock=""
mine="$(api "$API/user/stopwatches" | REPO="$REPO" NUM="$NUM" python3 -c '
import json, os, sys

try:
    rows = json.load(sys.stdin)
except ValueError:
    sys.exit(3)
if not isinstance(rows, list):
    sys.exit(3)
owner, _, name = os.environ["REPO"].lower().partition("/")
num = int(os.environ["NUM"])
# Fold the case: Gitea paths are case-insensitive (`Owner/Repo` answers 200), while
# /user/stopwatches returns the canon. An exact comparison would leave the stopwatch ticking silently —
# it is one per user, and the next start would hit 409.
hit = any(
    row.get("issue_index") == num
    and str(row.get("repo_owner_name") or "").lower() == owner
    and str(row.get("repo_name") or "").lower() == name
    for row in rows
    if isinstance(row, dict)
)
sys.stdout.write("1" if hit else "0")
' 2>/dev/null)" || mine=""
if [ "$mine" = 1 ]; then
  if out="$(GITEA_TOKEN="$TOKEN" GITEA_URL="${API%/api/v1}" bash "$ROOT/bin/retainer-task-clock.sh" "$REPO" stop "$NUM" 2>&1)"; then
    clock="$out"
  else
    clock="⚠ clock not stopped (task closed, only the figure is lost)"
  fi
elif [ -z "$mine" ]; then
  clock="⚠ stopwatch list not read — the clock may have stayed running"
fi

# The active-task marker — symmetric to task-start. It asserts "this task is in progress", and
# after closing the assertion is false. Until now nobody removed it: the only writer is
# task-start, so the value outlived its task by days. Its readers are the route, preflight and conformance.
# ONLY its own number is removed, from this session's slot and the shared one: another session's task, or a
# neighbouring task in the same slot, is not this close's to erase. A missing file is not an error —
# starting could have gone without a marker.
marker_said="no marker"
marker_top="$(git rev-parse --show-toplevel 2>/dev/null || printf '')"
# Outside a repository the marker was not checked AT ALL, and that is not the same as "there was none": merged into one
# wording, these cases read as a clean close where the local half did not run.
[ -n "$marker_top" ] || marker_said="outside a git repository — marker not checked"
if [ -n "$marker_top" ]; then
  held="$(retainer_marker "$marker_top" active-issue)"
  if [ "$(retainer_marker_clear "$marker_top" active-issue "$NUM")" != 0 ]; then
    marker_said="marker removed"
  elif [ -n "$held" ] && [ "$held" != "$NUM" ]; then
    marker_said="marker holds another task — untouched"
  elif [ -n "$held" ]; then
    marker_said="⚠ marker not removed"
  fi
  # Line 1 is the task number; retainer_marker would mix in digits of the paths below it.
  snap="$(retainer_state_dir "$marker_top")/$(retainer_session)/dirty-at-start"
  if [ -f "$snap" ] && [ "$(head -n 1 "$snap" 2>/dev/null)" = "$NUM" ]; then rm -f "$snap"; fi
fi

if [ "$removed" = 0 ]; then
  labels_said="no working labels"
else
  labels_said="labels removed: $removed ($label_names)"
fi
if [ "$closed_now" = 1 ]; then state_said="task closed"; else state_said="task was already closed"; fi
echo "✔ #$NUM: $labels_said · $state_said · $marker_said"
# Refusing on an already closed task is too late — but silence is not allowed: otherwise the tail of tasks closed
# by merge with empty criteria is visible to nobody.
if [ "$closed_now" != 1 ]; then
  late="$(ac_state "$ISSUE")"
  case "${late:-?}" in
    open*)    echo "  ⚠ acceptance criteria not checked — the task does not say which of the declared is done" ;;
    unknown*) echo "  ⚠ checkboxes exist, but none under an Acceptance Criteria heading — the machine does not know whether the criteria are checked" ;;
    ok|none)  ;;
    *)        echo "  ⚠ criteria state not read — the parse did not run, rather than saying «nothing to judge»" ;;
  esac
fi
[ -n "$clock" ] && echo "  $clock"
# The project's code graph is refreshed after the close, detached, so the next session asks a current
# graph without waiting for a build. Only a graph that exists is refreshed: a project that never asked
# one does not pay a build per close. Its failure is the graph's own and never changes this exit code.
if [ -n "$marker_top" ] && command -v graphify >/dev/null 2>&1; then
  graph_home="$(bash "$ROOT/bin/retainer-state.sh" path graph "$marker_top" 2>/dev/null)"
  if [ -n "$graph_home" ] && [ -f "$graph_home/graph.json" ]; then
    nohup bash "$ROOT/bin/retainer-graph.sh" -C "$marker_top" refresh \
      >> "$graph_home/refresh.log" 2>&1 </dev/null &
    echo "  code graph refresh started in the background"
  fi
fi
exit 0
