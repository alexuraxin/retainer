# How Retainer works

> A Russian version lives in the engine repository as `docs/HOW-IT-WORKS.ru.md`; it does not ship
> with the plugin.

An AI agent under pressure writes code with no task, weakens the check in its way and says "done"
without running anything. A rule in the prompt does not stop it. Retainer moves the rules into hooks,
a gate and the tracker, which the agent does not control, and keeps them in one plugin for every project.

<p align="center">
  <img src="assets/diagrams/layout.svg" width="960" alt="The engine is one plugin for all projects: agents, skills, hooks and presets; each project adds its own .retainer/config.toml and .retainer/PROJECT.md">
</p>

## The task cycle

<p align="center">
  <img src="assets/diagrams/cycle.svg" width="960" alt="The task cycle: issue, plan, plan check, code with tests, gate, review, PR, merge check, merge; a contradiction returns to the plan, a red gate or a review finding returns to the code">
</p>

A commit without `#N` is rejected. Role agents check the plan, the diff and the result: five of them in
[agent-roles.md](agent-roles.md), 17 skills in [SKILLS.md](SKILLS.md).

## The guard

A `PreToolUse` hook (`hooks/guard_discipline.py`) that judges **only `Bash`** and blocks destructive
acts, secret egress, new dependencies and writes to its own wiring. File edits are held by the harness
`deny` rules. Details: [guard.md](guard.md).

## Hooks that feed the agent

| Hook | Does |
|---|---|
| `hooks/write_advice.py` | names the skill for the kind of file being written (kinds in `hooks/write_advice.rules`); on a grep for a function name, names the code-graph command (`hooks/search_advice.py`) |
| `hooks/session_context.py` | injects the hot part of `.retainer/PROJECT.md` at session start; shows the session mode line |
| `hooks/project_context.py`, `hooks/project_doc.py` | pick which part of the project document to feed; table `hooks/context.rules` |
| `hooks/stop_gate.py` | the "done" gate: on a turn whose final message claims done, runs the tests for the files this session changed and the project's `lint_command`; red refuses the turn. Files another session or the owner left in the tree are not judged, and a turn with none of its own changes runs nothing. When the engine's own runner finds every suite slot on the machine busy for the whole wait, the tests are skipped with a visible note and the turn is not refused, so a red goes unseen that turn |

The Stop hook also prints the next step of the task (`bin/retainer-route.sh`, steps in `hooks/route.rules`).
With questions off, a turn may stop only on a named ground, `handoff: <code> — <what is blocked>`:
`destructive`, `owner-key`, `native-deny`, `self-approval`, `boundary` (or `pointless`).

## The gate

`bash scripts/gate.sh` runs every check: a fast subset on commit, all of it on push and in CI.
Steps: guard probe · `ruff` · `flake8` · `mypy --strict` · `codespell` · `import-linter` · `pytest` with
coverage. The engine's own steps come from `bin/retainer-gate-steps.sh`.

The code graph is not part of the gate. `bin/retainer-graph.sh explain "<name>"` (or `path "<A>" "<B>"`) answers from a graph kept in the engine's state home, outside the project tree, and rebuilds it first when the code changed; closing a task refreshes it.

## Task commands

| Command | Does |
|---|---|
| `bin/retainer-ready-check.sh` | the task has a plan, criteria, boundaries and files, and an impact label names who suffers |
| `bin/retainer-task-start.sh` | label, branch, task marker |
| `bin/retainer-usecase-registry.sh` | the project's scenario list |
| `bin/retainer-merge-ready.sh` | merge lock: checks green, review on this head; published as status `retainer/merge-lock` |
| `bin/retainer-task-close.sh` | result comment, labels cleared |

Needs Gitea or GitLab. Without a tracker the rest works and issues and merges are done by hand.

## Autonomy

`bin/retainer-flow-policy.sh` gives each step `auto`, `ask` or `off`; `bin/retainer-tool-policy.sh` does the
same for heavy tools. Set on `/retainer:settings`.

| Step | manual | assisted | auto | marathon |
|---|---|---|---|---|
| `issue` | ask | ask | auto | auto |
| `branch` | ask | auto | auto | auto |
| `commit` | ask | auto | auto | auto |
| `pr` | ask | ask | auto | auto |
| `merge` | off | off | off | **auto** |
| `cleanup` | auto | auto | auto | auto |
| `ask_owner` | auto | auto | auto | **off** |
| `confirm_intake` | auto | auto | auto | auto |

Autonomy removes questions, not checks.

## Rigor regulators

Optional checks per project, in `[rigor]`:

- `doc_links` — paths in agent docs exist
- `doc_claims` — a marked claim is confirmed by running it
- `agent_canon` — a cycle role is not duplicated in the project
- `protected_copy` — no copy of a protected file
- `bypass_alert` — the same guard hit does not repeat
- `hot_context` — the always-read context stays small
- `remote_creds` — no credentials in the remote URL
- `skills_catalog` — the skills catalogue matches the skills
- `dependency_check` — every dependency is locked
- `deny_sync` — guard paths and harness `deny` agree
- `runner_labels` — one CI runner label per project
- `complexity_trace` — a new code file justifies its complexity
- `prose_lang` — code prose is in English
- `prototype_debt` — a prototype marker has a task number
- `glossary_terms` — terms are in the glossary
- `practices_form` — a practice rule has a sample address
- `secret_scan` — no hardcoded secret
- `req_trace` — code traces to requirements
- `guard_registration` — the guard is registered as a hook
- `hooks_check` — git hooks are in place
- `django_extras` — extra Django checks
- `js_gate` — the frontend gate

Turning one off needs a line with a reason in `docs/tooling.md`.

## The engine itself

| Tool | Does |
|---|---|
| `bin/retainer-suite.sh` | all tests; the full run once per pull request in CI |
| `bin/retainer-mutate.sh` | breaks one construct at a time; a test nothing reddens is deleted |
| `bin/guard-wiring-check.sh` | the guard is attached where the harness reads it |
| `bin/retainer-stage.sh` | a scratch copy of the engine for edits to protected files |
| `bin/retainer-register.sh` | the list of managed projects |
| `bin/retainer-release.sh` | builds a release from changelog fragments; version in `.claude-plugin/plugin.json` |
| `bin/retainer-publish.sh` | publishes the public copy after a leak scan (`bin/retainer_export_scan.py`) |

Optional `launchd` services (keeper, digest, conveyor) have templates in `presets/launchd/`.

## Boundaries

The guard closes the easy path, not a determined attacker: a name assembled from pieces or a write behind
a variable shows up in the diff and in review.
