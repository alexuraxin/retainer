---
description: "Open the retainer settings page (settings for all projects + one project's checks) locally in the browser — like /usage."
argument-hint: "[settings|rigor|all]"
---

Open the retainer settings page with the local opener (no egress; the page reads the local `~/.config/retainer`):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/bin/retainer-settings.sh" $ARGUMENTS
```

Opens `docs/settings-page/retainer-settings.html`: at the top what is common to every project (tracker, secret paths, `autonomy_level`, git flow, tools), then a project picker, then that project's checks (`[rigor]`). The argument `rigor` opens the same page at the project part; `settings` and `all` open it at the top.
