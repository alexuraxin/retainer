#!/usr/bin/env bash
# retainer: repo-setup — label taxonomy + milestone helper + (optional) branch protection.
# Idempotent. The token is NEVER printed.
#
#   setup-repo.sh <owner/repo> [--protect] [--milestone "Name"]
#
# Token: the engine's shared resolver (retainer_token) — places listed in bin/retainer-config.sh
# Base:  $GITEA_URL · tracker_url from the global config · http://localhost:3000
set -euo pipefail

# shellcheck source=bin/retainer-config.sh
. "$(cd "$(dirname "$0")" && pwd)/retainer-config.sh"

REPO="${1:-}"
[ -z "$REPO" ] && { echo "usage: setup-repo.sh <owner/repo> [--protect] [--milestone NAME]" >&2; exit 2; }
shift || true

PROTECT=0
MILESTONE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --protect)   PROTECT=1; shift ;;
    --milestone) MILESTONE="${2:-}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

TOKEN="$(retainer_token)"
[ -z "$TOKEN" ] && { echo "no token (looked in: $(retainer_token_places))" >&2; exit 1; }

API="${GITEA_URL:-$(retainer_cfg tracker_url http://localhost:3000)}/api/v1"
AUTH="Authorization: token $TOKEN"

# ── taxonomy: name|color|description (30 labels) ─────────────────────────
LABELS='
P0|d73a4a|Priority 0 — critical
P1|e99695|Priority 1 — important
P2|fbca04|Priority 2 — normal
now|0e8a16|Queue: taken now. No more than five open at once
next|fbca04|Queue: the next wave
later|c5c5c5|Priority zero: how the work runs, not in the queue. Taken up when it gets in the way
S|bfe5bf|Size: up to three hours
M|f9d0c4|Size: one working day
L|e11d21|Size: more than a day — do NOT take, decompose
impact-user|b60205|Hits whoever USES the product, an embedding project included. Name what they see.
impact-maker|fbca04|Hits whoever MAKES the product. Name the price now: minutes, runs, repeats.
backend|1d76db|Area: backend
frontend|5319e7|Area: frontend
data|0e8a16|Area: data/pipeline
bug|d73a4a|Defect
epic|3e4b9e|Epic (large task)
tech-debt|c5def5|Technical debt
open-question|d4c5f9|Open question for the owner
llm|bfdadc|LLM track
ready|0e8a16|Ready to work (decomposed)
not-decomposed|fbca04|Not decomposed
blocked|b60205|Blocked
in-progress|fef2c0|In progress
gate-passed|0e8a16|Gate green
gate-failed|d73a4a|Gate red
review-clean|0e8a16|Review clean
review-revised|fbca04|Review with revisions
merge-clean|0e8a16|The pre-merge gate gave its verdict: what was declared is done
tester-found|d93f0b|Found by the tester
discipline|5319e7|Automatic discipline incident (bypass/red gate)
'

echo "═══ labels → $REPO ═══"
# The list is read PAGED: the tracker cuts a response at its own ceiling of 50, and `limit=100` yields
# a truncated list with no sign of truncation — a label past the cut would read as absent and be
# created anew. Form: bin/retainer-ready-check.sh:36-56.
PAGE=1
EXISTING=""
while [ "$PAGE" -le 20 ]; do
  page="$(curl -s -H "$AUTH" "$API/repos/$REPO/labels?limit=50&page=$PAGE")"
  got="$(printf '%s' "$page" | python3 -c '
import json, sys
try:
    rows = json.load(sys.stdin)
except ValueError:
    sys.exit(3)
if not isinstance(rows, list):
    sys.exit(3)
sys.stdout.write(str(len(rows)))
')" || { echo "label list not read — the taxonomy is NOT applied" >&2; exit 1; }
  EXISTING="$EXISTING$page
"
  [ "$got" -lt 50 ] && break
  PAGE=$((PAGE + 1))
done

# Values go to python VIA ENV, not interpolated into the source (otherwise quotes/backslash = injection).
# The registry is fed from a here-string, not a pipe: behind a pipe the loop runs in a subshell, and a
# failure recorded there does not survive it — the run would report `!` per label and still exit 0.
LABEL_RC=0
while IFS='|' read -r name color desc; do
  [ -z "$name" ] && continue
  # One read answers all three outcomes: the label is absent, it matches the taxonomy, or it diverges
  # — and then its id is what the PATCH is addressed by. The comparison sits in python next to the
  # parse: the local grep breaks on a Cyrillic character class, and an existing description is
  # exactly that side of the comparison.
  reply="$(printf '%s' "$EXISTING" | LBL="$name" COL="$color" DSC="$desc" python3 -c '
import json, os, sys
name, color, desc = os.environ["LBL"], os.environ["COL"], os.environ["DSC"]
rows = []
for line in sys.stdin:
    if line.strip():
        rows.extend(json.loads(line))
verdict = "MISSING"
for row in rows:
    if row.get("name") != name:
        continue
    same_text = (row.get("description") or "") == desc
    # The API returns bare hex while the request body carries a leading "#": comparing those two
    # forms would call every label diverged and repaint the tracker on the first run.
    same_color = (row.get("color") or "").lstrip("#").lower() == color.lower()
    verdict = "MATCH" if same_text and same_color else "DIVERGED %s" % row["id"]
    break
# The verdict and the request body leave in one answer: the loop walks the registry label by label,
# and a second interpreter start per label is paid on every run of the command. The body is written
# as UTF-8 rather than escaped, so a dash in a description stays a dash on the wire and in the log.
sys.stdout.write(verdict + "\n" + json.dumps(
    {"name": name, "color": "#" + color, "description": desc}, ensure_ascii=False))
')"
  verdict="${reply%%$'\n'*}"
  body="${reply#*$'\n'}"
  case "$verdict" in
    MATCH)
      echo "  = $name (exists)" ;;
    "DIVERGED "*)
      code="$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "$AUTH" -H 'Content-Type: application/json' \
        -d "$body" "$API/repos/$REPO/labels/${verdict#DIVERGED }")"
      [ "$code" = "200" ] && echo "  ~ $name (aligned with the box)" \
        || { echo "  ! $name (HTTP $code)"; LABEL_RC=1; } ;;
    MISSING)
      code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' \
        -d "$body" "$API/repos/$REPO/labels")"
      [ "$code" = "201" ] && echo "  + $name" || { echo "  ! $name (HTTP $code)"; LABEL_RC=1; } ;;
    *)
      echo "  ! $name (label verdict not read)"; LABEL_RC=1 ;;
  esac
done <<< "$LABELS"

# ── Milestone (optional) ────────────────────────────────────────────────────────
if [ -n "$MILESTONE" ]; then
  echo "═══ milestone «${MILESTONE}» ═══"
  MEX="$(curl -s -H "$AUTH" "$API/repos/$REPO/milestones?state=all")"
  if echo "$MEX" | MST="$MILESTONE" python3 -c 'import sys,json,os;print(any(m["title"]==os.environ["MST"] for m in json.load(sys.stdin)))' 2>/dev/null | grep -q True; then
    echo "  = exists"
  else
    body="$(MST="$MILESTONE" python3 -c 'import json,os;print(json.dumps({"title":os.environ["MST"]}))')"
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' -d "$body" "$API/repos/$REPO/milestones")"
    [ "$code" = "201" ] && echo "  + created" || echo "  ! HTTP $code"
  fi
fi

# ── branch protection on the main branch (opt-in: --protect) ──────────────────
# OFF by default: protection is a choice per repository. The scaffold calls with --protect.
PROTECT_RC=0
# Initialized HERE, not by a default substitution below: a substitution would read the value from the
# environment, and an environment variable would silently switch the branch protection off with a zero exit code.
BRANCH_UNSUPPORTED=0
# The main branch name is taken from the REPOSITORY, not from a constant: on a `master` project a rule
# for `main` would protect a nonexistent branch while `master` itself stayed open — the protection
# would look configured. If the tracker answered but gave no name — refuse, do not guess `main`. An
# unreachable tracker never reaches this branch: the run under `set -e` aborts with the transport
# code on the first request.
BASE_BRANCH=""
if [ "$PROTECT" = "1" ]; then
  BASE_BRANCH="$(retainer_api_default_branch "$API" "$AUTH" "$REPO")"
fi

case "$BASE_BRANCH" in
  */*)
    echo "═══ branch-protection → $REPO ═══"
    echo "  ! main branch «${BASE_BRANCH}» contains a slash — NOT setting protection:"
    echo "    the name goes into the request path, and reading the created rule answers \"not found\";"
    echo "    the report would say \"no rule\" over a created rule. Set the protection by hand."
    PROTECT_RC=1
    # A separate state, not a flag reset: a reset would send the run to the "skipped — without
    # --protect" branch, i.e. the print would contradict both the action and the passed flag.
    BRANCH_UNSUPPORTED=1 ;;
esac

if [ "$BRANCH_UNSUPPORTED" = "1" ]; then
  :  # the refusal is already printed above, the branching below is about other states
elif [ "$PROTECT" = "1" ] && [ -z "$BASE_BRANCH" ]; then
  echo "═══ branch-protection → $REPO ═══"
  echo "  ! cannot ask the tracker for the main branch — NOT setting protection:"
  echo "    a rule for a guessed name would protect the wrong branch and leave the open one open."
  PROTECT_RC=1
elif [ "$PROTECT" = "1" ]; then
  echo "═══ branch-protection $BASE_BRANCH → $REPO ═══"
  # The box contract (skills/task-cycle, section "PR → merge"):
  #   required_approvals = 0 — a solo maintainer has no second reviewer to approve, and
  #   a locked merge redirects work to hunting for a bypass instead of stopping it;
  #   the gate status check is mandatory — without it a merge on red CI is technically possible.
  # The context is produced by the distributed CI template (workflow `gate`, job `gate`): the names are
  # linked and cannot be changed separately — a test guards the link.
  GATE_CTX="gate / gate (pull_request)"
  # A required context without anything publishing it is considered forever pending by Gitea, which
  # locks the merge FOREVER. So the status check is set only if the gate workflow exists in the repository.
  wf_code="$(curl -s -o /dev/null -w '%{http_code}' -H "$AUTH" \
    "$API/repos/$REPO/contents/.gitea/workflows/gate.yml")"
  if [ "$wf_code" != "200" ]; then
    echo "  ⚠ workflow .gitea/workflows/gate.yml not found (HTTP $wf_code) — not setting the status check:"
    echo "    a required context without a publisher locks the merge forever. Order: CI first, then --protect."
  fi
  # The merge lock is required by the same rule: only where its workflow publishes it. And only together
  # with the gate — the lock refuses while the gate's own report is missing, so a required lock without a
  # required gate would hold the merge closed for ever.
  lock_code="$(curl -s -o /dev/null -w '%{http_code}' -H "$AUTH" \
    "$API/repos/$REPO/contents/.gitea/workflows/merge-lock.yml")"
  if [ "$lock_code" != "200" ] || [ "$wf_code" != "200" ]; then
    echo "  ⚠ not requiring ${RETAINER_LOCK_CONTEXT}: it needs both .gitea/workflows/merge-lock.yml (HTTP $lock_code)"
    echo "    and .gitea/workflows/gate.yml (HTTP $wf_code) in the repository."
  fi
  cur_json="$(curl -s -H "$AUTH" "$API/repos/$REPO/branch_protections/$BASE_BRANCH")"
  code="$(curl -s -o /dev/null -w '%{http_code}' -H "$AUTH" "$API/repos/$REPO/branch_protections/$BASE_BRANCH")"
  # The context list is assigned whole, so it is built as a UNION with what already stands: a
  # repository may have its own required status (the merge lock), and overwriting it would silently
  # drop someone else's protection. To an existing rule we send only this command's fields — the rest is not ours.
  RULE="$(CUR="$cur_json" CTX="$GATE_CTX" HAVE_WF="$wf_code" EXISTS="$code" BASE="$BASE_BRANCH" \
    LOCK_CTX="$RETAINER_LOCK_CONTEXT" HAVE_LOCK="$lock_code" python3 -c '
import json
import os
import sys

want = os.environ["CTX"]
have_wf = os.environ["HAVE_WF"] == "200"
exists = os.environ["EXISTS"] == "200"
try:
    parsed = json.loads(os.environ["CUR"])
except ValueError:
    parsed = None
current = parsed if isinstance(parsed, dict) and parsed.get("branch_name") else {}
checks = [row for row in (current.get("status_check_contexts") or []) if row]
if have_wf and want not in checks:
    checks.append(want)
lock = os.environ["LOCK_CTX"]
if have_wf and os.environ["HAVE_LOCK"] == "200" and lock not in checks:
    checks.append(lock)
rule = {"required_approvals": 0, "enable_push": False}
if not exists:
    rule["branch_name"] = os.environ["BASE"]
    rule["require_signed_commits"] = False
    # A requested official review would lock the merge where nobody can answer the request.
    rule["block_on_official_review_requests"] = False
if checks:
    rule["enable_status_check"] = True
    rule["status_check_contexts"] = checks
elif not exists:
    rule["enable_status_check"] = False
sys.stdout.write(json.dumps(rule, ensure_ascii=False))
')"
  if [ "$code" = "200" ]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "$AUTH" -H 'Content-Type: application/json' \
      -d "$RULE" "$API/repos/$REPO/branch_protections/$BASE_BRANCH")"
    [ "$code" = "200" ] && echo "  ~ rule aligned with the box" || { echo "  ! PATCH HTTP $code"; PROTECT_RC=1; }
  else
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' \
      -d "$RULE" "$API/repos/$REPO/branch_protections")"
    [ "$code" = "201" ] && echo "  + rule created" || { echo "  ! POST HTTP $code"; PROTECT_RC=1; }
  fi
  # What is printed is the RESULT, read back from the server. A "not found" answer arrives as valid
  # JSON without rule fields, so the presence of `branch_name` is judged: otherwise a missing
  # protection would print as "direct push closed", with a zero exit code at that.
  read_out="$(curl -s -H "$AUTH" "$API/repos/$REPO/branch_protections/$BASE_BRANCH" | BASE="$BASE_BRANCH" python3 -c '
import json
import os
import sys

try:
    rule = json.load(sys.stdin)
except ValueError:
    sys.stdout.write("  ! cannot read the protection — the outcome is unknown\n")
    sys.exit(1)
if not isinstance(rule, dict) or not rule.get("branch_name"):
    sys.stdout.write("  ✗ NO protection rule on {0} — the branch is open\n".format(os.environ["BASE"]))
    sys.exit(1)
checks = rule.get("status_check_contexts") or []
guarded = rule.get("enable_status_check") and checks
sys.stdout.write("  ▶ direct push: {0}\n".format("closed" if not rule.get("enable_push") else "OPEN"))
sys.stdout.write("  ▶ required approvals: {0}\n".format(rule.get("required_approvals")))
sys.stdout.write("  ▶ status check: {0}\n".format(", ".join(checks) if guarded else "NOT required"))
')" || PROTECT_RC=1
  printf '%s\n' "$read_out"
else
  echo "  (branch protection skipped — without --protect)"
fi

echo "done."
# A label left with a stale description is not a successful run: a rollout over several repositories
# must not read as clean when the tracker refused the write.
[ "$LABEL_RC" = 0 ] || exit 1
exit "$PROTECT_RC"
