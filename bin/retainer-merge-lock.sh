#!/usr/bin/env bash
# retainer: merge lock EXECUTOR — turns a verdict into a mandatory status check.
#
#   retainer-merge-lock.sh <owner/repo> <number>
# exit 0 — verdict issued as a status (green or red), or the number is not a PR (nothing to lock)
#      2 — usage / no token / tracker did not answer / could not check / status not written
#
# THERE IS NO EXIT 1. A refusal is the mechanism WORKING, and a red job for it would be
# indistinguishable from a broken suite, so a refusal is published as a red status and the job goes
# green. A red job then means one thing only: something is broken.
#
# Why a separate executor. `retainer-merge-ready.sh` knows whether merging is allowed, but its verdict
# lived as a terminal line: whether to call the lock was up to the agent. Here the verdict is put
# outside — into a commit status that the tracker requires for merging (branch protection, `status_check_contexts`).
#
# THE CEILING IS NAMED HONESTLY: the status is written with the same token the agent uses with the tracker, so
# "cannot be bypassed" is false. True: merge is closed while no GREEN status stands on the head — whether
# none was issued or the issued one is red — and writing a green one past the lock is a separate deliberate
# act, and it stays in the commit status log.
#
# WHY A REFUSAL IS PUBLISHED TOO. Publishing it is safe only because the reader excludes this very
# context when it judges a head: the server computes a head's combined status as the worst of all
# contexts, so a lock that read its own red back would refuse for ever. Given that, publishing buys two
# things — the verdict is readable on the pull request without opening a run, and a condition that
# REGRESSES closes the merge again instead of leaving an earned green with nothing to overwrite it.
#
# "Could not check" is not a verdict and is not published: exit 2 keeps the job red, because an
# unreachable tracker or a broken parse IS a breakage, and red is the right signal for it.
#
# HEAD. The status is hung on the commit the lock gave the verdict on, not on "the current branch".
# A new commit has no status of its own, and merge is closed until the lock runs again.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=bin/retainer-config.sh
. "$ROOT/bin/retainer-config.sh"

# Status context, from the engine's shared config. The name must match the server setting
# (`status_check_contexts` of branch protection), and it has exactly one home because TWO readers
# need the same string: this publisher and the reader that excludes its own verdict. A literal in
# each would drift silently; the config carries it as a plain assignment, so the environment cannot
# decide it either.
LOCK_CONTEXT="$RETAINER_LOCK_CONTEXT"

REPO="${1:-}"; NUM="${2:-}"
usage(){ echo "usage: retainer-merge-lock.sh <owner/repo> <PR number | head-SHA>" >&2; exit 2; }
case "$REPO" in */*) ;; *) usage ;; esac
# The second argument is a PR number or a run head. A gate-completion event does not know the PR number:
# it has only the SHA the gate ran on. The forms differ by composition: a number is decimal,
# a head is hex of seven or more characters.
BY_SHA=""
case "$NUM" in
  '') usage ;;
  *[!0-9]*)
    case "$NUM" in
      *[!0-9a-fA-F]*) usage ;;
      ???????*)       BY_SHA="$NUM" ;;
      *)              usage ;;
    esac ;;
esac

API="$(retainer_cfg tracker_url http://localhost:3000)/api/v1"
TOKEN="$(retainer_token)"   # in CI it arrives as the run token; in a terminal it is read from a file
[ -n "$TOKEN" ] || { echo "no tracker token — nothing to issue the status with, merge stays closed"; exit 2; }

api(){ curl -s --max-time 15 -H "Authorization: token $TOKEN" "$@"; }

# ── run head → PR number ───────────────────────────────────────────────────────
# A gate run completes on a branch without a PR too, and on a push to main. There is nothing to lock there,
# and no verdict to publish either: unlike a refusal, which is a verdict about a real PR, this event has no
# subject at all.
#
# Searched among OPEN PRs: a verdict is useless for a closed one, and the head of a closed branch may coincide with
# the current head after a stacked merge.
list=""
if [ -n "$BY_SHA" ]; then
  list="$(mktemp)"
  trap 'rm -f "$list"; [ -n "${pr_body:-}" ] && rm -f "$pr_body"' EXIT
  # The page size is set by the INSTANCE, not our `limit`: a full page is indistinguishable from a full list,
  # and "not found" on it means "did not look further". That outcome is "not checked", not "nothing there".
  PAGE=50
  http="$(api -o "$list" -w '%{http_code}' "$API/repos/$REPO/pulls?state=open&limit=$PAGE")"
  [ "$http" = 200 ] || { echo "tracker answered ${http:-nothing} on the PR list — not issuing status"; exit 2; }
  # The parse answers with THREE different outcomes, and they must not be confused: a number · "not in the list" · "not
  # parsed". Empty output is the most broken state (no python3, it crashed, output did not arrive), and
  # it must read as "not checked", otherwise a quiet zero asserts a check that did not happen.
  #
  # Outcome markers are Latin: the value crosses the python → shell boundary, and under a non-
  # UTF-8 locale printing Cyrillic fails, turning a normal outcome into a red job.
  NUM="$(SHA="$BY_SHA" PAGE="$PAGE" python3 -c '
import json, os, sys

want = os.environ["SHA"].lower()
try:
    data = json.load(sys.stdin)
except ValueError:
    print("?"); sys.exit()
if not isinstance(data, list):
    print("?"); sys.exit()
hits = []
for pull in data:
    if not isinstance(pull, dict):
        print("?"); sys.exit()
    head = ((pull.get("head") or {}).get("sha") or "").lower()
    if head and head.startswith(want):
        hits.append(pull.get("number"))
if len(hits) > 1:
    print("many"); sys.exit()
if hits:
    print(hits[0] or "?"); sys.exit()
print("edge" if len(data) >= int(os.environ["PAGE"]) else "none")
' < "$list")"
  case "$NUM" in
    ''|'?') echo "PR list not parsed — not issuing status"; exit 2 ;;
    'many') echo "head $BY_SHA is shared by several open PRs — unknown which to lock"; exit 2 ;;
    'edge')  echo "open PR list hit the page size, no match on it — not checked"; exit 2 ;;
    'none')   echo "run on $BY_SHA belongs to no open PR — nothing to lock"; exit 0 ;;
  esac
  echo "▶ head $BY_SHA is PR #$NUM"
fi

# ── what number we were given ──────────────────────────────────────────────────
# An `issue_comment` event also comes from plain issues: they have no pull request of the same number, and
# the tracker answers 404. That is not a run failure — nothing to lock.
#
# The RESPONSE CODE is judged, not the body. Gitea returns an error as valid json without PR fields, and "no `state`
# field" looks the same for 404 (plain issue) and 401 (token went stale). The body cannot tell them apart,
# and the outcomes are opposite: the first is a normal quiet zero, the second is "not checked".
pr_body="$(mktemp)"
trap 'rm -f "$pr_body"; [ -n "${list:-}" ] && rm -f "$list"' EXIT
http="$(api -o "$pr_body" -w '%{http_code}' "$API/repos/$REPO/pulls/$NUM")"
case "$http" in
  200) ;;
  404) echo "#$NUM in $REPO is not a pull request, nothing to lock"; exit 0 ;;
  ''|000) echo "tracker did not answer about #$NUM — not issuing status"; exit 2 ;;
  *)   echo "tracker answered $http to the request about #$NUM — not issuing status"; exit 2 ;;
esac
read -r head base state <<EOF
$(python3 -c '
import json, sys

try:
    d = json.load(sys.stdin)
except Exception:
    print("? ? ?"); sys.exit()
if not isinstance(d, dict) or "state" not in d:
    print("? ? ?"); sys.exit()
print((d.get("head") or {}).get("sha") or "?",
      (d.get("base") or {}).get("ref") or "?",
      d.get("state") or "?")
' < "$pr_body")
EOF
# Empty is not "no head" but "the parse did not run at all": no python3, it crashed, output did not arrive.
# Such input must read as "not checked", otherwise the most broken state falls through
# the code with empty variables and ends in a quiet zero.
case "$head" in
  ''|'?') echo "tracker response about #$NUM not parsed — not issuing status"; exit 2 ;;
esac
[ "$base" = "?" ] && { echo "PR #$NUM has no base branch named — not issuing status"; exit 2; }
# A closed or merged PR has nothing to lock: no verdict is published under it at all. Unlike a refusal,
# where merge WAITS for permission, here it will never come.
[ "$state" = open ] || { echo "PR #$NUM is not open (state: $state) — nothing to lock"; exit 0; }

# ── the verdict itself ─────────────────────────────────────────────────────────
# Whether the status locks merge is decided by the SERVER: the context must stand in `status_check_contexts`
# of the base branch protection. Checking that from here is useless — `branch_protections` is readable only with
# repo admin rights, while the run uses the job token: the answer would be "not checked"
# on every run, i.e. exactly where the answer is needed. The setting lives in one-time repo
# setup, not in a step executed on every comment.
verdict="$("$ROOT/bin/retainer-merge-ready.sh" "$REPO" "$NUM" 2>&1)"; rc=$?
printf '%s\n' "$verdict"
# Three outcomes of the reader, and only two of them are verdicts. Code 2 says the reader could not
# check — an environment breakage, published as nothing and left as a red job.
case "$rc" in
  0|1) ;;
  *)   echo "✗ lock could not check (code $rc) — status «${LOCK_CONTEXT}» not issued, merge stays closed"
       exit 2 ;;
esac
if [ "$rc" = 0 ]; then
  STATE=success
  REASON="verdict on $(printf '%s' "$head" | cut -c1-7)"
else
  STATE=failure
  # The LAST unindented line of the verdict. The reader prints a reason unindented and its details
  # indented, so the reason is the last line at column zero — not the FIRST, because checks that
  # PASS also report at column zero on their way through (release discipline says so twice), and on
  # a release PR the first such line would be a pass-through note published as the reason.
  # The whole verdict stays in the run log, which `target_url` points at.
  REASON="$(printf '%s\n' "$verdict" | awk 'NF && $0 !~ /^[[:space:]]/ {last = $0} END {print last}')"
  [ -n "$REASON" ] || REASON="refused, the reason is in the run log"
fi

# ── verdict outward ────────────────────────────────────────────────────────────
# The description is cut HERE rather than silently in the UI: on a refusal it is the only place the
# reason is visible without opening the run, and the job is green now, so nobody opens it.
#
# Escaped to ASCII on purpose. Verdict lines carry guillemets and dashes, and this value crosses
# the python to shell boundary and then goes into a json body; under a non-UTF-8 locale printing it
# raw would fail and turn a normal refusal into a red job.
body="$(STATE="$STATE" REASON="$REASON" CTX="$LOCK_CONTEXT" URL="${MERGE_LOCK_RUN_URL:-}" python3 -c '
import json, os

print(json.dumps({
    "context": os.environ["CTX"],
    "state": os.environ["STATE"],
    "description": ("merge lock: " + os.environ["REASON"])[:140],
    "target_url": os.environ["URL"],
}, ensure_ascii=True))
')"
code="$(api -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
        -d "$body" "$API/repos/$REPO/statuses/$head")"
# A status that did not get written leaves the head carrying whatever stood there before — which is a
# stale GREEN where one was earned earlier, so the job is red on both paths rather than only on the
# refusal one. The red job is the whole signal here; the agent's own call before a merge is the second.
case "$code" in
  200|201) ;;
  *)       echo "✗ status not written (code $code) — merge stays closed"; exit 2 ;;
esac
if [ "$STATE" = success ]; then
  echo "✓ status «${LOCK_CONTEXT}» issued on $head — merge open until the next commit"
else
  echo "✓ refusal issued as «${LOCK_CONTEXT}» failure on $head — merge closed, and the job is not a breakage"
fi
exit 0
