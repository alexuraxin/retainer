#!/usr/bin/env bash
# retainer: where the cycle's own state is written — the path an agent or a role writes with Write.
#
#   retainer-state.sh path active-issue|plan-checked|tree|handoff.md|graph [project dir]
#   retainer-state.sh get active-issue|plan-checked [project dir]   — the session's own marker digits, or nothing
#   retainer-state.sh tree                                          — the tree this session took its task in
# exit 0 — the path is printed and its directory exists (`get` and `tree`: printed or nothing) · 1 — the
# directory could not be made · 2 — usage.
#
# The markers are per session; the handoff and the code graph are one per project (the handoff is written
# for the NEXT session, which has another id). `graph` names a directory, not a file: its basename is
# `graphify-out` because graphify leaves out every source directory named like its output. The home is outside every working tree, so the agent writes it itself; the
# readers find it through `retainer_marker` in bin/retainer-config.sh.
# complexity: keep, step 7 — without it the agent and plan-checker compute the state path by hand from a formula, and the copies drift
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=bin/retainer-config.sh
. "$ROOT/bin/retainer-config.sh"

usage(){
  echo "usage: retainer-state.sh path active-issue|plan-checked|tree|handoff.md|graph [project dir]" >&2
  echo "       retainer-state.sh get active-issue|plan-checked [project dir] | tree" >&2
  exit 2
}
# The tree is looked up across projects: its reader stands outside any repository, where the project key
# is unknown. A session id is unique, so only one session's slots match; the newest record wins.
if [ "${1:-}" = tree ]; then
  [ "$(retainer_session)" = shared ] && exit 0
  newest=""; pick=""
  for place in "${RETAINER_STATE_HOME:-$HOME/.config/retainer/state}"/*/"$(retainer_session)"/tree; do
    held="$(cat "$place" 2>/dev/null)"
    [ -d "$held" ] || continue
    if [ -z "$newest" ] || [ "$place" -nt "$newest" ]; then newest="$place"; pick="$held"; fi
  done
  [ -z "$pick" ] || printf '%s\n' "$pick"
  exit 0
fi
case "${1:-}" in
  # The session's OWN slot only: the shared one is written by a run with no session, and reading it
  # would make that run's task every session's.
  get) case "${2:-}" in
         active-issue|plan-checked)
           [ "$(retainer_session)" = shared ] && { echo; exit 0; }
           { tr -dc '0-9' < "$(retainer_state_dir "${3:-.}")/$(retainer_session)/$2"; } 2>/dev/null; echo; exit 0 ;;
         *) usage ;;
       esac ;;
  path) ;;
  *) usage ;;
esac
NAME="${2:-}"; DIR="${3:-.}"
home="$(retainer_state_dir "$DIR")"
case "$NAME" in
  active-issue|plan-checked|tree) place="$home/$(retainer_session)/$NAME" ;;
  handoff.md) place="$home/handoff.md" ;;
  graph) place="$home/graphify-out" ;;
  *) usage ;;
esac
mkdir -p "${place%/*}" 2>/dev/null || { echo "✗ cannot create ${place%/*}" >&2; exit 1; }
printf '%s\n' "$place"
