#!/usr/bin/env bash
# retainer: repeated pushing against the guard. The log is an observation, no issues are filed from
# it; this is only a prompt to look into the source by hand. SILENT below the threshold: a report on
# every run stops being read.
#
#   retainer-bypass-alert.sh [project dir] [--days N] [--threshold N]
# exit 0 — threshold not crossed · 1 — repeated push · 2 — usage
#      or log unreadable · 3 — no log at all, no targets.
set -uo pipefail

# shellcheck source=bin/retainer-config.sh

DIR="."; DAYS=1; THRESHOLD=10
while [ $# -gt 0 ]; do
  case "$1" in
    --days)      DAYS="${2:?}"; shift 2 ;;
    --threshold) THRESHOLD="${2:?}"; shift 2 ;;
    -*) echo "usage: retainer-bypass-alert.sh [dir] [--days N] [--threshold N]" >&2; exit 2 ;;
    *) DIR="$1"; shift ;;
  esac
done
case "$DAYS$THRESHOLD" in *[!0-9]*) echo "--days/--threshold: numbers only" >&2; exit 2 ;; esac
[ -d "$DIR" ] || { echo "usage: retainer-bypass-alert.sh [dir] [--days N] [--threshold N]" >&2; exit 2; }
cd "$DIR" || exit 2

LOG=".retainer/bypass.log"
[ -f "$LOG" ] || exit 3        # no log — nothing to check (not "clean": there may have been no bypasses, or the log may never have started)

SINCE="$(python3 -c "
import datetime, sys
sys.stdout.write(str(datetime.date.today() - datetime.timedelta(days=int('$DAYS'))))
" 2>/dev/null)"
[ -n "$SINCE" ] || { echo "could not compute the period — the check is not working" >&2; exit 2; }

# The window boundary is calendar-only. Code that reads a file nobody writes looks working and
# silently is not. A cured source stops counting as entries leave the window — or at once if called
# with `--days`/`--threshold` locally.
BOUND="calendar, $DAYS d."

# Aggregation by the pair "reason x target": the pattern matters, not a single block.
OUT="$(LOG="$LOG" SINCE="$SINCE" THRESHOLD="$THRESHOLD" python3 -c '
import json, os, sys
from collections import Counter

def safe(value):
    """A string that is guaranteed printable.

    Content can be broken, not only format: a surrogate passes json.loads and fails on output, raw
    invalid bytes break the file iteration itself. A catch around json.loads does not reach that,
    and the abort would drop the log tail — and with it the REAL pushes against the guard.
    """
    return str(value).encode("utf-8", "replace").decode("utf-8")

seen = Counter()
broken = 0
try:
    # errors="replace": invalid bytes otherwise break the ITERATION, not the parse of one line.
    with open(os.environ["LOG"], encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if not isinstance(entry, dict):
                continue
            # A guard probe is a diagnostic, not an agent push. It is not counted toward the threshold
            # but stays in the log: "guard was probed" and "was not" must differ.
            if entry.get("probe") is True:
                continue
            ts = str(entry.get("ts", ""))
            # Compare the FULL stamp, not its date: a boundary may be second-precise. Truncated to a
            # date, an entry sorted lexicographically below a same-day timestamped boundary and the
            # whole day dropped out. For a calendar boundary (bare date) the result is the same: a
            # timestamp is greater than it.
            if ts < os.environ["SINCE"]:
                continue
            seen[(safe(entry.get("reason", "?")), safe(entry.get("detail", ""))[:70])] += 1
except OSError:
    sys.exit(3)
except Exception:
    # A parse abort must not drop the tail: what was read is counted, and it STAYS a push. Replacing
    # the verdict with a usage code would lose real pushes.
    sys.stderr.write("! log not read to the end (broken content) — count is incomplete\n")
limit = int(os.environ["THRESHOLD"])
# One axis: the pair "reason x target". A second axis — total per reason — counted hygiene
# observations; the guard no longer writes such reasons, all it has left are blocking.
for (reason, detail), count in seen.most_common():
    if count >= limit:
        sys.stdout.write(f"P\t{count}\t{reason}\t{detail}\n")
')"
rc=$?
[ "$rc" -eq 0 ] || { echo "bypass log not parsed — the check is not working" >&2; exit 2; }
[ -n "$OUT" ] || exit 0        # threshold not crossed — stay silent so as not to train skipping this step

echo "▶ bypass log: since $SINCE ($BOUND), threshold $THRESHOLD"
printf '%s\n' "$OUT" | while IFS="$(printf '\t')" read -r _ n reason detail; do
  printf '  %4s × %s → %s\n' "$n" "$reason" "$detail"
done
{
cat <<'EOF'
✗ the same bypass keeps repeating. This is not "the agent misbehaving": that many attempts in a row
  means either the rule gets in the way for a reason and must be changed deliberately, or the tool
  is inconvenient and the agent goes around it out of inertia. Investigate, do not tolerate.
EOF
echo "  Entries are in .retainer/bypass.log — read them and investigate the cause by hand."
echo "  The count runs over the window: since $SINCE. Once the source is dealt with the entries leave the window on their own,"
echo "  or call with --days/--threshold locally."
} >&2
exit 1
