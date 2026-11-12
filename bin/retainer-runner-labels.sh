#!/usr/bin/env bash
# retainer: the CI runner label is one per project and matches the declared one.
#
#   retainer-runner-labels.sh [project dir]
# exit 0 — job labels agree · 1 — a job with a foreign label
#      2 — usage or THE CHECK IS NOT WORKING · 3 — no targets: no workflows or nothing to compare against
#
# A label that no runner answers gives neither an error nor a red run: the job stays in the queue forever,
# no status is issued, the run looks like an ordinary pending one. A mechanism standing on such a workflow
# is turned off by one word, silently.
#
# WHY THE COMPARISON IS NOT AGAINST RUNNER REGISTRATION. Runners in the tracker are bound to a repository, and
# the registration file on the machine does not name the scope — only the server address. Folding the labels of all
# the machine's registrations into one set is wrong both ways: a neighbouring project's label
# counts as its own, and its own runner registered in the wrong dir counts as nonexistent.
# So what is known locally and exactly is compared: a label declared in the project config — all
# jobs must call it; no declaration — the jobs must call THE SAME ONE.
#
# WHAT THE CHECK DOES NOT KNOW: whether a live runner answers this label. That is a property of the tracker, not of the
# tree, and the answer needs network and administrator rights.
set -uo pipefail

DIR="${1:-.}"
[ -d "$DIR" ] || { echo "usage: retainer-runner-labels.sh [project dir]" >&2; exit 2; }
cd "$DIR" || exit 2

# What is judged is not the presence of awk but its working: the parse is the only data source of the check, and an awk
# that exists and fails would give an empty parse, indistinguishable from "the workflow has no jobs".
printf 'x\n' | awk '{ print }' >/dev/null 2>&1 || {
  echo "✗ CI runner label: awk does not work — the check is NOT working" >&2; exit 2
}

files=""
for f in .gitea/workflows/*.yml .gitea/workflows/*.yaml \
         .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -f "$f" ] && files="$files $f"
done
[ -n "$files" ] || { echo "▶ CI runner label: no workflows — nothing to check"; exit 3; }

# The parse goes by the key line, not by YAML as a whole: a parser of our own for a foreign format drifts
# silently. Three things must still be parsed, otherwise the check lies:
#   * a block scalar (`run: |`) — the engine workflow itself writes YAML in heredocs, and a line from there would
#     be a finding with a foreign address;
#   * a list on the following lines — a valid and not rare form, and silence on it reads as "clean";
#   * quotes, brackets and a trailing comment — otherwise the label is compared together with them.
labels_of() {
  awk '
    { indent = match($0, /[^ ]/) - 1; if (indent < 0) indent = 0 }
    inblock && /[^ ]/ && indent <= blockind { inblock = 0 }
    inblock { next }
    /:[ ]*[|>][-+0-9]*[ ]*$/ { inblock = 1; blockind = indent; next }
    {
      if (match($0, /^[ ]*runs-on:[ ]*/)) {
        value = substr($0, RSTART + RLENGTH)
        sub(/[ ]+#.*$/, "", value)
        gsub(/[][",]/, " ", value); gsub(/'"'"'/, " ", value)
        if (value ~ /[^ ]/) { print FILENAME ":" FNR "|" value; pending = 0 }
        else { pending = 1; pendind = indent }
        next
      }
      if (pending && /^[ ]*#/) next
      if (pending && /^[ ]*-[ ]*[^ ]/ && indent >= pendind) {
        value = $0
        sub(/^[ ]*-[ ]*/, "", value)
        sub(/[ ]+#.*$/, "", value)
        gsub(/[][",]/, " ", value); gsub(/'"'"'/, " ", value)
        print FILENAME ":" FNR "|" value
        next
      }
      if (pending && /[^ ]/) pending = 0
    }' "$@"
}

# The project declaration. If present, it is the truth: a job label is compared with it, and a substitution is caught
# even in a project with a single job.
DECLARED=""
[ -f .retainer/config.toml ] && DECLARED="$(awk '
  /^[[:space:]]*\[/ { inr = ($0 ~ /^[[:space:]]*\[ci\][[:space:]]*$/) }
  inr && /^[[:space:]]*runner_label[[:space:]]*=/ {
    sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); gsub(/["'"'"']/, "");
    gsub(/[[:space:]]/, ""); print; exit
  }' .retainer/config.toml 2>/dev/null)"

# An empty declaration is not the same as its absence: the project wrote the key, so it considers itself in
# strong mode. It is looked up IN ITS OWN section: a key that landed in a foreign one is "wrong section", not
# "empty", and sending someone to fix emptiness would send them the wrong way.
DECLARED_EMPTY=""
DECLARED_ELSEWHERE=""
if [ -f .retainer/config.toml ] && [ -z "$DECLARED" ]; then
  if awk '
      /^[[:space:]]*\[/ { inr = ($0 ~ /^[[:space:]]*\[ci\][[:space:]]*$/) }
      inr && /^[[:space:]]*runner_label[[:space:]]*=/ { found = 1 }
      END { exit !found }' .retainer/config.toml 2>/dev/null; then
    DECLARED_EMPTY=1
  elif grep -q '^[[:space:]]*runner_label[[:space:]]*=' .retainer/config.toml; then
    DECLARED_ELSEWHERE=1
  fi
fi

seen=""       # labels met in jobs
unjudged=""   # values that appear only at run time
found=0
checked=0
# shellcheck disable=SC2086  # $files is a path list, word splitting is intentional
while IFS='|' read -r where value; do
  [ -n "$value" ] || continue
  # An expression is judged WHOLE: `${{ matrix.runner }}` splits by spaces into three words, and a word-wise
  # parse would declare `matrix.runner` a label the project never declared.
  case "$value" in
    *'${{'*|*__*) unjudged="$unjudged $where"; continue ;;
  esac
  for label in $value; do
    checked=$((checked + 1))
    case " $seen " in *" $label "*) ;; *) seen="$seen $label" ;; esac
    [ -z "$DECLARED" ] && continue
    [ "$label" = "$DECLARED" ] && continue
    printf '✗ %s — label «%s», but the project declared «%s»\n' "$where" "$label" "$DECLARED"
    found=$((found + 1))
  done
done <<EOF
$(labels_of $files)
EOF

if [ -n "$unjudged" ]; then
  echo "▶ the label appears only at run time — check by eye:"
  for item in $unjudged; do printf '    %s\n' "$item"; done
  echo "  An expression or a template placeholder: what ends up there cannot be derived from here."
  echo "  A job with a foreign label neither fails nor starts — it waits for a runner that will not"
  echo "  come for it, and the run reads as pending. The mechanism on such a workflow is disabled silently."
fi

if [ "$found" != 0 ]; then
  echo "  A job with a foreign label neither fails nor starts: it waits for a runner that will not"
  echo "  come for it, and the run reads as pending. The mechanism on this workflow is disabled silently."
  exit 1
fi
[ "$checked" != 0 ] || { echo "▶ CI runner label: no job named a label — nothing to check"; exit 3; }

# No declaration — jobs are compared with each other. Diverging labels within one project mean the same
# thing: one of the jobs calls a runner that does not exist for the others.
if [ -z "$DECLARED" ]; then
  if [ -n "$DECLARED_EMPTY" ]; then
    echo "▶ the runner_label declaration exists but is empty — jobs are compared with each other"
  elif [ -n "$DECLARED_ELSEWHERE" ]; then
    echo "▶ runner_label is declared outside the [ci] section — jobs are compared with each other"
  fi
  count=0
  for label in $seen; do count=$((count + 1)); done
  if [ "$count" -gt 1 ]; then
    echo "✗ the project's jobs call different runners:$seen"
    labels_of $files | while IFS='|' read -r where value; do printf '    %s → %s\n' "$where" "$value"; done
    echo "  A job with a foreign label neither fails nor starts: it waits for a runner that will not"
    echo "  come for it, and the run reads as pending. The mechanism on this workflow is disabled silently."
    echo "  The label is declared once: runner_label in the [ci] section of the project config. Until it exists,"
    echo "  a divergence is visible only this way — by jobs not matching each other."
    exit 1
  fi
  [ "$checked" -gt 1 ] || {
    if [ -z "$DECLARED_EMPTY" ] && [ -z "$DECLARED_ELSEWHERE" ]; then
      echo "▶ CI runner label: there is one job and no declaration — nothing to compare against"
      echo "  Declare runner_label in the [ci] section of the project config, and a label substitution becomes visible."
    else
      echo "▶ CI runner label: there is one job, and the declaration is unreadable — nothing to compare against"
    fi
    exit 3; }
  if [ -n "$unjudged" ]; then
    echo "✔ judged jobs call one runner:$seen — for the rest see above"
  else
    echo "✔ the project's jobs call one runner:$seen"
  fi
  exit 0
fi
if [ -n "$unjudged" ]; then
  echo "✔ judged jobs match the declared «${DECLARED}» — for the rest see above"
else
  echo "✔ job labels match the declared «${DECLARED}»"
fi
