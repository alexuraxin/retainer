# Guard

One hook (`hooks/guard_discipline.py`) for every repository that has `.retainer/config.toml`. It checks
each `Bash` command before it runs and blocks five things:

| Rule | Blocks | Switch in `.retainer/config.toml` |
|---|---|---|
| Destructive acts | `rm -rf`, `find -delete`, `find -exec rm`, `dd`, `git reset --hard`, force push (`--force`, `-f`, `+ref`), a push that deletes remote branches (`:ref`, `--delete`, `--mirror`), `chmod -R`, shutdown; the same inside a heredoc piped into a shell | `guard_destructive` |
| Secret egress | a secret file sent to an outside host; remote code piped into a shell | `guard_egress` |
| Its own wiring and keys | writes to `~/.claude/settings.json`, `~/.claude/hooks` (and the same two under `CLAUDE_CONFIG_DIR` when it is set), the managed-projects list, the owner keys | always on |
| New dependency | `pip install X`, `poetry add`, `uv add`, `npm i X`, also inside a heredoc piped into a shell | `guard_dependency` (on by default) |
| A config it cannot read | every command in a repository whose `.retainer/config.toml` leaves an array or a multiline value unclosed, or is not UTF-8 | always on |

Not blocked: a single `rm file`, a normal `push`, installing what is already declared (`npm ci`,
`pip install -r`, `uv sync`, `pip install -e .`), system managers like `brew`.

The guard judges only `Bash`. File edits (`Edit`, `Write`) are closed by the harness `deny` rules, not by the
guard. A rule in `~/.claude/settings.json` must use `Edit(//full/path)` or `Edit(~/path)`: a single leading
slash points inside `~/.claude/` and closes nothing, and `Write(...)` rules are ignored.

## Where protection ends

- **A rule names a path, not a repository.** A second working tree (`git worktree add`) or a clone
  in another directory holds the same tracked files under another path, and no rule written for
  the main tree covers it. Such a tree is open to edit tools until a rule names its path.
  `bash ~/retainer/bin/retainer-deny-sync.sh <that tree>` shows it red and prints the rule to paste.
- **Git changes protected files without a write.** `checkout`, `pull`, `merge` and `revert` replace
  the content of a protected file, and a commit carries whatever edit lies in the tree, the owner's
  included. The `deny` rules close edit tools, and git is not one. The guard stops `git checkout .`
  and `git restore .` only as destructive acts, not for what they put into a protected file.
- **`deny_sync` counts a path as covered by any rule over it.** One rule on the tree root or on a
  directory above it (`Edit(//<root>/**)`) covers every `protected` entry, and
  `Edit(//<root>/hooks/*.py)` covers `hooks/guard_discipline.py` but not `hooks/hooks.json`. Not
  counted: a rule that starts with a pattern, holds a bracket class, or names the root with a
  trailing slash (these are listed to check by eye); a bare pattern matching a directory (`h*`,
  write `h*/**`); a pattern above the root (`//x/repo-*/.retainer/**`).
- **Destructive acts are found by a coarse match on the command text.** Spellings outside the list
  pass: combined or abbreviated flags (`git push -df`, `--dele`), `git push --prune`,
  `find … | xargs rm`, `find -exec sh -c 'rm …'`, a verb called by full path (`/usr/bin/find`). A
  `#` inside a word ends the command for the guard but not for the shell, so whatever follows it
  (`echo a#; rm -rf app`) goes unjudged.

## Turning it on

The plugin wires the guard itself (`hooks/hooks.json`). Nothing goes into `~/.claude/settings.json`; remove
any old manual wiring, or the guard runs twice.

A project needs:

- `.retainer/config.toml` with `protected` (template: `presets/retainer.config.toml.template`);
- the lines from `presets/gitignore.workstate` in `.gitignore`.

No config, no guard: an unmanaged repository is skipped.

## Unlocking

Only the owner creates the key, in their own terminal: `touch <repo>/.retainer/unlock`. It is an empty file
and expires after 30 minutes. The guard's own wiring is unlocked by the global key `~/.retainer/unlock`.
The agent cannot issue either key: the guard refuses the write (touching a key that is still valid passes).
The check is a coarse match on the command text, so a write after `cd` into the key's directory, or through
a writer outside its verb list, still passes. The same match also refuses a command that only names
another tree's `.retainer/unlock` next to a write verb, a search or a message text included.
The project key also lifts the refusal on a config the guard cannot read. When the broken file lost or
broke its own `unlock_file`, the default `.retainer/unlock` is the key.

## Checking it works

```bash
bash ~/retainer/bin/guard-wiring-check.sh --project <path>
```

`0` the gate calls the engine check · `1` the gate checks wiring on its own · `2` no gate found ·
`4` no check step · `5` the wiring points to a missing file (the agent runs unguarded).

An older project whose `gate.sh` reads `~/.claude/settings.json` directly migrates once:
`bash ~/retainer/bin/adopt-managed-plugin.sh <path> --dry-run`, then without `--dry-run`.

## Updating

With the marketplace added as a folder, refresh the catalog first, or the update silently does nothing:

```bash
claude plugin marketplace update retainer
claude plugin update retainer@retainer
```

Then restart the session. `claude plugin list` shows the installed version.
