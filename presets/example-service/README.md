# example-service — a reference for the shape of a red-then-green test

A tiny teaching service. Not about features — about **the shape of a good test**: what a test looks like that
turns red on a real class of bug, and not "just in case".

## Idea

A good regression test grounds a lesson in a FACT: it was red on the bug and went green on the fix. A test that is
green both ways guards nothing. Here this is shown mechanically — three classes of bugs, each with:

- **the correct version** (`example_service/signup.py`) — the test is green;
- **the buggy version** (`example_service/signup_buggy.py`) — the same test is **red**;
- **the test itself** (`tests/test_signup.py`) — named after the bug class, the assert hits the invariant the bug violates.

The wrapper runs EACH test separately against both versions and requires: green on the fix AND **red on the bug**.
If a test is green on the bug, it is tautological or the bug does not manifest; fix the test (the check is per-class, not "the whole
run went red" — otherwise one tautology would hide behind red from its neighbors).

## Three classes (real ones that bite in production)

| class | bug | guard test |
|---|---|---|
| **fail-open validation** | the validator lets empty/broken input through (returns "ok") | empty/broken input → rejected |
| **unhandled external dependency** | an external call without failure handling → the whole request fails | failing fetcher → graceful default |
| **secret in the log** | the full record with the password is logged → egress | capture the log → no password |

## How to read

1. Open `signup.py` and `signup_buggy.py` side by side — here is the bug, here is the fix.
2. Open `tests/test_signup.py` — here is the shape: name = class, assert = invariant.
3. Run the wrapper (`tests/test_example_service.sh` in the engine) — you will see green-on-fix, red-on-bug.

Caught a bug of your own? Write the same kind of test: reproduce it red, then fix. Not "more tests" — one
per class, grounded in a real failure.
