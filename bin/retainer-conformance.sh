#!/usr/bin/env bash
# retainer: has a managed project converged with the box.
#
#   retainer-conformance.sh [project dir]
# exit 0 — no discrepancies, all signals checked · 1 — discrepancies found
#      2 — usage or THE CHECK IS NOT WORKING · 3 — no targets: the directory does not look like a managed project
#      4 — no discrepancies, but NOT ALL signals were checked (nothing to look at)
#
# The engine rolls out ITSELF and checks ITSELF: the only comparison compares the engine tree with
# the installed plugin, so both sides are the engine's. Nothing measures the "what is in the box"
# versus "what the project has" divergence, and a project silently lives with old wiring while the
# agent reads its instructions as truth.
#
# ADVISORY ON PURPOSE. The command does not edit project files and is not put into its gate: half the
# targets are protected, and a red gate on a new-version rollout would stop work in every project at
# once. Fixes are printed as text — the owner applies them.
#
# THE UNCHECKED IS NAMED. A class that could not be run (no git repository, no files) is printed on
# a separate line and does not count toward the verdict: "converged" and "did not look" are different
# answers, and silently merging them would be false calm.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BOX="$(cd "$HERE/.." && pwd)"

# The shared config is sourced BEFORE the cd into the project: the delivery resolution lives there
# and must stay the engine's only one. Sourcing defines functions and sets two constants — an empty
# RETAINER_ADVISORY_REASONS that nothing in the tree reads, and RETAINER_LOCK_CONTEXT, read by the
# merge lock's publisher and reader. Neither is used here — no other effect on this check.
# FAIL-CLOSED on its absence: a failed source leaves the resolution undefined, and the check would
# then report every project's delivery as "not judged" — the unverified dressed as a measurement,
# which is the very class this check exists against.
[ -f "$HERE/retainer-config.sh" ] || {
  echo "✗ box conformance: retainer-config.sh is not alongside — the delivery resolution is unavailable" >&2
  exit 2; }
# shellcheck source=bin/retainer-config.sh
. "$HERE/retainer-config.sh"

DIR="${1:-.}"
[ -d "$DIR" ] || { echo "usage: retainer-conformance.sh [project dir]" >&2; exit 2; }
cd "$DIR" || exit 2
[ -d .retainer ] || {
  echo "▶ box conformance: no .retainer/ — not a managed project, nothing to check"; exit 3; }
[ -f "$HERE/retainer-gate-steps.sh" ] || {
  echo "✗ box conformance: retainer-gate-steps.sh is not alongside — cannot read the box contents" >&2
  exit 2; }

CONFIG=".retainer/config.toml"
# Flow commands: labels, time tracking and checkboxes live inside them. An instruction that teaches
# the manual path leaves all of that to the agent's memory.
FLOW_COMMANDS="retainer-task-start.sh retainer-task-close.sh retainer-merge-ready.sh retainer-blocked-check.sh"

found=0
unchecked=""
say(){ printf '✗ %s\n' "$1"; found=$((found + 1)); }
fix(){ printf '    fix: %s\n' "$1"; }
skip(){ unchecked="$unchecked
    $1"; }

# A top-level key or one from the named table of the project config.
cfg(){  # cfg <key> [table]
  [ -f "$CONFIG" ] || return 0
  awk -v key="$1" -v table="${2:-}" '
    /^[[:space:]]*\[/ { inside = (table != "" && $0 ~ ("^[[:space:]]*\\[" table "\\][[:space:]]*$")) }
    (table == "" || inside) && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
      sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, "")
      sub(/[[:space:]]+$/, ""); gsub(/^["'"'"']|["'"'"']$/, "")
      print; exit
    }' "$CONFIG" 2>/dev/null
}

# Is the key named in a COMMENT of the `[rigor]` table. A project that decided "we do not need this
# step" often writes it as prose beside the table — and for a self-gate step that is
# indistinguishable from a forgotten key, though the fix differs. The region is the same as `cfg`'s:
# a key outside the table does not exist for the step, and a mention above the table or in a
# neighbouring one is not a decision.
# Word boundaries are computed by replacing all non-word bytes with a space, not by a negated class
# in a regex: a negated class over multibyte bytes catches parts of non-ASCII neighbours.
named_in_comment(){  # named_in_comment <key> -> 0 if the key is named in a [rigor] table comment
  [ -f "$CONFIG" ] || return 1
  awk -v key="$1" '
    /^[[:space:]]*\[/ { inr = ($0 ~ /^[[:space:]]*\[rigor\][[:space:]]*$/); next }
    !inr { next }
    index($0, "#") == 0 { next }
    { text = substr($0, index($0, "#"))
      gsub(/[^A-Za-z0-9_]/, " ", text)
      if (index(" " text " ", " " key " ") > 0) { found = 1; exit } }
    END { exit (found ? 0 : 1) }' "$CONFIG" 2>/dev/null
}

# ── 1. The project instructions name the flow commands ────────────────────────
# A project has SEVERAL instructions and the agent reads them together: looking at one file declares
# a discrepancy what is written in its neighbour. The set is the same as in the instruction link check.
docs=""
for cand in CLAUDE.md AGENTS.md ONBOARDING.md tooling.md docs/tooling.md \
            "$(cfg regulations docs)" "$(cfg project_context docs)" "$(cfg architecture docs)"; do
  [ -n "$cand" ] && [ -f "$cand" ] || continue
  # One file named by both the default and the config is one file: twice in the report it reads as
  # two different places that were looked at.
  case "
$docs" in *"
$cand"*) continue ;; esac
  docs="$docs$cand
"
done
# A command mention in an instruction. Word boundaries are real: `our-retainer-task-start.shim` does
# not name `retainer-task-start.sh`. Negation is judged by MARKUP forms, not by the hash: in
# Markdown a hash is a heading, and "### retainer-task-start.sh" is documenting, not forbidding.
named(){  # named <command>
  esc="$(printf '%s' "$1" | sed 's/\./\\./g')"
  # Loop WITHOUT a pipeline: in a subshell `return` would leave it, not the function, and any
  # instruction would read as not naming the command.
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    if grep -E "(^|[^[:alnum:]_.-])${esc}([^[:alnum:]_.-]|\$)" "$doc" 2>/dev/null \
       | grep -vE '(^|[[:space:]>*-]+)([Dd][Oo][[:space:]]+[Nn][Oo][Tt][[:space:]]+(use|keep|do|call)|<!--)|~~' | grep -q .; then
      return 0
    fi
  done <<EOF
$docs
EOF
  return 1
}

if [ -z "$docs" ]; then
  skip "no project instructions found — nowhere to name the flow commands"
else
  missing=""
  for cmd in $FLOW_COMMANDS; do
    named "$cmd" || missing="$missing $cmd"
  done
  if [ -n "$missing" ]; then
    say "project instructions do not name the flow commands:$missing"
    printf '    looked at: %s\n' "$(printf '%s' "$docs" | tr '\n' ' ')"
    fix "add to the task-cycle section: \"start — ${CLAUDE_PLUGIN_ROOT:-<plugin>}/bin/retainer-task-start.sh <owner/repo> <N>\"
             and likewise for close, merge readiness and hitting a block"
  fi
fi

# ── 2. The project gate calls the engine steps ────────────────────────────────
# A call is judged by EXECUTION, not by a name mention. In the box gate the runner name appears three
# times — in a variable assignment, in the "no runner" message and in the call line itself — and
# the call goes THROUGH a variable. A name search answered "calls" both where the call line was
# commented out and where it was deleted outright: the check was silent exactly on its subject.
#
# So: comments are stripped, the names the runner can be called by are collected (the path itself
# and variables assigned to it NOT in a comment), and a line is required where such a name stands in
# command position — as the first word, after a command separator or after an interpreter.
script_called(){  # script_called <gate file> <engine script name, regex>
  body="$(sed -E 's/(^|[[:space:]])#.*$//' "$1")"
  tokens="$2"
  for var in $(printf '%s\n' "$body" \
      | grep -oE "[A-Za-z_][A-Za-z0-9_]*=[^;]*$2" | cut -d= -f1); do
    tokens="$tokens|[\$]${var}|[\$][{]${var}[}]"
  done
  printf '%s\n' "$body" | grep -qE \
    "(^[[:space:]]*|[;&|][[:space:]]*|(^|[[:space:]])(bash|sh|source|[.])[[:space:]]+)\"?[^[:space:]\"]*(${tokens})"
}
steps_called(){  # steps_called <gate file>
  script_called "$1" 'retainer-gate-steps\.sh'
}
# The run frame is the second half of the same seam: the runner carries the SET of engine steps, the
# frame carries the ORDER and OUTCOME of a run. A gate with its own copy of the frame looks working
# and stays on behaviour frozen at some point: a run fix in the engine never reaches it.
frame_sourced(){  # frame_sourced <gate file>
  script_called "$1" 'retainer-gate-frame\.sh'
}

# A gate may be declared by a COMMAND, not a file (`make ci`, `docker compose run …`): there is no
# file by that name, but the call exists. The signal comes from the shell, not from a list of known
# names — a list would go stale with every new build tool.
# An empty string can get here — `command -v ""` answers with refusal, and the command branch is
# not chosen. There is deliberately no separate guard for it: it would repeat the same condition.
# defer: only the first word is judged, the existence of the TARGET itself is not checked (`make ci`
# without a `ci` target passes as a declared gate), upgrade: when a project appears that declared
# the gate as a nonexistent target — the target discriminator differs for make, docker and npm, and
# there is nothing to build it on before a case.
cmd_exists(){ command -v "$1" >/dev/null 2>&1; }

# The project declares the gate address itself with the `gate_command` key; the built-in list is a
# fallback for projects that have not declared it yet.
#
# The resolution order is load-bearing: FILE, then the fallback list, and only then the command. For
# a project that declared the gate as a command and also has its own `scripts/gate.sh`, the call
# checks run on the file — the reverse order would silently send them to "not checked".
#
# A file is looked up by EVERY word of the value, not the first: an interpreter before the path is
# a common form (`python3 scripts/gate.py`, `uv run scripts/gate.py`), and parsing by the first word
# would send a working check of a whole family of stacks to "not checked". Interpreters cannot be
# listed by name: the list goes stale with every new tool.
gate_decl="$(cfg gate_command)"
gate=""; declares_path=0
for word in $gate_decl; do
  # A word becomes the gate address by SPELLING or by the execute bit. Otherwise an option argument
  # that happens to be an existing file would be declared the gate: `docker compose -f
  # docker-compose.yml run` would make the YAML the gate, and `make -f build/Makefile ci` the
  # Makefile, and the check would advise putting a bash line into them. A script extension works
  # even for a not-yet-created file — a declared and vanished gate must stay a discrepancy, not
  # slide into "declared as a command".
  # It is checked that this is a FILE: the `-x` bit is true for a directory too, and a directory
  # argument (`npm --prefix ./app run gate`, `make -C ./build ci`) would be declared a vanished
  # gate — a false discrepancy for a converged project.
  # defer: a path without a script extension and without the execute bit — a file (`tools/gate`) or
  # a directory (`./scripts`) alike — is not accepted as an address — with a live file from the
  # fallback list the checks go by it, without such a file the value reads as a command,
  # upgrade: when a project with such a declaration appears.
  case "$word" in
    *.sh|*.py) ;;
    */*) { [ -f "$word" ] && [ -x "$word" ]; } || continue ;;
    *) continue ;;
  esac
  declares_path=1
  [ -f "$word" ] && { gate="$word"; break; }
done
# The fallback list does not apply where the project declared an ADDRESS: otherwise a foreign file
# would take the place of the declared and vanished gate — the call checks would run on it and
# return "converged" where the declared gate does not exist at all.
#
# The signal is precisely "an address is declared", not "anything is declared": for a project that
# declared a COMMAND, the gate file next to it is judged as before, and the call checks that work
# today keep working.
if [ -z "$gate" ] && [ "$declares_path" = 0 ]; then
  for cand in scripts/gate.sh app/scripts/gate.sh gate.sh; do
    [ -f "$cand" ] && { gate="$cand"; break; }
  done
fi
# A command is judged by the first word of the value — it declares the tool (`make`, `docker`, `npm`).
gate_word="$(printf '%s' "$gate_decl" | sed -E 's/^[[:space:]]*//; s/[[:space:]].*$//')"
gate_cmd=""
[ -z "$gate" ] && [ "$declares_path" = 0 ] && cmd_exists "$gate_word" && gate_cmd="$gate_decl"

if [ -n "$gate_cmd" ]; then
  # Both halves of the seam — the step set and the run frame — are judged by READING the gate file.
  # A command gives no file, and accepting it as converged would pass "did not look" off as
  # "converged": the unchecked is named, and the return code becomes "NOT ALL checked".
  skip "gate declared as the command '${gate_cmd}' — the engine-step call, the run frame and the default step set cannot be checked"
elif [ -z "$gate" ]; then
  # "Not named" and "named but did not resolve" are different project states, and the fix differs.
  # Merging them would repeat the very lie about an undeclared key that this branch was rewritten
  # for. Command resolution depends on the PATH of THE machine running the check — and that is named.
  if [ -n "$gate_decl" ] && [ "$declares_path" = 1 ]; then
    say "gate '${gate_decl}' declared, but there is no file at this address"
    fix "fix the path in gate_command or restore the gate file"
  elif [ -n "$gate_decl" ]; then
    say "gate '${gate_decl}' did not resolve: command '${gate_word}' is not in PATH on this machine"
    # Command resolution depends on the PATH of THE machine running the check, not the project's
    # machine: the same project gives a different answer on different machines, and that cannot go
    # unsaid.
    fix "check the name in gate_command or install the tool '${gate_word}' on the machine running the check"
  else
    say "project gate not found: the gate_command key is not set and there is no gate in the known places"
    fix "declare gate_command in $CONFIG or install the gate via the scaffold"
  fi
elif ! steps_called "$gate"; then
  say "gate '${gate}' does not call the engine steps — the distributed checks never execute in the project"
  # The name is in the file but no executable line — the most common way of switching off, and it
  # must be named separately: otherwise the owner looks for a vanished mention where it is in place.
  grep -q 'retainer-gate-steps\.sh' "$gate" \
    && printf '    the runner name is in the file, but only in an assignment, comment or message\n'
  fix 'restore the gate line: bash "$RETAINER_HOME/bin/retainer-gate-steps.sh" "$PROJECT_ROOT"'
  gate=""
elif ! frame_sourced "$gate"; then
  say "gate '${gate}' runs with its own copy of the frame — run fixes do not reach the project"
  # Nothing is claimed here about the CURRENT behaviour of the copy: it may be fresh or frozen a year
  # ago. The discrepancy is that from now on it is fixed by hand in this file, not by a plugin update.
  printf '    the copy lives its own life: the next run fix will land in the engine, but not here\n'
  fix 'source the frame: . "$RETAINER_HOME/bin/retainer-gate-frame.sh", declare steps via step'
fi

# ── 3. Hooks are wired and the set is in place ────────────────────────────────
# The box gate requires `core.hooksPath` EQUAL to `.githooks`; any other value turns the project
# gate red, and declaring it converged would contradict the project's own blocking rule.
HOOKS_DIR=".githooks"
# The required seams of the box. The rest is stack-dependent and is not part of the required set.
REQUIRED_HOOKS="pre-commit pre-push commit-msg"
HOOKS_SRC="$BOX/presets/python/githooks"
# A class switched off by the project in `[rigor]` is not required — but is not counted as converged
# either: "did not look" and "converged" stay different answers. Switching off silences the class
# WHOLE, including a dead hook and a hook outside the index: the project declared it does not use
# the `.githooks` directory, and a partial check inside a switched-off class would mix both answers
# in one.
if [ "$(cfg hooks_check rigor)" = false ]; then
  skip "hooks class not checked — disabled by the project in [rigor]: hooks_check = false"
elif ! command -v git >/dev/null 2>&1 || ! git rev-parse --git-dir >/dev/null 2>&1; then
  skip "directory is not a git repository — hook wiring not checked"
else
  # The LOCAL level is read: a globally set path would answer for a project with nothing wired.
  hooks_path="$(git config --local --get core.hooksPath || true)"
  same_dir=1
  [ -n "$hooks_path" ] && [ -d "$hooks_path" ] && [ "$hooks_path" -ef "$HOOKS_DIR" ] && same_dir=0
  if [ "$hooks_path" = "$HOOKS_DIR" ] && [ ! -d "$HOOKS_DIR" ]; then
    say "core.hooksPath is set correctly, but directory $HOOKS_DIR is missing — hooks never run"
    fix "create $HOOKS_DIR and put the box hooks there"
  elif [ "$same_dir" != 0 ]; then
    say "core.hooksPath = '${hooks_path:-unset}', but the box gate requires '${HOOKS_DIR}'"
    fix "git config core.hooksPath $HOOKS_DIR"
  elif [ ! -d "$HOOKS_SRC" ]; then
    skip "no hook set in the box ($HOOKS_SRC) — nothing to compare against"
  else
    # The REQUIRED seams are compared, not the whole directory: the project's hook set is its own,
    # and the box already decided that — the wiring is mirrored, not the list. A hook like a dev-server
    # restart depends on the stack and layout, and requiring it everywhere prescribes a dummy.

    # Delivery is read on the branch a CLONER receives, not in the index: a staged or unpushed seam
    # lies on the disk of one machine exactly like a seam outside the index. The resolution is the
    # engine's single one — a copy here would be its third place and would drift from the first two.
    clone_branch="$(retainer_clone_default_branch .)"
    delivery_remote="$(retainer_remote .)"
    # tree_has <ref> <path> — is the path in that tree: 0 — yes · 1 — no · 2 — could not tell.
    # The discriminator is "exit 0 AND non-empty output". An empty `git ls-tree` is produced both by
    # an honest "not there" and by a refusal, and merging the two repeats the class this whole check
    # exists against: the unverified handed out as converged.
    tree_has() {
      local out rc
      out="$(git ls-tree -r --name-only "$1" -- "$2" 2>/dev/null)"; rc=$?
      [ "$rc" = 0 ] || return 2
      [ -n "$out" ] || return 1
      return 0
    }
    missing_hooks=""; dead_hooks=""; loose_hooks=""; waived_hooks=""
    staged_hooks=""; unpushed_hooks=""; undelivered_unknown=""
    for hook in $REQUIRED_HOOKS; do
      # A seam missing from the box ITSELF would silently stop being required of every project at
      # once — a weakening visible to nobody. That is a box defect, and it is named.
      if [ ! -f "$HOOKS_SRC/$hook" ]; then
        skip "required seam $hook is missing from the box — nothing to require from the project"
        continue
      fi
      # A file's presence is not a seam: git silently does not run a hook without the +x bit, and an
      # empty file runs nothing. Both give a project where pre-commit is "in place" and never fires
      # — the same outcome as a missing hook, and it must be named as itself.
      if [ ! -f "$HOOKS_DIR/$hook" ]; then
        # A missing seam can be a DECISION, not an omission: the project has no fast linters, and a
        # preset installed on the check's advice would answer "passed" without checking — the
        # advice would worsen the state. The decision is read where it can be versioned — in the
        # project config, the `[hooks]` table, key = seam name, value = REASON. An empty value is
        # not a decision: "not required" without a reason is indistinguishable from a forgotten seam.
        waiver="$(cfg "$hook" hooks)"
        if [ -n "$waiver" ]; then
          waived_hooks="$waived_hooks$hook|$waiver
"
        else
          missing_hooks="$missing_hooks $hook"
        fi
      elif [ ! -s "$HOOKS_DIR/$hook" ] || [ ! -x "$HOOKS_DIR/$hook" ]; then
        dead_hooks="$dead_hooks $hook"
      # A seam outside the git index lies on the disk of ONE machine: neither a clone nor a second
      # contributor will have it, and a file-based check answers "converged" for a project that
      # will have no seams at all. "Rolled out here" and "reached the project" are different
      # statements, and the fix differs: `git add` versus `cp`. So the state is its own, not the
      # same as a missing one.
      elif ! git ls-files --error-unmatch "$HOOKS_DIR/$hook" >/dev/null 2>&1; then
        loose_hooks="$loose_hooks $hook"
      # Past the index two states remain, and they are not the same answer. A seam committed nowhere
      # travels with no clone at all; a seam committed on a working branch travels with none of the
      # clones a cloner actually makes. The fixes differ — `git commit` versus `git push` — so the
      # states are separate.
      elif ! git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
        # No HEAD at all: the repository holds no commit, so the seam is in the index and nowhere else.
        # Told apart from a failed read on purpose — here the absence is a FACT, not an unknown.
        staged_hooks="$staged_hooks $hook"
      else
        tree_has HEAD "$HOOKS_DIR/$hook"
        case $? in
          2) undelivered_unknown="$undelivered_unknown $hook" ;;
          1) staged_hooks="$staged_hooks $hook" ;;
          0)
            # The default branch is unresolvable for a project with no remote: delivery past the commit
            # has no axis there, and that goes to the "not checked" channel below rather than a verdict.
            if [ -n "$clone_branch" ]; then
              tree_has "$clone_branch" "$HOOKS_DIR/$hook"
              case $? in
                2) undelivered_unknown="$undelivered_unknown $hook" ;;
                1) unpushed_hooks="$unpushed_hooks $hook" ;;
              esac
            fi
            ;;
        esac
      fi
    done
    if [ -n "$dead_hooks" ]; then
      say "hooks are present but do not run (empty or without the +x bit):$dead_hooks"
      for hook in $dead_hooks; do
        fix "chmod +x $HOOKS_DIR/$hook   # and make sure the file is not empty"
      done
    fi
    if [ -n "$missing_hooks" ]; then
      say "$HOOKS_DIR lacks required hooks:$missing_hooks — the seams on these events never run"
      # ONLY the missing one is copied: the project has its own hooks in the same directory, and it
      # is in its `protected` — an "everything on top" fix would overwrite protected files.
      for hook in $missing_hooks; do
        fix "cp $HOOKS_SRC/$hook $HOOKS_DIR/$hook && chmod +x $HOOKS_DIR/$hook"
      done
    fi
    if [ -n "$loose_hooks" ]; then
      say "required hooks outside the git index:$loose_hooks — nobody will have them after a clone"
      for hook in $loose_hooks; do
        fix "git add $HOOKS_DIR/$hook"
      done
    fi
    if [ -n "$staged_hooks" ]; then
      say "required hooks staged but in no commit:$staged_hooks — a clone takes the branch, not the index"
      # The advice has to be EXECUTABLE in THIS project: where commit-msg is alive it demands DIGITS
      # after `#`, so a `#<task>` placeholder is rejected by the very seam the advice exists for. The
      # number comes from the project's own active-issue marker — local, offline, the task the project
      # works under. No marker — an explicit placeholder plus the instruction to replace it, so the
      # line does not look ready to paste.
      msg_note=""
      if [ -x "$HOOKS_DIR/commit-msg" ]; then
        issue="$(retainer_marker . active-issue)"
        msg_note=" -m '#${issue:-NNN} — box hooks under version'"
        [ -n "$issue" ] || msg_note="$msg_note   # replace NNN with the task number"
      fi
      for hook in $staged_hooks; do
        fix "git commit $HOOKS_DIR/$hook$msg_note"
      done
    fi
    if [ -n "$unpushed_hooks" ]; then
      say "required hooks committed but absent from $clone_branch:$unpushed_hooks — a cloner gets that branch"
      head_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
      if [ "$head_branch" = "${clone_branch#"$delivery_remote"/}" ]; then
        fix "git push $delivery_remote ${clone_branch#"$delivery_remote"/}"
      else
        # HEAD is a working branch, and `push HEAD:<default>` would carry its UNRELATED commits into
        # the branch a cloner receives, bypassing the project's own review. Measured on a side branch:
        # an unrelated file landed on the default branch together with the seam. So the route is named
        # instead of a command that would do it.
        fix "deliver $HOOKS_DIR to ${clone_branch#"$delivery_remote"/} by the project's own flow — HEAD is $head_branch, not the default branch"
      fi
    fi
    if [ -n "$undelivered_unknown" ]; then
      # Not a discrepancy: the tree could not be read, and "did not look" must not be dressed as
      # "not delivered" — that is the same false verdict with the sign flipped.
      skip "delivery of seams could not be read from git:$undelivered_unknown"
    fi
    if [ -z "$clone_branch" ]; then
      skip "the branch a cloner receives is unresolvable (no remote, or its HEAD is unset) — delivery past the commit not judged"
    fi
    # The reason is PRINTED: otherwise "converged" for a project without a seam would read as a
    # check oversight, and the config entry as a way to silence the check. It does not count as a
    # discrepancy and does not lower the completeness of the check: the class ran, an answer came.
    printf '%s' "$waived_hooks" | while IFS='|' read -r hook why; do
      [ -n "$hook" ] || continue
      printf '▶ seam %s is not required per the project record: %s\n' "$hook" "$why"
    done
  fi
fi

# ── 4. Steps absent from the project config ───────────────────────────────────
# Meaningful only where the gate CALLS these steps: otherwise the report would advise adding knobs
# that turn nothing.
#
# An undeclared key means DIFFERENT things for two kinds of step, and merging them into one line
# lies about one of them. An ordinary step without a key works: the runner default is "on". A
# self-gate step without a key is SILENT: it reads its own key and without a declaration exits
# having checked nothing. The first is advice, the second a discrepancy: the project has a check
# switched off, and it is switched off by silence.
# The condition of the two halves DIFFERS. An undeclared self-gate key is a fact about the config
# and holds for any gate shape: for a gate declared as a command it is not visible whether it calls
# the engine steps, and for a project whose gate demonstrably does NOT call them, all of them are
# off, and that finding is already named above. Advice about steps running by default stays with a
# readable gate: advising knobs not known to turn anything is advising at random.
if [ -f "$CONFIG" ] && { [ -n "$gate" ] || [ -n "$gate_cmd" ]; }; then
  unknown=""; undeclared=""; prosed=""
  # The step set is asked from the runner by its machine output, not read out of its source: parsing
  # a foreign file is a second parser of one intent. The row shape is checked, otherwise a runner
  # printing something else instead of the registry would become a source of step names. An empty
  # answer here is not "no steps" but "could not read".
  keys="$(bash "$HERE/retainer-gate-steps.sh" --list 2>/dev/null \
            | grep -E '^[a-z_][a-z0-9_]*\|' | cut -d'|' -f1)"
  # A step no key turns off is not a knob: naming it in [rigor] would be advice that changes nothing.
  always="$(bash "$HERE/retainer-gate-steps.sh" --list-always 2>/dev/null || true)"
  keys="$(printf '%s\n' "$keys" | grep -vxF -e "${always:-//}" || true)"
  [ -n "$keys" ] || skip "engine step registry not read — default set not named"
  # The list of self-gate steps is asked from the registry's OWNER, not derived here: a second
  # parse of the same signal would silently drift from the first. It counts as unread on TWO
  # signals — a runner refusal (does not know the mode, partial rollout) and an answer of the wrong
  # shape. An empty answer with a zero code is legitimate: the registry may hold no self-gate step.
  # That the answer itself agrees with the step code is guarded by the engine suite, not this command.
  if selfgate_raw="$(bash "$HERE/retainer-gate-steps.sh" --list-selfgate 2>/dev/null)"; then
    selfgate="$(printf '%s\n' "$selfgate_raw" | grep -E '^[a-z_][a-z0-9_]*$' || true)"
    # A non-empty answer from which no key of the right shape came out is "could not read". Silence
    # here would take away the whole class: a runner printing something else would pass undeclared
    # keys off as declared.
    if [ -n "$(printf '%s' "$selfgate_raw" | tr -d '[:space:]')" ] && [ -z "$selfgate" ]; then
      selfgate=""
      skip "self-gate step list came in the wrong shape — declaration of their keys not checked"
    fi
  else
    selfgate=""
    skip "self-gate step list not read — declaration of their keys not checked"
  fi
  for key in $keys; do
    [ -n "$key" ] || continue
    # "Declared" is judged by THE SAME reader the gate uses — the `[rigor]` table. A key above the
    # table or in a neighbouring one does not exist for the step, and accepting it as declared would
    # pass a silent step off as configured. An empty value is not a declaration: the step reads it
    # as undeclared and stays silent.
    [ -n "$(cfg "$key" rigor)" ] && continue
    if printf '%s\n' "$selfgate" | grep -qx "$key"; then
      if named_in_comment "$key"; then
        prosed="$prosed $key"
      else
        undeclared="$undeclared $key"
      fi
    else
      unknown="$unknown $key"
    fi
  done
  if [ -n "$undeclared" ]; then
    say "$CONFIG does not declare the keys of self-gate steps:$undeclared — these steps stay silent"
    printf '    Such a step reads its own key and without a declaration checks nothing: the project\n'
    printf '    has the check switched off, and it is off through config silence, not a decision.\n'
    fix "declare each in [rigor]: key = false — deliberately off, any other value — on.
             Append them all at once: retainer-migrate.sh $PWD --apply
             A key already present in the config empty or quoted is left alone by the command — the
             gate does not read it, and a second identical one beside it would make the config
             unreadable: edit by hand"
  fi
  if [ -n "$prosed" ]; then
    say "in $CONFIG the step decision is named in a comment, not a key:$prosed — the mechanism does not read it"
    printf '    Prose beside the table is read by a person, not by the step: it asks for the KEY and\n'
    printf '    stays silent without it. The decision exists and the check is off by silence — worse than either outcome.\n'
    fix "move the decision into a key for each one named:$prosed —
             for example \`$(printf '%s' "$prosed" | awk '{ print $1 }') = false\`. The same meaning, but the
             step sees it; the comment can stay beside it as the reason.
             Append them all at once: retainer-migrate.sh $PWD --apply"
  fi
  if [ -n "$gate" ] && [ -n "$unknown" ]; then
    printf '▶ steps absent from the project config (running by default):%s\n' "$unknown"
    printf '    Not a discrepancy: name them in [rigor] so the check set is visible.\n'
  fi
fi

# ── 5. The project working state is covered by ignore ─────────────────────────
# The class list lives in the box ONCE: the scaffold puts the same one into the new project's
# `.gitignore`. A scaffold fix reaches only NEW projects; existing ones stay uncovered silently —
# and it reaches them by one way only: this report line.
#
# ADVISORY: not counted as a discrepancy and does not raise the return code. The project has its own
# `.gitignore`, some paths are tied to its own mechanisms, and the command must not edit a foreign tree.
WORKSTATE="$BOX/presets/gitignore.workstate"

# The PATTERN itself is asked. The list holds the form — directories are written with a trailing
# slash, and on this form git's answer depends neither on the directory existing on disk nor on
# whether the ignore is set by this path or a parent one (measured). A directory name WITHOUT a slash
# gave a false "not covered" — so the form is declared in the list header, not propped up by a
# transformation here.
# Non-literal lines (negations, wildcards) are skipped: coverage is not asked for them.
workstate_gaps(){  # workstate_gaps <list file>
  gaps=""; tracked=""; local_only=""; seen=0
  # `|| [ -n "$pat" ]` is load-bearing: a file without a trailing newline otherwise silently loses
  # the LAST entry, and the class stays clean on it.
  while IFS= read -r pat || [ -n "$pat" ]; do
    case "$pat" in ''|'#'*|'!'*|*'*'*) continue ;; esac
    seen=$((seen + 1))
    # `--` is mandatory: a line starting with a dash would otherwise parse as a git option, and the
    # answer would silently be about the wrong path.
    src="$(git check-ignore -v -- "$pat" 2>/dev/null | cut -d: -f1)"
    case "$src" in
      '') ;;
      # A source that TRAVELS WITH THE CLONE is an ignore file inside the tree. `.git/info/exclude`
      # and the global ignore lie on the disk of ONE machine: the next contributor will carry the
      # state into a commit, and answering "covered" would repeat the class loose_hooks exists for.
      .git/*|/*) local_only="$local_only $pat"; continue ;;
      *) continue ;;
    esac
    # A path ALREADY in the index is not removed by ignore: `check-ignore` answers "not ignored" for
    # it even for an exact pattern, and the fix is different — remove from the index. Merging both
    # into one advice would suggest a fix that changes nothing.
    if git ls-files --error-unmatch -- "$pat" >/dev/null 2>&1; then
      tracked="$tracked $pat"
    else
      gaps="$gaps $pat"
    fi
  done < "$1"
  # A list that yielded no literal line is not "all covered": the file exists but there is no
  # subject to check. Silence here is indistinguishable from full coverage, which is exactly the
  # answer the script forbids itself in the header.
  [ "$seen" -gt 0 ] || { skip "working-state list is empty — nothing to check"; return 0; }
  [ -z "$gaps" ] || {
    printf '▶ working state not covered by ignore:%s\n' "$gaps"
    printf '    Not a discrepancy: the project has its own list. But `git add -A` from the root will carry them into\n'
    printf '    a commit, and they come back on every branch switch.\n'; }
  [ -z "$local_only" ] || {
    printf '▶ working state covered only locally:%s\n' "$local_only"
    printf '    Coverage lives in .git/info/exclude or the global ignore — it will not travel with a clone,\n'
    printf '    and for a second contributor these paths will be uncovered.\n'; }
  [ -z "$tracked" ] || {
    printf '▶ working state already under git version control:%s\n' "$tracked"
    # `-r` is needed: without it git refuses on a directory entry, and the list has them — advice
    # without the flag would be unexecutable exactly where it is needed most often.
    printf '    Ignore does not undo this — the path is already in the index: git rm -r --cached <path>\n'; }
  return 0
}

if [ ! -f "$WORKSTATE" ]; then
  # The list carries ONE advisory class, so its absence is "not checked", not a refusal of the whole
  # command: the step runner, without which it does refuse, carries two verdict classes.
  skip "no working-state list in the box ($WORKSTATE) — nothing to check"
elif ! command -v git >/dev/null 2>&1 || ! git rev-parse --git-dir >/dev/null 2>&1; then
  skip "directory is not a git repository — working-state ignore coverage not checked"
else
  workstate_gaps "$WORKSTATE"
fi

# ── 6. Project practices in place ─────────────────────────────────────────────
# The practices file is read by the cycle ROLES — plan check and review — not by the gate. So the
# class stands outside the project-gate condition: a tree without a recognised gate must still learn
# of the loss. Without the file both readers read emptiness on every run, and the mandatory-reading
# item executes to nothing.
#
# Whether the tree is Python the class does not ask — the decision and its return trigger are written
# where the file is placed: `bin/retainer-migrate.sh`, the `defer:` marker of the practices class.
PRACTICES=".retainer/practices.md"
PRACTICES_TPL="$BOX/presets/practices.md.template"
if [ ! -f "$PRACTICES_TPL" ]; then
  # A template missing from the box ITSELF would silently stop being required of every project at once.
  skip "no practices template in the box ($PRACTICES_TPL) — nothing to require from the project"
elif [ ! -f "$PRACTICES" ]; then
  say "project practices file missing ($PRACTICES) — cycle roles read emptiness"
  fix "place the template: retainer-migrate.sh $PWD --apply
             (by hand: substitute the project name in $PRACTICES_TPL and save as $PRACTICES)"
fi

# ── 7. Kit copies: stale or edited by the project ─────────────────────────────
# The list and the manifest are bin/retainer-migrate.sh's: the manifest keeps the hash of the box
# version last delivered. A copy equal to that hash and not to the box is stale — the project never
# touched it, and so is a copy with no line that equals a version the box once shipped
# (presets/kit-history); any other differing copy is the project's edit. An edit the box has nothing newer for
# is a note, not a discrepancy: the box version already lies beside it, and keeping the edit is the
# project's choice.
KIT_LIST="$BOX/presets/kit-copies"
MANIFEST=".retainer/manifest"
kit_sha(){ if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{ print $1 }'; }
if [ ! -f "$KIT_LIST" ]; then
  skip "no kit copy list in the box ($KIT_LIST) — kit copies not checked"
else
  unmanifested=""
  while read -r mode target src <&3; do
    case "$mode" in always|present) ;; *) continue ;; esac
    [ -f "$BOX/presets/$src" ] || { skip "kit copy $target: its box source presets/$src is missing"; continue; }
    m="$(awk -v p="$target" '$2 == p { print $1; exit }' "$MANIFEST" 2>/dev/null)"
    # migrate refuses a link, so a verdict here would ask for a fix that never comes.
    [ -L "$target" ] && { skip "kit copy $target is a symbolic link — migrate does not write through it"; continue; }
    if [ ! -e "$target" ]; then
      [ "$mode" = always ] && [ -z "$m" ] || continue
      case "$target" in */*) [ -d "${target%%/*}" ] || continue ;; esac
      say "kit copy $target is missing"
      fix "retainer-migrate.sh $PWD --apply installs it"
      continue
    fi
    [ -f "$target" ] && [ -r "$target" ] || { skip "kit copy $target is not a readable file"; continue; }
    b="$(kit_sha "$BOX/presets/$src")"; f="$(kit_sha "$target")"
    if [ "$f" = "$b" ]; then
      :
    elif { [ -n "$m" ] && [ "$f" = "$m" ]; } || { [ -z "$m" ] && awk -v h="$f" -v s="$src" \
           '$1 == h && $2 == s { found = 1 } END { exit !found }' "$BOX/presets/kit-history" 2>/dev/null; }; then
      say "kit copy $target is stale — untouched since the box delivered it, and the box has a newer version"
      fix "retainer-migrate.sh $PWD --apply replaces it"
    elif [ ! -f "$MANIFEST" ]; then
      unmanifested="$unmanifested $target"
    elif [ "$m" = "$b" ]; then
      printf '· kit copy %s is edited by the project, and the box has nothing newer\n' "$target"
    else
      say "kit copy $target is edited by the project, and the box has a newer version"
      fix "retainer-migrate.sh $PWD --apply keeps the edit and puts the box version beside it as $target.incoming"
    fi
  done 3< "$KIT_LIST"
  if [ -n "$unmanifested" ]; then
    say "kit copies differ from the box and there is no manifest ($MANIFEST) — stale and edited cannot be told apart:$unmanifested"
    fix "retainer-migrate.sh $PWD --apply records the manifest, keeps each differing copy and puts the box version beside it"
  fi
fi

[ -z "$unchecked" ] || printf '▶ not checked:%s\n' "$unchecked"
[ "$found" = 0 ] || {
  printf '  Discrepancies: %s. This command does not edit project files — the owner applies the fixes above.\n' "$found"
  exit 1; }
# The verdict is read by more than a human: the return code must tell "converged" from "not
# everything checked". Zero here would mean a confirmation that did not happen — and the command
# already sits in a flow where a machine reads it.
if [ -n "$unchecked" ]; then
  echo "✔ no discrepancies on the checked signals, but NOT EVERYTHING was checked — see above"
  exit 4
fi
echo "✔ project conforms to the box on all checked signals"
