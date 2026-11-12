"""signup_buggy — BUGGY versions of the same functions. The test_signup.py tests go RED on them.

It exists only for machine proof of the shape: the test_example_service.sh wrapper runs
THE SAME tests against the fix (green) and against this file (red). If a test does not go red on the bug —
it guards nothing (tautology). Compare with signup.py line by line — here are the three classes.
"""
import logging

log = logging.getLogger("example_service")


def validate_signup(username: str, email: str) -> bool:
    # BUG (class 1, fail-open): accepts ANY input — empty/broken passes.
    return True


def fetch_profile(user_id: int, fetcher) -> dict:
    # BUG (class 2, unhandled external dependency): no try — a fetcher failure takes down the request.
    return fetcher(user_id)


def register(username: str, email: str, password: str) -> dict:
    record = {"username": username, "email": email, "password": password}
    # BUG (class 3, secret in the log): logs the FULL record — the password leaks.
    log.info("registered: %s", record)
    return record
