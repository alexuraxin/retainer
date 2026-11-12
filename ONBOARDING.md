# Onboarding

Install the plugin, connect a project, run the first task through the cycle — about 15 minutes.

## 1. Install the plugin
Lines starting with `/` are typed into the **Claude Code chat** (the Claude panel in VS Code, or `claude` in a
terminal), not into a shell.
```
/plugin marketplace add alexuraxin/Retainer     # the engine showcase on GitHub
/plugin install retainer
```
If macOS opens a window offering to install "command line developer tools", click **Install**, wait for it to
finish, then repeat the two lines.

Then restart Claude Code so it loads the plugin: in VS Code, ⌘⇧P → "Developer: Reload Window"; in a terminal,
exit and run `claude` again.

`marketplace add` takes the owner and the repository, not a URL. If it answers that the repository is not
found, the installation is not broken: either the address is wrong, or your account cannot read the showcase.

The showcase contains the assembled kit at its root, not the development tree: the marketplace catalogue declares
the root the plugin source, and exactly it goes into the project.
The plugin brings: skills (cycle, gate, graph-first, …), five cycle agents (plan-checker, code-reviewer,
merge-checker, doc-updater, tester), hooks (guard `guard_discipline.py`, "done" gate `stop_gate.py`, work-kind advisor
`write_advice.py`),
project presets. It connects at personal scope — works in all projects.

## 1.5. Bring the machine up
In the Claude Code chat, after the restart:
```
/retainer:install
```
It checks what the hooks, the gate and the skills need (git, python3, curl, Homebrew, uv, graphify, shellcheck;
optionally node and ghostrefs) and installs the groups you pick. Two steps it cannot do for you, because macOS
asks for your password: Apple's developer tools and Homebrew. If they are missing, open the **Terminal** app
(⌘+Space, type "Terminal") and run these lines one at a time:
```
xcode-select --install
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```
Then run the lines Homebrew prints under "Next steps", **quit VS Code completely (⌘Q) and open it again** (in a
terminal: open a new terminal window and run `claude`), and run `/retainer:install` again.
A rerun installs only what is still missing. On Linux it prints the `apt` commands instead. Until python3 is
there the hooks stay quiet and protection is off; the session start says so.

Optional: a DeepSeek key turns on a second, independent opinion before risky steps. Paste it on the settings
page — `/retainer:settings`, section "Second opinion" — never into the chat.

## 2. The guard is already wired (verify, do not register)
The guard comes with the plugin: `hooks/hooks.json` attaches it to `PreToolUse` (matcher `Bash`) and `Stop`
from the versioned cache. The same file wires the work-kind advisor — `PreToolUse` with matcher
`Bash|Write|Edit|Grep`; it cancels nothing, names the skill to take for that work, and on a grep for a function name names the code-graph command. Do NOT write anything into `~/.claude/settings.json` by hand — registered there too, it would be doubled.
Restart the session (plugin hooks are read at startup) and verify with a live command — a guard probe in any project's gate.

Updating the plugin from a **directory source** (the marketplace is a folder, not a git host) requires an order:
```
claude plugin marketplace update retainer    # re-read the catalogue; otherwise update is a silent no-op
claude plugin update retainer@retainer
```
Details and rollback of the old manual wiring — `docs/guard.md`.

## 3. Global settings (once)
- Assemble `~/.config/retainer/config.toml` on the **settings page** — open it with the command
  `bin/retainer-settings.sh` (or `/retainer:settings` from the agent; like `/usage`): the page
  `retainer-settings.html` (tracker, secret paths, autonomy); paste the config with the key in your own terminal.
- A project's checks `[rigor]` are on the same page, below the project picker (`bin/retainer-settings.sh rigor` opens it there).
- Secrets are files (`chmod 600`, outside git); the config holds only PATHS.

## 4. Connect a project
Two paths, and which one you are on is decided by the tracker: the automated task lifecycle speaks
Gitea or GitLab, everything else in the box works against any host (the boundary and its figure are
in [README.md](README.md)).

Both paths run from a clone of the showcase — the plugin itself sits in a versioned cache that moves
on every update:
```
git clone https://github.com/alexuraxin/Retainer <clone>
```
The scaffold, the gate and the merge lock find the engine at `RETAINER_HOME`, or at `$HOME/retainer`
when it is unset. Clone into `$HOME/retainer`, or export `RETAINER_HOME=<clone>` — in your shell and
in the environment of the runner that runs CI.

The clone does not follow a plugin update: after `claude plugin update`, run `git -C <clone> pull`, so
the gate and the merge lock run the version the hooks run.

### 4a. With a tracker — Gitea or GitLab
**New:** `<clone>/bin/retainer-new.sh <name>` — a scaffold with full strictness out of the box (gate, guard config, CI, AGENTS.md, the task skeleton `.gitea/ISSUE_TEMPLATE/task.md`).
**Existing:** put in `.retainer/config.toml` + `.retainer/PROJECT.md`, then CI (template `<clone>/presets/ci/gitea-actions.gate.yml.template` → `.gitea/workflows/gate.yml`) and only after it `<clone>/bin/setup-repo.sh <owner/repo> --protect` <!-- retainer:allow-link: the paths are CREATED by this instruction, they do not exist in the engine itself -->

Both workflows are laid with the runner substituted — the label the project's `[ci] runner_label` declares (`self-hosted` by default):
```
sed "s/__RUNNER__/self-hosted/g" <clone>/presets/ci/gitea-actions.gate.yml.template > .gitea/workflows/gate.yml
sed "s/__RUNNER__/self-hosted/g" <clone>/presets/ci/gitea-actions.merge-lock.yml.template > .gitea/workflows/merge-lock.yml
```
Both run on a runner of your own (`runs-on: self-hosted`). Register it under your user — Gitea profile → Settings → Actions → Runners → "Create new runner" — not in one repository's settings: a repository runner serves that repository only, and the runs of every other project stay queued with nothing to take them.

The second is the merge lock: it publishes the `retainer/merge-lock` status that the gated merge path and branch protection wait for, and nothing else in a project writes it. It runs the engine from the runner, so the engine has to be on that machine, as for the gate. It waits for the gate under the template's names — workflow `name: gate`, job `gate`; a gate named otherwise is never seen, and preflight says so.

Who merges: by default the person, with the merge button. For the agent to merge itself once the lock and the gate are green, the machine needs the agent merge path — a root-owned copy of `bin/retainer-merge-gated.sh` that the person allows the agent to run. `/retainer:install` reports it in the AGENT MERGE PATH section and prints the Terminal lines that install it, the allow rule and the merge setting; nothing there is run for you.

The task skeleton is installed into an already connected project too — copy `<clone>/presets/issue-template.task.md.template` to `.gitea/ISSUE_TEMPLATE/task.md`. Without it the form of the acceptance block that the merge lock requires can only be learned from a refusal.

Order matters: Gitea treats a required status check without a workflow that publishes it as forever pending and locks merge permanently. Without the workflow the command will not set the status check and will say so out loud. The lock is required only where both workflows stand: the lock itself waits for the gate's report.

`setup-repo.sh --protect` lays 20+ labels and branch protection. Then — registration in the registry of managed projects (in your own terminal):
```
echo '<absolute path of the repo>' >> ~/.config/retainer/managed-repos
```

### 4b. Without a tracker — GitHub or anywhere else
**New project:** `<clone>/bin/retainer-new.sh <name>` still lays out the scaffold, but it writes the Gitea
workflow and the Gitea task skeleton unconditionally — delete `.gitea/` afterwards and continue from
step 2 below.
**Existing project:**
1. Put in `.retainer/config.toml` + `.retainer/PROJECT.md` — the same two files; the tracker keys simply stay unset. <!-- retainer:allow-link: the paths are CREATED by this instruction, they do not exist in the engine itself -->
2. CI: copy `<clone>/presets/ci/github-actions.gate.yml.template` to `.github/workflows/gate.yml` <!-- retainer:allow-link: the path is CREATED by this instruction, it does not exist in the engine itself -->.
   Nothing to substitute inside it, but two things have to agree with it:
   - `[ci] runner_label` in your `.retainer/config.toml` must say `ubuntu-latest`, the label this <!-- retainer:allow-link: the project's own config, created by the scaffold, not a file of the engine -->
     template runs on. The scaffold writes `self-hosted` there, and a gate step compares every
     workflow against that line — left as it is, your own gate goes red on a runner that exists.
   - the engine has to reach the runner: the template reads the repository variable `RETAINER_SOURCE`
     (and the secret `RETAINER_TOKEN` if that source is private). On a hosted runner, with neither
     set, the job goes red on delivery rather than green; on a runner of your own that already
     carries the engine, the delivery step skips itself and nothing is needed.

   Any other CI needs the same one line, `bash scripts/gate.sh`.
3. Register the project in the registry of managed projects (in your own terminal):
```
echo '<absolute path of the repo>' >> ~/.config/retainer/managed-repos
```

<!-- retainer:steps-end — the steps of this path end here; what follows names what it does not get -->

What this path does NOT get: the tracker-bound half of the box — `setup-repo.sh`, which creates
the labels and the branch protection, and the lifecycle commands, four of which step 5 names:
readiness, pickup, merge readiness, close. The issue,
the branch, the review and the merge are then yours to drive by hand; the gate, the guard, the "done"
gate and the five cycle agents are not affected and need no tracker.

## 5. The first task cycle
```
issue-first → plan → plan-checker → "ok" → code+tests → gate (green) → code-reviewer → commit → PR → merge → Compound
```
- No code without an issue. The plan passes the agent BEFORE code. The gate is one command (`bash scripts/gate.sh`) — green is mandatory.
- Every "wait for you" arrow ("ok", PR, merge) is a setting, not a law: in a long autonomous run
  the agent does not wait for them and writes forks as separate issues. The gate and review are not removed.
- code-reviewer looks for what will BREAK (three axes: spec / goal-adherence+wired / standards), not for a reason to approve.
- **"Done" is under the gate too.** Besides the commit, a Stop hook holds the check: the tests mapped to the edits
  of the working tree run at the moment the agent ends its turn. Only the owner key removes it.
- Task steps exist as commands: `<clone>/bin/retainer-ready-check.sh` (is it ready),
  `<clone>/bin/retainer-task-start.sh` (pick up), `<clone>/bin/retainer-merge-ready.sh` (can it be merged),
  `<clone>/bin/retainer-task-close.sh` (close).
- A guard refusal lands in the project's `.retainer/bypass.log`; it files no task, the log is what you read.

## Next
- `docs/HOW-IT-WORKS.md` — how it works (engine vs content, cycle, guard, gate, autonomy, rollout, boundaries).
- `docs/agent-roles.md` — the five cycle agents; `docs/SKILLS.md` — a catalogue of 17 skills (each with "when NOT to use").
- `docs/guard.md` — guard activation (a step under the owner key).
