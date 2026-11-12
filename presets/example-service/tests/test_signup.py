"""Red-then-green form tests: one per bug class. Each goes RED on its own bug.

The implementation is chosen via env EXAMPLE_IMPL (signup = fix, signup_buggy = bug) — so the same
test logic is run by the wrapper against both versions: green on the fix, red on the bug.
The shape (learn from it): test name = bug class; the assert hits exactly the invariant the bug violates.
"""
import importlib
import os
import unittest

impl = importlib.import_module(os.environ.get("EXAMPLE_IMPL", "example_service.signup"))


class TestSignupForms(unittest.TestCase):
    def test_validate_rejects_invalid_input(self):
        """Class 1 (fail-open validation): empty/broken input is REJECTED. Goes red if the validator is fail-open."""
        self.assertFalse(impl.validate_signup("", "bob@example.com"), "empty username must be rejected")
        self.assertFalse(impl.validate_signup("bob", "not-an-email"), "email without @ must be rejected")
        self.assertTrue(impl.validate_signup("bob", "bob@example.com"), "valid input must be accepted")

    def test_fetch_survives_external_failure(self):
        """Class 2 (unhandled external dependency): fetcher failure → default, NOT an exception. Goes red if unhandled."""
        def failing_fetcher(_user_id):
            raise RuntimeError("external service unavailable")

        result = impl.fetch_profile(7, failing_fetcher)
        self.assertEqual(result["user_id"], 7, "on external failure — a graceful default with user_id")
        self.assertIsNone(result["profile"], "default on failure: profile=None (no data)")

    def test_register_does_not_log_password(self):
        """Class 3 (secret in the log): the password does NOT reach the log. Goes red on the leak."""
        with self.assertLogs("example_service", level="INFO") as captured:
            impl.register("bob", "bob@example.com", "hunter2")
        logged = " ".join(captured.output)
        self.assertNotIn("hunter2", logged, "the password must not leak into the log")


if __name__ == "__main__":
    unittest.main()
