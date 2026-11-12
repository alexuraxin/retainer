#!/usr/bin/env bash
# retainer: which tests CI runs for these changes.
#
#   retainer-ci-scope.sh <event> <branch> [changed-files…]
# Prints one test file per line. exit 0 — list printed · 2 — usage · 3 — run NO suite: the push carries
# a tree its pull request already tested (see SKIP below); nothing is printed.
#
# Selection by changes already exists in the engine — `hooks/stop_gate.py`, at turn end. It cannot
# be reused in CI as is: it is deliberately coarse and by construction cannot see cross-cutting
# tests. A change to `bin/retainer-gate-steps.sh` pulls `test_gate_steps.sh` but not
# `test_rigor_registry.sh`, which depends on the same file. So GUARANTEE and early catch are split.
#
# TIERS:
#   pull_request_ci — the pull request in CI: the FULL suite, the one full run a change pays for.
#   pull_request    — the local tier (`bin/retainer-suite.sh` run with no arguments): selected by
#                     changes PLUS the cross-cutting minimum. The engine's branch pre-push runs no tests.
#   push to main    — no suite when the merge provably carries its pull request's tested tree
#                     (exit 3); the full suite otherwise.
#   other           — full suite: an unknown event must not be able to silently narrow the check.
# A RELEASE diff selects the release set in both pull-request tiers, before any per-file rule.
set -uo pipefail

[ "$#" -gt 0 ] || { echo "usage: retainer-ci-scope.sh <event> <branch> [files…]" >&2; exit 2; }
EVENT="${1:-}"
REF="${2:-}"
shift 2 2>/dev/null || shift $#

cd "$(dirname "$0")/.." || exit 2
[ -d tests ] || { echo "retainer-ci-scope: no tests directory — nothing to select from" >&2; exit 2; }

all_tests() {
  for path in tests/test_*.sh; do
    [ -f "$path" ] && printf '%s\n' "$path"
  done
}

# CROSS-CUTTING MINIMUM — not a list here but a MARKER IN THE TEST ITSELF. These are tests whose INPUT
# is the whole tree: registry cross-checks, publishability, lints, document gates. Selection by name
# cannot see them because they have no "own" source file.
#
# A hand-kept list lags behind new scanners: a registry in another file diverges from its subject
# silently. So a test declares itself with a `# end-to-end: <reason>` line in its header, and
# `tests/test_ci_scope.sh` holds the other side — every test that reads the tree carries the marker.
CROSSCUT="$(grep -l '^# end-to-end:' tests/test_*.sh 2>/dev/null)"

# RELEASE — recognised by the same composition the merge lock uses (`bin/retainer-merge-ready.sh`,
# `RELEASE_PATH_RE` and its three signs): only the journal, the two manifests and legible fragments;
# the journal and `plugin.json` both present; a fragment deleted, i.e. named in the diff and absent
# from the tree. A hand edit of a manifest or a journal alone is not a release: `.claude-plugin/` is
# where the distribution `source` lives. The regex is a copy, held equal to the lock's by a case in
# tests/test_ci_scope.sh. Checked BEFORE the per-file loop: the manifest rule there selects all.
RELEASE_PATH_RE='^(CHANGELOG\.md|\.claude-plugin/(plugin|marketplace)\.json|docs/changelog\.d/(README\.md|[0-9]+\.(fix|feat)\.md))$'
RELEASE_SET="tests/test_release.sh tests/test_release_preflight.sh tests/test_plugin_version_sync.sh
tests/test_changelog_pointers.sh tests/test_marketplace_installable.sh"
is_release() {
  local f journal=0 manifest=0 dropped=0
  for f in "$@"; do
    [[ "$f" =~ $RELEASE_PATH_RE ]] || return
    case "$f" in
      CHANGELOG.md) journal=1 ;;
      .claude-plugin/plugin.json) manifest=1 ;;
      docs/changelog.d/README.md) ;;
      docs/changelog.d/*) [ -e "$f" ] || dropped=1 ;;
    esac
  done
  [ "$journal" = 1 ] && [ "$manifest" = 1 ] && [ "$dropped" = 1 ]
}

# SKIP — a push whose HEAD is a two-parent merge, whose tree is its second parent's tree, and whose
# first parent is an ancestor of the second. Then the pull request head already contained the base,
# its trial merge changed nothing, and the required gate ran on exactly this tree; branch protection
# (`block_on_outdated_branch`, a required gate context) would not have let it merge otherwise. Read
# from the graph, nothing is recorded. A squash, a rebase, a fast-forward, an octopus or a history too
# shallow to answer is not this shape, and runs the full suite. A rebase-THEN-merge IS this shape while
# its second parent is a rebased commit nobody tested — so the graph is necessary, not sufficient: the
# workflow skips only when the required gate is green on that second parent.
merge_carries_tested_tree() {
  local first second
  first="$(git rev-parse -q --verify 'HEAD^1^{commit}' 2>/dev/null)" || return 1
  second="$(git rev-parse -q --verify 'HEAD^2^{commit}' 2>/dev/null)" || return 1
  git rev-parse -q --verify 'HEAD^3^{commit}' >/dev/null 2>&1 && return 1
  [ "$(git rev-parse 'HEAD^{tree}')" = "$(git rev-parse "$second^{tree}")" ] || return
  git merge-base --is-ancestor "$first" "$second" 2>/dev/null
}

case "$EVENT:$REF" in
  pull_request:*|pull_request_ci:*)
    if is_release "$@"; then
      for path in $RELEASE_SET; do [ -f "$path" ] && printf '%s\n' "$path"; done
      exit 0
    fi ;;
esac

case "$EVENT:$REF" in
  pull_request:*) ;;
  push:*)
    merge_carries_tested_tree && exit 3
    all_tests; exit 0 ;;
  # pull_request_ci and anything unrecognised: the full suite.
  *) all_tests; exit 0 ;;
esac

# No changes named — nothing to narrow on. Full suite: an empty change list means "unknown",
# not "nothing changed".
[ "$#" -gt 0 ] || { all_tests; exit 0; }

selected=""
add() {
  case " $selected " in *" $1 "*) return 0 ;; esac
  [ -f "$1" ] && selected="$selected $1"
}

for changed in "$@"; do
  case "$changed" in
    # Journals: each one's entry form has its own gate, and the generic document rule below would drop
    # them with the rest. Selection, not cross-cutting minimum: the minimum runs on every PR, while these
    # files change in few tasks. Each journal → gate pair is named explicitly because the test name does
    # not match the file name; one gate for both would swap the subject — each reads exactly its own
    # file and asserts nothing about the other.
    docs/ERROR-JOURNAL.md)     add "tests/test_error_journal.sh"; continue ;;
    docs/DEVIATION-JOURNAL.md) add "tests/test_deviation_journal.sh"; continue ;;
    # These two carry the tracker-boundary statement, which a case asserts; without this line a
    # re-wording of either selects nothing and the assertion sleeps until a full pass.
    README.md|ONBOARDING.md)   add "tests/test_preset_examples.sh"; continue ;;
    # A document pulls no code tests of its own — the document gates of the cross-cutting minimum cover it.
    *.md) continue ;;
    # Changing a test pulls exactly that test.
    tests/test_*.sh) add "$changed"; continue ;;
    # The DOM fixture is shared by the scenario sets of BOTH layers of the settings page, and the page
    # carries no test of its own name. The generic rule below would look for tests/test_pult_dom.sh
    # and tests/test_retainer_settings.sh, find the launcher's test instead of the page's, and the
    # page's behaviour would reach main judged by no one.
    tests/fixtures/pult-dom.js|docs/settings-page/*.html)
      add "tests/test_settings_page_behavior.sh"; add "tests/test_rigor_page_behavior.sh"
      add "tests/test_rigor_registry.sh"; add "tests/test_settings_page.sh"; continue ;;
    # Hook wiring: the file name matches no test, and the generic "name → tests/test_<name>" rule
    # silently falls to a nonexistent path. The tests guarding it are named here, and the list grows
    # with the number of wired hooks: a hook not named here has its wiring unchecked.
    hooks/hooks.json)
      add "tests/test_stop_gate.sh"; add "tests/test_guard_wiring.sh"
      add "tests/test_write_advice.sh"; add "tests/test_session_context.sh"
      add "tests/test_box_smoke.sh"; continue ;;
    # The launcher every hook runs through: its cases live with the installer, and the box smoke runs
    # each declared hook through it.
    hooks/retainer-python)
      add "tests/test_install.sh"; add "tests/test_box_smoke.sh"; continue ;;
    # The settings server's key module: its cases run against the server that imports it.
    bin/settings_key.py)
      add "tests/test_settings_server.sh"; continue ;;
    # The second-opinion reader: no corpus of its own name; its cases live with the MCP wrapper, the
    # untrusted-output frame and the settings server that writes the key it reads.
    bin/second_opinion.py)
      add "tests/test_mcp.sh"; add "tests/test_untrusted.sh"; add "tests/test_settings_server.sh"; continue ;;
    # Shipped project-context table: the base `context` leads to a nonexistent tests/test_context.sh,
    # so the generic rule silently pulls NOTHING. It has three readers — both feed hooks and the gate
    # step that reads the same table through the library bundle.
    hooks/context.rules)
      add "tests/test_session_context.sh"; add "tests/test_write_advice.sh"
      add "tests/test_hot_context.sh"; continue ;;
    # The two hooks that carry the route: the generic rule leads each to its own corpus and never to
    # the route's, while the route is a seam inside both — the hint in one, the hint and the
    # standstill judge in the other.
    hooks/stop_gate.py)
      add "tests/test_stop_gate.sh"; add "tests/test_route.sh"; continue ;;
    hooks/session_context.py)
      add "tests/test_session_context.sh"; add "tests/test_route.sh"; continue ;;
    # Project-context library: its own corpus is thin — it is the shared parse for three readers, and
    # a change in it alters each one's verdict. That is the price of reuse, paid here rather than as a
    # finding on main.
    hooks/project_context.py|hooks/project_doc.py)
      add "tests/test_project_context.sh"; add "tests/test_session_context.sh"
      add "tests/test_write_advice.sh"; add "tests/test_hot_context.sh"; continue ;;
    # The search-hint branch of the write advisor: its cases live in the advisor's corpus.
    hooks/search_advice.py)
      add "tests/test_write_advice.sh"; continue ;;
    # Shared seam "where the kit lives": it has no corpus of its own, cases live with the callers. The
    # generic rule would lead to a nonexistent tests/test_dist_subdir.sh and pull nothing, while a
    # contract change alters the verdict of both callers — the showcase build and the version gate.
    bin/retainer-dist-subdir.sh)
      add "tests/test_marketplace_installable.sh"; add "tests/test_make_public.sh"
      add "tests/test_retainer_publish.sh"; continue ;;
  esac
  base="${changed##*/}"
  base="${base%.*}"
  base="${base#retainer-}"
  base="${base#retainer_}"
  add "tests/test_${base//-/_}.sh"
  # CI wiring, runner config and the plugin manifest change run conditions for ALL — narrowing is
  # not allowed here, and it is cheaper to sort out here than to catch as red on main later.
  case "$changed" in
    .gitea/*|.claude-plugin/*|presets/ci/*|bin/retainer-suite.sh) all_tests; exit 0 ;;
  esac
done

for keep in $CROSSCUT; do
  add "$keep"
done

# Output order follows `tests/test_*.sh` so the log reads the same under any selection.
for path in $(all_tests); do
  case " $selected " in *" $path "*) printf '%s\n' "$path" ;; esac
done
