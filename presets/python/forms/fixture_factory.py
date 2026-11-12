"""Shape of a data factory: fields typed, call typed, related objects lazy.

A test that needs one field different overrides it in the call instead of
assembling the object by hand, so the factory stays the single place that knows
what a correct object looks like. Related objects are created only when the
caller passes none, and their fields are accepted as a nested set: without
that, a test that needs one field of a related object assembles it by hand and
the factory stops being the single place.

Two ways of saying what the related object is cannot both apply, so passing an
object and its fields together is refused instead of one of them being dropped:
a factory that silently ignores an argument makes a test pass for the wrong
reason.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Protocol, TypedDict, Unpack, final

import pytest

if TYPE_CHECKING:
    from collections.abc import Callable


@final
class CustomerFields(TypedDict, total=False):
    """Fields a test may override on a customer."""

    email: str
    is_active: bool


@final
class InvoiceFields(TypedDict, total=False):
    """Fields a test may override on an invoice."""

    total: int
    is_settled: bool
    customer: dict[str, object]
    customer_fields: CustomerFields


#: Message of the refusal below. A named constant keeps the string out of the
#: raise, where this preset's linter forbids an inline one.
_BOTH_CUSTOMER_KEYS = 'pass either customer or customer_fields, not both'


class InvoiceFactory(Protocol):
    """Build a stored invoice for a test."""

    def __call__(self, **fields: Unpack[InvoiceFields]) -> dict[str, object]:
        """Return the created invoice."""


@pytest.fixture
def invoice_factory(
    customer_factory: Callable[..., dict[str, object]],
) -> InvoiceFactory:
    """Create a correct invoice, creating a customer only when none is given."""

    def factory(**fields: Unpack[InvoiceFields]) -> dict[str, object]:
        customer = fields.pop('customer', None)
        customer_fields = fields.pop('customer_fields', {})
        if customer is not None and customer_fields:
            raise TypeError(_BOTH_CUSTOMER_KEYS)
        if customer is None:
            customer = customer_factory(**customer_fields)
        return {
            'customer': customer,
            'total': fields.get('total', 1000),
            'is_settled': fields.get('is_settled', False),
        }

    return factory
