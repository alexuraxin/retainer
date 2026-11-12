#!/usr/bin/env bash
# retainer: discipline digest -- where it slips most often (observability). READ-ONLY (sample: blast-radius:
# touches no code, only reads and prints). Aggregate over managed repos (registry ~/.config/retainer/managed-repos)
# + the global guard bypass log: incidents by type · top signatures (reason·detail) · [rigor] coverage.
#
#   retainer-digest.sh [--repos-file FILE] [--since YYYY-MM-DD] [--top N]
#
# Registry: --repos-file else $HOME/.config/retainer/managed-repos (one path per line). Global log:
# $HOME/.retainer/bypass.log (a HOME override isolates the test). No network, no mutation.
# SHARE-SAFE: tokens are redacted at the SOURCE; the digest additionally masks /Users/<user>/, email, public
# IP in the printed detail -- safe to show a colleague.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

REPOS_FILE="$HOME/.config/retainer/managed-repos"
SINCE=""; TOP=10
while [ $# -gt 0 ]; do
  case "$1" in
    --repos-file) REPOS_FILE="${2:?}"; shift 2 ;;
    --since)      SINCE="${2:?}"; shift 2 ;;
    --top)        TOP="${2:?}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

REPOS=()
if [ -f "$REPOS_FILE" ]; then
  while IFS= read -r r; do
    if [ -n "$r" ]; then REPOS+=("$r"); fi
  done < "$REPOS_FILE"
fi
GLOBAL_LOG="$HOME/.retainer/bypass.log"

# The step kind is asked of the registry OWNER (retainer-gate-steps.sh), not derived here: an
# undeclared key means different things for the two kinds -- a regular step defaults to "enabled" in
# the runner, a selfgate step stays silent, and a second list would drift from the first silently.
# An unread answer is not "no selfgate steps": that case is named by a line, and state signs do not
# discriminate. The answer shape is checked: a runner printing something else instead of the list
# would become a source of names.
SELFGATE=""
SELFGATE_READ=0
if selfgate_raw="$(bash "$HERE/retainer-gate-steps.sh" --list-selfgate 2>/dev/null)"; then
  SELFGATE="$(printf '%s\n' "$selfgate_raw" | grep -E '^[a-z_][a-z0-9_]*$' || true)"
  # An empty answer with exit 0 is legal -- there may be no selfgate steps at all. A non-empty one
  # yielding no key of the right shape means "could not be read".
  if [ -n "$(printf '%s' "$selfgate_raw" | tr -d '[:space:]')" ] && [ -z "$SELFGATE" ]; then
    SELFGATE_READ=0
  else
    SELFGATE_READ=1
  fi
fi

# The list goes via the ENVIRONMENT: positional arguments end in a variable tail of repositories,
# and a list appended at the end would merge with them.
RETAINER_SELFGATE="$SELFGATE" RETAINER_SELFGATE_READ="$SELFGATE_READ" \
python3 - "$SINCE" "$TOP" "$GLOBAL_LOG" ${REPOS[@]+"${REPOS[@]}"} <<'PY'
import sys, json, os, re
from collections import Counter

since = sys.argv[1]; top = int(sys.argv[2]); global_log = sys.argv[3]; repos = sys.argv[4:]
RIGOR = ["hooks_check","guard_registration","doc_links","agent_canon","protected_copy","bypass_alert","hot_context","remote_creds","skills_catalog","dependency_check","deny_sync","doc_claims","runner_labels","complexity_trace","prose_lang","prototype_debt","glossary_terms","practices_form","secret_scan","req_trace","django_extras","js_gate"]

SELFGATE = set((os.environ.get("RETAINER_SELFGATE") or "").split())
SELFGATE_READ = os.environ.get("RETAINER_SELFGATE_READ") == "1"

def cell_of(key, flags):  # state sign of a regulator in the coverage table
    # Presence is judged by the FACT of the entry, not by comparison with the absence sign: else a
    # value that coincides with the sign passes for an undeclared key. An empty value is not a
    # declaration: the step, the check and the gate all read it so (the default fills the empty slot).
    # A missing key and an empty value are one state, "undeclared": the step reads them so too.
    value = flags.get(key, "")
    if value == "":
        if not SELFGATE_READ:
            return "?"
        return "?" if key in SELFGATE else "\u00b7"
    if value == "false":
        return "\u00d7"
    return "✓" if value == "true" else value[:5]

def mask(s):  # share-safe: hide identity (tokens are already redacted at the source)
    s = re.sub(r'/Users/[^/ "]+', '/Users/…', s)
    s = re.sub(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '…@…', s)
    s = re.sub(r'\b(?:\d{1,3}\.){3}\d{1,3}\b', 'x.x.x.x', s)
    return s

def safe(s):
    """A string that is guaranteed printable.

    Not only the entry format can be broken but its CONTENT: a surrogate from `\\udXXX` passes
    json.loads and fails only on output, and raw invalid bytes in the file crash the read itself.
    Neither is caught by a guard around json.loads -- the abort takes the whole log tail, and the
    summary shows "no incidents" where they were not counted.
    """
    return str(s).encode('utf-8', 'replace').decode('utf-8')

def parse_log(path, label):
    out = []
    broken = 0
    try:
        # errors='replace': invalid bytes in the file otherwise crash the ITERATION, not the line
        # parse, and a guard around json.loads does not reach that.
        with open(path, encoding='utf-8', errors='replace') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except Exception:
                    continue                                  # broken line -> skip
                if not isinstance(e, dict):
                    continue                                  # valid JSON but not an object (number/array/bool) -> skip, no crash
                reason = safe(e.get("reason", "")); ts = safe(e.get("ts", ""))
                detail = e.get("detail", "")
                if not isinstance(detail, str):               # non-string detail -> to string (no mask/Counter crash)
                    detail = json.dumps(detail, ensure_ascii=True)
                detail = safe(detail)
                if not reason:
                    continue
                if since and ts and ts[:10] < since:          # junk/empty ts -> do not cut (include), do not fail
                    continue
                out.append((reason, detail, ts, label))
    except OSError:
        pass                                                  # no file / unreadable -- repo without incidents, normal
    except Exception:
        # An abort must not take the log tail: what was read stays in the summary, and the abort is
        # named aloud -- "no incidents" and "not fully counted" must be distinguishable.
        sys.stderr.write("  ! log %s not read to the end (broken content)\n" % label)
    return out

incidents = []; coverage = {}
for r in repos:
    label = os.path.basename(r.rstrip('/')) or r
    incidents += parse_log(os.path.join(r, ".retainer", "bypass.log"), label)
    cfg = os.path.join(r, ".retainer", "config.toml")
    try:
        flags = {}; inr = False
        with open(cfg, encoding='utf-8') as f:
            for line in f:
                st = line.strip()
                if st.startswith('['):
                    inr = (st == '[rigor]')
                elif inr and '=' in st:
                    k, v = st.split('=', 1); k = k.strip()
                    # The SAME threshold the step and gate judge by (`rigor()` in retainer-gate-steps.sh --
                    # one function for both): all quotes and all whitespace bytes are stripped, not only
                    # the edges. Else `key = "  "` reads as a value, prints as an empty cell -- a sign
                    # absent from the legend -- while the step on the same config stays silent. The kit
                    # check reads this form DIFFERENTLY (its `cfg` strips only the edges and counts the
                    # key as declared); aligning its threshold is a separate task, unchanged here.
                    v = re.sub(r'[\s"\']', '', v.split('#', 1)[0])
                    if k in RIGOR:
                        flags[k] = v
        coverage[label] = flags
    except OSError:
        coverage[label] = None                                # no config / unreadable -- not under retainer

global_inc = parse_log(global_log, "global-guard")
incidents += global_inc

print("═══ retainer discipline digest ═══")
print("period: %s · repos: %d managed + global · incidents: %d\n"
      % ("since " + since if since else "all time", len(repos), len(incidents)))

if not incidents:
    print("no incidents recorded.")
else:
    print("── incidents by type ──")
    for reason, n in Counter(i[0] for i in incidents).most_common():
        print("  %3d  %s" % (n, reason))
    print("\n── top signatures (reason · detail) ──")
    for (reason, detail), n in Counter((i[0], i[1]) for i in incidents).most_common(top):
        print("  %3d  %s · %s" % (n, reason, mask(detail)[:80]))

print("\n── regulator coverage ──")
if not coverage:
    print("  (no managed repos in the registry)")
else:
    print("  " + "project".ljust(16) + " ".join(f[:5].ljust(5) for f in RIGOR))
    for label, flags in coverage.items():
        if flags is None:
            print("  " + label[:16].ljust(16) + "(not under retainer)")
            continue
        row = "  " + label[:16].ljust(16)
        for f in RIGOR:
            row += cell_of(f, flags).ljust(5) + " "
        print(row)
    print("  signs: ✓ enabled | \u00d7 disabled by decision | \u00b7 undeclared, regular step runs"
          " by default | ? undeclared, selfgate step silent | other -- value from the config")
    if not SELFGATE_READ:
        print("  ! selfgate step list not read -- kind of undeclared key unknown,"
              " all such printed as \"?\"")

if global_inc:
    print("\nglobal guard bypass log: %d incidents" % len(global_inc))

# Tail of the last sync run. The sync runs by exactly one path -- the Stop hook -- and its output
# must not vanish into /dev/null along with messages that get no second chance: the one-time seed
# message, the unreachable-tracker diagnostic, the broken-record count. Show ONLY lines needing
# attention: the full log is in the file, and the digest is a summary, not a journal.
sync_log = os.path.join(os.path.expanduser("~"), ".cache", "retainer", "sync.log")
try:
    with open(sync_log, encoding="utf-8", errors="replace") as fh:
        tail = fh.read().splitlines()[-40:]
except OSError:
    tail = []
notable = [ln for ln in tail if ln.lstrip().startswith("!") or "seed" in ln or "broken records:" in ln]
notable = [ln for ln in notable if not ln.rstrip().endswith("broken records: 0")]
if notable:
    print("\nsync (last run, %s):" % sync_log)
    for line in notable[-5:]:
        print("  " + line.strip()[:100])
PY
