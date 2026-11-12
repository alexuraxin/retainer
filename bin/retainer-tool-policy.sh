#!/usr/bin/env bash
# retainer: call policy for ONE heavy tool -- agents/skills.
# Prints: off | ask | auto.
#   off -- not used · ask -- I PROPOSE and wait for "ok" · auto -- I call it myself whenever needed.
#
# `auto` is AUTOMATIC APPLICATION, not "allowed to call". It has three outcomes:
#   called                  -- step executed, work goes on;
#   did not call by choice  -- NOT ALLOWED: `auto` leaves no discretion;
#   CANNOT call             -- external obstacle: stop and ask the owner with a NAMED conflict,
#                              the marker `[CONFLICT: <regulator> = auto, cannot execute --
#                              <reason>]`. A silent downgrade to `off` is a violation.
# For `code_reviewer` the merge lock requires a review record on the head being merged
# (`bin/retainer-merge-ready.sh`); who left the record is not judged, so the role run itself rests on
# this policy.
#
# Two levels, NOT tied to autonomy_level (the single exception is marathon, see the file tail):
#   tools_mode (global mode): always_ask -> all ask · always_auto -> all auto · manual (default) -> per tool.
#     Either global mode leaves a tool whose tool_<name> is `off` switched off: off is a prohibition,
#     and a global mode sets how active the tools are, not what is forbidden.
#   tool_<name>: off|ask|auto, default ask (owner: "propose"). Written by the console.
# Pair of retainer-flow-policy.sh (that one is the git-flow steps, this one is tool calls).
#
#   retainer-tool-policy.sh <code_reviewer|plan_checker|tester|second_opinion>
# exit 0 = policy printed; exit 2 = unknown tool (usage).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=bin/retainer-config.sh
. "$ROOT/bin/retainer-config.sh"   # retainer_cfg -- global retainer config

TOOL="${1:-}"
case "$TOOL" in
  code_reviewer|plan_checker|tester|second_opinion) ;;
  *) echo "usage: retainer-tool-policy.sh <code_reviewer|plan_checker|tester|second_opinion>" >&2; exit 2 ;;
esac

MODE="$(retainer_cfg tools_mode manual)"
OVER="$(retainer_cfg "tool_$TOOL" ask)"
case "$OVER" in off|ask|auto) ;; *) OVER=ask ;; esac   # garbage -> ask (propose)
# The per-tool key is read BEFORE the global mode, because its `off` outranks the mode.
if [ "$OVER" = off ]; then
  RESOLVED=off
else
  case "$MODE" in
    always_ask)  RESOLVED=ask ;;
    always_auto) RESOLVED=auto ;;
    *)           RESOLVED="$OVER" ;;   # manual (and any unknown -> manual)
  esac
fi

# Marathon -- the only tie to autonomy_level. The pair "tool x marathon" is incompatible by
# construction, and a setting cannot reconcile it -- the mode decides, not the key:
#   code_reviewer -- "autonomy removes questions, not checks": review in an autonomous run IS the
#     replacement for a manual "ok". Review off + auto-merge = unreviewed code in main.
# For the other tools the `ask` outcome ("propose and wait for ok") is unexecutable -- nobody to wait
# for -- so the mode turns it into a decision, whether that `ask` came from tool_<name>, from
# always_ask or from the default. An `off` or an `auto` stays as it was resolved above.
if [ "$(retainer_cfg autonomy_level assisted)" = marathon ]; then
  case "$TOOL" in
    code_reviewer) RESOLVED=auto ;;                        # unconditional: the mode does not give the check away
    plan_checker)  [ "$RESOLVED" = ask ] && RESOLVED=auto ;;   # plan check is cheap and non-dialogue
    *)             [ "$RESOLVED" = ask ] && RESOLVED=off ;;    # tester/second_opinion -- heavy and outbound
  esac
fi
printf '%s\n' "$RESOLVED"
