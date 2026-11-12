#!/usr/bin/env bash
# retainer: machine-checkable definition of task readiness.
#
# Labels at creation are classification (priority · area · type · impact, known immediately). Readiness is a
# claim about STATE: it is checked, not declared.
#
#   retainer-ready-check.sh <owner/repo> <task number>   — one task
#   retainer-ready-check.sh <owner/repo> --all            — report on all tasks labelled ready
# exit 0 — the task can be taken · 1 — it cannot, what is missing is printed · 2 — usage / tracker silent.
#
# The token is read from a file; its value is NOT printed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=bin/retainer-config.sh
. "$ROOT/bin/retainer-config.sh"

REPO="${1:-}"; WHAT="${2:-}"
usage(){ echo "usage: retainer-ready-check.sh <owner/repo> <task number|--all>" >&2; exit 2; }
case "$REPO" in */*) ;; *) usage ;; esac
case "$WHAT" in --all) ;; ''|*[!0-9]*) usage ;; esac

API="$(retainer_cfg tracker_url http://localhost:3000)/api/v1"
TOKEN="$(retainer_token)"
[ -n "$TOKEN" ] || { echo "no tracker token — readiness cannot be checked"; exit 2; }

api(){ curl -s --max-time 20 -H "Authorization: token $TOKEN" "$API/$1" 2>/dev/null; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Siblings: ALL open tasks of the repository. Needed both for dependencies and to check that a
# neighbouring task does not hit the same files. Must be paged: Gitea silently cuts the response at
# its own ceiling (50), and `limit=100` yields a truncated list with no sign of truncation — then
# "dependency closed" and "no collisions" are answered from incomplete data, the more confidently
# the larger the repository.
PAGE=1
: > "$WORK/pages.jsonl"
while [ "$PAGE" -le 20 ]; do
  api "repos/$REPO/issues?state=open&type=issues&limit=50&page=$PAGE" > "$WORK/page.json"
  [ -s "$WORK/page.json" ] || { echo "tracker did not respond — readiness cannot be checked"; exit 2; }
  got="$(P="$WORK/page.json" python3 -c '
import json, os, sys
try:
    with open(os.environ["P"], encoding="utf-8") as fh:
        page = json.load(fh)
except (OSError, ValueError):
    sys.exit(3)
if not isinstance(page, list):
    sys.exit(3)
sys.stdout.write(str(len(page)))
')" || { echo "task list not parsed — the check is not working"; exit 2; }
  cat "$WORK/page.json" >> "$WORK/pages.jsonl"
  printf '\n' >> "$WORK/pages.jsonl"
  [ "$got" -lt 50 ] && break
  PAGE=$((PAGE + 1))
done
J="$WORK/pages.jsonl" O="$WORK/siblings.json" python3 -c '
import json, os, sys
merged = []
with open(os.environ["J"], encoding="utf-8") as fh:
    for line in fh:
        if line.strip():
            merged.extend(json.loads(line))
with open(os.environ["O"], "w", encoding="utf-8") as out:
    json.dump(merged, out)
' || { echo "task pages did not merge — the check is not working"; exit 2; }

# One task: body + comments → parse → report. The parser prints problems one per line; the header and
# verdict are assembled here, so python has neither formatting nor output modes.
check_one(){
  local num="$1" title problems rc
  api "repos/$REPO/issues/$num"           > "$WORK/issue.json"
  api "repos/$REPO/issues/$num/comments"  > "$WORK/comments.json"
  title="$(ISSUE="$WORK/issue.json" python3 -c '
import json, os, sys
try:
    with open(os.environ["ISSUE"], encoding="utf-8") as fh:
        print((json.load(fh).get("title") or "")[:70])
except Exception:
    sys.exit(0)
')"
  problems="$(ISSUE="$WORK/issue.json" COMMENTS="$WORK/comments.json" SIBLINGS="$WORK/siblings.json" \
    NUM="$num" python3 "$ROOT/bin/retainer_ready_check.py")"
  rc=$?
  case "$rc" in
    0) printf '✓ #%s %s\n' "$num" "$title"
       printf '  form is complete. Whether the criterion is verifiable is up to a human; the machine cannot see it.\n'
       return 0 ;;
    2) printf '✗ #%s — %s\n' "$num" "$problems"
       # "not checked" ≠ "not ready": the caller must tell them apart, otherwise a tracker failure
       # looks like a verdict on the task.
       return 2 ;;
  esac
  printf '✗ #%s %s\n' "$num" "$title"
  printf '%s\n' "$problems" | sed 's/^/  — /'
  [ "${MODE:-one}" = all ] || printf '  What is missing is filled in by grooming BEFORE the start, not by reconnaissance inside the task.\n'
  return 1
}

if [ "$WHAT" = --all ]; then
  # An empty list and a broken parse are DIFFERENT outcomes. Merged into one they give the most
  # dangerous answer: "nothing to check, all fine" instead of "the check is not working".
  nums="$(S="$WORK/siblings.json" python3 -c '
import json, os, sys
try:
    with open(os.environ["S"], encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError, KeyError):
    sys.exit(3)
if not isinstance(data, list):
    sys.exit(3)
for it in data:
    if any(lb.get("name") == "ready" for lb in it.get("labels") or []):
        print(it["number"])
')"
  case "$?" in 0) ;; *) echo "task list not parsed — the check is not working"; exit 2 ;; esac
  [ -n "$nums" ] || { echo "no tasks with the ready label"; exit 0; }
  bad=0; total=0
  for n in $nums; do
    total=$((total + 1))
    MODE=all check_one "$n" || bad=$((bad + 1))
  done
  echo "── total: $bad of $total labelled ready cannot be taken"
  [ "$bad" -eq 0 ]
  exit $?
fi

check_one "$WHAT"
