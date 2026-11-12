# Task cycle — step 11, Compound

Read before writing a lesson. The core is `../SKILL.md`; this file holds the rest of the rules
step 11 names there. The order of forms and the `retire_when` line are adapted from
compound-engineering (MIT, see `THIRD-PARTY-NOTICES.md`).

## Pick the form: try these in order, take the first that holds

A note is read every session and still does not stop the repeat; a check costs nothing to keep and
stops it on its own.

1. **One owner, one way.** The mistake was possible because two ways to do the same thing exist.
   Merging them changes working code, so this step does not do it: name it to the owner as work,
   and hold the lesson in the next form that fits meanwhile.
2. **A check** — a test, or a lint rule in the lint setup the repo already runs. It holds when the
   check sees the defect, runs where the repo already runs its checks, and its failure tells the
   reader what to fix. **Keep a check only after you saw both:** it passes on the current tree, run
   the way the repo runs it, and it fails on the defect's shape in a throwaway copy of the tree.
   The working tree never holds the defect, not even for a moment. Cannot show both → undo the
   check, name it in the note as the check to write, and go to the next form. A check that needs
   working code changed, a new tool or a new dependency is not written here either: it is named
   the same way.
3. **A rule** — one line in "What NOT to do" of `.retainer/PROJECT.md`. It holds when the defect is
   one an author must avoid while writing and a reviewer can see in a diff, and no check can catch
   it. One condition, in that section's style, true without volatile numbers or names. No such
   section in the project → do not create one: the note holds the whole lesson.
4. **A note** — auto-memory, or "Known pitfalls" in `.retainer/PROJECT.md`. For the reasoning a
   check or a rule cannot carry: measured facts, rejected options, why. Correcting a note that
   became wrong stays in this form.

A check or a rule already states the lesson → write nothing and say which file holds it. After
writing a check or a rule, ask again what would still be lost; write a note only for that, and
have it name the check or rule. When a check was named but not written, the note holds the whole
lesson and names the check, so the lesson survives if nobody writes it.

## A note names when it stops being true

When a note holds only while something outside the repo holds — an open bug upstream, a tool or
platform version, a service's behaviour — add an optional `retire_when:` line (in a memory note
under `metadata:`, in a pitfall as its last line): the outside change that ends it, and how to
check for that change without editing the repo. Without such a dependency, leave it out. Example:

```
retire_when: Gitea's API gains a cancel route for Actions runs; check the API docs of the Gitea version this machine runs
```
