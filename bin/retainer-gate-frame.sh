#!/usr/bin/env bash
# retainer: gate FRAME — step running, summary, incident log. A project sources it:
#
#   RETAINER_HOME="${RETAINER_HOME:-$HOME/retainer}"
#   . "$RETAINER_HOME/bin/retainer-gate-frame.sh"
#   GATE_STEPS="fmt|format
#   tests|tests"
#   step fmt  "$RUN/ruff" format --check .
#   step tests "$RUN/pytest" -q
#   gate_finish
#
# Why the frame lives HERE and not in the project's gate. The behavior "a red step does not cancel the rest"
# is a rule common to all projects on the box, not a property of one repository. While it was
# copied together with the template, a fix in the template reached nowhere: the project kept a
# copy taken at some point, and one red step kept aborting the run. The composition of the ENGINE steps
# is kept in retainer-gate-steps.sh for the same reason — here the same technique, one layer below.
#
# What stays with the project is exactly its own: what it checks itself with (step registry and commands) and where its
# venv lives. Everything that describes the ORDER and OUTCOME of a run arrives from here with the plugin.
#
# Contract for a project gate:
#   * source under `set -euo pipefail`; the frame takes the project's `.retainer` directory from GATE_STATE_DIR
#     (default `.retainer` next to the gate) — [rigor] and the pushback log are read from there too;
#   * declare GATE_STEPS before the first `step` — the registry builds the summary, and a step the run
#     did not reach shows in it as a separate state;
#   * finish with a `gate_finish` call — it prints the summary and returns the code of the first failed step.

# The frame is only sourced. Running it directly checks nothing and would silently return 0 — i.e. it
# would look like a passed gate.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "retainer-gate-frame.sh — the gate frame, sourced from a project's gate.sh:" >&2
  echo "  . \"\$RETAINER_HOME/bin/retainer-gate-frame.sh\"" >&2
  exit 2
fi

# The `.retainer` directory of the PROJECT ITSELF — its config and pushback log. Not to be confused with `RETAINER_HOME`:
# the engine is installed there, and substituting it here would lead the regulators into the engine's config (it has no [rigor]
# table — all rigor levels would silently fall back to defaults), and the project's incidents into the engine's
# log, from which tasks are filed on its tracker.
#
# By default the directory lies next to the gate, but layouts can be nested: for a project with the app
# in app/ the gate runs from app/, and `.retainer/` lies above. Then the project declares the path itself BEFORE
# sourcing the frame.
GATE_STATE_DIR="${GATE_STATE_DIR:-.retainer}"
# Expand IMMEDIATELY: the log is written by the EXIT trap, and by then a step may have changed the top shell's directory.
# A relative path would lead the incident astray — silently, because the write is closed with `2>/dev/null`.
[ -d "$GATE_STATE_DIR" ] && GATE_STATE_DIR="$(cd "$GATE_STATE_DIR" && pwd)"

# ── Rigor regulators (above the fixed strict baseline; they do not lower below it) ──
# We read [rigor] from config.toml OURSELVES (the guard's mini-parser stops at the first table,
# and macOS py3.9 has no tomllib). Values: true/false or a string. Changing flags is under the guard (key).
CONFIG="$GATE_STATE_DIR/config.toml"
IS_CI=""; [ -n "${CI:-}${GITEA_ACTIONS:-}" ] && IS_CI=1

rigor() {  # rigor <key> <default>
  local key="$1" def="$2" val=""
  [ -f "$CONFIG" ] && val="$(awk -v k="$key" '
    /^[[:space:]]*\[/ { inr = ($0 ~ /^[[:space:]]*\[rigor\][[:space:]]*$/) }
    inr && $0 ~ ("^[[:space:]]*" k "[[:space:]]*=") {
      sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); gsub(/["'"'"']/, ""); gsub(/[[:space:]]/, "");
      print; exit
    }' "$CONFIG" 2>/dev/null)"
  printf '%s' "${val:-$def}"
}

# The project declares the registry. The empty stub is needed so the EXIT trap survives a failure BEFORE the declaration:
# under `set -u` the summary on an undeclared variable would die together with the verdict.
GATE_STEPS="${GATE_STEPS:-}"

GATE_RC=0        # code of the FIRST failed step; zero while none has failed
GATE_DONE=""     # name|state — only for executed steps
GATE_SUMMARY=""  # the summary is printed once: by the normal end or by the trap
GATE_WIRING=""   # the guard wiring check ran (it is not in the registry: it does not decide the gate outcome)
GATE_SKIP=""     # a step reported "nothing to check with" without occupying the return code with its message
GATE_UNFINISHED=""  # the verdict was not taken: the run ended without gate_finish with red steps
GATE_BROKEN=0    # the output reader closed before the gate finished speaking (see the PIPE trap below)
GATE_RC_SAFE=0   # verdict of steps completed BEFORE the output broke: only it is reliable

# `bash gate.sh | head` is the usual way to look at long output. The reader closes the pipe, and the code
# does NOT come from a check: first the step command dies on the dead pipe (each tool has its own
# code), then the gate itself on its very first print. The trap marks the break and exits at once;
# the verdict is taken from the snapshot made before the break.
trap 'GATE_BROKEN=1; exit 141' PIPE

gate_field() {   # gate_field <text> <name> — the second field of the line with this name
  printf '%s\n' "$1" | awk -F'|' -v k="$2" '$1 == k { print $2; exit }'
}
gate_mark() { GATE_DONE="$GATE_DONE$1|$2
"; }

# Step outcome: non-zero code — failed · `GATE_SKIP` — nothing to check with · otherwise passed. "Nothing
# to check" is reported through a SIDE channel, not the return code, because a step command may be a foreign
# binary with its own code semantics: pytest, for example, uses three for an internal run
# error. A numeric contract over foreign codes would turn a broken tool into "does not count"
# — i.e. a green gate with tests not run.
step() {         # step <name> <command...> — the outcome is collected, the run continues
  local name="$1" rc=0; shift
  GATE_SKIP=""
  # Snapshot of the verdict BEFORE the step. If the output reader closes during this step, the command dies on the
  # dead pipe and returns non-zero — not about code quality but about the fate of the output. The incident is
  # logged from the snapshot: it is about the steps that managed to finish.
  GATE_RC_SAFE="$GATE_RC"
  printf '▶ %s\n' "$(gate_field "$GATE_STEPS" "$name")"
  "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then
    gate_mark "$name" fail
    if [ "$GATE_RC" -eq 0 ]; then GATE_RC="$rc"; fi
  elif [ -n "$GATE_SKIP" ]; then
    gate_mark "$name" skip
  else
    gate_mark "$name" ok
  fi
  return 0
}
step_off() {     # switched off by a regulator — the state is declared, not skipped silently
  gate_mark "$1" off
}
step_ci() {      # deliberately does not run in CI (the step's condition is false there by construction)
  gate_mark "$1" ci
}

gate_summary() {
  [ -n "$GATE_SUMMARY" ] && return 0
  GATE_SUMMARY=1
  printf '── step summary ──\n'
  # Steps ran but there is no registry: the summary would be EMPTY — i.e. it would look like a gate with no
  # steps. The empty `GATE_STEPS` stub exists for the trap, and it also turns a forgotten
  # declaration from a loud `set -u` failure into a quiet emptiness. We say it aloud.
  if [ -z "$GATE_STEPS" ] && [ -n "$GATE_DONE" ]; then
    printf '  ! GATE_STEPS registry not declared — steps ran, nothing to name them with:\n'
    printf '%s' "$GATE_DONE" | awk -F'|' 'NF { printf "      %s — %s\n", $1, $2 }'
  fi
  local name title
  while IFS='|' read -r name title; do
    [ -n "$name" ] || continue
    case "$(gate_field "$GATE_DONE" "$name")" in
      ok)   printf '  ✓ %s\n' "$title" ;;
      fail) printf '  ✗ %s\n' "$title" ;;
      off)  printf '  · %s — switched off by a regulator\n' "$title" ;;
      ci)   printf '  · %s — does not run in CI\n' "$title" ;;
      skip) printf '  · %s — nothing to check with, step did not run\n' "$title" ;;
      *)    printf '  ! %s — NOT RUN\n' "$title" ;;
    esac
  done <<EOF
$GATE_STEPS
EOF
  if [ -n "$GATE_WIRING" ]; then
    printf '  · guard wiring check — a warning, does not decide the gate outcome\n'
  fi
  return 0
}

# Red gate → a discipline incident in the log. No task is filed from it: that auto-filing went when
# the engine was cut back to protecting the irreversible, and the log is what gets read. Skipped in CI
# (the failure is visible in CI logs). detail = ONLY the fact of failure (code), WITHOUT step output — otherwise a secret from
# the secret-scan step could leak into the tracker. The guard excludes bypass.log from revert; the trap does NOT call
# exit → the gate's return code is preserved. The trap prints the summary in case of a break: a step that silently
# did not run is worse than a missing one — it is counted as passed.
gate_exit() {
  local rc="$1" ts
  # The handler must survive to the write, so here the break signal is only MARKED: exiting from it
  # would cut the handler at its first print, and a red gate viewed through `| head` would not reach
  # the log at all.
  trap 'GATE_BROKEN=1' PIPE
  # Printing the summary also checks the reader: a break INSIDE a step was never noticed by the top shell —
  # it printed nothing — and it surfaces exactly here.
  gate_summary || GATE_BROKEN=1
  if [ "$GATE_BROKEN" = 1 ]; then
    # The verdict comes from the snapshot BEFORE the break: the step during which the reader left returned the dead
    # pipe's code, not a code assessment. Code 141 alone does not count as a break: an inner
    # pipeline gives it with a live reader too, and then the gate really did die midway.
    printf '⚠ gate output cut off by the reader — code %s is not a verdict; outcome of steps before the break: %s\n' \
      "$rc" "$GATE_RC_SAFE" >&2
    rc="$GATE_RC_SAFE"
  fi
  # The verdict may be left untaken: the run reached the end but `gate_finish` was not called (forgotten in the
  # gate, cut by a `return`, left via `exit 0`). Then the shell returns zero, and red steps turn
  # into a passed gate — the very silent green the frame was moved to prevent. We take the
  # verdict here and say it aloud: a skipped step is visible, while "gate passed" is not.
  if [ "$rc" -eq 0 ] && [ "$GATE_RC" -ne 0 ] && [ "$GATE_BROKEN" != 1 ]; then
    printf '✗ gate ended without a verdict — gate_finish not called, but steps failed (code %s)\n' \
      "$GATE_RC" >&2
    rc="$GATE_RC"
    GATE_UNFINISHED="$GATE_RC"
  fi
  # The timestamp is taken AFTER the summary is printed: before it, an unflushed stdout buffer would go into the fork of
  # the substitution and stick to the log line, breaking the JSONL.
  ts="$(date +%Y-%m-%dT%H:%M:%S)"
  if [ -z "$IS_CI" ] && [ "$rc" -ne 0 ] && [ -d "$GATE_STATE_DIR" ]; then
    printf "{\"ts\":\"%s\",\"reason\":\"gate-failed\",\"detail\":\"gate failed (code %s)\"}\n" "$ts" "$rc" >> "$GATE_STATE_DIR/bypass.log" 2>/dev/null
  fi
  # The process code is replaced ONLY when the verdict was not taken. In the other cases it was returned by
  # `gate_finish` or a failed command outside a step, and replacing it would hide the real cause.
  [ -n "$GATE_UNFINISHED" ] && exit "$GATE_UNFINISHED"
  return 0
}
trap 'gate_exit $?' EXIT

# End of run: summary and verdict. Returns the code of the FIRST failed step — the same one that goes into the incident
# log. There is no point keeping this block in the project: it is identical everywhere, and diverging, it would give a
# gate that prints the summary and still returns zero.
gate_finish() {
  gate_summary
  if [ "$GATE_RC" -ne 0 ]; then
    echo "✗ GATE RED — failed steps are listed in the summary above"
    exit "$GATE_RC"
  fi
  echo "✓ GATE GREEN"
}
