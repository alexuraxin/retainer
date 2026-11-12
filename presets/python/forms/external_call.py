"""Shape of an outgoing call: typed request, typed response, named failures.

Three properties carry the form. The request and the response are explicit
types, so the contract of the remote system lives in this module and nowhere
else. The transport is injected rather than called directly, so a test replaces
it at the process boundary instead of patching the module where it is defined.
The failures this adapter answers for are listed by name: an unlisted exception
reaches the caller instead of being swallowed into a generic error.

The call also refuses to run inside a database transaction. A remote call under
an open transaction holds row locks for as long as the network takes, and the
network has no deadline the database agrees with.
"""

from __future__ import annotations

import dataclasses
from typing import TYPE_CHECKING, Final, Protocol, final

if TYPE_CHECKING:
    from collections.abc import Mapping


@final
@dataclasses.dataclass(frozen=True, slots=True)
class DeliveryRequest:
    """What this adapter sends."""

    order_id: int
    address: str


@final
@dataclasses.dataclass(frozen=True, slots=True)
class DeliveryResponse:
    """What the remote system answers, as this project reads it."""

    tracking_id: str
    accepted: bool


class DeliveryUnavailableError(Exception):
    """Raised when the remote system cannot be reached or understood."""


class _Transport(Protocol):
    """Minimal transport contract: one call, one mapping back."""

    def post(
        self,
        url: str,
        payload: Mapping[str, object],
        timeout: int,
    ) -> Mapping[str, object]:
        """Send the payload and return the decoded answer."""


class _OutsideTransaction(Protocol):
    """Guard that refuses to run while a database transaction is open."""

    def __call__(self) -> None:
        """Raise if a transaction is active."""


_TIMEOUT_SECONDS: Final = 10
_HANDLED: Final = (OSError, TimeoutError, KeyError, ValueError)


@final
@dataclasses.dataclass(frozen=True, slots=True)
class RequestDelivery:
    """Ask the delivery provider to take an order."""

    _transport: _Transport
    _outside_transaction: _OutsideTransaction
    _endpoint: str

    def __call__(self, request: DeliveryRequest) -> DeliveryResponse:
        """Send one order and return the provider answer."""
        self._outside_transaction()
        payload = dataclasses.asdict(request)
        try:
            answer = self._transport.post(
                self._endpoint,
                payload,
                _TIMEOUT_SECONDS,
            )
        except _HANDLED as err:
            raise DeliveryUnavailableError(self._endpoint) from err
        return self._read(answer)

    def _read(self, answer: Mapping[str, object]) -> DeliveryResponse:
        try:
            return DeliveryResponse(
                tracking_id=str(answer['tracking_id']),
                accepted=bool(answer['accepted']),
            )
        except KeyError as err:
            raise DeliveryUnavailableError(self._endpoint) from err
