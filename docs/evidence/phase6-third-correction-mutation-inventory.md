# Shared and global mutation inventory: Phase 6 third correction

Every method in `src/instrument/DefinitionRepository.cfc` that writes a row **not** owned by a
single instrument version, with the contract it actually enforces after this correction. This
supersedes `phase6-second-correction-mutation-inventory.md`, which described two of these methods
as guarded by a preceding `requireDraftVersion` call and one as authorized by a known-user check --
neither of which was true in the sense the word implies.

The inventory is kept honest by tests, not by this document:
`InstrumentImmutabilityTest.testEveryRepositoryMutatorIsCoveredHere` reads the repository's own
metadata and fails if a mutating method exists that the spec does not exercise, and
`testTheSharedAndGlobalInventoryNamesOnlyRealMethods` fails if the spec's shared/global list names
a method that no longer exists. The two locked reads below are not in that list because they write
nothing; they are recorded here because they are what makes the mutator beside them correct.

## The shared row (`icf.instrument`)

| Method | Writes | What actually enforces it |
| --- | --- | --- |
| `createInstrument` | INSERT | Insert-only, at the instrument's birth, when it owns no versions and there is nothing frozen to protect. `UQ_instrument_code` makes a second call for the same code fail rather than reach the existing row, so this method cannot be used to change one. |
| `lockInstrumentByCode` / `lockInstrumentById` | nothing (read) | `UPDLOCK, HOLDLOCK, ROWLOCK`, taken and read in one statement, held for the caller's transaction. Not a mutator, listed because it is the thing that makes the mutator below correct. |
| `updateInstrumentMetadata` | UPDATE | Performs the UPDATE only. **The caller must already hold the row** from one of the locked reads above and must derive every value it writes from *that* read, inside the same transaction; a partial patch restates the fields it omits, so values taken from an unlocked read are a lost update however carefully the write is locked afterwards. The `userExists` call is an **integrity** check for `icf.audit_event.actor_user_id`'s foreign key -- every row in `icf.app_user` satisfies it -- and is **not** authorization. |

**Authorization for the shared row is not in the repository.** It is
`InstrumentMetadataService.updateMetadata`, which takes the current principal and calls
`AuthorizationService.requirePermission(principal, "instrument.manage")` before any mutation. There
is no actor argument on that operation: the audit actor is the principal's `userId`. Neither the
repository's `userExists` nor the absence of an HTTP route is, or may be described as, the
authorization control.

**Import does not write this row after the instrument's birth.** It re-reads it under
`lockInstrumentById` *after* taking its version lock and refuses a document that disagrees
(`SHARED_METADATA_CONFLICT`), on that locked row rather than on the unlocked read it used to resolve
the instrument id.

## The global reporting identity rows

| Method | Writes | What actually enforces it |
| --- | --- | --- |
| `createDimensionIdentity` | INSERT into `icf.dimension_definition` | **One statement.** `INSERT ... SELECT` whose source is the owning `icf.instrument_version` row under `UPDLOCK, ROWLOCK`, predicated on `status = N'DRAFT'`, with `OUTPUT INSERTED` returning the row the database reports inserting. The authority decision cannot be separated from the write, so a caller that owns no transaction has no window to lose. No eligible row means no insert, no returned id, and a typed non-DRAFT (or not-found) refusal. |
| `createDimensionValueIdentity` | INSERT into `icf.dimension_value` | The same statement shape; the next display order is a correlated subquery, so the statement's source stays the one version row and exactly zero or one value is ever minted. |

These previously called `requireDraftVersion` and then issued an unconditional INSERT. That is sound
*inside a transaction that already holds the version lock* and unsound outside one, which is how
these public methods are also called: the `UPDLOCK` was released at the end of the status SELECT, a
publish could freeze the version in the gap, and the INSERT ran anyway. **A lock released before the
write it protects is not a write boundary**, and this document previously implied it was.

## Version rows that are not version *content*

| Method | Writes | What actually enforces it |
| --- | --- | --- |
| `createDraftVersion` | INSERT into `icf.instrument_version` | Creates a DRAFT under an existing instrument; there is no frozen version to protect. `FK_instrument_version_instrument` means it cannot attach a version to an instrument that does not exist. |
| `markPublished` | UPDATE of `icf.instrument_version` | `requireDraftVersion` under the version's own lock, inside the publish transaction, and the UPDATE re-asserts `status = N'DRAFT'` in its own predicate, so two publishers racing cannot both succeed. |

## One lock order

`icf.instrument_version` first, `icf.instrument` second, children last.

* Publication takes the version row and never holds the instrument row.
* Import takes the version row, then the instrument row.
* The shared-metadata operation takes **only** the instrument row and requests no version lock.
* Both identity creators take the version row inside their own single statement.

No path takes `icf.instrument` before `icf.instrument_version`, so no pair of these can deadlock.
That is asserted, not assumed: `SharedMetadataConcurrencyBarrierTest.testImportQueuesForTheSharedRowAndThenDecidesOnIt`
holds the shared row while an import that already holds its version lock queues for it, and
`PublishConcurrencyBarrierTest.testImportVersusPublishQueuesRatherThanDeadlocking` does the mirror
case on the version row.
