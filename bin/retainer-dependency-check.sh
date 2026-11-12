#!/usr/bin/env bash
# retainer: dependency manifest against the lock file.
#
#   retainer-dependency-check.sh [project dir]
# exit 0 — agree · 1 — divergence · 2 — usage or THE CHECK DOES NOT WORK
#      3 — no targets: no manifest found in this root
#
# Editing the manifest is the only place where foreign code enters the project with no check at all.
# A package name may be invented by the model (and then someone has already registered it —
# slopsquat), a release may be a day old. Neither the gate nor the presets looked at this.
#
# THIS IS THE OFFLINE PART, and it is a boundary by design, not a half-measure: the gate must work
# without a network, and "no network" must not read as "dirty" — red on a plane without Wi-Fi stops
# being read. Package existence and release age need a network and run in CI, where one exists by definition.
#
# Offline exactly one thing is checked, but machine-checkable: EVERY name from the manifest is present
# in the lock file. A package added to the manifest and never installed is the commonest trace of
# both an invented name and a forgotten `uv lock`.
set -uo pipefail

DIR="${1:-.}"
[ -d "$DIR" ] || { echo "usage: retainer-dependency-check.sh [project dir]" >&2; exit 2; }
cd "$DIR" || exit 2

command -v python3 >/dev/null 2>&1 || {
  echo "✗ dependencies: no python3 — the check does NOT work" >&2; exit 2
}

# "manifest -> lock" pairs. The registry is explicit: silent support of a format absent from the
# list would mean a green summary where nothing was checked.
MANIFESTS="pyproject.toml:uv.lock requirements.txt:requirements.lock package.json:package-lock.json"

found=0
dirty=0
unlocked=0
for pair in $MANIFESTS; do
  manifest="${pair%%:*}"
  lock="${pair##*:}"
  [ -f "$manifest" ] || continue
  # No lock file — no target: a project may not pin at all. Demanding it here would solve a
  # DIFFERENT task for the project (build reproducibility), while this one is about whether what the
  # manifest names exists. The pair is simply not checked, and the summary says so.
  if [ ! -f "$lock" ]; then unlocked=$((unlocked + 1)); continue; fi
  found=$((found + 1))
  missing="$(MANIFEST="$manifest" LOCK="$lock" python3 -c '
import os
import re
import sys

# Names are taken ROUGHLY and on purpose: lines like `name`, `"name>=1.2"`, `name = "^1"`. An exact
# parse of three formats would be a third parser in the engine, while the check is not about manifest
# syntax but about whether what it names is installed at all. A false name from a comment is cheaper than a missed package.
NAME = re.compile(r"^[\s\"'\''-]*([A-Za-z][A-Za-z0-9._-]{1,60})")
SKIP = re.compile(r"^\s*[#\[]|^\s*$")
try:
    manifest = open(os.environ["MANIFEST"], encoding="utf-8").read().splitlines()
    lock = open(os.environ["LOCK"], encoding="utf-8").read().lower()
except OSError:
    sys.stderr.write("UNREADABLE\n")
    sys.exit(2)
seen = []
for line in manifest:
    if SKIP.match(line) or "=" in line.split(":")[0] and "==" not in line:
        continue
    hit = NAME.match(line)
    if not hit:
        continue
    name = hit.group(1).lower()
    if name in {"name", "version", "description", "requires", "dependencies", "true", "false"}:
        continue
    if name not in lock and name.replace("_", "-") not in lock:
        seen.append(hit.group(1))
print("\n".join(sorted(set(seen))))
')"
  rc=$?
  if [ "$rc" != 0 ]; then
    echo "✗ dependencies: parsing $manifest failed — the check does NOT work" >&2
    exit 2
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf '  ✗ %s: «%s» is named in the manifest and absent from %s\n' "$manifest" "$name" "$lock"
    dirty=$((dirty + 1))
  done <<EOF
$missing
EOF
done

if [ "$found" -eq 0 ]; then
  # Two kinds of "nothing" are told apart: no manifest at all, and a manifest without a lock. The
  # second is not a finding (see above), but not silence either: the summary must say WHAT was not checked.
  if [ "$unlocked" -gt 0 ]; then
    printf '▶ dependencies: manifests without a lock — %s, nothing to compare against\n' "$unlocked"
  else
    echo "▶ dependencies: no manifest in this root — nothing to check"
  fi
  exit 3
fi
if [ "$dirty" -eq 0 ]; then
  printf '▶ dependencies: manifest and lock agree (checked %s · without a lock %s)\n' "$found" "$unlocked"
  exit 0
fi
printf '✗ manifest/lock divergences: %s. A package named and not installed is either\n' "$dirty" >&2
printf '  an invented name (someone has already registered it for themselves) or a forgotten lock rebuild.\n' >&2
printf '  Package existence and release age are checked by CI: there is no network here by design.\n' >&2
exit 1
