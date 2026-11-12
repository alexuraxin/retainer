# Discipline policy — retainer (the engine's Python box)

retainer is a bash-first engine; its own Python (`bin/*.py`, `hooks/*.py`) is held under the same
strict box we hand out to projects. The full discipline policy (triggers, Definition of Done,
the task cycle, sources of truth) is already laid out for retainer: `docs/HOW-IT-WORKS.md`, `docs/guard.md`,
the skills themselves. Here — what the box requires to keep in ONE place: **the RATCHET debt journal**.

Box wiring: `pyproject.toml` (ruff/mypy), `setup.cfg` (flake8-WPS/codespell),
`requirements-dev.txt` (tool pins), the gate `tests/test_python_lint.sh` (self-lint mirroring
`test_shellcheck.sh`). Volume measurement — `bin/blast-radius.sh`.

**A commit-time gate on OUR OWN code (#165).** Invariant: the engine's own code is under the same box we hand out
to projects, **a gate from the FIRST line**, not a retrofit later (otherwise — "a cobbler without shoes", the root of #162–#164).
Wiring — a versioned `.githooks/`, activated by `bin/githooks-install.sh` (`core.hooksPath`, local,
after a clone/merge):
- `pre-commit` → a fast box subset (`test_python_lint.sh` + `test_shellcheck.sh`) — seconds per commit;
- `pre-push` → a tier by target: a push to `main` — the full suite `tests/test_*.sh`; a branch push — no tests,
  only the showcase refusal and the branch-phase check, because CI on the pull request runs the suite once;
  an unknown target → full (fail-safe);
- `tests/test_githooks.sh` → a self-gate: goes red if the hooks are not activated (parity with the distributed
  `hooks_check`). Bypassing the hooks is standard: `git commit/push --no-verify`.

**How many runs per task.** The full suite runs on a push to `main` and in CI; a branch push runs no tests
locally, so a task pays for its full run once, in CI on its pull request. During the work the following run: the targeted test
of the subject (`bash tests/test_<subject>.sh`), the scanners
that measure the WHOLE SET rather than the task's subject (their marker is the line `# end-to-end:` in the test header; the CI selector
picks them up by the same marker), and a mutation probe of the edit (`bin/retainer-mutate.sh`). A list of
such tests is not written out here: a hand-written list silently falls behind the tree. They answer whether the
check guards what is being edited; the full run answers a different question — whether the tree is intact — and that answer
is needed once, when the edits are finished. The "gate" step in the task cycle on the engine is executed by this set,
not by the full suite: the engine has no single gate command — it is carried by the `pre-commit` subset and the suite in
CI — and a literal "one command" would mean the suite on every fix iteration.

The suite of a push to `main` in `pre-push` runs in the WORKING TREE, without checking out the pushed commit
(`bash bin/retainer-suite.sh --all` in `.githooks/pre-push`): "green on the head that leaves" is true exactly when the
tree is clean, otherwise the run proves the tree, not the head.

There is one cloud run per task — in the `pull_request` context, on a trial merge, and it is the FULL suite: the
selector (`bin/retainer-ci-scope.sh`) answers its `pull_request_ci` tier with every test.
The run on the main branch after a merge is the full suite, the nightly one is the full suite plus the verdict-honesty runner
on top. These are release runs, not task runs: the composition is decided by the selector per event, not by a cutoff in
the workflow job.

The measurement after which the rule was written down: a wave of two tasks produced 24 full runs and 132 minutes.

Deferred (referenced): CI `.gitea/workflows/` waits for a Gitea Actions runner → **#168**; commit-msg (issue-first)
and tamper protection of `.githooks`/`.gitea` — until the guard stabilizes (`guard_git`) → **#169**. Decision — ADR-0004.

**Code prose states behaviour.** A comment or docstring says what the code does now: a contract, a
parameter, a limit, and why a threshold has its value. A task number, the former behaviour, what broke
and what was measured on the way go to the commit message, the CHANGELOG or a journal. The
`prose_content` step names such lines in what a change adds; the engine's tests carry no finding of it.

## Debt journal (RATCHET)

Every deliberate relaxation of strictness or a deferred part is a ROW here, with a rationale and a
condition for lifting. The ratchet goes only up: what is turned on is not turned back off without a row here and the owner's key.
Introduced by the retrofit (skill `retrofit`): the existing Python was not written for WPS/mypy, "fix everything at once"
is not needed — a phased ratchet, the gate green at every step.

| Date | What is relaxed / deferred | Why (rationale) | Condition for lifting | Issue |
|---|---|---|---|---|
| 2026-10-29 | the shipped `protected` registry covers `.gitea/**` and nothing for `.github/**`: on a project installed WITHOUT a tracker the CI workflow is held by no tamper protection | The GitHub gate template arrived with the tracker boundary (#1086). Widening the registry every project ships (`presets/retainer.config.toml.template`, `bin/retainer-new.sh`) changes the behaviour of every installed project out of a task about one preset and two documents. The gap is stated where it is met instead: the template header names it and tells the reader to add `".github/**"` to their own `protected` | A project installs the GitHub template → it adds the pattern to its own config; the shipped registry is widened by a task of its own, which also extends the guard's cases to the new path | #1086 |
| 2026-10-16 | `WPS202` — per-file-ignore: `tests/fixtures/page_language.py` | The checker that pairs the settings pages with their Russian dictionary. The same WPS202 <-> WPS231/210 conflict as the guard's: each helper split out to keep functions small adds a module member, folding them back puts a function over the complexity and local limits — both directions measured. Everything else (ruff, format, all other WPS, mypy strict) is clean, and the checker's own teeth are proven by seven mutants in `tests/test_page_language.sh` | Permanent (while the checker is one self-contained file) | #1105 |
| 2026-07-28 | `WPS202` — per-file-ignore: `hooks/guard_discipline.py` | A single-file security hook (run as `python3 guard_discipline.py`, NOT a package — split into modules = import fragility). WPS202 (module members >7) is unavoidable: decomposing `main()` into small functions for readability + low WPS231/210 GROWS the member count — a direct WPS202 ↔ WPS231/210 conflict in one file. Everything else (ruff/WPS/mypy/format) is cleaned, the deferral is lifted, behavior is proven by `test_guard.sh` (116/0) | Permanent (while the hook is one self-contained file) | #162 |
| 2026-07-27 | `import-linter` (import contracts) — not wired | N/A to the subject: retainer is bash-first, Python is scattered scripts in `bin/`/`hooks/`, no package and no cross-layer imports, the contracts have nothing to guard | A Python package with layers appears → wire from `presets/python/.importlinter.template` | retrofit |
| 2026-07-27 | `pytest` + 100% coverage — not wired | N/A to the subject: no Python unit tests; the engine's behavior is covered by the bash suite `tests/*.sh` (incl. `test_mcp.sh`, `test_guard.sh`), Python code is tested through it | Python unit tests appear → enable `pytest --cov-fail-under=100` | retrofit |
| 2026-07-27 | `WPS421` (print) — per-file-ignore: `bin/second_opinion.py`, `hooks/selfcheck_guard.py`; inline: `bin/retainer_settings_server.py` (port for the launcher) | print/stdout IS the interface of a CLI tool, a hook probe and a port contract with the launcher, not a forgotten debug output. A permanent ratchet, not "fix to logging" | Permanent (while this is a CLI/hook/server with stdout output) | retrofit |
| 2026-07-27 | `WPS226`,`WPS407`,`WPS202` — per-file-ignore: `bin/second_opinion_mcp.py` | Protocol MCP/JSON-RPC code: WPS226 — field names (`name`,`type`,`text`…); WPS407 — protocol dict descriptors (SERVER/TOOL/METHODS), not mutated; WPS202 — the dispatch map gives 10>7 small handler functions (the price of the chosen `_handle` decomposition) | Permanent (until a different protocol abstraction) | retrofit |
| 2026-07-28 | `S310` — inline noqa: `bin/second_opinion.py` (`_post`) | `urlopen` of the CONSTANT `https://api.deepseek.com` — the URL is not user-controlled, no SSRF/scheme vector; stdlib-only (no `requests`) | Permanent (while the endpoint is a literal constant) | #163 |
| 2026-07-28 | `E402` — inline noqa: `bin/second_opinion_mcp.py`, `hooks/selfcheck_guard.py` | Importing a sibling module is possible ONLY after `sys.path.insert(HERE)` — the standard pattern of a stdlib-only script; cannot be lifted to the top of the file | Permanent (while sibling modules are not a package) | #163 |
| 2026-07-28 | `BLE001` — inline noqa: `bin/second_opinion_mcp.py` (`_opinion_content`) | A broad `except Exception` at the BOUNDARY of an MCP session: a second opinion must not bring the client down; narrowing = the risk of an uncaught session crash | Permanent (a robustness boundary) | #163 |
| 2026-07-28 | `N802` — inline noqa: `bin/retainer_settings_server.py` (`do_GET`/`do_POST`/`log_message`) | The method names are dictated by the base `http.server.BaseHTTPRequestHandler` — physically cannot be renamed, it is a framework contract | Permanent (a stdlib contract) | #163 |
| 2026-07-28 | `WPS437` — inline noqa: `hooks/selfcheck_guard.py` (`guard._load`/`_unlocked`) | The white-box guard probe pulls the guard's own loader/unlock as the SINGLE source of truth — reimplementing = drift from the production logic. The security module's public API is NOT widened for the probe (owner's decision, #163) | Permanent (while the probe is white-box) | #163 |
| 2026-07-28 | shellcheck `SC1090` — directive `source=/dev/null`: `bin/conveyor-poll.sh` | The source is an external USER config (`$HOME/.config/retainer/conveyor.conf`), the path is dynamic: nothing to follow. `source=/dev/null` is the exact idiom for "external source on purpose", not a blanket disable | Permanent (while the config is external) | #164 |
| 2026-07-28 | shellcheck `SC2088` — inline disable: `tests/test_config.sh` | The tilde is LITERAL: the test compares the config's value STRING, not a path for a file operation — expanding `~` would be wrong | Permanent (a string comparison, not an FS path) | #164 |
| 2026-07-27 | shellcheck gate threshold = `warning` (note level outside the gate) | note-level SC2012/2015/2016 are OPINIONS/idioms (`A && B || C`, a literal `$` in sed, ls-parsing), not bugs; gating on them = eternal churn and risky "fixes". The threshold is documented in `test_shellcheck.sh`; stricter — `SHELLCHECK_SEVERITY=info` by hand | Permanent (policy; raising the threshold is the owner's decision) | #164 |
| 2026-10-02 | python preset: an SQL linter and a second spelling checker of the reference — not adopted | Subject-conditional tools: for a project without raw SQL the SQL linter finds no targets, and a second spelling checker with its own dictionary gives a stream of false findings on domain words. The box ships what goes red on the merits for everyone | A step for subject-conditional linters (turned on by the presence of the subject) — #883 | #960 |
| 2026-10-02 | python preset: prod settings, a trial static build, a prod server config — not adopted | These are DEPLOY checks, and the box knows nothing about a project's deploy: no mode, no server, no build method. A run outside the deployment environment would check a fiction | The box starts shipping deploy (image, server, statics) — then these three steps arrive with it | #960 |
| 2026-10-02 | python preset: a ban on auto-fitting SNAPSHOTS (snapshot tests) — not adopted | The box ships no snapshots at all: no step, no library, no case form. There is nothing to check a ban on overwriting a stale snapshot with — no subject. The linter half of the same rule is adopted and guarded by a case (a call to fix without a refusal to edit turns the suite red) | The box starts shipping snapshot tests — then the ban arrives with them | #960 |
| 2026-10-02 | python preset: lockfile integrity, cache cleanup, gate refusal outside the development environment — not adopted | All three rest on the package manager and the environment layout, which differ across managed projects (`pip`, `poetry`, `uv`); wiring in one would break the gate for the others. Partly closed by the substep for integrity of installed dependencies | The package manager is declared by a config key — then the steps take its commands | #960 |

**Rule:** you cannot "just add an ignore". Any `# noqa`, `per-file-ignores`, deferred file,
lowered threshold — first a row here, then the code. The journal is **compacted** as phases close.

**Boundaries (do not double an incident):** RATCHET = RELAXATIONS of the linter/gate config and deferred parts;
caught BUGS → `docs/ERROR-JOURNAL.md`; the agent's process deviations → `docs/DEVIATION-JOURNAL.md`
(what the guard did not catch mechanically); what the guard caught mechanically → `.retainer/bypass.log`.
