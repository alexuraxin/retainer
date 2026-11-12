#!/usr/bin/env bash
# retainer: what code prose SAYS -- a comment or docstring states behaviour, not the history of the code.
#
#   retainer-prose-content.sh [project dir]
# exit 0 -- no narrative in the lines a change adds · 1 -- findings · 2 -- usage or the check does
#      not work · 3 -- nothing to judge: not a git repository, no base, no added code lines.
#
# On in every project, like a linter: no key turns it off. Its targets are the lines a change adds,
# so the existing corpus of comments is never its subject. The finder, the targets and the
# `retainer:allow-prose` mark are shared with the language step (`--content` mode).
# complexity: keep, step 2 — the gate passes a step only a directory, so the mode needs its own script
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# The shared script refuses a missing directory itself (exit 2).
exec bash "$HERE/retainer-prose-lang.sh" --content "${1:-.}"
