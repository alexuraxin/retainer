"""signup — the CORRECT (fixed) versions. Tests on them are green.

The three functions carry three CLASSES of bugs that really bit (see the engine's error journal) — here already
fixed. Next to it lies signup_buggy.py with the same functions but with the bugs: tests on it go RED.
That is what teaches the shape: a test is named after the bug class and goes red EXACTLY on it (fix/bug — compare by eye).
"""
import logging

log = logging.getLogger("example_service")


def validate_signup(username: str, email: str) -> bool:
    """Class 1 — fail-open validation. Rejects empty/broken input.

    The bug: returned True on ANY input (fail-open) → let garbage through into the system.
    Guard test: empty username / email without "@" → must be False.
    """
    if not username or not email or "@" not in email:
        return False
    return True


def fetch_profile(user_id: int, fetcher) -> dict:
    """Class 2 — unhandled external dependency. External call failure → graceful default.

    The bug: called fetcher without handling → an exception from the external call took down the whole request.
    `fetcher` is injected (mock contract: callable(user_id) -> dict) — so the test can supply a failing one.
    Guard test: a fetcher that raises → the function does NOT fail, returns the default.
    """
    try:
        return fetcher(user_id)
    except Exception:
        # honest emptiness: "no data" + WHY at warning level (not silently) — but WITHOUT the secret/payload.
        log.warning("fetch_profile: external failure for user %s — returning graceful default", user_id)
        return {"user_id": user_id, "profile": None}


def register(username: str, email: str, password: str) -> dict:
    """Class 3 — secret in the log. Logs the record WITHOUT the password.

    The bug: log.info with the FULL record → the password/secret leaked into the log (and logs go to the tracker/aggregator).
    Guard test: capture the log → the password must not be there.
    """
    record = {"username": username, "email": email, "password": password}
    safe = {k: v for k, v in record.items() if k != "password"}
    log.info("registered: %s", safe)
    return record
