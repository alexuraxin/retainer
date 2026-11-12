#!/usr/bin/env bash
# retainer: gitea-flow -- resolver of the policy of ONE flow step (skill gitea-flow).
# Prints the effective step policy: auto | ask | off.
#   auto -- the agent does the step itself · ask -- propose and wait for the owner's "ok" · off -- does not do it (manual/skip).
# Source: flow_<step> from the global config (a per-step override -- "each cycle is governed separately");
# unset or invalid -> the default from autonomy_level (matrix below). A single source of truth for the
# defaults -- otherwise the agent computes them inconsistently (issue-last instead of issue-first).
#
#   retainer-flow-policy.sh <issue|branch|commit|pr|merge|cleanup|ask_owner|confirm_intake>
#   retainer-flow-policy.sh level   -- the autonomy level this resolver applies, after normalisation
# exit 0 = policy printed; exit 2 = unknown step (usage).
# `level` is not a step: it stays outside the `<...>` list, which readers parse as the step contract.
#
# Step ask_owner is NOT a git step: it is a gate "may work be stopped by a question to the owner".
# It is owned by the task-cycle skill; gitea-flow still has six steps. Two values:
#   auto -- a blocking question is allowed · off -- forbidden; the fork goes into an `open-question`
#   issue with a recorded default, and work continues on the default.
# `ask` is meaningless for it ("ask permission to ask") -> invalid, falls back to the level default.
#
# Step confirm_intake is also not a git step and a SEPARATE gate, not a mode of ask_owner. The split
# is the point: a question about a FORK INSIDE a task and a question about the TASK BOUNDARY cost
# differently. A wrong default inside a task is fixed by the next step; a misread boundary is fixed by
# nothing -- the wrong work is done entirely (live case: "prepare one" read as a portion of work
# instead of a list of tasks, three hours in the wrong direction). Hence marathon switches off
# ask_owner and does NOT switch off confirm_intake: confirmation is a line or two BEFORE the start,
# not a run stopped at a fork.
#   auto -- briefly write HOW the task was understood and wait for "ok" · off -- start at once.
# `ask` is meaningless here too ("ask permission to confirm") -> invalid, falls back to the level default.
#
# Level marathon -- a long autonomous run: work stops at NO step, including merge, and questions
# are forbidden. The earlier rule "merge is always owner-gated, the harness auto-classifier cuts the
# agent" was lifted by the owner ("the agent merges"). On the other levels merge stays off and is
# enabled only by an explicit flow_merge.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=bin/retainer-config.sh
. "$ROOT/bin/retainer-config.sh"   # retainer_cfg -- global retainer config

STEP="${1:-}"
case "$STEP" in
  issue|branch|commit|pr|merge|cleanup|ask_owner|confirm_intake|level) ;;
  *) { echo "usage: retainer-flow-policy.sh <issue|branch|commit|pr|merge|cleanup|ask_owner|confirm_intake>"
       echo "       retainer-flow-policy.sh level"; } >&2; exit 2 ;;
esac

LEVEL="$(retainer_cfg autonomy_level assisted)"
case "$LEVEL" in manual|assisted|auto|marathon) ;; *) LEVEL=assisted ;; esac   # unknown level -> strict default (as preflight)
[ "$STEP" = level ] && { printf '%s\n' "$LEVEL"; exit 0; }

# step default by level -- the matrix (step:level). Local steps bolder, outward steps more careful.
default_for() {
  case "$1:$LEVEL" in
    ask_owner:marathon)           echo off ;;    # marathon: a question = stopping all work, forbidden
    ask_owner:*)                  echo auto ;;   # other levels: asking is allowed
    # Confirming understanding is the same on ALL levels, marathon included -- a line separate from
    # ask_owner on purpose. Marathon removes questions about forks; the task boundary is not a fork,
    # and misreading it makes all the work pointless, not one choice inside it.
    confirm_intake:*)             echo auto ;;
    *:marathon)                   echo auto ;;   # marathon: all flow steps itself, merge included
    issue:manual|issue:assisted)  echo ask ;;    # outward write to the tracker -> confirm outside auto
    issue:auto)                   echo auto ;;
    branch:manual)                echo ask ;;
    branch:assisted|branch:auto)  echo auto ;;    # local, low risk
    commit:manual)                echo ask ;;    # "manual does nothing itself": a commit too
    commit:assisted|commit:auto)  echo auto ;;   # local, low risk
    pr:manual|pr:assisted)        echo ask ;;    # outward write -> confirm outside auto
    pr:auto)                      echo auto ;;
    merge:manual|merge:assisted|merge:auto)    echo off ;;    # owner-gated outside marathon
    cleanup:manual|cleanup:assisted|cleanup:auto) echo auto ;;  # the classifier lets the close API through
    # An uncovered step:level pair. Printing NOTHING is forbidden -- the consumer would read it as
    # "no policy" and take undefined behavior, silently. A silent substitution is bad too: a hole in
    # the matrix would look like a normal answer, and the completeness test would become a tautology
    # (checking non-emptiness that it itself guarantees). So: a safe value on stdout AND a diagnostic
    # on stderr -- the consumer is protected, while the hole stays visible and caught by the test.
    *)
      echo "retainer-flow-policy: no policy for pair $1:$LEVEL -- matrix incomplete" >&2
      # off is safe for "do" steps; for the question and confirmation gates the safe value is the opposite.
      case "$1" in ask_owner|confirm_intake) echo auto ;; *) echo off ;; esac
      ;;
  esac
}

OVER="$(retainer_cfg "flow_$STEP" "")"
case "$STEP:$OVER" in
  ask_owner:auto|ask_owner:off)           printf '%s\n' "$OVER" ;;   # the question gate has two valid values
  confirm_intake:auto|confirm_intake:off) printf '%s\n' "$OVER" ;;   # the confirmation gate -- the same two
  ask_owner:*|confirm_intake:*)           default_for "$STEP" ;;     # incl. `ask`: it is meaningless, not "almost auto"
  *:auto|*:ask|*:off)                     printf '%s\n' "$OVER" ;;   # a valid per-step override wins
  *)                                      default_for "$STEP" ;;     # unset / garbage -> level default
esac
