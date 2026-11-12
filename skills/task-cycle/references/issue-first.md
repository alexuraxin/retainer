# Task cycle — step 0, issue-first

Read before filing, grooming or taking a task. The core is `../SKILL.md`; this file holds the
rest of the rules the core names here.

## Step 0 — Issue-first: the rest

   **The "active issue" signal:** the marker is set by `bin/retainer-task-start.sh` together with
   the branch, the label and the clock — three actions that by memory went unset. The marker is
   per session and lives outside the tree, so several sessions in one tree each keep their own task.
   By hand: Write `<N>` to the path `retainer-state.sh path active-issue` prints; `retainer-task-close.sh`
   clears it. Its readers are the route, preflight and conformance; nothing blocks a code edit
   without it.
   **Readiness is a checkable state, not a label:** `ready` is set ONLY after
   `retainer-ready-check.sh` exits 0, and never at creation (a just-created task is ungroomed
   by definition). Labeling at creation is classification (priority·area·type·impact, known at once);
   readiness is a claim about state, and it is checked. What is required: the autonomous-work block
   (files, plan, criterion, boundaries) + an impact label + a comment with landmines found by READING the code
   (`file:line` addresses) + closed dependencies + no neighboring task claiming the same place in a file.
   Whether the criterion itself is checkable ("a failing test can be written from it") is invisible
   to a machine — that is on the human and the reviewer.
   **A label change is a cycle STEP, not memory:** took a task → remove `ready`, set `in-progress`
   (by the same action as the active-issue marker). **Enforced:** `retainer-preflight.sh` fails
   (manual/assisted) / warns (auto) if the active-issue marker holds `<N>` while issue `<N>` carries
   neither `in-progress` (nor `blocked`, if the task is paused). Triage labels
   (`ready/in-progress/blocked/not-decomposed`) live on the issue; outcome labels —
   `gate-passed`/`gate-failed` set by CI on the PR, `review-clean`/`review-revised` by the review
   cycle (step 6). A task's status is tied to its acceptance test (`failing`→`passing`): no "done"
   without red→green. Three agent failures the cycle catches: doing too much at once · premature
   "done" · shallow tests.
   **Intake check before acceptance (donor mattpocock/triage):** accept a new issue or a donor
   practice only after two checks on the DOMAIN concept (not on the wording): (1) **redundancy** —
   is the concept already covered by existing code/skill (rung 2 of [[complexity-budget]],
   navigation via [[graph-first]]); (2) **prior-rejection** — was the concept rejected or deferred
   earlier in the project's rejected-ideas log (wherever the project keeps it: the donor-practices
   journal and/or closed issues). A match — do not create a duplicate, reference the existing one.
   This is rung 2 of the complexity budget, shifted to intake rather than to the plan.
   **Who suffers is the filing question.** A task carries `impact-user` (whoever USES the
   product, an embedding project included: the body says what they see while it is not fixed)
   or `impact-maker` (whoever MAKES it: the body names the price now — minutes, runs,
   repeats). Neither answers — the subject is a mechanism watching a mechanism, and it is not
   filed at all. Impact says whose the pain is; `P0/P1/P2` says when.
