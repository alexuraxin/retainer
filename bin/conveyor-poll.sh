#!/usr/bin/env bash
# retainer CONVEYOR: polls the tracker's in-progress tasks; if work exists but no live session does, it
# continues the cycle itself (headless claude) without waiting for a manual restart in chat. Provisional
# (will move to the retainer web settings later). Called periodically by a launchd timer (see presets/launchd).
#
# ⚠ AUTONOMY: for the spawned `claude -p` to actually drive the cycle (edit/commit/push), the owner raises
#   its permissions (--permission-mode / tool allowlist). THIS = handing autonomous write/commit/push to an
#   UNATTENDED agent with no human in the loop. The only safeguard then is the guard
#   (destructive-gate, protected files). Raise permissions deliberately; prefer an allowlist, not skip-all.
#
# SAFE BY DEFAULT: inert without a config and when RESPAWN!=1 (log only). Anti-runaway gates
# fail CLOSED (bad number → do NOT spawn). Kill-switch, rate-limit (clamp ≥300s), attempt ceiling,
# mutual exclusion (atomic mkdir-lock), pre-flight binary check (launchd gives a minimal PATH!).
#
# Config: ~/.config/retainer/conveyor.conf (bash), example:
#   RESPAWN=1                                  # 0/empty → poll+log only (default 0)
#   REPOS="owner/project owner/my-project"
#   DIR_owner_project="$HOME/project"     # key = owner/repo with /,-,. replaced by _
#   DIR_owner_my_project="$HOME/my-project"
#   PROMPT="Continue the in-progress task per the retainer cycle (issue-first → plan → plan-checker → …)."
#   RESPAWN_CMD='$HOME/.local/bin/claude -p "$PROMPT"'   # ABSOLUTE path! launchd PATH is minimal.
#   MIN_RESPAWN_SEC=1800                        # debounce (clamped from below to 300)
#   MAX_RESPAWNS=5                              # respawn ceiling per repo while the task is not closed
#   STUCK_AFTER=10800                           # sec without ANY sign of life (run.log/.git/spawn) → SIGTERM the hung session (clamped from below to 3600)
# Kill-switch: ~/.retainer/conveyor.off  — if the file exists the conveyor does nothing.
# Token: the engine's shared resolver (retainer_token) — list of locations in bin/retainer-config.sh
set -euo pipefail

log() { echo "$(date '+%Y-%m-%dT%H:%M:%S') $*"; }
is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
# mtime as epoch. ORDER MATTERS: GNU `stat -c %Y` first (on BSD it fails cleanly → empty stdout → fallback);
# BSD/macOS `stat -f %m` second (on GNU we never reach it, otherwise `-f`=--file-system would give garbage).
# `-e` (not `-f`!): .git is a DIRECTORY, stat gives its mtime (commit/index = sign of life). No path → 0.
mtime() { [ -e "$1" ] && { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; } || echo 0; }

# Clean reset of hung/ghost sessions and locks. Works even with the kill-switch.
if [ "${1:-}" = "--terminate" ]; then
  STATE="$HOME/.cache/retainer/conveyor"; n=0
  for lk in "$STATE"/*.lock; do
    [ -f "$lk" ] || continue
    pid="$(cat "$lk" 2>/dev/null || echo)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null && n=$((n + 1)); fi
    rm -f "$lk"
  done
  log "--terminate: sessions stopped=$n, locks removed"
  exit 0
fi

# Inertness is a state, not an event. It enters the trail ONCE, on change: otherwise a disabled
# conveyor writes the same line every five minutes, the trail is all noise, and a real error
# reads as one more of the same. Errors and work are logged as before.
INERT_MARK="$HOME/.cache/retainer/conveyor/last-inert"
log_inert() {
  local reason="$1" prev=""
  [ -f "$INERT_MARK" ] && prev="$(cat "$INERT_MARK" 2>/dev/null || echo)"
  [ "$prev" = "$reason" ] && return 0
  mkdir -p "$(dirname "$INERT_MARK")" 2>/dev/null || true
  printf '%s\n' "$reason" > "$INERT_MARK" 2>/dev/null || true
  log "$reason"
}
# Returning to work shows in the trail once — same principle as going inert.
clear_inert() {
  [ -f "$INERT_MARK" ] || return 0
  log "inert state cleared ($(cat "$INERT_MARK" 2>/dev/null || echo '?')) — conveyor working"
  rm -f "$INERT_MARK" 2>/dev/null || true
}

KILL="$HOME/.retainer/conveyor.off"
[ -f "$KILL" ] && { log_inert "disabled (kill-switch $KILL)"; exit 0; }

CONF="${CONVEYOR_CONF:-$HOME/.config/retainer/conveyor.conf}"
[ -f "$CONF" ] || { log_inert "no config $CONF — conveyor inert"; exit 0; }
# shellcheck source=/dev/null  # external user config (dynamic path) — deliberately not followed
source "$CONF"

REPOS="${REPOS:-}"
[ -z "$REPOS" ] && { log_inert "REPOS empty — nothing to poll"; exit 0; }
RESPAWN="${RESPAWN:-0}"
PROMPT="${PROMPT:-Continue the in-progress task per the retainer cycle.}"
RESPAWN_CMD="${RESPAWN_CMD:-claude -p \"\$PROMPT\"}"
MIN_RESPAWN_SEC="${MIN_RESPAWN_SEC:-1800}"
MAX_RESPAWNS="${MAX_RESPAWNS:-5}"
STUCK_AFTER="${STUCK_AFTER:-10800}"   # sec without a sign of life → session hung. Coarse last-resort watchdog: threshold ABOVE any legit pause (subagent chain/build)

# Anti-runaway gates must fail CLOSED. Bad number → do not spawn at all.
if ! is_uint "$MIN_RESPAWN_SEC"; then
  log "MIN_RESPAWN_SEC is not an integer ('$MIN_RESPAWN_SEC') — fail-closed, RESPAWN disabled"
  RESPAWN=0
fi
if ! is_uint "$MIN_RESPAWN_SEC" || [ "$MIN_RESPAWN_SEC" -lt 300 ]; then
  MIN_RESPAWN_SEC=300   # clamp from below: 0/small does not disable the debounce
fi
is_uint "$MAX_RESPAWNS" || MAX_RESPAWNS=5
is_uint "$STUCK_AFTER" || STUCK_AFTER=10800
[ "$STUCK_AFTER" -lt 3600 ] && STUCK_AFTER=3600   # clamp from below to 1h: a cycle subagent/build easily stays silent >10min; below an hour = false kills

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/retainer-config.sh
. "$HERE/retainer-config.sh"
TOKEN="$(retainer_token)"
[ -z "$TOKEN" ] && { log_inert "no token ($(retainer_token_places)) — conveyor inert"; exit 0; }
clear_inert                       # reached the work: inertness is over, shown once
API="${GITEA_URL:-http://localhost:3000}/api/v1"

STATE="$HOME/.cache/retainer/conveyor"; mkdir -p "$STATE"
PF="$HERE/retainer-preflight.sh"   # externalization preflight gate (sibling in bin/)

# Mutual exclusion for the whole run — atomic mkdir (macOS has no flock). Removed on exit.
LOCKD="$STATE/poll.lock.d"
if ! mkdir "$LOCKD" 2>/dev/null; then log "another conveyor run is already going — skip"; exit 0; fi
trap 'rmdir "$LOCKD" 2>/dev/null || true' EXIT

now="$(date +%s)"

for repo in $REPOS; do
  slug="$(printf '%s' "$repo" | tr -c 'A-Za-z0-9_' '_')"   # /,-,. → _ (otherwise DIR_<slug> is invalid)

  # in-progress tasks. --max-time against a hung Gitea; broken/non-JSON reply → 0, not a dead loop.
  json="$(curl -s --max-time 15 -H "Authorization: token $TOKEN" \
    "$API/repos/$repo/issues?state=open&labels=in-progress&type=issues&limit=50" || echo '')"
  cnt="$(J="$json" python3 -c '
import json, os
try:
    d = json.loads(os.environ["J"])
    print(len(d) if isinstance(d, list) else 0)
except Exception:
    print(0)')"

  if [ "$cnt" -eq 0 ]; then
    log "$repo: no in-progress — skip"
    rm -f "$STATE/$slug.attempts" "$STATE/$slug.escalated" "$STATE/$slug.recovery" "$STATE/$slug.preflight-blocked" 2>/dev/null || true   # work closed → reset counter+escalation+gate markers
    continue
  fi
  log "$repo: in-progress tasks = $cnt"

  # Slot state for this repo: finished / stuck / crashed / active.
  # finished (task closed, cnt==0) was already handled above by resetting counters. Here cnt>0 → inspect the lock.
  lock="$STATE/$slug.lock"
  if [ -f "$lock" ]; then
    lpid="$(cat "$lock" 2>/dev/null || echo)"
    if [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null; then
      # pid alive. Hung? Sign of life = the FRESHEST of: output (run.log), repo work (.git: commit/index),
      # spawn moment (.last). Take the max — any activity source resets the timer. run.log is weak on
      # read-only phases (a code-review subagent is silent on stdout for 10-20 min), so do NOT rely on it alone.
      dvar="DIR_$slug"; pdir="${!dvar:-}"
      spawn="$(cat "$STATE/$slug.last" 2>/dev/null || echo 0)"; is_uint "$spawn" || spawn=0
      ref=0
      for t in "$(mtime "$STATE/$slug.run.log")" "$(mtime "$pdir/.git")" "$spawn"; do
        is_uint "$t" && [ "$t" -gt "$ref" ] && ref="$t"
      done
      idle=$(( now - ref ))
      if [ "$ref" -gt 0 ] && [ "$idle" -ge "$STUCK_AFTER" ]; then
        # STUCK: live pid, but no source moved for ≥ STUCK_AFTER. Kill RELIABLY and remove the lock
        # ONLY once it is dead — otherwise we lose the pid and the next poll spawns ON TOP of a live orphan (double spawn).
        log "$repo: session pid $lpid HUNG (no signs of life ${idle}s ≥ ${STUCK_AFTER}s) — killing"
        kill -TERM "$lpid" 2>/dev/null || true
        dead=0
        for _ in 1 2 3; do sleep 1; kill -0 "$lpid" 2>/dev/null || { dead=1; break; }; done
        [ "$dead" -eq 0 ] && { kill -KILL "$lpid" 2>/dev/null || true; sleep 1; kill -0 "$lpid" 2>/dev/null || dead=1; }
        if [ "$dead" -eq 1 ]; then
          rm -f "$lock" 2>/dev/null || true
          : > "$STATE/$slug.recovery"   # STUCK-killed → crash recovery; marker (lock removed → next poll is fresh, but it is a recovery)
          log "$repo: hung pid $lpid terminated — slot freed (next poll respawns)"
        else
          log "$repo: pid $lpid did NOT die even after SIGKILL — LEAVING the lock (not spawning on top), operator must investigate"
        fi
        continue
      fi
      log "$repo: session alive and active (pid $lpid, silence ${idle}s < ${STUCK_AFTER}s) — not spawning another"
      continue
    fi
    # CRASHED: lock exists, pid dead/empty, task not closed (cnt>0). Clean the ghost lock, respawn below.
    log "$repo: previous session CRASHED (pid ${lpid:-?} dead, $cnt tasks still open) — cleaning lock, respawn below"
    rm -f "$lock" 2>/dev/null || true
    : > "$STATE/$slug.recovery"   # CRASHED → crash recovery; marker (the same poll respawns, read below)
  fi

  if [ "$RESPAWN" != "1" ]; then
    log "$repo: RESPAWN disabled → signal only (work exists, no live session). Set RESPAWN=1 in the config."
    continue
  fi

  # Attempt ceiling — do not burn API money forever on "hung but did not close the task".
  attempts="$(cat "$STATE/$slug.attempts" 2>/dev/null || echo 0)"; is_uint "$attempts" || attempts=0
  if [ "$attempts" -ge "$MAX_RESPAWNS" ]; then
    # not a SILENT stop but ESCALATION to the operator — signal ONCE (marker + notification).
    esc="$STATE/$slug.escalated"
    if [ ! -f "$esc" ]; then
      printf '%s repo=%s attempts=%s/%s — conveyor gave up, a human is needed\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S')" "$repo" "$attempts" "$MAX_RESPAWNS" > "$esc"
      # macOS notification is opt-in (NOTIFY=1 in the config), so as not to scare with a sudden popup. The marker is always written.
      [ "${NOTIFY:-0}" = "1" ] && command -v osascript >/dev/null 2>&1 && osascript -e \
        "display notification \"conveyor gave up on $repo ($attempts attempts) — needs investigation\" with title \"retainer\"" 2>/dev/null || true
      log "$repo: ceiling ($attempts/$MAX_RESPAWNS) — ESCALATION to operator (marker $esc; NOTIFY=1 for popup)"
    else
      log "$repo: ceiling ($attempts/$MAX_RESPAWNS) — already escalated, waiting for a human"
    fi
    continue
  fi

  # debounce
  last="$(cat "$STATE/$slug.last" 2>/dev/null || echo 0)"; is_uint "$last" || last=0
  if [ $((now - last)) -lt "$MIN_RESPAWN_SEC" ]; then
    log "$repo: respawned recently ($((now - last))s < ${MIN_RESPAWN_SEC}s) — waiting"
    continue
  fi

  # project directory
  dirvar="DIR_$slug"; projdir="${!dirvar:-}"
  if [ -z "$projdir" ] || [ ! -d "$projdir" ]; then
    log "$repo: no project directory ($dirvar) — cannot continue"
    continue
  fi

  # Pre-flight — is the respawn binary really in PATH? (launchd PATH is minimal → an honest refusal, not a false "started")
  bin0="${RESPAWN_CMD%% *}"
  if ! command -v "$bin0" >/dev/null 2>&1; then
    log "$repo: respawn binary '$bin0' NOT found (PATH=$PATH) — not launching. Give an ABSOLUTE path in RESPAWN_CMD."
    continue
  fi

  # Externalization preflight gate BEFORE spawn. HERE (after the binary pre-flight, BEFORE arming .last/attempts/lock) —
  # `continue` on fail does NOT burn an attempt and does NOT write a lock. recovery marker (STUCK/CRASHED) → --recovery (crash recovery:
  # context = issue + working tree, no manifest needed). Strictness comes from autonomy_level (preflight reads it itself).
  runlog="$STATE/$slug.run.log"                        # BEFORE preflight: otherwise >>"$runlog" under set -u is unbound
  if [ -f "$PF" ]; then   # -f (not -x): called via `bash "$PF"` — no exec bit needed, a file without +x would silently skip the gate
    recov=""; [ -f "$STATE/$slug.recovery" ] && { recov="--recovery"; rm -f "$STATE/$slug.recovery"; }
    if ! bash "$PF" "$projdir" "$repo" ${recov:+"$recov"} >> "$runlog" 2>&1; then
      pfb="$STATE/$slug.preflight-blocked"
      if [ ! -f "$pfb" ]; then
        # We do NOT name the cause ourselves: preflight has two hard-failure classes (manifest and
        # closed tasks with a working label), and "context not externalized" on the second sends the
        # owner to fix the wrong thing. What exactly failed is in $runlog, and we point there.
        printf '%s repo=%s — preflight blocked the spawn; reason in %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$repo" "$runlog" > "$pfb"
        [ "${NOTIFY:-0}" = "1" ] && command -v osascript >/dev/null 2>&1 && osascript -e \
          "display notification \"preflight blocked the spawn of $repo — reason in the report\" with title \"retainer\"" 2>/dev/null || true
        log "$repo: preflight BLOCKED the spawn — escalation (reason in $runlog; marker $pfb; NOTIFY=1 for popup)"
      else
        log "$repo: preflight blocked the spawn again — already escalated, waiting for the cause to be fixed"
      fi
      continue
    fi
    rm -f "$STATE/$slug.preflight-blocked" 2>/dev/null || true   # preflight ok → clear the block marker
  else
    log "$repo: preflight tool ($PF) missing — externalization gate skipped (old install?)"
  fi

  log "$repo: RESPAWNING headless in $projdir (attempt $((attempts + 1))/$MAX_RESPAWNS)"
  echo "$now" > "$STATE/$slug.last"                    # arm the rate limit BEFORE spawn (if it dies instantly we still wait)
  echo "$((attempts + 1))" > "$STATE/$slug.attempts"
  ( cd "$projdir" && PROMPT="$PROMPT" nohup bash -c "$RESPAWN_CMD" >> "$runlog" 2>&1 </dev/null & echo $! > "$lock" )
  log "$repo: started (pid $(cat "$lock" 2>/dev/null)), log $runlog"
done
log "cycle finished."
