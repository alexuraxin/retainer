# Retainer agents

Five agents: separate subagents the cycle calls at a fixed step, so the work is checked by someone other
than its author. Prompts live in `agents/<name>.md`; project specifics come from `.retainer/PROJECT.md`.
A project does not keep its own copy of a cycle role: the `agent_canon` gate step catches a duplicate.

| Agent | When | Answer |
|---|---|---|
| plan-checker | before code | `PLAN OK` · `THERE ARE CONTRADICTIONS` · `NEEDS CLARIFICATION` · `CANNOT START` |
| code-reviewer | before the commit | findings, or approved |
| merge-checker | before the merge, after a green `retainer-merge-ready.sh` | `MERGE-CLEAN` or blocking findings |
| doc-updater | after the task | updated docs |
| tester | only on request | what broke in the live UI |

**plan-checker** checks the plan against the project docs and practices: files, a sample to follow,
known pitfalls. "Cannot start" means no code.

**code-reviewer** looks for what will break: does the code do what the task promised, is it wired in,
does it follow the project's practices.

**merge-checker** compares what was done with what the task declared: criteria, files, boundaries, tests for
edits that carry a use case. It starts cold, without the author's session.

**doc-updater** brings epic statuses, the architecture doc and the debt journal in line with the code.

**tester** opens the app in a browser (Playwright) and tries to break the feature.

How they fit into the cycle: [HOW-IT-WORKS](HOW-IT-WORKS.md).
