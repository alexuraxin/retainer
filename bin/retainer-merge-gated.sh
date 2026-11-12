#!/bin/bash -p
# retainer: the owner-switched merge path — merge ONE pull request only while the merge setting is on
# and the latest lock and gate rows on its head are green and were written by an Actions run (which a
# PR changing the code the gate runs can still mint: the run token reaches that step).
#
#   retainer-merge-gated.sh [--check] <owner/repo> <PR number>
# exit 0 — merged (with --check: every condition holds, nothing was sent)
# exit 1 — refused (reason on stdout)
# exit 2 — usage / tracker did not answer / no token (fail-closed: tracker silence is not permission)
#
# The owner installs it root-owned into INSTALL_DIR and allows exactly that path. From there it trusts
# nothing the agent can write: `-p` skips BASH_ENV, SHELLOPTS and exported functions; python, curl,
# mktemp and rm run under an empty environment by absolute path; curl reads no curlrc (`-q` must stay
# its first argument); the config is
# found by the account's home from the password database; the tracker origin is the constant below.
# The token travels in a header file inside the 0700 work directory, never in argv or on stdout.
# Install it at INSTALL_DIR exactly: anywhere else the test seam and tracker_url are honoured. On
# another machine or repository, set INSTALL_DIR, INSTALLED_TRACKER and GATE_CTX to its own first.
# complexity: keep, step 7 — without it the only merge path the classifier lets through is the owner's hand
set -uo pipefail
PATH=/usr/bin:/bin
export PATH

INSTALL_DIR=/opt/retainer/bin
INSTALLED_TRACKER=http://localhost:3000
LOCK_CTX="retainer/merge-lock"
GATE_CTX="gate / gate (pull_request)"
API_TIMEOUT=15
MERGE_TIMEOUT=600

clean() { /usr/bin/env -i PATH=/usr/bin:/bin "$@"; }
py() { clean /usr/bin/python3 -I "$@"; }
http() { clean /usr/bin/curl -q -s -H "@$WORK/auth" "$@"; }

usage() { echo "usage: retainer-merge-gated.sh [--check] <owner/repo> <PR number>" >&2; exit 2; }
CHECK=0
[ "${1:-}" = "--check" ] && { CHECK=1; shift; }
[ $# -eq 2 ] || usage
REPO="$1"; PR="$2"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
case "$REPO" in *..*) usage ;; esac
case "$PR" in ''|*[!0-9]*) usage ;; esac

SELF_DIR="$(cd "$(/usr/bin/dirname "$0")" && pwd -P)"
HOME_DIR="$(py -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')"
CFG="$HOME_DIR/.config/retainer/config.toml"
# The test seam: honoured only outside the install directory, so the installed copy never reads it.
INSTALLED=0
[ "$SELF_DIR" = "$INSTALL_DIR" ] && INSTALLED=1
if [ "$INSTALLED" = 0 ] && [ -n "${RETAINER_MERGE_GATED_CONFIG:-}" ]; then
  CFG="$RETAINER_MERGE_GATED_CONFIG"
fi

# Same reading as retainer_cfg: flat keys before the first table, first match wins, quotes and
# trailing comments stripped.
cfg() {
  [ -f "$CFG" ] || return 0
  /usr/bin/awk -v k="$1" '
    /^[[:space:]]*\[/ { exit }
    $0 ~ ("^[[:space:]]*" k "[[:space:]]*=") {
      sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, "");
      gsub(/["'"'"']/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "");
      print; exit
    }' "$CFG" 2>/dev/null
}

# The switch mirrors `retainer-flow-policy.sh merge` for the two values that mean "on": an explicit
# auto, or unset under marathon. Any other value refuses.
FLOW_MERGE="$(cfg flow_merge)"
LEVEL="$(cfg autonomy_level)"
if [ "$FLOW_MERGE" != "auto" ] && ! { [ -z "$FLOW_MERGE" ] && [ "$LEVEL" = "marathon" ]; }; then
  echo "refused: the merge setting flow_merge is '${FLOW_MERGE:-unset}' (autonomy_level '${LEVEL:-unset}'), so auto-merge is off."
  echo "The switch is the owner's: Merge on the settings page (/retainer:settings)."
  exit 1
fi

if [ "$INSTALLED" = 1 ]; then
  TRACKER="$INSTALLED_TRACKER"
else
  TRACKER="$(cfg tracker_url)"; TRACKER="${TRACKER:-$INSTALLED_TRACKER}"; TRACKER="${TRACKER%/}"
fi
API="$TRACKER/api/v1/repos/$REPO"
TOKEN_PATH="$(cfg gitea_token_path)"; TOKEN_PATH="${TOKEN_PATH/#\~/$HOME_DIR}"
[ -n "$TOKEN_PATH" ] && [ -r "$TOKEN_PATH" ] || TOKEN_PATH="$HOME_DIR/.config/retainer/gitea_token"

# mktemp -d makes the directory 0700, which keeps the header file below private.
WORK="$(clean /usr/bin/mktemp -d)" || exit 2
trap 'clean /bin/rm -rf "$WORK"' EXIT
TOKEN="$(clean /usr/bin/tr -d '[:space:]' < "$TOKEN_PATH" 2>/dev/null)"
[ -n "$TOKEN" ] || { echo "no tracker token — the PR cannot be checked, not merging"; exit 2; }
printf 'Authorization: token %s\n' "$TOKEN" > "$WORK/auth"
unset TOKEN

# get <path> <out file> — a read; a non-200 answer or no answer is the tracker's silence.
get() {
  local code
  code="$(http --max-time "$API_TIMEOUT" -o "$2" -w '%{http_code}' "$API/$1")" || code=000
  [ "$code" = "200" ]
}

get "pulls/$PR" "$WORK/pr.json" || { echo "the tracker did not return PR #$PR — not merging"; exit 2; }
HEAD_SHA="$(py -c 'import json, sys
try:
    pr = json.load(open(sys.argv[1]))
    sha = pr["head"]["sha"] if pr.get("state") == "open" else ""
except Exception:
    sha = "unreadable"
print(sha)' "$WORK/pr.json")"
[ "$HEAD_SHA" = "unreadable" ] && { echo "the tracker answered PR #$PR with something unreadable — not merging"; exit 2; }
[ -n "$HEAD_SHA" ] || { echo "refused: PR #$PR is not open"; exit 1; }
BASE_REF="$(py -c 'import json, sys; print(json.load(open(sys.argv[1]))["base"]["ref"])' "$WORK/pr.json")"

# The raw statuses of the head, every page until an empty one: the combined endpoint keeps no creator,
# and a single page would hide older rows behind newer ones. Past 20 pages the check is not finished.
page=1
while :; do
  get "statuses/$HEAD_SHA?limit=50&page=$page" "$WORK/st.$page.json" \
    || { echo "the tracker did not return the statuses of $HEAD_SHA — not merging"; exit 2; }
  rows="$(py -c 'import json, sys
rows = json.load(open(sys.argv[1]))
print(len(rows) if isinstance(rows, list) else -1)' "$WORK/st.$page.json" 2>/dev/null)"
  case "$rows" in
    0) clean /bin/rm -f "$WORK/st.$page.json"; break ;;
    ''|-1) echo "the tracker answered the statuses of $HEAD_SHA with something not a list — not merging"; exit 2 ;;
  esac
  page=$((page + 1))
  [ "$page" -gt 20 ] && { echo "more than 19 pages of statuses on $HEAD_SHA — not merging"; exit 2; }
done

# Latest row per context; a row counts only when Actions wrote it: no creator, and a target URL on this
# repository's runs, relative or under the tracker origin.
VERDICT="$(py - "$WORK" "$TRACKER" "$REPO" "$LOCK_CTX" "$GATE_CTX" <<'PY'
import glob, json, sys
work, tracker, repo, *contexts = sys.argv[1:]
rows = []
for name in glob.glob(work + "/st.*.json"):
    rows += json.load(open(name))
runs = "/" + repo + "/actions/runs/"
for ctx in contexts:
    mine = [r for r in rows if r.get("context") == ctx]
    if not mine:
        print(f"no {ctx} verdict on this head yet")
        sys.exit(0)
    last = max(mine, key=lambda r: r.get("id", 0))
    url = last.get("target_url") or ""
    if url.startswith(tracker + "/"):
        url = url[len(tracker):]
    if last.get("creator") or not url.startswith(runs):
        who = (last.get("creator") or {}).get("login") or "unknown"
        print(f"the latest {ctx} row was not written by CI (by {who}, url '{last.get('target_url') or ''}')")
        sys.exit(0)
    if last.get("status") != "success":
        print(f"{ctx} is {last.get('status')}: {last.get('description') or 'no reason given'}")
        sys.exit(0)
print("ok")
PY
)"
if [ "$VERDICT" != "ok" ]; then
  echo "refused: $VERDICT"
  case "$VERDICT" in *"not written by CI"*)
    echo "A lock run outside CI writes its row with your token. Raise the lock in CI again: a PR comment, or the merge-lock.yml dispatch." ;;
  esac
  exit 1
fi

if [ "$CHECK" = 1 ]; then
  echo "check: PR #$PR at ${HEAD_SHA:0:10} may be merged (flow_merge ${FLOW_MERGE:-unset}, lock and gate green from CI)"
  exit 0
fi

# head_commit_id pins the checked head: a push after the check makes the server refuse.
code="$(http --max-time "$MERGE_TIMEOUT" -o "$WORK/merge.json" -w '%{http_code}' -X POST \
  -H "Content-Type: application/json" \
  -d "{\"Do\":\"merge\",\"head_commit_id\":\"$HEAD_SHA\"}" "$API/pulls/$PR/merge")" || code=000
if [ "$code" = "200" ]; then
  echo "merged PR #$PR at ${HEAD_SHA:0:10}"
  exit 0
fi
# A cut merge (no answer, or a server error) may still have landed: look for the head in the base.
case "$code" in
  000|5*)
    if get "commits?sha=$BASE_REF&limit=50" "$WORK/base.json" \
      && py -c 'import json, sys
sys.exit(0 if any(c.get("sha") == sys.argv[2] for c in json.load(open(sys.argv[1]))) else 1)' \
        "$WORK/base.json" "$HEAD_SHA"; then
      echo "the merge answered HTTP $code, but ${HEAD_SHA:0:10} is on $BASE_REF: it landed — check that PR #$PR shows as merged"
      exit 0
    fi ;;
esac
if [ "$code" = "000" ]; then
  echo "the merge got no answer and ${HEAD_SHA:0:10} is not on $BASE_REF — state unknown, not retrying"
  exit 2
fi
echo "refused: the merge answered HTTP $code"
py -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("message", ""))
except Exception:
    pass' "$WORK/merge.json" 2>/dev/null
exit 1
