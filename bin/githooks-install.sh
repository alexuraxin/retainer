#!/usr/bin/env bash
# Activates the engine's commit-time gate on its OWN code: wires the versioned .githooks/ through
# core.hooksPath. Idempotent. Mirrors the MECHANISM retainer-new.sh uses to install the gate in
# managed projects (`git config core.hooksPath .githooks`); the engine's hook set is its own
# (pre-commit=box subset, pre-push=full suite on main, none on a branch), so the wiring is mirrored, not
# the hook list.
#
# core.hooksPath is LOCAL config (not committed) -> every clone/machine activates it with this script.
# Run once after cloning.
#
#   bin/githooks-install.sh          # activate the engine hooks
#   bin/githooks-install.sh --check  # verify activation (exit!=0 if inactive) — for test_githooks.sh
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ not a git repository" >&2; exit 1; }
cd "$ROOT"
WANT=".githooks"

if [ "${1:-}" = "--check" ]; then
  have="$(git config --get core.hooksPath || true)"
  [ -n "$have" ] || { echo "✗ core.hooksPath is not set — run bin/githooks-install.sh" >&2; exit 1; }
  # git resolves a relative core.hooksPath from the tree root and takes an absolute one as is. Accept
  # ANY form pointing at the same directory (.githooks / ./.githooks / /abs/.../.githooks): compare by
  # inode (-ef), not by string, so an absolute-path activation still counts as active.
  case "$have" in /*) have_abs="$have";; *) have_abs="$ROOT/$have";; esac
  if [ "$have_abs" -ef "$ROOT/$WANT" ]; then
    echo "✓ core.hooksPath → $WANT (engine hooks active)"
    exit 0
  fi
  echo "✗ core.hooksPath='$have' does not point at $WANT — run bin/githooks-install.sh" >&2
  exit 1
fi

[ -d "$WANT" ] || { echo "✗ directory $WANT is missing — the repo has no engine hooks" >&2; exit 1; }
chmod +x "$WANT"/*
git config core.hooksPath "$WANT"
echo "✓ core.hooksPath=$WANT — engine hooks active (pre-commit=box subset, pre-push=full suite on main, none on a branch)"
echo "  bypass if needed: git commit/push --no-verify"
