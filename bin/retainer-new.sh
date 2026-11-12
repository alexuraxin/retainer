#!/usr/bin/env bash
# retainer new — creates a project with FULL discipline out of the box (ADR-0002).
# Flat layout (code at the repo root). The first commit passes the full strict gate.
#
#   retainer-new.sh <name> [--django] [--no-install] [--path DIR]
#
# --django      add the preset's Django module (stub: marker in config, install later)
# --no-install  no venv / no requirements-dev install / no gate run (files + commit only)
# --path DIR    parent directory (default $PWD)
#
# RETAINER_HOME  where retainer is installed (default ~/retainer)
# RETAINER_RUNNER CI runner (default self-hosted)
set -euo pipefail

NAME="${1:-}"
[ -z "$NAME" ] && { echo "usage: retainer-new.sh <name> [--django] [--no-install] [--path DIR]" >&2; exit 2; }
shift

DJANGO=0; INSTALL=1; PARENT="$PWD"
while [ $# -gt 0 ]; do
  case "$1" in
    --django)     DJANGO=1; shift ;;
    --no-install) INSTALL=0; shift ;;
    --path)       PARENT="${2:?}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$NAME" in
  *[!a-zA-Z0-9_-]*|[!a-zA-Z]*) echo "project name: letters/digits/-/_ , starts with a letter" >&2; exit 2 ;;
esac
PKG="${NAME//-/_}"                       # package name: hyphens → underscores
RETAINER_HOME="${RETAINER_HOME:-$HOME/retainer}"
PRESETS="$RETAINER_HOME/presets"
RUNNER="${RETAINER_RUNNER:-self-hosted}"
DEST="$PARENT/$NAME"

[ -e "$DEST" ] && { echo "already exists: $DEST" >&2; exit 1; }
[ -d "$PRESETS/python" ] || { echo "preset not found: $PRESETS/python (RETAINER_HOME=$RETAINER_HOME)" >&2; exit 1; }
# The work-state list is checked HERE, not at inlining: inlining runs after `git init` and two dozen
# written files, so a refusal there would abort the project mid-tree.
[ -f "$PRESETS/gitignore.workstate" ] || { echo "preset not found: $PRESETS/gitignore.workstate" >&2; exit 1; }

echo "▶ creating $DEST (package: $PKG, django: $DJANGO)"
mkdir -p "$DEST"/{scripts,.retainer,.githooks,.gitea/workflows,.gitea/ISSUE_TEMPLATE,"$PKG",tests}
cd "$DEST"
git init -q

# ── layout-agnostic presets (copied as is) ──────────────────────────
cp "$PRESETS/python/pyproject.toml.template"       pyproject.toml
cp "$PRESETS/python/setup.cfg.template"            setup.cfg
cp "$PRESETS/python/requirements-dev.txt.template" requirements-dev.txt
# File shape ships with the linter strictness: without it the editor applies its own width and
# indent, and a plain "just saved the file" turns the gate red for the next person.
cp "$PRESETS/.editorconfig.template"               .editorconfig
# The project's only conftest: the base test timeout is extended ONLY by a marker, and the extension
# is declared here. Without it the pyproject `timeout` cannot be raised legitimately — the first slow
# test lowers the bar for everyone.
cp "$PRESETS/python/conftest.py.template"          conftest.py
# Release-age buffer: two lines, zero logic, works on every new project at once — poisoned packages
# are caught within 1-3 days, a one-week buffer closes the window entirely.
cp "$PRESETS/python/uv.toml.template"              uv.toml
cp "$PRESETS/python/gate.sh.template"              scripts/gate.sh
cp "$PRESETS/python/req-trace.sh.template"         scripts/req-trace.sh
cp "$PRESETS/python/secret-scan.sh.template"       scripts/secret-scan.sh
chmod +x scripts/gate.sh scripts/req-trace.sh scripts/secret-scan.sh

# coverage scope on the package (otherwise --cov measures everything)
printf '\n[tool.coverage.run]\nsource = ["%s"]\n' "$PKG" >> pyproject.toml

# tooling.md — policy (project name substituted)
sed "s/<PROJECT>/$NAME/g" "$PRESETS/tooling.md.template" > tooling.md
# PROJECT.md — context for agents
sed "s/<PROJECT>/$NAME/g" "$PRESETS/PROJECT.md.template" > .retainer/PROJECT.md
# CI — flat gate from scratch
sed "s/__RUNNER__/$RUNNER/g" "$PRESETS/ci/gitea-actions.gate.yml.template" > .gitea/workflows/gate.yml
# The merge lock publishes the verdict the gated merge path and branch protection wait for; without it
# nothing in the project writes that status. Same runner as the gate.
sed "s/__RUNNER__/$RUNNER/g" "$PRESETS/ci/gitea-actions.merge-lock.yml.template" > .gitea/workflows/merge-lock.yml
# The task skeleton ships with the project: the acceptance-block shape is a machine requirement of
# the merge lock, and it can otherwise be learned only by hitting a refusal at the end of the work.
cp "$PRESETS/issue-template.task.md.template" .gitea/ISSUE_TEMPLATE/task.md
# The practices layer is laid down empty in shape: a new project has no practices yet, but the file
# must exist — otherwise cycle roles read emptiness while the project document claims the file exists.
sed "s/<PROJECT>/$NAME/g" "$PRESETS/practices.md.template" > .retainer/practices.md

# ── .importlinter (minimal VALID contract for an empty package) ──────────
cat > .importlinter <<EOF
# Architecture contracts — machine-checked (import-linter, command lint-imports).
# ⛔ Under the guard. The starting contract is trivially true; fill it in for your layout.
[importlinter]
root_package = $PKG
include_external_packages = True

[importlinter:contract:pure-core]
name = Core without direct network
type = forbidden
source_modules =
    $PKG
forbidden_modules =
    socket

# Production does not import tests: such an import survives a local run (tests are alongside) and
# fails in production, where there is no tests directory at all. On an empty project the contract is
# true — and stays true for free.
[importlinter:contract:tests-restrictions]
name = Production does not import tests
type = forbidden
source_modules =
    $PKG
forbidden_modules =
    tests
EOF

# ── .retainer/config.toml (FLAT layout, full protected) ──────────────
cat > .retainer/config.toml <<EOF
# $NAME/.retainer/config.toml — project config for retainer (flat layout).
# All top-level keys and protected go BEFORE the [docs] table (otherwise the key lands in the table).

gate_command = "bash scripts/gate.sh"
backup_command = ""
unlock_file = ".retainer/unlock"

# Gate on a declared "done": test path shape ({stem} is the changed module's name) and what runs the
# chosen paths. If unset the engine's shape is used, and in a project in another language no tests are found.
test_layout = "tests/test_{stem}.py"
test_command = ".venv/bin/pytest -q"

# Tests laid out as a tree by layers — a mirror is used instead of test_layout: a pair of roots
# "sources:tests", the module path maps with a test_ prefix on each segment, and with no exact test
# the directory above it is taken. The target weight limit is a string, otherwise it reads as "unset".
# test_mirror = "src:tests"
# test_mirror_limit = "25"

# Destructive-act gate: without a key irreversible commands are blocked (reset --hard/clean/force-push, rm -rf, dd…).
guard_destructive = true

# New-dependency gate (on by default, the line declares it aloud): blocks a command that adds a
# package via a language manager. Restoring declared packages and system managers are not touched.
guard_dependency = true

# Egress gate: blocks a command that reads a secret file AND sends data to an EXTERNAL host (not an auth header).
# Protection against prompt-injection exfiltration. git push with a token and API auth are not touched.
guard_egress = true

# What the guard protects — files whose edit WEAKENS a check.
protected = [
  ".retainer/**",
  ".githooks/**",
  ".git/hooks/**",
  ".gitea/**",
  "scripts/gate.sh",
  "scripts/secret-scan.sh",
  "pyproject.toml",
  "conftest.py",
  "setup.cfg",
  ".importlinter",
  "requirements-dev.txt",
  "tooling.md",
  "AGENTS.md",
]

# Rigor regulators (on top of the fixed baseline; they do NOT lower it). Changing them is under the guard (key).
[rigor]
hooks_check        = true          # gate fails if core.hooksPath != .githooks (skipped in CI); false = opt out of .githooks, the class is not checked
guard_registration = true          # guard is registered as a hook (skipped in CI; graceful without the engine)
secret_scan        = "basic"        # basic (narrow prefixes: AKIA/ghp_/xox/JWT/PEM) | thorough (+ generic secret=…) | false
req_trace          = "basic"        # basic (advisory) | thorough (fails) | false — req:ID tracing (.retainer/requirements.md)
doc_links          = true          # paths named in instructions must exist: a dead link teaches the agent something false
agent_canon        = true          # a cycle role does not exist in two copies at once (otherwise which one is called is a guess)
protected_copy     = true          # no copy of a protected file under another name (a copy is edited freely yet read as the rules)
bypass_alert       = true          # the same hit against the guard does not repeat a threshold number of times (silent until it repeats)
hot_context        = true          # mandatory reading is not bloated and holds no reports of work done in place of rules
remote_creds       = true          # the remote repository address has no embedded credentials
skills_catalog     = true          # the skills catalog in docs is built from live SKILL.md files, not hand-written
dependency_check   = true          # what the dependency manifest names is in the lock file
deny_sync          = true          # the guard's protected list and the harness deny list have not diverged
doc_claims         = true          # a marked document claim is confirmed by a command
runner_labels      = true          # all CI jobs call one runner (otherwise a job hangs in the queue silently)
complexity_trace   = true          # a new component carries a complexity-decision line (an invisible decision equals an undone one)
prose_lang         = true          # DECLARATION of the code prose language: Latin in docstrings, comments, names — free from scratch
prototype_debt     = true          # a prototype marker carries a task number (otherwise the debt is declared with nowhere to read what was agreed)
glossary_terms     = false         # term check against the glossary: enabled by project decision once a glossary exists
practices_form     = true          # a practice rule the diff touched carries its address (Sample:), its date (Distilled:); silent without .retainer/practices.md
django_extras      = false         # djangofmt+manage.py check+lintmigrations+services-purity (Django)
js_gate            = false          # node --check + biome + node:test (JS/frontend)

[docs]
regulations = "tooling.md"
project_context = ".retainer/PROJECT.md"
EOF
[ "$DJANGO" = "1" ] && printf '\n# django module enabled at scaffold — install django-stubs/pytest-django/django-zeal later.\ndjango = true\n' >> .retainer/config.toml

# The CI runner label is appended AFTER the heredoc (which deliberately does not substitute
# variables) and as the LAST section: lines appended below would otherwise land in [ci].
printf '\n# CI runner: the gate step checks all project workflows against this label — the same label sits\n# in runs-on of the shipped CI template.\n[ci]\nrunner_label = "%s"\n' \
  "$RUNNER" >> .retainer/config.toml

# Starting requirements manifest (req_trace): the owner writes R-lines with the key, the agent adds tags in code.
# Empty (header only) → the req_trace gate is green on the first commit (no R-IDs → nothing uncovered).
cat > .retainer/requirements.md <<'EOF'
# Project requirements (req:ID)
#
# The owner writes requirements as lines `R-<n>: <text>` (editing is under the guard, with the owner's key).
# The agent adds a tag comment `req: R-<n>` in code/tests (a list — `req: R-1, R-2`).
# The req_trace regulator catches uncovered requirements (no code or test reference) and orphans (a tag without an R-ID = drift).
#
# Example (add your own R-lines — only they, without `#`, count as requirements):
# R-1: <what the system must do>
EOF

# ── AGENTS.md — context for non-Claude harnesses (Codex/Cursor/Gemini); de-facto 2026 standard ──
cat > AGENTS.md <<EOF
# $NAME — context for AI agents (AGENTS.md)

The project is under retainer discipline. **AGENTS.md** is the de-facto standard for agent context
(Claude Code, Codex, Cursor, Gemini). Read BEFORE working:

- **Discipline policy:** \`tooling.md\` — "tool BEFORE the event" triggers, Definition of Done, RATCHET.
- **Project context:** \`.retainer/PROJECT.md\` — architecture, pitfalls, prohibitions.
- **Quality gate (one command):** \`bash scripts/gate.sh\` — must be green BEFORE a commit.
- **Cycle:** issue → branch → plan → code → gate → review → commit(#N) → PR → merge.

⚠ The **discipline guard** (blocks edits to config/gate, destructive acts, exfiltration) runs as a
**Claude Code** PreToolUse hook. On Codex/Cursor/Gemini the CONTEXT and the cycle carry over (follow
them as rules), but mechanical hook enforcement exists only in Claude Code.
EOF

# ── git hooks (FLAT) ──────────────────────────────────────────────────────
cat > .githooks/pre-commit <<EOF
#!/usr/bin/env bash
# pre-commit: a fast subset (ruff format+check + codespell — seconds) so new code is born formatted
# and clean at COMMIT. The full box (mypy/WPS/import-linter/pytest) runs on pre-push/CI.
# No venv (fresh clone) → soft skip: the guarantee comes from pre-push/CI, not this hook.
set -euo pipefail
[ -x .venv/bin/ruff ] || { echo "▶ pre-commit: no .venv — skipped (gate on pre-push/CI)"; exit 0; }
.venv/bin/ruff format --check $PKG tests
.venv/bin/ruff check $PKG tests
.venv/bin/codespell $PKG tests
EOF
cat > .githooks/pre-push <<'EOF'
#!/usr/bin/env bash
# pre-push: the gate as the first line (the GUARANTEE is CI from scratch, not this hook).
set -euo pipefail
echo "▶ pre-push: running the gate…"
bash scripts/gate.sh
EOF
cat > .githooks/post-commit <<'EOF'
#!/usr/bin/env bash
# post-commit: project additions after a commit. The code graph is not rebuilt here: it lives in the
# engine's state home and is rebuilt by the query itself (retainer-graph.sh).
set -euo pipefail
exit 0
EOF
cat > .githooks/commit-msg <<'EOF'
#!/usr/bin/env bash
# commit-msg: issue-first MECHANICALLY — a commit without an issue reference (#N) is rejected.
set -euo pipefail
msg_file="$1"
first_line="$(sed -n '1p' "$msg_file")"
case "$first_line" in
  Merge*|Revert*|fixup!*|squash!*|"") exit 0 ;;
esac
if ! grep -qE '(^|[^0-9A-Za-z])#[0-9]+' "$msg_file"; then
  {
    echo "✗ commit-msg: no issue reference (#N)."
    echo "  issue-first: code is born from an issue. Add #<number> to the message."
    echo "  (merge/revert/fixup are exempt; bootstrap — only with --no-verify)."
  } >&2
  exit 1
fi
EOF
chmod +x .githooks/pre-commit .githooks/pre-push .githooks/post-commit .githooks/commit-msg
git config core.hooksPath .githooks

# ── smoke package (fully covered by a test → coverage 100%) ─────────────────
printf '"""Package %s."""\n' "$PKG" > "$PKG/__init__.py"
cat > "$PKG/core.py" <<EOF
"""Core of $PKG."""


def healthcheck() -> bool:
    """Return True — a service check that the package imports."""
    return True
EOF
: > tests/__init__.py
cat > tests/test_smoke.py <<EOF
"""Smoke test: the package imports and responds."""

from $PKG.core import healthcheck


def test_healthcheck() -> None:
    assert healthcheck()
EOF

# ── .gitignore + README ─────────────────────────────────────────────────────
cat > .gitignore <<'EOF'
.venv/
__pycache__/
*.pyc
.ruff_cache/
.mypy_cache/
.pytest_cache/
.coverage
htmlcov/
EOF
# Work state is inlined from the KIT's list, not from own lines: the same list is read by the kit
# check on existing projects, and a second copy here would diverge from it silently.
cat "$PRESETS/gitignore.workstate" >> .gitignore
cat > README.md <<EOF
# $NAME

A project under retainer discipline (full strictness out of the box, ADR-0002).

## Development
\`\`\`
python3.12 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
bash scripts/gate.sh          # full gate: guard · ruff · WPS · mypy · import-linter · codespell · pytest, coverage 100%
\`\`\`
Cycle: issue → branch → plan → plan-checker → code → gate → code-reviewer → commit(#N) → PR → merge.
EOF

# ── venv + install + gate (unless --no-install) ──────────────────────────
if [ "$INSTALL" = "1" ]; then
  echo "▶ venv + requirements-dev + gate…"
  python3.12 -m venv .venv 2>/dev/null || python3 -m venv .venv
  .venv/bin/pip install -q -r requirements-dev.txt
  if bash scripts/gate.sh; then
    echo "✓ gate green on the empty project"
  else
    echo "✗ gate red — fix the smoke package/config until green BEFORE committing" >&2
    exit 1
  fi
else
  echo "▶ skipping install/gate (--no-install). Run the gate manually before committing."
fi

# ── first commit ───────────────────────────────────────────────────────────
git add -A
# --no-verify: the bootstrap commit legitimately has no #N (an empty project has no issue yet); the commit-msg hook is for later ones.
git commit --no-verify -q -m "chore: retainer scaffold — discipline out of the box (full strictness)

Full gate (guard probe · ruff · WPS · mypy strict · import-linter · codespell ·
pytest, coverage 100%), strict configs, tooling.md policy, git hooks, CI, guard.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"

echo "✓ ready: $DEST (first commit created)"
# The project is born with `protected` in config and WITHOUT a single write rule: the guard judges
# only `Bash`, write tools are held by `deny` in the home settings, and the scaffold neither writes
# there nor should. Staying silent here would hand the owner a project whose protection is declared
# and does not work. The check prints the missing rules as ready text; its verdict is no sentence on
# the scaffold, so the exit code is suppressed.
#
# The path is passed ABSOLUTE (`$PWD`, the shell is already inside the created tree): a relative
# `--path` would lead the check to a nonexistent directory, and the owner would see usage instead of rules.
bash "$RETAINER_HOME/bin/retainer-deny-sync.sh" "$PWD" || true
echo "  next: create the repo on Gitea → git remote add → push → bin/setup-repo.sh <owner/repo> --protect"
echo "  In your own terminal, list the project, otherwise the settings page and the engine's"
echo "  cross-project checks will not see it:"
echo "    echo '$DEST' >> ~/.config/retainer/managed-repos"
echo "  (the guard protects that list, so the line is yours to run, not the agent's)"
