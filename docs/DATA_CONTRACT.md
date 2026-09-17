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
  "rowVersion": "base64-rowversion",
  "clientMutationId": "GUID",
  "changedAt": "ISO-8601 timestamp",
  "dimensions": {
    "school": { "selectedValueCode": "elgin_high_school" },
    "tag": { "textValue": "optional text" }
  },
  "responses": {
    "comp_s1_q1": { "state": "ANSWERED", "storedCode": "4" },
    "comp_s1_notes": { "state": "ANSWERED", "textValue": "..." }
  }
}
```

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

## Concurrency and transactions

- Treat the walk plus changed dimensions/responses as one authorized aggregate mutation.
- Compare the supplied walk `row_version` before applying changes.
- Apply explicit component-clearing behavior and the triggering applicability response in one transaction.
- Increment/update the walk timestamp and return its new row version after the child updates commit.
- Use bounded retry only for transient database failures, not for stale concurrency conflicts.

