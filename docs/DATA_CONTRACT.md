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
8. Resolve global dimensions by code and dimension values by value code.
9. Insert/update rules, items, and version-specific dimension placements after their referenced GUIDs are known.
10. Validate every reference, allowed type, order, unique key, response option, and JSON document.
11. Compile canonical snapshot JSON from the imported contract.
12. Compare the compiled semantic content with the input. Abort on mismatch.
13. Commit only after all validations pass.

The importer must be idempotent for an unchanged DRAFT and must not create duplicate child rows on retry.

## Publishing

Publishing a DRAFT is one transaction:

1. Lock the DRAFT version for update.
2. Revalidate all definitions and unresolved references.
3. Confirm that current required items have valid response sets.
4. Record unresolved placeholders as warnings, not invented replacements. Publishing policy may decide whether warnings block publication.
5. Generate canonical compiled snapshot JSON.
6. Calculate SHA-256 over the exact stored canonical JSON.
7. Set effective start, publisher, published timestamp, checksum, and status to PUBLISHED.
8. Write an audit event.
9. Commit.

After commit, the version and every child definition are immutable. A change requires a new DRAFT version.

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
| `AMBIGUOUS` | its answer was lost, or was an HTTP 5xx | No |

- A retry after a transport failure or an HTTP 5xx reuses the record: the same id, the same row
  version, and the same body, so the server either replays what it committed or commits it now.
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
