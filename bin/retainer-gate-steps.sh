#!/usr/bin/env bash
# retainer: ENGINE gate steps — one entry point for a project.
# A project gate is a copy of a template taken at some point; so the step set is kept HERE, otherwise a new
# step needs a manual gate edit in every project and never reaches them.
#
#   retainer-gate-steps.sh [project dir]
# exit 0 — enabled steps passed · 1 — some failed OR no step found any targets · 2 — usage.
# Code 3 does NOT leave this script: project gates call it under `set -e`, and their contract is 0/1/2.
# STEP contract: 0 — targets existed, clean · 1 — targets existed, violations · 2 — usage or
# the check is broken · 3 — no targets, nothing to check in this root.
# A step regulator is read from the PROJECT config `[rigor]`: `false` disables, anything else enables.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# The frame for foreign output lives next to the guard — one home per engine. No file
# (incomplete rollout) — output is printed as before: the frame is a provenance mark, not a
# condition of gate operation, and failing the gate over its absence would be worse than printing without it.
FRAME="$(cd "$HERE/.." && pwd)/hooks/untrusted.py"

DIR="${1:-.}"
case "$DIR" in
  --list|--list-selfgate|--list-always) ;;
  *) [ -d "$DIR" ] || {
       echo "usage: retainer-gate-steps.sh [project dir | --list | --list-selfgate | --list-always]" >&2
       exit 2; } ;;
esac

CONFIG=".retainer/config.toml"
rigor() {  # rigor <key> <default> — the [rigor] section of the project config
  local key="$1" def="$2" val=""
  [ -f "$CONFIG" ] && val="$(awk -v k="$key" '
    /^[[:space:]]*\[/ { inr = ($0 ~ /^[[:space:]]*\[rigor\][[:space:]]*$/) }
    inr && $0 ~ ("^[[:space:]]*" k "[[:space:]]*=") {
      sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); gsub(/["'"'"']/, ""); gsub(/[[:space:]]/, "");
      print; exit
    }' "$CONFIG" 2>/dev/null)"
  printf '%s' "${val:-$def}"
}

# STEP REGISTRY: regulator key · title · script · `selfgate` on a step that requires
# DECLARING its key and is silent without it. Add a step = add a line here.
# The list is also read by the registry-reconciliation test — a regulator forgotten in the config or on the settings page is caught by it.
# The selfgate marker lives HERE, not at each consumer: the conformance check and migration
# ask the registry owner, and no second list of selfgate steps appears in the tree.
# A marked step must itself tell the operator WHAT to declare: its script contains the line
# "key <key> in [rigor]" — the suite uses it to check the registry marker and the step code have not drifted.
# `always` marks a step no key turns off: it is not a regulator, the project config does not name it,
# and a `false` in [rigor] under its name changes nothing. It must stay silent without a subject (code 3).
STEPS="
doc_links|dead links in instructions|retainer-doc-links.sh
agent_canon|cycle role canon|retainer-agent-canon.sh
protected_copy|copies of protected files|retainer-protected-copy.sh
bypass_alert|repeated pushes against the guard|retainer-bypass-alert.sh
hot_context|volume of mandatory reading|retainer-hot-context.sh
remote_creds|credentials in the remote address|retainer-remote-creds.sh
skills_catalog|skills catalog matches the tree|retainer-skills-catalog.sh
dependency_check|dependency manifest matches the lock|retainer-dependency-check.sh
deny_sync|protected and deny registries match|retainer-deny-sync.sh
doc_claims|marked document claims|retainer-doc-claims.sh
runner_labels|one CI runner label per project|retainer-runner-labels.sh
complexity_trace|trace of the complexity decision for a new component|retainer-complexity-trace.sh
prose_lang|code prose language|retainer-prose-lang.sh|selfgate
prose_content|narrative in code prose|retainer-prose-content.sh|always
prototype_debt|prototype debt marked in code|retainer-prototype-debt.sh|selfgate
glossary_terms|code term defined in the glossary|retainer-glossary-terms.sh|selfgate
practices_form|project practices record form|retainer-practices-check.sh
"

# `--list` prints the registry machine-readably: lines `key|title|script` plus `|selfgate` on a step
# that requires declaring. Parsing the registry in foreign code otherwise becomes a second parser of one
# intent, and they drift silently — one sees the key, the other does not, and the set of checks
# reads differently.
if [ "$DIR" = --list ]; then
  printf '%s\n' "$STEPS" | sed '/^[[:space:]]*$/d'
  exit 0
fi
# `--list-selfgate` answers one question: which steps require declaring the key. The registry owner
# answers it, because there are two consumers — conformance and migration — and identical
# parsing of the fourth field in each would drift silently.
if [ "$DIR" = --list-selfgate ]; then
  printf '%s\n' "$STEPS" | awk -F'|' '$4 == "selfgate" { print $1 }'
  exit 0
fi
# `--list-always` answers which steps are not regulators: a consumer that lists the knobs subtracts them.
if [ "$DIR" = --list-always ]; then
  printf '%s\n' "$STEPS" | awk -F'|' '$4 == "always" { print $1 }'
  exit 0
fi
cd "$DIR" || exit 2

failed=0
ran=0
clean=0
empty=0
excused=0
missing=0
while IFS='|' read -r key title script mark; do
  [ -n "$key" ] || continue
  [ "$mark" != always ] && [ "$(rigor "$key" true)" = "false" ] && continue
  path="$HERE/$script"
  if [ ! -f "$path" ]; then
    # Step declared, script absent (incomplete update). Staying silent is not allowed: "enabled" and "working" would diverge.
    printf '  (engine has no %s — update the plugin; step "%s" skipped)\n' "$script" "$title"
    missing=$((missing + 1))
    continue
  fi
  printf '▶ R: %s\n' "$title"
  ran=$((ran + 1))
  # The step title is OUR text and is printed outside; step output contains lines from the checked
  # files and goes to the agent IN A FRAME. A foreign log line or file name written in the form of
  # an instruction is otherwise indistinguishable from an owner instruction. The frame marks provenance, it is not a censor.
  step=0; out="$(bash "$path" . 2>&1)" || step=$?
  if [ -n "$out" ] && [ -x "$FRAME" ]; then
    printf '%s' "$out" | python3 "$FRAME" "gate step · $key"; printf '\n'
  else
    printf '%s\n' "$out"
  fi
  # `case`, not `||`: "no targets" (3) must differ from "checked, clean" (0), otherwise the summary
  # goes green on a wrong root. An unknown code goes to failed ON PURPOSE:
  # without this branch the mutant `3 → 4` falls into the default and survives the suite.
  case "$step" in
    0) clean=$((clean + 1)) ;;
    3) empty=$((empty + 1)); [ "$mark" = always ] && excused=$((excused + 1)) ;;
    1) failed=$((failed + 1)) ;;
    *) failed=$((failed + 1)); printf '  (step "%s" returned %s — counting as failed)\n' "$title" "$step" ;;
  esac
done <<EOF
$STEPS
EOF

# Failing on violations is the prior behavior, KEPT and goes first. The tail is appended, not
# rewritten: the test checks the substring "failed: N of M" via grep -qF.
if [ "$failed" -ne 0 ]; then
  printf '✗ engine gate steps failed: %s of %s · checked %s · not applicable %s\n' \
    "$failed" "$ran" "$clean" "$empty" >&2
  exit 1
fi

# New failure: no targets found for ANY enabled step. Two conditions beyond equality, and both are
# needed so the message does not lie about the cause:
#   `ran > excused` — with all regulators off only `always` steps run, and their "nothing added"
#                   (3) says nothing about the address: bare equality would give a red about
#                   the address where there are simply no regulated steps;
#   `missing = 0` — with an incomplete plugin update a surviving step may return 3, and equality
#                   holds (ran=1, empty=1). But the cause is then "update the plugin", already
#                   printed above — an address verdict would override the right cause with a wrong one.
if [ "$ran" -gt "$excused" ] && [ "$missing" -eq 0 ] && [ "$empty" -eq "$ran" ]; then
  printf '✗ no engine step found targets in "%s" — this is an ADDRESS error, not cleanliness.\n' "$PWD" >&2
  printf '  The project root is where .retainer/ and CLAUDE.md live, not the code subdirectory.\n' >&2
  exit 1
fi

printf '▶ engine steps: checked %s · not applicable %s · skipped %s\n' "$clean" "$empty" "$missing"
exit 0
