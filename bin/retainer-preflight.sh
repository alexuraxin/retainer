#!/usr/bin/env bash
# retainer: preflight gate for context externalization. Before an autonomous run
# checks that the context is EXTERNALIZED into durable artifacts and prints a report. READ-ONLY (as blast-radius/digest).
# Strictness = autonomy_level (global config, settings page):
#   manual     -- everything HARD (manifest+git+labels); launch only on owner-confirm.
#   assisted   -- manifest HARD (except --recovery); git/labels advisory (default = hybrid).
#   auto       -- everything advisory (report only); auto-continue.
#   marathon   -- git/labels advisory (as auto), BUT the manifest is HARD. This is not an "owner question"
#                that the mode removes but a precondition the agent closes itself by writing the handoff.
#                Marathon is the only mode where context loss at compaction is guaranteed:
#                the run is long, nobody can pick it up. Where externalization matters most, it is
#                mandatory. The level must be in the valid list below, otherwise the fail-safe quietly
#                resets it to assisted and the mode breaks silently.
#
#   retainer-preflight.sh <repo-dir> [<owner/repo>] [--recovery]
# exit 0 = may launch; exit!=0 = a hard check failed (do NOT launch). The token is NOT printed.
# --recovery: crash recovery (a fallen session) -- context = issue body + working tree, the manifest is NOT required.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=bin/retainer-config.sh
. "$ROOT/bin/retainer-config.sh"   # retainer_cfg -- global retainer config

DIR=""; REPO=""; RECOVERY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --recovery) RECOVERY=1; shift ;;
    -*) echo "unknown argument: $1" >&2; exit 2 ;;
    *) if [ -z "$DIR" ]; then DIR="$1"; elif [ -z "$REPO" ]; then REPO="$1"; else echo "extra argument: $1" >&2; exit 2; fi; shift ;;
  esac
done
[ -z "$DIR" ] && { echo "usage: retainer-preflight.sh <repo-dir> [<owner/repo>] [--recovery]" >&2; exit 2; }
[ -d "$DIR" ] || { echo "no such directory: $DIR" >&2; exit 2; }

LEVEL="$(retainer_cfg autonomy_level assisted)"
case "$LEVEL" in manual|assisted|auto|marathon) ;; *) LEVEL=assisted ;; esac   # unknown -> strict default (fail-safe)
MAXAGE="${PREFLIGHT_MAX_AGE:-86400}"                                        # manifest freshness, sec (default 24h)
hard=0
mark(){ printf '  %s %s\n' "$1" "$2"; }
mtime(){ [ -e "$1" ] && { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; } || echo 0; }

# whether the check is hard at the current level
is_hard(){
  case "$1:$LEVEL" in
    manifest:manual|manifest:assisted|manifest:marathon) [ "$RECOVERY" = 1 ] && return 1; return 0 ;;
    git:manual|labels:manual)          return 0 ;;
    active-label:manual|active-label:assisted) return 0 ;;   # enforcement -- hard by default (assisted), advisory only on auto
    closed-labels:manual|closed-labels:assisted) return 0 ;; # symmetric to active-label -- entry was guarded, exit was not
    # Stale executable code is a precondition, not a remark. Hard in marathon too (by the same
    # logic that makes the manifest hard there): the run is long, nobody can pick it up, and the old
    # rules will execute all of it. On auto it is advisory: the run is short and the owner is near.
    deployed:manual|deployed:assisted|deployed:marathon) return 0 ;;
    # An unprotected main branch is a divergence between policy and fact, and it must be LOUD.
    # But hard in exactly the opposite way from deployed: where the owner is NEAR (manual/assisted),
    # and advisory in an autonomous run. Only the owner can enable protection in the tracker -- hard in
    # marathon would stop the run with a requirement nobody can fulfil, i.e. create a dead end
    # instead of a check. Sample: active-label -- enforcement where someone can execute it.
    protected-main:manual|protected-main:assisted) return 0 ;;
    # A project without the lock workflow, or with a gate under another name, has no gated merge path.
    # Hard by the same reasoning as protected-main: the workflow files are often the owner's to write.
    merge-lock-wf:manual|merge-lock-wf:assisted) return 0 ;;
    *)                                 return 1 ;;
  esac
}
# $1=check-name $2=ok(0)/bad(1) $3=msg-ok $4=msg-bad
report(){
  if [ "$2" = 0 ]; then mark "✓" "$3"; return; fi
  if is_hard "$1"; then mark "✗" "$4 [HARD]"; hard=$((hard + 1)); else mark "⚠" "$4 [advisory]"; fi
}

echo "── preflight of externalization · level: $LEVEL ──"
now="$(date +%s)"

# 1. handoff manifest (the project's state home -> STATUS ## Handoff -> none)
MAN="${PREFLIGHT_MANIFEST:-}"
if [ -z "$MAN" ]; then
  if [ -f "$(retainer_state_dir "$DIR")/handoff.md" ]; then MAN="$(retainer_state_dir "$DIR")/handoff.md"
  elif [ -f "$DIR/STATUS.md" ] && grep -q '## Handoff' "$DIR/STATUS.md" 2>/dev/null; then MAN="$DIR/STATUS.md"; fi
fi
if [ -n "$MAN" ] && [ -f "$MAN" ]; then
  age=$(( now - $(mtime "$MAN") ))
  if [ "$age" -le "$MAXAGE" ]; then report manifest 0 "manifest is fresh (${MAN##*/}, ${age}s)" ""
  else report manifest 1 "" "manifest is stale (${MAN##*/}, ${age}s > ${MAXAGE}s)"; fi
elif [ "$RECOVERY" = 1 ]; then
  mark "✓" "manifest not required (--recovery: context = issue + working tree)"
else
  report manifest 1 "" "no handoff manifest (the path: retainer-state.sh path handoff.md; or STATUS ## Handoff)"
fi

# 2. git tree is clean (uncommitted = not externalized)
if git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ -z "$(git -C "$DIR" status --porcelain 2>/dev/null)" ]; then report git 0 "git tree is clean" ""
  else report git 1 "" "git tree is dirty (uncommitted changes)"; fi
else
  mark "·" "git: not a git repo -- N/A"
fi

# 3. label triage of OPEN issues (needs owner/repo + token)
if [ -n "$REPO" ]; then
  # Resolution is a shared seam: the list of lookup places is one for the whole engine.
  TOKEN="$(retainer_token)"
  if [ -n "$TOKEN" ]; then
    API="${GITEA_URL:-$(retainer_cfg tracker_url http://localhost:3000)}/api/v1"
    json="$(curl -s --max-time 15 -H "Authorization: token $TOKEN" "$API/repos/$REPO/issues?state=open&type=issues&limit=50" || echo '')"
    untri="$(J="$json" python3 -c '
import json, os
try:
    d = json.loads(os.environ["J"])
except Exception:
    print(-1); raise SystemExit
if not isinstance(d, list):
    print(-1); raise SystemExit
tri = {"ready", "in-progress", "blocked", "not-decomposed"}
print(sum(1 for i in d if not (tri & {l["name"] for l in (i.get("labels") or [])})))' 2>/dev/null || echo -1)"
    if [ "$untri" = "-1" ]; then mark "⚠" "label triage: tracker unavailable/garbled reply -- skipped"
    elif [ "$untri" = 0 ]; then report labels 0 "all OPEN issues are triaged" ""
    else report labels 1 "" "$untri OPEN issues without a workflow label (ready/in-progress/blocked/not-decomposed)"; fi

    # active-label: the ACTIVE issue must carry in-progress (not ready) -- anti-recurrence enforcement.
    # Fail-safe: garbled $json / issue not in OPEN -> skip (⚠, NOT hard, NOT a crash); a marker with no
    # digits reads as no marker.
    # Triage labels (on an issue) vs outcome labels (on a PR) -- only the active task's triage here, not gate-passed.
    # Run with no session (the owner's terminal, the conveyor) it sees only the shared slot: a task taken
    # in an agent session is that session's, and this check speaks for the terminal it runs in.
    AI="$(retainer_marker "$DIR" active-issue)"
    if [ -n "$AI" ]; then
      als="$(J="$json" N="$AI" python3 -c '
import json, os
try:
    d = json.loads(os.environ["J"])
    n = int(os.environ["N"])              # non-number -> ValueError -> skip (fail-safe)
except Exception:
    print("skip"); raise SystemExit
if not isinstance(d, list):
    print("skip"); raise SystemExit
issue = next((i for i in d if i.get("number") == n), None)
if issue is None:
    print("skip"); raise SystemExit       # N not in the OPEN list (closed/beyond the limit) -- not our business
labels = {l["name"] for l in (issue.get("labels") or [])}
# an active task is legitimate as in-progress OR blocked (a pause); ready/untriaged is a violation
print("ok" if (labels & {"in-progress", "blocked"}) else "bad")' 2>/dev/null || printf 'skip')"
      case "$als" in
        ok)  report active-label 0 "active issue #$AI: active triage ok (in-progress/blocked)" "" ;;
        bad) report active-label 1 "" "active issue #$AI is not in-progress/blocked (the active task needs triage)" ;;
        *)   mark "⚠" "active-label: active issue #$AI is not in the OPEN list/tracker garbled -- skipped" ;;
      esac
    else
      # An empty marker used to switch the check off SILENTLY -- "not setting the marker" gave exactly
      # the same output as "setting it right": nothing. Forgetfulness and bypass were indistinguishable.
      #
      # It CANNOT be hard, by ordering: preflight runs BEFORE a task is taken, and taking sets the marker.
      # But silence is not allowed either -- the missing marker is now named aloud, together with the
      # command that creates it. The difference between ⚠ and silence is the whole point here.
      mark "⚠" "active-issue: no marker -- no task taken yet (take one: retainer-task-start.sh <owner/repo> <N>)"
    fi

    # closed-labels: a CLOSED task must not carry a label claiming activity
    # (in-progress/ready/blocked) -- on a closed one each of them lies. `not-decomposed` is not in the list:
    # there it is a legitimate trace (closed without decomposing). The walk is PAGED, as in ready-check:
    # Gitea silently cuts the reply to 50, and one page prints "clean" exactly when the tail is
    # longer than a page -- green for the wrong reason.
    # The loop exits on an EMPTY page, not on "fewer than 50": the reply ceiling is set by the instance
    # admin (`MAX_RESPONSE_ITEMS`, Gitea default 50, but it can be 20), and `limit=50` then silently
    # returns 20 -- the rule "<50 means the end" would end the walk on the very first page.
    # Hitting the page ceiling is NOT "clean" but "not checked" (⚠), otherwise we get exactly the
    # fail-open the check was written against.
    # The page ceiling is a variable: 40 pages of 50 issues is 2000 closed, but in the pathological case
    # (slow tracker, full pages) the walk costs 40 x --max-time and runs under the conveyor lock.
    CLOSED_MAX_PAGES="${PREFLIGHT_MAX_PAGES:-40}"
    cpage=1; chits=""; cbroken=0; ctrunc=0
    while :; do
      if [ "$cpage" -gt "$CLOSED_MAX_PAGES" ]; then ctrunc=1; break; fi
      cjson="$(curl -s --max-time 15 -H "Authorization: token $TOKEN" \
               "$API/repos/$REPO/issues?state=closed&type=issues&limit=50&page=$cpage" || printf '')"
      cout="$(J="$cjson" python3 -c '
import json, os, sys
try:
    rows = json.loads(os.environ["J"])
except ValueError:
    sys.exit(3)
if not isinstance(rows, list):
    sys.exit(3)
work = {"in-progress", "ready", "blocked"}
sys.stdout.write("%d\n" % len(rows))
for row in rows:
    if not isinstance(row, dict):           # garbage in the list is no reason to crash the whole walk
        continue
    labels = {lab.get("name") for lab in (row.get("labels") or []) if isinstance(lab, dict)}
    if work & labels:
        num = row.get("number")
        sys.stdout.write("#%s\n" % (num if num is not None else "?"))
' 2>/dev/null)" || { cbroken=1; break; }
      cgot="$(printf '%s\n' "$cout" | sed -n 1p)"
      cmore="$(printf '%s\n' "$cout" | sed 1d)"
      [ -n "$cmore" ] && chits="$chits $cmore"
      case "$cgot" in ''|*[!0-9]*) cbroken=1; break ;; esac
      [ "$cgot" -eq 0 ] && break
      cpage=$((cpage + 1))
    done
    ccount="$(printf '%s' "$chits" | wc -w | tr -d ' ')"
    cfix="$ROOT/bin/retainer-task-close.sh $REPO <N>"
    # What WAS found is stronger than an incomplete walk: a violation seen on the first page does not
    # vanish because the second did not arrive. The reverse branch order ("first not-checked") threw
    # away the numbers already found and printed "skipped" -- the same fail-open from the other side.
    if [ "$ccount" != 0 ]; then
      cshow="$(printf '%s' "$chits" | tr ' ' '\n' | sed '/^$/d' | head -3 | tr '\n' ' ')"
      [ "$ccount" -gt 3 ] && cshow="${cshow}…"          # ellipsis only if the list is truly truncated
      cpart=""
      [ "$cbroken" = 1 ] && cpart=", walk incomplete (tracker dropped) -- there may be more"
      [ "$ctrunc" = 1 ] && cpart=", walk incomplete (page ceiling) -- there may be more"
      report closed-labels 1 "" "closed with a work label: $ccount ($cshow)$cpart -- remove: $cfix"
    elif [ "$cbroken" = 1 ]; then
      mark "⚠" "closed-labels: tracker unavailable/garbled reply -- skipped"
    elif [ "$ctrunc" = 1 ]; then
      mark "⚠" "closed-labels: more than $CLOSED_MAX_PAGES pages of closed -- not all checked, this is NOT \"clean\""
    else
      report closed-labels 0 "closed tasks are free of work labels" ""
    fi
  else
    # The lookup places are named one by one: without them the no-token line reads as "no token
    # on the system" and does not tell an empty machine from one where the token lies elsewhere.
    mark "·" "label triage, closed-labels, branch protection: no token -- skipped (looked in: $(retainer_token_places))"
  fi
else
  mark "·" "label triage: owner/repo not given -- skipped"
fi

# 4. rollout: the plugin CACHE is what executes, not the working tree. `claude plugin update` compares
#    the version NUMBER, not the content: an identical number in the tree and the cache gives "already at
#    the latest version", and the cache freezes forever. Measured on a live tree: dozens of commits after
#    the cache release were not executed -- the rules were committed, covered by tests and merged, but
#    the machine in production did not exist. Found by accident.
#
#    CONTENT is compared, not the version number: a human bumps the number, and the "bump on release"
#    rule is broken the same day it is written. The check must not depend on whether someone remembered.
#
#    The place is preflight, NOT the test suite: a tree-vs-cache divergence exists only on the owner's
#    machine, the runner has no plugin cache at all, and a test there would degenerate into a skip.
PLUGINS_DB="${PREFLIGHT_PLUGINS_DB:-$HOME/.claude/plugins/installed_plugins.json}"
PMAN="$DIR/.claude-plugin/plugin.json"
# What AFFECTS EXECUTION is compared: hooks, scripts, skills, roles, manifest. Nobody runs docs and
# tests from the cache, and their divergence is not "old code is executing".
DEPLOY_DIRS="hooks bin skills agents .claude-plugin"
if [ ! -f "$PMAN" ]; then
  mark "·" "rollout: not a plugin (no .claude-plugin/plugin.json) -- N/A"
elif [ ! -f "$PLUGINS_DB" ]; then
  mark "·" "rollout: no registry of installed plugins ($PLUGINS_DB) -- N/A"
else
  PNAME="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("name",""))' "$PMAN" 2>/dev/null || printf '')"
  CACHES="$(DB="$PLUGINS_DB" NAME="$PNAME" python3 -c '
import json, os, sys
name = os.environ["NAME"]
if not name:
    sys.exit(3)
try:
    db = json.load(open(os.environ["DB"]))
except Exception:                          # broken/unreadable registry -- "not checked", not "clean"
    sys.exit(3)
plugins = db.get("plugins")
if not isinstance(plugins, dict):
    sys.exit(3)
for key, entries in plugins.items():
    # The registry key is <name>@<marketplace>; the marketplace does not matter here, the plugin name does.
    if key.split("@")[0] != name:
        continue
    for entry in (entries or []):
        if isinstance(entry, dict) and entry.get("installPath"):
            sys.stdout.write(entry["installPath"] + "\n")
' 2>/dev/null)" || CACHES="__broken__"
  if [ "$CACHES" = "__broken__" ]; then
    mark "⚠" "rollout: plugin registry unreadable -- NOT checked (this is not \"matches\")"
  elif [ -z "$CACHES" ]; then
    mark "·" "rollout: plugin «${PNAME:-?}» is not installed from this tree -- N/A"
  elif ! git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    mark "·" "rollout: not a git repo -- cannot build the executable file list, N/A"
  else
    # shellcheck disable=SC2086  # $DEPLOY_DIRS is a path list for git ls-files, the splitting is intentional
    TRACKED="$(git -C "$DIR" ls-files -- $DEPLOY_DIRS 2>/dev/null || printf '')"
    # The composition of the DISTRIBUTION is declared by the registry, not the tree: part of the versioned
    # files do not travel to the cache by design (the registry itself, the marketplace file). A tree-wide
    # comparison counted them "diverged" on any rollout, a fresh one too -- and the verdict "stale code
    # is executing" burned always. A threshold that cannot be reached teaches launching around the check,
    # and real drift drowns in that noise.
    #
    # The list is taken FROM THE COMPOSITION SELECTOR -- a second selection of our own over the same
    # registry would drift from it silently. The selector is called FROM THE KIT, and the tree is passed
    # as an argument: the tree's own script may be of any age, and what is asked here is not it but the
    # distribution composition. If the tree has no registry, or the kit has no selector yet (it is older
    # than the change) -- the whole tree is compared, as before: the distribution then IS the tree, and
    # there is nothing to narrow the composition by.
    #
    # The selector's exit code is SIGNIFICANT, and significant in different ways. "No registry at all"
    # (3) is an ordinary outcome: the project declared no composition, the tree is compared. "A registry
    # exists but is unfit" (1) -- the composition is declared and failed to build: silently returning to
    # the tree comparison would bring back the very false divergences the step was fixed for, and not
    # say why.
    #
    # The selector comes FROM THE KIT while the registry is read FROM THE TREE, and their versions
    # diverge: a kit older than the tree will not understand a record form added yesterday -- then
    # "unfit" arrives here, and the explanation is printed, not swallowed.
    dlerr="$(mktemp)"
    DISTLIST="$(bash "$ROOT/bin/retainer-dist-list.sh" "$DIR" 2>"$dlerr")"; dlrc=$?
    [ "$dlrc" = 0 ] || DISTLIST=""
    dfiltered=""
    case "$dlrc" in
      0|3) ;;                       # composition built or no registry at all -- silently, ordinary outcomes
      # No selector in the kit (it is older than the change) is also an ordinary outcome, and the registry
      # has nothing to do with it: the shell answers 127 "command not found", 126 "not executable".
      # Blaming the registry for there being nothing to ask it with would name as the cause something
      # the project may not even have.
      126|127) ;;
      *)
        # The reason is PRINTED: the selector names an address ("the registry names what the tree lacks: ..."),
        # and a swallowed stderr would leave the owner a verdict with no address -- to fix at random.
        # The glyph is cut off by SUBSTITUTION, not by a character class: in the C locale (which is on
        # the machine) the class `[✗▶]` is a set of BYTES, and from a multibyte glyph only the first byte
        # is cut, leaving junk in the verdict. Tests do not catch this: they grep the text after the glyph.
        dlwhy="$(head -1 "$dlerr" 2>/dev/null)"; dlwhy="${dlwhy#* }"
        # An empty reason is not printed as empty parentheses: "failed to build ()" reads as a break of
        # the check itself, not as a selector refusal.
        mark "⚠" "rollout: distribution composition declared but failed to build${dlwhy:+ ($dlwhy)} -- comparing the whole tree" ;;
    esac
    rm -f "$dlerr"
    if [ -n "$DISTLIST" ]; then
      dfiltered="yes"
      # WHOLE LINES (`-x`) are compared, as text (`-F`): a path with a dot or bracket would otherwise
      # become a pattern and pull in foreign lines.
      TRACKED="$(grep -xF -f <(printf '%s\n' "$DISTLIST") <(printf '%s\n' "$TRACKED") || printf '')"
    fi
    dtotal=0; ddrift=0; dnames=""; dmissing=0; dabsent=0; danames=""
    for cache in $CACHES; do
      [ -d "$cache" ] || { dmissing=$((dmissing + 1)); continue; }
      while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        dtotal=$((dtotal + 1))
        # A file ABSENT FROM THE CACHE is not the same as diverged content: the distribution declared it
        # its own, and its absence is what executes. There are two causes -- the kit is older than the
        # tree, or the distribution was built around the registry -- and the verdict names both: one is
        # fixed by an update, the other by a rebuild, and there is nothing to guess on the owner's behalf.
        # Absence is separated from drift ONLY when the composition was narrowed by the registry: without
        # it the list is the whole tree, where part of the files do not travel to the cache by design,
        # and "declared by the registry" would be a claim about a registry nobody read. Then a missing
        # file counts as drift, as before -- the verdict is the old one, not an invented one.
        if [ -n "$dfiltered" ] && [ ! -e "$cache/$rel" ]; then
          dabsent=$((dabsent + 1))
          [ "$(printf '%s' "$danames" | wc -w | tr -d ' ')" -lt 3 ] && danames="$danames ${rel##*/}"
          continue
        fi
        cmp -s "$DIR/$rel" "$cache/$rel" && continue
        ddrift=$((ddrift + 1))
        [ "$(printf '%s' "$dnames" | wc -w | tr -d ' ')" -lt 3 ] && dnames="$dnames ${rel##*/}"
      done <<TRACKED_EOF
$TRACKED
TRACKED_EOF
    done
    dshow="$(printf '%s' "$dnames" | sed 's/^ //')"
    [ "$ddrift" -gt 3 ] && dshow="$dshow …"
    dashow="$(printf '%s' "$danames" | sed 's/^ //')"
    [ "$dabsent" -gt 3 ] && dashow="$dashow …"
    dfix="build the release (bin/retainer-release.sh) and claude plugin update $PNAME"
    if [ "$dtotal" = 0 ] && [ "$dmissing" -gt 0 ]; then
      mark "⚠" "rollout: the cache directory from the registry does not exist -- NOT checked (registry stale)"
    elif [ "$dtotal" = 0 ] && [ -n "$dfiltered" ]; then
      # Empty AFTER narrowing is not "the tree has nothing": the files exist, the distribution composition removed them.
      # The earlier wording would assert something untrue about the tree and switch the check off quietly.
      mark "⚠" "rollout: the distribution composition holds nothing executable ($DEPLOY_DIRS) -- nothing to compare"
    elif [ "$dtotal" = 0 ]; then
      mark "⚠" "rollout: no tracked files $DEPLOY_DIRS in the tree -- nothing to compare"
    elif [ "$dabsent" != 0 ]; then
      # Absence is named FIRST and separately from drift: it has a different cause. There are two causes,
      # though -- the file appeared in the tree and the kit has not seen it yet, or the distribution was
      # built around the registry -- and both are named: blaming the build where the kit's age is at
      # fault teaches not reading the verdict. Drift, if any, is named on the same line: otherwise one
      # absent file hides any number of diverged ones, and they have to be fixed in two rounds.
      dboth=""
      [ "$ddrift" != 0 ] && dboth="; and content diverges: $ddrift ($dshow)"
      report deployed 1 "" "the cache LACKS files declared by the distribution registry: $dabsent of $dtotal ($dashow)$dboth -- the kit is older than the tree or the distribution was built around the registry, $dfix"
    elif [ "$ddrift" = 0 ]; then
      report deployed 0 "executable code matches the tree ($dtotal files)" ""
    else
      report deployed 1 "" "STALE code is executing: $ddrift of $dtotal cache files diverge from the tree ($dshow) -- $dfix"
    fi
  fi
fi

# 4b. The main branch is protected IN FACT, not in the policy text.
#
# Class: "the document promises a protection that does not exist". The merge lock (retainer-merge-ready.sh)
# holds only on being called -- nothing stops merging with the button around it or pushing to main
# directly. While this state is visible only to whoever goes to look at the tracker settings, it lives
# for years: in one day there were three cases of the same class.
#
# The FACT at the tracker is checked, not the entry in a doc. Tracker silence is "not checked", not "protected":
# fail-closed here would refuse on every offline run, and fail-open would lie about protection.
if [ -n "${REPO:-}" ] && [ -n "${TOKEN:-}" ] && [ -n "${API:-}" ]; then
  # The name of the main branch is declared by the repository itself: a project on `master` answered the
  # request about `main` with a 404, the parse found no `protected` key and printed "tracker did not
  # answer" -- an access failure in place of a configuration divergence. These are different answers,
  # and merging them is forbidden.
  # FOUR states instead of one, told apart by the reply CODE, not by emptiness: "tracker silent" (no
  # network, transport refusal), "tracker refused with a code" (repository name or token rights),
  # "tracker answered but did not name the main branch" and "no branch of that name". Emptiness is one
  # for all four, and merging them returns the original defect through another door.
  rcode="$(retainer_api_code "$API" "Authorization: token $TOKEN" "repos/$REPO")"
  bbranch=""
  [ "$rcode" = "200" ] && bbranch="$(retainer_api_default_branch "$API" "Authorization: token $TOKEN" "$REPO")"
  # The branch request is made only when the name is known: otherwise an offline run waits for a timeout
  # a second time, and the answer is discarded anyway.
  # `-w` itself prints the code on a transport refusal, no `000` of our own is needed: it would be appended second.
  bresp=""
  [ -n "$bbranch" ] && bresp="$(curl -s --max-time 15 -w '\n%{http_code}' \
    -H "Authorization: token $TOKEN" "$API/repos/$REPO/branches/$bbranch")"
  bstate="$(BJ="${bresp%$'\n'*}" BCODE="${bresp##*$'\n'}" BB="$bbranch" RC="$rcode" python3 -c '
import json, os, sys

code = os.environ["RC"]
if not os.environ["BB"]:
    if code == "200":
        sys.stdout.write("noname")
    elif code in {"000", ""}:
        sys.stdout.write("silent")
    else:
        sys.stdout.write("refused")
    raise SystemExit
if os.environ["BCODE"] == "404":
    sys.stdout.write("missing")
    raise SystemExit
try:
    row = json.loads(os.environ["BJ"])
except ValueError:
    sys.stdout.write("?")
    raise SystemExit
if not isinstance(row, dict) or "protected" not in row:
    sys.stdout.write("?")
    raise SystemExit
if not row.get("protected"):
    sys.stdout.write("open")
    raise SystemExit
if not row.get("enable_status_check"):
    sys.stdout.write("nocheck")
    raise SystemExit
sys.stdout.write("ok")
')"
  case "$bstate" in
    ok)      report protected-main 0 "branch $bbranch is protected, status checks are required" "" ;;
    open)    report protected-main 1 "" "branch $bbranch is NOT protected: direct push is open, the merge lock is bypassed with the button" ;;
    nocheck) report protected-main 1 "" "branch $bbranch is protected but has no required status checks -- red CI will not stop a merge" ;;
    missing) report protected-main 1 "" "branch $bbranch does not exist in the repository -- nothing to protect, and the divergence is configuration, not access" ;;
    noname)  mark "⚠" "main-branch protection -- NOT checked: the tracker answered but did not name the main branch" ;;
    silent)  mark "⚠" "main-branch protection -- NOT checked: the tracker did not answer (silence is not protection)" ;;
    refused) mark "⚠" "main-branch protection -- NOT checked: the tracker refused with code $rcode (repository name or token rights)" ;;
    *)       mark "⚠" "protection of ${bbranch:-the main branch} -- NOT checked: the tracker reply was not parsed (silence is not protection)" ;;
  esac
fi

# 4c. The gated merge path has a lock to read. `retainer-merge-gated.sh` merges only on a green
# `retainer/merge-lock` row and a green `gate / gate (pull_request)` row; in a project the first is
# written by the lock workflow laid from the engine template, and both names come from the gate being
# `name: gate` with the job `gate`. Judged from the working tree only when the gated path is installed
# and the project runs Gitea CI; anywhere else the check does not apply and says nothing.
# Where it is installed is what the engine's own copy declares in INSTALL_DIR: the script trusts
# itself only there. The value is read as the installer reads it, up to the first blank. A missing
# copy or line or a value that is not an absolute path gives no default, and two non-empty `INSTALL_DIR=`
# lines join into a path that names no file; either way the check stays silent. The gated script's own
# test holds that it declares exactly one line, which the installer requires.
gated_dir="$(sed -n 's/^INSTALL_DIR=\([^[:space:]]*\).*/\1/p' "$ROOT/bin/retainer-merge-gated.sh" 2>/dev/null)"
case "$gated_dir" in /*) gated_default="$gated_dir/retainer-merge-gated.sh" ;; *) gated_default="" ;; esac
GATED="${PREFLIGHT_MERGE_GATED:-$gated_default}"
GATE_WF="$DIR/.gitea/workflows/gate.yml"
if [ -f "$GATED" ]; then
  if [ -f "$GATE_WF" ]; then
    # The declared name decides the context; without a declaration Gitea names it after the file.
    gname="$(awk '/^name:/ { sub(/^name:[[:space:]]*/, ""); sub(/[[:space:]]+#.*$/, ""); gsub(/["\047]/, ""); print; exit }' "$GATE_WF")"
    # The job part of the context is the first job's own `name:` when it declares one, else its id.
    gjob="$(awk '
      /^jobs:/ { f = 1; next }
      f && /^  [A-Za-z0-9_-]+:/ { if (id != "") exit; id = $0; gsub(/[ :]/, "", id); next }
      id != "" && /^    name:/ {
        sub(/^    name:[[:space:]]*/, ""); sub(/[[:space:]]+#.*$/, ""); gsub(/["\047]/, "")
        print; found = 1; exit
      }
      END { if (!found) print id }' "$GATE_WF")"
    grunner="$(awk '/^[[:space:]]+runs-on:/ { sub(/^[[:space:]]+runs-on:[[:space:]]*/, ""); sub(/[[:space:]]+#.*$/, ""); print; exit }' "$GATE_WF")"
    gctx="${gname:-gate.yml} / ${gjob:-?} (pull_request)"
    if [ -f "$DIR/.gitea/workflows/merge-lock.yml" ]; then
      report merge-lock-wf 0 "the merge lock workflow is in place" ""
    else
      report merge-lock-wf 1 "" "the gated merge path is installed, but .gitea/workflows/merge-lock.yml is missing -- nothing publishes ${RETAINER_LOCK_CONTEXT} and every gated merge is refused. Lay it: sed \"s/__RUNNER__/${grunner:-self-hosted}/g\" \"$ROOT/presets/ci/gitea-actions.merge-lock.yml.template\" > .gitea/workflows/merge-lock.yml"
    fi
    if [ "$gctx" = "gate / gate (pull_request)" ]; then
      report merge-lock-wf 0 "the gate publishes «gate / gate (pull_request)», the context the lock waits for" ""
    else
      report merge-lock-wf 1 "" "the gate publishes «${gctx}», while the lock and the gated merge wait for «gate / gate (pull_request)» -- name the workflow \`name: gate\` and its first job \`gate\`"
    fi
  else
    mark "·" "merge lock workflow: no .gitea/workflows/gate.yml -- N/A"
  fi
fi

# 5. owner-confirm (the non-mechanizable)
echo "  -- the mechanizable is checked; the COMPLETENESS of the head (whether everything is externalized) is confirmed by the owner"

if [ "$hard" -gt 0 ]; then
  # The cause is named by the report above, not this line: hard failures also happen not about the
  # manifest (closed tasks with a work label), and "context not externalized" there would send to fix the wrong thing.
  echo "✗ preflight: $hard hard failure(s) at level '$LEVEL' -- the cause is in the report above, do NOT launch"
  exit 1
fi
echo "✓ preflight: hard checks passed (level '$LEVEL')"
exit 0
