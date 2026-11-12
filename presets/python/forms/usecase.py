"""Shape of a use case: business behavior with no IO of its own.

The use case owns the decision and delegates every effect to an injected
dependency. Two properties carry the form: the class is frozen, so a resolved
instance cannot be reconfigured at runtime, and every dependency is a protocol,
so a test substitutes it without touching the module where it is defined.
"""

from __future__ import annotations

import dataclasses
from typing import TYPE_CHECKING, Protocol, final

if TYPE_CHECKING:
    from collections.abc import Sequence
    from contextlib import AbstractContextManager


class _Invoice(Protocol):
    """Minimal invoice contract this use case depends on."""

    @property
    def total(self) -> int:
        """Amount to charge, in minor units."""

    @property
    def is_settled(self) -> bool:
        """Whether the invoice is already paid."""


class _InvoiceQueries(Protocol):
    """Read side of invoice storage."""

    def find_due(self, *, customer_id: int) -> Sequence[_Invoice]:
        """Return unsettled invoices of one customer."""


class _PaymentGateway(Protocol):
    """Outgoing payment call."""

    def charge(self, *, customer_id: int, amount: int) -> str:
        """Charge the customer and return the payment reference."""


class _Transaction(Protocol):
    """Atomic unit around storage writes."""

    def __call__(self) -> AbstractContextManager[None]:
        """Open the unit of work."""


class NothingToChargeError(Exception):
    """Raised when a customer has no unsettled invoices."""


@final
@dataclasses.dataclass(frozen=True, slots=True)
class ChargeDueInvoices:
    """Charge every unsettled invoice of a customer as one payment."""

    _queries: _InvoiceQueries
    _gateway: _PaymentGateway
    _transaction: _Transaction

    def __call__(self, *, customer_id: int) -> str:
        """Charge the customer once and return the payment reference."""
        invoices = self._queries.find_due(customer_id=customer_id)
        due = [invoice for invoice in invoices if not invoice.is_settled]
        if not due:
            raise NothingToChargeError(customer_id)
        amount = sum(invoice.total for invoice in due)
        with self._transaction():
            return self._gateway.charge(customer_id=customer_id, amount=amount)
