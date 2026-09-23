# ICFWalk data contract

## Runtime principle

Each walk is pinned to one immutable published instrument version. The compiled snapshot stored on that version is the runtime rendering and validation contract. The normalized configuration tables support administration, validation, lookup, and reporting; they must agree with the snapshot at publication.

The aligned JSON uses readable logical IDs. SQL Server uses GUID primary keys. The import/publish service owns the mapping.

## JSON-to-SQL mapping

| JSON area | SQL destination | Mapping notes |
| --- | --- | --- |
| `instrument` | `icf.instrument` | Upsert by unique `code`; do not replace the GUID for an existing instrument |
| `instrument.version` | `icf.instrument_version` | Upsert only an existing DRAFT with the same instrument and label; never overwrite PUBLISHED/RETIRED |
| `sections[]` | `icf.section_definition` | Map logical parent keys after all section GUIDs are allocated; merge color, optional/required flags, and JSON settings into `settings_json` |
| `responseSets[]` | `icf.response_set` | Preserve `setKey` as `response_set_key`; merge authoring flags into `settings_json` |
| `responseOptions[]` | `icf.response_option` | Preserve exact stored code, label, order, numeric score, N/A flag, and definition; run `002_alignment_patch.sql` first |
| `rules[]` | `icf.rule_definition` | Store canonical `conditionsJson`; supported current effects are SHOW only |
| `dimensions[]` | `icf.dimension_definition` | Upsert global definitions by unique `code`; store value mode and allow-other behavior in `settings_json` |
| `dimensionValues[]` | `icf.dimension_value` | Upsert within a dimension by `valueCode`; runtime school group/grade-band metadata remains in the compiled snapshot |
| `instrumentDimensions[]` | `icf.instrument_dimension` | Store visible-by-default, placeholder, and option-filter settings in `settings_json` |
| `items[]` | `icf.item_definition` | Map item logical keys to GUIDs; merge content family, placeholder, link, reportability, and item settings into `settings_json` |
| Complete JSON | `icf.instrument_version.compiled_snapshot_json` | Canonical runtime snapshot with deterministic property and array ordering |
| Snapshot SHA-256 | `icf.instrument_version.checksum_sha256` | Lowercase 64-character SHA-256 over canonical UTF-8 JSON bytes |

## Logical-ID import rules

1. Begin one SQL transaction.
2. Resolve the instrument by `code`; reuse its GUID or create it.
3. Resolve the version by `(instrument_id, version_label)`.
4. If that version is PUBLISHED or RETIRED, refuse the import.
5. For a new DRAFT, allocate GUIDs for all logical definitions. For an existing DRAFT, reuse rows by their unique version key.
6. Insert/update sections in two passes so every parent GUID is known.
7. Insert/update response sets and options.
8. Resolve dimension and dimension-value **identities** by code. `icf.dimension_definition` and
   `icf.dimension_value` hold reporting identity only -- `dimension_id`, `code`, `value_id`,
   `value_code`. A row is created the first time a code is seen and is never updated again.
9. Insert/update rules, items, and version-specific dimension placements after their referenced
   GUIDs are known. A placement row (`icf.instrument_dimension`) also carries what *this version*
   says the dimension is -- label, data type, reportability, sensitivity, settings, activity -- and
   `icf.instrument_dimension_value` carries the values this version offers, in its order, with its
   labels, effective windows and activity flags.
10. Validate every reference, allowed type, order, unique key, response option, and JSON document.
11. Compile canonical snapshot JSON from the imported contract.
12. Compare the compiled semantic content with the input. Abort on mismatch.
13. Commit only after all validations pass.

The importer must be idempotent for an unchanged DRAFT and must not create duplicate child rows on retry.

## One semantic rule set

There is exactly one authoritative set of semantic rules about an instrument, and it is expressed
over **normalized definitions** -- the representation the importer produces, the compiler
serializes into the stored snapshot, and `DefinitionRepository.loadNormalizedDefinitions` reads back
out of SQL Server. `src/instrument/DefinitionValidator.cfc` holds it: references, allowed types,
unique logical keys, section hierarchy (including cycles), response-set requirements, option
ordering, rule syntax and supported semantics, dimension and value rules, placements, the
retired-content guardrail, and the runtime renderability rules below. It also validates the
snapshot **envelope** (see "The snapshot envelope").

It is also the one place the shared vocabulary lives. Item types, choice types, selection modes,
rule target types, effects and supported effects, source types, operators, data types, condition
logics, the maximum display order, the retired-content strings, the placeholder review status and
the supported option filters are defined once, on `DefinitionValidator`, and read from it by
`InstrumentConfigValidator`, `SnapshotCompiler` and `RenderModelBuilder`. Two copies of a shared
constant is how the validator and the renderer drifted apart in the first place.

### Publishable implies renderable

Every state the semantic rules accept must be one `RenderModelBuilder` will build, completely.
These rules exist because the renderer has them, and each corresponds to a way it throws or
silently drops content:

| Rule | Code | What the renderer does otherwise |
| --- | --- | --- |
| Exactly one active section has no parent | `SECTION_ROOT_MISSING`, `SECTION_ROOT_AMBIGUOUS` | Throws `SNAPSHOT_NO_ROOT`, or keeps one root and silently drops the other's whole subtree |
| Every active section, item and placement is reachable from that root | `SECTION_ORPHANED_FROM_ROOT`, `ITEM_ORPHANED_FROM_ROOT`, `PLACEMENT_ORPHANED_FROM_ROOT` | Builds without them; the instrument is quietly smaller than it says |
| An active placement names a section | `PLACEMENT_SECTION_REQUIRED` | Has nowhere to put the control |
| Every accepted item type has a layout and a storage shape | `INVALID_ENUM` | Throws `SNAPSHOT_UNSUPPORTED_ITEM_TYPE` |
| An active item's response set is active | `RESPONSE_SET_INACTIVE` | Throws `SNAPSHOT_UNKNOWN_RESPONSE_SET`: it indexes active sets only |
| An active choice item's set has at least one active option | `RESPONSE_SET_NO_ACTIVE_OPTIONS` | Renders a question with nothing to choose |
| An active placement's dimension is active | `DIMENSION_INACTIVE` | Throws `SNAPSHOT_UNKNOWN_DIMENSION` |
| An active LIST placement offers at least one active value | `DIMENSION_NO_ACTIVE_VALUES` | Renders an empty, unanswerable control |
| `settings.optionFilter` is one the renderer implements, and its source dimension is active | `UNSUPPORTED_OPTION_FILTER`, `OPTION_FILTER_SOURCE_MISSING` | Throws `UNSUPPORTED_OPTION_FILTER`, or filters nothing |
| An active rule's target and sources are active | `RULE_TARGET_INACTIVE`, `RULE_SOURCE_INACTIVE` | Keeps a rule pointing at content it has already filtered out |

**`MULTI_CHOICE` and `SHORT_TEXT` are not accepted item types.** Both were on the old allow-list and
implemented nowhere: neither has a renderer layout, and `icf.walk_response` stores one selected
option per item, so `MULTI_CHOICE` could not be persisted even if it were drawn. They are refused at
import and at publication. Supporting either means implementing it end to end first, and
`DefinitionValidator.itemTypes()` is the single place that records the decision.

Because a hand-maintained rule set can still drift from the thing it describes, both import and
publication additionally run the **real renderer** over the compiled snapshot
(`RenderContractValidator`). A throw becomes a structured `{ code, message, path }` issue instead of
a runtime 500, and the built model is counted against the definitions, so a build that succeeds
while dropping a subtree is refused as `RENDER_MODEL_INCOMPLETE`.

Rules that only mean something for an inbound authoring document stay in
`InstrumentConfigValidator`: that the document declares DRAFT, that its authoring ids are unique and
resolve to each other, that `conditionsJson` parses as text.

**Declaring DRAFT is required, and it is a declaration of exactly `DRAFT`.** `instrument.version.status`
must be present, must be a JSON string, and must equal `DRAFT` case-sensitively -- the enumeration
in `CK_instrument_version_status` is the three upper-case literals, and CFML's own `!=` is
case-insensitive, so `draft` used to pass as a DRAFT declaration. Absence used to pass too: the
check only ran when the member existed, so silence was read as consent on the one field that says
which of three lifecycle states the author believes they are writing. The three failures are
reported distinctly at `$.instrument.version.status`: `VERSION_STATUS_REQUIRED` (absent or null),
`VERSION_STATUS_INVALID` (present but not a string), `VERSION_STATUS_NOT_DRAFT` (a string that is
not exactly `DRAFT`). A *persisted* version's status is a lifecycle fact and is never checked here:
it is read under the version's row lock. None of them can be applied to a
version already in SQL Server, which has keys instead of authoring ids and a parsed conditions
document instead of a string.

Import runs both layers. Publish runs the shared layer, twice: once on the definitions carried in
the stored snapshot, and once on the definitions SQL Server holds. So "a DRAFT that imported" and "a
version that publishes" are the same predicate, and neither side can drift into accepting what the
other refuses.

## Publishing

Publishing a DRAFT is one transaction. Self-consistency is not validity: a DRAFT carrying the same
invalid content in its rows and in its snapshot satisfies every comparison between them, so
publishing validates each of them in its own right as well as against the other.

1. Refuse a malformed version id, a missing or malformed publisher, before any database work.
2. Take the version row under `UPDLOCK, ROWLOCK` -- the same lock, in the same order, that every
   definition write takes -- and read its status under that lock.
3. Refuse anything that is not a DRAFT.
4. Refuse a publisher who is not a real `icf.app_user`.
5. Refuse a version with no compiled snapshot, a snapshot that does not parse, or a stored checksum
   that is not the SHA-256 of the stored snapshot.
5b. Refuse a snapshot that parses to anything other than a **JSON object** (`SNAPSHOT_SHAPE` at
   `$`). `null`, an array, a string, a number and a boolean are all valid JSON and none of them is
   an instrument snapshot. A top-level `null` in particular leaves the parsed variable null on
   Lucee, and reading it back is an engine error rather than a value -- which used to happen inside
   the canonical serializer, *before* any refusal had been marked, so the caller received a 500 and
   the attempt left no durable record. This is established before anything dereferences or
   serializes the document, exactly as `Router.cfc` guards the request-body path.
6. Refuse a snapshot whose bytes are not the canonical serialization of the document they parse to
   (`SNAPSHOT_NOT_CANONICAL`). Publication never rewrites them: rewriting would move the checksum
   the DRAFT was reviewed under.
7. Validate the stored snapshot envelope, including the full `counts` block and that the instrument
   code and version label it claims are the identity of the row it is stored on.
8. Validate the definitions carried in the snapshot against the shared rule set.
9. Validate the definitions SQL Server holds against the same rule set, independently.
10. Build the render model from the exact snapshot about to be frozen, and refuse if the runtime
    cannot build it or builds it with content missing.
11. Confirm the snapshot's definitions and SQL Server's still compile to the same definitions
    checksum (the drift check).
12. Record unresolved placeholders as warnings, not invented replacements. Publishing policy may
    decide whether warnings block publication.
13. Write status, the **unchanged** snapshot bytes, the unchanged checksum, the publisher,
    `published_at` and `effective_start` in one statement. Publishing never recompiles: the stored
    bytes and checksum are exactly what the import produced.
14. Read the row back and confirm the stored publisher is the actor this call was made for.
15. Write one audit event naming that publisher.
16. Commit.

Every refusal happens inside the transaction and therefore changes nothing: status, timestamps,
publisher, snapshot, checksum, definitions, audit success events and every row version are exactly
as they were. Exactly one refusal audit event is written **after** the rollback, because a record
written inside the transaction would be rolled back with it and the refusal would leave no trace.
Refusal details carry lifecycle facts only -- version, label, prior status, operation, reason code,
actor, checksums, counts -- never definitions, snapshot text, narrative content, secrets or tokens.

The same holds for `InstrumentImportService`, and for **every** refusing branch in it. Import and
`discardDraft` each write one `INSTRUMENT_VERSION_WRITE_REFUSED` event after their rollback, with
`operation` = `IMPORT` or `DISCARD_DRAFT` and a stable `reason`:

| Reason | Raised when |
| --- | --- |
| `VERSION_NOT_DRAFT` | The version is PUBLISHED or RETIRED |
| `VERSION_IN_USE` | The version is a DRAFT that walks already reference |
| `SHARED_METADATA_CONFLICT` | The document disagrees with the shared `icf.instrument` row about `active` |

`VERSION_IN_USE` is the one that was missing: both branches threw without marking the refusal, so
the catch had nothing to persist and the attempt left no trace at all. Being DRAFTs, they had no
status guard standing behind them either, so the refusal record was the only evidence there would
ever have been.

After commit, the version and every child definition are immutable. A change requires a new DRAFT
version.

## The snapshot envelope and the canonical-byte contract

`icf.instrument_version.compiled_snapshot_json` is a **canonical** document
(`icfwalk-canonical-json/1`: struct keys sorted by UTF-16 code unit, no whitespace, arrays in
order, shortest round-trip numbers) and `checksum_sha256` is the SHA-256 of exactly those bytes. A
snapshot that merely encodes the right content some other way carries a checksum that does not mean
what it claims -- two databases holding the same instrument would disagree about its identity.
Publication therefore parses the stored bytes, re-serializes them through the one canonicalizer and
requires byte-for-byte equality (`SNAPSHOT_NOT_CANONICAL`). It **refuses** rather than rewriting,
because rewriting would silently move the checksum the DRAFT was reviewed under.

The envelope the compiler writes and every reader trusts:

| Member | Requirement |
| --- | --- |
| `snapshotFormat` | `icfwalk-instrument-snapshot/1` |
| `definitions` | An object, validated by the shared rule set |
| `instrument` | An object with a non-blank `code`, equal to the code of the row it is stored on |
| `version` | An object with a non-blank `versionLabel`, equal to the label of the row it is stored on |
| `counts` | An object carrying **all nine** members below, and no others |

`counts` is what readers trust instead of walking the arrays, so it is part of the contract and not
a convenience. All nine members are required -- `sections`, `items`, `responseSets`,
`responseOptions`, `rules`, `dimensions`, `dimensionValues`, `instrumentDimensions`, `placeholders`
-- and each must be a **JSON number** that is whole, not negative, and no greater than 2147483647,
and that equals the value the definitions imply. `placeholders` is derived rather than counted from
a collection: it is the number of items whose `reviewStatus` is the placeholder status.

**The number rule is a type rule, not a coercion rule.** CFML's `isNumeric` answers a coercion
question: it says yes to the string `"144"`, and a loose comparison then says that string equals
`144`. So a counts block of `{"items": "144", ...}` used to satisfy the envelope and be frozen,
although the contract above defines the member as a number and every reader parses it as one.
`core/JsonTypes` decides the type from the value's Java class instead, so a numeric-looking string,
a boolean, an array and an object are all type errors. A missing block, an empty block, a missing
member, a value of the wrong type, a fractional, negative, non-finite or out-of-range number, a
value that disagrees with the definitions, or a member the envelope does not define are each
refused with a stable code and path (`SNAPSHOT_COUNTS_MISSING`, `SNAPSHOT_COUNTS_INVALID`,
`SNAPSHOT_COUNTS_MISMATCH`, `SNAPSHOT_COUNTS_UNEXPECTED`).

## Shared instrument metadata

`icf.instrument` is shared by every version of the instrument, so writing it is not an edit to a
draft. Ownership is explicit:

| Column | Scope | Who writes it |
| --- | --- | --- |
| `code` | Identity | `createInstrument`, once, at the instrument's birth. Never updated. |
| `name`, `description` | **Version** | Compiled into each version's snapshot and served from it. The shared row's copies are operational labels that the walk runtime never reads. |
| `active` | Shared operational state | Part of `SnapshotService.currentVersion()`'s predicate, so it decides whether an already PUBLISHED version is in service. |

An import therefore writes the shared row exactly once, when the instrument does not yet exist.
Afterwards it writes nothing there. A document whose `instrument.active` disagrees with the stored
row is refused atomically (`SHARED_METADATA_CONFLICT`) -- not applied, and not silently dropped --
and the refusal is audited like any other refused write. `name` and `description` are not refused,
because they are already stored at the right scope: they go into *this* version's snapshot, so V2
may describe the instrument differently from V1 and each walk sees its own version's wording.

**That conflict is decided on the locked current row.** Import's first read of `icf.instrument`
resolves the instrument id and is unlocked, so an authorized metadata change can commit after it.
Deciding the conflict from that earlier object made such a change invisible: the document said
"active", the stale object agreed, and the import was accepted against a row that by then said
otherwise. Import now re-reads the row under `UPDLOCK, HOLDLOCK` **after** taking the version lock,
and the decision -- and the rest of the transaction -- sees that row.

Changing the shared row deliberately is `InstrumentMetadataService.updateMetadata`:

* **Authorization** is the central model. The operation takes the current principal and asks
  `AuthorizationService` for global `instrument.manage` before any mutation. There is no actor
  argument: the audit actor is the principal's `userId` and cannot be named or substituted from the
  call site. `DefinitionRepository.userExists` is an **integrity** check for
  `icf.audit_event.actor_user_id`'s foreign key, satisfied by every row in `icf.app_user`, and is
  not authorization. Neither is the absence of an HTTP route, which is a scope decision.
* **The row is locked before it is read.** A patch restates the stored value of every field it
  omits, so the locked read, the merge, the update and the audit are one transaction
  (`lockInstrumentByCode`, `UPDLOCK, HOLDLOCK`). Two contending partial patches therefore both
  survive, in either arrival order, and each audit event's `before` image is the row that request
  actually replaced.
* **The patch is validated strictly** before anything is written: only `name`, `description` and
  `active`; an unknown member is refused (`INSTRUMENT_METADATA_UNKNOWN_FIELD`) rather than ignored;
  `name` a non-blank JSON string within `nvarchar(200)`; `description` a JSON string within
  `nvarchar(1000)`, where blank means NULL; `active` an **actual** JSON boolean, never a coerced
  string or number (`isBoolean("144")`, `isBoolean(0)` and `isBoolean("no")` are all true in CFML,
  and a coerced `false` takes a published version out of service); and at least one supported
  member (`INSTRUMENT_METADATA_NO_CHANGES`).
* **A patch with no material difference is a no-op** (`docs/OPEN_DECISIONS.md`): no write, no audit
  event, no `row_version` movement, and `noOp: true` in the result. Materiality is exact: `name` and
  `description` are compared case-sensitively and `active` as a boolean, so a capitalization-only
  edit is a real change, written and audited.
* Exactly one `INSTRUMENT_METADATA_UPDATED` audit event names the actor and what changed. Narrative
  content never enters it: the description is reported as `descriptionChanged`, never as its text.

This correction closes the write boundary and adds **no** administration UI for that operation.

## Global reporting identity

`icf.dimension_definition` and `icf.dimension_value` are global rows that every version's reporting
points at. They are created once, when a code is first seen, and never updated. Creating one is
still a version-scoped authority, and that authority is **inside the minting statement**:
`createDimensionIdentity` and `createDimensionValueIdentity` each issue one `INSERT ... SELECT`
whose source is the owning `icf.instrument_version` row, read under `UPDLOCK, ROWLOCK` and
predicated on `status = N'DRAFT'`, with `OUTPUT INSERTED` returning the row the database reports
inserting.

They used to call `requireDraftVersion` and then issue an unconditional INSERT. Inside the import's
transaction that is sound, because the transaction holds the version lock from the check through
the write. But these are **public** repository methods and are called directly, outside any
transaction, and there the `UPDLOCK` lives only for the length of the SELECT: a publish could take
the row and freeze the version in the gap, and the INSERT then ran anyway, minting permanent global
identity on the authority of a version that was no longer a DRAFT. A lock released before the write
it protects is not a write boundary. One statement is atomic, so there is no gap left for any
caller to lose, whether or not it owns a transaction. When the predicate matches nothing, nothing
is inserted and nothing is returned, and the caller receives a typed non-DRAFT refusal rather than
a GUID for a row that does not exist.

## The DRAFT-only write boundary

"Published definitions are immutable" is structural, not procedural. Every method in
`DefinitionRepository` that writes version content does two things, and neither is optional
(the mutators that write shared or global rows have their own contracts, above, and are in the same
inventory):

1. **Resolve and lock the owning version first.** `requireDraftVersion` takes the
   `icf.instrument_version` row under `UPDLOCK, ROWLOCK` inside the caller's transaction and refuses
   anything that is not a DRAFT. It is called by the repository method itself, so a caller cannot
   forget it -- there is no path to the DML that does not pass through it. A method handed only a
   child id (an option id, a section id) resolves the owner **from the child row in the database**
   rather than trusting the version it was told, and refuses a mismatch with
   `INSTRUMENT_DEFINITION_VERSION_MISMATCH`.
2. **Status-qualify the DML.** Every `UPDATE`, `DELETE` and `INSERT` carries the owning version's
   `status = N'DRAFT'` in its own predicate. If the lock above were ever bypassed or defeated, the
   statement still matches no rows.

A refused write therefore changes no data and moves no `row_version`. A write that silently matched
no rows is caught by the importer's round-trip checksum proof, which fails the whole transaction
rather than committing a partial one.

**One lock order, everywhere.** `icf.instrument_version` under `UPDLOCK, ROWLOCK` first, then the
instrument row, then children. Publication, import, every version-content mutator and both global
identity creators take it in that order, so a publish racing an edit queues on one row instead of
interleaving, and no pair of them can deadlock by taking two rows in opposite orders. The one write
that does not start from a version -- `createInstrument` -- happens before the instrument has any
versions. The shared-metadata operation takes **only** `icf.instrument`, and requests no version
lock at all, so it cannot invert the order either; import takes the version row first and then
re-reads `icf.instrument` under its own lock, in that order, to decide the shared-metadata
conflict on the current row rather than on the unlocked read it used to resolve the instrument id.

That ordering is proved, not assumed, by a two-sided barrier. Transaction A emits `A_LOCKED` from
inside its transaction once it holds the lock; transaction B emits `B_AT_COMPETING_BOUNDARY`
immediately before the database call that contends for it; A is released only after B is heard,
and the spec asserts both signals in that order and then the one permitted serial outcome and the
final state. That B had not finished while A held the lock is asserted only as supplemental
evidence, never as the proof of arrival. `PublishConcurrencyBarrierTest` covers publish against
publish, publish against import, import against publish, and publish against a new dimension
identity and a new dimension-value identity; `SharedMetadataConcurrencyBarrierTest` covers metadata
against metadata and import's shared-state check against an authorized metadata update. The seam is
a test-only repository decorator; no production configuration exposes a lock hook.

There is **no unchecked deletion path**. `deleteDraftVersionCascade` refuses a non-DRAFT version like
every other mutator. Test fixtures that must remove a frozen fixture version use the test-only
harness `tests/cfml/support/FixtureCleanup.cfc`, which no application code references and no HTTP
route reaches, or the `ICFWALK_TESTS_ENABLED`-gated maintenance cleanup.

## Publisher attribution

A version that is not a DRAFT names the user who published it. There is no default, no empty string,
and no path that publishes with nobody named:

- `InstrumentPublishService.publish` requires a publisher argument and refuses a blank one
  (`PUBLISHER_REQUIRED`), a malformed one (`PUBLISHER_INVALID`), and one that is not a real
  `icf.app_user` (`PUBLISHER_UNKNOWN`).
- `DefinitionRepository.markPublished` requires it too, so no future caller can reintroduce an
  unattributed publication by going around the service.
- The HTTP route derives the publisher from the authenticated principal only. Its request body
  selects nothing and a non-empty body is refused (`PUBLISH_BODY_NOT_ALLOWED`).
- `CK_instrument_version_publisher_required` (migration `006`) refuses any non-DRAFT row with a NULL
  `published_by_user_id`, so the invariant survives a hand-written statement.
- The success audit's actor is read back from the stored row, so the audit trail and the row can
  never disagree about who published.

Migration `006` never invents a publisher for an existing row: a non-DRAFT version with a NULL
publisher fails the migration loudly, with the count, because attributing an existing publication is
an authorized remediation decision and not a migration's to make.

### The publish request-body contract, exactly

The route takes **no request body**, and that is now what it enforces. It asks whether any body
bytes arrived -- from `Content-Length`, falling back to the parsed content for a chunked request --
rather than whether the parsed struct is empty, because no body and a literal `{}` both parse to an
empty struct. So:

| Request body | Result |
| --- | --- |
| none | Accepted; the publisher is the authenticated principal |
| `{}` or `{ }` | 400 `PUBLISH_BODY_NOT_ALLOWED` |
| whitespace only | 400 `PUBLISH_BODY_NOT_ALLOWED` |
| `null` | 400 `INVALID_JSON_BODY` (a JSON `null` is not an object) |
| `[]` | 400 `INVALID_JSON_BODY` |
| any object, including one naming an actor, publisher, checksum or snapshot | 400 `PUBLISH_BODY_NOT_ALLOWED` |

`Content-Length: 0` is not a body. Every one of these refusals happens before the service is
reached, so none of them publishes anything or moves a row version.

## Version-scoped dimensions and values

`icf.dimension_definition` and `icf.dimension_value` are **reporting identity and nothing else**.
`dimension_id`, `code`, `value_id` and `value_code` are created once, when a code is first seen, and
never updated again. `icf.walk_dimension_value.selected_value_id` points at those rows, so a walk
conducted under V1 and a walk conducted under V2 group together by one stable code.

Everything a version *authors* is version-scoped:

| What | Where |
| --- | --- |
| Dimension label, data type, reportability, sensitivity, settings, activity | `icf.instrument_dimension.dimension_*` |
| Which values a version offers, and their label, order, effective window, activity | `icf.instrument_dimension_value` |

`loadNormalizedDefinitions`, the render model, and the walk path's definition index all read the
version-scoped rows. The invariant this buys:

> After V1 is published, importing or editing V2 can never change `loadNormalizedDefinitions(V1)`,
> V1's checksum materialization, V1's comparison metadata, or the meaning of data already reported
> under V1.

Before migration `006` the shared rows were read directly, so importing V2 with a renamed dimension,
a relabelled or reordered value, a deactivated value or a dropped one silently rewrote what V1's
definitions said -- after V1 was published, frozen and reported on. V1's stored snapshot did not
move, so the corruption was invisible until something compared the snapshot with the tables and
found drift in a version nobody had touched.

**Membership is authored, never inferred.** After the one-time schema transition, rows in
`icf.instrument_dimension_value` are written only by
`DefinitionRepository.replaceVersionDimensionValues`, under the owning version's row lock and only
while that version is a DRAFT. Migration `006`'s legacy backfill is tied to that transition, which
is recorded durably in `icf.schema_migration_state`, and is never re-evaluated against what is
currently missing. Re-evaluating it was a data-corruption bug in its own right: once V2 minted a
new global value, a re-applied `006` inferred that published V1 must have meant to offer it and
inserted it -- changing V1's definitions and the walk values it accepted while its snapshot bytes,
checksum and `row_version` stayed put, which `WalkRepository.definitionIndex()`'s checksum-keyed
cache could not see. `database/README.md` has the transition states, the read-only detection
queries for environments the earlier form already touched, and the reviewed remediation procedure
(which requires an authorized decision wherever intended historical membership cannot be inferred
from the version's own frozen snapshot).

A consequence worth stating: a dimension value that is in the database but not in the imported
document is simply not part of that version. It keeps its identity row, and every earlier version
that offers it keeps offering it. The importer no longer warns
`DIMENSION_VALUE_NOT_IN_DOCUMENT`, because there is nothing left to warn about -- the value was not
"left in place" in a shared row that other versions read; it is version-scoped, and this version
does not have it.

## Walk aggregate

A walk comprises:

- one `icf.walk` row;
- zero or one `icf.walk_dimension_value` row for each configured dimension;
- zero or one `icf.walk_response` row for each single-value/text item;
- zero or more `icf.walk_response_selection` rows for a multi-select item;
- append-only revision and audit records.

Every child row carries or resolves to the walk's pinned `version_id`. The server rejects an item, option, dimension, or value from another version/definition.

## Suggested autosave payload

```json
{
  "walkId": "GUID",
  "versionId": "GUID",
  "rowVersion": "0x0000000000000000",
  "clientMutationId": "GUID",
  "changedAt": "ISO-8601 timestamp",
  "dimensions": {
    "grade": { "selectedValueCode": "7" },
    "tag": { "textValue": "optional text" }
  },
  "responses": {
    "comp_s1_q1": { "storedCode": "4" },
    "comp_s1_notes": { "textValue": "..." }
  }
}
```

`rowVersion` and `clientMutationId` are required on a save, and both `dimensions` and `responses`
root objects must be present. The School dimension is not a client field: the server derives it from
the walk's org unit (see "School and organizational scope"), so a payload need not carry it and may
not contradict it. Response `state` is derived data: the server owns it, and a payload
that asserts one is rejected (`CLIENT_STATE_NOT_ACCEPTED`) rather than silently ignored. Values are
checked against their JSON primitive type, never coerced.

The server response returns the committed `rowVersion`, normalized values, save timestamp, and mutation ID. A retry with the same mutation ID must not duplicate data. A stale row version returns a conflict, never a last-write-wins overwrite.

## Response states

| State | Meaning | Reporting behavior |
| --- | --- | --- |
| `UNANSWERED` | Visible/applicable item has no answer | Exclude from numerator and denominator |
| `ANSWERED` | Valid value stored for the visible/applicable item | Include only when the item is reportable |
| `HIDDEN` | A visibility rule currently hides the item/section | Exclude; values may be retained for conditional classroom sections so they reappear if the condition returns |
| `NOT_APPLICABLE` | User explicitly marked a skippable component No | Exclude; current prototype clears its rating values |

Never convert UNANSWERED, HIDDEN, or NOT_APPLICABLE to numeric zero.

## Visibility and clearing rules

- Metadata-driven conditional classroom sections retain their prior responses while hidden, matching the prototype's in-memory behavior. Persist the state as HIDDEN and exclude it from reports and export while hidden.
- Period becomes hidden outside grades 6–12. Retain or clear its prior value according to one consistent documented policy; default to retaining it as HIDDEN so a temporary grade correction does not destroy data.
- Workshop Model and Academic Teaming are different: selecting No explicitly clears their rating responses, marks them NOT_APPLICABLE, hides the rating controls, retains notes, and updates averages immediately.
- When switching either skippable component back to Yes, its cleared ratings return as UNANSWERED.

## Values by type

- Controlled single choice: `selected_option_id` for item responses or `selected_value_id` for dimensions.
- Free text and long text: `text_value`.
- Numeric values: `number_value`.
- Dates: `date_value`.
- Booleans: `boolean_value`.
- Multi-select: one parent `walk_response` plus `walk_response_selection` rows.
- Email draft workflow: canonical JSON in a non-reportable `text_value`, validated against an application-owned schema.

Do not populate multiple typed value columns for one response.

## Email-draft JSON

```json
{
  "includedPartKeys": ["part1", "comp_s1", "summary"],
  "drafted": true,
  "to": "",
  "subject": "Editable subject",
  "body": "Editable body"
}
```

This object is private walk content, not an aggregate-report source. Nothing in this state authorizes sending email.

## Revision and audit behavior

- `walk_revision` stores prior snapshots for material edits according to application policy. It is append only.
- `audit_event` records lifecycle/security facts such as create, complete, void, publish, retire, role change, denied cross-scope access, and conflict resolution.
- Do not place full narrative notes, email bodies, secrets, tokens, or unnecessary personal data in audit details.

## Aggregate calculations

- A response distribution counts only current reportable ANSWERED rows within the authorized filter population.
- A numeric average is `SUM(numeric_score) / COUNT(answered numeric score)` over the same filtered population.
- Never average pre-averaged component values across walks when their answered-item counts differ. Aggregate from item-level scored responses or use the correct weighted denominator.
- Hidden, unanswered, and not-applicable values remain visible as separate data-quality/state counts when useful, but never enter numeric averages.
- Narrative items, email workflow state, teacher fields, and classroom labels are excluded.

### How Phase 7 reports implement this

**The population.** A report covers the walks of **one** instrument version (default: the current
one), because every walk is pinned to one immutable version and two versions may word or score an
item differently. Within it: walks whose org unit is one the caller's `report.view` assignments cover
now (effective dates, active units and `include_descendants` resolved), narrowed to one named unit
and its covered descendants when the request names one; COMPLETED walks, plus DRAFT walks only when
the request asks (`includeDrafts=true`); never a VOIDED walk; and, when given, an observation window
on `icf.walk.observed_at` (the visit date, or the creation instant when there is none), inclusive of
both calendar dates.

**What is reportable.** An item is reported when it is an active `SINGLE_CHOICE` item flagged
reportable in the pinned version; notes, text, display items and the email draft never are,
whatever their flags say. A dimension is reported when it is an active placement of a reportable,
non-sensitive `LIST` dimension other than School. Free-text dimensions (Observer, Lesson Standard,
tags) and the Date dimension are never reported, and neither is a list dimension's "Other" text:
"Other" is counted by its code. School is reported as the org unit, which is the scope authority
(see "School and organizational scope").

**States.** Response states are the persisted engine evaluation (see "Response states"); a
distribution counts `ANSWERED` rows only, an item's numeric average is the sum of the option scores of
its answered responses whose option carries a score and is not N/A divided by their count, and a
section's average pools every such response beneath it. Dimension states are not persisted, so a
report asks the engine: a dimension value counts only when the instrument shows that dimension for
the walk's own values of the dimensions its rules read. A Period retained while hidden is `HIDDEN`,
is never counted as its value and never matches a Period filter. A dimension whose visibility would
depend on a response or on free text is left out of reports rather than counted wrongly.

**Report coherence.** A report reads many walks in several statements. It captures every
population walk's `row_version` from the walk row before any child row is read, and verifies them
after every aggregate has been read. A walk that moved in between may have been read in two
committed states, so the report is discarded and recomputed, at most three times, after which the
request is refused with 409 `REPORT_POPULATION_CHANGED`. Every counted walk therefore contributes
exactly one committed state, and no statistic mixes two states of one walk. Every mutation path
updates the walk row in the same transaction as its child writes, which is what makes the row
version a sufficient signal; the report holds no lock a writer waits on.

**Two kinds of report.** The population above is a *live* report's. Live figures are served only
to a caller who holds `walk.read` on every unit the report would count: that person can open each
of those walks, so an aggregate tells them nothing they could not read directly. Every other
caller -- every report-only role -- reads *released* figures instead (next section), and a live
request from them is refused with 400 `REPORT_RELEASE_REQUIRED`, however it is narrowed.

### Aggregate privacy rule (RPT-03)

The owner-approved rule (`docs/OPEN_DECISIONS.md`, "Aggregate privacy rule (RPT-03)"): minimum
**k = 3** completed walks, report-only users read **frozen releases**. What follows is the rule as
implemented, and what it does not protect against.

**Why live figures cannot be protected.** Two live reports whose filters differ by one walk --
`to=D` against `to=D-1`, a Grade filter against none, a parent unit against its children, with and
without drafts, one answer filter against another -- differ by exactly that walk, and so does one
report run before and after a walk is completed or edited. Subtraction returns the walk's
categorical answers, and no suppression of the individual reports prevents it. So a report-only
user never receives live figures.

**Releases** (migration `007_report_release.sql`, `POST /api/reports/releases`). A release freezes
the COMPLETED walks observed on a range of dates (`observedFrom`..`observedTo`, inclusive, on
`icf.walk.observed_at` as live reports use it) that has passed (the last date before today, UTC).

* **Who releases.** Only a caller holding `walk.read` and `report.view` on every active org unit --
  someone who can already open every walk a release will count. Anyone else: 403
  `REPORT_RELEASE_NOT_PERMITTED`, audited `ACCESS_DENIED`.
* **No overlap.** No two releases cover the same date. The service checks under an exclusive
  application lock (409 `REPORT_RELEASE_OVERLAP`) and `TR_report_release_no_overlap` refuses an
  overlapping row whatever writes it. Dates alone do not keep releases apart, though: a completed
  walk stays correctable, and its visit date decides `observed_at`. The next bullet does.
* **One release per walk, ever** (audit finding P7C-02). When a release is created it records every
  walk its stored blocks count in `icf.report_release_walk`, keyed by the walk alone, so the
  database refuses a second membership (`PK_report_release_walk`) whatever writes it. A new release
  leaves out every walk an earlier release counted. So no two releases share a walk, and none can
  be combined with another to learn about one. What a date correction does:
  * a walk an earlier release counted keeps its correction (walks stay correctable after release),
    the release that counted it keeps the figures it froze, and no later release ever counts it,
    whatever dates its visit date now falls in;
  * a walk not yet released whose visit date is corrected into dates already released is never
    released: those dates are closed, and no later release covers them.
  Both outcomes disclose less, never more (fail closed). Walks in a block below k are not recorded
  (the block is not stored, so nothing about them was published) and remain releasable. The
  database also refuses a block whose count differs from the walks recorded for it (50065), and any
  later change to a stored block's recorded walks (50065).
* **Never changes.** A release is computed once, in one transaction, from one coherent read of
  every walk (the same captured-then-verified row versions as a live report, up to three attempts,
  then 409 `REPORT_POPULATION_CHANGED`). Completing, editing or voiding a walk afterwards changes no
  released figure, so rerunning a report reveals nothing. What the database itself enforces: no
  release, block, cell or membership row is ever updated (50064); nothing -- block, cell or
  membership row -- is added to a release after the transaction that created it
  (`created_transaction_id`, 50066); a stored block's recorded walks never grow or shrink (50065).
  What it does not refuse is deleting a whole release, rows in dependency order (cells, blocks,
  membership, release). Nothing in the application does; only the test-only fixture cleanup removes
  a test's own. An operator must not: a deleted release frees its dates and its walks for a second
  release that could then be combined with what was already read.
* **Blocks.** A release is stored per block: one instrument version at one org unit (the walk's
  own unit). A block with fewer than k walks is not stored at all (`CK_report_release_block_walks`,
  `TR_report_release_block_floor`), so it contributes to nothing -- not to its school, not to its
  district. For every stored block, every reportable breakdown is stored as the count of each
  non-zero category, keyed by instrument codes. No narrative is stored. The walks a block counts
  are recorded in the membership (above) so the database can refuse a second release of them; no
  report reads the membership, and nothing a report returns carries a walk id.
* **Versions.** A release covers every reportable version (the current version and the PUBLISHED
  and RETIRED ones) with completed walks on its dates. Walks pinned to any other version are not
  released.

**Reading a release** (`releaseId=` on `/api/reports/aggregate` and `.csv`). Anyone with
`report.view` may read one, within their own scope (an out-of-scope unit is still 404 and audited).
A release takes `versionId`, `orgUnitId`, `section` and `item` -- what is shown -- and nothing that
narrows who is counted: `from`, `to`, every `dim_*`, `optionItem`/`option` and `includeDrafts` are
refused with 400 `REPORT_FILTER_NOT_PERMITTED`, each offending parameter named. The figures are
built in three steps:

1. **Per block, per breakdown.** A breakdown is every category a block's walks fall into for one
   item (each option, then `UNANSWERED`, `HIDDEN`, `NOT_APPLICABLE`, `UNRECORDED`) or one dimension
   (each value, then `UNANSWERED`, `HIDDEN`); the categories do not overlap and add up to the
   block's walks. Each breakdown of each block is protected by `DisclosureControl.suppress`:
   * cells of 1..k-1 are withheld (primary); zero is published;
   * complementary cells -- the smallest other non-zero cell, ties by category order -- are added
     until at least two are withheld, they total k or more, and they are not all forced to be 1;
   * if that would withhold every non-zero cell, the whole breakdown is withheld, zeros included;
   * an **audit** then computes, for every withheld cell, every value it could hold in any breakdown
     this algorithm would publish the same way (a reader who knows the rule, its bounds and its
     tie-breaks, not only one who subtracts); if any withheld cell has only one possible value, the
     whole breakdown is withheld instead. `ReportDisclosureTest` proves the result exhaustively for
     every breakdown of up to six categories and small totals, for k = 3 and k = 4, and checks the
     audit against a brute-force inversion of the algorithm.
   Every breakdown of the version is protected, whatever section or question the request selects,
   so a block publishes the same cells in every report that reads it.
2. **Linked breakdowns.** Instrument rules tie some breakdowns together: Period is shown only for
   grades 6-12, so Period's `HIDDEN` count is a sum of Grade cells; the PreK-K section's items are
   `HIDDEN` for every other grade; a classroom-type section's items are `HIDDEN` for every other
   Class Type; the Music/Art/PE section follows Content; a skippable component's ratings are
   `NOT_APPLICABLE` exactly when its "applicable" question was answered No. A published member of
   such a group can solve a withheld cell of another. So breakdowns linked by any rule (read from
   the version's own rules, transitively; an unreported source still links what it governs) are a
   group: if any member has a cell of 1..k-1 in a block, the whole group is withheld in that block;
   otherwise it is published complete.
3. **Adding up.** A report over several blocks adds the cells each block published. A category
   withheld in some block is marked `withheld: true` and its count is the published part -- a lower
   bound -- or `null` when no block published any of it. Because every figure is a sum of figures
   each block's own report already publishes, subtracting any two reports of one release (a district
   and its schools, a school and its neighbour) yields nothing that is not already published.

**Derived figures.** `states.ANSWERED` is the sum of the published option counts (withheld if any
option is). An item's `scored` figures are computed from its published scored options only: with
fewer than k such responses (or none, when some were withheld) `responses`, `sum` and `mean` are
all `null` and `withheld` is `true`; otherwise `withheld: true` says the mean is of the published
ratings only. A section pools its reported items' published scored responses under the same rule.
`withheldResponses` is the block's (or blocks') walks less every figure shown for that breakdown.
`population.byStatus` is `{ COMPLETED }` only: a release has no status to split.

**What a released report looks like.** `mode: "RELEASE"`, `release: { releaseId, observedFrom,
observedTo, minimumWalks, releasedAt }`, `disclosure: { minimumWalks, protected }`. A withheld figure
is `null` -- never 0 and never a number sent beside a flag; a figure only partly published is a
number with `withheld: true`. A selection with no stored block (a school with 0, 1 or 2 walks, or
none of its blocks in the release) returns `population: { walks: null, byStatus: {}, withheld: true }`
and no org unit, dimension, section or item, identically whatever the true count. The CSV carries
the same figures, each on its own record with its own `withheld` flag (an empty count with `1` is
withheld; a count with `1` is the published part). Logs (`report.generated`, `report.exported`,
`report.released`) and audit details (`REPORT_EXPORTED`, `REPORT_RELEASED`) carry identifiers and
published counts only; a withheld population is recorded as `-1`.

**Computing a report in isolation** (audit finding P7C-01). A live report, and each version of a
release being frozen, materialize their authorized scope and walk population in temporary tables
that every aggregate joins. Each computation gets its own pair: connection-local (one `#`, built
from `chr(35)`, never `##`, which SQL Server makes global), named from a server-generated GUID
(`#icf_rp_` / `#icf_ru_` and 32 hex digits, checked against that exact pattern on every use), and
created inside the request's own transaction, which `beginPopulation` requires
(`REPORT_POPULATION_NO_TRANSACTION`). The computation records its connection's session id and
refuses to verify or clean up on any other (`REPORT_POPULATION_CONNECTION_CHANGED`), so a result is
never assembled from two connections. The tables are dropped on success and rolled back with the
transaction on failure. Concurrent requests therefore never share, block on, replace or read one
another's scope or population: `ReportIsolationTest` pauses one computation inside its transaction
and runs another (two live reports on disjoint schools; a live report and a release, both ways) to
completion beside it, and checks both counts exactly. The build the audit examined
(`0c74dbd`) already used connection-local tables: CFML writes one `#` as `##` inside a string, so
its `"##icf_report_population"` was `#icf_report_population` at run time. The fixed name is gone
anyway, and the transaction and connection checks are new.

**What this does not protect against** (accepted or outside the rule):

* A block in which every walk falls in one category publishes that category complete (100%): its
  complement is 0, so nothing is small. That is an attribute of every walk in the block, disclosed
  to anyone who knows a walk was in it. Approved with the rule as a residual.
* The rule protects a release against its own readers. Two people with different scopes who pool
  what each can see, or a reader who also knows facts outside the report (who was walked when), can
  learn more than either report shows. No aggregate suppression prevents collusion or outside
  knowledge.
* Walk-and-report roles reporting inside their own `walk.read` scope see live, unsuppressed figures
  and every filter. They can open each of those walks already.
* Releases record the counts of small cells inside stored blocks (they are needed to protect each
  read the same way), and the membership records which walks each stored block counts; only blocks
  below k are never stored. Database administrators can read walks directly anyway.
* A walk whose visit date is corrected into dates already released is never released, and a walk
  corrected after its release is reported only as it stood when released. Utility is lost; nothing
  is disclosed.

## Mutation identity and idempotency

Every state-changing walk request carries a `clientMutationId` (create, save, complete, void) and,
except on create, the walk's `rowVersion`. Both are mandatory: a missing or malformed token is a
validation error before any write.

`icf.walk_mutation` records each committed mutation in the same transaction as the change. A record
binds the id to its **actor**, **action**, **target**, and the SHA-256 **fingerprint of its
canonical semantic request** (migration `004_mutation_fingerprint.sql`, additive and nullable so
rows written earlier stay valid). The fingerprint is taken over canonical JSON of the action, the
target (the walk, or the org unit for a create), and the fields that decide what the request means:
the whole-state `dimensions`/`responses` for create and save, the `reason` for a void. It excludes
`rowVersion`, `clientMutationId`, `changedAt`, and the requested `versionId` -- none of those is
part of what the request means, and a create retried after a newer version is published must still
match what it committed.

The checks run in a fixed order, each a precondition of the next, so nothing about the recorded
walk is disclosed or returned before it has been earned:

1. **Authorization.** Every replay re-authorizes the recorded walk against the current principal and
   the current authorization graph. An id recorded before access changed answers "not found",
   exactly as opening that walk would -- before any check whose answer could differ per walk.
2. **Actor, action, and target.** A mismatch is the id being reused for a different request:
   409 `MUTATION_ID_REUSED`.
3. **Provenance.** A row written before migration `004` carries no fingerprint, so nothing recorded
   can prove that this request is the request it committed -- an identical-looking retry and a
   materially different request are indistinguishable against it. Such a row is **never replayed as
   a success**: it answers 409 `MUTATION_LEGACY_UNVERIFIABLE` deterministically, writes no
   application state, and tells the client to reload and retry under a new mutation id. Fingerprints
   are never fabricated or backfilled, because the original semantic request cannot be reconstructed
   from the stored outcome.
4. **Semantic request.** A different fingerprint under the same id is 409 `MUTATION_ID_REUSED`; it is
   never accepted as an equivalent retry.
5. **Coherence.** A replay returns the recorded walk as it stands now, and the retrying client still
   holds the local state that went with the *original* mutation. So the recorded outcome is replayed
   only while the aggregate still stands where that mutation left it -- the row version the mutation
   committed is still the row version in the database. If the aggregate has advanced (another session
   saved, completed, or voided the walk in between), the replay is refused with 409
   `MUTATION_REPLAY_SUPERSEDED`: the client is told its mutation did commit and that the walk has
   changed since, so it must reload and reconcile like any other conflict. The response details carry
   the **recorded** row version, never the current one, so no stale local state is ever paired with a
   token that would let it overwrite newer work.

An exact, coherent retry of a committed request replays its recorded outcome and writes nothing.

**Invariant.** An idempotent replay never pairs stale client state with a row version representing
newer server state.

Network errors and HTTP 5xx are ambiguous -- the mutation may have committed before the answer was
lost -- so a client retries them with the same `clientMutationId` and the same body. An operation id
is spent only on a definitive success or a definitive, non-retryable 4xx.

### Pending mutation operations in the browser

Because the server recognises a retry by its id *and* its semantic request, a rebuilt request is a
different request and is refused. So each ambiguous-capable mutation owns one **immutable operation
record** in the browser, created once and never rebuilt from later UI state:

| Field | Meaning |
| --- | --- |
| `action` | `CREATE`, `SAVE`, `COMPLETE`, or `VOID` |
| `target` | the org unit for a create, the walk for everything else -- part of the record's key, so an operation is never shared between two walks |
| `mutationId` | the `clientMutationId` the request was issued with |
| `body` | the frozen semantic request (whole state for create and save, the reason for a void) |
| `rowVersion` | the concurrency token the operation was issued against, where one applies |
| `status` | `UNSENT`, `IN_FLIGHT`, or `AMBIGUOUS` (below) |

The status separates a record nothing has been sent for from one whose request is already on the
wire, because only the first is the browser's alone to replace:

| Status | Meaning | May a newer payload replace it? |
| --- | --- | --- |
| `UNSENT` | minted; no request carrying this id has left the browser | Yes -- nothing on the server can correspond to it |
| `IN_FLIGHT` | its request was sent and no answer has come back | No |
| `AMBIGUOUS` | its answer was lost, was an HTTP 5xx, or could not be used | No |

- A retry after a transport failure, an HTTP 5xx, or an unusable answer reuses the record: the same
  id, the same row version, and the same body, so the server either replays what it committed or
  commits it now.
- **What counts as a transport failure is a type, not a default.** `app/assets/js/api.js` raises
  `NetworkError` only where `fetch()` itself rejects -- no response, no status line, no headers --
  and `ResponseError` when a response arrived and could not be read or parsed. Anything else the
  save path can throw (a walk document that is not a walk, a bug in the response handling) is
  neither. The browser classifies by type and treats every unrecognised failure as unresolved:
  ambiguous, so the record is kept and the retry is offered, but never reported to the person as an
  unreachable server and never allowed to stand in for one. A response-shaped failure means the
  request was delivered, so the mutation behind it is exactly as likely to be committed as one whose
  answer was a 500.
- **An editor change never deletes a record whose request has been sent.** An edit made while a save
  is in flight replaces nothing: the in-flight record keeps its id and its frozen body, the newer
  state is queued, and if that save's answer is lost the browser retries the *original* request
  first. Only once it resolves definitively does the queued newer state go out, under a new id and
  against the row version the retry settled on.
- A record is released only on a definitive outcome -- a success, or a non-retryable 4xx -- or on an
  explicit decision by the user to abandon it. Reloading the walk from the server releases an
  `UNSENT` save record but keeps a sent one: a reload cannot tell whether the server committed it.
- A `COMPLETE` record is keyed to its walk, so completing a different walk later never reuses it.
- A `VOID` retry sends the reason and row version from its record, not the input field as it now
  stands.
- A pending record is unsaved work: internal navigation and `beforeunload` both see it, including on
  the list view where no walk is open, so an ambiguous create, completion, or void cannot be silently
  abandoned by a reload, a closed tab, or a navigation.
- **Every ambiguous operation stays reachable.** The control that started one is not a reliable home
  for its retry: a void's confirmation row is destroyed by the next list render, and a completion's
  button is hidden as soon as the walk is reloaded and turns out to have been completed. So the
  browser renders an unfinished-operations bar from the registry itself, outside both views, giving
  each unresolved operation a retry that re-sends its exact frozen request and an explicit "stop
  trying". A record can therefore never outlive every way to resolve it, which would leave a
  permanent unload guard with nothing left to click.
- `MUTATION_REPLAY_SUPERSEDED` is definitive: the mutation committed, so the record is released and
  the browser reconciles (a save enters conflict review; a create, completion, or void reloads what
  the server holds).

## Visibility, retention, and clearing on a whole-state save

The server, not the browser, owns visibility, applicability, and retention. Inside the locked
mutation transaction it loads the persisted state, derives visibility from the walk's **pinned**
instrument, and merges:

| Case | Result |
| --- | --- |
| Hidden under the submitted state | The persisted value is kept. An omitted hidden value is RETAINED without the browser echoing it, and a value a client sends for a hidden target is ignored. |
| Was hidden and the submission omits it | The persisted value reappears (the condition has returned). |
| Visible and the submission omits it | CLEAR: the value is cleared. |
| Visible and the submission carries it | A normal edit. |
| `NOT_APPLICABLE` (skippable component marked No) | Ratings are cleared, notes are preserved. Switching back to Yes returns the ratings as `UNANSWERED`, never the cleared values. |

A crafted client therefore cannot alter, inject, or delete a value the instrument currently hides.

## School and organizational scope

**Invariant.** A walk authorized and stored at School A can never carry School B's School dimension
value, whatever the two deployments' org-unit codes happen to be.

The identity relationship between a SCHOOL org unit and an instrument School dimension value is an
explicit, stored, validated mapping: `icf.org_unit_dimension_map` (migration
`005_org_unit_dimension_map.sql`), one row per `(org_unit_id, dimension_code)` naming a `value_code`.
It is **not** a comparison of `org_unit_code` with `valueCode`. Those are two independently owned
namespaces, and equality between them is a coincidence of a particular deployment's naming, not an
identity: a deployment whose codes are not the instrument's school value codes has no matching
values at all, and then nothing could contradict any School value a client sent.

Two relational facts carry the invariant rather than any procedure:

| Constraint | What it guarantees |
| --- | --- |
| `PK (org_unit_id, dimension_code)` | one org unit carries at most one School value |
| `UNIQUE (dimension_code, value_code)` | one School value belongs to at most one org unit, so School B's value is never available to School A |

`source` records where a row came from: `EXPLICIT` (declared in the org-unit import) or
`CODE_ALIGNED` (derived by the alignment endpoint from an exact code match, validated against the
instrument at the time it ran). Nothing is ever derived from a display name.

At walk time the server reads only the stored row, and re-validates its `value_code` against the
walk's **pinned** instrument version:

- **Mapped, and the mapped value exists in the pinned version**: the server fills and locks that
  value, and refuses any other School value, including the free-text "Other"
  (409 `SCHOOL_ORG_MISMATCH`, audited `WALK_SCHOOL_SCOPE_REJECTED`, nothing written).
- **Unmapped, or the mapped value is not defined by the pinned version**: the School dimension
  **fails closed**. Nothing is filled, because nothing trustworthy exists to fill, and any submitted
  School value is refused with 409 `SCHOOL_ORG_UNMAPPED` (audited `WALK_SCHOOL_SCOPE_UNMAPPED`,
  nothing written). The server will not label a walk with a school it cannot verify, so a deployment
  must declare the mapping before walks there can carry a School value. Code equality alone maps
  nothing: a SCHOOL unit whose `org_unit_code` *is* an instrument School value still fails closed
  until a row exists for it.
- A district-scoped user creating a walk at an authorized descendant SCHOOL is an ordinary create:
  authorization is the org unit's, and the School dimension follows that unit's mapping.
- Walks at a DISTRICT unit are left alone. This specification defines no district-level walk
  semantics, so none are assumed.

Operators declare the mapping in one of two ways (both write the same validated rows, and both refuse
a value the instrument does not define, one another unit already holds, and one that identifies
nothing — see below):

- `POST /api/maintenance/org-units/import` with `schoolValueCode` on a SCHOOL unit (`EXPLICIT`);
- `POST /api/maintenance/org-units/align-school-dimension`, which *reports* the rows an operator
  could derive for active SCHOOL units whose `org_unit_code` is exactly a School value code of the
  current renderable version, as `candidates[]`, and writes only the pairs that operator sends back
  in `confirm[]` (`CODE_ALIGNED`). This is the only place a code is ever compared with a value code,
  it runs only when an operator asks, code equality on its own persists nothing, and what a
  confirmation produces is a stored row. `{ "dryRun": true }` is the report with confirmations
  ignored.

What is stored is the instrument's own spelling of the value code, never the org unit's. The walk
path compares the stored code with the pinned version's values exactly (case-sensitively), so a unit
code matching in everything but case must still store the instrument's form.

### Values that identify nothing

A controlled list can define a value that names no particular thing. The School dimension allows free
text, so it carries a value coded `other` meaning "none of these, see the typed text". It is a value
the instrument defines, but it is never an identity:

- `schoolValueCode: "other"` is refused (400 `ORG_UNIT_SCHOOL_VALUE_NOT_IDENTIFYING`);
- a SCHOOL unit whose `org_unit_code` is exactly `other` is reported by the alignment as
  `NON_IDENTIFYING_VALUE_CODE`, is never a candidate, and cannot be confirmed into one;
- `icf.org_unit_dimension_map` refuses the row outright
  (`CK_org_unit_dimension_map_identifying`, migration `005`), so no application path, script, or
  hand-written statement can create one.

Such a unit stays unmapped, which the walk path already handles by failing closed: no School value is
filled and none is accepted. That is strictly better than an identity that identifies nothing, which
would label the unit's walks "Other" and — because the mapping is unique on (dimension, value) —
take a value naming no school away from every other school.

A deployment upgrading from before migration `005` runs the alignment endpoint once, reviews the
candidates and confirms them; until it does, walks at its schools carry no School value and refuse a
submitted one.

## Runtime instrument selection and snapshot integrity

- The current version is scoped to the ICFWalk instrument itself (`ICFWALK_INSTRUMENT_CODE`): the
  newest PUBLISHED version whose `effective_start` is at or before the current UTC instant and
  whose `effective_end` is absent or still in the future. A version scheduled for a future term, an
  expired one, and a version of any other instrument that happens to share a label are all
  excluded. The development-only DRAFT preview is scoped to the same instrument and has no
  effective window.
- Draft import and draft discard resolve a version by `(instrument_id, version_label)`. A version
  label is unique only within an instrument, so another instrument's identically labelled draft can
  neither be selected nor deleted.
- Every uncached snapshot load re-computes SHA-256 over the exact stored canonical UTF-8 snapshot
  and compares it with `checksum_sha256`. A mismatch, or a missing digest, fails closed: nothing is
  parsed into a render model, nothing is cached, and the walk surfaces answer with a configuration
  error rather than rendering or validating against an altered contract.

## Concurrency and transactions

- Treat the walk plus changed dimensions/responses as one authorized aggregate mutation.
- Compare the supplied walk `row_version` before applying changes.
- Apply explicit component-clearing behavior and the triggering applicability response in one transaction.
- Increment/update the walk timestamp and return its new row version after the child updates commit.
- Use bounded retry only for transient database failures, not for stale concurrency conflicts.


## Build decisions recorded in Phase 4 (application policy under this contract)

- **"Other" free text on a LIST dimension**: `selected_value_id` = the dimension's `other` value and
  `text_value` = the typed text. The text is a qualifier of the selected value, not a second typed
  value; it is accepted only when the Other value is selected (stale text from a previous Other
  selection is dropped) and it never enters aggregate grouping (reports group by
  `selected_value_id`). Value codes are compared exactly.
- **Response rows**: one `walk_response` row exists for every response-capable item of the pinned
  version (display items excluded) from creation, with `response_state = UNANSWERED` when empty, so
  the four states are countable in reports. Values are cleared (option NULL) for `NOT_APPLICABLE`
  and retained for `HIDDEN`. Dimension rows exist only while a value is present; a dimension's
  HIDDEN state is derived by evaluating the walk's pinned rules (the table has no state column).
- **`observed_at`** follows the visit-date dimension (the first DATE-typed placement with a value).
  When no visit date is present -- never entered, or entered and then cleared -- it falls back to the
  walk's immutable `created_at`, so a cleared date never leaves a stale observation timestamp behind.
- **Idempotency**: `icf.walk_mutation` (migrations `003` and `004`) records each client mutation id
  with the committed outcome in the same transaction; an exact retry replays it. Ids are bound to
  walk, actor, action, and the fingerprint of the canonical semantic request. See "Mutation identity
  and idempotency" above.
- **Mutation response coherence**: a successful SAVE or COMPLETE response is materialized inside the
  same transaction that performs the mutation, while the walk mutation lock is still held, and the
  finished document is returned through the transaction outcome. The rowversion, header, dimensions,
  responses, evaluation states and revision count it carries therefore all describe one serialized
  database state -- the state that mutation produced -- and its rowversion always equals the one the
  mutation recorded in `icf.walk_mutation`. No other SAVE, COMPLETE or VOID can commit between a
  mutation and the construction of the document it returns. This includes the successful no-op save
  of an already completed walk, which answers from the state it observed rather than a later one.
  Reading the walk again after the commit instead would hand a client that still holds its own
  submitted state a rowversion minted for someone else's, and that client's next whole-state save
  would overwrite the newer work without ever seeing 409 `STALE_ROW_VERSION`. A replay is materialized
  under the same lock by the same rule (see "Mutation identity and idempotency").
- **Summary export coherence** (Phase 5 correction): `GET /api/walks/{id}/summary` is a read, but
  it is a read of an *aggregate*, so it is materialized inside one transaction that takes the walk
  mutation lock first (`findWalk(id, true)`) and holds it across the header, the dimension values,
  the responses, the visibility evaluation, the text and the file name. Unlocked, those were
  separate statements and a mutation could commit between any two of them: a save that changes a
  visibility-driving dimension and a response it governs commits both together, and an export
  straddling that commit could pair the old dimensions with the new responses, then print, under
  the old dimensions, a retained answer the new ones hide. The file would describe a state the
  database never held, violating SUM-01 and SUM-04. Because SAVE, COMPLETE, VOID and a replay all
  begin by taking that same row lock, serializing against it serializes against all of them: a
  mutation commits strictly before or strictly after an export, never inside one. The export still
  writes nothing -- no row version moves, no revision, no mutation record -- and the metadata-only
  log line and `WALK_SUMMARY_EXPORTED` audit event are written after the transaction, from the
  already-coherent result.
- **Revisions**: appended on completion (`COMPLETE`, the pre-completion snapshot) and on each
  *material* edit of a COMPLETED walk (`POST_COMPLETION_EDIT`, the snapshot before the edit); DRAFT
  autosaves append none. An identical save to a COMPLETED walk writes nothing at all: no revision, no
  new row version. `prior_snapshot_json` holds the walk header, dimension values, and responses with
  states.
- **Void vs delete**: the My Walks delete action voids a DRAFT with the reason
  "Deleted by owner from My Walks"; a COMPLETED walk requires an explicit reason; physical deletion
  is never available (`DELETE` answers 409). Voided walks keep all rows and leave the list.
- **List scope**: My Walks lists the owner's non-voided walks in units where the owner still holds
  walk.edit_owned or walk.read; `scope=all` adds other users' non-voided walks in walk.read units.
- **Email-draft JSON** is validated on save against the schema above (only those five keys,
  `includedPartKeys` strings, `drafted` boolean) and stored as canonical JSON.

## Summary export and email-draft decisions recorded in Phase 5 (presentation policy)

The text export is derived, never stored: there is no summary table, no "last exported" column, and
no cache. Phase 5 adds no table, column, or migration. The email draft is the existing
`EMAIL_DRAFT_JSON` response (`email_workflow`) and follows "Values by type" unchanged.

One formatting contract is implemented twice, in `src/walks/WalkSummaryFormatter.cfc` and
`app/assets/js/summary.js`, and `tests/fixtures/summary-vectors.json` proves them byte-identical.
Both are pure functions of the render model, the working state, and the engine evaluation. The
decisions below are the points where a source had to be resolved; each was reviewed against
`source/current-prototype.html` with `scripts/prototype-summary-oracle.mjs`.

1. **A hidden value is excluded from the export, not deleted.** A dimension prints only while
   `dimensionStates[code] == "ANSWERED"` and a section only while it is visible, so a retained
   hidden Period or a hidden conditional card never reaches the text, the file name, or the email
   (SUM-04). The rows stay in the database and print again the moment the instrument shows them.
   This is the contract's "exclude from reports and export while hidden" applied to the export.
2. **Conditional-card order in the export.** `behavior.export.preservePrototypeSectionOrder` is
   true, so the export follows the prototype rather than `displayOrder`. The two differ in exactly
   one place. The rule is keyed on the SHOW rule's source dimension, never on a section key: a
   conditional card sourced from the `content` dimension prints immediately before the last
   conditional card sourced from `classType`. Today that is Content-Area before ESL. The renderer
   keeps `displayOrder`. OPEN for content owners: renumber `displayOrder` and the rule becomes a
   no-op on its own.
3. **The content-area heading is the section title uppercased** (`CONTENT-AREA LOOK-FORS`), matching
   the on-screen card, where the prototype composed `<CONTENT> CLASSROOM`. OPEN together with the
   card heading (a `settings.titleTemplate` supporting `{contentLabel}` would retire it).
4. **One trailing colon is stripped from a placement label** before `": "` is appended, so
   `Visit occurred at the:` prints once and not twice. The doubled colon is a prototype defect.
5. **Non-scored choices print the option label** (`[Yes]`, `[ON pace]`, `[Partial]`); scored choices
   print `<storedCode>/<max numeric score>`. The only visible difference from the prototype is the
   capitalization of yes/no, and the label is what the person saw on the pill.
6. **Part 4 export labels come from a presentation map by item key** (`Strengths`, `Growth areas`),
   the same device as `LIST_CARD` in `app.js`. OPEN for a future DRAFT: an `exportLabel` item
   setting would remove the map.
7. **A non-scored choice among scored siblings prints its prompt with a trailing colon**
   (`- Pacing:  [ON pace]`), stated as a data rule rather than an item key.
8. **Component averages use answered numeric scores only** and print `n/a` when none is answered; a
   blank never counts as zero (COND-15, SUM-02). A component whose rated rows are all
   `NOT_APPLICABLE` prints the not-part line, no average and no ratings, and keeps its notes
   (SUM-03). One decimal place, rounded exactly as JavaScript's `toFixed(1)` rounds the IEEE-754
   double quotient, so 2.25 formats as `2.3` and 3.05 as `3.0`; the CFML twin reproduces that with
   `BigDecimal(double).setScale(1, HALF_UP)` and the vectors pin the agreement.
9. **Line endings and encoding.** UTF-8 without a BOM, LF only, no trailing newline. `app/index.cfm`
   ends at its closing tag with no trailing newline for the same reason: any character after it is
   template output and would be appended to every response body.
10. **The file name is derived from `behavior.export.fileNamePattern`**, which names the dimensions
    that label the walk. Values are joined by the pattern's separator, and runs of characters
    outside `[A-Za-z0-9_-]` collapse to a single underscore with case preserved. A walk with nothing
    named falls back to its id. Nothing else survives, so no quote, path separator, or traversal
    sequence can reach a `Content-Disposition` header (SUM-05).
11. **The email draft's key order is part of the contract.** The server canonicalizes to
    `body, drafted, includedPartKeys, subject, to` and the browser serializes in that same order, so
    a reload compares equal and the conflict panel never reports an unsent edit nobody made.
    Clearing a draft keeps the recipient and the ticked parts and empties only the generated text
    (SUM-09). The draft is never a completion issue.
12. **`to` is optional free text.** It is not validated as an address, is stored verbatim, and is
    never parsed as a mail header, because nothing in the application sends mail. The browser
    percent-encodes it into a `mailto:` URL, where a CR/LF or a `bcc:` is data and not a header.
13. **A voided walk still exports.** Phase 4 keeps it readable by id, and the text carries no status
    line. OPEN: content owners could ask for one later.
14. **Export privacy.** `WALK_SUMMARY_EXPORTED` and the export log line carry the walk id, its
    status, the version id, and a byte count. The summary text, notes, subject, body, and recipient
    are never logged or audited (SEC-05).
