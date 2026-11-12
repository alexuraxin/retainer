#!/usr/bin/env bash
# retainer: duplicate cycle role between project and engine.
# The canon is the engine's: a project role is legitimate only where the engine has no such role at all.
#
#   retainer-agent-canon.sh [project dir]
# exit 0 — no collisions · 1 — collisions · 2 — usage or the check is not working · 3 — no targets.
set -uo pipefail
ENGINE_AGENTS="$(cd "$(dirname "$0")/.." && pwd)/agents"

DIR="${1:-.}"
[ -d "$DIR" ] || { echo "usage: retainer-agent-canon.sh [project dir]" >&2; exit 2; }
cd "$DIR" || exit 2

PROJ_AGENTS=".claude/agents"
if [ ! -d "$PROJ_AGENTS" ]; then
  echo "▶ agent canon: the project has no roles of its own — no collisions possible"
  exit 3
fi
if [ ! -d "$ENGINE_AGENTS" ]; then
  # Engine not connected: nothing to compare against. Must not stay silent — "check not working" is not "clean".
  echo "  (engine roles dir not found: $ENGINE_AGENTS — nothing to compare against, skipped)"
  exit 2
fi

clash=0
own=0
for path in "$PROJ_AGENTS"/*.md; do
  [ -e "$path" ] || continue
  name="$(basename "$path")"
  if [ -e "$ENGINE_AGENTS/$name" ]; then
    clash=$((clash + 1))
    printf '  ✗ role «%s» exists in both the project and the engine — which one gets called is not decided by config\n' "${name%.md}"
    printf '      project: %s lines · engine: %s lines\n' \
      "$(wc -l < "$path" | tr -d ' ')" "$(wc -l < "$ENGINE_AGENTS/$name" | tr -d ' ')"
  else
    own=$((own + 1))
  fi
done

if [ "$clash" -eq 0 ] && [ "$own" -eq 0 ]; then
  # The roles dir exists but holds no roles: the role was deleted, the dir remained. Zero targets — saying
  # "clean" would report success of a check that never ran.
  echo "▶ agent canon: roles dir is empty — nothing to compare"
  exit 3
fi
if [ "$clash" -eq 0 ]; then
  printf '▶ agent canon: no collisions (project own roles: %s)\n' "$own"
  exit 0
fi
cat >&2 <<EOF
✗ role-name collisions: $clash. The canon is the engine's: a project copy of a cycle role adds no
  specifics beyond what PROJECT.md gives, but makes role selection unmanageable.
  What to do: move the project differences into PROJECT.md and delete the role copy from the project.
  Editing the project roles dir is done by the OWNER — it is off-limits to the agent.
EOF
exit 1
