#!/usr/bin/env bash
# retainer: the `blocked` label must assert something checkable.
#
#   retainer-blocked-check.sh <owner/repo>
# exit 0 — clean · 1 — unfounded labels or invisible blocks found
#      2 — usage / tracker did not answer / no token (fail-closed: silence is not clean)
#
# The `blocked` label by itself asserts nothing checkable: the tracker's dependency field is what
# names a blocker, and a label without it is a promise.
#
# There are TWO holes and they differ:
#   * the field is not filled in where it applies (the blocker is an issue);
#   * the field does not exist where the blocker is a PERSON. A Gitea dependency expresses only
#     issue->issue, so a block on an owner action keeps an empty field however carefully it is filled.
# Hence two legitimate forms of grounds, not one.
#
# A COMMAND, not a gate step — the default from the task. A block lives in the tracker, the gate runs
# in projects that may have no tracker at all, and a network step in an offline gate is red on a plane
# without Wi-Fi. The flow must call it when it sets the label.
#
# The token is read from a file, the value is NEVER printed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=bin/retainer-config.sh
. "$ROOT/bin/retainer-config.sh"

REPO="${1:-}"
case "$REPO" in */*) ;; *) echo "usage: retainer-blocked-check.sh <owner/repo>" >&2; exit 2 ;; esac

API="$(retainer_cfg tracker_url http://localhost:3000)/api/v1"
TOKEN="$(retainer_token)"
[ -n "$TOKEN" ] || { echo "no tracker token — block state cannot be checked" >&2; exit 2; }

api(){ curl -s --max-time 20 -H "Authorization: token $TOKEN" "$API/$1" 2>/dev/null; }

# Open issues. Pagination is mandatory: Gitea cuts the answer at 50 SILENTLY, so a single-page
# request undercounts.
issues=""
page=1
while [ "$page" -le 6 ]; do
  chunk="$(api "repos/$REPO/issues?state=open&type=issues&limit=50&page=$page")"
  [ -n "$chunk" ] || { echo "tracker did not answer — silence is not clean" >&2; exit 2; }
  case "$chunk" in '[]'|'') break ;; esac
  issues="$issues$chunk"
  page=$((page + 1))
done
[ -n "$issues" ] || { echo "tracker did not answer — silence is not clean" >&2; exit 2; }

# Numbers of issues with the label and of issues with a non-empty dependency field. The latter is a
# separate per-issue request: the issue list does not return dependencies.
labelled="$(printf '%s' "$issues" | python3 -c '
import json
import sys

decoder = json.JSONDecoder()
raw = sys.stdin.read()
seen, marked = set(), []
pos = 0
while pos < len(raw):
    while pos < len(raw) and raw[pos].isspace():
        pos += 1
    if pos >= len(raw):
        break
    try:
        rows, pos = decoder.raw_decode(raw, pos)
    except ValueError:
        break
    for row in rows:
        number = row.get("number")
        if number in seen:
            continue
        seen.add(number)
        names = {label.get("name") for label in (row.get("labels") or [])}
        if "blocked" in names:
            marked.append(number)
print(" ".join(str(number) for number in sorted(marked)))
print(" ".join(str(number) for number in sorted(seen)))
')"
[ -n "$labelled" ] || { echo "tracker answer parsing failed — the check is NOT working" >&2; exit 2; }
marked="$(printf '%s\n' "$labelled" | sed -n 1p)"
everyone="$(printf '%s\n' "$labelled" | sed -n 2p)"

# Canonical form for a human blocker. No state field of our own is introduced (default from the
# task): it would have to be synced with the tracker, a third registry of one intent.
HUMAN='Blocker: owner —'

found=0
say(){ found=$((found + 1)); printf '  ✗ %s\n' "$1"; }

for number in $marked; do
  body="$(api "repos/$REPO/issues/$number" | python3 -c '
import json
import sys

try:
    row = json.load(sys.stdin)
except ValueError:
    row = {}
print((row.get("body") or "").replace("\r", ""))
')"
  deps="$(api "repos/$REPO/issues/$number/dependencies" | python3 -c '
import json
import sys

try:
    rows = json.load(sys.stdin)
except ValueError:
    rows = []
print(len(rows) if isinstance(rows, list) else 0)
')"
  [ "${deps:-0}" -gt 0 ] && continue
  case "$body" in *"$HUMAN"*) continue ;; esac
  say "#$number: blocked label without grounds — neither a tracker dependency nor a line \"$HUMAN <what to do>\""
done

# Reverse check: a dependency exists but no label — the block is invisible in the issue list and
# drops out of planning precisely because it cannot be seen.
for number in $everyone; do
  case " $marked " in *" $number "*) continue ;; esac
  deps="$(api "repos/$REPO/issues/$number/dependencies" | python3 -c '
import json
import sys

try:
    rows = json.load(sys.stdin)
except ValueError:
    rows = []
print(len(rows) if isinstance(rows, list) else 0)
')"
  [ "${deps:-0}" -gt 0 ] && say "#$number: tracker dependency exists, no blocked label — the block is invisible in the list"
done

if [ "$found" -eq 0 ]; then
  printf '▶ blocks: clean (issues with the label: %s)\n' "$(printf '%s' "$marked" | wc -w | tr -d ' ')"
  exit 0
fi
printf '✗ unfounded blocks: %s. A label that asserts nothing reads as\n' "$found" >&2
printf '  "someone knows why" — and nobody does.\n' >&2
printf '  Grounds are one of two: an issue->issue dependency in the tracker or a line "%s <what exactly>".\n' "$HUMAN" >&2
exit 1
