#!/usr/bin/env bash
# retainer: ask the code graph of a project — where a name is defined, who calls it, how two names relate.
#
#   retainer-graph.sh [-C <project dir>] explain "<name>"
#   retainer-graph.sh [-C <project dir>] path "<A>" "<B>"
#   retainer-graph.sh [-C <project dir>] refresh            — rebuild only if the code changed, answer nothing
# exit 0 — answered (refresh: the graph is current) · 1 — the rebuild or the query failed · 2 — usage, no
#          graphify, or not inside a git repository.
#
# The graph lives in the engine's state home of the project (`retainer-state.sh path graph`), never in the
# tree: nothing is committed and no gate reads it. Before answering, the command compares a fingerprint
# of the tree with the one the graph was built from and rebuilds first when they differ, so an answer
# never describes code that is no longer there. The fingerprint is written only after a successful build:
# a failed one is retried by the next call, and its graph is not used.
# complexity: keep, step 7 — without it the agent cannot find a graph outside the tree, and a stale answer reads as confident as a fresh one
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage(){
  echo "usage: retainer-graph.sh [-C <project dir>] explain \"<name>\" | path \"<A>\" \"<B>\" | refresh" >&2
  exit 2
}
DIR="."
if [ "${1:-}" = -C ]; then [ -n "${2:-}" ] || usage; DIR="$2"; shift 2; fi
CMD="${1:-}"
case "$CMD" in
  explain) [ $# -eq 2 ] || usage ;;
  path) [ $# -eq 3 ] || usage ;;
  refresh) [ $# -eq 1 ] || usage ;;
  *) usage ;;
esac

TREE="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "✗ not inside a git repository: $DIR" >&2; exit 2; }
command -v graphify >/dev/null 2>&1 || {
  echo "✗ graphify is not installed — install it with: uv tool install graphifyy" >&2; exit 2; }
# defer: one graph per repository slug, so a stand and the live tree of one repository rebuild it in turn, upgrade: rebuild churn seen when working from stands
HOME_DIR="$("$ROOT/bin/retainer-state.sh" path graph "$TREE")" || exit 1
mkdir -p "$HOME_DIR" || { echo "✗ cannot create $HOME_DIR" >&2; exit 1; }
GRAPH="$HOME_DIR/graph.json"
STAMP="$HOME_DIR/.fingerprint"
LOCK="$HOME_DIR.lock"
# How long a waiter waits for another rebuild, in seconds; the corpus shortens it.
WAIT="${RETAINER_GRAPH_WAIT:-120}"

# What the graph is built from: the index (additions, deletions, staged edits), the unstaged diff, and the
# untracked files that are not ignored, each with its checksum.
fingerprint(){
  (
    cd "$TREE" || exit 1
    git ls-files -s
    git diff --no-ext-diff --no-textconv --binary
    git ls-files -o --exclude-standard -z | while IFS= read -r -d '' f; do
      [ -f "$f" ] && printf '%s %s\n' "$(cksum < "$f")" "$f"
    done
  ) | cksum
}

# The close refresh and the next query can meet, and graphify writes graph.json in place. A rebuild holds
# the lock; a waiter gives up after WAIT seconds, and a lock older than ten minutes is a dead run's. A
# stale lock that cannot be removed is waited on like a live one, so the loop always counts toward WAIT.
take_lock(){
  local waited=0
  until mkdir "$LOCK" 2>/dev/null; do
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ] && rmdir "$LOCK" 2>/dev/null; then
      continue
    fi
    [ "$waited" -ge "$WAIT" ] && { echo "✗ another rebuild of this graph holds $LOCK" >&2; return 1; }
    sleep 1; waited=$((waited + 1))
  done
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
}

current(){
  [ -f "$GRAPH" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$1" ]
}

rebuild(){
  local seen
  seen="$(fingerprint)" || { echo "✗ cannot read the tree $TREE" >&2; return 1; }
  # A current graph is read at once unless a rebuild is writing it right now; then the reader waits.
  current "$seen" && [ ! -d "$LOCK" ] && return 0
  take_lock || return 1
  # Another run may have built it while this one waited: one build serves every waiter.
  current "$seen" && return 0
  rm -f "$STAMP"
  echo "▶ no graph yet, or the code changed since it was built — building $HOME_DIR (seconds)…" >&2
  if (cd "$TREE" && GRAPHIFY_OUT="$HOME_DIR" GRAPHIFY_FORCE=1 graphify update .) > "$HOME_DIR/update.log" 2>&1 \
     && [ -f "$GRAPH" ]; then
    printf '%s\n' "$seen" > "$STAMP"
    return 0
  fi
  echo "✗ graphify update failed — the graph is not used until a rebuild succeeds; log: $HOME_DIR/update.log" >&2
  tail -5 "$HOME_DIR/update.log" >&2
  return 1
}

rebuild || exit 1
case "$CMD" in
  refresh) exit 0 ;;
  explain) graphify explain "$2" --graph "$GRAPH" || exit 1 ;;
  path) graphify path "$2" "$3" --graph "$GRAPH" || exit 1 ;;
esac
