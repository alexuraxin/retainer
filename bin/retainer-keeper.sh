#!/usr/bin/env bash
# retainer keeper — periodic "reviver" invoked by a launchd timer
# (presets/launchd/com.retainer.keeper.plist). Keeps TWO jobs alive:
#   • pult — settings server down/not started → bring up server-only on the stable port (no browser);
#   • conveyor — run conveyor-poll.sh (inert without conveyor.conf by itself, respawns on limits).
# Both by default. Safe: each job is soft (|| true), one failing does not take down the other.
#   retainer-keeper.sh [--pult|--conveyor|--both]   (default --both)
# Test seams: $RETAINER_SETTINGS_PIDFILE (pult pidfile), $RETAINER_SETTINGS_SH (launcher),
#   $CONVEYOR_POLL (path to conveyor-poll.sh).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---both}"
mkdir -p "$HOME/.cache/retainer" 2>/dev/null || true   # launchd log dir (else the first output is dropped)

# Job stderr is NOT silenced (2>/dev/null would swallow diagnostics in keeper.log): serve errors (exit 4,
# python traceback) and the conveyor log() must stay visible. Softness comes from `|| true`, not suppression.
ensure_pult() {
  local pidfile="${RETAINER_SETTINGS_PIDFILE:-$HOME/.config/retainer/.settings-server.pid}"
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
    return 0   # alive — no-op
  fi
  "${RETAINER_SETTINGS_SH:-$ROOT/bin/retainer-settings.sh}" serve >/dev/null || true  # stdout quiet, stderr → log
}

run_conveyor() {
  local poll="${CONVEYOR_POLL:-$ROOT/bin/conveyor-poll.sh}"
  [ -f "$poll" ] || return 0     # no conveyor — just skip
  bash "$poll" || true           # its log()/errors → keeper.log; it gates RESPAWN/limits/kill-switch itself
}

case "$MODE" in
  --pult)      ensure_pult ;;
  --conveyor)  run_conveyor ;;
  --both|"")   ensure_pult; run_conveyor ;;
  *) echo "usage: retainer-keeper.sh [--pult|--conveyor|--both]" >&2; exit 2 ;;
esac
