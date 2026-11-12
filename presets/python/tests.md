# The project test layer — layout, fixtures, case shape

Part of the Python preset. The rules from here apply from the first test of a new project: a layout introduced
later costs rewriting all the paths, and the habit of "one module — one test" cannot be rewritten at all.

The source of practices is `wemake-django-template` and a production Django project built on it. What of this is executed
by a machine rather than read by eye: `pyproject.toml` (coverage bar, timeout, strict markers),
`conftest.py` (timeout extension by marker), `.importlinter` (tests are not imported by production).

## A test starts from a business case, not from a layer

A case describes what a user does, not which layers it is assembled from. There is no need to cover a layer
just because it exists: a suite sliced by layers covers details and not a single path by which they
are called in production.

Three consequences follow, in this order — otherwise the gap is closed with the wrong thing:

1. **Coverage is short — first DATA, then new cases.** The same business case is run on
   another branch of a condition, another boundary, another set. A new case is created when a new
   user scenario appeared, not when coverage fell a percent short.
2. **All cases are covered, yet coverage is still short — that is excess code.** What remains is branches that
   nobody will call in production: safety nets, handling of impossible states, a reserve "for the future". Such
   code is deleted, not wrapped in tests. The coverage bar works here as a dead-code
   detector, and that is its most useful role.
3. **Foreign code is not tested.** A case on a uniqueness constraint tests the DBMS; a case that
   renders a template and makes sure the insertion worked tests the template engine. Until we run
   into a specific failure, both are considered working. If we ran into one — the test pins EXACTLY that
   failure, rather than testing the framework in general.

## The boundaries of a case are declared, not implied

Each case fails only from a change inside its boundary. Where a subject has levels
(composition — adapter — behavior), the boundaries are named by a list "what it checks / what it does NOT check":
composition checks what was sent and with which arguments; the adapter — that the right use case was called and the
arguments arrived; behavior — domain rules, without the orchestrator's rigging. A case that fails from an edit
in a neighboring level costs more than it catches: it is fixed along with every foreign change.

**An end-to-end run does not cover the levels it passed through.** A request through a handle goes red as a whole and
does not name the level where the rule is broken; with narrow per-layer changes it also lies in a different
change — and the level goes out without a case of its own. That is why composition, adapter and behavior
have cases at their boundary: the subject is the same business case, but the question is asked at its own level. This does not
contradict the rule "a case starts from a business case, not from a layer": the layer sets not the subject of the case but the
level of the question. Nor is it a duplicate of one mechanism — a duplicate checks one mechanism through
three entries, a level case checks a rule that does not exist at the other levels. And it does not cancel the end-to-end case:
a seam is checked by a real seam.

## What a case does not do

- **Does not check markup.** Classes, layout, template structure are not the subject: the response status,
  the context and a marker in the markup (an attribute introduced for the test) are the subject. A template formatter
  wraps lines at its own width and breaks markup inside a tag, so a case on a literal substring
  goes red out of nowhere. A layout regression is caught by looking at the screen in a live run.
- **Does not breed duplicates of one mechanism.** Three cases "an unknown record gives a refusal" across three handles
  check one mechanism; one or two meaningful ones are enough.
- **Does not assert shape instead of behavior.** "Non-empty" and "key is present" pass on wrong
  values too: a concrete result is checked. Where there are many values, the full set is compared
  as a whole (including the record that must not be touched), not selected fields — comparing values
  catches what the fixture happened to fill in, comparing sets catches everything.

Shape versus behavior — line by line:

```python
def test_band_filters_are_not_empty() -> None:
    """A band maps to a non-empty set of filters.

    The weak form: any non-empty result passes, so a band mapped to the
    wrong boundaries keeps this case green.
    """
    assert filters_for(band)
    assert 'match' in payload


def test_band_filters_narrow_by_exact_boundaries() -> None:
    """A band maps to the boundaries the queryset is narrowed by.

    The strong form: a wrong boundary fails the case, and so does a key
    the payload must not carry.
    """
    assert filters_for(band) == {'score__gte': 70, 'score__lt': 80}
    assert payload == {'match': 'partial', 'reason': 'score'}
```

The first case stays green on a band with wrong boundaries; the second goes red on it.

## The layout mirrors the code structure

`tests/` repeats the package tree: from a test's path you can see the layer and the application, not only the module name.

```
<pkg>/logic/scoring.py        →  tests/test_logic/test_scoring.py
<pkg>/infra/repository.py     →  tests/test_infra/test_repository.py
```

Two reasons. A test is found by the address of the code — without a mirror it is searched for by grepping the function name, and "there is
no test" is indistinguishable from "the test is named differently". And an empty spot in the mirror is a visible hole: a layer directory
without tests is visible in the tree, the coverage share does not show it.

A flat package gives flat tests (`tests/test_core.py`) — the mirror is trivial; directories are created
together with layers, not in advance.

**The mirror runs into file base names.** While test directories have no `__init__.py`, pytest
in the default import mode takes a file by its base name, and two `test_feedback.py` in different
layers break the suite COLLECTION: the run fails on import before reaching a single case. The mirror
promotes this — the module name repeats on every layer. There are two ways out, and one is chosen per project:
either base names are unique across the whole tree (`test_feedback_repository.py`), or test directories
become packages — this is how it is done in the kit (`${CLAUDE_PLUGIN_ROOT}/presets/example-service/tests/`),
and the `D104` relaxation in the preset config is precisely about their `__init__.py`.

The path shape is read by a machine: the "declared done" gate looks for the test of a changed module by the keys
`test_layout` (flat) or `test_mirror` (mirror) in `.retainer/config.toml`. A layout the
config does not know about is invisible to the gate.

## One module — several tests, each name names a scenario

A test name is a sentence about behavior, not the name of the module being covered:

```python
def test_expired_token_is_rejected() -> None:
    """An expired token is refused instead of silently renewed."""


def test_token_of_another_user_is_rejected() -> None:
    """A token issued to someone else does not open this account."""


def test_valid_token_returns_owner() -> None:
    """A valid token resolves to the account it was issued for."""
```

`test_auth` for a whole module does not say what exactly broke, and in a red run reads as
"somewhere in authorization". The docstring states BEHAVIOR ("an anonymous request gets 403"), and does not
retell the code ("calls the view with AnonymousUser"): a retelling goes stale silently, because nobody
checks it against the code.

Each case names the defect class it guards — in one line of the docstring. A test without it
can be neither deleted nor changed after half a year: it is unclear what it held. The requirement is mechanical, not
on one's conscience: the `D1` relaxation for tests is dropped in the preset, and a case without a docstring turns the linter red.

## A counter-case is mandatory

Next to "it worked" stands "and this must not work":

```python
def test_rule_blocks_protected_path() -> None:
    """A protected path is refused."""
    assert guard.check('config.toml').blocked


def test_rule_allows_ordinary_path() -> None:
    """An ordinary path is allowed.

    Without this counter-case the test above would pass for a guard that
    refuses everything.
    """
    assert not guard.check('README.md').blocked
```

A test for a single firing proves that the mechanism fires — not that it looks at the input.
A mechanism that always returns "yes" passes it green.

## A scenario versus a module, and a test that guards nothing

Slicing "a test per function" gives coverage and not a single test for the path by which these functions are
called in production. Hence a suite that is green over a broken system: every detail is checked
separately, and the JOINT between them is never checked.

A test guards something only if all four conditions hold:

1. **It names a scenario.** "A request from an unconfirmed user is not created" is a scenario;
   "checks `create_request`" is a module name put on a test.
2. **The joint is checked with a real joint.** If both ends of a seam are replaced, the test proves that the mocks
   agreed with each other. At least one test per seam goes through real components —
   a real call, a real write, real serialization.
3. **A mutant turns it red.** Break the mechanism the test guards (remove the check, return a constant,
   drop the condition) — the test must go red. If it does not, it guards something other than what is claimed, and its
   green means nothing.
4. **A counter-case is in place** (see above).

The mutant check is not a ritual: it is done once, when writing the test, and costs a minute. A test
that did not pass it is cheaper to delete than to keep: a suite with a false green is more dangerous than an absent one,
because it is cited as proof.

## Fixtures live as a separate layer

`tests/plugins/` — fixtures and factories, wired in the root `conftest.py` via `pytest_plugins`:

```python
pytest_plugins = [
    'tests.plugins.identity.user',
    'tests.plugins.employment.organization',
]
```

`conftest.py` is a protected file: the run policy is silenced in it with one line, so its edit
goes through an unlock by the owner's key. Fixtures do not suffer from this — they live in
`tests/plugins/`, and only the wiring line goes into conftest.

The reason for the list: a `conftest.py` at every level of the tree hides the source of a fixture (which of four versions of
`user` arrived in this test is visible only from file placement), while `pytest_plugins` gives one
explicit list.

A factory is typed with `Protocol` (call shape) + `TypedDict` (fields), not `dict[str, Any]`:

```python
class UserData(TypedDict, total=False):
    """Fields a test may override on a user."""

    email: str
    full_name: str


class UserDataFactory(Protocol):
    """Build user data for a test."""

    def __call__(self, **fields: Unpack[UserData]) -> UserData:
        """Return the fields, filling the ones the caller omitted."""


@pytest.fixture
def user_data_factory() -> UserDataFactory:
    """Build user data, letting a test override single fields."""
    def factory(**fields: Unpack[UserData]) -> UserData:
        return {'email': mimesis_field('person.email'), **fields}

    return factory
```

A factory, not a ready object: a test that needs one field different overrides it in the call, and does not
assemble the object by hand. A hardcoded value in a test is a hidden dependency on it: the test
passes while the value is that very one, and is silent about the code looking at its specifics. A fixed
value stays only where a concrete boundary is checked.

**Related objects are created LAZILY and configured in a nested way.** A factory creates a related record
only if the caller did not pass one, and accepts the related record's fields as a separate nested
set. Without laziness every case pays with extra database writes, and without a nested set a test
that needs one field on a related record builds it by hand — and the factory stops being the
only place that knows what a correct object looks like.

**There are no private builders in a test file.** Helpers like "build an object", "build an address", "build a request
body" inside a file read badly and drift apart between files: their place is the fixtures and
factories of the shared layer. The same applies to a repeated check: if three cases verify the same
state, the check becomes an assertion fixture, not copy-paste.

## A fake is an explicit class, not `Mock`

```python
@final
class _AlwaysFailingGateway:
    """A gateway that always answers with a refusal."""

    def send(self, message: str) -> Result:
        return Result(ok=False, error='unavailable')
```

`Mock` accepts any call and any signature: the test stays green after the method
was renamed or its arguments changed. An explicit class breaks at the same place where production will break,
and is read as a description of the external system. Keep it next to the test that uses it.

**This rule is about an EXTERNAL dependency.** A double of your own code has a different task, and a different form:

| What is replaced | Form | Why |
|---|---|---|
| an external system (gateway, foreign API, payment) | an explicit class with the REAL signature | breaks where production breaks; reads as a description of a foreign system |
| your own use case at the adapter boundary (the orchestrator calls the use case) | an observer with free arguments that records calls | a signature change of the use case edits the EXPECTATION in the case, not the double itself; otherwise one refactoring rewrites all the doubles |

An observer double keeps a shared prefix in its name and a docstring — on both the class and the call method: without
this, half a year later it is not visible what it observes and why it exists.

## Replacing a dependency — through DI, not `monkeypatch`

```python
with implemented_override(Gateway, _AlwaysFailingGateway):
    result = use_case.execute(order_id)
```

`monkeypatch.setattr` ties the test to WHERE the dependency is declared: moving an import to another
module makes the replacement silently useless — the test is green, and the replaced object is no longer in this path.
The container hands out the same dependency as production, and the replacement holds on to the contract, not to the
address.

**The replacement mechanics live in a fixture, not in the case body.** The fixture is typed with a protocol and
returns a context manager; inside it is free to use any replacement tool, including
one forbidden in the case itself. From outside the case sees one line "at this boundary this answers", and the expectation
reads without rigging details. The boundaries for which such fixtures are created
first: the task queue, outgoing HTTP, the orchestrator, the clock, file storage.

Direct use of a replacement tool inside a case is not forbidden, but it is an exception, not the norm, and
each one is visible by eye in review.

## Idempotency is checked by a call in a loop

```python
for _ in range(3):
    sync_catalog(source)
assert Item.objects.count() == 1
```

One call proves that the operation fires. "A repeated call breaks nothing" is a separate
property, and it is caught only by repetition.

## The number of queries and of "new objects" — an ordinary tool

A test asserts not only the result but the price: how many queries went to the database and whether
objects appeared where they should not. The Django part is in `presets/django/README.md`.

The expected number is held in a named constant with a comment that explains EVERY query
("authentication, rate limit, list selection"). A threshold without such a comment gets adjusted to
the fact on the first red run, and the guard's batching reserve runs out unnoticed.

## A data migration is checked both ways

A migration that changes DATA carries reverse code and a test. Which migrations exactly require this and which
do not (an autogenerated field or index addition does not) is listed in
`presets/django/README.md`: one list in one place, otherwise two sources drift apart silently. The test applies the previous migration, prepares
records with factories, applies the migration under test — and compares the FULL state, including the record that must not be
touched. Then it applies the previous one again and checks that the rollback returned everything as it was.

In the migration itself next to the query stands a comment with the volume of production data ("in production about four
thousand such records, the update is safe") and a decoding of numeric codes if they take part:
after half a year neither can be recovered from the code, and the decision "is this safe in production"
is made precisely by them.

Sample forms — `${CLAUDE_PLUGIN_ROOT}/presets/python/forms/`: the case — `test_case.py` (scenario name,
docstring with the defect class, a counter-case alongside, a query-count constant with a justification), the data
factory — `fixture_factory.py` (fields as a separate type, call shape as a protocol, lazy relations), a double of an
external system — `external_call.py` (transport injection at the process boundary). A PROJECT sample
overrides them: its code is fresher and knows its decisions.

Related: the `test-generation` skill (test types beyond the happy path), `presets/python/gate.sh.template`
(the `tests` step — run, coverage, N+1 detector), `presets/python/forms/README.md` (where the decision lives
and where the form lives — in which layer the decision about validation and types is made).
