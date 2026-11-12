#!/usr/bin/env bash
# retainer: the route of the task in work — which step is next, under which gate, at what run cost.
# complexity: keep, step 7 — nothing else computes which cycle step comes next, and without it the route lives only in the agent's context and dies with compaction
#
#   retainer-route.sh [project dir] [--full] [--rules FILE] [--repo owner/repo]
# exit 0 — the route is printed · 2 — usage · 3 — nothing to say: not a repository, or no task is
#          active in it. Silence there is the answer and not a complaint: this command is called on
#          every turn boundary, and a complaint on every turn outside a task is noise.
#
# WHAT IS DERIVED, NOT STORED. Each step's state comes from facts that already exist — the active-task
# marker, the plan-check marker, the tree's dirt recorded at the start, the branch name, the commit
# count, the push state, the pull-request phase and its labels. The command writes nothing: a second home for the route would drift from the
# tree exactly while the work moves, which is the failure it exists to remove.
#
# AN HONEST GAP OVER A GUESS. A step whose state needs the tracker, while the tracker does not
# answer, prints `not checked` and the walk STOPS there. Naming a later step from an unknown earlier
# one is the class of wrong answer this command exists to remove, so the third state is carried
# through rather than collapsed into "open" or "green".
#
# NOT A JUDGE. The route refuses nothing: it prints the gate value a resolver returned and the run
# the table names. Enforcement lives in the gate steps and in hooks/stop_gate.py. It is not a mode of
# retainer-preflight.sh either — that one judges readiness, may refuse, and runs once before a run;
# this one speaks on every turn and never refuses.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/retainer-config.sh
. "$HERE/retainer-config.sh"

DIR=""; MODE=line; RULES=""; SLUG=""
usage(){
  echo "usage: retainer-route.sh [project dir] [--full] [--rules FILE] [--repo owner/repo]" >&2
  exit 2
}
while [ $# -gt 0 ]; do
  case "$1" in
    --full)  MODE=full; shift ;;
    --line)  MODE=line; shift ;;
    --rules) RULES="${2:-}"; [ -n "$RULES" ] || usage; shift 2 ;;
    --repo)  SLUG="${2:-}"; [ -n "$SLUG" ] || usage; shift 2 ;;
    -*)      usage ;;
    *)       [ -z "$DIR" ] || usage; DIR="$1"; shift ;;
  esac
done
[ -n "$DIR" ] || DIR="."
[ -d "$DIR" ] || usage
case "${SLUG:-x/x}" in */*) ;; *) usage ;; esac

# The table has a test seam of its own, like the by-work advisor's: a corpus must be able to feed a
# table of two lines without touching the shipped one.
[ -n "$RULES" ] || RULES="${RETAINER_ROUTE_RULES:-$HERE/../hooks/route.rules}"
[ -f "$RULES" ] || exit 3
PHASE_SH="${RETAINER_ROUTE_PHASE_SH:-$HERE/retainer-branch-phase.sh}"
# The page cap of the full mode is the phase command's own default, named here rather than repeated
# as a number: a cap of our own would drift from the one that actually walks.
BRANCH_PHASE_MAX_PAGES_FULL="${BRANCH_PHASE_MAX_PAGES:-10}"

TOP="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" || exit 3
[ -n "$TOP" ] || exit 3

NUM="$(retainer_marker "$TOP" active-issue)"
[ -n "$NUM" ] || exit 3

# ── facts: everything local, gathered once ─────────────────────────────────────
CHECKED="$(retainer_marker "$TOP" plan-checked)"
BRANCH="$(git -C "$TOP" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '')"
REMOTE="$(retainer_remote "$TOP")"; [ -n "$REMOTE" ] || REMOTE=origin
BASE="$(retainer_base_branch "$TOP" "$REMOTE")"
AHEAD=0
[ -n "$BASE" ] && AHEAD="$(git -C "$TOP" rev-list --count "$BASE..HEAD" 2>/dev/null || printf '0')"
case "$AHEAD" in ''|*[!0-9]*) AHEAD=0 ;; esac
DIRTY="$(git -C "$TOP" status --porcelain 2>/dev/null | sed -n 1p)"
# UNTRACKED WORK COUNTS, and the earlier attempt to exclude it is reverted on measurement. Reading
# tracked modifications only did stop a stray log from pinning the walk at `commit` — but a
# never-added file is the ordinary shape of new work in this tree, and the step then read green over
# it while the push that follows runs a suite which sees tracked files alone. "You have uncommitted
# work" over litter is a true answer that is merely less useful; "push" over an uncommitted new
# module is a wrong one. Litter belongs in the project's ignore list, not in this heuristic.
# Paths dirty when task-start created the branch are not the task's work; see dirty-at-start.
# On a parse failure DIRTY keeps the reading above.
SNAP="$(retainer_state_dir "$TOP")/$(retainer_session)/dirty-at-start"
if [ -f "$SNAP" ] && [ "$(head -n 1 "$SNAP" 2>/dev/null)" = "$NUM" ] \
   && [ "$(head -n 2 "$SNAP" 2>/dev/null | tail -n 1)" = "$TOP" ]; then
  if OWN="$(git -C "$TOP" status --porcelain -z -uall 2>/dev/null | SNAP="$SNAP" python3 -c '
import os, sys

def paths(raw):
    found, records, at = [], raw.split(b"\0"), 0
    while at < len(records):
        record = records[at]
        at += 1
        if len(record) < 4:
            continue
        found.append(record[3:])
        if b"R" in record[:2] or b"C" in record[:2]:
            at += 1  # a rename or copy carries its source path as the next field
    return found

with open(os.environ["SNAP"], "rb") as fh:
    parts = fh.read().split(b"\n", 2)
seen = set(paths(parts[2] if len(parts) > 2 else b""))
for path in paths(sys.stdin.buffer.read()):
    if path not in seen:
        sys.stdout.buffer.write(path)
        break
')"; then
    DIRTY="$OWN"
  fi
fi
LHEAD="$(git -C "$TOP" rev-parse HEAD 2>/dev/null || printf '')"
RHEAD="$(git -C "$TOP" rev-parse "refs/remotes/$REMOTE/$BRANCH" 2>/dev/null || printf '')"
[ -n "$SLUG" ] || SLUG="$(retainer_cfg tracker_repo)"
API="${GITEA_URL:-$(retainer_cfg tracker_url http://localhost:3000)}/api/v1"

# THE TASK MAY LIVE IN ANOTHER CLONE. This project does its work on a stand, so the session's tree is
# often on another branch while the task's branch, commits and pushes exist only on the remote. When
# the checkout here is not the task's branch, the four git steps are read from the REMOTE: the remote
# is the one truth every clone shares, and a stand's path is not something to guess. A branch checked
# out here keeps the local reading, which also sees uncommitted work.
LOCAL_TASK=0
case "$BRANCH" in issue-"$NUM"|issue-"$NUM"-*) LOCAL_TASK=1 ;; esac
PHASE_BRANCH="$BRANCH"
RSTATE=""
remote_read(){  # sets RSTATE = absent|even|ahead|several, and PHASE_BRANCH to the remote task branch
  [ -z "$RSTATE" ] || return 0
  RSTATE=absent
  # One call for the base and the task. A failed call reads as no branch: the old local answer,
  # never a false green. It runs on a turn boundary, so it must never ask: no credential prompt on
  # the terminal, no ssh passphrase, and a dead host gives up in seconds rather than at the hook's
  # timeout.
  local out bsha
  out="$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5' \
         git -C "$TOP" ls-remote "$REMOTE" "refs/heads/$BASE" "refs/heads/issue-$NUM" \
         "refs/heads/issue-$NUM-*" 2>/dev/null </dev/null)"
  bsha="$(printf '%s\n' "$out" | awk -v r="refs/heads/$BASE" '$2 == r { print $1 }')"
  # The glob matches the tail of a ref, so the names are filtered again here: exactly `issue-<N>` or
  # `issue-<N>-*`, which keeps task 11360 out of task 1136 and a ref like `x/issue-<N>` out too.
  local rows
  rows="$(printf '%s\n' "$out" | awk -v n="$NUM" '
    { name = $2; sub(/^refs\/heads\//, "", name) }
    name == "issue-" n || index(name, "issue-" n "-") == 1 { print $1, name }')"
  [ -n "$rows" ] || return 0
  if [ "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" -gt 1 ]; then
    # Which of two branches is live cannot be told from refs: an old one may be merged and its name
    # burnt. The route names them and does not guess.
    RSTATE=several
    WHY="several remote branches for the task: $(printf '%s\n' "$rows" | awk '{ print $2 }' | paste -sd' ' -)"
    return 0
  fi
  PHASE_BRANCH="${rows#* }"
  # The stand's commits are not in this tree, so they cannot be counted: a head that differs from
  # the base head is work pushed.
  if [ "${rows%% *}" = "$bsha" ]; then RSTATE=even; else RSTATE=ahead; fi
}

# THE PLAN VERDICT ALSO LIVES ON THE TASK. The local marker sits under `.retainer/`, which the
# harness may deny to every writer in the session's tree; plan-checker can always post a comment
# `plan-checked: <N>`. Read only when the marker is not this task's, and only when the walk reaches
# `plan`. No slug, no token, a silent tracker: each answers with something that is not a list of
# comments, and that is the old local answer, `open`. The endpoint has no pages: one call is the whole
# feed.
#
# ONLY THE PROJECT'S OWN TRACKER. The slug comes from a config key that applies in every connected
# project, and a task number is all a comment has to match — so a project whose remote is elsewhere
# would turn green on another repository's task of the same number. The remote must be the tracker's
# repository itself.
plan_comment(){  # -> 0 when a comment names this task as plan-checked, 1 otherwise
  local url
  url="$(git -C "$TOP" remote get-url "$REMOTE" 2>/dev/null | sed -e 's#://[^/@]*@#://#' -e 's#\.git$##')"
  [ "$url" = "${API%/api/v1}/$SLUG" ] || return 1
  curl -s --max-time 10 -H "Authorization: token $(retainer_token 2>/dev/null)" \
       "$API/repos/$SLUG/issues/$NUM/comments" 2>/dev/null | N="$NUM" python3 -I -c '
import json, os, re, sys

# The form the lock and the task close treat as a service record: a line that STARTS with the
# label, any case, with the emphasis markdown puts around it. A looser reader here would turn the
# plan green on a comment those two count as the result report.
LABEL = re.compile(r"^[\s>*_`-]*plan-checked[*_`]*\s*:[*_`\s]*(\d+)", re.IGNORECASE | re.MULTILINE)
try:
    rows = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
if not isinstance(rows, list):
    sys.exit(1)
for row in rows:
    if isinstance(row, dict) and os.environ["N"] in LABEL.findall(str(row.get("body") or "")):
        sys.exit(0)
sys.exit(1)
'
}

# THE WORK ALREADY LANDED — read locally, from the base itself. On the base branch with nothing
# ahead there are two readings and they must not be guessed: the task was never started, or its
# branch is merged and gone while the marker is still set. That window is real — the close command
# clears the marker only at its very end. The deciding fact is in the base branch: this project's
# commits carry `#<N>`, enforced by the commit-msg hook, so a base that holds one has the work.
#
# Local on purpose. The earlier form asked the TRACKER, and the repository for that question came
# from a global config key which "applies in ALL projects where retainer is connected" — with two
# connected projects it named a foreign repository's issue, and a closed issue there would have
# called this work landed. The base branch cannot be about another project.
LANDED=0
if [ -n "$BASE" ] && [ "$BRANCH" = "$BASE" ] && [ "$AHEAD" -eq 0 ]; then
  # NO PIPE into `grep -q`, and this is measured. `grep -q` exits on the first match, git keeps
  # writing into a closed pipe, dies of SIGPIPE, and `pipefail` hands the PIPELINE 141 — so the test
  # failed while the pattern HAD matched. Measured on this base: 400 subjects are 45 266 bytes and
  # `PIPESTATUS` came back `141 0`, three runs out of three. A short fixture base never showed it:
  # git fits a few subjects into the pipe buffer and exits before the reader closes it.
  #
  # HEAD, not the base by name: this reads only where the branch IS the base and nothing is ahead, so
  # the base tip is HEAD, and HEAD is never an ambiguous name. The guard's own input two lines up
  # still resolves the bare name, so a tag sharing the base's name silences the signal there and the
  # route falls back to naming `branch` — fail-safe, never a false green, and outside this change.
  #
  # 400 subjects is about forty days of this project's history, far more than the window the signal
  # is meant for — the minutes between a merge and the marker being cleared. A marker abandoned for
  # longer falls back to naming `branch`, which is the honest older answer.
  #
  # The signal rests on one convention: a subject carries the number of the task it belongs to. Two
  # numbers appear only in merge and release subjects, where they name a pull request or tasks already
  # landed. A subject that mentions a LATER task would call it landed early; none of the last 400 do.
  #
  # The base read is LOCAL, so in the window where a branch is merged on the server but not yet
  # fast-forwarded here, the older `branch` answer still comes back. Fast-forwarding is the cleanup
  # step's own path, and this signal deliberately waits for it rather than asking the tracker.
  # ONE anchor, trailing. A leading `(^|[^0-9])` was measured to have no witness — removing it left
  # the corpus green — and its only possible effect is a false NEGATIVE: it cannot stop a false match
  # this project can produce, since a task reference always starts at a `#`, but a subject listing
  # two numbers adjacently (`#1115#1124`) would make the second unmatchable and call landed work
  # unfinished. By the project's rule a construct whose mutant stays green goes.
  if grep -qE "#$NUM([^0-9]|\$)" \
       <<<"$(git -C "$TOP" log --format=%s -n 400 HEAD 2>/dev/null)"; then
    LANDED=1
  fi
fi

# ── the tracker half: asked at most once, and only if the walk reaches it ──────
PHASE=""; PRNUM=""; WHY=""
phase_read(){  # sets PHASE = open|none|merged|closed|unknown and PRNUM when there is one
  [ -z "$PHASE" ] || return 0
  if [ -z "$SLUG" ] || [ -z "$PHASE_BRANCH" ] || [ "$PHASE_BRANCH" = HEAD ]; then
    PHASE=unknown; WHY="no repository slug or no branch name"; return 0
  fi
  # The line mode is spoken on every turn boundary, so its walk is capped at one page: with the
  # recent-update sort an active pull request sits there, and a miss answers exit 2 — not checked —
  # which is a state this command already carries honestly. The full mode is run once at task start
  # and once at session start and keeps the default ten pages.
  local out rc pages
  pages="$BRANCH_PHASE_MAX_PAGES_FULL"
  [ "$MODE" = line ] && pages=1
  out="$(BRANCH_PHASE_MAX_PAGES="$pages" bash "$PHASE_SH" \
         "$SLUG" --branch "$PHASE_BRANCH" --repo-dir "$TOP" 2>/dev/null)"; rc=$?
  PRNUM="$(printf '%s' "$out" | sed -n 's/.*PR #\([0-9]\{1,\}\).*/\1/p' | sed -n 1p)"
  case "$rc" in
    0) case "$out" in
         *"no PR was created"*) PHASE=none ;;
         *"PR #"*)              PHASE=open ;;
         *)                     PHASE=unknown; WHY="the phase reply was not recognised" ;;
       esac ;;
    1) case "$out" in
         *MERGED*) PHASE=merged ;;
         *)        PHASE=closed ;;
       esac ;;
    *) PHASE=unknown
       WHY="$(printf '%s' "$out" | sed -n 1p | sed 's/^[^ ]* //')"
       [ -n "$WHY" ] || WHY="the tracker did not answer" ;;
  esac
}

labelled(){  # labelled <label> -> 0 when the pull request carries it, 1 when not, 2 when unknown
  [ -n "$PRNUM" ] || return 2
  local token out
  token="$(retainer_token)"
  [ -n "$token" ] || return 2
  out="$(curl -s --max-time 15 -H "Authorization: token $token" \
         "$API/repos/$SLUG/issues/$PRNUM/labels" 2>/dev/null)" || return 2
  printf '%s' "$out" | L="$1" python3 -I -c '
import json, os, sys

try:
    rows = json.load(sys.stdin)
except ValueError:
    sys.exit(2)
if not isinstance(rows, list):
    sys.exit(2)
want = os.environ["L"]
names = {str(row.get("name")) for row in rows if isinstance(row, dict)}
sys.exit(0 if want in names else 1)
'
}

# ── the state of one step: green · open · unknown ──────────────────────────────
# The answer is ASSIGNED to STATE_OUT, not printed: a caller reading it through `$(...)` would run
# this in a subshell, and the phase cache, the pull-request number and the reason for an honest gap
# would all die there — the walk asked the tracker once per step and printed the fallback reason.
STATE_OUT=""
local_state(){  # the four git steps read from the session's own tree
  case "$1" in
    branch)
      case "$BRANCH" in
        issue-"$NUM"|issue-"$NUM"-*) STATE_OUT=green ;;
        *)                           STATE_OUT=open ;;
      esac ;;
    code)
      { [ "$AHEAD" -gt 0 ] || [ -n "$DIRTY" ]; } && STATE_OUT=green || STATE_OUT=open ;;
    commit)
      { [ -z "$DIRTY" ] && [ "$AHEAD" -gt 0 ]; } && STATE_OUT=green || STATE_OUT=open ;;
    *)
      { [ -n "$RHEAD" ] && [ "$RHEAD" = "$LHEAD" ]; } && STATE_OUT=green || STATE_OUT=open ;;
  esac
}
state_of(){
  # Everything the trail leaves behind is green once the work landed. That is what "the trail is all
  # that is left" means: covering only the local four moved the wrong instruction from `branch` to
  # `pr`, and leaving `plan` out of the list moved it again — onto "run plan-checker", because
  # the plan-checked marker is cleared by nothing and drifts. Measured on the live tree: the marker
  # trailed the active task by two hundred tasks.
  #
  # A task that lands in SEVERAL waves is outside this signal: between the waves the base already
  # holds a commit for it while work remains, and the route says `cleanup` where a new branch is the
  # right answer. Named rather than closed — the local signal cannot tell a partial landing from a
  # whole one, and the tracker form that could was removed for naming a foreign repository's issue.
  if [ "$LANDED" = 1 ]; then
    case "$1" in
      plan|branch|code|commit|push|pr|review|merge) STATE_OUT=green; return 0 ;;
    esac
  fi
  case "$1" in
    issue)
      [ -n "$NUM" ] && STATE_OUT=green || STATE_OUT=open ;;
    plan)
      { { [ -n "$CHECKED" ] && [ "$CHECKED" = "$NUM" ]; } || plan_comment; } \
        && STATE_OUT=green || STATE_OUT=open ;;
    branch|code|commit|push)
      if [ "$LOCAL_TASK" = 0 ]; then
        remote_read
        case "$RSTATE:$1" in
          several:*)               STATE_OUT=unknown ;;
          ahead:*|even:branch)     STATE_OUT=green ;;
          *)                       STATE_OUT=open ;;
        esac
        return 0
      fi
      local_state "$1" ;;
    pr)
      phase_read
      case "$PHASE" in
        open|merged|closed) STATE_OUT=green ;;
        none)               STATE_OUT=open ;;
        *)                  STATE_OUT=unknown ;;
      esac ;;
    review)
      phase_read
      if [ "$PHASE" = unknown ]; then STATE_OUT=unknown; return 0; fi
      labelled review-clean
      case "$?" in
        0) STATE_OUT=green ;;
        1) STATE_OUT=open ;;
        *) WHY="the pull request's labels were not read"; STATE_OUT=unknown ;;
      esac ;;
    merge)
      phase_read
      case "$PHASE" in
        merged)  STATE_OUT=green ;;
        unknown) STATE_OUT=unknown ;;
        *)       STATE_OUT=open ;;
      esac ;;
    *)
      # cleanup, and any step a project adds below it: the marker is still set, so the trail is not
      # yet cleaned. A step the script does not know is OPEN, never green — an unknown name must not
      # read as work already done.
      #
      # This arm is the ONLY default. An initialiser at the function's entry stood here as a second
      # one, against a step name that fell through every arm and kept the previous step's verdict;
      # it was measured redundant — every arm above assigns in both outcomes and this one catches
      # any name — and by the project's rule, written a hundred lines above, a construct whose
      # mutant stays green goes rather than keeps a case written around it.
      STATE_OUT=open ;;
  esac
}

gate_of(){  # gate_of <gate field> -> the word the resolver returned, or `-`, or `not read`
  local out
  case "$1" in
    flow:*) out="$(bash "$HERE/retainer-flow-policy.sh" "${1#flow:}" 2>/dev/null)" ;;
    tool:*) out="$(bash "$HERE/retainer-tool-policy.sh" "${1#tool:}" 2>/dev/null)" ;;
    *)      printf '%s' "-"; return 0 ;;
  esac
  [ -n "$out" ] && printf '%s' "$out" || printf '%s' "not read"
}

# ── the table: trimmed by one pass, five fields exactly ────────────────────────
STEPS=(); GATES=(); RUNS=(); PATHS=(); BYPASSES=()
TOTAL=0
while IFS='|' read -r f_step f_gate f_run f_path f_bypass; do
  STEPS[$TOTAL]="$f_step"; GATES[$TOTAL]="$f_gate"; RUNS[$TOTAL]="$f_run"
  PATHS[$TOTAL]="$f_path"; BYPASSES[$TOTAL]="$f_bypass"
  TOTAL=$((TOTAL + 1))
done < <(awk -F'|' '
  $1 ~ /^[[:space:]]*#/ { next }
  NF != 5 { next }
  { for (i = 1; i <= NF; i++) { gsub(/^[ \t]+|[ \t]+$/, "", $i) }
    print $1 "|" $2 "|" $3 "|" $4 "|" $5 }
' "$RULES")
[ "$TOTAL" -gt 0 ] || exit 3

# ── the walk: the first step that is not green is the next one ─────────────────
NEXT=-1
i=0
while [ "$i" -lt "$TOTAL" ]; do
  state_of "${STEPS[$i]}"
  st="$STATE_OUT"
  STATES[$i]="$st"
  if [ "$st" != green ] && [ "$NEXT" -lt 0 ]; then
    NEXT="$i"
    # The walk stops asking: states beyond the next step are not facts about this moment, and asking
    # the tracker for them would pay for an answer nobody reads.
    break
  fi
  i=$((i + 1))
done
[ "$NEXT" -ge 0 ] || NEXT=$((TOTAL - 1))

n_step="${STEPS[$NEXT]}"; n_state="${STATES[$NEXT]}"
n_gate="$(gate_of "${GATES[$NEXT]}")"
n_run="${RUNS[$NEXT]}"

if [ "$MODE" = full ]; then
  printf 'route of task #%s · branch %s\n' "$NUM" "${BRANCH:-?}"
  i=0
  while [ "$i" -lt "$TOTAL" ]; do
    mark=' '
    [ "$i" -lt "$NEXT" ] && mark='+'
    if [ "$i" -eq "$NEXT" ]; then
      case "$n_state" in unknown) mark='?' ;; *) mark='>' ;; esac
    fi
    printf '  %s %2d %-7s gate %-9s run %s\n' \
      "$mark" "$((i + 1))" "${STEPS[$i]}" "$(gate_of "${GATES[$i]}")" "${RUNS[$i]}"
    i=$((i + 1))
  done
else
  printf 'route #%s · step %d/%d %s · gate %s · run %s\n' \
    "$NUM" "$((NEXT + 1))" "$TOTAL" "$n_step" "$n_gate" "$n_run"
fi

if [ "$n_state" = unknown ]; then
  printf 'next: %s — state NOT CHECKED (%s): close that before reading the steps after it\n' \
    "$n_step" "${WHY:-the tracker did not answer}"
else
  printf 'next: %s — %s\n' "$n_step" "${PATHS[$NEXT]}"
fi
printf 'bypass here: %s\n' "${BYPASSES[$NEXT]}"
exit 0
