#!/usr/bin/env bash
# retainer: gate step wrapper over the skills catalog generator.
#
#   retainer-skills-catalog.sh [project dir]
# exit 0 -- catalog converges · 1 -- diverged · 2 -- THE CHECK DOES NOT WORK · 3 -- no targets
#
# The engine step registry calls an `.sh` with one directory argument; the generator is Python with
# its own flag contract. The wrapper reconciles the two and writes NOTHING: a gate step that edits
# the tree turns a check into auto-fix and red into a quiet "already fixed it".
#
# A project without `skills/` has no targets -- code 3, not clean: the summary has no right to go
# green where it checked nothing.
set -uo pipefail
GEN="$(cd "$(dirname "$0")" && pwd)/retainer_skills_catalog.py"

DIR="${1:-.}"
[ -d "$DIR" ] || { echo "usage: retainer-skills-catalog.sh [project dir]" >&2; exit 2; }
cd "$DIR" || exit 2

[ -f "$GEN" ] || { echo "✗ skills catalog: generator missing next to the script -- the check does NOT work" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "✗ skills catalog: no python3 -- the check does NOT work" >&2; exit 2; }

out="$(python3 "$GEN" --check . 2>&1)"; rc=$?
printf '%s\n' "$out"
exit "$rc"
