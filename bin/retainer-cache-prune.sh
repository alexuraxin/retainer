#!/usr/bin/env bash
# retainer: remove old plugin versions from the harness cache.
#
#   retainer-cache-prune.sh [how many versions to keep]   # default 2
#   retainer-cache-prune.sh --dry-run [how many]          # show only
# exit 0 — removed, or nothing to remove · 2 — usage / no cache
#
# The marketplace installs a plugin as a COPY of the tree into `~/.claude/plugins/cache/<market>/<plugin>/<version>`
# and does not delete the previous ones, so copies pile up without limit. We keep TWO —
# the current and the previous: the previous is needed to roll back when a release turns out bad, and a third
# answers nothing anymore.
#
# THE INSTALLED VERSION IS NEVER REMOVED, even if by count it is past the threshold: deleting the tree
# the installed-plugins registry points to disables the guard on a live machine.
set -uo pipefail

CACHE="${RETAINER_PLUGIN_CACHE:-$HOME/.claude/plugins/cache}"
INSTALLED="${RETAINER_INSTALLED_PLUGINS:-$HOME/.claude/plugins/installed_plugins.json}"
KEEP=2
DRY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    ''|*[!0-9]*) echo "usage: retainer-cache-prune.sh [--dry-run] [how many versions to keep]" >&2; exit 2 ;;
    *) KEEP="$arg" ;;
  esac
done
[ "$KEEP" -ge 1 ] 2>/dev/null || { echo "usage: at least one version must be kept" >&2; exit 2; }
[ -d "$CACHE" ] || { echo "▶ cache prune: no cache ($CACHE) — nothing to remove"; exit 0; }

# Versions the installed registry points to: these must not be touched.
pinned=""
[ -f "$INSTALLED" ] && pinned="$(python3 - "$INSTALLED" <<'PY' 2>/dev/null || true
import json,sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for entries in (data.get("plugins") or {}).values():
    for e in entries if isinstance(entries, list) else [entries]:
        path = (e or {}).get("installPath")
        if path:
            print(path)
PY
)"

freed=0
removed=0
for plugdir in "$CACHE"/*/*; do
  [ -d "$plugdir" ] || continue
  # Versions sort as versions, not as strings: `0.57.10` is lexically smaller than `0.57.9`, and
  # a plain sort would delete the fresh one.
  versions="$(ls -1 "$plugdir" 2>/dev/null | sort -V)"
  total="$(printf '%s\n' "$versions" | sed '/^$/d' | wc -l | tr -d ' ')"
  [ "$total" -gt "$KEEP" ] || continue
  drop="$(printf '%s\n' "$versions" | sed '/^$/d' | head -n "$((total - KEEP))")"
  while IFS= read -r ver; do
    [ -n "$ver" ] || continue
    target="$plugdir/$ver"
    case "
$pinned" in *"
$target"*)
      printf '  ▸ %s — installed version, leaving it\n' "$target"
      continue ;;
    esac
    size="$(du -sk "$target" 2>/dev/null | cut -f1)"
    freed=$((freed + ${size:-0}))
    removed=$((removed + 1))
    if [ "$DRY" = 1 ]; then
      printf '  ▸ would remove %s (%s MB)\n' "$target" "$(( ${size:-0} / 1024 ))"
    else
      rm -rf "$target"
      printf '  ▸ removed %s (%s MB)\n' "$target" "$(( ${size:-0} / 1024 ))"
    fi
  done <<EOF
$drop
EOF
done

if [ "$removed" = 0 ]; then
  printf '✔ cache prune: no extra versions (keeping %s)\n' "$KEEP"
else
  printf '✔ cache prune: %s versions, %s MB (keeping %s)\n' "$removed" "$(( freed / 1024 ))" "$KEEP"
fi
