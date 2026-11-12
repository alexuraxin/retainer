# Task cycle — review and merge

Read before the review round and before the merge. The core is `../SKILL.md`; this file holds the
rest of the rules the core names here.

## Step 6 — code-reviewer: the rest

   **Two rounds by default.** A cheap pre-commit pass and the final pass on the PR head. A third
   round only for a NEW blocking finding, not a reworded old one; beyond that, findings go out as
   follow-up tasks, not another role run — the loop fix → run → nth nitpick burns more than it catches.

   **The verdict is recorded together with the COMMIT it was made on:** the outcome comment carries
   the line `review-sha: <sha>` (the branch head at read time). The label says "read", but not WHAT
   was read: between the verdict and the merge the branch moves, and what is merged diverges from
   what was reviewed. The identity check is held by `retainer-merge-ready.sh` — a divergence or a
   missing record blocks the merge.

   **The record must name WHO did the review, and a self-check is called a self-check.** A record
   "review done by the author of the change — a self-check" is legitimate and honest, while silence
   about the performer reads as a claim to an independence that was not there. Independence is given
   not by a comment field but by the role's cold start: the author remembers why they wrote it that
   way, and that memory works as a ready justification for every finding.

   **The verdict is a self-declaration, and the machine knows it.** Exactly one thing is checkable:
   a record exists and it is about the head being merged. WHO left it is checked by no one: there is
   one tracker account, and the machine signal of a role run was removed together with the guard's
   procedural layer. A reader without a writer would refuse every PR — it would be a wall, not a
   lock. Hence the requirement is on you, not the machine: the role is actually called, and a
   self-check is called a self-check in the text of the record.

   **The run that counts is on the head that will go into the merge.** A run before commit catches
   findings cheaply but reads the commit's parent: the next commit moves the head, and the
   `review-sha` record no longer applies to it. So the LAST role run goes after the last commit and
   push — on the PR head — and only then is `review-sha` written. A fix per findings moves the head
   and zeroes the verdict: the final run must be clean, otherwise the cycle repeats. Intermediate
   runs do not lose their point — they are cheaper and earlier.

   **You physically cannot call the role — that is a THIRD state, not "did not call".** `auto` means
   "the step is mandatory" and leaves no discretion. Stop and name the conflict with a greppable
   marker, modeled on the ambiguity marker from step 1 — in the report and in the issue body:

       [CONFLICT: <regulator> = auto, cannot execute — <reason>]

   A silent downgrade to `off` is a violation, not a choice; "did the review myself, by diff" in
   place of an independent run even more so. The regulator is removed by the owner, not you.

## Step 8 — doc-updater: the rest

   **This commit moves the head and voids the step-6 review verdict.** Batch EVERY head move — the
   doc-update and the merge with `main` — before the final role run, then run the role ONCE on the
   resulting head and write `review-sha`. Otherwise each move needs its own round: docs and the
   merge interleaved with runs produce six rounds where one suffices.

## Step 9 — PR → merge: the rest

   Before merge the branch head must be the one on which the last review role run passed and which
   is recorded in `review-sha`: any commit after the verdict demands a new round — except a merge
   of `main` that leaves the task's patch unchanged. The lock compares `git patch-id` of the task's
   diff against its merge base at the reviewed head and at the merged one; equal ids carry the
   verdict over. A conflict resolved by hand, or a `main` edit next to the task's lines, changes the
   id and asks for the round.
   Merge with `main` just before the merge, in the same batch as the final run — an early merge
   that changes the task's patch voids `review-sha` and forces another role run.
   **Direct push to `main` is closed BY A MECHANISM, and this is measured.** A direct push is
   rejected by the server (`pre-receive hook declined`), the `main` head does not move.
   The status check `gate / gate (pull_request)` is mandatory: the merge button is unavailable on
   red CI. Keep the wording matched to the fact: the mechanism, not branch protection, is what
   closes it.

   **Two seams, each closing its own.** The status check cannot be bypassed but knows little: only
   "is it green". The lock `retainer-merge-ready.sh` knows more — identity of the reviewed and the
   merged, checked criteria, the result report, release discipline. The first closes a merge past
   CI, the second checks content. Neither can be dropped as a "duplicate" of the other: they judge
   different things. Mandatory reviews (`required_approvals`) are intentionally absent — there is one
   person in the repository, and they would block work entirely.

   **The lock too is enforced by a mechanism, not memory.** The verdict is issued outward as the
   commit status `retainer/merge-lock` — set by `bin/retainer-merge-lock.sh` from the `merge-lock`
   workflow. It closes the merge where the context is entered into the branch protection's
   `status_check_contexts`; the earlier seam (a guard rule on the merge request) was removed together
   with the guard's procedural layer. There is no impossibility here: the status is written by the
   same token as everything else. There is a checkable state — no status, merge closed.

   **The status applies to a SPECIFIC head.** A new commit — no status on it, merge closed until a
   new lock run. The verdict depends on what does not yet exist when the PR opens: the review record,
   the report in the task, the checked criteria, the green gate. The first three are brought by a
   comment, the last by the gate run finishing, and both events recompute the lock themselves. No
   need to call it by hand; if you still must (a rebase, a task edit without a comment) —
   `POST /api/v1/repos/<owner>/<repo>/actions/workflows/merge-lock.yml/dispatches` with
   `{"ref":"main","inputs":{"pr":"<number>"}}`.

   **A check that depends on an outside service — the second model, for one — is NOT made a required
   check.** It reddens whenever that service is unavailable; making a merge condition out of it swaps
   the false-green class for a false-red one.
