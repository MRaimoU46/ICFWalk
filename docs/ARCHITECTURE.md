# Architecture notes (Phases 1 to 5, the Phase 6 publish foundation, and Phase 7 reporting)

## Shape

```
HTTP -> app/index.cfm -> Router -> Controller -> Service -> Repository -> SQL Server (icf schema)
                          |            |             |
                          |            |             +-- Validator / Normalizer / SnapshotCompiler
                          |            +-- MaintenanceGuard (Phase 1) / Authorization (Phase 2)
                          +-- Responder (JSON, error mapping) + RequestContext (correlation)
```

Everything is plain CFML script components wired by `src/Bootstrap.cfc` into a singleton container
stored in `application.icf`. There is no framework dependency, and no CFC is reachable directly
over HTTP: `Application.cfc` rejects every request except `index.cfm`.

| Layer | Components |
| --- | --- |
| Request/controller | `http/Router`, `http/Responder`, `http/MaintenanceGuard`, `controllers/*` |
| Service | `instrument/InstrumentImportService` |
| Validation | `instrument/InstrumentConfigValidator` (document rules), `core/Db` typed parameters |
| Data access | `instrument/DefinitionRepository`, `instrument/DefinitionMapper`, `audit/AuditRepository` |
| Cross-cutting | `config/ConfigLoader`, `core/Errors`, `core/Logger`, `core/RequestContext`, `core/CanonicalJson` |
| Instrument engine (Phase 3) | `instrument/SnapshotService`, `instrument/RenderModelBuilder`, `instrument/VisibilityEngine` |
| Views | `views/shell.html` served by `controllers/ShellController`; browser modules in `app/assets/js` (`renderer.js`, `rules.js`, `walk-state.js`, `walk-store.js`, `app.js`, `reports.js`) |
| Reporting (Phase 7) | `reports/ReportService`, `reports/ReportRepository`, `controllers/ReportController` |

## Configuration and environments

`ConfigLoader` reads `ICFWALK_*` environment variables, then an optional `.env` file. The
environment defaults to `production`, which disables maintenance endpoints, the test runner, and the
development identity stub. A production configuration that tries to enable the development identity
stub is refused at startup (`ICFWalk.Configuration`), which is the AUTH-02 seam. All open decisions
from `docs/OPEN_DECISIONS.md` are surfaced as configuration seams with their documented safe defaults
(`ICFWALK_PLACEHOLDER_WARNINGS_BLOCK_PUBLISH`, `ICFWALK_HIDDEN_PERIOD_POLICY`,
`ICFWALK_REPORT_SUPPRESSION_THRESHOLD`; outbound email is not configurable and always off).

## Error model

Deliberate failures throw `ICFWalk.*` exception types with a stable `errorcode` and optional JSON
details (`core/Errors`). `Responder` maps types to HTTP statuses (400/401/403/404/409/422/500) and
returns `{ error: { code, message, correlationId, details? } }`. Unexpected exceptions are logged
with their location and returned as a generic 500 with only the correlation id outside development.

## Logging and correlation

`RequestContext` assigns or accepts (`X-Correlation-Id`, restricted character set) a correlation id
per request and echoes it in the response header. `Logger` writes one canonical JSON line per event
to the ColdFusion log `icfwalk` and redacts by key name (passwords, tokens, cookies, narrative
fields such as `text_value`, `notes`, `body`, `subject`, teacher and email fields, prompts and
labels) and truncates any string over 200 characters, so free text never reaches the log even under
an unexpected field name. `AuditRepository` applies the same key denylist before persisting
`details_json`.

## Canonical JSON and snapshots

`core/CanonicalJson` implements `icfwalk-canonical-json/1` (sorted keys, JSON.stringify escaping,
plain decimal numbers, ISO-8601 UTC dates). It is used for the compiled snapshot, checksums, stored
`settings_json`/`conditions_json` documents, log lines, and API responses (so numeric-looking
strings never become numbers, a known `serializeJSON` hazard on Adobe ColdFusion).

`scripts/lib/snapshot.mjs` is the independent Node reference implementation. Shared vectors
(`tests/fixtures/canonical-json-vectors.json`) and the golden checksum
(`tests/golden/instrument-snapshot.golden.json`) prove the CFML and Node implementations are
byte-identical. The compiled snapshot (`icfwalk-instrument-snapshot/1`) contains the instrument,
version provenance, all definitions keyed by logical keys (never SQL GUIDs), the prototype behavior
block, the content-review block, and counts. Because it carries no environment-specific identifiers,
the same document produces the same checksum in every environment.

## Import algorithm

`InstrumentImportService.importConfig` follows `docs/DATA_CONTRACT.md`:

1. Full validation of the authoring document before any database access (structure, unique keys,
   case-collision guard, references, enumerations, supported rule effects, orders, response-set
   integrity, conditions JSON shape and consistency with the flat authoring columns, ISO instants,
   retired SIP text guardrail, placeholder warnings).
2. One transaction: resolve instrument by `code`; lock and resolve the version by
   `(instrument_id, version_label)`; refuse `PUBLISHED`/`RETIRED` (`ICFWalk.Import.PublishedVersion`)
   and DRAFTs referenced by walks (`ICFWalk.Import.VersionInUse`); create the DRAFT when absent.
3. Upsert by unique key with GUID reuse: sections in two passes (content first with parked orders,
   then parent + final order), response sets and options, global dimensions and values (never
   deleted; stale values are kept and reported), rules (target logical IDs resolved to keys), items,
   placements. Version-scoped rows that disappeared from the document are deleted. Display orders
   are "parked" (+1,000,000) before updates so reorders never violate the unique sibling-order
   indexes mid-transaction.
4. Read every definition back from SQL Server, recompile, and compare the definitions checksum with
   the one compiled from the input. Any difference rolls the whole import back
   (`IMPORT_ROUNDTRIP_MISMATCH`).
5. Store the canonical snapshot and SHA-256 on the version and append an audit event.

Fields the supplied schema has no column for are stored in the owning row's `settings_json`
(or, for `response_option` and `dimension_value`, in the parent's `settings_json`; for rules, in an
`authoring` block inside `conditions_json`). `DefinitionMapper` documents the exact layout.

## Recorded source conflict

`icf.instrument_dimension` carries the unique index `UX_instrument_dimension_order (version_id,
display_order)`, but `config/instrument-config.json` authors placement `displayOrder` per section
(Visit information uses 10..80; Target / Taxonomy reuses 10 and 20 for `topic` and `tag`). Per the
source precedence (JSON is the instrument contract, SQL is the persistence authority) neither
supplied file was changed: the snapshot and `settings_json.displayOrder` keep the authored
per-section order, and the `display_order` column receives a derived version-unique value
(document order of sections, then authored order). The validator checks placement order uniqueness
per section. Reporting and rendering must read the authored order from the snapshot.

## Security posture (Phase 1 scope)

- Every SQL statement is parameterized through `core/Db` (`queryExecute` with typed params).
- Maintenance endpoints (seed, versions, discard draft, test runner) require an explicit enable
  flag, a constant-time-compared token header, and a loopback caller unless remote access is
  explicitly allowed; failures respond 404 and are logged, successes are audited. They are not
  cookie-authenticated, so CSRF does not apply to them; Phase 2 adds session auth and CSRF tokens
  for user routes.
- Responses set `Cache-Control: no-store` and `X-Content-Type-Options: nosniff`.
- `configFile` for the import endpoint is restricted to a `.json` file name inside the configured
  instrument directory (no path traversal).

## Identity, roles, and organizational scope (Phase 2)

```
request -> IdentityProvider.resolve(req) -> UserRepository (JIT provision) -> SessionService
        -> AuthorizationService.principalFor(user) -> Router policy check -> controller
                                                    -> authorizeWalk / requirePermission (record level)
```

**Identity adapters** implement `identity/IdentityProvider` (`resolve(req)` returns an asserted
subject or an anonymous result with a reason). `HeaderIdentityProvider` is the production SSO seam:
the district's SSO gateway/reverse proxy authenticates the user and asserts the subject, name, and
email in headers whose names come from `ICFWALK_SSO_*_HEADER`. Only source addresses in
`ICFWALK_SSO_TRUSTED_PROXIES` (IPv4 or CIDR) are believed, an optional shared secret header can be
required, and requests carrying identity headers from untrusted addresses are logged as spoofing
attempts and treated as anonymous. No identity provider product is assumed; an OIDC or SAML adapter
would implement the same interface with `perRequest() = false` so the session retains the identity
between requests. `DevelopmentIdentityProvider` reads `X-ICFWalk-Dev-Subject` and can only be
constructed when `ICFWALK_DEV_IDENTITY_ENABLED=true` outside production; `ConfigLoader` refuses that
setting in production, `IdentityProviderFactory` refuses the mode without it, and the provider's
constructor refuses again, so it cannot be enabled by accident (AUTH-02).

**Users** are matched by `app_user.identity_subject` only. First sign-in provisions the row
(`ICFWALK_AUTO_PROVISION_USERS`, default true; users still have no access until a role assignment
exists). Inactive users are rejected. Sign-in rotates the session id, stores only user id, subject,
sign-in time, and a 256-bit CSRF token, and is audited (`USER_PROVISIONED`, `USER_SIGNED_IN`,
`USER_SIGNED_OUT`). Cookies are HttpOnly, SameSite=Lax, and Secure (the Secure flag cannot be
disabled in production).

**Authorization** (`authorization/AuthorizationService`) rebuilds the principal on every request from
`user_role_scope` joined to `app_role` and `org_unit`, filtered in SQL by the database clock
(`effective_start <= now < effective_end`), active role, and active unit. `include_descendants`
expands to every active descendant of the assigned unit through the in-memory active tree. The five
schema role flags map to permissions `walk.create`, `walk.read`, `walk.edit_owned`, `report.view`
(org-scoped) and `instrument.manage` (global, never grants walks or reports). `requirePermission`
distinguishes a missing capability (403) from an out-of-scope or unknown unit (404) so existence is
not disclosed; malformed identifiers are 400. `authorizeWalk(principal, walkId, action)` re-resolves
the walk's org unit and owner from the database: `read` needs `walk.read` in the walk's unit (or
ownership with `walk.edit_owned`), `edit`/`void` need ownership plus `walk.edit_owned`. Report-only
roles therefore never reach individual walk details. Every denial is audited as `ACCESS_DENIED` with
permission, unit, and record id only.

**Router policies**: every route declares `public`, `maintenance`, `{ authenticated }`, or
`{ permission }`; there is no permissive default. State-changing session routes require the
synchronizer CSRF token header. Maintenance routes (seed, org-unit import, user provisioning, role
assignment, test runner, fixture cleanup) remain token-guarded and never use the session.

**Bootstrap of a deployment**: import org units (`config/org-units.example.json` as a template),
provision the first administrator, assign `MASTER_INSTRUMENT_ADMIN`, then assign walk/report roles
per district or school, all through the maintenance endpoints (documented in `docs/LOCAL_SETUP.md`).

## Instrument engine and visual shell (Phase 3)

```
instrument_version.compiled_snapshot_json
   -> SnapshotService (current PUBLISHED, or DRAFT fallback outside production; cached by checksum)
   -> RenderModelBuilder.build(snapshot)  -> render model (icfwalk-render-model/1)
   -> GET /api/instrument/current          -> browser renderer.js (DOM) + rules.js (visibility)
                                              VisibilityEngine.cfc = server twin of rules.js
```

**Render model.** `RenderModelBuilder` turns the flat snapshot into a section tree (children by
`parentSectionKey` and `displayOrder`) whose nodes carry only derived facts, never named content:
placements (dimension inputs with label, placeholder, data type, values, option filter), items
with a `layout` derived from item type and response set (`display-heading`, `display-guidance`,
`question` = choice with definitions, `choice-row` = choice without definitions such as yes/no,
`applicability`, `notes`, `text`, `email-draft`), question numbers (scored questions are numbered;
sections without scored questions number every question, which reproduces the prototype), and
section presentation (`card` for top-level sections that hold placements or are conditional,
`accordion` for the other top-level parts, `component` for nested sections with
`settings.partNumber`, `block` otherwise; a block shows its heading only when it has look-fors
or a color). Skippable components are recognised from the rules: the item that is the ITEM-typed
source of SHOW rules on sibling items is the applicability item and the targets are the rated
items. The 17 placeholder items are flagged (`isPlaceholder`) but displayed as the prototype does.
Unsupported rule effects, operators, option filters, and item types are refused at build time.

**Visibility engine.** `VisibilityEngine.cfc` and `app/assets/js/rules.js` implement the same
semantics and are proven equivalent by `tests/fixtures/visibility-vectors.json` (32 states,
asserted by both `VisibilityEngineTest` and `tests/node/visibility.test.mjs`). A target with SHOW
rules is visible when any rule is true; DIMENSION conditions compare the selected value's label or
code, ITEM conditions the stored option code; operators EQUALS/NOT_EQUALS/IN/NOT_IN with AND/OR.
Response states: HIDDEN (section or dimension-driven rule), NOT_APPLICABLE (hidden by a
sibling-item rule, i.e. the applicability answer), ANSWERED (valid option code or non-empty text),
UNANSWERED; nothing is ever coerced to zero. Option filters come from placement settings
(`schoolTypeToGradeBand` = grade values whose `valueGroup` equals the selected school's group; Other
or no school = every grade). `normalize()` applies the prototype's clearing: a filtered selection
that is no longer allowed is cleared; NOT_APPLICABLE responses are cleared (ratings when a
component is set to No; notes are never rated and remain); dimension values hidden by rules are
retained unless `ICFWALK_HIDDEN_PERIOD_POLICY=CLEAR` (docs/OPEN_DECISIONS.md, exposed to the
browser as `policies.hiddenDimensionPolicy`). The working state shape is the Phase 4 autosave
payload from `docs/DATA_CONTRACT.md` (`dimensions` by code, `responses` by item key).

**Browser shell.** `GET /` serves `src/views/shell.html` (no instrument content, no user data,
strict CSP) and the ES modules in `app/assets/js`. `renderer.js` builds the editor DOM once from
the model and keeps it in sync on every edit (visibility, filtered options, pressed pills, rating
counts, live announcements). `walk-store.js` is the persistence boundary: Phase 3 shipped an
in-memory `SessionWalkStore`; Phase 4 replaced it with `ApiWalkStore` (same interface plus
`instrument` and `complete`) and the 700 ms debounced autosave (see the Phase 4 section). My Walks card
composition (title = grade · content, meta = school · date · relative time) is presentation
configuration by dimension code in `app.js` (`LIST_CARD`), not instrument content.

## Walk persistence and autosave (Phase 4)

```
browser app.js (700 ms debounce, mutation ids, rowVersion)
   -> ApiWalkStore (walk-store.js) -> /api/walks routes (Router policy: walk capability + CSRF)
   -> WalkController -> WalkService
        AuthorizationService.authorizeWalk (scope + owner + status re-read from the database)
        WalkPayloadValidator (keys, codes, values against the pinned version's render model)
        VisibilityEngine.normalize + evaluateVisibility (server clearing and states)
        WalkRepository (one transaction: UPDLOCK on icf.walk, diff-writes, revision, mutation log)
        AuditRepository (lifecycle and security facts only)
```

**Aggregate and transaction.** A walk is `icf.walk` plus one `walk_dimension_value` row per
dimension with a value and one `walk_response` row per response-capable item of the pinned
version (state `UNANSWERED` when empty, so state counts are reportable). `PUT /api/walks/{id}`
carries the whole working state; the server validates it (`WalkPayloadValidator`), re-normalizes it
with the same engine the browser uses, then, inside one transaction, locks the walk row, compares the
client's `rowVersion` token with the row's `rowversion` (409 `STALE_ROW_VERSION`, nothing written,
audited `WALK_SAVE_CONFLICT`), writes only the rows whose value or state changed, bumps
`updated_at`/`rowversion`, and records the client mutation id with the committed outcome
(`icf.walk_mutation`, migration `003`). A retry with the same id replays that outcome; the id is
bound to its walk, actor, and action. Reads never trust request fields for scope: org unit, owner,
version, and status always come from the row.

**Validation (fail closed).** Dimension codes must be placements of the pinned version; list codes
resolve to `dimension_value` GUIDs of that dimension, `otherText` is accepted only on `allowOther`
dimensions and stored only with the Other value selected (documented mapping: `selected_value_id`
= Other, `text_value` = the text); TEXT/DATE/NUMBER/BOOLEAN values must fit the data type
(`YYYY-MM-DD` calendar dates, 1000-character texts). Item keys must be active items of the version;
display items accept nothing; choice items accept only a `storedCode` of their own response set
(resolved to the option GUID of that set, so an option that exists in another set or version is
refused, SAVE-07); text items accept `textValue` only (20,000 characters); the email-draft item
accepts only the application schema of `docs/DATA_CONTRACT.md` and is stored as canonical JSON.
All comparisons of codes use exact string comparison (`compare`), never CFML `==`, which treats
`"yes"` and `"1"` (and `"1"` and `"1.0"`) as equal; the shared vectors carry cases for this.

**States and clearing.** The engine's `normalize` runs server-side on every save: a grade outside
the selected school's band is cleared (`DIMENSION_CLEARED/OPTION_FILTER`), and setting a skippable
component to No clears its ratings (`RESPONSE_CLEARED/NOT_APPLICABLE`) in the same transaction as
the applicability answer; notes are never rated and are retained. Persisted response states follow
`evaluateVisibility`: `HIDDEN` rows keep their value (conditional classroom sections reappear with
their answers), `NOT_APPLICABLE` rows have no option, Period hidden outside grades 6–12 keeps its
row (`RETAIN_HIDDEN`, configurable). `observed_at` follows the visit-date dimension.

**Lifecycle.** `POST .../complete` validates every required, currently visible item and placement
(400 `WALK_INCOMPLETE` with field-specific errors; the draft is untouched), appends revision
`COMPLETE` (the pre-completion snapshot), sets `COMPLETED`/`completed_at`, audits `WALK_COMPLETED`.
Owners may still edit a completed walk: each such save must leave it complete (400
`WALK_COMPLETION_INVALID`) and appends revision `POST_COMPLETION_EDIT`; drafts append no revisions
(autosave would create thousands). `POST .../void` sets `VOIDED` with a reason (required for
completed walks; drafts use the default reason from the My Walks delete action) and keeps every row;
`DELETE` is always refused (409 `WALK_DELETE_REFUSED`). Voided walks leave the list, stay readable
by id, and reject edits. Audit events: `WALK_CREATED`, `WALK_COMPLETED`, `WALK_COMPLETION_REJECTED`,
`WALK_POST_COMPLETION_EDIT`, `WALK_VOIDED`, `WALK_DELETE_REFUSED`, `WALK_SAVE_CONFLICT`,
`WALK_SAVE_REJECTED` (tampering: code and paths), `WALK_MUTATION_REPLAYED`, `WALK_MUTATION_ID_REUSED`,
plus `ACCESS_DENIED` from the authorization layer. No narrative value is ever written to the audit
or mutation logs.

**Browser.** `ApiWalkStore` implements the Phase 3 `WalkStore` interface over the routes. `app.js`
debounces edits 700 ms, coalesces edits made mid-flight into the next save, and shows `Unsaved
changes` / `Saving...` / `All changes saved` / a specific failure with a Retry action (input stays on
screen). Every ambiguity-capable mutation owns an immutable operation record (`docs/DATA_CONTRACT.md`,
"Pending mutation operations in the browser") keyed by action and target, carrying its
`clientMutationId`, its row version, and its frozen semantic body. A record whose request has been
sent is never replaced by a newer payload: an edit made during an in-flight save queues behind it, and
a lost answer retries the original request before the queued state goes out under a new id. Unresolved
operations are rendered from that registry into an unfinished-operations bar that lives outside both
views, so a retry is still reachable after the list re-renders or the walk is reloaded from the
server. On 409 `STALE_ROW_VERSION` it stops autosaving, loads the server record, and shows an
`alertdialog` listing only the fields this session changed since it last loaded or saved (its unsent
edits) against the saved values; "Use the saved version" discards them, "Keep my edits and save"
applies them on top of the server record and saves with the new row version. Completion errors are
rendered as an `alert` summary with links that expand the section and focus the control, and each
field is marked `aria-invalid` with a description. Non-owners get a read-only editor; completed walks
show a banner; a completed walk's delete action asks for a void reason. Walks pinned to an older
version load their render model through `GET /api/walks/{id}/instrument` and cache it per version.

## Summary export and teacher email draft (Phase 5)

```
browser  app.js #export-btn -> GET /api/walks/{id}/summary            (flush to the server, then download)
         renderer.js email-draft slot -> email-composer.js -> setResponse + commit -> PUT /api/walks/{id}
server   WalkController.summary -> WalkService.summary
                                   -> AuthorizationService.authorizeWalk(read)
                                   -> WalkRepository (header, dimension values, responses)
                                   -> SnapshotService.renderModelFor(pinned versionId)
                                   -> VisibilityEngine.evaluateVisibility
                                   -> WalkSummaryFormatter.summaryText / fileName
                                   -> AuditRepository (WALK_SUMMARY_EXPORTED: ids and a byte count)
shared   src/walks/WalkSummaryFormatter.cfc  ==  app/assets/js/summary.js
         proven byte-identical by tests/fixtures/summary-vectors.json
```

**One formatting contract, implemented twice.** The export is the same problem the visibility engine
already had: the browser must show what the server would produce, and neither may drift. It is
solved the same way. Both formatters are pure functions of `(model, state, evaluation)` with the
same function names and the same output, and `tests/fixtures/summary-vectors.json` holds golden
expectations that both suites compare byte for byte (`compare()` in CFML, never `==`). Nothing else
formats a summary: the browser's fallback export, the email draft, and the server's download all
come from these two files.

The browser's fallback is narrow on purpose. `#export-btn` flushes the editor state to the server
and downloads `GET /api/walks/{id}/summary`; it uses the browser formatter **only** when that flush
failed with an actual `NetworkError` -- the one failure that means no response was produced and the
server was not reached. A 4xx, a 5xx, a conflict, and any answer the browser could not use all block
the export instead, because in every one of them the request reached the server and a
browser-generated file could describe a state the server already holds (`docs/DATA_CONTRACT.md`,
"Pending mutation operations in the browser").

The vectors are not self-certifying. `scripts/generate-summary-vectors.mjs` produces them from the
**served** render model with the JavaScript formatter, and `scripts/prototype-summary-oracle.mjs`
then replays every vector through `source/current-prototype.html` itself and classifies each
difference. Only the deviations recorded in `BUILD_STATUS.md` (hidden values excluded, the
content-area heading, the doubled trailing colon, yes/no capitalization) are allowed; anything else
fails. The generated email drafts match the prototype exactly, with no deviation at all.

**Nothing new is stored.** The summary is derived on demand and never cached; the file name is
derived; the email draft is one ordinary `walk_response.text_value` of the existing
`EMAIL_DRAFT_JSON` item. Phase 5 adds no table, column, or migration.

**Exporting is a read.** The route carries the same policy and the same `authorizeWalk(read)` as
opening a walk, takes nothing from the request but the walk id, writes nothing, and moves no row
version. A VOIDED walk still exports, because Phase 4 keeps it readable by id.

**The draft rides the existing mutation path.** The composer writes the whole document into the
walk's `email_workflow` response and commits through the renderer, so autosave, the row-version
compare, mutation idempotency, replay coherence, and the conflict panel all apply unchanged. The
browser serializes its keys in the order the server canonicalizes to, so a reload compares equal
and no phantom unsent edit appears.

**Nothing sends mail, and nothing may.** No SMTP configuration, no `cfmail`, no mail library, no
endpoint that accepts a recipient. The only outbound action is a `mailto:` URL the browser hands to
the person's own mail client, with every value percent-encoded.
`tests/node/no-mail.test.mjs` is the standing gate on all of that.

## Instrument publication (Phase 6 foundation)

`InstrumentPublishService` freezes one DRAFT into a PUBLISHED version. What makes it safe is not one
check but the shape of the transaction around it.

**One rule set, two layers.** `DefinitionValidator` is the authoritative semantic rule set, and it
works over *normalized definitions* -- the representation the importer produces, the compiler
serializes into the snapshot, and `DefinitionRepository.loadNormalizedDefinitions` reads back out of
SQL Server. `InstrumentConfigValidator` keeps only the rules that mean something for an inbound
authoring document (authoring ids, `conditionsJson` as text, the DRAFT declaration) and delegates
everything else to the shared validator on the normalized form of the document it is validating. So
import and publish apply the same predicate and cannot drift apart. See
`docs/DATA_CONTRACT.md`, "One semantic rule set".

**Validity, not self-consistency.** Publication validates the stored snapshot's envelope and
definitions, *and* the definitions SQL Server holds, each in its own right, before comparing the two
by checksum. A DRAFT carrying the same invalid content in both places satisfies every comparison
between them; only validating each one separately catches it.

**Publishable means renderable.** A rule set is a description of the runtime, maintained by hand,
and a description drifts. `DefinitionValidator` now carries a rule for every way
`RenderModelBuilder` can fail -- exactly one active root section, no active content orphaned from
it, only item types and option filters the runtime implements, and every reference an *active* row
makes resolving to something that is also active and usable -- and publication *also* runs the real
renderer, on the exact bytes it is about to freeze (`RenderContractValidator`). A renderer failure
becomes a structured `{ code, message, path }` refusal rather than escaping as a runtime 500, and
the built model is counted against the definitions so a renderer that builds successfully while
silently dropping a subtree is refused too. Import runs the same preflight on the snapshot it
compiles, so a DRAFT that imports is a DRAFT that publishes.

**Item types are a runtime commitment.** `MULTI_CHOICE` and `SHORT_TEXT` were on the accepted list
and implemented nowhere: neither has a renderer layout, and `icf.walk_response` stores one selected
option per item, so `MULTI_CHOICE` had nowhere to be persisted even if it were drawn. Both are
refused, at import and at publication. `DefinitionValidator.itemTypes()` is the single place that
records the decision, and `RenderModelBuilder` and `SnapshotCompiler` read their shared constants
(the option-filter table, the placeholder review status) from it rather than keeping copies.

**One lock order.** `instrument_version` under `UPDLOCK, ROWLOCK` first, children afterwards -- for
publication, for import, inside every repository mutator that writes version content
(`DefinitionRepository.requireDraftVersion`), and inside the global identity creators' own single
`INSERT ... SELECT` (below). A publish racing an edit therefore queues on one row rather than
interleaving into a partially frozen version, and neither order can deadlock by design.

**A structural write boundary, including the shared and global rows.** Immutability is not a
helper a caller must remember. Every repository mutator that writes version content locks and checks
the owning version itself, and every statement it issues carries `status = N'DRAFT'` in its own
predicate; a method handed only a child id resolves the owner from the database rather than from its
arguments. There is no unchecked deletion path -- fixture teardown lives in
`tests/cfml/support/FixtureCleanup.cfc`, which no application code references.

The mutators that write *shared* or *global* rows are inside the boundary too, under the contract
each actually has, rather than excluded from the inventory as they once were:

| Mutator | Rows | Contract |
| --- | --- | --- |
| `createInstrument` | `icf.instrument` | Insert-only, at the instrument's birth, when it has no versions to protect. The unique `code` makes a second call fail rather than reach the existing row. |
| `updateInstrumentMetadata` | `icf.instrument` | Performs the UPDATE only. The caller takes the row under `UPDLOCK, HOLDLOCK, ROWLOCK` (`lockInstrumentByCode` / `lockInstrumentById`) and derives every value from **that** read, inside the same transaction. Its `userExists` call is an **integrity** check for the audit foreign key, not authorization: every row in `icf.app_user` satisfies it. Reached only by `InstrumentMetadataService`, which authorizes (`instrument.manage`) and audits. No import path, and no route. |
| `lockInstrumentByCode` / `lockInstrumentById` | `icf.instrument` (read) | The locked read the shared-row write derives from. `UPDLOCK, HOLDLOCK, ROWLOCK`, so the values read are still the values being replaced at the moment of the write. Import calls the second one **after** its version lock, preserving the one lock order. |
| `createDimensionIdentity` | `icf.dimension_definition` | One statement: `INSERT ... SELECT` whose source is the owning `icf.instrument_version` row under `UPDLOCK, ROWLOCK`, predicated on `status = N'DRAFT'`, with `OUTPUT INSERTED` returning the row actually inserted. Atomic, so a caller that owns no transaction has no window between the authority decision and the write. No eligible row means nothing is inserted and the caller gets a typed non-DRAFT refusal. |
| `createDimensionValueIdentity` | `icf.dimension_value` | The same single qualified statement; the next display order is a correlated subquery, so the statement's source stays the one version row and exactly zero or one value is ever minted. |
| `createDraftVersion` | `icf.instrument_version` | Creates a DRAFT under an existing instrument; there is no frozen version to protect. |

**Shared instrument metadata has one owner, and it is not import.** `icf.instrument.active` is part
of `SnapshotService.currentVersion()`'s selection predicate, so writing it decides whether an
already PUBLISHED version is in service at all. The importer used to write the whole shared row from
the document on every re-import, which made "import a V2 draft" a way to remove published V1 from
the runtime with nothing changed on the version and nobody named. Now:

* `code` is identity, written once and never updated.
* `name` and `description` are **version** facts. They are compiled into each version's snapshot and
  served from it by `RenderModelBuilder`, so V2 may describe the instrument differently from V1 and
  each walk sees its own version's wording. Nothing in the walk runtime reads the shared row's name
  or description; they are operational labels for the instrument as a whole.
* `active` is a shared operational decision. An import that declares it differently from the stored
  row is refused atomically with `SHARED_METADATA_CONFLICT` -- not applied, and not silently
  dropped -- and the refusal is audited like any other refused write.
* Changing any of the three deliberately is `InstrumentMetadataService.updateMetadata`. It takes
  the **current principal** and asks `AuthorizationService` for global `instrument.manage` before
  any mutation; the audit actor is that principal's `userId`, and there is no argument by which a
  caller can name or substitute another actor. `DefinitionRepository.userExists` is still called,
  as an **integrity** check for `icf.audit_event.actor_user_id`'s foreign key -- every row in
  `icf.app_user` satisfies it, so it is not, and must not be described as, a permission check.
  This pass closes the boundary and adds **no** administration UI for the operation: nothing in
  `src/http` or `src/controllers` reaches it. That absence is a scope decision, not the security
  control.
* **The row is locked before it is read, not after.** The operation derives a complete replacement
  row, so a patch that changes one field restates the stored value of every field it omits. Those
  values now come from `lockInstrumentByCode`, which takes the row under `UPDLOCK, HOLDLOCK` and
  reads it in the same statement; the merge, the update and the audit all happen inside that one
  transaction. Deriving them from an unlocked read and taking the lock later -- which is what this
  used to do -- is a lost update: two concurrent partial patches both restate what they read before
  the other ran, and whichever commits second silently undoes the first. Because `active` decides
  whether a published version is in service, the change that got undone could be a deliberate
  deactivation, and the audit trail recorded a `before` image that was never the row replaced.
* **Import decides the shared conflict on the locked current row.** Import reads `icf.instrument`
  to resolve the instrument id; that read is unlocked and an authorized metadata change can commit
  after it. So import re-reads the row under `UPDLOCK, HOLDLOCK` **after** taking the version lock,
  and evaluates `SHARED_METADATA_CONFLICT` against that. One lock order throughout --
  `icf.instrument_version` first, `icf.instrument` second -- and the metadata operation requests no
  version lock at all, so none of these three can deadlock with each other.

**Durable refusals, from every refusing branch.** Every refusal happens inside the transaction, so a
record written there would roll back with it. The refusing branch captures a small descriptor, the
transaction rolls back, and exactly one audit event is written afterwards, carrying identifiers,
statuses, reasons, counts and checksums -- never definitions, snapshot text or narrative content.
`InstrumentImportService` uses the same shape for a refused import or discard, **including** the
DRAFT-in-use branches (`INSTRUMENT_VERSION_IN_USE`), which previously threw without marking the
refusal and so left no trace at all -- and which, being DRAFTs, had no status guard standing behind
them either.

**A named publisher.** The publisher is required at the service boundary, checked against
`icf.app_user` under the lock, read back from the row before the success audit is written, and
enforced by `CK_instrument_version_publisher_required` in the database. Over HTTP it comes from the
authenticated principal only; the route takes no request body at all.

**Version-scoped dimensions, and a one-time transition.** `icf.dimension_definition` and
`icf.dimension_value` hold reporting identity only. What a version calls a dimension and which
values it offers live on `icf.instrument_dimension` and `icf.instrument_dimension_value` (migration
`006`), so importing V2 cannot change what published V1 says -- while a walk's stored `value_id`
still means the same thing across versions. Migration `006`'s legacy membership backfill is a
one-time schema transition recorded in `icf.schema_migration_state`, never a condition re-evaluated
on each apply: re-evaluating it made a re-application infer a V2-only value into published V1,
changing what V1 accepted while its snapshot, checksum and `row_version` stayed put. See
`database/README.md`, "The legacy membership backfill is one-time", for the states, the read-only
detection queries and the reviewed remediation procedure.

**Concurrency is proved with a barrier, not with timing.** Repeated `Promise.all` races are kept as
stress coverage, but they cannot show that two transactions ever overlapped. The deterministic
proof is a two-sided barrier (`tests/cfml/support/ConcurrencyBarrier.cfc`, driven through the
`armBefore` / `armAfter` seams of `tests/cfml/support/InterceptingDefinitionRepository`). Transaction
A emits `A_LOCKED` from inside its transaction once it holds the production lock; the competing
request B emits `B_AT_COMPETING_BOUNDARY` immediately before the database call that contends for
that lock. The spec releases A only after hearing B, asserts both signals were observed in that
order, and then asserts the one permitted serial outcome and the final state. That B had not
finished while A held the lock is asserted too, but only as supplemental evidence once its arrival
has been independently observed; non-completion on its own proves nothing about arrival. Seven
pairings are covered: publish/publish, publish/import, import/publish, publish/new dimension
identity and publish/new dimension-value identity (`PublishConcurrencyBarrierTest`), and
metadata/metadata and import's shared-state check against an authorized metadata update
(`SharedMetadataConcurrencyBarrierTest`). The decorator is test-only: the container never holds it
and no route reaches it, so there is no configuration in which a client can activate a lock hook.

## Instrument administration (Phase 6)

```
browser  admin.js -> /api/admin/instrument/*            (Router: permission instrument.manage; CSRF on every POST)
            |
AdminInstrumentController  (body contracts: only named members; no body on publish/discard; 5 MB import cap)
            |
InstrumentAdminService ----- reads ----> SnapshotService (checksum-verified snapshot -> render model)
     |        |                           InstrumentVersionComparer (row-by-row diff on logical keys)
     |        |                           DraftEditor (pure: which wording may change, and how)
     |        '-- writes ---> InstrumentImportService.writeNormalizedDraft  (the one DRAFT write path)
     |
InstrumentPublishService.publish / .retire   (version row lock, then instrument; refusals audited after rollback)
```

**One write path for every DRAFT.** An upload, a clone and a wording edit all end as a normalized
instrument document handed to `InstrumentImportService.writeNormalizedDraft`: the same definition
validation, renderer preflight, version lock, compile, round-trip proof and refusal audit an import
gets. Its options say what kind of write it is (`operation` IMPORT / CLONE / EDIT, `mustCreate` for a
clone, `targetVersionId` + `expectedChecksum` for an edit, `skipWhenUnchanged`, the success event and
extra audit details). `InstrumentAdminService` never writes a definition row, so there is no second,
weaker authoring path to keep in step.

**Wording, not structure, is edited in the browser.** `DraftEditor` allows the fields the acceptance
criteria and the placeholder queue need -- section title, instructions and review status; item
prompt, help text, placeholder, review status and revision notes; option label and definition;
version review status and notes -- and nothing that changes structure (keys, types, response sets,
rules, dimensions, order). Structure is authored in the instrument document and imported, as before.
Keys match exactly. When an edit changes an item's prompt or review status, the document's
`contentReview.unresolvedPlaceholders` summary is rebuilt from the items; otherwise it is untouched,
so an unrelated edit cannot move snapshot bytes. Because `behavior` and item `settings` are never
editable here, an in-app edit cannot change the summary export or the email draft
(`behavior.export.fileNamePattern`, `settings.selectableParts`): the summary vectors stay valid.

**Lost updates are refused, not merged.** An edit carries the checksum of the DRAFT it was made
against. It is compared before the edit is built and again under the version row's lock inside the
write; a mismatch is 409 `DRAFT_CHANGED` with the current checksum and a durable refusal audit.

**Preview is the runtime's model.** `preview` returns `SnapshotService.renderModelFor(versionId)` --
the builder, the verified snapshot and the cache walks use -- and the browser renders it with the same
`renderer.js`, over a blank state that is never saved. For the version `/api/instrument/current`
serves, the preview model is byte-identical (`admin-instrument.test.mjs`).

**Comparison is on logical keys, exactly.** `InstrumentVersionComparer.diff` keys each collection by
its logical key (sections by `sectionKey`, options by `setKey/optionKey`, and so on) and compares rows
through canonical JSON, so a type change (`"1"` versus `1`) is a change and struct key order is not.
It reports added, removed and changed rows with field-level before and after, plus a fixed list of
version metadata.

**Retirement.** `InstrumentPublishService.retire` takes the version row with `UPDLOCK, ROWLOCK` (the
single lock order: version row, then instrument), refuses anything but PUBLISHED, and refuses
leaving the instrument with no version in service unless the caller confirms
(`allowNoCurrentVersion`). `DefinitionRepository.markRetired` sets `status = RETIRED` and
`effective_end` (strictly after `effective_start`, which the schema's check requires); snapshot,
checksum, publisher and publication time are untouched, and `InstrumentImmutabilityTest` now carries
`markRetired` in its lifecycle inventory. Retirements of one instrument are serialized: after its
version lock, `retire` takes a transaction-owned `sp_getapplock` named for the instrument
(`DefinitionRepository.lockRetirement`) before it checks what stays in service. Without it, two
administrators retiring the two in-service versions at once could each count on the other's
version and both commit, leaving nothing in service unconfirmed
(`RetireConcurrencyBarrierTest.testTwoRetirementsCannotTogetherLeaveNothingInService`, red before
the lock). Only retirement takes that lock, so it adds no edge to the version-then-instrument order
the other operations share. Who retired a version is recorded in the audit event, not a
new column: no migration was needed.

**A walk is never pinned to a retired version.** `WalkService.create` resolves the current version,
then inserts the walk. Retirement could commit between the two. `WalkRepository.insertWalk` is now a
status-qualified `INSERT ... SELECT` from the version row `WITH (HOLDLOCK, ROWLOCK)` with `OUTPUT
INSERTED`: nothing inserted means the version is RETIRED, and the service answers 409
`INSTRUMENT_VERSION_CHANGED`. The shared range lock also makes a retirement that arrives after the
insert queue behind the walk's transaction. Before this change a barrier test produced both failure
modes -- a walk pinned to a RETIRED version, and a SQL Server deadlock victim
(`RetireConcurrencyBarrierTest`, red evidence in `docs/evidence/phase6-admin-red-before-fix.md`).
Existing walks are unaffected: they open, save, complete, export and report against their pinned
version whatever its status.

**The view.** `app/assets/js/admin.js` is its own view in the one shell, like Reports. A user whose
only capability is `instrument.manage` lands on it and never calls a walk or report route. Actions
are offered by status (Preview, Compare, Placeholders and New draft for every version; Edit wording,
Publish and Discard for a DRAFT; Retire for a PUBLISHED one), but every decision is the server's and
a refusal is shown as the server gave it. Publish, retire and discard ask first in an inline
`alertdialog` with focus on Cancel; retiring the only in-service version asks a second time. A
mutation whose answer never arrived is reported as unknown and the list is reloaded, never assumed
done. All text reaches the page through `textContent`; the CSP is unchanged.

**Reports after a retirement.** Phase 7 already reports PUBLISHED and RETIRED versions. The one
change there: when nothing is in service, the default report version is the newest frozen version
instead of a 404, so the Reports view still opens (`InstrumentAdministrationTest.testReportsStillOpenWhenNoVersionIsInService`).

## The Excel round-trip (instrument updates)

The instrument changes once a year. Structure (new questions, answers, rules) is authored in the
instrument document, and people edit that document in Excel rather than as JSON:

```
Download:  GET .../versions/{id}/document  -> InstrumentDocumentExporter (snapshot -> document)
           -> workbook.js writeWorkbook (in the page) -> .xlsx saved by the browser
Upload:    .xlsx -> workbook.js readWorkbook (in the page) -> document
           -> POST /api/admin/instrument/import (unchanged) -> validation, DRAFT
```

**The server never parses a spreadsheet.** Conversion both ways happens in the browser. The upload
ends as the same JSON document a JSON upload sends, through the same route, validation, size cap and
refusal audit, so a workbook can do nothing a document could not, and there is no new upload path
to secure. `app/assets/js/workbook.js` has no dependency: an .xlsx file is a zip of XML parts, read
and written with the platform's raw-deflate streams (`CompressionStream`, `DecompressionStream`) and
a small XML reader that refuses any DOCTYPE, so no entity or external reference is ever expanded.
Size limits stop a file that inflates far past what an instrument could be, and every zip part's
CRC is checked.

**The export is an exact inverse.** Compiled snapshots keep every row's authoring id, so
`InstrumentDocumentExporter` gives each row its id back and resolves each key reference to the id
of the row that owns it. `InstrumentDocumentExporterTest` proves the supplied instrument exports and
normalizes back to the same definitions checksum and the same whole-snapshot checksum, and that a
PUBLISHED version exported and imported under a new label is a DRAFT with exactly its definitions.

**The workbook is the one content owners already know.** Same sheet and column names and the same
title, description and header rows as `config/ICFWalk_Instrument_Configuration_Aligned.xlsx`, plus a
"Start Here" sheet and a "document" sheet (`docs/DATA_CONTRACT.md`, "Instrument workbooks"). The
reviewed aligned workbook, written by other software, reads to exactly the supplied instrument, and
workbooks opened, edited and saved in LibreOffice Calc read back exactly (`tests/node/workbook.test.mjs`
with the fixtures in `tests/fixtures/workbooks`).

**Problems point at cells.** A problem in the workbook itself is reported by sheet, row and column
before anything is sent. A problem the server finds is reported against a document path, which
`locate()` maps back to the cell it came from -- including paths into the normalized definitions,
whose rows the server sorts by key, by reproducing that sort.

**A draft is not replaced by surprise.** Uploading under the label of an existing DRAFT replaces
it, which is how a draft is edited in Excel. The workbook records which version and checksum it was
downloaded from, so the page asks first when that draft changed after the download, or when the file
did not come from it at all; a published version's label is refused with the way out.

## Aggregate reporting (Phase 7)

```
browser  reports.js -> GET /api/reports/options | /aggregate | /aggregate.csv   (Router: permission report.view)
server   ReportController -> ReportService
             AuthorizationService.requirePermission / visibleOrgUnitIds   (scope: covered units only)
             SnapshotService.renderModelFor(version) + WalkRepository.definitionIndex(version)
             VisibilityEngine.evaluateVisibility   (which dimension values are visible, per combination)
             ReportRepository   (one READ COMMITTED transaction, session temp tables, counts only)
             AuditRepository    (REPORT_EXPORTED: identifiers and counts)
```

**What a report is.** Counts and scores keyed by codes, over the walks of **one** instrument
version (default: the current one). Every walk is pinned to an immutable version, and two versions
may word or score an item differently, so the report never pools across versions. The reportable
surface -- the *catalog* -- is derived from that version's render model: active single-choice
items flagged reportable (notes, text, display items and the email draft are never reportable,
whatever their flags say), and active placements of reportable, non-sensitive **list** dimensions
except School (the org unit is the school and the scope authority; free-text Observer, Lesson
Standard and tags and the Date dimension are never reported). The catalog is cached per version and
checksum, exactly like the definition index it is built from.

**Who.** `report.view` admits the request; the population is the caller's covered units
(`AuthorizationService.visibleOrgUnitIds`, which already resolves effective dates, active units and
`include_descendants`) intersected with any unit the request names. A named unit outside that set
is refused through `requirePermission`, so it is 404 and audited `ACCESS_DENIED`, the same way an
out-of-scope walk is. Instrument administrators and role-less users hold no `report.view`.

**Counting.** Response states are read, not re-derived: the Phase 4 save path writes the engine's
own `ANSWERED` / `UNANSWERED` / `HIDDEN` / `NOT_APPLICABLE` evaluation in the same transaction as the
value it describes. Option distributions count `ANSWERED` rows only; an item mean is the sum of the
option scores of answered, scored, non-N/A responses divided by their count, computed in
`BigDecimal`; a section's mean pools every scored response beneath it (weighted by responses, never
an average of walk averages). Dimension states are **not** persisted, so the report asks the engine:
for a dimension whose visibility rules read only other list dimensions, every combination of those
source values (plus "none") is evaluated through `VisibilityEngine.evaluateVisibility`, and the
combinations that show it become the SQL condition that decides whether a stored value counts. For
Period that yields "grade in 6..12", derived rather than written anywhere. A dimension whose
visibility would depend on a response or on free text is left out of the report rather than
counted wrong.

**Coherence without locks.** A report reads many walks over several statements, and a save can
commit between two of them. Holding every population walk's mutation lock (the Phase 5 export's
answer for one walk) would stall every autosave in scope for the length of a district report, so
the report validates optimistically with the row version every mutation already moves:

1. `selectCandidates` reads walk rows only and stores each walk's `row_version` in a session temp
   table (`#icf_report_population`);
2. the population filters and every aggregate join that table and read child rows;
3. `verifyPopulation` re-reads the row versions. Any walk that moved (or vanished) means some
   aggregate may have seen it in two states, and the whole report is discarded and recomputed, at
   most three times; then 409 `REPORT_POPULATION_CHANGED`.

Create, save, complete and void all update the walk row in the same transaction as their child
writes, and a no-op save writes nothing, so a moved row version is exactly the signal needed. A walk
left out because of what S2 read (a filter it failed) was left out on the strength of one committed
state; every walk that is counted was unchanged from its selection to the check. The transaction is
READ COMMITTED and exists only to keep the temp tables on one connection -- it holds no lock a writer
waits on. `ReportCoherenceTest` forces a real committed save between the dimension and item
aggregates through `tests/cfml/support/InterceptingReportRepository` and proves the recomputation;
with the check removed the same test reports Grade 7 beside rating 5, a state the walk never held
(`docs/evidence/phase7-red-before-fix.md`).

**Exclusions are structural.** `ReportRepository` selects walk ids, org units, statuses, row
versions, selected value ids and selected option ids -- nothing else. It names no text, teacher,
classroom, owner or user column, which `tests/node/reports.test.mjs` asserts against its source,
and no report DTO carries a walk identifier. The browser module builds its DOM with `textContent`
only.

**Privacy suppression.** `ICFWALK_REPORT_SUPPRESSION_THRESHOLD` stays the undecided seam it was
(default none). When set to N, a population below N is withheld whole and each org-unit and
dimension-value group below N is withheld individually. See `docs/DATA_CONTRACT.md` for what it
deliberately does not attempt.

**Browser.** `reports.js` owns the Reports view in the existing shell: filters built from
`/api/reports/options`, a query string for `/api/reports/aggregate`, and a link to the CSV route
(no `download` attribute, so the route's `Content-Disposition` names the file). A report-only role
lands there and never requests `/api/walks` or `/api/instrument/current`; walk roles get a Reports
button beside My walks, reached through the same unsaved-work guard as leaving the editor.

## What Phase 6 builds on

- `WalkSummaryFormatter` / `summary.js` are the one place walk content becomes prose. Anything that
  has to render or export a walk (an administration preview, a report) should call them rather than
  format again; the vectors are what keeps that promise enforceable.
- `GET /api/walks/{id}/summary` is the pattern for any future read-only, downloadable artifact:
  `authorizeWalk(read)`, the walk's pinned version, a sanitized `Content-Disposition`, `no-store`,
  `nosniff`, and an audit event carrying identifiers and counts only.
- The composer shows how a composite control lives inside the renderer: it is built once into the
  item's slot, syncs from the walk state on every refresh, writes through `setResponse` + `commit`,
  and is disabled by `applyEditability` like every other control.
- Publishing (Phase 6) must keep `behavior.export.fileNamePattern` and the `email_workflow` item's
  `settings.selectableParts` intact, because both formatters are driven by them. Adding an
  `exportLabel` item setting and a `settings.titleTemplate` would retire the two presentation maps
  that remain (`PART4_LABELS` and the content-area heading decision).
- The email draft is non-reportable by contract: Phase 7 must exclude `email_workflow` from every
  report and extract.

## What Phase 5 built on (Phase 4 hand-off)

- `WalkService.open` returns the normalized state plus derived states; the summary/export
  formatter was built once in CFML and once in JavaScript over the same render model + state,
  like the visibility engine, and proven equal by vectors.
- The email-draft item (`EMAIL_DRAFT_JSON`) already persisted the `docs/DATA_CONTRACT.md` document
  through the ordinary save path (validated, canonical JSON in `text_value`, non-reportable).
- `renderer.js` exposed the `email-draft` layout slot; `app.js` `#export-btn` was the hidden hook for
  the text export.

## What Phase 4 built on (Phase 3 hand-off)

- `SnapshotService.renderModelFor(versionId)` and `snapshotFor(versionId)` render a walk against
  its pinned version; `currentVersion()` is the version new walks are created against.
- `VisibilityEngine.evaluateVisibility(model, state)` and `normalize(model, state, policies)` give
  the server the same HIDDEN / NOT_APPLICABLE / clearing decisions the browser makes, for the
  autosave transaction, completion validation, and reports.
- `WalkStore` (browser) is the seam for `/api/walks` endpoints; `app.js` already carries the
  org-unit selection for creation (`walk.create` scope from `/api/me`) and the save-status states.

## What Phase 3 built on (Phase 2 hand-off)

- `AuthorizationService.visibleOrgUnitIds(principal, "walk.read")` and `authorizeWalk` are the
  scope primitives for My Walks and the walk editor; `req.principal` is available in every
  authenticated controller.
- `Router.add(method, pattern, controller, action, policy)` with `{ "permission": "walk.create",
  "orgUnitBody": "orgUnitId" }` authorizes creation against the unit named in the JSON body.
- The compiled snapshot on `instrument_version` is the rendering contract; `DefinitionRepository`
  resolves keys to GUIDs for persistence.
