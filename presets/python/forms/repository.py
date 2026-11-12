"""Shape of a repository: storage access, and nothing else.

The repository returns the project's own object, not a view model: shaping data
for a screen or a response belongs to the layer that renders it, otherwise every
new screen grows a new repository method. Row locking is a flag on the read, not
a second method, so the caller chooses the mode without the storage layer
guessing it. A write that needs an already-open unit of work says so in its name
instead of opening its own.

The connection is a protocol, not a concrete driver: locking syntax differs
between engines, and a form that hardcodes one driver teaches a statement that
does not parse on the others.
"""

from __future__ import annotations

import dataclasses
from typing import TYPE_CHECKING, Any, Final, Protocol, final

if TYPE_CHECKING:
    from collections.abc import Iterator, Sequence

#: A row as a driver hands it over: element types are known to the query, not to
#: the checker.
_Row = tuple[Any, ...]

_SELECT_DUE: Final = """
SELECT id, customer_id, total, is_settled
FROM invoice
WHERE customer_id = :customer_id AND is_settled = 0
"""
#: Appended for a locking read: PostgreSQL and MySQL parse it, SQLite does not.
_LOCK_SUFFIX: Final = ' FOR UPDATE'


class _Outcome(Protocol):
    """What this repository needs from one executed statement."""

    #: Rows the statement touched. A write reports its effect only here: a
    #: cursor holds no rows after an UPDATE.
    rowcount: int

    def __iter__(self) -> Iterator[_Row]:
        """Iterate over the rows a read returned."""


class _Connection(Protocol):
    """What this repository needs from a database connection."""

    def execute(
        self,
        statement: str,
        bound: dict[str, object],
    ) -> _Outcome:
        """Run one statement and return its outcome."""


@final
@dataclasses.dataclass(frozen=True, slots=True)
class Invoice:
    """An invoice as this project stores it."""

    id: int
    customer_id: int
    total: int
    is_settled: bool


class InvoiceMissingError(Exception):
    """Raised when a caller asks for an invoice that does not exist."""


@final
@dataclasses.dataclass(frozen=True, slots=True)
class InvoiceRepo:
    """Read and write invoices."""

    _connection: _Connection

    def find_due(
        self,
        *,
        customer_id: int,
        for_update: bool = False,
    ) -> Sequence[Invoice]:
        """Return unsettled invoices of one customer, locking them on demand."""
        query = _SELECT_DUE
        if for_update:
            query += _LOCK_SUFFIX
        rows = self._connection.execute(query, {'customer_id': customer_id})
        return [
            Invoice(
                id=int(row[0]),
                customer_id=int(row[1]),
                total=int(row[2]),
                is_settled=bool(row[3]),
            )
            for row in rows
        ]

    def settle_in_open_transaction(self, *, invoice_id: int) -> None:
        """Mark one invoice settled.

        Requires a transaction opened by the caller: a method that opens its
        own unit of work cannot be composed into one.
        """
        written = self._connection.execute(
            'UPDATE invoice SET is_settled = 1 WHERE id = :invoice_id',
            {'invoice_id': invoice_id},
        )
        if not written.rowcount:
            raise InvoiceMissingError(invoice_id)
