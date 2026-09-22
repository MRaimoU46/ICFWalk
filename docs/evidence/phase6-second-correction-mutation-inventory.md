# Phase 6 publish-foundation second correction: the mutation inventory

Every public production write that can reach an instrument's configuration tables, with the
lifecycle that owns it, the lock it takes, the status it requires, who calls it, what it audits and
what proves it.

This inventory is **complete by construction, not by assertion**.
`InstrumentImmutabilityTest.testEveryRepositoryMutatorIsCoveredHere` reads `DefinitionRepository`'s
own metadata, selects every public method whose name begins with a write verb
(`insert|update|upsert|delete|place|park|store|mark|replace|create|set`), and fails if any of them
is neither exercised as version content nor listed as shared/global.
`testTheSharedAndGlobalInventoryNamesOnlyRealMethods` fails in the other direction, if the list
names a method that no longer exists. There is no exclusion list any more: the audited build had
one (`NOT_VERSION_CONTENT`), and `updateInstrument` -- the method that could make a published
version disappear -- was on it.

## 1. Version-owned content (`icf.*` rows carrying `version_id`)

All nineteen take the owning `icf.instrument_version` row under `UPDLOCK, ROWLOCK` **first**, via
`requireDraftVersion` (or `requireDraftOwnerOf`, which resolves the owner from the child row in the
database and refuses a mismatch with `INSTRUMENT_DEFINITION_VERSION_MISMATCH`), refuse anything that
is not a DRAFT, and carry `status = N'DRAFT'` in their own DML besides. A refused call changes no
row and moves no `row_version`.

| Repository entry point | Table(s) written | Called by |
| --- | --- | --- |
| `storeSnapshot` | `instrument_version` (snapshot, checksum) | `InstrumentImportService.importConfig` |
| `markPublished` | `instrument_version` (status, snapshot, checksum, publisher, timestamps) | `InstrumentPublishService.publish` |
| `parkVersionOrders` | `section_definition`, `response_option`, `item_definition`, `instrument_dimension` (display orders) | `InstrumentImportService.writeDefinitions` |
| `insertSection` | `section_definition` | `InstrumentImportService.writeDefinitions` |
| `updateSectionContent` | `section_definition` | `InstrumentImportService.writeDefinitions` |
| `placeSection` | `section_definition` (parent, final order) | `InstrumentImportService.writeDefinitions` |
| `deleteSections` | `section_definition` | `InstrumentImportService.writeDefinitions` |
| `upsertResponseSet` | `response_set` | `InstrumentImportService.writeDefinitions` |
| `deleteResponseSet` | `response_set` | `InstrumentImportService.writeDefinitions` |
| `upsertOption` | `response_option` | `InstrumentImportService.writeDefinitions` |
| `deleteOption` | `response_option` | `InstrumentImportService.writeDefinitions` |
| `upsertRule` | `rule_definition` | `InstrumentImportService.writeDefinitions` |
| `deleteRule` | `rule_definition` | `InstrumentImportService.writeDefinitions` |
| `upsertItem` | `item_definition` | `InstrumentImportService.writeDefinitions` |
| `deleteItem` | `item_definition` | `InstrumentImportService.writeDefinitions` |
| `upsertPlacement` | `instrument_dimension` (placement **and** this version's view of the dimension) | `InstrumentImportService.writeDefinitions` |
| `replaceVersionDimensionValues` | `instrument_dimension_value` | `InstrumentImportService.writeDefinitions` |
| `deletePlacement` | `instrument_dimension`, `instrument_dimension_value` | `InstrumentImportService.writeDefinitions` |
| `deleteDraftVersionCascade` | every version-owned table, and the version row | `InstrumentImportService.discardDraft` |

**Audit behaviour.** None of these audits individually; they are steps inside one service
transaction. The transaction audits once on success (`INSTRUMENT_VERSION_CREATED`,
`INSTRUMENT_VERSION_REIMPORTED`, `INSTRUMENT_VERSION_DISCARDED`, `INSTRUMENT_VERSION_PUBLISHED`) and
once on refusal, after the rollback (`INSTRUMENT_VERSION_WRITE_REFUSED`,
`INSTRUMENT_VERSION_PUBLISH_REFUSED`).

**Tests.** `InstrumentImmutabilityTest.testEveryMutatorIsRefusedForAPublishedVersion` and
`…ForARetiredVersion` call all nineteen against frozen fixtures and then compare status, snapshot,
checksum, publisher, the version `row_version`, the definitions checksum, every child table's high
`row_version` and every child count with what they were.
`testTheSameMutatorsStillWriteForADraft` proves the boundary is a boundary and not blanket refusal.
`testAChildOfAnotherVersionCannotBeWrittenThroughThisOne` proves the owner is resolved from the
database, not from the caller's argument.

## 2. Shared instrument metadata (`icf.instrument`)

| Entry point | Lifecycle owner | Lock | Guard | Called by | Audit |
| --- | --- | --- | --- | --- | --- |
| `createInstrument` | The instrument's birth | none needed | Insert-only. The unique `code` makes a second call for an existing instrument fail rather than reach its row, so it can never rewrite shared metadata. At this moment the instrument has no versions, so there is nothing frozen to protect. | `InstrumentImportService.importConfig`, only when `findInstrumentByCode` returns nothing | The enclosing import's success event |
| `updateInstrumentMetadata` | Instrument-level operation | `icf.instrument` under `UPDLOCK, ROWLOCK` | Requires a named `authorizedByUserId` that is a real `icf.app_user`; refuses blank, malformed and unknown with `INSTRUMENT_METADATA_ACTOR_REQUIRED` before any write | `InstrumentMetadataService.updateMetadata` **only**. No import path. No route: nothing in `src/http` or `src/controllers` references it. | Exactly one `INSTRUMENT_METADATA_UPDATED` on `INSTRUMENT`/`instrumentId`, naming the actor, the changed fields, and the previous and new name and active flag |

`updateInstrument` -- the audited build's unguarded, import-called setter -- **no longer exists**.
It was not merely removed from the inventory: the call graph is proved clean by
`testTheSharedAndGlobalInventoryNamesOnlyRealMethods` (the name resolves to nothing) and by
`SharedInstrumentBoundaryTest.testTheAuthorizedOperationHasNoRoute` (no router or controller
references the replacement).

**Why this is not version content.** `icf.instrument.active` is part of
`SnapshotService.currentVersion()`'s selection predicate, so writing it decides whether an already
PUBLISHED version is in service. `name` and `description` are compiled into each version's snapshot
and served from there, so they are version facts with an operational copy on the shared row that the
walk runtime never reads.

**Tests.** `SharedInstrumentBoundaryTest`: a V2 import declaring `instrument.active = false` cannot
remove published V1 from the runtime; a V2 rename applies to V2's snapshot only and not to the
shared row; V1's snapshot bytes, checksum, `row_version` and whole render model are unchanged by a
V2 import; a conflicting document is refused atomically with one durable `SHARED_METADATA_CONFLICT`
audit and no partial write; the authorized operation works and audits itself; it refuses an unknown
or blank actor and writes nothing; and it has no route.
`InstrumentImmutabilityTest.testEverySharedOrGlobalMutatorEnforcesItsOwnContract` calls
`createInstrument` for an existing code (must fail) and `updateInstrumentMetadata` with a blank and
an unknown actor (must refuse), then asserts the shared and global rows are byte-identical
afterwards.

## 3. Global reporting identity (`icf.dimension_definition`, `icf.dimension_value`)

| Entry point | Lifecycle owner | Lock | Guard | Called by | Audit |
| --- | --- | --- | --- | --- | --- |
| `createDimensionIdentity` | The requesting DRAFT version | `icf.instrument_version` under `UPDLOCK, ROWLOCK` | `requireDraftVersion(versionId)` **inside the repository**, before the INSERT | `InstrumentImportService.writeDefinitions`, only when the code has never been seen | The enclosing import's success event |
| `createDimensionValueIdentity` | The requesting DRAFT version | the same | the same | `InstrumentImportService.writeDefinitions`, only when the (dimension, value code) pair has never been seen | The enclosing import's success event |

Both rows are **insert-only and never updated**: they carry `dimension_id`, `code`, `value_id` and
`value_code`, which `icf.walk_dimension_value.selected_value_id` points at forever. Everything a
version authors about a dimension lives on its own `instrument_dimension` /
`instrument_dimension_value` rows.

Both signatures now **take the requesting version id**, so the guard is structural rather than
something an earlier caller is trusted to have done. In the audited build neither took a version at
all, and neither checked anything.

**Tests.** `InstrumentImmutabilityTest.testEverySharedOrGlobalMutatorEnforcesItsOwnContract` (both
refused for a PUBLISHED and a RETIRED version),
`testARefusedGlobalIdentityCreationWritesNothing` (the refused identity row was never inserted, and
no shared or global row moved), `testGlobalIdentityCreationStillWorksForADraft` (a DRAFT may mint
identity, and the row really is written).

## 4. Version creation (`icf.instrument_version`)

| Entry point | Lifecycle owner | Guard | Called by | Audit |
| --- | --- | --- | --- | --- |
| `createDraftVersion` | The import that creates it | Creates a DRAFT, so there is no frozen version to protect. `FK_instrument_version_instrument` refuses a version under an instrument that does not exist. | `InstrumentImportService.importConfig` | `INSTRUMENT_VERSION_CREATED` |

**Tests.** `InstrumentImmutabilityTest.testEverySharedOrGlobalMutatorEnforcesItsOwnContract` asserts
it cannot attach a version to a non-existent instrument.

## 5. Public methods that match the write-name pattern but write nothing

| Method | Why |
| --- | --- |
| `parkOffset` | Returns the parking constant. Executes no statement. |

Declared in `InstrumentImmutabilityTest.NOT_A_WRITE`, and the inventory test fails if the name stops
resolving to a real method.

## 6. Writes outside the instrument lifecycle

`WalkRepository` writes walk data (`icf.walk`, `walk_response`, `walk_dimension_value`,
`walk_revision`, `walk_mutation`) and `AuditRepository` appends to `icf.audit_event`. Neither can
reach an instrument's configuration tables: they are a different aggregate with their own
concurrency contract (Phase 4), and they are out of scope for the DRAFT-only write boundary. The
schema-contract test (`tests/node/cfml-suite.test.mjs`, "CFML SQL references only known icf tables")
keeps the set of tables any CFML statement names under review.

## 7. What the migration writes, and when

`database/006_version_scoped_dimensions.sql` is the only other thing that writes
`icf.instrument_dimension_value`. Its legacy membership backfill is a **one-time** schema
transition, recorded in `icf.schema_migration_state`; after that transition the migration writes no
membership on any apply, for any version, in any status. See `database/README.md`, "The legacy
membership backfill is one-time".
