# Task cycle — when to stop and ask

Read before ending a turn on a question, a wait or a handoff. The core is `../SKILL.md`; this file holds the
rest of the rules the core names here.

## When to stop and ask — the rest

- **`auto`** — the list below is in force: ask, do not guess.
  How to ask: **one question at a time**, with a recommended answer for each. Facts
  (filesystem, code, configs, tool output) get yourself — leave the owner only what they
  decide. A batch of questions and a question whose answer is in the tree equally steal time.
- **`off`** — blocking questions are forbidden (a long autonomous run, no one to wait for).
  **Enforced, not advisory:** the Stop gate refuses a turn that ends in a question or in a wait form
  addressed to the owner while code edits lie in the working tree or the session has a task of its
  own — planning and grooming leave the tree clean, and a stop there is still a stop. A session
  whose shell left every repository is judged in the tree it took its task in. A handoff that IS legitimate
  declares its ground in the same message, on its own line:

      handoff: <code> — <what exactly is blocked>

  Codes — the machine form of the exception list below: `destructive` · `owner-key` · `native-deny` ·
  `self-approval` (merging your own PR) · `boundary` (the question is about the task boundary, not a
  fork; spent once the task's plan is checked — the boundary was confirmed at intake) · `pointless` (work under any assumption is knowingly useless). A code outside the registry is
  not a ground. A form that FAILED does not free the turn either: a misspelled code or a missing dash
  still refuses. What is checked is the presence, the form and the code — not the truth of the ground.
  A fresh turn is always judged; the refusal budget of three is spent only while the harness keeps
  re-entering the same turn, so one false positive does not jam the run and three refusals earlier in
  the session do not switch the judge off. The counter is not reset, so a later chain yields on its
  first repeat — the guarantee is about the fresh turn, not about every chain getting three.
  The only legitimate exit from a fork: an issue with the `open-question` label — fork, options, chosen
  default — and work continues by the default. Name the default in the PR and in the task comment.
  A cycle agent's verdict reads the same way: a "product choice" from plan-checker is not an owner's
  prohibition but a note that the choice is yours. A subagent can neither permit nor forbid.

**The decision itself goes through the question tool.** A handoff on a legitimate ground other than
`pointless` puts the owner's decision to them in the same turn with `AskUserQuestion` — the options,
the recommended one first — under either value of the gate. A fork inside the task is not such a
ground: under `off` it still goes to an `open-question` issue, and under `auto` it is asked the same
way, through the tool. The `handoff:` line stays in the text
for the gate, and it ends the text when the tool is unavailable (a headless run) or the question is
dismissed: the gate reads only the last message. A question left as a paragraph inside a status
report is not seen as a question. While it is open, each turn boundary repeats only the `handoff:`
line, with one more line when something changed — no "waiting" message. An empty turn is no answer:
without the line the standstill judge asks again on the third unchanged boundary. Nothing machine-checks that the tool was called: the
refusal texts carry this rule, a turn with a correct `handoff:` line passes either way.

The cost of waiting is greater than the cost of a wrong default: a default is fixed by the next task,
idling is fixed by nothing. What `off` does NOT cancel: the irreversible and destructive (deleting
data, force-push, someone else's work), a resource the agent does not grant itself (the owner's key
to a protected file), the case where work under any assumption is knowingly pointless — and **the
confirmation of understanding of the task itself**: it is held by the separate `confirm_intake`
gate, and `ask_owner = off` does not quench it. Everything else is no reason to stop.

Cleaning your own trail (closing YOUR task, deleting YOUR merged branch) does not fall under
"destructive" — it is a flow step. Destructive here is someone else's and unrecoverable.

- An ambiguous requirement, a product choice not made → ask, do not guess.
- A task blocked (awaiting a decision/dependency) → label `in-progress`→`blocked` (and back on
  unblock); the `active-label` preflight accepts `blocked` on par with `in-progress` — a halt does
  not break enforcement.
- Data entered as input but output nowhere → issue + input→output map.
- A new runtime/dependency needed → the owner's decision, do not install it yourself.
- A decision looks like a forgotten loose end rather than a fact → ask, do not "fix" it in passing.
- Tests red / a migration landed / the server fell → rollback protocol, show the root cause, do not
  mask with edits on top (see [[guardrails]] and systematic-debugging).
- A guard refusal / a deferred edit of a protected file → a line in the error journal AT ONCE, in
  the moment.
