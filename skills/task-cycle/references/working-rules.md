# Task cycle — working rules

Read when the work reaches one of these rules. The core is `../SKILL.md`; this file holds the
rest of the rules the core names here.

## Externalizing task context — decisions and questions in a durable record

Grooming reasoning, decisions made and open questions of a task live in its **durable record in the
tracker**, not in the agent's memory or an ephemeral scratchpad/chat — so that context is not
re-derived each session (tokens) and survives compaction/pickup. This is step 11 Compound, but for
the context of ONE task: Compound sends cross-task knowledge to memory/`PROJECT.md` (a different
home), while the `double-reasoning` self-report below catches when context is NOT externalized (went
into the same reasoning twice).

- **The canon is the issue body (edit-in-place), not the comment feed.** A block "Decision (date) ·
  Open questions · Dependencies". One record to read = minimum tokens; one place = minimum drift;
  "replace, do not append" comes out by itself — editing the body is replacement. A comment is only
  an optional audit line ("changed X to Y, date"), not the source of truth.
- **Re-verification on taking the task.** Task order and priority may have changed since grooming —
  reread the body before starting, do not trust old context blindly.
- **Dependencies by the tracker's native ref, expanded lazily.** A linked task's ref (`#N` and the
  equivalent in another tracker) is a pointer, not a load: pull the linked task into context ONLY
  when you take the dependent one into work, not the whole tangle at once (bulk-loading the chain
  also eats tokens). The tracker renders the ref's state itself → staleness is visible, no manual
  upkeep.
- **The boundary with memory — one fact, one home.** Memory (step 11) is durable knowledge and
  pitfalls that outlive the task (cross-task, per project; owner preferences are a separate global
  layer); the context of a specific task/grooming is its tracker record. Do not duplicate.

The residual risk is a second place where truth lives (drift). Managed in-built: edit-in-place (no
diverging copies) + re-verification on taking. Do NOT introduce a hierarchy (epics/milestones) for
the sake of linkage itself — lazy refs hold it; heavy grouping of a small tracker is complexity for
complexity's sake.

## Self-report of deviations (deviation journal)

Behavioral deviations are mechanically unreliable to detect → we catch them by self-report in
`docs/DEVIATION-JOURNAL.md` (honesty-based, complements the error journal and RATCHET). Three
classes, write **IN THE MOMENT**:
- `rule-deviation` — a conscious departure from a rule: which · why · how to restore rigor;
- `post-facto-bypass` — a bypass found after the fact → a retro entry;
- `double-reasoning` — went into the same reasoning twice / redid what was decided → a signal of
  NON-externalization, move the decision durable.

What the guard catches mechanically (`.retainer/bypass.log`) is NOT duplicated here — only what the
guard did not catch.

## Decomposition: tracer bullets and wide refactors

**Tracer bullet (vertical slice).** Cut the work into slices, each a narrow but COMPLETE path
through all layers (schema → API → UI → tests), demonstrable on its own, the size of one context
window. Not a horizontal slice of one layer. Each slice declares its blocking edges (what must
finish earlier). A slice with no blockers starts at once.

**A wide refactor is the exception, the expand–contract pattern.** One mechanical change fanning
across the whole base (rename a field, retype a shared symbol) does not fit a tracer bullet: a
single edit breaks thousands of places at once. Sequence:
1. **Expand** — add the new form ALONGSIDE the old, breaking nothing.
2. **Migrate** — move callers in batches by blast radius (per package/directory), each batch its own
   task, gate green between batches (the old form still exists).
3. **Contract** — remove the old form when no callers remain (the task is blocked by all batches).

This is exactly our donor-module cuts: not one commit, but expand → migrate by slices → contract,
keeping the gate green at each step.

## A comment answers ONE question

What this code does. Plus, if non-obvious: under what condition it fires and what it deliberately
does NOT do. Rationale stays when it changes application ("fail-closed, because a check's silence is
not cleanliness"); retelling the past does not.

Three things are forbidden, and all three rot faster than the code: what stood here before, what it
cost, what measurement showed it. History lives in the CHANGELOG, journals, ADRs and task bodies —
there it is content. A test docstring explaining WHICH CLASS is guarded is a description of the
subject, not a retelling, and stays.

The rule is held by you, not a machine: a comment answers WHAT the code does and why so, and does
not retell the task.

## Deep modules (design vocabulary)

When designing an interface, aim for a **deep module**: much behavior behind a small interface. A
**shallow module** (interface almost as large as the implementation) — avoid. **Deletion test:**
would deleting the module concentrate complexity or just smear it? "Concentrates" — the module earns
its place. **Interface = test surface** (what cannot be checked through the interface is hidden for
nothing). Keep the terms exact (module/interface/implementation/seam/depth), do not swap them for
"component/service/API". Pairs with the project vocabulary — [[task-cycle]] and the project glossary.
