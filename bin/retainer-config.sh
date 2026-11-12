#!/usr/bin/env bash
# Global retainer config — a single source of truth OVER per-project .retainer/.
# Lives in ~/.config/retainer/config.toml (env override RETAINER_CONFIG — for tests). Template:
# presets/global-config.toml.template. Change it here — applies in ALL projects where retainer is connected.
#
# Usage (source): . "$(dirname "$0")/retainer-config.sh"; url="$(retainer_cfg tracker_url http://localhost:3000)"
#
# We read FLAT keys (up to the first [table]) — like the guard/conveyor mini-parser (macOS py3.9 has no tomllib,
# no dependencies pulled in). Linked lists (connected_projects) live separately: the managed-repos registry
# stays a plain list of paths — the managed-project walks read it, and the list needs no TOML parsing.

# Reasons for which a task need not be filed: the list is EMPTY because the guard has no observation
# reasons left — the procedural layer was removed. The seam stays: it is one for all consumers, and a second
# copy of the list would drift from the first silently. An entry here means "the rule fires routinely,
# and a task per firing would flood", not "bypass allowed".
export RETAINER_ADVISORY_REASONS=""

# The status context the merge lock publishes its verdict under. ONE home for two readers: the
# publisher (`retainer-merge-lock.sh`) and the reader that must exclude its OWN verdict when it
# judges a head (`retainer-merge-ready.sh`). Two literals drift silently, and this drift is
# invisible: the exclusion stops matching, and a refused pull request never turns green again.
#
# A plain assignment, no `${...:-}` substitution. The value must agree with a SERVER setting
# (`status_check_contexts` of branch protection), which the code cannot read back, so letting the
# environment decide it would mean a control switched off from outside. Exported, like the list above,
# only so that a self-lint does not read a value whose readers live in other files as dead: both of
# them source this file themselves, so nothing arrives by inheritance, and the assignment overrides
# anything inherited anyway.
export RETAINER_LOCK_CONTEXT="retainer/merge-lock"

# retainer_cfg <key> [default] — value of a flat key of the global config, or default.
retainer_cfg() {
  local key="$1" def="${2:-}" cfg="${RETAINER_CONFIG:-$HOME/.config/retainer/config.toml}" val=""
  [ -f "$cfg" ] && val="$(awk -v k="$key" '
    /^[[:space:]]*\[/ { exit }                       # flat keys only BEFORE the first [table]
    $0 ~ ("^[[:space:]]*" k "[[:space:]]*=") {
      sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, "");
      gsub(/["'"'"']/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "");
      print; exit
    }' "$cfg" 2>/dev/null)"
  printf '%s' "${val:-$def}"
}

# The list of places to look for the tracker token is ONE for the whole engine: a copy in a separate script drifts
# from the original silently, and a skipped check is indistinguishable from a passed one.
#
# A tilde in a declared path is expanded here: the config is written by a human, and `~/...` is the ordinary form;
# storing it as is would search for a file in a directory named `~`.
retainer_token_paths() {
  local declared
  declared="$(retainer_cfg gitea_token_path "")"
  [ -n "$declared" ] && printf '%s\n' "${declared/#\~/$HOME}"
  # The default stays in the chain even when the key is set: on a machine where the key points elsewhere,
  # the old file may lie nearby and be the only live one.
  printf '%s\n' "$HOME/.config/retainer/gitea_token"
}

# retainer_token — the tracker token or an empty string. Order: environment → declared path →
# default.
#
# A NON-EMPTY value counts as valid, not an existing file. An empty or unreadable file does not break the
# chain: otherwise a declared but empty stub would cancel the live default — and a "no token" verdict
# would be issued over a machine that has one.
retainer_token() {
  local token="${GITEA_TOKEN:-}" path value
  [ -n "$token" ] && { printf '%s' "$token"; return 0; }
  while IFS= read -r path; do
    [ -n "$path" ] && [ -f "$path" ] || continue
    value="$(cat "$path" 2>/dev/null || true)"
    # The file exists but has no value — an environment defect, and staying silent about it returns that same
    # indistinguishable skip. Diagnostics go to stderr: stdout here is the token value.
    [ -n "$value" ] || { printf 'retainer: %s is unreadable or empty — searching on\n' "$path" >&2; continue; }
    printf '%s' "$value"
    return 0
  done <<TOKEN_PATHS_EOF
$(retainer_token_paths)
TOKEN_PATHS_EOF
  return 0
}

# ── base branch: the name is taken from the REPOSITORY, not a constant ─────────────────────────
# One home for all commands: a rule duplicated across files drifts silently — and drifts toward a
# project whose main branch is named differently, i.e. exactly where nobody checks it.

# retainer_remote [dir] — whom to ask for the base: `origin` if it exists; else the only remote;
# else the only one with a DECLARED `HEAD`; else empty. A choice of "any of several" is
# not made: it silently leads the base into someone else's mirror, and a disagreement between two declarations is not something
# to guess.
retainer_remote() {
  local dir="${1:-.}" names name declared=""
  names="$(git -C "$dir" remote 2>/dev/null)"
  [ -n "$names" ] || return 0
  printf '%s\n' "$names" | grep -qx origin && { printf 'origin'; return 0; }
  [ "$(printf '%s\n' "$names" | grep -c .)" = 1 ] && { printf '%s' "$names"; return 0; }
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    git -C "$dir" symbolic-ref --quiet "refs/remotes/$name/HEAD" >/dev/null 2>&1 || continue
    [ -z "$declared" ] || return 0        # two declarations that may disagree — we do not guess
    declared="$name"
  done <<REMOTES_EOF
$names
REMOTES_EOF
  printf '%s' "$declared"
  return 0
}

# retainer_base_branch [dir] [remote] — the NAME of the main branch, declared by the repository itself. Empty
# means "cannot determine": the caller refuses with its own text, rather than silently taking `main` for the base.
#
# Tiers; the `main` default is the LAST link here, not the first:
#   1) `refs/remotes/<remote>/HEAD` — what the repository declared itself;
#   2) exactly one branch on `<remote>` — that one (a mirror without `HEAD`): a FACT of the repository;
#   3) `<remote>/main` or `main` exists — projects on `main` keep working as before;
#   4) otherwise empty.
#
# A second name is NOT guessed: blindly substituting `master` misses exactly where the name is
# non-standard, and an abandoned branch is taken for the base.
retainer_base_branch() {
  local dir="${1:-.}" remote="${2:-}" head_ref only cand
  [ -n "$remote" ] || remote="$(retainer_remote "$dir")"
  if [ -n "$remote" ]; then
    # One reader of the VALUE of refs/remotes/<remote>/HEAD in the engine, and it is the function
    # below: a second call of the same form here is what the single-resolution rule exists against.
    # `retainer_remote` probes the same ref for EXISTENCE and must stay as it is: it CHOOSES the
    # remote, and a chooser must not depend on a reader that resolves the remote itself — routing the
    # probe through this function WITHOUT the remote name recurses without bound (measured).
    head_ref="$(retainer_clone_default_branch "$dir" "$remote")"
    # Exactly the remote prefix is stripped, not everything up to the last slash: a branch `release/v1` has a slash inside
    # the name, and cutting at it would return `v1` — a name that does not exist in the repository.
    [ -n "$head_ref" ] && { printf '%s' "${head_ref#"$remote"/}"; return 0; }
  fi
  # Exactly one branch on the remote — it is the base: a FACT of the repository, and it outranks the default.
  # The tier sits before `main` on purpose: otherwise an abandoned local `main` beat the real
  # main branch, and the diff went against a branch the project had left.
  if [ -n "$remote" ]; then
    only="$(git -C "$dir" for-each-ref --format='%(refname:lstrip=3)' "refs/remotes/$remote" 2>/dev/null \
      | grep -vx HEAD)"
    [ "$(printf '%s\n' "$only" | grep -c .)" = 1 ] && { printf '%s' "$only"; return 0; }
  fi
  # The default is the LAST link. Full ref paths, not a bare name: `rev-parse main` takes a
  # TAG `main` for the base, i.e. the diff would go against anything merely named `main`.
  for cand in ${remote:+"refs/remotes/$remote/main"} refs/heads/main; do
    git -C "$dir" rev-parse --verify --quiet "$cand" >/dev/null 2>&1 && { printf 'main'; return 0; }
  done
  return 0
}

# retainer_base_ref [dir] [remote] — the EXISTING base ref: `<remote>/<name>` if it exists, else
# local `<name>`. Empty — base not found: the diff has nothing to branch from, and then the command says so
# aloud instead of measuring the whole tree.
retainer_base_ref() {
  local dir="${1:-.}" remote="${2:-}" name cand
  [ -n "$remote" ] || remote="$(retainer_remote "$dir")"
  name="$(retainer_base_branch "$dir" "$remote")"
  [ -n "$name" ] || return 0
  for cand in ${remote:+"$remote/$name"} "$name"; do
    git -C "$dir" rev-parse --verify --quiet "$cand" >/dev/null 2>&1 && { printf '%s' "$cand"; return 0; }
  done
  return 0
}

# retainer_clone_default_branch [dir] [remote] — the branch a CLONER receives: `<remote>/<name>` taken
# from refs/remotes/<remote>/HEAD, and nothing else. Empty — unresolvable: no remote, or HEAD never set.
# That ref is the LOCAL cache of what the last clone or fetch recorded, not the server's HEAD today:
# chosen deliberately, because the answer must come without network and without a token. After the
# default branch is renamed on the server a stale ref can still answer, and the honesty then rests on
# the reader of the tree refusing to judge what it could not read.
# Deliberately NOT retainer_base_branch: that one answers "what to branch from" and degrades to a local
# `main` so that work can continue. For delivery the same degradation would call a seam delivered in a
# repository nobody can clone — the two questions have different right answers.
retainer_clone_default_branch() {
  local dir="${1:-.}" remote="${2:-}" head_ref
  [ -n "$remote" ] || remote="$(retainer_remote "$dir")"
  [ -n "$remote" ] || return 0
  head_ref="$(git -C "$dir" symbolic-ref --short "refs/remotes/$remote/HEAD" 2>/dev/null || true)"
  printf '%s' "$head_ref"
}

# retainer_api_default_branch <api> <auth-header> <owner/repo> — the main branch per the TRACKER, for commands
# that go to it anyway. Empty — the tracker did not answer, or answered without the field: "don't know" and "main" are
# different answers, and conflating them protects a branch that does not exist in the repository.
retainer_api_default_branch() {
  local body
  # The transport code is swallowed here: a network failure returns 7, and under `set -e` in the caller it killed
  # the run before the refusal was printed. An empty reply is a normal result, the caller judges it.
  body="$(curl -s --max-time 15 -H "$2" "$1/repos/$3" 2>/dev/null || true)"
  printf '%s' "$body" | python3 -c '
import json
import sys

try:
    row = json.load(sys.stdin)
except ValueError:
    raise SystemExit
if isinstance(row, dict):
    sys.stdout.write(str(row.get("default_branch") or ""))
' 2>/dev/null || true
}

# retainer_api_code <api> <auth-header> <path after /api/v1/> — the tracker's response CODE, or `000` when
# there was no response at all. Needed where "the tracker is silent" and "the tracker answered but the field is missing" must
# be told apart: the empty value is the same for both, but the causes differ, and
# mixing them up is the defect the check exists to prevent.
retainer_api_code() {
  # `-w %{http_code}` prints `000` itself on a transport failure, so there is no `000` of our own here: a second
  # would be appended to the first and give `000000` — a value that compares with nothing.
  curl -s -o /dev/null --max-time 15 -w '%{http_code}' -H "$2" "$1/$3" 2>/dev/null
  return 0
}

# retainer_token_places — where the token was SEARCHED for, on one line. Needed where a refusal is printed to a human:
# "no token" without the list of places does not tell an empty machine from one where the token lies elsewhere.
# The list comes from the same function as the search: a second list of its own would drift from the first — exactly
# the class the seam exists for.
retainer_token_places() {
  local path out=""
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    out="${out:+$out, }$path"
  done <<PLACES_EOF
$(retainer_token_paths)
PLACES_EOF
  printf '%s' '$GITEA_TOKEN'
  [ -n "$out" ] && printf ', %s' "$out"
}

# retainer_refuse_foreign_engine_tree <path inside the script's tree> <what would break> — refusal
# to work over a FOREIGN engine copy. Returns 0 if work is allowed, and 2 with an explanation on stderr.
# The first argument is any path inside the script's tree (root or `bin/`): git finds the tree from it
# itself.
#
# The local half of the flow commands (branch, marker) runs in the CURRENT directory, while the script may lie in
# another repository: an engine copy on a stand is a full tree. Then the branch is created in one
# tree and the work is done in another: both operations are legitimate, the code is zero, the output cheerful, and the mismatch
# is discovered only at `push`.
#
# The refusal is NARROW — only "engine over another engine copy":
#   * a plugin-box script over a project is the normal path, and the box is not a git tree;
#   * an engine-tree script over a FOREIGN project is also normal: the engine lies alongside for that;
#   * a script of one engine copy run in another is a defect: both repositories are real, both
#     "own", and the script cannot guess which was meant.
# The sign of an engine copy is the plugin manifest at the tree ROOT: the live tree and a stand have it, a
# managed project does not; vendoring the engine in a subdirectory raises no refusal.
#
# `GIT_WORK_TREE` in the environment makes the trees equal for git — then the refusal does not fire: addressing
# in such an environment is set by the caller.
#
# One home for the check, although two call it.
retainer_refuse_foreign_engine_tree() {
  local self_tree here_tree what="${2:-The work would go to the wrong tree}"
  self_tree="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null || printf '')"
  here_tree="$(git rev-parse --show-toplevel 2>/dev/null || printf '')"
  # A directory outside a repository gives an empty value, and it never reaches the refusal: the plugin manifest
  # is looked up under that empty root, i.e. at the filesystem root, where it does not exist.
  [ "$self_tree" != "$here_tree" ] || return 0
  [ -f "$self_tree/.claude-plugin/plugin.json" ] || return 0
  [ -f "$here_tree/.claude-plugin/plugin.json" ] || return 0
  echo "✗ the script lives in a different repository than the current directory:" >&2
  echo "    script:    $self_tree" >&2
  echo "    directory: $here_tree" >&2
  echo "  $what — silently." >&2
  echo "  Call the script of the tree you are working in (or cd into the script's tree)." >&2
  return 2
}

# ── the cycle's own state: per session, outside every working tree ─────────────────────────────
# The task markers lived in `.retainer/` of the tree, which the harness denies to the agent as a whole,
# and one file served every session of the tree, so the marker named whoever wrote last. They live in
# the machine's config instead, keyed by the repository and the session:
#   <home>/<project>/<session>/active-issue · <session>/plan-checked · shared/… · handoff.md
# The project key is the remote's owner/repo, so a stand and the live tree of one repository share
# it and a session's task is seen from both. No remote: the tree's own path. The tree's old
# `.retainer/<name>` files are not read: one file there is shared by every session.

# retainer_repo_slug <dir> — `owner/repo` of the tree's remote; empty without one.
retainer_repo_slug() {
  local remote url
  remote="$(retainer_remote "${1:-.}")"
  [ -n "$remote" ] || return 0
  url="$(git -C "${1:-.}" remote get-url "$remote" 2>/dev/null)" || return 0
  url="${url%/}"; url="${url%.git}"
  case "$url" in
    *:*/*) url="${url##*:}" ;;     # scp form host:owner/repo, and the path of a URL below
  esac
  url="${url#//}"
  printf '%s\n' "$url" | awk -F/ 'NF >= 2 && $(NF-1) != "" && $NF != "" { print $(NF-1) "/" $NF }'
}

# retainer_session — the session's slot name: CLAUDE_CODE_SESSION_ID reduced to [A-Za-z0-9-], or `shared`.
# The value becomes a path component, so nothing but those characters reaches it.
retainer_session() {
  local id
  id="$(printf '%s' "${CLAUDE_CODE_SESSION_ID:-}" | tr -dc 'A-Za-z0-9-')"
  [ -n "$id" ] || id=shared
  printf '%s\n' "$id"
}

# retainer_state_dir <dir> — the project's state directory. Prints it, creates nothing.
retainer_state_dir() {
  local top key
  top="$(git -C "${1:-.}" rev-parse --show-toplevel 2>/dev/null)" || top="$(cd "${1:-.}" && pwd -P)"
  key="$(retainer_repo_slug "$top")"
  if [ -n "$key" ]; then key="$(printf '%s' "$key" | sed 's#/#__#')"
  else key="$(printf '%s' "$top" | tr '/' '_')"; fi
  printf '%s/%s\n' "${RETAINER_STATE_HOME:-$HOME/.config/retainer/state}" "$key"
}

# retainer_marker <dir> <name> — digits of the session's marker, else of the shared slot; empty when
# neither holds digits.
retainer_marker() {
  local home val place
  home="$(retainer_state_dir "$1")"
  for place in "$home/$(retainer_session)/$2" "$home/shared/$2"; do
    [ -f "$place" ] || continue
    val="$({ tr -dc '0-9' < "$place"; } 2>/dev/null)"
    [ -n "$val" ] && { printf '%s\n' "$val"; return 0; }
  done
  return 0
}

# retainer_marker_set <dir> <name> <value> — writes the session's marker; 1 when it could not.
retainer_marker_set() {
  local slot
  slot="$(retainer_state_dir "$1")/$(retainer_session)"
  mkdir -p "$slot" 2>/dev/null && printf '%s\n' "$3" > "$slot/$2" 2>/dev/null
}

# retainer_marker_clear <dir> <name> <value> — removes the marker from the session's slot and from the
# shared one, each only when it holds <value>: a neighbour's task is never erased.
# Prints how many it removed.
retainer_marker_clear() {
  local home place n=0
  home="$(retainer_state_dir "$1")"
  for place in "$home/$(retainer_session)/$2" "$home/shared/$2"; do
    [ -f "$place" ] && [ "$({ tr -dc '0-9' < "$place"; } 2>/dev/null)" = "$3" ] && rm -f "$place" 2>/dev/null && n=$((n + 1))
  done
  printf '%s\n' "$n"
}
