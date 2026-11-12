#!/usr/bin/env bash
# retainer: credentials embedded in a remote repository URL.
#
#   retainer-remote-creds.sh [project dir]
# exit 0 — clean · 1 — a remote with credentials exists · 2 — usage or THE CHECK IS NOT WORKING
#      3 — no targets: the dir is not a git repository or no remote is defined at all
#
# The engine forbids exactly this to ITSELF and did not look at the projects it hands discipline to. A refusal on the
# `://…@…` sign is written and works in `bin/retainer-publish.sh` — but only for its own publishing remote.
# In a managed project the tracker admin token lay in plain text in `.git/config`, embedded in the URL, and nobody saw it.
#
# A FOUND VALUE IS NOT PRINTED. The check is about a secret leak; printing the secret into the gate log, the CI log
# and agent output would multiply it with the very tool that complains about it.
# The remote name and the sign are printed — enough to fix it.
set -uo pipefail

DIR="${1:-.}"
[ -d "$DIR" ] || { echo "usage: retainer-remote-creds.sh [project dir]" >&2; exit 2; }
cd "$DIR" || exit 2

command -v git >/dev/null 2>&1 || {
  echo "✗ credentials in remote: no git — the check is NOT working" >&2; exit 2
}
git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "▶ credentials in remote: not a git repository — nothing to check"; exit 3
}

# `git remote -v` gives two lines per remote (fetch/push) — count NAMES, not lines, otherwise
# the same address would be reported as a finding twice.
remotes="$(git remote 2>/dev/null)"
[ -n "$remotes" ] || { echo "▶ credentials in remote: no remote defined — nothing to check"; exit 3; }

found=0
checked=0
for name in $remotes; do
  url="$(git remote get-url "$name" 2>/dev/null)" || continue
  checked=$((checked + 1))
  case "$url" in
    # Local forms: a file path and `file://` have no credentials, and in tests and
    # mirrors they are legitimate. Cut off BEFORE parsing, otherwise a path with `@` in a dir name would become a finding.
    file://*|/*|.*|~*) continue ;;
  esac
  # Credentials are an `@` in the address AUTHORITY, i.e. between `://` and the first following `/`.
  # Later in the path `@` is legitimate (branch `refs/@`, a `user@host` dir in an SSH-like notation).
  case "$url" in
    *://*)
      authority="${url#*://}"
      authority="${authority%%/*}"
      case "$authority" in
        *@*)
          found=$((found + 1))
          printf '  ✗ remote «%s»: credentials embedded in the URL (value not printed)\n' "$name"
          ;;
      esac
      ;;
  esac
done

if [ "$found" -eq 0 ]; then
  printf '▶ credentials in remote: clean (remotes checked: %s)\n' "$checked"
  exit 0
fi
printf '✗ remotes with credentials: %s. The token in .git/config is readable by anyone who reached the tree,\n' "$found" >&2
printf '  and it survives a change of permissions: neither logout nor rotation of the agent key will revoke it.\n' >&2
printf '  Fix: git remote set-url <name> <address without credentials>, the token — from a storage file.\n' >&2
exit 1
