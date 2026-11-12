# Sample forms: what to repeat when the project has no sample yet

The task cycle requires naming, for every new kind of code, the address of a sample — a file the new artifact
repeats. On a project with live code the address is taken FROM THE PROJECT: its code is fresher than any template. These
files are for the case when there is nothing yet to repeat — a new project, the first artifact of its kind.

**The project sample always wins.** Found a file of the same kind in the tree — name it, not
the form from here. The form from here loses to the project's for one reason: it does not know the project's decisions.

## What lies here

| File | Kind of code | What the form carries |
|---|---|---|
| `usecase.py` | use case | behavior with no I/O of its own: a frozen carrier, dependencies as protocols, a call with named arguments |
| `repository.py` | storage access | returns a project object, not a representation; row locking by a read flag, not a second method; a write that needs an open unit of work says so by its name |
| `external_call.py` | outgoing call | request and response types next to the call, transport is injected (a test replaces it at the process boundary, not by patching a module), the list of failures the adapter answers for, a ban on running inside a database transaction |
| `typed_facade.py` | facade over an untyped library | types are described once in one module, at runtime the library is re-exported; the alternative is to silence type checking at every call |
| `fixture_factory.py` | data factory | fields as a separate type, the call shape as a protocol, related objects are created lazily and configured by a nested set |
| `test_case.py` | test case | the name names a scenario, the docstring the defect class, a counter-case stands next to it; the expected query count as a constant with a justification |

Prose in the forms is Latin script: a form with a Russian docstring would contradict the `prose_lang` regulator
it itself illustrates. Explanations for the reader live in this document, not in the sample code.

**Project names are substituted before the first run.** The forms refer to the package `package` and to a
stub library on purpose: a sample written with relative imports would teach relative
imports. Copied a form — rename `package` to your own and substitute the real library. Skip
this step in a test case — the test collector fails on the import and collects NOT A SINGLE test of the project, not
just your own case.

## What these files do not do

- **Not a library.** They are not imported: they are read and repeated. The subject names (`Invoice`,
  `Delivery`) are chosen to be plainly foreign to the project's domain.
- **Do not replace standards.** A form shows HOW an artifact looks; what must be verified
  is said by the test layer (`presets/python/tests.md`) and the project policy.
- **Do not cover the whole stack.** Forms tied to a framework (data migration and its test, views,
  admin) live in its preset module — `presets/django/README.md`.

## Where the decision lives and where the form lives

The forms above show HOW an artifact looks. Below — where it lies: four rules, each with a
condition under which it applies. None is tied to a specific framework, but the first two
speak of the input boundary — that is, of an application that accepts requests; a scraper and a library
read the last two.

**Value validation lives in the calculation layer, not in the request-shape description.** The shape-description
library answers for a number of the right type having arrived; that the number is within the domain scale and the reason
code is known is the job of pure functions. Condition: the check needs to know the subject. The machine holds half of the rule —
the `pure` contract in `.importlinter.template` keeps the shape-description library out of the pure
layer. The second half, about the domain scale, is invisible to the machine and held by review: what the check knows
about the subject is visible neither from imports nor from the file address.

**A type describes one layer.** An external contract — a request body, a foreign API's response — is described
by the validation library at the boundary; an internal object and a state snapshot is carried by a plain carrier.
Condition for splitting: the type began to answer two questions — "what is stored" and "what to write". Then it is
two types, and composition links them. While the question is one, the type is one: the second is created on the condition, not
in advance.

**Reading the request shape does not live in the handler.** Condition: the parsing is needed by more than one handler
or returns a calculation-layer object. Then the parsing has its own place and one signature for all readers,
and the handler is left with the refusal and the response. A single parse needed by one handler does not create a layer.

**A layer name does not promise what is not in it.** A view builder named as part of the pure layer
makes the reader look in it for domain rules — and not find them. Where the assembly of data for
the screen lives is said by the repository form; here — only about the name: it is read as a statement about the contents.
