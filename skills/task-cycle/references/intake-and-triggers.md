# Task cycle — intake and triggers

Read at intake and before planning. The core is `../SKILL.md`; this file holds the
rest of the rules the core names here.

## Task intake — the rest

**Scope larger than one session — map first, cycle second.** If what you took on does not fit one
run (an epic, "where to start", several unrelated ends), the cycle does not begin here: the route
is first laid out into decision tickets. The `retainer:wayfinder` skill is user-invoked — the agent
does not launch it: tell the owner the scope needs a map and name the command `/retainer:wayfinder`.
The cycle takes a separate ticket once the map exists.

*Why this step exists.* The autonomous-run rule "ask no blocking questions" governs forks INSIDE a
task, not the question of what the task IS. Confusing the two spends a whole session on the wrong
work — an error no later task can fix. So the boundary is confirmed before work begins.

**Two questions that must not be mixed:**

| | question about a FORK inside the task | question about the task BOUNDARY |
|---|---|---|
| policy gate | `ask_owner` | `confirm_intake` |
| in an autonomous run | forbidden — `open-question` issue with a default | allowed, the step is not removed |
| cost of error | fixed by the next task | all the work is the wrong work, nothing fixes it |

Confirmation is asked through the question tool, `AskUserQuestion`: the reading you took first, the
other reading second, with the line `handoff: boundary — <what is unclear>` in the text for the gate
(see "The decision itself goes through the question tool" in `stop-and-ask.md`). No machine closes the tool itself —
the guard does not read `ask_owner` and hangs on `Bash` only; what is judged is the OUTCOME of the
turn, by the handoff judge in `stop-and-ask.md`.

## Step 0 — Triggers: the rest

Typical triggers (Python/Django preset):
- adds a screen / new queryset → N+1 detector (`django-zeal`);
- HTTP call to an external API/LLM → mock layer in tests (`pytest-httpx`);
- touches module structure / imports → `import-linter`;
- introduces a new model → migration linters.

**Four codes are not all the triggers: the resolver knows no SKILL at all.** Having checked them,
the "triggers checked" item cannot be closed: skills have their own triggers, and many are "call
BEFORE" ([[complexity-budget]] before introducing a component, [[diagnosing]] before the first edit
on a bug, [[frontend-taste]] before the first line of markup, [[graph-first]] before searching by
grep). Check against the project's skill list, not the resolver's four codes.

The [[complexity-budget]] trigger is introducing a new component, layer, abstraction, dependency or
config, including when the component is born mid-work out of a review finding. It must be called
explicitly; a paragraph about complexity written into the plan in your own words is not a call.

This trigger is enforced not by memory but by the `complexity_trace` gate step: a new code file
(`.py`, `.sh`) without the line `# complexity: keep, step <1-7> — <what breaks without the component>`
reddens the gate.

**Other triggers have no machine, or a weaker one — and this must be known by name, not in
general.** The by-work advisor knows exactly the kinds of work listed in its table (for example, a
markup edit names [[frontend-taste]]). The list lives in the table, not here: both a line count and
a prose list rot on the next kind of work, equally silently. The agent reads the hint together with
the call result, i.e. the FIRST file of a kind of work is written without it.
[[diagnosing]] has no machine at all: its trigger is not a file-write event. [[graph-first]] has one:
a grep for a code name gets the graph command from the same advisor.
The advisor's rule on the complexity budget is deferred to a separate task. Everything not named by
a machine here is held by this page — and waiting for a hint from a machine that does not exist
means never calling the skill. A red step is no reason to stop, even in an autonomous run — the
decision is made by whoever introduces the component, and recorded by that same line.

*Why this rule exists.* A rule that is not mandatory reading does not get followed: a tool that
should have been on before the task gets opened only after the fact, and the defect it would have
caught (N+1) is caught by hand instead. Hence: triggers are step 0, before everything.
