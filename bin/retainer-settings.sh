#!/usr/bin/env bash
# retainer: settings launcher — starts a LOCAL server
# (127.0.0.1, no egress) and opens the settings page in the browser. The "Save" button on a page
# writes ~/.config/retainer/config.toml directly (POST /save). The server lives in the background; stop it:
#   retainer-settings.sh stop
# Test seams: $SETTINGS_DIR (pages dir), $RETAINER_OPENER (open command),
# $RETAINER_SETTINGS_SERVER (server command), $RETAINER_SETTINGS_PIDFILE (pid file).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${SETTINGS_DIR:-$ROOT/docs/settings-page}"
# SERVER is an array (command+args), not a string: the quoted "${SERVER[@]}" needs no word-split crutch
# (SC2086). The env override RETAINER_SETTINGS_SERVER is a "python3 path" string, split with read -a; the default
# keeps the path as ONE element (robust to spaces in $ROOT).
if [ -n "${RETAINER_SETTINGS_SERVER:-}" ]; then
  read -r -a SERVER <<<"$RETAINER_SETTINGS_SERVER"
else
  SERVER=(python3 "$ROOT/bin/retainer_settings_server.py")
fi
PIDFILE="${RETAINER_SETTINGS_PIDFILE:-$HOME/.config/retainer/.settings-server.pid}"

usage() { echo "usage: retainer-settings.sh [settings|rigor|all|stop]  (default: all)" >&2; }

# ── stop: kill the background server ──
if [ "${1:-}" = "stop" ]; then
  if [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "panel stopped"
  else
    echo "panel not running"
  fi
  rm -f "$PIDFILE"
  exit 0
fi

# ── serve: start the server WITHOUT a browser (for keeper/launchd). Idempotent: alive → no-op ──
if [ "${1:-}" = "serve" ]; then
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    echo "panel already alive (pid $(cat "$PIDFILE"))"; exit 0
  fi
  [ -f "$DIR/retainer-settings.html" ] || { echo "no pages: $DIR" >&2; exit 4; }
  mkdir -p "$(dirname "$PIDFILE")" 2>/dev/null || true
  # nohup + </dev/null (no weaker than the conveyor's detach) — survive the exit of the keeper/launchd job
  nohup "${SERVER[@]}" "$DIR" >/dev/null 2>&1 </dev/null &
  echo "$!" > "$PIDFILE"
  echo "panel started server-only (pid $!, usually http://127.0.0.1:8765)"
  exit 0
fi

# One page holds both layers; `rigor` opens it at the project part.
PAGE="retainer-settings.html"
case "${1:-all}" in
  settings|all) anchor="" ;;
  rigor)        anchor="#project" ;;
  -h|--help)    usage; exit 0 ;;
  *)            echo "unknown argument: $1" >&2; usage; exit 2 ;;
esac

# ── page in place? (exit 4 — as before) ──
[ -f "$DIR/$PAGE" ] || { echo "no page: $DIR/$PAGE" >&2; exit 4; }

# ── opener: seam → autodetect (macOS open / Linux xdg-open) ──
opener="${RETAINER_OPENER:-}"
if [ -z "$opener" ]; then
  if command -v open >/dev/null 2>&1; then
    opener="open"
  elif command -v xdg-open >/dev/null 2>&1; then
    opener="xdg-open"
  else
    echo "no opener (open/xdg-open) in PATH" >&2
    exit 3
  fi
fi

# ── stop the previous server (one at a time) ──
if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; fi
mkdir -p "$(dirname "$PIDFILE")" 2>/dev/null || true

# ── start the server in the background, read the port (first stdout line) ──
portfile="$(mktemp)"
"${SERVER[@]}" "$DIR" > "$portfile" 2>/dev/null &
srv=$!
echo "$srv" > "$PIDFILE"
port=""
i=0
while [ "$i" -lt 30 ]; do
  port="$(head -1 "$portfile" 2>/dev/null || true)"
  [ -n "$port" ] && break
  i=$((i + 1)); sleep 0.1
done
rm -f "$portfile"
if [ -z "$port" ]; then echo "server did not start" >&2; kill "$srv" 2>/dev/null || true; rm -f "$PIDFILE"; exit 6; fi

# ── open the page via the local URL ──
rc=0
"$opener" "http://127.0.0.1:$port/$PAGE$anchor" || { echo "opener failed on: $PAGE" >&2; rc=5; }
if [ "$rc" != 0 ]; then kill "$srv" 2>/dev/null || true; rm -f "$PIDFILE"; exit "$rc"; fi

echo "panel: http://127.0.0.1:$port (in the background, pid $srv). Change settings → \"Save\". Stop: retainer-settings.sh stop"
exit 0
