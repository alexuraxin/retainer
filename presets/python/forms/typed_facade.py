"""Shape of a facade over an untyped library.

A library without annotations is typed once, in one module, instead of being
silenced at every call site. Under type checking the names below are protocols
that describe what this project uses; at runtime the real library is
re-exported unchanged, so importing this module gives working objects. A call
that drifts from the described shape fails type checking here, not in whichever
module happened to import the library last.

The re-export is explicit (`as` with the same name) because that is what marks
a name as public for type checkers.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:

    class RetryPolicy:
        """Typed interface for the untyped retry policy."""

        def __init__(self, *, attempts: int, backoff: float) -> None:
            """Configure how often and how slowly a call is retried."""

        def run(self, call: Any, /, *args: Any, **kwargs: Any) -> Any:
            """Invoke the call under this policy."""
            raise NotImplementedError

    class Breaker:
        """Typed interface for the untyped circuit breaker."""

        @property
        def is_open(self) -> bool:
            """Whether calls are currently refused."""
            raise NotImplementedError

else:
    from flaky_lib import (
        Breaker as Breaker,  # noqa: PLC0414 - re-export is the point
    )
    from flaky_lib import (
        RetryPolicy as RetryPolicy,  # noqa: PLC0414 - same, re-export
    )
