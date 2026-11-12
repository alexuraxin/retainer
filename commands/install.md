---
description: "Bring this machine up to what retainer runs on — check what is missing, then install what the person allows."
argument-hint: "[recommended|pages|ghostrefs]"
---

Set up the machine for retainer. Speak to the person in their language; they may be installing developer tools for the first time.

1. Run the check and show its output to the person verbatim, in a code block:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/retainer-install.sh"
   ```

2. If the output ends with lines to run in Terminal (Apple developer tools, Homebrew), do not run them yourself: they ask for the computer's password. Tell the person to open Terminal (⌘+Space, type "Terminal"), paste each line, wait for it to finish, and write "done". Then run the check again. Repeat until the required group is complete (exit 0).

   The AGENT MERGE PATH section is optional and is the person's alone. When it prints lines, show them and say what they give: the agent merges a pull request itself once the merge lock and the gate are green, instead of waiting for the person's button. Do not run the `sudo` lines, do not edit `~/.claude/settings.json` for the allow rule, and do not change the merge setting: the person does all three, or leaves the section as it is.

3. Ask which optional groups to install, with the question tool (multi-select). Offer only groups that still have missing tools; `recommended` goes first and is marked recommended. If `$ARGUMENTS` names groups, use those and skip the question.

4. Install the chosen groups and show the output:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/bin/retainer-install.sh" --install <groups>
   ```

   A line marked ✗ is a failed step: say which one, and that rerunning `/retainer:install` retries only what is still missing.

5. If the DeepSeek key is missing, say that it enables a second, independent opinion before risky steps and is optional. If the person has a key, open the settings page with `/retainer:settings` and ask them to paste it into the "Second opinion" field there. Never ask for the key in the chat.

6. Finish with a short summary: what is installed, what was skipped, the agent merge path's state, and the next step — `retainer new <name>` for a new project, or `/retainer:retrofit` to connect an existing one.
