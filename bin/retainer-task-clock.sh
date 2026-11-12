#!/usr/bin/env bash
# retainer: calendar duration of a task -- the clock hangs on steps that touch the task anyway; a
# separate ritual does not take root for measurement.
#
#   retainer-task-clock.sh <owner/repo> start|stop <task number>
#   retainer-task-clock.sh <owner/repo> report [--limit N]
# exit 0 -- done · 1 -- tracker refused · 2 -- usage / no token.
#
# This is CALENDAR duration, not effort: pauses and waiting lie between start and stop. It must not
# be called anything else -- a misnamed figure gets optimized instead of analyzed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=bin/retainer-config.sh
. "$ROOT/bin/retainer-config.sh"

REPO="${1:-}"; ACTION="${2:-}"
usage(){ echo "usage: retainer-task-clock.sh <owner/repo> start|stop <number> | report [--limit N]" >&2; exit 2; }
case "$REPO" in */*) ;; *) usage ;; esac
LIMIT=20
case "$ACTION" in
  start|stop)
    NUM="${3:-}"
    case "$NUM" in ''|*[!0-9]*) usage ;; esac ;;
  report)
    [ "${3:-}" = --limit ] && LIMIT="${4:-20}"
    case "$LIMIT" in ''|*[!0-9]*) usage ;; esac ;;
  *) usage ;;
esac

# GITEA_URL is the same seam as in preflight/pipeline/task-close: the measurement must go to the SAME
# host where the task lives, otherwise stop goes into the void and the caller sees "tracker did not stop the clock".
API="${GITEA_URL:-$(retainer_cfg tracker_url http://localhost:3000)}/api/v1"
TOKEN="$(retainer_token)"
[ -n "$TOKEN" ] || { echo "no tracker token -- time cannot be recorded"; exit 2; }

api(){ curl -s --max-time 15 -H "Authorization: token $TOKEN" "$@"; }

case "$ACTION" in
  start)
    # One stopwatch per user: if busy with another task, silence is not allowed -- the measurement would go astray.
    codeout="$(api -o /dev/null -w '%{http_code}' -X POST "$API/repos/$REPO/issues/$NUM/stopwatch/start")"
    case "$codeout" in
      201) echo "▶ clock for task #$NUM started"; exit 0 ;;
      409) echo "⚠ the stopwatch is already busy with another task -- this measurement was not started (one per user)"; exit 1 ;;
      *)   echo "⚠ the tracker did not start the clock (code $codeout) -- the task is taken anyway, the measurement is just not kept"; exit 1 ;;
    esac ;;
  stop)
    codeout="$(api -o /dev/null -w '%{http_code}' -X POST "$API/repos/$REPO/issues/$NUM/stopwatch/stop")"
    case "$codeout" in
      201) ;;
      *) echo "⚠ the tracker did not stop the clock (code $codeout) -- maybe it was never running"; exit 1 ;;
    esac
    api "$API/repos/$REPO/issues/$NUM/times" | NUM="$NUM" python3 -c '
import json, os, sys
try:
    rows = json.load(sys.stdin)
except ValueError:
    rows = []
total = sum(int(row.get("time", 0)) for row in rows) if isinstance(rows, list) else 0
hours, rest = divmod(total, 3600)
num = os.environ["NUM"]
sys.stdout.write("▶ task #%s: calendar duration %s h %s min\n" % (num, hours, rest // 60))
'
    exit 0 ;;
esac

# report: per-task table -- input for analyzing "why is this one longer than its neighbor", not a productivity measure.
api "$API/repos/$REPO/times?limit=1000" | LIMIT="$LIMIT" python3 -c '
import json, os, sys
from collections import defaultdict

try:
    rows = json.load(sys.stdin)
except ValueError:
    sys.stderr.write("tracker did not answer -- no measurements\n")
    raise SystemExit(1)
if not isinstance(rows, list):
    sys.stderr.write("tracker answered with an error -- no measurements\n")
    raise SystemExit(1)
if not rows:
    sys.stdout.write("no time measurements: no task has been recorded yet\n")
    raise SystemExit(0)
per = defaultdict(int)
for row in rows:
    per[int(row.get("issue_id", 0))] += int(row.get("time", 0))
sys.stdout.write("── calendar duration of tasks (not effort) ──\n")
for issue_id, secs in sorted(per.items(), key=lambda pair: -pair[1])[: int(os.environ["LIMIT"])]:
    sys.stdout.write(f"  {secs // 3600:4d} h {secs % 3600 // 60:02d} min   task id {issue_id}\n")
sys.stdout.write("\nPauses and waiting lie between start and stop -- this is duration, not work.\n")
'
