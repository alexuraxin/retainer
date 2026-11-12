#!/usr/bin/env bash
# retainer: TAKING a task with one command — symmetric to retainer-task-close.sh.
#
#   retainer-task-start.sh <owner/repo> <task number> [--no-branch|--from-main]
# exit 0 — taken · 1 — the tracker refused / the branch was not created / the branch is ahead of the base / no working
#          tree, i.e. the branch and marker are not done · 2 — usage, or run over another copy of the
#          engine: the script cannot decide which of the two trees to work in.
#
# Closing a task was mechanized, starting was not: three actions from the agent's memory (branch, label,
# marker) plus the clock. The asymmetry gave "work bypassing the tracker": the agent reached a finished plan
# leaving no trace in the tracker, and no machine objected — the active-label check ran
# only with a marker already set, i.e. it was switched off by the marker's absence.
#
# The task body is printed to stdout ON PURPOSE: the condition comes from the tracker, not from the agent's memory.
# The token is read from a file, the value is NOT printed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/retainer-config.sh
. "$ROOT/retainer-config.sh"

REPO="${1:-}"; NUM="${2:-}"; MODE="${3:-}"
usage(){ echo "usage: retainer-task-start.sh <owner/repo> <number> [--no-branch|--from-main]" >&2; exit 2; }
case "$REPO" in */*) ;; *) usage ;; esac
case "$NUM" in ''|*[!0-9]*) usage ;; esac
case "$MODE" in ''|--no-branch|--from-main) ;; *) usage ;; esac

# Refusing to work over a foreign copy of the engine is a shared seam, its home is bin/retainer-config.sh: the local
# half of taking (branch, marker) goes into the current directory, while the script may lie in another tree.
retainer_refuse_foreign_engine_tree "$ROOT" "The branch and marker would be created here, while the work would happen there" \
  || exit $?

API="${GITEA_URL:-$(retainer_cfg tracker_url http://localhost:3000)}/api/v1"
TOKEN="$(retainer_token)"
[ -n "$TOKEN" ] || { echo "no tracker token — cannot take the task"; exit 2; }
AUTH="Authorization: token $TOKEN"
api(){ curl -s --max-time 15 -H "$AUTH" "$@"; }

# ── the task body: read BEFORE any change. Not read — not taken: taking blindly a task whose condition
#    is unknown is exactly the work from memory the command exists against. ──
issue_json="$(api "$API/repos/$REPO/issues/$NUM")"
read -r ok title <<EOF
$(printf '%s' "$issue_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("no -"); raise SystemExit
if not isinstance(d, dict) or "state" not in d:
    print("no -"); raise SystemExit
print("yes" if d.get("state") == "open" else "closed", (d.get("title") or "-").replace("\n", " "))
')
EOF
case "$ok" in
  yes) ;;
  closed) echo "✗ task #$NUM is closed — nothing to take"; exit 1 ;;
  *) echo "✗ task #$NUM not read (the tracker is silent or answered with an error) — not taking blindly"; exit 1 ;;
esac

rc=0
CREATED=0   # 1 when this run created the task's branch

# The local half of the command — branch and marker — is possible only in a working tree. Silently
# skipped, it leaves the output cheerful (labels, clock), the taking looks done, while the marker
# holds the PREVIOUS task, to which closing and the active-task check then cling.
#
# `--show-toplevel` is empty not only outside a repository: a bare repository and a run from inside
# `.git/` say the same. The cases are split — otherwise the advice "call from the project dir" is given to someone already there.
IN_REPO=0
NO_REPO_WHY="this is not a git repository — call from the project dir"
if git rev-parse --show-toplevel >/dev/null 2>&1; then
  IN_REPO=1
elif git rev-parse --git-dir >/dev/null 2>&1; then
  NO_REPO_WHY="the repository has no working tree (bare or GIT_DIR in the environment)"
fi
if [ "$IN_REPO" = 0 ]; then
  echo "⚠ the local half of taking is not done: $NO_REPO_WHY" >&2
  if [ "$MODE" = "--no-branch" ]; then
    echo "  The active-issue marker is not set." >&2
  else
    echo "  The branch is not created, the active-issue marker is not set." >&2
  fi
  rc=1
fi

# ── branch issue-<N>-<slug> off main. The slug is from the title: latin/digits, the rest to a hyphen. ──
if [ "$MODE" != "--no-branch" ] && [ "$IN_REPO" = 1 ]; then
  slug="$(printf '%s' "$title" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '-' | tr -s '-' | cut -c1-40 | sed 's/^-//; s/-$//')"
  branch="issue-$NUM${slug:+-$slug}"
  if git rev-parse --verify --quiet "$branch" >/dev/null 2>&1; then
    if git checkout -q "$branch"; then
      echo "▶ branch $branch (already existed) — switched"
    else
      # A switch refusal must be audible: otherwise the task commits land on the previous branch with
      # cheerful output and a zero code.
      echo "✗ branch $branch exists, but could not switch — the tree is in the way (a modified or untracked file)" >&2
      rc=1
    fi
  else
    # The name of the main branch is declared by the repository itself: on a project with `master`, branching off `main` hit a
    # nonexistent ref, and the guard below compared the branch with nothing.
    base="$(retainer_base_ref .)"
    # The repository may not declare a main branch at all — a local project without a remote and without `main`.
    # A refusal on that would be a refusal on level ground: branch off the current head and say aloud that
    # there is nothing to compare the branch with. A silent tree rollback is impossible here — the head is the base.
    if [ -z "$base" ]; then
      echo "⚠ the repository did not declare a main branch — branching off the current branch «$(git rev-parse --abbrev-ref HEAD)», nothing to compare with the base"
      base=HEAD
    fi
    # Branching off the main branch is right exactly when the previous work is already merged and pushed.
    # A red gate, a marathon branch with "PR at the end" and a fetch that did not run are three cases where this is
    # not so, and then `checkout -b` off a foreign base SILENTLY rolls the tree back to the whole depth of the unsent
    # (a live measurement: 15 commits, seven policy sections and a lost gate edit came back).
    # The operation is legal, the code is zero, the output is cheerful — the signal was the guard side diff.
    #
    # Hence: compare BEFORE branching and refuse if the current branch is ahead of the base. The bypass is named
    # (`--from-main`), not silent: "off main anyway" stays possible, but becomes
    # a decision, not a default.
    # fetch has its own branch name, and a hardwired `main` left the guard empty exactly on the projects the
    # base is resolved for: fetch did not run, the ref did not exist, `rev-list` answered 0.
    # There is nothing to ask when the remote or the name is not found — then the base freshness is moot.
    base_remote="$(retainer_remote .)"
    base_name="$(retainer_base_branch .)"
    if [ -n "$base_remote" ] && [ -n "$base_name" ]; then
      git fetch -q "$base_remote" "$base_name" 2>/dev/null \
        || echo "⚠ fetch did not run — $base may be an echo of the past, not the base"
    fi
    ahead="$(git rev-list --count "$base"..HEAD 2>/dev/null || echo 0)"
    if [ "$ahead" -gt 0 ] && [ "$MODE" != "--from-main" ]; then
      echo "✗ the current branch $(git rev-parse --abbrev-ref HEAD) is $ahead commit(s) ahead of $base." >&2
      echo "  Branching off $base would take them out of the working tree — silently." >&2
      echo "  Merge or push the work, or name the decision explicitly: --from-main" >&2
      rc=1
    elif git checkout -q -b "$branch" "$base" 2>/dev/null; then
      CREATED=1
      echo "▶ branch $branch from $base ($(git rev-parse --short "$base"))"
      [ "$ahead" -gt 0 ] && echo "  ⚠ --from-main: $ahead commit(s) of the previous branch remained outside the tree"
    else
      echo "⚠ branch $branch could not be created — the tree is dirty or the base is not found"; rc=1
    fi
  fi
fi

# ── labels: remove ready/blocked, set in-progress. Removal goes BEFORE setting: a task with both labels at once
#    asserts both "ready to take" and "in progress" — a contradiction visible in the list. ──
labels_json="$(api "$API/repos/$REPO/labels?limit=100")"
inprog_id="$(printf '%s' "$labels_json" | python3 -c '
import json, sys
try:
    rows = json.load(sys.stdin)
except Exception:
    raise SystemExit
if isinstance(rows, list):
    for row in rows:
        if isinstance(row, dict) and row.get("name") == "in-progress":
            print(row.get("id") or "")
            break
')"
for stale in ready blocked; do
  api -o /dev/null -X DELETE "$API/repos/$REPO/issues/$NUM/labels/$(printf '%s' "$labels_json" | LBL="$stale" python3 -c '
import json, os, sys
try:
    rows = json.load(sys.stdin)
except Exception:
    raise SystemExit
name = os.environ["LBL"]
if isinstance(rows, list):
    for row in rows:
        if isinstance(row, dict) and row.get("name") == name:
            print(row.get("id") or "")
            break
')" 2>/dev/null || true
done
if [ -n "$inprog_id" ]; then
  code="$(api -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d "{\"labels\":[$inprog_id]}" "$API/repos/$REPO/issues/$NUM/labels")"
  case "$code" in
    200|201) echo "▶ labels: ready/blocked removed, in-progress set" ;;
    *) echo "⚠ label in-progress not set (HTTP $code)"; rc=1 ;;
  esac
else
  echo "⚠ label in-progress not found in the repository — labels untouched"; rc=1
fi

# ── the active-task marker: the one whose absence used to SWITCH OFF the check for its own absence. ──
# It lives per session outside the tree (bin/retainer-config.sh): the tree's `.retainer/` is denied to
# the agent, and one shared file named whoever wrote last. Another task already in this session's slot
# is named before it is replaced, never overwritten in silence.
if [ "$IN_REPO" = 1 ]; then
  top="$(git rev-parse --show-toplevel)"
  own="$(retainer_state_dir "$top")/$(retainer_session)/active-issue"
  held="$({ tr -dc '0-9' < "$own"; } 2>/dev/null)"   # this slot only: the write below replaces nothing else
  [ -z "$held" ] || [ "$held" = "$NUM" ] || echo "⚠ the marker held task #$held — replaced by #$NUM"
  if retainer_marker_set "$top" active-issue "$NUM"; then
    echo "▶ marker active-issue = $NUM (session $(retainer_session))"
    # The tree beside the task: the stop gate of a session whose shell left every repository judges it.
    retainer_marker_set "$top" tree "$top" || echo "⚠ the task's tree not recorded — a cwd outside the repository stays unjudged"
    # The tree's dirt at branch creation, for the route. Not on a re-take: the tree then holds the task's work.
    if [ "$CREATED" = 1 ]; then
      { printf '%s\n%s\n' "$NUM" "$top"; git status --porcelain -z -uall 2>/dev/null; } \
        > "$(retainer_state_dir "$top")/$(retainer_session)/dirty-at-start" 2>/dev/null \
        || echo "⚠ the tree's dirt at the start not recorded — foreign files will hold the route at «commit»"
    fi
  else
    echo "⚠ marker not written — the active-label check will stay mute"; rc=1
  fi
fi

# ── the clock: in the same motion as everything else. It not starting is no reason not to take the task. ──
if [ -x "$ROOT/retainer-task-clock.sh" ]; then
  GITEA_TOKEN="$TOKEN" bash "$ROOT/retainer-task-clock.sh" "$REPO" start "$NUM" 2>&1 | tail -1
fi

# ── the task condition to stdout: the agent reads it from the tracker, not from its own memory. ──
echo
echo "── #$NUM $title ──"
printf '%s' "$issue_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
sys.stdout.write((d.get("body") or "(body empty)") + "\n")
'
# ── the route: which steps the task goes through, where it stands now, and what the next one costs.
#    Printed AFTER the task body and BEFORE the refusal repeat below, which owns the output tail.
#    The command is silent without an active task, so a failed marker above simply means no route.
if [ "$IN_REPO" = 1 ] && [ -x "$ROOT/retainer-route.sh" ]; then
  echo
  bash "$ROOT/retainer-route.sh" "${top:-.}" --full || true
fi

# The refusal is repeated at the end: between it and this line labels, the clock and the whole task body are printed,
# and the screen is left with success last. Not everyone sees the exit code, everyone sees the output tail.
[ "$rc" -ne 0 ] && [ "$IN_REPO" = 0 ] \
  && echo "⚠ taking incomplete: $NO_REPO_WHY — marker and branch not done" >&2
exit "$rc"
