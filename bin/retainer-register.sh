#!/usr/bin/env bash
# retainer: registry of managed projects (~/.config/retainer/managed-repos): add/list/remove BY SCRIPT, not by hand.
# The registry is an allowlist: the console writes [rigor] only into projects listed here, and the
# managed-project sweeps (digest, registry-vs-disk reconcile) walk it. The guard does not read its content.
#   retainer-register.sh add <path>     -- add (idempotent; path -> absolute; the directory must exist)
#   retainer-register.sh list           -- show the registry (one absolute path per line)
#   retainer-register.sh remove <path>  -- remove (works for an already deleted directory too)
# Test seam: $RETAINER_MANAGED_REPOS (path to the registry file).
set -euo pipefail

REG="${RETAINER_MANAGED_REPOS:-$HOME/.config/retainer/managed-repos}"
usage() { echo "usage: retainer-register.sh <add|list|remove> [path]" >&2; }

# absolute directory path (canonical dir, symlinks not resolved); empty + nonzero if the directory is missing
abspath() { ( cd "$1" 2>/dev/null && pwd ); }

cmd="${1:-}"
case "$cmd" in
  list)
    [ -f "$REG" ] && cat "$REG" || true
    ;;
  add)
    p="${2:-}"; [ -n "$p" ] || { echo "path required" >&2; usage; exit 2; }
    ap="$(abspath "$p")" || true
    [ -n "$ap" ] || { echo "no such directory: $p" >&2; exit 2; }
    mkdir -p "$(dirname "$REG")"; touch "$REG"
    if grep -qxF "$ap" "$REG"; then
      echo "already in registry: $ap"
    else
      printf '%s\n' "$ap" >> "$REG"; echo "added: $ap"
    fi
    ;;
  remove)
    p="${2:-}"; [ -n "$p" ] || { echo "path required" >&2; usage; exit 2; }
    ap="$(abspath "$p")" || true
    [ -n "$ap" ] || ap="$p"   # directory already deleted -- remove by the given path as is
    [ -f "$REG" ] || { echo "registry empty"; exit 0; }
    grep -vxF "$ap" "$REG" > "$REG.tmp" 2>/dev/null || true
    mv "$REG.tmp" "$REG"
    echo "removed (if present): $ap"
    ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
