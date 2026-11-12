#!/usr/bin/env bash
# retainer: suite runner -- one home for HOW tests are run.
#
# Suite time is held by TWO things. The first is the file count: the total grows with it and is cut only
# by parallelism, so it lives here and not as a copy in the hook and in the workflow. The second is the dominant
# file: the verdict-honesty runner launches the whole suite once more. It parallelizes inside itself and
# takes its budget from here through the environment rather than computing its own.
#
#   retainer-suite.sh [--all | files...]
# exit 0 -- all passed · 1 -- at least one failed · 2 -- usage/nothing to run ·
#      3 -- SUITE_SLOT_GIVEUP passed with every slot busy, nothing was run.
#
# THE FILE COMPOSITION IS NOT DECIDED HERE. Whom to run (for example, skipping the honesty runner on an
# intermediate push) the caller knows and passes as a list. A second home for the same truth would
# split the workflow and the hook exactly where this task merges them.
#
# Regulators (environment):
#   SUITE_JOBS=<N>      degree of parallelism. Unset -- computed from the machine capacity.
#                       A given one beats the computation: used by a measurement and by a caller who knows
#                       more about its own load than this script does.
#   SUITE_PEERS=<N>     how many jobs run the suite side by side (default 1). Affects the budget computation.
#   SUITE_SERIAL="a b"  base names (without .sh) that run AFTER the parallel wave, one at a
#                       time. The registry is explicit: a test that cannot take parallelism is named here.
#   SUITE_SLOTS, SUITE_SLOT_GIVEUP, SUITE_SLOT_WAIT, RETAINER_SUITE_SLOTS_DIR -- the host-wide limit on concurrent runs,
#                       see HOST-WIDE SLOTS below.
#
# RETRY. A file that fails in the wave or the tail reruns once, alone, with the same environment. A pass
# leaves the run green but prints `FLAKY <file>` and counts it in the summary, together with the output of
# the failed wave run; a second fail fails the run. One retry per file, never a rerun of the whole run:
# a flake costs seconds instead of the whole job, and it stays readable in the log instead of silent.
set -uo pipefail

# How many jobs run the suite SIMULTANEOUSLY. A multiplier that was in no computation --
# and it turned numbers chosen separately into sixteen workers.
#
# The value is passed by the caller: how many jobs run side by side is known to the workflow, not this script.
# Today's number and its rationale stand in the CI wiring itself -- where they are changed. A retelling here
# would be a second home for the same truth: when the wiring changes, a test goes red on it, while the retelling
# goes stale silently.
#
# Only LOCAL callers reach the default, and there are two: the git hook before push and the gate on
# the declared "done". No jobs run next to them, so the default is one: reserving
# capacity for what does not exist means paying for a foreign load that is absent. A garbage
# value is equated to the default, otherwise a typo would give a stricter budget than emptiness.
#
# The "done" gate changes the degree together with the default, and this is a decision, not a side effect: it runs a
# subset by changed files (workers never exceed targets anyway) and fires where
# a human waits for the answer. It does not overload even together with CI running alongside: the total workers
# stay fewer than cores.
JOBS_PER_RUN="${SUITE_PEERS:-1}"
case "$JOBS_PER_RUN" in ''|*[!0-9]*|0) JOBS_PER_RUN=1 ;; esac
RUNNER_CFG="${RETAINER_RUNNER_CFG:-$HOME/.config/retainer/gitea-runner/config.yaml}"

# WORKER BUDGET. The limiters were set separately and never multiplied:
#
#   runner capacity x jobs per run x SUITE_JOBS = workers, which can exceed the cores
#
# Each number can be right on an empty machine; what goes wrong is their product. An oversubscribed
# machine runs many times slower and network steps hit their timeouts, so overload turns not only
# into delay but into a FALSE RED -- and those stop being read.
#
# The capacity is read from the runner config, not set as a constant: two homes for one number
# drift silently, and would drift exactly when the owner raises capacity.
suite_budget() {
  cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
  case "$cores" in ''|*[!0-9]*|0) cores=4 ;; esac
  cap="$(sed -n 's/^[[:space:]]*capacity:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$RUNNER_CFG" 2>/dev/null | head -1)"
  # No config (a project without its own runner) -- count the capacity as one: understating the budget where
  # there is no runner at all means paying for a foreign load that does not exist.
  case "$cap" in ''|*[!0-9]*|0) cap=1 ;; esac
  # The runs that really hold slots, when more of them fit than the CI wiring declares: the owner
  # may raise SUITE_SLOTS above the capacity, and then the declared count understates the neighbours.
  runs=$(( cap * JOBS_PER_RUN ))
  [ "$SLOTS_HELD" -gt "$runs" ] && runs="$SLOTS_HELD"
  budget=$(( cores / runs ))
  [ "$budget" -ge 1 ] || budget=1
  printf '%s' "$budget"
}

# An explicit degree is validated before the slot wait: a usage error must not queue first.
case "${SUITE_JOBS:-1}" in *[!0-9]*|0) echo "retainer-suite: SUITE_JOBS=«${SUITE_JOBS}» -- an integer >= 1 is needed" >&2; exit 2 ;; esac

# HOST-WIDE SLOTS. The budget above divides the cores among the CI jobs it knows of, and nothing else
# bounded how many runs execute at once: a local pre-push, another session's run and two CI gates all
# went together. Every run now takes one of SUITE_SLOTS slots in one directory shared by CI and local
# sessions, and waits aloud when they are taken.
#
# A slot is an exclusive flock on a slot file, held by THIS shell's descriptor 9. The lock belongs to
# the open file description, so it outlives the short python child that takes it and is dropped by the
# kernel when the run dies by any signal: a crash leaves nothing to reclaim. Children get fd 9 closed,
# otherwise an orphaned test would keep a dead run's slot.
#
#   SUITE_SLOTS=<N>              slots on the machine (default 2; match it to how many CI jobs the runner
#                                takes at once, a local run queues behind them). Garbage equals the default.
#   RETAINER_SUITE_SLOTS_DIR     where the slot files live. A fixed path, not $TMPDIR or $HOME: a CI job
#                                under the host executor and a local session must meet in one place.
#   SUITE_SLOT_GIVEUP=<s>        give up waiting after s seconds and run NOTHING: exit 3, aloud. For a
#                                caller with its own ceiling that would rather skip than add a run over
#                                the limit. Outranks SUITE_SLOT_WAIT; garbage is ignored.
#   SUITE_SLOT_WAIT=<s>          give up waiting after s seconds and run without a slot, aloud. Unset --
#                                wait as long as the holders live. Set by stop gates: a plugin copy older
#                                than SUITE_SLOT_GIVEUP sets only this, a newer one sets both, for runners
#                                that do not know the give-up.
#   SUITE_SLOT_HELD              exported by every run past the slot step, with a slot or without one. A
#                                nested run under the same directory takes none: it would otherwise queue
#                                behind its own parent, and under a capped parent pay the cap twice.
#
# Fail-open, aloud: without a working python3 or a writable directory the run goes without a slot. A
# gate hung on its own lock is worse than one run over the limit.
SLOTS="${SUITE_SLOTS:-2}"
case "$SLOTS" in ''|*[!0-9]*|0) SLOTS=2 ;; esac
SLOTS_DIR="${RETAINER_SUITE_SLOTS_DIR:-/tmp/retainer-suite-slots}"
SLOT_WAIT="${SUITE_SLOT_WAIT:-}"
case "$SLOT_WAIT" in *[!0-9]*) SLOT_WAIT='' ;; esac
SLOT_GIVEUP="${SUITE_SLOT_GIVEUP:-}"
case "$SLOT_GIVEUP" in *[!0-9]*) SLOT_GIVEUP='' ;; esac
SLOTS_HELD=0

# Lock the file open on fd 9 without blocking. exit 0 -- the slot is ours, 3 -- another run holds it,
# anything else -- python3 cannot lock at all, which must not read as "busy" and queue forever.
lock_fd9() {
  python3 -c 'import fcntl, sys
try:
    fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(3)' 2>/dev/null
}

# How many runs hold slots now, this one included. The other slot files are tried on their own
# descriptors and released at once; our own is skipped -- a second open of it would always fail.
count_held() {
  python3 - "$SLOTS_DIR" "$SLOTS" "$1" <<'PY'
import fcntl, os, sys
root, total, mine = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
held = 1
for k in range(1, total + 1):
    if k == mine:
        continue
    try:
        with open(os.path.join(root, 'slot-%d' % k), 'a') as fh:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        held += 1
print(held)
PY
}

no_slot() {
  printf '⚠ no suite slot (%s) -- running without one\n' "$1"
  export SUITE_SLOT_HELD="$SLOTS_DIR"
}

take_slot() {
  local k rc t0 waited announced=0
  if [ "${SUITE_SLOT_HELD:-}" = "$SLOTS_DIR" ]; then
    printf '▶ suite slot: the enclosing run went through the slot step, not taken again\n'
    return 0
  fi
  command -v python3 >/dev/null 2>&1 || { no_slot "no python3"; return 0; }
  mkdir -p "$SLOTS_DIR" 2>/dev/null || { no_slot "cannot create $SLOTS_DIR"; return 0; }
  t0="$(date +%s)"
  while :; do
    k=1
    while [ "$k" -le "$SLOTS" ]; do
      { exec 9>>"$SLOTS_DIR/slot-$k"; } 2>/dev/null || { no_slot "cannot open $SLOTS_DIR/slot-$k"; return 0; }
      lock_fd9; rc=$?
      if [ "$rc" = 0 ]; then
        waited=$(( $(date +%s) - t0 ))
        printf '▶ suite slot %s of %s (waited %s s)\n' "$k" "$SLOTS" "$waited"
        export SUITE_SLOT_HELD="$SLOTS_DIR"
        SLOTS_HELD="$(count_held "$k")"
        case "$SLOTS_HELD" in ''|*[!0-9]*) SLOTS_HELD=1 ;; esac
        return 0
      fi
      exec 9>&-
      [ "$rc" = 3 ] || { no_slot "python3 cannot lock"; return 0; }
      k=$(( k + 1 ))
    done
    if [ "$announced" = 0 ]; then
      printf '⏳ all %s suite slots are busy -- waiting for one\n' "$SLOTS"
      announced=1
    fi
    waited=$(( $(date +%s) - t0 ))
    # Before any worker exists: the give-up leaves nothing started and nothing to clean.
    if [ -n "$SLOT_GIVEUP" ] && [ "$waited" -ge "$SLOT_GIVEUP" ]; then
      printf '⏳ no suite slot free after %s s (all %s busy) -- tests not run\n' "$waited" "$SLOTS"
      exit 3
    fi
    if [ -n "$SLOT_WAIT" ] && [ "$waited" -ge "$SLOT_WAIT" ]; then
      no_slot "none free after $waited s"
      return 0
    fi
    sleep 2
  done
}

# Registry of the serial tail. Empty -- the whole suite runs in parallel.
# test_verdict_honesty: runs the WHOLE suite once more, and in the common wave would double the load on the same
# cores. It has its own parallelism, internal, on the same budget -- so it goes after the wave, not
# together with it. It puts a probe file into the tests/ directory of the live repository (otherwise git-aware tests
# skip and the runner would measure a skip); the probe name is unique, it does not bother neighbors.
SERIAL_DEFAULT="test_verdict_honesty"
SERIAL="${SUITE_SERIAL-$SERIAL_DEFAULT}"

all_suite() {
  # shellcheck disable=SC2206
  FILES=(tests/test_*.sh)
  [ -e "${FILES[0]}" ] || { echo "retainer-suite: no test_*.sh in tests/ -- nothing to run" >&2; exit 2; }
}

scope_suite() {
  local scope_tool branch base selected since against
  local changed=() line
  scope_tool="$(dirname "$0")/retainer-ci-scope.sh"
  if ! command -v git >/dev/null 2>&1 \
     || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
     || ! git rev-parse --verify --quiet origin/main >/dev/null 2>&1 \
     || [ ! -f "$scope_tool" ]; then
    echo "▶ selection cannot be computed (no git / origin/main / ci-scope) -- running the FULL suite (fail-safe)" >&2
    all_suite
    return
  fi
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  base="$(git merge-base origin/main HEAD 2>/dev/null)"
  against="origin/main"
  # The last pushed head, when pre-push names one: what its push already ran is not rerun, and a
  # merge of main contributes only what it brings in. An unknown commit or a non-ancestor (a force
  # push) keeps the base above.
  since="${RETAINER_SUITE_SINCE:-}"
  if [ -n "$since" ] && git cat-file -e "$since^{commit}" 2>/dev/null \
     && git merge-base --is-ancestor "$since" HEAD 2>/dev/null; then
    base="$since"; against="the last pushed head"
  fi
  if [ -z "$base" ]; then
    echo "▶ no merge-base with origin/main -- running the FULL suite (fail-safe)" >&2
    all_suite
    return
  fi
  while IFS= read -r line; do
    [ -n "$line" ] && changed+=("$line")
  done < <(
    { git diff --name-only "$base" HEAD
      git diff --name-only HEAD
      git ls-files --others --exclude-standard
    } 2>/dev/null | sort -u
  )
  # bash 3.2 aborts on "${arr[@]}" of an empty array under set -u; the [@]+ form guards it.
  selected="$(bash "$scope_tool" pull_request "$branch" "${changed[@]+"${changed[@]}"}" 2>/dev/null)"
  if [ -z "$selected" ]; then
    echo "▶ ci-scope returned an empty selection -- running the FULL suite (fail-safe)" >&2
    all_suite
    return
  fi
  FILES=()
  while IFS= read -r line; do
    [ -n "$line" ] && FILES+=("$line")
  done <<< "$selected"
  printf '▶ selection by diff against %s: %s tests\n' "$against" "${#FILES[@]}" >&2
}

# No args: select tests by diff against origin/main (ci-scope). --all: full suite. Explicit list wins.
ALL=0
if [ "${1:-}" = "--all" ]; then ALL=1; shift; fi
FILES=("$@")
if [ "$ALL" = 1 ]; then
  all_suite
elif [ "${#FILES[@]}" -eq 0 ]; then
  scope_suite
fi

is_serial() {
  local base="${1##*/}"
  base="${base%.sh}"
  case " $SERIAL " in *" $base "*) return 0 ;; *) return 1 ;; esac
}

PAR=()
TAIL=()
for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "retainer-suite: no file $f" >&2; exit 2; }
  if is_serial "$f"; then TAIL+=("$f"); else PAR+=("$f"); fi
done

take_slot
JOBS="${SUITE_JOBS:-$(suite_budget)}"
# The computed budget is visible to children: a file that itself runs a batch of runs must share THIS
# machine, not compute its own degree again. A second computation would drift from the first.
export SUITE_JOBS="$JOBS"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
LOGS="$WORK/logs"
mkdir -p "$LOGS"

# Worker: a run of one file. Output goes TO A FILE, one short line goes to the console -- otherwise
# under parallelism the neighbors' lines interleave inside each other and the log is unreadable.
# `</dev/null` is mandatory: a test waiting on stdin would hang silently under xargs.
#
# `worker <file> retry` is the second run of a file that failed in the wave: the wave log is kept as
# `.wave.log`, and the verdict goes to `.flaky` on a pass and to `.failed` on a second fail.
export SUITE_LOGDIR="$LOGS"
worker() {
  local f="$1" mode="${2:-}" base rc
  base="${f##*/}"
  [ "$mode" = retry ] && mv "$SUITE_LOGDIR/${base}.log" "$SUITE_LOGDIR/${base}.wave.log"
  bash "$f" </dev/null >"$SUITE_LOGDIR/${base}.log" 2>&1
  rc=$?
  if [ "$mode" = retry ]; then
    if [ "$rc" -eq 0 ]; then
      printf '  FLAKY %s (failed in the wave, passed alone)\n' "$f"
      printf '%s\n' "$f" >>"$SUITE_LOGDIR/.flaky"
    else
      printf '  FAIL %s (rc=%s, failed again alone)\n' "$f" "$rc"
      printf '%s\n' "$f" >>"$SUITE_LOGDIR/.failed"
    fi
  elif [ "$rc" -eq 0 ]; then
    printf '  ok   %s\n' "$f"
  else
    printf '  FAIL %s (rc=%s)\n' "$f" "$rc"
    printf '%s\n' "$f" >>"$SUITE_LOGDIR/.wave-failed"
  fi
  return 0
}
export -f worker

# Machine load is named ALOUD. Previously a developer learned of competition with the CI queue
# only by time: the run took three times longer, the cause was named nowhere, and a conclusion was drawn about
# the tests. We count not "is the daemon running" -- it always is -- but the actual load.
loadavg="$(uptime 2>/dev/null | sed -n 's/.*averages*:[[:space:]]*\([0-9.]*\).*/\1/p')"
if [ -n "$loadavg" ]; then
  cores_now="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
  busy="$(awk -v load="$loadavg" -v cpus="$cores_now" 'BEGIN { print (load > cpus * 0.7) ? 1 : 0 }')"
  if [ "$busy" = "1" ]; then
    printf '⚠ machine busy (load %s on %s cores) -- probably a CI run is in progress.\n' "$loadavg" "$cores_now"
    printf '  The time of this run is about load, not about the tests; network steps may go red on a timeout.\n'
  fi
fi

started="$(date +%s)"
if [ "${#PAR[@]}" -gt 0 ]; then
  printf '▶ parallel wave: %s files, -P%s\n' "${#PAR[@]}" "$JOBS"
  printf '%s\n' "${PAR[@]}" | xargs -P "$JOBS" -I '{}' bash -c 'worker "$@"' _ '{}' 9>&-
fi

if [ "${#TAIL[@]}" -gt 0 ]; then
  printf '▶ serial tail: %s (runs the suite itself, with its own parallelism)\n' "${TAIL[*]##*/}"
  for f in "${TAIL[@]}"; do worker "$f" 9>&-; done
fi

# The retry pass: each file that failed above reruns once, alone. `sort -u` keeps a file named twice in
# an explicit list to one retry.
if [ -f "$LOGS/.wave-failed" ]; then
  printf '▶ retry: %s failed in the wave, each reruns once alone\n' "$(sort -u "$LOGS/.wave-failed" | grep -c .)"
  while IFS= read -r f; do worker "$f" retry 9>&-; done < <(sort -u "$LOGS/.wave-failed")
fi
elapsed=$(( $(date +%s) - started ))

# Aggregate. The named output of the failed is printed IN FULL and in alphabetical order: under parallelism
# completion order is random, and a log that changes from run to run is unreadable by eye.
failed=0
if [ -f "$LOGS/.failed" ]; then
  failed="$(grep -c . "$LOGS/.failed")"
  echo
  echo "── failed output ──"
  while IFS= read -r f; do
    printf '════ %s ════\n' "$f"
    cat "$LOGS/${f##*/}.log"
  done < <(sort "$LOGS/.failed")
fi

# A flake's wave output is the only evidence of why it failed: the green verdict must not discard it.
flaky=0
flaky_note=''
if [ -f "$LOGS/.flaky" ]; then
  flaky="$(grep -c . "$LOGS/.flaky")"
  flaky_note=" ($flaky flaky)"
  echo
  echo "── flaky output (the failed wave run) ──"
  while IFS= read -r f; do
    printf '════ %s ════\n' "$f"
    cat "$LOGS/${f##*/}.wave.log"
  done < <(sort "$LOGS/.flaky")
fi

total=$(( ${#PAR[@]} + ${#TAIL[@]} ))
if [ "$failed" -eq 0 ]; then
  printf '\n✓ suite green: %s files in %ss (-P%s)%s\n' "$total" "$elapsed" "$JOBS" "$flaky_note"
  exit 0
fi
printf '\n✗ failed %s of %s in %ss (-P%s)%s\n' "$failed" "$total" "$elapsed" "$JOBS" "$flaky_note" >&2
exit 1
