#!/usr/bin/env bash
# retainer: does the managed-projects registry match the disk.
#
#   retainer-registry-check.sh [search root ...]
# exit 0 — matches · 1 — discrepancies found · 2 — usage or registry unreadable
#
# A project's managed status is asserted by TWO independent sources: the registry
# `~/.config/retainer/managed-repos` (sweeps go by it — digest, step preflight, this check) and the
# `.retainer/` marker on disk (the kit check and the guard itself work by it, climbing to the config
# from the edited path). They diverge silently: a project with `.retainer/` outside the registry is
# in no sweep, and a registry path without `.retainer/` sends a sweep into a directory with no rules.
#
# The sides of a discrepancy DIFFER and the fix differs — `retainer-register.sh add` versus deleting
# a line — so they are printed separately.
#
# THE RULE ON THE KIT AND STANDS IS WRITTEN DOWN, not implied: a tree that is itself a kit (holds
# `.claude-plugin/plugin.json`) does not count as a managed project. This covers the engine's live
# tree, the stands (`retainer-stand*`) and any clone of them: they have `.retainer/` because the
# engine guards itself, but there is nothing to roll a kit out into a kit.
set -uo pipefail

REG="${RETAINER_MANAGED_REPOS:-$HOME/.config/retainer/managed-repos}"
[ -f "$REG" ] || {
  echo "✗ registry check: no registry ($REG) — nothing to compare against" >&2; exit 2; }

# Search roots: arguments or the home directory. Depth is limited deliberately — the subject here is
# "a project next to other projects", not a full disk walk, which would run into Library and caches.
ROOTS="${*:-$HOME}"
DEPTH="${RETAINER_SCAN_DEPTH:-3}"

registry_paths=""
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  registry_paths="$registry_paths$line
"
done < "$REG"

found=0
say(){ printf '✗ %s\n' "$1"; found=$((found + 1)); }

# ── side 1: a path in the registry with no project there ──────────────────────────────
# Findings accumulate PER LINE, not per word: the discrepancy reason is text with spaces, and
# iterating an unquoted list would tear it into separate "paths".
gone=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if [ ! -d "$path" ]; then
    gone="$gone$path — no such directory
"
  elif [ ! -f "$path/.retainer/config.toml" ]; then
    gone="$gone$path — no .retainer/config.toml
"
  fi
done <<EOF
$registry_paths
EOF

# ── side 2: a project on disk that is not in the registry ────────────────────────
# Search dump directories are skipped, not projects: managed trees are not kept under them, and
# walking them costs minutes.
orphan=""
for root in $ROOTS; do
  [ -d "$root" ] || continue
  while IFS= read -r cfg; do
    [ -n "$cfg" ] || continue
    proj="$(cd "$(dirname "$(dirname "$cfg")")" && pwd)"
    [ -f "$proj/.claude-plugin/plugin.json" ] && continue   # this is the kit itself, not a project under it
    case "
$registry_paths" in *"
$proj
"*) continue ;; esac
    case "
$orphan" in *"
$proj
"*) continue ;; esac
    orphan="$orphan$proj
"
  done <<EOF
$(find "$root" -maxdepth "$DEPTH" \
    \( -name Library -o -name .Trash -o -name node_modules -o -name .venv -o -name .git \) -prune -o \
    -path '*/.retainer/config.toml' -print 2>/dev/null)
EOF
done

if [ -n "$gone" ]; then
  say "in the registry, but no managed project there:"
  printf '%s' "$gone" | while IFS= read -r item; do
    [ -n "$item" ] && printf '    %s\n' "$item"
  done
  printf '  A sweep will enter a tree with no rules. Fix: bash bin/retainer-register.sh remove <path>\n'
fi
if [ -n "$orphan" ]; then
  say "project on disk is managed but not in the registry — sweeps do not see it:"
  printf '%s' "$orphan" | while IFS= read -r item; do
    [ -n "$item" ] && printf '    %s\n' "$item"
  done
  printf '  Neither the digest nor a step run opens it. Fix: bash bin/retainer-register.sh add <path>\n'
fi

[ "$found" = 0 ] || exit 1
echo "✔ managed-projects registry matches the disk (the kit and its stands do not count)"
