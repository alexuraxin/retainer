#!/usr/bin/env bash
# retainer: the truth about a branch's phase — both halves.
#
#   retainer-branch-phase.sh <owner/repo> [--branch <name>] [--repo-dir <path>]
#   retainer-branch-phase.sh <owner/repo> --unmerged [--base <branch>] [--repo-dir <path>]
#
# PHASE mode: which phase the branch is in according to the TRACKER.
#   exit 0 — phase open (PR open) or no PR was ever created: push makes sense
#   exit 1 — phase CLOSED (PR merged or closed): push moves a dead branch
#   exit 2 — NOT checked (no token, tracker silent, reply not parsed)
#
# UNMERGED mode: what from HEAD is not yet in the base branch — against a fresh origin, not a stale one.
#   exit 0 — comparison done (list printed, possibly empty)
#   exit 2 — comparison failed (fetch did not succeed): a silent wrong answer is worse than a refusal
#
# Both modes address the same failure class: local git does not know this truth. The model
# "pushed to the branch → the PR grew" holds exactly until the first merge; after it `git push` returns 0 and
# merely moves a dead branch. Worked example: the PR was merged, the agent did eight more tasks with the gate and
# push, no PR existed for them, and nothing appeared in the tracker for eight tasks in a row. The second
# failure masked the first: `git log origin/main..HEAD` WITHOUT fetch answered honestly for the pre-merge
# state and showed merged commits as unmerged — "fifteen commits unmerged" read as
# "the work is in place", though eight sat in a dead branch.
#
# The token is read from a file, its value is NEVER printed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=bin/retainer-config.sh
. "$ROOT/bin/retainer-config.sh"

REPO=""; BRANCH=""; DIR="."; BASE=""; MODE=phase
usage(){
  echo "usage: retainer-branch-phase.sh <owner/repo> [--branch <name>] [--repo-dir <path>]" >&2
  echo "       retainer-branch-phase.sh <owner/repo> --unmerged [--base <branch>] [--repo-dir <path>]" >&2
  exit 2
}
while [ $# -gt 0 ]; do
  case "$1" in
    --unmerged) MODE=unmerged; shift ;;
    --branch)   BRANCH="${2:-}"; [ -n "$BRANCH" ] || usage; shift 2 ;;
    --base)     BASE="${2:-}"; [ -n "$BASE" ] || usage; shift 2 ;;
    --repo-dir) DIR="${2:-}"; [ -n "$DIR" ] || usage; shift 2 ;;
    -*)         usage ;;
    *)          [ -z "$REPO" ] || usage; REPO="$1"; shift ;;
  esac
done
case "$REPO" in */*) ;; *) usage ;; esac
[ -d "$DIR" ] || { echo "no such directory: $DIR" >&2; exit 2; }
git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "not a git repository: $DIR" >&2; exit 2; }

# The main branch name and the remote name are taken from the REPOSITORY, not a constant: on a project with `master`
# (or a remote under another name) the comparison went to a nonexistent ref, i.e. answered about a different
# tree. An explicit `--base` wins — it is the way to compare against a non-standard base.
REMOTE="$(retainer_remote "$DIR")"
[ -n "$REMOTE" ] || REMOTE=origin
# The name for PRINTING is always obtained: the owner instruction in phase mode reads it, and phase mode does not
# resolve the base. An empty name would give "branch off a fresh  " — advice without a subject.
BASE_SHOWN="${BASE:-$(retainer_base_branch "$DIR" "$REMOTE")}"
# The fallback agrees with the phrase it is substituted into ("off a fresh …"): the repository may not declare
# the main branch name, and the advice must stay readable.
[ -n "$BASE_SHOWN" ] || BASE_SHOWN="main-branch state"

# ── unmerged mode ──────────────────────────────────────────────────────────────
# The comparison is against what was JUST fetched (FETCH_HEAD), not a remote-tracking ref that may not have
# updated. "Check is green because it looks at the wrong thing" is a recurring class.
if [ "$MODE" = unmerged ]; then
  # The base is needed ONLY here: phase mode does not read it, and a refusal in the prologue would forbid a run where
  # there is nothing to compare against and no reason to.
  [ -n "$BASE" ] || BASE="$(retainer_base_branch "$DIR" "$REMOTE")"
  [ -n "$BASE" ] || {
    echo "✗ cannot determine the repository main branch — pass --base <branch>" >&2; exit 2; }
  if ! ferr="$(git -C "$DIR" fetch --quiet "$REMOTE" "$BASE" 2>&1)"; then
    echo "✗ fetch $REMOTE $BASE failed — nothing to compare against."
    echo "  Comparing with a stale $REMOTE/$BASE would show merged commits as unmerged;"
    echo "  a silent wrong answer is worse than a refusal, hence the refusal."
    [ -n "$ferr" ] && printf '  %s\n' "$ferr"
    exit 2
  fi
  head_sha="$(git -C "$DIR" rev-parse HEAD 2>/dev/null || printf '')"
  base_sha="$(git -C "$DIR" rev-parse FETCH_HEAD 2>/dev/null || printf '')"
  [ -n "$head_sha" ] && [ -n "$base_sha" ] || {
    echo "✗ HEAD or FETCH_HEAD did not resolve — nothing to compare"; exit 2; }
  list="$(git -C "$DIR" log --oneline "$base_sha..$head_sha" 2>/dev/null || printf '')"
  count="$(printf '%s' "$list" | grep -c . || true)"
  echo "▶ unmerged into $REMOTE/$BASE (after fetch, base ${base_sha:0:7}): commits $count"
  [ -n "$list" ] && printf '%s\n' "$list" | sed 's/^/  /'
  exit 0
fi

# ── phase mode ─────────────────────────────────────────────────────────────────
if [ -z "$BRANCH" ]; then
  BRANCH="$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '')"
fi
[ -n "$BRANCH" ] && [ "$BRANCH" != HEAD ] || {
  echo "⚠ branch name not determined (detached HEAD?) — phase NOT checked"; exit 2; }

API="${GITEA_URL:-$(retainer_cfg tracker_url http://localhost:3000)}/api/v1"
TOKEN="$(retainer_token)"
[ -n "$TOKEN" ] || { echo "⚠ no tracker token — phase of branch «${BRANCH}» NOT checked"; exit 2; }

# The walk is paginated and capped: sorting by recency puts the needed PR on the first page almost
# always, but "almost" is no reason to stop at it.
MAXP="${BRANCH_PHASE_MAX_PAGES:-10}"
page=1; verdict=""; prnum=""
while [ "$page" -le "$MAXP" ]; do
  json="$(curl -s --max-time 15 -H "Authorization: token $TOKEN" \
          "$API/repos/$REPO/pulls?state=all&sort=recentupdate&limit=50&page=$page" 2>/dev/null || printf '')"
  out="$(J="$json" B="$BRANCH" python3 -c '
import json, os, sys

try:
    rows = json.loads(os.environ["J"])
except ValueError:
    sys.exit(3)
if not isinstance(rows, list):
    sys.exit(3)
branch = os.environ["B"]
sys.stdout.write("%d\n" % len(rows))
for row in rows:
    if not isinstance(row, dict):
        continue
    head = row.get("head") or {}
    # After a branch is deleted Gitea replaces head.ref with refs/pull/<N>/head, while head.label keeps
    # the branch name. Matching by ref would lose exactly the case the check exists for.
    label = str(head.get("label") or "")
    name = label.split(":")[-1] or str(head.get("ref") or "").replace("refs/heads/", "")
    if name != branch:
        continue
    if row.get("state") == "open":
        state = "open"
    elif row.get("merged"):
        state = "merged"
    else:
        state = "closed"
    sys.stdout.write("%s %s\n" % (state, row.get("number")))
' 2>/dev/null)" || { echo "⚠ tracker's PR reply not parsed — phase of branch «${BRANCH}» NOT checked"; exit 2; }
  got="$(printf '%s\n' "$out" | sed -n 1p)"
  case "$got" in ''|*[!0-9]*) echo "⚠ tracker did not return a PR list — phase of branch «${BRANCH}» NOT checked"; exit 2 ;; esac
  while IFS=' ' read -r st num; do
    [ -n "$st" ] || continue
    # An open PR beats any closed one: the branch may have been reopened after the previous merge.
    if [ "$st" = open ]; then verdict=open; prnum="$num"; break; fi
    [ -z "$verdict" ] && { verdict="$st"; prnum="$num"; }
  done <<PAGE_EOF
$(printf '%s\n' "$out" | sed 1d)
PAGE_EOF
  [ "$verdict" = open ] && break
  [ "$got" -eq 0 ] && break
  page=$((page + 1))
done

case "$verdict" in
  open)
    echo "▶ branch «${BRANCH}»: PR #$prnum open — phase active, push goes into it"
    exit 0 ;;
  merged)
    echo "✗ branch «${BRANCH}»: PR #$prnum MERGED — phase closed."
    echo "  push here will return 0 and merely move a dead branch: the PR will not grow, nothing will"
    echo "  appear in the tracker. Branch off a fresh $BASE_SHOWN and open a new PR."
    exit 1 ;;
  closed)
    echo "✗ branch «${BRANCH}»: PR #$prnum closed without merge — phase closed."
    echo "  push into it presents nothing to anyone. New work — new branch and new PR."
    exit 1 ;;
  *)
    if [ "$page" -gt "$MAXP" ]; then
      echo "⚠ branch «${BRANCH}»: PR not found within $MAXP pages — this is NOT \"no PR\", but \"not fully scanned\""
      exit 2
    fi
    echo "▶ branch «${BRANCH}»: no PR was created — push opens a new phase"
    exit 0 ;;
esac
