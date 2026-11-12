<p align="center">
  <img src="docs/assets/hero.svg" width="480" alt="Retainer">
</p>

<h1 align="center">Retainer</h1>

<p align="center">
  <b>Discipline for AI coding agents.</b><br>
  It checks what the agent did, not what it said.
</p>

<p align="center">
  <a href=".claude-plugin/marketplace.json"><img alt="version" src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fraw.githubusercontent.com%2Falexuraxin%2FRetainer%2Fmain%2F.claude-plugin%2Fmarketplace.json&query=%24.plugins%5B0%5D.version&label=version&color=4F46E5"></a>
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-4F46E5"></a>
  <img alt="Claude Code plugin" src="https://img.shields.io/badge/Claude%20Code-plugin-7C3AED">
</p>

---

An AI agent under pressure takes the cheapest path: it writes code with no task behind it, weakens
the test that is in its way, and says "done" without running anything. A rule in the prompt does not
stop that — the agent drops the rule with the same motion it drops the code.

Retainer moves the rules out of the agent's reach: into hooks that run before its commands, a gate
that runs before its commits, and a merge lock the tracker enforces. One plugin, the same rules in
every project.

## What you get

| | |
|---|---|
| **Task cycle** | issue → plan → plan check → code → gate → review → merge, with five role agents checking the plan, the diff and the merge |
| **Guard** | blocks the irreversible before it runs: `rm -rf` on work, force-push, secrets leaving the machine, new dependencies, edits to its own wiring |
| **One-command gate** | format, lint, types, tests, architecture contracts — a fast subset on commit, the full gate on push and in CI |
| **"Done" gate** | when the agent ends its turn, the tests for what it touched run; on red the turn is refused; when the machine has no free test slot for the whole wait, the run is skipped with a visible note, and a red goes unseen that turn |
| **Autonomy dial** | from "asks before every step" to a marathon that merges on its own — review and the gate stay on at every level |
| **One home for rules** | the engine is shared; a project adds only what to protect and its own pitfalls |

## How it works

<p align="center">
  <img src="docs/assets/diagrams/flow.svg" width="960" alt="A command passes the guard, which blocks the irreversible; the code passes the done gate, review and gate, and the merge lock before it reaches main">
</p>

The full picture — cycle, guard, gates, autonomy, rigor regulators — is in
[How it works](docs/HOW-IT-WORKS.md).

## Install

You need [Claude Code](https://claude.com/claude-code) — the Claude panel in VS Code, or `claude` in a
terminal. Lines starting with `/` are typed into the **Claude Code chat**, not into a shell.

**1. Install the plugin** — in the Claude Code chat:

```
/plugin marketplace add alexuraxin/Retainer
/plugin install retainer
```

If macOS opens a window offering to install "command line developer tools", click **Install**, wait for it
to finish, then repeat the two lines.

Restart Claude Code so it loads the plugin: in VS Code, ⌘⇧P → "Developer: Reload Window"; in a terminal,
exit and run `claude` again.

**2. Bring the machine up** — in the Claude Code chat:

```
/retainer:install
```

It shows what is installed, what is missing, and installs the rest with your OK. Two steps it cannot do
for you, because macOS asks for your password: Apple's developer tools and Homebrew. If they are
missing, open the **Terminal** app (⌘+Space, type "Terminal") and run these lines one at a time:

```
xcode-select --install
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Then run the lines Homebrew prints under "Next steps", **quit VS Code completely (⌘Q) and open it again**
(in a terminal: open a new terminal window and run `claude`), and run `/retainer:install` again. On Linux
it prints the `apt` commands instead.

Optional: a DeepSeek key turns on a second, independent opinion before risky steps. Paste it on the
settings page — `/retainer:settings`, section "Second opinion" — never into the chat.

**3. Connect a project** — about 15 minutes: [Onboarding](ONBOARDING.md).

To update: `/plugin marketplace update retainer`, then `/plugin install retainer` again — without the
first command the second installs the cached version.

**Needs:** Claude Code, git, bash and Python 3. Works with any git host; the automated task lifecycle
speaks Gitea or GitLab.

## Documentation

- [How it works](docs/HOW-IT-WORKS.md) — the cycle, the guard, the gates, autonomy
- [Onboarding](ONBOARDING.md) — installation and the first task
- [Agent roles](docs/agent-roles.md) — the five cycle agents
- [Skills](docs/SKILLS.md) — the skills catalogue
- [Guard](docs/guard.md) — guard activation

This repository is the built plugin itself: every folder you see here is exactly what lands in your
project, and you can read all of it. The engine is developed in a separate tree with its own tests and CI.

## License

[MIT](LICENSE)
