#!/usr/bin/env bash
# retainer: merge lock — may THIS pull request be merged right now.
#
#   retainer-merge-ready.sh <owner/repo> <PR number>
# exit 0 — merging is allowed (PR open, no conflicts, checks green)
# exit 1 — merging is not allowed (reason on stdout)
# exit 2 — usage / tracker did not answer / no token (fail-closed: tracker silence is not permission)
#
# The token is read from a file; its value is NEVER printed — not in debug output, not in an error.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=bin/retainer-config.sh
. "$ROOT/bin/retainer-config.sh"

REPO="${1:-}"; PR="${2:-}"
case "$REPO" in */*) ;; *) echo "usage: retainer-merge-ready.sh <owner/repo> <PR number>" >&2; exit 2 ;; esac
case "$PR" in ''|*[!0-9]*) echo "usage: retainer-merge-ready.sh <owner/repo> <PR number>" >&2; exit 2 ;; esac

API="$(retainer_cfg tracker_url http://localhost:3000)/api/v1"
TOKEN="$(retainer_token)"
[ -n "$TOKEN" ] || { echo "no tracker token — PR state cannot be checked, do not merge"; exit 2; }

# The wait is one number with one home: a slow endpoint and a dead one need different patience, and
# a literal in two call sites drifts.
API_TIMEOUT="${RETAINER_API_TIMEOUT:-15}"
api(){ curl -s --max-time "$API_TIMEOUT" -H "Authorization: token $TOKEN" "$API/$1" 2>/dev/null; }

# A request that timed out or was refused leaves EMPTY stdout, and the parsers below read empty as
# "the answer was not parsed" — a diagnosis that sends the reader into a correct parser instead of to
# the endpoint, which happened four times in one session. Silence is named BEFORE any parse, by the
# caller that knows which request it made; "not parsed" stays for an answer that arrived and could
# not be read. It is a shell function and not a subshell helper on purpose: `exit` inside a command
# substitution would end the substitution and let the script walk on with an empty answer.
require_answer(){                        # <answer> <what was asked about>
  [ -n "$1" ] && return 0
  echo "tracker did not answer $2 within ${API_TIMEOUT}s — silence is not permission, do not merge"
  exit 2
}

pr_json="$(api "repos/$REPO/pulls/$PR")"
require_answer "$pr_json" "about PR #$PR"

# Parsed by one python3: it exists everywhere the guard runs and does not choke on unicode in titles.
# Gitea returns an error as VALID json (`{"message":"not found"}`, 401 etc.), so "not parsed" is
# caught not only by a parser exception. The sign of a real PR answer is the key `state`. Without it
# this is an error message, not a PR, and reading it as "no checks" would permit a merge on an error.
read -r state merged mergeable sha base_ref base_sha merge_base <<EOF
$(printf '%s' "$pr_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("? ? ? ? ? ? ?"); sys.exit()
if not isinstance(d, dict) or "state" not in d:
    print("? ? ? ? ? ? ?"); sys.exit()
head = d.get("head") or {}
base = d.get("base") or {}
print(d.get("state") or "?", str(d.get("merged", False)).lower(),
      str(d.get("mergeable", False)).lower(), head.get("sha") or "?",
      base.get("ref") or "?", base.get("sha") or "?",
      d.get("merge_base") or "?")
')
EOF

[ "$state" = "?" ] && { echo "tracker answer about PR #$PR not parsed — do not merge"; exit 2; }
# Without a head commit there is nothing to check: the status request would go to `/commits/?/status`
# and return 404, i.e. "no checks" — the most permissive outcome from the most broken state.
[ "$sha" = "?" ] && { echo "PR #$PR names no head commit — check status cannot be asked, do not merge"; exit 2; }
[ "$merged" = true ] && { echo "PR #$PR is already merged"; exit 1; }
[ "$state" = open ] || { echo "PR #$PR is not open (state: $state)"; exit 1; }
[ "$mergeable" = true ] || { echo "PR #$PR does not merge automatically — conflicts or branch protection"; exit 1; }

# ── identity of the reviewed and the merged ────────────────────────────────────
# The review outcome label hangs on the TASK and says "read", but not WHAT was read. Between the
# verdict and the merge the branch moves, and what is merged diverges from what was reviewed. The
# check is not a second read of the diff (a second pass over the same diff must say the same thing)
# but identity: the review verdict is recorded in a comment as a line `review-sha: <sha>`, and here it
# is compared with the PR head commit.
#
# Fail-closed by its own logic: no record — do not merge. Otherwise a task without a review looks
# exactly like a task with one, and that is the very state the lock exists for.
#
# THE ORIGIN OF THE VERDICT IS NOT JUDGED, and this must be said aloud. It cannot be judged by the
# tracker account (there is one account, and a rule "comment author != PR author" would refuse every
# honest merge), and the machine mark — an attestation of a completed role run — was written by the
# guard, and that code was cut together with the guard procedural layer. A reader without a writer
# would mean a refusal for EVERY new PR: the lock would become a wall. What remains is what is
# checkable: a record exists and it is about the head that is being merged. Who left it, the machine
# no longer knows — the verdict is a self-declaration, and the policy must call the role itself.
comments_json="$(api "repos/$REPO/issues/$PR/comments")"
require_answer "$comments_json" "with the comment list of PR #$PR"
review_list="$(printf '%s' "$comments_json" | python3 -c '
import json, re, sys

# The label is searched TOGETHER with emphasis: markdown puts it both inside (`**review-sha:**`) and
# around (`**review-sha**:`, `` `review-sha`: ``), and separates the colon with a space. Searching
# one literal answers "no record" over a standing record.
LABEL = re.compile(r"review-sha[*_`]*\s*:", re.IGNORECASE)
# Anchored = the label opens its line, past leading whitespace, one list marker and emphasis markup.
# A label sitting mid-sentence is a prose citation of a sha, not a record: a report of a
# multi-round review quotes the sha of the previous round, and that quote must not outvote the fresh
# record. Selection happens in the shell below; here each candidate only carries whether it is
# anchored.
# Leading emphasis is kept in the anchor so an emphasized fresh record (`**review-sha:** ...`) still
# beats a mid-sentence citation. The cost is fail-closed: a citation that itself opens a line wrapped
# in emphasis or a code span reads as a record and can refuse a merge a reworded citation would pass.
# That direction is safe (a fresh comment clears it) and matches prior behavior; a stricter anchor
# would only move the hole onto the commoner emphasized-record form, and telling a wrapped citation
# from a wrapped record apart needs real span matching, not a line prefix.
ANCHOR = re.compile(r"^[ \t]*(?:[-*+] +|[0-9]+\. +)?[*_`]*$")
# Markup around the value is stripped from the edges: asterisk, backtick, underscore and a stuck
# punctuation mark are markup, not part of the commit. The set is closed and held by a case per
# character: space and tab are not in it — splitting on whitespace comes first and removes them.
WRAP = "*_`.,;:!?()[]"
try:
    rows = json.load(sys.stdin)
except ValueError:
    print("?")                                  # answer not parsed: not "no record" but "unknown"
    sys.exit()
if not isinstance(rows, list):
    print("?")
    sys.exit()
# Each candidate leaves a line "A<tab>value" (anchored) or "T<tab>value" (in-text), in order across
# comments and within a comment. Who is the record is decided in the shell, where the commit judge
# already lives — a second "looks like a commit" test is not duplicated here.
found = []
for row in rows:
    if not isinstance(row, dict):
        continue
    body = str(row.get("body") or "")
    for hit in LABEL.finditer(body):
        line_start = body.rfind("\n", 0, hit.start()) + 1
        flag = "A" if ANCHOR.match(body[line_start:hit.start()]) else "T"
        tail = body[hit.end():]
        # Blank lines and markup are stripped BEFORE the value: an emphasized label leaves asterisks
        # behind it, and the value may be separated by a blank line.
        words = tail.strip().strip(WRAP).split()
        if words:
            found.append("%s\t%s" % (flag, words[0].strip(WRAP) or words[0]))
        elif tail.strip():
            # Empty after stripping the markup — not "no record" but junk in the value: passed on as
            # written, so that the refusal names the reason.
            found.append("%s\t%s" % (flag, tail.split()[0]))
        # A label without a value does not enter the list: a comment CITING the rule would otherwise
        # give an honest two-round PR the diagnosis "there was no review".
print("\n".join(found) or "none")
')"
case "$review_list" in
  '?') echo "PR #$PR: comment list not parsed — which commit the review read is unknown, do not merge"; exit 2 ;;
  none)
    echo "PR #$PR: no review record (the line «review-sha: <sha>» in a comment) — do not merge."
    echo "  This is not \"forgot the report\": review is a cycle step, and only the owner can lift it with a regulator."
    echo "  Being physically unable to call the role is not a reason to skip the step: stop and name the conflict"
    echo "  [CONFLICT: code_reviewer = auto, cannot execute — <reason>]"
    echo "  For PRs opened before the record was introduced, the verdict is confirmed by a NEW comment with review-sha."
    exit 1 ;;
esac
# Pick the operative record, fail-closed. An anchored occurrence (the label opening a line) is a
# real record; an in-text one is a prose citation. If any anchored record exists, the LAST anchored
# one is the operand and must parse as a commit — a typo in it refuses, it does not fall through to
# an older sha quoted in prose (that fall-through would merge a head the review never read). Only
# when no anchored record exists at all does selection fall back to the last in-text value that
# parses, keeping the legacy forms working (a record inside a phrase, two rounds in one comment).
# Staleness is not let through here: identity against the head is checked below and cuts any record
# read on the wrong head.
review_sha=""
review_bad=""
anchored_seen=0
anchored_last=""; anchored_last_ok=0
text_last=""; text_last_ok=""
tab="$(printf '\t')"
while IFS="$tab" read -r flag candidate; do
  [ -n "$candidate" ] || continue
  ok=0
  case "$candidate" in *[!0-9a-fA-F]*) ;; *) [ "${#candidate}" -ge 7 ] && [ "${#candidate}" -le 40 ] && ok=1 ;; esac
  if [ "$flag" = A ]; then
    anchored_seen=1; anchored_last="$candidate"; anchored_last_ok="$ok"
  else
    text_last="$candidate"; [ "$ok" = 1 ] && text_last_ok="$candidate"
  fi
done <<REVIEWEOF
$review_list
REVIEWEOF
if [ "$anchored_seen" = 1 ]; then
  if [ "$anchored_last_ok" = 1 ]; then review_sha="$anchored_last"; else review_bad="$anchored_last"; fi
else
  if [ -n "$text_last_ok" ]; then review_sha="$text_last_ok"; else review_bad="$text_last"; fi
fi
if [ -z "$review_sha" ]; then
  echo "PR #$PR: review record not parsed (review-sha: «${review_bad}» does not look like a commit) — do not merge"
  exit 1
fi
# Compared in the SHORT form: the record may carry an abbreviated sha, while the tracker returns the full one.
short_rev="$(printf '%s' "$review_sha" | cut -c1-7 | tr 'A-Z' 'a-z')"
short_head="$(printf '%s' "$sha" | cut -c1-7 | tr 'A-Z' 'a-z')"

# same_patch <reviewed> <head> — 0 when the task's patch is the same at both heads: each diffed against
# its merge base with the base branch, compared by `git patch-id --verbatim` (whitespace counts: an
# indentation change is a change; hunk line numbers do not). A merge of the base brings
# other people's work, not the task's, so the verdict on the task carries over. The lock job holds only
# a shallow base, and the tracker gives a diff for the current head only, so both heads are fetched into
# a throwaway repository. Any failure — fetch, an unknown reviewed commit, an empty patch — is "differs".
same_patch(){
  local dir rc=1 rev base_r base_h id_r id_h
  dir="$(mktemp -d 2>/dev/null)" || return 1
  if git -C "$dir" init -q 2>/dev/null \
     && GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=3 \
        GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="Authorization: token $TOKEN" \
        GIT_CONFIG_KEY_1=http.lowSpeedLimit GIT_CONFIG_VALUE_1=1 \
        GIT_CONFIG_KEY_2=http.lowSpeedTime GIT_CONFIG_VALUE_2="$API_TIMEOUT" \
        git -C "$dir" fetch -q "${API%/api/v1}/$REPO.git" "$base_ref:refs/lock/base" "$2:refs/lock/head" 2>/dev/null \
     && rev="$(git -C "$dir" rev-parse --verify --quiet "$1^{commit}")" \
     && base_r="$(git -C "$dir" merge-base refs/lock/base "$rev")" \
     && base_h="$(git -C "$dir" merge-base refs/lock/base refs/lock/head)"; then
    id_r="$(git -C "$dir" diff --no-ext-diff --no-color "$base_r" "$rev" | git -C "$dir" patch-id --verbatim | cut -d' ' -f1)"
    id_h="$(git -C "$dir" diff --no-ext-diff --no-color "$base_h" refs/lock/head | git -C "$dir" patch-id --verbatim | cut -d' ' -f1)"
    [ -n "$id_r" ] && [ "$id_r" = "$id_h" ] && rc=0
  fi
  rm -rf "$dir"
  return "$rc"
}

if [ "$short_rev" != "$short_head" ] && same_patch "$review_sha" "$sha"; then
  echo "PR #$PR: the head differs from review-sha only by a merge of $base_ref — the task's patch is the same, the verdict carries over"
  echo "  review read: $review_sha"
  echo "  head now:    $sha"
elif [ "$short_rev" != "$short_head" ]; then
  echo "PR #$PR: commits arrived on the branch after the review — what is merged will diverge from what was reviewed, do not merge"
  echo "  review read: $review_sha"
  echo "  head now:    $sha"
  newer="$(api "repos/$REPO/pulls/$PR/commits" | REV="$short_rev" python3 -c '
import json, os, sys

rev = os.environ["REV"]
try:
    rows = json.load(sys.stdin)
except ValueError:
    sys.exit()
if not isinstance(rows, list):
    sys.exit()
# Gitea returns PR commits newest first: everything before the recorded one arrived AFTER the review.
for row in rows:
    if not isinstance(row, dict):
        continue
    line = str(row.get("sha") or "")
    if line[:7].lower() == rev:
        break
    subject = str((row.get("commit") or {}).get("message") or "").splitlines()[:1]
    print("    %s %s" % (line[:7], subject[0] if subject else ""))
')"
  [ -n "$newer" ] && { echo "  arrived after the verdict:"; printf '%s\n' "$newer"; }
  exit 1
fi

# ── the release does not rest on the memory of the PR author ───────────────────
# The CHANGELOG header rule: "change a rule/regulator/guard → an entry in the journal". It is broken
# the same day it is written: main carried a guard edit, the version did not reflect it, the CHANGELOG
# was silent, and a plugin update would have installed an undocumented rule. The cause is not
# forgetfulness: a release is not a task step, it rests on the memory of the PR author — the same
# class as cleanup and the result report. The rule exists, the seam does not.
#
# A CHECKABLE fact is judged: the diff touched an executable → the same diff must carry a journal
# FRAGMENT. How substantive the entry is, the machine does not judge and will not pretend to.
#
# A fragment is required, not an edit of `CHANGELOG.md` and the manifest: the version is raised by the
# release on main (`bin/retainer-release.sh`), not by a branch. A contract that made every branch
# touch the place common to all — the journal head and the `version` field in two manifests — made a
# stack of branches conflict on every merge. A branch that touched the manifest itself does NOT pass
# the check: a version raised before the release diverges from the journal and from what actually went
# into distribution.
#
# The walk is paged with a ceiling: a truncated file list gives "rule not touched" — green for the
# wrong reason. Hitting the ceiling means "not checked", not "allowed".
# Registry of the executable surface. Wider than the rollout directories in preflight, on purpose:
# `.githooks/` and `.gitea/` sit in `protected` with the wording "the gate cannot be silently
# weakened", and `commands/` is shipped by the plugin. An edit of any of them moves the rule, and the
# release must carry it.
#
# `presets/`: it holds the GATE TEMPLATE that is distributed to every managed project and executed
# there on every commit. Without it, a task done purely in `presets/` passed the lock silently — a
# regulator was removed from the distributed template, and the release requirement fired only on an
# accidental side file in `bin/`.
#
# `docs/` is deliberately NOT in the list: most edits there move no rule, and a noisy check gets
# bypassed. `docs/settings-page/*.html` is an open question (the page writes the config of a live project).
RULE_DIRS="hooks/ bin/ skills/ agents/ commands/ .githooks/ .gitea/ .claude-plugin/ presets/"
RELEASE_MAX_PAGES="${MERGE_READY_MAX_PAGES:-5}"
# A non-numeric ceiling silently switched the walk off: `[ N -gt abc ]` returns 2, the branch is not
# taken, and "hit the ceiling" never happens. A typo in the variable turned fail-closed into fail-open.
case "$RELEASE_MAX_PAGES" in
  ''|*[!0-9]*) echo "PR #$PR: MERGE_READY_MAX_PAGES=«${RELEASE_MAX_PAGES}» is not a number — do not merge"; exit 2 ;;
esac
[ "$RELEASE_MAX_PAGES" -gt 0 ] || { echo "PR #$PR: MERGE_READY_MAX_PAGES=0 — walk switched off, do not merge"; exit 2; }
# The page size is set by the INSTANCE (`max_response_items`, 50 for this Gitea), not by our `limit`.
# So the end of the list is recognized by a page SHORTER than the first, not by an empty one:
# otherwise a full list spends an extra request, and the ceiling fires one earlier than declared.
fpage=1; frows=""; fbroken=0; ftrunc=0; fsize=0
while :; do
  if [ "$fpage" -gt "$RELEASE_MAX_PAGES" ]; then ftrunc=1; break; fi
  fout="$(api "repos/$REPO/pulls/$PR/files?limit=100&page=$fpage" | python3 -c '
import json, sys

try:
    rows = json.load(sys.stdin)
except ValueError:
    sys.exit(3)
if not isinstance(rows, list):
    sys.exit(3)
sys.stdout.write("%d\n" % len(rows))
# STATUS is taken together with the name: without it an executable edit passes when the diff merely
# DELETES someone else fragment — the name is in the list, the new entry is not. Deleting fragments
# is also a routine action of the release mechanism, so the input is not exotic but every-release.
for row in rows:
    if isinstance(row, dict) and row.get("filename"):
        sys.stdout.write("%s\t%s\n" % (row.get("status") or "?", row["filename"]))
')" || { fbroken=1; break; }
  fgot="$(printf '%s\n' "$fout" | sed -n 1p)"
  case "$fgot" in ''|*[!0-9]*) fbroken=1; break ;; esac
  frows="$frows
$(printf '%s\n' "$fout" | sed 1d)"
  [ "$fpage" = 1 ] && fsize="$fgot"
  [ "$fgot" -lt "$fsize" ] && break      # page shorter than the first — the list ended
  [ "$fgot" -eq 0 ] && break
  fpage=$((fpage + 1))
done

if [ "$fbroken" = 1 ]; then
  echo "PR #$PR: list of changed files not read — release discipline cannot be checked, do not merge"
  exit 2
fi
if [ "$ftrunc" = 1 ]; then
  echo "PR #$PR: more than $RELEASE_MAX_PAGES pages of files — release discipline NOT checked, do not merge"
  exit 2
fi
frows="$(printf '%s\n' "$frows" | sed '/^$/d')"
fnames="$(printf '%s\n' "$frows" | cut -f2-)"
if [ -z "$fnames" ]; then
  # A PR without a single file is not "rule not touched" but an unreadable answer: an empty list would
  # give permission from the most broken state.
  echo "PR #$PR: tracker returned an empty list of changed files — release discipline NOT checked"
  exit 2
fi

# ── release PR: the journal, both manifests and fragment deletions, nothing else ───
# The release commit must pass this same path: a direct push to `main` is closed by branch protection
# for everyone (`enable_push: false`), so without this seam the release mechanism would have NO route
# into `main` IN PRINCIPLE — a manifest edit is forbidden below, and bypassing the lock means removing
# the protection.
#
# Recognized by COMPOSITION, not by branch name and not by label: the name and the label are set by
# whoever merges. Allowed are the journal, two manifests, fragments with a legible name and the
# directory README (the format description travels with the directory) — nested paths under
# `docs/changelog.d/` are foreign, otherwise "exactly these paths" is untrue.
#
# The list is declared as ONE string and is readable from outside: the release suite checks the
# composition of its commit against it by grepping this variable. A second list, rewritten into a
# test, diverged from this one in the very commit that tightened it — and a legitimate release hit a
# refusal nobody expected.
RELEASE_PATH_RE='^(CHANGELOG\.md|\.claude-plugin/(plugin|marketplace)\.json|docs/changelog\.d/(README\.md|[0-9]+\.(fix|feat)\.md))$'
release_pr=1
while IFS= read -r fname; do
  [ -n "$fname" ] || continue
  printf '%s\n' "$fname" | grep -qE "$RELEASE_PATH_RE" || { release_pr=0; break; }
done <<EOF
$fnames
EOF
# Three signs of a REAL release, and each is required. Without them the exception would be granted to
# any diff "manifest + a journal line": the release mechanism refuses to assemble an empty directory,
# so a release ALWAYS carries removed fragments, a raised version and a journal section. Their absence
# means not a release but a hand edit of `.claude-plugin/` — and that is where the distribution
# `source` lives, i.e. the decision of what goes into the plugin at all.
printf '%s\n' "$fnames" | grep -qx 'CHANGELOG\.md' || release_pr=0
printf '%s\n' "$fnames" | grep -qx '\.claude-plugin/plugin\.json' || release_pr=0
printf '%s\n' "$frows" | grep -qE '^deleted'"$(printf '\t')"'docs/changelog\.d/[0-9]+\.(fix|feat)\.md$' || release_pr=0

# Release discipline applies ONLY to a repository that releases the plugin itself. Journal fragments
# exist so that `retainer-release.sh` assembles them into a version section and deletes them; a
# project has no such command, nobody would assemble the fragments — they would pile up as a dead
# directory, and the lock would start passing any PR that carries at least one file of the needed
# kind, i.e. become a ritual.
#
# `RULE_DIRS` lists the executable surface of the ENGINE, but the `.githooks/` and `.gitea/`
# directories exist in every managed project — and the requirement reached them. Measured on a live
# project: there is no `docs/changelog.d` at all, yet a PR editing CI hit a refusal.
#
# The sign is checkable and coincides with what makes the distribution: the plugin manifest in the
# tree of the BASE branch. Not the repository name and not a list — they would have to be kept by
# hand. The tree of the BASE, not of the head: otherwise a PR deleting the manifest would lift the
# discipline from itself.
#
# Judged by HTTP CODE, not by the shape of the body. Gitea returns an error as a valid json object
# (`{"message":"not found"}` on 404, the same on 401 and 5xx), and "no file" cannot be told from
# "tracker answered with an error" by the body: a broken token or a flapping 5xx would lift release
# discipline from the whole engine. Only an explicit 404 permits; everything else is unknown, and it
# must leave the rule in force.
releases_plugin(){                       # 0 — does not release (no manifest) · 1 — releases or unknown
  [ "$base_sha" = "?" ] && return 1      # base not parsed: nothing to ask, judge strictly
  local body code
  body="$(mktemp)"
  code="$(curl -s --max-time "$API_TIMEOUT" -o "$body" -w '%{http_code}' \
    -H "Authorization: token $TOKEN" \
    "$API/repos/$REPO/contents/.claude-plugin/plugin.json?ref=$base_sha" 2>/dev/null)"
  rm -f "$body"
  # ONLY an explicit 404 lifts the rule: there is no manifest at this path, the repository does not
  # release the plugin. Everything else — 200 (including a directory or symlink instead of a file),
  # 401, 403, 5xx, timeout — is unknown, and it must leave the discipline in force. The body is not
  # parsed at all: "no file" and "tracker answered with an error" are indistinguishable by it, and
  # the cost of a mistake here is one-sided — a false refusal is fixed by the next run, a lifted rule
  # is fixed by nothing.
  [ "$code" = 404 ]
}

# ── journal fragment names: judged on every PR, not only on a rule edit ─────────
# The release assembler refuses the WHOLE release over one name it cannot read, and that refusal comes
# at assembly, works later. A fragment-only PR touches no executable, so the entry demand below never
# speaks for it — the name is judged here instead. Every file the PR leaves under `docs/changelog.d/`
# (added, changed, renamed — anything but deleted) must be the README or a readable fragment, by the
# same full-path pattern the release recognition uses. The tracker is asked about the manifest only
# when such a name is found, and only an engine is held to the form: a project may keep its own.
bad_frag="$(printf '%s\n' "$frows" | awk -F'\t' '$1 != "deleted" && $2 ~ /^docs\/changelog\.d\// { print $2 }' \
  | grep -vE "$RELEASE_PATH_RE" | head -1)"
if [ -n "$bad_frag" ] && ! releases_plugin; then
  echo "PR #$PR: journal fragment «${bad_frag}» is not readable by the release — do not merge."
  echo "  form: docs/changelog.d/<task>.fix.md or docs/changelog.d/<task>.feat.md (docs/changelog.d/README.md)"
  echo "  The release refuses to assemble over such a name, and the refusal would come only at release time."
  exit 1
fi

rule_hit=""
for rdir in $RULE_DIRS; do
  hit="$(printf '%s\n' "$fnames" | grep "^$rdir" | head -1)"
  [ -n "$hit" ] && [ -z "$rule_hit" ] && rule_hit="$hit"
done

if [ "$release_pr" = 1 ]; then
  echo "PR #$PR: release (changelog + manifest + removed fragments) — release discipline does not apply to it"
elif [ -z "$rule_hit" ]; then
  :                                      # the diff touches no executable — no need to ask about the manifest
elif releases_plugin; then
  echo "PR #$PR: repository does not release the plugin — release discipline does not apply"
else
  if [ -n "$rule_hit" ]; then
    # An ADDED fragment counts as the entry. A name in the list asserts nothing by itself: a diff
    # that deletes someone else fragment or fixes a comma in it would pass with zero new entries.
    # The sign is positive (`added`), not "not deleted": should the tracker name a status otherwise,
    # we hit a refusal rather than permit on an unknown word.
    if ! printf '%s\n' "$frows" | grep -qE '^added'"$(printf '\t')"'docs/changelog\.d/[0-9]+\.(fix|feat)\.md$'; then
      echo "PR #$PR: diff changes an executable ($rule_hit), but there is no journal entry — do not merge."
      echo "  missing: a NEW docs/changelog.d/<task>.fix.md or <task>.feat.md"
      echo "  An ADDED file counts as the entry: deletion, an edit of someone else fragment and rename"
      echo "  carry no new lines for projects, and deletion is additionally done by every release."
      echo "  The plugin is installed as a COPY and updated by version: a rule without a release will not reach"
      echo "  the machines, and projects will not see from the journal that the policy has moved. The release raises the version."
      exit 1
    fi
    # What is measured is the TOUCH of the file, not a change of the `version` field inside it — and
    # exactly that is said. An edit of the description or keys of the manifest will not pass either:
    # the machine cannot separate it from a bump here, and promising in the text more than is
    # measured is the very class the lock exists against.
    touched=""
    printf '%s\n' "$fnames" | grep -qx '\.claude-plugin/plugin\.json' && touched=".claude-plugin/plugin.json"
    if printf '%s\n' "$fnames" | grep -qx '\.claude-plugin/marketplace\.json'; then
      [ -n "$touched" ] && touched="$touched and "
      touched="${touched}.claude-plugin/marketplace.json"
    fi
    if [ -n "$touched" ]; then
      echo "PR #$PR: branch touches $touched together with a rule edit — do not merge."
      echo "  The manifest is edited by the release (bin/retainer-release.sh) in a separate branch where there is"
      echo "  nothing but the journal and the manifests: otherwise the version reaches main without its journal section."
      exit 1
    fi
  fi
fi

# ── comment about the RESULT on the tasks being closed ─────────────────────────
# Owner rule: no comment about the results and the work done — the task is not complete.
#
# The seam is here, not in `retainer-task-close.sh`, on purpose: the real closing path is on merge
# (`Closes #N`), and nobody calls that command. A check placed there would be bypassed by the same
# move. The merge lock already refuses without a review record and is already called before the merge.
#
# The machine judges a CHECKABLE fact, not substance — on the pattern of the grounding checker in the
# error journal: a comment exists, it is not service (`review-sha`, `plan-checked`) and not from a
# sync bot. Whether
# the report is substantive enough the machine cannot judge, and pretending it can means creating a
# rule that is bypassed by one word.
#
# The parsing of closing references is NOT duplicated: it is taken from retainer-task-close.sh — a
# second copy of the list of Gitea forms is guaranteed to diverge from the first.
# The exit code MATTERS: empty output is of two kinds — "the PR closes no tasks" (legitimate) and
# "the list was not obtained" (not). The second read as the first, the loop below ran zero times, and
# with it both checks living in it were silently switched off — the result report and the checked
# criteria. The lock reached "merge allowed" without checking anything: fail-open in the gate.
# The reason is NAMED by the neighbour code: 1 — PR body not parsed, tracker silent or no interpreter,
# 2 — usage or no token, 126 — the neighbour is in place but not executable, 127 — no neighbour at
# all. One common string for all cases would lock the merge with no clue, and the tracker address is
# taken differently by the neighbour and by the lock — so there is reason to diverge.
close_refs="$("$(dirname "$0")/retainer-task-close.sh" --print-refs "$REPO" "$PR" 2>/dev/null)" || {
  echo "PR #$PR: list of tasks being closed not obtained (code $?) — report and criteria cannot be checked, do not merge"
  exit 2
}
for ref in $close_refs; do
  # The fourth answer read through a pipe, and the only one of the four whose empty case said "not
  # parsed": the others refuse in their own words or sit inside a branch that is already refusing.
  # The feed of a long task is exactly where this endpoint is slow, so this is the carrier that
  # produced the false diagnoses in the first place.
  rep_json="$(api "repos/$REPO/issues/$ref/comments")"
  require_answer "$rep_json" "with the comments of task #$ref"
  rep="$(printf '%s' "$rep_json" | python3 -c '
import json, re, sys

SERVICE = re.compile(r"review-sha[*_`]*\s*:|^[\s>*_`-]*plan-checked[*_`]*\s*:", re.IGNORECASE | re.MULTILINE)
try:
    rows = json.load(sys.stdin)
except ValueError:
    print("?"); sys.exit()
if not isinstance(rows, list):
    print("?"); sys.exit()
for row in rows:
    if not isinstance(row, dict):
        continue
    body = str(row.get("body") or "")
    if not body.strip():
        continue
    if SERVICE.search(body):                      # a review or plan-check record is service, not a report
        continue
    user = str(((row.get("user") or {}).get("login")) or "")
    if user.endswith("-bot"):                     # automation does not report on work
        continue
    print("yes"); sys.exit()
print("none")
')"
  # Are the acceptance criteria checked? This can only be checked BEFORE the merge: the tracker
  # closes by `Closes #N` itself, and the canon machine in `retainer-task-close.sh` is not executed
  # on this path at all — the command arrives at an already closed task, where refusing is too late.
  # Measured: a task and five more of an overnight marathon were closed with completely empty criteria.
  #
  # The parsing is NOT duplicated: it is taken from where the canon lives (`--print-ac`). A second
  # copy of the rule would diverge from the first — exactly as the closing-reference forms above would.
  crit="$("$(dirname "$0")/retainer-task-close.sh" --print-ac "$REPO" "$ref" 2>/dev/null || printf '?')"
  case "${crit%%$'\t'*}" in
    ok|none) ;;
    '?')     echo "PR #$PR: body of task #$ref not parsed — whether criteria are checked is unknown, do not merge"; exit 2 ;;
    unknown) echo "PR #$PR: task #$ref has checkboxes, but none under an Acceptance Criteria heading — do not merge."
             echo "  The checkboxes were found under other headings:"
             printf '%s\n' "$crit" | tr '\t' '\n' | tail -n +2 | sed 's/^/    /'
             echo "  Name the criteria block «## Acceptance Criteria» (or «## Критерии приёмки») and keep the items right under it:"
             echo "  a subheading between the heading and the list breaks the block at itself."
             exit 1 ;;
    *)       echo "PR #$PR: task #$ref: acceptance criteria not checked — do not merge:"
             printf '%s\n' "$crit" | tr '\t' '\n' | tail -n +2 | sed 's/^/    /'
             echo "  A tick is the assignee statement: the machine does not fill it in. Tick what is done"
             echo "  or explain in the task why an item was dropped."
             echo "  A criterion observable only after the merge: move it to an observation task, and mark it moved here."
             exit 1 ;;
  esac

  case "$rep" in
    yes) ;;
    '?') echo "PR #$PR: comments of task #$ref not parsed — whether a report exists is unknown, do not merge"; exit 2 ;;
    *)   echo "PR #$PR: task #$ref has no result comment — do not merge."
         echo "  No comment about the results and the work done — the task is not complete."
         echo "  The service record «review-sha» does not count as a report: it is about WHAT was read, not about what was done."
         exit 1 ;;
  esac
done

# ── is the branch base current? ────────────────────────────────────────────────
# A green status belongs to the branch HEAD, not to the merge result. If the base moved, the run
# checked what already existed, not what will result: one branch introduces a mechanical rule, another
# at the same time introduces its violation, there is no text conflict, both PRs are green — main is red.
# The check stands BEFORE the statuses on purpose: otherwise the lock first says "green", and a stale
# base reads as a nitpick after the permission.
#
# Compared: `merge_base` from the PR answer — the actual branching point — against the head of the
# base branch itself. They differ: the base moved after the branch left it. NOT `base.sha`: this
# tracker returns the live tip of the base branch in that field, so comparing it would be the tip
# against itself and could never refuse. Not parsed — fail-closed, as everywhere here.
#
# `base.sha` is not judged here — its only consumer `releases_plugin` judges "?" itself,
# earlier in the run.
if [ "$base_ref" = "?" ]; then
  echo "PR #$PR: base branch not named in the tracker answer — base currency cannot be checked, do not merge"
  exit 2
fi
if [ "$merge_base" = "?" ]; then
  echo "PR #$PR: branching point not named in the tracker answer — base currency cannot be checked, do not merge"
  exit 2
fi
base_head="$(api "repos/$REPO/branches/$base_ref" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("?"); sys.exit()
if not isinstance(d, dict):
    print("?"); sys.exit()
print(((d.get("commit") or {}).get("id")) or "?")
')"
[ "$base_head" = "?" ] && { echo "PR #$PR: head of branch $base_ref not read — do not merge"; exit 2; }
if [ "$(printf '%s' "$merge_base" | cut -c1-7)" != "$(printf '%s' "$base_head" | cut -c1-7)" ]; then
  echo "PR #$PR: base is behind $base_ref — the run checked the branch head, not the merge result"
  echo "  branching point: $merge_base"
  echo "  $base_ref now:   $base_head"
  echo "  merge $base_ref in (or rebase) and run the suite AGAIN: a run before that does not count"
  exit 1
fi

# Check status by the head commit, EXCLUDING the context this lock publishes its own verdict under.
# Our own status is our own earlier answer and says nothing about the branch, while the server computes
# the top-level `state` as the worst of ALL contexts — so judging by that field would make one refusal
# permanent: every later run would see its own red and refuse again. The verdict is therefore
# recomputed from the list here, and the server's `state` is not used for it at all.
#
# An empty judged set = no FOREIGN check on the head: in a repository without CI this is normal, not a
# failure, so such a case is allowed and said aloud — otherwise the lock would jam where the gate runs
# on pre-push, not in the cloud. It stays allowed when the only status on the head is ours, for the very
# reason the exclusion exists: an answer of our own tells us nothing we are not recomputing right now.
#
# And exactly for that "empty" must mean empty, not "not parsed". A tracker error (404 on the SHA,
# 404 on the repository, 401 on the token) arrives as valid json without status fields — without a
# check for the sign of a real answer it would read as "CI not configured", i.e. the most broken
# input would give the most permissive output. The sign is the key `sha` or `total_count` in the body.
# A FULL page is a third answer again. Paging genuinely hides contexts here, and `total_count` follows
# the page rather than counting them, so it cannot tell a cut answer from a whole one. What can is the
# page being full: it is indistinguishable from a longer list, and a context beyond it may be red. The
# size is asked for explicitly, and it is the instance's own ceiling: a larger number is clamped to
# it, so a page could never reach the requested size and this guard would go inert — exactly how its
# predecessor was inert. The same reading the executor uses when it searches for a pull request by head.
#
# THE PROGRAM BELOW CARRIES NO COMMENTS, and that is load-bearing: the heredoc is unquoted, so a
# backtick inside it would run as a command substitution. Its two traps are named here instead.
# First, the field on an ELEMENT is `status`; `state` is the name of the TOP-LEVEL field and of what
# the publisher POSTs, so reading `state` per element would match nothing and exclude nothing.
# Second, the three outcomes it prints beside the state — the number of FOREIGN checks, and whether
# our own verdict on this head is red — are what the branches below are written against.
# The page size is named here so the judgement below can compare against it.
STATUS_PAGE=50
status_json="$(api "repos/$REPO/commits/$sha/status?limit=$STATUS_PAGE")"
require_answer "$status_json" "with the check status of head $sha"
read -r st count own <<EOF
$(printf '%s' "$status_json" | LOCK_CONTEXT="$RETAINER_LOCK_CONTEXT" PAGE="$STATUS_PAGE" python3 -c '
import json, os, sys

own_ctx = os.environ["LOCK_CONTEXT"]
page = int(os.environ["PAGE"])
try:
    data = json.load(sys.stdin)
except Exception:
    print("? 0 no")
    sys.exit()
if not isinstance(data, dict) or not ("sha" in data or "total_count" in data):
    print("? 0 no")
    sys.exit()
rows = data.get("statuses") or []
if not isinstance(rows, list):
    print("? 0 no")
    sys.exit()
if len(rows) >= page:
    print("cut 0 no")
    sys.exit()
own = "no"
blocking = pending = foreign = 0
for row in rows:
    if not isinstance(row, dict):
        print("? 0 no")
        sys.exit()
    state = row.get("status")
    if row.get("context") == own_ctx:
        if state in ("failure", "error"):
            own = "red"
        continue
    foreign += 1
    if state in ("failure", "error"):
        blocking += 1
    elif state == "pending":
        pending += 1
    elif state not in ("success", "skipped"):
        print("unknown 0 " + own)
        sys.exit()
if blocking:
    print("failure %d %s" % (foreign, own))
elif pending:
    print("pending %d %s" % (foreign, own))
elif foreign:
    print("success %d %s" % (foreign, own))
else:
    print("none 0 " + own)
')
EOF

# The exclusion is not silent: a refusal of ours standing on the head is why the pull request looks
# shut, and without this line the reader would hide the very record it is ignoring. It stands BEFORE
# the required-context block, which is the only path that reports on the head in CI and would
# otherwise return before the note was printed. Indented, because the LAST line of this output at
# column zero is what the publisher reads as the reason.
if [ "${own:-}" = red ]; then
  echo "  note: this lock's own earlier refusal stands on the head — excluded from the verdict below,"
  echo "  and it keeps the merge shut until a lock run overwrites it on this same head"
fi

# Optional: require THE OWN gate. A recomputed `success` means "every foreign context present on the
# head is green" — if the gate did not run while another checker reported, that is enough for success.
# MERGE_READY_REQUIRE_CONTEXT set — the context must be present and green.
#
# This is its OWN reader of the same body, deliberately not merged with the recompute above: one shared
# parse would let a change to either side silence the other without a word. It looks the context up in
# the raw list, so it answers even where the recompute refuses to judge at all.
# Not asked where the recompute REFUSED TO JUDGE: those outcomes are "not checked" and exit 2 below,
# while this block can exit 1 — and a refusal is published as a verdict now, so an unparsed or
# truncated answer would go out as a red status whose stated reason is wrong.
REQ="${MERGE_READY_REQUIRE_CONTEXT:-}"
case "$st" in '?'|cut|unknown) REQ="" ;; esac
if [ -n "$REQ" ]; then
  hit="$(printf '%s' "$status_json" | REQ="$REQ" python3 -c '
import json, os, sys
want = os.environ["REQ"]
try:
    d = json.load(sys.stdin)
except Exception:
    print("no"); sys.exit()
for s in (d.get("statuses") or []):
    if s.get("context") == want:
        print("ok" if s.get("status") == "success" else "bad"); sys.exit()
print("missing")
')"
  case "$hit" in
    ok)      ;;
    missing) echo "PR #$PR: required check «${REQ}» is missing on the head commit — do not merge"; exit 1 ;;
    *)       echo "PR #$PR: required check «${REQ}» is not green — do not merge"; exit 1 ;;
  esac
fi

# The verdict names the HEAD it was issued for: the lock executor (`retainer-merge-lock.sh`) hangs the
# status on exactly this commit, not on "the current branch". The same line used to be accompanied by
# a write to `~/.cache/retainer/merge-verdict`, read by a guard rule; the rule was cut together with
# the guard procedural layer, and the file would remain state with no reader.
case "$st:$count" in
  success:*)  echo "PR #$PR: checks green ($count) — merge allowed"; echo "  verdict issued on head $sha"; exit 0 ;;
  none:0)     echo "PR #$PR: no checks on the head commit (CI not configured) — merge allowed"; echo "  verdict issued on head $sha"; exit 0 ;;
  pending:*)  echo "PR #$PR: checks still running — wait, do not merge"; exit 1 ;;
  \?:*)       echo "check status of PR #$PR not parsed (tracker error) — do not merge"; exit 2 ;;
  cut:*)      echo "PR #$PR: the status page came back full — a context beyond it may be red, not checked, do not merge"; exit 2 ;;
  unknown:*)  echo "PR #$PR: a check on the head reports a state the lock does not know — not checked, do not merge"; exit 2 ;;
  *)          echo "PR #$PR: checks not green (state: $st) — do not merge"; exit 1 ;;
esac
