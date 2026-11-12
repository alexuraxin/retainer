#!/usr/bin/env bash
# guard-wiring-check: the guard is REGISTERED as a hook — where the settings are actually read.
# Lives in the ENGINE, not in a project's gate.sh: the wiring changes (direct settings.json
# registration → plugin hooks.json), and a move must reach managed projects via `plugin update`,
# not by hand-editing gate.sh in each one.
#
#   guard-wiring-check.sh              # prints a verdict on guard REGISTRATION in this HOME
#   guard-wiring-check.sh --quiet      # exit code only
#   guard-wiring-check.sh --project [<path>]   # verdict on a PROJECT: has its gate.sh migrated
#
# Registration codes: 0 — wired · 1 — settings exist, no wiring · 2 — not installed/unreadable
#       3 — wired TWICE (plugin + manual registration: the guard runs twice on every call)
#       5 — wiring EXISTS but points to a missing file: the hook fails on launch, the agent
#           works without a guard and does not know it. Separate from 1: "not wired" is visible,
#           "wired to nowhere" was indistinguishable from live by a substring check.
# --project codes:  0 — gate calls the engine · 1 — gate checks the wiring ITSELF (hand-rolled)
#       2 — gate not found · 4 — no wiring-check step in the gate at all
#       5 — guard wiring in `<project>/.claude/settings{,.local}.json` points to a
#           missing file. Judged BEFORE the gate: a managed-project clone keeps its gate where the
#           default does not expect it, and an early "no gate" exit hid a dead guard behind "cannot check".
#
# Where a hook command leads is known to bin/hook_wiring_scan.py — the same parse for all three
# wirings (global, project, plugin) and for the test. Three copies of this parse had drifted apart.
#
# WHY --project. "I replaced the block" and "this project migrated" are different questions. On a
# managed project the move was finished by hand, and the gate kept a hand-rolled grep over engine
# internals UNDER a commit message saying "the engine carries the check". Nothing outside shows the
# difference — a verdict on the file is needed.
#
# ENV (test overrides): RETAINER_HOME (engine root), CLAUDE_SETTINGS (settings file).
#
# BOUNDARY: this checks REGISTRATION, not liveness. What the guard actually BLOCKS is proven by
# the `hooks/selfcheck_guard.py` probe (gate step). Neither is complete alone: a live but
# unregistered hook is not loaded; a registered but dead one does not block.
# Neither proves that the plugin cache is fresh. Both checks look at RETAINER_HOME (the engine
# tree), while Claude Code loads the CACHE — a stale cache is called wired by both (update from
# a directory source is a silent no-op). Cache freshness — `claude plugin list` after update.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
RETAINER_HOME="${RETAINER_HOME:-$HERE}"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
QUIET=0
PROJECT=""
MODE=registration
while [ "$#" -gt 0 ]; do
  case "$1" in
    --quiet)   QUIET=1 ;;
    --project) MODE=project; case "${2:-}" in ""|--*) ;; *) PROJECT="$2"; shift ;; esac ;;
    *)         echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$1"; }

# ── Verdict on a PROJECT: has its gate.sh moved to the engine check ───────────────────────────
# What counts as a "wiring step" is known to bin/gate_wiring_scan.py — the same parse the move in
# adopt-managed-plugin.sh uses. If they drifted, the verdict would lie about its own work.
if [ "$MODE" = project ]; then
  PROJECT="$(cd "${PROJECT:-.}" 2>/dev/null && pwd)" || { say "  (no project directory)"; exit 2; }

  rc=0
  RETAINER_HOME="$RETAINER_HOME" ENGINE_BIN="$HERE/bin" PROJECT="$PROJECT" QUIET="$QUIET" python3 - <<'PY' || rc=$?
import json
import os
import pathlib
import sys

sys.path.insert(0, os.environ["ENGINE_BIN"])
from gate_wiring_scan import ENGINE_CALL, gate_path, wiring_hits  # noqa: E402
from hook_wiring_scan import describe, guard_wirings  # noqa: E402

project = pathlib.Path(os.environ["PROJECT"])
home = pathlib.Path(os.environ["RETAINER_HOME"])
quiet = os.environ["QUIET"] == "1"


def say(text):
    """Print the verdict; under --quiet only the exit code goes out."""
    if not quiet:
        print(text)


def blob(path):
    """Settings JSON or {} — a broken file means "nothing to show", not a wiring verdict."""
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeDecodeError):
        return {}


# The PROJECT wiring is judged FIRST, whether or not a gate was found. Otherwise the check never
# reaches the hooks: below sits an early "no gate" exit, and the very shape this exists for
# (git present, gate in a non-standard place, no `.retainer/`) hits exactly it. With nothing to
# show we fall through to the gate verdict UNCHANGED, or every --project fixture would shift.
# Both files: `settings.local.json` is an equal wiring source, only not under git.
dead = []
for leaf in ("settings.json", "settings.local.json"):
    dead += guard_wirings(blob(project / ".claude" / leaf), plugin_root=home, anchor=project)[1]
if dead:
    say("  ⚠ guard wiring in the project is stale: " + describe(dead))
    say("    an absolute path into another project silently goes stale on a move — route via the plugin")
    raise SystemExit(5)

gate = project / gate_path(project)
if not gate.is_file():
    say(f"  (no gate {gate} — project migration cannot be checked)")
    raise SystemExit(2)

lines = gate.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
if any(ENGINE_CALL in ln for ln in lines):
    say(f"  migrated ✓: {gate} calls {ENGINE_CALL}")
    raise SystemExit(0)
if wiring_hits(lines):
    say(f"  ⚠ NOT migrated: {gate} checks the wiring ITSELF — knows engine internals")
    say(f"    fix: bash {os.environ['RETAINER_HOME']}/bin/adopt-managed-plugin.sh {project}")
    raise SystemExit(1)
say(f"  ⚠ no wiring-check step in {gate} at all — the wiring is gated by nothing")
raise SystemExit(4)
PY
  exit "$rc"
fi

# python3 computes the verdict (JSON, not grep over braces): must tell a hook in `hooks` from
# the string "guard_discipline" anywhere else in the file. Prints: <verdict>\t<detail>.
OUT="$(RETAINER_HOME="$RETAINER_HOME" ENGINE_BIN="$HERE/bin" CLAUDE_SETTINGS="$CLAUDE_SETTINGS" python3 - <<'PY'
import json
import os
import pathlib
import sys

sys.path.insert(0, os.environ["ENGINE_BIN"])
from hook_wiring_scan import describe, guard_wirings  # noqa: E402

settings = pathlib.Path(os.environ["CLAUDE_SETTINGS"])
home = pathlib.Path(os.environ["RETAINER_HOME"])


def out(verdict, detail):
    print(f"{verdict}\t{detail}")
    raise SystemExit(0)


if not settings.is_file():
    out("nosettings", f"{settings} missing — no Claude Code settings found in this HOME")

raw = settings.read_text(encoding="utf-8", errors="replace")
try:
    data = json.loads(raw or "{}")
except (ValueError, UnicodeDecodeError):
    # Settings do not parse (broken JSON) — no verdict, but not silent either: degrade
    # to grep so as not to say "no wiring" where there is one.
    out("unreadable", "settings.json does not parse as JSON" + ("; a guard_discipline line IS in it" if "guard_discipline" in raw else ""))

# The anchor for relative paths here is HOME: Claude Code launched in an arbitrary directory reads
# the settings of this HOME, and the verdict must not depend on where the check was called from.
live, dead = guard_wirings(data, plugin_root=home, anchor=pathlib.Path.home())
direct = bool(live)

# The plugin name comes from the engine itself — a fork under another name is checked the same (no hardcode).
name = ""
manifest = home / ".claude-plugin" / "plugin.json"
if manifest.is_file():
    try:
        name = json.loads(manifest.read_text(encoding="utf-8")).get("name") or ""
    except (ValueError, UnicodeDecodeError):
        name = ""

enabled = [
    key for key, val in (data.get("enabledPlugins") or {}).items()
    if val and key.split("@")[0] == name and name
]
hooks_json = home / "hooks" / "hooks.json"
try:
    declared = json.loads(hooks_json.read_text(encoding="utf-8"))
except (OSError, ValueError, UnicodeDecodeError):
    declared = {}
# The plugin wiring is judged by the same parse, not a substring: "guard_discipline appears in
# hooks.json" held for a declaration to nowhere too — the same class one level up.
plug_live, plug_dead = guard_wirings(declared, plugin_root=home, anchor=home)
declares = bool(plug_live)
plugin = bool(enabled) and declares
if enabled:
    # A dead declaration inside a DISABLED plugin is not a live problem: the guard is absent for
    # another reason, and that reason ("plugin not enabled") is the one to name, not a stale path.
    dead += plug_dead

# Order: "wired" first, then "stale". The reverse would displace both the double wiring (code 3) and
# live wiring — a stale registration NEXT TO live wiring is output noise, not a missing guard.
stale = " · stale wiring alongside: " + describe(dead) if dead else ""
if direct and plugin:
    out("both", f"plugin {enabled[0]} + manual registration in settings hooks{stale}")
if plugin:
    out("plugin", f"plugin {enabled[0]} → {hooks_json}{stale}")
if direct:
    out("direct", f"direct registration in hooks of {settings}{stale}")
if dead:
    out("dead", "wiring exists but leads nowhere: " + describe(dead))

why = []
if not name:
    why.append(f"cannot read the plugin name ({manifest})")
elif not enabled:
    why.append(f"plugin '{name}' is not enabled in enabledPlugins")
if not declares:
    why.append(f"{hooks_json} does not declare a live guard_discipline")
if not direct:
    why.append("no guard in settings hooks")
out("none", "; ".join(why))
PY
)" || { say "  (wiring check could not run — python3 unavailable or crashed)"; exit 2; }

VERDICT="${OUT%%$'\t'*}"
DETAIL="${OUT#*$'\t'}"

case "$VERDICT" in
  plugin)     say "  wired ✓ (plugin): $DETAIL"; exit 0 ;;
  direct)     say "  wired ✓ (direct registration): $DETAIL"; exit 0 ;;
  both)
    say "  ⚠ guard wired TWICE: $DETAIL"
    say "    after the plugin cutover remove the manual registration from settings — otherwise the hook runs twice on every call"
    exit 3 ;;
  dead)
    # Separate from "not wired": the wiring EXISTS, and a substring check counted it live. Silence
    # is not an option — the hook fails on launch, and the agent works without a guard, unaware.
    say "  ⚠ wiring is stale: $DETAIL"
    say "    an absolute path into another project silently goes stale on a move — route via \${CLAUDE_PLUGIN_ROOT}"
    exit 5 ;;
  none)       say "  ⚠ guard NOT wired: $DETAIL"; say "    how to fix — docs/guard.md"; exit 1 ;;
  nosettings) say "  ($DETAIL — engine not connected in this environment; skipped)"; exit 2 ;;
  *)          say "  (no verdict possible: $DETAIL)"; exit 2 ;;
esac
