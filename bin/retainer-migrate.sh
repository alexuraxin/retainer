#!/usr/bin/env bash
# retainer: bring a managed tree up to the kit.
#
#   retainer-migrate.sh <project dir> [--apply]
# Default is a dry run: it only shows what would be done. `--apply` does the work.
# exit 0 -- nothing to bring up or all done · 1 -- work remains, not applied · 2 -- usage.
#
# The classes are independent, and a class with no subject does not end the command: moving an old
# state directory is needed by few, while missing keys and kit files are needed by everyone the
# scaffold missed. A class without a subject says so in a line and yields to the next one.
#
# The command does NOT edit the RULES FILE: it is under the guard and is edited by the owner. The
# command prints the exact replacements, which the owner applies.
#
# `--apply` WRITES INTO THE PROJECT STATE DIRECTORY AND INTO THE KIT COPIES (presets/kit-copies:
# the task template, preset scripts and configs, several of them on the project's protected list),
# and it is an owner step (sample: bin/adopt-managed-plugin.sh). The guard judges a command by its
# text and does not see a write from inside a script -- so honesty rests on these rules, not on
# protection:
#   · dry run by default, writing only on an explicit `--apply`;
#   · what is written is printed in a line, every edit named;
#   · an existing value and an existing file are never overwritten, save one kind: a kit copy the
#     project never edited -- its hash equals the manifest's line or, with no line, a version the
#     box once shipped (presets/kit-history);
#   · the regulator is appended with the value `false` -- disabled deliberately: enabling it on a
#     live tree turns the gate red for work the project did not order, and that is the project's
#     decision, not the command's.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BOX="$(cd "$HERE/.." && pwd)"

# Directory names come from the environment so a test can build a fixture without mentioning the real
# legacy name: the fixture then does not depend on which paths the guard cuts by command text.
LEGACY="${RETAINER_LEGACY_DIR:-.foreman}"   # the state directory name of early versions
LIVE="${RETAINER_STATE_DIR:-.retainer}"

DIR=""; APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    -*) echo "unknown argument: $1" >&2; exit 2 ;;
    *) [ -z "$DIR" ] && DIR="$1" || { echo "extra argument: $1" >&2; exit 2; }; shift ;;
  esac
done
[ -n "$DIR" ] && [ -d "$DIR" ] || { echo "usage: retainer-migrate.sh <project dir> [--apply]" >&2; exit 2; }
cd "$DIR" || exit 2

todo=0       # what is still to do
moved=0      # what this run ACTUALLY did
unchecked=0  # a class that could not be run: "not looked at" and "converged" are different answers

if [ ! -d "$LEGACY" ]; then
  echo "▶ move: no legacy directory $LEGACY -- nothing to move"
else   # ── class 1: moving the legacy directory, up to the "end of class 1" line ──
echo "── state move: $LEGACY → $LIVE ──"

# 1. PROJECT.md is the only file agents read by name. It is the one that gets stuck.
if [ -f "$LEGACY/PROJECT.md" ]; then
  if [ -f "$LIVE/PROJECT.md" ]; then
    if diff -q "$LEGACY/PROJECT.md" "$LIVE/PROJECT.md" >/dev/null 2>&1; then
      echo "  · PROJECT.md has already moved, the legacy copy is identical -- it can be deleted"
    else
      echo "  ✗ PROJECT.md is in BOTH directories and they DIFFER -- merge by hand, a machine cannot"
      diff "$LEGACY/PROJECT.md" "$LIVE/PROJECT.md" | head -20 | sed 's/^/      /'
      todo=$((todo + 1))
    fi
  elif [ "$APPLY" = 1 ]; then
    # The destination must be a DIRECTORY. If a file lies under that name, a bare `mv` would overwrite
    # it with the legacy copy -- the only path in the command able to lose data.
    if [ -e "$LIVE" ] && [ ! -d "$LIVE" ]; then
      echo "  ✗ $LIVE exists and is not a directory -- nowhere to move to, sort it out by hand"
      todo=$((todo + 1))
    elif ! mkdir -p "$LIVE"; then
      echo "  ✗ could not create $LIVE -- the move was not done"
      todo=$((todo + 1))
    elif git mv "$LEGACY/PROJECT.md" "$LIVE/PROJECT.md" 2>/dev/null; then
      echo "  ✓ PROJECT.md moved to $LIVE/ (under version control)"
      moved=$((moved + 1))
    elif mv "$LEGACY/PROJECT.md" "$LIVE/PROJECT.md"; then
      # git refused -- most often the destination is ignored. The file moved but dropped out of version
      # control; staying silent is not allowed: "moved" and "moved and visible to git" differ.
      echo "  ✓ PROJECT.md moved to $LIVE/"
      echo "    ⚠ git refused to move the file -- check whether the destination is under .gitignore"
      moved=$((moved + 1))
    else
      echo "  ✗ the PROJECT.md move was NOT done (no permission or a read-only filesystem)"
      todo=$((todo + 1))
    fi
  else
    todo=$((todo + 1))
    echo "  → PROJECT.md lies ONLY in $LEGACY/ -- move it to $LIVE/"
  fi
fi

# 2. What else remains in the legacy directory is the owner's call: the bypass log is merged, the config is usually dropped.
rest=""
for left in "$LEGACY"/* "$LEGACY"/.[!.]*; do
  [ -e "$left" ] || continue
  name="$(basename "$left")"
  [ "$name" = PROJECT.md ] && continue
  rest="$rest$name "
done
if [ -n "$rest" ]; then
  echo "  · left in $LEGACY/: $rest"
  echo "    (merge the bypass log into the new one, compare and delete the config; the owner decides)"
fi

# 3. References in instructions. The owner edits them -- the rules file is under the guard; the command gives the exact list.
# We search for the legacy directory NAME, not a hardcoded string: the name is parameterized, and a
# hardcoded search silently found zero references in any project that named the directory otherwise.
OLDNAME="$(basename "$LEGACY" | sed 's/^\.//')"
echo
echo "── references to the old name ($OLDNAME) in instructions ──"
hits=0
for doc in CLAUDE.md AGENTS.md "$LIVE/PROJECT.md" "$LEGACY/PROJECT.md"; do
  [ -f "$doc" ] || continue
  # grep -c prints 0 AND returns 1 on "not found"; `|| echo 0` would append a SECOND zero and the
  # comparison broke on a multi-line value. Take the first line and substitute zero only if empty.
  n="$(grep -c -i "$OLDNAME" "$doc" 2>/dev/null | head -1)"
  n="${n:-0}"
  [ "$n" -gt 0 ] || continue
  hits=$((hits + n))
  printf '  %s: lines mentioning it -- %s\n' "$doc" "$n"
  grep -n -i "$OLDNAME" "$doc" | head -5 | sed 's/^/      /'
done
if [ "$hits" -gt 0 ]; then
  todo=$((todo + 1))
  echo
  echo "  Replacements (made by the OWNER -- the rules file is under the guard, the agent does not touch it):"
  printf '    ~/%s/  → ~/retainer/            (engine directory in the home folder)\n' "${LEGACY#.}"
  printf '    %s/    → %s/          (state directory in the project: PROJECT.md, config, log)\n' "$LEGACY" "$LIVE"
  printf '    ~/%s/  → ~/%s/        (home state directory: the unlock key)\n' "$LEGACY" "$LIVE"
  printf '    "plugin %s" → "plugin retainer" (and all other mentions of the name in prose)\n' "$OLDNAME"
  echo  "  Replace by DIRECTORY, not by single files: otherwise references to the config and log remain."
else
  echo "  clean"
fi
fi   # ── end of class 1 ──

# ── 4. Selfgate step keys are declared ────────────────────────────────────────
# A step that reads its own key stays SILENT without a declaration: the runner default "enabled" does
# not enable it. Keys arrive by scaffold only to a NEW project, and an existing tree lives with silent
# steps until the key is written by hand.
CONFIG="$LIVE/config.toml"
STEPS_SH="$HERE/retainer-gate-steps.sh"

# The regulator is read THE SAME WAY the gate reads it: only inside the `[rigor]` table whose header
# stands alone on its line. A key above the table, in a neighboring table or under a header of another
# form does not exist for the step, and counting it as declared would append nothing where the step
# is silent.
#
# The VALUE is printed, while the exit code speaks about the key line itself: "no key" and "key
# present with an empty value" are different project states with different fixes. The gate reads an
# empty value as the default, a selfgate step as undeclared, and a second identical key cannot be
# appended beside it: the config would stop parsing entirely.
rigor_read(){  # rigor_read <key> -> value on stdout, 0 -- the key line exists
  [ -f "$CONFIG" ] && [ -r "$CONFIG" ] || return 1
  awk -v key="$1" '
    /^[[:space:]]*\[/ { inr = ($0 ~ /^[[:space:]]*\[rigor\][[:space:]]*$/) }
    inr && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
      sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, "")
      gsub(/["'"'"']/, ""); gsub(/[[:space:]]/, "")
      print; found = 1; exit
    }
    END { exit (found ? 0 : 1) }' "$CONFIG"
}

# Appending the table is a FUNCTION: on the system bash 3.2.57 negating a compound command loses the
# failure of its redirection -- `! { ... } >> unwritable_file` does not fire at all. A function call
# keeps the failure, and the branch guard stays alive. The form was checked on this machine.
append_rigor_table(){  # append_rigor_table <keys separated by spaces>
  # `local key` is load-bearing for the next edit: five loops in this file use the name `key`, and a
  # function call from inside such a loop would clobber the variable in the same iteration.
  local key
  printf '\n[rigor]\n'
  for key in $1; do
    printf '%-18s = false   # not declared by the scaffold: the step requires a declaration\n' "$key"
  done
}

# THE TABLE FORM DECIDES whether the command writes or prints. Writing goes only where parsing is
# reliable: exactly one `[rigor]` header on its own line (the gate requires the same form) and no
# declaration of the same table in another spelling. Anything else is printed as text, like edits to
# the rules file: a key appended past the parser makes the config invalid, and the guard on an
# unreadable config returns an EMPTY protected list -- the project is left unprotected and does not say so.
rigor_form(){  # prints plain · none · odd
  local heads others
  # Config readability is judged BEFORE entering the class, at the only caller: an unreadable file is
  # not "no table", and the create branch would append a second table where the first exists and is
  # merely unread. A second guard here would be unreachable.
  heads="$(grep -cE '^[[:space:]]*\[rigor\][[:space:]]*$' "$CONFIG")"
  # Other spellings of the SAME table: a header with a trailing comment or spaces inside the brackets,
  # a quoted name, a subtable `[rigor.<something>]`, a dotted key `rigor.<step>` (quoted too).
  # Anchored on the table NAME, not on a substring occurrence: `[rigorous_notes]` is another table,
  # and refusing on it would be advice that cannot be followed.
  others="$(grep -cE '^[[:space:]]*(\[[[:space:]]*["'"'"']?rigor["'"'"']?[[:space:]]*(\]|\.)|["'"'"']?rigor["'"'"']?[[:space:]]*\.)' "$CONFIG")"
  if [ "$others" -gt "$heads" ] || [ "$heads" -gt 1 ]; then printf 'odd'
  elif [ "$heads" = 1 ]; then printf 'plain'
  else printf 'none'
  fi
}

# A quoted key is valid TOML that neither the gate nor this command reads. Appending a plain one
# beside it would declare one key twice: the config stops parsing entirely.
key_in_quotes(){  # key_in_quotes <key>
  awk -v key="$1" '
    /^[[:space:]]*\[/ { inr = ($0 ~ /^[[:space:]]*\[rigor\][[:space:]]*$/); next }
    inr && $0 ~ ("^[[:space:]]*[\"'"'"']" key "[\"'"'"'][[:space:]]*=") { found = 1; exit }
    END { exit (found ? 0 : 1) }' "$CONFIG"
}

sha256_of(){  # sha256_of <file> -> hex digest; sha256sum on Linux, shasum on macOS
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{ print $1 }'
}

echo
if [ ! -f "$CONFIG" ] || [ ! -r "$CONFIG" ]; then
  # The classes cannot be run, and the verdict must carry that: a tree that lost its config would
  # otherwise report converged with the kit, merging "not looked at" with "converged".
  # THREE classes are skipped, and the counter names them all: a smaller number would be wrong.
  if [ ! -f "$CONFIG" ]; then
    echo "▶ bring-up: no config $CONFIG -- the tree is not managed by the kit"
  else
    echo "▶ bring-up: config $CONFIG is unreadable -- no read permission"
  fi
  echo "    classes skipped: selfgate step declaration, practices file, kit copies"
  unchecked=$((unchecked + 3))
else
  echo "── selfgate step declaration ──"
  # The list is asked of the registry OWNER and checked BY SHAPE, not by exit code: a runner printing
  # something other than the registry would otherwise become a source of names that this command
  # writes into the project's protected file. The key shape is closed by the same alphabet as the registry's.
  selfgate_raw="$(bash "$STEPS_SH" --list-selfgate 2>/dev/null)" || selfgate_raw=""
  selfgate="$(printf '%s\n' "$selfgate_raw" | grep -E '^[a-z_][a-z0-9_]*$' || true)"
  if [ -n "$(printf '%s' "$selfgate_raw" | tr -d '[:space:]')" ] && [ -z "$selfgate" ]; then
    echo "  ✗ the selfgate step list came in a foreign shape -- it cannot be read, update the plugin"
    todo=$((todo + 1))
    unchecked=$((unchecked + 1))
  elif [ -z "$selfgate_raw" ] && ! bash "$STEPS_SH" --list-selfgate >/dev/null 2>&1; then
    echo "  ✗ the selfgate step list was not read ($STEPS_SH is missing alongside) -- the rollout is incomplete"
    todo=$((todo + 1))
    unchecked=$((unchecked + 1))
  else
    missing=""; quoted=""; empty=""
    for key in $selfgate; do
      if value="$(rigor_read "$key")"; then
        [ -n "$value" ] && continue
        empty="$empty $key"
      elif key_in_quotes "$key"; then
        quoted="$quoted $key"
      else
        missing="$missing $key"
      fi
    done
    [ -z "$quoted" ] || {
      printf '  ✗ keys are written in quotes, and neither the gate nor this command reads such an entry:%s\n' "$quoted"
      printf '      remove the quotes by hand: appending a plain key beside it declares it twice,\n'
      printf '      and the config stops parsing entirely\n'
      todo=$((todo + 1))
    }
    [ -z "$empty" ] || {
      printf '  ✗ keys stand in the config with an EMPTY value, and a selfgate step reads them as undeclared:%s\n' "$empty"
      printf '      write a value by hand (false -- disabled deliberately): a second identical key beside it\n'
      printf '      would declare it twice, and the config would stop parsing\n'
      todo=$((todo + 1))
    }
    form="$(rigor_form)"
    # "All declared" is said only where no problem remains: a line beside a list of problem keys
    # would contradict itself.
    if [ -z "$missing" ] && [ -z "$quoted" ] && [ -z "$empty" ]; then
      echo "  · all selfgate steps are declared"
    elif [ -z "$missing" ]; then
      :
    elif [ "$form" = odd ]; then
      # The table form is not the one the gate reads: writing here would either double the table or land
      # where nobody reads it. We print the edit -- the owner applies it and normalizes the form.
      printf '  ✗ the [rigor] table is declared in a form the gate does not read -- not writing.\n'
      printf '      Bring the header to the form "[rigor]" on its own line (without a trailing\n'
      printf '      comment and without dotted rigor.<step> keys) and write:\n'
      for key in $missing; do printf '        %-18s = false\n' "$key"; done
      todo=$((todo + 1))
    elif [ "$APPLY" = 1 ]; then
      tmp="$CONFIG.migrate.tmp"
      nkeys=0
      for key in $missing; do nkeys=$((nkeys + 1)); done
      # A write counts as successful only if EVERY step of it succeeded. Otherwise the write report rests
      # on what the command meant to do: halfway through the pour the keys already stand in the file, the
      # table form is intact, and the per-key check honestly confirms them -- over a config that lost its tail.
      write_ok=1
      # The key goes INSIDE the table: appended to the file end, it would land in the config's last table
      # (in the kit template `[ci]` follows `[rigor]`), and the gate would not read it.
      # Columns are aligned to the canon of live configs -- a human reads and edits the file.
      if [ "$form" = plain ]; then
        # Assembly and pour are TIED by a check: `> "$CONFIG"` truncates the file first, and an aborted
        # assembly would leave the project config truncated. The builder's exit code is guarded by a
        # case (read-only state directory), the length invariant is not: an input where the builder
        # returns zero AND truncated output cannot be built as a fixture. The line stays deliberately:
        # the class "silently shortened the project's protected file" costs more than one uncovered
        # check, and appending lines cannot shorten a file in any correct run.
        if awk -v keys="$missing" '
             { print }
             /^[[:space:]]*\[rigor\][[:space:]]*$/ && !inserted {
               n = split(keys, k, " ")
               for (i = 1; i <= n; i++) {
                 if (k[i] != "") printf "%-18s = false   # not declared by the scaffold: the step requires a declaration\n", k[i]
               }
               inserted = 1
             }' "$CONFIG" > "$tmp" \
           && [ "$(grep -c "" "$tmp")" -ge "$(( $(grep -c "" "$CONFIG") + nkeys ))" ]; then
          # The content is poured INTO THE SAME file, not replaced by it: `mv` would drop the access mode
          # (a config may be 600) and replace a symlink with a regular file.
          if cat "$tmp" > "$CONFIG"; then
            rm -f "$tmp"
          else
            write_ok=0
            printf '  ✗ the pour failed; the assembled config is left in %s\n' "$tmp"
          fi
        else
          write_ok=0
          printf '  ✗ the new config was not assembled -- the project file is untouched (draft: %s)\n' "$tmp"
        fi
      elif ! append_rigor_table "$missing" >> "$CONFIG"; then
        # Appending to the file end has no draft: if aborted, it leaves a stub of a line in the config.
        # So the exit code is load-bearing here -- it is the only thing that will tell.
        write_ok=0
        printf '  ✗ the [rigor] table was appended incompletely -- a line stub may remain in the config\n'
      fi
      # EVERY key and the table form are checked after the write: checking only the first key accepted
      # as success a write after which the config stopped parsing.
      # EVERY key is checked: there is no discriminating input between "first key" and "all" with the
      # current write mechanics (an aborted assembly loses the first one too), so the mutation "check
      # only the first" survives the suite. The check rests not on a case but on an invariant: the write
      # report must rest on what was read, not on what the command meant to write.
      written=""; failed=""
      for key in $missing; do
        [ -n "$(rigor_read "$key")" ] && written="$written $key" || failed="$failed $key"
      done
      if [ -z "$failed" ] && [ "$(rigor_form)" = plain ] && [ "$write_ok" = 1 ]; then
        printf '  ✓ appended to [rigor] with the value false:%s\n' "$written"
        moved=$((moved + 1))
      else
        printf '  ✗ the write was NOT COMPLETE (not appended:%s) -- check the config by hand\n' "${failed:- —}"
        todo=$((todo + 1))
      fi
    else
      todo=$((todo + 1))
      printf '  → [rigor] lacks selfgate step keys:%s -- append with the value false\n' "$missing"
    fi
  fi

  # ── 5. The project practices file ───────────────────────────────────────────
  # The practices are read by the cycle ROLES -- plan check and review. Without the file both read
  # emptiness, and the mandatory-reading item executes to nothing.
  # defer: the tree's Python-ness is not asked, upgrade: when a non-Python project lands under the kit
  PRACTICES="$LIVE/practices.md"
  PRACTICES_TPL="$BOX/presets/practices.md.template"
  echo "── project practices ──"
  if [ -f "$PRACTICES" ]; then
    echo "  · the practices file is in place -- untouched"
  elif [ ! -f "$PRACTICES_TPL" ]; then
    echo "  ✗ no practices template in the kit ($PRACTICES_TPL) -- nothing to put"
    todo=$((todo + 1))
  elif [ "$APPLY" = 1 ]; then
    # The project name is substituted into the template heading. Replacement metacharacters are escaped:
    # a directory name with an ampersand would otherwise write the matched text into the document instead of itself.
    NAME="$(basename "$(pwd)")"
    NAME_ESC="$(printf '%s' "$NAME" | sed 's/[&/\]/\\&/g')"
    if sed "s/<PROJECT>/$NAME_ESC/g" "$PRACTICES_TPL" > "$PRACTICES"; then
      echo "  ✓ practices template put in place: $PRACTICES"
      moved=$((moved + 1))
    else
      rm -f "$PRACTICES"
      echo "  ✗ the practices file was NOT written (no permission or a read-only filesystem)"
      todo=$((todo + 1))
    fi
  else
    todo=$((todo + 1))
    echo "  → no practices file ($PRACTICES) -- put the kit template"
  fi

  # ── 6. Kit copies, brought forward by the install-hash manifest ─────────────
  # A copy alone cannot say whose its difference is. The manifest holds the hash of the box version
  # last delivered to the project: a copy equal to it is untouched and is replaced; any other copy is
  # the project's edit, kept, with the new box version put beside it as <file>.incoming. A copy with
  # no manifest line -- every copy of a tree from before the manifest -- is untouched only if it
  # equals a version the box once shipped (presets/kit-history); otherwise it counts as edited, so
  # the first update overwrites nothing the project wrote. The .incoming is left untracked on
  # purpose: git status is where the project sees it.
  KIT_LIST="$BOX/presets/kit-copies"
  KIT_HISTORY="$BOX/presets/kit-history"
  MANIFEST="$LIVE/manifest"
  echo "── kit copies ──"
  if [ ! -f "$KIT_LIST" ]; then
    echo "  ✗ no kit copy list in the box ($KIT_LIST) -- copies not checked"
    unchecked=$((unchecked + 1))
  else
    lines=""; n_inst=0; n_repl=0; n_beside=0; n_left=0; kit_dirty=0; m_new=""
    # fd 3: a command in the loop body that reads stdin would otherwise eat the list.
    while read -r mode target src <&3; do
      case "$mode" in always|present) ;; *) continue ;; esac
      box_copy="$BOX/presets/$src"
      if [ ! -f "$box_copy" ]; then
        echo "  ✗ $target: its box source presets/$src is missing -- not checked"
        unchecked=$((unchecked + 1)); continue
      fi
      b="$(sha256_of "$box_copy")"
      m="$(awk -v p="$target" '$2 == p { print $1; exit }' "$MANIFEST" 2>/dev/null)"
      act=""
      if [ -L "$target" ] || [ -L "$target.incoming" ]; then
        # A write through a link lands outside the project, possibly in the box itself.
        echo "  ✗ $target: a symbolic link -- not written through, not checked"; unchecked=$((unchecked + 1))
      elif [ ! -e "$target" ]; then
        # Installed only where the copy's top directory is already there: a `.gitea/` copy has no
        # business in a tree whose tracker is another one.
        [ "$mode" = always ] || continue
        case "$target" in */*) [ -d "${target%%/*}" ] || continue ;; esac
        if [ -n "$m" ]; then
          echo "  · $target: removed by the project -- left alone"; n_left=$((n_left + 1))
        else act=install
        fi
      elif [ ! -f "$target" ] || [ ! -r "$target" ]; then
        echo "  ✗ $target: not a readable file -- not checked"; unchecked=$((unchecked + 1))
      else
        f="$(sha256_of "$target")"
        if [ "$f" = "$b" ]; then
          m_new="$b"
        elif [ -n "$m" ] && [ "$f" = "$m" ]; then act=replace
        elif [ -z "$m" ] && awk -v h="$f" -v s="$src" '$1 == h && $2 == s { found = 1 } END { exit !found }' "$KIT_HISTORY" 2>/dev/null
        then act=replace
        elif [ "$m" = "$b" ]; then
          echo "  · $target: edited by the project, the box has nothing newer -- left alone"; n_left=$((n_left + 1))
        else act=beside
        fi
      fi
      # What the manifest keeps for this path: the old line unless a delivery below succeeds.
      m_new="${m_new:-$m}"
      case "$act" in
        replace) [ -n "$m" ] && why="untouched since the last install" || why="equals a version the box once shipped, never edited" ;;
        beside)  [ -n "$m" ] && why="edited since the last install" || why="differs from every box version, no install recorded -- taken as the project's edit" ;;
      esac
      if [ -n "$act" ] && [ "$APPLY" != 1 ]; then
        todo=$((todo + 1))
        case "$act" in
          install) echo "  → $target: absent -- install the box version" ;;
          replace) echo "  → $target: $why -- replace with the new box version" ;;
          beside)  echo "  → $target: $why -- keep it, put the box version beside as $target.incoming" ;;
        esac
      elif [ -n "$act" ]; then
        case "$act" in
          install) mkdir -p "$(dirname "$target")" && cp "$box_copy" "$target" ;;
          replace) cat "$box_copy" > "$target" ;;   # poured into the same file: the mode bit stays
          beside)  cp "$box_copy" "$target.incoming" ;;
        esac
        if [ $? = 0 ]; then
          m_new="$b"; moved=$((moved + 1))
          case "$act" in
            install) echo "  ✓ $target: installed"; n_inst=$((n_inst + 1)) ;;
            replace) echo "  ✓ $target: replaced -- $why"; n_repl=$((n_repl + 1)) ;;
            beside)  echo "  ✓ $target: $why -- kept, the box version put beside as $target.incoming"
                     n_beside=$((n_beside + 1)) ;;
          esac
        else
          echo "  ✗ $target: the $act was NOT done (no permission or a read-only filesystem)"; todo=$((todo + 1))
        fi
      fi
      [ "$m_new" = "$m" ] || kit_dirty=1
      [ -z "$m_new" ] || lines="$lines$m_new  $target
"
      m_new=""
    done 3< "$KIT_LIST"
    if [ "$kit_dirty" = 1 ] && [ "$APPLY" != 1 ]; then
      todo=$((todo + 1)); echo "  → the manifest $MANIFEST is behind the copies -- record it"
    elif [ "$kit_dirty" = 1 ]; then
      if { printf '# sha256 of the box version last delivered to this project -- written by retainer-migrate.sh\n'
           printf '%s' "$lines"; } > "$MANIFEST"; then
        echo "  ✓ manifest written: $MANIFEST"
      else
        echo "  ✗ the manifest was NOT written -- the next update takes every copy as edited"; todo=$((todo + 1))
      fi
    fi
    [ "$APPLY" != 1 ] || printf '  kit copies: installed %s · replaced %s · kept with an incoming version %s · left alone %s\n' \
      "$n_inst" "$n_repl" "$n_beside" "$n_left"
  fi
fi

echo
if [ "$todo" -eq 0 ]; then
  if [ "$unchecked" -gt 0 ]; then
    printf '▶ nothing to bring up in what was checked, but NOT EVERYTHING was checked (classes skipped: %s) -- see above\n' "$unchecked"
  elif [ "$moved" -gt 0 ]; then
    printf '▶ items done: %s. The tree converges with the kit\n' "$moved"
  else
    echo "▶ nothing to bring up: the tree converges with the kit"
  fi
  exit 0
fi
# "Done" and "remaining" are different counters. A "move done" report on --apply regardless of the
# outcome, even when moving was impossible (copies diverged) or pointless (only references in
# instructions remain), is a "done" report without a fact -- exactly what this whole tool is written against.
if [ "$APPLY" = 1 ]; then
  [ "$moved" -gt 0 ] && echo "▶ items done: $moved. Remaining (items: $todo) -- see above" \
                     || echo "▶ nothing moved. Remaining (items: $todo) -- see above"
  exit 1
fi
echo "▶ dry run, nothing changed. To apply: retainer-migrate.sh $DIR --apply"
exit 1
