# Task cycle — step 1, the plan

Read before writing the plan. The core is `../SKILL.md`; this file holds the
rest of the rules the core names here.

## Step 1 — Plan: the rest

   - The same marker (the core, step 1) goes into the issue body: the plan lives to the end of the session, the issue
     lives longer. An unmarked ambiguity found by the checker yields a "NEEDS CLARIFICATION"
     verdict, and the `plan-checked` marker is not set with it — i.e. no code is written until a
     trace is left.
   - **A defect found along the way is routed by "same work, or another?" below, not filed by
     reflex.** What stays mechanical is the DECLARATION: an edit that widens the diff is declared
     where the machine reads — the issue body or a comment on it, never only the pull request.
     The rule is mechanical:
     `${CLAUDE_PLUGIN_ROOT}/bin/retainer-scope-check.sh <owner/repo> <N>` compares new module-level
     names and new files in the diff against what is declared in the issue body and its comments.
     Not `exit 0` — either the scope grew undeclared OR a new code file names no sample, and these
     are not the same: the step's message says what did not match. The step strips the issue-skeleton
     hints before parsing — otherwise it would take its own template form for a declaration.
     Call it **from the project directory**: the call tree is what is measured; the argument only
     says where to read the task. Outside the repository the command refuses rather than silently
     checking a foreign tree.
     The diff-boundary check does NOT catch this class: an edit that removed a protection in seven
     forms touched exactly the declared files, the scope grew WITHIN them.
   - **The completion report names what was deferred** — the list of tasks created along the way.
     Empty after a long session is a signal that findings drowned in the volume, not that there
     were none.
   - **Same work, or another? — asked BEFORE a finding becomes a task.** The question is about the
     SUBJECT, not the file: a task is undercut when the system is left inconsistent after it, and
     oversplit when two tasks share one subject. "Small" means one edit and one probe. Five ways,
     first fit wins:
     1. the SAME subject, and it is an EDIT — absorb it: the task takes the file it needs, and a
        NEW file goes into the `"Files:"` block of the issue BODY. A comment suffices only for an
        edit inside a place the block already claims: the readiness check reads that block and never
        the comments, so a file announced only in a comment stays invisible to the task groomed
        tomorrow, which declares it in turn and starts against you. If the file is already declared
        by a task labelled `ready` or `in-progress`, absorb it anyway and say so in a comment to
        that task, or record a deviation — that check judges collisions from the lists BEFORE a
        start and never revisits a widening made mid-work, so this one collision is yours to hand
        over, not the machine's to catch.
     2. the SAME subject, and it is a QUESTION — it does not become a task and does not become an
        edit: record it as a `[CLARIFY: ...; default: ...]` marker (the core, step 1) in the issue body, and
        proceed by the default.
     3. a different subject, small, in a file this task already edits AND no task labelled `ready`
        or `in-progress` declares — fix it now and declare it the same way. Which carrier HOLDS
        that declaration depends on the file: the scope check reads module-level names in `.py` and
        `.sh` outside `tests/`, `presets/` and `docs/`, so a widening by document, preset, skeleton
        or test is held by the merge gate role alone. A file another working task declares is not
        this way even when your diff already touches it — that is the next one.
     4. a different subject, in a file declared by a task labelled `ready` or `in-progress` — a
        comment into that task, where its executor reads.
     5. a different subject otherwise — a new task when it is large, needs a product decision, or
        cannot be done from here; when it is small and no task holds the file, fix it and declare
        it. A finding is never dropped: losing findings costs more than splitting.
   - **An input→output map for data/metrics:** if the task touches a measure field / a formula /
     a screen, the plan explicitly records: where the field is FILLED (input), where it is COMPUTED
     (aggregation), which screen SHOWS it (output). No output — an honest stub + an issue, not
     something ephemeral in text.
   - **Task format** (from writing-plans): exact file paths (Create/Modify/Test), an **Interfaces**
     block (what the task consumes and what it returns — exact signatures), micro-steps in
     TDD rhythm. Plus a **"Files:"** block — so two tasks that MAY run at the same time do not
     collide in one place of a file (a bare path claims the whole file). The block bounds
     PARALLEL work, not this task: the unit of a task is a state of the system that is
     CONSISTENT after it, so one task takes as many files as that state needs. Three carriers
     of one datum are one task across three files; two independent edits in one file are two
     tasks.
   - **A sample for every new kind of code.** A **kind of code** is the thing whose form a new file
     must repeat, and the list is CLOSED: scenario, repository, external-call adapter, view,
     migration, fixture, test, gate step, role, skill. NOT a kind: a new function inside an existing
     file, an empty structural file (a package declaration, a typing marker), a changelog fragment,
     a document, fixture data. An open list would give two different answers for one new file, and
     the checker's verdict here is binding — the cost of error is higher than the value of breadth.
     The definition lives here and only here; roles reference it rather than repeat it: two lists
     diverge silently, and that is exactly the class this rule closes.
     The plan names the address of the file the new artifact repeats:

         Sample: <file>            or    Sample: <file>:<line>
         Sample: <file>#<anchor>    (function name, class, or section heading)

     A form taken from a live file does not diverge from the tree; a prose list of standards
     diverges silently — and neither side notices. The line and anchor are optional: the file is
     enough, they only shorten reading. **A line number rots faster than the plan lives** — a
     neighboring task shifts the file's contents by dozens of lines; so a shifted address means
     "check by anchor or by content", not "no sample named". A sample is unnamed exactly when there
     is no file at the address at all, or no line in the plan.
     No sample in the PROJECT — the address points into the kit forms,
     `${CLAUDE_PLUGIN_ROOT}/presets/python/forms/`; the list of FORMS is in that directory's README,
     and framework-bound forms are in its preset module. A project sample overrides a kit form:
     project code is fresher than any template and knows decisions the template does not.
     <!-- claim: test -d presets/python/forms -->
     **Forms do not cover all kinds, and the list of kinds stays ONE — the one above.** The
     directory README lists forms, not kinds, and must not be read as a list of kinds: two lists
     diverge silently. A kind covered by neither the project nor the kit is a legitimate "no sample,
     new kind", and the plan says so directly, otherwise the checker reads silence as a forgotten
     step.
     **The address goes into the issue body** together with the ambiguity markers: the plan lives to
     the end of the session, but review reads the issue — without this line the reviewer has nothing
     to check against, and the rule lives one round. There is a slot for it in the canonical issue
     skeleton — the "Sample" section (`presets/issue-template.task.md.template`). Into that section,
     not the "Files:" block: there the address would read as a file of THIS task, and the readiness
     check would find a false collision with the task the sample actually edits.
     **A denial is written just as explicitly**, one line in the plan and in the issue body:

         No new kinds of code

     Without it, silence is indistinguishable from an omission, and the outcome depends on the run
     rather than the rule: review sees a new file and does not know whether the address was forgotten
     or there really is no kind.
     **Changing a kind's form deliberately is the third legitimate case.** A task that was
     undertaken precisely to change the form (a new canon, a different layer, another contract) names
     the sample AND says HOW the new form differs from it and why. Then divergence from the sample is
     execution of the plan, not a finding; review checks that they diverged exactly as declared.
     Without this case the rule would penalize exactly the tasks that change the canon.
     Project practices (`.retainer/PROJECT.md`, `.retainer/practices.md`) are read TOGETHER with the
     plan, not after the code: a rule that only reaches review lives one round and is forgotten with
     the task. Into the project document a practice goes as a rule plus a sample address, not as a
     code quote: a quote ages silently, an address leads to what exists.
     **Distilling practices FROM the code (the writer).** The layer has readers — the review and plan
     roles — and it has a writer: on reaching a rule that is about a CLASS (the form of an artifact,
     where a decision lives, what counts as a sufficient check) the role records it in
     `.retainer/practices.md` by the template form. A one-off mistake is not a class — its home is the
     error journal. The order:
     Order: copy `${CLAUDE_PLUGIN_ROOT}/presets/practices.md.template` into `<project>/.retainer/practices.md`
     (a new project gets it scaffolded) → for each kind of code read the two or three files the project's
     reviewers wrote (whoever has the most edits in that directory) → record the rule in one phrase with a
     `Sample: <file>:<line>` address and a `Distilled: <date>`. A rule without an address is not recorded:
     it means "this is how it seems to me", and the roles would then judge foreign code by it. What is NOT
     recorded: what a machine already enforces (a linter, import contracts, gate steps), and one-off
     mistakes. The record form is held by the `practices_form` gate step, not by memory.
