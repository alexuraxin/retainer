"""Shape of a test case: one scenario, its defect class, a counter-case.

The name states the behavior, so a red run says what broke rather than where.
The docstring names the defect class the case guards, so a later reader can
decide whether the case may be deleted. The counter-case is not optional: a case
that only proves "the mechanism fired" stays green for a mechanism that fires
always, and such a suite is worse than no suite because it is cited as proof.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Final, Protocol

import pytest

# Imported at runtime, not under TYPE_CHECKING: `pytest.raises` needs the class
# itself, and `from __future__ import annotations` defers annotations only.
# `package` is your project's package name: no relative import here.
from package.usecase import NothingToChargeError

if TYPE_CHECKING:
    from collections.abc import Callable
    from contextlib import AbstractContextManager

#: Three queries cover the customer lookup, the invoice list and the write.
_EXPECTED_QUERIES: Final = 3


class _QueryCounter(Protocol):
    """A fixture that fails the case when the query count differs."""

    def __call__(self, expected: int) -> AbstractContextManager[object]:
        """Enter a block in which exactly `expected` queries may run."""


def test_due_invoices_are_charged_as_one_payment(
    charge_due_invoices: Callable[..., str],
    invoice_factory: Callable[..., dict[str, object]],
) -> None:
    """Two unsettled invoices of one customer leave as a single charge."""
    invoice_factory(total=700)
    invoice_factory(total=300)

    reference = charge_due_invoices(customer_id=1)

    assert reference == 'charge-1000'


def test_settled_invoices_are_not_charged(
    charge_due_invoices: Callable[..., str],
    invoice_factory: Callable[..., dict[str, object]],
) -> None:
    """A settled invoice is not charged.

    Without this counter-case the test above would pass for a mechanism that
    charges every invoice it sees.
    """
    invoice_factory(total=700, is_settled=True)
    invoice_factory(total=300)

    reference = charge_due_invoices(customer_id=1)

    assert reference == 'charge-300'


def test_customer_without_due_invoices_is_refused(
    charge_due_invoices: Callable[..., str],
) -> None:
    """Charging a customer with nothing due raises instead of paying zero."""
    with pytest.raises(NothingToChargeError):
        charge_due_invoices(customer_id=1)


def test_charging_costs_a_fixed_number_of_queries(
    charge_due_invoices: Callable[..., str],
    invoice_factory: Callable[..., dict[str, object]],
    assert_num_queries: _QueryCounter,
) -> None:
    """The charge does not grow a query per invoice.

    `assert_num_queries` is the project's own fixture: on Django it wraps
    `django_assert_num_queries`, elsewhere it counts on the engine's event hook.
    """
    invoice_factory(total=700)
    invoice_factory(total=300)

    with assert_num_queries(_EXPECTED_QUERIES):
        charge_due_invoices(customer_id=1)
